#!/bin/sh
# Render dumped star references: WEBDIR OUTDIR [names...].
HERE=$(cd "$(dirname "$0")" && pwd)
exec python3 "$HERE/reference_shots.py" stars "$@"
