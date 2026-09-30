// THE SUN, SEEN FROM THE VEHICLE — sim/flight/localview.gd's sun sprite.
// The orrery draws the Sun as a body 1 AU away, which from inside local space
// is a disc a handful of pixels across at a brightness calibrated for looking
// at a solar system, not for standing in daylight. The sky dome drew a disc of
// its own, but only while there was air to draw it in: above the dome's top
// the sun simply vanished from the sky of an ascending rocket, which is the
// one place it is most dramatic.
//
// So the sun is drawn here, in the pass the vehicle is in, as three things:
//
//   THE DISC at its true angular radius (0.267° from Earth — passed in, so it
//   is 0.4° from Venus and a point from Neptune), limb-darkened with the
//   Eddington law I(μ) = I₀(0.4 + 0.6μ). Its radiance is the sun's own: a
//   white surface in full sun is E/π, the disc is E/Ω, and the ratio of the
//   two is π/Ω ≈ 46 000. That is well past anything a display can show and
//   the tone curve takes care of it; what matters is that it is FAR brighter
//   than anything it lights, or it reads as a white sticker.
//
//   THE AUREOLE — forward scattering by aerosols, the bright halo a few
//   degrees round the sun that is most of what "looking toward the sun" is in
//   the lower atmosphere. It scales with the air column along the sun line,
//   so it thins away with altitude and is gone in vacuum.
//
//   THE VEILING GLARE of the camera — scatter in the optics, a 1/θ² wing, and
//   the STARBURST. This is what hides the stars near the sun even in vacuum:
//   the sky beside the sun is not bright, the LENS is. The starburst is
//   diffraction off the aperture's straight edges: an iris of n blades throws
//   one streak perpendicular to each edge, 2n of them for an odd n (a 7-blade
//   iris makes 14), each a line a pixel or two wide whose length goes with how
//   far the sun overexposes the frame. Between them, dozens of fainter hair-
//   thin rays of random length — scatter from the blade edges' roughness and
//   dust on the front element — which is the texture every photograph of the
//   sun from orbit has and six clean spikes do not. The streaks are widths in
//   PIXELS and lengths in ANGLE: the lens draws a sharp line whatever the
//   field of view, and its length is the optics' response to the sun's flux.
//   The ghosts the same lens throws across the frame are lens_flare.gdshader.
//
// EXTINCTION is per channel: Rayleigh τ ∝ λ⁻⁴ plus a grey aerosol term, along
// the real air mass for the sun's elevation, scaled by the density at the
// observer's altitude. That is the whole of sunset reddening, and it switches
// off by itself on the way up.
//
// OCCLUSION, three ways:
//   · by anything in the local pass (the vehicle, the tower, the ground patch)
//     — this is depth-test-DISABLED, and reads the depth buffer itself: the
//     disc is hidden per pixel where geometry is nearer than the sun, and the
//     glare by the fraction of the disc that is uncovered, sampled at its
//     centre and on a ring round it. A glare that ignored occlusion would
//     shine through the rocket;
//   · by the planet beyond the ground patch — uVisible, the fraction of the
//     disc above the horizon at the observer's altitude, from the script;
//   · by clouds — the cloud field's transmittance toward the sun's centre,
//     marched here from the same field the cloud pass draws.
//
// BLENDING: additive (premultiplied with ALPHA = 0), like every emitter in
// this pass: it adds light and covers nothing.
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled;

#include "res://shaders/flight/clouds.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform float uAngR = 0.00465;          // angular radius, rad
uniform float uExtent = 0.75;           // the quad's half-size, as tan(angle)
uniform vec3 uColor = vec3(1.0);        // the star's colour, luminance 1
uniform float uRadiance = 1500.0;       // disc centre, HDR
uniform vec3 uTau = vec3(0.0);          // zenith optical depth at the observer, per channel
uniform float uAirMass = 1.0;           // relative air column along the sun line
uniform float uAureole = 0.0;           // aerosol column along the sun line, 0 in vacuum
uniform float uVisible = 1.0;           // fraction of the disc above the horizon
uniform vec3 uCamLocal = vec3(0.0);     // the camera in the local frame, for the clouds
uniform vec3 uSunLocal = vec3(0.0, 1.0, 0.0);
uniform float uGlare = 1.0;             // lens glare strength
uniform float uDist = 3.0e6;            // where the quad is, m
uniform int uBlades = 7;                // the iris: 2n streaks for an odd n
uniform float uIrisRot = 0.31;          // its orientation in the frame, rad

