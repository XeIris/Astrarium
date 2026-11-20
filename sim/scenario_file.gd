class_name ScenarioFile
extends RefCounted

# A scenario file (docs/scenario-format.md) to a preset dictionary in the physics' units.
# Pure: no scene access. Every error is found before anything is built, so a refused
# file never touches the stage.

const FORMAT := 1
const MAX_BYTES := 4 * 1024 * 1024
const MAX_BODIES := 2048
const WARN_BODIES := 256
const MAX_PARTICLES := 500000
const HOURS_PER_YEAR := 8766.0   # Julian year, as Rocketry.YR_S
const DT_FRAME := 1.0 / 60.0

# Frame time on an Apple M5, rounded up so the warning comes early
# (docs/scenario-format.md#limits-measured). Re-measure with tools/scenariolimits.tscn
# when per-body costs change.
const COST := {"body_ms": 0.1, "star_ms": 0.07, "pair_step_ms": 4.0e-5, "budget_ms": 100.0}

## The Scenario panel's list groups a built-in may name, in panel order, with their headings.
const GROUPS := {
	"learning": "Learning scenarios", "trisolaris": "Trisolaris scenarios", "black-holes": "BH scenarios",
	"neutron-stars": "Neutron star scenarios", "sandboxes": "Sandboxes", "real-stars": "Real stars",
	"stellar-systems": "Stellar system scenarios",
}

const TYPES := ["planet", "world", "gas-giant", "star", "white-dwarf", "neutron", "bh"]
const ROCKY := ["planet", "world"]
const STELLAR := ["star", "white-dwarf"]
const NOT_HOLE := ["planet", "world", "gas-giant", "star", "white-dwarf", "neutron"]

# kind, types (empty: all), and limits. "deg" and "hours" convert to radians and years.
const BODY_KEYS := {
	"type": ["type", []], "name": ["name", []], "mass": ["num", [], 0.0, INF, true],
	"pos": ["vec3", []], "vel": ["vec3", []], "orbit": ["orbit", []],
	"spinFrac": ["num", [], 0.0, INF], "spinHz": ["num", ["neutron"], 0.0, INF],
	"visualSpinRadS": ["num", [], -INF, INF], "phase": ["phase", STELLAR],
	"catalog": ["catalog", ["star", "white-dwarf", "neutron"]],
	"radiusSun": ["num", STELLAR, 0.0, INF, true], "radiusKm": ["num", ["planet", "world", "gas-giant", "neutron"], 0.0, INF, true],
	"teff": ["num", STELLAR, 0.0, INF, true], "luminosity": ["num", STELLAR, 0.0, INF],
	"Z": ["num", NOT_HOLE, 0.0, 1.0], "ageYr": ["num", [], 0.0, 1e11, true],
	"composition": ["composition", ROCKY], "contactAU": ["num", NOT_HOLE, 0.0, INF],
	"softening": ["num", [], 0.0, INF], "emitsGW": ["bool", []],
	"k2": ["num", NOT_HOLE, 0.0, INF], "tideLagS": ["num", NOT_HOLE, 0.0, INF],
	"dayLength": ["hours", ["planet", "world", "gas-giant"]], "obliquity": ["deg", []],
	"tidalLock": ["body", ROCKY], "home": ["bool", ["world"]], "seed": ["num", [], -INF, INF],
	# climate inputs: ranges are ClimateInputs.DOMAIN's, checked by Structure.input_error
	"mixedLayer": ["num", ROCKY, -INF, INF], "albedoBase": ["num", ROCKY, -INF, INF],
	"albedoIce": ["num", ROCKY, -INF, INF], "albedo": ["num", ["planet", "world", "gas-giant"], 0.0, 1.0],
	"T0": ["num", ROCKY, -INF, INF], "oceans": ["bool", ROCKY], "salinity": ["num", ROCKY, -INF, INF],
	"land": ["num", ROCKY, -INF, INF], "oceanDepth": ["num", ROCKY, -INF, INF],
	"pN2": ["num", ROCKY, -INF, INF], "pO2": ["num", ROCKY, -INF, INF], "pAr": ["num", ROCKY, -INF, INF],
	"pCO2": ["num", ROCKY, -INF, INF], "pCH4": ["num", ROCKY, -INF, INF], "pSO2": ["num", ROCKY, -INF, INF],
	# look
	"color": ["color", []], "glow": ["color", []],
	"palette": ["palette", ["gas-giant"]], "rings": ["bool", ["gas-giant"]],
	"ringInner": ["num", ["gas-giant"], 1.0, 20.0], "ringOuter": ["num", ["gas-giant"], 1.0, 20.0],
	"ringColor": ["color", ["gas-giant"]], "internalHeat": ["num", ["gas-giant"], 0.0, 100.0],
	"vortices": ["int", ["gas-giant"], 0.0, 8.0],
	"hot": ["bool", ROCKY], "atmosphere": ["bool", ROCKY],
	"atmColor": ["color", ROCKY], "cloudColor": ["color", ROCKY], "regolith": ["color", ROCKY],
	"atmThick": ["num", ROCKY, 0.0, 4.0], "haze": ["num", ROCKY, 0.0, 1.0], "crater": ["num", ROCKY, 0.0, 1.0],
	"cloudCover": ["num", ROCKY, 0.0, 1.0], "biota": ["num", ROCKY, 0.0, 1.0], "arid": ["num", ROCKY, 0.0, 1.0],
	"transport": ["num", ROCKY, 0.0, 1.0], "cloudSpin": ["num", ROCKY, -100.0, 100.0],
	"surfaceK": ["num", ROCKY, 0.0, 5000.0, true], "frostK": ["num", ROCKY, 0.0, 5000.0, true],
	"seaLevel": ["num", ROCKY, 0.0, 1.3], "plateScale": ["num", ROCKY, 0.0, 20.0, true],
	"landRelief": ["num", ROCKY, 0.0, 20.0], "season": ["num", ROCKY, 0.0, 200.0],
}

