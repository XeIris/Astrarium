#[compute]
#version 450
// COMPOSE the frame's HDR buffer: linear radiance in rgb and the temperature code in
// alpha, zipping the colour and temperature passes (docs/godot.md) into the one
// RGBA16F buffer the chain uses.
//   mode 0  orrery        rgb = scene,                         a = temp
//   mode 1  orrery+flight rgb = local + scene·(1 − local.a),   a = mix(temp, 1, local.a)
//           (opaque vehicle pixels are "no data", 1.0)
//   mode 2  model viewer  rgb = model,                         a = 1
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tScene;
layout(set = 0, binding = 1) uniform sampler2D tTemp; // spectral temperature or visible flight coverage
layout(set = 0, binding = 2) uniform sampler2D tOverlay; // local space or diffuse galaxy glow
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D outHdr;
layout(push_constant, std430) uniform PC {
	float mode;       // 0 orrery, 1 orrery + local overlay, 2 model
	float useTemp;    // 1 when the temperature pass rendered this frame
	float addGlow;    // additive galaxy radiance, sampled at the display pixel centre
	float localCoverage;
} pc;

void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outHdr);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec3 rgb = texelFetch(tScene, p, 0).rgb;
	// 1.0 is "no data: infer the temperature from colour".
	float a = pc.useTemp > 0.5 ? texelFetch(tTemp, p, 0).r : 1.0;
	if(pc.addGlow > 0.5){
		rgb += textureLod(tOverlay, (vec2(p) + 0.5) / vec2(sz), 0.0).rgb;
	} else if(pc.mode > 1.5){
		a = 1.0;
	} else if(pc.mode > 0.5){
		vec4 l = texelFetch(tOverlay, p, 0);
		float coverage = pc.localCoverage > 0.5 ? textureLod(tTemp, (vec2(p) + 0.5) / vec2(sz), 0.0).r : l.a;
		coverage = clamp(coverage, 0.0, 1.0);
		rgb = l.rgb + rgb * (1.0 - coverage);
		a = mix(a, 1.0, coverage);
	}
	imageStore(outHdr, p, vec4(rgb, a));
}
