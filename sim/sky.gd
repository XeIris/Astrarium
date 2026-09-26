class_name SkyModel
extends RefCounted

# ============================================================================
# SKY — procedural celestial background, resolution-free and band-aware.
# ============================================================================
# (The port of sim/sky.js. The GLSL half — SKY_GLSL — is
# shaders/sky/sky.gdshaderinc; this file is everything the JS module did on the
# CPU: the band tables, the environments, and the functions that write the
# uniform block. `class_name` is SkyModel because Sky is a Godot class.)
#
# The old sky was a 2048x1024 canvas with 9000 dots painted into it. That fails
# for three separate reasons, and only one of them is "not enough texels".
#
# 1. IT WAS ALREADY UNDER-RESOLVED STANDING STILL. 2048 texels across 360deg is
#    0.176deg/texel; the lens pass renders at ~0.05deg/pixel. The map was ~3.5x
#    coarser than the screen before a black hole touched it.
#
# 2. LENSING MAGNIFICATION IS UNBOUNDED. Near the photon ring the Jacobian of
#    the deflection map is near-singular and one texel covers tens of pixels.
#    No fixed-resolution map survives that, at any resolution. You cannot
#    outrun a divergence by adding texels.
#
# 3. THE LENSING RESPONSE WAS PHYSICALLY WRONG. Gravitational lensing conserves
#    surface brightness (Liouville / conservation of etendue) and amplifies
#    FLUX by the magnification mu = 1/|det J|. So an extended source - a
#    nebula, the galactic band - keeps its brightness and merely distorts,
#    while a POINT source stays point-like and gets BRIGHTER. Sampling stars
#    from a texture forces them into the extended-source behaviour, which is
#    why the Einstein ring read as stretched paint instead of a ring of
#    brilliant points.
#
# THE ORGANISING IDEA: SPLIT THE SKY BY HOW LENSING TREATS IT, NOT BY WHAT IT IS
#
#   point layer      stars, pulsars, X-ray binaries, quasars
#                    -> analytic, procedural, no texture, infinite resolution
#   diffuse layer    galactic band, nebulae, CMB, diffuse X-ray background
#                    -> surface brightness conserved; a smooth field is right
#   absorbing layer  interstellar dust
#                    -> multiplies everything behind it, band-dependent
#
# ONE TERM DOES ALL THE LENSING WORK: THE SCREEN-SPACE JACOBIAN
#
#   Let J = [dD/dx, dD/dy] be the 3x2 derivative of the outgoing ray direction
#   with respect to screen pixels. Both derivatives are taken with dFdx/dFdy in
#   the pass that produced the direction, so J costs nothing to obtain and
#   already contains fov, resolution and lensing together. Everything follows
#   from it:
#
#     - w^2 = |dD/dx x dD/dy| is the solid angle of sky this pixel covers, and
#       carries det J. It shrinks as 1/mu wherever the hole magnifies.
#
#     - Diffuse layers ignore J entirely and are evaluated as plain radiance,
#       so their surface brightness is conserved for free.
#
#     - A star's offset is solved for IN PIXELS: given a star direction s,
#       solve J p = (s - D) in least squares. The PSF is then a fixed circular
#       Gaussian in p, so the star is the same little disc on screen no matter
#       what the lens is doing. Normalising the kernel through J divides by
#       w^2, giving  L = F * G(p) / w^2  — and since w^2 goes as 1/mu, the peak
#       radiance rises exactly as mu. Flux amplification, point sources that
#       stay points, and the anisotropy of the mapping, from one expression.
#
#   Working in PIXELS rather than in source angle is the part that matters.
#   Blur a star by a fixed angle on the source sphere and the lens stretches
#   that kernel tangentially into an arc — which is the correct image of an
#   EXTENDED source, and wrong for a star. The arc is the filter, not the star.
#   Extended things here (galaxies, supernova shells) are deliberately kept in
#   source angle so that they DO arc, which is the honest difference between
#   the two cases.
#
#   This is the ray-bundle filtering of James, von Tunzelmann, Franklin &
#   Thorne (2015) - the DNGR renderer built for Interstellar - who found that
#   point-sampling a star field flickered unacceptably and that the cure was to
#   integrate the sky over each pixel's mapped footprint rather than sample it
#   at a point. Here the bundle is measured rather than traced, which is much
#   cheaper and, for a full-screen pass, just as good.
#
#   The PSF width is a constant number of PIXELS. That is the right invariant:
#   a real instrument's PSF is fixed on its detector by diffraction, not by the
#   pixel grid or the field of view, so a star covers the same little disc
#   however far you zoom. Where a source is smaller than that disc it is
#   clamped in size and DIMMED to conserve flux - the same rule sim/scale.gd
#   uses to carry a sub-pixel body on a point-source marker.
#
# THE MAGNITUDE LAW COMES FREE FROM THE CELL SUBDIVISION
#
#   Stars are hashed into cells of a tangent-warped cube map (no equirect pole
#   pinch, no seam, near-equal solid angle per cell). Tier k uses 2^k times as
#   many cells per face edge as tier 0, so tier k holds 4x as many stars as
#   tier k-1. Give each tier one magnitude less flux and you have reproduced
#
#       N(<m)  proportional to  10^(0.6 m)
#
#   the Euclidean star-count law, exactly, as a side effect of the subdivision.
#   Each tier IS one magnitude bin. Calibration anchor: 9096 stars brighter
#   than mag 6.5 over the whole sky (Hipparcos).
#
#   Below the faintest tier the population is not dropped - it is folded into
#   the diffuse layer as INTEGRATED UNRESOLVED STARLIGHT. That is not a cheat:
#   the Milky Way band is unresolved stars. It is also what stops the sky
#   reading as uniform confetti, which was the other half of what looked wrong.
#
# TEMPERATURE, NOT COLOUR
#
#   Every star hashes a TEMPERATURE and gets its colour from the Planck locus,
#   per the house rule in the lens marcher. One number then drives both the
#   visible colour and the band response, so they cannot disagree.
#
#   The temperature is NOT drawn from the initial mass function. A
#   magnitude-limited sky is Malmquist-biased: luminous stars are visible from
#   much further away, so the naked-eye sky is dominated by hot B/A stars and
#   distant giants, not by the M dwarfs that dominate by number. The draw in
#   the shader is weighted for what a magnitude-limited sample actually contains.
#
# BANDS: WHY THE SKY CANNOT GO THROUGH sim/spectrum.gd
#
#   spectrum re-images BLACKBODY CONTINUUM: it recovers a temperature and
#   evaluates a Planck ratio. That is right for stars and for the disc. It
#   cannot produce a real multiwavelength sky, because nearly everything that
#   dominates the sky outside the visible is not thermal continuum at all -
#   21 cm and CO lines, synchrotron power laws, pi-zero decay gamma rays, and
#   the CMB. sim/spectrum.gd says as much in its own header.
#
#   So the sky is composited PER BAND here, at the band's own frequency:
#
#       L(d, nu) = sum_i  spatial_i(d) * spectral_i(nu) * prod_j ext_j(d, nu)
#
#   where spectral_i is a hand-authored per-band weight for the non-thermal
#   components (tables below, with their justification) and a real Planck FLUX
#   ratio for the stars. The result is written already-in-band and marked with
#   SKY_ALPHA so the remap passes it through untouched instead of trying to
#   infer a temperature from it.
#
#   Note the stars need a FLUX ratio, not the surface-brightness ratio
#   spectrum uses. In the Rayleigh-Jeans limit a star's surface brightness
#   ratio is ~1, which would keep stars blazing in the radio; what actually
#   removes them is the nu^3 prefactor acting on their tiny solid angle. Carry
#   the prefactor and a 6000 K star comes out 6e-11 times as bright at 1 GHz as
#   in the visible - gone, which is the correct and much more striking answer.
#
#   One consequence worth stating: LENSING IS ACHROMATIC. A black hole deflects
#   every wavelength identically - there is no dispersion in vacuum - so the
#   distortion geometry is pixel-identical in all seven bands and only the
#   source content changes. Switching bands with the ring on screen is a fair
#   demonstration of that.
#
# IN GODOT. A "uniforms" object of the web build (skyUniforms(), shared by the
# backdrop and the lens resolve and kept in step by syncSky) is here an Array
# of ShaderMaterial — render/pipeline.gd keeps it as `pipe.sky_materials`
# ([background colour pass, background temperature pass]). Every function
# below that took `uniforms` takes that Array and writes every material in it,
# so syncSky(fn) is simply calling the function once.
# ============================================================================

