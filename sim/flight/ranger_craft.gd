class_name RangerCraft
extends RefCounted

# Reference-judged cross sections, aft to nose: length fraction, half-span
# fraction, belly, chine and crown heights, crown half-width fraction. Heights
# scale with length; the catalogue owns overall dimensions and flight datums.
const SECTIONS := [
	[0.0, .52, -.039, -.006, .065, .34],
	[.10, .82, -.039, .014, .092, .49],
	[.20, 1.0, -.038, .021, .103, .53],
	[.31, .92, -.035, .021, .106, .49],
	[.43, .83, -.031, .017, .095, .46],
	[.52, .75, -.027, .014, .068, .43],
	[.61, .69, -.023, .011, .025, .45],
	[.78, .63, -.017, .006, .018, .49],
	[.95, .60, -.012, .001, .011, .52],
	[1.0, .55, -.009, -.004, .004, .48],
]

# Filming miniature: the raised chines run forward from the radiator and
# separate from the foredeck at their tips. Offsets from the skin are in metres.
const CHINE_STATIONS := [
	[.082, -.36, .01, .31],
	[.10, -.35, .04, .37],
	[.20, -.16, .0, .48],
	[.31, -.14, .12, .46],
	[.43, -.13, .18, .42],
	[.52, -.13, .21, .40],
	[.61, -.26, .22, .39],
	[.78, -.21, .27, .38],
	[.865, .09, .33, .43],
	[.935, .22, .35, .40],
	[.973, .29, .35, .29],
]

static func section(spec: Dictionary, i: int) -> Array[Vector3]:
	var s: Array = SECTIONS[i]
	var y := float(s[0]) * float(spec.L)
	var w := float(s[1]) * float(spec.D) * .5
	var c := float(s[5]) * float(spec.D) * .5
	var z0 := float(s[2]) * float(spec.L)
	var z1 := float(s[3]) * float(spec.L)
	var z2 := float(s[4]) * float(spec.L)
	return [Vector3(-w*.84,y,z0), Vector3(w*.84,y,z0), Vector3(w,y,z1),
		Vector3(c,y,z2), Vector3(-c,y,z2), Vector3(-w,y,z1)]

static func _point(q: Array, u: float, v: float) -> Vector3:
	return (q[0] as Vector3).lerp(q[1],u).lerp((q[3] as Vector3).lerp(q[2],u),v)

static func _cell(q: Array, u0: float, u1: float, v0: float, v1: float) -> Array:
	return [_point(q,u0,v0),_point(q,u1,v0),_point(q,u1,v1),_point(q,u0,v1)]

static func _face(out: Array, p: Array, mat: String, name_: String) -> void:
	var distinct := []
	for v: Vector3 in p:
		if distinct.is_empty() or v.distance_to(distinct.back())>1e-7: distinct.append(v)
	if distinct[0].distance_to(distinct.back())<1e-7: distinct.pop_back()
	if distinct.size()<3: return
	out.append({"vertices": distinct.map(func(v: Vector3): return [v.x,v.y,v.z]), "material": mat, "name": name_})

static func _hole(q: Array, u0: float, u1: float, v0: float, v1: float, skew:=0.0) -> Array:
	var cu := (u1-u0)*.13; var cv := (v1-v0)*.13
	var corners:=[Vector2(u0,v0+cv),Vector2(u0+cu,v0),Vector2(u1-cu,v0),Vector2(u1,v0+cv),
		Vector2(u1,v1-cv),Vector2(u1-cu,v1),Vector2(u0+cu,v1),Vector2(u0,v1-cv)]
	return corners.map(func(uv: Vector2) -> Vector3: return _point(q,uv.x+skew*(uv.y-.5),uv.y))

static func _frame(faces: Array, panel: Array, hole: Array) -> void:
	var outside := [panel[0],panel[0],panel[1],panel[1],panel[2],panel[2],panel[3],panel[3]]
	for n in 8: _face(faces,[outside[n],outside[(n+1)%8],hole[(n+1)%8],hole[n]],"thermal","window_frame")

static func at(spec: Dictionary, y: float) -> Array[Vector3]:
	for i in SECTIONS.size()-1:
		var a := section(spec,i); var b := section(spec,i+1)
		if y<=b[0].y:
			var t := clampf((y-a[0].y)/(b[0].y-a[0].y),0,1)
			var out: Array[Vector3]=[]
			for j in 6: out.append(a[j].lerp(b[j],t))
			return out
	return section(spec,SECTIONS.size()-1)

