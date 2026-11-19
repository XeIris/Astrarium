# How a star's surface is drawn

`sim/star_visual.gd` and the shaders it drives (`star_photo`, `star_corona`,
`prom_volume`, `star_envelope`, `star_noise`) draw a star as the layers an observer
would separate: the photosphere in continuum light, the chromosphere's line emission
over it, the transition region and corona above the limb, the plasma held on the
magnetic field (loops, prominences, flare arcades), and, where a star has one, the
extended atmosphere, wind and dust it is shedding. Each layer is modelled from what is
measured; where a layer is drawn brighter than it is, that is one named constant,
the way bodies are drawn magnified.

## What telescopes see, and what this draws

The pictures people know the Sun from are narrowband and false-coloured. SDO/AIA
304 Å is He II at ~50 000 K (log T ≈ 4.7), formed in the upper chromosphere and
transition region; 171 Å is Fe IX at ~0.6 MK coronal loops; H-α (656 nm) is the
chromosphere at ~10⁴ K. In broadband visible light the Sun is a white,
limb-darkened disc with granulation, spots and faculae, and the chromosphere's line
emission is ~10⁻⁴ of the continuum: you see prominences only at an eclipse or
through a narrowband filter.

The orrery draws the chromosphere at `StarVisual.CHROMO_GAIN` relative to the disc,
and lets it veil `CHROMO_VEIL` of the continuum under it, as an H-α line-centre image
does. That is the one exaggeration. Everything that makes the layer look the way it
does (where it is bright, how it brightens at the limb, what it is made of) follows
the physics below. Stars without a convective envelope have no chromosphere, so they
draw their continuum only.

The continuum is drawn at `DISC_LEVEL` when a chromosphere is drawn over it and at
`DISC_LEVEL_BARE` / b^0.7 when not, where b is the surface brightness of
[structure.md](structure.md#drawn-surface-brightness). Under ACES a dim orange reads
as brown, so a bare disc gives back part of that compression; the stars keep their
order of brightness.

That keeps a hot star's disc under ACES's shoulder, where it keeps its colour and limb,
but leaves bloom almost nothing above its threshold: a 30 000 K disc is drawn only a
few times brighter than the Sun's, where σT⁴ says ~700. So a star brighter than the Sun, the exposure's
reference, draws the rest as glare off its limb (`StarVisual.glare_of`): a 1/θ² wing
whose peak grows with b − 1 and saturates under the bare disc's limb, so the disc stays
the brightest thing drawn, and whose width (40 px as it appears, growing as √(1 + excess))
is in pixels, as a PSF's is. A disc smaller than the wing gets a halo its own size. The
glare is visible light only: in another band the band image's bloom is the PSF.

## The photosphere

Every feature is a local temperature T, drawn through the Planck ratio
B_λ(T)/B_λ(T̄) at the sRGB primaries' effective wavelengths (612, 549, 465 nm). A
spot's colour and contrast are therefore consequences of its temperature, and the
temperature pass publishes the same T, so a spot is dark and a ribbon bright in UV.

- **Granulation.** A granule is drawn as the temperature its measured continuum
  contrast implies at ~600 nm, so the bluer bands show it more. Rms continuum contrast ≈ 16% for the Sun before instrumental
  smearing; Hinode/SP measures 7% at 630 nm and MURaM gives 14–15% until the
  telescope's PSF is applied (Danilovic et al. 2008, A&A 484, L17). Contrast rises
  with Teff and falls with log g (Magic & Asplund 2014, Stagger-grid VI, arXiv:1405.7628),
  and vanishes without a convective envelope (Teff ≳ 7000 K).
  `Stellar.granulation_contrast` is a fit to those trends:
  0.16 (T/5772)² 10^(0.1(4.44 − log g)), clamped to 3–30%.
- **Granule size** is a few pressure scale heights (`Structure.granule_frequency`).
  Two layers are drawn: granules at ten times that frequency over large cells at
  it. On a red supergiant the large cells dominate: a handful of convective cells
  across the disc (Freytag et al. 2002; Chiavassa et al. 2009, A&A 506, 1351;
  π¹ Gru, Paladini et al. 2018, Nature 553, 310; R Dor, Vlemmings et al. 2024,
  Nature 633, 323). On a dwarf they are a faint mesogranular pattern. Each layer
  fades as its cells fall below a pixel.
- **Spots** are bipolar groups on Joy's law: the leading spot equatorward, the axis
  tilted by half the latitude. The umbra's radius is ~0.4 of the penumbra's (Solanki
  2003, A&ARv 11, 153). Penumbral filaments carry outward Evershed grains, umbral dots
  are bright points, and the umbra is sampled through the Wilson depression, so near
  the limb the disc-centre side of the penumbra narrows. The umbral deficit is
  `Stellar.spot_temperature_drop`, ~1850 K on the Sun and a few hundred kelvin on an
  M dwarf (Berdyugina 2005, Living Rev. Sol. Phys. 2, 8). Spot size grows with
  activity, so an active M dwarf's spots cover far more of its disc.
- **Faculae and plage** are hot walls seen obliquely, so they appear toward the limb.
- **Limb darkening** is Claret's (2000) quadratic law per primary; gravity darkening
  is von Zeipel's on the Roche surface (Altair's CHARA image, Monnier et al. 2007,
  Science 317, 342, shows it is if anything stronger than β = ¼).

