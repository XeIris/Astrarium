#[compute]
#version 450
layout(local_size_x = 8, local_size_y = 8) in;

layout(set = 0, binding = 0) uniform sampler2D tLocalColor;
layout(r16f, set = 0, binding = 1) uniform restrict writeonly image2D outCoverage;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, imageSize(outCoverage)))) return;
	imageStore(outCoverage, pixel, vec4(texelFetch(tLocalColor, pixel, 0).a));
}