static func _chines(spec: Dictionary) -> Array:
	var chines := []
	for side: int in [-1,1]:
		var vertices := []
		var faces := [[0,1,2,3,4]]
		for station: Array in CHINE_STATIONS:
			var y := float(station[0])*float(spec.L)
			var hull := at(spec,y)
			var chine := hull[2]
			var crown := hull[3]
			var inner := chine.x+float(station[1])
			var outer := minf(chine.x+float(station[2]),float(spec.D)*.5)
			var rise := float(station[3])
			var bevel := minf(.045,(outer-inner)*.25)
			var deck := lerpf(chine.z,crown.z,clampf((chine.x-inner)/(chine.x-crown.x),0.0,1.0))
			vertices.append_array([
				[side*inner,y,deck-.10],
				[side*outer,y,chine.z-.075],
				[side*outer,y,chine.z+rise*.42],
				[side*(outer-bevel),y,chine.z+rise],
				[side*(inner+bevel),y,maxf(deck+.035,chine.z+rise*.27)],
			])
		for i in CHINE_STATIONS.size()-1:
			for j in 5:
				var a := i*5+j
				var b := i*5+(j+1)%5
				faces.append([b,a,a+5,b+5])
		var last := vertices.size()-1
		faces.append([last,last-1,last-2,last-3,last-4])
		if side<0:
			for face: Array in faces: face.reverse()
		chines.append({"name":"inspection_chine_port" if side<0 else "inspection_chine_starboard",
			"vertices":vertices,"faces":faces})
	return chines

# The gear folds forward into three real openings, not through an opaque belly.
static func _belly(spec: Dictionary, faces: Array) -> void:
	var rows := [0.0,3.35,5.05,13.45,15.15,float(spec.L)]
	for row: Array in SECTIONS: rows.append(float(row[0])*float(spec.L))
	rows.sort()
	for i in rows.size()-1:
		var y0: float=rows[i]; var y1: float=rows[i+1]
		if y1-y0<1e-6: continue
		var a:=at(spec,y0); var b:=at(spec,y1)
		var mid: float=(y0+y1)*.5
		var bays: Array = [-2.8,2.8] if mid>3.35 and mid<5.05 else [0.0] if mid>13.45 and mid<15.15 else []
		# Constant x cuts make rectangular bays within a tapering outer edge.
		if bays.is_empty():
			_face(faces,[a[1],a[0],b[0],b[1]],"tps","belly")
			continue
		# Build each solid span directly; leave the bay intervals open.
		var endpoints := [Vector2(-INF, float(bays[0])-.48)]
		if bays.size()==2: endpoints.append(Vector2(float(bays[0])+.48,float(bays[1])-.48))
		endpoints.append(Vector2(float(bays.back())+.48,INF))
		for span: Vector2 in endpoints:
			var x0a:=maxf(span.x,a[0].x); var x1a:=minf(span.y,a[1].x)
			var x0b:=maxf(span.x,b[0].x); var x1b:=minf(span.y,b[1].x)
			_face(faces,[Vector3(x1a,y0,a[0].z),Vector3(x0a,y0,a[0].z),Vector3(x0b,y1,b[0].z),Vector3(x1b,y1,b[0].z)],"tps","gear_bay_edge")

## Identical low-resolution skin and window apertures for Blender and fallback.
static func geometry(spec: Dictionary) -> Dictionary:
	var faces := []; var windows := []
	for i in SECTIONS.size()-1:
		var a := section(spec,i); var b := section(spec,i+1)
		for edge in 6:
			if edge==0: continue
			var j := (edge+1)%6
			var q := [a[j],a[edge],b[edge],b[j]]
			var cells := []
			if edge==3 and i in [2,3,4]:
				for ends: Vector2 in [Vector2(0,.20),Vector2(.20,.46),Vector2(.46,.54),Vector2(.54,.80),Vector2(.80,1)]: cells.append([ends.x,ends.y,.0,1.0])
			elif edge in [2,4] and i in [2,3,4]: cells.append([.0,1.0,.0,1.0])
			elif edge==3 and i==5:
				for k in 4: cells.append([k*.25,(k+1)*.25,.0,1.0])
			if cells.is_empty():
				_face(faces,q,"tps" if edge in [1,5] else "thermal","skin_%d_%d"%[i,edge])
			else:
				for k in cells.size():
					var c: Array = cells[k]
					var panel := _cell(q,c[0],c[1],c[2],c[3])
					if edge==3 and i in [2,3,4] and k==2:
						_face(faces,panel,"thermal","crown_spine"); continue
					var margin := .30 if i==2 else .22 if i==3 else .08 if i==4 else .16
					var skew:=(-.18 if k<2 else .18) if edge==3 else .10
					var hole := _hole(panel,.15,.85,margin,1.0-margin,skew)
					_frame(faces,panel,hole)
					_face(windows,hole,"glass","window_%d"%windows.size())
	_belly(spec,faces)
	var aft:=section(spec,0)
	var center:=Vector3(0,0,.15)
	for i in aft.size():
		for j in 8:
			var a:=aft[i].lerp(aft[(i+1)%aft.size()],float(j)/8)
			var b:=aft[i].lerp(aft[(i+1)%aft.size()],float(j+1)/8)
			_face(faces,[a,b,center+(b-center).normalized()*.68,center+(a-center).normalized()*.68],"tps","aft")
	var nose := section(spec,SECTIONS.size()-1); nose.reverse()
	_face(faces,nose,"tps","nose")
	return {"faces":faces,"windows":windows,"sections":SECTIONS,"chines":_chines(spec)}

