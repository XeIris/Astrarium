extends Node

# Scenario files (docs/scenario-format.md): every built-in file against the fixture of the
# builds it replaced, bit for bit; every refusal and warning; the derived defaults; and
# upload, Load anyway, the load deadline, the slow-frame pause, remove and standing on an
# uploaded world, through the stage. `snapshot=1` rewrites the fixture from the current
# scenarios after an intended change.
const FIXTURE := "res://tools/fixtures/scenario_states.json"
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var checks := 0
var failures := []
var stage: Node
var tmp := ""

func check(what: String, ok: bool) -> void:
	checks += 1
	if not ok: failures.append(what)

func _ready() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.get("snapshot") == "1":
		get_tree().quit(snapshot())
		return
	OS.add_logger(catcher)
	tmp = OS.get_temp_dir().path_join("astrarium-scenariofilecheck-%d" % OS.get_process_id())
	DirAccess.make_dir_recursive_absolute(tmp)
	decimals()
	compare_builtins()
	refusals()
	warnings()
	defaults()
	await through_the_stage()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	for name in DirAccess.get_files_at(tmp): DirAccess.remove_absolute(tmp.path_join(name))
	DirAccess.remove_absolute(tmp)
	for f in failures: printerr("SCENARIOFILE FAIL ", f)
	print("SCENARIOFILE DONE %d checks, %d failures" % [checks, failures.size()])
	get_tree().quit(1 if not failures.is_empty() else 0)

# READING NUMBERS: the nearest double, where String.to_float can be an ulp off.
const DECIMALS := [
	["0.1", "9a9999999999b93f"], ["0.10000000000000001", "9a9999999999b93f"],
	["0.3", "333333333333d33f"], ["0.29999999999999999", "333333333333d33f"],
	["7.4957", "4182e2c798fb1d40"], ["7.4957000000000003", "4182e2c798fb1d40"],
	["5e-324", "0100000000000000"], ["4.9406564584124654e-324", "0100000000000000"],
	["2.2250738585072014e-308", "0000000000001000"], ["1.7976931348623157e+308", "ffffffffffffef7f"],
	["0", "0000000000000000"], ["-0", "0000000000000080"], ["0.000e7", "0000000000000000"],
	["1e-330", "0000000000000000"], ["-1e-330", "0000000000000080"],
	# Mantissas past int64, and 1 + 2⁻⁵³ (the midpoint above 1) written out: a tie goes to even.
	["9.999999999999999999", "0000000000002440"], ["0.9999999999999999999", "000000000000f03f"],
	["1.00000000000000011102230246251565404236316680908203125", "000000000000f03f"],
	["1.00000000000000011102230246251565404236316680908203126", "010000000000f03f"],
	["1e99999999999999999999", "000000000000f07f"], ["1e-99999999999999999999", "0000000000000000"],
	["2.4703282292062327e-324", "0000000000000000"], ["2.4703282292062328e-324", "0100000000000000"],
	["6.02214076e+23", "17c557ca85e1df44"], ["6.0221407599999999e+23", "17c557ca85e1df44"],
	["1e-12", "11ea2d819997713d"], ["9.9999999999999998e-13", "11ea2d819997713d"],
	["3.0035e-06", "52754696f731c93e"], ["0.00115273063734272", "eaecdc18e7e2523f"],
	["0.0011527306373427201", "eaecdc18e7e2523f"], ["9007199254740992", "0000000000004043"],
	["9007199254740993", "0000000000004043"],
	["-41133280.68750414", "2c028005279d83c1"], ["-41133280.687504143", "2c028005279d83c1"],
	["7.250236593433288e-12", "42d1a66b0ae39f3d"], ["7.2502365934332878e-12", "42d1a66b0ae39f3d"],
	["-8512.180957803213", "6113a02917a0c0c0"], ["-8512.1809578032135", "6113a02917a0c0c0"],
	["-6.53453243158078e-14", "c1785c79a06432bd"], ["16309769133346.336", "ac44bafdd3aaad42"],
	["772161149759.9664", "edfe67830c796642"], ["772161149759.96643", "edfe67830c796642"],
	["4.550534414555413e-13", "2203fbcbc102603d"], ["4.5505344145554127e-13", "2203fbcbc102603d"],
	["264.446054720334", "fa40460a23877040"], ["264.44605472033402", "fa40460a23877040"],
	["0.0013837138433340603", "afaa106db7ab563f"], ["-6.728315645599016e-15", "23b5a744384dfebc"],
	["-6.7283156455990156e-15", "23b5a744384dfebc"], ["-1.3929803243573108e-09", "6887dc6a64ee17be"],
	["5.1738735966730935", "34658deb0bb21440"], ["-0.0036723534639978351", "cd02dfc07b156ebf"],
	["-35536225491.974228", "cef2a7893f8c20c2"], ["715.94626956260242", "9fc4c6f5915f8640"],
	["-0.0075305696736899016", "66fd7fe75fd87ebf"], ["5389486023.2772646", "ad6f747cd013f441"],
]

