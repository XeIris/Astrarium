class_name Starcat
extends RefCounted

# ============================================================================
# A CATALOGUE OF REAL STARS
# ----------------------------------------------------------------------------
# Everything else in this sim is generated: masses go in, a mass–luminosity
# relation comes out, and the result is a plausible star rather than a
# particular one. This file is the opposite. Every entry is a measured object,
# and the numbers are the measurements — mass, radius, effective temperature,
# luminosity, rotation — not what the scaling relations would have predicted.
#
# That distinction is the point of the file. Feeding Betelgeuse's 16.5 M☉ into
# a main-sequence radius relation returns 4.9 R☉; Betelgeuse is 764. Feeding
# Sirius B's 1.02 M☉ into one returns 1.0 R☉; Sirius B is 0.0084. The scaling
# relations are not wrong, they simply describe main-sequence stars, and half
# of the famous ones are not on the main sequence. So each entry also carries
# its evolutionary `phase`, which is what lets the cross-section view show a
# red supergiant's onion shells rather than a scaled-up Sun.
#
# SOURCES. Masses, radii and temperatures are the values in general use from
# interferometry (CHARA, VLTI/AMBER, NPOI), asteroseismology, and orbital
# solutions for the binaries; distances are Hipparcos/Gaia parallaxes. Where a
# quantity is genuinely contested — Betelgeuse's radius and distance above all,
# which have moved by 30% within the last decade — the note says so.
#
# ROTATION. `oblate` is the MEASURED R_equator / R_polar, and the sim works
# backwards from it to the fraction of break-up rotation (see
# Structure.inverse_roche_shape). This is the right way round: interferometry
# measures a star's shape far more precisely than its equatorial velocity,
# which needs an inclination to be known. Vega's measured 236 km/s
# independently predicts a ratio of 1.192 against a measured 1.193 — see the
# note there.
#
# PORT NOTE. Entries and the specs built from them are Dictionaries with the
# web build's keys verbatim; `pos`/`vel` are 3-element Arrays of floats.
# ============================================================================

