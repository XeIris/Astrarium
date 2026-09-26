// ============================================================================
// ONE ENGINE'S PLUME — PLUME_VERT / PLUME_FRAG of sim/flight/plume.js.
// ----------------------------------------------------------------------------
// The derivation is in the JS header and repeated inline below: the SHAPE is a
// function of the ambient pressure alone (uExpand, 0 at sea level, 1 in
// vacuum), and the colour is the propellant's temperature falling along the
// jet. The geometry is a straight open tube at the nozzle's own exit radius,
// hung from the exit plane and running down −Y; all the shaping is here.
//
// BLENDING. The web material was publishAlpha(): RGB = src·srcα + dst, where
// srcα is the log-encoded TEMPERATURE this fragment publishes (≈ 0.32 for a
// 3400 K plume) — so the colour that reaches the frame is rgb × that code, and
// the code itself replaced the alpha channel. The local pass has no
// temperature channel (compose.glsl treats local coverage as "no data"), so
// here the product is formed in the shader and blended ONE, ONE —
// blend_premul_alpha with ALPHA = 0 (PORT_GUIDE §6) — which adds the colour
// and leaves the local pass's COVERAGE alone: an additive emitter covers
// nothing, and the orrery behind it must show through undimmed.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

uniform vec3 uCore;
uniform vec3 uEdge;
uniform float uThrottle = 0.0;
uniform float uExpand = 0.0;     // 0 = sea level (pinched), 1 = vacuum (bloomed)
uniform float uTime = 0.0;
uniform float uSoot = 0.85;
uniform float uGlow = 1.0;
uniform float uTemp = 3400.0;
uniform float uBeam = 0.0;
uniform float uDiamonds = 1.0;
uniform float uLen = 1.0;

varying vec2 vUv;
varying float vAxial;      // 0 at the nozzle, 1 at the tip
varying float vAng;        // azimuth round the jet, 0..1

void vertex() {
	vUv = UV;
	vAng = UV.x;
	vAxial = clamp(-VERTEX.y / max(uLen, 1e-4), 0.0, 1.0);
	vec3 p = VERTEX;
	float a = vAxial;
	// THE RADIUS PROFILE IS THE PRESSURE STORY, and it is two different shapes
	// rather than one scaled.
	//
	//   OVER-EXPANDED (sea level): the ambient squeezes the jet back down to a
	//   column barely wider than the throat, and it spreads only as the mixing
	//   layer eats into it — slowly, and roughly linearly. A Merlin at liftoff
	//   is a pencil, not a cone.
	//
	//   UNDER-EXPANDED (vacuum): nothing confines it, so it turns the corner at
	//   the lip and opens as a bell that is several exit diameters across within
	//   one diameter of the nozzle. The a^0.6 is that: nearly all the spread
	//   happens immediately and then it is ballistic.
	// Both profiles start at exactly 1.0 — the nozzle's own exit radius, which
	// the geometry is built at — and then neck or bloom over the first few
	// percent of the length. Starting anywhere else leaves a visible step where
	// the jet meets the bell it is supposed to be coming out of.
	float sea = mix(1.0, 0.52, smoothstep(0.0, 0.05, a)) + 0.95 * pow(a, 1.55);
	float vac = mix(1.0, 0.34, smoothstep(0.0, 0.03, a)) + 4.30 * pow(a, 0.60);
	float bloom = mix(sea, vac, uExpand);
	// A beam does not spread at all — it is collimated, which is the whole
	// difference between an ion engine and a flame.
	bloom = mix(bloom, 0.34 + 0.22 * a, uBeam);
	p.xz *= bloom;
	// A throttled engine has a shorter flame — less mass flow to burn, and the
	// afterburning mixing layer is what most of the length IS. A vacuum plume is
	// longer again because nothing is stopping it.
	p.y *= mix(1.0, 2.3, uExpand) * (0.55 + 0.45 * uThrottle);
	VERTEX = p;
}

float hash(vec3 p) { return fract(sin(dot(p, vec3(21.7, 91.3, 47.1))) * 43758.5453); }
float noise(vec3 p) {
	vec3 i = floor(p), f = fract(p); f = f * f * (3.0 - 2.0 * f);
	float n000 = hash(i), n100 = hash(i + vec3(1.0, 0.0, 0.0));
	float n010 = hash(i + vec3(0.0, 1.0, 0.0)), n110 = hash(i + vec3(1.0, 1.0, 0.0));
	float n001 = hash(i + vec3(0.0, 0.0, 1.0)), n101 = hash(i + vec3(1.0, 0.0, 1.0));
	float n011 = hash(i + vec3(0.0, 1.0, 1.0)), n111 = hash(i + vec3(1.0, 1.0, 1.0));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
float fbm(vec3 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 3; i++) { v += a * noise(p); p *= 2.07; a *= 0.5; }
	return v;
}

