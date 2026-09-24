#[compute]
#version 450
// Bright pass into mip 0 — sim/postfx.js BRIGHT_FRAG.
// Karis average — weight by 1/(1+luma) before averaging so a single blazing
// pixel (a star, a flare kernel) doesn't detonate into a flickering firefly
// when it gets downsampled.
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tSrc;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D outImg;
layout(push_constant, std430) uniform PC { vec2 texel; float threshold; float knee; } pc;
float luma(vec3 c){ return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
vec3 tap(vec2 uv, vec2 o){
	vec3 c = texture(tSrc, uv + o * pc.texel).rgb;
	return c / (1.0 + luma(c));
}
void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outImg);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec2 uv = (vec2(p) + 0.5) / vec2(sz);
	// 4-tap box in the source, Karis-weighted
	vec3 s = tap(uv, vec2(-1.0,-1.0)) + tap(uv, vec2(1.0,-1.0))
	       + tap(uv, vec2(-1.0, 1.0)) + tap(uv, vec2(1.0, 1.0));
	s *= 0.25;
	s = s / max(1.0 - luma(s), 1e-4);     // undo the Karis weighting
	// soft-knee threshold: a gentle shoulder instead of a hard cutoff, so
	// things don't pop in and out of the bloom as they brighten
	float l = luma(s);
	float soft = clamp(l - pc.threshold + pc.knee, 0.0, 2.0 * pc.knee);
	soft = soft * soft / (4.0 * pc.knee + 1e-4);
	float w = max(soft, l - pc.threshold) / max(l, 1e-4);
	imageStore(outImg, p, vec4(s * w, 1.0));
}
