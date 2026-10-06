#!/bin/sh
# Capture both flight builds: OUTDIR [scenarios] [both|godot|web].
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/reference_shots.py" flight "$@"
