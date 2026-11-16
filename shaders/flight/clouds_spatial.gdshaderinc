#include "res://shaders/flight/clouds.gdshaderinc"
#include "res://shaders/flight/clouds_march.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;

varying vec3 vDir;

void vertex() {
	vDir = (MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz;
}

#ifdef CLOUD_REDUCED
uniform sampler2D uReduced : filter_nearest, repeat_disable;
uniform sampler2D uReducedClip : filter_nearest, repeat_disable;
uniform ivec2 uCloudInputSize;

// Negative alpha requests a full march. Reject neighbours on discontinuities
// before reconstructing a pixel at a tower, vehicle or ground silhouette.
vec4 cloud_resolve(ivec2 px, ivec2 size, float scene, float shell_end) {
	if (size != uCloudInputSize || textureSize(uReduced, 0) != (size + ivec2(1)) / 2) return vec4(-1.0);
	if (((px.x | px.y) & 1) == 0) return texelFetch(uReduced, px / 2, 0);
	if (any(lessThanEqual(px, ivec2(0))) || any(greaterThanEqual(px + ivec2(1), size))) return vec4(-1.0);

	vec4 layer = vec4(0.0);
	vec4 low = vec4(65504.0);
	vec4 high = vec4(0.0);
	vec2 frac_px = vec2(px & ivec2(1)) * 0.5;
	for (int i = 0; i < 4; i++) {
		ivec2 offset = ivec2(i & 1, i / 2);
		vec2 weight = mix(vec2(1.0) - frac_px, frac_px, vec2(offset));
		if (weight.x * weight.y == 0.0) continue;
		ivec2 tap = px / 2 + offset;
		float sampled = texelFetch(uReducedClip, tap, 0).r;
		if (min(scene, sampled) < shell_end && abs(sampled - scene) > max(5.0, scene * 0.005)) return vec4(-1.0);
		vec4 color = texelFetch(uReduced, tap, 0);
		if (color.a < 0.0) return vec4(-1.0);
		low = min(low, color);
		high = max(high, color);
		layer += color * weight.x * weight.y;
	}
	vec4 limit = 0.16 * max(high, vec4(0.12, 0.12, 0.12, 0.5));
	return all(lessThanEqual(high - low, limit)) ? layer : vec4(-1.0);
}
#endif

void fragment() {
	if (uCloudCoverage <= 0.0) discard;
	vec3 rd = normalize(vDir);
	vec2 interval = cloud_interval(uCamLocal, rd);
	if (interval.y <= interval.x) discard;
	// Opaque ground, tower and vehicle geometry clip the cloud on every pixel.
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene = length(v.xyz / v.w);
	float shell_end = min(interval.y, uMaxDist);
	float t1 = min(shell_end, scene);
	if (t1 <= interval.x) discard;

	vec4 layer = vec4(-1.0);
	float jitter = ign(FRAGCOORD.xy);
#ifdef CLOUD_REDUCED
	ivec2 px = ivec2(FRAGCOORD.xy);
	ivec2 size = ivec2(VIEWPORT_SIZE);
	if (size == uCloudInputSize) {
		layer = cloud_resolve(px, size, scene, shell_end);
		jitter = cloud_jitter(px);
	}
#endif
	if (layer.a < 0.0) layer = cloud_march(uCamLocal, rd, interval.x, t1, jitter);
	if (layer.a <= 0.002) discard;
	ALBEDO = layer.rgb;
	ALPHA = layer.a;
}
