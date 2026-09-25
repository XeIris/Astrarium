class_name CrossSection
extends RefCounted

# ============================================================================
# CROSS-SECTION — cutting a body open and labelling what is inside
# ----------------------------------------------------------------------------
# Everything else in this sim draws what an observer could see. This draws what
# they could not: the interior, which for every object here is inferred rather
# than imaged. That is worth being explicit about, because the inference is not
# equally strong everywhere along the radius —
#
#   · a planet's core radius comes from its moment of inertia and seismology,
#     and is known to a few percent
#   · a star's interior comes from stellar models constrained by helioseismology
#     and neutrinos, and is known well for the Sun and less well elsewhere
#   · a neutron star's inner core is genuinely unknown — that is what the whole
#     TOV-limit question turns on
#   · a black hole's interior is not merely unmeasured but unmeasurABLE, and
#     what is drawn there is the coordinate structure of a solution to
#     Einstein's equations, not a place anyone has information about
#
# So each layer carries its own note, and the black hole says outright that the
# diagram is cheating. The alternative — drawing them all with the same
# confidence — would be the actual dishonesty.
#
# TEMPERATURE COLOUR. Layers are filled by a ramp over log T spanning 100 K to
# 10¹⁰ K, which is the range the sim contains (a planet's crust to a collapsing
# iron core). It runs dark violet → red → orange → yellow → white, the ordering
# of a heated blackbody, so "brighter is hotter" is the whole legend.
#
# PORT NOTES (Godot). The web drew into two <canvas> bitmaps (330 × 260 and
# 330 × 26) that CSS then scaled to the panel's width. Here the same arithmetic
# runs in the same BITMAP coordinates inside a Control's _draw(), under one
# scale transform onto the laid-out box — `XsecCanvas` and `LegendCanvas`
# below, both El nodes so the HUD's CSS layout sizes them as `width: 100%;
# height: auto` sized them (content height = width × H/W). Canvas-2D colours
# are CSS sRGB and so are a Control's, so they pass straight through
# (PORT_GUIDE.md §5, §8). Text is drawn glyph by glyph at Blink's advances
# (HudTheme.adv_em) in the HUD's Menlo, because Chrome's canvas resolves
# `ui-monospace, monospace` to the same face and a measured label that drifts
# by a few pixels lands on the leader line it was placed beside.
# ============================================================================

const AU_PER_KM := Physics.AU_PER_KM
const AU_PER_RSUN := Physics.AU_PER_RSUN

# A perceptual ramp over log10(T). Anchors are chosen so the familiar
# temperatures land where you would expect: a planetary surface is dark, a
# photosphere is orange-yellow, a stellar core is white.
const TEMP_STOPS := [
	[2.0, [18, 16, 46]],        # 100 K   — outer solar system ice
	[2.5, [30, 34, 92]],        # 316 K   — a habitable surface
	[3.0, [72, 40, 120]],       # 1 kK    — molten rock
	[3.5, [150, 46, 96]],       # 3.2 kK  — an M dwarf photosphere
	[3.76, [206, 74, 58]],      # 5.8 kK  — the Sun's photosphere
	[4.3, [242, 140, 44]],      # 20 kK   — a B star
	[5.0, [252, 196, 82]],      # 100 kK
	[6.0, [255, 232, 150]],     # 1 MK    — the solar corona
	[7.3, [255, 250, 225]],     # 20 MK   — the Sun's core
	[9.0, [232, 244, 255]],     # 1 GK    — carbon burning
	[10.0, [190, 222, 255]],    # 10 GK   — silicon burning / collapse
]

## A JS number out of a structure field: null / undefined → NaN, so every
## comparison below fails the way `undefined > 0` does.
static func num(v) -> float:
	if v == null or not (v is float or v is int):
		return NAN
	return float(v)

