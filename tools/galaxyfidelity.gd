extends SceneTree

# A rendered galaxy against a telescope image of it, registered and measured
# (docs/physics/galaxies.md#against-hubble-measured). Not a check: the photographs are not
# in the repository. Downloads and licences are listed in that section.
#   Godot --headless --path . -s tools/galaxyfidelity.gd -- ours=/abs/render.png
#     north=<deg, celestial north clockwise from up in ours> fov=<deg spanned by ours' height>
#     photo=/abs/photo.jpg pnorth=<deg, photo's north counter-clockwise from up>
#     field=<w′>x<h′> nucleus=<x>,<y> (photo px) pc=<pc per arcsec>
#     ellipse=<a′>,<b′>,<pa deg> [scale=0.5] out=/abs/prefix
# Writes <prefix>_ours.png, <prefix>_photo.png (the same field, north and pixels) and
# <prefix>.json, and prints METRIC lines.
#
# Ours is turned so north points as in the photo and cut to its field; the photo is resampled
# to ours' pixels with its nucleus on ours'. Ours is then rank-matched to the photo's luminance
# inside the ellipse, so a processed photograph's unknown stretch does not enter the structure
# measures:
#  - band power of log(L + L₂₀), L₂₀ the 20th percentile (dither in near-black lanes would
#    otherwise rule the log): the variance of L_f − L_2f, L_f resampled down by f and back up,
#    a Δ-variance-like band pass (Stutzki et al. 1998), reported at the band's scale in pc;
#  - clumpiness (Conselice 2003): Σ(I − I_s)⁺ / ΣI, I_s at a tenth of the ellipse;
#  - arm–interarm contrast: per elliptical annulus the 90th/10th percentile, median;
#  - colour: per annulus the median log₁₀(B/R).

var args := {}

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		if kv.size() == 2: args[kv[0]] = kv[1]
	var need := ["ours", "north", "fov", "photo", "pnorth", "field", "nucleus", "pc", "ellipse", "out"]
	for k in need:
		if not args.has(k):
			push_error("galaxyfidelity: missing %s=" % k)
			quit(1)
			return
	var scale := float(args.get("scale", "0.5"))
	var ours := Image.load_from_file(args.ours)
	if ours == null or ours.is_empty():
		push_error("galaxyfidelity: cannot read %s" % args.ours)
		quit(1)
		return
	ours.convert(Image.FORMAT_RGB8)
	var W := ours.get_width()
	var H := ours.get_height()
	var fw := float(String(args.field).split("x")[0])
	var fh := float(String(args.field).split("x")[1])
	var deg_px := float(args.fov) / float(H)
	var cw := int(round(fw / 60.0 / deg_px * scale))
	var ch := int(round(fh / 60.0 / deg_px * scale))
	# Ours: a pixel of the output at (u, v) from its centre, turned by north + pnorth, read
	# bilinearly from the render about its centre.
	var turn := deg_to_rad(float(args.north) + float(args.pnorth))
	var reg := Image.create_empty(cw, ch, false, Image.FORMAT_RGB8)
	for y in ch:
		for x in cw:
			var u := (float(x) + 0.5 - cw * 0.5) / scale
			var v := (float(y) + 0.5 - ch * 0.5) / scale
			var sx := W * 0.5 + u * cos(turn) + v * sin(turn)
			var sy := H * 0.5 - u * sin(turn) + v * cos(turn)
			reg.set_pixel(x, y, bilinear(ours, sx - 0.5, sy - 0.5))
	# The photo: its whole frame is the field; the nucleus moves to the centre.
	var photo := Image.load_from_file(args.photo)
	if photo == null or photo.is_empty():
		push_error("galaxyfidelity: cannot read %s (Godot holds at most 2^28 pixels)" % args.photo)
		quit(1)
		return
	photo.convert(Image.FORMAT_RGB8)
	var nuc := String(args.nucleus).split(",")
	var k := float(cw) / float(photo.get_width())
	var nx := float(nuc[0]) * k
	var ny := float(nuc[1]) * k
	photo.resize(cw, int(round(photo.get_height() * k)), Image.INTERPOLATE_LANCZOS)
	var pr := Image.create_empty(cw, ch, false, Image.FORMAT_RGB8)
	for y in ch:
		for x in cw:
			pr.set_pixel(x, y, bilinear(photo, float(x) + nx - cw * 0.5, float(y) + ny - ch * 0.5))
	reg.save_png(args.out + "_ours.png")
	pr.save_png(args.out + "_photo.png")
	var el := String(args.ellipse).split(",")
	var px_arcmin := float(cw) / fw
	var res := measure(reg, pr, float(args.pc) * 60.0 / px_arcmin, float(el[0]) * px_arcmin, float(el[1]) * px_arcmin, deg_to_rad(float(el[2])))
	var fa := FileAccess.open(args.out + ".json", FileAccess.WRITE)
	fa.store_string(JSON.stringify(res, " "))
	print("GALAXYFIDELITY DONE")
	quit()