## Alpha sentinel meaning "this pixel is sky, already imaged in the current
## band - do not infer a temperature, do not apply a Planck ratio".
##
## The existing protocol in sim/spectrum.gd is: alpha in (0.005, 0.985) carries
## log T, anything else means "infer T from colour". That fallback is still what
## lit geometry wants (it writes alpha 1.0 and really is blackbody-coloured), so
## the sky needs its own value rather than reusing 1.0. 0.995 sits in the unused
## gap and survives half-float storage comfortably - fp16 spacing near 1.0 is
## 4.9e-4, so the test window in the remap is ~9 representable steps wide.
## (The shader's own copy is SKY_ALPHA in shaders/sky/sky.gdshaderinc.)
const SKY_ALPHA := 0.995

# ----------------------------------------------------------------------------
# Per-band spectral weights.
# ----------------------------------------------------------------------------
# Band order matches Spectrum.BANDS:
#   0 radio 1 GHz   1 microwave 100 GHz   2 infrared 10 um   3 visible
#   4 ultraviolet   5 X-ray 0.3 keV       6 gamma ~100 keV
#
# These are RELATIVE radiances within a component, normalised to that
# component's peak band, and they are authored rather than derived because the
# underlying emission is non-thermal. Each entry carries the reason.
const W := {
	# Cosmic-ray electrons spiralling in the galactic magnetic field. Power law,
	# I ~ nu^-0.7, so it is overwhelming at 1 GHz and negligible by the infrared.
	# This is what the 408 MHz all-sky maps are made of: a bright plane plus a
	# huge loop arching out of it.
	"synchrotron":  [1.00, 0.10, 0.004, 0.0008, 0.0004, 0.0, 0.0],

	# Neutral atomic hydrogen, 21 cm. A line, and a radio-only one.
	"hydrogen21":   [0.60, 0.05, 0.0, 0.0, 0.0, 0.0, 0.0],

	# The cosmic microwave background: 2.725 K, filling the sky in every
	# direction. It exists in exactly one of these windows, and in that window it
	# is the entire sky. Nothing else here does that.
	"cmb":          [0.01, 1.00, 0.0, 0.0, 0.0, 0.0, 0.0],

	# Interstellar dust re-radiating the starlight it absorbed, ~20 K. THE key
	# inversion in the whole feature: the lanes that are black in the visible are
	# the brightest structure on screen at 10 um.
	"dustEmission": [0.0, 0.25, 1.00, 0.0, 0.0, 0.0, 0.0],

	# Integrated light of stars below the resolution limit - the galactic band
	# itself. Follows the stellar population, so it peaks in the visible/near-IR.
	"starGlow":     [0.0, 0.0, 0.35, 1.00, 0.12, 0.0, 0.0],

	# The bulge is an old population dominated by cool K giants: redder than the
	# disc, and almost absent in the ultraviolet.
	"bulge":        [0.0, 0.0, 0.60, 1.00, 0.05, 0.0, 0.0],

	# H II regions: recombination lines (H-alpha dominates the visible), warm
	# dust in the IR, thermal free-free bremsstrahlung in the radio.
	"hii":          [0.25, 0.10, 0.50, 1.00, 0.30, 0.0, 0.0],

	# Reflection nebulae are starlight scattered off dust - Rayleigh-ish, so they
	# are blue and they survive into the ultraviolet.
	"reflection":   [0.0, 0.0, 0.05, 1.00, 0.80, 0.05, 0.0],

	# External galaxies: an integrated stellar population plus their own dust.
	# Broad, and the only component here that is genuinely isotropic.
	"galaxies":     [0.05, 0.02, 0.40, 1.00, 0.30, 0.05, 0.01],

	# Diffuse soft X-ray background - the local hot bubble plus the unresolved
	# sum of distant AGN. This is the glow that cold clouds are silhouetted
	# against, which is how the ROSAT all-sky map shows dust as shadows.
	"xrayDiffuse":  [0.0, 0.0, 0.0, 0.0, 0.0, 1.00, 0.05],

	# Cosmic rays striking interstellar gas make pi-zeros, which decay to gamma
	# rays. Traces the gas column, so it is a thin bright ridge exactly on the
	# plane, and it is essentially the only diffuse gamma-ray emission there is.
	"pionRidge":    [0.0, 0.0, 0.0, 0.0, 0.0, 0.02, 1.00],

	# Supernova remnants: synchrotron shells in the radio, shock-heated gas at
	# 10^6-10^7 K in X-rays. Bright at both ends, nearly invisible between them.
	"snr":          [1.00, 0.20, 0.05, 0.02, 0.02, 0.80, 0.10],

	# Pulsars: coherent radio beams and curvature-radiation gamma rays, with
	# almost nothing in between. Crab, Vela and Geminga are gamma-ray point
	# sources long before they are anything else.
	"pulsar":       [1.00, 0.15, 0.0, 0.001, 0.001, 0.30, 1.00],

	# X-ray binaries: accretion onto a compact object. The optical counterpart of
	# a bright XRB is often a faint, unremarkable star.
	"xrb":          [0.05, 0.0, 0.02, 0.001, 0.01, 1.00, 0.15],

	# Blazars - jets pointed at us. Isotropic on the sky, unlike everything
	# galactic, and they dominate the gamma-ray point-source population.
	"blazar":       [0.80, 0.20, 0.05, 0.02, 0.05, 0.50, 1.00],
}

