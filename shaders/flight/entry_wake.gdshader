// RE-ENTRY PLASMA, the wake: streaks of shock-layer gas leaving the skin's downstream
// edges and running aft along the flow (Plume.EntryGlow). An instance's basis column 0
// is the streak, start to end; column 1's length its width; COLOR.a its opacity;
// INSTANCE_CUSTOM (seed, age fraction). Paler and cooler than the layer it came from.
// Added ONE, ONE, depth-tested so the vehicle hides what is behind it.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;
#include "res://shaders/flight/entry_plasma.gdshaderinc"

uniform float uHeat = 0.0;
uniform float uTemp = 2000.0;
uniform float uTime = 0.0;

varying vec2 vUV;
varying flat float v_op;
varying flat float v_seed;

void vertex() {
	vUV = vec2(VERTEX.x + 0.5, VERTEX.y * 2.0);
	v_op = COLOR.a;
	v_seed = INSTANCE_CUSTOM.x;
	vec3 p0 = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 ax = (MODELVIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
	float w = length((MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 p = p0 + ax * vUV.x;
	// Turned about its own axis to face the eye; it spreads as it goes.
	vec3 side = cross(ax, p);
	side = length(side) > 1e-6 * length(ax) * length(p) ? normalize(side) : vec3(1.0, 0.0, 0.0);
	p += side * (w * (0.35 + 0.65 * vUV.x) * vUV.y);
	POSITION = PROJECTION_MATRIX * vec4(p, 1.0);
}

void fragment() {
	float u = vUV.x;
	float v = vUV.y;
	float across = max(exp(-3.5 * v * v) - exp(-3.5), 0.0);
	float along = smoothstep(0.0, 0.1, u) * pow(max(1.0 - u, 0.0), 1.4);
	float knots = plasma_noise(vec3(u * 7.0 - uTime * 11.0, v * 1.5, v_seed));
	// Dimmer than the layer it left, and saturating: past a hard entry it lengthens
	// rather than brightens.
	float I = v_op * across * along * (0.45 + 1.1 * knots) * uHeat / (0.3 + uHeat);
	if (I <= 0.0) discard;
	float T = uTemp * 0.75;
	vec3 c = mix(plasma_colour(T), vec3(1.0, 0.80, 0.86), 0.55);
	ALBEDO = c * (I * 1.8 * plasma_code(T));
	ALPHA = 0.0;
}
