// Exhaust smoke as a column, shared by the plume's own smoke (plume.gdshader) and the
// trail it hands over to (smoke_trail.gdshader), so the two are one medium where they
// meet: the same profile, the same noise at the same scale, the same light.
// Plume.apply_smoke_light sets the uniforms. See docs/physics/plumes.md#the-trail.
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);   // local frame, toward the sun
uniform vec3 uSun = vec3(1.0);                // its light on the smoke
uniform vec3 uSky = vec3(0.22, 0.28, 0.39);   // skylight from above
uniform vec3 uGround = vec3(0.1, 0.09, 0.07); // bounce from below
uniform sampler3D uSmokeNoise : filter_linear, repeat_enable;   // tiling, ~4 features a tile

// Light scattered toward the eye per unit albedo, `od` the optical depth toward the
// sun. `cosv` is the cosine between the view ray and the sun direction; `up` the side
// of the column facing the sky (−1..1). Henyey–Greenstein g = 0.55, mixed 70:30 with
// isotropic, as in smoke_volume.gdshader. Smoke is optically thick: light scattered
// many times reaches deeper than the direct beam, so a second, weaker and more
// forgiving term carries it (Wrenninge's octaves, a = b = 0.4).
vec3 smoke_light(float od, float cosv, float up) {
	float g2 = 0.3025;
	float hg = (1.0 - g2) / pow(1.0 + g2 - 1.1 * cosv, 1.5);
	float sun = exp(-od) * mix(1.0, hg, 0.7) + 0.4 * exp(-0.4 * od);
	return uSun * sun * 0.75 + mix(uGround, uSky, 0.5 + 0.5 * up);
}

// Path from radial offset `r` toward the sun inside a cylinder of radius `A`. `r` and
// `s` are perpendicular to the axis; `s` is the unit sun direction's perpendicular part.
// A sun along the axis looks down the column: capped at four radii.
float tube_chord(vec3 r, vec3 s, float A) {
	float ss = dot(s, s);
	if (ss < 1e-4) return 4.0 * A;
	float b = dot(r, s);
	float h = b * b - ss * (dot(r, r) - A * A);
	if (h <= 0.0) return 0.0;
	h = sqrt(h);
	return clamp((-b + h) / ss - max((-b - h) / ss, 0.0), 0.0, 4.0 * A);
}

// The column's optical depth toward the sun from radial offset `r`: its mean
// extinction inside one radius scale, K / (2a²), along that chord.
float column_sun_od(vec3 r, vec3 s, float a, float K) {
	return 0.5 * K / (a * a) * tube_chord(r, s, a);
}

// Noise with features about `L` metres across, in air-fixed metres `q`: the two
// power-of-two octaves either side of L, cross-faded and restored to full contrast,
// so features grow with the column without the pattern sliding. Periodic in q over
// 8·2¹¹ m (Plume.SmokeColumn.AIR_WRAP).
float smoke_octave(vec3 q, float k) {
	// Each octave keeps its own offset whichever pair it is in, or the pattern jumps
	// where the column's width crosses a power of two.
	return texture(uSmokeNoise, q / (4.0 * exp2(k)) + fract(k * 0.618034)).r;
}
float smoke_noise(vec3 q, float L) {
	float lk = log2(max(L, 0.05));
	float k = floor(lk);
	float f = lk - k;
	float n = mix(smoke_octave(q, k), smoke_octave(q, k + 1.0), f);
	return 0.5 + (n - 0.5) / sqrt((1.0 - f) * (1.0 - f) + f * f);
}

// Extinction, 1/m, at distance `r` from the axis of a column of radius scale `a` (m)
// holding K (τ·m) of smoke per metre, at air-fixed point `q`. Large lobes push the
// edge in and out; the detail is looked up through them (domain warping), so it curls
// round the lobes instead of sitting on a grid. The edge reaches 1.85 a.
float column_sigma(vec3 q, float r, float a, float K, bool fine) {
	float x = r / a;
	if (x > 1.9 || K <= 0.0) return 0.0;
	float lobe = smoke_noise(q, 2.2 * a);
	float body = smoothstep(1.2, 0.45, x + (lobe - 0.5) * 1.3);
	if (body <= 0.0) return 0.0;
	vec3 w = q + (lobe - 0.5) * a * vec3(1.6, -1.1, 0.9);
	float det = smoke_noise(w, 0.8 * a);
	// A finer octave mixed in at full contrast, so it adds detail, not density.
	if (fine) det = 0.5 + (mix(det, smoke_noise(w * 1.7 + 3.1, 0.3 * a), 0.35) - 0.5) * 1.35;
	// Half-density radius 0.82 a: the same smoke per metre whatever the column's width.
	float Rs = 0.82 * a;
	return K * body * (0.3 + 2.1 * det * det) / (2.0 * Rs * Rs);
}
