class_name CompositionPie
extends HudCanvas

# The composition as a pie, one control for the Foundry and the live editor. A pie is linear,
# so a slice can be thinner than a pixel while the gas still matters (Earth's CO₂ is 0.04%).
# Three things keep it honest about that: every gas has a legend row with its value and a bar on
# a log scale, a gas too thin to draw leaves a tick on the rim, and the inner ring shows the gases
# under 1% among themselves. Water that follows temperature is hatched; a gas the seed drew is
# hollow in the legend. Height follows the row count, so the left column can measure it.

const OUTER := 50.0
const INNER := 31.0
const TRACE_OUT := 26.0
const TRACE_IN := 20.0
const ROW_H := 15.0
const LEGEND_X := 2.0 * OUTER + 14.0
const STRIP_H := 8.0
const KEY_H := 13.0
# A slice under this many degrees is thinner than a pixel on the rim at OUTER.
const THIN_DEG := 180.0 / (PI * OUTER)
const TRACE_SHARE := 0.01
# The log bars run from a part in a billion of a bar to the model's 200 bar.
const BAR_LO := -9.0
const BAR_HI := 2.31

var rows: Array = []
var surface := {}
## Per row: its share of the air, degrees of pie, and whether it is too thin to draw.
var shares: Array = []
var total_bar := 0.0

func _init() -> void:
	super(0.0, 120.0)
	mouse_filter = Control.MOUSE_FILTER_PASS

## `rows`: [{key, label, color, bar, source}] with source stated, drawn or follows.
func show_composition(new_rows: Array, new_surface: Dictionary) -> void:
	if new_rows == rows and new_surface == surface: return
	rows = new_rows
	surface = new_surface
	total_bar = 0.0
	for r in rows: total_bar += float(r.bar)
	shares.clear()
	for r in rows:
		var share: float = float(r.bar) / total_bar if total_bar > 0.0 else 0.0
		shares.append({ "share": share, "deg": share * 360.0, "thin": share * 360.0 < THIN_DEG })
	fixed_h = maxf(2.0 * OUTER + 6.0, ROW_H * rows.size() + KEY_H) + STRIP_H + 18.0
	update_minimum_size()
	queue_redraw()

## A share of the air as it reads best.
static func format_share(s: float) -> String:
	if s >= 0.0995: return "%s %%" % U.fixed(s * 100.0, 0)
	if s >= 0.001: return "%s %%" % U.fixed(s * 100.0, 1 if s >= 0.01 else 2)
	if s >= 1e-6: return "%s ppm" % U.fixed(s * 1e6, 0 if s >= 1e-5 else 1)
	return "%s ppb" % U.fixed(s * 1e9, 1)

static func _source_text(source: String) -> String:
	match source:
		"stated": return "stated"
		"drawn": return "drawn from the seed"
		_: return "follows temperature, through Clausius–Clapeyron"

func _get_tooltip(at: Vector2) -> String:
	if at.x < LEGEND_X:
		return "A pie is linear: its outer ring shows each gas's share of the air, a tick on the rim marks a gas too thin to draw, and the inner ring shows the gases under 1% among themselves."
	var i := int(at.y / ROW_H)
	if i < 0 or i >= rows.size(): return ""
	var r: Dictionary = rows[i]
	return "%s: %s, %s of the air, %s." % [r.label, Hud.format_bar(float(r.bar)), format_share(shares[i].share), _source_text(r.source)]

func _arc(center: Vector2, a0: float, a1: float, r0: float, r1: float, col: Color) -> void:
	var n := maxi(2, int(ceil((a1 - a0) / deg_to_rad(4.0))))
	for i in n:
		var u0: float = lerpf(a0, a1, float(i) / n)
		var u1: float = lerpf(a0, a1, float(i + 1) / n)
		draw_colored_polygon(PackedVector2Array([
			center + Vector2.from_angle(u0) * r0, center + Vector2.from_angle(u0) * r1,
			center + Vector2.from_angle(u1) * r1, center + Vector2.from_angle(u1) * r0]), col)

# Water is hatched: dim, with radial strokes at a fixed angular pitch.
func _hatch(center: Vector2, a0: float, a1: float, r0: float, r1: float, col: Color) -> void:
	_arc(center, a0, a1, r0, r1, Color(col, 0.28))
	var a := a0 + deg_to_rad(3.0)
	while a < a1:
		draw_line(center + Vector2.from_angle(a) * r0, center + Vector2.from_angle(a) * r1, col, 1.0, true)
		a += deg_to_rad(6.0)

func _draw_content() -> void:
	var f := HudTheme.font("mono")
	var center := Vector2(OUTER + 1.0, OUTER + 3.0)
	if rows.is_empty():
		draw_arc(center, OUTER - 0.5, 0.0, TAU, 64, HudTheme.BORDER_STRONG, 1.0, true)
		draw_arc(center, INNER, 0.0, TAU, 64, HudTheme.BORDER, 1.0, true)
		_center_text(f, center, "no air", "")
		draw_string(f, Vector2(LEGEND_X, 14), "No gases: an airless world.", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, HudTheme.TEXT_DIM)
	else:
		_draw_rings(f, center)
		_draw_legend(f)
	_draw_surface(f)

