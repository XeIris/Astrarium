"""Bake geometric Sun-centred J2000 ecliptic vectors from JPL Horizons and Voyager navigation SPKs.

Run with Python 3 and SpiceyPy. The archive uses UTC Unix seconds, AU,
and AU/day. Keep calls serial as required by the JPL SSD API fair-use policy.
"""
import argparse
import csv
import json
import math
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import urlopen, urlretrieve

import spiceypy as spice

ROOT = Path(__file__).resolve().parents[1]
START = "1977-08-20 00:00:00"
END = "2026-11-19 23:59:59"
# Start at the first whole UTC second inside each SPK.
PROBES = {"Voyager 1": (-31, "1977-09-05 13:58:37"), "Voyager 2": (-32, "1977-08-20 15:31:45")}
# Spacecraft SPK, central body and (where present) the matching satellite solution.
ENCOUNTERS = [
    ("Voyager 1", "1979-03-05", "vgr1_jup230.bsp", "Jupiter", "Io"),
    ("Voyager 1", "1980-11-12", "vgr1_sat337.bsp", "Saturn", "Titan"),
    ("Voyager 2", "1979-07-09", "vgr2_jup230.bsp", "Jupiter", None),
    ("Voyager 2", "1981-08-26", "vgr2_sat337.bsp", "Saturn", None),
    ("Voyager 2", "1986-01-24", "vgr2.ura182.bsp", "Uranus", "Miranda"),
    ("Voyager 2", "1989-08-25", "vgr2_nep097.bsp", "Neptune", "Triton"),
]
PLANETS = {"Mercury": (199, 3), "Venus": (299, 7), "Earth": (399, 5),
           "Mars": (499, 12), "Jupiter": (599, 24), "Saturn": (699, 32),
           "Uranus": (799, 48), "Neptune": (899, 48)}
MOONS = {"Io": 501, "Titan": 606, "Miranda": 705, "Triton": 801}
AU_KM = 149597870.7


def date(s):
    return datetime.fromisoformat(s).replace(tzinfo=timezone.utc)


def stamp(dt):
    return dt.strftime("%Y-%m-%d %H:%M:%S")


def vectors(target, start, end, step):
    args = dict(COMMAND=target, CENTER="500@10", EPHEM_TYPE="VECTORS", REF_SYSTEM="ICRF",
                REF_PLANE="ECLIPTIC", VEC_CORR="NONE", VEC_TABLE=2, TIME_TYPE="UT",
                OUT_UNITS="AU-D", CSV_FORMAT="YES", START_TIME=start, STOP_TIME=end,
                STEP_SIZE=step, OBJ_DATA="NO")
    url = "https://ssd.jpl.nasa.gov/api/horizons.api?" + urlencode(
        {"format": "json", **{k: f"'{v}'" for k, v in args.items()}})
    for attempt in range(3):
        try:
            with urlopen(url, timeout=120) as response:
                result = json.load(response)
            break
        except OSError:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)
    table = result["result"]
    if "$$SOE" not in table or "$$EOE" not in table:
        raise ValueError(table[-1500:])
    rows = csv.reader(table.split("$$SOE")[1].split("$$EOE")[0].strip().splitlines())
    states = {}
    for row in rows:
        t = round((float(row[0]) - 2440587.5) * 86400)
        vec = tuple(map(float, row[2:8]))
        if len(vec) != 6 or not all(map(math.isfinite, vec)):
            raise ValueError(row)
        states[t] = vec
    if min(states) != int(date(start).timestamp()):
        raise ValueError(f"Incomplete Horizons interval for {target} at {start}")
    return states


def window(target, center, days, step):
    t = date(center)
    return vectors(target, stamp(t - timedelta(days=days)), stamp(t + timedelta(days=days)), step)