# Extinction by interstellar dust, relative to the visible.
#
# Rising into the ultraviolet is the ordinary ~1/lambda extinction law made
# worse by the 2175 A absorption bump, so UV dust lanes are blacker than
# visible ones. The X-ray entry is a different mechanism entirely -
# photoelectric absorption by metals in the cold gas - but it is large, and it
# is what makes cold clouds appear as shadows against the diffuse X-ray glow.
# Radio and gamma pass through dust essentially untouched.
const EXTINCTION := [0.0, 0.005, 0.06, 1.0, 2.2, 1.4, 0.0]

# Exposure per band, applied to the composited sky before the remap's log
# stretch. This is the sky's own equivalent of a telescope's integration time:
# the bands span too many decades to share one gain. The infrared and
# ultraviolet numbers offset the honest Planck flux ratio for the STARS - at
# 10 um every star is ~20x fainter than in the visible, and lifting that back
# up is exposure, not fudging, because the RELATIVE behaviour between hot and
# cool stars is left exactly as the physics gives it.
# Final per-band exposure trim, applied after the components are summed.
const SKY_GAIN := [0.75, 0.85, 0.90, 1.0, 0.95, 0.90, 0.80]
# Stars in the visible go to the HDR tone mapper; in every other band they go
# to the remap's log stretch, whose useful range tops out ~35x lower. Hence the
# small numbers outside the visible — it is a change of display scale, not of
# physics. The RELATIVE behaviour between hot and cool stars is left exactly as
# the Planck flux ratio gives it, which is what makes cool giants dominate the
# infrared and hot stars the ultraviolet.
const STAR_GAIN := [0.02, 0.02, 0.10, 1.0, 0.06, 0.02, 0.02]

