// ============================================================================
// THE CLOUD PASS — a raymarched cumulus layer for local space.
// ----------------------------------------------------------------------------
// The previous clouds lived inside the sky dome: eight samples through a slab,
// evaluated only when the camera was under it and looking up. So they had no
// sides, nothing lit them but a guess, and the moment a rocket climbed past
// 2.8 km they were gone — there was nothing to look DOWN on, which is the one
// view of a cloud deck every launch broadcast has.
//
// This is a volume, marched per pixel through the field in clouds.gdshaderinc,
// from wherever the camera is: under the layer, inside it, or above it looking
// down. The march stops at whatever the scene has in front — the ground, the
// tower, the vehicle — because it reads the DEPTH BUFFER and ends the ray
// there, which is how a cloud gets in front of the ground and behind the
// rocket without either being sorted against it.
//
// LIGHT, in the order it matters:
//   · extinction along the view ray (Beer–Lambert), integrated per step with
//     Hillaire's energy-conserving form ∫S·e^{-σx}dx = S(1 − e^{-σΔ})/σ, so
//     the result does not depend on the step size;
//   · the SUN, attenuated by the optical depth toward it (a short march with
//     geometrically growing steps), phase-weighted by a two-lobe
//     Henyey–Greenstein: a strong forward peak (g = 0.8, the SILVER LINING on
//     a cloud between you and the sun) and a weak back lobe;
//   · MULTIPLE SCATTERING, which is what makes a thick cloud white instead of
//     black, in two parts. One further octave after Wrenninge et al. (half
//     the extinction, half the energy, a flatter lobe) carries the shallow
//     orders. The deep ones are DIFFUSION: in a medium this thick the light
//     random-walks, and what gets through an optical depth τ goes as
//     1/(1 + ¾τ(1 − g)) — two-stream theory — not as e^(−τ). That is the
//     difference between a grey cumulus base and a black one: at τ = 40 the
//     exponential leaves 4e-18 of the sun and the random walk leaves a fifth.
//     Its weight, ~1/π², is what makes a thick slab's diffuse radiance come
//     out at E·T/π, the radiance of a Lambert sheet with that transmission;
//   · SKYLIGHT from above and the ground's bounce from below, which is why
//     the tops of a cumulus are brighter than its base even in shade;
//   · AERIAL PERSPECTIVE, the same exponential haze as the ground's, applied
//     at the transmittance-weighted distance — so a deck 50 km off goes blue
//     and flat, which is what depth in a cloudscape looks like.
//
// SAMPLING. Steps grow geometrically with distance (a pixel's footprint
// does), the texture mip is chosen from that footprint, and the start is
// offset per pixel by interleaved gradient noise — which trades the banding a
// fixed step would draw for fine grain the film grain in the post chain
// already covers. The march ends early once the view is 99% blocked.
//
// OUTPUT is premultiplied: rgb is the integrated radiance, alpha the
// COVERAGE (1 − transmittance) — a cloud genuinely hides what is behind it,
// the stars included.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

#include "res://shaders/flight/clouds.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 uCamLocal = vec3(0.0);       // camera position in the local frame, m
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uSunColor = vec3(1.0);       // irradiance at the layer, HDR, already reddened
uniform vec3 uSkyTop = vec3(0.3, 0.4, 0.6);   // skylight on a cloud's upper faces
uniform vec3 uSkyBottom = vec3(0.1, 0.1, 0.1);// light from below (ground bounce)
uniform vec3 uHaze = vec3(0.56, 0.71, 0.91);
uniform float uHazeDensity = 2.6e-5;      // the ground's aerial-perspective coefficient
uniform float uHazeRho = 1.0;             // air density at the camera, relative
uniform float uMaxDist = 120000.0;        // how far the march may run, m
uniform int uSteps = 56;
uniform int uLightSteps = 6;
uniform float uDetail = 1.0;
uniform float uPixAngle = 0.0009;        // radians per pixel, for the mip level

varying vec3 vDir;

void vertex() {
	vDir = (MODEL_MATRIX * vec4(VERTEX, 0.0)).xyz;
}

float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / (12.566371 * pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5));
}

