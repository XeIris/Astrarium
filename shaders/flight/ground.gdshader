// ============================================================================
// THE GROUND PATCH — GROUND_VERT / GROUND_FRAG of sim/flight/localview.js.
// ----------------------------------------------------------------------------
// A radially tessellated unit disc, stretched to the patch radius with a
// quadratic distribution (the vertices crowd near the vehicle) and dropped by
// the planet's curvature, y = −r²/2R — a parabolic sheet rather than a piece of
// a sphere, which over a few hundred kilometres is identical to well under a
// metre and never puts 6.4e6 into a float32 vertex.
//
// OPAQUE, and it must stay so: its only use of alpha was the rim fade, which
// is a 4×4 ordered DITHER here as in the web build. Being opaque is what puts
// it in the queue that is drawn first, so every transparent emitter in the
// scene is depth-tested against it rather than stamped out by it.
//
// Lit by hand for a Lambert BRDF: the 1/π is the same one the vehicle's
// StandardMaterial3D carries, with uSunI the same irradiance its
// DirectionalLight gets (AGENTS.md, "local space is lit for a Lambert BRDF").
//
// Two things tie it to the PLANET rather than to the local frame, whose origin
// rides under the vehicle: the procedural detail is sampled about uAnchor (a
// planet-fixed point's position in the local frame — the pad, when there is
// one), so the scrub and sand stay where they are as the rocket flies over
// them instead of travelling with it; and the CLOUD SHADOWS are the cloud
// pass's own field (clouds.gdshaderinc) marched toward the sun from each
// ground point, so a shadow lies under the cloud that casts it.
// ============================================================================
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

// A 4x4 ordered dither, built by the recursion that defines a Bayer matrix —
// M(2n) = 4·M(n) tiled plus M(2) — rather than by looking one up.
float b2(vec2 p) { p = mod(p, 2.0); return mod(2.0 * p.y + 3.0 * p.x, 4.0); }
float bayer4(vec2 c) {
	vec2 p = floor(mod(c, 4.0));
	return (b2(floor(p * 0.5)) * 4.0 + b2(p)) / 16.0;
}

