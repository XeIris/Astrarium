// ============================================================================
// ATMOSPHERE — the port of sim/rocky_visual.js's atmosphereMaterial.
//
// Rayleigh scattering goes as lambda^-4, so the cross sections for R, G, B
// are in the ratio 5.8 : 13.5 : 33.1 per 10^-6 m^-1 — that ratio IS why the
// sky is blue and why the same sky is red along a long path at sunset, and it
// is the only colour information this shell needs.
//
// AdditiveBlending, BackSide, alpha 1 in the web build → blend_add,
// cull_front; its alpha (1·1 + d) saturated the temperature channel to "no
// data" wherever it drew, and the temperature pass reproduces exactly that.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_front;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uThick = 1.0;
uniform vec3 uTint = vec3(1.0);

varying vec3 vWN;
varying vec3 vView;

void vertex() {
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float sstep_a(float e0, float e1, float x) {
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

void fragment() {
	vec3 N = normalize(vWN);
	vec3 V = normalize(vView);
	// Path length through a thin shell goes as 1/|N.V| at grazing angles;
	// that divergence is the bright ring on the limb, and it is capped
	// because the shell is not actually infinitely thin.
	float mu = abs(dot(N, V));
	float path = min(1.0 / max(mu, 0.06), 7.0) - 1.0;
	vec3 beta = normalize(vec3(5.8, 13.5, 33.1));
	vec3 col = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		float lam = sstep_a(-0.35, 0.5, dot(N, L));
		// Along a long path the blue has already been scattered OUT, so what
		// is left arriving is red. That is the sunset, and it belongs on the
		// limb nearest the star.
		float fwd = pow(max(dot(V, -L), 0.0), 4.0);
		vec3 tone = mix(beta, vec3(1.0, 0.40, 0.16), fwd * 0.85);
		col += tone * uSunColor[i] * uSunInt[i] * lam;
	}
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = col * uTint * path * 0.085 * uThick;
	}
	ALPHA = 1.0;
}
