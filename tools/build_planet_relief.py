#!/usr/bin/env python3
"""Build assets/planet-relief/<world>.elev, the measured height of Earth, Mars and the Moon.

    python tools/build_planet_relief.py path/to/dem_dir

dem_dir holds (needs numpy and h5py):
  ETOPO_2022_v1_60s_N90W180_surface.nc  NOAA NCEI, ETOPO 2022 60" ice surface, metres above
      sea level (https://www.ngdc.noaa.gov/thredds/catalog/global/ETOPO2022/60s/catalog.html)
  megt90n000cb.img  MGS MOLA MEGDR, 4 per degree, metres above the areoid
      (https://pds-geosciences.wustl.edu/mgs/mgs-m-mola-5-megdr-l3-v1/mgsl_300x/meg004/)
  ldem_4.img  LRO LOLA LDEM, 4 per degree, half-metres above the 1737.4 km sphere
      (https://pds-geosciences.wustl.edu/lro/lro-l-lola-3-rdr-v1/lrolol_1xxx/data/lola_gdr/cylindrical/img/)

Terms and credits are in THIRD_PARTY.md.

Output, little-endian: magic "ASEL", int32 width, int32 height, then width × height int16
metres, row by row from north to south, each from 180° W eastward. A cell is the mean (ETOPO)
or the median (MOLA, LOLA, as their labels say) over its quarter degree, centred on it.
"""
import struct
import sys
from pathlib import Path

import numpy as np

OUT = Path(__file__).resolve().parent.parent / "assets" / "planet-relief"
W, H = 1440, 720


def etopo(folder):
    import h5py
    with h5py.File(folder / "ETOPO_2022_v1_60s_N90W180_surface.nc", "r") as f:
        z = f["z"][:].astype(np.float64)
        lat = f["lat"][:]
        lon = f["lon"][:]
    if z.shape != (10800, 21600) or not (lon[0] < lon[1]):
        sys.exit(f"build_planet_relief: unexpected ETOPO grid {z.shape}")
    if lat[0] < lat[-1]:
        z = z[::-1]
    # 60" cells in 15 × 15 blocks: the quarter degree's mean.
    return z.reshape(H, 15, W, 15).mean(axis=(1, 3))


def pds(path, dtype, scale):
    raw = np.fromfile(path, dtype=dtype)
    if raw.size != W * H:
        sys.exit(f"build_planet_relief: {path.name} holds {raw.size} samples, not {W * H}")
    # Both start at 0° E; this layout starts at 180° W.
    return np.roll(raw.reshape(H, W).astype(np.float64) * scale, W // 2, axis=1)


def write(name, h):
    if not np.isfinite(h).all() or np.abs(h).max() > 32000:
        sys.exit(f"build_planet_relief: bad heights for {name}: {h.min()}..{h.max()}")
    data = b"ASEL" + struct.pack("<ii", W, H) + np.rint(h).astype("<i2").tobytes()
    (OUT / f"{name}.elev").write_bytes(data)
    weight = np.cos(np.radians(90.0 - (np.arange(H) + 0.5) / 4.0))[:, None] * np.ones((1, W))
    print(f"{name}: {h.min():.0f}..{h.max():.0f} m, area mean {np.average(h, weights=weight):.0f} m, "
          f"{len(data)} bytes")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    folder = Path(sys.argv[1])
    OUT.mkdir(parents=True, exist_ok=True)
    write("earth", etopo(folder))
    write("mars", pds(folder / "megt90n000cb.img", ">i2", 1.0))
    write("moon", pds(folder / "ldem_4.img", "<i2", 0.5))
    print(f"build_planet_relief: 3 worlds -> {OUT}")


if __name__ == "__main__":
    main()
