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

# The Milky Way's light: the disc's and bulge's populations weighted by their visible
# luminosity give an integrated colour to set beside the measured one, Licquia,
# Newman & Brinchmann (2015): rest-frame B−V = 0.744 +0.068 −0.054. Never tuned to it.
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

## Native against GDScript where their libms differ: kpc, (kpc/Myr)/0.2 and relative work.
## MinGW's libm and the engine's differ by an ulp or so, which 300 steps carry to ~1e-13.
const PARITY_TOL := 1e-12
# Main-sequence stars per magnitude at the Sun against Bovy (2017, MNRAS 470, 1360)
# Table 1, measured with Gaia TGAS and 2MASS: dn/dM_V per subtype, averaged over the
# subtypes whose M_V falls in each bin (10⁻⁴ pc⁻³ mag⁻¹). Not fitted; the bounds pin
# the measured differences, which docs/physics/galaxies.md reports.
## Real stars within 40 pc against the model's resolved ones: number and visible light
## (galaxycheck's neighbourhood(); a comparison pinned so a change shows, not a fit).
const NEAR_COUNT_PIN := 0.62
const NEAR_LIGHT_PIN := 2.33
## The neighbours' absolute V from their stellar masses against McConnachie (2012): the
## LMC's and M33's come out 0.8–0.9 mag bright (their literature masses imply M/L_V ≈ 1.8,
## the population model's is ≈ 0.8); a pin that a change shows, not a fit.
const NEIGHBOUR_MV_TOL := 1.0
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
	# The rotation-curve instrument (HUD and lesson) holds each part's curve, which add up in
	# quadrature to the model's.
	var chart := GalCurveChart.new()
	chart.measure(tr, p)
	var worst_sum := INF if chart.parts.size() != p.parts.size() else 0.0
	for k in chart.model.size():
		var v2 := 0.0
		for name in chart.parts:
			var c: PackedVector2Array = chart.parts[name]
			if c.size() != chart.model.size():
				worst_sum = INF
				break
			v2 += c[k].y * c[k].y
		if is_finite(worst_sum): worst_sum = maxf(worst_sum, absf(sqrt(v2) - chart.model[k].y))
	chart.free()
	# The Solar System and the Galaxy share one sky (GalaxyScene's join): Betelgeuse
	# (J2000 88.79294, +7.40706) lands at its galactic (l, b) = (199.787, −8.959) on the Sun's
	# axes, and a direction survives the trip there and back.
	var l := deg_to_rad(199.787)
	var b := deg_to_rad(-8.959)
	var bet := SkyModel.radec_to_scene(88.79294, 7.40706).to_v3()
	var on_sun := GalaxyScene.solar_to_galaxy(bet, Basis())
	var off := rad_to_deg(on_sun.angle_to(Vector3(cos(b) * cos(l), sin(b), -cos(b) * sin(l))))
	var sun_b: Basis = GalNeighbourhood.sun_frame(8.122, 0.027, 140.0)[1]
	var back := GalaxyScene.galaxy_to_solar(GalaxyScene.solar_to_galaxy(bet, sun_b), sun_b)
	ok(off < 0.01 and back.angle_to(bet) < 1e-5, "the join's sky: Betelgeuse %s° from its galactic (l, b), %s° off after the round trip" % [U.fixed(off, 4), U.expo(rad_to_deg(back.angle_to(bet)), 1)])
	# Each part's v_c comes from its own force, summed in a different order: rounding only.
	ok(worst_sum < 1e-3, "the rotation chart's parts add to its model curve (%s km/s)" % U.expo(worst_sum, 1))
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
	var anchor := GalModels.spiral_anchor()
	var want := PI + deg_to_rad(float(anchor[1]))
	var off := absf(wrapf(crest.call(float(anchor[0])) - want, -PI / 2.0, PI / 2.0))
	ok(off < deg_to_rad(0.2), "spiral crest on Perseus (%s kpc at the model's R0, β = 40°) today, within %s°" % [String.num(float(anchor[0]), 2), String.num(rad_to_deg(off), 2)])
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
	# A step's pattern time comes from its index, so batching cannot change a trajectory:
	# 40 steps a call against 2000 in one, through the patterns' growth and grown in.
	var by40 := GalTracers.new(GalModels.build("milky_way", 4))
	var whole := GalTracers.new(GalModels.build("milky_way", 4))
	var n_steps := int(round((0.0 - by40.t) / GalTracers.DT)) + 400
	n_steps -= n_steps % 40
	for s in n_steps / 40: by40.step(40)
	whole.step(n_steps)
	ok(by40.pos == whole.pos and by40.vel == whole.vel and by40.work == whole.work,
		"%d steps in batches of 40 and in one give the same bits, through the patterns' growth to t = %s Myr" % [n_steps, String.num(whole.t, 0)])
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
	# arm dust on Scutum–Centaurus (inside) is full and on Perseus down by
	# exp(−((R − 6.71)/2.07)²), R its crest at the model's R0. Each is the crest's dust
	# less the disc's.
	var arm_dust := func(R: float, beta_deg: float) -> float:
		var ph := PI + deg_to_rad(beta_deg)
		var on := v.dust_density(R * cos(ph), 0.0, R * sin(ph))
		var save: float = v.dust.rhoArm
		v.dust.rhoArm = 0.0
		var off := v.dust_density(R * cos(ph), 0.0, R * sin(ph))
		v.dust.rhoArm = save
		return on - off
	var arms := GalModels.reid_arms()
	var r_per: float = arms[4][1]
	var r_sct: float = arms[1][1]
	var ratio: float = arm_dust.call(r_per, 40.0) / arm_dust.call(r_sct, 23.0)
	var cut := exp(-pow((r_per - 6.71) / 2.07, 2.0))
	ok(absf(ratio - cut) < 0.02, "arm dust cut off outside 6.71 kpc: Perseus / Scutum–Centaurus %s (%s)" % [String.num(ratio, 3), String.num(cut, 3)])
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
# The rings' and the march's quadrature; light lost to the disc's edge or the glow's
# bounds is 0.1–0.3 mag.
const DRAWN_MV_TOL := 0.005

