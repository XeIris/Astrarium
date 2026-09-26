// ============================================================================
// SOLID SURFACE — the port of sim/rocky_visual.js's surfaceMaterial. Used by
// every solid world (sim/rocky_visual.gd) and by the climate model's home
// world (sim/world.gd). See sim/rocky_visual.gd for what drives each uniform.
//
// THE VERTEX STAGE never forms an absolute world position. The web build
// wrote projection * modelView * p because modelViewMatrix was assembled on
// the CPU in float64 and carried the CAMERA-relative offset; here the camera
// sits at the render origin (PORT_GUIDE.md §3, floating origin), so
// MODEL_MATRIX's translation IS that camera-relative offset and the world
// position formed from it is small whenever the body is close enough to see.
// The world-space view vector is therefore just minus that position.
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_opaque;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain.gdshaderinc"

uniform float uSeed = 0.0;
// Height of the sea-level datum, in km. Raising it floods the world;
// -60 is "there is no liquid at all", which is how an airless or a
// boiled-dry body is expressed rather than by a second code path.
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
// Mission imagery (sim/planetmaps.gd). The colour map is sRGB and decoded, as
// THREE's SRGBColorSpace texture was; the land mask is data and is not.
// Clamped rather than repeated: THREE repeated in u and clamped in v, and a
// repeat in v would bleed the south pole into the north one in the small mips.
// The seam needs no wrap — the mesh duplicates its vertices there.
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
		// A body with no air and no plate tectonics has no orogeny either:
		// its relief IS its impact record, so the tectonic terrain is faded
		// out as the crater record is faded in.
		float ch = craters(p, uSeed, uCrater, fresh);
		hKm = mix(hKm, hKm * 0.30 + ch, clamp(uCrater, 0.0, 1.0));
		rug = mix(rug, clamp(abs(ch) * 0.8, 0.0, 1.0), clamp(uCrater, 0.0, 1.0));
	}
	// uSeaKm is a LEVEL, not an offset applied to the ground. Subtracting
	// it from the terrain was the same arithmetic and a different physical
	// claim: a dry world expresses itself by putting sea level 60 km down,
	// and the lapse rate then read that as 60 km of altitude and took
	// 390 K off the surface — which froze Mars solid under CO2 at an
	// equilibrium temperature of 213 K. Altitude is measured from the
	// geoid; where the sea is, is a separate question.
	float sinLat = clamp(p.y, -1.0, 1.0);
	float lat = asin(sinLat);
	float a = abs(lat);
	bool sea = hKm < uSeaKm;
	if (uMapKind > 0.5 && uMapKind < 1.5)
		sea = texture(uLandMask, vMapUv).r < 0.5 && uSeaKm > -2.0;

	// --- temperature, and therefore everything else
	float T = surfaceTemp(sinLat, max(hKm, 0.0), uS2) + uSeason * sinLat * uDecl;

	// --- how wet. Continental interiors are dry because the water fell on
	// the way in; lee slopes are dry because it fell on the way over. The
	// upwind probe is the coarse crust only — what casts a rain shadow is
	// the massif, not the scree on it — and the wind reverses at the
	// trade/westerly boundary near 30 degrees, which is why the wet side
	// of a continent swaps hemisphere by hemisphere.
	//
	// BOTH SIDES OF THE DIFFERENCE ARE THE SAME FIELD. Subtracting the full
	// hKm from the coarse probe does not measure a slope at all: the fine
	// octaves (+-0.9 km) and the tectonic belt (up to 7 km) exist on only
	// one side of it, so the result is the local detail with its sign
	// flipped — speckle on flat ground, and a mountain belt that reads as
	// the WETTEST place on the planet rather than the driest lee.
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
		// The continental shelf is only ~130 m deep and is the brightest
		// water on the planet — it is why coastlines are turquoise from
		// orbit and why the shape of a continent reads larger than its land.
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
			// NASA's deep ocean is intentionally almost black in the source
			// composite. Restore the measured blue-water reflectance while
			// retaining its shallow-water color and mapped coastline.
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

	// --- volatiles. Everything freezes out below its own condensation
	// point: water at 273, CO2 at 148, nitrogen at 63. A permanent cap
	// needs no precipitation (an ice sheet is the accumulation of ages);
	// a seasonal snowpack does.
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
	// An energy-balance model, where there is one, owns the ice line: its
	// glaciated fraction is a state variable with a feedback on it, and the
	// picture has to agree with the number the model is integrating.
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
		// The sea is not blue because water is blue. It is blue because it
		// is a mirror lying under a Rayleigh-scattering sky, and at grazing
		// incidence its Fresnel reflectance approaches 1 — which is why the
		// ocean brightens toward the limb and toward the terminator.
		float fres = pow(1.0 - max(dot(N, V), 0.0), 5.0);
		lit += sc * (1.0 - rough) * mix(0.02, 0.35, fres) * diff * uHaze;
		skylight += sc * diff;
	}
	lit += albedo * uAmbient;

	// --- aerial perspective. An atmosphere is between you and the ground,
	// and it scatters blue out of the line of sight, so the limb of a world
	// with air is hazier and bluer than its centre. Without this term a
	// planet with an atmosphere still reads as a bare rock with a ring
	// painted round it.
	float limb = pow(1.0 - abs(dot(N, V)), 2.2);
	lit = mix(lit, lit * 0.75 + skylight * vec3(0.20, 0.34, 0.62) * 0.45, uHaze * limb);

	// --- incandescent once it is truly scorching
	lit += vec3(1.0, 0.28, 0.06) * pow(uScorch, 2.0) * 0.9;

	// Publish the surface temperature, log-encoded, so the spectral imaging
	// pass can re-image the planet in its own thermal band rather than
	// guessing a temperature from the colour of its rocks. A 288 K world is
	// a 10 micron source, and that is exactly what the infrared band should
	// show it as. (The web build wrote it into alpha; here it is the
	// temperature pass, PORT_GUIDE.md §6 — an opaque emitter.)
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(T), 0.0, 0.0);
	} else {
		ALBEDO = lit;
	}
}
