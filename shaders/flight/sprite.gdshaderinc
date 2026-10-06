// Camera-facing sprites (engine glow, RCS puffs, launch smoke): a unit quad centred on
// the instance, scaled by its world scale and turned in the screen plane by its
// rotation. Output is (color · texel.rgb, opacity · texel.a). A sprite set is a
// MultiMesh (Plume.Sprites): instance colour is (tint, opacity), custom.x the rotation,
// drawn in instance order, so Plume sorts the blended puffs back to front itself. A
// lone sprite (the engine glow) is a MeshInstance3D with the instance uniforms below,
// so that Godot can merge every glow into one draw; outside a MultiMesh COLOR is 1 and
// INSTANCE_CUSTOM 0, and inside one the uniforms keep their identity defaults.
// Gradients are analytic and linear; the smoke puff is value noise baked into an
// ImageTexture without conversion.
instance uniform vec3 tint = vec3(1.0);
instance uniform float opacity = 1.0;
instance uniform float rot = 0.0;
// 0: the engine glow gradient, 1: the RCS puff gradient, 2: the smoke texture
uniform int uKind = 0;
uniform sampler2D uMap : filter_linear_mipmap, repeat_disable;

varying vec2 vQ;
varying flat vec3 v_tint;
varying flat float v_opacity;

void vertex() {
	vQ = VERTEX.xy;
	v_tint = tint * COLOR.rgb;
	v_opacity = opacity * COLOR.a;
	float a = rot + INSTANCE_CUSTOM.x;
	vec2 sc = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec2 al = VERTEX.xy * sc;
	vec2 r = vec2(cos(a) * al.x - sin(a) * al.y, sin(a) * al.x + cos(a) * al.y);
	vec4 centre = MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0);
	POSITION = PROJECTION_MATRIX * (centre + vec4(r, 0.0, 0.0));
}

// A canvas radial gradient, interpolated in straight RGBA; colour stops 0..255.
vec4 grad(float r, float p0, vec4 c0, float p1, vec4 c1) {
	return mix(c0, c1, clamp((r - p0) / max(p1 - p0, 1e-6), 0.0, 1.0)) / vec4(255.0, 255.0, 255.0, 1.0);
}

vec4 sprite_texel() {
	// quad (−½…½) → texture uv, with the canvas's top row at the top of the quad
	vec2 uv = vec2(vQ.x + 0.5, 0.5 - vQ.y);
	float r = length(vQ) * 2.0;     // the gradients run from the centre to r = s/2
	if (uKind == 0) {
		if (r >= 1.0) return vec4(0.0);
		if (r < 0.12) return grad(r, 0.00, vec4(255.0, 255.0, 255.0, 1.0), 0.12, vec4(255.0, 246.0, 226.0, 0.85));
		if (r < 0.35) return grad(r, 0.12, vec4(255.0, 246.0, 226.0, 0.85), 0.35, vec4(255.0, 190.0, 120.0, 0.30));
		if (r < 0.70) return grad(r, 0.35, vec4(255.0, 190.0, 120.0, 0.30), 0.70, vec4(255.0, 140.0, 60.0, 0.07));
		return grad(r, 0.70, vec4(255.0, 140.0, 60.0, 0.07), 1.00, vec4(255.0, 120.0, 40.0, 0.0));
	} else if (uKind == 1) {
		if (r >= 1.0) return vec4(0.0);
		if (r < 0.4) return grad(r, 0.0, vec4(255.0, 255.0, 255.0, 0.9), 0.4, vec4(200.0, 225.0, 255.0, 0.35));
		return grad(r, 0.4, vec4(200.0, 225.0, 255.0, 0.35), 1.0, vec4(160.0, 200.0, 255.0, 0.0));
	}
	return texture(uMap, uv);
}
