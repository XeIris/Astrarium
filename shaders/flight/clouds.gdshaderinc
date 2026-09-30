// THE CLOUD FIELD — shared by the cloud pass, the ground (its shadows) and the
// sun (its occlusion). Density only; the lighting is the cloud pass's.
// A cloud is a region of air past its dew point, and what that looks like is
// set by two scales: the WEATHER (tens of kilometres — where there is cloud
// at all) and the CONVECTION inside it (a few hundred metres to a few
// kilometres — the individual turrets of a cumulus). The field is built the
// way the production real-time systems build it (Schneider's Nubis for
// Horizon Zero Dawn, Hillaire's for Frostbite):
//
//   coverage  a low-frequency field that says how much of the sky is cloud
//             here, raised and lowered around the global coverage
//   profile   how a cumulus fills its layer with height: a FLAT base, because
//             the base is the lifting condensation level and is the same
//             height everywhere, and a rounded top that narrows as the parcel
//             runs out of buoyancy
//   shape     billowed low-frequency noise (Perlin warped by inverted Worley,
//             which is what makes it read as cauliflower rather than smoke);
//             a sample is cloud where shape × profile beats (1 − coverage)
//   erosion   high-frequency Worley taken OFF the edges only, where a real
//             cloud is evaporating into dry air — which is why a cumulus has
//             a crisp edge and a soft one at once
//
// WHERE THE NOISE LIVES. Local space's origin follows the vehicle, so noise
// sampled in local coordinates slides along with it — a cloud field that rides
// with the rocket is the one thing that most obviously says "painted". So every
// sample is taken at its PLANET-FIXED position: local → the planet's rotating
// frame (uLocalToPlanet, carried round with the planet's spin), measured from
// the planet's centre. That is 6.4e6 m in float32, resolved to half a metre,
// which is far below any structure a cloud has; and it means there is no seam,
// no re-anchoring, and the same cumulus is over the same field from the pad
// and from orbit.
//
// Altitude is the exact |p| − R of that position, not a flat-earth y, so the
// layer bends down over the horizon the way the ground patch does.

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

// MIP LEVEL FROM FOOTPRINT. Inside a march there are no useful screen
// derivatives — the neighbouring pixel's sample is at a different, jittered
// distance — so the level is chosen from what one pixel covers at this range
// (`fp`, metres) against the volume's texel. Without it the erosion, which is
// 17 m per texel, aliases into glitter on every deck more than ten km off:
// detail finer than a pixel is not detail.
float cloud_lod(float fp, float tile, float texels) {
	return max(log2(fp * texels / tile), 0.0);
}

// COVERAGE at a planet-fixed point: how much of the sky is cloud here, from
// the weather and the synoptic systems round the global coverage, thinned
// over the pad. Split out of the density because it is the slowly varying
// part — tens to hundreds of km — and a march seen from the upper atmosphere
// can evaluate it once every few km instead of at every sample (see
// uCovReuse in clouds.gdshader). Evaluated at every sample, as everything
// but that march does, the result is exactly what it always was.
float cloud_coverage(vec3 pp, float fp) {
	vec3 q = pp + uCloudWind;
	// WEATHER: 40 km cells of more and less cloud round the global coverage,
	// so the sky is not the same everywhere you look.
	float weather = textureLod(uCloudShape, q * (1.0 / 41000.0) + vec3(0.31, 0.17, 0.83),
		cloud_lod(fp, 41000.0, 96.0)).r;
	// and SYNOPTIC SYSTEMS, several hundred km across — fronts and clear
	// highs. Seen from orbit a single 40 km weather tile repeats across the
	// whole disc like wallpaper; this is what makes it a planet's weather.
	float synoptic = textureLod(uCloudShape, q * (1.0 / 420000.0) + vec3(0.71, 0.43, 0.05),
		cloud_lod(fp, 420000.0, 96.0)).r;
	float cov = clamp(uCloudCoverage + (weather - 0.5) * 0.9 + (synoptic - 0.5) * 1.3, 0.0, 1.0);
	// LAUNCH COMMIT CRITERIA. A rocket climbing through a cumulus can trigger
	// lightning down its own exhaust (Apollo 12 was struck twice), so the
	// flight rules forbid launching within a few miles of one. So the sky
	// over the pad on launch day is the sky a launch was allowed in: the
	// field is thinned round the site rather than every launch being flown out
	// of cloud shadow.
	if (uClearR > 0.0)
		cov *= mix(0.2, 1.0, smoothstep(uClearR * 0.35, uClearR * 1.4, distance(pp, uClearAt)));
	return cov;
}

// Density at a planet-fixed point, as an extinction coefficient (1/m), given
// the coverage there. `detail` (0..1) weights the erosion: the light march
// and the shadows only need the bulk of the cloud, and it is the most
// expensive fetch. `fp` is the pixel footprint in metres at this sample, for
// the mip level.
float cloud_density_cov(vec3 pp, float detail, float fp, float cov) {
	float hf = cloud_hfrac(pp);
	if (hf <= 0.0 || hf >= 1.0 || uCloudCoverage <= 0.0) return 0.0;
	vec3 q = pp + uCloudWind;
	// PROFILE: a flat base in the first 6% of the layer, a top that rounds
	// off over the upper half — narrower where the weather is thinner, so
	// fair-weather cumulus are squat and the big ones tower.
	float top = mix(0.45, 1.0, clamp(cov * 1.3 - 0.1, 0.0, 1.0));
	float profile = smoothstep(0.0, 0.06, hf) * (1.0 - smoothstep(top * 0.55, top, hf));
	// SHAPE: Perlin, lifted where the big inverted-Worley cells are, which
	// is what bunches it into separate billowed turrets.
	// turned against the weather grid, so the two tilings never line up
	vec3 s = CLOUD_TURN * q * (1.0 / 6200.0);
	float perlin = textureLod(uCloudShape, s, cloud_lod(fp, 6200.0, 96.0)).r;
	float worley = textureLod(uCloudWorley, s * 0.9 + vec3(0.5, 0.2, 0.7), cloud_lod(fp, 6900.0, 64.0)).r;
	float shape = cloud_remap(perlin, -(1.0 - worley) * 0.9, 1.0, 0.0, 1.0);
	float d = cloud_remap(shape * profile, 1.0 - cov, 1.0, 0.0, 1.0);
	if (d <= 0.0) return 0.0;
	// EROSION, stronger toward the base where the cloud is wispier and
	// weaker in the turrets, and only where the cloud is thin already.
	// Faded out with range, before its own mip level is a blur of grey —
	// and not FETCHED once it has faded, which from altitude is always.
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

// Optical depth from a local point toward `dir` through the layer — `n`
// samples on a geometric progression from `first` metres, which puts the
// resolution where the cloud's own self-shadowing is. `fp` is the footprint
// of the pixel the march is for: a light sample for a cloud 200 km away does
// not need, and should not fetch, the volume's finest mip.
// `cov` < 0 reads the coverage at every sample; otherwise it is the coverage
// to use throughout — the light march is a few km at most, and the coverage
// varies over tens.
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

// The (at most two) distances along a ray from `ro` (local) at which it
// crosses the sphere of radius uPlanetR + h, measured from the planet centre.
// Computed about the camera's own offset so the big numbers cancel first.
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
