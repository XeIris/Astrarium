// ============================================================================
// THREE.Sprite, as the flight view's sprites used it (sim/flight/plume.js: the
// engine glow, the RCS puffs, the launch smoke).
// ----------------------------------------------------------------------------
// A unit quad facing the camera, centred on the object, scaled by the
// object's world scale and turned in the screen plane by the material's
// `rotation` — three's sprite vertex shader, line for line. SpriteMaterial's
// output is (color · texel.rgb, opacity · texel.a).
//
// Each sprite in the web build had its OWN material (a colour, an opacity and
// a rotation per puff), so here those three are INSTANCE uniforms: one shader,
// one material, and every MeshInstance3D carries its own values. Each sprite
// stays its own object for the same reason it was one in three — the
// transparent queue is sorted back-to-front per OBJECT, and a cloud of
// overlapping puffs needs that order.
//
// The textures were canvases (NoColorSpace — sampled as LINEAR, PORT_GUIDE §5),
// so the two gradients are evaluated analytically and the smoke puff, which
// is value noise, is baked into an ImageTexture with no colour conversion.
// ============================================================================
instance uniform vec3 tint = vec3(1.0);
instance uniform float opacity = 0.0;
instance uniform float rot = 0.0;
// 0: the engine glow gradient, 1: the RCS puff gradient, 2: the smoke texture
uniform int uKind = 0;
uniform sampler2D uMap : filter_linear_mipmap, repeat_disable;

varying vec2 vQ;

void vertex() {
	vQ = VERTEX.xy;
	vec2 sc = vec2(length(MODEL_MATRIX[0].xyz), length(MODEL_MATRIX[1].xyz));
	vec2 al = VERTEX.xy * sc;
	vec2 r = vec2(cos(rot) * al.x - sin(rot) * al.y, sin(rot) * al.x + cos(rot) * al.y);
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
