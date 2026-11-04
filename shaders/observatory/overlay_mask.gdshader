// Puts the sky overlay behind what is opaque in the flight pass: only opaque geometry
// has alpha 1 there (ConstellationOverlay.COVER_MAX).
shader_type canvas_item;

uniform sampler2D uLocal : filter_linear, repeat_disable;

void fragment() {
	COLOR.a *= 1.0 - smoothstep(0.992, 1.0, texture(uLocal, SCREEN_UV).a);
}
