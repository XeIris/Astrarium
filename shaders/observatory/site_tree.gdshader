// A tree of the site: lit like the terrain, with its skylight so a backlit wood keeps its
// colour instead of going black against the evening.
shader_type spatial;
render_mode diffuse_lambert, specular_disabled;

uniform vec3 uAlbedo = vec3(0.17, 0.23, 0.1);
uniform float uSkyI = 0.35;
uniform float uSunY = 1.0;

void fragment() {
	ALBEDO = uAlbedo;
	ROUGHNESS = 1.0;
	EMISSION = uAlbedo * uSkyI * smoothstep(-0.18, 0.05, uSunY);
}
