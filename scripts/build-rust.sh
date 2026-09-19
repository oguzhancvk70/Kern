#!/bin/sh
# kern-ffi staticlib'ini derler, Xcode ARCHS için lipo ile birleştirir
set -eu
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"

PROFILE=debug
FLAG=""
if [ "${CONFIGURATION:-Debug}" = "Release" ]; then
  PROFILE=release
  FLAG="--release"
fi

LIBS=""
for ARCH in ${ARCHS:-$(uname -m)}; do
  case "$ARCH" in
    arm64) TRIPLE=aarch64-apple-darwin ;;
    x86_64) TRIPLE=x86_64-apple-darwin ;;
    *) echo "desteklenmeyen mimari: $ARCH" >&2; exit 1 ;;
  esac
  cargo build -p kern-ffi -p kern $FLAG --target "$TRIPLE"
  LIBS="$LIBS target.nosync/$TRIPLE/$PROFILE/libkern_ffi.a"
  BINS="${BINS:-} target.nosync/$TRIPLE/$PROFILE/kern"
done

OUT="target.nosync/universal/$PROFILE"
mkdir -p "$OUT"
lipo -create $LIBS -output "$OUT/libkern_ffi.a"
lipo -create $BINS -output "$OUT/kern"