# mass  M☉        radius R☉ (polar, if oblate is given)
# teff  K         luminosity L☉         dist  light years
# phase id from Structure.PHASES        oblate R_eq/R_pol
const STAR_CATALOG := {
	"sun": {
		"name": "Sun", "mass": 1.0, "radius": 1.0, "teff": 5772.0, "lum": 1.0, "dist": 0.0,
		"sp": "G2V", "phase": "ms-mid",
		"note": "The calibration point for everything else in astrophysics, and a thoroughly ordinary star: more massive than about 95% of the stars in the galaxy.",
	},
	"proxima": {
		"name": "Proxima Centauri", "mass": 0.1221, "radius": 0.1542, "teff": 3042.0, "lum": 0.00155, "dist": 4.246,
		"sp": "M5.5Ve", "phase": "ms-mid", "flare": 3.0,
		"note": "The nearest star to the Sun, and only just a star at all — 60% above the hydrogen-burning limit. Fully convective, violently magnetic, and it will still be burning hydrogen in four trillion years.",
	},
	"barnard": {
		"name": "Barnard's Star", "mass": 0.162, "radius": 0.196, "teff": 3223.0, "lum": 0.0035, "dist": 5.96,
		"sp": "M4.0V", "phase": "ms-late",
		"note": "The fastest proper motion of any star — it crosses a lunar diameter of sky every 180 years. Ancient and metal-poor.",
	},
	"alphacenA": {
		"name": "Alpha Centauri A", "mass": 1.0788, "radius": 1.2234, "teff": 5790.0, "lum": 1.519, "dist": 4.365,
		"sp": "G2V", "phase": "ms-late",
		"note": "The Sun's near-twin, slightly heavier and noticeably older, so it has swelled and brightened past where the Sun is now.",
	},
	"alphacenB": {
		"name": "Alpha Centauri B", "mass": 0.9092, "radius": 0.8632, "teff": 5260.0, "lum": 0.5002, "dist": 4.365,
		"sp": "K1V", "phase": "ms-late",
		"note": "An orange dwarf on an 80-year, e = 0.52 orbit with A — from 11.2 AU apart to 35.6 and back.",
	},
	"siriusA": {
		"name": "Sirius A", "mass": 2.063, "radius": 1.711, "teff": 9940.0, "lum": 25.4, "dist": 8.61,
		"sp": "A1V", "phase": "ms-mid",
		"note": "The brightest star in the sky, which it owes as much to being close as to being bright.",
	},
	"siriusB": {
		"name": "Sirius B", "mass": 1.018, "radius": 0.0084, "teff": 25200.0, "lum": 0.056, "dist": 8.61,
		"sp": "DA2", "type": "white-dwarf",
		"note": "A white dwarf the size of Earth with the mass of the Sun. Its existence was inferred from Sirius A's wobble in 1844, forty years before anyone saw it, and its density was so absurd that Eddington wrote the star had replied \"shut up, I know what I am doing\".",
	},
	"vega": {
		"name": "Vega", "mass": 2.135, "radius": 2.362, "teff": 9602.0, "lum": 40.12, "dist": 25.04,
		"sp": "A0Va", "phase": "ms-early", "oblate": 2.818 / 2.362, "poleOn": true, "debris": true,
		"note": "For a century the definition of magnitude zero — and then interferometry found it is a rapid rotator seen almost pole-on, so we had been calibrating photometry against its hot pole. It spins at 236 km/s, 88% of break-up; that measured velocity predicts an equator-to-pole radius ratio of 1.192 against the 1.193 observed, and a 10 260 K pole over an 8 610 K equator against 10 070 / 8 910 measured.",
	},
	"altair": {
		"name": "Altair", "mass": 1.86, "radius": 1.63, "teff": 7550.0, "lum": 10.6, "dist": 16.73,
		"sp": "A7Vn", "phase": "ms-mid", "oblate": 2.03 / 1.63,
		"note": "The first star other than the Sun to have its surface directly imaged (CHARA, 2007). Spinning at ~273 km/s, its equator bulges 25% and runs 1600 K cooler than its poles.",
	},
	"fomalhaut": {
		"name": "Fomalhaut", "mass": 1.92, "radius": 1.842, "teff": 8590.0, "lum": 16.63, "dist": 25.13,
		"sp": "A3V", "phase": "ms-early", "debris": true,
		"note": "Young, and wrapped in a sharply eccentric debris ring 140 AU across whose inner edge is swept clean — the classic case for an unseen planet shepherding it.",
	},
	"achernar": {
		"name": "Achernar", "mass": 6.7, "radius": 6.78, "teff": 15000.0, "lum": 3150.0, "dist": 139.0,
		"sp": "B6Vep", "phase": "ms-mid", "oblate": 1.352, "decretion": true,
		"note": "The flattest star known: its equator is 35% further from the centre than its poles. It spins near enough to break-up that it throws off a gaseous decretion disc, which is what the \"e\" in its spectral type means.",
	},
	"regulus": {
		"name": "Regulus", "mass": 3.8, "radius": 3.22, "teff": 12460.0, "lum": 316.0, "dist": 79.3,
		"sp": "B8IVn", "phase": "ms-late", "oblate": 4.21 / 3.22,
		"note": "Spinning at 96% of break-up. Its pole is 14 500 K and its equator 11 000 K — the single most extreme gravity darkening measured on a bright star.",
	},
	"bellatrix": {
		"name": "Bellatrix", "mass": 8.6, "radius": 5.75, "teff": 21800.0, "lum": 9211.0, "dist": 249.7,
		"sp": "B2III", "phase": "tams",
		"note": "Orion's left shoulder, and the nearest hot B star. At 8.6 M☉ it sits almost exactly on the line between ending as a white dwarf and ending as a neutron star — which of the two it will be is genuinely not known.",
	},
	"rigel": {
		"name": "Rigel", "mass": 21.0, "radius": 78.9, "teff": 12100.0, "lum": 120000.0, "dist": 863.0,
		"sp": "B8Ia", "phase": "subgiant",
		"note": "A blue supergiant already past the main sequence: 120 000 L☉ from a star that has been burning for only eight million years. It has been a red supergiant before and is likely to become one again before it explodes.",
	},
	"betelgeuse": {
		"name": "Betelgeuse", "mass": 16.5, "radius": 764.0, "teff": 3600.0, "lum": 126000.0, "dist": 548.0,
		"sp": "M1-2Ia-ab", "phase": "agb",
		"note": "A red supergiant so large that its photosphere would reach past the asteroid belt, and so tenuous that the outer half of it is closer to a vacuum than to air. Its radius and distance are both uncertain by tens of percent — it has no sharp edge to measure. In 2019 it dimmed by 60%, which turned out to be a dust cloud condensing over a cool patch thrown off its own surface.",
	},
	"antares": {
		"name": "Antares", "mass": 12.0, "radius": 680.0, "teff": 3660.0, "lum": 75900.0, "dist": 550.0,
		"sp": "M1.5Iab", "phase": "agb",
		"note": "The other red supergiant of naked-eye fame, named for looking like Mars (\"anti-Ares\") and losing about an Earth mass of itself every three years.",
	},
	"aldebaran": {
		"name": "Aldebaran", "mass": 1.16, "radius": 45.1, "teff": 3900.0, "lum": 439.0, "dist": 65.3,
		"sp": "K5III", "phase": "rgb",
		"note": "A red giant of almost exactly the Sun's mass — which makes it a preview: an Earth-mass core of degenerate helium the size of this planet, inside an envelope 45 times the Sun's radius.",
	},
	"arcturus": {
		"name": "Arcturus", "mass": 1.08, "radius": 25.4, "teff": 4286.0, "lum": 170.0, "dist": 36.7,
		"sp": "K0III", "phase": "rgb",
		"note": "An old, metal-poor halo star passing through the disc at 122 km/s. It is not from around here.",
	},
	"capella": {
		"name": "Capella Aa", "mass": 2.5687, "radius": 11.98, "teff": 4970.0, "lum": 78.7, "dist": 42.9,
		"sp": "G8III", "phase": "heburn",
		"note": "Caught in the act: it crossed the Hertzsprung gap recently enough that its companion, nearly the same mass, has not yet followed. The pair are the reason we can date that crossing at all.",
	},
	"polaris": {
		"name": "Polaris", "mass": 5.4, "radius": 37.5, "teff": 6015.0, "lum": 1260.0, "dist": 447.6,
		"sp": "F7Ib", "phase": "heburn", "pulsator": 3.97,
		"note": "The nearest Cepheid, pulsating every 3.97 days. Cepheids obey a period–luminosity law, which is how the distance to anything beyond our own galaxy is measured — the whole cosmic distance ladder rests on stars like this one.",
	},
	"deneb": {
		"name": "Deneb", "mass": 19.0, "radius": 203.0, "teff": 8525.0, "lum": 196000.0, "dist": 2615.0,
		"sp": "A2Ia", "phase": "subgiant",
		"note": "One of the most luminous stars visible to the eye. It is 2 600 light years away and still first magnitude; put it where Sirius is and it would cast shadows at night.",
	},
	"spica": {
		"name": "Spica A", "mass": 11.43, "radius": 7.47, "teff": 25300.0, "lum": 20512.0, "dist": 250.0,
		"sp": "B1III-IV", "phase": "ms-late",
		"note": "Half of a four-day binary so close that both stars are tidally distorted into eggs, and the pair varies in brightness simply by turning.",
	},
	"mira": {
		"name": "Mira", "mass": 1.18, "radius": 332.0, "teff": 3000.0, "lum": 8400.0, "dist": 300.0,
		"sp": "M7IIIe", "phase": "agb", "pulsator": 332.0,
		"note": "The first variable star ever recognised (1596), swinging through 8 magnitudes on a 332-day pulsation. It is shedding its envelope and trails a 13-light-year tail of its own gas.",
	},
	"etacar": {
		"name": "Eta Carinae A", "mass": 100.0, "radius": 240.0, "teff": 9400.0, "lum": 5.0e6, "dist": 7500.0,
		"sp": "LBV", "phase": "tams",
		"note": "The most luminous star in the galaxy that we can still see, sitting hard against its own Eddington limit. In the 1840s it brightened to outshine everything but Sirius and threw off ten to forty solar masses in a single eruption — and survived. The debris is still expanding as the Homunculus Nebula.",
	},
	"r136a1": {
		"name": "R136a1", "mass": 196.0, "radius": 39.2, "teff": 46000.0, "lum": 4.68e6, "dist": 163000.0,
		"sp": "WN5h", "phase": "ms-mid",
		"note": "The heaviest star known, in the 30 Doradus cluster of the Large Magellanic Cloud. It was born heavier still — a wind driven by its own radiation has already stripped tens of solar masses off it — and it is inside the pair-instability window, so it may leave nothing at all behind.",
	},
	"uyscuti": {
		"name": "UY Scuti", "mass": 7.0, "radius": 755.0, "teff": 3365.0, "lum": 1.1e5, "dist": 5100.0,
		"sp": "M4Ia", "phase": "agb",
		"note": "For a while the largest star known by radius; the record keeps moving because these stars have no definable surface and their distances are poor. What is certain is that it would reach past Jupiter.",
	},
	"crab": {
		"name": "Crab Pulsar", "mass": 1.4, "radius": 12.0 / 696340.0, "teff": 1e6, "lum": 0.0, "dist": 6500.0,
		"sp": "PSR", "type": "neutron", "spinMs": 33.5,
		"note": "The neutron star left by the supernova the Chinese court astronomers recorded in 1054. It turns 30 times a second, and the wind it drives lights the entire nebula around it.",
	},
}

