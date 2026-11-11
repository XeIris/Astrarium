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
		patterns()
		light()
		neighbourhood()
		landmarks()
		neighbours()
		types()
	_done()

func _done() -> void:
	print("GALAXYCHECK DONE checks=%d failures=%d native=%s" % [checks, failures, str(GalTracers.native_available())])
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
		var gx := (p.phi(x + h, y, z) - p.phi(x - h, y, z)) / (2.0 * h)
		var gy := (p.phi(x, y + h, z) - p.phi(x, y - h, z)) / (2.0 * h)
		var gz := (p.phi(x, y, z + h) - p.phi(x, y, z - h)) / (2.0 * h)
		var ex := acc[i * 3] + gx
		var ey := acc[i * 3 + 1] + gy
		var ez := acc[i * 3 + 2] + gz
		var ef := sqrt(ex * ex + ey * ey + ez * ez) / sqrt(gx * gx + gy * gy + gz * gz)
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
## The libm functions the tracer kernel calls whose results the native library and the
## engine disagree on, at 64 fixed arguments each in the ranges the kernel uses.
func libm_differences() -> PackedStringArray:
	var names := ["sin", "cos", "tan", "exp", "log", "atan2", "tanh", "pow", "sqrt"]
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026
	var buf := PackedFloat64Array([0.0])
	var want := PackedFloat64Array()
	for f in names.size():
		for k in 64:
			var x := rng.randf_range(-10.0, 10.0)
			var y := rng.randf_range(-10.0, 10.0)
			var r := 0.0
			match f:
				0: r = sin(x)
				1: r = cos(x)
				2: r = tan(x)
				3:
					x = rng.randf_range(-50.0, 5.0)
					r = exp(x)
				4:
					x = rng.randf_range(1e-6, 100.0)
					r = log(x)
				5: r = atan2(x, y)
				6: r = tanh(x)
				7:
					x = rng.randf_range(1e-3, 10.0)
					y = rng.randf_range(-6.0, 6.0)
					r = pow(x, y)
				8:
					x = absf(x) * 10.0
					r = sqrt(x)
			buf.append_array([float(f), x, y, 0.0])
			want.append(r)
	buf[0] = float(buf.size())
	var got: PackedFloat64Array = ClassDB.class_call_static("NBodyKernel", "libm", buf)
	var out := PackedStringArray()
	for f in names.size():
		for k in 64:
			var j := f * 64 + k
			if got.size() != buf.size() or got[1 + 4 * j + 3] != want[j]:
				out.append(names[f])
				break
	return out

func colour(p: GalPotential) -> void:
	# The model's three populations: the disc's stars aged 0.1–10 Gyr, the arms' younger
	# ones at the measured star formation rate, and the old bulge. Unreddened: the
	# measurement is corrected for the Milky Way's own dust.
	var disc := GalPopulation.build({"kind": "constant", "gyr": 10.0, "fromGyr": GalModels.MW_YOUNG_GYR})
	var young := GalPopulation.build({"kind": "constant", "gyr": GalModels.MW_YOUNG_GYR})
	var bulge := GalPopulation.build({"kind": "burst", "gyr": 10.0})
	var g := GalUnits.G
	var ld: float = GalModels.VISIBLE_DISC * p.part("disc").gm / g * GalUnits.MASS_UNIT_SUN * disc.mean_l / disc.mean_mass
	var ly: float = GalModels.MW_SFR * GalModels.MW_YOUNG_GYR * 1e9 * young.light_per_formed
	var lb: float = GalModels.VISIBLE_BULGE * GalPotential.gm_total(p.part("bulge")) / g * GalUnits.MASS_UNIT_SUN * bulge.mean_l / bulge.mean_mass
	var c := (disc.color * ld + young.color * ly + bulge.color * lb) / (ld + ly + lb)
	var bv := GalPopulation.bv_of(c)
	print("     disc B−V %s, young %s, bulge %s, Galaxy %s; young %s %%, bulge %s %% of the bolometric light" % [
		String.num(GalPopulation.bv_of(disc.color), 3), String.num(GalPopulation.bv_of(young.color), 3),
		String.num(GalPopulation.bv_of(bulge.color), 3), String.num(bv, 3), String.num(100.0 * ly / (ld + ly + lb), 1),
		String.num(100.0 * lb / (ld + ly + lb), 1)])
	ok(GalPopulation.bv_of(GalPopulation.visible(5772.0)) > 0.55 and GalPopulation.bv_of(GalPopulation.visible(5772.0)) < 0.75, "a 5772 K blackbody reads as the Sun's B−V ≈ 0.65 (%s)" % String.num(GalPopulation.bv_of(GalPopulation.visible(5772.0)), 3))
	ok(bv > 0.744 - 2.0 * 0.054 and bv < 0.744 + 2.0 * 0.068, "integrated B−V %s within 2σ of Licquia et al. (2015), 0.744 +0.068 −0.054" % String.num(bv, 3))
	# Pins, not measurements: today's colour of each population, so that a change to
	# how stars' colours mix shows even where the integrated colour stays within 2σ.
	# The young population's 0.30 is known to be too red (docs/physics/galaxies.md).
	var pins := {"disc": [disc, 0.806], "young": [young, 0.304], "bulge": [bulge, 0.990]}
	var worst := 0.0
	for k in pins: worst = maxf(worst, absf(GalPopulation.bv_of(pins[k][0].color) - float(pins[k][1])))
	ok(worst < 0.02, "each population's B−V within 0.02 of its pinned value (worst %s)" % String.num(worst, 3))
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
## Native against GDScript where their libms differ: kpc, (kpc/Myr)/0.2 and relative work.
## Real stars within 40 pc against the model's resolved ones: number and visible light
## (galaxycheck's neighbourhood(); a comparison pinned so a change shows, not a fit).
## The neighbours' absolute V from their stellar masses against McConnachie (2012): the
## LMC's and M33's come out 0.8–0.9 mag bright (their literature masses imply M/L_V ≈ 1.8,
## the population model's is ≈ 0.8); a pin that a change shows, not a fit.
const NEIGHBOUR_MV_TOL := 1.0
const NEAR_COUNT_PIN := 0.61
const NEAR_LIGHT_PIN := 2.25
const PARITY_TOL := 1e-9
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
	var model := GalModels.build("milky_way", 1, false)
	var tr := GalTracers.new(model)
	var again := GalTracers.new(GalModels.build("milky_way", 1, false))
	ok(tr.n == 6000 and tr.pos == again.pos and tr.vel == again.vel, "same seed, same %d tracers" % tr.n)
	var other := GalTracers.new(GalModels.build("milky_way", 2, false))
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

