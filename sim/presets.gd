class_name Presets
extends RefCounted

# Scenario data in M☉, AU and AU/yr; scene/body scales affect rendering only.
# build returns body specs; omitted settings use consumer defaults.
# Design, scientific bounds and sky schema: docs/scenarios.md.

# The one source of randomness: `orbiter`'s default phase. randf() unless a harness
# installs a deterministic generator here.
static var rand_override: Callable = Callable()
static func _rand() -> float:
	return float(rand_override.call()) if rand_override.is_valid() else randf()

# Keplerian two-body relative state for (a, e, incl, true anomaly nu), for building
# hierarchies exactly.
## Returns { pos: [x,y,z], vel: [x,y,z] }.
static func kepler(Mtot: float, a: float, e: float, incl: float, nu: float) -> Dictionary:
	var p := a * (1.0 - e * e)
	var r := p / (1.0 + e * cos(nu))
	var h := sqrt(Physics.G * Mtot * p)
	var px := r * cos(nu)
	var pz := r * sin(nu)
	var vx := -Physics.G * Mtot / h * sin(nu)
	var vz := Physics.G * Mtot / h * (e + cos(nu))
	var c := cos(incl)
	var s := sin(incl)
	return { "pos": [px, pz * s, pz * c], "vel": [vx, vz * s, vz * c] }

static func addv(a: Array, b: Array, k: float = 1.0) -> Array:
	return [a[0] + b[0] * k, a[1] + b[1] * k, a[2] + b[2] * k]
## `angle` defaults to a random phase (null → _rand() · 2π).
static func orbiter(Mc: float, a: float, spec: Dictionary, angle = null) -> Dictionary:
	var ang: float = (_rand() * PI * 2.0) if angle == null else float(angle)
	var v := Physics.circular_speed(Mc, a)
	return U.merged(spec, { "pos": [cos(ang) * a, 0.0, sin(ang) * a], "vel": [-sin(ang) * v, 0.0, cos(ang) * v] })

# Mean elements, J2000 ecliptic and equinox: [a AU, e, I°, L°, ϖ°, Ω°], each as
# [J2000 value, rate per Julian century]. Planets: Standish, "Keplerian Elements for
# Approximate Positions of the Major Planets" (JPL), Table 1, valid 1800–2050; EMB is
# the Earth–Moon barycentre. Moon: geocentric, Meeus, Astronomical Algorithms ch. 47
# (ϖ = L′ − M′), with the mean 5.145° inclination.
# A dry world's thermal flywheel, in metres of water: rock's annual skin depth at its heat
# capacity (docs/physics/climate.md#a-climate-per-world).
const DRY_LAYER_M := 1.5

const SOLAR_ELEMENTS := {
	"Mercury": [[0.38709927, 0.00000037], [0.20563593, 0.00001906], [7.00497902, -0.00594749], [252.25032350, 149472.67411175], [77.45779628, 0.16047689], [48.33076593, -0.12534081]],
	"Venus":   [[0.72333566, 0.00000390], [0.00677672, -0.00004107], [3.39467605, -0.00078890], [181.97909950, 58517.81538729], [131.60246718, 0.00268329], [76.67984255, -0.27769418]],
	"EMB":     [[1.00000261, 0.00000562], [0.01671123, -0.00004392], [-0.00001531, -0.01294668], [100.46457166, 35999.37244981], [102.93768193, 0.32327364], [0.0, 0.0]],
	"Mars":    [[1.52371034, 0.00001847], [0.09339410, 0.00007882], [1.84969142, -0.00813131], [-4.55343205, 19140.30268499], [-23.94362959, 0.44441088], [49.55953891, -0.29257343]],
	"Jupiter": [[5.20288700, -0.00011607], [0.04838624, -0.00013253], [1.30439695, -0.00183714], [34.39644051, 3034.74612775], [14.72847983, 0.21252668], [100.47390909, 0.20469106]],
	"Saturn":  [[9.53667594, -0.00125060], [0.05386179, -0.00050991], [2.48599187, 0.00193609], [49.95424423, 1222.49362201], [92.59887831, -0.41897216], [113.66242448, -0.28867794]],
	"Uranus":  [[19.18916464, -0.00196176], [0.04725744, -0.00004397], [0.77263783, -0.00242939], [313.23810451, 428.48202785], [170.95427630, 0.40805281], [74.01692503, 0.04240589]],
	"Neptune": [[30.06992276, 0.00026291], [0.00859048, 0.00005105], [1.77004347, 0.00035372], [-55.12002969, 218.45945325], [44.96476227, -0.32241464], [131.78422574, -0.00508664]],
	"Pluto":   [[39.48211675, -0.00031596], [0.24882730, 0.00005170], [17.14001206, 0.00004818], [238.92903833, 145.20780515], [224.06891629, -0.04062942], [110.30393684, -0.01183482]],
	"Moon":    [[384399.0 * Physics.AU_PER_KM, 0.0], [0.0549, 0.0], [5.145, 0.0], [218.3164477, 481267.88123421], [83.3532465, 4069.0137287], [125.0445479, -1934.1362891]],
}