const ORBIT_KEYS := ["around", "a", "e", "i", "nu", "testParticle"]

const TOP_KEYS := {
	"format": ["int", 1.0, 1.0], "name": ["text", 80], "blurb": ["text", 4000],
	"group": ["str"], "order": ["num", -INF, INF], "sky": ["sky"], "bodies": ["bodies"],
	"paint": ["paint"], "sceneScale": ["num", 0.0, INF, true], "bodyScale": ["num", 0.0, INF, true],
	"trueScale": ["bool"], "camRadius": ["num", OrreryCamera.MIN_REQUEST_RADIUS, OrreryCamera.MAX_REQUEST_RADIUS],
	"focus": ["str"], "lensing": ["bool"], "mesh": ["bool"], "discIntensity": ["num", 0.0, 1.0],
	"discOuter": ["num", 0.0, INF, true], "gwBoost": ["num", 0.0, INF], "timeScale": ["num", 0.0, INF, true],
	"maxStep": ["num", 0.0, INF, true], "epochJD": ["num", -INF, INF], "spawnAtRest": ["bool"],
	"surface": ["bool"], "climate": ["climate"], "massSlider": ["bool"],
}

# kind, kinds it applies to (empty: all), limits
const PAINT_KEYS := {
	"kind": ["kind", []], "body": ["str", []], "label": ["str", []], "seed": ["num", [], -INF, INF],
	"color": ["color", []], "density": ["num", [], 0.0, 1.0],
	"inner": ["num", ["ring", "belt"], 0.0, INF, true], "outer": ["num", ["ring", "belt"], 0.0, INF, true],
	"count": ["int", ["ring", "belt"], 1.0, float(MAX_PARTICLES)], "ecc": ["num", ["ring", "belt"], 0.0, 1.0],
	"incl": ["deg", ["ring", "belt"]], "tilt": ["deg", ["ring", "belt"]],
	"surfaceDensity": ["num", ["ring", "belt"], -INF, INF], "perturber": ["str", ["ring", "belt"]],
	"sizePx": ["num", ["ring", "belt"], 0.5, 16.0], "decretion": ["bool", ["ring"]],
	"radius": ["num", ["cloud"], 0.0, INF, true], "lobes": ["int", ["cloud"], 1.0, 4.0],
	"expand": ["num", ["cloud"], -INF, INF],
}

## Reads a file. `builtin` allows `group`; an uploaded file is always Custom.
## Returns { ok, preset, errors: [String], warnings: [String] }.
static func read(path: String, builtin := false) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return _result(["cannot open %s: %s" % [path, error_string(FileAccess.get_open_error())]])
	if f.get_length() > MAX_BYTES:
		return _result(["the file is larger than %d MB" % (MAX_BYTES / 1048576)])
	var text := f.get_as_text()
	f.close()
	var r := from_text(text, builtin)
	if r.ok: r.preset.file = path
	return r

