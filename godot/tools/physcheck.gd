extends SceneTree

# ============================================================================
# PHYSICS-CORE CHECK — the GDScript half of the numeric comparison.
# ----------------------------------------------------------------------------
#   node godot/tools/physref.mjs ref /abs/ref.json
#   Godot --headless --path godot --script res://tools/physcheck.gd -- \
#         mode=ref in=/abs/ref.json out=/abs/gd.json
#   node godot/tools/physdiff.mjs /abs/ref.json /abs/gd.json
#
#   Godot --headless --path godot --script res://tools/physcheck.gd -- \
#         mode=long preset=trisolaris years=2000 [fps=60]
#
# `ref` recomputes, in GDScript, every case physref.mjs ran through the web
# build (structure_of over ~1000 specs, every helper over its grid, the star
# catalogue and builders, every preset's build and derive_body at both size
# conventions, the climate model, and 240 frames of eleven presets through the
# exact stepPhysics loop). `long` is the integration regression: a preset at its
# own pace, frame by frame, reporting energy drift and sub-steps per second.
# ============================================================================

var pm_seed := 1
func _pm() -> float:
	pm_seed = (pm_seed * 16807) % 2147483647
	return float(pm_seed) / 2147483647.0

# ---- a minimal orchestrator state (the physics half of loadPreset) ---------
var bodies: Array = []
var scene_scale := 1.0
var body_scale := 1.0
var true_scale := false
var max_step := 5e-3
var gw_boost := 0.0
var time_scale := 2.0
var sim_years := 0.0
var home_id = null
var next_id := 1
var consumed := 0
var climate: Climate = null
var last_steps := 0

func get_stars() -> Array:
	var out := []
	for b in bodies:
		if (b.type == "star" or b.type == "white-dwarf") and b.alive: out.append(b)
	return out

func get_home():
	if home_id == null: return null
	for b in bodies:
		if b.id == home_id: return b
	return null

func load_preset(key: String, seed_value: int = 12345) -> Dictionary:
	var p: Dictionary = Presets.PRESETS[key]
	pm_seed = seed_value
	Presets.rand_override = _pm
	scene_scale = p.sceneScale; body_scale = U.nz(p.get("bodyScale"), 1.0); true_scale = bool(p.get("trueScale", false))
	max_step = U.nz(p.get("maxStep"), 5e-3); gw_boost = U.nz(p.get("gwBoost"), 0.0); time_scale = U.nz(p.get("timeScale"), 2.0)
	bodies = []; sim_years = 0.0; home_id = null; next_id = 1; consumed = 0
	var specs: Array = p.build.call()
	for spec in specs:
		var b := Derive.new_body(next_id, spec)
		next_id += 1
		b.radius_scene = Derive.render_radius(b, spec, b.mass0, scene_scale, body_scale, true_scale)
		b.contact_au = Derive.contact_au(b, spec, b.radius_scene, scene_scale)
		if spec.get("type") == "world" and spec.get("home", false): home_id = b.id
		bodies.append(b)
	climate = Climate.new(p.climate) if p.has("climate") else null
	if climate != null:
		var home = get_home()
		if home != null: climate.step(1e-6, home, get_stars())
	return { "p": p, "specs": specs }

func _on_merger(ev: Dictionary) -> void:
	bodies.erase(ev.absorbed)
	consumed += 1

## stepPhysics: the physics loop, then the clock and the climate on what was
## actually integrated.
func step_physics(sim_dt: float) -> float:
	var r := Derive.step_physics(bodies, sim_dt, max_step, gw_boost, _on_merger)
	last_steps = r.steps
	sim_years += r.stepped
	var home = get_home()
	if climate != null and home != null: climate.step(r.stepped, home, get_stars())
	return r.stepped

func body_out(b: Body) -> Dictionary:
	return {
		"name": b.name, "type": b.type, "mass": b.mass, "alive": b.alive, "emitsGW": b.emits_gw,
		"radius": b.radius if b.type != "bh" else null, "rs": b.rs if (b.type in ["bh", "neutron", "white-dwarf"]) else null,
		"radiusSun": b.radius_sun, "luminosity": b.luminosity, "teff": b.teff,
		"spectral": b.spectral, "phase": b.phase, "spinFrac": b.spin_frac, "Z": b.Z, "composition": b.composition,
		"dayLength": b.day_length if b.type == "world" else null,
		"obliquity": b.obliquity if b.type == "world" else null,
		"home": b.home if b.type == "world" else null,
		"radiusScene": b.radius_scene, "contactAU": b.contact_au, "structure": b.structure,
	}

