class_name Fall
extends RefCounted
## A dropped piece once Separation hands it on: a body of its own in the vessel's
## parent-centred SI frame, under gravity, drag against the turning air, and its
## recovery sequence or breakup (`look.fall`). It reads the vessel's frame and never
## acts on the vessel. Sources and the drag model: docs/physics/srb-separation.md
## (recovery) and docs/physics/stage-separation.md (the tank).

## Integration step, s, in the air; and where drag is negligible (q under Q_THIN Pa).
const STEP_AIR := 0.05
const STEP_THIN := 2.0
const Q_THIN := 10.0
## The average of |sin α|³ (and |cos α|³) over an end-over-end tumble: 4/(3π).
const TUMBLE := 4.0 / (3.0 * PI)
## A chute's fill time, s, for its opening and each disreef (not resolved further).
const FILL := 1.0
## Display: seconds to swing under a chute or stand up afloat, and seconds a piece
## stays drawn once at rest or broken up while nobody follows it.
const SETTLE := 2.0
const LINGER := 120.0

static var _a1 := DVec3.new()
static var _a2 := DVec3.new()
static var _a3 := DVec3.new()
static var _a4 := DVec3.new()
static var _r2 := DVec3.new()
static var _v2 := DVec3.new()
static var _r3 := DVec3.new()
static var _v3 := DVec3.new()
static var _r4 := DVec3.new()
static var _v4 := DVec3.new()
static var _air := DVec3.new()
static var _g := DVec3.new()

var name := ""
var parent: Body
## Position, m, and velocity, m/s, in the vessel's parent-centred frame.
var r := DVec3.new()
var v := DVec3.new()
var mass := 0.0
## Length and diameter, m, for the drag.
var L := 0.0
var D := 0.0
## The pivot in the body's own frame, and the body frame's attitude in world axes.
var cg := Vector3.ZERO
var B := Basis()
## Body rates, rad/s, body frame: the tumble it left with.
var w := Vector3.ZERO
## Seconds since separation, and the vessel's MET at separation.
var t := 0.0
var met0 := 0.0
var data := {}
## "fall", "rest" (on the surface) or "gone" (sunk, broken up, or its frame lost).
var state := "fall"
## Hanging under a chute, axis along the flow: axial drag, not a tumble's.
var hanging := false
## Gone at impact instead of resting (the nose cap is not recovered).
var sinks := false
## Whether the camera can follow it (the boosters and the tank, not their parts).
var follow := true
## {key, t0, CdA, reef, D, reach, at, count, spread, nodes: Array[Node3D], pilot}
var chutes: Array = []
## Each {name, t, met, alt, speed, q, mach}, in order.
var events: Array = []
var apogee := -INF
var max_q := 0.0
var max_q_alt := 0.0
## t at splashdown, impact or breakup; −1 before.
var ended := -1.0
## Pieces this one has shed (nose cap, frustum), for Spaceflight to draw.
var shed: Array = []
## The geometry, in its own frame, and the node LocalView places it by.
var body: Node3D
var holder: Node3D
## The holder's local-frame position, m (LocalView.place keeps a reference).
var pos := DVec3.new()
## How many of `events` the mission log has shown.
var logged := 0
var _due := {}
var _vr := 0.0

## Take over body `b` of Separation's state `s` for stage `cs` of `craft`: where it is
## and how it moves, from the craft's frame (its origin the vessel's position, its axes
## the vessel's attitude) into the vessel's frame.
static func handoff(vessel: Vessel, craft, cs, s: Dictionary, b: Dictionary) -> Fall:
	var f := Fall.new()
	var n: Node3D = b.node
	var spec: Dictionary = cs.spec
	f.data = spec.look.fall
	f.parent = vessel.parent
	var Tc: Transform3D = n.transform if n == cs.group else (cs.group as Node3D).transform * n.transform
	f.cg = (b.base as Transform3D).affine_inverse() * (b.cg as Vector3)
	var Qv := Basis(vessel.q.to_quaternion())
	f.B = (Qv * Tc.basis).orthonormalized()
	f.r.copy_from(vessel.r).add_in(DVec3.from_v3(Qv * (Tc * f.cg)))
	var F: Basis = (craft.group as Node3D).basis.inverse() * (s.frame as Basis)
	f.v.copy_from(vessel.v).add_in(DVec3.from_v3(Qv * (F * (b.v as Vector3))))
	f.w = Separation.rates(s.sep, b.side)
	f.mass = float(s.mass)
	f.L = float(spec.L)
	f.D = float(spec.D)
	f.t = float(s.t)
	f.met0 = vessel.met - f.t
	f.body = n
	var noun := str(f.data.get("name", spec.name))
	f.name = noun if n == cs.group else ("%s %s" % ["Port" if float(b.side) < 0.0 else "Starboard", noun])
	f._vr = f.v.dot(DQuat.nrm(f.r.clone()))
	return f

