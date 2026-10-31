class_name PlasmaSpectrum
extends RefCounted

# The shock layer's visible emission: lines and band systems whose upper levels are
# populated as Boltzmann gives at the equilibrium temperature behind a normal shock,
# plus free–free continuum, turned to linear sRGB through the CIE 1931 functions.
# Air takes its state from Ionisation; CO₂ (Mars, Venus) and N₂–CH₄ (Titan) layers
# from the small equilibrium below. Derivation, data and limits:
# docs/physics/entry-plasma.md#the-colour.

const K_B := 1.380649e-23
const H_C := 1.98644586e-25         # h·c, J·m
const N_A := 6.02214076e23
const P_REF := 1e5                  # Pa: the standard state the Kp below are for

# An emitter: the species carrying its upper level, that level's energy above the
# species' ground state (K), its degeneracy g_u over the ground's g₀, the system's
# Einstein A (s⁻¹), and its visible lines or band heads [nm, share of the power].
# Atomic data: NIST ASD. Molecular systems: Laux (1993) and Lofthus & Krupenie (1977)
# for N₂ and N₂⁺, Huber & Herzberg for CN, C₂ and CO; vibrational structure is folded
# into the shares, the population into the electronic factor. UV systems (NO γ and β,
# O₂ Schumann–Runge, CO fourth positive) emit nothing the eye sees and are left out.
const EMITTERS := {
	"O777": {"sp": "O", "theta": 124660.0, "g": 15.0 / 9.0, "A": 3.69e7, "lines": [[777.4, 1.0]]},
	"O845": {"sp": "O", "theta": 127530.0, "g": 9.0 / 9.0, "A": 3.22e7, "lines": [[844.6, 1.0]]},
	"N868": {"sp": "N", "theta": 137000.0, "g": 32.0 / 4.0, "A": 2.5e7,
		"lines": [[746.8, 0.35], [821.6, 0.30], [868.0, 0.35]]},
	"H656": {"sp": "H", "theta": 140300.0, "g": 18.0 / 2.0, "A": 4.41e7, "lines": [[656.3, 1.0]]},
	"N2p1N": {"sp": "N2+", "theta": 36800.0, "g": 1.0, "A": 1.6e7,
		"lines": [[358.2, 0.05], [391.4, 0.62], [427.8, 0.25], [470.9, 0.08]]},
	"N2_1P": {"sp": "N2", "theta": 85700.0, "g": 6.0, "A": 1.5e5,
		"lines": [[580.0, 0.08], [595.0, 0.10], [632.0, 0.15], [654.0, 0.20], [670.0, 0.15],
			[750.0, 0.17], [775.0, 0.07], [870.0, 0.08]]},
	"N2_2P": {"sp": "N2", "theta": 128000.0, "g": 6.0, "A": 2.7e7,
		"lines": [[315.9, 0.20], [337.1, 0.38], [357.7, 0.25], [380.5, 0.12], [405.9, 0.05]]},
	"CNviolet": {"sp": "CN", "theta": 37050.0, "g": 1.0, "A": 1.5e7,
		"lines": [[359.0, 0.10], [388.3, 0.62], [421.6, 0.22], [460.6, 0.06]]},
	"CNred": {"sp": "CN", "theta": 13300.0, "g": 2.0, "A": 1.5e5,
		"lines": [[650.0, 0.20], [700.0, 0.20], [790.0, 0.30], [920.0, 0.30]]},
	"C2swan": {"sp": "C2", "theta": 29800.0, "g": 6.0, "A": 7.6e6,
		"lines": [[438.3, 0.05], [473.7, 0.20], [516.5, 0.45], [563.6, 0.20], [619.1, 0.10]]},
	"COang": {"sp": "CO", "theta": 125100.0, "g": 1.0, "A": 1.1e7,
		"lines": [[451.1, 0.20], [483.5, 0.35], [519.8, 0.25], [561.0, 0.12], [608.0, 0.08]]},
}
const SETS := {
	"air": ["O777", "O845", "N868", "N2p1N", "N2_1P", "N2_2P"],
	"co2": ["O777", "O845", "COang", "CNviolet", "CNred", "C2swan", "N2_1P"],
	"n2ch4": ["N868", "H656", "N2p1N", "N2_1P", "N2_2P", "CNviolet", "CNred", "C2swan"],
}
# Volume fractions of the gases the non-air layers are made from (Mars: Franz et al.
# 2017; Venus: von Zahn et al. 1983; Titan: Niemann et al. 2010, at the surface).
const COMPOSITION := {
	"Mars": {"co2": 0.953, "n2": 0.027}, "Venus": {"co2": 0.965, "n2": 0.035},
	"Titan": {"n2": 0.984, "ch4": 0.0148},
}
# Dissociation equilibria A ⇌ B + C as Kp = exp(ΔS/R − ΔH/RT) bar, with ΔH (as K) and ΔS
# (J/mol/K) at 298 K from JANAF; within a factor of ~2 at shock-layer temperatures.
const KP := {
	"CO2": [64010.0, 144.93],   # CO₂ ⇌ CO + O
	"CO": [128900.0, 121.5],    # CO ⇌ C + O
	"CN": [90200.0, 108.8],     # CN ⇌ C + N
	"C2": [73000.0, 116.8],     # C₂ ⇌ 2C
}
const I_N2 := 180800.0          # N₂ ionisation energy, K (15.58 eV); 2g₊/g₀ = 4
const I_O := 158030.0
const I_N := 168660.0

