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
uniform float uScorchRadius = 0.0;

varying vec2 vLocal;

float noise2(vec2 p) { return fract(sin(dot(p, vec2(17.23, 81.71))) * 43758.5453); }

void vertex() {
	vLocal = VERTEX.xy;
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * (1.0 - 2.0e-4 * uOrder);
	NORMAL = normalize((MODELVIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	if (uScorchRadius > 0.0) {
		float r = length(vLocal) / uScorchRadius;
		float patches = noise2(floor(vLocal * 0.22));
		float edge = 1.0 - smoothstep(0.56, 0.99, r + (patches - 0.5) * 0.13);
		if (edge < noise2(floor(FRAGCOORD.xy * 0.5))) discard;
		ALBEDO = uColor * (0.55 + 0.65 * patches);
	} else {
		ALBEDO = uColor;
	}
	ROUGHNESS = uRoughness;
	METALLIC = uMetallic;
	SPECULAR = 0.5;
}