func altitude(vessel: Vessel) -> float:
	return r.length() - float(vessel.env.radius)

## Advance `dt` s on the vessel's clock.
func step(dt: float, vessel: Vessel) -> void:
	if vessel.parent != parent: state = "gone"
	var left := dt
	while left > 0.0 and state != "gone":
		var h := minf(left, _step_len(vessel))
		if state == "rest": _rest(h, vessel)
		else: _rk4(h, vessel)
		t += h
		left -= h
		_turn(h, vessel)
		if state == "fall": _sequence(vessel)

## Done with: gone, or at rest past LINGER while the camera is elsewhere.
func retired(followed: bool) -> bool:
	return state == "gone" or (ended >= 0.0 and t - ended > LINGER and not followed)

## The extent the camera frames, m: the body with any chutes out.
func frame_length() -> float:
	var reach := 0.0
	for ch: Dictionary in chutes: reach = maxf(reach, float(ch.reach))
	return maxf(L, 3.0) + reach

func _step_len(vessel: Vessel) -> float:
	if state == "rest" or not chutes.is_empty() or not _due.is_empty(): return STEP_AIR
	var atm = vessel.env.atm
	if atm == null: return STEP_THIN
	var h := altitude(vessel)
	if h > float(atm.top): return STEP_THIN
	var va := vessel.airspeed(r, v, _air).length()
	return STEP_AIR if 0.5 * Rocketry.density(atm, h) * va * va > Q_THIN else STEP_THIN

## Drag area, m², at Mach `M`: the body, tumbling end over end or hanging along the
## flow (Allen's crossflow and the blunt end, as Vessel uses them), and its chutes.
func drag_area(M: float) -> float:
	var end := Rocketry.blunt_drag_coefficient(M) * PI * D * D / 4.0
	var cda := end if hanging else TUMBLE * (Vessel.crossflow_cn(M) * L * D + end)
	for ch: Dictionary in chutes: cda += float(ch.CdA) * open_fraction(ch)
	return cda

## How far a chute is open, as a fraction of its full drag area: its reefing stages
## by the clock since deployment, each filling over FILL s.
func open_fraction(ch: Dictionary) -> float:
	var s := t - float(ch.t0)
	var f := 0.0
	for st: Array in ch.reef:
		if s >= float(st[0]): f = lerpf(f, float(st[1]), clampf((s - float(st[0])) / FILL, 0.0, 1.0))
	return f

func _accel(vessel: Vessel, rr: DVec3, vv: DVec3, out: DVec3) -> DVec3:
	vessel.gravity(rr, _g)
	out.copy_from(_g)
	var atm = vessel.env.atm
	if atm == null: return out
	var h := rr.length() - float(vessel.env.radius)
	if h > float(atm.top): return out
	var rho := Rocketry.density(atm, h)
	var va := vessel.airspeed(rr, vv, _air).length()
	if rho <= 0.0 or va < 0.5: return out
	var M := va / Rocketry.speed_of_sound(atm, h)
	return out.add_scaled_in(_air, -0.5 * rho * va * drag_area(M) / mass)

func _rk4(h: float, vessel: Vessel) -> void:
	_accel(vessel, r, v, _a1)
	_r2.copy_from(r).add_scaled_in(v, h * 0.5)
	_v2.copy_from(v).add_scaled_in(_a1, h * 0.5)
	_accel(vessel, _r2, _v2, _a2)
	_r3.copy_from(r).add_scaled_in(_v2, h * 0.5)
	_v3.copy_from(v).add_scaled_in(_a2, h * 0.5)
	_accel(vessel, _r3, _v3, _a3)
	_r4.copy_from(r).add_scaled_in(_v3, h)
	_v4.copy_from(v).add_scaled_in(_a3, h)
	_accel(vessel, _r4, _v4, _a4)
	r.add_scaled_in(v, h / 6.0).add_scaled_in(_v2, h / 3.0).add_scaled_in(_v3, h / 3.0).add_scaled_in(_v4, h / 6.0)
	v.add_scaled_in(_a1, h / 6.0).add_scaled_in(_a2, h / 3.0).add_scaled_in(_a3, h / 3.0).add_scaled_in(_a4, h / 6.0)

## At rest on the surface it turns with the planet (ω × r, the pole on −Y).
func _rest(h: float, vessel: Vessel) -> void:
	var R := float(vessel.env.radius)
	var lift := r.length() - R
	_g.set_v(0.0, -float(vessel.env.rotRate), 0.0).cross_vectors(_g, r)
	r.add_scaled_in(_g, h)
	DQuat.set_len(r, R + lift)
	v.set_v(0.0, -float(vessel.env.rotRate), 0.0).cross_vectors(v, r)

