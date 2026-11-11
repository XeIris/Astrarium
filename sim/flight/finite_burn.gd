class_name FiniteBurn
extends RefCounted

# Central-gravity predictor for a continuously prograde escape. Production flight
# still uses Vessel's full force model and steers/cuts off against its live energy.
static func drive(v: Vessel) -> Dictionary:
	var thrust:=0.0;var flow:=0.0;var prop:=0.0
	for st in v.live_stages():
		if st.spec.get("engine")==null or st.prop<=0.0:continue
		var engine: Dictionary=st.spec.engine
		var f: float=float(engine.thrustVac)*st.live
		thrust+=f;flow+=f/(Rocketry.G0*float(engine.ispVac));prop+=st.prop
	return {"thrust":thrust,"isp":thrust/(flow*Rocketry.G0) if flow>0.0 else 0.0,"prop":prop}

static func escape(r: DVec3,v: DVec3,mu: float,mass: float,thrust: float,isp: float,
		vinf: float,prop: float,h:=5.0) -> Dictionary:
	if mu<=0.0 or mass<=prop or thrust<=0.0 or isp<=0.0 or h<=0.0:return {}
	var s:=PackedFloat64Array([r.x,r.y,r.z,v.x,v.y,v.z,mass])
	var k:=PackedFloat64Array();k.resize(28)
	var tmp:=PackedFloat64Array();tmp.resize(7)
	var ve:=isp*Rocketry.G0;var flow:=thrust/ve
	var duration:=0.0;var target:=vinf*vinf*.5
	var budget:=prop/flow
	while duration<budget and duration<86400.0:
		if energy(s,mu)>=target:break
		var step:=minf(h,budget-duration)
		var previous:=s.duplicate();var before:=energy(s,mu)
		_step(s,k,tmp,mu,thrust,flow,step)
		var after:=energy(s,mu)
		if not is_finite(after) or s[6]<=0.0:return {}
		if after>=target:
			# Resolve the cutoff within the last prediction step; the actual burn
			# independently stops on energy measured from its integrated state.
			var fraction:=clampf((target-before)/(after-before),0.0,1.0)
			s=previous
			_step(s,k,tmp,mu,thrust,flow,step*fraction)
			duration+=step*fraction
			return {"r":DVec3.new(s[0],s[1],s[2]),"v":DVec3.new(s[3],s[4],s[5]),
				"duration":duration,"mass":s[6],"dv":ve*log(mass/s[6])}
		duration+=step
	return {}

static func energy(s: PackedFloat64Array,mu: float) -> float:
	return (s[3]*s[3]+s[4]*s[4]+s[5]*s[5])*.5-mu/sqrt(s[0]*s[0]+s[1]*s[1]+s[2]*s[2])

static func _step(s: PackedFloat64Array,k: PackedFloat64Array,tmp: PackedFloat64Array,
		mu: float,thrust: float,flow: float,h: float) -> void:
	for stage in 4:
		var f:=0.0 if stage==0 else (.5 if stage<3 else 1.0)
		for i in 7:tmp[i]=s[i]+(k[(stage-1)*7+i]*h*f if stage>0 else 0.0)
		var r2:=tmp[0]*tmp[0]+tmp[1]*tmp[1]+tmp[2]*tmp[2]
		var g:=-mu/(r2*sqrt(r2))
		var speed:=sqrt(tmp[3]*tmp[3]+tmp[4]*tmp[4]+tmp[5]*tmp[5])
		var a:=thrust/(tmp[6]*maxf(speed,1e-9))
		var off:=stage*7
		for i in 3:
			k[off+i]=tmp[i+3]
			k[off+3+i]=g*tmp[i]+a*tmp[i+3]
		k[off+6]=-flow
	for i in 7:s[i]+=h/6.0*(k[i]+2*k[7+i]+2*k[14+i]+k[21+i])
