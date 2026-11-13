// A galaxy's unresolved starlight (sim/galaxy/gal_visual.gd): the luminosity density
// of its model integrated along each view ray, I = ∫ j ds / 4π, on a box drawn from
// inside (front faces culled) so it works from outside the galaxy and within it.
// Stars nearer than uRes and heavier than GalPopulation.M_RESOLVED are drawn one by
// one (galaxy_stars.gdshader); inside uRes the glow keeps only the lighter stars'
// share (uFaint), so the two add up to the same flux.
//
// Samples are uniform in u = asinh((s − s_c)/scale) about the ray's crossing of the
// plane (disc) or its closest approach to the centre (spheroid): dense where the
// light is, so a thin disc seen face-on is sampled through its layer. Dust lies in the
// disc's layer: the disc march carries its optical depth front to back, per channel
// (uExt, A_λ/A_V), and the spheroid's samples read it there.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front;

#include "res://shaders/galaxy/galaxy_glow.gdshaderinc"