func run_frames(key: String, frames: int, fps: float = 60.0, sample: int = 0) -> Dictionary:
	var lp := load_preset(key)
	var p: Dictionary = lp.p
	var E0 := Derive.total_energy(bodies)
	var steps := 0
	var max_steps := 0
	var capped := 0
	var samples := []
	var frame_dt: float = float(U.nz(p.get("timeScale"), 2.0)) / fps
	var t0 := Time.get_ticks_usec()
	for f in frames:
		step_physics(frame_dt)
		steps += last_steps; max_steps = maxi(max_steps, last_steps)
		if last_steps >= Derive.STEP_GUARD: capped += 1
		if sample > 0 and (f + 1) % sample == 0:
			var bl := []
			for b in bodies:
				bl.append({ "name": b.name, "pos": b.pos.to_array(), "vel": b.vel.to_array(), "mass": b.mass })
			var cl = null
			if climate != null:
				cl = { "T": climate.T, "S": climate.S, "era": climate.era.key, "ice": climate.ice, "clouds": climate.clouds,
					"humidity": climate.humidity, "storm": climate.storm, "time": climate.time,
					"historyLen": climate.history.size(), "extremes": climate.extremes.duplicate(), "perStar": climate.per_star.duplicate(true),
					"last": climate.history[climate.history.size() - 1] if not climate.history.is_empty() else null }
			samples.append({ "f": f + 1, "simYears": sim_years, "E": Derive.total_energy(bodies), "n": bodies.size(),
				"bodies": bl, "climate": cl })
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var E1 := Derive.total_energy(bodies)
	return { "key": key, "frames": frames, "fps": fps, "timeScale": U.nz(p.get("timeScale"), 2.0), "simYears": sim_years,
		"bodies": bodies.size(), "consumed": consumed, "E0": E0, "E1": E1, "drift": absf((E1 - E0) / E0),
		"steps": steps, "maxSteps": max_steps, "capped": capped, "ms": ms,
		"stepsPerSec": steps / (ms / 1000.0) if ms > 0.0 else 0.0, "samples": samples }

# ---- the helper dispatch (names are the JS exports) ------------------------
func make_calls() -> Dictionary:
	return {
		"rockyMaxRadius": func(c): return Structure.rocky_max_radius(c),
		"rockyRadiusEarth": func(m, c): return Structure.rocky_radius_earth(m, c),
		"giantRadiusJup": func(m): return Structure.giant_radius_jup(m),
		"whiteDwarfRadiusSun": func(m): return Structure.white_dwarf_radius_sun(m),
		"neutronRadiusKm": func(m): return Structure.neutron_radius_km(m),
		"tovLimit": func(s): return Structure.tov_limit(s),
		"hydrogenBurnLimit": func(z): return Structure.hydrogen_burn_limit(z),
		"phaseAt": func(f): return Structure.phase_at(f),
		"phaseById": func(id): return Structure.phase_by_id(id),
		"baseLuminosity": func(m, z): return Structure.base_luminosity(m, z),
		"baseRadiusSun": func(m): return Structure.base_radius_sun(m),
		"rocheShape": func(u): return Structure.roche_shape(u),
		"inverseRocheShape": func(r): return Structure.inverse_roche_shape(r),
		"rotationalShape": func(m, r, w, k): return Structure.rotational_shape(m, r, w, k),
		"breakupOmega": func(m, r, k): return Structure.breakup_omega(m, r, k),
		"gravityDarkeningBeta": func(t, s): return Structure.gravity_darkening_beta(t, s),
		"rocheGravity": func(s, c): return Structure.roche_gravity(s, c),
		"gravityDarkenedTemps": func(t, s): return Structure.gravity_darkened_temps(t, s),
		"centralConditions": func(m, r, x, z): return Structure.central_conditions(m, r, x, z),
		"pressureScaleHeightFrac": func(t, r, m): return Structure.pressure_scale_height_frac(t, r, m),
		"granuleFrequency": func(t, r, m): return Structure.granule_frequency(t, r, m),
		"surfaceBrightness": func(t): return Structure.surface_brightness(t),
		"spectralType": func(t): return Structure.spectral_type(t),
		"spectralFull": func(t, c): return Structure.spectral_full(t, c),
		"luminosityClass": func(r, m): return Structure.luminosity_class(r, m),
		"endStateOf": func(m): return Structure.end_state_of(m),
		"meanMolecularWeight": func(x, z): return Structure.mean_molecular_weight(x, z),
		"mainSequenceLifetime": func(m, l): return Structure.main_sequence_lifetime(m, l),
		"eddingtonLuminosity": func(m): return Structure.eddington_luminosity(m),
		"physicalRadiusAU": func(t, m, r): return Scale.physical_radius_au(t, m, r),
		"pixelsPerWorldUnit": func(d, f, h): return Scale.pixels_per_world_unit(d, f, h),
		"apparentPixels": func(r, d, f, h): return Scale.apparent_pixels(r, d, f, h),
		"discPeakTemp": func(m): return Derive.disc_peak_temp(m),
		"referenceRadiusAU": func(t): return Derive.reference_radius_au(t),
		"baseRadius": func(t, m, rs): return Derive.base_radius(null, { "type": t } if rs == null else { "type": t, "radiusSun": rs }, m),
	}

