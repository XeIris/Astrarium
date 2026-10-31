#!/usr/bin/env python3
"""Run selected verification suites; retain logs and reject incomplete runs."""
import argparse
import contextlib
import datetime
import fnmatch
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
SUITES = ("dev", "fast", "native", "flight", "scenario-replay", "rendered", "assets", "procedural", "clean", "lifecycle", "export", "compatibility", "perf", "m5-budget", "m5-medium", "stability", "stability-study")
ENGINE_ERROR = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):", re.MULTILINE)
# Each check in these runs with nothing beside it: they measure time, run check.py
# themselves (clean), read the previous step's output (export), or need exact object
# counts (lifecycle; its checks run beside each other only, see `alone`).
ALONE = {"perf", "m5-budget", "m5-medium", "stability", "stability-study", "clean", "export", "lifecycle"}
# The soak's features in runtime_checks.gd's order, one process each.
SOAK_FEATURES = ("spawn_remove", "edit_mass", "true_scale", "editor", "paint", "xsec", "cam_modes", "quality",
                 "lessons", "model_viewer", "flight_stage", "flight_catch", "scenario", "start_screen")
# The full launches sharedflightcheck flies, one process each.
SHARED_FLIGHTS = ("saturnv", "falcon9", "shuttle", "starship")
# The descent gates, one flightcheck process each.
DESCENTS = ("lm", "f9booster", "f9booster_light", "f9booster_heavy", "skycrane", "skycrane_staged", "lmdeorbit", "shcatch", "shcatch_2x")
# missioncheck's cases in its own order, with headless undrawn seconds on an M-series
# Mac (only for launch order).
MISSIONS = {"launch_orbit": 40, "lunar_orbit": 55, "lunar_landing": 28, "skip_moon": 4,
            "ship_return": 45, "orbiter_return": 60, "orbiter_return_2x": 45, "orbiter_home": 300, "shuttle_fates": 90}
