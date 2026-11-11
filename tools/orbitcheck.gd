extends SceneTree

var checks:=0
var failures:=0
const MU:=3.986004418e14

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("ORBITCHECK FAIL ",label)

func _init() -> void:
	# An outbound Earth hyperbola at 230,000 km, including a short accepted
	# residual step. The universal-anomaly guess must have consistent SI units.
	var r:=DVec3.new(229975392.75500903,0,0)
	var v:=DVec3.new(6243.493187497603,0,203.07903691641397)
	for dt in [.14313593695632307,1.0,3600.0,-3600.0]: verify(r,v,dt)
	verify(DVec3.new(9e6,0,0),DVec3.new(0,0,11500),3600.0)
	verify(DVec3.new(9e6,0,0),DVec3.new(0,0,sqrt(2*MU/9e6)*1.000001),3600.0)
	verify(DVec3.new(27203752.911670785,0,0),DVec3.new(-18038.390508008622,0,261.0243094425178),-.05986762796533692)
	verify(DVec3.new(73705066.95869502,0,0),DVec3.new(5186.584708762342,0,131.02043122204702),.0001984258044131431)
	verify(DVec3.new(9e6,0,0),DVec3.new(0,0,sqrt(MU/9e6)),3600.0)
	verify(DVec3.new(9e6,0,0),DVec3.new(1200,0,6000),-3600.0)
	var untouched:=DVec3.new(1,2,3)
	expect(not Orbit.propagate(r,v,MU,NAN,untouched,DVec3.new()) and untouched.x==1.0,"invalid time leaves the output untouched")
	print("ORBITCHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)

func verify(r: DVec3,v: DVec3,dt: float) -> void:
	var at:=DVec3.new();var speed:=DVec3.new()
	var ok:=Orbit.propagate(r,v,MU,dt,at,speed)
	expect(ok,"conic propagation converges for dt %.12f"%dt)
	if not ok:return
	var rr:=r.clone();var vv:=v.clone()
	var n:=maxi(64,ceili(absf(dt)/.5));var h:=dt/n
	for i in n:rk4(rr,vv,h)
	expect(at.distance_to(rr)<.15 and speed.distance_to(vv)<.0001,"independent RK4 agreement for dt %.12f (r %.8f, v %.8f)"%[dt,at.distance_to(rr),speed.distance_to(vv)])
	var r_back:=DVec3.new();var v_back:=DVec3.new()
	expect(Orbit.propagate(at,speed,MU,-dt,r_back,v_back) and r_back.distance_to(r)<.3 and v_back.distance_to(v)<.0002,"forward/backward conic symmetry")
	var e0:=v.length_sq()*.5-MU/r.length()
	var e1:=speed.length_sq()*.5-MU/at.length()
	expect(absf(e1-e0)<1e-5*maxf(absf(e0),1.0),"specific orbital energy remains invariant: dt %.3f e0 %.9f e1 %.9f"%[dt,e0,e1])

func gravity(r: DVec3) -> DVec3:
	return r.clone().scale_in(-MU/pow(r.length(),3))

func rk4(r: DVec3,v: DVec3,h: float) -> void:
	var a1:=gravity(r)
	var v2:=v.clone().add_scaled_in(a1,h*.5)
	var a2:=gravity(r.clone().add_scaled_in(v,h*.5))
	var v3:=v.clone().add_scaled_in(a2,h*.5)
	var a3:=gravity(r.clone().add_scaled_in(v2,h*.5))
	var v4:=v.clone().add_scaled_in(a3,h)
	var a4:=gravity(r.clone().add_scaled_in(v3,h))
	r.add_scaled_in(v,h/6).add_scaled_in(v2,h/3).add_scaled_in(v3,h/3).add_scaled_in(v4,h/6)
	v.add_scaled_in(a1,h/6).add_scaled_in(a2,h/3).add_scaled_in(a3,h/3).add_scaled_in(a4,h/6)