func decimals() -> void:
	for v in DECIMALS:
		var got := Jsonc.decimal(v[0])
		check("%s reads as the nearest double (%s, not %s)" % [v[0], v[1], PackedFloat64Array([got]).to_byte_array().hex_encode()],
			PackedFloat64Array([got]).to_byte_array().hex_encode() == v[1])
	var r := Jsonc.parse("{\"a\": 1e400}")
	check("1e400 reads as infinite, for the finite checks to refuse", r.error.is_empty() and is_inf(float(r.data.a)))
	# Windows' pow() overflows the estimate for the largest double; the exact step must recover it.
	check("an estimate that overflowed still finds the largest double",
		Jsonc._nearest(Jsonc._big(17976931348623157), 292, INF) == 1.7976931348623157e308)
	check("and a value past its rounding edge stays infinite", is_inf(Jsonc._nearest(Jsonc._big(18), 307, INF)))
	# Past MAX_DIGITS only "anything nonzero" survives, which is what decides a tie.
	var tie := "1.00000000000000011102230246251565404236316680908203125" + "0".repeat(1000)
	check("a tie written with a thousand more zeros still goes to even", Jsonc.decimal(tie) == 1.0)
	check("and one more nonzero digit far out rounds up", Jsonc.decimal(tie + "1") == 1.0000000000000002)
	check("an estimate that underflowed still finds the smallest subnormal",
		Jsonc._nearest(Jsonc._big(5), -324, 0.0) == Jsonc._from_bits(1))

# THE BUILT-INS, against the builds they were written from.
static func encode(v: Variant) -> Variant:
	if v is float: return ["d", PackedFloat64Array([v]).to_byte_array().hex_encode()]
	if v is int: return ["i", v]
	if v is Array or v is PackedFloat64Array or v is PackedFloat32Array:
		return Array(v).map(func(x): return encode(x))
	if v is Dictionary:
		var out := {}
		for k in v:
			if v[k] is Callable: continue
			out[str(k)] = encode(v[k])
		return out
	return v

static func decode(v: Variant) -> Variant:
	if v is Array and v.size() == 2 and v[0] is String and v[0] == "d":
		return PackedByteArray(Array(v[1].hex_decode())).decode_double(0)
	if v is Array and v.size() == 2 and v[0] is String and v[0] == "i": return int(v[1])
	if v is Array: return v.map(func(x): return decode(x))
	if v is Dictionary:
		var out := {}
		for k in v: out[k] = decode(v[k])
		return out
	return v

## Empty when equal: numbers by value (int or float, so 0.0 == -0.0), everything else exactly.
## `ulps` > 0 lets a number, or each component of a vector, differ by that many ulps of
## the vector's largest component: trig puts a near-zero component many of its own ulps off.
static func diff(a: Variant, b: Variant, path := "", ulps := 0) -> String:
	var an := a is int or a is float
	var bn := b is int or b is float
	if an or bn:
		var same := an and bn and (float(a) == float(b) or ulps > 0 and ulp_distance(float(a), float(b)) <= ulps)
		return "" if same else "%s: %s vs %s" % [path, var_to_str(a), var_to_str(b)]
	if a is Array or a is PackedFloat64Array:
		if not (b is Array or b is PackedFloat64Array) or a.size() != b.size(): return "%s: %s vs %s" % [path, var_to_str(a), var_to_str(b)]
		if ulps > 0 and a.size() > 0 and Array(a).all(func(x): return x is float or x is int) and Array(b).all(func(x): return x is float or x is int):
			var scale := 0.0
			for x in a: scale = maxf(scale, absf(float(x)))
			var tol := float(ulps) * (Jsonc._next(scale, 1) - scale) if scale > 0.0 else 0.0
			for i in a.size():
				if not (absf(float(a[i]) - float(b[i])) <= tol): return "%s[%d]: %s vs %s" % [path, i, var_to_str(a[i]), var_to_str(b[i])]
			return ""
		for i in a.size():
			var d := diff(a[i], b[i], "%s[%d]" % [path, i], ulps)
			if not d.is_empty(): return d
		return ""
	if a is Dictionary:
		if not b is Dictionary: return "%s: not an object" % path
		for k in a:
			if not b.has(k): return "%s.%s: missing" % [path, k]
			var d := diff(a[k], b[k], "%s.%s" % [path, k], ulps)
			if not d.is_empty(): return d
		for k in b:
			if not a.has(k): return "%s.%s: extra" % [path, k]
		return ""
	return "" if typeof(a) == typeof(b) and a == b else "%s: %s vs %s" % [path, var_to_str(a), var_to_str(b)]

