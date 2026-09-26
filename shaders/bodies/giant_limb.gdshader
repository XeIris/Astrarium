// ============================================================================
// LIMB HAZE — a giant has no edge. The disc fades into a thin bright rim of
// forward-scattering aerosol several scale heights above the deck, and without
// it the silhouette is a hard circle, which is the tell that you are looking at
// a solid ball. (Port of sim/giant_visual.js's limbMaterial.)
//
// AdditiveBlending, BackSide, alpha 1 → blend_add, cull_front; in the
// temperature pass it writes 1 at alpha 1, i.e. "no data", as the web build's
// saturated alpha did.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_front;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain_noise.gdshaderinc"

uniform vec3 uTint = vec3(1.0);

varying vec3 vWN;
varying vec3 vView;

void vertex() {
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 N = normalize(vWN);
	vec3 V = normalize(vView);
	float rim = pow(1.0 - abs(dot(N, V)), 3.0);
	vec3 col = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		float lam = sstep(-0.30, 0.45, dot(N, L));
		float fwd = 0.4 + 1.6 * pow(max(dot(V, -L), 0.0), 3.0);
		col += uTint * uSunColor[i] * uSunInt[i] * lam * fwd;
	}
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = col * rim * 0.30;
	}
	ALPHA = 1.0;
}
