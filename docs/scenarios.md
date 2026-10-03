# Scenario design notes

Code: `sim/presets.gd`, `sim/edupresets.gd`. [web/README.md](../web/README.md)
describes the scenarios for readers; this file keeps the design constraints and
measurements behind them.

## Trisolaris (hierarchical initial conditions)

Close stellar encounters can disrupt a planetary orbit, so the flagship starts
with a hierarchy:

- Alpha (1.20 M☉, F) and Beta (0.85 M☉, K): a 0.35 AU pair, 53-day period.
- Trisolaris orbits both at 1.80 AU, e = 0.42: circumbinary (P-type), outside
  the Holman–Wiegert limit (a_crit ≈ 2.3 a_bin ≈ 0.8 AU).
- Gamma (2.00 M☉, A, 11 L☉): a 51-year orbit at 25° around the whole system.

The standing long-run target is 60 000 years, but the current native-kernel
trajectory fails the declared inner-orbit bound near 18 095 years and later
ejects the world, despite relative energy drift below 5.3e-8. The earlier
60 000-year stability claim is not supported by this recheck; see R28 in the
[review log](codebase-review-2026-10-02.md). Earlier insolation samples swung
~9× (0.34 to 3.1 Earth-suns); these climate statistics have not been revalidated
as an ensemble against the current kernel.

The 2026-10-04 timestep probes keep the authored frame interval and observation
cadence, with unchanged bounds. All request 60 000 years:

| maximum step (years) | world orientation offset (radians) | first sampled extent failure (years) | maximum relative energy drift |
|---:|---:|---:|---:|
| 0.0004 | 0 | 18 095 | 5.26e-8 |
| 0.0002 | 0 | 8 482 | 1.04e-8 |
| 0.0001 | 0 | none through 60 000 | 2.49e-9 |
| 0.00005 | 0 | 12 460 | 6.19e-10 |
| 0.0004 | +1e-6 | 27 224 | 5.21e-8 |
| 0.0004 | −1e-6 | 14 578 | 5.17e-8 |

One passing refinement amid failures does not establish convergence. The tiny
world-orientation probes rotate position and velocity relative to the inner
binary barycenter; they change apsidal orientation, not anomaly along the same
ellipse. No authored timestep or orbit was changed to obtain a passing gate.
These six trajectories are not a statistical stability ensemble.

Run the strict authored gate with `python3 tools/check.py stability`. For a
separately marked probe, run Godot headlessly with
`--script res://tools/stabilitycheck.gd -- max_step=0.0002 report=/abs/result.json`;
`world_rotation=0.000001` selects the orientation perturbation. A diagnostic
cannot satisfy the runner's baseline completion marker. Reports keep decimal
states plus versioned binary64 hex, with the field order and byte order stated
in the report. The binary encoding preserves exact doubles independently of
decimal-parser rounding. Extent is sampled every 1 000 frames (about 5.83 years),
so the recorded time is the first observed violation, not an exact event time.

## Wandering suns (`trisolaris_wander`)

Built for the sky rather than stability: a 2+2 hierarchy parked just inside
the region where encounters go chaotic.

    Alpha  0.58 M☉  K5, 4163 K   home sun, 0.34 AU: an orange disc twice the Sun's width
    Beta   1.25 M☉  F5, 6770 K   a 0.45 AU pair (78 days) on one wide e = 0.50 orbit,
    Gamma  0.78 M☉  K2, 4973 K   inclined 22° to the world's

The pair's periapsis is 1.68 AU, five times the world's orbit. Every 3.8 years
a passage kicks the world's orbit, and near the Mardling–Aarseth boundary the
kicks compound rather than average out. The inclination is below the ~39.2°
Kozai–Lidov angle: it doesn't drive the chaos, it keeps the suns from tracing
one repeated line.

`qRatio` = q₂/a_P is the one knob. Below ~4 the world is stripped within decades.
Above ~6 the system relaxes and the sky becomes predictable (in a grid scan the
one-sun fraction climbs from 21% to over 70%).

Measured over a 24-run ensemble at the preset's step cap (75 203 samples),
counting suns showing a disc at least a quarter of the Sun's apparent width:

| suns showing a disc | fraction |
|---|---|
| none | 3% |
| one | 21% (a Stable Era) |
| two | 44% |
| three | 32% (a tri-solar day) |

The flagship preset gives 0 / 0 / 100 / 0. Insolation runs 0.64 (5th percentile)
to 3.68 (95th), 7.8 at the 99th, and is in the liquid-water band 91% of the time.

The Lyapunov time is of order an orbital period, so a run is set by rounding
after a few decades and can't reproduce these numbers shot for shot; only
ensemble statistics mean anything. The world lives a median of 382 years
(92 to 3437) and always ends: 14 of 24 runs ejected it, 10 fed it to a star's
Roche limit. The step cap is 3e-4: worst-case drift 6e-5 over 1500 years and
5.3e-4 across the ensemble. Halving the cap changes neither lifetimes nor sky
statistics.

These presets use the real destruction distance, not the drawn radius (drawn,
it is 3.5–3.7× the photosphere and ~2× the Roche limit, 9× and 7× at the
flagship's scale). It decides which close passes the world survives.
