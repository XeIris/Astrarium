// A galaxy's H II regions (sim/galaxy/gal_hii.gd): one camera-facing quad per region, its
// centre (galaxy-local kpc) in VERTEX, its cluster's visible light per channel (Sun-luminances)
// in CUSTOM0.rgb, the quad's corner and the nebula's σ (kpc) in CUSTOM1, the nebula's lines in
// CUSTOM2.rgb. Each is a Gaussian of radiance L/(4π)/(2πσ²), the cluster a point (MIN_PX wide),
// the nebula no narrower; both dimmed by the model's dust between the region and the camera.
// The sum is clipped at zero per pixel: Hα lies outside sRGB.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_disabled, skip_vertex_transform;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/galaxy/gal_model.gdshaderinc"

const float MIN_PX = 0.7;
// The quad spans ±2σ of the nebula, which holds erf(√2)² = 0.911 of its light and erf(√2 q)² of
// the cluster's, q = σ_nebula/σ_cluster: each is scaled up to keep all of it. ±3σ would hold
// 0.995 at 2.25 times the fragments.
const float EXTENT = 2.0;

// Abramowitz & Stegun 7.1.26, |error| < 1.5e-7, for x ≥ 0.
float erf_pos(float x) {
	float t = 1.0 / (1.0 + 0.3275911 * x);
	float y = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 + t * (-1.453152027 + t * 1.061405429))));
	return 1.0 - y * exp(-x * x);
}
const int N_DUST = 16;

uniform vec3 uCamLocal = vec3(0.0, 0.0, 60.0);
// The glow's: pixel value per L☉ kpc⁻² sr⁻¹ over 4π.
uniform float uGain = 1.0;
// One pixel's angle (rad).
uniform float uPix = 1e-3;
uniform vec3 uExt = vec3(0.748, 1.0, 1.324);

varying vec3 vStars;
varying vec3 vLines;
varying vec2 vUV;
varying float vQ;

// V optical depth from p toward the camera through the dust layer, which ends where the
// exponential layer has fallen to e⁻⁸.
float dust_to_camera(vec3 p, vec3 dir, float dist) {
	float layer = 8.0 * max(uDustMap.y, 0.01);
	float t1 = dist;
	if (abs(dir.y) > 1e-6) {
		float exit = (sign(dir.y) * layer - p.y) / dir.y;
		t1 = min(t1, max(exit, 0.0));
	}
	float dt = t1 / float(N_DUST);
	float tau = 0.0;
	for (int i = 0; i < N_DUST; i++) {
		tau += gal_dust(p + dir * ((float(i) + 0.5) * dt)) * dt;
	}
	return tau;
}

void vertex() {
	vec3 c = VERTEX;
	vec3 rel = c - uCamLocal;
	float dist = max(length(rel), 1e-6);
	float sc = MIN_PX * uPix * dist;
	float s = max(CUSTOM1.z, sc);
	vec3 att = exp(-dust_to_camera(c, -rel / dist, dist) * uExt);
	vQ = s / sc;
	float held_n = pow(erf_pos(EXTENT * 0.70710678), 2.0);
	float held_c = pow(erf_pos(EXTENT * vQ * 0.70710678), 2.0);
	vStars = CUSTOM0.rgb * att * uGain / (6.2831853 * sc * sc * held_c);
	vLines = CUSTOM2.rgb * att * uGain / (6.2831853 * s * s * held_n);
	vUV = CUSTOM1.xy * EXTENT;
	vec4 view = MODELVIEW_MATRIX * vec4(c, 1.0);
	// The quad's half-width in view units: kpc times the group's scale.
	view.xy += CUSTOM1.xy * EXTENT * s * length(MODELVIEW_MATRIX[0].xyz);
	VERTEX = view.xyz;
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r2 = dot(vUV, vUV);
	ALBEDO = max(vLines * exp(-0.5 * r2) + vStars * exp(-0.5 * r2 * vQ * vQ), vec3(0.0));
}
