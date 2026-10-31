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

# two-body barycentric setup orbiting in the XZ plane
static func binary(m1: float, m2: float, sep: float, t1: Dictionary, t2: Dictionary, phase: float = 0.0) -> Array:
	var M := m1 + m2
	var r1 := sep * m2 / M
	var r2 := sep * m1 / M
	var vrel := Physics.circular_speed(M, sep)
	var v1 := vrel * m2 / M
	var v2 := vrel * m1 / M
	var cx := cos(phase)
	var cz := sin(phase)
	return [
		U.merged(t1, { "mass": m1, "pos": [-r1 * cx, 0.0, -r1 * cz], "vel": [r1 * 0.0 + v1 * cz, 0.0, -v1 * cx] }),
		U.merged(t2, { "mass": m2, "pos": [r2 * cx, 0.0, r2 * cz], "vel": [-v2 * cz, 0.0, v2 * cx] }),
	]

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
static func mulv(a: Array, k: float) -> Array:
	return [a[0] * k, a[1] * k, a[2] * k]

# A number for a name, without a trailing .0 ("0.1", "4").
static func _num(x: float) -> String:
	if x == floor(x) and absf(x) < 1e15:
		return str(int(x))
	return str(x)

# Hierarchy constructors use barycentric stellar orbits; the circumbinary world's
# tiny recoil is neglected (docs/scenarios.md).
static func _tri_star(name: String, mass: float, extra: Dictionary = {}) -> Dictionary:
	return U.merged({
		"type": "star", "name": name, "mass": mass,
		"luminosity": Stellar.luminosity(mass), "teff": Stellar.effective_temp(mass),
	}, extra)

## o = { mA, mB, mC, aBin, aWorld, eWorld, worldNu = π, aOuter, eOuter,
##       outerIncl = 0, outerNu = 0.55π, world = {} }
static func circumbinary_triad(o: Dictionary) -> Array:
	var mA: float = o.mA; var mB: float = o.mB; var mC: float = o.mC
	var aBin: float = o.aBin; var aWorld: float = o.aWorld; var eWorld: float = o.eWorld
	var worldNu: float = U.nz(o.get("worldNu"), PI)
	var aOuter: float = o.aOuter; var eOuter: float = o.eOuter
	var outerIncl: float = U.nz(o.get("outerIncl"), 0.0)
	var outerNu: float = U.nz(o.get("outerNu"), PI * 0.55)
	var world: Dictionary = U.nz(o.get("world"), {})

	var Mab := mA + mB
	var kb := kepler(Mab, aBin, 0.0, 0.0, 0.0)
	var A := U.merged(_tri_star("Alpha", mA), { "pos": mulv(kb.pos, -mB / Mab), "vel": mulv(kb.vel, -mB / Mab) })
	var B := U.merged(_tri_star("Beta", mB), { "pos": mulv(kb.pos, mA / Mab), "vel": mulv(kb.vel, mA / Mab) })

	var kw := kepler(Mab, aWorld, eWorld, 0.0, worldNu)
	var P := U.merged({
		"type": "world", "name": "Trisolaris", "mass": 3.0e-6,
		"pos": kw.pos, "vel": kw.vel,
		"dayLength": 1.0 / 90.0, "obliquity": 0.41, "home": true,
	}, world)

	# The outer star orbits the barycentre of binary + world.
	var Min: float = Mab + float(P.mass)
	var Mtot := Min + mC
	var ko := kepler(Mtot, aOuter, eOuter, outerIncl, outerNu)
	var C := U.merged(_tri_star("Gamma", mC), { "pos": mulv(ko.pos, Min / Mtot), "vel": mulv(ko.vel, Min / Mtot) })
	var off := mulv(ko.pos, -mC / Mtot)
	var offv := mulv(ko.vel, -mC / Mtot)
	for b in [A, B, P]:
		b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv)

	return [A, B, C, P]

## o = { mA, mB, mC, aWorld, eWorld, worldNu = π, aBeta, eBeta, betaIncl = 0,
##       betaNu = 0, aOuter, eOuter, outerIncl = 0, outerNu = 0.55π, world = {} }
static func alpha_world_triad(o: Dictionary) -> Array:
	var mA: float = o.mA; var mB: float = o.mB; var mC: float = o.mC
	var aWorld: float = o.aWorld; var eWorld: float = o.eWorld
	var worldNu: float = U.nz(o.get("worldNu"), PI)
	var aBeta: float = o.aBeta; var eBeta: float = o.eBeta
	var betaIncl: float = U.nz(o.get("betaIncl"), 0.0)
	var betaNu: float = U.nz(o.get("betaNu"), 0.0)
	var aOuter: float = o.aOuter; var eOuter: float = o.eOuter
	var outerIncl: float = U.nz(o.get("outerIncl"), 0.0)
	var outerNu: float = U.nz(o.get("outerNu"), PI * 0.55)
	var world: Dictionary = U.nz(o.get("world"), {})

	# First level: Trisolaris is an S-type world around Alpha.
	var Mwp := mA + 3.0e-6
	var kw := kepler(Mwp, aWorld, eWorld, 0.0, worldNu)
	var A := U.merged(_tri_star("Alpha", mA), { "pos": mulv(kw.pos, -3.0e-6 / Mwp), "vel": mulv(kw.vel, -3.0e-6 / Mwp) })
	var P := U.merged({
		"type": "world", "name": "Trisolaris", "mass": 3.0e-6,
		"pos": mulv(kw.pos, mA / Mwp), "vel": mulv(kw.vel, mA / Mwp),
		"dayLength": 1.0 / 90.0, "obliquity": 0.41, "home": true,
	}, world)

	# Beta circles the Alpha + world pair; Gamma circles the whole nested system.
	var Minner := Mwp + mB
	var kb := kepler(Minner, aBeta, eBeta, betaIncl, betaNu)
	var B := U.merged(_tri_star("Beta", mB), { "pos": mulv(kb.pos, Mwp / Minner), "vel": mulv(kb.vel, Mwp / Minner) })
	var boff := mulv(kb.pos, -mB / Minner)
	var boffv := mulv(kb.vel, -mB / Minner)
	for b in [A, P]:
		b.pos = addv(b.pos, boff); b.vel = addv(b.vel, boffv)

	var Mtot := Minner + mC
	var ko := kepler(Mtot, aOuter, eOuter, outerIncl, outerNu)
	var C := U.merged(_tri_star("Gamma", mC), { "pos": mulv(ko.pos, Minner / Mtot), "vel": mulv(ko.vel, Minner / Mtot) })
	var off := mulv(ko.pos, -mC / Mtot)
	var offv := mulv(ko.vel, -mC / Mtot)
	for b in [A, B, P]:
		b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv)

	return [A, B, C, P]

