// ============================================================================
// TERRAIN & SURFACE CLIMATE — the shared GLSL that decides what a solid world
// LOOKS like, from the two things that actually decide it on a real planet:
// where its crust is thick, and how much sunlight and rain each patch gets.
// (Port of sim/terrain.js's GLSL strings; sim/terrain.gd holds the JS half.)
// ----------------------------------------------------------------------------
// The old rocky planet was a canvas of fBm run through a colour ramp. That is
// a texture, not a model, and it shows: the elevation histogram of plain fBm is
// a single hump centred on the mean, so a sea-level cut through it gives
// smooth, rounded, contour-like coasts everywhere, and the colour, being a
// function of height alone, puts the same vegetation at the equator and at
// 70 degrees. Nothing in the picture is a consequence of anything.
//
// Three mechanisms replace it, and between them they are most of what you
// recognise when you look at a photograph of the Earth:
//
//   1. ISOSTASY, which is why coastlines are sharp.
//      Continental crust is ~35 km of low-density granitic rock; oceanic crust
//      is ~7 km of dense basalt. Both float on the mantle, so the continents
//      ride about 4.5 km higher, and Earth's hypsometric curve is BIMODAL —
//      two peaks, one at roughly +0.8 km (continental platform) and one at
//      -4 km (abyssal plain), with very little area in between. That gap is
//      the continental slope, and it is why a coastline is a sharp, fractal,
//      dendritic boundary rather than a soft contour: sea level lands in the
//      empty part of the histogram, where the surface is STEEP. Reproducing
//      the bimodality is a one-line transfer function on the noise, and it is
//      the single biggest difference between this and a height-ramped fBm.
//
//   2. PLATE TECTONICS, which is why mountains come in LINES.
//      Relief is not scattered at random over the crust; it is concentrated at
//      plate boundaries, and which kind of relief depends on whether the
//      plates are converging or separating. A cellular (Worley) partition of
//      the sphere gives the plates; each is given a velocity, and the sign of
//      the closing rate across a boundary selects the outcome — a mountain
//      belt where two continents collide, a trench with a volcanic arc just
//      inboard of it where ocean goes under land, a mid-ocean ridge where two
//      oceanic plates separate.
//
//   3. THE GENERAL CIRCULATION, which is why deserts come in BELTS.
//      Air rises at the equator, dries, and descends near 30 degrees; that
//      descending branch of the Hadley cell is the Sahara, Arabia, the Kalahari,
//      the Atacama and the Australian interior, all at the same latitude on
//      different continents. It rises again at the polar front near 55 degrees
//      (the storm tracks, and the world's temperate forests) and descends at
//      the pole (Antarctica is a desert). Combine that with the Clausius–
//      Clapeyron scaling of how much water air can hold, and precipitation
//      falls out as a function of latitude and temperature. Colour then comes
//      from a Whittaker diagram — biome as a function of mean temperature and
//      annual precipitation — rather than from height.
//
// Everything below is pure shader code. It supplies terrain for invented
// worlds and unmapped Solar System bodies in both sim/world.gd and
// sim/rocky_visual.gd. Named Earth, Mars and Moon use mission imagery for
// their geography instead (sim/planetmaps.gd).
//
// Include order is the web build's TERRAIN_GLSL: NOISE + PLATE + ELEVATION +
// COARSE + CRATER + CLIMATE. The uniforms declared here are fed by
// Terrain.terrain_uniforms() (sim/terrain.gd).
// ============================================================================
#ifndef TERRAIN_INC
#define TERRAIN_INC

#include "res://shaders/bodies/terrain_noise.gdshaderinc"

