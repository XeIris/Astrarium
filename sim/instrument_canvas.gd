class_name Canvas2D
extends RefCounted

# ============================================================================
# THE INSTRUMENTS' CANVAS — the handful of CanvasRenderingContext2D calls the
# light curve, the strain chart and the HR diagram make, as static helpers over
# a Control's draw_* API.
# ----------------------------------------------------------------------------
# The web instruments drew into a <canvas> whose BACKING size was fixed (340 ×
# 210, or 340 × 260 for the HR diagram) and which CSS then scaled to the width
# of the card's media column (`width: 100%; height: auto`, max 340 px). Every
# coordinate in those files is therefore in backing pixels. `begin()` sets the
# same scale on the Control (its laid-out width over the backing width), so the
# arithmetic ports unchanged and the picture is the web one, resampled the same
# way — only sharper, since Godot scales the vectors rather than a bitmap.
#
# Canvas conventions kept: strokeRect(x+0.5 …) is a 1 px line centred on the
# half pixel; fillText's y is the alphabetic BASELINE; textAlign right/center
# move the anchor. The canvas font was `10px ui-monospace, monospace`, which
# Chrome on the Mac resolves to the same Menlo as the HUD's mono stack.
# ============================================================================

static func begin(ci: CanvasItem, backing_w: float) -> void:
	var s := 1.0
	if ci is Control and backing_w > 0.0:
		s = (ci as Control).size.x / backing_w
	ci.set_meta("c2d_scale", s)
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2(s, s))

static func end(ci: CanvasItem) -> void:
	ci.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

static func _scale(ci: CanvasItem) -> float:
	return float(ci.get_meta("c2d_scale", 1.0))

static func font() -> Font:
	return HudTheme.font("mono")

static func text_width(text: String, size: float) -> float:
	return HudTheme.text_w(font(), text, size, 0.0)

static func stroke_rect(ci: CanvasItem, x: float, y: float, w: float, h: float, col: Color, lw: float = 1.0) -> void:
	ci.draw_rect(Rect2(x, y, w, h), col, false, lw)

static func fill_rect(ci: CanvasItem, x: float, y: float, w: float, h: float, col: Color) -> void:
	ci.draw_rect(Rect2(x, y, w, h), col, true)

## ctx.stroke() of a moveTo/lineTo path, optionally dashed (setLineDash).
static func stroke_path(ci: CanvasItem, pts: PackedVector2Array, col: Color, lw: float, dash: Array = []) -> void:
	if pts.size() < 2:
		return
	if dash.is_empty():
		ci.draw_polyline(pts, col, lw, true)
		return
	# The dash pattern runs continuously along the whole path, as canvas does.
	var on := true
	var di := 0
	var left: float = dash[0]
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		var pos := 0.0
		while pos < seg - 1e-6:
			var step := minf(left, seg - pos)
			if on:
				ci.draw_line(a.lerp(b, pos / seg), a.lerp(b, (pos + step) / seg), col, lw, true)
			pos += step
			left -= step
			if left <= 1e-6:
				on = not on
				di = (di + 1) % dash.size()
				left = dash[di]

static func line(ci: CanvasItem, x0: float, y0: float, x1: float, y1: float, col: Color, lw: float = 1.0) -> void:
	ci.draw_line(Vector2(x0, y0), Vector2(x1, y1), col, lw, true)

static func fill_circle(ci: CanvasItem, x: float, y: float, r: float, col: Color) -> void:
	ci.draw_circle(Vector2(x, y), r, col, true, -1.0, true)

static func stroke_circle(ci: CanvasItem, x: float, y: float, r: float, col: Color, lw: float = 1.0) -> void:
	ci.draw_arc(Vector2(x, y), r, 0.0, TAU, 48, col, lw, true)

## fillText at an alphabetic baseline; align "left" | "right" | "center".
static func fill_text(ci: CanvasItem, text: String, x: float, y: float, size: float, col: Color, align := "left") -> void:
	var f := font()
	var w := text_width(text, size)
	if align == "right": x -= w
	elif align == "center": x -= w * 0.5
	# Rasterised at the size it will be SEEN at, then scaled back into the
	# backing frame, so a 9 px label in a 0.95× canvas is not a blurred 9 px one.
	var s := _scale(ci)
	var px := size * s
	var isz := maxi(int(roundf(px)), 1)
	var k := px / isz            # residual scale, ≈ 1
	var base_t := Transform2D(0.0, Vector2(s, s), 0.0, Vector2.ZERO)
	var local := Transform2D(0.0, Vector2(k / s, k / s), 0.0, Vector2(x, y))
	ci.draw_set_transform_matrix(base_t * local)
	var cx := 0.0
	for i in text.length():
		ci.draw_char(f, Vector2(cx, 0.0), text[i], isz, col)
		cx += HudTheme.adv_em(f, text.unicode_at(i)) * isz
	ci.draw_set_transform_matrix(base_t)

## fillText under translate(x, y) · rotate(angle), centred (the HR y label).
static func fill_text_rotated(ci: CanvasItem, text: String, x: float, y: float, angle: float, size: float, col: Color) -> void:
	var s := _scale(ci)
	var base_t := Transform2D(0.0, Vector2(s, s), 0.0, Vector2.ZERO)
	ci.draw_set_transform_matrix(base_t * Transform2D(angle, Vector2(x, y)))
	var f := font()
	var w := text_width(text, size)
	var isz := maxi(int(roundf(size * s)), 1)
	var k := size * s / isz / s
	ci.draw_set_transform_matrix(base_t * Transform2D(angle, Vector2(x, y)) * Transform2D(0.0, Vector2(k, k), 0.0, Vector2(-w * 0.5, 0.0)))
	var cx := 0.0
	for i in text.length():
		ci.draw_char(f, Vector2(cx, 0.0), text[i], isz, col)
		cx += HudTheme.adv_em(f, text.unicode_at(i)) * isz
	ci.draw_set_transform_matrix(base_t)
