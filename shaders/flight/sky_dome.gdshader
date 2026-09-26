// ============================================================================
// THE SKY DOME — SKY_VERT / SKY_FRAG of sim/flight/localview.js.
// ----------------------------------------------------------------------------
// A plane-parallel atmosphere seen from inside a 3000 km sphere: column
// density along the line of sight with a 1/(cos + ε) air mass, saturating so
// the horizon goes pale instead of blowing out; Rayleigh phase plus a forward
// Mie lobe; sunrise reddening.
//
// DEPTH-TESTED, no depth write, BackSide, transparent (NormalBlending). A
// transparent object is drawn after every opaque one whatever its priority, so
// a dome drawn "behind everything" with the depth test off is drawn LAST, over
// the vehicle — the washed-out, see-through launch of the web build's history.
// Tested against the depth buffer, the ground and the vehicle occlude it.
//
// ALPHA IS COVERAGE, deliberately much steeper than the scattered radiance:
// stars are invisible in daylight not because the air is opaque but because
// the sky is four orders of magnitude brighter than they are, and with no
// adapted exposure in this pass the only way to say that is to cover them.
// In the local pass alpha is exactly that — coverage of the orrery behind —
// and compose.glsl blends it premultiplied, as the web build's NormalBlending
// drew the dome straight over the orrery's frame.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_front;

uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uTint;
uniform vec3 uHaze;
uniform float uEye = 0.0;
uniform float uScaleH = 8500.0;
uniform float uHasAir = 1.0;
uniform float uThick = 1.05;

varying vec3 vDir;

void vertex() {
	vDir = VERTEX;
}

void fragment() {
	if (uHasAir < 0.5) discard;
	vec3 d = normalize(vDir);
	float up = clamp(d.y, -1.0, 1.0);
	// Column density along the line of sight, from a plane-parallel atmosphere
	// with the Kasten–Young-ish 1/(cos+eps) air mass. Saturating rather than
	// linear, so the horizon goes pale instead of blowing out.
	float rho = exp(-uEye / uScaleH);
	float airmass = 1.0 / max(up + 0.09, 0.06);
	float tau = rho * uThick * airmass;
	float scatter = 1.0 - exp(-tau);

	float cosT = dot(d, uSunDir);
	// Rayleigh phase, and a forward Mie lobe for the glare around the sun.
	float ray = 0.75 * (1.0 + cosT * cosT);
	float mie = pow(max(cosT, 0.0), 14.0);

	float sun = clamp(uSunDir.y * 2.0 + 0.25, 0.0, 1.0);
	vec3 col = uTint * ray * scatter * sun;
	col = mix(col, uHaze * scatter * sun, clamp(scatter * 1.3 - 0.25, 0.0, 1.0));
	col += vec3(1.0, 0.82, 0.60) * mie * scatter * sun * 1.6;
	// At sunrise/sunset the path through the atmosphere reddens what is left.
	col *= mix(vec3(1.0, 0.45, 0.22), vec3(1.0), clamp(uSunDir.y * 3.0 + 0.35, 0.0, 1.0));

	float a = clamp(scatter * 3.2, 0.0, 1.0) * sun;
	// 0.85, not 1.5: the horizon term reaches uHaze·scatter ≈ (0.56, 0.71, 0.91)
	// on its own, and scaling that up put every channel past 1.0, where the tone
	// curve's shoulder flattens it to a featureless white band.
	ALBEDO = col * 0.85;
	ALPHA = a;
}