// ----------------------------------------------------------------------------
// PLATES. A Worley partition of the sphere: jitter one feature point per cell
// of a 3D lattice and find the two nearest. F1 names the plate you are on, F2
// the one across the nearest boundary, and F2 - F1 is (twice) the distance to
// that boundary — zero on it, growing inward. Each plate gets a velocity from
// its own hash, projected into the tangent plane, and the closing rate along
// the line joining the two feature points says what kind of boundary it is.
// ----------------------------------------------------------------------------
// c1/c2 come back as the two nearest feature POINTS; d1/d2 their distances.
void plateField(vec3 p, out float d1, out float d2, out vec3 c1, out vec3 c2) {
	vec3 ip = floor(p);
	vec3 fp = fract(p);
	d1 = 8.0; d2 = 8.0; c1 = p; c2 = p;
	for (int k = -1; k <= 1; k++) for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
		vec3 g = vec3(float(i), float(j), float(k));
		vec3 cell = ip + g;
		vec3 f = g + hash33(cell) - fp;
		float d = dot(f, f);
		if (d < d1) { d2 = d1; c2 = c1; d1 = d; c1 = cell + hash33(cell); }
		else if (d < d2) { d2 = d; c2 = cell + hash33(cell); }
	}
	d1 = sqrt(d1); d2 = sqrt(d2);
}
// A plate's drift, tangent to the sphere at p.
vec3 plateVel(vec3 cell, vec3 p) {
	vec3 v = hash33(cell + 5.17) * 2.0 - 1.0;
	return normalize(v - p * dot(v, p) + 1e-5);
}

// ----------------------------------------------------------------------------
// ELEVATION. Returns height in KILOMETRES relative to the datum, so the lapse
// rate below is a real 6.5 K/km and a trench is really 10 km deep. `rug` comes
// back as a 0..1 ruggedness used for shading and for the rain shadow.
// ----------------------------------------------------------------------------
uniform float uPlateScale = 2.6;    // plates across the sphere (Earth: ~3)
uniform float uLandRelief = 3.2;    // km from datum to the highest continent
uniform float uOceanDepth = 4.6;    // km from datum to the abyssal plain
uniform float uCrustT = 0.54;       // the fBm level that IS sea level (see terrain_uniforms)

void terrain(vec3 p, float seed, out float hKm, out float rug) {
	vec3 q = warp(p * 1.9 + vec3(seed), 0.55);

	// --- crust thickness. One warped fBm, recentred on the level that makes
	// the requested fraction of the surface continental. The threshold is NOT
	// 1 - landFraction: summed-octave fBm is very nearly Gaussian (measured:
	// mean 0.497, sd 0.1065 over seven octaves), so asking for 32% land by
	// subtracting 0.68 leaves 8% of the surface above the datum. The GDScript
	// side inverts the normal CDF instead — see Terrain.crust_threshold —
	// which is why Earth here has Earth's land fraction rather than a third
	// of it.
	float c = fbm(q, 7) - uCrustT;

	// --- ISOSTASY: push the distribution AWAY from the datum. pow() with an
	// exponent below 1 expands values near zero outward and compresses the
	// tails, turning one hump into two and leaving the continental slope
	// nearly empty. This is the line that makes coastlines sharp.
	float s = sign(c);
	float y = s * pow(min(abs(c) / 0.34, 1.0), 0.55);

	// Continents are rough; the abyssal plain is famously flat (it is buried
	// under kilometres of pelagic sediment), so the two sides get different
	// relief and different detail amplitudes.
	hKm = (y >= 0.0) ? y * uLandRelief : y * uOceanDepth;
	float detailAmp = (y >= 0.0) ? 0.9 : 0.25;
	float fine = (fbm(q * 5.3 + 3.1, 5) - 0.5) * 2.0;
	hKm += fine * detailAmp;

	// --- TECTONICS
	float d1; float d2; vec3 c1; vec3 c2;
	plateField(p * uPlateScale + vec3(seed * 0.7), d1, d2, c1, c2);
	float edge = (d2 - d1);                          // 0 on the boundary
	float onEdge = 1.0 - sstep(0.0, 0.42, edge);
	// Which way the boundary faces, and how fast the two sides close on it.
	vec3 dir = normalize(c2 - c1 + 1e-5);
	float closing = dot(plateVel(c1, p) - plateVel(c2, p), dir);
	float land = sstep(-0.2, 0.6, hKm);

	// Convergent: a ridged belt, tall where two continents meet (the Himalaya
	// is 8 km because neither side will subduct), lower as a volcanic arc
	// where ocean goes under land.
	float belt = ridged(warp(p * 7.0 + vec3(seed), 0.2), 5);
	belt = pow(clamp(belt, 0.0, 1.0), 1.6);
	float conv = max(closing, 0.0) * onEdge;
	hKm += belt * conv * mix(2.2, 7.0, land);
	// and the trench that goes with subduction, just OUTBOARD of the arc
	float trench = sstep(0.06, 0.0, edge) * conv * (1.0 - land);
	hKm -= trench * 5.0;

	// Divergent: a mid-ocean ridge — a broad swell of young, hot, buoyant
	// crust with a rift valley along its crest.
	float div = max(-closing, 0.0) * onEdge * (1.0 - land);
	hKm += div * (1.6 - 1.1 * sstep(0.10, 0.0, edge));

	rug = clamp(belt * conv * 1.6 + abs(fine) * 0.4, 0.0, 1.0);
}

