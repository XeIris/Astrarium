// A galaxy's stars near the camera, made in the vertex shader from nothing but the
// vertex index (sim/galaxy/gal_visual.gd). The galaxy is cut into cells of side uCell
// in (R, height, azimuth); a cell's stars are a Poisson draw from the model's own
// number density, hashed from the cell's integer coordinates, so a region always
// holds the same stars. Each ring of cells turns rigidly at its circular frequency,
// so stars move with the galaxy and the cells never shear apart. Only stars inside
// uRes are drawn; the glow integrates everything beyond.
//
// Vertex v: slot k = v mod K of cell v / K; the cell is (ring, height, azimuth) in
// a block of uSpan³ around the camera. Rings come from the CPU in double: per ring,
// its rotation angle and its first azimuth cell (uRingTurn, uRingFirst).
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/common/point_source.gdshaderinc"
#include "res://shaders/galaxy/gal_model.gdshaderinc"

const int MAX_SPAN = 15;
const float QUAD_PX = 5.0;

uniform int uSpan = 9;
uniform int uSlots = 64;
uniform float uCell = 0.01;
uniform float uRes = 0.04;
uniform int uRingBase = 0;
uniform int uHeightBase = 0;
uniform float uRingTurn[MAX_SPAN];
uniform float uRingFirst[MAX_SPAN];
uniform vec3 uCamLocal = vec3(-8.0, 0.0, 0.0);
uniform uint uSeed = 1u;
// Number per kpc³ per unit of j (L☉ kpc⁻³): 1/⟨L⟩ of each population.
uniform float uDiscPerJ = 1.0;
uniform float uSpherePerJ = 1.0;
// Each population's present-day mass function as 65 quantiles of log10 m, and the
// main sequence on a log10 m grid: visible light per L☉ (rgb) and luminosity (L☉).
uniform float uDiscQ[65];
uniform float uSphereQ[65];
uniform vec4 uMS[64];
uniform vec2 uMSRange = vec2(-1.1, 2.0);
// Pixel value per (L☉ kpc⁻² ÷ pixel solid angle), as the glow's uGain is per radiance.
uniform float uGain = 1.0;
uniform float uPixSr = 1e-6;
uniform float uProfilePx2 = 3.27;
// Extinction in the red, green and blue channels relative to V (as the glow's).
uniform vec3 uExt = vec3(0.748, 1.0, 1.324);
// The real stars' sphere (sim/galaxy/gal_neighbourhood.gd): its centre relative to the
// camera and its radius; no procedural star is made inside it. Radius 0: none.
uniform vec4 uHole = vec4(0.0);
// galaxylookcheck only: every star white with this bolometric L, none nearer than uInner.
uniform float uFixL = 0.0;
uniform float uInner = 0.0;

varying vec3 vCol;

uint pcg(uint v) {
	uint s = v * 747796405u + 2891336453u;
	uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
	return (w >> 22u) ^ w;
}

float u01(inout uint h) {
	h = pcg(h);
	return float(h >> 8u) * (1.0 / 16777216.0);
}

// Poisson draw: Knuth's product for small means, a normal deviate above 30.
int poisson(float lam, inout uint h) {
	if (lam <= 0.0) return 0;
	if (lam > 30.0) {
		float g = sqrt(-2.0 * log(max(u01(h), 1e-7))) * cos(6.2831853 * u01(h));
		return max(int(floor(lam + sqrt(lam) * g + 0.5)), 0);
	}
	float L = exp(-lam);
	float p = 1.0;
	int k = 0;
	for (int i = 0; i < 80; i++) {
		p *= u01(h);
		if (p <= L) break;
		k++;
	}
	return k;
}

