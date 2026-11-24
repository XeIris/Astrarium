// A SEA from OceanGPU's four FFT cascades, in the flight pass. The two long cascades are fetched texel by texel
// and blended as OceanField.displacement blends them, so what floats on it stands on what is drawn. Hand-lit,
// as the site's ground's haze is: the sky it reflects, the sun's glint on slopes the cascades draw and the
// roughness of those they do not, and the light that comes back out of the liquid. docs/physics/ocean.md#drawing-it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_always;

uniform sampler2D uDisp0 : filter_nearest, repeat_enable;
uniform sampler2D uDisp1 : filter_nearest, repeat_enable;
uniform sampler2D uDisp2 : filter_nearest, repeat_enable;
uniform sampler2D uDisp3 : filter_nearest, repeat_enable;
uniform sampler2D uDeriv0 : filter_linear, repeat_enable;
uniform sampler2D uDeriv1 : filter_linear, repeat_enable;
uniform sampler2D uDeriv2 : filter_linear, repeat_enable;
uniform sampler2D uDeriv3 : filter_linear, repeat_enable;
uniform vec4 uTile = vec4(500.0, 100.0, 20.0, 2.5);   // L per cascade, m
uniform vec4 uCells = vec4(64.0, 64.0, 128.0, 128.0); // N per cascade
uniform vec4 uSlopeVar = vec4(0.0);                   // mean-square slope each cascade draws
uniform float uUnresolved = 0.0;                      // and what none of them draws
// Where the long waves' surface is squeezed this far towards folding, its crests break: an estimate.
uniform float uFoamJ = 0.55;
uniform sampler2D uScreen : hint_screen_texture, filter_linear_mipmap, repeat_disable;
uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;

uniform vec3 uCamLocal = vec3(0.0);
uniform vec3 uSunDir = vec3(0.0, 1.0, 0.0);
uniform vec3 uSunRGB = vec3(1.0);
uniform vec3 uSkyTop = vec3(0.1, 0.2, 0.4);
uniform vec3 uHaze = vec3(0.5, 0.6, 0.7);
uniform float uDensity = 2.6e-5;
uniform float uScaleH = 8500.0;
uniform float uCover = 0.0;
uniform float uTide = 0.0;
uniform float uFrozen = 0.0;
// The liquid: normal-incidence reflectance, absorption and backscatter (1/m, at 650, 550, 450 nm), and the
// reflectance of a deep column of it.
uniform float uF0 = 0.0209;
uniform float uIor = 1.339;
uniform vec3 uAbsorb = vec3(0.34, 0.0565, 0.0092);
uniform vec3 uBackscatter = vec3(0.00044, 0.00093, 0.00245);
uniform vec3 uDeepR = vec3(0.0004, 0.0054, 0.088);
uniform sampler2D uHeights : filter_linear, repeat_disable;
uniform float uHeightsHalf = 60000.0;
uniform float uRadius = 6.371e6;
uniform float uOpen = 1.0;
// Where the planet's patch stands under the site, m: a hit at it is a stand-in floor, not the sea bed.
uniform float uPatchY = -30.0;

varying vec3 vPlace;
varying float vRange;

// OceanField.displacement's bilinear blend, texel centres on the lattice points.
vec4 fetch(sampler2D t, vec2 p, float L, float n) {
	vec2 u = p / (L / n);
	vec2 i0 = floor(u);
	vec2 f = u - i0;
	ivec2 a = ivec2(mod(i0, n));
	ivec2 b = ivec2(mod(i0 + 1.0, n));
	return texelFetch(t, a, 0) * (1.0 - f.x) * (1.0 - f.y) + texelFetch(t, ivec2(b.x, a.y), 0) * f.x * (1.0 - f.y)
		+ texelFetch(t, ivec2(a.x, b.y), 0) * (1.0 - f.x) * f.y + texelFetch(t, b, 0) * f.x * f.y;
}

// How much of a cascade a sample this far apart can carry: its shortest waves are four texels long.
float carried(float L, float n, float spacing) {
	return 1.0 - smoothstep(0.5, 1.0, spacing / (4.0 * L / n));
}

