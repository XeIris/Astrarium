# The Observatory: the sky from a site on a date

Code: `sim/observatory/` (`earthframe.gd`, `lunar.gd`, `observatory.gd`, `sites.gd`,
`constellation_overlay.gd`, and the generated `deltat.gd` and `nutation2000b.gd`).
Check: `tools/observatorycheck.gd`.

The Observatory mode is the `solar` preset seen from the ground. It sets a civil date,
stands the camera on Earth's WGS-84 surface at a site, and turns the observer with
Earth's true orientation on that date. Everything in the sky (Sun, Moon, planets,
catalogue stars, the procedural sky, the constellation overlay) stays in the
orrery's J2000 frame; only the observer moves. Seasons and which stars are up follow
from the date and the site.

## From a civil date to the sky

1. **Civil time to TT.** From 1972 the date is UTC and TT = UTC + ΔAT + 32.184 s
   (`TimeScales.LEAPS`, whose last offset holds after it). Before 1972 the date is
   UT1 (UTC did not exist in its present form) and TT = UT1 + ΔT. TDB adds the
   periodic terms of [time.md](time.md).
2. **The Solar System on the date** (`Observatory.solar_state`, `main.restate_solar`).
   Planets and the Earth–Moon barycentre come from the solar preset's own builder, JPL's
   mean elements (Standish, table 1). The Moon's offset from Earth is
   `LunarTheory.position`: the leading terms of ELP-2000/82 as Meeus truncates them
   (25 terms in longitude and distance, 15 in latitude, and the A1–A3 terms), in the
   ecliptic of date, carried to J2000 by the IAU 2006 precession; its velocity is a
   ±30 min central difference. The mean elements alone leave out evection,
   variation and the annual equation and are 0.5°–2.2° off; this is 0.007° rms. The
   clock then runs the orrery's N-body integration (1PN, Yoshida) from that state.
   Setting a date is a new epoch, so `sim_years` is assigned and its compensated
   remainder restarts (AGENTS.md).
3. **Earth's orientation** (`EarthFrame.site`). The GCRS → true-of-date matrix is
   the IAU 2006 Fukushima–Williams precession angles (γ̄, φ̄, ψ̄, frame bias included)
   with IAU 2000B nutation added to ψ and ε (SOFA's `iauPfw06`, `iauFw2m`, `iauNut00b`).
   Greenwich apparent sidereal time is the IAU 2006 GMST (`iauGmst06`, from the Earth
   rotation angle at UT1 = TT − ΔT) plus the equation of the equinoxes, Δψ cos ε_A and
   its two largest complementary terms (2.64 mas sin Ω, 0.06 mas sin 2Ω). Polar motion
   (≲ 0.3″) is ignored.
4. **The site.** The geodetic point (`Rocketry.geodetic_point` on WGS-84) at the local
   apparent sidereal angle gives the eye; the ellipsoid's normal is the zenith,
   north is along the meridian. All three go to GCRS through the transpose of step
   3's matrix, then to orrery axes. The camera stands at Earth's position plus that
   offset in true scale, so the Moon's ~1° topocentric parallax is real.
5. **The stars.** Each catalogue star moves along a great circle at its proper motion
   from its catalogue epoch (BSC5: FK5 J2000; Gaia DR3: 2016.0) to the date
   (`EarthFrame.proper_motion`, `BrightStars.set_epoch`). Linear proper motion is good
   over centuries; over millennia a nearby star's motion is not linear (perspective
   acceleration needs a radial velocity, which is not applied).

Annual aberration (≤ 20″) and light deflection are not applied to the drawn sky:
at the Observatory's fields of view a pixel is 100″–250″.

## ΔT

ΔT = TT − UT1 (`EarthFrame.delta_t`):

- **Measured** (1657 to the table's end, 2026.75 at build time): the USNO's tables
  (`tools/build_deltat.py`): `historic_deltat.data` half-yearly to 1973.0 with its
  standard errors, then `deltat.data` monthly, interpolated linearly.
- **Outside the table**: the Espenak & Meeus polynomials (NASA's Five Millennium
  Canon) with the 2005–3000 pieces of the 2014 EclipseWise update, shifted to meet the
  table at its nearest end, so ΔT(y) = ΔT_last + P(y) − P(y_last). At 2126.0 this is
  153.8 s.
- **Its 1σ** (`delta_t_sigma`): the table's own inside it; after it, Huber's random
  walk in the length of day from the last measurement,
  σ = 365.25 n √(n Q/3 (1 + n/2500)) / 1000 s with Q = 0.058 ms²/yr and n years past
  the table, the model NASA's uncertainty table uses (it gives 612 s at 2500 and
  1885 s at 3000 from a 2005 calibration); before the table, NASA's values (431 s at
  −500, Huber's walk beyond).

