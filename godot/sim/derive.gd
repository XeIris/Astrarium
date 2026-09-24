class_name Derive
extends RefCounted

# ============================================================================
# BODY DERIVATION — what a spec IMPLIES, and the integrator loop that moves it.
# ----------------------------------------------------------------------------
# In the web build all of this lived in the orchestrator (blackhole_sim.js):
# the exaggerated-size table, the reference radii, deriveBody, the energy
# readout and the adaptive step. None of it touches a mesh, a DOM node or the
# camera, and CLAUDE.md says to prefer extending a sim/ module over growing the
# orchestrator, so the port moves the pure half here and leaves main.gd with
# the half that owns the scene. The functions are verbatim ports; where the JS
# read `state.*` the value is a parameter instead.
# ============================================================================

# ============================================================================
# BODY CREATION
# ============================================================================
# The exaggerated ("Boosted") size of each type, at that type's DEFAULT mass.
# A neutron star is ~12 km across sitting in an orbit millions of times wider,
# so its rendered size is pure invention either way; what these numbers buy is
# enough pixels for its lensed surface, polar caps and magnetosphere to be
# visible at all.
const BOOST_RADIUS := {
	"star": 0.34, "white-dwarf": 0.12, "neutron": 0.30,
	"gas-giant": 0.30, "world": 0.13, "planet": 0.15, "bh": 0.2,
}

# Colours are the JS hex ints (sRGB): U.lin() them for a uniform or a light.
const TYPE_DEFAULTS := {
	"star":    { "mass": 1.0, "color": 0xffe0a0, "glow": 0xff8040 },
	"neutron": { "mass": 1.4, "color": 0xcfe8ff, "glow": 0x88c4ff },
	"white-dwarf": { "mass": 0.6, "color": 0xdfe9ff, "glow": 0xaac8ff },
	"gas-giant": { "mass": 9.5e-4, "color": 0xd4a574, "glow": 0x6a4828 },
	"planet":  { "mass": 3e-6, "color": 0x6a90c0, "glow": 0x3a6a9a },
	"world":   { "mass": 3e-6, "color": 0x6a90c0, "glow": 0x3a6a9a },
	"bh":      { "mass": 10.0, "color": 0x000000, "glow": 0x000000 },
}

## TYPE_DEFAULTS[type] || TYPE_DEFAULTS.planet
static func type_default(type) -> Dictionary:
	if type != null and TYPE_DEFAULTS.has(type):
		return TYPE_DEFAULTS[type]
	return TYPE_DEFAULTS.planet

# The physical radius each of those numbers corresponds to, computed once from
# the interior model at the type's default mass. Boosted radius is then scaled
# by how far the BODY's real radius departs from that reference — so the
# exaggeration is a constant magnification per type rather than a constant
# size, and a 300 M⊕ super-Earth is visibly three times a 1 M⊕ one.
#
# Normalising at the default mass is what keeps every existing preset
# pixel-identical: a quick-spawned planet is 1 M⊕, a quick-spawned gas giant is
# 1 M_J, Trisolaris is 1 M⊕, and all of them come out at exactly the ratio 1.
static var _ref_radius := {}
static func reference_radius_au(type) -> float:
	if not _ref_radius.has(type):
		var def := type_default(type)
		var st := Structure.structure_of({ "type": type, "mass": def.mass, "spinFrac": 0.0 })
		var r: float = U.nz(st.get("radiusAU"), 0.0)
		_ref_radius[type] = r if r > 0.0 else 1.0
	return _ref_radius[type]

## `b` may be null (the Foundry sizes a body that does not exist yet).
static func base_radius(b: Body, spec: Dictionary, mass: float) -> float:
	var type = spec.get("type")
	var base: float = BOOST_RADIUS.get(type, 0.2) if type != null else 0.2
	# Stars are the one type whose measured radii span 90 000 to 1 (Betelgeuse to
	# Sirius B). This is the deliberately unphysical readable mode, and drawing
	# that range at all defeats its purpose, so a measured stellar radius is
	# compressed: R^0.45 keeps the ordering and squeezes the range to ~180:1.
	# True scale is the other branch of render_radius and is left entirely alone.
	if type == "star":
		var rs_ = spec.get("radiusSun")
		return base * (pow(float(rs_), 0.45) if rs_ != null else Stellar.radius_sun(mass))
	var ref := reference_radius_au(type)
	var r := b.radius if (b != null and b.radius > 0.0) else ref
	# The clamp is not physics, it is framing: a 0.01 M⊕ pebble still has to be
	# clickable and a brown dwarf still has to fit beside the star it orbits.
	return base * clampf(r / ref, 0.18, 9.0)

