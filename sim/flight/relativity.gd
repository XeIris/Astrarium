class_name Relativity
extends RefCounted

# ============================================================================
# RELATIVISTIC CRUISE
# ----------------------------------------------------------------------------
# Interstellar flight is a different physical regime from everything else in
# sim/flight/, and it gets its own integrator rather than a relativistic patch
# on the Newtonian one. Between stars there is no gravity worth the name, the
# motion is one-dimensional along the target line, and the exact solution is
# available in closed form — so using it is both more accurate and simpler than
# stepping a modified momentum equation.
#
# With constant PROPER acceleration a (what the crew feels) and proper time τ:
#
#     v(τ) = c·tanh(aτ/c)          γ(τ) = cosh(aτ/c)
#     t(τ) = (c/a)·sinh(aτ/c)      d(τ) = (c²/a)·(cosh(aτ/c) − 1)
#
# The natural variable is the RAPIDITY φ = aτ/c, which adds linearly the way
# velocity does not: a flip-and-burn crossing needs total rapidity 2φ, and the
# rocket equation in these units is simply Δφ = (v_e/c)·ln(m₀/m₁). That is why
# this module thinks in rapidity throughout and only converts to a velocity at
# the very end.
#
# THE MISSION PROFILE. A flip-and-burn (accelerate to the midpoint, decelerate
# after it) is the fastest crossing but needs the most Δv. When the ship does
# not have it, the answer is not "impossible" — it is to burn to whatever
# rapidity the tanks allow, COAST, and turn over. `solve_profile` finds the
# coast fraction, and that is what makes the Hail Mary's real mission close:
# 2 000 t of astrophage on a 100 t ship gives ln(21) = 3.05 of rapidity through
# a photon drive, which is not enough for flip-and-burn over 11.9 ly but is
# comfortably enough for accelerate–coast–decelerate — arriving in 13.9 years
# of Earth time, which is what the book says the trip takes.
#
# PORT NOTES. `Cruise` is an inner class: `Relativity.Cruise.new({...})`, the
# constructor taking the JS options object as a Dictionary. Its getters (beta,
# gamma, remaining) are properties. Positions are DVec3 in AU — the Cruise is
# the one flight object that lives in the orrery's frame, because between the
# stars there is no parent body to be centred on.
# ============================================================================

const LY_M := 9.4607304725808e15            # light year, metres (exact by definition of c)
const LY_AU := LY_M / Rocketry.AU_M          # 63241.077 AU — the same number as physics.gd's C
const YEAR_S := 365.25 * 86400.0

## Rapidity → velocity fraction, and back.
static func beta_of(phi: float) -> float: return tanh(phi)
static func gamma_of(phi: float) -> float: return cosh(phi)
static func rapidity_of(beta: float) -> float:
	return atanh(minf(maxf(beta, -0.999999999), 0.999999999))

## Total rapidity a vehicle can deliver, from the relativistic rocket equation
##   Δφ = (v_e/c)·ln(m₀/m₁)
## A photon drive has v_e = c exactly, so its rapidity is just ln of the mass
## ratio — which is the cleanest statement of why interstellar flight is hard:
## every unit of rapidity costs a factor of e in mass.
static func rapidity_budget(dry_mass: float, prop_mass: float, exhaust_ms: float) -> float:
	if not (prop_mass > 0.0) or not (dry_mass > 0.0): return 0.0
	return (exhaust_ms / Rocketry.C_MS) * log((dry_mass + prop_mass) / dry_mass)

