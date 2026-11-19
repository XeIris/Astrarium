extends SceneTree

var failures:=0
var checks:=0

func body(label: String,mass: float,at: DVec3) -> Body:
	var b:=Body.new();b.name=label;b.mass=mass;b.pos.copy_from(at);b.alive=true
	return b

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("SOICHECK FAIL ",label)

func _init() -> void:
	var sun:=body("Sun",1.0,DVec3.new())
	var jupiter:=body("Jupiter",1.0/1047.348644,DVec3.new(5.2,0,0))
	var io:=body("Io",4.49e-8,jupiter.pos.clone().add_in(DVec3.new(421700000.0/Rocketry.AU_M,0,0)))
	var ganymede:=body("Ganymede",7.45e-8,jupiter.pos.clone().add_in(DVec3.new(1070412000.0/Rocketry.AU_M,0,0)))
	var v:=Vessel.new({"vehicle":Vehicles.get_vehicle("lm"),"parent":jupiter,"bodies":[sun,jupiter,io,ganymede]})
	expect(v.primary_of(io)==jupiter,"Io belongs to Jupiter, not the larger neighbouring moon")
	expect(v.primary_of(ganymede)==jupiter,"Ganymede belongs to Jupiter")
	expect(v.primary_of(jupiter)==sun and v.primary_of(sun)==null,"planet and root hierarchy")
	var soi:=421700000.0*pow(io.mass/jupiter.mass,.4)
	expect(absf(v.soi_of(io)-soi)<.001,"Io SOI uses its distance and mass ratio to Jupiter")
	v.r.set_v(1.8e9,0,0);v.check_soi()
	expect(v.parent==jupiter,"a distant Jupiter approach does not enter an inflated moon SOI")
	v.r.copy_from(v.body_offset(io,DVec3.new())).add_in(DVec3.new(soi*.5,0,0));v.check_soi()
	expect(v.parent==io,"a real nested SOI encounter rebases onto Io")
	var earth:=body("Earth",Rocketry.M_EARTH_SUN,DVec3.new(1,0,0))
	var moon:=body("Moon",earth.mass/81.30056907,earth.pos.clone().add_in(DVec3.new(384400000.0/Rocketry.AU_M,0,0)))
	v.bodies=[sun,earth,moon]
	expect(v.primary_of(moon)==earth,"Moon keeps Earth even though solar acceleration is stronger")
	v.bodies.reverse()
	expect(v.primary_of(moon)==earth,"hierarchy is independent of body array order")
	v.on_rebase=Callable()
	print("SOICHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)