func bilinear(img: Image, x: float, y: float) -> Color:
	var w := img.get_width()
	var h := img.get_height()
	if x < 0.0 or y < 0.0 or x > w - 1 or y > h - 1: return Color.BLACK
	var x0 := int(x)
	var y0 := int(y)
	var x1 := mini(x0 + 1, w - 1)
	var y1 := mini(y0 + 1, h - 1)
	var a := img.get_pixel(x0, y0).lerp(img.get_pixel(x1, y0), x - x0)
	var b := img.get_pixel(x0, y1).lerp(img.get_pixel(x1, y1), x - x0)
	return a.lerp(b, y - y0)

func lum(img: Image) -> PackedFloat32Array:
	var w := img.get_width()
	var out := PackedFloat32Array()
	out.resize(w * img.get_height())
	for i in out.size():
		var c := img.get_pixel(i % w, i / w)
		out[i] = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
	return out

func smooth(v: PackedFloat32Array, w: int, h: int, f: float) -> PackedFloat32Array:
	var img := Image.create_from_data(w, h, false, Image.FORMAT_RF, v.to_byte_array())
	img.resize(maxi(int(w / f), 2), maxi(int(h / f), 2), Image.INTERPOLATE_LANCZOS)
	img.resize(w, h, Image.INTERPOLATE_CUBIC)
	return img.get_data().to_float32_array()

## pc per pixel; the ellipse's semi-axes in pixels about the centre and its major axis from up
## toward right.
func measure(ours: Image, photo: Image, pc: float, ea: float, eb: float, pa: float) -> Dictionary:
	var w := ours.get_width()
	var h := ours.get_height()
	var er := PackedFloat32Array()
	er.resize(w * h)
	var idx := PackedInt32Array()
	for y in h:
		for x in w:
			var dx := x - w * 0.5
			var dy := h * 0.5 - y
			var u := dx * sin(pa) + dy * cos(pa)
			var v := dx * cos(pa) - dy * sin(pa)
			var r := sqrt((u / ea) * (u / ea) + (v / eb) * (v / eb))
			er[y * w + x] = r
			if r < 1.0: idx.append(y * w + x)
	var lo := lum(ours)
	var lp := lum(photo)
	var so := Array(idx)
	so.sort_custom(func(i, j): return lo[i] < lo[j])
	var vp := PackedFloat32Array()
	for i in idx: vp.append(lp[i])
	vp.sort()
	var lm := lo.duplicate()
	for k in so.size(): lm[so[k]] = vp[k]
	var floor_l: float = vp[int(0.2 * vp.size())]
	var res := {"pc_per_px": pc}
	for name in ["ours", "photo"]:
		var L: PackedFloat32Array = lm if name == "ours" else lp
		var im: Image = ours if name == "ours" else photo
		var ln := PackedFloat32Array()
		ln.resize(w * h)
		for i in w * h: ln[i] = log(L[i] + floor_l + 1.0 / 255.0)
		var band := {}
		var f := 1.0
		var prev := ln
		while f * pc <= 1000.0 and f < minf(w, h) / 8.0:
			var nxt := smooth(ln, w, h, 2.0 * f)
			var s := 0.0
			var s2 := 0.0
			var n := 0
			for i in idx:
				if er[i] > 0.9: continue
				var d := prev[i] - nxt[i]
				s += d
				s2 += d * d
				n += 1
			band[str(int(round(f * pc)))] = s2 / n - (s / n) * (s / n)
			prev = nxt
			f *= 2.0
		var sm := smooth(L, w, h, 0.1 * ea)
		var pos := 0.0
		var tot := 0.0
		for i in idx:
			pos += maxf(L[i] - sm[i], 0.0)
			tot += L[i]
		var contrasts := []
		var colours := []
		for k in range(1, 9):
			var ring := []
			var col := []
			for i in idx:
				if er[i] >= k / 10.0 and er[i] < (k + 1) / 10.0:
					ring.append(L[i])
					var c := im.get_pixel(i % w, i / w)
					col.append(log(maxf(c.b, 1.0 / 255.0) / maxf(c.r, 1.0 / 255.0)) / log(10.0))
			if ring.size() < 50: continue
			ring.sort()
			col.sort()
			contrasts.append(ring[int(0.9 * ring.size())] / maxf(ring[int(0.1 * ring.size())], 1.0 / 255.0))
			colours.append(col[col.size() / 2])
		var cs := contrasts.duplicate()
		cs.sort()
		res[name] = {"band": band, "clumpiness": pos / tot, "contrast": cs[cs.size() / 2] if not cs.is_empty() else 0.0, "colour": colours}
		var bs := ""
		for kk in band: bs += " %s:%.4f" % [kk, band[kk]]
		var co := ""
		for c in colours: co += " %.3f" % c
		print("METRIC %s clump=%.3f contrast=%.2f band%s colour%s" % [name, pos / tot, res[name].contrast, bs, co])
	var rs := ""
	var ratio := {}
	for kk in res.ours.band:
		ratio[kk] = float(res.ours.band[kk]) / float(res.photo.band[kk])
		rs += " %s:%.2f" % [kk, ratio[kk]]
	res["ratio"] = ratio
	print("METRIC ratio%s" % rs)
	return res
