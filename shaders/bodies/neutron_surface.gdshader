// ============================================================================
// NEUTRON-STAR SURFACE — port of SURF_VERT / SURF_FRAG in sim/neutron_visual.js.
// The header of sim/neutron_visual.gd carries the physics.
//
// Everything here is camera-relative. The web build avoided forming a world
// coordinate by working from modelViewMatrix and rotating the view-space offset
// back to world with the transpose of mat3(viewMatrix); here world space IS
// camera-relative (the floating origin, PORT_GUIDE.md §3), and the same
// rotation is mat3(INV_VIEW_MATRIX).
// ============================================================================
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uTime = 0.0;
uniform float uGain = 1.35;
uniform float uCompact = 0.4;
uniform float uCapGlow = 0.0;
uniform float uTeffK = 1.0e6;
uniform vec3 uColor = vec3(0.30, 0.52, 1.0);
uniform vec3 uCapColor = vec3(0.80, 0.90, 1.0);
uniform vec3 uMagAxis = vec3(0.0, 1.0, 0.0);

varying vec3 vObj;
varying vec3 vWN;
varying vec3 vView;

void vertex() {
	vObj = normalize(VERTEX);
	vWN = normalize(mat3(MODEL_MATRIX) * NORMAL);
	vec4 mv = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	// back to WORLD space without a world coordinate: mv.xyz is the offset to
	// the camera in the view basis, and a view rotation is orthonormal, so its
	// inverse rotates it back. The self-lensing below reconstructs against vObj
	// and so needs V in world.
	vView = -(mat3(INV_VIEW_MATRIX) * mv.xyz);
}

float hsh(vec3 p) { return fract(sin(dot(p, vec3(17.1, 113.5, 7.9))) * 43758.5453); }
float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hsh(i), hsh(i + vec3(1.0, 0.0, 0.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 0.0)), hsh(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(hsh(i + vec3(0.0, 0.0, 1.0)), hsh(i + vec3(1.0, 0.0, 1.0)), f.x), mix(hsh(i + vec3(0.0, 1.0, 1.0)), hsh(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float fbm(vec3 p0) {
	vec3 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.11; a *= 0.5; }
	return v;
}

void fragment() {
	vec3 V  = normalize(vView);
	vec3 N  = normalize(vWN);
	float mu = clamp(dot(N, V), 0.0, 1.0);

	// --- gravitational self-lensing.
	// cos(psi) = 1 - (1 - mu) / (1 - rs/R).  uCompact = rs/R.
	// Points on the apparent disc map back to a LARGER colatitude than they
	// would in flat space, which is how the far side comes into view.
	float cosPsi = 1.0 - (1.0 - mu) / max(1.0 - uCompact, 0.05);
	cosPsi = clamp(cosPsi, -1.0, 1.0);

	// Rebuild the true surface direction: keep the object-space azimuth around
	// the view axis, but replace the colatitude with the lensed one.
	//
	// NOTE: vObj is object space and V is world space, so this reconstruction
	// is only correct while the mesh carries no rotation relative to world
	// space. That holds today — update() rotates spin_axis, never core, and
	// no obliquity tilt is applied to a neutron star the way sim/world.gd tilts
	// a rocky planet. Anything that starts rotating this group has to transform
	// V into object space with inverse(MODEL_MATRIX) in the vertex shader first,
	// or the far side will come into view off-axis.
	vec3 tangential = normalize(vObj - dot(vObj, V) * V + vec3(1e-6));
	vec3 pTrue = normalize(V * cosPsi + tangential * sqrt(max(1.0 - cosPsi * cosPsi, 0.0)));

	// --- surface: a smooth degenerate crust. Almost featureless — it is
	// crushed to nuclear density and about as flat as anything in nature —
	// so only a faint mottling from field-line footprints.
	float mot = fbm(pTrue * 9.0 + uTime * 0.05);
	float base = 0.85 + mot * 0.30;

	// --- hot magnetic caps around ±magnetic axis
	float capA = dot(pTrue,  normalize(uMagAxis));
	float cap  = smoothstep(0.80, 0.985, abs(capA));
	// ragged rim where the open field lines end
	cap *= 0.7 + 0.6 * fbm(pTrue * 22.0 + uTime * 0.6);

	vec3 col = uColor * base;
	col += uCapColor * cap * (2.2 + uCapGlow * 5.0);

	// --- limb darkening. Hot, mostly-scattering atmosphere: shallow law.
	col *= 1.0 - 0.35 * (1.0 - mu);

	// --- the lensed rim. Light from the far side piles up into a bright
	// ring right at the apparent edge, which is a real signature of a compact
	// enough object and the thing that makes it read as *dense*.
	float rim = pow(1.0 - mu, 3.5);
	col += uColor * rim * 2.6;

	// The temperature pass: the log-encoded surface temperature (~10⁶ K) for
	// sim/spectrum.gd. This is why a neutron star is the one thing in the sim
	// that blazes in the X-ray band while every star in the field goes black.
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		ALBEDO = vec3(temp_code(uTeffK), 0.0, 0.0);
	} else {
		ALBEDO = col * uGain;
	}
}
