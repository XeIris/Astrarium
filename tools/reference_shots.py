#!/usr/bin/env python3
"""Capture migration references; reject failed, incomplete or stale output."""
import argparse
import datetime
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from types import SimpleNamespace

from check import ROOT, godot_path, metadata, run_check


class CaptureError(ValueError):
    pass


def node_json(*args):
    child = subprocess.run(["node", *args], cwd=ROOT, capture_output=True, text=True, timeout=30)
    if child.returncode:
        raise CaptureError(child.stderr or "shot-list generator failed")
    return json.loads(child.stdout)


def select(requested, available):
    names = requested or list(available)
    if not names or len(names) != len(set(names)) or any(n not in available for n in names):
        raise CaptureError("empty, duplicate or unknown shot selection")
    return names


def jobs(kind, args, godot):
    base = [godot, "--path", str(ROOT)]
    if kind == "stars":
        source, output = Path(args[0]).resolve(), Path(args[1]).resolve()
        names = select(args[2:], {p.stem: p for p in sorted(source.glob("*.json"))})
        for name in names:
            json.loads((source / (name + ".json")).read_text())
            image = output / (name + ".png")
            yield name, output, base + ["res://tools/startest.tscn", "--",
                f"state={source / (name + '.json')}", f"out={image}", "frames=8"], [image], ["harness: saved " + str(image)], 90
    elif kind == "course":
        output = Path(args[0]).resolve()
        table = node_json("-e", "import('./tools/course.shots.mjs').then(m => console.log(JSON.stringify(m.SHOTS)))")
        shots = {s[0]: s for s in table}
        for name in select(args[1:], shots):
            _, key, steps, frames = shots[name]
            image, dump = output / (name + ".png"), output / (name + ".json")
            yield name, output, base + ["--resolution", "1280x720", "res://tools/coursetest.tscn", "--",
                f"lesson={key}", f"steps={steps}", f"cframes={frames}", f"cout={image}", f"cdump={dump}"], [image, dump], ["coursetest: wrote " + str(image)], 90
    else:
        output = Path(args[0]).resolve()
        table = json.loads((ROOT / "tools/flight_scenarios.json").read_text())
        names = select(args[1].split(",") if len(args) > 1 else [], table["scenarios"])
        which = args[2] if len(args) > 2 else "both"
        if which not in ("both", "godot", "web"):
            raise CaptureError("flight renderer must be both, godot or web")
        if which != "godot":
            shots = node_json(str(ROOT / "tools/flightshots.mjs"), ",".join(names))
            dest = output / "web"
            dest.mkdir(parents=True, exist_ok=True)
            shot_list = dest / "shots.json"
            shot_list.write_text(json.dumps(shots, indent=2) + "\n")
            files = [dest / (s["name"] + ext) for s in shots
                     for ext in ([".png", ".json", ".bare.png"] if s.get("bare") else [".png", ".json"])]
            yield "web", dest, ["node", str(ROOT / "tools/webref.mjs"), str(shot_list), str(dest)], files, ["ok " + s["name"] for s in shots], 900
        if which != "web":
            dest = output / "godot"
            for name in names:
                shots = [s for s in table["scenarios"][name] if s[0] == "shot"]
                files = [dest / (s[1] + ext) for s in shots
                         for ext in ([".png", ".json", ".hud.png"] if len(s) > 2 and s[2] else [".png", ".json"])]
                yield name, dest, base + ["--resolution", "1280x720", "res://tools/flighttest.tscn", "--",
                    "preset=solar", f"seed={table['seed']}", "mode=flight", f"scen={name}", f"out={dest}/"], files, ["flighttest: " + s[1] + " " for s in shots], 900


def capture(job, index, options):
    name, output, command, files, markers, timeout = job
    if not files or not markers:
        raise CaptureError(f"{name}: no captures requested")
    output.mkdir(parents=True, exist_ok=True)
    # Old captures must not satisfy a child that exits before writing anything.
    for path in files:
        path.unlink(missing_ok=True)
    result = run_check((name, command, None, timeout), output, index, options)
    result["outputs"] = [str(p) for p in files]
    text = Path(result["log"]).read_text(errors="replace")
    if result["problem"]:
        return result
    if re.search(r"^FAIL\b|\[page exception\]|^CHECK DIFF", text, re.MULTILINE):
        result["problem"] = "reference capture or comparison failed"
    elif any(len(re.findall("^" + re.escape(m) + (r".*$" if m.endswith(" ") else "$"),
                            text, re.MULTILINE)) != 1 for m in markers):
        result["problem"] = "missing or duplicated capture completion marker"
    else:
        try:
            for path in files:
                if path.suffix == ".json":
                    data = json.loads(path.read_text())
                    if not isinstance(data, dict) or not data:
                        raise CaptureError(f"empty telemetry: {path}")
                else:
                    data = path.read_bytes()
                    if (len(data) < 45 or data[:8] != b"\x89PNG\r\n\x1a\n"
                            or data[12:16] != b"IHDR" or data[-12:] != b"\x00\x00\x00\x00IEND\xaeB`\x82"):
                        raise CaptureError(f"invalid or truncated PNG: {path}")
        except (OSError, ValueError) as error:
            result["problem"] = str(error)
    if result["problem"]:
        print(f"CAPTURE FAIL {name}: {result['problem']}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("stars", "course", "flight"))
    parser.add_argument("args", nargs="+")
    options = parser.parse_args()
    minimum = 2 if options.kind == "stars" else 1
    if len(options.args) < minimum or (options.kind == "flight" and len(options.args) > 3):
        parser.error("stars: WEBDIR OUTDIR [names...]; course: OUTDIR [names...]; flight: OUTDIR [scenarios] [both|godot|web]")
    timeout = float(os.environ["TIMEOUT"]) if "TIMEOUT" in os.environ else None
    if timeout is not None and (not math.isfinite(timeout) or timeout <= 0):
        parser.error("TIMEOUT must be finite and positive")
    web_only = options.kind == "flight" and len(options.args) == 3 and options.args[2] == "web"
    godot = "" if web_only else godot_path(os.environ.get("GODOT"))
    config = SimpleNamespace(godot=godot, timeout=timeout, background=False, allow_macos_ca_error=False)
    output = Path(options.args[1] if options.kind == "stars" else options.args[0]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    report = {"kind": options.kind, "complete": False, "results": [],
              "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "commit": metadata(["git", "rev-parse", "HEAD"]),
              "working_tree": metadata(["git", "status", "--short"]),
              "godot": metadata([godot, "--version"]) if godot else None,
              "arguments": options.args, "timeout_override": timeout}
    try:
        for index, job in enumerate(jobs(options.kind, options.args, godot)):
            result = capture(job, index, config)
            report["results"].append(result)
            if result["problem"]:
                return 1
        report["complete"] = bool(report["results"])
        return 0 if report["complete"] else 1
    finally:
        (output / "reference-report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"CAPTURE FAILED: {error}")
