// THE GROUND AT A SITE, close up: the surveyed grids' mesh (SiteScene.terrain_mesh), its material chosen by
// height, slope and noise from the site's palette. The relief below the grid reaches the shading through the
// world's own roughness, ν(ℓ) = ν_cell (ℓ/L_cell)^H; the Sun is occluded by the grids' own heights
// (SurfaceShadow is this march on the CPU); a regolith's BRDF lights it. docs/physics/surface.md#the-ground-close-up.
shader_type spatial;
render_mode specular_disabled;

uniform vec3 uRockA;
uniform vec3 uRockB;
uniform vec3 uSoil;
uniform vec3 uGreen;
uniform float uGreenTop = -1.0;   // m: vegetation thins out to none here
uniform vec3 uHaze;
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);   // site frame: x west, y up, z north
uniform float uDensity = 2.6e-5;
uniform float uScaleH = 8500.0;
uniform float uEye = 1.0;
uniform float uHasAir = 1.0;
uniform float uSkyI = 0.35;       // the flight ground's skylight
uniform vec3 uFillTint = vec3(1.0);
uniform float uSnowLine = 1.0e9;  // m: a world's frost line, in its own lapse rate
uniform float uRivers = 0.0;      // 1: UV2.y is log₁₀ drainage area, and water runs where it is large
// The grids' heights (SurfaceRelief), one texel a vertex, and the drop's radius.
uniform sampler2D uNearH : filter_nearest, repeat_disable;
uniform sampler2D uFarH : filter_nearest, repeat_disable;
uniform float uNearHalf = 3200.0;
uniform float uFarHalf = 60000.0;
uniform float uRadius = 6.371e6;
uniform float uTop = 1.0e4;       // m: over the highest of the grids a ray is clear
uniform float uSunAng = 0.00465;  // the Sun's angular radius, rad
// The world's roughness: ν at the measured cell's scale, that scale, m, and the Hurst exponent.
uniform float uRoughCell = 40.0;
uniform float uCellM = 2000.0;
uniform float uHurst = 0.8;
// 1: an airless regolith, Lommel–Seeliger with an opposition surge; 0: Oren–Nayar under air.
uniform float uAirless = 0.0;

varying vec3 vPlace;     // east, height, north in the site's frame
varying vec3 vNormalL;
varying float vChannel;
varying float vSunVis;
varying vec3 vSunView;

// PCG2D (Jarzynski & Olano 2020): an integer hash, so the pattern does not swim with GPU sin().
uvec2 pcg2d(uvec2 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * 1664525u; v.y += v.x * 1664525u;
	v = v ^ (v >> 16u);
	v.x += v.y * 1664525u; v.y += v.x * 1664525u;
	v = v ^ (v >> 16u);
	return v;
}
float hash2(ivec2 c, uint s) { return float(pcg2d(uvec2(c) + uvec2(s, s * 747796405u)).x) * (1.0 / 4294967295.0); }

// Value noise in [−1, 1] with its gradient, quintic (Quílez's derivative form).
vec3 vnoise(vec2 p, uint s) {
	vec2 i = floor(p);
	vec2 f = p - i;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	ivec2 c = ivec2(i);
	float a = hash2(c, s), b = hash2(c + ivec2(1, 0), s), cc = hash2(c + ivec2(0, 1), s), d = hash2(c + ivec2(1, 1), s);
	float k1 = b - a, k2 = cc - a, k4 = a - b - cc + d;
	return vec3((a + k1 * u.x + k2 * u.y + k4 * u.x * u.y) * 2.0 - 1.0, 2.0 * du * vec2(k1 + k4 * u.y, k2 + k4 * u.x));
}

// One grid's height at (e, n) on its own triangles, with the drop; terrain_mesh's split.
float grid_y(sampler2D tex, float half_m, vec2 en) {
	int n = textureSize(tex, 0).x;
	float step = 2.0 * half_m / float(n - 1);
	vec2 f = (en + half_m) / step;
	ivec2 c = min(ivec2(f), ivec2(n - 2));
	vec2 t = f - vec2(c);
	float h00 = texelFetch(tex, c, 0).r;
	float h10 = texelFetch(tex, c + ivec2(1, 0), 0).r;
	float h01 = texelFetch(tex, c + ivec2(0, 1), 0).r;
	float y;
	if (t.x + t.y <= 1.0) y = h00 + t.x * (h10 - h00) + t.y * (h01 - h00);
	else {
		float h11 = texelFetch(tex, c + ivec2(1, 1), 0).r;
		y = h11 + (1.0 - t.x) * (h01 - h11) + (1.0 - t.y) * (h10 - h11);
	}
	return y - dot(en, en) / (2.0 * uRadius);
}

