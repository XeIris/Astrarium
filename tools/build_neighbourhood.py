#!/usr/bin/env python3
"""Build assets/sky/neighbourhood.bin: the real stars around the Sun in three dimensions,
for the galactic scene (sim/galaxy/gal_neighbourhood.gd, docs/physics/galaxies.md).

    python3 tools/build_neighbourhood.py BSC5P.tdat.gz GAIA_BRIGHT.csv GAIA_G8.csv GAIA_40PC.csv [HIP2.csv]

Two sets:
- far: the Solar System sky's own stars, BSC5 (as tools/build_starcat.py reads it) and
  Gaia DR3 from G = 6.5 to 8 less BSC5's (as tools/build_gaia.py selects and converts
  them), with the same V and B−V, so from the Sun the galactic scene shows that sky;
- near: every star within NEAR_PC brighter than M_V = M_V_RESOLVED, the galactic
  scene's resolved limit (GalPopulation.M_RESOLVED's main-sequence star in the model),
  from Gaia DR3 and BSC5. A sky star that qualifies moves to this set; one nearer but
  fainter (a red dwarf such as Lacaille 9352) stays far, so the sky stays whole.

Gaia DR3 and Hipparcos are ESA data under CC BY-NC 3.0 IGO (Credit: ESA/Gaia/DPAC; Credit:
ESA for Hipparcos). The packed file is derived data under the same terms: non-commercial
whatever the project's MIT licence says (THIRD_PARTY.md).

Inputs, each one ADQL query to the ESA Gaia archive (https://gea.esac.esa.int/tap-server/tap,
asynchronous, FORMAT=csv, MAXREC=200000):
- GAIA_BRIGHT: SELECT source_id, ra, dec, parallax, parallax_error, phot_g_mean_mag, bp_rp,
  pmra, pmdec, ruwe FROM gaiadr3.gaia_source WHERE phot_g_mean_mag <= 6.5
- GAIA_G8: SELECT source_id, ra, dec, parallax, parallax_error, phot_g_mean_mag, bp_rp, pmra,
  pmdec, ruwe FROM gaiadr3.gaia_source WHERE phot_g_mean_mag > 6.5 AND phot_g_mean_mag <= 8.0
  (extra columns are ignored)
- GAIA_40PC: the same columns WHERE parallax > 25 AND parallax_over_error > 10 AND
  phot_g_mean_mag + 5*LOG10(parallax/100.0) < 10.5
- HIP2 (optional): SELECT hip, ra, dec, plx, e_plx, pm_ra, pm_de, hp_mag, b_v, v_i, sn FROM
  public.hipparcos_newreduction (van Leeuwen 2007)
and BSC5P.tdat.gz from HEASARC (tools/build_starcat.py).

A star's distance, in order: its Gaia DR3 parallax at parallax/error ≥ 10, where Gaia's
astrometry is sound (RUWE ≤ 1.4, Lindegren et al. 2021's threshold, and G ≥ 5, below which
Gaia saturates); Hipparcos's at ≥ 5; Gaia's at ≥ 5 (now whatever its RUWE or G); BSC5's own
parallax (BSC5 stars only); otherwise FALLBACK_PC, flagged.

Gaia's parallax zero-point (Lindegren et al. 2021, about −0.02 mas for these stars) is not
applied. It moves a near star (parallax ≥ 25 mas) by under 0.1 %, and the far set's distances
show only as parallax while the camera is within 30 pc of the Sun (FAR_FADE), where a far
star's own parallax is a few mas at least: under 1 %. The reference implementation is a
downloaded package, which this build does not run. Matches are within 10″ (positions carried to J2000 by
their proper motions) and a magnitude.

Output, little-endian: b"ASNB", then int32 version, near count, far count; then float32
records (x, y, z in pc from the Sun on the galactic scene's axes: +x toward the Galactic
centre, +y toward the north galactic pole, +z toward l = 270°; M_V; B−V; distance source:
0 Gaia, 1 Hipparcos, 2 BSC5, 3 none), near first, each set brightest first.
"""
import csv
import math
import struct
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_gaia  # noqa: E402
import build_starcat  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "assets" / "sky" / "neighbourhood.bin"
VERSION = 1
NEAR_PC = 40.0
# The model's 0.5 M☉ main-sequence star: L = 0.0625 L☉ with 0.524 of the Sun's visible
# light per L☉, M_V = 4.83 − 2.5 log10(0.0328). galaxycheck holds this to the model.
M_V_RESOLVED = 8.541
FALLBACK_PC = 1000.0
MATCH_ARCSEC = 10.0
# The galactic frame as SkyModel.galactic_frame_j2000 builds it: the north galactic pole
# and the centre's direction (ICRS degrees).
NGP = (192.85948, 27.12825)
GC = (266.40500, -28.93617)


