class_name Separation
extends RefCounted
## A dropped stage leaving the stack: the stage, or each of its pieces (the Shuttle's
## two boosters, a fairing's two halves), is flown in the frame held at separation.
## Its own separation impulse pushes it, the stack's acceleration leaves it behind,
## and gravity pulls both alike. Display only: the vessel has already dropped the
## stage's mass. Per-stage data is `look.sep` in vehicles.gd; sources and numbers are
## in docs/physics/stage-separation.md (the Shuttle's boosters: srb-separation.md).

## Seconds a separated stage stays drawn.
const SHOWN := 30.0
## Longest integration step, s, so a coarse frame still resolves a motor burn.
const STEP := 0.05

## Fraction of a stage's own engines' cutoff thrust still left `t` s after separation
## (`look.sep.residual`): a solid's chamber blowing down, `F₀ e^(−t/tau)`, or a liquid
## engine's measured decay, `curve` [[s after cutoff, fraction]] entered `from` s after
## cutoff. Pushes the stage forward along its own axis.
static func residual_fraction(t: float, r: Dictionary) -> float:
	if t < 0.0: return 0.0
	if r.has("tau"):
		return exp(-t / float(r.tau)) if t < residual_end(r) else 0.0
	var c: Array = r.curve
	var x := t + float(r.get("from", 0.0))
	if x < float(c[0][0]) or x >= float(c[-1][0]): return 0.0
	for i in range(1, c.size()):
		if x < float(c[i][0]):
			return lerpf(float(c[i - 1][1]), float(c[i][1]), (x - float(c[i - 1][0])) / (float(c[i][0]) - float(c[i - 1][0])))
	return 0.0

## Seconds after separation when a residual is over: a measured curve's end, or a
## blowdown once it is down to 1% (the last 1% of its impulse is dropped).
static func residual_end(r: Dictionary) -> float:
	if r.has("tau"): return float(r.tau) * log(100.0)
	return float((r.curve as Array)[-1][0]) - float(r.get("from", 0.0))

## Thrust fraction of a separation motor `t` s after the command: ignition, web action
## at full thrust, linear tail-off (TM X-64967 fig. 2).
static func motor_fraction(t: float, m: Dictionary) -> float:
	var t0 := float(m.get("ignite", 0.0))
	var t1 := t0 + float(m.web)
	var t2 := t1 + float(m.get("tail", 0.0))
	if t < t0 or t >= t2: return 0.0
	if t < t1: return 1.0
	return (t2 - t) / (t2 - t1)

## A site's azimuth, rad, from +X toward +Z. A port piece (side −1) mirrors X.
static func _azimuth(site: Array, side: float) -> float:
	var az := deg_to_rad(float(site[2]))
	return az if side > 0.0 else PI - az

## Where a motor site's exhaust runs, a unit vector in the stage frame: forward (+Y)
## and out at the site's azimuth by the cant. The push on the stage is its opposite.
static func exhaust_dir(m: Dictionary, site: Array, side: float) -> Vector3:
	var cant := deg_to_rad(float(m.cant))
	var az := _azimuth(site, side)
	return Vector3(sin(cant) * cos(az), cos(cant), sin(cant) * sin(az))

## Where a site's exhaust leaves, in its body's frame: `[y, r, az]` is its height,
## distance off the axis and azimuth.
static func motor_point(site: Array, side: float) -> Vector3:
	var az := _azimuth(site, side)
	return Vector3(float(site[1]) * cos(az), float(site[0]), float(site[1]) * sin(az))

## Body rates once spun up, rad/s in the stage frame. Authored as (P, Q, R): roll about
## the stage's axis, pitch about +X, yaw about −Z; one triple, or one per side.
static func rates(sep: Dictionary, side: float) -> Vector3:
	var r = sep.get("rates")
	if r is Dictionary: r = r.starboard if side > 0.0 else r.port
	if not r is Array: return Vector3.ZERO
	return Vector3(float(r[1]), float(r[0]), -float(r[2])) * (PI / 180.0)

## A node's mesh bounds in its parent's frame.
static func _bounds(n: Node3D) -> AABB:
	var acc := [false, AABB()]
	CraftModel._measure_into(n, n.transform, acc, null)
	return acc[1] if acc[0] else AABB(n.position, Vector3.ZERO)

