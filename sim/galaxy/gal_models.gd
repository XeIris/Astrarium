class_name GalModels
extends RefCounted

# The modelled galaxies, as data: a potential, the tracer populations that sample
# it, and how its light follows its mass. Sources per value in
# docs/physics/galaxies.md; nothing here is tuned to look right.

## The scenarios of the galactic scene, in the order the list shows them.
const ORDER := ["gal_milkyway"]

const PRESETS := {
	"gal_milkyway": {
		"name": "Milky Way",
		"blurb": "Our galaxy as Bovy's MWPotential2014: a bulge, a Miyamoto–Nagai disc and an NFW dark halo, fitted to measured Milky Way kinematics. Thousands of test stars and cold-gas clouds orbit in it. Its rotation curve is measured live from them, beside the one Gaia and APOGEE measured.",
		"model": "milky_way",
		"camRadius": 60.0,
		"camTheta": 0.95,
		"rateMyrS": 5.0,
	},
	"gal_m87": {
		"name": "M87",
		"blurb": "A giant elliptical at the heart of the Virgo cluster, 17 Mpc away: a ball of old stars five times the Milky Way's light (Kormendy et al. 2009), around the black hole the Event Horizon Telescope imaged.",
		"model": "m87", "camRadius": 200.0, "camTheta": 1.2, "rateMyrS": 0.0,
	},
	"gal_m51": {
		"name": "Whirlpool (M51)",
		"blurb": "A grand-design spiral 8.6 Mpc away, its two arms measured one by one (Marchuk et al. 2024), with its companion NGC 5195 tens of kpc behind it at the tip of one arm.",
		"model": "m51", "camRadius": 45.0, "camTheta": 0.8, "rateMyrS": 0.0,
	},
	"gal_m104": {
		"name": "Sombrero (M104)",
		"blurb": "A disc galaxy seen 6° from edge-on, 9.6 Mpc away: a bright spheroid of old stars, a disc, and a ring of dust that cuts across it (De Looze et al. 2012).",
		"model": "m104", "camRadius": 45.0, "camTheta": 1.466, "rateMyrS": 0.0,
	},
}

# Bovy (2015) Table 1: normalised at R0 = 8 kpc, vc(R0) = 220 km/s, with the bulge,
# disc and halo supplying 5, 60 and 35 % of the radial force there.
const MW_R0 := 8.0
const MW_V0_KMS := 220.0

## McKee, Parravano & Hollenbach (2015): of the 47.1 M☉ pc⁻² of baryons over the
## solar circle, 27.0 are visible stars and 33.4 stars plus remnants; the rest is gas.
## The bulge has almost no gas, so its visible share is 27.0 / 33.4.
const VISIBLE_DISC := 27.0 / 47.1
const VISIBLE_BULGE := 27.0 / 33.4

## The Milky Way's neighbours, drawn from their stars: placed where they are, tilted as
## measured. Light only: their halos wait for encounters (phase 4), which need them.
## Exponential discs stand in as Miyamoto–Nagai discs of the same mass and half-mass
## radius (a = 1.678 R_d / √3); a spheroid as a Hernquist sphere of the same projected
## half-light radius (a = R_e / 1.8153). docs/physics/galaxies.md#the-local-group.
## Positions from NED; i the inclination, pa the line of nodes east of north (degrees).
## Measured beats modelled: where McConnachie (2012, Table 3) gives an absolute V (`mv`),
## the light is scaled to it; the stellar masses only shape it. galaxycheck reports how far
## the masses alone would land.
const LOCAL_GROUP := {
	# Kafle et al. (2018), whose bulge and disc masses average five earlier studies; distance
	# from McConnachie (2012, Table 2); i 77.5° (Tamm et al. 2012), PA 38° (Corbelli et al. 2010).
	"m31": {"name": "Andromeda (M31)", "ra": 10.68479292, "dec": 41.269065, "d": 783.0, "i": 77.5, "pa": 38.0,
		"bulge": [3.4e10, 0.7], "disc": [6.9e10, 6.5, 0.26], "extent": 35.0},
	# Corbelli et al. (2014): stars 4.8 × 10⁹ M☉, an exponential disc of 1.8 kpc, no bulge,
	# 100 pc half-thick at the centre; McConnachie (2012): 809 kpc, PA 23°, ellipticity 0.41,
	# so i = acos(1 − 0.41) for a thin disc.
	"m33": {"name": "Triangulum (M33)", "ra": 23.46204167, "dec": 30.66022222, "d": 809.0, "i": 53.84, "pa": 23.0,
		"disc": [4.8e9, 1.744, 0.1], "extent": 15.0, "mv": -18.8},
	# van der Marel, Kallivayalil & Besla (2009): stars 2.7 × 10⁹ M☉; van der Marel (2001):
	# exponential, scale length 1.3–1.5 kpc (1.4 here); van der Marel & Cioni (2001): i 34.7°,
	# PA 122.5°; Pietrzyński et al. (2019): 49.59 kpc. Its thickness, b = 0.2 a, is a rendering
	# choice: van der Marel et al. (2002) find a thick disc, V/σ ≈ 2.9.
	"lmc": {"name": "Large Magellanic Cloud", "ra": 80.89416667, "dec": -69.75611111, "d": 49.59, "i": 34.7, "pa": 122.5,
		"disc": [2.7e9, 1.356, 0.27], "extent": 12.0, "mv": -18.1},
	# Stars 3.1 × 10⁸ M☉ (van der Marel et al. 2009, from Stanimirović et al. 2004); the old
	# stars a spheroid (ibid.), exponential with scale length 1.25 kpc (Gonidakis et al. 2009),
	# so R_e = 2.10 kpc; Graczyk et al. (2020): 62.44 kpc. Drawn round: Crowl et al. (2001)
	# find it elongated along the line of sight.
	"smc": {"name": "Small Magellanic Cloud", "ra": 13.18666667, "dec": -72.82861111, "d": 62.44, "i": 0.0, "pa": 0.0,
		"bulge": [3.1e8, 1.155], "extent": 15.0, "young": true, "mv": -16.8},
}

