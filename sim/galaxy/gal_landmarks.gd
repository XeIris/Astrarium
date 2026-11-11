class_name GalLandmarks
extends RefCounted

# The places worth flying to in a galactic scene, each with a card and its sources. Data
# with no scene access: where each one is (galaxy-local kpc) is worked out from the model
# at a time, and GalaxyScene labels them on screen and flies to them.
# docs/physics/galaxies.md#landmarks.
#
# `at` says how a landmark is placed:
# - "sun": the Sun, turning with its ring (GalNeighbourhood.sun_frame);
# - "origin": the galaxy's centre;
# - "bar": the galaxy's centre, labelled at `label_r` kpc along the bar toward its near end;
# - "spiral": a point on the spiral pattern at (R kpc, β°), β from the Sun–centre line
#   toward the rotation as Reid et al. (2019) measure it, turning with the pattern;
# - "sky": RA, Dec (ICRS degrees, from NED unless noted) and distance from the Sun (kpc),
#   placed from the Sun at t = 0 through the app's own galactic frame. Their own orbits
#   are not followed.
# `view`: the camera's distance from it (kpc) and its polar angle (rad, 0 = face-on). A
# sky landmark is seen from the Sun's side instead, as we see it.
# `v`: an apparent V magnitude from the Sun, for a compact object drawn as a point of that
# integrated light.

const MILKY_WAY := [
	{
		"id": "sun", "name": "The Sun", "short": "Sun", "at": "sun", "view": [0.001, 1.32],
		"card": "Our star, here 8 kpc from the centre (8.18 kpc measured: GRAVITY Collaboration 2019) and 20.8 pc above the plane (Bennett & Bovy 2019). It goes round the Galaxy in about 220 Myr. Around it are the real stars of our sky, at the distances Gaia and Hipparcos measured.",
	},
	{
		"id": "sgra", "name": "Sagittarius A*", "short": "Sgr A*", "at": "origin", "view": [0.3, 1.2],
		"card": "The black hole at the centre: 4.30 million solar masses, weighed by the orbits of the stars around it (GRAVITY Collaboration 2022). Its horizon is about 25 million km across, inside Mercury's orbit. At this scale it is a point, hidden by the bulge's dust.",
	},
	{
		"id": "bar", "name": "The bar", "short": "Bar", "at": "bar", "label_r": 3.0, "view": [16.0, 0.03],
		"card": "A bar of old stars 5 kpc long, its near end 27° ahead of the Sun–centre line (Bland-Hawthorn & Gerhard 2016), turning once in about 160 Myr, at 39 km/s/kpc (Portail et al. 2017). Here it is gravity first: its light is lost in the bright bulge.",
	},
	{
		"id": "perseus", "name": "Perseus Arm", "short": "Perseus Arm", "at": "spiral", "r": 8.87, "beta": 40.0, "view": [5.0, 0.35],
		"card": "One of the Galaxy's two major arms, 8.9 kpc from the centre where Reid et al. (2019) found it from maser parallaxes. An arm is a density wave: its pattern turns at 28 km/s/kpc (Dias et al. 2019), slower than the stars, which pass through it.",
	},
	{
		"id": "omegacen", "name": "ω Centauri", "short": "ω Cen", "at": "sky", "ra": 201.69699, "dec": -47.47947, "d": 5.43, "v": 3.50, "view": [0.5, 1.1],
		"card": "The Galaxy's most massive globular cluster: 3.94 million solar masses within a half-light radius of 7.6 pc, 5.43 kpc from the Sun (Baumgardt's catalogue; Baumgardt & Vasiliev 2021). Drawn as one point of its measured light, V = 3.5 from the Sun.",
	},
	{
		"id": "lmc", "name": "Large Magellanic Cloud", "short": "LMC", "at": "sky", "ra": 80.89416667, "dec": -69.75611111, "d": 49.59, "view": [25.0, 1.0],
		"card": "The largest of the Milky Way's satellites: 49.6 kpc away, to 1 % (Pietrzyński et al. 2019), and 1.4 × 10¹¹ solar masses in all, measured by how it bends the Orphan stream (Erkal et al. 2019). It moves at 321 km/s about the Galaxy (Kallivayalil et al. 2013). Drawn from its stars: 2.7 × 10⁹ solar masses in a disc tilted 34.7° to our line of sight (van der Marel et al. 2009; van der Marel & Cioni 2001).",
	},
	{
		"id": "smc", "name": "Small Magellanic Cloud", "short": "SMC", "at": "sky", "ra": 13.18666667, "dec": -72.82861111, "d": 62.44, "view": [20.0, 1.0],
		"card": "62.4 kpc away (Graczyk et al. 2020). It passed within about 7.5 kpc of the LMC some 150 Myr ago, and its stars' motions show it being torn apart (Zivick et al. 2018). Drawn from its old stars, a spheroid of 3.1 × 10⁸ solar masses (van der Marel et al. 2009; Gonidakis et al. 2009).",
	},
	{
		"id": "m33", "name": "Triangulum Galaxy (M33)", "short": "M33", "at": "sky", "ra": 23.46204167, "dec": 30.66022222, "d": 809.0, "view": [40.0, 1.0],
		"card": "The Local Group's third spiral, 809 kpc away (McConnachie 2012): a disc of 4.8 × 10⁹ solar masses of stars with no bulge (Corbelli et al. 2014), tilted 54° to our line of sight.",
	},
	{
		"id": "m31", "name": "Andromeda Galaxy (M31)", "short": "M31", "at": "sky", "ra": 10.68479292, "dec": 41.269065, "d": 783.0, "view": [90.0, 1.0],
		"card": "The nearest large galaxy, 783 kpc away and closing at 300 km/s (McConnachie 2012). A bulge of 3.4 and a disc of 6.9 × 10¹⁰ solar masses of stars (Kafle et al. 2018), tilted 77.5° to our line of sight (Tamm et al. 2012).",
	},
]

