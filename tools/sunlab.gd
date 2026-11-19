extends Harness
# THE SOLAR LAB: the Sun's visual (or a catalogue star's) alone, its active regions and one flare placed by
# hand, for pictures of the photosphere, loops and eruptions at a chosen moment.
#   Godot --path . res://tools/sunlab.tscn -- out=/abs/x.png frames=20 [x=0.3]
#     [at=limb|top|disc] [energy=2] [band=5] [cam=r,theta,phi] [regions=3] [teff=5772]
#     [star=sun|proxima|betelgeuse|vega|siriusB|… (stars and white dwarfs)]
#     [close=1] [xto=0.9] [orbit=0.6] [seq=/abs/prefix every=2] [qlon=0 qlat=0.5 qtilt=1.57] [spin=0.1] [probe=1]
#     [puff=1.6,-0.4,1.57 puffto=4]
# x is the flare's progress through its event (0..1); no flare without it. `at` puts
# it on the east limb (a prominence against the sky, its loops along the line of
# sight), on the north limb seen from below the equator (`top`: the loops side-on)
# or at the disc centre (a filament and its ribbons). The clock is stopped: activity
# only moves when x does. For a clip, `xto` carries the flare on to that progress over
# the run, `orbit` turns the camera by that many radians, and `seq` saves every
# `every`-th frame as <seq>_0000.png…; `qlon`/`qlat` move the first quiescent
# prominence (longitude 0 is the east limb).

var body: Body
var viz
var x0 := -1.0
var x1 := -1.0
var phi0 := 0.0
var probe_t0 := 0
var puff = null
var puff_r := Vector2.ZERO

func _setup() -> void:
	var spec := Starcat.star_spec(str(args.get("star", "sun")), {"pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0]})
	# The lab draws photospheres: stars and white dwarfs. A neutron star has its own visual.
	if spec.is_empty() or not (str(spec.type) in ["star", "white-dwarf"]):
		push_error("sunlab: star=%s is not a star or white dwarf" % str(args.get("star", "sun")))
		get_tree().quit(1)
		return
	# The catalogue's measured Teff wins inside star_spec, so an override goes on after it.
	if args.has("teff"): spec.teff = float(args.teff)
	var teff := float(spec.teff)
	body = Body.new()
	body.type = str(spec.type)
	body.mass = float(spec.mass); body.mass0 = body.mass
	Derive.derive_body(body, spec)
	var opts := VisualOpts.new()
	opts.radius_scene = 1.0
	opts.oblate = 1.0 / (1.0 - float(body.structure.get("flattening", 0.0)))
	opts.teff = body.teff
	opts.radius_sun = body.radius_sun
	opts.spin_frac = body.spin_frac
	opts.color = Stellar.blackbody_color(float(body.teff))
	viz = Bodies.create_body_visual(body, opts)
	pipe.world_root.add_child(viz.group)
	# Debugging switches: hide a part to see what it contributes.
	if args.has("nocorona"): viz.corona.visible = false
	if args.has("nocore"): viz.core.visible = false
	# spin= scales the display rotation (the Sun turns every few seconds), for clips.
	if args.has("spin"):
		viz.omega *= float(args.spin)
		viz.mat.set_shader_parameter("uOmega", viz.omega)
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
	if args.has("x"):
		x0 = clampf(float(args.x), 0.0, 0.999)
		x1 = clampf(float(args.get("xto", args.x)), 0.0, 0.999)
	if args.has("qlon") and not viz.quiescent.is_empty():
		viz.quiescent[0].lon = float(args.qlon)
		if args.has("qlat"): viz.quiescent[0].lat = float(args.qlat)
		if args.has("qtilt"): viz.quiescent[0].tilt = float(args.qtilt)
	# puff=r[,lat,lon[,tau]]: an ejected puff of the envelope r stellar radii out (longitude 0
	# is the east limb, π/2 faces the camera); puffto= carries it on over the run.
	if args.has("puff") and viz.envelope != null:
		var pv: PackedStringArray = str(args.puff).split(",")
		var plat := float(pv[1]) if pv.size() > 1 else 0.3
		var plon := float(pv[2]) if pv.size() > 2 else 0.0
		puff = viz.eject(Vector3(cos(plat) * cos(plon), sin(plat), cos(plat) * sin(plon)))
		puff.r = float(pv[0])
		if pv.size() > 3: puff.tau = float(pv[3])
		puff_r = Vector2(puff.r, float(args.get("puffto", pv[0])))
	# close=1 centres the camera on the first region, 0.9 R away.
	if args.get("close", "0") == "1":
		var v: Vector3 = act.region_dir(act.regions[0])
		cam_target = DVec3.new(v.x, v.y, v.z)
		if not args.has("cam"): cam_radius = 0.9
	phi0 = cam_phi

func _step(step: float) -> void:
	if body == null: return      # rejected in _setup; the quit lands next frame
	# probe=1: wall-clock frame time over the second half of the run, VSync off.
	if args.has("probe"):
		if frame == 1: DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		if frame == frames / 2: probe_t0 = Time.get_ticks_usec()
		if frame == frames - 1:
			print("SUNLAB PROBE ms/frame=%.3f" % (float(Time.get_ticks_usec() - probe_t0) / 1000.0 / float(frames - 1 - frames / 2)))
	var u := clampf(float(frame) / float(maxi(frames, 1)), 0.0, 1.0)
	var act: Stellar.ActivityModel = body.activity
	if x0 >= 0.0 and not act.flares.is_empty():
		act.flares[0].t = lerpf(x0, x1, u) * float(act.flares[0].duration)
	if args.has("orbit"): cam_phi = phi0 + float(args.orbit) * u
	if puff != null: puff.r = lerpf(puff_r.x, puff_r.y, u)
	var every := maxi(int(args.get("every", "1")), 1)
	# Captures stop at `frames`; without out= nothing else ends the run, so quit once the
	# last one has been taken.
	if args.has("seq") and not args.has("out") and frame >= frames + 2: get_tree().quit()
	if args.has("seq") and frame % every == 0 and frame < frames:
		var path := "%s_%04d.png" % [str(args.seq), frame / every]
		pipe.capture_next(func(img: Image): img.save_png(path))
	var ctx := VisualCtx.new()
	ctx.camera = pipe.scene_cam
	ctx.cam_pos = cam_pos
	ctx.time = t
	ctx.scene_scale = 1.0
	ctx.sim_dt = 0.0
	ctx.bodies = [body]
	ctx.viewport_h = float(pipe.render_size.y)
	ctx.visible_band = pipe.postfx.band == Spectrum.VISIBLE_BAND
	viz.update(step, ctx)