static func ulp_distance(a: float, b: float) -> int:
	if not (is_finite(a) and is_finite(b)) or (a < 0.0) != (b < 0.0): return 0 if a == b else 1 << 62
	var buf := PackedByteArray()
	buf.resize(16)
	buf.encode_double(0, absf(a))
	buf.encode_double(8, absf(b))
	return absi(buf.decode_s64(0) - buf.decode_s64(8))

# What load_preset_spec assumes when a preset leaves a setting out.
const CONSUMER_DEFAULTS := {"bodyScale": 1.0, "trueScale": false, "timeScale": 2.0, "maxStep": 5e-3,
	"gwBoost": 0.0, "discIntensity": 0.9, "spawnAtRest": false, "lensing": false, "mesh": true, "surface": false}
const FILE_ONLY := ["group", "order", "file", "warnings", "massSlider", "build"]
const ORBIT_ULPS := 4

func compare_builtins() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	var files := 0
	for name in DirAccess.get_files_at(Presets.SCENARIO_DIR):
		if not name.ends_with(".jsonc"): continue
		files += 1
		var key := name.get_basename()
		var r := ScenarioFile.read(Presets.SCENARIO_DIR.path_join(name), true)
		check("%s loads: %s" % [key, r.errors], r.ok)
		check("%s has no warnings: %s" % [key, r.warnings], r.warnings.is_empty())
		if not r.ok: continue
		check("%s is in Presets" % key, Presets.PRESETS.has(key) and key in Presets.PRESET_ORDER)
		if not fixture.has(key):
			check("%s is in the fixture (snapshot=1 after an intended change)" % key, false)
			continue
		# An orbit goes through sin and cos, which libms do not round alike: the fixture
		# is macOS's, and glibc and MinGW put sirius an ulp away. States stay exact.
		var trig := FileAccess.get_file_as_string(Presets.SCENARIO_DIR.path_join(name)).contains("\"orbit\"")
		compare_preset(key, decode(fixture[key]), r.preset, ORBIT_ULPS if trig else 0)
	# The two built in code go through Kepler's equation in libm, like an orbit file.
	for key in ["solar", "jovian_voyage"]:
		check("%s is in the fixture" % key, fixture.has(key) and Presets.PRESETS.has(key))
		if fixture.has(key) and Presets.PRESETS.has(key): compare_preset(key, decode(fixture[key]), Presets.PRESETS[key], ORBIT_ULPS)
	check("every built-in file was read (%d)" % files, files >= 36)
	var five := Jsonc._from_bits(Jsonc._bits(1.0) + 5)
	check("the orbit allowance is %d ulps and no more" % ORBIT_ULPS,
		diff([1.0], [Jsonc._from_bits(Jsonc._bits(1.0) + ORBIT_ULPS)], "", ORBIT_ULPS).is_empty() and not diff([1.0], [five], "", ORBIT_ULPS).is_empty())
	check("the Trisolaris file builds four bodies with Trisolaris placed by its orbit",
		FileAccess.get_file_as_string("res://scenarios/trisolaris.jsonc").contains("\"testParticle\": true"))

func compare_preset(key: String, want: Dictionary, got: Dictionary, ulps: int) -> void:
	var keys := {}
	for k in want: keys[k] = true
	for k in got: keys[k] = true
	for k in keys:
		if k == "bodies" or k in FILE_ONLY: continue
		var d := diff(want.get(k, CONSUMER_DEFAULTS.get(k)), got.get(k, CONSUMER_DEFAULTS.get(k)), k)
		check("%s: %s" % [key, d], d.is_empty())
	var d := diff(want.bodies, got.build.call(), "bodies", ulps)
	check("%s: %s" % [key, d], d.is_empty())

func snapshot() -> int:
	var out := {}
	for key in Presets.PRESET_ORDER:
		var p: Dictionary = Presets.PRESETS[key]
		var r: Dictionary = encode(p)
		r["bodies"] = encode(p.build.call())
		for k in ["file", "warnings", "group", "massSlider"]: r.erase(k)
		out[key] = r
	var f := FileAccess.open(FIXTURE, FileAccess.WRITE)
	if f == null:
		printerr("SCENARIOFILE cannot write ", FIXTURE)
		return 1
	f.store_string(JSON.stringify(out, "\t", true))
	f.close()
	print("SCENARIOFILE snapshot ", out.size(), " scenarios")
	return 0