# A 2+2 hierarchy parked near its stability boundary, for a non-repeating sky: Alpha
# with the world at aP, and a tight Beta+Gamma pair (aBC) on a wide, eccentric,
# inclined orbit with periapsis q2 = a2(1 − e2). `qRatio` = q2 / aP is the knob that
# matters (docs/scenarios.md).
## o = { mA, mB, mC, aBC, eBC = 0.10, e2, i2, qRatio, fLight = 1.0,
##       eP = 0.04, nuP = 0, nu2 = π, nuBC = 0, world = {} }
static func wandering_triad(o: Dictionary) -> Array:
	var mA: float = o.mA; var mB: float = o.mB; var mC: float = o.mC
	var aBC: float = o.aBC
	var eBC: float = U.nz(o.get("eBC"), 0.10)
	var e2: float = o.e2; var i2: float = o.i2; var qRatio: float = o.qRatio
	var fLight: float = U.nz(o.get("fLight"), 1.0)
	var eP: float = U.nz(o.get("eP"), 0.04)
	var nuP: float = U.nz(o.get("nuP"), 0.0)
	var nu2: float = U.nz(o.get("nu2"), PI)
	var nuBC: float = U.nz(o.get("nuBC"), 0.0)
	var world: Dictionary = U.nz(o.get("world"), {})

	var mp := 3.0e-6
	# put the world where Alpha alone delivers `fLight` Earth-suns
	var aP := sqrt(Stellar.luminosity(mA) / fLight)
	var a2 := (qRatio * aP) / (1.0 - e2)

	# Real destruction distance, not the drawn radius, since it decides which close
	# passes the world survives.
	var star := func(name: String, mass: float) -> Dictionary:
		return {
			"type": "star", "name": name, "mass": mass,
			"luminosity": Stellar.luminosity(mass), "teff": Stellar.effective_temp(mass),
			"contactAU": Physics.roche_limit(mass),
		}

	# level 1: Trisolaris about Alpha
	var MAp := mA + mp
	var kp := kepler(MAp, aP, eP, 0.0, nuP)
	var A := U.merged(star.call("Alpha", mA), { "pos": mulv(kp.pos, -mp / MAp), "vel": mulv(kp.vel, -mp / MAp) })
	var P := U.merged({
		"type": "world", "name": "Trisolaris", "mass": mp,
		"pos": mulv(kp.pos, mA / MAp), "vel": mulv(kp.vel, mA / MAp),
		"dayLength": 1.0 / 90.0, "obliquity": 0.41, "home": true,
	}, world)

	# level 1b: the Beta-Gamma pair about its own barycentre
	var MBC := mB + mC
	var kbc := kepler(MBC, aBC, eBC, 0.0, nuBC)
	var B := U.merged(star.call("Beta", mB), { "pos": mulv(kbc.pos, -mC / MBC), "vel": mulv(kbc.vel, -mC / MBC) })
	var C := U.merged(star.call("Gamma", mC), { "pos": mulv(kbc.pos, mB / MBC), "vel": mulv(kbc.vel, mB / MBC) })

	# level 2: the pair's barycentre about Alpha's, inclined and eccentric
	var Mt := MAp + MBC
	var k2 := kepler(Mt, a2, e2, i2, nu2)
	for b in [B, C]:
		b.pos = addv(b.pos, k2.pos, MAp / Mt); b.vel = addv(b.vel, k2.vel, MAp / Mt)
	for b in [A, P]:
		b.pos = addv(b.pos, k2.pos, -MBC / Mt); b.vel = addv(b.vel, k2.vel, -MBC / Mt)

	return [A, B, C, P]

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

# THE TABLE
static var PRESETS: Dictionary = _make_presets()

static var PRESET_ORDER: Array = EduPresets.EDU_ORDER + ["blank", "stellar_zoo", "sirius", "vega", "achernar", "betelgeuse", "alphacen", "etacar", "hr_ladder", "trisolaris", "trisolaris_wander", "trisolaris_compact", "trisolaris_wide", "trisolaris_alpha", "trisolaris_chaos", "sandbox", "solar", "threebody", "binarystar", "bhmerger", "nsmerger", "feeding"]