## tempColor(T) — an sRGB Color (the CSS `rgb(r,g,b)` it returned, channel for
## channel, Math.round included).
static func temp_color(Tv) -> Color:
	var T := num(Tv)
	if not (T > 0.0):
		return Color8(24, 26, 34)
	if is_inf(T):
		return Color8(255, 255, 255)
	var x := U.log10(T)
	if x <= float(TEMP_STOPS[0][0]):
		return _c8(TEMP_STOPS[0][1])
	for i in TEMP_STOPS.size() - 1:
		var x0: float = TEMP_STOPS[i][0]
		var c0: Array = TEMP_STOPS[i][1]
		var x1: float = TEMP_STOPS[i + 1][0]
		var c1: Array = TEMP_STOPS[i + 1][1]
		if x <= x1:
			var t := (x - x0) / (x1 - x0)
			return Color8(int(U.jround(c0[0] + (c1[0] - c0[0]) * t)), int(U.jround(c0[1] + (c1[1] - c0[1]) * t)),
				int(U.jround(c0[2] + (c1[2] - c0[2]) * t)))
	return _c8(TEMP_STOPS[TEMP_STOPS.size() - 1][1])

static func _c8(a: Array) -> Color:
	return Color8(a[0], a[1], a[2])

# ----------------------------------------------------------------------------
# Formatting. A body in this sim can be 10 km or 10 AU across and 1e-9 or 1e9
# solar masses, so every readout has to pick its own unit or it is unreadable.
# ----------------------------------------------------------------------------
static func fmt_length(au_v) -> String:
	var au := num(au_v)
	if not (au > 0.0): return "—"
	var km := au / AU_PER_KM
	if km < 1.0: return "%s m" % U.fixed(km * 1000.0, 0)
	if km < 1e5: return "%s km" % U.fixed(km, 1 if km < 100.0 else 0)
	if au < 0.02: return "%s R☉" % U.fixed(au / AU_PER_RSUN, 3)
	if au < 3.0: return "%s R☉ · %s AU" % [U.fixed(au / AU_PER_RSUN, 1), U.fixed(au, 3)]
	return "%s R☉ · %s AU" % [U.fixed(au / AU_PER_RSUN, 0), U.fixed(au, 2)]

static func fmt_mass(msun_v) -> String:
	var msun := num(msun_v)
	if msun >= 0.02: return "%s M☉" % U.fixed(msun, 3 if msun < 10.0 else 1)
	var mj := msun / Structure.M_JUP_SUN
	if mj >= 0.3: return "%s M_J" % U.fixed(mj, 2)
	var me := msun / Structure.M_EARTH_SUN
	return "%s M⊕" % U.fixed(me, 2 if me < 10.0 else 0)

static func fmt_temp(T_v) -> String:
	var T := num(T_v)
	# Number.isFinite: NaN and undefined are "not finite" too, and print ∞
	if not is_finite(T): return "∞"
	if not (T > 0.0): return "—"
	if T < 1e4: return "%d K" % int(U.jround(T))
	if T < 1e6: return "%s kK" % U.fixed(T / 1e3, 1)
	if T < 1e9: return "%s MK" % U.fixed(T / 1e6, 1 if T < 1e7 else 0)
	return "%s GK" % U.fixed(T / 1e9, 1)

static func fmt_density(rho_v) -> String:
	var rho := num(rho_v)
	if not is_finite(rho): return "∞"
	if not (rho > 0.0): return "—"
	if rho < 1e4: return "%s kg/m³" % U.fixed(rho, 2 if rho < 100.0 else 0)
	var e := int(floor(U.log10(rho)))
	return "%s×10%s kg/m³" % [U.fixed(rho / pow(10.0, e), 2), sup(e)]

const SUPS := "⁰¹²³⁴⁵⁶⁷⁸⁹"
static func sup(n: int) -> String:
	var s := str(n)
	var o := ""
	for c in s:
		o += "⁻" if c == "-" else SUPS[int(c)]
	return o

static func fmt_period(sec_v) -> String:
	var sec := num(sec_v)
	if not is_finite(sec): return "—"
	if sec < 1.0: return "%s ms" % U.fixed(sec * 1000.0, 2)
	if sec < 120.0: return "%s s" % U.fixed(sec, 2)
	if sec < 7200.0: return "%s min" % U.fixed(sec / 60.0, 1)
	if sec < 3.0 * 86400.0: return "%s h" % U.fixed(sec / 3600.0, 1)
	if sec < 800.0 * 86400.0: return "%s d" % U.fixed(sec / 86400.0, 1)
	return "%s yr" % U.fixed(sec / 3.156e7, 2)

