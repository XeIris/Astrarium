// THE PHOTOSPHERE, and the chromosphere seen against it. Every feature is a local
// temperature turned into colour by the Planck ratio; the chromosphere is optically
// thin line emission on top. Models and sources: docs/physics/stellar-surfaces.md.
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/star_noise.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);   // unused
uniform vec3 uHot = vec3(1.0);     // unused
uniform float uPulse = 1.0;
// Quadratic limb darkening per primary (Stellar.limb_darkening).
uniform vec3 uLimbA = vec3(0.45, 0.52, 0.60);
uniform vec3 uLimbB = vec3(0.17, 0.16, 0.15);
// physical Teff, published to the spectral imaging pass (the temperature pass)
uniform float uTeff = 5772.0;
uniform float uOmega = 1.0;
// uSpin is Ω/Ω_crit, which sets both the shape and the temperature map; at 0
// everything reduces to the non-rotating case.
uniform float uSpin = 0.0;
uniform float uGdBeta = 0.25;
uniform vec3 uColPole = vec3(1.0);
uniform vec3 uColEq = vec3(1.0);
uniform float uTpole = 5772.0;
// Surface brightness relative to the Sun (Structure.surface_brightness) and the level
// the continuum is drawn at, low enough that the disc keeps its colour under ACES.
uniform float uGain = 1.0;
uniform float uDisc = 1.0;
uniform float uGranScale = 9.0;
// RMS granulation contrast (Stellar.granulation_contrast); 1 with a convective
// envelope, 0 without (no granules, no spots, no chromosphere).
uniform float uGranContrast = 0.16;
uniform float uConv = 1.0;
// Umbral temperature deficit in K (Stellar.spot_temperature_drop), and the penumbral
// radius of a strength-1 leading spot in stellar radii.
uniform float uSpotDT = 1850.0;
uniform float uSpotSize = 0.045;
// Display weight of the chromosphere's line emission, and its colour (linear).
uniform float uChromo = 0.0;
uniform vec3 uChromoCol = vec3(1.0, 0.30, 0.09);
// How much of the continuum the chromosphere hides (0 without one).
uniform float uVeil = 0.0;
uniform vec4 uSpots[8];      // xyz = surface direction, w = strength
uniform int uSpotCount = 0;
uniform vec4 uFlares[4];     // xyz = region direction, w = amplitude
// xyz = the bipole axis (across the neutral line), w = how far the two
// ribbons have separated. A flare is a TWO-ribbon event.
uniform vec4 uFlareAxis[4];
uniform int uFlareCount = 0;

varying vec3 vObj;
varying vec3 vVN;
varying vec3 vVP;
varying float vG;
varying vec3 vCam;

// The Roche equipotential R(θ)/R_pole in closed form (Structure.roche_shape); 1.5 at
// u = 1.
float rocheShape(float u0) {
	float u = clamp(u0, 0.0, 1.0);
	if (u < 1e-3) return 1.0 + 0.148148 * u * u;   // series; the form below is 0/0 here
	return (3.0 / u) * cos((3.14159265 + acos(u)) / 3.0);
}

void vertex() {
	vec3 dir = normalize(VERTEX);
	vObj = dir;
	float sinT = length(dir.xz);
	float x = rocheShape(uSpin * sinT);
	vec3 p = VERTEX * x;                    // radial stretch onto the spheroid

	// Effective gravity in units of its polar value; with GM = 1 and R_pole = 1,
	// Ω² = (8/27) uSpin².
	float om2 = 0.296296 * uSpin * uSpin;
	float gr  = -1.0 / (x * x) + om2 * x * sinT * sinT;
	float gt  = om2 * x * sinT * dir.y;
	vG = sqrt(gr * gr + gt * gt);           // exactly 1 at the pole

	// Tilt the radial normal toward the meridian by the gravity vector's tilt (g is
	// normal to an equipotential).
	vec3 er = dir;
	vec3 et = normalize(vec3(dir.x * dir.y, -sinT * sinT, dir.z * dir.y) + vec3(1e-6));
	vec3 n  = normalize(er * (-gr) + et * (-gt));

	// View space; the floating origin keeps MODELVIEW small.
	vVN = normalize(MODELVIEW_NORMAL_MATRIX * n);
	vVP = (MODELVIEW_MATRIX * vec4(p, 1.0)).xyz;
	// The camera in object space, for the Wilson depression.
	vCam = (inverse(MODELVIEW_MATRIX) * vec4(0.0, 0.0, 0.0, 1.0)).xyz / max(length(VERTEX), 1e-9);
	VERTEX = p;
	NORMAL = n;
}

