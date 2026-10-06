class_name HudRow
extends Container

# A row: children at their minimum width, the ones that expand sharing what is left
# (by stretch ratio), each aligned on the cross axis by its size flags. Like
# HBoxContainer, except that wrapping prose is placed with its overhang
# (ui/widgets/prose.gd) in the same pass; widened after the box's own sort, its
# height would change and the box sort again, every time.

var sep := 0.0

func _init(separation := 0.0) -> void:
	sep = separation
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _kids() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if c is Control and (c as Control).visible and not (c as Control).top_level:
			out.append(c)
	return out

func _get_minimum_size() -> Vector2:
	var ks := _kids()
	var w := sep * maxf(ks.size() - 1, 0)
	var h := 0.0
	for k in ks:
		var ms := k.get_combined_minimum_size()
		w += ms.x
		h = maxf(h, ms.y)
	return Vector2(w, h)

func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var ks := _kids()
	var free := size.x - sep * maxf(ks.size() - 1, 0)
	var ratio := 0.0
	for k in ks:
		free -= k.get_combined_minimum_size().x
		if k.size_flags_horizontal & Control.SIZE_EXPAND:
			ratio += k.size_flags_stretch_ratio
	free = maxf(free, 0.0)
	var x := 0.0
	for k in ks:
		var w := k.get_combined_minimum_size().x
		if k.size_flags_horizontal & Control.SIZE_EXPAND and ratio > 0.0:
			w += free * k.size_flags_stretch_ratio / ratio
		var h := k.get_combined_minimum_size().y
		var y := 0.0
		var v := k.size_flags_vertical
		if v & Control.SIZE_FILL:
			h = size.y
		elif v & Control.SIZE_SHRINK_CENTER:
			y = roundf((size.y - h) * 0.5)
		elif v & Control.SIZE_SHRINK_END:
			y = size.y - h
		fit_child_in_rect(k, Rect2(x, y, w + Prose.overhang(k), h))
		x += w + sep
