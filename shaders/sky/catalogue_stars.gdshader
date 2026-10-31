// Catalogue stars (sim/brightstars.gd): one quad per star, set at the far plane in
// its J2000 direction and held a few pixels across. INSTANCE_CUSTOM is the scene
// direction and the flux of a sky star of that V; COLOR is its blackbody colour.
// Additive and depth-tested, so bodies hide them; the temperature pass discards, as
// the point-source markers do.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled;

#include "res://shaders/common/temp_pass.gdshaderinc"

uniform float uPixSr = 1e-6;
uniform vec2 uViewport = vec2(1280.0, 720.0);
uniform float uGain = 1.0;
const float QUAD_PX = 5.0;

varying vec2 vQ;
varying vec3 vCol;

void vertex() {
	vQ = VERTEX.xy + 0.5;
	vec3 d = mat3(VIEW_MATRIX) * normalize(INSTANCE_CUSTOM.xyz);
	vCol = COLOR.rgb * INSTANCE_CUSTOM.w / uPixSr * uGain;
	vec4 clip = PROJECTION_MATRIX * vec4(d, 1.0);
	vec2 ndc = d.z < 0.0 ? clip.xy / clip.w : vec2(4.0);   // behind the camera: off screen
	// z = 0 is the far plane under reversed Z, behind every body.
	POSITION = vec4(ndc + VERTEX.xy * QUAD_PX * 2.0 / uViewport, 0.0, 1.0);
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r = length(vQ - 0.5) * 2.0;
	if (r > 1.0) discard;
	float a = exp(-r * r * 6.0);
	ALBEDO = vCol * a;
}