## Which emitter set an atmosphere's shock layer uses, or "" for none.
static func gas_of(atm) -> String:
	if atm == null: return ""
	var g := str(atm.get("plasma", atm.get("radiative", "")))
	return g if SETS.has(g) else ""

static func kp(key: String, T: float) -> float:
	var k: Array = KP[key]
	return exp(float(k[1]) / Ionisation.R_GAS - float(k[0]) / T)

## The shock layer's species, m⁻³, and its temperature, for free stream ρ₁, T₁ and
## speed V, as {T, rho, n: {species: m⁻³}}; null when there is no shock or no gas.
static func shock_state(atm, rho1: float, T1: float, V: float, body_name := ""):
	var gas := gas_of(atm)
	if gas == "" or rho1 <= 0.0: return null
	if gas == "air":
		var s := Ionisation.normal_shock(rho1, T1, V)
		if float(s.ne) <= 0.0 and float(s.T) < 1500.0: return null
		var n := Ionisation.species(float(s.T), float(s.rho), s.alpha)
		n["N2+"] = float(n.N2) * _saha(float(s.T), 4.0, I_N2) / maxf(float(n.e), 1.0)
		return {"T": s.T, "rho": s.rho, "n": n, "gas": gas}
	var comp: Dictionary = COMPOSITION.get(body_name, COMPOSITION.Mars if gas == "co2" else COMPOSITION.Titan)
	var s2 = _shock(gas, comp, rho1, T1, V)
	if s2 == null: return null
	return s2

