class_name HookEffect
extends CompositorEffect

# ============================================================================
# A RENDER-THREAD HOOK.
# ----------------------------------------------------------------------------
# The post chain has to run AFTER every SubViewport that feeds it has rendered
# this frame and BEFORE the root viewport composites the result to the screen.
# Godot renders a SubViewport before the viewport that contains it, so the
# chain lives in the callback of a tiny "hook" viewport that CONTAINS all the
# others: its callback is the first moment all of them are finished. The hook
# viewport's own 3D scene is empty; nothing of what it renders is ever shown.
# (Measured, not assumed — see PORT_GUIDE.md, "render order".)
# ============================================================================

var callback: Callable

func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_POST_TRANSPARENT
	needs_motion_vectors = false
	needs_normal_roughness = false

func _render_callback(_type: int, _data: RenderData) -> void:
	if callback.is_valid():
		callback.call()
