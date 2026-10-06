#!/bin/sh
# Capture course cards and live telemetry: OUTDIR [names...].
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/reference_shots.py" course "$@"