static func fmt_years(y_v) -> String:
	var y := num(y_v)
	if not (y > 0.0) or not is_finite(y): return "—"
	if y < 1e3: return "%s yr" % U.fixed(y, 0)
	if y < 1e6: return "%s kyr" % U.fixed(y / 1e3, 1)
	if y < 1e9: return "%s Myr" % U.fixed(y / 1e6, 1)
	if y < 1e13: return "%s Gyr" % U.fixed(y / 1e9, 1)
	return "%s Gyr" % U.expo(y / 1e9, 1)

## The verdict banner's class per state (the CSS rules .fd-verdict.v-*).
const VERDICT_CLASS := {
	"stable": "v-ok",
	"degenerate": "v-warn",
	"breakup": "v-bad",
	"collapse": "v-bad",
	"explode": "v-bad",
	"ignite": "v-info",
}

# ----------------------------------------------------------------------------
# The prose that goes beside the diagram: the derived quantities the layers do
# not carry, chosen per kind of body because what is interesting about a
# neutron star (its compactness) is not what is interesting about a planet.
# Returns [[key, value], ...].
# ----------------------------------------------------------------------------
static func structure_facts(st: Dictionary) -> Array:
	var F: Array = []
	var add := func(k: String, v) -> void:
		if v != null and str(v) != "":
			F.append([k, str(v)])
	var g := func(k: String) -> float: return num(st.get(k))
	add.call("mass", fmt_mass(st.get("mass")))
	if st.get("type") != "bh": add.call("radius", fmt_length(st.get("radiusAU")))
	var f: float = g.call("flattening")
	if f > 1e-3:
		add.call("shape", "R_eq/R_pol = %s" % U.fixed(1.0 / (1.0 - f), 3))
		add.call("flattening", "f = %s" % U.fixed(f, 4))
	var sp: float = g.call("spinFrac")
	if sp > 1e-3:
		add.call("spin", "%s%% of break-up" % U.fixed(sp * 100.0, 1))
		add.call("period", fmt_period(st.get("spinPeriodSec")))
	match st.get("type"):
		"planet":
			add.call("composition", st.get("composition"))
			add.call("density", fmt_density(st.get("density")))
			add.call("core temp", fmt_temp(st.get("Tc")))
			add.call("max radius", "%s R⊕ at %d M⊕" % [U.fixed(g.call("maxRadiusEarth"), 2), int(U.jround(g.call("maxRadiusMassEarth")))])
		"gas-giant":
			add.call("density", fmt_density(st.get("density")))
			add.call("core temp", fmt_temp(st.get("Tc")))
			if g.call("teff") > 0.0: add.call("T_eff", fmt_temp(st.get("teff")))
		"star":
			add.call("T_eff", fmt_temp(st.get("teff")))
			if sp > 1e-3: add.call("pole / equator", "%s / %s" % [fmt_temp(st.get("tPole")), fmt_temp(st.get("tEq"))])
			var L: float = g.call("luminosity")
			add.call("luminosity", "%s L☉" % (U.fixed(L, 2) if L < 1000.0 else U.expo(L, 2)))
			add.call("L / L_Edd", U.fixed(g.call("eddington"), 3))
			add.call("core temp", fmt_temp(st.get("Tc")))
			add.call("core pressure", "%s GPa" % U.expo(g.call("Pc") / 1e9, 2))
			add.call("core X(H)", U.fixed(g.call("X"), 2))
			var ph = st.get("phase")
			add.call("phase", ph.get("label") if ph is Dictionary else null)
			add.call("MS lifetime", fmt_years(st.get("msLifetime")))
			var es = st.get("endState")
			add.call("ends as", es.get("label") if es is Dictionary else null)
		"neutron":
			add.call("density", fmt_density(st.get("density")))
			add.call("surface gravity", "%s g" % U.expo(g.call("surfaceGravity") / 9.81, 2))
			add.call("compactness", "r_s/R = %s" % U.fixed(g.call("compactness"), 3))
			add.call("surface redshift", "%s%%" % U.fixed(g.call("redshift") * 100.0, 1))
			add.call("TOV limit here", "%s M☉" % U.fixed(g.call("tovMax"), 2))
			if is_finite(g.call("spinPeriodMs")): add.call("spin period", "%s ms" % U.fixed(g.call("spinPeriodMs"), 2))
		"white-dwarf":
			add.call("density", fmt_density(st.get("density")))
			add.call("T_eff", fmt_temp(st.get("teff")))
			add.call("Chandrasekhar", "%s M☉" % Structure._num(Structure.LIMITS.chandrasekhar))
		"bh":
			add.call("event horizon", fmt_length(st.get("horizonAU")))
			add.call("photon sphere", fmt_length(st.get("photonSphereAU")))
			add.call("ISCO", fmt_length(st.get("iscoAU")))
			if g.call("spin") > 0.01: add.call("spin a*", U.fixed(g.call("spin"), 3))
			add.call("Hawking T", "%s K" % U.expo(g.call("hawkingK"), 2))
			add.call("evaporates in", "10%s yr" % sup(int(U.jround(U.log10(g.call("evaporationYr"))))))
	return F

