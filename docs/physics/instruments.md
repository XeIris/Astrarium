# The Observatory's instruments

Code: `sim/observatory/` (`telescopes.gd`, `optics.gd`, `sky_conditions.gd`, `sky_field.gd`,
`planet_disc.gd`, `imager.gd`, `instruments.gd`) and `ui/plate_view.gd`. Check:
`tools/imagingcheck.gd`, headless, with `tools/hudcheck.tscn` for the panel.

A frame is synthesised on the CPU, from a request to an array of electrons, with no scene
access and no GPU. That makes the same numbers available to a headless check as to the
screen. `expose()` runs on a worker thread, since a Moon-filling frame takes a noticeable
fraction of a second in GDScript. The clock doesn't advance during an exposure, and the
target is treated as perfectly tracked.

## From a star to electrons

```
electrons = 1004 ph/s/cm²/Å × 10^(−0.4 V) × Δλ × A × τ × 10^(−0.4 k X) × t
```

1004 is Johnson V = 0 (Bessell 1998's 3.63×10⁻⁹ erg/s/cm²/Å at 5500 Å), Δλ the filter's
width, A the unobstructed collecting area and τ the whole system's throughput with the
detector's QE, k the site's V extinction, X the airmass and t the exposure. X is Kasten &
Young (1989), which stays finite at the horizon: 1/(cos z + 0.50572 (96.07995 − z)^−1.6364).

Each pixel then holds its share of the light under the PSF, plus the sky (`sky_v`, a surface
brightness measured from the ground, so it takes no further extinction) and dark current. It
gets Poisson noise, Gaussian read noise and the full well's clip. Charge past a full well
bleeds along its column, half up and half down, until a pixel has room. Binning sums
physical pixels in software: sky, dark and the well scale with their number, and read noise
with its square root.

## The PSF

The radial PSF is the Hankel transform of the product of two transfer functions:

```
P(θ) = 2π ∫ T(f/fc) exp(−3.44 (λf/r0)^(5/3)) J0(2πfθ) f df,   fc = D/λ
```

`T` is the annular pupil's OTF (O'Neill 1956) and the exponential Fried's long-exposure
atmospheric MTF. With r0 → ∞ this is the obstructed Airy pattern. With D ≫ r0 it tends to
FWHM = 0.98 λ/r0. The seeing slider is the FWHM at 500 nm at the zenith, and r0 scales as
λ^(6/5) X^(−3/5).

The integral uses 256 frequency samples, up to min(D/λ, 4 r0/λ), where the atmosphere's
transfer has fallen below 10⁻⁶. That loses the far wing to rounding, so a seeing-limited PSF
continues past 2 FWHM as Kolmogorov's θ^(−11/3). Against a 4096-sample integral the join is
good at 2 FWHM and runs about 30–50% high at 3.5–7 FWHM, which is well under 1% of the light.
A bright star's stamp continues along that tail until it adds under 0.02 e⁻ per pixel.

Discs are painted, then blurred by a Gaussian of equal FWHM, which keeps the frame's cost
down. That loses the true PSF's wings on a resolved body. The aperture for SNR and the
limiting magnitude has a radius of one FWHM (at least a pixel), and uses the PSF's own
encircled energy.

## The sky

- **Dark sky.** V mag/arcsec² at the zenith per site, with half of it brightening by the
  airmass (airglow's van Rhijn slant; Patat 2008's f ≈ 0.5 in V).
- **Moon.** Krisciunas & Schaefer (1991) eqs. 15–21, with its own scattering function, phase
  curve and extinction. The nL scale is their eq. 1.
- **Twilight.** Patat et al. (2006), μ_V = 11.84 + 1.518 (ζ − 95) − 0.057 (ζ − 95)² for
  solar zenith distance 95°–105°.
- **Daylight** is a straight run from there to V ≈ 4 mag/arcsec². It is an estimate that only
  matters to show why a dome stays shut: with the Sun up, the desk refuses optical frames.

## The sources

- **Catalogue stars**: the BSC5 and Gaia files the sky already draws, to V ≈ 8, carried by
  their proper motions.
- **Fainter stars are modelled, not observed**: a Poisson-like field seeded per ¼° patch of sky,
  so every telescope sees the same stars at the same place, and a deeper frame only adds to
  them. Its counts per square degree are approximate and shape the field only, scaled by
  galactic latitude with a simple disc. Nothing there is a real star.
