extends Node

const CT := preload("res://tools/crafttest.gd")
var output := ""
var mats := {}

func collect(node: Node) -> void:
	if node is MeshInstance3D:
		for s in node.mesh.get_surface_count():
			var m: Material=node.mesh.surface_get_material(s)
			if m!=null: mats[m.resource_name.get_slice(".",0)]=m
	for child in node.get_children(): collect(child)

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("out="): output=a.substr(4)
	if DisplayServer.get_name()=="headless" or output.is_empty():
		printerr("EVAPODMATERIALS needs a GPU and out=/absolute/file.png")
		get_tree().quit(1);return
	get_window().size=Vector2i(1600,900)
	CraftAssets.craft_models_ready(["evapod"])
	var c=CraftModel.build_craft(Vehicles.get_vehicle("evapod"));add_child(c.group)
	var cabin:=CraftInterior.new();cabin.set_enabled(true,c,Vehicles.get_vehicle("evapod"))
	collect(c.group)
	var frame: Array=CT.make_frame(self,1600,900,0x161e29)
	var vp: SubViewport=frame[0]
	CT.add_rig(vp,1.3,0x667788,.8)
	var camera:=Camera3D.new();camera.projection=Camera3D.PROJECTION_ORTHOGONAL;camera.size=1.25
	camera.position=Vector3(0,0,3);vp.add_child(camera);camera.current=true
	var font:=SystemFont.new();font.font_names=PackedStringArray(["Menlo","monospace"])
	var rows: Array=[['ENAMEL','podWhite',8.0],['SATIN LAMINATE','podPanel',5.0],['LEATHERETTE','podPad',14.0],['WEBBING','podWebbing',25.0],['ALUMINIUM','podAluminium',5.0],['RUBBER','podSeal',18.0]]
	for i in rows.size():
		var row: Array=rows[i]
		if not mats.has(row[1]):
			printerr("EVAPODMATERIALS missing ",row[1]);get_tree().quit(1);return
		var m: StandardMaterial3D=mats[row[1]].duplicate()
		m.uv1_scale=Vector3.ONE*float(row[2])*.32
		var ball:=MeshInstance3D.new();var sphere:=SphereMesh.new();sphere.radius=.16;sphere.height=.32;sphere.radial_segments=64;sphere.rings=32
		ball.mesh=sphere;ball.material_override=m;ball.position=Vector3((i%3-1)*.70,(.5-floor(i/3.0))*.56,0);vp.add_child(ball)
		var label:=Label.new();label.text=row[0];label.position=Vector2((i%3)*533+25,24+floor(i/3.0)*450)
		label.add_theme_font_override("font",font);label.add_theme_font_size_override("font_size",19);frame[1].add_child(label)
	var show:=TextureRect.new();show.texture=frame[1].get_texture();show.size=Vector2(1600,900);add_child(show)
	for i in 8:await RenderingServer.frame_post_draw
	frame[1].get_texture().get_image().save_png(output)
	cabin.dispose();c.group.queue_free();CraftAssets.clear()
	await get_tree().process_frame
	print("EVAPODMATERIALS DONE")
	get_tree().quit()
