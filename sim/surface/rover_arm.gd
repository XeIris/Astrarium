class_name RoverArm
extends RefCounted

# Perseverance's robotic arm: 2 m, five joints, a 45 kg turret (JPL's press kit). Here a shoulder that turns
# (azimuth) and lifts, an elbow, a wrist that keeps the turret square to the ground, and the turret's own
# turn: it places the turret on a point of ground the rover can reach and stows it again. Kinematics only, in
# the rover's body frame (x left, y up, z forward, origin its centre of mass); its mass does not move the
# rover. docs/physics/rover.md#the-arm.

## The shoulder's mount on the body's front, and the links: upper arm, forearm, wrist to the turret's
## contact face. Estimates within JPL's 2 m.
const SHOULDER := Vector3(0.3, -0.15, 0.85)
const UPPER := 0.95
const FOREARM := 0.85
const WRIST := 0.25
## Joint rates, rad/s (an estimate: the arm moves in minutes, not seconds).
const RATE := 0.15
## Stowed: folded back along the front, turret tucked.
const STOWED := {"az": 0.0, "lift": -0.25, "elbow": 2.9, "wrist": -1.2, "turn": 0.0}

var joints := STOWED.duplicate()
var target := STOWED.duplicate()
## Where the turret was sent (body frame), and whether the joints have got there.
var aim := Vector3.ZERO
var placed := false
var stowed := true

## Send the turret to a body-frame point, its face down onto it. False when out of reach: then nothing moves.
func reach(p: Vector3) -> bool:
	var sol = solve(p)
	if sol == null or not p.is_finite(): return false
	target = sol
	aim = p
	stowed = false
	return true

func stow() -> void:
	target = STOWED.duplicate()
	stowed = true

## Joint angles that put the turret's face on `p` (body frame), the wrist above it, or null.
static func solve(p: Vector3):
	var wrist := p + Vector3(0.0, WRIST, 0.0)
	var d := wrist - SHOULDER
	var az := atan2(d.x, d.z)
	var horiz := Vector2(d.x, d.z).length()
	var r := Vector2(horiz, d.y).length()
	if r > UPPER + FOREARM - 1e-4 or r < absf(UPPER - FOREARM) + 1e-4: return null
	# Two links in the vertical plane, elbow up: the law of cosines.
	var cos_e := (r * r - UPPER * UPPER - FOREARM * FOREARM) / (2.0 * UPPER * FOREARM)
	var elbow := acos(clampf(cos_e, -1.0, 1.0))
	var lift := atan2(d.y, horiz) + atan2(FOREARM * sin(elbow), UPPER + FOREARM * cos(elbow))
	# The wrist turns back what the shoulder and elbow turned, so the turret hangs straight down.
	var wrist_a := lift - elbow
	return {"az": az, "lift": lift, "elbow": elbow, "wrist": wrist_a, "turn": 0.0}

## Where the joints put the turret's face, body frame: forward kinematics.
static func tip(j: Dictionary) -> Vector3:
	var lift := float(j.lift)
	var elbow := float(j.elbow)
	var h := UPPER * cos(lift) + FOREARM * cos(lift - elbow)
	var y := UPPER * sin(lift) + FOREARM * sin(lift - elbow)
	var az := float(j.az)
	return SHOULDER + Vector3(h * sin(az), y - WRIST, h * cos(az))

## Move the joints toward the target at their rate.
func advance(dt: float) -> void:
	var done := true
	for k in joints:
		var now := float(joints[k])
		var want := float(target[k])
		var next := move_toward(now, want, RATE * dt)
		joints[k] = next
		if absf(next - want) > 1e-4: done = false
	placed = done and not stowed
