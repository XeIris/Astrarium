// THE DELUGE — the launch complex's steam points (sim/flight/launchsite.js).
// THREE.Points: gl_PointSize = uSize·(0.35 + age·1.6)·300 / max(−z_view, 1),
// a soft disc per point that fades with age. The age rides in UV.x (dead
// points are simply left out of the buffer rather than discarded).
//
// The web material drove the COLOUR blend with the coverage and threw the
// alpha away (steam is not an emitter and must not publish a temperature).
// Here the local pass's alpha is coverage, and blend_mix raising it is right:
// steam does hide the orrery behind it.
//
// Each point is a PUFF, not a disc: the smoke sprite's noise-bitten, self-
// shadowed texture (Plume.smoke_texture), turned by a per-point angle that
// rides in UV.y so it is stable for the point's life. Round soft discs by the
// hundred read as a pile of cotton balls however they move; torn, lit puffs
// read as steam. Its brightness is the light falling on it (Plume.daylight).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

uniform float uSize = 30.0;
uniform float uLight = 1.0;
uniform sampler2D uMap : filter_linear_mipmap, repeat_disable;
varying float vA;
varying float vRot;

void vertex() {
	vA = UV.x;
	vRot = UV.y * 6.2831853 + vA * 1.3;     // and it rolls slowly as it ages
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	POINT_SIZE = uSize * (0.35 + vA * 1.6) * 300.0 / max(-mv.z, 1.0);
}

void fragment() {
	vec2 d = POINT_COORD - 0.5;
	if (vA < 0.0) discard;
	float c = cos(vRot), s = sin(vRot);
	vec2 uv = vec2(c * d.x - s * d.y, s * d.x + c * d.y) + 0.5;
	vec4 t = texture(uMap, uv);
	float a = t.a * (1.0 - vA) * 0.62;
	if (a <= 0.003) discard;
	ALBEDO = vec3(0.92, 0.93, 0.95) * t.rgb * uLight;
	ALPHA = a;
}
