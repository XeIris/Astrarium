class_name Prominence
extends RefCounted

# Plasma on the field (loop arcades, flux ropes, hedgerow prominences) as volumes
# marched by shaders/bodies/prom_volume.gdshader: one box per structure, its density
# in field-aligned coordinates. This file derives each structure's geometry from the
# star visual's parameters and bounds the box with it, so the shader and the box agree.
# Shared contract: shaders/AGENTS.md; physics: docs/physics/stellar-surfaces.md.

## Field geometries (uKind): loops across the neutral line, a flux rope along it, and a
## quiescent hedgerow curtain.
const ARCADE := 0
const ROPE := 1
const HEDGEROW := 2

## Line opacity per stellar radius at unit density, for cool (10⁴ K) material: a rope or
## curtain core a few hundredths of a radius thick is then several optical depths
## through, as prominences are in H-α and He II.
const KAPPA_COOL := 60.0

const VOLUME_SHADER := preload("res://shaders/bodies/prom_volume.gdshader")

static var _box: BoxMesh = null
static var _noise: ImageTexture3D = null
static var _count := 0

## A unit box; the shader stretches it over each structure's bounds.
static func box() -> BoxMesh:
	if _box == null:
		_box = BoxMesh.new()
		_box.size = Vector3.ONE
	return _box

## Tiling Perlin noise, four features a tile, for the plasma's sheets and knots. Built
## once, synchronously (it is small), so the first frame has it; never freed.
static func plasma_noise() -> ImageTexture3D:
	if _noise != null:
		return _noise
	var n := FastNoiseLite.new()
	n.seed = 7177
	n.noise_type = FastNoiseLite.TYPE_PERLIN
	n.frequency = 1.0 / 16.0
	n.fractal_type = FastNoiseLite.FRACTAL_NONE
	var size := 64
	var imgs := n.get_seamless_image_3d(size, size, size, false, 0.1, true)
	_noise = ImageTexture3D.new()
	_noise.create(Image.FORMAT_L8, size, size, size, false, imgs)
	return _noise

## One structure. Orient the group with +Y the local vertical and +Z the bipole axis
## (+X the neutral line), then drive it with set_params(). `cool` / `hot` are linear.
static func create_arcade(cool: Color, hot: Color) -> Arcade:
	return Arcade.new(cool, hot)

## The curved region a flat-coordinate box (x, h, z in stellar radii) covers, in the
## arcade's frame: points dir·R(1 + h) − (0, R, 0) with dir ∥ (x, 1, z).
static func frame_bounds(R: float, x: float, z: float, h: float) -> AABB:
	var top := R * (1.0 + h) * 1.02
	var px := top * x / sqrt(1.0 + x * x)
	var pz := top * z / sqrt(1.0 + z * z)
	var lo := Vector3(-px, R * (1.0 / sqrt(1.0 + x * x + z * z) - 1.0) - 0.002 * R, -pz)
	var hi := Vector3(px, R * h * 1.02 + 0.002 * R, pz)
	return AABB(lo, hi - lo)

class Arcade:
	extends RefCounted
	var group: Node3D
	var mesh: MeshInstance3D
	var mat: ShaderMaterial
	## uTime, accumulated here rather than read back from the material.
	var time := 0.0
	var absorbs := true

	func _init(cool: Color, hot: Color) -> void:
		mat = ShaderMaterial.new()
		mat.shader = Prominence.VOLUME_SHADER
		mat.set_shader_parameter("uCool", Vector3(cool.r, cool.g, cool.b))
		mat.set_shader_parameter("uHot", Vector3(hot.r, hot.g, hot.b))
		mat.set_shader_parameter("uNoise", Prominence.plasma_noise())
		# A different stretch of the noise for every structure, deterministically.
		Prominence._count += 1
		mat.set_shader_parameter("uSeed", fmod(float(Prominence._count) * 0.6180339887, 1.0) * 37.0)
		mesh = MeshInstance3D.new()
		mesh.mesh = Prominence.box()
		mesh.material_override = mat
		mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		group = Node3D.new()
		group.add_child(mesh)
		group.visible = false

	## Hot coronal loops do not absorb against the disc; only cool prominence
	## material does (a filament).
	func set_absorbs(on: bool) -> void:
		absorbs = on

	## p = { R, span, len, height, shear, twist, erupt, width, amp, plasmaT, dt },
	## optionally apex (0 feet-bright … 1 top-bright), glow (visible-light gain), kind
	## (ARCADE, ROPE, HEDGEROW), flow (loop lengths per second) and opacity (0..1 of
	## KAPPA_COOL; by default cool ropes and curtains absorb and arcades do not).
	## Lengths are in stellar radii; `width` is a strand's thickness.
	func set_params(p: Dictionary) -> void:
		time += float(p.dt)
		var R: float = p.R
		var kind := int(p.get("kind", Prominence.ARCADE))
		var e: float = p.erupt
		var span: float = p.span
		var geo := Vector4.ZERO
		var shear_z := 0.0
		var bx := 0.0; var bz := 0.0; var bh := 0.0
		match kind:
			Prominence.ROPE:
				# The rope rises and stretches faster than it widens.
				var Lh: float = 0.5 * float(p.len) * (1.0 + 0.8 * e)
				var H: float = float(p.height) * (0.45 + 3.2 * e * e + 0.8 * e)
				var A: float = span * 0.42 * (1.0 + 1.8 * e)
				var writhe: float = e * 0.7 * Lh
				shear_z = float(p.shear) * span
				geo = Vector4(Lh, H, A, writhe)
				bx = Lh + 2.4 * A
				bz = shear_z + writhe + 2.4 * A
				bh = H + 2.4 * A
			Prominence.HEDGEROW:
				var Lh: float = 0.5 * float(p.len)
				geo = Vector4(Lh, span * 0.8, p.height, span * 0.6)
				bx = Lh
				bz = span * 0.6 + 2.2 * span * 0.8
				bh = float(p.height) * 1.6 * 1.15
			_:
				var H: float = float(p.height) * 1.3
				var S: float = float(p.shear) * span
				geo = Vector4(p.len, span, H, S)
				bx = float(p.len) + absf(S)
				bz = span * 1.05
				bh = H * 1.05
		var cool := 1.0 if kind != Prominence.ARCADE else 0.0
		var kappa := Prominence.KAPPA_COOL * float(p.get("opacity", cool)) if absorbs else 0.0
		var bounds := Prominence.frame_bounds(R, bx, bz, bh)
		mat.set_shader_parameter("uBoxMin", bounds.position)
		mat.set_shader_parameter("uBoxMax", bounds.end)
		mesh.custom_aabb = bounds
		mat.set_shader_parameter("uR", R)
		mat.set_shader_parameter("uKind", float(kind))
		mat.set_shader_parameter("uGeo", geo)
		mat.set_shader_parameter("uGeo2", Vector4(0.1 / maxf(float(p.width), 1e-4),
			0.5 + float(p.twist), shear_z, 0.35))
		mat.set_shader_parameter("uErupt", e)
		mat.set_shader_parameter("uAmp", p.amp)
		mat.set_shader_parameter("uPlasmaT", p.plasmaT)
		mat.set_shader_parameter("uApex", p.get("apex", 0.0))
		mat.set_shader_parameter("uGlow", p.get("glow", 1.0))
		mat.set_shader_parameter("uFlow", p.get("flow", 0.35))
		mat.set_shader_parameter("uKappa", kappa)
		mat.set_shader_parameter("uCooled", p.get("cooled", 0.0))
		mat.set_shader_parameter("uTime", time)

	func dispose() -> void:
		if is_instance_valid(group):
			group.queue_free()
