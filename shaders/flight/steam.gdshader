// ============================================================================
// THE DELUGE — the launch complex's steam points (sim/flight/launchsite.js).
// ----------------------------------------------------------------------------
// THREE.Points: gl_PointSize = uSize·(0.35 + age·1.6)·300 / max(−z_view, 1),
// a soft disc per point that fades with age. The age rides in UV.x (dead
// points are simply left out of the buffer rather than discarded).
//
// The web material drove the COLOUR blend with the coverage and threw the
// alpha away (steam is not an emitter and must not publish a temperature).
// Here the local pass's alpha is coverage, and blend_mix raising it is right:
// steam does hide the orrery behind it.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float uSize = 30.0;
varying float vA;

void vertex() {
	vA = UV.x;
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POINT_SIZE = uSize * (0.35 + vA * 1.6) * 300.0 / max(-mv.z, 1.0);
}

void fragment() {
	vec2 d = POINT_COORD - 0.5;
	float r = length(d);
	if (r > 0.5 || vA < 0.0) discard;
	float a = (1.0 - smoothstep(0.15, 0.5, r)) * (1.0 - vA) * 0.55;
	ALBEDO = vec3(0.92, 0.93, 0.95);
	ALPHA = a;
}
