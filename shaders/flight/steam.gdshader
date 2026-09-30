// THE DELUGE: the launch complex's steam points. Point size
// uSize·(0.35 + age·1.6)·300 / max(−z_view, 1), fading with age; age in UV.x (dead
// points are left out of the buffer). Steam isn't an emitter; blend_mix raising
// coverage is right, since it hides the orrery behind it. Each point is a puff (the
// smoke sprite texture, Plume.smoke_texture), turned by a per-point angle in UV.y,
// lit by Plume.daylight.
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
