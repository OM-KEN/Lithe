#!/bin/bash
set -euo pipefail

REQUIRED_TOOLS=(
    oxipng
    pngquant
    cjpegli
    jpegtran
)

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
    if [[ ! -s "$executable" || ! -x "$executable" ]]; then
        echo "缺少必需工具或工具不可执行: $executable" >&2
        exit 1
    fi
    lipo "$executable" -verify_arch arm64 x86_64
    verify_system_dependencies "$executable"
}

verify_image() {
    local image=$1
    local expected_format=$2
    local metadata

    [[ -s "$image" ]]
    metadata=$(sips -g format -g pixelWidth -g pixelHeight "$image")
    grep -Fq "format: $expected_format" <<< "$metadata"
    grep -Fq "pixelWidth: 4" <<< "$metadata"
    grep -Fq "pixelHeight: 4" <<< "$metadata"
}

mkdir -p .build/tests

swiftc -parse-as-library \
    LitheModels.swift \
    FileLifecycle.swift \
    ToolRunner.swift \
    CompressionEngine.swift \
    SessionModel.swift \
    SystemActions.swift \
    InspectorUI.swift \
    Tests/CoreTests.swift \
    -framework AppKit \
    -framework CryptoKit \
    -framework CoreImage \
    -framework ImageIO \
    -framework UniformTypeIdentifiers \
    -o .build/tests/CoreTests

.build/tests/CoreTests

for tool in "${REQUIRED_TOOLS[@]}"; do
    verify_tool_binary "Vendor/bin/$tool"
done

[[ "$(Vendor/bin/oxipng --version)" == "oxipng 10.2.0" ]]
[[ "$(Vendor/bin/pngquant --version)" == "3.0.3" ]]
cjpegli_help=$(Vendor/bin/cjpegli -h 2>&1)
grep -Fq "Usage:" <<< "$cjpegli_help"
grep -Fq "PNG" <<< "$cjpegli_help"
jpegtran_version=$(Vendor/bin/jpegtran -version 2>&1)
grep -Fq "libjpeg-turbo version 3.2.0" <<< "$jpegtran_version"

SMOKE_DIR=$(mktemp -d /tmp/lithe-tool-smoke.XXXXXX)
cleanup() {
    case "$SMOKE_DIR" in
        /tmp/lithe-tool-smoke.*) /bin/rm -rf -- "$SMOKE_DIR" ;;
        *) echo "拒绝删除异常测试目录: $SMOKE_DIR" >&2 ;;
    esac
}
trap cleanup EXIT
printf 'P6\n4 4\n255\n' > "$SMOKE_DIR/input.ppm"
printf '\377\000\000\000\377\000\000\000\377\377\377\377\000\000\000\377\377\000\000\377\377\377\000\377\100\200\300\300\200\100\040\100\140\140\100\040\012\024\036\050\062\074\106\120\132\144\156\170' >> "$SMOKE_DIR/input.ppm"
sips -s format png "$SMOKE_DIR/input.ppm" --out "$SMOKE_DIR/input.png" >/dev/null

cp "$SMOKE_DIR/input.png" "$SMOKE_DIR/oxipng.png"
Vendor/bin/oxipng -o 1 --strip safe "$SMOKE_DIR/oxipng.png" >/dev/null
Vendor/bin/pngquant --force --quality 70-95 --output "$SMOKE_DIR/pngquant.png" "$SMOKE_DIR/input.png"
Vendor/bin/cjpegli "$SMOKE_DIR/input.png" "$SMOKE_DIR/cjpegli.jpg" --quality=90
Vendor/bin/jpegtran -copy none -optimize -progressive -outfile "$SMOKE_DIR/jpegtran.jpg" "$SMOKE_DIR/cjpegli.jpg"

verify_image "$SMOKE_DIR/oxipng.png" png
verify_image "$SMOKE_DIR/pngquant.png" png
verify_image "$SMOKE_DIR/cjpegli.jpg" jpeg
verify_image "$SMOKE_DIR/jpegtran.jpg" jpeg
echo "All Lithe tests passed"
