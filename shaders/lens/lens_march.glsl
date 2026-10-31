#[compute]
#version 450
// BLACK HOLE, pass 1: Kerr null geodesics and the volumetric disc, at the lens scale
// (physics: docs/physics/lensing.md). The sky is evaluated on the resulting
// direction field at full resolution by shaders/sky/background.
layout(local_size_x = 8, local_size_y = 8) in;

//   gMarch0   disc emission (rgb), transmittance (a)
//   gMarch1   outgoing direction as a delta from the undeflected ray (rgb),
//             log of the disc's luminance-weighted mean temperature (a)
layout(rgba16f, set = 0, binding = 0) uniform restrict writeonly image2D gMarch0;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D gMarch1;

#define MAX_HOLES 2
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 holePosRs[MAX_HOLES];   // xyz position (camera-relative scene units), w = r_s
	vec4 holeSpin[MAX_HOLES];    // a* (prograde with the disc), ISCO in r_s, 1/peak Page–Thorne flux, √(r_isco/M)
	vec4 holeRoot[MAX_HOLES];    // roots of x³ − 3x + 2a*
	vec4 holeCoef[MAX_HOLES];    // their Page–Thorne log coefficients
	vec4 camRight;               // camera basis, world space (camMat columns)
	vec4 camUp;
	vec4 camBack;
	vec4 camPosFov;              // xyz camera position (0 under the floating origin), w fov (rad)
	vec4 misc0;                  // aspect, time, discIntensity, discTemp
	vec4 misc1;                  // discTpeakPhys, discOuter, holeCount, _
} P;

#define holeCount int(P.misc1.z + 0.5)
#define camPos P.camPosFov.xyz
#define fov P.camPosFov.w
#define aspect P.misc0.x
#define time P.misc0.y
#define discIntensity P.misc0.z
#define discTemp P.misc0.w
// The disc's true peak temperature (K) from the hole's mass, for the imaging bands
// (the rendered colour is rescaled for the eye; a 10 M☉ disc is ~10⁷ K).
#define discTpeakPhys P.misc1.x
// Outer edge of the disc, in r_s. Set by where gas is actually supplied, so a
// preset that puts a star on a 6 AU orbit needs a smaller disc.
#define discOuter P.misc1.y

vec3 holePos(int k){ return P.holePosRs[k].xyz; }
float holeRs(int k){ return P.holePosRs[k].w; }
float holeA(int k){ return P.holeSpin[k].x; }
// r₊ = M(1 + √(1 − a²)), scene units
float holeRp(int k){ return 0.5 * holeRs(k) * (1.0 + sqrt(max(1.0 - holeA(k) * holeA(k), 0.0))); }

#define PI 3.141592653589793
// Near-extremal prograde orbits skim the horizon for several windings.
#define STEPS 320

// reference radius of the flaring law, in r_s (the Schwarzschild ISCO)
#define R_FLARE 3.0

// noise
float hash31(vec3 p){
	p = fract(p * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p){
	vec3 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash31(i + vec3(0,0,0)), hash31(i + vec3(1,0,0)), f.x),
	               mix(hash31(i + vec3(0,1,0)), hash31(i + vec3(1,1,0)), f.x), f.y),
	           mix(mix(hash31(i + vec3(0,0,1)), hash31(i + vec3(1,0,1)), f.x),
	               mix(hash31(i + vec3(0,1,1)), hash31(i + vec3(1,1,1)), f.x), f.y), f.z);
}
float fbm(vec3 p){
	float v = 0.0, a = 0.5;
	for(int i = 0; i < 4; i++){ v += a * vnoise(p); p = p * 2.13 + 17.3; a *= 0.5; }
	return v;
}
float fbm2(vec3 p){   // cheaper, for the domain warp
	return vnoise(p) * 0.65 + vnoise(p * 2.17 + 5.1) * 0.35;
}

