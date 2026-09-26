#[compute]
#version 450
// ============================================================================
// SPECTRAL RE-IMAGING — the port of sim/spectrum.js's REMAP_FRAG. The physics,
// the knots and the palettes are unchanged; only the plumbing is compute. The
// header of sim/spectrum.gd carries the derivation.
// ============================================================================
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tSrc;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D outImg;
layout(push_constant, std430) uniform PC {
	// uTheta = hν/k for the band, in kelvin: the temperature at which this
	// band's Planck exponent is unity, and therefore the band's Wien cutoff.
	float uTheta;
	float uTref;
	float uPalette;
	float uStretch;
} pc;

// --- inverse of the Planck-locus colour fit -------------------------------
// x = ln(b/r) in LINEAR light. The knots below are that fit evaluated at
// known temperatures; the curve is steep in the cool half and saturates in
// the hot half, so a straight exponential fit will not do — this is a
// piecewise-linear inverse through the tabulated points.
float estimateT(vec3 c){
	float r = max(c.r, 1e-7);
	float b = max(c.b, 1e-7);
	float x = log(b / r);

	// (x, lnT) knots: 1200 K … 40000 K
	const int N = 7;
	float xs[7]; float ts[7];
	xs[0] = -9.00; ts[0] = 7.090;   //  1200 K
	xs[1] = -6.40; ts[1] = 7.601;   //  2000 K
	xs[2] = -1.851; ts[2] = 8.006;  //  3000 K
	xs[3] = -0.223; ts[3] = 8.661;  //  5772 K
	xs[4] =  0.516; ts[4] = 9.210;  // 10000 K
	xs[5] =  0.883; ts[5] = 9.903;  // 20000 K
	xs[6] =  1.142; ts[6] = 10.597; // 40000 K

	if(x <= xs[0]) return exp(ts[0]);
	for(int i = 1; i < N; i++){
		if(x <= xs[i]){
			float f = (x - xs[i-1]) / max(xs[i] - xs[i-1], 1e-6);
			// Capped well below the fit's own ceiling. Inference is only
			// trustworthy for pixels that really are blackbody-coloured; anything
			// genuinely hotter than this publishes its temperature in alpha
			// instead, so the top of the table only ever gets reached by things
			// that merely happen to be blue — and calling those 40 000 K makes
			// them erupt in the ultraviolet.
			return clamp(exp(mix(ts[i-1], ts[i], f)), 1200.0, 20000.0);
		}
	}
	return 20000.0;
}

// ln(exp(u) − 1), stable across the ~14 decades of u this has to span.
float lnExpm1(float u){
	if(u > 20.0)  return u;                        // the −1 is irrelevant
	if(u < 1e-4)  return log(max(u, 1e-30));       // exp(u)−1 → u
	return log(exp(u) - 1.0);
}

// Surface brightness in the band at temperature T, relative to the band's
// reference temperature. The ν³ prefactor cancels; only the Planck exponent —
// the Wien cutoff — survives, and it is the whole reason the bands differ.
float bandBrightness(float T){
	float lnB = lnExpm1(pc.uTheta / max(pc.uTref, 1.0)) - lnExpm1(pc.uTheta / max(T, 1.0));
	return exp(clamp(lnB, -60.0, 20.0));
}

// --- false colour ---------------------------------------------------------
vec3 ramp(vec3 a, vec3 b, vec3 c, vec3 d, float v){
	v = clamp(v, 0.0, 1.0);
	if(v < 0.3333) return mix(a, b, v * 3.0);
	if(v < 0.6667) return mix(b, c, (v - 0.3333) * 3.0);
	return mix(c, d, (v - 0.6667) * 3.0);
}

vec3 palette(float v){
	int uPalette = int(pc.uPalette + 0.5);
	if(uPalette == 0)        // radio — magenta/orange, VLA-ish
		return ramp(vec3(0.0), vec3(0.16,0.0,0.22), vec3(0.64,0.0,0.43), vec3(1.0,0.62,0.24), v);
	else if(uPalette == 1)   // microwave — cold blue to white, Planck-ish
		return ramp(vec3(0.0), vec3(0.02,0.06,0.24), vec3(0.15,0.55,0.80), vec3(1.0,1.0,1.0), v);
	else if(uPalette == 2)   // infrared — Spitzer/JWST heat scale
		return ramp(vec3(0.0), vec3(0.24,0.04,0.0), vec3(1.0,0.35,0.0), vec3(1.0,0.93,0.72), v);
	else if(uPalette == 4)   // ultraviolet — GALEX-ish indigo
		return ramp(vec3(0.0), vec3(0.10,0.03,0.28), vec3(0.42,0.30,0.95), vec3(0.82,0.93,1.0), v);
	else if(uPalette == 5)   // X-ray — Chandra-ish blue/purple
		return ramp(vec3(0.0), vec3(0.02,0.08,0.30), vec3(0.48,0.22,0.85), vec3(1.0,1.0,1.0), v);
	else                     // gamma — Fermi-ish green/yellow
		return ramp(vec3(0.0), vec3(0.0,0.16,0.06), vec3(0.42,0.86,0.16), vec3(1.0,1.0,0.85), v);
}

void main(){
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outImg);
	if(p.x >= sz.x || p.y >= sz.y) return;
	vec4 src = texelFetch(tSrc, p, 0);
	vec3 c = src.rgb;
	float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
	if(lum <= 1e-6){ imageStore(outImg, p, vec4(0.0, 0.0, 0.0, 1.0)); return; }

	// Emitters publish their TRUE temperature in alpha, log-encoded. The
	// reserved value 1.0 means "no data", and those pixels fall back to
	// inferring T from the colour — which is exactly right for lit geometry.
	float a = src.a;

	// SKY_ALPHA (0.995, from sim/sky.gd) means "already imaged in this band".
	// The celestial background is mostly non-thermal outside the visible and
	// has no temperature for a Planck ratio to use, so sim/sky.gd composites it
	// at the band's own frequency and this pass only stretches and colours it.
	if(a > 0.990 && a < 0.9985){
		float sky = dot(c, vec3(0.2126, 0.7152, 0.0722));
		float vs = log(1.0 + sky * pc.uStretch) / log(1.0 + 3.0 * pc.uStretch);
		imageStore(outImg, p, vec4(palette(vs) * 1.55, 1.0));
		return;
	}

	float T = (a > 0.005 && a < 0.985) ? exp(a * 25.33) : estimateT(c);

	// The rendered luminance is used only as a COVERAGE mask — "is there
	// emitting material on this pixel" — never as the band radiance: the disc is
	// drawn in a rescaled palette, so its visible brightness is not B_ν(ν_vis,
	// T_true). The threshold keeps the faint nebular gradient of the sky from
	// being amplified by the band gain into a glowing field.
	float cover = smoothstep(0.02, 0.25, lum) * clamp(lum / 1.2, 0.05, 1.2);
	float band = cover * bandBrightness(T);

	// Log stretch, anchored so full scale sits a little above the band's
	// reference source — every astronomical image outside the visible is shown
	// this way.
	float v = log(1.0 + band * pc.uStretch) / log(1.0 + 3.0 * pc.uStretch);

	imageStore(outImg, p, vec4(palette(v) * 1.55, 1.0));
}
