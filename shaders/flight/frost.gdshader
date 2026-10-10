// RIME ON A CRYOGENIC TANK (sim/flight/cryo.gd): a lit, partly transparent shell
// just outside the stage's skin. Ice collects in horizontal runs, where moisture
// condenses under ring frames and stringers, and in blotches between them; it is
// thickest mid-tank and thins toward the band's ends. uAmount sheds it in flight.
shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_back, diffuse_lambert, specular_schlick_ggx;

uniform float uAmount = 1.0;
uniform float uStrength = 1.0;
uniform float uSeed = 0.0;

varying vec3 vObj;

void vertex() {
	vObj = VERTEX;
}

float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p) {
	vec3 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
	               mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
	               mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

void fragment() {
	// Around the tank in metres of arc, so the noise wraps without a seam.
	vec3 q = vObj + vec3(uSeed);
	float blotch = vnoise(q * 0.22) * 0.6 + vnoise(q * 0.7) * 0.3 + vnoise(q * 2.2) * 0.1;
	float runs = vnoise(vec3(q.x * 0.35, q.y * 3.5, q.z * 0.35));
	float ends = smoothstep(0.0, 0.18, UV.y) * smoothstep(1.0, 0.82, UV.y);
	float rime = (blotch * 0.7 + runs * 0.45) * ends * uStrength;
	float cover = smoothstep(0.42, 0.75, rime) * uAmount;
	// Shedding takes the thin rime first and leaves the thick runs longest.
	cover *= smoothstep(1.0 - uAmount, 1.0 - uAmount + 0.25, rime + 0.25);
	if (cover < 0.01) discard;
	// Rime is bright and matte; fresh frost has a faint sparkle.
	ALBEDO = vec3(0.86, 0.89, 0.92);
	ROUGHNESS = 0.82 - 0.2 * vnoise(q * 9.0);
	SPECULAR = 0.35;
	ALPHA = cover * 0.9;
}
