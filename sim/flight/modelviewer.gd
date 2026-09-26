class_name ModelViewer
extends RefCounted

# ============================================================================
# THE MODEL VIEWER — port of sim/flight/modelviewer.js.
# ----------------------------------------------------------------------------
# The vehicles are built at their real dimensions from the same numbers the
# physics uses, and in flight you almost never get to see that. A rocket in a
# launch is a hundred metres away and lit from one side; a lander is a dot on a
# grey plain; an ion cruiser is in the dark. So this is a studio: neutral
# ground, three-point light, a turntable, and nothing else in the scene.
#
# It exists to answer three questions that flight cannot:
#
#   HOW BIG IS IT?      A 1.75 m figure stands at the base and a rule is drawn
#                       up the side in ten-metre divisions. Scale is a
#                       comparison, not a number — 110 m means nothing until
#                       there is a person next to it.
#   WHAT IS IT MADE OF? The stack can be pulled apart along its own axis, each
#                       stage separated in proportion to its length, so the
#                       interstages, the engine clusters and the payload are
#                       all visible at once.
#   WHAT MOVES?         Legs, fins, arrays and gimbals all run from the same
#                       `update` the flight model drives, so what you see here
#                       is what will move on the vehicle.
#
# LIGHTING is a photographic three-point setup rather than a physical one,
# because the question here is "what shape is this" and not "what would this
# look like at Merritt Island at 09:00". A key at 35° above and to the left, a
# fill at a quarter of its strength opposite to open the shadows, and a rim
# behind to separate a white vehicle from a grey ground — which is exactly the
# problem every NASA publicity photograph of a rocket had to solve.
#
# GODOT NOTES
#   · Everything lives under pipe.model_root and is drawn by pipe.model_cam in
#     pipe.model_vp, through render/postfx.gd (bloom + ACES), as the web studio
#     drew through sim/postfx.js. The orchestrator switches the pipeline to
#     Mode.MODEL; this file never touches the mode.
#   · render/pipeline.gd's neutral_env() turns Godot's ambient OFF, so the
#     studio sets up its own light here: three light energies are divided by π
#     (Godot's non-physical light units already carry the π that three's
#     Lambert divides out — measured, see tools/crafttest.gd add_rig()).
#   · THREE.HemisphereLight has no Godot node. Its irradiance is
#     mix(ground, sky, ½ + ½ n·y) = (sky+ground)/2 + (sky−ground)/2 · n·y, which
#     is EXACTLY an ambient term plus a pair of directional lights along ±Y —
#     one ordinary from above, one NEGATIVE from below, each contributing
#     max(0, ±n·y). Both are diffuse-only (light_specular = 0), as three's
#     hemisphere light is.
#   · The studio is metres across, so its camera moves; the floating origin of
#     PORT_GUIDE §3 is for the orrery, where float32 runs out.
# ============================================================================

const CM := preload("res://sim/flight/craftmodel.gd")