## Solve an accelerate–coast–decelerate crossing of `dist_ly` at proper
## acceleration `a` with a rapidity budget `budget`.
##
## Returns the leg rapidity actually used, the coast, and both clocks. If the
## budget is more than a flip-and-burn needs, the answer IS flip-and-burn and
## the surplus is reported rather than spent. Keys as in the JS: mode ('flip' |
## 'coast' | 'short'), phi, coastLy, tauS, coordS, gammaMax, betaMax, budget,
## used, spare, feasible, flipPhi, burnLy.
static func solve_profile(dist_ly: float, a_ms2: float, budget: float) -> Dictionary:
	var d := dist_ly * LY_M
	var ca := Rocketry.C_MS / a_ms2                        # seconds per unit rapidity
	var c2a := Rocketry.C_MS * Rocketry.C_MS / a_ms2       # metres per unit (cosh−1)

	# Flip-and-burn: each leg covers half the distance.
	var half_phi := acosh(1.0 + (d / 2.0) / c2a)
	if budget >= 2.0 * half_phi:
		var tau := 2.0 * ca * half_phi
		var t := 2.0 * ca * sinh(half_phi)
		return {
			"mode": "flip", "phi": half_phi, "coastLy": 0.0,
			"tauS": tau, "coordS": t, "gammaMax": cosh(half_phi), "betaMax": tanh(half_phi),
			"budget": budget, "used": 2.0 * half_phi, "spare": budget - 2.0 * half_phi, "feasible": true,
		}
	# Otherwise burn half the budget each way and coast the difference.
	var phi := budget / 2.0
	var leg_ly := c2a * (cosh(phi) - 1.0)
	var coast := d - 2.0 * leg_ly
	if coast < 0.0:
		# Not even enough to stop: report it honestly rather than inventing fuel.
		return { "mode": "short", "phi": phi, "coastLy": 0.0, "feasible": false, "budget": budget, "used": budget,
				 "flipPhi": 2.0 * half_phi, "tauS": INF, "coordS": INF, "gammaMax": cosh(phi), "betaMax": tanh(phi) }
	var beta := tanh(phi)
	var gamma := cosh(phi)
	var coast_coord := coast / (beta * Rocketry.C_MS)
	return {
		"mode": "coast", "phi": phi, "coastLy": coast / LY_M,
		# What the faster profile would have needed, carried out so the panel can
		# say why this ship is not flying it. Rapidity is the honest currency: the
		# mass ratio is exp(Δφ·c/v_e), which the readout finishes once it knows
		# the exhaust velocity.
		"flipPhi": 2.0 * half_phi,
		"tauS": 2.0 * ca * phi + coast_coord / gamma,
		"coordS": 2.0 * ca * sinh(phi) + coast_coord,
		"gammaMax": gamma, "betaMax": beta,
		"budget": budget, "used": budget, "spare": 0.0, "feasible": true,
		"burnLy": leg_ly / LY_M,
	}