// Planck locus → linear RGB. Colour comes from a temperature, never from a
// hand-picked gradient, so the disc, the stars and the redshift all agree.
// Stellar.BB_LUT: Planck × CIE 1931 → linear sRGB, peak 1, log T 800–42 000 K.
const vec3 BB_LUT[48] = vec3[48](
	vec3(1.0000, 0.0000, 0.0000), vec3(1.0000, 0.0034, 0.0000), vec3(1.0000, 0.0178, 0.0000), vec3(1.0000, 0.0349, 0.0000),
	vec3(1.0000, 0.0549, 0.0000), vec3(1.0000, 0.0776, 0.0000), vec3(1.0000, 0.1030, 0.0000), vec3(1.0000, 0.1313, 0.0000),
	vec3(1.0000, 0.1622, 0.0000), vec3(1.0000, 0.1960, 0.0000), vec3(1.0000, 0.2324, 0.0000), vec3(1.0000, 0.2713, 0.0096),
	vec3(1.0000, 0.3128, 0.0280), vec3(1.0000, 0.3566, 0.0523), vec3(1.0000, 0.4025, 0.0837), vec3(1.0000, 0.4503, 0.1228),
	vec3(1.0000, 0.4997, 0.1705), vec3(1.0000, 0.5503, 0.2275), vec3(1.0000, 0.6018, 0.2942), vec3(1.0000, 0.6538, 0.3707),
	vec3(1.0000, 0.7058, 0.4571), vec3(1.0000, 0.7574, 0.5527), vec3(1.0000, 0.8081, 0.6570), vec3(1.0000, 0.8574, 0.7689),
	vec3(1.0000, 0.9050, 0.8870), vec3(0.9901, 0.9411, 1.0000), vec3(0.8802, 0.8746, 1.0000), vec3(0.7913, 0.8183, 1.0000),
	vec3(0.7187, 0.7704, 1.0000), vec3(0.6590, 0.7295, 1.0000), vec3(0.6095, 0.6944, 1.0000), vec3(0.5682, 0.6641, 1.0000),
	vec3(0.5335, 0.6379, 1.0000), vec3(0.5041, 0.6152, 1.0000), vec3(0.4792, 0.5955, 1.0000), vec3(0.4579, 0.5782, 1.0000),
	vec3(0.4396, 0.5631, 1.0000), vec3(0.4238, 0.5499, 1.0000), vec3(0.4101, 0.5382, 1.0000), vec3(0.3982, 0.5280, 1.0000),
	vec3(0.3877, 0.5189, 1.0000), vec3(0.3786, 0.5108, 1.0000), vec3(0.3706, 0.5036, 1.0000), vec3(0.3635, 0.4972, 1.0000),
	vec3(0.3572, 0.4915, 1.0000), vec3(0.3516, 0.4864, 1.0000), vec3(0.3466, 0.4819, 1.0000), vec3(0.3422, 0.4778, 1.0000)
);
vec3 blackbody(float T){
	T = clamp(T, 800.0, 42000.0);
	float u = log(T / 800.0) / log(42000.0 / 800.0) * 47.0;
	int i = min(int(u), 46);
	return mix(BB_LUT[i], BB_LUT[i + 1], u - float(i));
}

// disc

// Flaring scale height. Thin discs run H/R ≈ 0.05 and flare outward as r^(9/8).
float scaleHeight(float r, float rs){
	return rs * (0.045 * pow(r / (R_FLARE * rs), 1.125) + 0.012);
}

// Page–Thorne effective temperature (F/F_peak)^¼ at r (units of M); zero at the ISCO.
float ptTemp(int k, float rM){
	vec4 s = P.holeSpin[k];
	float x = sqrt(rM), x0 = s.w, a = s.x;
	if(x <= x0) return 0.0;
	vec3 xr = P.holeRoot[k].xyz, c = P.holeCoef[k].xyz;
	float t = x - x0 - 1.5 * a * log(x / x0)
		- c.x * log((x - xr.x) / (x0 - xr.x))
		- c.y * log((x - xr.y) / (x0 - xr.y))
		- c.z * log((x - xr.z) / (x0 - xr.z));
	float F = t / (x * x * x * x * (x * x * x - 3.0 * x + 2.0 * a));
	return pow(max(F * s.z, 0.0), 0.25);
}

