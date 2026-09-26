extends Harness

# ===========================================================================
# THE MODEL VIEWER ON THE REAL PIPELINE — sim/flight/modelviewer.gd drawn into
# pipe.model_vp and through render/postfx.gd, exactly as the orchestrator will
# draw it, for comparison with the web app's studio (blackhole_sim.html, the
# model viewer open, turntable off).
#
#   Godot --path . res://tools/crafttest.studio.tscn -- v=falcon9 out=/abs.png \
#         frames=60 [explode=1] [deploy=0] [spin=1] [assets=0]
#
# The turntable is OFF by default (the web shot clicks #mvSpin), so the frame
# does not depend on how long anything took to load.
# ===========================================================================

var mv: ModelViewer

func _setup() -> void:
	pipe.set_mode(RenderPipeline.Mode.MODEL)
	var v: String = args.get("v", "saturnv")
	if args.get("assets", "1") != "0":
		CraftAssets.craft_models_ready([v])
	mv = ModelViewer.create_model_viewer(pipe)
	mv.load(v)
	if args.get("spin", "0") != "1":
		mv.cam.spin = 0.0
		mv.cam.held = true
	if args.has("explode"): mv.set_explode(float(args.explode))
	if args.get("deploy", "1") == "0": mv.set_deploy(false)
	print("studio: ", v, " ", JSON.stringify(mv.stats()))

func _step(d: float) -> void:
	mv.update(d)
