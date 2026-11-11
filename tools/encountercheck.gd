extends SceneTree
# Galaxy encounters: van der Marel et al.'s (2012b) semi-analytic orbits (GalOrbits) against
# what they published and the integrator against Kepler; the restricted stars (GalEncounter);
# the equilibrium sampler (GalEddington) against Hernquist's closed forms; the live tree
# (GalLive) against its twin and against direct summation, and a live galaxy left alone.

var checks := 0
var failures := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond: failures += 1
	print(("ok   " if cond else "FAIL ") + what)

func _init() -> void:
	halos()
	kepler()
	canonical()
	isolated()
	parity()
	spins()
	discs()
	eddington()
	live_parity()
	live_accuracy()
	live_alone()
	switch()
	print("ENCOUNTERCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

## Their paper II's worked example (c 10: c200 7.4, a/r_s 2.01, M_H/M_vir 1.36) and the
## canonical scales they quote (62.5 kpc for 1.5 × 10¹² M☉ at c 9.56, 24.9 for M33).
func halos() -> void:
	var h := GalOrbits.hernquist_halo(1e12, 10.0)
	# Within 1 %: their c200 iteration and rounding to the digits they print.
	ok(absf(float(h[3]) / 7.4 - 1.0) < 0.01 and absf(float(h[4]) / 2.01 - 1.0) < 0.01 and absf(float(h[0]) / 1e12 / 1.36 - 1.0) < 0.01,
		"a c = 10 halo: c200 %s, a/r_s %s, M_H/M_vir %s (van der Marel et al. 2012a: 7.4, 2.01, 1.36)" % [
		String.num(float(h[3]), 3), String.num(float(h[4]), 3), String.num(float(h[0]) / 1e12, 3)])
	var mw := GalOrbits.hernquist_halo(1.5e12, 9.56)
	var m33 := GalOrbits.hernquist_halo(0.15e12, 11.37)
	ok(absf(float(mw[1]) - 62.5) < 0.05 and absf(float(m33[1]) - 24.9) < 0.05, "canonical Hernquist scales %s and %s kpc (62.5, 24.9)" % [
		String.num(float(mw[1]), 2), String.num(float(m33[1]), 2)])

## Two compact galaxies without friction far outside each other's scales: a Kepler ellipse.
## The period and the energy after ten orbits.
func kepler() -> void:
	var o := GalOrbits.new()
	o.friction = false
	o.add("A", 1e11, 1e-5, Vector3(-100.0, 0.0, 0.0), Vector3.ZERO)
	o.add("B", 1e11, 1e-5, Vector3(100.0, 0.0, 0.0), Vector3.ZERO)
	var mu := o.gm[0] + o.gm[1]
	# Each at half of 0.7 times the circular relative speed, opposite: an ellipse from apocentre.
	var v := sqrt(mu / 200.0) * 0.7 * 0.5
	o.vel[1] = -v
	o.vel[4] = v
	var e0 := _energy(o)
	# Semi-major axis from the vis-viva relation; T = 2π √(a³/μ).
	var vr := 2.0 * v
	var sma := 1.0 / (2.0 / 200.0 - vr * vr / mu)
	var period := TAU * sqrt(sma * sma * sma / mu)
	var dt := period / 20000.0
	var last_y := 0.0
	var crossings := []
	for k in 200000:
		o.step(dt)
		var y := o.pos[4] - o.pos[1]
		if last_y < 0.0 and y >= 0.0: crossings.append(o.t)
		last_y = y
	var measured := (float(crossings[crossings.size() - 1]) - float(crossings[0])) / float(crossings.size() - 1)
	var de := absf(_energy(o) / e0 - 1.0)
	ok(absf(measured / period - 1.0) < 1e-4 and de < 1e-8, "two point galaxies keep Kepler's period (%s) and their energy (%s) over ten orbits" % [
		U.expo(absf(measured / period - 1.0), 1), U.expo(de, 1)])

func _energy(o: GalOrbits) -> float:
	var e := 0.0
	var m := [o.gm[0], o.gm[1]]
	for i in 2:
		var v := o.velocity(i)
		e += 0.5 * float(m[i]) * v.length_squared()
	e -= o.gm[0] * o.gm[1] / o.separation(0, 1)
	return e

## The canonical Milky Way–M31–M33 model, 10 Gyr at 1 Myr.
func canonical() -> void:
	var o := GalModels.encounter(GalModels.VDM_CANONICAL)
	var hist := [[], [], []]
	var pairs := [[0, 1], [1, 2], [0, 2]]
	var cm0 := _centre(o)
	var vcm := _momentum(o)
	for k in 10000:
		o.step(1.0)
		for p in 3: hist[p].append(o.separation(pairs[p][0], pairs[p][1]))
	var peri := _first_min(hist[0])
	var apo := _next_max(hist[0], int(peri[0]))
	var m33 := _first_min(hist[1])
	# Merged once the centres stay within 5 kpc for a whole Gyr (their footnote 3): the last
	# time they were farther.
	var merge := -1.0
	for k in range(hist[0].size() - 1000):
		var all_in := true
		for q in range(k, k + 1000):
			if float(hist[0][q]) > 5.0:
				all_in = false
				break
		if all_in:
			merge = float(k) / 1000.0
			break
	print("     MW–M31: pericentre %s kpc at %s Gyr (N-body 35.0 at 3.97), apocentre %s kpc at %s Gyr (171.9 at 4.79), merged by %s Gyr (6.29)" % [
		U.fixed(float(peri[1]), 1), U.fixed(float(peri[0]) / 1000.0, 2), U.fixed(float(apo[1]), 1), U.fixed(float(apo[0]) / 1000.0, 2), U.fixed(merge, 2)])
	print("     M33–M31: pericentre %s kpc at %s Gyr (their semi-analytic 80.3 at 0.93)" % [U.fixed(float(m33[1]), 1), U.fixed(float(m33[0]) / 1000.0, 3)])
	ok(absf(float(m33[1]) / 80.3 - 1.0) < 0.02 and absf(float(m33[0]) / 1000.0 - 0.93) < 0.03,
		"M33 passes M31 at %s kpc after %s Gyr, as van der Marel et al.'s semi-analytic orbit does (80.3 kpc, 0.93 Gyr)" % [U.fixed(float(m33[1]), 1), U.fixed(float(m33[0]) / 1000.0, 3)])
	# Against their N-body run the semi-analytic method is "adequate"; this bounds the gap.
	ok(absf(float(peri[0]) / 1000.0 - 3.97) < 0.3 and float(peri[1]) < 60.0 and merge > 5.5 and merge < 7.0,
		"M31 reaches the Milky Way at %s Gyr and merges by %s Gyr (their N-body run: 3.97, 6.29)" % [U.fixed(float(peri[0]) / 1000.0, 2), U.fixed(merge, 2)])
	# The system's centre drifts at its starting velocity, the friction and the unequal pulls
	# taken out.
	var drift := _centre(o).distance_to(cm0 + vcm * o.t)
	# Rounding over 10⁴ steps at positions of ~10³ kpc: within a parsec.
	ok(drift < 1e-3, "the system's mass centre moves uniformly over 10 Gyr (%s kpc off)" % U.expo(drift, 1))

## The Milky Way alone: in a rigid axisymmetric potential each star keeps its energy (to the
## leapfrog's bounded error) and its angular momentum about the spin (exactly, up to rounding),
## and the disc keeps its size.
func isolated() -> void:
	var o := GalOrbits.new()
	var row: Array = GalModels.VDM_CANONICAL[0]
	var st: Array = GalModels.VDM_STARS["Milky Way"]
	var halo := GalOrbits.hernquist_halo(float(row[1]) - float(st[0]) - float(st[2]), float(row[2]))
	o.add("Milky Way", float(halo[0]), float(halo[1]), Vector3.ZERO, Vector3.ZERO)
	var e := GalEncounter.new(o)
	e.set_galaxy(0, [halo[0], halo[1]], [st[0], 0.9688 * float(st[1]), 0.1 * float(st[1])], [st[2], float(st[3]) / 1.8153], Vector3(0, 0, -1))
	e.seed_disc(0, 1000, float(st[0]), float(st[1]), 0.3, 0.1, 7)
	var spin: Vector3 = (e.axes[0] as Basis).y
	var e0 := _star_energies(e)
	var l0 := _star_lz(e, spin)
	var r0 := _median_r(e)
	var r_min := PackedFloat64Array()
	r_min.resize(e.n)
	for i in e.n: r_min[i] = Vector3(e.pos[3 * i], e.pos[3 * i + 1], e.pos[3 * i + 2]).length()
	for k in 2000:
		e.step(1)
		for i in e.n: r_min[i] = minf(r_min[i], Vector3(e.pos[3 * i], e.pos[3 * i + 1], e.pos[3 * i + 2]).length())
	var e1 := _star_energies(e)
	var l1 := _star_lz(e, spin)
	var kept := []
	var dived := 0
	var dl := 0.0
	for i in e.n:
		dl = maxf(dl, absf(l1[i] - l0[i]) / absf(l0[i]))
		# Within 0.5 kpc a circular orbit takes fewer than ~30 steps of DT and the bulge's cusp
		# turns the force abruptly at its centre: a step errs there by more than 1e-3, and the
		# hot inner disc sends a few stars in.
		if r_min[i] < 0.5: dived += 1
		else: kept.append(absf(e1[i] / e0[i] - 1.0))
	kept.sort()
	var worst: float = kept[kept.size() - 1]
	var dr := absf(_median_r(e) / r0 - 1.0)
	ok(worst < 1e-3 and dl < 1e-9 and dr < 0.02 and dived < e.n / 10, "a lone Milky Way's stars keep their energy (worst %s, the %d of %d that dive within 0.5 kpc of the centre aside), all their angular momentum (%s), the disc its size (%s), over 1 Gyr" % [
		U.expo(worst, 1), dived, e.n, U.expo(dl, 1), U.expo(dr, 1)])

func _star_energies(e: GalEncounter) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	var P: Array = e.params[0]
	var B: Basis = e.axes[0]
	for i in e.n:
		var x := e.pos[3 * i]
		var y := e.pos[3 * i + 1]
		var z := e.pos[3 * i + 2]
		var r := sqrt(x * x + y * y + z * z)
		var phi := -float(P[0]) / (r + float(P[1])) - float(P[5]) / (r + float(P[6]))
		var ly := x * B.y.x + y * B.y.y + z * B.y.z
		var R2 := r * r - ly * ly
		var s := float(P[3]) + sqrt(ly * ly + float(P[4]) * float(P[4]))
		phi -= float(P[2]) / sqrt(R2 + s * s)
		var v2 := e.vel[3 * i] * e.vel[3 * i] + e.vel[3 * i + 1] * e.vel[3 * i + 1] + e.vel[3 * i + 2] * e.vel[3 * i + 2]
		out.append(0.5 * v2 + phi)
	return out

func _star_lz(e: GalEncounter, spin: Vector3) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for i in e.n:
		var x := e.pos[3 * i]
		var y := e.pos[3 * i + 1]
		var z := e.pos[3 * i + 2]
		var vx := e.vel[3 * i]
		var vy := e.vel[3 * i + 1]
		var vz := e.vel[3 * i + 2]
		out.append((y * vz - z * vy) * spin.x + (z * vx - x * vz) * spin.y + (x * vy - y * vx) * spin.z)
	return out

func _median_r(e: GalEncounter) -> float:
	var rs := []
	for i in e.n: rs.append(Vector3(e.pos[3 * i], e.pos[3 * i + 1], e.pos[3 * i + 2]).length())
	rs.sort()
	return rs[rs.size() / 2]

## The C kernel against the GDScript one through the canonical encounter: bit for bit, as both
## call only sqrt.
func parity() -> void:
	if not GalEncounter.native_available():
		ok(false, "the native encounter kernel is loaded")
		return
	var a := GalModels.vdm_encounter(0.008, 3)
	var b := GalModels.vdm_encounter(0.008, 3)
	b.use_native = false
	a.step(400)
	b.step(400)
	var same := a.pos == b.pos and a.vel == b.vel
	var worst := 0.0
	for i in a.pos.size(): worst = maxf(worst, absf(a.pos[i] - b.pos[i]))
	ok(same, "the native encounter kernel matches GDScript bit for bit over 200 Myr (worst %s kpc)" % U.expo(worst, 1))

func _centre(o: GalOrbits) -> Vector3:
	var c := Vector3.ZERO
	var m := 0.0
	for i in o.count():
		c += o.position(i) * o.gm[i]
		m += o.gm[i]
	return c / m

func _momentum(o: GalOrbits) -> Vector3:
	var p := Vector3.ZERO
	var m := 0.0
	for i in o.count():
		p += o.velocity(i) * o.gm[i]
		m += o.gm[i]
	return p / m

func _first_min(h: Array) -> Array:
	for k in range(1, h.size() - 1):
		if float(h[k]) < float(h[k - 1]) and float(h[k]) <= float(h[k + 1]): return [k + 1, h[k]]
	return [-1, INF]

func _next_max(h: Array, from: int) -> Array:
	for k in range(maxi(from, 1), h.size() - 1):
		if float(h[k]) > float(h[k - 1]) and float(h[k]) >= float(h[k + 1]): return [k + 1, h[k]]
	return [-1, 0.0]

## M33's spin is derived from its sky geometry (GalModels.disc_spin); the same derivation from
## M31's Table 1 geometry must land on the spin van der Marel et al. state for it.
func spins() -> void:
	var g: Dictionary = GalModels.LOCAL_GROUP["m31"]
	var derived := GalModels.disc_spin(float(g.ra), float(g.dec), 77.5, 37.5, "NW", "SW")
	var stated := GalModels.vdm_spin("M31")
	var ang := rad_to_deg(derived.angle_to(stated))
	# 2°: their inclination and PA come from Chemin et al. 2009 and Corbelli et al. 2010
	# at the precision Table 1 prints.
	ok(ang < 2.0, "M31's spin derived from its sky geometry is %s° from van der Marel et al.'s (−0.412, −0.767, −0.492)" % U.fixed(ang, 2))
	var m33 := GalModels.vdm_spin("M33")
	ok(absf(m33.length() - 1.0) < 1e-6, "M33's spin is a unit vector (%s, %s, %s)" % [U.fixed(m33.x, 3), U.fixed(m33.y, 3), U.fixed(m33.z, 3)])

## Every disc of the canonical encounter is stable to axisymmetric collapse where it has stars
## (Q > 1 from 0.5 to 6 R_d) and is Q_REF at the reference radius.
func discs() -> void:
	var e := GalModels.vdm_encounter(0.01, 1)
	for i in e.count():
		var d: Dictionary = e.discs[i]
		var rd := float(d.rd)
		var vc := func(R: float) -> float: return e.circular_speed(i, R)
		var qmin := INF
		var R := 0.5 * rd
		while R <= 6.0 * rd:
			qmin = minf(qmin, e.toomre_q(i, R, vc))
			R += 0.1 * rd
		var qref := e.toomre_q(i, GalEncounter.R_REF * rd, vc)
		ok(qmin > 1.0 and absf(qref / GalEncounter.Q_REF - 1.0) < 1e-3, "%s's disc: Q %s at the reference radius, at least %s from 0.5 to 6 R_d" % [
			e.orbits.names[i], U.fixed(qref, 3), U.fixed(qmin, 2)])

## The sampler on a lone Hernquist sphere: its f(E) has Hernquist's (1990, eq. 17) shape, its
## stars his dispersion (eq. 10) at each radius, and the whole is in virial equilibrium.
func eddington() -> void:
	var s := GalEddington.new(1.0, 1.0, 1000.0, [["hernquist", 1.0, 1.0]])
	var ratios := []
	for q: float in [0.1, 0.3, 0.5, 0.7, 0.9]:
		var x := sqrt(q)
		var fh := (3.0 * asin(x) + x * sqrt(1.0 - q) * (1.0 - 2.0 * q) * (8.0 * q * q - 8.0 * q - 3.0)) / pow(1.0 - q, 2.5)
		ratios.append(s.f_at(q) / fh)
	var spread: float = (float(ratios.max()) - float(ratios.min())) / float(ratios.max())
	ok(spread < 0.003, "Eddington's f(E) has Hernquist's closed form's shape to %s across binding energies 0.1–0.9" % U.expo(spread, 1))
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var n := 200000
	var r: Array = s.sample(rng, n)
	var pos: PackedFloat64Array = r[0]
	var vel: PackedFloat64Array = r[1]
	var worst := 0.0
	for b: float in [0.1, 0.3, 1.0, 3.0, 10.0]:
		var sum := 0.0
		var want := 0.0
		var cnt := 0
		for i in n:
			var x := Vector3(pos[3 * i], pos[3 * i + 1], pos[3 * i + 2]).length()
			if x > b * 0.8 and x < b * 1.25:
				sum += Vector3(vel[3 * i], vel[3 * i + 1], vel[3 * i + 2]).length_squared() / 3.0
				want += pow(GalOrbits.sigma(1.0, 1.0, x), 2.0)
				cnt += 1
		# His σ² averaged over the same stars, against their mean v²/3, in units of the
		# sampling noise: a Maxwellian's σ from N independent speeds errs by 0.41/√N, and the
		# mirrored pairs share a speed.
		var noise := 0.41 / sqrt(cnt / 2.0)
		worst = maxf(worst, absf(sqrt(sum / want) - 1.0) / noise)
	ok(worst < 4.0, "sampled stars have Hernquist's dispersion at 0.1–10 a (worst %s of the sampling noise)" % U.fixed(worst, 1))
	var L := GalLive.new(20000, 0, 1.0, 0.7)
	for i in 20000: L.set_particle(i, [pos[3 * i], pos[3 * i + 1], pos[3 * i + 2]], [vel[3 * i], vel[3 * i + 1], vel[3 * i + 2]], 1.0 / GalUnits.G / 20000.0, 0.01)
	var en := L.energy()
	var vir := -2.0 * float(en[0]) / float(en[1])
	# W of a whole Hernquist sphere is −G M²/(6a) (his eq. 14); the cut at 1000 a loses 0.2 %.
	var w := float(en[1]) * GalUnits.G / (-1.0 / 6.0)
	ok(absf(vir - 1.0) < 0.02 and absf(w - 1.0) < 0.02, "a sampled Hernquist sphere is in virial equilibrium (2K/|W| %s) with his W (%s of it)" % [U.fixed(vir, 3), U.fixed(w, 3)])

## The C tree against the GDScript one, bit for bit, and on one thread against all of them.
func live_parity() -> void:
	if not GalLive.native_available():
		ok(false, "the native live kernel is loaded")
		return
	var a := _small_live(1)
	var b := _small_live(1)
	var c := _small_live(1)
	b.use_native = false
	c.threads = 1
	a.step(3)
	b.step(3)
	c.step(3)
	var body := func(L: GalLive) -> PackedFloat64Array: return L.buf.slice(GalLive.HDR, GalLive.HDR + GalLive.STRIDE * L.n)
	ok(body.call(a) == body.call(b) and a.draw_bytes == b.draw_bytes, "the native live kernel matches GDScript bit for bit over 3 steps")
	ok(body.call(a) == body.call(c) and int(a.buf[GalLive.H_THREADS]) > 1, "it gives the same bits on one thread as on %d" % int(a.buf[GalLive.H_THREADS]))

func _small_live(seed: int) -> GalLive:
	var e := GalModels.vdm_encounter(0.01, seed)
	e.go_live()
	return e.live

## The tree's accelerations against direct summation, on the Milky Way's particles.
func live_accuracy() -> void:
	var e := GalEncounter.new(GalModels.encounter([GalModels.VDM_CANONICAL[0]]))
	GalModels.vdm_galaxy(e, 0, GalModels.VDM_CANONICAL[0], 0.05, 2)
	e.go_live()
	var L := e.live
	L.accelerate()
	var errs := []
	var g := L.buf[GalLive.H_G]
	for i in range(0, L.n, 7):
		var ai := Vector3(L.buf[GalLive.HDR + GalLive.STRIDE * i + 6], L.buf[GalLive.HDR + GalLive.STRIDE * i + 7], L.buf[GalLive.HDR + GalLive.STRIDE * i + 8])
		var d := Vector3.ZERO
		var pi := L.position(i)
		var ei := L.buf[GalLive.HDR + GalLive.STRIDE * i + GalLive.EPS]
		for j in L.n:
			if j == i: continue
			var dp := L.position(j) - pi
			var ej := L.buf[GalLive.HDR + GalLive.STRIDE * j + GalLive.EPS]
			var s := maxf(ei, ej)
			var r2 := dp.length_squared() + s * s
			d += dp * (g * L.mass(j) / (r2 * sqrt(r2)))
		errs.append((ai - d).length() / d.length())
	errs.sort()
	var med: float = errs[errs.size() / 2]
	var p99: float = errs[int(0.99 * errs.size())]
	# Monopole cells at θ 0.7: Barnes & Hut's tree errs by ~1 % typically.
	ok(med < 0.01 and p99 < 0.05, "the tree's accelerations against direct summation: median error %s, 99th percentile %s" % [(U.fixed(100.0 * med, 2) + " %"), (U.fixed(100.0 * p99, 1) + " %")])

## The Milky Way alone and live for 300 Myr: its energy kept, its halo where it was, its disc a
## disc.
func live_alone() -> void:
	var e := GalEncounter.new(GalModels.encounter([GalModels.VDM_CANONICAL[0]]))
	GalModels.vdm_galaxy(e, 0, GalModels.VDM_CANONICAL[0], 1.0, 1)
	e.go_live()
	var L := e.live
	var en0 := L.energy()
	var h0 := _halo_radii(e)
	var z0 := _disc_thickness(e)
	e.step(300)
	var en1 := L.energy()
	var de := absf((float(en1[0]) + float(en1[1])) / (float(en0[0]) + float(en0[1])) - 1.0)
	var h1 := _halo_radii(e)
	var z1 := _disc_thickness(e)
	ok(de < 3e-3, "a live Milky Way keeps its energy over 300 Myr (%s)" % U.expo(de, 1))
	ok(absf(h1[0] / h0[0] - 1.0) < 0.03 and absf(h1[1] / h0[1] - 1.0) < 0.02, "its halo stays put: 10 %% and half-mass radii %s → %s, %s → %s kpc" % [
		U.fixed(h0[0], 1), U.fixed(h1[0], 1), U.fixed(h0[1], 1), U.fixed(h1[1], 1)])
	ok(z1 < 2.0 * z0, "its disc stays thin: rms height at 6–10 kpc %s → %s kpc" % [U.fixed(z0, 3), U.fixed(z1, 3)])

func _halo_radii(e: GalEncounter) -> Array:
	var c := e.centre(0)
	var rs := []
	for j in range(e.n, e.live.n): rs.append(e.live.position(j).distance_to(c))
	rs.sort()
	return [rs[int(0.1 * rs.size())], rs[rs.size() / 2]]

func _disc_thickness(e: GalEncounter) -> float:
	var c := e.centre(0)
	var B: Basis = e.axes[0]
	var zz := 0.0
	var n := 0
	for j in e.n:
		if e.tag[j] != 0: continue
		var p := e.live.position(j) - c
		var R := (p - B.y * p.dot(B.y)).length()
		if R > 6.0 and R < 10.0:
			zz += pow(p.dot(B.y), 2.0)
			n += 1
	return sqrt(zz / n)

## Going live moves no star and keeps every galaxy's momentum: the stars are where they were
## and the haloes arrive moving with their galaxies.
func switch() -> void:
	var e := GalModels.vdm_encounter(0.05, 4)
	var before := e.pos.duplicate()
	var p0 := Vector3.ZERO
	var m0 := 0.0
	for i in e.count():
		var h: Array = e.haloes[i]
		var mi := float(h[2]) * (h[0] as PackedFloat64Array).size() / 3.0
		for j in e.n: if e.owner[j] == i: mi += e.star_mass[j]
		p0 += e.orbits.velocity(i) * mi
		m0 += mi
	e.go_live()
	var moved := 0.0
	for j in e.n: moved = maxf(moved, e.live.position(j).distance_to(Vector3(before[3 * j], before[3 * j + 1], before[3 * j + 2])))
	var p1 := Vector3.ZERO
	var m1 := 0.0
	for j in e.live.n:
		p1 += e.live.velocity(j) * e.live.mass(j)
		m1 += e.live.mass(j)
	# The haloes come in mirrored pairs and add nothing; the stars' dispersions average to
	# zero only to their noise, σ/√N: ~1 km/s for a few thousand.
	var dv := (p1 / m1 - p0 / m0).length() / GalUnits.KMS
	ok(moved == 0.0 and absf(m1 / m0 - 1.0) < 1e-9 and dv < 2.0, "going live moves no star (%s kpc) and keeps the mass and its mean motion (%s km/s)" % [U.expo(moved, 1), U.fixed(dv, 2)])
