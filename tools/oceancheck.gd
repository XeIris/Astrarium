extends SceneTree

# The sea and what floats on it, headless: the FFT ocean against its own spectrum and a direct sum, and
# floating hulls against Archimedes and the Apollo record. docs/physics/ocean.md#what-tests-it.
# Run: python3 tools/check.py --only oceancheck

var checks := 0
var failures := 0

func ok(name: String, pass_: bool, detail: String) -> void:
	checks += 1
	if not pass_: failures += 1
	print("OCEANCHECK %s %s: %s" % ["ok" if pass_ else "FAIL", name, detail])

func note(name: String, detail: String) -> void:
	print("OCEANCHECK note %s: %s" % [name, detail])

func _init() -> void:
	_field()
	_one_wave()
	_hydrostatics()
	_capsule()
	_dynamics()
	print("OCEANCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

func _field() -> void:
	for case in [["Earth, 10 m/s, open sea", 9.81, 4000.0, Liquid.of("Earth"), 10.0, 6.0e5],
			["Earth, 5 m/s, 20 km fetch", 9.81, 4000.0, Liquid.of("Earth"), 5.0, 2.0e4],
			["Titan, 1 m/s, Ligeia", 1.352, 160.0, Liquid.of("Titan"), 1.0, 1.0e5]]:
		var t0 := Time.get_ticks_usec()
		var f := OceanField.new(case[1], case[2], case[3], case[4], 0.7, case[5], 7)
		var build_ms := (Time.get_ticks_usec() - t0) / 1000.0
		# What a continuous spectrum holds, integrated in ω with the spreading's normalisation, against the
		# lattices' sum over their bands.
		var m0 := 0.0
		var w := 0.02 * f.peak_omega
		while w < f.dispersion(f.k_hi[OceanField.CASCADES - 1]):
			var dw := w * 0.002
			m0 += SurfaceWaves.spectrum(w + 0.5 * dw, f.wind, f.g, f.fetch) * dw
			w += dw
		var lat := 0.0
		for c in OceanField.CASCADES: lat += f.variance[c]
		ok("%s: the lattices hold the spectrum" % case[0], absf(lat / m0 - 1.0) < 0.03,
			"Hs %s m on the lattices against %s m integrated; tiles %s m" % [U.fixed(4.0 * sqrt(lat), 3), U.fixed(4.0 * sqrt(m0), 3),
			", ".join(Array(f.L).map(func(x): return U.fixed(x, 1)))])
		var phys := f.variance[0] + f.variance[1]
		note("%s: the physics cascades" % case[0], "%s%% of the variance, waves down to %s m" % [U.fixed(100.0 * phys / lat, 2), U.fixed(TAU / f.k_hi[1], 2)])
		t0 = Time.get_ticks_usec()
		f.snapshot(37.25)
		var snap_ms := (Time.get_ticks_usec() - t0) / 1000.0
		# On its lattice points a cascade's FFT is the direct sum over its modes exactly.
		var worst := 0.0
		for c in OceanField.PHYSICS:
			var nn := f.n[c]
			var d := f.L[c] / float(nn)
			for p in [[0, 0], [3, 17], [40, 9], [63, 63]]:
				var exact := f.direct_height(float(p[0]) * d, float(p[1]) * d, 37.25, c)
				worst = maxf(worst, absf(f.hy[c][p[1] * nn + p[0]] - exact))
		ok("%s: the FFT is the direct sum" % case[0], worst < 1e-9, "worst %s m on lattice points" % U.expo(worst, 1))
		# The grid's own variance is Parseval's Σ|H|², which averages to m₀.
		var s2 := 0.0
		for c in OceanField.PHYSICS:
			var gsum := 0.0
			for v in f.hy[c]: gsum += v * v
			s2 += gsum / float(f.hy[c].size())
		ok("%s: the drawn sea's height spread" % case[0], absf(4.0 * sqrt(s2) / (4.0 * sqrt(phys)) - 1.0) < 0.25,
			"4σ %s m against the physics cascades' Hs %s m (one realisation)" % [U.fixed(4.0 * sqrt(s2), 3), U.fixed(4.0 * sqrt(phys), 3)])
		note("%s: cost" % case[0], "build %s ms, a CPU snapshot %s ms" % [U.fixed(build_ms, 1), U.fixed(snap_ms, 1)])
		var unres := f.unresolved_slope()
		var res := 0.0
		for c in OceanField.CASCADES: res += f.slope_var[c]
		note("%s: mean-square slope" % case[0], "%s drawn + %s unresolved" % [U.fixed(res, 4), U.fixed(unres, 4)])

# One wave alone: moved sideways as Lagrange's first order moves the water, its crest closes up and its trough
# opens, so over fixed points it stands above its mean for (π − 2ak)/2π of its length, less than half.
func _one_wave() -> void:
	var f := OceanField.new(9.81, 4000.0, Liquid.of("Earth"), 10.0, 0.0, 6.0e5, 7)
	var best := 0
	var big := 0.0
	for i in f.h0r[0].size():
		var a := f.h0r[0][i] * f.h0r[0][i] + f.h0i[0][i] * f.h0i[0][i]
		if a > big: big = a; best = i
	for c in OceanField.CASCADES:
		for i in f.h0r[c].size():
			if c == 0 and i == best: continue
			f.h0r[c][i] = 0.0; f.h0i[c][i] = 0.0
	# Steepen it, so the effect stands clear of the bilinear sampling.
	var nn := f.n[0]
	var dk := TAU / f.L[0]
	var kx := dk * float(OceanField._signed(best % nn, nn)); var kz := dk * float(OceanField._signed(best / nn, nn))
	var k := sqrt(kx * kx + kz * kz)
	var amp := 0.15 / k
	var s := amp * 0.5 / sqrt(big)
	f.h0r[0][best] *= s; f.h0i[0][best] *= s
	f._live[0].fill(1)
	f.snapshot(0.0)
	var above := 0
	var n := 4000
	var lam := TAU / k
	for i in n:
		var d := lam * i / n
		if f.height_at(kx / k * d, kz / k * d) > 0.0: above += 1
	var want := (PI - 2.0 * 0.15) / TAU
	ok("one wave's crest is narrower than its trough", absf(float(above) / n - want) < 0.01,
		"above its mean over %s of its length; Lagrange's first order gives (π − 2ak)/2π = %s at ak 0.15" % [U.fixed(float(above) / n, 4), U.fixed(want, 4)])

# A box hull: 8 corners, 12 outward-wound triangles, centred on the origin.
static func _box(bx: float, by: float, bz: float) -> Dictionary:
	var v := PackedFloat64Array()
	for i in 8:
		v.append_array([bx * (0.5 if i & 1 else -0.5), by * (0.5 if i & 2 else -0.5), bz * (0.5 if i & 4 else -0.5)])
	var tris := PackedInt32Array([0, 1, 5, 0, 5, 4, 2, 6, 7, 2, 7, 3, 0, 4, 6, 0, 6, 2, 1, 3, 7, 1, 7, 5, 0, 2, 3, 0, 3, 1, 4, 5, 7, 4, 7, 6])
	return {"verts": v, "tris": tris}

func _hydrostatics() -> void:
	var sea := Liquid.of("Earth")
	var box := _box(4.0, 2.0, 3.0)
	ok("a box's volume", absf(Floater.volume(box.verts, box.tris) - 24.0) < 1e-12, "%s m³" % U.fixed(Floater.volume(box.verts, box.tris), 6))
	var f := Floater.new(9.81, sea, 1.225)
	f.hulls.append({"verts": box.verts, "tris": box.tris, "scale": 1.0, "name": "box"})
	# Its bottom 0.7 m under: Archimedes, ρg·4·3·0.7, straight up and with no moment.
	f.p = PackedFloat64Array([0.0, 0.3, 0.0])
	var l := f.loads(true)
	var want := 1025.0 * 9.81 * 12.0 * 0.7
	ok("Archimedes on a box", absf(l[1] / want - 1.0) < 1e-12 and absf(l[0]) + absf(l[2]) < 1e-9 * want and absf(l[3]) + absf(l[4]) + absf(l[5]) < 1e-9 * want,
		"%s N up against ρgV %s N; displaced %s m³" % [U.fixed(l[1], 3), U.fixed(want, 3), U.fixed(f.displaced, 6)])
	# Heeled a little about z, at the same draft: the moment is ρgV·GM·φ with GM = KB + BM − KG, BM = B²/12T.
	var phi := 0.02
	f.set_basis(Basis(Vector3(0, 0, 1), phi))
	l = f.loads(true)
	var T := 0.7
	var gm := T / 2.0 + 4.0 * 4.0 / (12.0 * T) - 1.0
	var m_want := -1025.0 * 9.81 * 12.0 * T * gm * sin(phi)
	ok("a box's righting moment", absf(l[5] / m_want - 1.0) < 0.01,
		"%s N·m against ρgV·GM·sin φ %s N·m (GM %s m)" % [U.fixed(l[5], 1), U.fixed(m_want, 1), U.fixed(gm, 3)])
	# Let it float free from a metre too high: it settles at m/ρA.
	var g2 := Floater.new(9.81, sea, 1.225)
	g2.hulls.append({"verts": box.verts, "tris": box.tris, "scale": 1.0, "name": "box"})
	var m := 6000.0
	g2.set_inertia(m, PackedFloat64Array([m * (4.0 + 9.0) / 12.0, 0, 0, 0, m * (16.0 + 9.0) / 12.0, 0, 0, 0, m * (16.0 + 4.0) / 12.0]))
	g2.p = PackedFloat64Array([0.0, 1.5, 0.0])
	g2.advance(60.0)
	var draft := 1.0 - g2.p[1]
	ok("a box settles at its draft", absf(draft - m / (1025.0 * 12.0)) < 2e-3,
		"%s m against m/ρA %s m, after a minute" % [U.fixed(draft, 4), U.fixed(m / (1025.0 * 12.0), 4)])

## Still water: the height at which the CM, held at heel φ about z, floats, and the moment the water puts
## on it there about its centre of mass.
func _equilibrium(f: Floater, phi: float) -> PackedFloat64Array:
	f.set_basis(Basis(Vector3(0, 0, 1), phi))
	var lo := -4.0; var hi := 4.0
	var weight := f.mass * f.g
	for i in 60:
		var mid := 0.5 * (lo + hi)
		f.p = PackedFloat64Array([0.0, mid, 0.0])
		if f.loads(true)[1] > weight: lo = mid
		else: hi = mid
	f.p = PackedFloat64Array([0.0, 0.5 * (lo + hi), 0.0])
	var l := f.loads(true)
	return PackedFloat64Array([f.p[1], l[5]])

# Attitudes the water holds the CM in, over a full turn: zeros of the righting moment that it falls through, and
# that still push back from 7.5° either side (a near-neutral graze on its side is no resting place).
func _stable(f: Floater) -> Array:
	var out := []
	var steps := 144
	var dphi := TAU / steps
	var prev := _equilibrium(f, -PI)[1]
	for i in range(1, steps + 1):
		var phi := -PI + dphi * i
		var m := _equilibrium(f, phi)[1]
		if prev > 0.0 and m <= 0.0:
			var at := phi - dphi + dphi * prev / (prev - m)
			var side := deg_to_rad(7.5)
			if _equilibrium(f, at - side)[1] > 0.0 and _equilibrium(f, at + side)[1] < 0.0:
				out.append(rad_to_deg(at))
		prev = m
	return out

func _capsule() -> void:
	var sea := Liquid.of("Earth")
	var mesh := Capsule.lathe(Capsule.outline(), 12)
	var vol := Floater.volume(mesh.verts, mesh.tris)
	var f := Capsule.floater(9.81, sea, 1.225)
	note("the command module", "%s m³ of hull for %s m³ of sea water to displace" % [U.fixed(vol, 2), U.fixed(Capsule.MASS / 1025.0, 2)])
	var empty := _stable(f)
	ok("the CM floats two ways with its bags empty", empty.size() == 2,
		"stable at heel %s°; NASA TN D-7081: Stable I and Stable II" % ", ".join(empty.map(func(x): return U.fixed(x, 0))))
	Capsule.inflate(f, 1.0)
	var full := _stable(f)
	ok("with the bags full, only upright", full.size() == 1 and absf(full[0]) < 90.0,
		"stable at heel %s°" % ", ".join(full.map(func(x): return U.fixed(x, 0))))
	Capsule.inflate(f, 0.0)
	var up := _equilibrium(f, deg_to_rad(float(empty[0]) if not empty.is_empty() else 0.0))
	note("Stable I", "the shield's lowest point %s m under the surface" % U.fixed(-(up[0] - Capsule.CG_Y), 2))
	var titan := Capsule.floater(1.352, Liquid.of("Titan"), 5.4)
	var te := _equilibrium(titan, 0.0)
	ok("on Ligeia Mare it still floats", titan.displaced > 0.0 and titan.displaced < vol * 0.98,
		"%s of its %s m³ under, against %s in sea water" % [U.fixed(titan.displaced, 2), U.fixed(vol, 2), U.fixed(Capsule.MASS / 1025.0, 2)])

static func heel(f: Floater) -> float:
	return rad_to_deg(acos(clampf(f.rot[4], -1.0, 1.0)))

func _dynamics() -> void:
	var sea := Liquid.of("Earth")
	# Onto still water at Apollo's 22 mph under three mains.
	var f := Capsule.floater(9.81, sea, 1.225)
	f.p = PackedFloat64Array([0.0, 8.0, 0.0])
	f.v = PackedFloat64Array([0.0, -9.83, 0.0])
	f.chute = {"at": PackedFloat64Array([0.0, Capsule.HEIGHT - Capsule.CG_Y, 0.0]), "area": Capsule.MAINS.area, "cd": Capsule.MAINS.Cd}
	var t0 := Time.get_ticks_usec()
	f.advance(1.2)
	var vz := f.v[1]
	f.chute = null
	f.advance(40.0)
	var wall := (Time.get_ticks_usec() - t0) / 1e6
	note("splashdown on still water", "peak %s g; %s° heel after 40 s; %s s of wall time for 40 s" % [U.fixed(f.peak_accel / 9.81, 1), U.fixed(heel(f), 0), U.fixed(wall, 2)])
	ok("it comes to rest afloat", absf(f.v[1]) < 0.05 and heel(f) < 20.0 and f.wet,
		"heave %s m/s, heel %s°, %s m³ displaced against %s" % [U.fixed(f.v[1], 3), U.fixed(heel(f), 1), U.fixed(f.displaced, 2), U.fixed(Capsule.MASS / 1025.0, 2)])
	# Upside down, then the bags: Apollo 11 came down inverted and stood up 7.6 minutes after splashdown, in a
	# sea; here one a 7 m/s wind raised.
	var u := Capsule.floater(9.81, sea, 1.225)
	var st := _equilibrium(u, deg_to_rad(float(_stable(u)[0])))
	u.p = PackedFloat64Array([0.0, st[0], 0.0])
	u.field = OceanField.new(9.81, 4000.0, sea, 7.0, 0.7, 6.0e5, 11)
	u.advance(30.0)
	var still2 := heel(u)
	var t_up := -1.0
	while u.t < 30.0 + Capsule.INFLATE_S + 300.0:
		Capsule.inflate(u, (u.t - 30.0) / Capsule.INFLATE_S)
		u.advance(u.t + 1.0)
		if heel(u) < 30.0 and t_up < 0.0: t_up = u.t - 30.0
		if t_up > 0.0 and u.t - 30.0 > t_up + 20.0: break
	ok("Stable II holds until the bags fill", still2 > 90.0, "%s° after 30 s" % U.fixed(still2, 0))
	ok("the bags right it", t_up > 0.0 and heel(u) < 30.0,
		"upright %s s after the compressors start (filling in %s s), Hs %s m; Apollo 11: 7.6 min from splashdown" % [U.fixed(t_up, 0), U.fixed(Capsule.INFLATE_S, 0), U.fixed(u.field.hs(), 2)])
	# On still water nothing knocks it over the crest of its righting curve.
	var s0 := Capsule.floater(9.81, sea, 1.225)
	var e2 := _equilibrium(s0, deg_to_rad(float(_stable(s0)[0])))
	s0.p = PackedFloat64Array([0.0, e2[0], 0.0])
	Capsule.inflate(s0, 1.0)
	s0.advance(120.0)
	note("the bags on still water", "%s° of heel after 120 s full" % U.fixed(heel(s0), 0))
	# In a 10 m/s sea: a 3.9 m capsule on 80 m waves goes up and down with the water under it.
	var field := OceanField.new(9.81, 4000.0, sea, 10.0, 0.7, 6.0e5, 11)
	var w := Capsule.floater(9.81, sea, 1.225)
	w.field = field
	var e0 := _equilibrium(w, deg_to_rad(-5.0))
	w.p = PackedFloat64Array([0.0, e0[0], 0.0])
	w.field = field
	w.advance(20.0)
	var hs := PackedFloat64Array(); var ws := PackedFloat64Array()
	t0 = Time.get_ticks_usec()
	while w.t < 140.0:
		w.advance(w.t + 0.5)
		hs.append(w.p[1]); ws.append(w.water(w.p[0], w.p[2])[0])
	wall = (Time.get_ticks_usec() - t0) / 1e6
	var mh := 0.0; var mw := 0.0
	for i in hs.size(): mh += hs[i]; mw += ws[i]
	mh /= hs.size(); mw /= ws.size()
	var shh := 0.0; var sww := 0.0; var shw := 0.0
	for i in hs.size():
		shh += (hs[i] - mh) * (hs[i] - mh); sww += (ws[i] - mw) * (ws[i] - mw); shw += (hs[i] - mh) * (ws[i] - mw)
	var corr := shw / sqrt(shh * sww)
	var ratio := sqrt(shh / sww)
	ok("it rides the waves", corr > 0.9 and ratio > 0.8 and ratio < 1.25,
		"heave against the water under it: correlation %s, ratio of spreads %s (Hs %s m)" % [U.fixed(corr, 3), U.fixed(ratio, 2), U.fixed(field.hs(), 2)])
	note("in waves", "%s s of wall time for 120 s; drifted %s m" % [U.fixed(wall, 1), U.fixed(Vector2(w.p[0], w.p[2]).length(), 1)])
