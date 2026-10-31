class_name Ionisation
extends RefCounted

# Equilibrium air behind a normal shock and its free electrons, for radio blackout.
# Lighthill's ideal dissociating gas for N₂ and O₂, NO from N₂ + O₂ ⇌ 2NO, and Saha
# for NO, N and O. Derivation and checks: docs/physics/entry-plasma.md#radio-blackout.

const K_B := 1.380649e-23
const AMU := 1.66053907e-27
const R_GAS := 8.31446261815324
# Lighthill: characteristic dissociation temperature θ_d (K) and density ρ_d (kg/m³),
# per Vincenti & Kruger (1965) table 8.1; mass fraction in air; molar mass (kg/mol).
const DIATOMS := [
	{"theta": 113000.0, "rho_d": 130e3, "y": 0.767, "M": 0.028013},   # N₂
	{"theta": 59500.0, "rho_d": 150e3, "y": 0.233, "M": 0.031999},    # O₂
]
# N₂ + O₂ ⇌ 2NO: ΔH = 180.6 kJ/mol and ΔS = 24.8 J/mol/K (JANAF, 298 K).
const NO_K0 := 19.7
const NO_THETA := 21720.0
# Saha: ionisation energy (K) and 2g₊/g₀ for NO, N and O.
const IONS := {"NO": [107500.0, 0.5], "N": [168660.0, 4.5], "O": [158030.0, 0.889]}
# S-band (2287.5 MHz, Apollo's and the Shuttle's downlink): f_p = 8.98·√n_e Hz.
const S_BAND_HZ := 2.2875e9

## The electron density at which a link at `freq_hz` is reflected, m⁻³.
static func critical_density(freq_hz: float = S_BAND_HZ) -> float:
	return pow(freq_hz / 8.979, 2.0)

## Air's dissociated fractions [α_N₂, α_O₂] at temperature T and density ρ.
static func _alphas(T: float, rho: float) -> Array:
	var out := []
	for d in DIATOMS:
		var k: float = float(d.rho_d) / maxf(rho * float(d.y), 1e-30) * exp(-float(d.theta) / T)
		# α²/(1 − α) = k
		out.append(0.5 * (-k + sqrt(k * k + 4.0 * k)) if k < 1e12 else 1.0)
	return out

## Specific enthalpy (J/kg), gas constant (J/kg/K), dissociated fractions and free
## electrons (m⁻³) of air at T and ρ. Ionisation's energy and its electrons count.
static func _mix(T: float, rho: float) -> Array:
	var a := _alphas(T, rho)
	var h := 0.0
	var R := 0.0
	for i in DIATOMS.size():
		var d: Dictionary = DIATOMS[i]
		var Rs: float = R_GAS / float(d.M)
		var ai := float(a[i])
		h += float(d.y) * Rs * ((4.0 + 2.0 * ai) * T + ai * float(d.theta))
		R += float(d.y) * Rs * (1.0 + ai)
	var ion := _saha(T, rho, a)
	h += (float(ion[1]) + 2.5 * float(ion[0]) * T) * K_B / rho
	R += float(ion[0]) * K_B / rho
	return [h, R, a, ion[0]]

## [n_e (m⁻³), Σ n₊·I/k (K/m³)] for air at T and ρ with dissociated fractions α.
static func _saha(T: float, rho: float, alpha: Array) -> Array:
	var aN := float(alpha[0]); var aO := float(alpha[1])
	var n_n2 := rho * 0.767 * (1.0 - aN) / (0.028013 / 6.02214076e23)
	var n_o2 := rho * 0.233 * (1.0 - aO) / (0.031999 / 6.02214076e23)
	var nN := rho * 0.767 * aN / (0.0140067 / 6.02214076e23)
	var nO := rho * 0.233 * aO / (0.0159994 / 6.02214076e23)
	var tot := n_n2 + n_o2 + nN + nO
	var n_no := sqrt(NO_K0 * exp(-NO_THETA / T) * n_n2 * n_o2)
	var neutral := {"NO": n_no, "N": nN, "O": nO}
	var S := {}
	var ne := 0.0
	for k in IONS:
		S[k] = 2.4147e21 * pow(T, 1.5) * float(IONS[k][1]) * exp(-float(IONS[k][0]) / T)
		ne += float(neutral[k]) * float(S[k])
	# Charge balance n_e = Σ n₀S/(n_e + S) by Newton from the weak-ionisation root,
	# which lies above the solution, so the iteration descends to it monotonically.
	ne = minf(sqrt(ne), tot)
	for it in 30:
		var f := ne
		var df := 1.0
		for k in IONS:
			var sk: float = S[k]
			var q := float(neutral[k]) * sk / (ne + sk)
			f -= q
			df += q / (ne + sk)
		var step := f / df
		ne -= step
		if absf(step) <= 1e-10 * ne: break
	var e_ion := 0.0
	for k in IONS: e_ion += float(neutral[k]) * float(S[k]) / (ne + float(S[k])) * float(IONS[k][0])
	return [ne, e_ion]