// ----------------------------------------------------------------------------
// A CHEAP crust probe — warp + isostasy only, no plates and no fine detail.
// The rain-shadow test needs to know how high the ground is UPWIND, and
// evaluating the full terrain a second time per fragment to find out is not
// worth it: what casts a shadow is the massif, not the scree on it.
// ----------------------------------------------------------------------------
float crustHeight(vec3 p, float seed) {
	vec3 q = warp(p * 1.9 + vec3(seed), 0.55);
	float c = fbm(q, 5) - uCrustT;
	float y = sign(c) * pow(min(abs(c) / 0.34, 1.0), 0.55);
	return (y >= 0.0) ? y * uLandRelief : y * uOceanDepth;
}

// ----------------------------------------------------------------------------
// CRATERS. On a body with no atmosphere and no plate tectonics, nothing erases
// an impact: the Moon's surface is a four-billion-year integral of everything
// that ever hit it, and the size distribution is a power law, so every big
// crater is pocked with smaller ones. That is the whole look, and it is not
// something fBm produces — a crater is a DISC with a rim, not a bump.
//
// One layer scatters at most one impact per lattice cell, each with its own
// radius, and draws the real profile: a parabolic bowl inside the rim, an
// uplifted rim at the radius itself, and an ejecta blanket fading outside it.
// Three layers an octave apart give the power law.
// ----------------------------------------------------------------------------
float craterLayer(vec3 p, float seed) {
	vec3 ip = floor(p);
	vec3 fp = fract(p);
	float h = 0.0;
	for (int k = -1; k <= 1; k++) for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
		vec3 g = vec3(float(i), float(j), float(k));
		vec3 r = hash33(ip + g + seed);
		if (r.z > 0.55) continue;                 // not every cell is hit
		float d = length(g + r - fp);
		float rad = 0.18 + 0.26 * r.z;
		float t = d / rad;
		if (t > 2.0) continue;
		float bowl = (t < 1.0) ? -(1.0 - t * t) * 0.85 : 0.0;
		float dr = (t - 1.0) * 3.4;
		float de = (t - 1.45) * 2.0;   // negative inside
		float rim  = exp(-dr * dr) * 0.55;
		float ej   = exp(-de * de) * 0.10;
		h += bowl + rim + ej;
	}
	return h;
}
// Kilometres of crater relief, plus a 0..1 "freshness" that bright ray
// systems and dark basin floors are keyed off.
float craters(vec3 p, float seed, float density, out float fresh) {
	float h = craterLayer(p * 7.0  + vec3(seed), seed)
	        + craterLayer(p * 15.0 + vec3(seed + 3.0), seed + 3.0) * 0.5
	        + craterLayer(p * 31.0 + vec3(seed + 7.0), seed + 7.0) * 0.25;
	fresh = clamp(h * 0.9, 0.0, 1.0);
	return h * 1.6 * density;
}

// ----------------------------------------------------------------------------
// SURFACE CLIMATE. Temperature from the annual-mean insolation distribution,
// precipitation from the cells of the general circulation, colour from the two
// together.
// ----------------------------------------------------------------------------
uniform float uMeanK = 288.0;      // global mean surface temperature, K
uniform float uTransport = 0.42;   // 0 = radiative equilibrium, 1 = isothermal planet
uniform float uArid = 0.0;         // 0..1 global dryness (a world with little water)

// Annual-mean insolation vs latitude, the standard form used by every 1-D
// energy-balance model since Budyko and Sellers:
//     S(phi)/Sbar = 1 + s2 * P2(sin phi),   P2(x) = (3x^2 - 1)/2
// s2 = -0.482 for Earth's 23.4 degree obliquity; a world tipped further over
// has a flatter profile, and past 54 degrees s2 changes SIGN and the poles
// become the hottest part of the planet.
float insolation(float sinLat, float s2) {
	float P2 = 0.5 * (3.0 * sinLat * sinLat - 1.0);
	return max(1.0 + s2 * P2, 0.02);
}