# Rendered radius in SCENE units. Black holes are always honest — their
# horizon is the thing you came to look at. Everything else is either the real
# geometric radius (true scale) or the readable, exaggerated stand-in.
# (JS read state.sceneScale / state.bodyScale / state.trueScale.)
static func render_radius(b: Body, spec: Dictionary, mass: float, scene_scale: float, body_scale: float, true_scale: bool) -> float:
	if spec.get("type") == "bh": return b.rs * scene_scale
	if true_scale and b.radius > 0.0: return b.radius * scene_scale
	return base_radius(b, spec, mass) * body_scale

# Destruction distance (attachVisual in the web build). By default a body is
# destroyed when it touches what you can SEE, which keeps the exaggerated view
# self-consistent. But that ties a physical outcome to a drawing convention: at
# the Trisolaris presets' scale an exaggerated star reaches ~9x further out than
# its real photosphere, which quietly decides which close passes a world walks
# away from. A spec may override it with a real distance in AU (see the Roche
# limits in sim/presets.gd).
#
# A MEASURED radius is such an override, and is treated as one. The Moon is
# the case that forced it: it orbits 0.00257 AU from the Earth, and the
# Earth's EXAGGERATED disc is 0.15 AU across — so switching #solar from real
# sizes to readable ones destroyed the Moon on the next frame, silently, with
# nothing but a bump in the "consumed" counter to say so. A body that carries
# a real radius in km has no need to guess a contact distance from how it
# happens to be drawn.
#
# The orchestrator assigns the result to b.contact_au whenever it (re)builds a
# body's visual, exactly where attachVisual did.
static func contact_au(b: Body, spec: Dictionary, radius_scene: float, scene_scale: float) -> float:
	var c = spec.get("contactAU")
	if c != null: return float(c)
	var rk = spec.get("radiusKm")
	if rk != null and float(rk) != 0.0: return b.radius
	return radius_scene / scene_scale

# Peak temperature of the Shakura–Sunyaev disc a hole of this mass would carry.
# The thin-disc result is T_peak ∝ (Ṁ/M²)^¼ and, at a fixed Eddington fraction,
# Ṁ ∝ M, which leaves T ∝ M^(−¼): a stellar-mass hole peaks in the X-ray at
# ~10⁷ K and a supermassive one only in the UV. This is the temperature the
# lens pass images the disc at, and the one a sub-pixel hole's marker has to
# publish so the imaging bands treat it as the X-ray source it is.
static func disc_peak_temp(mass: float) -> float:
	return 2.0e7 * pow(maxf(mass, 0.1), -0.25)

# ---------------------------------------------------------------------------
# Recompute a body's interior model. Everything that reads structure — the
# cross-section, the object editor, the oblateness the star shader draws, the
# stability checks in the render loop — reads b.structure, so this is the one
# place that decides what a body physically IS. It has to be re-run whenever
# mass or spin changes, which accretion does continuously.
# ---------------------------------------------------------------------------
static func refresh_structure(b: Body) -> Dictionary:
	var sp := b.spec
	var q := {
		"type": b.type, "mass": b.mass, "spinFrac": b.spin_frac,
		"phase": b.phase, "composition": b.composition, "Z": b.Z,
		"radiusSun": b.radius_sun, "teff": sp.get("teff"), "luminosity": sp.get("luminosity"),
		"radiusKm": sp.get("radiusKm"),
		# JS passed b.rs, which is undefined on a body that never had one set
		# (stars, planets); Body.rs defaults to 0, so 0 means "undefined" here.
		"rs": b.rs if b.rs != 0.0 else null,
	}
	b.structure = Structure.structure_of(q)
	return b.structure

