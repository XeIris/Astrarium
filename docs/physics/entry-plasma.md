# Re-entry plasma

What is drawn is the shock layer, the gas between the bow shock and the skin,
and the wake it sheds. Its brightness and colour come from one number: the
vessel's Sutton–Graves stagnation flux q₀ (`Rocketry.heat_flux`, at the nose
radius `Vessel` uses), the same flux that loads the heat shield. Code:
`Plume.EntryGlow` and `EntryUnit` in `sim/flight/plume.gd`;
`shaders/flight/entry_glow.gdshader`, `entry_wake.gdshader` and
`entry_plasma.gdshaderinc`.

## Units

Each body the air heats on its own is a unit: every stage of the craft, driven
by the stack's flux while it is attached, and each piece handed to `Fall` (the
boosters, the External Tank), driven by its own flux from its own airspeed,
density and diameter. A unit's flow direction is its own velocity through the
turning air, in world axes. A detached stage that is not a `Fall` is dark.

## The layer on the skin

The layer is the vehicle's own skin meshes drawn again as a `material_overlay`:
three shells chained by `next_pass`, pushed out along the normals by 0.6 %,
4.5 % and 12 % of the diameter, and thickened by up to 2.5× toward the
shoulders, where the real standoff grows. Riding the skin, the layer fits every
part, flap and separated piece, and the vehicle's depth hides its own far side.
Decals and nodes with their own shader (frost, plumes) are skipped.

With c = n̂·v̂ the cosine of incidence (v̂ the body's direction through the air):

- the local wall flux is q₀·c², times √(R_ref/R) for the local radius of
  curvature R, estimated from the normal's change across the pixel and clamped
  to 0.6–1.8. At 40° α the belly gets c² ≈ 0.41 of the nose: about the
  radiative-equilibrium ratio of the belly tiles' 1260 °C to the nose cap's
  1650 °C, (1533/1923)⁴ ≈ 0.40. The radius term lifts the nose cap and the wing
  leading edges above the flat belly;
- the gas's radiance climbs faster than the wall flux with the shock's
  strength, so the layer shines as (local flux)^1.5;
- c ≤ 0 is dark: the leeward side and anything facing away from the air;
- so is skin in the body's own lee (Newtonian shadowing): the air meets the
  first surface in its path and nothing behind it. The wake's grid (below)
  keeps, for each column along the flow, the most upstream skin depth; it is
  uploaded as a texture every 0.1 s, and each shell fragment compares its own
  skin point's depth with the four nearest columns. A point more than the
  tolerance behind is sheltered, blended over a second tolerance so the edge is
  soft. The tolerance is the wake's (the larger of 4% of the diameter and
  0.6 cell) plus the depth the point's own surface spans across 1.5 cells,
  1.5 cell·tan θ, so slanted windward skin does not shade itself. The samples
  are sparse, so an empty column with skin on both sides within two cells
  takes the lower of the two and the silhouette does not grow. The orbiter's
  fin and OMS pods, forward-facing but behind the fuselage at 40° α, go dark;
- the local temperature is T₀·(local flux)^¼, where T₀ is the stagnation
  temperature derived from q₀. It sets the brightness code; the colour is the
  layer's spectrum ([below](#the-colour)), shifted to the local temperature;
- a thin glowing layer brightens toward its limb (longer path), and the
  outermost shell fades toward its own silhouette so that no edge line is
  drawn round the vehicle;
- turbulence is value noise stretched along the flow and advected aft.

A blunt body's bow-shock cap is the same layer on its heat shield, which faces
the flow squarely (c ≈ 1). It stands about 0.12 D off the shield and wraps the
shoulder.

## The wake

Gas leaves the skin where the windward surface ends. Every 0.1 s, 1200
area-weighted skin samples are projected along the flow onto a 28×28 grid. A
sample is a departure point when three things hold:

1. it is windward (c ≥ 0.1);
2. it is the first thing the air meets in its grid column, so it is not in the
   lee of the body. This excludes a bump on the leeward fuselage that has the
   belly ahead of it;
