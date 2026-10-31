class_name BrightStars
extends RefCounted

# The real sky of a Solar System scene: the Yale Bright Star Catalogue to V ≈ 6.5
# (assets/sky/bsc5.bin, tools/build_starcat.py) and Gaia DR3 from G = 6.5 to 8
# (assets/sky/gaia_g8.bin, tools/build_gaia.py; ESA/Gaia/DPAC, CC BY-SA 3.0 IGO).
# Each star at its catalogue direction, its V on the sky's flux scale and its colour
# from B−V. The procedural sky keeps everything fainter (catalogue_tiers). Absent
# BSC5, nothing is drawn and the procedural sky stays whole.

const DATA := "res://assets/sky/bsc5.bin"
const DATA_FAINT := "res://assets/sky/gaia_g8.bin"
const SHADER := preload("res://shaders/sky/catalogue_stars.gdshader")
# The quad's Gaussian core and halo integrate to this many pixels² at unit gain.
const PROFILE_PX2 := 3.27

var node: MultiMeshInstance3D
var material: ShaderMaterial
var count := 0

static func available() -> bool:
	return FileAccess.file_exists(DATA)

## The procedural sky's one-magnitude tiers the catalogues replace: through V ≈ 6
## with BSC5, all six (to the V ≈ 8 floor) with Gaia as well.
static func catalogue_tiers() -> int:
	return SkyModel.CATALOGUE_TIERS + (2 if FileAccess.file_exists(DATA_FAINT) else 0)

## B−V to Teff (Ballesteros 2012, EPL 97, 34008), for a blackbody colour.
static func bv_teff(bv: float) -> float:
	var b := clampf(bv, -0.4, 2.0)
	return 4600.0 * (1.0 / (0.92 * b + 1.7) + 1.0 / (0.92 * b + 0.62))

func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = SHADER
	material.render_priority = 2
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	var q := QuadMesh.new()
	q.size = Vector2(1, 1)
	mm.mesh = q
	var stars: Array = []
	for path in [DATA, DATA_FAINT]:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null: continue
		while f.get_position() + 16 <= f.get_length():
			stars.append([f.get_float(), f.get_float(), f.get_float(), f.get_float()])
	count = stars.size()
	mm.instance_count = count
	for i in count:
		var s: Array = stars[i]
		var d := SkyModel.radec_to_scene(s[0], s[1]).to_v3()
		var flux := SkyModel.STAR_FLUX * pow(10.0, -0.4 * (float(s[2]) - SkyModel.STAR_FLUX_MAG))
		var bv: float = s[3] if is_finite(float(s[3])) else 0.6
		mm.set_instance_transform(i, Transform3D())
		mm.set_instance_color(i, Stellar.blackbody_color(bv_teff(bv)))
		mm.set_instance_custom_data(i, Color(d.x, d.y, d.z, flux))
	node = MultiMeshInstance3D.new()
	node.name = "BrightStars"
	node.multimesh = mm
	node.material_override = material
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))

## Per frame: the viewport (px), the vertical field of view and the band's star gain.
func update(fov_rad: float, viewport: Vector2, gain: float) -> void:
	var pix := 2.0 * tan(fov_rad * 0.5) / maxf(viewport.y, 1.0)
	material.set_shader_parameter("uPixSr", pix * pix)
	material.set_shader_parameter("uViewport", viewport)
	material.set_shader_parameter("uGain", gain / PROFILE_PX2)

func dispose() -> void:
	if is_instance_valid(node): node.queue_free()
