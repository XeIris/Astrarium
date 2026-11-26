extends Node

# GAME SAVE CHECK: saved games through the real stage (sim/save_game.gd, sim/save_store.gd,
# ui/save_browser.gd). The codec keeps ints and non-finite floats; the slots list, sort,
# rename, overwrite and delete; damaged and invalid files are listed with a reason and
# refused without touching the stage; a sandbox, a flight and a planetary exploration each
# come back bit for bit and fly on as they would have; the title's menus, the save card's
# confirmations and the exit prompt do what they say.
#   Godot --headless --path . res://tools/gamesavecheck.tscn -- settings=default

const Catch = preload("res://tools/coursecheck.gd").Catch
const JsonFile = preload("res://core/json_file.gd")
var catcher := Catch.new()
var main: Node
var checks := 0
var failures := 0
var dir := ""

func check(label: String, ok: bool, detail := "") -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s%s" % ["ok" if ok else "FAIL", label, "" if ok or detail == "" else " — " + detail])

func _ready() -> void:
	OS.add_logger(catcher)
	dir = OS.get_temp_dir().path_join("astrarium-gamesavecheck-%d" % OS.get_process_id())
	_wipe(dir)
	SaveStore.dir = dir
	PlanetMaps.synchronous = true
	main = load("res://main.tscn").instantiate()
	add_child(main)
	main.set_process(false)
	for i in 3: await get_tree().process_frame
	SaveStore.dir = dir
	codec()
	store()
	damaged_files()
	main._start("sandbox")
	main.set_drawn(false)
	await sandbox_round_trip()
	await refused_loads()
	await flight_round_trip()
	await pad_round_trip()
	await planetary_round_trip()
	await title_and_card()
	await exit_prompt()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	_wipe(dir)
	print("GAMESAVECHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)

func _wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path): return
	for sub in DirAccess.get_directories_at(path): _wipe(path.path_join(sub))
	for f in DirAccess.get_files_at(path): DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)

func frames(n: int, dt := 1.0 / 60.0) -> void:
	for i in n: main.animate(dt)

# THE CODEC

func codec() -> void:
	var v := {"seed": 123456789, "big": 9007199254740993, "neg": -7, "third": 1.0 / 3.0, "sum": 0.1 + 0.2,
		"tiny": 5e-324, "huge": 1.7976931348623157e308, "inf": INF, "ninf": -INF, "nan": NAN, "f": 2.0,
		"nest": [1, [2.5, {"k": true}], null, "x"], "packed": PackedFloat64Array([1.5, -0.0, 1e-300])}
	var enc := SaveCodec.encode(v)
	check("codec encodes plain values", enc.error == "", enc.error)
	var text := JSON.stringify(enc.value, "", true, true)
	var dec := SaveCodec.decode(JSON.parse_string(text))
	check("codec decodes what it wrote", dec.error == "", dec.error)
	var d: Dictionary = dec.value
	check("an int stays an int", typeof(d.seed) == TYPE_INT and d.seed == 123456789 and typeof(d.neg) == TYPE_INT)
	check("an int past 2^53 is exact", d.big == 9007199254740993)
	check("a float stays a float", typeof(d.f) == TYPE_FLOAT and d.f == 2.0)
	check("doubles round-trip bit for bit", d.third == 1.0 / 3.0 and d.sum == 0.1 + 0.2 and d.tiny == 5e-324 and d.huge == 1.7976931348623157e308)
	check("non-finite floats survive", d.inf == INF and d.ninf == -INF and is_nan(d.nan))
	check("nesting survives", d.nest[0] == 1 and d.nest[1][0] == 2.5 and d.nest[1][1].k == true and d.nest[2] == null)
	check("a packed array comes back as numbers", d.packed.size() == 3 and d.packed[2] == 1e-300)
	var node := Node.new()
	check("an object cannot be saved", SaveCodec.encode({"x": node}).error.contains("cannot be saved"))
	node.free()
	check("a Vector3 cannot be saved", SaveCodec.encode({"x": Vector3.ONE}).error != "")
	check("a reserved key is refused", SaveCodec.encode({"@i": 1}).error != "")
	check("a non-text key is refused", SaveCodec.encode({1: 1}).error != "")
	var odd := 0.003606201593081111
	var e2 := SaveCodec.encode({"x": odd, "z": -0.0})
	var d2: Dictionary = SaveCodec.decode(JSON.parse_string(JSON.stringify(e2.value, "", true, true))).value
	check("a double Godot's JSON would round is kept exactly", SaveCodec.bits(d2.x) == SaveCodec.bits(odd), str(e2.value))
	check("negative zero keeps its sign", SaveCodec.bits(d2.z) == SaveCodec.bits(-0.0))
	for bad in [{"@i": "4.5"}, {"@i": 4}, {"@f": "huge"}, {"@x": 1}, {"a": {"@q": 1}}, {"@d": "zz"}, {"@d": "000000000000f07f"}]:
		check("decode refuses %s" % JSON.stringify(bad), SaveCodec.decode(bad).error != "")
	var deep = 1
	for i in 80: deep = [deep]
	check("absurd nesting is refused", SaveCodec.encode(deep).error.contains("deeply") and SaveCodec.decode(deep).error.contains("deeply"))