## What a galaxy's visual actually draws, as an absolute V: its glow's luminance marched
## along the normal in rings over the drawn box and sphere, four azimuths a ring
## (bars and arms are not round), Σ = 4π × the ray's radiance.
static func drawn_mv(model: Dictionary, rings := 120, azimuths := 4) -> float:
	var v := GalaxyVisual.new(model)
	var box: Vector3 = v.glow_mat.get_shader_parameter("uBox")
	var reach: float = v.glow_mat.get_shader_parameter("uSphereR")
	var rmax := maxf(minf(box.x, box.z), reach)
	var top := maxf(box.y, reach) * 1.01
	var l := 0.0
	for k in rings:
		# Rings evenly spaced in √R, so the dense centre gets its share.
		var ra := rmax * pow(float(k) / rings, 2.0)
		var rb := rmax * pow(float(k + 1) / rings, 2.0)
		var rc := 0.5 * (ra + rb)
		var sig := 0.0
		for a in azimuths:
			var ph := TAU * (float(a) + 0.5) / azimuths
			sig += v.ray_luminance(Vector3(rc * cos(ph), top, rc * sin(ph)), Vector3(0, -1, 0)) * 4.0 * PI / azimuths
		l += sig * PI * (rb * rb - ra * ra)
	v.dispose()
	return 4.83 - 2.5 * log(l) / log(10.0)

func neighbours() -> void:
	var mw := GalModels.build("milky_way", 1, false)
	var worst := 0.0
	var drawn := 0.0
	for k in MEASURED_MV:
		var lv := GalModels.visible_luminosity(GalModels.neighbour(k, true))
		var mv := 4.83 - 2.5 * log(lv) / log(10.0)
		var nm := GalModels.neighbour(k)
		# A bar or arms in the map: enough azimuths that their harmonics average out.
		var shown := drawn_mv(nm, 120, 16 if nm.has("discMap") else 4)
		print("     %s: M_V %s from its stellar mass and the population's M/L, %s measured; drawn at %s" % [k, String.num(mv, 2), String.num(MEASURED_MV[k], 1), String.num(shown, 3)])
		worst = maxf(worst, absf(mv - float(MEASURED_MV[k])))
		drawn = maxf(drawn, absf(shown - float(MEASURED_MV[k])))
	ok(drawn < DRAWN_MV_TOL, "the neighbours' glow, marched as drawn, gives McConnachie's (2012) measured absolute V (worst %s mag < %s)" % [U.expo(drawn, 1), String.num(DRAWN_MV_TOL, 3)])
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
## M33's arms in its drawn map: the young light's normalised m = 2 amplitude over 1–3.2 kpc
## (HERM33ES's 0.4–0.8 for Hα and dust, 0.6 aimed at), and the star formation rate its light
## implies against what is measured.
func m33_arms() -> void:
	var m := GalModels.neighbour("m33")
	var v := GalaxyVisual.new(m)
	var img: Image = v.arm_img
	var n := img.get_width()
	var px := 2.0 * GalaxyVisual.ARM_HALF / float(n)
	var nb := int(3.3 / px) + 1
	var a0 := PackedFloat64Array()
	var cr := PackedFloat64Array()
	var ci := PackedFloat64Array()
	for arr in [a0, cr, ci]: arr.resize(nb)
	for j in n:
		for i in n:
			var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
			var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
			var k := int(sqrt(x * x + z * z) / px)
			if k >= nb: continue
			var r := img.get_pixel(i, j).r
			var phi := atan2(z, x)
			a0[k] += r
			cr[k] += r * cos(2.0 * phi)
			ci[k] += r * sin(2.0 * phi)
	var acc := 0.0
	var cnt := 0
	for k in nb:
		var R := (float(k) + 0.5) * px
		if R < 1.0 or R > 3.2: continue
		acc += sqrt(cr[k] * cr[k] + ci[k] * ci[k]) / a0[k]
		cnt += 1
	var a2 := acc / float(cnt)
	print("     M33: %s of its young light in the arms; star formation %s M☉/yr implied by its V" % [String.num(v.young_share, 3), String.num(float(m.sfr), 3)])
	ok(absf(a2 - 0.6) < 0.01, "M33's young light has m = 2 amplitude %s over 1–3.2 kpc (HERM33ES 0.4–0.8 in Hα and dust)" % String.num(a2, 3))
	# Verley et al. (2007) find 0.2 M☉/yr in the inner disc alone, from the infrared and Hα.
	ok(float(m.sfr) > 0.2 and float(m.sfr) < 0.7, "M33's light implies %s M☉/yr of star formation (inner disc alone 0.2, Verley et al. 2007)" % String.num(float(m.sfr), 3))
	v.dispose()