void vertex() {
	vec2 at = VERTEX.xz + uCamLocal.xz;
	float dist = length(VERTEX.xz);
	// The mesh's rings grow with range; the spacing at this one, roughly.
	float spacing = max(dist * 0.055, 0.05);
	vec3 shift = vec3(0.0);
	if (uFrozen < 0.5) {
		shift += fetch(uDisp0, at, uTile.x, uCells.x).xyz;
		shift += fetch(uDisp1, at, uTile.y, uCells.y).xyz;
		shift += fetch(uDisp2, at, uTile.z, uCells.z).xyz * carried(uTile.z, uCells.z, spacing);
		shift += fetch(uDisp3, at, uTile.w, uCells.w).xyz * carried(uTile.w, uCells.w, spacing);
	}
	VERTEX += shift;
	// The ball's curve, as SiteScene.terrain_mesh drops the ground.
	VERTEX.y -= dot(at, at) / (2.0 * uRadius);
	vPlace = vec3(at.x, VERTEX.y, at.y);
	vRange = dist;
}

// Beckmann's slope distribution at a half vector c = cos θh from the drawn normal, for a mean-square slope s2
// (both axes together).
float beckmann(float c, float s2) {
	c = max(c, 1e-3);
	float t2 = (1.0 - c * c) / (c * c);
	float a2 = max(s2 * 0.5, 1e-5);
	return exp(-t2 / (2.0 * a2)) / (6.2831853 * a2 * c * c * c * c);
}

