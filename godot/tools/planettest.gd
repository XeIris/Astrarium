extends Harness

# ============================================================================
# PLANET HARNESS — rebuilds a web-reference frame for the solid-world, gas
# giant and painter port, from the JSON tools/planetshots.mjs had the web
# build write beside its PNG:
#
#   Godot --path godot res://tools/planettest.tscn -- scene=/abs/earth_vis.json \
#         out=/abs/earth_vis_godot.png band=3 frames=30 [pin=0]
#
# It builds Body objects by hand (id, name, position, spin, the spec turned
# into the `opts` dictionary exactly as attachVisual builds it), the sun list
# the orchestrator would (camera-relative positions under the floating
# origin), the camera at the web camera's absolute position and orientation,
# and runs the real visuals' update() every frame.
#
# NUMBERS FIRST: on the capture frame it prints every scalar uniform whose
# value the GDScript update derived differently from the web build's live
# value (uMeanK, uDecl, uSeaKm, uTeff, uCover, …). Then — unless pin=0 — it
# PINS every uniform, spin phase and vortex to the captured values, so the
# picture compares the shaders alone and is free of clock differences (uTime,
# the uMeanK ease, the random spin a rocky body is born with).
# ============================================================================

var cap: Dictionary
var items: Array = []        # [{viz, body, cap}]
var all_bodies: Array = []
var suns_ctx: Array = []
var painter: Painter
var pin := true
var scene_scale := 1.0

func _setup() -> void:
	PlanetMaps.synchronous = true
	pin = str(args.get("pin", "1")) != "0"
	var txt := FileAccess.get_file_as_string(str(args.scene))
	cap = JSON.parse_string(txt)
	scene_scale = float(cap.sceneScale)
	cam_pos = DVec3.from_array(cap.cam.pos)
	var q: Array = cap.cam.quat
	pipe.scene_cam.transform = Transform3D(Basis(Quaternion(q[0], q[1], q[2], q[3])), Vector3.ZERO)
	pipe.scene_cam.fov = float(cap.cam.fov)
	pipe.scene_cam.near = float(cap.cam.near)
	# Godot builds its frustum (and its light culler's frustum points) in
	# float32; the web build's 3e-7 … 1e5 near/far at true scale is 3e11 to
	# one and degenerates. The far plane only has to clear what is in frame.
	pipe.scene_cam.far = minf(float(cap.cam.far), float(args.get("far", str(float(cap.cam.near) * 1.0e7))))
	pipe.postfx.set_scene_temp(float(cap.sceneMaxTemp))

	# every body, as bare physics (tidal locks look their parent up by name)
	var by_name := {}
	for ab in cap.allBodies:
		var b := Body.new()
		b.id = int(ab.id); b.name = str(ab.name); b.type = str(ab.type)
		b.pos = DVec3.from_array(ab.pos)
		b.luminosity = ab.luminosity
		if ab.gpos != null: b.scene_pos = DVec3.from_array(ab.gpos)
		else: b.scene_pos = b.pos.scaled(scene_scale)
		all_bodies.append(b)
		by_name[b.name] = b
	for s in cap.suns:
		var star: Body = by_name.get(str(s.name))
		var c: Array = s.color
		suns_ctx.append({
			"body": star, "pos_rel": DVec3.from_array(s.posScene).rel_v3(cam_pos),
			"color": Color(c[0], c[1], c[2]), "intensity": float(s.intensity),
		})

	for cb in cap.bodies:
		var b: Body = by_name[str(cb.name)]
		b.mass = float(cb.mass)
		b.spin = cb.spin
		b.spin_phase = float(cb.spinPhase)
		b.cloud_phase = float(cb.cloudPhase)
		b.day_length = float(cb.dayLength)
		b.radius = float(cb.radius)
		var spec: Dictionary = cb.spec
		var opts := opts_from_spec(spec, float(cb.radiusScene), cb.defColor)
		var viz
		match b.type:
			"world": viz = WorldVisual.create_world_visual(b, opts)
			"gas-giant":
				opts["giantPalette"] = GiantVisual.GIANT_PALETTES.get(str(U.nz(opts.get("paletteName"), "jupiter")), GiantVisual.GIANT_PALETTES.jupiter)
				viz = GiantVisual.create_giant_visual(b, opts)
			_: viz = RockyVisual.create_rocky_visual(b, opts)
		pipe.world_root.add_child(viz.group)
		var gs: Array = cb.gscale
		viz.group.scale = Vector3(gs[0], gs[1], gs[2])
		place(viz.group, DVec3.from_array(cb.gpos))
		items.append({"viz": viz, "body": b, "cap": cb})

	painter = Painter.create_painter({
		"get_body": func(id): return U.find(all_bodies, func(x): return x.id == id),
		"get_scene_scale": func(): return scene_scale,
		"root": pipe.world_root,
	})
	for pi in cap.painter:
		var spec = pi.opts
		if spec == null: continue
		apply_paint_spec(spec, by_name)

