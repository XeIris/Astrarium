class_name PlanetElevation
extends RefCounted

# The measured height of a mapped world, a quarter-degree grid built by tools/build_planet_relief.py
# (sources and terms in THIRD_PARTY.md). Metres above sea level on Earth, the areoid on Mars and the
# 1737.4 km sphere on the Moon. Loaded on the main thread; a loaded grid is never written, so a
# worker may read it. Held only while a showcase is on. docs/physics/surface.md#the-pin.

const DIR := "res://assets/planet-relief/"
const WORLDS := {
	"Earth": {"file": "earth.elev", "source": "ETOPO 2022", "how": "mean"},
	"Mars": {"file": "mars.elev", "source": "MOLA", "how": "median"},
	"Moon": {"file": "moon.elev", "source": "LOLA", "how": "median"},
}

var width := 0
var height := 0
var source := ""
## "mean" or "median": what a cell holds of the samples inside it.
var how := ""
var _data := PackedByteArray()

static var _cache := {}

## The grid for `body_name`, or null when the world has none or its file can't be read.
static func of(body_name: String) -> PlanetElevation:
	if not WORLDS.has(body_name): return null
	if not _cache.has(body_name):
		_cache[body_name] = _load(WORLDS[body_name])
	return _cache[body_name]

static func release() -> void:
	_cache.clear()

static func _load(world: Dictionary) -> PlanetElevation:
	var f := FileAccess.open(DIR + str(world.file), FileAccess.READ)
	if f == null:
		push_warning("PlanetElevation: %s could not be opened" % world.file)
		return null
	var bytes := f.get_buffer(f.get_length())
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "ASEL":
		push_warning("PlanetElevation: %s is not an elevation grid" % world.file)
		return null
	var e := PlanetElevation.new()
	e.width = bytes.decode_s32(4)
	e.height = bytes.decode_s32(8)
	if e.width < 2 or e.height < 2 or bytes.size() != 12 + 2 * e.width * e.height:
		push_warning("PlanetElevation: %s has the wrong size" % world.file)
		return null
	e._data = bytes.slice(12)
	e.source = world.source
	e.how = world.how
	return e

## Width of a cell, rad of arc.
func cell_rad() -> float:
	return PI / height

## Metres, bilinear between cell centres, at a latitude and longitude in radians (east positive).
func at(lat_r: float, lon_r: float) -> float:
	var fy := (PI * 0.5 - lat_r) / PI * height - 0.5
	var fx := fposmod(lon_r + PI, TAU) / TAU * width - 0.5
	fy = clampf(fy, 0.0, height - 1.0)
	var j0 := mini(int(fy), height - 2)
	var ty := fy - j0
	var i0 := int(floor(fx))
	var tx := fx - i0
	var i1 := posmod(i0 + 1, width)
	i0 = posmod(i0, width)
	return lerpf(lerpf(_cell(i0, j0), _cell(i1, j0), tx), lerpf(_cell(i0, j0 + 1), _cell(i1, j0 + 1), tx), ty)

func _cell(i: int, j: int) -> float:
	return float(_data.decode_s16(2 * (j * width + i)))