# ----------------------------------------------------------------------------
# Sky environments.
# ----------------------------------------------------------------------------
# The sim is not obliged to reproduce Earth's sky - these systems are somewhere
# else in the galaxy, or not in one at all. That is a licence worth spending:
# the same code with different parameters gives every preset its own sky, and
# each of these is a real place a star system can be.
#
# (Key order is the web build's object order — disc, core, globular, halo,
# starburst — and GDScript Dictionaries keep insertion order, so .keys() lists
# them the way Object.keys(SKY_ENVIRONMENTS) did: the `e` key in skytest and
# the settings panel's rows both depend on it.)
const SKY_ENVIRONMENTS := {
	# Mid-disc, a few kpc out. The familiar arrangement: a band across the sky,
	# a bulge toward the centre, a dust lane bisecting both.
	"disc": {
		"starDensity": 0.55, "planeConcentration": 2.6,
		"glow": 1.00, "bulge": 1.00, "dust": 1.00,
		"hii": 1.00, "reflection": 1.0, "galaxies": 1.0,
		"bandScaleH": 0.10, "bulgeSize": 0.30,
	},
	# Deep in the core. Sky choked with stars, an enormous bulge, and so much
	# dust that the visible sky is half blocked while the infrared blazes.
	"core": {
		"starDensity": 3.20, "planeConcentration": 3.0,
		"glow": 3.20, "bulge": 4.50, "dust": 2.60,
		"hii": 1.80, "reflection": 1.4, "galaxies": 0.5,
		"bandScaleH": 0.13, "bulgeSize": 0.85,
	},
	# Inside a globular cluster. Thousands of bright old stars in every
	# direction, no band, no dust, no ongoing star formation.
	"globular": {
		# A globular is a halo satellite, so the galaxy is a distant, thin lens
		# seen from OUTSIDE the disc rather than a band wrapped around you — and
		# the cluster's own stars, being local, ignore it entirely.
		"starDensity": 9.00, "planeConcentration": 0.0,
		"glow": 0.45, "bulge": 0.55, "dust": 0.05,
		"hii": 0.0, "reflection": 0.0, "galaxies": 0.8,
		"bandScaleH": 0.045, "bulgeSize": 0.22,
	},
	# Out in the halo, or between galaxies. Almost empty: a scattering of faint
	# stars, the galaxy itself reduced to a distant smear, and external galaxies
	# everywhere because nothing is blocking them.
	"halo": {
		"starDensity": 0.12, "planeConcentration": 4.0,
		"glow": 0.22, "bulge": 0.35, "dust": 0.05,
		"hii": 0.05, "reflection": 0.05, "galaxies": 2.6,
		"bandScaleH": 0.030, "bulgeSize": 0.14,
	},
	# A spiral arm mid-starburst. H-alpha everywhere, blazing OB associations,
	# heavy dust, and the reflection nebulae that go with young hot stars.
	"starburst": {
		"starDensity": 1.60, "planeConcentration": 3.4,
		"glow": 1.60, "bulge": 0.70, "dust": 1.90,
		"hii": 4.20, "reflection": 2.6, "galaxies": 0.9,
		"bandScaleH": 0.045, "bulgeSize": 0.26,
	},
}

