class_name LanderCraft
extends RefCounted

# Judged sections of the cargo shuttle's faceted central cabin, aft to bow.
# Length and beam remain catalogue dimensions; the two deep side pods are separate
# closed skins with load-bearing bridges into the central body.
const SECTIONS := [
	[0.0,.30,-.09,.015,.055,.23],
	[.31,.36,-.09,.015,.070,.27],
	[.55,.56,-.09,.040,.100,.42],
	[.72,.67,-.08,.025,.086,.50],
	[.94,.64,-.06,.005,.016,.55],
	[1.0,.59,-.05,.0,.010,.50],
]

static func section(spec: Dictionary,row: Array,offset:=0.0) -> Array[Vector3]:
	var y:=float(row[0])*float(spec.L)
	var w:=float(row[1])*float(spec.D)*.5;var crown:=float(row[5])*float(spec.D)*.5
	var z0:=float(row[2])*float(spec.L);var z1:=float(row[3])*float(spec.L);var z2:=float(row[4])*float(spec.L)
	return [Vector3(offset-w*.84,y,z0),Vector3(offset+w*.84,y,z0),Vector3(offset+w,y,z1),
		Vector3(offset+crown,y,z2),Vector3(offset-crown,y,z2),Vector3(offset-w,y,z1)]

static func geometry(spec: Dictionary) -> Dictionary:
	var faces:=[];var windows:=[]
	for i in SECTIONS.size()-1:
		var a:=section(spec,SECTIONS[i]);var b:=section(spec,SECTIONS[i+1])
		for edge in 6:
			var j: int=(edge+1)%6
			var q: Array=[a[j],a[edge],b[edge],b[j]]
			if i in [1,2,3] and edge in [2,3,4]:
				var columns:=4 if edge==3 else 1
				for col in columns:
					var panel:=RangerCraft._cell(q,float(col)/columns,float(col+1)/columns,0,1)
					var hole:=RangerCraft._hole(panel,.14,.86,.17,.83)
					RangerCraft._frame(faces,panel,hole)
					RangerCraft._face(windows,hole,"glass","window_%d"%windows.size())
			else:RangerCraft._face(faces,q,"tps" if edge==0 else "thermal","cabin skin")
	RangerCraft._face(faces,section(spec,SECTIONS[0]),"tps","aft closure")
	var bow:=section(spec,SECTIONS.back());bow.reverse()
	RangerCraft._face(faces,bow,"thermal","bow closure")
	for side in [-1,1]:
		var rows: Array=[
			[.02,.19,-.12,.015,.045,.16],
			[.12,.21,-.18,.024,.066,.16],
			[.25,.20,-.18,.023,.064,.15],
			[.34,.15,-.13,.020,.051,.13],
			[.46,.15,-.12,.021,.051,.13],
			[.54,.20,-.16,.027,.070,.16],
			[.63,.21,-.16,.023,.065,.16],
			[.73,.15,-.09,.014,.035,.12],
		]
		var offset: float=side*float(spec.D)*.395
		for i in rows.size()-1:
			var a:=section(spec,rows[i],offset);var b:=section(spec,rows[i+1],offset)
			for edge in 6:
				var j: int=(edge+1)%6
				var lower := edge in [0,1,5]
				RangerCraft._face(faces,[a[j],a[edge],b[edge],b[j]],"tps" if lower else "thermal","cargo pod skin")
		RangerCraft._face(faces,section(spec,rows[0],offset),"panel","pod aft")
		var front:=section(spec,rows.back(),offset);front.reverse()
		RangerCraft._face(faces,front,"thermal","pod front")
	return {"faces":faces,"windows":windows}

static func engines(spec: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3]=[]
	for side in [-1,1]:
		for i in 3:out.append(Vector3(side*float(spec.D)*.395+(i-1)*float(spec.L)*.05,0.0,-float(spec.L)*.035))
	return out

static func dock(spec: Dictionary) -> Dictionary:
	var fraction:=.20
	var a: Array=SECTIONS[0];var b: Array=SECTIONS[1]
	var slope: float=(float(b[4])-float(a[4]))/(float(b[0])-float(a[0]))
	var height: float=float(a[4])+slope*(fraction-float(a[0]))
	return {"at":[0.0,fraction*float(spec.L),height*float(spec.L)+.04],
		"normal":[0.0,-slope,1.0],"radius":1.02,"handrails":[.12,.28]}

static func build(spec: Dictionary,parts: Dictionary) -> Dictionary:
	var root:=Node3D.new();var mats:=CraftModel.craft_materials();var data:=geometry(spec)
	for row: Dictionary in data.faces+data.windows:
		RangerCraft._poly(root,row,mats.glass if row.material=="glass" else mats.tiles if row.material=="tps" else mats.white)
	for side in [-1,1]:
		EvaPod._box(root,Vector3(side*float(spec.D)*.27,float(spec.L)*.44,0),Vector3(float(spec.D)*.30,float(spec.L)*.20,float(spec.L)*.045),mats.white)
	var port:=dock(spec)
	var collar:=CraftModel._mesh(CraftModel._torus(float(port.radius),.12,10,40),mats.steel)
	collar.position=Vector3(port.at[0],port.at[1],port.at[2])
	var normal:=Vector3(port.normal[0],port.normal[1],port.normal[2]).normalized()
	collar.quaternion=Quaternion(Vector3.UP,normal)
	root.add_child(collar)
	for at: Vector3 in engines(spec):
		var pivot:=Node3D.new();root.add_child(pivot);pivot.position=at;parts.gimbals.append(pivot)
		var bell:=CraftModel._mesh(CraftModel._cylinder(.25,.44,.45,24),mats.nozzle)
		bell.position.y=.225;pivot.add_child(bell)
	return {"group":root,"parts":parts}
