class_name KerrCircular
extends RefCounted

# Prescribed prograde equatorial circular orbit in Boyer–Lindquist coordinates.
# It is a test-particle demonstration, never an input to the weak-field integrator.
# Bardeen, Press & Teukolsky (1972), eq. 2.16; docs/physics/kerr-demonstration.md.
const MAX_SPIN:=.998

static func parameters(mass_sun: float,spin: float,radius_m: float) -> Dictionary:
	if not is_finite(mass_sun) or not is_finite(spin) or not is_finite(radius_m) \
		or mass_sun<=0.0 or spin<0.0 or spin>MAX_SPIN or radius_m<=0.0:
		return {"ok":false,"why":"Expected positive mass and radius, with prograde spin in 0–0.998"}
	var mu:=Rocketry.GM_SUN*mass_sun
	var gravitational_radius:=mu/(Rocketry.C_MS*Rocketry.C_MS)
	if not is_finite(gravitational_radius) or gravitational_radius<=0.0:
		return {"ok":false,"why":"The mass is outside the resolved numeric range"}
	var radius:=radius_m/gravitational_radius
	var isco:=Structure.kerr_isco(spin)
	if not is_finite(radius) or radius<isco:
		return {"ok":false,"why":"The prescribed stable orbit must be at or outside the Kerr ISCO"}
	var root:=sqrt(1.0-3.0/radius+2.0*spin/pow(radius,1.5))
	var dilation:=(1.0+spin/pow(radius,1.5))/root
	var omega:=Rocketry.C_MS/gravitational_radius/(pow(radius,1.5)+spin)
	var period:=TAU/omega if omega>0.0 else INF
	if not is_finite(period) or not is_finite(dilation) or period<=0.0:
		return {"ok":false,"why":"The orbit is outside the resolved numeric range"}
	return {"ok":true,"why":"","radius":radius_m,"radiusM":radius,"spin":spin,
		"gravitationalRadius":gravitational_radius,"iscoM":isco,"omega":omega,
		"period":period,"dilation":dilation,"properRate":1.0/dilation,
		"label":"Kinematic Kerr circular orbit"}

static func sample(orbit: Dictionary,coordinate_seconds: float,phase:=0.0) -> Dictionary:
	if not orbit.get("ok",false) or not is_finite(coordinate_seconds) or not is_finite(phase):return {}
	var angle:=wrapf(fmod(coordinate_seconds,float(orbit.period))*float(orbit.omega)+phase,0.0,TAU)
	var radius:=float(orbit.radius);var speed:=radius*float(orbit.omega)
	return {"r":DVec3.new(radius*cos(angle),0.0,radius*sin(angle)),
		"v":DVec3.new(-speed*sin(angle),0.0,speed*cos(angle)),
		"angle":angle,"properSeconds":coordinate_seconds*float(orbit.properRate)}
