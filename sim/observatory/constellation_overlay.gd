class_name ConstellationOverlay
extends Control

# Constellation stick figures, names and IAU boundaries drawn over the frame in screen
# space and cut at the horizon. Data: assets/sky/constellations.json, built by
# tools/build_constellations.py. Figure stars move with their proper motion
# (set_epoch); boundaries are fixed to the sky by definition (B1875 lines given at J2000).
# Each name is set just under one of its figure's stars.

const T = preload("res://ui/theme.gd")
const DATA := "res://assets/sky/constellations.json"
const LINE := Color(0.50, 0.66, 1.0, 0.55)
const BOUND := Color(0.85, 0.66, 0.40, 0.32)
const NAME := Color(0.70, 0.80, 1.0, 0.90)
# Great-circle pieces per figure segment, so a line bends with the projection and stops
# at the horizon. Boundary points are already ≤ 1° apart.
const PIECES := 6

var show_lines := true
var show_names := true
var show_bounds := false
## Figure segments: [ra, dec, μα cos δ, μδ] for each end (degrees, mas/yr), J2000.
var _figure_src: Array = []
var _figure := PackedVector3Array()    # scene unit vectors, two per segment
var _bounds := PackedVector3Array()    # scene unit vectors, two per segment
var _labels: Array = []                # [name, scene unit vector]
var _basis := Basis()
var _tan := 1.0
var _up := Vector3.UP
var _on := false
var count := 0

func _init() -> void:
	name = "ConstellationOverlay"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	theme = T.theme()
	visible = false
	_load()

func _load() -> void:
	if not FileAccess.file_exists(DATA): return
	var d = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	if not d is Dictionary: return
	var figures: Dictionary = d.get("figures", {})
	for abbr in figures:
		var c: Dictionary = figures[abbr]
		_figure_src.append_array(c.get("lines", []))
		for at in c.get("labels", []):
			_labels.append([String(c.get("name", abbr)).to_upper(), SkyModel.radec_to_scene(float(at[0]), float(at[1])).to_v3()])
		count += 1
	for poly in d.get("bounds", []):
		var pts: Array = poly.p
		for i in pts.size():
			var a: Array = pts[i]
			var b: Array = pts[(i + 1) % pts.size()]
			_bounds.append(SkyModel.radec_to_scene(float(a[0]), float(a[1])).to_v3())
			_bounds.append(SkyModel.radec_to_scene(float(b[0]), float(b[1])).to_v3())
	set_epoch(2000.0)

## Carry the figure stars to Julian year `year`.
func set_epoch(year: float) -> void:
	_figure.resize(_figure_src.size() * 2)
	for i in _figure_src.size():
		var s: Array = _figure_src[i]
		for e in 2:
			var o := e * 4
			var p := EarthFrame.proper_motion(deg_to_rad(float(s[o])), deg_to_rad(float(s[o + 1])),
				float(s[o + 2]), float(s[o + 3]), 2000.0, year)
			_figure[i * 2 + e] = EarthFrame.to_scene(p).to_v3()

## Per frame: the scene camera's basis and vertical field of view (degrees), and the
## observer's zenith in scene axes.
func place(basis: Basis, fov_deg: float, up: Vector3, on: bool) -> void:
	_basis = basis
	_tan = tan(deg_to_rad(fov_deg) * 0.5)
	_up = up
	_on = on
	visible = on and (show_lines or show_names or show_bounds) and count > 0
	if visible: queue_redraw()

## Screen position of scene direction `d`, or null behind the camera.
func project(d: Vector3):
	var z := -d.dot(_basis.z)
	if z <= 1e-4: return null
	var h := size.y
	var w := size.x
	var x := d.dot(_basis.x) / z / (_tan * w / h)
	var y := d.dot(_basis.y) / z / _tan
	return Vector2((x + 1.0) * 0.5 * w, (1.0 - y) * 0.5 * h)

func _segments(dirs: PackedVector3Array, out: PackedVector2Array, pieces: int) -> void:
	var margin := size.length()
	var ahead := -_basis.z
	# Beyond this from the view axis a point is off screen at any aspect up to 3:1.
	var cos_edge := cos(minf(atan(_tan * 3.2) + 0.05, PI * 0.5))
	for i in range(0, dirs.size(), 2):
		var a := dirs[i]; var b := dirs[i + 1]
		if (a.dot(_up) < 0.0 and b.dot(_up) < 0.0) or (a.dot(ahead) < cos_edge and b.dot(ahead) < cos_edge and pieces == 1):
			continue
		var prev = null
		for k in pieces + 1:
			var d := a.lerp(b, float(k) / pieces).normalized()
			var p = project(d) if d.dot(_up) > 0.0 else null
			if p != null and prev != null and (p as Vector2).distance_to(prev) < margin:
				out.append(prev); out.append(p)
			prev = p

func _draw() -> void:
	if not _on: return
	if show_bounds and not _bounds.is_empty():
		var pts := PackedVector2Array()
		_segments(_bounds, pts, 1)
		if not pts.is_empty(): draw_multiline(pts, BOUND, 1.0, true)
	if show_lines and not _figure.is_empty():
		var pts := PackedVector2Array()
		_segments(_figure, pts, PIECES)
		if not pts.is_empty(): draw_multiline(pts, LINE, 1.2, true)
	if show_names:
		var font := get_theme_default_font()
		for l in _labels:
			var d: Vector3 = l[1]
			if d.dot(_up) < 0.02: continue
			var p = project(d)
			if p == null: continue
			var text: String = l[0]
			var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(font, (p as Vector2) + Vector2(-w * 0.5, 17.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, NAME)
