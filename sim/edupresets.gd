class_name EduPresets
extends RefCounted

# TEACHING SCENARIOS: ordinary presets (same units and contract, merged into
# PRESETS by sim/presets.gd), each the minimum arrangement that shows one idea.
# Every number is real; anything adjusted for watchability is said in the blurb
# and here. The clock is always adjusted (a pace that shows the year strobes the
# day), and each scenario picks the pace its lesson needs.

const DEG := PI / 180.0

# circular orbit about a dominant central mass at the origin, at a stated phase
static func orbiter(Mc: float, a: float, spec: Dictionary, angle: float = 0.0, incl: float = 0.0) -> Dictionary:
	var v := Physics.circular_speed(Mc, a)
	return U.merged(spec, {
		"pos": [cos(angle) * a, sin(angle) * sin(incl) * a, sin(angle) * cos(incl) * a],
		"vel": [-sin(angle) * v, cos(angle) * sin(incl) * v, cos(angle) * cos(incl) * v],
	})

# A satellite placed relative to its parent's ACTUAL state — see the note on
# moon_of() in sim/presets.gd for why the parent's semi-major axis is not enough.
static func moon_of(parent: Dictionary, dist_m: float, mass_sun: float, radius_km: float, name: String, extra: Dictionary = {}) -> Dictionary:
	var a := dist_m / 1.495978707e11
	var px: float = parent.pos[0]; var py: float = parent.pos[1]; var pz: float = parent.pos[2]
	var vx: float = parent.vel[0]; var vy: float = parent.vel[1]; var vz: float = parent.vel[2]
	# Math.hypot, in double precision (Vector2 is float32)
	var r := sqrt(px * px + pz * pz)
	if r == 0.0: r = 1.0
	var ux := px / r
	var uz := pz / r
	var v := Physics.circular_speed(float(parent.mass) + mass_sun, a)
	var o := U.merged({ "type": "planet", "name": name, "mass": mass_sun, "radiusKm": radius_km, "hot": true }, extra)
	o.pos = [px + ux * a, py, pz + uz * a]
	o.vel = [vx - uz * v, vy, vz + ux * v]
	return o

# An eccentric orbit started at apoapsis, where it is slowest:
# v = √(GM (1−e)/(a(1+e))).
static func eccentric(Mc: float, a: float, e: float, spec: Dictionary, angle: float = 0.0) -> Dictionary:
	var r := a * (1.0 + e)
	var v := sqrt(Physics.G * Mc * (1.0 - e) / (a * (1.0 + e)))
	return U.merged(spec, {
		"pos": [cos(angle) * r, 0.0, sin(angle) * r],
		"vel": [-sin(angle) * v, 0.0, cos(angle) * v],
	})

# Earth as the climate's home world: 23.44° obliquity, 0.306 Bond albedo, 29% land,
# and a 0.61 greenhouse factor taking 255 K equilibrium to the real 288 K.
const EARTH := {
	"type": "world", "name": "Earth", "mass": 3.0035e-6, "radiusKm": 6371.0,
	"atmosphere": true, "land": 0.29, "biota": 1.0, "albedo": 0.306, "greenhouse": 0.61,
	"obliquity": 23.44 * DEG, "cloudCover": 0.44, "season": 11.0, "home": true,
}

const MOON := { "hot": true, "crater": 1.0, "regolith": 0x9a958c, "albedo": 0.12, "obliquity": 0.0268 }

static var EDU_PRESETS: Dictionary = _make()

const EDU_ORDER := [
	"edu_seasons", "edu_moon", "edu_kepler", "edu_habitable",
	"edu_starbirth", "edu_sun", "edu_lifecycle", "edu_supernova", "edu_pulsar",
	"edu_transit", "edu_hole", "edu_galaxy", "edu_cluster",
]

