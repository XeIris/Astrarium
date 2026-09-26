#[compute]
#version 450
// ============================================================================
// COMPOSITE — sim/postfx.js COMPOSITE_FRAG: bloom back over the frame, the ONE
// tone curve (ACES), vignette, grain, linear → sRGB, and a sub-LSB dither.
// Writes 8-bit sRGB, which is what the web build's default framebuffer held.
// ============================================================================
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tScene;
layout(set = 0, binding = 1) uniform sampler2D tBloom;
layout(rgba8, set = 0, binding = 2) uniform restrict writeonly image2D outImg;
layout(push_constant, std430) uniform PC {
	float bloomStrength, exposure, vignette, grain;
	float time, pad0, pad1, pad2;
} pc;

// ACES RRT+ODT, Stephen Hill's fit. Unlike the cheap Narkowicz curve this
// keeps the characteristic hue shift as things saturate: a red-hot disc edge
// slides orange → yellow → white on its way up, the way film and sensors do.
const mat3 ACESIn = mat3(
	0.59719, 0.07600, 0.02840,
	0.35458, 0.90834, 0.13383,
	0.04823, 0.01566, 0.83777);
const mat3 ACESOut = mat3(
	 1.60475, -0.10208, -0.00327,
	-0.53108,  1.10813, -0.07276,
	-0.07367, -0.00605,  1.07602);
vec3 rrt(vec3 v){
	vec3 a = v * (v + 0.0245786) - 0.000090537;
	vec3 b = v * (0.983729 * v + 0.4329510) + 0.238081;
	return a / b;
}
vec3 acesFitted(vec3 c){
	c = ACESIn * c;
	c = rrt(c);
	c = ACESOut * c;
	return clamp(c, 0.0, 1.0);
}

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outImg);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec2 vUv = (vec2(p) + 0.5) / vec2(sz);
	// gl_FragCoord as WebGL reported it: pixel centres, origin bottom-left.
	vec2 fragCoord = vec2(float(p.x) + 0.5, float(sz.y - p.y) - 0.5);

	vec3 col = texture(tScene, vUv).rgb;
	col += texture(tBloom, vUv).rgb * pc.bloomStrength;

	col *= pc.exposure;
	col = acesFitted(col);

	// Optical vignette — a real lens falls off toward the corners, and the
	// darker frame edge makes the bright centre read as brighter still.
	float r = length(vUv - 0.5) * 1.414;
	col *= 1.0 - pc.vignette * pow(clamp(r, 0.0, 1.0), 2.4);

	// Sensor grain, scaled down in the highlights the way shot noise really is.
	float n = hash(fragCoord + fract(pc.time) * 137.0) - 0.5;
	col += n * pc.grain * (1.0 - 0.7 * dot(col, vec3(0.333)));

	// linear → sRGB
	col = max(col, vec3(0.0));
	vec3 srgb = mix(col * 12.92,
	                1.055 * pow(col, vec3(1.0 / 2.4)) - 0.055,
	                step(0.0031308, col));

	// Ordered-ish dither. 8-bit output over a smooth ACES shoulder bands very
	// visibly against a black sky; a sub-LSB of noise removes it entirely.
	srgb += (hash(fragCoord * 1.7) - 0.5) / 255.0;
	imageStore(outImg, p, vec4(srgb, 1.0));
}