# ----------------------------------------------------------------------------
# Turn a catalogue key into a body spec the sim can spawn.
# ----------------------------------------------------------------------------
## `extra` is merged over the catalogue fields ({...extra} in the JS). An
## unknown key is an error there (it throws); here it pushes an error and
## returns {}.
static func star_spec(key: String, extra: Dictionary = {}) -> Dictionary:
	if not STAR_CATALOG.has(key):
		push_error("unknown star: %s" % key)
		return {}
	var c: Dictionary = STAR_CATALOG[key]
	var type: String = c.get("type", "star")
	var spec := {
		"type": type, "name": c.name, "mass": c.mass,
		"catalog": key, "catalogNote": c.note, "sp": c.sp,
	}
	for k in extra:
		spec[k] = extra[k]
	if type == "star" or type == "white-dwarf":
		spec.radiusSun = c.radius
		spec.teff = c.teff
		spec.luminosity = c.lum
		spec.phase = Structure.phase_by_id(c.phase).f if c.has("phase") else 0.5
		# Measured shape wins over any modelled spin (see the module header).
		if c.has("oblate"): spec.spinFrac = Structure.inverse_roche_shape(c.oblate)
		if c.has("flare"): spec.activityBoost = c.flare
	if type == "neutron":
		spec.radiusKm = float(c.radius) * 696340.0
		spec.spin = (1000.0 / float(c.spinMs)) if c.has("spinMs") else 10.0
	return spec

