// THE CLOUD FIELD, shared by the cloud pass, the ground (shadows) and the sun
// (occlusion). Density only. Built as Nubis (Schneider) and Frostbite (Hillaire) do:
//   coverage  low-frequency: how much of the sky is cloud here
//   profile   a flat base (the lifting condensation level) and a rounded top
//   shape     Perlin warped by inverted Worley (cauliflower, not smoke); cloud where
//             shape × profile beats (1 − coverage)
//   erosion   high-frequency Worley off the edges only
// Samples are planet-fixed (uLocalToPlanet), measured from the planet's centre, so
// clouds don't ride with the vehicle (6.4e6 m in float32 is half a metre). Altitude
// is |p| − R, so the layer curves over the horizon. sim/flight/cloudfield.gd must
// match this sample for sample. Rendering: docs/physics/clouds.md.

uniform sampler3D uCloudShape : filter_linear_mipmap, repeat_enable;    // Perlin fbm
uniform sampler3D uCloudWorley : filter_linear_mipmap, repeat_enable;   // inverted Worley, large cells
uniform sampler3D uCloudDetail : filter_linear_mipmap, repeat_enable;   // inverted Worley fbm, small
uniform float uCloudCoverage = 0.0;       // 0 = clear, 1 = overcast
uniform float uCloudBase = 1500.0;        // m above the datum
uniform float uCloudTop = 4200.0;
uniform float uCloudSigma = 0.045;        // extinction at full density, 1/m
uniform mat3 uLocalToPlanet;              // local frame → planet-fixed rotating frame
uniform float uPlanetR = 6.371e6;         // radius of the altitude datum, m
uniform vec3 uCloudWind = vec3(0.0);      // planet-fixed displacement of the air, m
uniform vec3 uClearAt = vec3(0.0);        // planet-fixed: the launch site
uniform float uClearR = 0.0;              // how far round it the sky is thinned, m

// A fixed 40° turn about (1, 1, 1): the turret noise is sampled in a frame
// rotated against the weather's, so their tile boundaries never coincide.
const mat3 CLOUD_TURN = mat3(vec3(0.843228, 0.450325, -0.293553), vec3(-0.293553, 0.843228, 0.450325), vec3(0.450325, -0.293553, 0.843228));

// Everything below takes a point in the LOCAL frame (metres, y up, origin on
// the datum under the vehicle) and works in the planet-fixed frame from there.
vec3 cloud_planet(vec3 local) {
	return uLocalToPlanet * vec3(local.x, local.y + uPlanetR, local.z);
}

float cloud_remap(float v, float lo, float hi, float a, float b) {
	return a + (v - lo) * (b - a) / max(hi - lo, 1e-5);
}

// The layer's height fraction, 0 at the base and 1 at the top.
float cloud_hfrac(vec3 pp) {
	return (length(pp) - uPlanetR - uCloudBase) / (uCloudTop - uCloudBase);
}

// Mip level from the pixel footprint `fp` (m) against the texel, since march samples
// have no useful screen derivatives. Otherwise the 17 m erosion glitters at range.
float cloud_lod(float fp, float tile, float texels) {
	return max(log2(fp * texels / tile), 0.0);
}

// COVERAGE at a planet-fixed point (weather plus synoptic systems, thinned over the
// pad). Split out because it varies over tens of km, so a march from above can reuse
// it (uCovReuse).
float cloud_coverage(vec3 pp, float fp) {
	vec3 q = pp + uCloudWind;
	// WEATHER: 40 km cells of more and less cloud round the global coverage,
	// so the sky is not the same everywhere you look.
	float weather = textureLod(uCloudShape, q * (1.0 / 41000.0) + vec3(0.31, 0.17, 0.83),
		cloud_lod(fp, 41000.0, 96.0)).r;
	// Synoptic systems several hundred km across, so the 40 km weather tile doesn't
	// repeat like wallpaper from orbit.
	float synoptic = textureLod(uCloudShape, q * (1.0 / 420000.0) + vec3(0.71, 0.43, 0.05),
		cloud_lod(fp, 420000.0, 96.0)).r;
	float cov = clamp(uCloudCoverage + (weather - 0.5) * 0.9 + (synoptic - 0.5) * 1.3, 0.0, 1.0);
	// Launch commit criteria forbid launching near cumulus (Apollo 12 was struck), so
	// the field is thinned round the site.
	if (uClearR > 0.0)
		cov *= mix(0.2, 1.0, smoothstep(uClearR * 0.35, uClearR * 1.4, distance(pp, uClearAt)));
	return cov;
}