# REFUSALS: each file must be refused with a message naming the problem.
const STAR := "{\"type\": \"star\", \"name\": \"Sun\", \"mass\": 1}"
const EARTH := "{\"type\": \"planet\", \"name\": \"Earth\", \"mass\": 3e-6, \"orbit\": {\"around\": \"Sun\", \"a\": 1}}"

static func file(bodies: String, extra := "") -> String:
	return "{\"format\": 1, \"name\": \"t\", %s \"bodies\": [%s]}" % [extra + "," if not extra.is_empty() else "", bodies]

func refuse(label: String, text: String, fragment: String, builtin := false) -> void:
	var r := ScenarioFile.from_text(text, builtin)
	var said := "; ".join(r.errors)
	check("refuses %s (said: %s)" % [label, said], not r.ok and said.contains(fragment))

func refusals() -> void:
	refuse("a syntax error, with its line", "{\n\"format\": 1,\n\"name\" \"t\"}", "line 3")
	refuse("a duplicate key", "{\"format\": 1, \"format\": 1, \"name\": \"t\", \"bodies\": []}", "duplicate key")
	refuse("NaN", file(STAR.replace("1}", "NaN}")), "expected a value")
	refuse("an infinite number", file(STAR.replace("1}", "1e400}")), "finite")
	refuse("a missing format", "{\"name\": \"t\", \"bodies\": []}", "format is required")
	refuse("another format", file("", "\"format\": 2").replace("\"format\": 1, ", ""), "must be 1")
	refuse("an unknown top-level key", file(STAR, "\"camRadus\": 3"), "camRadus")
	refuse("an unknown body key, with its line", "{\"format\": 1, \"name\": \"t\", \"bodies\": [\n{\"type\": \"star\", \"name\": \"Sun\", \"mas\": 1}]}", "bodies[0].mas (line 2): unknown key")
	refuse("a key that does not apply to the type", file("{\"type\": \"star\", \"name\": \"Sun\", \"rings\": true}"), "does not apply to a star")
	refuse("a wrong type", file("{\"type\": \"star\", \"name\": \"Sun\", \"mass\": \"heavy\"}"), "finite number")
	refuse("an unknown body type", file("{\"type\": \"comet\", \"name\": \"C\"}"), "must be one of")
	refuse("a missing name", file("{\"type\": \"star\"}"), "name")
	refuse("a null name", file("{\"type\": \"star\", \"name\": null}"), "name")
	refuse("a colour that is not #rrggbb", file("{\"type\": \"star\", \"name\": \"Sun\", \"color\": \"red\"}"), "#rrggbb")
	refuse("an unknown palette", file("{\"type\": \"gas-giant\", \"name\": \"J\", \"palette\": \"plaid\"}"), "must be one of")
	refuse("an unknown catalogue star", file("{\"type\": \"star\", \"name\": \"X\", \"catalog\": \"nostar\"}"), "catalogue")
	refuse("a catalogue star of another type", file("{\"type\": \"star\", \"name\": \"B\", \"catalog\": \"siriusB\"}"), "white-dwarf")
	refuse("an unknown phase", file("{\"type\": \"star\", \"name\": \"Sun\", \"phase\": \"teenage\"}"), "phase")
	refuse("zero mass", file("{\"type\": \"star\", \"name\": \"Sun\", \"mass\": 0}"), "above 0")
	refuse("a body outside the structure model", file("{\"type\": \"star\", \"name\": \"Sun\", \"spinFrac\": 2}"), "mass-shedding")
	refuse("a climate input outside its domain", file("{\"type\": \"world\", \"name\": \"W\", \"pCO2\": 500}"), "pCO2")
	refuse("duplicate names", file(STAR + "," + STAR.replace("1}", "2, \"pos\": [5, 0, 0]}")), "already the name")
	refuse("both an orbit and a position", file(STAR + "," + EARTH.replace("\"orbit\"", "\"pos\": [1, 0, 0], \"orbit\"")), "use one")
	refuse("an orbit around nobody", file(EARTH), "no body is named \"Sun\"")
	refuse("orbits that name each other", file("{\"type\": \"star\", \"name\": \"A\", \"orbit\": {\"around\": \"B\", \"a\": 1}}, {\"type\": \"star\", \"name\": \"B\", \"orbit\": {\"around\": \"A\", \"a\": 1}}"), "loop")
	refuse("an unbound eccentricity", file(STAR + "," + EARTH.replace("\"a\": 1", "\"a\": 1, \"e\": 1")), "below 1")
	refuse("a missing semi-major axis", file(STAR + "," + EARTH.replace("\"a\": 1", "\"e\": 0.1")), "orbit.a")
	refuse("bodies touching at the start", file(STAR + "," + STAR.replace("Sun", "Twin").replace("1}", "1, \"pos\": [0.001, 0, 0]}")), "touches Sun")
	refuse("a body at the speed of light", file(STAR.replace("1}", "1, \"vel\": [70000, 0, 0]}")), "speed of light")
	refuse("a white dwarf at the Chandrasekhar mass", file("{\"type\": \"white-dwarf\", \"name\": \"WD\", \"mass\": 1.5}"), "Chandrasekhar")
	refuse("a neutron star past the TOV limit", file("{\"type\": \"neutron\", \"name\": \"NS\", \"mass\": 2.6}"), "TOV")
	refuse("two home worlds", file("{\"type\": \"world\", \"name\": \"A\", \"home\": true, \"pos\": [1, 0, 0]}, {\"type\": \"world\", \"name\": \"B\", \"home\": true, \"pos\": [2, 0, 0]}"), "only one body")
	refuse("climate without a home world", file(STAR, "\"climate\": {\"T0\": 288}"), "home world")
	refuse("an unknown climate input", file(STAR, "\"climate\": {\"T00\": 288}"), "T00")
	refuse("a focus on nobody", file(STAR, "\"focus\": \"Moon\""), "no body is named \"Moon\"")
	refuse("paint on nobody", file(STAR, "\"paint\": [{\"kind\": \"ring\", \"body\": \"Moon\", \"inner\": 1, \"outer\": 2}]"), "paint[0].body")
	refuse("a ring with no inner edge", file(STAR, "\"paint\": [{\"kind\": \"ring\", \"body\": \"Sun\", \"outer\": 2}]"), "inner and outer")
	refuse("too many paint particles", file(STAR, "\"paint\": [{\"kind\": \"belt\", \"body\": \"Sun\", \"inner\": 1, \"outer\": 2, \"count\": 400000}, {\"kind\": \"belt\", \"body\": \"Sun\", \"inner\": 3, \"outer\": 4, \"count\": 400000}]"), "particles")
	refuse("a tidal lock on itself", file("{\"type\": \"planet\", \"name\": \"P\", \"tidalLock\": \"P\"}"), "another body")
	refuse("a camera distance out of range", file(STAR, "\"camRadius\": 1e7"), "camRadius")
	refuse("a zero scene scale", file(STAR, "\"sceneScale\": 0"), "sceneScale")
	refuse("a zero step", file(STAR, "\"maxStep\": 0"), "maxStep")
	refuse("an unknown sky environment", file(STAR, "\"sky\": {\"env\": \"nebulous\"}"), "nebulous")
	refuse("an uploaded file choosing a group", file(STAR, "\"group\": \"learning\""), "built-in")
	refuse("a mass slider with no black hole", file(STAR, "\"massSlider\": true"), "black hole")
	refuse("a null name", "{\"format\": 1, \"name\": null, \"bodies\": []}", "name is required")
	refuse("a null format", "{\"format\": null, \"name\": \"t\", \"bodies\": []}", "format is required")
	refuse("an unknown list group", file(STAR, "\"group\": \"trisolars\""), "must be one of", true)
	refuse("a home world that the file's climate pushes out of range",
		file(STAR + ", {\"type\": \"world\", \"name\": \"Home\", \"home\": true, \"albedoBase\": 0.6, \"orbit\": {\"around\": \"Sun\", \"a\": 1}}",
			"\"climate\": {\"albedoIce\": 0.5}"), "bodies[1]")
	for pair in [["a b.jsonc", "a_b.jsonc"], ["A.jsonc", "a.jsonc"], ["a b.jsonc", "a_b_c8687a08.jsonc"], ["a.json", "a.jsonc"]]:
		check("%s and %s keep distinct copies" % pair, ScenarioStore.key_for(pair[0]) != ScenarioStore.key_for(pair[1]))
	check("one name always lands on one copy (%s)" % ScenarioStore.key_for("/x/My System.jsonc"),
		ScenarioStore.key_for("/x/My System.jsonc") == ScenarioStore.key_for("/y/My System.jsonc"))
	check("and the key gives the name back", ScenarioStore.name_of(ScenarioStore.key_for("/x/Système_2 (b).jsonc")) == "Système_2 (b).jsonc")
	var many := []
	for i in ScenarioFile.MAX_BODIES + 1: many.append("{\"type\": \"planet\", \"name\": \"p%d\", \"pos\": [%d, 0, 0]}" % [i, i])
	refuse("more bodies than a file may hold", file(", ".join(many)), "the most a file may hold")
	var ok := ScenarioFile.from_text(file(STAR + "," + EARTH, "\"group\": \"learning\""), true)
	check("a built-in may choose its group", ok.ok and ok.preset.group == "learning")