// Turbulent density in the co-rotating frame — the strands.
float discDensity(vec3 p, float rs, float r, float H, float rin){
	float y = p.y / H;
	if(abs(y) > 2.6) return 0.0;
	float vert = exp(-0.5 * y * y);

	float lr  = log(r / rs);
	float phi = atan(p.z, p.x);

	// Keplerian shear. Everything downstream is evaluated at ψ, so the pattern
	// is frozen into the flow: it orbits with the gas rather than sliding over it.
	float om  = 5.0 * pow(r / rs, -1.5);
	float psi = phi + om * time;

	// low-frequency warp braids neighbouring strands over one another
	float w = fbm2(vec3(cos(psi) * 0.55, sin(psi) * 0.55, lr * 2.0 + time * 0.03));
	psi += (w - 0.5) * 1.3;

	// Anisotropic noise: small azimuthal radius, large radial multiplier, so features
	// are long and thin. The y term keeps it 3D.
	float yv = y * 0.35;
	vec3 q1 = vec3(cos(psi), sin(psi), 0.0) * 0.80 + vec3(0.0, yv, lr * 11.0);
	vec3 q2 = vec3(cos(psi), sin(psi), 0.0) * 2.20 + vec3(0.0, yv * 2.0, lr * 30.0);
	float f1 = fbm(q1 + vec3(0.0, 0.0,  time * 0.035));   // slow decorrelation
	float f2 = fbm(q2 - vec3(0.0, 0.0,  time * 0.080));

	float strands = f1 * 0.70 + f2 * 0.44;
	// Contrast curve. The disc is optically thick, so structure is only visible
	// where the optical depth swings from ≫1 (opaque filament) to ≪1 (gap).
	strands = pow(clamp(strands * 1.70 - 0.52, 0.0, 1.0), 2.2);

	// a pair of broad spiral density waves, wound by the same shear
	float arms = 0.72 + 0.28 * sin(2.0 * psi + lr * 4.5);

	// taper both edges so the disc doesn't end on a hard rim
	float rn    = (r / rs - rin) / max(discOuter - rin, 1e-3);
	float edge  = smoothstep(0.0, 0.10, rn) * (1.0 - smoothstep(0.55, 1.0, rn));

	return strands * arms * vert * edge * 9.0;
}

// The source function S = j/κ, already transported to the observer. Independent of
// density: an optically thick medium's brightness is set by temperature. `g` is the
// frequency ratio observed/emitted.
vec3 discSource(int k, float rM, float g, float dens, out float Tphys){
	float Tn = ptTemp(k, rM);

	// Peak colour temperature — the "Disc Temp" control, deliberately rescaled so
	// the visible gradient spans the same SHAPE the true profile has.
	float Tpeak = mix(3200.0, 12000.0, discTemp);
	float Temit = Tpeak * max(Tn, 0.02);

	// T_obs = g·T_emit — the approaching limb is genuinely hotter-looking.
	vec3 col = blackbody(Temit * g);

	// The physically true observed temperature, carried alongside the colour.
	Tphys = discTpeakPhys * max(Tn, 0.02) * g;

	// I_obs ∝ g⁴ (Liouville, bolometric), radial falloff softened to T^2.6.
	float emis = pow(Tn, 2.6) * pow(g, 4.0);

	// Turbulent heating concentrated in the dense filaments.
	float heat = 0.40 + 0.85 * min(dens, 1.8);

	return col * emis * heat * discIntensity * 0.62;
}

