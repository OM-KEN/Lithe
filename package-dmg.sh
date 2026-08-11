#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "$0")" && pwd -P)
cd "$PROJECT_DIR"

APP_NAME="Lithe"
BUILD_DIR=".build"
VERSION=$(tr -d '[:space:]' < VERSION)
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$BUILD_DIR/$DMG_NAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
RELEASE_MODE=false
NOTARIZE_DMG=false

if [[ ${1:-} == "--release" ]]; then
    RELEASE_MODE=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--release]" >&2
    exit 2
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION must use MAJOR.MINOR.PATCH." >&2
    exit 1
fi

if [[ "$RELEASE_MODE" == true ]]; then
    if [[ -z ${LITHE_SIGN_IDENTITY:-} || ${LITHE_SIGN_IDENTITY:-} == "-" ]]; then
        echo "--release requires LITHE_SIGN_IDENTITY with an Apple signing identity." >&2
        exit 1
    fi
    if [[ ${LITHE_SIGN_IDENTITY} != Apple\ Development:* \
        && ${LITHE_SIGN_IDENTITY} != Developer\ ID\ Application:* ]]; then
        echo "--release requires Apple Development or Developer ID Application signing." >&2
        exit 1
    fi
    if [[ ${LITHE_SIGN_IDENTITY} == Developer\ ID\ Application:* ]]; then
        if [[ -z ${LITHE_NOTARY_PROFILE:-} ]]; then
            echo "Developer ID releases require LITHE_NOTARY_PROFILE." >&2
            exit 1
        fi
        NOTARIZE_DMG=true
    fi
fi

mkdir -p "$BUILD_DIR"
STAGING_DIR=$(mktemp -d "$BUILD_DIR/dmg-stage.XXXXXX")
MOUNT_DIR=$(mktemp -d "$BUILD_DIR/dmg-mount.XXXXXX")
IS_MOUNTED=false

cleanup() {
    if [[ "$IS_MOUNTED" == true ]]; then
        hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
    fi
    case "$STAGING_DIR" in
        .build/dmg-stage.*) /bin/rm -rf -- "$STAGING_DIR" ;;
    esac
    case "$MOUNT_DIR" in
        .build/dmg-mount.*) /bin/rm -rf -- "$MOUNT_DIR" ;;
    esac
}
trap cleanup EXIT INT TERM

./build.sh

APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_BUNDLE/Contents/Info.plist")
APP_BUILD=$(plutil -extract CFBundleVersion raw "$APP_BUNDLE/Contents/Info.plist")
if [[ "$APP_VERSION" != "$VERSION" || "$APP_BUILD" != "$VERSION" ]]; then
    echo "Built app version does not match VERSION." >&2
    exit 1
fi
if [[ "$RELEASE_MODE" == true ]]; then
    SIGNATURE_DETAILS=$(codesign --display --verbose=4 "$APP_BUNDLE" 2>&1)
    if ! grep -Fq "Authority=${LITHE_SIGN_IDENTITY}" <<< "$SIGNATURE_DETAILS"; then
        echo "The built app does not use the requested signing identity." >&2
        exit 1
    fi
    if [[ "$NOTARIZE_DMG" == true ]] \
        && ! grep -Fq "Timestamp=" <<< "$SIGNATURE_DETAILS"; then
        echo "The app signature has no secure timestamp." >&2
        exit 1
    fi
fi

ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

case "$DMG_PATH" in
    .build/Lithe-[0-9]*.[0-9]*.[0-9]*.dmg) /bin/rm -f -- "$DMG_PATH" "$CHECKSUM_PATH" ;;
    *) echo "Refusing unexpected DMG path: $DMG_PATH" >&2; exit 1 ;;
esac

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -fs HFS+ \
    -format UDZO \
    -imagekey zlib-level=9 \
    -srcfolder "$STAGING_DIR" \
    "$DMG_PATH" >/dev/null

if [[ "$NOTARIZE_DMG" == true ]]; then
    codesign --force --sign "$LITHE_SIGN_IDENTITY" --timestamp "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$LITHE_NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
elif [[ "$RELEASE_MODE" == true ]]; then
    echo "Warning: Apple Development release matches Copied but is not notarized for Gatekeeper."
fi

hdiutil verify "$DMG_PATH" >/dev/null
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG_PATH" >/dev/null
IS_MOUNTED=true
test -d "$MOUNT_DIR/$APP_NAME.app"
test -L "$MOUNT_DIR/Applications"
codesign --verify --deep --strict "$MOUNT_DIR/$APP_NAME.app"
MOUNTED_VERSION=$(plutil -extract CFBundleShortVersionString raw "$MOUNT_DIR/$APP_NAME.app/Contents/Info.plist")
[[ "$MOUNTED_VERSION" == "$VERSION" ]]
hdiutil detach "$MOUNT_DIR" >/dev/null
IS_MOUNTED=false

shasum -a 256 "$DMG_PATH" > "$CHECKSUM_PATH"
echo "Packaged $DMG_PATH"
echo "Checksum $CHECKSUM_PATH"