## Display attitude: the tumble it left with; the tank's measured entry tumble once in
## the air; swung along the flow under a chute; upright afloat.
func _turn(h: float, vessel: Vessel) -> void:
	var want := Vector3.ZERO
	if state == "rest":
		if data.has("float"): want = DQuat.nrm(r.clone()).to_v3()
	elif hanging:
		var va := vessel.airspeed(r, v, _air)
		if va.length_sq() > 1.0: want = -va.normalized().to_v3()
	if want != Vector3.ZERO:
		w = Vector3.ZERO
		var axis := B.y.normalized()
		var turn := axis.cross(want)
		var ang := atan2(turn.length(), axis.dot(want))
		if turn.length_squared() > 1e-12:
			B = (Basis(turn.normalized(), ang * (1.0 - exp(-h / SETTLE))) * B).orthonormalized()
		return
	var tumble := float(data.get("tumble", 0.0))
	var atm = vessel.env.atm
	if tumble > 0.0 and atm != null and altitude(vessel) < float(atm.top):
		w = Vector3(deg_to_rad(tumble), 0.0, 0.0)
	if w.length_squared() > 0.0:
		B = (B * Basis(w.normalized(), w.length() * h)).orthonormalized()

func _sequence(vessel: Vessel) -> void:
	var alt := altitude(vessel)
	var up := DQuat.nrm(_g.copy_from(r))
	var vr := v.dot(up)
	if _vr > 0.0 and vr <= 0.0 and apogee == -INF:
		apogee = alt
		note("apogee", vessel)
	_vr = vr
	var atm = vessel.env.atm
	if atm != null and alt < float(atm.top):
		var va := vessel.airspeed(r, v, _air).length()
		var q := 0.5 * Rocketry.density(atm, alt) * va * va
		if q > max_q: max_q = q; max_q_alt = alt
	var nc = data.get("noseCap")
	if nc != null and not _done("noseCap") and vr < 0.0 and alt <= float(nc.alt):
		note("noseCap", vessel)
		var cap := _shed("nosecap", float(nc.mass))
		if cap != null: cap.sinks = true
		_due.drogue = t + float(data.drogue.delay)
	if _due.has("drogue") and t >= float(_due.drogue):
		_due.erase("drogue")
		_deploy("drogue", data.drogue)
		note("drogue", vessel)
	var fr = data.get("frustum")
	if fr != null and _done("drogue") and not _done("frustum") and alt <= float(fr.alt):
		note("frustum", vessel)
		var piece := _shed("frustum", float(fr.mass))
		# The drogue stays on the frustum and pulls it away; the mains come out of it.
		for ch: Dictionary in chutes.duplicate():
			if ch.key == "drogue" and piece != null:
				chutes.erase(ch); piece.chutes.append(ch)
				for n: Node3D in ch.nodes: n.reparent(piece.holder, false)
		_due.mains = t + float(data.mains.delay)
	if _due.has("mains") and t >= float(_due.mains):
		_due.erase("mains")
		_deploy("mains", data.mains)
		note("mains", vessel)
	var brk = data.get("breakup")
	if brk != null and vr < 0.0 and alt <= float(brk):
		note("breakup", vessel)
		ended = t
		state = "gone"
		return
	# Nozzle first when hanging: its lowest point is the base, `cg.y` below the pivot.
	if alt - (_bottom() if hanging else 0.0) <= 0.0:
		note("splashdown", vessel)
		ended = t
		state = "gone" if sinks else "rest"
		for ch: Dictionary in chutes:
			for n: Node3D in ch.nodes: n.queue_free()
		chutes.clear()
		if data.has("float"):
			DQuat.set_len(r, float(vessel.env.radius) + float(data.float) - (_top() - cg.y))
		else:
			DQuat.set_len(r, float(vessel.env.radius))
		_rest(0.0, vessel)

func _done(key: String) -> bool:
	return events.any(func(e): return e.name == key)

## Record an event with where and how fast it happened.
func note(what: String, vessel: Vessel) -> void:
	var alt := altitude(vessel)
	var va := vessel.airspeed(r, v, _air).length()
	var atm = vessel.env.atm
	var rho := Rocketry.density(atm, maxf(alt, 0.0)) if atm != null and alt < float(atm.top) else 0.0
	var a := Rocketry.speed_of_sound(atm, maxf(alt, 0.0)) if atm != null else 1.0
	events.append({"name": what, "t": t, "met": met0 + t, "alt": alt, "speed": va,
		"q": 0.5 * rho * va * va, "mach": va / a})

func event(what: String):
	for e: Dictionary in events:
		if e.name == what: return e
	return null

