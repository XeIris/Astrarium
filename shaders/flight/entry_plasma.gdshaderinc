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
