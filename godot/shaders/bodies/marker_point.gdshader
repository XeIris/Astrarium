// ============================================================================
// THE POINT-SOURCE MARKER — port of createMarker()'s material in sim/scale.js.
// See sim/marker.gd for why it exists and how it hands over from the mesh.
//
// A camera-facing quad (the web copied camera.quaternion onto the mesh; here
// the billboard is formed in view space, which is the same plane) scaled by the
// node's own scale, as THREE's mesh.scale was.
//
// BLENDING is deliberately split in the web build: RGB adds (ONE, ONE), ALPHA
// takes the MAX, because alpha is the log-encoded temperature and "the hottest
// contributor wins" is the right composite. Godot has no MAX blend on a
// spatial material, and it does not need one: the destination under a marker
// is almost always the sky, SKY_ALPHA = 0.995, which is above every code a
// marker can publish (≤ 0.98) — so the web's max() was a no-op there, and the
// temperature pass here discards (PORT_GUIDE.md §6, the marker row).
// ============================================================================
shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform vec3 uColor = vec3(1.0);
uniform float uOpacity = 0.0;
uniform float uGain = 1.0;
uniform float uSel = 0.0;
// same encoding as the surface shaders: log(T)/25.33, clamped below 1
uniform float uTempA = 0.0;

varying vec2 vQ;

void vertex() {
	vQ = VERTEX.xy + 0.5;
	vec2 sc = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	POSITION = PROJECTION_MATRIX * (centre + vec4(VERTEX.xy * sc, 0.0, 0.0));
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r = length(vQ - 0.5) * 2.0;
	if (r > 1.0) discard;
	float core = exp(-r * r * 30.0);
	float halo = exp(-r * r * 3.2) * 0.28;
	float a = (core + halo) * uOpacity;
	// Selection reticle. Once every planet is an honest point of light it is
	// indistinguishable from the background starfield, so picking one out of
	// the Bodies list has to show you WHERE it is. The ring sits well
	// outside the core so it frames the body without hiding it.
	float ring = uSel * uOpacity * 0.5 *
	             (smoothstep(0.58, 0.65, r) - smoothstep(0.71, 0.78, r));
	if (a <= 0.003 && ring <= 0.003) discard;
	// premultiplied: colour already carries its own coverage
	ALBEDO = uColor * a * uGain + vec3(0.5, 0.72, 1.0) * ring;
	ALPHA = 0.0;
}
