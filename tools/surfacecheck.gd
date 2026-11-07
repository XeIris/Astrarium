extends Node

# The surface: terrain, sea and weather against outside numbers, the visit through the app's path at the
# model's extremes, and the proof that outside a visit none of it allocates or runs. With pixels=1,
# windowed, it stands at contrasting sites and judges the frames (quality=low|high, out=/abs/dir).
const Catch = preload("res://tools/coursecheck.gd").Catch
var catcher := Catch.new()
var stage: Node
var checks := 0
var failures := 0
var args := {}

func check(label: String, ok: bool) -> void:
	checks += 1
	if not ok: failures += 1
	print("%s %s" % ["ok" if ok else "FAIL", label])

func near(a: float, b: float, tol: float) -> bool:
	return absf(a - b) <= tol

func new_stage(preset: String) -> void:
	stage.load_preset(preset)
	stage.set_process(false)
	stage.state.paused = true

func spawn_world(mix: String, au: float, name_: String, extra := {}) -> Body:
	var inputs: Dictionary = Composition.MIXES[mix].inputs.duplicate()
	inputs.merge(extra, true)
	var spec := {"type": "planet", "mass": 3e-6, "name": name_, "seed": 4242, "obliquity": 0.41}
	spec.merge(inputs, true)
	var lamp: Body = stage.get_stars()[0]
	spec.pos = DVec3.new(cos(1.0), 0.0, sin(1.0)).scaled(au).add(lamp.pos).to_array()
	var v := Physics.circular_speed(lamp.mass, au)
	spec.vel = DVec3.new(-sin(1.0), 0.0, cos(1.0)).scaled(v).add(lamp.vel).to_array()
	var b: Body = stage.spawn_body(spec)
	for i in 3: stage.animate(1.0 / 60.0)
	return b

# OCEANS
func waves() -> void:
	# The closed forms, and the drawn trains' own variance against them.
	check("10 m/s fully developed is 2–3 m on Earth (Beaufort 5): %.2f" % SurfaceWaves.developed_hs(10.0, 9.81), SurfaceWaves.developed_hs(10.0, 9.81) >= 2.0 and SurfaceWaves.developed_hs(10.0, 9.81) <= 3.0)
	check("Titan at 1 m/s is near Lorenz & Hayes's 0.2 m (%.2f)" % SurfaceWaves.developed_hs(1.0, 1.35), near(SurfaceWaves.developed_hs(1.0, 1.35), 0.2, 0.06))
	check("Height goes as 1/g", near(SurfaceWaves.developed_hs(10.0, 3.72) / SurfaceWaves.developed_hs(10.0, 9.81), 9.81 / 3.72, 1e-9))
	for wind in [5.0, 10.0, 20.0]:
		for g in [9.81, 3.72, 1.35]:
			var trains := SurfaceWaves.make_trains(wind, g, 4000.0, 7)
			var sea := SurfaceWaves.fill(trains, wind, 0.0, g, 1.0e9)
			var want := SurfaceWaves.developed_hs(wind, g)
			check("U=%d g=%.2f: the trains' H_s is the closed form (%.2f, %.2f m)" % [wind, g, sea.hs, want], near(sea.hs, want, 0.2 * want))
	# Fetch-limited against the observed table (Wikipedia, Wind wave): 37 km/h, 139 km, average 1.5 m. H_s ≈ 1.6 × mean.
	var t2 := SurfaceWaves.make_trains(10.3, 9.81, 4000.0, 7)
	var s2 := SurfaceWaves.fill(t2, 10.3, 0.0, 9.81, 139000.0)
	check("37 km/h over 139 km gives about 2.4 m (%.2f)" % s2.hs, near(s2.hs, 2.4, 0.8))
	var short := SurfaceWaves.fill(t2, 10.3, 0.0, 9.81, 2000.0)
	check("a short fetch raises less", short.hs < s2.hs * 0.7)
	check("the peak period at 10 m/s is near 7 s (%.1f)" % (TAU / SurfaceWaves.peak_omega(10.0, 9.81, 1e9)), near(TAU / SurfaceWaves.peak_omega(10.0, 9.81, 1e9), 7.5, 1.0))
	# Dispersion's limits.
	check("deep water: ω² = gk", near(SurfaceWaves.wavenumber(1.0, 9.81, 5000.0), 1.0 / 9.81, 1e-3))
	var shallow_k := SurfaceWaves.wavenumber(0.05, 9.81, 10.0)
	check("shallow water: c = √(gh)", near(0.05 / shallow_k, sqrt(9.81 * 10.0), 0.3))
	check("a lower g slows a wave of the same frequency", SurfaceWaves.wavenumber(1.0, 3.72, 5000.0) > SurfaceWaves.wavenumber(1.0, 9.81, 5000.0))
	var cm := TAU / 0.017
	var w_ripple := sqrt((9.81 * cm + SurfaceWaves.SIGMA_WATER / SurfaceWaves.RHO_WATER * pow(cm, 3.0)))
	check("capillaries come in at about 1.7 cm (Wikipedia's minimum phase speed, %.2f m/s)" % (w_ripple / cm), near(w_ripple / cm, SurfaceWaves.min_phase_speed(9.81), 0.01))
	check("the minimum phase speed is water's 0.23 m/s (%.3f)" % SurfaceWaves.min_phase_speed(9.81), near(SurfaceWaves.min_phase_speed(9.81), 0.23, 0.01))
	# A wind change must not jump a phase.
	var tr := SurfaceWaves.make_trains(8.0, 9.81, 4000.0, 3)
	var before: Array = tr.map(func(t): return [t.omega, t.k, t.phase])
	SurfaceWaves.fill(tr, 25.0, 1.0, 9.81, 1e7)
	check("a wind change keeps every train's frequency and phase", tr.map(func(t): return [t.omega, t.k, t.phase]) == before)
	check("a site's sea is reproducible", SurfaceWaves.make_trains(8.0, 9.81, 4000.0, 3).map(func(t): return t.phase) == before.map(func(r): return r[2]))
	# The direction: a bearing east runs along the frame's −x.
	SurfaceWaves.fill(tr, 8.0, PI * 0.5, 9.81, 1e7)
	var arrays := SurfaceWaves.shader_arrays(tr)
	var mean_x := 0.0
	for w: Vector4 in arrays.waves: mean_x += w.x / max(Vector2(w.x, w.y).length(), 1e-9)
	check("an eastward wind's waves run east, which is −x here", mean_x < 0.0)

