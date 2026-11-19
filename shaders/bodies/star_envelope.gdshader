// WHAT LIES ABOVE A PHOTOSPHERE THAT IS NOT A THIN SKIN, marched through a sphere about
// the star: a cool giant's levitated molecular layer, which hides the limb and glows
// at nearly the photosphere's temperature, so the star has no sharp edge; the dust its
// wind condenses, which reddens what it covers and scatters starlight; the puffs its
// largest cells throw off, warm gas that turns to dust past the condensation radius;
// and a hot star's ionised wind, which hides the hydrostatic surface. Parameters from
// Stellar.envelope_of; physics in docs/physics/stellar-surfaces.md.
// blend_premul_alpha: emission over the transmitted background. Transmission is per
// colour but blending has one alpha, so the background is taken out by its least
// transmitted colour and the rest put back from the photosphere it covers.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/star_noise.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler3D uNoise : filter_linear, repeat_enable;

// The photosphere's radius in the star's frame, and the envelope's in stellar radii.
uniform float uR = 1.0;
uniform float uEnv = 2.0;
uniform float uTeff = 3600.0;
// The photosphere's drawn colour at the disc centre, and its limb darkening.
uniform vec3 uSurf = vec3(1.0);
uniform vec3 uLimbA = vec3(0.6);
uniform vec3 uLimbB = vec3(0.1);
// The molecular layer: scale height and radial optical depth.
uniform float uLayerH = 0.0;
uniform float uLayerTau = 0.0;
// Convection cells across the disc (the photosphere's granule frequency).
uniform float uCellK = 2.0;
// Dust: condensation radius, radial optical depth past it, scattered-light gain.
uniform float uDustR = 5.0;
uniform float uDustTau = 0.0;
uniform float uDustGain = 1.0;
// A hot star's wind: electron-scattering depth at its base, and its line emission.
uniform float uWindTau = 0.0;
uniform float uWindGain = 1.0;
uniform float uTime = 0.0;
// Ejected puffs: (direction, distance in R) and (width in R, column depth across the
// centre, dust fraction, seed).
uniform vec4 uPuffA[4];
uniform vec4 uPuffB[4];
uniform int uPuffCount = 0;

varying vec3 vObj;
varying flat vec3 vCam;
varying flat float vScale;

const int STEPS = 40;
// Extinction relative to its mean: TiO bands cover the green and blue more than the
// red; small grains extinguish ∝ 1/λ.
const vec3 TIO = vec3(0.62, 1.05, 1.33);
const vec3 DUST = vec3(0.80, 1.00, 1.25);

void vertex() {
	vObj = VERTEX;
	vCam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
	vScale = length(MODEL_MATRIX[0].xyz);
}

float jitter(vec2 p) {
	uvec2 q = uvec2(ivec2(p) + 32768);
	uint h = q.x * 1664525u + q.y * 22695477u + 1013904223u;
	h ^= h >> 16u; h *= 2246822519u; h ^= h >> 13u;
	return float(h & 0xffffffu) / 16777216.0;
}

float tex(vec3 p) { return texture(uNoise, p).r; }

// Henyey–Greenstein, normalised to 1 for isotropic scattering.
float hg(float c, float g) {
	float g2 = g * g;
	return (1.0 - g2) / pow(max(1.0 + g2 - 2.0 * g * c, 1e-4), 1.5);
}

// Dilution of the star's light at r stellar radii.
float dilution(float r) {
	return 0.5 * (1.0 - sqrt(max(1.0 - 1.0 / (r * r), 0.0)));
}

