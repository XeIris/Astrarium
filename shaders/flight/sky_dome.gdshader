// ============================================================================
// THE SKY DOME — SKY_VERT / SKY_FRAG of sim/flight/localview.js.
// ----------------------------------------------------------------------------
// A plane-parallel atmosphere seen from inside a 3000 km sphere: column
// density along the line of sight with a 1/(cos + ε) air mass, saturating so
// the horizon goes pale instead of blowing out; Rayleigh phase plus a forward
// Mie lobe; sunrise reddening.
//
// DEPTH-TESTED, no depth write, BackSide, transparent (NormalBlending). A
// transparent object is drawn after every opaque one whatever its priority, so
// a dome drawn "behind everything" with the depth test off is drawn LAST, over
// the vehicle — the washed-out, see-through launch of the web build's history.
// Tested against the depth buffer, the ground and the vehicle occlude it.
//
// ALPHA IS COVERAGE, deliberately much steeper than the scattered radiance:
// stars are invisible in daylight not because the air is opaque but because
// the sky is four orders of magnitude brighter than they are, and with no
// adapted exposure in this pass the only way to say that is to cover them.
// In the local pass alpha is exactly that — coverage of the orrery behind —
// and compose.glsl blends it premultiplied, as the web build's NormalBlending
// drew the dome straight over the orrery's frame.
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_front;

uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uTint;
uniform vec3 uHaze;
uniform float uEye = 0.0;
uniform float uScaleH = 8500.0;
uniform float uHasAir = 1.0;
uniform float uThick = 1.05;
uniform float uCloudCoverage = 0.0;
uniform float uCloudVolume = 0.0;
uniform sampler3D uCloudNoise : filter_linear_mipmap, repeat_enable;

varying vec3 vDir;

float cloud_hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float cloud_noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(cloud_hash(i), cloud_hash(i + vec2(1.0, 0.0)), f.x),
		mix(cloud_hash(i + vec2(0.0, 1.0)), cloud_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}
float cloud_field(vec2 p) {
	float broad = cloud_noise(p * 0.72);
	float body = cloud_noise(p * 1.65 + vec2(8.4, 2.7));
	float edges = cloud_noise(p * 4.1 - vec2(4.3, 7.2));
	float wisps = cloud_noise(p * 9.2 + vec2(3.5, 9.1));
	return broad * 0.48 + body * 0.31 + edges * 0.15 + wisps * 0.06;
}

float volume_density(vec3 p) {
	vec3 uv = p * vec3(0.00017, 0.00035, 0.00017) + vec3(0.12, 0.38, 0.61);
	float body = texture(uCloudNoise, uv).r;
	float detail = texture(uCloudNoise, uv * 2.43 + vec3(0.37, 0.10, 0.23)).r;
	float billow = smoothstep(0.69 - uCloudCoverage * 0.10,
		0.79 - uCloudCoverage * 0.10, body * 0.78 + detail * 0.22);
	float base = smoothstep(850.0, 1150.0, p.y);
	float top = 1.0 - smoothstep(2250.0, 2800.0, p.y);
	return billow * base * top;
}

void vertex() {
	vDir = VERTEX;
}

