#!/usr/bin/env python3
"""Place the target OS library beside an export pack for the native loader."""
from pathlib import Path
import shutil
import sys

LIBRARIES = {"macOS": "libastrarium_native.dylib", "Linux": "libastrarium_native.linux.x86_64.so",
             "Windows": "astrarium_native.windows.x86_64.dll"}

def main():
    archive, target = Path(sys.argv[1]), sys.argv[2]
    name = LIBRARIES[target]
    source = Path(__file__).resolve().parent.parent / "native/bin" / name
    destination = archive.parent / "native/bin" / name
    if not archive.is_file() or not source.is_file() or source.stat().st_size == 0:
        raise ValueError("export pack and built target native library are required")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)
    print("NATIVEPACKAGE DONE " + name)

if __name__ == "__main__":
    try:
        main()
    except (IndexError, KeyError, OSError, ValueError) as error:
        sys.exit(f"NATIVEPACKAGE FAIL: {error}")
