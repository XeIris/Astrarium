class_name MaterialDetail
extends RefCounted

# Photo-based albedo for the authored craft, procedural fallbacks and pad.
# The meshes have no common UV convention, so object-space triplanar mapping
# keeps the material scale consistent. Only High and Ultra enable the extra samples.

const TEXTURES := {
	"paint": "res://assets/materials/painted-skin.png",
	"metal": "res://assets/materials/brushed-metal.png",
	"tiles": "res://assets/materials/ceramic-tiles.png",
	"foam": "res://assets/materials/thermal-foam.png",
	"gold": "res://assets/materials/gold-insulation.png",
	"solar": "res://assets/materials/solar-cells.png",
	"concrete": "res://assets/materials/launch-concrete.png",
}

# Texture, repetitions per metre, normal strength, and whether the image
# supplies the colour outright. Neutral scans retain the authored palette.
const FAMILIES := {
	"white": ["paint", 1.5, 0.10, false], "dirty": ["paint", 1.5, 0.10, false],
	"black": ["paint", 1.5, 0.10, false], "red": ["paint", 1.5, 0.10, false],
	"paint": ["paint", 1.5, 0.10, false], "safety-yellow": ["paint", 1.5, 0.10, false],
	"steel": ["metal", 1.2, 0.13, false], "alu": ["metal", 1.2, 0.13, false],
	"nozzle": ["metal", 1.2, 0.13, false], "hot": ["metal", 1.2, 0.13, false],
	"grey": ["metal", 1.2, 0.13, false], "oxidized-copper": ["metal", 1.2, 0.13, false],
	"tiles": ["tiles", 0.6, 0.22, true],
	"foam": ["foam", 1.4, 0.25, false], "ablator": ["foam", 1.4, 0.25, false],
	"gold": ["gold", 1.4, 0.20, true],
	"solar": ["solar", 0.6, 0.04, true],
	"concrete": ["concrete", 0.18, 0.25, true],
	"darkcon": ["concrete", 0.18, 0.25, false],
	"scorch": ["concrete", 0.18, 0.25, false],
	"soot": ["concrete", 0.18, 0.20, false],
}

# The finish each family takes with the photo detail on: colour (sRGB, or -1 to
# keep it), roughness, metallic, clearcoat. Paint is a warm semi-gloss enamel;
# bare metal is metallic, but only partly, since the craft studio has no sky to
# reflect and a full metal there would render black.
const FINISH := {
	"white": [0xece9e1, 0.5, 0.04, 0.28], "dirty": [0xc4c2bd, 0.62, 0.05, 0.15],
	"paint": [-1, 0.52, 0.04, 0.25], "red": [-1, 0.52, 0.05, 0.25],
	"black": [-1, 0.48, 0.08, 0.3], "safety-yellow": [-1, 0.52, 0.04, 0.2],
	"steel": [-1, 0.3, 0.55, 0.0], "alu": [-1, 0.38, 0.5, 0.0],
	"nozzle": [-1, 0.45, 0.5, 0.0], "grey": [-1, 0.42, 0.45, 0.0],
}
## Families that weather: run-off streaks and grime, multiplied over the paint.
const WEATHER := ["white", "dirty", "paint", "black", "red", "safety-yellow", "steel", "alu"]

static var _materials: Array[WeakRef] = []
static var _grime: ImageTexture
static var _enabled := false
static var _albedo_textures := {}
static var _rough_texture: ImageTexture
static var _normal_texture: ImageTexture

static func _sample(x: int, y: int) -> float:
	# Periodic fields so seams do not show where the material repeats.
	var a := TAU * float(x) / 64.0
	var b := TAU * float(y) / 64.0
	return 0.50 + 0.22 * sin(a * 5.0 + sin(b * 3.0)) * sin(b * 7.0) \
		+ 0.14 * sin(a * 13.0 + b * 11.0) * sin(b * 17.0 - a * 9.0)

static func _ensure_textures() -> void:
	if _rough_texture != null: return
	for family in TEXTURES:
		_albedo_textures[family] = load(TEXTURES[family])
	var rough := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var normal := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var v := _sample(x, y)
			var r := clampf(0.82 + 0.18 * v, 0.0, 1.0)
			rough.set_pixel(x, y, Color(r, r, r, 1.0))
			var dx := (_sample((x + 1) % 64, y) - _sample((x + 63) % 64, y)) * 0.20
			var dy := (_sample(x, (y + 1) % 64) - _sample(x, (y + 63) % 64)) * 0.20
			var n := Vector3(-dx, -dy, 1.0).normalized()
			normal.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, 1.0))
	_rough_texture = ImageTexture.create_from_image(rough)
	_normal_texture = ImageTexture.create_from_image(normal)
	_grime = _grime_texture()

