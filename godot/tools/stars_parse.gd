extends SceneTree
# Headless smoke check for the star/compact-object visuals: every script
# parses, every factory builds, every update runs. `Godot --headless --path
# godot --script res://tools/stars_parse.gd`
func _init() -> void:
	for p in ["res://sim/bodies.gd", "res://sim/star_visual.gd", "res://sim/prominence.gd", "res://sim/neutron_visual.gd", "res://sim/marker.gd", "res://sim/flash.gd", "res://sim/spacetime_mesh.gd"]:
		var s = load(p)
		print(p, " -> ", s != null and s.can_instantiate())
	var b := Body.new(); b.type = "star"; b.mass = 1.0; b.radius = 0.00465
	var v = Bodies.create_body_visual(b, {"radiusScene": 1.0, "teff": 5772.0})
	print("star viz ", v, " regions ", b.activity.regions.size(), " gran ", v.mat.get_shader_parameter("uGranScale"), " gain ", v.mat.get_shader_parameter("uGain"))
	v.update(0.016, {"time": 0.0, "sim_dt": 0.001, "holes": []})
	var w := Body.new(); w.type = "white-dwarf"; w.mass = 1.0; w.radius = 4e-5
	var wv = Bodies.create_body_visual(w, {"radiusScene": 0.2, "teff": 25000.0})
	print("wd regions ", w.activity.regions.size())
	var n := Body.new(); n.type = "neutron"; n.mass = 1.4; n.radius = 8e-8; n.rs = 2.8e-8
	var nv = Bodies.create_body_visual(n, {"radiusScene": 0.1})
	nv.update(0.016, {"time": 0.0, "holes": []})
	var h := Body.new(); h.type = "bh"
	print("hole ", Bodies.create_body_visual(h, {}).is_hole)
	var p := Body.new(); p.type = "planet"; p.mass = 3e-6
	var pv = Bodies.create_body_visual(p, {"radiusScene": 0.15, "glow": 0x3a6a9a})
	print("planet r via wrap ", pv.r, " group ", pv.group)
	var m := Marker.create_marker({"color": 0xffffff, "teff": 5000.0, "gain": 26.0})
	print("marker ", m.mesh)
	var f := Flash.create(0xffd0a0, 2.0, 0.16, 12.0, "shell")
	print("flash step ", f.step(0.1), " ", f.node.scale)
	var st := SpacetimeMesh.new()
	print("mesh surfaces ", st.node.mesh.get_surface_count())
	# the dynamic Structure route: a static func called through its script
	var S = load("res://sim/stellar.gd")
	print("static via script: ", S.callv("activity_level", [1.0]), " == ", Stellar.activity_level(1.0))
	# accretion: a star 1 unit from a hole of r_s 0.1 sheds particles and mass
	var a := Body.new(); a.type = "star"; a.mass = 1.0; a.mass0 = 1.0; a.radius = 0.00465
	var av = Bodies.create_body_visual(a, {"radiusScene": 0.3, "teff": 5772.0})
	av.group.position = Vector3(1, 0, 0)
	var hctx := {"time": 0.0, "sim_dt": 0.0, "holes": [{"pos_rel": Vector3.ZERO, "rs_scene": 0.1, "mass": 10.0}]}
	for i in 60:
		av.update(1.0 / 60.0, hctx)
	print("accretion: mass ", a.mass, " points visible ", av.stream.points.visible, " surfaces ", av.stream.mesh.get_surface_count(), " group scale ", av.group.scale.x)
	quit()
