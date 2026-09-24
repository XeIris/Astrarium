// ============================================================================
// PLACEHOLDER — replaced by the port of sim/sky.js (SKY_GLSL). It exists so the
// render pipeline can be brought up before the sky is ported. The real file
// declares every sky uniform (uGalNormal, uwSynch, …, uBeta) and defines:
//   vec3 skyRadiance(vec3 d, vec3 ddx, vec3 ddy)
//   vec3 sky_aberrate(vec3 dir)
//   float sky_beaming()
//   const float SKY_ALPHA = 0.995;
// ============================================================================
const float SKY_ALPHA = 0.995;
uniform vec3 uBeta = vec3(0.0);
float sky_h(vec3 p){ return fract(sin(dot(p, vec3(12.9898, 78.233, 37.719))) * 43758.5453); }
vec3 skyRadiance(vec3 d, vec3 ddx, vec3 ddy){
	vec3 c = floor(d * 300.0);
	float s = step(0.9985, sky_h(c));
	return vec3(0.002, 0.003, 0.006) + vec3(s) * 0.8;
}
vec3 sky_aberrate(vec3 dir){ return dir; }
float sky_beaming(){ return 1.0; }
