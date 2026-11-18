// THE ARCADE, shared by prom_emit.gdshader (prominence: emission off the limb) and
// prom_absorb.gdshader (filament: absorption on the disc); they differ only in blend
// and the end of fragment(). Physics in sim/prominence.gd and
// docs/physics/stellar-surfaces.md.
//
// The mesh carries no shape: CUSTOM0 = (aThread, aS, aSide, aSeed).
//   aThread: -1..1 across the arcade   aS: 0..1 along the thread
//   aSide:   -1/+1 ribbon edge         aSeed: per-thread randomiser
#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/bodies/star_noise.gdshaderinc"

uniform float uR = 1.0;
uniform float uSpan = 0.22;
uniform float uLen = 0.30;
uniform float uHeight = 0.34;
uniform float uShear = 0.5;
uniform float uTwist = 0.6;
uniform float uErupt = 0.0;
uniform float uWidth = 0.012;
uniform float uTime = 0.0;
uniform float uMode = 0.0;
uniform float uAmp = 0.0;
uniform float uPlasmaT = 1.2e7;
uniform vec3 uCool = vec3(1.0, 0.4, 0.2);
uniform vec3 uHot = vec3(1.0);
// 0: brightest at the feet (an impulsive flare, chromospheric material); 1: along the
// whole loop and brightest at the top (hot coronal loops, a post-flare arcade).
uniform float uApex = 0.0;
// Visible-light gain of the emission. Coronal loops are million-kelvin plasma, nearly
// invisible in white light but bright in X-ray, where the temperature pass decides.
uniform float uGlow = 1.0;
// 0: loops across the neutral line (an arcade); 1: a flux rope along it, its threads
// wound about one axis; 2: a quiescent hedgerow, a curtain of near-vertical threads.
uniform float uKind = 0.0;
// How fast condensations stream along the field, in thread lengths per second.
uniform float uFlow = 0.35;

varying float vS;
varying float vSide;
varying float vThread;
varying float vSeed;
varying vec3 vVP;
varying vec3 vCV;

// A drawn ribbon is this many thread widths wide: the thread and its glow.
const float HALO = 3.2;

// Local frame: +Y vertical, +Z the bipole axis (footpoints of an arcade loop separate
// along Z), +X the neutral line. X and Z are tangent-plane offsets in stellar radii,
// Y a radial height; onSphere() keeps the footpoints on the surface.
float h1(float x) { return fract(sin(x * 127.1) * 43758.5453); }

vec3 arcadeLine(float s, float k, float seed) {
	float taper = sqrt(max(1.0 - k * k, 0.0));
	// Loops near the ends of the arcade are shorter and lower: the neutral
	// line has ends, and the field closes down at them.
	float w = uSpan  * (0.42 + 0.58 * taper) * (0.85 + 0.30 * h1(seed));
	float h = uHeight * pow(max(taper, 1e-3), 0.55) * (0.50 + 1.05 * h1(seed + 3.1));
	// The eruption: the rope rises and stretches, faster than it widens.
	h *= 1.0 + uErupt * 2.8;
	w *= 1.0 + uErupt * 0.65;

	float th = 3.14159265 * s;
	float z = -w * cos(th);
	float y =  h * sin(th);
	// SHEAR: the apex displaced along the neutral line (the stored energy, wound down by
	// the caller via uShear). Threads jittered off even spacing (not a comb).
	float x = (k + (h1(seed + 2.2) - 0.5) * 0.16) * uLen * (1.0 + uErupt * 0.9)
	        + uShear * uSpan * sin(th);
	// TWIST, and the kink waves that run along every loop.
	float ph = 6.2831853 * (uTwist * s + seed * 3.7);
	float amp = 0.055 * uSpan * (0.35 + uErupt);
	x += amp * cos(ph);
	y += amp * sin(ph) * 0.55;
	x += 0.03 * uSpan * sin(th) * sin(th * 3.0 - uTime * (0.6 + h1(seed + 4.0)) + seed * 9.0);
	// and every thread sags differently under its own weight
	y -= 0.06 * uSpan * sin(th) * (h1(seed + 7.7) - 0.35);
	return vec3(x, y, z);
}

