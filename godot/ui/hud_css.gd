class_name HudCss
extends RefCounted

# ============================================================================
# blackhole_sim.css, rule by rule, as El style dictionaries.
#
# Keys (see ui/widgets/el.gd): w/h/maxh/minw/maxw px; wp a width fraction;
# m/p shorthands or mt/mr/mb/ml, pt/pr/pb/pl; b [width, colour] or bt/br/bb/bl
# with bct/bcr/bcb/bcl; bg; rad; display block|flex|grid; dir row|column;
# ai/as align-items/-self; jc justify-content; gapc/gapr; cols grid tracks
# (fr > 0, fixed px < 0); grow/shrink/basis; fs ff fw fi c ls lh up ta nw for
# text (these inherit); ib an inline-block (margins do not collapse); fit
# shrink-to-fit width; vc a <button>'s vertically centred content; scroll
# overflow-y:auto; blur a backdrop-filter radius.
#
# letter-spacing is written in em in the CSS and is converted here with the
# element's OWN font size — that is the computed (px) value, and the px value is
# what children inherit.
# ============================================================================

const T = preload("res://ui/theme.gd")

static func em(x: float, fs: float) -> float:
	return x * fs

static func merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate()
	o.merge(b, true)
	return o

## A <button>'s user-agent style, which the page's classes then override: it is
## an inline-block, centres its text both ways, and resets font, letter-spacing,
## text-transform and line-height rather than inheriting them.
static func button(s: Dictionary) -> Dictionary:
	return merge({"ib": true, "fit": true, "ta": "center", "vc": true, "ls": 0.0, "up": false, "lh": -1.0,
		"ff": "sys", "fs": 13.333, "fw": 400, "c": Color.BLACK, "p": [1, 6], "b": [2, T.BORDER],
		"bg": Color(0.94, 0.94, 0.94)}, s)

# ---- panels -----------------------------------------------------------------------
static func panel(w: float) -> Dictionary:
	return {"w": w, "bg": T.PANEL, "b": [1, T.BORDER], "blur": 10.0, "p": 16, "scroll": true, "sbw": 4.0}

## .panel h3 (+ :not(:first-child))
static func h3(first: bool) -> Dictionary:
	return {"fs": 10.0, "ls": em(0.2, 10), "up": true, "c": T.TEXT_DIM, "mb": 10.0, "pb": 6.0,
		"bb": 1.0, "bcb": T.BORDER, "fw": 500, "mt": 0.0 if first else 20.0}

const PANEL_HEAD := {"display": "flex", "ai": "baseline", "jc": "space-between", "gapc": 8.0}

static func panel_close() -> Dictionary:
	return button({"bg": T.CLEAR, "b": [0, T.CLEAR], "c": T.TEXT_DIM, "ff": "mono", "fs": 12.0,
		"lh": 1.0, "p": [2, 4]})
const PANEL_CLOSE_HOVER := {"c": T.WARN}

static func section_note() -> Dictionary:
	return {"fs": 9.5, "c": T.TEXT_DIM, "lh": 1.55, "mb": 10.0}

# ---- rows ---------------------------------------------------------------------------
const ROW := {"display": "flex", "ai": "center", "jc": "space-between", "mb": 10.0, "gapc": 10.0}
const ROW_LABEL := {"fs": 11.0, "c": T.TEXT_DIM, "grow": 0.0, "shrink": 0.0}
const ROW_LABEL_TITLE := {"bb": 1.0, "bcb": T.TEXT_DIM, "bdot": true}
const ROW_VAL := {"fs": 11.0, "c": T.ACCENT, "minw": 60.0, "ta": "right"}
# flex: 1 (basis 0), and the UA's 2px margin all round
const ROW_RANGE := {"grow": 1.0, "shrink": 1.0, "basis": 0.0, "m": 2}

# ---- buttons -------------------------------------------------------------------------
static func ghost_btn() -> Dictionary:
	return button({"wp": 1.0, "bg": T.CLEAR, "c": T.TEXT_DIM, "b": [1, T.BORDER], "p": 7, "ff": "mono",
		"fs": 10.0, "ls": em(0.1, 10), "up": true, "mb": 10.0})
const GHOST_HOVER := {"c": T.TEXT, "bcol": T.BORDER_STRONG}

static func action_btn() -> Dictionary:
	return button({"wp": 1.0, "bg": T.CLEAR, "c": T.WARN, "b": [1, T.WARN], "p": 8, "ff": "mono",
		"fs": 10.0, "ls": em(0.1, 10), "up": true, "mt": 8.0})
const ACTION_HOVER := {"bg": T.WARN, "c": Color.BLACK}

static func toggle_btn() -> Dictionary:
	return button({"bg": T.CLEAR, "c": T.TEXT_DIM, "b": [1, T.BORDER], "p": [7, 8], "ff": "mono",
		"fs": 10.0, "ls": em(0.1, 10), "up": true})
const TOGGLE_HOVER := {"c": T.TEXT, "bcol": T.BORDER_STRONG}
const TOGGLE_ACTIVE := {"bg": T.ACCENT, "c": Color.BLACK, "bcol": T.ACCENT}
const TOGGLE_ROW := {"display": "grid", "cols": [1.0, 1.0], "gapc": 6.0, "gapr": 6.0, "mb": 8.0}

static func band_btn() -> Dictionary:
	return button({"p": [7, 2], "bg": T.CLEAR, "b": [1, T.BORDER], "c": T.TEXT_DIM, "ff": "mono",
		"fs": 9.0, "ls": em(0.06, 9)})
