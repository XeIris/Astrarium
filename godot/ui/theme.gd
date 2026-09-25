class_name HudTheme
extends RefCounted

# ============================================================================
# THE HUD's LOOK, FROM THE CSS's OWN VARIABLES
# ----------------------------------------------------------------------------
# Every colour here is a `:root` variable of blackhole_sim.css, used DIRECTLY.
# A CSS colour is sRGB and so is a Godot Color drawn by a Control (the 2D
# canvas is not colour-managed), so `#ff8c42` is Color8(0xff, 0x8c, 0x42) and
# nothing is converted — PORT_GUIDE.md §5. The only linear colours the HUD ever
# sees are the ones the SIM computes (a sun's blackbody colour), and those are
# converted at the one place they cross over (the sun-list dot).
#
# The fonts are the CSS stacks, resolved the way the browser resolves them.
# Measured, not assumed: on the machine this was written on, Chrome renders
# `'JetBrains Mono', 'SF Mono', 'Menlo', monospace` as Menlo (the installed
# JetBrains font is the Nerd-font family, under a different name, and SF Mono
# is not exposed to applications), and Godot's SystemFont resolves the same
# stack to the same Menlo. The display stack ends in `system-ui`, which Godot
# does not know — asked for it, it hands back an arbitrary face — so it is
# spelled `.AppleSystemUIFont` here, which is what system-ui IS on macOS.
#
# FONT METRICS ARE CHROME'S, NOT GODOT'S. Every line box in the HUD is sized
# from them, so they decide where every panel ends:
#   * `line-height: normal` is round(ascent) + round(descent) at the used size
#     (Blink rounds the two separately): Menlo at 10px is 9 + 2 = 11, at 11px
#     10 + 3 = 13. Godot's own get_height() rounds up and gives 14 at 11px.
#   * advances are taken at 1000 px and scaled, so a 9.5px glyph advances
#     exactly 9.5 × its em advance. Godot quantises advances at small sizes,
#     which over a 40-character line drifts by several pixels.
# ============================================================================

# ---- :root
const BG := Color(0x05 / 255.0, 0x06 / 255.0, 0x0a / 255.0)
const PANEL := Color(10 / 255.0, 12 / 255.0, 18 / 255.0, 0.82)
const BORDER := Color(180 / 255.0, 200 / 255.0, 230 / 255.0, 0.12)
const BORDER_STRONG := Color(180 / 255.0, 200 / 255.0, 230 / 255.0, 0.3)
const TEXT := Color(0xc8 / 255.0, 0xd0 / 255.0, 0xdc / 255.0)
const TEXT_DIM := Color(0x6a / 255.0, 0x73 / 255.0, 0x82 / 255.0)
const ACCENT := Color(0xff / 255.0, 0x8c / 255.0, 0x42 / 255.0)
const ACCENT_2 := Color(0x4e / 255.0, 0xa8 / 255.0, 0xff / 255.0)
const WARN := Color(0xff / 255.0, 0x4e / 255.0, 0x6b / 255.0)
const CLEAR := Color(0, 0, 0, 0)

const MONO_STACK := ["JetBrains Mono", "SF Mono", "Menlo", "monospace"]
# 'Neue Haas Grotesk Display Pro', 'Inter', system-ui, sans-serif
const DISPLAY_STACK := ["Neue Haas Grotesk Display Pro", "Inter", ".AppleSystemUIFont", "sans-serif"]
# A <button>'s own UA font (`font: -webkit-small-control`) — system-ui.
const SYSTEM_STACK := [".AppleSystemUIFont", "sans-serif"]

static func rgba(r: int, g: int, b: int, a: float = 1.0) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, a)

static func hexc(h: int, a: float = 1.0) -> Color:
	return Color((h >> 16 & 255) / 255.0, (h >> 8 & 255) / 255.0, (h & 255) / 255.0, a)

# ---- fonts --------------------------------------------------------------------
static var _fonts := {}
## Stem dilation matching CoreText's (see font()).
static var EMBOLDEN := 0.3
static var _adv := {}
static var _met := {}
static var _metric := {}

## THE SYSTEM FACE HAS AN OPTICAL SIZE. SF Pro is one variable font with an
## `opsz` axis (17–96, default 28), and CoreText — which Chrome draws
## system-ui with — sets that axis to the point size and then applies the
## face's size-specific TRACKING (the `trak` table: 0 at 12 pt, −0.08 at 13,
## −0.31 at 16, −0.43 at 17). Below 20 px the result is the wider "Text"
## design; Godot's SystemFont gives the opsz-28 "Display" one at every size,
## which set the lesson card's 13.5 px prose 11% narrower than the page
## (measured: 489 px against 548 for the same line). So for the display
## family at a small size, the face carries opsz and the run carries the
## tracking, as extra letter-spacing (tracking()). At 20 px and above
## nothing changes — the start screen's 30 px title is Display in both.
const TRAK := [[12.0, 0.0], [13.0, -0.08], [14.0, -0.15], [15.0, -0.23], [16.0, -0.31], [17.0, -0.43], [19.99, -0.45]]

