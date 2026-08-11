#!/bin/bash
set -euo pipefail

umask 022

# pngquant 3 is officially distributed as a Rust crate. The crate carries an
# exact Cargo.lock and its crates.io checksum covers the complete source tree.
PNGQUANT_VERSION="3.0.3"
PNGQUANT_CRATE_SHA256="68a12bdd8825f9989f4ee9a6ab0b42727dae57728b939ef63453366697a07232"
PNGQUANT_CRATE_COMMIT="2e953d9cbc282393022038673856623dcbeb389a"
PNGQUANT_TAG_OBJECT="1da7ec020e603ac1ed531931a36275a47521a66f"
PNGQUANT_TAG_COMMIT="53a332a58f44357b6b41842a54d74aa1e245913d"

# libpng-sys 1.1.9 is retained as the Rust FFI wrapper required by pngquant's
# lockfile, but its old bundled C source is not compiled. Link current official
# libpng and Little CMS release archives statically instead.
LIBPNG_VERSION="1.6.58"
LIBPNG_SHA256="8c9b05b675ca7301a458df2c2e46f26e1d41ff36b8863f8c33530bc58c2e6225"
LIBPNG_TAG_OBJECT="fdc7185dfedbddce8c2487bc171f66af4fca24ab"
LIBPNG_TAG_COMMIT="3061454d980de7d53608f594194cfac722721d2a"

LCMS_VERSION="2.19.1"
LCMS_TAG="lcms2.19.1"
LCMS_SHA256="bfc54f7bab59fbc921012014a8032e4cba4abd46db47d46b76416a8c0b2815c8"
LCMS_TAG_COMMIT="21c582a594fe5279f90c0b93437c398f93bf62b0"

RUST_VERSION="1.85.1"
RUSTC_SHA256="93a6fd55cf1a88bb50e133c5bdb629197b80ad0ccab128ce3a84902992786b4c"
CARGO_SHA256="21edfaa6d97dd5eca08c50d2520d1a821e917be98d3515cbf00ddafd9001b634"
RUST_STD_ARM64_SHA256="a066d9b033f5fc74283ca86e38da8178c201e86b17113e184383904573734a67"
RUST_STD_X86_64_SHA256="30d3324771063f7923ad5fe0695a09d5097d07234415a84019fe91fca912cf23"
RUST_MANIFEST_SHA256="1e7dae690cd12e27405a97e64704917489a27c650201bf47780a936055d67909"

MACOS_MIN_VERSION="14.0"
PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WORK_DIR=$(mktemp -d /tmp/lithe-pngquant3.XXXXXX)
ARCHIVE_DIR="$WORK_DIR/archives"
RUST_ROOT="$WORK_DIR/rust"
CARGO_HOME_DIR="$WORK_DIR/cargo-home"
CARGO_TARGET_DIR="$WORK_DIR/cargo-target"
STAGE_DIR="$WORK_DIR/stage"
SDKROOT=$(xcrun --sdk macosx --show-sdk-path)
MAKE_JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)

cleanup() {
    case "$WORK_DIR" in
        /tmp/lithe-pngquant3.*) rm -rf -- "$WORK_DIR" ;;
    esac
}
trap cleanup EXIT

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "This reproducible universal build requires an Apple Silicon macOS host." >&2
    exit 1
fi

for tool in awk curl file find lipo make otool shasum sips tar xcrun; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Required build tool is missing: $tool" >&2
        exit 1
    fi
done

mkdir -p \
    "$ARCHIVE_DIR" \
    "$RUST_ROOT" \
    "$CARGO_HOME_DIR" \
    "$CARGO_TARGET_DIR" \
    "$STAGE_DIR/bin" \
    "$STAGE_DIR/licenses"

download_and_verify() {
    local url=$1
    local output=$2
    local expected_sha=$3

    curl -fL \
        --ipv4 \
        --retry 5 \
        --retry-all-errors \
        --retry-delay 2 \
        --proto '=https' \
        --tlsv1.2 \
        -o "$output" \
        "$url"
    printf '%s  %s\n' "$expected_sha" "$output" | shasum -a 256 -c -
}

