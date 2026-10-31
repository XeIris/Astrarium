class_name Stellar
extends RefCounted

# STELLAR ASTROPHYSICS from one input, mass in M☉: main-sequence radius, luminosity
# and Teff, and colour from a Planck fit (a 2 M☉ star is ~11× the Sun's luminosity).

# Mass–luminosity and mass–radius live in sim/structure.gd and are re-exported
# here. One copy matters above ~20 M☉, where a plain M^3.5 gives 1.7e6 L☉ at 55 M☉
# against a real ~5e5 (see MASSIVE_L there).
static func luminosity(mass_sun: float, Z: float = 0.014) -> float:
	return Structure.base_luminosity(mass_sun, Z)

static func radius_sun(mass_sun: float) -> float:
	return Structure.base_radius_sun(mass_sun)

## Effective temperature from Stefan–Boltzmann: L = 4πR²σT⁴ ⇒ T ∝ (L/R²)^¼.
## Normalised so 1 M☉ → 5772 K.
static func effective_temp(mass_sun: float) -> float:
	var L := Structure.base_luminosity(mass_sun)
	var R := Structure.base_radius_sun(mass_sun)
	return 5772.0 * pow(L / (R * R), 0.25)

## Harvard spectral class letter, for the HUD.
static func spectral_class(teff: float) -> String:
	if teff >= 30000.0: return "O"
	if teff >= 10000.0: return "B"
	if teff >= 7500.0: return "A"
	if teff >= 6000.0: return "F"
	if teff >= 5200.0: return "G"
	if teff >= 3700.0: return "K"
	return "M"

# Blackbody colour: Tanner Helland's piecewise fit to the Planck locus, normalised
# for roughly constant perceived brightness. The components are linear, so pass the
# Color raw, never through srgb_to_linear or a `source_color` uniform.
# Planck × CIE 1931 2° colour matching (Wyman, Sloan & Shirley 2013 fit) → XYZ →
# linear sRGB (D65), out-of-gamut channels clipped, peak-normalised so stars differ in
# hue rather than exposure. 48 steps in log T over 800–42 000 K; the sky and lens
# shaders carry the same table (BB_LUT).
const BB_LUT := [
	Color(1.0000, 0.0000, 0.0000), Color(1.0000, 0.0034, 0.0000), Color(1.0000, 0.0178, 0.0000), Color(1.0000, 0.0349, 0.0000),
	Color(1.0000, 0.0549, 0.0000), Color(1.0000, 0.0776, 0.0000), Color(1.0000, 0.1030, 0.0000), Color(1.0000, 0.1313, 0.0000),
	Color(1.0000, 0.1622, 0.0000), Color(1.0000, 0.1960, 0.0000), Color(1.0000, 0.2324, 0.0000), Color(1.0000, 0.2713, 0.0096),
	Color(1.0000, 0.3128, 0.0280), Color(1.0000, 0.3566, 0.0523), Color(1.0000, 0.4025, 0.0837), Color(1.0000, 0.4503, 0.1228),
	Color(1.0000, 0.4997, 0.1705), Color(1.0000, 0.5503, 0.2275), Color(1.0000, 0.6018, 0.2942), Color(1.0000, 0.6538, 0.3707),
	Color(1.0000, 0.7058, 0.4571), Color(1.0000, 0.7574, 0.5527), Color(1.0000, 0.8081, 0.6570), Color(1.0000, 0.8574, 0.7689),
	Color(1.0000, 0.9050, 0.8870), Color(0.9901, 0.9411, 1.0000), Color(0.8802, 0.8746, 1.0000), Color(0.7913, 0.8183, 1.0000),
	Color(0.7187, 0.7704, 1.0000), Color(0.6590, 0.7295, 1.0000), Color(0.6095, 0.6944, 1.0000), Color(0.5682, 0.6641, 1.0000),
	Color(0.5335, 0.6379, 1.0000), Color(0.5041, 0.6152, 1.0000), Color(0.4792, 0.5955, 1.0000), Color(0.4579, 0.5782, 1.0000),
	Color(0.4396, 0.5631, 1.0000), Color(0.4238, 0.5499, 1.0000), Color(0.4101, 0.5382, 1.0000), Color(0.3982, 0.5280, 1.0000),
	Color(0.3877, 0.5189, 1.0000), Color(0.3786, 0.5108, 1.0000), Color(0.3706, 0.5036, 1.0000), Color(0.3635, 0.4972, 1.0000),
	Color(0.3572, 0.4915, 1.0000), Color(0.3516, 0.4864, 1.0000), Color(0.3466, 0.4819, 1.0000), Color(0.3422, 0.4778, 1.0000)
]
const BB_T0 := 800.0
const BB_T1 := 42000.0

