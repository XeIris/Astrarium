class_name Separation
extends RefCounted
## A stage made of pieces that leave on their own (the Shuttle's two boosters): each
## piece is pushed out by its separation motors, falls behind the accelerating stack
## and tumbles. Display only: the vessel has already dropped the stage's mass.
## Sources and numbers: docs/physics/srb-separation.md.

## Seconds a separated piece stays drawn.
const SHOWN := 30.0

## Thrust fraction of one separation-motor cluster `t` s after the command:
## ignition, web action at full thrust, linear tail-off (TM X-64967 fig. 2).
static func motor_fraction(t: float, m: Dictionary) -> float:
	var t0 := float(m.ignite)
	var t1 := t0 + float(m.web)
	var t2 := t1 + float(m.tail)
	if t < t0 or t >= t2: return 0.0
	if t < t1: return 1.0
	return (t2 - t) / (t2 - t1)

## The motors' resultant push on the piece on `side` (+1 starboard), a unit vector in
## the stage frame: aft along the axis by the cant, outboard, and dipped away from
## the orbiter (+Z) so the booster passes under its wing.
static func push_dir(m: Dictionary, side: float) -> Vector3:
	var cant := deg_to_rad(float(m.cant))
	var dip := deg_to_rad(float(m.dip))
	return Vector3(side * sin(cant) * cos(dip), -cos(cant), -sin(cant) * sin(dip))

## Where a cluster's exhaust leaves, piece-local: on the skin facing the exhaust.
static func motor_point(m: Dictionary, side: float, k: int) -> Vector3:
	var at: Array = m.at[k]
	var e := -push_dir(m, side)
	var lateral := Vector3(e.x, 0.0, e.z).normalized()
	return Vector3(0.0, float(at[0]), 0.0) + lateral * float(at[1])

## Body rates three seconds after separation, rad/s in the stage frame. Authored as
## the memo's (P, Q, R): roll about the booster's axis, pitch about the orbiter's
## starboard axis, yaw about the orbiter's down (−Z).
static func rates(m: Dictionary, side: float) -> Vector3:
	var r: Array = m.rates.starboard if side > 0.0 else m.rates.port
	return Vector3(float(r[1]), float(r[0]), -float(r[2])) * (PI / 180.0)

## Begin the drift of `pieces` (Node3D, children of the stage group). `frame` is the
## craft's attitude now; the drift is integrated in that frame so the stack's later
## pitching does not swing the boosters with it.
static func start(spec: Dictionary, pieces: Array, frame: Basis) -> Dictionary:
	var bodies := []
	for n: Node3D in pieces:
		bodies.append({"node": n, "base": n.transform, "side": signf(n.position.x) if n.position.x != 0.0 else 1.0,
			"p": Vector3.ZERO, "v": Vector3.ZERO, "R": Basis()})
	return {"t": 0.0, "frame": frame, "bodies": bodies, "motors": spec.look.bsm,
		"mass": float(spec.dry) / maxf(float(pieces.size()), 1.0)}

## Advance by `dt` s. `basis` is the craft's attitude now and `accel` the stack's
## non-gravitational acceleration along its own +Y, m/s²; gravity pulls both alike.
## Returns false once the pieces are done.
static func step(s: Dictionary, dt: float, basis: Basis, accel: float) -> bool:
	var m: Dictionary = s.motors
	var t0 := float(s.t)
	s.t = t0 + dt
	var F: Basis = basis.inverse() * (s.frame as Basis)
	var a_stack: Vector3 = F.inverse() * Vector3(0.0, accel, 0.0)
	# Both clusters, midpoint in time so a coarse frame still delivers the impulse.
	var a_motor := 2.0 * float(m.thrust) * motor_fraction(t0 + dt * 0.5, m) / float(s.mass)
	var cg := Vector3(0.0, float(m.cgY), 0.0)
	# The memo's rates are reached by 3 s and then held: the plume and proximity
	# aerodynamics that drive them are not modelled.
	var spin_k := minf(float(s.t) / 3.0, 1.0)
	for b: Dictionary in s.bodies:
		var R: Basis = b.R
		var a: Vector3 = R * push_dir(m, b.side) * a_motor - a_stack
		b.v += a * dt
		b.p += b.v * dt
		var w: Vector3 = rates(m, b.side) * spin_k
		if w.length_squared() > 0.0:
			b.R = (R * Basis(w.normalized(), w.length() * dt)).orthonormalized()
		var base: Transform3D = b.base
		var origin: Vector3 = base.origin + b.p + cg - (b.R as Basis) * cg
		(b.node as Node3D).transform = Transform3D(F * (b.R as Basis), F * origin)
	return float(s.t) < SHOWN
