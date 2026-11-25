class_name TitanMoon
extends RefCounted

# Titan about Saturn: approximate mean elements, not an ephemeris, on a circular orbit in Saturn's equatorial
# plane. Its orbit, mass and radius from NASA's planetary satellite factsheet; its air at the surface from
# Huygens (Fulchignoni et al. 2005: 1467 hPa, 93.65 K). Dry to its climate: its northern seas are stated where
# Cassini mapped them (StatedSeas), not drawn by the crust.

const A_KM := 1221870.0
const MASS_KG := 1.3452e23
const RADIUS_KM := 2574.73

## Replace Saturn's spec with Saturn and Titan, preserving the total mass, position and momentum.
static func system(saturn: Dictionary) -> Array:
	var planet := saturn.duplicate(true)
	var m := MASS_KG / 1.98847e30
	planet.mass -= m
	var titan := around(planet, m)
	var out: Array = [planet, titan]
	for field in ["pos", "vel"]:
		for axis in 3:
			var offset := m / float(saturn.mass) * (float(titan[field][axis]) - float(saturn[field][axis]))
			for body: Dictionary in out: body[field][axis] -= offset
	return out

static func around(saturn: Dictionary, m: float) -> Dictionary:
	var pole: Array = Rocketry.POLES.Saturn
	var north := Rocketry.equatorial_dir(deg_to_rad(pole[0]), deg_to_rad(pole[1]))
	var frame := DQuat.new().set_from_unit_vectors(DVec3.new(0, -1, 0), north)
	var a := A_KM * Physics.AU_PER_KM
	var phase := 4.24
	var speed := Physics.circular_speed(float(saturn.mass) + m, a)
	var pos := DQuat.rotate(DVec3.new(cos(phase) * a, 0, sin(phase) * a), frame)
	var vel := DQuat.rotate(DVec3.new(-sin(phase) * speed, 0, cos(phase) * speed), frame)
	var surface_bar := 1.467
	return {"type": "planet", "name": "Titan", "mass": m, "radiusKm": RADIUS_KM, "hot": true,
		"oceans": false, "land": 1.0, "oceanDepth": 0.0, "mixedLayer": Presets.DRY_LAYER_M,
		# The whole column as nitrogen: the climate's gas fits know methane only at Earth's trace (ClimateInputs'
		# domain stops at 1 mbar), and the surface temperature is stated below anyway. The flight's air
		# (Rocketry.ATMOSPHERES.Titan) and the entry's glow (PlasmaSpectrum) carry the methane.
		"atmosphere": true, "pN2": surface_bar, "pCH4": 0.0, "pO2": 0.0, "pAr": 0.0, "pCO2": 0.0, "pSO2": 0.0,
		# Stated: the haze's warming and anti-greenhouse are not in the gas column, and its colour is the haze's.
		"surfaceK": 93.65, "atmColor": 0xd9a24a, "haze": 2.0, "cloudCover": 0.05,
		"crater": 0.05, "regolith": 0x9a7a3c, "albedo": 0.22, "obliquity": 0.0055, "tidalLock": "Saturn",
		# Its thick, slow air carries the heat poleward: Cassini's CIRS finds the poles only 2–4 K colder than
		# the 93.7 K equator (Jennings et al. 2016), which this transport gives; the default leaves Ligeia frozen.
		"transport": 0.87,
		# Lorenz et al. 2013's map: its highest gridded point 520 m over the 2575 km sphere and its lowest 1.7 km under;
		# Corlies et al. 2017's new mountains none over 700 m. Half a kilometre from the datum to its broad rises.
		"landRelief": 0.5,
		# The equatorial sand seas: linear dunes 100–150 m high and about 1 km wide, 1–4 km apart with flat
		# interdunes between, running roughly east–west within about 30° of the equator (Lorenz et al. 2006;
		# Radebaugh et al. 2008). 120 m, 3 km and 80° are a choice inside those.
		"dunes": {"height": 120.0, "width": 1000.0, "spacing": 3000.0, "bearing": 80.0, "band": 30.0},
		"pos": [float(saturn.pos[0]) + pos.x, float(saturn.pos[1]) + pos.y, float(saturn.pos[2]) + pos.z],
		"vel": [float(saturn.vel[0]) + vel.x, float(saturn.vel[1]) + vel.y, float(saturn.vel[2]) + vel.z]}