# WARNINGS: the file loads, and says why it may be slow.
func warnings() -> void:
	var ring := []
	for i in 300: ring.append("{\"type\": \"planet\", \"name\": \"p%d\", \"orbit\": {\"around\": \"Sun\", \"a\": %s, \"nu\": %d, \"testParticle\": true}}" % [i, 3.0 + i * 0.2, i * 37])
	var r := ScenarioFile.from_text(file(STAR + "," + ", ".join(ring)))
	check("300 bodies load with warnings (%s)" % [r.errors], r.ok and r.warnings.size() >= 1)
	check("and the warnings name the count (%s)" % [r.warnings], r.ok and r.warnings.any(func(w): return w.contains("301 bodies")))
	# 80 planets beside a 0.02 AU pair: 524 sub-steps a frame, about 150 ms by the model.
	var crowd := [STAR, "{\"type\": \"star\", \"name\": \"B\", \"mass\": 1, \"orbit\": {\"around\": \"Sun\", \"a\": 0.02}}"]
	for i in 80: crowd.append("{\"type\": \"planet\", \"name\": \"p%d\", \"pos\": [%d, 0, 0]}" % [i, 3 + i])
	var costly := ScenarioFile.from_text(file(", ".join(crowd), "\"timeScale\": 0.5"))
	check("a crowd beside a tight pair warns of its cost, not its count (%s)" % [costly.warnings],
		costly.ok and costly.warnings.any(func(w): return w.contains("Predicted")) and not costly.warnings.any(func(w): return w.contains("bodies: past")))
	var tight := ScenarioFile.from_text(file(STAR + ", {\"type\": \"star\", \"name\": \"B\", \"mass\": 1, \"orbit\": {\"around\": \"Sun\", \"a\": 0.02}}", "\"timeScale\": 50"))
	check("a pair that needs more sub-steps than the guard warns (%s)" % [tight.warnings],
		tight.ok and tight.warnings.any(func(w): return w.contains("sub-steps")))
	var fast := ScenarioFile.from_text(file(STAR.replace("1}", "1, \"vel\": [10000, 0, 0]}")))
	check("a body above 0.1c warns (%s)" % [fast.warnings], fast.ok and fast.warnings.any(func(w): return w.contains("0.1c")))
	var calm := ScenarioFile.from_text(file(STAR + "," + EARTH))
	check("an ordinary system has no warnings (%s)" % [calm.warnings], calm.ok and calm.warnings.is_empty())