install_rust_component() {
    local archive=$1
    local component_dir=$2
    local extract_dir="$WORK_DIR/rust-components/$component_dir"

    mkdir -p "$extract_dir"
    tar -xJf "$archive" -C "$extract_dir"
    "$extract_dir/$component_dir/install.sh" \
        --prefix="$RUST_ROOT" \
        --disable-ldconfig >/dev/null
}

run_logged() {
    local description=$1
    local log=$2
    shift 2

    echo "$description"
    if ! "$@" >"$log" 2>&1; then
        tail -n 200 "$log" >&2
        return 1
    fi
}

PNGQUANT_URL="https://static.crates.io/crates/pngquant/pngquant-${PNGQUANT_VERSION}.crate"
LIBPNG_URL="https://download.sourceforge.net/project/libpng/libpng16/${LIBPNG_VERSION}/libpng-${LIBPNG_VERSION}.tar.gz"
LCMS_URL="https://github.com/mm2/Little-CMS/releases/download/${LCMS_TAG}/lcms2-${LCMS_VERSION}.tar.gz"
RUST_DIST_URL="https://static.rust-lang.org/dist/2025-03-18"

download_and_verify \
    "$PNGQUANT_URL" \
    "$ARCHIVE_DIR/pngquant.crate" \
    "$PNGQUANT_CRATE_SHA256"
download_and_verify \
    "$LIBPNG_URL" \
    "$ARCHIVE_DIR/libpng.tar.gz" \
    "$LIBPNG_SHA256"
download_and_verify \
    "$LCMS_URL" \
    "$ARCHIVE_DIR/lcms2.tar.gz" \
    "$LCMS_SHA256"
download_and_verify \
    "$RUST_DIST_URL/rustc-${RUST_VERSION}-aarch64-apple-darwin.tar.xz" \
    "$ARCHIVE_DIR/rustc.tar.xz" \
    "$RUSTC_SHA256"
download_and_verify \
    "$RUST_DIST_URL/cargo-${RUST_VERSION}-aarch64-apple-darwin.tar.xz" \
    "$ARCHIVE_DIR/cargo.tar.xz" \
    "$CARGO_SHA256"
download_and_verify \
    "$RUST_DIST_URL/rust-std-${RUST_VERSION}-aarch64-apple-darwin.tar.xz" \
    "$ARCHIVE_DIR/rust-std-arm64.tar.xz" \
    "$RUST_STD_ARM64_SHA256"
download_and_verify \
    "$RUST_DIST_URL/rust-std-${RUST_VERSION}-x86_64-apple-darwin.tar.xz" \
    "$ARCHIVE_DIR/rust-std-x86_64.tar.xz" \
    "$RUST_STD_X86_64_SHA256"

install_rust_component \
    "$ARCHIVE_DIR/rustc.tar.xz" \
    "rustc-${RUST_VERSION}-aarch64-apple-darwin"
install_rust_component \
    "$ARCHIVE_DIR/cargo.tar.xz" \
    "cargo-${RUST_VERSION}-aarch64-apple-darwin"
install_rust_component \
    "$ARCHIVE_DIR/rust-std-arm64.tar.xz" \
    "rust-std-${RUST_VERSION}-aarch64-apple-darwin"
install_rust_component \
    "$ARCHIVE_DIR/rust-std-x86_64.tar.xz" \
    "rust-std-${RUST_VERSION}-x86_64-apple-darwin"

rustc_version=$("$RUST_ROOT/bin/rustc" --version --verbose)
cargo_version=$("$RUST_ROOT/bin/cargo" --version)
case "$rustc_version" in
    *"release: $RUST_VERSION"*) ;;
    *) echo "Unexpected rustc version: $rustc_version" >&2; exit 1 ;;
esac
case "$cargo_version" in
    "cargo $RUST_VERSION"*) ;;
    *) echo "Unexpected cargo version: $cargo_version" >&2; exit 1 ;;
esac

mkdir -p "$WORK_DIR/pngquant-source"
tar -xzf "$ARCHIVE_DIR/pngquant.crate" -C "$WORK_DIR/pngquant-source"
PNGQUANT_SOURCE="$WORK_DIR/pngquant-source/pngquant-${PNGQUANT_VERSION}"

