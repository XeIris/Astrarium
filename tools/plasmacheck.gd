extends SceneTree

# PLASMA CHECK: the shock layer's spectrum (PlasmaSpectrum) against colorimetry, the
# band systems that should dominate each regime, the Rankine–Hugoniot jump of the
# CO₂ and N₂–CH₄ solver, and the shader's Boltzmann shift (entry_plasma.gdshaderinc).
#   Godot --headless --path . --script res://tools/plasmacheck.gd

var checks := 0
var failures := 0

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["PASS" if ok else "FAIL", label])

func layer(body: String, h: float, V: float):
	var atm = U.merged({"g": 9.8, "R": 6.37e6}, Rocketry.ATMOSPHERES[body])
	var pr := Rocketry.profile(atm, h)
	return PlasmaSpectrum.shock_state(atm, pr[0], pr[1], V, body)

func shares(st: Dictionary) -> Dictionary:
	var em := PlasmaSpectrum.emission(st)
	var tot := 0.0
	for e in em: tot += float(e[2])
	var out := {}
	for e in em: out[e[0]] = float(e[2]) / tot
	return out

# The shader's sum on the CPU: each term shifted by e^(θ/T_s − θ/T), desaturated, peak 1.
func shader_colour(terms: Array, Ts: float, T: float) -> Color:
	var c := Color(0, 0, 0)
	for t in terms: c += (t[0] as Color) * float(t[1]) * exp(float(t[2]) * (1.0 / Ts - 1.0 / T))
	var lo := minf(minf(c.r, c.g), c.b)
	if lo < 0.0: c = Color(c.r - lo, c.g - lo, c.b - lo)
	var m := maxf(maxf(c.r, c.g), c.b)
	return Color(c.r / m, c.g / m, c.b / m)

func _init() -> void:
	# Equal-energy white E in linear sRGB is (1.271, 1, 0.959) relative to G.
	var w := Color(0, 0, 0)
	for i in 401: w += PlasmaSpectrum.xyz_to_rgb(PlasmaSpectrum.cmf(380.0 + i))
	check("illuminant E → sRGB (%.3f, 1, %.3f)" % [w.r / w.g, w.b / w.g], absf(w.r / w.g - 1.271) < 0.03 and absf(w.b / w.g - 0.959) < 0.03)
	var na := PlasmaSpectrum.xyz_to_rgb(PlasmaSpectrum.cmf(589.0))
	check("589 nm is orange-yellow", na.r > na.g and na.g > 0.0 and na.b < 0.0)

	var slow = layer("Earth", 60e3, 4000.0)
	var sh = layer("Earth", 80e3, 7400.0)
	var lunar = layer("Earth", 80e3, 10800.0)
	check("air layers solved", slow != null and sh != null and lunar != null)
	if slow == null or sh == null or lunar == null:
		_done(); return
	var s1 := shares(slow)
	var c1 := PlasmaSpectrum.colour(slow)
	check("4 km/s: N₂ first positive %.2f of the power, colour red (%.2f, %.2f, %.2f)" % [s1.N2_1P, c1.r, c1.g, c1.b],
		s1.N2_1P > 0.9 and c1.r == 1.0 and c1.g < 0.25 and c1.b < 0.05)
	var ion := Ionisation.normal_shock(Rocketry.profile(Rocketry.ATMOSPHERES.Earth, 80e3)[0],
		Rocketry.profile(Rocketry.ATMOSPHERES.Earth, 80e3)[1], 7400.0)
	check("air takes Ionisation's state (%.0f K)" % sh.T, absf(float(sh.T) - float(ion.T)) < 1.0)
	var s2 := shares(sh)
	var c2 := PlasmaSpectrum.colour(sh)
	check("Shuttle 7.4 km/s at 80 km: N₂⁺ 1st negative + N₂ 1st positive %.2f, pink-magenta (%.2f, %.2f, %.2f)" % [s2.N2p1N + s2.N2_1P, c2.r, c2.g, c2.b],
		s2.N2p1N + s2.N2_1P > 0.8 and c2.b > 0.5 * c2.r and c2.g < 0.2)
	var c3 := PlasmaSpectrum.colour(lunar)
	var s3 := shares(lunar)
	check("lunar return at 10.8 km/s: atomic N and O lines %.2f, bluer than the Shuttle (B/R %.2f > %.2f)" % [s3.N868 + s3.O777 + s3.O845, c3.b / c3.r, c2.b / c2.r],
		s3.N868 + s3.O777 + s3.O845 > 0.8 and c3.b / c3.r > c2.b / c2.r)

	# The CO₂ and N₂–CH₄ jump: mass, momentum and energy across the shock.
	for c in [["Mars", 40e3, 6000.0], ["Venus", 100e3, 10000.0], ["Titan", 300e3, 6000.0]]:
		var atm = U.merged({"g": 9.8, "R": 6.37e6}, Rocketry.ATMOSPHERES[c[0]])
		var pr := Rocketry.profile(atm, c[1])
		var rho1 := float(pr[0])
		var T1 := float(pr[1])
		var st = layer(c[0], c[1], c[2])
		if st == null:
			check("%s layer solved" % c[0], false); continue
		var gas := "co2" if c[0] != "Titan" else "n2ch4"
		var comp: Dictionary = PlasmaSpectrum.COMPOSITION[c[0]]
		var m1 := PlasmaSpectrum._mix(gas, comp, T1, rho1)
		var m2 := PlasmaSpectrum._mix(gas, comp, float(st.T), float(st.rho))
		var V: float = c[2]
		var u2: float = V * rho1 / float(st.rho)
		var p1: float = rho1 * float(m1.R) * T1
		var p2: float = float(st.rho) * float(m2.R) * float(st.T)
		var mom: float = absf((p1 + rho1 * V * V) - (p2 + float(st.rho) * u2 * u2)) / (rho1 * V * V)
		var en: float = absf((float(m1.h) + 0.5 * V * V) - (float(m2.h) + 0.5 * u2 * u2)) / (0.5 * V * V)
		check("%s at %.0f km/s: Rankine–Hugoniot residuals momentum %s, energy %s, %.0f K" % [c[0], V / 1000.0, String.num_scientific(mom), String.num_scientific(en), st.T],
			mom < 2e-3 and en < 2e-3 and float(st.T) < 12000.0)
	var mars = layer("Mars", 40e3, 6000.0)
	if mars != null:
		var sm := shares(mars)
		check("Mars at 6 km/s: CN violet + red %.2f of the power" % (sm.CNviolet + sm.CNred), sm.CNviolet + sm.CNred > 0.8)
	var titan = layer("Titan", 300e3, 6000.0)
	if titan != null:
		var st := shares(titan)
		check("Titan at 6 km/s: CN %.2f of the power" % (st.CNviolet + st.CNred), st.CNviolet + st.CNred > 0.8)

	# The shader's terms reproduce the CPU colour at the layer's T and as it cools.
	for st in [sh, lunar, mars]:
		if st == null: continue
		var terms := PlasmaSpectrum.shader_terms(st)
		for f: float in [1.0, 0.8, 0.6]:
			var T: float = float(st.T) * f
			var want := PlasmaSpectrum.colour(st, T)
			var got := shader_colour(terms, float(st.T), T)
			var d := maxf(maxf(absf(want.r - got.r), absf(want.g - got.g)), absf(want.b - got.b))
			check("shader terms at %.0f K (%.1f T_s): %.3f from the full sum" % [T, f, d], d < 1e-4)
	_done()

func _done() -> void:
	print("PLASMACHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures > 0 else 0)
