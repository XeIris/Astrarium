class_name CraftInterior
extends RefCounted

# An instance belongs to one live craft; no interior resource is preloaded/cached.
const LAYER := 1 << 18
var group: Node3D
var authored := false
var shade: Node3D
var reveal: Node3D
var reveal_was_visible := true
var window_sun: DirectionalLight3D
var shadow_view: SubViewport
var previous_atlas_size := 0

func set_enabled(enabled: bool, craft, vehicle: Dictionary) -> void:
	if not enabled:
		dispose()
		return
	if is_instance_valid(group): return
	var spec: Dictionary = vehicle.get("interior", {})
	if spec.is_empty(): return
	var st = craft.stage(str(spec.stage))
	if st == null or not st.group.visible: return
	var path := str(spec.get("asset", ""))
	if craft.authored and ResourceLoader.exists(path):
		var scene = load(path)
		if scene is PackedScene:
			group = scene.instantiate()
			authored = true
	if group == null: group = RangerCraft.cabin(st.spec) if st.spec.get("look", {}).get("ranger", false) else _fallback(st.spec)
	group.name = "FlightInterior"
	CraftAssets._prepare(group)
	_prepare(group)
	st.group.add_child(group)
	shade = st.group.find_child("window_shade", true, false) as Node3D
	if shade != null: shade.visible = false
	if authored:
		# The cabin carries its own painted reveal, fitted over the exterior's ribbed rubber.
		reveal = st.group.find_child("window_reveal", true, false) as Node3D
		if reveal != null:
			reveal_was_visible = reveal.visible
			reveal.visible = false
	var fixtures := group.find_children("interior_light_*", "Node3D", true, false)
	var inverse := CraftModel.world_xform(group).affine_inverse()
	var lighting: Dictionary = spec.get("lighting", {})
	var keys: Array = lighting.get("keys", [])
	if not fixtures.is_empty():
		shadow_view = group.get_viewport() as SubViewport
		if shadow_view != null:
			previous_atlas_size = shadow_view.positional_shadow_atlas_size
			shadow_view.positional_shadow_atlas_size = maxi(previous_atlas_size, 2048)
	for fixture: Node3D in fixtures:
		var is_key := keys.has(str(fixture.name).trim_prefix("interior_light_").to_int())
		var color_: Array = lighting.keyColor if is_key else lighting.color
		var light := OmniLight3D.new()
		light.position = inverse * CraftModel.world_xform(fixture).origin
		light.light_color = Color(color_[0], color_[1], color_[2])
		light.light_energy = float(lighting.keyEnergy if is_key else lighting.energy)
		light.omni_range = float(lighting.range)
		light.light_size = float(lighting.sourceRadius)
		light.light_cull_mask = LAYER
		# Millimetre-scale bezels and canopy seals cast onto the cabin alone.
		light.shadow_enabled = is_key
		light.shadow_caster_mask = LAYER
		light.shadow_bias = 0.018
		light.shadow_normal_bias = 0.12
		group.add_child(light)
	if fixtures.is_empty():
		# Procedural cabins have no authored ceiling sockets.
		for side in [-1.0, 1.0]:
			var lamp := OmniLight3D.new()
			var center: Array = spec.eye
			lamp.position = Vector3(center[0] + side * 0.55, center[1], center[2])
			lamp.light_color = Color(1.0, 0.85, 0.72)
			lamp.light_energy = 0.3
			lamp.omni_range = float(lighting.range)
			lamp.light_cull_mask = LAYER
			group.add_child(lamp)
	var fill := OmniLight3D.new()
	var fill_at: Array = lighting.get("fill", [0.0, 1.45, 0.1])
	fill.position = Vector3(fill_at[0], fill_at[1], fill_at[2])
	fill.light_color = Color(0.67, 0.80, 1.0)
	fill.light_energy = float(lighting.get("fillEnergy", 0.16))
	fill.omni_range = float(lighting.get("fillRange", 1.5))
	fill.light_cull_mask = LAYER
	group.add_child(fill)

## The near shadow frustum resolves the canopy bars at the seated eye.
func light_windows(primary: DirectionalLight3D, secondary: DirectionalLight3D) -> void:
	if not authored: return
	if window_sun == null:
		window_sun = DirectionalLight3D.new()
		window_sun.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
		window_sun.light_cull_mask = LAYER
		window_sun.shadow_caster_mask = LAYER
		window_sun.shadow_enabled = true
		window_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		window_sun.directional_shadow_max_distance = 10.0
		window_sun.shadow_bias = 0.015
		window_sun.shadow_normal_bias = 0.12
		group.add_child(window_sun)
	var star := secondary if secondary.visible and secondary.light_energy > primary.light_energy else primary
	window_sun.global_basis = star.global_basis
	window_sun.light_color = star.light_color
	window_sun.light_energy = star.light_energy
	window_sun.visible = star.visible and star.light_energy > 0.0

func dispose() -> void:
	window_sun = null
	if is_instance_valid(shadow_view):
		shadow_view.positional_shadow_atlas_size = previous_atlas_size
	shadow_view = null
	if is_instance_valid(shade): shade.visible = true
	shade = null
	if is_instance_valid(reveal): reveal.visible = reveal_was_visible
	reveal = null
	if is_instance_valid(group):
		group.get_parent().remove_child(group)
		group.queue_free()
	group = null
	authored = false

static func _prepare(node: Node) -> void:
	if node is MeshInstance3D:
		(node as MeshInstance3D).layers = LAYER
	for child in node.get_children(): _prepare(child)

static func _fallback(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var s := float(spec.D)/2.06
	var mat := CraftModel._mat("podInteriorFallback",0x422725,.85,.02)
	for side in [-1.0,1.0]:
		EvaPod._box(root,Vector3(side*.76,.95,0)*s,Vector3(.06,1.05,1.1)*s,mat)
	EvaPod._box(root,Vector3(0,.28,0)*s,Vector3(1.1,.06,1.0)*s,mat)
	EvaPod._box(root,Vector3(0,1.05,-.70)*s,Vector3(.8,1.25,.06)*s,mat)
	var black := CraftModel._mat("podInteriorSeat",0x242328,.8,.02)
	EvaPod._box(root,Vector3(0,.57,-.26)*s,Vector3(.47,.15,.49)*s,black)
	EvaPod._box(root,Vector3(0,.96,-.49)*s,Vector3(.47,.70,.14)*s,black)
	EvaPod._box(root,Vector3(0,.85,.64)*s,Vector3(.72,.25,.06)*s,black)
	for x in [-.18,.18]:
		EvaPod._box(root,Vector3(x,.92,.60)*s,Vector3(.25,.12,.01)*s,CraftModel._mat("podFallbackDisplay",0x68c3f4,.4,.01,0x68c3f4,1.0))
	return root
