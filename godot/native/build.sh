#!/bin/sh
# Build the native N-body kernel (see astrarium_native.c for why it exists).
# One compiler line, no build system: needs only Xcode's command line tools
# (`xcode-select --install`). Produces a universal (arm64 + x86_64) dylib so an
# exported macOS build runs on both Apple silicon and Intel Macs.
#
# -ffp-contract=off is load-bearing: it forbids fusing a*b+c into one rounding,
# which V8 never does, and the port promises the same sub-steps as the web build.
#
# The dylib is committed prebuilt, so none of this is needed to RUN the project;
# rebuild only after editing astrarium_native.c. Regenerate the header with
#   Godot --headless --dump-gdextension-interface   (after a Godot upgrade).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/bin"
cc -O2 -ffp-contract=off -fno-fast-math -std=c11 -Wall -Wextra -Wno-unused-parameter -Wno-cast-function-type-mismatch \
   -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
   -I"$HERE" "$HERE/astrarium_native.c" \
   -o "$HERE/bin/libastrarium_native.dylib"
codesign --force -s - "$HERE/bin/libastrarium_native.dylib" >/dev/null 2>&1 || true
echo "built $HERE/bin/libastrarium_native.dylib"
