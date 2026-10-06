class_name CatchTower
extends RefCounted

# A launch tower's catch arms as a physical fixture, in the vessel's parent frame
# (SI, deck at altitude 0). LaunchSite draws it; geometry and the estimated
# tolerances are in docs/physics/booster-catch.md.

## The chopsticks complex as launchsite.gd builds it, m from the pad axis and deck.
const TOWER_OFFSET := 26.0
const TOWER_HALF := 6.0
const TOWER_TOP := 122.5
## Arms start closing once the pins are this close above the rails, aligned.
const CAPTURE_ABOVE := 25.0
const CLOSE_S := 3.0
## The arms' shock absorbers: a damped spring on the rails, period ~3 s.
const SETTLE_W := 2.1
const SETTLE_ZETA := 0.7

var pos := DVec3.new()      # the pad axis at deck level
var out := DVec3.new()      # horizontal unit from the tower out over the pad (the arms' reach)
var side := DVec3.new()     # horizontal unit across the arms (the pins point along it)
var rail_alt := 0.0         # rail height above the deck, m
var closed := 0.0           # 0 open … 1 closed on the hull
var closing := false
var caught := false
var settle := 0.0           # shock-absorber travel, m, downward positive
var settle_v := 0.0
var _hold := DVec3.new()    # caught: the booster's horizontal offset from the axis
var _prev_pin = null        # the pins' altitude at the last contact test
var _w := DVec3.new()
var _t := DVec3.new()

## A tower at pad point `pad` (parent frame, on the surface) whose arms reach along
## the horizontal unit `reach`, with rails `rail_alt` above the deck.
static func at(pad: DVec3, reach: DVec3, rails: float) -> CatchTower:
	var t := CatchTower.new()
	t.pos.copy_from(pad)
	var up := DQuat.nrm(pad.clone())
	t.out.copy_from(reach).add_scaled_in(up, -reach.dot(up))
	DQuat.nrm(t.out)
	DQuat.nrm(t.side.cross_vectors(up, t.out))
	t.rail_alt = rails
	return t

## The pins' height above the base for a stage with a catch spec, m.
static func pin_height(spec: Dictionary) -> float:
	return float(spec.catch.pinFrac) * float(spec.L)

## Carry the tower round with its body (ω × r, as place_on_pad) and run the arms.
func step(dt: float, rot_rate: float) -> void:
	if dt <= 0.0: return
	var R := pos.length()
	var h := _hold.length()
	for p in [pos, out, side, _hold]:
		_w.set_v(0.0, -rot_rate, 0.0).cross_vectors(_w, p)
		p.add_scaled_in(_w, dt)
	DQuat.set_len(pos, R)
	DQuat.nrm(out); DQuat.nrm(side)
	if h > 0.0: DQuat.set_len(_hold, h)
	if closing: closed = minf(1.0, closed + dt / CLOSE_S)
	if caught:
		# Semi-implicit, stable at a frame's step.
		settle_v += (-SETTLE_W * SETTLE_W * settle - 2.0 * SETTLE_ZETA * SETTLE_W * settle_v) * dt
		settle += settle_v * dt

## Horizontal offset of `r` from the pad axis, written into `o`.
func offset(r: DVec3, o: DVec3) -> DVec3:
	var up := DQuat.nrm(_t.copy_from(pos))
	o.copy_from(r).sub_in(pos)
	return o.add_scaled_in(up, -o.dot(up))

## The axis point the arms close on, at the rails' height minus `below`.
func axis_point(below: float, o: DVec3) -> DVec3:
	var up := DQuat.nrm(_t.copy_from(pos))
	return o.copy_from(pos).add_scaled_in(up, rail_alt - below)

## Test a vessel against the tower once per step: "" (nothing), "caught", or why
## it was lost. Starts the arms closing when the pins come down aligned.
func contact(v: Vessel) -> String:
	var st = v.current_stage if v.current_stage != null else v._first_attached()
	if st == null or st.spec.get("catch") == null: return ""
	var cs: Dictionary = st.spec.catch
	var alt := v.altitude()
	var pin := alt + pin_height(st.spec)
	var o := offset(v.r, DVec3.new())
	var d := o.length()
	var radius := v.diameter * 0.5
	# The tower: a square column TOWER_OFFSET behind the axis, against the hull.
	var d_out := o.dot(out) + TOWER_OFFSET
	var d_side := o.dot(side)
	if alt < TOWER_TOP and absf(d_out) < TOWER_HALF + radius and absf(d_side) < TOWER_HALF + radius:
		return "struck the launch tower"
	var up := DQuat.nrm(_t.copy_from(v.r))
	var vrel := v.airspeed(v.r, v.v, DVec3.new())
	var v_vert := vrel.dot(up)
	var v_lat := vrel.add_scaled_in(up, -v_vert).length()
	if not closing and pin > rail_alt and pin < rail_alt + CAPTURE_ABOVE \
			and d < float(cs.radius) and v_lat < float(cs.vHoriz) * 2.0:
		closing = true
	var prev = _prev_pin
	_prev_pin = pin
	if prev == null or prev <= rail_alt or pin > rail_alt: return ""
	# The pins came down through the rails this step.
	if closed <= 0.0: return ""
	if closed < 1.0: return "struck the catch arms while they closed"
	if d > float(cs.radius): return "missed the catch rails by %s m" % U.fixed(d, 1)
	if v_vert < -float(cs.vVert) or v_lat > float(cs.vHoriz):
		return "hit the catch arms at %s m/s vertical, %s m/s lateral — rated to %s m/s" % [
			U.fixed(-v_vert, 1), U.fixed(v_lat, 1), Vessel.js_num(float(cs.vVert))]
	caught = true
	settle = 0.0
	settle_v = -v_vert
	_hold.copy_from(o)
	return "caught"

