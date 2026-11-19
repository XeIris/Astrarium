extends Node

var main: Node
var failures:=0

func _ready() -> void:
	PlanetMaps.synchronous=true
	get_viewport().set_disable_input(true)
	seed(1)
	main=Node.new(); main.set_script(load("res://main.gd")); add_child(main); main.set_process(false)
	for i in 4: await get_tree().process_frame
	main._start("sandbox"); main.set_drawn(false,false); main.load_preset("solar")
	await CraftAssets.craft_models_ready(["ranger"])
	var f: Spaceflight=main.flight
	f.begin("ranger",{"mode":"orbit","alt":250e3,"inc":28.5,"phase":0.0})
	main.set_cam_mode("flight")
	for i in 5: main.animate(1.0/60)
	var v:=f.vessel
	var initial_prop: float=v.current_stage.prop
	f.run_program("glide")
	var frames:=0; var seen:=0
	while frames<600000 and v.phase not in [Vessel.PHASE.LANDED,Vessel.PHASE.DESTROYED]:
		f.set_warp(3 if v.altitude()>120e3 else 0)
		main.animate(1.0/60)
		frames+=1
		while seen<v.events.size():
			print("RANGERFLIGHT T+%.1f %s"%[v.events[seen].t,v.events[seen].msg]); seen+=1
		if frames%1800==0:
			print("RANGERFLIGHT state=%s h=%.0f v=%.1f q=%.0f"%[f.autopilot.state_name,v.altitude(),v.v.length(),v.telemetry.q])
			await get_tree().process_frame
	if v.phase!=Vessel.PHASE.LANDED:
		failures+=1; printerr("RANGERFLIGHT FAIL did not land: ",v.phase," ",f.autopilot.status)
	elif v.landed_at==null or absf(float(v.landed_at.vVert))>float(v.current_stage.spec.gear.vVert) or not v.current_stage.gear_out or v.rolling==null or v.rolling.stop==null:
		failures+=1; printerr("RANGERFLIGHT FAIL incomplete or unsafe gear landing/rollout")
	if v.current_stage.prop>=initial_prop:
		failures+=1; printerr("RANGERFLIGHT FAIL deorbit did not consume propellant")
	print("RANGERFLIGHT RESULT phase=%s frames=%d fuel=%.1f touchdown=%s"%[v.phase,frames,v.current_stage.prop,v.landed_at])
	main.end_flight()
	print("RANGERFLIGHT DONE failures=%d"%failures)
	get_tree().quit(1 if failures else 0)