# THE SLOTS

func _state(n: int) -> Dictionary:
	return {"world": {"n": n, "x": 0.1 * n}}

func store() -> void:
	var empty := SaveStore.list("sandbox")
	check("ten empty slots to start", empty.size() == SaveStore.SLOTS and empty.all(func(e): return e.status == "empty"))
	check("the first free slot is the first", SaveStore.first_free("sandbox") == 0)
	for name in ["", "   ", "x".repeat(SaveStore.NAME_MAX + 1), "tab\there", "be" + char(7) + "ll"]:
		check("name %s is refused" % JSON.stringify(name), SaveStore.name_error(name) != "")
		check("writing under %s is refused" % JSON.stringify(name), not SaveStore.write("sandbox", 0, name, "", {}).ok)
	check("a name of %d characters is fine" % SaveStore.NAME_MAX, SaveStore.name_error("é".repeat(SaveStore.NAME_MAX)) == "")
	check("slot 11 does not exist", not SaveStore.write("sandbox", 10, "x", "", {}).ok and not SaveStore.read("sandbox", -1).ok)
	check("an unknown kind is refused", not SaveStore.write("chess", 0, "x", "", {}).ok)
	var w := SaveStore.write("sandbox", 3, "  Beta  ", "the second", _state(2), 2000.0)
	check("a save writes", w.ok, str(w.get("error", "")))
	SaveStore.write("sandbox", 1, "alpha", "the first", _state(1), 1000.0)
	SaveStore.write("sandbox", 6, "Gamma", "the third", _state(3), 3000.0)
	var r := SaveStore.read("sandbox", 3)
	check("a save reads back", r.ok and r.save.name == "Beta" and r.save.summary == "the second" and r.save.saved == 2000.0
		and r.save.state == _state(2), str(r.get("error", "")))
	var listed := SaveStore.list("sandbox")
	check("the list shows filled slots where they are", listed[1].status == "ok" and listed[3].name == "Beta" and listed[6].saved == 3000.0
		and listed[0].status == "empty")
	var by_date: Array = SaveStore.sorted(listed, "date").map(func(e): return e.name)
	var by_name: Array = SaveStore.sorted(listed, "name").map(func(e): return e.name)
	check("sorted newest first", by_date == ["Gamma", "Beta", "alpha"], str(by_date))
	check("sorted by name, ignoring case", by_name == ["alpha", "Beta", "Gamma"], str(by_name))
	check("the first free slot skips filled ones", SaveStore.first_free("sandbox") == 0)
	check("kinds keep separate slots", SaveStore.list("spaceflight").all(func(e): return e.status == "empty")
		and SaveStore.list("planetary").all(func(e): return e.status == "empty"))
	var ren := SaveStore.rename("sandbox", 3, "Delta")
	r = SaveStore.read("sandbox", 3)
	check("a rename keeps the date and the contents", ren.ok and r.save.name == "Delta" and r.save.saved == 2000.0 and r.save.state == _state(2))
	check("renaming an empty slot fails", not SaveStore.rename("sandbox", 0, "x").ok)
	check("renaming to a bad name fails", not SaveStore.rename("sandbox", 3, "").ok and SaveStore.read("sandbox", 3).save.name == "Delta")
	SaveStore.write("sandbox", 3, "Delta", "overwritten", _state(9), 4000.0)
	r = SaveStore.read("sandbox", 3)
	check("an overwrite replaces the slot", r.save.summary == "overwritten" and r.save.state == _state(9))
	check("a delete empties the slot", SaveStore.delete("sandbox", 3) == OK and SaveStore.list("sandbox")[3].status == "empty"
		and not FileAccess.file_exists(SaveStore.path_of("sandbox", 3)))
	check("deleting an empty slot is harmless", SaveStore.delete("sandbox", 3) == OK)
	for slot in SaveStore.SLOTS: SaveStore.write("planetary", slot, "p%d" % slot, "", _state(slot), float(slot))
	check("ten filled slots leave none free", SaveStore.first_free("planetary") == -1)
	check("an eleventh cannot be made", not SaveStore.write("planetary", SaveStore.SLOTS, "p", "", {}).ok)
	SaveStore.write("planetary", 0, "p0", "", {"world": {"x": 0.1 + 0.2}}, 0.0)
	check("the store writes doubles in full", FileAccess.get_file_as_string(SaveStore.path_of("planetary", 0)).contains("0.30000000000000004"))
	var ok_state := SaveStore.write("sandbox", 9, "bad state", "", {"x": Callable()})
	check("a state that cannot be encoded is not written", not ok_state.ok and SaveStore.list("sandbox")[9].status == "empty")
	for slot in SaveStore.SLOTS: SaveStore.delete("planetary", slot)
	for slot in SaveStore.SLOTS: SaveStore.delete("sandbox", slot)

# DAMAGED AND INVALID FILES: listed with a reason, deletable, never loaded.

