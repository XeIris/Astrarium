class_name SkyModel
extends RefCounted

# The celestial background's CPU half: band tables, environments and the
# uniform writers. The shader is shaders/sky/sky.gdshaderinc; the derivation
# (why no texture, the pixel Jacobian, per-band compositing) is docs/physics/sky.md.
# `mats` everywhere is pipe.sky_materials: [background colour pass, temperature pass].

## Alpha meaning "sky, already imaged in this band": pass through the remap.
## It sits in the unused gap above the log-T codes (≤ 0.985) and below 1.0 ("infer
## T from colour"), ~9 fp16 steps wide. Mirrored in sky.gdshaderinc.
const SKY_ALPHA := 0.995

# Relative radiance of each component per band, normalised to its peak band.
# Authored, since the emission is non-thermal. Band order is Spectrum.BANDS:
#   0 radio 1 GHz   1 microwave 100 GHz   2 infrared 10 um   3 visible
#   4 ultraviolet   5 X-ray 0.3 keV       6 gamma ~100 keV
const W := {
	# Cosmic-ray electrons in the galactic field: I ~ nu^-0.7.
	"synchrotron":  [1.00, 0.10, 0.004, 0.0008, 0.0004, 0.0, 0.0],

	# Neutral hydrogen, 21 cm: radio only.
	"hydrogen21":   [0.60, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0],

	# 2.725 K; in its one window it is the whole sky.
	"cmb":          [0.01, 1.00, 0.0, 0.0, 0.0, 0.0, 0.0],

	# Dust re-radiating absorbed starlight at ~20 K: the visible's dark lanes glow at 10 um.
	"dustEmission": [0.0, 0.25, 1.00, 0.0, 0.0, 0.0, 0.0],

	# Unresolved starlight: the galactic band itself.
	"starGlow":     [0.0, 0.0, 0.35, 1.00, 0.12, 0.0, 0.0],

	# Old, K-giant dominated: redder than the disc, faint in the UV.
	"bulge":        [0.0, 0.0, 0.60, 1.00, 0.05, 0.0, 0.0],

	# Recombination lines (H-alpha), warm dust in the IR, free-free in the radio.
	"hii":          [0.25, 0.10, 0.50, 1.00, 0.30, 0.0, 0.0],

	# Starlight scattered off dust: blue, and survives into the UV.
	"reflection":   [0.0, 0.0, 0.05, 1.00, 0.80, 0.05, 0.0],

	# Integrated stellar population plus dust; the one isotropic component.
	"galaxies":     [0.05, 0.02, 0.40, 1.00, 0.30, 0.05, 0.01],

	# Local hot bubble plus unresolved AGN; cold clouds shadow it (as in ROSAT).
	"xrayDiffuse":  [0.0, 0.0, 0.0, 0.0, 0.0, 1.00, 0.05],

	# Pi-zero decay from cosmic rays on gas: a thin ridge on the plane.
	"pionRidge":    [0.0, 0.0, 0.0, 0.0, 0.0, 0.02, 1.00],

	# Synchrotron shells in the radio, 10^6-10^7 K gas in X-rays.
	"snr":          [1.00, 0.20, 0.05, 0.02, 0.02, 0.80, 0.10],

	# Coherent radio beams and curvature-radiation gamma rays.
	"pulsar":       [1.00, 0.15, 0.0, 0.001, 0.001, 0.30, 1.00],

	# Accretion onto a compact object; often a faint optical counterpart.
	"xrb":          [0.05, 0.0, 0.02, 0.001, 0.01, 1.00, 0.15],

	# Jets pointed at us; dominate the gamma-ray point sources.
	"blazar":       [0.80, 0.20, 0.05, 0.02, 0.05, 0.50, 1.00],
}

# Dust extinction relative to the visible. UV is ~1/lambda plus the 2175 A bump;
# X-ray is photoelectric absorption by metals in cold gas.
const EXTINCTION := [0.0, 0.005, 0.06, 1.0, 2.2, 1.4, 0.0]

# Per-band exposure of the summed sky: the bands span too many decades to share one gain.
const SKY_GAIN := [0.75, 0.85, 0.90, 1.0, 0.95, 0.90, 0.80]
# Star exposure per band. Outside the visible, stars go to the remap's log
# stretch, whose range tops out ~35x lower; the hot/cool ratio is untouched.
const STAR_GAIN := [0.02, 0.02, 0.10, 1.0, 0.06, 0.02, 0.02]