# ============================================================================
# CANVAS-2D, the few calls the diagrams use, on a CanvasItem in bitmap px.
# ============================================================================
static func font(fw := 400) -> Font:
	return HudTheme.font("mono", fw)

## ctx.measureText(s).width for `<fs>px monospace`.
static func text_w(s: String, fs: float, fw := 400) -> float:
	return HudTheme.text_w(font(fw), s, fs, 0.0)

static var MIDDLE_EM := 0.24
static var ROUND_Y := true

## ctx.fillText with textAlign / textBaseline, glyph by glyph at Blink advances.
static func fill_text(ci: CanvasItem, s: String, x: float, y: float, fs: float, col: Color,
		align := "left", base := "alphabetic", fw := 400) -> void:
	var f := font(fw)
	var w := HudTheme.text_w(f, s, fs, 0.0)
	if align == "center": x -= w * 0.5
	elif align == "right": x -= w
	# textBaseline offsets. Chrome's canvas measures 'top' on the EM BOX —
	# the font's ascent and descent normalised to sum to one em (Menlo:
	# 0.797 / 0.203) — not on the hhea ascent the page's own line boxes use
	# (0.928 / 0.236); with the hhea number every 9 px 'top' label sat 0.9 px
	# low against the web shots. 'middle' is MEASURED (MIDDLE_EM): 0.24 em
	# puts the 9 and 10 px labels of the diagram and the curve's axis within
	# 0.05 px of the web's ink centroids, where (a − d)/2 on either metric was
	# 0.4–0.6 px low. The baseline then goes to the nearest whole pixel row.
	var m := HudTheme.metrics(f)
	var ea := m.x / (m.x + m.y)
	var ed := m.y / (m.x + m.y)
	match base:
		"middle": y += MIDDLE_EM * fs
		"top": y += ea * fs
		"bottom": y -= ed * fs
	if ROUND_Y: y = floorf(y + 0.5)
	var isz := int(roundf(fs))
	var xx := x
	for i in s.length():
		ci.draw_char(f, Vector2(xx, y), s[i], isz, col)
		xx += HudTheme.adv_em(f, s.unicode_at(i)) * fs

## A stroked circle or ellipse with an optional dash pattern [on, off] that
## runs along the path from angle 0, as ctx.setLineDash does.
static func stroke_ellipse(ci: CanvasItem, c: Vector2, rx: float, ry: float, col: Color, lw: float, dash: Array = []) -> void:
	if rx <= 0.0 or ry < 0.0:
		return
	var n := clampi(int(maxf(rx, ry) * 1.2), 48, 720)
	var pts := PackedVector2Array()
	for i in n + 1:
		var a := TAU * i / n
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	stroke_poly(ci, pts, col, lw, dash)

