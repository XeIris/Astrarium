class_name GalModels
extends RefCounted

# The modelled galaxies, as data: a potential, the tracer populations that sample
# it, and how its light follows its mass. Sources per value in
# docs/physics/galaxies.md; nothing here is tuned to look right.

## The scenarios of the galactic scene, in the order the list shows them.
const ORDER := ["gal_milkyway", "gal_m51", "gal_m104", "gal_m87", "gal_mw_m31", "gal_antennae", "gal_pro_retro"]

const PRESETS := {
	"gal_milkyway": {
		"name": "Milky Way",
		"blurb": "Our galaxy as Bovy's MWPotential2014: a bulge, a Miyamoto–Nagai disc and an NFW dark halo, fitted to measured Milky Way kinematics. Thousands of test stars and cold-gas clouds orbit in it. Its rotation curve is measured live from them, beside the one Gaia and APOGEE measured.",
		"model": "milky_way",
		"camRadius": 60.0,
		"camTheta": 0.95,
		"rateMyrS": 5.0,
	},
	"gal_antennae": {
		"name": "The Antennae",
		"blurb": "NGC 4038 and 4039 in Corvus, as Privon et al. (2013) reconstructed them from their tails' shapes and H I velocities: two equal spirals on a parabolic orbit, both turning the way they move. They pass about 6 kpc apart 150 Myr in and throw out two long tails. Privon's model sees them as they are today at 408 Myr, around their second pass, as they merge.",
		"model": "antennae", "camRadius": 160.0, "camTheta": 1.5707963, "rateMyrS": 20.0,
	},
	"gal_pro_retro": {
		"name": "Prograde and retrograde",
		"blurb": "Two identical spirals on the same parabolic orbit, seen from above it. One spins the way the orbit turns, the other against it. Toomre & Toomre (1972) showed what follows: the prograde disc, whose stars keep pace with the passing companion, is torn into a long tail and a bridge; the retrograde one barely notices.",
		"model": "pro_retro", "camRadius": 140.0, "camTheta": 1.5707963, "rateMyrS": 20.0,
	},
	"gal_mw_m31": {
		"name": "Milky Way meets M31",
		"blurb": "The Milky Way, Andromeda and M33 from today, as van der Marel et al. (2012) set them out from Hubble's measurement of M31's motion: about 4 billion years to a first pass, dynamical friction drawing them together. Recent measurements make a merger only about even odds (Sawala et al. 2025).",
		"model": "vdm_canonical", "camRadius": 900.0, "camTheta": 0.9, "rateMyrS": 100.0,
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
	# Its two inner arms (Smercina et al. 2023, PHATTER, from resolved stars of every age): log
	# spirals of pitch 23.78° through R0 0.90 kpc, 155–160° apart in phase (157.5° here), traced
	# to 3.2 kpc (Javadi et al. 2017); they wind counterclockwise outward on the sky, and their
	# phase was set by laying them over ESO's image (eso1424a). Their width (σ 0.3 kpc), start
	# and fade past 3.2 kpc are set by eye. M33_LIGHT gives them their light.
	"m33": {"name": "Triangulum (M33)", "ra": 23.46204167, "dec": 30.66022222, "d": 809.0, "i": 53.84, "pa": 23.0,
		"disc": [4.8e9, 1.744, 0.1], "extent": 15.0, "mv": -18.8,
		"arms": [["South", 0.90, 0.0, 23.78, 23.78, 0.3, -165.7, 0.0, false], ["North", 0.90, 157.5, 23.78, 23.78, 0.3, 157.5 - 165.7, 157.5, false]],
		"armR": [0.3, 12.0], "armTurns": 1, "armWidthGrowth": 0.0, "armRise": [0.6, 0.6], "armEndFade": 0.6},
	# van der Marel, Kallivayalil & Besla (2009): stars 2.7 × 10⁹ M☉; van der Marel (2001):
	# exponential, scale length 1.3–1.5 kpc (1.4 here); Pietrzyński et al. (2019): 49.59 kpc.
	# i 25.86°, line of nodes 149.23° (Choi et al. 2018a), the frame its bar was measured in.
	# The bar (Rathore et al. 2024, completeness-corrected Gaia DR3 red clump): axis ratio 0.54,
	# PA 121.26° on the sky, peak bi-symmetric amplitude A2 0.27, and A2 falling to half its peak
	# at 2.58 kpc (their AM1 radius; 2.13 kpc by the m = 2 phase, which a straight model bar
	# cannot show). Drawn as a Ferrers (1 − m²)² bar: its share of the disc's light is solved so
	# the map's peak A2 is 0.27, and its 3.25 kpc length set so A2 halves at 2.58 kpc. Its 0.76
	# kpc offset from the disc's centre, and the lopsided arm on its western end, are not drawn. Its thickness,
	# b = 0.2 a, is a rendering choice: van der Marel et al. (2002) find a thick disc, V/σ ≈ 2.9.
	"lmc": {"name": "Large Magellanic Cloud", "ra": 80.89416667, "dec": -69.75611111, "d": 49.59, "i": 25.86, "pa": 149.23,
		"disc": [2.7e9, 1.356, 0.27], "extent": 12.0, "mv": -18.1, "bar": [3.25, 0.54, 121.26, 0.27]},
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
	if spec.has("arms") and not from_mass: _m33_light(model, spec)
	if spec.has("bar"):
		# The disc in the map as the exponential it stands in for, with its bar (GalaxyVisual).
		var pop := GalPopulation.build({"kind": "constant", "gyr": 10.0})
		var yd := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
		var b: Array = spec.bar
		model.discMap = {"exp": spec.disc[1] / 0.9688, "z": spec.disc[2], "bol": 1.0 / yd,
			"bar": [b[0], b[1], bar_angle(spec, float(b[2])), b[3]]}
	return model

# M33's light split at one star formation rate into the stars of the last 100 Myr and the rest,
# the whole at its measured V: the rate this implies is reported, not imposed (estimates span
# 0.2 to over 0.5 M☉/yr with the tracer). The young light is gathered into the arms so its
# normalised m = 2 amplitude over 1–3.2 kpc is 0.6, the middle of the 0.4–0.8 M33 shows in Hα
# and dust (Combes et al. 2012, HERM33ES); old and young both as exponentials of the disc's
# scale length, 0.1 kpc thick.
const M33_LIGHT := {"a2": 0.6, "a2R": [1.0, 3.2], "youngGyr": 0.1}

static func _m33_light(model: Dictionary, spec: Dictionary) -> void:
	var tg := float(M33_LIGHT.youngGyr)
	var old_spec := {"kind": "constant", "gyr": 10.0, "fromGyr": tg}
	var old := GalPopulation.build(old_spec)
	var young := GalPopulation.build({"kind": "constant", "gyr": tg})
	var yo := 0.2126 * old.color.r + 0.7152 * old.color.g + 0.0722 * old.color.b
	var yy := 0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b
	var lv := pow(10.0, -0.4 * (float(spec.mv) - 4.83))
	# Light at one rate: light per mass formed times the mass formed in each span.
	var sfr := lv / (old.light_per_formed * (10.0 - tg) * 1e9 * yo + young.light_per_formed * tg * 1e9 * yy)
	var l_old := sfr * (10.0 - tg) * 1e9 * old.light_per_formed
	var d: Dictionary = (model.potential as GalPotential).part("disc")
	var m_disc := float(d.gm) / GalUnits.G * GalUnits.MASS_UNIT_SUN
	for l in model.light:
		if l.part == "disc": l.visible = l_old / (m_disc * old.mean_l / old.mean_mass)
	model.discPop = old_spec
	model.armLight = sfr * tg * 1e9 * young.light_per_formed
	model.sfr = sfr
	for k in ["arms", "armR", "armTurns", "armWidthGrowth", "armRise", "armEndFade"]: model[k] = spec[k]
	model.youngGyr = tg
	model.envelope = [1e9, 0.0]
	var h := float(spec.disc[1]) / 0.9688
	model.armH = float(spec.disc[2])
	model.discMap = {"exp": h, "z": float(spec.disc[2]), "bol": 1.0 / yo}
	model.thinMap = {"exp": h, "z": float(spec.disc[2]), "bol": 1.0 / yy, "a2": M33_LIGHT.a2, "a2R": M33_LIGHT.a2R}

## The angle (rad) in a disc's plane, from its line of nodes, of a direction seen at position
## angle `pa_deg` on the sky: deprojected through the disc's own axes (GalLandmarks.sky_basis).
static func bar_angle(spec: Dictionary, pa_deg: float) -> float:
	var sk := GalLandmarks.sky_basis(float(spec.ra), float(spec.dec), float(spec.i), float(spec.pa))
	var basis: Basis = sk[1]
	# North and east as sky_basis takes them.
	var e := 0.5
	var ra := float(spec.ra)
	var dec := float(spec.dec)
	var north := (GalLandmarks.sky_direction(ra, dec + e) - GalLandmarks.sky_direction(ra, dec - e)).normalized()
	var east := (GalLandmarks.sky_direction(ra + e / cos(deg_to_rad(dec)), dec) - GalLandmarks.sky_direction(ra - e / cos(deg_to_rad(dec)), dec)).normalized()
	var best := 0.0
	var err := INF
	for k in 36000:
		var psi := TAU * float(k) / 36000.0
		var w := basis.x * cos(psi) + basis.z * sin(psi)
		# A bar is a line: its position angle is taken modulo 180°.
		var pa := fposmod(rad_to_deg(atan2(w.dot(east), w.dot(north))), 180.0)
		var d := absf(fposmod(pa - pa_deg + 90.0, 180.0) - 90.0)
		if d < err:
			err = d
			best = psi
	return best

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
	# M87 (Kormendy et al. 2009): D 17.22 Mpc, M_VT −22.95; its light is M87_PROFILE. E1, drawn
	# round.
	"m87": {"name": "M87", "ra": 187.7059308, "dec": 12.39112326, "d": 17220.0, "mv": -22.95,
		"light": "m87", "extent": 470.0},
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
# M87's measured V surface brightness (Kormendy et al. 2009, Table 3: composite photometry
# along the major axis): [r (″), μ_V (mag arcsec⁻²), ellipticity]; no ellipticity is given at
# the first point. The table is not corrected for the Galaxy's A_V = 0.072 (their Table 1),
# which it integrates to M_VT within 0.01 mag once it is. Drawn round on the circularised
# radius r √(1 − ε), as the light density whose projection it is (an Abel inversion). Past the
# last point (155 kpc) it carries on as their Sérsic fit does (n 11.84, r_e 703.91″ on the major
# axis, circularised with the last point's ε), joined there: in the inversion to 20 times,
# drawn to 3 times, so a sight line through the outer halo holds its light. The last segment's
# own slope, I ∝ R^−1.3 at μ_V ≈ 28, is too shallow to carry on.
const M87_AV := 0.072
const M87_SERSIC := [11.84, 703.91]
const M87_PROFILE := [
	[0.017, 16.266, 0.0],
	[0.044, 16.358, 0.16],
	[0.088, 16.511, 0.161],
	[0.176, 16.589, 0.161],
	[0.22, 16.646, 0.161],
	[0.264, 16.7, 0.162],
	[0.308, 16.746, 0.162],
	[0.352, 16.788, 0.162],
	[0.396, 16.838, 0.138],
	[0.44, 16.889, 0.131],
	[0.484, 16.927, 0.118],
	[0.548, 16.953, 0.109],
	[0.604, 16.966, 0.097],
	[0.66, 16.996, 0.094],
	[0.727, 17.031, 0.084],
	[0.795, 17.062, 0.09],
	[0.867, 17.091, 0.087],
	[0.95, 17.114, 0.079],
	[1.038, 17.134, 0.075],
	[1.147, 17.165, 0.071],
	[1.254, 17.195, 0.072],
	[1.365, 17.21, 0.049],
	[1.515, 17.241, 0.03],
	[1.669, 17.27, 0.023],
	[1.825, 17.29, 0.015],
	[1.998, 17.318, 0.007],
	[2.196, 17.346, 0.018],
	[2.419, 17.371, 0.015],
	[2.64, 17.399, 0.012],
	[2.835, 17.418, 0.008],
	[3.218, 17.47, 0.005],
	[3.823, 17.538, 0.012],
	[4.546, 17.613, 0.01],
	[5.413, 17.715, 0.017],
	[6.092, 17.79, 0.021],
	[7.118, 17.913, 0.028],
	[7.78, 17.991, 0.023],
	[8.61, 18.086, 0.028],
	[9.441, 18.183, 0.02],
	[10.304, 18.277, 0.026],
	[11.552, 18.409, 0.03],
	[12.322, 18.489, 0.026],
	[13.715, 18.622, 0.03],
	[15.109, 18.749, 0.03],
	[16.615, 18.879, 0.032],
	[18.249, 19.009, 0.036],
	[19.971, 19.143, 0.036],
	[21.945, 19.284, 0.04],
	[23.961, 19.415, 0.043],
	[26.318, 19.56, 0.05],
	[29.04, 19.716, 0.051],
	[31.75, 19.86, 0.052],
	[35.015, 20.016, 0.059],
	[38.371, 20.161, 0.064],
	[42.073, 20.318, 0.072],
	[45.779, 20.455, 0.076],
	[50.855, 20.631, 0.078],
	[56.04, 20.794, 0.082],
	[61.094, 20.936, 0.086],
	[67.531, 21.097, 0.096],
	[72.277, 21.217, 0.1],
	[77.179, 21.331, 0.099],
	[84.918, 21.499, 0.109],
	[93.972, 21.693, 0.114],
	[104.954, 21.912, 0.128],
	[116.011, 22.116, 0.139],
	[127.938, 22.317, 0.153],
	[139.798, 22.515, 0.157],
	[154.17, 22.714, 0.171],
	[166.341, 22.87, 0.185],
	[180.926, 23.019, 0.206],
	[200.909, 23.22, 0.222],
	[222.587, 23.42, 0.237],
	[242.103, 23.573, 0.254],
	[265.053, 23.742, 0.275],
	[293.99, 23.934, 0.293],
	[321.366, 24.096, 0.303],
	[346.737, 24.257, 0.313],
	[381.651, 24.441, 0.329],
	[419.276, 24.658, 0.337],
	[462.914, 24.82, 0.348],
	[502.343, 25.011, 0.37],
	[541.377, 25.09, 0.381],
	[593.608, 25.288, 0.388],
	[653.131, 25.486, 0.398],
	[719.449, 25.697, 0.427],
	[794.328, 25.917, 0.447],
	[878.348, 26.1, 0.454],
	[946.237, 26.328, 0.447],
	[1046.325, 26.62, 0.457],
	[1145.513, 26.848, 0.464],
	[1230.269, 26.995, 0.454],
	[1336.595, 27.18, 0.443],
	[1479.109, 27.305, 0.439],
	[1621.81, 27.535, 0.436],
	[1778.279, 27.715, 0.433],
	[1995.262, 27.755, 0.429],
	[2443.7, 28.045, 0.422],
]
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
	if spec.get("light", "") == "m87": _m87_light(model)
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

## M87's light as M87_PROFILE has it: ln j (bolometric L☉ kpc⁻³) on SPHERE_TAB_N radii even in
## ln r out to 3 times the last point; its mass through the population model, held in the potential as a
## Hernquist sphere of the same mass and half-mass radius (a = r_half/(1 + √2)).
const SPHERE_TAB_N := 256
const SPHERE_TAB_R0 := 1e-3
static func _m87_light(model: Dictionary) -> void:
	var spec: Dictionary = model.sky
	var prof := m87_surface(float(spec.d))
	var R: PackedFloat64Array = prof[0]
	var lnI: PackedFloat64Array = prof[1]
	var rmax := 3.0 * R[R.size() - 1]
	var pop := GalPopulation.build({"kind": "burst", "gyr": 10.0})
	var y := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
	var d := log(rmax / SPHERE_TAB_R0) / float(SPHERE_TAB_N - 1)
	var lnj := PackedFloat32Array()
	lnj.resize(SPHERE_TAB_N)
	for k in SPHERE_TAB_N:
		var r := SPHERE_TAB_R0 * exp(float(k) * d)
		lnj[k] = log(maxf(abel(R, lnI, r, prof[2]) / y, 1e-30))
	# Light and mass within each radius, from the table as drawn.
	var lb := 0.0
	var cum := PackedFloat64Array()
	cum.resize(SPHERE_TAB_N)
	for k in range(1, SPHERE_TAB_N):
		var r0 := SPHERE_TAB_R0 * exp(float(k - 1) * d)
		var r1 := SPHERE_TAB_R0 * exp(float(k) * d)
		lb += 0.5 * (exp(lnj[k - 1]) * r0 * r0 + exp(lnj[k]) * r1 * r1) * 4.0 * PI * (r1 - r0)
		cum[k] = lb
	var r_half := rmax
	for k in SPHERE_TAB_N:
		if cum[k] >= 0.5 * lb:
			r_half = SPHERE_TAB_R0 * exp(float(k) * d)
			break
	var mass := lb / (VISIBLE_BULGE * pop.mean_l / pop.mean_mass)
	(model.potential as GalPotential).add(GalPotential.hernquist("bulge", r_half / (1.0 + sqrt(2.0)), GalUnits.G * mass / GalUnits.MASS_UNIT_SUN))
	model.light.append({"part": "bulge", "visible": VISIBLE_BULGE})
	model.sphereTable = {"lnr0": log(SPHERE_TAB_R0), "dlnr": d, "lnj": lnj, "rmax": rmax}

## M87_PROFILE as V surface luminosity (L☉ kpc⁻²) on circularised radius (kpc): [R, ln I].
static func m87_surface(d_kpc: float) -> Array:
	var kpc_as := d_kpc * PI / (180.0 * 3600.0)
	var R := PackedFloat64Array()
	var lnI := PackedFloat64Array()
	for row in M87_PROFILE:
		R.append(float(row[0]) * kpc_as * sqrt(1.0 - float(row[2])))
		# μ = M☉ + 21.572 − 2.5 log₁₀(I in L☉ pc⁻²); 21.572 = 5 log₁₀(206265″/10 pc).
		lnI.append(-0.4 * (float(row[1]) - M87_AV - 4.83 - 21.572) * log(10.0) + log(1e6))
	# Ciotti & Bertin's (1999) b_n, to 1/n².
	var n := float(M87_SERSIC[0])
	var b := 2.0 * n - 1.0 / 3.0 + 4.0 / (405.0 * n) + 46.0 / (25515.0 * n * n)
	var last: Array = M87_PROFILE[M87_PROFILE.size() - 1]
	var re := float(M87_SERSIC[1]) * kpc_as * sqrt(1.0 - float(last[2]))
	return [R, lnI, [n, b, re]]

## ln I at R, linear in ln R between points; beyond, the Sérsic profile `sersic` = [n, b_n, r_e]
## joined at the last point, or without one the last slope.
static func lnI_at(R: PackedFloat64Array, lnI: PackedFloat64Array, x: float, sersic := []) -> float:
	var lx := log(x)
	if x <= R[0]: return lnI[0]
	var n := R.size()
	var k := R.bsearch(x)
	if k < n:
		var t := (lx - log(R[k - 1])) / (log(R[k]) - log(R[k - 1]))
		return lerpf(lnI[k - 1], lnI[k], t)
	if not sersic.is_empty():
		var sn: float = sersic[0]
		return lnI[n - 1] - float(sersic[1]) * (pow(x / float(sersic[2]), 1.0 / sn) - pow(R[n - 1] / float(sersic[2]), 1.0 / sn))
	return lnI[n - 1] + (lnI[n - 1] - lnI[n - 2]) / (log(R[n - 1]) - log(R[n - 2])) * (lx - log(R[n - 1]))

## The light density whose projection is I(R): j(r) = −(1/π) ∫_r^∞ I′(R) dR / √(R² − r²), with
## R = r cosh u, out to 20 times the last point, I beyond it as lnI_at continues it.
static func abel(R: PackedFloat64Array, lnI: PackedFloat64Array, r: float, sersic := []) -> float:
	var umax := acosh(20.0 * R[R.size() - 1] / r)
	var n := 600
	var s := 0.0
	for k in n:
		var u := (float(k) + 0.5) * umax / float(n)
		var x := r * cosh(u)
		var h := x * 1e-4
		s += (exp(lnI_at(R, lnI, x + h, sersic)) - exp(lnI_at(R, lnI, x - h, sersic))) / (2.0 * h) * umax / float(n)
	return -s / PI

## Encounters (GalOrbits): each galaxy [name, M_vir (M☉), concentration, position (kpc), velocity
## (km/s)] in the Galactocentric frame.
## The Milky Way, M31 and M33 as van der Marel et al. (2012b, Table 2) start their canonical
## N-body model: the present positions and velocities from their paper II, M_vir 1.5 × 10¹² M☉
## for both large galaxies (c 9.56) and 1.5 × 10¹¹ for M33 (c 11.37, from Klypin et al. 2011);
## the M31 position is §3.4's. Their N-body result: M31's next pericentre 35.0 kpc at 3.97 Gyr,
## apocentre 171.9 kpc at 4.79 Gyr, merger by 6.29 Gyr; M33's pericentre on M31 79.6 kpc at
## 0.92 Gyr, which their semi-analytic orbits put at 80.3 kpc at 0.93 Gyr (Appendix A).
const VDM_CANONICAL := [
	["Milky Way", 1.5e12, 9.56, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0]],
	["M31", 1.5e12, 9.56, [-378.9, 612.7, -283.1], [72.6, -69.7, 50.9]],
	["M33", 0.15e12, 11.37, [-476.1, 491.1, -412.9], [43.1, 101.3, 138.8]],
]

## Their galaxies' stars (van der Marel et al. 2012b, Tables 1–2): disc mass and exponential
## scale length, bulge mass and R^1/4 effective radius (a Hernquist sphere of a = R_e/1.8153
## here), and spin in the Galactocentric frame: the Milky Way's (0, 0, −1) and M31's
## (−0.412, −0.767, −0.492) as their §3.2 states them, M33's from its Table 1 geometry
## (VDM_M33_GEOMETRY, disc_spin). The halo is M_vir less disc and bulge, as their N-body haloes
## are. A disc's rigid potential is Miyamoto–Nagai of the exponential's half-mass radius
## (a = 0.9688 R_d), 0.1 R_d thick, and its stars sech² of the same scale: a choice.
const VDM_STARS := {
	"Milky Way": [7.5e10, 3.0, 1.0e10, 0.6, [0.0, 0.0, -1.0]],
	"M31": [1.2e11, 5.0, 1.9e10, 1.0, [-0.412, -0.767, -0.492]],
	"M33": [9.0e9, 1.3, 0.0, 0.0, []],
}
## M33's disc on the sky (their Table 1: inclination and line of nodes from Corbelli &
## Schneider 1997, near side from Corbelli & Walterbos 2007), at LOCAL_GROUP's position.
const VDM_M33_GEOMETRY := {"i": 52.9, "pa": 4.0, "near": "W", "approaching": "N"}
## Particles once live: stars of one mass and haloes of another (M☉), and their Plummer
## softenings (kpc). docs/physics/galaxies.md#live says how they were set.
const LIVE_STAR_MASS := 4.0e6
const LIVE_HALO_MASS := 4.0e7
const LIVE_STAR_EPS := 0.1
const LIVE_HALO_EPS := 1.0
## The separation of the Milky Way and M31 (kpc) at which the encounter goes live.
const VDM_LIVE_AT := 250.0

## The spin of a disc seen on the sky at (ra, dec) (degrees, J2000) with inclination and line of
## nodes (PA east of north), its near side and approaching side as compass points, in the
## Galactocentric frame (x toward the Galactic centre, z to the north Galactic pole). The
## galactic axes come from the pole and centre sim/sky.gd states.
static func disc_spin(ra: float, dec: float, inc: float, pa: float, near: String, approaching: String) -> Vector3:
	var zg := _radec(192.85948, 27.12825)
	var xg := _radec(266.40500, -28.93617)
	xg = (xg - zg * xg.dot(zg)).normalized()
	var yg := zg.cross(xg)
	var s := _radec(ra, dec)
	var a := deg_to_rad(ra)
	var d := deg_to_rad(dec)
	var north := Vector3(-sin(d) * cos(a), -sin(d) * sin(a), cos(d))
	var east := Vector3(-sin(a), cos(a), 0.0)
	var compass := {"N": north, "S": -north, "E": east, "W": -east}
	var m := north * cos(deg_to_rad(pa)) + east * sin(deg_to_rad(pa))
	var nr := Vector3.ZERO
	for c in near: nr += compass[c]
	var p := (nr - m * nr.dot(m)).normalized()
	var i := deg_to_rad(inc)
	# The disc's minor axis runs toward the near side and toward us.
	var minor := p * cos(i) - s * sin(i)
	var spin := m.cross(minor).normalized()
	var ap := Vector3.ZERO
	for c in approaching: ap += compass[c]
	var side := m if ap.dot(m) > 0.0 else -m
	if spin.cross(side).dot(s) > 0.0: spin = -spin
	return Vector3(spin.dot(xg), spin.dot(yg), spin.dot(zg))

static func _radec(ra: float, dec: float) -> Vector3:
	var a := deg_to_rad(ra)
	var d := deg_to_rad(dec)
	return Vector3(cos(d) * cos(a), cos(d) * sin(a), sin(d))

static func vdm_spin(name: String) -> Vector3:
	var sp: Array = VDM_STARS[name][4]
	if not sp.is_empty(): return Vector3(sp[0], sp[1], sp[2])
	var g: Dictionary = LOCAL_GROUP["m33"]
	var m: Dictionary = VDM_M33_GEOMETRY
	return disc_spin(float(g.ra), float(g.dec), float(m.i), float(m.pa), String(m.near), String(m.approaching))

## The canonical encounter, its particle counts scaled by `scale` (1 for the scene).
static func vdm_encounter(scale := 1.0, seed := 1) -> GalEncounter:
	var e := GalEncounter.new(encounter(VDM_CANONICAL))
	for i in VDM_CANONICAL.size(): vdm_galaxy(e, i, VDM_CANONICAL[i], scale, seed)
	e.live_at = VDM_LIVE_AT
	return e

## Galaxy i of an encounter, row as VDM_CANONICAL's, as van der Marel et al. built theirs: its
## rigid potential, its disc and bulge stars and its halo particles in waiting.
static func vdm_galaxy(e: GalEncounter, i: int, row: Array, scale: float, seed: int) -> void:
	var g := GalUnits.G / GalUnits.MASS_UNIT_SUN
	var st: Array = VDM_STARS[row[0]]
	var md := float(st[0])
	var rd := float(st[1])
	var mb := float(st[2])
	var ab := float(st[3]) / 1.8153
	var halo := GalOrbits.hernquist_halo(float(row[1]) - md - mb, float(row[2]))
	e.set_galaxy(i, [halo[0], halo[1]], [md, 0.9688 * rd, 0.1 * rd], [mb, ab if mb > 0.0 else 1.0], vdm_spin(String(row[0])))
	var pot := [["hernquist", g * float(halo[0]), float(halo[1])], ["disc", g * md, rd]]
	if mb > 0.0: pot.append(["hernquist", g * mb, ab])
	e.seed_disc(i, maxi(int(md / LIVE_STAR_MASS * scale), 1), md, rd, 0.1 * rd, LIVE_STAR_EPS, seed * 16 + i)
	if mb > 0.0:
		var bulge := GalEddington.new(g * mb, ab, 50.0 * ab, pot)
		e.seed_bulge(i, maxi(int(mb / LIVE_STAR_MASS * scale), 1), mb, bulge, LIVE_STAR_EPS, seed * 16 + 4 + i)
	# The halo is cut at its virial radius, where the Hernquist mass matches the NFW's.
	var rvir := float(halo[2])
	var mh := float(halo[0]) * pow(rvir / (rvir + float(halo[1])), 2.0)
	var hs := GalEddington.new(g * float(halo[0]), float(halo[1]), rvir, pot)
	e.seed_halo(i, maxi(int(mh / LIVE_HALO_MASS * scale), 1), mh, hs, LIVE_HALO_EPS, seed * 16 + 8 + i)

## The Antennae (NGC 4038/4039) as Privon et al. (2013, Table 2) matched them: two equal
## galaxies on a parabolic orbit (e 1) of pericentre p 0.25, disc spins (i, ω) (65°, 345°) for
## NGC 4038 and (70°, 95°) for NGC 4039, seen at t 5.62 after starting at 0 with the idealised
## pericentre at 2, scaled by L 19.7 kpc and V 265 km/s (G = 1). Each galaxy is Barnes &
## Hibbard's (2009, eq. B14) model, which Privon et al. used: a Hernquist bulge, an exponential
## disc and a tapered NFW halo of masses 0.0625, 0.1875 and 1.0.
const ANTENNAE := {"L": 19.7, "V": 265.0, "p": 0.25, "t_peri": 2.0, "t_now": 5.62,
	"discs": [["NGC 4038", 65.0, 345.0], ["NGC 4039", 70.0, 95.0]], "view": [-20.0, 283.0, -5.0]}
## Toomre & Toomre's (1972) demonstration on the same galaxies and orbit: one disc spinning
## with the orbit in its plane (i 0, prograde) and one against it (i 180, retrograde), seen
## down the orbit's axis. Half Privon's particles, so it runs twice as fast.
const PRO_RETRO := {"L": 19.7, "V": 265.0, "p": 0.25, "t_peri": 2.0,
	"discs": [["Prograde", 0.0, 0.0], ["Retrograde", 180.0, 0.0]], "view": [0.0, 0.0, 0.0], "scale": 0.5}
const IDENTIKIT := {"antennae": ANTENNAE, "pro_retro": PRO_RETRO}
const BH09 := {"mb": 0.0625, "ab": 0.02, "bb": 4.0, "md": 0.1875, "ad": 1.0 / 12.0, "zd": 0.0075,
	"mh_a": 0.16, "ah": 0.25, "bh": 0.98015, "eps": 0.0075, "q_sigma": 0.075}
## Privon et al.'s self-consistent runs: 8k bulge, 24k disc and 32k halo particles a galaxy.
const ANTENNAE_COUNTS := [8192, 24576, 32768]
## Their models' step, 1/256 of a time unit (BH09 App. B), here ~0.28 Myr: the bulges are
## small and dense.
const ANTENNAE_DT := 0.25

## The parabolic relative orbit of two galaxies of G M_total = mu, pericentre p, t after
## pericentre (Barker's equation): [position, velocity] of 2 relative to 1, the pericentre on x
## and the angular momentum on z.
static func parabolic(mu: float, p: float, t: float) -> Array:
	var k := sqrt(mu / (2.0 * p * p * p))
	# D + D³/3 = k t; Newton from D = cbrt(3 k t).
	var w := k * t
	var d := signf(w) * pow(absf(3.0 * w), 1.0 / 3.0)
	for i in 60: d -= (d + d * d * d / 3.0 - w) / (1.0 + d * d)
	var dd := k / (1.0 + d * d)
	return [Vector3(p * (1.0 - d * d), 2.0 * p * d, 0.0), Vector3(-2.0 * p * d * dd, 2.0 * p * dd, 0.0)]

## A disc's spin from its inclination to the orbit and argument of periapsis (Barnes 2011,
## Identikit 2 §1), in the orbit's frame (angular momentum on z): the ascending node lies ω
## behind the direction to the companion at periapsis, and the spin tilts by i from z about it.
## Their papers do not spell out the signs; this reading, with the view below, is the one that
## reproduces Privon et al.'s Fig. 6: both tails' places on the sky and the signs of their
## line-of-sight velocities. docs/physics/galaxies.md#the-antennae.
static func identikit_spin(inc: float, omega: float, to_companion: Vector3) -> Vector3:
	var z := Vector3(0, 0, 1)
	var node := to_companion.rotated(z, -deg_to_rad(omega))
	var i := deg_to_rad(inc)
	return z * cos(i) + z.cross(node) * sin(i)

## Privon et al.'s view: the orbit's frame turned by R_x(θX) R_y(θY) R_z(θZ) onto the sky's
## (X east, Y north, Z away from us), then onto the scene's, where the default camera looks
## down −Z with north up and east on the left: a half turn about Y. Of the Euler orders tried,
## this one puts the tails nearest the particles of their Fig. 6a.
static func antennae_frame(spec: Dictionary = ANTENNAE) -> Basis:
	var v: Array = spec.view
	var m := Basis(Vector3(1, 0, 0), deg_to_rad(v[0])) * Basis(Vector3(0, 1, 0), deg_to_rad(v[1])) * Basis(Vector3(0, 0, 1), deg_to_rad(v[2]))
	return Basis(Vector3(0, 1, 0), PI) * m

## The Antennae encounter as seen from the Sun (antennae_frame), particle counts scaled by
## `scale`.
static func antennae(scale := 1.0, seed := 1) -> GalEncounter:
	return identikit(ANTENNAE, scale, seed)

## An encounter of two of Barnes & Hibbard's galaxies as an Identikit spec sets it out (spec as
## ANTENNAE), seen as its view puts it.
static func identikit(spec: Dictionary, scale := 1.0, seed := 1) -> GalEncounter:
	var A: Dictionary = spec
	var g: Dictionary = BH09
	var lu := float(A.L)
	var vu := float(A.V) * GalUnits.KMS
	# G = 1 in their units: G M_unit = V² L, and a time unit is L / V.
	var gm_unit := vu * vu * lu
	var m_unit_sun := gm_unit / GalUnits.G * GalUnits.MASS_UNIT_SUN
	var m_gal := float(g.mb) + float(g.md) + 1.0
	var orb := parabolic(2.0 * m_gal, float(A.p), -float(A.t_peri))
	var q := antennae_frame(spec)
	var rel: Vector3 = q * (orb[0] * lu)
	var vrel: Vector3 = q * (orb[1] * vu)
	var o := GalOrbits.new()
	o.friction = false
	o.add(String(A.discs[0][0]), m_gal * m_unit_sun, float(g.ah) * lu, -rel * 0.5, -vrel * 0.5)
	o.add(String(A.discs[1][0]), m_gal * m_unit_sun, float(g.ah) * lu, rel * 0.5, vrel * 0.5)
	var e := GalEncounter.new(o)
	e.live_dt = ANTENNAE_DT
	for i in 2:
		var d: Array = A.discs[i]
		var to_companion := Vector3(1, 0, 0) * (1.0 if i == 0 else -1.0)
		var spin := q * identikit_spin(float(d[1]), float(d[2]), to_companion)
		var ab := float(g.ab) * lu
		var ad := float(g.ad) * lu
		var ah := float(g.ah) * lu
		var bh := float(g.bh) * lu
		var mb := float(g.mb) * m_unit_sun
		var md := float(g.md) * m_unit_sun
		var gm_ha := float(g.mh_a) * gm_unit
		# The rigid halo seeds the disc before it goes live, at once: a Hernquist sphere of the
		# halo's mass and scale stands in.
		e.set_galaxy(i, [m_unit_sun, ah], [md, 0.9688 * ad, float(g.zd) * lu], [mb, ab], spin)
		var pot := [["nfw", gm_ha, ah, bh], ["hernquist", float(g.mb) * gm_unit, ab], ["disc", float(g.md) * gm_unit, ad]]
		var eps := float(g.eps) * lu
		var counts: Array = ANTENNAE_COUNTS
		e.seed_disc(i, maxi(int(counts[1] * scale), 1), md, ad, float(g.zd) * lu, eps, seed * 16 + i, float(g.q_sigma) * lu)
		var bulge := GalEddington.new(float(g.mb) * gm_unit, ab, float(g.bb) * lu, pot)
		e.seed_bulge(i, maxi(int(counts[0] * scale), 1), mb, bulge, eps, seed * 16 + 4 + i)
		# The taper falls by e every a_h beyond b_h: ten scale lengths out it holds nothing.
		var cut := bh + 10.0 * ah
		var shape := GalEddington.nfw_shape(ah, bh)
		var mh := float(g.mh_a) * shape.at(cut).x * m_unit_sun
		var hs := GalEddington.new(gm_ha, ah, cut, pot, bh)
		e.seed_halo(i, maxi(int(counts[2] * scale), 1), mh, hs, eps, seed * 16 + 8 + i)
	e.live_at = INF
	return e

## The light an encounter draws, per draw tag (GalEncounter.tag: galaxy, + BULGE_TAG for a
## bulge): [that population's visible light per channel, all its stars together (Color,
## Sun-luminances), and a blob σ of one star spacing where it is dense (kpc)]. Mass becomes
## light through the population model, visible share VISIBLE_BULGE, as type_galaxy's: a disc
## formed stars evenly for 10 Gyr, a bulge in one burst 10 Gyr ago.
static func vdm_lights(e: GalEncounter) -> Array:
	var stars := []
	for row in VDM_CANONICAL:
		var st: Array = VDM_STARS[row[0]]
		stars.append([float(st[0]), float(st[1]), float(st[2]), float(st[3]) / 1.8153])
	return encounter_lights(e, stars)

## An Identikit pair's light: both galaxies Barnes & Hibbard's model in Privon et al.'s units.
static func antennae_lights(e: GalEncounter) -> Array:
	var lu := float(ANTENNAE.L)
	var vu := float(ANTENNAE.V) * GalUnits.KMS
	var m_unit_sun := vu * vu * lu / GalUnits.G * GalUnits.MASS_UNIT_SUN
	var g: Dictionary = BH09
	var one := [float(g.md) * m_unit_sun, float(g.ad) * lu, float(g.mb) * m_unit_sun, float(g.ab) * lu]
	return encounter_lights(e, [one, one])

## Per galaxy `stars` [disc mass (M☉), R_d, bulge mass, bulge Hernquist a (kpc)].
static func encounter_lights(e: GalEncounter, stars: Array) -> Array:
	var out := []
	out.resize(2 * GalEncounter.BULGE_TAG)
	var disc_pop := GalPopulation.build({"kind": "constant", "gyr": 10.0})
	var bulge_pop := GalPopulation.build({"kind": "burst", "gyr": 10.0})
	var counts := PackedInt32Array()
	counts.resize(out.size())
	for k in e.n: counts[e.tag[k]] += 1
	for t in out.size():
		out[t] = [Color(0, 0, 0), 1.0]
		var gi := t % GalEncounter.BULGE_TAG
		if gi >= stars.size() or counts[t] == 0: continue
		var st: Array = stars[gi]
		if t < GalEncounter.BULGE_TAG:
			var rd := float(st[1])
			# Stars per kpc² at R_d of an exponential disc: N e^(−1)/(2π R_d²).
			var spacing := 1.0 / sqrt(float(counts[t]) * exp(-1.0) / (TAU * rd * rd))
			out[t] = [disc_pop.color * (float(st[0]) * VISIBLE_BULGE * disc_pop.mean_l / disc_pop.mean_mass), spacing]
		else:
			var ab := float(st[3])
			# A Hernquist sphere's stars per kpc³ at r = a: N / (16π a³).
			var spacing := pow(16.0 * PI * ab * ab * ab / float(counts[t]), 1.0 / 3.0)
			out[t] = [bulge_pop.color * (float(st[2]) * VISIBLE_BULGE * bulge_pop.mean_l / bulge_pop.mean_mass), spacing]
	return out

## An encounter's orbits from its table (VDM_CANONICAL's form).
static func encounter(rows: Array) -> GalOrbits:
	var o := GalOrbits.new()
	for r in rows:
		var h := GalOrbits.hernquist_halo(float(r[1]), float(r[2]))
		var p: Array = r[3]
		var v: Array = r[4]
		o.add(String(r[0]), float(h[0]), float(h[1]), Vector3(p[0], p[1], p[2]), Vector3(v[0], v[1], v[2]) * GalUnits.KMS)
	return o

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
	if key == "vdm_canonical": return {"key": key, "name": "Milky Way meets M31", "encounter": "vdm", "seed": seed, "extent": 1000.0}
	if IDENTIKIT.has(key): return {"key": key, "name": String(PRESETS.get("gal_" + key, {}).get("name", key)), "encounter": "identikit", "spec": key, "seed": seed, "extent": 150.0}
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
