// THE GROUND PATCH: a radially tessellated disc, stretched with vertices crowding
// near the vehicle and dropped by y = −r²/2R (docs: localview.gd).
//
// Opaque: the rim fade is a 4×4 ordered dither, so every transparent emitter is
// depth-tested against it. Lit by hand for a Lambert BRDF, with the same 1/π and
// irradiance (uSunI) the vehicle's light gets.
//
// Tied to the planet, not the local frame: detail is sampled about uAnchor (a
// planet-fixed point, the pad when there is one), and cloud shadows march the cloud
// field (clouds.gdshaderinc) toward the sun from each ground point.
shader_type spatial;
render_mode unshaded, cull_disabled;

#include "res://shaders/flight/clouds.gdshaderinc"

uniform float uRadius = 6.371e6;    // planet radius, m
uniform float uPatch = 4e4;         // patch radius, m
uniform float uEye = 0.0;           // observer altitude, m
uniform vec3 uGround;
uniform vec3 uRock;
uniform vec3 uHaze;
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uSea;
uniform float uScaleH = 8500.0;
uniform float uDensity = 2.4e-5;
uniform float uHasAir = 1.0;
uniform float uSeaLevel = 0.42;
uniform float uOceans = 1.0;
uniform float uSunI = 3.0;
uniform float uSkyI = 0.35;
uniform float uTemp = 288.0;
uniform float uGeoReady = 0.0;
uniform mat3 uGeoFrame;
uniform vec2 uPadLocal;
uniform vec2 uAnchor = vec2(0.0);   // a planet-fixed point, in the local frame (x east, y north)
uniform float uHasPad = 0.0;
uniform vec3 uCamLocal = vec3(0.0);
// Cloud-shadow samples: 6 near the deck, fewer from altitude (set by localview.gd).
uniform int uShadowSteps = 6;
uniform sampler2D uEarthColor : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D uEarthLand : filter_linear_mipmap_anisotropic, repeat_enable;

varying float vDist;
varying vec3 vWorld;
varying float vDrop;
varying vec3 vLocal;

void vertex() {
	// The unit disc is stretched to the patch radius with a quadratic
	// distribution, so the vertices crowd where the detail is: near the vehicle.
	vec3 p = VERTEX;
	float u = length(p.xz);
	float r = uPatch * u * u;
	vec2 d = u > 1e-6 ? p.xz / u : vec2(0.0);
	// planetary curvature — the horizon drop
	float drop = (r * r) / (2.0 * uRadius);
	vec3 q = vec3(d.x * r, -drop, d.y * r);
	vDist = r; vWorld = q; vDrop = drop;
	// camera-relative world position, plus the camera: the point in the local frame
	vLocal = (MODEL_MATRIX * vec4(q, 1.0)).xyz + uCamLocal;
	VERTEX = q;
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(41.3, 289.1))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm(vec2 p) { float v = 0.0, a = 0.5; for (int i = 0; i < 5; i++) { v += a * noise(p); p *= 2.13; a *= 0.5; } return v; }

