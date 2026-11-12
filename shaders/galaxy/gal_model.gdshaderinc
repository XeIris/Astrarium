// A galaxy's light and dust from its model (sim/galaxy/gal_visual.gd mirrors every
// function here on the CPU). Galaxy-local kpc, Y the axis, azimuth φ = atan2(z, x).
// Luminosity densities are L☉ kpc⁻³; dust is V-band optical depth per kpc.

// Miyamoto–Nagai disc: (K, a, b) with K = visible·(M/L)⁻¹·M·b²/4π, M in M☉.
uniform vec3 uDisc = vec3(0.0, 3.0, 0.28);
// The light model's edge (kpc): the disc's light tapers to zero over its last fifth, as
// the glow's box ends there. Miyamoto–Nagai light falls only as R⁻³.
uniform float uEdge = 30.0;
// The spiral's own density (Cox & Gómez 2002, eqs. 1–2), the disc's mass gathered
// into arms with zero mean: (K = visible·(L/M)·ρ0, r0, Rs, H); its in-plane factor is in
// the arm map, as it turns with them.
uniform vec4 uSpiral = vec4(0.0, 8.0, 7.0, 0.18);
// The disc's light as the arm map's b instead (L☉ kpc⁻²): (scale, z), exp(−|y|/z)/2z above
// the plane; 0 for the Miyamoto–Nagai disc above.
uniform vec2 uDiscMap = vec2(0.0, 1.0);
// Spheroid: (kind, K, p1, p2). kind 0, a power law with a cutoff: K·r^−α·exp(−r²/rc²),
// p1 = α, p2 = rc. kind 1, Hernquist: K·a/(2π r (r + a)³), p1 = a. kind 2, a measured profile:
// K·exp(ln j), ln j in uSphereTab on texels even in ln r from p1 = ln r₀ by p2, held at r₀ and
// zero past the last texel; linear between texels, read by texelFetch so the CPU's matches.
uniform vec4 uSphere = vec4(0.0, 0.0, 1.8, 1.9);
uniform sampler2D uSphereTab : filter_nearest, repeat_disable;
// The bar's frame for the spheroid's light: (cos θb, sin θb, b/a, c/a); b/a = c/a = 1
// keeps it round. Light is conserved: j(r_e)/(b/a · c/a).
uniform vec4 uBar = vec4(1.0, 0.0, 1.0, 1.0);

// The star-forming disc's radial envelope, the dust disc's: (h_r, hole radius).
uniform vec2 uEnvelope = vec2(2.26, 4.0);

// Dust (Drimmel & Spergel 2001): disc (κρ0, h_r, h0, flare per kpc past uDustB.x),
// arms (κρa, cutoff radius r_m and scale r_a beyond it, width per kpc of radius), uDustB = (disc flare radius, arm height,
// arm flare radius, arm flare per kpc²).
uniform vec4 uDust = vec4(0.0, 2.26, 0.1344, 0.0148);
uniform vec4 uDustArm = vec4(0.0, 6.71, 2.07, 0.0641);
uniform vec4 uDustB = vec4(4.4, 0.08, 5.48, 0.0146);
// Dust as a face-on surface density map instead (M☉ kpc⁻², the arm map's g): (V opacity in
// kpc² M☉⁻¹, z) with exp(−|y|/z)/2z above the plane; 0 for none.
uniform vec2 uDustMap = vec2(0.0, 1.0);


// Young stars along spiral arms: (K, scale height, pattern turn, arm count). The arms
// turn rigidly, so in their own frame they are a fixed map (GalaxyVisual bakes it from
// Reid et al.'s loci): r = Σ exp(−d²/2w²) of the young arms, g = Drimmel & Spergel's
// arm dust factor (cutoff · exp(−(d/w)²)), b = the stellar spiral's e^{−(R−r0)/Rs} cos γ,
// over ±uArmHalf kpc.
uniform vec4 uYoung = vec4(0.0, 0.05, 0.0, 0.0);
uniform sampler2D uArmMap : filter_linear, repeat_disable;
uniform float uArmHalf = 20.0;
// The arm map at a point, turned back into the arms' frame.
vec3 gal_arm_map3(vec3 p) {
	if (uYoung.w < 0.5) return vec3(0.0);
	float c = cos(uYoung.z);
	float sn = sin(uYoung.z);
	vec2 q = vec2(p.x * c + p.z * sn, p.z * c - p.x * sn) / (2.0 * uArmHalf) + 0.5;
	if (q.x <= 0.0 || q.y <= 0.0 || q.x >= 1.0 || q.y >= 1.0) return vec3(0.0);
	return texture(uArmMap, q).rgb;
}

