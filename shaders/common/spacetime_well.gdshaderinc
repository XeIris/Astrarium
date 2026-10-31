// The spacetime sheet's depth (sim/spacetime_mesh.gd fills wells). An illustration,
// not an embedding of space: each body's term is summed.
//   w > 0: a mass, depth ∝ its Newtonian potential: z.x·(1/d) outside radius w,
//          the uniform sphere's (3w² − d²)/(2w³) inside.
//   w < 0: a hole of horizon r_s = −w, Flamm's paraboloid z = 2√(r_s(r − r_s)),
//          drawn as its drop below the value at FLAMM_EDGE·r_s. The paraboloid
//          never flattens, so the sheet is level beyond that.
uniform vec4 wells[16];
uniform int wellCount = 0;

const float FLAMM_EDGE = 40.0;

float well_dip(vec2 p) {
	float dip = 0.0;
	for (int i = 0; i < 16; i++) {
		if (i >= wellCount) break;
		float d = distance(p, wells[i].xy);
		float w = wells[i].w;
		if (w < 0.0) {
			float rs = -w;
			float flamm = 2.0 * sqrt(rs * max(min(d, FLAMM_EDGE * rs) - rs, 0.0));
			dip += 2.0 * sqrt(rs * rs * (FLAMM_EDGE - 1.0)) - flamm;
		} else {
			float R = max(w, 1e-6);
			dip += wells[i].z * (d > R ? 1.0 / d : (3.0 * R * R - d * d) / (2.0 * R * R * R));
		}
	}
	return dip;
}
