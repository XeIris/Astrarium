#[compute]
#version 450
// BLACK HOLE, pass 1: null geodesics and the volumetric disc, at the lens scale
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

#define PI 3.141592653589793
#define STEPS 240

// inner edge of the disc, in r_s — the ISCO of a Schwarzschild hole
#define R_ISCO 3.0

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
vec3 blackbody(float T){
	T = clamp(T, 800.0, 42000.0);
	float t = T * 0.01;
	vec3 c;
	c.r = t <= 66.0 ? 255.0 : 329.698727446 * pow(max(t - 60.0, 1e-3), -0.1332047592);
	c.g = t <= 66.0 ? 99.4708025861 * log(t) - 161.1195681661
	                : 288.1221695283 * pow(max(t - 60.0, 1e-3), -0.0755148492);
	c.b = t >= 66.0 ? 255.0
	    : (t <= 19.0 ? 0.0 : 138.5177312231 * log(max(t - 10.0, 1e-3)) - 305.0447927307);
	c = clamp(c / 255.0, 0.0, 1.0);
	return pow(c, vec3(2.2));                 // sRGB fit → linear
}

// disc

// Flaring scale height. Thin discs run H/R ≈ 0.05 and flare outward as r^(9/8).
float scaleHeight(float r, float rs){
	return rs * (0.045 * pow(r / (R_ISCO * rs), 1.125) + 0.012);
}

// Shakura–Sunyaev radial temperature, normalised to peak at 1.
// Peaks at r = (49/36)·r_in where the profile reaches 0.4880.
float ssTemp(float r, float rin){
	float x = rin / r;
	if(x >= 1.0) return 0.0;
	return pow(x, 0.75) * pow(max(1.0 - sqrt(x), 0.0), 0.25) * 2.0492;
}

// Turbulent density in the co-rotating frame — the strands.
float discDensity(vec3 p, float rs, float r, float H){
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
	float rn    = (r / rs - R_ISCO) / max(discOuter - R_ISCO, 1e-3);
	float edge  = smoothstep(0.0, 0.10, rn) * (1.0 - smoothstep(0.55, 1.0, rn));

	return strands * arms * vert * edge * 9.0;
}

