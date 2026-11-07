// A SEA, in the flight pass: wave trains from SurfaceWaves summed as Gerstner waves, with the
// local depth from the far grid. Unshaded and hand-lit, as the ground patch's haze is, because
// what a sea shows is mostly the sky it reflects. docs/physics/surface.md#oceans.
shader_type spatial;
render_mode unshaded, cull_disabled;

const int WAVES = 24;
uniform vec4 uWaves[WAVES];      // kx, kz, amplitude, ω
uniform float uPhases[WAVES];
uniform float uTime = 0.0;
uniform vec3 uCamLocal = vec3(0.0);
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uSunRGB = vec3(1.0);
uniform vec3 uSkyTop = vec3(0.1, 0.2, 0.4);
uniform vec3 uHaze = vec3(0.5, 0.6, 0.7);
uniform float uDensity = 2.6e-5;
uniform float uScaleH = 8500.0;
uniform float uCover = 0.0;
uniform float uTide = 0.0;
uniform float uFrozen = 0.0;
uniform vec3 uDeep = vec3(0.012, 0.045, 0.105);
uniform vec3 uShallow = vec3(0.03, 0.22, 0.26);
uniform sampler2D uHeights : filter_linear, repeat_disable;
uniform float uHeightsHalf = 60000.0;

varying vec3 vPlace;
varying float vFade;

// Long waves die with range: a vertex can't carry one shorter than its spacing.
float wave_weight(float k, float dist) {
	return smoothstep(40.0, 8.0, k * max(dist, 1.0) * 0.012);
}

void vertex() {
	vec2 at = VERTEX.xz + uCamLocal.xz;
	float dist = length(VERTEX.xz);
	vec3 shift = vec3(0.0);
	if (uFrozen < 0.5) {
		for (int i = 0; i < WAVES; i++) {
			vec4 w = uWaves[i];
			float k = length(w.xy);
			if (k <= 0.0) continue;
			float a = w.z * wave_weight(k, dist);
			float ph = dot(w.xy, at) - w.w * uTime + uPhases[i];
			vec2 d = w.xy / k;
			// x − (k̂)A sin θ, y = A cos θ: Tessendorf's (29)–(30), with θ's sign for a wave going along k̂.
			shift.xz -= d * a * sin(ph);
			shift.y += a * cos(ph);
		}
	}
	VERTEX += shift;
	vPlace = vec3(at.x, VERTEX.y, at.y);
	vFade = dist;
}

void fragment() {
	vec3 viewDir = normalize((INV_VIEW_MATRIX * vec4(-VERTEX, 0.0)).xyz);
	vec2 at = vPlace.xz;
	float dist = length((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	// The slope from every train, per pixel, so the small waves live here and not in the mesh.
	vec2 slope = vec2(0.0);
	float steep = 0.0;
	if (uFrozen < 0.5) {
		for (int i = 0; i < WAVES; i++) {
			vec4 w = uWaves[i];
			float k = length(w.xy);
			if (k <= 0.0) continue;
			// A wave shorter than a pixel's footprint on the water would alias: it goes, as its light
			// goes into the mean surface. Grazing views stretch the footprint.
			float foot = k * dist * 0.0014 / max(viewDir.y, 0.04);
			float fade = 1.0 / (1.0 + foot * foot);
			float ph = dot(w.xy, at) - w.w * uTime + uPhases[i];
			float ak = w.z * k * fade;
			slope += (w.xy / k) * ak * sin(ph);
			steep += ak * cos(ph);
		}
	}
	// What no train carries, near the eye: wind ripples, which fade with range.
	float rip = exp(-dist / 60.0);
	if (rip > 0.01 && uFrozen < 0.5) {
		vec2 q = at * 2.6 - uTime * vec2(0.7, 0.4);
		vec2 q2 = at.yx * 5.3 + uTime * vec2(0.5, -0.9);
		slope += rip * 0.035 * vec2(sin(q.x + 1.3 * sin(q.y)) + sin(q2.x), sin(q.y + 1.1 * sin(q.x)) + sin(q2.y));
	}
	vec3 N = normalize(vec3(slope.x, 1.0, slope.y));
	float cosv = max(dot(N, viewDir), 0.0);
	// Schlick, n = 1.33.
	float fres = 0.02 + 0.98 * pow(1.0 - cosv, 5.0);
	vec3 R = reflect(-viewDir, N);
	float up = max(R.y, 0.0);
	float day = clamp(uSunDir.y * 2.0 + 0.25, 0.02, 1.0);
	vec3 sky = mix(uHaze * 1.4, uSkyTop * 2.2, pow(up, 0.5)) * day;
	// Under cloud the reflection greys, and there is no glint.
	sky = mix(sky, vec3(0.75) * day, uCover * 0.75);
	// Shallows from the far grid's heights: x is west in the site's frame, u east.
	vec2 uv = vec2(-at.x, at.y) / (2.0 * uHeightsHalf) + 0.5;
	float bed = texture(uHeights, uv).r;
	float depth = max(uTide - bed, 0.0);
	float shallow = exp(-depth / 12.0);
	// Water's own colour, in the sun that reaches into it; albedos against an irradiance of about 3.
	vec3 body_col = mix(uDeep, uShallow, shallow) * 3.0 * clamp(uSunDir.y * 1.6 + 0.1, 0.02, 1.0) * (1.0 - 0.5 * uCover);
	vec3 col = mix(body_col, sky, fres);
	float glint = pow(max(dot(R, uSunDir), 0.0), 240.0) * (1.0 - uCover);
	col += uSunRGB * glint * 6.0;
	// A slope past about 1/6 breaks (Tessendorf §4.6), and a wave breaks on the shore.
	float foam = smoothstep(0.17, 0.32, length(slope)) * 0.7 + smoothstep(0.5, 1.2, shallow) * 0.25;
	col = mix(col, vec3(0.75) * clamp(uSunDir.y * 2.0 + 0.15, 0.05, 1.0), clamp(foam, 0.0, 0.85));
	// Hide where the land stands above it, so a coast is the terrain's.
	if (bed > uTide + 0.5 && abs(uv.x - 0.5) < 0.5 && abs(uv.y - 0.5) < 0.5) discard;
	// A frozen sea is pack ice.
	if (uFrozen > 0.5) {
		col = vec3(1.5, 1.6, 1.7) * clamp(uSunDir.y * 1.4 + 0.1, 0.03, 1.0);
	}
	float mean_rho = uScaleH * (1.0 - exp(-max(uCamLocal.y, 1.0) / uScaleH)) / max(uCamLocal.y, 1.0);
	float fog = 1.0 - exp(-uDensity * dist * mean_rho);
	col = mix(col, uHaze * clamp(uSunDir.y * 1.1 + 0.25, 0.02, 1.0), fog);
	ALBEDO = col;
}