## A neighbour's model, as GalaxyVisual draws it. Masses are stellar, so both parts take
## the bulge's visible share of stars and remnants. Discs form stars steadily for 10 Gyr;
## a bulge formed early, except the SMC's spheroid, which also formed steadily.
## `from_mass` leaves the light at the masses' (galaxycheck's comparison).
static func neighbour(key: String, from_mass := false) -> Dictionary:
	var spec: Dictionary = LOCAL_GROUP.get(key, {})
	if spec.is_empty(): return {}
	var pot := GalPotential.new()
	var light := []
	if spec.has("bulge"):
		pot.add(GalPotential.hernquist("bulge", float(spec.bulge[1]), GalUnits.G * float(spec.bulge[0]) / GalUnits.MASS_UNIT_SUN))
		light.append({"part": "bulge", "visible": VISIBLE_BULGE})
	if spec.has("disc"):
		pot.add(GalPotential.miyamoto_nagai("disc", float(spec.disc[1]), float(spec.disc[2]), GalUnits.G * float(spec.disc[0]) / GalUnits.MASS_UNIT_SUN))
		light.append({"part": "disc", "visible": VISIBLE_BULGE})
	var model := {
		"key": key, "name": spec.name, "potential": pot, "sense": 1.0, "extent": spec.extent, "light": light,
		"spherePop": {"kind": "constant", "gyr": 10.0} if spec.get("young", false) else {"kind": "burst", "gyr": 10.0},
		"sky": spec,
	}
	if spec.has("mv") and not from_mass:
		var k := pow(10.0, -0.4 * (float(spec.mv) - 4.83)) / visible_luminosity(model)
		for l in light: l.visible = float(l.visible) * k
	return model

## A model's total visible luminosity (Sun-luminances): each part's stellar mass, visible
## share, its population's L/M and that light's luminance.
static func visible_luminosity(model: Dictionary) -> float:
	var pop_d := GalPopulation.build(model.get("discPop", {"kind": "constant", "gyr": 10.0}))
	var pop_s := GalPopulation.build(model.get("spherePop", {"kind": "burst", "gyr": 10.0}))
	var lv := 0.0
	for l in model.light:
		var part: Dictionary = (model.potential as GalPotential).part(l.part)
		var pop: GalPopulation = pop_d if l.part == "disc" else pop_s
		var y := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
		lv += float(l.visible) * float(part.gm) / GalUnits.G * GalUnits.MASS_UNIT_SUN * pop.mean_l / pop.mean_mass * y
	if model.has("armLight"):
		var young := GalPopulation.build({"kind": "constant", "gyr": MW_YOUNG_GYR})
		lv += float(model.armLight) * (0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b)
	return lv

# 150″ at 8.58 Mpc, where Egusa et al. (2017) split M51's arms into inner and outer pitches.
const M51_ARM_BREAK := 6.240

