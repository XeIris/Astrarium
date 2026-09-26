// ============================================================================
// SKY — procedural celestial background, resolution-free and band-aware.
// The port of sim/sky.js's SKY_GLSL. The module-level derivation (why a map
// cannot survive lensing, the screen-space Jacobian, the magnitude law, the
// Malmquist-weighted temperatures, why the sky composites itself per band) is
// the header of sim/sky.gd, which is the port of that file's JS half.
// Every comment below is the web build's, kept with the code it explains.
//
// Included by shaders/sky/background.gdshader (colour) and
// shaders/sky/background_temp.gdshader (the temperature pass), both
// `shader_type sky`, where dFdx/dFdy are available. The uniform NAMES are the
// web build's skyUniforms() names, one for one, and every declared default
// here equals the JS default — so a fresh ShaderMaterial is already the web
// build's sky before sim/sky.gd writes anything (SkyModel.init_sky_materials
// writes them all anyway, so the two can never drift).
//
// ONE DEVIATION IN THE INTERFACE, forced by gdshader. The web build carried
// the Doppler factor of the observer's boost in a mutable module-level global,
// `float sky_D = 1.0;`, set as a side effect of sky_aberrate() and read by
// sky_blackbody(). gdshader has no mutable globals (only const, uniform and
// varying may sit outside a function), so D is carried EXPLICITLY:
//
//   vec3  sky_aberrate(vec3 dir)       the rest-frame direction (unchanged)
//   float sky_doppler(vec3 dir)        D for the SHIP-frame direction dir —
//                                      exactly the value sky_aberrate(dir)
//                                      stored in sky_D
//   vec3  skyRadianceD(dir, ddx, ddy, D)  the radiance with that D
//   vec3  skyRadiance(dir, ddx, ddy)   == skyRadianceD(..., 1.0): what the
//                                      lens resolve got, since it never
//                                      called sky_aberrate and sky_D stayed 1
//   float sky_beaming(float D)         D^4
//
// so the backdrop reads   rd = sky_aberrate(d); D = sky_doppler(d);
//                         skyRadianceD(rd, dFdx(rd), dFdy(rd), D) * sky_beaming(D)
// which is arithmetically the web build's backdrop, term for term.
// ============================================================================

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

// Relativistic boost of the OBSERVER, as velocity/c in world coordinates.
// Zero everywhere except during interstellar cruise, where it is what turns
// the sky into a forward-lit tunnel. See sky_aberrate below.
uniform vec3 uBeta = vec3(0.0);

/**
 * Alpha sentinel meaning "this pixel is sky, already imaged in the current
 * band - do not infer a temperature, do not apply a Planck ratio". The value
 * and its reasoning are SkyModel.SKY_ALPHA's (sim/sky.gd).
 */
const float SKY_ALPHA = 0.995;

#define SKY_PI 3.141592653589793
// Six magnitude bins of resolved stars, then the rest as glow. That cutoff is
// the instrument's confusion limit, and it lands near apparent magnitude 8 —
// a little past the naked-eye limit of 6.5, which is about right for something
// that is explicitly a camera.
#define SKY_TIERS 6

// Band-weight cull threshold.
//
// The W table in sim/sky.gd is not only a set of multipliers - it is a
// statement about which components EXIST in a given band, and most of them do
// not. In the visible, ten of the fifteen weights are zero or near it, and
// every one of those components was being evaluated at full price and then
// multiplied by nothing: three 3x3 compact-source neighbourhoods, an SNR
// neighbourhood, and six diffuse fields carrying an fBm each.
//
// So the weights are read as predicates as well as gains. The branches are on
// uniforms, which means they are perfectly coherent across the draw - every
// invocation in the dispatch takes the same side, there is no divergence, and
// the cost is one scalar compare. This gets BETTER as components are added,
// because a new component is free in the bands where it does not emit.
//
// The threshold is set where a component can no longer survive THE DISPLAY
// SCALE IT IS HEADING INTO, and those scales are not the same, so neither is
// the threshold:
//
//   visible   goes to the ACES tone mapper in render/postfx.gd against a frame
//             whose stars are orders of magnitude brighter. Anything under a
//             few percent of the band peak is buried. Measured at 1280x720:
//             culling everything below 0.03 changes 0 of 921600 pixels, and
//             the components it drops - SNR, blazars, pulsars, XRBs and the
//             six diffuse non-thermal fields - are most of the pass.
//
//   all else  goes to the log stretch in shaders/post/remap.glsl, which fills
//             the palette from ~0.002 and therefore LIFTS faint components
//             rather than burying them. The floor has to sit below the smallest
//             weight that is meant to be seen, and the tables use 0.01
//             (galaxies in gamma) as a deliberate "faint but present" value.
//             Measured: 0.005 is pixel-identical in radio, infrared, X-ray and
//             gamma, while 0.05 visibly damages all four.
//
// Getting this backwards is a silent, band-specific regression, which is why
// both numbers are pinned to a measurement rather than chosen by eye.
#define SKY_W_EPS_VIS 0.03
#define SKY_W_EPS_LOG 0.005

