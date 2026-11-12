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
// Spheroid: (kind, K, p1, p2). kind 0, a power law with a cutoff: K·r^−α·exp(−r²/rc²),
// p1 = α, p2 = rc. kind 1, Hernquist: K·a/(2π r (r + a)³), p1 = a.
uniform vec4 uSphere = vec4(0.0, 0.0, 1.8, 1.9);
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
	if (uDust.x <= 0.0) return 0.0;
	float R = length(p.xz);
	float hd = uDust.z + (R > uDustB.x ? uDust.w * (R - uDustB.x) : 0.0);
	float tau = uDust.x * gal_envelope(R) * gal_sech2(p.y / hd);
	if (uDustArm.x > 0.0) {
		// Drimmel & Spergel's eqs. 15–17; the map holds the cutoff and the profile across.
		float ha = uDustB.y + (R > uDustB.z ? uDustB.w * (R - uDustB.z) * (R - uDustB.z) : 0.0);
		tau += uDustArm.x * gal_arm_map(p).g * exp(-p.y * p.y / (ha * ha));
	}
	return tau + gal_rings(R, p.y);
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
	if (uSpiral.x > 0.0) jd += uSpiral.x * m.b * gal_sech2(p.y / uSpiral.w);
	jd = max(jd, 0.0) * smoothstep(uEdge, 0.8 * uEdge, R);
	float env = gal_envelope(R);
	jy = uYoung.x > 0.0 ? uYoung.x * env * m.r * exp(-abs(p.y) / uYoung.y) / (2.0 * uYoung.y) : 0.0;
	dtau = 0.0;
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