## Galaxies of other kinds, each a scene of its own (too far for the Milky Way's): drawn
## at their measured total light (V_T⁰ or M_VT), shared among parts as their published
## decompositions find it; each part's stellar mass follows through the population
## model. Light only. docs/physics/galaxies.md#galaxy-types.
## `parts`: name → [share of the light, scale (kpc), (disc height, kpc)].
const TYPES := {
	# Kormendy et al. (2009, Table 1): D 17.22 Mpc, M_VT −22.95, r_e 16.2 kpc from the 2-D
	# profile (194.4″); E1, drawn round. A Hernquist sphere of that half-light radius.
	"m87": {"name": "M87", "ra": 187.7059308, "dec": 12.39112326, "d": 17220.0, "mv": -22.95,
		"parts": {"bulge": [1.0, 8.93]}, "extent": 150.0},
	# McQuinn et al. (2016): 9.55 Mpc; RC3 V_T⁰ 7.55, so M_V −22.35. Gadotti &
	# Sánchez-Janssen (2012, model bdh, at 9.1 Mpc, rescaled): bulge 13 % (n 1.9, r_e 0.46 kpc)
	# and halo 52 % (exponential, r_e 6.0 kpc, ellipticity 0.28) as one Hernquist sphere of
	# their joint half-light radius, 4.68 kpc; disc 35 %, scale length 1.89 kpc, height 0.78.
	# Inclination 84° (Emsellem et al. 1996, via ibid.).
	# The Whirlpool, 8.58 Mpc (McQuinn et al. 2016). Its light is M51_LIGHT: the measured V_T (RC3
	# V_T⁰ 8.14, M_V −21.53) is what the dust leaves of it, and is checked, not imposed.
	# Orientation i 24°, PA 169°, and the arms' pitches in that frame, from the stellar mass map:
	# 19.3° and 23.4° inside 150″, 37.4° and 32.4° beyond, measured over 30″–220″ (Egusa et al.
	# 2017, Tables 1–2; arm 2 is the one joined to NGC 5195). They wind clockwise outward on the
	# sky (mirrored here). Their widths across, σ 0.815 and 0.785 kpc, are Marchuk et al.'s
	# (2024) radial FWHM of 47.0″ and 45.8″. Their phase was set by laying the ridges over
	# Hubble's image, scaled and turned by the two nuclei; their start (rising over 1.5–3.5 kpc)
	# and their fade over 0.6 rad past the measured span are set by eye. Dust: M51_DUST.
	"m51": {"name": "Whirlpool (M51)", "ra": 202.4696258, "dec": 47.19520736, "d": 8580.0, "mv": -21.53, "i": 24.0, "pa": 169.0,
		"light": "m51", "extent": 25.0,
		"arms": [["Arm 1", M51_ARM_BREAK, -135.0, 37.4, 19.3, 0.815, -135.0 - 28.7, -135.0 + 263.0, false],
			["Arm 2", M51_ARM_BREAK, 59.0, 32.4, 23.4, 0.785, 59.0 - 34.6, 59.0 + 212.9, false]], "armMirror": true,
		"armR": [0.5, 20.0], "armTurns": 2, "armWidthGrowth": 0.0, "armRise": [1.5, 2.0], "armEndFade": 0.6,
		"companions": ["ngc5195"], "dustMap": "m51"},
	# NGC 5195, M51's companion: RC3 V_T⁰ 9.58 and effective aperture 114.3″ (r_e 57.15″); 20–50
	# kpc behind M51 (Dobbs et al. 2010; Salo & Laurikainen 2000, via Marchuk et al. 2024), 35 here;
	# i 43°, PA 91° (Spillar et al. 1992, via Wei et al. 2020); old (12 Gyr, ibid.). Drawn round.
	"ngc5195": {"name": "NGC 5195", "ra": 202.4980839, "dec": 47.2661666, "d": 8615.0, "mv": -20.09, "i": 43.0, "pa": 91.0,
		"parts": {"bulge": [1.0, 1.310]}, "extent": 20.0},
	"m104": {"name": "Sombrero (M104)", "ra": 189.9976312, "dec": -11.62308847, "d": 9550.0, "mv": -22.35, "i": 84.0,
		"parts": {"bulge": [0.65, 2.577], "disc": [0.35, 1.834, 0.785]}, "bulgeAxes": [1.0, 0.72], "extent": 30.0,
		"dust": "m104"},
}

# M51's dust, face-on, from Inman et al.'s (2023) radiative-transfer model (Tables 3, A2, A3; i
# 20.3°, 8.58 Mpc): an inner and a main disc, each [R_tin, R_in, R_t, h_d, χ_d, τ_B at R_in] in
# their eq. 1, zero inside R_tin, rising linearly from χ_d to 1 up to R_in, then exp(−R/h_d) to
# R_t, exp(−|z|/z_d) above the plane with z_d 0.16 kpc; τ_B face-on through the whole disc.
# Their fit ends at 6.8 kpc because the disc stops being axisymmetric there, not the dust; past
# it the main disc carries on at their outer disc's 3.6 kpc scale length (Table 5), an
# extrapolation. τ_V = τ_B/1.324 (Rieke & Lebofsky 1985, as EXTINCTION_RGB).
# Lanes: PAWS finds 66.5 % of the CO outside the centre in the spiral arms (Colombo et al.
# 2014, Table 2: 43.44 of 43.44 + 21.88 × 10⁷ K km s⁻¹ pc²), so that share of each ring's dust
# lies in lanes, the ring's mean kept. A lane follows its gas arm's pitch (Egusa et al. 2017,
# Table 2: 19.9° and 18.8° inside 150″, 27.8° and 27.6° beyond) with its azimuthal FWHM (≃ 30°
# inside, ≃ 5° beyond, §3.2), upstream of the young stars by ΔΘ = Ω_p t_SF (R_CR/R − 1) at
# 4 kpc, the middle of the 2.5–6 kpc fitted: Egusa et al.'s (2009) arm-1 fit, Ω_p 31 km/s/kpc,
# t_SF 7.1 Myr (0.225 rad together, distance-free), R_CR 2.9′, with a flat rotation curve.
const M51_DUST := {"discs": [[0.0, 0.8, 1.9, 5.0, 0.45, 5.33], [1.8, 2.7, 6.8, 6.0, 1.0, 2.62]],
	"z": 0.16, "outerH": 3.6, "share": 0.665, "pitchIn": [19.9, 18.8], "pitchOut": [27.8, 27.6],
	"fwhmIn": 30.0, "fwhmOut": 5.0, "omegaT": 0.225, "rCRArcmin": 2.9, "anchor": 4.0}
