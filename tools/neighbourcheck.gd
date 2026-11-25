extends SceneTree
# Neighbours against the full scans it replaces, copied below as they stood: the tidal
# test's primary, the eclipse occluders and the planetshine source, for every receiver of
# random, flat, collinear, tied, coincident and real scenes. Any difference fails.
# Godot --headless --path . --script res://tools/neighbourcheck.gd

var checks := 0
var failures := 0
var rng := RandomNumberGenerator.new()

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL ", what)

func _init() -> void:
	rng.seed = 75
	var types := ["planet", "world", "gas-giant", "star", "bh", "neutron", "white-dwarf"]
	compare("random cloud", cloud(220, types, 50.0, false))
	compare("flat disc", cloud(220, types, 60.0, true))
	compare("rocky disc", cloud(300, ["planet"], 60.0, true))
	compare("collinear", line(120, types))
	compare("lattice ties", lattice(types))
	compare("coincident and dead", degenerate(types))
	compare("tie on the bound", bound_tie())
	compare("wide range", wide(types))
	var solar: Array = []
	var id := 1
	for spec in Presets.PRESETS.solar.build.call():
		solar.append(Derive.new_body(id, spec)); id += 1
	compare("solar", solar)
	var nan_receiver := cloud(40, types, 20.0, false)
	nan_receiver[3].pos.x = NAN
	nan_receiver[7].pos.z = INF
	# A non-finite distance gives the full scan a NaN angular radius, which its sort places
	# anywhere; the index takes no such occluder. Tides and shine agree.
	compare("non-finite receivers", nan_receiver, true)
	print("NEIGHBOURCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

func make(id: int, type: String, mass: float, radius: float, p: Vector3) -> Body:
	var b := Body.new()
	b.id = id; b.type = type; b.name = "%s %d" % [type, id]
	b.mass = mass; b.radius = radius
	b.pos = DVec3.new(p.x, p.y, p.z)
	if rng.randf() < 0.3: b.spec = {"albedo": rng.randf_range(0.05, 0.9)}
	return b

func cloud(n: int, types: Array, size: float, flat: bool) -> Array:
	var out := [make(1, "bh", 50.0, 0.0, Vector3.ZERO)]
	for i in n:
		var t: String = types[rng.randi() % types.size()]
		var p := Vector3(rng.randf_range(-size, size), 0.0 if flat else rng.randf_range(-size, size), rng.randf_range(-size, size))
		out.append(make(i + 2, t, pow(10.0, rng.randf_range(-8.0, 1.0)), pow(10.0, rng.randf_range(-6.0, -2.0)), p))
	return out

func line(n: int, types: Array) -> Array:
	var out := []
	for i in n:
		out.append(make(i + 1, types[i % types.size()], pow(10.0, rng.randf_range(-6.0, 0.0)), 1e-4, Vector3(0.0, 0.0, rng.randf_range(-30.0, 30.0))))
	return out

# Equal masses and radii on a grid: many exact ties in every value.
func lattice(types: Array) -> Array:
	var out := []
	var id := 1
	for a in 6:
		for b in 6:
			for c in 2:
				out.append(make(id, types[id % 3], 1e-5, 2e-4, Vector3(a, c, b) * 2.0)); id += 1
	out.append(make(id, "star", 1.0, 0.005, Vector3(5, 10, 5)))
	return out

# Two equal neighbours at the same distance, the earlier one reached last and exactly on
# the stopping bound: a search that stops on a tie picks the later one.
func bound_tie() -> Array:
	var out := [make(1, "planet", 1e-5, 1e-4, Vector3(40, 0, 0)),
		make(2, "planet", 1e-5, 1e-4, Vector3(0, 0, 1)),
		make(3, "planet", 1e-5, 1e-4, Vector3(1, 0, 0)),
		make(4, "planet", 1e-5, 1e-4, Vector3.ZERO)]
	for i in 30: out.append(make(i + 5, "planet", 1e-5, 1e-4, Vector3(10 + i, 0, 0)))
	for b: Body in out: b.spec = {}
	return out

func degenerate(types: Array) -> Array:
	var out := cloud(60, types, 5.0, false)
	out[5].pos = out[9].pos.clone()
	out[6].pos = out[9].pos.clone()
	out[11].alive = false
	out[12].radius = 0.0
	out[13].mass = 0.0
	return out

func wide(types: Array) -> Array:
	var out := []
	for i in 80:
		var r := pow(10.0, rng.randf_range(-4.0, 6.0))
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1)).normalized() * r
		out.append(make(i + 1, types[i % types.size()], pow(10.0, rng.randf_range(-12.0, 3.0)), pow(10.0, rng.randf_range(-9.0, 0.0)), d))
	return out

