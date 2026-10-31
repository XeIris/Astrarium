// Matches sim/suns.gd's apply_suns() (MAX_SUNS = 4). Colours arrive linear
// (Stellar.blackbody_color or U.lin), so no source_color hint.
uniform vec3 uSunDir[4];
uniform vec3 uSunColor[4];
uniform float uSunInt[4];
uniform int uSunCount = 0;

// Eclipses (Suns.apply_occluders): bodies that can stand between this one and a star,
// at their true size and distance, in units of this body's true radius and on world
// axes, so a magnified render never casts a magnified shadow.
uniform vec4 uOcc[4];
uniform float uOccRed[4];
uniform int uOccCount = 0;
uniform float uSunAng[4];

// Planetshine (Suns.apply_shine): the brightest sunlit neighbour as a weak extra light,
// world axes, linear colour, intensity already at its display gain.
uniform vec3 uShineDir = vec3(1.0, 0.0, 0.0);
uniform vec3 uShineColor = vec3(1.0);
uniform float uShineInt = 0.0;

// Fraction of a disc of angular radius a left uncovered by a disc of radius b whose
// centre is d away (flat-sky circle overlap).
float disc_uncovered(float a, float b, float d) {
	if (d >= a + b) return 1.0;
	if (d <= abs(a - b)) return b >= a ? 0.0 : 1.0 - (b * b) / (a * a);
	float c1 = clamp((d * d + a * a - b * b) / (2.0 * d * a), -1.0, 1.0);
	float c2 = clamp((d * d + b * b - a * a) / (2.0 * d * b), -1.0, 1.0);
	float k = (-d + a + b) * (d + a - b) * (d - a + b) * (d + a + b);
	float lens = a * a * acos(c1) + b * b * acos(c2) - 0.5 * sqrt(max(k, 0.0));
	return clamp(1.0 - lens / (PI * a * a), 0.0, 1.0);
}

// Star i's light at surface point n (unit, world axes, from this body's centre): the
// uncovered share of its disc (umbra and penumbra; the star's own limb darkening is
// ignored), plus the sunset-red light an occluder's atmosphere refracts into its umbra.
vec3 eclipse(int i, vec3 n) {
	float vis = 1.0;
	float red = 0.0;
	vec3 L = normalize(uSunDir[i]);
	float s = max(uSunAng[i], 1e-7);
	for (int j = 0; j < 4; j++) {
		if (j >= uOccCount) break;
		vec3 v = uOcc[j].xyz - n;
		float dist = length(v);
		if (dist <= uOcc[j].w || dot(v, L) <= 0.0) continue;
		float rho = asin(min(uOcc[j].w / dist, 1.0));
		// atan2 keeps arc-second separations that acos would round away
		float th = atan(length(cross(v / dist, L)), dot(v / dist, L));
		float f = disc_uncovered(s, rho, th);
		vis *= f;
		red = max(red, uOccRed[j] * (1.0 - f));
	}
	// Earth's umbra passes ~1e-4 of sunlight, reddened by its limb; raised ×100 here so
	// a totally eclipsed Moon reads at the full Moon's exposure (docs/physics/sky.md#eclipses).
	return vec3(vis) + red * vec3(0.9, 0.28, 0.08) * 0.012;
}