vec2 gal_arm_map(vec3 p) {
	return gal_arm_map3(p).rg;
}

float gal_sech2(float x) {
	float e = exp(-2.0 * abs(x));
	return 4.0 * e / ((1.0 + e) * (1.0 + e));
}

// Dust rings (De Looze et al. 2012's form for M104): each (R, σ, V optical depth per kpc
// at its peak, 0), Gaussian in R, sech² in height with scale uRingH; peak 0 for none.
uniform vec4 uRing[4];
uniform float uRingH = 0.01;
float gal_rings(float R, float y) {
	if (uRing[0].z <= 0.0) return 0.0;
	float t = 0.0;
	for (int i = 0; i < 4; i++) {
		float x = (R - uRing[i].x) / max(uRing[i].y, 1e-6);
		t += uRing[i].z * exp(-0.5 * x * x);
	}
	return t * gal_sech2(y / uRingH);
}

float gal_disc_j(vec3 p) {
	float a = uDisc.y;
	float b2 = uDisc.z * uDisc.z;
	float R2 = p.x * p.x + p.z * p.z;
	float zb = sqrt(p.y * p.y + b2);
	float s = a + zb;
	float q = R2 + s * s;
	float j = uDisc.x * (a * R2 + (a + 3.0 * zb) * s * s) / (q * q * sqrt(q) * zb * zb * zb);
	if (uDiscMap.x > 0.0) j = uDiscMap.x * gal_arm_map3(p).b * exp(-abs(p.y) / uDiscMap.y) / (2.0 * uDiscMap.y);
	if (uSpiral.x > 0.0) {
		// The in-plane factor e^{−(R−r0)/Rs} cos γ turns with the arms: the map's b.
		j += uSpiral.x * gal_arm_map3(p).b * gal_sech2(p.y / uSpiral.w);
	}
	return max(j, 0.0) * smoothstep(uEdge, 0.8 * uEdge, sqrt(R2));
}

float gal_sphere_j(vec3 p) {
	// In the bar's frame, stretched to its axis ratios.
	float u = p.x * uBar.x + p.z * uBar.y;
	float v = -p.x * uBar.y + p.z * uBar.x;
	// The cusp is clamped at 1 pc, inside any pixel at the scales it is drawn from.
	float r = max(length(vec3(u, p.y / uBar.w, v / uBar.z)), 1e-3);
	float k = 1.0 / (uBar.z * uBar.w);
	if (uSphere.x < 0.5) {
		return k * uSphere.y * pow(r, -uSphere.z) * exp(-r * r / (uSphere.w * uSphere.w));
	}
	if (uSphere.x > 1.5) {
		int n = textureSize(uSphereTab, 0).x;
		float x = max((log(r) - uSphere.z) / uSphere.w, 0.0);
		if (x >= float(n - 1)) return 0.0;
		int i = int(x);
		float f = x - float(i);
		float lj = mix(texelFetch(uSphereTab, ivec2(i, 0), 0).r, texelFetch(uSphereTab, ivec2(i + 1, 0), 0).r, f);
		return k * uSphere.y * exp(lj);
	}
	float a = uSphere.z;
	return k * uSphere.y * a / (6.2831853 * r * pow(r + a, 3.0));
}

// The dust disc's radial shape with its central hole, also the star-forming envelope.
float gal_envelope(float R) {
	float rh = uEnvelope.y;
	if (R >= rh) return exp(-R / uEnvelope.x);
	float x = R / (2.0 * rh) - 0.5;
	return exp(-rh / uEnvelope.x) * exp(-x * x / 0.0625);
}

float gal_young_j(vec3 p) {
	if (uYoung.x <= 0.0) return 0.0;
	float R = length(p.xz);
	return uYoung.x * gal_envelope(R) * gal_arm_map(p).r * exp(-abs(p.y) / uYoung.y) / (2.0 * uYoung.y);
}


float gal_dust(vec3 p) {
	float R = length(p.xz);
	if (uDustMap.x > 0.0) {
		return uDustMap.x * gal_arm_map(p).g * exp(-abs(p.y) / uDustMap.y) / (2.0 * uDustMap.y) + gal_rings(R, p.y);
	}
	if (uDust.x <= 0.0) return 0.0;
	float hd = uDust.z + (R > uDustB.x ? uDust.w * (R - uDustB.x) : 0.0);
	float tau = uDust.x * gal_envelope(R) * gal_sech2(p.y / hd);
	if (uDustArm.x > 0.0) {
		// Drimmel & Spergel's eqs. 15–17; the map holds the cutoff and the profile across.
		float ha = uDustB.y + (R > uDustB.z ? uDustB.w * (R - uDustB.z) * (R - uDustB.z) : 0.0);
		tau += uDustArm.x * gal_arm_map(p).g * exp(-p.y * p.y / (ha * ha));
	}
	return tau + gal_rings(R, p.y);
}