# ---------------------------------------------------------------------------
# Derive everything a body's spec IMPLIES: horizon, radius, temperature,
# luminosity, spin and interior model. Split out of spawnBody because it has to
# be re-runnable on a body that already exists — the live editor changes a mass
# or a spin on something already in orbit and needs exactly this block again,
# without touching the id, the position, the velocity or the trail.
# ---------------------------------------------------------------------------
static func derive_body(b: Body, spec: Dictionary) -> Body:
	var type = spec.get("type")
	var def := type_default(type)
	var mass := b.mass
	if type == "bh":
		b.rs = float(U.nz(spec.get("rs"), Physics.schwarzschild(mass)))   # effective horizon (AU)
	elif type == "neutron":
		b.radius = Physics.neutron_radius(mass)
		b.rs = Physics.schwarzschild(mass)
	elif type == "star":
		# A measured radius (sim/starcat.gd) wins; otherwise the main-sequence
		# relation. This matters far past cosmetics — b.radius is the collision
		# radius, and Betelgeuse's is 150 times what its mass alone would predict.
		b.radius_sun = spec.get("radiusSun")
		b.radius = float(spec.radiusSun) * Physics.AU_PER_RSUN if spec.get("radiusSun") != null else Physics.stellar_radius(mass)
		b.luminosity = U.nz(spec.get("luminosity"), Stellar.luminosity(mass))
		b.teff = U.nz(spec.get("teff"), Stellar.effective_temp(mass))
		b.spectral = Stellar.spectral_class(b.teff)
		b.phase = U.nz(spec.get("phase"), 0.5)
	elif type == "white-dwarf":
		b.radius_sun = U.nz(spec.get("radiusSun"), Structure.white_dwarf_radius_sun(mass))
		b.radius = float(b.radius_sun) * Physics.AU_PER_RSUN
		b.teff = U.nz(spec.get("teff"), 12000.0)
		# L = 4πR²σT⁴, in solar units with the Sun's own radius and 5772 K divided out
		b.luminosity = U.nz(spec.get("luminosity"), pow(float(b.radius_sun), 2.0) * pow(float(b.teff) / 5772.0, 4.0))
		b.spectral = "D"
		b.rs = Physics.schwarzschild(mass)
	else:
		# Planets and worlds now carry a REAL radius (AU) rather than the old
		# 0.0001 placeholder — true-scale rendering needs it, and it also makes the
		# collision test physical instead of arbitrary. sim/scale.gd falls back to a
		# mass–radius relation when a preset gives no measured radiusKm.
		b.radius = Scale.physical_radius_au(str(type) if type != null else "", mass, spec.get("radiusKm"))
	if type == "world":
		b.day_length = float(U.nz(spec.get("dayLength"), 1.0 / 90.0))
		b.obliquity = float(U.nz(spec.get("obliquity"), 0.35))
		b.home = bool(U.nz(spec.get("home"), false))   # JS !!spec.home

	# How fast it turns, as a fraction of its own break-up rate. This is the
	# dimensionless form of spin, and it is the one that means something: 1.0 is
	# the mass-shedding limit for ANY body, so the same number describes a
	# millisecond pulsar and a gas giant. sim/structure.gd turns it into a shape.
	b.spin_frac = float(U.nz(spec.get("spinFrac"), 0.0))
	b.composition = spec.get("composition")
	b.Z = float(U.nz(spec.get("Z"), 0.014))

	# the spec is kept so the visual can be rebuilt at a different size without
	# disturbing the physics state (see rebuildVisuals)
	b.spec = spec; b.def = def
	refresh_structure(b)

	# The interior model has the last word on what a star currently IS, and the
	# evolutionary phase is the case that proves it. b.teff and b.luminosity were
	# set above from the ZAMS relations, which know about mass and nothing else —
	# so dragging "Life burned" from the main sequence to the red giant branch
	# moved the structure, the layers and the radius, and left the star the same
	# colour and the same brightness it had been. A star that swells 25-fold and
	# does not turn red is the one thing that lesson must not show.
	#
	# A stated value still wins (see _star_structure: measured beats modelled), and
	# at the default mid-main-sequence phase the model returns what the ZAMS
	# relations already gave, so nothing that does not use the phase moves.
	if type == "star" and b.structure.get("type") == "star":
		if spec.get("teff") == null: b.teff = b.structure.teff
		if spec.get("luminosity") == null: b.luminosity = b.structure.luminosity
		if spec.get("radiusSun") == null: b.radius_sun = b.structure.radiusSun
		b.spectral = Stellar.spectral_class(b.teff)

	# A MEASURED radius always wins. Failing that, take the interior model's,
	# which is the same relation the Foundry and the cross-section are showing —
	# and which, unlike the M^0.27 fallback it replaces, actually turns over.
	# Without this a 300 M⊕ planet is drawn 4.7 R⊕ across even at true scale,
	# when the whole point is that no rocky planet can exceed about 3.06.
	var rk = spec.get("radiusKm")
	var has_rk: bool = rk != null and float(rk) != 0.0
	if not has_rk and type != "bh" and float(U.nz(b.structure.get("radiusAU"), 0.0)) > 0.0:
		b.radius = b.structure.radiusAU
	return b