func tides() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	var moon: Body = stage.state.body_named("Moon")
	var sun: Body = stage.state.body_named("Sun")
	var to_moon := moon.pos.sub(earth.pos).normalized().to_v3()
	var rows: Array = SurfaceWaves.tide(earth, to_moon, stage.state.bodies).rows
	var by := {}
	for r in rows: by[r.name] = r
	check("the Moon and Sun both raise tides on Earth", by.has("Moon") and by.has("Sun"))
	var gamma := 1.0 - 1.04 * 0.299
	check("Earth's γ is the elastic 0.69", near(gamma, 0.69, 0.005))
	# (m/M)(R/d)³R: 0.357 m for the Moon, full range 3/2 of it = 0.54 m and for the Sun 0.25 m.
	# The preset starts with the Moon near apogee, so the Moon's rows are read at its mean 384 400 km.
	var moon_km: float = moon.pos.distance_to(earth.pos) * Rocketry.AU_M / 1000.0
	print("SURFACECHECK the Moon is at %.0f km" % moon_km)
	var moon_scale: float = by.Moon.scale / gamma * pow(moon_km / 384400.0, 3.0)
	var sun_scale: float = by.Sun.scale / gamma
	check("the Moon's tide before the world's yield ranges 0.54 m (%.3f, at its live distance)" % (1.5 * moon_scale), near(1.5 * moon_scale, 0.54, 0.08))
	check("the Sun's ranges 0.25 m (%.3f)" % (1.5 * sun_scale), near(1.5 * sun_scale, 0.25, 0.015))
	check("S₂/M₂ is 0.46 (%.3f)" % (sun_scale / moon_scale), near(sun_scale / moon_scale, 0.46, 0.07))
	# M₂ at the equator under the Moon: 3/4 of its scale, over the declination's cos²: Apel's 0.24 m.
	check("M₂ is Apel's 0.24 m (%.3f)" % (0.75 * moon_scale * 0.905), near(0.75 * moon_scale * 0.905, 0.24, 0.04))
	check("S₂ is Apel's 0.11 m (%.3f)" % (0.75 * sun_scale * 0.915), near(0.75 * sun_scale * 0.915, 0.11, 0.01))
	var sub: float = SurfaceWaves.tide(earth, to_moon, stage.state.bodies).height
	var side: float = SurfaceWaves.tide(earth, to_moon.cross(sun.pos.sub(earth.pos).normalized().to_v3()).normalized(), stage.state.bodies).height
	check("high under the Moon, low round the side (%.3f, %.3f)" % [sub, side], sub > side + 0.05)
	# The semi-diurnal rhythm, from the live orbit: a site turning with Earth under the real Moon.
	var period_s: float = RockyVisual.sidereal_period_yr(earth) * Rocketry.YR_S
	var site := Vector3(1.0, 0.0, 0.0)
	var dt_h := 0.2
	var heights := []
	var turned := 0.0
	stage.state.max_step = minf(stage.state.max_step, 1e-4)
	for i in int(24.0 * 4.0 / dt_h):
		heights.append(SurfaceWaves.tide(earth, site.rotated(Vector3.UP, -turned), stage.state.bodies).height)
		stage.step_physics(dt_h * 3600.0 / Rocketry.YR_S)
		turned += TAU * dt_h * 3600.0 / period_s
	var peaks := []
	for i in range(1, heights.size() - 1):
		if heights[i] > heights[i - 1] and heights[i] >= heights[i + 1]: peaks.append(i)
	var gaps := 0.0
	for i in range(1, peaks.size()): gaps += (peaks[i] - peaks[i - 1]) * dt_h
	var mean_gap := gaps / maxf(peaks.size() - 1, 1)
	check("high water comes round every 12.4 h, near M₂'s 12.42 (%.2f h, %d peaks)" % [mean_gap, peaks.size()], near(mean_gap, 12.42, 0.45) and peaks.size() >= 6)
	# A world with another moon's arrangement reads its own bodies.
	new_stage("solar")
	var mars: Body = stage.state.body_named("Mars")
	check("a world with no near moon has a smaller tide", absf(SurfaceWaves.tide(mars, Vector3.UP, stage.state.bodies).height) < 0.1)

# WEATHER: the scales on worlds whose numbers fitted nothing here but Earth's.
func world_scales(g: float, radius_km: float, omega: float, temp: float, molar: float, cp: float, wet: bool, contrast: float, rho: float, absorbed: float) -> SurfaceWeather:
	var w := SurfaceWeather.new()
	w.g = g; w.radius = radius_km * 1000.0; w.omega = omega; w.temp = temp; w.cp = cp; w.wet = wet
	w.scale_h = 8.314 * temp / (molar * g)
	w.pole_equator_k = contrast; w.rho = rho; w.absorbed = absorbed; w.has_air = true
	w.derive()
	return w

