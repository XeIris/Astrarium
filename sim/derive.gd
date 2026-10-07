class_name Derive
extends RefCounted

const MASS_EDIT_MEASUREMENTS := ["radiusSun", "teff", "luminosity", "radiusKm", "rs"]

# BODY DERIVATION: what a spec implies, and the integrator loop. Pure (no meshes,
# UI or camera); main.gd keeps the half that owns the scene. Values the orchestrator
# holds in `state` are parameters here.

# BODY CREATION
# Exaggerated size per type at that type's default mass. A true neutron star is
# invisible at orbital scale; this buys enough pixels for its surface detail.
const BOOST_RADIUS := {
	"star": 0.34, "white-dwarf": 0.12, "neutron": 0.30,
	"gas-giant": 0.30, "world": 0.13, "planet": 0.15, "bh": 1.0,
}

# Colours are sRGB hex ints: U.lin() them for a uniform or a light.
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

# The physical radius at each type's default mass, from the interior model. The
# exaggerated radius scales by real/reference, a constant magnification per type (a
# 300 M⊕ super-Earth draws visibly bigger than 1 M⊕). Normalising at the default
# keeps existing presets pixel-identical.
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
	# Measured stellar radii span 90 000:1, so in the readable mode they are compressed
	# as R^0.45 (~180:1), keeping the order. True scale is untouched.
	if type == "star":
		var rs_ = spec.get("radiusSun")
		return base * (pow(float(rs_), 0.45) if rs_ != null else Stellar.radius_sun(mass))
	var ref := reference_radius_au(type)
	var r := b.radius if (b != null and b.radius > 0.0) else ref
	# The clamp is not physics, it is framing: a 0.01 M⊕ pebble still has to be
	# clickable and a brown dwarf still has to fit beside the star it orbits.
	return base * clampf(r / ref, 0.18, 9.0)

# Rendered radius in scene units: the real radius (a black hole's horizon) at true
# scale, otherwise the readable stand-in.
static func render_radius(b: Body, spec: Dictionary, mass: float, scene_scale: float, body_scale: float, true_scale: bool) -> float:
	if spec.get("type") == "bh": return hole_render_radius(b.rs, scene_scale, body_scale, true_scale)
	if true_scale and b.radius > 0.0: return b.radius * scene_scale
	return base_radius(b, spec, mass) * body_scale

# Lensing, the disc, mesh wells and framing all size from this. A 10 M☉ horizon is
# ~30 km, so the stand-in compresses r_s like stellar radii and never draws a hole
# smaller than its true horizon. Contact stays at the physical r_s (contact_au).
static func hole_render_radius(rs_au: float, scene_scale: float, body_scale: float, true_scale: bool) -> float:
	var horizon := rs_au * scene_scale
	if true_scale: return horizon
	var ref := Physics.schwarzschild(float(TYPE_DEFAULTS.bh.mass))
	var stand_in: float = BOOST_RADIUS.bh * clampf(pow(rs_au / ref, 0.45), 0.18, 9.0) * body_scale
	return maxf(horizon, stand_in)

# Contact is physical even when the displayed body is magnified. A stated
# contactAU can represent a prescribed destruction distance such as a Roche limit.
static func contact_au(b: Body, spec: Dictionary) -> float:
	if b.type == "bh": return b.rs
	var c = spec.get("contactAU")
	return float(c) if c != null else b.radius

# Peak Shakura–Sunyaev disc temperature: T ∝ (Ṁ/M²)^¼ with Ṁ ∝ M gives T ∝ M^(−¼)
# (~10⁷ K, X-ray, for a stellar-mass hole). The lens pass and a sub-pixel hole's
# marker both use it.
static func disc_peak_temp(mass: float) -> float:
	return 2.0e7 * pow(maxf(mass, 0.1), -0.25)

