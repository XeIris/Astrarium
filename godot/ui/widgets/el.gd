class_name El
extends Control

# ============================================================================
# ONE HTML ELEMENT, LAID OUT BY CSS's RULES
# ----------------------------------------------------------------------------
# The HUD's target is a screenshot-identical copy of the web page, and the page
# is laid out by CSS: block flow with COLLAPSING margins, flex rows whose items
# shrink to their min-content and align on their text BASELINES, grids of equal
# fractions, inline text whose line boxes are sized by the font's rounded
# metrics, inline-blocks (<kbd>) that stretch the line they sit in. Godot's
# containers do none of those, and every one of them moves something by a few
# pixels — the panel head alone is 31 px tall rather than 28 only because the
# ✕ button's baseline sits lower than the heading's. So the HUD is not built
# from Godot containers. It is built from these: one El per HTML element,
# carrying that element's computed style, and a layout that is a small, honest
# port of the parts of CSS the page actually uses.
#
# Style is a Dictionary of CSS properties (short keys, below), plus VARIANTS:
# [state, overrides] pairs applied in order when a state is on — "hover",
# "active", "on", "open", "focus", and any class the HUD toggles. Order is the
# cascade's: a later variant wins, exactly as `.toggle-btn.active` written
# after `.toggle-btn:hover` does.
#
# Text properties INHERIT (colour, font, size, letter-spacing, line-height,
# text-transform, text-align), everything else does not. A leaf element carries
# `runs` — inline text, optionally with inline-blocks (kbd, the FLARE tag) and
# line breaks — and is laid out by `_layout_inline`.
#
# Layout is top-down and explicit: `layout(width) -> height` sets this node's
# size and every child's position and size. Nothing here is a Container, so
# nothing re-sorts behind our back; the Hud calls layout on each positioned
# panel when something in it changed (`touch()`).
# ============================================================================

signal pressed

const INHERITED := {"fs": 12.0, "ff": "mono", "fw": 400, "fi": false, "c": HudTheme.TEXT,
	"ls": 0.0, "lh": -1.0, "up": false, "ta": "left", "nw": false}
const DEFAULTS := {"display": "block", "dir": "row", "wrap": false, "w": -1.0, "wp": -1.0, "h": -1.0,
	"maxh": -1.0, "minw": -1.0, "maxw": -1.0, "minh": -1.0, "mauto": false,
	"mt": 0.0, "mr": 0.0, "mb": 0.0, "ml": 0.0, "pt": 0.0, "pr": 0.0, "pb": 0.0, "pl": 0.0,
	"bt": 0.0, "br": 0.0, "bb": 0.0, "bl": 0.0,
	"bct": HudTheme.CLEAR, "bcr": HudTheme.CLEAR, "bcb": HudTheme.CLEAR, "bcl": HudTheme.CLEAR,
	"bdot": false, "bg": HudTheme.CLEAR, "rad": 0.0, "gapc": 0.0, "gapr": 0.0, "cols": [],
	"area": [], "ai": "stretch", "jc": "start", "as": "", "grow": 0.0, "shrink": 1.0, "basis": -1.0,
	"iw": -1.0, "fit": false, "ib": false, "vc": false, "scroll": false, "sbw": 4.0,
	"clip": false, "op": 1.0, "rot": 0.0, "glow": 0.0, "ring": HudTheme.CLEAR, "outline_ring": 0.0,
	"blur": 0.0, "mlauto": false, "aspect": 0.0, "span": 1}

## Every root that needs laying out again (a positioned panel), and whether
## anything did — the Hud reads and clears these once a frame.
static var dirty_roots := {}
## Scrollbars take their 4 px out of the content box, as WebKit's do. The web
## reference shots are taken with Chrome's --hide-scrollbars, which makes them
## zero-width, so the HUD harness turns them off to compare like with like.
static var scrollbars := true
static var any_dirty := true

var base := {}
var variants: Array = []          # [[state, {overrides}], ...]
var states := {}
var cs := {}                      # computed (base + active variants)
var runs: Array = []              # inline content; [] = not a text leaf
var is_root := false              # a positioned element the Hud places
var el_id := ""
var clickable := false

# scroll state (overflow-y: auto)
var scroll_y := 0.0
var content_h := 0.0
var overflowing := false
var _thumb: Control = null
var _blur: ColorRect = null

# inline layout result
var _lines: Array = []
var _text_h := 0.0
var _hovered := false

func _init(style: Dictionary = {}, vars: Array = []) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_NONE
	base = _expand(style)
	for v in vars:
		variants.append([v[0], _expand(v[1])])
	_recompute()

# ---- style --------------------------------------------------------------------

## Shorthands: "b": [w, color] (all four sides), "p"/"m": n or [t, r, b, l].
static func _expand(s: Dictionary) -> Dictionary:
	var o := {}
	for k in s:
		var v = s[k]
		match k:
			"b":
				for side in ["t", "r", "b", "l"]:
					o["b" + side] = float(v[0]); o["bc" + side] = v[1]
			"bcol":
				for side in ["t", "r", "b", "l"]:
					o["bc" + side] = v
			"p", "m":
				var a: Array = v if v is Array else [v, v, v, v]
				if a.size() == 2: a = [a[0], a[1], a[0], a[1]]
				if a.size() == 3: a = [a[0], a[1], a[2], a[1]]
				o[k + "t"] = float(a[0]); o[k + "r"] = float(a[1]); o[k + "b"] = float(a[2]); o[k + "l"] = float(a[3])
			_:
				o[k] = v
	return o

