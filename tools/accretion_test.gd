extends Harness
# Accretion stream + legacy star + spacetime slab + marker, in one frame, with
# a (lens-less) hole at the origin pulling on a star 1.2 units out. No web
# counterpart: no preset uses 'star-basic', and a stripping star needs the
# lens to look like anything on the web side. This checks the GPU point pool
# (POINT_SIZE, CUSTOM0 alpha), the legacy star's sprites and the mesh wells.
#   Godot --path . res://tools/accretion_test.tscn -- out=/abs.png frames=90
var star: Body
var legacy: Body
var hole: Body
var slab: SpacetimeMesh
var bodies: Array = []

func _setup() -> void:
	cam_target = DVec3.new(0.6, 0.0, 0.0)
	cam_radius = 4.0
	hole = Body.new(); hole.type = "bh"; hole.mass = 10.0; hole.rs_scene = 0.1; hole.id = 1
	star = Body.new(); star.type = "star"; star.id = 2; star.mass = 1.0; star.mass0 = 1.0; star.radius = 0.00465
	star.scene_pos = DVec3.new(1.2, 0.0, 0.0)
	legacy = Body.new(); legacy.type = "star-basic"; legacy.id = 3; legacy.mass = 1.0; legacy.mass0 = 1.0
	legacy.scene_pos = DVec3.new(-0.9, 0.4, -0.6)
	for b in [hole, star, legacy]:
		var v = Bodies.create_body_visual(b, {"radiusScene": 0.25, "teff": 5772.0, "glow": 0xff8040})
		v.group.set_meta("base_scale", 1.0)
		pipe.world_root.add_child(v.group)
		place(v.group, b.scene_pos)
		b.radius_scene = 0.25
		bodies.append(b)
	slab = SpacetimeMesh.new()
	pipe.world_root.add_child(slab.node)

func _step(dt: float) -> void:
	var ctx := {"time": t, "sim_dt": 0.0, "camera": pipe.scene_cam, "cam_pos": cam_pos,
		"holes": [{"pos_rel": hole.scene_pos.rel_v3(cam_pos), "rs_scene": 0.1, "mass": 10.0}]}
	for b in bodies:
		b.viz.update(dt, ctx)
	slab.update(bodies, cam_target.x, cam_target.z, dt, cam_pos)
	if frame == frames:
		print("accretion: star mass ", star.mass, " live stream ", star.viz.stream.points.visible)
