class_name HudStack
extends Container

# A column whose children are spaced by their own margins (metas "mt" / "mb", px).
# Adjacent margins collapse to the larger, and a stack with `collapse` passes its
# first child's top and last child's bottom margin outward, so a section's last row
# and the next heading are 20 px apart, not 30. Children fill the width unless their
# horizontal size flags say shrink; meta "maxw" caps a child's width. Prose gets
# its overhang (ui/widgets/prose.gd).

var collapse := true

func _init(collapse_through := true) -> void:
	collapse = collapse_through
	mouse_filter = Control.MOUSE_FILTER_IGNORE

## Set a child's margins; returns it, for chaining at construction.
static func m(c: Control, mt := 0.0, mb := 0.0) -> Control:
	c.set_meta("mt", mt)
	c.set_meta("mb", mb)
	return c

func _kids() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if c is Control and (c as Control).visible and not (c as Control).top_level:
			out.append(c)
	return out

static func _collapse(a: float, b: float) -> float:
	return maxf(maxf(a, 0.0), maxf(b, 0.0)) + minf(minf(a, 0.0), minf(b, 0.0))

static func top_margin(c: Control) -> float:
	var m0 := float(c.get_meta("mt", 0.0))
	if c is HudStack and (c as HudStack).collapse:
		var ks := (c as HudStack)._kids()
		if not ks.is_empty(): m0 = _collapse(m0, top_margin(ks[0]))
	return m0

static func bottom_margin(c: Control) -> float:
	var m0 := float(c.get_meta("mb", 0.0))
	if c is HudStack and (c as HudStack).collapse:
		var ks := (c as HudStack)._kids()
		if not ks.is_empty(): m0 = _collapse(m0, bottom_margin(ks[-1]))
	return m0

## [child, y, height] for every visible child, and the total height.
func _plan() -> Array:
	var ks := _kids()
	var rows: Array = []
	var y := 0.0
	var pend := 0.0
	for i in ks.size():
		var k := ks[i]
		var tm := top_margin(k)
		if i == 0:
			y += 0.0 if collapse else tm
		else:
			y += _collapse(pend, tm)
		var h := k.get_combined_minimum_size().y
		rows.append([k, y, h])
		y += h
		pend = bottom_margin(k)
	if not collapse and not ks.is_empty():
		y += pend
	return [rows, y]

func _get_minimum_size() -> Vector2:
	var w := 0.0
	for k in _kids():
		w = maxf(w, k.get_combined_minimum_size().x)
	return Vector2(w, _plan()[1])

func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	for r in _plan()[0]:
		var k: Control = r[0]
		var ms := k.get_combined_minimum_size()
		var w := size.x
		if k.has_meta("maxw"):
			w = minf(w, float(k.get_meta("maxw")))
		var x := 0.0
		var flags := k.size_flags_horizontal
		if not (flags & Control.SIZE_FILL):
			w = minf(ms.x, size.x)
			if flags & Control.SIZE_SHRINK_CENTER: x = (size.x - w) * 0.5
			elif flags & Control.SIZE_SHRINK_END: x = size.x - w
		fit_child_in_rect(k, Rect2(x, r[1], maxf(w, ms.x) + Prose.overhang(k), r[2]))
