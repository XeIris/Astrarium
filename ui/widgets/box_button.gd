class_name BoxButton
extends HudButton

# A button whose content is a container (a symbol over a label, an icon over a
# title and a paragraph). Button is not a container, so this holds its minimum size
# at the content's plus the kind's padding and places the content inside the
# padding. Labels added with tint() take the kind's text colour in each state, as
# children inherit a hovered button's colour.

var content: Container
## Centre the content vertically when the button is taller than it.
var center := false
var _tinted: Array[Label] = []
var _hover := false

func _init(k := "Add", c: Container = null, tip := "") -> void:
	super(k, "", tip)
	content = c if c != null else VBoxContainer.new()
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(content)
	content.minimum_size_changed.connect(_fit)
	mouse_entered.connect(func(): _hover = true; _retint())
	mouse_exited.connect(func(): _hover = false; _retint())
	_fit()

## A label whose colour follows the button's state.
func tint(l: Label) -> Label:
	_tinted.append(l)
	_retint()
	return l

func _restyle() -> void:
	super()
	_fit()
	_retint()

func _margins() -> Array:
	var sb := get_theme_stylebox("normal")
	return [sb.get_margin(SIDE_TOP), sb.get_margin(SIDE_RIGHT), sb.get_margin(SIDE_BOTTOM), sb.get_margin(SIDE_LEFT)]

func _fit() -> void:
	if content == null:
		return
	var m := _margins()
	var ms := content.get_combined_minimum_size()
	custom_minimum_size = Vector2(ms.x + m[1] + m[3], ms.y + m[0] + m[2])
	_place()

func _place() -> void:
	var m := _margins()
	var h: float = size.y - m[0] - m[2]
	var ch: float = h
	var y: float = m[0]
	if center:
		ch = minf(content.get_combined_minimum_size().y, h)
		y += roundf((h - ch) * 0.5)
	content.position = Vector2(m[3], y)
	content.size = Vector2(maxf(size.x - m[1] - m[3], 0.0), maxf(ch, 0.0))

func _retint() -> void:
	if _tinted.is_empty() or not HudTheme.KINDS.has(kind):
		return
	var on := active and (HudTheme.KINDS[kind] as Dictionary).has("on")
	var state := ("onhover" if _hover else "on") if on else ("hover" if _hover else "normal")
	var c: Color = HudTheme.kind_look(kind, state).c
	for l in _tinted:
		if not is_instance_valid(l): continue
		var st: Dictionary = (l.get_meta("st", {}) as Dictionary).duplicate()
		st.c = c
		HudTheme.apply_label(l, st)

func _notification(what: int) -> void:
	if what == NOTIFICATION_THEME_CHANGED:
		_fit()
	elif what == NOTIFICATION_RESIZED:
		_place()
