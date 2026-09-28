// The same world-space triangular lattice is drawn over every geometry band.
// Grid density follows the camera zoom; triangle count only controls how
// smoothly the physical sheet bends around gravity wells.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float time = 0.0;
uniform vec4 wells[16];
uniform int wellCount = 0;
uniform float grid_step = 1.0;

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
		if (wells[i].w > 0.5) dip += s * 2.4 / (0.5 + d * 0.14);
		else dip += s * 0.8 / (d + 0.5);
	}
	p.y -= dip;
	vDepth = dip;
	VERTEX = p;
}

void fragment() {
	vec2 uv = vPos / grid_step;
	vec2 cell = fract(uv);
	float axis_d = min(min(cell.x, 1.0 - cell.x), min(cell.y, 1.0 - cell.y));
	float diagonal_d = abs(cell.x + cell.y - 1.0) * 0.70710678;
	float d = min(axis_d, diagonal_d);
	vec2 footprint = fwidth(uv);
	float pixel = max(max(footprint.x, footprint.y), 0.0001);
	float coverage = 1.0 - smoothstep(pixel * 0.35, pixel * 1.2, d);
	float alias_fade = 1.0 - smoothstep(0.32, 0.70, pixel);
	float radius = length(vPos);
	float alpha = coverage * alias_fade * mix(0.38, 0.22, smoothstep(18.0, 500.0, radius));
	alpha *= 1.0 - smoothstep(24576.0, 30720.0, radius);
	if (alpha < 0.002) discard;
	float it = clamp(vDepth * 0.08 + 0.1, 0.0, 1.0);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = mix(vec3(0.2, 0.35, 0.6), vec3(0.8, 0.4, 0.15), it);
	}
	ALPHA = alpha;
}