void fragment() {
	// Terrain colour: two rock tones mixed by a large-scale field, with a fine
	// grain that only survives close to the camera — past a few kilometres it
	// is below a pixel anyway and keeping it just aliases.
	vec2 gp = vWorld.xz - uAnchor;     // planet-fixed: see the header
	float big = fbm(gp * 0.00008);
	// Raise the ground under the launch site. Every pad ever built is on a
	// coast — for range safety — so this is what a launch site actually looks
	// like from the tower: land under you, water a few kilometres out. Under
	// the PAD, which is not where the vehicle is a minute later.
	big += 0.40 * exp(-length(gp) / 7000.0) * uHasPad;
	// Three scales of detail, each fading out at the range where it stops being
	// resolvable and starts being aliasing. The MID octave is the one that
	// matters for a launch: it is the only thing in view with a known size, so
	// it is what the eye reads the climb rate against.
	float mid = fbm(gp * 0.0011);
	float fine = fbm(gp * 0.02);
	float midK = exp(-vDist / 9000.0);
	float fineK = exp(-vDist / 900.0);
	vec3 col = mix(uRock, uGround, clamp(big * 1.5 - 0.15, 0.0, 1.0));
	col *= 0.72 + 0.30 * mix(0.5, mid, midK) + 0.34 * mix(0.5, fine, fineK);
	// Procedural seas only where there is no map: where there is one, it owns
	// every coastline, and a procedural lake blended into the pad's parcel
	// drew saturated blue ponds a few kilometres out that the map knows
	// nothing about.
	float water_frac = 0.0;
	if (uGeoReady < 0.5 && uOceans > 0.5 && big < uSeaLevel) {
		float dep = smoothstep(uSeaLevel, uSeaLevel - 0.18, big);
		col = mix(col, uSea, dep * 0.92);
		water_frac = dep;
	}
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
		// THE MAP IS TEN KILOMETRES A TEXEL, and from a hundred kilometres up
		// that is forty texels across the frame: filtered, every coast is a
		// smear and every field a blur. What is under a texel cannot be
		// recovered, but it can be made CONSISTENT with the map — detail that
		// only exists where the map cannot see and that averages back to it
		// where it can. Everything below fades on the pixel's own footprint
		// (fwidth), so it is added where the map is magnified and vanishes
		// where it is not, rather than aliasing.
		float fp = length(fwidth(gp));                              // metres per pixel here
		float texel = length(fwidth(mapUv * vec2(4096.0, 2048.0))); // map texels per pixel
		// COASTS: the bilinear mask's half-way contour, pushed about by fractal
		// noise a texel's worth, and cut as sharply as the pixel allows — a
		// coast at the pixel's resolution with the map's shape.
		float wig = (fbm(gp * (1.0 / 2600.0) + vec2(3.1, 7.7)) - 0.5) * 0.55
			+ (fbm(gp * (1.0 / 420.0) + vec2(9.2, 1.3)) - 0.5) * 0.30 * (1.0 - smoothstep(60.0, 300.0, fp));
		float k = clamp(texel * 0.5, 0.035, 0.5);
		float land = smoothstep(0.5 - k, 0.5 + k, mask + wig * (1.0 - smoothstep(0.6, 2.0, texel)));
		// Keep the actual reclaimed/graded launch parcel above water.
		land = max(land, 1.0 - smoothstep(700.0, 1800.0, distance(vWorld.xz, uPadLocal)));
		// LAND: the map's colour, broken up at the scales it cannot resolve —
		// the patchwork of forest, field, scrub and bare ground that every
		// view from orbit is made of. Brightness and dryness, each at two
		// scales, faded by footprint.
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
		// Within a few kilometres of the pad the metre-scale fields above take
		// over: stone, scrub and sand at a scale the map knows nothing about.
		float parcel = 1.0 - smoothstep(1300.0, 4200.0, distance(vWorld.xz, uPadLocal));
		float sand = smoothstep(0.48, 0.69, fbm(gp * 0.0018 + vec2(17.0, 31.0)));
		landCol = mix(landCol, col, parcel * 0.62);
		landCol = mix(landCol, uRock * 1.28, sand * parcel * 0.28);
		// WATER: the map's own shallows (the Bahamas banks are in it), with a
		// little large-scale variation so open ocean is not one flat colour.
		vec3 water = max(mapped * 0.8, uSea * 0.8) * (0.92 + 0.16 * d1);
		col = mix(water, landCol, land);
		water_frac = 1.0 - land;
	}

	// Lambert against the local sun, with the vehicle's 1/π: uSunI is the same
	// irradiance the DirectionalLight gives the rocket standing on this ground.
	// uSkyI is the diffuse skylight — the ONLY light on the night side of a
	// body with an atmosphere, and why a terminator is not a hard edge.
	const float INV_PI = 0.3183099;
	float ndl = clamp(uSunDir.y, -0.2, 1.0);
	// CLOUD SHADOW: the optical depth of the layer along the sun line from
	// here, six samples between where that line enters the base and leaves
	// the top. Not a black shadow: under a thick cloud the sun still arrives
	// DIFFUSED, and the sky round the cloud still lights the ground.
	float shade = 1.0;
	if (uCloudCoverage > 0.0 && uSunDir.y > 0.02) {
		vec2 tb = cloud_sphere(vLocal, uSunDir, uCloudBase);
		vec2 tt = cloud_sphere(vLocal, uSunDir, uCloudTop);
		float a0 = max(tb.y, 0.0);
		float a1 = tt.y;
		float ds = (a1 - a0) / 6.0;
		float od = 0.0;
		for (int i = 0; i < 6; i++)
			od += cloud_density(vLocal + uSunDir * (a0 + (float(i) + 0.5) * ds), false) * ds;
		// direct beam, or what diffuses through (two-stream, as the cloud pass)
		shade = max(exp(-od), 1.0 / (1.0 + 0.11 * od));
	}
	col *= INV_PI * (uSunI * max(ndl, 0.0) * shade + uSkyI * (0.35 + 0.65 * clamp(uSunDir.y + 0.25, 0.0, 1.0)));

	// SUN GLINT on open water: the specular image of the sun in a wind-
	// roughened sea, a GGX lobe with the slope spread of a ~7 m/s wind
	// (Cox & Munk's σ² ≈ 0.04). From altitude it is the brightest thing on the
	// planet and a broad smear across the ocean on the sun's side; without it
	// water is a flat painted blue.
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

	// AERIAL PERSPECTIVE, along the actual path from the eye to this point:
	// a straight path from the ground to altitude h through an exponential
	// atmosphere has mean density H·(1 − e^(−h/H))/h, so its depth is that
	// times the path length. Near the ground (h ≪ H) it is the ρ·distance it
	// always was; from altitude it is the column between the two, spread over
	// the slant — thin straight down, thick toward the limb, which is what
	// turns the view from orbit blue-white at the horizon. The old form used
	// the air density at the eye alone, so above 50 km the planet had no air
	// on it at all.
	//   uDensity is calibrated on the HORIZONTAL haze at the pad, which is
	// mostly boundary-layer aerosol; a path down from altitude crosses that
	// layer once and the clean air above it, so from high up the column is
	// weighted down to the ~0.1 Rayleigh depth it really is. And the light a
	// downward path scatters toward the eye is dimmer than the horizon's
	// (sideways phase, and no bright horizon behind it), so the veil straight
	// down is dimmer too. Without both, the planet from 100 km was a milky
	// blue sheet with the continents drowned in it.
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