# ============================================================================
# Uniforms
# ============================================================================

## The shared uniform block's defaults — the web build's skyUniforms(), as
## {uniform name: value}. Both background materials (and anything else that
## includes sky.gdshaderinc) carry exactly these. The shader include declares
## the same values as its defaults; init_sky_materials() writes them anyway, so
## the two cannot drift.
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

		# Relativistic boost of the OBSERVER, as velocity/c in world coordinates.
		# Zero everywhere except during interstellar cruise, where it is what turns
		# the sky into a forward-lit tunnel. See sky_aberrate in the shader.
		"uBeta": Vector3(0, 0, 0),
	}

## Write every default of sky_uniforms() into every material in `mats` — what
## `Object.assign(skyUniforms(), …)` did when the web build built a pass.
static func init_sky_materials(mats: Array) -> void:
	var d := sky_uniforms()
	for k in d:
		_set_all(mats, k, d[k])

static func _set_all(mats: Array, name: String, value) -> void:
	for m in mats:
		if m != null:
			(m as ShaderMaterial).set_shader_parameter(name, value)

## Set the observer's boost. Pass a zero vector (the default) and every path
## through this module is bit-identical to what it was before relativistic
## flight existed — the aberration reduces to the identity and the Doppler
## factor to exactly 1.
static func apply_sky_boost(mats: Array, beta_vec: Vector3) -> void:
	_set_all(mats, "uBeta", beta_vec)

