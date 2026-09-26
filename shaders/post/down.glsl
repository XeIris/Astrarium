#[compute]
#version 450
// Progressive downsample — sim/postfx.js DOWN_FRAG.
// 13-tap partial-tent kernel (Jimenez / CoD): far better mip stability than a
// box filter, which is what stops the halo from crawling.
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tSrc;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D outImg;
layout(push_constant, std430) uniform PC { vec2 texel; float pad0; float pad1; } pc;
vec3 t(vec2 uv, vec2 o){ return texture(tSrc, uv + o * pc.texel).rgb; }
void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outImg);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec2 uv = (vec2(p) + 0.5) / vec2(sz);
	vec3 a = t(uv, vec2(-2.0, 2.0)), b = t(uv, vec2(0.0, 2.0)), c = t(uv, vec2(2.0, 2.0));
	vec3 d = t(uv, vec2(-2.0, 0.0)), e = t(uv, vec2(0.0, 0.0)), f = t(uv, vec2(2.0, 0.0));
	vec3 g = t(uv, vec2(-2.0,-2.0)), h = t(uv, vec2(0.0,-2.0)), i = t(uv, vec2(2.0,-2.0));
	vec3 j = t(uv, vec2(-1.0, 1.0)), k = t(uv, vec2(1.0, 1.0));
	vec3 l = t(uv, vec2(-1.0,-1.0)), m = t(uv, vec2(1.0,-1.0));
	vec3 o = e * 0.125;
	o += (a + c + g + i) * 0.03125;
	o += (b + d + f + h) * 0.0625;
	o += (j + k + l + m) * 0.125;
	imageStore(outImg, p, vec4(o, 1.0));
}
