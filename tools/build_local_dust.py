#!/usr/bin/env python3
"""Build assets/galaxy/local_dust.bin: the measured dust around the Sun, for the galactic
scene's view from inside the disc (sim/galaxy/gal_local_dust.gd, docs/physics/galaxies.md).

    python3 -I tools/build_local_dust.py mean_and_std_healpix.fits [out.bin]

Input: Edenhofer et al. (2024, A&A 685, A82), "A parsec-scale Galactic 3D dust map out to
1.25 kpc from the Sun", the posterior mean on HEALPix spheres (Zenodo 10.5281/zenodo.10658339,
v1.0.2, mean_and_std_healpix.fits, 3 252 715 200 bytes, md5 10c823a5fcf81b47b6e15530bcdf54dc;
CC BY 4.0). The file holds the differential extinction in E of Zhang, Green & Rix (2023) per
pc on NSIDE 256 NESTED galactic pixels at 516 radii from 68.6 to 1248.1 pc, the radii's
boundaries, and the extinction integrated within the inner 69 pc, which the map leaves out.

Output: the same density, averaged
- in angle onto W × H cells even in galactic l and in sin b (equal areas, 15′ square in the
  plane, where the structure is, and longer in b toward the poles), each the mean of SUB × SUB
  HEALPix lookups across the cell (the map's own cells are 14′);
- in distance onto LAYERS shells between the map's own boundaries, nearest in ln r to an even
  split (43 % deep each), each the density that keeps the shell's integral (Σ ρ Δr / ΔR);
plus an innermost shell from 0 to 69 pc holding the inner integral spread evenly over it.
Integrated extinction to every kept boundary is therefore unchanged by the averaging in
distance; the build prints how far the averaging in angle moves it.

Encoding: a cell's density ρ (E pc⁻¹) as a byte q = round(255 ln(ρ/RHO_MIN)/LN_RANGE), 0 at
or below RHO_MIN, and read back as RHO_MIN·exp(LN_RANGE·q/255), byte 0 too: steps of 4.9 %, about
2.5 % at worst. RHO_MIN integrates to 1.3e-3 E (3e-3 mag in V) over the whole map.

Format, little-endian: b"ASLD", int32 version, W, H, LAYERS + 1; float32 the shells' outer
radii (pc), ln RHO_MIN, LN_RANGE; then the bytes, shell by shell, row by row from sin b = 1,
each row from l = 0 eastward, deflate-compressed (zlib) as one stream.

Pure Python on purpose: nothing downloaded is run, and the build needs no packages. It checks
the file's md5, then reads the 1.6 GB mean once, a row of radii at a time, and takes a few minutes.
"""
import array
import math
import struct
import sys
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "assets" / "galaxy" / "local_dust.bin"
VERSION = 1
# H rows of 2/H in sin b: 15′ at b = 0, as the 1440 columns are.
W, H = 1440, 458
SUB = 2
# Each shell costs the view from the Sun a read and a segment per pixel: eight hold it at the
# M5's 30 fps, and from the Sun the extinction to every kept boundary is the map's own.
LAYERS = 8
RHO_MIN = 1.0e-6
LN_RANGE = 12.5
MD5 = "10c823a5fcf81b47b6e15530bcdf54dc"
SIZE = 3252715200


def cards(f):
    """One FITS header as a dict (CONTINUE cards dropped), and the file left at its data."""
    h = {}
    while True:
        block = f.read(2880)
        if len(block) < 2880: raise SystemExit("BUILD FAIL: truncated FITS header")
        for k in range(36):
            c = block[80 * k:80 * k + 80].decode("ascii")
            key = c[:8].strip()
            if key == "END": return h
            if c[8:10] != "= ": continue
            v = c[10:].split("/")[0].strip() if not c[10:].strip().startswith("'") else c[10:].strip()
            if v.startswith("'"): v = v[1:v.index("'", 1)].strip()
            h[key] = v