# The frames of shuttle_fates flown both undrawn and drawn by the parity check: liftoff
# from the pad and booster separation; at the end both boosters are falling on their
# own past apogee, so their state is in the digest.
PARITY_FRAMES = 13000
# --changed: repository paths (fnmatch, `*` crosses directories) → the checks (fnmatch
# on check names) that cover them. A tools/ file also selects every check whose command
# names it. Documentation selects nothing; any other unmapped path selects `dev`.
# Keep this in step with AGENTS.md "Checks" when a check or a subsystem is added.
CHANGED_RULES = (
    (("project.godot", "main.gd", "core/*", "export_presets.cfg"), ("*",)),
    (("sim/physics.gd", "sim/nbody.gd", "sim/world.gd", "native/*"),
     ("invariantcheck", "nbodycheck", "numericalcheck", "secularcheck", "sciencecheck", "savecheck", "sharedflightcheck-*",
      "missioncheck-*", "accretion*", "sharedtimecheck", "transitioncheck", "realismcheck")),
    (("sim/structure.gd", "sim/derive.gd", "sim/presets.gd", "sim/edupresets.gd", "sim/starcat.gd",
      "sim/stellar.gd", "sim/scale.gd", "sim/climate.gd", "sim/ebm.gd", "sim/suns.gd", "sim/bodies.gd"),
     ("presetcheck", "structureinputcheck", "editorcheck", "coursecheck", "invariantcheck", "nbodycheck",
      "secularcheck", "sciencecheck", "savecheck", "accretion*", "_soak_check-*", "realismcheck")),
    (("sim/lessons.gd", "sim/lessonui.gd", "sim/lightcurve.gd", "sim/gwdetector.gd", "sim/hrdiagram.gd",
      "sim/instrument_canvas.gd", "sim/masscurve.gd", "sim/crosssection.gd", "sim/cutaway.gd", "sim/foundry.gd",
      "sim/perihelion.gd"),
     ("coursecheck", "editorcheck", "structureinputcheck", "_soak_check-*")),
    # The chirp template, the perihelion meter (with edu_mercury's 1PN rate) and the dates.
    (("sim/gwdetector.gd", "sim/perihelion.gd", "sim/timescales.gd", "sim/edupresets.gd"), ("sciencecheck",)),
    # The shock layer's spectrum and the shader terms it hands the glow.
    (("sim/flight/plasma_spectrum.gd", "sim/flight/ionisation.gd", "shaders/flight/entry_plasma.gdshaderinc"),
     ("plasmacheck",)),
    # Flight physics, guidance and what hands state to them (craftmodel separates stages).
    (("sim/flight/vessel.gd", "sim/flight/guidance.gd", "sim/flight/mission.gd", "sim/flight/rocketry.gd",
      "sim/flight/orbit.gd", "sim/flight/fall.gd", "sim/flight/separation.gd", "sim/flight/spaceflight.gd",
      "sim/flight/relativity.gd", "sim/flight/dquat.gd", "sim/flight/catchtower.gd", "sim/flight/vehicles.gd",
      "sim/flight/craftmodel.gd", "sim/flight/ionisation.gd", "sim/flight/lunar_gravity.gd",
      "tools/fixtures/flight_fixture.json"),
     ("flighttimecheck", "flightphysicscheck", "spinframecheck", "sharedflightcheck-*", "flight-descent-*",
      "missioncheck-*", "scenariocheck")),
    (("sim/flight/scenarios.gd", "tools/scenariocheck.gd"), ("scenariocheck",)),
    # cloudcheck also tests the climatology: Terrain's CPU copy and the shader copy it must match.
    (("sim/flight/cloudfield.gd", "sim/flight/localview.gd", "shaders/flight/clouds.gdshaderinc", "sim/terrain.gd",
      "shaders/common/cloud_climate.gdshaderinc"), ("cloudcheck",)),
    # Any other flight file is presentation: the parity flight shows it cannot move physics.
    (("sim/flight/*",), ("flighttimecheck", "missioncheck-skip_moon", "missioncheck-parity-*")),
    # The flight sky's coefficients are checked numerically; its drawing by the render rule.
    (("sim/flight/sky_ms.gd", "sim/stellar.gd", "tools/build_sky_ms.py", "sim/flight/lagrange.gd"), ("flightphysicscheck",)),
    (("sim/flight/vehicles.gd", "sim/flight/craftmodel.gd", "sim/flight/craftassets.gd", "sim/flight/separation.gd",
      "sim/flight/material_detail.gd", "assets/*", "model_sources/*"), ("assetcheck", "craft-*")),
    (("sim/flight/launchsite.gd", "sim/flight/catchtower.gd", "model_sources/blender/launchpads.py"),
     ("padcheck", "flight-descent-shcatch*")),
    (("render/lens_pass.gd",), ("realismcheck",)),
    (("render/*", "shaders/*", "sim/*_visual.gd", "sim/sky.gd", "sim/skyview.gd", "sim/terrain.gd",
      "sim/prominence.gd", "sim/planetmaps.gd", "sim/marker.gd", "sim/trail.gd", "sim/painter.gd",
      "sim/spacetime_mesh.gd", "sim/flash.gd", "sim/titlereel.gd", "sim/flight/plume.gd", "sim/flight/localview.gd",
      "sim/flight/cloudfield.gd", "sim/flight/vapour.gd", "sim/flight/cryo.gd"),
     ("lenscheck", "skycachecheck", "presetcheck", "hud*", "_soak_check-*", "_leak_check", "missioncheck-parity-*")),
    (("ui/*",), ("hud*", "editorcheck", "structureinputcheck", "transitioncheck", "coursecheck", "_soak_check-*")),
    (("tools/runtime_checks.gd",), ("_soak_check-*", "_leak_check", "_shutdown_check", "presetcheck")),
    # Any other tool (fxlab, harnesses): at least it must still parse.
    (("tools/*",), ("import",)),
)
CHANGED_IGNORED = ("*.md", "docs/*", "web/*", "LICENSE*", ".github/*", "tools/evidence/*")
CA_ERROR = re.compile(r'^ERROR: Condition "ret != noErr" is true\. Returning: ""\n'
                      r'\s+at: get_system_ca_certificates \(platform/macos/os_macos\.mm:\d+\)\n?', re.MULTILINE)


class Check(NamedTuple):
    name: str
    command: list
    markers: object  # None, or a regex (or tuple of them) that must each match exactly one line
    timeout: float
    cost: float = 0  # rough idle seconds; --jobs launches the longest first
    alone: object = False  # True: nothing beside it; a string: only beside checks with the same string