- **Planets** take their V from `Marker.apparent_magnitude` (Mallama & Hilton), the **Moon** from
  Krisciunas & Schaefer's phase curve, scaled by its distance. A map decides where that light
  falls, not how much. Maps are the repository's existing Moon, Mars and Jupiter; orientation is
  IAU WGCCRE (Archinal et al. 2018), with the Moon's largest periodic terms. Scattering is
  Lommel–Seeliger on the airless bodies and Minnaert (k = 0.75) on the others. Saturn's rings
  and banding have their relative brightness set by eye.

A planet covers its map's real resolution: 2.8″ per map pixel on the Moon, so a DEIMOS frame of
it is blurrier than the telescope.

## Radio

The Lovell's L-band map is flux density, not light. Each pixel is the sky through a Gaussian beam
of FWHM 70 λ/D, with radiometer noise (SEFD + S)/√(2Δν τ) per pointing and confusion (Condon
et al. 2002's 0.2 mJy ν^−0.7 θ²), both smoothed by the beam. Confusion is seeded to the sky, as
a stand-in for its unresolved sources. Radio sources follow Baars et al. (1977). Bodies are
thermal, S = 2kTΩ/λ², except Jupiter's synchrotron belts and the quiet Sun. A star has no entry
at all, and the panel says so: it's a real limit of the instrument, as a star is many orders
of magnitude below the confusion.

## Pointing

`status()` reports altitude, azimuth, airmass, rise and set past the mount's limit, and a slew
time at published rates, the short way round. It's computed for the target's present place, so a
moving body's rise and set are approximate. The telescope on the ground chases the target at
`SLEW_SPEEDUP` times its real rate, since a true Lovell slew takes minutes. Optical frames are
refused below the limit, with the Sun up or within 30° of it. Radio frames need only the limit.

## The numbers and how far to trust them

| Instrument | Value | Source |
|---|---|---|
| FORS2 | 8.2 m, 0.25″/px (2×2), 6.8′ field | [ESO FORS](https://www.eso.org/sci/facilities/paranal/instruments/fors/inst.html) |
| FORS2 | read noise 2.7 e⁻, gain 0.70 e⁻/ADU | ESO's CCD upgrade page (high gain, 100 kHz). **Its applicability to the MIT CCD is unconfirmed** |
| FORS2 | full well 45,900 e⁻ | Derived: 16 bits × 0.70 e⁻/ADU. The well itself is deeper, so this is the converter's limit |
| FORS2 | τ = 0.34, V_HIGH 123 nm | **From memory**, then held to ESO's [zero point](https://www.eso.org/sci/facilities/paranal/instruments/fors/inst/zeropoints.html) of ≈ 28.2 |
| FORS2 | dark 3 e⁻/px/h | **Estimate** |
| DEIMOS | 10 m, 0.1185″/px, 16.7 × 5′; 800 e⁻/s at V = 21 | [Keck DEIMOS](https://www2.keck.hawaii.edu/inst/deimos/specs.html). τ = 0.30 is set by this rate, so that check is not independent |
| DEIMOS | read noise ≤ 5 e⁻, dark < 0.001 e⁻/s, ~1 e⁻/DN | Design review figures; the actual read noise may well be lower |
| DEIMOS | a 5′ square of the field | A simplification: frames are square |
| OmegaCAM | 2.6 m, 0.214″/px, 1°, read noise 5–6 e⁻, gain ~2.5 e⁻/ADU | [ESO OmegaCAM](https://www.eso.org/sci/facilities/paranal/instruments/omegacam/inst.html) |
| OmegaCAM | full well 163,000 e⁻ | Derived, as for FORS2 |
| OmegaCAM | τ = 0.40, dark 0.001 e⁻/s, ε = 0.36 | **Estimates** |
| Lovell | 76.2 m, 15°/min az, 10°/min el | [JBO facts](http://www.jb.man.ac.uk/aboutus/lovell/facts.html) |
| Lovell | SEFD 36 Jy; 512 MHz; 1.25–1.75 GHz | EVN status table as quoted by a Goonhilly paper; e-MERLIN. Not read from a primary table |
| Mounts | Keck ε = 0.18 and all optical slew rates and altitude limits; the 30° Sun limit | **Estimates**. Treat slew times as indicative |
| Paranal | sky V 21.61 | [ESO NSB](https://www.hq.eso.org/sci/facilities/paranal/astroclimate/Obsconditions/NSB.html) (Patat 2003) |
| Paranal | seeing 0.72″ | ESO's 2016–2023 median. k_V 0.12 is **from memory** (Patat et al. 2011) |
| Mauna Kea | sky V 21.9, k_V 0.11 | Krisciunas 1997; CFHT. Seeing 0.6″ is **an estimate** from CFHT's 0.40″ free atmosphere plus a dome |
| Jodrell Bank | the optical row | **Placeholder**: only its radio receiver is modelled |
| Radio | Baars spectra, Cas A's fade; thermal temperatures; Jupiter 4.8 Jy at 4 AU; quiet Sun 40 sfu | Baars **from memory**, then checked against 1.4 GHz values also from memory. The rest are **estimates**. Cas A's fade is extrapolated 60 years from 1965 and is probably too steep by now |

## Not modelled

- **Galaxies, nebulae and clusters.** A deep frame shows stars only, real to V ≈ 8 and invented
  below. The Hubble Ultra Deep Field's coordinates give you modelled stars, not its galaxies.
- **Earthshine.** A crescent's night side is black, so a frame at its centre is sky and noise.
- **Moons of other planets** (the solar preset doesn't carry them), asteroids and comets.
- **Ghosts, spider diffraction spikes, Keck's segmented pupil, flat fields, cosmic rays, fringing,
  sky gradients, dispersion and refraction.** A Keck PSF is a circular annulus here.
- **Adaptive optics.** So Keck is seeing-limited, as without its AO system. Diffraction appears
  only with Seeing at 0, and only on a fine enough pixel.
- **Filters other than V**, and spectra; every source is V-band. So no star colours: frames are
  monochrome, as a single-filter frame is.
- **Apparent places.** A frame uses the same geometric places as the sky view
  ([observatory.md](observatory.md#from-a-civil-date-to-the-sky)), with no annual aberration
  (≤ 20″), light deflection or planet light time (≤ 40″). At 0.1–0.25″ per pixel those are
  hundreds of pixels, and the outer planets' mean elements are further still: Saturn is 0.16°
  (572″) from Horizons at J2000, wider than FORS2's 408″ field. A frame of a planet is centred
  on the model's planet. Its position against the catalogue's stars isn't the real one.
- **Weather.** The sky is always clear. The radio band has no sky background, RFI or spillover.
- **A real exposure's motion**: tracking errors, differential refraction, a planet's own motion
  and rotation during long frames.
- **A neutral-density filter is an invention.** These instruments don't carry the 5 and 10 mag
  options. The Moon and planets otherwise saturate them in under the slider's 1 ms, which is
  itself true: observers use other means, such as narrow-band filters.

## Checks

`tools/imagingcheck.gd`, by what each one protects:

- Diffraction: the first dark ring of a frame's own pixels at 1.22 λ/D; the Airy profile from
  its J1 form; the annular OTF against a direct count of the overlap of two displaced annuli.
- Seeing: FWHM = 0.98 λ/r0 across D, r0 and λ, in the table and in a frame's pixels; the r0
  scalings; a 5 cm aperture staying diffraction-limited.
- Photometry: every electron on the frame; a blank frame's mean and variance; the panel's SNR
  against the scatter of 400 frames for four instrument and magnitude pairs; a star at the
  reported limit having SNR 5; sky-limited depth with exposure and aperture.
- Saturation: nothing over the well, a bleed along the column and not the row, and a sky over
  the well reporting no limit.
- Sky: airmass; the Moon's phase curve and scattering; twilight's fit; the nL scale against
  Crumey (2014, MNRAS 442, 2600, §1.3): 60⁴(180/π)² Z_V with Z_V = 2.54×10⁻⁶ lx is 1.08×10⁵ cd/m²
  at 0 mag/arcsec², and 22 mag/arcsec² is his 1.71×10⁻⁴ cd/m².
- The Moon: **Mare Crisium on the sky-west side**, the map's dark sea where the IAU axes put it,
  a waning crescent lit on the east, the lit fraction, the libration range.
- Radio: Baars' fluxes; the beam; the radiometer equation; a source's peak in Jy/beam; a blank
  map's rms; the Moon through the beam.
- Reach: analytic rise and set against altitude directly read then; refusal reasons; slew times.