## Begin the drift of `nodes`: the stage's pieces (children of `group`), or the stage
## group itself. `frame` is the craft's attitude now; `ctx` is {mass: what is left of
## the stack, kg, for its own unmodelled push (`look.sep.stack`); support: the
## non-gravitational acceleration, craft frame, m/s², the ground gives a stage left
## standing on it (the LM's descent stage), else zero}.
static func start(spec: Dictionary, group: Node3D, nodes: Array, frame: Basis, ctx := {}) -> Dictionary:
	var sep: Dictionary = spec.get("look", {}).get("sep", {})
	var whole: bool = nodes.size() == 1 and nodes[0] == group
	var support: Vector3 = ctx.get("support", Vector3.ZERO)
	var bodies := []
	for n: Node3D in nodes:
		# The mesh middle (plumes hung on the body count too: only a fallback). A fairing
		# half sits on the axis, so only its shape says which side it is.
		var centre := _bounds(n).get_center()
		var at_x := n.position.x if n.position.x != 0.0 else centre.x
		# Which way a piece mirrors its motors and rates; a whole stage does not.
		var side := signf(at_x) if not whole and absf(at_x) > 1e-3 else 1.0
		# The pivot: an authored height on the axis of the body, or its middle.
		var cg: Vector3 = n.transform * Vector3(0.0, float(sep.cgY), 0.0) if sep.has("cgY") else centre
		# A piece pushed sideways (`push`, m/s) leaves straight out from the stack's axis.
		var v := Vector3.ZERO
		var out := Vector3(centre.x, 0.0, centre.z)
		if sep.has("push") and out.length() > 1e-3:
			v = out.normalized() * float(sep.push)
		bodies.append({"node": n, "base": n.transform, "side": side, "cg": cg,
			"p": Vector3.ZERO, "v": v, "R": Basis(), "support": support})
	var stack = sep.get("stack")
	return {"t": 0.0, "frame": frame, "bodies": bodies, "sep": sep, "motors": sep.get("motors"),
		# Pieces sit in the stage group, which rides with the craft; held-frame rotations
		# turn about the craft's origin, so they need where the group is.
		"offset": Vector3.ZERO if whole else group.position,
		"mass": float(spec.dry) / maxf(float(nodes.size()), 1.0),
		"stack_a": float(stack.thrust) / maxf(float(ctx.get("mass", 0.0)), 1.0) if stack != null else 0.0}

## Seconds after separation when everything this model adds is over (the motors' burn,
## the stack's own push, the spin-up), so a stage with a fate (`look.fall`) can be handed
## on to Fall. Past this the pieces only coast, which Fall flies in absolute terms.
static func handoff_time(s: Dictionary) -> float:
	var sep: Dictionary = s.sep
	var t := float(sep.get("spinUp", 3.0)) if sep.has("rates") else 0.0
	if sep.has("residual"): t = maxf(t, residual_end(sep.residual))
	var m = s.motors
	if m != null:
		t = maxf(t, float(m.get("ignite", 0.0)) + float(m.web) + float(m.get("tail", 0.0)))
	var stack = sep.get("stack")
	if stack != null:
		var dur := float(stack.time) if stack.has("time") else float(stack.dv) / maxf(float(s.stack_a), 1e-6)
		t = maxf(t, float(stack.get("start", 0.0)) + dur)
	return t

## Advance by `dt` s. `basis` is the craft's attitude now and `accel` the stack's
## non-gravitational acceleration, craft frame, m/s². Returns false once done.
static func step(s: Dictionary, dt: float, basis: Basis, accel: Vector3) -> bool:
	var sep: Dictionary = s.sep
	var m = s.motors
	var t0 := float(s.t)
	s.t = t0 + dt
	var F: Basis = basis.inverse() * (s.frame as Basis)
	var a_stack: Vector3 = F.inverse() * accel
	# What is left of the stack makes its own push that the vessel does not fly (the
	# S-II's ullage rockets, the orbiter's −Z translation), in its own frame.
	var stack = sep.get("stack")
	if stack != null:
		var tm := float(t0 + dt * 0.5) - float(stack.get("start", 0.0))
		var dur := float(stack.time) if stack.has("time") else float(stack.dv) / maxf(float(s.stack_a), 1e-6)
		if tm >= 0.0 and tm < dur:
			var d: Array = stack.dir
			a_stack += F.inverse() * Vector3(float(d[0]), float(d[1]), float(d[2])).normalized() * float(s.stack_a)
	# Midpoint in time, so a coarse frame still delivers a motor's impulse.
	var thrust := float(m.thrust) * motor_fraction(t0 + dt * 0.5, m) / float(s.mass) if m != null else 0.0
	var r = sep.get("residual")
	var push := float(r.thrust) * residual_fraction(t0 + dt * 0.5, r) / float(s.mass) if r != null else 0.0
	# Authored rates are reached by `spinUp` s and then held: the plume and proximity
	# aerodynamics that drive them are not modelled (the boosters' memo gives 3 s).
	var spin_k := minf(float(s.t) / float(sep.get("spinUp", 3.0)), 1.0)
	var off: Vector3 = s.offset
	for b: Dictionary in s.bodies:
		var R: Basis = b.R
		var a: Vector3 = (b.support as Vector3) - a_stack
		if thrust > 0.0:
			for site: Array in m.sites:
				a -= R * exhaust_dir(m, site, b.side) * thrust
		if push > 0.0:
			a += R * Vector3.UP * push
		# Trapezoidal in position: exact for a constant push over the step, so the drift
		# does not depend on the step (semi-implicit Euler put a 5-step separation 20% long).
		var v0: Vector3 = b.v
		b.v += a * dt
		b.p += (v0 + (b.v as Vector3)) * 0.5 * dt
		var w: Vector3 = rates(sep, b.side) * spin_k
		if w.length_squared() > 0.0:
			b.R = (R * Basis(w.normalized(), w.length() * dt)).orthonormalized()
		# Turn about the pivot, move by p, then carry the held frame into the craft's.
		var base: Transform3D = b.base
		var cg: Vector3 = b.cg
		var o: Vector3 = cg + (b.R as Basis) * (base.origin - cg) + (b.p as Vector3)
		(b.node as Node3D).transform = Transform3D(F * (b.R as Basis) * base.basis, F * (off + o) - off)
	return float(s.t) < SHOWN