const GRID_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;
uniform float uStep = 1.0;
uniform float uRadius = 100.0;
uniform vec3 uCol;
uniform vec3 uBg;
varying vec3 vP;
void vertex() { vP = VERTEX; }
void fragment() {
	// Anti-aliased grid: the line width is set from the screen-space
	// derivative so a line is one pixel wide however far away it is. A fixed
	// width would either alias into moiré at range or vanish underfoot.
	// vP is the LOCAL position and the mesh is a plane in XY, so the two axes
	// it spans are x and y — z is identically 0 whatever the mesh is rotated
	// to. Sampled as .xz the second axis is constant, its fwidth is 0, and the
	// division is 0/0: lines along one axis only, and a fade that is not radial.
	vec2 g = abs(fract(vP.xy / uStep - 0.5) - 0.5) / fwidth(vP.xy / uStep);
	float line = 1.0 - min(min(g.x, g.y), 1.0);
	vec2 g10 = abs(fract(vP.xy / (uStep * 10.0) - 0.5) - 0.5) / fwidth(vP.xy / (uStep * 10.0));
	line = max(line, (1.0 - min(min(g10.x, g10.y), 1.0)) * 1.6);
	float fade = 1.0 - smoothstep(uRadius * 0.35, uRadius, length(vP.xy));
	ALBEDO = mix(uBg, uCol, clamp(line, 0.0, 1.0));
	ALPHA = fade;
}
"""

var pipe: RenderPipeline
var root: Node3D
var camera: Camera3D
var key_l: DirectionalLight3D
var fill_l: DirectionalLight3D
var rim_l: DirectionalLight3D
var grid: MeshInstance3D
var grid_mat: ShaderMaterial
var figure: Node3D
var rule_group: Node3D

var craft = null          # CraftModel.Craft
## {key, ...the vehicle spec} of the vehicle on the turntable, or null.
var vehicle = null
var height := 1.0
var span := 1.0
var mid_y := 0.5
var radius := 1.0
## Turntable state. `spin` is the idle rotation; it stops the moment the viewer
## takes hold of the model, because an object that keeps moving under your
## hand cannot be inspected. The orchestrator writes spin / held directly (the
## "turntable" toggle), as the web page did.
var cam := {"yaw": 0.9, "pitch": 0.20, "dist": 3.0, "spin": 0.10, "held": false, "explode": 0.0, "want_explode": 0.0}
var deploy_all := 1.0
var _retried := {}
var _waiting := ""

static func create_model_viewer(p: RenderPipeline) -> ModelViewer:
	return ModelViewer.new(p)

func _init(p: RenderPipeline) -> void:
	pipe = p
	camera = pipe.model_cam
	camera.fov = 38.0
	camera.keep_aspect = Camera3D.KEEP_HEIGHT
	root = Node3D.new()
	root.name = "ModelViewer"
	pipe.model_root.add_child(root)

	# The rig is carried ON the camera, not fixed to the world. A studio
	# photographer moves the lights with the subject; a fixed rig means half of
	# every turntable revolution is spent looking at the shadow side, which is
	# exactly the problem this viewer exists to solve.
	key_l = _dir(0xfff3e4, 2.9)
	fill_l = _dir(0xbfd4f0, 0.8)
	rim_l = _dir(0xe8f0ff, 1.9)
	_hemisphere(0x2a3340, 0x14161a, 0.55)

	grid_mat = ShaderMaterial.new()
	var sh := Shader.new(); sh.code = GRID_SHADER
	grid_mat.shader = sh
	grid_mat.set_shader_parameter("uCol", _lin3(0x55677a))
	grid_mat.set_shader_parameter("uBg", _lin3(0x101318))
	grid = MeshInstance3D.new()
	grid.mesh = CM._to_mesh(CM._plane(1, 1), grid_mat)
	grid.rotation_order = EULER_ORDER_XYZ
	grid.rotation.x = -PI / 2.0
	root.add_child(grid)

	figure = _human()
	root.add_child(figure)
	rule_group = Node3D.new()
	root.add_child(rule_group)

func _dir(hex: int, intensity: float) -> DirectionalLight3D:
	var l := DirectionalLight3D.new()
	l.light_color = Color.hex((hex << 8) | 0xff)
	l.light_energy = intensity / PI
	root.add_child(l)
	return l

static func _lin3(hex: int) -> Vector3:
	var c := U.lin(hex)
	return Vector3(c.r, c.g, c.b)

## THREE.HemisphereLight(sky, ground, intensity), exactly, for diffuse — see
## the header.
func _hemisphere(sky_hex: int, ground_hex: int, intensity: float) -> void:
	var sky := U.lin(sky_hex); var gnd := U.lin(ground_hex)
	var avg := Color((sky.r + gnd.r) * 0.5, (sky.g + gnd.g) * 0.5, (sky.b + gnd.b) * 0.5)
	var half := Color((sky.r - gnd.r) * 0.5, (sky.g - gnd.g) * 0.5, (sky.b - gnd.b) * 0.5)
	var env := pipe.env_model
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	var am := maxf(maxf(avg.r, avg.g), maxf(avg.b, 1e-6))
	# Environment colours are sRGB and converted, like three's hex; these are
	# linear sums, so they go back through linear_to_srgb first.
	env.ambient_light_color = Color(avg.r / am, avg.g / am, avg.b / am).linear_to_srgb()
	env.ambient_light_energy = am * intensity / PI
	var hm := maxf(maxf(absf(half.r), absf(half.g)), maxf(absf(half.b), 1e-6))
	var hc := Color(absf(half.r) / hm, absf(half.g) / hm, absf(half.b) / hm).linear_to_srgb()
	for s in [1.0, -1.0]:
		var l := DirectionalLight3D.new()
		l.light_color = hc
		l.light_energy = hm * intensity / PI
		l.light_negative = s < 0.0
		l.light_specular = 0.0
		# s = +1 shines DOWN (lights n·y > 0); s = −1 shines UP, negative.
		l.basis = Basis.looking_at(Vector3(0, -s, 0), Vector3(0, 0, 1))
		root.add_child(l)

## The human figure. 1.75 m, and deliberately a silhouette rather than a model:
## the eye reads a person from the proportions alone, and anything more
## detailed would invite you to look at it instead of at the vehicle.
func _human() -> Node3D:
	var g := Node3D.new()
	var m := StandardMaterial3D.new()
	m.albedo_color = Color.hex(0xd8641fff)
	m.roughness = 0.85; m.metallic = 0.0
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
	var add := func(geo, pos: Vector3) -> void:
		var mi := MeshInstance3D.new()
		mi.mesh = CM._to_mesh(geo, m)
		mi.position = pos
		g.add_child(mi)
	add.call(CM._capsule(0.19, 0.72, 4, 10), Vector3(0, 1.10, 0))
	add.call(CM._sphere(0.115, 12, 10), Vector3(0, 1.66, 0))
	for s in [-1.0, 1.0]:
		add.call(CM._capsule(0.085, 0.62, 4, 8), Vector3(s * 0.10, 0.40, 0))
		add.call(CM._capsule(0.062, 0.56, 4, 8), Vector3(s * 0.30, 1.12, 0))
	return g

## The rule: a graduated bar beside the vehicle, in tens of metres.
func _build_rule(H: float) -> void:
	for c in rule_group.get_children():
		c.queue_free()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color.hex(0x6f8496ff)
	var step := 50.0 if H > 200.0 else (10.0 if H > 60.0 else (5.0 if H > 12.0 else 1.0))
	var pts := PackedVector3Array([Vector3.ZERO, Vector3(0, H, 0)])
	var y := 0.0
	while y <= H + 1e-6:
		var long := int(U.jround(y / step)) % 5 == 0
		pts.append(Vector3(0, y, 0)); pts.append(Vector3(H * 0.035 if long else H * 0.018, y, 0))
		y += step
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = pts
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	am.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.mesh = am
	rule_group.add_child(mi)
	rule_group.set_meta("step", step)

## Put a vehicle on the turntable. Returns {key, ...spec}, or null for an
## unknown key.
##
## Warms this vehicle's authored mesh, and builds again when it lands.
## build_craft is synchronous by design, so the first call here draws the
## procedural fallback (unless the model is already cached) and update()
## replaces it once the threaded load settles — which is the right way round:
## the studio opens instantly on something, rather than on nothing. ONE retry
## per vehicle: a .glb that loads but carries no `stage_` node settles with no
## model while build_craft still falls back, and an unguarded rebuild would
## repeat without bound.
func load(vehicle_key: String):
	var veh = CM.vehicle(vehicle_key)
	if veh == null:
		return null
	CraftAssets.preload_craft(vehicle_key)
	_waiting = vehicle_key
	if craft != null:
		root.remove_child(craft.group)
		craft.group.queue_free()
		craft = null
	vehicle = (veh as Dictionary).duplicate()
	vehicle["key"] = vehicle_key
	craft = CM.build_craft(veh)
	root.add_child(craft.group)
	# Frame from the MODEL's own bounds, not from the stacked stage lengths.
	# Those two disagree wherever a vehicle is not a simple stack — the lunar
	# module's legs reach far outside its 6 m of stage height, an aeroshell is
	# wider than it is tall, and a Shuttle's boosters sit alongside rather than
	# under. A box measured off the geometry cannot be wrong about any of them.
	var bb: AABB = CM.measure(craft.group)
	var size := bb.size
	height = craft.height
	if not (height > 0.0):
		height = 0.0
		for s in veh.stages: height += float(s.L)
	# What has to fit vertically is the larger of the height and the width, so
	# a squat, wide vehicle is not cropped by a frame sized for a tall one.
	span = maxf(maxf(size.y, size.x * 0.8), maxf(size.z * 0.8, 1.0))
	mid_y = bb.get_center().y
	radius = maxf(size.x, size.z) * 0.5

	figure.position = Vector3(radius + 1.4, 0, radius * 0.5)
	figure.visible = span > 3.5
	_build_rule(height)
	rule_group.position = Vector3(-(radius + 1.2), 0, 0)

	# A grid whose squares are a size you can name: metres for a lander, tens
	# of metres for a launcher.
	grid_mat.set_shader_parameter("uStep", 10.0 if span > 60.0 else (5.0 if span > 12.0 else 1.0))
	grid_mat.set_shader_parameter("uRadius", span * 3.2)
	grid.scale = Vector3(span * 7.0, span * 7.0, 1.0)

	cam.dist = 1.95
	cam.yaw = 0.9
	cam.pitch = 0.10
	cam.explode = 0.0; cam.want_explode = 0.0
	return vehicle

## Stage-by-stage statistics for the panel, all derived rather than stored.
## The Δv / mass / TWR derivations belong to sim/flight/vehicles.gd
## (stage_delta_v, gross_mass, total_delta_v, pad_twr); until that file exists
## they come back null and the rows carry only what the spec states.
func stats():
	if vehicle == null: return null
	var vs = CM.vehicle_data().get("script")
	var can := func(fn: String) -> bool:
		if vs == null: return false
		for m in (vs as Script).get_script_method_list():
			if m.name == fn: return true
		return false
	var rows := []
	var st: Array = vehicle.stages
	for i in st.size():
		var s: Dictionary = st[i]
		var e = s.get("engine")
		rows.append({
			"key": s.key, "name": s.get("name", s.key),
			"L": s.L, "D": s.D, "dry": s.get("dry"), "prop": s.get("prop"),
			"engine": ("%d× %s" % [int(s.count), e.name]) if e != null else "—",
			"thrust": float(e.thrustVac) * float(s.count) if e != null else 0.0,
			"isp": float(e.ispVac) if e != null else 0.0,
			"dv": vs.stage_delta_v(vehicle, i) if can.call("stage_delta_v") else null,
		})
	return {
		"name": vehicle.name, "height": height, "rows": rows,
		"gross": vs.gross_mass(vehicle) if can.call("gross_mass") else null,
		"dv": vs.total_delta_v(vehicle) if can.call("total_delta_v") else null,
		"twr": vs.pad_twr(vehicle, 9.80665) if can.call("pad_twr") else null,
	}

func set_explode(v: float) -> void:
	cam.want_explode = clampf(v, 0.0, 1.0)

func set_deploy(on) -> void:
	deploy_all = 1.0 if on else 0.0

## Mouse drag in CSS pixels, as the web's pointermove deltas.
func drag(dx: float, dy: float) -> void:
	cam.held = true
	cam.yaw -= dx * 0.008
	cam.pitch = clampf(cam.pitch - dy * 0.006, -1.35, 1.45)

## A wheel step in the DOM's deltaY units (≈ +100 per notch away from you;
## Godot's MOUSE_BUTTON_WHEEL_DOWN is +100, WHEEL_UP −100).
func wheel(delta_y: float) -> void:
	cam.dist = clampf(cam.dist * (1.0 + delta_y * 0.0012), 0.45, 40.0)

func update(dt: float) -> void:
	if craft == null: return
	# The warm-up load finishing is the rebuild signal (the JS awaited the
	# promise; here the threaded load is polled).
	if _waiting != "" and CraftAssets.poll(_waiting):
		var k := _waiting
		_waiting = ""
		if CraftAssets.has_model(k) and vehicle != null and vehicle.key == k \
				and not craft.authored and not _retried.has(k):
			_retried[k] = true
			var keep := cam.duplicate()
			load(k)
			cam = keep
	if not cam.held: cam.yaw += cam.spin * dt
	cam.explode += (cam.want_explode - cam.explode) * (1.0 - exp(-dt * 4.0))

	# The stack is pulled apart along its own axis, each stage moved in
	# proportion to how far up the stack it sits — so the gaps are even and the
	# vehicle stays recognisable instead of scattering.
	var attached := {}; var deploy := {}
	for st in craft.stages:
		st.group.position.y = st.base_y + cam.explode * st.base_y * 0.55
		st.group.visible = true
		st.sep = null
		attached[st.key] = true
		deploy[st.key] = deploy_all
	craft.update({"dt": dt, "attached": attached, "deploy": deploy,
		"gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})

	# Frame the whole stack: the camera orbits the vehicle's mid-height at a
	# distance set by the height itself, so a 7 m lander and a 120 m launcher
	# are both filled to the same fraction of the frame.
	var H: float = span * (1.0 + cam.explode * 0.5)
	var mid: float = mid_y + span * cam.explode * 0.28
	var d: float = cam.dist * H
	var cp := cos(cam.pitch); var sp := sin(cam.pitch)
	var pos := Vector3(cos(cam.yaw) * cp * d, mid + sp * d, sin(cam.yaw) * cp * d)
	camera.transform = Transform3D(Basis.looking_at(Vector3(0, mid, 0) - pos, Vector3.UP), pos)
	# Key 40° off the camera axis and above, fill 70° the other way and low,
	# rim behind and high: the standard three-point setup, in the camera's own
	# frame so it holds at every angle.
	var place := func(light: DirectionalLight3D, d_az: float, elev: float) -> void:
		var a: float = cam.yaw + d_az
		var dir := Vector3(cos(a) * cos(elev), sin(elev), sin(a) * cos(elev))
		light.basis = Basis.looking_at(-dir, Vector3.UP if absf(dir.y) < 0.999 else Vector3(0, 0, 1))
	place.call(key_l, -0.70, 0.62)
	place.call(fill_l, 1.15, 0.12)
	place.call(rim_l, PI + 0.35, 0.75)

	camera.near = maxf(H * 0.002, 0.02)
	camera.far = H * 200.0

## The camera's aspect follows the viewport the pipeline sized
## (RenderPipeline.set_view_size); kept for the web API's shape.
func set_size(_w: int, _h: int) -> void:
	pass

## Every vehicle, in VEHICLE_ORDER, each {key, ...spec}.
func list() -> Array:
	var out := []
	for k in CM.vehicle_order():
		var v: Dictionary = (CM.vehicle(k) as Dictionary).duplicate()
		v["key"] = k
		out.append(v)
	return out

func dispose() -> void:
	if craft != null:
		craft.group.queue_free()
	craft = null
	vehicle = null
