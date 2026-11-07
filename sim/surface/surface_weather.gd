class_name SurfaceWeather
extends RefCounted

# Synoptic weather at one site, with the scales taken from the world: the Hadley cell's width, the
# Rossby radius and Eady growth rate set where storms form, how big they are and how fast they
# grow, and they drift on the thermal wind. It draws on the climate and never writes to it.
# docs/physics/surface.md#weather. SI. Exists only while someone stands on the world.

# Lindzen & Farrell (1980), the Eady maximum.
const EADY := 0.31
# Eady's fastest wave is 2π/1.61 Rossby radii long.
const EADY_WAVELENGTHS := 3.90
# A cyclone's life in Eady e-folds. Puts Earth's at the 4 days of Sharkey et al. (2019).
const LIFE_EFOLDS := 1.4
# The troposphere's stability against dry adiabatic: N² = (g²/c_pT)(1 − Γ/Γ_d). Earth's 6.5 K/km of
# 9.8 is Γ/Γ_d = 0.66; dry worlds, without latent heat, sit nearer 0.4 (Mars's N in Rees & Garrett).
const LAPSE_WET := 0.66
const LAPSE_DRY := 0.4
# A surface wind from the energy budget: KE dissipated ρC_dU³ = ε(absorbed), with ε·/C_d pinned to
# Earth's about 7 m/s over 240 W/m². An estimate; a reference table is in the doc.
const WIND_EARTH := 7.0
const FLUX_EARTH := 240.0
const RHO_EARTH := 1.225
const FRONT_GUST := 2.2
const WIND_MAX_MACH := 0.08
# A storm only rains near its middle, where the air is rising hard. An estimate.
const RAIN_FROM := 0.25
const RAIN_FULL := 0.65
const WORLD_DAY_MIN_S := 3600.0

# What the world gives. All SI.
var g := 9.81
var radius := 6.371e6
var omega := 7.29e-5
var temp := 288.0
var air_bar := 1.0
var rho := 1.225
var cp := 1004.0
var scale_h := 8500.0
var wet := true
var has_air := true
var lat := 0.0
var lon := 0.0
var pole_equator_k := 40.0
var absorbed := 240.0
# Derived scales.
var brunt := 0.011
var tropo_h := 11000.0
var hadley := 0.45
var storm_lat := 0.8
var coriolis := 1e-4
var shear := 0.002
var rossby := 1.0e6
var wavelength := 3.9e6
var eady_rate := 6e-6
var life_s := 3.4e5
var drift := 12.0
var wind_mean := 7.0
var sound := 340.0
var rain_mm_yr := 990.0
var clear_cover := 0.44
# Today's systems: [{lat, lon, born, life, size, sign, seed}], where lat and lon are radians.
var systems: Array = []
var _rng := RandomNumberGenerator.new()
var _next_id := 0
var _age := 0.0
var _span := 0.0

## Read a world, and draw its storm population from `seed`.
func setup(b: Body, cl: Climate, lat_r: float, lon_r: float, seed: int) -> void:
	g = cl.gravity
	radius = b.radius * Rocketry.AU_M
	var period := RockyVisual.sidereal_period_yr(b) * Rocketry.YR_S
	omega = TAU / maxf(period if period > 0.0 else 86400.0, WORLD_DAY_MIN_S)
	temp = maxf(cl.T, 30.0)
	air_bar = cl.air.p_dry + cl.steam * cl.steam_bar
	has_air = air_bar >= Climate.AIRLESS_BAR
	var molar: float = cl.air.mean_molar
	cp = Atmosphere.R_GAS / cl.air.kappa / molar
	sound = sqrt(cl.air.gamma * Atmosphere.R_GAS * temp / molar)
	rho = air_bar * 1e5 * molar / (Atmosphere.R_GAS * temp)
	scale_h = Atmosphere.R_GAS * temp / (molar * g)
	wet = cl.wet and cl.ocean + cl.steam > 0.0
	lat = lat_r
	lon = lon_r
	absorbed = (1.0 - float(cl.albedo(cl.T).alb)) * cl.S * Climate.S0 / 4.0
	pole_equator_k = _pole_equator(cl)
	rain_mm_yr = ClimateLook.precipitation_mm(cl)
	clear_cover = clampf(float(U.nz(b.spec.get("cloudCover"), ClimateLook.cover_of(cl))), 0.0, 1.0)
	derive()
	_rng.seed = seed
	systems.clear()
	_span = 2.0 * life_s
	_age = 0.0
	if has_air and eady_rate > 0.0:
		var count: int = clampi(int(round(TAU * radius * cos(storm_lat) / wavelength)), 1, 16)
		# Spread through their lives, so a visit does not start on a blank sky.
		for i in count:
			_spawn(-_rng.randf() * life_s)

func _pole_equator(cl: Climate) -> float:
	if not cl.wet: return 0.3 * temp
	var t: PackedFloat64Array = cl.ebm.T
	return absf(float(t[0]) - float(t[t.size() - 1]))

