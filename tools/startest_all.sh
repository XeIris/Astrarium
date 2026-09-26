#!/bin/sh
# Render every dumped web reference in $1 (webref.mjs output) through
# tools/startest.tscn into $2, one Godot process per shot, and print the
# harness's CHECK lines.   tools/startest_all.sh <webdir> <outdir> [names…]
GODOT=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE=$(cd "$(dirname "$0")/.." && pwd)
WEB=$1; OUT=$2; shift 2
mkdir -p "$OUT"
NAMES=${*:-$(cd "$WEB" && ls *.json | sed 's/\.json$//')}
for n in $NAMES; do
  rm -f "$OUT/$n.png"
  "$GODOT" --path "$HERE" res://tools/startest.tscn -- state="$WEB/$n.json" out="$OUT/$n.png" frames=8 \
    > "$OUT/$n.log" 2>&1
  echo "== $n $( [ -f "$OUT/$n.png" ] && echo ok || echo FAILED)"
  grep -E "CHECK DIFF|SHADER ERROR|SCRIPT ERROR|ERROR:" "$OUT/$n.log" | grep -v "leaked\|ObjectDB\|still in use" | head -20
done
