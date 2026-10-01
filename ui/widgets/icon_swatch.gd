class_name IconSwatch
extends TextureRect

# A fixed-size picture in a row: the settings panel's app icon choices.

func _init(t: Texture2D, px := 28.0) -> void:
	texture = t
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_SCALE
	custom_minimum_size = Vector2(px, px)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE
