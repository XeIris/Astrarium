// TERRAIN & SURFACE CLIMATE: what a solid world looks like, from where its crust is
// thick and how much sunlight and rain each patch gets. CPU half: sim/terrain.gd.
// Used for invented worlds and unmapped bodies (Earth, Mars and the Moon use imagery,
// sim/planetmaps.gd). Three mechanisms:
//
//   1. ISOSTASY: thick light continental crust rides ~4.5 km above thin dense
//      oceanic crust, so the hypsometric curve is bimodal (+0.8 km and −4 km) and
//      sea level lands on the steep, empty slope between: sharp coastlines.
//   2. PLATE TECTONICS: a Worley partition gives plates with velocities, and the
//      closing rate across a boundary picks the relief: collision belts, trenches
//      with volcanic arcs, mid-ocean ridges. Mountains come in lines.
//   3. THE GENERAL CIRCULATION: Hadley descent near 30° makes the desert belts,
//      the polar front near 55° the storm tracks, and the poles are dry. With
//      Clausius–Clapeyron, precipitation is a function of latitude and temperature,
//      and colour comes from a Whittaker diagram, not height.
//
// Include order: NOISE + PLATE + ELEVATION + COARSE + CRATER + CLIMATE. Uniforms are
// fed by Terrain.terrain_uniforms().
#ifndef TERRAIN_INC
#define TERRAIN_INC

#include "res://shaders/bodies/terrain_noise.gdshaderinc"

// PLATES: a Worley partition. F1 names your plate, F2 the one across the nearest
// boundary, F2 − F1 is twice the distance to it. Each plate's velocity (hashed,
// projected tangent) gives the closing rate. c1/c2 are the two nearest feature
// points; d1/d2 their distances.
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

// ELEVATION in km relative to the datum (the lapse rate is a real 6.5 K/km). `rug`
// is 0..1 ruggedness for shading and the rain shadow.
uniform float uPlateScale = 2.6;    // plates across the sphere (Earth: ~3)
uniform float uLandRelief = 3.2;    // km from datum to the highest continent
uniform float uOceanDepth = 4.6;    // km from datum to the abyssal plain
uniform float uCrustT = 0.54;       // the fBm level that IS sea level (see terrain_uniforms)

void terrain(vec3 p, float seed, out float hKm, out float rug) {
	vec3 q = warp(p * 1.9 + vec3(seed), 0.55);

	// --- crust thickness: warped fBm recentred so the requested fraction is
	// continental. The threshold is not 1 − landFraction: the fBm is near-Gaussian
	// (mean 0.497, sd 0.1065), so the CPU inverts the normal CDF (Terrain.crust_threshold).
	float c = fbm(q, 7) - uCrustT;

	// --- ISOSTASY: pow() with an exponent below 1 pushes values away from the datum,
	// making the distribution bimodal and the continental slope nearly empty.
	float s = sign(c);
	float y = s * pow(min(abs(c) / 0.34, 1.0), 0.55);

	// Continents are rough; the abyssal plain is flat under sediment.
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

	// Convergent: a ridged belt, tallest where continents meet, lower as a volcanic arc
	// where ocean subducts.
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

// A cheap crust probe (warp + isostasy only) for the upwind rain-shadow test.
float crustHeight(vec3 p, float seed) {
	vec3 q = warp(p * 1.9 + vec3(seed), 0.55);
	float c = fbm(q, 5) - uCrustT;
	float y = sign(c) * pow(min(abs(c) / 0.34, 1.0), 0.55);
	return (y >= 0.0) ? y * uLandRelief : y * uOceanDepth;
}

// CRATERS, where nothing erases them. At most one impact per lattice cell with its
// own radius: parabolic bowl, uplifted rim, fading ejecta. Three layers an octave
// apart give the power-law size distribution.
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

// SURFACE CLIMATE: temperature from annual-mean insolation, precipitation from the
// circulation cells, colour from both.
uniform float uMeanK = 288.0;      // global mean surface temperature, K
uniform float uTransport = 0.42;   // 0 = radiative equilibrium, 1 = isothermal planet
uniform float uArid = 0.0;         // 0..1 global dryness (a world with little water)

// Annual-mean insolation vs latitude (Budyko, Sellers):
//     S(φ)/S̄ = 1 + s2·P2(sin φ),  P2(x) = (3x² − 1)/2
// s2 = −0.482 at 23.4°; it changes sign past 54°, and the poles become hottest.
float insolation(float sinLat, float s2) {
	float P2 = 0.5 * (3.0 * sinLat * sinLat - 1.0);
	return max(1.0 + s2 * P2, 0.02);
}

// T ~ S^(1/4), relaxed toward the global mean by poleward heat transport, then a
// 6.5 K/km lapse rate.
float surfaceTemp(float sinLat, float hKm, float s2) {
	float f = pow(insolation(sinLat, s2), 0.25);
	float T = uMeanK * mix(f, 1.0, uTransport);
	return T - 6.5 * max(hKm, 0.0);
}

// Precipitation 0..1 from the three cells plus Clausius–Clapeyron (~7%/K), fitted to
// Earth's zonal mean: equatorial maximum, a dry-but-not-zero trough near 30°, a
// storm-track maximum at 45–60°, polar desert.
float precipitation(float lat, float T, float inland, float shadow) {
	float a = abs(lat);
	// Squared directly: pow() is undefined for a negative base.
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

// Whittaker biomes: vegetation as a 2-D blend of temperature and precipitation.
// The values are real albedos (sand ~0.38, forest ~0.12); that 3:1 ratio is what
// makes a continent read as one.
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
