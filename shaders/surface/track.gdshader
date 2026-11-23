// A WHEEL'S TRACK, multiplied into the ground under it (RoverTracks): the tread's chevrons pressed in, and the
// rut darker the deeper Bekker's sinkage made it (COLOR.r is the sinkage over 5 cm). Filtered by fwidth, as
// ground_mark.gdshader is, so the chevrons fade rather than shimmer far off.
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled, depth_draw_never;

varying float vDepth;

void vertex() {
	vDepth = COLOR.r;
}

void fragment() {
	vec2 uv = UV;
	// Chevrons: a V across the tread every 11 cm of path (24 round a 2.57 m rim).
	float pitch = 0.107;
	float v = uv.y / pitch + abs(uv.x - 0.5) * 1.6;
	float w = fwidth(v);
	float bar = smoothstep(0.5 - w, 0.5 + w, abs(fract(v) - 0.5) * 2.0);
	float detail = 1.0 - smoothstep(0.6, 1.4, w);
	// The rim of the rut catches light; its floor is in its own shade.
	float edge = smoothstep(0.0, 0.12, uv.x) * smoothstep(1.0, 0.88, uv.x);
	float floor_dark = 1.0 - clamp(vDepth, 0.0, 1.0) * 0.45;
	float k = mix(1.0, floor_dark * mix(1.0, 0.82, bar * detail), edge);
	ALBEDO = vec3(k);
}
