// SOLID SURFACE, for every solid world (sim/rocky_visual.gd, which explains the
// uniforms) and the climate model's home world (sim/world.gd). The camera sits at
// the render origin, so MODEL_MATRIX's translation is camera-relative and the
// world-space view vector is minus the world position.
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain.gdshaderinc"

uniform float uSeed = 0.0;
// Sea-level datum height, km. −60 means no liquid (airless or boiled dry).
uniform float uSeaKm = 0.0;
uniform float uIce = 0.0;        // glaciated fraction FORCED by an EBM, if any
uniform float uScorch = 0.0;
// Annual-mean insolation's second Legendre coefficient. See insolation_s2.
uniform float uS2 = -0.477;
uniform float uFrostK = 273.0;
uniform float uBiota = 0.0;
uniform float uCrater = 0.0;
uniform vec3 uRegolith = vec3(0.258, 0.216, 0.176);
uniform float uHaze = 0.0;
uniform vec3 uAmbient = vec3(0.0021, 0.0033, 0.0070);
uniform float uTime = 0.0;
// Exposure — see rocky_visual.gd: a constant, shared by every body, so two
// worlds side by side stay comparable.
uniform float uGain = 1.95;
// Seasons: uDecl is the sine of the sub-solar latitude, uSeason how far the
// surface follows it (kelvin of swing between the poles).
uniform float uSeason = 8.0;
uniform float uDecl = 0.0;
uniform float uMapKind = 0.0;  // 0 procedural, 1 Earth land/water, 2 dry mission mosaic
uniform float uMapScale = 1.0;
// Mission imagery (sim/planetmaps.gd): colour is sRGB, the land mask is data.
// Clamped (a repeat in v bleeds pole to pole in small mips); the mesh duplicates the
// seam vertices.
uniform sampler2D uColorMap : source_color, hint_default_black, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D uLandMask : hint_default_black, filter_linear_mipmap, repeat_disable;

varying vec3 vObj;
varying vec3 vWN;
varying vec3 vView;
varying vec2 vMapUv;

