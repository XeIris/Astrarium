// THE PHOTOSPHERE (physics in sim/star_visual.gd's header).
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);   // unused
uniform vec3 uHot = vec3(1.0);
uniform float uPulse = 1.0;
uniform float uLimbU = 0.6;
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
// Just past 1.0 — see sim/star_visual.gd for why the disc sits ON the tone
// curve's shoulder rather than beyond it.
uniform float uGain = 1.0;
uniform float uGranScale = 9.0;
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
	VERTEX = p;
	NORMAL = n;
}

float hsh(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hsh(i),                   hsh(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(hsh(i + vec3(0.0, 1.0, 0.0)), hsh(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hsh(i + vec3(0.0, 0.0, 1.0)), hsh(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(hsh(i + vec3(0.0, 1.0, 1.0)), hsh(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm(vec3 p0) {
	vec3 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.07; a *= 0.5; }
	return v;
}

// rotate a point about the Y axis
vec3 rotY(vec3 p, float a) { float c = cos(a), s = sin(a); return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z); }

void fragment() {
	vec3 p = normalize(vObj);

	// --- differential rotation: Ω(lat) = Ω_eq (1 − 0.19 sin²lat), as on the Sun.
	float sinLat = clamp(p.y, -1.0, 1.0);
	float omega  = uOmega * (1.0 - 0.19 * sinLat * sinLat);
	vec3  s      = rotY(p, -omega * uTime);   // co-rotating surface coordinate

	// --- granulation: bright granule tops and dark intergranular lanes. The lanes come
	// from the ridge trick: |n − ½| near zero is a thin connected network.
	float nA = fbm(s * uGranScale + vec3(0.0, uTime * 0.05, 0.0));
	float nB = fbm(s * (uGranScale * 2.7) - vec3(uTime * 0.09));

	float laneA = 1.0 - smoothstep(0.0, 0.075, abs(nA - 0.5));
	float laneB = 1.0 - smoothstep(0.0, 0.055, abs(nB - 0.5));
	float lanes = clamp(laneA * 0.75 + laneB * 0.55, 0.0, 1.0);

	// granule interiors: bright, with a slight dome from centre to rim
	float cellA = smoothstep(0.42, 0.72, nA);
	float cellB = smoothstep(0.44, 0.70, nB);

	// Contrast is deliberately small. Real granulation is only ~15–20%
	// peak-to-peak; crank it and you get a golf ball.
	float bright = 0.88 + cellA * 0.19 + cellB * 0.10 - lanes * 0.30;

	// --- starspots: dark umbra, warm penumbra with radial filaments,
	// bright faculae ring
	float spotMask = 0.0, penumbra = 0.0, facula = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= uSpotCount) break;
		vec4 sp = uSpots[i];
		float d = distance(p, sp.xyz);                 // chord distance on unit sphere
		float rad = 0.10 + 0.26 * sp.w;
		// ragged edge so spots aren't perfect discs
		float wob = (fbm(p * 14.0 + float(i) * 5.0) - 0.5) * 0.10;
		float u = 1.0 - smoothstep(rad * 0.42, rad + wob, d); // 1 in the umbra
		spotMask = max(spotMask, u * sp.w);

		// Penumbral filaments: the near-horizontal field combs the gas into radial threads.
		float ring = (1.0 - smoothstep(rad * 0.85, rad * 1.35, d)) * (1.0 - u);
		vec3  rel  = normalize(p - sp.xyz * dot(p, sp.xyz) + vec3(1e-5));
		float comb = 0.5 + 0.5 * sin(dot(rel, normalize(cross(sp.xyz, vec3(0.0, 1.0, 0.001)))) * 90.0
		                             + fbm(p * 30.0) * 6.0);
		penumbra = max(penumbra, ring * sp.w * (0.45 + comb * 0.55));

		facula   = max(facula, (1.0 - smoothstep(rad, rad * 1.55, d)) * (1.0 - u) * sp.w);
	}
	bright *= mix(1.0, 0.20, spotMask);
	bright *= mix(1.0, 0.62, penumbra);
	bright += facula * 0.35;

	// --- the two flare ribbons straddling the neutral line
	vec3 flareGlow = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uFlareCount) break;
		vec4 fl = uFlares[i];
		vec4 fx = uFlareAxis[i];
		vec3 rel = p - fl.xyz;
		float across = dot(rel, fx.xyz);                          // across the line
		float along  = dot(rel, cross(fl.xyz, fx.xyz));           // along it
		// Two strips at ±sep along the neutral line; sep grows as reconnection climbs, so
		// the ribbons draw apart. Squared directly: pow() is undefined for the negative base
		// between the ribbons.
		float rd = (abs(across) - fx.w) / 0.055;
		float rb = exp(-rd * rd);
		rb *= 1.0 - smoothstep(0.14, 0.30, abs(along));
		rb *= 1.0 - smoothstep(0.30, 0.50, length(rel));
		// filamentary kernels inside each ribbon
		float fil = 0.5 + 0.5 * fbm(p * 30.0 + uTime * 3.0);
		flareGlow += vec3(1.0, 0.93, 0.85) * rb * fil * fl.w * 3.4;
	}

	// The disc mean stays near 1.0 so the tone curve resolves granulation and spots;
	// hot granule cores and faculae punch past it into the bloom.
	// --- GRAVITY DARKENING (von Zeipel 1924): T_eff ~ g^β, F ~ g^(4β), so the equator is
	// cooler and dimmer (Vega 10 260 K vs 8 610 K; Regulus 14 500 vs 11 000). β = ¼
	// radiative, ~0.08 convective (Lucy 1967), chosen on the CPU from Teff.
	float gDark = pow(max(vG, 1e-4), uGdBeta);            // T_local / T_pole
	float gFlux = pow(max(vG, 1e-4), 4.0 * uGdBeta);      // F_local / F_pole
	// Endpoint colours are true blackbody colours for pole and equator; g is monotonic
	// between them, so it is also the blend coordinate.
	float gEqv  = pow(max(1.0 - 0.5 * uSpin * uSpin, 1e-4), uGdBeta);
	float tBlend = uSpin > 0.02
		? clamp((1.0 - gDark) / max(1.0 - gEqv, 1e-4), 0.0, 1.0) : 0.0;
	vec3 surfCol = mix(uColPole, uColEq, tBlend);

	vec3 base = surfCol * bright * uPulse * uGain * gFlux;
	// hot granule cores read as the star's own hotter continuum
	base += uHot * pow(max(nB - 0.60, 0.0), 2.0) * 5.5 * uGain * gFlux;
	base += flareGlow * uGain;

	// --- limb darkening: I(mu)/I(0) = 1 - u(1 - mu), mu = cos(view angle)
	vec3 V = normalize(-vVP);
	float mu = clamp(dot(normalize(vVN), V), 0.0, 1.0);
	base *= (1.0 - uLimbU * (1.0 - mu));

	// --- chromosphere: H-alpha reddening right at the limb
	float rim = pow(1.0 - mu, 3.0);
	base += vec3(1.0, 0.28, 0.16) * rim * 0.85 * uGain;

	// Publish the local temperature, not the mean: a fast rotator's pole is ~1500 K
	// hotter, visible in UV.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		float tLocal = uSpin > 0.02 ? uTpole * gDark : uTeff;
		ALBEDO = vec3(temp_code(tLocal), 0.0, 0.0);
	} else {
		ALBEDO = base;
	}
}
