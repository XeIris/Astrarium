class_name Flash
extends RefCounted

# Event sprites: compact light or expanding ejecta. The orchestrator owns their
# camera-relative placement and steps their lifetime; the shader draws the gradient.

const SPRITE_SHADER := preload("res://shaders/bodies/flash_sprite.gdshader")
const NO_CULL_AABB := AABB(Vector3(-1.0e6, -1.0e6, -1.0e6), Vector3(2.0e6, 2.0e6, 2.0e6))

var node: MeshInstance3D
var mat: ShaderMaterial
var life := 1.0
var size: float
var decay: float
var grow: float
var shell: bool

static var _quad: QuadMesh = null

## Up to three [position, Color] gradient stops, in raw channels (U.raw).
## The returned node's scale sets its size.
static func make_sprite(stops: Array) -> MeshInstance3D:
	if _quad == null:
		_quad = QuadMesh.new()
		_quad.size = Vector2(1, 1)
	var m := ShaderMaterial.new()
	m.shader = SPRITE_SHADER
	var st := stops.duplicate()
	while st.size() < 3:
		st.append(st[st.size() - 1])
	m.set_shader_parameter("uStopPos", Vector3(st[0][0], st[1][0], st[2][0]))
	for i in 3:
		var c: Color = st[i][1]
		m.set_shader_parameter("uStop%d" % i, Vector4(c.r, c.g, c.b, c.a))
	m.set_shader_parameter("uOpacity", 1.0)
	var n := MeshInstance3D.new()
	n.mesh = _quad
	n.material_override = m
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.custom_aabb = NO_CULL_AABB
	return n

## The caller owns node placement and must call step() to advance the lifetime.
static func create(color_hex: int, p_size: float, p_decay: float = 0.8, p_grow: float = 2.0, kind: String = "flash") -> Flash:
	var f := Flash.new()
	f.node = make_sprite([
		[0.0, U.raw(0xffffff, 1.0)],
		[0.3, U.raw(color_hex, 204.0 / 255.0)],
		[1.0, U.raw(color_hex, 0.0)],
	])
	f.node.name = "Flash"
	f.mat = f.node.material_override
	f.size = p_size
	f.decay = p_decay
	f.grow = p_grow
	f.shell = kind == "shell"
	f.node.scale = Vector3.ONE * p_size
	return f

## Returns false after burnout; the caller must kill() and release the flash.
func step(dt: float) -> bool:
	life -= dt * decay
	if life <= 0.0:
		return false
	var p := 1.0 - life                                   # 0 → 1 over the life
	# t^½ for ejecta (decelerating), linear for light (nothing is moving)
	var k := 1.0 + grow * (sqrt(p) if shell else p)
	node.scale = Vector3.ONE * (size * k)
	# Spreading the same emission over k× the radius costs a factor k in
	# surface brightness; light that is not going anywhere just fades.
	mat.set_shader_parameter("uOpacity", pow(life, 1.5) / k if shell else life)
	return true

func kill() -> void:
	if is_instance_valid(node):
		node.queue_free()
