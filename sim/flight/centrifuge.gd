class_name Centrifuge
extends RefCounted

# A prescribed internal rotor. Its angular momentum is not coupled to the hull's
# attitude; this limitation is exposed alongside the habitat measurements.
static func state(spec: Dictionary, proper_seconds: float) -> Dictionary:
	var radius:=float(spec.radius)
	var rpm:=float(spec.rpm)
	var omega:=rpm*TAU/60.0
	var walk:=float(spec.get("walkSpeed",1.4))
	return {"radius":radius,"rpm":rpm,"omega":omega,"gravity":omega*omega*radius,
		"gees":omega*omega*radius/Rocketry.G0,
		"coriolisRatio":2.0*walk/(absf(omega)*radius) if absf(omega)*radius>0.0 else NAN,
		"walkSpeed":walk,"angle":wrapf(fmod(proper_seconds,60.0/maxf(absf(rpm),1e-12))*omega,0.0,TAU),
		"momentumCoupled":false}

static func telemetry(stages: Array, proper_seconds: float) -> Dictionary:
	for st in stages:
		if st.attached and st.spec.get("centrifuge") is Dictionary:
			return state(st.spec.centrifuge,proper_seconds)
	return {}
