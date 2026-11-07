class_name CraftInterior
extends RefCounted

# An instance belongs to one live craft; no interior resource is preloaded/cached.
const LAYER := 1 << 18
var group: Node3D
var authored := false
var shade: Node3D

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
	if group == null: group = _fallback(st.spec)
	group.name = "FlightInterior"
	CraftAssets._prepare(group)
	_prepare(group)
	st.group.add_child(group)
	shade = st.group.find_child("window_shade", true, false) as Node3D
	if shade != null: shade.visible = false
	var fixtures := group.find_children("interior_light_*", "Node3D", true, false)
	var positions: Array[Vector3] = []
	var inverse := CraftModel.world_xform(group).affine_inverse()
	for fixture: Node3D in fixtures:
		positions.append(inverse * CraftModel.world_xform(fixture).origin)
	if positions.is_empty(): positions = [Vector3(-0.55, 1.5, 0.0), Vector3(0.55, 1.5, 0.0)]
	for pos in positions:
		var light := OmniLight3D.new()
		light.position = pos
		light.light_color = Color(1.0, 0.13, 0.07)
		light.light_energy = 0.28
		light.omni_range = 1.65
		light.light_cull_mask = LAYER
		group.add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0, 1.45, 0.1)
	fill.light_color = Color(0.67, 0.80, 1.0)
	fill.light_energy = 0.16
	fill.omni_range = 1.5
	fill.light_cull_mask = LAYER
	group.add_child(fill)

func dispose() -> void:
	if is_instance_valid(shade): shade.visible = true
	shade = null
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