varying vec3 vCentre;                   // view-space centre of the quad
varying vec3 vView;                     // view-space position of this fragment
varying float vCloudT;                  // cloud transmittance toward the sun

void vertex() {
	vec4 c = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	vCentre = c.xyz;
	float s = length(c.xyz) * uExtent;
	vec4 p = c + vec4(VERTEX.xy * 2.0 * s, 0.0, 0.0);
	vView = p.xyz;
	POSITION = PROJECTION_MATRIX * p;
	// CLOUDS toward the sun's centre: the layer's optical depth along the sun
	// line, marched once — the same for every fragment of the sprite, because
	// the glare is the lens's response to whatever of the sun gets through.
	// So it is marched per VERTEX (four times) rather than per pixel of a
	// quad that can cover the screen.
	vCloudT = 1.0;
	if (uCloudCoverage > 0.0) {
		vec3 ro = uCamLocal;
		float h = length(vec3(ro.x, ro.y + uPlanetR, ro.z)) - uPlanetR;
		vec2 tb = cloud_sphere(ro, uSunLocal, uCloudBase);
		vec2 tt = cloud_sphere(ro, uSunLocal, uCloudTop);
		float a0 = h < uCloudBase ? max(tb.y, 0.0) : 0.0;
		float a1 = h > uCloudTop ? -1.0 : (h < uCloudBase ? tt.y : (tb.x > 0.0 ? tb.x : tt.y));
		if (a1 > a0) {
			float ds = (a1 - a0) / 10.0;
			float od = 0.0;
			for (int i = 0; i < 10; i++)
				od += cloud_density(ro + uSunLocal * (a0 + (float(i) + 0.5) * ds), false) * ds;
			vCloudT = exp(-od);
		}
	}
}

float h1(float n) { return fract(sin(n * 127.1) * 43758.5453); }
// value noise round the circle, periodic in `cells`
float ring_noise(float a, float cells, float seed) {
	float x = a / 6.2831853 * cells;
	float i = floor(x), f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(h1(mod(i, cells) + seed), h1(mod(i + 1.0, cells) + seed), f);
}