// Density (extinction, 1/m) given the coverage. `detail` (0..1) weights the
// erosion; `fp` is the footprint in metres, for the mip level.
float cloud_density_cov(vec3 pp, float detail, float fp, float cov) {
	float hf = cloud_hfrac(pp);
	if (hf <= 0.0 || hf >= 1.0 || uCloudCoverage <= 0.0) return 0.0;
	vec3 q = pp + uCloudWind;
	// PROFILE: flat base in the first 6%, a top rounding off over the upper half; squat
	// where the weather is thin, towering where it isn't.
	float top = mix(0.45, 1.0, clamp(cov * 1.3 - 0.1, 0.0, 1.0));
	float profile = smoothstep(0.0, 0.06, hf) * (1.0 - smoothstep(top * 0.55, top, hf));
	// SHAPE: Perlin lifted by big inverted-Worley cells into turrets, turned against the
	// weather grid so the tilings don't align.
	vec3 s = CLOUD_TURN * q * (1.0 / 6200.0);
	float perlin = textureLod(uCloudShape, s, cloud_lod(fp, 6200.0, 96.0)).r;
	float worley = textureLod(uCloudWorley, s * 0.9 + vec3(0.5, 0.2, 0.7), cloud_lod(fp, 6900.0, 64.0)).r;
	float shape = cloud_remap(perlin, -(1.0 - worley) * 0.9, 1.0, 0.0, 1.0);
	float d = cloud_remap(shape * profile, 1.0 - cov, 1.0, 0.0, 1.0);
	if (d <= 0.0) return 0.0;
	// EROSION, stronger toward the base and only where the cloud is thin; faded with
	// range and not fetched once faded.
	float k = detail * (1.0 - smoothstep(8.0, 40.0, fp));
	if (k > 0.0) {
		float e = textureLod(uCloudDetail, q * (1.0 / 820.0), cloud_lod(fp, 820.0, 48.0)).r;
		e = mix(e, 1.0 - e, clamp(hf * 4.0, 0.0, 1.0));
		d = cloud_remap(d, e * 0.42 * k, 1.0, 0.0, 1.0);
		if (d <= 0.0) return 0.0;
	}
	// density ramps up over the lower third, so bases are not a hard sheet
	return d * smoothstep(0.0, 0.3, hf + 0.1) * uCloudSigma;
}

float cloud_density_fp(vec3 pp, float detail, float fp) {
	float hf = cloud_hfrac(pp);
	if (hf <= 0.0 || hf >= 1.0 || uCloudCoverage <= 0.0) return 0.0;
	return cloud_density_cov(pp, detail, fp, cloud_coverage(pp, fp));
}

float cloud_density_pp(vec3 pp, bool detail) {
	return cloud_density_fp(pp, detail ? 1.0 : 0.0, 0.0);
}

float cloud_density(vec3 local, bool detail) {
	return cloud_density_pp(cloud_planet(local), detail);
}

// Optical depth from a local point toward `dir`: `n` geometric samples from `first`
// metres. `fp` is the pixel's footprint. `cov` < 0 reads coverage per sample,
// otherwise it is used throughout.
float cloud_optical_depth_fp(vec3 local, vec3 dir, int n, float first, float fp, float cov) {
	float od = 0.0;
	float t = 0.0;
	float ds = first;
	for (int i = 0; i < n; i++) {
		t += ds * 0.5;
		vec3 pp = cloud_planet(local + dir * t);
		od += (cov < 0.0 ? cloud_density_fp(pp, 0.0, fp) : cloud_density_cov(pp, 0.0, fp, cov)) * ds;
		t += ds * 0.5;
		ds *= 2.0;
	}
	return od;
}

float cloud_optical_depth(vec3 local, vec3 dir, int n, float first) {
	return cloud_optical_depth_fp(local, dir, n, first, 0.0, -1.0);
}

// The ray's crossings of the sphere of radius uPlanetR + h, computed about the
// camera's offset so the big numbers cancel first.
vec2 cloud_sphere(vec3 ro, vec3 rd, float h) {
	vec3 c = vec3(ro.x, ro.y + uPlanetR, ro.z);
	float r = uPlanetR + h;
	float b = dot(c, rd);
	// |c|² − r² as (|c| − r)(|c| + r): the difference is small, the sum is not
	float lc = length(c);
	float cc = (lc - r) * (lc + r);
	float disc = b * b - cc;
	if (disc < 0.0) return vec2(-1.0);
	float s = sqrt(disc);
	return vec2(-b - s, -b + s);
}
