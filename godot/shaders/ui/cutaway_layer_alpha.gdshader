// ============================================================================
// cutaway_layer.gdshader for the TRANSPARENT shells — a black hole's
// photon sphere, ISCO and ergosphere, which are locations in the spacetime
// rather than material (three: transparent, opacity 0.16, depthWrite left on,
// NormalBlending → blend_mix + depth_draw_always). Same clip, same lighting.
// ============================================================================
shader_type spatial;
render_mode cull_disabled, diffuse_lambert, specular_schlick_ggx, blend_mix, depth_draw_always;

uniform vec3 albedo : source_color = vec3(1.0);
uniform vec3 emissive = vec3(0.0);        // linear
uniform float roughness_v = 0.82;
uniform float opacity = 1.0;

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
	ALPHA = opacity;
}
