extends Node

# Render measured-star remnants through the real stage.
# Godot --path . res://tools/transitioncheck.tscn -- mode=sandbox
const CourseCheck = preload("res://tools/coursecheck.gd")
var catcher := CourseCheck.Catch.new()
var failures := 0
var checks := 0
var stage: Node

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func render_frames() -> void:
	for i in 3:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame

func _ready() -> void:
	OS.add_logger(catcher)
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	await get_tree().process_frame
	await get_tree().process_frame
	stage._start("sandbox")
	stage.state.paused = true
	stage.set_process(false)
	for case in [[1.0, "white-dwarf"], [10.0, "neutron"], [30.0, "bh"]]:
		stage.clear_bodies()
		var b: Body = stage.spawn_body({"type": "star", "mass": case[0], "radiusSun": 120.0,
			"luminosity": 900.0, "teff": 4500.0, "contactAU": 0.3, "name": "Measured progenitor"})
		await render_frames()
		stage.core_collapse(b)
		await render_frames()
		check("%s remnant type" % case[1], b.type == case[1])
		check("%s discards progenitor radius/contact" % case[1], not b.spec.has("radiusSun") and not b.spec.has("radiusKm") and not b.spec.has("contactAU"))
		if b.type == "bh":
			check("BH contact is new horizon", b.contact_au == Physics.schwarzschild(b.mass) and b.radius == 0.0)
			check("BH discards photosphere", b.teff == null and b.luminosity == null and b.radius_sun == null)
		else:
			check("%s physical radius follows remnant" % case[1], b.radius == b.structure.radiusAU and b.radius < 0.001 and b.contact_au == b.radius)
			if b.type == "white-dwarf":
				check("WD retains intended remnant temperature", b.teff == 30000.0 and b.spec.teff == 30000.0)
				check("WD recomputes luminosity", b.luminosity == b.structure.luminosity and b.luminosity < 1.0 and not b.spec.has("luminosity"))
			else:
				check("neutron discards stellar photosphere", b.teff == null and b.luminosity == null)
	var errors := catcher.take()
	for error in errors: print("TRANSITIONCHECK ENGINE ", error)
	check("rendered remnant transitions have no engine errors", errors.is_empty())
	print("TRANSITIONCHECK DONE checks=%s failures=%s" % [checks, failures])
	OS.remove_logger(catcher)
	get_tree().quit(1 if failures else 0)
