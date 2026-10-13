#!/usr/bin/env python3
"""Run selected verification suites; retain logs and reject incomplete runs."""
import argparse
import contextlib
import datetime
import json
import os
from pathlib import Path
import platform
import queue
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
SUITES = ("fast", "native", "flight", "rendered", "assets", "procedural", "clean", "lifecycle", "export", "compatibility", "perf", "m5-budget", "m5-medium", "stability", "stability-study")
ENGINE_ERROR = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):", re.MULTILINE)
# Each check in these runs with nothing beside it: they measure time, run check.py
# themselves (clean), read the previous step's output (export), or need exact object
# counts (lifecycle).
ALONE = {"perf", "m5-budget", "m5-medium", "stability", "stability-study", "clean", "export", "lifecycle"}
# The descent gates, one flightcheck process each.
DESCENTS = ("lm", "f9booster", "f9booster_light", "f9booster_heavy", "skycrane", "skycrane_staged", "lmdeorbit", "shcatch", "shcatch_2x")
# missioncheck's cases in its own order, with idle seconds on an M-series Mac (only for launch order).
MISSIONS = {"launch_orbit": 71, "lunar_orbit": 92, "lunar_landing": 37, "skip_moon": 2,
            "ship_return": 77, "orbiter_return": 101, "orbiter_home": 183}
CA_ERROR = re.compile(r'^ERROR: Condition "ret != noErr" is true\. Returning: ""\n'
                      r'\s+at: get_system_ca_certificates \(platform/macos/os_macos\.mm:\d+\)\n?', re.MULTILINE)


class Check(NamedTuple):
    name: str
    command: list
    markers: object  # None, or a regex (or tuple of them) that must each match exactly one line
    timeout: float
    cost: float = 0  # rough idle seconds; --jobs launches the longest first
    alone: bool = False


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
        return Check(name, base + ["--headless", "--script", f"res://tools/{name}.gd", "--", *args], marker, timeout)

    def scene(name, marker, *args, timeout=300):
        return Check(name, base + ["--resolution", "1280x720", f"res://tools/{name}.tscn", "--", *args], marker, timeout)

    if suite == "fast":
        # Everything else reads the import cache, so nothing runs beside the import.
        yield Check("import", base + ["--headless", "--import", "--quit"], None, 180, alone=True)
        yield ("reference-shots-selfcheck", [sys.executable, str(ROOT / "tools/reference_shots_test.py")],
               r"^REFERENCE SHOTS SELF-CHECK PASS$", 30)
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
        yield script("sharedflightcheck", r"^SHARED FLIGHT DONE failures=0$", timeout=900)._replace(cost=70)
        for case in DESCENTS:
            descent = script("flightcheck", r"^FLIGHT CHECK DONE scenarios=1 failures=0$",
                             f"only={case}", f"out={output / f'flight_descent-{case}.json'}", timeout=600)
            yield descent._replace(name=f"flight-descent-{case}", cost=10)
        # One mission per process. The case list guards against a mission check.py does not know.
        # Each mission fails on its own at a frame cap, so the limit only catches a hang; it
        # allows several times the idle time because entry is flown at 1× under --jobs load.
        for case, cost in MISSIONS.items():
            markers = (rf"^MISSION CHECK CASES {','.join(MISSIONS)}$", rf"^MISSION {case} ok\b", r"^MISSION CHECK DONE failures=0$")
            yield scene("missioncheck", markers, f"only={case}", timeout=1200)._replace(name=f"missioncheck-{case}", cost=cost)
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
    elif suite == "m5-medium":
        medium = scene("perfcheck", r"^PERFCHECK DONE cases=11 failures=0$", "m5_native=1", "m5_preset=medium", f"report={output / 'm5-medium.json'}")
        yield ("perfcheck-m5-medium", *medium[1:])
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