void fragment() {
	float a = vAxial;
	float radial = abs(vUv.x - 0.5) * 2.0;
	// Azimuth as a position on a circle, so the turbulence does not have a seam
	// where the cylinder's uv wraps.
	float th = vAng * 6.2831853;
	vec3 sp = vec3(cos(th) * 1.7, sin(th) * 1.7, 0.0);

	// ZONE 1 — THE SUPERSONIC CORE. The gas leaves the throat at Mach 3-plus
	// and stays supersonic for a few exit diameters before the mixing layer,
	// growing inward from the edge, closes on the axis. That length is SHORT and
	// it is where all the shock structure lives; it gets relatively shorter as
	// the jet blooms, because a bloomed jet has far more surface for the shear
	// layer to work on.
	float coreEnd = mix(0.34, 0.13, uExpand);
	float inCore = 1.0 - smoothstep(coreEnd * 0.55, coreEnd * 1.35, a);

	// SHOCK DIAMONDS: a standing train of oblique shocks, bright where the gas
	// is compressed and dark where it re-expands. The spacing grows downstream
	// and the whole train disappears with altitude on its own, because there
	// is no longer an ambient pressure to be wrong about.
	float sp0 = 0.055 + 0.16 * a;
	float diamonds = 0.5 + 0.5 * cos((a / sp0) * 6.2831853);
	diamonds = pow(max(diamonds, 0.0), 2.6);
	// The bright cells are narrow and the dark ones wide: weight to the axis.
	float shock = 1.0 + 2.4 * diamonds * (1.0 - radial * 0.65);

	// THE MACH DISK: a heavily over-expanded jet terminates its oblique train
	// in a NORMAL shock within a diameter or so of the exit — the hard white
	// knot at a sea-level nozzle that a vacuum engine does not have.
	float over = 1.0 - uExpand;
	float aM = 0.045 + 0.075 * over;
	// Squared by multiplication, not pow(): the base is negative upstream.
	float dM = (a - aM) / 0.028;
	float disk = exp(-dM * dM) * smoothstep(0.35, 0.85, over);
	disk *= 1.0 - smoothstep(0.35, 0.95, radial);

	float core = pow(max(1.0 - radial * 1.75, 0.0), 2.6) * inCore;

	// ZONE 2 — THE MIXING LAYER, which is most of what you can see: a
	// turbulent shear layer entraining air and, for anything carbon-bearing,
	// still BURNING. Brightest in an annulus, because that is where the shear is.
	float dS = (radial - 0.62) / 0.40;
	float shear = exp(-dS * dS);
	float mixLayer = smoothstep(coreEnd * 0.4, coreEnd * 1.8, a) * pow(1.0 - a, 0.9);

	// Turbulence advected downstream, regenerated rather than translated.
	float turb = fbm(sp + vec3(0.0, 0.0, a * 6.5 - uTime * 5.5));
	turb = mix(turb, fbm(sp * 2.3 + vec3(0.0, 0.0, a * 13.0 - uTime * 9.0)), 0.45);
	// A beam has no turbulence at all: it is collisionless.
	turb = mix(turb, 0.5, uBeam);

	float iCore = (core * 2.2 + disk * 3.4) * mix(1.0, shock, uDiamonds * over);
	// The mixing layer needs SOMETHING TO MIX WITH: in vacuum there is no
	// entrainment and no afterburning, so a vacuum plume is a smooth,
	// translucent, almost structureless cone — the observation, not a shortcut.
	float iMix = shear * mixLayer * (0.35 + 1.5 * turb) * (0.30 + 0.70 * uSoot)
	           * (0.18 + 0.82 * over);
	// The body glow behind both, so the jet is never see-through down the axis.
	float body = pow(1.0 - a, 1.25) * (1.0 - pow(radial, uBeam > 0.5 ? 6.0 : 2.2)) * 0.45;

	float i = (iCore + iMix + body) * uThrottle * uGlow;
	if (i <= 0.0006) discard;

	// COLOUR IS A TEMPERATURE, and the temperature falls along the jet. Soot is
	// what makes that visible: a hydrogen plume stays a thin violet.
	float cool = 1.0 - 0.72 * pow(a, 0.8) * uSoot;
	vec3 col = mix(uEdge, uCore, clamp(core * 1.5 + disk * 2.0 + (1.0 - a) * 0.30, 0.0, 1.0));
	col = mix(col, uEdge * vec3(1.00, 0.52, 0.24), (1.0 - cool));
	// The shock cells are hotter than the gas around them, so they are WHITER.
	col = mix(col, vec3(1.0), clamp((disk * 1.8 + diamonds * 0.45 * over * inCore) * uDiamonds, 0.0, 0.85));

	// HDR: emitters are expected to write well above 1.0
	vec3 rgb = col * i * 7.0;
	// The published temperature code, cooled along the jet — which in the web
	// build was also the SOURCE FACTOR of the colour blend.
	float T = uTemp * mix(1.0, cool, 0.85);
	float code = clamp(log(max(T, 2.0)) / 25.33, 0.006, 0.984);
	ALBEDO = rgb * code;
	ALPHA = 0.0;
}