void vertex() {
	vObj = normalize(VERTEX);
	vMapUv = UV;
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 p = normalize(vObj);

	// --- relief
	float hKm = 0.0;
	float rug = 0.0;
	if (uMapKind < 0.5) terrain(p, uSeed, hKm, rug);
	float fresh = 0.0;
	if (uMapKind < 0.5 && uCrater > 0.002) {
		// With no air and no tectonics, relief is the impact record: tectonic terrain fades
		// out as craters fade in.
		float ch = craters(p, uSeed, uCrater, fresh);
		hKm = mix(hKm, hKm * 0.30 + ch, clamp(uCrater, 0.0, 1.0));
		rug = mix(rug, clamp(abs(ch) * 0.8, 0.0, 1.0), clamp(uCrater, 0.0, 1.0));
	}
	// uSeaKm is a level, not an offset: altitude is from the geoid, or a dry world's
	// −60 km sea would read as 60 km of altitude for the lapse rate.
	float sinLat = clamp(p.y, -1.0, 1.0);
	float lat = asin(sinLat);
	float a = abs(lat);
	bool sea = hKm < uSeaKm;
	if (uMapKind > 0.5 && uMapKind < 1.5)
		sea = texture(uLandMask, vMapUv).r < 0.5 && uSeaKm > -2.0;

	// --- temperature, and therefore everything else
	float T = surfaceTemp(sinLat, max(hKm, 0.0), uS2) + uSeason * sinLat * uDecl;

	// --- how wet. Interiors are dry (rain fell on the way in), lee slopes are dry. The
	// upwind probe is coarse crust only, and the wind reverses near 30°. Both sides of
	// the difference must be the same (coarse) field, or fine detail and belts read as
	// wet.
	float P = 0.0;
	if (uMapKind < 0.5) {
		float inland = sstep(uSeaKm + 0.05, uSeaKm + 1.4, hKm);
		vec3 east = normalize(cross(vec3(0.0, 1.0, 0.0), p) + 1e-6);
		vec3 probe = normalize(p + east * (a < 0.52 ? -0.04 : 0.04));
		float shadow = clamp((crustHeight(probe, uSeed) - crustHeight(p, uSeed)) * 0.6, 0.0, 1.0);
		P = precipitation(lat, T, inland, shadow);
	}

	// --- albedo
	vec3 albedo;
	float rough;
	if (sea) {
		float depth = clamp((uSeaKm - hKm) / max(uOceanDepth, 0.5), 0.0, 1.0);
		// The ~130 m continental shelf: the brightest water, turquoise from orbit.
		vec3 shelf = vec3(0.06, 0.26, 0.31);
		vec3 abyss = vec3(0.014, 0.050, 0.135);
		albedo = mix(shelf, abyss, sstep(0.02, 0.30, depth));
		rough = 0.06;
	} else {
		// Bare ground: the body's own regolith, mottled.
		vec3 rock = uRegolith * (0.72 + 0.55 * fbm(p * 9.0 + vec3(uSeed), 4));
		// Mare basalt: a flooded impact basin is darker and flatter than the
		// highlands around it, which is the Moon's entire two-tone face.
		float mare = uCrater * sstep(0.56, 0.74, fbm(p * 1.7 + vec3(uSeed + 13.0), 4));
		rock = mix(rock, rock * 0.42, mare);
		// and the bright ray systems of the craters young enough to still
		// have them
		rock = mix(rock, rock * 1.7, uCrater * fresh * 0.45);
		albedo = mix(rock, biome(T, P, rug), uBiota);
		rough = mix(0.95, 0.6, rug);
	}
	if (uMapKind > 0.5) {
		vec3 mapped = texture(uColorMap, vMapUv).rgb;
		if (uMapKind < 1.5) {
			// The source composite's deep ocean is near black; restore measured blue-water
			// reflectance, keeping shallow colour and the mapped coast.
			float land = texture(uLandMask, vMapUv).r;
			vec3 deep = vec3(0.018, 0.060, 0.155);
			float shelf = sstep(0.025, 0.13, mapped.g);
			vec3 water = mix(deep, max(mapped * 0.8, deep), shelf);
			float wet = sstep(-5.0, -2.0, uSeaKm);
			vec3 dryBed = vec3(0.15, 0.14, 0.12) * (0.8 + mapped.g * 1.4);
			albedo = mix(mix(dryBed, mapped, land), mix(water, mapped, land), wet);
			rough = mix(0.9, mix(0.06, 0.88, land), wet);
		} else {
			albedo = mapped * uMapScale;
			rough = 0.92;
		}
	}

	// --- volatiles, each freezing out below its own condensation point (uFrostK). A
	// permanent cap needs no precipitation; seasonal snow does.
	float frost = 0.0;
	if (uMapKind < 0.5) {
		float perm = sstep(uFrostK - 5.0, uFrostK - 17.0, T);
		float snow = sstep(uFrostK + 4.0, uFrostK - 5.0, T) * sstep(0.03, 0.28, P);
		float seaIce = sea ? sstep(uFrostK + 0.5, uFrostK - 4.0, T) : 0.0;
		frost = clamp(max(max(perm, snow), seaIce), 0.0, 1.0);
	} else if (uMapKind < 1.5) {
		// The July image already has Greenland and Antarctica. Additional
		// glaciation appears only if the simulated Earth actually cools.
		float cold = 1.0 - sstep(245.0, 280.0, uMeanK);
		frost = cold * sstep(0.72 - 0.56 * cold, 0.92 - 0.35 * cold, abs(sinLat));
	}
	// Where an energy-balance model runs, its ice fraction owns the ice line.
	if (uIce > (uMapKind > 0.5 ? 0.15 : 0.001)) {
		float capEdge = 1.0 - uIce * 1.05;
		float jitter = (fbm(p * 3.0 + 11.0, 3) - 0.5) * 0.16;
		frost = max(frost, sstep(capEdge - 0.10, capEdge + 0.06, abs(sinLat) + jitter)
		                   * sstep(0.02, 0.18, uIce));
	}
	// ragged edge — an ice margin is a coastline, not a parallel
	if (frost > 0.0)
		frost = clamp(frost + (fbm(p * 7.0 + 31.0, 4) - 0.5) * 0.35, 0.0, 1.0);
	albedo = mix(albedo, vec3(0.82, 0.87, 0.93), frost);
	rough = mix(rough, 0.62, frost);

	// --- a world baking dry
	albedo = mix(albedo, vec3(0.55, 0.42, 0.26), clamp(uScorch * 1.6, 0.0, 0.85));

	// --- lighting, from every star at once
	vec3 N = normalize(vWN);
	vec3 V = normalize(vView);
	vec3 lit = vec3(0.0);
	vec3 skylight = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		float ndl = dot(N, L);
		// A star is a disc, not a point, so the terminator has a width.
		float diff = sstep(-0.08, 0.22, ndl);
		vec3 sc = uSunColor[i] * uSunInt[i];
		lit += albedo * sc * diff * uGain;
		// specular — sun glint off water and off ice, and off nothing else
		vec3 H = normalize(L + V);
		float spec = pow(max(dot(N, H), 0.0), mix(240.0, 20.0, rough)) * (1.0 - rough);
		lit += sc * spec * 0.30 * step(0.0, ndl);
		// The sea reflects the sky with Fresnel reflectance near 1 at grazing incidence, so
		// it brightens toward the limb and terminator.
		float fres = pow(1.0 - max(dot(N, V), 0.0), 5.0);
		lit += sc * (1.0 - rough) * mix(0.02, 0.35, fres) * diff * uHaze;
		skylight += sc * diff;
	}
	lit += albedo * uAmbient;

	// --- aerial perspective: bluer, hazier limbs on a world with air.
	float limb = pow(1.0 - abs(dot(N, V)), 2.2);
	lit = mix(lit, lit * 0.75 + skylight * vec3(0.20, 0.34, 0.62) * 0.45, uHaze * limb);

	// --- incandescent once it is truly scorching
	lit += vec3(1.0, 0.28, 0.06) * pow(uScorch, 2.0) * 0.9;

	// Publish the surface temperature to the temperature pass (a 288 K world is a 10 µm
	// source in the IR band).
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(T), 0.0, 0.0);
	} else {
		ALBEDO = lit;
	}
}