func _raw(kind: String, slot: int, text) -> void:
	DirAccess.make_dir_recursive_absolute(SaveStore.path_of(kind, slot).get_base_dir())
	var f := FileAccess.open(SaveStore.path_of(kind, slot), FileAccess.WRITE)
	if text is PackedByteArray: f.store_buffer(text)
	else: f.store_string(str(text))
	f.close()

func _envelope(over := {}) -> String:
	var d := {"format": 1, "kind": "sandbox", "name": "ok", "saved": 1.0, "summary": "", "state": {"world": {}}}
	d.merge(over, true)
	for k in over:
		if over[k] == null: d.erase(k)
	return JSON.stringify(d)

func damaged_files() -> void:
	var good := _envelope()
	var cases := [
		["empty file", ""],
		["truncated JSON", good.left(good.length() - 9)],
		["binary garbage", PackedByteArray([0xff, 0xfe, 0x00, 0x13, 0x88, 0x01, 0x7f])],
		["a JSON array", "[1, 2, 3]"],
		["a JSON string", "\"save\""],
		["a newer format", _envelope({"format": 2})],
		["an older format", _envelope({"format": 0})],
		["a fractional format", _envelope({"format": 1.5})],
		["another kind's save", _envelope({"kind": "spaceflight"})],
		["an unknown kind", _envelope({"kind": "chess"})],
		["an unknown field", _envelope({"extra": 1})],
		["no state", _envelope({"state": null})],
		["a state that is not a dictionary", _envelope({"state": [1]})],
		["a name that is not text", _envelope({"name": 5})],
		["an empty name", _envelope({"name": ""})],
		["a negative date", _envelope({"saved": -1})],
		["a summary that is not text", _envelope({"summary": {}})],
		["a damaged integer tag", _envelope({"state": {"world": {"n": {"@i": "seven"}}}})],
		["an unknown tag", _envelope({"state": {"world": {"@z": 1}}})],
	]
	for i in cases.size():
		_raw("sandbox", i % SaveStore.SLOTS, cases[i][1])
		var e: Dictionary = SaveStore.list("sandbox")[i % SaveStore.SLOTS]
		var r := SaveStore.read("sandbox", i % SaveStore.SLOTS)
		check("%s is listed as unreadable" % cases[i][0], e.status == "bad" and e.error != "" and not r.ok and r.error != "", e.error)
		check("%s can be deleted" % cases[i][0], SaveStore.delete("sandbox", i % SaveStore.SLOTS) == OK
			and SaveStore.list("sandbox")[i % SaveStore.SLOTS].status == "empty")
	_raw("sandbox", 0, _envelope({"name": "Kept name", "format": 9}))
	var e0: Dictionary = SaveStore.list("sandbox")[0]
	check("an unreadable save keeps the name it had", e0.status == "bad" and e0.name == "Kept name" and e0.error.contains("newer"), e0.error)
	SaveStore.delete("sandbox", 0)
	# An oversized file is not even parsed.
	var f := FileAccess.open(SaveStore.path_of("sandbox", 0), FileAccess.WRITE)
	f.seek(SaveStore.MAX_BYTES + 16)
	f.store_8(0)
	f.close()
	check("an oversized file is refused unread", SaveStore.read("sandbox", 0).error.contains("larger"))
	SaveStore.delete("sandbox", 0)
	# A stale recovery file must not lock a slot the player writes.
	_raw("sandbox", 2, good)
	var bak := FileAccess.open(SaveStore.path_of("sandbox", 2) + ".bak", FileAccess.WRITE)
	bak.store_string(good)
	bak.close()
	var w := SaveStore.write("sandbox", 2, "fresh", "", {"world": {}})
	check("a stale recovery file does not block a save", w.ok and SaveStore.read("sandbox", 2).save.name == "fresh", str(w.get("error", "")))
	SaveStore.delete("sandbox", 2)
	check("a delete takes the recovery file too", not FileAccess.file_exists(SaveStore.path_of("sandbox", 2) + ".bak"))

# THE SANDBOX

func world_digest() -> Array:
	var st: SimState = main.state
	var out := [st.preset_key, st.sim_years, st.year_remainder, st.consumed, st.time_scale, st.true_scale, st.paused, st.max_step]
	for b: Body in st.bodies:
		var row := [b.name, b.type, b.mass, b.mass0, b.pos.to_array(), b.vel.to_array(), b.spin_frac, b.spin_omega,
			b.spin_tracked, b.radius, b.spin_phase]
		if b.climate != null:
			var cl: Climate = b.climate
			row.append([cl.T, cl.ice, cl.ocean, cl.steam, cl.clouds, cl.time, cl.pending, cl.wet, Array(cl.ebm.T),
				cl.mixed_layer, cl.pressures.duplicate(), cl.history.size(), cl.extremes.duplicate()])
		out.append(row)
	return out

func cam_digest() -> Array:
	var c = main.cam
	var st: SimState = main.state
	var f := st.body_by_id(st.follow_id)
	return [st.cam_mode, c.theta, c.phi, c.radius, c.target.to_array(), c.offset.to_array(), f.name if f else null,
		st.body_by_id(st.focus_id).name if st.focus_id != null else null]

