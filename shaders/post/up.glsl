#[compute]
#version 450
// Upsample + accumulate — sim/postfx.js UP_FRAG. The web build drew this 9-tap
// tent ADDITIVELY into the next-larger mip, on top of the downsample already
// there. A compute pass cannot blend, so the addition is written out: the
// result is the base level plus the tent of the (already accumulated) smaller
// level, which is the same number the blend produced.
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tSrc;    // smaller, accumulated level
layout(set = 0, binding = 1) uniform sampler2D tBase;   // this level's downsample
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image2D outImg;
layout(push_constant, std430) uniform PC { vec2 texel; float radius; float pad0; } pc;
vec3 t(vec2 uv, vec2 o){ return texture(tSrc, uv + o * pc.texel * pc.radius).rgb; }
void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outImg);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec2 uv = (vec2(p) + 0.5) / vec2(sz);
	vec3 o = t(uv, vec2( 0.0, 0.0)) * 4.0;
	o += (t(uv, vec2(-1.0, 0.0)) + t(uv, vec2(1.0, 0.0))
	    + t(uv, vec2( 0.0,-1.0)) + t(uv, vec2(0.0, 1.0))) * 2.0;
	o +=  t(uv, vec2(-1.0,-1.0)) + t(uv, vec2(1.0,-1.0))
	    + t(uv, vec2(-1.0, 1.0)) + t(uv, vec2(1.0, 1.0));
	vec3 base = texelFetch(tBase, p, 0).rgb;
	imageStore(outImg, p, vec4(base + o / 16.0, 1.0));
}
