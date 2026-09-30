// THE POINT-SOURCE MARKER (see sim/marker.gd): a camera-facing quad formed in view
// space, scaled by the node's scale. RGB adds; the temperature would take the max,
// but the destination is almost always the sky (SKY_ALPHA = 0.995, above any marker
// code ≤ 0.98), so the temperature pass discards.
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
	// Selection reticle, well outside the core, so a point-sized body can be found.
	float ring = uSel * uOpacity * 0.5 *
	             (smoothstep(0.58, 0.65, r) - smoothstep(0.71, 0.78, r));
	if (a <= 0.003 && ring <= 0.003) discard;
	// premultiplied: colour already carries its own coverage
	ALBEDO = uColor * a * uGain + vec3(0.5, 0.72, 1.0) * ring;
	ALPHA = 0.0;
}
