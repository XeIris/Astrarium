// ============================================================================
// RE-ENTRY PLASMA — createEntryGlow() of sim/flight/plume.js.
// ----------------------------------------------------------------------------
// A bow-shock cap whose brightness and colour follow the Sutton–Graves heat
// flux, the same number that is burning the shield down. BackSide in the web
// build: only the inner wall of the cap is drawn (cull_front here).
//
// The view-space normal is a VARYING formed in vertex() — normalMatrix·normal
// — because Godot's own fragment NORMAL is flipped on back faces and this is a
// back-face-only material: the shading reads the sign of vN.y.
//
// Blending as the plume (publishAlpha): the colour was weighted by the
// published temperature code and added; formed here, blended ONE, ONE.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_front;

uniform float uHeat = 0.0;
uniform float uTime = 0.0;
uniform float uTemp = 2000.0;

varying vec3 vN;
varying vec3 vP;

void vertex() {
	vN = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	vP = VERTEX;
}

float hash(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5); }

void fragment() {
	if (uHeat < 0.001) discard;
	vec3 n = normalize(vN);
	// The sheath is brightest at the stagnation point and streams back.
	float front = clamp(-n.y * 0.5 + 0.5, 0.0, 1.0);
	float rim = pow(1.0 - abs(n.z), 2.0);
	float flick = 0.75 + 0.25 * hash(floor(vP * 9.0 + uTime * 26.0));
	float i = uHeat * (pow(front, 2.4) * 1.6 + rim * 0.5) * flick;
	// colour runs dull red → orange → blue-white as the flux climbs, which
	// is the real progression from a shallow entry to a lunar-return one
	vec3 c = mix(vec3(1.0, 0.24, 0.06), vec3(1.0, 0.72, 0.35), clamp(uHeat * 1.6, 0.0, 1.0));
	c = mix(c, vec3(0.75, 0.86, 1.0), clamp(uHeat * 0.65 - 0.55, 0.0, 1.0));
	float code = clamp(log(uTemp) / 25.33, 0.006, 0.984);
	ALBEDO = c * i * 5.0 * code;
	ALPHA = 0.0;
}
