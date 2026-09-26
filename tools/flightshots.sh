#!/bin/sh
# ============================================================================
# FLIGHT SHOTS, both builds — every scenario in tools/flight_scenarios.json (or
# the comma list given), flown by the REAL orchestrator in Godot (one process
# per scenario, as the web side replays each shot from a fresh page) and by the
# web build through webref.mjs.
#
#   tools/flightshots.sh /abs/outdir [scen,scen] [godot|web]
#
# writes outdir/godot/<shot>.png (+ .hud.png, .json) and outdir/web/<shot>.png
# (+ .bare.png, .json). The web side needs a checkout with assets/*.glb:
# WEB_ROOT (default: the main checkout this worktree hangs off).
# ============================================================================

OUT=${1:?outdir}
HERE=$(cd "$(dirname "$0")/.." && pwd)
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
SCENS=${2:-$(python3 -c "import json;print(','.join(json.load(open('$HERE/tools/flight_scenarios.json'))['scenarios']))")}
SEED=$(python3 -c "import json;print(json.load(open('$HERE/tools/flight_scenarios.json'))['seed'])")
WHICH=${3:-both}
mkdir -p "$OUT/godot" "$OUT/web"
if [ "$WHICH" != godot ]; then
  node "$HERE/tools/flightshots.mjs" "$SCENS" > "$OUT/web/shots.json"
  PORT=${PORT:-8831} WEB_ROOT=${WEB_ROOT:-$HERE/web} \
    node "$HERE/tools/webref.mjs" "$OUT/web/shots.json" "$OUT/web/" > "$OUT/web/log.txt" 2>&1 &
fi
if [ "$WHICH" != web ]; then
  for s in $(echo "$SCENS" | tr ',' ' '); do
    "$G" --path "$HERE" --resolution 1280x720 res://tools/flighttest.tscn -- \
      preset=solar seed=$SEED mode=flight scen=$s out="$OUT/godot/" > "$OUT/godot/$s.log" 2>&1
    grep "flighttest:\|SCRIPT ERROR\|SHADER ERROR" "$OUT/godot/$s.log" || true
  done
fi
wait
