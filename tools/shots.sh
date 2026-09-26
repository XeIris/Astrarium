#!/bin/sh
# Run the orchestrator's screenshot mode for a list of shots, one process each.
#   tools/shots.sh OUTDIR "name|arg arg ..." "name|arg ..." ...
# e.g. tools/shots.sh /tmp/o "vega5|preset=vega band=5 frames=60 hud=0"
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; shift
mkdir -p "$OUT"
for spec in "$@"; do
  name="${spec%%|*}"; args="${spec#*|}"
  $G --path "$HERE" --resolution ${RES:-1280x720} -- $args out="$OUT/$name.png" >"$OUT/$name.log" 2>&1 &
  pid=$!
  i=0; while kill -0 $pid 2>/dev/null && [ $i -lt ${TIMEOUT:-60} ]; do sleep 1; i=$((i+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  errs=$(grep -c "SCRIPT ERROR\|SHADER ERROR" "$OUT/$name.log")
  [ -f "$OUT/$name.png" ] && echo "ok   $name (errors: $errs)" || echo "FAIL $name (errors: $errs)"
done
