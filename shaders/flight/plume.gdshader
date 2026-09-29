// ============================================================================
// ONE ENGINE'S PLUME — a raymarched volume of emission and soot.
// ----------------------------------------------------------------------------
// The web build drew a plume as the SURFACE of a tube whose radius was bent
// in the vertex shader, with the light painted onto that surface. A flame is
// not a surface: it is a volume of glowing gas, and what reaches the eye is
// the emission INTEGRATED along the line of sight, dimmed by whatever soot is
// in front of it. A tube cannot do the three things that make a real plume
// read as one — it has a hard silhouette, it looks the same end-on as side-on,
// and nothing inside it can be in front of anything else. So this marches the
// ray through the jet's own field, from a bounding cylinder drawn back-faced
// (so it works from inside, too), and stops at the depth buffer (so the
// rocket's own base and the ground in front of the flame hide it).
//
// THE FIELD, in the jet's own units (De = exit diameter), and every part of
// it set by a number the flight model already has:
//
//   PRESSURE RATIO  PR = p_exit / p_ambient. This is the whole shape story.
//     PR < 1, OVER-EXPANDED (sea level): the air squeezes the jet in and it
//     recompresses through a train of oblique shocks — the SHOCK DIAMONDS —
//     and, if PR is low enough, a normal shock across the axis: the MACH
//     DISK, the hard white knot an RS-25 has a metre below its bell and a
//     Merlin does not (its PR at sea level is ~0.6, the SSME's ~0.16).
//     PR > 1, UNDER-EXPANDED (altitude): the jet turns the corner at the lip
//     and balloons; the diamonds stretch (cell length ∝ √PR) and go.
//     PR → ∞ (vacuum): a vast, faint, structureless bell.
//   CELL LENGTH  Ls ≈ 0.45 De √(M² − 1) √PR + 0.4 De: Prandtl's √(M² − 1) is
//     the angle an expansion wave makes with the flow; √PR is the jet getting
//     wider and the waves longer as the air thins.
//   CORE  the supersonic potential core, a few De long at sea level: the
//     mixing layer eats in from the edge until it reaches the axis.
//   MIXING LAYER  a turbulent shear layer at the jet's edge, growing ~0.1 De
//     per De. Fuel-rich exhaust meets air there and BURNS AGAIN, which is
//     where most of a kerosene plume's light comes from — so it is brightest
//     in an annulus, and it is turbulent, advected downstream at a fraction of
//     the exhaust speed and regenerated rather than scrolled.
//   SOOT  carbon from a fuel-rich kerosene engine: it both GLOWS (the orange
//     of a kerolox plume is incandescent soot at ~2000 K) and ABSORBS (the
//     brown-black smoke). The F-1 dumped its gas-generator exhaust into the
//     nozzle extension as a film coolant, so the first couple of diameters of
//     a Saturn V's plume are wrapped in a dark, cool, sooty sleeve before the
//     film ignites — the single most recognisable thing about the S-IC's fire.
//     A solid's alumina is the other kind: it scatters, bright and white.
//
// EMISSION IS IN HDR and the colour is the propellant's (see sim/flight/plume.gd
// for the table). BLENDING is premultiplied: rgb is the light emitted (and,
// for smoke, scattered) along the ray, alpha the soot's COVERAGE — a sooty
// plume genuinely hides the sky behind it, a hydrogen one hides nothing.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;

uniform vec3 uBox = vec3(1.0);        // bounding cylinder: (radius, length, radius), m
uniform float uRe = 0.5;              // exit radius, m
uniform float uThrottle = 0.0;        // 0..1
uniform float uPR = 1.0;              // p_exit / p_ambient
uniform float uMach = 3.5;            // exit Mach number
uniform float uTime = 0.0;
uniform float uSeed = 0.0;            // per engine: no two flicker alike

