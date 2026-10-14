// RE-ENTRY PLASMA, the shock layer: one shell of the vehicle's own skin pushed out
// along its normals, as a material_overlay (three chained by next_pass make the layer),
// so it fits every part, flap and piece. Lit by how squarely the skin meets the air:
// local flux ≈ q₀·cos²θ, and the leeward side stays dark (docs/physics/entry-plasma.md).
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

varying vec3 vN;
varying vec3 vQ;

void vertex() {
	vec3 n = normalize(NORMAL);
	// Thinnest at the stagnation point, thickening round the shoulders.
	float c = clamp(dot(n, uMotion), 0.0, 1.0);
	VERTEX += n * uStandoff * (1.0 + 1.5 * (1.0 - c));
	vN = n;
	vQ = VERTEX - uOrigin;
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
	ALBEDO = plasma_colour(T) * (uHeat * uWeight * glow * path * flick * 22.0 * plasma_code(T));
	ALPHA = 0.0;
}
