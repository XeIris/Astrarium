// ============================================================================
// GAS GIANT CLOUD DECK — the port of sim/giant_visual.js's giantMaterial. The
// module header (why a giant does not turn as one object, the three optical
// levels, the unbanded poles) is in sim/giant_visual.gd.
//
// Opaque and an emitter: it publishes the planet's effective temperature
// (absorbed sunlight plus internal heat) to the temperature pass.
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain_noise.gdshaderinc"

uniform float uTime = 0.0;
uniform float uSeed = 0.0;
uniform float uContrast = 1.0;
uniform float uTeff = 124.0;
// ring shadow cast ONTO the planet: inner/outer radius in body radii, 0 = none
uniform float uRingIn = 0.0;
uniform float uRingOut = 0.0;
uniform vec3 uZone;
uniform vec3 uBelt;
uniform vec3 uDeep;
uniform vec3 uHaze;
// vortices: (sin lat, longitude, angular radius, strength)
uniform vec4 uVortex[6];
uniform vec3 uVortexCol[6];
uniform int uVortexN = 0;
// sun directions in the SPUN body's own frame, for the ring-shadow test
uniform vec3 uSunObj[4];

// ---------------------------------------------------------------------------
// The zonal wind profile, shared by the shader (which advects the cloud with
// it) and by GDScript (which drifts the vortices with it), so a spot always
// travels at the speed of the jet it is sitting in.
// ---------------------------------------------------------------------------
uniform float uJets = 11.0;      // jets per radian of latitude
uniform float uJetAmp = 0.55;    // amplitude of the alternating jets
uniform float uEqJet = 1.0;      // equatorial superrotation (Saturn's is enormous)

// Phase of the jet system. The jets go as cos(theta), the vertical motion as
// sin(theta): a quarter cycle apart, which is the observed relationship
// between the jets and the belt/zone boundaries they sit on.
float jetPhase(float lat) { return uJets * lat; }

float zonalWind(float lat) {
	float a = abs(lat);
	// equatorial jet, then the alternating mid-latitude system, damped out
	// toward the poles where the banded regime breaks down entirely
	float env = exp(-pow(a / 1.05, 4.0));
	return uEqJet * exp(-pow(a / 0.24, 2.0)) + uJetAmp * cos(jetPhase(lat)) * env;
}

// Angular drift rate. u is a LINEAR speed along a latitude circle, so the
// angular rate carries the 1/cos(phi) — which is why the high-latitude jets
// wrap the planet faster in longitude than their wind speed suggests.
float zonalOmega(float lat) {
	return zonalWind(lat) / max(cos(lat), 0.15);
}

vec3 rotY(vec3 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}
// Rodrigues — rotate p about an arbitrary unit axis. Used to spin the
// sampled coordinate inside a vortex, which is what turns a coloured oval
// into something with visible circulation in it.
vec3 rotAxis(vec3 p, vec3 axis, float a) {
	float c = cos(a);
	float s = sin(a);
	return p * c + cross(axis, p) * s + axis * dot(axis, p) * (1.0 - c);
}

varying vec3 vObj;
varying vec3 vWN;
varying vec3 vView;