func compare(label: String, bodies: Array, non_finite := false) -> void:
	var near := Neighbours.new(bodies)
	var stars := bodies.filter(func(b): return b.type == "star" and b.alive)
	var star: Body = stars[0] if not stars.is_empty() else null
	var bad := 0
	for b: Body in bodies:
		if near.strongest_pull(b) != tide_scan(b, bodies): bad += 1
		for limit in [INF, 3.0]:
			var got := near.occluders(b, limit, Suns.MAX_OCCLUDERS)
			if non_finite:
				for o: Body in got:
					if is_nan(key(b, o)): bad += 1
			elif not same_picks(got, occluder_scan(b, bodies, limit), b):
				bad += 1
		if star != null:
			var lit := near.shine(b, star)
			var want := shine_scan(b, bodies, star)
			if lit[0] != want[0] or not (lit[1] == want[1]): bad += 1
	ok(bad == 0, "%s: %d bodies, %d mismatches" % [label, bodies.size(), bad])

# The occluders' order is the full scan's sort, whose ties are not stable past 16 picks:
# the angular radii must match exactly, and the bodies too where no tie decides.
func same_picks(got: Array, want: Array, b: Body) -> bool:
	if got.size() != want.size(): return false
	for k in got.size():
		if got[k] == want[k]: continue
		if key(b, got[k]) != key(b, want[k]): return false
	return true

func key(receiver: Body, b: Body) -> float:
	return b.radius / maxf(b.pos.distance_to(receiver.pos), 1e-12)

# --- the full scans as main._check_tidal_limit and Suns.apply_occluders / apply_shine ran them

func tide_scan(b: Body, bodies: Array) -> Body:
	var prim: Body = null
	var pull := 0.0
	for o in bodies:
		if o == b or not o.alive: continue
		var d2 := b.pos.distance_sq_to(o.pos)
		if d2 <= 0.0: continue
		var t: float = o.mass / (d2 * sqrt(d2))
		if t > pull: pull = t; prim = o
	return prim

func occluder_scan(body: Body, bodies: Array, nearest_star: float) -> Array:
	var picks: Array = []
	for b: Body in bodies:
		if b == body or not b.alive or b.radius <= 0.0 or b.type in ["star", "bh", "neutron", "white-dwarf"]: continue
		var d := b.pos.distance_to(body.pos)
		if d >= nearest_star: continue
		picks.append([b.radius / maxf(d, 1e-12), b])
	picks.sort_custom(func(x, y): return x[0] > y[0])
	var out := []
	for j in mini(picks.size(), Suns.MAX_OCCLUDERS): out.append(picks[j][1])
	return out

func shine_scan(body: Body, bodies: Array, star: Body) -> Array:
	var best := 0.0
	var won: Body = null
	for b: Body in bodies:
		if b == body or not b.alive or b.radius <= 0.0 or not (b.type in ["planet", "world", "gas-giant"]): continue
		var to_body := b.pos.sub(body.pos).scaled(-1.0)
		var d := to_body.length()
		var to_star := star.pos.sub(b.pos)
		var alpha := acos(clampf(to_body.normalized().dot(to_star.normalized()), -1.0, 1.0))
		var A := float(U.nz(b.spec.get("albedo"), Rocketry.SURFACES.get(b.name, {}).get("albedo", 0.3)))
		var f := A * 2.0 / 3.0 * pow(b.radius / maxf(d, 1e-12), 2.0) * (sin(alpha) + (PI - alpha) * cos(alpha)) / PI
		if f > best:
			best = f
			won = b
	return [won, best]