## A polyline, solid or dashed (dash measured along the path, carried over
## the joints as the canvas does).
static func stroke_poly(ci: CanvasItem, pts: PackedVector2Array, col: Color, lw: float, dash: Array = []) -> void:
	if pts.size() < 2:
		return
	if dash.is_empty():
		ci.draw_polyline(pts, col, lw, true)
		return
	var on: float = dash[0]
	var off: float = dash[1]
	var period := on + off
	var s := 0.0                  # distance along the dash pattern
	for i in pts.size() - 1:
		var a := pts[i]; var b := pts[i + 1]
		var L := a.distance_to(b)
		var t := 0.0
		while t < L - 1e-6:
			var ph := fmod(s, period)
			var seg: float
			if ph < on:
				seg = minf(on - ph, L - t)
				ci.draw_line(a.lerp(b, t / L), a.lerp(b, (t + seg) / L), col, lw, true)
			else:
				seg = minf(period - ph, L - t)
			t += seg; s += seg

static func stroke_line(ci: CanvasItem, a: Vector2, b: Vector2, col: Color, lw := 1.0, dash: Array = []) -> void:
	stroke_poly(ci, PackedVector2Array([a, b]), col, lw, dash)

static func fill_circle(ci: CanvasItem, c: Vector2, r: float, col: Color) -> void:
	if r <= 0.0:
		return
	ci.draw_circle(c, r, col, true, -1.0, true)