// Kerr–Schild Cartesian form, with the spin along +Z (docs/physics/lensing.md):
// g = η + f k⊗k, f = 2r³/(r⁴ + a²Z²) and k = (1, (rX + aY)/(r² + a²), (rY − aX)/(r² + a²), Z/r),
// where r solves (X² + Y²)/(r² + a²) + Z²/r² = 1. Units of M. Returns r, f, the
// spatial k and their gradients; dk[i] = ∂k/∂Xᵢ.
void kerrSchild(vec3 X, float a, out float r, out float f, out vec3 k, out vec3 df, out mat3 dk){
	float a2 = a * a, z2 = X.z * X.z;
	float w = dot(X, X) - a2;
	float s = sqrt(0.25 * w * w + a2 * z2);
	// The product of the roots avoids cancellation inside the ring radius.
	float r2 = max(w >= 0.0 ? 0.5 * w + s : a2 * z2 / max(s - 0.5 * w, 1e-30), 1e-12);
	r = sqrt(r2);
	float q = r2 * r2 + a2 * z2;
	vec3 gr = vec3(X.x * r, X.y * r, X.z * (r2 + a2) / r) * (r2 / q);
	f = 2.0 * r * r2 / q;
	df = (6.0 * r2 * gr - f * (4.0 * r2 * r * gr + vec3(0.0, 0.0, 2.0 * a2 * X.z))) / q;
	float S = r2 + a2;
	k = vec3((r * X.x + a * X.y) / S, (r * X.y - a * X.x) / S, X.z / r);
	vec3 c = (vec3(X.xy, 0.0) - 2.0 * r * vec3(k.xy, 0.0)) / S;
	dk[0] = gr.x * c + vec3(r / S, -a / S, -X.z * gr.x / r2);
	dk[1] = gr.y * c + vec3(a / S, r / S, -X.z * gr.y / r2);
	dk[2] = gr.z * c + vec3(0.0, 0.0, 1.0 / r - X.z * gr.z / r2);
}

// Scene → Kerr–Schild axes: the spin (KS +Z) points along scene −y, the disc's
// angular momentum (it orbits +x → +z). A proper rotation, so covectors map alike.
vec3 toKS(vec3 v){ return vec3(v.x, v.z, -v.y); }
vec3 fromKS(vec3 v){ return vec3(v.x, -v.z, v.y); }

// Rays are traced forwards in the time reverse of the scene, which is Kerr with −a:
// ingoing Kerr–Schild coordinates are regular on that future horizon. H = ½gᵘᵛpᵤpᵥ with
// gᵘᵛ = η − Σ fₖ Kₖ⊗Kₖ (exact for one hole; the two-hole sum is illustrative). Returns
// dx/dλ, dp/dλ and each hole's Boyer–Lindquist-like r in scene units.
void geodesic(vec3 pos, vec3 p, float pt, out vec3 v, out vec3 dp, out float rh[MAX_HOLES]){
	v = p; dp = vec3(0.0);
	for(int k = 0; k < MAX_HOLES; k++){
		rh[k] = uintBitsToFloat(0x7f7fffffu);
		if(k >= holeCount) break;
		float M = 0.5 * holeRs(k);
		float r, f; vec3 kv, df; mat3 dk;
		kerrSchild(toKS((pos - holePos(k)) / M), -holeA(k), r, f, kv, df, dk);
		vec3 Pk = toKS(p);
		float Kp = -pt + dot(kv, Pk);
		v -= fromKS(f * Kp * kv);
		dp += fromKS(0.5 * df * Kp * Kp + f * Kp * (transpose(dk) * Pk)) / M;
		rh[k] = r * M;
	}
}

