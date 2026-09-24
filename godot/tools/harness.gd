class_name Harness
extends Node

# ============================================================================
# A REUSABLE RENDER HARNESS — the Godot counterpart of the web build's
# throwaway test pages (.claude/skytest.html, crafttest.html). Extend it, put
# your module's objects under `pipe.world_root` in _setup(), and run:
#
#   Godot --path godot res://tools/<yours>.tscn -- out=/abs/path.png \
#         frames=30 dt=0.016667 band=3 w=1280 h=720 cam=r,theta,phi hud=0
#
# Everything runs at a FIXED step (dt) for `frames` frames, then the composited
# frame (3D only — no HUD) is written to `out` and the process quits. Without
# `out` it just runs interactively, with a mouse-orbit camera.
#
# The camera is the orrery's orbit camera: a target (DVec3, scene units), a
# radius and two angles. It sits at the ORIGIN of the render world (floating
# origin) — objects must be placed with place(node, abs_scene_pos) or with
# `cam_pos` subtracted by hand. See PORT_GUIDE.md.
# ============================================================================

var pipe: RenderPipeline
var args := {}
var frame := 0
var dt := 1.0 / 60.0
var frames := 30
var t := 0.0
var cam_target := DVec3.new()
var cam_radius := 24.0
var cam_theta := PI / 2.0 - 0.35
var cam_phi := PI / 2.0
var cam_pos := DVec3.new()        # absolute scene-space camera position (the floating origin)
var lens_params = null            # set to a Dictionary to run the lens marcher
var _placed: Array = []           # [node, DVec3 abs position]
var _dragging := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	dt = float(args.get("dt", str(dt)))
	frames = int(args.get("frames", str(frames)))
	var scale := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	get_window().content_scale_factor = scale
	pipe = RenderPipeline.new()
	add_child(pipe)
	var layer := CanvasLayer.new()
	layer.layer = -1
	add_child(layer)
	layer.add_child(pipe.display)
	var w := int(args.get("w", "1280")); var h := int(args.get("h", "720"))
	pipe.set_view_size(Vector2i(w, h))
	if args.has("band"):
		pipe.set_band(int(args.band))
	if args.has("cam"):
		var c: PackedStringArray = str(args.cam).split(",")
		cam_radius = float(c[0])
		if c.size() > 1: cam_theta = float(c[1])
		if c.size() > 2: cam_phi = float(c[2])
	_setup()

## Override: build what you are testing.
func _setup() -> void:
	pass

## Override: per-frame update of what you are testing (called after the camera
## and placements are final for this frame).
func _step(_dt: float) -> void:
	pass

## Keep `node` at absolute scene position `p` (DVec3) under the floating origin.
func place(node: Node3D, p: DVec3) -> void:
	_placed.append([node, p])

func update_camera() -> void:
	cam_pos.set_v(
		cam_target.x + cam_radius * sin(cam_theta) * cos(cam_phi),
		cam_target.y + cam_radius * cos(cam_theta),
		cam_target.z + cam_radius * sin(cam_theta) * sin(cam_phi))
	var look := cam_target.rel_v3(cam_pos)
	var basis := Basis.looking_at(look, Vector3.UP) if look.length() > 0.0 else Basis()
	pipe.scene_cam.transform = Transform3D(basis, Vector3.ZERO)

func _process(real_dt: float) -> void:
	var step := dt if args.has("out") else minf(real_dt, 0.05)
	frame += 1
	t += step
	update_camera()
	for pn in _placed:
		(pn[0] as Node3D).position = (pn[1] as DVec3).rel_v3(cam_pos)
	_step(step)
	if lens_params != null:
		lens_params.basis = pipe.scene_cam.global_transform.basis
		lens_params.aspect = float(pipe.render_size.x) / float(pipe.render_size.y)
	pipe.prepare_frame(lens_params, t)
	if args.has("out") and frame == frames:
		pipe.capture_next(func(img: Image):
			img.save_png(str(args.out))
			print("harness: saved ", args.out)
			get_tree().quit())

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		if e.button_index == MOUSE_BUTTON_LEFT:
			_dragging = e.pressed
		elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_radius *= 0.9
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_radius *= 1.1
	elif e is InputEventMouseMotion and _dragging:
		cam_phi -= e.relative.x * 0.005
		cam_theta = clampf(cam_theta - e.relative.y * 0.005, 0.05, PI - 0.05)
