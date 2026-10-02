#!/usr/bin/env python3
"""Validate a Godot --export-pack ZIP without relying on the source checkout."""
import re
import sys
from pathlib import Path
from zipfile import BadZipFile, ZipFile


def check(path: Path) -> int:
    failures = []
    with ZipFile(path) as archive:
        names = set(archive.namelist())
        for name in sorted(names):
            if name.startswith(("tools/", "web/", "model_sources/", "docs/", "build/")):
                failures.append(f"development resource: {name}")
            if name.endswith((".import", ".remap")):
                text = archive.read(name).decode("utf-8").rstrip("\0")
                for target in re.findall(r'^path="res://([^"\n]+)"', text, re.MULTILINE):
                    if target not in names:
                        failures.append(f"missing remapped resource: {name} -> {target}")
        for name in ("project.binary", "main.tscn.remap", "main.gd.remap",
                     ".godot/global_script_class_cache.cfg", "native/astrarium_native.gdextension"):
            if name not in names:
                failures.append(f"missing boot resource: {name}")
    for failure in failures:
        print(f"EXPORTCHECK FAIL {failure}", file=sys.stderr)
    print(f"EXPORTCHECK {'FAIL' if failures else 'PASS'}: {len(names)} entries, "
          f"{path.stat().st_size} bytes, {len(failures)} failures")
    return bool(failures)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: python3 tools/exportcheck.py /absolute/path/game.zip")
    try:
        sys.exit(check(Path(sys.argv[1])))
    except (OSError, ValueError, BadZipFile) as error:
        sys.exit(f"EXPORTCHECK FAIL: {error}")
