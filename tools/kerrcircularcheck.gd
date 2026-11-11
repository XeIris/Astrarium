extends SceneTree

var checks:=0
var failures:=0
func expect(ok: bool,label: String) -> void:
	checks+=1
	if not ok:failures+=1;printerr("KERRCIRCULARCHECK FAIL ",label)

func _init() -> void:
	var rg:=Rocketry.GM_SUN*1e8/(Rocketry.C_MS*Rocketry.C_MS)
	var schwarz:=KerrCircular.parameters(1e8,0.0,6.0*rg)
	expect(schwarz.ok,"Schwarzschild ISCO orbit is allowed")
	expect(absf(float(schwarz.dilation)-sqrt(2.0))<1e-12,"Schwarzschild r=6M clock rate")
	for spin: float in [0.0,.5,.9,.998]:
		var radius:=maxf(1.4,Structure.kerr_isco(spin)*1.05)
		var orbit:=KerrCircular.parameters(1e8,spin,radius*rg)
		expect(orbit.ok,"valid stable prograde orbit")
		var omega: float=orbit.omega*rg/Rocketry.C_MS
		var gtt:=-(1.0-2.0/radius)
		var gtp:=-2.0*spin/radius
		var gpp:=radius*radius+spin*spin+2.0*spin*spin/radius
		var metric_clock:=1.0/sqrt(-gtt-2.0*omega*gtp-omega*omega*gpp)
		expect(absf(metric_clock-float(orbit.dilation))<1e-10,"clock rate from independent metric normalisation")
		var radial_balance:=-2.0/(radius*radius)+4.0*spin*omega/(radius*radius) \
			+omega*omega*(2.0*radius-2.0*spin*spin/(radius*radius))
		expect(absf(radial_balance)<1e-12,"angular velocity satisfies the radial geodesic condition")
		var doubled:=KerrCircular.parameters(2e8,spin,2.0*radius*rg)
		expect(absf(float(doubled.period)/float(orbit.period)-2.0)<1e-12 \
			and absf(float(doubled.dilation)-float(orbit.dilation))<1e-12,"mass scales period and size without changing the dimensionless clock rate")
		var a:=KerrCircular.sample(orbit,123.0)
		var b:=KerrCircular.sample(orbit,123.0+float(orbit.period))
		expect((a.r as DVec3).distance_to(b.r)<.001,"one coordinate period closes the prescribed orbit")
		expect(absf((a.r as DVec3).dot(a.v))/(float(orbit.radius)*(a.v as DVec3).length())<1e-14,"coordinate velocity is tangential")
		expect(absf(float(a.properSeconds)*float(orbit.dilation)-123.0)<1e-12,"proper time derives from the accepted coordinate interval")
	expect(not KerrCircular.parameters(1e8,.999,1.4*rg).ok,"unsupported lens spin is rejected")
	expect(not KerrCircular.parameters(1e8,.998,1.1*rg).ok,"inside-ISCO orbit is rejected")
	expect(not KerrCircular.parameters(0,.5,rg).ok and not KerrCircular.parameters(1e8,.5,NAN).ok,"nonphysical and nonfinite requests are rejected")
	expect(not KerrCircular.parameters(1e-300,.5,1e300).ok,"finite but numerically unresolved orbit is rejected")
	print("KERRCIRCULARCHECK DONE checks=%d failures=%d"%[checks,failures])
	quit(1 if failures else 0)