## The web build's attachVisual opts literal, key for key.
static func opts_from_spec(spec: Dictionary, radius_scene: float, def_color) -> Dictionary:
	var o := {"radiusScene": radius_scene}
	o["color"] = U.nz(spec.get("color"), def_color)
	o["glow"] = spec.get("glow")
	o["paletteName"] = spec.get("palette")
	for k in ["seed", "obliquity", "tidalLock", "hot", "atmosphere", "atmColor", "seaLevel", "rings", "ringColor",
			"land", "albedo", "greenhouse", "surfaceK", "frostK", "biota", "crater", "regolith", "haze",
			"cloudCover", "cloudColor", "atmThick", "ringInner", "ringOuter", "internalHeat", "vortices",
			"transport", "season", "arid", "plateScale", "landRelief", "oceanDepth"]:
		o[k] = spec.get(k)
	return o

## The web build's applyPaintSpec, for the ring/belt/cloud kinds.
func apply_paint_spec(spec: Dictionary, by_name: Dictionary) -> void:
	var b: Body = by_name.get(str(spec.get("body", "")))
	var common := {"bodyId": b.id if b != null else null}
	var kind := str(spec.kind)
	if kind == "cloud":
		painter.add("cloud", U.merged(common, {
			"radius": U.nz(spec.get("radius"), 10.0), "lobes": U.nz(spec.get("lobes"), 1),
			"color": U.nz(spec.get("color"), 0xffcf9a), "density": U.nz(spec.get("density"), 0.7),
			"expandAUperYr": U.nz(spec.get("expand"), 0.0), "seed": U.nz(spec.get("seed"), randf() * 100.0),
			"label": U.nz(spec.get("label"), "ejecta")}))
		return
	var belt := kind == "belt"
	var central := 1.0
	for cb in cap.allBodies:
		if b != null and int(cb.id) == b.id:
			pass
	if b != null:
		for cb in cap.bodies:
			if int(cb.id) == b.id: central = float(cb.mass)
		if b.type == "star": central = 1.0
	painter.add("belt" if belt else "ring", U.merged(common, {
		"centralMass": central, "inner": spec.inner, "outer": spec.outer,
		"count": U.nz(spec.get("count"), 11000 if belt else 26000),
		"ecc": U.nz(spec.get("ecc"), 0.14 if belt else 0.0025),
		"incl": U.nz(spec.get("incl"), 0.16 if belt else 0.001),
		"color": U.nz(spec.get("color"), 0xcdbb99),
		"sizePx": U.nz(spec.get("sizePx"), 2.4 if belt else 2.0),
		"tilt": U.nz(spec.get("tilt"), 0.0),
		"perturberA": spec.get("perturber"),
		"surfaceDensity": U.nz(spec.get("surfaceDensity"), -1.5),
		"label": U.nz(spec.get("label"), kind)}))