## The non-visual half of spawnBody: id, type, name, masses, state vectors,
## GW flag and spin, then derive_body. The orchestrator then does the visual
## half (attachVisual: render_radius → radius_scene, contact_au, rs_scene, the
## visual and the marker), the home-world id and the trail.
static func new_body(id: int, spec: Dictionary) -> Body:
	var type = spec.get("type")
	var def := type_default(type)
	var mass := float(U.nz(spec.get("mass"), def.mass))
	var b := Body.new()
	b.id = id
	b.type = str(type) if type != null else ""
	var nm = spec.get("name")
	b.name = str(nm) if (nm != null and str(nm) != "") else b.type.to_upper()
	b.mass = mass; b.mass0 = mass
	b.pos = DVec3.from_array(U.nz(spec.get("pos"), [0.0, 0.0, 0.0]))     # AU
	b.vel = DVec3.from_array(U.nz(spec.get("vel"), [0.0, 0.0, 0.0]))     # AU/yr
	b.acc = DVec3.new()
	b.alive = true
	b.emits_gw = bool(U.nz(spec.get("emitsGW"), type == "bh" or type == "neutron"))
	b.spin = spec.get("spin")
	derive_body(b, spec)
	return b

# ============================================================================
# THE INTEGRATOR LOOP
# ============================================================================

# Smallest resolved-needs timescale among bodies — the dynamical time of the
# tightest/ fastest pair. Used to shrink the step during close encounters so a
# fast in-spiral can't slingshot out from integration error.
# (JS read state.maxStep.)
static func dynamic_step(bodies: Array, max_step: float) -> float:
	var t_min := max_step
	var n := bodies.size()
	for i in n:
		var bi: Body = bodies[i]
		if not bi.alive: continue
		for j in range(i + 1, n):
			var bj: Body = bodies[j]
			if not bj.alive: continue
			var sep := bi.pos.distance_to(bj.pos)
			var mu := Physics.G * (bi.mass + bj.mass)
			var t_fall := sqrt((sep * sep * sep) / maxf(mu, 1e-9))   # free-fall time
			var vrel := bi.vel.distance_to(bj.vel)
			var t_fly := sep / maxf(vrel, 1e-6)                      # crossing time
			t_min = minf(t_min, minf(0.05 * t_fall, 0.08 * t_fly))
	return maxf(t_min, 1e-8)

# stepPhysics gives up after 8000 sub-steps and advances the clock by what it
# actually integrated, so hitting the guard does not corrupt the answer — it
# silently slows simulated time instead. Silently is the problem: the step cap
# is a slider, and its low end reaches the guard easily, at which point the sim
# is running slower than the Time controls say and nothing anywhere says why.
const STEP_GUARD := 8000

## The physics half of stepPhysics(simDt). Returns { stepped, steps }:
## `stepped` is the simulated time actually integrated, which is <= sim_dt
## whenever the sub-step guard trips — callers must drive anything on the
## simulated clock (state.simYears, the climate, shader time) from it, not from
## what they passed in; `steps` is state.lastSteps. Each merger event is handed
## to `on_merger` as it happens, inside the sub-step loop, exactly where the
## JS called handleMerger — which removes the absorbed body from `bodies`, so
## the next sub-step already integrates without it. With no callback the
## absorbed body is simply removed. (Committing visual positions, trails and
## the climate step stay in the orchestrator.)
static func step_physics(bodies: Array, sim_dt: float, max_step: float, gw_boost: float, on_merger: Callable = Callable()) -> Dictionary:
	if sim_dt <= 0.0: return { "stepped": 0.0, "steps": 0 }
	var remaining := sim_dt
	var guard := 0
	var stepped := 0.0
	while remaining > 1e-12 and guard < STEP_GUARD:
		guard += 1
		var h := minf(remaining, dynamic_step(bodies, max_step))
		Physics.integrate(bodies, h)
		if gw_boost != 0.0: Physics.apply_gw_reaction(bodies, h, gw_boost)
		var events := Physics.resolve_collisions(bodies)
		for ev in events:
			if on_merger.is_valid(): on_merger.call(ev)
			else: bodies.erase(ev.absorbed)
		remaining -= h
		stepped += h
	return { "stepped": stepped, "steps": guard }

# Total energy of the system, in AU/M☉/yr units. Kinetic plus the Newtonian
# pair potential — the Paczyński–Wiita term and the GW back-reaction are both
# deliberately left out, because a conserved quantity is only useful as a check
# if it is the one the INTEGRATOR is supposed to conserve. With GW boost on, or
# near a hole, the drift shown is therefore real physics leaving the system as
# well as integration error, and the readout says so by not pretending
# otherwise: what it detects is the cap being too long, which dwarfs both.
static func total_energy(bodies: Array) -> float:
	var bs := []
	for b in bodies:
		if b.alive: bs.append(b)
	var E := 0.0
	for i in bs.size():
		var bi: Body = bs[i]
		E += 0.5 * bi.mass * bi.vel.length_sq()
		for j in range(i + 1, bs.size()):
			var bj: Body = bs[j]
			var r := bi.pos.distance_to(bj.pos)
			E -= Physics.G * bi.mass * bj.mass / maxf(r, 1e-9)
	return E
