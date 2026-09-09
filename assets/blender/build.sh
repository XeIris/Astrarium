#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the authored craft models.
#
#   assets/blender/build.sh              build everything
#   assets/blender/build.sh hailmary     build one
#
# The .py files beside this one are the MODEL; assets/*.glb is a build artifact
# and is not in the repo. A fresh clone runs fine without it — buildHailMary
# falls back to its procedural build — but the ship is not the ship until this
# has been run once.
#
# Finding Blender is half the job: it is commonly installed somewhere that is
# not on PATH (through Steam, for one, which is where it is on the machine this
# was written on), so `which blender` finding nothing means nothing.
# ---------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/../.."                    # repo root

find_blender() {
  if command -v blender >/dev/null 2>&1; then command -v blender; return; fi
  local candidates=(
    "/Applications/Blender.app/Contents/MacOS/Blender"
    "$HOME/Applications/Blender.app/Contents/MacOS/Blender"
    "$HOME/Library/Application Support/Steam/steamapps/common/Blender/Blender.app/Contents/MacOS/Blender"
    "/usr/local/bin/blender" "/opt/homebrew/bin/blender"
  )
  for c in "${candidates[@]}"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
  if command -v mdfind >/dev/null 2>&1; then                 # macOS: ask Spotlight
    local app
    app="$(mdfind "kMDItemCFBundleIdentifier == 'org.blenderfoundation.blender'" 2>/dev/null | head -1)"
    [ -n "$app" ] && [ -x "$app/Contents/MacOS/Blender" ] && { echo "$app/Contents/MacOS/Blender"; return; }
  fi
  return 1
}

BLENDER="$(find_blender)" || {
  echo "error: no Blender found." >&2
  echo "  Looked on PATH, in /Applications and ~/Applications, under Steam, and in Spotlight." >&2
  echo "  Any Blender 4.1+ works. Set BLENDER=/path/to/Blender to override." >&2
  exit 1
}
BLENDER="${BLENDER_OVERRIDE:-${BLENDER}}"
echo "blender: $BLENDER"
"$BLENDER" --version | head -1

MODELS=("${@:-hailmary}")
for m in "${MODELS[@]}"; do
  script="assets/blender/${m}.py"
  [ -f "$script" ] || { echo "error: no such model '$m' ($script)" >&2; exit 1; }
  echo "--- building $m"
  # Blender is chatty on export; keep the lines that say what was made.
  "$BLENDER" --background --python "$script" -- --out "assets/${m}.glb" 2>&1 \
    | grep -E '^\[|Error|Traceback|line [0-9]+, in' || true
done