func _center_text(f: Font, center: Vector2, line: String, sub: String) -> void:
	var w := f.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
	draw_string(f, center + Vector2(-w * 0.5, 2.0 if sub == "" else -1.0), line, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, HudTheme.ACCENT)
	if sub != "":
		var ws := f.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
		draw_string(f, center + Vector2(-ws * 0.5, 9.0), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, HudTheme.TEXT_DIM)

func _draw_rings(f: Font, center: Vector2) -> void:
	var a := -PI * 0.5
	var trace_total := 0.0
	for i in rows.size():
		if float(shares[i].share) < TRACE_SHARE: trace_total += float(rows[i].bar)
	for i in rows.size():
		var r: Dictionary = rows[i]
		var col := HudTheme.hexc(int(r.color))
		var sweep := deg_to_rad(float(shares[i].deg))
		if shares[i].thin:
			# Too thin for the ring: a tick that stands off the rim, where the slice would be.
			draw_line(center + Vector2.from_angle(a) * (OUTER - 7.0), center + Vector2.from_angle(a) * (OUTER + 1.0), col, 1.0, true)
		elif r.source == "follows":
			_hatch(center, a, a + sweep, INNER, OUTER, col)
		else:
			_arc(center, a, a + sweep, INNER, OUTER, col)
		a += sweep
	if trace_total > 0.0:
		var b := -PI * 0.5
		for i in rows.size():
			if float(shares[i].share) >= TRACE_SHARE: continue
			var sweep_b := TAU * float(rows[i].bar) / trace_total
			var col_b := HudTheme.hexc(int(rows[i].color))
			if rows[i].source == "follows": _hatch(center, b, b + sweep_b, TRACE_IN, TRACE_OUT, col_b)
			else: _arc(center, b, b + sweep_b, TRACE_IN, TRACE_OUT, col_b)
			b += sweep_b
	else:
		_center_text(f, center, Hud.format_bar(total_bar), "of air")
	if trace_total > 0.0:
		var w := f.get_string_size(Hud.format_bar(total_bar), HORIZONTAL_ALIGNMENT_LEFT, -1, 8).x
		draw_string(f, center + Vector2(-w * 0.5, 3.0), Hud.format_bar(total_bar), HORIZONTAL_ALIGNMENT_LEFT, -1, 8, HudTheme.ACCENT)

func _draw_legend(f: Font) -> void:
	var width := size.x - LEGEND_X
	for i in rows.size():
		var r: Dictionary = rows[i]
		var y := ROW_H * i
		var col := HudTheme.hexc(int(r.color))
		var sw := Rect2(LEGEND_X, y + 3.0, 8.0, 8.0)
		match r.source:
			"stated": draw_rect(sw, col)
			"drawn": draw_rect(sw.grow(-0.5), col, false, 1.0)
			_:
				draw_rect(sw, Color(col, 0.28))
				for k in 3: draw_line(sw.position + Vector2(1.0 + 3.0 * k, 8.0), sw.position + Vector2(3.0 + 3.0 * k, 0.0), col, 1.0, true)
		draw_string(f, Vector2(LEGEND_X + 12.0, y + 10.0), str(r.label), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, HudTheme.TEXT)
		var value := "%s · %s" % [Hud.format_bar(float(r.bar)), format_share(shares[i].share)]
		draw_string(f, Vector2(LEGEND_X + 36.0, y + 10.0), value, HORIZONTAL_ALIGNMENT_RIGHT, width - 36.0, 9, HudTheme.ACCENT)
		# The same pressure on a log scale, so nine decades share a column.
		var k := clampf((U.log10(maxf(float(r.bar), 1e-30)) - BAR_LO) / (BAR_HI - BAR_LO), 0.0, 1.0)
		var bar_y := y + 13.0
		draw_line(Vector2(LEGEND_X + 12.0, bar_y), Vector2(LEGEND_X + width, bar_y), HudTheme.BORDER, 1.0)
		draw_line(Vector2(LEGEND_X + 12.0, bar_y), Vector2(LEGEND_X + 12.0 + (width - 12.0) * k, bar_y), Color(col, 0.75), 1.0)
	var key_y := ROW_H * rows.size() + 9.0
	draw_string(f, Vector2(LEGEND_X, key_y), "■ stated  □ drawn  ▨ follows T", HORIZONTAL_ALIGNMENT_LEFT, width, 8, HudTheme.TEXT_DIM)

func _draw_surface(f: Font) -> void:
	if surface.is_empty(): return
	var y := fixed_h - STRIP_H - 12.0
	var x := 0.0
	var w := size.x
	var parts := [["land", 0x8a7a62], ["sea", 0x2a6fb0], ["ice", 0xd8e6f2]]
	var text := PackedStringArray()
	for part in parts:
		var s := float(surface.get(part[0], 0.0))
		if s <= 0.0: continue
		var seg := s * w
		draw_rect(Rect2(x, y, maxf(seg, 1.0), STRIP_H), HudTheme.hexc(int(part[1])))
		x += seg
		text.append("%s %s" % [part[0], "%s %%" % U.fixed(s * 100.0, 0)])
	draw_string(f, Vector2(0.0, y + STRIP_H + 11.0), " · ".join(text), HORIZONTAL_ALIGNMENT_LEFT, w, 9, HudTheme.TEXT_DIM)