// LAND COVER round a coastal pad (Kennedy's is typical): mown lawn inside the
// perimeter, saw-palmetto scrub beyond, sandy tracks and dry patches, and wet
// hollows with standing water. Linear albedos of the right order (lawn ~0.13,
// scrub ~0.07, sand ~0.38). Returns the colour; `relief` is a height for shading.
vec3 land_cover(vec2 gp, float fp, float from_pad, out float relief, out float wet) {
	// Domain-warped so boundaries meander like vegetation, not like noise.
	vec2 w = gp + 60.0 * vec2(fbm(gp * 0.004 + 3.1), fbm(gp * 0.004 + 8.4)) - 30.0;
	float scrub = smoothstep(0.46, 0.58, fbm(w * 0.0021 + vec2(4.0, 1.0)));
	// The mown perimeter: everything near the pad is lawn.
	scrub *= smoothstep(380.0, 900.0, from_pad + (fbm(w * 0.01) - 0.5) * 220.0);
	float sand = smoothstep(0.6, 0.72, fbm(w * 0.006 + vec2(11.0, 5.0)));
	float dry = smoothstep(0.45, 0.7, fbm(w * 0.013 + vec2(2.0, 9.0)));
	wet = smoothstep(0.62, 0.72, fbm(w * 0.0016 + vec2(7.0, 13.0))) * (1.0 - sand);
	vec3 lawn = mix(vec3(0.115, 0.15, 0.055), vec3(0.2, 0.19, 0.095), dry * 0.7);
	vec3 brush = vec3(0.05, 0.075, 0.034);
	vec3 col = mix(lawn, brush, scrub);
	col = mix(col, vec3(0.4, 0.35, 0.25), sand * 0.85);
	col = mix(col, mix(vec3(0.05, 0.065, 0.045), vec3(0.025, 0.04, 0.05), smoothstep(0.75, 0.85, wet)), wet * 0.8);
	// Metres: tussocks and mower stripes on the lawn, crowns in the scrub, faded on
	// the pixel footprint.
	float k1 = 1.0 - smoothstep(1.5, 6.0, fp);
	float k2 = 1.0 - smoothstep(12.0, 50.0, fp);
	float tuft = fbm(gp * 0.7) - 0.5;
	float crown = fbm(gp * 0.12 + 40.0) - 0.5;
	float stripe = (step(0.5, fract(dot(gp, vec2(0.6, 0.8)) / 9.0)) - 0.5) * (1.0 - scrub) * (1.0 - sand);
	col *= 1.0 + tuft * 0.35 * k1 + crown * mix(0.25, 0.7, scrub) * k2 + stripe * 0.06 * k2;
	relief = fbm(gp * 0.008) * 3.0 + crown * 1.4 * scrub;
	return col;
}

// A 4x4 ordered dither, built by the recursion that defines a Bayer matrix —
// M(2n) = 4·M(n) tiled plus M(2) — rather than by looking one up.
float b2(vec2 p) { p = mod(p, 2.0); return mod(2.0 * p.y + 3.0 * p.x, 4.0); }
float bayer4(vec2 c) {
	vec2 p = floor(mod(c, 4.0));
	return (b2(floor(p * 0.5)) * 4.0 + b2(p)) / 16.0;
}

