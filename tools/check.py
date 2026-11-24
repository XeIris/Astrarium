#!/usr/bin/env python3
"""Run selected verification suites; retain logs and reject incomplete runs."""
import argparse
import contextlib
import datetime
import difflib
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import platform
import queue
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
SUITES = ("dev", "fast", "encounters", "native", "flight", "scenario-replay", "rendered", "assets", "procedural", "clean", "lifecycle", "export", "compatibility", "perf", "m5-budget", "m5-medium", "stability", "stability-study", "mutation")
ENGINE_ERROR = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):", re.MULTILINE)
# Each check in these runs with nothing beside it: they measure time, run check.py
# themselves (clean), read the previous step's output (export), need exact object
# counts (lifecycle; its checks run beside each other only, see `alone`), or break the
# tree in place (mutation).
ALONE = {"perf", "m5-budget", "m5-medium", "stability", "stability-study", "clean", "export", "lifecycle", "mutation"}
# The soak's features in runtime_checks.gd's order, one process each.
SOAK_FEATURES = ("spawn_remove", "edit_mass", "true_scale", "editor", "paint", "xsec", "cam_modes", "quality",
                 "lessons", "voyager", "model_viewer", "eva_pod", "ranger", "discovery", "docking", "kerr",
                 "flight_stage", "flight_catch", "scenario", "showcase", "surface", "observatory", "galaxy", "encounter", "join", "start_screen")
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
    (("sim/voyager/*", "ui/voyager_*.gd", "assets/voyager/*", "model_sources/voyager.py",
      "tools/build_voyager.py", "tools/voyagercheck.*", "sim/flight/modelviewer.gd", "ui/hangar.gd"),
     ("voyagercheck", "_soak_check-voyager")),
    (("sim/flight/docking_session.gd", "tools/dockingmissioncheck.*", "tools/dockingclearance.gd", "ui/hangar.gd", "ui/flight_console.gd",
      "ui/control_bindings.gd", "sim/flight/scenarios.gd", "sim/flight/endurance_craft.gd"), ("dockingmissioncheck*", "dockingscenarios", "dockingflightshots", "_soak_check-docking")),
    (("sim/flight/kerr_circular.gd", "sim/flight/spaceflight.gd", "sim/presets.gd"),
     ("kerrflightcheck", "kerrflightshots", "lenscheck", "_soak_check-kerr")),
    (("sim/flight/mission.gd",), ("missionguidancecheck", "discoveryflightcheck")),
    (("sim/flight/lander_craft.gd", "model_sources/blender/lander.py"), ("craft-*", "assetcheck")),
    (("sim/flight/endurance_craft.gd", "model_sources/blender/endurance.py"), ("endurancecheck-*", "craft-*", "assetcheck")),
    (("model_sources/blender/movie_materials.py",), ("endurancecheck-*", "discoverycheck-*", "craft-*", "assetcheck")),
    (("sim/flight/vessel.gd",), ("soicheck", "discoveryflightcheck")),
    (("sim/flight/kerr_circular.gd",), ("kerrcircularcheck",)),
    (("sim/flight/finite_burn.gd",), ("finiteburncheck", "discoveryflightcheck", "flightphysicscheck")),
    (("sim/flight/orbit.gd",), ("orbitcheck", "flightphysicscheck", "flighttimecheck", "missioncheck-*", "discoveryflightcheck")),
    (("sim/flight/discovery_craft.gd", "sim/flight/centrifuge.gd", "sim/jovian_moons.gd", "model_sources/blender/discovery.py"),
     ("discoverycheck-*", "discoveryflightcheck", "discoveryflightshots", "craft-*", "assetcheck", "hudcheck", "_soak_check-discovery")),
    (("model_sources/blender/cabin_displays.py",), ("rangercheck-*", "rangerflightshots", "evapodcheck*", "evapodflightshots")),
    (("sim/flight/ranger_craft.gd", "model_sources/blender/ranger.py", "model_sources/blender/movie_materials.py",
      "sim/flight/craft_interior.gd", "sim/flight/localview.gd", "sim/flight/vehicles.gd", "tools/craftspec.gd"),
     ("rangercheck-*", "rangerflightcheck", "rangerflightshots", "_soak_check-ranger", "scenariocheck")),
    (("sim/flight/eva_pod.gd", "sim/flight/craft_interior.gd", "sim/flight/vehicles.gd",
      "sim/flight/localview.gd", "sim/flight/spaceflight.gd", "model_sources/blender/evapod*.py",
      "model_sources/blender/common.py", "tools/craftspec.gd"),
     ("evapodcheck*", "evapodflightshots", "_soak_check-eva_pod")),
    (("project.godot", "main.gd", "core/*", "export_presets.cfg"), ("*",)),
    (("sim/physics.gd", "sim/nbody.gd", "sim/world.gd", "native/*"),
     ("galaxycheck", "encountercheck", "invariantcheck", "nbodycheck", "numericalcheck", "secularcheck", "sciencecheck", "savecheck", "sharedflightcheck-*",
      "missioncheck-*", "accretion*", "sharedtimecheck", "transitioncheck", "realismcheck", "flightphysicscheck")),
    (("sim/structure.gd", "sim/derive.gd", "sim/presets.gd", "sim/edupresets.gd", "sim/starcat.gd",
      "sim/stellar.gd", "sim/scale.gd", "sim/climate.gd", "sim/climate_inputs.gd", "sim/atmosphere.gd", "sim/ebm.gd", "sim/suns.gd", "sim/bodies.gd"),
     ("presetcheck", "structureinputcheck", "editorcheck", "coursecheck", "invariantcheck", "nbodycheck",
      "secularcheck", "sciencecheck", "savecheck", "accretion*", "_soak_check-*", "realismcheck")),
    # What runs on the ground, and the proof it runs nowhere else.
    (("sim/surface/*", "shaders/surface/*", "shaders/observatory/site_terrain.gdshader", "sim/showcase.gd", "sim/planet_pin.gd", "sim/climate_look.gd",
      "sim/planet_elevation.gd", "assets/planet-relief/*", "sim/flight/localview.gd", "sim/observatory/site_scene.gd"),
     ("surfacecheck", "surfacepixelcheck*", "_soak_check-showcase", "_soak_check-surface", "groundcheck", "groundlookcheck", "seacheck")),
    (("shaders/surface/*", "tools/groundlookcheck.*", "sim/surface/surface_shadow.gd"), ("groundlookcheck",)),
    # The sea: its FFT field and liquids, what floats on it, and the GPU's half of it.
    (("sim/surface/ocean_field.gd", "sim/surface/surface_waves.gd", "sim/surface/liquid.gd", "sim/surface/floater.gd",
      "sim/surface/capsule.gd", "tools/oceancheck.gd"), ("oceancheck", "seacheck", "oceanlookcheck")),
    (("sim/surface/ocean_gpu.gd", "shaders/surface/ocean_fft.glsl", "shaders/surface/water.gdshader", "tools/oceanlookcheck.*"),
     ("oceanlookcheck",)),
    (("sim/surface/surface_sea.gd", "tools/seacheck.*"), ("seacheck",)),
    # The CPU's crust is held to the shader's; the pin and the showcase read it.
    (("sim/planet_relief.gd", "sim/planet_pin.gd", "sim/showcase.gd", "shaders/bodies/terrain.gdshaderinc",
      "shaders/bodies/terrain_noise.gdshaderinc", "shaders/bodies/rocky_surface.gdshader", "shaders/bodies/pin_marker.gdshader",
      "sim/rocky_visual.gd", "sim/planetmaps.gd", "tools/terrain_probe.gdshader", "sim/planet_elevation.gd",
      "assets/planet-relief/*", "tools/build_planet_relief.py"),
     ("pincheck", "pincheck-gpu", "hud*", "_soak_check-showcase")),
    # How a world looks: the derived values headless, and the frames with pixels=1.
    (("sim/climate_look.gd", "sim/rocky_visual.gd", "sim/world.gd", "sim/terrain.gd", "sim/climate.gd", "sim/atmosphere.gd",
      "shaders/bodies/rocky_surface.gdshader", "shaders/bodies/terrain.gdshaderinc", "shaders/bodies/cloud_deck.gdshader"),
     ("lookcheck", "lookpixelcheck*")),
    (("sim/composition.gd", "ui/composition_editor.gd", "ui/widgets/composition_pie.gd", "sim/foundry.gd", "sim/climate.gd",
      "sim/climate_inputs.gd", "sim/atmosphere.gd"), ("compositioncheck", "hud*", "editorcheck", "realismcheck")),
    (("sim/lessons.gd", "sim/lessonui.gd", "sim/lightcurve.gd", "sim/gwdetector.gd", "sim/hrdiagram.gd",
      "sim/instrument_canvas.gd", "sim/masscurve.gd", "sim/crosssection.gd", "sim/cutaway.gd", "sim/foundry.gd",
      "sim/perihelion.gd"),
     ("coursecheck", "editorcheck", "structureinputcheck", "_soak_check-*")),
    # The photometer replay, the chirp template, the perihelion meter (with edu_mercury's 1PN rate) and the dates.
    (("sim/lightcurve.gd", "sim/gwdetector.gd", "sim/perihelion.gd", "sim/timescales.gd", "sim/edupresets.gd"),
     ("sciencecheck",)),
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
      "missioncheck-*", "scenariocheck", "groundcheck", "seacheck")),
    (("tools/groundcheck.*",), ("groundcheck",)),
    (("sim/surface/rover*.gd", "shaders/surface/track.gdshader", "tools/rovercheck.gd"), ("rovercheck", "groundcheck")),
    (("sim/surface/rotorcraft*.gd", "tools/rotorcheck.gd"), ("rotorcheck", "groundcheck")),
    (("sim/flight/scenarios.gd", "tools/scenariocheck.gd"), ("scenariocheck",)),
    # cloudcheck also tests the climatology: Terrain's CPU copy and the shader copy it must match.
    (("sim/flight/cloudfield.gd", "sim/flight/localview.gd", "shaders/flight/clouds*", "render/flight_cloud_pass.gd", "sim/terrain.gd",
      "shaders/common/cloud_climate.gdshaderinc"), ("cloudcheck", "flightlightcheck", "surfacepixelcheck*")),
    # What lights a vehicle, as drawn.
    (("sim/flight/localview.gd", "sim/flight/spaceflight.gd", "shaders/flight/ground.gdshader"), ("flightlightcheck",)),
    # Any other flight file is presentation: the parity flight shows it cannot move physics.
    (("sim/flight/*",), ("flighttimecheck", "missioncheck-skip_moon", "missioncheck-parity-*")),
    # The flight sky's coefficients are checked numerically; its drawing by the render rule.
    (("sim/flight/sky_ms.gd", "sim/stellar.gd", "tools/build_sky_ms.py", "sim/flight/lagrange.gd"), ("flightphysicscheck",)),
    (("sim/flight/vehicles.gd", "sim/flight/craftmodel.gd", "sim/flight/craftassets.gd", "sim/flight/separation.gd",
      "sim/flight/material_detail.gd", "assets/*", "model_sources/*"), ("assetcheck", "craft-*")),
    (("sim/flight/launchsite.gd", "sim/flight/catchtower.gd", "model_sources/blender/launchpads.py"),
     ("padcheck", "flight-descent-shcatch*")),
    (("render/lens_pass.gd", "sim/brightstars.gd", "assets/sky/*", "tools/build_gaia.py"), ("realismcheck",)),
    # The Observatory: Earth's orientation, ΔT, sites, the date controls and the overlay.
    (("sim/observatory/*", "sim/timescales.gd", "sim/brightstars.gd", "assets/sky/*", "assets/sites/*", "sim/presets.gd",
      "shaders/observatory/*", "ui/site_picker.gd", "model_sources/blender/observatories.py",
      "tools/build_starcat.py", "tools/build_gaia.py", "tools/build_constellations.py", "tools/build_deltat.py",
      "tools/build_nutation.py", "tools/build_site_terrain.py"),
     ("observatorycheck", "observatorycheck-assets", "observatorystagecheck", "observatorylookcheck", "imagingcheck", "hud*", "_soak_check-observatory")),
    # The Observatory's sky as drawn: the dome it shares with flight, and the markers.
    (("shaders/flight/sky_dome.gdshader", "sim/marker.gd", "shaders/bodies/marker_point.gdshader", "sim/rocky_visual.gd",
      "sim/flight/localview.gd"),
     ("observatorylookcheck", "observatorystagecheck")),
    # Picking and the selection reticle.
    (("core/orrery_camera.gd", "sim/marker.gd", "shaders/bodies/marker_point.gdshader"), ("cameracheck",)),
    (("ui/plate_view.gd", "sim/planetmaps.gd", "assets/planet-maps/*"), ("imagingcheck",)),
    # The Moon's mapped face (moon_face).
    (("sim/rocky_visual.gd",), ("observatorycheck",)),
    (("render/*", "shaders/*", "sim/*_visual.gd", "sim/sky.gd", "sim/skyview.gd", "sim/terrain.gd",
      "sim/prominence.gd", "sim/planetmaps.gd", "sim/marker.gd", "sim/trail.gd", "sim/painter.gd",
      "sim/spacetime_mesh.gd", "sim/flash.gd", "sim/titlereel.gd", "sim/flight/plume.gd", "sim/flight/localview.gd",
      "sim/flight/cloudfield.gd", "sim/flight/vapour.gd", "sim/flight/cryo.gd"),
     ("lenscheck", "skycachecheck", "presetcheck", "hud*", "_soak_check-*", "_leak_check", "missioncheck-parity-*")),
    # How large a point source is drawn: the rule, its three users, and the bloom that spreads them.
    (("shaders/common/point_source.gdshaderinc", "shaders/sky/*", "shaders/bodies/marker_point.gdshader", "shaders/post/*",
      "sim/marker.gd", "sim/brightstars.gd", "sim/sky.gd", "render/postfx.gd"), ("glowcheck",)),
    (("ui/*",), ("hud*", "editorcheck", "compositioncheck", "structureinputcheck", "transitioncheck", "coursecheck", "_soak_check-*")),
    # The galactic scene: its physics headless, how it looks windowed, and the soak.
    (("sim/galaxy/*", "shaders/galaxy/*", "ui/widgets/rotation_chart.gd", "assets/sky/neighbourhood.bin",
      "tools/build_neighbourhood.py", "assets/galaxy/*", "tools/build_local_dust.py", "tools/build_local_dust_grid.py"),
     ("galaxycheck", "encountercheck", "galaxylookcheck", "coursecheck", "_soak_check-galaxy", "_soak_check-encounter", "_soak_check-join", "hud*")),
    # The live encounters' six-minute replay: only what moves their particles.
    (("sim/galaxy/gal_encounter.gd", "sim/galaxy/gal_live.gd", "sim/galaxy/gal_orbits.gd", "sim/galaxy/gal_eddington.gd",
      "sim/galaxy/gal_models.gd", "native/*", "tools/encounterlivecheck.gd"), ("encounterlivecheck",)),
    (("tools/galaxycheck.gd",), ("galaxycheck",)),
    (("tools/encountercheck.gd",), ("encountercheck",)),
    # galaxycheck also reads the Solar System sky's catalogues and its galactic frame.
    (("assets/sky/bsc5.bin", "assets/sky/gaia_g8.bin", "sim/brightstars.gd", "sim/sky.gd",
      "tools/build_gaia.py", "tools/build_starcat.py"), ("galaxycheck",)),
    (("tools/galaxylookcheck.gd", "tools/galaxylookcheck.tscn"), ("galaxylookcheck",)),
    (("render/pipeline.gd", "render/postfx.gd", "shaders/post/compose.glsl", "shaders/post/local_coverage.glsl"),
     ("galaxylookcheck", "flightlightcheck")),
    (("tools/runtime_checks.gd",), ("_soak_check-*", "_leak_check", "_shutdown_check", "presetcheck")),
    (("tools/check.py",), ("check-selfcheck",)),
    # Any other tool (fxlab, harnesses): at least it must still parse.
    (("tools/*",), ("import",)),
)
CHANGED_IGNORED = ("*.md", "docs/*", "web/*", "LICENSE*", ".github/*", "tools/evidence/*")
# Selected beside CHANGED_RULES without covering the path: an unmapped file still selects `dev`.
CHANGED_ALSO = ((("sim/*", "ui/*", "core/*", "render/*", "main.gd", "native/*"), ("rulecheck",)),)
CA_ERROR = re.compile(r'^ERROR: Condition "ret != noErr" is true\. Returning: ""\n'
                      r'\s+at: get_system_ca_certificates \(platform/macos/os_macos\.mm:\d+\)\n?', re.MULTILINE)
