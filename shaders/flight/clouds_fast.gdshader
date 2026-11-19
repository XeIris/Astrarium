shader_type spatial;
render_mode unshaded, blend_premul_alpha, depth_draw_never, depth_test_disabled, cull_front, fog_disabled;

#define CLOUD_REDUCED
#include "res://shaders/flight/clouds_spatial.gdshaderinc"