const A_B_PER_A_V := 1.324
# M51's stars before the dust, from the same model (Inman et al. 2023, Tables 3, 5, A1, A3): a
# Sérsic n = 4 bulge of R_e 0.35 kpc (a Hernquist sphere of a = R_e/1.8153 here), and old and
# young (thin) discs, inner and main, each [R_tin, R_in, R_t, χ_s, h_s in g, h_s in r, z_s,
# L_ν at 4719 Å, at 6185 Å (W Hz⁻¹)] in the form of M51_DUST's discs. Past 6.8 kpc the main
# discs carry on at their outer disc's scale lengths (2.0 kpc old, 1.45 young), an
# extrapolation as for the dust. V is taken between g and r, at Johnson V's 5476 Å, log-linear
# in L_ν and in scale length; the Sun's V is 4.80 AB (Willmer 2018).
# Of the young light outside the nucleus, 91 % is in the arms: the Hα of M51's H II regions,
# 10^41.1 erg/s in the arms against 10^40.1 between them (Lee, Hwang & Lee 2011, §5.2).
# The old disc is gathered into the same arms to its measured peak-to-valley contrast in K,
# where dust hardly dims it: 1.8 at 70″, 3 at 125″, 2 at 150″ (Rix & Rieke 1993, §4.2), linear
# between and held beyond; each ring keeps its mean.
const M51_LIGHT := {"bulge": [0.35, 4.16e20, 6.05e20],
	"disc": [[0.0, 0.0, 1.9, 0.0, 0.74, 0.73, 0.19, 4.36e21, 6.26e21], [1.8, 2.7, 6.8, 1.5, 3.8, 3.5, 0.19, 8.20e21, 1.21e22]],
	"thin": [[0.0, 0.7, 1.9, 0.1, 0.6, 0.6, 0.09, 1.87e21, 1.96e21], [1.8, 2.7, 6.8, -0.7, 4.3, 4.3, 0.09, 3.39e21, 2.95e21]],
	"outerH": [2.0, 1.45], "armShare": 0.91, "armContrast": [[70.0, 1.8], [125.0, 3.0], [150.0, 2.0]]}
# M51's H II regions. Their Hα is the star formation rate's, log SFR = log L(Hα) − 41.27
# (Kennicutt & Evans 2012, Table 1, Kroupa IMF; 90 % of it from stars under 10 Myr), at
# Inman et al.'s 4.11 M☉/yr, less the 45 % in diffuse gas (Thilker, Braun & Walterbos 2000).
# They share it as Lee, Hwang & Lee (2011) measure, at 9.9 Mpc (rescaled): dN/dL ∝ L^−2.25
# above 10^37.1 erg/s and L^−1.42 below, 10^35.5 to 10^39.0; diameter 8 pc at 10^35.5 growing
# as L ∝ D^3.04 (their §5.3, §6.4; the anchor is their size range's lower end). [N II]
# λλ6583, 6548 add half the Hα (Bresolin et al. 2004, via Lee et al.), 3 : 1; Hβ is Hα/2.86
# (case B, 10⁴ K; Osterbrock & Ferland 2006). Each region also holds the light of its stars
# under 10 Myr, the same 55 % of all such light, taken from the young disc's. Regions fainter
# than 10^36.5 erg/s (at 9.9 Mpc; three quarters of them, 14 % of their light) stay in the
# smooth young light, lines and all: a rendering choice.
const M51_HII := {"sfr": 4.11, "logC": 41.27, "dig": 0.45, "tGyr": 0.01, "alpha": [-2.25, -1.42],
	"logL": [35.5, 37.1, 39.0], "d": 9.9, "size": [8.0, 3.04], "nii": 0.5, "hahb": 2.86, "drawLogL": 36.5, "levels": 5, "top": 0.22}
const LAMBDA_V := 5476.0
const SUN_V_AB := 4.80

## L_ν (W Hz⁻¹) in L☉ of V: an AB magnitude at 10 pc against the Sun's.
static func lnu_to_lv(lnu: float) -> float:
	var pc10_cm := 10.0 * GalUnits.AU_PER_PC * Rocketry.AU_M * 100.0
	var m_ab := -2.5 * log(lnu * 1e7 / (4.0 * PI * pc10_cm * pc10_cm)) / log(10.0) - 48.6
	return pow(10.0, -0.4 * (m_ab - SUN_V_AB))