# The CA diagnostic's first line, read before its `at:` line was written.
CA_PENDING = re.compile(r'^ERROR: Condition "ret != noErr" is true\. Returning: ""\n?\Z', re.MULTILINE)
# A GDScript error ends the function it is in, so a check's quit() is often never reached
# and Godot idles until the timeout (at under 1% of a core, measured).
ERROR_QUIET = 10  # s: a child this long silent after an engine error is stopped; it has failed already
STALL_CPU = 0.03  # share of one core under which a silent child counts as idle
RUN_TIMEOUT = 300  # s: --run's limit unless --timeout gives one
STOP_GRACE = 5  # s from SIGTERM to SIGKILL when a child is stopped; Godot exits on SIGTERM at once
FAILURE_LINE = re.compile(r"(?:^|\s)(?:SCRIPT ERROR|SHADER ERROR|ERROR):|\bFAIL|^Traceback|^\w*Error\b")
EPILOG = """exit status: 0 every check passed; 1 a check failed (a timeout, a stall or an engine
error included); 2 bad arguments; 3 incomplete without a failure (--budget ran out); 128+N
stopped by signal N. Children are stopped with the runner, whatever stops it except SIGKILL;
the next run stops what a killed runner left behind.

examples:
  check.py --changed --budget 540          what the change touches, inside a 10-minute tool limit
  check.py --only invariantcheck,secular*  named checks (globs) from any suite
  check.py --timeout 120 --run --headless --script res://tools/orbitcheck.gd
                                           one Godot command, supervised like a check
  check.py --monitor                       a window showing every run in this clone"""


