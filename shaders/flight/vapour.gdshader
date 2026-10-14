// A CONDENSATION COLLAR (sim/flight/vapour.gd): fog in the annulus between the body
// and the expansion's edge, from a shoulder (y = 0) back to the recompression shock
// (y = −L). It forms within a little of the corner, thickest against the skin, and
// stops at the shock in a sharp, ragged edge. Raymarched from a back-faced bounding
// cylinder and stopped at the depth buffer, as plume.gdshader is. Droplets this
// small scatter strongly forward: the collar glows when seen toward the sun.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;

uniform vec3 uBox = vec3(1.0);      // bounding cylinder: (radius, length, radius), m
uniform float uR = 1.0;             // body radius below the shoulder, m
uniform float uFlare = 0.4;         // the edge's widening at the shock, body radii
uniform float uSigma = 0.0;         // extinction at full density, 1/m
uniform float uTime = 0.0;
uniform float uSeed = 0.0;
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);   // toward the sun, in this node's frame
uniform float uLight = 1.0;         // Plume.daylight

varying vec3 vLocal;
varying flat vec3 vCam;

void vertex() {
	vLocal = VERTEX * uBox;
	VERTEX = vLocal;
	vCam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p) {
	vec3 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
	               mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
	               mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	vec3 ro = vCam;
	vec3 rd = normalize(vLocal - vCam);
	float R = uBox.x;
	float L = uBox.y;
	float a = dot(rd.xz, rd.xz);
	float b = dot(ro.xz, rd.xz);
	float c = dot(ro.xz, ro.xz) - R * R;
	float disc = b * b - a * c;
	if (disc <= 0.0 || a < 1e-8) discard;
	float sq = sqrt(disc);
	float ty0 = (-L - ro.y) / (abs(rd.y) > 1e-6 ? rd.y : 1e-6);
	float ty1 = (0.0 - ro.y) / (abs(rd.y) > 1e-6 ? rd.y : 1e-6);
	float t0 = max(max((-b - sq) / a, min(ty0, ty1)), 0.0);
	float t1 = min((-b + sq) / a, max(ty0, ty1));
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(v.xyz / v.w));
	if (t1 <= t0) discard;

	const int N = 32;
	float dt = (t1 - t0) / float(N);
	float jit = ign(FRAGCOORD.xy);
	float T = 1.0;
	float acc = 0.0;
	for (int i = 0; i < N; i++) {
		vec3 p = ro + rd * (t0 + (float(i) + jit) * dt);
		float s = -p.y / L;                       // 0 at the corner, 1 at the shock
		float r = length(p.xz);
		float ang = atan(p.z, p.x);
		// Streaks along the flow, and a shock that wavers round the body.
		float n1 = vnoise(vec3(ang * 3.0 + uSeed, s * 3.0 - uTime * 0.7, uSeed));
		float n2 = vnoise(vec3(ang * 9.0 - uSeed, s * 9.0 - uTime * 2.0, r / uR * 4.0));
		float edge = 1.0 + 0.22 * (n1 - 0.5);
		float shock = 1.0 - smoothstep(edge - 0.05, edge, s);
		float onset = smoothstep(0.0, 0.10, s);
		float ro2 = uR * (1.0 + uFlare * pow(clamp(s, 0.0, 1.0), 0.6));
		float h = (r - uR * 0.99) / max(ro2 - uR, 1e-3);   // 0 at the skin, 1 at the edge
		float shell = (h > 0.0 && h < 1.0) ? exp(-h * 1.6) * smoothstep(1.0, 0.75, h) : 0.0;
		// Patchy: the expansion is turbulent, and the fog comes and goes in streaks.
		float streak = smoothstep(0.15, 0.85, n2 * 0.7 + n1 * 0.5);
		float rho = shell * shock * onset * (0.12 + 2.2 * streak);
		float st = exp(-uSigma * rho * dt);
		acc += T * (1.0 - st);
		T *= st;
		if (T < 0.02) break;
	}
	float alpha = 1.0 - T;
	if (alpha < 0.003) discard;
	// Bright toward the sun (forward scattering), white elsewhere: sun plus sky.
	float cs = dot(rd, normalize(uSunDir));
	float phase = 0.75 + 1.6 * pow(max(cs, 0.0), 6.0);
	vec3 col = vec3(0.93, 0.95, 0.98) * uLight * phase;
	ALBEDO = col * acc;
	ALPHA = alpha;
}
