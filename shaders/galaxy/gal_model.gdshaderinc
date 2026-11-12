// A galaxy's light as its model's mass (sim/galaxy/gal_visual.gd): luminosity density
// in L☉ kpc⁻³ from the disc and the spheroid of the potential, times each one's
// visible-star fraction and light-to-mass ratio. Galaxy-local kpc, Y the axis.

// Miyamoto–Nagai disc: (K, a, b) with K = visible·(M/L)⁻¹·M·b²/4π, M in M☉.
uniform vec3 uDisc = vec3(0.0, 3.0, 0.28);
// Spheroid: (kind, K, p1, p2). kind 0, a power law with a cutoff: K·r^−α·exp(−r²/rc²),
// p1 = α, p2 = rc. kind 1, Hernquist: K·a/(2π r (r + a)³), p1 = a.
uniform vec4 uSphere = vec4(0.0, 0.0, 1.8, 1.9);

float gal_disc_j(vec3 p) {
	float a = uDisc.y;
	float b2 = uDisc.z * uDisc.z;
	float R2 = p.x * p.x + p.z * p.z;
	float zb = sqrt(p.y * p.y + b2);
	float s = a + zb;
	float q = R2 + s * s;
	return uDisc.x * (a * R2 + (a + 3.0 * zb) * s * s) / (q * q * sqrt(q) * zb * zb * zb);
}

float gal_sphere_j(vec3 p) {
	// The cusp is clamped at 1 pc, inside any pixel at the scales it is drawn from.
	float r = max(length(p), 1e-3);
	if (uSphere.x < 0.5) {
		return uSphere.y * pow(r, -uSphere.z) * exp(-r * r / (uSphere.w * uSphere.w));
	}
	float a = uSphere.z;
	return uSphere.y * a / (6.2831853 * r * pow(r + a, 3.0));
}
