// The ground round an observatory: the DEM's mesh with its material chosen by height,
// slope and noise, from a palette per site. Its irradiance is the local sun's, as a
// vehicle's is, and its haze is the flight ground's (ground.gdshader) along the view path.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_disabled;

uniform vec3 uRockA;
uniform vec3 uRockB;
uniform vec3 uSoil;
uniform vec3 uGreen;
uniform float uGreenTop = -1.0;   // m: vegetation thins out to none here
uniform float uFields = 0.0;      // 1: hedged fields, for a farmed plain
uniform vec3 uHaze;
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform float uDensity = 2.6e-5;
uniform float uScaleH = 8500.0;
uniform float uEye = 1.0;
uniform float uHasAir = 1.0;
uniform float uSkyI = 0.35;       // the flight ground's skylight

varying vec3 vPlace;     // x, height, z in the site's frame
varying vec3 vNormalL;

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
float fbm(vec2 p) {
	float a = 0.5, s = 0.0;
	for (int i = 0; i < 4; i++) { s += a * noise(p); p = p * 2.03 + vec2(17.3, 9.1); a *= 0.5; }
	return s;
}

void vertex() {
	vPlace = vec3(UV.x, UV2.x, UV.y);
	vNormalL = NORMAL;
}

void fragment() {
	float dist = length(VERTEX);
	vec2 p = vPlace.xz;
	float slope = 1.0 - clamp(vNormalL.y, 0.0, 1.0);
	// Noise that fades with range, or it shimmers below a pixel.
	float near_k = exp(-dist / 1500.0);
	float big = fbm(p / 900.0);
	float mid = fbm(p / 70.0);
	float fine = fbm(p / 3.5) * near_k;
	vec3 col = mix(uRockA, uRockB, smoothstep(0.32, 0.68, big * 0.7 + mid * 0.3));
	col = mix(col, uSoil, smoothstep(0.42, 0.75, mid) * (1.0 - smoothstep(0.08, 0.3, slope)));
	if (uGreenTop > 0.0) {
		float g = (1.0 - smoothstep(uGreenTop - 500.0, uGreenTop, vPlace.y)) * (1.0 - smoothstep(0.2, 0.55, slope));
		vec3 green = uGreen;
		if (uFields > 0.5) {
			// Hedged fields: a warped grid, each cell its own crop, a dark line round it.
			vec2 q = p + 60.0 * vec2(noise(p / 400.0), noise(p / 400.0 + 7.0));
			vec2 cell = floor(q / 190.0);
			vec2 f = abs(fract(q / 190.0) - 0.5);
			float crop = hash(cell);
			green = mix(uGreen, uSoil, step(0.72, crop));
			green *= 0.85 + 0.3 * hash(cell + 3.0);
			green *= 1.0 - 0.55 * smoothstep(0.47, 0.495, max(f.x, f.y)) * exp(-dist / 5000.0);
		}
		col = mix(col, green, g);
	}
	// Stones and grit underfoot, out to where they would shimmer.
	float grit = (fbm(p / 0.45) - 0.47) * exp(-dist / 90.0);
	col *= 0.82 + 0.3 * mid + 0.25 * (fine - 0.25) + 0.9 * grit;
	ALBEDO = col;
	ROUGHNESS = 1.0;
	// Air along the view path, as the ground patch computes it.
	// Skylight, the same term the planet's ground patch adds.
	EMISSION = ALBEDO * uSkyI * (0.55 + 0.45 * vNormalL.y) * smoothstep(-0.18, 0.05, uSunDir.y);
	if (uHasAir > 0.5) {
		float dh = max(uEye, 1.0);
		float mean_rho = uScaleH * (1.0 - exp(-dh / uScaleH)) / dh;
		float fog = 1.0 - exp(-uDensity * dist * mean_rho);
		float ndl = max(dot(normalize(vNormalL), uSunDir), 0.0);
		ALBEDO *= 1.0 - fog;
		EMISSION = EMISSION * (1.0 - fog) + uHaze * (0.35 + 0.75 * ndl) * fog * smoothstep(-0.12, 0.08, uSunDir.y);
	}
}
