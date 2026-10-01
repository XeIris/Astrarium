class_name ElHost
extends Container

# Holds El content that a sim module still builds, inside a native panel: lays its
# El children out top to bottom at its own width and reports their height.

var _h := 0.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func touch() -> void:
	_relayout()

func _get_minimum_size() -> Vector2:
	return Vector2(0, _h)

func _process(_dt: float) -> void:
	for c in get_children():
		if c is El and (c as El)._ldirty:
			_relayout()
			return

func _relayout() -> void:
	var y := 0.0
	for c in get_children():
		if not (c is El) or not (c as El).visible: continue
		var e := c as El
		y += e.gf("mt")
		var h := e.layout(size.x)
		e.position = Vector2(e.gf("ml"), y)
		y += h + e.gf("mb")
	if absf(y - _h) > 0.01:
		_h = y
		update_minimum_size()

func _notification(what: int) -> void:
	if what == NOTIFICATION_SORT_CHILDREN or what == NOTIFICATION_RESIZED:
		_relayout()