static func from_text(text: String, builtin := false) -> Dictionary:
	if text.length() > MAX_BYTES: return _result(["the file is larger than %d MB" % (MAX_BYTES / 1048576)])
	var parsed := Jsonc.parse(text)
	if not parsed.error.is_empty():
		return _result(["line %d, column %d: %s" % [parsed.line, parsed.col, parsed.error]])
	return from_data(parsed.data, builtin, parsed.lines)

static func _result(errors: Array, preset = null, warnings: Array = []) -> Dictionary:
	return {"ok": errors.is_empty() and preset != null, "preset": preset, "errors": errors, "warnings": warnings}

## `lines` (path → line) makes messages point into the file.
static func from_data(data: Variant, builtin := false, lines := {}) -> Dictionary:
	var c := _Ctx.new(lines)
	if not data is Dictionary:
		c.err("", "the file must be one { … } object")
		return _result(c.errors)
	var preset := {}
	for key in data:
		if not TOP_KEYS.has(key):
			c.err(key, "unknown key")
	if data.get("format") == null: c.err("", "format is required (format: %d)" % FORMAT)
	if data.get("name") == null: c.err("", "name is required")
	if data.get("bodies") == null: c.err("", "bodies is required (it may be empty: [])")
	if not c.errors.is_empty(): return _result(c.errors)
	for key in data:
		var v: Variant = data[key]
		if v == null: continue
		var sch: Array = TOP_KEYS[key]
		match sch[0]:
			"int":
				if not _is_num(v) or float(v) != floor(float(v)) or float(v) < sch[1] or float(v) > sch[2]:
					c.err(key, "must be %d" % int(sch[1]) if sch[1] == sch[2] else "must be a whole number")
			"text":
				if not v is String or v.strip_edges().is_empty() and key == "name" or (v is String and v.length() > sch[1]):
					c.err(key, "must be text of 1 to %d characters" % sch[1])
				else: preset[key] = v
			"str":
				if not v is String or v.is_empty(): c.err(key, "must be a name")
				elif key == "group" and not builtin: c.err(key, "only built-in scenarios choose a group")
				elif key == "group" and not GROUPS.has(v): c.err(key, "must be one of %s" % ", ".join(GROUPS.keys()))
				else: preset[key] = v
			"num":
				var e := _num_error(v, sch[1], sch[2], sch.size() > 3)
				if not e.is_empty(): c.err(key, e)
				else: preset[key] = float(v)
			"bool":
				if not v is bool: c.err(key, "must be true or false")
				else: preset[key] = v
			"sky":
				var e := SkyModel.request_error(v)
				if not e.is_empty(): c.err(key, e)
				else: preset[key] = v
			"climate":
				if not v is Dictionary: c.err(key, "must be an object")
				else:
					var unknown := ClimateInputs.unknown_key(v)
					if not unknown.is_empty(): c.err("%s.%s" % [key, unknown], "unknown climate input")
					else:
						var e := ClimateInputs.input_error(v)
						if not e.is_empty(): c.err(key, e)
						else: preset[key] = v
	var specs: Array = _bodies(c, data.get("bodies"))
	if data.get("paint") != null:
		preset.paint = _paint(c, data.paint)
	if not c.errors.is_empty(): return _result(c.errors)
	for i in specs.size():
		var spec := _normalized(specs[i])
		# What the stage will check: the home world with the file's climate merged in.
		if spec.type == "world" and spec.get("home") == true and preset.get("climate"): spec.merge(preset.climate)
		var reason := Structure.input_error(spec)
		if not reason.is_empty(): c.err("bodies[%d]" % i, reason)
	if not c.errors.is_empty(): return _result(c.errors)
	var built := _place(c, specs)
	if not c.errors.is_empty(): return _result(c.errors)
	var bodies: Array = built.bodies
	_cross_checks(c, preset, data, specs, bodies)
	if not c.errors.is_empty(): return _result(c.errors)
	_defaults(preset, data, specs, bodies)
	var warnings := _warnings(preset, specs, bodies)
	preset.warnings = warnings
	var frozen: Array = specs
	preset.build = func() -> Array: return frozen.duplicate(true)
	return _result([], preset, warnings)