// The source function S = j/κ, already transported to the observer. Independent of
// density: an optically thick medium's brightness is set by temperature.
vec3 discSource(vec3 p, vec3 rd, float rs, float r, float dens, out float Tphys){
	float rin = R_ISCO * rs;
	float Tn  = ssTemp(r, rin);

	// Peak colour temperature — the "Disc Temp" control, deliberately rescaled so
	// the visible gradient spans the same SHAPE the true profile has.
	float Tpeak = mix(3200.0, 12000.0, discTemp);
	float Temit = Tpeak * max(Tn, 0.02);

	// circular-orbit speed measured by a static local observer
	float grav = sqrt(max(1.0 - rs / r, 1e-4));
	float beta = clamp(sqrt(0.5 * rs / r) / grav, 0.0, 0.96);
	float gam  = 1.0 / sqrt(max(1.0 - beta * beta, 1e-4));

	vec3 vhat = normalize(vec3(-p.z, 0.0, p.x));      // prograde tangent
	vec3 nobs = -rd;                                   // back along the ray, to the eye
	float dop = 1.0 / (gam * (1.0 - beta * dot(vhat, nobs)));

	float g = clamp(dop * grav, 0.04, 5.0);

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

// Null geodesic: d²x/dλ² = −(3/2) r_s h² x / r⁵.
vec3 holeAccel(vec3 rv, vec3 vel, float rs, float distanceToHole){
	// Unit-direction factors avoid scene-unit fifth powers and absolute floors.
	float r = max(distanceToHole, rs * 1e-5);
	vec3 rhat = rv / r;
	vec3 hhat = cross(rhat, vel);
	return -1.5 * (rs / r) * (1.0 / r) * dot(hhat, hhat) * rhat;
}

vec3 geoAccel(vec3 pos, vec3 vel){
	vec3 a = vec3(0.0);
	for(int k = 0; k < MAX_HOLES; k++){
		if(k >= holeCount) break;
		vec3 rv = pos - holePos(k);
		a += holeAccel(rv, vel, holeRs(k), length(rv));
	}
	return a;
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

	vec3 pos = camPos;
	vec3 vel = rd;
	if(holeCount == 1){
		vec3 rv = camPos - holePos(0);
		float r = length(rv);
		if(r > holeRs(0)){
			// Static observer's local ray to a coordinate tangent: docs/physics/lensing.md.
			vec3 rhat = rv / r;
			vec3 radial = dot(rd, rhat) * rhat;
			vel = normalize(radial + (rd - radial) / sqrt(1.0 - holeRs(0) / r));
		}
	}
	vec3 color = vec3(0.0);
	float trans = 1.0;
	bool captured = false;
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

	for(int i = 0; i < STEPS; i++){
		// adaptive step: fine near a horizon and near a disc plane
		float step = uintBitsToFloat(0x7f7fffffu);
		float minr = step;
		vec3 k1 = vec3(0.0);
		for(int k = 0; k < MAX_HOLES; k++){
			if(k >= holeCount) break;
			float rs = holeRs(k);
			vec3 pl  = pos - holePos(k);
			float r  = length(pl);
			minr = min(minr, r);
			if(r < rs){ captured = true; }

			step = min(step, max(0.16 * (r - rs), 0.012 * rs));
			step = min(step, r * 0.30);

			// never leap over the slab: cap by the distance to the equatorial plane
			float rcyl = length(pl.xz);
			if(rcyl + step >= R_ISCO * rs && rcyl - step <= discOuter * rs && abs(pl.y) < discOuter * rs){
				float H = scaleHeight(max(rcyl, R_ISCO * rs), rs);
				step = min(step, max(abs(pl.y) * 0.45, H * 0.7));
			}
			// Avoid a second distance evaluation for this curvature stage.
			k1 += holeAccel(pl, vel, rs, r);
		}
		if(captured) break;
		if(minr > far) break;
		step = clamp(step, rsMax * 0.010, max(12.0 * rsMax, 0.16 * minr));
		k1 -= vel * dot(k1, vel);

		// Arclength curvature is the transverse part of the affine acceleration.
		vec3 vh  = normalize(vel + k1 * (step * 0.5));
		vec3 ph  = pos + vel * (step * 0.5);
		vec3 k2  = geoAccel(ph, vh);
		k2 -= vh * dot(k2, vh);
		vec3 nvel = normalize(vel + k2 * step);
		vec3 npos = pos + vh * step;

		// volumetric disc sample at the segment midpoint
		vec3 mid = mix(pos, npos, 0.5);
		for(int k = 0; k < MAX_HOLES; k++){
			if(k >= holeCount) break;
			float rs = holeRs(k);
			vec3 pl = mid - holePos(k);
			// H(r) increases to the outer edge; density vanishes above 2.6 H(r).
			if(abs(pl.y) > 3.0 * maxDiscH[k]) continue;
			float r = length(pl.xz);
			if(r < R_ISCO * rs || r > discOuter * rs) continue;
			float H = scaleHeight(r, rs);
			float dens = discDensity(pl, rs, r, H);
			if(dens <= 0.0015) continue;

			// Exact dI/dτ = S − I over the segment: I += S(1 − e^−τ). Path length in horizon
			// radii.
			float dl  = step / rs;
			float tau = dens * dl * 4.5;
			float att = exp(-tau);
			float Tphys;
			vec3 add = trans * discSource(pl, nvel, rs, r, dens, Tphys) * (1.0 - att);
			color += add;
			// weight by how much this sample actually contributed to the pixel
			float w = dot(add, vec3(0.2126, 0.7152, 0.0722));
			tSum += w * Tphys; tWeight += w;
			trans *= att;
		}

		if(trans < 0.004) break;
		vel = nvel;
		pos = npos;
	}

	// hand over to the resolve pass. The direction is stored as a delta from the
	// undeflected ray, so fp16 spends its mantissa on the bend.
	vec3 d = normalize(vel);
	// Zeroing transmittance on capture retires a separate captured flag.
	float tr = captured ? 0.0 : trans;
	float Tmean = tWeight > 1e-9 ? tSum / tWeight : 0.0;

	imageStore(gMarch0, px, vec4(color, tr));
	imageStore(gMarch1, px, vec4(d - rd, Tmean > 1.0 ? log(Tmean) : 0.0));
}