## Two-body state from one SOLAR_ELEMENTS row at `t_cy` Julian centuries from J2000,
## relative to the primary of gravitational parameter `mu` (AU³/yr²). The orrery frame
## takes ecliptic x → x, y → z and ecliptic north → −y, so prograde orbits turn about −y.
## Returns { pos: [x,y,z], vel: [x,y,z] }.
static func elements_state(mu: float, row: Array, t_cy: float) -> Dictionary:
	var el := []
	for pair in row: el.append(float(pair[0]) + float(pair[1]) * t_cy)
	var a: float = el[0]; var e: float = el[1]
	var inc := deg_to_rad(el[2]); var varpi := deg_to_rad(el[4]); var node := deg_to_rad(el[5])
	var w := varpi - node
	var M := fposmod(deg_to_rad(el[3]) - varpi + PI, TAU) - PI
	var E := M + e * sin(M)
	for _i in 50:
		var dE := (E - e * sin(E) - M) / (1.0 - e * cos(E))
		E -= dE
		if absf(dE) < 1e-15: break
	var b := sqrt(1.0 - e * e)
	var xp := a * (cos(E) - e); var yp := a * b * sin(E)
	var E_dot := sqrt(mu / (a * a * a)) / (1.0 - e * cos(E))
	var vxp := -a * sin(E) * E_dot; var vyp := a * b * cos(E) * E_dot
	var cw := cos(w); var sw := sin(w); var cn := cos(node); var sn := sin(node); var ci := cos(inc); var si := sin(inc)
	var px := [cw * cn - sw * sn * ci, -sw * cn - cw * sn * ci]
	var py := [cw * sn + sw * cn * ci, -sw * sn + cw * cn * ci]
	var pz := [sw * si, cw * si]
	return {
		"pos": [px[0] * xp + px[1] * yp, -(pz[0] * xp + pz[1] * yp), py[0] * xp + py[1] * yp],
		"vel": [px[0] * vxp + px[1] * vyp, -(pz[0] * vxp + pz[1] * vyp), py[0] * vxp + py[1] * vyp],
	}

# THE TABLE: the scenarios in scenarios/*.jsonc (docs/scenario-format.md), and the three
# that need code: the Solar System's ephemeris and the Jupiter and Titan expeditions built on it.
const SCENARIO_DIR := "res://scenarios"
static var PRESETS: Dictionary = _make_presets()

# The list order; a file not named here follows, by its `order` and then its key.
const LISTED := ["edu_seasons", "edu_moon", "edu_kepler", "edu_mercury", "edu_habitable",
	"edu_starbirth", "edu_sun", "edu_lifecycle", "edu_supernova", "edu_pulsar",
	"edu_transit", "edu_hole", "edu_galaxy", "edu_cluster",
	"blank", "stellar_zoo", "sirius", "vega", "achernar", "betelgeuse", "alphacen", "etacar", "hr_ladder", "trisolaris", "trisolaris_wander", "trisolaris_compact", "trisolaris_wide", "trisolaris_alpha", "trisolaris_chaos", "sandbox", "solar", "jovian_voyage", "titan_voyage", "threebody", "binarystar", "bhmerger", "nsmerger", "feeding", "gargantua_demo"]