func climate_cases() -> Array:
	var out := []
	var mk := func(x: float, L: float, nm: String) -> Body:
		var b := Body.new()
		b.name = nm; b.mass = 1.0; b.luminosity = L; b.pos = DVec3.new(x, 0.0, 0.0)
		return b
	for opts in [{}, { "mixedLayer": 5.0, "T0": 200.0 }, { "mixedLayer": 60.0, "T0": 320.0, "greenhouse": 0.7, "albedoBase": 0.3, "albedoIce": 0.3 }]:
		var cl := Climate.new(opts)
		var planet: Body = mk.call(0.0, 0.0, "P")
		var rows := [{ "T": cl.T, "tau": cl.tau_years, "hc": cl.heat_capacity, "c": cl.celsius }]
		for row in [[1.0, 3.0, 0.01], [0.5, 2.0, 0.1], [0.3, 5.0, 1.0], [2.0, 1.0, 10.0], [1.0, 1.0, 0.0], [1.0, 1.0, -1.0], [1.0, 1.0, 0.003], [4.0, 0.2, 0.05]]:
			var stars := [mk.call(row[0], 1.0, "A"), mk.call(-row[1], 2.5, "B")]
			cl.step(row[2], planet, stars)
			rows.append({ "T": cl.T, "S": cl.S, "era": cl.era.key, "ice": cl.ice, "clouds": cl.clouds, "humidity": cl.humidity,
				"storm": cl.storm, "time": cl.time, "hist": cl.history.size(), "ext": cl.extremes.duplicate(), "perStar": cl.per_star.duplicate(true),
				"alb": cl.albedo(250.0), "cls": cl.classify(cl.T).key, "c": cl.celsius })
		cl.reset(250.0)
		rows.append({ "T": cl.T, "S": cl.S, "era": cl.era.key, "ext": cl.extremes, "hist": cl.history.size() })
		out.append(rows)
	return out

func transit_rv() -> Dictionary:
	load_preset("edu_transit")
	var star: Body = bodies[0]
	var lo := INF
	var hi := -INF
	var k := 1.495978707e11 / 3.15576e7
	for i in 5000:
		Physics.integrate(bodies, 1e-5)
		var rv := -star.vel.z * k
		lo = minf(lo, rv); hi = maxf(hi, rv)
	return { "K": (hi - lo) / 2.0, "lo": lo, "hi": hi }

# ---- JSON: INF/NaN as the strings the Node side writes ----------------------
func clean(v):
	match typeof(v):
		TYPE_FLOAT:
			if is_nan(v): return "NaN"
			if is_inf(v): return "Infinity" if v > 0 else "-Infinity"
			return v
		TYPE_DICTIONARY:
			var o := {}
			for k in v:
				if v[k] is Callable: continue
				o[k] = clean(v[k])
			return o
		TYPE_ARRAY:
			var a := []
			for x in v: a.append(clean(x))
			return a
		TYPE_OBJECT:
			if v is DVec3: return v.to_array()
			return str(v)
	return v

