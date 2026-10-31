#!/usr/bin/env python3
"""Build assets/sky/bsc5.bin from the Yale Bright Star Catalogue, 5th revised ed.
(Hoffleit & Warren 1991), as HEASARC distributes it (table BSC5P).

    python3 tools/build_starcat.py [path/to/heasarc_bsc5p.tdat.gz]

Without a path it downloads
https://heasarc.gsfc.nasa.gov/FTP/heasarc/dbase/tdat_files/heasarc_bsc5p.tdat.gz.
Output: little-endian float32 records (RA°, Dec° J2000, V, B−V), brightest first,
for every entry with a position and V; a missing B−V is written as NaN.
"""
import gzip
import io
import math
import struct
import sys
import urllib.request
from pathlib import Path

URL = "https://heasarc.gsfc.nasa.gov/FTP/heasarc/dbase/tdat_files/heasarc_bsc5p.tdat.gz"
OUT = Path(__file__).resolve().parent.parent / "assets" / "sky" / "bsc5.bin"


def rows(text):
    fields, data = None, False
    for line in text.splitlines():
        if line.startswith("line[1]"):
            fields = line.split("=", 1)[1].split()
        elif line.strip() == "<DATA>":
            data = True
        elif line.strip() == "<END>":
            break
        elif data and fields:
            yield dict(zip(fields, line.split("|")))


def number(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return math.nan


def main():
    raw = Path(sys.argv[1]).read_bytes() if len(sys.argv) > 1 else urllib.request.urlopen(URL, timeout=60).read()
    text = gzip.decompress(raw).decode("latin-1") if raw[:2] == b"\x1f\x8b" else raw.decode("latin-1")
    stars = []
    for r in rows(text):
        ra, dec, v = number(r.get("ra")), number(r.get("dec")), number(r.get("vmag"))
        if math.isnan(ra) or math.isnan(dec) or math.isnan(v):
            continue
        stars.append((ra, dec, v, number(r.get("bv_color"))))
    if len(stars) < 9000:
        sys.exit(f"build_starcat: only {len(stars)} stars parsed; the table layout may have changed")
    stars.sort(key=lambda s: s[2])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    with io.open(OUT, "wb") as f:
        for s in stars:
            f.write(struct.pack("<4f", *s))
    print(f"build_starcat: {len(stars)} stars, V {stars[0][2]:.2f} to {stars[-1][2]:.2f} -> {OUT}")


if __name__ == "__main__":
    main()