# DEFAULTS: what a file leaves out, or writes as null.
func defaults() -> void:
	var r := ScenarioFile.from_text(file(STAR + "," + EARTH, "\"camRadius\": null"))
	check("an ordinary system loads", r.ok)
	if not r.ok: return
	var p: Dictionary = r.preset
	var extent := 1.0 - 3e-6 / (1.0 + 3e-6)
	check("sceneScale frames the widest start distance at 20 units (%s)" % p.sceneScale, absf(float(p.sceneScale) - 20.0 / extent) < 1e-6)
	check("camRadius is 2.5× that, and null counts as left out (%s)" % p.camRadius, absf(float(p.camRadius) - 50.0) < 1e-6)
	check("timeScale makes the shortest orbit last 10 s (%s yr/s)" % p.timeScale, absf(float(p.timeScale) - 0.1) < 1e-3)
	check("no lensing without a black hole", not p.has("lensing"))
	var bodies: Array = p.build.call()
	check("a two-body orbit moves its parent: the barycentre stays put", absf(float(bodies[0].pos[0]) * 1.0 + float(bodies[1].pos[0]) * 3e-6) < 1e-15)
	check("each build is a fresh copy", p.build.call()[0] != null and p.build.call()[0] is Dictionary and not is_same(p.build.call()[0], bodies[0]))
	var one := ScenarioFile.from_text(file("{\"type\": \"bh\", \"name\": \"Hole\", \"mass\": 8}"))
	check("one body is focused, at 12 units, with lensing on", one.ok and one.preset.focus == "Hole" and one.preset.camRadius == 12.0 and one.preset.lensing == true)
	var moon := ScenarioFile.from_text(file(STAR + "," + EARTH.replace("\"a\": 1}", "\"a\": 1, \"testParticle\": true}") +
		", {\"type\": \"planet\", \"name\": \"Moon\", \"mass\": 3.7e-8, \"orbit\": {\"around\": \"Earth\", \"a\": 0.00257}}" +
		", {\"type\": \"gas-giant\", \"name\": \"J\", \"mass\": 9.5e-4, \"orbit\": {\"around\": \"Sun\", \"a\": 5.2}}"))
	var mb: Array = moon.preset.build.call() if moon.ok else []
	check("a parent's satellites move with it when a later orbit makes it recoil", moon.ok
		and absf((float(mb[2].pos[0]) - float(mb[1].pos[0])) - 0.00257) < 1e-12
		and absf((float(mb[1].pos[0]) - float(mb[0].pos[0])) - (1.0 - 0.00257 * 3.7e-8 / (3e-6 + 3.7e-8))) < 1e-12
		and float(mb[0].pos[0]) != 0.0)