## The LMC's bar measured back out of its drawn map as Rathore et al. (2024) measured the real
## one: A2 and the m = 2 phase in 0.1 kpc annuli; the bar's end where A2 falls to half its
## peak; its phase seen on the sky.
func lmc_bar() -> void:
	var m := GalModels.neighbour("lmc")
	var v := GalaxyVisual.new(m)
	var img: Image = v.arm_img
	var n := img.get_width()
	var px := 2.0 * GalaxyVisual.ARM_HALF / float(n)
	var nb := 60
	var a0 := PackedFloat64Array()
	var cr := PackedFloat64Array()
	var ci := PackedFloat64Array()
	for arr in [a0, cr, ci]: arr.resize(nb)
	for j in n:
		for i in n:
			var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
			var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
			var k := int(sqrt(x * x + z * z) / 0.1)
			if k >= nb: continue
			var b := img.get_pixel(i, j).b
			var phi := atan2(z, x)
			a0[k] += b
			cr[k] += b * cos(2.0 * phi)
			ci[k] += b * sin(2.0 * phi)
	var peak := 0.0
	var kp := 0
	for k in nb:
		var a2 := sqrt(cr[k] * cr[k] + ci[k] * ci[k]) / a0[k]
		if a2 > peak:
			peak = a2
			kp = k
	var r_end := 0.0
	for k in range(kp, nb):
		if sqrt(cr[k] * cr[k] + ci[k] * ci[k]) / a0[k] < 0.5 * peak:
			r_end = (float(k) + 0.5) * 0.1
			break
	# The bar's direction in the plane from the phase inside it, then on the sky.
	var sr := 0.0
	var si := 0.0
	for k in range(5, 20):
		sr += cr[k]
		si += ci[k]
	var psi := 0.5 * atan2(si, sr)
	var spec: Dictionary = GalModels.LOCAL_GROUP.lmc
	var sk := GalLandmarks.sky_basis(float(spec.ra), float(spec.dec), float(spec.i), float(spec.pa))
	var w: Vector3 = (sk[1] as Basis).x * cos(psi) + (sk[1] as Basis).z * sin(psi)
	var e := 0.5
	var north := (GalLandmarks.sky_direction(float(spec.ra), float(spec.dec) + e) - GalLandmarks.sky_direction(float(spec.ra), float(spec.dec) - e)).normalized()
	var east := (GalLandmarks.sky_direction(float(spec.ra) + e / cos(deg_to_rad(float(spec.dec))), float(spec.dec)) - GalLandmarks.sky_direction(float(spec.ra) - e / cos(deg_to_rad(float(spec.dec))), float(spec.dec))).normalized()
	var pa := fposmod(rad_to_deg(atan2(w.dot(east), w.dot(north))), 180.0)
	print("     LMC bar: %s of the disc's light, A2 peak %s at %s kpc, half at %s kpc, sky PA %s°" % [
		String.num(v.bar_share, 3), String.num(peak, 3), String.num((float(kp) + 0.5) * 0.1, 2), String.num(r_end, 2), String.num(pa, 2)])
	ok(absf(peak - 0.27) < 0.005, "the LMC's drawn bar has Rathore et al.'s peak A2 (%s, want 0.27)" % String.num(peak, 4))
	ok(absf(pa - 121.26) < 1.0, "the LMC's drawn bar lies at PA %s° on the sky (Rathore et al. 121.26°)" % String.num(pa, 2))
	# Their AM1 radius, A2 at half its peak: 2.58 (+0.04 −0.05) kpc, binned in 0.1 kpc annuli.
	ok(absf(r_end - 2.58) < 0.1, "the LMC's drawn bar's A2 halves at %s kpc (Rathore et al. 2.58)" % String.num(r_end, 2))
	v.dispose()