def encounter_tracks(tracks, kernel_dir):
    kernel_dir.mkdir(parents=True, exist_ok=True)
    base = "https://naif.jpl.nasa.gov/pub/naif/"
    paths = {"de440s.bsp": "generic_kernels/spk/planets/", "naif0012.tls": "generic_kernels/lsk/"}
    paths.update({name: "VOYAGER/kernels/spk/" for name in ["sat337.bsp", *(e[2] for e in ENCOUNTERS)]})
    for name, directory in paths.items():
        path = kernel_dir / name
        if not path.exists():
            pending = path.with_suffix(path.suffix + ".part")
            urlretrieve(base + directory + name, pending)
            pending.replace(path)

    for probe, when, kernel, planet, moon in ENCOUNTERS:
        print(f"Sampling {kernel}", flush=True)
        spice.kclear()
        for name in ["naif0012.tls", "de440s.bsp", "sat337.bsp", kernel]:
            spice.furnsh(str(kernel_dir / name))
        center = int(date(when).timestamp())
        probe_id = PROBES[probe][0]
        # The broader Horizons knots on either side join back into the long cruise.
        tracks[probe].update(window(probe_id, when, 15, "12 h"))
        targets = [(probe, probe_id, 600)]
        if planet == "Jupiter":
            # The jup230 encounter SPKs contain the spacecraft alone.
            tracks[planet].update(window(599, when, 3, "3 h"))
            if moon:
                tracks[moon] = window(MOONS[moon], when, 3, "20 m")
        else:
            targets.append((planet, PLANETS[planet][0], 10800))
            if moon:
                targets.append((moon, MOONS[moon], 1200))
        for name, target, seconds in targets:
            track = tracks.setdefault(name, {})
            start = center - 3 * 86400
            stop = center + 3 * 86400
            times = set(range(start, stop + 1, seconds))
            times.update(t for t in track if start <= t <= stop)
            for t in sorted(times):
                epoch = spice.str2et(datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S"))
                state, _ = spice.spkezr(str(target), epoch, "ECLIPJ2000", "NONE", "SUN")
                track[t] = tuple(x / AU_KM for x in state[:3]) + tuple(v * 86400 / AU_KM for v in state[3:])
    spice.kclear()


def build(kernel_dir):
    tracks = {}
    for name, (target, step) in PLANETS.items():
        print(f"Fetching {name}", flush=True)
        tracks[name] = vectors(target, START, END, f"{step} d")
    for name, (target, start) in PROBES.items():
        track = vectors(target, start, END, "28 d")
        track.update(vectors(target, start, stamp(date(start) + timedelta(days=10)), "2 h"))
        tracks[name] = track
    encounter_tracks(tracks, kernel_dir)
    for name, (target, _) in {**PROBES, **PLANETS}.items():
        # A fixed cadence rarely lands on the endpoint.
        endpoint = vectors(target, END, "2026-11-20 00:00:59", "1 m")
        t = int(date(END).timestamp())
        tracks[name][t] = endpoint[t]
    # Godot imports the text resource and exports it as a binary resource.
    out = ROOT / "assets/voyager/trajectory.tres"
    with tempfile.NamedTemporaryFile("w", dir=out.parent, delete=False) as f:
        f.write('[gd_resource type="Resource" script_class="VoyagerArchive" format=3]\n\n')
        f.write('[ext_resource type="Script" path="res://sim/voyager/archive.gd" id="1"]\n\n')
        f.write('[resource]\nscript = ExtResource("1")\ntracks = {\n')
        for idx, (name, track) in enumerate(tracks.items()):
            f.write(f'"{name}": PackedFloat64Array(\n')
            rows = [", ".join([str(t), *(f"{x:.15g}" for x in state)])
                    for t, state in sorted(track.items())]
            f.write(",\n".join(rows))
            f.write("\n)" + ("," if idx + 1 < len(tracks) else "") + "\n")
            print(f"{name}: {len(rows)} states")
        f.write("}\n")
    Path(f.name).chmod(0o644)
    Path(f.name).replace(out)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernels", type=Path, help="Keep downloaded NAIF kernels in this directory")
    options = parser.parse_args()
    with tempfile.TemporaryDirectory() as scratch:
        build(options.kernels or Path(scratch))