static func font_sized(ff: String, fw: int, fi: bool, fs: float) -> Font:
	if ff != "disp" or fs >= 20.0:
		return font(ff, fw, fi)
	var opsz := maxf(fs, 17.0)
	var key := "%s/%d/%s/opsz%.2f" % [ff, fw, fi, opsz]
	if _fonts.has(key):
		return _fonts[key]
	var base: FontVariation = font(ff, fw, fi)
	var ts := TextServerManager.get_primary_interface()
	var axes := {ts.name_to_tag("opsz"): opsz, ts.name_to_tag("wght"): fw}
	var fv: FontVariation = base.duplicate()
	fv.variation_opentype = axes
	var mv := FontVariation.new()
	mv.base_font = _metric["%s/%d/%s" % [ff, fw, fi]]
	mv.variation_opentype = axes
	_fonts[key] = fv
	_metric[fv.get_instance_id()] = mv
	_kerned[fv.get_instance_id()] = true
	return fv

## KERNING, for the same faces. Blink shapes a run through HarfBuzz/CoreText
## and applies the font's pair kerning; the HUD's per-character layout sums
## bare advances, which is exact for the monospaced face (it has no kerning)
## and 1.6 px too wide over a 97-character line of the lesson card's prose —
## enough to push the last word of a line that fits in Chrome onto the next.
## So the optical-size display faces (and only they: nothing else in the HUD
## changes) add each pair's kerning, measured by shaping the pair on the
## metric face and taking away the two advances, in em, cached per pair.
static var _kerned := {}
static var _kern := {}

static func kern_em(f: Font, a: int, b: int) -> float:
	var fid := f.get_instance_id()
	if not _kerned.has(fid):
		return 0.0
	var tbl: Dictionary = _kern.get(fid, {})
	if tbl.is_empty():
		_kern[fid] = tbl
	var key := a * 0x110000 + b
	if tbl.has(key):
		return tbl[key]
	var mf: Font = _metric.get(fid, f)
	var pair := String.chr(a) + String.chr(b)
	var k := mf.get_string_size(pair, HORIZONTAL_ALIGNMENT_LEFT, -1, 1000).x / 1000.0 - adv_em(f, a) - adv_em(f, b)
	# a shaping artefact (a ligature, a mark) is not kerning; real pair
	# kerning in a text face is a few hundredths of an em
	if absf(k) > 0.25: k = 0.0
	tbl[key] = k
	return k

## Extra letter-spacing, px, that CoreText's tracking adds at this size.
static func tracking(ff: String, fs: float) -> float:
	if ff != "disp" or fs >= 20.0:
		return 0.0
	if fs <= TRAK[0][0]:
		return TRAK[0][1]
	for i in TRAK.size() - 1:
		if fs <= TRAK[i + 1][0]:
			var t: float = (fs - TRAK[i][0]) / (TRAK[i + 1][0] - TRAK[i][0])
			return lerpf(TRAK[i][1], TRAK[i + 1][1], t)
	return TRAK[-1][1]

