// RE-ENTRY PLASMA, the shock layer: one shell of the vehicle's own skin pushed out
// along its normals, as a material_overlay (three chained by next_pass make the layer),
// so it fits every part, flap and piece. Lit by how squarely the skin meets the air:
// local flux ≈ q₀·cos²θ, and the leeward side and anything in the body's own lee stay
// dark (docs/physics/entry-plasma.md).
// Added ONE, ONE, depth-tested so the vehicle hides its own far side.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_back, world_vertex_coords;
#include "res://shaders/flight/entry_plasma.gdshaderinc"

uniform float uHeat = 0.0;                     // stagnation flux / 1.1 MW/m²
uniform float uTemp = 2000.0;                  // shock-layer temperature there, K
uniform float uTime = 0.0;
uniform vec3 uMotion = vec3(0.0, 1.0, 0.0);    // world: the body's way through the air
uniform vec3 uOrigin = vec3(0.0);              // world: the body's origin, the noise frame
uniform float uScale = 5.0;                    // m: the body's diameter
uniform float uNoseR = 1.0;                    // m: the radius the stagnation flux is for
uniform float uStandoff = 0.1;                 // m off the skin at the stagnation point
uniform float uWeight = 1.0;                   // this shell's share of the emission
uniform float uEdge = 0.0;                     // 1: fade toward this shell's silhouette
// Newtonian shelter (Plume.EntryGlow._shelter_map): the most upstream skin depth in each
// column of the projection along the flow; uToGrid takes a world offset from uOrigin to
// (across, across, upstream) in the root frame; uGrid is (lowest corner, cell, tolerance).
uniform sampler2D uShelter : filter_nearest, repeat_disable;
uniform mat3 uToGrid = mat3(1.0);
uniform vec4 uGrid = vec4(0.0, 0.0, 1.0, 1.0);

varying vec3 vN;
varying vec3 vQ;
varying vec3 vSkin;

void vertex() {
	vec3 n = normalize(NORMAL);
	// Thinnest at the stagnation point, thickening round the shoulders.
	float c = clamp(dot(n, uMotion), 0.0, 1.0);
	vSkin = VERTEX - uOrigin;
	VERTEX += n * uStandoff * (1.0 + 1.5 * (1.0 - c));
	vN = n;
	vQ = VERTEX - uOrigin;
}

// 1 where skin further upstream in this column of the flow hides the point from the
// air, 0 where nothing does; the four nearest columns, blended, so the edge is soft.
// A column's deepest sample may lie up to ~1.5 cells away on the same skin, which a
// slope of tan θ (c = cos θ) puts that much further upstream: not shelter.
float sheltered(vec3 q, float c) {
	vec3 g = uToGrid * q;
	ivec2 size = textureSize(uShelter, 0);
	vec2 t = (g.xy - uGrid.xy) / uGrid.z - 0.5;
	ivec2 i0 = ivec2(floor(t));
	vec2 f = t - floor(t);
	float tol = uGrid.w + 1.5 * uGrid.z * sqrt(max(1.0 - c * c, 0.0)) / max(c, 0.05);
	float s[4];
	for (int k = 0; k < 4; k++) {
		ivec2 c = i0 + ivec2(k & 1, k >> 1);
		bool in_map = c.x >= 0 && c.y >= 0 && c.x < size.x && c.y < size.y;
		float hi = in_map ? texelFetch(uShelter, c, 0).r : -1e6;
		s[k] = smoothstep(tol, 2.0 * tol, hi - g.z);
	}
	return mix(mix(s[0], s[1], f.x), mix(s[2], s[3], f.x), f.y);
}

void fragment() {
	vec3 n = normalize(vN);
	float c = dot(n, uMotion);
	if (uHeat < 0.001 || c <= 0.0) discard;
	// Wall flux q₀·cos²θ, and ∝ 1/√R for the local radius of curvature R (from the
	// normal's change across the pixel), so a nose cap or a leading edge outshines
	// the flat belly. The gas's own radiance climbs faster than the flux: flux^1.5.
	float k = length(fwidth(n)) / max(length(fwidth(vQ)), 1e-5);
	float q = c * c * smoothstep(0.0, 0.3, c) * clamp(sqrt(k * uNoseR), 0.6, 1.8);
	q *= 1.0 - sheltered(vSkin, c);
	if (q <= 0.0) discard;
	float glow = q * sqrt(q);
	vec3 V = normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz);
	float mu = abs(dot(n, V));
	// A thin glowing layer brightens toward its limb (a longer path through it).
	float path = mix(1.0 / max(mu, 0.3), smoothstep(0.0, 0.7, mu), uEdge);
	// Turbulence: streaks along the flow, running aft.
	float along = dot(vQ, uMotion);
	vec3 across = vQ - uMotion * along;
	vec3 x = across / (0.12 * uScale) + uMotion * ((along + uTime * 2.0 * uScale) / (1.2 * uScale));
	float t = plasma_noise(x) * 0.7 + plasma_noise(x * 2.3 + 7.1) * 0.3;
	float flick = 0.7 + 0.6 * t;
	// The local wall flux sets the local temperature, T ∝ q^¼ as for radiative equilibrium.
	float T = uTemp * pow(q, 0.25);
	ALBEDO = plasma_spectral(pow(q, 0.25), T) * (uHeat * uWeight * glow * path * flick * 22.0 * plasma_code(T));
	ALPHA = 0.0;
}
