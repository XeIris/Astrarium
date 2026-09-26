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
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_disabled;

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
uniform sampler2D uEarthColor : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D uEarthLand : filter_linear_mipmap_anisotropic, repeat_enable;

varying float vDist;
varying vec3 vWorld;
varying float vDrop;

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
	float big = fbm(vWorld.xz * 0.00008);
	// Raise the ground under the launch site. Every pad ever built is on a
	// coast — for range safety — so this is what a launch site actually looks
	// like from the tower: land under you, water a few kilometres out.
	big += 0.40 * exp(-vDist / 7000.0);
	// Three scales of detail, each fading out at the range where it stops being
	// resolvable and starts being aliasing. The MID octave is the one that
	// matters for a launch: it is the only thing in view with a known size, so
	// it is what the eye reads the climb rate against.
	float mid = fbm(vWorld.xz * 0.0011);
	float fine = fbm(vWorld.xz * 0.02);
	float midK = exp(-vDist / 9000.0);
	float fineK = exp(-vDist / 900.0);
	vec3 col = mix(uRock, uGround, clamp(big * 1.5 - 0.15, 0.0, 1.0));
	col *= 0.72 + 0.30 * mix(0.5, mid, midK) + 0.34 * mix(0.5, fine, fineK);
	if (uOceans > 0.5 && big < uSeaLevel) {
		float dep = smoothstep(uSeaLevel, uSeaLevel - 0.18, big);
		col = mix(col, uSea, dep * 0.92);
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
		float land = texture(uEarthLand, mapUv).r;
		// The global mask resolves roughly 10 km per pixel. Keep the actual
		// reclaimed/graded launch parcel above water at that coarse resolution.
		land = max(land, 1.0 - smoothstep(700.0, 1800.0, distance(vWorld.xz, uPadLocal)));
		// The global image resolves kilometres, so local stone, scrub and sand
		// still come from the metre-scale fields above. The mapped mask owns
		// every coastline, including the ocean beyond the launch complex.
		vec3 landCol = mix(mapped, col, 0.42);
		vec3 water = max(mapped * 0.8, uSea * 0.8);
		col = mix(water, landCol, land);
	}

	// Lambert against the local sun, with the vehicle's 1/π: uSunI is the same
	// irradiance the DirectionalLight gives the rocket standing on this ground.
	// uSkyI is the diffuse skylight — the ONLY light on the night side of a
	// body with an atmosphere, and why a terminator is not a hard edge.
	const float INV_PI = 0.3183099;
	float ndl = clamp(uSunDir.y, -0.2, 1.0);
	col *= INV_PI * (uSunI * max(ndl, 0.0) + uSkyI * (0.35 + 0.65 * clamp(uSunDir.y + 0.25, 0.0, 1.0)));

	// AERIAL PERSPECTIVE. The optical depth along a horizontal path is the
	// integral of the density, which for an exponential atmosphere seen from
	// altitude h is ρ(h)·distance — so the haze thins with height on the body's
	// own scale height with nothing extra to tune.
	float rho = uHasAir > 0.5 ? exp(-uEye / uScaleH) : 0.0;
	float tau = rho * uDensity * vDist;
	float fog = 1.0 - exp(-tau);
	col = mix(col, uHaze * (0.35 + 0.75 * max(ndl, 0.0)), clamp(fog, 0.0, 1.0));

	// The patch has to end somewhere; fade it out rather than showing an edge —
	// DITHERED, not blended, because this surface is OPAQUE.
	float edge = 1.0 - smoothstep(0.86, 1.0, vDist / uPatch);
	if (edge <= 0.002) discard;
	if (edge < 1.0 && edge < bayer4(FRAGCOORD.xy)) discard;
	ALBEDO = col;
}
