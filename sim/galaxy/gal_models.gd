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
		var k := pow(10.0, -0.4 * (float(spec.mv) - 4.83)) / visible_luminosity(model, true)
		for l in light: l.visible = float(l.visible) * k
	return model

## A model's visible luminosity (Sun-luminances): each part's stellar mass, visible
## share, its population's L/M and that light's luminance; with `drawn`, only the light
## its visual draws (drawn_share).
static func visible_luminosity(model: Dictionary, drawn := false) -> float:
	var pop_d := GalPopulation.build(model.get("discPop", {"kind": "constant", "gyr": 10.0}))
	var pop_s := GalPopulation.build(model.get("spherePop", {"kind": "burst", "gyr": 10.0}))
	var lv := 0.0
	for l in model.light:
		var part: Dictionary = (model.potential as GalPotential).part(l.part)
		var pop: GalPopulation = pop_d if l.part == "disc" else pop_s
		var y := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
		var share := drawn_share(model, part) if drawn else 1.0
		lv += float(l.visible) * float(part.gm) / GalUnits.G * GalUnits.MASS_UNIT_SUN * pop.mean_l / pop.mean_mass * y * share
	if model.has("armLight"):
		var young := GalPopulation.build({"kind": "constant", "gyr": MW_YOUNG_GYR})
		lv += float(model.armLight) * (0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b)
	return lv

## Half-height of the box the glow is drawn on and marches a disc through (kpc): it must
## hold the spheroid's sphere, as a ray that misses the box has no fragment to carry its light.
static func glow_half_height(model: Dictionary) -> float:
	return maxf(4.0, sphere_reach(model))

## Radius of the sphere the glow marches a spheroid through (kpc). A power law with a
## cutoff is below 1e-3 of its peak past three cutoff radii; a Hernquist sphere holds
## (r/(r + a))² of its light within r: 95 % at 40 a.
static func sphere_reach(model: Dictionary) -> float:
	var bl: Dictionary = (model.potential as GalPotential).part("bulge")
	if not bl.is_empty() and bl.kind == GalPotential.Kind.POWER_CUTOFF: return 3.0 * float(bl.rc)
	if not bl.is_empty() and bl.kind == GalPotential.Kind.HERNQUIST: return minf(float(model.get("extent", 30.0)), 40.0 * float(bl.a))
	return 8.0

