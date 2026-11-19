class_name JovianMoons
extends RefCounted

# Approximate mean elements, not an ephemeris: orbital radii, masses and mean
# radii from NASA planetary satellite factsheets. Circular equatorial orbits.
const DATA := [
	["Io",421700.0,4.49e-8,1821.6,{"crater":0.0,"regolith":0xc9b25c,"albedo":.63}],
	["Europa",671034.0,2.41e-8,1560.8,{"crater":.08,"regolith":0xcfc6b4,"albedo":.67}],
	["Ganymede",1070412.0,7.45e-8,2634.1,{"crater":.6,"regolith":0x8a8274,"albedo":.43}],
	["Callisto",1882709.0,5.41e-8,2410.3,{"crater":1.0,"regolith":0x5e564b,"albedo":.22}],
]

## Replace a system-barycentre spec with Jupiter and its four resolved moons,
## preserving the original total mass, position and momentum.
static func system(barycenter: Dictionary) -> Array:
	var jupiter:=barycenter.duplicate(true)
	for row: Array in DATA:jupiter.mass-=float(row[2])
	var out: Array=[jupiter]
	out.append_array(around(jupiter))
	for field in ["pos","vel"]:
		for axis in 3:
			var offset:=0.0
			for moon: Dictionary in out.slice(1):
				offset+=float(moon.mass)/float(barycenter.mass)*(float(moon[field][axis])-float(barycenter[field][axis]))
			for body: Dictionary in out:body[field][axis]-=offset
	return out

static func around(jupiter: Dictionary) -> Array:
	var out:=[]
	var pole: Array=Rocketry.POLES.Jupiter
	var north:=Rocketry.equatorial_dir(deg_to_rad(pole[0]),deg_to_rad(pole[1]))
	var frame:=DQuat.new().set_from_unit_vectors(DVec3.new(0,-1,0),north)
	for i in DATA.size():
		var row: Array=DATA[i]; var a:=float(row[1])*Physics.AU_PER_KM
		var phase: float=[.75,-2.6,2.2,-1.2][i]
		var speed:=Physics.circular_speed(float(jupiter.mass)+float(row[2]),a)
		var pos:=DQuat.rotate(DVec3.new(cos(phase)*a,0,sin(phase)*a),frame)
		var vel:=DQuat.rotate(DVec3.new(-sin(phase)*speed,0,cos(phase)*speed),frame)
		# These moons have exospheres, not a continuum atmosphere for the flight
		# integrator. State the zero-column approximation instead of drawing an air.
		out.append(U.merged({"type":"planet","name":row[0],"mass":row[2],"radiusKm":row[3],"hot":true,
			"oceans":false,"land":1.0,"oceanDepth":0.0,"pN2":0.0,"pO2":0.0,"pAr":0.0,"pCO2":0.0,"pCH4":0.0,"pSO2":0.0},U.merged(row[4],{
			"pos":[float(jupiter.pos[0])+pos.x,float(jupiter.pos[1])+pos.y,float(jupiter.pos[2])+pos.z],
			"vel":[float(jupiter.vel[0])+vel.x,float(jupiter.vel[1])+vel.y,float(jupiter.vel[2])+vel.z]})))
	return out
