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
layout(set = 0, binding = 1) uniform sampler2D tTemp;
layout(set = 0, binding = 2) uniform sampler2D tLocal;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image2D outHdr;
layout(push_constant, std430) uniform PC {
	float mode;       // 0 orrery, 1 orrery + local overlay, 2 model
	float useTemp;    // 1 when the temperature pass rendered this frame
	float pad0, pad1;
} pc;

void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outHdr);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec3 rgb = texelFetch(tScene, p, 0).rgb;
	// 1.0 is "no data: infer the temperature from colour".
	float a = pc.useTemp > 0.5 ? texelFetch(tTemp, p, 0).r : 1.0;
	if(pc.mode > 1.5){
		a = 1.0;
	} else if(pc.mode > 0.5){
		vec4 l = texelFetch(tLocal, p, 0);
		rgb = l.rgb + rgb * (1.0 - clamp(l.a, 0.0, 1.0));
		a = mix(a, 1.0, clamp(l.a, 0.0, 1.0));
	}
	imageStore(outHdr, p, vec4(rgb, a));
}