## The share of a part's light the glow draws: a Hernquist spheroid's within sphere_reach;
## a Miyamoto–Nagai disc's within the glow box's height and the light's edge, tapered over its
## last fifth (gal_model.gdshaderinc). Mass in a cylinder is the gravitational flux out of
## it (docs/physics/galaxies.md#the-light-a-neighbour-draws). Other parts: all of it.
static func drawn_share(model: Dictionary, part: Dictionary) -> float:
	if part.kind == GalPotential.Kind.HERNQUIST:
		# Its light is round in r' = (u, y/c, v/b): along a direction n the sphere's edge
		# is at r' = r q(n), so the share is ∫ q⁻³ (r q/(r q + a))² dΩ / 4π b c.
		var r := sphere_reach(model)
		var ax: Array = model.get("bulgeAxes", [1.0, 1.0])
		var bx := float(ax[0])
		var cy := float(ax[1])
		var n := 48
		var share := 0.0
		for i in n:
			var ny := (float(i) + 0.5) / n
			var st := sqrt(1.0 - ny * ny)
			for j in n:
				var ph := (float(j) + 0.5) / n * PI * 0.5
				var q := sqrt(pow(st * cos(ph), 2.0) + pow(ny / cy, 2.0) + pow(st * sin(ph) / bx, 2.0))
				share += pow(r * q / (r * q + float(part.a)), 2.0) / (q * q * q)
		return share * (1.0 / n) * (PI * 0.5 / n) * 8.0 / (4.0 * PI * bx * cy)
	if part.kind != GalPotential.Kind.MIYAMOTO_NAGAI: return 1.0
	var a := float(part.a)
	var b := float(part.b)
	var e := float(model.get("extent", 30.0))
	var h := glow_half_height(model)
	var zh := sqrt(h * h + b * b)
	var nr := 32
	var nz := 256
	var umax := asinh(h / b)
	var share := 0.0
	for i in nr:
		# t from 0 at the edge to 1 at 0.8 edge: the smoothstep's weight 6t(1 − t) dt.
		var t := (float(i) + 0.5) / nr
		var rr := e * (1.0 - 0.2 * t)
		var side := 0.0
		for j in nz:
			var u := (float(j) + 0.5) / nz * umax
			var z := b * sinh(u)
			var s := a + sqrt(z * z + b * b)
			side += b * cosh(u) / pow(rr * rr + s * s, 1.5)
		side *= rr * rr * umax / nz
		var sh := a + zh
		var caps := h / zh * (1.0 - sh / sqrt(rr * rr + sh * sh))
		share += (side + caps) * 6.0 * t * (1.0 - t) / nr
	return share

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
	# The Whirlpool. McQuinn et al. (2016): 8.58 Mpc; RC3 V_T⁰ 8.14, so M_V −21.53. Marchuk et al.
	# (2024, g band, bulge + disc + spirals; at 8.9 Mpc, rescaled): i 46.2°, PA 24.4°; bulge 8 %
	# (r_eff 16.1″), disc 56 % (h 70.0″), and two arms of 19 and 17 % of the light, pitch 11.0°
	# and 14.1°, radial FWHM 47.0″ and 45.8″ (σ across the arm = FWHM/2.355 · cos pitch), light
	# falling with h_s 51.0″ and 62.4″, no width growth. Their phase, their span (1.5–10.5 kpc),
	# their light rising over their first 2 kpc and fading over 0.6 rad past their ends are set
	# to Hubble's image by eye, as are the disc's thickness (0.3 kpc) and the arms' (0.1). No dust.
	"m51": {"name": "Whirlpool (M51)", "ra": 202.4696258, "dec": 47.19520736, "d": 8580.0, "mv": -21.53, "i": 46.2, "pa": 24.4,
		"parts": {"bulge": [0.08, 0.369], "disc": [0.56, 2.821, 0.3]}, "extent": 25.0,
		"arms": [["Arm 1", 4.000, 0.0, 11.0, 11.0, 0.815, -284.5, 289.1, false], ["Arm 2", 4.000, 180.0, 14.1, 14.1, 0.785, -40.1, 403.7, false]], "armShare": 0.36, "armDecay": [2.121, 2.596], "armR": [0.5, 20.0], "armTurns": 2, "armH": 0.1,
		"armWidthGrowth": 0.0, "armRise": [1.5, 2.0], "armEndFade": 0.6, "companions": ["ngc5195"]},
	# NGC 5195, M51's companion: RC3 V_T⁰ 9.58 and effective aperture 114.3″ (r_e 57.15″); 20–50
	# kpc behind M51 (Dobbs et al. 2010; Salo & Laurikainen 2000, via Marchuk et al. 2024), 35 here;
	# i 43°, PA 91° (Spillar et al. 1992, via Wei et al. 2020); old (12 Gyr, ibid.). Drawn round.
	"ngc5195": {"name": "NGC 5195", "ra": 202.4980839, "dec": 47.2661666, "d": 8615.0, "mv": -20.09, "i": 43.0, "pa": 91.0,
		"parts": {"bulge": [1.0, 1.310]}, "extent": 20.0},
	"m104": {"name": "Sombrero (M104)", "ra": 189.9976312, "dec": -11.62308847, "d": 9550.0, "mv": -22.35, "i": 84.0,
		"parts": {"bulge": [0.65, 2.577], "disc": [0.35, 1.834, 0.785]}, "bulgeAxes": [1.0, 0.72], "extent": 30.0,
		"dust": "m104"},
}

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
	var lv := pow(10.0, -0.4 * (float(spec.mv) - 4.83))
	# With arms, stars under 100 Myr are theirs, so the disc's own population starts there,
	# as GalaxyVisual draws it.
	if spec.has("arms"): model.discPop = {"kind": "constant", "gyr": 10.0, "fromGyr": MW_YOUNG_GYR}
	for part in spec.parts:
		var pp: Array = spec.parts[part]
		var pop := GalPopulation.build({"kind": "burst", "gyr": 10.0} if part == "bulge" else model.get("discPop", {"kind": "constant", "gyr": 10.0}))
		var y := 0.2126 * pop.color.r + 0.7152 * pop.color.g + 0.0722 * pop.color.b
		# The stellar mass whose visible stars give this part its share of the light.
		var mass := float(pp[0]) * lv / (VISIBLE_BULGE * pop.mean_l / pop.mean_mass * y)
		var gm := GalUnits.G * mass / GalUnits.MASS_UNIT_SUN
		if part == "bulge": pot.add(GalPotential.hernquist("bulge", float(pp[1]), gm))
		else: pot.add(GalPotential.miyamoto_nagai("disc", float(pp[1]), float(pp[2]), gm))
		light.append({"part": part, "visible": VISIBLE_BULGE})
	# Each part's share is of the light drawn: what the glow's bounds leave out is made up.
	for l in light: l.visible = float(l.visible) / drawn_share(model, pot.part(l.part))
	if spec.has("arms"):
		# The arms' measured share of the light, as the young population's bolometric light.
		var young := GalPopulation.build({"kind": "constant", "gyr": MW_YOUNG_GYR})
		var yy := 0.2126 * young.color.r + 0.7152 * young.color.g + 0.0722 * young.color.b
		for k in ["arms", "armDecay", "armR", "armTurns", "armH", "armWidthGrowth", "armRise", "armEndFade", "armMirror"]:
			if spec.has(k): model[k] = spec[k]
		model.armLight = float(spec.armShare) * lv / yy
		model.envelope = [1e9, 0.0]
	if spec.has("companions"): model.companions = spec.companions
	if spec.get("dust", "") == "m104":
		var d := m104_dust()
		model.dustRing = d[0]
		model.dustRingH = M104_DUST_H
		model.dust = d[1]
	return model

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
# their density amplitude at 8 kpc, ρ0 = (14/11) m_H n0 with n0 = 1 cm⁻³: the mass per
# hydrogen nucleus with helium at a tenth of it by number, 1.283 amu cm⁻³. Pattern speed 28.2 ± 2.1
# km/s/kpc from Gaia DR2 open clusters (Dias et al. 2019). Pitch 12°, the mean of the
# two major arms' pitches measured from maser parallaxes, Perseus (10.3°, 8.7°) and
# Scutum–Centaurus (14.1°, 12.1°) (Reid et al. 2019, Table 2), whose Perseus crest it
# puts at R = 8.87 kpc, Galactocentric azimuth 40° from the Sun, today.
const MW_SPIRAL_OMEGA_KMS_KPC := 28.2
const MW_SPIRAL_PITCH_DEG := 12.0
const MW_SPIRAL_ANCHOR := [8.87, 40.0]
## Reid et al. (2019) give their arms for R0 = 8.15 kpc; the model's Sun is at MW_R0. Their
## radii are scaled by MW_R0 / REID_R0 so each arm keeps its place relative to the Sun
## (reid_arms, spiral_anchor).
const REID_R0 := 8.15
## The hydrogen atom's mass in atomic mass units (CODATA 2018).
const M_H_AMU := 1.00782503
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
## Reid et al.'s arms with their radii scaled to the model's R0 (REID_R0).
static func reid_arms() -> Array:
	var out := []
	for a in REID_2019_ARMS:
		var row: Array = (a as Array).duplicate()
		row[1] = float(row[1]) * MW_R0 / REID_R0
		out.append(row)
	return out

