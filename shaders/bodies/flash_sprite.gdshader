// ============================================================================
// A RADIAL-GRADIENT SPRITE — the web build's THREE.Sprite with a 128×128
// CanvasTexture radial gradient, as used by the flash sprites
// (blackhole_sim.js spawnFlash) and by sim/bodies.js glowSprite().
// ----------------------------------------------------------------------------
// The texture was never a picture, only a gradient, so it is evaluated here
// analytically: up to three colour stops, interpolated linearly in straight
// (un-premultiplied) RGBA as the canvas did, zero past the outer stop.
// CanvasTexture pixels are NoColorSpace — the hex values are sampled AS
// LINEAR and never decoded — so the stop colours are passed RAW
// (U.raw(hex), PORT_GUIDE.md §5).
//
// THREE.Sprite: a unit quad facing the camera, scaled by the object's world
// scale (the column lengths of its model matrix), SpriteMaterial output
// (texel.rgb, texel.a · opacity), AdditiveBlending (SRC_ALPHA, ONE). The product
// is formed here and blended ONE, ONE (blend_premul_alpha with ALPHA = 0);
// the temperature pass adds the web's (texel.a · opacity)² (PORT_GUIDE.md §6).
// Depth-tested, not depth-writing, as SpriteMaterial was.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uStopPos = vec3(0.0, 0.4, 1.0);
uniform vec4 uStop0 = vec4(1.0);
uniform vec4 uStop1 = vec4(1.0, 1.0, 1.0, 0.4);
uniform vec4 uStop2 = vec4(1.0, 1.0, 1.0, 0.0);
uniform float uOpacity = 1.0;

varying vec2 vQ;

void vertex() {
	vQ = VERTEX.xy;
	vec2 sc = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	POSITION = PROJECTION_MATRIX * (centre + vec4(VERTEX.xy * sc, 0.0, 0.0));
}

void fragment() {
	// the gradient's radius is half the canvas: r = 1 at the quad's edge midpoints
	float r = length(vQ) * 2.0;
	vec4 texel;
	if (r <= uStopPos.x) texel = uStop0;
	else if (r <= uStopPos.y) texel = mix(uStop0, uStop1, (r - uStopPos.x) / max(uStopPos.y - uStopPos.x, 1e-6));
	else if (r <= uStopPos.z) texel = mix(uStop1, uStop2, (r - uStopPos.y) / max(uStopPos.z - uStopPos.y, 1e-6));
	else texel = uStop2;
	float a = texel.a * uOpacity;
	if (a <= 0.0) discard;
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(a * a, 0.0, 0.0);
	} else {
		ALBEDO = texel.rgb * a;
	}
	ALPHA = 0.0;
}
