class_name TitleItem
extends BaseButton

# A title-screen choice: widely tracked text over a hairline that fades to the right.
# Hover or keyboard focus eases in a soft band behind it, brightens the text and
# draws the line further out.

const FACES := ["Avenir", "Avenir Next", "Helvetica Neue", ".AppleSystemUIFont", "sans-serif"]
const RULE := 150.0
const RULE_LIT := 230.0

var text := ""
var font_size := 21
var _font: Font
## 0 at rest, 1 hovered or focused, eased.
var _lit := 0.0
var _target := 0.0

static var _shared_font: Font = null

static func face() -> Font:
	if _shared_font == null:
		var sf := SystemFont.new()
		sf.font_names = PackedStringArray(FACES)
		sf.font_weight = 300
		sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_ONE_QUARTER
		sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		sf.hinting = TextServer.HINTING_NONE
		var fv := FontVariation.new()
		fv.base_font = sf
		_shared_font = fv
	return _shared_font

func _init(label: String) -> void:
	text = label
	_font = face()
	focus_mode = Control.FOCUS_ALL
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	mouse_entered.connect(func(): _aim(1.0))
	mouse_exited.connect(func(): _aim(1.0 if has_focus() else 0.0))
	focus_entered.connect(func(): _aim(1.0))
	focus_exited.connect(func(): _aim(1.0 if is_hovered() else 0.0))
	set_process(false)

func _aim(v: float) -> void:
	_target = v
	set_process(true)

func set_font_size(px: int) -> void:
	font_size = px
	custom_minimum_size = Vector2(RULE_LIT + 40.0, ceilf(px * 2.9))
	update_minimum_size()
	queue_redraw()

func _process(dt: float) -> void:
	_lit += (_target - _lit) * (1.0 - exp(-dt * 12.0))
	if absf(_target - _lit) < 0.002:
		_lit = _target
		set_process(false)
	queue_redraw()

## Letter spacing as the reference tracks it: about a fifth of the size.
func _tracking() -> float:
	return font_size * 0.2

func _draw() -> void:
	var h := _lit
	var k := h * h * (3.0 - 2.0 * h)
	var track := _tracking()
	var baseline := size.y * 0.52
	var rule_y := size.y * 0.84

	# The band: a soft wash from the left edge, gone by the rule's lit length.
	if k > 0.0:
		var band := PackedVector2Array([Vector2(-18, 0), Vector2(RULE_LIT + 30.0, 0), Vector2(RULE_LIT + 30.0, size.y), Vector2(-18, size.y)])
		var a := 0.085 * k
		draw_polygon(band, PackedColorArray([Color(1, 1, 1, a), Color(1, 1, 1, 0), Color(1, 1, 1, 0), Color(1, 1, 1, a)]))
		draw_line(Vector2(-18, 2), Vector2(-18, size.y - 2), Color(1, 1, 1, 0.55 * k), 1.5)

	var x := 6.0 * k
	var col := Color(1, 1, 1, lerpf(0.78, 1.0, k))
	for ch in text:
		draw_string(_font, Vector2(x, baseline + font_size * 0.35), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)
		x += _font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x + track

	# The rule fades out to the right; lit, it reaches further and brighter.
	var reach := lerpf(RULE, RULE_LIT, k)
	var n := 24
	for i in n:
		var f0 := float(i) / n
		var f1 := float(i + 1) / n
		var a := lerpf(0.42, 0.85, k) * (1.0 - f0) * (1.0 - f0)
		draw_line(Vector2(f0 * reach, rule_y), Vector2(f1 * reach, rule_y), Color(1, 1, 1, a), 1.0)