## Quadratic limb-darkening coefficients per sRGB primary (R, V, B bands), for
## I(μ)/I(1) = 1 − a(1 − μ) − b(1 − μ)², from Claret (2000) (LimbDark.TABLE),
## linear in Teff and held at the table's ends (2000–49 000 K). Returns
## [a: Vector3, b: Vector3].
static func limb_darkening(teff: float) -> Array:
	var t: Array = LimbDark.TABLE
	var i := 1
	while i < t.size() - 1 and float(t[i][0]) < teff: i += 1
	var f := clampf((teff - float(t[i - 1][0])) / (float(t[i][0]) - float(t[i - 1][0])), 0.0, 1.0)
	var row := func(k: int) -> float: return lerpf(float(t[i - 1][k]), float(t[i][k]), f)
	return [Vector3(row.call(1), row.call(2), row.call(3)), Vector3(row.call(4), row.call(5), row.call(6))]

## Linear sRGB of a blackbody at `kelvin`, brightest channel 1.
static func blackbody_color(kelvin: float) -> Color:
	var u := log(clampf(kelvin, BB_T0, BB_T1) / BB_T0) / log(BB_T1 / BB_T0) * float(BB_LUT.size() - 1)
	var i := mini(int(u), BB_LUT.size() - 2)
	return (BB_LUT[i] as Color).lerp(BB_LUT[i + 1], u - float(i))

## A hotter, whiter version of the photosphere colour for the corona/flares.
static func corona_color(kelvin: float) -> Color:
	return blackbody_color(kelvin).lerp(Color(1, 1, 1), 0.35)

# Rotation in rad/yr. Below the Kraft break (~1.3 M☉, Teff ≈ 6200 K) a convective
# envelope's magnetised wind spins a star down (the Sun: ~25 d); above it, without
# one, A and B stars keep ~150 km/s at the equator, a period of about a day (Kraft
# 1967; Zorec & Royer 2012).
static func rotation_rate(mass_sun: float) -> float:
	var m := maxf(mass_sun, 0.1)
	var slow := TAU / (25.0 * pow(m, -0.6) / 365.25)
	var radius_km := Physics.stellar_radius(m) / Physics.AU_PER_KM
	var fast := 150.0 / radius_km * Rocketry.YR_S
	var w := smoothstep(1.2, 1.5, m)
	return lerpf(slow, fast, w)

# MAGNETIC ACTIVITY: cool convective-envelope stars flare and spot; hot radiative
# ones barely do.
static func activity_level(mass_sun: float) -> float:
	# peaks for late-K/M dwarfs, falls off sharply above ~1.4 M☉
	var m := maxf(mass_sun, 0.08)
	return clampf(pow(0.9 / m, 1.6), 0.08, 3.0)

## Mean interval between significant flares, in sim years.
static func flare_interval(mass_sun: float) -> float:
	return 0.06 / activity_level(mass_sun)

