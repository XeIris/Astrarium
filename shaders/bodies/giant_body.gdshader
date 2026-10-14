// GAS GIANT CLOUD DECK (module notes in sim/giant_visual.gd). Opaque and an
// emitter: it publishes the planet's effective temperature (absorbed sunlight plus
// internal heat).
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
// A measured map (PlanetMaps): east longitude across, north up, equal steps of
// planetocentric latitude. It replaces the bands below |lat| = uMapPole.
uniform sampler2D uMap : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform float uMapOn = 0.0;
uniform float uMapPole = 1.32;

// The zonal wind profile, shared with GDScript (which drifts the vortices), so a
// spot travels at its jet's speed.
uniform float uJets = 11.0;      // jets per radian of latitude
uniform float uJetAmp = 0.55;    // amplitude of the alternating jets
uniform float uEqJet = 1.0;      // equatorial superrotation (Saturn's is enormous)

// Jets go as cos(θ) and vertical motion as sin(θ): a quarter cycle apart, as the
// belt/zone boundaries are.
float jetPhase(float lat) { return uJets * lat; }

float zonalWind(float lat) {
	float a = abs(lat);
	// equatorial jet, then the alternating mid-latitude system, damped out
	// toward the poles where the banded regime breaks down entirely
	float env = exp(-pow(a / 1.05, 4.0));
	return uEqJet * exp(-pow(a / 0.24, 2.0)) + uJetAmp * cos(jetPhase(lat)) * env;
}

// Angular rate carries 1/cos(φ): u is linear speed along the latitude circle.
float zonalOmega(float lat) {
	return zonalWind(lat) / max(cos(lat), 0.15);
}

vec3 rotY(vec3 p, float a) {
	float c = cos(a);
	float s = sin(a);
	return vec3(c * p.x - s * p.z, p.y, s * p.x + c * p.z);
}
// Rodrigues rotation, to spin the coordinate inside a vortex.
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

// Turbulence stretched along the flow (2.5×, not 4) with low octave counts: with no
// mip chain, sub-pixel octaves alias into horizontal moiré.
float zonalTurb(vec3 q, float s, int oct) {
	return fbm(vec3(q.x, q.y * 2.5, q.z) * s + vec3(uSeed), oct);
}
// The flow map: two copies of the field, half a period out of step.
float turb(vec3 qa, vec3 qb, float w, float s, int oct) {
	return mix(zonalTurb(qb, s, oct), zonalTurb(qa, s, oct), w);
}

// The map's own colour, with turbulence finer than its ~120 km texels. The map
// is a snapshot, so it turns rigidly with System III: real jets move it by under
// a degree in a day, and flow-mapping a photograph cross-fades it into mush.
// Called in uniform control flow: it takes derivatives.
vec3 mapped(vec3 p, float lat) {
	float lon = atan(-p.z, p.x);
	vec2 uv = vec2(fract(lon / 6.2831853 + 0.5), 0.5 - lat / 3.14159265);
	// The wrap at ±180° would jump the mip level; take u's gradient from whichever
	// of two seam positions is far from here.
	float u2 = fract(lon / 6.2831853);
	vec2 gx = vec2(dFdx(uv.x), dFdx(uv.y)), gy = vec2(dFdy(uv.x), dFdy(uv.y));
	float ax = dFdx(u2), ay = dFdy(u2);
	if (abs(ax) < abs(gx.x)) gx.x = ax;
	if (abs(ay) < abs(gy.x)) gy.x = ay;
	vec3 c = textureGrad(uMap, uv, gx, gy).rgb;
	// Eddies sheared along the jets, faded as they approach a pixel (no mip chain).
	vec3 q = vec3(p.x, p.y * 3.0, p.z);
	float fw = length(fwidth(p));
	float k1 = 1.0 - sstep(0.002, 0.006, fw);
	float k2 = 1.0 - sstep(0.0008, 0.0024, fw);
	float d = (fbm(q * 260.0 + vec3(uSeed), 3) - 0.5) * 0.16 * k1
	        + (ridged(q * 720.0 + vec3(uSeed + 3.0), 2) - 0.5) * 0.10 * k2;
	return c * (1.0 + d);
}

