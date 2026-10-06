// The procedural sky, resolution-free and band-aware. Derivation:
// docs/physics/sky.md; CPU half: sim/sky.gd, whose defaults equal the ones here.
// Included by background.gdshader (colour) and background_temp.gdshader
// (temperature pass), both `shader_type sky`, where dFdx/dFdy work.
//
// gdshader has no mutable globals, so the observer's Doppler factor is explicit:
//   vec3  sky_aberrate(vec3 dir)          rest-frame direction
//   float sky_doppler(vec3 dir)           D for ship-frame direction dir
//   vec3  skyRadianceD(dir, ddx, ddy, D)  radiance at that D
//   vec3  skyRadiance(dir, ddx, ddy)      == skyRadianceD(..., 1.0), for the lens resolve
//   float sky_beaming(float D)            D^4
// The backdrop reads  rd = sky_aberrate(d); D = sky_doppler(d);
//                     skyRadianceD(rd, dFdx(rd), dFdy(rd), D) * sky_beaming(D)

// ---- uniforms --------------------------------------------------------------
uniform vec3  uGalNormal = vec3(0.2798740849862627, 0.929581782275801, 0.23989207284536798);  // unit normal of the galactic plane
uniform vec3  uGalCenter = vec3(0.910455341534624, -0.2201100825688102, 0.35017513135947076); // unit direction toward the galactic centre
uniform vec3  uGalEast = vec3(0.0, 0.0, 1.0);    // completes the frame; longitude runs toward it

uniform float uVisibleBand = 1.0;  // 1.0 in the visible band, 0.0 otherwise
uniform float uTheta = 0.0;        // h*nu/k for the current band, in kelvin
uniform float uThetaVis = 0.0;     // the same for the visible band (the reference)
uniform float uNuRatio3 = 1.0;     // (nu / nu_visible)^3
uniform float uExtCoef = 1.0;      // dust extinction, relative to the visible
uniform float uSkyGain = 1.0;
uniform float uStarGain = 1.0;

uniform float uStarFlux = 2.2e-4;  // flux of a tier-0 star, in radiance*steradian
uniform float uStarDensity = 0.70; // stars per cell, before plane concentration
uniform float uPlaneConc = 2.2;    // how much the band crowds stars toward itself
uniform float uPsfPx = 1.25;       // instrument PSF width, in pixels
uniform float uPixAngle = 8.7e-4;  // unlensed angular size of one pixel, radians
uniform float uSpikes = 1.0;       // diffraction spikes on the brightest stars

uniform float uGlow = 1.0;
uniform float uBulge = 1.0;
uniform float uDust = 1.0;
uniform float uHii = 1.0;
uniform float uRefl = 1.0;
uniform float uGalaxies = 1.0;
uniform float uBandScaleH = 0.055;
uniform float uBulgeSize = 0.30;

// per-component band weights, set from the tables in sim/sky.gd
uniform float uwSynch = 0.0;
uniform float uwH21 = 0.0;
uniform float uwCmb = 0.0;
uniform float uwDustEm = 0.0;
uniform float uwGlow = 1.0;
uniform float uwBulge = 1.0;
uniform float uwHii = 1.0;
uniform float uwRefl = 1.0;
uniform float uwGalaxies = 1.0;
uniform float uwXrayBg = 0.0;
uniform float uwPion = 0.0;
uniform float uwSnr = 0.0;
uniform float uwPulsar = 0.0;
uniform float uwXrb = 0.0;
uniform float uwBlazar = 0.0;

// Observer velocity/c in world coordinates; nonzero only in interstellar cruise.
uniform vec3 uBeta = vec3(0.0);

// Cube-face atlas of the diffuse emission (rgb) and dust depth (a), rendered by
// render/sky_cache.gd. Face size in texels; 0 evaluates them live.
uniform sampler2D uSkyCache : filter_linear, repeat_disable;
uniform float uSkyCacheFace = 0.0;
// Checks evaluate every neighbour cell to prove the point-source cull is exact.
uniform bool uSkyExhaustive = false;

/**
 * Alpha sentinel meaning "this pixel is sky, already imaged in the current
 * band - do not infer a temperature, do not apply a Planck ratio". The value
 * and its reasoning are SkyModel.SKY_ALPHA's (sim/sky.gd).
 */
const float SKY_ALPHA = 0.995;

#define SKY_PI 3.141592653589793
// Six magnitude bins of resolved stars, then glow: a confusion limit near mag 8.
#define SKY_TIERS 6

// Band-weight cull thresholds. A W weight is also a predicate: a component that
// can't survive the band's display scale is skipped (a uniform branch, so no
// divergence). Both are measured, not chosen by eye:
//   visible   ACES against bright stars: culling below 0.03 changes 0 of 921600
//             pixels at 1280x720
//   all else  the remap's log stretch lifts faint values, so the floor sits under
//             the smallest intended weight (0.01): 0.005 is pixel-identical, 0.05
//             visibly damages all four non-visible bands
#define SKY_W_EPS_VIS 0.03
#define SKY_W_EPS_LOG 0.005