func weather() -> void:
	var earth := world_scales(9.81, 6371.0, 7.29e-5, 288.0, 0.02896, 1004.0, true, 40.0, 1.225, 240.0)
	var mars := world_scales(3.72, 3389.5, 7.09e-5, 210.0, 0.04334, 735.0, false, 60.0, 0.016, 110.0)
	var venus := world_scales(8.87, 6051.8, 2.31e-5, 737.0, 0.04345, 1180.0, false, 5.0, 65.0, 17.0)
	var titan := world_scales(1.352, 2575.0, 4.5e-6, 94.0, 0.0275, 1040.0, false, 3.0, 5.3, 3.0)
	print("SURFACECHECK Hadley: Earth %.0f° Mars %.0f° Venus %.0f° Titan %.0f°" % [rad_to_deg(earth.hadley), rad_to_deg(mars.hadley), rad_to_deg(venus.hadley), rad_to_deg(titan.hadley)])
	check("Earth's Hadley edge is near its observed 30° (%.0f°)" % rad_to_deg(earth.hadley), near(rad_to_deg(earth.hadley), 30.0, 8.0))
	check("Mars's is near 40° (%.0f°)" % rad_to_deg(mars.hadley), near(rad_to_deg(mars.hadley), 40.0, 15.0))
	check("Venus's is near 60° (%.0f°)" % rad_to_deg(venus.hadley), near(rad_to_deg(venus.hadley), 60.0, 20.0))
	check("Titan's runs pole to pole (%.0f°)" % rad_to_deg(titan.hadley), rad_to_deg(titan.hadley) > 85.0)
	var n_earth := TAU * earth.radius * cos(earth.storm_lat) / earth.wavelength
	var n_mars := TAU * mars.radius * cos(mars.storm_lat) / mars.wavelength
	print("SURFACECHECK wavenumber: Earth %.1f Mars %.1f; Rossby %.0f km, %.0f km" % [n_earth, n_mars, earth.rossby / 1000.0, mars.rossby / 1000.0])
	check("Earth's storms are zonal wavenumber 5–7 (%.1f)" % n_earth, n_earth >= 4.0 and n_earth <= 8.0)
	check("Mars's are 1–4 (%.1f)" % n_mars, n_mars >= 1.0 and n_mars <= 4.5)
	check("Earth's Rossby radius is about 1000 km (%.0f)" % (earth.rossby / 1000.0), near(earth.rossby / 1000.0, 1000.0, 400.0))
	var efold_d := 1.0 / earth.eady_rate / 86400.0
	check("Earth's e-fold is a day or two (%.1f d)" % efold_d, efold_d > 0.7 and efold_d < 3.0)
	check("Earth's storms last 3–6 days (%.1f d; calibrated to about 4)" % (earth.life_s / 86400.0), earth.life_s / 86400.0 > 3.0 and earth.life_s / 86400.0 < 6.0)
	check("they drift at 8–25 m/s (%.1f)" % earth.drift, earth.drift > 8.0 and earth.drift < 25.0)
	check("the Earth's surface wind is the pin's 7 m/s", near(earth.wind_mean, 7.0, 0.01))
	check("Venus's surface wind is NSSDC's 0.3–1 m/s, to a factor of two (%.2f)" % venus.wind_mean, venus.wind_mean > 0.15 and venus.wind_mean < 2.0)
	print("SURFACECHECK surface wind: Earth %.1f Mars %.1f Venus %.2f Titan %.2f" % [earth.wind_mean, mars.wind_mean, venus.wind_mean, titan.wind_mean])
	# Mars is high by this estimate (the doc says so); this keeps it from going further.
	check("Mars's is within a factor of five of Viking's 2–10 m/s (%.1f)" % mars.wind_mean, mars.wind_mean > 2.0 and mars.wind_mean < 50.0)
	check("a thin air's scale height is its own", near(mars.scale_h / 1000.0, 11.0, 1.0))
	# A world's own: spinning faster narrows the cell (Wikipedia, Kaspi & Showman).
	var fast := world_scales(9.81, 6371.0, 2.0 * 7.29e-5, 288.0, 0.02896, 1004.0, true, 40.0, 1.225, 240.0)
	check("spinning twice as fast narrows the cell", fast.hadley < earth.hadley)
	check("and shrinks the storms", fast.wavelength < earth.wavelength)
	var stronger := world_scales(9.81, 6371.0, 7.29e-5, 288.0, 0.02896, 1004.0, true, 80.0, 1.225, 240.0)
	check("a sharper contrast grows them faster", stronger.eady_rate > earth.eady_rate)
	# A system's life on the stage's clock, and the mean rain it delivers.
	new_stage("solar")
	var e: Body = stage.state.body_named("Earth")
	var w := SurfaceWeather.new()
	w.setup(e, e.climate, deg_to_rad(50.0), 0.3, 99)
	var again := SurfaceWeather.new()
	again.setup(e, e.climate, deg_to_rad(50.0), 0.3, 99)
	check("a site's weather is reproducible", var_to_str(w.systems) == var_to_str(again.systems))
	var other := SurfaceWeather.new()
	other.setup(e, e.climate, deg_to_rad(50.0), 0.3, 100)
	check("another seed differs", var_to_str(w.systems) != var_to_str(other.systems))
	check("the climate gave it a storm population", w.systems.size() >= 3)
	var rain := 0.0
	var wet_hours := 0
	var count := 0
	var max_cover := 0.0
	var dt := 3600.0
	var climate_before := var_to_str([e.climate.T, e.climate.ice, e.climate.clouds, e.climate.pressures, e.climate.ocean, e.climate.time])
	for i in 24 * 365:
		w.step(dt)
		var n := w.now()
		rain += float(n.rain_mm_h)
		if float(n.rain_mm_h) > 0.1: wet_hours += 1
		max_cover = maxf(max_cover, float(n.cover))
		count += 1
	var yearly := rain * dt / 3600.0
	print("SURFACECHECK a year at 50°N: %.0f mm, wet %.0f%% of hours, cover up to %.2f; climate rain %.0f mm" % [yearly, 100.0 * wet_hours / count, max_cover, w.rain_mm_yr])
	check("a year's rain at a storm track is within a factor of three of the climate's (%.0f, %.0f mm)" % [yearly, w.rain_mm_yr], yearly > w.rain_mm_yr / 3.0 and yearly < w.rain_mm_yr * 3.0)
	check("it does not rain all the time", float(wet_hours) / count < 0.6)
	check("a storm darkens the sky", max_cover > w.clear_cover + 0.1)
	check("weather changes nothing in the climate", climate_before == var_to_str([e.climate.T, e.climate.ice, e.climate.clouds, e.climate.pressures, e.climate.ocean, e.climate.time]))
	# Worlds with nothing to rain.
	var mars_b: Body = stage.state.body_named("Mars")
	var wm := SurfaceWeather.new()
	wm.setup(mars_b, mars_b.climate, 0.3, 0.1, 5)
	wm.step(86400.0)
	check("a dry world has wind and no rain", float(wm.now().rain_mm_h) == 0.0 and float(wm.now().wind) > 0.0)
	var moon_b: Body = stage.state.body_named("Moon")
	var wn := SurfaceWeather.new()
	wn.setup(moon_b, moon_b.climate, 0.3, 0.1, 5)
	wn.step(86400.0)
	check("an airless world has no weather at all", float(wn.now().wind) == 0.0 and float(wn.now().cover) == 0.0 and wn.systems.is_empty())

