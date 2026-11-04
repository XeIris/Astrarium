class_name SitePicker
extends Control

# The Observatory's front door: the facility filmed from the air, an arrow each side to
# move between sites, its name and numbers, and Observe. Set out like the hangar.

signal step(dir: int)
signal observe()
signal back()

const KICK := {"fs": 9.0, "ls": 3.0, "up": true, "c": HudTheme.TEXT_DIM, "fw": 500}
const NAME := {"fs": 34.0, "ls": 6.0, "up": true, "c": HudTheme.ACCENT, "lh": 1.15}
const KIND := {"fs": 12.0, "ls": 0.6, "c": HudTheme.TEXT}
const BLURB := {"fs": 11.0, "c": HudTheme.TEXT_DIM, "lh": 1.5}
const KEY := {"fs": 10.0, "c": HudTheme.TEXT_DIM}
const VAL := {"fs": 11.0, "c": HudTheme.ACCENT}

## A chevron button at the frame's edge, for the arrows.
class Arrow extends BaseButton:
	var dir := 1
	var _lit := 0.0
	func _init(d: int) -> void:
		dir = d
		custom_minimum_size = Vector2(72, 120)
		focus_mode = Control.FOCUS_ALL
		tooltip_text = "Next site (→)" if d > 0 else "Previous site (←)"
	func _process(dt: float) -> void:
		var want := 1.0 if is_hovered() or has_focus() else 0.0
		if absf(want - _lit) > 0.003:
			_lit = lerpf(_lit, want, 1.0 - exp(-dt * 14.0))
			queue_redraw()
	func _draw() -> void:
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		var s := 22.0 + 3.0 * _lit
		var col := Color(1, 1, 1, 0.55 + 0.45 * _lit)
		var pts := PackedVector2Array([c + Vector2(-dir * s * 0.5, -s), c + Vector2(dir * s * 0.5, 0.0), c + Vector2(-dir * s * 0.5, s)])
		draw_polyline(pts, col, 2.0, true)

var shade: TextureRect
var veil: ColorRect
var left: Arrow
var right: Arrow
var kicker: Label
var title: Label
var kind: Label
var blurb: Label
var facts: GridContainer
var dots: Control
var go: TitleItem
var back_b: TitleItem
var _count := 3
var _index := 0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	shade = TextureRect.new()
	var g := Gradient.new()
	g.set_color(0, Color(0, 0, 0, 0.0))
	g.set_color(1, Color(0, 0, 0, 0.82))
	g.set_offset(0, 0.42)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0, 0); gt.fill_to = Vector2(0, 1)
	shade.texture = gt
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)
	kicker = Hud.label(self, "", KICK)
	title = Hud.label(self, "", NAME)
	kind = Hud.label(self, "", KIND)
	blurb = Hud.label(self, "", BLURB, true)
	facts = GridContainer.new()
	facts.columns = 2
	facts.add_theme_constant_override("h_separation", 18)
	facts.add_theme_constant_override("v_separation", 3)
	facts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(facts)
	left = Arrow.new(-1)
	left.pressed.connect(func(): step.emit(-1))
	add_child(left)
	right = Arrow.new(1)
	right.pressed.connect(func(): step.emit(1))
	add_child(right)
	dots = Control.new()
	dots.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dots.draw.connect(_draw_dots)
	add_child(dots)
	go = TitleItem.new("Observe the sky")
	go.pressed.connect(func(): observe.emit())
	add_child(go)
	back_b = TitleItem.new("Back")
	back_b.pressed.connect(func(): back.emit())
	add_child(back_b)
	veil = ColorRect.new()
	veil.color = Color(0, 0, 0, 0)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(veil)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED: _layout()

## Fill the card for site `index` of `count`; `place` is its site's name and region.
func show_site(index: int, count: int, place: String, d: Dictionary) -> void:
	_index = index
	_count = count
	kicker.text = "Observatory · site %d of %d" % [index + 1, count]
	title.text = String(d.telescope)
	kind.text = "%s · %s" % [place, d.kind]
	(blurb as Prose).say(String(d.blurb))
	for c in facts.get_children():
		facts.remove_child(c)
		c.queue_free()
	for row: Array in d.facts:
		Hud.label(facts, String(row[0]), KEY)
		Hud.label(facts, String(row[1]), VAL)
	dots.queue_redraw()
	_layout.call_deferred()

func set_veil(a: float) -> void:
	veil.color.a = a

func _draw_dots() -> void:
	for i in _count:
		var on := i == _index
		dots.draw_circle(Vector2(6.0 + i * 18.0, 6.0), 3.0 if on else 2.0, Color(1, 1, 1, 0.95 if on else 0.4))

func _layout() -> void:
	var W := size.x
	var H := size.y
	if W <= 0.0: return
	shade.position = Vector2.ZERO
	shade.size = Vector2(W, H)
	veil.position = Vector2.ZERO
	veil.size = Vector2(W, H)
	left.position = Vector2(14.0, H * 0.42 - 60.0)
	left.size = left.custom_minimum_size
	right.size = right.custom_minimum_size
	right.position = Vector2(W - 14.0 - right.size.x, H * 0.42 - 60.0)
	var margin := roundf(clampf(W * 0.055, 28.0, 96.0))
	var col := clampf(W * 0.44, 280.0, 560.0)
	var bottom := H - roundf(clampf(H * 0.07, 20.0, 64.0))
	facts.reset_size()
	var fw := facts.get_combined_minimum_size()
	blurb.size = Vector2(col, 0.0)
	var bh := (blurb as Prose).get_combined_minimum_size().y
	# The card runs up from the bottom: numbers, then the blurb, the kind and the name.
	var y := bottom - fw.y
	facts.position = Vector2(margin, y)
	y -= bh + 12.0
	blurb.position = Vector2(margin, y)
	blurb.size = Vector2(col, bh)
	y -= 26.0
	kind.position = Vector2(margin, y)
	y -= 50.0
	title.position = Vector2(margin, y)
	y -= 20.0
	kicker.position = Vector2(margin, y)
	var fs := int(clampf(H * 0.024, 15.0, 24.0))
	go.set_font_size(fs)
	go.size = go.get_combined_minimum_size()
	back_b.set_font_size(int(fs * 0.72))
	back_b.size = back_b.get_combined_minimum_size()
	back_b.position = Vector2(W - margin - back_b.size.x, bottom - back_b.size.y)
	go.position = Vector2(W - margin - go.size.x, back_b.position.y - go.size.y - 10.0)
	dots.size = Vector2(_count * 18.0 + 4.0, 12.0)
	dots.position = Vector2((W - dots.size.x) * 0.5, H - 34.0)