# ============================================================================
# THE CRUISE STATE — one live interstellar flight
# ============================================================================
class Cruise extends RefCounted:
	var name: String
	var origin: DVec3            # AU, in the orrery's frame
	var dir: DVec3               # unit vector origin → target
	var dist_au: float
	var dist_ly: float
	var a: float                 # proper acceleration, m/s²
	var dry_mass: float
	var prop_mass: float
	var prop: float
	var exhaust: float
	var budget: float
	var plan: Dictionary
	# live state
	var phi: float = 0.0         # current rapidity (signed along dir)
	var s: float = 0.0           # distance travelled along dir, metres
	var tau: float = 0.0         # ship proper time, s
	var t: float = 0.0           # coordinate time, s
	var leg: String = "accel"    # accel | coast | decel | arrived
	var leg_tau: float = 0.0
	var throttle: float = 1.0
	var log: Array = []          # [{tau, m}]

	var beta: float:
		get: return tanh(phi)
	var gamma: float:
		get: return cosh(phi)
	## Metres remaining to the target.
	var remaining: float:
		get: return maxf(dist_ly * LY_M - s, 0.0)

	## opts: { origin: DVec3 (AU), target: DVec3 (AU), accel, budget?, dryMass,
	## propMass, exhaustMS, name? } — the JS constructor's option object.
	func _init(opts: Dictionary) -> void:
		name = opts.get("name") if opts.get("name") else "Cruise"
		origin = (opts.origin as DVec3).clone()
		dir = (opts.target as DVec3).clone().sub_in(opts.origin)
		dist_au = dir.length()
		DQuat.nrm(dir)
		dist_ly = dist_au / LY_AU
		a = opts.accel
		dry_mass = opts.dryMass; prop_mass = opts.propMass; prop = opts.propMass
		exhaust = opts.exhaustMS
		budget = opts.budget if opts.get("budget") != null else Relativity.rapidity_budget(dry_mass, prop_mass, exhaust)
		plan = Relativity.solve_profile(dist_ly, a, budget)

	## Position in AU, in the orrery's frame.
	func position(out: DVec3 = null) -> DVec3:
		if out == null: out = DVec3.new()
		return out.copy_from(dir).scale_in(s / Rocketry.AU_M).add_in(origin)

	## Velocity in AU/yr, for anything that wants it in the orrery's units.
	func velocity(out: DVec3 = null) -> DVec3:
		if out == null: out = DVec3.new()
		return out.copy_from(dir).scale_in(beta * LY_AU)

	func note(m: String) -> void:
		log.append({ "tau": tau, "m": m })
		if log.size() > 60: log.pop_front()

	## Advance by `dtau` seconds of SHIP time — the natural variable, because the
	## drive's throttle, the fuel burn and the crew all live on the ship's clock.
	## Coordinate time is derived from it, never integrated separately.
	func step(dtau: float) -> void:
		if leg == "arrived" or dtau <= 0.0: return
		var leg_phi: float = plan.phi
		# decide the leg
		if leg == "accel" and phi >= leg_phi - 1e-9:
			leg = "decel" if plan.mode == "flip" else "coast"
			note("Turnover — beginning deceleration" if plan.mode == "flip" else "Cutoff at β = %s, γ = %s — coasting" % [U.fixed(beta, 5), U.fixed(gamma, 3)])
			if leg == "decel": note("Flip and burn")
		if leg == "coast":
			# Turn over when the remaining distance equals what the deceleration leg
			# will cover — computed, not scheduled, so a mid-course change of mind
			# still stops at the right place.
			var need := (Rocketry.C_MS * Rocketry.C_MS / a) * (cosh(phi) - 1.0)
			if remaining <= need:
				leg = "decel"; note("Turnover — flip and burn")

		var burning := leg == "accel" or leg == "decel"
		var sgn := -1.0 if leg == "decel" else 1.0
		var acc := a * throttle if burning else 0.0

		# Exact hyperbolic advance over dtau at constant proper acceleration.
		var dphi := sgn * acc * dtau / Rocketry.C_MS
		var phi0 := phi
		var phi1 := phi + dphi if burning else phi
		# Coordinate time and distance are integrals of cosh and sinh; with constant
		# a they are exact, and with a = 0 they reduce to the coasting case.
		if burning and absf(dphi) > 1e-15:
			var k := Rocketry.C_MS / (sgn * acc)
			t += k * (sinh(phi1) - sinh(phi0))
			s += (Rocketry.C_MS * k) * (cosh(phi1) - cosh(phi0))
			# Fuel: dm/m = −dφ·c/v_e , the relativistic rocket equation differentiated.
			var frac := exp(-absf(dphi) * Rocketry.C_MS / exhaust)
			var m := dry_mass + prop
			prop = maxf(0.0, m * frac - dry_mass)
			if prop <= 0.0 and leg == "accel":
				note("Astrophage exhausted — coasting"); leg = "coast"
			phi = phi1
		else:
			t += dtau * cosh(phi)
			s += dtau * Rocketry.C_MS * sinh(phi)
		tau += dtau

		if leg == "decel" and (phi <= 0.0 or remaining <= 0.0):
			phi = maxf(phi, 0.0)
			leg = "arrived"
			note("Arrival — %s ship, %s coordinate" % [Relativity.fmt_years(tau / YEAR_S), Relativity.fmt_years(t / YEAR_S)])

	## Everything the HUD needs, in one Dictionary (JS keys).
	func readout() -> Dictionary:
		return {
			"beta": beta, "gamma": gamma, "phi": phi,
			"shipYears": tau / YEAR_S, "coordYears": t / YEAR_S,
			"dilation": t / maxf(tau, 1e-9),
			"travelledLy": s / LY_M, "remainingLy": remaining / LY_M,
			"totalLy": dist_ly, "leg": leg,
			"propT": prop / 1000.0, "propFrac": prop / maxf(prop_mass, 1.0),
			"accelG": 0.0 if (leg == "coast" or leg == "arrived") else a / Rocketry.G0,
			"plan": plan,
			# The extra mass ratio a flip-and-burn crossing would need over this
			# ship's own. Δφ = (v_e/c)·ln(M), so the factor is exp(Δφ·c/v_e) — a
			# number that moves with the plan, the drive and the tanks, which is the
			# whole point of quoting it.
			"flipMassRatio": exp((plan.flipPhi - budget) * Rocketry.C_MS / exhaust) \
				if (plan.get("flipPhi") != null and plan.flipPhi > budget and exhaust > 0.0) else 1.0,
		}