func set_style(style: Dictionary) -> void:
	base.merge(_expand(style), true)
	_recompute()

func set_state(s: String, on: bool) -> void:
	if bool(states.get(s, false)) == on:
		return
	states[s] = on
	_recompute()

func has_state(s: String) -> bool:
	return bool(states.get(s, false))

func _recompute() -> void:
	var c := base.duplicate()
	for v in variants:
		if states.get(v[0], false):
			c.merge(v[1], true)
	cs = c
	modulate.a = float(cs.get("op", 1.0))
	_invalidate()
	touch()

## Text measurements are cached per element; anything that can change what a
## run inherits (a state on an ancestor) drops the caches of the whole subtree.
var _atoms_cache = null
var _iw_cache = null

func _invalidate() -> void:
	_atoms_cache = null
	_iw_cache = null
	_ldirty = true
	for c in get_children():
		if c is El:
			(c as El)._invalidate()

## The value of a property: own, inherited, or default.
func g(k: String):
	if cs.has(k):
		return cs[k]
	if INHERITED.has(k):
		var p := get_parent()
		if p is El:
			return (p as El).g(k)
		return INHERITED[k]
	return DEFAULTS[k]

func gf(k: String) -> float:
	return float(g(k))

## Something about this element changed: its positioned root lays out again.
func touch() -> void:
	any_dirty = true
	var r: Node = self
	while r != null and r is El and not (r as El).is_root:
		(r as El)._ldirty = true
		r = r.get_parent()
	if r is El:
		(r as El)._ldirty = true
	if r is El:
		dirty_roots[r] = true
	queue_redraw()

func set_runs(r: Array) -> void:
	runs = r
	_atoms_cache = null
	_iw_cache = null
	touch()

func set_text(t: String) -> void:
	if runs.size() == 1 and runs[0].get("t", null) == t:
		return
	runs = [{"t": t}]
	_atoms_cache = null
	_iw_cache = null
	touch()

func get_text() -> String:
	var s := ""
	for r in runs:
		s += str(r.get("t", ""))
	return s

func kids() -> Array:
	var out: Array = []
	for c in get_children():
		if c is El and c.visible:
			out.append(c)
	return out

# ---- interaction ----------------------------------------------------------------

## A <button>: takes the click, shows the hand, and goes :hover. PASS, not
## STOP: the button accepts its own clicks, and a wheel over it still reaches
## the panel that scrolls, as the browser's does.
func make_clickable(tooltip := "") -> El:
	clickable = true
	mouse_filter = Control.MOUSE_FILTER_PASS
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if tooltip != "":
		tooltip_text = tooltip
	if not mouse_entered.is_connected(_on_enter):
		mouse_entered.connect(_on_enter)
		mouse_exited.connect(_on_exit)
	return self

func make_hoverable() -> void:
	if not mouse_entered.is_connected(_on_enter):
		mouse_entered.connect(_on_enter)
		mouse_exited.connect(_on_exit)
	if mouse_filter == Control.MOUSE_FILTER_IGNORE:
		mouse_filter = Control.MOUSE_FILTER_PASS

func _on_enter() -> void:
	set_state("hover", true)

func _on_exit() -> void:
	set_state("hover", false)

func _gui_input(e: InputEvent) -> void:
	if clickable and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and not e.pressed:
		if Rect2(Vector2.ZERO, size).has_point(e.position) and not has_state("disabled"):
			pressed.emit()
			accept_event()
	elif clickable and e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		accept_event()
	if gf("maxh") > 0.0 and bool(g("scroll")) and e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if overflowing:
				scroll_by((-1.0 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0) * 40.0 * maxf(e.factor, 1.0))
				accept_event()

func scroll_by(dy: float) -> void:
	var mx := maxf(content_h - size.y, 0.0)
	var ny := clampf(scroll_y + dy, 0.0, mx)
	if ny != scroll_y:
		scroll_y = ny
		touch()

# ---- measurement ------------------------------------------------------------------

func _hpad() -> float:
	return gf("pl") + gf("pr") + gf("bl") + gf("br")

func _vpad() -> float:
	return gf("pt") + gf("pb") + gf("bt") + gf("bb")

## Border-box max-content width.
func max_content_w() -> float:
	if gf("w") >= 0.0:
		return gf("w")
	var w := 0.0
	if gf("iw") >= 0.0:
		w = gf("iw")
	elif not runs.is_empty():
		w = _inline_widths().x
	else:
		var ks := kids()
		var disp: String = g("display")
		if disp == "flex" and g("dir") == "row":
			for k in ks:
				w += k.max_content_w() + k.gf("ml") + k.gf("mr")
			w += gf("gapc") * maxf(ks.size() - 1, 0)
		elif disp == "grid":
			var cols: Array = g("cols")
			var n := maxi(cols.size(), 1)
			var best := 0.0
			var fixed := 0.0
			for c in cols:
				if float(c) < 0.0: fixed += -float(c)
			for k in ks:
				best = maxf(best, k.max_content_w() + k.gf("ml") + k.gf("mr"))
			var nfr := 0
			for c in cols:
				if float(c) > 0.0: nfr += 1
			w = fixed + best * nfr + gf("gapc") * (n - 1)
		else:
			for k in ks:
				w = maxf(w, k.max_content_w() + k.gf("ml") + k.gf("mr"))
	if gf("maxw") >= 0.0:
		w = minf(w, gf("maxw") - _hpad())
	return maxf(w + _hpad(), gf("minw"))

