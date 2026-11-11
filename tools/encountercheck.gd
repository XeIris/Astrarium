extends SceneTree
# Galaxy encounters (sim/galaxy/gal_orbits.gd): van der Marel et al.'s (2012b) semi-analytic
# orbits against what they published, and the integrator against Kepler.

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
	e.seed_disc(0, 1000, float(st[1]), 0.3, 0.05, 7)
	var spin: Vector3 = (e.axes[0] as Basis).y
	var e0 := _star_energies(e)
	var l0 := _star_lz(e, spin)
	var r0 := _median_r(e)
	e.step(2000)
	var e1 := _star_energies(e)
	var l1 := _star_lz(e, spin)
	var de := 0.0
	var dl := 0.0
	for i in e.n:
		de = maxf(de, absf(e1[i] / e0[i] - 1.0))
		dl = maxf(dl, absf(l1[i] - l0[i]) / absf(l0[i]))
	var dr := absf(_median_r(e) / r0 - 1.0)
	ok(de < 1e-3 and dl < 1e-9 and dr < 0.02, "a lone Milky Way's stars keep their energy (%s), angular momentum (%s) and the disc its size (%s) over 1 Gyr" % [
		U.expo(de, 1), U.expo(dl, 1), U.expo(dr, 1)])

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
	var a := GalModels.vdm_encounter(150, 3)
	var b := GalModels.vdm_encounter(150, 3)
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