class _Ctx:
	var errors := []
	var lines := {}
	func _init(l: Dictionary) -> void: lines = l
	func err(path: String, msg: String) -> void:
		if errors.size() >= 20: return
		var at := path
		if lines.has(path): at = "%s (line %d)" % [path, lines[path]]
		errors.append(("%s: %s" % [at, msg]) if not at.is_empty() else msg)

static func _is_num(v: Variant) -> bool:
	return v is float or v is int

static func _num_error(v: Variant, lo: float, hi: float, lo_open := false) -> String:
	if not _is_num(v) or not is_finite(float(v)): return "must be a finite number"
	var x := float(v)
	if x < lo or x > hi or (lo_open and x == lo):
		if is_inf(hi): return ("must be above %s" if lo_open else "must be at least %s") % _n(lo)
		if is_inf(lo): return "must be at most %s" % _n(hi)
		return "must be from %s to %s" % [_n(lo), _n(hi)] + (" (not %s)" % _n(lo) if lo_open else "")
	return ""

static func _n(x: float) -> String:
	return Structure._num(x)

static func color_of(v: Variant) -> int:
	if not v is String or v.length() != 7 or not v.begins_with("#") or not v.substr(1).is_valid_hex_number(): return -1
	return v.substr(1).hex_to_int()

static func _bodies(c: _Ctx, list: Variant) -> Array:
	if not list is Array:
		c.err("bodies", "must be a list [ … ]")
		return []
	if list.size() > MAX_BODIES:
		c.err("bodies", "has %d bodies; the most a file may hold is %d" % [list.size(), MAX_BODIES])
		return []
	var out := []
	for i in list.size():
		var path := "bodies[%d]" % i
		var src: Variant = list[i]
		if not src is Dictionary:
			c.err(path, "must be an object")
			out.append({})
			continue
		out.append(_body(c, path, src))
	return out

static func _body(c: _Ctx, path: String, src: Dictionary) -> Dictionary:
	var type: Variant = src.get("type")
	if not type is String or type not in TYPES:
		c.err(path + ".type", "must be one of %s" % ", ".join(TYPES))
		return {}
	var name: Variant = src.get("name")
	if not name is String or name.strip_edges().is_empty() or name.length() > 40:
		c.err(path + ".name", "is required: text of 1 to 40 characters")
		return {}
	var spec := {}
	for key in src:
		var at := "%s.%s" % [path, key]
		if not BODY_KEYS.has(key):
			c.err(at, "unknown key")
			continue
		var sch: Array = BODY_KEYS[key]
		var types: Array = sch[1]
		if not types.is_empty() and type not in types:
			c.err(at, "does not apply to a %s" % type)
			continue
		var v: Variant = src[key]
		if v == null: continue
		match sch[0]:
			"type", "name": spec[key] = v
			"body":
				if not v is String or v.is_empty(): c.err(at, "must name a body")
				else: spec[key] = v
			"num":
				var e := _num_error(v, sch[2], sch[3], sch.size() > 4)
				if not e.is_empty(): c.err(at, e)
				else: spec[key] = float(v)
			"int":
				var e := _num_error(v, sch[2], sch[3])
				if e.is_empty() and float(v) != floor(float(v)): e = "must be a whole number"
				if not e.is_empty(): c.err(at, e)
				else: spec[key] = int(v)
			"bool":
				if not v is bool: c.err(at, "must be true or false")
				else: spec[key] = v
			"vec3":
				if not v is Array or v.size() != 3 or not v.all(func(x): return _is_num(x) and is_finite(float(x))):
					c.err(at, "must be [x, y, z], three finite numbers")
				else: spec[key] = [float(v[0]), float(v[1]), float(v[2])]
			"deg":
				var e := _num_error(v, -INF, INF)
				if not e.is_empty(): c.err(at, e)
				else: spec[key] = deg_to_rad(float(v))
			"hours":
				var e := _num_error(v, 0.0, INF, true)
				if not e.is_empty(): c.err(at, e)
				else: spec[key] = float(v) / HOURS_PER_YEAR
			"color":
				var hex := color_of(v)
				if hex < 0: c.err(at, "must be a colour written \"#rrggbb\"")
				else: spec[key] = hex
			"palette":
				if not v is String or not GiantVisual.GIANT_PALETTES.has(v):
					c.err(at, "must be one of %s" % ", ".join(GiantVisual.GIANT_PALETTES.keys()))
				else: spec[key] = v
			"composition":
				if not v is String or not Structure.ROCK_COMPOSITIONS.has(v):
					c.err(at, "must be one of %s" % ", ".join(Structure.ROCK_COMPOSITIONS.keys()))
				else: spec[key] = v
			"phase":
				if v is String:
					var ph: Dictionary = U.nz(U.find(Structure.PHASES, func(q): return q.id == v), {})
					if ph.is_empty(): c.err(at, "must be a number or one of %s" % ", ".join(Structure.PHASES.map(func(p): return p.id)))
					else: spec[key] = ph.f
				elif _is_num(v) and is_finite(float(v)): spec[key] = float(v)
				else: c.err(at, "must be a number or a phase name")
			"catalog":
				if not v is String or not Starcat.STAR_CATALOG.has(v): c.err(at, "is not a catalogue star")
				elif String(Starcat.STAR_CATALOG[v].get("type", "star")) != type:
					c.err(at, "%s is a %s, not a %s" % [v, Starcat.STAR_CATALOG[v].get("type", "star"), type])
				else: spec[key] = v
			"orbit":
				var o := _orbit(c, at, v)
				if not o.is_empty(): spec[key] = o
	if spec.has("orbit") and (spec.has("pos") or spec.has("vel")):
		c.err(path, "gives both an orbit and pos/vel; use one")
	if spec.has("catalog"):
		var base := Starcat.star_spec(spec.catalog)
		for key in spec: base[key] = spec[key]
		spec = base
	return spec