func _init() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	var mode: String = args.get("mode", "ref")
	if mode == "ref":
		var ref = JSON.parse_string(FileAccess.get_file_as_string(args["in"]))
		var out := {}
		var structure := []
		for s in ref.cases.specs: structure.append(Structure.structure_of(s))
		out.structure = structure
		var calls := make_calls()
		var cr := []
		for c in ref.cases.calls: cr.append((calls[c.fn] as Callable).callv(c.args))
		out.calls = cr
		var cat := {}
		for k in Starcat.STAR_CATALOG: cat[k] = Starcat.star_spec(k, { "extra": 1.0 })
		out.catalog = cat
		out.builders = {
			"ring": Starcat.star_ring(["sun", "vega", "siriusB", "betelgeuse"], 10.0, { "phase": 0.3 }),
			"ring0": Starcat.star_ring(["sun", "proxima"], 1.0),
			"binary": Starcat.real_binary("siriusA", "siriusB", { "a": 7.4957, "e": 0.5923 }),
			"binary2": Starcat.real_binary("alphacenA", "alphacenB", { "a": 23.52, "e": 0.5179, "incl": 0.14, "nu": 1.1 }),
			"companion": Starcat.companion(2.0, 3.0, { "name": "x", "mass": 1e-6 }, 0.7, 0.2),
		}
		out.presetOrder = Presets.PRESET_ORDER
		var presets := {}
		for key in Presets.PRESET_ORDER:
			var lp := load_preset(key)
			var meta := {}
			for k in lp.p:
				if not (lp.p[k] is Callable): meta[k] = lp.p[k]
			var bl := []
			for b in bodies:
				var o := body_out(b)
				o.rBoost = Derive.render_radius(b, b.spec, b.mass0, scene_scale, body_scale, true_scale)
				o.rOther = Derive.render_radius(b, b.spec, b.mass0, scene_scale, body_scale, not true_scale)
				o.baseRadius = Derive.base_radius(b, b.spec, b.mass0)
				bl.append(o)
			presets[key] = { "meta": meta, "specs": lp.specs, "bodies": bl, "E0": Derive.total_energy(bodies),
				"dyn": Derive.dynamic_step(bodies, max_step),
				"climate": { "T": climate.T, "S": climate.S, "perStar": climate.per_star } if climate != null else null }
		out.presets = presets
		out.climate = climate_cases()
		var fr := {}
		for key in ["trisolaris", "trisolaris_wander", "bhmerger", "nsmerger", "binarystar", "threebody", "solar", "feeding", "sandbox", "edu_seasons", "sirius"]:
			fr[key] = run_frames(key, 240, 60.0, 60)
		out.frames = fr
		out.transitRV = transit_rv()
		var AUkm := Physics.AU_PER_KM
		var earth := Structure.rotational_shape(3.0035e-6, 6371.0 * AUkm, 7.2921159e-5, "rocky")
		var jup := Structure.rotational_shape(9.5459e-4, 69911.0 * AUkm, 1.75853e-4, "giant")
		var vega := Structure.structure_of(Starcat.star_spec("vega"))
		var sun := Structure.structure_of({ "type": "star", "mass": 1.0, "phase": 0.5 })
		var bh0 := Structure.structure_of({ "type": "bh", "mass": 10.0 })
		var bh1 := Structure.structure_of({ "type": "bh", "mass": 10.0, "spinFrac": 0.998 })
		out.calibrations = {
			"earthFlattening": earth.f, "earthInvF": 1.0 / earth.f,
			"jupiterFlattening": jup.f,
			"siriusB_Rsun": Structure.white_dwarf_radius_sun(1.018),
			"iscoOverM_a0": bh0.iscoAU / (bh0.rs / 2.0),
			"iscoOverM_a998": bh1.iscoAU / (bh0.rs / 2.0),
			"vegaSpinFrac": vega.spinFrac, "vegaReOverRp": vega.radiusEqAU / vega.radiusPolarAU, "vegaTPole": vega.tPole, "vegaTEq": vega.tEq,
			"sunTc": sun.Tc, "sunPc": sun.Pc, "sunRhoC": sun.rhoC, "sunR": sun.radiusSun, "sunL": sun.luminosity, "sunTeff": sun.teff,
			"rockyMaxRadiusEarth": Structure.rocky_max_radius("earth").radiusEarth, "rockyMaxMassEarth": Structure.rocky_max_radius("earth").massEarth,
			"earth1ME_Rearth": Structure.rocky_radius_earth(1.0, "earth"),
		}
		var f := FileAccess.open(args["out"], FileAccess.WRITE)
		f.store_string(JSON.stringify(clean(out), "", false, true))
		f.close()
		print("wrote ", args["out"])
	elif mode == "long":
		var key: String = args.get("preset", "trisolaris")
		var years := float(args.get("years", "100"))
		var fps := float(args.get("fps", "60"))
		var p: Dictionary = Presets.PRESETS[key]
		var frames := int(ceil(years / (float(U.nz(p.get("timeScale"), 2.0)) / fps)))
		var r := run_frames(key, frames, fps, maxi(1, frames / 10))
		var series := []
		for s in r.samples:
			series.append({ "yr": s.simYears, "drift": absf((s.E - r.E0) / r.E0), "n": s.n })
		r.erase("samples")
		r.series = series
		print(JSON.stringify(clean(r), " ", false, true))
	quit()
