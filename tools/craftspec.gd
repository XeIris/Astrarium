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
			if vehicle.has("interior") and str(vehicle.interior.stage) == str(spec.key):
				row["interior"] = vehicle.interior.duplicate(true)
			row["partCounts"] = CraftAssets.part_counts(spec, vehicle)
			if spec.get("look", {}).get("ranger", false): row["geometry"] = RangerCraft.geometry(spec)
			if spec.get("look", {}).get("lander", false):
				row["geometry"]=LanderCraft.geometry(spec)
				row["enginePositions"]=LanderCraft.engines(spec).map(func(v: Vector3):return [v.x,v.y,v.z])
				row["dockPort"]=LanderCraft.dock(spec)
			if spec.get("look", {}).get("endurance", false):
				row["berths"]=EnduranceCraft.berths(spec)
				row["spokes"]=EnduranceCraft.spokes(spec).map(func(member: Dictionary) -> Dictionary:
					var a: Vector3=member.start;var b: Vector3=member.end
					return {"start":[a.x,a.y,a.z],"end":[b.x,b.y,b.z],"radius":member.radius})
			if spec.get("look", {}).get("discovery", false):row["berths"]=DiscoveryCraft.berths(spec)
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
