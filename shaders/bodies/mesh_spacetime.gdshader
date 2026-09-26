// ============================================================================
// THE SPACETIME MESH — the web's meshMat (blackhole_sim.js), on a line mesh
// built to match THREE's `wireframe: true` (see sim/spacetime_mesh.gd).
// Each well dips the sheet: a hole as 2.4 s / (0.5 + 0.14 d), anything else
// as 0.8 s / (d + 0.5), with d measured in the slab's own (recentred) plane.
//
// BLENDING: a transparent NormalBlending material that still writes depth
// (THREE's default depthWrite for a transparent material). In the temperature
// pass it is the NormalBlending row: R = 1, ALPHA = a, so the channel becomes
// a + d(1 − a), as the web's alpha did.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float time = 0.0;
uniform vec4 wells[16];
uniform int wellCount = 0;

varying float vDepth;
varying vec2 vPos;

void vertex() {
	vec3 p = VERTEX;
	vPos = p.xz;
	float dip = 0.0;
	for (int i = 0; i < 16; i++) {
		if (i >= wellCount) break;
		float d = distance(p.xz, wells[i].xy);
		float s = wells[i].z;
		float isHole = wells[i].w;
		if (isHole > 0.5) dip += s * 2.4 / (0.5 + d * 0.14);
		else dip += s * 0.8 / (d + 0.5);
	}
	p.y -= dip;
	vDepth = dip;
	VERTEX = p;
}

void fragment() {
	float r = length(vPos);
	float alpha = (1.0 - smoothstep(18.0, 60.0, r)) * 0.30 + 0.04;
	float it = clamp(vDepth * 0.08 + 0.1, 0.0, 1.0);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = mix(vec3(0.2, 0.35, 0.6), vec3(0.8, 0.4, 0.15), it);
	}
	ALPHA = alpha;
}
