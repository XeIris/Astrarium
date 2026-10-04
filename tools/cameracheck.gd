extends SceneTree

var checks := 0
var failures := 0

func check(label: String, accepted: bool) -> void:
	checks += 1
	if not accepted:
		failures += 1
		print("CAMERACHECK FAIL ", label)

func body(at: DVec3, rendered_radius: float) -> Body:
	var result := Body.new()
	result.scene_pos = at
	result.radius_scene = rendered_radius
	return result

func _init() -> void:
	var origin := DVec3.new()
	var camera := OrreryCamera.new(origin)
	check("controller shares the stage's absolute origin", camera.position == origin)
	camera.target.set_v(1e9, 2e9, -3e9)
	camera.theta = PI / 2.0
	camera.phi = 0.0
	camera.jump_radius(0.0002)
	var basis := camera.update_orbit()
	check("small offset survives large absolute coordinates", absf(origin.x - camera.target.x - camera.radius) < 1e-7)
	check("orbit faces the subject", (-basis.z).dot(camera.target.rel_v3(origin).normalized()) > 0.999999)
	var earth := body(camera.target.clone(), 1e-5)
	check("picking subtracts the double origin before float conversion", camera.pick([earth], Vector2(640, 360), Vector2(1280, 720), 50.0, basis) == earth)
	var hidden := body(origin.add(DVec3.new(1.0, 0, 0)), 0.1)
	check("body behind camera is not picked", camera.pick([hidden], Vector2(640, 360), Vector2(1280, 720), 50.0, basis) == null)
	var closer := body(origin.add(DVec3.new(-0.0001, 0, 0)), 1e-5)
	check("frontmost body wins independent of array order", camera.pick([earth, closer], Vector2(640, 360), Vector2(1280, 720), 50.0, basis) == closer)
	check("true-scale near plane stays resolvable", camera.near_plane([earth], false, 0.01) > 0.0 and camera.near_plane([earth], false, 0.01) < camera.radius)
	camera.target.set_v(0, 0, 0)
	camera.jump_radius(10)
	earth.scene_pos.set_v(1, 0, 0)
	camera.glide_target_to(earth.scene_pos)
	check("nearby focus does not teleport target", camera.target.x == 0 and camera.offset.x == -1)
	camera.track_follow(earth, 0.1)
	var old_target := camera.target.x
	earth.scene_pos.x += 1000
	camera.track_follow(earth, 0.0)
	check("follow tracks full body displacement without lag", absf(camera.target.x - old_target - 1000) < 1e-10)
	earth.scene_pos.x = 1e6
	camera.glide_target_to(earth.scene_pos)
	check("system-wide change cuts to destination", camera.offset.length_sq() == 0 and camera.target.x == earth.scene_pos.x)
	var slow := OrreryCamera.new(DVec3.new())
	var fast := OrreryCamera.new(DVec3.new())
	slow.jump_radius(1); fast.jump_radius(1)
	slow.radius_to = 1000; fast.radius_to = 1000
	for i in 30: slow.ease_radius(1.0 / 30)
	for i in 144: fast.ease_radius(1.0 / 144)
	check("distance easing has the same time constant at 30/144fps", absf(log(slow.radius / fast.radius)) < 1e-12)
	slow.zoom_orbit(-100)
	var zoomed := slow.radius
	slow.ease_radius(10)
	check("wheel zoom cancels a previous ease", slow.radius_to == null and slow.radius == zoomed)
	var bindings := ControlBindings.new("")
	var held := {KEY_W: true, KEY_SHIFT: true}
	camera.position.set_v(1e9, 0, 0)
	camera.yaw = PI / 2; camera.pitch = 0
	camera.update_free(0.25, bindings, held)
	check("free flight uses existing physical bindings and fast multiplier", absf(camera.position.x - 1e9 - 12) < 1e-6)
	camera.update_free(1, bindings, {KEY_W: true, KEY_S: true})
	check("opposed movement cancels", absf(camera.position.x - 1e9 - 12) < 1e-6)
	check("empty free scene has a finite near plane", camera.near_plane([], true, 0.002) == 0.01)
	for request in [{}, {"radius": 1e-6}, {"radius": 20000.0}, {"mode": "surface", "theta": -1.0}, {"phi": 100, "radius": null}]:
		check("valid authored camera request %s" % str(request), OrreryCamera.request_error(request).is_empty())
	for request in [null, [], "orbit", {"raduis": 10}, {"mode": "orbti"}, {"mode": null}, {"radius": 0}, {"radius": -1}, {"radius": INF}, {"radius": NAN}, {"radius": true}, {"radius": "10"}, {"phi": NAN}, {"theta": []}]:
		check("invalid request rejected with diagnostic %s" % str(request), not OrreryCamera.request_error(request).is_empty())
	camera.radius_to = 100
	var previous_theta := camera.theta
	var previous_phi := camera.phi
	var previous_radius := camera.radius
	check("rejected mixed patch leaves distance, angles and pending ease intact", not camera.apply_request({"theta": 2, "phi": 7, "radius": -1}) and camera.theta == previous_theta and camera.phi == previous_phi and camera.radius == previous_radius and camera.radius_to == 100)
	for distance in [1e300, pow(2.0, -1030.0), 1e-6 - 1e-12, 20000.0 + 1e-6]:
		var request := {"theta": 2, "phi": 7, "radius": distance}
		check("unsupported finite authored distance rejected %s" % str(distance), not OrreryCamera.request_error(request).is_empty())
		check("unsupported distance leaves complete patch untouched %s" % str(distance), not camera.apply_request(request) and camera.theta == previous_theta and camera.phi == previous_phi and camera.radius == previous_radius and camera.radius_to == 100)
	var bounded := OrreryCamera.new(DVec3.new())
	for distance in [1e-6, 20000.0]:
		check("inclusive distance bound applies %s" % str(distance), bounded.apply_request({"radius": distance}) and bounded.radius == distance)
		var bounded_basis := bounded.update_orbit()
		check("inclusive distance bound produces finite camera basis %s" % str(distance), bounded_basis.x.is_finite() and bounded_basis.y.is_finite() and bounded_basis.z.is_finite())
	bounded.jump_radius(1e-7)
	check("internal framing retains its independently derived distance", bounded.radius == 1e-7)
	camera.apply_request({"radius": 7, "theta": -1.0, "phi": 3})
	check("authored distance cancels pending ease", camera.radius == 7 and camera.radius_to == null)
	check("authored theta avoids orbit poles", camera.theta == 0.02 and camera.phi == 3)
	print("CAMERACHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