float scene_dist(vec2 uv, mat4 inv_proj) {
	float d = texture(uDepth, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return length(v.xyz / v.w);
}

void fragment() {
	if (uVisible <= 0.0) discard;
	vec3 sd = normalize(vCentre);
	vec3 vd = normalize(vView);
	// 2·asin(|a − b|/2), not acos(a·b): acos is flat at 1, and a quarter-degree
	// disc lives entirely in the part of it float32 cannot resolve.
	float th = 2.0 * asin(clamp(length(vd - sd) * 0.5, 0.0, 1.0));

	// the atmosphere's colour filter on the direct beam
	vec3 T = exp(-uTau * uAirMass);

	// ---- the disc, limb-darkened, antialiased on its own edge. Never drawn
	// smaller than a pixel and a bit: a distant sun is a POINT, and a point
	// has to keep its flux — so what is drawn larger is drawn dimmer by the
	// ratio of the areas, and seen from Neptune it is a hard, bright star.
	// abs(): Godot's projection carries a flipped y, and a negative pixel
	// turned every smoothstep here inside out
	float px = 2.0 / abs(PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);
	float r_draw = max(uAngR, 1.2 * px);
	float edge = 1.0 - smoothstep(r_draw - px * 0.7, r_draw + px * 0.7, th);
	float mu = sqrt(max(1.0 - (th * th) / (r_draw * r_draw), 0.0));
	float disc = edge * (0.4 + 0.6 * mu) * (uAngR * uAngR) / (r_draw * r_draw);
	// hidden, per pixel, by anything nearer than the sun
	float here = scene_dist(SCREEN_UV, INV_PROJECTION_MATRIX);
	float open_here = here > uDist * 0.9 ? 1.0 : 0.0;

	// ---- how much of the sun is uncovered, for the glare: its centre and a
	// ring at the disc's edge, in screen space
	vec4 cc = PROJECTION_MATRIX * vec4(vCentre, 1.0);
	vec2 cuv = cc.xy / cc.w * 0.5 + 0.5;
	vec4 ce = PROJECTION_MATRIX * vec4(vCentre + normalize(cross(sd, vec3(0.0, 1.0, 0.0))) * length(vCentre) * uAngR, 1.0);
	float rpx = length((ce.xy / ce.w * 0.5 + 0.5) - cuv);
	float open_sun = 0.0;
	for (int i = 0; i < 7; i++) {
		vec2 o = i == 0 ? vec2(0.0) : vec2(cos(float(i) * 1.047), sin(float(i) * 1.047)) * rpx * 0.8;
		vec2 uv = cuv + o;
		bool on = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
		// off screen: assume open, as a real lens would still see it
		open_sun += (!on || scene_dist(uv, INV_PROJECTION_MATRIX) > uDist * 0.9) ? 1.0 : 0.0;
	}
	open_sun /= 7.0;

	// ---- aureole: aerosol forward scattering, ~θ^-1.5 out to tens of degrees
	float x = th / uAngR;
	float aureole = uAureole * 0.012 * pow(max(x, 1.0), -1.6);
	// ---- veiling glare of the optics: a 1/θ² wing and a broad soft floor
	// (the floor is written per unit of the Sun-from-Earth's solid angle, so a
	// smaller sun throws proportionally less of it: glare goes with FLUX)
	float flux = (uAngR * uAngR) / (0.00465 * 0.00465);
	float glare = uGlare * (0.0012 / max(x * x, 1.0) + 0.00005 * exp(-th / 0.05) * flux);
	// ---- the starburst, in the FRAME's axes: the iris does not turn with
	// the sun, so the streaks keep their angle as the sun crosses the screen.
	// (the camera's x axis laid into the plane round the sun: no divide, so
	// nothing blows up for a sun near the edge of the view)
	vec3 fx = vec3(1.0, 0.0, 0.0) - sd * sd.x;
	fx = dot(fx, fx) > 1e-6 ? normalize(fx) : normalize(cross(sd, vec3(0.0, 1.0, 0.0)));
	vec3 fy = cross(sd, fx);
	float ang = atan(dot(vd, fy), dot(vd, fx) + 1e-12);
	float rpx_here = th / px;                                   // pixels from the centre
	float xs = max(x, 1.0) / sqrt(max(flux, 1e-4));             // a fainter star streaks shorter
	float star = 0.0;
	for (int k = 0; k < 16; k++) {
		if (k >= uBlades) break;
		float phi = uIrisRot + float(k) * 3.14159265 / float(uBlades);
		float perp = rpx_here * abs(sin(ang - phi));            // px off this streak's line
		float w = mix(1.25, 0.6, smoothstep(0.0, 380.0, rpx_here));   // tapering to a hairline
		// each of its two arms has its own length and weight, as a real
		// burst's do (the blades are never quite identical)
		float side = cos(ang - phi) >= 0.0 ? 0.0 : 1.0;
		float seed = float(k) * 2.0 + side + 3.0;
		float L = mix(35.0, 125.0, h1(seed));
		float A = mix(0.45, 1.0, h1(seed + 17.0));
		star += A * exp(-0.5 * perp * perp / (w * w)) * pow(xs, -1.25) * exp(-xs / L);
	}
	// the hair: many faint, thin rays of random length between the streaks
	float n1 = ring_noise(ang, 211.0, 11.0);
	float n2 = ring_noise(ang, 127.0, 29.0);
	float Lh = mix(6.0, 80.0, pow(ring_noise(ang, 67.0, 47.0), 1.5));
	float hair = (pow(n1, 22.0) + 0.7 * pow(n2, 16.0)) * pow(xs, -1.3) * exp(-xs / Lh);
	glare += uGlare * flux * (0.008 * star + 0.022 * hair) * smoothstep(1.0, 2.5, x);

	// Everything off the disc fades out well inside the quad, so its edge is
	// never seen however bright the sun is.
	float ext = atan(uExtent);
	float window = 1.0 - smoothstep(0.45 * ext, 0.92 * ext, th);
	float sky_part = (aureole + glare) * open_sun * window;

	float cloudT = vCloudT;
	vec3 rgb = uColor * T * uRadiance * uVisible * cloudT * (disc * open_here + sky_part);
	// A cloud in front scatters the sun it hides into a bright patch rather
	// than blotting it out; that light is the cloud's own (the cloud pass
	// draws it), so only the DIRECT terms are cut here.
	// written as a positive test so a NaN (which fails every comparison) is
	// discarded too, not composited as black
	if (!(max(rgb.r, max(rgb.g, rgb.b)) >= 1e-4)) discard;
	ALBEDO = rgb;
	ALPHA = 0.0;
}
