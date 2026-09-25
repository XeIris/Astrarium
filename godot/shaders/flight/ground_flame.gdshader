// ============================================================================
// THE GROUND FLAME — createGroundFlame() of sim/flight/plume.js: what the
// exhaust does after it hits the deck. A flattened hemisphere, brightest where
// you look ALONG the sheet, thin on the axis, thrown out in wandering lobes,
// eaten by hard-contrast turbulence so the geometry never shows as a dome.
//
// Blending as the plume (publishAlpha): colour weighted by the published
// temperature code and added; formed here, blended ONE, ONE. The normal is a
// view-space varying (normalMatrix·normal), never flipped for back faces —
// the web shader's vN was not.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

uniform vec3 uCore;
uniform vec3 uEdge;
uniform float uPower = 0.0;
uniform float uTime = 0.0;
uniform float uSoot = 0.85;
uniform float uTemp = 2800.0;

varying vec3 vP;
varying vec3 vN;

void vertex() {
	vP = VERTEX;
	vN = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
}

float hash(vec3 p) { return fract(sin(dot(p, vec3(21.7, 91.3, 47.1))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i), hash(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

void fragment() {
	if (uPower < 0.002) discard;
	float r = length(vP.xz);               // 0 on the axis, 1 at the rim
	// A THIN SHELL IS BRIGHTEST WHERE YOU LOOK ALONG IT.
	float grazing = pow(1.0 - abs(normalize(vN).y), 1.6);
	// Thin on the axis (the jet is coming down there), thickest part-way out.
	float band = smoothstep(0.08, 0.38, r) * (1.0 - smoothstep(0.58, 1.0, r));
	// LOBES, not a disc: a low-order azimuthal mode drifting at its own rate.
	float th = atan(vP.z, vP.x);
	float lobes = 0.60 + 0.40 * sin(th * 5.0 + uTime * 1.7 + sin(th * 2.0 - uTime * 0.9) * 1.4);
	// Billowing, advected radially outward at the speed it is leaving.
	float turb = noise(vec3(cos(th) * 2.6, sin(th) * 2.6, r * 3.4 - uTime * 4.0));
	turb = mix(turb, noise(vec3(cos(th) * 6.4, sin(th) * 6.4, r * 8.5 - uTime * 7.5)), 0.5);
	turb = mix(turb, noise(vec3(cos(th) * 14.0, sin(th) * 14.0, r * 17.0 - uTime * 12.0)), 0.3);
	// Hard contrast, so it EATS the shell rather than shading it.
	turb = pow(clamp(turb * 1.55 - 0.22, 0.0, 1.0), 1.7);

	float i = uPower * band * lobes * (0.22 + 1.05 * grazing) * turb * 3.2;
	if (i <= 0.0008) discard;
	// It cools fast on the way out: white at the root, deep orange at the edge.
	float cool = 1.0 - 0.80 * smoothstep(0.15, 0.95, r) * uSoot;
	vec3 col = mix(uEdge * vec3(1.0, 0.48, 0.20), uCore, cool);
	float code = clamp(log(max(uTemp * mix(1.0, cool, 0.9), 2.0)) / 25.33, 0.006, 0.984);
	ALBEDO = col * i * 6.0 * code;
	ALPHA = 0.0;
}