// rotate a point about the Y axis
vec3 rotY(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z); }

// One sunspot in its group's plane (q in units of the leading spot's penumbral radius,
// r its own radius). Returns (umbra, penumbra, filament brightness 0..1). The umbra is
// sampled through the Wilson depression: displaced toward the disc centre near the limb.
// fq: one pixel in q's units, for fading filaments the pixel cannot resolve.
vec3 spot_shade(vec2 q, float r, vec2 wil, float seed, float rag, float fq) {
	float d = length(q) / r;
	if (d > 1.4) return vec3(0.0);
	float ang = atan(q.y, q.x);
	vec2 ca = vec2(cos(ang), sin(ang));
	float edge = 1.0 + rag * (2.0 * sn_noise(vec3(ca * 1.7, seed)) - 1.0)
	                 + 0.35 * rag * (2.0 * sn_noise(vec3(ca * 5.3, seed + 2.0)) - 1.0);
	float dp = d / edge;
	float pen = 1.0 - smoothstep(0.90, 1.0, dp);
	float du = length(q / r - wil) / edge;
	float umb = 1.0 - smoothstep(0.37, 0.45, du);
	// Penumbral filaments: the near-horizontal field combs the gas into radial threads
	// (integer angular frequencies keep atan's seam invisible), with Evershed grains
	// streaming outward along them.
	// Each set fades to its mean where its cycles fall below a pixel.
	float cyc = fq / (6.2831853 * max(length(q), 1e-3));
	float f1 = mix(0.5, 0.5 + 0.5 * sin(ang * 47.0 + 2.6 * sn_noise(vec3(ca * 4.0, seed + dp * 1.5))),
		1.0 - smoothstep(0.3, 0.7, 47.0 * cyc));
	float f2 = mix(0.5, 0.5 + 0.5 * sin(ang * 113.0 + 4.0 * sn_noise(vec3(ca * 9.0, seed + 5.0))),
		1.0 - smoothstep(0.3, 0.7, 113.0 * cyc));
	float fil = f1 * 0.6 + f2 * 0.4;
	fil *= 0.72 + 0.28 * sin(dp * 34.0 - uTime * 1.3 + f2 * 5.0);
	return vec3(umb, pen, fil);
}