## A caught vessel's position: hanging by its pins from the rails, on the absorbers.
func held_position(pin: float, r_out: DVec3) -> DVec3:
	axis_point(pin + settle, r_out)
	return r_out.add_in(_hold)

## The state a returning booster starts from: at apogee after its boostback, `apo`
## m up, coming home at `v_back` m/s along −reach. Downrange and crossrange are
## solved as a boostback targets: fly this model's coast and catch guidance at 30 Hz
## (coarser steps lose control at ignition) to landing-burn ignition, predict where
## a constant-deceleration burn stops (r + v·t_go/2), and move the start by that
## point's miss from the approach point. Returns {r, v, q}.
static func return_state(veh: Dictionary, parent: Body, bodies: Array, tower: CatchTower,
		apo: float, v_back: float, approach: float) -> Dictionary:
	var down := 0.0
	var cross := 0.0
	var best := {}
	for it in 8:
		var t := CatchTower.at(tower.pos, tower.out, tower.rail_alt)
		var v := Vessel.new({"vehicle": veh, "parent": parent, "bodies": bodies, "payload": 0.0})
		var up := DQuat.nrm(t.pos.clone())
		var R: float = float(v.env.radius) + apo
		var th := down / float(v.env.radius)
		v.r.copy_from(up).scale_in(cos(th)).add_scaled_in(t.out, sin(th)).add_scaled_in(t.side, cross / float(v.env.radius))
		DQuat.set_len(v.r, R)
		var at_up := DQuat.nrm(v.r.clone())
		var home := t.out.clone().add_scaled_in(at_up, -t.out.dot(at_up))
		DQuat.nrm(home).negate_in()
		v.v.set_v(0.0, -float(v.env.rotRate), 0.0)
		v.v.cross_vectors(v.v, v.r).add_scaled_in(home, v_back)
		var air := DVec3.new()
		# Engines down, as the catch program's coast holds.
		v.q.set_from_unit_vectors(Vessel.BODY_FWD, at_up)
		v.phase = Vessel.PHASE.DESCENT
		best = {"r": v.r.clone(), "v": v.v.clone(), "q": v.q.clone()}
		v.catch_tower = t
		var ap := Guidance.Autopilot.new(v)
		ap.engage("catch")
		var guard := 0
		while guard < 12000 and v.phase != Vessel.PHASE.DESTROYED and v.phase != Vessel.PHASE.LANDED:
			guard += 1
			ap.update(1.0 / 30.0)
			v.step(1.0 / 30.0)
			if ap.state_name != "coast" and ap.state_name != null: break
		DQuat.nrm(at_up.copy_from(v.r))
		var vrel := v.airspeed(v.r, v.v, air)
		var vv := vrel.dot(at_up)
		var t_go := 2.0 * maxf(v.altitude(), 0.0) / maxf(-vv, 1.0)
		var miss := t.offset(v.r, DVec3.new()).add_scaled_in(vrel.add_scaled_in(at_up, -vv), t_go * 0.5)
		miss.add_scaled_in(t.out, -approach)
		if miss.length() < 2.0: break
		down -= miss.dot(t.out)
		cross -= miss.dot(t.side)
	return best

## Post-boostback apogee and homeward speed for begin_return: estimates consistent with
## the flown timeline and the ~1.2 km/s peak descent speed. Slow, because without
## grid-fin lift in this model nothing steers the coast (booster-catch.md).
const RETURN_APOGEE := 95000.0
const RETURN_SPEED := 60.0

## Turn `v` (a Vehicles.booster_return vessel) into a booster coming home to a
## tower at `pad`, its arms reaching along `reach`. Returns the tower, also left on
## v.catch_tower.
static func begin_return(v: Vessel, pad: DVec3, reach: DVec3) -> CatchTower:
	var spec: Dictionary = v.stages[0].spec
	var tower := CatchTower.at(pad, reach, float(spec.catch.baseClear) + pin_height(spec))
	var s := return_state(v.vehicle, v.parent, v.bodies, tower, RETURN_APOGEE, RETURN_SPEED,
		Guidance.Autopilot.CATCH_APPROACH)
	v.r.copy_from(s.r); v.v.copy_from(s.v); v.q.copy_from(s.q)
	v.omega.set_v(0.0, 0.0, 0.0)
	v.phase = Vessel.PHASE.DESCENT
	v.launch_site = null
	v.catch_tower = tower
	return tower
