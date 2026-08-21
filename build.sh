#!/bin/bash
set -euo pipefail

APP_NAME="Lithe"
BUILD_DIR=".build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
APP_EXECUTABLE="$(pwd -P)/$MACOS_DIR/$APP_NAME"
VERSION=$(tr -d '[:space:]' < VERSION)
SIGN_IDENTITY=${LITHE_SIGN_IDENTITY:--}
CODESIGN_ARGS=(
    --force
    --sign "$SIGN_IDENTITY"
    --options runtime
)
REQUIRED_TOOLS=(
    oxipng
    pngquant
    cjpegli
    jpegtran
)

REQUIRED_LICENSES=(
    OxiPNG-LICENSE.txt
    pngquant-COPYRIGHT.txt
    pngquant-Cargo.lock
    pngquant-DEPENDENCY-LICENSES.txt
    pngquant-SOURCE-MANIFEST.txt
    pngquant-lcms2-LICENSE.txt
    pngquant-libpng-LICENSE.txt
    Jpegli-LICENSE.txt
    Jpegli-PATENTS.txt
    Jpegli-NOTICE.txt
    Jpegli-apngdis-LICENSE.txt
    Jpegli-Highway-LICENSE.txt
    Jpegli-skcms-LICENSE.txt
    Jpegli-zlib-LICENSE.txt
    Jpegli-libpng-LICENSE.txt
    Jpegli-libjpeg-turbo-LICENSE.md
    libjpeg-turbo-LICENSE.md
    libjpeg-turbo-README.ijg
)

SOURCES=(
    LitheModels.swift
    FileLifecycle.swift
    ToolRunner.swift
    CompressionEngine.swift
    SessionModel.swift
    SystemActions.swift
    SessionCoordinator.swift
    ResultUI.swift
    InspectorUI.swift
    SettingsView.swift
    LitheApp.swift
)

require_nonempty_file() {
    local file=$1
    if [[ ! -s "$file" ]]; then
        echo "缺少必需文件或文件为空: $file" >&2
        exit 1
    fi
}

verify_system_dependencies() {
    local executable=$1
    local dependencies
    local dependency

    dependencies=$(otool -L "$executable")
    while IFS= read -r dependency; do
        [[ -z "$dependency" ]] && continue
        case "$dependency" in
            /usr/lib/*|/System/Library/*) ;;
            *)
                echo "工具包含非系统动态依赖: $executable -> $dependency" >&2
                exit 1
                ;;
        esac
    done < <(printf '%s\n' "$dependencies" | awk '/^[[:space:]]/ { print $1 }')
}

verify_tool_binary() {
    local executable=$1
    require_nonempty_file "$executable"
    if [[ ! -x "$executable" ]]; then
        echo "必需工具不可执行: $executable" >&2
        exit 1
    fi
    lipo "$executable" -verify_arch arm64 x86_64
    verify_system_dependencies "$executable"
}

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "VERSION 必须是 MAJOR.MINOR.PATCH" >&2
    exit 1
fi

if running_pids=$(/usr/bin/pgrep -x -f "$APP_EXECUTABLE" 2>/dev/null); then
    echo "检测到正在运行的 Lithe 构建产物（PID: ${running_pids//$'\n'/, }）。" >&2
    echo "请先关闭 Lithe，确认会话进程退出后再构建；拒绝覆盖正在执行的 App。" >&2
    exit 1
fi

require_nonempty_file LICENSE
require_nonempty_file THIRD_PARTY_NOTICES.md
for tool in "${REQUIRED_TOOLS[@]}"; do
    verify_tool_binary "Vendor/bin/$tool"
done
for license in "${REQUIRED_LICENSES[@]}"; do
    require_nonempty_file "Vendor/licenses/$license"
done

case "$APP_BUNDLE" in
    .build/Lithe.app) /bin/rm -rf -- "$APP_BUNDLE" ;;
    *) echo "拒绝删除异常构建目录: $APP_BUNDLE" >&2; exit 1 ;;
esac
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR/Tools" "$RESOURCES_DIR/Licenses"

COMMON_SWIFTC_ARGS=(
    -O
    -framework AppKit
    -framework SwiftUI
    -framework ImageIO
    -framework CoreImage
    -framework UniformTypeIdentifiers
    -framework CryptoKit
)

ARCH_BINARIES=()
for arch in arm64 x86_64; do
    binary="$BUILD_DIR/$APP_NAME-$arch"
    swiftc \
        -o "$binary" \
        -target "$arch-apple-macosx14.0" \
        "${COMMON_SWIFTC_ARGS[@]}" \
        "${SOURCES[@]}"
    ARCH_BINARIES+=("$binary")
done
lipo -create "${ARCH_BINARIES[@]}" -output "$MACOS_DIR/$APP_NAME"
rm -f "${ARCH_BINARIES[@]}"
lipo "$MACOS_DIR/$APP_NAME" -verify_arch arm64 x86_64

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
cp LICENSE "$RESOURCES_DIR/LICENSE"
cp THIRD_PARTY_NOTICES.md "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
for license in "${REQUIRED_LICENSES[@]}"; do
    cp "Vendor/licenses/$license" "$RESOURCES_DIR/Licenses/$license"
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$APP_BUNDLE/Contents/Info.plist"

for tool in "${REQUIRED_TOOLS[@]}"; do
    source_tool="Vendor/bin/$tool"
    destination="$RESOURCES_DIR/Tools/$tool"
    cp "$source_tool" "$destination"
    codesign "${CODESIGN_ARGS[@]}" "$destination"
done

codesign "${CODESIGN_ARGS[@]}" "$APP_BUNDLE"

for tool in "${REQUIRED_TOOLS[@]}"; do
    embedded_tool="$RESOURCES_DIR/Tools/$tool"
    verify_tool_binary "$embedded_tool"
    codesign --verify --strict "$embedded_tool"
done
cmp -s LICENSE "$RESOURCES_DIR/LICENSE"
cmp -s THIRD_PARTY_NOTICES.md "$RESOURCES_DIR/THIRD_PARTY_NOTICES.md"
for license in "${REQUIRED_LICENSES[@]}"; do
    embedded_license="$RESOURCES_DIR/Licenses/$license"
    require_nonempty_file "$embedded_license"
    cmp -s "Vendor/licenses/$license" "$embedded_license"
done
codesign --verify --deep --strict "$APP_BUNDLE"
echo "Built $APP_BUNDLE"
