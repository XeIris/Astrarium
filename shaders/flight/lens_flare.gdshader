// ============================================================================
// LENS GHOSTS — the other half of what a camera does with the sun in frame.
// ----------------------------------------------------------------------------
// sun_disc.gdshader draws what the lens does AT the sun: the core, the veiling
// glare, the starburst. This draws what it does everywhere else. Every air–
// glass surface in a lens reflects a fraction of a percent, and a pair of
// such reflections sends a defocused image of the aperture back onto the
// sensor — a GHOST. Because every element is centred on the optical axis, the
// ghosts all lie on the line from the sun through the centre of the frame,
// on both sides of it, at fixed fractions of the sun's offset; each is the
// shape of the iris (here seven blades, a heptagon) and tinted by the coating
// it bounced off (green and magenta for modern multi-coats, amber for old
// single-layer ones). Move the sun and they slide along that line; put the
// sun at the centre and they collapse onto it. Photographs of the sun from
// orbit are full of them, and a sun without them reads as painted on.
//
// Their brightness goes with the light that ENTERS the lens: the sun's
// radiance after the atmosphere and the clouds (the script passes that as one
// colour), times how much of the disc is uncovered in this frame — read from
// the depth buffer at the sun's own screen position, so a tower or the
// vehicle in front of the sun puts its ghosts out with it. And they fade as
// the sun leaves the frame: off the sensor there is still glare, but the
// bright ghosts come from the image of the sun itself.
//
// Full-screen, additive (premultiplied with ALPHA = 0). Drawn last in the
// pass: a ghost is in the lens, in front of everything.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, skip_vertex_transform;

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 uSunLocal = vec3(0.0, 1.0, 0.0);   // direction to the sun, local frame
uniform vec3 uSunRGB = vec3(0.0);               // radiance entering the lens, HDR (0 = off)
uniform float uDist = 3.0e6;                    // the sun sprite's distance, m
uniform float uStrength = 1.0;

void vertex() {
	POSITION = vec4(VERTEX.xy * 2.0, 0.0, 1.0);
}

float scene_dist(vec2 uv, mat4 inv_proj) {
	float d = texture(uDepth, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return length(v.xyz / v.w);
}

// a regular n-gon of circumradius 1: < 1 inside
float ngon(vec2 p, float n, float rot) {
	float a = atan(p.y, p.x) + rot;
	float seg = 6.2831853 / n;
	return length(p) * cos(mod(a, seg) - 0.5 * seg) / cos(0.5 * seg);
}

void fragment() {
	if (max(uSunRGB.r, max(uSunRGB.g, uSunRGB.b)) <= 0.0) discard;
	vec3 sv = mat3(VIEW_MATRIX) * uSunLocal;
	if (sv.z > -0.05) discard;                      // behind the camera
	vec4 cp = PROJECTION_MATRIX * vec4(sv * 1000.0, 1.0);
	vec2 suv = cp.xy / cp.w * 0.5 + 0.5;
	// off the frame, the ghosts go
	vec2 off = abs(suv - 0.5);
	float on_frame = 1.0 - smoothstep(0.48, 0.62, max(off.x, off.y));
	if (on_frame <= 0.0) discard;
	// how much of the sun this frame can see
	float open = 0.0;
	for (int i = 0; i < 5; i++) {
		vec2 o = i == 0 ? vec2(0.0) : vec2(cos(float(i) * 1.5708), sin(float(i) * 1.5708)) * 0.002;
		vec2 uv = suv + o;
		bool in_view = all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
		open += (!in_view || scene_dist(uv, INV_PROJECTION_MATRIX) > uDist * 0.9) ? 1.0 : 0.0;
	}
	open /= 5.0;
	if (open <= 0.0) discard;

	float aspect = VIEWPORT_SIZE.x / VIEWPORT_SIZE.y;
	vec2 q = (SCREEN_UV - 0.5) * vec2(aspect, 1.0);
	vec2 s = (suv - 0.5) * vec2(aspect, 1.0);
	// (position along the axis as a multiple of the sun's offset, radius as a
	// fraction of the frame height, tint, strength)
	const int N = 7;
	float K[N] = float[](-0.28, -0.52, -0.78, -1.12, -1.55, 0.36, 0.62);
	float Rr[N] = float[](0.018, 0.045, 0.030, 0.10, 0.055, 0.012, 0.024);
	vec3 C[N] = vec3[](vec3(0.45, 1.0, 0.55), vec3(0.95, 0.45, 1.0), vec3(1.0, 0.75, 0.35),
		vec3(0.35, 0.55, 1.0), vec3(0.55, 1.0, 0.8), vec3(1.0, 0.6, 0.3), vec3(0.6, 0.7, 1.0));
	float S[N] = float[](1.0, 0.55, 0.8, 0.22, 0.35, 1.3, 0.6);
	vec3 col = vec3(0.0);
	for (int i = 0; i < N; i++) {
		vec2 g = s * K[i];
		float r = Rr[i] * (1.0 + 0.35 * length(s));   // ghosts grow off-axis
		float d = ngon((q - g) / r, 7.0, 0.31);
		// a soft-edged disc with a slightly brighter rim, as a defocused
		// aperture image is
		float body = 1.0 - smoothstep(0.82, 1.0, d);
		float rim = smoothstep(0.7, 0.95, d) * body;
		col += C[i] * S[i] * (0.55 * body + 0.6 * rim) / (1.0 + 60.0 * r * r);
	}
	// a faint halo round the frame centre, the size of the sun's offset: the
	// reflection off the sensor cover glass
	float halo = exp(-pow((length(q) - length(s) * 0.9) / 0.012, 2.0)) * 0.12;
	col += vec3(0.6, 0.8, 1.0) * halo * smoothstep(0.05, 0.25, length(s));
	vec3 rgb = col * uSunRGB * 4.0e-5 * uStrength * open * on_frame;
	if (!(max(rgb.r, max(rgb.g, rgb.b)) >= 1e-4)) discard;
	ALBEDO = rgb;
	ALPHA = 0.0;
}
