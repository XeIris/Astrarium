class_name Prose
extends Label

# A wrapping label that breaks lines where the design does. There a line's
# trailing space hangs past the edge; Godot's wrapping counts it, and would break a
# word early. So a HudStack places left-aligned prose one space (`hang`) wider than
# its column, and say() ends the text with a space, so every line, the last
# included, carries exactly one counted space: a line fits when its visible text
# fits the column.

var hang := 0.0
var _raw := ""

func say(t: String) -> void:
	_raw = t
	var full := t + " " if hang > 0.0 else t
	if text != full:
		text = full

## The text without the space that makes it wrap like the design.
func said() -> String:
	return _raw

## The width to add when placing `c` (0 unless it is left-aligned prose).
static func overhang(c: Control) -> float:
	if c is Prose:
		var p := c as Prose
		return p.hang if p.horizontal_alignment == HORIZONTAL_ALIGNMENT_LEFT else 0.0
	if c is Rich:
		return (c as Rich).hang
	return 0.0

class Rich extends RichTextLabel:
	var hang := 0.0
	var _raw := ""

	func say(bbcode: String) -> void:
		_raw = bbcode
		var full := bbcode + " " if hang > 0.0 else bbcode
		if text != full:
			text = full

	func said() -> String:
		return _raw
