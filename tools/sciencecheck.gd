extends SceneTree

# Synthetic and frozen-state instrument checks, plus live numerical convergence.
# Godot --headless --path . --script res://tools/sciencecheck.gd
# Add -- compatibility=web to strictly compare obsolete live trajectories too;
# corrected force/contact models intentionally differ from that frozen run.

var fails := 0
var rows := 0

func check(name: String, ok: bool, value = null) -> void:
	rows += 1
	if not ok: fails += 1
	print("%s %s%s" % ["ok  " if ok else "FAIL", name, "" if value == null else "  (%s)" % str(value)])

static func rel_err(a: float, b: float) -> float:
	if a == b: return 0.0
	return absf(a - b) / maxf(maxf(absf(a), absf(b)), 1e-300)

func body(name: String, radius: float, pos: Array, lum = 0.0) -> Body:
	var b := Body.new()
	b.name = name; b.radius = radius; b.luminosity = lum; b.alive = true
	b.pos = DVec3.new(pos[0], pos[1], pos[2]); b.vel = DVec3.new()
	return b

func from_fixture(arr: Array) -> Array:
	var out: Array = []
	for d in arr:
		var b := Body.new()
		# JSON drops what JS left undefined (a hole has no `radius`), and the
		# Body defaults are the same zeros the JS `||` fallbacks read.
		b.name = d.name; b.type = d.type; b.mass = d.mass
		b.radius = float(U.nz(d.get("radius"), 0.0)); b.rs = float(U.nz(d.get("rs"), 0.0))
		b.contact_au = float(U.nz(d.get("contactAU"), 0.0)); b.luminosity = d.get("luminosity"); b.alive = d.get("alive", true)
		b.pos = DVec3.new(d.pos[0], d.pos[1], d.pos[2]); b.vel = DVec3.new(d.vel[0], d.vel[1], d.vel[2])
		out.append(b)
	return out

func build(key: String) -> Array:
	var p: Dictionary = Presets.PRESETS[key]
	var out := []
	var id := 1
	for spec in p.build.call():
		var b := Derive.new_body(id, spec); id += 1
		b.contact_au = Derive.contact_au(b, spec, Derive.render_radius(b, spec, b.mass0, float(p.sceneScale), float(p.get("bodyScale", 1.0)), bool(p.get("trueScale", false))), float(p.sceneScale))
		out.append(b)
	return out