void fragment() {
	vec3 p = normalize(vObj);
	float lat = asin(clamp(p.y, -1.0, 1.0));
	float a = abs(lat);
	float mapK = uMapOn * (1.0 - sstep(uMapPole - 0.08, uMapPole + 0.06, a));
	vec3 col = vec3(0.0);
	vec3 mc = vec3(0.0);
	if (uMapOn > 0.5) mc = mapped(p, lat);
	if (mapK < 0.999) {

	// --- ADVECTION, flow-mapped. Wind varies with latitude, so the longitude offset
	// between latitudes grows without bound, and a frozen field winds into moiré. So
	// two copies advect on clocks half a period apart and cross-fade, bounding the
	// winding by ω·period. 16 s keeps the filaments legible with jets a fifth of a
	// radian apart.
	float per = 16.0;
	float ta = mod(uTime, per);
	float tb = mod(uTime + per * 0.5, per);
	// Each copy's weight is zero when its clock wraps: w = 1 − |2t/T − 1|.
	float wx = 1.0 - abs(2.0 * ta / per - 1.0);

	float om = zonalOmega(lat);
	vec3 qa = rotY(p, -om * ta);
	vec3 qb = rotY(p, -om * tb);

	// --- vortices: each drifts with its own jet (GDScript advances its longitude), is
	// sheared into an oval, and spins the coordinate inside it.
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

	// --- belts and zones: sin of the jet phase. The wobble goes on the latitude, not the
	// result, so boundaries meander as jets do, with festoons. The displacement is a
	// fraction of the jet spacing (π/uJets), or it erases the band.
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

	col = mix(uBelt, uZone, band * 0.5 + 0.5);

	// --- optical depth of the main deck. Where it is thin you are looking
	// down into the warm deep layer; that is what a belt IS.
	float tau = turb(qa, qb, wx, 2.6, 5);
	float clear = sstep(0.62, 0.34, tau + band * 0.20);
	col = mix(col, uDeep, clear * 0.75);

	// --- filaments and festoons where the shear is (zone edges, not centres).
	float shear = 1.0 - abs(band);
	float fil = mix(ridged(vec3(qb.x, qb.y * 3.5, qb.z) * 3.0 + vec3(uSeed + 4.0), 3),
	                ridged(vec3(qa.x, qa.y * 3.5, qa.z) * 3.0 + vec3(uSeed + 4.0), 3), wx);
	col *= 1.0 + (fil - 0.55) * (0.22 + 0.55 * shear);

	// --- the high haze, thicker toward the poles (Saturn's grey-blue poles), advected
	// rigidly above the jets, so no flow map.
	float hz = zonalTurb(rotY(p, -uTime * 0.018), 1.6, 4);
	float hazeAmt = clamp(0.12 + 0.55 * polar + 0.25 * hz, 0.0, 0.85);
	col = mix(col, uHaze, hazeAmt * 0.6);

	// --- vortices on top of all of it
	col = mix(col, uZone, vortexCollar * 0.7);
	col = mix(col, vortexCol, vortexMask);
	}
	col = mix(col, mc, mapK);

	// --- lighting: no specular (no surface), strong limb darkening.
	vec3 N = normalize(vWN);
	vec3 Vv = normalize(vView);
	float mu = max(dot(N, Vv), 0.0);
	vec3 lit = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		float ndl = dot(N, L);
		float diff = sstep(-0.06, 0.20, ndl);
		// Near the limb the slant path never reaches the deck: only haze.
		float minn = mix(0.28, 1.0, pow(mu, 0.60));
		float sh = 1.0;
		if (uRingOut > 0.0) {
			// Ring shadow: if the line toward the star crosses the equatorial plane inside the
			// rings, the star is behind them.
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
	// Starlight only: the night side must stay as black as the sky it hides.
	lit += col * vec3(0.0015, 0.0017, 0.0022);

	// Internal heat (Jupiter emits 1.67× what it absorbs), so the IR band images it.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uTeff), 0.0, 0.0);
	} else {
		ALBEDO = lit;
	}
}
