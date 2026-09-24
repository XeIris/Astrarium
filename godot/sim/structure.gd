class_name Structure
extends RefCounted

# ============================================================================
# SEED FILE — the two ZAMS relations sim/stellar.gd needs, ported exactly, so
# the foundation compiles. The physics-core port REPLACES this file with the
# whole of sim/structure.js (keep these two functions' names and behaviour).
# ============================================================================

# Above 20 M☉ no single power law works: the slope of the mass–luminosity
# relation falls from 3.5 toward ~1.4 as massive stars approach the Eddington
# ceiling. Rather than extrapolate a power law past where it is calibrated,
# interpolate in log–log through anchors read off the Geneva rotating grids
# (Ekström et al. 2012; Yusof et al. 2013 for the very massive end).
const MASSIVE_L := [
	[20.0, 5.01e4], [30.0, 1.41e5], [40.0, 2.82e5], [60.0, 5.62e5],
	[85.0, 1.00e6], [120.0, 1.58e6], [150.0, 2.00e6], [200.0, 3.02e6], [300.0, 5.01e6],
]

static func base_luminosity(mass_sun: float, Z: float = 0.014) -> float:
	var m := maxf(mass_sun, 0.02)
	var L: float
	if m < 0.43: L = 0.23 * pow(m, 2.3)
	elif m < 2.0: L = pow(m, 4.0)
	elif m < 20.0: L = 1.4 * pow(m, 3.5)
	else:
		var A := MASSIVE_L
		if m >= A[A.size() - 1][0]:
			var m0: float = A[A.size() - 1][0]; var L0: float = A[A.size() - 1][1]
			L = L0 * pow(m / m0, 1.4)
		else:
			var i := 0
			while A[i + 1][0] < m: i += 1
			var m0: float = A[i][0]; var L0: float = A[i][1]
			var m1: float = A[i + 1][0]; var L1: float = A[i + 1][1]
			var t := (log(m) - log(m0)) / (log(m1) - log(m0))
			L = exp(log(L0) * (1.0 - t) + log(L1) * t)
	# Metal-poor stars are more transparent, so they are hotter and brighter at
	# fixed mass — a weak but real dependence.
	return L * pow(0.014 / maxf(Z, 1e-4), 0.12)

static func base_radius_sun(mass_sun: float) -> float:
	var m := maxf(mass_sun, 0.05)
	return pow(m, 0.8) if m < 1.0 else pow(m, 0.57)