## Recompute the canonical interior model after physical mass or spin changes.
static func refresh_structure(b: Body) -> Dictionary:
	var sp := b.spec
	if b.type == "bh":
		b.rs = Physics.schwarzschild(b.mass)
		b.radius = 0.0
		sp.mass = b.mass
		sp.erase("rs")
	var q := {
		"type": b.type, "mass": b.mass, "spinFrac": b.spin_frac,
		"phase": b.phase, "composition": b.composition, "Z": b.Z,
		"radiusSun": sp.get("radiusSun"), "teff": sp.get("teff"), "luminosity": sp.get("luminosity"),
		"radiusKm": sp.get("radiusKm"),
		"spinHz": sp.get("spinHz"),
		# Body.rs defaults to 0, which means "unset" (stars, planets).
		"rs": b.rs if b.rs != 0.0 else null,
	}
	b.structure = Structure.structure_of(q)
	b.spin_frac = float(b.structure.get("spinFrac", b.spin_frac))
	if b.type != "bh" and float(b.structure.get("radiusAU", 0.0)) > 0.0:
		b.radius = b.structure.radiusAU
		if b.structure.has("radiusSun"):
			b.radius_sun = b.structure.radiusSun

	if b.structure.get("type") == b.type and b.type in ["star", "white-dwarf"] and b.structure.has("luminosity"):
		b.teff = b.structure.teff
		b.luminosity = b.structure.luminosity
		b.spectral = Stellar.spectral_class(b.teff) if b.type == "star" else "D"
	b.contact_au = contact_au(b, sp)
	return b.structure

# Derive intrinsic properties; construction/edits own the live state vectors.
static func derive_body(b: Body, spec: Dictionary) -> Body:
	var type = spec.get("type")
	var def := type_default(type)
	var mass := b.mass
	var name = spec.get("name")
	b.name = str(name) if name != null and str(name) != "" else b.type.to_upper()
	b.softening = float(U.nz(spec.get("softening"), 0.0))
	b.emits_gw = bool(U.nz(spec.get("emitsGW"), type == "bh" or type == "neutron"))
	if type == "bh":
		b.rs = Physics.schwarzschild(mass)
		b.radius = 0.0
		b.radius_sun = null; b.teff = null; b.luminosity = null; b.spectral = null
	elif type == "neutron":
		b.radius = Physics.neutron_radius(mass)
		b.rs = Physics.schwarzschild(mass)
	elif type == "star":
		# A measured radius wins, else the main-sequence relation. b.radius is also the
		# collision radius (Betelgeuse's is 150× what its mass predicts).
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
		# A real radius in AU (sim/scale.gd falls back to a mass–radius law without radiusKm).
		b.radius = Scale.physical_radius_au(str(type) if type != null else "", mass, spec.get("radiusKm"))
	if type == "world":
		b.day_length = float(U.nz(spec.get("dayLength"), 1.0 / 90.0))
		b.obliquity = float(U.nz(spec.get("obliquity"), 0.35))
		b.home = bool(U.nz(spec.get("home"), false))

	# Spin as a fraction of break-up: 1.0 is mass shedding for any body.
	b.spin_frac = float(U.nz(spec.get("spinFrac"), 0.0))
	b.composition = spec.get("composition")
	b.Z = float(U.nz(spec.get("Z"), 0.014))

	# the spec is kept so the visual can be rebuilt at a different size without
	# disturbing the physics state (see rebuildVisuals)
	b.spec = spec.duplicate(); b.def = def
	refresh_structure(b)
	b.visual_spin_rad_s = spec.get("visualSpinRadS")
	if b.visual_spin_rad_s == null:
		if type == "neutron" and spec.get("spinHz") != null:
			b.visual_spin_rad_s = TAU * maxf(float(spec.spinHz), 0.0)
		else:
			b.visual_spin_rad_s = b.default_visual_spin_rad_s

	return b

