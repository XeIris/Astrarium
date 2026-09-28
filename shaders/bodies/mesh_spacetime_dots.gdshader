// One shaded bead per world-space cell. Its centre follows the deformed sheet,
// while its silhouette stays round in screen space even at oblique angles.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_always, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float time = 0.0;
uniform vec4 wells[16];
uniform int wellCount = 0;
uniform float grid_step = 1.0;
uniform vec2 viewport_size = vec2(1600.0, 1000.0);

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

vec2 cell_jitter(vec2 cell) {
	vec2 seed = vec2(dot(cell, vec2(127.1, 311.7)), dot(cell, vec2(269.5, 183.3)));
	return (fract(sin(seed) * 43758.5453) - 0.5) * 0.30;
}

void fragment() {
	vec2 uv = vPos / grid_step;
	vec2 cell = floor(uv + 0.5);
	vec2 footprint = fwidth(uv);
	float alias_fade = 1.0 - smoothstep(0.32, 0.70, max(footprint.x, footprint.y));
	if (alias_fade < 0.002) discard;
	vec2 jitter = cell_jitter(cell);
	vec2 local = uv - cell - jitter;
	// Most of the transparent sheet is empty. Reject it before projecting and
	// lighting a bead; widen the guard where perspective compresses the cells.
	float guard = clamp(max(footprint.x, footprint.y) * 4.5, 0.27, 0.48);
	if (max(abs(local.x), abs(local.y)) > guard) discard;
	vec2 centre = (cell + jitter) * grid_step;
	// Project the bead centre rather than measuring distance on the sheet.
	// Planar discs become ellipses near the horizon; these remain little spheres.
	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * MODEL_MATRIX * vec4(centre.x, -vDepth, centre.y, 1.0);
	if (clip.w <= 0.0) discard;
	vec2 centre_uv = clip.xy / clip.w * 0.5 + 0.5;
	vec2 offset = (SCREEN_UV - centre_uv) * viewport_size;
	float bead_radius = 2.9;
	float bead_distance = length(offset);
	float coverage = 1.0 - smoothstep(bead_radius - 0.8, bead_radius + 0.2, bead_distance);
	float radius = length(vPos);
	float alpha = coverage * alias_fade * mix(0.98, 0.78, smoothstep(18.0, 500.0, radius));
	alpha *= 1.0 - smoothstep(24576.0, 30720.0, radius);
	if (alpha < 0.002) discard;
	float it = clamp(vDepth * 0.08 + 0.1, 0.0, 1.0);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		vec2 disk = offset / bead_radius;
		vec3 normal = normalize(vec3(-disk.x, disk.y, sqrt(max(1.0 - dot(disk, disk), 0.0))));
		vec3 light = normalize(vec3(-0.5, 0.65, 0.75));
		float diffuse = max(dot(normal, light), 0.0);
		float glint = pow(max(dot(reflect(-light, normal), vec3(0.0, 0.0, 1.0)), 0.0), 24.0);
		vec3 base = mix(vec3(0.19, 0.33, 0.54), vec3(0.72, 0.39, 0.17), it);
		ALBEDO = base * (0.27 + 0.80 * diffuse) + vec3(0.46, 0.62, 0.83) * glint * 0.75;
	}
	ALPHA = alpha;
}