// Surface temperature: the radiative-equilibrium gradient T ~ S^(1/4),
// relaxed toward the global mean by however much heat the atmosphere and
// ocean move poleward, then a dry-ish 6.5 K/km lapse rate with altitude.
float surfaceTemp(float sinLat, float hKm, float s2) {
	float f = pow(insolation(sinLat, s2), 0.25);
	float T = uMeanK * mix(f, 1.0, uTransport);
	return T - 6.5 * max(hKm, 0.0);
}

// Precipitation, 0..1, from the three overturning cells plus Clausius-
// Clapeyron: saturation vapour pressure rises about 7% per kelvin, so warm
// air carries far more water and a cold desert is as dry as a hot one.
// The coefficients are fitted to Earth's annual-mean zonal precipitation:
// a maximum at the equator, a trough near 30 degrees that is DRY BUT NOT
// ZERO, a broad secondary maximum over the storm tracks at 45-60, and a
// polar desert. Getting the trough wrong is what puts a Sahara at the
// latitude of France.
float precipitation(float lat, float T, float inland, float shadow) {
	float a = abs(lat);
	// Squared directly rather than through pow(), which GLSL leaves
	// undefined for a negative base — both off-equator terms are negative on
	// the equatorward side of the cell they describe.
	float zi = a / 0.30;
	float zf = (a - 0.90) / 0.40;
	float zh = (a - 0.55) / 0.22;
	float itcz  = 0.75 * exp(-zi * zi);                      // rising, equator
	float front = 0.42 * exp(-zf * zf);                      // rising, ~52 deg
	float horse = 0.42 * exp(-zh * zh);                      // sinking, ~31 deg
	float polar = 0.45 * sstep(1.00, 1.45, a);               // sinking, pole
	float P = clamp(0.30 + itcz + front - horse - polar, 0.0, 1.0);
	P *= clamp(exp((T - 288.0) / 20.0), 0.05, 1.6);          // moisture capacity
	P *= mix(1.0, 0.45, inland);                             // continentality
	P *= mix(1.0, 0.45, shadow);                             // rain shadow
	return clamp(P * (1.0 - uArid), 0.0, 1.0);
}

// Whittaker's biome diagram: what grows somewhere is a function of mean
// temperature and annual precipitation, and almost nothing else. Read off
// as a 2-D blend rather than as a lookup so the boundaries are gradients,
// which is what they are on the ground.
// The values are ALBEDOS, not palette picks: sand really is around 0.38 and
// closed-canopy forest really is around 0.12, and it is that three-to-one
// ratio that makes a photograph of a continent look the way it does. Choose
// them by eye instead and the deserts come out the same brightness as the
// grassland, which is the single most obvious way a rendered planet stops
// looking like a planet.
vec3 biome(float T, float P, float rug) {
	float t = clamp((T - 258.0) / 48.0, 0.0, 1.0);   // -15 C .. +48 C
	vec3 desert  = mix(vec3(0.34, 0.30, 0.25), vec3(0.44, 0.35, 0.22), t); // cold->hot
	vec3 grass   = mix(vec3(0.21, 0.21, 0.14), vec3(0.28, 0.26, 0.13), t);
	vec3 forest  = mix(vec3(0.07, 0.11, 0.08), vec3(0.09, 0.17, 0.07), t); // boreal->temperate
	vec3 jungle  = vec3(0.05, 0.12, 0.05);
	vec3 tundra  = vec3(0.20, 0.19, 0.16);

	vec3 col = mix(desert, grass, sstep(0.07, 0.22, P));
	col = mix(col, forest,  sstep(0.22, 0.44, P));
	col = mix(col, jungle,  sstep(0.50, 0.75, P) * sstep(0.55, 0.80, t));
	// too cold for trees: the treeline, which is a temperature line
	col = mix(col, tundra, sstep(0.16, 0.02, t));
	// exposed rock where the ground is too steep to hold soil
	col = mix(col, vec3(0.23, 0.21, 0.20), sstep(0.45, 0.85, rug));
	return col;
}

#endif
