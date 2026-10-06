extends Harness
# Render cosmetic gas streams and spacetime wells.
#   Godot --path . res://tools/accretion_test.tscn -- out=/abs.png frames=90
var star: Body
var hole: Body
var slab: SpacetimeMesh
var bodies: Array = []

func _setup() -> void:
	cam_target = DVec3.new(0.6, 0.0, 0.0)
	cam_radius = 4.0
	hole = Body.new(); hole.type = "bh"; hole.mass = 10.0; hole.rs_scene = 0.1; hole.id = 1
	star = Derive.new_body(2, {"type": "star", "mass": 1.0, "teff": 5772.0})
	star.scene_pos = DVec3.new(1.2, 0.0, 0.0)
	for b in [hole, star]:
		var v = Bodies.create_body_visual(b, VisualOpts.from_dict({"radiusScene": 0.25, "teff": 5772.0, "glow": 0xff8040}))
		pipe.world_root.add_child(v.group)
		place(v.group, b.scene_pos)
		b.radius_scene = 0.25
		bodies.append(b)
	slab = SpacetimeMesh.new()
	pipe.world_root.add_child(slab.node)

func _step(dt: float) -> void:
	var ctx := VisualCtx.new()
	ctx.time = t; ctx.camera = pipe.scene_cam; ctx.cam_pos = cam_pos
	ctx.holes = [VisualCtx.Hole.of(hole, hole.scene_pos.rel_v3(cam_pos))]
	for b in bodies:
		b.viz.update(dt, ctx)
	slab.update(bodies, cam_target.x, cam_target.z, dt, cam_pos)
	if frame == frames:
		print("accretion: star mass ", star.mass, " live stream ", star.viz.stream.points.visible)

func _exit_tree() -> void:
	# Break the body/visual ownership cycle before renderer shutdown.
	for b: Body in bodies: b.viz = null
	bodies.clear()
	star = null; hole = null; slab = null
	super._exit_tree()