class Check(NamedTuple):
    name: str
    command: list
    markers: object  # None, or a regex (or tuple of them) that must each match exactly one line
    timeout: float
    cost: float = 0  # rough idle seconds, until a run has measured it
    alone: object = False  # True: nothing beside it; a string: only beside checks with the same string
    lane: str = ""  # checks sharing a lane run one at a time, beside the checks that have none
    cores: str = ""  # an argument stem ("threads="): the check takes every core unless told how many


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
        for paths, selectors in CHANGED_ALSO:
            if any(fnmatch.fnmatch(path, pattern) for pattern in paths):
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
    # macOS stops drawing a fully covered window, and a check awaiting a frame then stalls at
    # no CPU, so these float above other apps. The timing suites keep an ordinary window.
    window = base + ["--always-on-top"] if suite in ("rendered", "lifecycle") else base

    def script(name, marker, *args, timeout=180):
        return Check(name, base + ["--headless", "--script", f"res://tools/{name}.gd", "--", *args], marker, timeout)

    # Windowed: only for checks that judge a rendered frame, read a GPU result or must
    # see SHADER ERRORs (printed on first render). The dummy renderer has none of these.
    # One window at a time: beside other windowed checks Metal reports fence timeouts.
    # Saturated CPUs do not cause them, so headless checks run beside the window
    # (measurements in docs/performance.md).
    def scene(name, marker, *args, timeout=300):
        return Check(name, window + ["--resolution", "1280x720", f"res://tools/{name}.tscn", "--", *args], marker, timeout, lane="window")

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
        yield ("check-selfcheck", [sys.executable, str(ROOT / "tools/check_test.py")], r"^CHECK SELF-CHECK PASS$", 120)
        # About a second: AGENTS.md's physics rules that a pattern can state (tools/rulecheck.py --list).
        yield ("rulecheck", [sys.executable, str(ROOT / "tools/rulecheck.py")], r"^RULECHECK DONE rules=[1-9]\d* violations=0$", 60)
        yield script("skycheck", r"^SKYCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("voyagercheck", r"^VOYAGER DONE failures=0$", "title=0")
        yield script("cameracheck", r"^CAMERACHECK DONE checks=[1-9]\d* failures=0$")
        yield script("invariantcheck", r"^INVARIANTCHECK DONE checks=[1-9]\d* failures=0 native=(?:true|false)$")
        yield script("sciencecheck", r"^sciencecheck: [1-9]\d* checks, 0 failed$")
        yield script("savecheck", r"^SAVECHECK ([1-9]\d*)/\1 checks passed \(platform=(?:macOS|Linux|Windows); native \+ forced backup publication\)\.$")
        yield script("secularcheck", r"^SECULARCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("flighttimecheck", r"^FLIGHT TIME PASS \(0 failures\)$")
        # The LRV's physics against the Apollo record: sinkage, speed, slip, turning, breakout, dust.
        # Timeouts sized for CI's runners, about three times a desktop's wall time beside other checks.
        yield script("rovercheck", r"^ROVERCHECK DONE checks=[1-9]\d* failures=0$", timeout=900)
        # Rotors against momentum theory and the flown record; Ingenuity and Dragonfly flown over planes.
        yield script("rotorcheck", r"^ROTORCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        # The FFT sea against its spectrum and a direct sum; hulls against Archimedes and the Apollo record.
        yield script("oceancheck", r"^OCEANCHECK DONE checks=[1-9]\d* failures=0$", timeout=900)
        yield script("orbitcheck", r"^ORBITCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("soicheck", r"^SOICHECK DONE checks=[1-9]\d* failures=0$")
        yield script("missionguidancecheck", r"^MISSIONGUIDANCECHECK DONE checks=[1-9]\d* failures=0$")
        yield script("kerrcircularcheck", r"^KERRCIRCULARCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("kerrflightcheck", r"^KERRFLIGHTCHECK DONE checks=[1-9]\d* failures=0$")
        # ~100 s on an M5; CI's runners take about twice that.
        yield script("flightphysicscheck", r"^flightphysicscheck: PASS$", timeout=420)
        yield script("spinframecheck", r"^SPINFRAMECHECK DONE checks=[1-9]\d* failures=0$")
        yield script("observatorycheck", r"^OBSERVATORYCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("imagingcheck", r"^IMAGINGCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("observatorystagecheck", r"^OBSERVATORYSTAGECHECK DONE checks=[1-9]\d* failures=0$")
        yield script("cloudcheck", r"^CLOUDCHECK DONE checks=[1-9]\d* failures=0$")
        yield script("plasmacheck", r"^PLASMACHECK DONE checks=[1-9]\d* failures=0$")
        # ~30 s: a Gyr of 6000 tracers in MWPotential2014.
        yield script("galaxycheck", r"^GALAXYCHECK DONE checks=[1-9]\d* failures=0 native=(?:true|false)$", timeout=300)
        # Galaxy encounters: the orbits against van der Marel et al. (2012b).
        # ~50 s on an M5's ten cores, several times that on CI's two or three. Alone: its live
        # tree uses every core, and on CI that starved the checks beside it past their timeouts.
        yield script("encountercheck", r"^ENCOUNTERCHECK DONE checks=[1-9]\d* failures=0$", timeout=900)._replace(alone=True)
    elif suite == "encounters":
        # ~6 min on an M5's ten cores, past CI's limits on two or three: the canonical encounter
        # live for 10 Gyr against their N-body run. Kept out of "fast" (and so out of clean);
        # --changed selects it when the galaxy code changes.
        # With neighbours it is told how many cores they leave it: on all of them it took
        # half of each mission's (docs/performance.md).
        yield script("encounterlivecheck", r"^ENCOUNTERLIVECHECK DONE checks=[1-9]\d* failures=0$", timeout=1800)._replace(cores="threads=")
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
        yield headless_scene("scenariocheck", r"^SCENARIOCHECK DONE scenarios=3 failures=0$",
                             "only=evapod:pod_berth,ranger:spin_match,lander:axial_recovery", "replay=1", timeout=240)._replace(name="dockingscenarios", cost=60)
        yield headless_scene("dockingmissioncheck", r"^DOCKINGMISSIONS DONE missions=3 failures=0$", timeout=240)
        yield headless_scene("dockingmissioncheck", r"^DOCKINGMISSIONS DONE missions=3 failures=0$", "assets=0",
                             timeout=240)._replace(name="dockingmissioncheck-fallback")
        yield script("finiteburncheck", r"^FINITEBURNCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)._replace(cost=160)
        yield headless_scene("rangerflightcheck", r"^RANGERFLIGHT DONE failures=0$", timeout=900)
        yield headless_scene("discoveryflightcheck", r"^DISCOVERYFLIGHT DONE failures=0$", timeout=1800)
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
        # A landing on the Moon and on Mars stands on the ground that is drawn; Earth keeps its figure.
        yield headless_scene("groundcheck", r"^GROUNDCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)._replace(cost=40)
        # Apollo's command module comes down on the sea it draws, floats on it and is righted.
        yield headless_scene("seacheck", r"^SEACHECK DONE checks=[1-9]\d* failures=0$", timeout=900)._replace(cost=60)
        # Every developer scenario, jumped to and checked against its declared state.
        yield Check("scenariocheck", base + ["--headless", "res://tools/scenariocheck.tscn"],
                    r"^SCENARIOCHECK DONE scenarios=[1-9]\d* failures=0$", 900, cost=120)
    elif suite == "scenario-replay":
        # Each fast-forwarded or built scenario against the flight played at 60 fps.
        yield Check("scenario-replay", base + ["--headless", "res://tools/scenariocheck.tscn", "--", "replay=1"],
                    r"^SCENARIOCHECK DONE scenarios=[1-9]\d* failures=0$", 3600)
    elif suite == "rendered":
        # Windowed: lens and skycache read GPU results and pixels; glowcheck measures a
        # source's glow in the final frame, because bloom and the tone curve decide its
        # size; observatorylookcheck judges the Observatory's sky and flightlightcheck a vehicle's
        # light in the same frame; coursecheck
        # and the accretion checks collect the errors a drawn frame
        # raises (SHADER ERROR included); hudcheck screenshots and drives real input over
        # laid-out Controls; presetcheck attributes each scenario's render errors. The
        # rest judge state and run headless.
        yield scene("lenscheck", r"^LENSCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("skycachecheck", r"^SKYCACHECHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("glowcheck", r"^GLOWCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        yield scene("observatorylookcheck", r"^OBSERVATORYLOOKCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        # The galactic scene's glow against its CPU integral, and the star/glow hand-over's flux.
        yield scene("galaxylookcheck", r"^GALAXYLOOKCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        yield scene("flightlightcheck", r"^FLIGHTLIGHTCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        # Actual cockpit depth, lighting and production camera/arm controls require a GPU.
        yield scene("evapodflightshots", r"^EVAPODFLIGHT DONE failures=0$")
        yield scene("discoveryflightshots", r"^DISCOVERYFLIGHTSHOTS DONE failures=0$")
        yield scene("rangerflightshots", r"^RANGERFLIGHTSHOTS DONE failures=0$")
        # These runs inspect the visible docking attachment and the Kerr backdrop.
        yield scene("dockingflightshots", r"^DOCKINGFLIGHTSHOTS DONE checks=[1-9]\d* failures=0$")
        yield scene("kerrflightcheck", r"^KERRFLIGHTCHECK DONE checks=[1-9]\d* failures=0$", "render=1")._replace(name="kerrflightshots")
        yield scene("coursecheck", r"^COURSE 40L 125S 0E$")
        # The drawn ground at a landing against its CPU half: the Sun's march and the LM's shadow, in the frame.
        yield scene("groundlookcheck", r"^GROUNDLOOKCHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        # The GPU's FFT sea against the CPU's, texel for texel; it reads the RenderingDevice back.
        yield scene("oceanlookcheck", r"^OCEANLOOKCHECK DONE checks=[1-9]\d* failures=0$", timeout=300)
        pin_gpu = scene("pincheck", r"^PINCHECK DONE checks=[1-9]\d* failures=0$", "gpu=1")
        yield ("pincheck-gpu", *pin_gpu[1:])
        for quality in ("medium", "low", "high"):
            site = scene("surfacecheck", r"^SURFACECHECK DONE checks=[1-9]\d* failures=0$", "pixels=1", f"quality={quality}")
            yield (f"surfacepixelcheck-{quality}", *site[1:])
        for quality in ("medium", "low", "high"):
            pixels = scene("lookcheck", r"^LOOKCHECK DONE checks=[1-9]\d* failures=0$", "pixels=1", f"quality={quality}")
            yield (f"lookpixelcheck-{quality}", *pixels[1:])
        yield scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1")
        startup_low = scene("hudcheck", r"^HUDCHECK TEST [1-9]\d* passed, 0 failed$", "hstate=sandbox", "htest=1", "quality=low")
        yield ("hud-low-startup", *startup_low[1:])
        layout = scene("hudcheck", r"^HUDCHECK LAYOUT [1-9]\d* passed, 0 failed$", "hlayout=1", "assets=0", "padmodels=0")
        yield ("hud-layout", *layout[1:])
        yield headless_scene("sharedtimecheck", r"^SHARED TIME DONE checks=[1-9]\d* failures=0$", "assets=0")
        yield headless_scene("transitioncheck", r"^TRANSITIONCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("structureinputcheck", r"^STRUCTUREINPUTCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("editorcheck", r"^EDITORCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("compositioncheck", r"^COMPOSITIONCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("lookcheck", r"^LOOKCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("pincheck", r"^PINCHECK DONE checks=[1-9]\d* failures=0$")
        yield headless_scene("surfacecheck", r"^SURFACECHECK DONE checks=[1-9]\d* failures=0$", timeout=600)
        yield headless_scene("realismcheck", r"^REALISMCHECK DONE checks=[1-9]\d* failures=0$")
        yield scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$")
        accretion_gd = scene("accretioncheck", r"^ACCRETIONCHECK DONE checks=[1-9]\d* failures=0$", "native=0")
        yield ("accretion-gdscript", *accretion_gd[1:])
        yield Check("presetcheck", ["sh", str(ROOT / "tools/presetcheck.sh"), str(output / "presets-engine.log"), *window[len(base):]],
                    r"^PRESETCHECK DONE 38$", 300, lane="window")  # windowed, like scene()
    elif suite in ("assets", "procedural"):
        if suite == "assets":
            yield ("craft-parity", base + ["--headless", "res://tools/crafttest.tscn", "--", "parity"],
                   r"^PARITY DONE 28 poses, 0 failures$", 180)
        if suite == "assets":
            yield script("observatorycheck", (r"^OBSERVATORYCHECK authored library: [1-9]\d* stages$", r"^OBSERVATORYCHECK DONE checks=[1-9]\d* failures=0$"),
                         "assets=1")._replace(name="observatorycheck-assets")
        for assets in (("1", "0") if suite == "assets" else ("0",)):
            yield script("evapodcheck", r"^EVAPODCHECK DONE checks=[1-9]\d* failures=0$", f"assets={assets}")._replace(name=f"evapodcheck-{assets}")
            yield script("rangercheck", r"^RANGERCHECK DONE checks=[1-9]\d* failures=0$", f"assets={assets}")._replace(name=f"rangercheck-{assets}")
            yield script("discoverycheck", r"^DISCOVERYCHECK DONE checks=[1-9]\d* failures=0$", f"assets={assets}")._replace(name=f"discoverycheck-{assets}")
            yield script("endurancecheck", r"^ENDURANCECHECK DONE checks=[1-9]\d* failures=0$", f"assets={assets}")._replace(name=f"endurancecheck-{assets}")
            # The authored gate cannot pass by silently substituting optional fallback models.
            yield script("assetcheck", rf"^ASSETCHECK DONE [1-9]\d* checks, {'14' if assets == '1' else '0'} authored, 0 failures$", f"assets={assets}")
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
            return Check(name, window + ["--verbose", "--resolution", "1280x720", "--", "mode=sandbox", "preset=solar", "rounds=5",
                                       "settings=default", f"eval={method}", *args], marker, 900, cost=40, alone="lifecycle")
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
    elif suite == "mutation":
        # Plausible mistakes planted one at a time; the checks named for each must reject it.
        # core (the orrery's physics, rebuilding native/ for its twins) takes minutes; galaxy
        # about an hour and a half, most of it in galaxylookcheck's window.
        for group, timeout in (("core", 1800), ("galaxy", 10800)):
            yield (f"mutationcheck-{group}", [sys.executable, str(ROOT / "tools/mutationcheck.py"), "--godot", godot, "--only", group,
                                              "--log-dir", str(output / f"mutation-{group}")],
                   r"^MUTATIONCHECK DONE as-expected=(\d+)/\1 ", timeout)
    elif suite == "compatibility":
        # Known strict trajectory differences remain failures; no widened tolerances or expected-failure masking.
        yield script("sciencecheck", r"^sciencecheck: [1-9]\d* checks, 0 failed$", "compatibility=web")
        yield ("physcheck", ["sh", str(ROOT / "tools/physcheck.sh"), str(output / "physics-reference")], r"^PHYSCHECK COMPLETE:", 300)
    elif suite == "m5-budget":
        yield scene("perfcheck", r"^PERFCHECK DONE cases=18 failures=0$", "m5_native=1", f"report={output / 'm5-native.json'}")
    elif suite == "m5-medium":
        medium = scene("perfcheck", r"^PERFCHECK DONE cases=18 failures=0$", "m5_native=1", "m5_preset=medium", f"report={output / 'm5-medium.json'}")
        yield ("perfcheck-m5-medium", *medium[1:])
    elif suite == "perf":
        yield scene("perfcheck", r"^PERFCHECK DONE cases=18 failures=0$", f"report={output / 'render-profile.json'}")
        abba = scene("perfcheck", r"^PERFCHECK DONE cases=19 failures=0$", "studio_abba=1", f"report={output / 'studio-abba.json'}")
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
    left alone and never become the app to return to."""

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


class Interrupted(BaseException):
    """SIGTERM or SIGHUP, raised in the main thread so cleanup runs (an agent's tool
    timeout sends SIGTERM; children in their own sessions would otherwise outlive it)."""
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


class Stopped(Exception):
    """A running child stopped early; the message is the problem reported."""


def clock_seconds(text):
    """ps's TIME or ETIME, `[[dd-]hh:]mm:ss[.ss]`, in seconds."""
    days, _, clock = text.strip().rpartition("-")
    seconds = 0.0
    for part in clock.split(":"):
        seconds = seconds * 60 + float(part)
    return seconds + 86400 * int(days or 0)


def process_table():
    """{pid: (ppid, CPU seconds, elapsed seconds)}, or None where ps is unavailable."""
    if os.name != "posix":
        return None
    try:
        listed = subprocess.run(["ps", "-A", "-o", "pid=,ppid=,time=,etime="], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    table = {}
    for line in listed.stdout.splitlines():
        with contextlib.suppress(ValueError):
            pid, ppid, cpu, elapsed = line.split()
            table[int(pid)] = (int(ppid), clock_seconds(cpu), clock_seconds(elapsed))
    return table or None


def descendants(table, root):
    """`root` and every process below it, by parent pid: nested runners start their
    own sessions, so a process group alone misses them."""
    children = {}
    for pid, (ppid, *_rest) in table.items():
        children.setdefault(ppid, []).append(pid)
    found, stack = [], [root]
    while stack:
        pid = stack.pop()
        if pid in table and pid not in found:
            found.append(pid)
            stack.extend(children.get(pid, []))
    return found


class Processes:
    """One shared `ps` every few seconds for all running checks' stall tests."""
    EVERY = 5

    def __init__(self):
        self.lock = threading.Lock()
        self.at = -1e9
        self.table = None

    def tree(self, root):
        """(CPU seconds, pids) of `root`'s tree, or None when unknown."""
        with self.lock:
            if time.monotonic() - self.at >= self.EVERY:
                self.table, self.at = process_table(), time.monotonic()
            table = self.table
        if not table or root not in table:
            return None
        pids = descendants(table, root)
        return sum(table[pid][1] for pid in pids), frozenset(pids)


PROCESSES = Processes()


def exited(pid):
    """True once `pid` is gone or a zombie. Never reaps it: a worker may be waiting on it."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    with contextlib.suppress(OSError, subprocess.SubprocessError):
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout
        return not state.strip() or state.strip().startswith("Z")
    return False


def stop_tree(*pids, grace=None):
    """Stop each pid's process group and every descendant: SIGTERM, then SIGKILL after
    up to `grace` s (STOP_GRACE). The grace lets mutationcheck put back the file it broke."""
    if not pids:
        return
    grace = STOP_GRACE if grace is None else grace
    if os.name != "posix":
        for pid in pids:
            with contextlib.suppress(OSError, subprocess.SubprocessError):
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(pid)], capture_output=True, timeout=30)
        return
    # Listed first: a descendant whose parent exits is reparented and no longer found.
    table = process_table() or {}
    below = [other for pid in pids for other in descendants(table, pid)]
    if grace:
        for pid in pids:
            with contextlib.suppress(OSError):
                os.killpg(pid, signal.SIGTERM)
        end = time.monotonic() + grace
        while time.monotonic() < end and not all(exited(pid) for pid in pids):
            time.sleep(0.05)
    for pid in pids:
        with contextlib.suppress(OSError):
            os.killpg(pid, signal.SIGKILL)
    for other in below:
        with contextlib.suppress(OSError):
            os.kill(other, signal.SIGKILL)


class Watcher:
    """Stops a child that can no longer pass: one still running ERROR_QUIET s after
    its output stops (or `grace` s after) following an engine error, or one with no
    output, no new processes and under STALL_CPU of a core for `stall` s (0: never)."""

    def __init__(self, pid, paths, options):
        self.pid, self.paths = pid, paths
        self.grace = getattr(options, "error_grace", 60)
        self.stall = getattr(options, "stall", 0)
        self.allow_ca = options.allow_macos_ca_error
        self.offsets = {path: 0 for path in paths}
        self.heard = self.busy = time.monotonic()
        self.error_at = None
        self.sample = None  # (when, CPU seconds, pids) at the last sign of work

    def engine_error(self):
        """The full logs read the way run_child judges them."""
        for path in self.paths:
            with contextlib.suppress(OSError):
                text = path.read_text(errors="replace")
                if self.allow_ca:
                    text = CA_ERROR.sub("", CA_PENDING.sub("", text))
                if ENGINE_ERROR.search(text):
                    return True
        return False

    def __call__(self):
        now = time.monotonic()
        candidate = False
        for path in self.paths:
            with contextlib.suppress(OSError):
                with path.open("rb") as stream:
                    stream.seek(self.offsets[path])
                    new = stream.read()
                if new:
                    self.offsets[path] += len(new)
                    self.heard = now
                    candidate = candidate or ENGINE_ERROR.search(new.decode(errors="replace")) is not None
        if self.error_at is None and candidate and self.engine_error():
            self.error_at = now
        if self.error_at is not None and (now - self.heard >= ERROR_QUIET or now - self.error_at >= self.grace):
            return f"engine error; child still running {round(now - self.error_at)}s after it, stopped"
        if self.stall:
            tree = PROCESSES.tree(self.pid)
            if tree is not None:
                cpu, pids = tree
                if self.sample is None or pids != self.sample[2] or cpu - self.sample[1] > STALL_CPU * (now - self.sample[0]):
                    self.sample, self.busy = (now, cpu, pids), now
                if now - max(self.heard, self.busy) >= self.stall:
                    return f"stalled: no output and under {STALL_CPU:.0%} of a core for {round(now - max(self.heard, self.busy))}s"
        return None


def excerpt(text, errors=20, tail=8, width=300):
    """What to read first in a failed check's log: each error or FAIL line with the
    line after it (a GDScript backtrace's `at:`), then its last lines."""
    lines = text.splitlines()
    marked = [i for i, line in enumerate(lines) if FAILURE_LINE.search(line)]
    chosen = sorted({j for i in marked[:errors] for j in (i, i + 1) if j < len(lines)}
                    | set(range(max(len(lines) - tail, 0), len(lines))))
    shown, last = [], -1
    for i in chosen:
        if i > last + 1:
            shown.append(f"  | ... {i - last - 1} lines")
        shown.append("  | " + lines[i][:width])
        last = i
    if len(marked) > errors:
        shown.append(f"  | ({len(marked) - errors} more error/FAIL lines in the log)")
    return shown


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
        limit = options.timeout or timeout
        deadline = getattr(options, "deadline", None)
        budget = deadline is not None and deadline - time.monotonic() < limit
        if budget:
            limit = max(deadline - time.monotonic(), 0.1)
        watcher = Watcher(process.pid, [log, *([engine_log] if engine_log else [])], options)
        try:
            code, cpu = wait_child(process, limit, watcher)
            problem = None if code == 0 else f"child exited {code}"
        except (subprocess.TimeoutExpired, Stopped) as stop:
            stop_tree(process.pid)
            process.wait()
            code = 124
            problem = str(stop) if isinstance(stop, Stopped) else "budget: stopped when --budget ran out" if budget else "timeout"
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
    if problem and getattr(options, "excerpt", True):
        lines.extend(excerpt(text) if text.strip() else excerpt(engine_text))
    return {"name": name, "command": command, "exit_code": code, "problem": problem,
            "seconds": elapsed, "cpu_seconds": cpu, "log": str(log), "engine_log": str(engine_log) if engine_log else None,
            "allowed_ca_diagnostics": ignored, "focus_restored": restored,
            "renderer": next((line for line in raw.splitlines() if re.match(r"^(?:Metal|Vulkan|OpenGL).*Using Device", line)), None),
            "metrics": [line for line in raw.splitlines() if line.startswith(("SHARED TIME BENCH", "SHARED TIME CONFIG", "HUDCHECK PERF", "HUDCHECK CONFIG", "NBODYCHECK PASS", "STABILITYCHECK", "STABILITYDIAGNOSTIC"))]}, lines


def wait_child(process, timeout, watch=None):
    """Wait for `process`; returns (exit code, CPU seconds of it and the children it
    reaped, or None where wait4 is unavailable). Raises TimeoutExpired, or Stopped
    when `watch()`, called about once a second, names a problem."""
    deadline = time.monotonic() + timeout
    watched = time.monotonic()
    while True:
        if hasattr(os, "wait4"):
            pid, status, usage = os.wait4(process.pid, os.WNOHANG)
            if pid:
                process.returncode = os.waitstatus_to_exitcode(status)
                return process.returncode, round(usage.ru_utime + usage.ru_stime, 3)
        elif process.poll() is not None:
            return process.returncode, None
        now = time.monotonic()
        if now > deadline:
            raise subprocess.TimeoutExpired(process.args, timeout)
        if watch is not None and now - watched >= 1:
            watched = now
            reason = watch()
            if reason:
                raise Stopped(reason)
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


QUICK = 10  # seconds: a check this short starts first, so a broken precondition fails at once
PASS_KEEP = 6  # earlier passes remembered per check: worktrees of one clone share them
PASS_DAYS = 30


def launch_order(segment, expected, jobs):
    """Quick checks first, shortest first, so a cheap failure stops the run before the
    long ones are paid for; then the unmeasured; then the rest, longest first where
    they share the jobs."""
    quick = sorted((i for i in segment if expected[i] is not None and expected[i] <= QUICK), key=lambda i: expected[i])
    unmeasured = [i for i in segment if expected[i] is None]
    rest = [i for i in segment if expected[i] is not None and expected[i] > QUICK]
    if jobs > 1:
        rest.sort(key=lambda i: -expected[i])
    return quick + unmeasured + rest


def worktree_tree():
    """The working tree as a git tree object: tracked, staged, unstaged and untracked
    files, written through a scratch index so the real one is untouched. None when git
    cannot say."""
    try:
        index = subprocess.run(["git", "rev-parse", "--git-path", "index"], cwd=ROOT, capture_output=True, text=True,
                               check=True, timeout=15).stdout.strip()
        with tempfile.TemporaryDirectory(prefix="astrarium-index-") as folder:
            scratch = Path(folder) / "index"
            if (ROOT / index).is_file():
                shutil.copyfile(ROOT / index, scratch)
            env = {**os.environ, "GIT_INDEX_FILE": str(scratch)}
            subprocess.run(["git", "add", "-A"], cwd=ROOT, env=env, capture_output=True, check=True, timeout=120)
            return subprocess.run(["git", "write-tree"], cwd=ROOT, env=env, capture_output=True, text=True,
                                  check=True, timeout=60).stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def git_paths(*args):
    listed = subprocess.run(["git", "ls-files", "-z", *args], cwd=ROOT, capture_output=True, check=True, timeout=30)
    return {Path(os.fsdecode(path)) for path in listed.stdout.split(b"\0") if path}


def ignored_inputs():
    return {path for path in git_paths("--others", "--ignored", "--exclude-standard", "--", "assets", "native")
            if path.suffix != ".import"}


def surroundings(godot, ignored):
    """What a pass depends on outside the tree: the engine, the platform and the files
    git ignores that a check loads (authored models, a locally built kernel). Their
    .import files follow from them and carry per-checkout ids."""
    version = subprocess.run([godot, "--version"], cwd=ROOT, capture_output=True, check=True, timeout=15).stdout.strip()
    digest = hashlib.sha256(version + json.dumps([platform.system(), platform.machine()]).encode())
    for path in sorted(ignored):
        digest.update(os.fsencode(path) + b"\0")
        digest.update(hashlib.sha256((ROOT / path).read_bytes()).digest())
    return digest.hexdigest()[:16]


def input_stamps(godot, ignored):
    """POSIX change times catch in-place rewrites even when bytes and mtime are
    restored. Directory stamps also catch temporary entries and rename cycles."""
    paths = {Path(godot), Path(godot).parent, ROOT}
    for path in git_paths("--cached", "--others", "--exclude-standard") | ignored:
        paths.add(ROOT / path)
        paths.update(ROOT / parent for parent in path.parents)
    stamps = {}
    for path in paths:
        try:
            info = path.lstat()
        except FileNotFoundError:
            stamps[path] = None  # a tracked path may be deleted in the worktree
            continue
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            return None  # a symlink can introduce inputs outside the monitored paths
        stamps[path] = (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    return stamps


class PassInputs(NamedTuple):
    tree: str
    around: str
    stamps: dict


def pass_inputs(godot):
    # Windows stat reports creation time rather than POSIX change time.
    if os.name != "posix":
        return None
    try:
        ignored = ignored_inputs()
        stamps = input_stamps(godot, ignored)
        if stamps is not None and (tree := worktree_tree()):
            around = surroundings(godot, ignored)
            if stamps == input_stamps(godot, ignored_inputs()):
                return PassInputs(tree, around, stamps)
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def pass_key(check, output, godot, around, allow_macos_ca_error):
    """Names a check as run: its command with this run's own paths taken out, its
    markers, error policy and surroundings."""
    def plain(part):
        part = str(part).replace(str(output), "<out>").replace(str(ROOT), "<root>")
        return "<godot>" if part == godot else "<python>" if part == sys.executable else part
    stated = json.dumps([[plain(part) for part in check.command], check.markers, around, allow_macos_ca_error], default=str)
    return f"{check.name}#{hashlib.sha256(stated.encode()).hexdigest()[:16]}"


def read_passes(folder):
    """{pass key: [{tree, utc}, newest first]}, or {} when missing or malformed."""
    try:
        passes = json.loads((folder / "passes.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return passes if isinstance(passes, dict) else {}


def record_passes(folder, tree, keys):
    """Remember that the checks named by `keys` passed on `tree`."""
    now = datetime.datetime.now(datetime.timezone.utc)
    oldest = (now - datetime.timedelta(days=PASS_DAYS)).isoformat()
    with contextlib.suppress(OSError):
        folder.mkdir(parents=True, exist_ok=True)
        passes = read_passes(folder)
        for key in keys:
            earlier = [r for r in passes.get(key, []) if isinstance(r, dict) and r.get("tree") != tree]
            passes[key] = [{"tree": tree, "utc": now.isoformat()}, *earlier][:PASS_KEEP]
        passes = {key: kept for key, records in passes.items()
                  if (kept := [r for r in records if isinstance(r, dict) and str(r.get("utc", "")) >= oldest])}
        temporary = folder / f"passes.{os.getpid()}.tmp"
        temporary.write_text(json.dumps(passes, indent=1, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(folder / "passes.json")


def tree_changes(earlier, tree):
    """Paths that differ between two trees, or None when git cannot compare them (an
    unreferenced tree is pruned in time)."""
    listed = subprocess.run(["git", "diff", "--name-only", "--no-renames", earlier, tree],
                            cwd=ROOT, capture_output=True, text=True, timeout=60)
    if listed.returncode != 0:
        return None
    return sorted({path.removesuffix(".uid") for path in listed.stdout.splitlines() if path})


def passed_unchanged(plan, keys, dev, passes, tree, changes=tree_changes):
    """{plan index: record} for each check that passed on an earlier tree from which
    nothing CHANGED_RULES maps to it has changed. --changed trusts those rules to choose
    the checks; this trusts them the same way, from the check's last pass instead of
    from a branch point. Never the import: it prepares this checkout's own cache."""
    selected = {}

    def touched(earlier):
        if earlier not in selected:
            files = changes(earlier, tree)
            selected[earlier] = None if files is None else {check.name for check in changed_plan(plan, files, dev)[0]}
        return selected[earlier]

    hits = {}
    for index, check in enumerate(plan):
        if check.name == "import":
            continue
        for record in passes.get(keys[index], []):
            if not isinstance(record, dict) or not isinstance(record.get("tree"), str):
                continue
            names = touched(record["tree"])
            if names is not None and check.name not in names:
                hits[index] = record
                break
    return hits


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
        self.live, self.began = {}, {}  # live: run_plan's {index: Popen}, for reaping after a killed runner
        self.budget_stops = {}  # index: True for a check --budget stopped
        self.branch = metadata(["git", "rev-parse", "--abbrev-ref", "HEAD"])
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
        self.began[index] = time.time()

    @staticmethod
    def last_line(log):
        """The log's last non-empty line: what a running check is doing now."""
        with contextlib.suppress(OSError), log.open("rb") as stream:
            stream.seek(max(stream.seek(0, os.SEEK_END) - 4096, 0))
            lines = [line.strip() for line in stream.read().decode(errors="replace").splitlines() if line.strip()]
            return lines[-1][:160] if lines else ""
        return ""

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
            log = self.output / f"{index:02d}-{self.plan[index].name}.log"
            process = self.live.get(index)
            running.append({"name": self.plan[index].name, "log": str(log), "seconds": round(elapsed), "expected": expected and round(expected),
                            "timeout": timeout, "quiet": round(quiet), "flag": flag, "last": self.last_line(log),
                            "pid": process.pid if process else None, "began": self.began.get(index)})
        waiting = [i for i in range(len(self.plan)) if i not in self.done and i not in self.running]
        # Parallel work shares the jobs; a lane's checks queue behind each other; alone
        # checks run end to end.
        left = [max((self.expected[i] or 0) - (now - began), 0) for i, began in self.running.items()]
        shared = sum(left) + sum(self.expected[i] or 0 for i in waiting if self.plan[i].alone is not True)
        alone = sum(self.expected[i] or 0 for i in waiting if self.plan[i].alone is True)
        lane = (sum(max((self.expected[i] or 0) - (now - began), 0) for i, began in self.running.items() if self.plan[i].lane)
                + sum(self.expected[i] or 0 for i in waiting if self.plan[i].lane and self.plan[i].alone is not True))
        unknown = sum(1 for i in [*self.running, *waiting] if not self.expected[i])
        return {"pid": os.getpid(), "root": str(ROOT), "branch": self.branch, "args": self.argv, "log_dir": str(self.output),
                "started_utc": self.started_utc, "updated": time.time(), "elapsed": round(now - self.started),
                "total": len(self.plan), "passed": sum(self.done.values()), "failed": [self.plan[i].name for i, ok in self.done.items() if not ok],
                "stopping": self.stopping, "stopping_failure": any(not ok and not self.budget_stops.get(i) for i, ok in self.done.items()),
                "running": running, "waiting": [self.plan[i].name for i in waiting],
                "eta": None if self.stopping else round(max([*left, 0]) if not waiting and not running else max(max(left, default=0), shared / self.jobs, lane) + alone),
                "eta_unknown": unknown, "finished": None}

    @staticmethod
    def render(state, width=None, detail=False):
        """One summary line plus a line per running check (and its last log line, with `detail`)."""
        done = state["passed"] + len(state["failed"])
        head = f"[{done}/{state['total']}] {len(state['running'])} running, {len(state['waiting'])} waiting, {duration(state['elapsed'])} elapsed"
        if detail:
            filled = round(20 * done / max(state["total"], 1))
            head = f"[{'#' * filled}{'.' * (20 - filled)}] " + head
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
            if detail and check.get("last"):
                lines.append(f"      > {check['last']}")
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

    def close(self, complete, budget=False):
        self.clear()
        state = self.snapshot()
        state["finished"] = ("passed" if complete else "budget" if budget and not state["stopping_failure"]
                             else "failed" if state["failed"] else "interrupted")
        self.write(state)
        with contextlib.suppress(OSError, ValueError):
            path = self.dir / "last.json"
            last = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
            last[str(ROOT)] = {key: state[key] for key in ("finished", "failed", "updated", "args", "log_dir", "branch")}
            temporary = path.with_suffix(f".{os.getpid()}.tmp")
            temporary.write_text(json.dumps(last, indent=1, sort_keys=True) + "\n", encoding="utf-8")
            temporary.replace(path)
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


def run_states(folder):
    """[(path, state, alive)] for each run status file; a file from another version or
    a partial write skips only that run."""
    states = []
    for path in sorted(folder.glob("*.json")) if folder.is_dir() else []:
        if path.name in ("times.json", "passes.json", "last.json"):
            continue
        with contextlib.suppress(OSError, ValueError, KeyError, TypeError):
            state = json.loads(path.read_text(encoding="utf-8"))
            # Nothing else prunes runs nobody watched; last.json keeps each worktree's newest.
            if state.get("finished") and time.time() - state.get("updated", 0) > 86400:
                path.unlink(missing_ok=True)
                continue
            if isinstance(state, dict) and isinstance(state.get("pid"), int):
                states.append((path, state, process_alive(state["pid"])))
    return states


def reap_orphans(folder):
    """Stop the checks a runner left when it died unfinished (SIGKILL, a crash): nothing
    else would time them out. A pid counts as the check only while its elapsed time
    still matches the recorded start. Returns lines to print."""
    lines, table = [], None
    for path, state, alive in run_states(folder):
        if state.get("finished") or alive:
            continue
        stopped = []
        for entry in state.get("running") or []:
            pid, began = entry.get("pid"), entry.get("began")
            if not isinstance(pid, int) or not isinstance(began, (int, float)):
                continue
            table = table if table is not None else (process_table() or {})
            if pid in table and abs(time.time() - table[pid][2] - began) <= 5:
                stop_tree(pid)
                stopped.append(entry.get("name", str(pid)))
        state.update(finished="abandoned", reaped=stopped, updated=time.time())
        with contextlib.suppress(OSError):
            temporary = path.with_suffix(".reap.tmp")
            temporary.write_text(json.dumps(state), encoding="utf-8")
            temporary.replace(path)
        if stopped:
            lines.append(f"REAPED {', '.join(stopped)}: left running by runner pid {state['pid']} in {state.get('root')}, which died")
    return lines


COLOUR = {"PASS": "\x1b[32m", "FAIL": "\x1b[31m", "WARN": "\x1b[33m", "DIM": "\x1b[2m", "END": "\x1b[0m"}


def watch(once, as_json=False):
    """Print the runs in progress in every worktree of this clone, redrawn each second.
    Finished runs stay listed for ten minutes; a runner that vanished is shown as such."""
    folder = runs_dir()
    colour = sys.stdout.isatty() and not once
    paint = (lambda kind, text: COLOUR[kind] + text + COLOUR["END"]) if colour else (lambda kind, text: text)
    if colour:
        sys.stdout.write("\x1b[?1049h\x1b[?25l")  # the alternate screen, cursor hidden: no flicker or scrollback
    try:
        while True:
            reaped = reap_orphans(folder)
            blocks, listed = [], []
            for path, state, alive in run_states(folder):
                with contextlib.suppress(KeyError, TypeError, AttributeError, ValueError):
                    age = time.time() - state["updated"]
                    if (state["finished"] or not alive) and age > 600:
                        path.unlink(missing_ok=True)
                        continue
                    listed.append({**state, "alive": alive, "age": round(age)})
                    where = state["root"].replace(str(Path.home()), "~")
                    branch = state.get("branch")
                    title = f"{branch + ' ' if branch and branch != 'unavailable' else ''}({where}) pid {state['pid']}: check.py {' '.join(state['args'])}".rstrip()
                    kind = None
                    if state["finished"]:
                        kind = "PASS" if state["finished"] == "passed" else "FAIL"
                        title += f"  [{state['finished']} {duration(age)} ago]"
                    elif not alive:
                        kind, title = "FAIL", title + "  [runner exited without finishing]"
                    elif age > 10:
                        kind, title = "WARN", title + f"  [no update for {duration(age)}; runner busy or stuck]"
                    body = []
                    for line in Progress.render(state, detail=not state["finished"]):
                        body.append("  " + (paint("WARN", line) if "<-" in line else paint("DIM", line) if line.lstrip().startswith(">") else line))
                    blocks.append([paint(kind, title) if kind else title, *body, f"  logs {state['log_dir']}"])
            if as_json:
                print(json.dumps(listed, indent=1))
                return 0
            text = "\n\n".join("\n".join(block) for block in [*([reaped] if reaped else []), *blocks]) or "no check runs in progress"
            if once:
                print(text)
                return 0
            stamp = time.strftime("%H:%M:%S")
            sys.stdout.write("\x1b[H\x1b[2J" + text + f"\n\n{stamp}  (Ctrl-C to stop watching; the runs continue)\n")
            sys.stdout.flush()
            time.sleep(1)
    except KeyboardInterrupt:
        return 0
    finally:
        if colour:
            sys.stdout.write("\x1b[?25h\x1b[?1049l")
            sys.stdout.flush()


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
    print(f"TOTAL wall {report['wall_seconds']}s, check cpu {round(cpu, 1)}s, {len(report['results'])} checks"
          + (f", {len(report['cached'])} not rerun" if report.get("cached") else ""), flush=True)


def run_plan(plan, output, options, guard, report, keys=None):
    """Run checks up to options.jobs at a time. A check marked alone waits for the
    running ones and runs by itself; checks in one lane take turns beside the rest.
    After a failure nothing new starts (unless options.keep_going); running checks
    finish. Results print and enter the report in plan order, each with its pass key."""
    done = queue.Queue()
    progress = Progress(plan, output, options)
    complete = False
    live = progress.live
    finished = {}
    deadline = getattr(options, "deadline", None)
    started = set()
    stopped = False
    failed = False
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
                result["key"] = keys[printed] if keys else None
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
            waiting, running, lanes = launch_order(segment, progress.expected, options.jobs), 0, set()
            # A lane's check waits on the GPU more than it computes (the windowed ones
            # averaged 0.6 of a core), so beside other jobs it takes none of their places.
            extra = options.jobs > 1
            while waiting or running:
                if deadline is not None and time.monotonic() >= deadline and not stopped:
                    stopped = progress.stopping = True
                    report["budget_reached"] = True
                while not stopped:
                    # A free lane first: its checks cannot overlap, so they set the pace.
                    room = running - (len(lanes) if extra else 0) < options.jobs
                    index = next((i for i in waiting if plan[i].lane and plan[i].lane not in lanes), None) if extra or room else None
                    if index is None and room:
                        index = next((i for i in waiting if not plan[i].lane), None)
                    if index is None:
                        break
                    waiting.remove(index)
                    if plan[index].lane:
                        lanes.add(plan[index].lane)
                    progress.say(f"RUN {plan[index].name}")
                    progress.start(index)
                    started.add(index)
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
                lanes.discard(plan[index].lane)
                progress.finish(index, outcome[0]["problem"] is None, outcome[0]["seconds"])
                progress.budget_stops[index] = str(outcome[0]["problem"]).startswith("budget:")
                failed = failed or outcome[0]["problem"] is not None
                stopped = stopped or (failed and not getattr(options, "keep_going", False))
                progress.stopping = stopped
                flush()
            if stopped:
                break
        complete = not failed and not report.get("budget_reached")
        return complete
    finally:
        stop_tree(*[process.pid for process in list(live.values()) if process.returncode is None])
        flush(final=True)
        for index in sorted(started - set(progress.done)):  # the run itself was stopped (a signal)
            report["results"].append({"name": plan[index].name, "problem": "interrupted: the run was stopped first",
                                      "seconds": round(time.monotonic() - progress.running.get(index, time.monotonic()), 3),
                                      "log": str(output / f"{index:02d}-{plan[index].name}.log"), "key": None})
        report["not_run"] = [plan[i].name for i in range(len(plan)) if i not in started]
        budget = bool(report.get("budget_reached") or any(progress.budget_stops.values()))
        if budget:
            report["budget_reached"] = True
            progress.say(f"BUDGET ran out; {len(report['not_run'])} checks not run" + (f": {', '.join(report['not_run'])}" if report["not_run"] else ""))
        progress.close(complete, budget=budget)


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


CHANGED_SUITES = ["assets", "procedural", "dev", "fast", "encounters", "native", "flight", "rendered", "lifecycle"]


def run_command(args, godot, expect, timeout):
    """--run: one Godot command as a check named after the script or scene it runs.
    A leading Godot executable is taken as --godot; --path is added unless given."""
    if args and not args[0].startswith("-") and not args[0].startswith("res://") and Path(args[0]).is_file():
        godot, args = godot_path(args[0]), args[1:]
    script = next((part for part in args if re.match(r"res://.+\.(?:gd|tscn)$", part)), None)
    name = "run-" + (Path(script).stem if script else "godot")
    return Check(name, [godot, *([] if "--path" in args else ["--path", str(ROOT)]), *args], expect, timeout), godot


def show_output(path, head=20, tail=100, errors=20):
    """--run: the child's output, its middle left out past head + tail lines (the error
    lines in it are kept)."""
    lines = Path(path).read_text(errors="replace").splitlines()
    print(f"OUTPUT {len(lines)} lines, {path}", flush=True)
    if len(lines) <= head + tail + errors:
        shown = lines
    else:
        middle = [line for line in lines[head:-tail] if FAILURE_LINE.search(line)]
        shown = [*lines[:head], f"... {len(lines) - head - tail} lines left out ({len(middle)} error/FAIL lines among them"
                 + (f", the first {errors} follow" if len(middle) > errors else "") + ")", *middle[:errors], "...", *lines[-tail:]]
    for line in shown:
        print(line[:500], flush=True)
    print("END OUTPUT", flush=True)


def failure_status(report):
    """3 when every problem is a --budget stop (an incomplete run), else 1."""
    problems = [result["problem"] for result in report["results"] if result["problem"]]
    return 3 if all(problem.startswith("budget:") for problem in problems) else 1


def open_monitor():
    """A window of its own running --watch. On macOS a .command file opens in Terminal
    without asking for automation access."""
    if platform.system() == "Darwin":
        return subprocess.run(["open", "-a", "Terminal", str(ROOT / "tools/monitor.command")], timeout=30).returncode
    print("--monitor opens a window on macOS only; watching here instead", flush=True)
    return watch(False)


def interrupted(signum, frame):
    raise Interrupted(signum)


def main():
    argv = sys.argv[1:]
    run_args = None
    if "--run" in argv:  # everything after it is Godot's, its own `--` included
        at = argv.index("--run")
        argv, run_args = argv[:at], argv[at + 1:]
        run_args = run_args[1:] if run_args[:1] == ["--"] else run_args
    parser = argparse.ArgumentParser(description=__doc__, epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("suites", nargs="*", metavar="SUITE", help=", ".join(SUITES) + " (default: fast)")
    parser.add_argument("--godot", default=os.environ.get("GODOT"))
    parser.add_argument("--log-dir", type=Path)
    parser.add_argument("--timeout", type=float, help=f"override each child timeout in seconds (--run: default {RUN_TIMEOUT})")
    parser.add_argument("--budget", type=float, metavar="SECONDS",
                        help="the whole run's limit: when it runs out, running checks are stopped, the rest are not started "
                             "and the report is still written (exit 3 unless a check failed). Set it under the caller's own limit")
    parser.add_argument("--only", action="append", metavar="CHECKS",
                        help="only these checks: comma-separated names or globs, from the named suites or else every suite "
                             "--changed can select (the import still runs first)")
    parser.add_argument("--stall", type=float, default=90, metavar="SECONDS",
                        help="stop a check with no output, no new processes and under 3%% of a core for SECONDS (default 90; 0: never)")
    parser.add_argument("--error-grace", type=float, default=60, metavar="SECONDS",
                        help=f"stop a check still running SECONDS after an engine error, or {ERROR_QUIET} s after its output stops "
                             "(default 60); the error has failed it already")
    parser.add_argument("--run", nargs="*", metavar="GODOT_ARG",
                        help="run one Godot command supervised like a check (log, timeout, stall and error stops, report) and print "
                             "its output; must come last, everything after it goes to Godot")
    parser.add_argument("--expect", metavar="REGEX", help="with --run: a line that must appear exactly once")
    parser.add_argument("--allow-macos-ca-error", action="store_true", help="allow only Godot's get_system_ca_certificates diagnostic")
    parser.add_argument("--background", action="store_true",
                        help="macOS: hand focus back whenever a windowed check activates (not for the fullscreen M5 gates)")
    parser.add_argument("--jobs", type=int, default=default_jobs(),
                        help="checks run at once (default: performance cores); timing suites always run alone")
    parser.add_argument("--repeat", type=int, default=3, help="performance repetitions (default 3)")
    parser.add_argument("--changed", nargs="?", const="HEAD", metavar="REF",
                        help="run only the checks covering files changed since REF's merge base (default HEAD: "
                             "uncommitted work), from the selected suites or else every suite a change can select; "
                             "a check that already passed on inputs its rules call unchanged is not run again")
    parser.add_argument("--fresh", action="store_true", help="with --changed: run every selected check, whatever passed before")
    parser.add_argument("--keep-going", action="store_true", help="after a failure, still run the remaining checks")
    parser.add_argument("--list", action="store_true", help="print the planned checks with their timeouts and usual times, and exit")
    parser.add_argument("--watch", action="store_true",
                        help="show the check runs in progress in any worktree of this clone (e.g. an agent's), live")
    parser.add_argument("--status", action="store_true", help="print the --watch view once and exit")
    parser.add_argument("--json", action="store_true", help="with --status: the runs as JSON")
    parser.add_argument("--monitor", action="store_true", help="open a separate window (Terminal on macOS) running --watch")
    parser.add_argument("--compare", type=Path, metavar="REPORT", help="show each check's time against an earlier report.json")
    parser.add_argument("--export-preset", default={"Darwin": "macOS", "Linux": "Linux", "Windows": "Windows"}.get(platform.system(), "macOS"))
    options = parser.parse_args(argv)
    options.run = run_args
    if options.monitor:
        return open_monitor()
    if options.watch or options.status:
        return watch(once=options.status, as_json=options.json)
    if options.run is not None and (not options.run or options.suites or options.changed or options.only or options.list):
        parser.error("--run needs Godot arguments, and takes no suites, --changed, --only or --list")
    if options.expect and options.run is None:
        parser.error("--expect goes with --run")
    # The asset suites come first: they take seconds, and fail when a worktree has no authored models.
    options.suites = options.suites or (CHANGED_SUITES if options.changed or options.only else ["fast"])
    if any(suite not in SUITES for suite in options.suites):
        parser.error("unknown suite; choose from " + ", ".join(SUITES))
    if options.repeat < 1 or options.jobs < 1 or any(value is not None and value <= 0 for value in (options.timeout, options.budget)):
        parser.error("repeat, jobs, timeout and budget must be positive")
    if options.stall < 0 or options.error_grace < 0:
        parser.error("stall and error grace must not be negative")
    if options.background and (platform.system() != "Darwin" or any(s.startswith("m5-") for s in options.suites)):
        parser.error("--background is macOS-only; the M5 gates need their fullscreen Space visible")
    for name in ("SIGTERM", "SIGHUP"):
        if hasattr(signal, name):
            signal.signal(getattr(signal, name), interrupted)
    for line in reap_orphans(runs_dir()):
        print(line, flush=True)
    options.godot = godot_path(options.godot)
    output = options.log_dir.resolve() if options.log_dir else Path(tempfile.mkdtemp(prefix="astrarium-check-"))
    output.mkdir(parents=True, exist_ok=True)
    report = {"started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "platform": platform.platform(), "machine": platform.machine(), "processor": platform.processor(),
              "godot": metadata([options.godot, "--version"]), "commit": metadata(["git", "rev-parse", "HEAD"]),
              "working_tree": metadata(["git", "status", "--short"]), "suites": [] if options.run else options.suites,
              "background": options.background, "jobs": options.jobs, "keep_going": options.keep_going,
              "performance": ({"resolution": "1280x720", "rendered_craft": "authored Saturn V/Falcon 9 (required)",
                               "cpu_flight_craft": "procedural (asserted by each harness)",
                               "studio_abba": "frozen stage; two ABBA cycles per distance; distinct model viewport timestamp batches",
                               "shared_time": "fixed 1/60s steps; CPU animate timing; native=0 and required native=1",
                               "hud": "fixed 1/60s frames; wall time across rendered frames; vsync disabled",
                               "repetitions": options.repeat, "limitations": "local baseline; GPU availability recorded separately, no portable budget gate"}
                              if "perf" in options.suites and not options.run else None),
              "complete": False, "tree": None, "cached": [], "results": []}
    status = None
    if options.run is not None:
        command, options.godot = run_command(options.run, options.godot, options.expect, options.timeout or RUN_TIMEOUT)
        plan, inputs, keys = [command], None, []
        options.excerpt = False  # the output itself is printed
        report["run"] = command.command
    else:
        plan, inputs, keys, status = plan_checks(parser, options, output, report)
    if options.list:
        history, seen = read_times(runs_dir()), {}
        for check in plan:
            seen[check.name] = seen.get(check.name, -1) + 1
            usual = history.get(f"{check.name}#{seen[check.name]}") or check.cost
            print(f"{check.name}{'' if not check.alone else ' (alone)' if check.alone is True else f' ({check.alone})'}"
                  f"{f' (one {check.lane} at a time)' if check.lane and check.alone is not True else ''}"
                  f"{' headless' if '--headless' in check.command else ' windowed' if check.command[0] == options.godot else ''}"
                  f"  timeout {duration(options.timeout or check.timeout)}" + (f", usually {duration(usual)}" if usual else ""))
        return 0
    started = time.monotonic()
    options.deadline = started + options.budget if options.budget else None
    try:
        if status is not None:
            if status:
                # Nothing ran, so nothing is verified: not a pass, even for a docs-only change.
                print("CHANGED no checks selected; name a suite to run one", flush=True)
            return status
        with FocusGuard() if options.background else contextlib.nullcontext() as guard:
            passed = run_plan(plan, output, options, guard, report, keys)
        if options.run is not None and report["results"]:
            show_output(report["results"][0]["log"])
        if not passed:
            return failure_status(report)
        report["complete"] = True
        return 0
    finally:
        report["wall_seconds"] = round(time.monotonic() - started, 1)
        passed = [result["key"] for result in report["results"] if result["problem"] is None and result.get("key")]
        if inputs and passed:
            if pass_inputs(options.godot) == inputs:
                record_passes(runs_dir(), inputs.tree, passed)
            else:
                print("CACHE pass records skipped because check inputs changed or could not be read", flush=True)
        path = output / "report.json"
        path.write_text(json.dumps(report, indent=2) + "\n")
        print_times(report, options.compare)
        print(f"REPORT {path}", flush=True)


def plan_checks(parser, options, output, report):
    """The checks the suites, --only and --changed select, minus passes --changed may
    reuse. Returns (plan, pass inputs, pass keys, exit status or None): a status when
    --changed leaves nothing to run."""
    plan = [check._replace(alone=check.alone or suite in ALONE)
            for suite in options.suites
            for check in map(lambda c: Check(*c), checks(suite, options.godot, output, options.repeat, options.export_preset))]
    # Suites share checks (dev runs fast's); each runs once.
    seen = set()
    plan = [check for check in plan if (check.name, tuple(map(str, check.command))) not in seen
            and not seen.add((check.name, tuple(map(str, check.command))))]
    # Everything reads the import cache, whichever suite was named first.
    plan.sort(key=lambda check: check.name != "import")
    if options.only:
        patterns = [part.strip() for given in options.only for part in given.split(",") if part.strip()]
        names = sorted({check.name for check in plan})
        unknown = [pattern for pattern in patterns if not any(fnmatch.fnmatch(name, pattern) for name in names)]
        if unknown:
            close = sorted({match for pattern in unknown for match in difflib.get_close_matches(pattern, names, n=3, cutoff=0.6)})
            parser.error(f"--only: no check named {', '.join(unknown)} in {' '.join(options.suites)}"
                         + (f"; close: {', '.join(close)}" if close else "; --list prints the names"))
        chosen = [check for check in plan if any(fnmatch.fnmatch(check.name, p) for p in patterns)]
        engine = any(check.command[0] == options.godot for check in chosen)
        plan = [check for check in plan if check in chosen or (check.name == "import" and engine)]
    selected = len(plan)
    dev = []
    if options.changed:
        files = changed_files(options.changed)
        dev = [Check(*c) for c in checks("dev", options.godot, output, options.repeat, options.export_preset)]
        plan, unmapped = changed_plan(plan, files, dev)
        selected = len(plan)
        report["changed"] = {"ref": options.changed, "files": files, "unmapped": unmapped}
        print(f"CHANGED {len(files)} files since {options.changed}; {len(plan)} checks"
              + (f"; unmapped (dev suite): {', '.join(unmapped)}" if unmapped else ""), flush=True)
    inputs = pass_inputs(options.godot) if plan else None
    keys = []
    if inputs:
        report["tree"] = inputs.tree
        keys = [pass_key(check, output, options.godot, inputs.around, options.allow_macos_ca_error) for check in plan]
    if options.changed and inputs and not options.fresh:
        hits = passed_unchanged(plan, keys, dev, read_passes(runs_dir()), inputs.tree)
        # The import alone verifies nothing: it runs for the checks that read its cache.
        if hits and all(index in hits or check.name == "import" for index, check in enumerate(plan)):
            hits.update({index: None for index, check in enumerate(plan) if check.name == "import"})
        report["cached"] = [{"name": plan[index].name, "key": keys[index], "tree": record["tree"], "passed_utc": record.get("utc")}
                            for index, record in sorted(hits.items()) if record]
        for entry in report["cached"]:
            print(f"CACHED {entry['name']}: passed {str(entry['passed_utc'])[:16]}Z on tree {entry['tree'][:10]}", flush=True)
        if hits:
            print(f"CACHED {len(report['cached'])} of {selected} checks passed earlier on inputs their rules call unchanged; "
                  "--fresh runs them again", flush=True)
        plan = [check for index, check in enumerate(plan) if index not in hits]
        keys = [key for index, key in enumerate(keys) if index not in hits]
    status = None
    if options.changed and not plan:
        report["complete"] = bool(report["cached"])
        status = 0 if report["cached"] else 1
    # After the keys: a pass does not depend on how many threads summed the forces.
    spare = max(2, (os.cpu_count() or 2) - options.jobs)
    plan = [check._replace(command=[*check.command, f"{check.cores}{spare}"]) if check.cores and len(plan) > 1 and check.alone is not True
            else check for check in plan]
    return plan, inputs, keys, status


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Interrupted as stop:
        print(f"CHECK STOPPED by signal {stop.signum}; running checks were stopped", file=sys.stderr, flush=True)
        sys.exit(128 + stop.signum)
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(f"CHECK FAILED: {error}")