// Godot re-prints float constants in fixed notation, so literals below ~1e-14
// reach the GPU as 0.0. Spell floors as bit patterns, or a degenerate Jacobian on
// photon-ring pixels divides by zero and the bloom spreads the NaNs.
#define SKY_1E_16 uintBitsToFloat(0x24e69595u)   // 1e-16
#define SKY_1E_24 uintBitsToFloat(0x179abe15u)   // 1e-24
#define SKY_1E_30 uintBitsToFloat(0x0da24260u)   // 1e-30

// Diffuse layers come from the cache only below 4x magnification; the photon ring
// keeps evaluating them, since no fixed resolution survives it.
#define SKY_CACHE_MIN_W2 0.25

// smoothstep with reversed edges, written out: the spec leaves it undefined, and
// this is what WebGL/ANGLE evaluates. It sets the star-tier LOD boundary.
float sky_hermite(float e0, float e1, float x){
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// ---- hashing: three independent streams from one 3-vector.
vec3 sky_hash33(vec3 p_in){
	vec3 p = fract(p_in * vec3(0.1031, 0.1030, 0.0973));
	p += dot(p, p.yxz + 33.33);
	return fract((p.xxy + p.yxx) * p.zyx);
}
float sky_hash13(vec3 p_in){
	vec3 p = fract(p_in * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float sky_vnoise(vec3 p){
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(sky_hash13(i + vec3(0.0, 0.0, 0.0)), sky_hash13(i + vec3(1.0, 0.0, 0.0)), f.x),
	               mix(sky_hash13(i + vec3(0.0, 1.0, 0.0)), sky_hash13(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
	           mix(mix(sky_hash13(i + vec3(0.0, 0.0, 1.0)), sky_hash13(i + vec3(1.0, 0.0, 1.0)), f.x),
	               mix(sky_hash13(i + vec3(0.0, 1.0, 1.0)), sky_hash13(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}
float sky_fbm(vec3 p_in, int oct){
	vec3 p = p_in;
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 6; i++) {
		if (i >= oct) break;
		v += a * sky_vnoise(p); p = p * 2.07 + 13.7; a *= 0.5;
	}
	return v;
}

// ---- relativistic aberration. A source at θ' from the direction of travel was at
//     cos θ = (cos θ' − β) / (1 − β cos θ')
// in the rest frame (at γ = 10 everything visible is within ~11° ahead), with
//     D = 1 / (γ (1 − β cos θ')).
// Stars are coloured from temperature, so T·D is exact. Bolometric intensity goes
// as D^4 (sky_beaming). Applied before the caller's screen derivatives, so the
// point-source machinery picks up the change in solid angle.
vec3 sky_aberrate(vec3 dir){
	float b = length(uBeta);
	if (b < 1e-6) return dir;
	vec3 bh = uBeta / b;
	float mu = dot(dir, bh);               // cos theta' in the ship frame
	// rest-frame cosine, and the component perpendicular to the boost is rescaled
	// to keep the direction a unit vector.
	float mu0 = (mu - b) / (1.0 - b * mu);
	vec3 perp = dir - bh * mu;
	float pl = length(perp);
	if (pl < 1e-9) return bh * sign(mu0 == 0.0 ? 1.0 : mu0);
	return normalize(bh * mu0 + (perp / pl) * sqrt(max(1.0 - mu0 * mu0, 0.0)));
}

// D = 1 / (gamma (1 - beta cos theta')) for the ship-frame direction `dir`.
float sky_doppler(vec3 dir){
	float b = length(uBeta);
	if (b < 1e-6) return 1.0;
	vec3 bh = uBeta / b;
	float mu = dot(dir, bh);
	float gamma = 1.0 / sqrt(max(1.0 - b * b, 1e-12));
	return 1.0 / (gamma * (1.0 - b * mu));
}

// Bolometric brightening: I' = D^4 I.
float sky_beaming(float D){ return D * D * D * D; }

// ---- Planck ----------------------------------------------------------------
// Same fit as the lens marcher's, kept local to avoid a name collision.
vec3 sky_blackbody(float T_in, float D){
	// A blackbody at T seen through D is a blackbody at T·D.
	float T = clamp(T_in * D, 800.0, 42000.0);
	float t = T * 0.01;
	vec3 c;
	c.r = t <= 66.0 ? 255.0 : 329.698727446 * pow(max(t - 60.0, 1e-3), -0.1332047592);
	c.g = t <= 66.0 ? 99.4708025861 * log(t) - 161.1195681661
	                : 288.1221695283 * pow(max(t - 60.0, 1e-3), -0.0755148492);
	c.b = t >= 66.0 ? 255.0
	    : (t <= 19.0 ? 0.0 : 138.5177312231 * log(max(t - 10.0, 1e-3)) - 305.0447927307);
	c = clamp(c / 255.0, 0.0, 1.0);
	return pow(c, vec3(2.2));
}

// ln(exp(u) - 1), stable over the ~14 decades of u the bands demand. At 0.3 keV
// off a 6000 K star u is about 1750, and exp(u) is inf on the first line.
float sky_lnExpm1(float u){
	if (u > 20.0) return u;
	if (u < 1e-4) return log(max(u, SKY_1E_30));
	return log(exp(u) - 1.0);
}

// A star's flux in this band relative to the visible:
//     F_nu / F_vis = (nu/nu_vis)^3 · (exp(theta_vis/T) − 1) / (exp(theta/T) − 1)
// The ν³ prefactor doesn't cancel for a point source; it removes stars from the radio.
float sky_starBand(float T_in){
	if (uVisibleBand > 0.5) return 1.0;
	float T = max(T_in, 1.0);
	float ln = log(uNuRatio3)
	         + sky_lnExpm1(uThetaVis / T)
	         - sky_lnExpm1(uTheta / T);
	return exp(clamp(ln, -80.0, 12.0));
}

// Emission helper: in the visible a component contributes its true colour, in
// every other band a scalar radiance that the false-colour palette will map.
vec3 sky_emit(vec3 col, float bandWeight, float amp){
	return uVisibleBand > 0.5 ? col * amp : vec3(amp * bandWeight);
}

// ---- galactic frame: sin(b) along the plane normal, longitude from the centre
// toward uGalEast.
float sky_sinb(vec3 d){ return dot(d, uGalNormal); }
float sky_lon(vec3 d){ return atan(dot(d, uGalEast), dot(d, uGalCenter)); }

// Disc surface brightness from inside: thin and thick exponential discs in
// latitude, brightening toward the centre in longitude.
float sky_bandProfile(vec3 d){
	float b = abs(sky_sinb(d));
	float thin = exp(-b / max(uBandScaleH, 1e-3));
	// A broad halo around the ridge, or the band reads as a painted stripe.
	float thick = exp(-b / max(uBandScaleH * 5.0, 1e-3)) * 0.45;
	float l = sky_lon(d);
	float toward = 0.35 + 0.65 * exp(-abs(l) / 1.15);
	return (thin + thick) * toward;
}

// The gas profile: a much smaller scale height than the stars, for everything that
// traces gas (synchrotron, 21 cm, dust, the π⁰ ridge). On the stellar profile the
// radio sky becomes a flat wash under the log stretch.
float sky_gasProfile(vec3 d){
	float b = abs(sky_sinb(d));
	float core = exp(-b / max(uBandScaleH * 0.9, 1e-3));
	float halo = exp(-b / max(uBandScaleH * 4.5, 1e-3)) * 0.07;
	float l = sky_lon(d);
	return (core + halo) * (0.4 + 0.6 * exp(-abs(l) / 1.2));
}

// The bulge: a flattened spheroid around the centre direction, wider in
// longitude than in latitude, as a bar seen from inside the disc must be.
float sky_bulgeProfile(vec3 d){
	float b = sky_sinb(d);
	float l = sky_lon(d);
	float q = (l * l) / (uBulgeSize * uBulgeSize)
	        + (b * b) / (uBulgeSize * uBulgeSize * 0.16);
	return exp(-q);
}

// Two-armed spiral modulation in longitude. Cheap, and it keeps the H II
// regions and the young stars from being spread evenly along the band.
float sky_arms(vec3 d){
	return 0.55 + 0.45 * sin(2.0 * sky_lon(d) + 1.1);
}

// ---- dust: optical depth along the ray. Its scale height is ~1/3 of the stars',
// so the lane is a clean dark stripe; the fBm makes dark nebulae.
float sky_dustTau(vec3 d){
	float b = abs(sky_sinb(d));
	float lane = exp(-b / max(uBandScaleH * 0.34, 1e-3));
	// ("patch" is a reserved word in GLSL — tessellation. It compiles nowhere.)
	float veil = sky_fbm(d * 5.5, 4);
	veil = pow(clamp(veil * 1.55 - 0.25, 0.0, 1.0), 1.6);
	float clumps = pow(clamp(sky_fbm(d * 17.0 + 41.0, 3) * 1.7 - 0.45, 0.0, 1.0), 2.0);
	// τ of order 1, not 5, or the lane cancels the band where it is brightest.
	return uDust * lane * (0.55 * veil + 1.15 * clumps) * 0.95;
}

// Extinction as a multiplier: chromatic in the visible (reddening), one coefficient
// elsewhere.
vec3 sky_extinction(float tau){
	if (uVisibleBand > 0.5) return exp(-tau * vec3(0.78, 1.0, 1.38));
	return vec3(exp(-tau * uExtCoef));
}

// ---- cube cells: direction → face and face coordinates in [-1, 1]. No pole
// collapse, no seam.
void sky_cube(vec3 d, out float face, out vec2 fc){
	vec3 a = abs(d);
	if (a.x >= a.y && a.x >= a.z) { face = d.x > 0.0 ? 0.0 : 1.0; fc = vec2(d.y, d.z) / a.x; }
	else if (a.y >= a.z)          { face = d.y > 0.0 ? 2.0 : 3.0; fc = vec2(d.z, d.x) / a.y; }
	else                          { face = d.z > 0.0 ? 4.0 : 5.0; fc = vec2(d.x, d.y) / a.z; }
}
vec3 sky_uncube(float face, vec2 fc){
	if (face < 0.5) return normalize(vec3( 1.0, fc.x, fc.y));
	if (face < 1.5) return normalize(vec3(-1.0, fc.x, fc.y));
	if (face < 2.5) return normalize(vec3(fc.y,  1.0, fc.x));
	if (face < 3.5) return normalize(vec3(fc.y, -1.0, fc.x));
	if (face < 4.5) return normalize(vec3(fc.x, fc.y,  1.0));
	return normalize(vec3(fc.x, fc.y, -1.0));
}

// Equiangular warp (tan(g·π/4)): solid angle per cell within 1.30, the residual
// corrected in the existence probability.
vec2 sky_toGrid(vec2 fc){ return atan(fc) * (4.0 / SKY_PI); }
vec2 sky_fromGrid(vec2 g){ return tan(g * (SKY_PI / 4.0)); }

// Residual solid angle per unit grid area, normalised to 1 at the face centre.
float sky_cellWeight(vec2 fc){
	float s = 1.0 + fc.x * fc.x + fc.y * fc.y;
	return (1.0 + fc.x * fc.x) * (1.0 + fc.y * fc.y) / (s * sqrt(s));
}

// Neighbour offsets (x0, y0, x1, y1) whose sources can lie within `reach` radians
// of a ray at fractional cell position f. The equiangular map spans at least π/6
// radians per grid unit (its smallest singular value, at a face corner); 0.9 covers
// chord and tangent-projection slack. Skipped cells only held rejected sources.
ivec4 sky_neighbours(vec2 f, float cells, float reach){
	if (uSkyExhaustive) return ivec4(-1, -1, 1, 1);
	float span = reach * cells * (3.0 / SKY_PI) / 0.9;
	return ivec4(f.x < span ? -1 : 0, f.y < span ? -1 : 0,
	             1.0 - f.x < span ? 1 : 0, 1.0 - f.y < span ? 1 : 0);
}

// ---- stellar temperature, weighted for a magnitude-limited sample (mostly B/A
// stars and distant giants), not the IMF.
float sky_starTemp(float u_in, float tier){
	// Bright tiers skew hotter still: at a fixed apparent magnitude the brightest
	// entries are drawn from a larger volume, so the bias compounds.
	float u = clamp(u_in - 0.10 * (2.0 - min(tier, 2.0)) * 0.5, 0.0, 0.9999);
	if (u < 0.020) return mix(20000.0, 34000.0, u / 0.020);            // O / early B
	if (u < 0.300) return mix( 9000.0, 20000.0, (u - 0.020) / 0.280);  // B / A
	if (u < 0.550) return mix( 6500.0,  9000.0, (u - 0.300) / 0.250);  // A / F
	if (u < 0.720) return mix( 5200.0,  6500.0, (u - 0.550) / 0.170);  // F / G
	if (u < 0.880) return mix( 3900.0,  5200.0, (u - 0.720) / 0.160);  // K
	return              mix( 3000.0,  3900.0, (u - 0.880) / 0.120);    // M giants
}

// ---- point layer. The PSF lives in the image plane: the star's offset is solved
// in pixels, J p = (sdir − dir) by least squares (2x2 normal equations), and the
// PSF is a fixed Gaussian in p. Normalised through J, L = F·G(p)/w², so the peak
// rises as μ and a lensed star stays a point (docs/physics/sky.md). Core plus a
// faint halo, area-normalised together.
float sky_psf(vec2 p){
	float s2 = uPsfPx * uPsfPx;
	float r2 = dot(p, p);
	float core = exp(-0.5 * r2 / s2) / (6.2831853 * s2);
	float halo = exp(-0.5 * r2 / (9.0 * s2)) / (6.2831853 * 9.0 * s2);
	return 0.86 * core + 0.14 * halo;
}

// Four diffraction spikes on the brightest stars: an instrument signature, straight
// and screen-aligned since they live in pixel space.
float sky_spike(vec2 p){
	if (uSpikes < 0.01) return 0.0;
	float s = uPsfPx * 1.3;
	float arm = exp(-0.5 * p.y * p.y / (s * s)) * exp(-abs(p.x) / (s * 13.0))
	          + exp(-0.5 * p.x * p.x / (s * s)) * exp(-abs(p.y) / (s * 13.0));
	return arm * uSpikes * 0.016 / (6.2831853 * uPsfPx * uPsfPx);
}

// ---- clusters: open (young, blue, loose, in the plane) and globular (old, red,
// tight, in the halo). Returns (density multiplier, temperature bias) for the star loop.
vec2 sky_clusterField(vec3 dir, float face, vec2 g){
	float boost = 0.0;
	float bias = 0.0;
	for (int i = 0; i < 2; i++) {
		float open = float(i);                    // 0 = globular, 1 = open
		float cells = mix(7.0, 11.0, open);
		vec2 cell = floor((g * 0.5 + 0.5) * cells);

		for (int oy = -1; oy <= 1; oy++) {
			for (int ox = -1; ox <= 1; ox++) {
				vec2 cc = cell + vec2(float(ox), float(oy));
				if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
				vec3 h = sky_hash33(vec3(cc + 0.5, face * 31.0 + open * 91.7));
				if (h.x > 0.16) continue;

				vec3 cdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
				// open clusters live in the disc; globulars deliberately do not
				float gate = mix(1.0, sky_bandProfile(cdir), open);
				float rad = mix(0.020, 0.035, open) * (0.5 + h.x * 3.0);
				float d = length(dir - cdir);
				float w = exp(-0.5 * d * d / (rad * rad)) * gate;
				boost += w * mix(14.0, 7.0, open);
				// globulars are metal-poor and old: push the temperature draw toward
				// the K/M end. Open clusters are the reverse, and much more so.
				bias += w * mix(0.28, -0.34, open);
			}
		}
	}
	return vec2(boost, bias);
}

// ---- extended and compact populations. Galaxies are isotropic and seen through
// the whole dust column (the zone of avoidance, and its absence in the IR).
// Extended, so evaluated in source angle; the width clamp to the pixel filter
// makes an unresolved one behave as a point.
float sky_galaxies(vec3 dir, float face, vec2 g, float w2){
	float acc = 0.0;
	float cells = 9.0;
	vec2 cellPos = (g * 0.5 + 0.5) * cells;
	vec2 cell = floor(cellPos);
	// The widest galaxy (2.82e-3 rad) bounds the r2 > 30 sig2 reject below.
	ivec4 nb = sky_neighbours(cellPos - cell, cells, sqrt(30.0) * max(2.82e-3, uPsfPx * sqrt(w2)));

	for (int oy = nb.y; oy <= nb.w; oy++) {
		for (int ox = nb.x; ox <= nb.z; ox++) {
			vec2 cc = cell + vec2(float(ox), float(oy));
			if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
			vec3 h  = sky_hash33(vec3(cc + 0.5, face * 17.0 + 3.7));
			vec3 h2 = sky_hash33(vec3(cc + 0.5, face * 17.0 + 57.1));
			if (h.x > 0.30 * uGalaxies) continue;

			vec3 gdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
			// a few big ones, many small
			float ang = (2.2e-4 + 2.6e-3 * pow(h2.x, 3.0));
			float sig = max(ang, uPsfPx * sqrt(w2));
			vec3 dd = dir - gdir;
			float r2 = dot(dd, dd);
			if (r2 > 30.0 * sig * sig) continue;
			float flux = uStarFlux * 0.15 * (0.25 + h2.y);
			acc += flux * exp(-0.5 * r2 / (sig * sig)) / (6.2831853 * sig * sig);
		}
	}
	return acc;
}

// Compact non-thermal sources (pulsars, XRBs, blazars), in pixel space like stars.
// "plane" gates onto the disc; blazars are extragalactic, so 0.
float sky_compact(vec3 dir, vec3 ddx, vec3 ddy, float ga, float gb, float gc,
                  float gdet, float w2, float reach, float face, vec2 g, float cells, float seed,
                  float plane, float accept, float flux){
	float acc = 0.0;
	vec2 cellPos = (g * 0.5 + 0.5) * cells;
	vec2 cell = floor(cellPos);
	ivec4 nb = sky_neighbours(cellPos - cell, cells, reach);

	for (int oy = nb.y; oy <= nb.w; oy++) {
		for (int ox = nb.x; ox <= nb.z; ox++) {
			vec2 cc = cell + vec2(float(ox), float(oy));
			if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
			vec3 h = sky_hash33(vec3(cc + 0.5, face * 23.0 + seed));
			vec3 sdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
			float gate = mix(1.0, sky_bandProfile(sdir), plane);
			if (h.x > accept * gate) continue;

			vec3 delta = sdir - dir;
			if (dot(delta, delta) > 400.0 * w2 * uPsfPx * uPsfPx) continue;
			float pu = dot(ddx, delta);
			float pv = dot(ddy, delta);
			vec2 p = vec2(gc * pu - gb * pv, ga * pv - gb * pu) / gdet;
			if (dot(p, p) > 64.0) continue;

			// Same flux normalisation as a star: the 1/w2 is what makes these
			// brighten under lensing instead of just moving.
			acc += flux * (0.3 + 2.4 * h.x / max(accept, 1e-4)) * sky_psf(p) / w2;
		}
	}
	return acc;
}

// Supernova remnants: annuli (limb-brightened shells), in source angle.
float sky_snr(vec3 dir, float face, vec2 g, float w2){
	float acc = 0.0;
	float cells = 6.0;
	vec2 cell = floor((g * 0.5 + 0.5) * cells);

	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
			vec2 cc = cell + vec2(float(ox), float(oy));
			if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;
			vec3 h = sky_hash33(vec3(cc + 0.5, face * 11.0 + 77.3));
			vec3 sdir = sky_uncube(face, sky_fromGrid((cc + h.yz) / cells * 2.0 - 1.0));
			if (h.x > 0.22 * sky_bandProfile(sdir)) continue;

			float rad = 0.010 + 0.045 * h.x / 0.22;
			float thick = max(rad * 0.22, uPsfPx * sqrt(w2));
			float d = length(dir - sdir);
			float e = (d - rad) / thick;
			acc += exp(-0.5 * e * e) * (0.6 + 0.8 * sky_fbm(dir * 40.0, 3)) * 0.55;
		}
	}
	return acc;
}

// ---- footprint-independent layers. Diffuse emission and dust ignore the pixel
// Jacobian (docs/physics/sky.md), so they depend on rest-frame direction alone and
// render/sky_cache.gd may sample them from a per-direction cache.

// Dust optical depth, only where something in this band consumes it (not radio or gamma).
float sky_tau(vec3 dir){
	float wEps = uVisibleBand > 0.5 ? SKY_W_EPS_VIS : SKY_W_EPS_LOG;
	if (uVisibleBand > 0.5 || uExtCoef > wEps || uwDustEm > wEps
	    || uwRefl > wEps || uwXrayBg > wEps) return sky_dustTau(dir);
	return 0.0;
}

// Adds the diffuse emission to `total` term by term, behind dust extinction `ext`.
vec3 sky_diffuseAdd(vec3 total_in, vec3 dir, float tau, vec3 ext){
	vec3 total = total_in;
	float wEps = uVisibleBand > 0.5 ? SKY_W_EPS_VIS : SKY_W_EPS_LOG;
	float band  = sky_bandProfile(dir);
	float bulge = sky_bulgeProfile(dir);

	// ---- unresolved starlight: the galactic band itself, behind the same dust.
	float glow = uGlow * band * 0.30;
	total += sky_emit(vec3(0.62, 0.66, 0.85), uwGlow, glow) * ext;

	// The bulge is older and redder than the disc, and it sits behind more dust.
	float bul = uBulge * bulge * 0.22;
	total += sky_emit(vec3(1.00, 0.78, 0.52), uwBulge, bul) * ext * ext;

	// ---- nebulae. H II regions follow the arms; red from H-alpha; absent in X-ray
	// and gamma.
	if (uwHii > wEps) {
		float arms = sky_arms(dir);
		float hiiN = pow(clamp(sky_fbm(dir * 7.3 + 5.0, 4) * 1.9 - 0.62, 0.0, 1.0), 2.1);
		float hii  = uHii * hiiN * band * arms * 0.42;
		total += sky_emit(vec3(1.00, 0.20, 0.26), uwHii, hii) * ext;
	}

	// Reflection nebulae: scattered starlight, blue, only where dust and a hot star meet.
	if (uwRefl > wEps) {
		float reflN = pow(clamp(sky_fbm(dir * 9.1 + 71.0, 3) * 1.8 - 0.70, 0.0, 1.0), 2.0);
		float refl  = uRefl * reflN * clamp(tau, 0.0, 1.4) * band * 0.26;
		total += sky_emit(vec3(0.34, 0.50, 1.00), uwRefl, refl) * ext;
	}

	// ---- non-thermal sky. The remap's log stretch spans ~0.002–0.7, so profiles are
	// sharpened and floors kept small, or the band collapses into a flat wash.
	// The gas column feeds synchrotron and 21 cm.
	float gas = 0.0;
	if (uwSynch > wEps || uwH21 > wEps) gas = sky_gasProfile(dir);

	// Synchrotron: the plane plus a thin North Polar Spur arc.
	if (uwSynch > wEps) {
		float sloop = exp(-pow(abs(length(dir - normalize(uGalNormal * 0.55 + uGalCenter * 0.83)) - 0.62) * 13.0, 2.0));
		float synch = (gas * 2.6 + sloop * 0.30 + 0.0015) * (0.55 + 0.90 * sky_fbm(dir * 3.1, 3));
		total += sky_emit(vec3(0.0), uwSynch, synch * 0.26);
	}

	// Neutral hydrogen, 21 cm: diffuse, filamentary, and everywhere along the plane.
	if (uwH21 > wEps) {
		float h21 = gas * (0.45 + 1.05 * sky_fbm(dir * 6.0 + 31.0, 4));
		total += sky_emit(vec3(0.0), uwH21, h21 * 0.30);
	}

	// The CMB: a uniform floor plus the observer's dipole, kept below the galactic dust.
	// The fBm stands in for 10⁻⁵ anisotropies, exaggerated just enough to avoid a flat fill.
	if (uwCmb > wEps) {
		float dipole = 1.0 + 0.16 * dot(dir, uGalEast);
		float aniso  = 1.0 + 0.22 * (sky_fbm(dir * 12.0 + 3.0, 3) - 0.5);
		total += sky_emit(vec3(0.0), uwCmb, dipole * aniso * 0.06);
	}

	// Thermal dust emission uses the same τ that darkens the visible, so IR lanes land
	// on the dark ones.
	if (uwDustEm > wEps) total += sky_emit(vec3(0.0), uwDustEm, tau * 0.65);

	// π⁰ decay: a thin ridge on the gas column; the gamma sky is nearly empty elsewhere.
	if (uwPion > wEps) {
		float ridge = exp(-abs(sky_sinb(dir)) / max(uBandScaleH * 0.40, 1e-3));
		total += sky_emit(vec3(0.0), uwPion, ridge * 0.45 + 0.0012);
	}

	// Soft X-ray background, shadowed by cold gas (as in ROSAT).
	if (uwXrayBg > wEps) {
		float xbg = (0.55 + 0.35 * sky_fbm(dir * 2.6 + 9.0, 3)) * exp(-tau * 1.4);
		total += sky_emit(vec3(0.0), uwXrayBg, xbg * 0.12);
	}

	return total;
}

// Texel centres sit on face edges, so bilinear filtering never crosses a face.
vec2 sky_cacheUV(float face, vec2 g){
	float n = uSkyCacheFace;
	vec2 origin = vec2(mod(face, 3.0), floor(face / 3.0)) * n;
	return (origin + 0.5 + (g * 0.5 + 0.5) * (n - 1.0)) / vec2(3.0 * n, 2.0 * n);
}


// skyRadianceD / skyRadiance
//   dir      outgoing ray direction, normalised (after lensing)
//   ddx,ddy  its screen derivatives: their cross product is the pixel's source
//            solid angle, and the pair carries the anisotropy
//   D        the observer's Doppler factor (sky_doppler), 1.0 with no boost
vec3 skyRadianceD(vec3 dir, vec3 ddx_in, vec3 ddy_in, float D){
	vec3 total = vec3(0.0);
	vec3 ddx = ddx_in;
	vec3 ddy = ddy_in;

	// Cull threshold for this band's component weights - see SKY_W_EPS_VIS.
	float wEps = uVisibleBand > 0.5 ? SKY_W_EPS_VIS : SKY_W_EPS_LOG;

	// Source solid angle per pixel, clamped by scaling the basis so J stays consistent.
	// The lower cap bounds magnification at ~1000×; the upper stops rays that wind the
	// photon sphere (where the derivative is noise) from blowing up the ring.
	float w2 = max(length(cross(ddx, ddy)), SKY_1E_16);
	float pix2 = max(uPixAngle * uPixAngle, SKY_1E_16);
	float s = 1.0;
	if (w2 < pix2 * 1.0e-3) s = sqrt(pix2 * 1.0e-3 / w2);
	if (w2 > pix2 * 144.0)  s = sqrt(pix2 * 144.0 / w2);
	ddx *= s; ddy *= s; w2 *= s * s;

	// Normal equations for the least-squares pixel offset, hoisted out of the
	// star loop: p = (JtJ)^-1 Jt delta.
	float ga = dot(ddx, ddx);
	float gb = dot(ddx, ddy);
	float gc = dot(ddy, ddy);
	float gdet = max(ga * gc - gb * gb, SKY_1E_24);

	// Characteristic source-plane radius of the PSF, used only to decide which
	// tiers are still resolvable as points.
	float sigma = uPsfPx * sqrt(w2);

	// The cube cell decomposition, once: every population walks up to a 3x3
	// neighbourhood on the same face and differs only in cell count.
	float face;
	vec2 fc;
	sky_cube(dir, face, fc);
	vec2 g = sky_toGrid(fc);                      // [-1,1] on this face

	bool cached = uSkyCacheFace > 0.5 && w2 >= pix2 * SKY_CACHE_MIN_W2;
	vec4 diffuse = cached ? textureLod(uSkyCache, sky_cacheUV(face, g), 0.0) : vec4(0.0);
	float tau = cached ? diffuse.a : sky_tau(dir);
	vec3 ext = sky_extinction(tau);

	// ---- stars, crowding toward the plane. Density stays live: interpolating it
	// would move the acceptance threshold and add or remove individual stars.
	vec2 clus = sky_clusterField(dir, face, g);
	float density = uStarDensity * (1.0 + uPlaneConc * sky_bandProfile(dir) + clus.x);
	// A source farther than `reach` fails the footprint reject. The pixel-offset
	// reject gives a tighter bound, |p| >= |P delta| / sigma_max(J), when J is
	// invertible and its plane is nearly tangent (so |P delta| tracks the angle).
	float reach = 20.0 * uPsfPx * sqrt(w2);
	vec3 jn = cross(ddx, ddy);
	if (ga * gc - gb * gb > SKY_1E_24 && abs(dot(jn, dir)) > 0.99 * length(jn)) {
		float lmax = 0.5 * (ga + gc) + sqrt(0.25 * (ga - gc) * (ga - gc) + gb * gb);
		reach = min(reach, 8.0 * sqrt(lmax));
	}

	for (int t = 0; t < SKY_TIERS; t++) {
		float tier  = float(t);
		float cells = 4.0 * exp2(tier);             // cells per face edge
		// Angular size of one cell. Tier k has 4x the cells and 1/2.512 the flux of
		// tier k-1: one magnitude bin per tier, N(<m) ~ 10^(0.6m) for free.
		float cellAng = (SKY_PI * 0.5) / cells;
		float flux    = uStarFlux * pow(0.398, tier);

		// Points while the cell is wider than the PSF, otherwise mean surface brightness.
		// The crossfade conserves flux, and since w shrinks under magnification the ring
		// resolves deeper into the luminosity function. (Reversed edges: see sky_hermite.)
		float diffuseMix = sky_hermite(cellAng * 2.2, cellAng * 0.7, sigma);
		diffuseMix = 1.0 - diffuseMix;

		if (diffuseMix < 0.999) {
			vec2 cellPos = (g * 0.5 + 0.5) * cells;
			vec2 cell = floor(cellPos);
			ivec4 nb = sky_neighbours(cellPos - cell, cells, reach);
			for (int oy = nb.y; oy <= nb.w; oy++) {
				for (int ox = nb.x; ox <= nb.z; ox++) {
					vec2 cc = cell + vec2(float(ox), float(oy));
					// Off-face cells belong to the neighbouring face.
					if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;

					vec3 key = vec3(cc + 0.5, face * 64.0 + tier * 7.31);
					vec3 h   = sky_hash33(key);
					vec3 h2  = sky_hash33(key + 19.73);

					vec2 sg  = (cc + h.xy) / cells * 2.0 - 1.0;   // grid coords of the star
					vec2 sfc = sky_fromGrid(sg);
					// Clamped: a cell holds one star, so an acceptance above 1 would make the
					// resolved and unresolved branches disagree (by ~100× in a globular).
					float pAccept = min(density * sky_cellWeight(sfc) * 0.62, 1.0);
					if (h2.x > pAccept) continue;

					vec3 sdir = sky_uncube(face, sfc);
					vec3 delta = sdir - dir;
					// Cheap reject before the projection: nothing further than a few
					// footprints away can land inside the kernel.
					if (dot(delta, delta) > 400.0 * w2 * uPsfPx * uPsfPx) continue;

					// Least-squares offset in pixels.
					float pu = dot(ddx, delta);
					float pv = dot(ddy, delta);
					vec2 p = vec2(gc * pu - gb * pv, ga * pv - gb * pu) / gdet;
					if (dot(p, p) > 64.0) continue;

					// half a magnitude of scatter within the bin, so the tiers do not
					// read as five discrete brightness classes
					float f = flux * pow(10.0, -0.4 * (h.z - 0.5));
					// the cluster bias is what makes an open cluster read blue and a
					// globular read amber, rather than both being a local density bump
					float T = sky_starTemp(clamp(h2.y + clus.y, 0.0, 0.9999), tier);

					// Dividing by w2 is what turns the shrinking footprint into flux
					// amplification: peak radiance rises exactly as mu.
					float amp = f * (sky_psf(p) + sky_spike(p) * step(tier, 0.5)) / w2;
					amp *= sky_starBand(T) * uStarGain * (1.0 - diffuseMix);

					total += sky_emit(sky_blackbody(T, D), 1.0, amp);
				}
			}
		}

		// the unresolved remainder of this tier, as surface brightness
		if (diffuseMix > 0.001) {
			float cellOmega = (4.0 * SKY_PI / 6.0) / (cells * cells);
			float meanT = sky_starTemp(0.45, tier);
			// Same clamped acceptance; cellWeight at the ray's cell is close enough.
			float pMean = min(density * sky_cellWeight(fc) * 0.62, 1.0);
			float amp = diffuseMix * pMean * flux / cellOmega
			          * sky_starBand(meanT) * uStarGain;
			total += sky_emit(sky_blackbody(meanT, D), 1.0, amp);
		}
	}

	total *= ext;
	total = cached ? total + diffuse.rgb : sky_diffuseAdd(total, dir, tau, ext);

	// ---- galaxies and compact sources, behind the full dust column.
	if (uwGalaxies > wEps) {
		float gal = sky_galaxies(dir, face, g, w2) * uGalaxies;
		total += sky_emit(vec3(0.86, 0.83, 0.78), uwGalaxies, gal) * ext;
	}

	if (uwSnr > wEps)
		total += sky_emit(vec3(0.0), uwSnr, sky_snr(dir, face, g, w2));

	// Densities for a gamma ridge plus scattered points, and a handful of X-ray
	// binaries. Three 3x3 neighbourhoods: the most expensive part, skipped in the visible.
	float cf = uStarFlux * 0.030;
	if (uwPulsar > wEps)
		total += sky_emit(vec3(0.0), uwPulsar,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, reach, face, g, 13.0,  5.0, 1.0, 0.16, cf * 0.6));
	if (uwXrb > wEps)
		total += sky_emit(vec3(0.0), uwXrb,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, reach, face, g,  9.0, 61.0, 1.0, 0.13, cf * 0.9));
	if (uwBlazar > wEps)
		total += sky_emit(vec3(0.0), uwBlazar,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, reach, face, g, 11.0, 29.0, 0.0, 0.05, cf * 0.7));

	return total * uSkyGain;
}

// The unboosted sky (D = 1), for the lens resolve.
vec3 skyRadiance(vec3 dir, vec3 ddx, vec3 ddy){
	return skyRadianceD(dir, ddx, ddy, 1.0);
}
