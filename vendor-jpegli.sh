#!/bin/bash
set -euo pipefail

export LC_ALL=C

JPEGLI_COMMIT="031a0077f5799a6041004267fc12b956c1f52a20"
JPEGLI_SHA256="269b3a75d6b2da2351f7fb2d642043f60f9b6d1bd5839f20c0d7c569be073367"

HIGHWAY_COMMIT="271a9a0ed9de1232d9117f1572c3fe28f8542ec1"
HIGHWAY_SHA256="c42bcfe44d100223ea0043acb3da6de703103ca44bfb1d46b577c90939177f5f"
SKCMS_COMMIT="96d9171c94b937a1b5f0293de7309ac16311b722"
SKCMS_SHA256="9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627"
ZLIB_COMMIT="51b7f2abdade71cd9bb0e7a373ef2610ec6f9daf"
ZLIB_SHA256="d9e270d46252734aa49770fbc544125391617956266f220bd63216c834f3a522"
LIBPNG_COMMIT="872555f4ba910252783af1507f9e7fe1653be252"
LIBPNG_SHA256="f7ebcdc408a26d45244d9ef3d35d732a5482a77c55d1d40bf1eb748030691097"
LIBJPEG_TURBO_COMMIT="8ecba3647edb6dd940463fedf38ca33a8e2a73d1"
LIBJPEG_TURBO_SHA256="ed729127097af5000bfeddc6b3e679c4363bb1618ebfc07efb6b47f576471b4b"

CMAKE_VERSION="3.27.9"
CMAKE_SHA256="ae1fdfd3f74864d0432f2e4a93ff6488125cd8f2869a40a1c2d5166feb6c607c"
DEPLOYMENT_TARGET="14.0"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
WORK_DIR=$(mktemp -d /tmp/lithe-jpegli.XXXXXX)

cleanup() {
  case "$WORK_DIR" in
    /tmp/lithe-jpegli.*)
      /bin/rm -rf -- "$WORK_DIR"
      ;;
    *)
      printf 'Refusing to remove unexpected work directory: %s\n' "$WORK_DIR" >&2
      ;;
  esac
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "vendor-jpegli.sh requires macOS." >&2
  exit 1
fi

for tool in awk curl file grep install lipo otool shasum sips tar vtool xcrun codesign; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool is unavailable: $tool" >&2
    exit 1
  fi
done

CLANG=$(xcrun --find clang)
CLANGXX=$(xcrun --find clang++)
BUILD_JOBS=${JPEGLI_BUILD_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)}

download_and_verify() {
  local url=$1
  local destination=$2
  local expected_sha=$3

  curl -fsSL --retry 3 --retry-delay 1 -o "$destination" "$url"
  printf '%s  %s\n' "$expected_sha" "$destination" | shasum -a 256 -c -
}

extract_archive() {
  local archive=$1
  local destination=$2

  mkdir -p "$destination"
  tar -xzf "$archive" -C "$destination" --strip-components=1
}

download_and_verify \
  "https://github.com/google/jpegli/archive/$JPEGLI_COMMIT.tar.gz" \
  "$WORK_DIR/jpegli.tar.gz" \
  "$JPEGLI_SHA256"
download_and_verify \
  "https://github.com/google/highway/archive/$HIGHWAY_COMMIT.tar.gz" \
  "$WORK_DIR/highway.tar.gz" \
  "$HIGHWAY_SHA256"
download_and_verify \
  "https://github.com/google/skcms/archive/$SKCMS_COMMIT.tar.gz" \
  "$WORK_DIR/skcms.tar.gz" \
  "$SKCMS_SHA256"
download_and_verify \
  "https://github.com/madler/zlib/archive/$ZLIB_COMMIT.tar.gz" \
  "$WORK_DIR/zlib.tar.gz" \
  "$ZLIB_SHA256"
download_and_verify \
  "https://github.com/glennrp/libpng/archive/$LIBPNG_COMMIT.tar.gz" \
  "$WORK_DIR/libpng.tar.gz" \
  "$LIBPNG_SHA256"
download_and_verify \
  "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/$LIBJPEG_TURBO_COMMIT.tar.gz" \
  "$WORK_DIR/libjpeg-turbo.tar.gz" \
  "$LIBJPEG_TURBO_SHA256"
download_and_verify \
  "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz" \
  "$WORK_DIR/cmake.tar.gz" \
  "$CMAKE_SHA256"

SOURCE_DIR="$WORK_DIR/source"
extract_archive "$WORK_DIR/jpegli.tar.gz" "$SOURCE_DIR"
extract_archive "$WORK_DIR/highway.tar.gz" "$SOURCE_DIR/third_party/highway"
extract_archive "$WORK_DIR/skcms.tar.gz" "$SOURCE_DIR/third_party/skcms"
extract_archive "$WORK_DIR/zlib.tar.gz" "$SOURCE_DIR/third_party/zlib"
extract_archive "$WORK_DIR/libpng.tar.gz" "$SOURCE_DIR/third_party/libpng"
extract_archive "$WORK_DIR/libjpeg-turbo.tar.gz" "$SOURCE_DIR/third_party/libjpeg-turbo"

CMAKE_DIR="$WORK_DIR/cmake"
extract_archive "$WORK_DIR/cmake.tar.gz" "$CMAKE_DIR"
CMAKE="$CMAKE_DIR/CMake.app/Contents/bin/cmake"
if [[ ! -x "$CMAKE" ]]; then
  echo "Pinned CMake executable was not found after extraction." >&2
  exit 1
fi

