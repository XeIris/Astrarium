extends SceneTree

# ===========================================================================
# WEB vs GODOT, AS NUMBERS — compare pairs of crafttest/craftsheet frames.
#
#   Godot --headless --path . --script res://tools/crafttest.compare.gd -- \
#         web_dir godot_dir [pairs_dir]
#
# For every PNG present in both directories (same name), prints:
#   mad     mean absolute difference over all pixels, 0–255, mean of R, G, B
#   grid    the largest difference between the two frames' 16×9 coarse
#           LUMINANCE grids (the .claude/art.js idea) — a feature that is
#           missing, moved or a different brightness shows up here even when
#           the per-pixel number is dominated by antialiasing
#   fg      the fraction of pixels that differ by more than 24 levels
# and, with pairs_dir, writes <name>.png there: web on the left, Godot on the
# right, which is the evidence image kept in tools/ref/craft/.
# ===========================================================================

func _init() -> void:
	var a := OS.get_cmdline_user_args()
	if a.size() < 2:
		print("usage: -- web_dir godot_dir [pairs_dir]")
		quit(2)
		return
	var web: String = a[0]; var god: String = a[1]
	var pairs: String = a[2] if a.size() > 2 else ""
	if pairs != "": DirAccess.make_dir_recursive_absolute(pairs)
	var names := Array(DirAccess.get_files_at(god)).filter(func(f): return f.ends_with(".png"))
	names.sort()
	print("%-28s %6s %6s %6s" % ["frame", "mad", "grid", "fg%"])
	for n in names:
		if not FileAccess.file_exists(web.path_join(n)): continue
		var A := Image.load_from_file(web.path_join(n))
		var B := Image.load_from_file(god.path_join(n))
		A.convert(Image.FORMAT_RGB8); B.convert(Image.FORMAT_RGB8)
		if A.get_size() != B.get_size():
			print("%-28s size mismatch %s vs %s" % [n, A.get_size(), B.get_size()])
			continue
		var w := A.get_width(); var h := A.get_height()
		var sum := 0.0; var big := 0
		var ga := PackedFloat64Array(); ga.resize(16 * 9)
		var gb := PackedFloat64Array(); gb.resize(16 * 9)
		var gn := PackedFloat64Array(); gn.resize(16 * 9)
		for y in range(0, h, 2):
			for x in range(0, w, 2):
				var ca := A.get_pixel(x, y); var cb := B.get_pixel(x, y)
				var d := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0 * 255.0
				sum += d
				if d > 24.0: big += 1
				var gi := int(y * 9 / h) * 16 + int(x * 16 / w)
				ga[gi] += ca.get_luminance(); gb[gi] += cb.get_luminance(); gn[gi] += 1.0
		var n_px := float(((w + 1) / 2) * ((h + 1) / 2))
		var gmax := 0.0
		for i in ga.size():
			if gn[i] > 0.0: gmax = maxf(gmax, absf(ga[i] - gb[i]) / gn[i] * 255.0)
		print("%-28s %6.2f %6.1f %6.2f" % [n, sum / n_px, gmax, 100.0 * big / n_px])
		if pairs != "":
			var out := Image.create(w * 2, h, false, Image.FORMAT_RGB8)
			out.blit_rect(A, Rect2i(0, 0, w, h), Vector2i(0, 0))
			out.blit_rect(B, Rect2i(0, 0, w, h), Vector2i(w, 0))
			if w > 1000:
				out.resize(w, h / 2, Image.INTERPOLATE_LANCZOS)
			out.save_png(pairs.path_join(n))
	quit()
