class_name Flash
extends RefCounted

# ============================================================================
# FLASH SPRITES — the two things a violent event can look like.
# (blackhole_sim.js spawnFlash / killFlash and the flash loop in animate().)
#
# `flash` (the default) is a compact glow that grows a little and fades: the
# right stand-in for light, where nothing is actually moving outward — a
# ringdown burst, a horizon forming, a disc brightening as it swallows something.
#
# `shell` is the right stand-in for MATTER, and everything the sim calls a
# supernova throws matter. Two things change. The ejecta expand a long way —
# as t^½ rather than linearly, because they run out fast and then decelerate
# against what is around them — and, because the sprite spreads the same
# emission over that growing disc, brightness falls as size⁻¹ on top of the
# fade. The net effect is a wash that thins out instead of a dot that dims:
# what was left of a Type Ia at 90% of its life used to be a small, still
# clearly visible blue-white ball sitting exactly where the star had been,
# which reads as "the star is still there" — the opposite of what the toast
# says happened to it.
#
# USE (the orchestrator):
#   var f := Flash.create(0xffffff, size, 0.55)          # or kind = "shell"
#   pipe.world_root.add_child(f.node)                    # placed each frame at
#   flashes.append([f, wpos_dvec3])                      #   wpos.rel_v3(cam_pos)
#   … each frame: if not f.step(dt): f.kill()            # and drop it
#
# The web's CanvasTexture — which had to be disposed with the sprite or every
# merger leaked a pair — is gone: the gradient is evaluated in
# shaders/bodies/flash_sprite.gdshader, so kill() only frees the node.
# ============================================================================

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

## A THREE.Sprite with a radial-gradient CanvasTexture: `stops` is up to three
## [position, Color] pairs whose colours are RAW (U.raw — canvas pixels are
## never colour-managed). The node's scale is the sprite's size.
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

## spawnFlash(worldPos, color, size, decay = 0.8, { grow = 2, kind = 'flash' }).
## The caller places `node` (it has no position of its own to keep).
static func create(color_hex: int, p_size: float, p_decay: float = 0.8, p_grow: float = 2.0, kind: String = "flash") -> Flash:
	var f := Flash.new()
	# rg.addColorStop(0, '#ffffff'); (0.3, hex + 'cc'); (1, hex + '00')
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

## Advance one frame. Returns false once the flash has burnt out — the caller
## then kill()s it and drops it.
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