## Number densities (m⁻³) of N₂, O₂, N, O, NO and electrons in air at T, ρ and
## dissociated fractions α, as _saha counts them.
static func species(T: float, rho: float, alpha: Array) -> Dictionary:
	var aN := float(alpha[0]); var aO := float(alpha[1])
	var n_n2 := rho * 0.767 * (1.0 - aN) / (0.028013 / 6.02214076e23)
	var n_o2 := rho * 0.233 * (1.0 - aO) / (0.031999 / 6.02214076e23)
	return {"N2": n_n2, "O2": n_o2,
		"N": rho * 0.767 * aN / (0.0140067 / 6.02214076e23), "O": rho * 0.233 * aO / (0.0159994 / 6.02214076e23),
		"NO": sqrt(NO_K0 * exp(-NO_THETA / T) * n_n2 * n_o2), "e": float(_saha(T, rho, alpha)[0])}

## Post-shock state for free-stream density rho1 (kg/m³), temperature T1 (K) and
## speed V (m/s): {T, rho, p, alpha, ne}. Weak shocks fall back to γ = 1.4.
static func normal_shock(rho1: float, T1: float, V: float) -> Dictionary:
	var m1 := _mix(T1, rho1)
	var R1: float = m1[1]
	var p1 := rho1 * R1 * T1
	var h1: float = m1[0]
	var M1 := V / sqrt(1.4 * R1 * T1)
	if M1 <= 1.0: return {"T": T1, "rho": rho1, "p": p1, "alpha": [0.0, 0.0], "ne": 0.0}
	# The γ = 1.4 jump first, then ε = ρ₁/ρ₂ iterated against the real enthalpy.
	var eps := ((1.4 - 1.0) * M1 * M1 + 2.0) / ((1.4 + 1.0) * M1 * M1)
	var T := T1
	var rho2 := rho1 / eps
	var p2 := p1
	var mix := m1
	for it in 60:
		p2 = p1 + rho1 * V * V * (1.0 - eps)
		var h2 := h1 + 0.5 * V * V * (1.0 - eps * eps)
		# Secant on h(T) = h₂ from the last temperature; h rises steeply and smoothly in T.
		var ta := maxf(T, T1 * 1.5)
		var tb := ta * 1.2
		var fa := float(_mix(ta, rho2)[0]) - h2
		var fb := float(_mix(tb, rho2)[0]) - h2
		for k in 40:
			if fb == fa: break
			var tc := clampf(tb - fb * (tb - ta) / (fb - fa), T1, 80000.0)
			ta = tb; fa = fb
			tb = tc; fb = float(_mix(tb, rho2)[0]) - h2
			if absf(tb - ta) < 1e-6 * tb: break
		T = tb
		mix = _mix(T, rho2)
		var eps_new := rho1 * float(mix[1]) * T / p2
		if absf(eps_new - eps) < 1e-7 * eps:
			eps = eps_new; rho2 = rho1 / eps
			break
		eps = 0.5 * (eps + eps_new)
		rho2 = rho1 / eps
	return {"T": T, "rho": rho2, "p": p2, "alpha": mix[2], "ne": mix[3]}

## Electron density behind the bow shock at altitude h and air speed V, m⁻³; zero
## outside air whose chemistry this models (`radiative: "air"`).
static func shock_layer_ne(atm, h: float, V: float) -> float:
	if atm == null or atm.get("radiative") != "air" or V < 2000.0: return 0.0
	var pr := Rocketry.profile(atm, h)
	if float(pr[0]) <= 0.0: return 0.0
	return float(normal_shock(pr[0], pr[1], V).ne)