## Border-box min-content width.
func min_content_w() -> float:
	if gf("w") >= 0.0:
		return gf("w")
	var w := 0.0
	if gf("iw") >= 0.0:
		w = gf("iw")
	elif not runs.is_empty():
		w = _inline_widths().y
	else:
		var ks := kids()
		var disp: String = g("display")
		if disp == "flex" and g("dir") == "row" and not bool(g("wrap")):
			for k in ks:
				w += k._flex_min() + k.gf("ml") + k.gf("mr")
			w += gf("gapc") * maxf(ks.size() - 1, 0)
		else:
			for k in ks:
				w = maxf(w, k.min_content_w() + k.gf("ml") + k.gf("mr"))
	return maxf(w + _hpad(), gf("minw"))

## The automatic minimum size of a flex item (min-width: auto).
func _flex_min() -> float:
	if gf("minw") >= 0.0:
		return gf("minw")
	if bool(g("scroll")) or bool(g("clip")):
		return 0.0
	return min_content_w()

# ---- layout -----------------------------------------------------------------------

## Lay out at border-box width `w`; returns the border-box height. `forced_h`
## is a height imposed by the parent (flex/grid stretch).
## Layout is cached: an element nothing has touched, asked for the same width
## and the same imposed height, keeps what it had — its children are already
## where they belong. Ten text updates a second then cost only their own path
## to the root, not the whole panel.
var _ldirty := true
var _lw := -1.0
var _lf := -2.0

func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED:
		touch()
	elif what == NOTIFICATION_UNPARENTED:
		_ldirty = true

func layout(w: float, forced_h: float = -1.0) -> float:
	if not _ldirty and absf(w - _lw) < 0.001 and absf(forced_h - _lf) < 0.001:
		return size.y
	var h := _layout_now(w, forced_h)
	_ldirty = false
	_lw = w
	_lf = forced_h
	return h

func _layout_now(w: float, forced_h: float) -> float:
	var bl := gf("bl"); var bt := gf("bt"); var pl := gf("pl"); var pt := gf("pt")
	var cw := maxf(w - _hpad(), 0.0)
	var maxh := gf("maxh")
	var scroll: bool = g("scroll")
	var ch := _layout_content(cw, Vector2(bl + pl, bt + pt))
	var auto_h := ch + _vpad()
	overflowing = false
	if scroll and maxh >= 0.0 and auto_h > maxh + 0.01:
		# The WebKit scrollbar is taken out of the content box, so the whole
		# content lays out again 4 px narrower once it knows it overflows.
		overflowing = true
		if scrollbars:
			ch = _layout_content(maxf(cw - gf("sbw"), 0.0), Vector2(bl + pl, bt + pt))
		auto_h = ch + _vpad()
	content_h = auto_h
	var h := auto_h
	if gf("h") >= 0.0:
		h = gf("h")
	if forced_h >= 0.0:
		h = forced_h
	if gf("minh") >= 0.0:
		h = maxf(h, gf("minh"))
	if maxh >= 0.0:
		h = minf(h, maxh)
	if not overflowing:
		scroll_y = 0.0
	else:
		scroll_y = clampf(scroll_y, 0.0, maxf(content_h - h, 0.0))
	# A <button> centres its content in whatever height it is given — unless
	# it is a flex container, whose items start at the top like any flex box.
	if bool(g("vc")) and g("display") == "block" and h > auto_h + 0.01:
		var dy := (h - auto_h) * 0.5
		for k in kids():
			k.position.y += dy
		for ln in _lines:
			ln.top += dy
	if scroll_y != 0.0:
		for k in kids():
			k.position.y -= scroll_y
	size = Vector2(w, h)
	clip_contents = overflowing or bool(g("clip"))
	_sync_thumb()
	_sync_blur()
	queue_redraw()
	return h

func _layout_content(cw: float, o: Vector2) -> float:
	if gf("aspect") > 0.0:
		for k in kids():
			k.position = o
			k.layout(cw)
		return cw * gf("aspect")
	if not runs.is_empty():
		return _layout_inline(cw)
	var disp: String = g("display")
	if disp == "flex":
		if g("dir") == "row":
			return _layout_flex_row(cw, o)
		return _layout_flex_col(cw, o)
	if disp == "grid":
		return _layout_grid(cw, o)
	return _layout_block(cw, o)

## Width of a child laid out in normal flow (block / flex column / grid cell).
func _child_w(k: El, avail: float, stretch: bool) -> float:
	var ml := k.gf("ml"); var mr := k.gf("mr")
	if k.gf("w") >= 0.0:
		return k.gf("w")
	if k.gf("wp") >= 0.0:
		return avail * k.gf("wp") - ml - mr
	var w := avail - ml - mr
	if not stretch or (bool(k.g("fit")) and g("display") == "block"):
		w = minf(k.max_content_w(), w)
	if k.gf("maxw") >= 0.0:
		w = minf(w, k.gf("maxw"))
	return maxf(w, k.gf("minw"))

# -- block flow, with margin collapsing ---------------------------------------------

func _collapses_top() -> bool:
	return g("display") == "block" and gf("pt") == 0.0 and gf("bt") == 0.0 and runs.is_empty() \
		and not bool(g("ib")) and not bool(g("scroll")) and not is_root

func _collapses_bot() -> bool:
	return g("display") == "block" and gf("pb") == 0.0 and gf("bb") == 0.0 and runs.is_empty() \
		and not bool(g("ib")) and not bool(g("scroll")) and not is_root and gf("h") < 0.0

func eff_mt() -> float:
	var m := gf("mt")
	if _collapses_top():
		var ks := kids()
		if not ks.is_empty() and not bool(ks[0].g("ib")):
			m = _collapse(m, ks[0].eff_mt())
	return m

