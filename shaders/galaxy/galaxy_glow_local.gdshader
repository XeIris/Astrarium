// The Milky Way's glow (galaxy_glow.gdshader) with the measured dust around the Sun.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, depth_test_disabled, cull_front;

#define LOCAL_DUST
#include "res://shaders/galaxy/galaxy_glow.gdshaderinc"