## M87 drawn from Kormendy et al.'s (2009) measured profile: the drawn galaxy, projected along
## parallel rays, against each measured point inside half the profile's reach, and its light
## against their M_VT.
const M87_PROFILE_TOL := 0.05
func m87() -> void:
	var m := GalModels.type_galaxy("m87")
	var v := GalaxyVisual.new(m)
	var prof := GalModels.m87_surface(float(m.sky.d))
	var R: PackedFloat64Array = prof[0]
	var lnI: PackedFloat64Array = prof[1]
	var rmax := R[R.size() - 1]
	var d := Vector3(0.0, -1.0, 0.0)
	var worst := 0.0
	var worst_r := 0.0
	var n := 0
	for i in R.size():
		if R[i] > 0.5 * rmax: continue
		var sigma := v.ray_luminance(Vector3(R[i], 600.0, 0.0), d, 1e-4, 3000) * 4.0 * PI
		var dm := 2.5 * (lnI[i] - log(sigma)) / log(10.0)
		if absf(dm) > absf(worst):
			worst = dm
			worst_r = R[i]
		n += 1
	ok(absf(worst) < M87_PROFILE_TOL, "M87 projects back onto Kormendy et al.'s %d measured points inside %s kpc (worst %s mag at %s kpc)" % [
		n, U.fixed(0.5 * rmax, 0), U.fixed(worst, 3), U.fixed(worst_r, 2)])
	# Its light within the last point's circle on the sky, as photometry adds it up.
	var lc := 0.0
	var steps := 60
	var r0 := log(0.01)
	var dl := (log(R[R.size() - 1]) - r0) / float(steps)
	for k in steps:
		var ra := exp(r0 + float(k) * dl)
		var rb := exp(r0 + float(k + 1) * dl)
		var rc := sqrt(ra * rb)
		lc += v.ray_luminance(Vector3(rc, 600.0, 0.0), d, 1e-4, 3000) * 4.0 * PI * PI * (rb * rb - ra * ra)
	lc += v.ray_luminance(Vector3(0.005, 600.0, 0.0), d, 1e-4, 3000) * 4.0 * PI * PI * 1e-4
	var mv := 4.83 - 2.5 * log(lc) / log(10.0)
	ok(absf(mv - float(GalModels.TYPES.m87.mv)) < 0.05, "M87 drawn holds M_V %s within its last measured point's circle (Kormendy et al. M_VT −22.95)" % U.fixed(mv, 3))
	v.dispose()

