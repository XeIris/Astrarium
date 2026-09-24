#!/bin/sh
# The physics-core comparison, end to end:
#   godot/tools/physcheck.sh [outdir]
# web build → ref.json (physref.mjs), Godot port → gd.json (physcheck.gd),
# then the per-section relative-error table (physdiff.mjs).
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${TMPDIR:-/tmp}/physcheck}
mkdir -p "$out"
godot=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
node "$here/physref.mjs" ref "$out/ref.json"
"$godot" --headless --quit-after 100000 --path "$here/.." --script res://tools/physcheck.gd -- \
  mode=ref in="$out/ref.json" out="$out/gd.json" 2>&1 | grep -v '^Godot Engine' || true
node "$here/physdiff.mjs" "$out/ref.json" "$out/gd.json"