## Linear sRGB of a unit of each emitter's power, and the power per m³ (W) each gives
## in the layer `st` at temperature T (populations at T, densities frozen as `st`
## found them). [[name, Color, P, theta]], free–free last.
static func emission(st: Dictionary, T := -1.0) -> Array:
	if T <= 0.0: T = float(st.T)
	var n: Dictionary = st.n
	var out := []
	for key in SETS[str(st.gas)]:
		var e: Dictionary = EMITTERS[key]
		var ns := float(n.get(e.sp, 0.0))
		if ns <= 0.0: continue
		var rgb := Color(0, 0, 0)
		var p := 0.0
		for ln: Array in e.lines:
			var lam := float(ln[0]) * 1e-9
			var w := float(ln[1]) * H_C / lam
			p += w
			rgb += xyz_to_rgb(cmf(float(ln[0]))) * w
		var q := 1.0
		if key == "C2swan": q = 1.0 + 6.0 * exp(-1030.0 / T)   # the a³Πᵤ level 0.09 eV up
		var P := ns * float(e.g) / q * exp(-float(e.theta) / T) * float(e.A) * p
		out.append([key, rgb / maxf(p, 1e-60), P, float(e.theta)])
	# Free–free at the layer's own T, then carried to T as the other emitters are: its
	# electrons re-equilibrate, n_e² ∝ e^(−I/T) for the ion that supplies them (NO⁺ in
	# air), and e^(−hc/λkT) at 550 nm.
	var Ts := float(st.T)
	var I: float = {"air": float(Ionisation.IONS.NO[0]), "co2": I_O}.get(str(st.gas), I_N)
	var th_ff := I + H_C / (550e-9 * K_B)
	out.append(["ff", _ff_colour(Ts), _ff_power(float(n.get("e", 0.0)), Ts) * exp(th_ff * (1.0 / Ts - 1.0 / T)), th_ff])
	return out

## Linear sRGB of the layer at temperature T, brightest channel 1.
static func colour(st: Dictionary, T := -1.0) -> Color:
	var c := Color(0, 0, 0, 1)
	for e: Array in emission(st, T):
		c += (e[1] as Color) * float(e[2])
	# A line outside sRGB's gamut is desaturated toward white, keeping its hue.
	var lo := minf(minf(c.r, c.g), c.b)
	if lo < 0.0: c = Color(c.r - lo, c.g - lo, c.b - lo)
	var m := maxf(maxf(c.r, c.g), c.b)
	if not (m > 0.0): return Color(1.0, 0.13, 0.03)
	return Color(c.r / m, c.g / m, c.b / m)

## The shader's terms, one per emitter (the largest set and free–free fill
## EMITTER_SLOTS): [rgb (unit power), power at the layer's T relative to the strongest,
## θ (K)].
const EMITTER_SLOTS := 9
static func shader_terms(st: Dictionary) -> Array:
	var em := emission(st)
	var top := 0.0
	for e: Array in em: top = maxf(top, float(e[2]))
	var out := []
	for e: Array in em: out.append([e[1], float(e[2]) / maxf(top, 1e-60), float(e[3])])
	return out

# CIE 1931 2° observer, the multi-lobe Gaussian fit of Wyman, Sloan & Shirley (2013).
static func _g(x: float, mu: float, s1: float, s2: float) -> float:
	var t := (x - mu) / (s1 if x < mu else s2)
	return exp(-0.5 * t * t)

static func cmf(nm: float) -> Vector3:
	return Vector3(
		1.056 * _g(nm, 599.8, 37.9, 31.0) + 0.362 * _g(nm, 442.0, 16.0, 26.7) - 0.065 * _g(nm, 501.1, 20.4, 26.2),
		0.821 * _g(nm, 568.8, 46.9, 40.5) + 0.286 * _g(nm, 530.9, 16.3, 31.1),
		1.217 * _g(nm, 437.0, 11.8, 36.0) + 0.681 * _g(nm, 459.0, 26.0, 13.8))

## XYZ → linear sRGB (D65), unclipped.
static func xyz_to_rgb(x: Vector3) -> Color:
	return Color(3.2406 * x.x - 1.5372 * x.y - 0.4986 * x.z,
		-0.9689 * x.x + 1.8758 * x.y + 0.0415 * x.z,
		0.0557 * x.x - 0.2040 * x.y + 1.0570 * x.z)

