#!/usr/bin/env python3
"""Verify a committed checkout without local import caches or generated models."""
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parent.parent
ENGINE_ERROR = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):|ObjectDB instances leaked at exit", re.MULTILINE)


def run(command, cwd, log, timeout=1800):
    with log.open("w") as stream:
        result = subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"child exited {result.returncode}: {log}")
    return log.read_text(errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--rendered-boot", action="store_true", help="also boot the exported application using a graphical renderer")
    parser.add_argument("--export-preset", default={"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}[platform.system()])
    options = parser.parse_args()
    output = options.log_dir.resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
              "platform": platform.platform(), "complete": False,
              "scope": "committed clean clone, rebuilt native kernel, procedural assets, export pack, resource/native startup and optional rendered boot"}
    try:
        dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).strip()
        if dirty:
            raise RuntimeError("commit the candidate before clean-clone verification; working tree has changes")
        with tempfile.TemporaryDirectory(prefix="astrarium-clean-") as temporary:
            checkout = Path(temporary) / "checkout"
            run(["git", "clone", "--quiet", "--local", "--no-hardlinks", str(ROOT), str(checkout)], ROOT, output / "clone.log")
            if (checkout / ".godot").exists() or list((checkout / "assets/craft").glob("*.glb")) or list((checkout / "assets/pads").glob("*.glb")):
                raise RuntimeError("clone unexpectedly contains import caches or generated models")
            report["godot"] = subprocess.check_output([options.godot, "--version"], text=True).strip()
            run(["sh", str(checkout / "native/build.sh")], checkout, output / "native-build.log")
            run([sys.executable, str(checkout / "tools/check.py"), "fast", "native", "procedural", "export",
                 "--godot", options.godot, "--log-dir", str(output / "checks"), "--export-preset", options.export_preset],
                checkout, output / "checks.log")
            archive = output / "checks/game.zip"
            # Native libraries must exist outside the pack for the OS loader.
            isolated = Path(temporary) / "boot"
            isolated.mkdir()
            shutil.copytree(output / "checks/native", isolated / "native")
            with ZipFile(archive) as pack:
                for name in pack.namelist():
                    if name.startswith("native/bin/"):
                        destination = isolated / name
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(pack.read(name))
            probe = isolated / "startup.gd"
            probe.write_text('extends SceneTree\nfunc _init() -> void:\n\tvar scene = load("res://main.tscn")\n\tvar native_ok := ClassDB.class_exists("NBodyKernel")\n\tif not scene is PackedScene or not native_ok:\n\t\tpush_error("Export resources/native startup failed")\n\t\tquit(1)\n\t\treturn\n\tvar node = scene.instantiate()\n\tnode.free()\n\tprint("EXPORTSTARTUP DONE resources=true native=true")\n\tquit(0)\n')
            engine_log = output / "boot.engine.log"
            command = [options.godot, "--headless", "--path", str(isolated), "--main-pack", str(archive),
                       "--log-file", str(engine_log), "--script", str(probe)]
            text = run(command, isolated, output / "boot.log", timeout=120)
            errors = text + (engine_log.read_text(errors="replace") if engine_log.exists() else "")
            if ENGINE_ERROR.search(errors) or text.count("EXPORTSTARTUP DONE resources=true native=true") != 1:
                raise RuntimeError(f"invalid isolated exported startup: {output / 'boot.log'}")
            if options.rendered_boot:
                text = run([options.godot, "--path", str(isolated), "--main-pack", str(archive),
                            "--log-file", str(output / "rendered-boot.engine.log"), "--quit-after", "60", "--",
                            "mode=sandbox", "preset=solar", "assets=0", "padmodels=0"],
                           isolated, output / "rendered-boot.log", timeout=120)
                errors = text + (output / "rendered-boot.engine.log").read_text(errors="replace")
                if ENGINE_ERROR.search(errors):
                    raise RuntimeError("engine error or leak during rendered exported boot")
                report["rendered_boot"] = True
            report["complete"] = True
        print("CLEANCHECK DONE failures=0")
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        print(f"CLEANCHECK FAIL: {error}", file=sys.stderr)
        return 1
    finally:
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    sys.exit(main())