void fragment() {
	vec3 p = normalize(vObj);
	// One pixel on the unit surface, taken here where derivatives are defined.
	float pfw = length(fwidth(p));

	// The surface pattern turns at one rate. Granules and the network live far shorter
	// than the differential rotation takes to shear them, and at the display's rotation
	// rate a latitude-dependent one would comb them into zonal stripes within seconds.
	// The active regions keep Ω(lat) on the CPU.
	vec3 s = rotY(p, -uOmega * uTime);   // co-rotating surface coordinate

	vec3 V = normalize(-vVP);
	float mu = clamp(dot(normalize(vVN), V), 0.0, 1.0);
	float limb = 1.0 - mu;
	float conv = uConv;

	// --- GRAVITY DARKENING (von Zeipel 1924): T_eff ~ g^β, F ~ g^(4β), so the equator is
	// cooler and dimmer (Vega 10 260 K vs 8 610 K; Regulus 14 500 vs 11 000). β = ¼
	// radiative, ~0.08 convective (Lucy 1967), chosen on the CPU from Teff.
	float gDark = pow(max(vG, 1e-4), uGdBeta);            // T_local / T_pole
	float gFlux = pow(max(vG, 1e-4), 4.0 * uGdBeta);      // F_local / F_pole
	float gEqv  = pow(max(1.0 - 0.5 * uSpin * uSpin, 1e-4), uGdBeta);
	float tBlend = uSpin > 0.02
		? clamp((1.0 - gDark) / max(1.0 - gEqv, 1e-4), 0.0, 1.0) : 0.0;
	vec3 surfCol = mix(uColPole, uColEq, tBlend);
	float Tm = uSpin > 0.02 ? uTpole * gDark : uTeff;

	// --- GRANULATION at two scales: granules (a few pressure scale heights) over larger
	// cells. A supergiant is mostly the large cells (Freytag et al. 2002); on a dwarf they
	// are a faint mesogranular pattern. Each layer fades as it falls below a pixel.
	float giant = 1.0 - smoothstep(4.0, 20.0, uGranScale);
	vec3 gq = s * (uGranScale * 10.0);
	vec3 cq = s * uGranScale;
	float gAA = 1.0 - smoothstep(0.3, 0.75, length(fwidth(gq)));
	float cAA = 1.0 - smoothstep(0.3, 0.75, length(fwidth(cq)));
	float g = 0.0;
	if (conv > 0.0) {
		// Laned granules on a dwarf; on a giant the smaller structures riding on the cells
		// are soft-edged.
		if (gAA > 0.0) {
			float laned = giant < 1.0 ? sn_granule(sn_cells(gq, uTime * 0.15)) : 0.0;
			float soft = giant > 0.0 ? 1.8 * (2.0 * sn_fbm(gq * 0.6 + vec3(uTime * 0.01), 3) - 1.0) : 0.0;
			g += gAA * mix(laned, soft, giant);
		}
		// A dwarf's large cells carry no lanes of their own, only a soft brightness pattern.
		if (cAA > 0.0) {
			float soft = giant < 1.0 ? 2.0 * sn_fbm(cq * 0.7 + vec3(0.0, uTime * 0.01, 0.0), 3) - 1.0 : 0.0;
			float laned = giant > 0.0 ? sn_granule(sn_cells(cq, uTime * 0.03)) : 0.0;
			g += cAA * mix(soft, laned, giant);
		}
	}

	// --- ACTIVE REGIONS. Each is a bipolar group on Joy's law (leading spot equatorward,
	// tilted by half the latitude), surrounded by plage and faculae.
	float umb = 0.0, pen = 0.0, fil = 0.0, pore = 0.0, fac = 0.0, plage = 0.0, udot = 0.0, fibr = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= uSpotCount) break;
		vec4 sp = uSpots[i];
		float S = sp.w;
		vec3 c = sp.xyz;
		float rP = uSpotSize * (0.35 + 0.65 * S);
		if (S < 0.01 || distance(p, c) > rP * 12.0) continue;
		vec3 lead = normalize(cross(c, vec3(0.0, 1.0, 0.0)) + vec3(0.0, 0.0, 1e-5));
		vec3 north = cross(lead, c);
		float tilt = 0.5 * asin(clamp(c.y, -1.0, 1.0));
		vec3 ax = lead * cos(tilt) - north * sin(tilt);
		vec3 perp = cross(c, ax);
		float seed = float(i) * 7.31;
		vec3 rel = p - c;
		vec2 q = vec2(dot(rel, ax), dot(rel, perp)) / rP;
		vec3 vd = normalize(vCam - c);
		float muc = max(dot(vd, c), 0.15);
		vec2 wil = vec2(dot(vd, ax), dot(vd, perp)) * min(0.10 / muc, 0.45);

		vec3 L = spot_shade(q - vec2(1.05, 0.08), 1.0, wil, seed, 0.12, pfw / rP);
		vec3 F = spot_shade(q + vec2(1.30, -0.10), 0.45 + 0.30 * S, wil, seed + 3.1, 0.38, pfw / rP);
		float pA = max(L.y, F.y);
		umb = max(umb, max(L.x, F.x) * S);
		pen = max(pen, pA * min(S * 2.0, 1.0));
		fil = max(fil, (L.y > F.y ? L.z : F.z) * pA);
		udot = max(udot, smoothstep(0.80, 0.92, sn_noise(vec3(q * 15.0, seed + uTime * 0.05))) * max(L.x, F.x));

		// Pores and fragments scattered between and behind the two spots.
		float gd = length(q * vec2(0.42, 0.95));
		float pr = sn_noise(vec3(q * 10.0, seed + 9.0));
		pore = max(pore, smoothstep(0.84, 0.88, pr) * (1.0 - smoothstep(1.1, 1.7, gd)) * (1.0 - pA) * S);

		// Faculae hug the spots; plage spreads several spot radii, ragged at its edge.
		float fp = sn_fbm(vec3(q * 0.8, seed + 11.0), 3);
		fac = max(fac, (1.0 - smoothstep(0.9, 2.4 + 1.6 * fp, gd)) * (1.0 - pA) * S);
		float gp = length(q * vec2(0.55, 0.9));
		plage = max(plage, (1.0 - smoothstep(1.4, 3.0 + 3.0 * fp, gp)) * S);

		// Superpenumbral fibrils: chromospheric threads running radially out of each spot.
		vec2 qa = q - vec2(1.05, 0.08);
		float ra = length(qa);
		float fa = atan(qa.y, qa.x);
		float fstreak = sn_noise(vec3(cos(fa) * 9.0, sin(fa) * 9.0, ra * 1.2 - uTime * 0.04 + seed));
		fibr = max(fibr, pow(fstreak, 2.0) * smoothstep(0.9, 1.3, ra) * (1.0 - smoothstep(1.6, 3.4, ra)) * S);
	}
	umb *= conv; pen *= conv; pore *= conv; fac *= conv; plage *= conv; fibr *= conv;

	// --- the local temperature, and the continuum it radiates relative to the local mean
	float T = Tm;
	T = mix(T, Tm - uSpotDT * (0.38 - 0.26 * fil), pen);
	T = mix(T, Tm - uSpotDT * 0.75, pore);
	T = mix(T, Tm - uSpotDT * (1.0 - 0.45 * udot), umb);
	// Faculae are hot walls seen obliquely, so they show toward the limb.
	T += Tm * (0.055 * fac + 0.025 * plage) * pow(limb, 1.3);
	// A granule is a temperature too. Its measured contrast is the continuum's near 600 nm,
	// where d ln B / d ln T = x / (1 − e^−x), x = hc/λkT, so that intensity is a
	// temperature, and the bluer bands show it more, as they do. Granulation does not show
	// through the chromosphere's line emission.
	float x6 = 23510.0 / Tm;
	float gI = uGranContrast * g * (1.0 - pen) * (1.0 - pore) * (1.0 - 1.4 * uVeil * conv);
	T *= 1.0 + max(gI, -0.9) * (1.0 - exp(-x6)) / x6;
	vec3 base = surfCol * (uGain * uDisc * uPulse * gFlux) * sn_planck_ratio(T, Tm);

	// --- limb darkening: I(μ)/I(1) = 1 − a(1 − μ) − b(1 − μ)², μ = cos(view angle)
	base *= max(vec3(1.0) - uLimbA * limb - uLimbB * limb * limb, vec3(0.0));

	// --- the two flare ribbons straddling a sheared, meandering neutral line. They are
	// 10⁴ K continuum, coloured by its Planck ratio to the photosphere (normalised in red,
	// where the drawn strength is set), so a flare is bluer than the star it is on.
	vec3 ribT = sn_planck_ratio(1.0e4, Tm);
	ribT /= ribT.r;
	vec3 flareGlow = vec3(0.0);
	float ribbon = 0.0;
	for (int i = 0; i < 4; i++) {
		if (i >= uFlareCount) break;
		vec4 fl = uFlares[i];
		vec4 fx = uFlareAxis[i];
		vec3 rel = p - fl.xyz;
		if (length(rel) > 0.6) continue;
		float across = dot(rel, fx.xyz);
		float along  = dot(rel, cross(fl.xyz, fx.xyz));
		float sep = fx.w;
		float fi = float(i) * 3.7;
		float w = 0.008 + 0.06 * sep;
		float bendA = sep * (0.40 * sin(along * 12.0 + fi) + 0.18 * sin(along * 31.0 + 2.0 * fi));
		float bendB = sep * (0.40 * sin(along * 12.0 + fi + 0.7) + 0.18 * sin(along * 27.0 + fi));
		float ra = (across - sep - bendA) / w;
		float rb = (across + sep - bendB) / w;
		// The ribbons are offset along the line by the shear, and lumpy with kernels.
		float mA = 1.0 - smoothstep(0.10, 0.26, abs(along - 0.04));
		float mB = 1.0 - smoothstep(0.10, 0.26, abs(along + 0.04));
		float kA = 0.30 + 1.9 * pow(sn_noise(vec3(along * 60.0, 1.0, uTime * 0.8 + fi)), 3.0);
		float kB = 0.30 + 1.9 * pow(sn_noise(vec3(along * 60.0, 7.0, uTime * 0.8 + fi)), 3.0);
		float rib = exp(-ra * ra) * mA * kA + exp(-rb * rb) * mB * kB;
		float hx = across / (sep * 1.7 + 0.03);
		float halo = exp(-hx * hx) * (1.0 - smoothstep(0.06, 0.32, abs(along)));
		flareGlow += surfCol * ribT * (rib * 3.4 + halo * 0.35) * fl.w;
		ribbon = max(ribbon, rib * fl.w);
	}
	base += flareGlow * uGain;

	// --- THE CHROMOSPHERE: line emission from 10⁴ K gas over the network (supergranule
	// boundaries, where convection sweeps the field), brightest in plage. Optically thin,
	// so it brightens toward the limb as the path through the layer lengthens.
	if (uChromo > 0.0) {
		vec3 nq = s * max(uGranScale * 0.45, 2.5);
		float nAA = 1.0 - smoothstep(0.25, 0.7, length(fwidth(nq * 3.3)));
		float fAA = 1.0 - smoothstep(0.25, 0.7, length(fwidth(nq * 9.0)));
		vec3 w1 = vec3(sn_fbm(nq * 1.1 + vec3(0.0, 0.0, uTime * 0.004), 3),
		               sn_fbm(nq * 1.1 + vec3(5.2, 1.3, 7.7), 3),
		               sn_fbm(nq * 1.1 + vec3(2.7, 8.1, 3.3), 3)) - 0.5;
		vec2 cn = sn_cells(nq + w1 * 1.9, uTime * 0.01);
		float e = cn.y - cn.x;
		float edge = exp(-e * e / 0.05);
		// Bright clumps (rosettes, mottles) strung along the network, and the fibrils that
		// fan out of them across the cells.
		float m = mix(0.5, sn_fbm(nq * 3.3 + w1 * 3.0 + vec3(uTime * 0.006), 4), nAA);
		float clump = smoothstep(0.32, 0.78, m);
		float fb = 1.0 - abs(2.0 * sn_noise(nq * 6.5 + w1 * 6.0 + vec3(0.0, uTime * 0.01, 0.0)) - 1.0);
		fb = mix(0.3, fb * fb * fb, nAA);
		float fine = mix(0.5, sn_noise(nq * 13.0 + w1 * 8.0), fAA);
		float ch = 0.24 + 0.30 * m + edge * (0.15 + 2.5 * clump * clump) + 0.65 * fb * (0.25 + edge) * (0.4 + m);
		ch *= 0.75 + 0.5 * fine;
		// Quiet regions, enhanced network and the dim coronal-hole floor vary over tens of
		// supergranules.
		ch *= 0.55 + 0.9 * sn_fbm(s * 1.7 + vec3(3.0, 1.0, uTime * 0.002), 3);
		ch += plage * (0.9 + 5.5 * m * m * m + 1.4 * fb) + fibr * 1.6;
		// Spots and pores are dark in the line too; over a penumbra the emission is combed
		// into its filaments.
		ch *= mix(1.0, 0.25 + 0.5 * fil, pen) * (1.0 - 0.97 * umb) * (1.0 - 0.7 * pore);
		float path = min(1.0 / max(mu, 0.05), 7.0);
		// In the line the layer is partly opaque and veils the continuum under it, as an
		// H-α image does.
		base *= 1.0 - uVeil * conv;
		base += uChromoCol * (uChromo * uGain * ch * path * conv);
	}

	// Publish the local temperature: spots are cool and ribbons hot outside the visible,
	// and a fast rotator's pole is ~1500 K hotter in UV.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		float tPub = mix(T, 1.0e4, clamp(ribbon, 0.0, 1.0));
		ALBEDO = vec3(temp_code(tPub), 0.0, 0.0);
	} else {
		ALBEDO = base;
	}
}