def data_bytes(h):
    n = abs(int(h["BITPIX"])) // 8
    for a in range(int(h.get("NAXIS", 0))): n *= int(h["NAXIS%d" % (a + 1)])
    n = (n + int(h.get("PCOUNT", 0))) * int(h.get("GCOUNT", 1))
    return n + (-n % 2880)


def hdus(path):
    """Each extension's header and data offset."""
    out = []
    with open(path, "rb") as f:
        while True:
            pos = f.tell()
            if not f.read(1): break
            f.seek(pos)
            h = cards(f)
            out.append((h, f.tell()))
            f.seek(data_bytes(h) if int(h.get("NAXIS", 0)) else 0, 1)
    return out


def table_column(path, h, off):
    """A one-column binary table of doubles or floats, as a flat list."""
    form = h["TFORM1"]
    rep = int(form[:-1] or 1)
    code = form[-1]
    fmt = {"D": "d", "E": "f"}[code]
    rows = int(h["NAXIS2"])
    with open(path, "rb") as f:
        f.seek(off)
        raw = f.read(rows * rep * struct.calcsize(fmt))
    a = array.array(fmt, raw)
    if sys.byteorder == "little": a.byteswap()
    return list(a), rep


def spread(v):
    """Interleave a coordinate's bits with zeros (HEALPix NESTED's x/y to pixel)."""
    r = 0
    for b in range(16):
        r |= ((v >> b) & 1) << (2 * b)
    return r


def ang2pix_nest(nside, z, phi):
    """HEALPix NESTED pixel of the direction with cos θ = z and longitude φ (Górski et al.
    2005, as chealpix's ang2pix_nest_z_phi computes it)."""
    za = abs(z)
    tt = (phi % (2.0 * math.pi)) / (0.5 * math.pi)
    if za <= 2.0 / 3.0:
        t1 = nside * (0.5 + tt)
        t2 = nside * z * 0.75
        jp = int(t1 - t2)
        jm = int(t1 + t2)
        ifp = jp // nside
        ifm = jm // nside
        face = (ifp | 4) if ifp == ifm else (ifp if ifp < ifm else ifm + 8)
        ix = jm & (nside - 1)
        iy = nside - (jp & (nside - 1)) - 1
    else:
        ntt = min(int(tt), 3)
        tp = tt - ntt
        tmp = nside * math.sqrt(3.0 * (1.0 - za))
        jp = min(int(tp * tmp), nside - 1)
        jm = min(int((1.0 - tp) * tmp), nside - 1)
        if z >= 0:
            face, ix, iy = ntt, nside - jm - 1, nside - jp - 1
        else:
            face, ix, iy = ntt + 8, jp, jm
    return face * nside * nside + (spread(ix) | (spread(iy) << 1))


def pix2ang_nest(nside, p):
    """(z, φ) of a NESTED pixel's centre: the inverse, written from the same paper, to check
    the lookup by a round trip."""
    npface = nside * nside
    face, q = divmod(p, npface)
    ix = iy = 0
    for b in range(16):
        ix |= ((q >> (2 * b)) & 1) << b
        iy |= ((q >> (2 * b + 1)) & 1) << b
    jrll = [2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4][face]
    jpll = [1, 3, 5, 7, 0, 2, 4, 6, 1, 3, 5, 7][face]
    jr = jrll * nside - ix - iy - 1
    if jr < nside:
        nr = jr
        z = 1.0 - nr * nr / (3.0 * npface)
        kshift = 0
    elif jr > 3 * nside:
        nr = 4 * nside - jr
        z = nr * nr / (3.0 * npface) - 1.0
        kshift = 0
    else:
        nr = nside
        z = (2 * nside - jr) * 2.0 / (3.0 * nside)
        kshift = (jr - nside) & 1
    jp = (jpll * nr + ix - iy + 1 + kshift) // 2
    if jp > 4 * nside: jp -= 4 * nside
    if jp < 1: jp += 4 * nside
    phi = (jp - (kshift + 1) * 0.5) * (0.5 * math.pi / nr)
    return z, phi