// TINY LITERALS DO NOT SURVIVE GODOT'S SHADER COMPILER. It re-prints every
// float constant into the generated GLSL in FIXED notation with ~14 decimals,
// so 1e-16, 1e-24 and 1e-30 all reach the GPU as 0.0 (measured: a probe
// log2(x + 1e-37) came back -inf). The web build leans on three of them as
// floors, and without them the degenerate Jacobian on isolated photon-ring
// pixels — the two screen derivatives exactly antiparallel, cross product
// exactly zero — divided by zero: w2 = 0, s = inf, NaN, which the bloom mip
// chain then spread into black rectangles over the whole disc. Spelled as bit
// patterns, the constants are exact and cannot be re-printed away.
#define SKY_1E_16 uintBitsToFloat(0x24e69595u)   // 1e-16
#define SKY_1E_24 uintBitsToFloat(0x179abe15u)   // 1e-24
#define SKY_1E_30 uintBitsToFloat(0x0da24260u)   // 1e-30

// GLSL's smoothstep with the edges REVERSED (edge0 > edge1), written out.
// The web build called smoothstep(cellAng*2.2, cellAng*0.7, sigma), which the
// spec leaves undefined but WebGL/ANGLE evaluates as the plain Hermite formula
// below. SPIR-V and Metal leave it undefined too, and a driver that took them
// at their word would move the star-tier LOD boundary, so the formula the web
// build actually got is stated here instead of hoped for.
float sky_hermite(float e0, float e1, float x){
	float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
	return t * t * (3.0 - 2.0 * t);
}

// ---- hashing ---------------------------------------------------------------
// Three independent streams from one 3-vector. The star loop needs several
// uncorrelated values per cell (position, brightness, temperature) and pulling
// them from one hash call is most of the cost saved.
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

// ---- relativistic aberration -----------------------------------------------
// The observer's boost, and the per-pixel Doppler factor it produces.
//
// A source seen by a moving observer at angle theta' from the direction of
// travel was, in the rest frame, at
//     cos theta = (cos theta' - beta) / (1 - beta cos theta')
// so the whole sky piles into a forward cone: at gamma = 10 everything visible
// is inside about 11 degrees ahead. The Doppler factor for that direction is
//     D = 1 / (gamma (1 - beta cos theta'))
// and a blackbody at T is seen at T*D, which this module can represent exactly
// because it colours its stars from a Planck locus - so the shift is applied to
// the TEMPERATURE at source, not as a hue filter afterwards. Bolometric
// intensity goes as D^4 (the headlight effect), which is sky_beaming.
//
// The aberration is deliberately applied to the ray direction BEFORE the caller
// takes its screen-space derivatives, so the change in solid angle per pixel is
// picked up by the same point-source machinery that already handles lensing
// magnification. Nothing here assumes an angular resolution.
//
// (The web build's sky_aberrate also stored D in the global sky_D; see the
// header of this file for why that is sky_doppler here.)
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

// The Doppler factor D = 1 / (gamma (1 - beta cos theta')) for the ship-frame
// direction `dir` — what sky_aberrate(dir) left in the web build's sky_D.
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
	// A blackbody at T seen through a Doppler factor D is a blackbody at T*D.
	// D is 1.0 unless the caller measured a real boost, so this is the identity
	// for every non-relativistic path through the module.
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