def unit(ra, dec):
    a, d = math.radians(ra), math.radians(dec)
    return (math.cos(d) * math.cos(a), math.cos(d) * math.sin(a), math.sin(d))


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def frame():
    n = unit(*NGP)
    c = unit(*GC)
    k = dot(c, n)
    c = tuple(ci - k * ni for ci, ni in zip(c, n))
    m = math.sqrt(dot(c, c))
    c = tuple(ci / m for ci in c)
    y = (n[1] * c[2] - n[2] * c[1], n[2] * c[0] - n[0] * c[2], n[0] * c[1] - n[1] * c[0])
    return c, y, n  # galactic X (centre), Y (l = 90°), Z (pole)


X_G, Y_G, Z_G = frame()


def local(u, d_pc):
    """The scene's axes: X toward the centre, Y the pole, Z = −Y_galactic (the Galaxy turns
    toward −Z at the Sun, GalModels' sense = +1)."""
    return (d_pc * dot(u, X_G), d_pc * dot(u, Z_G), -d_pc * dot(u, Y_G))


def number(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return math.nan


def to_j2000(ra, dec, pma, pmd, epoch):
    """A position carried from `epoch` to J2000 by its proper motion (mas/yr)."""
    dt = 2000.0 - epoch
    dec2 = dec + pmd * dt / 3.6e6
    return ra + pma * dt / 3.6e6 / max(math.cos(math.radians(dec2)), 1e-6), dec2


class Index:
    """Stars binned by declination for matching."""

    def __init__(self, stars):
        self.bins = {}
        for s in stars:
            self.bins.setdefault(int((s["dec"] + 90.0) * 2.0), []).append(s)

    def best(self, ra, dec, mag, key):
        u = unit(ra, dec)
        cmax = math.cos(math.radians(MATCH_ARCSEC / 3600.0))
        k = int((dec + 90.0) * 2.0)
        out, best = None, -1.0
        for kk in (k - 1, k, k + 1):
            for s in self.bins.get(kk, ()):
                c = dot(u, s["u"])
                if c > cmax and abs(s[key] - mag) < 1.0 and c > best:
                    out, best = s, c
        return out


def gaia_rows(path):
    for r in csv.DictReader(open(path, newline="")):
        g = float(r["phot_g_mean_mag"])
        c = number(r.get("bp_rp"))
        c = 0.82 if math.isnan(c) else c
        c = min(max(c, -0.5), 2.75)
        pma = number(r.get("pmra"))
        pmd = number(r.get("pmdec"))
        pma = 0.0 if math.isnan(pma) else pma
        pmd = 0.0 if math.isnan(pmd) else pmd
        ra0, dec0 = float(r["ra"]), float(r["dec"])
        ra, dec = to_j2000(ra0, dec0, pma, pmd, 2016.0)
        yield {"id": r["source_id"], "ra0": ra0, "dec0": dec0, "ra": ra, "dec": dec, "u": unit(ra, dec),
               "g": g, "c": c, "v": build_gaia.v_of(g, c), "bv": build_gaia.bv_of(min(max(c, -0.2), 2.5)),
               "plx": number(r.get("parallax")), "err": number(r.get("parallax_error")), "pm": (pma, pmd),
               "ruwe": number(r.get("ruwe")) if "ruwe" in r else None}


def hip_rows(path):
    for r in csv.DictReader(open(path, newline="")):
        pma, pmd = number(r["pm_ra"]), number(r["pm_de"])
        pma = 0.0 if math.isnan(pma) else pma
        pmd = 0.0 if math.isnan(pmd) else pmd
        ra, dec = to_j2000(float(r["ra"]), float(r["dec"]), pma, pmd, 1991.25)
        yield {"ra": ra, "dec": dec, "u": unit(ra, dec), "hp": number(r["hp_mag"]),
               "plx": number(r["plx"]), "err": number(r["e_plx"])}


def good(plx, err, snr):
    return not math.isnan(plx) and not math.isnan(err) and plx > 0.0 and err > 0.0 and plx / err >= snr


# Gaia's astrometry is preferred only where it is sound: RUWE ≤ 1.4 (Lindegren et al. 2021,
# their recommended threshold for a well-behaved single-star solution) and G ≥ 5, below which
# Gaia saturates (Lindegren et al. 2021 §2). Otherwise Hipparcos goes first.
RUWE_MAX = 1.4
G_SATURATED = 5.0


def gaia_sound(s):
    ruwe = s.get("ruwe")
    if ruwe is None:
        sys.exit("build_neighbourhood: a Gaia file has no ruwe column; rerun its query with ruwe")
    # A two-parameter solution has no parallax and no RUWE: never sound.
    return not math.isnan(ruwe) and ruwe <= RUWE_MAX and s["g"] >= G_SATURATED


def main():
    if len(sys.argv) not in (5, 6):
        sys.exit(__doc__)
    bsc_path, bright_path, g8_path, near_path = sys.argv[1:5]
    hip = Index(list(hip_rows(sys.argv[5]))) if len(sys.argv) == 6 else None
    gaia_bright = list(gaia_rows(bright_path))
    gaia_g8 = list(gaia_rows(g8_path))
    gaia_all = Index(gaia_bright + gaia_g8)

    stars = []  # (u, d_pc, V, B−V, source, gaia id or None)
    tally = {"gaia": 0, "hipparcos": 0, "gaia_weak": 0, "bsc5": 0, "none": 0}
    for r in build_starcat.table(bsc_path):
        ra, dec, v = (build_starcat.number(r.get(k)) for k in ("ra", "dec", "vmag"))
        if math.isnan(ra) or math.isnan(dec) or math.isnan(v):
            continue
        bv = build_starcat.number(r.get("bv_color"))
        g = gaia_all.best(ra, dec, v, "v")
        h = hip.best(ra, dec, v, "hp") if hip else None
        if g and gaia_sound(g) and good(g["plx"], g["err"], 10.0):
            d, src = 1000.0 / g["plx"], 0
            tally["gaia"] += 1
        elif h and good(h["plx"], h["err"], 5.0):
            d, src = 1000.0 / h["plx"], 1
            tally["hipparcos"] += 1
        elif g and good(g["plx"], g["err"], 5.0):
            d, src = 1000.0 / g["plx"], 0
            tally["gaia_weak"] += 1
        elif build_starcat.number(r.get("parallax")) > 0.0:
            d, src = 1.0 / build_starcat.number(r.get("parallax")), 2
            tally["bsc5"] += 1
        else:
            d, src = FALLBACK_PC, 3
            tally["none"] += 1
        stars.append((unit(ra, dec), d, v, bv, src, g["id"] if g else None))
    n_bsc = len(stars)
    if n_bsc < 9000:
        sys.exit(f"build_neighbourhood: only {n_bsc} BSC5 stars; the table layout may have changed")

    # Gaia G 6.5–8 less BSC5, by tools/build_gaia.py's rule (30″ and a magnitude).
    bsc_index = {}
    for u, _, v, _, _, _ in stars:
        bsc_index.setdefault(int((math.degrees(math.asin(u[2])) + 90.0) * 2.0), []).append((u, v))
    cos30 = math.cos(math.radians(30.0 / 3600.0))
    dropped = 0
    for s in gaia_g8:
        u0 = unit(s["ra0"], s["dec0"])
        b = int((s["dec0"] + 90.0) * 2.0)
        if any(dot(u0, w) > cos30 and abs(s["v"] - vb) < 1.0 for k in (b - 1, b, b + 1) for w, vb in bsc_index.get(k, ())):
            dropped += 1
            continue
        h = hip.best(s["ra"], s["dec"], s["v"], "hp") if hip else None
        if gaia_sound(s) and good(s["plx"], s["err"], 10.0):
            d, src = 1000.0 / s["plx"], 0
            tally["gaia"] += 1
        elif h and good(h["plx"], h["err"], 5.0):
            d, src = 1000.0 / h["plx"], 1
            tally["hipparcos"] += 1
        elif good(s["plx"], s["err"], 5.0):
            d, src = 1000.0 / s["plx"], 0
            tally["gaia_weak"] += 1
        else:
            d, src = FALLBACK_PC, 3
            tally["none"] += 1
        stars.append((s["u"], d, s["v"], s["bv"], src, s["id"]))
    if len(stars) - n_bsc < 30000:
        sys.exit("build_neighbourhood: too few Gaia G 6.5–8 stars; the query may have changed")

    near, far = [], []
    for u, d, v, bv, src, gid in stars:
        rec = (*local(u, d), v - 5.0 * math.log10(d / 10.0), bv, float(src))
        (near if d < NEAR_PC and rec[3] < M_V_RESOLVED else far).append((rec, gid))
    taken = {gid for _, gid in near if gid} | {gid for _, gid in far if gid}
    added = 0
    for s in gaia_rows(near_path):
        if s["id"] in taken or not good(s["plx"], s["err"], 10.0):
            continue
        d = 1000.0 / s["plx"]
        mv = s["v"] - 5.0 * math.log10(d / 10.0)
        if d >= NEAR_PC or mv >= M_V_RESOLVED:
            continue
        near.append(((*local(s["u"], d), mv, s["bv"], 0.0), s["id"]))
        added += 1
    near = [r for r, _ in near]
    far = [r for r, _ in far]
    near.sort(key=lambda r: r[3])
    far.sort(key=lambda r: r[3])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUT, "wb") as f:
        f.write(b"ASNB" + struct.pack("<3i", VERSION, len(near), len(far)))
        for r in near + far:
            f.write(struct.pack("<6f", *r))
    print(f"build_neighbourhood: {len(near)} stars within {NEAR_PC:g} pc to M_V {M_V_RESOLVED} "
          f"({added} from the 40 pc sample), {len(far)} more in the sky; {dropped} Gaia stars already in BSC5; "
          f"distances {tally}; Hipparcos {'used' if hip else 'not given'} -> {OUT}")


if __name__ == "__main__":
    main()