## M51 (GalModels.M51_LIGHT, M51_DUST, M51_HII): each measured input drawn back out of the map
## and catalogue, and the whole against independent measurements.
const M51_SEEN_TOL := 0.35
func m51() -> void:
	var m := GalModels.type_galaxy("m51")
	var v := GalaxyVisual.new(m)
	var img: Image = v.arm_img
	var n := GalaxyVisual.ARM_N
	var px := 2.0 * GalaxyVisual.ARM_HALF / float(n)
	# Rings of texels, as _gather_light bins them: mean and extremes of each channel.
	var nb := int(ceil(GalaxyVisual.ARM_HALF * sqrt(2.0) / px)) + 1
	var mean := []
	var lo := []
	var hi := []
	var cnt := PackedFloat64Array()
	cnt.resize(nb)
	for c in 3:
		var a := PackedFloat64Array(); a.resize(nb); mean.append(a)
		var b := PackedFloat64Array(); b.resize(nb); b.fill(1e300); lo.append(b)
		var e := PackedFloat64Array(); e.resize(nb); hi.append(e)
	var dust_in := 0.0
	var dust_all := 0.0
	for j in n:
		for i in n:
			var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
			var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
			var R := sqrt(x * x + z * z)
			var k := int(R / px)
			var p := img.get_pixel(i, j)
			cnt[k] += 1.0
			for c in 3:
				mean[c][k] += p[c]
				lo[c][k] = minf(lo[c][k], p[c])
				hi[c][k] = maxf(hi[c][k], p[c])
			dust_all += p.g * px * px
			if R < 6.8: dust_in += p.g * px * px
	# Each band of radius keeps the measured profile: the dust's (lanes gathered), the old and
	# young discs'. Bands of ±0.5 kpc, not single rings of texels: a ring samples a 5° lane on
	# the square grid too coarsely to hold its mean to a per cent.
	var worst := [0.0, 0.0, 0.0]
	for R in [1.0, 2.5, 4.0, 6.0, 8.0]:
		var got := [0.0, 0.0, 0.0]
		var want := [0.0, 0.0, 0.0]
		for j in n:
			for i in n:
				var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
				var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
				var rr := sqrt(x * x + z * z)
				if absf(rr - R) > 0.5: continue
				var p := img.get_pixel(i, j)
				for c in 3: got[c] += p[c]
				want[0] += GalModels.inman_surface(m.thinMap.discs, float(m.thinMap.outerH), rr) * float(m.thinMap.bol)
				want[1] += v._dust_axisym(rr)
				want[2] += GalModels.inman_surface(m.discMap.discs, float(m.discMap.outerH), rr) * float(m.discMap.bol)
		for c in 3: worst[c] = maxf(worst[c], absf(float(got[c]) / float(want[c]) - 1.0))
	ok(worst[0] < 0.01 and worst[1] < 0.01 and worst[2] < 0.01, "M51's rings keep Inman et al.'s profiles: young %s, dust %s, old %s %%" % [
		U.fixed(worst[0] * 100.0, 2), U.fixed(worst[1] * 100.0, 2), U.fixed(worst[2] * 100.0, 2)])
	# Dust: the map against the profile's own integral, Inman et al.'s mass and Mentuch Cooper et
	# al.'s (2012, Table 2: 1.19e8 M☉ at 9.9 Mpc, another dust model).
	var analytic := 0.0
	var dr := 0.001
	var r := dr * 0.5
	while r < 6.8:
		analytic += v._dust_axisym(r) * TAU * r * dr
		r += dr
	var mc := 1.19e8 * pow(8.58 / 9.9, 2.0)
	print("     M51's dust: %s M☉ inside 6.8 kpc (Inman et al. 3.74e7), %s M☉ in all (Mentuch Cooper et al. %s)" % [
		U.expo(dust_in, 3), U.expo(dust_all, 3), U.expo(mc, 3)])
	ok(absf(dust_in / analytic - 1.0) < 0.01, "M51's dust map holds its profile's mass inside 6.8 kpc (%s)" % String.num(dust_in / analytic, 4))
	ok(dust_in / 3.74e7 > 1.05 and dust_in / 3.74e7 < 1.2 and absf(dust_all / mc - 1.0) < 0.2,
		"M51's dust mass: %s of Inman et al.'s (Draine's V opacity against their B model), %s of Mentuch Cooper et al.'s" % [
		String.num(dust_in / 3.74e7, 3), String.num(dust_all / mc, 3)])
	# Lanes upstream of their arms by Egusa et al.'s (2009) ΔΘ at the anchor.
	var dtheta: float = float(m.dustMap.omegaT) * (float(m.dustMap.rCR) / float(m.dustMap.anchor) - 1.0)
	var wl := 0.0
	for i in v.lanes.size():
		wl = maxf(wl, absf(v._arm_beta(i, float(m.dustMap.anchor))[0] - v._lane_beta(i, float(m.dustMap.anchor)) - dtheta))
	ok(dtheta > 0.0 and wl < 1e-9, "M51's dust lanes stand %s° upstream of their arms at %s kpc (Egusa et al. 2009)" % [
		String.num(rad_to_deg(dtheta), 2), m.dustMap.anchor])
	# The old disc's peak to valley at 125″ (5.2 kpc), Rix & Rieke's 3; the young light's share
	# between the arms, 1 − 0.91.
	var k5 := int(5.2 / px)
	var con: float = hi[2][k5] / lo[2][k5]
	ok(absf(con - 3.0) < 0.15, "M51's old disc peaks %s× its valley at 5.2 kpc (Rix & Rieke 3)" % String.num(con, 2))
	# The young light at 4 kpc, texel by texel: the ring's light with 91 % (Lee et al.) gathered as
	# the arms' profile has it, the rest even.
	var k4 := int(4.0 / px)
	var ring := []
	var a_sum := 0.0
	for j in n:
		for i in n:
			var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
			var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
			var rr := sqrt(x * x + z * z)
			if int(rr / px) != k4: continue
			var a := v._arms(rr, atan2(z, x), 0.0)
			ring.append([rr, a, img.get_pixel(i, j).r])
			a_sum += a
	var wy := 0.0
	for e in ring:
		var t: float = GalModels.inman_surface(m.thinMap.discs, float(m.thinMap.outerH), e[0]) * float(m.thinMap.bol)
		var f: float = 0.91 * v._arm_presence(e[0])
		wy = maxf(wy, absf(float(e[2]) / (t * ((1.0 - f) + f * float(e[1]) / (a_sum / float(ring.size())))) - 1.0))
	ok(wy < 1e-5, "M51's young light at 4 kpc: 91 %% of each ring in the arms' profile, the rest even (worst %s)" % U.expo(wy, 1))
	# The light, all of it: the map's old and young discs and the bulge, each its model's.
	var disc_drawn: float = v.disc_k * v._map_integral(img, 2)
	ok(absf(disc_drawn / v._l_disc - 1.0) < 1e-6 and absf(v.young_k * v._arm_integral(img) / v._l_young - 1.0) < 1e-6,
		"M51's discs draw their model's light (old %s, young %s)" % [String.num(disc_drawn / v._l_disc, 6), String.num(v.young_k * v._arm_integral(img) / v._l_young, 6)])
	# Seen from the Sun through its own dust, against RC3's V_T⁰ (−21.53): parallel rays across it.
	var side := GalLandmarks.sun_side(m)
	var d := -side
	var e1 := d.cross(Vector3.UP).normalized()
	var e2 := d.cross(e1).normalized()
	var seen := [0.0, 0.0]
	var keep: Dictionary = v.dust_map
	for pass_i in 2:
		v.dust_map = keep if pass_i == 0 else {}
		var acc := 0.0
		var a := -24.0 + 0.25
		while a < 24.0:
			var b := -24.0 + 0.25
			while b < 24.0:
				acc += v.ray_luminance(side * 200.0 + e1 * a + e2 * b, d, 1e-3, 96) * 0.25
				b += 0.5
			a += 0.5
		seen[pass_i] = acc * 4.0 * PI
	v.dust_map = keep
	var hii_l := 0.0
	for i in v.hii_cat.n:
		var c: Color = (v.hii_cat.stars[i] as Color) + (v.hii_cat.lines[i] as Color)
		hii_l += 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	var intrinsic := GalModels.visible_luminosity(m)
	var mv_free := 4.83 - 2.5 * log(seen[1] + hii_l) / log(10.0)
	var mv_seen := 4.83 - 2.5 * log(seen[0] + hii_l * seen[0] / seen[1]) / log(10.0)
	print("     M51 from the Sun: M_V %s through its dust, %s without (its stars %s), RC3 −21.53" % [
		U.fixed(mv_seen, 2), U.fixed(mv_free, 2), U.fixed(4.83 - 2.5 * log(intrinsic) / log(10.0), 2)])
	ok(absf(mv_free - (4.83 - 2.5 * log(intrinsic) / log(10.0))) < 0.02, "M51's rays add up to its stars' light without dust (%s mag)" % U.fixed(mv_free - (4.83 - 2.5 * log(intrinsic) / log(10.0)), 3))
	ok(absf(mv_seen - float(GalModels.TYPES.m51.mv)) < M51_SEEN_TOL, "M51 shows M_V %s through its dust, %s mag from RC3's −21.53 (no scattering: < %s)" % [
		U.fixed(mv_seen, 2), U.fixed(mv_seen - float(GalModels.TYPES.m51.mv), 2), M51_SEEN_TOL])
	hii_checks(m, v)
	v.dispose()