## Weathering, multiplied over paint: near 1 with darker vertical run-off streaks
## and a fine speckle. Projected triplanar, so streaks run down the side faces.
static func _grime_texture() -> ImageTexture:
	var n := FastNoiseLite.new()
	n.seed = 1969
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	var fine := FastNoiseLite.new()
	fine.seed = 7
	fine.frequency = 0.25
	var sz := 128
	var img := Image.create(sz, sz, false, Image.FORMAT_RGBA8)
	for y in sz:
		for x in sz:
			# Stretched along v: streaks, not blotches. Periodic in both axes, so it tiles.
			var a := TAU * float(x) / sz
			var b := TAU * float(y) / sz
			var streak := n.get_noise_3d(cos(a) * 9.0, sin(a) * 9.0, sin(b) * 0.65 + cos(b) * 0.65)
			var blot := n.get_noise_3d(cos(a) * 2.0 + 40.0, sin(a) * 2.0, cos(b) * 2.0 + sin(b))
			var v := 1.0 - 0.10 * maxf(streak, 0.0) - 0.05 * (blot * 0.5 + 0.5) \
				- 0.035 * absf(fine.get_noise_2d(float(x), float(y)))
			img.set_pixel(x, y, Color(v, v * 0.995, v * 0.985, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

static func register(m: StandardMaterial3D) -> void:
	if m == null: return
	# Transparent and emissive surfaces should not gain a false matte finish.
	if m.emission_enabled or m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED: return
	var family := m.resource_name.get_slice(".", 0)
	if not FAMILIES.has(family): return
	# Prune while scanning: every launch registers fresh materials, and dead refs
	# would otherwise pile up until the next quality toggle.
	for i in range(_materials.size() - 1, -1, -1):
		var r = _materials[i].get_ref()
		if r == null: _materials.remove_at(i)
		elif r == m: return
	m.set_meta("photo_base", {
		"albedo_color": m.albedo_color, "albedo_texture": m.albedo_texture,
		"roughness_texture": m.roughness_texture,
		"normal_enabled": m.normal_enabled, "normal_texture": m.normal_texture,
		"normal_scale": m.normal_scale,
		"uv1_triplanar": m.uv1_triplanar, "uv1_scale": m.uv1_scale,
		"roughness": m.roughness, "metallic": m.metallic,
	})
	_materials.append(weakref(m))
	if _enabled: _apply(m)

static func set_enabled(on: bool) -> void:
	if _enabled == on: return
	_enabled = on
	if on: _ensure_textures()
	for i in range(_materials.size() - 1, -1, -1):
		var m: StandardMaterial3D = _materials[i].get_ref()
		if m == null: _materials.remove_at(i)
		else: _apply(m)
	if not on:
		_grime = null
		_albedo_textures.clear()
		_rough_texture = null
		_normal_texture = null

static func _apply(m: StandardMaterial3D) -> void:
	if not _enabled:
		var base: Dictionary = m.get_meta("photo_base")
		m.albedo_color = base.albedo_color
		m.albedo_texture = base.albedo_texture
		m.roughness_texture = base.roughness_texture
		m.normal_enabled = base.normal_enabled
		m.normal_texture = base.normal_texture
		m.normal_scale = base.normal_scale
		m.uv1_triplanar = base.uv1_triplanar
		m.uv1_scale = base.uv1_scale
		m.roughness = base.roughness
		m.metallic = base.metallic
		m.clearcoat_enabled = false
		m.detail_enabled = false
		return
	var family := m.resource_name.get_slice(".", 0)
	var settings: Array = FAMILIES[family]
	m.albedo_texture = _albedo_textures[settings[0]]
	m.albedo_color = Color.WHITE if settings[3] else m.get_meta("photo_base").albedo_color
	m.uv1_triplanar = true
	m.uv1_scale = Vector3.ONE * settings[1]
	m.roughness_texture = _rough_texture
	m.normal_enabled = true
	m.normal_scale = settings[2]
	m.normal_texture = _normal_texture
	var fin = FINISH.get(family)
	if fin != null:
		if int(fin[0]) >= 0 and not settings[3]: m.albedo_color = Color.hex((int(fin[0]) << 8) | 0xff)
		m.roughness = fin[1]
		m.metallic = fin[2]
		m.clearcoat_enabled = float(fin[3]) > 0.0
		m.clearcoat = fin[3]
		m.clearcoat_roughness = 0.35
	if family in WEATHER:
		m.detail_enabled = true
		m.detail_blend_mode = BaseMaterial3D.BLEND_MODE_MUL
		m.detail_uv_layer = BaseMaterial3D.DETAIL_UV_2
		m.detail_albedo = _grime
		m.uv2_triplanar = true
		# One streak pattern every ~12 m.
		m.uv2_scale = Vector3.ONE * 0.085
