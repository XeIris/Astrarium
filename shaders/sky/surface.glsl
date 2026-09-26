#[compute]
#version 450
// ============================================================================
// SURFACE VIEW — standing on the planet, looking up. The port of
// sim/skyview.js's SKY_FRAG; the derivation is in the header of
// sim/skyview.gd, and every comment below is the web build's.
// ----------------------------------------------------------------------------
// The web build ran this as a full-screen fragment pass that read the rendered
// scene (sky backdrop + geometry, `tScene`) and wrote the composite into the
// HDR buffer. Here it is a compute kernel the pipeline runs between compose
// and the band remap (render/postfx.gd, "0b"), reading the composed HDR buffer
// and writing a second one. Nothing in it needs screen-space derivatives, so
// nothing is lost in the move to compute.
//
// ALPHA. The web pass wrote gl_FragColor = vec4(col * uExposure, 1.0) over the
// whole frame, so in the surface view every pixel reached the remap as 1.0 —
// "no temperature data, infer T from colour" — and the backdrop's SKY_ALPHA
// and every emitter's published temperature were overwritten. This kernel
// writes 1.0 for the same reason and with the same consequence.
//
// The ray is rebuilt exactly as the web build built it from uCamMat/uFov/
// uAspect, with vUv reconstructed WebGL-style (origin bottom-left) from the
// pixel, and the scene is fetched at the same pixel the web's texture2D(tScene,
// vUv) hit (a texel centre, so linear filtering returns the texel itself).
// ============================================================================
layout(local_size_x = 8, local_size_y = 8) in;
layout(set = 0, binding = 0) uniform sampler2D tScene;
layout(rgba16f, set = 0, binding = 1) uniform restrict writeonly image2D outHdr;

#define MAX_SUNS 4
layout(set = 0, binding = 2, std140) uniform Params {
	vec4 sunDirAng[MAX_SUNS];   // xyz uSunDir (unit vectors to each sun), w uSunAng (angular RADIUS, rad)
	vec4 sunColInt[MAX_SUNS];   // rgb uSunColor, w uSunInt (relative flux, 1 = one solar constant)
	vec4 upCount;               // xyz uUp (local vertical at the observer), w uSunCount
	vec4 northFov;              // xyz uNorth (a horizon reference direction), w uFov (rad)
	vec4 camRight;              // uCamMat column 0 (world), w uAspect
	vec4 camUp;                 // uCamMat column 1, w uTime
	vec4 camBack;               // uCamMat column 2, w uExposure
	vec4 camPosNight;           // xyz uCamPos (unused by the shader, as in the web), w uNight
	vec4 clim0;                 // uIce, uScorch, uClouds, uHumidity
	vec4 clim1;                 // uStorm, _, _, _
} P;

#define uSunDir(i) P.sunDirAng[i].xyz
#define uSunAng(i) P.sunDirAng[i].w
#define uSunColor(i) P.sunColInt[i].rgb
#define uSunInt(i) P.sunColInt[i].w
#define uSunCount int(P.upCount.w + 0.5)
#define uUp P.upCount.xyz
#define uNorth P.northFov.xyz
#define uFov P.northFov.w
#define uAspect P.camRight.w
#define uTime P.camUp.w
#define uExposure P.camBack.w
#define uIce P.clim0.x
#define uScorch P.clim0.y
#define uClouds P.clim0.z
#define uHumidity P.clim0.w
#define uStorm P.clim1.x

#define PI 3.14159265359

// optical depth of the whole atmosphere at zenith (β · H)
const vec3 TAU_R = vec3(0.0490, 0.1136, 0.2784);
const float TAU_M = 0.0180;

