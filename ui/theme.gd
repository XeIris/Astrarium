class_name HudTheme
extends RefCounted

# THE HUD'S LOOK: colour tokens, faces, text styles and the Godot Theme every panel
# uses. Control colours are sRGB, so nothing is converted (docs/godot.md); the only
# linear colours are sim-computed ones, converted where they cross (the sun dot).
#
# Faces are the design's stacks resolved as CoreText does: mono is Menlo, and
# `system-ui` is spelled `.AppleSystemUIFont`. Godot font sizes are whole px, so a
# 9.5 px style draws at 9 px (px()); its line box keeps the design's height (text_font).

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
const DISPLAY_STACK := ["Neue Haas Grotesk Display Pro", "Inter", ".AppleSystemUIFont", "sans-serif"]
const SYSTEM_STACK := [".AppleSystemUIFont", "sans-serif"]

static func rgba(r: int, g: int, b: int, a: float = 1.0) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, a)

static func hexc(h: int, a: float = 1.0) -> Color:
	return Color((h >> 16 & 255) / 255.0, (h >> 8 & 255) / 255.0, (h & 255) / 255.0, a)

## The Blink brightness(1.12) filter the course's filled buttons use on hover.
static func bright(c: Color) -> Color:
	return Color(minf(c.r * 1.12, 1.0), minf(c.g * 1.12, 1.0), minf(c.b * 1.12, 1.0), c.a)

## Whole-px font size for a design size. From 9.5 px up it rounds down, so a label
## sized to fit its box still fits (a wider face would wrap it); below, it rounds
## to stay legible.
static func px(fs: float) -> int:
	return int(fs) if fs >= 9.5 else int(fs + 0.5)

# ---- faces ----------------------------------------------------------------------
static var _fonts := {}
## A small embolden matches CoreText's stem dilation.
static var EMBOLDEN := 0.3
static var _adv := {}
static var _met := {}
static var _metric := {}

## The system face has an optical-size axis that CoreText sets to the point size,
## plus a tracking table; SystemFont gives opsz 28 at every size, 11% narrow for
## 13.5 px prose. So below 20 px the face carries opsz and the run the tracking.
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

## Pair kerning of the display face, in em: shaping each pair on the metric face
## less the two advances. (Menlo has none.)
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

## A face for a family key ("mono" | "disp" | "sys" | "lucida"), weight and style.
static func font(ff: String, fw: int = 400, fi: bool = false) -> Font:
	var key := "%s/%d/%s" % [ff, fw, fi]
	if _fonts.has(key):
		return _fonts[key]
	var sf := SystemFont.new()
	match ff:
		"disp": sf.font_names = PackedStringArray(DISPLAY_STACK)
		"sys": sf.font_names = PackedStringArray(SYSTEM_STACK)
		# Godot's system font claims ◂/▸ and draws them a third the size
		"lucida": sf.font_names = PackedStringArray(["Lucida Grande"])
		_: sf.font_names = PackedStringArray(MONO_STACK)
	sf.font_weight = fw
	sf.font_italic = fi
	sf.hinting = TextServer.HINTING_NONE
	sf.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_ONE_QUARTER
	sf.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	sf.generate_mipmaps = true
	# Metrics come from the face without fallbacks, or Lucida's ascent makes Menlo
	# lines a pixel taller.
	_metric[key] = sf.duplicate()
	var fb := SystemFont.new()
	fb.font_names = PackedStringArray(["Menlo", "Apple Symbols"] if ff == "lucida" else ["Lucida Grande", "Apple Symbols"])
	fb.hinting = TextServer.HINTING_NONE
	fb.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_ONE_QUARTER
	sf.fallbacks = [fb]
	var fv := FontVariation.new()
	fv.base_font = sf
	fv.variation_embolden = EMBOLDEN
	# Menlo's bold and italic are synthesised (SystemFont won't select them).
	if ff == "mono" and fw >= 600:
		fv.variation_embolden = EMBOLDEN + 0.55
	if ff == "mono" and fi:
		fv.variation_transform = Transform2D(Vector2(1, 0), Vector2(-0.2, 1), Vector2.ZERO)
	_fonts[key] = fv
	_metric[fv.get_instance_id()] = _metric[key]
	return fv