static func _append_polygon(g: CraftModel.Geo, vertices: Array, inset: float) -> void:
	var ps := PackedVector3Array()
	for p: Array in vertices: ps.append(Vector3(p[0],p[1],p[2]))
	var normal := (ps[1]-ps[0]).cross(ps[2]-ps[0]).normalized()
	var first := g.pos.size()
	for p in ps:
		g.pos.append(p+normal*inset); g.nrm.append(normal)
	for i in range(1,ps.size()-1):
		g.idx.append_array(PackedInt32Array([first,first+i,first+i+1]))

static func _poly(parent: Node3D, row: Dictionary, mat: Material, inset := 0.0) -> void:
	var g := CraftModel.Geo.new()
	_append_polygon(g,row.vertices,inset)
	parent.add_child(CraftModel._mesh(g,mat))

static func build(spec: Dictionary, parts: Dictionary) -> Dictionary:
	var root := Node3D.new()
	var mats := CraftModel.craft_materials()
	var data := geometry(spec)
	for row: Dictionary in data.faces: _poly(root,row,mats.tiles if row.material=="tps" else mats.white)
	for chine: Dictionary in data.chines:
		var surface := CraftModel.Geo.new()
		for face: Array in chine.faces:
			_append_polygon(surface,face.map(func(i: int): return chine.vertices[i]),0.0)
		var mesh := CraftModel._mesh(surface,mats.tiles)
		mesh.name=chine.name
		root.add_child(mesh)
	var shade := Node3D.new(); shade.name="window_shade"; root.add_child(shade)
	for row: Dictionary in data.windows: _poly(shade,row,mats.glass)
	var socket:=CraftModel._mesh(CraftModel._lathe(PackedVector2Array([
		Vector2(.68,.008),Vector2(.66,.11),Vector2(.49,.15),Vector2(.47,.27),Vector2(0,.27)]),40),mats.black)
	socket.position.z=.15;root.add_child(socket)
	var flange:=CraftModel._mesh(CraftModel._torus(.575,.043,8,40),mats.steel)
	flange.position=Vector3(0,.055,.15);flange.rotation.x=PI*.5;root.add_child(flange)
	for side in [-1,1]:
		var pivot := Node3D.new(); pivot.name="gimbal_ranger_%d"%parts.gimbals.size()
		pivot.position=Vector3(side*1.45,0,0); root.add_child(pivot); parts.gimbals.append(pivot)
		EvaPod._box(pivot,Vector3(0,.23,0),Vector3(.72,.46,.6),mats.nozzle)
	for i in 3:
		var mount := Node3D.new(); root.add_child(mount)
		mount.position=Vector3(0 if i==0 else (-2.8 if i==1 else 2.8),13.8 if i==0 else 3.7,-.47)
		mount.basis=Basis(Vector3.UP,Vector3.BACK,Vector3.RIGHT)
		var leg := Node3D.new(); mount.add_child(leg); parts.legs.append(leg)
		EvaPod._box(leg,Vector3(.5,0,0),Vector3(1.0,.13,.13),mats.steel)
		EvaPod._box(leg,Vector3(.98,0,0),Vector3(.64,.18,.64),mats.black)
	for i in 7:
		var mount := Node3D.new(); root.add_child(mount)
		mount.position=Vector3((i-3)*.95,.9,.1)
		mount.basis=Basis(Vector3.UP,Vector3.BACK,Vector3.RIGHT)
		var flap := Node3D.new(); mount.add_child(flap); parts.flaps.append(flap)
		EvaPod._box(flap,Vector3(-.36,0,0),Vector3(.70,.08,.85),mats.tiles)
	return {"group":root,"parts":parts}

static func cabin(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var m := CraftModel._mat("surveyCabin",0x555b60,.82,.03)
	for row: Dictionary in geometry(spec).faces:
		if row.name=="aft" or row.name=="nose" or row.name.begins_with("skin_") and int(row.name.get_slice("_",1))>5: continue
		_poly(root,row,m,-.06)
	var dark := CraftModel._mat("surveySeat",0x23292c,.83,.02)
	for x in [-.72,.72]:
		EvaPod._box(root,Vector3(x,7.2,.03),Vector3(.65,.65,.18),dark)
		EvaPod._box(root,Vector3(x,6.96,.48),Vector3(.65,.15,1.0),dark)
	EvaPod._box(root,Vector3(0,8.9,.4),Vector3(3.0,.3,.5),dark)
	return root
