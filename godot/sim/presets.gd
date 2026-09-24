class_name Presets
extends RefCounted

# ============================================================================
# PRESET SCENARIOS
# Every spec is in REAL units: mass = M☉, pos = AU, vel = AU/yr.
# `sceneScale` = scene units per AU (rendering only). `bodyScale` exaggerates
# rendered body sizes (true-to-scale planets ARE sub-pixel — `trueScale: true`
# draws them honestly instead and leans on the point-source markers in
# sim/scale.gd to keep them visible). `radiusKm` supplies a real physical
# radius; without one, sim/scale.gd falls back to a mass–radius relation.
# `gwBoost` accelerates gravitational-wave inspiral so mergers are watchable.
#
# `sky` says WHERE IN THE UNIVERSE the system is, which sim/sky.gd turns into a
# background. `env` names one of SKY_ENVIRONMENTS — disc, core, globular, halo,
# starburst — and `tilt`/`roll` orient the galactic plane relative to the
# scene, deciding where the band crosses the view. Nothing here obliges the sky
# to be Earth's; a system in a globular cluster genuinely has thousands of
# bright stars and no band at all, and saying so costs two numbers.
#
# `env` also takes SEVERAL environments at once — ['globular', 'disc'], or
# { globular: 1, disc: 0.4 } for explicit weights — because they are
# populations rather than paint. A cluster's own stars and the galaxy behind
# them are both there, and the blend adds them; see blendEnvironments() in
# sim/sky.gd for why the shape terms take the mean instead. Any parameter
# written straight onto the spec overrides the blend, so "core, but without
# the dust" needs no sixth environment.
#
# PORT NOTE. A preset is a Dictionary with the web build's keys verbatim
# (`name`, `blurb`, `sceneScale`, `bodyScale`, `camRadius`, `lensing`, `sky`,
# `timeScale`, `maxStep`, `trueScale`, `surface`, `focus`, `mesh`, `climate`,
# `gwBoost`, `paint`, `discOuter`, `discIntensity`, `spawnAtRest`), and `build`
# is a Callable returning an Array of spec Dictionaries. A key the JS preset did
# not state is ABSENT here too, so `p.get("maxStep", 5e-3)` is `p.maxStep ??
# 5e-3`. Spec `pos`/`vel` are 3-element Arrays of floats (DVec3.from_array);
# colours in specs are the JS hex ints (sRGB — U.lin() them).
# ============================================================================

# The one source of randomness in any build: `orbiter`'s default phase, which
# the solar system uses so every load starts the planets somewhere new. It is
# randf() — as random as Math.random() was — unless a harness installs a
# deterministic generator here to compare a build against the web build's.
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

# ----------------------------------------------------------------------------
# Keplerian two-body relative state (position & velocity) for an orbit with
# semi-major axis a, eccentricity e, inclination incl, at true anomaly nu.
# Used to assemble hierarchical systems exactly rather than by eyeballing.
# ----------------------------------------------------------------------------
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

# JS Number→String for the few numbers that go into a name ("0.1", "4").
static func _num(x: float) -> String:
	if x == floor(x) and absf(x) < 1e15:
		return str(int(x))
	return str(x)

# Shared three-sun constructors. The nested Kepler states put every level at
# its own barycentre before the outer orbit is applied, which avoids the small
# but secular kick caused by simply placing the inner system at the origin.
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

	# The outer star orbits the barycentre of the binary + world, not the
	# binary alone. The distinction is tiny here, but keeps the construction
	# self-consistent and makes the helper safe for heavier test worlds too.
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

	# Second level: Beta circles the Alpha + world pair. Gamma then circles the
	# entire nested system, so neither outer orbit is started around a false
	# origin.
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

