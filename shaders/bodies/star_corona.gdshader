// CORONA / AUREOLE as a camera-facing billboard, not a shell (a shell's fresnel makes
// a hard bubble ring), so brightness falls off smoothly and streamers can be drawn in
// screen space. The product uColor·a·(a/2) is formed here and blended ONE, ONE
// (blend_premul_alpha, ALPHA = 0). Depth test off: it adds over the photosphere.
// The temperature pass writes only the spicule fringe (replace, ALPHA = 1).
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);
uniform float uFlux = 1.0;
uniform float uSize = 1.0;
uniform float uCore = 0.22;
// The chromosphere's H-α red, for the spicule fringe at the limb (linear).
uniform vec3 uChromo = vec3(1.0, 0.144, 0.058);

varying vec2 vP;
varying vec3 vView;
varying vec3 vCentre;

void vertex() {
	vP = VERTEX.xy;
	// billboard: offset in view space from the object's origin
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vCentre = centre.xyz;
	vView = centre.xyz + vec3(VERTEX.xy * uSize, 0.0);
	POSITION = PROJECTION_MATRIX * (centre + vec4(VERTEX.xy * uSize, 0.0, 0.0));
}

float hsh(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hsh(i), hsh(i + vec2(1.0, 0.0)), f.x), mix(hsh(i + vec2(0.0, 1.0)), hsh(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p0) {
	vec2 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.1; a *= 0.5; }
	return v;
}

void fragment() {
	float r = length(vP);
	if (r > 1.0) discard;
	float ang = atan(vP.y, vP.x);

	// smooth radial falloff — no hard edge anywhere
	float glow = exp(-(r - uCore) * 5.5);
	// a tight, bright inner aureole hugging the photosphere
	glow += exp(-(r - uCore) * 26.0) * 1.4;

	// radial streamers, slowly churning
	float streak = fbm(vec2(ang * 3.2, r * 3.0 - uTime * 0.05));
	glow *= 0.55 + streak * 0.95;

	// fade to nothing at the quad's edge so the billboard never shows
	glow *= 1.0 - smoothstep(0.72, 1.0, r);

	float a = clamp(glow, 0.0, 4.0) * uFlux;
	float srcA = a * 0.5;

	// The view ray's closest approach to the star's centre, in stellar radii past the
	// limb: exact from any viewpoint, which the billboard's own radius is not.
	vec3 d = normalize(vView);
	float R = uCore * uSize;
	float x = length(vCentre - d * dot(vCentre, d)) / R - 1.0;
	if (dot(vCentre, d) < 0.0) x = 1e3;

	// SPICULES: the chromosphere's top is a forest of jets ~10 Mm (0.015 R) high, so
	// the limb is a ragged red fringe rather than an edge.
	float hgt = 0.009 + 0.010 * fbm(vec2(ang * 260.0, uTime * 0.25)) + 0.004 * vnoise(vec2(ang * 1300.0, 0.0));
	float spic = smoothstep(-0.002, 0.001, x) * (1.0 - smoothstep(hgt * 0.4, hgt, x));
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		// The spicules are 10⁴ K chromosphere, dark outside the visible. The corona's own
		// glow is too faint in visible light for the band remap's coverage, so it leaves
		// the value underneath: off the disc that is the sky's ("already imaged"), which
		// carries the glow into every band, rather than a colour-guessed 5000 K that
		// would black it out.
		if (spic < 0.3 || x <= 0.0) discard;
		ALBEDO = vec3(temp_code(1.0e4), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		ALBEDO = uColor * a * srcA + uChromo * spic * 0.10;
		ALPHA = 0.0;
	}
}