# Free–free (Kramers, Gaunt factor 1): 4πj_ν = 6.8e-51·n_e·n₊·T^−½·e^(−hν/kT) W/m³/Hz,
# singly charged ions, n₊ = n_e. Integrated over 380–780 nm for its power and colour.
static func _ff_power(ne: float, T: float) -> float:
	if ne <= 0.0: return 0.0
	var p := 0.0
	for i in 41:
		var lam := (380.0 + 10.0 * i) * 1e-9
		p += exp(-H_C / (lam * K_B * T)) * 2.998e8 / (lam * lam) * 10e-9
	return 6.8e-51 * ne * ne / sqrt(T) * p

static func _ff_colour(T: float) -> Color:
	var c := Color(0, 0, 0)
	var p := 0.0
	for i in 41:
		var nm := 380.0 + 10.0 * i
		var w := exp(-H_C / (nm * 1e-9 * K_B * T)) / (nm * nm)
		c += xyz_to_rgb(cmf(nm)) * w
		p += w
	return c / maxf(p, 1e-60)

## Saha's n₊n_e/n₀, m⁻³, for 2g₊/g₀ = `gr` and ionisation energy I (K).
static func _saha(T: float, gr: float, I: float) -> float:
	return 2.4147e21 * pow(T, 1.5) * gr * exp(-I / T)

# A CO₂ or N₂–CH₄ layer: CO₂ ⇌ CO + O, CO ⇌ C + O and N₂ ⇌ 2N (Lighthill's N₂ constants)
# carry the energy, against a rigid-rotor, fully excited heat capacity (CO₂ 7.5R, CO and
# N₂ 4.5R, atoms 2.5R); CH₄ is counted as broken into C + 4H, and the trace species
# (CN, C₂, and C in N₂–CH₄) follow from the KP equilibria without feeding back.
# Ionisation's energy is left out, so above ~9 km/s the layer runs hot. The jump is
# iterated on ε = ρ₁/ρ₂ as Ionisation does for air.
static func _shock(gas: String, comp: Dictionary, rho1: float, T1: float, V: float):
	var m1 := _mix(gas, comp, T1, rho1)
	var p1 := rho1 * float(m1.R) * T1
	var M1 := V / sqrt(1.3 * float(m1.R) * T1)
	if M1 <= 1.0: return null
	var eps := (0.3 * M1 * M1 + 2.0) / (2.3 * M1 * M1)
	var rho2 := rho1 / eps
	var T := T1
	var mix := m1
	for it in 60:
		var p2 := p1 + rho1 * V * V * (1.0 - eps)
		var h2 := float(m1.h) + 0.5 * V * V * (1.0 - eps * eps)
		var lo := T1
		var hi := 60000.0
		for k in 60:
			T = 0.5 * (lo + hi)
			if float(_mix(gas, comp, T, rho2).h) > h2: hi = T
			else: lo = T
		mix = _mix(gas, comp, T, rho2)
		var eps_new := rho1 * float(mix.R) * T / p2
		if absf(eps_new - eps) < 1e-6 * eps: break
		eps = 0.5 * (eps + eps_new)
		rho2 = rho1 / eps
	if T < 1500.0: return null
	return {"T": T, "rho": rho2, "n": mix.n, "gas": gas}

