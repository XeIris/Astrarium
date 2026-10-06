#!/bin/sh
# Disable contraction and fast math to preserve the GDScript operation order.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/bin"
case "$(uname -s)" in
  Darwin)
    OUTPUT="$HERE/bin/libastrarium_native.dylib"
    set -- -dynamiclib -arch arm64 -arch x86_64 -mmacosx-version-min=11.0
    ;;
  Linux)
    case "$(uname -m)" in
      x86_64) ARCH=x86_64 ;;
      aarch64|arm64) ARCH=arm64 ;;
      *) echo "Unsupported Linux architecture" >&2; exit 1 ;;
    esac
    OUTPUT="$HERE/bin/libastrarium_native.linux.$ARCH.so"
    set -- -shared -fPIC
    ;;
  MINGW*|MSYS*)
    case "$(uname -m)" in
      x86_64) ;;
      *) echo "Windows native build requires x86_64 MinGW-w64" >&2; exit 1 ;;
    esac
    OUTPUT="$HERE/bin/astrarium_native.windows.x86_64.dll"
    set -- -shared -static-libgcc
    ;;
  *) echo "Unsupported build platform: $(uname -s)" >&2; exit 1 ;;
esac
"${CC:-cc}" -O2 -ffp-contract=off -fno-fast-math -std=c11 -Wall -Wextra -Wno-unused-parameter \
   "$@" -I"$HERE" "$HERE/astrarium_native.c" -lm -o "$OUTPUT"
if [ "$(uname -s)" = Darwin ]; then codesign --force -s - "$OUTPUT"; fi
echo "built $OUTPUT"