// The interstellar medium below the map (sim/galaxy/gal_ism.gd): octaves of a periodic
// Gaussian field in the plane, each sheared by the rotation curve over its eddy's lifetime;
// the dust gathered into sheets at the field's zeros, the young light log-normal. uISMOct[o] is octave o's
// sheet contrast (0: none), uISMYoung its young log-amplitude, uISMLam its longest wavelength
// (kpc), uISMM its turn and scale into the field (two columns) and uISMOff its offset;
// uISMTurn's row o is its turn back (rad) on 64 radii from 0 to uISMTurnR, read by hand.
uniform sampler2D uISM : filter_linear, repeat_enable;
uniform sampler2D uISMTurn : filter_nearest, repeat_disable;
uniform float uISMOct[9];
uniform float uISMYoung[9];
uniform float uISMLam[9];
uniform vec2 uISMM[18];
uniform vec2 uISMOff[9];
uniform float uISMTurnR = 30.0;
// Octaves drawn, from the largest (GalISM.count): the rest are too faint to show.
uniform int uISMCount = 9;
// The dust's structured share, and the height (kpc) beyond which a camera is outside the layer
// and sees the medium.
uniform vec2 uISMLayer = vec2(0.5, 1.0);
// Each multiplier's realised mean over this galaxy at footprints of 12.5 pc doubling to 200 pc
// (GalISM.norms), divided out, linear in log₂ of the footprint between them.
uniform vec2 uISMNorm[5];

// Feathers off the lanes (GalISM.feather): uFeather (amplitude, spacing per R, angle to the
// arm at emergence (rad), width per spacing), uFeatherR (break and corotation radii (kpc),
// mirrored), uLane[k] lane k's (R₀, β₀, tan p in, tan p out) and uLaneSpan[k] its arm's span.
uniform vec4 uFeather = vec4(0.0);
uniform vec3 uFeatherR = vec3(1.0);
uniform vec4 uLane[2];
uniform vec2 uLaneSpan[2];
float gal_feather(vec2 q, float foot) {
	if (uFeather.x <= 0.0) return 1.0;
	float R = length(q);
	float rcr = uFeatherR.y;
	if (R < 0.05 || R > 0.9 * rcr) return 1.0;
	float beta = atan(q.y, q.x) - 3.14159265;
	if (uFeatherR.z > 0.5) beta = -beta;
	float u = 1e9;
	float fade = 0.0;
	float tp = 0.0;
	for (int k = 0; k < 2; k++) {
		vec4 ln = uLane[k];
		vec2 span = uLaneSpan[k];
		float rb = uFeatherR.x;
		float lb = R <= rb ? ln.y - log(R / ln.x) / ln.z : ln.y - log(rb / ln.x) / ln.z - log(R / rb) / ln.w;
		float uk = mod(beta - lb, 6.28318531);
		if (uk < u) {
			u = uk;
			tp = R <= rb ? ln.z : ln.w;
			fade = smoothstep(span.x, span.x + 0.5, R) * smoothstep(span.y, span.y - 0.5, R);
		}
	}
	fade *= smoothstep(0.9 * rcr, 0.7 * rcr, R);
	if (fade <= 0.0) return 1.0;
	float p = atan(tp);
	float aa = 1.0 / tp - 1.0 / tan(min(p + uFeather.z, radians(85.0)));
	float kk = 1.0 / (1.0 - R / rcr);
	float left = 1.0 - kk * u / aa;
	if (left <= 0.0) return 1.0;
	float chi = (log(R) + log(left) / kk) / (uFeather.y * sin(p));
	float a = uFeather.x * fade * left;
	float fs = foot / (0.77 * uFeather.y * R);
	float sig = sqrt(uFeather.w * uFeather.w + fs * fs);
	if (sig >= 0.35) return 1.0;
	int n0 = int(floor(chi));
	float g = 0.0;
	for (int m = n0 - 1; m < n0 + 3; m++) {
		uint h = uint(m * 1973 + 26699);
		h = (h ^ (h >> 16u)) * 2246822519u;
		h = (h ^ (h >> 13u)) * 3266489917u;
		h ^= h >> 16u;
		float jx = float(h & 65535u) / 65536.0;
		float jy = float(h >> 16u) / 65536.0;
		float x = chi - float(m) - 0.3 * (2.0 * jx - 1.0);
		g += -log(1.0 - 0.999 * jy) * exp(-0.5 * x * x / (sig * sig));
	}
	g /= sig * 2.50662827;
	return 1.0 + a * smoothstep(0.35, 0.21, sig) * (g - 1.0);
}