static func _make_presets() -> Dictionary:
	var P := {}
	# The teaching scenarios (sim/edupresets.gd), merged so PRESETS is the one lookup.
	var edu: Dictionary = EduPresets.EDU_PRESETS
	for k in edu:
		P[k] = edu[k]
	P.sandbox = {
		"sky": { "env": "disc", "tilt": 0.42, "roll": 0.7 },
		"name": "Black Hole Sandbox",
		"blurb": "A 10 M☉ black hole with an illustrated accretion disc and lensing. Spawn bodies and watch their orbits and contact mergers.",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 34.0, "lensing": true,
		"build": func() -> Array: return _build_sandbox(),
	}

	P.solar = {
		"sky": { "env": "disc", "galactic": "j2000" },
		"name": "Solar System",
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

	P.threebody = {
		"sky": { "env": "globular", "tilt": 0.30, "roll": 1.4 },
		"name": "Three-Body (figure-eight)",
		"blurb": "The Chenciner–Montgomery choreography: three equal masses chasing each other along one shared figure-eight orbit. A real exact solution.",
		"sceneScale": 4.0, "bodyScale": 1.4, "camRadius": 22.0, "lensing": false,
		"build": func() -> Array: return _build_threebody(),
	}

	# Hierarchy design and long-run validation limits: docs/scenarios.md.
	P.trisolaris = {
		"sky": { "env": "disc", "tilt": 0.55, "roll": 0.35 },
		"name": "Trisolaris",
		"blurb": "Three suns, one world. Alpha and Beta form a tight binary; Trisolaris follows an eccentric orbit around both, while hot Gamma returns every 51 years. Changing sunlight drives temperate seasons and cold spells.",
		"sceneScale": 4.0, "bodyScale": 0.55, "camRadius": 20.0, "lensing": false,
		# Resolve the short inner-binary period; long-run orbital extent needs a separate check.
		"timeScale": 0.35, "maxStep": 4e-4,
		"surface": true, "focus": "Alpha", "mesh": false,                  # offers the view-from-the-ground camera
		"climate": { "mixedLayer": 12.0, "T0": 288.0 },
		"build": func() -> Array: return _build_trisolaris(),
	}

	# A more compact P-type hierarchy with brighter illumination.
	P.trisolaris_compact = {
		"sky": { "env": "disc", "tilt": 0.50, "roll": 0.65 },
		"name": "Trisolaris - Compact Haven",
		"blurb": "A compact, bright hierarchy: Trisolaris circles Alpha and Beta at 1.35 AU while Gamma sweeps the 15 AU outer orbit. Three suns and stronger encounters change the sunlight reaching the world.",
		"sceneScale": 4.0, "bodyScale": 0.55, "camRadius": 20.0, "lensing": false,
		"timeScale": 0.35, "maxStep": 4e-4,
		"surface": true, "focus": "Alpha", "mesh": false,
		"climate": { "mixedLayer": 12.0, "T0": 288.0 },
		"build": func() -> Array: return circumbinary_triad({
			"mA": 1.15, "mB": 0.75, "mC": 1.55,
			"aBin": 0.24, "aWorld": 1.35, "eWorld": 0.22,
			"aOuter": 15.0, "eOuter": 0.22, "outerIncl": 12.0 * PI / 180.0,
			"outerNu": PI * 0.65,
		}),
	}

	# A wide P-type hierarchy: a long outer period and a big seasonal cycle.
	P.trisolaris_wide = {
		"sky": { "env": "disc", "tilt": 0.60, "roll": 0.10 },
		"name": "Trisolaris - Wide Seasons",
		"blurb": "A wide circumbinary world: Alpha and Beta are 0.55 AU apart, Trisolaris follows a 2.6 AU eccentric orbit, and Gamma returns every century from 36 AU.",
		"sceneScale": 3.0, "bodyScale": 0.55, "camRadius": 28.0, "lensing": false,
		"timeScale": 0.35, "maxStep": 4e-4,
		"surface": true, "focus": "Alpha", "mesh": false,
		"climate": { "mixedLayer": 18.0, "T0": 288.0 },
		"build": func() -> Array: return circumbinary_triad({
			"mA": 1.05, "mB": 0.90, "mC": 1.65,
			"aBin": 0.55, "aWorld": 2.60, "eWorld": 0.28,
			"aOuter": 36.0, "eOuter": 0.25, "outerIncl": 18.0 * PI / 180.0,
			"outerNu": PI * 0.40,
		}),
	}

	# S-type: the world orbits Alpha, Beta orbits that pair, Gamma orbits everything.
	P.trisolaris_alpha = {
		"sky": { "env": "disc", "tilt": 0.46, "roll": 1.05 },
		"name": "Trisolaris - Alpha's Refuge",
		"blurb": "An S-type solution: Trisolaris orbits Alpha at 0.8 AU, Beta circles the pair at 6.5 AU, and Gamma stays out at 52 AU.",
		"sceneScale": 2.4, "bodyScale": 0.55, "camRadius": 24.0, "lensing": false,
		"timeScale": 0.35, "maxStep": 4e-4,
		"surface": true, "focus": "Alpha", "mesh": false,
		"climate": { "mixedLayer": 14.0, "T0": 288.0 },
		"build": func() -> Array: return alpha_world_triad({
			"mA": 1.10, "mB": 0.80, "mC": 1.60,
			"aWorld": 0.80, "eWorld": 0.12, "worldNu": PI,
			"aBeta": 6.50, "eBeta": 0.18, "betaIncl": 8.0 * PI / 180.0, "betaNu": 0.90,
			"aOuter": 52.0, "eOuter": 0.20, "outerIncl": 18.0 * PI / 180.0,
			"outerNu": PI * 0.60,
		}),
	}

	# TRISOLARIS — WANDERING SUNS: built for the sky. A 2+2 hierarchy just inside the
	# chaotic region; each 3.8-year passage kicks the world's orbit, so no two returns
	# look alike. Nothing is scripted. Ensemble statistics (how many suns show a disc,
	# insolation, lifetimes) are in docs/scenarios.md; a single run can't reproduce them.
	P.trisolaris_wander = {
		"sky": { "env": "disc", "tilt": 0.52, "roll": 0.85 },
		"name": "Trisolaris — Wandering Suns",
		"blurb": "Three suns that genuinely wander. A tight Beta+Gamma pair dives past the home sun every 3.8 years on a chaotically evolving inclined orbit, so the sky is never the same twice: one sun 21% of the time, two 44%, three 32%, dark 3% — against two-suns-always for the other architectures. Stand on the planet (V); this is the one built for the view. Unlike them it is not stable, and it is not meant to be: the world lives a few centuries, then is ejected or torn apart.",
		"sceneScale": 4.0, "bodyScale": 0.20, "camRadius": 18.0, "lensing": false,
		# A tighter step cap for the close passes (drift 6e-5 over 1500 years).
		"timeScale": 0.35, "maxStep": 3e-4,
		"surface": true, "focus": "Alpha", "mesh": false,
		# a deeper mixed layer than the flagship: the swings here are sharper, and
		# 20 m of ocean is what keeps them eras rather than weather.
		"climate": { "mixedLayer": 20.0, "T0": 288.0 },
		"build": func() -> Array: return wandering_triad({
			"mA": 0.58, "mB": 1.25, "mC": 0.78,
			"aBC": 0.45, "eBC": 0.10,
			"e2": 0.50, "i2": 22.0 * PI / 180.0,
			"qRatio": 5.0, "fLight": 1.0,
			"eP": 0.04, "nuP": 0.9, "nu2": PI, "nuBC": 2.1,
		}),
	}

	# A genuine non-hierarchical three-body system: expect the planet to be flung out,
	# swallowed or ejected within centuries. Reload to reroll.
	P.trisolaris_chaos = {
		"sky": { "env": "disc", "tilt": 0.55, "roll": 0.35 },
		"name": "Trisolaris — Chaotic Era",
		"blurb": "The same three suns with NO protective hierarchy — a true chaotic three-body system. Trisolaris gets thrown between the stars, roasted, frozen, and usually ejected or consumed within a few centuries. This is the version that has no solution.",
		"sceneScale": 3.0, "bodyScale": 0.55, "camRadius": 40.0, "lensing": false,
		"timeScale": 0.35, "maxStep": 6e-4,
		"surface": true, "focus": "Alpha", "mesh": false,
		"climate": { "mixedLayer": 10.0, "T0": 288.0 },
		"build": func() -> Array: return _build_trisolaris_chaos(),
	}

	P.bhmerger = {
		"sky": { "env": "halo", "tilt": 0.22, "roll": 2.6 },
		"name": "Binary Black Hole Orbit",
		"blurb": "A wide binary of 36 and 29 solar masses, lensing the sky behind them.",
		"sceneScale": 60.0, "bodyScale": 1.0, "camRadius": 72.0, "lensing": true, "timeScale": 0.15, "maxStep": 5e-5,
		"build": func() -> Array: return binary(36.0, 29.0, 0.45,
			{ "type": "bh", "name": "BH-A" },
			{ "type": "bh", "name": "BH-B" }),
	}

	P.nsmerger = {
		"sky": { "env": "starburst", "tilt": 0.48, "roll": 1.9 },
		"name": "Binary Neutron Star Orbit",
		"blurb": "A wide pair of neutron stars with sweeping pulsar beams. This view illustrates their orbit; it does not simulate an inspiral, kilonova or merger waveform.",
		"sceneScale": 45.0, "bodyScale": 1.0, "camRadius": 26.0, "lensing": false, "timeScale": 0.15, "maxStep": 5e-5,
		"build": func() -> Array: return binary(1.45, 1.35, 0.35,
			{ "type": "neutron", "name": "NS-A", "visualSpinRadS": 22.0 },
			{ "type": "neutron", "name": "NS-B", "visualSpinRadS": 16.0 }),
	}

	P.binarystar = {
		"sky": { "env": "starburst", "tilt": 0.50, "roll": 0.9 },
		"name": "Illustrative Stellar Inspiral",
		"blurb": "Two stars lose orbital energy through exaggerated drag and can reach physical contact. This illustrates orbital decay; it does not model mass transfer, stellar envelopes or a luminous red nova.",
		"sceneScale": 3.0, "bodyScale": 1.0, "camRadius": 16.0, "lensing": false, "gwBoost": 4e17, "timeScale": 0.5,
		"build": func() -> Array: return binary(1.1, 0.9, 2.5,
			{ "type": "star", "name": "Star A", "mass": 1.1, "color": 0xfff0d0, "glow": 0xffaa44, "emitsGW": true },
			{ "type": "star", "name": "Star B", "mass": 0.9, "color": 0xffd0a0, "glow": 0xff8030, "emitsGW": true }),
	}

	P.feeding = {
		"sky": { "env": "core", "tilt": 0.36, "roll": 1.2 },
		"name": "Black Hole and Companion",
		"blurb": "A star orbits a 12 M☉ black hole, with both bodies drawn at their physical sizes. The gas stream illustrates how stripped material could flow toward the hole; the star keeps its mass until contact. Focus Singularity for a close view of its shadow and illustrated disc.",
		"sceneScale": 200.0, "bodyScale": 1.0, "camRadius": 30.0, "lensing": true, "discOuter": 9.0,
		"trueScale": true, "timeScale": 1e-4, "maxStep": 1e-5,
		"build": func() -> Array: return _build_feeding(),
	}

	# BLANK CANVAS: empty, and new bodies arrive at rest, so the only motion is what
	# gravity makes of what you place. Slow time scale, since a pair released a few AU
	# apart falls together in a couple of years.
	P.blank = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 1.6 },
		"name": "Blank Canvas",
		"blurb": "An empty scene, and the one place where Spawn puts things down at rest instead of into an orbit. Nothing moves until gravity moves it, so whatever happens next is entirely yours: release two bodies and watch them fall together, or place three and find out what the three-body problem does to your arrangement. Build the objects in the Foundry below — the mass, spin and composition sliders all apply — and paint rings and belts onto them. (Nothing here emits light, so until you spawn a star the scene is lit by a lamp riding the camera. It is a viewing aid and it switches off the moment there is a real star to light things.)",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 26.0, "lensing": false, "mesh": true,
		"timeScale": 0.25, "maxStep": 2e-3,
		"spawnAtRest": true,
		"build": func() -> Array: return [],
	}

	# REAL STARS, from sim/starcat.gd, all at true scale, since comparing exaggerated
	# radii compares drawing conventions.

	P.stellar_zoo = {
		"sky": { "env": "disc", "tilt": 0.34, "roll": 1.15 },
		"name": "The Stellar Zoo",
		"blurb": "Ten famous stars at their true relative sizes, from Betelgeuse — whose photosphere would reach the asteroid belt — down to Sirius B, an Earth-sized white dwarf. That is a range of 90 000 to 1, so most of them are points until you fly to them. They are on genuinely circular orbits about their common centre of mass, computed from the real N-body force at t = 0; a ring of unequal masses has no stable mode, so left running it will buckle and come apart. That is the correct answer, not a bug.",
		"sceneScale": 0.5, "bodyScale": 1.0, "camRadius": 60.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 1.5, "maxStep": 2e-3,
		"build": func() -> Array: return Starcat.star_ring(["betelgeuse", "rigel", "aldebaran", "polaris", "achernar",
				"bellatrix", "vega", "siriusA", "sun", "siriusB"], 70.0),
	}

	P.sirius = {
		"sky": { "env": "disc", "tilt": 0.40, "roll": 2.4 },
		"name": "Sirius A & B",
		"blurb": "The real orbit: a = 7.50 AU, e = 0.59, period 50.13 years. Sirius A is an ordinary A1 star; Sirius B beside it has 1.02 solar masses packed into the volume of Earth, held up by electron degeneracy alone. Its existence was deduced from Sirius A wobbling, forty years before anyone saw it. At true scale B is a point of light — which is exactly the observational problem that made it so hard to find.",
		"sceneScale": 3.0, "bodyScale": 1.0, "camRadius": 40.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 3.0, "maxStep": 1e-3,
		"build": func() -> Array: return Starcat.real_binary("siriusA", "siriusB", { "a": 7.4957, "e": 0.5923, "incl": 0.24, "nu": 2.2 }),
	}

	P.vega = {
		"sky": { "env": "disc", "tilt": 0.28, "roll": 0.5 },
		"name": "Vega — a star seen pole-on",
		"blurb": "Vega spins at 236 km/s, 88% of the speed at which it would fly apart, and we happen to look almost straight down its rotation axis. That is why it was the photometric zero point for a century and why the calibration was quietly wrong: we were measuring its hot pole. The bulge and the pole-to-equator temperature gradient here are not artistic — the measured rotation predicts an equatorial radius 1.192 times the polar against 1.193 observed, and von Zeipel gravity darkening then gives a 10 260 K pole over an 8 610 K equator against 10 070 / 8 910 measured. (Vega also has a debris disc, but it runs from 86 to 200 AU — twenty thousand times the width of the star — so there is no single zoom that shows you both.)",
		"sceneScale": 182.0, "bodyScale": 1.0, "camRadius": 9.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.2, "maxStep": 1e-3,
		"build": func() -> Array:
			var v := Starcat.star_spec("vega", { "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] })
			return [v],
	}

	P.achernar = {
		"sky": { "env": "disc", "tilt": 0.62, "roll": 1.8 },
		"name": "Achernar — the flattest star",
		"blurb": "Its equator sits 35% further from the centre than its poles, which is the most extreme rotational distortion measured on any bright star. The hard limit is 1.5: at that ratio the equator is in orbit and material simply leaves, and nothing that stays in one piece can be flatter. Achernar is close enough to it that it really is throwing off a disc of its own gas — the \"e\" in its spectral type B6Vep.",
		"sceneScale": 64.0, "bodyScale": 1.0, "camRadius": 11.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.2, "maxStep": 1e-3,
		"paint": [{ "kind": "ring", "body": "Achernar", "inner": 0.052, "outer": 0.13, "tilt": 0.0, "color": 0xffd0b0, "density": 0.7, "decretion": true }],
		"build": func() -> Array: return [Starcat.star_spec("achernar", { "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] })],
	}

	P.betelgeuse = {
		"sky": { "env": "disc", "tilt": 0.30, "roll": 2.9 },
		"name": "Betelgeuse",
		"blurb": "A red supergiant of 16.5 solar masses and 764 solar radii — put it where the Sun is and its surface would reach past the asteroid belt, swallowing Mercury, Venus, Earth and Mars. Jupiter and Saturn are drawn here at their real orbital distances, to scale, so you can see that Jupiter’s orbit is the first one that clears it. Its interior is the onion: an iron-free carbon–oxygen core under helium and hydrogen shells, and almost all of that enormous volume is emptier than a laboratory vacuum.",
		"sceneScale": 2.2, "bodyScale": 1.0, "camRadius": 34.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.4, "maxStep": 2e-3,
		"build": func() -> Array: return _build_betelgeuse(),
	}

	P.alphacen = {
		"sky": { "env": "disc", "tilt": 0.44, "roll": 0.2 },
		"name": "Alpha Centauri",
		"blurb": "The real nearest system, with the real orbit: A and B swing between 11.2 and 35.6 AU on an 80-year, e = 0.52 ellipse. Proxima is bound to the pair but 13 000 AU out — so far that it takes 550 000 years to go round once, and it is off screen at any zoom that shows the binary. Proxima b orbits it in 11 days, inside a habitable zone that is inside Mercury’s distance, around a star that flares hard enough to strip an atmosphere.",
		"sceneScale": 1.6, "bodyScale": 1.0, "camRadius": 60.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 4.0, "maxStep": 2e-3,
		"build": func() -> Array: return _build_alphacen(),
	}

	P.etacar = {
		"sky": { "env": "starburst", "tilt": 0.52, "roll": 1.35 },
		"name": "Eta Carinae — against the Eddington limit",
		"blurb": "A hundred solar masses radiating five million times the Sun. At that luminosity the radiation pressure pushing outward on free electrons is comparable to the star’s own gravity holding it in — L/L_Edd is near one, and its outer layers are barely bound at all. In the 1840s it threw off somewhere between ten and forty solar masses in a single eruption, briefly became the second brightest star in the sky, and survived. The debris is the Homunculus Nebula, expanding at its measured 650 km/s — drawn at 26 AU rather than its true 38 000, because the binary that threw it off is 15 AU across and there is no single frame that holds both.",
		"sceneScale": 0.9, "bodyScale": 1.0, "camRadius": 78.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.3, "maxStep": 2e-3,
		"paint": [{ "kind": "cloud", "body": "Eta Carinae A", "radius": 26.0, "lobes": 2, "color": 0xffcf9a, "density": 0.85, "expand": 0.137 }],
		"build": func() -> Array: return _build_etacar(),
	}

	P.hr_ladder = {
		"sky": { "env": "globular", "tilt": 0.36, "roll": 0.9 },
		"name": "The Main Sequence, end to end",
		"blurb": "Eleven stars from 0.1 to 60 solar masses, every one of them burning hydrogen in its core — the same process, over a factor of 600 in mass. Everything else changes: the red dwarf at one end is 3000 K and will last ten trillion years; the O star at the other is 45 000 K, four hundred thousand times brighter, and will be gone in three million. Sizes are exaggerated here rather than true, because this is the one comparison where readability beats honesty; hit \"Sizes: Real\" to see what it actually looks like.",
		"sceneScale": 1.0, "bodyScale": 0.9, "camRadius": 46.0, "lensing": false, "mesh": false,
		"timeScale": 0.5, "maxStep": 2e-3,
		"build": func() -> Array: return _build_hr_ladder(),
	}
	return P

# BUILDS — the bodies of the `build()` functions, as static functions so the
# table above stays readable.
static func _build_sandbox() -> Array:
	var Mbh := 10.0
	var bodies: Array = [{ "type": "bh", "name": "Singularity", "mass": Mbh, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }]
	bodies.append(orbiter(Mbh, 4.5, { "type": "gas-giant", "name": "Gas Giant", "palette": "jupiter" }, 0.6))
	bodies.append(orbiter(Mbh, 7.0, { "type": "star", "name": "Companion Star", "mass": 1.2 }, 3.4))
	return bodies

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
	# what it's made of: albedo, greenhouse, and the dominant volatile's condensation
	# temperature.
	# cloudCover is the fraction under cloud thick enough to hide the ground: MODIS's
	# 0.67 total less the thin cirrus the decks don't draw.
	var earth := { "type": "planet", "name": "Earth", "mass": m_earth, "radiusKm": 6371.0,
		"atmosphere": true, "land": 0.32, "biota": 1.0, "albedo": 0.306, "greenhouse": 0.61,
		"obliquity": 0.4091, "cloudCover": 0.44, "season": 11.0,
		# The oceans' tide, which a uniform elastic sphere can't give: k2 (Lambeck 1980)
		# and the lag that recedes the Moon 3.8 cm/yr (Neron de Surgy & Laskar 1997).
		"k2": 0.299, "tideLagS": 638.0,
	}
	# The Moon, on its real orbit about Earth: a target inside Earth's SOI and an
	# airless body to land on. Its 5.1° tilt keeps eclipses to the nodes.
	var moon := { "type": "planet", "name": "Moon", "mass": m_moon, "radiusKm": 1737.4,
		"hot": true, "crater": 1.0, "regolith": 0x9a958c, "albedo": 0.12, "obliquity": 0.0268,
		"tidalLock": "Earth" }
	var emb := elements_state(Physics.G * (1.0 + m_earth + m_moon), SOLAR_ELEMENTS.EMB, t_cy)
	var rel := elements_state(Physics.G * (m_earth + m_moon), SOLAR_ELEMENTS.Moon, t_cy)
	var f_moon := m_moon / (m_earth + m_moon)
	earth.pos = addv(emb.pos, rel.pos, -f_moon); earth.vel = addv(emb.vel, rel.vel, -f_moon)
	moon.pos = addv(emb.pos, rel.pos, 1.0 - f_moon); moon.vel = addv(emb.vel, rel.vel, 1.0 - f_moon)
	var bodies := [
		sun,
		P.call(1.0 / 6023657.33, 2439.7, "planet", "Mercury", {
			"hot": true, "crater": 0.95, "regolith": 0x8b8279, "albedo": 0.12, "obliquity": 0.0006 }),
		# Venus's 737 K is stated: no greenhouse parameter reaches 2.4× its equilibrium
		# temperature.
		P.call(1.0 / 408523.719, 6051.8, "planet", "Venus", {
			"hot": true, "atmosphere": true, "atmColor": 0xffd9a0, "surfaceK": 737.0, "albedo": 0.77,
			"crater": 0.10, "regolith": 0xb08a5c, "cloudCover": 1.0, "cloudColor": 0xfff2d2,
			"atmThick": 2.4, "haze": 1.2, "obliquity": 3.096, "cloudSpin": 60.0 }),
		earth,
		moon,
		# Mars's caps are CO₂ (148 K), so they grow and retreat each winter.
		P.call(1.0 / 3098703.59, 3389.5, "planet", "Mars", {
			"hot": true, "atmosphere": true, "atmThick": 0.22, "atmColor": 0xd8b48c,
			"cloudCover": 0.10, "cloudColor": 0xe8d8c0, "haze": 0.25, "greenhouse": 0.95,
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
			"obliquity": 2.1386 }),
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

static func _build_threebody() -> Array:
	# exact figure-eight ICs for G=m=1; rescale velocities by 2π for G=4π².
	var k := 2.0 * PI
	var p := [0.97000436, -0.24308753]
	var v3 := [-0.93240737, -0.86473146]
	var colors := [0xffd9a0, 0xa0c8ff, 0xffa0a0]
	var glows := [0xff8040, 0x4080ff, 0xff4060]
	var star := func(i: int) -> Dictionary:
		return { "type": "star", "name": "Body %d" % i, "mass": 1.0, "color": colors[i - 1], "glow": glows[i - 1] }
	return [
		U.merged(star.call(1), { "pos": [p[0], 0.0, p[1]], "vel": [-v3[0] / 2.0 * k, 0.0, -v3[1] / 2.0 * k] }),
		U.merged(star.call(2), { "pos": [-p[0], 0.0, -p[1]], "vel": [-v3[0] / 2.0 * k, 0.0, -v3[1] / 2.0 * k] }),
		U.merged(star.call(3), { "pos": [0.0, 0.0, 0.0], "vel": [v3[0] * k, 0.0, v3[1] * k] }),
	]

static func _build_trisolaris(world_eccentricity: float = 0.20) -> Array:
	# Eccentricity-aware screening and the bounded numerical study: docs/scenarios.md.
	return circumbinary_triad({
		"mA": 1.20, "mB": 0.85, "mC": 2.00,
		"aBin": 0.35, "aWorld": 1.80, "eWorld": world_eccentricity,
		"aOuter": 22.0, "eOuter": 0.35, "outerIncl": 25.0 * PI / 180.0,
	})

static func _build_trisolaris_chaos() -> Array:
	var star := func(name: String, mass: float, extra: Dictionary = {}) -> Dictionary:
		return U.merged({
			"type": "star", "name": name, "mass": mass,
			"luminosity": Stellar.luminosity(mass), "teff": Stellar.effective_temp(mass),
		}, extra)
	# three comparable masses on a near-equilateral (Lagrange) layout, which
	# is unstable for mass ratios like these — it breaks up on its own.
	var ms := [1.20, 0.85, 2.00]
	var R := 3.2
	var Mt := 0.0
	for m in ms: Mt += m
	var names := ["Alpha", "Beta", "Gamma"]
	var bodies := []
	for i in ms.size():
		var m: float = ms[i]
		var th := (float(i) * 2.0 * PI) / 3.0
		var v := sqrt(Physics.G * Mt / (sqrt(3.0) * R)) * 0.96   # just off equilibrium
		bodies.append(U.merged(star.call(names[i], m), {
			"pos": [R * cos(th), 0.0, R * sin(th)],
			"vel": [-v * sin(th), 0.0, v * cos(th)],
		}))
	bodies.append({
		"type": "world", "name": "Trisolaris", "mass": 3e-6,
		"pos": [0.0, 0.0, 9.5], "vel": [-sqrt(Physics.G * Mt / 9.5) * 1.02, 0.0, 0.0],
		"dayLength": 1.0 / 90.0, "obliquity": 0.41, "home": true,
	})
	return bodies

static func _build_feeding() -> Array:
	# Close enough to show the illustrative stream, with physical surfaces still separated.
	return binary(12.0, 1.8, 0.018,
		{ "type": "bh", "name": "Singularity" },
		{ "type": "star", "name": "Companion Star", "color": 0xffe0a0, "glow": 0xff8040 })

static func _build_betelgeuse() -> Array:
	var B := Starcat.star_spec("betelgeuse", { "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] })
	return [
		B,
		Starcat.companion(B.mass, 5.203, { "type": "gas-giant", "name": "Jupiter's orbit", "mass": 9.5459e-4, "radiusKm": 69911.0, "palette": "jupiter" }, 0.4),
		Starcat.companion(B.mass, 9.537, { "type": "gas-giant", "name": "Saturn's orbit", "mass": 2.858e-4, "radiusKm": 58232.0, "palette": "saturn", "rings": true }, 3.1),
	]

static func _build_alphacen() -> Array:
	var pair := Starcat.real_binary("alphacenA", "alphacenB", { "a": 23.52, "e": 0.5179, "incl": 0.14, "nu": 1.1 })
	var P := Starcat.star_spec("proxima")
	# Proxima's real 13 000 AU is off-scene; it goes at 900 AU on the same bound path,
	# and the blurb says so.
	var m_pair: float = float(pair[0].mass) + float(pair[1].mass)
	var M: float = m_pair + float(P.mass)
	var a := 900.0
	var v := Physics.circular_speed(M, a)
	# Split the outer orbit about its barycentre, each side taking its mass share
	# (0.55 of circular speed with no radial velocity is apoapsis of e = 0.70).
	var p_share := m_pair / M
	var b_share: float = float(P.mass) / M
	var px := a * p_share
	var pv := v * p_share
	P.pos = [px, 0.0, 0.0]; P.vel = [0.0, 0.0, pv]
	for st in pair:
		st.pos[0] -= a * b_share; st.vel[2] -= v * b_share
	var pb := Starcat.companion(P.mass, 0.0485, {
		"type": "planet", "name": "Proxima b", "mass": 3.3e-6, "radiusKm": 7160.0, "hot": true,
	}, 1.0)
	pb.pos = [pb.pos[0] + px, pb.pos[1], pb.pos[2]]
	pb.vel = [pb.vel[0], pb.vel[1], pb.vel[2] + pv]
	return [pair[0], pair[1], P, pb]

static func _build_etacar() -> Array:
	var E := Starcat.star_spec("etacar", { "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] })
	# The real companion: ~30 M☉, 5.54-year orbit, e ≈ 0.9. Its periastron
	# passage is what makes the whole system flare in X-rays.
	var M: float = float(E.mass) + 30.0
	var a := 15.4
	var e := 0.9
	var nu := PI * 0.8
	var k := kepler(M, a, e, 0.2, nu)
	return [
		U.merged(E, { "pos": mulv(k.pos, -30.0 / M), "vel": mulv(k.vel, -30.0 / M) }),
		{ "type": "star", "name": "Eta Carinae B", "mass": 30.0, "radiusSun": 20.0, "teff": 37000.0,
			"luminosity": 8.0e5, "phase": Structure.phase_by_id("ms-mid").f,
			"pos": mulv(k.pos, float(E.mass) / M), "vel": mulv(k.vel, float(E.mass) / M) },
	]

static func _build_hr_ladder() -> Array:
	var masses := [0.1, 0.2, 0.4, 0.7, 1.0, 1.5, 2.5, 4.0, 9.0, 20.0, 60.0]
	var n := masses.size()
	var R := 26.0
	var specs := []
	var ths := []
	for i in n:
		var m: float = masses[i]
		var th := (float(i) / float(n)) * PI * 2.0
		specs.append({
			"type": "star", "name": "%s M☉" % _num(m), "mass": m,
			"luminosity": Stellar.luminosity(m), "teff": Stellar.effective_temp(m),
			"radiusSun": Structure.base_radius_sun(m), "phase": 0.5,
			"pos": [cos(th) * R, 0.0, sin(th) * R],
		})
		ths.append(th)
	# same exact circular-balance construction as Starcat.star_ring()
	for si in n:
		var s: Dictionary = specs[si]
		var ax := 0.0
		var az := 0.0
		for oi in n:
			if oi == si: continue
			var o: Dictionary = specs[oi]
			var dx: float = o.pos[0] - s.pos[0]
			var dz: float = o.pos[2] - s.pos[2]
			var d2 := dx * dx + dz * dz
			var d := sqrt(d2)
			ax += Physics.G * float(o.mass) / d2 * dx / d; az += Physics.G * float(o.mass) / d2 * dz / d
		var th: float = ths[si]
		var a_rad := maxf(-(ax * cos(th) + az * sin(th)), 1e-9)
		var v := sqrt(a_rad * R)
		s.vel = [-sin(th) * v, 0.0, cos(th) * v]
	return specs
