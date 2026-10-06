// ONE SHELL OF THE 3D CUTAWAY (sim/cutaway.gd): roughness 0.82, metalness 0,
// double-sided, with two world-space clip planes (−x ≥ 0 and −z ≥ 0) intersected, so
// only the x > 0 and z > 0 quarter is removed and the notch stays facing the camera.
// Lambert diffuse plus schlick_ggx at SPECULAR 0.5 (F0 = 0.04); cull_disabled flips
// back-face normals, so the far inner wall is lit as an inside surface. Emissive is
// linear, added after lighting.
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx;

uniform vec3 albedo : source_color = vec3(1.0);
uniform vec3 emissive = vec3(0.0);        // linear
uniform float roughness_v = 0.82;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	if (wpos.x > 0.0 && wpos.z > 0.0) discard;
	ALBEDO = albedo;
	ROUGHNESS = roughness_v;
	METALLIC = 0.0;
	SPECULAR = 0.5;
	EMISSION = emissive;
}
