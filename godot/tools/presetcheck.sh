#!/bin/sh
# Run main.gd's _preset_check and attribute every script/shader error to the
# preset that was loading when it printed. Exit status 1 if anything failed.
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOG=${1:-/tmp/presetcheck.log}
$G --path "$HERE" --resolution 960x540 -- mode=sandbox eval=_preset_check >"$LOG" 2>&1
awk '/PRESETCHECK BEGIN/{k=$3} /SCRIPT ERROR|SHADER ERROR/{n[k]++; if(!(k in first)) first[k]=$0}
     /PRESETCHECK (ROWS|LOST|DONE)/{print}
     END{bad=0; for (k in n){print "ERRORS " k ": " n[k] "  (first: " first[k] ")"; bad=1}; exit bad}' "$LOG"