// Interleaved gradient noise (Jimenez 2014): a per-pixel offset with no
// low-frequency structure, so a jittered march shows grain, not bands.
float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void fragment() {
	if (uCloudCoverage <= 0.0) discard;
	vec3 rd = normalize(vDir);
	vec3 ro = uCamLocal;

	// ---- the part of the ray inside the layer: the shell between the base
	// and top spheres, from wherever the camera is.
	float h = length(vec3(ro.x, ro.y + uPlanetR, ro.z)) - uPlanetR;
	vec2 tb = cloud_sphere(ro, rd, uCloudBase);
	vec2 tt = cloud_sphere(ro, rd, uCloudTop);
	float t0; float t1;
	if (h < uCloudBase) {
		// below: out through the base (the far root), then out through the top
		if (tb.y <= 0.0) discard;
		t0 = max(tb.y, 0.0);
		t1 = tt.y;
	} else if (h > uCloudTop) {
		// above: in through the top; out through the base if the ray reaches
		// it, else back out through the top on the far side of the dip
		if (tt.x <= 0.0) discard;
		t0 = tt.x;
		t1 = tb.x > 0.0 ? tb.x : tt.y;
	} else {
		// inside: until the first of the two surfaces it meets
		t0 = 0.0;
		t1 = tb.x > 0.0 ? tb.x : tt.y;
	}
	// the scene in front ends the ray: ground, tower, vehicle
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	float scene = length(v.xyz / v.w);
	t1 = min(t1, min(scene, uMaxDist));
	if (t1 <= t0) discard;

	float cosT = dot(rd, uSunDir);
	// two lobes, and each octave of multiple scattering flatter than the last
	float ph0 = mix(hg(cosT, 0.80), hg(cosT, -0.25), 0.25);
	float ph1 = mix(hg(cosT, 0.40), hg(cosT, -0.12), 0.25);

	float jitter = ign(FRAGCOORD.xy);
	vec3 col = vec3(0.0);
	float T = 1.0;
	float tw = 0.0;       // transmittance-weighted distance, for the haze
	float wsum = 0.0;
	// STEP LENGTH GROWS WITH RANGE: a fixed fraction of the distance (what a
	// pixel's footprint does), floored so near cloud is resolved and sized so
	// the march always reaches t1 within the step budget. A step from 11 km
	// up through a 3 km deck is a few tens of metres; along a grazing line to
	// the horizon it is kilometres, and at that range that is all there is.
	int N = uSteps;
	float base = max(t0, 30.0);
	float r = pow(max(t1, base * 1.001) / base, 1.0 / float(N));
	float ds = base * (r - 1.0) + max(t0 - base, 0.0);
	float t = t0 + ds * jitter;
	for (int i = 0; i < 160; i++) {
		if (i >= N || t >= t1) break;
		float step = min(ds, t1 - t);
		float ts = t;
		t += step;
		ds *= r;
		vec3 p = ro + rd * ts;
		vec3 pp = cloud_planet(p);
		float sigma = cloud_density_fp(pp, uDetail, ts * uPixAngle);
		if (sigma <= 0.0) continue;
		// light: the optical depth toward the sun; single scattering, one
		// octave, and the diffusion floor (see the header)
		float od = cloud_optical_depth(p, uSunDir, uLightSteps, 45.0);
		float hf = clamp(cloud_hfrac(pp), 0.0, 1.0);
		vec3 sun = uSunColor * (ph0 * exp(-od)
			+ 0.5 * ph1 * exp(-od * 0.5)
			+ 0.10 / (1.0 + 0.11 * od));
		// a powder term: the edge of a cloud facing you is darker than its
		// interior, because light entering there has had nothing to scatter
		// off yet. Applied softly, and only away from the forward lobe.
		float powder = mix(1.0, 1.0 - exp(-sigma * 90.0), 0.5 * (1.0 - clamp(cosT, 0.0, 1.0)));
		vec3 amb = mix(uSkyBottom, uSkyTop, smoothstep(0.0, 1.0, hf));
		vec3 S = sigma * (sun * powder * 12.566371 * 0.25 + amb);
		float Ts = exp(-sigma * step);
		col += T * (S - S * Ts) / sigma;
		tw += T * (1.0 - Ts) * ts;
		wsum += T * (1.0 - Ts);
		T *= Ts;
		if (T < 0.01) break;
	}
	float a = 1.0 - T;
	if (a <= 0.002) discard;
	// aerial perspective at the distance the cloud actually is
	float dist = tw / max(wsum, 1e-5);
	float fog = 1.0 - exp(-uHazeRho * uHazeDensity * dist);
	col = mix(col, uHaze * a, clamp(fog, 0.0, 1.0));
	ALBEDO = col;
	ALPHA = a;
}