## A disc in Inman et al.'s form at V: [R_tin, R_in, R_t, χ, h, z, L_V (L☉), amplitude at R_in
## (L☉ kpc⁻²)], the amplitude from L_V over the profile's area.
static func inman_disc_v(c: Array) -> Array:
	var f := log(LAMBDA_V / 4719.0) / log(6185.0 / 4719.0)
	var h: float = exp(lerpf(log(float(c[4])), log(float(c[5])), f))
	var lv := lnu_to_lv(exp(lerpf(log(float(c[7])), log(float(c[8])), f)))
	var d := [c[0], c[1], c[2], c[3], h, c[6], lv, 1.0]
	var area := 0.0
	var n := 4000
	var dr: float = float(c[2]) / float(n)
	for k in n:
		var R := (float(k) + 0.5) * dr
		area += inman_shape(d, R) * TAU * R * dr
	d[7] = lv / area
	return d

## The profile's shape, 1 at R_in (zero outside R_tin..R_t).
static func inman_shape(d: Array, R: float) -> float:
	if R < float(d[0]) or R > float(d[2]): return 0.0
	if R < float(d[1]): return R / float(d[1]) * (1.0 - float(d[3])) + float(d[3])
	return exp(-(R - float(d[1])) / float(d[4]))

## Surface luminosity (L☉ kpc⁻²) of a set of such discs at R; past the last one's R_t it
## carries on at outer_h.
static func inman_surface(discs: Array, outer_h: float, R: float) -> float:
	var s := 0.0
	for k in discs.size():
		var d: Array = discs[k]
		if R <= float(d[2]) or k < discs.size() - 1: s += float(d[7]) * inman_shape(d, R)
		else: s += float(d[7]) * inman_shape(d, float(d[2])) * exp(-(R - float(d[2])) / outer_h)
	return s

## The light past the last disc's R_t, as inman_surface continues it.
static func inman_beyond(discs: Array, outer_h: float) -> float:
	var d: Array = discs[discs.size() - 1]
	var rt: float = d[2]
	return TAU * float(d[7]) * inman_shape(d, rt) * outer_h * (rt + outer_h)

## Dust as extinction per mass: Draine (2003, Table 4), R_V = 3.1 Milky Way dust, C_ext(V) =
## 4.89 × 10⁻²² cm² per H with M_H/M_dust = 90, so 2.63 × 10⁴ cm²/g, in kpc²/M☉.
const DUST_KAPPA_V := 5.492e-6
## M104's dust, De Looze et al. (2012, Table 2, standard model) at 9.2 Mpc rescaled to
## 9.55: a ring of 7.5 × 10⁶ M☉ (×(9.55/9.2)²) in four Gaussians, [R, σ (kpc), share], 20 pc
## thick; an inner exponential disc of 4.07 × 10⁵ M☉ (×(9.55/9.2)²), scale length 2 kpc.
## Peak optical depths per kpc follow in m104_dust() (κ ρ0, ρ0 = M / (area · 2h)).
const M104_RING := [[6.332, 0.498, 0.30], [8.201, 0.260, 0.18], [9.083, 0.187, 0.27], [7.111, 1.557, 0.25]]
const M104_RING_MASS := 7.5e6 * (9.55 / 9.2) * (9.55 / 9.2)
const M104_DISC_DUST := 4.07e5 * (9.55 / 9.2) * (9.55 / 9.2)
const M104_DUST_HR := 2.0 * 9.55 / 9.2
## The 20 pc slab of constant density as a sech² layer of the same column (2h = 20 pc).
const M104_DUST_H := 0.010

static func m104_dust() -> Array:
	var rings := []
	for r in M104_RING:
		var R: float = r[0]
		var sig: float = r[1]
		# ∫ 2πR' exp(−(R'−R)²/2σ²) dR' over R' > 0, by quadrature.
		var area := 0.0
		var dr := sig / 40.0
		var x := dr * 0.5
		while x < R + 8.0 * sig:
			area += TAU * x * exp(-0.5 * pow((x - R) / sig, 2.0)) * dr
			x += dr
		rings.append([R, sig, DUST_KAPPA_V * float(r[2]) * M104_RING_MASS / (area * 2.0 * M104_DUST_H)])
	var rho0 := M104_DISC_DUST / (TAU * M104_DUST_HR * M104_DUST_HR * 2.0 * M104_DUST_H)
	var disc := {"kappa": DUST_KAPPA_V, "rhoDisc": rho0, "rhoArm": 0.0, "hr": M104_DUST_HR, "hole": 0.0, "h0": M104_DUST_H,
		"h1": 0.0, "rf": 0.0, "rm": 0.0, "ra": 1.0, "ca": 1.0, "h0a": 1.0, "rfa": 0.0, "h1a": 0.0}
	return [rings, disc]