func eff_mb() -> float:
	var m := gf("mb")
	if _collapses_bot():
		var ks := kids()
		if not ks.is_empty() and not bool(ks[-1].g("ib")):
			m = _collapse(m, ks[-1].eff_mb())
	return m

## Two adjoining margins collapse to the largest positive plus the most
## negative (CSS 2 §8.3.1).
static func _collapse(a: float, b: float) -> float:
	return maxf(maxf(a, 0.0), maxf(b, 0.0)) + minf(minf(a, 0.0), minf(b, 0.0))

func _layout_block(cw: float, o: Vector2) -> float:
	var y := 0.0
	var pend := 0.0
	var ks := kids()
	var ct := _collapses_top()
	var cb := _collapses_bot()
	for i in ks.size():
		var k: El = ks[i]
		var kw := _child_w(k, cw, not bool(k.g("ib")))
		var h := k.layout(kw)
		var x := k.gf("ml")
		if bool(k.g("mauto")):
			x = (cw - kw) * 0.5
		elif k.g("ta") == "center" and bool(k.g("ib")) and false:
			x = (cw - kw) * 0.5
		if bool(k.g("ib")):
			# An inline-block sits in a line box of its own: its margins are part
			# of that line's height and collapse with nothing.
			y += pend + k.gf("mt")
			pend = 0.0
			if g("ta") == "center":
				x = (cw - kw) * 0.5
			elif g("ta") == "right":
				x = cw - kw - k.gf("mr")
			k.position = o + Vector2(x, y)
			y += h + k.gf("mb")
			continue
		var tm := k.eff_mt()
		var bm := k.eff_mb()
		if i == 0 and ct:
			tm = 0.0
		if h <= 0.0 and k._collapses_top() and k._collapses_bot():
			pend = _collapse(pend, _collapse(tm, bm))
			k.position = o + Vector2(x, y + pend)
			continue
		y += _collapse(pend, tm)
		k.position = o + Vector2(x, y)
		y += h
		pend = bm
	if not (cb and not ks.is_empty() and not bool(ks[-1].g("ib"))):
		y += pend
	return y

# -- flex ---------------------------------------------------------------------------------

func _layout_flex_row(cw: float, o: Vector2) -> float:
	var ks := kids()
	if ks.is_empty():
		return 0.0
	var gap := gf("gapc")
	var lines: Array = [ks]
	if bool(g("wrap")):
		lines = []
		var cur: Array = []
		var used := 0.0
		for k in ks:
			var b: float = k._flex_basis(cw) + k.gf("ml") + k.gf("mr")
			b = maxf(b, k._flex_min() + k.gf("ml") + k.gf("mr"))
			if not cur.is_empty() and used + gap + b > cw:
				lines.append(cur); cur = []; used = 0.0
			used += (gap if not cur.is_empty() else 0.0) + b
			cur.append(k)
		lines.append(cur)
	var y := 0.0
	for li in lines.size():
		if li > 0:
			y += gf("gapr")
		y += _flex_line(lines[li], cw, o + Vector2(0, y), gap, lines.size() == 1)
	return y

func _flex_basis(cw: float) -> float:
	if gf("basis") >= 0.0:
		return gf("basis")
	if gf("w") >= 0.0:
		return gf("w")
	if gf("wp") >= 0.0:
		return cw * gf("wp") - gf("ml") - gf("mr")
	return max_content_w()

func _flex_line(ks: Array, cw: float, o: Vector2, gap: float, single: bool) -> float:
	var n := ks.size()
	var basis: Array = []; var mins: Array = []; var sizes: Array = []; var frozen: Array = []
	var used := gap * (n - 1)
	var autos := 0
	for k in ks:
		var b: float = k._flex_basis(cw)
		var mn: float = k._flex_min()
		basis.append(b); mins.append(mn)
		sizes.append(maxf(b, mn)); frozen.append(false)
		used += maxf(b, mn) + k.gf("ml") + k.gf("mr")
		if bool(k.g("mlauto")): autos += 1
	# CSS 2.1 flex sizing: grow or shrink is decided on the HYPOTHETICAL sizes
	# (bases clamped to their minimums), but the free space is distributed from
	# the flex BASES, freezing any item its minimum stops.
	var growing := cw - used > 0.0
	var fixed_sum := gap * (n - 1)
	for k in ks: fixed_sum += k.gf("ml") + k.gf("mr")
	for _it in 5:
		var free0 := cw - fixed_sum
		var tg := 0.0; var ts := 0.0
		for i in n:
			if frozen[i]: free0 -= sizes[i]
			else:
				free0 -= basis[i]
				tg += ks[i].gf("grow"); ts += ks[i].gf("shrink") * basis[i]
		var viol := false
		for i in n:
			if frozen[i]: continue
			var want: float = basis[i]
			if growing and tg > 0.0:
				want = basis[i] + free0 * ks[i].gf("grow") / tg
			elif not growing and ts > 0.0:
				want = basis[i] + free0 * ks[i].gf("shrink") * basis[i] / ts
			if want < mins[i]:
				sizes[i] = mins[i]; frozen[i] = true; viol = true
			else:
				sizes[i] = want
		if not viol:
			break
	var free := cw - fixed_sum
	for i in n: free -= sizes[i]
	# heights, then the line's cross size (baselines aligned)
	var hs: Array = []
	var maxA := 0.0; var maxD := 0.0; var line_h := 0.0
	var ai: String = g("ai")
	for i in n:
		var k: El = ks[i]
		var h := k.layout(sizes[i])
		hs.append(h)
		var al: String = k.g("as") if k.g("as") != "" else ai
		var outer := h + k.gf("mt") + k.gf("mb")
		if al == "baseline":
			var b := k.gf("mt") + k.baseline()
			maxA = maxf(maxA, b); maxD = maxf(maxD, outer - b)
		else:
			line_h = maxf(line_h, outer)
	line_h = maxf(line_h, maxA + maxD)
	if single and gf("h") >= 0.0:
		line_h = maxf(line_h, gf("h") - _vpad())
	# main axis placement
	var x := 0.0
	var between := gap
	var jc: String = g("jc")
	if free > 0.0 and autos > 0:
		pass
	elif free > 0.0:
		if jc == "space-between" and n > 1:
			between = gap + free / (n - 1)
		elif jc == "end":
			x = free
		elif jc == "center":
			x = free * 0.5
	for i in n:
		var k: El = ks[i]
		if bool(k.g("mlauto")) and free > 0.0:
			x += free / autos
		x += k.gf("ml")
		var al: String = k.g("as") if k.g("as") != "" else ai
		var h: float = hs[i]
		var yy := k.gf("mt")
		match al:
			"baseline":
				yy = maxA - k.baseline()
			"center":
				yy = (line_h - h - k.gf("mt") - k.gf("mb")) * 0.5 + k.gf("mt")
			"end":
				yy = line_h - h - k.gf("mb")
			"stretch":
				if k.gf("h") < 0.0:
					var fh := line_h - k.gf("mt") - k.gf("mb")
					if absf(fh - h) > 0.01:
						k.layout(sizes[i], fh)
		k.position = o + Vector2(x, yy)
		x += sizes[i] + k.gf("mr") + between
	return line_h