# TERRAIN: drainage laws no constant here was set to.
func flow_length(run: Dictionary, n: int, dx: float) -> Array:
	# Each cell's longest upstream path, along the stack in reverse.
	var length := PackedFloat32Array()
	length.resize(n * n)
	var stack: PackedInt32Array = run.stack
	var recv: PackedInt32Array = run.recv
	for i in range(n * n - 1, -1, -1):
		var c := stack[i]
		var r := recv[c]
		if r == c: continue
		var d := dx if c % n == r % n or c / n == r / n else dx * 1.41421356
		if length[c] + d > length[r]: length[r] = length[c] + d
	return [length]

func regression(xs: Array, ys: Array) -> Array:
	var n := float(xs.size())
	var sx := 0.0; var sy := 0.0; var sxx := 0.0; var sxy := 0.0
	for i in xs.size():
		sx += xs[i]; sy += ys[i]; sxx += xs[i] * xs[i]; sxy += xs[i] * ys[i]
	var m := (n * sxy - sx * sy) / (n * sxx - sx * sx)
	return [m, (sy - m * sx) / n]

func strahler(run: Dictionary, n: int, area_min: float) -> Dictionary:
	var area: PackedFloat32Array = run.area
	var recv: PackedInt32Array = run.recv
	var stack: PackedInt32Array = run.stack
	var order := PackedInt32Array()
	order.resize(n * n)
	var best := PackedInt32Array(); best.resize(n * n)
	var twice := PackedByteArray(); twice.resize(n * n)
	var streams := {}
	for i in range(n * n - 1, -1, -1):
		var c := stack[i]
		if area[c] < area_min: continue
		var o := 1 if best[c] == 0 else (best[c] + 1 if twice[c] == 1 else best[c])
		order[c] = o
		var r := recv[c]
		if r == c or area[r] < area_min:
			streams[o] = int(streams.get(o, 0)) + 1
			continue
		if o > best[r]:
			# The stream of order `best[r]` ends here, if there was one; an order's count is its heads.
			best[r] = o
			twice[r] = 0
		elif o == best[r]:
			twice[r] = 1
		# A stream of this order ends where it joins one of a higher order.
	# Count streams by the cells where the order changes along the flow.
	streams.clear()
	for k in n * n:
		if area[k] < area_min: continue
		var r2 := recv[k]
		if r2 == k or area[r2] < area_min or order[r2] != order[k]:
			streams[order[k]] = int(streams.get(order[k], 0)) + 1
	return streams

func drainage() -> void:
	var n := 129
	var dx := 100.0
	var relief := SurfaceRelief.new()
	var u := 1.0e-3
	var k := 2.0e-5
	var run := relief.run_steady(n, dx, u, k, 120, 2000.0, 11)
	# Steady state: S = (U/K) A^(−m/n), the law's own analytic answer.
	var xs := []
	var ys := []
	var resid := 0.0
	var count := 0
	var h: PackedFloat32Array = run.h
	var recv: PackedInt32Array = run.recv
	var area: PackedFloat32Array = run.area
	var base: PackedByteArray = run.base
	for c in n * n:
		var r := recv[c]
		if r == c or base[c] == 1 or area[c] < 1e6: continue
		var d := dx if c % n == r % n or c / n == r / n else dx * 1.41421356
		var s: float = (h[c] - h[r]) / d
		if s <= 0.0: continue
		xs.append(log(area[c]) / log(10.0))
		ys.append(log(s) / log(10.0))
		resid += absf(log(s / (u / k * pow(area[c], -0.5))))
		count += 1
	var fit := regression(xs, ys)
	print("SURFACECHECK steady slope-area: slope %.3f over %d cells, mean |ln(S/S_law)| %.3f" % [fit[0], count, resid / count])
	check("rivers settle on S ∝ A^(−0.5): measured exponent %.3f" % fit[0], near(fit[0], -0.5, 0.05))
	check("and on the law's own S = (U/K) A^−½, within 10%% (%.3f)" % (resid / count), resid / count < 0.10)
	# Hack's law, over the basins that reach a boundary.
	var length: PackedFloat32Array = flow_length(run, n, dx)[0]
	var hx := []
	var hy := []
	for c in n * n:
		if area[c] < 1e5: continue
		hx.append(log(area[c]) / log(10.0))
		hy.append(log(maxf(length[c], dx)) / log(10.0))
	var hack := regression(hx, hy)
	print("SURFACECHECK Hack's exponent %.3f over %d cells" % [hack[0], hx.size()])
	check("Hack's exponent is near real rivers' 0.57 (%.3f)" % hack[0], hack[0] > 0.48 and hack[0] < 0.68)
	var streams := strahler(run, n, 2.5e5)
	var orders: Array = streams.keys()
	orders.sort()
	var ratio_sum := 0.0
	var ratio_n := 0
	for o in orders:
		if streams.has(o + 1) and int(streams[o + 1]) >= 2:
			ratio_sum += float(streams[o]) / float(streams[o + 1])
			ratio_n += 1
	var rb := ratio_sum / maxf(ratio_n, 1)
	print("SURFACECHECK Strahler %s, bifurcation %.2f" % [var_to_str(streams).replace("\n", ""), rb])
	check("the bifurcation ratio is real rivers' 3–5 (%.2f)" % rb, ratio_n >= 1 and rb >= 2.8 and rb <= 5.5)
	# K as the world sets it.
	var a := SurfaceRelief.new()
	a.flowing = true; a.rain_mm = 990.0; a.g = SurfaceRelief.G_EARTH
	var b := SurfaceRelief.new()
	b.flowing = true; b.rain_mm = 990.0; b.g = 3.72
	check("stream power goes with gravity", near(b.erodibility() / a.erodibility(), 3.72 / SurfaceRelief.G_EARTH, 1e-9))
	b.g = SurfaceRelief.G_EARTH; b.rain_mm = 247.5
	check("and as the square root of rain", near(b.erodibility() / a.erodibility(), 0.5, 1e-9))
	b.flowing = false
	check("nothing flowing, nothing carved", b.erodibility() == 0.0)

