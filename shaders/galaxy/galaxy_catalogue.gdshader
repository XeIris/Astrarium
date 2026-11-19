// The real stars around the Sun (sim/galaxy/gal_neighbourhood.gd): one point per star,
// its offset from the Sun on the Sun's axes in VERTEX (kpc), (colour per unit visible
// light, visible luminosity in Sun-luminances) in CUSTOM0 and its set (0 near, 1 far)
// in CUSTOM1.x. Drawn as the lattice draws (galaxy_stars.gdshader), by point_flux. Their V is
// as observed, so no model dust dims them again.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, skip_vertex_transform;

#include "res://shaders/common/temp_pass.gdshaderinc"
#include "res://shaders/common/point_source.gdshaderinc"

const float QUAD_PX = 5.0;
// The Sun relative to the camera (kpc, galaxy-local, reduced in double) and its axes.
uniform vec3 uSunRel = vec3(0.0);
uniform mat3 uSunBasis = mat3(1.0);
// Near stars are drawn inside the camera's resolved sphere, as the lattice's are.
uniform float uRes = 0.04;
uniform float uNearW = 1.0;
uniform float uFarW = 1.0;
uniform float uGain = 1.0;
uniform float uPixSr = 1e-6;
uniform float uProfilePx2 = 3.27;

varying vec3 vCol;

void vertex() {
	vec3 rel = uSunRel + uSunBasis * VERTEX;
	float d = length(rel);
	bool far = CUSTOM1.x > 0.5;
	float w = far ? uFarW : uNearW * step(d, uRes);
	float flux = CUSTOM0.w / (12.566371 * max(d * d, 1e-12));
	float v = w * point_flux(flux / uPixSr * uGain) / uProfilePx2;
	if (v >= 2e-4) {
		vec3 world = mat3(MODEL_MATRIX) * rel;
		VERTEX = (VIEW_MATRIX * vec4(world, 1.0)).xyz;
		POINT_SIZE = QUAD_PX;
		vCol = CUSTOM0.rgb * v;
	} else {
		VERTEX = vec3(0.0, 0.0, 1e9);
		POINT_SIZE = 0.0;
		vCol = vec3(0.0);
	}
}

void fragment() {
	if (is_temp_pass(CAMERA_VISIBLE_LAYERS)) discard;
	float r = length(POINT_COORD - 0.5) * 2.0;
	if (r > 1.0 || vCol.r + vCol.g + vCol.b <= 0.0) discard;
	ALBEDO = vCol * exp(-r * r * 6.0);
}
