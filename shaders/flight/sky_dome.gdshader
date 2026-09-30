// THE SKY DOME — SKY_VERT / SKY_FRAG of sim/flight/localview.js.
// A spherical atmosphere seen from inside a 3000 km sphere: column density
// along the line of sight through the shell (see column()), saturating so the
// horizon goes pale instead of blowing out; Rayleigh phase plus a forward Mie
// lobe; sunrise reddening. From the pad it is the sky it always was; from
// orbit it is the limb.
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
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_front;

uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uTint;
uniform vec3 uHaze;
uniform float uEye = 0.0;
uniform float uScaleH = 8500.0;
uniform float uHasAir = 1.0;
uniform float uThick = 1.05;
uniform float uRadius = 6.371e6;    // the planet, m
varying vec3 vDir;

// The air's column density along a ray from the eye, in units of one scale
// height of sea-level air: ∫ exp(−z/H) ds / H, through a SPHERICAL shell and
// stopping at the ground. The plane-parallel air mass this replaced knows only
// the eye's own density, so from 50 km up it saw almost no air in any
// direction and the sky went black to the horizon — when the one thing every
// photograph from up there shows is the LIMB: a tangent ray skims down through
// the whole atmosphere and glows blue in a thin band over the black.
float column(vec3 d) {
	float R = uRadius;
	float H = max(uScaleH, 1.0);
	float top = 12.0 * H;                               // e⁻¹² of the air is above this
	float h = uEye;
	float r0 = R + h;
	float b = r0 * d.y;                                 // dot(ro, rd), ro straight up
	// where the ray leaves the top of the atmosphere (or enters it, from above)
	float cT = (h - top) * (2.0 * R + h + top);         // |ro|² − (R+top)², without cancellation
	float dT = b * b - cT;
	if (dT <= 0.0) return 0.0;
	float sT = sqrt(dT);
	float t0 = h > top ? max(-b - sT, 0.0) : 0.0;
	float t1 = -b + sT;
	if (t1 <= t0) return 0.0;
	// ...and where it meets the ground, if it does
	float cG = h * (2.0 * R + h);
	float dG = b * b - cG;
	if (dG > 0.0) {
		float tg = -b - sqrt(dG);
		if (tg > 0.0) t1 = min(t1, tg);
	}
	// sixteen samples, crowded toward the start where the air is densest from
	// inside and spread through the tangent point from outside
	float acc = 0.0;
	float span = t1 - t0;
	float prev = 0.0;
	for (int i = 1; i <= 16; i++) {
		float u = float(i) / 16.0;
		float f = u * u;
		float tm = t0 + span * 0.5 * (f + prev);
		float ds = span * (f - prev);
		prev = f;
		vec3 p = vec3(0.0, r0, 0.0) + d * tm;
		float z = length(p) - R;
		acc += exp(-max(z, 0.0) / H) * ds;
	}
	return acc / H;
}


void vertex() {
	vDir = VERTEX;
}

void fragment() {
	if (uHasAir < 0.5) discard;
	vec3 d = normalize(vDir);
	// Column density along the line of sight, from a plane-parallel atmosphere
	// with the Kasten–Young-ish 1/(cos+eps) air mass. Saturating rather than
	// linear, so the horizon goes pale instead of blowing out.
	// (uThick is the zenith depth from sea level; the plane-parallel form
	// wrote it with an air mass of 1/(1 + 0.09) straight up, kept here so the
	// sky from the pad is the sky it was)
	float tau = uThick * 0.917 * column(d);
	float scatter = 1.0 - exp(-tau);

	float cosT = dot(d, uSunDir);
	// Rayleigh phase, and a forward Mie lobe for the glare around the sun.
	float ray = 0.75 * (1.0 + cosT * cosT);
	float mie = pow(max(cosT, 0.0), 220.0);

	float sun = clamp(uSunDir.y * 2.0 + 0.25, 0.0, 1.0);
	vec3 col = uTint * ray * scatter * sun;
	col = mix(col, uHaze * scatter * sun, clamp(scatter * 1.3 - 0.25, 0.0, 1.0));
	col += vec3(1.0, 0.82, 0.60) * mie * scatter * sun * 0.16;
	// At sunrise/sunset the path through the atmosphere reddens what is left.
	col *= mix(vec3(1.0, 0.45, 0.22), vec3(1.0), clamp(uSunDir.y * 3.0 + 0.35, 0.0, 1.0));

	// Clouds are not drawn here either: shaders/flight/clouds.gdshader marches
	// them as a volume, from above as well as below.

	// The sun's DISC is not drawn here: shaders/flight/sun_disc.gdshader draws
	// it in the same pass, at every altitude, with the air mass's reddening and
	// the camera's glare. The Mie lobe above is the sky's own share of it.
	float a = clamp(scatter * 3.2, 0.0, 1.0) * sun;
	// 0.85, not 1.5: the horizon term reaches uHaze·scatter ≈ (0.56, 0.71, 0.91)
	// on its own, and scaling that up put every channel past 1.0, where the tone
	// curve's shoulder flattens it to a featureless white band.
	ALBEDO = col * 0.85;
	ALPHA = a;
}
