extends Node

# ===========================================================================
# CONTACT SHEET — every vehicle in one frame, each in its own viewport, all at
# the same light and the same fraction of its own height. The Godot
# counterpart of .claude/craftsheet.html. One image is the only way to judge
# whether the SET looks like it belongs together, which is a different
# question from whether any one of them is right.
#
#   Godot --path . res://tools/craftsheet.tscn -- out=/abs.png
#     v=saturnv,falcon9,...   vehicles (default saturnv,falcon9,shuttle,skycrane,hailmary)
#     cols=<n>                columns (default min(count, 5))
#     cw=, ch=                cell size (default 340×560)
#     assets=0                procedural fallback
#
# Each cell is tone mapped exactly as crafttest.gd's frame is (three's
# ACESFilmic, background composited after the curve); see make_frame() there.
# ===========================================================================

const CM := preload("res://sim/flight/craftmodel.gd")
const CT := preload("res://tools/crafttest.gd")

var args := {}
var frame := 0
var sheet: SubViewport
var crafts := []

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		args[kv[0]] = kv[1] if kv.size() > 1 else ""
	if args.get("assets", "1") != "0":
		CraftAssets.craft_models_ready()      # fill the model cache before the first build
	# One unknown key in the list is enough to throw inside build_craft and
	# leave the whole sheet blank, which is the opposite of what a contact
	# sheet is for. Drop what does not exist and say so.
	var asked: PackedStringArray = str(args.get("v", "saturnv,falcon9,shuttle,skycrane,hailmary")).split(",")
	var keys := []
	var unknown := []
	for k in asked:
		if CM.vehicle(k) != null: keys.append(k)
		else: unknown.append(k)
	if not unknown.is_empty():
		push_warning("[craftsheet] no such vehicle: " + ", ".join(unknown))
	if keys.is_empty():
		push_error("[craftsheet] nothing to draw — known vehicles: " + ", ".join(CM.vehicles().keys()))
		get_tree().quit(1)
		return
	var cols := int(args.get("cols", str(mini(keys.size(), 5))))
	var rows := ceili(float(keys.size()) / cols)
	var CW := int(args.get("cw", "340")); var CH := int(args.get("ch", "560"))
	get_window().size = Vector2i(cols * CW, rows * CH)

	sheet = SubViewport.new()
	sheet.size = Vector2i(cols * CW, rows * CH)
	sheet.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sheet)
	# The page's own background (body #22252a) shows through any cell left
	# empty, because the canvas is only ever drawn inside the scissored cells.
	var page_bg := ColorRect.new()
	page_bg.color = Color.hex(0x22252aff)
	page_bg.size = Vector2(sheet.size)
	sheet.add_child(page_bg)
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Menlo", "SF Mono", "monospace"])
	for i in keys.size():
		var cell := _make_cell(keys[i], CW, CH)
		var cx := (i % cols) * CW; var cy := (i / cols) * CH
		var tr := TextureRect.new()
		tr.texture = (cell.vp2 as SubViewport).get_texture()
		tr.position = Vector2(cx, cy)
		tr.size = Vector2(CW, CH)
		sheet.add_child(tr)
		for ln in [[cell.name, 0xdfe7ef, 22], ["%s m tall · %s m span" % [U.fixed(cell.H, 1), U.fixed(cell.W, 1)], 0x8fa3b6, 40]]:
			var l := Label.new()
			l.text = ln[0]
			l.add_theme_font_override("font", font)
			l.add_theme_font_size_override("font_size", 13)
			l.add_theme_color_override("font_color", Color.hex((ln[1] << 8) | 0xff))
			# A canvas fillText y is the BASELINE; a Label is placed by its top.
			l.position = Vector2(cx + 12, cy + ln[2] - 13)
			sheet.add_child(l)
	var show := TextureRect.new()
	show.texture = sheet.get_texture()
	show.set_anchors_preset(Control.PRESET_FULL_RECT)
	show.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	show.stretch_mode = TextureRect.STRETCH_SCALE
	add_child(show)

func _make_cell(key: String, CW: int, CH: int) -> Dictionary:
	var fr: Array = CT.make_frame(self, CW, CH, 0x2c3037)
	var vp3: SubViewport = fr[0]
	CT.add_rig(vp3, 1.9, 0x424c5a, 0.65)
	var veh: Dictionary = CM.vehicle(key)
	var craft = CM.build_craft(veh)
	crafts.append(craft)
	# Gear DOWN, like crafttest: `deploy: {}` means "asked for nothing", and a
	# sheet of landers with their legs folded is a sheet that cannot tell you
	# whether the legs are right. dt = 0 freezes the easing, so the state is
	# stepped in rather than waited for.
	var dep := {}
	for st in craft.stages: dep[st.key] = 1.0
	craft.update({"dt": 0.0, "attached": {}, "deploy": dep, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
	craft.update({"dt": 4.0, "attached": {}, "deploy": dep, "gimbal": {"x": 0.0, "z": 0.0}, "flap": 0.0})
	vp3.add_child(craft.group)
	var box: AABB = CM.measure(craft.group)
	var size := box.size; var mid := box.get_center()
	var H := maxf(maxf(size.y, size.x), 1e-3)
	# The 1.75 m figure: without it a contact sheet flattens a 111 m launcher
	# and a 3 m rover into the same picture.
	var man := MeshInstance3D.new()
	man.mesh = CM._to_mesh(CM._capsule(0.22, 1.31, 4, 8), CT.std_mat(0xd08a50, 0.9))
	man.position = Vector3(size.x * 0.5 + maxf(H * 0.05, 1.4), box.position.y + 0.875, 0)
	vp3.add_child(man)
	var cam := Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.fov = 30.0; cam.near = 0.02; cam.far = 1.0e5
	var d := H * 2.15
	var pos := mid + Vector3(d * 0.62, d * 0.20, d * 0.76)
	cam.transform = Transform3D(CT.look_basis(mid - pos), pos)
	vp3.add_child(cam)
	cam.current = true
	return {"vp2": fr[1], "name": veh.name, "H": size.y, "W": size.x}

func _process(_dt: float) -> void:
	if sheet == null: return
	frame += 1
	if args.has("out") and frame == 4:
		sheet.get_texture().get_image().save_png(str(args.out))
		print("craftsheet: saved ", args.out)
		for c in crafts: c.group.queue_free()
		CraftAssets.clear()
		get_tree().quit()
