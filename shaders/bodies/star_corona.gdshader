// THE ATMOSPHERE ABOVE THE LIMB, as a camera-facing billboard (a shell's fresnel makes
// a hard bubble ring): the chromosphere's spicule forest, the transition region's glow
// that He II 304 Å images show, and the white-light corona with its streamers. All three
// are optically thin, blended ONE, ONE (blend_premul_alpha, ALPHA = 0); depth test off,
// so they add over the photosphere's edge. The temperature pass writes only the spicule
// fringe (replace, ALPHA = 1). Models: docs/physics/stellar-surfaces.md.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/star_noise.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);
uniform float uFlux = 1.0;
uniform float uSize = 1.0;
uniform float uCore = 0.22;
// The photosphere's breathing, so the limb features stay on the limb.
uniform float uRScale = 1.0;
// The chromosphere's colour (linear) and display weight (StarVisual.CHROMO_GAIN); 0 for
// a star without a convective envelope, which has neither spicules nor a transition region.
uniform vec3 uChromo = vec3(1.0, 0.30, 0.09);
uniform float uChromoW = 0.0;
// The photosphere's flattening 1 − R_pole/R_eq; uSize is sized to the equator.
uniform float uFlat = 0.0;

varying vec2 vP;
varying vec3 vView;
varying vec3 vCentre;
varying vec2 vAxis;
varying float vScale;
varying float vMinor;

void vertex() {
	vP = VERTEX.xy;
	// The orchestrator's group scale is in MODELVIEW; the billboard offset is not.
	vScale = length(MODELVIEW_MATRIX[0].xyz);
	float size = uSize * vScale;
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vCentre = centre.xyz;
	vView = centre.xyz + vec3(VERTEX.xy * size, 0.0);
	// The spin axis on the billboard, which streamers and plumes are arranged about.
	vec3 ax = (MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	vAxis = length(ax.xy) > 1e-6 * vScale ? normalize(ax.xy) : vec2(0.0, 1.0);
	// A spheroid's outline is an ellipse: the equator across the projected axis, and
	// along it the pole foreshortened by the axis's tilt out of the sky.
	float sinI = clamp(length(ax.xy) / max(length(ax), 1e-12), 0.0, 1.0);
	float q = 1.0 - uFlat;
	vMinor = sqrt(q * q * sinI * sinI + (1.0 - sinI * sinI));
	POSITION = PROJECTION_MATRIX * (centre + vec4(VERTEX.xy * size, 0.0, 0.0));
}

void fragment() {
	float r = length(vP);
	if (r > 1.0) discard;
	vec2 d2 = vP / max(r, 1e-6);

	// The view ray's closest approach to the star's centre, in stellar radii past the
	// limb: exact from any viewpoint, which the billboard's own radius is not.
	vec3 d = normalize(vView);
	float R = uCore * uSize * vScale * uRScale;
	float ca = dot(d2, vAxis);
	float limbR = vMinor / sqrt(vMinor * vMinor * (1.0 - ca * ca) + ca * ca);
	float x = (length(vCentre - d * dot(vCentre, d)) / R - limbR) / limbR;
	if (dot(vCentre, d) < 0.0) x = 1e3;
	float h = max(x, 0.0);
	// Latitude of the limb point behind this pixel (exact when the axis is in the sky).
	float lat = asin(clamp(ca, -1.0, 1.0));
	float alat = abs(lat);
	// Fine structure fades as it falls below a pixel.
	float px = length(fwidth(vP)) / uCore;        // stellar radii per pixel
	float aaS = 1.0 - smoothstep(0.004, 0.012, px);
	float aaR = 1.0 - smoothstep(0.02, 0.06, px);

	// --- THE CORONA: the K-corona falls off steeply; helmet streamers rise over the active
	// belts and narrow into rays, polar plumes stand over the dark coronal holes.
	float kc = pow(1.0 + h, -4.0) * 0.55 + exp(-h * 9.0) * 0.45;
	float bl = lat / 0.62;
	float belt = exp(-bl * bl);
	float ray = sn_fbm(vec3(d2 * 3.2 * (1.0 + 1.6 * h), 0.25 * h + uTime * 0.004), 3);
	float helmet = smoothstep(0.42, 0.78, ray) * belt;
	float plume = smoothstep(0.5, 0.9, sn_noise(vec3(d2 * 48.0, h * 1.5))) * smoothstep(0.9, 1.35, alat) * exp(-h * 2.5);
	float corona = kc * (0.45 * (1.0 - 0.45 * smoothstep(0.85, 1.3, alat)) + 1.5 * helmet + 0.12 * plume * aaR);
	corona *= uFlux * (1.0 - smoothstep(0.72, 1.0, r));

	// --- THE TRANSITION REGION's glow, clumped over the network: the soft halo just off
	// the limb in He II images.
	float clump = sn_fbm(vec3(d2 * 18.0, h * 6.0 - uTime * 0.02), 3);
	float tr = (exp(-h / 0.022) * 1.6 + exp(-h / 0.09) * 0.35) * (0.55 + 0.9 * clump);

	// --- SPICULES: the chromosphere's top is a forest of jets ~10 Mm (0.015 R) high and
	// leaning, so the limb is a ragged fringe rather than an edge.
	float lean = 0.6 * (sn_noise(vec3(d2 * 40.0, 3.0)) - 0.5);
	vec2 dl = d2 + vec2(-d2.y, d2.x) * (h * lean * 4.0);
	float jets = sn_noise(vec3(dl * 190.0, uTime * 0.18)) * 0.6 + sn_noise(vec3(dl * 430.0, uTime * 0.3)) * 0.4;
	jets = mix(0.5, jets, aaS);
	float hgt = 0.008 + 0.014 * sn_noise(vec3(d2 * 60.0, uTime * 0.05)) + 0.010 * jets;
	float spic = (1.0 - smoothstep(hgt * 0.35, hgt, h)) * (0.35 + 1.1 * jets);
	// Fade in across the limb itself; the photosphere draws the layer inside it.
	float onLimb = smoothstep(-0.004, 0.002, x);
	spic *= onLimb;
	tr *= onLimb;
	corona *= smoothstep(-0.01, 0.0, x);

	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		// The spicules are 10⁴ K chromosphere, dark outside the visible. The corona's own
		// glow is too faint in visible light for the band remap's coverage, so it leaves
		// the value underneath: off the disc that is the sky's ("already imaged"), which
		// carries the glow into every band, rather than a colour-guessed 5000 K that
		// would black it out.
		if (uChromoW <= 0.0 || spic < 0.3 || x <= 0.0) discard;
		ALBEDO = vec3(temp_code(1.0e4), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = uColor * corona * 0.45 + uChromo * (uChromoW * (spic * 7.0 + tr * 2.2));
		ALPHA = 0.0;
	}
}
