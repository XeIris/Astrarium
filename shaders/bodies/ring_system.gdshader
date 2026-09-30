// RINGS: a radial optical-depth profile. Saturn's, in its own radii:
//   C ring      1.24 – 1.53   tau ~ 0.1, nearly transparent
//   B ring      1.53 – 1.95   tau ~ 1.5, the bright one
//   Cassini     1.95 – 2.03   a resonance-swept gap
//   A ring      2.03 – 2.27   tau ~ 0.5, Encke gap at 2.21
// Boundaries are moon resonances, hence sharp. Transparency is 1 − exp(−tau/mu)
// along the slant path. blend_mix, cull_disabled; the temperature pass writes 1 at
// the ring's alpha.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled;

#include "res://shaders/common/suns.gdshaderinc"
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/terrain_noise.gdshaderinc"

uniform vec3 uColor = vec3(0.69, 0.58, 0.38);
uniform float uInner = 1.24;
uniform float uOuter = 2.27;
uniform float uBodyR = 1.0;
uniform float uSeed = 1.0;
uniform vec3 uSunObj[4];

varying vec3 vLocal;
varying vec3 vView;
varying vec3 vNrm;

void vertex() {
	vLocal = VERTEX;                    // ring plane is the mesh's own XY
	vNrm = normalize(mat3(MODEL_MATRIX) * vec3(0.0, 0.0, 1.0));
	vView = -(MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// Optical depth vs radius, in body radii.
float tauAt(float r) {
	float t = 0.0;
	t += 0.12 * sstep(1.235, 1.27, r) * sstep(1.53, 1.50, r);   // C
	t += 1.50 * sstep(1.525, 1.56, r) * sstep(1.951, 1.93, r);  // B
	t += 0.06 * sstep(1.951, 1.96, r) * sstep(2.025, 2.015, r); // Cassini
	t += 0.55 * sstep(2.025, 2.04, r) * sstep(2.269, 2.25, r);  // A
	t *= 1.0 - 0.85 * sstep(2.209, 2.214, r) * sstep(2.219, 2.214, r); // Encke
	return t;
}

void fragment() {
	float r = length(vLocal.xy) / max(uBodyR, 1e-6);
	if (r < uInner || r > uOuter) discard;
	float tau = tauAt(r);
	// Ringlets: spiral density waves, radial only (grooved like a record), two scales.
	tau *= 0.62 + 0.50 * fbm(vec3(r * 42.0, uSeed, 0.0), 3)
	     + 0.26 * fbm(vec3(r * 150.0, uSeed + 3.0, 0.0), 2);
	if (tau < 0.004) discard;

	// Transmitted fraction exp(−tau/mu), mu the cosine to the ring-plane normal: opaque
	// edge-on, a haze face-on.
	vec3 V = normalize(vView);
	float mu = max(abs(dot(normalize(vNrm), V)), 0.05);
	float alpha = 1.0 - exp(-tau / mu);

	vec3 lit = vec3(0.0);
	for (int i = 0; i < 4; i++) {
		if (i >= uSunCount) break;
		vec3 L = normalize(uSunDir[i]);
		// the planet's own shadow falling across the rings
		vec3 Lo = normalize(uSunObj[i]);
		// The mesh is turned -90 degrees about X to lie in the equator, so
		// its local (x, y) is the body frame's (x, -z). Get that wrong and
		// the planet's shadow falls on the wrong side of the system.
		vec2 q = vLocal.xy / max(uBodyR, 1e-6);
		vec3 pt = vec3(q.x, 0.0, -q.y);
		float along = dot(pt, Lo);
		float perp = length(pt - Lo * along);
		// The planet's shadow is a cylinder along the star line: a parallel-sided band on
		// tilted rings, soft-edged because the star is a disc.
		float sh = (along < 0.0) ? mix(0.10, 1.0, sstep(0.92, 1.12, perp)) : 1.0;
		// Ring particles are icy and forward-scatter strongly: the far side
		// of the system, seen against the sun, is much the brighter.
		float fwd = 0.45 + 0.9 * pow(max(dot(V, -L), 0.0), 2.5);
		// denser material is brighter as well as more opaque
		lit += uColor * uSunColor[i] * uSunInt[i] * sh * fwd * (0.55 + 0.45 * min(tau, 1.2));
	}
	lit += uColor * 0.015;
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(1.0, 0.0, 0.0);
	} else {
		ALBEDO = lit * 0.75;
	}
	ALPHA = clamp(alpha, 0.0, 1.0);
}