void fragment() {
	// In the site's own axes: in flight the site is turned to the local frame.
	mat3 to_site = transpose(mat3(MODEL_MATRIX));
	vec3 viewDir = normalize(to_site * (INV_VIEW_MATRIX * vec4(-VERTEX, 0.0)).xyz);
	vec2 at = vPlace.xz;
	float dist = length((INV_VIEW_MATRIX * vec4(VERTEX, 0.0)).xyz);
	// A pixel's footprint on the water, m; grazing views stretch it.
	float foot = dist * 0.0014 / max(viewDir.y, 0.04);
	vec4 d0 = texture(uDeriv0, at / uTile.x);
	vec4 d1 = texture(uDeriv1, at / uTile.y);
	vec4 d2 = texture(uDeriv2, at / uTile.z);
	vec4 d3 = texture(uDeriv3, at / uTile.w);
	vec4 w = vec4(carried(uTile.x, uCells.x, foot), carried(uTile.y, uCells.y, foot),
		carried(uTile.z, uCells.z, foot), carried(uTile.w, uCells.w, foot));
	if (uFrozen > 0.5) w = vec4(0.0);
	vec4 der = d0 * w.x + d1 * w.y + d2 * w.z + d3 * w.w;
	// A wave too short for the pixel is not gone: its slopes become the surface's roughness (Bruneton et al. 2010).
	float s2 = uUnresolved + dot(uSlopeVar, vec4(1.0) - w);
	vec3 N = normalize(vec3(-der.x / max(1.0 + der.z, 0.2), 1.0, -der.y / max(1.0 + der.w, 0.2)));
	float cosv = max(dot(N, viewDir), 1e-3);
	float fres = uF0 + (1.0 - uF0) * pow(1.0 - cosv, 5.0);
	vec3 R = reflect(-viewDir, N);
	float up = max(R.y, 0.0);
	float day = clamp(uSunDir.y * 2.0 + 0.25, 0.02, 1.0);
	vec3 sky = mix(uHaze * 1.4, uSkyTop * 2.2, pow(up, 0.5)) * day;
	sky = mix(sky, vec3(0.75) * day, uCover * 0.75);
	// The sun's glint: the slopes that face it, over the rough surface's spread of them. Irradiance in the
	// site's units, where a white ground under a high sun reads about 3 = E/π.
	vec3 H = normalize(viewDir + uSunDir);
	float sun_up = max(uSunDir.y, 0.0);
	float fs = uF0 + (1.0 - uF0) * pow(1.0 - max(dot(H, viewDir), 0.0), 5.0);
	float glint = fs * beckmann(dot(H, N), s2) / (4.0 * cosv);
	vec3 sun_e = uSunRGB * 3.0 * 3.14159 * step(0.0, uSunDir.y) * (1.0 - uCover);
	// The light in the liquid: what comes back out of a deep column (R∞), and the floor where it is near.
	vec3 down_e = vec3(3.0) * clamp(uSunDir.y * 1.6 + 0.1, 0.02, 1.0) * (1.0 - 0.5 * uCover);
	vec3 deep = uDeepR * down_e;
	vec2 uv = vec2(-at.x, at.y) / (2.0 * uHeightsHalf) + 0.5;
	float bed = texture(uHeights, uv).r;
	float column = max(uTide - bed, 0.0);
	vec3 T_dir = refract(-viewDir, N, 1.0 / uIor);
	float path = column / max(-T_dir.y, 0.05);
	// What the depth buffer shows behind the surface: the sea bed where the site's ground is drawn, or a
	// hull; the planet's patch below the sea only stands in for one.
	float zd = texture(uDepth, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, zd, 1.0);
	vp.xyz /= vp.w;
	float behind = max(length(vp.xyz) - dist, 0.0);
	// How far below this surface the hit lies; at the patch's level or under it, it is the stand-in.
	// The light that lit what is behind came down through the liquid to it as well.
	float lit_depth = 0.0;
	if (behind * viewDir.y < vPlace.y - uPatchY - 0.5) {
		path = min(path, behind);
		lit_depth = behind * viewDir.y;
	}
	vec3 k_ext = uAbsorb + uBackscatter;
	vec3 tr = exp(-k_ext * path);
	vec2 bend = N.xz * clamp(path, 0.0, 3.0) * 0.02 / max(dist * 0.02, 1.0);
	vec3 seen = texture(uScreen, SCREEN_UV + bend).rgb * exp(-k_ext * lit_depth);
	vec3 under = seen * tr + deep * (vec3(1.0) - tr);
	vec3 col = under * (1.0 - fres) + sky * fres + sun_e * glint;
	// Foam on the crests: where the three longer cascades together squeeze the surface towards folding,
	// J = (1 + ∂Dx/∂x)(1 + ∂Dz/∂z) − (∂Dx/∂z)².
	float foam = 0.0;
	if (uFrozen < 0.5) {
		float jxz = fetch(uDisp0, at, uTile.x, uCells.x).w * w.x + fetch(uDisp1, at, uTile.y, uCells.y).w * w.y
			+ fetch(uDisp2, at, uTile.z, uCells.z).w * w.z;
		vec2 jl = d0.zw * w.x + d1.zw * w.y + d2.zw * w.z;
		float jac = (1.0 + jl.x) * (1.0 + jl.y) - jxz * jxz;
		foam = smoothstep(uFoamJ + 0.12, uFoamJ - 0.08, jac);
	}
	float shore = smoothstep(1.5, 0.0, column) * 0.35;
	// Fresh foam reflects about half the light (Whitlock et al. 1982).
	col = mix(col, vec3(0.5) * down_e, clamp(foam + shore, 0.0, 0.9));
	bool inside = abs(uv.x - 0.5) < 0.5 && abs(uv.y - 0.5) < 0.5;
	if (bed > uTide + 0.5 && inside) discard;
	if (!inside && uOpen < 0.5) discard;
	if (uFrozen > 0.5) col = vec3(1.5, 1.6, 1.7) * clamp(uSunDir.y * 1.4 + 0.1, 0.03, 1.0);
	float mean_rho = uScaleH * (1.0 - exp(-max(uCamLocal.y, 1.0) / uScaleH)) / max(uCamLocal.y, 1.0);
	float fog = 1.0 - exp(-uDensity * dist * mean_rho);
	col = mix(col, uHaze * clamp(uSunDir.y * 1.1 + 0.25, 0.02, 1.0), fog);
	ALBEDO = col;
	ALPHA = 1.0;
}