## Advance of one character, in em, on the undilated face (canvas text).
static func adv_em(f: Font, ch: int) -> float:
	var fid := f.get_instance_id()
	var tbl: Dictionary = _adv.get(fid, {})
	if tbl.is_empty():
		_adv[fid] = tbl
	if tbl.has(ch):
		return tbl[ch]
	var mf: Font = _metric.get(fid, f)
	var a := mf.get_char_size(ch, 1000).x / 1000.0
	if a <= 0.0 or not mf.has_char(ch):
		a = f.get_char_size(ch, 1000).x / 1000.0
	tbl[ch] = a
	return a

## [ascent_em, descent_em] as CoreText reports them (hhea).
static func metrics(f: Font) -> Vector2:
	var id := f.get_instance_id()
	if _met.has(id):
		return _met[id]
	var mf: Font = _metric.get(id, f)
	var m := Vector2(mf.get_ascent(1000) / 1000.0, mf.get_descent(1000) / 1000.0)
	_met[id] = m
	return m

## Rounded ascent and descent at a size, px: `line-height: normal` is their sum.
static func asc_desc(f: Font, size: float) -> Vector2:
	var m := metrics(f)
	return Vector2(roundf(m.x * size), roundf(m.y * size))

## Width of a canvas string: em advances × size plus letter-spacing per character.
static func text_w(f: Font, s: String, size: float, ls: float) -> float:
	var w := 0.0
	var kerned := _kerned.has(f.get_instance_id())
	for i in s.length():
		w += adv_em(f, s.unicode_at(i)) * size + ls
		if kerned and i + 1 < s.length():
			w += kern_em(f, s.unicode_at(i), s.unicode_at(i + 1)) * size
	return w

# ---- text styles ------------------------------------------------------------------
# A text style is {ff, fw, fi, fs, c, ls (px), lh (-1 normal, ≤ 8 a multiple, else
# px), up}; missing keys take DEFAULT.
const DEFAULT := {"ff": "mono", "fw": 400, "fi": false, "fs": 12.0, "c": TEXT, "ls": 0.0, "lh": -1.0, "up": false}

static func style(s: Dictionary) -> Dictionary:
	var o := DEFAULT.duplicate()
	o.merge(s, true)
	return o

## Line-box height of a style, px.
static func line_h(s: Dictionary) -> float:
	var st := style(s)
	var ad := asc_desc(font(st.ff, st.fw, st.fi), st.fs)
	var lh: float = st.lh
	if lh < 0.0: return ad.x + ad.y
	if lh > 8.0: return lh
	return lh * float(st.fs)

## A face at one size whose lines are the style's line box, with the glyphs on the
## baseline half-leading places them at, and letter-spacing as glyph spacing.
static func text_font(s: Dictionary) -> Font:
	var st := style(s)
	var fs: float = st.fs
	var ls: float = float(st.ls) + tracking(st.ff, fs)
	var key := "t/%s/%d/%s/%.3f/%.3f/%.3f" % [st.ff, st.fw, st.fi, fs, ls, st.lh]
	if _fonts.has(key):
		return _fonts[key]
	var base: FontVariation = font_sized(st.ff, st.fw, st.fi, fs)
	var ad := asc_desc(font(st.ff, st.fw, st.fi), fs)
	var L := roundf(line_h(st))
	var size := px(fs)
	var ga := base.get_ascent(size)
	var gd := base.get_descent(size)
	# A variation over a variation drops the inner one's settings, so this one
	# carries the face's own (embolden, slant, optical size) over the system font.
	var fv := FontVariation.new()
	fv.base_font = base.base_font
	fv.variation_embolden = base.variation_embolden
	fv.variation_transform = base.variation_transform
	fv.variation_opentype = base.variation_opentype
	fv.spacing_glyph = int(roundf(ls))
	fv.spacing_top = int(roundf((L - ad.x - ad.y) * 0.5 + ad.x - ga))
	fv.spacing_bottom = int(L - ga - gd) - fv.spacing_top
	_fonts[key] = fv
	return fv

