// ============================================================================
// THE LEGACY STAR surface — starMaterial() in sim/bodies.js: granulation fBm +
// limb darkening + flicker. Shared by star_basic.gdshader (the opaque core)
// and star_basic_layer.gdshader (the additive "gassy outer layer", which in
// the web build was a clone of the same ShaderMaterial).
// ============================================================================
#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform vec3 uColor = vec3(1.0);
uniform float uPulse = 1.0;

varying vec3 vN;
varying vec3 vPos;

void vertex() {
	vN = normalize(MODELVIEW_NORMAL_MATRIX * NORMAL);
	vPos = VERTEX;
}

float hsh(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n = mix(mix(mix(hsh(i), hsh(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 0.0)), hsh(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	              mix(mix(hsh(i + vec3(0.0, 0.0, 1.0)), hsh(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 1.0)), hsh(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
	return n;
}
float fbm(vec3 p0) {
	vec3 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 5; i++) { v += a * vnoise(p); p *= 2.05; a *= 0.5; }
	return v;
}

vec3 star_basic_color() {
	vec3 p = normalize(vPos);
	float gran = fbm(p * 7.0 + uTime * 0.15);
	float cells = fbm(p * 16.0 - uTime * 0.25);
	float bright = 0.55 + gran * 0.7 + cells * 0.25;
	// dark sunspots
	float spot = 1.0 - smoothstep(0.5, 0.62, fbm(p * 4.0 + vec3(3.0) + uTime * 0.02));
	bright *= mix(1.0, 0.45, spot);
	vec3 base = uColor * bright * uPulse;
	// hot specks
	base += vec3(1.0, 0.85, 0.5) * pow(max(cells - 0.55, 0.0), 2.0) * 1.5;
	// limb darkening
	float limb = pow(max(dot(vN, vec3(0.0, 0.0, 1.0)), 0.0), 0.55);
	base *= mix(0.55, 1.15, limb);
	return base;
}
