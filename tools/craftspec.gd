extends SceneTree

# Blender consumes the runtime catalogue instead of maintaining physical dimensions.
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1:
		printerr("CRAFTSPEC requires an output path")
		quit(1)
		return
	var vehicles := {}
	for id in Vehicles.VEHICLE_ORDER:
		var vehicle: Dictionary = Vehicles.get_vehicle(id)
		var stages := {}
		for spec in vehicle.stages:
			var row: Dictionary = spec.duplicate(true)
			row["partCounts"] = CraftAssets.part_counts(spec, vehicle)
			row["gimbalLimits"] = CraftAssets.gimbal_limits(spec, vehicle)
			stages[spec.key] = row
		vehicles[id] = stages
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	if file == null:
		printerr("CRAFTSPEC cannot write ", args[0])
		quit(1)
		return
	file.store_string(JSON.stringify({"version": 1, "vehicles": vehicles}))
	var error := file.get_error()
	file.close()
	print("CRAFTSPEC DONE ", vehicles.size(), " vehicles")
	quit(0 if error == OK else 1)