# The bar and the spiral (GalPattern): force and ∂Φ/∂t from the potential, the native
# kernel bit for bit against the GDScript one, E − W through their growth, and the
# Jacobi integral E − Ωb Lz with the bar alone, which does not use the work tally.
func patterns() -> void:
	var pats := GalModels.mw_patterns()
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for p in pats:
		var worst_f := 0.0
		var worst_t := 0.0
		for i in 200:
			var R := rng.randf_range(0.3, 20.0)
			var ph := rng.randf() * TAU
			var x := R * cos(ph)
			var z := R * sin(ph)
			var y := rng.randf_range(-1.0, 1.0)
			var t := rng.randf_range(GalModels.MW_T_START - 20.0, 200.0)
			var out := PackedFloat64Array([0.0, 0.0, 0.0])
			GalPattern.add_accel(p, x, y, z, t, out, 0)
			var h := 1e-5 * maxf(R, 0.5)
			var gx := (GalPattern.phi(p, x + h, y, z, t) - GalPattern.phi(p, x - h, y, z, t)) / (2.0 * h)
			var gy := (GalPattern.phi(p, x, y + h, z, t) - GalPattern.phi(p, x, y - h, z, t)) / (2.0 * h)
			var gz := (GalPattern.phi(p, x, y, z + h, t) - GalPattern.phi(p, x, y, z - h, t)) / (2.0 * h)
			var gn := sqrt(gx * gx + gy * gy + gz * gz)
			if gn > 0.0:
				var ex := out[0] + gx
				var ey := out[1] + gy
				var ez := out[2] + gz
				worst_f = maxf(worst_f, sqrt(ex * ex + ey * ey + ez * ez) / gn)
			var fd := (GalPattern.phi(p, x, y, z, t + 1e-3) - GalPattern.phi(p, x, y, z, t - 1e-3)) / 2e-3
			if absf(fd) > 1e-12:
				worst_t = maxf(worst_t, absf(GalPattern.dphi_dt(p, x, y, z, t) - fd) / absf(fd))
		var name := "bar" if p.kind == GalPattern.Kind.BAR else "spiral"
		ok(worst_f < 1e-5, "%s: acceleration = −∇Φ at 200 points and times (worst %s)" % [name, U.expo(worst_f, 2)])
		ok(worst_t < 1e-4, "%s: ∂Φ/∂t against a finite difference (worst %s)" % [name, U.expo(worst_t, 2)])
	# The spiral's potential minimum (its stellar crest) on each ring today: on Perseus
	# where Reid et al. measured it, and falling behind the rotation outward (trailing).
	var sp: Dictionary = pats[1]
	var crest := func(R: float) -> float:
		var best := INF
		var at := 0.0
		for k in 7200:
			var ph := TAU * float(k) / 7200.0
			var v := GalPattern.phi(sp, R * cos(ph), 0.0, R * sin(ph), 0.0)
			if v < best:
				best = v
				at = ph
		return at
	var want := PI + deg_to_rad(float(GalModels.MW_SPIRAL_ANCHOR[1]))
	var off := absf(wrapf(crest.call(float(GalModels.MW_SPIRAL_ANCHOR[0])) - want, -PI / 2.0, PI / 2.0))
	ok(off < deg_to_rad(0.2), "spiral crest on Perseus (8.87 kpc, β = 40°) today, within %s°" % String.num(rad_to_deg(off), 2))
	# Two arms repeat every 180°, so the step is kept short: −ln(7.5/7)/tan 12° = −18.6°.
	var drift := wrapf(crest.call(7.5) - crest.call(7.0), -PI / 2.0, PI / 2.0)
	ok(drift < 0.0 and absf(rad_to_deg(drift) + 18.6) < 0.3, "the arms trail: the crest falls %s° behind the rotation from 7 to 7.5 kpc (−18.6°)" % String.num(rad_to_deg(drift), 1))
	var model := GalModels.build("milky_way", 3)
	var a := GalTracers.new(model)
	if GalTracers.native_available():
		var b := GalTracers.new(GalModels.build("milky_way", 3))
		b.use_native = false
		# Compared every step: an ulp in the work tally can round away again later. Bit
		# identity needs the library and the engine to share a libm; where they do not
		# (MinGW's on Windows), they must agree to PARITY_TOL instead.
		var differ := libm_differences()
		var first := -1
		var worst := 0.0
		for s in 300:
			a.step(1)
			b.step(1)
			if not (a.pos == b.pos and a.vel == b.vel and a.work == b.work):
				if first < 0: first = s
				for i in a.n:
					for c in 3:
						worst = maxf(worst, absf(a.pos[3 * i + c] - b.pos[3 * i + c]))
						worst = maxf(worst, absf(a.vel[3 * i + c] - b.vel[3 * i + c]) / 0.2)
					worst = maxf(worst, absf((a.work[i] - b.work[i]) / a.e0[i]))
		if differ.is_empty():
			ok(first < 0, "native and GDScript tracer kernels bit-identical at every step of 300 with the bar and spiral%s" % ("" if first < 0 else " (first differs at step %d)" % first))
		else:
			ok(worst < PARITY_TOL, "native and GDScript tracer kernels agree to %s over 300 steps (< %s); not bit for bit, as the library's libm differs from the engine's in %s" % [
				U.expo(worst, 2), U.expo(PARITY_TOL, 0), ", ".join(differ)])
	else:
		print("     native kernel unavailable: the GDScript kernel alone runs")
	a.step(int(round((0.0 - a.t) / GalTracers.DT)) + (500 if not quick else 0))
	var dw := a.energy_drift()
	ok(dw < 2e-5, "with the bar and spiral grown in: worst |Δ(E − W)/E| %s < 2e-5 at t = %s Myr" % [U.expo(dw, 2), String.num(a.t, 0)])
	var moved := 0.0
	for i in a.n: moved = maxf(moved, absf(a.work[i] / a.e0[i]))
	ok(moved > 1e-3, "and the patterns do work on the tracers (largest |W/E| %s)" % U.expo(moved, 2))
	# Bar alone, fully grown from the start: E − Ωb Lz is conserved in its frame.
	var bar: Dictionary = GalModels.mw_patterns()[0].duplicate()
	bar.tForm = -1e9
	var m2 := GalModels.build("milky_way", 4, false)
	m2.patterns = [bar]
	var c := GalTracers.new(m2)
	var j0 := PackedFloat64Array()
	for i in c.n: j0.append(c.e0[i] - float(bar.omega) * c.lz(i))
	c.step(1000 if quick else 3000)
	var e1 := c.energies()
	var worst_j := 0.0
	for i in c.n: worst_j = maxf(worst_j, absf((e1[i] - float(bar.omega) * c.lz(i) - j0[i]) / j0[i]))
	ok(worst_j < 2e-5, "bar alone: worst |ΔE_J/E_J| %s < 2e-5 over %s Myr" % [U.expo(worst_j, 2), String.num(c.t, 0)])

