extends SceneTree
# The galactic scene's physics (docs/physics/galaxies.md): the unit system against
# independent constants, MWPotential2014 against the derived values Bovy (2015)
# tabulates, force and density against the potential they must come from, the
# tracers' conservation in the static potential, and the rotation curve measured
# from them against the model's. Deterministic: fixed seeds, fixed steps.
# Godot --headless --path . --script res://tools/galaxycheck.gd [-- quick=1]

var checks := 0
var failures := 0
var quick := false

func ok(cond: bool, what: String) -> void:
	checks += 1
	if not cond: failures += 1
	print("%s %s" % ["ok  " if cond else "FAIL", what])

func near(v: float, want: float, tol: float, what: String) -> void:
	ok(is_finite(v) and absf(v - want) <= tol, "%s: %s (want %s ± %s)" % [what, _g(v), _g(want), _g(tol)])

static func _g(v: float) -> String:
	return U.expo(v, 5) if v != 0.0 and (absf(v) < 1e-3 or absf(v) >= 1e6) else String.num(v, 6)

func _init() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "quick=1": quick = true
	units()
	var mw := GalModels.milky_way_potential()
	ok(mw != null and mw.parts.size() == 3, "MWPotential2014 builds with three parts")
	if mw == null:
		_done()
		return
	bovy_table(mw)
	consistency(mw)
	colour(mw)
	if failures == 0:
		tracers()
	_done()

