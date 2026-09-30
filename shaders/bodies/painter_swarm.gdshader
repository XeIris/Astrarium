// ORBITAL SWARM: the particles of a painted ring or belt (sim/painter.gd), with each
// particle's analytic Kepler orbit solved in the vertex shader from its elements;
// only the clock is a uniform.
//
// THE CLOCK IN FLOAT32. M = M0 + n t drifts: near Saturn n ~ 1e4 rad/yr, and after
// centuries n t ~ 1e6 rad, where a float32 ulp is 0.06 rad. So the phase is in
// revolutions with both factors split:
//     nu = nu_hi + nu_lo        (nu_hi carries 12 significant bits)
//     t  = t_hi  + t_lo         (t_hi carries 12 significant bits)
// nu_hi * t_hi is an exact 24-bit product, so its fraction is exact; the cross terms
// are ~2^-11 of the whole. The CPU splits in double (nu per particle, t per frame).
//
// CUSTOM0 = (a [AU], e, nu_hi, nu_lo)     nu in revolutions per year
// CUSTOM1 = (M0, inclination, node, argument of periapsis)
// CUSTOM2 = (size, shade, 0, 0)
//
// Transparent (blend_mix); the temperature pass writes 1 at the point's own alpha.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(0.61, 0.5, 0.32);
uniform float uSize = 2.2;
uniform float uSoft = 1.0;
uniform vec2 uT = vec2(0.0);     // (t_hi, t_lo), years
uniform float uScale = 1.0;      // scene units per AU

varying float vShade;

// Kepler's equation M = E − e sin E: two Newton steps from a good guess.
float eccentricAnomaly(float M, float e) {
	float Ea = M + e * sin(M) * (1.0 + e * cos(M));
	for (int i = 0; i < 2; i++) {
		Ea -= (Ea - e * sin(Ea) - M) / (1.0 - e * cos(Ea));
	}
	return Ea;
}

void vertex() {
	float a = CUSTOM0.x;
	float e = CUSTOM0.y;
	float rev = fract(fract(CUSTOM0.z * uT.x) + fract(CUSTOM0.z * uT.y)
	                + fract(CUSTOM0.w * uT.x) + CUSTOM0.w * uT.y);
	float M = CUSTOM1.x + 6.283185307 * rev;
	float Ea = e > 1e-6 ? eccentricAnomaly(M, e) : M;
	// Position in the orbital plane, from the eccentric anomaly.
	float xo = a * (cos(Ea) - e);
	float yo = a * sqrt(1.0 - e * e) * sin(Ea);
	// Rotate by argument of periapsis, inclination, longitude of node.
	float cw = cos(CUSTOM1.w), sw = sin(CUSTOM1.w);
	float x1 = xo * cw - yo * sw;
	float y1 = xo * sw + yo * cw;
	float ci = cos(CUSTOM1.y), si = sin(CUSTOM1.y);
	float x2 = x1;
	float y2 = y1 * ci;
	float z2 = y1 * si;
	float co = cos(CUSTOM1.z), so = sin(CUSTOM1.z);
	float X = x2 * co - y2 * so;
	float Y = x2 * so + y2 * co;
	// Scene axes: the orbital plane is XZ, so the out-of-plane term is Y.
	vec3 p = vec3(X, z2, Y) * uScale;
	vShade = CUSTOM2.y;
	// Model space; MODEL_MATRIX's translation is the pinned body's offset from
	// the camera (floating origin), so the transformed point is small near it.
	VERTEX = p;
	// Constant pixel size: a ring particle is unresolvable from any distance where the
	// ring is visible, so it stays a point source.
	POINT_SIZE = uSize * CUSTOM2.x;
}

void fragment() {
	float d = length(POINT_COORD - 0.5) * 2.0;
	if (d > 1.0) discard;
	float al = pow(1.0 - d, uSoft);
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = uColor * vShade;
	}
	ALPHA = al * 0.9;
}
