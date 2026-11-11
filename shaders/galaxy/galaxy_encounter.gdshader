// An encounter's stars (sim/galaxy/gal_encounter_visual.gd): one camera-facing quad per star,
// four vertices each, the star's index VERTEX_ID / 4. Its position (encounter frame, kpc) and
// galaxy are a texel of uPos; each galaxy's light per star (Sun-luminances, per channel) and
// blob σ (kpc) are uniforms. A Gaussian of radiance L/(4π)/(2πσ²), widened to no less than
// MIN_PX pixels with its light kept, over a quad of ±2σ that holds erf(√2)² of it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, skip_vertex_transform;

#include "res://shaders/common/temp_pass.gdshaderinc"

const float MIN_PX = 0.7;
const float EXTENT = 2.0;
const float HELD = 0.9110697;

uniform sampler2D uPos : filter_nearest, repeat_disable;
uniform int uTexW = 1024;
// The camera in the encounter's frame, kpc.
uniform vec3 uCam = vec3(0.0);
uniform vec4 uLight[4];
uniform float uSigma[4];
// The glow's: pixel value per L☉ kpc⁻² sr⁻¹ over 4π.
uniform float uGain = 1.0;
uniform float uPix = 1e-3;

varying vec3 vCol;
varying vec2 vUV;

void vertex() {
	int i = VERTEX_ID / 4;
	int c = VERTEX_ID - 4 * i;
	vec2 corner = vec2(c == 1 || c == 2 ? 1.0 : -1.0, c >= 2 ? 1.0 : -1.0);
	vec4 t = texelFetch(uPos, ivec2(i % uTexW, i / uTexW), 0);
	int g = clamp(int(t.w + 0.5), 0, 3);
	vec3 rel = t.xyz - uCam;
	float dist = max(length(rel), 1e-6);
	float s = max(uSigma[g], MIN_PX * uPix * dist);
	vCol = uLight[g].rgb * uGain / (6.2831853 * s * s * HELD);
	vUV = corner * EXTENT;
	vec4 view = VIEW_MATRIX * vec4(rel, 1.0);
	view.xy += corner * EXTENT * s;
	VERTEX = view.xyz;
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	ALBEDO = vCol * exp(-0.5 * dot(vUV, vUV));
}