func _first_diff(a, b, at := "") -> String:
	if a is Array and b is Array:
		if a.size() != b.size(): return "%s sizes %d and %d" % [at, a.size(), b.size()]
		for i in a.size():
			var d := _first_diff(a[i], b[i], "%s[%d]" % [at, i])
			if d != "": return d
		return ""
	if a is Dictionary and b is Dictionary:
		var ka: Array = a.keys()
		var kb: Array = b.keys()
		ka.sort()
		kb.sort()
		if ka != kb: return "%s keys %s and %s" % [at, ka, kb]
		for k in a:
			var d := _first_diff(a[k], b[k], "%s.%s" % [at, k])
			if d != "": return d
		return ""
	if typeof(a) != typeof(b): return "%s types %s and %s (%s vs %s)" % [at, type_string(typeof(a)), type_string(typeof(b)), a, b]
	if a is float and (a == b or (is_nan(a) and is_nan(b))): return ""
	if a is float: return "%s %s vs %s (differ by %s)" % [at, String.num_scientific(a), String.num_scientific(b), String.num_scientific(b - a)]
	return "" if a == b else "%s %s vs %s" % [at, str(a).left(200), str(b).left(200)]

func _save(kind: String, slot: int, name: String) -> Dictionary:
	var cap := SaveGame.capture(main, kind)
	if not cap.ok: return cap
	var w := SaveStore.write(kind, slot, name, cap.summary, cap.state)
	cap.ok = w.ok
	cap.error = w.get("error", "")
	return cap

## Stellar flares are drawn from Godot's unseeded global RNG (Stellar.ActivityModel), so no
## two runs play them alike, saved or not; quieted, the play-on compares the save itself.
func _quiet_stars() -> void:
	for b: Body in main.state.bodies:
		if b.activity == null: continue
		b.activity.next = INF
		b.activity.flares.clear()
		b.activity.flux = 1.0
		b.activity.bolometric = 1.0

func sandbox_round_trip() -> void:
	main.load_preset("solar")
	frames(30)
	# A scene that has been played with: a spawned world, an edit, a ring, a focus, a pace.
	var b: Body = main.spawn_body(main.place_spawn({"type": "planet", "name": "Saved World", "seed": 4242}))
	main.edit_body(main.state.body_named("Mars"), {"mass": main.state.body_named("Mars").mass * 1.5})
	main.set_follow(main.state.body_named("Saturn"))
	main.paint_ring_on(main.state.body_named("Saturn"))
	main.set_time_scale(0.75)
	_quiet_stars()
	frames(90)
	check("the spawned world has a climate", b != null and b.climate != null)
	check("a sandbox in play can be saved", SaveGame.why_not(main, SaveGame.kind_now(main)) == "" and SaveGame.kind_now(main) == "sandbox")
	var cap := _save("sandbox", 0, "Solar, edited")
	check("the sandbox saves", cap.ok, str(cap.error))
	var digest := world_digest()
	var cam := cam_digest()
	var paint: int = main.painter.items.size()
	check("the summary says what is in it", str(cap.summary).begins_with("Solar System") and str(cap.summary).contains("star")
		and str(cap.summary).contains("gas giant"), str(cap.summary))
	frames(240)
	var played_on := world_digest()
	# Somewhere else entirely, then back.
	main.load_preset("binarystar")
	frames(10)
	var r := SaveStore.read("sandbox", 0)
	check("the save reads", r.ok, str(r.error))
	var err: String = await main.restore_save("sandbox", r.save.state)
	check("the sandbox loads", err == "", err)
	var back := world_digest()
	check("every body, the clock and the climates come back bit for bit", _first_diff(digest, back) == "", _first_diff(digest, back))
	check("the camera comes back", _first_diff(cam, cam_digest()) == "", _first_diff(cam, cam_digest()))
	check("the ring comes back", main.painter.items.size() == paint and paint > 0)
	check("the spawned world's climate draw is its own", main.state.body_named("Saved World").climate.drawn == b.climate.drawn if b != null else false)
	check("the mode is the sandbox", main.state.app_mode == "sandbox" and not main.at_start)
	_quiet_stars()
	frames(240)
	var again := world_digest()
	check("a loaded sandbox plays on exactly as the original did", _first_diff(played_on, again) == "", _first_diff(played_on, again))
	# A spec the stage would refuse is refused at capture, so nothing unloadable is written.
	var star: Body = main.state.bodies.filter(func(x): return x.type == "star")[0]
	star.spec.radiusSun = -1.0
	var refused := SaveGame.capture(main, "sandbox")
	check("a scene that would not load back is not saved", not refused.ok and str(refused.error).contains("cannot be saved"), str(refused.get("error", "")))
	star.spec.erase("radiusSun")

static func _climate_of(s: Dictionary, drawn := false) -> Dictionary:
	for e in s.world.bodies:
		if e.climate != null and (not drawn or e.climate.has("drawn")): return e.climate
	return {}