## The scales, from what setup read. Public so a check can hand it another planet.
func derive() -> void:
	var stable := LAPSE_WET if wet else LAPSE_DRY
	brunt = sqrt(maxf(g * g / (cp * temp) * (1.0 - stable), 0.0))
	# The tropopause, where the column has cooled to its stratosphere (Atmosphere.STRAT).
	var lapse := stable * g / cp
	tropo_h = (1.0 - Atmosphere.STRAT) * temp / maxf(lapse, 1e-5)
	# Rees & Garrett (2019, after Held 2000): φ_H ≈ √(NH/Ωa), with H the scale height.
	hadley = sqrt(brunt * scale_h / maxf(omega * radius, 1e-9))
	# Storms grow on the baroclinic flank just poleward of the descending branch.
	storm_lat = clampf(hadley + 0.26, 0.2, 1.35)
	coriolis = 2.0 * omega * sin(storm_lat)
	# Thermal wind across the pole-to-equator contrast over a quarter of the meridian.
	var dy := PI * 0.5 * radius
	var dtdy := pole_equator_k / dy
	shear = g / maxf(coriolis * temp, 1e-12) * dtdy
	rossby = brunt * tropo_h / maxf(coriolis, 1e-12)
	wavelength = EADY_WAVELENGTHS * rossby
	eady_rate = EADY * coriolis / maxf(brunt, 1e-9) * shear
	life_s = LIFE_EFOLDS / maxf(eady_rate, 1e-9)
	drift = minf(shear * tropo_h * 0.5, 100.0)
	# A thin air cannot keep the scaling's speed: dissipation is not the limit there, and a fraction of
	# the sound speed is (an estimate; Mars's air is near this, and Pluto's well past it).
	wind_mean = minf(surface_wind(absorbed, rho), WIND_MAX_MACH * sound)

## Surface wind scale, m/s: U³ ∝ absorbed/ρ, as dissipation balances the heat engine. None without air.
static func surface_wind(flux: float, density: float) -> float:
	if density <= 0.0: return 0.0
	return WIND_EARTH * pow(maxf(flux, 0.0) / FLUX_EARTH * RHO_EARTH / density, 1.0 / 3.0)

func _spawn(born: float) -> void:
	_next_id += 1
	var hemisphere := 1.0 if lat >= 0.0 else -1.0
	systems.append({
		"id": _next_id,
		"lat": hemisphere * clampf(storm_lat + _rng.randfn(0.0, 0.12), 0.05, 1.45),
		"lon": lon + _rng.randf_range(-PI, PI),
		"born": born,
		"life": life_s * _rng.randf_range(0.7, 1.3),
		"size": wavelength * 0.25 * _rng.randf_range(0.7, 1.3),
	})

## Advance the population by `dt` seconds of the world's time. Nothing outside this object moves.
func step(dt: float) -> void:
	if not has_air or systems.is_empty() and eady_rate <= 0.0: return
	_age += dt
	var dlon := drift * dt / maxf(radius * cos(storm_lat), 1.0) * (1.0 if omega >= 0.0 else -1.0)
	for i in range(systems.size() - 1, -1, -1):
		var s: Dictionary = systems[i]
		s.lon = wrapf(float(s.lon) + dlon, -PI, PI)
		if _age - float(s.born) > float(s.life):
			systems.remove_at(i)
			_spawn(_age)

## Distance from the site to a system, m.
func _distance(s: Dictionary) -> float:
	var a := sin(lat) * sin(float(s.lat)) + cos(lat) * cos(float(s.lat)) * cos(lon - float(s.lon))
	return radius * acos(clampf(a, -1.0, 1.0))

## How strong a system is now, 0..1: it grows and then decays.
func _strength(s: Dictionary) -> float:
	var t := clampf((_age - float(s.born)) / maxf(float(s.life), 1.0), 0.0, 1.0)
	return sin(PI * t)

## The weather at the site now: {cover, wind, wind_dir, rain_mm_h, kind, front, near_km, snow}.
## Rain's mean over a year is the climate's rain; storms concentrate it.
func now() -> Dictionary:
	var out := {"cover": 0.0, "wind": 0.0, "wind_dir": 0.0, "rain_mm_h": 0.0, "kind": "none", "front": 0.0, "near_km": -1.0, "snow": false}
	if not has_air: return out
	var influence := 0.0
	var near := INF
	var gust_dir := 0.0
	for s: Dictionary in systems:
		var d := _distance(s)
		var strength := _strength(s)
		var k := strength * exp(-0.5 * pow(d / float(s.size), 2.0))
		if k > influence:
			influence = k
			# The wind goes round a low: at right angles to the bearing to it, cyclonically.
			var bearing := atan2(float(s.lon) - lon, float(s.lat) - lat)
			gust_dir = bearing + (PI * 0.5 if lat >= 0.0 else -PI * 0.5)
		near = minf(near, d)
	var westerly := PI * 0.5 if absf(lat) >= hadley else -PI * 0.5
	out.wind_dir = lerp_angle(westerly, gust_dir, clampf(influence * 1.5, 0.0, 1.0))
	out.wind = wind_mean * (1.0 + FRONT_GUST * influence)
	out.near_km = near / 1000.0 if near < INF else -1.0
	out.front = influence
	# A dry world's storms lift dust, not clouds, and dust isn't modelled.
	out.cover = clampf(clear_cover + (1.0 - clear_cover) * influence, 0.0, 1.0) if wet else clear_cover
	if not wet: return out
	# A fair share of a year's rain arrives under systems: influence's mean over the track is about
	# the area share a system's Gaussian covers, so rain under a storm is mean/share.
	var share := clampf(float(systems.size()) * 2.0 * PI * pow(wavelength * 0.25, 2.0) / maxf(4.0 * PI * radius * radius, 1.0), 0.02, 1.0)
	out.rain_mm_h = rain_mm_yr / (365.25 * 24.0) * smoothstep(RAIN_FROM, RAIN_FULL, influence) / share
	out.snow = temp - 6.5 * 0.5 < 271.0 and float(out.rain_mm_h) > 0.0
	out.kind = "rain" if float(out.rain_mm_h) > 0.05 and not out.snow else ("snow" if out.snow else "none")
	return out