## Point every band-dependent uniform at `band_index`. Everything the sky needs
## to know about the imaging band is set here and nowhere else.
static func apply_sky_band(mats: Array, band_index: int) -> void:
	var bands: Array = Spectrum.BANDS
	var i := clampi(band_index, 0, bands.size() - 1)
	var nu := float(bands[i].nu)
	# h/k in kelvin-seconds, as in sim/spectrum.gd.
	var nu_vis := float(bands[Spectrum.VISIBLE_BAND].nu)
	_set_all(mats, "uVisibleBand", 1.0 if i == Spectrum.VISIBLE_BAND else 0.0)
	_set_all(mats, "uTheta", Spectrum.H_OVER_K * nu)
	_set_all(mats, "uThetaVis", Spectrum.H_OVER_K * nu_vis)
	_set_all(mats, "uNuRatio3", pow(nu / nu_vis, 3.0))
	_set_all(mats, "uExtCoef", float(EXTINCTION[i]))
	_set_all(mats, "uSkyGain", float(SKY_GAIN[i]))
	_set_all(mats, "uStarGain", float(STAR_GAIN[i]))

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

# ----------------------------------------------------------------------------
# Environment parameters, and how two of them combine.
# ----------------------------------------------------------------------------
# SKY_PARAMS is the single list of what an environment IS. The uniform name,
# the blend rule and the slider range all live on the one row, so a new sky
# component is added here and the blender, the applier and the settings panel
# pick it up without being touched. (Same discipline as sim/masscurve.gd
# sampling its thresholds out of structure_of rather than listing them.)
#
# The `add` flag is the physics, not a preference. Split by what the number
# actually measures:
#
#   ADDITIVE (add: true) — an AMOUNT of something. Star density, the diffuse
#     glow, the bulge, dust column, H II, reflection nebulae, external
#     galaxies. These are independent populations along the same line of
#     sight, and lines of sight superpose: standing in a globular cluster you
#     see the cluster's own stars AND, through them, the galaxy it orbits.
#     Adding is what a second population does.
#
#   GEOMETRIC (add: false) — a SHAPE of the one galaxy you are inside. There
#     is exactly one galactic plane, so there is exactly one scale height, one
#     plane concentration and one bulge size. Two of them cannot coexist the
#     way two populations can, so these take the weighted MEAN — the blend
#     moves the shape from one place to the other rather than stacking it.
#
# Summing a shape parameter is the error worth naming: blend disc with core
# at full weight and an added bandScaleH gives a band 0.23 rad thick, which is
# not a galaxy seen from anywhere.
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

## Normalise whatever `env` was written as into [name, weight] pairs.
##
## Four spellings, because a preset, a slider panel and a console handle all
## want a different one and none of them should have to convert:
##
##   "disc"                          one environment, weight 1
##   ["globular", "disc"]            equal weights
##   [["globular", 1], ["disc", .4]] explicit weights
##   { "globular": 1, "disc": 0.4 }  the same, as a map — what the UI holds
##
## Unknown names are dropped rather than defaulted, so a typo shows up as the
## component going missing instead of silently becoming a second disc.
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

# JS unary +: numbers pass, numeric strings parse, anything else is NaN (and
# NaN then fails the w > 0 test, exactly as it did in the web build).
static func _num(v) -> float:
	if v is float or v is int:
		return float(v)
	if v is bool:
		return 1.0 if v else 0.0
	if v is String and v.is_valid_float():
		return v.to_float()
	return NAN

## Collapse one or more named environments into a flat parameter object.
##
## Weights are NOT normalised for the additive terms — that is the whole point.
## Half a disc plus half a core is genuinely dimmer than either, and a disc at
## weight 1 alongside a globular at weight 1 is a cluster sky with the full
## galaxy still behind it. The geometric terms ARE normalised, because a
## weighted mean is only a mean if the weights sum to one.
##
## An empty or unrecognised list falls back to a plain disc, so nothing can ask
## for a sky and get a black one.
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