func _deploy(key: String, ch: Dictionary) -> void:
	var rec := {"key": key, "t0": t, "CdA": float(ch.CdA), "reef": ch.reef, "D": float(ch.D),
		"reach": float(ch.reach), "at": float(ch.at), "count": int(ch.get("count", 1)),
		"spread": deg_to_rad(float(ch.get("spread", 0.0))), "nodes": [], "pilot": null}
	hanging = true
	if holder != null:
		for i in int(rec.count):
			var rig := CraftModel.parachute(float(rec.D), float(rec.reach))
			holder.add_child(rig)
			rec.nodes.append(rig)
		if ch.has("pilot"):
			# The pilot chute stays on the drogue's apex.
			var p := CraftModel.parachute(float(ch.pilot), float(rec.reach) * float(ch.pilot) / float(rec.D))
			holder.add_child(p)
			rec.nodes.append(p)
			rec.pilot = p
	chutes.append(rec)

## Detach this body's `prefix_<stage>_<i>` node as a Fall of its own, `m` kg, leaving
## with this one's state. Null when the body has no such node.
func _shed(prefix: String, m: float) -> Fall:
	var n: Node3D = null
	if body != null:
		for c in body.get_children():
			if str(c.name).begins_with(prefix + "_"): n = c
	if n == null: return null
	var acc := [false, AABB()]
	_measure(n, n.transform, acc)
	var box: AABB = acc[1]
	var f := Fall.new()
	f.parent = parent
	f.follow = false
	f.name = "%s %s" % [name, prefix]
	f.body = Node3D.new()
	n.reparent(f.body, false)
	f.holder = Node3D.new()
	f.holder.add_child(f.body)
	f.cg = box.get_center()
	f.L = box.size.y
	f.D = maxf(box.size.x, box.size.z)
	f.B = B
	f.w = w
	f.r.copy_from(r).add_in(DVec3.from_v3(B * (f.cg - cg)))
	f.v.copy_from(v)
	f.mass = m
	mass -= m
	f.t = t
	f.met0 = met0
	f.hanging = hanging
	f._vr = _vr
	f.apogee = apogee
	shed.append(f)
	return f

## The body's top and bottom along its axis, m, in its own frame.
func _top() -> float:
	return _extent().end.y

func _bottom() -> float:
	return cg.y - _extent().position.y

func _extent() -> AABB:
	var acc := [false, AABB()]
	if body != null: _measure(body, Transform3D(), acc)
	return acc[1] if acc[0] else AABB(Vector3(-D, 0.0, -D) * 0.5, Vector3(D, L, D))

## Mesh bounds under `n` in the body's frame, plumes left out (`fx`).
static func _measure(n: Node, xf: Transform3D, acc: Array) -> void:
	if n.has_meta("fx"): return
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var b := xf * (n as MeshInstance3D).mesh.get_aabb()
		acc[1] = (acc[1] as AABB).merge(b) if acc[0] else b
		acc[0] = true
	for c in n.get_children():
		if c is Node3D: _measure(c, xf * (c as Node3D).transform, acc)

## Draw it in the local frame: `origin` its origin in the vessel's frame, `to_local` the
## world-to-local rotation. Chutes trail along the flow from their attach points.
func place(vessel: Vessel, origin: DVec3, to_local: Basis, east: DVec3, up: DVec3, north: DVec3) -> void:
	var d := r.sub(origin)
	pos.set_v(d.dot(east), d.dot(up), d.dot(north))
	if body == null: return
	var Bl := to_local * B
	body.transform = Transform3D(Bl, -(Bl * cg))
	if chutes.is_empty(): return
	var va := vessel.airspeed(r, v, _air)
	var flow: Vector3 = to_local * (-va.normalized().to_v3() if va.length_sq() > 1.0 else DQuat.nrm(r.clone()).to_v3())
	var side := flow.cross(Vector3(1, 0, 0) if absf(flow.x) < 0.9 else Vector3(0, 0, 1)).normalized()
	for ch: Dictionary in chutes:
		var k := sqrt(maxf(open_fraction(ch), 0.0))
		var at: Vector3 = Bl * (Vector3(0.0, float(ch.at), 0.0) - cg)
		var n_main := int(ch.count)
		for i in mini(n_main, (ch.nodes as Array).size()):
			var axis := flow
			if n_main > 1:
				# A cluster splays out at its measured pull angle.
				var out := side.rotated(flow, TAU * i / n_main)
				axis = flow.rotated(flow.cross(out).normalized(), float(ch.spread))
			_rig(ch.nodes[i], at, axis, k)
		if ch.pilot != null:
			_rig(ch.pilot, at + flow * float(ch.reach), flow, 1.0)

static func _rig(n: Node3D, at: Vector3, axis: Vector3, open: float) -> void:
	var x := axis.cross(Vector3(1, 0, 0) if absf(axis.x) < 0.9 else Vector3(0, 0, 1)).normalized()
	var z := x.cross(axis)
	var s := maxf(open, 0.06)
	n.transform = Transform3D(Basis(x * s, axis, z * s), at)
