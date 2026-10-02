#!/bin/sh
# The physics-core comparison, end to end:
#   tools/physcheck.sh [outdir]
# web build → ref.json (physref.mjs), Godot port → gd.json (physcheck.gd),
# then the per-section relative-error table (physdiff.mjs).
set -e
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-${TMPDIR:-/tmp}/physcheck}
mkdir -p "$out"
godot=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
node "$here/physref.mjs" ref "$out/ref.json"
# Never compare a previous run's output after a failed or interrupted process.
rm -f "$out/gd.json"
if "$godot" --headless --quit-after 100000 --path "$here/.." --script res://tools/physcheck.gd -- \
  mode=ref in="$out/ref.json" out="$out/gd.json" >"$out/godot.log" 2>&1; then
  cat "$out/godot.log"
else
  status=$?
  cat "$out/godot.log"
  exit "$status"
fi
if grep -Eq '(^|[[:space:]])(SCRIPT ERROR|SHADER ERROR|ERROR):' "$out/godot.log" || [ ! -s "$out/gd.json" ]; then
  echo "PHYSCHECK FAILED: engine error or missing output"
  exit 1
fi
node "$here/physdiff.mjs" "$out/ref.json" "$out/gd.json"
echo "PHYSCHECK COMPLETE: numeric differences are compatibility telemetry, not a physics correctness or parity pass."