func relief_of(g: float, flowing: bool, sea: bool) -> SurfaceRelief:
	var r := PlanetRelief.new()
	r.seed = 21.0
	r.crust_t = Terrain.crust_threshold(0.5)
	var s := SurfaceRelief.new()
	s.relief = r
	s.center = Vector3(0.3, 0.5, 0.81).normalized()
	s.east = Vector3.UP.cross(s.center).normalized()
	s.north = s.center.cross(s.east).normalized()
	s.g = g
	s.radius_m = 6.0e6
	s.seed = 33
	s.cells = 65
	s.has_sea = sea
	s.flowing = flowing
	s.rain_mm = 990.0 if flowing else 0.0
	s.build()
	return s

func spread(h: PackedFloat32Array, n: int) -> float:
	# Local relief: deviation of each cell from its neighbourhood's mean, which the crust's own broad
	# shape doesn't enter.
	var sum := 0.0
	var count := 0
	for y in range(2, n - 2, 2):
		for x in range(2, n - 2, 2):
			var c := y * n + x
			var mean := (h[c - 2] + h[c + 2] + h[c - 2 * n] + h[c + 2 * n]) * 0.25
			sum += pow(h[c] - mean, 2.0)
			count += 1
	return sqrt(sum / count)

func terrain() -> void:
	var started := Time.get_ticks_msec()
	var earth_like := relief_of(9.82, false, false)
	print("SURFACECHECK PROFILE relief_build_65_ms=%d" % (Time.get_ticks_msec() - started))
	# The worst case for time: running water, at each quality's grid.
	for cells in SurfaceSite.CELLS.values():
		var rq := relief_of(9.82, false, false)
		rq.cells = cells
		rq.flowing = true
		rq.rain_mm = 990.0
		started = Time.get_ticks_msec()
		rq.build()
		print("SURFACECHECK PROFILE survey_cells_%d_ms=%d" % [cells, Time.get_ticks_msec() - started])
	var mars_like := relief_of(3.72, false, false)
	var e_rel := spread(earth_like.grids[0].h, 65)
	var m_rel := spread(mars_like.grids[0].h, 65)
	var ratio := m_rel / e_rel
	print("SURFACECHECK local relief Earth %.1f m, Mars's gravity %.1f m, ratio %.2f" % [e_rel, m_rel, ratio])
	check("relief goes as 1/g: Mars's gravity stands %.2f times Earth's (Olympus Mons / Everest: 2.5)" % ratio, near(ratio, 2.5, 0.7))
	var carved := relief_of(9.82, true, false)
	var c_rel := spread(carved.grids[1].h, 65)
	var d_rel := spread(earth_like.grids[1].h, 65)
	check("the same ground, wet and dry, differ (%.1f, %.1f m)" % [c_rel, d_rel], absf(c_rel - d_rel) > 0.01 * d_rel)
	var max_a := 0.0
	for v in carved.channel_far: max_a = maxf(max_a, v)
	check("water gathers: the far grid's biggest river drains over 100 km² (10^%.1f m²)" % max_a, max_a > 8.0)
	check("reproducible", spread(relief_of(9.82, true, false).grids[0].h, 65) == spread(carved.grids[0].h, 65))
	var sea := relief_of(9.82, true, true)
	var hh: PackedFloat32Array = sea.grids[1].h
	var above := 0
	for v in hh:
		if v > 0.0: above += 1
	check("a world with a sea has both, or says why", above > 0)
	var crust_h := relief_of(9.82, false, false)
	var dir0 := crust_h.relief.height(crust_h.center).x * 1000.0
	# The crust stands in the middle of the grids, give or take the roughness and creep added.
	check("the grid stands on the planet's own crust (%.0f m, %.0f m)" % [SiteScene.sample(crust_h.grids, 0.0, 0.0), dir0], near(SiteScene.sample(crust_h.grids, 0.0, 0.0), dir0, 900.0))
	check("no NaN in a built grid", _finite(crust_h.grids[0].h) and _finite(crust_h.grids[1].h))
	# Cancelling is prompt and leaves nothing half-built.
	var c := SurfaceRelief.new()
	c.relief = crust_h.relief; c.center = crust_h.center; c.east = crust_h.east; c.north = crust_h.north; c.cells = 65; c.g = 9.82
	c.cancelled = true
	c.build()
	check("a cancelled survey has no grids", c.grids.is_empty())

func _finite(a: PackedFloat32Array) -> bool:
	for v in a:
		if not is_finite(v): return false
	return true

