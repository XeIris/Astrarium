#!/bin/sh
# Copy the authored vehicle meshes into the Godot project.
#
# assets/*.glb are BUILD ARTIFACTS of assets/blender/*.py (run
# assets/blender/build.sh) and are gitignored, in the web build and here alike.
# The Godot port loads them at runtime from res://assets/craft/ and falls back
# to its procedural builds when they are missing — a missing asset is not an
# error (CLAUDE.md). Pass a different source directory as $1 if the meshes live
# in another checkout.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/../../assets}"
DST="$HERE/../assets/craft"
mkdir -p "$DST"
n=0
for f in "$SRC"/*.glb; do
  [ -e "$f" ] || continue
  cp "$f" "$DST/"
  n=$((n + 1))
done
echo "synced $n vehicle mesh(es) from $SRC into $DST"