// The rope's axis runs along the neutral line, rooted at both of its ends and sheared
// across it; a kinking rope writhes into an S as its twist turns into writhe.
vec3 ropeAxis(float s) {
	float th = 3.14159265 * s;
	float L = uLen * (1.0 + 0.8 * uErupt);
	float H = uHeight * (0.45 + 3.2 * uErupt * uErupt + 0.8 * uErupt);
	vec3 a = vec3(-0.5 * L * cos(th), H * pow(max(sin(th), 0.0), 0.75), -uShear * uSpan * cos(th));
	a.z += uErupt * 0.35 * L * sin(2.0 * th);
	return a;
}

vec3 ropeLine(float s, float k, float seed) {
	vec3 a = ropeAxis(s);
	vec3 t = normalize(ropeAxis(min(s + 0.01, 1.0)) - ropeAxis(max(s - 0.01, 0.0)) + vec3(1e-6));
	vec3 n1 = normalize(cross(t, vec3(0.0, 1.0, 0.0)) + vec3(0.0, 0.0, 1e-6));
	vec3 n2 = cross(t, n1);
	float th = 3.14159265 * s;
	// The threads fray away from the axis as the rope expands.
	float rho = uSpan * 0.42 * (0.2 + 0.8 * sqrt(h1(seed + 1.9)))
	          * (1.0 + uErupt * (1.0 + 1.6 * h1(seed + 9.1))) * (0.45 + 0.55 * sin(th));
	float phi = 6.2831853 * (h1(seed + 5.3) + (0.5 + uTwist) * s) + k * 3.14159265;
	vec3 p = a + rho * (cos(phi) * n1 + sin(phi) * n2);
	// Torn, sagging material under the rising rope.
	p.y -= uSpan * 0.25 * uErupt * h1(seed + 6.6) * sin(th);
	return p;
}

// A hedgerow prominence (Berger et al. 2008): a thin curtain of near-vertical threads
// along the neutral line, its top ragged, its material raining down through it.
vec3 hedgeLine(float s, float k, float seed) {
	float env = sqrt(max(1.0 - k * k, 0.0));
	float top = uHeight * pow(env, 0.6) * (0.35 + 0.65 * h1(seed + 3.1))
	          * (0.55 + 0.9 * sn_noise(vec3(k * 4.0, 1.0, 0.0)));
	float x = (k + (h1(seed + 2.2) - 0.5) * 0.05) * uLen * 0.5;
	x += uSpan * 0.5 * s * sin(s * 2.3 + seed * 5.0 + uTime * 0.03);
	float z = uSpan * ((h1(seed + 4.4) - 0.5) * 1.6 + 0.4 * sin(s * 3.0 + k * 9.0 + uTime * 0.04));
	return vec3(x, s * top, z);
}

vec3 fieldLine(float s, float k, float seed) {
	if (uKind > 1.5) return hedgeLine(s, k, seed);
	if (uKind > 0.5) return ropeLine(s, k, seed);
	return arcadeLine(s, k, seed);
}

// Tangent offsets to a real point above a real sphere. The star's centre is
// at (0, -uR, 0) in this frame.
vec3 onSphere(vec3 p) {
	vec3 dir = normalize(vec3(p.x, 1.0, p.z));
	return dir * (uR * (1.0 + p.y)) - vec3(0.0, uR, 0.0);
}

