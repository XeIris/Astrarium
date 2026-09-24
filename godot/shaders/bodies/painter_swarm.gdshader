// ============================================================================
// ORBITAL SWARM — the particles of a painted ring or belt (sim/painter.gd).
// ----------------------------------------------------------------------------
// The web build advanced every particle's Kepler orbit on the CPU each frame
// and uploaded the positions. Here the same analytic solution runs in the
// VERTEX SHADER: each point carries its orbital elements as attributes, and
// only the clock is a uniform. The solution is exact for a test particle
// (painter.gd's header says why), so moving it to the GPU changes nothing but
// where it is evaluated — except precision, which is the one thing to get right.
//
// THE CLOCK IN FLOAT32. The mean anomaly M = M0 + n t is what drifts: a ring
// particle near Saturn has n ~ 1e4 rad/yr, so after a few hundred simulated
// years n t is ~1e6 rad, where one float32 ulp is 0.06 rad and the ring would
// visibly step. So the phase is formed in REVOLUTIONS with both factors split:
//
//     nu = nu_hi + nu_lo        (nu_hi carries 12 significant bits)
//     t  = t_hi  + t_lo         (t_hi carries 12 significant bits)
//
// nu_hi * t_hi is then a 24-bit product and EXACT in float32, so its fractional
// part is exact however large it is; the three cross terms are each ~2^-11 of
// the whole and lose nothing that matters. The CPU does the splitting (in
// double), once per particle for nu and once per frame for t.
//
// CUSTOM0 = (a [AU], e, nu_hi, nu_lo)     nu in revolutions per year
// CUSTOM1 = (M0, inclination, node, argument of periapsis)
// CUSTOM2 = (size, shade, 0, 0)
//
// Transparent, NormalBlending → blend_mix; temperature pass writes 1 at the
// point's own alpha (PORT_GUIDE.md §6 table).
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(0.61, 0.5, 0.32);
uniform float uSize = 2.2;
uniform float uSoft = 1.0;
uniform vec2 uT = vec2(0.0);     // (t_hi, t_lo), years
uniform float uScale = 1.0;      // scene units per AU

varying float vShade;

// Solve Kepler's equation M = E − e sin E for the eccentric anomaly.
// Two Newton steps from a good initial guess are accurate to ~1e-10 (in
// double; to float32 here) for the eccentricities anything here uses.
float eccentricAnomaly(float M, float e) {
	float E = M + e * sin(M) * (1.0 + e * cos(M));
	for (int i = 0; i < 2; i++) {
		E -= (E - e * sin(E) - M) / (1.0 - e * cos(E));
	}
	return E;
}

void vertex() {
	float a = CUSTOM0.x;
	float e = CUSTOM0.y;
	float rev = fract(fract(CUSTOM0.z * uT.x) + fract(CUSTOM0.z * uT.y)
	                + fract(CUSTOM0.w * uT.x) + CUSTOM0.w * uT.y);
	float M = CUSTOM1.x + 6.283185307 * rev;
	float E = e > 1e-6 ? eccentricAnomaly(M, e) : M;
	// Position in the orbital plane, from the eccentric anomaly.
	float xo = a * (cos(E) - e);
	float yo = a * sqrt(1.0 - e * e) * sin(E);
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
	// Constant size in PIXELS, deliberately. A ring particle is somewhere
	// between a grain and a house, sitting in a ring a hundred thousand
	// kilometres wide: its true angular size is unresolvable at every
	// distance from which the ring is visible at all, so it is a point
	// source and stays one. Sizing these with distance would draw the
	// particles as boulders the size of moons the moment you flew close.
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
