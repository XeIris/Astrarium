// THE EXHAUST TRAIL: one tube of smoke along the nodes Plume.SmokeColumn lays in the
// air, and along the plume's axis where the column grows out of the flame. Each
// instance is one segment's box, but its march only counts the slab between the
// segment's two end planes. Each end plane bisects the bend into the neighbouring
// segment, so neighbours share it: the segments partition one column with no gap and
// no overlap (two volumes composited one over the other are not one medium).
// Density and light are smoke_column.gdshaderinc's, with the noise fixed in the air
// (uAir). See docs/physics/plumes.md#the-trail.
// Instance data: transform = the box (x, z: unit side axes × Rb; y: the axis × (H + Rb),
// H the half length), COLOR = (grey, τ1, τ0x, τ0z): the end planes' normals are
// axis + τ1·x̂ at node 1 and axis + τ0x·x̂ + τ0z·ẑ at node 0. CUSTOM = (a0, a1, K0, K1).
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;
#include "res://shaders/flight/smoke_column.gdshaderinc"

uniform sampler2D uDepth : hint_depth_texture, filter_nearest, repeat_disable;
uniform mat4 uAir;            // view space → air-fixed noise space, m (wrapped)
uniform int uSteps = 5;
uniform int uLightSteps = 0;
uniform bool uFine = false;   // a third, finer noise octave

varying vec3 vView;
varying flat vec3 vN0;        // node 0, view space
varying flat vec3 vN1;        // node 1
varying flat vec3 vD;         // unit axis node 0 → node 1
varying flat vec3 vM0;        // end plane normals, pointing along the axis
varying flat vec3 vM1;
varying flat vec4 vAK;        // a0, a1, K0, K1
varying flat float vGrey;
varying flat float vRb;

void vertex() {
	vAK = INSTANCE_CUSTOM;
	vGrey = COLOR.r;
	vec3 c = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	vec3 ax = (MODELVIEW_MATRIX * vec4(1.0, 0.0, 0.0, 0.0)).xyz;
	vec3 ay = (MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz;
	vec3 az = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 1.0, 0.0)).xyz;
	vRb = length(ax);
	float hy = length(ay);
	vD = ay / max(hy, 1e-6);
	float H = hy - vRb;
	vN0 = c - vD * H;
	vN1 = c + vD * H;
	vec3 xh = ax / max(vRb, 1e-6), zh = az / max(vRb, 1e-6);
	vM0 = normalize(vD + COLOR.b * xh + COLOR.a * zh);
	vM1 = normalize(vD + COLOR.g * xh);
	vView = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	POSITION = PROJECTION_MATRIX * vec4(vView, 1.0);
}

void fragment() {
	vec3 rd = normalize(vView);
	// ---- the ray inside the cylinder of radius Rb about the axis
	vec3 oc = -vN0;
	float dd = dot(rd, vD), od = dot(oc, vD);
	vec3 rp = rd - vD * dd, op = oc - vD * od;
	float A = dot(rp, rp), B = dot(op, rp), C = dot(op, op) - vRb * vRb;
	float t0 = 0.0, t1 = 1e30;
	if (A > 1e-9) {
		float h = B * B - A * C;
		if (h <= 0.0) discard;
		h = sqrt(h);
		t0 = max(t0, (-B - h) / A); t1 = min(t1, (-B + h) / A);
	} else if (C > 0.0) discard;
	// ---- and between the end planes: (p − n0)·m0 ≥ 0, (p − n1)·m1 ≤ 0
	float a0 = dot(rd, vM0), b0 = dot(vN0, vM0);
	if (abs(a0) > 1e-7) { if (a0 > 0.0) t0 = max(t0, b0 / a0); else t1 = min(t1, b0 / a0); }
	else if (b0 > 0.0) discard;
	float a1 = dot(rd, vM1), b1 = dot(vN1, vM1);
	if (abs(a1) > 1e-7) { if (a1 > 0.0) t1 = min(t1, b1 / a1); else t0 = max(t0, b1 / a1); }
	else if (b1 < 0.0) discard;
	float d = texture(uDepth, SCREEN_UV).r;
	vec4 v = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d, 1.0);
	t1 = min(t1, length(v.xyz / v.w));
	if (t1 <= t0) discard;

	vec3 sunV = normalize((VIEW_MATRIX * vec4(uSunDir, 0.0)).xyz);
	vec3 upV = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 sunP = sunV - vD * dot(sunV, vD);
	float cosv = dot(rd, sunV);
	float dt = (t1 - t0) / float(uSteps);
	float jit = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float T = 1.0;
	vec3 L = vec3(0.0);
	for (int i = 0; i < 16; i++) {
		if (i >= uSteps) break;
		float t = t0 + (float(i) + jit) * dt;
		vec3 p = rd * t;
		// Along the segment by the distances to its end planes, so a, K and the axis
		// point agree with the neighbour's on the plane they share.
		float d0 = dot(p - vN0, vM0), d1 = dot(vN1 - p, vM1);
		float s = clamp(d0 / max(d0 + d1, 1e-6), 0.0, 1.0);
		float a = mix(vAK.x, vAK.y, s);
		float K = mix(vAK.z, vAK.w, s);
		if (K <= 0.0) continue;
		vec3 q = p - mix(vN0, vN1, s);
		vec3 rad = q - vD * dot(q, vD);
		float sg = column_sigma((uAir * vec4(p, 1.0)).xyz, length(rad), a, K, uFine);
		if (sg <= 0.0) continue;
		// The sun through the column. On Ultra the steps toward the sun add the billows'
		// own shadows as a departure from that mean, so it is no darker on average.
		float sig_m = 0.5 * K / (a * a);
		float od_s = column_sun_od(rad, sunP, a, K);
		for (int k = 1; k <= 2; k++) {
			if (k > uLightSteps) break;
			float l = 0.45 * a * float(k);
			vec3 ps = p + sunV * l;
			od_s += (column_sigma((uAir * vec4(ps, 1.0)).xyz, length(rad + sunP * l), a, K, false) - sig_m) * 0.45 * a;
		}
		od_s = max(od_s, 0.0);
		float up = dot(rad, upV) / max(length(rad), 1e-4);
		vec3 Ls = vGrey * smoke_light(od_s, cosv, up);
		float a_s = 1.0 - exp(-sg * dt);
		L += T * Ls * a_s;
		T *= 1.0 - a_s;
		if (T < 0.02) break;
	}
	float cover = 1.0 - T;
	if (cover < 0.003) discard;
	ALBEDO = L / cover;
	ALPHA = cover;
}