## The landmarks of a model, by its key.
static func of(model_key: String) -> Array:
	return MILKY_WAY if model_key == "milky_way" else []

static func find(model_key: String, id: String) -> Dictionary:
	for lm in of(model_key):
		if lm.id == id: return lm
	return {}

## A direction on the sky (ICRS degrees) on the Sun's axes (+x the Galactic centre, +y
## the north galactic pole, +z toward l = 270°), through SkyModel's galactic frame.
static func sky_direction(ra: float, dec: float) -> Vector3:
	var gal := SkyModel.galactic_frame_j2000()
	var u := SkyModel.radec_to_scene(ra, dec)
	var n := DVec3.from_v3(gal[0])
	var c := DVec3.from_v3(gal[1])
	var y := DVec3.from_v3(gal[2])
	return Vector3(u.dot(c), u.dot(n), -u.dot(y))

## A neighbour's centre and axes (galaxy-local): x along its line of nodes, y its disc's
## normal, tilted by its inclination from the line of sight. North and east on the sky are
## differences of directions half a degree apart. Which side of the disc is near is not
## modelled.
static func neighbour_frame(spec: Dictionary, model: Dictionary) -> Array:
	var r0: float = model.get("r0", 8.0)
	var pot: GalPotential = model.potential
	var f: Array = GalNeighbourhood.sun_frame(r0, float(model.get("sense", 1.0)) * pot.vc(r0) / r0, 0.0)
	var sb: Basis = f[1]
	var ra := float(spec.ra)
	var dec := float(spec.dec)
	var e := 0.5
	var u := sky_direction(ra, dec)
	var north := (sky_direction(ra, dec + e) - sky_direction(ra, dec - e)).normalized()
	var east := (sky_direction(ra + e / cos(deg_to_rad(dec)), dec) - sky_direction(ra - e / cos(deg_to_rad(dec)), dec)).normalized()
	var pa := deg_to_rad(float(spec.pa))
	var inc := deg_to_rad(float(spec.i))
	var nodes := north * cos(pa) + east * sin(pa)
	var across := -north * sin(pa) + east * cos(pa)
	var normal := -u * cos(inc) + across * sin(inc)
	var ex := sb * nodes
	var ey := sb * normal
	return [(f[0] as Vector3) + sb * (u * float(spec.d)), Basis(ex, ey, ex.cross(ey)).orthonormalized()]

## Where its label goes: on the landmark, or along the bar for the bar.
static func label_position(lm: Dictionary, model: Dictionary, t_myr: float) -> Vector3:
	if String(lm.at) != "bar": return position(lm, model, t_myr)
	for p in model.get("patterns", []):
		if p.kind == GalPattern.Kind.BAR:
			var a := GalPattern.angle(p, t_myr)
			return Vector3(cos(a), 0.0, sin(a)) * float(lm.label_r)
	return Vector3.ZERO

## Where a landmark is at t (galaxy-local kpc). `model` gives r0, the potential and the
## patterns.
static func position(lm: Dictionary, model: Dictionary, t_myr: float) -> Vector3:
	var r0: float = model.get("r0", 8.0)
	var sense := float(model.get("sense", 1.0))
	var pot: GalPotential = model.potential
	var omega := sense * pot.vc(r0) / r0
	match String(lm.at):
		"sun":
			return GalNeighbourhood.sun_frame(r0, omega, t_myr)[0]
		"origin", "bar":
			return Vector3.ZERO
		"spiral":
			var turn := 0.0
			for p in model.get("patterns", []):
				if p.kind == GalPattern.Kind.SPIRAL: turn = GalPattern.angle(p, t_myr) - float(p.angle0)
			var phi := PI + deg_to_rad(float(lm.beta)) + turn
			return Vector3(float(lm.r) * cos(phi), 0.0, float(lm.r) * sin(phi))
		"sky":
			var f: Array = GalNeighbourhood.sun_frame(r0, omega, 0.0)
			var b: Basis = f[1]
			return (f[0] as Vector3) + b * (sky_direction(float(lm.ra), float(lm.dec)) * float(lm.d))
	return Vector3.ZERO