# ============================================================================
# SCENARIO BUILDERS
# ============================================================================

# ----------------------------------------------------------------------------
# A ring of stars, each started on a genuinely circular orbit.
#
# The usual way to build a display like this is to place the bodies and give
# them a speed from √(GM_total/R), which is only correct for one body orbiting
# a central mass — there is no central mass here, and the ring members pull on
# each other as hard as anything else does. So instead, sum the actual
# N-body acceleration on each member at t = 0, take its inward component, and
# set that body's speed from v = √(a_r · R). Each star then starts in exact
# circular balance with the real force acting on it.
#
# It will still come apart. A ring of unequal masses has no stable mode — the
# heavy members perturb the light ones, the ring buckles, and within a few
# revolutions it is an ordinary chaotic N-body system. That is the correct
# answer and the blurb says so; the alternative would be to freeze the bodies
# in place and stop calling it a simulation.
# ----------------------------------------------------------------------------
static func star_ring(keys: Array, radius_au: float, opts: Dictionary = {}) -> Array:
	var n := keys.size()
	var specs := []
	var ths := []
	for i in n:
		var th := (float(i) / float(n)) * PI * 2.0 + float(U.nz(opts.get("phase"), 0.0))
		var s := star_spec(keys[i])
		s.pos = [cos(th) * radius_au, 0.0, sin(th) * radius_au]
		specs.append(s)
		ths.append(th)
	for si in n:
		var s: Dictionary = specs[si]
		# net acceleration from every other member
		var ax := 0.0
		var az := 0.0
		for oi in n:
			if oi == si: continue
			var o: Dictionary = specs[oi]
			var dx: float = o.pos[0] - s.pos[0]
			var dz: float = o.pos[2] - s.pos[2]
			var d2 := dx * dx + dz * dz
			var d := sqrt(d2)
			var a := Physics.G * float(o.mass) / d2
			ax += a * dx / d; az += a * dz / d
		# inward component (toward the ring centre at the origin)
		var th: float = ths[si]
		var ur := [-cos(th), -sin(th)]
		var a_rad := maxf(ax * ur[0] + az * ur[1], 1e-9)
		var v := sqrt(a_rad * radius_au)
		s.vel = [-sin(th) * v, 0.0, cos(th) * v]
	return specs

