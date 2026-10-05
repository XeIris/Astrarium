#!/usr/bin/env python3
"""Run selected verification suites; retain logs and reject incomplete runs."""
import argparse
import datetime
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
SUITES = ("fast", "native", "flight", "rendered", "assets", "procedural", "clean", "lifecycle", "export", "compatibility", "perf", "m5-budget", "stability", "stability-study")
ENGINE_ERROR = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):", re.MULTILINE)
CA_ERROR = re.compile(r'^ERROR: Condition "ret != noErr" is true\. Returning: ""\n'
                      r'\s+at: get_system_ca_certificates \(platform/macos/os_macos\.mm:\d+\)\n?', re.MULTILINE)


def godot_path(value):
    candidates = [value] if value else [shutil.which("godot"), shutil.which("Godot"),
                                       "/Applications/Godot.app/Contents/MacOS/Godot"]
    for candidate in candidates:
        if candidate and Path(candidate).is_file() and os.access(candidate, os.X_OK):
            return str(Path(candidate).resolve())
    raise ValueError("Godot executable unavailable; pass --godot or set GODOT")


def checks(suite, godot, output, repeat, export_preset):
    base = [godot, "--path", str(ROOT)]

    def script(name, marker, *args, timeout=180):
        return (name, base + ["--headless", "--script", f"res://tools/{name}.gd", "--", *args], marker, timeout)

    def scene(name, marker, *args, timeout=300):
        return (name, base + ["--resolution", "1280x720", f"res://tools/{name}.tscn", "--", *args], marker, timeout)

    if suite == "fast":
        yield ("import", base + ["--headless", "--import", "--quit"], None, 180)
        yield script("skycheck", r"^SKYCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("cameracheck", r"^CAMERACHECK DONE checks=[1-9]\d* failures=0$")
        yield script("invariantcheck", r"^INVARIANTCHECK DONE checks=[1-9]\d* failures=0 native=(?:true|false)$")
        yield script("sciencecheck", r"^sciencecheck: [1-9]\d* checks, 0 failed$")
        yield script("savecheck", r"^SAVECHECK ([1-9]\d*)/\1 checks passed \(platform=(?:macOS|Linux|Windows); native \+ forced backup publication\)\.$")
        yield script("flighttimecheck", r"^FLIGHT TIME PASS \(0 failures\)$")
    elif suite == "native":
        yield script("nbodycheck", r"^NBODYCHECK DONE [1-9]\d* presets, 0 failed \(", timeout=600)
        yield script("numericalcheck", r"^NUMERICALCHECK DONE checks=[1-9]\d* failures=0$")
    elif suite == "stability":
        yield script("stabilitycheck", r"^STABILITYCHECK DONE mode=baseline target_years=60000(?:\.0+)? accepted_years=60000(?:\.0+)? failures=0$",
                     "years=60000", f"report={output / 'stability.json'}", timeout=900)
    elif suite == "stability-study":
        yield from checks("stability", godot, output, repeat, export_preset)
        probes = [(f"step-{divisor}", f"step_divisor={divisor}") for divisor in (2, 4, 8)]
        probes += [(label, f"world_rotation={angle}") for label, angle in (
            ("orientation-plus-tiny", "0.000001"), ("orientation-minus-tiny", "-0.000001"),
            ("orientation-quarter", "1.5707963267948966"), ("orientation-half", "3.141592653589793"),
            ("orientation-three-quarters", "4.71238898038469"))]
        for label, option in probes:
            probe = script("stabilitycheck", r"^STABILITYDIAGNOSTIC DONE mode=diagnostic target_years=60000(?:\.0+)? accepted_years=60000(?:\.0+)? failures=0$",
                           "years=60000", option, f"report={output / (label + '.json')}", timeout=900)
            yield ("stability-" + label, *probe[1:])
    elif suite == "flight":
        yield script("sharedflightcheck", r"^SHARED FLIGHT DONE failures=0$", timeout=900)
    elif suite == "rendered":
        yield scene("lenscheck", r"^LENSCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("skycachecheck", r"^SKYCACHECHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("coursecheck", r"^COURSE 35L 108S 0E$")
        yield scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1")
        startup_low = scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1", "quality=low")
        yield ("hud-low-startup", *startup_low[1:])
        layout = scene("hudcheck", r"^HUDCHECK LAYOUT [1-9]\d* passed, 0 failed$", "hlayout=1", "assets=0", "padmodels=0")
        yield ("hud-layout", *layout[1:])
        yield scene("sharedtimecheck", r"^SHARED TIME DONE checks=[1-9]\d* failures=0$", "assets=0")
        yield scene("transitioncheck", r"^TRANSITIONCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("structureinputcheck", r"^STRUCTUREINPUTCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("editorcheck", r"^EDITORCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$")
        accretion_gd = scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$", "native=0")
        yield ("accretion-gdscript", *accretion_gd[1:])
        yield ("presetcheck", ["sh", str(ROOT / "tools/presetcheck.sh"), str(output / "presets-engine.log")],
               r"^PRESETCHECK DONE 35$", 300)
    elif suite in ("assets", "procedural"):
        if suite == "assets":
            yield ("craft-parity", base + ["--headless", "res://tools/crafttest.tscn", "--", "parity"],
                   r"^PARITY DONE 18 poses, 0 failures$", 180)
        for assets in (("1", "0") if suite == "assets" else ("0",)):
            # The authored gate cannot pass by silently substituting optional fallback models.
            yield script("assetcheck", rf"^ASSETCHECK DONE [1-9]\d* checks, {'9' if assets == '1' else '0'} authored, 0 failures$", f"assets={assets}")
            for action in ("audit", "clearance"):
                yield (f"craft-{action}-{assets}", base + ["--headless", "res://tools/crafttest.tscn", "--", action, f"assets={assets}"],
                       r"^CRAFTCHECK DONE PASS$", 180)
            for pads in (("1", "0") if suite == "assets" else ("0",)):
                yield script("padcheck", r"^PADCHECK DONE PASS$", f"assets={assets}", f"padmodels={pads}")
    elif suite == "clean":
        yield ("cleancheck", [sys.executable, str(ROOT / "tools/cleancheck.py"), "--godot", godot,
                             "--log-dir", str(output / "clean"), "--export-preset", export_preset],
               r"^CLEANCHECK DONE failures=0$", 1800)
    elif suite == "lifecycle":
        for method, marker in (("_soak_check", r"^SOAK DONE$"), ("_leak_check", r"^LEAKCHECK DONE$"), ("_shutdown_check", r"^SHUTDOWNCHECK DONE$")):
            yield (method, base + ["--verbose", "--resolution", "1280x720", "--", "mode=sandbox", "preset=solar", "rounds=5", f"eval={method}"], marker, 900)
    elif suite == "export":
        archive = output / "game.zip"
        yield ("export-pack", base + ["--headless", "--export-pack", export_preset, str(archive)], None, 300)
        yield ("package-native", [sys.executable, str(ROOT / "tools/package_native.py"), str(archive), export_preset],
               r"^NATIVEPACKAGE DONE .+$", 30)
        yield ("exportcheck", [sys.executable, str(ROOT / "tools/exportcheck.py"), str(archive)], r"^EXPORTCHECK PASS:.* 0 failures$", 30)
    elif suite == "compatibility":
        # Known strict trajectory differences remain failures; no widened tolerances or expected-failure masking.
        yield script("sciencecheck", r"^sciencecheck: [1-9]\d* checks, 0 failed$", "compatibility=web")
        yield ("physcheck", ["sh", str(ROOT / "tools/physcheck.sh"), str(output / "physics-reference")], r"^PHYSCHECK COMPLETE:", 300)
    elif suite == "m5-budget":
        yield scene("perfcheck", r"^PERFCHECK DONE cases=11 failures=0$", "m5_native=1", f"report={output / 'm5-native.json'}")
    elif suite == "perf":
        yield scene("perfcheck", r"^PERFCHECK DONE cases=11 failures=0$", f"report={output / 'render-profile.json'}")
        abba = scene("perfcheck", r"^PERFCHECK DONE cases=16 failures=0$", "studio_abba=1", f"report={output / 'studio-abba.json'}")
        yield ("studio-abba", *abba[1:])
        yield script("nbodycheck", r"^NBODYCHECK DONE [1-9]\d* presets, 0 failed \(", timeout=600)
        for _ in range(repeat):
            for native in ("0", "1"):
                yield scene("sharedtimecheck", r"^SHARED TIME DONE checks=[1-9]\d* failures=0$", "bench=1", "assets=0", f"native={native}")
            for state in ("sandbox", "flight", "model"):
                yield scene("hudcheck", rf"^HUDCHECK PERF {state} shown .* hidden .* ms$", f"hstate={state}", "hperf=1", "assets=0")


def run_check(check, output, index, options):
    name, command, marker, timeout = check
    log = output / f"{index:02d}-{name}.log"
    engine_log = None
    if command[0] == options.godot:
        engine_log = log.with_suffix(".engine.log")
        engine_log.unlink(missing_ok=True)
        command = [command[0], "--log-file", str(engine_log), *command[1:]]
    start = time.monotonic()
    print(f"RUN {name}", flush=True)
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                   env={**os.environ, "GODOT": options.godot}, start_new_session=os.name == "posix")
        try:
            code = process.wait(timeout=options.timeout or timeout)
            problem = None if code == 0 else f"child exited {code}"
        except subprocess.TimeoutExpired:
            if os.name == "posix":
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.wait()
            code, problem = 124, "timeout"
    raw = log.read_text(errors="replace")
    text, ignored = CA_ERROR.subn("", raw) if options.allow_macos_ca_error else (raw, 0)
    engine_text = engine_log.read_text(errors="replace") if engine_log and engine_log.exists() else ""
    if options.allow_macos_ca_error:
        engine_text, engine_ignored = CA_ERROR.subn("", engine_text)
        ignored = max(ignored, engine_ignored)
    if ignored:
        print(f"  allowed {ignored} macOS system-CA diagnostic(s); retained in log", flush=True)
    errors = text + "\n" + engine_text
    if problem is None and ENGINE_ERROR.search(errors):
        problem = "engine error"
    if problem is None and marker is not None and len(re.findall(marker, text, re.MULTILINE)) != 1:
        problem = "missing or duplicated successful completion marker"
    if problem is None and name.startswith("stability") and len(re.findall(r"^STABILITY(?:CHECK|DIAGNOSTIC) DONE\b.*$", text, re.MULTILINE)) != 1:
        problem = "conflicting stability completion markers"
    if problem is None and re.search(r"ObjectDB instances leaked at exit|(?:SOAK|LEAKCHECK) FAILURES \[(?!\])", errors):
        problem = "lifecycle leak"
    elapsed = round(time.monotonic() - start, 3)
    print(f"{'FAIL' if problem else 'PASS'} {name} {elapsed}s" + (f": {problem}" if problem else ""), flush=True)
    print(f"  {log}", flush=True)
    return {"name": name, "command": command, "exit_code": code, "problem": problem,
            "seconds": elapsed, "log": str(log), "engine_log": str(engine_log) if engine_log else None,
            "allowed_ca_diagnostics": ignored,
            "renderer": next((line for line in raw.splitlines() if re.match(r"^(?:Metal|Vulkan|OpenGL).*Using Device", line)), None),
            "metrics": [line for line in raw.splitlines() if line.startswith(("SHARED TIME BENCH", "SHARED TIME CONFIG", "HUDCHECK PERF", "HUDCHECK CONFIG", "NBODYCHECK PASS", "STABILITYCHECK", "STABILITYDIAGNOSTIC"))]}


def metadata(command):
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=15)
    return result.stdout.strip() if result.returncode == 0 else "unavailable"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", metavar="SUITE", help=", ".join(SUITES) + " (default: fast)")
    parser.add_argument("--godot", default=os.environ.get("GODOT"))
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument("--timeout", type=float, help="override each child timeout in seconds")
    parser.add_argument("--allow-macos-ca-error", action="store_true", help="allow only Godot's get_system_ca_certificates diagnostic")
    parser.add_argument("--repeat", type=int, default=3, help="performance repetitions (default 3)")
    parser.add_argument("--export-preset", default={"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}.get(platform.system(), "macOS"))
    options = parser.parse_args()
    options.suites = options.suites or ["fast"]
    if any(suite not in SUITES for suite in options.suites):
        parser.error("unknown suite; choose from " + ", ".join(SUITES))
    if options.repeat < 1 or (options.timeout is not None and options.timeout <= 0):
        parser.error("repeat and timeout must be positive")
    options.godot = godot_path(options.godot)
    output = options.log_dir.resolve() if options.log_dir else Path(tempfile.mkdtemp(prefix="astrarium-check-"))
    output.mkdir(parents=True, exist_ok=True)
    report = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
              "godot": metadata([options.godot, "--version"]), "commit": metadata(["git", "rev-parse", "HEAD"]),
              "working_tree": metadata(["git", "status", "--short"]), "suites": options.suites,
              "performance": ({"resolution": "1280x720", "rendered_craft": "authored Saturn V/Falcon 9 (required)",
                               "cpu_flight_craft": "procedural (asserted by each harness)",
                               "studio_abba": "frozen stage; two ABBA cycles per distance; distinct model viewport timestamp batches",
                               "shared_time": "fixed 1/60s steps; CPU animate timing; native=0 and required native=1",
                               "hud": "fixed 1/60s frames; wall time across rendered frames; vsync disabled",
                               "repetitions": options.repeat, "limitations": "local baseline; GPU availability recorded separately, no portable budget gate"}
                              if "perf" in options.suites else None),
              "complete": False, "results": []}
    try:
        for suite in options.suites:
            for check in checks(suite, options.godot, output, options.repeat, options.export_preset):
                result = run_check(check, output, len(report["results"]), options)
                report["results"].append(result)
                if result["problem"]:
                    return 1
        report["complete"] = True
        return 0
    finally:
        path = output / "report.json"
        path.write_text(json.dumps(report, indent=2) + "\n")
        print(f"REPORT {path}", flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"CHECK FAILED: {error}")
