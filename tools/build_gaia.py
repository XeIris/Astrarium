#!/usr/bin/env python3
"""Build assets/sky/gaia_g8.bin from Gaia DR3: the stars from G = 6.5 to 8.0, the
range below the Yale Bright Star Catalogue (tools/build_starcat.py).

    python3 tools/build_gaia.py path/to/gaia_g8.csv

The CSV is the result of one ADQL query to the ESA Gaia archive's TAP service
(https://gea.esac.esa.int/tap-server/tap/sync, FORMAT=csv):

    SELECT ra, dec, phot_g_mean_mag, bp_rp FROM gaiadr3.gaia_source
    WHERE phot_g_mean_mag > 6.5 AND phot_g_mean_mag <= 8.0

Gaia DR3 (Gaia Collaboration, Vallenari et al. 2023, A&A 674, A1) is ESA data
processed by the Gaia DPAC, licensed CC BY-SA 3.0 IGO; the packed file is a
derivative under the same licence.

Output: bsc5.bin's records, little-endian float32 (RA°, Dec° at the Gaia epoch, V,
B−V), brightest first, so BrightStars reads both files alike:
- V from G and C = BP−RP by Riello et al. (2021, A&A 649, A3, table C.2),
  G − V = −0.02704 + 0.01424 C − 0.2156 C² + 0.01426 C³, for −0.5 < C < 2.75;
- B−V as the colour whose Ballesteros (2012) temperature matches the dwarf
  BP−RP temperature of Mucciarelli & Bellazzini (2020),
  θ = 5040/T = 0.4929 + 0.5092 C − 0.0353 C²;
- a star missing BP−RP takes C = 0.82 (the Sun's), and C is clamped to the
  relations' range;
- a star within 30″ of a BSC5 star and within a magnitude of it is that star, and
  is dropped. Proper motion from 2016 to 2000 (at most a few arcseconds) is ignored.
"""
import csv
import io
import math
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BSC5 = ROOT / "assets" / "sky" / "bsc5.bin"
OUT = ROOT / "assets" / "sky" / "gaia_g8.bin"


def v_of(g, c):
    return g - (-0.02704 + 0.01424 * c - 0.2156 * c * c + 0.01426 * c * c * c)


def teff_of(c):
    return 5040.0 / (0.4929 + 0.5092 * c - 0.0353 * c * c)


def ballesteros(bv):
    return 4600.0 * (1.0 / (0.92 * bv + 1.7) + 1.0 / (0.92 * bv + 0.62))


def bv_of(c):
    t = teff_of(c)
    lo, hi = -0.4, 2.0
    for _ in range(60):
        mid = 0.5 * (lo + hi)
        if ballesteros(mid) > t:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def unit(ra, dec):
    a, d = math.radians(ra), math.radians(dec)
    return (math.cos(d) * math.cos(a), math.cos(d) * math.sin(a), math.sin(d))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    bright = []
    raw = BSC5.read_bytes()
    for i in range(0, len(raw) - 15, 16):
        ra, dec, v, _ = struct.unpack_from("<4f", raw, i)
        bright.append((unit(ra, dec), v))
    # Bin the bright stars by declination so the match is quick.
    bins = {}
    for u, v in bright:
        bins.setdefault(int((math.degrees(math.asin(u[2])) + 90.0) * 2.0), []).append((u, v))
    cos_max = math.cos(math.radians(30.0 / 3600.0))
    stars, dropped = [], 0
    with io.open(sys.argv[1], newline="") as f:
        for row in csv.DictReader(f):
            ra, dec, g = float(row["ra"]), float(row["dec"]), float(row["phot_g_mean_mag"])
            c = float(row["bp_rp"]) if row["bp_rp"] not in ("", "null") else 0.82
            c = min(max(c, -0.5), 2.75)
            v = v_of(g, c)
            u = unit(ra, dec)
            b = int((dec + 90.0) * 2.0)
            same = any(u[0] * w[0] + u[1] * w[1] + u[2] * w[2] > cos_max and abs(v - vb) < 1.0
                       for k in (b - 1, b, b + 1) for w, vb in bins.get(k, ()))
            if same:
                dropped += 1
                continue
            stars.append((ra, dec, v, bv_of(min(max(c, -0.2), 2.5))))
    if len(stars) < 30000:
        sys.exit(f"build_gaia: only {len(stars)} stars; the query or table layout may have changed")
    stars.sort(key=lambda s: s[2])
    with io.open(OUT, "wb") as f:
        for s in stars:
            f.write(struct.pack("<4f", *s))
    print(f"build_gaia: {len(stars)} stars (V {stars[0][2]:.2f} to {stars[-1][2]:.2f}), "
          f"{dropped} already in BSC5 -> {OUT}")


if __name__ == "__main__":
    main()