func _done() -> void:
	print("GALAXYCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)

# The unit system is Physics.G and the orrery year; check it against the
# conventional constants it must reproduce (IAU 2015 GM☉ and the parsec).
func units() -> void:
	# G in kpc (km/s)² / M☉ from GM☉ = 1.32712440018e20 m³/s² and 1 pc = 3.0856775814913673e16 m.
	var g_kms := GalUnits.G / (GalUnits.KMS * GalUnits.KMS) / GalUnits.MASS_UNIT_SUN
	near(g_kms / 4.300917e-6, 1.0, 2e-6, "G in kpc (km/s)²/M☉ against 4.300917e-6")
	near(GalUnits.KPC_M / 3.0856775814913673e19, 1.0, 1e-12, "kpc in m")
	# 1 km/s ≈ 1.0227 pc/Myr (with the orrery Myr, 1.7e-5 longer than a Julian one).
	near(GalUnits.KMS * 1000.0, 1.0227122 * (Rocketry.YR_S / 31557600.0), 1e-6, "km/s in pc/Myr")

# Bovy (2015) Table 1, third and second sections: values derived from the fitted
# potential, so they test this implementation of it, not the Milky Way.
func bovy_table(p: GalPotential) -> void:
	var g := GalUnits.G
	var kms := GalUnits.KMS
	near(GalUnits.kms(p.vc(8.0)), 220.0, 1e-9, "vc(R0)")
	near(GalPotential.gm_total(p.part("bulge")) / g, 0.5, 0.05, "bulge mass, 10¹⁰ M☉ (Table 1: 0.5)")
	near(p.part("disc").gm / g, 6.8, 0.05, "disc mass, 10¹⁰ M☉ (6.8)")
	# M(<60 kpc) as R vc²/G, the spherical estimate the constraint (Xue et al. 2008) is.
	near(60.0 * pow(p.vc(60.0), 2.0) / g / 10.0, 4.1, 0.05, "M(<60 kpc), 10¹¹ M☉ (4.1)")
	# Escape speed with Φ(∞) = 0.
	near(GalUnits.kms(sqrt(-2.0 * p.phi(8.0, 0.0, 0.0))), 513.0, 1.0, "vesc(R0), km/s (513)")
	var h := 1e-4
	var slope := (log(p.vc(8.0 * (1.0 + h))) - log(p.vc(8.0 * (1.0 - h)))) / (2.0 * h)
	near(slope, -0.10, 0.005, "dln vc/dln R at R0 (−0.10)")
	near(GalUnits.msun_pc3(p.density(8.0, 0.0)), 0.10, 0.005, "ρ(R0, 0), M☉/pc³ (0.10)")
	near(GalUnits.msun_pc3(GalPotential.density_of(p.part("halo"), 8.0, 0.0)), 0.008, 0.0005, "ρDM(R0), M☉/pc³ (0.008)")
	# Vertical force at 1.1 kpc in units of 2πG M☉ pc⁻².
	var fz := (p.phi(8.0, 1.1 + h, 0.0) - p.phi(8.0, 1.1 - h, 0.0)) / (2.0 * h)
	near(GalUnits.msun_pc2(fz / (TAU * g)), 72.0, 1.0, "Fz(R0, 1.1 kpc), 2πG M☉/pc² (72)")
	# NFW mass inside the tabulated virial radius, 245 kpc (concentration 15.3 = 245/16).
	near(GalPotential.gm_within(p.part("halo"), 245.0) / g / 100.0, 0.8, 0.05, "Mvir, 10¹² M☉ (0.8)")
	ok(kms > 0.0, "km/s conversion positive")

# Force is −∇Φ and density is ∇²Φ/4πG at scattered points, by central differences.
func consistency(p: GalPotential) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var pts := PackedFloat64Array()
	for i in 64:
		var R := rng.randf_range(0.3, 40.0)
		var ph := rng.randf() * TAU
		pts.append_array([R * cos(ph), rng.randf_range(-5.0, 5.0), R * sin(ph)])
	var acc := PackedFloat64Array()
	acc.resize(pts.size())
	p.accel_into(pts, acc, 64)
	var worst_f := 0.0
	var worst_rho := 0.0
	for i in 64:
		var x := pts[i * 3]; var y := pts[i * 3 + 1]; var z := pts[i * 3 + 2]
		var h := 1e-4 * maxf(sqrt(x * x + y * y + z * z), 0.1)
		var g := Vector3(
			(p.phi(x + h, y, z) - p.phi(x - h, y, z)) / (2.0 * h),
			(p.phi(x, y + h, z) - p.phi(x, y - h, z)) / (2.0 * h),
			(p.phi(x, y, z + h) - p.phi(x, y, z - h)) / (2.0 * h))
		var a := Vector3(acc[i * 3], acc[i * 3 + 1], acc[i * 3 + 2])
		var ef := (a + g).length() / g.length()
		worst_f = maxf(worst_f, ef)
		var lap := 0.0
		var c := p.phi(x, y, z)
		lap += (p.phi(x + h, y, z) - 2.0 * c + p.phi(x - h, y, z)) / (h * h)
		lap += (p.phi(x, y + h, z) - 2.0 * c + p.phi(x, y - h, z)) / (h * h)
		lap += (p.phi(x, y, z + h) - 2.0 * c + p.phi(x, y, z - h)) / (h * h)
		var R := sqrt(x * x + z * z)
		var rho := p.density(R, y)
		var er := absf(lap / (4.0 * PI * GalUnits.G) - rho) / rho
		worst_rho = maxf(worst_rho, er)
	ok(worst_f < 1e-5, "acceleration = −∇Φ at 64 points (worst %s)" % U.expo(worst_f, 2))
	ok(worst_rho < 1e-3, "density = ∇²Φ/4πG at 64 points (worst %s)" % U.expo(worst_rho, 2))

# The Milky Way's light: the disc's and bulge's populations weighted by their visible
# luminosity give an integrated colour to set beside the measured one, Licquia,
# Newman & Brinchmann (2015): rest-frame B−V = 0.744 +0.068 −0.054. Never tuned to it.
func colour(p: GalPotential) -> void:
	var disc := GalPopulation.build({"kind": "constant", "gyr": 10.0})
	var bulge := GalPopulation.build({"kind": "burst", "gyr": 10.0})
	var g := GalUnits.G
	var ld: float = GalModels.VISIBLE_DISC * p.part("disc").gm / g * disc.mean_l / disc.mean_mass
	var lb: float = GalModels.VISIBLE_BULGE * GalPotential.gm_total(p.part("bulge")) / g * bulge.mean_l / bulge.mean_mass
	var c := (disc.color * ld + bulge.color * lb) / (ld + lb)
	var bv := GalPopulation.bv_of(c)
	print("     disc B−V %s, bulge %s, Galaxy %s; bulge %s %% of the light" % [String.num(GalPopulation.bv_of(disc.color), 3),
		String.num(GalPopulation.bv_of(bulge.color), 3), String.num(bv, 3), String.num(100.0 * lb / (ld + lb), 1)])
	ok(GalPopulation.bv_of(GalPopulation.visible(5772.0)) > 0.55 and GalPopulation.bv_of(GalPopulation.visible(5772.0)) < 0.75, "a 5772 K blackbody reads as the Sun's B−V ≈ 0.65 (%s)" % String.num(GalPopulation.bv_of(GalPopulation.visible(5772.0)), 3))
	ok(bv > 0.744 - 2.0 * 0.054 and bv < 0.744 + 2.0 * 0.068, "integrated B−V %s within 2σ of Licquia et al. (2015), 0.744 +0.068 −0.054" % String.num(bv, 3))
	# The quantile table the star shader draws masses from, integrated over the drawn
	# fraction u in z = −log10(1 − u), which reaches its top decades (the shader's
	# 24-bit u stops at 1 − 6e-8; the last 1e-7 is held at the top entry).
	for pp in [["disc", disc], ["bulge", bulge]]:
		var pop: GalPopulation = pp[1]
		var steps := 40000
		var zmax := GalPopulation.Q_DECADES
		var sl := 0.0
		var ob := 0.0
		for i in steps:
			var z := (float(i) + 0.5) / float(steps) * zmax
			var u := 1.0 - pow(10.0, -z)
			var du := log(10.0) * (1.0 - u) * zmax / float(steps)
			var m := pow(10.0, pop.quantile_lm(u))
			sl += Stellar.luminosity(m) * du
			if m >= 8.0: ob += du
		var top := pow(10.0, pop.quantiles[64])
		sl += Stellar.luminosity(top) * pow(10.0, -zmax)
		if top >= 8.0: ob += pow(10.0, -zmax)
		var ratio := sl / pop.resolved_mean_l
		ok(absf(ratio - 1.0) < 0.03, "%s: the drawn stars' mean L is %s of the population's (1 ± 0.03)" % [pp[0], String.num(ratio, 4)])
		var obr := ob / maxf(pop.resolved_ob, 1e-30)
		ok((pop.resolved_ob == 0.0 and ob == 0.0) or absf(obr - 1.0) < 0.05, "%s: stars above 8 M☉ drawn at %s of their share %s (1 ± 0.05)" % [pp[0], String.num(obr, 3), U.expo(pop.resolved_ob, 2)])
	luminosity_function(p, disc)
	ok(disc.post_ms_light > 0.3 and bulge.post_ms_light > disc.post_ms_light, "giants: %s %% of the disc's light, %s %% of the old bulge's" % [String.num(100.0 * disc.post_ms_light, 0), String.num(100.0 * bulge.post_ms_light, 0)])

# Main-sequence stars per magnitude at the Sun against Bovy (2017, MNRAS 470, 1360)
# Table 1, measured with Gaia TGAS and 2MASS: dn/dM_V per subtype, averaged over the
# subtypes whose M_V falls in each bin (10⁻⁴ pc⁻³ mag⁻¹). Not fitted; the bounds pin
# the measured differences, which docs/physics/galaxies.md reports.
const BOVY_2017_DN_DMV := {1: 3.8, 2: 5.4, 3: 9.9, 4: 22.6, 5: 24.8, 6: 24.3}

func luminosity_function(p: GalPotential, pop: GalPopulation) -> void:
	var d: Dictionary = p.part("disc")
	# The model disc's mass density at the Sun (M☉ pc⁻³), and its main-sequence stars.
	var rho := GalPotential.density_of(d, 8.0, 0.0208) * GalUnits.MASS_UNIT_SUN * 1e-9
	var n_ms := GalModels.VISIBLE_DISC * rho / pop.mean_mass
	var bins := {}
	var tot := 0.0
	var dl := (GalPopulation.LM_MAX - GalPopulation.LM_MIN) / 2400.0
	for i in 2400:
		var mm := pow(10.0, GalPopulation.LM_MIN + (float(i) + 0.5) * dl)
		var L := Stellar.luminosity(mm)
		var w := mm * GalPopulation._imf(mm) * minf(1.0, Structure.main_sequence_lifetime(mm, L) / 1e10) * dl
		tot += w
		var c := GalPopulation.visible(Stellar.effective_temp(mm))
		var mv := 4.83 - 2.5 * log(L * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)) / log(10.0)
		var b := int(floor(mv))
		bins[b] = float(bins.get(b, 0.0)) + w
	var line := ""
	var ratios := {}
	for b in BOVY_2017_DN_DMV:
		var model := float(bins.get(b, 0.0)) / tot * n_ms * 1e4
		ratios[b] = model / float(BOVY_2017_DN_DMV[b])
		line += "  M_V %d–%d: %s" % [b, b + 1, String.num(ratios[b], 2)]
	print("     model / Bovy (2017) stars per magnitude:" + line)
	ok(ratios[2] > 0.75 and ratios[2] < 1.33 and ratios[1] > 0.35 and ratios[1] < 1.0,
		"A and early-F dwarfs: model %s and %s of Gaia's counts (A0–A5 0.35–1, A6–F1 0.75–1.33)" % [String.num(ratios[1], 2), String.num(ratios[2], 2)])
	ok(ratios[5] > 1.5 and ratios[5] < 3.5 and ratios[6] > 1.5 and ratios[6] < 4.0,
		"G and K dwarfs: model %s and %s of Gaia's counts, the known excess (1.5–3.5, 1.5–4)" % [String.num(ratios[5], 2), String.num(ratios[6], 2)])

