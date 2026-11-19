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

## Surface gravity log₁₀(g / cm s⁻²) from mass (M☉) and radius (R☉); the Sun is 4.44.
static func log_g(mass_sun: float, radius_sun_: float) -> float:
	return 4.438 + log(maxf(mass_sun, 1e-6) / pow(maxf(radius_sun_, 1e-6), 2.0)) / log(10.0)

## RMS continuum contrast of granulation in the visible: ~16% for the Sun before
## instrumental smearing, rising with Teff and falling with log g, and gone with the
## convective envelope. A fit to the trends in docs/physics/stellar-surfaces.md.
static func granulation_contrast(teff: float, logg: float) -> float:
	var c := 0.16 * pow(clampf(teff, 2500.0, 7000.0) / 5772.0, 2.0) * pow(10.0, 0.1 * clampf(4.44 - logg, -1.0, 5.0))
	return clampf(c, 0.03, 0.30) * Structure.envelope_convection(teff)

## How much cooler a starspot's umbra is than the photosphere, in K: ~1850 K on the
## Sun, only a few hundred on an M dwarf (Berdyugina 2005, Living Rev. Sol. Phys. 2, 8).
static func spot_temperature_drop(teff: float) -> float:
	return 1850.0 * clampf((teff - 3200.0) / 2572.0, 0.12, 1.2)

## Hot coronae on giants end at the Linsky–Haisch dividing line, near K2–K3 III: cooler
## giants have cool massive winds instead (Haisch, Schmitt & Fabian 1992). 1 for a
## dwarf or a warm giant, 0 past the line. `dwarf` is 1 on a dwarf, 0 on a giant.
static func hot_corona(teff: float, dwarf: float) -> float:
	return 1.0 - (1.0 - dwarf) * smoothstep(4600.0, 4100.0, teff)

# THE ENVELOPE: what lies above a photosphere when it is more than a thin skin
# (docs/physics/stellar-surfaces.md#puffed-up-and-shedding-stars).
## Levitation of a cool giant's atmosphere by convection, shocks and pulsation, in
## pressure scale heights: its molecular layer sits at 1.2–1.4 R on Betelgeuse and
## Antares (Ohnaka et al. 2013, 2017) and near 2 R on a Mira.
const LEVITATION := 6.0
## Grain condensation temperature, between corundum (~1400 K) and silicates (~1100 K).
const DUST_CONDENSATION_K := 1300.0
## Visible extinction per gram of gas. An M star's silicates are iron-poor and nearly
## transparent in the visible (Höfner 2008), so the shell dims a Mira by about a
## magnitude and Betelgeuse by a few tenths, not the 10² cm²/g of dark grains.
const DUST_KAPPA_CM2_G := 30.0
## Electron scattering, cm²/g: hydrogen-rich, and a WR star's helium.
const KAPPA_ES_H := 0.34
const KAPPA_ES_HE := 0.20

## Escape speed (km/s) from mass (M☉) at radius (R☉).
static func escape_kms(mass_sun: float, radius_sun_: float) -> float:
	return 617.7 * sqrt(maxf(mass_sun, 1e-6) / maxf(radius_sun_, 1e-6))