# The light and dust the arms and bar add (GalaxyVisual's CPU copy of the shaders):
# the young stars' total against the star formation rate that sets it, and the
# extinction from the Sun to the Galactic centre against Fritz et al. (2011), who
# measure A_Ks = 2.42 ± 0.10 toward Sgr A*: A_V ≈ 21.6 with Rieke & Lebofsky's
# A_K/A_V = 0.112, the law the dust model uses. Not fitted.
func light() -> void:
	var v := GalaxyVisual.new(GalModels.build("milky_way", 1))
	v._turn_patterns(0.0)
	var want := GalModels.MW_SFR * GalModels.MW_YOUNG_GYR * 1e9 * v.young_pop.light_per_formed
	var got := 0.0
	var dr := 0.05
	for ir in 400:
		var R := (float(ir) + 0.5) * dr
		for ip in 720:
			var ph := TAU * (float(ip) + 0.5) / 720.0
			# The young layer integrates to one over height.
			var j := v.light_density(Vector3(R * cos(ph), 0.0, R * sin(ph)))
			got += j[2] * 2.0 * GalModels.MW_YOUNG_H * R * dr * TAU / 720.0
	ok(absf(got / want - 1.0) < 0.02, "young stars: %s L☉ in the arms for 1.65 M☉/yr over 100 Myr (%s of it)" % [U.expo(got, 3), String.num(got / want, 3)])
	var tau := 0.0
	var n := 8000
	for i in n:
		var f := (float(i) + 0.5) / float(n)
		tau += v.dust_density(-8.0 * (1.0 - f), 0.0208 * (1.0 - f), 0.0) * 8.0 / float(n)
	# Drimmel & Spergel's arms are cut off outside r_m = 6.71 kpc (their eq. 16): the
	# arm dust on Scutum–Centaurus (4.91 kpc, inside) is full and on Perseus (8.87 kpc)
	# down by exp(−((8.87 − 6.71)/2.07)²) = 0.34. Each is the crest's dust less the disc's.
	var arm_dust := func(R: float, beta_deg: float) -> float:
		var ph := PI + deg_to_rad(beta_deg)
		var on := v.dust_density(R * cos(ph), 0.0, R * sin(ph))
		var save: float = v.dust.rhoArm
		v.dust.rhoArm = 0.0
		var off := v.dust_density(R * cos(ph), 0.0, R * sin(ph))
		v.dust.rhoArm = save
		return on - off
	var ratio: float = arm_dust.call(8.87, 40.0) / arm_dust.call(4.91, 23.0)
	ok(absf(ratio - exp(-pow((8.87 - 6.71) / 2.07, 2.0))) < 0.02, "arm dust cut off outside 6.71 kpc: Perseus / Scutum–Centaurus %s (0.34)" % String.num(ratio, 3))
	var av := 1.0857 * tau
	ok(av > 15.0 and av < 28.0, "A_V from the Sun to the centre %s against ≈ 21.6 from Fritz et al. 2011 (15–28)" % String.num(av, 1))
	v.group.free()

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