## A galaxy of TYPES as GalaxyVisual draws it.
static func type_galaxy(key: String) -> Dictionary:
	var spec: Dictionary = TYPES.get(key, {})
	if spec.is_empty(): return {}
	var pot := GalPotential.new()
	var light := []
	var model := {"key": key, "name": spec.name, "potential": pot, "sense": 1.0, "extent": spec.extent, "light": light,
		"sky": spec, "bulgeAxes": spec.get("bulgeAxes", [1.0, 1.0])}
	if spec.get("light", "") == "m51": _m51_light(model)
	var lv := pow(10.0, -0.4 * (float(spec.mv) - 4.83))
	for part in spec.get("parts", {}):
		var pp: Array = spec.parts[part]
		var pop := GalPopulation.build({"kind": "burst", "gyr": 10.0} if part == "bulge" else {"kind": "constant", "gyr": 10.0})
		var y := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
		# The stellar mass whose visible stars give this part its share of the light.
		var mass := float(pp[0]) * lv / (VISIBLE_BULGE * pop.mean_l / pop.mean_mass * y)
		var gm := GalUnits.G * mass / GalUnits.MASS_UNIT_SUN
		if part == "bulge": pot.add(GalPotential.hernquist("bulge", float(pp[1]), gm))
		else: pot.add(GalPotential.miyamoto_nagai("disc", float(pp[1]), float(pp[2]), gm))
		light.append({"part": part, "visible": VISIBLE_BULGE})
	if spec.has("arms"):
		# The arms' measured share of the light, as the young population's bolometric light.
		var young := GalPopulation.build({"kind": "constant", "gyr": MW_YOUNG_GYR})
		var yy := 0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b
		for k in ["arms", "armDecay", "armR", "armTurns", "armH", "armWidthGrowth", "armRise", "armEndFade", "armMirror"]:
			if spec.has(k): model[k] = spec[k]
		if spec.has("armShare"): model.armLight = float(spec.armShare) * lv / yy
		model.envelope = [1e9, 0.0]
	if spec.has("companions"): model.companions = spec.companions
	if spec.get("dustMap", "") == "m51":
		var dm := M51_DUST.duplicate(true)
		dm.kappa = DUST_KAPPA_V
		dm.rCR = deg_to_rad(float(M51_DUST.rCRArcmin) / 60.0) * float(spec.d)
		dm.rBreak = M51_ARM_BREAK
		model.dustMap = dm
	if spec.get("dust", "") == "m104":
		var d := m104_dust()
		model.dustRing = d[0]
		model.dustRingH = M104_DUST_H
		model.dust = d[1]
	return model

## M51's stars as M51_LIGHT has them: the bulge and old discs' masses through the population
## model (the discs as one Miyamoto–Nagai disc of the main disc's half-mass radius in the
## potential), the young discs' light as the arms', and both discs' profiles for the map.
static func _m51_light(model: Dictionary) -> void:
	var pot: GalPotential = model.potential
	var light: Array = model.light
	var bulge_pop := GalPopulation.build({"kind": "burst", "gyr": 10.0})
	var disc_spec := {"kind": "constant", "gyr": 10.0, "fromGyr": MW_YOUNG_GYR}
	var disc_pop := GalPopulation.build(disc_spec)
	var young := GalPopulation.build({"kind": "constant", "gyr": MW_YOUNG_GYR})
	var ys := 0.2126 * bulge_pop.color.r + 0.7152 * bulge_pop.color.g + 0.0722 * bulge_pop.color.b
	var yd := 0.2126 * disc_pop.color.r + 0.7152 * disc_pop.color.g + 0.0722 * disc_pop.color.b
	var yy := 0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b
	var f := log(LAMBDA_V / 4719.0) / log(6185.0 / 4719.0)
	var b: Array = M51_LIGHT.bulge
	var lb := lnu_to_lv(exp(lerpf(log(float(b[1])), log(float(b[2])), f)))
	var mb := lb / (VISIBLE_BULGE * bulge_pop.mean_l / bulge_pop.mean_mass * ys)
	pot.add(GalPotential.hernquist("bulge", float(b[0]) / 1.8153, GalUnits.G * mb / GalUnits.MASS_UNIT_SUN))
	light.append({"part": "bulge", "visible": VISIBLE_BULGE})
	var discs := []
	var thins := []
	for c in M51_LIGHT.disc: discs.append(inman_disc_v(c))
	for c in M51_LIGHT.thin: thins.append(inman_disc_v(c))
	var oh: Array = M51_LIGHT.outerH
	var ld := inman_beyond(discs, float(oh[0]))
	for d in discs: ld += float(d[6])
	var ly := inman_beyond(thins, float(oh[1]))
	for d in thins: ly += float(d[6])
	var md := ld / (VISIBLE_BULGE * disc_pop.mean_l / disc_pop.mean_mass * yd)
	var main: Array = discs[1]
	pot.add(GalPotential.miyamoto_nagai("disc", 0.9688 * float(main[4]), float(main[5]), GalUnits.G * md / GalUnits.MASS_UNIT_SUN))
	light.append({"part": "disc", "visible": VISIBLE_BULGE})
	model.discPop = disc_spec
	# Bolometric: the map holds V surface luminosity divided by each population's V per L☉.
	var contrast := []
	for c in M51_LIGHT.armContrast: contrast.append([deg_to_rad(float(c[0]) / 3600.0) * float(TYPES.m51.d), c[1]])
	model.discMap = {"discs": discs, "outerH": float(oh[0]), "z": float(main[5]), "bol": 1.0 / yd, "contrast": contrast}
	model.thinMap = {"discs": thins, "outerH": float(oh[1]), "z": float((thins[1] as Array)[5]), "bol": 1.0 / yy,
		"share": float(M51_LIGHT.armShare)}
	model.armLight = ly / yy
	model.armH = float((thins[1] as Array)[5])
	model.hii = M51_HII

