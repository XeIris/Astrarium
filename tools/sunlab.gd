extends Harness
# THE SOLAR LAB: the Sun's visual alone, its active regions and one flare placed by
# hand, for pictures of the photosphere, loops and eruptions at a chosen moment.
#   Godot --path . res://tools/sunlab.tscn -- out=/abs/x.png frames=20 [x=0.3]
#     [at=limb|top|disc] [energy=2] [band=5] [cam=r,theta,phi] [regions=3] [teff=5772]
#     [close=1]
# x is the flare's progress through its event (0..1); no flare without it. `at` puts
# it on the east limb (a prominence against the sky, its loops along the line of
# sight), on the north limb seen from below the equator (`top`: the loops side-on)
# or at the disc centre (a filament and its ribbons). The clock is stopped: activity
# only moves when x does.

var body: Body
var viz

func _setup() -> void:
	var teff := float(args.get("teff", "5772"))
	var spec := Starcat.star_spec("sun", {"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0], "teff": teff})
	body = Body.new()
	body.type = "star"
	body.mass = float(spec.mass); body.mass0 = body.mass
	Derive.derive_body(body, spec)
	var opts := VisualOpts.new()
	opts.radius_scene = 1.0
	opts.oblate = 1.0
	opts.teff = body.teff
	opts.radius_sun = body.radius_sun
	opts.spin_frac = body.spin_frac
	opts.color = Stellar.blackbody_color(float(body.teff))
	viz = Bodies.create_body_visual(body, opts)
	pipe.world_root.add_child(viz.group)
	place(viz.group, DVec3.new())
	pipe.scene_cam.near = 0.002
	pipe.scene_cam.far = 2000.0
	cam_radius = 3.4
	cam_theta = PI / 2.0
	cam_phi = PI / 2.0
	if args.has("cam"):
		var c: PackedStringArray = str(args.cam).split(",")
		cam_radius = float(c[0])
		if c.size() > 1: cam_theta = float(c[1])
		if c.size() > 2: cam_phi = float(c[2])
	pipe.postfx.set_scene_temp(maxf(teff, 5800.0))

	# Active regions in the belts, one of them where the flare is wanted. The camera
	# looks down −Z from +Z, so longitude 0 is the limb and π/2 the disc centre.
	var act: Stellar.ActivityModel = body.activity
	act.regions.clear()
	act.flares.clear()
	act.cmes.clear()
	act.next = INF
	var at := str(args.get("at", "limb"))
	var lons := [0.0 if at == "limb" else PI / 2.0, 1.15, 2.1, 0.55, 1.9, 0.3]
	if at == "top" and not args.has("cam"):
		cam_theta = PI - 0.30
	var lats := [0.30, -0.24, 0.38, -0.42, 0.20, 0.50]
	for i in int(args.get("regions", "3")):
		act.regions.append({"lat": lats[i], "lon": lons[i], "strength": 0.85 - 0.12 * i,
			"age": 0.2, "life": 0.4})
	if args.has("x"):
		var f := {"t": 0.0, "duration": 0.15, "energy": float(args.get("energy", "2.0")),
			"amp": 0.0, "dir": act.region_dir(act.regions[0]), "region": act.regions[0]}
		f.t = clampf(float(args.x), 0.0, 0.999) * f.duration
		act.flares.append(f)
	# close=1 centres the camera on the first region, 0.9 R away.
	if args.get("close", "0") == "1":
		var v: Vector3 = act.region_dir(act.regions[0])
		cam_target = DVec3.new(v.x, v.y, v.z)
		if not args.has("cam"): cam_radius = 0.9

func _step(step: float) -> void:
	var ctx := VisualCtx.new()
	ctx.camera = pipe.scene_cam
	ctx.cam_pos = cam_pos
	ctx.time = t
	ctx.scene_scale = 1.0
	ctx.sim_dt = 0.0
	ctx.bodies = [body]
	ctx.viewport_h = float(pipe.render_size.y)
	viz.update(step, ctx)