static func _make() -> Dictionary:
	var P := {}

	# WHY THERE ARE SEASONS: an axis fixed in space on Earth's real orbit (e = 0.0167).
	# Perihelion is on 3 January, and the 6.8% swing in insolation has the wrong sign
	# to explain summer; the 23.44° tilt does the work.
	P.edu_seasons = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 2.1 },
		"name": "Why there are seasons",
		"blurb": "One star, one planet, and the real 23.44° tilt. Earth's orbit is its real one — eccentricity 0.0167, with perihelion in January — so the planet is CLOSEST to the Sun during northern winter. Watch the terminator: the axis keeps pointing at the same place in the sky all year, so first one pole leans into the light and then the other. The ONE thing changed from reality is the length of the day: this world turns 20 times a year rather than 365, because no single pace makes both the day and the year watchable and the course needs both.",
		"sceneScale": 34.0, "bodyScale": 0.5, "camRadius": 12.0, "lensing": false, "mesh": false,
		"timeScale": 0.06, "maxStep": 1e-3,
		"surface": true, "focus": "Earth",
		"climate": { "mixedLayer": 60.0, "T0": 288.0 },
		"build": func() -> Array:
			var Ms := 1.0
			var sun := { "type": "star", "name": "Sun", "mass": Ms, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
			# Started at aphelion (early July), so the planet first falls sunward through
			# northern autumn. 20 days to the year so neither the orbit nor the day strobes;
			# the lessons set their own pace on top (0.003 yr/s for day/night, 0.06 for seasons).
			var earth := eccentric(Ms, 1.00000011, 0.0167, U.merged(EARTH, { "dayLength": 1.0 / 20.0 }))
			return [sun, earth],
	}

	# PHASES AND ECLIPSES: half the Moon is always lit; a phase is how much of that
	# half faces us. The real 5.14° inclination is why eclipses are rare. (Mutual
	# eclipse shadows are not rendered.)
	P.edu_moon = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 2.1 },
		"name": "Phases, and why eclipses are rare",
		"blurb": "The Earth–Moon system at its real separation — 384 400 km, thirty Earth diameters, which is already further apart than almost every diagram draws it. The Sun lights exactly half the Moon at every instant; the phase is how much of that half you can see from here. The geometry shows eclipse alignments; mutual eclipse shadows are not rendered. Earth’s rotation is slowed to 80 turns per year. The orbit carries its real 5.14° tilt to the ecliptic, which is the entire reason there is not an eclipse every month: at most new moons the shadow misses by several Earth diameters.",
		"sceneScale": 900.0, "bodyScale": 0.25, "camRadius": 6.5, "lensing": false, "mesh": false,
		# A lunar month in about twelve seconds. The Moon's orbit is the clock this
		# scenario is about, so it is the one the pace is chosen for.
		"trueScale": true, "timeScale": 0.006, "maxStep": 2e-4,
		"surface": true, "focus": "Earth",
		"climate": { "mixedLayer": 60.0, "T0": 288.0 },
		"build": func() -> Array: return _build_moon(),
	}

	# KEPLER'S LAWS, AS AN EXPERIMENT
	#   Circle and Ellipse: both a = 1.5 AU, one circular, one e = 0.72 (0.42–2.58 AU).
	#   Same period (third law); started together at apoapsis, they return together.
	#   Far: a = 1.5 × 4^(1/3) = 2.3811 AU, so a³ is 4× and the period exactly 2×.
	# On the ellipse, periapsis speed is (1+e)/(1−e) = 6.1× apoapsis (second law).
	P.edu_kepler = {
		"sky": { "env": "disc", "tilt": 0.30, "roll": 1.1 },
		"name": "Kepler's laws",
		"blurb": "Three planets round one star. Circle and Ellipse have the SAME semi-major axis — 1.5 AU — and wildly different shapes, and they keep arriving back together, because the period depends on the semi-major axis and on nothing else. Far sits at 2.381 AU, where a³ is exactly four times theirs, so it takes exactly two of their years to go round once: count the laps. On the ellipse the planet moves 6.1 times faster at its closest point than at its furthest, which is the second law — the trail bunches up where it is slow.",
		"sceneScale": 22.0, "bodyScale": 0.35, "camRadius": 62.0, "lensing": false, "mesh": false,
		"timeScale": 0.6, "maxStep": 1e-3,
		"build": func() -> Array:
			var Ms := 1.0
			var a := 1.5
			var sun := { "type": "star", "name": "Sun", "mass": Ms, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
			var rock := func(name: String, color: int) -> Dictionary:
				return {
					"type": "planet", "name": name, "mass": 3.0e-6, "radiusKm": 6371.0, "hot": true,
					"crater": 0.4, "regolith": color, "albedo": 0.22, "obliquity": 0.2,
				}
			return [
				sun,
				orbiter(Ms, a, rock.call("Circle", 0x8fa3b8), 0.0),
				eccentric(Ms, a, 0.72, rock.call("Ellipse", 0xb8896a), 0.0),
				# a³ = 4 × 1.5³ → a = 1.5 × 4^(1/3) = 2.3811 AU, period exactly 2×.
				orbiter(Ms, a * U.cbrt(4.0), rock.call("Far", 0x7f8f7a), PI),
			],
	}

	# WHERE STARS COME FROM. A core collapses once heavier than its Jeans mass,
	# M_J ≈ 2 M☉ (T/10 K)^1.5 (n/10⁴ cm⁻³)^-0.5, and its angular momentum leaves a disc.
	# The protostar is still contracting (PHASES in sim/structure.gd). The collapse
	# itself isn't simulated: the disc is analytic test particles (sim/painter.gd),
	# showing the arrangement a collapse leaves.
	P.edu_starbirth = {
		# The cloud is the sky (H II, reflection nebulosity and dust turned up), not the
		# painter's shell nebula, which reads as a soap bubble for infalling gas.
		"sky": { "env": { "starburst": 1.0, "disc": 0.35 }, "tilt": 0.44, "roll": 0.8,
			"hii": 5.4, "reflection": 3.4, "dust": 2.3, "starDensity": 2.0 },
		"name": "The birth of a star",
		"blurb": "A protostar in a star-forming region, with the disc it cannot avoid having. What collapsed was rotating, and rotation cannot be thrown away, so the infalling gas lands on a disc instead of on the star — which is where the planets come from, and why every planet in our solar system goes round the same way. The star at the centre is not fusing anything yet: it shines on the heat of its own collapse, and it is larger and redder now than it will ever be again. The nebulosity is the sky, not an object: the H II and reflection components of sim/sky.js turned up, because that is genuinely where young stars are. The cloud core immediately around it is NOT drawn — the painter models optically thin shells, which is right for a thrown-off envelope and wrong for an infalling one.",
		"sceneScale": 0.9, "bodyScale": 0.8, "camRadius": 32.0, "lensing": false, "mesh": false,
		"timeScale": 2.0, "maxStep": 2e-3,
		"paint": [
			# Σ ∝ r^-1, the minimum-mass solar nebula's profile, from the dust
			# sublimation radius out to where the cloud is still falling in.
			{ "kind": "belt", "body": "Protostar", "inner": 0.35, "outer": 26.0, "color": 0xc8956a, "surfaceDensity": -1.0 },
		],
		"build": func() -> Array:
			var pr := Structure.phase_by_id("protostar")
			var M := 1.0
			var star := {
				"type": "star", "name": "Protostar", "mass": M, "phase": pr.f,
				# The Hayashi track: nearly fixed at ~4000 K while the radius shrinks.
				"teff": 4100.0, "radiusSun": Structure.base_radius_sun(M) * float(pr.rMul), "luminosity": 1.6,
				"color": 0xffb070, "glow": 0xff6a28, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0],
			}
			return [
				star,
				# Two bodies that have already swept their own lanes clear — the first
				# planets, at the distances where the disc is dense enough to build one.
				orbiter(M, 5.2, { "type": "gas-giant", "name": "Protoplanet", "mass": 3.0e-4, "palette": "jupiter", "internalHeat": 4.0 }, 0.7),
				orbiter(M, 12.0, { "type": "planet", "name": "Planetesimal", "mass": 2.0e-6, "radiusKm": 4000.0, "hot": true, "crater": 0.9, "regolith": 0x8a7a6a }, 3.6),
			],
	}

	# THE SUN, CLOSE UP: no orbit, on a clock slow enough that a flare lasts more
	# than a frame.
	P.edu_sun = {
		"sky": { "env": "disc", "tilt": 0.38, "roll": 2.1 },
		"name": "The Sun, close up",
		"blurb": "One ordinary G2 star at 5772 K, filling the frame, on a clock slowed to about a day per second — because a solar flare lasts hours and erupts once every few years, and at orbital pace the entire event happens between two frames. Everything on the surface is derived: the granulation is convection cells at the size the pressure scale height gives, the spots are where the field is strong enough to choke that convection, and the loops above them are gas that cannot cross a magnetic field line and so slides along it.",
		"sceneScale": 210.0, "bodyScale": 1.0, "camRadius": 6.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.0028, "maxStep": 5e-4,
		"build": func() -> Array: return [Starcat.star_spec("sun", { "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] })],
	}

	# ONE STAR, WHOLE LIFE: nothing else in the scene, so the phase slider has the
	# frame. Each stop is a real point on the track, recomputed by structure_of(); the
	# star swells 130× by the AGB.
	P.edu_lifecycle = {
		"sky": { "env": "disc", "tilt": 0.40, "roll": 0.3 },
		"name": "One star, whole life",
		"blurb": "A single solar-mass star, with the cross-section panel open and its phase slider free. Every stop on it is a real point on the evolutionary track — the radius, the temperature, the colour and the interior layers are all recomputed from the model, not cross-faded between pictures. Drag it right and watch the star leave the main sequence, swell 25-fold into a red giant, and then 130-fold again; the inner planet is at Mercury's distance to show what that means for anything in the way.",
		# 0.9 to 130 R☉ is 144:1, so the camera reframes as the star grows (edit_body glides).
		"sceneScale": 26.0, "bodyScale": 1.0, "camRadius": 1.1, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.4, "maxStep": 1e-3,
		"focus": "Sol",
		"build": func() -> Array:
			var M := 1.0
			return [
				# Deliberately unmeasured: a stated radius/teff/luminosity would hold the star
				# fixed against the phase.
				{ "type": "star", "name": "Sol", "mass": M, "phase": Structure.phase_by_id("zams").f,
					"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] },
				orbiter(M, 0.387, { "type": "planet", "name": "Inner world", "mass": 1.66e-7, "radiusKm": 2439.7,
					"hot": true, "crater": 0.95, "regolith": 0x8b8279, "albedo": 0.12 }, 0.5),
				orbiter(M, 1.0, { "type": "planet", "name": "Earth-like", "mass": 3.0035e-6, "radiusKm": 6371.0,
					"atmosphere": true, "land": 0.29, "albedo": 0.306, "greenhouse": 0.61, "obliquity": 23.44 * DEG,
					"cloudCover": 0.44, "hot": true }, 3.4),
			],
	}

	# A STAR ABOUT TO EXPLODE: 20 M☉ at the pre-collapse stop, an Earth-sized iron
	# core under onion shells. end_state_of() decides the remnant (a black hole at
	# 20 M☉, a neutron star below). The lesson triggers the collapse; nothing is scripted.
	P.edu_supernova = {
		"sky": { "env": ["starburst", "disc"], "tilt": 0.5, "roll": 1.4 },
		"name": "A star about to explode",
		"blurb": "Twenty solar masses at the last stop before the end. Silicon burning in the core takes about a day and builds an iron core — and iron is where nuclear binding energy peaks, so burning it costs energy instead of releasing it. When that core passes its own Chandrasekhar mass it falls in inside a quarter of a second, and what is left over depends only on how heavy it was. The scenario knows which; it is not told.",
		"sceneScale": 1.6, "bodyScale": 1.0, "camRadius": 44.0, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 0.25, "maxStep": 2e-3,
		"focus": "Doomed",
		"build": func() -> Array:
			var M := 20.0
			var p := Structure.phase_by_id("preSN")
			return [{
				"type": "star", "name": "Doomed", "mass": M, "phase": p.f,
				"radiusSun": Structure.base_radius_sun(M) * float(p.rMul), "luminosity": Stellar.luminosity(M) * 0.06,
				"teff": 3600.0, "color": 0xff8a50, "glow": 0xff5a20, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0],
			}],
	}

	# A LIGHTHOUSE MADE OF NEUTRONS: 1.4 M☉ in 12 km, surface gravity 2×10¹¹ g, and
	# light bent enough to show over half the sphere (ray-traced in neutron_visual.gd).
	# The beams leave the magnetic poles, off the rotation axis, so they sweep.
	P.edu_pulsar = {
		"sky": { "env": ["disc", "halo"], "tilt": 0.58, "roll": 2.2 },
		"name": "A pulsar",
		"blurb": "One and a half solar masses inside a sphere 24 km across, turning 30 times a second. Rotation is slowed in this view so you can follow the sweep. Its gravity bends the light leaving its own surface far enough that you see well past the limb — more than half the star at once. The beams come out of the magnetic poles, which are not the rotation poles, so they sweep: a pulsar does not blink, it rotates, and we only call it a pulsar because the beam happens to cross us. Switch to the RADIO band to see what a radio telescope sees.",
		# 12.5 km at true scale, so sceneScale makes the star about one unit wide
		# (8.35e-8 AU × 1.2e7).
		"sceneScale": 1.2e7, "bodyScale": 1.0, "camRadius": 6.5, "lensing": false, "mesh": false,
		"trueScale": true, "timeScale": 2.0e-7, "maxStep": 1e-8,
		"focus": "Pulsar",
		"build": func() -> Array:
			return [{ "type": "neutron", "name": "Pulsar", "mass": 1.4, "spinHz": 30.0, "visualSpinRadS": 30.0,
				"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }],
	}

	# HOW WE FIND PLANETS: two near edge-on planets, sized so both methods work.
	#   Giant  1.2 M_J, 1.3 R_J, a = 0.05 AU, P = 4.08 d: area ratio 1.70%,
	#          K = 28.43 (M_p/M_J)(a/AU)^-½ = 152 m/s
	#   Rock   1 R⊕ at a = 0.28 AU: 84 ppm, and a 17 cm/s wobble
	# The measured dip (~2.1%) is deeper than the area ratio because of limb darkening
	# (linear u = 0.6: centre 1/(1−u/3) = 1.25× the mean), which sim/lightcurve.gd
	# integrates. The observer is the camera, so transits need you in the orbital plane
	# (about 0.5% chance for 1 AU round a Sun).
	P.edu_transit = {
		"sky": { "env": "disc", "tilt": 0.34, "roll": 1.9 },
		"name": "Finding planets: transits and wobbles",
		"blurb": "A Sun-like star with two planets on almost edge-on orbits. The hot Jupiter covers 1.7% of the star every 4.08 days and hauls it around at 152 m/s; the Earth-sized planet further out covers 84 parts per million and moves the star at 17 cm/s. Both are real numbers for those planets. The measured dip is a little deeper than the area ratio, because a stellar disc is brighter in the middle than at the edge. The observer is the camera — so climb out of the orbital plane and the transits stop, which is exactly why we have only found the planets whose orbits happen to point at us.",
		"sceneScale": 300.0, "bodyScale": 0.5, "camRadius": 26.0, "lensing": false, "mesh": false,
		# 0.005 yr/s: the 4.08-day orbit takes ~2.2 s, so a few dips fit the window.
		"timeScale": 0.005, "maxStep": 2e-5,
		"focus": "Kepler-ish",
		"build": func() -> Array: return _build_transit(),
	}

	# THE HABITABLE ZONE: three identical planets at 0.55, 1.00 and 1.90 AU. Nothing is
	# set; each derives its insolation (insolation_at) and its ice and biomes follow.
	#     S = L / r²,  T_eq = 278.6 K · (L/r²)^¼ · (1−A)^¼
	#   0.55 AU  3.31 S⊕  344 K  runaway
	#   1.00 AU  1.00 S⊕  255 K  288 K with the greenhouse
	#   1.90 AU  0.28 S⊕  185 K  frozen
	P.edu_habitable = {
		"sky": { "env": "disc", "tilt": 0.36, "roll": 0.7 },
		"name": "The habitable zone",
		"blurb": "Three identical planets at 0.55, 1.0 and 1.9 AU from the same star. Identical: same mass, same radius, same albedo, same atmosphere. Nothing about how they look is set anywhere — each one computes the sunlight falling on it from where it actually is, turns that into a surface temperature, and its ice caps, its deserts and its vegetation follow. One of them is a furnace, one is frozen, and the one in between is not special in any way except its distance.",
		# Exaggerated: at true scale three Earths over 1.35 AU are three points.
		"sceneScale": 8.0, "bodyScale": 3.0, "camRadius": 22.0, "lensing": false, "mesh": false,
		"timeScale": 0.25, "maxStep": 1e-3,
		"build": func() -> Array:
			var M := 1.0
			var sun := { "type": "star", "name": "Sun", "mass": M, "radiusSun": 1.0, "teff": 5772.0, "luminosity": 1.0,
				"color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
			var world := func(name: String, a: float, angle: float) -> Dictionary:
				return orbiter(M, a, {
					"type": "planet", "name": name, "mass": 3.0035e-6, "radiusKm": 6371.0,
					"atmosphere": true, "land": 0.29, "biota": 1.0, "albedo": 0.306, "greenhouse": 0.61,
					"obliquity": 23.44 * DEG, "cloudCover": 0.44, "season": 11.0,
				}, angle)
			return [sun, world.call("Scorched", 0.55, 0.4), world.call("Temperate", 1.00, 2.6), world.call("Frozen", 1.90, 4.6)],
	}

	# A BLACK HOLE WITH NOTHING AROUND IT: the shadow (2.6 r_s, since light inside the
	# 1.5 r_s photon sphere is captured), the photon ring, and the Einstein ring of what
	# is behind. Works because the star field is analytic (docs/physics/sky.md).
	P.edu_hole = {
		"sky": { "env": ["halo", "disc"], "tilt": 0.26, "roll": 2.7 },
		"name": "A black hole, alone",
		"discIntensity": 0.0,
		"blurb": "Eight solar masses and nothing else in the frame. There is nothing to see here in the ordinary sense — a black hole emits nothing — so everything you can see is the sky BEHIND it being bent. The dark disc is the shadow, and it is 5.2 Schwarzschild radii across rather than 2, because any light that comes closer than the photon sphere at 1.5 r_s spirals in. The bright circle round it is the photon ring: light that went most of the way round and came back out. Turn the accretion disc up and the same geometry shows you the far side of the disc over the top of the hole.",
		# Frame the isolated physical horizon at 1.2 scene units.
		"sceneScale": 1.2 / Physics.schwarzschild(8.0), "bodyScale": 1.0, "camRadius": 26.0, "lensing": true, "mesh": false,
		"timeScale": 0.4,
		"build": func() -> Array:
			return [{ "type": "bh", "name": "Hole", "mass": 8.0, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }],
	}

	# THE SKY FROM INSIDE THE GALAXY: an empty scene. We're two thirds out in a disc, so
	# the Milky Way is a band round the sky; every sky component is band-aware for the
	# multiwavelength lesson.
	P.edu_galaxy = {
		"sky": { "env": "disc", "tilt": 0.0, "roll": 0.9 },
		"name": "The Milky Way, from inside it",
		"blurb": "An empty scene: everything here is the sky itself. The Milky Way is a disc about 100 000 light years across and 1000 thick, and we are inside it — so it is not an object we look at, it is a band that goes all the way round us, and its narrowness is the disc seen edge-on. The dark lanes splitting it are not gaps, they are dust in the way. Change the imaging band and that same dust becomes the brightest thing in the sky.",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 12.0, "lensing": false, "mesh": false,
		"timeScale": 0.1,
		"build": func() -> Array: return [],
	}

	P.edu_cluster = {
		"sky": { "env": ["globular", "halo"], "tilt": 0.4, "roll": 1.7 },
		"name": "Inside a globular cluster",
		"blurb": "A million stars inside thirty light years, bound to each other and orbiting the galaxy as one object for twelve billion years. From in here the naked-eye sky holds tens of thousands of stars instead of three thousand, and the galaxy the cluster orbits is a distant object rather than a band overhead — because you are outside the disc looking back at it. Globulars are the oldest things in the galaxy, which is why almost every star in one is either a red dwarf or a red giant: everything heavier has already died.",
		"sceneScale": 2.0, "bodyScale": 1.0, "camRadius": 12.0, "lensing": false, "mesh": false,
		"timeScale": 0.1,
		"build": func() -> Array: return [],
	}
	return P

static func _build_moon() -> Array:
	var Ms := 1.0
	var sun := { "type": "star", "name": "Sun", "mass": Ms, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
	var earth := orbiter(Ms, 1.0, U.merged(EARTH, { "dayLength": 1.0 / 80.0 }), 0.0)
	var moon := moon_of(earth, 3.844e8, 3.6923e-8, 1737.4, "Moon", U.merged(MOON, { "tidalLock": "Earth" }))
	# The 5.14° tilt, applied to the moon's state RELATIVE to the Earth so
	# the inclination is of the lunar orbit and not of the Earth's.
	var i := 5.145 * DEG
	var c := cos(i)
	var s := sin(i)
	var rot := func(v: Array, o: Array) -> Array:
		var dx: float = v[0] - o[0]
		var dy: float = v[1] - o[1]
		var dz: float = v[2] - o[2]
		# rotate about the x axis (the line of nodes, put along x by construction)
		return [o[0] + dx, o[1] + dy * c - dz * s, o[2] + dy * s + dz * c]
	moon.pos = rot.call(moon.pos, earth.pos)
	moon.vel = rot.call(moon.vel, earth.vel)
	return [sun, earth, moon]

static func _build_transit() -> Array:
	var M := 1.0
	var star := { "type": "star", "name": "Kepler-ish", "mass": M, "radiusSun": 1.0, "teff": 5772.0,
		"luminosity": 1.0, "color": 0xfff2cc, "glow": 0xffaa33, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0] }
	# 1.2 Jupiter masses in solar units, and an inflated 1.3 R_J — hot
	# Jupiters really are puffed up by the irradiation they sit under.
	var giant := orbiter(M, 0.05, {
		"type": "gas-giant", "name": "Giant b", "mass": 1.2 * 9.5459e-4, "radiusKm": 1.3 * 69911.0,
		"palette": "jupiter", "internalHeat": 3.0,
	}, 0.0, 1.2 * DEG)
	var rock := orbiter(M, 0.28, {
		"type": "planet", "name": "Rock c", "mass": 3.0035e-6, "radiusKm": 6371.0, "hot": true,
		"crater": 0.3, "regolith": 0xa08878, "albedo": 0.25,
	}, 2.4, 0.4 * DEG)
	# Give the star the balancing momentum, so the radial-velocity wobble is the
	# integrator's own.
	var gm: float = giant.mass
	var rm: float = rock.mass
	var px: float = gm * giant.vel[0] + rm * rock.vel[0]
	var py: float = gm * giant.vel[1] + rm * rock.vel[1]
	var pz: float = gm * giant.vel[2] + rm * rock.vel[2]
	star.vel = [-px / M, -py / M, -pz / M]
	return [star, giant, rock]
