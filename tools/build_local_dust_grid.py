#!/usr/bin/env python3
"""Build assets/galaxy/local_dust_grid.bin: the measured dust around the Sun on a 3D grid, for
views away from the Sun (sim/galaxy/gal_local_dust.gd, docs/physics/galaxies.md).

    python3 -I tools/build_local_dust_grid.py mean_and_std_healpix.fits [out.bin]

Input: Edenhofer et al. (2024)'s posterior mean, as tools/build_local_dust.py reads it.

Output: the density averaged onto cubes in the Sun's galactic frame (x toward l = 0, y toward
the north galactic pole, z toward l = 270°), centred on the Sun, at two levels (LEVELS): 12.5 pc
cubes over a box 2.5 kpc square in the plane and 1 kpc thick, and 2.5 pc cubes within 200 pc
of the Sun (100 pc vertically), where the nearest clouds' cores are a few pc across and a
12.5 pc cube would average them away. Each cube is the mean of SUB³ points across it;
inside the map's first boundary (69 pc) a point takes the inner integral spread evenly, as the
shells do, and beyond 1.25 kpc it is empty. The build prints the share of the map's dust the
box holds.

Encoding as local_dust.bin's: a byte q = round(255 ln(ρ/RHO_MIN)/LN_RANGE), 0 below RHO_MIN.

Format, little-endian: b"ASLG", int32 version, the number of levels; per level int32 NX, NY,
NZ and float32 its cube's side (pc); float32 ln RHO_MIN, LN_RANGE; then each level's bytes in
turn, z slab by slab, each y row by row from the south, x fastest, deflate-compressed (zlib) as
one stream.

Pure Python on purpose: nothing downloaded is run. It reads the 1.6 GB mean once.
"""
import array
import hashlib
import math
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_local_dust import RHO_MIN, LN_RANGE, SIZE, hdus, table_column, ang2pix_nest  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "assets" / "galaxy" / "local_dust_grid.bin"
VERSION = 1
# (NX, NY, NZ, cube side in pc): the whole map's box, then the Sun's surroundings.
LEVELS = [(200, 80, 200, 12.5), (160, 80, 160, 2.5)]
SUB = 2
R_MAX = 1250.0


def main():
    if len(sys.argv) < 2: raise SystemExit(__doc__)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else OUT
    if src.stat().st_size != SIZE: raise SystemExit("BUILD FAIL: %s is not the published file's size" % src)
    ext = hdus(src)
    mh, moff = next((h, o) for h, o in ext if h.get("EXTNAME", "").strip().upper() == "MEAN")
    nside = int(mh["NSIDE"])
    npix = int(mh["NAXIS1"])
    nrad = int(mh["NAXIS2"])
    if mh["ORDERING"].upper() != "NEST" or npix != 12 * nside * nside or mh["BITPIX"] != "-32":
        raise SystemExit("BUILD FAIL: unexpected MEAN layout")
    bounds = inner = None
    for h, o in ext:
        if h.get("XTENSION") == "BINTABLE" and h.get("TTYPE1", "") == "radial pixel boundaries":
            bounds = table_column(src, h, o)
        name = h.get("EXTNAME", "").strip().lower()
        if h.get("XTENSION") == "IMAGE" and (name.startswith("mean of integrated inner") or name.startswith("integrated inner")):
            inner = (h, o)
    if bounds is None or inner is None: raise SystemExit("BUILD FAIL: no radial table or inner map")
    col, rep = bounds
    edges = col if rep == 1 and len(col) == nrad + 1 else [col[2 * i] for i in range(nrad)] + [col[-1]]
    ih, ioff = inner
    ctype = ih.get("CTYPE", ih.get("CTYPE1", "")).lower()
    r0 = float(ctype.split("within")[1].replace("pc", "").strip())
    if abs(edges[0] - r0) > 0.5: raise SystemExit("BUILD FAIL: the map starts at %.2f pc, the inner integral ends at %.2f" % (edges[0], r0))

    # Every sample point: its HEALPix pixel and cube (levels one after another), grouped by
    # radius (index nrad: the inner sphere). Points beyond the map are left out: empty.
    pix_of = [array.array("i") for _ in range(nrad + 1)]
    cell_of = [array.array("i") for _ in range(nrad + 1)]
    import bisect
    off = [(s + 0.5) / SUB for s in range(SUB)]
    base = 0
    starts = []
    for NX, NY, NZ, CELL in LEVELS:
        starts.append(base)
        for k in range(NZ):
            for j in range(NY):
                for i in range(NX):
                    c = base + (k * NY + j) * NX + i
                    for a in off:
                        z = ((k + a) * CELL - 0.5 * NZ * CELL)
                        for b in off:
                            y = ((j + b) * CELL - 0.5 * NY * CELL)
                            for e in off:
                                x = ((i + e) * CELL - 0.5 * NX * CELL)
                                r = math.sqrt(x * x + y * y + z * z)
                                if r >= edges[-1]: continue
                                p = ang2pix_nest(nside, y / r, math.atan2(-z, x) % (2.0 * math.pi))
                                n = nrad if r < edges[0] else bisect.bisect_right(edges, r) - 1
                                pix_of[n].append(p)
                                cell_of[n].append(c)
            if k % 20 == 0: print("BUILD points: level %.1f pc, slab %d/%d" % (CELL, k, NZ), flush=True)
        base += NX * NY * NZ
    ncell = base

    acc = array.array("d", bytes(8 * ncell))
    total = 0.0
    omega = 4.0 * math.pi / npix
    with open(src, "rb") as f:
        f.seek(ioff)
        a0 = array.array("f", f.read(4 * npix))
        if sys.byteorder == "little": a0.byteswap()
        for p, c in zip(pix_of[nrad], cell_of[nrad]): acc[c] += a0[p] / r0
        total += sum(a0) * omega * r0 * r0 / 3.0
        f.seek(moff)
        for n in range(nrad):
            row = array.array("f", f.read(4 * npix))
            if sys.byteorder == "little": row.byteswap()
            for p, c in zip(pix_of[n], cell_of[n]): acc[c] += row[p]
            total += sum(row) * omega * (edges[n + 1] ** 3 - edges[n] ** 3) / 3.0
            if n % 64 == 0: print("BUILD radius %d/%d" % (n, nrad), flush=True)
    n3 = SUB ** 3
    data = bytearray(ncell)
    head = b"ASLG" + struct.pack("<2i", VERSION, len(LEVELS))
    for lv, (NX, NY, NZ, CELL) in enumerate(LEVELS):
        held = 0.0
        for c in range(starts[lv], starts[lv] + NX * NY * NZ):
            rho = acc[c] / n3
            held += rho * CELL ** 3
            data[c] = 0 if rho <= RHO_MIN else min(255, int(round(255.0 * math.log(rho / RHO_MIN) / LN_RANGE)))
        print("BUILD level %.1f pc (%d × %d × %d) holds %.4f of the map's dust" % (CELL, NX, NY, NZ, held / total))
        head += struct.pack("<3if", NX, NY, NZ, CELL)
    head += struct.pack("<2f", math.log(RHO_MIN), LN_RANGE)
    blob = head + zlib.compress(bytes(data), 9)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    print("BUILD wrote %s: %d bytes, sha256 %s" % (out, len(blob), hashlib.sha256(blob).hexdigest()))


if __name__ == "__main__":
    main()