## The envelope of a structure `s` with wind Ṁ (M☉/yr), all lengths in stellar radii:
##   layerH, layerTau: the levitated molecular layer's scale height and radial optical
##     depth in the visible (TiO bands grow strong below ~4000 K);
##   dustR, dustTau: where grains condense, r_c/R = ½(T_eff/T_c)^{5/2} (Höfner 2007, with
##     p = 1), and the radial optical depth beyond it, κ Ṁ / (4π v r_c), the wind leaving
##     at half the escape speed from r_c;
##   windTau: a hot star's wind in electron scattering at its base (β = 1 law cut at
##     v = 0.01 v∞): optically thick for a Wolf–Rayet star, and an LBV's continuum-driven
##     outflow near the Eddington limit (Owocki et al. 2017) thickens it;
##   ejectKms: the speed of episodic surface mass ejections (Dupree et al. 2020 measure
##     ~90 km/s for Betelgeuse's in 2019), and ejectYr the mean interval between them.
static func envelope_of(s: Dictionary, mdot: float) -> Dictionary:
	var out := {"layerH": 0.0, "layerTau": 0.0, "dustR": 0.0, "dustTau": 0.0, "windTau": 0.0,
		"windKms": 0.0, "ejectKms": 0.0, "ejectYr": INF}
	var T: float = float(s.get("teff", 0.0))
	var R: float = float(s.get("radiusSun", 0.0))
	var M: float = float(s.get("mass", 0.0))
	if T <= 0.0 or R <= 0.0 or M <= 0.0: return out
	var hp := Structure.pressure_scale_height_frac(T, R, M)
	var vesc := escape_kms(M, R)
	var g_cm := mdot * Structure.M_SUN * 1000.0 / Rocketry.YR_S       # Ṁ in g/s
	var R_cm := R * Structure.R_SUN * 100.0
	var cool := Structure.envelope_convection(T)
	# Only a star whose layer reaches past a few hundredths of its radius is drawn with one.
	var H := clampf(LEVITATION * hp, 0.0, 0.4) * cool
	if H > 0.01:
		out.layerH = H
		out.layerTau = (0.15 + 0.9 * smoothstep(4300.0, 3200.0, T)) * smoothstep(0.01, 0.03, H)
		# Mass leaves in episodes from the largest cells, about once per crossing of the
		# layer at the ejection speed.
		out.ejectKms = 0.6 * vesc
		out.ejectYr = clampf(R / (45.4 * out.ejectKms) * 4.0, 0.05, 50.0)
	if T < 4500.0 and mdot > 1e-9:
		var rc := 0.5 * pow(T / DUST_CONDENSATION_K, 2.5)
		var vw := maxf(0.5 * escape_kms(M, R * rc), 5.0) * 1e5
		out.dustR = rc
		out.dustTau = clampf(DUST_KAPPA_CM2_G * g_cm / (4.0 * PI * vw * rc * R_cm), 0.0, 6.0)
	# A line-driven wind needs a hot star; near the Eddington limit the continuum drives
	# one at any temperature, and an LBV's visible surface is formed in it.
	var gamma: float = float(s.get("eddington", 0.0))
	if (T > 10000.0 and mdot > 0.0) or gamma > 0.7:
		var vinf := 2.6 * vesc
		var k := KAPPA_ES_HE if bool(s.get("wolfRayet", false)) else KAPPA_ES_H
		var tau := k * g_cm / (4.0 * PI * vinf * 1e5 * R_cm) * log(100.0)
		tau += 4.0 * smoothstep(0.7, 1.0, gamma)
		out.windTau = clampf(tau, 0.0, 8.0)
		out.windKms = vinf
	return out

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

## The planetary K index a star's activity drives at 1 AU: 2 when quiet; each CME
## arrives after ~1.8 days (900 km/s), lifts Kp toward 9 by how far its flare's energy
## exceeded the CME threshold, and fades over a day. Every CME counts as aimed at the
## planet; a real one is geoeffective only if launched near the disc centre.
static func storm_kp(act) -> float:
	if act == null: return 2.0
	var kp := 2.0
	for c in act.cmes:
		var since: float = float(c.t) - 0.005
		if since < 0.0: continue
		var peak := 7.0 * clampf((float(c.get("energy", 0.0)) - 1.1 * act.activity) / maxf(1.9 * act.activity, 1e-3), 0.0, 1.0)
		kp = maxf(kp, 2.0 + peak * exp(-since / 0.0027))
	return kp

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
				"alpha": 1.0, "dir": f.dir, "energy": energy,
				"width": 0.35 + rng.call() * 0.4,
			})