build_architecture() {
  local arch=$1
  local build_dir="$WORK_DIR/build-$arch"

  "$CMAKE" -S "$SOURCE_DIR" -B "$build_dir" -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_C_COMPILER="$CLANG" \
    -DCMAKE_CXX_COMPILER="$CLANGXX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON \
    -DJPEGLI_STATIC=ON \
    -DJPEGLI_ENABLE_TOOLS=ON \
    -DJPEGLI_ENABLE_DEVTOOLS=OFF \
    -DJPEGLI_ENABLE_BENCHMARK=OFF \
    -DJPEGLI_ENABLE_FUZZERS=OFF \
    -DJPEGLI_ENABLE_JPEGLI_LIBJPEG=OFF \
    -DJPEGLI_INSTALL_JPEGLI_LIBJPEG=OFF \
    -DJPEGLI_ENABLE_DOXYGEN=OFF \
    -DJPEGLI_ENABLE_MANPAGES=OFF \
    -DJPEGLI_ENABLE_JNI=OFF \
    -DJPEGLI_ENABLE_SJPEG=OFF \
    -DJPEGLI_ENABLE_OPENEXR=OFF \
    -DJPEGLI_ENABLE_SKCMS=ON \
    -DJPEGLI_BUNDLE_LIBPNG=ON \
    -DJPEGLI_ENABLE_TCMALLOC=OFF \
    -DJPEGLI_ENABLE_LTO=OFF \
    -DJPEGLI_VERSION="${JPEGLI_COMMIT:0:12}"
  "$CMAKE" --build "$build_dir" --target cjpegli --parallel "$BUILD_JOBS"
}

# libpng performs architecture-specific feature detection at configure time, so
# each slice is configured independently before being merged into one binary.
build_architecture arm64
build_architecture x86_64

for arch_name in arm64 x86_64; do
  grep -q "^JPEGLI_VERSION:UNINITIALIZED=${JPEGLI_COMMIT:0:12}$" \
    "$WORK_DIR/build-$arch_name/CMakeCache.txt"
done

UNIVERSAL_BINARY="$WORK_DIR/cjpegli"
lipo -create \
  "$WORK_DIR/build-arm64/tools/cjpegli" \
  "$WORK_DIR/build-x86_64/tools/cjpegli" \
  -output "$UNIVERSAL_BINARY"
chmod +x "$UNIVERSAL_BINARY"
codesign --force --sign - "$UNIVERSAL_BINARY"

lipo "$UNIVERSAL_BINARY" -verify_arch arm64 x86_64
BUILD_INFO=$(vtool -show-build "$UNIVERSAL_BINARY")
if [[ $(printf '%s\n' "$BUILD_INFO" | grep -c "minos $DEPLOYMENT_TARGET") -ne 2 ]]; then
  echo "Both slices must target macOS $DEPLOYMENT_TARGET." >&2
  printf '%s\n' "$BUILD_INFO" >&2
  exit 1
fi

NON_SYSTEM_DEPENDENCIES=$(otool -L "$UNIVERSAL_BINARY" \
  | awk '/^[[:space:]]+\// { print $1 }' \
  | grep -Ev '^(/usr/lib/|/System/Library/)' || true)
if [[ -n "$NON_SYSTEM_DEPENDENCIES" ]]; then
  echo "Unexpected non-system dynamic dependencies:" >&2
  printf '%s\n' "$NON_SYSTEM_DEPENDENCIES" >&2
  exit 1
fi

codesign --verify --strict "$UNIVERSAL_BINARY"
"$UNIVERSAL_BINARY" -h | grep -F "the input can be PPM, PNM, PFM, PAM, PGX, PNG, APNG" >/dev/null

"$UNIVERSAL_BINARY" \
  "$SOURCE_DIR/third_party/libjpeg-turbo/testimages/testorig.ppm" \
  "$WORK_DIR/from-ppm.jpg" \
  -q 90
file "$WORK_DIR/from-ppm.jpg" | grep -q "JPEG image data"
sips -g format "$WORK_DIR/from-ppm.jpg" | grep -q "format: jpeg"

verify_png_round_trip() {
  local arch_name=$1

  if ! arch -"$arch_name" /usr/bin/true >/dev/null 2>&1; then
    echo "Skipping $arch_name execution because this Mac cannot run that slice."
    return
  fi

  arch -"$arch_name" "$UNIVERSAL_BINARY" \
    "$SOURCE_DIR/third_party/libpng/pngbar.png" \
    "$WORK_DIR/from-png-$arch_name.jpg" \
    -q 90
  file "$WORK_DIR/from-png-$arch_name.jpg" | grep -q "JPEG image data"
  sips -s format png \
    "$WORK_DIR/from-png-$arch_name.jpg" \
    --out "$WORK_DIR/decoded-$arch_name.png" >/dev/null
  file "$WORK_DIR/decoded-$arch_name.png" | grep -q "PNG image data, 88 x 31"
  sips -g pixelWidth -g pixelHeight "$WORK_DIR/decoded-$arch_name.png" \
    | grep -q "pixelWidth: 88"
  sips -g pixelWidth -g pixelHeight "$WORK_DIR/decoded-$arch_name.png" \
    | grep -q "pixelHeight: 31"
}

verify_png_round_trip arm64
verify_png_round_trip x86_64

mkdir -p "$SCRIPT_DIR/Vendor/bin"
install -m 0755 "$UNIVERSAL_BINARY" "$SCRIPT_DIR/Vendor/bin/cjpegli"

file "$SCRIPT_DIR/Vendor/bin/cjpegli"
lipo -info "$SCRIPT_DIR/Vendor/bin/cjpegli"
otool -L "$SCRIPT_DIR/Vendor/bin/cjpegli"
vtool -show-build "$SCRIPT_DIR/Vendor/bin/cjpegli"
shasum -a 256 "$SCRIPT_DIR/Vendor/bin/cjpegli"
echo "Verified Jpegli $JPEGLI_COMMIT and rebuilt Vendor/bin/cjpegli."
