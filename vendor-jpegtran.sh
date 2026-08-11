#!/bin/bash
set -euo pipefail

LIBJPEG_TURBO_VERSION="3.2.0"
LIBJPEG_TURBO_BUILD="20260630"
LIBJPEG_TURBO_SHA256="6f30092cef9fb839779646608f4ee14ae3cbac989c47fa05e841b0841f09878e"
LIBJPEG_TURBO_URL="https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${LIBJPEG_TURBO_VERSION}/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}.tar.gz"

# CMake is a pinned build-only dependency. It is not copied into Vendor/.
CMAKE_VERSION="4.3.3"
CMAKE_SHA256="d11a5713abe12c8b47afb8270e20c239cad9502ba9d5d9fd9c654731447b62ff"
CMAKE_URL="https://github.com/Kitware/CMake/releases/download/v${CMAKE_VERSION}/cmake-${CMAKE_VERSION}-macos10.10-universal.tar.gz"

MACOS_DEPLOYMENT_TARGET="14.0"
SOURCE_DATE_EPOCH="1782847419"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LITHE_JPEGTRAN_WORK_DIR=$(mktemp -d /tmp/lithe-jpegtran.XXXXXX)

cleanup() {
  case "$LITHE_JPEGTRAN_WORK_DIR" in
    /tmp/lithe-jpegtran.*)
      /bin/rm -rf -- "$LITHE_JPEGTRAN_WORK_DIR"
      ;;
    *)
      printf 'Refusing to remove unexpected work directory: %s\n' "$LITHE_JPEGTRAN_WORK_DIR" >&2
      ;;
  esac
}
trap cleanup EXIT

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "vendor-jpegtran.sh must run on macOS." >&2
  exit 1
fi

for required_command in curl shasum tar xcrun file; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$required_command" >&2
    exit 1
  fi
done

if [[ ! -x /usr/bin/make ]]; then
  echo "Missing required command: /usr/bin/make" >&2
  exit 1
fi

export LC_ALL=C
export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1

LIBJPEG_TURBO_ARCHIVE="$LITHE_JPEGTRAN_WORK_DIR/libjpeg-turbo.tar.gz"
CMAKE_ARCHIVE="$LITHE_JPEGTRAN_WORK_DIR/cmake.tar.gz"

curl -fsSL --retry 3 -o "$LIBJPEG_TURBO_ARCHIVE" "$LIBJPEG_TURBO_URL"
printf '%s  %s\n' "$LIBJPEG_TURBO_SHA256" "$LIBJPEG_TURBO_ARCHIVE" | shasum -a 256 -c -

curl -fsSL --retry 3 -o "$CMAKE_ARCHIVE" "$CMAKE_URL"
printf '%s  %s\n' "$CMAKE_SHA256" "$CMAKE_ARCHIVE" | shasum -a 256 -c -

tar -xzf "$LIBJPEG_TURBO_ARCHIVE" -C "$LITHE_JPEGTRAN_WORK_DIR"
tar -xzf "$CMAKE_ARCHIVE" -C "$LITHE_JPEGTRAN_WORK_DIR"

LIBJPEG_TURBO_SOURCE="$LITHE_JPEGTRAN_WORK_DIR/libjpeg-turbo-${LIBJPEG_TURBO_VERSION}"
CMAKE_BINARY="$LITHE_JPEGTRAN_WORK_DIR/cmake-${CMAKE_VERSION}-macos10.10-universal/CMake.app/Contents/bin/cmake"
CLANG_BINARY=$(xcrun --sdk macosx --find clang)
LIPO_BINARY=$(xcrun --find lipo)
OTOOL_BINARY=$(xcrun --find otool)
BUILD_JOBS=$(sysctl -n hw.logicalcpu)

if [[ ! -d "$LIBJPEG_TURBO_SOURCE" || ! -x "$CMAKE_BINARY" ]]; then
  echo "Downloaded archives did not contain the expected source or CMake layout." >&2
  exit 1
fi

build_architecture() {
  local architecture="$1"
  local build_directory="$LITHE_JPEGTRAN_WORK_DIR/build-${architecture}"

  "$CMAKE_BINARY" \
    -S "$LIBJPEG_TURBO_SOURCE" \
    -B "$build_directory" \
    -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CLANG_BINARY" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_DEPLOYMENT_TARGET" \
    -DBUILD="$LIBJPEG_TURBO_BUILD" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DWITH_SIMD=OFF \
    -DWITH_TESTS=OFF \
    -DWITH_TOOLS=ON \
    -DWITH_TURBOJPEG=OFF

  "$CMAKE_BINARY" --build "$build_directory" \
    --target jpegtran-static \
    --parallel "$BUILD_JOBS"

  if [[ ! -x "$build_directory/jpegtran-static" ]]; then
    printf 'jpegtran build did not produce an executable for %s.\n' "$architecture" >&2
    exit 1
  fi
}

build_architecture arm64
build_architecture x86_64

UNIVERSAL_BINARY="$LITHE_JPEGTRAN_WORK_DIR/jpegtran"
OUTPUT_BINARY="$SCRIPT_DIR/Vendor/bin/jpegtran"
mkdir -p "$SCRIPT_DIR/Vendor/bin"

"$LIPO_BINARY" -create \
  "$LITHE_JPEGTRAN_WORK_DIR/build-arm64/jpegtran-static" \
  "$LITHE_JPEGTRAN_WORK_DIR/build-x86_64/jpegtran-static" \
  -output "$UNIVERSAL_BINARY"
chmod 755 "$UNIVERSAL_BINARY"
"$LIPO_BINARY" "$UNIVERSAL_BINARY" -verify_arch arm64 x86_64

for architecture in arm64 x86_64; do
  while IFS= read -r dependency; do
    [[ -z "$dependency" ]] && continue
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      *)
        printf 'Unexpected non-system dependency in %s slice: %s\n' "$architecture" "$dependency" >&2
        exit 1
        ;;
    esac
  done < <("$OTOOL_BINARY" -arch "$architecture" -L "$UNIVERSAL_BINARY" | sed -n '2,$p' | awk '{print $1}')
done

/bin/mv -f "$UNIVERSAL_BINARY" "$OUTPUT_BINARY"

VERSION_OUTPUT=$("$OUTPUT_BINARY" -version 2>&1)
case "$VERSION_OUTPUT" in
  *"libjpeg-turbo version ${LIBJPEG_TURBO_VERSION}"*) ;;
  *)
    printf 'Unexpected jpegtran version output: %s\n' "$VERSION_OUTPUT" >&2
    exit 1
    ;;
esac

file "$OUTPUT_BINARY"
"$LIPO_BINARY" -info "$OUTPUT_BINARY"
"$OTOOL_BINARY" -L "$OUTPUT_BINARY"
printf '%s\n' "$VERSION_OUTPUT"
echo "Verified libjpeg-turbo ${LIBJPEG_TURBO_VERSION} jpegtran for macOS ${MACOS_DEPLOYMENT_TARGET}+ (arm64 and x86_64)."