void vertex() {
	float aThread = CUSTOM0.x;
	float aS = CUSTOM0.y;
	float aSide = CUSTOM0.z;
	float aSeed = CUSTOM0.w;
	vS = aS; vSide = aSide; vThread = aThread; vSeed = aSeed;
	vec3 a = onSphere(fieldLine(aS, aThread, aSeed));
	vec3 b = onSphere(fieldLine(min(aS + 0.015, 1.0), aThread, aSeed));
	if (aS > 0.985) b = 2.0 * a - onSphere(fieldLine(aS - 0.015, aThread, aSeed));
	vec4 mv = MODELVIEW_MATRIX * vec4(a, 1.0);
	vec4 mv2 = MODELVIEW_MATRIX * vec4(b, 1.0);
	// Widen the ribbon perpendicular to both the thread and the line of sight, in view
	// space.
	vec3 tv = normalize(mv2.xyz - mv.xyz + vec3(1e-9));
	vec3 eye = normalize(-mv.xyz);
	vec3 sr = cross(tv, eye);
	float sl = length(sr);
	// Where the thread runs along the sight line the cross product has no direction:
	// fall back to one across the arcade's own axis, and thin the ribbon, since a tube
	// seen end-on is a point.
	vec3 fb = normalize(cross(normalize((MODELVIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz + vec3(1e-6)), eye) + vec3(1e-6));
	fb *= dot(fb, sr) < 0.0 ? -1.0 : 1.0;
	vec3 side = normalize(mix(fb, sr / max(sl, 1e-6), smoothstep(0.05, 0.3, sl)) + vec3(1e-6));
	float w = uWidth * uR * (0.55 + 0.9 * h1(aSeed + 1.3)) * HALO * mix(0.35, 1.0, smoothstep(0.05, 0.35, sl));
	// a loop is fatter at its apex, where the field has spread out
	w *= uKind > 1.5 ? 1.6 : 0.7 + 0.6 * sin(3.14159265 * aS);
	// Fatter in absorption, so the threads merge into one dark filament spine.
	w *= mix(1.0, 1.7, step(0.5, uMode));
	mv.xyz += side * (aSide * w);
	vVP = mv.xyz;
	vCV = (MODELVIEW_MATRIX * vec4(0.0, -uR, 0.0, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * mv;
}

// Everything the two passes share: returns the thread's weight `a` (before
// the disc test) and writes the colour, the footpoint term and onDisc.
float arcade_weight(out vec3 col, out float fp, out float onDisc) {
	// Optically thin thread: a bright core and the glow around it, falling to zero at
	// the ribbon's edge. Inside the core, finer strands run along the field.
	float x = vSide * HALO;
	float core = exp(-x * x * 2.7);
	float halo = exp(-x * x * 0.45) * (1.0 - vSide * vSide) * (uKind > 1.5 ? 0.55 : 0.30);
	float strands = 0.65 + 0.35 * sin(vSide * 9.0 + vSeed * 40.0 + vS * 2.0);
	float prof = core * strands + halo;
	// No two flux tubes carry the same amount of plasma.
	float tw = 0.45 + 1.05 * fract(sin(vSeed * 31.0 * 127.1 + 7.3) * 43758.5453);

	// Brightest at the feet, where accelerated particles stop.
	fp = exp(-vS * 5.5) + exp(-(1.0 - vS) * 5.5);

	// FLOWS: condensations stream along the field. Down both legs of a loop (coronal
	// rain), out along a rope and down its legs as it drains, and down through a hedgerow.
	float dir = vS < 0.5 ? -1.0 : 1.0;
	if (uKind > 1.5) dir = 1.0;
	float lane = vThread * 5.0 + vSeed * 17.0;
	float knots = sn_fbm(vec3(vS * 11.0 + dir * uTime * uFlow * 3.0, lane, vSeed), 3);
	float blobs = pow(sn_noise(vec3(vS * 26.0 + dir * uTime * uFlow * 5.0, lane * 1.7, 2.0)), 2.0);
	float flow = 0.35 + 0.9 * knots + 0.8 * blobs;

	// Each loop lights a little after its neighbour along the neutral line.
	float stagger = clamp(uAmp * 1.6 - abs(vThread) * 0.55, 0.0, 1.0);
	if (uKind > 0.5) stagger = clamp(uAmp * 1.4, 0.0, 1.0);

	float top = sin(3.14159265 * vS);
	float along = mix(0.30 + 0.70 * fp, 0.40 + 0.45 * top + 0.35 * fp, uApex);
	if (uKind > 1.5) along = smoothstep(0.0, 0.06, vS) * (1.0 - smoothstep(0.55, 1.0, vS)) * 0.9;
	float a = prof * along * flow * stagger * tw;
	// An erupting rope drains: legs stay lit, the apex thins.
	a *= mix(1.0, 0.35 + 0.65 * abs(vS * 2.0 - 1.0), clamp(uErupt * 0.7, 0.0, 1.0));

	// Hot where the beam lands, cool prominence material higher up; the densest knots
	// are the brightest.
	float hotMix = uKind > 1.5 ? 0.0 : (uKind > 0.5 ? 0.35 * fp * fp : clamp(fp * 0.75 + uErupt * 0.25, 0.0, 1.0));
	col = mix(uCool, uHot, hotMix);
	// Many threads overlap along any sight line: keep a tube from summing to white.
	a *= uKind > 1.5 ? 0.45 : (uKind > 0.5 ? 0.22 : 0.65);

	// --- filament or prominence: whether the sight line to this point passes inside the
	// disc, from its closest approach to the star's centre (vCV), exact at any distance.
	vec3 d = normalize(vVP);
	float b = length(vCV - d * dot(vCV, d));
	onDisc = 1.0 - smoothstep(uR * 0.985, uR * 1.01, b);
	return a;
}
