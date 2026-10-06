// THE BACKGROUND: the sky at infinity, lensed or not (colour pass). One sky shader,
// drawn behind all opaque geometry, with a branch on a uniform:
//   u_lens = false  the backdrop: d = EYEDIR, aberrated for the observer's boost,
//                   derivatives of the aberrated direction
//   u_lens = true   the resolve: d = EYEDIR + the marched deflection, plus the
//                   disc emission the marcher accumulated; never aberrated (D = 1)
shader_type sky;

#include "res://shaders/sky/sky.gdshaderinc"

uniform bool u_lens = false;
// From render/lens_pass.gd's compute marcher, at lens scale, this frame:
//   t_march0  disc emission (rgb), transmittance (a)
//   t_march1  outgoing direction as a delta from the undeflected ray (rgb),
//             log of the disc's luminance-weighted mean temperature (a)
uniform sampler2D t_march0 : filter_linear, repeat_disable;
uniform sampler2D t_march1 : filter_linear, repeat_disable;

void sky() {
	if (AT_CUBEMAP_PASS) {
		// Nothing samples the radiance map (no material in this world is lit
		// by the environment), so it is never worth a sky evaluation.
		COLOR = vec3(0.0);
	} else if (!u_lens) {
		// Aberrate first, then differentiate, so the forward compression of solid angle is
		// measured by the same Jacobian as lensing. D is explicit (sky_doppler).
		vec3 d = normalize(EYEDIR);
		vec3 rd = sky_aberrate(d);
		float D = sky_doppler(d);
		COLOR = skyRadianceD(rd, dFdx(rd), dFdy(rd), D) * sky_beaming(D);
	} else {
		vec4 m0 = texture(t_march0, SCREEN_UV);   // disc rgb, transmittance
		vec4 m1 = texture(t_march1, SCREEN_UV);   // direction delta, log mean T
		vec3 color = m0.rgb;
		float tr = m0.a;
		// The undeflected ray is exact at full resolution; adding back the
		// interpolated delta reconstructs the outgoing direction.
		vec3 d = normalize(normalize(EYEDIR) + m1.xyz);
		// Taken OUTSIDE the branch on purpose: derivatives are only defined
		// under uniform control flow, and transmittance goes to zero pixel to
		// pixel along the whole edge of the shadow — precisely where the ring is.
		vec3 ddx = dFdx(d), ddy = dFdy(d);
		vec3 skyCol = vec3(0.0);
		if (tr > 0.001) skyCol = tr * skyRadiance(d, ddx, ddy);
		COLOR = color + skyCol;
	}
}