## A font for a CSS family key ("mono" | "disp" | "sys"), weight and style.
static func font(ff: String, fw: int = 400, fi: bool = false) -> Font:
	var key := "%s/%d/%s" % [ff, fw, fi]
	if _fonts.has(key):
		return _fonts[key]
	var sf := SystemFont.new()
	match ff:
		"disp": sf.font_names = PackedStringArray(DISPLAY_STACK)
		"sys": sf.font_names = PackedStringArray(SYSTEM_STACK)
		# the face Chrome falls back to for ◂/▸ in a system-font button; Godot's
		# system font claims to have those glyphs and draws them a third the size
		"lucida": sf.font_names = PackedStringArray(["Lucida Grande"])
		_: sf.font_names = PackedStringArray(MONO_STACK)
	sf.font_weight = fw
	sf.font_italic = fi
	# CoreText, which Chrome draws with, does not hint; and a glyph that is
	# placed at a fractional x has to be rasterised there to stay put.
	sf.hinting = TextServer.HINTING_NONE
	sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_ONE_QUARTER
	sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	sf.generate_mipmaps = true
	# Glyph fallback in the order Chrome's (measured): SF has no ◂/▸ and the
	# browser takes them from Lucida Grande, not from wherever the OS's own
	# fallback walk happens to land first.
	# Metrics and advances are read from the face WITHOUT its fallbacks: a
	# Font's ascent is the largest over its whole fallback chain, and Lucida's
	# would make every Menlo line a pixel taller than Blink's.
	_metric[key] = sf.duplicate()
	var fb := SystemFont.new()
	fb.font_names = PackedStringArray(["Menlo", "Apple Symbols"] if ff == "lucida" else ["Lucida Grande", "Apple Symbols"])
	fb.hinting = TextServer.HINTING_NONE
	fb.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_ONE_QUARTER
	sf.fallbacks = [fb]
	# CoreText dilates glyph stems a little on the Mac (the "font smoothing"
	# Chrome inherits), so the same face rasterised plainly reads a shade
	# thinner and dimmer than the page. A small embolden is that dilation.
	var fv := FontVariation.new()
	fv.base_font = sf
	fv.variation_embolden = EMBOLDEN
	# Menlo is one file with four faces and SystemFont does not select the
	# bold or italic one by weight, so those two are synthesised — a face the
	# browser has and this does not; the advances are identical either way.
	if ff == "mono" and fw >= 600:
		fv.variation_embolden = EMBOLDEN + 0.55
	if ff == "mono" and fi:
		fv.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.2, 1), Vector2.ZERO)
	var f: Font = fv
	_fonts[key] = f
	_metric[f.get_instance_id()] = _metric[key]
	return f

## Advance of one character, in em (measured at 1000 px).
static func adv_em(f: Font, ch: int) -> float:
	var fid := f.get_instance_id()
	var tbl: Dictionary = _adv.get(fid, {})
	if tbl.is_empty():
		_adv[fid] = tbl
	if tbl.has(ch):
		return tbl[ch]
	# measured on the undilated face: emboldening widens the advance, and the
	# dilation is a rendering effect, not a metric one
	var mf: Font = _metric.get(f.get_instance_id(), f)
	var a := mf.get_char_size(ch, 1000).x / 1000.0
	if a <= 0.0 or not mf.has_char(ch):
		a = f.get_char_size(ch, 1000).x / 1000.0
	tbl[ch] = a
	return a

## [ascent_em, descent_em] (hhea, as CoreText reports it).
static func metrics(f: Font) -> Vector2:
	var id := f.get_instance_id()
	if _met.has(id):
		return _met[id]
	var mf: Font = _metric.get(f.get_instance_id(), f)
	var m := Vector2(mf.get_ascent(1000) / 1000.0, mf.get_descent(1000) / 1000.0)
	_met[id] = m
	return m

## Blink's rounded ascent and descent at a used size, in px.
static func asc_desc(f: Font, size: float) -> Vector2:
	var m := metrics(f)
	return Vector2(roundf(m.x * size), roundf(m.y * size))

## Width of a string as Blink lays it out: em advances × size, plus the
## letter-spacing after EVERY character (Blink adds it after the last too).
static func text_w(f: Font, s: String, size: float, ls: float) -> float:
	var w := 0.0
	var kerned := _kerned.has(f.get_instance_id())
	for i in s.length():
		w += adv_em(f, s.unicode_at(i)) * size + ls
		if kerned and i + 1 < s.length():
			w += kern_em(f, s.unicode_at(i), s.unicode_at(i + 1)) * size
	return w

# ---- the Godot Theme, for the few stock Controls the HUD uses ---------------
static var _theme: Theme = null

static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font("mono")
	t.default_font_size = 12
	# Native tooltips are the browser's `title` attribute; they are the one part
	# of the page the browser styles itself, so they take the panel look here.
	var tip := StyleBoxFlat.new()
	tip.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	tip.border_color = BORDER_STRONG
	tip.set_border_width_all(1)
	tip.set_content_margin_all(6)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font("font", "TooltipLabel", font("mono"))
	t.set_font_size("font_size", "TooltipLabel", 10)
	# The scenario search box: the field itself is drawn by its El wrapper
	# (border, focus ring), the LineEdit only carries the caret and the text.
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "focus", "read_only"]:
		t.set_stylebox(s, "LineEdit", empty)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_DIM, 0.85))
	t.set_color("caret_color", "LineEdit", TEXT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT_2, 0.35))
	t.set_font("font", "LineEdit", font("mono"))
	t.set_font_size("font_size", "LineEdit", 10)
	t.set_constant("minimum_character_width", "LineEdit", 0)
	_theme = t
	return t
