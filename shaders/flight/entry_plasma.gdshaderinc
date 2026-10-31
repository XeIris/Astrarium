// RE-ENTRY PLASMA, shared by the shock layer (entry_glow) and its wake (entry_wake):
// colour from the gas temperature, the temperature code the colour is weighted by
// (as the other local emitters), and value noise for the turbulence.

// Deep red near 2000 K, red-orange by 3500 K, yellow-orange by 5000 K and blue-white
// above 8000 K: the progression from a shallow entry to a lunar return.
vec3 plasma_colour(float T) {
	vec3 c = mix(vec3(1.0, 0.13, 0.03), vec3(1.0, 0.32, 0.08), smoothstep(2000.0, 3500.0, T));
	c = mix(c, vec3(1.0, 0.66, 0.36), smoothstep(3500.0, 5000.0, T));
	return mix(c, vec3(0.78, 0.86, 1.0), smoothstep(7000.0, 11000.0, T));
}

// The layer's spectrum (PlasmaSpectrum.shader_terms): each emitter's linear sRGB per unit
// power, its power at uShockT relative to the strongest, and its upper level's θ (K).
// uShockT = 0 leaves the ramp above, for gases the spectrum does not cover.
uniform vec3 uLineRGB[9];
uniform vec2 uLineP[9];
uniform float uShockT = 0.0;

// The layer's colour where its gas is at `f` of the stagnation temperature: Boltzmann
// moves each emitter's upper level by e^(θ/T_s − θ/T), the densities held.
vec3 plasma_spectral(float f, float T_ramp) {
	if (uShockT <= 0.0) return plasma_colour(T_ramp);
	float T = uShockT * max(f, 0.3);
	vec3 c = vec3(0.0);
	for (int i = 0; i < 9; i++)
		c += uLineRGB[i] * uLineP[i].x * exp(uLineP[i].y * (1.0 / uShockT - 1.0 / T));
	// Out of gamut: toward white, keeping the hue (PlasmaSpectrum.colour).
	c -= min(0.0, min(c.r, min(c.g, c.b)));
	float m = max(max(c.r, c.g), c.b);
	return m > 0.0 ? c / m : plasma_colour(T_ramp);
}

float plasma_code(float T) { return clamp(log(T) / 25.33, 0.006, 0.984); }

float plasma_hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float plasma_noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(plasma_hash(i), plasma_hash(i + vec3(1, 0, 0)), f.x),
			mix(plasma_hash(i + vec3(0, 1, 0)), plasma_hash(i + vec3(1, 1, 0)), f.x), f.y),
		mix(mix(plasma_hash(i + vec3(0, 0, 1)), plasma_hash(i + vec3(1, 0, 1)), f.x),
			mix(plasma_hash(i + vec3(0, 1, 1)), plasma_hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
