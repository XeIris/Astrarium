// THE SKY DOME: a spherical atmosphere seen from inside a 3000 km sphere. Column
// density through the shell (column()), saturating so the horizon goes pale; Rayleigh
// plus a forward Mie lobe; sunrise reddening. From orbit it is the limb.
//
// Depth-tested, no depth write, back faces, transparent (blend_mix). Transparent
// objects draw after all opaque ones, so it must depth-test, or it draws over the
// vehicle.
//
// Alpha is coverage, steeper than the radiance: in daylight the sky is 10⁴ brighter
// than the stars, and with no adapted exposure here the way to say so is to cover
// them. compose.glsl blends it premultiplied over the orrery.
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

// Column density from the eye, in sea-level scale heights, ∫ exp(−z/H) ds / H through
// a spherical shell and stopping at the ground, so a tangent ray from altitude
// shows the limb.
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
	// Saturating column depth (uThick is the zenith depth from sea level; the 0.917
	// keeps the pad sky calibrated).
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

	// The sun's disc is sun_disc.gdshader; the Mie lobe is the sky's share.
	float a = clamp(scatter * 3.2, 0.0, 1.0) * sun;
	// 0.85: the horizon term already reaches (0.56, 0.71, 0.91), and more flattens into
	// white on the tone curve's shoulder.
	ALBEDO = col * 0.85;
	ALPHA = a;
}
