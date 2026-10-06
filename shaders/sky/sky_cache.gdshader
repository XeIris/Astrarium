// Renders the sky's diffuse emission (rgb) and dust depth (a) into a 3x2 cube-face
// atlas for render/sky_cache.gd. Face texel centres lie on face edges; sky_cacheUV
// is the inverse mapping.
shader_type canvas_item;
render_mode unshaded, blend_disabled;

#include "res://shaders/sky/sky.gdshaderinc"

uniform float uCacheFace = 512.0;

void fragment() {
	vec2 px = UV * vec2(3.0, 2.0) * uCacheFace;
	vec2 tile = floor(px / uCacheFace);
	vec2 g = (px - tile * uCacheFace - 0.5) / (uCacheFace - 1.0) * 2.0 - 1.0;
	vec3 dir = sky_uncube(tile.y * 3.0 + tile.x, sky_fromGrid(g));
	float tau = sky_tau(dir);
	COLOR = vec4(sky_diffuseAdd(vec3(0.0), dir, tau, sky_extinction(tau)), tau);
}
