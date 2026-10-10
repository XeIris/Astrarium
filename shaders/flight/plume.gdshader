// ONE ENGINE'S PLUME: a raymarched volume of emission and soot, marched from a
// back-faced bounding cylinder (so it works from inside) and stopped at the depth
// buffer. In the jet's own units (De = exit diameter):
//   PRESSURE RATIO  PR = p_exit / p_ambient.
//     PR < 1, over-expanded: shock diamonds, and at low enough PR a Mach disk (an
//     RS-25's PR at sea level is ~0.16, a Merlin's ~0.6).
//     PR > 1, under-expanded: the jet balloons and the cells stretch (∝ √PR).
//     PR → ∞: a faint structureless bell.
//   CELL LENGTH  Ls ≈ 0.45 De √(M² − 1) √PR + 0.4 De (Prandtl's expansion-wave angle).
//   CORE  the supersonic potential core, a few De at sea level.
//   MIXING LAYER  a turbulent shear layer growing ~0.1 De per De, where fuel-rich
//     exhaust afterburns (most of a kerosene plume's light): bright in an annulus,
//     advected downstream and regenerated.
//   SOOT  glows (kerolox's orange, ~2000 K) and absorbs. The F-1's film-coolant
//     sleeve is a dark sooty wrap for the first diameters. Alumina scatters white.
//   FLAME AND SMOKE  in air the afterburning burns out within about a vehicle length
//     (uFlame, a fraction of the box); past it the exhaust is soot and condensing
//     water, a grey column scattering daylight (uTrail) that hands over to the
//     world-fixed trail (Plume.SmokeColumn).
//   BALLOON  high up, the far field swells to the radius where its pressure meets the
//     ambient plus the freestream's dynamic pressure (uBalloon, in exit radii). Its
//     boundary is a shock-heated, turbulent shell. See docs/physics/plumes.md.
// Emission is HDR in the propellant's colour (plume.gd). Premultiplied: rgb emitted
// light, alpha soot coverage.
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
uniform float uTempCode = 0.32;       // ln(T)/25.33, the temperature code
uniform int uSteps = 26;
uniform float uBalloon = 1.0;         // equilibrium radius of the far field, exit radii
uniform float uHi = 0.0;              // 0 near the ground, 1 fully ballooned
uniform float uShellK = 0.0;          // shock heating of the boundary, 0 in vacuum
uniform float uFlame = 1.0;           // where the luminous flame ends, fraction of the length
uniform vec3 uTrail = vec3(0.0);      // the exhaust smoke's colour in this light (premultiplied by 1/calibration)
uniform float uTrailK = 0.0;          // its density: soot and condensation, thinning with altitude

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

