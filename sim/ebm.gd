class_name LatitudeEBM
extends RefCounted

# Budyko–Sellers energy balance in latitude, North's (1975) diffusive form:
#   C ∂T/∂t = Q·s(x)·a(T) − (A + B·T) + D ∂/∂x[(1 − x²) ∂T/∂x],   x = sin φ
# with s(x) = 1 + s2·P2(x) (RockyVisual.insolation_s2) and the coalbedo a dropping
# where T < −10 °C. One hemisphere, symmetric about the equator. Implicit in time, so
# a frame of any length is stable; the ice edge carries the state, and with it the
# snowball hysteresis. docs/physics/climate.md#ice-lines-and-the-snowball.

const N := 60
# North, Cahalan & Coakley (1981): B = 2.09 W m⁻² K⁻¹ (OLR per °C), the ice edge at −10 °C
# and their coalbedos. A follows the world's greenhouse (Climate); D puts present
# Earth's ice edge at 72°, as theirs is. A slightly larger D melts the cap altogether:
# the small-ice-cap instability (North 1984).
const B := 2.09
const D := 0.55
const T_ICE := -10.0
# Ice-free coalbedo a₀ + a₂·P2(x): lower toward the poles, where the Sun is low.
const COALBEDO_FREE := 0.697
const COALBEDO_P2 := -0.0779
const COALBEDO_ICE := 0.38

var T := PackedFloat64Array()      # °C at cell centres x = (i + ½)/N
var _a := PackedFloat64Array(); var _b := PackedFloat64Array(); var _c := PackedFloat64Array(); var _r := PackedFloat64Array()

func _init(T0_c: float = 14.0) -> void:
	for arr in [T, _a, _b, _c, _r]: arr.resize(N)
	reset(T0_c)

func reset(T0_c: float) -> void:
	for i in N: T[i] = T0_c - 30.0 * pow((i + 0.5) / N, 2.0)

## Advance `dt_s` seconds under mean insolation Q (W/m², S/4), insolation shape s2,
## OLR intercept A (W/m² at 0 °C) and column heat capacity C (J m⁻² K⁻¹).
func step(dt_s: float, Q: float, s2: float, A: float, C: float) -> void:
	var dx := 1.0 / N
	var k := C / dt_s
	for i in N:
		var x := (i + 0.5) * dx
		var s := 1.0 + s2 * 0.5 * (3.0 * x * x - 1.0)
		var p2 := 0.5 * (3.0 * x * x - 1.0)
		var co := COALBEDO_ICE if T[i] < T_ICE else COALBEDO_FREE + COALBEDO_P2 * p2
		var w_lo := D * (1.0 - pow(i * dx, 2.0)) / (dx * dx) if i > 0 else 0.0
		var w_hi := D * (1.0 - pow((i + 1) * dx, 2.0)) / (dx * dx) if i < N - 1 else 0.0
		_a[i] = -w_lo
		_c[i] = -w_hi
		_b[i] = k + B + w_lo + w_hi
		_r[i] = k * T[i] + Q * s * co - A
	# Thomas algorithm.
	for i in range(1, N):
		var m := _a[i] / _b[i - 1]
		_b[i] -= m * _c[i - 1]
		_r[i] -= m * _r[i - 1]
	T[N - 1] = _r[N - 1] / _b[N - 1]
	for i in range(N - 2, -1, -1):
		T[i] = (_r[i] - _c[i] * T[i + 1]) / _b[i]

## Relax to equilibrium from the present state (keeping which branch it is on).
func settle(Q: float, s2: float, A: float, C: float = 4e8) -> void:
	for it in 400: step(5.0 * Rocketry.YR_S, Q, s2, A, C)

## sin of the ice edge's latitude: 1 with no ice, 0 when frozen to the equator (or,
## with the poles warmer, as past 54.7° of obliquity, where the ice starts).
func ice_edge() -> float:
	var warm_pole := T[N - 1] > T[0]
	for j in N:
		var i := N - 1 - j if not warm_pole else j
		if T[i] >= T_ICE: return float(i + 1) / N if not warm_pole else float(i) / N
	return 0.0

## Fraction of the surface under ice.
func ice_fraction() -> float:
	var f := 0.0
	for i in N: if T[i] < T_ICE: f += 1.0
	return f / N

func snowball() -> bool:
	return ice_fraction() >= 1.0

## Area-mean temperature, °C.
func mean_c() -> float:
	var t := 0.0
	for i in N: t += T[i]
	return t / N
