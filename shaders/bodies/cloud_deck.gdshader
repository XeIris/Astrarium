// CLOUDS on the circulation: the same overturning cells that make the deserts clear
// the subtropics, so the deck is a convective equatorial band, clear subtropical
// belts and mid-latitude storm tracks, advected by a zonal wind that reverses between
// trades and westerlies. blend_mix; the temperature pass writes 1.0 at its alpha.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain_noise.gdshaderinc"

uniform float uTime = 0.0;
uniform float uCover = 0.45;
uniform float uStorm = 0.25;
uniform float uSeed = 0.0;
uniform vec3 uTint = vec3(1.0);

varying vec3 vObj;
varying vec3 vWN;
varying vec3 vView;

void vertex() {
	// Camera-relative, never an absolute world coordinate (rocky_surface.gdshader).
	vObj = normalize(VERTEX);
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = normalize(vObj);
	float lat = asin(clamp(p.y, -1.0, 1.0));
	float a = abs(lat);

	// Zonal wind: easterly trades below ~30°, westerlies above. Gaussians squared
	// directly (pow() is undefined for a negative base).
	float ut = a / 0.42;
	float uw = (a - 0.92) / 0.38;
	float u = -0.55 * exp(-ut * ut) + 1.00 * exp(-uw * uw);

	// Flow-mapped, as in giant_body.gdshader: two copies half a period apart,
	// cross-faded to zero weight at each wrap, so the shear never winds up.
	float per = 20.0;
	float ta = mod(uTime, per);
	float tb = mod(uTime + per * 0.5, per);
	float wx = 1.0 - abs(2.0 * ta / per - 1.0);
	float ca = cos(ta * u * 0.05);
	float sa = sin(ta * u * 0.05);
	float cb = cos(tb * u * 0.05);
	float sb = sin(tb * u * 0.05);
	vec3 qa = vec3(ca * p.x - sa * p.z, p.y, sa * p.x + ca * p.z);
	vec3 qb = vec3(cb * p.x - sb * p.z, p.y, sb * p.x + cb * p.z);

	float d = mix(fbm(qb * 5.5 + vec3(uSeed) + vec3(0.0, tb * 0.012, 0.0), 7),
	              fbm(qa * 5.5 + vec3(uSeed) + vec3(0.0, ta * 0.012, 0.0), 7), wx);
	// cyclones: ridged noise is all creases, which is what a frontal band is
	float st = mix(ridged(qb * 7.0 - tb * 0.03, 5), ridged(qa * 7.0 - ta * 0.03, 5), wx) * uStorm;
	d += st * 0.30;

	// where the air is rising there is cloud, where it sinks there is none
	float bi = a / 0.25;
	float bf = (a - 0.95) / 0.30;
	float bh = (a - 0.52) / 0.22;
	float band = clamp(1.00 * exp(-bi * bi)
	                 + 0.70 * exp(-bf * bf)
	                 - 0.80 * exp(-bh * bh), 0.0, 1.25);
	float cover = clamp(uCover * mix(0.30, 1.25, band), 0.0, 1.0);
	float al = sstep(0.62 - cover * 0.44, 0.88 - cover * 0.32, d);
	if (al < 0.01) discard;

	vec3 N = normalize(vWN);
	vec3 lit = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		float diff = sstep(-0.12, 0.28, dot(N, normalize(uSunDir[i])));
		lit += uSunColor[i] * uSunInt[i] * diff;
	}
	lit += vec3(0.04, 0.06, 0.10);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = lit * uTint * mix(1.0, 0.78, uStorm);
	}
	ALPHA = al * 0.93;
}