# THE PROOF: nothing of the surface runs, or stays, anywhere else.
func nothing_elsewhere() -> void:
	SurfaceStats.reset()
	new_stage("solar")
	stage.state.paused = false
	stage.set_time_scale(0.01)
	var s: Showcase = stage.showcase
	check("no visit exists on the orrery", s.visit == null)
	for i in 120: stage.animate(1.0 / 60.0)
	check("orrery: nothing of the surface ran (%d)" % SurfaceStats.total(), SurfaceStats.total() == 0)
	stage.set_cam_mode("free")
	for i in 30: stage.animate(1.0 / 60.0)
	stage.set_cam_mode("orbit")
	check("free camera: nothing ran", SurfaceStats.total() == 0)
	# Even the showcase, until someone stands there.
	stage.set_app_mode("showcase", {"body": "Earth"})
	for i in 240: stage.animate(1.0 / 60.0)
	check("a showcase and its pin allocate no surface", SurfaceStats.total() == 0 and s.visit == null)
	stage.set_app_mode("sandbox")
	# Flight and the Observatory.
	new_stage("solar")
	stage.state.paused = false
	stage.last_craft = "falcon9"
	stage.set_app_mode("flight", {"direct": true})
	for i in 90: stage.animate(1.0 / 60.0)
	check("flight: nothing of the surface ran (%d)" % SurfaceStats.total(), SurfaceStats.total() == 0)
	stage.set_app_mode("sandbox")
	stage.set_app_mode("observatory", {"direct": true})
	for i in 60: stage.animate(1.0 / 60.0)
	check("the Observatory: nothing ran (%d)" % SurfaceStats.total(), SurfaceStats.total() == 0)
	stage.set_app_mode("sandbox")
	new_stage("solar")

	# A visit, and what it leaves behind.
	for i in 30: stage.animate(1.0 / 60.0)
	await get_tree().process_frame
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objects0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var resources0 := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
	var earth: Body = stage.state.body_named("Earth")
	for visit_i in 3:
		await visit_and_leave(earth, visit_i + 1)
		for i in 10: stage.animate(1.0 / 60.0)
		await get_tree().process_frame
		await get_tree().process_frame
		var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		var objects := Performance.get_monitor(Performance.OBJECT_COUNT)
		var resources := Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)
		print("SURFACECHECK after visit %d: nodes %+d, objects %+d, resources %+d" % [visit_i + 1, nodes - nodes0, objects - objects0, resources - resources0])
		check("visit %d left no nodes (%+d)" % [visit_i + 1, nodes - nodes0], absf(nodes - nodes0) <= 1.0)
		if visit_i > 0:
			check("visit %d left no resources beyond the first's shader cache (%+d)" % [visit_i + 1, resources - resources0], resources - resources0 <= 8.0)
	var before_quiet := SurfaceStats.total()
	for i in 60: stage.animate(1.0 / 60.0)
	check("after leaving, nothing runs (%d more)" % (SurfaceStats.total() - before_quiet), SurfaceStats.total() == before_quiet)

func visit_and_leave(b: Body, n: int) -> void:
	stage.set_app_mode("showcase", {"body": b.name})
	var s: Showcase = stage.showcase
	s.pins_dropped = n - 1
	s.drop_pin()
	s.stand()
	await settle_visit()
	for i in 20: stage.animate(1.0 / 60.0)
	s.leave_surface()
	stage.set_app_mode("sandbox")

func settle_visit() -> void:
	var v: SurfaceVisit = stage.showcase.visit
	if v == null: return
	if v.site != null: v.site.finish_now()
	for i in 4: stage.animate(1.0 / 60.0)
	await get_tree().process_frame

# Surface weather and terrain must not touch the world.
func no_feedback() -> void:
	var run := func(on_foot: bool) -> String:
		new_stage("solar")
		stage.state.paused = false
		stage.set_time_scale(0.001)
		var earth: Body = stage.state.body_named("Earth")
		stage.set_app_mode("showcase", {"body": "Earth"})
		stage.showcase.drop_pin()
		stage.state.paused = true
		if on_foot:
			stage.showcase.stand()
			stage.state.paused = true
			stage.showcase.visit.site.finish_now()
			for i in 5: stage.animate(1.0 / 60.0)
		for i in 300: stage.step_physics(0.0005)
		if on_foot:
			# Its weather and sea run on, on the same clock, and write nothing.
			for i in 30: stage.showcase.visit.update(1.0 / 60.0, 0.001)
		var out := []
		for b: Body in stage.state.bodies:
			out.append([b.name, b.pos.to_array(), b.vel.to_array(), b.mass, b.spin_omega])
			if b.climate != null: out.append([b.climate.T, b.climate.ice, b.climate.clouds, b.climate.ocean, b.climate.humidity, b.climate.time])
		if on_foot: stage.showcase.leave_surface()
		stage.set_app_mode("sandbox")
		earth = earth
		return var_to_str(out)
	var plain: String = run.call(false)
	var visited: String = run.call(true)
	check("standing on a world changes no orbit, spin or climate, bit for bit", plain == visited)

# Real flows: through the showcase, onto the surface, with what each world gives.
func extremes() -> void:
	new_stage("solar")
	var cases := [
		["Earth", "mapped, wet", null],
		["Mars", "mapped, dry, thin", null],
		["Venus", "dense", null],
		["Moon", "airless", null],
		["Pluto", "cold, thin", null],
	]
	for row in cases:
		await stand_on(stage.state.body_named(row[0]), row[1])
	var ball := spawn_world("ocean", 1.0, "Ball")
	var site := await stand_on(ball, "global ocean", 2)
	spawn_world("ocean", 2.6, "Shell")
	site = await stand_on(stage.state.body_named("Shell"), "ice shell", 2)
	spawn_world("earth", 1.0, "Terra", {"land": 0.5})
	await stand_on(stage.state.body_named("Terra"), "continents", 3)
	spawn_world("mars", 1.5, "Dust")
	await stand_on(stage.state.body_named("Dust"), "thin and dry")
	var light := {"type": "planet", "mass": 3.0e-8, "name": "Small", "seed": 5, "obliquity": 0.2}
	light.merge(Composition.MIXES.earth.inputs)
	light.pos = DVec3.new(1.0, 0.0, 0.0).to_array()
	light.vel = [0.0, Physics.circular_speed(1.0, 1.0), 0.0]
	stage.spawn_body(light)
	for i in 3: stage.animate(1.0 / 60.0)
	await stand_on(stage.state.body_named("Small"), "low gravity", 2)
	# No stars at all.
	new_stage("blank")
	stage.spawn_body({"type": "planet", "mass": 3e-6, "name": "Rogue", "seed": 8, "pos": [0.0, 0.0, 0.0], "vel": [0.0, 0.0, 0.0], "oceans": false, "pN2": 1.0})
	for i in 3: stage.animate(1.0 / 60.0)
	await stand_on(stage.state.body_named("Rogue"), "no stars")
	# True scale stays what it was.
	new_stage("solar")
	stage.set_true_scale(false)
	await stand_on(stage.state.body_named("Earth"), "from boosted sizes", 4)
	check("boosted sizes came back", not stage.state.true_scale)
	stage.set_true_scale(true)
	await stand_on(stage.state.body_named("Earth"), "from true scale", 5)
	check("true scale stayed", stage.state.true_scale)
	stage.set_true_scale(false)