void fragment() {
	vec3 ro = vCam;
	vec3 rd = normalize(vObj - vCam);
	float tca = -dot(ro, rd);
	float b = max(length(ro + rd * tca), 1e-4 * uR);
	float Re = uEnv * uR;
	if (b >= Re) discard;
	float half_ = sqrt(Re * Re - b * b);
	float t0 = max(tca - half_, 0.0);
	float t1 = tca + half_;
	bool hits = b < uR && tca > 0.0;
	if (b < uR) t1 = min(t1, tca - sqrt(uR * uR - b * b));
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 vv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(vv.xyz / vv.w) / max(vScale, 1e-12));
	if (t1 <= t0) discard;

	// March evenly in the angle the sample subtends at the star's centre: the samples
	// gather at the closest approach, where the envelope is densest, and a 1/r² wind
	// is integrated exactly.
	float ph0 = atan((t0 - tca) / b);
	float ph1 = atan((t1 - tca) / b);
	float dph = (ph1 - ph0) / float(STEPS);
	float jit = jitter(FRAGCOORD.xy);
	float H = max(uLayerH, 1e-4);
	float kL = uLayerTau / H;
	float kD = uDustTau / max(uDustR, 1.0);
	float kW = uWindTau / 4.6;
	vec3 T = vec3(1.0);
	vec3 col = vec3(0.0);
	vec3 wT = vec3(0.0);      // what each component hid: layer, dust, wind
	for (int i = 0; i < STEPS; i++) {
		float ph = ph0 + (float(i) + jit) * dph;
		float c = cos(ph);
		float x = b * tan(ph);
		vec3 p = ro + rd * (tca + x);
		float r = b / (c * uR);
		float ds = b * dph / (c * c * uR);
		vec3 dir = p / max(length(p), 1e-9);
		vec3 dtau = vec3(0.0);
		vec3 src = vec3(0.0);
		float h = r - 1.0;
		// The layer: lumpy over the giant cells, with plumes standing radially above them.
		if (uLayerTau > 0.0 && h < 8.0 * H) {
			float cell = tex(dir * uCellK * 0.35 + vec3(0.0, 0.0, h * 0.8 + uTime * 0.004));
			float plume = tex(dir * uCellK * 1.1 + vec3(0.37, h * 0.25, uTime * 0.006));
			float n = exp(-h / H) * (0.3 + 1.2 * smoothstep(0.3, 0.8, cell)) * (0.6 + 0.8 * plume);
			vec3 dt = kL * n * ds * TIO;
			// Lukewarm: within a few hundred kelvin of T_eff at its base (O'Gorman et al. 2020),
			// cooling outward.
			float TL = uTeff * (0.92 - 0.3 * clamp(h / (5.0 * H), 0.0, 1.0));
			dtau += dt;
			src += uSurf * sn_planck_ratio(TL, uTeff) * dt;
			wT.x += dt.g;
		}
		// Dust past the condensation radius, in clumps (Freytag & Höfner 2023).
		if (uDustTau > 0.0 && r > uDustR * 0.75) {
			float clump = tex(dir * 4.0 + vec3(r * 0.08, 0.0, 0.61));
			float n = (uDustR / r) * (uDustR / r) * smoothstep(uDustR * 0.75, uDustR * 1.2, r) * (0.2 + 1.6 * smoothstep(0.35, 0.75, clump));
			vec3 dt = kD * n * ds * DUST;
			dtau += dt;
			src += uSurf * (uDustGain * 0.5 * dilution(r) * hg(dot(dir, -rd), 0.55)) * dt;
			wT.y += dt.g;
		}
		// A hot star's wind: dense at its base, thrown out in radial clumps.
		if (uWindTau > 0.0) {
			float n = 1.0 / (r * r * max(1.0 - 1.0 / r, 0.01));
			float clump = tex(dir * 9.0 + vec3(0.0, 0.0, log(r) * 2.0 - uTime * 0.05));
			n *= 0.4 + 1.2 * smoothstep(0.3, 0.8, clump);
			float dt = kW * n * ds;
			dtau += vec3(dt);
			// Scattered starlight and the wind's own line emission, both diluted outward.
			src += uSurf * ((1.0 + uWindGain) * 2.0 * dilution(r)) * dt;
			wT.z += dt;
		}
		// Puffs: warm gas while inside the condensation radius, dust past it.
		for (int k = 0; k < 4; k++) {
			if (k >= uPuffCount) break;
			vec3 cen = uPuffA[k].xyz * uPuffA[k].w;
			float sg = uPuffB[k].x;
			vec3 q = p / uR - cen;
			// Drawn out behind into the wake it left, back toward the surface.
			float al = dot(q, uPuffA[k].xyz);
			vec3 pp = q - uPuffA[k].xyz * al;
			float sl = al < 0.0 ? sg + 0.7 * (uPuffA[k].w - 1.0) : sg;
			float d2 = dot(pp, pp) / (sg * sg) + al * al / (sl * sl);
			if (d2 > 6.0) continue;
			float n = exp(-d2) * (al < 0.0 ? mix(1.0, 0.45, clamp(-al / max(sl, 1e-3), 0.0, 1.0)) : 1.0) * (0.35 + 1.3 * smoothstep(0.3, 0.8, tex(q / sg * 0.45 + uPuffB[k].w)));
			float dt = uPuffB[k].y / (1.77 * sg) * n * ds;
			float dusty = uPuffB[k].z;
			// The ejected gas is hot and dense (Dupree et al. 2020 saw it bright in the UV):
			// grey, and near the photosphere's temperature, until it condenses.
			vec3 dtv = dt * mix(vec3(1.0), DUST, dusty);
			dtau += dtv;
			src += dtv * mix(uSurf * sn_planck_ratio(uTeff * 0.95, uTeff),
				uSurf * (uDustGain * 0.5 * dilution(r) * hg(dot(dir, -rd), 0.55)), dusty);
			wT.x += dt * (1.0 - dusty);
			wT.y += dt * dusty;
		}
		if (dtau.g <= 0.0) continue;
		// Each colour's source over its own optical depth, attenuated by what lies nearer.
		vec3 e = exp(-dtau);
		col += T * src / max(dtau, vec3(1e-6)) * (1.0 - e);
		T *= e;
		if (max(T.r, max(T.g, T.b)) < 0.005) break;
	}
	float Tmin = min(T.r, min(T.g, T.b));
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) {
		// The disc publishes its own value; off it, an opaque envelope publishes the
		// temperature of what hides the sky: layer, dust or wind.
		float cover = 1.0 - T.g;
		if (hits || cover < 0.3) discard;
		float temp = (wT.x * uTeff * 0.8 + wT.y * 1000.0 + wT.z * uTeff) / max(wT.x + wT.y + wT.z, 1e-6);
		ALBEDO = vec3(temp_code(temp), 0.0, 0.0);
		ALPHA = 1.0;
	} else {
		if (hits) {
			// Put back the colours transmitted better than the least: the photosphere's
			// light at the point behind.
			float mu = sqrt(max(1.0 - (b / uR) * (b / uR), 0.0));
			float l = 1.0 - mu;
			vec3 bg = uSurf * max(vec3(1.0) - uLimbA * l - uLimbB * l * l, vec3(0.0));
			col += bg * (T - vec3(Tmin));
			ALPHA = 1.0 - Tmin;
		} else {
			ALPHA = 1.0 - dot(T, vec3(0.3, 0.45, 0.25));
		}
		if (max(col.r, ALPHA) < 0.001) discard;
		ALBEDO = col;
	}
}
