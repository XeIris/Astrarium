// ============================================================================
// CORONA / AUREOLE — port of coronaMaterial() in sim/star_visual.js.
// ----------------------------------------------------------------------------
// Drawn as a CAMERA-FACING BILLBOARD rather than a sphere shell: a shell's
// fresnel term peaks at the shell's own limb, which puts a hard-edged bubble
// ring in space around the star. A billboard lets the brightness fall off
// smoothly with radius, the way a real corona does, and lets us draw radial
// streamers in screen space.
//
// BLENDING. The web material was AdditiveBlending (SRC_ALPHA, ONE) with
// gl_FragColor = (uColor·a, a/2), so it added uColor·a·(a/2) to colour and
// (a/2)² to the temperature channel. a reaches 4, so the "alpha" reaches 2 —
// legal in a float target, but not something to trust to a blend factor here.
// So the product is formed in the shader and blended ONE, ONE
// (blend_premul_alpha with ALPHA = 0; PORT_GUIDE.md §6), which is the same
// arithmetic without the factor. Depth test off, as the web's: it is drawn
// after the opaque photosphere and adds over it.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);
uniform float uFlux = 1.0;
uniform float uSize = 1.0;
uniform float uCore = 0.22;

varying vec2 vP;

void vertex() {
	vP = VERTEX.xy;
	// billboard: offset in view space from the object's origin
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
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
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(srcA * srcA, 0.0, 0.0);   // additive alpha: a·a + d
	} else {
		ALBEDO = uColor * a * srcA;
	}
	ALPHA = 0.0;
}