float hash(vec2 p){ return fract(sin(dot(p, vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p){ vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
	return mix(mix(hash(i),hash(i+vec2(1,0)),f.x), mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),f.x), f.y); }
float fbm(vec2 p){ float v=0.0,a=0.5; for(int i=0;i<5;i++){ v+=a*noise(p); p*=2.07; a*=0.5; } return v; }

// Kasten–Young air mass for a given cosine of the zenith angle.
float airMass(float cz){
	float z = degrees(acos(clamp(cz, -1.0, 1.0)));
	return 1.0 / (max(cz, 0.0) + 0.50572 * pow(max(96.07995 - z, 0.01), -1.6364));
}

float phaseRayleigh(float c){ return 3.0 / (16.0 * PI) * (1.0 + c*c); }
float phaseMie(float c){
	const float g = 0.76;
	float gg = g*g;
	return (1.0 - gg) / (4.0*PI * pow(1.0 + gg - 2.0*g*c, 1.5));
}

// Single-scattered radiance along a view ray of air mass mView.
//
// The naive form is (beta_scatter * phase) * mView, which grows WITHOUT BOUND as
// you look toward the horizon — at the horizon mView ~ 38, so the horizon comes
// out 38x the zenith and whites out the frame. That is wrong: light scattered
// toward you is also extinguished on its way to you. Integrating both through a
// uniform slab gives a SATURATING result,
//
//     L = (beta_s * P / beta_e) * (1 - exp(-beta_e * m))
//
// which tends to the single-scattering albedo as the path gets optically thick.
// It is why a real horizon is pale and bright but not blinding.
vec3 inScatter(float cosTheta, float mView){
	vec3 betaE = TAU_R + TAU_M;
	vec3 betaS = TAU_R * phaseRayleigh(cosTheta) + vec3(TAU_M * phaseMie(cosTheta));
	return (betaS / betaE) * (1.0 - exp(-betaE * mView));
}

void main(){
	ivec2 px = ivec2(gl_GlobalInvocationID.xy);
	ivec2 sz = imageSize(outHdr);
	if(px.x >= sz.x || px.y >= sz.y) return;
	// vUv as WebGL had it: origin bottom-left, so ndc.y points UP. The image's
	// row 0 is the TOP of the frame, hence the flip.
	vec2 vUv = vec2((float(px.x) + 0.5) / float(sz.x), 1.0 - (float(px.y) + 0.5) / float(sz.y));

	vec2 ndc = vUv * 2.0 - 1.0; ndc.x *= uAspect;
	float f = tan(uFov * 0.5);
	mat3 camMat = mat3(P.camRight.xyz, P.camUp.xyz, P.camBack.xyz);
	vec3 rd = normalize(camMat * normalize(vec3(ndc.x*f, ndc.y*f, -1.0)));

	float elev = dot(rd, uUp);                 // sine of the view elevation
	vec3 scene = texelFetch(tScene, px, 0).rgb;

	// Extinction on the SUN'S OWN DISC. The rendered star knows nothing about the
	// air it is being seen through, so redden it here: a sun on the horizon is
	// looking at us through ~38 air masses, which is why it goes blood red before
	// it sets. Applied per sun, so each one reddens on its own schedule.
	vec3 tint = vec3(1.0);
	for(int i=0;i<MAX_SUNS;i++){
		if(i >= uSunCount) break;
		float ang = acos(clamp(dot(rd, uSunDir(i)), -1.0, 1.0));
		float onDisc = 1.0 - smoothstep(uSunAng(i) * 0.9, uSunAng(i) * 3.5, ang);
		if(onDisc <= 0.001) continue;
		float sElev = dot(uSunDir(i), uUp);
		vec3 tr = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
		// below the horizon the disc is cut off by the planet itself
		tr *= smoothstep(-0.02, 0.01, sElev);
		tint = mix(tint, tr, onDisc);
	}
	scene *= tint;

	// ---------------------------------------------------------------- sky
	float mView = airMass(max(elev, 0.0));
	vec3 sky = vec3(0.0);
	vec3 sunGlare = vec3(0.0);
	float dayness = 0.0;

	for(int i=0;i<MAX_SUNS;i++){
		if(i >= uSunCount) break;
		vec3 L = uSunDir(i);
		float sElev = dot(L, uUp);
		// a sun below the horizon still lights the sky for a while — twilight
		float vis = smoothstep(-0.18, 0.02, sElev);
		if(vis <= 0.0) continue;

		float mSun = airMass(max(sElev, 0.0));
		vec3 trans = exp(-(TAU_R + TAU_M) * mSun);      // reddening on the way in
		float c = dot(rd, L);

		vec3 I = uSunColor(i) * uSunInt(i) * vis;
		sky += I * trans * inScatter(c, mView) * 32.0;

		// aureole: the bright, tight halo right around the disc
		float halo = pow(max(c, 0.0), 900.0) * 0.5 + pow(max(c, 0.0), 60.0) * 0.06;
		sunGlare += I * trans * halo * 2.0;

		dayness = max(dayness, vis * uSunInt(i) * max(sElev, 0.0));
	}

	// haze / humidity greys the sky out; storms darken it
	float haze = uHumidity * 0.35 + uStorm * 0.25;
	float lum = dot(sky, vec3(0.2126, 0.7152, 0.0722));
	sky = mix(sky, vec3(lum) * 1.05, clamp(haze, 0.0, 0.7));
	sky *= (1.0 - uStorm * 0.35);

	// a scorched world hazes over with dust and steam
	sky = mix(sky, sky * vec3(1.25, 0.85, 0.6) + vec3(0.03,0.01,0.0), uScorch * 0.8);

	// ---------------------------------------------------------------- ground
	vec3 ground = vec3(0.0);
	float groundMix = 0.0;
	if(elev < 0.0){
		// intersect the local ground plane; distance drives the fog
		float dist = -1.0 / min(elev, -1e-4);
		vec2 gp = vec2(dot(rd, uNorth), dot(rd, cross(uUp, uNorth))) * dist;

		float relief = fbm(gp * 0.35) * 0.7 + fbm(gp * 1.7) * 0.3;
		vec3 rock = mix(vec3(0.16,0.13,0.11), vec3(0.30,0.25,0.20), relief);
		vec3 veg  = mix(vec3(0.10,0.16,0.07), vec3(0.20,0.26,0.11), relief);
		// vegetation only in the temperate band, desert when scorched, ice when frozen
		vec3 base = mix(rock, veg, clamp((1.0 - uIce) * (1.0 - uScorch) * 0.9, 0.0, 1.0));
		base = mix(base, vec3(0.45,0.34,0.20), uScorch * 0.7);
		base = mix(base, vec3(0.80,0.85,0.92), smoothstep(0.05, 0.75, uIce));

		// lit by every sun that is up
		vec3 lit = vec3(0.0);
		for(int i=0;i<MAX_SUNS;i++){
			if(i >= uSunCount) break;
			float sElev = dot(uSunDir(i), uUp);
			float vis = smoothstep(-0.05, 0.12, sElev);
			vec3 trans = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
			// slope shading: relief gradient against the sun's azimuth
			float shade = 0.55 + 0.45 * relief;
			lit += uSunColor(i) * uSunInt(i) * vis * trans * max(sElev, 0.0) * shade;
		}
		lit += (0.10 + 0.16 * uIce) * max(sky, vec3(0.0)); // skylight bounced from the sky itself
		ground = base * lit * 7.5;
		ground += vec3(0.9,0.25,0.05) * pow(uScorch, 2.0) * 0.35;

		// aerial perspective: distant ground dissolves into the horizon sky
		float fog = 1.0 - exp(-dist * 0.0016 * (1.0 + haze * 2.0));
		vec3 horizonSky = sky * 1.15;
		ground = mix(ground, horizonSky, clamp(fog, 0.0, 1.0));
		// NB: smoothstep is undefined for edge0 >= edge1, so invert rather than
		// passing the edges backwards.
		groundMix = 1.0 - smoothstep(-0.006, 0.0, elev);
	}

	// ---------------------------------------------------------------- composite
	// Sky opacity: an bright sky hides the starfield, a dark one lets it through.
	float skyLum = dot(sky, vec3(0.2126,0.7152,0.0722));
	// Hide the decorative starfield even under sub-solar daylight; this
	// contrast threshold is separate from the radiance/exposure calibration.
	float opacity = 1.0 - exp(-skyLum * 40.0);
	// never fully mask the suns themselves — they outshine their own sky
	float sunMask = 0.0;
	for(int i=0;i<MAX_SUNS;i++){
		if(i >= uSunCount) break;
		float c = dot(rd, uSunDir(i));
		float ang = acos(clamp(c, -1.0, 1.0));
		sunMask = max(sunMask, 1.0 - smoothstep(uSunAng(i) * 0.85, uSunAng(i) * 2.6, ang));
	}
	opacity *= (1.0 - sunMask * 0.92);

	// The rendered star discs live in the same linear space as the sky, but their
	// shader is tuned for the un-tonemapped orbit view, so lift them here to keep
	// a sun reading as a sun once the filmic curve is applied.
	// Scattered light ADDS along the ray, including over the solar disc.
	// Replacing sky with a dim, orbit-exposed star made a dark hole in the halo.
	// Surface viewing uses a brighter disc exposure than close-up stellar study.
	vec3 col = scene * mix(1.5, 24.0, sunMask) * (1.0 - opacity)
	         + sky + sunGlare * (1.0 - groundMix);

	// cloud deck overhead, thickening with humidity
	if(elev > 0.0 && uClouds > 0.02){
		float d = 1.0 / max(elev, 0.02);
		vec2 cp = vec2(dot(rd, uNorth), dot(rd, cross(uUp, uNorth))) * d * 0.5;
		float cd = fbm(cp * 0.6 + uTime * 0.01);
		float cov = smoothstep(0.60 - uClouds*0.45, 0.80 - uClouds*0.30, cd);
		cov *= smoothstep(0.0, 0.16, elev);       // thin out toward the horizon
		vec3 cloudLit = vec3(0.0);
		for(int i=0;i<MAX_SUNS;i++){
			if(i >= uSunCount) break;
			float sElev = dot(uSunDir(i), uUp);
			float vis = smoothstep(-0.20, 0.06, sElev);
			vec3 trans = exp(-(TAU_R + TAU_M) * airMass(max(sElev, 0.0)));
			cloudLit += uSunColor(i) * uSunInt(i) * vis * trans;
		}
		cloudLit = cloudLit * mix(0.55, 0.16, uStorm) + vec3(0.02,0.025,0.04);
		col = mix(col, cloudLit, cov * clamp(uClouds, 0.0, 0.95) * 0.9);
	}

	if(groundMix > 0.0) col = mix(col, ground, groundMix);

	// Stay linear HDR: postfx applies the only tone curve. Exposure follows how
	// much sunlight is actually reaching the observer and lags behind it, so the
	// view adapts the way an eye does instead of blowing out the moment a sun
	// clears the horizon.
	imageStore(outHdr, px, vec4(col * uExposure, 1.0));
}