void fragment() {
	// Two rock tones and a fine grain that fades past a few km.
	vec2 gp = vWorld.xz - uAnchor;     // planet-fixed: see the header
	float big = fbm(gp * 0.00008);
	// Raise the land under the pad: pads are on coasts (range safety), water a few km out.
	big += 0.40 * exp(-length(gp) / 7000.0) * uHasPad;
	// Three detail scales, each fading where it would alias. The mid octave is what the
	// eye reads the climb rate against.
	float mid = fbm(gp * 0.0011);
	float fine = fbm(gp * 0.02);
	float midK = exp(-vDist / 9000.0);
	float fineK = exp(-vDist / 900.0);
	vec3 col = mix(uRock, uGround, clamp(big * 1.5 - 0.15, 0.0, 1.0));
	col *= 0.72 + 0.30 * mix(0.5, mid, midK) + 0.34 * mix(0.5, fine, fineK);
	// Procedural seas only where there is no map.
	float water_frac = 0.0;
	if (uGeoReady < 0.5 && uOceans > 0.5 && big < uSeaLevel) {
		float dep = smoothstep(uSeaLevel, uSeaLevel - 0.18, big);
		col = mix(col, uSea, dep * 0.92);
		water_frac = dep;
	}
	float relief = 0.0;
	if (uGeoReady > 0.5) {
		// The ground patch is a tangent sheet. Convert each point back to a
		// direction on the real sphere, then into the NASA map's lat/lon frame.
		vec3 geo = normalize(uGeoFrame * normalize(vec3(vWorld.x, vWorld.y + uRadius, vWorld.z)));
		vec2 mapUv = vec2(fract(atan(geo.z, geo.x) / 6.2831853 + 0.5),
		                  asin(clamp(geo.y, -1.0, 1.0)) / 3.14159265 + 0.5);
		// three samples with flipY: v = 0 is the image's BOTTOM row
		mapUv.y = 1.0 - mapUv.y;
		vec3 mapped = texture(uEarthColor, mapUv).rgb;
		float mask = texture(uEarthLand, mapUv).r;
		// The map is 10 km a texel. Detail is added only where the map is magnified and
		// averages back to it, faded on the pixel footprint (fwidth).
		float fp = length(fwidth(gp));                              // metres per pixel here
		float texel = length(fwidth(mapUv * vec2(4096.0, 2048.0))); // map texels per pixel
		// COASTS: the mask's half-way contour, pushed a texel's worth by fractal noise and
		// cut as sharply as the pixel allows.
		float wig = (fbm(gp * (1.0 / 2600.0) + vec2(3.1, 7.7)) - 0.5) * 0.55
			+ (fbm(gp * (1.0 / 420.0) + vec2(9.2, 1.3)) - 0.5) * 0.30 * (1.0 - smoothstep(60.0, 300.0, fp));
		float k = clamp(texel * 0.5, 0.035, 0.5);
		float land = smoothstep(0.5 - k, 0.5 + k, mask + wig * (1.0 - smoothstep(0.6, 2.0, texel)));
		// Keep the actual reclaimed/graded launch parcel above water.
		land = max(land, 1.0 - smoothstep(700.0, 1800.0, distance(vWorld.xz, uPadLocal)));
		// LAND: the map's colour broken up below a texel (brightness and dryness at two
		// scales), faded by footprint.
		float k2 = 1.0 - smoothstep(350.0, 1600.0, fp);
		float k3 = 1.0 - smoothstep(40.0, 220.0, fp);
		float d1 = fbm(gp * (1.0 / 9000.0) + vec2(5.3, 2.9));
		float d2 = fbm(gp * (1.0 / 1300.0) + vec2(1.7, 8.1));
		float d3 = fbm(gp * (1.0 / 170.0) + vec2(6.6, 4.4));
		float lum = 1.0 + 0.30 * (d1 - 0.5) + 0.42 * (d2 - 0.5) * k2 + 0.30 * (d3 - 0.5) * k3;
		float dry = smoothstep(0.52, 0.74, fbm(gp * (1.0 / 3800.0) + vec2(12.0, 3.0)));
		float wood = smoothstep(0.50, 0.72, fbm(gp * (1.0 / 1900.0) + vec2(2.0, 19.0))) * k2;
		vec3 landCol = mapped * lum;
		landCol = mix(landCol, landCol * vec3(1.18, 1.06, 0.80) + vec3(0.015, 0.012, 0.0), dry * 0.55);
		landCol = mix(landCol, landCol * vec3(0.72, 0.84, 0.66), wood * 0.6);
		// Within a few kilometres of the pad, land cover at a scale the map knows
		// nothing about takes over (land_cover).
		float from_pad = distance(vWorld.xz, uPadLocal);
		float parcel = (1.0 - smoothstep(1800.0, 5200.0, from_pad)) * uHasPad;
		if (parcel > 0.0) {
			float wetc;
			vec3 cover = land_cover(gp, fp, from_pad, relief, wetc);
			landCol = mix(landCol, cover, parcel * 0.92);
			relief *= parcel;
		}
		// WATER: the map's own shallows (the Bahamas banks are in it), with a
		// little large-scale variation so open ocean is not one flat colour.
		vec3 water = max(mapped * 0.8, uSea * 0.8) * (0.92 + 0.16 * d1);
		col = mix(water, landCol, land);
		water_frac = 1.0 - land;
	}

	// Lambert with the vehicle's 1/π; uSkyI is the diffuse skylight (the only light on
	// the night side, and why the terminator is soft).
	const float INV_PI = 0.3183099;
	float ndl = clamp(uSunDir.y, -0.2, 1.0);
	// CLOUD SHADOW: the layer's optical depth along the sun line, six samples between
	// base and top. Diffuse sun and skylight still arrive under it.
	float shade = 1.0;
	if (uCloudCoverage > 0.0 && uSunDir.y > 0.02) {
		vec2 tb = cloud_sphere(vLocal, uSunDir, uCloudBase);
		vec2 tt = cloud_sphere(vLocal, uSunDir, uCloudTop);
		float a0 = max(tb.y, 0.0);
		float a1 = tt.y;
		float ds = (a1 - a0) / float(uShadowSteps);
		float od = 0.0;
		for (int i = 0; i < 6; i++) {
			if (i >= uShadowSteps) break;
			od += cloud_density(vLocal + uSunDir * (a0 + (float(i) + 0.5) * ds), false) * ds;
		}
		// direct beam, or what diffuses through (two-stream, as the cloud pass)
		shade = max(exp(-od), 1.0 / (1.0 + 0.11 * od));
	}
	// Relief: the land cover's height tilts the normal a little, so low sun picks out
	// the scrub's crowns and the ground's swells.
	// (Derivatives taken in uniform control flow.)
	vec2 rg = vec2(dFdx(relief), dFdy(relief));
	vec3 dpx = dFdx(vWorld), dpy = dFdy(vWorld);
	float lit_k = 1.0;
	if (relief != 0.0) {
		vec3 n = normalize(cross(dpy + vec3(0.0, rg.y, 0.0), dpx + vec3(0.0, rg.x, 0.0)));
		n *= sign(n.y);
		lit_k = clamp(dot(n, uSunDir) / max(uSunDir.y, 0.15), 0.4, 1.6);
	}
	col *= INV_PI * (uSunI * max(ndl, 0.0) * shade * lit_k + uSkyI * (0.35 + 0.65 * clamp(uSunDir.y + 0.25, 0.0, 1.0)));

	// SUN GLINT: a GGX lobe with Cox & Munk's σ² ≈ 0.04 (~7 m/s wind).
	vec3 to_eye = uCamLocal - vLocal;
	float eye_dist = length(to_eye);
	vec3 V = to_eye / max(eye_dist, 1e-3);
	vec3 Nrm = normalize(vec3(vWorld.x, vWorld.y + uRadius, vWorld.z));
	if (water_frac > 0.0 && ndl > 0.0) {
		vec3 Hh = normalize(V + uSunDir);
		float nh = max(dot(Nrm, Hh), 0.0);
		float nv = max(dot(Nrm, V), 1e-3);
		float a2 = 0.04;
		float dd = nh * nh * (a2 - 1.0) + 1.0;
		float D = a2 / (3.14159265 * dd * dd);
		float F = 0.02 + 0.98 * pow(1.0 - max(dot(V, Hh), 0.0), 5.0);
		col += vec3(1.0, 0.96, 0.9) * water_frac * F * D / (4.0 * nv) * uSunI * shade;
	}

	// AERIAL PERSPECTIVE along the actual path. A straight path from the ground to
	// height h through an exponential atmosphere has mean density H·(1 − e^(−h/H))/h, so
	// from altitude the depth is the column spread over the slant (thin straight down,
	// thick at the limb). uDensity is calibrated on the pad's horizontal haze (mostly
	// boundary-layer aerosol), so a downward path is weighted toward its ~0.1 Rayleigh
	// depth, and its in-scatter is dimmer than the horizon's.
	float tau = 0.0;
	float cosz = max(dot(Nrm, V), 0.0);
	float up_high = smoothstep(2000.0, 20000.0, uEye);
	if (uHasAir > 0.5) {
		float dh = max(uEye, 1.0);
		float mean_rho = uScaleH * (1.0 - exp(-dh / uScaleH)) / dh;
		tau = uDensity * max(eye_dist, vDist) * mean_rho * mix(1.0, 0.45, up_high);
	}
	float fog = 1.0 - exp(-tau);
	vec3 haze = uHaze * (0.35 + 0.75 * max(ndl, 0.0)) * mix(1.0, 0.4, up_high * smoothstep(0.1, 0.6, cosz));
	col = mix(col, haze, clamp(fog, 0.0, 1.0));

	// The patch has to end somewhere; fade it out rather than showing an edge —
	// DITHERED, not blended, because this surface is OPAQUE.
	float edge = 1.0 - smoothstep(0.86, 1.0, vDist / uPatch);
	if (edge <= 0.002) discard;
	if (edge < 1.0 && edge < bayer4(FRAGCOORD.xy)) discard;
	ALBEDO = col;
}
