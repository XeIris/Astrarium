// For pincheck: the crust's height at points handed in a texture, packed into eight-bit channels.
shader_type canvas_item;
#define TERRAIN_EXACT
#include "res://shaders/bodies/terrain.gdshaderinc"
uniform sampler2D uPoints : filter_nearest;
uniform float uSeed = 0.0;
uniform float uCrater = 0.0;
void fragment() {
	vec3 p = normalize(texture(uPoints, UV).xyz);
	float h; float rug;
	terrain(p, uSeed, h, rug);
	if (uCrater > 0.002) {
		float fresh;
		float ch = craters(p, uSeed, uCrater, fresh);
		h = mix(h, h * 0.30 + ch, clamp(uCrater, 0.0, 1.0));
	}
	float k = clamp((h + 40.0) / 80.0, 0.0, 0.999999);
	float a = k * 255.0;
	float b = fract(a) * 255.0;
	float c = fract(b) * 255.0;
	COLOR = vec4(floor(a) / 255.0, floor(b) / 255.0, floor(c) / 255.0, 1.0);
}