func _layout_flex_col(cw: float, o: Vector2) -> float:
	var ks := kids()
	var y := 0.0
	var ai: String = g("ai")
	var gap := gf("gapr")
	var maxh := gf("maxh")
	for i in ks.size():
		var k: El = ks[i]
		var al: String = k.g("as") if k.g("as") != "" else ai
		var kw := _child_w(k, cw, al == "stretch")
		var h := k.layout(kw)
		var x := k.gf("ml")
		if al == "center":
			x = (cw - kw) * 0.5
		elif al == "end":
			x = cw - kw - k.gf("mr")
		if i > 0: y += gap
		y += k.gf("mt")
		k.position = o + Vector2(x, y)
		y += h + k.gf("mb")
	# A column with a height cap gives up the difference from the item that
	# scrolls (the lesson card's text/instrument row: `min-height: 0`).
	if maxh >= 0.0 and y + _vpad() > maxh:
		var excess := y + _vpad() - maxh
		for k in ks:
			if bool(k.g("scroll")):
				var nh: float = maxf(k.size.y - excess, 0.0)
				var old: float = k.base.get("maxh", -1.0)
				k.cs["maxh"] = nh
				k._ldirty = true
				k.layout(k.size.x)
				k._ldirty = true
				k.cs["maxh"] = old
				var shift: float = k.size.y - (nh + excess)
				var after := false
				for k2 in ks:
					if after: k2.position.y -= excess
					if k2 == k: after = true
				y -= excess
				break
	return y

# -- grid ---------------------------------------------------------------------------------

func _layout_grid(cw: float, o: Vector2) -> float:
	var ks := kids()
	var cols: Array = g("cols")
	if cols.is_empty(): cols = [1.0]
	var n := cols.size()
	var gc := gf("gapc"); var gr := gf("gapr")
	var fixed := 0.0; var fr := 0.0
	for c in cols:
		if float(c) < 0.0: fixed += -float(c)
		else: fr += float(c)
	var frw := maxf(cw - fixed - gc * (n - 1), 0.0) / maxf(fr, 1e-6)
	var cw_arr: Array = []; var cx: Array = []
	var xx := 0.0
	for c in cols:
		var wcol: float = -float(c) if float(c) < 0.0 else float(c) * frw
		cw_arr.append(wcol); cx.append(xx)
		xx += wcol + gc
	# placement: explicit `area` [col, row, span] or auto-flow row-major
	var place: Array = []
	var r := 0; var c := 0
	var nrows := 0
	for k in ks:
		var a: Array = k.g("area")
		var pc := 0; var pr := 0; var span := 1
		if a.size() >= 2:
			pc = a[0]; pr = a[1]; span = a[2] if a.size() > 2 else 1
		else:
			span = mini(int(k.base.get("span", 1)), n)
			if c + span > n:
				c = 0; r += 1
			pc = c; pr = r
			c += span
			if c >= n:
				c = 0; r += 1
		place.append([pc, pr, span])
		nrows = maxi(nrows, pr + 1)
	var rh: Array = []
	rh.resize(nrows); rh.fill(0.0)
	var hs: Array = []; var ws: Array = []
	for i in ks.size():
		var k: El = ks[i]
		var p: Array = place[i]
		var span_w: float = cx[p[0] + p[2] - 1] + cw_arr[p[0] + p[2] - 1] - cx[p[0]]
		var kw := _child_w(k, span_w, true)
		ws.append(kw)
		var h := k.layout(kw)
		hs.append(h)
		rh[p[1]] = maxf(rh[p[1]], h + k.gf("mt") + k.gf("mb"))
	var ry: Array = []
	var yy := 0.0
	for i in nrows:
		ry.append(yy)
		yy += rh[i] + (gr if i < nrows - 1 else 0.0)
	var ai: String = g("ai")
	for i in ks.size():
		var k: El = ks[i]
		var p: Array = place[i]
		var al: String = k.g("as") if k.g("as") != "" else ai
		var h: float = hs[i]
		var y0: float = ry[p[1]] + k.gf("mt")
		var rowh: float = rh[p[1]]
		if al == "stretch" and k.gf("h") < 0.0:
			var fh: float = rowh - k.gf("mt") - k.gf("mb")
			if absf(fh - h) > 0.01:
				k.layout(ws[i], fh)
		elif al == "center":
			y0 = ry[p[1]] + (rowh - h - k.gf("mt") - k.gf("mb")) * 0.5 + k.gf("mt")
		k.position = o + Vector2(cx[p[0]] + k.gf("ml"), y0)
	return yy

