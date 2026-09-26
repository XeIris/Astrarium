// ============================================================================
// ONE SHELL OF THE 3D CUTAWAY (sim/cutaway.gd) — a MeshStandardMaterial with
// two clipping planes, which StandardMaterial3D cannot express.
//
// three.js: roughness 0.82, metalness 0, DoubleSide, clippingPlanes
// [(-1,0,0)·p ≥ 0, (0,0,-1)·p ≥ 0] with clipIntersection = true — a fragment
// is removed only where BOTH planes would remove it, i.e. the one quarter
// x > 0 AND z > 0, in WORLD space (three's clipping planes are world-space,
// so the notch stays facing the camera while the model turns inside it).
// Godot's own lighting does the rest: diffuse_lambert is three's
// BRDF_Lambert, schlick_ggx with SPECULAR 0.5 is its F0 = 0.04 dielectric,
// and cull_disabled flips the normal on back faces as DoubleSide does — the
// far inner wall seen through the notch is lit as an inside surface.
// The emissive is three's `emissive` (linear, added after lighting).
// ============================================================================
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
