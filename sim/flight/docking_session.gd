class_name DockingSession
extends RefCounted

# A short, unwarped rendezvous. Both ships see the same accepted world interval;
# only the approaching vessel fires. Capture makes a rigid attachment after
# small pose/rate gates. Contact dynamics and rotor recoil are not integrated.
const DISTANCE_GATE:=.025
const SPEED_GATE:=.035
const ANGLE_GATE:=.035
const RATE_GATE:=.035

var carrier: Vessel
var craft: CraftModel.Craft
var berth: Dictionary
var render_pos:=DVec3.new()
var status:="Approaching"
var failure:=""
var latched:=false
var capture: Dictionary={}
var readout: Dictionary={}
var proper_rate:=1.0
var initial_rcs:=0.0
var start_coord:=0.0
var _before: Dictionary={}

static func create(v: Vessel,carrier_key: String,slot: String,gap: float) -> DockingSession:
	var vehicle: Dictionary=Vehicles.get_vehicle(carrier_key)
	if vehicle.is_empty() or not is_finite(gap) or gap<6.0 or gap>40.0:return null
	var spec: Dictionary=vehicle.stages[0]
	var slots: Array
	match carrier_key:
		"discovery":slots=DiscoveryCraft.berths(spec)
		"endurance":slots=EnduranceCraft.berths(spec)
		_:return null
	var selected: Dictionary={}
	for entry: Dictionary in slots:
		if str(entry.node)==slot and str(entry.vehicle)==v.vehicle_key:selected=entry
	if selected.is_empty():return null
	var out:=DockingSession.new();out.berth=selected
	out.carrier=Vessel.new({"vehicle":vehicle,"parent":v.parent,"bodies":v.bodies})
	out.carrier.vehicle_key=carrier_key
	out.carrier.r.copy_from(v.r);out.carrier.v.copy_from(v.v);out.carrier.q.copy_from(v.q)
	out.carrier.met=v.met;out.carrier.coord=v.coord;out.carrier.phase=Vessel.PHASE.ORBIT
	out.start_coord=v.coord
	out.craft=CraftModel.build_craft(vehicle)
	var occupied:=out.craft.group.find_child(slot,true,false) as Node3D
	if occupied==null:
		out.craft.group.free()
		return null
	occupied.visible=false
	out.draw_pose(4.0)
	var port:=out.port_pose()
	var lateral:=DQuat.rotate(DVec3.new(.65,0,0),out.carrier.q)
	v.r.copy_from(port.r).add_scaled_in(port.axis,gap).add_in(lateral)
	v.v.copy_from(port.v)
	v.q.copy_from(port.q).premultiply(DQuat.new().set_from_axis_angle(port.axis,-.55))
	v.omega.set_v(0,0,0);v.throttle=0.0;v.auto_stage=false
	v.sample(0.0)
	out.initial_rcs=float(v._first_attached().rcs_prop)
	out.readout=out.measure(v,port)
	v.log_event("Docking approach — %s"%str(vehicle.name))
	return out

func port_pose() -> Dictionary:
	var rotating: bool=carrier.vehicle_key=="endurance"
	var spin:=Centrifuge.state(carrier.stages[0].spec.centrifuge,carrier.met) if rotating else {"angle":0.0,"omega":0.0}
	var axis:=carrier.forward(DVec3.new())
	var frame:=carrier.q.clone().multiply(DQuat.new().set_from_axis_angle(Vessel.BODY_FWD,float(spin.angle)))
	var offset:=DQuat.rotate(DVec3.new(berth.at[0],berth.at[1],berth.at[2]),frame)
	var omega:=carrier.omega.clone().add_scaled_in(axis,float(spin.omega)*proper_rate)
	var q:=frame.multiply(DQuat.new(berth.q[0],berth.q[1],berth.q[2],berth.q[3])).normalize_in()
	var tangent:=omega.cross(offset)
	var radial:=offset.clone().add_scaled_in(axis,-offset.dot(axis)) if rotating else DVec3.new()
	return {"r":carrier.r.clone().add_in(offset),"v":carrier.v.clone().add_in(tangent),
		"q":q,"omega":omega,"axis":axis,"rpm":float(spin.omega)*60.0/TAU,
		"radial":radial,"tangent":tangent,"accel":omega.cross(tangent)}

func advance(seconds: float,bodies: Array,advance_world: Callable) -> float:
	# Guidance uses the start pose. At orbital speeds the end position is hundreds
	# of metres ahead of the active vessel's state when its controls are called.
	_before=port_pose()
	carrier.bodies=bodies
	var start:=carrier.met
	var opts: Dictionary={"advance_world":advance_world} if advance_world.is_valid() else {}
	var accepted:=carrier.step(seconds,opts)
	if accepted>0.0:proper_rate=(carrier.met-start)/accepted
	return accepted

func attitude_error(v: Vessel,port: Dictionary) -> DVec3:
	var error: DQuat=(port.q as DQuat).clone().multiply(v.q.clone().invert())
	var axis:=DVec3.new(error.x,error.y,error.z)
	var magnitude:=axis.length()
	if magnitude<1e-12:return axis
	var angle:=2.0*atan2(magnitude,absf(error.w))
	return axis.scale_in(angle/magnitude*(1.0 if error.w>=0.0 else -1.0))

func measure(v: Vessel,port: Dictionary) -> Dictionary:
	var delta:=v.r.clone().sub_in(port.r)
	var gap:=delta.dot(port.axis)
	return {"gap":gap,"cross":delta.add_scaled_in(port.axis,-gap).length(),
		"speed":v.v.distance_to(port.v),"angle":attitude_error(v,port).length(),
		"rate":v.omega.distance_to(port.omega),"rpm":port.rpm,
		"rcsUsed":initial_rcs-float(v._first_attached().rcs_prop)}

