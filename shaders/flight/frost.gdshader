// RIME ON A CRYOGENIC TANK (sim/flight/cryo.gd): a lit, partly transparent shell
// just outside the stage's skin. Ice forms in broad patches where the wall is
// coldest, and condensate freezes as it runs down along the stringers, so the
// coat is streaked vertically. It thins toward the band's ends; uAmount sheds it.
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
	// Object space is metres around the tank, so the noise wraps without a seam.
	vec3 q = vObj + vec3(uSeed);
	float patches = vnoise(q * 0.18) * 0.65 + vnoise(q * 0.6) * 0.35;
	float runs = vnoise(vec3(q.x * 1.6, q.y * 0.09, q.z * 1.6)) * 0.7
		+ vnoise(vec3(q.x * 4.5, q.y * 0.25, q.z * 4.5)) * 0.3;
	float ends = smoothstep(0.0, 0.18, UV.y) * smoothstep(1.0, 0.82, UV.y);
	float rime = (patches * 0.6 + runs * 0.55) * ends * uStrength;
	float cover = smoothstep(0.36, 0.66, rime) * uAmount;
	// Shedding takes the thin rime first and leaves the thick runs longest.
	cover *= smoothstep(1.0 - uAmount, 1.0 - uAmount + 0.25, rime + 0.25);
	if (cover < 0.01) discard;
	// Rime is bright, matte and granular; where it is thin the wall shows grey through.
	float grain = vnoise(q * 9.0);
	ALBEDO = vec3(0.93, 0.95, 0.97) * (0.9 + 0.1 * grain);
	ROUGHNESS = 0.85 - 0.2 * grain;
	SPECULAR = 0.35;
	ALPHA = cover * 0.92;
}