void main(){
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(gMarch0);
	if(px.x >= sz.x || px.y >= sz.y) return;
	// Image row zero and SCREEN_UV are top-down; NDC points up.
	vec2 vUv = vec2((float(px.x) + 0.5) / float(sz.x), 1.0 - (float(px.y) + 0.5) / float(sz.y));
	vec2 ndc = vUv * 2.0 - 1.0;
	ndc.x *= aspect;
	float f = tan(fov * 0.5);
	vec3 rl = normalize(vec3(ndc.x * f, ndc.y * f, -1.0));
	vec3 rd = normalize(P.camRight.xyz * rl.x + P.camUp.xyz * rl.y + P.camBack.xyz * rl.z);

	// The photon leaves the camera along rd in the time-reversed scene: p = u + n, with u
	// a static observer (or, inside an ergosphere, the Kerr–Schild normal observer) and
	// n unit and orthogonal to it, so the camera measures energy 1.
	vec3 pos = camPos;
	vec3 p0 = rd;
	float pt = -1.0;
	bool captured = false;
	if(holeCount == 1){
		float M = 0.5 * holeRs(0);
		float r, fk; vec3 kv, df; mat3 dk;
		kerrSchild(toKS((camPos - holePos(0)) / M), -holeA(0), r, fk, kv, df, dk);
		vec3 D = toKS(rd);
		float ut; vec3 us, w;
		if(fk < 1.0){
			// The static frame's spatial metric is δ + f/(1 − f) k⊗k; its symmetric
			// inverse square root maps the local ray to a coordinate direction.
			ut = inversesqrt(1.0 - fk); us = vec3(0.0);
			w = D - (1.0 - sqrt(1.0 - fk)) * dot(kv, D) * kv;
		} else {
			float al = inversesqrt(1.0 + fk);
			ut = al * (1.0 + fk); us = -al * fk * kv;
			w = D * inversesqrt(1.0 + fk * dot(kv, D) * dot(kv, D));
		}
		float nt = fk < 1.0 ? fk * dot(kv, w) / (1.0 - fk) : 0.0;
		float put = ut + nt;
		vec3 pus = us + w;
		float kp = put + dot(kv, pus);
		pt = -put + fk * kp;
		p0 = fromKS(pus + fk * kp * kv);
		captured = r < 1.0 + sqrt(max(1.0 - holeA(0) * holeA(0), 0.0));
	} else {
		// Two holes: the plain direction, with the energy that makes it null.
		float F = 0.0, B = 0.0, C = 0.0;
		for(int k = 0; k < MAX_HOLES; k++){
			if(k >= holeCount) break;
			float M = 0.5 * holeRs(k);
			float r, fk; vec3 kv, df; mat3 dk;
			kerrSchild(toKS((camPos - holePos(k)) / M), -holeA(k), r, fk, kv, df, dk);
			float c = dot(kv, toKS(rd));
			F += fk; B += fk * c; C += fk * c * c;
		}
		pt = -(-B + sqrt(max(B * B + (1.0 + F) * (1.0 - C), 0.0))) / (1.0 + F);
	}
	// The bend accumulates separately so fp32 keeps it when it is tiny.
	vec3 dP = vec3(0.0);
	vec3 color = vec3(0.0);
	float trans = 1.0;
	float tSum = 0.0, tWeight = 0.0;      // luminance-weighted mean disc temperature

	float maxDiscH[MAX_HOLES];
	for(int k = 0; k < MAX_HOLES; k++){
		if(k >= holeCount) break;
		maxDiscH[k] = scaleHeight(discOuter * holeRs(k), holeRs(k));
	}

	float rsMax = holeRs(0);
	for(int k = 1; k < MAX_HOLES; k++){ if(k < holeCount) rsMax = max(rsMax, holeRs(k)); }

	// escape radius: comfortably outside both the disc and the camera
	float camR = distance(camPos, holePos(0));
	float far  = max(camR * 1.4 + 40.0 * rsMax, 120.0 * rsMax);

	vec3 v1 = p0;
	bool escaped = false;
	float nearest = 0.0;   // the last step's closest approach, in that hole's r_s
	for(int i = 0; i < STEPS && !captured; i++){
		vec3 dp1; float rh[MAX_HOLES];
		geodesic(pos, p0 + dP, pt, v1, dp1, rh);
		// adaptive step: fine near a horizon and near a disc plane
		float step = uintBitsToFloat(0x7f7fffffu);
		float minr = step;
		nearest = step;
		for(int k = 0; k < MAX_HOLES; k++){
			if(k >= holeCount) break;
			float rs = holeRs(k);
			float r  = rh[k];
			minr = min(minr, r);
			nearest = min(nearest, r / rs);
			if(r < holeRp(k)){ captured = true; }

			// A floor of 0.1 r_s holds the near-extremal prograde edge to ~1%.
			step = min(step, max(0.16 * (r - holeRp(k)), 0.1 * rs));
			step = min(step, r * 0.30);

			// never leap over the slab: cap by the distance to the equatorial plane
			vec3 pl = pos - holePos(k);
			float rcyl = length(pl.xz);
			float rin = P.holeSpin[k].y * rs;
			if(rcyl + step >= rin && rcyl - step <= discOuter * rs && abs(pl.y) < discOuter * rs){
				float H = scaleHeight(max(rcyl, rin), rs);
				step = min(step, max(abs(pl.y) * 0.45, H * 0.7));
			}
		}
		if(captured) break;
		if(minr > far){ escaped = true; break; }
		step = clamp(step, rsMax * 0.010, max(12.0 * rsMax, 0.16 * minr));

		// RK2 midpoint in the affine parameter, sized to the spatial step.
		float h = step / length(v1);
		vec3 v2, dp2; float rm[MAX_HOLES];
		geodesic(pos + v1 * (0.5 * h), p0 + dP + dp1 * (0.5 * h), pt, v2, dp2, rm);
		vec3 npos = pos + v2 * h;
		dP += dp2 * h;

		// volumetric disc sample at the segment midpoint
		vec3 mid = mix(pos, npos, 0.5);
		vec3 pm = p0 + dP - dp2 * (0.5 * h);
		for(int k = 0; k < MAX_HOLES; k++){
			if(k >= holeCount) break;
			float rs = holeRs(k);
			float M = 0.5 * rs;
			float a = holeA(k);
			vec3 pl = mid - holePos(k);
			// H(r) increases to the outer edge; density vanishes above 2.6 H(r).
			if(abs(pl.y) > 3.0 * maxDiscH[k]) continue;
			// Boyer–Lindquist r in the equatorial plane: r² = ϖ² − a²M².
			float r = sqrt(max(dot(pl.xz, pl.xz) - a * a * M * M, 0.0));
			float rin = P.holeSpin[k].y;
			if(r < rin * rs || r > discOuter * rs) continue;
			float H = scaleHeight(r, rs);
			float dens = discDensity(pl, rs, r, H, rin);
			if(dens <= 0.0015) continue;

			// Redshift from the conserved E = −pₜ and L = p_φ: the gas is on a prograde
			// circular orbit, which in the reversed scene runs at Ω = −1/(r^1.5 + a).
			float rM = r / M;
			float r15 = rM * sqrt(rM);
			float ut = (r15 + a) / (pow(rM, 0.75) * sqrt(max(r15 - 3.0 * sqrt(rM) + 2.0 * a, 1e-6)));
			vec3 X = toKS(pl), Pk = toKS(pm);
			float L = (X.x * Pk.y - X.y * Pk.x) / M;
			float g = clamp(1.0 / (ut * (-pt + L / (r15 + a))), 0.04, 5.0);

			// Exact dI/dτ = S − I over the segment: I += S(1 − e^−τ). Path length in horizon
			// radii.
			float dl  = step / rs;
			float tau = dens * dl * 4.5;
			float att = exp(-tau);
			float Tphys;
			vec3 add = trans * discSource(k, rM, g, dens, Tphys) * (1.0 - att);
			color += add;
			// weight by how much this sample actually contributed to the pixel
			float wt = dot(add, vec3(0.2126, 0.7152, 0.0722));
			tSum += wt * Tphys; tWeight += wt;
			trans *= att;
		}

		pos = npos;
		if(trans < 0.004) break;
	}
	// A ray still winding near a photon orbit when the steps run out is all but captured.
	if(!captured && !escaped && trans >= 0.004 && nearest < 4.0) captured = true;

	// hand over to the resolve pass. The direction is stored as a delta from the
	// undeflected ray, so fp16 spends its mantissa on the bend.
	vec3 d = normalize(v1);
	// Zeroing transmittance on capture retires a separate captured flag.
	float tr = captured ? 0.0 : trans;
	float Tmean = tWeight > 1e-9 ? tSum / tWeight : 0.0;

	imageStore(gMarch0, px, vec4(color, tr));
	imageStore(gMarch1, px, vec4(d - rd, Tmean > 1.0 ? log(Tmean) : 0.0));
}