A ΔT error turns the whole sky by 15″ per second of time. At 2126 the forecast σ is
51 s, so the sky's rotation is uncertain by about 13′.

## The date range and its badge

The years 1926 to 2126 are supported (the present ± 100 years, issue 23). The badge
under the date reads:

| badge | when | says |
|---|---|---|
| Measured | inside the range and the ΔT table | the sources of the sky's orientation |
| Extrapolated | inside the range, after the ΔT table | ΔT is a forecast, its σ and the angle the sky may be turned by |
| Heavy approximation | outside 1926–2126 | the dominant error: Earth's rotation (ΔT σ and the angle), then that the planets' mean elements are fitted to 1800–2050 and that proper motion is linear |

Today is "Extrapolated" until the table is rebuilt: the USNO's monthly ΔT ends a
month or two behind the present.

## Error budget inside the range

| source | model | measured or stated error, 1926–2126 |
|---|---|---|
| precession and nutation | IAU 2006 + IAU 2000B | ≈ 1 mas (IAU 2000B's own accuracy); the SOFA test vectors are reproduced to 1e-12 rad |
| Earth rotation | measured ΔT, then forecast | ≈ 0.1 s (1.5″) measured; 51 s (13′) at 2126 |
| star places | BSC5 / Gaia DR3 + linear proper motion | Barnard's Star moves 10.4″/yr; linear motion is good to well under 1″ over the range |
| Sun | mean elements | ≤ 0.003° against Horizons |
| Moon | truncated ELP-2000/82 | 0.007° rms, 0.023° worst over 41 dates; ≤ 0.005° at the three epochs below |
| planets | JPL mean elements, table 1 | Mercury–Mars ≤ 0.002°; Jupiter 0.14°, Saturn 0.47°, Uranus 0.15° by 2126 (table 1 is fitted to 1800–2050 and has no great inequality) |

## Constellations

`assets/sky/constellations.json`, built by `tools/build_constellations.py`:

- **Stick figures** are this project's own, written in the builder as chains of
  Bayer, Flamsteed or HR designations and resolved in BSC5 (88 constellations, 542
  segments). They carry each star's proper motion, so the figures move with the
  stars.
- **Boundaries** are the IAU's (Delporte 1930), as CDS catalogue VI/49 (Davenhall &
  Leggett 1989) gives them precessed to J2000, taken from d3-celestial's GeoJSON
  copy (BSD-3). Their edges are arcs of B1875 parallels and meridians, so each edge is
  filled at ≤ 1° steps in the B1875 frame (IAU 1976 precession) and carried back; a
  straight J2000 great circle would bow off a long parallel by up to a degree near the
  poles. Boundaries are fixed to the sky and do not move with the stars.
- **Names** sit at the mean direction of each boundary polygon (Serpens has two).

The overlay is drawn in screen space over the frame, cut at the horizon.

## Sites

| site | latitude, longitude, height | source |
|---|---|---|
| Jodrell Bank (Lovell Telescope) | 53°14′10.50″ N, 2°18′25.74″ W, 80 m | JBO "Lovell Telescope facts and figures"; the page gives no height, 80 m is the ground level issue 23 quotes |
| Mauna Kea (Keck) | 19°49′35″ N, 155°28′28″ W, 4145 m | Wikidata Q210997 (Keck's telescope page was unreachable) |
| Cerro Paranal (VLT UT1) | 24°37′39.44″ S, 70°24′18.27″ W, 2635.43 m | ESO, Paranal astroclimate site page |

A custom site takes any latitude, longitude and height on WGS-84.

## Checks

`tools/observatorycheck.gd` (headless, in the fast suite):

- the IAU SOFA test vectors (t_sofa_c.c) for `iauObl06`, `iauPfw06`, `iauNut00b`,
  `iauEra00` and `iauGmst06`;
- ΔT continuous where the table and the polynomials meet, the USNO's own values at
  1926.0 (23.95 s) and 2000 Jan 1 (63.8285 s), Huber's walk against NASA's table,
  the badges at the range's edges, and civil time ↔ TT round trips in both eras;
- Polaris: the middle of its daily altitude range equals each site's latitude to
  0.01° in 1926, 2026 and 2126;
- the noon Sun at the 2026 solstices (USNO "Earth's Seasons"): 90° − |φ ∓ ε| to
  0.02° at all three sites;
- Sirius's rise, transit and set at all three sites: 1926 Jan 1 and 2050 Dec 31
  against the USNO's rise/set/transit service (printed to the minute; worst 0.68 min,
  in 2050, where the USNO's own ΔT forecast enters), and 2126 Jan 1 against IAU SOFA
  through pyerfa with the same ΔT (`tools/observatory_ref.py`; worst 2 s);
- the Sun, Moon and planets against JPL Horizons (DE441, geometric geocentric) at
  1926, 2000 and 2126, with the limits set just above the errors in the table above.