## Every invalid state is refused before the stage changes.
func refused_loads() -> void:
	main.load_preset("solar")
	frames(5)
	var good: Dictionary = SaveGame.capture(main, "sandbox").state
	var before := world_digest()
	var edits := {
		"no world": func(s): s.erase("world"),
		"an extra section": func(s): s.flight = {},
		"bodies not a list": func(s): s.world.bodies = {},
		"a negative mass": func(s): s.world.bodies[1].spec.mass = -1.0,
		"an unknown type": func(s): s.world.bodies[1].spec.type = "comet",
		"a position with NaN": func(s): s.world.bodies[2].spec.pos[1] = NAN,
		"a velocity of two numbers": func(s): s.world.bodies[2].spec.vel = [0.0, 1.0],
		"a mass in words": func(s): s.world.bodies[2].spec.mass = "heavy",
		"a spin past break-up": func(s): s.world.bodies[3].spec.spinFrac = 1.5,
		"a follow index out of range": func(s): s.world.camera.follow = 99999,
		"a camera at no distance": func(s): s.world.camera.radius = 0.0,
		"a bad sky": func(s): s.world.sky.tilt = "tilted",
		"an unknown sky field": func(s): s.world.sky.colour = 1.0,
		"an unknown scene field": func(s): s.world.scene.build = 1,
		"a scene flag that is not true or false": func(s): s.world.scene.surface = "yes",
		"a scene name that is not text": func(s): s.world.scene.name = 3,
		"a paint label that is not text": func(s): s.world.paint = [{"spec": {"kind": "cloud", "label": 7}, "t": 0.0}],
		"a zero scene scale": func(s): s.world.scene.sceneScale = 0.0,
		"a negative time scale": func(s): s.world.live.timeScale = -1.0,
		"a time that is not a number": func(s): s.world.live.simYears = "soon",
		"a paint kind that does not exist": func(s): s.world.paint = [{"spec": {"kind": "nebula"}, "t": 0.0}],
		"a paint on a missing body": func(s): s.world.paint = [{"spec": {"kind": "ring", "body": "Vulcan"}, "t": 0.0}],
		"a damaged climate": func(s): _climate_of(s).T = "warm",
		"a climate history row of two": func(s): _climate_of(s).history = [[1.0, 2.0]],
		"drawn climate inputs that are not a dictionary": func(s): _climate_of(s, true).drawn = 3,
	}
	for label in edits:
		var s: Dictionary = good.duplicate(true)
		edits[label].call(s)
		var why := SaveGame.validate("sandbox", s)
		var err: String = await main.restore_save("sandbox", s)
		check("%s is refused" % label, why != "" and err == why, why)
		check("%s leaves the stage as it was" % label, _first_diff(before, world_digest()) == "")
	# Through the store and the stage's own entry point: an envelope that reads, a state that does not.
	var s2: Dictionary = good.duplicate(true)
	s2.world.bodies[0].spec.mass = -5.0
	SaveStore.write("sandbox", 5, "Poisoned", "", s2)
	main.saves_ui.open("sandbox", "load", {}, true)
	await main.load_game("sandbox", 5)
	check("load_game refuses an invalid state and says why", main.saves_ui.visible and main.saves_ui._error.contains("Could not load"), main.saves_ui._error)
	check("an invalid state leaves the stage as it was", _first_diff(before, world_digest()) == "")
	check("a sandbox state is not a flight", SaveGame.validate("spaceflight", good) != "")
	main.saves_ui.close()
	SaveStore.delete("sandbox", 5)

# A FLIGHT

func vessel_digest() -> Array:
	var f = main.flight
	var v: Vessel = f.vessel
	var out := [v.vehicle_key, v.parent.name, v.phase, v.r.to_array(), v.v.to_array(), [v.q.x, v.q.y, v.q.z, v.q.w],
		v.omega.to_array(), v.met, v.coord, v.t0, v.throttle, v.stage_index, v.mass]
	for st in v.stages: out.append([st.spec.key, st.attached, st.prop, st.rcs_prop, st.ignited, st.spent, st.live])
	return out

func _close(a: Array, b: Array, tol_m: float) -> String:
	var ra := DVec3.from_array(a[3])
	var rb := DVec3.from_array(b[3])
	var dv := DVec3.from_array(a[4]).distance_to(DVec3.from_array(b[4]))
	if ra.distance_to(rb) > tol_m: return "position %s m apart" % U.prec(ra.distance_to(rb), 3)
	if dv > tol_m * 1e-2: return "velocity %s m/s apart" % U.prec(dv, 3)
	if absf(float(a[7]) - float(b[7])) > 1e-6: return "MET %s vs %s" % [a[7], b[7]]
	for i in range(13, a.size()):
		if a[i][1] != b[i][1] or absf(float(a[i][2]) - float(b[i][2])) > 1e-3 * maxf(1.0, float(a[i][2])):
			return "stage %s: %s vs %s" % [a[i][0], str(a[i]), str(b[i])]
	return ""

