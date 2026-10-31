// THE SKY DOME: a spherical atmosphere seen from inside a 3000 km sphere. From orbit
// it is the limb. An atmosphere with measured scattering coefficients (uPhysical:
// Earth) is single-scattered: Rayleigh λ⁻⁴, Mie and ozone absorption, each sample lit
// through its own sun path and dark in the planet's shadow, so sunsets redden, the
// Chappuis band keeps the twilight zenith blue, and the Earth shadow and Belt of Venus
// appear (Bruneton 2017 coefficients; docs/physics/sky.md#flight-sky). Multiple
// scattering comes from a precomputed table (sim/flight/sky_ms.gd, Hillaire 2020).
// Other bodies use the older grey column with a tint.
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
uniform float uPhysical = 0.0;
// Sea-level coefficients, m⁻¹, for the R, G, B primaries (680, 550, 440 nm).
uniform vec3 uBetaR = vec3(5.802e-6, 13.558e-6, 33.1e-6);
uniform float uBetaM = 3.996e-6;
uniform float uBetaMExt = 4.44e-6;  // Mie extinction; the albedo is 0.9
uniform vec3 uBetaO = vec3(0.650e-6, 1.881e-6, 0.085e-6);
uniform float uHR = 8000.0;
uniform float uHM = 1200.0;
uniform float uMieG = 0.8;
uniform float uGain = 10.0;         // SkyMS.GAIN: the pad's noon zenith at the old calibration
// Ψ(h, μ_s), the multiply scattered light per unit σ_s (SkyMS); u is μ_s, v is √(h/top).
uniform sampler2D uMS : filter_linear, repeat_disable;
uniform float uMSN = 32.0;
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


// Rayleigh, Mie and ozone densities (relative to sea level) at height z.
vec3 dens(float z) {
	float zz = max(z, 0.0);
	return vec3(exp(-zz / uHR), exp(-zz / uHM), max(1.0 - abs(zz - 25000.0) / 15000.0, 0.0));
}

// Optical depth (per channel) from p toward the sun; a huge value in the shadow.
vec3 sun_depth(vec3 p, vec3 s) {
	float R = uRadius;
	float b = dot(p, s);
	float c = dot(p, p) - R * R;
	if (b < 0.0 && b * b - c > 0.0) return vec3(1e4);
	float top = R + 12.0 * uHR;
	float t1 = -b + sqrt(max(b * b - (dot(p, p) - top * top), 0.0));
	vec3 acc = vec3(0.0);
	float prev = 0.0;
	for (int i = 1; i <= 6; i++) {
		float u = float(i) / 6.0;
		float f = u * u;
		vec3 dn = dens(length(p + s * t1 * 0.5 * (f + prev)) - R) * t1 * (f - prev);
		prev = f;
		acc += dn;
	}
	return uBetaR * acc.x + vec3(uBetaMExt) * acc.y + uBetaO * acc.z;
}

vec4 physical_sky(vec3 d, vec3 s) {
	float R = uRadius;
	float top = R + 12.0 * uHR;
	float h = uEye;
	vec3 o = vec3(0.0, R + h, 0.0);
	float b = dot(o, d);
	float cT = dot(o, o) - top * top;
	float dT = b * b - cT;
	if (dT <= 0.0) return vec4(0.0);
	float t0 = max(-b - sqrt(dT), 0.0);
	float t1 = -b + sqrt(dT);
	if (t1 <= t0) return vec4(0.0);
	float dG = b * b - (dot(o, o) - R * R);
	if (dG > 0.0) {
		float tg = -b - sqrt(dG);
		if (tg > 0.0) t1 = min(t1, tg);
	}
	float mu = dot(d, s);
	float pr = 3.0 / (16.0 * PI) * (1.0 + mu * mu);
	float g = uMieG;
	float pm = (1.0 - g * g) / (4.0 * PI * pow(max(1.0 + g * g - 2.0 * g * mu, 1e-4), 1.5));
	vec3 tau_v = vec3(0.0);
	vec3 L = vec3(0.0);
	float span = t1 - t0;
	float prev = 0.0;
	for (int i = 1; i <= 16; i++) {
		float u = float(i) / 16.0;
		float f = u * u;
		float tm = t0 + span * 0.5 * (f + prev);
		float ds = span * (f - prev);
		prev = f;
		vec3 p = o + d * tm;
		vec3 dn = dens(length(p) - R);
		vec3 step_tau = (uBetaR * dn.x + vec3(uBetaMExt) * dn.y + uBetaO * dn.z) * ds;
		vec3 tr_v = exp(-(tau_v + 0.5 * step_tau));
		vec3 tr = tr_v * exp(-sun_depth(p, s));
		float rp = length(p);
		vec2 uv = vec2(clamp(dot(p, s) / rp * 0.5 + 0.5, 0.0, 1.0), sqrt(clamp((rp - R) / (top - R), 0.0, 1.0)));
		vec3 ms = texture(uMS, (uv * (uMSN - 1.0) + 0.5) / uMSN).rgb;
		L += (tr * (uBetaR * dn.x * pr + vec3(uBetaM) * dn.y * pm) + tr_v * (uBetaR * dn.x + vec3(uBetaM) * dn.y) * ms) * ds;
		tau_v += step_tau;
	}
	return vec4(L * uGain, 1.0 - exp(-dot(tau_v, vec3(0.333))));
}

void vertex() {
	vDir = VERTEX;
}

void fragment() {
	if (uHasAir < 0.5) discard;
	vec3 d = normalize(vDir);
	if (uPhysical > 0.5) {
		vec4 ps = physical_sky(d, normalize(uSunDir));
		// Coverage follows radiance (a sky brighter than ~0.15 hides the stars), but the
		// light itself adds: blend_mix multiplies ALBEDO by ALPHA, so divide it back out
		// and a faint twilight still glows over the stars it barely dims.
		float a = clamp(max(ps.r, max(ps.g, ps.b)) * 6.0, 0.02, 1.0);
		ALBEDO = ps.rgb / a;
		ALPHA = a;
	} else {
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
}