# ============================================================================
# THE DIAGRAM
# ----------------------------------------------------------------------------
# draw(canvas, structure) — one call, repeated whenever the body changes. Here
# it draws onto any CanvasItem, in a W × H bitmap frame.
# ============================================================================
static func draw_cross_section(ci: CanvasItem, W: float, H: float, st: Dictionary, opts: Dictionary = {}) -> void:
	if st.is_empty():
		return
	var layers: Array = st.get("layers", [])
	if layers.is_empty():
		fill_text(ci, "no interior to show", 14, 24, 12, Color8(150, 170, 200, 153))
		return

	# Layout: the body occupies a disc on the left, labels stack down the right.
	var padL := 10.0; var padT := 26.0; var padB := 34.0
	var labelW := minf(178.0, W * 0.42)
	var discW := W - labelW - padL - 12.0
	var R := minf(discW / 2.0, (H - padT - padB) / 2.0)
	var cx := padL + R; var cy := padT + R
	var is_bh: bool = st.get("type") == "bh"

	# --- title
	var title = opts.get("title")
	if title == null or str(title) == "": title = st.get("label", "")
	fill_text(ci, str(title if title != null else ""), padL, 14, 12, HudTheme.hexc(0xcfe0ff), "left", "alphabetic", 600)

	# Radial scale: layer r0/r1 are fractions of the body's own radius, so the
	# disc is drawn to fill R and the scale bar underneath carries the units.
	var rr := func(f: float) -> float: return maxf(f, 0.0) * R

	# --- filled layers, outermost first so the inner ones land on top
	for i in range(layers.size() - 1, -1, -1):
		var L: Dictionary = layers[i]
		var col := Color(6 / 255.0, 7 / 255.0, 12 / 255.0) if (num(L.get("T")) == 0.0 and is_bh) else temp_color(L.get("T"))
		fill_circle(ci, Vector2(cx, cy), rr.call(num(L.get("r1"))), col)
	# boundaries
	for L in layers:
		stroke_ellipse(ci, Vector2(cx, cy), rr.call(num(L.get("r1"))), rr.call(num(L.get("r1"))), Color(0, 0, 0, 0.45), 1.0)

	# --- a black hole's "layers" are not material shells and must not be drawn
	# as if they were: the horizon, photon sphere and ISCO are locations in the
	# spacetime, so they get dashed rings over an unlit interior.
	if is_bh:
		var re := RegEx.create_from_string("(?i)sphere|ISCO|horizon|Ergosphere")
		var rh := RegEx.create_from_string("(?i)horizon")
		for L in layers:
			if re.search(str(L.get("name", ""))) == null: continue
			var r: float = rr.call(num(L.get("r1")))
			var c := Color8(255, 220, 150, 242) if rh.search(str(L.get("name", ""))) != null else Color8(120, 190, 255, 191)
			stroke_ellipse(ci, Vector2(cx, cy), r, r, c, 1.4, [4.0, 4.0])

	# --- rotational flattening, shown honestly: if the body is oblate, outline
	# the true shape over the (circular) layer diagram. The layers themselves are
	# drawn round because their published radii are means; the outline is the
	# measured shape, and the gap between them is the point.
	var fl := num(st.get("flattening"))
	if fl > 0.01:
		stroke_ellipse(ci, Vector2(cx, cy), R, R * (1.0 - fl), Color8(120, 220, 255, 217), 1.2, [3.0, 3.0])
		fill_text(ci, "true shape · f = %s" % U.fixed(fl, 3), padL, cy + R + 13, 9, Color8(120, 220, 255, 230))

	# --- labels down the right, with leader lines to the mid-radius of the layer
	var lx := W - labelW + 4.0
	var rows := layers.size()
	var rowH := minf(26.0, (H - padT - 8.0) / rows)
	var radius_au := num(st.get("radiusAU"))
	for i in rows:
		var L: Dictionary = layers[i]
		var y := padT + rowH * (i + 0.5)
		var mid := (num(L.get("r0")) + num(L.get("r1"))) / 2.0
		# leader: from the layer's mid-radius on the diagram's upper-right diagonal
		var th := -PI * 0.5 + (i + 0.5) / rows * PI * 0.98
		var p := Vector2(cx + cos(th) * rr.call(mid), cy + sin(th) * rr.call(mid))
		ci.draw_line(p, Vector2(lx - 8.0, y), Color8(150, 175, 210, 77), 1.0, true)
		fill_circle(ci, p, 1.8, Color8(190, 215, 255, 204))

		# swatch
		ci.draw_rect(Rect2(lx, y - 5.0, 8.0, 10.0), temp_color(L.get("T")))
		ci.draw_rect(Rect2(lx + 0.5, y - 4.5, 7.0, 9.0), Color(0, 0, 0, 0.5), false, 1.0)

		fill_text(ci, str(L.get("name", "")), lx + 13.0, y - 4.0, 10, HudTheme.hexc(0xdbe6f5), "left", "middle")
		var T := num(L.get("T"))
		var r_txt := fmt_length(num(L.get("r1")) * radius_au) if radius_au > 0.0 else "%s%%" % U.fixed(num(L.get("r1")) * 100.0, 0)
		fill_text(ci, r_txt + (" · " + fmt_temp(T) if T > 0.0 and is_finite(T) else ""), lx + 13.0, y + 6.0, 9,
			Color8(150, 175, 210, 191), "left", "middle")

	# --- scale bar under the disc: how big the whole thing actually is
	var barY := H - 14.0
	var bc := Color8(190, 210, 240, 128)
	ci.draw_line(Vector2(cx - R, barY), Vector2(cx + R, barY), bc, 1.0, true)
	ci.draw_line(Vector2(cx - R, barY - 3.0), Vector2(cx - R, barY + 3.0), bc, 1.0, true)
	ci.draw_line(Vector2(cx + R, barY - 3.0), Vector2(cx + R, barY + 3.0), bc, 1.0, true)
	var label := "ISCO %s across" % fmt_length(num(st.get("iscoAU")) * 2.0) if is_bh else "%s across" % fmt_length(radius_au * 2.0)
	fill_text(ci, label, cx, barY - 6.0, 9, Color8(190, 210, 240, 204), "center")

# ----------------------------------------------------------------------------
# The temperature legend, drawn once into its own small canvas.
# ----------------------------------------------------------------------------
static func draw_temp_legend(ci: CanvasItem, W: float, H: float) -> void:
	var barH := 9.0
	for x in int(W):
		var logT := 2.0 + (x / W) * 8.0             # 100 K … 1e10 K
		ci.draw_rect(Rect2(x, 0, 1, barH), temp_color(pow(10.0, logT)))
	var col := Color8(150, 175, 210, 204)
	var ticks := [[2.0, "100 K"], [3.76, "5.8 kK"], [7.2, "16 MK"], [10.0, "10 GK"]]
	for tk in ticks:
		var x: float = (float(tk[0]) - 2.0) / 8.0 * W
		ci.draw_rect(Rect2(minf(x, W - 1.0), barH, 1, 3), col)
		var al := "left" if x < W * 0.2 else ("right" if x > W * 0.8 else "center")
		fill_text(ci, tk[1], minf(maxf(x, 1.0), W - 1.0), barH + 12.0, 8, col, al)

