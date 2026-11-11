extends SceneTree

var checks:=0
var failures:=0
class Driver extends RefCounted:
	var vessel: Vessel
	var autopilot
	var count=null

func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("MISSIONGUIDANCECHECK FAIL ",label)

func _initialize() -> void:run.call_deferred()

func run() -> void:
	var jupiter:=Body.new();jupiter.name="Jupiter";jupiter.mass=1.0/1047.348644
	jupiter.radius=69911.0*Physics.AU_PER_KM;jupiter.alive=true
	var v:=Vessel.new({"vehicle":Vehicles.get_vehicle("discovery"),"parent":jupiter,"bodies":[jupiter]})
	v.r.set_v(-18970496463.845,2042318788.026,-44659837225.049)
	v.v.set_v(2361.031438478,-258.384067110,5824.730367557);v.phase=Vessel.PHASE.ORBIT
	v.sample(0.0)
	var driver:=Driver.new();driver.vessel=v;driver.autopilot=Guidance.Autopilot.new(v)
	var mission:=Mission.new();mission.flight=driver;mission.dest=jupiter;mission.auto_warp=false
	mission.plan={"legs":[{"key":"approach"},{"key":"capture"}],"r_cap":1e9}
	mission._stage="coast";mission._aim_radius=v.r.length()
	var event:=mission.next_event_s()
	var peri:=Orbit.time_to_periapsis_any(Orbit.elements(v.r,v.v,v.env.mu),v.env.mu)
	expect(event>0.0 and event<peri-Mission.TRIM_BEFORE_S,"arrival warp targets an intermediate checkpoint before the last-hours trim")
	mission.update(.05)
	expect(mission._burn==null,"a distant approach waits between geometric checkpoints")
	mission._aim_radius=v.r.length()*2.1
	mission.update(.05)
	expect(mission._burn!=null and driver.autopilot.program=="node","drifting arrival is corrected at a radius checkpoint, days before periapsis")
	mission._schedule(v.coord+10000.0,"Long capture",func() -> DVec3:return DVec3.new(0,10000,0))
	var duration: float=mission._burn.duration
	expect(duration>1000.0,"long-burn duration is sized from actual thrust, Isp and mass")
	v.coord=10000.0-duration*.5-Mission.HANDOVER_S+1.0
	mission._fly_burn(v,driver.autopilot)
	expect(mission._burn_engaged,"long-burn handover includes half the burn before the node centre")
	var reference: WeakRef=weakref(mission)
	mission.release();mission=null
	expect(reference.get_ref()==null,"ending flight releases a self-capturing scheduled burn")
	v.on_rebase=Callable();driver.autopilot=null
	print("MISSIONGUIDANCECHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)
