// ============================================================================
// THE ARCADE — shared by prom_emit.gdshader (a prominence: emission off the
// limb) and prom_absorb.gdshader (a filament: absorption on the disc). One
// object, drawn twice; the two shaders differ only in their blend mode and in
// the last few lines of fragment(). Port of LINE_GLSL / ARC_VERT / ARC_FRAG in
// sim/prominence.js; the header of sim/prominence.gd carries the physics.
//
// The mesh carries NO shape: CUSTOM0 = (aThread, aS, aSide, aSeed).
//   aThread: -1..1 across the arcade   aS: 0..1 along the loop
//   aSide:   -1/+1 ribbon edge         aSeed: per-thread randomiser
// ============================================================================
#include "res://shaders/common/temp_pass.gdshaderinc"

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

varying float vS;
varying float vSide;
varying float vThread;
varying float vSeed;
varying vec3 vVP;
varying vec3 vCV;

// ---------------------------------------------------------------------------
// The field line. Local frame: +Y is the local vertical, +Z the bipole axis
// (so the footpoints separate along Z), +X the neutral line (so the arcade
// extends along X). Lengths in X and Z are tangent-plane offsets in stellar
// radii; Y is a RADIAL height, also in stellar radii, and onSphere() turns the
// triple into a point on or above the actual sphere — which is what keeps the
// footpoints welded to the surface instead of hovering over it on a big star.
// ---------------------------------------------------------------------------
float h1(float x) { return fract(sin(x * 127.1) * 43758.5453); }

vec3 fieldLine(float s, float k, float seed) {
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
	// SHEAR: the apex is displaced ALONG the neutral line relative to the
	// feet. This is the stored free energy, and it relaxes as the flare
	// proceeds (the caller winds uShear down).
	// The threads are also jittered off their nominal spacing — evenly spaced
	// identical loops read as a comb, and a comb is the one thing an arcade
	// never looks like.
	// The arcade also SPLAYS as it erupts: the rope expands sideways as it
	// rises, so the threads fan apart instead of climbing in parallel.
	float x = (k + (h1(seed + 2.2) - 0.5) * 0.16) * uLen * (1.0 + uErupt * 0.9)
	        + uShear * uSpan * sin(th);

	// TWIST: a flux rope is braided, and the braid tightens as it erupts.
	float ph = 6.2831853 * (uTwist * s + seed * 3.7);
	float amp = 0.055 * uSpan * (0.35 + uErupt);
	x += amp * cos(ph);
	y += amp * sin(ph) * 0.55;
	// and every thread sags differently under its own weight
	y -= 0.06 * uSpan * sin(th) * (h1(seed + 7.7) - 0.35);
	return vec3(x, y, z);
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
	vec4 mv = MODELVIEW_MATRIX * vec4(a, 1.0);
	vec4 mv2 = MODELVIEW_MATRIX * vec4(b, 1.0);
	// Ribbon: widen perpendicular to the loop AND to the line of sight, so a
	// thread is the same apparent thickness whichever way it runs. Done in
	// view space, which is camera-relative and therefore float-safe at the
	// distances this sim works at.
	vec3 tv = normalize(mv2.xyz - mv.xyz + vec3(1e-9));
	vec3 side = normalize(cross(tv, normalize(-mv.xyz)));
	float w = uWidth * uR * (0.55 + 0.9 * h1(aSeed + 1.3));
	// a loop is fatter at its apex, where the field has spread out
	w *= 0.7 + 0.6 * sin(3.14159265 * aS);
	// In ABSORPTION the threads are drawn fatter so they overlap into one
	// coherent dark spine. A filament on the disc is a single sinuous ribbon,
	// not a row of separate scratches — the threading is only resolvable off
	// the limb, where it is seen against the sky rather than through the
	// column of everything in front of it.
	w *= mix(1.0, 1.7, step(0.5, uMode));
	mv.xyz += side * (aSide * w);
	vVP = mv.xyz;
	vCV = (MODELVIEW_MATRIX * vec4(0.0, -uR, 0.0, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * mv;
}

float h2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h2(i), h2(i + vec2(1.0, 0.0)), f.x), mix(h2(i + vec2(0.0, 1.0)), h2(i + vec2(1.0, 1.0)), f.x), f.y);
}
float fbm2(vec2 p0) {
	vec2 p = p0;
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * n2(p); p *= 2.1; a *= 0.5; }
	return v;
}

// Everything the two passes share: returns the thread's weight `a` (before
// the disc test) and writes the colour, the footpoint term and onDisc.
float arcade_weight(out vec3 col, out float fp, out float onDisc) {
	// Optically thin thread: a soft Gaussian across, so the edges of a loop
	// are limb-brightened the way a hollow tube of emitting gas is.
	float prof = exp(-vSide * vSide * 2.7);
	// No two flux tubes carry the same amount of plasma.
	float tw = 0.45 + 1.05 * h2(vec2(vSeed * 31.0, 7.3));

	// Brightest at the feet. Particles accelerated at the reconnection site
	// run down the legs and stop where the density rises, which is why a
	// flaring loop has bright footpoints and a faint apex.
	fp = exp(-vS * 5.5) + exp(-(1.0 - vS) * 5.5);

	// Coronal rain: condensations sliding back down both legs.
	float dir = vS < 0.5 ? -1.0 : 1.0;
	float rain = 0.55 + 0.75 * fbm2(vec2(vS * 9.0 + dir * uTime * 0.55, vThread * 5.0 + vSeed * 17.0));

	// Reconnection walks ALONG the neutral line, so the arcade does not light
	// up all at once — each loop in the row brightens a little after its
	// neighbour.
	float stagger = clamp(uAmp * 1.6 - abs(vThread) * 0.55, 0.0, 1.0);

	float a = prof * (0.30 + 0.70 * fp) * rain * stagger * tw;
	// An erupting loop drains: the legs stay lit and the apex thins out and
	// goes, which is why a filament eruption looks like it is being pulled
	// apart rather than lifted off in one piece.
	a *= mix(1.0, 0.30 + 0.70 * abs(vS * 2.0 - 1.0), clamp(uErupt * 0.8, 0.0, 1.0));

	// Hot where the beam lands, cool prominence material higher up.
	col = mix(uCool, uHot, clamp(fp * 0.75 + uErupt * 0.35, 0.0, 1.0));

	// --- filament or prominence? The same material, and the only difference
	// is whether the photosphere is behind it. vCV is the star's centre in
	// view space, so the perpendicular distance from the line of sight to the
	// centre says whether this point projects inside the disc.
	vec3 n = normalize(vCV);
	float perp = length(vVP - n * dot(vVP, n));
	onDisc = 1.0 - smoothstep(uR * 0.96, uR * 1.02, perp);
	return a;
}
