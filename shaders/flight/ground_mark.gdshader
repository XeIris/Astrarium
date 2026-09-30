// MARKS ON THE CONCRETE — the hardstand's expansion joints and the scorched
// apron, drawn as a MULTIPLY over the concrete that is already there.
// Both used to be geometry. The joints were 2 cm tubes laid along the slab at
// a height equal to their own radius, so half of each was inside the concrete
// and the depth test chose, pixel by pixel and frame by frame, which of the two
// to show: a joint read as a dotted line that crawled as the camera moved. At
// any range past a few tens of metres it was also narrower than a pixel, which
// rasterizes as dashes whatever the depth does. The apron's burnt edge was a
// screen-door dither (discard against a per-pixel hash), which reads as black
// speckle rather than as soot.
//
// A darkening is a multiply, so that is what this is: rgb is the fraction of
// the lit concrete that survives, and everything under it — the sun, the cloud
// shadow, the concrete's own detail — carries through. The joints are
// analytic lines filtered by the pixel's footprint (fwidth): a line narrower
// than a pixel is drawn wider and fainter by exactly its coverage, and once the
// grid is finer than the pixels can hold it fades to its own average instead
// of aliasing into moiré. The depth bias is decal.gdshader's, so the mark lies
// ON the concrete and never fights it.
shader_type spatial;
render_mode unshaded, blend_mul, depth_draw_never, cull_back, fog_disabled, skip_vertex_transform, shadows_disabled;

uniform int uMode = 0;                  // 0: joints, 1: scorch
uniform float uOrder = 1.0;             // decal.gdshader's bias order
// joints
uniform float uSpacing = 14.0;          // m between joints
uniform float uWidth = 0.06;            // m — a sealed joint and its stained margin
uniform float uJointDark = 0.38;        // what a joint leaves of the concrete
uniform float uExtent = 100.0;          // m — radius of the jointed field
// scorch
uniform float uScorchRadius = 18.0;
uniform float uScorchDark = 0.28;       // what the soot leaves at the centre

varying vec2 vLocal;

void vertex() {
	vLocal = VERTEX.xy;
	VERTEX = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz * (1.0 - 2.0e-4 * uOrder);
}

float hash(vec2 p) { return fract(sin(dot(p, vec2(17.23, 81.71))) * 43758.5453); }
float vnoise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}

void fragment() {
	vec2 p = vLocal;
	float keep = 1.0;
	if (uMode == 0) {
		vec2 fw = max(fwidth(p), vec2(1e-5));
		// distance to the nearest joint on each axis, m
		vec2 d = abs(fract(p / uSpacing + 0.5) - 0.5) * uSpacing;
		// box-filtered coverage of a line of width w by a pixel of footprint fw
		vec2 cov = clamp((0.5 * uWidth - d) / fw + 0.5, 0.0, 1.0) * min(vec2(1.0), uWidth / fw);
		// too fine to resolve: fade to the grid's average darkening
		vec2 fade = 1.0 - smoothstep(uSpacing * 0.08, uSpacing * 0.3, fw);
		float c = max(cov.x * fade.x, cov.y * fade.y);
		// the field stops short of the hardstand's edge
		c *= 1.0 - smoothstep(uExtent - 2.0, uExtent, length(p));
		keep = mix(1.0, uJointDark, c);
	} else {
		float r = length(p) / uScorchRadius;
		// ragged edge: burn reaches further where the blast was channelled
		float n = vnoise(p * 0.22) * 0.6 + vnoise(p * 0.9) * 0.4;
		float burn = 1.0 - smoothstep(0.35, 1.0, r + (n - 0.5) * 0.35);
		burn *= mix(0.75, 1.0, vnoise(p * 2.7));
		keep = mix(1.0, uScorchDark, clamp(burn, 0.0, 1.0));
	}
	ALBEDO = vec3(keep);
}