// The ballooned boundary at x (in equilibrium radii), in exit radii: it turns the
// corner within one radius, holds, then the freestream slowly narrows it.
float balloon_radius(float xr) {
	float B = uBalloon;
	float grow = 1.0 - exp(-xr * 2.6);
	return (1.0 + (B - 1.0) * grow) * (1.0 - 0.38 * smoothstep(1.2, 6.5, xr));
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
	float Req = uBalloon * uRe;          // equilibrium radius, m
	for (int i = 0; i < 96; i++) {
		if (i >= uSteps) break;
		float t = t0 + (float(i) + jitter) * dt;
		vec3 p = ro + rd * t;
		float x = -p.y / De;             // downstream, in De
		float r = length(p.xz) / uRe;    // off axis, in exit radii
		bool in_hi = false;
		vec3 em_hi = vec3(0.0);
		float sig_hi = 0.0;
		if (uHi > 0.0) {
			// ---- the ballooned far field. Large lobes carried downstream, so the
			// boundary billows like a fire rather than a cone.
			float xr = -p.y / Req;
			vec3 qb = vec3(p.x / Req, xr - uTime * 0.9, p.z / Req);
			// Stretched along the flow: the recirculated film coolant burns in sheets
			// streaming back from the base, not round lobes (docs/physics/plumes.md).
			float lobe = fbm3(qb * vec3(1.7, 0.38, 1.7) + uSeed);
			float Rb = balloon_radius(xr) * (1.0 + 0.6 * (lobe - 0.5));
			float rb = r / Rb;
			float tail = 1.0 - smoothstep(3.0, 6.3, xr);
			if (rb < 1.35 && tail > 0.0) {
				float fine = fbm3(vec3(p.x / Req * 5.5, xr * 1.1 - uTime * 2.4, p.z / Req * 5.5) - uSeed);
				float sb = (rb - 0.86) / 0.2;
				float shell = exp(-sb * sb);
				float fill = exp(-rb * rb * 1.8) * 0.35;
				float tongue = clamp(fine * 1.9 - 0.45, 0.0, 1.0);
				// Incandescent soot carries the light; a clean hydrogen plume barely shows.
				float inc = clamp(uSoot * 1.15 + uAfterburn * 0.12, 0.0, 1.0);
				float coolB = smoothstep(0.0, 4.5, xr);
				// Hottest in the tongues the shock heats, cooling to dull red downstream.
				vec3 c = mix(uMix, uTail, coolB);
				float dens = (shell * (0.25 + 2.2 * tongue * tongue) + fill * (0.3 + 0.7 * lobe)) * tail;
				// Per metre ∝ 1/R_eq, so a path across the swollen plume carries the light
				// and the narrow neck at the exit stays dim: the heating develops
				// where the freestream meets the boundary.
				em_hi = c * dens * inc * (0.2 + 0.8 * uShellK) * uHi * 1.1 * (1.3 - 0.5 * coolB) / Req;
				// Soot that has stopped glowing: the brown streaks between the tongues.
				sig_hi = uSoot * dens * (1.0 - 0.6 * tongue) * 1.7 * uHi / Req;
				in_hi = true;
			}
		}
		if (x < 0.0) continue;
		float Rj = jet_radius(x, over, under);
		float rho = r / Rj;
		if (rho > (uTrailK > 0.0 ? 2.6 : 1.9) && !in_hi) continue;
		float fade_end = 1.0 - smoothstep(0.55, 1.0, x / Lx);
		// a cluster's single engines hand over to the merged far field
		// (overlapping, so the hand-over never leaves a gap in the fire)
		float nearK = mix(1.0, 1.0 - smoothstep(2.5, 6.0, x), uNear);
		float farK = mix(1.0, smoothstep(0.15, 0.9, x), uFar);
		float along = fade_end * nearK * farK;
		if (along <= 0.0 && !in_hi) continue;

		// ---- turbulence, advected and regenerated at two scales, stretched along the flow.
		vec3 q = vec3(p.x / De, x - flow, p.z / De);
		float turb = fbm3(q * vec3(2.4, 0.85, 2.4) + uSeed);
		float turb2 = fbm3(q * vec3(7.0, 2.2, 7.0) - uSeed * 1.7 + vec3(0.0, flow * 0.6, 0.0));
		turb = mix(turb, 0.55, uBeam);

		// ---- 1. the supersonic core: hot, bright, smooth
		float inCore = 1.0 - smoothstep(coreLen * 0.55, coreLen * 1.25, x);
		// An under-expanded core cools as it expands: it dims with the pressure ratio.
		float core = exp(-rho * rho * 3.5) * inCore * (1.0 - 0.75 * under);

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
		// Mass is conserved: a jet ballooned to Rj exit radii glows ∝ 1/Rj² per metre.
		burn *= mix(1.0, 1.0 / (Rj * Rj), under);
		// In vacuum: a smooth, faint bell you can see stars through.
		float bell = under * exp(-rho * rho * 1.6) * 0.14 / (Rj * Rj) * (0.8 + 0.4 * turb);

		// ---- the flame burns out; the rest is smoke
		float fx = x / Lx;
		float lum = 1.0 - smoothstep(uFlame * 0.55, uFlame, fx);
		burn *= lum;
		bell *= mix(1.0, lum, 1.0 - under);

		// ---- colour: core → mixing → tail as the gas cools downstream
		float cool = smoothstep(coreLen * 0.6, Lx * uFlame * 0.85, x);
		vec3 e = uCore * core * 2.2 + uShock * (shock * 3.0 + disk * 5.0)
		       + mix(uMix, uTail, cool) * burn + mix(uCore, uMix, 0.5) * bell;
		// a beam is its core and nothing else
		e = mix(e, uCore * exp(-rho * rho * 2.0) * (0.8 + 0.2 * turb2), uBeam);
		// High up a cluster's single near fields have expanded and cooled: dimmer,
		// and the colour of the mixing layer rather than the white core.
		e = mix(e, dot(e, vec3(0.3333)) * uMix * 1.3, under * uNear * 0.7) * (1.0 - 0.55 * under * uNear);

		// ---- 4. the F-1's film sleeve: cool, fuel-rich, dark, igniting
		// raggedly over the first couple of diameters
		float film = uFilm * smoothstep(0.55, 0.95, rho) * (1.0 - smoothstep(1.2, 2.6 + turb * 1.2, x))
		           * (1.0 - under);
		e *= 1.0 - film * 0.92;

		// ---- 5. soot: absorbs and scatters a little (brown carbon, white alumina),
		// thickest in the tail and edge, in streaks carried by the eddies.
		float streak = clamp(turb2 * 1.8 - 0.55, 0.0, 1.0);
		float soot = uSoot * (0.2 + 1.3 * streak * turb) * (smoothstep(0.25, 0.9, x / Lx) * 1.1 + film * 3.0)
		           * smoothstep(1.8, 0.5, rho) * (1.0 - under) * along;
		float sigma = soot * 0.8 / De;   // per metre
		// The exhaust column past the flame: widening, billowed by the large eddies,
		// thinning toward the box's end where the world trail takes over.
		float smk = 0.0;
		if (uTrailK > 0.0) {
			float rs = rho / (1.0 + 0.9 * smoothstep(uFlame * 0.4, 1.0, fx));
			// Lumpy, not a tube: the eddies push the edge in and out and leave clear gaps.
			float body = smoothstep(1.2, 0.45, rs + (turb - 0.5) * 1.3);
			smk = uTrailK * body * smoothstep(uFlame * 0.35, uFlame * 0.95, fx)
			    * (1.0 - smoothstep(0.85, 1.0, fx)) * (0.15 + 1.6 * turb2 * turb2);
		}
		sigma += smk * 1.6 / De;

		vec3 em = e * uBright * thr * along / De + em_hi * uBright * thr;    // emission per metre
		sigma += sig_hi;
		float ds = dt;
		float Ts = exp(-sigma * ds);
		// emission + in-scattered smoke, integrated across the step
		// the in-scattered light shares the step's extinction between soot and smoke
		float sk = sigma > 0.0 ? smk * 1.6 / De / sigma : 0.0;
		col += T * (em * ds + mix(uSmoke * along, uTrail, sk) * (1.0 - Ts));
		T *= Ts;
		if (T < 0.02) break;
	}
	float alpha = 1.0 - T;
	if (max(col.r, max(col.g, col.b)) < 1e-4 && alpha < 0.002) discard;
	// the temperature code also scales the colour (calibrated brightness)
	ALBEDO = col * uTempCode * 2.4;
	ALPHA = alpha;
}