# Places a star system can be. Key order matters: skytest's `e` key and the
# settings panel list them in this order.
const SKY_ENVIRONMENTS := {
	# Mid-disc, a few kpc out: the familiar band, bulge and dust lane.
	"disc": {
		"starDensity": 0.55, "planeConcentration": 2.6,
		"glow": 1.00, "bulge": 1.00, "dust": 1.00,
		"hii": 1.00, "reflection": 1.0, "galaxies": 1.0,
		"bandScaleH": 0.10, "bulgeSize": 0.30,
	},
	# Deep in the core: dense stars, a huge bulge, heavy dust.
	"core": {
		"starDensity": 3.20, "planeConcentration": 3.0,
		"glow": 3.20, "bulge": 4.50, "dust": 2.60,
		"hii": 1.80, "reflection": 1.4, "galaxies": 0.5,
		"bandScaleH": 0.13, "bulgeSize": 0.85,
	},
	# Inside a globular: old stars everywhere, and the galaxy seen from outside
	# its disc as a thin distant lens.
	"globular": {
		"starDensity": 9.00, "planeConcentration": 0.0,
		"glow": 0.45, "bulge": 0.55, "dust": 0.05,
		"hii": 0.0, "reflection": 0.0, "galaxies": 0.8,
		"bandScaleH": 0.045, "bulgeSize": 0.22,
	},
	# The halo, or between galaxies: sparse stars, many external galaxies.
	"halo": {
		"starDensity": 0.12, "planeConcentration": 4.0,
		"glow": 0.22, "bulge": 0.35, "dust": 0.05,
		"hii": 0.05, "reflection": 0.05, "galaxies": 2.6,
		"bandScaleH": 0.030, "bulgeSize": 0.14,
	},
	# A spiral arm mid-starburst: H II, OB associations, dust, reflection nebulae.
	"starburst": {
		"starDensity": 1.60, "planeConcentration": 3.4,
		"glow": 1.60, "bulge": 0.70, "dust": 1.90,
		"hii": 4.20, "reflection": 2.6, "galaxies": 0.9,
		"bandScaleH": 0.045, "bulgeSize": 0.26,
	},
}

## Defaults of the uniform block every sky.gdshaderinc material carries. The
## include declares the same defaults; init_sky_materials() writes these anyway so
## the two can't drift.
static func sky_uniforms() -> Dictionary:
	return {
		"uGalNormal": Vector3(0.28, 0.93, 0.24).normalized(),
		"uGalCenter": Vector3(0.91, -0.22, 0.35).normalized(),
		"uGalEast": Vector3(0, 0, 1),

		"uVisibleBand": 1.0,
		"uTheta": 0.0,
		"uThetaVis": 0.0,
		"uNuRatio3": 1.0,
		"uExtCoef": 1.0,
		"uSkyGain": 1.0,
		"uStarGain": 1.0,

		"uStarFlux": 2.2e-4,
		"uStarDensity": 0.70,
		"uPlaneConc": 2.2,
		"uPsfPx": 1.25,
		"uPixAngle": 8.7e-4,
		"uSpikes": 1.0,

		"uGlow": 1.0, "uBulge": 1.0, "uDust": 1.0,
		"uHii": 1.0, "uRefl": 1.0, "uGalaxies": 1.0,
		"uBandScaleH": 0.055, "uBulgeSize": 0.30,

		"uwSynch": 0.0, "uwH21": 0.0, "uwCmb": 0.0,
		"uwDustEm": 0.0, "uwGlow": 1.0, "uwBulge": 1.0,
		"uwHii": 1.0, "uwRefl": 1.0, "uwGalaxies": 1.0,
		"uwXrayBg": 0.0, "uwPion": 0.0, "uwSnr": 0.0,
		"uwPulsar": 0.0, "uwXrb": 0.0, "uwBlazar": 0.0,

		# Observer velocity/c, nonzero only in interstellar cruise (sky_aberrate).
		"uBeta": Vector3(0, 0, 0),
	}

static func init_sky_materials(mats: Array) -> void:
	var d := sky_uniforms()
	for k in d:
		_set_all(mats, k, d[k])