const BLUE_ACTIVE := {"bg": T.ACCENT_2, "c": Color.BLACK, "bcol": T.ACCENT_2}

static func time_btn() -> Dictionary:
	return button({"p": [6, 2], "bg": T.CLEAR, "b": [1, T.BORDER], "c": T.TEXT_DIM, "ff": "mono",
		"fs": 9.5, "ls": em(0.06, 9.5)})

static func add_btn() -> Dictionary:
	return button({"bg": T.CLEAR, "c": T.TEXT, "b": [1, T.BORDER_STRONG], "p": [10, 6], "ff": "mono",
		"fs": 10.0, "ls": em(0.08, 10), "up": true, "display": "flex", "dir": "column", "ai": "center",
		"gapr": 4.0})
const ADD_HOVER := {"bcol": T.ACCENT, "c": T.ACCENT}

static func set_tab() -> Dictionary:
	return button({"grow": 1.0, "basis": 0.0, "bg": Color(1, 1, 1, 0.03), "b": [1, T.BORDER], "c": T.TEXT_DIM,
		"ff": "mono", "fs": 10.0, "ls": em(0.1, 10), "up": true, "p": [5, 0]})
const SET_TAB_ON := {"c": T.ACCENT, "bcol": T.ACCENT, "bg": Color(1, 1, 1, 0.06)}

static func ms_btn() -> Dictionary:
	return button({"bg": Color(1, 1, 1, 0.03), "b": [1, T.BORDER], "c": T.TEXT_DIM, "ff": "mono", "fs": 9.0,
		"ls": em(0.12, 9), "up": true, "p": [4, 9]})
static var MS_ON := {"c": T.hexc(0x0a0c12), "bg": T.ACCENT, "bcol": T.ACCENT}

static func panel_tab() -> Dictionary:
	return button({"bg": T.PANEL, "c": T.TEXT_DIM, "b": [1, T.BORDER], "blur": 10.0, "p": [8, 10],
		"ff": "mono", "fs": 10.0, "ls": em(0.12, 10), "up": true})
const PANEL_TAB_HOVER := {"c": T.ACCENT, "bcol": T.BORDER_STRONG}

static func preset_btn() -> Dictionary:
	return button({"bg": T.CLEAR, "c": T.TEXT_DIM, "b": [1, T.BORDER], "p": [7, 9], "ff": "mono", "fs": 10.0,
		"ls": em(0.08, 10), "ta": "left"})

static func mv_chip() -> Dictionary:
	return button({"bg": Color(1, 1, 1, 0.03), "b": [1, T.BORDER], "c": T.TEXT_DIM, "ff": "mono", "fs": 9.5,
		"p": [6, 5], "ta": "left"})
static var MV_CHIP_ON := {"c": T.ACCENT, "bcol": T.ACCENT, "bg": T.rgba(255, 140, 66, 0.08)}

static func craft_btn() -> Dictionary:
	return button({"display": "flex", "dir": "column", "gapr": 2.0, "ai": "start", "p": [7, 8],
		"b": [1, T.rgba(120, 190, 255, 0.22)], "rad": 4.0, "bg": T.rgba(20, 32, 50, 0.55), "c": T.TEXT,
		"ff": "mono", "fs": 10.5, "ta": "left", "lh": 1.25})
static var CRAFT_HOVER := {"bcol": T.ACCENT, "bg": T.rgba(30, 52, 80, 0.7)}
static var CRAFT_ON := {"bcol": T.ACCENT, "bg": T.rgba(40, 80, 120, 0.75)}

static func warp_btn() -> Dictionary:
	return button({"w": 20.0, "h": 18.0, "b": [1, T.rgba(120, 190, 255, 0.25)], "rad": 3.0,
		"bg": T.rgba(20, 32, 50, 0.6), "c": T.hexc(0xcfe6ff), "fs": 10.0, "lh": 1.0, "p": [1, 6]})

static func lc_nav() -> Dictionary:
	return button({"p": [5, 13], "bg": T.CLEAR, "b": [1, T.BORDER_STRONG], "c": T.TEXT, "ff": "mono", "fs": 11.0})

# ---- misc ----------------------------------------------------------------------------------
const STAT_GRID := {"display": "grid", "cols": [1.0, 1.0], "gapr": 5.0, "gapc": 10.0, "mb": 12.0}
const STAT_CELL := {"display": "flex", "jc": "space-between", "ai": "baseline"}
const STAT_K := {"fs": 10.0, "c": T.TEXT_DIM}
const STAT_V := {"fs": 11.0, "c": T.ACCENT}

const ERA := {
	"era-stable": {"c": Color(0x4e / 255.0, 0xe3 / 255.0, 0x9a / 255.0), "bg": T.CLEAR},
	"era-cold": {"c": Color(0x6f / 255.0, 0xb6 / 255.0, 1.0), "bg": T.CLEAR},
	"era-freeze": {"c": Color(0xb9 / 255.0, 0xe2 / 255.0, 1.0), "bg": Color(120 / 255.0, 190 / 255.0, 1.0, 0.10)},
	"era-hot": {"c": Color(1.0, 0xab / 255.0, 0x52 / 255.0), "bg": T.CLEAR},
	"era-scorch": {"c": Color(1.0, 0x5a / 255.0, 0x4a / 255.0), "bg": Color(1.0, 70 / 255.0, 50 / 255.0, 0.12)},
}
