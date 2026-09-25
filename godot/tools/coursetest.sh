#!/bin/sh
# The Godot half of the course's side-by-side set: every shot in
# tools/course.shots.mjs's SHOTS, one coursetest.tscn process each.
#   tools/coursetest.sh OUTDIR [name ...]
# writes OUTDIR/<name>.png and OUTDIR/<name>.json (the instruments' numbers and
# the card's rect), to be held against webref.mjs's output for the same list.
G=${GODOT:-/Applications/Godot.app/Contents/MacOS/Godot}
HERE="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; shift
mkdir -p "$OUT"
node -e "import('$HERE/tools/course.shots.mjs').then(m => { for (const s of m.SHOTS) console.log(s.join(' ')) })" |
while read name key n frames; do
  if [ $# -gt 0 ]; then case " $* " in *" $name "*) ;; *) continue ;; esac; fi
  rm -f "$OUT/$name.png"
  $G --path "$HERE" --resolution 1280x720 res://tools/coursetest.tscn -- lesson=$key steps=$n cframes=$frames \
     cout="$OUT/$name.png" cdump="$OUT/$name.json" >"$OUT/$name.log" 2>&1 &
  pid=$!
  i=0; while kill -0 $pid 2>/dev/null && [ $i -lt ${TIMEOUT:-90} ]; do sleep 1; i=$((i+1)); done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  errs=$(grep -c "SCRIPT ERROR\|SHADER ERROR" "$OUT/$name.log")
  [ -f "$OUT/$name.png" ] && echo "ok   $name (errors: $errs)" || echo "FAIL $name (errors: $errs)"
done