// A star's FLUX in the current band, relative to its flux in the visible:
//
//     F_nu / F_vis  =  (nu/nu_vis)^3 * (exp(theta_vis/T) - 1) / (exp(theta/T) - 1)
//
// The nu^3 prefactor is the part the remap can drop and this cannot. For an
// extended source it cancels against the reference; for a point source of fixed
// solid angle it does not, and it is the entire reason stars are absent from
// the radio sky rather than merely dimmer there.
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

// ---- galactic frame --------------------------------------------------------
// sin(b) is the component along the plane normal; longitude runs from the
// centre direction toward uGalEast. Both are exact, so the band and the bulge
// stay locked together however the frame is oriented per preset.
float sky_sinb(vec3 d){ return dot(d, uGalNormal); }
float sky_lon(vec3 d){ return atan(dot(d, uGalEast), dot(d, uGalCenter)); }

// Surface brightness of the disc as seen from inside it. Two exponential
// components in latitude - a thin young disc and a thicker old one - times a
// longitude term that brightens toward the centre, because that line of sight
// runs through far more of the disc than the anticentre one does.
float sky_bandProfile(vec3 d){
	float b = abs(sky_sinb(d));
	float thin = exp(-b / max(uBandScaleH, 1e-3));
	// The broad halo matters as much as the bright core. The naked-eye Milky Way
	// has a concentrated ridge a few degrees wide sitting inside a diffuse glow
	// that reaches tens of degrees; with only the ridge the band reads as a
	// painted stripe rather than as something the galaxy is doing.
	float thick = exp(-b / max(uBandScaleH * 5.0, 1e-3)) * 0.45;
	float l = sky_lon(d);
	float toward = 0.35 + 0.65 * exp(-abs(l) / 1.15);
	return (thin + thick) * toward;
}

// The INTERSTELLAR GAS profile, which is not the stellar one. Gas has a much
// smaller scale height than stars — it cools and settles, while stars are
// scattered out of the plane over billions of years — so everything that traces
// gas rather than starlight (synchrotron, 21 cm, dust, the pi-zero ridge) is a
// far sharper ridge than the visible band is.
//
// Getting this wrong is what makes a first attempt at the radio sky come out as
// a flat magenta wash: built on the stellar profile, the emission is still at a
// third of full scale 25 degrees off the plane, and the log stretch turns that
// into saturated false colour across the entire frame. The real 408 MHz sky is
// more than an order of magnitude down by then.
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

// ---- dust ------------------------------------------------------------------
// Optical depth of the interstellar dust along this line of sight. It hugs the
// plane far more tightly than the stars do - the dust scale height is roughly a
// third of the stellar one - which is why the lane cuts a clean dark stripe
// through the middle of the band instead of dimming it evenly. The fBm on top
// is what makes dark nebulae: real dust is patchy, not a smooth slab.
float sky_dustTau(vec3 d){
	float b = abs(sky_sinb(d));
	float lane = exp(-b / max(uBandScaleH * 0.34, 1e-3));
	// ("patch" is a reserved word in GLSL — tessellation. It compiles nowhere.)
	float veil = sky_fbm(d * 5.5, 4);
	veil = pow(clamp(veil * 1.55 - 0.25, 0.0, 1.0), 1.6);
	float clumps = pow(clamp(sky_fbm(d * 17.0 + 41.0, 3) * 1.7 - 0.45, 0.0, 1.0), 2.0);
	// Kept to tau of order 1 rather than order 5. The dust lane has to darken the
	// band, not delete it: the two profiles peak in the same place, so an opaque
	// lane cancels the glow exactly where the glow is supposed to be brightest
	// and the band disappears entirely instead of splitting in two.
	return uDust * lane * (0.55 * veil + 1.15 * clumps) * 0.95;
}

// Extinction as a multiplier. In the visible it is chromatic - A(lambda) rises
// toward the blue, so a reddened star goes dim AND orange, which is the single
// most recognisable signature of dust. In every other band one coefficient is
// enough, and outside the optical/UV/X-ray it is essentially unity.
vec3 sky_extinction(float tau){
	if (uVisibleBand > 0.5) return exp(-tau * vec3(0.78, 1.0, 1.38));
	return vec3(exp(-tau * uExtCoef));
}

// ---- cube cells ------------------------------------------------------------
// Direction -> cube face and face coordinates in [-1,1]. A cube beats the
// equirectangular map the old texture used on both counts that matter: cell
// solid angle stays within a factor of ~2.6 instead of collapsing to zero at
// the poles, and there is no seam to point the free-fly camera at.
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

