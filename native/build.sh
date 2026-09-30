#!/bin/sh
# Build the native N-body kernel (astrarium_native.c). One compiler line, Xcode
# command line tools only (`xcode-select --install`); a universal arm64 + x86_64
# dylib. -ffp-contract=off is load-bearing: no fused a*b+c, to keep the reference's
# rounding. The dylib is committed prebuilt; rebuild only after editing the C.
# Regenerate the header after a Godot upgrade with
#   Godot --headless --dump-gdextension-interface
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/bin"
cc -O2 -ffp-contract=off -fno-fast-math -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type-mismatch \
   -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
   -I"$HERE" "$HERE/astrarium_native.c" \
   -o "$HERE/bin/libastrarium_native.dylib"
codesign --force -s - "$HERE/bin/libastrarium_native.dylib" >/dev/null 2>&1 || true
echo "built $HERE/bin/libastrarium_native.dylib"
