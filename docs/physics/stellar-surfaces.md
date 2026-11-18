# How a star's surface is drawn

`sim/star_visual.gd` and the shaders it drives (`star_photo`, `star_corona`,
`prom_arcade`, `star_noise`) draw a star as the layers an observer would separate:
the photosphere in continuum light, the chromosphere's line emission over it, the
transition region and corona above the limb, and the plasma held on the magnetic
field (loops, prominences, flare arcades). Each layer is modelled from what is
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

## The photosphere

Every feature is a local temperature T, drawn through the Planck ratio
B_λ(T)/B_λ(T̄) at the sRGB primaries' effective wavelengths (612, 549, 465 nm). A
spot's colour and contrast are therefore consequences of its temperature, and the
temperature pass publishes the same T, so a spot is dark and a ribbon bright in UV.

- **Granulation.** Rms continuum contrast ≈ 16% for the Sun before instrumental
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

Arcades are separate threads, each a bright core with a glow, finer strands inside,
and condensations streaming along the field (coronal rain down both legs of a loop;
drainage out of a rising rope). Three geometries share one buffer:

- **Arcades** cross the neutral line: the active-region loops between flares (hot,
  1–3 MK, nearly invisible in white light) and the post-flare arcade, which forms
  under the rope, climbs with the reconnection point and cools (the standard CSHKP
  picture).
- **The flux rope** runs along the neutral line with its threads wound about one
  axis. As it erupts its twist turns into writhe and the axis kinks into an S
  (Török & Kliem 2005); its threads fray away from the axis and drain down its legs.
- **Hedgerow prominences** are quiescent: thin curtains of near-vertical threads
  along filament channels and the polar crown, with ragged tops and downflows through
  them (Berger et al. 2008, 2010, Hinode/SOT). Against the disc the same material
  absorbs: a filament.

The flare ribbons on the disc straddle a sheared, meandering neutral line, offset
along it by the shear and lumpy with kernels, and they separate as reconnection
climbs. They publish ~10⁴ K, the white-light flare continuum.

## Types

| Star | What is drawn |
|---|---|
| O, B, A (no convective envelope) | smooth limb- and gravity-darkened continuum; no granules, spots, chromosphere or loops |
| F, G, K dwarfs | high-contrast granulation (strongest in F), network, plage, spots and flares |
| M dwarfs | low-contrast granulation, large cool-contrast spots, a strong chromosphere (dMe stars show H-α in emission) |
| giants and supergiants | a few giant convection cells at high contrast, a weak chromosphere, no network |
| white dwarfs | `quiet`: no dynamo, so no spots, flares or chromosphere |

Check with `tools/sunlab.tscn` (`star=`, `band=4|5`, `at=limb|top|disc`, `x=`), whose
clip options (`xto`, `orbit`, `seq`) record a flare as it develops.