static func _set_all(mats: Array, name: String, value) -> void:
	for m in mats:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter(name, value)

## Sky exposure relative to a night-sky exposure. The flight view lowers it by
## the ratio of exposures (spaceflight.gd): beside a sunlit hull the camera is ten
## or so stops darker and the stars drop below the noise.
static var day_gain := 1.0
static var _band := -1

static func apply_day_gain(mats: Array, g: float) -> void:
	if absf(g - day_gain) < 1e-5 and _band >= 0: return
	day_gain = g
	if _band < 0: return
	_set_all(mats, "uSkyGain", float(SKY_GAIN[_band]) * day_gain)
	_set_all(mats, "uStarGain", float(STAR_GAIN[_band]) * day_gain)

## Zero (the default) makes aberration the identity and the Doppler factor exactly 1.
static func apply_sky_boost(mats: Array, beta_vec: Vector3) -> void:
	_set_all(mats, "uBeta", beta_vec)

## Every band-dependent uniform is set here and nowhere else.
static func apply_sky_band(mats: Array, band_index: int) -> void:
	var bands: Array = Spectrum.BANDS
	var i := clampi(band_index, 0, bands.size() - 1)
	var nu := float(bands[i].nu)
	var nu_vis := float(bands[Spectrum.VISIBLE_BAND].nu)
	_set_all(mats, "uVisibleBand", 1.0 if i == Spectrum.VISIBLE_BAND else 0.0)
	_set_all(mats, "uTheta", Spectrum.H_OVER_K * nu)
	_set_all(mats, "uThetaVis", Spectrum.H_OVER_K * nu_vis)
	_set_all(mats, "uNuRatio3", pow(nu / nu_vis, 3.0))
	_set_all(mats, "uExtCoef", float(EXTINCTION[i]))
	_band = i
	_set_all(mats, "uSkyGain", float(SKY_GAIN[i]) * day_gain)
	_set_all(mats, "uStarGain", float(STAR_GAIN[i]) * day_gain)

	var table := {
		"uwSynch": "synchrotron", "uwH21": "hydrogen21",
		"uwCmb": "cmb", "uwDustEm": "dustEmission",
		"uwGlow": "starGlow", "uwBulge": "bulge",
		"uwHii": "hii", "uwRefl": "reflection",
		"uwGalaxies": "galaxies", "uwXrayBg": "xrayDiffuse",
		"uwPion": "pionRidge", "uwSnr": "snr",
		"uwPulsar": "pulsar", "uwXrb": "xrb",
		"uwBlazar": "blazar",
	}
	for u in table:
		_set_all(mats, u, float(W[table[u]][i]))

# What an environment is: uniform, blend rule and slider range on one row, so a
# new component needs no other change (the blender, applier and settings panel
# read this). `add`: amounts of a population add; shapes of the one galaxy you
# are in take the weighted mean. See docs/physics/sky.md.
const SKY_PARAMS := [
	{ "key": "starDensity",        "uniform": "uStarDensity", "add": true,  "max": 12.0, "label": "Star density" },
	{ "key": "glow",               "uniform": "uGlow",        "add": true,  "max": 6.0,  "label": "Unresolved glow" },
	{ "key": "bulge",              "uniform": "uBulge",       "add": true,  "max": 6.0,  "label": "Bulge" },
	{ "key": "dust",               "uniform": "uDust",        "add": true,  "max": 4.0,  "label": "Dust" },
	{ "key": "hii",                "uniform": "uHii",         "add": true,  "max": 6.0,  "label": "H II regions" },
	{ "key": "reflection",         "uniform": "uRefl",        "add": true,  "max": 4.0,  "label": "Reflection neb." },
	{ "key": "galaxies",           "uniform": "uGalaxies",    "add": true,  "max": 4.0,  "label": "External galaxies" },
	{ "key": "planeConcentration", "uniform": "uPlaneConc",   "add": false, "max": 5.0,  "label": "Plane concentration" },
	{ "key": "bandScaleH",         "uniform": "uBandScaleH",  "add": false, "max": 0.25, "label": "Band scale height" },
	{ "key": "bulgeSize",          "uniform": "uBulgeSize",   "add": false, "max": 1.2,  "label": "Bulge size" },
]

