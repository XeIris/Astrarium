// ============================================================================
// A DECAL IS NOT A SLAB LIFTED A FEW CENTIMETRES — launchsite.js's decal().
// ----------------------------------------------------------------------------
// The apron and the crawlerway lie ON the concrete, coplanar with it, and the
// only thing separating them is a bias. The web build used polygonOffset: the
// bias expressed in the smallest resolvable depth increment at that fragment,
// correct at every distance, where any constant lift in metres is too small
// far away and floats visibly close up.
//
// StandardMaterial3D has no polygon offset, so this is the same material (a
// Lambert / Schlick-GGX surface with the MeshStandardMaterial's parameters)
// with the bias done the way a float depth buffer wants it: the view-space
// vertex is pulled toward the eye by a fixed FRACTION of its distance. The
// pixel it projects to does not move; only its depth does, by an amount that
// scales with range exactly as depth resolution does. `uOrder` is the JS
// order argument (the apron is 2, drawn over the crawlerway's 1).
// ============================================================================
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