static func _orbit(c: _Ctx, at: String, v: Variant) -> Dictionary:
	if not v is Dictionary:
		c.err(at, "must be an object { around, a, … }")
		return {}
	var o := {}
	for key in v:
		if key not in ORBIT_KEYS: c.err("%s.%s" % [at, key], "unknown key")
	var around: Variant = v.get("around")
	if around is String and not around.is_empty(): o.around = [around]
	elif around is Array and not around.is_empty() and around.all(func(x): return x is String):
		o.around = around.duplicate()
		o.group = true
	else: c.err(at + ".around", "must name a body, or list the bodies whose barycentre it orbits")
	var e := _num_error(v.get("a"), 0.0, INF, true)
	if not e.is_empty(): c.err(at + ".a", "is required and " + e)
	else: o.a = float(v.a)
	o.e = 0.0
	if v.get("e") != null:
		var ee: float = float(v.e) if _is_num(v.e) else NAN
		if not is_finite(ee) or ee < 0.0 or ee >= 1.0: c.err(at + ".e", "must be at least 0 and below 1")
		else: o.e = ee
	for key in ["i", "nu"]:
		o[key] = 0.0
		if v.get(key) != null:
			var ee := _num_error(v[key], -INF, INF)
			if not ee.is_empty(): c.err("%s.%s" % [at, key], ee)
			else: o[key] = deg_to_rad(float(v[key]))
	o.test = false
	if v.get("testParticle") != null:
		if not v.testParticle is bool: c.err(at + ".testParticle", "must be true or false")
		else: o.test = v.testParticle
	return o