func steer(v: Vessel,dt: float) -> void:
	if dt<=0.0 or _before.is_empty() or latched or failure!="":return
	var tank: Vessel.StageState=v._first_attached()
	if tank==null or not v.rcs_on or tank.rcs_prop<=0.0 or tank.spec.get("rcs")==null:
		failure="No reaction-control propellant or authority"
		return
	var rcs: Dictionary=tank.spec.rcs
	var ve:=Rocketry.G0*float(rcs.isp)
	var force:=float(rcs.thrust)*maxf(float(rcs.count)/4.0,1.0)
	var available:=minf(force*dt,tank.rcs_prop*ve)
	var arm:=v.diameter*.5+v.length*.25
	var inertia:=v.inertia()
	var fwd:=v.forward(DVec3.new())
	var error:=attitude_error(v,_before)
	var angle:=error.length()
	var demand: DVec3=(_before.omega as DVec3).clone().sub_in(v.omega)
	if angle>1e-9:demand.add_scaled_in(error,minf(angle*1.5,.60)/angle)
	var angular:=demand.scaled(float(inertia.pitch)).add_scaled_in(fwd,demand.dot(fwd)*(float(inertia.roll)-float(inertia.pitch)))
	var turn_impulse:=minf(angular.length(),available*arm)
	if angular.length_sq()>1e-16:angular.scale_in(turn_impulse/angular.length())
	v.omega.add_scaled_in(angular,1.0/float(inertia.pitch)).add_scaled_in(fwd,
		angular.dot(fwd)*(1.0/float(inertia.roll)-1.0/float(inertia.pitch)))
	available-=turn_impulse/arm
	var axis: DVec3=_before.axis
	var delta:=v.r.clone().sub_in(_before.r)
	var gap:=delta.dot(axis);var side:=delta.add_scaled_in(axis,-gap)
	# Centreline first, then follow the off-axis hatch on short final. This
	# avoids spending RCS circling a 13 cm offset through the whole approach.
	var t:=clampf((gap-2.0)/4.0,0.0,1.0)
	var blend:=1.0-t*t*(3.0-2.0*t)
	var blend_rate: float=-1.5*t*(1.0-t)*v.v.clone().sub_in(_before.v).dot(axis)
	side.add_scaled_in(_before.radial,1.0-blend)
	var aligned:=side.length()<.12 and angle<ANGLE_GATE and v.omega.distance_to(_before.omega)<.045
	var hold:=0.0 if aligned else 6.0
	var distance:=hold-gap
	# Slow before the stopping distance of the available jets, leaving thrust
	# for lateral station keeping as the measured gap approaches the latch.
	var brake:=sqrt(2.0*.50*maxf(available,0.0)*absf(distance)/(dt*v.mass))
	var speed:=signf(distance)*minf(.30,minf(brake,.65*absf(distance)))
	var want: DVec3=(_before.v as DVec3).clone().add_scaled_in(axis,speed).add_scaled_in(side,-.6) \
		.add_scaled_in(_before.tangent,blend-1.0).add_scaled_in(_before.radial,blend_rate)
	# The port's small offset from the spin axis needs continuous centripetal
	# acceleration; position feedback alone would leave a steady capture error.
	var impulse:=want.sub_in(v.v).scale_in(minf(dt*1.8,1.0)).add_scaled_in(_before.accel,dt*blend).scale_in(v.mass)
	var used:=minf(impulse.length(),maxf(available,0.0))
	if impulse.length_sq()>1e-16:v.v.add_scaled_in(impulse,used/(impulse.length()*v.mass))
	tank.rcs_prop=maxf(tank.rcs_prop-(used+turn_impulse/arm)/ve,0.0)
	status="Final approach" if aligned else ("Matching spin and alignment" if float(_before.rpm)!=0.0 else "Aligning with bay")

func after_step(v: Vessel) -> void:
	if failure!="" or latched:return
	if v.coord-start_coord>240.0:
		failure="Approach did not converge (gap %.3f m, lateral %.3f m, rate %.3f rad/s)"%[readout.gap,readout.cross,readout.rate]
		return
	if carrier.parent!=v.parent:
		failure="The vessels left their shared flight frame"
		return
	var pose:=port_pose()
	readout=measure(v,pose)
	if absf(readout.gap)<=DISTANCE_GATE and readout.cross<=DISTANCE_GATE and readout.speed<=SPEED_GATE \
		and readout.angle<=ANGLE_GATE and readout.rate<=RATE_GATE:
		capture=readout.duplicate();latched=true;status="Docked"
		_attach(v,pose)
		v.log_event("Docking capture — %s"%str(carrier.vehicle.name))
	elif readout.gap < -DISTANCE_GATE:
		failure="Port contact outside capture limits (%.3f m/s, %.2f°)"%[readout.speed,rad_to_deg(readout.angle)]

func step_linked(v: Vessel,seconds: float,bodies: Array,advance_world: Callable) -> float:
	var accepted:=advance(seconds,bodies,advance_world)
	_attach(v,port_pose())
	v.step_clocks(accepted);v.sample(0.0)
	return accepted

func _attach(v: Vessel,pose: Dictionary) -> void:
	v.r.copy_from(pose.r);v.v.copy_from(pose.v);v.q.copy_from(pose.q);v.omega.copy_from(pose.omega)

func draw_pose(dt: float) -> void:
	var deploy: Dictionary={"explorer":1.0} if carrier.vehicle_key=="discovery" else {}
	craft.update({"dt":dt,"properTime":carrier.met,"deploy":deploy})