static var _label_settings := {}

## A LabelSettings for a style, shared by every label in that style.
static func label_settings(s: Dictionary) -> LabelSettings:
	var st := style(s)
	var key := var_to_str([st.ff, st.fw, st.fi, st.fs, st.c, st.ls, st.lh])
	if _label_settings.has(key):
		return _label_settings[key]
	var ls := LabelSettings.new()
	ls.font = text_font(st)
	ls.font_size = px(st.fs)
	ls.font_color = st.c
	ls.line_spacing = 0.0
	_label_settings[key] = ls
	return ls

## Style a Label in place.
static func apply_label(l: Label, s: Dictionary) -> void:
	var st := style(s)
	l.label_settings = label_settings(st)
	l.uppercase = st.up

# ---- button and box kinds ----------------------------------------------------------
# Each kind is a Theme type variation (and "<kind>On" for its active state) over
# Button, PanelContainer and the composite BoxButton: base, hover and on are
# overrides of {bg, bc (border), bw, rad, pad [t, r, b, l], c}; text keys as above;
# `up` uppercases (Button has no text-transform); `wrap` breaks the text to the
# button's width. Hover over an active control is
# base + hover + on, as the cascade gives it.
static var KINDS := {
	"PanelClose": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [2, 4, 2, 4], "fs": 12.0, "lh": 1.0}, "hover": {"c": WARN}},
	"Ghost": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [7, 7, 7, 7], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}},
	"Action": {"base": {"c": WARN, "bc": WARN, "pad": [8, 8, 8, 8], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"bg": WARN, "c": Color.BLACK}},
	"Toggle": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [7, 8, 7, 8], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT, "c": Color.BLACK, "bc": ACCENT}},
	"ToggleIcon": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [5, 8, 5, 8], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT, "c": Color.BLACK, "bc": ACCENT}},
	# `.toggle-btn.on` has no rule: the model viewer's toggles look the same either way
	"ToggleFlat": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [7, 8, 7, 8], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {}},
	"Band": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [7, 2, 7, 2], "fs": 9.0, "ls": 0.54},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT_2, "c": Color.BLACK, "bc": ACCENT_2}},
	"TimeBtn": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [6, 2, 6, 2], "fs": 9.5, "ls": 0.57},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT_2, "c": Color.BLACK, "bc": ACCENT_2}},
	"Add": {"base": {"c": TEXT, "bc": BORDER_STRONG, "pad": [10, 6, 10, 6], "fs": 10.0, "ls": 0.8, "up": true},
		"hover": {"c": ACCENT, "bc": ACCENT}},
	"SetTab": {"base": {"bg": Color(1, 1, 1, 0.03), "c": TEXT_DIM, "bc": BORDER, "pad": [5, 0, 5, 0], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT}, "on": {"c": ACCENT, "bc": ACCENT, "bg": Color(1, 1, 1, 0.06)}},
	"PanelTab": {"base": {"bg": PANEL, "c": TEXT_DIM, "bc": BORDER, "pad": [8, 10, 8, 10], "fs": 10.0, "ls": 1.2, "up": true, "blur": true},
		"hover": {"c": ACCENT, "bc": BORDER_STRONG}},
	"Preset": {"base": {"wrap": true, "c": TEXT_DIM, "bc": BORDER, "pad": [7, 9, 7, 9], "fs": 10.0, "ls": 0.8, "align": "left"},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT_2, "c": Color.BLACK, "bc": ACCENT_2}},
	"PresetTri": {"base": {"wrap": true, "c": hexc(0xffc98a), "bc": rgba(255, 170, 70, 0.4), "pad": [7, 9, 7, 9], "fs": 10.0, "ls": 0.8, "align": "left"},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT, "c": Color.BLACK, "bc": ACCENT}},
	"MvChip": {"base": {"wrap": true, "bg": Color(1, 1, 1, 0.03), "c": TEXT_DIM, "bc": BORDER, "pad": [6, 5, 6, 5], "fs": 9.5, "align": "left"},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"c": ACCENT, "bc": ACCENT, "bg": rgba(255, 140, 66, 0.08)}},
	"Craft": {"base": {"bg": rgba(20, 32, 50, 0.55), "c": TEXT, "bc": rgba(120, 190, 255, 0.22), "rad": 4, "pad": [7, 8, 7, 8], "fs": 10.5, "lh": 1.25},
		"hover": {"bc": ACCENT, "bg": rgba(30, 52, 80, 0.7)}, "on": {"bc": ACCENT, "bg": rgba(40, 80, 120, 0.75)}},
	"Warp": {"base": {"bg": rgba(20, 32, 50, 0.6), "c": hexc(0xcfe6ff), "bc": rgba(120, 190, 255, 0.25), "rad": 3, "pad": [0, 0, 0, 0],
		"ff": "lucida", "fs": 10.0, "lh": 1.0}, "hover": {"bc": ACCENT}},
	"LcNav": {"base": {"c": TEXT, "bc": BORDER_STRONG, "pad": [5, 13, 5, 13], "fs": 11.0}, "hover": {"bc": ACCENT, "c": ACCENT}},
	"LcNext": {"base": {"bg": ACCENT, "c": hexc(0x0a0c12), "bc": ACCENT, "pad": [5, 13, 5, 13], "fs": 11.0}},
	"Clear": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [3, 3, 3, 3], "fs": 10.0, "lh": 1.0}, "hover": {"c": TEXT}},
	"Remove": {"base": {"c": WARN, "bw": 0, "pad": [1, 6, 1, 6], "fs": 12.0, "lh": 12.0}},
	"Solo": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [0, 0, 0, 6], "fs": 9.0, "ls": 0.72, "up": true}, "hover": {"c": ACCENT}},
	"Start": {"base": {"bg": rgba(12, 15, 23, 0.85), "c": TEXT, "bc": BORDER, "pad": [22, 22, 20, 22], "fs": 13.333},
		"hover": {"bc": ACCENT, "bg": rgba(20, 24, 34, 0.9)}},
	# the section heading (.panel h3) and the preset / module accordions
	"SectionHead": {"base": {"c": TEXT_DIM, "bw": 0, "bb": 1, "bc": BORDER, "pad": [0, 0, 6, 0], "fs": 10.0, "ls": 2.0, "up": true, "fw": 500},
		"hover": {"c": ACCENT}},
	"SectionHeadFocus": {"base": {"c": ACCENT_2, "bw": 0, "bb": 1, "bc": BORDER, "pad": [0, 0, 6, 0], "fs": 10.0, "ls": 2.0, "up": true, "fw": 500},
		"hover": {"c": ACCENT}},
	"GroupHead": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [8, 9, 8, 9], "fs": 10.0, "ls": 1.0, "up": true},
		"hover": {"c": TEXT, "bg": rgba(180, 200, 230, 0.06)}, "on": {"c": TEXT, "bg": Color(1, 1, 1, 0.025), "bb": 1, "bc": BORDER}},
	"BodyItem": {"base": {"c": TEXT_DIM, "bw": 0, "bb": 1, "bc": BORDER, "pad": [6, 8, 6, 8], "fs": 10.0},
		"hover": {"bg": rgba(180, 200, 230, 0.06)}, "on": {"bg": rgba(78, 168, 255, 0.12)}},
	"BodyItemLast": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [6, 8, 6, 8], "fs": 10.0},
		"hover": {"bg": rgba(180, 200, 230, 0.06)}, "on": {"bg": rgba(78, 168, 255, 0.12)}},
	# the Foundry
	"FdType": {"base": {"c": TEXT_DIM, "bc": BORDER, "pad": [7, 2, 7, 2], "fs": 8.5, "ls": 0.34},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bc": ACCENT, "c": ACCENT, "bg": rgba(255, 140, 66, 0.08)}},
	"FocusLimit": {"base": {"c": TEXT_DIM, "bc": BORDER_STRONG, "pad": [2, 6, 2, 6], "fs": 9.0, "ls": 0.72},
		"hover": {"c": TEXT, "bc": ACCENT}, "on": {"c": BG, "bg": ACCENT, "bc": ACCENT}},
	# the course
	"Continue": {"base": {"bg": ACCENT, "c": hexc(0x0a0c12), "bw": 0, "pad": [7, 7, 7, 7], "fs": 11.0, "ls": 0.44},
		"hover": {"bg": bright(ACCENT)}},
	"ModHead": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [6, 8, 6, 8], "fs": 11.0},
		"hover": {"c": TEXT, "bg": rgba(180, 200, 230, 0.06)}, "on": {"c": TEXT, "bb": 1, "bc": BORDER}},
	"LessonItem": {"base": {"c": TEXT_DIM, "bc": CLEAR, "pad": [5, 7, 5, 7], "fs": 11.0, "align": "left"},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT_2, "c": Color.BLACK, "bc": ACCENT_2}},
	"LessonDone": {"base": {"c": rgba(143, 224, 192, 0.85), "bc": CLEAR, "pad": [5, 7, 5, 7], "fs": 11.0, "align": "left"},
		"hover": {"c": TEXT, "bc": BORDER_STRONG}, "on": {"bg": ACCENT_2, "c": Color.BLACK, "bc": ACCENT_2}},
	"Reset": {"base": {"c": TEXT_DIM, "bw": 0, "pad": [0, 0, 0, 0], "fs": 9.0, "align": "left"}, "hover": {"c": WARN}},
	"Act": {"base": {"bg": WARN, "c": hexc(0x12070a), "bw": 0, "pad": [6, 14, 6, 14], "fs": 11.0, "ls": 0.44},
		"hover": {"bg": bright(WARN)}},
	# the flight panel
	"FlMode": {"base": {"bg": rgba(20, 32, 50, 0.55), "c": hexc(0xa8c4e0), "bc": rgba(120, 190, 255, 0.2), "rad": 3, "pad": [4, 2, 4, 2], "fs": 9.0, "ls": 0.36},
		"hover": {"bc": ACCENT}, "on": {"bg": rgba(40, 90, 140, 0.85), "c": hexc(0xeaf4ff), "bc": ACCENT}},
	"FlProg": {"base": {"bg": rgba(20, 32, 50, 0.55), "c": hexc(0xcfe6ff), "bc": rgba(120, 190, 255, 0.2), "rad": 3, "pad": [5, 8, 5, 8], "fs": 10.0, "align": "left"},
		"hover": {"bc": ACCENT, "bg": rgba(30, 52, 80, 0.7)}, "on": {"bg": rgba(40, 90, 140, 0.85), "bc": ACCENT}},
	"FlSelect": {"base": {"bg": rgba(12, 20, 32, 0.85), "c": hexc(0xcfe6ff), "bc": rgba(120, 190, 255, 0.22), "rad": 3, "pad": [4, 22, 4, 6], "fs": 10.5, "align": "left"}},
	"FdSelect": {"base": {"bg": rgba(0, 0, 0, 0.4), "c": TEXT, "bc": BORDER, "pad": [4, 26, 4, 6], "fs": 10.0, "lh": 13.0, "align": "left"}},
}