# The real stars around the Sun (GalNeighbourhood, tools/build_neighbourhood.py): the
# Solar System sky's stars in the same directions and brightnesses, on the same flux
# scale; the far set's light map holding their flux; and the near set against the
# model's resolved stars, the Gaia comparison issue 25 asks for (a pin, not a fit).
func neighbourhood() -> void:
	var nb := GalNeighbourhood.bake()
	ok(not nb.is_empty() and int(nb.n_near) > 3000 and int(nb.n_far) > 50000,
		"the real stars around the Sun load: %s within 40 pc, %s beyond" % [nb.get("n_near", 0), nb.get("n_far", 0)])
	if nb.is_empty(): return
	# The near set's cut is the model's resolved limit.
	var c5 := GalPopulation.visible(Stellar.effective_temp(GalPopulation.M_RESOLVED))
	var mv_res := 4.83 - 2.5 * log(Stellar.luminosity(GalPopulation.M_RESOLVED) * (0.2126 * c5.r + 0.7152 * c5.g + 0.0722 * c5.b)) / log(10.0)
	ok(absf(mv_res - GalNeighbourhood.M_V_RESOLVED) < 0.005, "the near set's cut M_V %s is the model's %s M☉ star (%s)" % [
		String.num(GalNeighbourhood.M_V_RESOLVED, 3), String.num(GalPopulation.M_RESOLVED, 1), String.num(mv_res, 3)])
	# The Solar System sky's stars, through the app's own galactic frame, against the set.
	var gal := SkyModel.galactic_frame_j2000()
	var n_axis: Vector3 = gal[0]
	var c_axis: Vector3 = gal[1]
	var y_axis: Vector3 = gal[2]
	var cells := {}
	var n: int = int(nb.n_near) + int(nb.n_far)
	for i in n:
		var p: Vector3 = nb.pos[i]
		var d := p.length()
		var v := float(nb.mv[i]) + 5.0 * log(d * 100.0) / log(10.0)
		var lb := GalNeighbourhood.galactic(p)
		var key := Vector2i(int(rad_to_deg(lb.x)), int(rad_to_deg(lb.y) + 90.0))
		if not cells.has(key): cells[key] = []
		cells[key].append([Vector3(p.x, -p.z, p.y) / d, v])
	var total := 0
	var matched := 0
	# Vector3 is float32: near 1 its dot product cannot tell 70″ from nothing, its cross
	# product resolves 0.01″.
	var sin_tol := sin(deg_to_rad(2.0 / 3600.0))
	for path in [BrightStars.DATA, BrightStars.DATA_FAINT]:
		var f := FileAccess.open(path, FileAccess.READ)
		while f.get_position() + 24 <= f.get_length():
			var ra := f.get_float()
			var dec := f.get_float()
			var V := f.get_float()
			f.get_float()
			var pma := f.get_float()
			var pmd := f.get_float()
			total += 1
			# Gaia's positions are at 2016.0; the set's, like BSC5's, at J2000.
			var dt: float = 2000.0 - float(BrightStars.EPOCHS[path])
			dec += pmd * dt / 3.6e6
			ra += pma * dt / 3.6e6 / maxf(cos(deg_to_rad(dec)), 1e-6)
			var u := SkyModel.radec_to_scene(ra, dec).to_v3()
			var g := Vector3(u.dot(c_axis), u.dot(y_axis), u.dot(n_axis))
			var l := rad_to_deg(fposmod(atan2(g.y, g.x), TAU))
			var b := rad_to_deg(asin(clampf(g.z, -1.0, 1.0))) + 90.0
			var hit := false
			for dl in [-1, 0, 1]:
				for db in [-1, 0, 1]:
					for e in cells.get(Vector2i(posmod(int(l) + dl, 360), int(b) + db), []):
						var w: Vector3 = e[0]
						if w.dot(g) > 0.0 and w.cross(g).length() < sin_tol and absf(float(e[1]) - V) < 1e-3: hit = true
			if hit: matched += 1
	ok(total > 50000 and matched == total, "every Solar System sky star is in the set, in the same direction (2″ at J2000) and V (1e-3): %d of %d" % [matched, total])
	# The flux scale: a star's light at the Sun is the sky's flux for its V.
	var worst := 0.0
	for i in range(int(nb.n_near), int(nb.n_near) + 50):
		var p: Vector3 = nb.pos[i]
		var v := float(nb.mv[i]) + 5.0 * log(p.length() * 100.0) / log(10.0)
		var drawn := GalaxyVisual.K * GalNeighbourhood.l_vis(nb.mv[i]) / (4.0 * PI * p.length_squared())
		worst = maxf(worst, absf(drawn / (SkyModel.STAR_FLUX * pow(10.0, -0.4 * (v - SkyModel.STAR_FLUX_MAG))) - 1.0))
	ok(worst < 1e-5, "from the Sun a real star has the Solar System sky's flux for its V (worst %s)" % U.expo(worst, 1))
	# The far set's light map holds its flux.
	var ff := 0.0
	for i in range(int(nb.n_near), n):
		ff += GalNeighbourhood.l_vis(nb.mv[i]) / (4.0 * PI * (nb.pos[i] as Vector3).length_squared())
	var mf := GalNeighbourhood.map_flux(nb.map)
	var ml := 0.2126 * mf.r + 0.7152 * mf.g + 0.0722 * mf.b
	ok(absf(ml / ff - 1.0) < 1e-4, "the far stars' light map integrates to their flux (%s)" % String.num(ml / ff, 6))
	# Where the catalogue outshines the model's own glow the glow can give up no more.
	var vis := GalaxyVisual.new(GalModels.build("milky_way", 1))
	var sun := Vector3(-8.0, GalNeighbourhood.SUN_HEIGHT, 0.0)
	var N := 600 if quick else 1500
	var tot := 0.0
	var cat := 0.0
	var lost := 0.0
	var img: Image = nb.map
	for k in N:
		var zz := 1.0 - (2.0 * k + 1.0) / N
		var rr := sqrt(1.0 - zz * zz)
		var ph := PI * (3.0 - sqrt(5.0)) * k
		var d := Vector3(rr * cos(ph), zz, rr * sin(ph))
		var lb := GalNeighbourhood.galactic(d)
		var col := img.get_pixel(clampi(int(lb.x / TAU * GalNeighbourhood.MAP_W), 0, GalNeighbourhood.MAP_W - 1),
			clampi(int((0.5 - lb.y / PI) * GalNeighbourhood.MAP_H), 0, GalNeighbourhood.MAP_H - 1))
		var m := 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b
		var I := vis.ray_luminance(sun, d, 1e-3, 300)
		tot += I
		cat += m
		lost += maxf(m - I, 0.0)
	# Smoothed too narrowly (4°: 0.8 %) the map outruns the glow around Orion, which goes dark.
	ok(lost / cat < 0.002 and cat / tot > 0.1 and cat / tot < 0.4, "from the Sun the far stars carry %s %% of the model's sky; %s %% of theirs exceeds the glow it replaces (< 0.2)" % [
		U.fixed(100.0 * cat / tot, 1), U.fixed(100.0 * lost / cat, 2)])
	vis.dispose()
	# The near set against the model's resolved stars within 40 pc.
	var R := GalNeighbourhood.NEAR_KPC
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var jd := 0.0
	var js := 0.0
	var M := 20000
	var lv := GalaxyVisual.new(GalModels.build("milky_way", 1))
	for i in M:
		var p := Vector3(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
		if p.length() > 1.0: continue
		var j := lv.light_density(sun + p * R)
		jd += j[0]
		js += j[1]
	var cube := 8.0 * R * R * R / float(M)
	var n_model := jd * cube * lv.disc_pop.resolved_per_l + js * cube * lv.sphere_pop.resolved_per_l
	var l_model := 0.0
	var bins_m := {}
	for k in 4000:
		var u := (float(k) + 0.5) / 4000.0
		var z := -log(1.0 - u) / log(10.0)
		var fq := clampf(z / GalPopulation.Q_DECADES, 0.0, 1.0) * 64.0
		var qi := mini(int(fq), 63)
		var m := pow(10.0, lerpf(lv.disc_pop.quantiles[qi], lv.disc_pop.quantiles[qi + 1], fq - float(qi)))
		var cm := GalPopulation.visible(Stellar.effective_temp(m))
		var lvis := Stellar.luminosity(m) * (0.2126 * cm.r + 0.7152 * cm.g + 0.0722 * cm.b)
		l_model += lvis * n_model / 4000.0
		var bm := int(floor(4.83 - 2.5 * log(lvis) / log(10.0)))
		bins_m[bm] = float(bins_m.get(bm, 0.0)) + n_model / 4000.0
	lv.dispose()
	var l_real := 0.0
	var bins_r := {}
	for i in int(nb.n_near):
		l_real += GalNeighbourhood.l_vis(nb.mv[i])
		var br := int(floor(nb.mv[i]))
		bins_r[br] = int(bins_r.get(br, 0)) + 1
	for b in range(-2, 9):
		print("     M_V %d to %d: real %d, model %s" % [b, b + 1, int(bins_r.get(b, 0)), String.num(float(bins_m.get(b, 0.0)), 1)])
	var nr := float(nb.n_near) / n_model
	var lr := l_real / l_model
	print("     within 40 pc to M_V %s: real %d stars, %s L☉ visible; model %s, %s L☉" % [
		String.num(GalNeighbourhood.M_V_RESOLVED, 2), nb.n_near, String.num(l_real, 0), String.num(n_model, 0), String.num(l_model, 0)])
	ok(absf(nr - NEAR_COUNT_PIN) < 0.05 and absf(lr - NEAR_LIGHT_PIN) < 0.15,
		"within 40 pc the real stars number %s of the model's resolved ones and give %s of their light (pinned %s, %s)" % [
		String.num(nr, 3), String.num(lr, 2), String.num(NEAR_COUNT_PIN, 2), String.num(NEAR_LIGHT_PIN, 2)])
	var f0: Array = GalNeighbourhood.sun_frame(8.0, 0.0275, 0.0)
	var f1: Array = GalNeighbourhood.sun_frame(8.0, 0.0275, 100.0)
	var b1: Basis = f1[1]
	var turn := wrapf(atan2((f1[0] as Vector3).z, (f1[0] as Vector3).x) - atan2((f0[0] as Vector3).z, (f0[0] as Vector3).x), -PI, PI)
	ok(absf(turn - 2.75) < 1e-5 and b1.x.dot(-(f1[0] as Vector3) * Vector3(1, 0, 1)) > 0.0 and absf(b1.determinant() - 1.0) < 1e-6
		and b1.z.dot(Vector3(-sin(PI + 2.75), 0.0, cos(PI + 2.75))) < -0.999,
		"the Sun turns at Ω(R0) with its axes: +x to the centre, +z against the rotation")


# Landmarks (GalLandmarks): the galactic frame they are placed through against ESA's own
# (l, b) for eight Gaia DR3 stars (gaiadr3.gaia_source ra, dec, l, b, queried 2026-11-11),
# every card sourced, sky landmarks at their distances, and the Perseus arm's landmark on
# the spiral's crest as it turns.
const GAIA_LB := [
	[76.62890153390961, 41.23417207468237, 165.35410348349683, 0.2715901914842562],
	[100.77044199727958, 44.524315844628944, 171.18152308769763, 17.254190036602797],
	[228.87612720122996, 33.31433528392251, 53.11146055142921, 58.43086994075083],
	[310.86462803135805, 15.074387647430187, 60.13532371539176, -16.554395381590524],
	[285.00347297566384, 32.14555499144238, 62.90558467639902, 12.381797375622167],
	[3.6599461564529565, -18.933189798652894, 75.105843142222, -78.22610066408402],
	[91.43981189014927, -24.19562687012799, 230.46147536032308, -20.341731140987942],
	[203.67206658148982, -0.5956181019830046, 325.24373419802896, 60.38898664872216],
]

func landmarks() -> void:
	var worst := 0.0
	for r in GAIA_LB:
		var d := GalLandmarks.sky_direction(float(r[0]), float(r[1]))
		var lb := GalNeighbourhood.galactic(d)
		var want := Vector3(cos(deg_to_rad(r[3])) * cos(deg_to_rad(r[2])), sin(deg_to_rad(r[3])), -cos(deg_to_rad(r[3])) * sin(deg_to_rad(r[2])))
		var got := Vector3(cos(lb.y) * cos(lb.x), sin(lb.y), -cos(lb.y) * sin(lb.x))
		worst = maxf(worst, rad_to_deg(want.cross(got).length()) * 3600.0)
	ok(worst < 1.0, "the landmarks' galactic frame against ESA's (l, b) for 8 Gaia stars: worst %s″ (< 1)" % String.num(worst, 3))
	var model := GalModels.build("milky_way", 1)
	var lms := GalLandmarks.of("milky_way")
	var ids := {}
	var complete := true
	for lm in lms:
		if ids.has(lm.id) or String(lm.name).is_empty() or (lm.view as Array).size() != 2 or float(lm.view[0]) <= 0.0:
			complete = false
		ids[lm.id] = true
		var src := RegEx.create_from_string("\\([^)]*\\d{4}\\)")
		if src.search(String(lm.card)) == null: complete = false
		for t in [0.0, 100.0]:
			var p := GalLandmarks.position(lm, model, t)
			if not (is_finite(p.x) and is_finite(p.y) and is_finite(p.z)): complete = false
	ok(lms.size() >= 6 and complete, "%d Milky Way landmarks, each with a name, a view, a finite place and a dated source in its card" % lms.size())
	var sun := GalLandmarks.position(lms[0], model, 0.0)
	var worst_d := 0.0
	for lm in lms:
		if lm.at == "sky": worst_d = maxf(worst_d, absf((GalLandmarks.position(lm, model, 0.0) - sun).length() / float(lm.d) - 1.0))
	ok(worst_d < 1e-5, "sky landmarks stand at their measured distances from the Sun (worst %s)" % U.expo(worst_d, 1))
	# The Perseus landmark on the crest (Φ's minimum along its radius) now and 100 Myr on.
	var per := GalLandmarks.find("milky_way", "perseus")
	var sp: Dictionary = {}
	for p in model.patterns:
		if p.kind == GalPattern.Kind.SPIRAL: sp = p
	var worst_c := 0.0
	for t in [0.0, 100.0]:
		var q := GalLandmarks.position(per, model, t)
		var R := Vector2(q.x, q.z).length()
		var best := INF
		var at := 0.0
		for k in 7200:
			var ph := TAU * float(k) / 7200.0
			var v := GalPattern._full(sp, R * cos(ph), 0.0, R * sin(ph), t)[0]
			if v < best:
				best = v
				at = ph
		var off := absf(wrapf(atan2(q.z, q.x) - at, -PI / 2.0, PI / 2.0))
		worst_c = maxf(worst_c, rad_to_deg(off))
	ok(worst_c < 0.2, "the Perseus Arm's landmark stays on the spiral's crest as it turns (worst %s° over 100 Myr)" % String.num(worst_c, 2))


# The Milky Way's neighbours (GalModels.LOCAL_GROUP): each one's light from its stellar
# mass through the population model, against the absolute V McConnachie (2012, Table 3)
# measured, which the masses were not taken from; and each one's tilt and line of nodes
# as drawn against the inclination and position angle stated.
const MEASURED_MV := {"lmc": -18.1, "smc": -16.8, "m33": -18.8}

func neighbours() -> void:
	var mw := GalModels.build("milky_way", 1, false)
	var worst := 0.0
	var drawn := 0.0
	for k in MEASURED_MV:
		var lv := GalModels.visible_luminosity(GalModels.neighbour(k, true))
		var mv := 4.83 - 2.5 * log(lv) / log(10.0)
		var shown := 4.83 - 2.5 * log(GalModels.visible_luminosity(GalModels.neighbour(k))) / log(10.0)
		print("     %s: M_V %s from its stellar mass and the population's M/L, %s measured; drawn at %s" % [k, String.num(mv, 2), String.num(MEASURED_MV[k], 1), String.num(shown, 3)])
		worst = maxf(worst, absf(mv - float(MEASURED_MV[k])))
		drawn = maxf(drawn, absf(shown - float(MEASURED_MV[k])))
	ok(drawn < 1e-6, "the neighbours are drawn at McConnachie's (2012) measured absolute V (worst %s mag)" % U.expo(drawn, 1))
	ok(worst < NEIGHBOUR_MV_TOL, "their stellar masses alone would give within %s mag of it (< %s): the literature's masses imply M/L_V near 1.8, the population model 0.8" % [String.num(worst, 2), String.num(NEIGHBOUR_MV_TOL, 1)])
	# Tilt and line of nodes, from the frame drawn: the normal against the line of sight,
	# and the nodes projected on the sky against north and east.
	var worst_i := 0.0
	var worst_pa := 0.0
	for k in GalModels.LOCAL_GROUP:
		var spec: Dictionary = GalModels.LOCAL_GROUP[k]
		if float(spec.i) == 0.0: continue
		var f := GalLandmarks.neighbour_frame(spec, mw)
		var sun: Vector3 = GalLandmarks.position(GalLandmarks.MILKY_WAY[0], mw, 0.0)
		var b: Basis = f[1]
		var los := ((f[0] as Vector3) - sun).normalized()
		worst_i = maxf(worst_i, absf(rad_to_deg(acos(absf(b.y.dot(los)))) - float(spec.i)))
		var sb: Basis = GalNeighbourhood.sun_frame(8.0, 0.0, 0.0)[1]
		var north := sb * (GalLandmarks.sky_direction(float(spec.ra), float(spec.dec) + 0.01) - GalLandmarks.sky_direction(float(spec.ra), float(spec.dec) - 0.01)).normalized()
		var east := los.cross(north).normalized() * -1.0
		var pa := rad_to_deg(atan2(b.x.dot(east), b.x.dot(north)))
		worst_pa = maxf(worst_pa, absf(wrapf(pa - float(spec.pa), -90.0, 90.0)))
	ok(worst_i < 0.05 and worst_pa < 0.1, "the neighbours tilt and lie as measured: inclination within %s°, line of nodes within %s°" % [String.num(worst_i, 3), String.num(worst_pa, 3)])
	# Kafle et al.'s M31 (from five studies) beside Tamm et al.'s (2012) independent map.
	print("     M31 stars, 10¹⁰ M☉: bulge 3.4 here, 3.1–4.4 Tamm et al. (2012); disc 6.9 here, 5.7 (8.6 at most) there")


# Galaxies of their own scenes (GalModels.TYPES): drawn at their measured total light, and
# M104's dust, integrated back to a mass, De Looze et al.'s (2012) ring and inner disc.
func types() -> void:
	var worst := 0.0
	for k in GalModels.TYPES:
		var m := GalModels.type_galaxy(k)
		var mv := 4.83 - 2.5 * log(GalModels.visible_luminosity(m)) / log(10.0)
		worst = maxf(worst, absf(mv - float(GalModels.TYPES[k].mv)))
	ok(worst < 1e-6, "%d galaxies of their own scenes are drawn at their measured absolute V (worst %s mag)" % [GalModels.TYPES.size(), U.expo(worst, 1)])
	# M51's arms: the light the young term draws against the measured 36 %, and beside the
	# light Calzetti et al.'s (2005) 3.4 M☉/yr would give over 100 Myr.
	var m51 := GalModels.type_galaxy("m51")
	var va := GalaxyVisual.new(m51)
	var drawn_arms := va.young_k * va._arm_integral(va.arm_img)
	var young := GalPopulation.build({"kind": "constant", "gyr": GalModels.MW_YOUNG_GYR})
	var from_sfr := 3.4 * GalModels.MW_YOUNG_GYR * 1e9 * young.light_per_formed
	print("     M51's arms: %s L☉ drawn (36 %% of its V light), %s L☉ from its star formation rate (×%s)" % [
		U.expo(drawn_arms, 3), U.expo(from_sfr, 3), String.num(from_sfr / drawn_arms, 2)])
	ok(absf(drawn_arms / float(m51.armLight) - 1.0) < 1e-6, "M51's arms draw the light measured in them (%s)" % String.num(drawn_arms / float(m51.armLight), 6))
	# On each arm's ridge, past its rise, its light falls as exp(−R/h_s) (Marchuk et al. 2024).
	var worst_h := 0.0
	for i in (m51.arms as Array).size():
		var row: Array = m51.arms[i]
		var vals := []
		for R in [4.5, 8.0]:
			# The ridge's azimuth at R: β = βk − ln(R/Rk)/tan ψ, φ = π + β.
			var beta := deg_to_rad(float(row[2])) - log(R / float(row[1])) / tan(deg_to_rad(float(row[3])))
			vals.append(va._arms(R, PI + beta, 0.0))
		var want := exp(-(8.0 - 4.5) / float(m51.armDecay[i]))
		worst_h = maxf(worst_h, absf(float(vals[1]) / float(vals[0]) / want - 1.0))
	ok(worst_h < 0.05, "M51's arms fade along their ridges with their measured h_s (worst %s %%)" % U.fixed(worst_h * 100.0, 1))
	va.dispose()
	# NGC 5195 against M51: 4.41′ apart on the sky (NED), 35 kpc behind.
	var cf := GalLandmarks.companion_frame(m51, "ngc5195")
	var off: Vector3 = cf[0]
	var side := GalLandmarks.sun_side(m51)
	var along := -off.dot(side)
	var across := (off + side * along).length()
	var sep := rad_to_deg(atan2(across, float(GalModels.TYPES.m51.d) + along)) * 60.0
	ok(absf(sep - 4.41) < 0.02 and absf(along - 35.0) < 0.2, "NGC 5195 stands %s′ from M51 on the sky (NED 4.41′) and %s kpc behind it (35)" % [String.num(sep, 3), String.num(along, 2)])
	# The dust's V opacity from Draine's (2003, Table 4) two numbers: C_ext(V) = 4.89 × 10⁻²²
	# cm² per H and M_H/M_dust = 90; m_H 1.6735575 × 10⁻²⁷ kg (CODATA), M☉ = GM☉/G (G =
	# 6.67430 × 10⁻¹¹, CODATA 2018), in kpc²/M☉.
	var kappa_si := 4.89e-26 * 90.0 / 1.6735575e-27
	var kappa := kappa_si * (Rocketry.GM_SUN / 6.67430e-11) / (GalUnits.KPC_M * GalUnits.KPC_M)
	ok(absf(GalModels.DUST_KAPPA_V / kappa - 1.0) < 1e-3, "the dust's V opacity is Draine's (2003): %s cm²/g, %s kpc²/M☉" % [String.num(kappa_si * 10.0, 0), U.expo(kappa, 4)])
	var v := GalaxyVisual.new(GalModels.type_galaxy("m104"))
	# Ring and disc apart: the disc dust is the envelope term, the rings the rest.
	var ring := 0.0
	var disc := 0.0
	var dR := 0.01
	var dz := 0.0005
	var R := dR * 0.5
	while R < 14.0:
		var z := -0.08 + dz * 0.5
		var col_r := 0.0
		var col_d := 0.0
		while z < 0.08:
			var d_all := v.dust_density(R, z, 0.0)
			var d_disc: float = v.dust.kappa * v.dust.rhoDisc * exp(-R / float(v.dust.hr)) * GalaxyVisual._sech2(z / float(v.dust.h0))
			col_d += d_disc * dz
			col_r += (d_all - d_disc) * dz
			z += dz
		ring += TAU * R * dR * col_r
		disc += TAU * R * dR * col_d
		R += dR
	ring /= GalModels.DUST_KAPPA_V
	disc /= GalModels.DUST_KAPPA_V
	var er := absf(ring / GalModels.M104_RING_MASS - 1.0)
	var ed := absf(disc / GalModels.M104_DISC_DUST - 1.0)
	ok(er < 0.02 and ed < 0.02, "M104's dust integrates back to De Looze et al.'s ring (%s M☉, %s off) and inner disc (%s M☉, %s off)" % [
		U.expo(ring, 2), U.fixed(er * 100.0, 2) + " %", U.expo(disc, 2), U.fixed(ed * 100.0, 2) + " %"])
	v.dispose()
