// ============================================================================
// GAS CLOUD SHELL — the port of sim/painter.js's createGasCloud material. The
// physics (optically thin, limb-brightened, homologous expansion) is in
// sim/painter.gd's GasCloud header.
//
// AdditiveBlending, DoubleSide → blend_add, cull_disabled. Its alpha a' was
// summed into the temperature channel as a'·a' + d; the temperature pass
// writes a' at alpha a' through blend_add to reproduce it.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(1.0, 0.6, 0.3);
uniform float uDensity = 0.7;
uniform float uTime = 0.0;
uniform float uSeed = 1.0;

varying vec3 vObj;
varying vec3 vView;
varying vec3 vN;

float hash(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i),                       hash(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(hash(i + vec3(0.0, 1.0, 0.0)), hash(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hash(i + vec3(0.0, 0.0, 1.0)), hash(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(hash(i + vec3(0.0, 1.0, 1.0)), hash(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm5(vec3 p) { float v = 0.0; float a = 0.5; vec3 q = p; for (int i = 0; i < 5; i++) { v += a * noise(q); q *= 2.13; a *= 0.5; } return v; }

void vertex() {
	vObj = normalize(VERTEX);
	vN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	// Camera-relative, never through an absolute world coordinate: under the
	// floating origin the world position IS the offset from the camera.
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 V = normalize(vView);
	float mu = abs(dot(normalize(vN), V));
	// Limb brightening: an optically thin shell is brightest where the
	// sightline is most nearly tangent to it, i.e. where mu -> 0. The
	// column depth through a thin shell goes as 1/mu.
	float limb = pow(1.0 - mu, 2.4) + 0.06;
	// Filamentary structure. Real ejecta are shredded by Rayleigh-Taylor
	// instabilities at the contact between fast and slow material, which
	// is what makes every nebula stringy rather than smooth.
	float fil = fbm5(vObj * 5.0 + uSeed) * 0.7 + fbm5(vObj * 17.0 - uSeed) * 0.45;
	float a = limb * uDensity * (0.35 + fil);
	float aa = clamp(a, 0.0, 1.0) * 0.85;
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(aa, 0.0, 0.0);
	} else {
		ALBEDO = uColor * a * 2.2;
	}
	ALPHA = aa;
}