uniform vec3 uCore = vec3(1.0, 0.85, 0.55);     // supersonic core, HDR per unit
uniform vec3 uShock = vec3(1.0, 0.95, 0.85);    // diamonds and the Mach disk
uniform vec3 uMix = vec3(1.0, 0.45, 0.12);      // afterburning mixing layer
uniform vec3 uTail = vec3(0.7, 0.22, 0.05);     // cooling downstream
uniform vec3 uSmoke = vec3(0.05, 0.04, 0.03);   // what the soot scatters, lit
uniform float uCoreLen = 5.0;         // potential core at sea level, De
uniform float uBright = 1.0;          // overall emission
uniform float uDiamonds = 1.0;        // shock-structure strength
uniform float uMachDisk = 0.0;        // normal-shock strength when over-expanded
uniform float uAfterburn = 1.0;       // how much the mixing layer burns
uniform float uSoot = 0.0;            // absorbing smoke in the tail
uniform float uFilm = 0.0;            // the F-1's dark film-cooling sleeve
uniform float uBeam = 0.0;            // 1: a collimated beam (ion, photon drive)
uniform float uNear = 0.0;            // 1: near field only (a cluster's far field is drawn merged)
uniform float uFar = 0.0;             // 1: a cluster's merged far field, fading in downstream
uniform float uTempCode = 0.32;       // ln(T)/25.33 — the web build's publish factor
uniform int uSteps = 26;

varying vec3 vLocal;                  // this fragment, in the plume's frame, m
varying flat vec3 vCam;               // the camera, in the plume's frame, m

void vertex() {
	vLocal = VERTEX * uBox;
	VERTEX = vLocal;
	vCam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz;
}