// SurfaceShadow.visibility, step for step.
float sun_visibility(vec3 p, vec3 sun) {
	if (sun.y <= -uSunAng) return 0.0;
	vec2 horiz = vec2(-sun.x, sun.z);
	float vis = 1.0;
	float t = 0.5;
	for (int k = 0; k < 28; k++) {
		vec2 q = p.xz + horiz * t;
		float ray = p.y + sun.y * t;
		if (ray > uTop) break;
		float ground;
		if (abs(q.x) < uNearHalf && abs(q.y) < uNearHalf) ground = grid_y(uNearH, uNearHalf, q);
		else if (abs(q.x) < uFarHalf && abs(q.y) < uFarHalf) ground = grid_y(uFarH, uFarHalf, q);
		else break;
		float rise = (ground + 0.05 + 0.002 * t - ray) / t;
		vis = min(vis, clamp(0.5 - rise / (2.0 * uSunAng), 0.0, 1.0));
		if (vis <= 0.0) return 0.0;
		t *= 1.5;
	}
	return vis;
}

void vertex() {
	vPlace = vec3(UV.x, UV2.x, UV.y);
	vNormalL = NORMAL;
	vChannel = UV2.y;
}

void fragment() {
	float dist = length(VERTEX);
	vec2 p = vPlace.xz;
	// Height of the drawn surface here, drop included, in the site's frame.
	float here_y = vPlace.y - dot(p, p) / (2.0 * uRadius);
	float slope = 1.0 - clamp(vNormalL.y, 0.0, 1.0);
	// A pixel's width on the ground, m: octaves under about two of them are filtered out, not aliased.
	float foot = max(length(fwidth(p)), 1e-4);
	bool near = abs(p.x) < uNearHalf && abs(p.y) < uNearHalf;
	float spacing = near ? 2.0 * uNearHalf / float(textureSize(uNearH, 0).x - 1) : 2.0 * uFarHalf / float(textureSize(uFarH, 0).x - 1);
	// The relief under the grid, octave by octave from half a cell down, each as high as the world's
	// roughness at its wavelength.
	// Each octave's height is κ ν(λ). With octaves falling by 2^−H, the slopes of all of them together
	// are 1/√(1 − 2^−2(1−H)) times the finest's, and this noise's RMS gradient is 1.22 per unit height (Monte Carlo over its cells):
	// κ makes the whole field's RMS slope at the finest drawn octave ν(λ)/λ.
	float kappa = sqrt(1.0 - pow(2.0, -2.0 * (1.0 - uHurst))) / 1.22;
	vec2 grad = vec2(0.0);
	float lam = spacing * 0.5;
	float patchy = 0.0;
	for (int k = 0; k < 14; k++) {
		float w = smoothstep(1.5, 4.0, lam / foot);
		if (w <= 0.0) break;
		float a = kappa * uRoughCell * pow(lam / uCellM, uHurst);
		vec3 nz = vnoise(p / lam, uint(k) * 92821u + 17u);
		grad += w * (a / lam) * nz.yz;
		if (k < 6) patchy += w * nz.x * (0.5 / float(k + 1));
		lam *= 0.5;
	}
	// The mesh's normal (x runs west) tilted by the relief below it.
	float ny = max(vNormalL.y, 0.05);
	vec3 nm = normalize(vec3(vNormalL.x / ny + grad.x, 1.0, vNormalL.z / ny - grad.y));
	NORMAL = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(nm, 0.0)).xyz);

	// The palette, as the planet's biome() draws it: rock and soil by slope and broad noise.
	float big = vnoise(p / 900.0, 3u).x * 0.5 + 0.5;
	float mid = vnoise(p / 70.0, 5u).x * 0.5 + 0.5;
	vec3 col = mix(uRockA, uRockB, smoothstep(0.32, 0.68, big * 0.7 + mid * 0.3));
	col = mix(col, uSoil, smoothstep(0.42, 0.75, mid) * (1.0 - smoothstep(0.08, 0.3, slope)));
	if (uGreenTop > 0.0) {
		float g = (1.0 - smoothstep(uGreenTop - 500.0, uGreenTop, vPlace.y)) * (1.0 - smoothstep(0.2, 0.55, slope));
		col = mix(col, uGreen, g);
	}
	if (uRivers > 0.5) {
		float wet = smoothstep(6.0, 7.2, vChannel + (mid - 0.5) * 0.3);
		col = mix(col, vec3(0.03, 0.06, 0.09), wet * 0.9);
	}
	float snow = smoothstep(uSnowLine - 220.0, uSnowLine + 160.0, vPlace.y + (mid - 0.5) * 240.0) * (1.0 - smoothstep(0.35, 0.65, slope));
	col = mix(col, vec3(0.82, 0.85, 0.9), snow);
	// Patches of brighter and darker grain, as fresh and weathered regolith differ: ±15 %, filtered with the relief.
	col *= 1.0 + 0.3 * patchy;
	ALBEDO = col;
	ROUGHNESS = 1.0;

	vec3 sun = normalize(uSunDir);
	vSunVis = sun_visibility(vec3(p.x, here_y, p.y), sun);
	// The Sun in view space, to tell it in light() from the hemisphere's fill.
	vSunView = normalize((VIEW_MATRIX * MODEL_MATRIX * vec4(sun, 0.0)).xyz);

	// Skylight, the same term the planet's ground patch adds.
	EMISSION = ALBEDO * uFillTint * uSkyI * (0.55 + 0.45 * nm.y) * smoothstep(-0.18, 0.05, uSunDir.y);
	if (uHasAir > 0.5) {
		float dh = max(uEye, 1.0);
		float mean_rho = uScaleH * (1.0 - exp(-dh / uScaleH)) / dh;
		float fog = 1.0 - exp(-uDensity * dist * mean_rho);
		ALBEDO *= 1.0 - fog;
		EMISSION = EMISSION * (1.0 - fog) + uHaze * (0.35 + 0.75 * max(nm.y, 0.0)) * fog * smoothstep(-0.12, 0.08, uSunDir.y);
	}
}

