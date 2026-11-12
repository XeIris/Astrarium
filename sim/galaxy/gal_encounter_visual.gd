class_name GalEncounterVisual
extends RefCounted

# An encounter drawn (GalEncounter): its disc and bulge stars as soft blobs, each sharing its
# population's light, through shaders/galaxy/galaxy_encounter.gdshader. Haloes are dark and
# not drawn; there is no dust. docs/physics/galaxies.md#encounters-phase-4.

const SHADER := preload("res://shaders/galaxy/galaxy_encounter.gdshader")
const TEX_W := 1024
const TAGS := 8

var group: Node3D
var stars: MeshInstance3D
var mat: ShaderMaterial
var tex: ImageTexture = null
var count := 0
var exposure := 1.0
var show_stars := true
var last_gain := 0.0

## `lights`: per tag (GalModels.vdm_lights) [visible light per channel of all its stars (Color,
## Sun-luminances), blob σ (kpc)]; `tags` each star's tag.
func _init(tags: PackedByteArray, lights: Array) -> void:
	count = tags.size()
	group = Node3D.new()
	group.name = "Encounter"
	var counts := PackedInt32Array()
	counts.resize(TAGS)
	for t in tags: counts[t] += 1
	var l := PackedVector4Array()
	var sig := PackedFloat32Array()
	for t in TAGS:
		var c: Color = lights[t][0] if t < lights.size() else Color(0, 0, 0)
		var k := 1.0 / maxf(float(counts[t]), 1.0)
		l.append(Vector4(c.r * k, c.g * k, c.b * k, 0.0))
		sig.append(float(lights[t][1]) if t < lights.size() else 1.0)
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("uLight", l)
	mat.set_shader_parameter("uSigma", sig)
	mat.set_shader_parameter("uTexW", TEX_W)
	# Four vertices per star, all at the origin: the shader places them.
	var verts := PackedVector3Array()
	verts.resize(4 * count)
	var idx := PackedInt32Array()
	idx.resize(6 * count)
	for i in count:
		var b := 4 * i
		idx[6 * i] = b
		idx[6 * i + 1] = b + 1
		idx[6 * i + 2] = b + 2
		idx[6 * i + 3] = b
		idx[6 * i + 4] = b + 2
		idx[6 * i + 5] = b + 3
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	stars = MeshInstance3D.new()
	stars.name = "Stars"
	stars.mesh = mesh
	stars.material_override = mat
	stars.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	stars.custom_aabb = AABB(Vector3(-1e6, -1e6, -1e6), Vector3(2e6, 2e6, 2e6))
	group.add_child(stars)

## Per frame: the stars' texture from a float32 (x, y, z, tag) block, the camera, the gain.
func update(bytes: PackedByteArray, cam: DVec3, fov_rad: float, viewport_h: float, star_gain: float) -> void:
	var pix := 2.0 * tan(fov_rad * 0.5) / maxf(viewport_h, 1.0)
	var gain := GalaxyVisual.K * star_gain * exposure
	last_gain = gain
	if bytes.size() == 16 * count and count > 0:
		var rows := int(ceil(float(count) / float(TEX_W)))
		var b := bytes
		if b.size() < 16 * TEX_W * rows:
			b = b.duplicate()
			b.resize(16 * TEX_W * rows)
		var img := Image.create_from_data(TEX_W, rows, false, Image.FORMAT_RGBAF, b)
		if tex == null or tex.get_height() != rows:
			tex = ImageTexture.create_from_image(img)
			mat.set_shader_parameter("uPos", tex)
		else:
			tex.update(img)
	stars.visible = show_stars and tex != null
	mat.set_shader_parameter("uCam", Vector3(cam.x, cam.y, cam.z))
	mat.set_shader_parameter("uGain", gain / (4.0 * PI))
	mat.set_shader_parameter("uPix", pix)

func dispose() -> void:
	if is_instance_valid(group): group.queue_free()
	group = null