# THE STAGE
func write(name: String, text: String) -> String:
	var path := tmp.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path

func frames(n: int) -> void:
	for i in n:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame

func through_the_stage() -> void:
	stage = load("res://main.tscn").instantiate()
	stage._cmd["settings"] = "default"
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	check("checks never read the user's uploads", ScenarioStore.dir != "user://scenarios")
	check("the sandbox shows its mass slider", stage.hud.ids.get("massRow") == null or stage.state.preset.get("massSlider") == true)

	var good := write("My System.jsonc", "// a comment\n" + file(STAR + "," + EARTH + ",", "\"blurb\": \"two\""))
	check("an upload loads", stage.upload_scenario(good))
	var key := ScenarioStore.key_for(good)
	check("it is kept under Custom as %s" % key, Presets.PRESETS.has(key) and FileAccess.file_exists(ScenarioStore.path_of(key)))
	check("and listed in the Custom group", stage.PRESET_GROUPS.any(func(g): return g.id == ScenarioStore.GROUP and key in g.keys))
	check("its copy keeps the comments", FileAccess.get_file_as_string(ScenarioStore.path_of(key)).begins_with("// a comment"))
	check("and the stage holds its two bodies", stage.state.preset_key == key and stage.state.bodies.size() == 2)
	write("My System.jsonc", file(STAR + "," + EARTH + "," + EARTH.replace("Earth", "Mars").replace("\"a\": 1", "\"a\": 1.5")))
	stage.upload_scenario(good)
	check("uploading the same name replaces it", stage.state.bodies.size() == 3 and stage.PRESET_GROUPS.filter(func(g): return g.id == ScenarioStore.GROUP)[0].keys.size() == 1)

	var long := write("L".repeat(100) + ".jsonc", file(STAR))
	check("a name too long to escape is refused (%s)" % ScenarioStore.add(long).errors, not ScenarioStore.add(long).ok and not FileAccess.file_exists(ScenarioStore.path_of(ScenarioStore.key_for(long))))

	var before: int = stage.state.bodies.size()
	var bad := write("Broken.jsonc", file("{\"type\": \"star\", \"name\": \"Sun\", \"mas\": 1}"))
	check("a refused upload returns false", not stage.upload_scenario(bad))
	check("and is not copied", not FileAccess.file_exists(ScenarioStore.path_of(ScenarioStore.key_for(bad))))
	check("and leaves the scene as it was", stage.state.bodies.size() == before and stage.state.preset_key == key)
	check("and the notice says why (%s)" % stage.hud.notice_text(), stage.hud.notice_text().contains("unknown key"))

	var ring := []
	for i in 300: ring.append("{\"type\": \"gas-giant\", \"name\": \"g%d\", \"orbit\": {\"around\": \"Sun\", \"a\": %s, \"nu\": %d, \"testParticle\": true}}" % [i, 3.0 + i * 0.2, i * 37])
	var heavy := write("Crowd.jsonc", file(STAR + "," + ", ".join(ring)))
	check("a file with warnings asks before loading", not stage.upload_scenario(heavy) and stage.state.preset_key == key)
	check("the notice offers Load anyway (%s)" % stage.hud.notice_text(), stage.hud.notice_text().contains("301 bodies") and stage.hud.sels.has("[data-notice=load-anyway]"))
	var crowd := ScenarioStore.key_for(heavy)
	check("its entry is kept, marked", Presets.PRESETS.has(crowd) and not Presets.PRESETS[crowd].warnings.is_empty())
	stage.state.paused = false
	stage.slice_ms = 0
	stage.load_preset(crowd, true)
	var held := true
	var guard := 0
	while stage._loading and guard < 600:
		var years: float = stage.state.sim_years
		await frames(1)
		held = held and stage.state.sim_years == years
		guard += 1
	stage.slice_ms = 30
	check("Load anyway spawns every body (%d)" % stage.state.bodies.size(), stage.state.bodies.size() == 301 and stage.state.preset_key == crowd)
	check("over %d frames, with the clock held" % guard, held and guard > 100)
	stage._watch_frame(1.5)
	stage._watch_frame(1.5)
	check("two frames over a second pause the simulation and say so", stage.state.paused and stage.hud.notice_text().contains("under 1 FPS"))
	stage.state.paused = false

	stage.load_preset(key)
	stage.slice_deadline_ms = 0
	stage.load_preset(crowd, true)
	guard = 0
	while stage._loading and guard < 600:
		await frames(1)
		guard += 1
	check("past the deadline the load stops and the previous scenario returns (%s)" % stage.state.preset_key, stage.state.preset_key == key and stage.state.bodies.size() == 3)
	check("and the notice says it failed (%s)" % stage.hud.notice_text(), stage.hud.notice_text().contains("failed"))
	stage.slice_deadline_ms = 15000

	# Past the deadline after another warned scenario, Blank Canvas comes back; without it, an empty stage.
	stage.load_preset(crowd, true)
	guard = 0
	while stage._loading and guard < 600:
		await frames(1)
		guard += 1
	var blank: Dictionary = Presets.PRESETS.blank
	Presets.PRESETS.erase("blank")
	stage.slice_deadline_ms = 0
	stage.load_preset(crowd, true)
	guard = 0
	while stage._loading and guard < 600:
		await frames(1)
		guard += 1
	Presets.PRESETS.blank = blank
	stage.slice_deadline_ms = 15000
	check("with no Blank Canvas the failed load leaves an empty stage (%d bodies)" % stage.state.bodies.size(),
		stage.state.bodies.is_empty() and stage.state.preset == null and stage.hud.notice_text().contains("failed"))

	# A galaxy taking the stage mid-load stops the load; the slow-frame watch ends with it.
	stage.slice_ms = 0
	stage.load_preset(crowd, true)
	await frames(3)
	var midway: bool = stage._loading
	stage.slice_ms = 30
	stage.load_preset(GalModels.ORDER[0])
	await frames(10)
	check("a galaxy entered mid-load stops it (was loading: %s, %d bodies)" % [midway, stage.state.bodies.size()],
		midway and not stage._loading and stage.state.bodies.is_empty() and stage.galaxy.active)
	stage._watch_slow = 0
	stage._watch_until = Time.get_ticks_msec() + 3000
	stage._watch_frame(1.5)
	stage._watch_frame(1.5)
	check("and the slow-frame watch stands down in the galaxy", stage._watch_slow == -1 and not stage.state.paused)
	stage.load_preset(key)
	check("the orrery loads again after it", stage.state.preset_key == key and not stage.galaxy.active)

	stage.request_remove_scenario(crowd)
	check("remove asks first", Presets.PRESETS.has(crowd) and stage.hud.sels.has("[data-notice=remove]"))
	stage.remove_scenario(crowd)
	check("and then deletes the copy and the entry", not Presets.PRESETS.has(crowd) and not FileAccess.file_exists(ScenarioStore.path_of(crowd)))

	var world := write("Home.jsonc", file(STAR + ", {\"type\": \"world\", \"name\": \"Home\", \"mass\": 3e-6, \"radiusKm\": 6371, \"home\": true," +
		" \"atmosphere\": true, \"land\": 0.4, \"pCO2\": 0.0004, \"pN2\": 0.78, \"pO2\": 0.21, \"obliquity\": 20, \"dayLength\": 30," +
		" \"orbit\": {\"around\": \"Sun\", \"a\": 1.1, \"testParticle\": true}}", "\"surface\": true, \"focus\": \"Home\", \"climate\": {\"mixedLayer\": 40}"))
	check("an uploaded rocky world loads", stage.upload_scenario(world))
	await frames(3)
	stage.set_app_mode("showcase", {"body": "Home"})
	var s: Showcase = stage.showcase
	s.drop_pin()
	s.stand()
	await frames(30)
	check("and can be stood on", s.visit != null and SurfaceStats.total() > 0)
	s.leave_surface()
	stage.set_app_mode("sandbox")
	stage.remove_scenario(ScenarioStore.key_for(world))
	stage.remove_scenario(key)
	check("a lesson's built-in scenario still loads", stage.load_preset("edu_hole") and stage.state.bodies.size() == 1)
