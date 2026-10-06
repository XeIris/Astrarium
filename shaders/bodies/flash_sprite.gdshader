// A RADIAL-GRADIENT SPRITE for flashes: up to three
// colour stops interpolated in straight RGBA, zero past the outer stop, with raw
// (linear, U.raw(hex)) colours. A unit camera-facing quad scaled by the world scale;
// output (texel.rgb, texel.a · opacity) formed here and blended ONE, ONE; the
// temperature pass adds (texel.a · opacity)². Depth-tested, not writing.
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