# ============================================================================
# The canvases as El nodes: `width: 100%; height: auto` over a W × H bitmap.
#
# The web RASTERISED each diagram at its bitmap size and the compositor then
# scaled the finished bitmap into the CSS box (330 → 314 px here, 300 → 266 in
# the Foundry). That resampling is part of how the page looks — a 1 px canvas
# line becomes a 0.95 px soft one, 9 px canvas text is slightly blurred — so
# it is reproduced rather than drawn around: the diagram is painted into a
# SubViewport of exactly the bitmap's size, only when it changes, and that
# texture is drawn into the content box with linear filtering. A 2D viewport
# with a transparent background stores colour premultiplied by the blend, so
# the texture is composited with a premultiplied-alpha material.
# ============================================================================
class BitmapCanvas extends El:
	var bw := 300.0
	var bh := 230.0
	var _vp: SubViewport
	var _painter: _Painter
	var _tex: TextureRect

	func _init(w: float, h: float, style: Dictionary = {}) -> void:
		bw = w; bh = h
		var s := {"aspect": h / w}
		s.merge(style, true)
		super(s)
		_vp = SubViewport.new()
		_vp.transparent_bg = true
		_vp.disable_3d = true
		_vp.size = Vector2i(int(w), int(h))
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		_painter = _Painter.new()
		_painter.owner_canvas = self
		_painter.size = Vector2(w, h)
		_vp.add_child(_painter)
		add_child(_vp, false, Node.INTERNAL_MODE_BACK)
		_tex = TextureRect.new()
		_tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_tex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_tex.stretch_mode = TextureRect.STRETCH_SCALE
		_tex.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
		_tex.texture = _vp.get_texture()
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
		_tex.material = m
		add_child(_tex, false, Node.INTERNAL_MODE_BACK)

	func set_bitmap(w: float, h: float) -> void:
		bw = w; bh = h
		_vp.size = Vector2i(int(w), int(h))
		_painter.size = Vector2(w, h)
		set_style({"aspect": h / w})
		repaint()

	## The drawing changed: paint the bitmap again (once).
	func repaint() -> void:
		_painter.queue_redraw()
		_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		queue_redraw()

	## The content box (inside the border).
	func inner() -> Rect2:
		return Rect2(Vector2(gf("bl"), gf("bt")), size - Vector2(gf("bl") + gf("br"), gf("bt") + gf("bb")))

	func _draw_extra() -> void:
		# the bitmap's box, snapped to device pixels as the compositor does
		var r := _snap(inner())
		_tex.position = r.position
		_tex.size = r.size

	## Override: draw onto `ci` in bitmap px.
	func _paint(_ci: CanvasItem) -> void:
		pass

	## Local point → bitmap px, as the web's pick() does it: against the
	## element's border box (getBoundingClientRect), not its content box.
	func to_bitmap(p: Vector2) -> Vector2:
		return Vector2(p.x * bw / maxf(size.x, 1.0), p.y * bh / maxf(size.y, 1.0))

class _Painter extends Control:
	var owner_canvas: BitmapCanvas
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
	func _draw() -> void:
		if owner_canvas:
			owner_canvas._paint(self)

class XsecCanvas extends BitmapCanvas:
	var st: Dictionary = {}
	var opts: Dictionary = {}
	func _init(w := 330.0, h := 260.0, style: Dictionary = {}) -> void:
		super(w, h, style)
	func set_structure(structure: Dictionary, o: Dictionary = {}) -> void:
		st = structure; opts = o
		repaint()
	func _paint(ci: CanvasItem) -> void:
		CrossSection.draw_cross_section(ci, bw, bh, st, opts)

class LegendCanvas extends BitmapCanvas:
	func _init(w := 330.0, h := 26.0, style: Dictionary = {}) -> void:
		super(w, h, style)
		repaint()
	func _paint(ci: CanvasItem) -> void:
		CrossSection.draw_temp_legend(ci, bw, bh)
