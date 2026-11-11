extends Node

var main: Node
var failures:=0

func _ready() -> void:
	PlanetMaps.synchronous=true;get_viewport().set_disable_input(true);seed(1)
	main=Node.new();main.set_script(load("res://main.gd"));add_child(main);main.set_process(false)
	for i in 4:await get_tree().process_frame
	main._start("sandbox");main.set_drawn(false,false);main.load_preset("jovian_voyage")
	await CraftAssets.craft_models_ready(["discovery"])
	var f: Spaceflight=main.flight
	f.begin("discovery",{"mode":"orbit","inc":0.0,"phase":0.0})
	main.set_cam_mode("flight")
	for i in 5:main.animate(1.0/60)
	var v:=f.vessel
	var drive: Vessel.StageState=v.stages[0]
	var initial_prop: float=drive.prop
	var mission=f.start_mission("Jupiter","orbit")
	if mission==null or mission.failed!="":
		printerr("DISCOVERYFLIGHT FAIL mission did not start: ",mission.failed if mission else "null")
		main.end_flight();get_tree().quit(1);return
	print("DISCOVERYFLIGHT PLAN dv=%.1f available=%.1f wait=%.1f days tof=%.1f days"%[mission.plan.dv,mission.plan.dv_avail,mission.plan.wait/86400,mission.plan.tof/86400])
	if mission.plan.get("aero",false):
		printerr("DISCOVERYFLIGHT FAIL unshielded explorer planned an atmospheric pass")
		main.end_flight();get_tree().quit(1);return
	var frames:=0;var seen:=0
	while frames<1000000 and not mission.done and mission.failed=="" and v.phase!=Vessel.PHASE.DESTROYED:
		main.animate(FlightScenarios.DT);frames+=1
		if f.autopilot.burning and v.throttle==0.0 and v.authority(0.0).alpha<=0.0:
			mission.abort("Burn cannot turn: no remaining attitude authority")
		while seen<v.events.size():
			print("DISCOVERYFLIGHT T+%.1f %s"%[v.events[seen].t,v.events[seen].msg])
			if str(v.events[seen].msg).contains("cutoff"):
				print("DISCOVERYFLIGHT COAST_STATE ",JSON.stringify({"r":[v.r.x,v.r.y,v.r.z],"v":[v.v.x,v.v.y,v.v.z],"mu":v.env.mu,"coord":v.coord}))
			seen+=1
		if frames%6000==0:
			print("DISCOVERYFLIGHT frames=%d t=%.0f parent=%s h=%.0f fuel=%.1f rcs=%.1f %s"%[frames,v.met,v.parent.name,v.altitude(),drive.prop,drive.rcs_prop,mission.status])
			var jupiter: Body=main.state.body_named("Jupiter")
			for row: Array in JovianMoons.DATA:
				var moon: Body=main.state.body_named(row[0])
				if moon==null or not moon.alive or absf(moon.pos.distance_to(jupiter.pos)/Physics.AU_PER_KM/float(row[1])-1.0)>.05:
					mission.abort("Galilean moon left its supported orbital-radius window: "+str(row[0]))
			await get_tree().process_frame
	if not mission.done or mission.failed!="" or v.parent.name!="Jupiter":
		failures+=1;printerr("DISCOVERYFLIGHT FAIL incomplete Jupiter rendezvous: ",mission.failed," ",mission.status)
		printerr("DISCOVERYFLIGHT FAILURE_STATE ",JSON.stringify({"r":v.r.to_array(),"v":v.v.to_array(),"mu":v.env.mu,"coord":v.coord,"stage_h":v._stage_h,"rcs":drive.rcs_prop,"q":[v.q.x,v.q.y,v.q.z,v.q.w],"omega":v.omega.to_array()}))
	elif float(v.telemetry.ecc)>.1 or float(v.telemetry.peri)<float(v.env.atm.top):
		failures+=1;printerr("DISCOVERYFLIGHT FAIL unsafe final orbit: ",v.telemetry.ecc," ",v.telemetry.peri)
	if drive.prop>=initial_prop:
		failures+=1;printerr("DISCOVERYFLIGHT FAIL manoeuvres did not consume propellant")
	if drive.prop<initial_prop*.05:
		failures+=1;printerr("DISCOVERYFLIGHT FAIL less than five per cent main propellant reserve: ",drive.prop)
	if v.telemetry.get("centrifuge",{}).is_empty():
		failures+=1;printerr("DISCOVERYFLIGHT FAIL habitat telemetry missing")
	print("DISCOVERYFLIGHT RESULT frames=%d parent=%s phase=%s fuel=%.1f rcs=%.1f peri=%.0f apo=%.0f ecc=%.6f"%[frames,v.parent.name,v.phase,drive.prop,drive.rcs_prop,float(v.telemetry.get("peri",NAN)),float(v.telemetry.get("apo",NAN)),float(v.telemetry.get("ecc",NAN))])
	main.end_flight();for i in 3:await get_tree().process_frame
	print("DISCOVERYFLIGHT DONE failures=%d"%failures)
	get_tree().quit(1 if failures else 0)
