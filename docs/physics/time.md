# Dates and time scales

A preset with an `epochJD` reads a date instead of elapsed years: the orrery's clock
and the flight panel's coordinate clock show UTC and TDB (`sim/timescales.gd`). The
solar preset starts at J2000.0, 2000 January 1 12:00 TDB (JD 2451545.0), which is
11:58:55.816 UTC.

## The chain

- **TDB.** The orrery integrates in barycentric coordinates, so its time is
  barycentric dynamical time: TDB = epoch + sim_years orrery years. An orrery year is
  2π√(AU³/GM☉) = 365.256 898 d (`Rocketry.YR_S`), the period in which G = 4π².
- **TT.** TDB − TT = 0.001 657 s·sin g + 0.000 014 s·sin 2g, with g the Earth–Moon
  barycentre's mean anomaly, 357.53° + 0.985 600 28°·(JD − 2451545.0) (USNO Circular
  179, eq. 2.6). That is good to ~10 μs; the full Fairhead–Bretagnon series is not
  needed for a display.
- **TAI.** TT − 32.184 s.
- **UTC.** TAI − ΔAT, from the IERS leap-second table (Bulletin C 70): 10 s from 1972
  to 37 s since 2017 January 1. Before 1972 UTC ran on rubber seconds and only TDB is
  shown. After the table the last offset holds, since no further leap second has been
  announced.

Calendar dates follow Meeus (Astronomical Algorithms, ch. 7): Gregorian from 1582
October 15, Julian before, with astronomical year numbering.

## Checks

`tools/sciencecheck.gd` holds J2000.0 at 11:58:55.816 UTC, TDB − TT within its
1.7 ms amplitude, the 2016 leap second, the absence of UTC before 1972, the
Gregorian reform's ten missing days, and one orrery year of TDB per unit of
`sim_years`.