// Tangent warp. Plain cube cells vary ~5x in solid angle between face centre
// and corner; warping the grid through tan(g*pi/4) - the standard equiangular
// cube map - cuts that to 1.30, and the residual is corrected by weighting the
// existence probability below. The result is a genuinely uniform star density
// per steradian, which the old equirect texture never had.
vec2 sky_toGrid(vec2 fc){ return atan(fc) * (4.0 / SKY_PI); }
vec2 sky_fromGrid(vec2 g){ return tan(g * (SKY_PI / 4.0)); }

// Residual solid angle per unit grid area, normalised to 1 at the face centre.
float sky_cellWeight(vec2 fc){
	float s = 1.0 + fc.x * fc.x + fc.y * fc.y;
	return (1.0 + fc.x * fc.x) * (1.0 + fc.y * fc.y) / (s * sqrt(s));
}

// ---- stellar temperature ---------------------------------------------------
// Weighted for a MAGNITUDE-LIMITED sample, not for the initial mass function.
// The sky is not a fair sample of stars: luminous ones are visible from vastly
// further away, so what you actually see is mostly B and A stars plus distant
// giants. Sampling the IMF instead would give a sky of red dwarfs, which is
// true of the galaxy and false of the view.
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

// ---- point layer -----------------------------------------------------------
// THE PSF LIVES IN THE IMAGE PLANE, NOT THE SOURCE PLANE.
//
// This is the difference between a ring of brilliant points and a ring of
// smears, and it is worth being precise about. The obvious implementation
// blurs the star by sigma in SOURCE angle. But near the photon ring the
// magnification is wildly anisotropic - tangential magnification runs far ahead
// of radial - so the lens stretches that source-plane kernel into an arc. Arcs
// are the correct image of an EXTENDED source; a star is a point, and a point
// source stays a point under any lens. The arc was the filter, not the star.
//
// So the offset is measured in PIXELS instead. Let J = [dD/dx, dD/dy] be the
// 3x2 Jacobian mapping screen pixels to sky directions. For a star at sdir,
// solve J p = (sdir - dir) in least squares - the normal equations are a 2x2
// inverse - and p is where the star sits relative to this pixel, in pixels. The
// PSF is then a plain circular Gaussian in p: fixed size on screen, no matter
// what the lens is doing.
//
// Normalisation carries the magnification. Pushing a unit-area image-plane
// kernel through J divides by |det J| = w^2, the source solid angle per pixel:
//
//     L  =  F * G(p) / w^2
//
// and w^2 shrinks as 1/mu where the sky is magnified, so the peak radiance
// rises exactly as mu. Flux amplification and a point that stays a point, from
// one expression, with the anisotropy handled by construction.
//
// The kernel is a bright core plus a wide faint halo, which is what a real PSF
// looks like once scattering in the optics is counted. Both terms are
// area-normalised in pixel units, so the pair integrates to unity.
float sky_psf(vec2 p){
	float s2 = uPsfPx * uPsfPx;
	float r2 = dot(p, p);
	float core = exp(-0.5 * r2 / s2) / (6.2831853 * s2);
	float halo = exp(-0.5 * r2 / (9.0 * s2)) / (6.2831853 * 9.0 * s2);
	return 0.86 * core + 0.14 * halo;
}

// Four diffraction spikes, on the brightest stars only. This is an INSTRUMENT
// signature rather than anything the star does - which is legitimate here,
// because the whole sim is framed as an imaging instrument with selectable
// bands, and every real image of a bright star has them. In pixel space they
// are simply arms along p.x and p.y, so they stay straight and screen-aligned
// however the sky underneath is being bent.
float sky_spike(vec2 p){
	if (uSpikes < 0.01) return 0.0;
	float s = uPsfPx * 1.3;
	float arm = exp(-0.5 * p.y * p.y / (s * s)) * exp(-abs(p.x) / (s * 13.0))
	          + exp(-0.5 * p.x * p.x / (s * s)) * exp(-abs(p.y) / (s * 13.0));
	return arm * uSpikes * 0.016 / (6.2831853 * uPsfPx * uPsfPx);
}