class FocusGuard:
    """macOS: Godot activates itself as its window opens. Return focus to the app
    the user last had in front. One guard serves every running check; only
    processes in a registered check's own session match (wrapper scripts launch
    Godot as a grandchild), so other Godot windows, such as an open editor, are
    left alone and never become the app to return to. Windowed rendering
    continues behind."""

    def __init__(self):
        self.restored = {}  # check pid -> restorations
        self.lock = threading.Lock()
        self.stop = threading.Event()
        self.bundle = self.front()[1]
        self.thread = threading.Thread(target=self.watch, daemon=True)

    @staticmethod
    def front():
        try:
            asn = subprocess.run(["lsappinfo", "front"], capture_output=True, text=True, timeout=2).stdout.strip()
            info = subprocess.run(["lsappinfo", "info", "-only", "pid", "-only", "bundleid", asn],
                                  capture_output=True, text=True, timeout=2).stdout
        except (OSError, subprocess.SubprocessError):
            return None, None
        pid = re.search(r'"pid"=(\d+)', info)
        bundle = re.search(r'"CFBundleIdentifier"="([^"]+)"', info)
        return (int(pid.group(1)) if pid else None), (bundle.group(1) if bundle else None)

    def watch(self):
        while not self.stop.wait(0.05):
            pid, bundle = self.front()
            owner = self.owner(pid)
            if owner is not None and self.bundle:
                subprocess.run(["open", "-b", self.bundle], capture_output=True, timeout=5)
                with self.lock:
                    if owner in self.restored: self.restored[owner] += 1
            elif pid is not None and bundle:
                self.bundle = bundle

    def owner(self, pid):
        if pid is None:
            return None
        with self.lock:
            owners = set(self.restored)
        if pid in owners:
            return pid
        try:
            sid = os.getsid(pid)
        except OSError:
            return None
        return sid if sid in owners else None

    def add(self, pid):
        with self.lock:
            self.restored[pid] = 0

    def remove(self, pid):
        with self.lock:
            return self.restored.pop(pid)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join()


def run_check(check, output, index, options):
    """Run one check now and print its result (also used by reference_shots.py)."""
    print(f"RUN {check[0]}", flush=True)
    with FocusGuard() if options.background else contextlib.nullcontext() as guard:
        result, lines = run_child(check, output, index, options, guard, {})
    for line in lines:
        print(line, flush=True)
    return result


def run_child(check, output, index, options, guard, live):
    """Run one child to completion or timeout. Returns its report entry and the
    lines to print, so concurrent checks can be reported in a stable order."""
    name, command, marker, timeout = check[:4]
    log = output / f"{index:02d}-{name}.log"
    lines = []
    engine_log = None
    if command[0] == options.godot:
        engine_log = log.with_suffix(".engine.log")
        engine_log.unlink(missing_ok=True)
        command = [command[0], "--log-file", str(engine_log), *command[1:]]
    start = time.monotonic()
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                                   env={**os.environ, "GODOT": options.godot}, start_new_session=os.name == "posix")
        live[index] = process
        guarded = guard is not None and "--headless" not in command
        if guarded: guard.add(process.pid)
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
        finally:
            restored = guard.remove(process.pid) if guarded else None
            live.pop(index, None)
    raw = log.read_text(errors="replace")
    text, ignored = CA_ERROR.subn("", raw) if options.allow_macos_ca_error else (raw, 0)
    engine_text = engine_log.read_text(errors="replace") if engine_log and engine_log.exists() else ""
    if options.allow_macos_ca_error:
        engine_text, engine_ignored = CA_ERROR.subn("", engine_text)
        ignored = max(ignored, engine_ignored)
    if ignored:
        lines.append(f"  allowed {ignored} macOS system-CA diagnostic(s); retained in log")
    errors = text + "\n" + engine_text
    if problem is None and ENGINE_ERROR.search(errors):
        problem = "engine error"
    markers = (marker,) if isinstance(marker, str) else marker or ()
    if problem is None and any(len(re.findall(m, text, re.MULTILINE)) != 1 for m in markers):
        problem = "missing or duplicated successful completion marker"
    if problem is None and name.startswith("stability") and len(re.findall(r"^STABILITY(?:CHECK|DIAGNOSTIC) DONE\b.*$", text, re.MULTILINE)) != 1:
        problem = "conflicting stability completion markers"
    if problem is None and re.search(r"ObjectDB instances leaked at exit|(?:SOAK|LEAKCHECK) FAILURES \[(?!\])", errors):
        problem = "lifecycle leak"
    elapsed = round(time.monotonic() - start, 3)
    lines.append(f"{'FAIL' if problem else 'PASS'} {name} {elapsed}s" + (f": {problem}" if problem else ""))
    lines.append(f"  {log}")
    return {"name": name, "command": command, "exit_code": code, "problem": problem,
            "seconds": elapsed, "log": str(log), "engine_log": str(engine_log) if engine_log else None,
            "allowed_ca_diagnostics": ignored, "focus_restored": restored,
            "renderer": next((line for line in raw.splitlines() if re.match(r"^(?:Metal|Vulkan|OpenGL).*Using Device", line)), None),
            "metrics": [line for line in raw.splitlines() if line.startswith(("SHARED TIME BENCH", "SHARED TIME CONFIG", "HUDCHECK PERF", "HUDCHECK CONFIG", "NBODYCHECK PASS", "STABILITYCHECK", "STABILITYDIAGNOSTIC"))]}, lines