static func _paint(c: _Ctx, list: Variant) -> Array:
	if not list is Array:
		c.err("paint", "must be a list [ … ]")
		return []
	var out := []
	var particles := 0
	for i in list.size():
		var at := "paint[%d]" % i
		var src: Variant = list[i]
		if not src is Dictionary:
			c.err(at, "must be an object")
			continue
		var kind: Variant = src.get("kind")
		if kind not in ["ring", "belt", "cloud"]:
			c.err(at + ".kind", "must be ring, belt or cloud")
			continue
		var spec := {}
		for key in src:
			var path := "%s.%s" % [at, key]
			if not PAINT_KEYS.has(key):
				c.err(path, "unknown key")
				continue
			var sch: Array = PAINT_KEYS[key]
			if not sch[1].is_empty() and kind not in sch[1]:
				c.err(path, "does not apply to a %s" % kind)
				continue
			var v: Variant = src[key]
			if v == null: continue
			match sch[0]:
				"kind", "str":
					if not v is String or v.is_empty(): c.err(path, "must be a name")
					else: spec[key] = v
				"num":
					var e := _num_error(v, sch[2], sch[3], sch.size() > 4)
					if not e.is_empty(): c.err(path, e)
					else: spec[key] = float(v)
				"int":
					var e := _num_error(v, sch[2], sch[3])
					if e.is_empty() and float(v) != floor(float(v)): e = "must be a whole number"
					if not e.is_empty(): c.err(path, e)
					else: spec[key] = int(v)
				"deg":
					var e := _num_error(v, -INF, INF)
					if not e.is_empty(): c.err(path, e)
					else: spec[key] = deg_to_rad(float(v))
				"bool":
					if not v is bool: c.err(path, "must be true or false")
					else: spec[key] = v
				"color":
					var hex := color_of(v)
					if hex < 0: c.err(path, "must be a colour written \"#rrggbb\"")
					else: spec[key] = hex
		if kind != "cloud":
			if not spec.has("inner") or not spec.has("outer"): c.err(at, "a %s needs inner and outer" % kind)
			elif spec.inner >= spec.outer: c.err(at, "inner must be below outer")
			particles += int(spec.get("count", 11000 if kind == "belt" else 26000))
		out.append(spec)
	if particles > MAX_PARTICLES:
		c.err("paint", "asks for %d particles; the most is %d" % [particles, MAX_PARTICLES])
	return out

# Placement. A body with an orbit is placed once every body it names is placed, in file
# order among those ready, so the output keeps the file's order. The parent is the named
# bodies with everything already placed around them. A two-body orbit moves the parent to
# keep the shared barycentre fixed; a test particle leaves it, joining its mass but not its
# barycentre (as the hierarchy builders always have).
static func _place(c: _Ctx, specs: Array) -> Dictionary:
	var index := {}
	for i in specs.size():
		var nm: String = specs[i].get("name", "")
		if index.has(nm): c.err("bodies[%d].name" % i, "\"%s\" is already the name of bodies[%d]" % [nm, index[nm]])
		else: index[nm] = i
	if not c.errors.is_empty(): return {}
	var mass := []
	for s in specs:
		mass.append(float(s.get("mass", Derive.type_default(s.get("type")).mass)))
	var pos := []
	var vel := []
	for s in specs:
		pos.append(s.get("pos", [0.0, 0.0, 0.0]).duplicate())
		vel.append(s.get("vel", [0.0, 0.0, 0.0]).duplicate())
	var placed := []
	placed.resize(specs.size())
	placed.fill(false)
	var touched := {}
	for i in specs.size():
		if not specs[i].has("orbit"): placed[i] = true
		for nm in specs[i].get("orbit", {}).get("around", []):
			if not index.has(nm): c.err("bodies[%d].orbit.around" % i, "no body is named \"%s\"" % nm)
			elif index[nm] == i: c.err("bodies[%d].orbit.around" % i, "a body cannot orbit itself")
	if not c.errors.is_empty(): return {}
	var systems := {}   # sorted member names joined by \n → {mass, pos, vel}
	var satellites := []
	for i in specs.size(): satellites.append([])
	var progress := true
	while progress:
		progress = false
		for i in specs.size():
			if placed[i]: continue
			var o: Dictionary = specs[i].orbit
			var named: Array = o.around.map(func(nm): return index[nm])
			if not named.all(func(j): return placed[j]): continue
			var members := _closure(named, satellites)
			var names: Array = members.map(func(j): return specs[j].name)
			var parent := _system_of(systems, names, members, mass, pos, vel)
			var M: float = parent.mass if o.test else parent.mass + mass[i]
			var rel := Presets.kepler(M, o.a, o.e, o.i, o.nu)
			if o.test:
				pos[i] = Presets.addv(parent.pos, rel.pos)
				vel[i] = Presets.addv(parent.vel, rel.vel)
			else:
				var k_parent: float = -mass[i] / M
				var k_body: float = parent.mass / M
				pos[i] = Presets.addv(parent.pos, rel.pos, k_body)
				vel[i] = Presets.addv(parent.vel, rel.vel, k_body)
				for j in members:
					pos[j] = Presets.addv(pos[j], rel.pos, k_parent)
					vel[j] = Presets.addv(vel[j], rel.vel, k_parent)
					touched[j] = true
			for j in members: satellites[j].append(i)
			names.append(specs[i].name)
			systems[_key(names)] = {"mass": parent.mass + mass[i], "pos": parent.pos, "vel": parent.vel}
			placed[i] = true
			touched[i] = true
			progress = true
	for i in specs.size():
		if not placed[i]:
			c.err("bodies[%d].orbit.around" % i, "the orbits name each other in a loop")
			return {}
	var bodies := []
	for i in specs.size():
		var s: Dictionary = specs[i]
		s.erase("orbit")
		if touched.has(i):
			s.pos = pos[i]
			s.vel = vel[i]
		var b := Derive.new_body(i + 1, _normalized(s))
		bodies.append(b)
	return {"bodies": bodies}