# ----------------------------------------------------------------------------
# A 2+2 hierarchy deliberately parked NEAR its stability boundary, which is the
# only architecture that gives the book's sky without the book's death sentence.
#
#   Alpha       the home sun. Trisolaris orbits it at aP, close in and tightly
#               bound, which is what lets the world survive at all.
#   Beta+Gamma  a tight pair (aBC) that together orbit Alpha on a wide, eccentric,
#               inclined orbit whose periapsis dives to q2 = a2(1 - e2).
#
# What makes the resulting sky non-repeating rather than merely periodic is that
# the encounters are strong and NOT in the secular regime. Each periapsis passage
# brings the pair to within q2 - aP of the world and delivers an impulsive kick to
# its orbit; near the Mardling-Aarseth stability boundary those kicks are large
# enough that the world's semi-major axis, eccentricity and orientation take a
# chaotic walk instead of averaging out. So no two passages find the world in the
# same place on the same orbit, and Beta and Gamma swing between flying-star
# points and discs that rival the home sun's, whirling around each other as they
# come. (Note that a modest `i2` is deliberate: below the ~39.2 deg Kozai-Lidov
# critical angle there is no eccentricity-inclination libration to speak of. The
# inclination here is not driving the chaos, it just denies the encounters a
# shared plane and keeps the suns from tracing one repeated line across the sky.)
#
# `qRatio` = q2 / aP is the single knob that matters. Below ~4 the world is
# stripped within decades; above ~6 the kicks weaken, the system relaxes toward a
# plain hierarchy, and the sky goes back to being predictable — measurably so, in
# a grid scan the one-sun fraction climbs from 21% to over 70%. See the preset.
# ----------------------------------------------------------------------------
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

	# A close pass is survivable here only because the destruction distance is the
	# real one. Left to the default, a body is destroyed on contact with its
	# *drawn* radius: for these stars that is 3.5-3.7x the true photosphere and
	# ~2x the Roche limit, and on the flagship preset's fatter drawing convention
	# it is ~9x and ~7x. That difference decides which close passes the world
	# walks away from, so it should not be a drawing choice. See attachVisual().
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

# circular orbit about a dominant central mass at the origin
# A satellite of a planet. It is placed relative to the PARENT'S ACTUAL STATE,
# not to where the parent's orbit nominally is: `orbiter` below puts planets at
# a random phase, so a moon built from the parent's semi-major axis alone lands
# tens of millions of kilometres from it and is on a solar orbit of its own
# within days. The moon's own circular velocity is added to whatever the parent
# is already doing, which is what makes it bound.
static func moon_of(parent_spec: Dictionary, dist_m: float, mass_sun: float, radius_km: float, name: String, extra: Dictionary = {}) -> Dictionary:
	var AU_M := 1.495978707e11
	var a := dist_m / AU_M
	var px: float = parent_spec.pos[0]; var py: float = parent_spec.pos[1]; var pz: float = parent_spec.pos[2]
	var vx: float = parent_spec.vel[0]; var vy: float = parent_spec.vel[1]; var vz: float = parent_spec.vel[2]
	# Offset along the parent's own radius vector, so the moon starts at its
	# planet's "noon" — an arbitrary but well-defined phase.
	# Math.hypot, in double precision (Vector2 is float32)
	var r := sqrt(px * px + pz * pz)
	if r == 0.0: r = 1.0
	var ux := px / r
	var uz := pz / r
	var v_moon := Physics.circular_speed(float(parent_spec.mass) + mass_sun, a)
	var o := U.merged({ "type": "planet", "name": name, "mass": mass_sun, "radiusKm": radius_km, "hot": true }, extra)
	o.pos = [px + ux * a, py, pz + uz * a]
	# perpendicular to the offset, in the same sense as the orrery's orbits
	o.vel = [vx + (-uz) * v_moon, vy, vz + ux * v_moon]
	return o

## `angle` defaults to a RANDOM phase (null → _rand() · 2π), as the JS default
## parameter did.
static func orbiter(Mc: float, a: float, spec: Dictionary, angle = null, incl: float = 0.0) -> Dictionary:
	var ang: float = (_rand() * PI * 2.0) if angle == null else float(angle)
	var v := Physics.circular_speed(Mc, a)
	var x := cos(ang) * a
	var z := sin(ang) * a
	var y := sin(incl) * x
	return U.merged(spec, { "pos": [x, y * 0.02, z], "vel": [-sin(ang) * v, 0.0, cos(ang) * v] })

# ============================================================================
# THE TABLE
# ============================================================================
static var PRESETS: Dictionary = _make_presets()

static var PRESET_ORDER: Array = EduPresets.EDU_ORDER + ["blank", "stellar_zoo", "sirius", "vega", "achernar", "betelgeuse", "alphacen", "etacar", "hr_ladder", "trisolaris", "trisolaris_wander", "trisolaris_compact", "trisolaris_wide", "trisolaris_alpha", "trisolaris_chaos", "sandbox", "solar", "threebody", "binarystar", "bhmerger", "nsmerger", "feeding"]