func stand_on(b: Body, label: String, pin_n := 1) -> SurfaceSite:
	var s: Showcase = stage.showcase
	var before := {"home": stage.state.home_id, "cam": stage.state.cam_mode, "scale": stage.state.true_scale}
	stage.set_app_mode("showcase", {"body": b.name})
	s.pins_dropped = pin_n - 1
	s.drop_pin()
	s.stand()
	check("%s: the survey starts from orbit" % label, s.visit != null and stage.state.cam_mode == "orbit")
	await settle_visit()
	check("%s: a visit began" % label, s.visit != null and stage.state.cam_mode == "surface")
	var v: SurfaceVisit = s.visit
	var site: SurfaceSite = v.site
	check("%s: the site is built" % label, site != null and site.built)
	for i in 8: stage.animate(1.0 / 60.0)
	var started := Time.get_ticks_usec()
	for i in 60: v.update(1.0 / 60.0, 1e-6)
	print("SURFACECHECK PROFILE %s visit_update_us=%d" % [label, (Time.get_ticks_usec() - started) / 60])
	var r := v.readouts()
	check("%s: the site stands where the pin said (%.0f m, %.0f m)" % [label, r.height, s.pin.ground.height_m], s.pin.ground.kind in ["sea", "sea ice"] or near(r.height, float(s.pin.ground.height_m), 0.7 * SurfaceRelief.ROUGH_M * minf(SurfaceRelief.G_EARTH / cl_gravity(b), SurfaceRelief.MAX_ROUGH) + 400.0))
	var fine := true
	for k in r:
		if r[k] is float and not is_finite(r[k]): fine = false
	check("%s: every readout is finite" % label, fine)
	print("SURFACECHECK %s, %s: %s T=%.0f K p=%s bar g=%.2f h=%.0f m wind=%.1f hs=%.2f period=%.1f tide=%.3f rain=%.2f cover=%.2f" % [b.name, label, pin_text(s), r.temp, U.prec(float(r.pressure), 3), r.gravity, r.height, r.wind, r.hs, r.period, r.tide, r.rain, r.cover])
	var cl: Climate = b.climate
	check("%s: gravity is this world's" % label, near(r.gravity, cl.gravity, 1e-9))
	if cl.air.p_dry < Climate.AIRLESS_BAR and cl.steam <= 0.0:
		check("%s: no air, no wind" % label, r.wind == 0.0 and r.cover == 0.0)
	if not cl.wet:
		check("%s: dry, no rain" % label, r.rain == 0.0)
		check("%s: dry, nothing carved by water" % label, not site.relief.flowing)
		check("%s: dry, no sea" % label, not r.has_sea and site._ocean == null)
	if r.has_sea and float(r.hs) > 0.0 and r.wind > 0.5:
		var want := SurfaceWaves.developed_hs(float(r.wind), cl.gravity)
		check("%s: the sea stands no higher than this wind and gravity allow (%.2f, %.2f m)" % [label, r.hs, want], r.hs < want * 1.3)
	s.leave_surface()
	stage.set_app_mode("sandbox")
	check("%s: leaving ends the visit" % label, s.visit == null and stage.state.cam_mode == before.cam)
	check("%s: home is what it was" % label, stage.state.home_id == before.home)
	check("%s: size convention is what it was" % label, stage.state.true_scale == before.scale)
	check("%s: the world is drawn again" % label, b.viz == null or b.viz.group.visible)
	return site

func cl_gravity(b: Body) -> float:
	return b.climate.gravity

func pin_text(s: Showcase) -> String:
	return str(s.pin.ground.kind) if s.pin != null else ""

# How the mode meets the rest of the app while on foot.
func manners() -> void:
	new_stage("solar")
	var earth: Body = stage.state.body_named("Earth")
	stage.set_app_mode("showcase", {"body": "Earth"})
	stage.showcase.drop_pin()
	stage.showcase.stand()
	await settle_visit()
	var clock: float = stage.state.time_scale
	stage.set_cam_mode("orbit")
	stage.animate(1.0 / 60.0)
	check("switching the camera off the surface ends the visit", stage.showcase.visit == null)
	check("and keeps the showcase", stage.showcase.active)
	stage.showcase.stand()
	await settle_visit()
	stage.load_preset("sandbox")
	stage.set_process(false)
	check("another scenario ends the visit and the mode", stage.showcase.visit == null and not stage.showcase.active and stage.state.cam_mode == "orbit")
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Earth"})
	stage.showcase.drop_pin()
	stage.showcase.stand()
	await settle_visit()
	stage.remove_body(stage.state.body_named("Earth").id)
	stage.animate(1.0 / 60.0)
	check("removing the world ends the visit", stage.showcase.visit == null and stage.state.cam_mode == "orbit")
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Earth"})
	stage.showcase.drop_pin()
	stage.showcase.stand()
	# Leaving mid-survey: the worker is told to stop, and the view never moved.
	stage.showcase.leave_surface()
	check("leaving during the survey is clean", stage.showcase.visit == null and stage.state.cam_mode == "orbit" and stage.state.home_id == null)
	stage.set_app_mode("sandbox")
	new_stage("solar")
	stage.set_app_mode("showcase", {"body": "Earth"})
	stage.showcase.stand()
	check("standing with no pin drops one first", stage.showcase.pin != null and stage.showcase.visit != null)
	await settle_visit()
	stage.showcase.leave_surface()
	stage.set_app_mode("flight", {"direct": true})
	check("flight from a showcase cleans up", not stage.showcase.active)
	stage.set_app_mode("sandbox")
	new_stage("solar")
	clock = clock
	earth = earth

# PIXELS
const SITES := [
	["Earth-like land", "earth", 1.0, {"land": 0.6, "pCO2": 0.002}, "land", 3],
	["Clear", "earth", 1.0, {"land": 0.6, "pCO2": 0.002, "cloudCover": 0.0}, "land", 3],
	["Storm", "earth", 1.0, {"land": 0.1, "pCO2": 0.002}, "sea", 2],
	["Earth-like sea", "earth", 1.0, {"land": 0.1, "pCO2": 0.002}, "sea", 2],
	["Mars-like", "mars", 1.5, {}, "land", 1],
	["Venus-like", "venus", 0.72, {}, "land", 1],
	["Snowball", "ocean", 2.6, {}, "ice", 1],
	["Airless", "bare", 1.0, {}, "land", 1],
]