3. one and a half cells along the direction the gas runs over the skin (the
   normal's part across the flow), the projection is empty, so the surface ends
   there. This keeps trailing edges, chines and a heat shield's shoulder, and
   rejects leading edges and the middle of the belly.

Departure points are weighted by c². Streaks are drawn from them along the
flow: camera-facing ribbons that widen downstream, flicker, and run aft as
they fade. The wake is cooler and paler than the layer it left, and saturates
with flux: a harder entry gives a longer wake (2.5–8.5 diameters), not a
blinding one.

## Radio blackout

`Ionisation` (`sim/flight/ionisation.gd`) puts equilibrium air behind a normal
shock and counts its free electrons. It applies only to atmospheres with
`radiative: "air"`.

- **Shock.** The Rankine–Hugoniot jump uses Lighthill's ideal dissociating gas for
  N₂ and O₂: θ_d = 113 000 and 59 500 K, ρ_d = 130 and 150 g/cm³ (Vincenti & Kruger
  1965). Its enthalpy is `R[(4 + 2α)T + αθ_d]` per species. The density ratio is
  iterated against the real enthalpy, with T solved by secant.
- **Chemistry.** NO comes from N₂ + O₂ ⇌ 2NO with K = 19.7·e^(−21 720/T) (JANAF
  ΔH and ΔS). It gives 0.8% NO at 2000 K and 5% at 3000 K in air.
- **Ionisation.** Saha's equation, `n_e n₊/n₀ = 2.415 × 10²¹ T^1.5 (2g₊/g₀) e^(−I/kT)`,
  is applied to NO (9.26 eV), N (14.53 eV) and O (13.62 eV). Charge balance is solved
  by Newton's method, and the ionisation energy and the electrons' enthalpy are
  counted in the shock's energy balance.

At lunar-return speed (10.8 km/s at 80 km) the layer reaches 9560 K, near the
~11 000 K of equilibrium-shock tables. For the Shuttle at 7.4 km/s and 80 km it
reaches 5600 K.

S-band (2287.5 MHz, Apollo's and the Shuttle's downlink) is reflected once the
plasma frequency `8.98√n_e` Hz exceeds it, which takes n_e > 6.5 × 10¹⁶ m⁻³. The
vessel solves the shock once a second of MET (0.7 ms per solve). Telemetry carries
`ne` and `blackout`, and the event log records loss and recovery of contact. Along
the Shuttle's entry the model is in blackout from ~100 km at 7.6 km/s down to
~50 km at 3.5 km/s; at Apollo's speeds it is in blackout throughout.

This is the stagnation region's density, an upper bound. The antennas sit on the
afterbody, where the expanded flow is cooler and thinner, so real blackouts start
later and end sooner. The Shuttle's lasted about 12–16 minutes, from around
80 km to about 55 km. The flow is also out of equilibrium above ~70 km. CO₂
atmospheres are outside the model, so Mars and Venus entries read no plasma.

## The colour

`PlasmaSpectrum` gives the layer the colour of its own emission. Once a second of
flight, at the vehicle's altitude and air speed, it solves the gas behind a normal
shock: for air, `Ionisation`'s equilibrium (N₂, O₂, N, O, NO, electrons) plus N₂⁺ by
Saha from that electron density; for CO₂ (Mars, Venus) and N₂–CH₄ (Titan), a small
equilibrium of its own (`PlasmaSpectrum._shock`): CO₂ ⇌ CO + O, CO ⇌ C + O and
Lighthill's N₂ ⇌ 2N carry the energy, against rigid-rotor, fully excited heat
capacities, with JANAF's 298 K ΔH and ΔS in Kp; CH₄ counts as broken into C + 4H; CN
and C₂ follow from C + N ⇌ CN and 2C ⇌ C₂ as traces. Ionisation's energy is left out
of the non-air layers, so above ~9 km/s they run hot. `plasmacheck` holds the jump's
mass, momentum and energy to 2 × 10⁻³.

Each emitter's upper level is populated as Boltzmann gives at the layer's
temperature, n_u = n·(g_u/g₀)·e^(−θ/T), and radiates n_u·A·hν, shared among its
visible lines or band heads:

| gas | emitters |
|---|---|
| air | O I 777 and 845 nm, N I 747–868 nm, N₂⁺ first negative (391, 428 nm), N₂ first positive (580–870 nm), N₂ second positive (316–406 nm) |
| CO₂ | O I, CO Ångström (451–608 nm), CN violet (388, 422 nm) and red (650–920 nm), C₂ Swan (474, 517, 564 nm), N₂ first positive |
| N₂–CH₄ | N I, Hα, N₂⁺, N₂ first and second positive, CN violet and red, C₂ Swan |

plus free–free continuum (Kramers, Gaunt factor 1). Atomic data are NIST's; the band
systems' A and shares are folded from Laux (1993), Lofthus & Krupenie (1977) and
Huber & Herzberg, with vibrational structure lumped into the electronic factor. UV
systems (NO γ and β, O₂ Schumann–Runge, CO fourth positive) are left out because the
eye cannot see them. The spectrum goes through the CIE 1931 functions (the Wyman,
Sloan & Shirley 2013 fit) to linear sRGB; a colour outside the gamut is desaturated
toward white, keeping its hue.

The shader gets each emitter's colour, power and θ. Where the gas is cooler, at
T = T_s·(local flux)^¼, it moves every emitter by e^(θ/T_s − θ/T) with the densities
held at the stagnation point's, and free–free by its electrons' e^(−I/T) as well, so
the shoulders redden. A piece driven by its own flux takes T_s·(q/q_s)^¼.

What comes out:

- a slow entry (4 km/s at 60 km, 3700 K) is N₂ first positive: deep red;
- the Shuttle at 7.4 km/s and 80 km (5600 K) is N₂⁺ first negative and N₂ first
  positive: pink-magenta;
- a lunar return at 10.8 km/s (9600 K) is atomic N and O in the near infrared, which
  the eye barely sees, and N₂⁺'s violet, which it does: blue-violet;
- Mars at 6 km/s (4700 K) and Titan are CN's violet and red systems: magenta.

These are equilibrium colours. Above ~70 km the real layer is out of equilibrium,
with N₂⁺ stronger than this, and ablation products (sodium, carbon from the shield)
are not in it.

## Limits

- No radiative transfer and no ablation products in the gas. The spectrum is the
  equilibrium layer's at the stagnation point.
- Shadowing is Newtonian: a sheltered surface is dark however close it is to
  the shock. Real lee flow is not quite empty (the fin sees a weak expansion
  flow), and the 28-column grid resolves shelter to about 1/28 of the body,
  so a small part near the edge of a shadow is softened rather than cut.
- The curvature estimate is per pixel, so its effect varies with distance from
  the camera. Its clamp keeps the change bounded.