void vertex() {
	// Camera-relative, never an absolute world coordinate (rocky_surface.gdshader).
	vObj = normalize(VERTEX);
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Turbulence sampled with more latitudinal than longitudinal frequency:
// a zonal flow stretches everything it carries along the direction it
// flows, so the eddies are long thin filaments, not blobs. The stretch
// is 2.5 rather than the 4 it wants to be, and the octave counts are
// low, for a reason that matters here: this is procedural noise with no
// mip chain, so an octave finer than a pixel does not add detail, it
// ALIASES — and on a banded planet it aliases into exactly the thing the
// bands are made of, a moire of horizontal stripes that moves with the
// camera. Detail that cannot be resolved is worse than no detail.
float zonalTurb(vec3 q, float s, int oct) {
	return fbm(vec3(q.x, q.y * 2.5, q.z) * s + vec3(uSeed), oct);
}
// The flow map: two copies of the field, half a period out of step.
float turb(vec3 qa, vec3 qb, float w, float s, int oct) {
	return mix(zonalTurb(qb, s, oct), zonalTurb(qa, s, oct), w);
}

void fragment() {
	vec3 p = normalize(vObj);
	float lat = asin(clamp(p.y, -1.0, 1.0));
	float a = abs(lat);

	// --- ADVECTION, and the one thing that has to be got right about it.
	//
	// The cloud is carried by the zonal wind, which is a function of
	// latitude, so the longitude offset between two adjacent latitudes
	// grows linearly and WITHOUT BOUND. Sample a frozen noise field at
	// that offset and after a few minutes the field's latitudinal
	// frequency has been wound up past a pixel and the planet dissolves
	// into moire — the shear is real, but a frozen field cannot express
	// arbitrarily much of it. A real atmosphere escapes this because its
	// eddies are continuously regenerated at their own scale, not stretched
	// for ever.
	//
	// So the field is regenerated too, by the standard flow-map device:
	// advect two copies whose clocks are half a period out of step, and
	// cross-fade between them so that whichever copy is being looked at is
	// always the one near the start of its wind-up. The winding is then
	// bounded by omega * period, the motion is continuous, and nothing
	// accumulates.
	// The period is what bounds the shear, so it is short: with jets a
	// fifth of a radian apart and an angular rate differing by a few per
	// radian across them, half a minute of winding already puts several
	// radians of phase between one side of a band and the other, which is
	// finer than the band. Sixteen seconds keeps the filaments legible.
	float per = 16.0;
	float ta = mod(uTime, per);
	float tb = mod(uTime + per * 0.5, per);
	// Each copy's weight falls to ZERO exactly when its own clock wraps,
	// so the reset is never visible and the worst winding ever shown is
	// half a period's worth.
	float wx = 1.0 - abs(2.0 * ta / per - 1.0);

	float om = zonalOmega(lat);
	vec3 qa = rotY(p, -om * ta);
	vec3 qb = rotY(p, -om * tb);

	// --- vortices. Each one drifts with its own jet (GDScript advances its
	// longitude), is stretched into an oval by the ambient shear, and spins
	// the coordinate inside it so the cloud there is visibly circulating.
	float vortexMask = 0.0;
	float vortexCollar = 0.0;
	vec3 vortexCol = uZone;
	for (int i = 0; i < 6; i++) {
		if (i >= uVortexN) break;
		vec4 V = uVortex[i];
		float vlat = asin(clamp(V.x, -1.0, 1.0));
		vec3 ctr = vec3(cos(vlat) * cos(V.y), V.x, cos(vlat) * sin(V.y));
		// distance in an anisotropic metric — 2.4:1, the aspect ratio the
		// shear holds a long-lived oval at
		vec3 d = p - ctr;
		float dy = d.y;
		float dxz = length(d - vec3(0.0, dy, 0.0));
		float r = sqrt(pow(dxz / 2.4, 2.0) + dy * dy) / max(V.z, 1e-3);
		if (r < 1.6) {
			float m = sstep(1.10, 0.30, r) * V.w;
			// a raised, brighter collar round the oval — the ring of cloud the
			// vortex has lifted is the part you actually see first
			vortexCollar = max(vortexCollar, sstep(1.30, 1.00, r) * sstep(0.75, 1.00, r) * V.w);
			// differential spin inside the oval: fastest at the collar
			float sp0 = (1.0 - sstep(0.0, 1.2, r)) * 0.55;
			qa = rotAxis(qa, ctr, sp0 * ta);
			qb = rotAxis(qb, ctr, sp0 * tb);
			vortexMask = max(vortexMask, m);
			vortexCol = uVortexCol[i];
		}
	}

	// --- belts and zones: sin of the jet phase, i.e. a quarter cycle out
	// of step with the jets themselves.
	//
	// The wobble goes on the LATITUDE, not on the result. A real band
	// boundary is a jet, and a jet meanders: it is displaced north and
	// south by the eddies it is shedding, so the boundary between a belt
	// and a zone is a train of interlocking scallops and festoons, and two
	// adjacent boundaries meander independently. Adding the noise to the
	// finished band value instead just mottles the stripes, which is what
	// a painted planet looks like.
	// The displacement is a fraction of the jet SPACING (pi/uJets): a
	// meander of order the spacing itself does not ripple the boundary, it
	// erases the band.
	float sp = 3.14159 / max(uJets, 1.0);
	float meander = (turb(qa, qb, wx, 1.5, 4) - 0.5) * sp * 0.55
	              + (turb(qa, qb, wx, 3.4, 3) - 0.5) * sp * 0.18;
	float band = sin(jetPhase(lat + meander));
	// a weaker, finer second system riding on the first
	band += 0.22 * sin(jetPhase(lat * 2.7 + meander * 1.8));
	band = clamp(band * uContrast * 1.6, -1.0, 1.0);

	// Poleward of about 60 degrees the banded regime is gone and the flow
	// is a crowd of cyclones instead.
	float polar = sstep(0.90, 1.25, a);
	float chaos = mix(ridged(qb * 4.5 + vec3(uSeed + 9.0), 3), ridged(qa * 4.5 + vec3(uSeed + 9.0), 3), wx);
	band = mix(band, (chaos - 0.55) * 2.0, polar);

	vec3 col = mix(uBelt, uZone, band * 0.5 + 0.5);

	// --- optical depth of the main deck. Where it is thin you are looking
	// down into the warm deep layer; that is what a belt IS.
	float tau = turb(qa, qb, wx, 2.6, 5);
	float clear = sstep(0.62, 0.34, tau + band * 0.20);
	col = mix(col, uDeep, clear * 0.75);

	// --- filaments and festoons, concentrated where the shear is: the
	// middle of a zone is bland and the boundary is a mess of streamers,
	// because that is where the velocity gradient is.
	float shear = 1.0 - abs(band);
	float fil = mix(ridged(vec3(qb.x, qb.y * 3.5, qb.z) * 3.0 + vec3(uSeed + 4.0), 3),
	                ridged(vec3(qa.x, qa.y * 3.5, qa.z) * 3.0 + vec3(uSeed + 4.0), 3), wx);
	col *= 1.0 + (fil - 0.55) * (0.22 + 0.55 * shear);

	// --- the high haze, which is thin at the equator and piles up over
	// the poles (it is why Saturn's poles are flat grey-blue). It is
	// advected RIGIDLY, at one rate for the whole planet: it sits above
	// the jets, it has almost no structure of its own, and a layer with no
	// shear in it needs no flow map.
	float hz = zonalTurb(rotY(p, -uTime * 0.018), 1.6, 4);
	float hazeAmt = clamp(0.12 + 0.55 * polar + 0.25 * hz, 0.0, 0.85);
	col = mix(col, uHaze, hazeAmt * 0.6);

	// --- vortices on top of all of it
	col = mix(col, uZone, vortexCollar * 0.7);
	col = mix(col, vortexCol, vortexMask);

	// --- lighting. A gas giant has no surface to be rough or smooth, so
	// there is no specular term at all; what it has instead is very strong
	// limb darkening, because near the limb you are looking through a long
	// slant path and seeing only the topmost, thinnest haze.
	vec3 N = normalize(vWN);
	vec3 Vv = normalize(vView);
	float mu = max(dot(N, Vv), 0.0);
	vec3 lit = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		float ndl = dot(N, L);
		float diff = sstep(-0.06, 0.20, ndl);
		// Limb darkening, and a lot of it: near the limb the line of sight
		// is a long slant path that never reaches the deck, so you see only
		// the thin haze above it. A giant fades to its edge.
		float minn = mix(0.28, 1.0, pow(mu, 0.60));
		float sh = 1.0;
		if (uRingOut > 0.0) {
			// Ring shadow. Walk from this point toward the star and see where
			// the line crosses the equatorial plane; if it crosses inside the
			// ring system, the star is behind the rings from here. It is the
			// single most recognisable thing about Saturn at low tilt.
			vec3 Lo = normalize(uSunObj[i]);
			if (abs(Lo.y) > 1e-3) {
				float t = -p.y / Lo.y;
				if (t > 0.0) {
					vec3 hit = p + Lo * t;
					float rr = length(vec2(hit.x, hit.z));
					if (rr > uRingIn && rr < uRingOut) {
						// the shadow carries the ring system's own optical depth,
						// so the Cassini division shows as a bright line across it
						float g = sstep(uRingIn, uRingIn + 0.04, rr) * sstep(uRingOut, uRingOut - 0.04, rr);
						float bandB = sstep(1.52, 1.56, rr) * sstep(1.96, 1.92, rr);   // B
						float bandA = 0.45 * sstep(2.02, 2.06, rr) * sstep(2.27, 2.24, rr);
						sh = 1.0 - 0.85 * g * clamp(0.25 + bandB + bandA, 0.0, 1.0);
					}
				}
			}
		}
		lit += col * uSunColor[i] * uSunInt[i] * diff * minn * sh;
	}
	lit += col * vec3(0.012, 0.014, 0.020);

	// A giant is warm from the inside: Jupiter radiates 1.67 times what it
	// absorbs, left over from contraction. Publishing that temperature is
	// what lets the infrared band image it as the source it is.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uTeff), 0.0, 0.0);
	} else {
		ALBEDO = lit;
	}
}
