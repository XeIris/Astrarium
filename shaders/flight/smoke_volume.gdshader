// LAUNCH SMOKE AS VOLUMES: each puff of Plume.SmokeColumn is a sphere of eroded 3D
// noise, raymarched from its camera-facing quad and stopped at the depth buffer.
// Light: the sun through the rest of the cloud (instance custom.y, from the CPU)
// and through this puff (a short march toward it), Henyey–Greenstein forward
// scattering, sky from above, ground bounce from below, and the fire underneath
// (custom.z). Instance colour is (albedo, opacity); custom.x the spin, custom.w a seed.
// Output for blend_mix: the scattered light over the coverage, and the coverage.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler3D uNoise : filter_linear, repeat_enable;

uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);   // local frame, toward the sun
uniform vec3 uSun = vec3(1.0);                // its light on the smoke
uniform vec3 uSky = vec3(0.3, 0.38, 0.5);     // skylight from above
uniform vec3 uGround = vec3(0.12, 0.11, 0.1); // bounce from below
uniform vec3 uFire = vec3(2.4, 1.1, 0.35);    // the deflected exhaust's glow
uniform float uDensity = 4.0;                 // optical depth across a fresh puff: many overlap into the cloud
uniform int uSteps = 6;
uniform int uLightSteps = 1;
uniform bool uFine = true;                    // the finest noise octave (Ultra)
uniform float uTime = 0.0;

varying vec3 vView;
varying flat vec3 vCentre;    // view space
varying flat float vR;
varying flat vec4 vCol;
varying flat vec4 vCustom;

void vertex() {
	vCol = COLOR;
	vCustom = INSTANCE_CUSTOM;
	float s = length(MODEL_MATRIX[0].xyz);
	vR = s * 0.5;
	vec4 c = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vCentre = c.xyz;
	// A little larger than the sphere, so its silhouette fits at close range.
	vec2 al = VERTEX.xy * s * 1.2;
	vView = c.xyz + vec3(al, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(vView, 1.0);
}

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (12.566371 * pow(1.0 + g2 - 2.0 * g * c, 1.5));
}

// Density at a point given in the puff's own units (centre 0, surface 1). The
// noise rides with the puff and grows with it; the spin turns it slowly.
float density(vec3 q, mat3 spin, vec3 seed) {
	float r0 = length(q);
	if (r0 >= 1.0) return 0.0;
	vec3 w = spin * q;
	// Billows: the large octave folded (|2n − 1|) into rounded lobes, finer ones on top.
	float n0 = texture(uNoise, w * 0.55 + seed).r;
	float n1 = texture(uNoise, w * 1.3 - seed * 1.7).r;
	float n2 = uFine ? texture(uNoise, w * 3.1 + seed * 0.6).r : 0.5;
	float n = (1.0 - abs(2.0 * n0 - 1.0)) * 0.55 + n1 * 0.3 + n2 * 0.15;
	// The large octave also moves the surface in and out, so no puff keeps a round
	// silhouette; then the finer noise erodes it into cauliflower.
	float r = r0 * (1.0 + (n0 - 0.5) * 0.9);
	float shape = 1.0 - r * r;
	return smoothstep(0.0, 0.18, shape * 1.5 - (1.0 - n) * 1.05);
}

void fragment() {
	vec3 rd = normalize(vView);
	vec3 oc = -vCentre;
	float b = dot(oc, rd);
	float c = dot(oc, oc) - vR * vR;
	float h = b * b - c;
	if (h <= 0.0) discard;
	h = sqrt(h);
	float t0 = max(-b - h, 0.0);
	float t1 = -b + h;
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(v.xyz / v.w));
	if (t1 <= t0) discard;

	vec3 sunV = normalize((VIEW_MATRIX * vec4(uSunDir, 0.0)).xyz);
	vec3 upV = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	float a = vCustom.x + uTime * 0.05;
	mat3 spin = mat3(vec3(cos(a), 0.0, sin(a)), vec3(0.0, 1.0, 0.0), vec3(-sin(a), 0.0, cos(a)));
	vec3 seed = vec3(vCustom.w, vCustom.w * 1.37, vCustom.w * 0.71);
	// View-space puff coordinates are turned back to the world's, so the noise does
	// not swim when the camera turns.
	mat3 toWorld = mat3(INV_VIEW_MATRIX);
	float phase = mix(0.0796, hg(dot(rd, sunV), 0.55), 0.7);
	float sigma0 = uDensity * vCol.a / vR;

	float dt = (t1 - t0) / float(uSteps);
	float jit = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float T = 1.0;
	vec3 L = vec3(0.0);
	for (int i = 0; i < 16; i++) {
		if (i >= uSteps) break;
		vec3 p = rd * (t0 + (float(i) + jit) * dt);
		vec3 q = (p - vCentre) / vR;
		float dn = density(toWorld * q, spin, seed);
		if (dn <= 0.0) continue;
		// Toward the sun through this puff; the rest of the cloud is custom.y.
		float od = 0.0;
		for (int k = 1; k <= 3; k++) {
			if (k > uLightSteps) break;
			od += density(toWorld * (q + sunV * 0.3 * float(k)), spin, seed);
		}
		float sunT = vCustom.y * exp(-od * uDensity * 0.3 * vCol.a);
		float up = dot(normalize(q), upV);
		vec3 amb = mix(uGround, uSky, 0.5 + 0.5 * up) * (0.55 + 0.45 * vCustom.y);
		vec3 fire = uFire * vCustom.z * clamp(0.6 - 0.6 * up, 0.0, 1.2);
		vec3 Ls = vCol.rgb * (uSun * sunT * phase * 12.566371 * 0.35 + amb) + fire;
		float a_s = 1.0 - exp(-sigma0 * dn * dt);
		L += T * Ls * a_s;
		T *= 1.0 - a_s;
		if (T < 0.02) break;
	}
	float cover = 1.0 - T;
	if (cover < 0.003) discard;
	ALBEDO = L / cover;
	ALPHA = cover;
}