## Normalise `env` into [name, weight] pairs. Accepts:
##   "disc"                          one environment, weight 1
##   ["globular", "disc"]            equal weights
##   [["globular", 1], ["disc", .4]] explicit weights
##   { "globular": 1, "disc": 0.4 }  the same, as a map — what the UI holds
##
## Unknown names are dropped, so a typo shows as a missing component.
static func sky_env_weights(env) -> Array:
	var pairs: Array = []
	if env == null or (env is String and env == "") :
		pairs = []
	elif env is String or env is StringName:
		pairs = [[str(env), 1.0]]
	elif env is Array:
		for e in env:
			if e is Array:
				pairs.append([str(e[0]), _num(e[1] if e.size() > 1 else null)])
			else:
				pairs.append([str(e), 1.0])
	elif env is Dictionary:
		for k in env:
			pairs.append([str(k), _num(env[k])])
	var out: Array = []
	for p in pairs:
		var w: float = p[1]
		if SKY_ENVIRONMENTS.has(p[0]) and w > 0.0 and is_finite(w):
			out.append(p)
	return out

# Numbers pass, numeric strings parse, anything else is NaN (and fails w > 0).
static func _num(v) -> float:
	if v is float or v is int:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	if v is String and v.is_valid_float():
		return v.to_float()
	return NAN

## Collapse named environments into one parameter set. Additive terms are not
## normalised (half a disc plus half a core is dimmer than either); shape terms
## are. An empty or unrecognised list gives a plain disc.
static func blend_environments(env) -> Dictionary:
	var pairs := sky_env_weights(env)
	if pairs.is_empty():
		return (SKY_ENVIRONMENTS.disc as Dictionary).duplicate()

	var total := 0.0
	for p in pairs:
		total += float(p[1])
	var out := {}
	for pm in SKY_PARAMS:
		var acc := 0.0
		for p in pairs:
			acc += float(p[1]) * float(SKY_ENVIRONMENTS[p[0]][pm.key])
		out[pm.key] = acc if pm.add else acc / total
	return out

## Apply an environment plus the galactic frame. A parameter set directly on
## `spec` overrides the blend ("core, without the dust"). `tilt`/`roll` rotate
## the one galactic frame, which decides where the band crosses the sky.
static func apply_sky_environment(mats: Array, spec: Dictionary = {}) -> void:
	var p := blend_environments(spec.get("env"))
	p.merge(spec, true)   # { ...blend, ...spec }

	for pm in SKY_PARAMS:
		_set_all(mats, pm.uniform, float(p[pm.key]))

	var tilt := float(spec.tilt) if spec.has("tilt") and spec.tilt != null else 0.34
	var roll := float(spec.roll) if spec.has("roll") and spec.roll != null else 0.9
	var frame := galactic_frame(tilt, roll)
	_set_all(mats, "uGalNormal", frame[0])
	_set_all(mats, "uGalCenter", frame[1])
	_set_all(mats, "uGalEast", frame[2])

## The galactic frame [normal, centre, east] for a tilt/roll, computed in doubles.
static func galactic_frame(tilt: float, roll: float) -> Array:
	var n := DVec3.new(sin(tilt) * cos(roll), cos(tilt), sin(tilt) * sin(roll)).normalized()
	# Centre: any vector not parallel to n, with n projected out.
	var seed := DVec3.new(1, 0, 0) if absf(n.y) > 0.9 else DVec3.new(0, 1, 0)
	var c := seed.sub(n.scaled(seed.dot(n))).normalized()
	var e := n.cross(c).normalized()
	return [n.to_v3(), c.to_v3(), e.to_v3()]

## The unlensed pixel footprint, against which the shader measures
## magnification. `fov` is vertical, in radians; `height` is in device pixels
## (pipe.render_size.y).
static func apply_sky_optics(mats: Array, fov: float, height: float) -> void:
	_set_all(mats, "uPixAngle", fov / maxf(1.0, height))

## Per-frame apply_sky_optics: the reference must track the current fov, or a
## zoom mis-brightens every star near the ring.
static func update_pix_angle(mats: Array, fov_rad: float, height_px: float) -> void:
	_set_all(mats, "uPixAngle", fov_rad / height_px if height_px > 0.0 else fov_rad)