static func kind_up(kind: String) -> bool:
	return bool((KINDS.get(kind, {}).get("base", {}) as Dictionary).get("up", false))

static func kind_align(kind: String) -> HorizontalAlignment:
	var a: String = (KINDS.get(kind, {}).get("base", {}) as Dictionary).get("align", "center")
	return HORIZONTAL_ALIGNMENT_LEFT if a == "left" else HORIZONTAL_ALIGNMENT_CENTER

## The resolved look of a kind in one state: "normal" | "hover" | "on" | "onhover".
static func kind_look(kind: String, state: String) -> Dictionary:
	var k: Dictionary = KINDS[kind]
	var o := {"bg": CLEAR, "bc": BORDER, "bw": 1, "rad": 0, "pad": [0, 0, 0, 0]}
	o.merge(k.base, true)
	if state == "hover" or state == "onhover": o.merge(k.get("hover", {}), true)
	if state == "on" or state == "onhover": o.merge(k.get("on", {}), true)
	return o

static func stylebox(look: Dictionary, blur := false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = CLEAR if blur and HudBlur.enabled else look.get("bg", CLEAR)
	var bw := int(look.get("bw", 1))
	sb.border_color = look.get("bc", BORDER)
	sb.set_border_width_all(bw)
	if look.has("bt"): sb.border_width_top = int(look.bt)
	if look.has("br"): sb.border_width_right = int(look.br)
	if look.has("bb"): sb.border_width_bottom = int(look.bb)
	if look.has("bl"): sb.border_width_left = int(look.bl)
	var pad: Array = look.get("pad", [0, 0, 0, 0])
	sb.content_margin_top = float(pad[0]) + sb.border_width_top
	sb.content_margin_right = float(pad[1]) + sb.border_width_right
	sb.content_margin_bottom = float(pad[2]) + sb.border_width_bottom
	sb.content_margin_left = float(pad[3]) + sb.border_width_left
	var rad := int(look.get("rad", 0))
	if rad > 0:
		sb.set_corner_radius_all(rad)
		sb.corner_detail = 6
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 0.6
	else:
		sb.anti_aliasing = false
	return sb

static func _add_kind(t: Theme, kind: String) -> void:
	var has_on: bool = KINDS[kind].has("on")
	for on in ([false, true] if has_on else [false]):
		var name := kind + ("On" if on else "")
		var normal := kind_look(kind, "on" if on else "normal")
		var hover := kind_look(kind, "onhover" if on else "hover")
		var blur: bool = normal.get("blur", false)
		t.set_type_variation(name, "Button")
		t.set_stylebox("normal", name, stylebox(normal, blur))
		t.set_stylebox("hover", name, stylebox(hover, blur))
		t.set_stylebox("pressed", name, stylebox(hover, blur))
		t.set_stylebox("disabled", name, stylebox(normal, blur))
		t.set_stylebox("focus", name, StyleBoxEmpty.new())
		t.set_stylebox("panel", name, stylebox(normal, blur))
		for sb in ["normal_mirrored", "hover_mirrored", "pressed_mirrored", "disabled_mirrored"]:
			t.set_stylebox(sb, name, stylebox(hover if sb.begins_with("hover") or sb.begins_with("pressed") else normal, blur))
		var f := text_font(normal)
		t.set_font("font", name, f)
		t.set_font_size("font_size", name, px(float(normal.get("fs", 12.0))))
		for c in ["font_color", "font_disabled_color", "font_focus_color"]:
			t.set_color(c, name, normal.c)
		for c in ["font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
			t.set_color(c, name, hover.c)
		t.set_constant("h_separation", name, 0)

# ---- the Theme ------------------------------------------------------------------------
static var _theme: Theme = null

static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = text_font({})
	t.default_font_size = 12
	for k in KINDS:
		_add_kind(t, k)
	t.set_constant("line_spacing", "Label", 0)
	t.set_color("font_color", "Label", TEXT)
	# Tooltips are the one part of the design the browser styled itself; they take
	# the panel look here.
	var tip := StyleBoxFlat.new()
	tip.bg_color = Color(0.04, 0.05, 0.07, 0.96)
	tip.border_color = BORDER_STRONG
	tip.set_border_width_all(1)
	tip.set_content_margin_all(6)
	t.set_stylebox("panel", "TooltipPanel", tip)
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font("font", "TooltipLabel", text_font({"fs": 10.0}))
	t.set_font_size("font_size", "TooltipLabel", 10)
	# the scenario search
	var field := stylebox({"bg": rgba(0, 0, 0, 0.18), "bc": BORDER, "pad": [8, 28, 8, 9]})
	var focus := stylebox({"bg": rgba(0, 0, 0, 0.18), "bc": ACCENT_2, "pad": [8, 28, 8, 9]})
	focus.expand_margin_left = 1; focus.expand_margin_right = 1
	focus.expand_margin_top = 1; focus.expand_margin_bottom = 1
	focus.border_color = ACCENT_2
	for s in ["normal", "read_only"]:
		t.set_stylebox(s, "LineEdit", field)
	t.set_stylebox("focus", "LineEdit", _ring(focus))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("font_placeholder_color", "LineEdit", Color(TEXT_DIM, 0.85))
	t.set_color("caret_color", "LineEdit", TEXT)
	t.set_color("selection_color", "LineEdit", Color(ACCENT_2, 0.35))
	t.set_font("font", "LineEdit", text_font({"fs": 10.0, "ls": 0.4}))
	t.set_font_size("font_size", "LineEdit", 10)
	t.set_constant("minimum_character_width", "LineEdit", 0)
	# scrollbars: a 4 px thumb in border-strong, no track, no arrows
	var thumb := StyleBoxFlat.new()
	thumb.bg_color = BORDER_STRONG
	thumb.content_margin_left = 2; thumb.content_margin_right = 2
	thumb.content_margin_top = 9; thumb.content_margin_bottom = 9
	var track := StyleBoxEmpty.new()
	track.content_margin_left = 2; track.content_margin_right = 2
	for s in ["grabber", "grabber_highlight", "grabber_pressed"]:
		t.set_stylebox(s, "VScrollBar", thumb)
	t.set_stylebox("scroll", "VScrollBar", track)
	t.set_stylebox("scroll_focus", "VScrollBar", track)
	var none := ImageTexture.create_from_image(Image.create(1, 1, false, Image.FORMAT_RGBA8))
	for i in ["increment", "increment_highlight", "increment_pressed", "decrement", "decrement_highlight", "decrement_pressed"]:
		t.set_icon(i, "VScrollBar", none)
	t.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("focus", "ScrollContainer", StyleBoxEmpty.new())
	t.set_stylebox("panel", "PanelContainer", StyleBoxEmpty.new())
	# selects
	for kind in ["FlSelect", "FdSelect"]:
		t.set_type_variation(kind, "OptionButton")
		t.set_icon("arrow", kind, chevron(kind_look(kind, "normal").c))
		t.set_constant("arrow_margin", kind, 7)
		t.set_constant("modulate_arrow", kind, 0)
	var pop := StyleBoxFlat.new()
	pop.bg_color = Color(0.04, 0.05, 0.07, 0.97)
	pop.border_color = BORDER_STRONG
	pop.set_border_width_all(1)
	pop.set_content_margin_all(4)
	t.set_stylebox("panel", "PopupMenu", pop)
	var hov := StyleBoxFlat.new()
	hov.bg_color = Color(ACCENT_2, 0.25)
	t.set_stylebox("hover", "PopupMenu", hov)
	t.set_font("font", "PopupMenu", text_font({"fs": 11.0}))
	t.set_font_size("font_size", "PopupMenu", 11)
	t.set_color("font_color", "PopupMenu", TEXT)
	t.set_color("font_hover_color", "PopupMenu", TEXT)
	_theme = t
	return t

## The focus ring: the accent border plus a 1 px 14% halo outside it.
static func _ring(sb: StyleBoxFlat) -> StyleBoxFlat:
	sb.shadow_color = rgba(78, 168, 255, 0.14)
	sb.shadow_size = 2
	return sb

## A 7 × 4 chevron (1.5 px stroke) for the selects.
static func chevron(col: Color) -> Texture2D:
	var img := Image.create(12, 8, false, Image.FORMAT_RGBA8)
	for y in 8:
		for x in 12:
			# distance to the two strokes of a V from (2.5, 2) through (6, 5.5) to (9.5, 2)
			var p := Vector2(x + 0.5, y + 0.5)
			var d := minf(_seg_d(p, Vector2(2.5, 2.25), Vector2(6, 5.75)), _seg_d(p, Vector2(6, 5.75), Vector2(9.5, 2.25)))
			var a := clampf(1.25 - d, 0.0, 1.0)
			img.set_pixel(x, y, Color(col, col.a * a))
	return ImageTexture.create_from_image(img)

static func _seg_d(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var t := clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)
