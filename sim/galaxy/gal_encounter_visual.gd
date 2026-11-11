class_name GalEncounterVisual
extends RefCounted

# An encounter drawn (GalEncounter): each galaxy's disc stars as soft blobs sharing its disc's
# light, through shaders/galaxy/galaxy_encounter.gdshader, and its bulge as the glow of a
# bulge-only GalaxyVisual riding its centre. No dust. docs/physics/galaxies.md#encounters.

const SHADER := preload("res://shaders/galaxy/galaxy_encounter.gdshader")
const TEX_W := 1024

var group: Node3D
var enc: GalEncounter
var stars: MeshInstance3D
var mat: ShaderMaterial
var tex: ImageTexture = null
## Per galaxy: a bulge glow or null.
var bulges: Array = []
var exposure := 1.0
var show_stars := true
var show_glow := true
var last_gain := 0.0

## `lights`: per galaxy [disc visible light per channel (Color, Sun-luminances, all stars
## together), blob σ (kpc), bulge model or {}].
func _init(e: GalEncounter, lights: Array) -> void:
	enc = e
	group = Node3D.new()
	group.name = "Encounter"
	var l := PackedVector4Array()
	var sig := PackedFloat32Array()
	var counts := PackedInt32Array()
	counts.resize(4)
	for i in e.n: counts[e.owner[i]] += 1
	for g in 4:
		if g < lights.size():
			var c: Color = lights[g][0]
			var k := 1.0 / maxf(float(counts[g]), 1.0)
			l.append(Vector4(c.r * k, c.g * k, c.b * k, 0.0))
			sig.append(float(lights[g][1]))
		else:
			l.append(Vector4.ZERO)
			sig.append(1.0)
	mat = ShaderMaterial.new()
	mat.shader = SHADER
	mat.set_shader_parameter("uLight", l)
	mat.set_shader_parameter("uSigma", sig)
	mat.set_shader_parameter("uTexW", TEX_W)
	# Four vertices per star, all at the origin: the shader places them.
	var verts := PackedVector3Array()
	verts.resize(4 * e.n)
	var idx := PackedInt32Array()
	idx.resize(6 * e.n)
	for i in e.n:
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
	for g in lights.size():
		var bm: Dictionary = lights[g][2]
		if bm.is_empty():
			bulges.append(null)
			continue
		var v := GalaxyVisual.new(bm)
		v.adapt_enabled = false
		v.show_stars = false
		group.add_child(v.group)
		bulges.append(v)

## Per frame: the stars' texture from the kernel's float32 block, the camera, the gain.
func update(cam: DVec3, t_myr: float, fov_rad: float, viewport_h: float, star_gain: float) -> void:
	var pix := 2.0 * tan(fov_rad * 0.5) / maxf(viewport_h, 1.0)
	var gain := GalaxyVisual.K * star_gain * exposure
	last_gain = gain
	if enc.draw_bytes.size() == 16 * enc.n and enc.n > 0:
		var rows := int(ceil(float(enc.n) / float(TEX_W)))
		var bytes := enc.draw_bytes
		if bytes.size() < 16 * TEX_W * rows:
			bytes = bytes.duplicate()
			bytes.resize(16 * TEX_W * rows)
		var img := Image.create_from_data(TEX_W, rows, false, Image.FORMAT_RGBAF, bytes)
		if tex == null or tex.get_height() != rows:
			tex = ImageTexture.create_from_image(img)
			mat.set_shader_parameter("uPos", tex)
		else:
			tex.update(img)
	stars.visible = show_stars and tex != null
	mat.set_shader_parameter("uCam", Vector3(cam.x, cam.y, cam.z))
	mat.set_shader_parameter("uGain", gain / (4.0 * PI))
	mat.set_shader_parameter("uPix", pix)
	for g in bulges.size():
		var v: GalaxyVisual = bulges[g]
		if v == null: continue
		var cd := DVec3.new(enc.orbits.pos[3 * g], enc.orbits.pos[3 * g + 1], enc.orbits.pos[3 * g + 2])
		v.group.position = cd.rel_v3(cam)
		v.exposure = exposure
		v.adaptation = 1.0
		v.show_glow = show_glow
		var cl := DVec3.new(cam.x - cd.x, cam.y - cd.y, cam.z - cd.z)
		v.update(cl, t_myr, null, 0.0, fov_rad, viewport_h, star_gain)

func dispose() -> void:
	for v in bulges:
		if v != null: v.dispose()
	if is_instance_valid(group): group.queue_free()
	group = null