def check_source(src):
    """The published file, by size and md5, read once in 16 MB pieces before anything uses it."""
    import hashlib
    if src.stat().st_size != SIZE: raise SystemExit("BUILD FAIL: %s is not the published file's size" % src)
    h = hashlib.md5()
    with open(src, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""): h.update(chunk)
    if h.hexdigest() != MD5: raise SystemExit("BUILD FAIL: %s is not the published file (md5 %s)" % (src, h.hexdigest()))


def main():
    if len(sys.argv) < 2: raise SystemExit(__doc__)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else OUT
    check_source(src)
    ext = hdus(src)
    mean = next((h, o) for h, o in ext if h.get("EXTNAME", "").strip().upper() == "MEAN")
    mh, moff = mean
    nside = int(mh["NSIDE"])
    npix = int(mh["NAXIS1"])
    nrad = int(mh["NAXIS2"])
    if mh["ORDERING"].upper() != "NEST" or npix != 12 * nside * nside or mh["BITPIX"] != "-32":
        raise SystemExit("BUILD FAIL: unexpected MEAN layout")
    bounds = centres = inner = None
    for h, o in ext:
        if h.get("XTENSION") == "BINTABLE":
            name = h.get("TTYPE1", "")
            col, rep = table_column(src, h, o)
            if name == "radial pixel boundaries": bounds = (col, rep)
            if name == "radial pixel centers": centres = col
        name = h.get("EXTNAME", "").strip().lower()
        if h.get("XTENSION") == "IMAGE" and (name.startswith("mean of integrated inner") or name.startswith("integrated inner")):
            inner = (h, o)
    if bounds is None or centres is None or inner is None: raise SystemExit("BUILD FAIL: no radial table or inner map")
    col, rep = bounds
    # Boundaries as published: either nrad + 1 edges, or (lo, hi) per radius.
    edges = col if rep == 1 and len(col) == nrad + 1 else [col[2 * i] for i in range(nrad)] + [col[-1]]
    if len(edges) != nrad + 1: raise SystemExit("BUILD FAIL: %d boundaries for %d radii" % (len(edges), nrad))
    ih, ioff = inner
    ctype = ih.get("CTYPE", ih.get("CTYPE1", "")).lower()
    r0 = float(ctype.split("within")[1].replace("pc", "").strip())
    print("BUILD map: nside %d, %d radii %.2f–%.2f pc (centres %.2f–%.2f), inner %s pc, units %s" % (
        nside, nrad, edges[0], edges[-1], centres[0], centres[-1], r0, mh.get("CUNIT")))

    # Shells: boundaries nearest in ln r to an even split of the map's range.
    lr0, lr1 = math.log(edges[0]), math.log(edges[-1])
    keep = [0]
    for k in range(1, LAYERS):
        want = lr0 + (lr1 - lr0) * k / LAYERS
        keep.append(min(range(nrad + 1), key=lambda i: abs(math.log(edges[i]) - want)))
    keep.append(nrad)
    shell_of = [0] * nrad
    for k in range(LAYERS):
        for i in range(keep[k], keep[k + 1]): shell_of[i] = k

    # Σ ρ Δr per shell and pixel, one radius (3 MB) at a time.
    acc = [array.array("d", bytes(8 * npix)) for _ in range(LAYERS)]
    with open(src, "rb") as f:
        f.seek(moff)
        for i in range(nrad):
            row = array.array("f", f.read(4 * npix))
            if sys.byteorder == "little": row.byteswap()
            dr = edges[i + 1] - edges[i]
            a = acc[shell_of[i]]
            acc[shell_of[i]] = array.array("d", [x + dr * y for x, y in zip(a, row)])
            if i % 64 == 0: print("BUILD radius %d/%d" % (i, nrad), flush=True)
    with open(src, "rb") as f:
        f.seek(ioff)
        a0 = array.array("f", f.read(4 * npix))
        if sys.byteorder == "little": a0.byteswap()
    radii = [r0] + [edges[keep[k + 1]] for k in range(LAYERS)]
    widths = [r0] + [edges[keep[k + 1]] - edges[keep[k]] for k in range(LAYERS)]
    if abs(edges[0] - r0) > 0.5: raise SystemExit("BUILD FAIL: the map starts at %.2f pc, the inner integral ends at %.2f" % (edges[0], r0))
    sheets = [a0] + acc

    # The lookup: SUB × SUB HEALPix pixels across each cell, checked by a round trip.
    for p in range(0, npix, 997):
        z, phi = pix2ang_nest(nside, p)
        if ang2pix_nest(nside, z, phi) != p: raise SystemExit("BUILD FAIL: HEALPix round trip at %d" % p)
    look = array.array("i")
    for j in range(H):
        for s in range(SUB):
            z = 1.0 - 2.0 * (j + (s + 0.5) / SUB) / H
            for i in range(W):
                for t in range(SUB):
                    l = math.radians((i + (t + 0.5) / SUB) * 360.0 / W)
                    look.append(ang2pix_nest(nside, z, l))
    print("BUILD lookup ready", flush=True)

    data = bytearray(W * H * (LAYERS + 1))
    clipped = 0
    n2 = SUB * SUB
    worst = 0.0
    total_src = total_out = 0.0
    tot_cells = [0.0] * (W * H)
    for k, sheet in enumerate(sheets):
        base = k * W * H
        for j in range(H):
            row0 = j * SUB * W * SUB
            for i in range(W):
                s = 0.0
                for u in range(SUB):
                    o = row0 + u * W * SUB + i * SUB
                    for t in range(SUB): s += sheet[look[o + t]]
                e = s / n2
                tot_cells[j * W + i] += e
                rho = e / widths[k]
                q = 0 if rho <= RHO_MIN else int(round(255.0 * math.log(rho / RHO_MIN) / LN_RANGE))
                if q > 255: clipped += 1
                q = min(q, 255)
                data[base + j * W + i] = q
        total_src += sum(sheet) / npix
    # The whole-sky mean of extinction to the edge, before and after the averaging in angle
    # (the cells' areas are equal), and the encoded one.
    total_out = sum(tot_cells) / (W * H)
    enc = 0.0
    for j in range(H):
        for i in range(W):
            s = 0.0
            for k in range(LAYERS + 1):
                q = data[k * W * H + j * W + i]
                # Byte 0 reads back as RHO_MIN, as the shaders decode it.
                s += RHO_MIN * math.exp(LN_RANGE * q / 255.0) * widths[k]
            enc += s
            worst = max(worst, abs(s - tot_cells[j * W + i]) / max(tot_cells[j * W + i], 1e-3))
    enc /= W * H
    print("BUILD mean E to %.0f pc: map %.5f, resampled %.5f, encoded %.5f; worst cell after encoding %.2f %%" % (
        radii[-1], total_src, total_out, enc, worst * 100.0))

    head = b"ASLD" + struct.pack("<4i", VERSION, W, H, LAYERS + 1)
    head += struct.pack("<%df" % (LAYERS + 1), *radii) + struct.pack("<2f", math.log(RHO_MIN), LN_RANGE)
    blob = head + zlib.compress(bytes(data), 9)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    import hashlib
    print("BUILD %d cells clipped at the top byte" % clipped)
    # The deflate stream depends on the zlib that wrote it; the header and payload do not.
    print("BUILD wrote %s: %d bytes, sha256 %s (with this zlib); content sha256 %s; shells to %s pc" % (
        out, len(blob), hashlib.sha256(blob).hexdigest(), hashlib.sha256(head + bytes(data)).hexdigest(), ", ".join("%.1f" % r for r in radii)))


if __name__ == "__main__":
    main()
