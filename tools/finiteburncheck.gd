extends SceneTree

var failures:=0
var checks:=0
class Driver extends RefCounted:
	var vessel: Vessel
	var autopilot
	var count=null
	var warp_idx:=0
	func set_warp(i: int):warp_idx=i
	func warp_index() -> int:return warp_idx

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("FINITEBURNCHECK FAIL ",label)

func _initialize() -> void:run.call_deferred()

func run() -> void:
	var earth:=Body.new();earth.name="Earth";earth.alive=true
	earth.mass=Rocketry.M_EARTH_SUN;earth.radius=6371.0*Physics.AU_PER_KM
	var v:=Vessel.new({"vehicle":Vehicles.get_vehicle("discovery"),"parent":earth,"bodies":[earth]})
	v.place_in_orbit(1000e3,0.0,0.0);v.env.zonal=null
	var drive:=FiniteBurn.drive(v)
	var prediction:=FiniteBurn.escape(v.r,v.v,v.env.mu,v.mass,drive.thrust,drive.isp,9000.0,drive.prop)
	var fine:=FiniteBurn.escape(v.r,v.v,v.env.mu,v.mass,drive.thrust,drive.isp,9000.0,drive.prop,1.0)
	expect(not prediction.is_empty() and not fine.is_empty(),"finite escape is achievable")
	if prediction.is_empty() or fine.is_empty():quit(1);return
	expect(absf(float(prediction.dv)-float(fine.dv))<.1 and absf(float(prediction.duration)-float(fine.duration))<.1,"predictor step convergence")
	var heavy:=FiniteBurn.escape(v.r,v.v,v.env.mu,v.mass*2.0,drive.thrust,drive.isp,9000.0,drive.prop*2.0)
	expect(not heavy.is_empty() and float(heavy.duration)>float(prediction.duration)*1.5,"heavier craft takes longer at unchanged thrust")
	expect(FiniteBurn.escape(v.r,v.v,v.env.mu,v.mass,drive.thrust,drive.isp,9000.0,100.0).is_empty(),"insufficient fuel is rejected")
	var driver:=Driver.new();driver.vessel=v;driver.autopilot=Guidance.Autopilot.new(v)
	var mission:=Mission.new();mission.flight=driver
	mission.dest=earth;mission.auto_warp=false
	mission.plan={"case":"planet","legs":[{"key":"escape"}]}
	mission._stage="burn"
	mission._schedule(v.coord+220.0*86400.0,"Distant departure",func() -> DVec3:return DVec3.new(0,1000,0))
	driver.autopilot.mode=Guidance.MODE.PROGRADE
	var coast_rcs: float=v.current_stage.rcs_prop
	for i in 200:
		mission.update(.05);driver.autopilot.update(.05)
		v.step(5000.0,{"rails":true})
	expect(v.current_stage.rcs_prop==coast_rcs,"unpowered window wait preserves attitude propellant")
	# Restore the same parking state before comparing the guided burn against the
	# isolated central-gravity prediction above.
	v.place_in_orbit(1000e3,0.0,0.0);v.env.zonal=null
	var direction:=DVec3.new(1,0,1).normalized()
	mission._schedule_finite_escape(v,v.env.mu,300.0,direction,9000.0)
	expect(mission.failed=="" and mission._burn!=null,"finite departure schedules")
	var before: float=v.current_stage.prop
	var frames:=0
	while frames<400000 and not mission._burn_done(driver.autopilot):
		mission._fly_burn(v,driver.autopilot)
		driver.autopilot.update(.05)
		v.step(.05)
		frames+=1
		if frames%12000==0:await process_frame
	var achieved:=sqrt(maxf(v.v.length_sq()-2.0*v.env.mu/v.r.length(),0.0))
	var actual=Mission._asymptote(v.r,v.v,v.env.mu)
	expect(frames<400000,"production departure burn completes")
	expect(absf(achieved-9000.0)<2.0,"live energy cutoff reaches requested excess speed: %.4f"%achieved)
	expect(actual!=null and DQuat.angle_between(actual,direction)<.01,"flown departure points along requested asymptote")
	expect(v.current_stage.prop<before and v.current_stage.prop>0.0,"production burn pays for propellant")
	print("FINITEBURNCHECK RESULT frames=%d met=%.2f vinf=%.4f prop=%.2f rcs=%.2f"%[frames,v.met,achieved,v.current_stage.prop,v.current_stage.rcs_prop])
	mission._burn=null;mission.flight=null;v.on_rebase=Callable();driver.autopilot=null
	print("FINITEBURNCHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)