def run_plan(plan, output, options, guard, report):
    """Run checks up to options.jobs at a time. A check marked alone waits for the
    running ones and runs by itself. After a failure nothing new starts; running
    checks finish. Results print and enter the report in plan order."""
    done = queue.Queue()
    live = {}
    finished = {}
    stopped = False
    printed = 0

    def worker(index):
        try:
            done.put((index, run_child(plan[index], output, index, options, guard, live), None))
        except BaseException as error:  # reported by the main thread
            done.put((index, None, error))

    def flush(final=False):
        nonlocal printed
        while printed < len(plan) and (printed in finished or final):
            if printed in finished:
                result, lines = finished.pop(printed)
                for line in lines:
                    print(line, flush=True)
                report["results"].append(result)
            printed += 1

    # Segments: runs of parallel checks between checks that run alone.
    segments = []
    for index, check in enumerate(plan):
        if check.alone or not segments or plan[segments[-1][-1]].alone:
            segments.append([])
        segments[-1].append(index)
    try:
        for segment in segments:
            if options.jobs > 1:
                segment = sorted(segment, key=lambda index: -plan[index].cost)
            waiting, running = list(segment), 0
            while waiting or running:
                while waiting and not stopped and running < options.jobs:
                    index = waiting.pop(0)
                    print(f"RUN {plan[index].name}", flush=True)
                    threading.Thread(target=worker, args=(index,), daemon=True).start()
                    running += 1
                if running == 0:
                    break
                index, outcome, error = done.get()
                running -= 1
                if error is not None:
                    raise error
                finished[index] = outcome
                stopped = stopped or outcome[0]["problem"] is not None
                flush()
            if stopped:
                break
        return not stopped
    finally:
        for process in list(live.values()):
            if process.poll() is None:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
        flush(final=True)


def default_jobs():
    # Efficiency cores fly a mission at a fraction of a performance core's speed.
    try:
        cores = subprocess.run(["sysctl", "-n", "hw.perflevel0.physicalcpu"], capture_output=True, text=True, timeout=5)
        if cores.returncode == 0 and int(cores.stdout) > 0:
            return int(cores.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return os.cpu_count() or 1


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
    parser.add_argument("--background", action="store_true",
                        help="macOS: hand focus back whenever a windowed check activates (not for the fullscreen M5 gates)")
    parser.add_argument("--jobs", type=int, default=default_jobs(),
                        help="checks run at once (default: performance cores); timing suites always run alone")
    parser.add_argument("--repeat", type=int, default=3, help="performance repetitions (default 3)")
    parser.add_argument("--export-preset", default={"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}.get(platform.system(), "macOS"))
    options = parser.parse_args()
    options.suites = options.suites or ["fast"]
    if any(suite not in SUITES for suite in options.suites):
        parser.error("unknown suite; choose from " + ", ".join(SUITES))
    if options.repeat < 1 or options.jobs < 1 or (options.timeout is not None and options.timeout <= 0):
        parser.error("repeat, jobs and timeout must be positive")
    if options.background and (platform.system() != "Darwin" or any(s.startswith("m5-") for s in options.suites)):
        parser.error("--background is macOS-only; the M5 gates need their fullscreen Space visible")
    options.godot = godot_path(options.godot)
    output = options.log_dir.resolve() if options.log_dir else Path(tempfile.mkdtemp(prefix="astrarium-check-"))
    output.mkdir(parents=True, exist_ok=True)
    report = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
              "godot": metadata([options.godot, "--version"]), "commit": metadata(["git", "rev-parse", "HEAD"]),
              "working_tree": metadata(["git", "status", "--short"]), "suites": options.suites,
              "background": options.background, "jobs": options.jobs,
              "performance": ({"resolution": "1280x720", "rendered_craft": "authored Saturn V/Falcon 9 (required)",
                               "cpu_flight_craft": "procedural (asserted by each harness)",
                               "studio_abba": "frozen stage; two ABBA cycles per distance; distinct model viewport timestamp batches",
                               "shared_time": "fixed 1/60s steps; CPU animate timing; native=0 and required native=1",
                               "hud": "fixed 1/60s frames; wall time across rendered frames; vsync disabled",
                               "repetitions": options.repeat, "limitations": "local baseline; GPU availability recorded separately, no portable budget gate"}
                              if "perf" in options.suites else None),
              "complete": False, "results": []}
    plan = [check._replace(alone=check.alone or suite in ALONE)
            for suite in options.suites
            for check in map(lambda c: Check(*c), checks(suite, options.godot, output, options.repeat, options.export_preset))]
    try:
        with FocusGuard() if options.background else contextlib.nullcontext() as guard:
            if not run_plan(plan, output, options, guard, report):
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