static func _make_presets() -> Dictionary:
	var P := {}
	# The teaching scenarios live in sim/edupresets.gd — same contract, same
	# units, merged here so PRESETS stays the ONE lookup every consumer uses.
	# Splitting the file was about length, not about kind: a scenario built for a
	# lesson is still just a scenario, and #edu_kepler has to work from the hash
	# and from the scenario list whether or not anyone is taking the course.
	var edu: Dictionary = EduPresets.EDU_PRESETS
	for k in edu:
		P[k] = edu[k]
	# --------------------------------------------------------------------------
	P.sandbox = {
		"sky": { "env": "disc", "tilt": 0.42, "roll": 0.7 },
		"name": "Black Hole Sandbox",
		"blurb": "A 10 M☉ black hole with a live accretion disc & lensing. Spawn bodies and watch them orbit, get shredded, and fall in.",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 34.0, "lensing": true,
		"build": func() -> Array: return _build_sandbox(),
	}

	# --------------------------------------------------------------------------
	P.solar = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 2.1 },
		"name": "Solar System",
		"blurb": "Real orbital distances, masses and body radii, G = 4π². Sizes default to TRUE scale — the planets are points until you fly to one. Toggle \"Sizes\" to get the readable, exaggerated view back. This is also the scenario to fly from: the Spaceflight section builds a real launch vehicle on the pad, and the Moon is here to land on.",
		"sceneScale": 1.0, "bodyScale": 0.5, "camRadius": 80.0, "lensing": false, "timeScale": 6.0,
		# The one preset where the bodies are drawn at their real geometric size.
		# See sim/scale.gd for why that needs a point-source fallback to be usable.
		"trueScale": true,
		"build": func() -> Array: return _build_solar(),
	}

	# --------------------------------------------------------------------------
	P.threebody = {
		"sky": { "env": "globular", "tilt": 0.30, "roll": 1.4 },
		"name": "Three-Body (figure-eight)",
		"blurb": "The Chenciner–Montgomery choreography: three equal masses chasing each other along one shared figure-eight orbit. A real exact solution.",
		"sceneScale": 4.0, "bodyScale": 1.4, "camRadius": 22.0, "lensing": false,
		"build": func() -> Array: return _build_threebody(),
	}

	# --------------------------------------------------------------------------
	# TRISOLARIS
	# --------------------------------------------------------------------------
	# Three suns and a world, arranged so it actually survives. A raw three-body
	# system with a planet in it disintegrates in a few hundred years, which is
	# dramatic but useless for watching a climate evolve. So this uses the one
	# arrangement nature actually permits for long-lived multiple-star systems: a
	# HIERARCHY.
	#
	#   · Alpha (1.20 M☉, F-type) and Beta (0.85 M☉, K-type) are a tight pair,
	#     0.35 AU apart, circling each other every 53 days.
	#   · Trisolaris orbits BOTH of them at 1.80 AU — a circumbinary "P-type"
	#     orbit, comfortably outside the Holman–Wiegert stability limit
	#     (a_crit ≈ 2.3 a_bin ≈ 0.8 AU), on a deliberately eccentric path (e = 0.42).
	#   · Gamma (2.00 M☉, hot A-type, 11 L☉) sweeps around the whole inner system
	#     on a 51-year, 25°-inclined orbit.
	#
	# Verified by integration: the configuration holds for 60 000+ simulated years
	# with a relative energy drift of ~1e-7. The planet's insolation still swings
	# by a factor of ~9 — from 0.34 to 3.1 Earth-suns — which is what drives the
	# Stable and Chaotic Eras. The chaos is in the CLIMATE, not in the orbits.
	P.trisolaris = {
		"sky": { "env": "disc", "tilt": 0.55, "roll": 0.35 },
		"name": "Trisolaris",
		"blurb": "Three suns, one world. A tight binary (Alpha + Beta) with Trisolaris on a wide eccentric circumbinary orbit, and hot Gamma sweeping past every 51 years. Insolation swings 9× — the Stable and Chaotic Eras are emergent, not scripted. Stable for 60 000+ years.",
		"sceneScale": 4.0, "bodyScale": 0.55, "camRadius": 20.0, "lensing": false,
		# The tighter cap keeps the 60 000-year phase error bounded; 8e-4 is fast
		# enough to look fine but eventually lets this particular hierarchy drift.
		"timeScale": 0.35, "maxStep": 4e-4,
		"surface": true, "focus": "Alpha", "mesh": false,                  # offers the view-from-the-ground camera
		"climate": { "mixedLayer": 12.0, "T0": 288.0 },
		"build": func() -> Array: return _build_trisolaris(),
	}

	# A more compact P-type hierarchy. The inner binary is tighter and Gamma
	# comes closer, but the world still has >4 binary separations at periapsis
	# and Gamma stays >7 world apocentres away at its closest approach.
	P.trisolaris_compact = {
		"sky": { "env": "disc", "tilt": 0.50, "roll": 0.65 },
		"name": "Trisolaris - Compact Haven",
		"blurb": "A compact, bright hierarchy: Trisolaris circles Alpha and Beta at 1.35 AU while Gamma sweeps the 15 AU outer orbit. Three suns, stronger encounters, and a stable 60 000-year architecture.",
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

	# A wide P-type hierarchy trades encounter strength for a long outer period.
	# The planet's 2.6 AU orbit has room for a large seasonal cycle without
	# approaching the circumbinary stability boundary.
	P.trisolaris_wide = {
		"sky": { "env": "disc", "tilt": 0.60, "roll": 0.10 },
		"name": "Trisolaris - Wide Seasons",
		"blurb": "A wide circumbinary world: Alpha and Beta are 0.55 AU apart, Trisolaris follows a 2.6 AU eccentric orbit, and Gamma returns every century from 36 AU. Verified stable for 60 000 simulated years.",
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

	# The world need not be circumbinary. This S-type solution nests the world
	# around Alpha, Beta around that pair, and Gamma around the whole hierarchy.
	# It is a useful counterexample to the first preset: the planet gets a
	# familiar dominant sun while the other two still make a changing sky.
	P.trisolaris_alpha = {
		"sky": { "env": "disc", "tilt": 0.46, "roll": 1.05 },
		"name": "Trisolaris - Alpha's Refuge",
		"blurb": "An S-type solution: Trisolaris orbits Alpha at 0.8 AU, Beta circles the pair at 6.5 AU, and Gamma stays out at 52 AU. The planet remains bound to its home sun for 60 000+ simulated years.",
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

	# --------------------------------------------------------------------------
	# TRISOLARIS — WANDERING SUNS
	# --------------------------------------------------------------------------
	# The other four Trisolaris presets put the chaos in the climate and keep the
	# orbits tame, which is what makes them last 60 000 years — but it also makes
	# their sky honest to the physics and *not* to the book. Alpha and Beta stay a
	# fixed pair overhead and Gamma sits 20 AU out contributing 0.04 S⊕: a third
	# sun you have to be told about. Nobody would write a religion around it.
	#
	# This one is built the other way round, for the SKY. It is a 2+2 hierarchy
	# parked just inside the region where secular evolution goes chaotic:
	#
	#   Alpha  0.58 M☉  K5, 4163 K   the home sun, 0.34 AU away — an orange disc
	#                                twice the width of Earth's Sun
	#   Beta   1.25 M☉  F5, 6770 K   — a tight 0.45 AU pair with a 78-day period,
	#   Gamma  0.78 M☉  K2, 4973 K     the two of them on one wide e = 0.50 orbit
	#                                  inclined 22° to the world's own
	#
	# The pair's periapsis dives to 1.68 AU — five times the world's own orbit,
	# which is close enough for Beta and Gamma to swell into discs and pull the
	# world's orbit around, and far enough that it is not simply torn away on the
	# first pass. Every 3.8 years they come back, and each passage kicks the world's
	# orbit hard enough that this close to the stability boundary the kicks compound
	# chaotically rather than averaging away — so no two returns find the world where
	# the last one left it, and none of them look alike. Nothing here is scripted or
	# animated: the suns wander because the three-body problem says they do.
	#
	# Measured over a 24-run ensemble at this preset's own step cap (75 203 samples;
	# see the note on determinism below), counting how many of the three are close
	# enough to show a real disc — at least a quarter of the width Earth's Sun
	# shows us, which is a statement about distance and not about how big this sim
	# chooses to draw them:
	#
	#     none               3%        true dark. Rare, and it does happen
	#     one               21%        a Stable Era. The sky you could plan a harvest by
	#     two               44%        the ordinary state of affairs
	#     three             32%        a tri-solar day, and the world bakes
	#
	# The same measurement on the flagship preset gives a flat 0 / 0 / 100 / 0 —
	# two suns, always, never changing size. Insolation here runs 0.64 (5th pct) to
	# 3.68 (95th), tailing to 7.8 at the 99th, and stays in the liquid-water band
	# 91% of the time. How many are above the HORIZON at any moment is then set by
	# the world's own 4-day rotation on top of that: near a close approach a single
	# day carries you through all four of those skies and back.
	#
	# ON DETERMINISM. A chaotic system's Lyapunov time is of order its orbital
	# period, so after a few decades this scenario's trajectory is set by
	# floating-point rounding, not by these initial conditions — your run will NOT
	# match the numbers above shot for shot, and cannot. Everything quoted here is
	# therefore pooled over 24 runs differing only in starting phase, which is the
	# only kind of claim that means anything about a system like this. On that
	# ensemble the world lives a median of 382 years (shortest 92, longest 3437) and
	# always ends: 14 of the 24 runs ejected it into the dark, the other 10 fed it
	# to a star's Roche limit. It is supposed to end. That is the premise of the
	# book. Worst-case energy drift across those runs is 5.3e-4.
	P.trisolaris_wander = {
		"sky": { "env": "disc", "tilt": 0.52, "roll": 0.85 },
		"name": "Trisolaris — Wandering Suns",
		"blurb": "Three suns that genuinely wander. A tight Beta+Gamma pair dives past the home sun every 3.8 years on a chaotically evolving inclined orbit, so the sky is never the same twice: one sun 21% of the time, two 44%, three 32%, dark 3% — against two-suns-always for the other architectures. Stand on the planet (V); this is the one built for the view. Unlike them it is not stable, and it is not meant to be: the world lives a few centuries, then is ejected or torn apart.",
		"sceneScale": 4.0, "bodyScale": 0.20, "camRadius": 18.0, "lensing": false,
		# Close passes are the whole point here, so the step cap is tighter than the
		# stable presets'. At 3e-4 the worst-case relative energy drift is 6e-5 over
		# 1500 years and 5.3e-4 across the full 24-run ensemble; halving the cap again
		# changes neither the lifetimes nor the sky statistics.
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

	# --------------------------------------------------------------------------
	# The honest version: a genuine, non-hierarchical three-body system. This is
	# what the Trisolarans actually live with — and it is why they want to leave.
	# Expect the planet to be flung into a wildly eccentric orbit, swallowed, or
	# ejected outright, usually within a few hundred years. Reload to reroll.
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

	# --------------------------------------------------------------------------
	P.bhmerger = {
		"sky": { "env": "halo", "tilt": 0.22, "roll": 2.6 },
		"name": "Binary Black Hole Merger",
		"blurb": "Two stellar-mass black holes spiral together, shedding orbital energy to gravitational waves until they coalesce (à la GW150914). Inspiral rate exaggerated.",
		"sceneScale": 60.0, "bodyScale": 1.0, "camRadius": 72.0, "lensing": true, "gwBoost": 3e10, "timeScale": 0.15, "maxStep": 5e-5,
		"build": func() -> Array: return binary(36.0, 29.0, 0.45,
			{ "type": "bh", "name": "BH-A", "rs": 0.02 },
			{ "type": "bh", "name": "BH-B", "rs": 0.016 }),
	}

	# --------------------------------------------------------------------------
	P.nsmerger = {
		"sky": { "env": "starburst", "tilt": 0.48, "roll": 1.9 },
		"name": "Neutron Star Merger",
		"blurb": "Two neutron stars inspiral and collide in a kilonova (à la GW170817). Watch the pulsar beams sweep as they whirl together.",
		"sceneScale": 45.0, "bodyScale": 1.0, "camRadius": 26.0, "lensing": false, "gwBoost": 1.8e14, "timeScale": 0.15, "maxStep": 5e-5,
		"build": func() -> Array: return binary(1.45, 1.35, 0.35,
			{ "type": "neutron", "name": "NS-A", "spin": 22.0 },
			{ "type": "neutron", "name": "NS-B", "spin": 16.0 }),
	}

	# --------------------------------------------------------------------------
	P.binarystar = {
		"sky": { "env": "starburst", "tilt": 0.50, "roll": 0.9 },
		"name": "Binary Star Merger",
		"blurb": "A close contact binary: the two stars slowly spiral together and merge into one more massive star (a luminous red nova). Takes ~30 s — speed it up or slow it down with the slider.",
		"sceneScale": 3.0, "bodyScale": 1.0, "camRadius": 16.0, "lensing": false, "gwBoost": 4e17, "timeScale": 0.5,
		"build": func() -> Array: return binary(1.1, 0.9, 2.5,
			{ "type": "star", "name": "Star A", "mass": 1.1, "color": 0xfff0d0, "glow": 0xffaa44, "emitsGW": true },
			{ "type": "star", "name": "Star B", "mass": 0.9, "color": 0xffd0a0, "glow": 0xff8030, "emitsGW": true }),
	}

	# --------------------------------------------------------------------------
	P.feeding = {
		"sky": { "env": "core", "tilt": 0.36, "roll": 1.2 },
		"name": "Black Hole Devouring a Star",
		"blurb": "A star on a plunging orbit is tidally stripped, trailing a stream of gas onto the black hole.",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 30.0, "lensing": true, "discOuter": 9.0,
		"build": func() -> Array: return _build_feeding(),
	}

	# ==========================================================================
	# BLANK CANVAS
	# --------------------------------------------------------------------------
	# Nothing in it, nothing moving, and — unlike every other preset — new bodies
	# arrive AT REST rather than on a circular orbit about the dominant mass.
	#
	# That combination is what makes it a workbench rather than a scenario. With
	# an empty scene there is no dominant mass for an orbit to be computed about,
	# so "spawn into orbit" has no meaning; and starting everything at zero
	# velocity means the only motion that ever appears is motion the integrator
	# produced from the gravity of what you placed. Drop two bodies and they fall
	# together. Drop three and you have a three-body problem you built yourself.
	#
	# The time scale is deliberately slow: a pair released from rest a few AU
	# apart collapses in a couple of years, and at the usual pace that is over
	# before you have let go of the mouse.
	# ==========================================================================
	P.blank = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 1.6 },
		"name": "Blank Canvas",
		"blurb": "An empty scene, and the one place where Spawn puts things down at rest instead of into an orbit. Nothing moves until gravity moves it, so whatever happens next is entirely yours: release two bodies and watch them fall together, or place three and find out what the three-body problem does to your arrangement. Build the objects in the Foundry below — the mass, spin and composition sliders all apply — and paint rings and belts onto them. (Nothing here emits light, so until you spawn a star the scene is lit by a lamp riding the camera. It is a viewing aid and it switches off the moment there is a real star to light things.)",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 26.0, "lensing": false, "mesh": true,
		"timeScale": 0.25, "maxStep": 2e-3,
		"spawnAtRest": true,
		"build": func() -> Array: return [],
	}

	# ==========================================================================
	# REAL STARS
	# --------------------------------------------------------------------------
	# Everything below is built from measured objects — see sim/starcat.gd for
	# the numbers and where they come from. These presets all run at TRUE SCALE,
	# because their whole point is a comparison, and a comparison between
	# exaggerated radii is a comparison between drawing conventions. A star that
	# goes sub-pixel is carried by the point-source marker in sim/scale.gd, which
	# is what a telescope does with it too.
	# ==========================================================================

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

# ============================================================================
# BUILDS — the bodies of the `build()` functions, as static functions so the
# table above stays readable.
# ============================================================================
static func _build_sandbox() -> Array:
	var Mbh := 10.0
	var rs := 0.5   # 0.5 AU "fat" horizon → self-consistent & visible
	var bodies: Array = [{ "type": "bh", "name": "Singularity", "mass": Mbh, "rs": rs, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }]
	bodies.append(orbiter(Mbh, 4.5, { "type": "gas-giant", "name": "Gas Giant", "palette": "jupiter" }, 0.6))
	bodies.append(orbiter(Mbh, 7.0, { "type": "star", "name": "Companion Star", "mass": 1.2 }, 3.4))
	return bodies

static func _build_solar() -> Array:
	var Ms := 1.0
	var sun := { "type": "star", "name": "Sun", "mass": Ms, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
	# a = semi-major axis (AU), m = mass (M☉), radiusKm = mean physical radius
	var P := func(a: float, m: float, radius_km: float, type: String, name: String, extra: Dictionary) -> Dictionary:
		return orbiter(Ms, a, U.merged({ "type": type, "name": name, "mass": m, "radiusKm": radius_km }, extra))
	# The surface model derives what it can (see sim/rocky_visual.gd): a body
	# works out its own temperature from where it is, and its ice line, its
	# desert belts and its biomes follow. What a preset still has to say is
	# what the body is MADE of — its albedo, its greenhouse, and above all
	# the condensation temperature of its dominant volatile, which is the
	# difference between a cap of water ice, one of dry ice and one of
	# nitrogen frost.
	var earth: Dictionary = P.call(1.000, 3.00e-6, 6371.0, "planet", "Earth", {
		"atmosphere": true, "land": 0.32, "biota": 1.0, "albedo": 0.306, "greenhouse": 0.61,
		"obliquity": 0.4091, "cloudCover": 0.44, "season": 11.0,
	})
	return [
		sun,
		P.call(0.387, 1.66e-7,  2439.7, "planet", "Mercury", {
			"hot": true, "crater": 0.95, "regolith": 0x8b8279, "albedo": 0.12, "obliquity": 0.0006 }),
		# Venus is the one body in the system whose surface temperature no
		# greenhouse parameter reaches: 737 K under 92 bar of CO2 is a factor
		# of 2.4 above its equilibrium temperature, so it is stated.
		P.call(0.723, 2.45e-6,  6051.8, "planet", "Venus", {
			"hot": true, "atmosphere": true, "atmColor": 0xffd9a0, "surfaceK": 737.0, "albedo": 0.77,
			"crater": 0.10, "regolith": 0xb08a5c, "cloudCover": 1.0, "cloudColor": 0xfff2d2,
			"atmThick": 2.4, "haze": 1.2, "obliquity": 3.096 }),
		earth,
		# The Moon, on its real orbit about the Earth rather than about the Sun.
		# It is here because a lunar mission needs somewhere to go: without it
		# the spaceflight autopilot's transfer planner has no target inside
		# Earth's sphere of influence, and its landing programs have no airless
		# body to practise on.
		moon_of(earth, 3.844e8, 3.6923e-8, 1737.4, "Moon", {
			"hot": true, "crater": 1.0, "regolith": 0x9a958c, "albedo": 0.12, "obliquity": 0.0268 }),
		# Mars keeps a trace of air, so it has dust storms and a haze — but its
		# caps are CO2, freezing out at 148 K, which is why they grow and
		# retreat by thousands of kilometres every winter.
		P.call(1.524, 3.21e-7,  3389.5, "planet", "Mars", {
			"hot": true, "atmosphere": true, "atmThick": 0.22, "atmColor": 0xd8b48c,
			"cloudCover": 0.10, "cloudColor": 0xe8d8c0, "haze": 0.25, "greenhouse": 0.95,
			"frostK": 148.0, "crater": 0.55, "regolith": 0xa9603a, "albedo": 0.25, "obliquity": 0.4396,
			"transport": 0.16, "season": 62.0 }),
		P.call(5.203, 9.54e-4, 69911.0, "gas-giant", "Jupiter", {
			"palette": "jupiter", "obliquity": 0.0546, "internalHeat": 1.67, "albedo": 0.503 }),
		P.call(9.537, 2.86e-4, 58232.0, "gas-giant", "Saturn", {
			"palette": "saturn", "rings": true, "ringColor": 0xe2d3b0, "ringInner": 1.235, "ringOuter": 2.27,
			"obliquity": 0.4665, "internalHeat": 1.78, "albedo": 0.342 }),
		# Uranus is tipped 97.8 degrees: its rotation axis lies almost IN its
		# orbital plane, so its bands run around what is very nearly the
		# sub-solar point and its poles take turns facing the Sun for 42 years.
		P.call(19.19, 4.37e-5, 25362.0, "gas-giant", "Uranus", {
			"palette": "ice", "obliquity": 1.7064, "internalHeat": 1.03, "albedo": 0.300 }),
		P.call(30.07, 5.15e-5, 24622.0, "gas-giant", "Neptune", {
			"palette": "ice", "obliquity": 0.4943, "internalHeat": 2.61, "albedo": 0.290, "vortices": 2 }),
		# Nitrogen freezes out at about 37 K and Pluto sits at 37 K, which is
		# the whole of why it has a frost cycle at all: the bright plains are
		# condensed N2 and the dark ones are the tholin crust showing through.
		P.call(39.48, 6.55e-9,  1188.3, "planet", "Pluto", {
			"hot": true, "frostK": 37.0, "crater": 0.7, "regolith": 0x9b7255, "albedo": 0.52,
			"obliquity": 2.1386 }),
	]

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

static func _build_trisolaris() -> Array:
	var mA := 1.20
	var mB := 0.85
	var mC := 2.00
	var mp := 3.0e-6
	var aBin := 0.35                        # Alpha–Beta separation
	var aP := 1.80                          # Trisolaris' circumbinary orbit
	var eP := 0.42
	var aC := 22.0
	var eC := 0.35
	var iC := 25.0 * PI / 180.0

	var star := func(name: String, mass: float, extra: Dictionary = {}) -> Dictionary:
		return U.merged({
			"type": "star", "name": name, "mass": mass,
			"luminosity": Stellar.luminosity(mass), "teff": Stellar.effective_temp(mass),
		}, extra)

	# -- inner binary about its own barycentre
	var Mab := mA + mB
	var kb := kepler(Mab, aBin, 0.0, 0.0, 0.0)
	var A: Dictionary = U.merged(star.call("Alpha", mA), { "pos": mulv(kb.pos, -mB / Mab), "vel": mulv(kb.vel, -mB / Mab) })
	var B: Dictionary = U.merged(star.call("Beta", mB), { "pos": mulv(kb.pos, mA / Mab), "vel": mulv(kb.vel, mA / Mab) })

	# -- Trisolaris on a circumbinary orbit about that barycentre,
	#    started at apoapsis: the world begins in a long, cold winter.
	var kp := kepler(Mab, aP, eP, 0.0, PI)
	var P := {
		"type": "world", "name": "Trisolaris", "mass": mp,
		"pos": kp.pos, "vel": kp.vel,
		"dayLength": 1.0 / 90.0,         # ~4 sim-day rotation, slow enough to watch
		"obliquity": 0.41,
		"home": true,
	}

	# -- Gamma about the whole inner system, started near apoapsis so its
	#    approach (and the heat that comes with it) plays out as you watch.
	var Min := Mab + mp
	var Mtot := Min + mC
	var kc := kepler(Mtot, aC, eC, iC, PI * 0.55)
	var C: Dictionary = U.merged(star.call("Gamma", mC), { "pos": mulv(kc.pos, Min / Mtot), "vel": mulv(kc.vel, Min / Mtot) })
	var off := mulv(kc.pos, -mC / Mtot)
	var offv := mulv(kc.vel, -mC / Mtot)
	for b in [A, B, P]:
		b.pos = addv(b.pos, off); b.vel = addv(b.vel, offv)

	return [A, B, C, P]

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
	# Star starts on a true (Paczyński–Wiita) circular orbit at the OUTER edge of
	# the tidal reach, so it orbits stably while accretion drag bleeds its energy
	# and spirals it slowly inward, shedding a gas stream the whole way down.
	var Mbh := 12.0
	var rs := 0.5
	var a := 6.0
	var v := sqrt(Physics.G * Mbh * a) / (a - rs)   # PW circular speed
	return [
		{ "type": "bh", "name": "Singularity", "mass": Mbh, "rs": rs, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] },
		{ "type": "star", "name": "Doomed Star", "mass": 1.8, "color": 0xffe0a0, "glow": 0xff8040, "pos": [a, 0.0, 0.0], "vel": [0.0, 0.0, v] },
	]

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
	# Proxima's real separation is 13 000 AU; placed there it is simply not
	# in the scene. It goes at 900 AU on the same bound, near-circular path
	# so it is reachable, and the blurb says what has been changed.
	var m_pair: float = float(pair[0].mass) + float(pair[1].mass)
	var M: float = m_pair + float(P.mass)
	var a := 900.0
	var v := Physics.circular_speed(M, a)
	# Split the outer orbit about its own barycentre. 0.55 of the circular
	# speed is not "near-circular": with no radial velocity it starts at
	# apoapsis of an e = 0.70 ellipse that falls to 160 AU. And giving
	# Proxima all of the momentum with nothing to balance it sends the whole
	# system drifting across the frame, so each side takes its mass share.
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
