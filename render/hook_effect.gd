class_name HookEffect
extends CompositorEffect

# A RENDER-THREAD HOOK. The post chain runs in the callback of a tiny viewport that
# contains all the others: SubViewports render before their container, so this is
# the first moment every input is finished (measured; docs/godot.md). Its own 3D
# scene is empty.

var callback: Callable

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_motion_vectors = false
	needs_normal_roughness = false

func _render_callback(_type: int, _data: RenderData) -> void:
	if callback.is_valid():
		callback.call()