func load_json(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	return JSON.parse_string(f.get_as_text()) if f else null

func sample_live(substeps: int) -> Dictionary:
	var bodies := build("edu_transit")
	var deepest := 0.0
	var lo := INF
	var hi := -INF
	var worst_rv := 0.0
	var peak: Array = []
	for i in 5000:
		for step in substeps: Physics.integrate(bodies, 1e-5 / substeps)
		var m := LightCurve.measure(bodies, DVec3.new(0.0, 0.0, 1.0))
		var depth: float = 1.0 - m.rel
		if depth > deepest:
			deepest = depth
			peak.clear()
			for b: Body in bodies:
				peak.append(body(b.name, b.radius, b.pos.to_array(), b.luminosity))
		lo = minf(lo, m.rv)
		hi = maxf(hi, m.rv)
		# Independent SI projection along +z, positive for recession.
		var expected: float = -bodies[0].vel.z * 149597870700.0 / 31557600.0
		worst_rv = maxf(worst_rv, absf(m.rv - expected))
	return {"depth": deepest, "K": (hi - lo) / 2.0, "rv_error": worst_rv, "peak": peak}

func transit_quadrature(bodies: Array) -> float:
	var star: Body = bodies[0]
	var blocked := 0.0
	# Integrate in polar coordinates over each smaller occulter, independently of
	# the instrument's golden-angle sample pattern; the live peak has no overlaps.
	for i in range(1, bodies.size()):
		var planet: Body = bodies[i]
		var dx := planet.pos.x - star.pos.x
		var dy := planet.pos.y - star.pos.y
		if planet.pos.z <= star.pos.z or sqrt(dx * dx + dy * dy) >= star.radius + planet.radius: continue
		var intensity := 0.0
		for ring in 64:
			var r := planet.radius * sqrt((ring + 0.5) / 64.0)
			for angle in 256:
				var theta := TAU * (angle + 0.5) / 256.0
				var x := dx + r * cos(theta)
				var y := dy + r * sin(theta)
				var q := (x * x + y * y) / (star.radius * star.radius)
				if q < 1.0: intensity += 0.4 + 0.6 * sqrt(1.0 - q)
		blocked += planet.radius * planet.radius / (star.radius * star.radius) * intensity / (64.0 * 256.0 * 0.8)
	return blocked

func _init() -> void:
	# ---- 1. synthetic
	var star := body("star", 1.0, [0, 0, 0], 1.0)
	var p := body("planet", 0.1, [0, 0, 2])
	var u := DVec3.new(0, 0, 1)
	var m := LightCurve.measure([star, p], u)
	check("central limb-darkened transit", absf((1.0 - m.rel) - 0.012481) < 0.00001, 1.0 - m.rel)
	check("face-on has no transit", LightCurve.measure([star, p], DVec3.new(0, 1, 0)).rel == 1.0)
	var twin := body("twin", 0.1, [0, 0, 2])
	check("overlapping silhouettes counted once", absf(LightCurve.measure([star, p, twin], u).rel - m.rel) < 1e-10)
	check("large occulter total eclipse", LightCurve.measure([star, body("large", 100.0, [0, 0, 2])], u).rel == 0.0)
	check("luminous companion eclipse", LightCurve.measure([star, body("companion", 2.0, [0, 0, 2], 0.5)], u).rel == 1.0 / 3.0)
	var bh := build("bhmerger")
	var pair = GWDetector.find_binary(bh)
	var h = GWDetector.strain_of(pair)
	var h2 = GWDetector.strain_of(pair, {"distMpc": 820.0})
	check("GW amplitude scales as inverse distance", absf(h.h0 / h2.h0 - 2.0) < 1e-12)
	star.type = "star"; p.type = "planet"
	check("GW ignores noncompact objects", GWDetector.find_binary([star, p]) == null)

	# ---- 2. fixture replay
	var fx = load_json("res://tools/fixtures/course/instruments.json")
	if fx == null:
		check("fixture present", false)
	else:
		for key in ["edu_transit", "alphacen", "sirius"]:
			var bodies := from_fixture(fx[key].bodies)
			var worst := 0.0
			var ev_ok := true
			for r in fx[key].rows:
				var uu := DVec3.new(r.u[0], r.u[1], r.u[2])
				var g := LightCurve.measure(bodies, uu)
				worst = maxf(worst, rel_err(g.rel, r.rel))
				worst = maxf(worst, rel_err(g.flux, r.flux))
				worst = maxf(worst, absf(g.rv - r.rv) / maxf(absf(r.rv), 1.0))
				if g.events.size() != int(r.events): ev_ok = false
			check("photometer replay %s (%d sight lines): worst rel err" % [key, fx[key].rows.size()], worst < 1e-9 and ev_ok, worst)
		for key in ["bhmerger", "nsmerger"]:
			var bodies := from_fixture(fx[key].bodies)
			var pr = GWDetector.find_binary(bodies)
			var same_pair: bool = pr != null and [pr.a.name, pr.b.name] == fx[key].pair
			var worst := 0.0
			for pair_case in [["s410", {}], ["s40i", {"distMpc": 40.0, "incl": 0.5}]]:
				var want: Dictionary = fx[key][pair_case[0]]
				var got: Dictionary = GWDetector.strain_of(pr, pair_case[1])
				for k in ["Mc", "rAU", "rSchwarz", "omega", "fGW", "h0", "hPlus", "hCross"]:
					worst = maxf(worst, rel_err(float(got[k]), float(want[k])))
				if bool(got.inBand) != bool(want.inBand): worst = INF
			check("GW replay %s (pair %s): worst rel err" % [key, str(fx[key].pair)], same_pair and worst < 1e-10, worst)

	var coarse := sample_live(1)
	var medium := sample_live(2)
	var fine := sample_live(4)
	check("live hot Jupiter transit depth in (0.019, 0.022)", coarse.depth > 0.019 and coarse.depth < 0.022, coarse.depth)
	check("live hot Jupiter RV amplitude in (145, 160)", coarse.K > 145.0 and coarse.K < 160.0, coarse.K)
	check("live radial velocity matches SI projection", coarse.rv_error < 1e-10, coarse.rv_error)
	var oracle := transit_quadrature(fine.peak)
	check("live transit peak agrees with independent quadrature", rel_err(fine.depth, oracle) < 5e-4, rel_err(fine.depth, oracle))
	for key in ["depth", "K"]:
		var coarse_gap := absf(float(coarse[key]) - float(medium[key]))
		var fine_gap := absf(float(medium[key]) - float(fine[key]))
		check("live %s converges under timestep halving" % key, fine_gap <= 0.5 * coarse_gap + 1e-12 and rel_err(float(medium[key]), float(fine[key])) < 1e-4, {"coarse_gap": coarse_gap, "fine_gap": fine_gap})
	var strict_compatibility := OS.get_cmdline_user_args().has("compatibility=web")
	var sci = load_json("res://tools/fixtures/course/science.json")
	var web_depth := -1.0
	var web_k := -1.0
	if sci:
		for r in sci.rows:
			if r.name == "live hot Jupiter transit depth": web_depth = float(r.value)
			if r.name == "live hot Jupiter RV amplitude": web_k = float(r.value)
	check("frozen live trajectory fixture present", web_depth > 0.0 and web_k > 0.0)
	if web_depth > 0.0 and web_k > 0.0:
		var depth_difference := rel_err(coarse.depth, web_depth)
		var rv_difference := rel_err(coarse.K, web_k)
		print("SCIENCECHECK COMPATIBILITY web depth_rel=%s K_rel=%s strict=%s" % [depth_difference, rv_difference, strict_compatibility])
		if strict_compatibility:
			check("depth matches the frozen web trajectory", depth_difference < 1e-6, depth_difference)
			check("K matches the frozen web trajectory", rv_difference < 1e-6, rv_difference)

	# ---- 4. the HR diagram's main sequence is structure_of, and passes the Sun
	var hr := HRDiagram.create_hr_diagram({})
	var near_sun := false
	for q in hr.MS:
		if absf(q.m - 1.0) < 0.03 and absf(q.teff - 5772.0) < 150.0 and absf(q.L - 1.0) < 0.1: near_sun = true
	check("HR main sequence sampled from structure_of passes the Sun (%d samples)" % hr.MS.size(), near_sun)

	print("sciencecheck: %d checks, %d failed" % [rows, fails])
	quit(1 if fails > 0 else 0)