# -- baselines ------------------------------------------------------------------------

## First baseline from the border-box top (the bottom margin edge when there
## is no line box, as CSS synthesises it for an inline-block).
func baseline() -> float:
	if not runs.is_empty() and not _lines.is_empty():
		return gf("bt") + gf("pt") + _lines[0].top + _lines[0].base
	for k in kids():
		var b: float = k.baseline()
		if b >= 0.0:
			return k.position.y + scroll_y + b
	return size.y

# ---- inline text ---------------------------------------------------------------------------

func _run_style(r: Dictionary) -> Dictionary:
	var fs: float = r.get("fs", gf("fs"))
	var ff: String = r.get("ff", g("ff"))
	var s := {
		"fs": fs,
		# the display face at a small size is its optical "Text" design, with
		# CoreText's tracking on top (HudTheme.font_sized)
		"font": HudTheme.font_sized(ff, int(r.get("fw", g("fw"))), bool(r.get("fi", g("fi"))), fs),
		"c": r.get("c", g("c")),
		"ls": float(r.get("ls", gf("ls"))) + HudTheme.tracking(ff, fs),
		"up": bool(r.get("up", g("up"))),
		"lh": float(r.get("lh", gf("lh"))),
	}
	return s

## Line height of a font at a size under a CSS line-height (-1 = normal).
static func _lh(font: Font, fs: float, lh: float) -> float:
	var ad := HudTheme.asc_desc(font, fs)
	if lh < 0.0:
		return ad.x + ad.y
	if lh > 8.0:          # an absolute px value
		return lh
	return lh * fs

func _atoms() -> Array:
	if _atoms_cache != null:
		return _atoms_cache
	_atoms_cache = _build_atoms()
	return _atoms_cache

func _build_atoms() -> Array:
	var out: Array = []
	var nw: bool = g("nw")
	for r in runs:
		if r.get("hide", false):
			continue
		if r.get("br", false):
			out.append({"br": true, "r": r, "st": _run_style(r)})
			continue
		var st := _run_style(r)
		var t: String = str(r.get("t", ""))
		if st.up:
			t = t.to_upper()
		if r.has("box"):
			var bx: Dictionary = r.box
			var w := HudTheme.text_w(st.font, t, st.fs, st.ls) + float(bx.get("pl", 0)) + float(bx.get("pr", 0)) \
				+ 2.0 * float(bx.get("bw", 0)) + float(bx.get("ml", 0)) + float(bx.get("mr", 0))
			w = maxf(w, float(bx.get("w", 0.0)))
			out.append({"t": t, "w": w, "r": r, "st": st, "box": bx})
			continue
		# words and the spaces between them are separate atoms: a space is a
		# break opportunity, and a space that ends a line is dropped
		var word := ""
		for i in t.length():
			var ch := t[i]
			if ch == " " and not nw:
				if word != "":
					out.append({"t": word, "w": HudTheme.text_w(st.font, word, st.fs, st.ls), "r": r, "st": st})
					word = ""
				out.append({"sp": true, "t": " ", "w": HudTheme.text_w(st.font, " ", st.fs, st.ls), "r": r, "st": st})
			else:
				word += ch
				# an em dash is a break opportunity after it (UAX #14, class B2)
				if ch == "—" and i < t.length() - 1 and t[i + 1] != " " and not nw:
					out.append({"t": word, "w": HudTheme.text_w(st.font, word, st.fs, st.ls), "r": r, "st": st})
					word = ""
		if word != "":
			out.append({"t": word, "w": HudTheme.text_w(st.font, word, st.fs, st.ls), "r": r, "st": st})
	return out

## (max-content, min-content) content widths of the inline text.
func _inline_widths() -> Vector2:
	if _iw_cache != null:
		return _iw_cache
	_iw_cache = _measure_inline()
	return _iw_cache

func _measure_inline() -> Vector2:
	var mx := 0.0; var mn := 0.0; var cur := 0.0
	for a in _atoms():
		if a.get("br", false):
			mx = maxf(mx, cur); cur = 0.0
			continue
		cur += a.w
		if not a.get("sp", false):
			mn = maxf(mn, a.w)
	mx = maxf(mx, cur)
	# a trailing space hangs and is not counted
	return Vector2(mx, mn)

