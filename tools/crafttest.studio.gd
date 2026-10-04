extends Harness

# Production model viewport and post-processing, with a stationary turntable.
#   Godot --path . res://tools/crafttest.studio.tscn -- v=falcon9 out=/abs.png \
#         frames=60 [explode=1] [deploy=0] [spin=1] [assets=0]

var mv: ModelViewer

func _setup() -> void:
	pipe.set_mode(RenderPipeline.Mode.MODEL)
	var v: String = args.get("v", "saturnv")
	if args.get("assets", "1") != "0":
		CraftAssets.craft_models_ready([v])
	mv = ModelViewer.create_model_viewer(pipe)
	mv.load_vehicle(v)
	for mesh in mv.craft.group.find_children("*", "MeshInstance3D", true, false):
		mesh.lod_bias = float(args.get("lod", "1"))
	if args.get("spin", "0") != "1":
		mv.cam.spin = 0.0
		mv.cam.held = true
	if args.has("explode"): mv.set_explode(float(args.explode))
	if args.get("deploy", "1") == "0": mv.set_deploy(false)
	print("studio: ", v, " ", JSON.stringify(mv.stats()))

func _step(d: float) -> void:
	mv.update(d)