# A Myr-scale run of the Milky Way's tracers: deterministic, conservative, and in a
# steady state whose rotation curve is the model's.
func tracers() -> void:
	var t_run := 300.0 if quick else 1000.0
	var model := GalModels.build("milky_way", 1)
	var tr := GalTracers.new(model)
	var again := GalTracers.new(GalModels.build("milky_way", 1))
	ok(tr.n == 6000 and tr.pos == again.pos and tr.vel == again.vel, "same seed, same %d tracers" % tr.n)
	var other := GalTracers.new(GalModels.build("milky_way", 2))
	ok(other.pos != tr.pos, "another seed, other tracers")
	var p: GalPotential = model.potential
	var gi := tr.population_index("gas")
	var si := tr.population_index("thin disc")
	var lz0 := PackedFloat64Array()
	for i in tr.n: lz0.append(tr.lz(i))
	var gas0 := GalCurve.measure(tr, gi, 3.0, 25.0)
	var wide0 := _wide(tr, si)
	tr.step(int(round(t_run / GalTracers.DT)))
	ok(absf(tr.t - t_run) < 1e-9, "integrated %s Myr in %d steps" % [String.num(tr.t, 1), tr.steps])
	var de := tr.energy_drift()
	ok(de < 2e-5, "worst tracer |ΔE/E| over the run %s < 2e-5" % U.expo(de, 2))
	var worst_l := 0.0
	for i in tr.n: worst_l = maxf(worst_l, absf(tr.lz(i) - lz0[i]) / absf(lz0[i]))
	ok(worst_l < 1e-10, "worst tracer |ΔLz/Lz| %s < 1e-10 (no azimuthal force)" % U.expo(worst_l, 2))
	var gas1 := GalCurve.measure(tr, gi, 3.0, 25.0)
	for pair in [["t = 0", gas0], ["t = %s Myr" % String.num(t_run, 0), gas1]]:
		var m: Dictionary = pair[1]
		var worst := 0.0
		var bins := 0
		for i in m.R.size():
			var want := GalUnits.kms(p.vc(m.R[i]))
			var dev: float = absf(m.v[i] - want) / maxf(m.err[i], 0.5)
			worst = maxf(worst, dev)
			bins += 1
		ok(bins >= 18 and worst < 3.5, "cold gas: measured curve = model vc in %d bins at %s (worst %s σ)" % [bins, pair[0], String.num(worst, 2)])
	var wide1 := _wide(tr, si)
	for i in wide0.size():
		var a: Array = wide0[i]
		var b: Array = wide1[i]
		var sig := sqrt(a[2] * a[2] + b[2] * b[2])
		ok(absf(b[1] - a[1]) <= 3.0 * sig + 0.5, "thin disc %s–%s kpc: mean vφ steady, %s → %s km/s (±%s)" % [
			String.num(a[0] - 1.0, 0), String.num(a[0] + 1.0, 0), String.num(a[1], 1), String.num(b[1], 1), String.num(sig, 1)])
	# The stars lag the circular speed (asymmetric drift), and the Jeans equation as
	# Eilers et al. applied it gets the circular speed back.
	var st := GalCurve.measure(tr, si, 6.0, 18.0)
	var jv := GalCurve.jeans_vc(st)
	var lag := 0.0
	var worst_j := 0.0
	for i in st.R.size():
		var want := GalUnits.kms(p.vc(st.R[i]))
		if st.R[i] > 8.0 and st.R[i] < 9.0: lag = want - st.v[i]
		worst_j = maxf(worst_j, absf(jv[i] - want))
	ok(lag > 8.0 and lag < 35.0, "asymmetric drift at R0: stars lag vc by %s km/s" % String.num(lag, 1))
	ok(st.R.size() >= 10 and worst_j < 8.0, "Jeans-corrected stellar curve within %s km/s of vc over 6–18 kpc" % String.num(worst_j, 1))
	eilers(p)

