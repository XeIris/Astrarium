extends SceneTree

# Run with Godot --headless --path . --script res://tools/flighttimecheck.gd.
# Fixed binary substeps make the guarded and complete RK4 runs directly comparable.
class SmallSteps extends Vessel:
	var bound := 1.0 / 64.0
	func step_bound() -> float:
		return bound

# Exercise the real frame driver without constructing its renderer.
class CapturedFlight extends Spaceflight:
	var visual_elapsed := 0.0
	func _init(_ctx: Dictionary) -> void:
		pass
	func bodies() -> Array:
		return state.bodies
	func update_visual(_dt: float, sim_seconds: float) -> void:
		visual_elapsed = sim_seconds

var failures: Array[String] = []

func expect(ok: bool, message: String) -> void:
	if not ok: failures.append(message)

func make_ship(fixed := false) -> Vessel:
	var earth := Body.new()
	earth.name = "Earth"; earth.type = "planet"
	earth.mass = 3.003e-6; earth.radius = 6371.0e3 / Rocketry.AU_M
	earth.alive = true
	var opts := {"vehicle": Vehicles.VEHICLES.saturnv, "parent": earth, "bodies": [earth]}
	var ship: Vessel = SmallSteps.new(opts) if fixed else Vessel.new(opts)
	ship.place_on_pad()
	ship.place_in_orbit(400000.0)
	return ship

func warnings(ship: Vessel) -> int:
	var n := 0
	for event in ship.events:
		if event.msg.begins_with("Flight integrator limit") or event.msg.begins_with("Flight frame limit"):
			n += 1
	return n

func driver(ship: Vessel) -> CapturedFlight:
	var flight := CapturedFlight.new({})
	flight.state = SimState.new()
	for body in ship.bodies: flight.state.bodies.append(body)
	flight.vessel = ship
	flight.active = true
	return flight

func _init() -> void:
	var guarded := make_ship(true)
	var complete := make_ship(true)
	var elapsed := guarded.step(10.0)
	complete.step(elapsed)
	expect(elapsed == 6.25 and guarded.step_guard_hit, "400-step guard must return 6.25 of 10 seconds")
	expect(guarded.coord == elapsed, "coordinate clock must match integrated time")
	expect(guarded.met == complete.met and guarded.clock_delta == complete.clock_delta, "proper and reference clocks must match complete RK4 run")
	expect(guarded.r.distance_to(complete.r) < 1e-8 and guarded.v.distance_to(complete.v) < 1e-8, "guarded state must match the same completed integration")
	expect(guarded.launch_site.r.distance_to(complete.launch_site.r) < 1e-8, "launch-site rotation must use integrated time")
	expect(guarded.downrange == complete.downrange, "downrange must use the synchronized launch site")
	expect(not complete.step_guard_hit, "exactly filling the budget must not report exhaustion")
	expect(warnings(guarded) == 1, "guard exhaustion must appear in the flight event log")
	guarded.step(10.0)
	expect(warnings(guarded) == 1, "consecutive guarded frames must not repeat the warning")
	guarded.step(0.5)
	expect(not guarded.step_guard_hit, "a healthy step must reset guard state")
	guarded.step(10.0)
	expect(warnings(guarded) == 2, "a new guard episode must warn again")

	var natural := make_ship()
	var natural_elapsed := natural.step(10000.0)
	expect(natural.step_guard_hit and natural_elapsed > 0.0 and natural_elapsed < 10000.0, "real orbital step bound must also exhaust on a large request")
	expect(natural.coord == natural_elapsed, "naturally guarded clock must match integrated time")

	var inner_ship := make_ship(true) as SmallSteps
	inner_ship.bound = 1.0 / 4096.0
	var inner := driver(inner_ship)
	inner.update(2.0)
	expect(inner_ship.step_guard_hit and inner_ship.coord == 400.0 / 4096.0, "frame driver must stop after the vessel guard")
	expect(inner.visual_elapsed == inner_ship.coord, "visuals must receive the vessel's elapsed time")
	inner.update(2.0)
	expect(warnings(inner_ship) == 1, "frame driver must preserve warning suppression")
	inner.update(0.01)
	expect(not inner_ship.step_guard_hit, "normal frame must clear an inner guard")

	var outer_ship := make_ship(true)
	var outer := driver(outer_ship)
	outer.update(20.0)
	expect(outer_ship.step_guard_hit and outer_ship.coord == 12.0, "24-step frame guard must advance only 12 of 20 seconds")
	expect(outer.visual_elapsed == 12.0 and warnings(outer_ship) == 1, "outer guard must synchronize visuals and log its limit")
	outer.update(20.0)
	expect(warnings(outer_ship) == 1, "outer guard must not repeat its warning each frame")
	outer.update(0.5)
	expect(not outer_ship.step_guard_hit and outer.visual_elapsed == 0.5, "healthy frame must reset outer guard and preserve normal time")

	var rails := make_ship()
	expect(rails.step(10000.0, {"rails": true}) == 10000.0 and not rails.step_guard_hit and rails.coord == 10000.0, "analytic rails must advance the full request")
	var landed := make_ship()
	landed.place_on_pad(); landed.phase = Vessel.PHASE.LANDED
	expect(landed.step(40.0) == 40.0 and not landed.step_guard_hit and landed.coord == 40.0, "landed branch must retain its full clock advance")
	landed.phase = Vessel.PHASE.DESTROYED
	expect(landed.step(20.0) == 20.0 and landed.coord == 60.0, "destroyed branch must retain coordinate clock advance")
	for message in failures: printerr("FLIGHT TIME FAILED: ", message)
	print("FLIGHT TIME ", "PASS" if failures.is_empty() else "FAIL", " (", failures.size(), " failures)")
	quit(0 if failures.is_empty() else 1)