// ---- noise: value noise, trilinear, and a 3-octave sum
float hash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float vnoise(vec3 p) {
	vec3 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash13(i), hash13(i + vec3(1, 0, 0)), f.x),
	               mix(hash13(i + vec3(0, 1, 0)), hash13(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(hash13(i + vec3(0, 0, 1)), hash13(i + vec3(1, 0, 1)), f.x),
	               mix(hash13(i + vec3(0, 1, 1)), hash13(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}
float fbm3(vec3 p) {
	return vnoise(p) * 0.55 + vnoise(p * 2.13 + 7.1) * 0.30 + vnoise(p * 4.37 + 3.3) * 0.15;
}

float ign(vec2 p) {
	return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

// The jet's radius at axial distance x (both in De), in exit radii.
float jet_radius(float x, float over, float under) {
	// over-expanded: pinched toward the first cell, then a slow ~4° spread
	float pinch = 1.0 - 0.16 * over * sin(3.14159 * clamp(x / 1.2, 0.0, 1.0));
	float sea = pinch + 0.14 * x;
	// under-expanded: turns the corner at the lip — nearly all of the spread
	// happens inside the first diameter, then it is ballistic
	float vac = 1.0 + under * 2.6 * pow(max(x, 0.0), 0.62) + 0.05 * x;
	float r = mix(sea, vac, clamp(under, 0.0, 1.0));
	// a beam does not spread: that is the whole difference from a flame
	return mix(r, 1.0 + 0.03 * x, uBeam);
}

void fragment() {
	if (uThrottle <= 0.001) discard;
	vec3 ro = vCam;
	vec3 rd = normalize(vLocal - vCam);
	float R = uBox.x;
	float L = uBox.y;
	// ---- the ray inside the bounding cylinder (y from −L to 0, radius R)
	float a = dot(rd.xz, rd.xz);
	float b = dot(ro.xz, rd.xz);
	float c = dot(ro.xz, ro.xz) - R * R;
	float disc = b * b - a * c;
	if (disc <= 0.0 || a < 1e-8) discard;
	float sq = sqrt(disc);
	float tc0 = (-b - sq) / a, tc1 = (-b + sq) / a;
	float ty0 = (-L - ro.y) / (abs(rd.y) > 1e-6 ? rd.y : 1e-6);
	float ty1 = (0.0 - ro.y) / (abs(rd.y) > 1e-6 ? rd.y : 1e-6);
	float t0 = max(max(tc0, min(ty0, ty1)), 0.0);
	float t1 = min(tc1, max(ty0, ty1));
	// the scene in front ends the ray (the vehicle's base, the deck, the ground)
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(v.xyz / v.w));
	if (t1 <= t0) discard;

	float De = 2.0 * uRe;
	float pr = max(uPR, 1e-3);
	// 0..1 measures of how over- and under-expanded the jet is
	float over = clamp(1.0 - pr, 0.0, 1.0);
	float under = clamp(log(max(pr, 1.0)) / log(300.0), 0.0, 1.0);
	float cell = 0.45 * sqrt(max(uMach * uMach - 1.0, 0.2)) * sqrt(clamp(pr, 0.05, 40.0)) + 0.4;
	// the diamonds exist while there is an ambient pressure to be wrong about
	float dia = uDiamonds * (1.0 - smoothstep(1.5, 12.0, pr)) * (1.0 - uBeam);
	float coreLen = uCoreLen * (1.0 + 3.0 * under);
	float Lx = L / De;                   // the plume's length, in De
	float thr = 0.35 + 0.65 * uThrottle;
	float flow = uTime * (6.0 + 10.0 * uThrottle);   // turbulence carried downstream, De/s

	float jitter = ign(FRAGCOORD.xy);
	float dt = (t1 - t0) / float(uSteps);
	vec3 col = vec3(0.0);
	float T = 1.0;
	for (int i = 0; i < 48; i++) {
		if (i >= uSteps) break;
		float t = t0 + (float(i) + jitter) * dt;
		vec3 p = ro + rd * t;
		float x = -p.y / De;             // downstream, in De
		if (x < 0.0) continue;
		float r = length(p.xz) / uRe;    // off axis, in exit radii
		float Rj = jet_radius(x, over, under);
		float rho = r / Rj;
		if (rho > 1.9) continue;
		float fade_end = 1.0 - smoothstep(0.55, 1.0, x / Lx);
		// a cluster's single engines hand over to the merged far field
		// (overlapping, so the hand-over never leaves a gap in the fire)
		float nearK = mix(1.0, 1.0 - smoothstep(2.5, 6.0, x), uNear);
		float farK = mix(1.0, smoothstep(0.15, 0.9, x), uFar);
		float along = fade_end * nearK * farK;
		if (along <= 0.0) continue;

		// ---- turbulence, advected downstream and regenerated (two scales)
		// stretched along the flow, because the eddies are: a shear layer's
		// structures are drawn out downstream before they break up
		vec3 q = vec3(p.x / De, x - flow, p.z / De);
		float turb = fbm3(q * vec3(2.4, 0.85, 2.4) + uSeed);
		float turb2 = fbm3(q * vec3(7.0, 2.2, 7.0) - uSeed * 1.7 + vec3(0.0, flow * 0.6, 0.0));
		turb = mix(turb, 0.55, uBeam);

		// ---- 1. the supersonic core: hot, bright, smooth
		float inCore = 1.0 - smoothstep(coreLen * 0.55, coreLen * 1.25, x);
		float core = exp(-rho * rho * 3.5) * inCore;

		// ---- 2. shock structure: X-shaped oblique shocks and bright cells
		float ph = x / cell;
		float tri = abs(1.0 - 2.0 * fract(ph));             // the shock's radius, rises and falls
		// (squares by multiplication: pow() of a negative base is undefined)
		float sd = (min(rho, 1.2) - tri) / 0.13;
		float shock = exp(-sd * sd) * 0.5
		            + exp(-rho * rho * 7.0) * pow(0.5 + 0.5 * cos(6.2831853 * ph), 5.0);
		shock *= dia * exp(-ph * 0.28) * inCore;
		// the Mach disk: a normal shock ~0.6–0.9 cell downstream, when PR is low
		float xm = cell * (0.55 + 0.35 * pr);
		float dm = (x - xm) / 0.09;
		float disk = exp(-dm * dm) * exp(-rho * rho * 5.0)
		           * uMachDisk * smoothstep(0.25, 0.8, over);

		// ---- 3. the mixing layer: an annulus at the jet's edge, burning
		float w = 0.22 + 0.05 * x;
		float sh = (rho - 0.92) / w;
		float shell = exp(-sh * sh);
		float fill = smoothstep(1.25, 0.2, rho) * smoothstep(coreLen * 0.4, coreLen * 1.6, x);
		// hard contrast, so the turbulence EATS the flame into tongues rather
		// than shading a smooth one
		float lick = clamp(turb * 1.7 - 0.35, 0.0, 1.0);
		float burn = uAfterburn * (shell * 0.8 + fill * 0.9) * (0.15 + 2.2 * lick * lick) * (0.6 + 0.8 * turb2)
		           * smoothstep(0.2, 1.4, x) * (0.1 + 0.9 * (1.0 - under));
		// Mass is conserved: a jet that has ballooned to Rj exit radii carries
		// the same gas through Rj² times the area, so what glows per metre
		// falls as 1/Rj². Without it, a first stage at 50 km (PR ≈ 500, a bell
		// 27 exit radii across) filled that whole bell with afterburning flame
		// and drew a solid orange orb a quarter of a kilometre wide around the
		// vehicle. The vacuum bell below already obeyed this.
		burn *= mix(1.0, 1.0 / (Rj * Rj), under);
		// in vacuum there is nothing to burn with and nothing to shear on: a
		// smooth, faint bell whose light falls off as it spreads
		// (thin: a vacuum plume is a glow you can see the stars through)
		float bell = under * exp(-rho * rho * 1.6) * 0.14 / (Rj * Rj) * (0.8 + 0.4 * turb);

		// ---- colour: core → mixing → tail as the gas cools downstream
		float cool = smoothstep(coreLen * 0.6, Lx * 0.8, x);
		vec3 e = uCore * core * 2.2 + uShock * (shock * 3.0 + disk * 5.0)
		       + mix(uMix, uTail, cool) * burn + mix(uCore, uMix, 0.5) * bell;
		// a beam is its core and nothing else
		e = mix(e, uCore * exp(-rho * rho * 2.0) * (0.8 + 0.2 * turb2), uBeam);

		// ---- 4. the F-1's film sleeve: cool, fuel-rich, dark, igniting
		// raggedly over the first couple of diameters
		float film = uFilm * smoothstep(0.55, 0.95, rho) * (1.0 - smoothstep(1.2, 2.6 + turb * 1.2, x))
		           * (1.0 - under);
		e *= 1.0 - film * 0.92;

		// ---- 5. soot: absorbs, and scatters a little (brown for carbon,
		// white for a solid's alumina). Thickest in the tail and at the edge.
		// In streaks, not a sheet: soot is carried in the same eddies as the
		// flame, and between them is clear burning gas.
		float streak = clamp(turb2 * 1.8 - 0.55, 0.0, 1.0);
		float soot = uSoot * (0.2 + 1.3 * streak * turb) * (smoothstep(0.25, 0.9, x / Lx) * 1.1 + film * 3.0)
		           * smoothstep(1.8, 0.5, rho) * (1.0 - under) * along;
		float sigma = soot * 0.8 / De;   // per metre

		vec3 em = e * uBright * thr * along / De;    // emission per metre
		float ds = dt;
		float Ts = exp(-sigma * ds);
		// emission + in-scattered smoke, integrated across the step
		col += T * (em * ds + uSmoke * (1.0 - Ts) * along);
		T *= Ts;
		if (T < 0.02) break;
	}
	float alpha = 1.0 - T;
	if (max(col.r, max(col.g, col.b)) < 1e-4 && alpha < 0.002) discard;
	// the web build's published temperature code was also the colour's source
	// factor; it is kept, so the plume sits at the same brightness it did
	ALBEDO = col * uTempCode * 2.4;
	ALPHA = alpha;
}