static var PRESET_ORDER: Array = _make_order()

static func _make_order() -> Array:
	var extra := PRESETS.keys().filter(func(k): return k not in LISTED)
	extra.sort_custom(func(a, b):
		var oa := float(PRESETS[a].get("order", INF)); var ob := float(PRESETS[b].get("order", INF))
		return oa < ob if oa != ob else a < b)
	return LISTED.filter(func(k): return PRESETS.has(k)) + extra

## 2023 July 1, 0h TT: the Titan expedition's date.
const TITAN_EPOCH_JD := 2460126.5

static func _make_presets() -> Dictionary:
	var P := {}
	for name in DirAccess.get_files_at(SCENARIO_DIR):
		if not name.ends_with(".jsonc"): continue
		var r := ScenarioFile.read(SCENARIO_DIR.path_join(name), true)
		if r.ok: P[name.get_basename()] = r.preset
		else: push_error("scenarios/%s: %s" % [name, "; ".join(r.errors)])

	P.solar = {
		"sky": { "env": "disc", "galactic": "j2000" },
		"name": "Solar System", "group": "stellar-systems",
		"blurb": "The planets and the Moon where they were at J2000.0 (JPL mean elements) on their real eccentric, inclined orbits, with DE440 masses and real radii, G = 4π². Sizes default to TRUE scale — the planets are points until you fly to one. Toggle \"Sizes\" to get the readable, exaggerated view back. This is also the scenario to fly from: the Spaceflight section builds a real launch vehicle on the pad, and the Moon is here to land on.",
		# 2e-4 yr is 1/1200 of Mercury's year: integration error ~1″/cy beside GR's 43″.
		"sceneScale": 1.0, "bodyScale": 0.5, "camRadius": 80.0, "lensing": false, "timeScale": 6.0, "maxStep": 2e-4,
		# The one preset where the bodies are drawn at their real geometric size.
		# See sim/scale.gd for why that needs a point-source fallback to be usable.
		"trueScale": true,
		# J2000.0, 2000 Jan 1 12:00 TDB: the clock reads a date (TimeScales).
		"epochJD": 2451545.0,
		"build": func() -> Array: return _build_solar(),
	}

	P.jovian_voyage = U.merged(P.solar,{
		"name":"Jupiter expedition", "group": null,
		"blurb":"The Solar System with Io, Europa, Ganymede and Callisto on approximate circular orbits in Jupiter's equatorial plane. Launch the Jupiter Explorer from Earth orbit and select Jupiter in the porkchop mission planner. Jupiter's zonal figure is used in local flight. The moon phases are illustrative, not a dated ephemeris.",
		# Roughly 480 Yoshida steps per Io orbit, rather than the planetary step.
		"maxStep":1e-5,"timeScale":.001,
		"build":func() -> Array:
			var bodies:=_build_solar()
			for i in bodies.size():
				if bodies[i].name=="Jupiter":
					var system:=JovianMoons.system(bodies[i])
					bodies[i]=system[0];bodies.append_array(system.slice(1));break
			return bodies,
	})

	P.titan_voyage = U.merged(P.solar,{
		"name":"Titan expedition", "group": null,
		"blurb":"The Solar System on 1 July 2023, the Titan Mare Explorer's planned arrival, with Titan on an approximate circular orbit in Saturn's equatorial plane: 1.5 bar of nitrogen and methane at 94 K under an orange haze, and late northern summer over its methane seas. Fly Dragonfly down to its dunes, TiME down to Ligeia Mare, or bring the Survey Shuttle in from orbit. The moon's phase is illustrative, not a dated ephemeris.",
		# Roughly 400 Yoshida steps per 16-day orbit of Titan.
		"maxStep":1.1e-4,"timeScale":.001,
		# TiME's arrival (Lorenz & Mann 2015): Titan's northern summer, when the Sun stays up over Ligeia.
		"epochJD":TITAN_EPOCH_JD,
		"build":func() -> Array:
			var bodies:=_build_solar((TITAN_EPOCH_JD - 2451545.0) / 36525.0)
			for i in bodies.size():
				if bodies[i].name=="Saturn":
					var system:=TitanMoon.system(bodies[i])
					bodies[i]=system[0];bodies.append(system[1]);break
			return bodies,
	})

	return P