func flight_round_trip() -> void:
	main.end_flight()
	main.scenario_world("solar")
	CraftAssets.craft_models_ready(["falcon9"])
	var sc = FlightScenarios.find("falcon9", "orbit")
	var err := FlightScenarios.build(main, sc)
	check("a Falcon 9 in orbit is built", err == "", err)
	main.state.app_mode = "flight"
	main.set_cam_mode("flight")
	var f = main.flight
	for i in 60: main.step_flight(1.0 / 60.0)
	# Mid-burn: the second stage lit, so the save holds a vessel under power.
	f.vessel.throttle = 0.4
	for i in 30: main.step_flight(1.0 / 60.0)
	check("a flight is saved as a spaceflight", SaveGame.kind_now(main) == "spaceflight" and SaveGame.why_not(main, "spaceflight") == "")
	var cap := _save("spaceflight", 0, "Falcon burn")
	check("the flight saves", cap.ok, str(cap.error))
	check("its summary names the vehicle and where it is", str(cap.summary).begins_with("Falcon 9") and str(cap.summary).contains("Earth"), str(cap.summary))
	var at_save := vessel_digest()
	var world := world_digest()
	check("a dropped stage is in the save", at_save.slice(13).any(func(s): return s[1] == false))
	for i in 300: main.step_flight(1.0 / 60.0)
	var flown := vessel_digest()
	var r := SaveStore.read("spaceflight", 0)
	err = await main.restore_save("spaceflight", r.save.state)
	check("the flight loads", err == "", err)
	check("the vessel comes back bit for bit", _first_diff(at_save, vessel_digest()) == "", _first_diff(at_save, vessel_digest()))
	check("its world comes back bit for bit", _first_diff(world, world_digest()) == "", _first_diff(world, world_digest()))
	check("the mode is spaceflight, the camera on the vessel", main.state.app_mode == "flight" and main.state.cam_mode == "flight" and f.active)
	var cs = f.craft.stage(str(f.vessel.stages[0].spec.key)) if f.craft != null else null
	check("a stage dropped before the save is not drawn", cs != null and not cs.group.visible and cs.sep == null)
	for i in 300: main.step_flight(1.0 / 60.0)
	# Attitude control's rate memory starts afresh, so a burn may differ by centimetres.
	var drift := _close(flown, vessel_digest(), 0.5)
	check("a loaded flight flies on as the original did (0.5 m after 5 s under power)", drift == "", drift)
	# What cannot be saved yet says so, and the exit prompt does not offer it.
	f.skip = {"until": 0.0}
	check("a skip in progress cannot be saved", SaveGame.why_not(main, "spaceflight").contains("skip"))
	f.skip = null
	var tower = f.vessel.catch_tower
	f.vessel.catch_tower = {}
	check("a booster coming home to its tower cannot be saved", SaveGame.why_not(main, "spaceflight").contains("tower"))
	f.vessel.catch_tower = tower
	var bad: Dictionary = r.save.state.duplicate(true)
	bad.flight.vehicle = "zeppelin"
	check("an unknown vehicle is refused", SaveGame.validate("spaceflight", bad).contains("zeppelin"))
	bad = r.save.state.duplicate(true)
	bad.flight.stages[1].prop = -10.0
	check("negative propellant is refused", SaveGame.validate("spaceflight", bad) != "")
	bad = r.save.state.duplicate(true)
	bad.flight.q = [0.0, 0.0, 0.0, 2.0]
	check("an attitude that is not a rotation is refused", SaveGame.validate("spaceflight", bad) != "")
	bad = r.save.state.duplicate(true)
	bad.flight.phase = "cruise"
	check("a phase that cannot be restored is refused", SaveGame.validate("spaceflight", bad) != "")
	bad = r.save.state.duplicate(true)
	bad.flight.stageKeys = ["f9s2", "nonsense"]
	check("stages the vehicle does not have are refused", SaveGame.validate("spaceflight", bad) != "")
	bad = r.save.state.duplicate(true)
	bad.flight.parent = 999
	check("a parent that is not saved is refused", SaveGame.validate("spaceflight", bad) != "")

func pad_round_trip() -> void:
	main.end_flight()
	main.scenario_world("solar")
	CraftAssets.craft_models_ready(["saturnv"])
	var v = main.flight.begin("saturnv", {"mode": "pad"})
	check("a Saturn V on the pad", v != null and v.phase == "prelaunch")
	main.state.app_mode = "flight"
	var cap := _save("spaceflight", 1, "On the pad")
	check("a vehicle on the pad saves", cap.ok and str(cap.summary).contains("on the pad"), str(cap.get("summary", cap.get("error", ""))))
	main.end_flight()
	main.load_preset("blank")
	var err: String = await main.restore_save("spaceflight", SaveStore.read("spaceflight", 1).save.state)
	var f = main.flight
	check("it loads standing on the pad", err == "" and f.active and f.vessel.vehicle_key == "saturnv" and f.vessel.phase == "prelaunch"
		and f.site != null, err)
	main.end_flight()

# A PLANETARY EXPLORATION