# FLARE / CME EVENT MODEL: a small population of active regions; flares rise fast
# and decay exponentially, the biggest launching a CME. Flares, CMEs and regions
# are Dictionaries read by star_visual.gd and prominence.gd.
class ActivityModel:
	extends RefCounted
	var rng: Callable
	var activity: float
	var interval: float
	var next: float
	var flares: Array = []        # live flare events
	var cmes: Array = []          # live coronal mass ejections
	var regions: Array = []       # active longitudes/latitudes (spot groups)
	var flux: float = 1.0         # instantaneous visual brightness multiplier
	var bolometric: float = 1.0   # the same flare in total output, for insolation and lighting

	func _init(mass_sun: float, p_rng: Callable = Callable()) -> void:
		rng = p_rng if p_rng.is_valid() else func(): return randf()
		activity = Stellar.activity_level(mass_sun)
		interval = Stellar.flare_interval(mass_sun)
		next = interval * (0.4 + rng.call())
		var n := int(round(clampf(2.0 + activity * 3.0, 2.0, 8.0)))
		for i in n:
			regions.append(new_region())
		flux = 1.0

	func new_region() -> Dictionary:
		# spots emerge in mid-latitude "activity belts", not at the poles
		var lat: float = (0.15 + rng.call() * 0.45) * (1.0 if rng.call() < 0.5 else -1.0)
		return {
			"lat": lat, "lon": rng.call() * TAU,
			"strength": 0.3 + rng.call() * 0.7,
			"age": 0.0, "life": 0.15 + rng.call() * 0.5,      # years
		}

	## Unit vector of a region on the (unrotated) stellar surface.
	func region_dir(r: Dictionary) -> Vector3:
		var cl := cos(float(r.lat))
		return Vector3(cl * cos(float(r.lon)), sin(float(r.lat)), cl * sin(float(r.lon))).normalized()

	func step(dt: float) -> void:
		# age the active regions; retire and replace the spent ones
		for i in range(regions.size() - 1, -1, -1):
			var r: Dictionary = regions[i]
			r.age += dt
			if r.age > r.life: regions[i] = new_region()

		# flare arrivals — Poisson-ish, anchored to an active region
		next -= dt
		if next <= 0.0:
			next = interval * (0.5 + rng.call() * 1.4)
			ignite()

		# advance flares: fast rise, exponential decay
		var fl := 1.0
		for i in range(flares.size() - 1, -1, -1):
			var f: Dictionary = flares[i]
			f.t += dt
			var x: float = f.t / f.duration
			if x >= 1.0:
				flares.remove_at(i)
				continue
			# rise over the first 12% of the event, then exponential decay
			f.amp = (x / 0.12) if x < 0.12 else exp(-(x - 0.12) * 5.5)
			fl += f.amp * f.energy * 0.35
		flux = fl
		# What the flare adds to the star's total output. The largest solar flares raise
		# it ~3e-4 for minutes (Kopp et al. 2005); `flux` is the visual pulse.
		bolometric = 1.0 + (fl - 1.0) * 1e-3

		# advance CMEs — a shell expanding at roughly constant speed, fading
		for i in range(cmes.size() - 1, -1, -1):
			var c: Dictionary = cmes[i]
			c.t += dt
			c.radius += c.speed * dt
			c.alpha = maxf(0.0, 1.0 - c.t / c.life)
			if c.alpha <= 0.0: cmes.remove_at(i)

	func ignite() -> void:
		# A star with no active regions has nothing to flare from (see the `quiet`
		# path in sim/star_visual.gd for degenerate stars).
		if regions.is_empty(): return
		var region: Dictionary = regions[int(floor(rng.call() * regions.size()))]
		# flare energies follow a power law: many small, rare huge ones
		var energy: float = pow(rng.call(), 2.2) * 3.0 * activity + 0.15
		var f := {
			"t": 0.0,
			"duration": 0.004 + rng.call() * 0.02,      # years (~1.5–9 days)
			"energy": energy, "amp": 0.0,
			"dir": region_dir(region),
			"region": region,
		}
		flares.append(f)
		# only the energetic events launch a CME
		if energy > 1.1 * activity:
			cmes.append({
				"t": 0.0, "life": 0.05 + rng.call() * 0.06,
				# stellar radii per year: a display speed ~1000× slower than a real CME's
				# 300–3000 km/s, so a shell is visible at orrery rates
				"radius": 1.0, "speed": 14.0 + rng.call() * 20.0,
				"alpha": 1.0, "dir": f.dir,
				"width": 0.35 + rng.call() * 0.4,
			})