## The spiral's crest today: Perseus where Reid et al. put it, at the model's R0.
static func spiral_anchor() -> Array:
	return [float(MW_SPIRAL_ANCHOR[0]) * MW_R0 / REID_R0, float(MW_SPIRAL_ANCHOR[1])]

static func mw_patterns() -> Array:
	var v0 := MW_V0_KMS * GalUnits.KMS
	var af := MW_BAR_ALPHA * v0 * v0 * pow(MW_R0 / MW_BAR_RB, 3.0) / 3.0
	var bar := GalPattern.bar(MW_BAR_OMEGA_KMS_KPC * GalUnits.KMS, PI + deg_to_rad(MW_BAR_ANGLE_DEG),
		MW_BAR_RB, af, MW_T_START, MW_T_GROW)
	var pitch := deg_to_rad(MW_SPIRAL_PITCH_DEG)
	var rho0 := 14.0 / 11.0 * M_H_AMU * AMU_CM3_MSUN_PC3 * 1e9 / GalUnits.MASS_UNIT_SUN
	var amp := 4.0 * PI * GalUnits.G * 0.18 * rho0
	# γ = 0 at the anchor: φp = φ + ln(R/r0)/tan α.
	var anchor: Array = spiral_anchor()
	var anchor_phi: float = PI + deg_to_rad(float(anchor[1]))
	var angle0: float = anchor_phi + log(float(anchor[0]) / MW_R0) / tan(pitch)
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
				"arms": reid_arms() if patterns else [],
				"sfr": MW_SFR if patterns else 0.0,
				"dust": MW_DUST if patterns else {},
				"bulgeAxes": MW_BULGE_AXES if patterns else [1.0, 1.0],
			}
	return {}
