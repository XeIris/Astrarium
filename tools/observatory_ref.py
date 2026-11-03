#!/usr/bin/env python3
"""Reference rise, transit and set times for observatorycheck where the USNO's
service stops (it covers 1800–2050): the IAU SOFA library through pyerfa.

    python3 -m venv /tmp/v && /tmp/v/bin/pip install pyerfa
    /tmp/v/bin/python tools/observatory_ref.py

Sirius at BSC5's J2000 place and proper motion (as assets/sky/bsc5.bin holds it,
parallax 379.21 mas and −5.5 km/s from Hipparcos), at the three sites, on 2126
January 1 UTC. eraAtco13 gives the topocentric place with no refraction; rise and set
are at a geometric altitude of −34′, as the USNO's are. UT1 − UTC comes from the
same ΔT as the Observatory (the last USNO value, 69.2065 s at 2026.7474, carried by
the EclipseWise 2014 polynomial), since any ΔT for 2126 is a forecast: this end
tests the geometry, not the forecast.
"""
import math

import erfa

SITES = {  # sim/observatory/sites.gd
    "jodrell": (53 + 14 / 60 + 10.50 / 3600, -(2 + 18 / 60 + 25.74 / 3600), 80.0),
    "maunakea": (19 + 49 / 60 + 35 / 3600, -(155 + 28 / 60 + 28 / 3600), 4145.0),
    "paranal": (-(24 + 37 / 60 + 39.44 / 3600), -(70 + 24 / 60 + 18.27 / 3600), 2635.43),
}
RA, DEC, PMRA, PMDEC = 101.28710174560547, -16.716100692749023, -553.0, -1205.0


def delta_t(y):
    poly = lambda x: 67.62 + 0.3645 * (x - 2015) + 0.0039755 * (x - 2015) ** 2
    return 69.2065 + poly(y) - poly(2026.7474)


def place(utc, lat, lon, h):
    tt1, tt2 = erfa.utctai(2400000.5, utc - 2400000.5)
    tt1, tt2 = erfa.taitt(tt1, tt2)
    dut1 = 37.0 + 32.184 - delta_t(2000.0 + (tt1 + tt2 - 2451545.0) / 365.25)
    # μα*/cos δ, in rad/yr of RA, as eraAtco13 takes it.
    pr = math.radians(PMRA / 3.6e6) / math.cos(math.radians(DEC))
    pd = math.radians(PMDEC / 3.6e6)
    aob, zob, hob, dob, rob, _ = erfa.atco13(math.radians(RA), math.radians(DEC), pr, pd, 0.37921, -5.5,
                                             2400000.5, utc - 2400000.5, dut1, math.radians(lon), math.radians(lat), h,
                                             0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
    return 90.0 - math.degrees(zob), math.degrees(hob)


def crossing(f, a, b):
    fa = f(a)
    for _ in range(50):
        m = 0.5 * (a + b)
        if (f(m) > 0) == (fa > 0):
            a, fa = m, f(m)
        else:
            b = m
    return 0.5 * (a + b)


def main():
    day = 2497565.5  # 2126 January 1, 0h UTC
    for key, (lat, lon, h) in SITES.items():
        alt = lambda t: place(t, lat, lon, h)[0] + 34.0 / 60.0
        ha = lambda t: (place(t, lat, lon, h)[1] + 180.0) % 360.0 - 180.0
        steps = [day + i / 1440.0 for i in range(1441)]
        out = {}
        for a, b in zip(steps, steps[1:]):
            if alt(a) < 0 <= alt(b):
                out["rise"] = crossing(alt, a, b)
            if alt(a) >= 0 > alt(b):
                out["set"] = crossing(alt, a, b)
            if ha(a) < 0 <= ha(b) and abs(ha(a)) < 90:
                out["transit"] = crossing(ha, a, b)
        print(key, {k: "%.5f h" % ((v - day) * 24.0) for k, v in sorted(out.items())})


if __name__ == "__main__":
    main()