// The table's k-th entry is at cumulative fraction 1 − 10^(−7k/64) (GalPopulation).
float quantile(bool sphere, float u) {
	float z = -log(max(1.0 - u, 1e-7)) / 2.302585;
	float f = clamp(z / 7.0, 0.0, 1.0) * 64.0;
	int i = min(int(f), 63);
	float a = sphere ? uSphereQ[i] : uDiscQ[i];
	float b = sphere ? uSphereQ[i + 1] : uDiscQ[i + 1];
	return mix(a, b, f - float(i));
}

vec4 main_sequence(float lm) {
	float f = clamp((lm - uMSRange.x) / (uMSRange.y - uMSRange.x), 0.0, 1.0) * 63.0;
	int i = min(int(f), 62);
	return mix(uMS[i], uMS[i + 1], f - float(i));
}

void vertex() {
	// Unused slots go behind the camera with no size.
	VERTEX = vec3(0.0, 0.0, 1e9);
	POINT_SIZE = 0.0;
	vCol = vec3(0.0);
	int k = VERTEX_ID % uSlots;
	int cell = VERTEX_ID / uSlots;
	int ir = cell % uSpan;
	int iy = (cell / uSpan) % uSpan;
	int ip = cell / (uSpan * uSpan);
	int ring = uRingBase + ir;
	int hgt = uHeightBase + iy;
	if (ring >= 0 && ip < uSpan) {
		float rc = (float(ring) + 0.5) * uCell;
		int nphi = max(int(6.2831853 * (float(ring) + 0.5)), 1);
		int j = int(mod(uRingFirst[ir] + float(ip), float(nphi)));
		uint h = pcg(uint(ring) * 73856093u ^ uint(hgt + 1048576) * 19349663u ^ uint(j) * 83492791u ^ uSeed);
		vec3 centre = vec3(rc, (float(hgt) + 0.5) * uCell, 0.0);
		float n_d = gal_disc_j(centre) * uDiscPerJ;
		float n_s = gal_sphere_j(centre) * uSpherePerJ;
		float vol = uCell * uCell * 6.2831853 * rc / float(nphi);
		int count = poisson((n_d + n_s) * vol, h);
		if (k < count) {
			h = pcg(h ^ uint(k) * 2654435761u);
			float R = (float(ring) + u01(h)) * uCell;
			float y = (float(hgt) + u01(h)) * uCell;
			float phi = (float(j) + u01(h)) / float(nphi) * 6.2831853 + uRingTurn[ir];
			vec3 rel = vec3(R * cos(phi), y, R * sin(phi)) - uCamLocal;
			float d = length(rel);
			bool sphere = u01(h) * (n_d + n_s) < n_s;
			vec4 ms = main_sequence(quantile(sphere, u01(h)));
			if (uFixL > 0.0) ms = vec4(1.0, 1.0, 1.0, uFixL);
			// Visible flux, L·Y/4πd² in Sun-luminance kpc⁻² (ms.rgb is light per L☉); a star
			// nearer than ~0.2 AU is not a point any more.
			float Y = max(dot(ms.rgb, vec3(0.2126, 0.7152, 0.0722)), 1e-6);
			float flux = ms.w * Y / (12.566371 * max(d * d, 1e-12));
			float v = point_flux(flux / uPixSr * uGain) / uProfilePx2;
			bool real = uHole.w > 0.0 && length(rel - uHole.xyz) < uHole.w;
			if (d <= uRes && d >= uInner && v >= 2e-4 && !real) {
				vec3 world = mat3(MODEL_MATRIX) * rel;
				VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
				POINT_SIZE = QUAD_PX;
				// Dimmed by the dust between: its density at the sight line's midpoint, which
				// varies little over the resolved radius.
				float tau = gal_dust(uCamLocal + rel * 0.5) * d;
				vCol = ms.rgb / Y * v * exp(-tau * uExt);
			}
		}
	}
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r = length(POINT_COORD - 0.5) * 2.0;
	if (r > 1.0 || vCol.r + vCol.g + vCol.b <= 0.0) discard;
	ALBEDO = vCol * exp(-r * r * 6.0);
}
