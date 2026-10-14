// LAUNCH SMOKE ON LOW AND MEDIUM: each puff of Plume.SmokeColumn is a camera-facing
// quad, not marched, that reads the exhaust trail's own medium at the front of the
// puff's sphere: the same lobes and domain-warped detail (smoke_column.gdshaderinc) in
// the same air-fixed noise (uAir), so overlapping puffs show one field, and the trail's
// light. See docs/physics/plumes.md#launch-smoke-on-low-and-medium.
// Instance colour is (albedo, opacity); custom = (spin, the sun's transmittance through
// the rest of the cloud, fire light, seed). custom.z < 0 marks boil-off vapour.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, fog_disabled;
#include "res://shaders/flight/smoke_column.gdshaderinc"

uniform mat4 uAir;                            // view space → air-fixed noise space, m
uniform vec3 uFire = vec3(2.4, 1.1, 0.35);    // the deflected exhaust's glow
uniform float uDensity = 2.2;                 // optical depth through a fresh puff's middle

varying vec2 vQ;              // −1..1 across the quad
varying flat vec3 vCentre;    // view space
varying flat float vR;
varying flat vec4 vCol;
varying flat vec4 vCustom;

void vertex() {
	vCol = COLOR;
	vCustom = INSTANCE_CUSTOM;
	float s = length(MODEL_MATRIX[0].xyz);
	vR = s * 0.5;
	vQ = VERTEX.xy * 2.0;
	vCentre = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(vCentre + vec3(VERTEX.xy * s, 0.0), 1.0);
}

void fragment() {
	float rho2 = dot(vQ, vQ);
	if (rho2 >= 1.0) discard;
	// The front of the puff's sphere: where the eye's ray enters it, and its normal.
	vec3 n = vec3(vQ, sqrt(1.0 - rho2));
	vec3 p = vCentre + n * vR;
	vec3 q = (uAir * vec4(p, 1.0)).xyz;
	// The column's profile across the puff: radius scale a, its ragged edge (1.85 a) at
	// the rim, lobes 2.2 a and detail 0.8 a across, looked up through the lobes.
	float a = vR / 1.85;
	float lobe = smoke_noise(q, 2.2 * a);
	float body = smoothstep(1.2, 0.45, sqrt(rho2) * 1.85 + (lobe - 0.5) * 1.3);
	if (body <= 0.0) discard;
	vec3 w = q + (lobe - 0.5) * a * vec3(1.6, -1.1, 0.9);
	float det = smoke_noise(w, 0.8 * a);
	bool wisp = vCustom.z < 0.0;
	// Vapour mixes in sheets: the sharpened ridges of the detail, mostly empty.
	float dens = wisp ? body * pow(1.0 - abs(2.0 * det - 1.0), 5.0) * 1.6
		: body * (0.3 + 2.1 * det * det);
	// Along the ray the puff is as deep as its chord there.
	float alpha = 1.0 - exp(-uDensity * vCol.a * dens * n.z);
	if (alpha < 0.003) discard;
	vec3 rd = normalize(p);
	vec3 sunV = normalize((VIEW_MATRIX * vec4(uSunDir, 0.0)).xyz);
	vec3 upV = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	// The sun through the rest of the cloud (the CPU's estimate), then through this puff
	// from its sunlit side, as deep as the chord the sun's ray crosses.
	float od = -log(max(vCustom.y, 1e-3)) + uDensity * vCol.a * dens * (1.0 - dot(n, sunV));
	float up = dot(n, upV);
	vec3 L = vCol.rgb * smoke_light(od, dot(rd, sunV), up);
	// The fire lights the low puffs from underneath, as on the volumes.
	if (!wisp) L += uFire * vCustom.z * clamp(0.6 - 0.6 * up, 0.0, 1.2);
	ALBEDO = L;
	ALPHA = alpha;
}