func pixels() -> void:
	var seen := {}
	for row in SITES:
		seen[row[0]] = await shoot(row)
	var ground: Dictionary = seen["Earth-like land"]
	var clear: Dictionary = seen["Clear"]
	var sea: Dictionary = seen["Earth-like sea"]
	var storm: Dictionary = seen["Storm"]
	check("a storm darkens the sea's sky and raises its sea (%.2f, %.2f m)" % [storm.hs, sea.hs], storm.hs > sea.hs)
	check("and it rains (%.2f mm/h)" % storm.rain, storm.rain > 0.1)
	var mars: Dictionary = seen["Mars-like"]
	var moon: Dictionary = seen["Airless"]
	var ice: Dictionary = seen["Snowball"]
	check("a day's sky over Earth's air is blue over red (%.3f, %.3f)" % [clear.sky.z, clear.sky.x], clear.sky.z > clear.sky.x)
	check("an airless sky is black (%.3f)" % moon.sky.length(), moon.sky.length() < 0.1)
	check("airless sky is darker than any with air", moon.sky.length() < ground.sky.length() * 0.3)
	check("ground is drawn: the lower frame is not sky", ground.ground_var > 0.0001)
	check("snow is bright (%.2f)" % ice.ground_lum, ice.ground_lum > ground.ground_lum)
	check("the sea moves: two moments differ (%.4f)" % sea.moved, sea.moved > 0.0005)
	check("rock stands still under the same clock (%.4f)" % moon.moved, moon.moved < sea.moved)

func shoot(row: Array) -> Dictionary:
	new_stage("blank")
	stage.state.show_mesh = false
	stage.state.show_lens = false
	stage.hud.set_hud_hidden(true)
	var lamp: Body = stage.spawn_body({"type": "star", "mass": 1.0, "name": "Lamp", "radiusKm": 696000.0})
	lamp = lamp
	var b := spawn_world(row[1], row[2], "World", row[3])
	for i in 300: b.climate.step(1.0, b, [lamp])
	for i in 3: stage.animate(1.0 / 60.0)
	# The first pin of the kind asked for.
	var pin_n := 1
	var want: String = row[4]
	for n in range(1, 40):
		var kind: String = PlanetPin.drop(b, n, 0).ground.kind
		if (want == "land" and kind == "land") or (want == "sea" and kind == "sea") or (want == "ice" and kind in ["sea ice", "ice sheet"]):
			pin_n = n
			break
	stage.set_app_mode("showcase", {"body": "World"})
	var s: Showcase = stage.showcase
	s.pins_dropped = pin_n - 1
	s.drop_pin()
	s.stand()
	await settle_visit()
	if row[0] == "Clear": s.visit.site.weather.systems.clear()
	# A storm right over the pin, at the height of its life, to see its rain and sea.
	if row[0] == "Storm":
		var wx: SurfaceWeather = s.visit.site.weather
		for sys: Dictionary in wx.systems:
			sys.lat = wx.lat; sys.lon = wx.lon
			sys.born = wx._age - 0.5 * float(sys.life)
	# The Sun up: bring the clock to a daytime for this pin, by turning the world under it.
	s.visit.turn_to_noon(0.65)
	stage.observer.azimuth = 0.9
	stage.observer.elevation = 0.04
	var started := Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 1500:
		stage.state.paused = true
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var a := get_viewport().get_texture().get_image()
	if args.has("out"): a.save_png("%s/site_%s_%s.png" % [args.out, row[0].replace(" ", "_"), args.get("quality", "medium")])
	started = Time.get_ticks_msec()
	while Time.get_ticks_msec() - started < 700:
		stage.animate(1.0 / 60.0)
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var c := get_viewport().get_texture().get_image()
	var w := a.get_width(); var h := a.get_height()
	var sky := Vector3.ZERO
	var count := 0
	for y in range(10, int(h * 0.2), 8):
		for x in range(10, w, 8):
			var p := a.get_pixel(x, y).srgb_to_linear()
			sky += Vector3(p.r, p.g, p.b)
			count += 1
	sky /= count
	var lum_sum := 0.0
	var lum2 := 0.0
	var moved := 0.0
	count = 0
	for y in range(int(h * 0.65), h - 4, 6):
		for x in range(4, w - 4, 6):
			var p := a.get_pixel(x, y)
			var q := c.get_pixel(x, y)
			var l := p.get_luminance()
			lum_sum += l
			lum2 += l * l
			moved += absf(l - q.get_luminance())
			count += 1
	var mean := lum_sum / count
	var rd: Dictionary = s.visit.readouts()
	var result := {"hs": float(rd.hs), "rain": float(rd.rain), "sky": sky, "ground_lum": mean, "ground_var": lum2 / count - mean * mean, "moved": moved / count}
	print("SURFACECHECK PIXELS %-16s sky %.3f %.3f %.3f ground lum %.3f var %.5f moved %.4f %s" % [row[0], sky.x, sky.y, sky.z, mean, result.ground_var, result.moved, s.pin.ground.text])
	s.leave_surface()
	stage.set_app_mode("sandbox")
	return result

func _ready() -> void:
	OS.add_logger(catcher)
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	stage = load("res://main.tscn").instantiate()
	add_child(stage)
	for i in 2: await get_tree().process_frame
	stage._start("sandbox")
	stage.set_process(false)
	if args.has("quality"): stage.set_render_quality(args.quality)
	if args.get("pixels", "0") == "1":
		await pixels()
	else:
		waves()
		tides()
		weather()
		drainage()
		terrain()
		await nothing_elsewhere()
		await no_feedback()
		await extremes()
		await manners()
	for i in 3: await get_tree().process_frame
	for error in catcher.take(): check("engine: " + str(error), false)
	print("SURFACECHECK DONE checks=%d failures=%d" % [checks, failures])
	get_tree().quit(1 if failures else 0)
