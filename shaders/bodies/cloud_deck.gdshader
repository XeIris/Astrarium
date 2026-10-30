// CLOUDS on the circulation: the same overturning cells that make the deserts clear
// the subtropics, so the deck is a convective equatorial band, clear subtropical
// belts and mid-latitude storm tracks, advected by a zonal wind that reverses between
// trades and westerlies. Coverage is calibrated: the noise is near-normal, so the
// threshold at probit z leaves Φ(z) of the sky opaque, and z comes from the world's
// cloudCover and the shared climatology (cloud_climate.gdshaderinc).
// blend_mix; the temperature pass writes 1.0 at its alpha.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_back;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain_noise.gdshaderinc"
#include "res://shaders/common/cloud_climate.gdshaderinc"

uniform float uTime = 0.0;
uniform float uCover = 0.45;     // global fraction under opaque cloud; 0 draws nothing
uniform float uCloudZ = 0.0;     // Terrain.cloud_global_z(uCover)
uniform float uItcz = 0.0;       // the ITCZ's latitude, rad
uniform float uStorm = 0.25;
uniform float uSeed = 0.0;
uniform vec3 uTint = vec3(1.0);
// Earth's mapped colour and land (PlanetMaps kind 1), for the deserts. uSurfTurn is the
// deck's turn relative to the surface (cloud phase − spin phase).
uniform float uMapKind = 0.0;
uniform float uSurfTurn = 0.0;
uniform sampler2D uColorMap : source_color, hint_default_black, filter_linear_mipmap, repeat_enable;
uniform sampler2D uLandMask : hint_default_black, filter_linear_mipmap, repeat_enable;

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

	// Seven octaves of value noise are near-normal (mean 0.497, sd 0.1065; see
	// Terrain.crust_threshold); the cross-fade of two independent copies shrinks the sd
	// by sqrt(w² + (1 − w)²), which is divided back out so coverage doesn't pulse.
	float spread = 0.1065 * sqrt(wx * wx + (1.0 - wx) * (1.0 - wx));
	float d = (mix(fbm(qb * 5.5 + vec3(uSeed) + vec3(0.0, tb * 0.012, 0.0), 7),
	               fbm(qa * 5.5 + vec3(uSeed) + vec3(0.0, ta * 0.012, 0.0), 7), wx) - 0.497) / spread;
	// Cyclones: ridged noise is all creases, which is what a frontal band is. Five octaves
	// have mean 0.684 and sd 0.120; added in sd units and the sum renormalised.
	float st = (mix(ridged(qb * 7.0 - tb * 0.03, 5), ridged(qa * 7.0 - ta * 0.03, 5), wx) - 0.684)
		/ (0.120 * sqrt(wx * wx + (1.0 - wx) * (1.0 - wx)));
	float ks = 2.4 * uStorm;
	d = (d + ks * st) / sqrt(1.0 + ks * ks);

	// Opaque where d beats −z, so Φ(z) of the sky is cloud. The ramp is symmetric about
	// the threshold (±0.7 sd), so the thin edges don't shift the mean cover.
	float z = uCloudZ + cloud_zonal_z(lat, uItcz);
	if (uCover <= 0.0) discard;
	if (uMapKind > 0.5 && uMapKind < 1.5) {
		// Deserts are where the subsiding air is also dry, so they are clearer than their
		// latitude (Sahara ~0.1 against a zonal 0.3). Arid = bright land that is redder
		// than green; ice is bright but grey. A coarse mip: cloud answers to the region,
		// not the pixel. UVs as RockyVisual.sphere_geometry.
		vec3 ps = vec3(cos(uSurfTurn) * p.x + sin(uSurfTurn) * p.z, p.y,
		               -sin(uSurfTurn) * p.x + cos(uSurfTurn) * p.z);
		vec2 uv = vec2(fract(atan(ps.z, -ps.x) / 6.2831853), acos(clamp(ps.y, -1.0, 1.0)) / 3.14159265);
		vec3 m = textureLod(uColorMap, uv, 5.0).rgb;
		float land = textureLod(uLandMask, uv, 5.0).r;
		float lum = dot(m, vec3(0.2126, 0.7152, 0.0722));
		float arid = land * sstep(0.10, 0.28, lum) * sstep(0.02, 0.12, m.r - m.g);
		z -= 0.9 * arid;
	}
	float al = sstep(-z - 0.7, -z + 0.7, d);
	if (al < 0.01) discard;

	vec3 N = normalize(vWN);
	vec3 lit = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		float diff = sstep(-0.12, 0.28, dot(N, normalize(uSunDir[i])));
		lit += uSunColor[i] * uSunInt[i] * diff;
	}
	// Night-side cloud is lit only by moon and airglow; a trace keeps the limb readable.
	lit += vec3(0.012, 0.018, 0.030);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = lit * uTint * mix(1.0, 0.78, uStorm);
	}
	ALPHA = al * 0.93;
}
