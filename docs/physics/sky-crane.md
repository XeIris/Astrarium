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
| [Saranathan 2024](https://arxiv.org/abs/2412.07960), an MSL-like mission | its vehicle and trajectory sections | the masses: 3152 kg at entry, 150 of ballast, 385 of heat shield, 2617 under the parachute, 2268 at powered descent |
| MSL's parachute reconstruction ([10.2514/1.A32816](https://doi.org/10.2514/1.A32816)); a review of Mars entry guidance | **search excerpts only** | a drag coefficient of 0.624–0.636 below Mach 0.6; range control ending below 1100 m/s |
| [JPL Robotics, terrain-relative navigation](https://www-robotics.jpl.nasa.gov/what-we-do/flight-projects/mars-2020-rover/terrain-relative-navigation/) | read | a position error under 40 m; Perseverance down within 5 m of its target |
| [The Planetary Society](https://www.planetary.org/articles/0804-from-space-plane-to-sky-crane), and reports of Curiosity's crash plume | **search excerpts only** | the descent stage down 650 m off (others say 800 m), about 20 s after the release |
| [Sky crane (Wikipedia)](https://en.wikipedia.org/wiki/Sky_crane_(landing_system)) | read | the wheels coming into place as the cables unreel; the crash 650 m off |

## The sequence

1. **Entry**, its lift banked 49°, then mostly up (15°) below 1100 m/s.
2. **Parachute** at 420 m/s, the balance masses going with it, and the survey of the ground below. **Heat shield** 20 s
   later, with its 385 kg (`jettison_shield`).
3. **Backshell** at 2.1 km. It stays on the parachute and the descent stage drops out below.
4. **Free fall** for 1 s, unpowered.
5. **Divert**: out of the shell's plane by 300–600 m, to the flattest, least rocky spot on the landing map.
6. **Vertical descent**, at most 32 m/s, slowing to 0.75 m/s.
7. **Sky crane** with the descent stage 18.6 m up: four of eight engines off, the bridle paid out to 7.5 m.
8. **Touchdown**, the cut a second later, the flyaway.

## Why the shell goes up

A dropped stage leaves at the difference of the non-gravitational accelerations (`Separation`). A spent booster has
nearly none, so a stack under thrust leaves it behind. Here the shell has the parachute. With CdA = 225 m², ρ ≈ 0.013
kg/m³ at 2.1 km, u = 81 m/s and 349 kg of backshell and parachute:

    a = ½ρu²·CdA / m = 0.5 · 0.013 · 81² · 225 / 349 ≈ 27 m/s²

The descent stage free-falls with almost no drag of its own, so over the 1 s before ignition the shell gains about
½·27·1² ≈ 14 m, less as it slows. The flown value is 12 m, against a 4.5 m aeroshell. `look.sep.canopy` adds that
drag, taken implicitly, since the shell slows in under a second. A shell staged by hand before its parachute opened has
none; one staged under it takes the parachute with it, and the descent stage flies on its engines.

## Why the divert is out of plane

The freed shell flies on in the plane of the old trajectory, so it comes down near where the stack was going. Huang et al.
keep the lander 200 m from that line; MSL and Mars 2020 flew 300 m. Candidates lie 300 m or more to either side of the
plane, as far as the engines can carry her in the time to go, and never past 600 m:

    t_go = 2 (h − h₁) / (|v_z| + 32),   reach = 0.45 a_max t_go² / 6

Of those, the 24 whose ground varies least over a 26 m cross, and of those the one with least rock: each rock of a metre
or more within 13 m counts against what she can stand over (0.6 m), the relief against a 25° slope. They are the rocks `SiteRocks` draws there, from the same
generator; a map from orbit (HiRISE, 0.3 m a pixel) shows none smaller. Rocks are still not met by a wheel. Her
position on that map is out by up to 40 m (JPL's requirement, taken as 3σ), drawn from the run's seed, so she comes
down that far off the spot she picked. Guidance itself is within 1 m of where it aims. The law is a = 6Δr/t² − (4v + 2v_f)/t, Huang et al.'s without its terminal acceleration.

## Why the sky crane takes 12 s

With the descent stage 18.6 m up, her stowed wheels are 1.30 m below it, at 17.3 m. The bridle takes 7.5 m of that and the
stage's own descent the rest:

    (17.3 − 7.5) / 0.75 ≈ 13 s

The vessel's reference is the stack's, so `contact_altitude` is the wheels': alt + 1.05 − bridle. At the cut the
descent stage leaves the vessel with its engines and propellant, and the reference comes down to her, her wheels staying
where they are. The bridle out at touchdown (`landed_at.bridle`) is where the stage flies off from. The program engaged
again part way down goes on from where the vehicle is in its sequence.

## The entry

The vehicle is Saranathan's to a kilogram (`groundcheck`: 3153, 2618 and 2269 kg against 3152, 2617 and 2268).
The 60° bank the old entry held opened the parachute at 5.1 km over the datum on those masses. Turning the lift up below 1100 m/s
and opening at Perseverance's 420 m/s raises it to 8.0 km. The range-control bank is then set so that it opens at
her published entry + 240 s (49°; a constant bank standing in for range control's modulation). The altitude follows:
9.2 km over the datum. Hers was about 11 km over Jezero, whose floor is some 2.6 km below the datum, so about 8.4.

## The flyaway

`CraneFlyaway`: the stage's remaining mass and engines, under gravity and a little drag, stepped on the flight's clock
to where it meets the drawn ground. It climbs for 2.5 s, pitches over 57° holding its height, burns until 16 s after the cut, and
falls. The pitch and the burn are set against two reports of Curiosity's, 650 m and about 20 s after the release; what
it carries is not adjusted. On falling ground it goes further (775 m where the site drops 45 m). Down, it turns with the
planet, and its smoke rises from there on the flight's clock: drawn puffs, whose rise and spread are estimates. It reads
the vessel and the ground and acts on neither.

## What tests it

`groundcheck`, on a flight from the parachute:

| Test | This model | The record |
| --- | --- | --- |
| Heat shield after the parachute | 20.0 s | 20 s (an input) |
| Free fall | 1.00 s | about 1 s, Tianwen-1 (an input) |
| Parachute after entry | 241 s (calibrated) | 240 s |
| Parachute's altitude over the datum | 9.2 km | about 8.4 km |
| Speed at backshell separation | 80.9 m/s | 85 m/s |
| Backshell, when the engines light | 12.4 m up off the stack, never below it | it stays on the parachute |
| Backshell separation to touchdown | 54.9 s | 60 s |
| Rover separation to touchdown | 12.3 s | about 12 s |
| Out of the shell's plane | 298 m, measured on the ground | 300 m (MSL), at most 600 m (Perseverance) |
| Off the spot she picked | 20.8 m, her map position out by 20.8 m | under 40 m (requirement); 5 m flown |
| Metre rocks about that spot | 0, where 39 of 60 others nearby have some | — |
| The descent stage's crash | 607 m, 20.0 s after the cut (calibrated) | 650 m, about 20 s |
| Packed clearance | 14 cm over the heat shield, 2 mm inside the backshell's facets | — |

Entered at fourteen longitudes round the equator, thirteen land, at 0.74 m/s and at most 0.01 m/s sideways. The fourteenth flies
into high terrain at 837 m/s before the parachute's Mach: the air over Mars' highlands is too thin for this system.

What is left of the 5% in the separation speed is the air: one isothermal 210 K Mars, all year. Nearer Jezero's
floor its denser air slows the stack further (73.9 m/s at a site 3 km below the datum).

Estimates: the payout rate (1 m/s), the 15° of heading alignment, the heat shield's drag area (15.9 m²), how far the mobility
folds, the 0.45 of the engines held for the divert, the 25° slope a spot is judged against, the flyaway's climb and drag area.

Not modelled: range control's bank reversals, the image matching behind terrain-relative navigation (only its error), the
parachute's wrist-mode swing, plume interaction, the rover's swing on the bridle and its snatch load, touchdown sensing
(contact is), and a landing at Jezero on the day.