## {h (J/kg), R (J/kg/K), n} of the layer gas at T and ρ, energies from undissociated
## CO₂/N₂ at 0 K.
static func _mix(gas: String, comp: Dictionary, T: float, rho: float) -> Dictionary:
	var R := Ionisation.R_GAS
	var x_co2 := float(comp.get("co2", 0.0))
	var x_n2 := float(comp.get("n2", 0.0))
	var x_ch4 := float(comp.get("ch4", 0.0))
	var mol := x_co2 * 0.04401 + x_n2 * 0.028013 + x_ch4 * 0.01604     # kg per mole of feed
	var n_feed := rho / mol * N_A                                       # feed molecules per m³
	# N₂ by Lighthill, its mass fraction held at the feed's.
	var y_n2 := x_n2 * 0.028013 / mol
	var kn: float = 130e3 / maxf(rho * y_n2, 1e-30) * exp(-113000.0 / T)
	var a_n := 0.5 * (-kn + sqrt(kn * kn + 4.0 * kn)) if kn < 1e12 else 1.0
	# CO₂ → CO + O (fraction a) and that CO → C + O (fraction b) at the layer's pressure,
	# which depends on both: a²(1 − b²)/(1 − a) = A₁ and ab(1 + b)/(1 − b) = A₂, with
	# A = Kp·(moles per feed)/(x_CO₂·p), solved in turn.
	var a_c := 0.0
	var b_c := 0.0
	if x_co2 > 0.0:
		var K1 := kp("CO2", T) * P_REF
		var K2 := kp("CO", T) * P_REF
		for i in 40:
			var moles := x_co2 * (1.0 + a_c + a_c * b_c) + x_n2 * (1.0 + a_n) + x_ch4 * 5.0
			var p := n_feed * moles * K_B * T
			var A1 := K1 * moles / (p * x_co2)
			var A2 := K2 * moles / (p * x_co2)
			var q := maxf(1.0 - b_c * b_c, 1e-12)
			var a_new := (-A1 + sqrt(A1 * A1 + 4.0 * q * A1)) / (2.0 * q)
			var b_new := (-(a_new + A2) + sqrt((a_new + A2) * (a_new + A2) + 4.0 * a_new * A2)) / (2.0 * maxf(a_new, 1e-30))
			var done := absf(a_new - a_c) < 1e-9 and absf(b_new - b_c) < 1e-9
			a_c = a_new; b_c = clampf(b_new, 0.0, 1.0)
			if done: break
	var per := {}   # molecules per feed molecule
	per["CO2"] = x_co2 * (1.0 - a_c)
	per["CO"] = x_co2 * a_c * (1.0 - b_c)
	per["C"] = x_co2 * a_c * b_c
	per["O"] = x_co2 * a_c * (1.0 + b_c)
	per["N2"] = x_n2 * (1.0 - a_n)
	per["N"] = 2.0 * x_n2 * a_n
	per["H"] = 4.0 * x_ch4
	var total := 0.0
	for k in per: total += float(per[k])
	var p_tot := n_feed * total * K_B * T
	var h := (x_co2 * (1.0 - a_c) * 7.5 + x_co2 * a_c * (1.0 - b_c) * 4.5 + x_co2 * a_c * (1.0 + 2.0 * b_c) * 2.5
		+ x_n2 * (1.0 - a_n) * 4.5 + 2.0 * x_n2 * a_n * 2.5 + x_ch4 * 12.5) * R * T
	h += x_co2 * a_c * 64010.0 * R + x_co2 * a_c * b_c * 128900.0 * R + x_n2 * a_n * 113000.0 * R
	var n := {}
	for k in per: n[k] = float(per[k]) * n_feed
	# Carbon's traces, in partial pressures (bar).
	var pb := func(k: String) -> float: return float(n.get(k, 0.0)) * K_B * T / P_REF
	var p_c: float = pb.call("C")
	var p_cn := 0.0
	if x_ch4 > 0.0:
		var c_tot := x_ch4 * n_feed * K_B * T / P_REF
		p_c = c_tot / (1.0 + pb.call("N") / kp("CN", T))
	p_cn = p_c * pb.call("N") / kp("CN", T)
	n["C"] = p_c * P_REF / (K_B * T)
	n["CN"] = p_cn * P_REF / (K_B * T)
	n["C2"] = p_c * p_c / kp("C2", T) * P_REF / (K_B * T)
	# Electrons from the most easily ionised atom present, weakly (n_e² = n₀S).
	var atom := "O" if x_co2 > 0.0 else "N"
	n["e"] = sqrt(float(n.get(atom, 0.0)) * _saha(T, 0.889 if atom == "O" else 4.5, I_O if atom == "O" else I_N))
	return {"h": h / (mol / 1.0), "R": total * R / mol, "n": n}
