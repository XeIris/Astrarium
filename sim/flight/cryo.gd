class_name Cryo
extends RefCounted

# Cryogenic tanks on the pad: rime where a tank wall holds liquid oxygen,
# hydrogen or methane, and boil-off vented as cold vapour that sinks and drifts.
# The frost is a lit, partly transparent shell over the tank's band of the stage;
# it sheds through the first seconds of flight. Kerosene stages carry it only on
# their oxygen tank; foam-insulated tanks (the Shuttle's) carry none.

const FROST_SHADER := preload("res://shaders/flight/frost.gdshader")

## Tank bands as fractions of the stage's length, and how heavily they frost:
## propellant → [[y0, y1, strength], ...]. Kerosene stages carry LOX on top; a
## hydrolox stage's insulated hydrogen tank frosts little, its LOX tank more.
const BANDS := {
	"RP-1/LOX": [[0.52, 0.88, 1.0]],
	"LH2/LOX": [[0.06, 0.34, 0.55], [0.4, 0.86, 0.25]],
	"CH4/LOX": [[0.1, 0.48, 0.9], [0.52, 0.9, 1.0]],
}

## Seconds for the rime to shed once the vehicle is moving.
const SHED_S := 18.0

var shells: Array[MeshInstance3D] = []
var materials: Array[ShaderMaterial] = []
## Vent outlets, carried on their stages: [{node, out: Vector3 (stage frame)}].
var vents: Array = []
var _acc := 0.0

static func build(craft: CraftModel.Craft) -> Cryo:
	var c := Cryo.new()
	for st in craft.stages:
		var spec: Dictionary = st.spec
		var eng = spec.get("engine")
		var look = spec.get("look")
		if eng == null or look != null and (look.get("mount") != null or look.get("skin") == "foam"):
			continue
		var bands = BANDS.get(str(eng.get("prop", "")))
		if bands == null: continue
		var L := float(spec.L)
		var r := float(spec.D) * 0.5 * 1.012
		var seed := float(hash(str(spec.key)) % 97)
		for b in bands:
			var y0: float = L * float(b[0])
			var y1: float = L * float(b[1])
			var mesh := CylinderMesh.new()
			mesh.top_radius = r
			mesh.bottom_radius = r
			mesh.height = y1 - y0
			mesh.radial_segments = 48
			mesh.rings = 4
			mesh.cap_top = false
			mesh.cap_bottom = false
			var m := ShaderMaterial.new()
			m.shader = FROST_SHADER
			m.set_shader_parameter("uStrength", float(b[2]))
			m.set_shader_parameter("uSeed", seed + y0)
			var mi := MeshInstance3D.new()
			mi.name = "frost"
			mi.mesh = mesh
			mi.material_override = m
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position.y = (y0 + y1) * 0.5
			st.group.add_child(mi)
			c.shells.append(mi)
			c.materials.append(m)
			# A vent pair at the top of each stage's upper tank, either side.
			if b != bands[-1]: continue
			for side in [0.0, PI]:
				var a: float = seed * 0.37 + side
				var out := Vector3(cos(a), 0.0, sin(a))
				var n := Node3D.new()
				n.name = "vent"
				n.position = out * r + Vector3(0.0, y1 - L * 0.02, 0.0)
				st.group.add_child(n)
				c.vents.append({"node": n, "out": out, "rate": float(b[2])})
	return c

## `fuelled`: still on the pad with full tanks; `moving_s`: seconds since release.
## Vapour goes into `smoke` (its group frame) while fuelled.
func update(dt: float, fuelled: bool, moving_s: float, smoke: Plume.SmokeColumn) -> void:
	var amount := 1.0 if fuelled else exp(-moving_s / SHED_S * 3.0)
	for i in shells.size():
		shells[i].visible = amount > 0.01 and shells[i].get_parent().visible
		materials[i].set_shader_parameter("uAmount", amount)
	if not fuelled or dt <= 0.0 or vents.is_empty(): return
	# Boil-off: a thin stream, many faint puffs a second from each outlet.
	_acc += dt * 6.0 * vents.size()
	var to_smoke := smoke.group.global_transform.affine_inverse()
	while _acc >= 1.0:
		_acc -= 1.0
		var v: Dictionary = vents[randi() % vents.size()]
		var node: Node3D = v.node
		if not node.is_visible_in_tree(): continue
		var xf := node.global_transform
		var p: Vector3 = to_smoke * xf.origin
		var out: Vector3 = (to_smoke.basis * (xf.basis * v.out)).normalized()
		smoke.emit_vent(p, out * (2.0 + randf() * 2.0), 0.7 + randf() * 0.7, 0.16 * float(v.rate) + 0.06)
