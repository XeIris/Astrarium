class_name SurfaceShadow
extends RefCounted

# How much of the Sun a point at a site sees past the site's own ground: the CPU half of
# shaders/surface/ground.gdshader's march, step for step, so a check can hold the frame to it.
# docs/physics/surface.md#the-ground-close-up.

## Steps along the ray, the first one's length, m, and each one's growth: 0.5 m to about 40 km.
const STEPS := 28
const FIRST := 0.5
const GROWTH := 1.5
## Clearance, m, plus a fraction of the distance: the ground under a point is its own triangle, so only
## rounding is left to stand off.
const BIAS := 0.05
const BIAS_K := 0.002

## The Sun's visible fraction, 0..1, at (e, n) m east and north of the site's origin and height y in its
## frame, toward `sun` (unit, site frame: x west, y up, z north) of angular radius `ang` rad.
static func visibility(grids: Array, e: float, n: float, y: float, sun: Vector3, ang: float, R: float, top: float) -> float:
	if sun.y <= -ang: return 0.0
	var horiz := Vector2(-sun.x, sun.z)
	var vis := 1.0
	var t := FIRST
	for k in STEPS:
		var pe := e + horiz.x * t
		var pn := n + horiz.y * t
		var ray := y + sun.y * t
		if ray > top: break
		var ground := ground_y(grids, pe, pn, R)
		if is_nan(ground): break
		var rise := (ground + BIAS + BIAS_K * t - ray) / t
		vis = minf(vis, clampf(0.5 - rise / (2.0 * ang), 0.0, 1.0))
		if vis <= 0.0: return 0.0
		t *= GROWTH
	return vis

## The ground's height in the site's frame at (e, n): the near grid's triangles inside it, else the far
## grid's, with the curvature drop. NAN off the far grid.
static func ground_y(grids: Array, e: float, n: float, R: float) -> float:
	for g: Dictionary in grids:
		var half: float = g.half
		if absf(e) >= half or absf(n) >= half: continue
		var cells: int = int(g.n) - 1
		var step := 2.0 * half / float(cells)
		var fx := (e + half) / step
		var fy := (n + half) / step
		var i := mini(int(fx), cells - 1)
		var j := mini(int(fy), cells - 1)
		var tx := fx - i
		var ty := fy - j
		var h: PackedFloat32Array = g.h
		var w: int = g.n
		# The far grid as it is drawn, tucked under the near one: its cells across that edge slope down to it.
		var near_half := 0.0 if is_same(g, grids[0]) else float(grids[0].half)
		var at := func(a: int, b: int) -> float:
			var tuck := absf(-half + a * step) < near_half and absf(-half + b * step) < near_half
			return h[b * w + a] - (SiteScene.TUCK if tuck else 0.0)
		var h00: float = at.call(i, j)
		var h10: float = at.call(i + 1, j)
		var h01: float = at.call(i, j + 1)
		var y: float
		if tx + ty <= 1.0: y = h00 + tx * (h10 - h00) + ty * (h01 - h00)
		else:
			var h11: float = at.call(i + 1, j + 1)
			y = h11 + (1.0 - tx) * (h01 - h11) + (1.0 - ty) * (h10 - h11)
		return y - (e * e + n * n) / (2.0 * R)
	return NAN