## The non-visual half of spawning: id, type, name, masses, state vectors,
## then derive_body. main.gd's attach_visual does the rest.
static func new_body(id: int, spec: Dictionary) -> Body:
	var type = spec.get("type")
	var def := type_default(type)
	var mass := float(U.nz(spec.get("mass"), def.mass))
	var b := Body.new()
	b.id = id
	b.type = str(type) if type != null else ""
	b.mass = mass; b.mass0 = mass
	b.pos = DVec3.from_array(U.nz(spec.get("pos"), [0.0, 0.0, 0.0]))     # AU
	b.vel = DVec3.from_array(U.nz(spec.get("vel"), [0.0, 0.0, 0.0]))     # AU/yr
	b.acc = DVec3.new()
	b.alive = true
	derive_body(b, spec)
	return b

# The smallest dynamical time among bodies, to shrink the step in close encounters.
static func dynamic_step(bodies: Array, max_step: float) -> float:
	var t_min := max_step
	var n := bodies.size()
	for i in n:
		var bi: Body = bodies[i]
		if not bi.alive: continue
		for j in range(i + 1, n):
			var bj: Body = bodies[j]
			if not bj.alive: continue
			var dx := bi.pos.x - bj.pos.x; var dy := bi.pos.y - bj.pos.y; var dz := bi.pos.z - bj.pos.z
			var sq := dx * dx + dy * dy + dz * dz
			# Inline sqrt where Physics.distance_xyz would take its unscaled branch.
			var sep := sqrt(sq) if sq >= DOUBLE_MIN_NORMAL and sq <= DOUBLE_MAX else Physics.distance_xyz(dx, dy, dz)
			var mu := Physics.G * (bi.mass + bj.mass)
			if not (sep <= DOUBLE_MAX and mu > 0.0 and mu <= DOUBLE_MAX): return NAN
			var fall_squared := (sep * sep * sep) / mu
			var t_fall := sqrt(fall_squared)
			if sep > 0.0 and not (fall_squared > 0.0 and fall_squared <= DOUBLE_MAX):
				t_fall = (sqrt(sep) / sqrt(mu)) * sep
			var ux := bi.vel.x - bj.vel.x; var uy := bi.vel.y - bj.vel.y; var uz := bi.vel.z - bj.vel.z
			sq = ux * ux + uy * uy + uz * uz
			var vrel := sqrt(sq) if sq >= DOUBLE_MIN_NORMAL and sq <= DOUBLE_MAX else Physics.distance_xyz(ux, uy, uz)
			if not (vrel <= DOUBLE_MAX): return NAN
			var t_fly := sep / vrel if vrel > 0.0 else INF
			t_min = minf(t_min, minf(0.05 * t_fall, 0.08 * t_fly))
	return t_min

# The sub-step guard: past it the clock advances only what was integrated, so the
# sim runs slow; main.gd reports it.
const STEP_GUARD := 8000

## Returns accepted years, successful sub-steps and `resolution_limited` for unsafe
## time/state arithmetic. Clocks use accepted time, including after the work guard.
## `on_merger` removes absorbed bodies between steps; otherwise this loop removes them.
static func step_physics(bodies: Array, sim_dt: float, max_step: float, gw_boost: float, on_merger: Callable = Callable(), initial_steps: int = 0) -> Dictionary:
	var result := {"stepped": 0.0, "steps": initial_steps, "resolution_limited": false}
	if not is_finite(sim_dt) or not is_finite(max_step) or not is_finite(gw_boost):
		result.resolution_limited = true
		return result
	if sim_dt <= 0.0: return result
	if max_step <= 0.0 or not Physics.finite_state(bodies):
		result.resolution_limited = true
		return result
	var remaining := sim_dt
	var guard := initial_steps
	var stepped := 0.0
	if guard >= STEP_GUARD: return result
	var contacts := Physics.resolve_collisions(bodies)
	var contact_limited := Physics.collision_limited
	for ev in contacts:
		if on_merger.is_valid(): on_merger.call(ev)
		else: bodies.erase(ev.absorbed)
	if contact_limited:
		result.resolution_limited = true
		return result
	while remaining > 0.0 and guard < STEP_GUARD:
		var h := minf(remaining, dynamic_step(bodies, max_step))
		if not is_finite(h) or h <= 0.0 or not is_finite(stepped + h) or stepped + h <= stepped:
			result.resolution_limited = true
			break
		if not Physics.integrate(bodies, h):
			result.resolution_limited = true
			break
		if gw_boost != 0.0: Physics.apply_gw_reaction(bodies, h, gw_boost)
		if not Physics.finite_state(bodies):
			Physics.restore_step(bodies)
			result.resolution_limited = true
			break
		guard += 1
		stepped += h
		remaining = minf(remaining - h, sim_dt - stepped)
		var events := Physics.resolve_collisions(bodies)
		contact_limited = Physics.collision_limited
		for ev in events:
			if on_merger.is_valid(): on_merger.call(ev)
			else: bodies.erase(ev.absorbed)
		if contact_limited:
			result.resolution_limited = true
			break
	result.stepped = stepped
	result.steps = guard
	return result

