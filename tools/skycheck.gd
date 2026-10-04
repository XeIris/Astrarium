extends SceneTree

var checks := 0
var failures := 0

func check(label: String, valid: bool) -> void:
	checks += 1
	if not valid:
		failures += 1
		printerr("SKYCHECK FAIL ", label)

func _init() -> void:
	for id in Presets.PRESETS:
		check("authored preset " + id, SkyModel.request_error(Presets.PRESETS[id].get("sky", {})).is_empty())
	for spec in [{}, {"env": "disc"}, {"env": ["disc", "halo"]}, {"env": [["disc", 0.5], ["halo", 1.0]]},
		{"env": {"disc": 0.0, "halo": 1.0}}, {"tilt": -PI, "roll": PI}, {"env": []}]:
		check("supported schema", SkyModel.request_error(spec).is_empty())
	for spec in [null, [], "disc", {"env": "dics"}, {"environment": "disc"}, {"env": [[]]},
		{"env": [["disc"]]}, {"env": [["disc", 1, 2]]}, {"env": {"halo": INF}}, {"env": {"halo": -1}},
		{"env": {"halo": true}}, {"env": {"halo": "1"}}, {"glow": NAN}, {"glow": 1e300}, {"tilt": true}, {"roll": []}]:
		check("malformed schema rejected", not SkyModel.request_error(spec).is_empty())
	print("SKYCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(1 if failures else 0)