## M51's H II regions against what they were drawn from.
func hii_checks(m: Dictionary, v: GalaxyVisual) -> void:
	var c: Dictionary = v.hii_cat
	var spec: Dictionary = m.hii
	var want: float = pow(10.0, log(float(spec.sfr)) / log(10.0) + float(spec.logC)) * (1.0 - float(spec.dig))
	var drawn := 0.0
	for l in c.lum: drawn += l
	ok(absf(float(c.ha_regions) / want - 1.0) < 1e-9 and absf(drawn / float(c.ha_drawn) - 1.0) < 1e-9,
		"M51's H II regions hold the star formation rate's Hα less the diffuse 45 %% (%s erg/s; %s of it drawn in %d regions of %d)" % [
		U.expo(want, 3), String.num(drawn / want, 3), c.n, c.n_all])
	# Lee et al.'s own regions: 10^41.1 + 10^40.6 + 10^40.1 erg/s at 9.9 Mpc (their §5.2).
	var lee := (pow(10.0, 41.1) + pow(10.0, 40.6) + pow(10.0, 40.1)) * pow(8.58 / 9.9, 2.0)
	print("     M51's H II regions: %s erg/s in Hα; Lee et al. catalogue %s (%s dex)" % [U.expo(want, 3), U.expo(lee, 3), U.fixed(log(lee / want) / log(10.0), 2)])
	# Seen face-on through the disc's dust and their own clouds', as Lee et al. saw them; the
	# regions left in the smooth light are taken as dimmed as the drawn ones.
	var tr := 0.0
	var tl := 0.0
	for i in range(0, c.n, 7):
		var p: Vector3 = c.pos[i]
		var tau := 0.0
		var y := p.y
		while y < 2.0:
			tau += v.dust_density(p.x, y + 0.0025, p.z) * 0.005
			y += 0.005
		tr += float(c.lum[i]) * exp(-tau * float(GalModels.EXTINCTION_RGB[0]))
		tl += float(c.lum[i])
	var shown := float(c.ha_regions) * tr / tl * GalHII.line_transmission(spec).r
	ok(absf(log(shown / lee) / log(10.0)) < 0.05, "M51's H II regions show %s erg/s of Hα face-on through the dust, Lee et al. observe %s (%s dex)" % [
		U.expo(shown, 3), U.expo(lee, 3), U.fixed(log(shown / lee) / log(10.0), 3)])
	# The luminosity function's bright slope recovered from the catalogue: dN/dlog L ∝ L^(α+1).
	var lb := pow(10.0, float(spec.logL[1])) * pow(8.58 / float(spec.d), 2.0)
	var hi := pow(10.0, float(spec.logL[2])) * pow(8.58 / float(spec.d), 2.0)
	var counts := [0.0, 0.0]
	var mid := sqrt(lb * hi) / 4.0
	for l in c.lum:
		if l >= lb and l < mid: counts[0] += 1.0
		elif l >= mid and l < hi: counts[1] += 1.0
	# ∫ L^α dL over each half against their ratio.
	var r_want := GalHII._power_int(mid / lb, hi / lb, float(spec.alpha[0])) / GalHII._power_int(1.0, mid / lb, float(spec.alpha[0]))
	var r_got: float = counts[1] / counts[0]
	ok(absf(r_got / r_want - 1.0) < 0.1, "M51's H II regions above the break follow Lee et al.'s L^−2.25 (bright/faint %s, want %s)" % [String.num(r_got, 3), String.num(r_want, 3)])
	# Sizes on L ∝ D^3.04 through the anchor.
	var l0 := pow(10.0, float(spec.logL[0])) * pow(8.58 / float(spec.d), 2.0)
	var d0 := float(spec.size[0]) * 8.58 / float(spec.d) * 1e-3
	var ws := 0.0
	for i in mini(c.n, 500):
		ws = maxf(ws, absf(float(c.sigma[i]) / (GalHII.SIGMA_PER_D * d0 * pow(float(c.lum[i]) / l0, 1.0 / float(spec.size[1]))) - 1.0))
	ok(ws < 1e-5, "M51's H II regions are as large as L ∝ D^3.04 makes them")
	# The young light kept: the smooth arms' plus the regions' clusters, against the young
	# population's light; the lines on top.
	var y0: Color = v.young_col0 * float(m.armLight)
	var smooth: Color = v.young_col * v._l_young - (c.dig_vis as Color)
	var stars := Color(0, 0, 0)
	for s in c.stars: stars += s
	var lum0 := 0.2126 * y0.r + 0.7152 * y0.g + 0.0722 * y0.b
	var lum1 := 0.2126 * (smooth.r + stars.r) + 0.7152 * (smooth.g + stars.g) + 0.0722 * (smooth.b + stars.b)
	ok(absf(lum1 / lum0 - 1.0) < 1e-6, "M51's young stars keep their light between the arms' glow and the regions' clusters (%s)" % String.num(lum1 / lum0, 7))
	# Clustering: 1 + ω(r) over 100–3000 pc, Landy & Szalay, against Grasha et al.'s (2019,
	# Table 2) −0.40 ± 0.05 for M51's clusters under 10 Myr. 1031 regions, as they had clusters.
	var slope := hii_clustering(v, c)
	# With 1031 points the estimator itself scatters by about Grasha et al.'s ±0.05: within 2σ.
	ok(absf(slope + 0.40) < 0.1, "M51's H II regions cluster with 1 + ω ∝ r^%s over 100–3000 pc (Grasha et al. −0.40 ± 0.05)" % String.num(slope, 3))

