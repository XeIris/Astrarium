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
// THE UPPER-ATMOSPHERE LOD (set per frame by localview.gd from altitude).
// Looking DOWN on the deck from tens of km, a pixel covers tens of metres and
// the ray crosses a 3 km slab, so the march's budget is spent resolving
// structure nobody can see. Above the layer the CPU lowers uSteps and
// uLightSteps, stretches the light march's first step (uLightFirst) so it
// still reaches as far through the cloud, and lets the coverage — the part
// of the density that varies over tens of km — be re-evaluated only every
// uCovReuse metres along the ray instead of at every sample, and not at all
// in the light march under it. 0 = every sample, as under the deck.
uniform float uLightFirst = 45.0;
uniform float uCovReuse = 0.0;

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

// Sub-step length a segment containing cloud is refined to, and the most
// sub-steps one segment may take (see the march).
const float REFINE_LEN = 150.0;
const int REFINE_MAX = 6;

// The far end of march segment i: s = i + jitter on t(s) = t0 + base·(rˢ − 1).
float seg_end(int i, float j, float t0, float base, float lr, float n, float t1) {
	return min(t0 + base * (exp(lr * clamp(float(i) + j, 0.0, n)) - 1.0), t1);
}

// The density at distance t along the ray, and the coverage there — the
// probe that decides whether a segment is worth refining, and the sample
// itself when it is not.
float probe(vec3 ro, vec3 rd, float t, out float cov) {
	vec3 pp = cloud_planet(ro + rd * t);
	float hf = cloud_hfrac(pp);
	cov = 0.0;
	if (hf <= 0.0 || hf >= 1.0) return 0.0;
	float fp = t * uPixAngle;
	cov = cloud_coverage(pp, fp);
	return cloud_density_cov(pp, uDetail, fp, cov);
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
	// The march is uniform in s, where t(s) = t0 + base·(rˢ − 1).
	//
	// THE JITTER GOES ON s, NOT ON t. Added to t it is a fraction of the FIRST
	// step — ten metres — and every later step is the same kilometres for
	// every pixel, so every pixel samples the same concentric shells round the
	// camera. Looking down through the slab that hardly shows; looking ALONG
	// it, from inside the deck on the way up, each shell cuts the layer in a
	// sheet and the cloud reads as a stack of painted planes. Offsetting s
	// moves every boundary by the same fraction of its OWN step, which turns
	// the shells into grain.
	//
	// And a grazing ray gets more samples. Down through the deck the range
	// spans a factor of two or three; along it, from 30 m to the horizon, a
	// factor of four thousand, and 28 steps over that are 35% of the range
	// apiece — a whole turret skipped between two samples. So the count is
	// raised until no step is more than ~15% of its range, up to twice the
	// budget; the early exit at 99% opacity keeps most of that unpaid.
	//
	// REFINED WHERE THERE IS CLOUD. Even at 15%, a step 20 km out is 3 km
	// long, and the jitter that removed the shells leaves a grain that big at
	// every cloud edge. Most of a grazing ray is clear air, so each segment is
	// first PROBED at its middle, and a segment whose own probe or either
	// neighbour's found any is marched in sub-steps of about REFINE_LEN, up
	// to REFINE_MAX of them. The neighbours are what catch the edge a
	// segment's midpoint missed. Looking down through the deck the segments
	// are already shorter than that, so nothing is added there — and an
	// unrefined segment's probe IS its sample, so probing costs nothing extra.
	float base = max(t0, 30.0);
	float span = max((t1 - t0 + base) / base, 1.001);
	int N = clamp(int(ceil(log(span) / log(1.15))), uSteps, uSteps * 2);
	float lr = log(span) / float(N);
	float fN = float(N);
	float ta = t0;
	float te = seg_end(0, jitter, t0, base, lr, fN, t1);
	float c_cur; float c_nxt = 0.0;
	float p_prv = 0.0;
	float p_cur = probe(ro, rd, 0.5 * (ta + te), c_cur);
	for (int i = 0; i < 160; i++) {
		if (i > N || ta >= t1) break;
		// segment i runs from the last boundary to s = i + jitter (the first
		// and last are partial)
		float step = te - ta;
		float tn = seg_end(i + 1, jitter, t0, base, lr, fN, t1);
		float p_nxt = i < N ? probe(ro, rd, 0.5 * (te + tn), c_nxt) : 0.0;
		bool busy = max(p_prv, max(p_cur, p_nxt)) > 0.0;
		int K = busy ? clamp(int(ceil(step / REFINE_LEN)), 1, REFINE_MAX) : 0;
		float sub = step / float(max(K, 1));
		float od = -1.0;
		for (int k = 0; k < REFINE_MAX; k++) {
			if (k >= K) break;
			float ts = ta + (float(k) + 0.5) * sub;
			vec3 p = ro + rd * ts;
			vec3 pp = cloud_planet(p);
			float fp = ts * uPixAngle;
			float hf = cloud_hfrac(pp);
			if (hf <= 0.0 || hf >= 1.0) continue;
			float sigma;
			float cov = c_cur;
			if (K == 1) sigma = p_cur;   // the probe IS this sample
			else {
				// the coverage varies over tens of km: a refined segment's
				// sub-steps share the probe's
				sigma = cloud_density_cov(pp, uDetail, fp, cov);
			}
			if (sigma <= 0.0) continue;
			// light: the optical depth toward the sun; single scattering, one
			// octave, and the diffusion floor (see the header). Marched once per
			// SEGMENT, at its first cloudy sample, and shared by its sub-steps:
			// a segment is only refined where it is hundreds of metres long,
			// and at that range the self-shadowing a separate light march per
			// sub-step would resolve is finer than a pixel. Marched per
			// sub-step, it was most of the refinement's cost.
			if (od < 0.0) od = cloud_optical_depth_fp(p, uSunDir, uLightSteps, uLightFirst, fp,
				uCovReuse > 0.0 ? cov : -1.0);
			vec3 sun = uSunColor * (ph0 * exp(-od)
				+ 0.5 * ph1 * exp(-od * 0.5)
				+ 0.10 / (1.0 + 0.11 * od));
			// a powder term: the edge of a cloud facing you is darker than its
			// interior, because light entering there has had nothing to scatter
			// off yet. Applied softly, and only away from the forward lobe.
			float powder = mix(1.0, 1.0 - exp(-sigma * 90.0), 0.5 * (1.0 - clamp(cosT, 0.0, 1.0)));
			vec3 amb = mix(uSkyBottom, uSkyTop, smoothstep(0.0, 1.0, hf));
			vec3 S = sigma * (sun * powder * 12.566371 * 0.25 + amb);
			float Ts = exp(-sigma * sub);
			col += T * (S - S * Ts) / sigma;
			tw += T * (1.0 - Ts) * ts;
			wsum += T * (1.0 - Ts);
			T *= Ts;
			if (T < 0.01) break;
		}
		if (T < 0.01) break;
		ta = te; te = tn;
		p_prv = p_cur; p_cur = p_nxt; c_cur = c_nxt;
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