func planetary_round_trip() -> void:
	main.quit_to_start()
	main._start("explore")
	check("Planetary exploration opens on the world picker", main.explore_map.visible and main.state.app_mode == "explore")
	var worlds: Array = main.explore_map.worlds().map(func(b): return b.name)
	check("the picker lists the worlds with ground", worlds.has("Mars") and worlds.has("Earth") and not worlds.has("Jupiter") and not worlds.has("Sun"), str(worlds))
	check("nothing is saved from the picker alone", SaveGame.kind_now(main) == "planetary" and SaveGame.why_not(main, "planetary") != "")
	var mars: Body = main.state.body_named("Mars")
	var jupiter: Body = main.state.body_named("Jupiter")
	main.explore_map.open_menu(jupiter, Vector2(10, 10))
	var menu: PopupMenu = main.explore_map._menu
	check("a gas giant's Explore is offered but disabled", menu.get_item_count() > 0 and menu.is_item_disabled(menu.get_item_index(ExploreMap.MENU_EXPLORE)))
	menu.hide()
	main.explore_map.open_menu(mars, Vector2(10, 10))
	check("a rocky world's Explore is enabled", not menu.is_item_disabled(menu.get_item_index(ExploreMap.MENU_EXPLORE)))
	menu.hide()
	main.explore_map._on_menu(ExploreMap.MENU_EXPLORE)
	var sc: Showcase = main.showcase
	check("Explore puts the world in full focus", sc.active and sc.body == mars and not main.explore_map.visible and sc.came_from == "explore")
	sc.drop_pin()
	sc.drop_pin()
	frames(20)
	check("an explored world can be saved", SaveGame.why_not(main, "planetary") == "")
	var cap := _save("planetary", 0, "Mars from orbit")
	check("the exploration saves", cap.ok and str(cap.summary).begins_with("Mars · pin 2"), str(cap.get("summary", cap.get("error", ""))))
	var pin := [sc.pin.n, sc.pin.lat, sc.pin.lon]
	sc.stand()
	frames(5)
	var stood := _save("planetary", 1, "On Mars")
	check("standing on the surface saves", stood.ok and str(stood.summary).contains("on the surface"), str(stood.get("error", "")))
	main._on_showcase_action("back")
	main._on_showcase_action("leave")
	check("leaving the world goes back to the picker", main.explore_map.visible and not sc.active)
	var err: String = await main.restore_save("planetary", SaveStore.read("planetary", 0).save.state)
	check("the exploration loads", err == "" and sc.active and sc.body.name == "Mars" and sc.visit == null, err)
	check("its pin is the same pin", sc.pin != null and [sc.pin.n, sc.pin.lat, sc.pin.lon] == pin)
	err = await main.restore_save("planetary", SaveStore.read("planetary", 1).save.state)
	frames(5)
	check("a save made on the surface loads on the surface", err == "" and sc.visit != null and sc.body.name == "Mars", err)
	main._on_showcase_action("back")
	main._on_showcase_action("leave")
	check("and leaving it goes back to the picker", main.explore_map.visible)
	var bad: Dictionary = SaveStore.read("planetary", 0).save.state.duplicate(true)
	bad.explore.body = 0
	check("exploring a star is refused", SaveGame.validate("planetary", bad).contains("no surface"))
	main.quit_to_start()

# THE TITLE, THE CARD AND THE EXIT PROMPT

func _find(root: Node, sel: String) -> HudButton:
	for c in root.get_children():
		if c is HudButton and c.get_meta("sel", "") == sel: return c
		var deeper := _find(c, sel)
		if deeper != null: return deeper
	return null

func press(sel: String) -> bool:
	var b := _find(main.saves_ui, sel)
	if b == null:
		check("button %s exists" % sel, false)
		return false
	b.pressed.emit()
	return true

