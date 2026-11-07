class_name EvaPod
extends RefCounted

# Compact procedural fallback and shared manipulator kinematics. Metres, +Z window.
static func pose(arms: Array, extension: float) -> void:
	var t := clampf(extension, 0.0, 1.0)
	for i in arms.size():
		var joint: Node3D = arms[i]
		match i % 4:
			0: joint.rotation.x = t * deg_to_rad(68.0)
			1: joint.rotation.x = t * deg_to_rad(18.0)
			2: joint.rotation.z = t * deg_to_rad(18.0)
			3: joint.rotation.z = -t * deg_to_rad(18.0)

static func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := CraftModel._mesh(CraftModel._box(size.x, size.y, size.z), mat)
	mi.position = pos
	parent.add_child(mi)
	return mi

static func _ball(parent: Node3D, pos: Vector3, radius: float, scale_: Vector3, mat: Material) -> void:
	var mi := CraftModel._mesh(CraftModel._sphere(radius, 48, 32), mat)
	mi.position = pos
	mi.scale = scale_
	parent.add_child(mi)

static func build(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var g := Node3D.new()
	var s := float(spec.D) / 2.06
	var white := CraftModel._mat("podWhite", 0xe2e0da, 0.46, 0.04)
	var black := CraftModel._mat("podSeal", 0x18191a, 0.75, 0.04)
	# A latitude/longitude patch leaves a real aperture, so interior mode can see out.
	var verts := PackedVector3Array()
	var idx := PackedInt32Array()
	for j in range(49):
		var lat := PI * j / 48.0
		for i in range(97):
			var a := TAU * i / 96.0
			verts.append(Vector3(sin(lat) * sin(a), cos(lat), sin(lat) * cos(a)) * (1.03 * s) + Vector3(0, 1.03*s, 0))
	for j in 48:
		for i in 96:
			var k := j*97+i
			var center := (verts[k]+verts[k+1]+verts[k+97]+verts[k+98])/4.0/s
			if center.z > 0.0 and pow(center.x/.45,2)+pow((center.y-1.42)/.54,2) < 1.15: continue
			idx.append_array(PackedInt32Array([k,k+97,k+1,k+1,k+97,k+98]))
	var normals := PackedVector3Array()
	for v in verts: normals.append((v-Vector3(0,1.03*s,0)).normalized())
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=verts
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_INDEX]=idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var hull := MeshInstance3D.new()
	hull.mesh=mesh
	hull.material_override=white
	g.add_child(hull)
	var shade := Node3D.new()
	shade.name = "window_shade"
	g.add_child(shade)
	_ball(shade,Vector3(0,1.42,.38)*s,1.0,Vector3(.33,.385,.01)*s,black)
	_box(g,Vector3(0,.51,.02)*s,Vector3(1.70,.82,1.22)*s,white)
	_box(g,Vector3(0,.42,.74)*s,Vector3(1.2,.49,.12)*s,white)
	for side in [-1.0,1.0]:
		_ball(g,Vector3(side*1.05,1.03,-.13)*s,1.0,Vector3(.30,.61,.61)*s,white)
		for y in [.38,.91]:
			_ball(g,Vector3(side*.72,y,.79)*s,.098*s,Vector3(1,1,.18),CraftModel._mat("podLamp",0xdce7ee,.4,.03,0xdce7ee,3.0))
		var shoulder := Node3D.new()
		shoulder.position=Vector3(side*.67,.64,.97)*s
		g.add_child(shoulder)
		parts.arms.append(shoulder)
		_ball(shoulder,Vector3.ZERO,.104*s,Vector3(.7,1,1),white)
		for x in [-.047,.047]: _box(shoulder,Vector3(x,.18,0)*s,Vector3(.05,.36,.05)*s,white)
		var elbow := Node3D.new()
		elbow.position.y=.36*s
		shoulder.add_child(elbow)
		parts.arms.append(elbow)
		_ball(elbow,Vector3.ZERO,.079*s,Vector3(1,1,1),white)
		for x in [-.047,.047]: _box(elbow,Vector3(x,.18,0)*s,Vector3(.044,.36,.044)*s,white)
		for sign_ in [-1.0,1.0]:
			var jaw := Node3D.new()
			jaw.position=Vector3(sign_*.046,.40,0)*s
			elbow.add_child(jaw)
			parts.arms.append(jaw)
			_box(jaw,Vector3(sign_*.035,.07,0)*s,Vector3(.035,.14,.035)*s,white)
			_box(jaw,Vector3(sign_*.015,.15,0)*s,Vector3(.06,.025,.035)*s,black)
	var pivot := Node3D.new()
	g.add_child(pivot)
	parts.gimbals.append(pivot)
	var bell := CraftModel._mesh(CraftModel._cylinder(.025*s,.09*s,.18*s,32),CraftModel.M.nozzle)
	bell.position.y=.09*s
	pivot.add_child(bell)
	return {"group":g,"parts":parts}
