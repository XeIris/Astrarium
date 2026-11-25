# The Sky Crane: Mars entry, descent and landing

`skycrane` in `vehicles.gd`, `Guidance.edl_guidance`, `Vessel.contact_altitude`, `Separation`, and `SkyCraneRig`, which draws.
Perseverance's numbers where they are published, MSL's where not, and what is neither is marked an estimate.

## Sources

| Source | Read | Used for |
| --- | --- | --- |
| [NASA PIA13282](https://science.nasa.gov/photojournal/final-minutes-of-curiositys-arrival-at-mars), Curiosity's timeline (an example case) | in full | the backshell at 1.8 km and 100 m/s; half the engines off as the cords spool; rover separation at about 20 m with about 12 s to go; 0.75 m/s |
| [Perseverance's landing press kit](https://www.jpl.nasa.gov/news/press_kits/mars_2020/landing/mission/) | read | parachute 21.5 m, heat shield 20 s after it, backshell at 2.1 km and 85 m/s, touchdown moved by up to 600 m, 7.6 m of cord |
| [Spaceflight Now's Perseverance timeline](https://spaceflightnow.com/2021/02/18/what-to-expect-during-perseverances-landing-on-mars/) | read | backshell at entry + 5:50, touchdown at + 6:50 |
| [Huang et al. 2022](https://doi.org/10.1007/s42064-021-0118-9), Tianwen-1's powered descent | its guidance and flight-result sections | a free fall of about 1 s before ignition; why the divert leaves the shell's plane; the quadratic guidance law; MSL's and Mars 2020's 300 m out-of-plane divert (their citation) |
| Sell et al. 2014 ([10.2514/1.A32682](https://doi.org/10.2514/1.A32682)); AAS 13-307 | **abstract or search excerpt only**: NTRS and CORE refused automated fetches | 300 m divert, 85 → 0.75 m/s, 7.5 m bridle; vertical flight at about 32 m/s; rover separation at about 18.6 m |
| [Sky crane (Wikipedia)](https://en.wikipedia.org/wiki/Sky_crane_(landing_system)) | read | the wheels coming into place as the cables unreel; the crash 650 m off |

## The sequence

1. **Parachute** at Mach 1.7, and the survey of the ground below.
2. **Heat shield** 20 s later, with its 385 kg (`jettison_shield`).
3. **Backshell** at 2.1 km. It stays on the parachute and the descent stage drops out below.
4. **Free fall** for 1 s, unpowered.
5. **Divert**: out of the shell's plane by 300–600 m, to the flattest ground the survey shows there.
6. **Vertical descent**, at most 32 m/s, slowing to 0.75 m/s.
7. **Sky crane** with the descent stage 18.6 m up: four of eight engines off, the bridle paid out to 7.5 m.
8. **Touchdown**, the cut a second later, the flyaway (drawn, not flown).

## Why the shell goes up

A dropped stage leaves at the difference of the non-gravitational accelerations (`Separation`). A spent booster has
nearly none, so a stack under thrust leaves it behind. Here the shell has the parachute. With CdA = 225 m², ρ ≈ 0.014
kg/m³ at 2.1 km, u = 76 m/s and a 215 kg shell:

    a = ½ρu²·CdA / m = 0.5 · 0.014 · 76² · 225 / 215 ≈ 42 m/s²

The descent stage free-falls with almost no drag of its own, so over the 1 s before ignition the shell gains about
½·42·1² ≈ 21 m, less as it slows. The flown value is 16 m, against a 4.5 m aeroshell. `look.sep.canopy` adds that
drag, taken implicitly, since the shell slows in under a second.

## Why the divert is out of plane

The freed shell flies on in the plane of the old trajectory, so it comes down near where the stack was going. Huang et al.
keep the lander 200 m from that line; MSL and Mars 2020 flew 300 m. Candidates lie 300 m or more to either side of the
plane, as far as the engines can carry her in the time to go, and never past 600 m:

    t_go = 2 (h − h₁) / (|v_z| + 32),   reach = 0.45 a_max t_go² / 6

Of those, the one whose ground varies least over a 10 m cross. That stands in for Perseverance's map of hazards; rocks
are drawn only, so they do not count. The law is a = 6Δr/t² − (4v + 2v_f)/t, Huang et al.'s without its terminal acceleration.

## Why the sky crane takes 12 s

With the descent stage 18.6 m up, her stowed wheels are 1.30 m below it, at 17.3 m. The bridle takes 7.5 m of that and the
stage's own descent the rest:

    (17.3 − 7.5) / 0.75 ≈ 13 s

The vessel's reference is the stack's, so `contact_altitude` is the wheels': alt + 1.05 − bridle. After the cut the
reference comes down to her and her wheels stay where they are.

## What tests it

`groundcheck`, on a flight from the parachute:

| Test | This model | The record |
| --- | --- | --- |
| Heat shield after the parachute | 20.0 s | 20 s (an input) |
| Free fall | 1.00 s | about 1 s, Tianwen-1 (an input) |
| Backshell, when the engines light | 16.4 m up off the stack, never below it | it stays on the parachute |
| Backshell separation to touchdown | 57.1 s | 60 s |
| Rover separation to touchdown | 12.4 s | about 12 s |
| Out of the shell's plane | 300 m, measured on the ground | 300 m (MSL), at most 600 m (Perseverance) |
| Speed at backshell separation | 76 m/s (not asserted) | 85 m/s |
| Packed clearance | 14 cm over the heat shield, 8 mm inside the backshell | — |

Entered at fourteen longitudes round the equator, thirteen land, at 0.74 m/s and at most 0.01 m/s sideways. The fourteenth flies
into high terrain at 837 m/s before the parachute's Mach: the air over Mars' highlands is too thin for this system.

Estimates: the parachute's Cd (0.62), the payout rate (1 m/s), the 10 m footprint, the heat shield's drag area (15.9 m²), how
far the mobility folds, the 0.45 of the engines held for the divert. The parachute opens at 6.9 km here, against about 11
km: the entry comes in lower than Perseverance's.

Not modelled: terrain-relative navigation (the survey is perfect), the parachute's wrist-mode swing, plume interaction, the
rover's swing on the bridle and its snatch load, touchdown sensing (contact is), and the flyaway's dynamics.