## `t_cy`: Julian centuries from J2000.0 (2000 Jan 1 12:00 TT) for the starting positions.
static func _build_solar(t_cy := 0.0) -> Array:
	var sun := { "type": "star", "name": "Sun", "mass": 1.0, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
	# m = mass (M☉) from the DE440 GM ratios (Park et al. 2021): the planet's system
	# where its moons aren't simulated, Pluto alone; radiusKm = mean physical radius.
	var P := func(m: float, radius_km: float, type: String, name: String, extra: Dictionary) -> Dictionary:
		var spec := U.merged({ "type": type, "name": name, "mass": m, "radiusKm": radius_km }, extra)
		return U.merged(spec, elements_state(Physics.G * (1.0 + m), SOLAR_ELEMENTS[name], t_cy))
	var m_earth := 1.0 / 332946.0487
	var m_moon := m_earth / 81.30056907
	# Surfaces are derived from where a body is (sim/rocky_visual.gd). A preset states
	# what it's made of: albedo, its air, and the dominant volatile's condensation
	# temperature.
	# cloudCover is the fraction under cloud thick enough to hide the ground: MODIS's
	# 0.67 total less the thin cirrus the decks don't draw.
	var earth := { "type": "planet", "name": "Earth", "mass": m_earth, "radiusKm": 6371.0,
		"oceans": true, "mixedLayer": 60.0,
		"atmosphere": true, "land": 0.32, "biota": 1.0, "albedo": 0.306,
		"pN2": Climate.EARTH_AIR.pN2, "pO2": Climate.EARTH_AIR.pO2, "pAr": Climate.EARTH_AIR.pAr,
		"pCO2": Climate.EARTH_AIR.pCO2, "pCH4": Climate.EARTH_AIR.pCH4,
		"oceanDepth": 3.7, "salinity": 35.0,
		"obliquity": 0.4091, "cloudCover": 0.44, "season": 11.0,
		# The oceans' tide, which a uniform elastic sphere can't give: k2 (Lambeck 1980)
		# and the lag that recedes the Moon 3.8 cm/yr (Neron de Surgy & Laskar 1997).
		"k2": 0.299, "tideLagS": 638.0,
	}
	# The Moon, on its real orbit about Earth: a target inside Earth's SOI and an
	# airless body to land on. Its 5.1° tilt keeps eclipses to the nodes.
	var moon := { "type": "planet", "name": "Moon", "mass": m_moon, "radiusKm": 1737.4,
		"hot": true, "crater": 1.0, "regolith": 0x9a958c, "albedo": 0.12, "obliquity": 0.0268,
		"tidalLock": "Earth", "oceans": false, "mixedLayer": DRY_LAYER_M }
	var emb := elements_state(Physics.G * (1.0 + m_earth + m_moon), SOLAR_ELEMENTS.EMB, t_cy)
	var rel := elements_state(Physics.G * (m_earth + m_moon), SOLAR_ELEMENTS.Moon, t_cy)
	var f_moon := m_moon / (m_earth + m_moon)
	earth.pos = addv(emb.pos, rel.pos, -f_moon); earth.vel = addv(emb.vel, rel.vel, -f_moon)
	moon.pos = addv(emb.pos, rel.pos, 1.0 - f_moon); moon.vel = addv(emb.vel, rel.vel, 1.0 - f_moon)
	var bodies := [
		sun,
		P.call(1.0 / 6023657.33, 2439.7, "planet", "Mercury", {
			"hot": true, "crater": 0.95, "regolith": 0x8b8279, "albedo": 0.12, "obliquity": 0.0006,
			"oceans": false, "mixedLayer": DRY_LAYER_M }),
		# Venus's 737 K is stated for the surface, whose emissivity rule cannot reach 2.4× its
		# equilibrium temperature. Its air is NSSDC's; its flywheel is 92 bar of CO₂
		# (docs/physics/climate.md#a-climate-per-world). atmColor is the sulphuric haze's, which
		# the gas column cannot derive.
		P.call(1.0 / 408523.719, 6051.8, "planet", "Venus", {
			"oceans": false, "mixedLayer": 270.0,
			"pCO2": 88.78, "pN2": 3.22, "pAr": 0.00644, "pSO2": 0.0138,
			"hot": true, "atmosphere": true, "atmColor": 0xffd9a0, "surfaceK": 737.0, "albedo": 0.77,
			"crater": 0.10, "regolith": 0xb08a5c, "cloudCover": 1.0, "cloudColor": 0xfff2d2,
			"haze": 1.2, "obliquity": 3.096, "cloudSpin": 60.0 }),
		earth,
		moon,
		# Mars's caps are CO₂ (148 K), so they grow and retreat each winter.
		P.call(1.0 / 3098703.59, 3389.5, "planet", "Mars", {
			# Dust, not gas, makes this sky (the column's Rayleigh depth is 0.003), so its colour
			# and depth stay stated.
			"hot": true, "atmosphere": true, "atmThick": 0.22, "atmColor": 0xd8b48c,
			"cloudCover": 0.10, "cloudColor": 0xe8d8c0, "haze": 0.25,
			"pCO2": 6.048e-3, "pN2": 1.647e-4, "pAr": 1.234e-4, "pO2": 1.018e-5,
			"oceans": false, "mixedLayer": DRY_LAYER_M,
			"frostK": 148.0, "crater": 0.55, "regolith": 0xa9603a, "albedo": 0.25, "obliquity": 0.4396,
			"transport": 0.16, "season": 62.0 }),
		P.call(1.0 / 1047.348644, 69911.0, "gas-giant", "Jupiter", {
			"palette": "jupiter", "obliquity": 0.0546, "internalHeat": 1.67, "albedo": 0.503 }),
		P.call(1.0 / 3497.9018, 58232.0, "gas-giant", "Saturn", {
			"palette": "saturn", "rings": true, "ringColor": 0xe2d3b0, "ringInner": 1.235, "ringOuter": 2.27,
			"obliquity": 0.4665, "internalHeat": 1.78, "albedo": 0.342 }),
		# Uranus is tipped 97.8°: its poles take turns facing the Sun for 42 years.
		P.call(1.0 / 22902.98, 25362.0, "gas-giant", "Uranus", {
			"palette": "ice", "obliquity": 1.7064, "internalHeat": 1.03, "albedo": 0.300 }),
		P.call(1.0 / 19412.26, 24622.0, "gas-giant", "Neptune", {
			"palette": "ice", "obliquity": 0.4943, "internalHeat": 2.61, "albedo": 0.290, "vortices": 2 }),
		# Pluto sits at N₂'s 37 K frost point, hence its frost cycle.
		P.call(869.6 / 1.32712440018e11, 1188.3, "planet", "Pluto", {
			"hot": true, "frostK": 37.0, "crater": 0.7, "regolith": 0x9b7255, "albedo": 0.52,
			# ~1 Pa of N₂ (New Horizons), which the draw from its orbit would overstate.
			"pN2": 1e-5, "pCO2": 0.0, "pO2": 0.0, "pAr": 0.0, "pCH4": 0.0, "pSO2": 0.0,
			"obliquity": 2.1386, "oceans": false, "mixedLayer": DRY_LAYER_M }),
	]
	# Barycentric start: with the Sun at rest, Jupiter alone would carry the whole
	# system off at 13 m/s.
	var mass := 0.0
	var com := [0.0, 0.0, 0.0]
	var mom := [0.0, 0.0, 0.0]
	for b in bodies:
		mass += float(b.mass)
		com = addv(com, b.pos, float(b.mass)); mom = addv(mom, b.vel, float(b.mass))
	for b in bodies:
		b.pos = addv(b.pos, com, -1.0 / mass); b.vel = addv(b.vel, mom, -1.0 / mass)
	return bodies