void fragment() {
	if (uHasAir < 0.5) discard;
	vec3 d = normalize(vDir);
	float up = clamp(d.y, -1.0, 1.0);
	// Column density along the line of sight, from a plane-parallel atmosphere
	// with the Kasten–Young-ish 1/(cos+eps) air mass. Saturating rather than
	// linear, so the horizon goes pale instead of blowing out.
	float rho = exp(-uEye / uScaleH);
	float airmass = 1.0 / max(up + 0.09, 0.06);
	float tau = rho * uThick * airmass;
	float scatter = 1.0 - exp(-tau);

	float cosT = dot(d, uSunDir);
	// Rayleigh phase, and a forward Mie lobe for the glare around the sun.
	float ray = 0.75 * (1.0 + cosT * cosT);
	float mie = pow(max(cosT, 0.0), 220.0);

	float sun = clamp(uSunDir.y * 2.0 + 0.25, 0.0, 1.0);
	vec3 col = uTint * ray * scatter * sun;
	col = mix(col, uHaze * scatter * sun, clamp(scatter * 1.3 - 0.25, 0.0, 1.0));
	col += vec3(1.0, 0.82, 0.60) * mie * scatter * sun * 0.16;
	// At sunrise/sunset the path through the atmosphere reddens what is left.
	col *= mix(vec3(1.0, 0.45, 0.22), vec3(1.0), clamp(uSunDir.y * 3.0 + 0.35, 0.0, 1.0));

	// A finite cloud sheet, intersected by the view ray. The divisions make
	// clouds shrink toward the horizon instead of being painted on the dome.
	float cloud = 0.0;
	if (uCloudVolume > 0.5 && uCloudCoverage > 0.001 && up > 0.025 && uEye < 2800.0) {
		// High quality: integrate extinction through a 1.9 km deep 3D density
		// field. The finite layer gives clouds parallax, lit rims and darker
		// undersides; the older flat sheet remains for Medium.
		float near_t = max((850.0 - uEye) / up, 0.0);
		float far_t = min((2800.0 - uEye) / up, 60000.0);
		float ds = max((far_t - near_t) / 8.0, 0.0);
		float trans = 1.0;
		vec3 light_sum = vec3(0.0);
		for (int i = 0; i < 8; i++) {
			vec3 p = d * (near_t + (float(i) + 0.5) * ds);
			p.y += uEye;
			float density = volume_density(p);
			float shade = volume_density(p + uSunDir * 440.0);
			float extinction = 1.0 - exp(-density * ds * 0.0016);
			float lit = clamp(0.50 + uSunDir.y * 0.38 - shade * 0.22, 0.18, 1.0);
			vec3 cloud_col = mix(vec3(0.38, 0.43, 0.51), vec3(1.12, 1.09, 1.02), lit);
			light_sum += cloud_col * trans * extinction;
			trans *= 1.0 - extinction;
		}
		// The far, grazing view is unresolved at this step count. Atmospheric
		// haze hides cloud detail there in reality too; fade it before it aliases.
		float distance_fade = smoothstep(0.055, 0.20, up);
		cloud = (1.0 - trans) * distance_fade;
		col = mix(col, col * trans + light_sum * sun, distance_fade);
	} else if (uCloudVolume < 0.5 && uCloudCoverage > 0.001 && up > 0.005) {
		vec2 at = d.xz / (max(up, 0.0) * 0.75 + 0.45) * 3.8 + vec2(1.7, 4.2);
		float field = cloud_field(at);
		float threshold = 0.67 - uCloudCoverage * 0.18;
		cloud = smoothstep(threshold, threshold + 0.085, field);
		cloud *= smoothstep(0.02, 0.14, up) * clamp(rho * 1.5, 0.0, 1.0);
		float underside = cloud_field(at + uSunDir.xz * 0.45);
		float lighting = clamp(0.43 + uSunDir.y * 0.28 + (field - underside) * 2.0,
			0.0, 1.0);
		vec3 lit_cloud = mix(vec3(0.35, 0.40, 0.47), vec3(1.02, 1.02, 0.99), lighting);
		lit_cloud *= 0.77 + 0.45 * cloud_noise(at * 3.2 + vec2(1.8, 5.7));
		col = mix(col, lit_cloud * sun, cloud * 0.86);
	}

	// The previous Mie term made one large shiny patch. At Earth's distance
	// the sun is a 0.53-degree disc; retain a narrow glow around its edge.
	float sun_angle = acos(clamp(cosT, -1.0, 1.0));
	float pixel_angle = max(fwidth(sun_angle), 0.00035);
	float disc = 1.0 - smoothstep(0.00465 - pixel_angle, 0.00465 + pixel_angle, sun_angle);
	float air_at_sun = exp(-rho * uThick / max(uSunDir.y + 0.09, 0.06) * 0.16);
	col += vec3(1.0, 0.92, 0.78) * disc * 4.2 * sun * air_at_sun * (1.0 - cloud * 0.95);

	float a = max(clamp(scatter * 3.2, 0.0, 1.0), disc) * sun;
	// 0.85, not 1.5: the horizon term reaches uHaze·scatter ≈ (0.56, 0.71, 0.91)
	// on its own, and scaling that up put every channel past 1.0, where the tone
	// curve's shoulder flattens it to a featureless white band.
	ALBEDO = col * 0.85;
	ALPHA = a;
}
