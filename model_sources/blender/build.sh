#!/usr/bin/env bash
# Build the authored craft and launchpad models.
#
#   model_sources/blender/build.sh                  9 vehicles, 4 pads and the facilities
#   model_sources/blender/build.sh shuttle pad_fss  selected models
#
# The .py files are the models; the .glb output in assets/craft/ and assets/pads/ is
# ignored build artifacts loaded directly by Godot. A
# fresh clone uses procedural fallbacks until this has run. lib.py and common.py
# aren't models. Vehicle ids in ALL match craftassets.gd; pad_* use launchpads.py.
#
# Blender is often off PATH (e.g. under Steam), so `which blender` proves nothing.
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

# The override is checked first and skips the search. BLENDER_OVERRIDE is accepted
# too (documented in model_sources/blender/AGENTS.md).
BLENDER="${BLENDER:-${BLENDER_OVERRIDE:-}}"
if [ -z "$BLENDER" ]; then
  BLENDER="$(find_blender)" || {
    echo "error: no Blender found." >&2
    echo "  Looked on PATH, in /Applications and ~/Applications, under Steam, and in Spotlight." >&2
    echo "  Any Blender 4.1+ works. Set BLENDER=/path/to/Blender to override." >&2
    exit 1
  }
fi
echo "blender: $BLENDER"
"$BLENDER" --version | head -1

ALL=(saturnv falcon9 shuttle starship lm skycrane ioncruiser hailmary beetle pad_lut pad_fss pad_strongback pad_chopsticks facilities)
if [ "$#" -gt 0 ]; then MODELS=("$@"); else MODELS=("${ALL[@]}"); fi
craft_spec="$(mktemp "${TMPDIR:-/tmp}/astrarium-craft-spec.XXXXXX")"
trap 'rm -f "$craft_spec"' EXIT
for m in "${MODELS[@]}"; do
  if [[ "$m" != pad_* && "$m" != facilities ]]; then
    GODOT="${GODOT:-$(command -v godot || true)}"
    if [ -z "$GODOT" ] && [ -x /Applications/Godot.app/Contents/MacOS/Godot ]; then
      GODOT=/Applications/Godot.app/Contents/MacOS/Godot
    fi
    [ -n "$GODOT" ] || { echo "error: set GODOT to export runtime vehicle dimensions" >&2; exit 1; }
    "$GODOT" --headless --path . --import --quit
    "$GODOT" --headless --path . --script res://tools/craftspec.gd -- "$craft_spec"
    break
  fi
done
export ASTRARIUM_CRAFT_SPEC="$craft_spec"
for m in "${MODELS[@]}"; do
  extra=()
  if [[ "$m" == pad_* ]]; then
    script="model_sources/blender/launchpads.py"
    extra=(--style "${m#pad_}")
    dst="assets/pads/${m}.glb"
  elif [[ "$m" == facilities ]]; then
    script="model_sources/blender/facilities.py"
    dst="assets/pads/facilities.glb"
  else
    script="model_sources/blender/${m}.py"
    dst="assets/craft/${m}.glb"
  fi
  [ -f "$script" ] || { echo "error: no such model '$m' ($script)" >&2; exit 1; }
  echo "--- building $m"
  # Blender is chatty on export; keep the lines that say what was made.
  # Write beside the published artifact and replace it only after a successful
  # build. A Blender crash must not remove a previously working model.
  mkdir -p "$(dirname "$dst")"
  tmp="$(dirname "$dst")/.${m}.build.glb"
  rm -f "$tmp"
  set +e
  "$BLENDER" --background --python "$script" -- ${extra[@]+"${extra[@]}"} --out "$tmp" 2>&1 \
    | grep -E '^\[|Error|Traceback|line [0-9]+, in'
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" -eq 0 ] || { rm -f "$tmp"; echo "error: blender failed on $m (exit $status)" >&2; exit 1; }
  [ -f "$tmp" ] || { echo "error: $m produced no .glb" >&2; exit 1; }
  mv "$tmp" "$dst"
done

echo "--- built ${#MODELS[@]} model(s)"
