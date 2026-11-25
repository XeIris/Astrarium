// A WHEEL'S TRACK, multiplied into the ground under it (RoverTracks), so the rut keeps the ground's own colour.
// It is relit as relief: a height field (a trough as deep as Bekker's sinkage, berms of the soil it pushed out
// either side, the grousers' imprints along it) seen with parallax, and shaded by the ratio of its slope's light
// to the flat ground's, with the rut's walls shadowing its floor when the Sun is low. Filtered by fwidth, so the
// imprints fade rather than shimmer far off. UV: x across the strip (the tread from TREAD0 to TREAD1), y the
// path's length, m; UV2 the path's heading (x, z) in the site frame; COLOR.r the sinkage over 5 cm.
shader_type spatial;
render_mode blend_mul, unshaded, cull_disabled, depth_draw_never, fog_disabled;

// The Sun, toward it, in the site's frame (x west, y up, z north).
uniform vec3 uSun = vec3(0.3, 0.8, 0.2);
// The strip's width, m; the grousers' pitch along the path, m, their imprint, m, and their sweep across it
// (a chevron's 1.6 for the LRV's; Perseverance's are gently curved).
// A dust storm's fog over the ground, 1/m: it hides the strip's shading with the ground under it.
uniform float uFog = 0.0;
uniform float uWidth = 0.34;
uniform float uPitch = 0.107;
uniform float uGrouser = 0.004;
uniform float uSweep = 1.6;
uniform float uCurved = 0.0;

const float TREAD0 = 0.13;
const float TREAD1 = 0.87;

varying float vDepth;
varying vec2 vHeading;

void vertex() {
	vDepth = clamp(COLOR.r, 0.0, 1.0) * 0.05;
	vHeading = UV2;
}

// Height of the disturbed soil over the undisturbed ground, m, at (u across in [0,1], v along in m).
float height(vec2 uv, float depth, float detail) {
	float t = (uv.x - TREAD0) / (TREAD1 - TREAD0);
	// The floor, rounding up into the walls over the tread's outer eighth.
	float floor_k = smoothstep(0.0, 0.14, t) * smoothstep(1.0, 0.86, t);
	// The berm: the displaced soil heaped just outside the walls, a third as high as the rut is deep.
	float berm = exp(-pow((t + 0.06) / 0.07, 2.0)) + exp(-pow((t - 1.06) / 0.07, 2.0));
	float s = abs(t - 0.5) * 2.0;
	float sweep = mix(s * uSweep, s * s * uSweep, uCurved);
	float g = 0.5 + 0.5 * cos(6.2831853 * (uv.y / uPitch + sweep));
	g = smoothstep(0.55, 0.95, g) * detail * step(0.0, t) * step(t, 1.0);
	return -depth * floor_k - uGrouser * g * floor_k + depth * 0.35 * berm;
}

void fragment() {
	float depth = max(vDepth, 0.006);
	float wv = fwidth(UV.y / uPitch);
	float detail = 1.0 - smoothstep(0.35, 1.0, wv);
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 along = normalize(vec3(vHeading.x, 0.0, vHeading.y) + vec3(1e-5, 0.0, 0.0));
	vec3 across = normalize(cross(along, up));
	// The eye in the strip's frame: (across, along, up). MODEL_MATRIX is the site's rotation.
	vec3 view_w = (INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz;
	vec3 view_l = transpose(mat3(MODEL_MATRIX)) * view_w;
	vec3 vt = vec3(dot(view_l, across), dot(view_l, along), dot(view_l, up));
	// Parallax: march down into the field along the eye ray, in metres, then back to (u, v).
	vec2 uv = UV;
	if (detail > 0.01 && vt.z > 0.05) {
		vec2 step_m = -vt.xy / vt.z * (depth + uGrouser) / 12.0;
		float layer = 0.0;
		float dl = (depth + uGrouser) / 12.0;
		vec2 p = vec2(UV.x * uWidth, UV.y);
		for (int i = 0; i < 12; i++) {
			float hh = height(vec2(p.x / uWidth, p.y), depth, detail);
			if (-layer <= hh) break;
			p += step_m;
			layer += dl;
		}
		uv = vec2(p.x / uWidth, p.y);
	}
	// The slope's normal from the field, in metres.
	float e = 0.004;
	float hc = height(uv, depth, detail);
	float hx = height(uv + vec2(e / uWidth, 0.0), depth, detail);
	float hy = height(uv + vec2(0.0, e), depth, detail);
	vec3 n = normalize(vec3(-(hx - hc) / e, -(hy - hc) / e, 1.0));
	vec3 st = normalize(vec3(dot(uSun, across), dot(uSun, along), dot(uSun, up)));
	float flat_l = max(st.z, 0.08);
	float k = max(dot(n, st), 0.0) / flat_l;
	// The walls' shadow on the floor: a short march toward the Sun through the field.
	if (st.z < 0.9) {
		vec2 dir = st.xy / max(length(st.xy), 1e-4);
		float rise = st.z / max(length(st.xy), 1e-4);
		for (int i = 1; i <= 8; i++) {
			float d = float(i) * 0.012;
			vec2 q = uv + vec2(dir.x * d / uWidth, dir.y * d);
			if (height(q, depth, detail) > hc + rise * d) { k *= 0.35; break; }
		}
	}
	// What the sky lights: a rut's floor sees less of it.
	float ao = 1.0 - clamp(-hc / 0.05, 0.0, 1.0) * 0.25;
	// With the Sun down the sky is all that lights it, and the slopes no longer show.
	float direct = smoothstep(0.0, 0.1, st.z);
	k = clamp(mix(1.0, k, 0.85 * direct) * ao, 0.2, 1.6);
	k = mix(1.0, k, exp(-uFog * length(VERTEX)));
	// The strip's own edge blends into the ground outside it.
	float edge = smoothstep(0.0, 0.05, UV.x) * smoothstep(1.0, 0.95, UV.x);
	ALBEDO = vec3(mix(1.0, k, edge));
}