## Apply an environment — named, blended, or explicitly overridden — plus the
## galactic frame orientation.
##
## `spec.env` takes any of the spellings sky_env_weights accepts, and any
## parameter written directly on the spec wins over the blend, so a preset can
## say "core, but without the dust" without inventing a sixth environment.
##
## `tilt`/`roll` place the observer's view of the galaxy rather than the
## observer: they rotate the galactic frame relative to the scene, which is
## what decides where the band crosses the sky. There is only ONE frame however
## many environments are blended — you are standing in one galaxy, so a blend
## mixes how much of each population you see, never where their planes are.
static func apply_sky_environment(mats: Array, spec: Dictionary = {}) -> void:
	var p := blend_environments(spec.get("env"))
	p.merge(spec, true)   # { ...blend, ...spec }

	for pm in SKY_PARAMS:
		_set_all(mats, pm.uniform, float(p[pm.key]))

	# Orient the galactic frame. tilt/roll are plain Euler angles on the plane
	# normal; the centre direction is then any unit vector orthogonal to it.
	var tilt := float(spec.tilt) if spec.has("tilt") and spec.tilt != null else 0.34
	var roll := float(spec.roll) if spec.has("roll") and spec.roll != null else 0.9
	var frame := galactic_frame(tilt, roll)
	_set_all(mats, "uGalNormal", frame[0])
	_set_all(mats, "uGalCenter", frame[1])
	_set_all(mats, "uGalEast", frame[2])

## The galactic frame [normal, centre, east] for a tilt/roll, in doubles and
## only then truncated — the arithmetic of applySkyEnvironment, exposed so a
## caller (the settings panel, a test) can know where the band is.
static func galactic_frame(tilt: float, roll: float) -> Array:
	var n := DVec3.new(sin(tilt) * cos(roll), cos(tilt), sin(tilt) * sin(roll)).normalized()
	# Pick any vector not parallel to n, project it out, and that is "toward the
	# centre"; uGalEast completes a right-handed frame so longitude is well
	# defined everywhere.
	var seed := DVec3.new(1, 0, 0) if absf(n.y) > 0.9 else DVec3.new(0, 1, 0)
	var c := seed.sub(n.scaled(seed.dot(n))).normalized()
	var e := n.cross(c).normalized()
	return [n.to_v3(), c.to_v3(), e.to_v3()]

## The unlensed pixel footprint — the reference the measured per-pixel footprint
## is compared against to recover the magnification, and the anchor for both
## ends of the magnification clamp.
##
## The PSF itself is not set here. It is a constant number of PIXELS, which is
## the right invariant for this renderer: an instrument's PSF is fixed on its
## detector, so a star covers the same little disc on screen whatever the fov
## and whatever the lens in front of it is doing.
##
## `fov` is the VERTICAL field of view in radians; `height` is the height of
## the rendered frame in DEVICE pixels (the web build's innerHeight × pixel
## ratio — pipe.render_size.y here).
static func apply_sky_optics(mats: Array, fov: float, height: float) -> void:
	_set_all(mats, "uPixAngle", fov / maxf(1.0, height))

## The per-frame form of apply_sky_optics. The web build's render loop did
##   syncSky(u => { u.uPixAngle.value = fovRad / (innerHeight * pixelRatio); })
## every frame, because the sky's footprint reference has to track the CURRENT
## fov, not the one at the last resize: it is what the measured per-pixel
## footprint is compared against to recover the magnification, so a zoom that
## changed it silently would make every star near the ring the wrong
## brightness. Call with (deg_to_rad(camera.fov), pipe.render_size.y).
static func update_pix_angle(mats: Array, fov_rad: float, height_px: float) -> void:
	_set_all(mats, "uPixAngle", fov_rad / height_px if height_px > 0.0 else fov_rad)