func hii_clustering(v: GalaxyVisual, c: Dictionary) -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var nd := 1031
	var d := []
	for k in nd: d.append(c.pos[rng.randi_range(0, int(c.n) - 1)])
	var sp: Dictionary = GalModels.M51_HII.duplicate()
	sp.levels = 0
	var rcat := GalHII.build(sp, 8580.0, v.arm_img, GalaxyVisual.ARM_HALF, 1e10, 0.09, 11)
	var r := []
	for k in 4 * nd: r.append(rcat.pos[rng.randi_range(0, int(rcat.n) - 1)])
	var edges := []
	for b in 11: edges.append(0.1 * pow(30.0, float(b) / 10.0))
	var dd := _pairs(d, d, edges, true)
	var drp := _pairs(d, r, edges, false)
	var rr := _pairs(r, r, edges, true)
	var na := float(d.size())
	var nr := float(r.size())
	var xs := []
	var ys := []
	for b in 10:
		var w: float = (dd[b] / (na * (na - 1.0) / 2.0) - 2.0 * drp[b] / (na * nr) + rr[b] / (nr * (nr - 1.0) / 2.0)) / (rr[b] / (nr * (nr - 1.0) / 2.0))
		xs.append(log(sqrt(float(edges[b]) * float(edges[b + 1]))))
		ys.append(log(1.0 + w))
	var mx := 0.0
	var my := 0.0
	for i in 10:
		mx += float(xs[i]) / 10.0
		my += float(ys[i]) / 10.0
	var sxy := 0.0
	var sxx := 0.0
	for i in 10:
		sxy += (float(xs[i]) - mx) * (float(ys[i]) - my)
		sxx += (float(xs[i]) - mx) * (float(xs[i]) - mx)
	return sxy / sxx