# ============================================================================
# WHAT RELATIVISTIC FLIGHT LOOKS LIKE
# ----------------------------------------------------------------------------
# Three effects, all of which act on the SKY rather than on the ship, and all of
# which fall out of one boost. `sky_boost` hands the sky shader the velocity it
# needs and the shader does the rest; see the aberration block in SKY_GLSL.
#
#   ABERRATION. The apparent direction of a source satisfies
#       cos θ_rest = (cos θ_ship − β)/(1 − β·cos θ_ship)
#   so the whole sky piles into a forward cone. At γ = 10 everything visible is
#   inside about 11° ahead.
#
#   DOPPLER. D = 1/(γ(1 − β·cos θ_ship)). A blackbody at T is seen at T·D, which
#   is exactly representable here because the sky colours its stars from a
#   Planck locus — so the shift is applied to the TEMPERATURE at source rather
#   than as a hue filter afterwards.
#
#   HEADLIGHT. Specific intensity transforms as I' = D⁴·I. Ahead the sky
#   brightens enormously; behind it goes black. Same physics as a blazar, one
#   multiply.
#
# Crucially the aberration is applied to the ray direction BEFORE the screen
# derivatives are taken, so the change in solid angle per pixel is picked up by
# the existing point-source machinery — the same path that already handles
# lensing magnification. Nothing here introduces a fixed angular resolution,
# which the repo forbids for good reason.
# ============================================================================

## The β vector (velocity/c) to hand the sky shader, in world coordinates. A
## DVec3 like every flight vector; the sky's uniform is its to_v3().
static func sky_boost(dir_unit: DVec3, beta: float, out: DVec3 = null) -> DVec3:
	if out == null: out = DVec3.new()
	return out.copy_from(dir_unit).scale_in(DQuat.jclamp(beta, -0.999999, 0.999999))

## Doppler factor for a source seen at angle θ from the direction of travel.
static func doppler_factor(beta: float, cos_theta: float) -> float:
	var g := 1.0 / sqrt(maxf(1.0 - beta * beta, 1e-18))
	return 1.0 / (g * (1.0 - beta * cos_theta))

## Half-angle (radians) containing the forward half of the aberrated sky —
## the "tunnel" a relativistic crew actually sees.
static func aberration_cone(beta: float) -> float:
	# The rest-frame hemisphere ahead (cos θ = 0) maps to cos θ' = β.
	return acos(DQuat.jclamp(beta, -1.0, 1.0))

static func fmt_years(y: float) -> String:
	if not is_finite(y): return "—"
	if y < 1.0 / 365.25: return "%s h" % U.fixed(y * 365.25 * 24.0, 1)
	if y < 1.0: return "%s d" % U.fixed(y * 365.25, 1)
	if y < 1000.0: return "%s yr" % U.fixed(y, 2)
	if y < 1e6: return "%s kyr" % U.fixed(y / 1000.0, 2)
	return "%s Myr" % U.fixed(y / 1e6, 2)