static func _closure(named: Array, satellites: Array) -> Array:
	var seen := {}
	var stack := named.duplicate()
	while not stack.is_empty():
		var j: int = stack.pop_back()
		if seen.has(j): continue
		seen[j] = true
		stack.append_array(satellites[j])
	var out: Array = seen.keys()
	out.sort()
	return out

static func _key(names: Array) -> String:
	var k := names.duplicate()
	k.sort()
	return "\n".join(k)

static func _system_of(systems: Dictionary, names: Array, members: Array, mass: Array, pos: Array, vel: Array) -> Dictionary:
	if members.size() == 1:
		var j: int = members[0]
		return {"mass": mass[j], "pos": pos[j], "vel": vel[j]}
	var k := _key(names)
	if systems.has(k): return systems[k]
	var m := 0.0
	var p := [0.0, 0.0, 0.0]
	var v := [0.0, 0.0, 0.0]
	for j in members: m += mass[j]
	for j in members:
		p = Presets.addv(p, pos[j], mass[j] / m)
		v = Presets.addv(v, vel[j], mass[j] / m)
	return {"mass": m, "pos": p, "vel": v}

static func _normalized(spec: Dictionary) -> Dictionary:
	var out := spec.duplicate()
	out.type = U.nz(out.get("type"), "planet")
	out.mass = U.nz(out.get("mass"), Derive.type_default(out.type).mass)
	return out

static func _cross_checks(c: _Ctx, preset: Dictionary, data: Dictionary, specs: Array, bodies: Array) -> void:
	var names := {}
	var homes := []
	for i in specs.size():
		var s: Dictionary = specs[i]
		names[s.name] = i
		if s.get("home") == true: homes.append(i)
	if homes.size() > 1: c.err("bodies[%d].home" % homes[1], "only one body can be the home world")
	if preset.get("focus") != null and not names.has(preset.focus): c.err("focus", "no body is named \"%s\"" % preset.focus)
	for i in preset.get("paint", []).size():
		var p: Dictionary = preset.paint[i]
		for key in ["body", "perturber"]:
			if p.get(key) != null and not names.has(p[key]): c.err("paint[%d].%s" % [i, key], "no body is named \"%s\"" % p[key])
	for i in specs.size():
		var lock: Variant = specs[i].get("tidalLock")
		if lock != null and (not names.has(lock) or lock == specs[i].name):
			c.err("bodies[%d].tidalLock" % i, "must name another body (the one it keeps a face to)")
	if (preset.get("climate") != null or preset.get("surface") == true) and homes.is_empty():
		c.err("climate" if preset.get("climate") != null else "surface", "needs a home world (a world with home: true)")
	if preset.get("massSlider") == true and not specs.any(func(s): return s.type == "bh"):
		c.err("massSlider", "needs a black hole")
	if not c.errors.is_empty(): return
	for i in bodies.size():
		var b: Body = bodies[i]
		if b.vel.length() >= Physics.C: c.err("bodies[%d].vel" % i, "is at or above the speed of light")
		if b.type == "neutron" and b.mass > Structure.tov_limit(b.spin_frac):
			c.err("bodies[%d].mass" % i, "is above the TOV limit (%s M☉ at this spin): it would collapse on the first frame" % _n(Structure.tov_limit(b.spin_frac)))
		if b.type == "white-dwarf" and b.mass >= float(Structure.LIMITS.chandrasekhar):
			c.err("bodies[%d].mass" % i, "is at or above the Chandrasekhar mass: it would detonate on the first frame")
	for i in bodies.size():
		var a: Body = bodies[i]
		var ca: float = a.rs if a.type == "bh" else (a.contact_au if a.contact_au != 0.0 else a.radius)
		for j in range(i + 1, bodies.size()):
			var b: Body = bodies[j]
			var cb: float = b.rs if b.type == "bh" else (b.contact_au if b.contact_au != 0.0 else b.radius)
			if a.pos.distance_to(b.pos) <= ca + cb:
				c.err("bodies[%d]" % j, "touches %s at the start (%s AU apart, contact at %s AU): they would merge on the first frame" % [a.name, _n(a.pos.distance_to(b.pos)), _n(ca + cb)])
				if c.errors.size() >= 20: return

