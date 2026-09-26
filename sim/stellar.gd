class_name Stellar
extends RefCounted

# ============================================================================
# STELLAR ASTROPHYSICS — the numbers behind a star.
# ----------------------------------------------------------------------------
# Everything here is derived from ONE input: the mass in M☉. Main-sequence
# scaling relations give radius, luminosity and effective temperature; Teff
# gives the colour via a Planck-curve fit. So a 2 M☉ star really is bigger,
# hotter, bluer and ~11× more luminous than the Sun without any of it being
# hand-tuned per body.
# ============================================================================

# Mass–luminosity and mass–radius. Both live in sim/structure.gd, which is the
# single place that decides what a star of a given mass is; they are re-exported
# here because this module's own name is what the rest of the sim reaches for.
#
# Keeping one copy matters above ~20 M☉, where the piecewise L ∝ M^3.5 that used
# to be here runs away — it returns 1.7e6 L☉ at 55 M☉ against a real ~5e5, and
# the Eddington factor computed from it would say every massive star is unbound.
# See MASSIVE_L there.
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

# ----------------------------------------------------------------------------
# Blackbody colour. Tanner Helland's piecewise fit to the Planck locus, then
# normalised to keep the perceived brightness roughly constant (we convey
# luminosity through size/glow/light intensity, not by dimming the disc).
#
# PORT NOTE: the web build built this as `new THREE.Color(r, g, b)` from
# FLOATS, which three does not colour-manage — the fit's values are used as
# linear-light components directly. So this is a plain Color, and it must NOT
# go through srgb_to_linear or a `source_color` uniform.
# ----------------------------------------------------------------------------
static func blackbody_color(kelvin: float) -> Color:
	var t := clampf(kelvin, 1000.0, 40000.0) / 100.0
	var r: float; var g: float; var b: float
	if t <= 66.0: r = 255.0
	else: r = 329.698727446 * pow(t - 60.0, -0.1332047592)
	if t <= 66.0: g = 99.4708025861 * log(t) - 161.1195681661
	else: g = 288.1221695283 * pow(t - 60.0, -0.0755148492)
	if t >= 66.0: b = 255.0
	elif t <= 19.0: b = 0.0
	else: b = 138.5177312231 * log(t - 10.0) - 305.0447927307
	var c := Color(clampf(r, 0.0, 255.0) / 255.0, clampf(g, 0.0, 255.0) / 255.0, clampf(b, 0.0, 255.0) / 255.0)
	# renormalise so every star reads as "bright", differing in hue not exposure
	var peak := maxf(c.r, maxf(c.g, c.b))
	if peak == 0.0: peak = 1.0
	return Color(c.r / peak, c.g / peak, c.b / peak)

## A hotter, whiter version of the photosphere colour for the corona/flares.
static func corona_color(kelvin: float) -> Color:
	return blackbody_color(kelvin).lerp(Color(1, 1, 1), 0.35)

# ----------------------------------------------------------------------------
# Rotation. Real stars rotate differentially — the equator laps the poles.
# The Sun: ~25 d equatorial, ~34 d polar. Massive stars spin much faster.
# Returned in radians per year (sim time unit).
# ----------------------------------------------------------------------------
static func rotation_rate(mass_sun: float) -> float:
	var days := 25.0 * pow(maxf(mass_sun, 0.1), -0.6)   # equatorial period
	return TAU / (days / 365.25)

# ----------------------------------------------------------------------------
# MAGNETIC ACTIVITY
# Cool stars with deep convective envelopes are the flare stars; hot massive
# stars have radiative envelopes and almost no spots. This drives how often a
# star flares and how heavily it's spotted.
# ----------------------------------------------------------------------------
static func activity_level(mass_sun: float) -> float:
	# peaks for late-K/M dwarfs, falls off sharply above ~1.4 M☉
	var m := maxf(mass_sun, 0.08)
	return clampf(pow(0.9 / m, 1.6), 0.08, 3.0)

## Mean interval between significant flares, in sim years.
static func flare_interval(mass_sun: float) -> float:
	return 0.06 / activity_level(mass_sun)

# ============================================================================
# FLARE / CME EVENT MODEL
# ----------------------------------------------------------------------------
# A star carries a small population of active regions (starspot groups). Flares
# erupt from those regions: a fast rise, an exponential decay, and — for the
# biggest events — a coronal mass ejection that expands away from the surface.
#
# Flares, CMEs and regions are Dictionaries with the JS field names, because
# sim/star_visual.gd and sim/prominence.gd read them the way the web build did.
# ============================================================================
class ActivityModel:
	extends RefCounted
	var rng: Callable
	var activity: float
	var interval: float
	var next: float
	var flares: Array = []        # live flare events
	var cmes: Array = []          # live coronal mass ejections
	var regions: Array = []       # active longitudes/latitudes (spot groups)
	var flux: float = 1.0         # instantaneous brightness multiplier

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
				"radius": 1.0, "speed": 14.0 + rng.call() * 20.0,   # in stellar radii per year
				"alpha": 1.0, "dir": f.dir,
				"width": 0.35 + rng.call() * 0.4,
			})
