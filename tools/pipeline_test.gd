extends Harness
# Bring-up check for render/pipeline.gd: one hole at the origin, the real
# marcher, the post chain. `-- out=/abs.png band=3`
func _setup() -> void:
	cam_target = DVec3.new()
	cam_radius = sqrt(8.0 * 8.0 + 24.0 * 24.0)
	cam_theta = acos(8.0 / cam_radius)
	lens_params = {
		"holes": [{"pos": Vector3.ZERO, "rs": 1.0}], "basis": Basis(), "fov": deg_to_rad(50.0),
		"aspect": 16.0 / 9.0, "time": 0.0, "disc_intensity": 0.9, "disc_temp": 0.6,
		"disc_tpeak_phys": 1.1e7, "disc_outer": 15.0,
	}
func _step(_dt: float) -> void:
	lens_params.holes[0].pos = DVec3.new().rel_v3(cam_pos)
	lens_params.time = frame * 0.01
