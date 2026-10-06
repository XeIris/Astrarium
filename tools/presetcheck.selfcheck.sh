#!/bin/sh
# Exercise the wrapper's failure contract without starting the renderer.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/presetcheck-self.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT HUP INT TERM
cat > "$task_tmp/godot" <<'FAKE'
#!/bin/sh
if [ "$CHECK_CASE" = missing ]; then exit 0; fi
printf '%s\n' 'PRESETCHECK BEGIN solar'
case "$CHECK_CASE" in
  script) printf '%s\n' 'SCRIPT ERROR: test failure' ;;
  shader) printf '%s\n' 'SHADER ERROR: test failure' ;;
  engine) printf '%s\n' 'ERROR: test failure' ;;
  incomplete) exit 0 ;;
esac
printf '%s\n' 'PRESETCHECK END solar' 'PRESETCHECK ROWS solar: 9->9'
if [ "$CHECK_CASE" = lost ]; then
  printf '%s\n' 'PRESETCHECK LOST ["solar: lost one body"]'
else
  printf '%s\n' 'PRESETCHECK LOST []'
fi
if [ "$CHECK_CASE" = count ]; then
  printf '%s\n' 'PRESETCHECK DONE 2'
else
  printf '%s\n' 'PRESETCHECK DONE 1'
fi
if [ "$CHECK_CASE" = child ]; then exit 37; fi
FAKE
chmod +x "$task_tmp/godot"
for check_case in good child missing incomplete lost script shader engine count; do
  status=0
  CHECK_CASE="$check_case" GODOT="$task_tmp/godot" sh "$here/presetcheck.sh" "$task_tmp/log" >"$task_tmp/report" 2>&1 || status=$?
  if [ "$check_case" = good ]; then
    [ "$status" -eq 0 ] || { cat "$task_tmp/report"; exit 1; }
  else
    [ "$status" -ne 0 ] || { echo "SELF-CHECK FAIL: accepted $check_case"; exit 1; }
  fi
  if [ "$check_case" = child ]; then [ "$status" -eq 37 ]; fi
  echo "SELF-CHECK PASS $check_case"
done