static func milky_way_potential() -> GalPotential:
	return GalPotential.new() \
		.add(GalPotential.power_cutoff("bulge", 1.8, 1.9)) \
		.add(GalPotential.miyamoto_nagai("disc", 3.0, 0.28)) \
		.add(GalPotential.nfw("halo", 16.0)) \
		.normalize(MW_R0, MW_V0_KMS * GalUnits.KMS, [0.05, 0.6, 0.35])

# The bar (Dehnen 2000, as galpy has it). Pattern speed 39.0 ± 3.5 km/s/kpc from
# Portail et al. (2017); the long bar's half-length 5.0 ± 0.2 kpc and the bulge's angle
# of 27° ± 2° to the Sun–centre line, near end at positive longitude, from
# Bland-Hawthorn & Gerhard (2016, §4). Strength α = 0.01, galpy's default after Dehnen
# (2000): α = 3 A_f/v0² (Rb/R0)³.
const MW_BAR_OMEGA_KMS_KPC := 39.0
const MW_BAR_RB := 5.0
const MW_BAR_ANGLE_DEG := 27.0
const MW_BAR_ALPHA := 0.01
# The spiral (Cox & Gómez 2002): two arms with their N = 2, Rs = 7 kpc, H = 0.18 kpc and
# a density amplitude of one atomic mass per cm³ at 8 kpc. Pattern speed 28.2 ± 2.1
# km/s/kpc from Gaia DR2 open clusters (Dias et al. 2019). Pitch 12°, the mean of the
# two major arms' pitches measured from maser parallaxes, Perseus (10.3°, 8.7°) and
# Scutum–Centaurus (14.1°, 12.1°) (Reid et al. 2019, Table 2), whose Perseus crest it
# puts at R = 8.87 kpc, Galactocentric azimuth 40° from the Sun, today.
const MW_SPIRAL_OMEGA_KMS_KPC := 28.2
const MW_SPIRAL_PITCH_DEG := 12.0
const MW_SPIRAL_ANCHOR := [8.87, 40.0]
# 1.66054e-24 g cm⁻³ in M☉ pc⁻³, with M☉ = GM☉/G = 1.98841e33 g and the IAU parsec.
const AMU_CM3_MSUN_PC3 := 0.0245355
# Both grow over one bar period from tStart and run another before today (t = 0), so
# the tracers have responded when the scene opens.
const MW_T_START := -320.0
const MW_T_GROW := 160.0

# Spiral arms as measured from maser parallaxes of high-mass star-forming regions
# (Reid et al. 2019, Table 2): name, R_kink (kpc), β_kink, ψ< and ψ> (deg; pitch for
# azimuths below and above the kink), Gaussian width at the kink (kpc, growing 42 pc
# per kpc), and the azimuths measured, β_min..β_max (deg). β runs from the Sun's
# direction toward the rotation. Beyond the measured azimuths an arm is extended at
# the model's 12° pitch: an extrapolation, not a measurement. Norma and Outer are the
# inner and outer ends of one arm, so only Norma is extended; the Local arm is a spur.
# Both keep to what was measured. The 3-kpc arm, inside the bar, is left out.
const REID_2019_ARMS := [
	["Norma", 4.46, 18.0, -1.0, 19.5, 0.14, 5.0, 54.0, true],
	["Scutum–Centaurus", 4.91, 23.0, 14.1, 12.1, 0.23, 0.0, 104.0, true],
	["Sagittarius–Carina", 6.04, 24.0, 17.1, 1.0, 0.27, 2.0, 97.0, true],
	["Local", 8.26, 9.0, 11.4, 11.4, 0.31, -8.0, 34.0, false],
	["Perseus", 8.87, 40.0, 10.3, 8.7, 0.35, -23.0, 115.0, true],
	["Outer", 12.24, 18.0, 3.0, 9.4, 0.65, -16.0, 71.0, false],
]
# Stars younger than 100 Myr light the arms: 1.65 ± 0.19 M☉/yr for a Kroupa IMF
# (Licquia & Newman 2015, as Bland-Hawthorn & Gerhard 2016 quote it), in a layer 49 pc
# thick (the A0 dwarfs' sech² height, Bovy 2017), over the star-forming envelope the
# dust disc traces. The disc's own population then covers ages 0.1–10 Gyr.
const MW_SFR := 1.65
const MW_YOUNG_GYR := 0.1
const MW_YOUNG_H := 0.049
# Dust (Drimmel & Spergel 2001, Table 1, R⊙ = 8 kpc): the disc's ρ0 1098 and the arms'
# 162 MJy/sr/kpc times the V opacity 0.0180 (MJy/sr)⁻¹; scale length 2.26 kpc, height
# 134.4 pc flaring 14.8 pc/kpc past 4.40 kpc, a central hole inside R⊙/2; arms cut
# off outside 6.71 kpc on 2.07 kpc, 64.1 pc/kpc wide, 80 pc high flaring 14.6 pc/kpc²
# past 5.48 kpc (their eqs. 13–17; Gaussian across and above the arm). Extinction per channel relative to V from Rieke & Lebofsky (1985),
# which they adopt: A_R/A_V = 0.748, A_B/A_V = 1.324.
const MW_DUST := {"kappa": 0.0180, "rhoDisc": 1098.0, "rhoArm": 162.0, "hr": 2.26, "h0": 0.1344, "h1": 0.0148,
	"rf": 4.40, "hole": 4.0, "rm": 6.71, "ra": 2.07, "ca": 0.0641, "h0a": 0.080, "rfa": 5.48, "h1a": 0.0146}
