// ============================================================================
// THE PHOTOSPHERE — port of photosphereMaterial() in sim/star_visual.js.
// The header of sim/star_visual.gd carries the physics; the comments below are
// the web shader's own, kept with the lines they explain.
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);   // kept for parity with the web uniform block; unused
uniform vec3 uHot = vec3(1.0);
uniform float uPulse = 1.0;
uniform float uLimbU = 0.6;
// physical Teff, published to the spectral imaging pass (the temperature pass)
uniform float uTeff = 5772.0;
uniform float uOmega = 1.0;
// Rotation. uSpin is Ω/Ω_crit — the ONE number that sets both the shape
// and the temperature map (see sim/structure.js). At 0 everything below
// collapses to the non-rotating case exactly.
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

// The Roche equipotential, R(theta)/R_pole, solved in closed form. See
// the derivation in sim/structure.js — this is the same function, and at
// u = 1 it returns exactly 1.5, the hard geometric limit on how flat a
// self-gravitating body can be.
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

	// Effective gravity at this point, in units of its polar value: the
	// Newtonian pull plus the centrifugal term, on the Roche surface.
	// With GM = 1 and R_pole = 1, Omega^2 = (8/27) uSpin^2.
	float om2 = 0.296296 * uSpin * uSpin;
	float gr  = -1.0 / (x * x) + om2 * x * sinT * sinT;
	float gt  = om2 * x * sinT * dir.y;
	vG = sqrt(gr * gr + gt * gt);           // exactly 1 at the pole

	// The surface normal of a radially stretched sphere is no longer
	// radial. Rather than carry the analytic gradient of the equipotential
	// through, tilt the radial normal toward the meridian by the same
	// ratio the gravity vector is tilted by — which is the gradient, since
	// the surface IS an equipotential and g is normal to it.
	vec3 er = dir;
	vec3 et = normalize(vec3(dir.x * dir.y, -sinT * sinT, dir.z * dir.y) + vec3(1e-6));
	vec3 n  = normalize(er * (-gr) + et * (-gt));

	// View space, not world space. In the web build that was the precision
	// decision (modelViewMatrix carries the camera-relative offset in float64);
	// here the floating origin makes world space camera-relative already, and
	// MODELVIEW_MATRIX is the same small-number product (PORT_GUIDE.md §3).
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

	// --- granulation.
	// A real photosphere is a packed mosaic of convective CELLS: bright,
	// roughly polygonal granule tops separated by narrow dark intergranular
	// lanes where the cooled gas sinks. Plain fBm cannot produce that — it
	// gives soft blobs, which is exactly what made the star read as a
	// fluffy cartoon sun. The lanes are recovered with the ridge trick:
	// the set where a noise field crosses its own mid-value is a thin
	// connected network, so |n − ½| near zero IS the lane pattern.
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

		// Penumbral filaments: the field is nearly horizontal in the
		// penumbra, so it combs the gas into radial threads pointing at the
		// umbra. It is the single most recognisable feature of a real spot.
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
		// Two strips at +-sep, each narrow, both running the length of the
		// neutral line. sep GROWS with the flare: the field that reconnects
		// gets higher and wider as the event proceeds, so its footpoints
		// land further out, and the ribbons visibly draw apart.
		// Squared directly, not through pow(): pow is undefined for a
		// negative base, and this base is negative everywhere BETWEEN the
		// two ribbons — i.e. over the whole arcade.
		float rd = (abs(across) - fx.w) / 0.055;
		float rb = exp(-rd * rd);
		rb *= 1.0 - smoothstep(0.14, 0.30, abs(along));
		rb *= 1.0 - smoothstep(0.30, 0.50, length(rel));
		// filamentary kernels inside each ribbon
		float fil = 0.5 + 0.5 * fbm(p * 30.0 + uTime * 3.0);
		flareGlow += vec3(1.0, 0.93, 0.85) * rb * fil * fl.w * 3.4;
	}

	// The disc itself is kept near 1.0 so the tone curve still has slope
	// left to resolve granulation and spots. What sells "blazing" is not a
	// brighter disc — it is the hot granule cores and faculae punching far
	// past 1.0 and lighting up the bloom pass, while the mean stays put.
	// --- GRAVITY DARKENING (von Zeipel 1924).
	// The rotating surface is an equipotential but not an equal-flux
	// surface: the radiative flux is proportional to the local effective
	// gravity, so T_eff ~ g^beta and F ~ g^(4 beta). The equator, further
	// out and centrifugally supported, is both cooler and dimmer than the
	// pole. On Vega that is 10 260 K against 8 610 K; on Regulus it is
	// 14 500 against 11 000, and both are directly measured.
	//
	// beta is 1/4 for a radiative envelope and ~0.08 for a convective one
	// (Lucy 1967) — the CPU side picks which, from Teff.
	float gDark = pow(max(vG, 1e-4), uGdBeta);            // T_local / T_pole
	float gFlux = pow(max(vG, 1e-4), 4.0 * uGdBeta);      // F_local / F_pole
	// The two endpoint colours are true blackbody colours for the pole and
	// equator temperatures, computed once on the CPU; g is monotonic
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

	// The temperature pass: the log-encoded true temperature for
	// sim/spectrum.gd. It is the LOCAL temperature, not the star's mean: on a
	// fast rotator the pole really is 1500 K hotter, and the imaging bands
	// should see that — flip to UV on Vega and the poles brighten while the
	// equator does not.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		float tLocal = uSpin > 0.02 ? uTpole * gDark : uTeff;
		ALBEDO = vec3(temp_code(tLocal), 0.0, 0.0);
	} else {
		ALBEDO = base;
	}
}
