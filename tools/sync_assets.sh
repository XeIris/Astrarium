#!/bin/sh
# Import separately built vehicle meshes; the local Blender build needs no copy.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HERE/../assets/craft}"
DST="$HERE/../assets/craft"
mkdir -p "$DST"
SRC="$(cd "$SRC" && pwd -P)"
DST="$(cd "$DST" && pwd -P)"
n=0
for f in "$SRC"/*.glb; do
  [ -e "$f" ] || continue
  if [ "$SRC" != "$DST" ]; then cp "$f" "$DST/"; fi
  n=$((n + 1))
done
echo "synced $n vehicle mesh(es) from $SRC into $DST"