const EXTINCTION_RGB := [0.748, 1.0, 1.324]
# The box/peanut bulge's axis ratios, 10 : 6.3 : 2.6 (Wegg & Gerhard 2013, via
# Bland-Hawthorn & Gerhard 2016): its light, not its mass, turns with the bar.
const MW_BULGE_AXES := [0.63, 0.26]

## The Sun's azimuth in the scene: it sits at (−R0, 0, 0). A Galactocentric azimuth β
## measured from the Sun toward the rotation (Reid et al.) is φ = π + β.
static func mw_patterns() -> Array:
	var v0 := MW_V0_KMS * GalUnits.KMS
	var af := MW_BAR_ALPHA * v0 * v0 * pow(MW_R0 / MW_BAR_RB, 3.0) / 3.0
	var bar := GalPattern.bar(MW_BAR_OMEGA_KMS_KPC * GalUnits.KMS, PI + deg_to_rad(MW_BAR_ANGLE_DEG),
		MW_BAR_RB, af, MW_T_START, MW_T_GROW)
	var pitch := deg_to_rad(MW_SPIRAL_PITCH_DEG)
	var rho0 := AMU_CM3_MSUN_PC3 * 1e9 / GalUnits.MASS_UNIT_SUN
	var amp := 4.0 * PI * GalUnits.G * 0.18 * rho0
	# γ = 0 at the anchor: φp = φ + ln(R/r0)/tan α.
	var anchor_phi: float = PI + deg_to_rad(float(MW_SPIRAL_ANCHOR[1]))
	var angle0: float = anchor_phi + log(float(MW_SPIRAL_ANCHOR[0]) / MW_R0) / tan(pitch)
	var spiral := GalPattern.spiral(MW_SPIRAL_OMEGA_KMS_KPC * GalUnits.KMS, angle0, 2, pitch, MW_R0, 7.0, 0.18,
		amp, MW_T_START, MW_T_GROW)
	return [bar, spiral]

## A model: its potential, tracer populations and light. `seed` fixes every draw;
## `patterns = false` leaves out the bar and spiral (galaxycheck's static runs).
static func build(key: String, seed := 1, patterns := true) -> Dictionary:
	if TYPES.has(key): return type_galaxy(key)
	match key:
		"milky_way":
			return {
				"key": key, "name": "Milky Way", "seed": seed,
				"potential": milky_way_potential(),
				"patterns": mw_patterns() if patterns else [],
				"tStart": MW_T_START if patterns else 0.0,
				"r0": MW_R0,
				# Rotation sense: the Galaxy turns clockwise seen from the north galactic
				# pole (+Y), so a star's azimuth from +X toward +Z grows.
				"sense": 1.0,
				"extent": 30.0,
				"populations": [
					# Kalberla & Dedes (2008): HI surface density roughly flat inside ~12.5 kpc,
					# then exponential with a 3.75 kpc scale length to ~30 kpc; the cold
					# neutral medium's dispersion is 6.1 km/s (their Table 1).
					{"name": "gas", "kind": "gas", "count": 2000, "rmin": 2.0, "rmax": 30.0,
						"flatTo": 12.5, "scale": 3.75, "sigmaKms": 6.1},
					# Bland-Hawthorn & Gerhard (2016): the old thin disc has σR = 35 ± 5 and
					# σz = 25 ± 5 km/s at R0, falling outward on 2 Rd with Rd = 2.6 kpc (their
					# Table 5, Binney & Piffl 2015). Positions sample the model disc's own density.
					# Inside 4 kpc the bar rules and the extrapolated σR passes 70 km/s, so the
					# axisymmetric disc starts there.
					{"name": "thin disc", "kind": "disc", "part": "disc", "count": 4000, "rmin": 4.0, "rmax": 20.0,
						"sigmaRKms": 35.0, "sigmaZKms": 25.0, "rSigma": 5.2, "rRef": 8.2},
				],
				"light": [
					{"part": "disc", "visible": VISIBLE_DISC},
					{"part": "bulge", "visible": VISIBLE_BULGE},
				],
				"arms": REID_2019_ARMS if patterns else [],
				"sfr": MW_SFR if patterns else 0.0,
				"dust": MW_DUST if patterns else {},
				"bulgeAxes": MW_BULGE_AXES if patterns else [1.0, 1.0],
			}
	return {}
