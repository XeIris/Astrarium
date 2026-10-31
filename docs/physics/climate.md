# Climate: `sim/climate.gd`

A zero-dimensional energy balance for the home world,

    C dT/dt = (1 − α(T)) S/4 − OLR(T),   OLR = ε σ T⁴

with ε the effective emissivity (0.61 puts Earth at 288 K), α rising with ice cover
between 278 K and 233 K, and C the ocean mixed layer's heat capacity. S is the
summed flux of every star at the planet's current distance (`insolation_at`).

## Runaway greenhouse

A wet world's outgoing longwave is capped at 282 W/m², the limit a saturated steam
atmosphere reaches near 300 K and holds until the surface passes ~1600 K
([Goldblatt et al. 2013](https://doi.org/10.1038/ngeo1892)). With ε = 0.61 the cap
binds above 302 K, so an Earth with α = 0.306 runs away above ~1.19 S⊕; 1D models
give 1.06 ([Kopparapu et al. 2013](https://doi.org/10.1088/0004-637X/765/2/131)) and
3D models ~1.1.

Above the cap the extra flux goes into the ocean, not the mixed layer. Earth's ocean
is 2.7×10⁶ kg/m² (1.4×10²¹ kg over 5.1×10¹⁴ m²); boiling it takes 6.2×10¹² J/m²,
10⁵ times what heats a 12 m mixed layer by a kelvin. So at the boiling point the
temperature follows the saturation curve while the ocean evaporates, and the steam
rains back out when the planet cools:

    T_boil = 1 / (1/373.15 K − (R/L) ln(1 + 270·steam)),   L = 40.7 kJ/mol

(Clausius–Clapeyron at constant L; a whole ocean as steam is 270 bar and 651 K, close
to water's 647 K critical point). An Earth-like world at 1.5 S⊕ boils its ocean in about
three thousand years; a Trisolaris close pass of a few months boils a fraction of a
percent. While steam is present the era is "Runaway greenhouse". Hydrogen escape,
which removes the water for good over 10⁸–10⁹ years in a moist greenhouse
(Kasting 1988), is not modelled, so steam always rains back.

A world declared without oceans (`climate.oceans = false`) has no cap.

## The habitable zone

`Climate.hz_flux` evaluates Kopparapu et al. (2013, Table 3, as corrected in their
erratum) for a star's Teff, S_eff = S☉ + aT + bT² + cT³ + dT⁴ with T = Teff − 5780 K
(clamped to 2600–7200 K). The climate panel shows the conservative zone, runaway to
maximum greenhouse (1.05 to 0.34 S⊕ for the Sun), for the star delivering most of the
flux; the limits are single-star results, so a circumbinary world reads them
approximately. The coefficients were transcribed from the paper rather than
re-downloaded; at 5780 K they reproduce its 0.99 AU moist-greenhouse and 1.70 AU
maximum-greenhouse distances.

## Clouds

Cloud cover is a visual humidity rule: it rises 3.75%/K near 288 K. It stays out of
the energy balance. Coupled at CERES's cloud radiative effect (−47 W/m² shortwave,
+26 W/m² longwave, at 0.67 cover; Loeb et al. 2018), that rule would add a cloud
feedback of −1.2 W/m²/K, where the observed value is +0.42 ± 0.35 W/m²/K (IPCC AR6
WG1 ch. 7). The base albedo and ε already include today's clouds.