func title_and_card() -> void:
	var hud = main.hud
	check("the title starts at the top menu", main.at_start and hud.title_menu == "root")
	var labels: Array = hud._start_inner.get_children().map(func(i): return i.text)
	check("the title offers Sandbox, Explore, Learn, Observatory and Settings", labels == ["Sandbox", "Explore", "Learn", "Observatory", "Settings"], str(labels))
	hud.title_chosen("explore")
	labels = hud._start_inner.get_children().map(func(i): return i.text)
	check("Explore holds Spaceflight and Planetary exploration", labels == ["Spaceflight", "Planetary exploration", "Back"], str(labels))
	hud.title_chosen("flight")
	labels = hud._start_inner.get_children().map(func(i): return i.text)
	check("Spaceflight offers New game and Load game", labels == ["New game", "Load game", "Back"] and hud.title_menu == "flight")
	check("the menu's items are registered once", hud.sels.get("[data-start=flight:load]", []).size() == 1 and not hud.sels.has("[data-start=sandbox]"))
	hud.title_chosen("back")
	hud.title_chosen("back")
	check("Back climbs to the top", hud.title_menu == "root")
	hud.title_chosen("sandbox")
	hud.title_chosen("sandbox:load")
	var ui: SaveBrowser = main.saves_ui
	check("Load game lists the sandbox's saves", ui.visible and ui.kind == "sandbox" and ui.mode == "load" and not ui.live_scene)
	check("the solar save is listed with a Load button", _find(ui, "saveLoad0") != null)
	ui.close()
	hud.show_title_menu("root")
	main._start("sandbox")
	main.load_preset("solar")
	# Save into an empty slot through the card.
	main._on_saves_action("save", "")
	check("Save game opens the sandbox's slots", ui.visible and ui.mode == "save" and ui.kind == "sandbox")
	press("saveHere2")
	check("an empty slot asks for a name, filled in", ui.view == "name" and ui._field != null and ui._field.text == "Solar System")
	ui._field.text = ""
	press("saveNameOk")
	check("an empty name is not taken", ui.view == "name" and SaveStore.list("sandbox")[2].status == "empty")
	ui._field.text = "Card save"
	press("saveNameOk")
	check("the card saves into the slot", not ui.visible and SaveStore.read("sandbox", 2).ok and SaveStore.read("sandbox", 2).save.name == "Card save")
	# Overwrite asks first, and Cancel leaves the slot alone.
	var saved_at: float = SaveStore.read("sandbox", 2).save.saved
	main._on_saves_action("save", "")
	press("saveOverwrite2")
	check("overwriting asks first", ui.view == "confirm")
	press("saveConfirmCancel")
	check("cancel goes back to the list", ui.view == "list" and SaveStore.read("sandbox", 2).save.saved == saved_at)
	press("saveOverwrite2")
	press("saveConfirmOk")
	check("then the name, kept", ui.view == "name" and ui._field.text == "Card save")
	ui._field.text = "Card save 2"
	press("saveNameOk")
	check("the overwrite is written", SaveStore.read("sandbox", 2).save.name == "Card save 2")
	# Rename and delete ask first too.
	main._on_saves_action("load", "sandbox")
	check("loading in play asks before replacing the scene", ui.live_scene)
	press("saveRename2")
	ui._field.text = "Renamed"
	press("saveNameOk")
	check("a rename asks first", ui.view == "confirm" and SaveStore.read("sandbox", 2).save.name == "Card save 2")
	press("saveConfirmOk")
	check("and then renames", ui.view == "list" and SaveStore.read("sandbox", 2).save.name == "Renamed")
	press("saveDelete2")
	check("a delete asks first", ui.view == "confirm" and SaveStore.read("sandbox", 2).ok)
	press("saveConfirmCancel")
	check("cancelling a delete keeps the save", SaveStore.read("sandbox", 2).ok)
	press("saveDelete2")
	press("saveConfirmOk")
	check("a confirmed delete empties the slot", SaveStore.list("sandbox")[2].status == "empty" and ui.view == "list")
	# Load from the card, over a scene in play.
	press("saveLoad0")
	check("loading over a scene asks first", ui.view == "confirm")
	press("saveConfirmOk")
	await get_tree().process_frame
	check("then loads the save", not ui.visible and main.state.body_named("Saved World") != null)
	# An unreadable slot in the list can only be deleted.
	_raw("sandbox", 7, "{ not json")
	main._on_saves_action("load", "sandbox")
	check("an unreadable save is listed with Delete and no Load", _find(ui, "saveDelete7") != null and _find(ui, "saveLoad7") == null)
	ui.close()
	SaveStore.delete("sandbox", 7)
	# Settings › Saves follows the game.
	main._sync_saves_page()
	check("Settings › Saves can save a sandbox", not main.hud.get_el("savesSave").disabled)
	main.quit_to_start()
	main._sync_saves_page()
	check("at the title there is nothing to save", main.hud.get_el("savesSave").disabled)

func exit_prompt() -> void:
	var ui: SaveBrowser = main.saves_ui
	main._start("sandbox")
	main.load_preset("solar")
	main.request_quit_to_start()
	check("quitting a sandbox asks whether to save", ui.visible and ui.view == "prompt" and not main.at_start)
	press("savePrompt2")
	check("Cancel stays in the game", not ui.visible and not main.at_start)
	main.request_quit_to_start()
	press("savePrompt1")
	check("Leave without saving leaves", main.at_start and not ui.visible)
	main._start("sandbox")
	main.load_preset("solar")
	main.request_quit_to_start()
	press("savePrompt0")
	check("Save first opens the slots", ui.visible and ui.mode == "save")
	ui.close()
	check("closing the slots does not leave", not main.at_start)
	main.request_quit_to_start()
	press("savePrompt0")
	press("saveHere4")
	ui._field.text = "Before leaving"
	press("saveNameOk")
	check("saving from the prompt saves, then leaves", main.at_start and SaveStore.read("sandbox", 4).ok)
	main.request_quit_to_start()
	check("at the title nothing asks", not ui.visible)
	main._start("observatory", true)
	main.request_quit_to_start()
	check("the Observatory has nothing to save and does not ask", main.at_start and not ui.visible)
	main._start("learn")
	main.load_preset("solar")
	main.set_app_mode("showcase", {"body": "Earth"})
	check("a showcase opened from a lesson is not a sandbox save", main.showcase.active and SaveGame.kind_now(main) == "")
	main.quit_to_start()