// Opposition surge, Hapke's shadow hiding: B(g) = 1 + B₀/(1 + tan(g/2)/h), B₀ 1.8 and h 0.071 (a lunar
// fit quoted by the CU/NASA Ames lunar photometry work). Normalised at 30°, so a typical phase keeps the
// palette's albedo.
float surge(float g) {
	return 1.0 + 1.8 / (1.0 + tan(0.5 * g) / 0.071);
}

void light() {
	float nl = max(dot(NORMAL, LIGHT), 0.0);
	float nv = max(dot(NORMAL, VIEW), 1e-3);
	float f;
	if (uAirless > 0.5) {
		// Lommel–Seeliger over Lambert, 2/(μ₀ + μ): 1 at normal incidence and emission, so a lit plain under a
		// low Sun stays bright to the limb, as the Moon does.
		float g = acos(clamp(dot(LIGHT, VIEW), -1.0, 1.0));
		f = 2.0 / (nl + nv + 1e-4) * surge(g) / surge(0.5236);
	} else {
		// Oren–Nayar at σ = 0.35 rad over its own A, so it is Lambert at normal incidence.
		float s2 = 0.35 * 0.35;
		float A = 1.0 - 0.5 * s2 / (s2 + 0.33);
		float B = 0.45 * s2 / (s2 + 0.09);
		vec3 lp = normalize(LIGHT - NORMAL * nl);
		vec3 vp = normalize(VIEW - NORMAL * nv);
		float cphi = max(dot(lp, vp), 0.0);
		float ti = acos(clamp(nl, 0.0, 1.0));
		float tr = acos(clamp(nv, 0.0, 1.0));
		f = (A + B * cphi * sin(max(ti, tr)) * tan(min(ti, tr))) / A;
	}
	float vis = dot(LIGHT, vSunView) > 0.9999 ? vSunVis : 1.0;
	DIFFUSE_LIGHT += nl * f * vis * ATTENUATION * LIGHT_COLOR / PI;
}