# Matches conservative forces: Plummer for ordinary pairs, Newtonian for BH pairs.
# GW drag, mergers and changing radii/masses invalidate integrator-only drift.
# Nonzero terms outside double precision return NAN; a singular potential is -INF.
static func total_energy(bodies: Array) -> float:
	var bs := []
	for b in bodies:
		if b.alive: bs.append(b)
	var E := 0.0
	for i in bs.size():
		var bi: Body = bs[i]
		if not is_finite(bi.mass) or bi.mass <= 0.0 or not bi.pos.is_finite_v() or not bi.vel.is_finite_v(): return NAN
		var speed_sq := bi.vel.length_sq()
		var half_mass := 0.5 * bi.mass
		var kinetic := half_mass * speed_sq
		var speed_scale := maxf(absf(bi.vel.x), maxf(absf(bi.vel.y), absf(bi.vel.z)))
		if speed_scale > 0.0 and (not is_finite(kinetic) or kinetic == 0.0 or speed_sq < DOUBLE_MIN_NORMAL or half_mass < DOUBLE_MIN_NORMAL):
			var vx := bi.vel.x / speed_scale; var vy := bi.vel.y / speed_scale; var vz := bi.vel.z / speed_scale
			kinetic = _energy_product([0.5, bi.mass, speed_scale, speed_scale, vx * vx + vy * vy + vz * vz], [])
		E += kinetic
		for j in range(i + 1, bs.size()):
			var bj: Body = bs[j]
			var r := Physics.distance_xyz(bi.pos.x - bj.pos.x, bi.pos.y - bj.pos.y, bi.pos.z - bj.pos.z)
			var denom := r if bi.type == "bh" or bj.type == "bh" else sqrt(r * r + Physics.pair_softening_sq(bi, bj))
			if bi.type != "bh" and bj.type != "bh" and (not is_finite(denom) or denom * denom < DOUBLE_MIN_NORMAL):
				denom = Physics.softened_distance(r, bi, bj)
			if denom == 0.0: return -INF
			if not is_finite(denom): return NAN
			var weighted_mass := Physics.G * bi.mass
			var numerator := weighted_mass * bj.mass
			var potential := numerator / denom
			if not is_finite(potential) or potential == 0.0 or numerator < DOUBLE_MIN_NORMAL or weighted_mass < DOUBLE_MIN_NORMAL:
				potential = _energy_product([Physics.G, bi.mass, bj.mass], [denom])
			E -= potential
	return E

static var DOUBLE_MIN_NORMAL := Physics.DOUBLE_MIN_NORMAL
static var DOUBLE_MAX := Physics.DOUBLE_MAX

# A diagnostic product outside binary64 is unavailable, not zero or infinite.
static func _energy_product(factors: Array, divisors: Array) -> float:
	var value := Physics.scaled_product(factors, divisors)
	return value if is_finite(value) and value > 0.0 else NAN