func _layout_inline(cw: float) -> float:
	var atoms := _atoms()
	# no text at all is no line box at all (an empty element is 0 tall)
	var any := false
	for a in atoms:
		if not a.get("sp", false):
			any = true
			break
	if not any:
		_lines = []
		_text_h = 0.0
		return 0.0
	var nw: bool = g("nw")
	_lines = []
	var line: Array = []
	var x := 0.0
	var pend_sp: Array = []
	for a in atoms:
		if a.get("br", false):
			_lines.append(line); line = []; x = 0.0; pend_sp = []
			continue
		if a.get("sp", false):
			if not line.is_empty():
				pend_sp.append(a)
			continue
		var spw := 0.0
		for s in pend_sp: spw += s.w
		if not line.is_empty() and not nw and x + spw + a.w > cw + 0.01:
			_lines.append(line); line = []; x = 0.0; pend_sp = []; spw = 0.0
		for s in pend_sp:
			line.append({"a": s, "x": x}); x += s.w
		pend_sp = []
		line.append({"a": a, "x": x}); x += a.w
	_lines.append(line)
	# vertical metrics: the strut of this element, then every run and box
	var font := HudTheme.font(g("ff"), int(g("fw")), bool(g("fi")))
	var fs := gf("fs")
	var ad := HudTheme.asc_desc(font, fs)
	var lh := _lh(font, fs, gf("lh"))
	var sA := ad.x + (lh - ad.x - ad.y) * 0.5
	var sD := lh - sA
	var ta: String = g("ta")
	var out: Array = []
	var y := 0.0
	for ln in _lines:
		var A := sA; var D := sD
		var w := 0.0
		for it in ln:
			var a: Dictionary = it.a
			var st: Dictionary = a.st
			var a2 := HudTheme.asc_desc(st.font, st.fs)
			var l2 := _lh(st.font, st.fs, st.lh)
			var up := a2.x + (l2 - a2.x - a2.y) * 0.5
			var dn := l2 - up
			if a.has("box"):
				var bx: Dictionary = a.box
				var tp := float(bx.get("pt", 0)) + float(bx.get("bw", 0))
				var bp := float(bx.get("pb", 0)) + float(bx.get("bw", 0))
				up += tp; dn += bp
				if bx.has("h"):
					dn = float(bx.h) - up
			if a.r.get("sub", false):
				var sh := fs / 5.0 + 1.0
				up -= sh; dn += sh
			A = maxf(A, up); D = maxf(D, dn)
			if not a.get("sp", false):
				w = it.x + a.w
		var off := 0.0
		if ta == "right": off = cw - w
		elif ta == "center": off = (cw - w) * 0.5
		# Blink holds geometry in LayoutUnits of 1/64 px, and a fractional line
		# height (9.5 px × 1.55) is truncated to one — which over a paragraph
		# is the difference between a panel ending at .48 or .5, and so which
		# way the measured chain rounds.
		var lh_u := floorf((A + D) * 64.0) / 64.0
		out.append({"items": ln, "top": y, "base": A, "h": lh_u, "off": off})
		y += lh_u
	_lines = out
	_text_h = y
	return y

# ---- drawing ------------------------------------------------------------------------------

## A rect snapped to device pixels the way Blink snaps boxes: each edge rounds.
func _snap(r: Rect2) -> Rect2:
	var gp := get_global_transform().origin
	var x0 := roundf(gp.x + r.position.x) - gp.x
	var y0 := roundf(gp.y + r.position.y) - gp.y
	var x1 := roundf(gp.x + r.end.x) - gp.x
	var y1 := roundf(gp.y + r.end.y) - gp.y
	return Rect2(x0, y0, x1 - x0, y1 - y0)

func _draw() -> void:
	var r := _snap(Rect2(Vector2.ZERO, size))
	var rot := gf("rot")
	if rot != 0.0:
		# transform-origin: 50% 50%
		var c := size * 0.5
		draw_set_transform_matrix(Transform2D(deg_to_rad(rot), c) * Transform2D(0.0, -c))
	var bg: Color = g("bg")
	var ring := gf("outline_ring")
	if ring > 0.0:
		draw_rect(r.grow(ring), g("ring"), false, ring * 2.0)
	var glow := gf("glow")
	if glow > 0.0:
		# box-shadow: 0 0 <glow>px <colour> — a Gaussian of σ = glow/2
		var cc := r.get_center()
		for i in 8:
			var t := (i + 1) / 8.0
			var rr := r.size.x * 0.5 + glow * t
			draw_circle(cc, rr, Color(bg, 0.16 * (1.0 - t) * (1.0 - t)), true, -1.0, true)
	var rad := gf("rad")
	if rad > 0.0 or glow > 0.0:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		var radius := rad if glow <= 0.0 else r.size.x * 0.5
		sb.set_corner_radius_all(int(round(radius)))
		sb.corner_detail = 8
		sb.border_color = g("bct")
		sb.border_width_top = int(gf("bt")); sb.border_width_bottom = int(gf("bb"))
		sb.border_width_left = int(gf("bl")); sb.border_width_right = int(gf("br"))
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 0.6
		draw_style_box(sb, r)
	else:
		if bg.a > 0.0 and (_blur == null or not _blur.visible):
			draw_rect(r, bg)
		_draw_borders(r)
	if not runs.is_empty():
		_draw_text()
	_draw_extra()
	if rot != 0.0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _draw_borders(r: Rect2) -> void:
	var t := gf("bt"); var b := gf("bb"); var l := gf("bl"); var rr := gf("br")
	if t > 0.0: draw_rect(Rect2(r.position.x, r.position.y, r.size.x, t), g("bct"))
	if l > 0.0: draw_rect(Rect2(r.position.x, r.position.y + t, l, r.size.y - t - b), g("bcl"))
	if rr > 0.0: draw_rect(Rect2(r.end.x - rr, r.position.y + t, rr, r.size.y - t - b), g("bcr"))
	if b > 0.0:
		if bool(g("bdot")):
			var x := r.position.x
			while x < r.end.x:
				draw_rect(Rect2(x, r.end.y - b, minf(b, r.end.x - x), b), g("bcb"))
				x += 2.0 * b
		else:
			draw_rect(Rect2(r.position.x, r.end.y - b, r.size.x, b), g("bcb"))