# Settings a file may leave out: derived from the bodies where the consumer's own default
# would frame or pace them badly.
static func _defaults(preset: Dictionary, data: Dictionary, specs: Array, bodies: Array) -> void:
	var n := bodies.size()
	var extent := 0.0
	if n >= 2:
		var m := 0.0
		var bary := DVec3.new()
		for b in bodies: m += b.mass
		for b in bodies: bary.add_scaled_in(b.pos, b.mass / m)
		for b in bodies: extent = maxf(extent, b.pos.distance_to(bary))
	if not preset.has("sceneScale"):
		preset.sceneScale = 20.0 / extent if extent > 0.0 else 2.0
	if not preset.has("camRadius"):
		var r := 2.5 * extent * float(preset.sceneScale) if extent > 0.0 else 12.0
		preset.camRadius = clampf(r, OrreryCamera.MIN_REQUEST_RADIUS, OrreryCamera.MAX_REQUEST_RADIUS)
		if n == 1 and not preset.has("focus"): preset.focus = specs[0].name
	if not preset.has("lensing") and specs.any(func(s): return s.type == "bh"): preset.lensing = true
	if not preset.has("timeScale"):
		var p_min := shortest_period(bodies)
		preset.timeScale = clampf(p_min / 10.0, 1e-6, 100.0) if is_finite(p_min) else 2.0

## The shortest two-body Kepler period among bound pairs at the start, years (INF if none).
static func shortest_period(bodies: Array) -> float:
	var p_min := INF
	for i in bodies.size():
		var a: Body = bodies[i]
		for j in range(i + 1, bodies.size()):
			var b: Body = bodies[j]
			var mu := Physics.G * (a.mass + b.mass)
			var r := a.pos.distance_to(b.pos)
			var v2 := a.vel.distance_sq_to(b.vel)
			var energy := 0.5 * v2 - mu / r
			if r <= 0.0 or energy >= 0.0: continue
			var sma := -mu / (2.0 * energy)
			p_min = minf(p_min, 2.0 * PI * sqrt(sma * sma * sma / mu))
	return p_min

## Predicted milliseconds per frame on the measured machine, and the starting sub-steps.
static func predict(preset: Dictionary, bodies: Array) -> Dictionary:
	var n := float(bodies.size())
	var h := Derive.dynamic_step(bodies, float(preset.get("maxStep", 5e-3))) if bodies.size() >= 2 else float(preset.get("maxStep", 5e-3))
	var steps := ceilf(DT_FRAME * float(preset.get("timeScale", 2.0)) / h) if is_finite(h) and h > 0.0 else INF
	var stars := float(bodies.filter(func(b): return b.type == "star").size())
	var ms: float = COST.body_ms * n + COST.star_ms * stars + COST.pair_step_ms * n * n * minf(steps, float(Derive.STEP_GUARD))
	return {"ms": ms, "steps": steps}

static func _warnings(preset: Dictionary, specs: Array, bodies: Array) -> Array:
	var out := []
	if bodies.size() > WARN_BODIES:
		out.append("%d bodies: past %d, a slower machine may run this under 10 FPS." % [bodies.size(), WARN_BODIES])
	var p := predict(preset, bodies)
	if p.ms > COST.budget_ms:
		out.append("Predicted about %d ms of work a frame (%s FPS) on a fast machine." % [int(p.ms), _n(snappedf(1000.0 / p.ms, 0.1))])
	if p.steps > Derive.STEP_GUARD:
		out.append("The closest pair needs %s sub-steps a frame, past the %d limit: time will run slower than asked." % [_n(p.steps), Derive.STEP_GUARD])
	for b in bodies:
		if b.vel.length() > 0.1 * Physics.C:
			out.append("%s moves faster than 0.1c, beyond the weak-field model." % b.name)
			break
	return out
