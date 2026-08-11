#!/bin/bash
set -euo pipefail

VERSION="10.2.0"
ARM_SHA="9aad3927d095b6ade2aacb92b89ebaca442483c1f7cde5d7a2486b283c2ed5f9"
X86_SHA="c45acf40a70cc02539c55555ac240bf5ef24544b7ea9959d22da19f606cec205"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK_DIR=$(mktemp -d /tmp/lithe-oxipng.XXXXXX)

cleanup() {
  case "$WORK_DIR" in
    /tmp/lithe-oxipng.*) /bin/rm -rf -- "$WORK_DIR" ;;
    *) printf 'Refusing to remove unexpected work directory: %s\n' "$WORK_DIR" >&2 ;;
  esac
}
trap cleanup EXIT

curl -fsSL \
  -o "$WORK_DIR/arm64.tar.gz" \
  "https://github.com/oxipng/oxipng/releases/download/v$VERSION/oxipng-$VERSION-aarch64-apple-darwin.tar.gz"
curl -fsSL \
  -o "$WORK_DIR/x86_64.tar.gz" \
  "https://github.com/oxipng/oxipng/releases/download/v$VERSION/oxipng-$VERSION-x86_64-apple-darwin.tar.gz"

printf '%s  %s\n' "$ARM_SHA" "$WORK_DIR/arm64.tar.gz" | shasum -a 256 -c -
printf '%s  %s\n' "$X86_SHA" "$WORK_DIR/x86_64.tar.gz" | shasum -a 256 -c -

mkdir "$WORK_DIR/arm64" "$WORK_DIR/x86_64"
tar -xzf "$WORK_DIR/arm64.tar.gz" -C "$WORK_DIR/arm64"
tar -xzf "$WORK_DIR/x86_64.tar.gz" -C "$WORK_DIR/x86_64"

ARM_BINARY=$(find "$WORK_DIR/arm64" -type f -name oxipng -perm +111 -print -quit)
X86_BINARY=$(find "$WORK_DIR/x86_64" -type f -name oxipng -perm +111 -print -quit)
mkdir -p "$SCRIPT_DIR/Vendor/bin"
lipo -create "$ARM_BINARY" "$X86_BINARY" -output "$SCRIPT_DIR/Vendor/bin/oxipng"
chmod +x "$SCRIPT_DIR/Vendor/bin/oxipng"
lipo "$SCRIPT_DIR/Vendor/bin/oxipng" -verify_arch arm64 x86_64
"$SCRIPT_DIR/Vendor/bin/oxipng" --version

echo "Verified OxiPNG $VERSION and rebuilt Vendor/bin/oxipng."