def changed_files(ref):
    """Paths changed since the merge base with `ref`, staged, unstaged and untracked."""
    base = subprocess.run(["git", "merge-base", ref, "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    listed = subprocess.run(["git", "diff", "--name-only", base], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout
    return sorted({path.removesuffix(".uid") for path in (listed + untracked).splitlines() if path})


def changed_plan(plan, files, dev):
    """The checks in `plan` that cover `files` (CHANGED_RULES), import first; `dev` is
    the dev suite's checks, run for an unmapped path. Returns (plan, unmapped paths)."""
    wanted, unmapped = set(), []
    for path in files:
        if any(fnmatch.fnmatch(path, ignored) for ignored in CHANGED_IGNORED):
            continue
        hit = False
        for paths, selectors in CHANGED_RULES:
            if any(fnmatch.fnmatch(path, pattern) for pattern in paths):
                hit = True
                wanted.update(check.name for check in plan if any(fnmatch.fnmatch(check.name, s) for s in selectors))
        if path.startswith("tools/"):
            stem = "tools/" + Path(path).stem + "."
            named = [check.name for check in plan if any(stem in str(part) for part in check.command)]
            hit = hit or bool(named)
            wanted.update(named)
        if not hit:
            unmapped.append(path)
            wanted.update(check.name for check in dev)
    if wanted:
        wanted.add("import")
    return [check for check in plan if check.name in wanted], unmapped


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

    # Windowed: only for checks that judge a rendered frame, read a GPU result or must
    # see SHADER ERRORs (printed on first render). The dummy renderer has none of these.
    def scene(name, marker, *args, timeout=300):
        return Check(name, base + ["--resolution", "1280x720", f"res://tools/{name}.tscn", "--", *args], marker, timeout)

    # Headless: the scene tree, visual nodes and their updates all run, nothing is drawn.
    def headless_scene(name, marker, *args, timeout=300):
        return Check(name, base + ["--headless", f"res://tools/{name}.tscn", "--", *args], marker, timeout)

    def mission(case, *args, timeout=1200):
        markers = (rf"^MISSION CHECK CASES {','.join(MISSIONS)}$", rf"^MISSION {case} ok\b", r"^MISSION CHECK DONE failures=0$")
        return headless_scene("missioncheck", markers, f"only={case}", *args, timeout=timeout)._replace(
            name=f"missioncheck-{case}", cost=MISSIONS[case])

    # Flies the same frames undrawn and drawn in one process; any difference in the
    # final state fails. Guards main.set_drawn's promise that skipping presentation
    # leaves physics bit-identical.
    def mission_parity(case, frames):
        markers = (rf"^MISSION PARITY {case} [0-9a-f]{{16}} ", r"^MISSION CHECK DONE failures=0$")
        return headless_scene("missioncheck", markers, f"only={case}", "parity=1", f"frames={frames}", timeout=900)._replace(
            name=f"missioncheck-parity-{case}")

    if suite == "dev":
        # The inner loop, under a minute: import, the numeric checks, one short mission
        # and a short drawn/undrawn parity flight. Nothing windowed.
        yield from (c for c in checks("fast", godot, output, repeat, export_preset) if c[0] != "reference-shots-selfcheck")
        yield mission("skip_moon", timeout=120)
        yield mission_parity("shuttle_fates", 1500)._replace(name="missioncheck-parity-short", cost=8)
    elif suite == "fast":
        # Everything else reads the import cache, so nothing runs beside the import.
        yield Check("import", base + ["--headless", "--import", "--quit"], None, 180, alone=True)
        yield ("reference-shots-selfcheck", [sys.executable, str(ROOT / "tools/reference_shots_test.py")],
               r"^REFERENCE SHOTS SELF-CHECK PASS$", 30)
        yield script("skycheck", r"^SKYCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("cameracheck", r"^CAMERACHECK DONE checks=[1-9]\d* failures=0$")
        yield script("invariantcheck", r"^INVARIANTCHECK DONE checks=[1-9]\d* failures=0 native=(?:true|false)$")
        yield script("sciencecheck", r"^sciencecheck: [1-9]\d* checks, 0 failed$")
        yield script("savecheck", r"^SAVECHECK ([1-9]\d*)/\1 checks passed \(platform=(?:macOS|Linux|Windows); native \+ forced backup publication\)\.$")
        yield script("secularcheck", r"^SECULARCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("flighttimecheck", r"^FLIGHT TIME PASS \(0 failures\)$")
        # ~100 s on an M5; CI's runners take about twice that.
        yield script("flightphysicscheck", r"^flightphysicscheck: PASS$", timeout=420)
        yield script("spinframecheck", r"^SPINFRAMECHECK DONE checks=[1-9]\d* failures=0$")
        yield script("cloudcheck", r"^CLOUDCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("plasmacheck", r"^PLASMACHECK DONE checks=[1-9]\d* failures=0$")
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
        for case in SHARED_FLIGHTS:
            shared = script("sharedflightcheck", (rf"^SHARED FLIGHT {case} PASS ", r"^SHARED FLIGHT DONE failures=0$"), f"only={case}", timeout=600)
            yield shared._replace(name=f"sharedflightcheck-{case}", cost=30)
        for case in DESCENTS:
            descent = script("flightcheck", r"^FLIGHT CHECK DONE scenarios=1 failures=0$",
                             f"only={case}", f"out={output / f'flight_descent-{case}.json'}", timeout=600)
            yield descent._replace(name=f"flight-descent-{case}", cost=10)
        # One mission per process, headless and undrawn: each is judged on its flown state,
        # and shuttle_fates' "still drawn" tests read node state, which headless keeps.
        # The case list guards against a mission check.py does not know. Each mission
        # fails on its own at a frame cap, so the limit only catches a hang.
        for case in MISSIONS:
            yield mission(case)
        yield mission_parity("shuttle_fates", PARITY_FRAMES)._replace(cost=60)
        # Every developer scenario, jumped to and checked against its declared state.
        yield Check("scenariocheck", base + ["--headless", "res://tools/scenariocheck.tscn"],
                    r"^SCENARIOCHECK DONE scenarios=[1-9]\d* failures=0$", 900, cost=120)
    elif suite == "scenario-replay":
        # Each fast-forwarded or built scenario against the flight played at 60 fps.
        yield Check("scenario-replay", base + ["--headless", "res://tools/scenariocheck.tscn", "--", "replay=1"],
                    r"^SCENARIOCHECK DONE scenarios=[1-9]\d* failures=0$", 3600)
    elif suite == "rendered":
        # Windowed: lens and skycache read GPU results and pixels; coursecheck and the
        # accretion checks collect the errors a drawn frame raises (SHADER ERROR included);
        # hudcheck screenshots and drives real input over laid-out Controls; presetcheck
        # attributes each scenario's render errors. The rest judge state and run headless.
        yield scene("lenscheck", r"^LENSCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("skycachecheck", r"^SKYCACHECHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("coursecheck", r"^COURSE 36L 111S 0E$")
        yield scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1")
        startup_low = scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1", "quality=low")
        yield ("hud-low-startup", *startup_low[1:])
        layout = scene("hudcheck", r"^HUDCHECK LAYOUT [1-9]\d* passed, 0 failed$", "hlayout=1", "assets=0", "padmodels=0")
        yield ("hud-layout", *layout[1:])
        yield headless_scene("sharedtimecheck", r"^SHARED TIME DONE checks=[1-9]\d* failures=0$", "assets=0")
        yield headless_scene("transitioncheck", r"^TRANSITIONCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("structureinputcheck", r"^STRUCTUREINPUTCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("editorcheck", r"^EDITORCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("realismcheck", r"^REALISMCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$")
        accretion_gd = scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$", "native=0")
        yield ("accretion-gdscript", *accretion_gd[1:])
        yield ("presetcheck", ["sh", str(ROOT / "tools/presetcheck.sh"), str(output / "presets-engine.log")],
               r"^PRESETCHECK DONE 36$", 300)
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
        # Windowed: the dummy renderer creates the visual nodes but none of the RenderingDevice
        # or render-thread resources a leak could hide in. One soak feature per process, so
        # their fixed settle waits overlap; the counts are per process, as each feature's
        # rounds are compared only with its own first round.
        def lifecycle(name, method, marker, *args):
            return Check(name, base + ["--verbose", "--resolution", "1280x720", "--", "mode=sandbox", "preset=solar", "rounds=5",
                                       f"eval={method}", *args], marker, 900, cost=40, alone="lifecycle")
        for feature in SOAK_FEATURES:
            yield lifecycle(f"_soak_check-{feature}", "_soak_check",
                            (rf"^SOAK FEATURES {','.join(SOAK_FEATURES)}$", rf"^SOAK {feature} +\d", r"^SOAK DONE$"), f"soak={feature}")
        yield lifecycle("_leak_check", "_leak_check", r"^LEAKCHECK DONE$")
        yield lifecycle("_shutdown_check", "_shutdown_check", r"^SHUTDOWNCHECK DONE$")
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
        cpu = None
        try:
            code, cpu = wait_child(process, options.timeout or timeout)
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
    cpu_text = f" cpu {cpu}s" if cpu is not None else ""
    lines.append(f"{'FAIL' if problem else 'PASS'} {name} {elapsed}s{cpu_text}" + (f": {problem}" if problem else ""))
    lines.append(f"  {log}")
    return {"name": name, "command": command, "exit_code": code, "problem": problem,
            "seconds": elapsed, "cpu_seconds": cpu, "log": str(log), "engine_log": str(engine_log) if engine_log else None,
            "allowed_ca_diagnostics": ignored, "focus_restored": restored,
            "renderer": next((line for line in raw.splitlines() if re.match(r"^(?:Metal|Vulkan|OpenGL).*Using Device", line)), None),
            "metrics": [line for line in raw.splitlines() if line.startswith(("SHARED TIME BENCH", "SHARED TIME CONFIG", "HUDCHECK PERF", "HUDCHECK CONFIG", "NBODYCHECK PASS", "STABILITYCHECK", "STABILITYDIAGNOSTIC"))]}, lines


def wait_child(process, timeout):
    """Wait for `process`; returns (exit code, CPU seconds of it and the children it
    reaped, or None where wait4 is unavailable). Raises TimeoutExpired."""
    if not hasattr(os, "wait4"):
        return process.wait(timeout=timeout), None
    deadline = time.monotonic() + timeout
    while True:
        pid, status, usage = os.wait4(process.pid, os.WNOHANG)
        if pid:
            process.returncode = os.waitstatus_to_exitcode(status)
            return process.returncode, round(usage.ru_utime + usage.ru_stime, 3)
        if time.monotonic() > deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        time.sleep(0.05)


def runs_dir():
    """Live run status and learned durations. Under the git common dir, so every
    worktree of this clone shares it and `--watch` sees runs an agent started."""
    try:
        common = metadata(["git", "rev-parse", "--git-common-dir"])
    except (OSError, subprocess.SubprocessError):
        common = "unavailable"
    return (ROOT / common if common != "unavailable" else ROOT / "tools/evidence") / "astrarium-check"


def duration(seconds):
    seconds = int(seconds)
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def read_times(folder):
    """Learned check durations, or {} when the file is missing or not a mapping."""
    try:
        history = json.loads((folder / "times.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return history if isinstance(history, dict) else {}


class Progress:
    """What a person needs while checks run: how many are left, what is running and
    for how long, and which look stuck. A terminal gets a redrawn status line; piped
    output (an agent's) gets a PROGRESS line every BEAT seconds. Either way the state
    goes to runs_dir()/<pid>.json for `check.py --watch`. Status I/O never fails a run."""
    BEAT = 30
    QUIET = 120  # seconds without log output before a running check is flagged

    def __init__(self, plan, output, options):
        self.plan, self.output, self.jobs = plan, output, options.jobs
        self.timeouts = [options.timeout or check.timeout for check in plan]
        self.tty = sys.stdout.isatty()
        self.started = time.monotonic()
        self.started_utc = datetime.datetime.now(datetime.timezone.utc).isoformat()
        self.argv = sys.argv[1:]
        self.running, self.done, self.warned, self.learned = {}, {}, set(), {}
        self.stopping = False
        self.beat = self.started
        self.drawn = False
        self.dir = runs_dir()
        self.keys, seen = [], {}
        for check in plan:  # padcheck runs under one name several times: key by occurrence
            seen[check.name] = seen.get(check.name, -1) + 1
            self.keys.append(f"{check.name}#{seen[check.name]}")
        history = read_times(self.dir)
        self.expected = [history.get(key) or check.cost or None for key, check in zip(self.keys, plan)]

    def start(self, index):
        self.running[index] = time.monotonic()

    def finish(self, index, passed, seconds):
        self.running.pop(index, None)
        self.done[index] = passed
        if passed:
            self.expected[index] = self.learned[self.keys[index]] = seconds

    def quiet(self, index, now):
        """Seconds since the check's logs last grew (or since it started)."""
        latest = self.running[index]
        log = self.output / f"{index:02d}-{self.plan[index].name}.log"
        for path in (log, log.with_suffix(".engine.log")):
            with contextlib.suppress(OSError):
                latest = max(latest, now - (time.time() - path.stat().st_mtime))
        return now - latest

    def snapshot(self):
        now = time.monotonic()
        running = []
        for index, began in sorted(self.running.items(), key=lambda item: item[1]):
            elapsed, expected, timeout = now - began, self.expected[index], self.timeouts[index]
            quiet = self.quiet(index, now)
            flag = ("near timeout" if elapsed > 0.75 * timeout
                    else "slower than usual" if expected and elapsed > 1.5 * expected and elapsed - expected > 30
                    # Long missions print little: silence matters once a check is past its usual time.
                    else f"no output {duration(quiet)}" if quiet > self.QUIET and not (expected and elapsed < expected) else None)
            running.append({"name": self.plan[index].name, "log": str(self.output / f"{index:02d}-{self.plan[index].name}.log"), "seconds": round(elapsed), "expected": expected and round(expected),
                            "timeout": timeout, "quiet": round(quiet), "flag": flag})
        waiting = [i for i in range(len(self.plan)) if i not in self.done and i not in self.running]
        # Parallel work shares the jobs; alone checks run end to end.
        left = [max((self.expected[i] or 0) - (now - began), 0) for i, began in self.running.items()]
        shared = sum(left) + sum(self.expected[i] or 0 for i in waiting if self.plan[i].alone is not True)
        alone = sum(self.expected[i] or 0 for i in waiting if self.plan[i].alone is True)
        unknown = sum(1 for i in [*self.running, *waiting] if not self.expected[i])
        return {"pid": os.getpid(), "root": str(ROOT), "args": self.argv, "log_dir": str(self.output),
                "started_utc": self.started_utc, "updated": time.time(), "elapsed": round(now - self.started),
                "total": len(self.plan), "passed": sum(self.done.values()), "failed": [self.plan[i].name for i, ok in self.done.items() if not ok],
                "stopping": self.stopping, "running": running, "waiting": [self.plan[i].name for i in waiting],
                "eta": None if self.stopping else round(max([*left, 0]) if not waiting and not running else max(max(left, default=0), shared / self.jobs) + alone),
                "eta_unknown": unknown, "finished": None}

    @staticmethod
    def render(state, width=None):
        """One summary line plus a line per running check."""
        done = state["passed"] + len(state["failed"])
        head = f"[{done}/{state['total']}] {len(state['running'])} running, {len(state['waiting'])} waiting, {duration(state['elapsed'])} elapsed"
        if state["failed"]:
            head += f", FAILED {', '.join(state['failed'])}"
        if state["stopping"]:
            head += "; stopping after the failure"
        elif state["eta"] is not None and (state["running"] or state["waiting"]):
            head += f", ~{duration(state['eta'])} left" + (f" (+{state['eta_unknown']} unmeasured)" if state["eta_unknown"] else "")
        lines = [head]
        for check in state["running"]:
            usual = f" (usually {duration(check['expected'])})" if check["expected"] else ""
            lines.append(f"  {check['name']}: {duration(check['seconds'])}{usual}, timeout {duration(check['timeout'])}"
                         + (f"  <- {check['flag']}" if check["flag"] else ""))
        return [line[:width] for line in lines] if width else lines

    def write(self, state):
        with contextlib.suppress(OSError):
            self.dir.mkdir(parents=True, exist_ok=True)
            path = self.dir / f"{os.getpid()}.json"
            temporary = path.with_suffix(".tmp")
            temporary.write_text(json.dumps(state), encoding="utf-8")
            temporary.replace(path)

    def clear(self):
        if self.drawn:
            sys.stdout.write("\r\x1b[J")
            self.drawn = False

    def say(self, line):
        self.clear()
        print(line, flush=True)
        self.tick()

    def tick(self):
        state = self.snapshot()
        self.write(state)
        for check in state["running"]:
            if check["flag"] and (check["name"], check["flag"].split()[0]) not in self.warned:
                self.warned.add((check["name"], check["flag"].split()[0]))
                self.clear()
                print(f"WARN {check['name']} {check['flag']} after {duration(check['seconds'])}: {check['log']}", flush=True)
        if self.tty:
            self.clear()
            size = shutil.get_terminal_size()
            lines = self.render(state, size.columns - 1)
            if len(lines) > size.lines - 2:
                lines = [*lines[:max(size.lines - 3, 1)], f"  ... {len(lines) - max(size.lines - 3, 1)} more running"]
            # Leave the cursor at the start of the block so clear() erases all of it.
            sys.stdout.write("\n".join(lines) + (f"\x1b[{len(lines) - 1}A" if len(lines) > 1 else "") + "\r")
            sys.stdout.flush()
            self.drawn = True
        elif time.monotonic() - self.beat >= self.BEAT and state["running"]:
            self.beat = time.monotonic()
            print("PROGRESS " + "\n".join(self.render(state)), flush=True)

    def close(self, complete):
        self.clear()
        state = self.snapshot()
        state["finished"] = "passed" if complete else "failed" if state["failed"] else "interrupted"
        self.write(state)
        if self.learned:
            # Concurrent runs can still drop each other's newest times (last writer wins);
            # the replace keeps readers from seeing a partial file.
            with contextlib.suppress(OSError):
                path = self.dir / "times.json"
                temporary = path.with_suffix(f".{os.getpid()}.tmp")
                temporary.write_text(json.dumps({**read_times(self.dir), **self.learned}, indent=1, sort_keys=True) + "\n",
                                     encoding="utf-8")
                temporary.replace(path)


def process_alive(pid):
    """False only when `pid` is known to have exited."""
    if os.name == "nt":
        # Signal 0 is CTRL_C_EVENT on Windows; os.kill would interrupt the console's runs.
        import ctypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
        if not handle:
            return ctypes.get_last_error() != 87  # ERROR_INVALID_PARAMETER: no such process
        code = ctypes.c_ulong()
        try:
            return not kernel.GetExitCodeProcess(ctypes.c_void_p(handle), ctypes.byref(code)) or code.value == 259
        finally:
            kernel.CloseHandle(ctypes.c_void_p(handle))
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    return True


def watch(once):
    """Print the runs in progress in every worktree of this clone, redrawn each second.
    Finished runs stay listed for ten minutes; a runner that vanished is shown as such."""
    folder = runs_dir()
    while True:
        blocks = []
        for path in sorted(folder.glob("*.json")) if folder.is_dir() else []:
            if path.name == "times.json":
                continue
            # A state file from another version or a partial write skips only that run.
            with contextlib.suppress(OSError, ValueError, KeyError, TypeError, AttributeError):
                state = json.loads(path.read_text(encoding="utf-8"))
                age = time.time() - state["updated"]
                alive = process_alive(state["pid"])
                if (state["finished"] or not alive) and age > 600:
                    path.unlink(missing_ok=True)
                    continue
                where = state["root"].replace(str(Path.home()), "~")
                title = f"pid {state['pid']} in {where}: check.py {' '.join(state['args'])}".rstrip()
                if state["finished"]:
                    title += f"  [{state['finished']} {duration(age)} ago]"
                elif not alive:
                    title += "  [runner exited without finishing]"
                elif age > 10:
                    title += f"  [no update for {duration(age)}; runner busy or stuck]"
                blocks.append([title, *("  " + line for line in Progress.render(state)), f"  logs {state['log_dir']}"])
        text = "\n\n".join("\n".join(block) for block in blocks) or "no check runs in progress"
        if once:
            print(text)
            return 0
        sys.stdout.write("\x1b[H\x1b[2J" + text + "\n\n(Ctrl-C to stop watching; the runs continue)\n")
        sys.stdout.flush()
        try:
            time.sleep(1)
        except KeyboardInterrupt:
            return 0


def print_times(report, compare):
    """Each check's wall and CPU seconds, slowest first, so a check that has grown
    slower shows. With an earlier report, flag checks over 1.25× and 5 s slower."""
    def keyed(results):
        # Several checks share a name (padcheck per asset/pad option): match them in order.
        seen = {}
        for result in results:
            seen[result["name"]] = seen.get(result["name"], -1) + 1
            yield (result["name"], seen[result["name"]]), result
    earlier = {}
    if compare:
        earlier = {key: r.get("seconds") for key, r in keyed(json.loads(Path(compare).read_text()).get("results", []))}
    print("TIMES wall s / cpu s" + (f" / was (wall s) from {compare}" if compare else ""), flush=True)
    for key, result in sorted(keyed(report["results"]), key=lambda kr: -kr[1]["seconds"]):
        was = earlier.get(key)
        cpu = result.get("cpu_seconds")
        flag = " SLOWER" if was and result["seconds"] > 1.25 * was and result["seconds"] - was > 5 else ""
        print(f"  {result['name']:<44} {result['seconds']:>8.1f} {cpu if cpu is not None else float('nan'):>8.1f}"
              + (f" {was:>8.1f}{flag}" if was is not None else ""), flush=True)
    cpu = sum(r.get("cpu_seconds") or 0.0 for r in report["results"])
    print(f"TOTAL wall {report['wall_seconds']}s, check cpu {round(cpu, 1)}s, {len(report['results'])} checks", flush=True)


def run_plan(plan, output, options, guard, report):
    """Run checks up to options.jobs at a time. A check marked alone waits for the
    running ones and runs by itself. After a failure nothing new starts; running
    checks finish. Results print and enter the report in plan order."""
    done = queue.Queue()
    progress = Progress(plan, output, options)
    complete = False
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
                    progress.say(line)
                report["results"].append(result)
            printed += 1

    # Segments: runs of parallel checks between checks that run alone.
    segments = []
    for index, check in enumerate(plan):
        last = plan[segments[-1][-1]] if segments else None
        if last is None or check.alone is True or last.alone is True or check.alone != last.alone:
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
                    progress.say(f"RUN {plan[index].name}")
                    progress.start(index)
                    threading.Thread(target=worker, args=(index,), daemon=True).start()
                    running += 1
                if running == 0:
                    break
                try:
                    index, outcome, error = done.get(timeout=1)
                except queue.Empty:
                    progress.tick()
                    continue
                running -= 1
                if error is not None:
                    raise error
                finished[index] = outcome
                progress.finish(index, outcome[0]["problem"] is None, outcome[0]["seconds"])
                stopped = stopped or outcome[0]["problem"] is not None
                progress.stopping = stopped
                flush()
            if stopped:
                break
        complete = not stopped
        return complete
    finally:
        for process in list(live.values()):
            if process.poll() is None:
                if os.name == "posix":
                    os.killpg(process.pid, signal.SIGKILL)
                else:
                    process.kill()
        flush(final=True)
        progress.close(complete)


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
    parser.add_argument("--changed", nargs="?", const="HEAD", metavar="REF",
                        help="run only the checks covering files changed since REF's merge base (default HEAD: "
                             "uncommitted work), from the selected suites or else dev..lifecycle")
    parser.add_argument("--list", action="store_true", help="print the planned checks and exit")
    parser.add_argument("--watch", action="store_true",
                        help="show the check runs in progress in any worktree of this clone (e.g. an agent's), live")
    parser.add_argument("--status", action="store_true", help="print the --watch view once and exit")
    parser.add_argument("--compare", type=Path, metavar="REPORT", help="show each check's time against an earlier report.json")
    parser.add_argument("--export-preset", default={"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}.get(platform.system(), "macOS"))
    options = parser.parse_args()
    if options.watch or options.status:
        return watch(once=options.status)
    options.suites = options.suites or (["dev", "fast", "native", "flight", "rendered", "assets", "procedural", "lifecycle"]
                                        if options.changed else ["fast"])
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
    # Suites share checks (dev runs fast's); each runs once.
    seen = set()
    plan = [check for check in plan if (check.name, tuple(map(str, check.command))) not in seen
            and not seen.add((check.name, tuple(map(str, check.command))))]
    if options.changed:
        files = changed_files(options.changed)
        dev = [Check(*c) for c in checks("dev", options.godot, output, options.repeat, options.export_preset)]
        plan, unmapped = changed_plan(plan, files, dev)
        report["changed"] = {"ref": options.changed, "files": files, "unmapped": unmapped}
        print(f"CHANGED {len(files)} files since {options.changed}; {len(plan)} checks"
              + (f"; unmapped (dev suite): {', '.join(unmapped)}" if unmapped else ""), flush=True)
    if options.list:
        for check in plan:
            print(f"{check.name}{'' if not check.alone else ' (alone)' if check.alone is True else f' ({check.alone})'}"
                  f"{' headless' if '--headless' in check.command else ' windowed' if check.command[0] == options.godot else ''}")
        return 0
    started = time.monotonic()
    try:
        if options.changed and not plan:
            # Nothing ran, so nothing is verified: not a pass, even for a docs-only change.
            print("CHANGED no checks selected; name a suite to run one", flush=True)
            return 1
        with FocusGuard() if options.background else contextlib.nullcontext() as guard:
            if not run_plan(plan, output, options, guard, report):
                return 1
        report["complete"] = True
        return 0
    finally:
        report["wall_seconds"] = round(time.monotonic() - started, 1)
        path = output / "report.json"
        path.write_text(json.dumps(report, indent=2) + "\n")
        print_times(report, options.compare)
        print(f"REPORT {path}", flush=True)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"CHECK FAILED: {error}")