## The chromosphere on the disc

Drawn where the field is: the network on supergranule boundaries (~30 Mm, about
twenty cells per solar radius), clumped into rosettes and mottles with fibrils
fanning across the cells; plage over active regions, much brighter; superpenumbral
fibrils running radially out of spots; a larger-scale variation of quiet Sun,
enhanced network and coronal-hole floor. The layer is optically thin, so its
brightness grows with the path through it, ∝ 1/μ, capped at 7: the limb brightens
where the photosphere darkens, which is why 304 Å and H-α discs have bright rims.

## Above the limb

- **Spicules**, the chromosphere's top, are jets ~10 Mm (0.015 R) high and leaning,
  so the limb is a ragged fringe (De Pontieu et al. 2007).
- **The transition region** glows just off the limb, clumped over the network.
- **The corona** falls off steeply. Helmet streamers rise over the active belts and
  narrow into rays; polar plumes stand over the coronal holes. The billboard follows
  the spheroid's projected outline, so a fast rotator's halo starts at its own limb.

## Plasma on the field

A picture of a prominence or a loop is a line-of-sight integral: I = ∫ S (1 − e^−dτ) e^−τ
for optically thick material, I = ∫ n² G(T) ds for thin (the emission measure that forward
models of EUV images integrate). So each structure is a volume, marched from the camera
through a box about it (`prom_volume.gdshader`), with its density written in coordinates
that follow its field: along a field line, and across the family of lines. Noise stretched
along the field makes structure that runs along it. Its ridges, where the noise crosses
its mean, are surfaces, so a family of field-aligned sheets that fold. Malanushenko et
al. (2022, ApJ 927, 1) find in MURaM simulations that many apparent coronal loops are
exactly this: folds in a sheet of emission, bright where a sight line runs along them.
Where two families of sheets cross they make tubes, the strands of a loop.

Plasma fills little of its volume (filling factors of ~0.1), so a sight line crosses
bright strands and dark gaps instead of averaging to a fog. Each structure has three
scales of it: clumps a few to a structure, sheets, and finer threads; detail that falls
below a pixel is blunted into the glow it averages to.

Three geometries:

- **Arcades** cross the neutral line, nested: field line ρ is a semi-ellipse, the loops
  smaller at the line's ends. Successive reconnection builds a post-flare arcade in
  generations, so its density is in shells, each threaded with strands. It forms at
  ~10⁷ K, invisible in white light, and appears in H-α and He II only as it cools
  (`cooled`, from the plasma temperature). Below ~2 MK its loops go thermally unstable
  and strands condense into 10⁴ K rain, which falls down both legs (Antolin 2020;
  Scullion et al. 2016); only that cool fraction absorbs.
- **The flux rope** runs along the neutral line, its threads wound about an arched
  axis. Its cool material lies in the dips of the twisted field, below the axis, and
  the cavity above is nearly empty. As it erupts its twist turns into writhe and the
  axis kinks into an S (Török & Kliem 2005), its strands fray, and it drains down its
  legs; the event's fade is that loss of material, so it dims and stops absorbing
  together.
- **Hedgerow prominences** are quiescent: thin curtains of near-vertical threads along
  filament channels and the polar crown, with ragged tops, downflows through them, feet
  (barbs) in the chromosphere, and a dark bubble at the base from which plumes rise by
  the Rayleigh–Taylor instability (Berger et al. 2008, 2010, 2011, Hinode/SOT).

Cool material is optically thick in its lines (`Prominence.KAPPA_COOL`) and thin in the
continuum, so it hides only the disc's line light (`LINE_SHARE` of it). Its source
function is the disc's light scattered at the prominence's height, below the disc's own:
the same material glows off the limb and is a dark filament against the disc.

The flare ribbons on the disc straddle a sheared, meandering neutral line, offset along
it by the shear and lumpy with kernels, and they separate as reconnection climbs. They
are ~10⁴ K, the white-light flare continuum, drawn by its Planck ratio to the
photosphere and published at that temperature, so a flare is bluer than its star.

## Puffed-up and shedding stars

A dwarf's photosphere is a skin: its pressure scale height is 4 × 10⁻⁴ of its radius.
A red supergiant's is a few percent, and its atmosphere is levitated far beyond that by
convection, shocks and pulsation: Antares and Betelgeuse have a molecular layer
("MOLsphere") at 1.2–1.4 R (Ohnaka et al. 2013, 2017), a lukewarm chromosphere out to
~2.5 R peaking near 3500 K, not the Sun's 10⁴ K (O'Gorman et al. 2020, A&A 638, A65), and
gas out to ~12 R. A Mira's molecular layers reach ~2 R and its dust shells ~2–4 R.
None of it has a sharp edge, which is why these stars' radii are uncertain by tens of
percent. `Stellar.envelope_of` derives it from the structure, and `star_envelope.gdshader`
marches it through a sphere about the star:

- **The molecular layer** has a scale height of `Stellar.LEVITATION` pressure scale heights
  and a radial optical depth in the visible set by TiO, which strengthens sharply below
  ~4000 K. Along a sight line past the limb it is many times thicker than radially, so the
  limb is hidden in it and the star ends in a glow rather than an edge. It is lumpy over
  the giant cells, with plumes standing above them (VLT/NACO shows one reaching ~6 R on
  Betelgeuse, Kervella et al. 2009). Its temperature is within a few hundred kelvin of
  T_eff at its base, so it glows at nearly the photosphere's brightness; TiO absorbs green
  and blue more than red, so what it covers reddens.
- **Dust** condenses where grains reach ~1300 K, at r_c/R = ½ (T_eff/T_c)^{5/2} (Höfner
  2007, with p = 1): ~3–4 R on a Mira, ~6 R on Betelgeuse. Past it the wind is dusty, in
  clumps rather than a smooth shell (Freytag & Höfner 2023), with radial optical depth
  κ Ṁ / (4π v r_c) from the star's own wind rate (`Structure.wind_mass_loss`). An M star's
  silicates are iron-poor and nearly transparent in the visible (Höfner 2008), so κ ≈ 30
  cm² per gram of gas: a Mira's shell dims it by about a magnitude, Betelgeuse's by a few
  tenths. Dust reddens what it covers (∝ 1/λ) and forward-scatters
  starlight; the scattered light is ~10⁻³ of the star's and is drawn at
  `StarVisual.DUST_GAIN`.
- **Episodic ejections.** Red supergiants lose much of their mass in discrete outflows
  from their largest cells: VY CMa's knots and arcs date to separate events decades
  apart (Humphreys et al. 2021), and in 2019 Betelgeuse threw off a hot, dense puff,
  bright in the UV, that cooled into a dust cloud over its southern hemisphere and
  dimmed it by more than a magnitude (Dupree et al. 2020; Montargès et al. 2021, Nature
  594, 365). The orchestrator launches puffs at 0.6 v_esc, about once per few crossings
  of the layer, on the sim clock. Each keeps its mass as it spreads, trails a wake back
  to the surface, and condenses closer in than the wind does (dense gas condenses
  hotter, `PUFF_CONDENSE`); once it has, its opacity is the grains', several times the
  molecules' (`DUST_BOOST`). That jump is the Great Dimming.
- **Hot winds.** A Wolf–Rayet star's wind is optically thick in electron scattering at
  its base (κ_es Ṁ / (4π v∞ R) with a β = 1 velocity law), so its hydrostatic surface is
  hidden and what is seen is formed in the outflow; near the Eddington limit the
  continuum drives an outflow at any temperature (Owocki et al. 2017), and an LBV like
  η Car is buried in one. The wind is drawn clumped and streaming radially (clumping is
  observed in every WR wind, Lépine & Moffat 1999), its scattered starlight and line
  emission diluted outward, the latter at `StarVisual.WIND_GAIN`.
- **The dividing line.** Giants cooler than ~K2–K3 have no hot corona and no hot loops;
  their chromospheres feed cool, massive winds instead (Linsky & Haisch 1979; Haisch,
  Schmitt & Fabian 1992). `Stellar.hot_corona` turns the corona billboard, the active-region
  loops and the quiescent prominences off past it.

## Types

| Star | What is drawn |
|---|---|
| O, B, A (no convective envelope) | smooth limb- and gravity-darkened continuum; no granules, spots, chromosphere or loops |
| F, G, K dwarfs | high-contrast granulation (strongest in F), network, plage, spots and flares |
| M dwarfs | low-contrast granulation, large cool-contrast spots, a strong chromosphere (dMe stars show H-α in emission) |
| giants and supergiants | a few giant convection cells at high contrast, a weak chromosphere, no network; past K2–K3 no hot corona, and a levitated molecular layer that hides the limb |
| AGB stars and red supergiants (Mira, Betelgeuse, Antares) | the molecular layer, a clumpy dust shell from the wind, and episodic ejections that turn to dust |
| Wolf–Rayet stars and LBVs (R136a1, η Car) | a clumped, optically thick wind in which the visible surface is formed |
| white dwarfs | `quiet`: no dynamo, so no spots, flares or chromosphere |

Check with `tools/sunlab.tscn` (`star=`, `band=4|5`, `at=limb|top|disc`, `x=`,
`puff=r,lat,lon`), whose clip options (`xto`, `puffto`, `orbit`, `seq`) record a flare or
an ejection as it develops.
