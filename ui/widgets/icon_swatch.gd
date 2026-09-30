class_name IconSwatch
extends El

# A fixed-size picture inside the HUD's box model — the settings panel's app
# icon choices. El draws boxes and text only; this is the one thing it cannot.

var tex: Texture2D

func _init(t: Texture2D, px := 28.0) -> void:
	tex = t
	super({"w": px, "h": px})

func _draw_extra() -> void:
	if tex != null: draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