grep -q "\"sha1\": \"$PNGQUANT_CRATE_COMMIT\"" \
    "$PNGQUANT_SOURCE/.cargo_vcs_info.json"
grep -q "version = \"$PNGQUANT_VERSION\"" "$PNGQUANT_SOURCE/Cargo.toml"

# A minimal pkg-config-compatible adapter directs libpng-sys to the per-slice
# static libpng archive. It deliberately refuses every other package, so
# libz-sys uses the macOS SDK's system libz instead of its old vendored zlib.
PKG_CONFIG_WRAPPER="$WORK_DIR/lithe-pkg-config"
cat >"$PKG_CONFIG_WRAPPER" <<'EOF'
#!/bin/sh
package=""
mode="flags"
for argument in "$@"; do
    case "$argument" in
        libpng) package="libpng" ;;
        --modversion) mode="version" ;;
    esac
done

[ "$package" = "libpng" ] || exit 1
if [ "$mode" = "version" ]; then
    printf '%s\n' "1.6.58"
else
    printf '%s\n' "-I${LITHE_LIBPNG_PREFIX}/include -L${LITHE_LIBPNG_PREFIX}/lib -lpng16 -lz"
fi
EOF
chmod +x "$PKG_CONFIG_WRAPPER"

for arch in arm64 x86_64; do
    ARCH_DIR="$WORK_DIR/$arch"
    PREFIX="$ARCH_DIR/prefix"
    mkdir -p "$ARCH_DIR/source" "$PREFIX/include" "$PREFIX/lib"
    tar -xzf "$ARCHIVE_DIR/libpng.tar.gz" -C "$ARCH_DIR/source"
    tar -xzf "$ARCHIVE_DIR/lcms2.tar.gz" -C "$ARCH_DIR/source"

    case "$arch" in
        arm64)
            host_triple="aarch64-apple-darwin"
            rust_target="aarch64-apple-darwin"
            ;;
        x86_64)
            host_triple="x86_64-apple-darwin"
            rust_target="x86_64-apple-darwin"
            ;;
    esac

    target_key=$(printf '%s' "$rust_target" | tr '-' '_')
    target_upper=$(printf '%s' "$target_key" | tr '[:lower:]' '[:upper:]')
    arch_flags="-arch $arch -isysroot $SDKROOT -mmacosx-version-min=$MACOS_MIN_VERSION"

    run_logged \
        "Building libpng $LIBPNG_VERSION for $arch" \
        "$ARCH_DIR/libpng.log" \
        /bin/bash -c '
            set -e
            cd "$1"
            env \
                CC=/usr/bin/clang \
                CXX=/usr/bin/clang++ \
                AR=/usr/bin/ar \
                RANLIB=/usr/bin/ranlib \
                CFLAGS="$2 -O3" \
                LDFLAGS="$2" \
                MACOSX_DEPLOYMENT_TARGET="$3" \
                ./configure \
                    --host="$4" \
                    --disable-dependency-tracking \
                    --disable-shared \
                    --enable-static \
                    --prefix="$5"
            make -j"$6" libpng16.la
            cp .libs/libpng16.a "$5/lib/libpng16.a"
            cp png.h pngconf.h pnglibconf.h "$5/include/"
            /usr/bin/ranlib "$5/lib/libpng16.a"
        ' _ \
        "$ARCH_DIR/source/libpng-$LIBPNG_VERSION" \
        "$arch_flags" \
        "$MACOS_MIN_VERSION" \
        "$host_triple" \
        "$PREFIX" \
        "$MAKE_JOBS"

    run_logged \
        "Building Little CMS $LCMS_VERSION for $arch" \
        "$ARCH_DIR/lcms2.log" \
        /bin/bash -c '
            set -e
            cd "$1"
            env \
                CC=/usr/bin/clang \
                CXX=/usr/bin/clang++ \
                AR=/usr/bin/ar \
                RANLIB=/usr/bin/ranlib \
                CFLAGS="$2 -O3" \
                LDFLAGS="$2" \
                MACOSX_DEPLOYMENT_TARGET="$3" \
                ./configure \
                    --host="$4" \
                    --disable-dependency-tracking \
                    --disable-shared \
                    --enable-static \
                    --without-jpeg \
                    --without-tiff \
                    --prefix="$5"
            make -C src -j"$6"
            cp src/.libs/liblcms2.a "$5/lib/liblcms2.a"
            cp include/lcms2.h include/lcms2_plugin.h "$5/include/"
            /usr/bin/ranlib "$5/lib/liblcms2.a"
        ' _ \
        "$ARCH_DIR/source/lcms2-$LCMS_VERSION" \
        "$arch_flags" \
        "$MACOS_MIN_VERSION" \
        "$host_triple" \
        "$PREFIX" \
        "$MAKE_JOBS"

    lipo "$PREFIX/lib/libpng16.a" -verify_arch "$arch"
    lipo "$PREFIX/lib/liblcms2.a" -verify_arch "$arch"

    run_logged \
        "Building pngquant $PNGQUANT_VERSION for $arch" \
        "$ARCH_DIR/pngquant.log" \
        env \
            PATH="$RUST_ROOT/bin:/usr/bin:/bin" \
            CARGO_HOME="$CARGO_HOME_DIR" \
            CARGO_TARGET_DIR="$CARGO_TARGET_DIR" \
            CARGO_INCREMENTAL=0 \
            CARGO_NET_RETRY=5 \
            CARGO_HTTP_TIMEOUT=120 \
            CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
            SDKROOT="$SDKROOT" \
            MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
            "CC_${target_key}=/usr/bin/clang" \
            "CFLAGS_${target_key}=$arch_flags -O3" \
            "CARGO_TARGET_${target_upper}_LINKER=/usr/bin/clang" \
            "CARGO_TARGET_${target_upper}_RUSTFLAGS=-C link-arg=-arch -C link-arg=$arch -C link-arg=-isysroot -C link-arg=$SDKROOT -C link-arg=-mmacosx-version-min=$MACOS_MIN_VERSION --remap-path-prefix=$WORK_DIR=/usr/src/lithe-pngquant" \
            PKG_CONFIG="$PKG_CONFIG_WRAPPER" \
            PKG_CONFIG_ALLOW_CROSS=1 \
            LITHE_LIBPNG_PREFIX="$PREFIX" \
            LCMS2_LIB_DIR="$PREFIX/lib" \
            LCMS2_INCLUDE_DIR="$PREFIX/include" \
            SOURCE_DATE_EPOCH=1702931226 \
            "$RUST_ROOT/bin/cargo" build \
                --manifest-path "$PNGQUANT_SOURCE/Cargo.toml" \
                --release \
                --locked \
                --target "$rust_target" \
                --no-default-features \
                --features lcms2

    cp "$CARGO_TARGET_DIR/$rust_target/release/pngquant" "$ARCH_DIR/pngquant"
    /usr/bin/strip -S -x "$ARCH_DIR/pngquant"
    lipo "$ARCH_DIR/pngquant" -verify_arch "$arch"
