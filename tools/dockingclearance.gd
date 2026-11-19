extends RefCounted

# Check both sets of triangle edges. A narrow adapter can pass through a single
# large hull face without any of that face's edges crossing the adapter.
var surfaces := {}
var visitor: Array[MeshInstance3D] = []
var carrier: Array[MeshInstance3D] = []

func _init(active: Node3D, target: Node3D) -> void:
	for item: MeshInstance3D in active.find_children("*","MeshInstance3D",true,false):
		if item.mesh and item.is_visible_in_tree(): visitor.append(item)
	for item: MeshInstance3D in target.find_children("*","MeshInstance3D",true,false):
		if item.mesh and item.is_visible_in_tree(): carrier.append(item)

func geometry(mesh: Mesh) -> Dictionary:
	if not surfaces.has(mesh):
		var faces := mesh.get_faces()
		var tree := TriangleMesh.new()
		if not faces.is_empty(): tree.create_from_faces(faces)
		surfaces[mesh] = {"faces":faces,"tree":tree}
	return surfaces[mesh]

func crosses(source: Mesh, target: Mesh, relative: Transform3D) -> bool:
	var faces: PackedVector3Array = geometry(source).faces
	var tree: TriangleMesh = geometry(target).tree
	var bounds := target.get_aabb()
	for i in range(0,faces.size(),3):
		var a := relative * faces[i]
		var b := relative * faces[i+1]
		var c := relative * faces[i+2]
		if not bounds.intersects(AABB(a,Vector3.ZERO).expand(b).expand(c)): continue
		if tree.intersect_segment(a,b) or tree.intersect_segment(b,c) or tree.intersect_segment(c,a): return true
	return false

func interference() -> String:
	for fixed in carrier:
		var inverse := fixed.global_transform.affine_inverse()
		var bounds := fixed.get_aabb()
		for ship in visitor:
			var relative := inverse * ship.global_transform
			if not bounds.intersects(relative * ship.get_aabb()): continue
			if crosses(ship.mesh,fixed.mesh,relative) or crosses(fixed.mesh,ship.mesh,relative.affine_inverse()):
				return "%s intersects %s" % [ship.get_path(),fixed.get_path()]
	return ""