// The dust's and the young light's multipliers at p's place in the plane for a footprint of
// `foot` kpc, each of mean one: octaves finer than the footprint fade out and take their
// contrast with them.
vec2 gal_ism(vec3 p, float foot) {
	if (uISMOct[0] <= 0.0) return vec2(1.0);
	float c = cos(uYoung.z);
	float sn = sin(uYoung.z);
	vec3 q = vec3(p.x * c + p.z * sn, p.y, p.z * c - p.x * sn);
	float x = clamp(length(q.xz) / uISMTurnR, 0.0, 1.0) * 63.0;
	int i = min(int(x), 62);
	float f = x - float(i);
	float ld = 0.0;
	float ly = 0.0;
	for (int o = 0; o < uISMCount; o++) {
		float l = uISMLam[o];
		float w = clamp((0.25 * l - foot) / (0.125 * l), 0.0, 1.0);
		if (w <= 0.0) break;
		float b = uISMOct[o] * w;
		float a = uISMYoung[o] * w;
		// Where this gas was an eddy lifetime ago.
		float ang = -mix(texelFetch(uISMTurn, ivec2(i, o), 0).r, texelFetch(uISMTurn, ivec2(i + 1, o), 0).r, f);
		float ca = cos(ang);
		float sa = sin(ang);
		vec2 h = vec2(q.x * ca - q.z * sa, q.x * sa + q.z * ca);
		vec2 n = texture(uISM, mat2(uISMM[2 * o], uISMM[2 * o + 1]) * h + uISMOff[o]).rg;
		// A sheet where the field crosses zero, exp(−βn²) over its mean (1 + 2β)^(−1/2).
		ld += -b * n.x * n.x + 0.5 * log(1.0 + 2.0 * b);
		ly += a * n.y - 0.5 * a * a;
	}
	float xn = clamp(log2(foot / 0.0125), 0.0, 4.0 - 1e-6);
	int in_ = int(xn);
	return vec2(exp(ld) * gal_feather(q.xz, foot), exp(ly)) / mix(uISMNorm[in_], uISMNorm[in_ + 1], xn - float(in_));
}

// The dust's multiplier from the field's D: its compact share is structured.
float gal_ism_dust(float m) {
	return 1.0 + uISMLayer.x * (m - 1.0);
}


// Disc light, young light and V optical depth per kpc at p, from one map lookup (the
// glow's march; gal_disc_j, gal_young_j and gal_dust give the same apart).
void gal_disc_sample(vec3 p, out float jd, out float jy, out float dtau) {
	vec3 m = gal_arm_map3(p);
	float a = uDisc.y;
	float b2 = uDisc.z * uDisc.z;
	float R2 = p.x * p.x + p.z * p.z;
	float R = sqrt(R2);
	float zb = sqrt(p.y * p.y + b2);
	float s = a + zb;
	float q = R2 + s * s;
	jd = uDisc.x * (a * R2 + (a + 3.0 * zb) * s * s) / (q * q * sqrt(q) * zb * zb * zb);
	if (uDiscMap.x > 0.0) jd = uDiscMap.x * m.b * exp(-abs(p.y) / uDiscMap.y) / (2.0 * uDiscMap.y);
	if (uSpiral.x > 0.0) jd += uSpiral.x * m.b * gal_sech2(p.y / uSpiral.w);
	jd = max(jd, 0.0) * smoothstep(uEdge, 0.8 * uEdge, R);
	float env = gal_envelope(R);
	jy = uYoung.x > 0.0 ? uYoung.x * env * m.r * exp(-abs(p.y) / uYoung.y) / (2.0 * uYoung.y) : 0.0;
	dtau = 0.0;
	if (uDustMap.x > 0.0) dtau = uDustMap.x * m.g * exp(-abs(p.y) / uDustMap.y) / (2.0 * uDustMap.y);
	if (uDust.x > 0.0) {
		float hd = uDust.z + (R > uDustB.x ? uDust.w * (R - uDustB.x) : 0.0);
		dtau = uDust.x * env * gal_sech2(p.y / hd);
		if (uDustArm.x > 0.0) {
			float ha = uDustB.y + (R > uDustB.z ? uDustB.w * (R - uDustB.z) * (R - uDustB.z) : 0.0);
			dtau += uDustArm.x * m.g * exp(-p.y * p.y / (ha * ha));
		}
	}
	dtau += gal_rings(R, p.y);
}
