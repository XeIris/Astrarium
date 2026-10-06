// THE NAVBALL'S HEMISPHERES: sky over the ball, then the horizon ellipse (semi-axes
// R·|n·z| across, R along, rotated by `ang`) even-odd with a half-plane in ground
// colour, i.e. their XOR, per pixel, antialiased over one pixel. CSS sRGB colours
// straight into the sRGB canvas.
shader_type canvas_item;

uniform vec2 uCentre = vec2(94.0);
uniform float uR = 82.72;
uniform float uAng = 0.0;
uniform float uA = 82.72;        // R·|n.z|
uniform float uLeft = 1.0;       // 1: the rectangle is x ∈ [−1.2R, 0]; 0: x ∈ [0, 1.2R]
uniform vec2 uSize = vec2(188.0);
uniform vec4 uSky = vec4(0.1647, 0.302, 0.4706, 1.0);
uniform vec4 uGround = vec4(0.4196, 0.3255, 0.2039, 1.0);

void fragment() {
	vec2 p = UV * uSize;
	vec2 d = p - uCentre;
	float inBall = clamp(uR - length(d) + 0.5, 0.0, 1.0);
	if (inBall <= 0.0) discard;
	// into the rotated frame: the inverse of the canvas's rotate(ang)
	float c = cos(uAng), s = sin(uAng);
	vec2 q = vec2(c * d.x + s * d.y, -s * d.x + c * d.y);
	// inside the ellipse, as a signed distance in pixels (first-order)
	float a = max(uA, 1e-3);
	vec2 k = q / vec2(a, uR);
	float f = dot(k, k) - 1.0;
	vec2 grad = 2.0 * q / vec2(a * a, uR * uR);
	float sd = f / max(length(grad), 1e-6);
	float inE = clamp(0.5 - sd, 0.0, 1.0);
	// inside the half-plane rectangle
	float x0 = uLeft > 0.5 ? -1.2 * uR : 0.0;
	float x1 = uLeft > 0.5 ? 0.0 : 1.2 * uR;
	float inR = clamp(q.x - x0 + 0.5, 0.0, 1.0) * clamp(x1 - q.x + 0.5, 0.0, 1.0);
	float ground = inE + inR - 2.0 * inE * inR;     // even-odd: the XOR
	vec4 col = mix(uSky, uGround, ground);
	COLOR = vec4(col.rgb, inBall);
}
