class_name RangerCraft
extends RefCounted

# Stations from the exhibit plan and profile traces, aft to bow. Widths are
# fractions of half-span and heights are fractions of length.
const SECTIONS := [
	[0.0, .49, -.0305, -.006, .0485, .32],
	[.10, .75, -.027, -.001, .054, .405],
	[.20, .853, -.0255, .0005, .0615, .44],
	[.31, .94, -.025, .002, .0665, .48],
	[.43, .846, -.0215, 0, .0585, .435],
	[.52, .760, -.0185, -.002, .036, .398],
	[.61, .678, -.015, -.003, .0205, .39],
	[.78, .554, -.012, -.0045, .013, .387],
	[.95, .440, -.009, -.006, .0075, .365],
	[1.0, .423, -.0075, -.006, .0055, .35],
]

# Filming miniature: the raised chines run forward from the radiator and
# separate from the foredeck at their tips. Offsets from the skin are in metres.
const CHINE_STATIONS := [
	[.082, -.32, .09, .13],
	[.10, -.31, .11, .15],
	[.20, -.25, .18, .18],
	[.31, -.22, .26, .18],
	[.43, -.19, .24, .16],
	[.52, -.19, .23, .15],
	[.61, -.22, .24, .14],
	[.78, -.20, .25, .16],
	[.865, .07, .28, .26],
	[.935, .20, .31, .29],
	[.973, .25, .31, .21],
]

# Chamfered aperture contours traced on the miniature, in local panel UVs.
const AFT_SMALL := [[.46,.26],[.51,.15],[.80,.16],[.84,.29],[.81,.66],[.72,.77],[.49,.70],[.44,.56]]
const AFT_LONG := [[.30,.27],[.44,.15],[.75,.10],[.82,.19],[.77,.73],[.66,.88],[.39,.81],[.27,.65]]
const MID_PENTAGON := [[.23,.29],[.39,.14],[.82,.17],[.91,.30],[.86,.76],[.70,.85],[.28,.78],[.17,.59]]
const MID_SLANTED := [[.28,.34],[.48,.16],[.82,.12],[.91,.23],[.87,.68],[.72,.80],[.35,.84],[.24,.69]]
const MID_SLIM := [[.42,.32],[.58,.15],[.86,.14],[.93,.24],[.88,.62],[.68,.77],[.37,.80],[.35,.66]]
const PILOT := [[.17,.23],[.32,.13],[.90,.11],[.96,.24],[.91,.85],[.81,.93],[.25,.84],[.12,.70]]
const PILOT_SLIVER := [[.14,.29],[.30,.18],[.79,.19],[.88,.29],[.85,.81],[.66,.89],[.27,.82],[.15,.70]]
const SIDE_AFT := [[.18,.37],[.26,.21],[.70,.16],[.80,.27],[.73,.71],[.59,.82],[.23,.73],[.14,.55]]
const SIDE_FORWARD := [[.26,.29],[.37,.16],[.70,.23],[.78,.37],[.73,.77],[.57,.85],[.30,.74],[.23,.57]]

const WELL_HALF_WIDTH := .48
const FLAP_WIDTH := .66

static func hull_span(spec: Dictionary) -> float:
	return float(spec.look.get("hullSpan",spec.D))