func update_camera() -> void:
	pass   # the web camera, fixed

func _step(step: float) -> void:
	var ctx := {
		"suns": suns_ctx, "holes": [], "bodies": all_bodies, "climate": cap.get("climate"),
		"sim_dt": 0.0, "time": t, "scene_scale": scene_scale, "cam_pos": cam_pos,
		"camera": pipe.scene_cam, "viewport_h": 720,
	}
	for it in items:
		it.viz.update(step, ctx)
	painter.update(0.0, cam_pos)
	if frame == frames:
		_compare_and_pin()

const MAT_KEYS := {"surfMat": "surf_mat", "cloudMat": "cloud_mat", "atmoMat": "atmo_mat",
		"mat": "mat", "limbMat": "limb_mat", "ringMat": "ring_mat"}
const CLOCKS := ["uTime"]

func _to_variant(v):
	if v is Array:
		if v.is_empty(): return null
		if v[0] is Array:
			if v[0].size() == 4:
				var p4 := PackedVector4Array()
				for e in v: p4.append(Vector4(e[0], e[1], e[2], e[3]))
				return p4
			var p3 := PackedVector3Array()
			for e in v: p3.append(Vector3(e[0], e[1], e[2]))
			return p3
		if v.size() == 2: return Vector2(v[0], v[1])
		if v.size() == 3: return Vector3(v[0], v[1], v[2])
		if v.size() == 4: return Vector4(v[0], v[1], v[2], v[3])
		var pf := PackedFloat32Array()
		for e in v: pf.append(float(e))
		return pf
	return v

func _compare_and_pin() -> void:
	for it in items:
		var viz = it.viz
		var cb: Dictionary = it.cap
		print("--- ", cb.name, " (", cb.type, ")")
		for mk in cb.mats:
			var m: ShaderMaterial = viz.get(MAT_KEYS[mk])
			if m == null:
				print("  [missing material] ", mk); continue
			var names := {}
			for u in m.shader.get_shader_uniform_list():
				names[u.name] = u.type
			var web: Dictionary = cb.mats[mk]
			for k in web:
				if not names.has(k):
					continue
				var wv = web[k]
				var ours = m.get_shader_parameter(k)
				if (wv is float or wv is int) and not (k in CLOCKS):
					var o := float(ours) if ours != null else NAN
					if absf(o - float(wv)) > 1e-3 * maxf(1.0, absf(float(wv))):
						print("  %s.%s  godot=%s  web=%s" % [mk, k, o, wv])
				if pin and wv != null:
					var val = _to_variant(wv)
					if val == null: continue
					if names[k] == TYPE_INT: val = int(val)
					elif names[k] == TYPE_PACKED_FLOAT32_ARRAY and not (val is PackedFloat32Array):
						val = PackedFloat32Array(wv)
					m.set_shader_parameter(k, val)
		if args.has("dbg"):
			for mk in cb.mats:
				var m: ShaderMaterial = viz.get(MAT_KEYS[mk])
				for k in ["uSunDir", "uSunColor", "uSunInt", "uSunCount", "uMapKind", "uColorMap"]:
					print("  dbg %s.%s = %s" % [mk, k, m.get_shader_parameter(k)])
		if pin:
			viz.core.rotation.y = float(cb.coreRotY)
			if cb.cloudRotY != null and viz.get("clouds") != null:
				viz.clouds.rotation.y = float(cb.cloudRotY)
	# painter: pin the swarm uniforms that are not clocks (size, colour)
	if pin:
		for i in mini(painter.items.size(), cap.painter.size()):
			var u = cap.painter[i].uniforms
			if u == null: continue
			var m: ShaderMaterial = painter.items[i].mat
			for k in ["uColor", "uSize", "uSoft", "uDensity"]:
				if u.has(k):
					m.set_shader_parameter(k, _to_variant(u[k]))