# Mean vφ of the thin disc in 2 kpc rings: [centre, mean, standard error] (km/s).
func _wide(tr: GalTracers, si: int) -> Array:
	var out := []
	for c in [7.0, 9.0, 11.0, 13.0, 15.0]:
		var s1 := 0.0
		var s2 := 0.0
		var k := 0
		for i in tr.n:
			if tr.pop[i] != si: continue
			var x := tr.pos[i * 3]
			var z := tr.pos[i * 3 + 2]
			var R := sqrt(x * x + z * z)
			if absf(R - c) > 1.0: continue
			var v := GalUnits.kms((x * tr.vel[i * 3 + 2] - z * tr.vel[i * 3]) / R * tr.sense)
			s1 += v
			s2 += v * v
			k += 1
		var m := s1 / float(k)
		out.append([c, m, sqrt(maxf(s2 / float(k) - m * m, 0.0) / float(k - 1))])
	return out

# The model against the curve Eilers et al. (2019) measured, which it was not fitted
# to. MWPotential2014 has vc(8 kpc) = 220 km/s by construction; they find 229 at
# 8.122 kpc, and the gap widens to ~7 % near 17 kpc. The bounds pin that measured
# offset so a change to the potential shows up here; they are not a fit.
func eilers(p: GalPotential) -> void:
	var worst := 0.0
	var mean := 0.0
	var k := 0
	for row in GalCurve.EILERS_2019:
		var R: float = row[0]
		if R > 21.0: continue
		var d := GalUnits.kms(p.vc(R)) - float(row[1])
		worst = maxf(worst, absf(d))
		mean += d
		k += 1
	mean /= float(k)
	print("     MWPotential2014 − Eilers et al. (2019) over 5–21 kpc: mean %s, worst %s km/s" % [String.num(mean, 1), String.num(worst, 1)])
	ok(mean > -14.0 and mean < -6.0 and worst < 18.0, "model below the Gaia/APOGEE curve by %s km/s on average (6–14), worst %s (< 18)" % [String.num(-mean, 1), String.num(worst, 1)])