func _pairs(a: Array, b: Array, edges: Array, same: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(edges.size() - 1)
	var lo: float = edges[0]
	var l0 := log(lo)
	var hi: float = edges[edges.size() - 1]
	var step := (log(hi) - l0) / float(edges.size() - 1)
	for i in a.size():
		var p: Vector3 = a[i]
		for j in (range(i + 1, b.size()) if same else range(b.size())):
			var q: Vector3 = b[j]
			var s := Vector2(p.x - q.x, p.z - q.z).length()
			if s >= lo and s < hi: out[int((log(s) - l0) / step)] += 1.0
	return out

func types() -> void:
	# M51's light is its stars before the dust (Inman et al. 2023); what it shows through the dust
	# is checked against RC3 in m51() instead.
	var worst := 0.0
	# RC3's V_T⁰ and Kormendy et al.'s M_VT are corrected for the galaxy's own dust, so the
	# glow is marched without it; seen face-on, the dust then takes what it takes.
	for k in GalModels.TYPES:
		if GalModels.TYPES[k].has("light"): continue
		var m := GalModels.type_galaxy(k)
		var dusty := m.has("dust") or m.has("dustRing")
		var seen := drawn_mv(m) if dusty else 0.0
		for d in ["dust", "dustRing"]: m.erase(d)
		var mv := drawn_mv(m, 120, 16 if m.has("arms") else 4)
		print("     %s: drawn at M_V %s, measured %s%s" % [k, String.num(mv, 3), String.num(float(GalModels.TYPES[k].mv), 2),
			(", %s through its dust face-on" % String.num(seen, 3)) if dusty else ""])
		worst = maxf(worst, absf(mv - float(GalModels.TYPES[k].mv)))
	ok(worst < DRAWN_MV_TOL, "%d galaxies of their own scenes, their glow marched as drawn, give their measured absolute V (worst %s mag < %s)" % [GalModels.TYPES.size() - 2, U.expo(worst, 1), String.num(DRAWN_MV_TOL, 3)])
	m51()
	ism()
	m87()
	lmc_bar()
	m33_arms()
	var m51 := GalModels.type_galaxy("m51")
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

# The medium below the map (GalISM): its field, that its multipliers keep the dust's mass and
# the young light (mean one, at every footprint), that its shear stays within one shear time,
# and what it does to M51 seen through its dust. docs/physics/galaxies.md#the-medium-below-the-map.
## At the normalising footprint exact; finer and coarser ones move it by what their own eddies
## do not average out.
const ISM_MEAN_TOL := Vector2(0.01, 0.03)
const ISM_SEEN_TOL := 0.10
func ism() -> void:
	var f := GalISM.field()
	var n := GalISM.N * GalISM.N
	var worst := 0.0
	for c in 2:
		var mean := 0.0
		var v := 0.0
		for i in n: mean += f[2 * i + c]
		mean /= n
		for i in n: v += (f[2 * i + c] - mean) * (f[2 * i + c] - mean)
		worst = maxf(worst, maxf(absf(mean), absf(v / n - 1.0)))
	var cross := 0.0
	for i in n: cross += f[2 * i] * f[2 * i + 1]
	ok(worst < 2e-3 and absf(cross / n) < 0.1, "the medium's field: two unit Gaussian channels (worst %s), uncorrelated (%s)" % [U.expo(worst, 1), String.num(cross / n, 3)])
	var m := GalModels.type_galaxy("m51")
	var vis := GalaxyVisual.new(m)
	# Every octave's turn back grows by at most SHEAR_MAX per e-fold of radius.
	var t := vis.ism_turns
	var slope := 0.0
	for o in GalISM.OCTAVES:
		for i in range(1, GalISM.TURN_N - 1):
			var r0 := maxf(vis.edge * float(i) / float(GalISM.TURN_N - 1), 0.02)
			var r1 := vis.edge * float(i + 1) / float(GalISM.TURN_N - 1)
			slope = maxf(slope, absf(t[o * GalISM.TURN_N + i + 1] - t[o * GalISM.TURN_N + i]) / log(r1 / r0))
	ok(slope <= GalISM.SHEAR_MAX * (1.0 + 1e-5), "the medium's shear stays within one shear time: strain %s ≤ %s" % [String.num(slope, 4), GalISM.SHEAR_MAX])
	# Mean one, weighted as the galaxy weighs it: the dust map's mass and the young light, over
	# the arm map's texels, at a fine and a coarse footprint.
	var img := vis.arm_img
	var px := 2.0 * GalaxyVisual.ARM_HALF / float(GalaxyVisual.ARM_N)
	var errs := Vector2.ZERO
	for foot in [0.005, 0.02, 0.1, 0.15, 0.3, 0.6]:
		var acc := Vector4.ZERO
		for j in range(0, GalaxyVisual.ARM_N, 2):
			for i in range(0, GalaxyVisual.ARM_N, 2):
				var x := -GalaxyVisual.ARM_HALF + (float(i) + 0.5) * px
				var z := -GalaxyVisual.ARM_HALF + (float(j) + 0.5) * px
				var c := img.get_pixel(i, j)
				var y := c.r * vis._envelope(sqrt(x * x + z * z))
				if c.g <= 0.0 and y <= 0.0: continue
				var mm := GalISM.multipliers(f, Vector3(x, 0.0, z), foot, vis.ism_turns, vis.edge, 0.0, vis.ism_layers, vis.ism_norm, vis.ism_feathers)
				acc += Vector4(c.g * GalISM.dust(mm.x), c.g, y * mm.y, y)
		errs = Vector2(maxf(errs.x, absf(acc.x / acc.y - 1.0)), maxf(errs.y, absf(acc.z / acc.w - 1.0)))
	ok(errs.x < ISM_MEAN_TOL.x and errs.y < ISM_MEAN_TOL.y, "M51's medium keeps its dust's mass (%s %%, < %s) and its young light (%s %%, < %s) at footprints 5–600 pc" % [
		U.fixed(errs.x * 100.0, 2), U.fixed(ISM_MEAN_TOL.x * 100.0, 0), U.fixed(errs.y * 100.0, 2), U.fixed(ISM_MEAN_TOL.y * 100.0, 0)])
	# Seen from the Sun through its own dust, with the medium as a 0.2″ pixel draws it: clumped
	# dust lets more light through than the smooth model's (Witt & Gordon 1996).
	var side := GalLandmarks.sun_side(m)
	var d := -side
	var e1 := d.cross(Vector3.UP).normalized()
	var e2 := d.cross(e1).normalized()
	var pix := deg_to_rad(0.2 / 3600.0) * float(GalModels.TYPES.m51.d) / 200.0
	var seen := [0.0, 0.0]
	for pass_i in 2:
		var acc := 0.0
		var a := -24.0 + 0.25
		while a < 24.0:
			var b := -24.0 + 0.25
			while b < 24.0:
				acc += vis.ray_luminance(side * 200.0 + e1 * a + e2 * b, d, 1e-3, 96, pix if pass_i == 0 else 0.0) * 0.25
				b += 0.5
			a += 0.5
		seen[pass_i] = acc
	var shift := -2.5 * log(seen[0] / seen[1]) / log(10.0)
	ok(absf(shift) < ISM_SEEN_TOL, "M51 through its dust with the medium: %s mag from the smooth model's (< %s)" % [U.fixed(shift, 3), ISM_SEEN_TOL])
	vis.dispose()
