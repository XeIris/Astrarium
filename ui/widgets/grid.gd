class_name HudGrid
extends Container

# Equal-width columns (GridContainer sizes columns by their widest cell), or fixed
# ones where `cols` holds a negative width. Cells fill row-major, meta "span" widens
# one, rows are as tall as their tallest cell, and cells stretch to the row.

var cols: Array = [1.0]
var hgap := 0.0
var vgap := 0.0

func _init(tracks: Array = [1.0], h := 0.0, v := 0.0) -> void:
	cols = tracks
	hgap = h
	vgap = v
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_cols(tracks: Array) -> void:
	cols = tracks
	update_minimum_size()
	queue_sort()

func _kids() -> Array[Control]:
	var out: Array[Control] = []
	for c in get_children():
		if c is Control and (c as Control).visible and not (c as Control).top_level:
			out.append(c)
	return out

## Column x offsets and widths at this width.
func _tracks(w: float) -> Array:
	var fixed := 0.0
	var fr := 0.0
	for c in cols:
		if float(c) < 0.0: fixed += -float(c)
		else: fr += float(c)
	var frw := maxf(w - fixed - hgap * (cols.size() - 1), 0.0) / maxf(fr, 1e-6)
	var xs: Array = []
	var ws: Array = []
	var x := 0.0
	for c in cols:
		var cw: float = -float(c) if float(c) < 0.0 else float(c) * frw
		xs.append(x); ws.append(cw)
		x += cw + hgap
	return [xs, ws]

## [child, col, row, span] per cell, and the row count.
func _place() -> Array:
	var n := cols.size()
	var out: Array = []
	var c := 0
	var r := 0
	for k in _kids():
		var span := mini(int(k.get_meta("span", 1)), n)
		if c + span > n:
			c = 0; r += 1
		out.append([k, c, r, span])
		c += span
		if c >= n:
			c = 0; r += 1
	var rows := r + (1 if c > 0 else 0)
	return [out, rows]

func _row_heights(cells: Array, rows: int) -> Array:
	var rh: Array = []
	rh.resize(rows)
	rh.fill(0.0)
	for cell in cells:
		rh[cell[2]] = maxf(rh[cell[2]], (cell[0] as Control).get_combined_minimum_size().y)
	return rh

func _get_minimum_size() -> Vector2:
	var p := _place()
	var rh := _row_heights(p[0], p[1])
	var h := 0.0
	for i in rh.size():
		h += rh[i] + (vgap if i > 0 else 0.0)
	var fixed := 0.0
	var nfr := 0
	for c in cols:
		if float(c) < 0.0: fixed += -float(c)
		else: nfr += 1
	var best := 0.0
	for cell in p[0]:
		if int(cell[3]) == 1: best = maxf(best, (cell[0] as Control).get_combined_minimum_size().x)
	return Vector2(fixed + best * nfr + hgap * (cols.size() - 1), h)

func _notification(what: int) -> void:
	if what != NOTIFICATION_SORT_CHILDREN:
		return
	var tr := _tracks(size.x)
	var p := _place()
	var rh := _row_heights(p[0], p[1])
	var ry: Array = []
	var y := 0.0
	for i in rh.size():
		ry.append(y)
		y += rh[i] + vgap
	for cell in p[0]:
		var c0: int = cell[1]
		var c1: int = c0 + int(cell[3]) - 1
		var x0: float = tr[0][c0]
		var w: float = tr[0][c1] + tr[1][c1] - x0
		fit_child_in_rect(cell[0], Rect2(x0, ry[cell[2]], w, rh[cell[2]]))
