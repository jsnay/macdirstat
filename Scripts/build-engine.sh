#!/bin/sh
# Build the dirstat-core Rust static library and stage it for SwiftPM.
#
# Usage: Scripts/build-engine.sh [path-to-dirstat-core-checkout]
# Default checkout location: ../dirstat-core (sibling of this repo).
set -eu

APP_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CORE_DIR=${1:-${DIRSTAT_CORE_DIR:-"$APP_ROOT/../dirstat-core"}}

if [ ! -f "$CORE_DIR/Cargo.toml" ]; then
    echo "error: dirstat-core checkout not found at $CORE_DIR" >&2
    echo "       clone https://github.com/jsnay/dirstat-core next to this repo," >&2
    echo "       or pass its path: Scripts/build-engine.sh /path/to/dirstat-core" >&2
    exit 1
fi

# Header pin (APP-FFI-6 / CORE-FFI-SAFE-3): the checked-in header must match
# the engine we are about to link, or the build fails here.
if ! diff -q "$APP_ROOT/Sources/CDirstatCore/include/dirstat_core.h" \
             "$CORE_DIR/include/dirstat_core.h" >/dev/null 2>&1; then
    echo "error: Sources/CDirstatCore/include/dirstat_core.h differs from" >&2
    echo "       $CORE_DIR/include/dirstat_core.h" >&2
    echo "       Re-pin it (copy the engine header in and commit) before building." >&2
    exit 1
fi

echo "Building dirstat-core (release) from $CORE_DIR"
ARCH=$(uname -m)
case "$ARCH" in
    arm64) TARGET=aarch64-apple-darwin ;;
    x86_64) TARGET=x86_64-apple-darwin ;;
    *) TARGET="" ;;
esac

mkdir -p "$APP_ROOT/.lib"
if [ -n "$TARGET" ] && [ "$(uname -s)" = "Darwin" ]; then
    (cd "$CORE_DIR" && cargo build --release --target "$TARGET")
    cp "$CORE_DIR/target/$TARGET/release/libdirstat_core.a" "$APP_ROOT/.lib/"
else
    (cd "$CORE_DIR" && cargo build --release)
    cp "$CORE_DIR/target/release/libdirstat_core.a" "$APP_ROOT/.lib/"
fi
echo "Staged $APP_ROOT/.lib/libdirstat_core.a"
