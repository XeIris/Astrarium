// Rain and snow near the eye: thin streaks or soft flakes, as much as the weather says.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform float uAlpha = 0.2;
uniform float uSnow = 0.0;
varying float vNear;

void vertex() {
	// Billboard about the fall direction: y stays along the streak, x turns to the eye.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		vec4(normalize(cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz)), 0.0),
		vec4(0.0, 1.0, 0.0, 0.0),
		vec4(normalize(cross(INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
		MODEL_MATRIX[3]);
	// A drop against the lens is a pillar, not a drop: it goes before it gets there.
	vNear = smoothstep(1.5, 4.0, length((MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz));
}

void fragment() {
	float x = abs(UV.x - 0.5) * 2.0;
	float y = abs(UV.y - 0.5) * 2.0;
	float shape = uSnow > 0.5 ? smoothstep(1.0, 0.2, length(vec2(x, y))) : (1.0 - x) * (1.0 - y * y);
	ALBEDO = vec3(0.72, 0.76, 0.82);
	ALPHA = uAlpha * shape * vNear;
}