## Override point for elements that paint something the box model cannot.
func _draw_extra() -> void:
	pass

func _draw_text() -> void:
	var ox := gf("bl") + gf("pl")
	var oy := gf("bt") + gf("pt")
	var gp := get_global_transform().origin
	for ln in _lines:
		var by := roundf(gp.y + oy + ln.top + ln.base) - gp.y
		for it in ln.items:
			var a: Dictionary = it.a
			var st: Dictionary = a.st
			var x: float = ox + ln.off + it.x
			var col: Color = st.c
			var bly := by
			if a.r.get("sub", false):
				bly += roundf(gf("fs") / 5.0 + 1.0)
			if a.has("box"):
				var bx: Dictionary = a.box
				var bw := float(bx.get("bw", 0))
				var a2 := HudTheme.asc_desc(st.font, st.fs)
				var l2 := _lh(st.font, st.fs, st.lh)
				var up := a2.x + (l2 - a2.x - a2.y) * 0.5
				var top := by - up - float(bx.get("pt", 0)) - bw
				var hh := l2 + float(bx.get("pt", 0)) + float(bx.get("pb", 0)) + 2.0 * bw
				if bx.has("h"): hh = float(bx.h)
				var bxw: float = a.w - float(bx.get("ml", 0)) - float(bx.get("mr", 0))
				var br := _snap(Rect2(x + float(bx.get("ml", 0)), top, bxw, hh))
				if bx.has("bg"):
					draw_rect(br, bx.bg)
				if bw > 0.0:
					draw_rect(br.grow(-bw * 0.5), bx.get("bc", HudTheme.BORDER_STRONG), false, bw)
				x += float(bx.get("ml", 0)) + bw + float(bx.get("pl", 0))
				if bx.has("c"): col = bx.c
				if bx.has("w"):
					x += (bxw - 2.0 * bw - float(bx.get("pl", 0)) - float(bx.get("pr", 0)) - HudTheme.text_w(st.font, a.t, st.fs, st.ls)) * 0.5
			if bool(a.r.get("pulse", false)):
				col.a *= pulse
			if a.get("sp", false):
				continue
			_draw_chars(st.font, a.t, Vector2(x, bly), st.fs, st.ls, col)

## Per-character drawing at Blink's positions. Sizes that are not whole
## pixels (9.5, 10.5, 13.33) are rasterised at a whole multiple and scaled
## down, so the glyphs are the size CSS asked for rather than the nearest int.
func _draw_chars(font: Font, t: String, p: Vector2, fs: float, ls: float, col: Color) -> void:
	var k := 1.0
	if absf(fs - roundf(fs)) > 0.01:
		for m in [2.0, 3.0, 4.0]:
			if absf(fs * m - roundf(fs * m)) < 0.02:
				k = m; break
		if k == 1.0: k = 4.0
	var isz := int(roundf(fs * k))
	var x := p.x
	if k != 1.0:
		draw_set_transform(Vector2(0, 0), 0.0, Vector2(1.0 / k, 1.0 / k))
	for i in t.length():
		var ch := t.unicode_at(i)
		draw_char(font, Vector2(x * k, p.y * k), t[i], isz, col)
		x += HudTheme.adv_em(font, ch) * fs + ls
	if k != 1.0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

var pulse := 1.0

# ---- scrollbar and backdrop --------------------------------------------------------------

func _sync_thumb() -> void:
	if not overflowing or not scrollbars:
		if _thumb: _thumb.visible = false
		return
	if _thumb == null:
		_thumb = _Thumb.new()
		_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_thumb, false, Node.INTERNAL_MODE_BACK)
	_thumb.visible = true
	var sbw := gf("sbw")
	var inner := size.y - gf("bt") - gf("bb")
	var th := maxf(inner * inner / maxf(content_h - gf("bt") - gf("bb"), 1.0), 18.0)
	var ty := gf("bt") + (inner - th) * (scroll_y / maxf(content_h - size.y, 1.0))
	_thumb.position = Vector2(size.x - gf("br") - sbw, ty)
	_thumb.size = Vector2(sbw, th)
	_thumb.queue_redraw()

class _Thumb extends Control:
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), HudTheme.BORDER_STRONG)

## backdrop-filter: blur(Npx) — the panel's background is drawn by a child
## that samples the screen behind it (show_behind_parent, so the borders and
## text this element draws still go over it).
static var _blur_shader: Shader = null

func _sync_blur() -> void:
	var b := gf("blur")
	if b <= 0.0 or not HudBlur.enabled:
		if _blur: _blur.visible = false
		return
	if _blur == null:
		_blur = ColorRect.new()
		_blur.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_blur.show_behind_parent = true
		var m := ShaderMaterial.new()
		m.shader = HudBlur.shader()
		_blur.material = m
		add_child(_blur, false, Node.INTERNAL_MODE_FRONT)
	_blur.visible = true
	_blur.position = Vector2.ZERO
	_blur.size = size
	var m2: ShaderMaterial = _blur.material
	m2.set_shader_parameter("tint", g("bg"))
	m2.set_shader_parameter("sigma", b)
	m2.set_shader_parameter("px_scale", get_window().content_scale_factor if is_inside_tree() else 1.0)
	_blur_extra(m2)

## Override: extra blur-shader parameters (the start screen's gradient).
func _blur_extra(_m: ShaderMaterial) -> void:
	pass