done

lipo -create \
    "$WORK_DIR/arm64/pngquant" \
    "$WORK_DIR/x86_64/pngquant" \
    -output "$STAGE_DIR/bin/pngquant"
chmod 0755 "$STAGE_DIR/bin/pngquant"
lipo "$STAGE_DIR/bin/pngquant" -verify_arch arm64 x86_64

for arch in arm64 x86_64; do
    minos=$(otool -l -arch "$arch" "$STAGE_DIR/bin/pngquant" | \
        awk '/cmd LC_BUILD_VERSION/{found=1; next} found && $1=="minos"{print $2; exit}')
    uuid=$(otool -l -arch "$arch" "$STAGE_DIR/bin/pngquant" | \
        awk '/cmd LC_UUID/{found=1; next} found && $1=="uuid"{print $2; exit}')
    if [ "$minos" != "$MACOS_MIN_VERSION" ] || [ -z "$uuid" ]; then
        echo "Invalid $arch Mach-O metadata: minos=$minos uuid=$uuid" >&2
        exit 1
    fi
done

while IFS= read -r dependency; do
    case "$dependency" in
        /usr/lib/*|/System/Library/*) ;;
        *)
            echo "Unexpected non-system dynamic dependency: $dependency" >&2
            exit 1
            ;;
    esac
done < <(otool -L "$STAGE_DIR/bin/pngquant" | awk '/^\t/{print $1}' | sort -u)

lipo "$STAGE_DIR/bin/pngquant" -thin arm64 -output "$WORK_DIR/pngquant-arm64"
lipo "$STAGE_DIR/bin/pngquant" -thin x86_64 -output "$WORK_DIR/pngquant-x86_64"
arm_version=$("$WORK_DIR/pngquant-arm64" --version)
x86_version=$(/usr/bin/arch -x86_64 "$WORK_DIR/pngquant-x86_64" --version)
if [ "$arm_version" != "$PNGQUANT_VERSION" ] || [ "$x86_version" != "$PNGQUANT_VERSION" ]; then
    echo "Slice version mismatch: arm64=$arm_version x86_64=$x86_version" >&2
    exit 1
fi

# Exercise the final universal binary on a real RGB PNG and require a smaller,
# decodable, dimension-preserving indexed PNG result.
TEST_DIR="$WORK_DIR/real-png-test"
mkdir -p "$TEST_DIR"
awk 'BEGIN {
    print "P3"; print "1024 1024"; print "255";
    for (y=0; y<1024; y++) for (x=0; x<1024; x++) {
        r=int(x/64)%16*17;
        g=int(y/64)%16*17;
        b=(int(x/64)+int(y/64))%16*17;
        print r, g, b;
    }
}' >"$TEST_DIR/input.ppm"
sips -s format png "$TEST_DIR/input.ppm" --out "$TEST_DIR/input.png" >/dev/null
"$STAGE_DIR/bin/pngquant" \
    --force \
    --quality=80-100 \
    --speed 4 \
    --output "$TEST_DIR/output.png" \
    "$TEST_DIR/input.png"

input_width=$(sips -g pixelWidth "$TEST_DIR/input.png" | awk '/pixelWidth/{print $2}')
input_height=$(sips -g pixelHeight "$TEST_DIR/input.png" | awk '/pixelHeight/{print $2}')
output_width=$(sips -g pixelWidth "$TEST_DIR/output.png" | awk '/pixelWidth/{print $2}')
output_height=$(sips -g pixelHeight "$TEST_DIR/output.png" | awk '/pixelHeight/{print $2}')
input_bytes=$(stat -f '%z' "$TEST_DIR/input.png")
output_bytes=$(stat -f '%z' "$TEST_DIR/output.png")
if [ "$input_width" != "$output_width" ] || \
   [ "$input_height" != "$output_height" ] || \
   [ "$output_bytes" -ge "$input_bytes" ]; then
    echo "Real PNG validation failed." >&2
    exit 1
fi

cp "$PNGQUANT_SOURCE/COPYRIGHT" \
    "$STAGE_DIR/licenses/pngquant-COPYRIGHT.txt"
cp "$PNGQUANT_SOURCE/Cargo.lock" \
    "$STAGE_DIR/licenses/pngquant-Cargo.lock"
cp "$WORK_DIR/arm64/source/libpng-$LIBPNG_VERSION/LICENSE" \
    "$STAGE_DIR/licenses/pngquant-libpng-LICENSE.txt"
cp "$WORK_DIR/arm64/source/lcms2-$LCMS_VERSION/LICENSE" \
    "$STAGE_DIR/licenses/pngquant-lcms2-LICENSE.txt"

{
    echo "Rust dependency license bundle for pngquant $PNGQUANT_VERSION"
    echo "Exact dependency versions and crate checksums are in pngquant-Cargo.lock."
    echo
    find "$CARGO_HOME_DIR/registry/src" -mindepth 2 -maxdepth 2 -type d | sort | \
    while IFS= read -r crate_dir; do
        crate_name=$(basename "$crate_dir")
        echo "================================================================================"
        echo "$crate_name"
        license_expression=$(awk -F' = ' '/^license = /{print $2; exit}' "$crate_dir/Cargo.toml" 2>/dev/null || true)
        if [ -n "$license_expression" ]; then
            echo "Cargo license expression: $license_expression"
        fi
        echo
        find "$crate_dir" -maxdepth 1 -type f \
            \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' \) | sort | \
        while IFS= read -r license_file; do
            echo "--- $(basename "$license_file") ---"
            cat "$license_file"
            echo
        done
    done
} >"$STAGE_DIR/licenses/pngquant-DEPENDENCY-LICENSES.txt"

cat >"$STAGE_DIR/licenses/pngquant-SOURCE-MANIFEST.txt" <<EOF
pngquant universal macOS vendor build provenance
================================================

Built artifact: pngquant $PNGQUANT_VERSION for arm64 + x86_64, macOS $MACOS_MIN_VERSION+

pngquant official crates.io distribution
URL: $PNGQUANT_URL
SHA-256: $PNGQUANT_CRATE_SHA256
Published crate VCS commit: $PNGQUANT_CRATE_COMMIT
Same-version Git tag object: $PNGQUANT_TAG_OBJECT
Same-version Git tag target: $PNGQUANT_TAG_COMMIT
Note: the official crate was published from a later MSRV-fix commit than the
same-version Git tag. This build uses the checksummed crates.io distribution.

libpng official source
Version: $LIBPNG_VERSION
URL: $LIBPNG_URL
SHA-256: $LIBPNG_SHA256
Verified Git tag object: $LIBPNG_TAG_OBJECT
Git tag target: $LIBPNG_TAG_COMMIT

Little CMS official release asset
Version: $LCMS_VERSION
URL: $LCMS_URL
SHA-256: $LCMS_SHA256
Git tag target: $LCMS_TAG_COMMIT

Official Rust toolchain
Version: $RUST_VERSION
Manifest: https://static.rust-lang.org/dist/channel-rust-$RUST_VERSION.toml
Manifest SHA-256: $RUST_MANIFEST_SHA256
rustc arm64 SHA-256: $RUSTC_SHA256
cargo arm64 SHA-256: $CARGO_SHA256
rust-std arm64 SHA-256: $RUST_STD_ARM64_SHA256
rust-std x86_64 SHA-256: $RUST_STD_X86_64_SHA256

Rust dependencies
The byte-for-byte upstream Cargo.lock is stored as pngquant-Cargo.lock.
Cargo --locked verifies every downloaded crates.io archive against the checksum
in that lockfile. Crate source URL pattern:
https://static.crates.io/crates/{name}/{name}-{version}.crate

Linkage decisions
- libpng $LIBPNG_VERSION: statically linked from official source above.
- Little CMS $LCMS_VERSION: statically linked from official source above.
- libpng-sys 1.1.9: Rust FFI wrapper only; its bundled libpng 1.6.37 is not built.
- libz-sys 1.1.12: Rust FFI wrapper only; its bundled zlib is not built.
- zlib and iconv: macOS system dynamic libraries.
EOF

mkdir -p "$PROJECT_DIR/Vendor/bin" "$PROJECT_DIR/Vendor/licenses"
/usr/bin/install -m 0755 \
    "$STAGE_DIR/bin/pngquant" \
    "$PROJECT_DIR/Vendor/bin/pngquant"
for license_file in "$STAGE_DIR/licenses"/pngquant-*; do
    /usr/bin/install -m 0644 "$license_file" "$PROJECT_DIR/Vendor/licenses/"
done

echo
file "$PROJECT_DIR/Vendor/bin/pngquant"
lipo -info "$PROJECT_DIR/Vendor/bin/pngquant"
otool -L "$PROJECT_DIR/Vendor/bin/pngquant"
for arch in arm64 x86_64; do
    echo "$arch metadata:"
    otool -l -arch "$arch" "$PROJECT_DIR/Vendor/bin/pngquant" | \
        awk '/cmd LC_UUID/{uuid=1; next} uuid && $1=="uuid"{print "  uuid " $2; uuid=0} /cmd LC_BUILD_VERSION/{build=1; next} build && $1=="minos"{print "  minos " $2; exit}'
done
printf 'arm64 version: %s\n' "$arm_version"
printf 'x86_64 version: %s\n' "$x86_version"
printf 'real PNG: %s -> %s bytes\n' "$input_bytes" "$output_bytes"
shasum -a 256 "$PROJECT_DIR/Vendor/bin/pngquant"
