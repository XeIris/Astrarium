#!/bin/sh
# Attribute engine errors to the preset being rendered; reject incomplete runs.
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOG=${1:-/tmp/presetcheck.log}
"$G" --path "$HERE" --resolution 960x540 -- mode=sandbox eval=_preset_check >"$LOG" 2>&1
status=$?
awk '
  /PRESETCHECK BEGIN/ {k=$3; begins++; if(active) bad=1; active=k}
  /PRESETCHECK END/ {ends++; if($3 != active) bad=1; active=""}
  /(^|[[:space:]])(SCRIPT ERROR|SHADER ERROR|ERROR):/ {
    n[k]++; if(!(k in first)) first[k]=$0
  }
  /PRESETCHECK (ROWS|LOST|DONE)/ {print}
  /^PRESETCHECK LOST / {lost++; if($0 != "PRESETCHECK LOST []") bad=1}
  /^PRESETCHECK DONE / {done++; expected=$3}
  END {
    for(k in n) {print "ERRORS " k ": " n[k] "  (first: " first[k] ")"; bad=1}
    if(done != 1 || lost != 1 || begins < 1 || begins != ends || begins != expected || active != "") {
      print "PRESETCHECK FAILED: incomplete or malformed run"; bad=1
    }
    exit bad
  }' "$LOG"
report_status=$?
if [ "$status" -ne 0 ]; then
  echo "PRESETCHECK FAILED: Godot exited $status (log: $LOG)"
  exit "$status"
fi
exit "$report_status"