# ----------------------------------------------------------------------------
# A real visual binary from its published orbital elements. Both stars are
# placed about their common barycentre on the true ellipse, at the true
# anomaly asked for, with the exact vis-viva speed for that point.
# ----------------------------------------------------------------------------
## `el` = { a, e, incl = 0, nu = PI }.
static func real_binary(key_a: String, key_b: String, el: Dictionary) -> Array:
	var A := star_spec(key_a)
	var B := star_spec(key_b)
	var a: float = el.a
	var e: float = el.e
	var incl: float = U.nz(el.get("incl"), 0.0)
	var nu: float = U.nz(el.get("nu"), PI)
	var M: float = float(A.mass) + float(B.mass)
	var p := a * (1.0 - e * e)
	var r := p / (1.0 + e * cos(nu))
	var h := sqrt(Physics.G * M * p)
	var px := r * cos(nu)
	var pz := r * sin(nu)
	var vx := -Physics.G * M / h * sin(nu)
	var vz := Physics.G * M / h * (e + cos(nu))
	var c := cos(incl)
	var s := sin(incl)
	var rel_pos := [px, pz * s, pz * c]
	var rel_vel := [vx, vz * s, vz * c]
	return [_share(A, rel_pos, rel_vel, -float(B.mass) / M), _share(B, rel_pos, rel_vel, float(A.mass) / M)]

static func _share(spec: Dictionary, rel_pos: Array, rel_vel: Array, k: float) -> Dictionary:
	var o := spec.duplicate()
	o.pos = [rel_pos[0] * k, rel_pos[1] * k, rel_pos[2] * k]
	o.vel = [rel_vel[0] * k, rel_vel[1] * k, rel_vel[2] * k]
	return o

# ----------------------------------------------------------------------------
# Put a small body on a circular orbit around a catalogue star.
# ----------------------------------------------------------------------------
static func companion(central_mass: float, a_au: float, spec: Dictionary, angle: float = 0.0, incl: float = 0.0) -> Dictionary:
	var v := Physics.circular_speed(central_mass, a_au)
	var o := spec.duplicate()
	# Rotate the whole state about the line of nodes (the x axis), the way
	# real_binary above does. Tilting only the y COORDINATE by an arbitrary 0.05
	# left the velocity flat in xz, so the body did not orbit in the plane it
	# claimed — it started off it and precessed out.
	o.pos = [cos(angle) * a_au,
			sin(angle) * sin(incl) * a_au,
			sin(angle) * cos(incl) * a_au]
	o.vel = [-sin(angle) * v,
			cos(angle) * sin(incl) * v,
			cos(angle) * cos(incl) * v]
	return o