static func section(spec: Dictionary, i: int) -> Array[Vector3]:
	var s: Array = SECTIONS[i]
	var y := float(s[0]) * float(spec.L)
	var w := float(s[1]) * hull_span(spec) * .5
	var c := float(s[5]) * hull_span(spec) * .5
	var z0 := float(s[2]) * float(spec.L)
	var z1 := float(s[3]) * float(spec.L)
	var z2 := float(s[4]) * float(spec.L)
	return [Vector3(-w*.80,y,z0), Vector3(w*.80,y,z0), Vector3(w,y,z1),
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

static func _aperture(faces: Array, windows: Array, panel: Array, outline: Array, mirrored: bool, label: String) -> void:
	var hole := []
	for j in 8:
		var uv: Array = outline[posmod(3-j,8) if mirrored else j]
		hole.append(_point(panel,1.0-float(uv[0]) if mirrored else float(uv[0]),float(uv[1])))
	_frame(faces,panel,hole)
	_face(windows,hole,"glass",label)

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
			var outer := minf(chine.x+float(station[2]),hull_span(spec)*.5)
			var rise := float(station[3])
			var bevel := minf(.045,(outer-inner)*.25)
			var deck := lerpf(chine.z,crown.z,clampf((chine.x-inner)/(chine.x-crown.x),0.0,1.0))
			vertices.append_array([
				[side*inner,y,deck-.075],
				[side*outer,y,chine.z-.045],
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

static func gear_mounts(spec: Dictionary) -> Array:
	var mounts := []
	var radius := float(spec.rollout.tyreR)
	for i in 3:
		var nose := i==0
		var contact: Array = spec.gear.nose if nose else spec.gear.point
		var y := float(contact[1])
		var z := -.02 if nose else -.21
		var arm := z-float(contact[2])-radius
		var x := 0.0 if nose else -2.25 if i==1 else 2.25
		mounts.append({"at":[x,y,z],"arm":arm,"tyreOffset":.085 if nose else .15,
			"rear":y-.36,"front":y+arm+radius+.08,"halfWidth":WELL_HALF_WIDTH,
			"ceiling":.148 if nose else .04})
	return mounts

static func _belly(spec: Dictionary, faces: Array, mounts: Array) -> void:
	var rows := []
	for row: Array in SECTIONS: rows.append(float(row[0])*float(spec.L))
	for mount: Dictionary in mounts: rows.append_array([mount.rear,mount.front])
	rows.sort()
	for i in rows.size()-1:
		var y0: float=rows[i]; var y1: float=rows[i+1]
		if y1-y0<1e-6: continue
		var a:=at(spec,y0); var b:=at(spec,y1)
		var mid: float=(y0+y1)*.5
		var bays := []
		for mount: Dictionary in mounts:
			if mid>float(mount.rear) and mid<float(mount.front): bays.append(mount.at[0])
		# Constant x cuts make rectangular bays within a tapering outer edge.
		if bays.is_empty():
			_face(faces,[a[1],a[0],b[0],b[1]],"tps","belly")
			continue
		# Build each solid span directly; leave the bay intervals open.
		var endpoints := [Vector2(-INF,float(bays[0])-WELL_HALF_WIDTH)]
		if bays.size()==2:
			endpoints.append(Vector2(float(bays[0])+WELL_HALF_WIDTH,float(bays[1])-WELL_HALF_WIDTH))
		endpoints.append(Vector2(float(bays.back())+WELL_HALF_WIDTH,INF))
		for span: Vector2 in endpoints:
			var x0a:=maxf(span.x,a[0].x); var x1a:=minf(span.y,a[1].x)
			var x0b:=maxf(span.x,b[0].x); var x1b:=minf(span.y,b[1].x)
			_face(faces,[Vector3(x1a,y0,a[0].z),Vector3(x0a,y0,a[0].z),Vector3(x0b,y1,b[0].z),Vector3(x1b,y1,b[0].z)],"tps","gear_bay_edge")

static func _well_faces(spec: Dictionary, mounts: Array) -> Array:
	var faces := []
	for mount: Dictionary in mounts:
		var x0 := float(mount.at[0])-WELL_HALF_WIDTH
		var x1 := float(mount.at[0])+WELL_HALF_WIDTH
		var rear := float(mount.rear)
		var front := float(mount.front)
		var roof := float(mount.ceiling)
		_face(faces,[Vector3(x1,rear,roof),Vector3(x0,rear,roof),
			Vector3(x0,front,roof),Vector3(x1,front,roof)],"panel","gear well roof")
		var rows := [rear]
		for row: Array in SECTIONS:
			var y := float(row[0])*float(spec.L)
			if y>rear and y<front: rows.append(y)
		rows.append(front)
		for i in rows.size()-1:
			var y0: float=rows[i]
			var y1: float=rows[i+1]
			var z0:=at(spec,y0)[0].z
			var z1:=at(spec,y1)[0].z
			_face(faces,[Vector3(x0,y0,z0),Vector3(x0,y1,z1),
				Vector3(x0,y1,roof),Vector3(x0,y0,roof)],"panel","gear well wall")
			_face(faces,[Vector3(x1,y1,z1),Vector3(x1,y0,z0),
				Vector3(x1,y0,roof),Vector3(x1,y1,roof)],"panel","gear well wall")
		var z0:=at(spec,rear)[0].z
		var z1:=at(spec,front)[0].z
		_face(faces,[Vector3(x0,rear,z0),Vector3(x0,rear,roof),
			Vector3(x1,rear,roof),Vector3(x1,rear,z0)],"panel","gear well rear")
		_face(faces,[Vector3(x1,front,z1),Vector3(x1,front,roof),
			Vector3(x0,front,roof),Vector3(x0,front,z1)],"panel","gear well front")
	return faces

static func _flap_mounts(spec: Dictionary) -> Array:
	var mounts := []
	var y := .9
	var z := at(spec,y)[2].z-.16
	var count := int(spec.look.flaps)
	for i in count:
		mounts.append([(i-(count-1)*.5)*.73,y,z])
	return mounts

## Identical low-resolution skin and window apertures for Blender and fallback.
static func geometry(spec: Dictionary) -> Dictionary:
	var faces := []; var windows := []
	for i in SECTIONS.size()-1:
		var a := section(spec,i); var b := section(spec,i+1)
		for edge in 6:
			if edge==0: continue
			var j := (edge+1)%6
			var q := [a[j],a[edge],b[edge],b[j]]
			if edge==3 and i==4:
				_aperture(faces,windows,_cell(q,0,.415,0,1),PILOT,false,"windshield_port")
				_aperture(faces,windows,_cell(q,.415,.479,0,1),PILOT_SLIVER,false,"windshield_inset_port")
				_face(faces,_cell(q,.479,.521,0,1),"thermal","crown_spine")
				_aperture(faces,windows,_cell(q,.521,.585,0,1),PILOT_SLIVER,true,"windshield_inset_starboard")
				_aperture(faces,windows,_cell(q,.585,1,0,1),PILOT,true,"windshield_starboard")
			elif edge==3 and i in [2,3]:
				var profiles := [AFT_SMALL,AFT_LONG] if i==2 else [MID_PENTAGON,MID_SLANTED,MID_SLIM]
				var rows := [0.0,.37,1.0] if i==2 else [0.0,.42,.74,1.0]
				for side in 2:
					for k in profiles.size():
						var panel := _cell(q,side*.5,(side+1)*.5,rows[k],rows[k+1])
						_aperture(faces,windows,panel,profiles[k],side==1,"window_%d"%windows.size())
			elif edge in [2,4] and i in [3,4]:
				_aperture(faces,windows,_cell(q,0,1,0,.51),SIDE_AFT,edge==4,"window_%d"%windows.size())
				_aperture(faces,windows,_cell(q,0,1,.51,1),SIDE_FORWARD,edge==4,"window_%d"%windows.size())
			elif edge in [2,3,4] and i==6:
				_face(faces,_cell(q,0,1,0,.71),"thermal","foredeck aft")
				_face(faces,_cell(q,0,1,.71,.735),"tps","foredeck seam")
				_face(faces,_cell(q,0,1,.735,1),"thermal","foredeck forward")
			else:
				_face(faces,q,"tps" if edge in [1,5] else "thermal","skin_%d_%d"%[i,edge])
	var mounts := gear_mounts(spec)
	_belly(spec,faces,mounts)
	var aft:=section(spec,0)
	var center:=Vector3(0,0,.15)
	for i in aft.size():
		for j in 8:
			var a:=aft[i].lerp(aft[(i+1)%aft.size()],float(j)/8)
			var b:=aft[i].lerp(aft[(i+1)%aft.size()],float(j+1)/8)
			_face(faces,[a,b,center+(b-center).normalized()*.68,center+(a-center).normalized()*.68],"tps","aft")
	var nose := section(spec,SECTIONS.size()-1); nose.reverse()
	_face(faces,nose,"tps","nose")
	return {"faces":faces,"windows":windows,"sections":SECTIONS,"chines":_chines(spec),
		"gear":mounts,"wells":_well_faces(spec,mounts),"flaps":_flap_mounts(spec),"flapWidth":FLAP_WIDTH}

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
	for row: Dictionary in data.wells: _poly(root,row,mats.dirty)
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
	var tyre_radius := float(spec.rollout.tyreR)
	for gear: Dictionary in data.gear:
		var mount := Node3D.new(); root.add_child(mount)
		mount.position=Vector3(gear.at[0],gear.at[1],gear.at[2])
		mount.basis=Basis(Vector3.UP,Vector3.BACK,Vector3.RIGHT)
		var height := float(gear.ceiling)-mount.position.z
		EvaPod._box(root,mount.position+Vector3.BACK*height*.5,Vector3(.29,.22,height+.06),mats.steel)
		var leg := Node3D.new(); mount.add_child(leg); parts.legs.append(leg)
		var arm := float(gear.arm)
		EvaPod._box(leg,Vector3(arm*.5,0,0),Vector3(arm,.12,.12),mats.steel)
		for side in [-1,1]:
			var tyre:=CraftModel._mesh(CraftModel._cylinder(tyre_radius,tyre_radius,.14,24),mats.black)
			tyre.position=Vector3(arm,side*float(gear.tyreOffset),0)
			leg.add_child(tyre)
	for at_: Array in data.flaps:
		var mount := Node3D.new(); root.add_child(mount)
		mount.position=Vector3(at_[0],at_[1],at_[2])
		mount.basis=Basis(Vector3.UP,Vector3.BACK,Vector3.RIGHT)
		var flap := Node3D.new(); mount.add_child(flap); parts.flaps.append(flap)
		EvaPod._box(flap,Vector3(-.36,0,0),Vector3(.70,.08,FLAP_WIDTH),mats.tiles)
	return {"group":root,"parts":parts}

static func cabin(spec: Dictionary) -> Node3D:
	var root := Node3D.new()
	var m := CraftModel._mat("surveyCabin",0x555b60,.82,.03)
	for row: Dictionary in geometry(spec).faces:
		if row.name=="aft" or row.name=="nose" or row.name.begins_with("skin_") and int(row.name.get_slice("_",1))>5: continue
		_poly(root,row,m,-.06)
	var dark := CraftModel._mat("surveySeat",0x23292c,.83,.02)
	for x in [-.72,.72]:
		EvaPod._box(root,Vector3(x,7.2,.025),Vector3(.65,.65,.14),dark)
		EvaPod._box(root,Vector3(x,6.96,.39),Vector3(.65,.15,.79),dark)
	EvaPod._box(root,Vector3(0,8.67,.23),Vector3(3.0,.3,.4),dark)
	return root
