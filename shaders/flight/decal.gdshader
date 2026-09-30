// A DECAL (the apron, the crawlerway) lies on the concrete, separated only by a
// depth bias. StandardMaterial3D has no polygon offset, so this is the same
// Lambert / Schlick-GGX surface with the view-space vertex pulled toward the eye by a
// fixed fraction of its distance: the pixel doesn't move, and the bias scales with
// range as float depth resolution does. `uOrder` stacks decals (the apron's 2 over
// the crawlerway's 1). The apron and joints are ground_mark.gdshader.
shader_type spatial;
render_mode skip_vertex_transform, diffuse_lambert, specular_schlick_ggx, cull_back;

uniform vec3 uColor : source_color = vec3(0.5);
uniform float uRoughness = 0.95;
uniform float uMetallic = 0.02;
uniform float uOrder = 1.0;

void vertex() {
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * (1.0 - 2.0e-4 * uOrder);
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	ALBEDO = uColor;
	ROUGHNESS = uRoughness;
	METALLIC = uMetallic;
	SPECULAR = 0.5;
}
