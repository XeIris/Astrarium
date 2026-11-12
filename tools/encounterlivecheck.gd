extends SceneTree
# The Milky Way, M31 and M33 run as the scene runs them (GalModels.vdm_encounter: restricted,
# then live from VDM_LIVE_AT) for 10 Gyr, against van der Marel et al.'s (2012b) N-body run of
# the same start: M31's first pericentre (35.0 kpc at 3.97 Gyr, §3.3), the merger (6.29 Gyr, by
# their footnote 3's rule) and the remnant's projected profile at 10 Gyr (their Fig. 7, read off
# at R^1/4 = 1.0, 1.5, 2.0, 2.38: log Σ 3.6, 2.5, 1.6, 0.8 M☉ pc⁻²). ~6 minutes on an M5.

var checks := 0
var failures := 0

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond: failures += 1
	print(("ok   " if cond else "FAIL ") + what)

func _init() -> void:
	var e := GalModels.vdm_encounter(1.0, 1)
	var sep := PackedFloat64Array()
	var m33_mw := PackedFloat64Array()
	var t_live := -1.0
	# Separations every 10 Myr.
	while e.time() < 10000.0 - 1e-6:
		e.step(int(round(10.0 / e.dt())))
		if t_live < 0.0 and e.is_live(): t_live = e.time()
		sep.append(e.centre(0).distance_to(e.centre(1)))
		m33_mw.append(e.centre(0).distance_to(e.centre(2)))
	if not e.is_live():
		ok(false, "the encounter went live")
		_finish()
		return
	print("     live from %s Gyr with %d particles" % [U.fixed(t_live / 1000.0, 2), e.live.n])
	var peri := _first_min(sep)
	var apo := _next_max(sep, int(peri[0]))
	var merge := -1.0
	for k in range(sep.size() - 100):
		var inside := true
		for q in range(k, k + 100):
			if sep[q] > 5.0:
				inside = false
				break
		if inside:
			merge = (k + 1) * 0.01
			break
	var m33 := _first_min(m33_mw)
	# Their N-body pericentre; the time lags by the semi-analytic orbit's, which runs until the
	# switch (encountercheck: 4.14 Gyr).
	ok(absf(float(peri[1]) / 35.0 - 1.0) < 0.15 and absf(float(peri[0]) * 0.01 - 3.97) < 0.3,
		"M31's first pericentre: %s kpc at %s Gyr (their N-body 35.0 at 3.97)" % [U.fixed(float(peri[1]), 1), U.fixed(float(peri[0]) * 0.01, 2)])
	ok(merge > 0.0 and absf(merge - 6.29) < 0.5, "the galaxies merge by %s Gyr (theirs 6.29)" % U.fixed(merge, 2))
	# Not judged: M33's orbit is semi-analytic until the switch, which van der Marel et al.
	# found inadequate for it (their App. A); here it passes the Milky Way far closer than in
	# their N-body run, which takes energy from M31's orbit. docs/physics/galaxies.md#live.
	print("     M31's first apocentre %s kpc at %s Gyr (theirs 171.9 at 4.79); M33's closest to the Milky Way before 4.5 Gyr %s kpc at %s Gyr (theirs 97.3 at 3.83)" % [
		U.fixed(float(apo[1]), 1), U.fixed(float(apo[0]) * 0.01, 2), U.fixed(float(m33[1]), 1), U.fixed(float(m33[0]) * 0.01, 2)])
	_remnant(e)
	_finish()

## The MW and M31 stars' surface density projected on the Galactocentric (X, Y) plane about
## their densest point, against their Fig. 7.
func _remnant(e: GalEncounter) -> void:
	var xs := []
	var ms := PackedFloat64Array()
	for j in e.n:
		if e.tag[j] % GalEncounter.BULGE_TAG > 1: continue
		xs.append(e.live.position(j))
		ms.append(e.star_mass[j] * GalUnits.MASS_UNIT_SUN)
	var c := Vector3.ZERO
	for p in xs: c += p
	c /= xs.size()
	var r := 50.0
	while r > 0.5:
		var s := Vector3.ZERO
		var n := 0
		for p in xs:
			if (p as Vector3).distance_to(c) < r:
				s += p
				n += 1
		c = s / n
		r *= 0.8
	var worst := 0.0
	var rows := []
	for ref in [[1.0, 3.6], [1.5, 2.5], [2.0, 1.6], [2.38, 0.8]]:
		var q: float = ref[0]
		var lo := pow(q - 0.05, 4.0)
		var hi := pow(q + 0.05, 4.0)
		var m := 0.0
		for k in xs.size():
			var p: Vector3 = xs[k]
			var R := Vector2(p.x - c.x, p.y - c.y).length()
			if R >= lo and R < hi: m += ms[k]
		var lg := log(maxf(m, 1.0) / (PI * (hi * hi - lo * lo) * 1e6)) / log(10.0)
		worst = maxf(worst, absf(lg - float(ref[1])))
		rows.append("%s: %s (%s)" % [U.fixed(q, 2), U.fixed(lg, 2), U.fixed(float(ref[1]), 1)])
	# 0.15 dex: reading their curve off the figure is good to about ±0.05.
	ok(worst < 0.15, "the remnant's log Σ at R^1/4 %s follows their Fig. 7 to %s dex" % [", ".join(rows), U.fixed(worst, 2)])

func _first_min(h: PackedFloat64Array) -> Array:
	for k in range(1, h.size() - 1):
		if h[k] < h[k - 1] and h[k] <= h[k + 1]: return [k + 1, h[k]]
	return [-1, INF]

func _next_max(h: PackedFloat64Array, from: int) -> Array:
	for k in range(maxi(from, 1), h.size() - 1):
		if h[k] > h[k - 1] and h[k] >= h[k + 1]: return [k + 1, h[k]]
	return [-1, 0.0]

func _finish() -> void:
	print("ENCOUNTERLIVECHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
