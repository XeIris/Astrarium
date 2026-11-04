#!/usr/bin/env python3
"""Build assets/sites/<site>.terrain, a small height tile round each observing site.

    python tools/build_site_terrain.py path/to/dem_dir

dem_dir holds Copernicus GLO-30 Public tiles (Copernicus_DSM_COG_10_*_DEM.tif, from
https://registry.opendata.aws/copernicus-dem/; needs numpy, tifffile and imagecodecs).
Each site gets two square grids on the tangent plane about its datum: a near one at
the DEM's own 30 m and a far one that reaches to where the planet's ground patch takes
over. A surface model: trees and buildings are in it, so sim/observatory/site_scene.gd
levels each facility's footprint.

Produced using Copernicus WorldDEM-30 © DLR e.V. 2010-2014 and © Airbus Defence and
Space GmbH 2014-2018 provided under COPERNICUS by the European Union and ESA; all
rights reserved.

Output, little-endian: magic "ASTE", then for each of the two grids int32 n and
float32 half-width (m), then n × n uint16 of (height + 100 m) × 10, row by row from
south to north, each from west to east.
"""
import glob
import math
import os
import struct
import sys
from pathlib import Path

import numpy as np
import tifffile

OUT = Path(__file__).resolve().parent.parent / "assets" / "sites"
# Datums as in sim/observatory/sites.gd. Jodrell Bank's far grid stops at its tile's
# edge: the Cheshire plain needs no more.
SITES = {
    "jodrell": (53 + 14 / 60 + 10.50 / 3600, -(2 + 18 / 60 + 25.74 / 3600), 20000.0),
    "maunakea": (19 + 49 / 60 + 35 / 3600, -(155 + 28 / 60 + 28 / 3600), 40000.0),
    "paranal": (-(24 + 37 / 60 + 39.44 / 3600), -(70 + 24 / 60 + 18.27 / 3600), 40000.0),
}
NEAR_HALF, NEAR_N, FAR_N = 3000.0, 201, 251


def load_tiles(folder):
    tiles = []
    for path in glob.glob(os.path.join(folder, "Copernicus_DSM_COG_10_*_DEM.tif")):
        p = os.path.basename(path).split("_")
        lat0 = float(p[4][1:]) * (1 if p[4][0] == "N" else -1)
        lon0 = float(p[6][1:]) * (1 if p[6][0] == "E" else -1)
        tiles.append((lat0, lon0, tifffile.imread(path)))
    if not tiles:
        sys.exit(f"build_site_terrain: no tiles in {folder}")
    return tiles


def sample(tiles, lat, lon):
    """Bilinear height at arrays lat, lon (°). Pixels are centred on their grid corner;
    the first row is the tile's north edge. Absent tiles are ocean, height 0."""
    out = np.zeros(lat.shape)
    for lat0, lon0, h in tiles:
        rows, cols = h.shape
        fy = (lat0 + 1.0 - lat) * rows
        fx = (lon - lon0) * cols
        inside = (fy >= 0) & (fy < rows - 1) & (fx >= 0) & (fx < cols - 1)
        y0, x0 = fy[inside].astype(int), fx[inside].astype(int)
        ty, tx = fy[inside] - y0, fx[inside] - x0
        out[inside] = (h[y0, x0] * (1 - tx) * (1 - ty) + h[y0, x0 + 1] * tx * (1 - ty)
                       + h[y0 + 1, x0] * (1 - tx) * ty + h[y0 + 1, x0 + 1] * tx * ty)
    return out


def grid(tiles, lat, lon, half, n):
    # WGS-84 radii of curvature at the datum: metres per radian of latitude and longitude.
    a, e2 = 6378137.0, 0.00669437999014
    w = 1.0 - e2 * math.sin(math.radians(lat)) ** 2
    m_lat = a * (1.0 - e2) / w ** 1.5
    m_lon = a / math.sqrt(w) * math.cos(math.radians(lat))
    axis = np.linspace(-half, half, n)
    east, north = np.meshgrid(axis, axis)
    return sample(tiles, lat + np.degrees(north / m_lat), lon + np.degrees(east / m_lon))


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    tiles = load_tiles(sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    for key, (lat, lon, far_half) in SITES.items():
        data = bytearray(b"ASTE")
        for half, n in ((NEAR_HALF, NEAR_N), (far_half, FAR_N)):
            h = grid(tiles, lat, lon, half, n)
            if not np.isfinite(h).all() or h.max() > 6000.0:
                sys.exit(f"build_site_terrain: bad heights at {key}: {h.min()}..{h.max()}")
            data += struct.pack("<if", n, half)
            data += np.clip(np.rint((h + 100.0) * 10.0), 0, 65535).astype("<u2").tobytes()
            print(f"{key}: ±{half / 1000:.0f} km at {2 * half / (n - 1):.0f} m, "
                  f"{h.min():.0f}..{h.max():.0f} m, centre {h[n // 2, n // 2]:.1f} m")
        (OUT / f"{key}.terrain").write_bytes(bytes(data))
    print(f"build_site_terrain: {len(SITES)} sites -> {OUT}")


if __name__ == "__main__":
    main()