// ---- clusters --------------------------------------------------------------
// Stars are not sprinkled independently; they are born in groups and a good
// fraction of the sky's texture is that clumping. Two kinds, and they are
// opposites in every respect that shows:
//
//   open clusters      young, blue, loose, and strictly in the plane
//   globular clusters  ancient, red, tightly bound, and OUT of the plane —
//                      they orbit in the halo, so they are the one stellar
//                      structure that ignores the galactic band entirely
//
// Returned as (density multiplier, temperature bias) and folded into the star
// loop, so a cluster is a real local excess of real stars rather than a sprite.
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

// ---- extended and compact populations --------------------------------------
// Galaxies are the one thing on this sky that is genuinely ISOTROPIC. Everything
// galactic crowds the plane; external galaxies do not care, and they are seen
// THROUGH the whole dust column, so in the visible they thin out and vanish
// behind the band — the zone of avoidance — while in the infrared and X-ray
// they come straight back. That contrast is free here, because the same tau
// that reddens the stars is applied to them.
//
// They are also EXTENDED, which is why they are evaluated in source angle
// rather than in pixels: an extended source really does arc under strong
// lensing, and it should. Clamping the width to the pixel filter and letting
// the 1/sigma^2 normalisation dim it is what makes an unresolved galaxy behave
// like a point again — the same rule sim/scale.gd uses for a sub-pixel body,
// and the one continuous expression covers both regimes.
float sky_galaxies(vec3 dir, float face, vec2 g, float w2){
	float acc = 0.0;
	float cells = 9.0;
	vec2 cell = floor((g * 0.5 + 0.5) * cells);

	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
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

// Compact non-thermal sources. These are the entire reason the radio, X-ray and
// gamma skies have anything in them once the stars have correctly disappeared:
// pulsars and X-ray binaries are faint or invisible points in the optical and
// dominant elsewhere. Rendered in pixel space like stars, because they are
// point sources in every band that can see them.
//
// "plane" gates the population onto the galactic disc. Blazars are set to 0 —
// they are extragalactic, so they scatter uniformly over the sky, which is
// exactly how a gamma-ray point-source map looks: a bright galactic ridge with
// isotropic sources sprinkled over everything else.
float sky_compact(vec3 dir, vec3 ddx, vec3 ddy, float ga, float gb, float gc,
                  float gdet, float w2, float face, vec2 g, float cells, float seed,
                  float plane, float accept, float flux){
	float acc = 0.0;
	vec2 cell = floor((g * 0.5 + 0.5) * cells);

	for (int oy = -1; oy <= 1; oy++) {
		for (int ox = -1; ox <= 1; ox++) {
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

// Supernova remnants: expanding shells, so they are ANNULI on the sky rather
// than points — bright edge, hollow middle, because the shell is a thin surface
// seen through more material at its limb. Extended, hence source-plane again.
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

// ============================================================================
// skyRadianceD / skyRadiance
// ----------------------------------------------------------------------------
//   dir      outgoing ray direction, normalised (after lensing, if any)
//   ddx,ddy  screen derivatives of that direction. These ARE the lensing, as
//            far as the sky is concerned: their cross product is the pixel's
//            source solid angle and carries det J, and the pair together give
//            the anisotropy that keeps a magnified star from smearing.
//   D        the observer's Doppler factor for this pixel (sky_doppler), 1.0
//            with no boost — the web build's sky_D global
// ============================================================================
vec3 skyRadianceD(vec3 dir, vec3 ddx_in, vec3 ddy_in, float D){
	vec3 total = vec3(0.0);
	vec3 ddx = ddx_in;
	vec3 ddy = ddy_in;

	// Cull threshold for this band's component weights - see SKY_W_EPS_VIS.
	float wEps = uVisibleBand > 0.5 ? SKY_W_EPS_VIS : SKY_W_EPS_LOG;

	// Source solid angle per pixel. Clamped by SCALING THE BASIS rather than the
	// area, so the Jacobian stays consistent with the number it reports.
	//
	// Both ends matter. The lower cap bounds magnification at ~1000x, past which
	// a real point source stops being one anyway. The upper cap is the important
	// one: rays that wind several times around the photon sphere land in
	// completely different places from one pixel to the next, so the derivative
	// there is not a footprint but noise, and without a cap the ring detonates.
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

	// The cube cell decomposition, computed ONCE for the whole function.
	//
	// Every cell-based population below - clusters, galaxies, SNR, the three
	// compact source classes, and the star tiers - walks a 3x3 neighbourhood on
	// the same cube face, at a different cell count. Only the count differs, so
	// only the cell index has to be recomputed per population; the face selection
	// and the tangent warp are the same answer every time. Deriving them in each
	// function cost seven evaluations of sky_cube (branchy) and sky_toGrid (an
	// atan per axis) per pixel for one distinct result.
	float face;
	vec2 fc;
	sky_cube(dir, face, fc);
	vec2 g = sky_toGrid(fc);                      // [-1,1] on this face

	float band  = sky_bandProfile(dir);
	float bulge = sky_bulgeProfile(dir);

	// Dust is only worth evaluating if something in this band consumes it, and in
	// the radio and gamma bands nothing does: extinction is unity there (see
	// EXTINCTION), thermal dust emission is weighted to zero, and so are the
	// reflection nebulae and the absorbed X-ray background. sky_dustTau is two
	// fBm fields, so this is one of the larger single savings available.
	float tau = 0.0;
	if (uVisibleBand > 0.5 || uExtCoef > wEps || uwDustEm > wEps
	    || uwRefl > wEps || uwXrayBg > wEps) tau = sky_dustTau(dir);
	vec3 ext = sky_extinction(tau);

	// ------------------------------------------------------------------ stars
	// Stars crowd toward the galactic plane for the same reason the band glows:
	// that is where the disc is. Without this the point layer sits uniformly on
	// top of a structured background and immediately reads as fake.
	vec2 clus = sky_clusterField(dir, face, g);
	float density = uStarDensity * (1.0 + uPlaneConc * band + clus.x);

	for (int t = 0; t < SKY_TIERS; t++) {
		float tier  = float(t);
		float cells = 4.0 * exp2(tier);             // cells per face edge
		// Angular size of one cell. Tier k has 4x the cells and 1/2.512 the flux of
		// tier k-1: one magnitude bin per tier, N(<m) ~ 10^(0.6m) for free.
		float cellAng = (SKY_PI * 0.5) / cells;
		float flux    = uStarFlux * pow(0.398, tier);

		// Resolved as points while the cell is comfortably wider than the PSF;
		// otherwise the tier's light is delivered as its mean surface brightness.
		// The crossfade conserves flux across the transition, which is what stops
		// the LOD boundary showing up as a seam - and because w shrinks under
		// magnification, the ring resolves DEEPER into the luminosity function than
		// the rest of the frame, which is exactly what magnification really does.
		// (Reversed edges, as the web build wrote them: see sky_hermite.)
		float diffuseMix = sky_hermite(cellAng * 2.2, cellAng * 0.7, sigma);
		diffuseMix = 1.0 - diffuseMix;

		if (diffuseMix < 0.999) {
			vec2 cell = floor((g * 0.5 + 0.5) * cells);
			for (int oy = -1; oy <= 1; oy++) {
				for (int ox = -1; ox <= 1; ox++) {
					vec2 cc = cell + vec2(float(ox), float(oy));
					// Cells that fall off the face edge are simply skipped. The stars
					// that would live there belong to the neighbouring face and are
					// found when the ray points at it; the seam is invisible because
					// nothing is stretched across it.
					if (cc.x < 0.0 || cc.y < 0.0 || cc.x >= cells || cc.y >= cells) continue;

					vec3 key = vec3(cc + 0.5, face * 64.0 + tier * 7.31);
					vec3 h   = sky_hash33(key);
					vec3 h2  = sky_hash33(key + 19.73);

					vec2 sg  = (cc + h.xy) / cells * 2.0 - 1.0;   // grid coords of the star
					vec2 sfc = sky_fromGrid(sg);
					// Clamped, and the clamp is load-bearing. A cell holds at most one
					// star, so an acceptance probability above 1 cannot deliver the extra
					// light it claims — but the unresolved branch below would happily
					// integrate it. In the globular environment uStarDensity is 9.0 and a
					// cluster boost multiplies that again, so the raw figure reaches ~100
					// and the two branches disagree by that factor. Clamping both is what
					// keeps the LOD crossfade flux-conserving instead of stepping in
					// brightness as a tier goes unresolved.
					float pAccept = min(density * sky_cellWeight(sfc) * 0.62, 1.0);
					if (h2.x > pAccept) continue;

					vec3 sdir = sky_uncube(face, sfc);
					vec3 delta = sdir - dir;
					// Cheap reject before the projection: nothing further than a few
					// footprints away can land inside the kernel.
					if (dot(delta, delta) > 400.0 * w2 * uPsfPx * uPsfPx) continue;

					// Least-squares offset in PIXELS. Everything about the star's
					// rendered shape happens here rather than in source angle, which is
					// what keeps a lensed point source a point instead of an arc.
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
			// Same clamped acceptance as the resolved branch. cellWeight is taken at
			// the ray's own cell rather than at each star's position — neighbouring
			// cells differ by well under a percent, and it is the clamp that matters.
			float pMean = min(density * sky_cellWeight(fc) * 0.62, 1.0);
			float amp = diffuseMix * pMean * flux / cellOmega
			          * sky_starBand(meanT) * uStarGain;
			total += sky_emit(sky_blackbody(meanT, D), 1.0, amp);
		}
	}

	total *= ext;

	// ------------------------------------------------------- unresolved starlight
	// Everything fainter than the last tier. This is the galactic band itself:
	// not a painted stripe, but the integrated light of the stars the instrument
	// cannot separate. Extinguished by the same dust as the stars in front of it.
	float glow = uGlow * band * 0.30;
	total += sky_emit(vec3(0.62, 0.66, 0.85), uwGlow, glow) * ext;

	// The bulge is older and redder than the disc, and it sits behind more dust.
	float bul = uBulge * bulge * 0.22;
	total += sky_emit(vec3(1.00, 0.78, 0.52), uwBulge, bul) * ext * ext;

	// --------------------------------------------------------------- nebulae
	// H II regions: ionised hydrogen around young hot stars, so they follow the
	// arms and hug the plane. H-alpha at 656 nm is why they are red. Gone in the
	// X-ray and gamma bands - recombination lines have no business there.
	if (uwHii > wEps) {
		float arms = sky_arms(dir);
		float hiiN = pow(clamp(sky_fbm(dir * 7.3 + 5.0, 4) * 1.9 - 0.62, 0.0, 1.0), 2.1);
		float hii  = uHii * hiiN * band * arms * 0.42;
		total += sky_emit(vec3(1.00, 0.20, 0.26), uwHii, hii) * ext;
	}

	// Reflection nebulae: starlight scattered off dust rather than emitted by it.
	// Rayleigh scattering makes them blue, and they only exist where there is
	// BOTH dust and a nearby hot star - hence the product with the dust field.
	if (uwRefl > wEps) {
		float reflN = pow(clamp(sky_fbm(dir * 9.1 + 71.0, 3) * 1.8 - 0.70, 0.0, 1.0), 2.0);
		float refl  = uRefl * reflN * clamp(tau, 0.0, 1.4) * band * 0.26;
		total += sky_emit(vec3(0.34, 0.50, 1.00), uwRefl, refl) * ext;
	}

	// ------------------------------------------------------- non-thermal sky
	// These are the components that make the non-visible bands worth switching
	// to. All are weighted to nothing in the visible by their band tables, so
	// they cost a few multiplies and change the frame completely elsewhere.
	//
	// CONTRAST MATTERS MORE THAN AMPLITUDE HERE. The remap applies a log stretch
	// tuned so that radiances from about 0.002 to about 0.7 fill the palette.
	// The real radio sky spans several hundred between the galactic plane and
	// the poles, and a component carrying a fat isotropic floor collapses that
	// range into a flat wash of false colour — which is exactly what a first
	// pass at this looks like. So the profiles below are sharpened and their
	// floors are kept genuinely small.
	// The gas column feeds synchrotron and 21 cm, and nothing else here.
	float gas = 0.0;
	if (uwSynch > wEps || uwH21 > wEps) gas = sky_gasProfile(dir);

	// Synchrotron: bright plane plus a huge loop arching well out of it, which is
	// the single most recognisable feature of the low-frequency radio sky.
	// A narrow arc, not a broad glow. The North Polar Spur is a thin filament
	// that reaches most of the way to the pole; drawn wide it stops being a
	// feature and becomes a floor under the whole frame, which is the difference
	// between a radio sky and a magenta rectangle.
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

	// The CMB: a nearly uniform floor, plus the dipole from the observer's own
	// motion. In the microwave band it is not a background, it is the sky — so a
	// flat mid-tone everywhere is the correct answer here, not a failure of
	// contrast. It is the one component that SHOULD look featureless.
	// Held well below the galactic dust so the plane still reads as the brightest
	// thing in the frame: the CMB is the floor of the microwave sky, not its
	// ceiling. The fBm term stands in for the primordial anisotropies, which are
	// genuinely tiny — parts in 10^5 — and are exaggerated here only enough to
	// stop the background looking like a flat fill.
	if (uwCmb > wEps) {
		float dipole = 1.0 + 0.16 * dot(dir, uGalEast);
		float aniso  = 1.0 + 0.22 * (sky_fbm(dir * 12.0 + 3.0, 3) - 0.5);
		total += sky_emit(vec3(0.0), uwCmb, dipole * aniso * 0.06);
	}

	// Thermal dust emission. Note this reuses the SAME tau that darkens the
	// visible sky: one dust distribution, absorbing in the optical and glowing in
	// the infrared, so the bright IR lanes land exactly on the black visible ones.
	if (uwDustEm > wEps) total += sky_emit(vec3(0.0), uwDustEm, tau * 0.65);

	// Cosmic rays on interstellar gas -> pi-zero decay. Traces the gas column, so
	// it is a thinner, harder-edged ridge than the stellar band, and outside it
	// the gamma sky is very nearly empty.
	if (uwPion > wEps) {
		float ridge = exp(-abs(sky_sinb(dir)) / max(uBandScaleH * 0.40, 1e-3));
		total += sky_emit(vec3(0.0), uwPion, ridge * 0.45 + 0.0012);
	}

	// Diffuse soft X-ray background, absorbed by the cold gas in front of it.
	// This is the one component that is DIMMER where there is more material, and
	// it is how the ROSAT all-sky map shows molecular clouds: as shadows.
	if (uwXrayBg > wEps) {
		float xbg = (0.55 + 0.35 * sky_fbm(dir * 2.6 + 9.0, 3)) * exp(-tau * 1.4);
		total += sky_emit(vec3(0.0), uwXrayBg, xbg * 0.12);
	}

	// ------------------------------------------------- galaxies and compact sources
	// Galaxies are extinguished by the full dust column — the zone of avoidance
	// in the visible, and its absence in the infrared.
	if (uwGalaxies > wEps) {
		float gal = sky_galaxies(dir, face, g, w2) * uGalaxies;
		total += sky_emit(vec3(0.86, 0.83, 0.78), uwGalaxies, gal) * ext;
	}

	if (uwSnr > wEps)
		total += sky_emit(vec3(0.0), uwSnr, sky_snr(dir, face, g, w2));

	// Densities chosen so the gamma sky is a ridge plus a scattering of points,
	// which is what a gamma-ray point-source catalogue actually looks like, and
	// so the X-ray sky has a handful of blazing binaries rather than a field.
	//
	// Three 3x3 neighbourhoods, each with a PSF projection per candidate - by
	// some distance the most expensive thing in this function that the visible
	// band has no use for at all.
	float cf = uStarFlux * 0.030;
	if (uwPulsar > wEps)
		total += sky_emit(vec3(0.0), uwPulsar,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, face, g, 13.0,  5.0, 1.0, 0.16, cf * 0.6));
	if (uwXrb > wEps)
		total += sky_emit(vec3(0.0), uwXrb,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, face, g,  9.0, 61.0, 1.0, 0.13, cf * 0.9));
	if (uwBlazar > wEps)
		total += sky_emit(vec3(0.0), uwBlazar,
			sky_compact(dir, ddx, ddy, ga, gb, gc, gdet, w2, face, g, 11.0, 29.0, 0.0, 0.05, cf * 0.7));

	return total * uSkyGain;
}

// The unboosted sky — the web build's skyRadiance() on any path that never
// called sky_aberrate (the lens resolve), where sky_D stayed 1.0.
vec3 skyRadiance(vec3 dir, vec3 ddx, vec3 ddy){
	return skyRadianceD(dir, ddx, ddy, 1.0);
}
