#[compute]
#version 450
layout(local_size_x=8,local_size_y=8) in;
layout(set=0,binding=0) uniform sampler2D uDepth;
layout(set=0,binding=1) uniform sampler3D uCloudShape;
layout(set=0,binding=2) uniform sampler3D uCloudWorley;
layout(set=0,binding=3) uniform sampler3D uCloudDetail;
layout(rgba16f,set=0,binding=4) uniform restrict writeonly image2D outColor;
layout(r32f,set=0,binding=5) uniform restrict writeonly image2D outDepth;
layout(set = 0, binding = 6, std140) uniform Params { vec4 data[34]; } P;
#define uCloudCoverage P.data[0].x
#define uCloudZ P.data[1].x
#define uCloudItcz P.data[2].x
#define uCloudBase P.data[3].x
#define uCloudTop P.data[4].x
#define uCloudSigma P.data[5].x
#define uLocalToPlanet mat3(P.data[6].xyz,P.data[7].xyz,P.data[8].xyz)
#define uPlanetR P.data[9].x
#define uCloudWind P.data[10].xyz
#define uClearAt P.data[11].xyz
#define uClearR P.data[12].x
#define uCamLocal P.data[13].xyz
#define uSunDir P.data[14].xyz
#define uSunColor P.data[15].xyz
#define uSkyTop P.data[16].xyz
#define uSkyNight P.data[17].xyz
#define uSkyBottom P.data[18].xyz
#define uBounce P.data[19].xyz
#define uHaze P.data[20].xyz
#define uHazeDensity P.data[21].x
#define uHazeRho P.data[22].x
#define uMaxDist P.data[23].x
#define uSteps int(P.data[24].x)
#define uLightSteps int(P.data[25].x)
#define uDetail P.data[26].x
#define uPixAngle P.data[27].x
#define uLightFirst P.data[28].x
#define uCovReuse P.data[29].x

#define CLOUD_COMPUTE
#include "res://shaders/common/cloud_climate.gdshaderinc"
#include "res://shaders/flight/clouds.gdshaderinc"
#include "res://shaders/flight/clouds_march.gdshaderinc"

void main() {
	ivec2 tap = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(tap, imageSize(outColor)))) return;

	// March one original pixel per 2×2 quad against its resolved opaque depth.
	ivec2 px = tap * 2;
	ivec2 size = textureSize(uDepth, 0);
	vec2 uv = (vec2(px) + 0.5) / vec2(size);
	vec4 optics = P.data[30];
	vec3 ray_view = vec3((2.0 * uv.x - 1.0) / optics.x, (1.0 - 2.0 * uv.y) / optics.y, -1.0);
	mat3 basis = mat3(P.data[31].xyz, P.data[32].xyz, P.data[33].xyz);
	float d = texelFetch(uDepth, px, 0).r;
	float scene = optics.z * optics.w / (optics.z + d * (optics.w - optics.z)) * length(ray_view);
	vec3 rd = normalize(basis * ray_view);
	vec2 interval = cloud_interval(uCamLocal, rd);
	float t1 = min(interval.y, min(scene, uMaxDist));
	vec4 layer = vec4(0.0);
	if (uCloudCoverage > 0.0 && t1 > interval.x) {
		layer = cloud_march(uCamLocal, rd, interval.x, t1, cloud_jitter(px));
	}
	imageStore(outDepth, tap, vec4(scene));
	imageStore(outColor, tap, layer);
}
