extends Node

# ============================================================================
# THE ORCHESTRATOR — the port of blackhole_sim.js.
# ----------------------------------------------------------------------------
# The web build's orchestrator held `state`, the scene/camera/renderer, body
# spawning and trails, physics stepping, camera modes (orbit / free-fly /
# surface), picking, preset loading, every UI binding, the HUD and the render
# loop. In Godot it is split three ways, and the split is the only
# architectural change here:
#
#   · RENDERING moved to render/pipeline.gd — the web build's hand-driven
#     setRenderTarget/autoClear sequence became a SubViewport tree with a
#     compositor hook (see its header).
#   · THE DOM moved to ui/hud.gd — every innerHTML template, class toggle and
#     measured layout. This file tells the Hud what to show and listens to its
#     signals; it never builds a Control.
#   · BODY DERIVATION moved to sim/derive.gd — deriveBody, renderRadius and
#     their tables are physics, and CLAUDE.md prefers a sim/ module to a
#     growing orchestrator.
#
# What stays here is what the web file was for: the frame loop, the camera,
# the body lifecycle, the structural events, and the wiring between modules.
#
# THE FLOATING ORIGIN. Every renderer camera sits at the origin; `cam_pos`
# (a DVec3, scene units) is where the web build's camera.position was, and
# every object is placed each frame at (its scene position − cam_pos),
# subtracted in double precision (PORT_GUIDE.md §3). `b.scene_pos` is what the
# web build called `b.viz.group.position`.
# ============================================================================

const STEP_GUARD := 8000
const TRAIL_MAX := 600
const MESH_Y := -6.0

var state := SimState.new()
var pipe: RenderPipeline
var hud = null                    # Hud
var cam_pos := DVec3.new(0.0, 8.0, 24.0)
var cam_basis := Basis()
var cam_fov := 50.0
var cam_near := 0.01

# The orbit/free camera. Distances in scene units.
var cam := {
	"target": DVec3.new(), "radius": 24.0, "theta": PI / 2.0 - 0.35, "phi": PI / 2.0,
	# Where the viewing distance is HEADING, when something asked for a new one
	# smoothly. null means the camera is exactly where it was put.
	"radius_to": null,
	# free fly
	"yaw": 0.0, "pitch": 0.0, "free_speed": 12.0,
}
var cam_offset := DVec3.new()

var spacetime_mesh = null         # SpacetimeMesh
var painter = null                # Painter
var observer = null               # SurfaceObserver
var sky_pass = null               # SkyPass
var flight = null                 # Spaceflight
var model_view = null             # ModelViewer
var lessons = null
var foundry = null
var inspector = null
var live_editor = null
var stage := {}                   # the course's API (see _build_stage)

var flashes: Array = []           # [{flash: Flash, abs: DVec3}]
var pending_collapse: Array = []
var keys := {}
var manual_dt = null
var model_open := false
var model_restore = null
var xsec_open := false
var learn_entered := false
var last_craft := "saturnv"
var rest_spawn_angle := 0.0
var fps_acc := 0.0
var fps_count := 0
var fps_time := 0.0
var hud_acc := 0.0
var dragging := false
var drag_moved := false
var down_pos := Vector2.ZERO
var last_pos := Vector2.ZERO
var _world_placed: Array = []     # other nodes held at an absolute scene position [node, DVec3]
var _cmd := {}

# The scenario catalogue is grouped here rather than in the physics presets:
# these labels are navigation, while PRESETS remains the source of truth for
# each scenario's initial conditions and rendering settings.
func _preset_group(id: String, label: String, keys_in: Array) -> Dictionary:
	var ks := []
	for k in Presets.PRESET_ORDER:
		if keys_in.has(k): ks.append(k)
	return {"id": id, "label": label, "keys": ks}

var PRESET_GROUPS: Array = []

# Spaceflight is for FLYING. Not one of the orrery's controls belongs in it:
# the scenario list, the interior editor, the painter, the spawner, the body
# list, the imaging bands, the camera modes and — above all — the time-scale
# slider are all things you do to a universe you are looking at.
# (SECTION_MODE / OPEN_BY_DEFAULT live with the sections, in ui/hud.gd.)

# ============================================================================
# BOOT
# ============================================================================
func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=", true, 1)
		_cmd[kv[0]] = kv[1] if kv.size() > 1 else ""
	# CSS px = Godot logical px: the window's content scale is the display
	# scale, as a browser's devicePixelRatio. The screenshot mode instead takes
	# window pixels as CSS pixels, as the web reference shots (deviceScaleFactor 1) do.
	var scale := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	get_window().content_scale_factor = 1.0 if _cmd.has("out") else scale
	get_window().min_size = Vector2i(900, 600)

	PRESET_GROUPS = [
		# The course's own scenarios are in the list like everything else. A lesson
		# opens one, but nothing about them is only reachable through a lesson.
		_preset_group("learning", "Learning scenarios", [
			"edu_seasons", "edu_moon", "edu_kepler", "edu_habitable", "edu_starbirth",
			"edu_sun", "edu_lifecycle", "edu_supernova", "edu_pulsar", "edu_transit",
			"edu_hole", "edu_galaxy", "edu_cluster"]),
		_preset_group("trisolaris", "Trisolaris scenarios", ["trisolaris", "trisolaris_wander", "trisolaris_compact", "trisolaris_wide", "trisolaris_alpha", "trisolaris_chaos"]),
		_preset_group("black-holes", "BH scenarios", ["bhmerger", "feeding"]),
		_preset_group("neutron-stars", "Neutron star scenarios", ["nsmerger"]),
		_preset_group("sandboxes", "Sandboxes", ["blank", "sandbox"]),
		_preset_group("real-stars", "Real stars", ["stellar_zoo", "sirius", "vega", "achernar", "betelgeuse", "alphacen", "etacar", "hr_ladder"]),
		_preset_group("stellar-systems", "Stellar system scenarios", ["solar", "threebody", "binarystar"]),
	]

	pipe = RenderPipeline.new()
	pipe.name = "Pipeline"
	add_child(pipe)
	var bg := CanvasLayer.new()
	bg.layer = -1
	add_child(bg)
	bg.add_child(pipe.display)
	SkyModel.init_sky_materials(pipe.sky_materials)

	spacetime_mesh = SpacetimeMesh.new()
	pipe.world_root.add_child(spacetime_mesh.node)

	painter = Painter.create_painter({
		"root": pipe.world_root,
		"get_body": func(id): return state.body_by_id(id),
		"get_scene_scale": func(): return state.scene_scale,
	})

	observer = SkyView.SurfaceObserver.new()
	sky_pass = SkyView.create_sky_pass()

	var ui_layer := CanvasLayer.new()
	ui_layer.layer = 1
	add_child(ui_layer)
	hud = Hud.new()
	hud.name = "Hud"
	ui_layer.add_child(hud)
	_bind_hud()

	flight = Spaceflight.create_spaceflight({
		"pipe": pipe, "state": state, "main": self,
		"panel": hud.mount("flightHud"),
		"toast": func(m): toast(m),
	})
	model_view = ModelViewer.create_model_viewer(pipe)
	_build_stage()
	lessons = LessonUI.create_lessons({"panel": hud.mount("courseMount"), "card": hud.mount("lessonCard"), "stage": stage})
	_build_foundry()

	hud.build_band_grid(Spectrum.BANDS)
	set_band(Spectrum.VISIBLE_BAND)
	hud.build_sky_settings(SkyModel.SKY_ENVIRONMENTS.keys(), SkyModel.SKY_PARAMS)
	_init_fx_rows()
	render_preset_groups()
	render_craft_grid()
	hud.render_model_grid(model_view.list())

	# The panels only make sense once both simulators exist, so the initial mode
	# is applied here rather than where it is defined.
	for id in ["settingsPanel", "scenarioPanel", "controlPanel"]: set_panel_open(id, true)
	# The flight panel starts closed and only opens when there is a vessel.
	set_panel_open("flightPanel", false)
	# The cross-section starts closed and has no tab: it is opened from a focused
	# body, so there is nothing to come back to until one is focused.
	set_panel_open("xsecPanel", false)
	set_app_mode("sandbox", {"quiet": true})

	get_viewport().size_changed.connect(resize)
	resize()
	# The web build took the scenario from the URL hash; here it is `preset=key`
	# on the command line, with the same own-property check.
	var k: String = _cmd.get("preset", "sandbox")
	load_preset(k if Presets.PRESETS.has(k) else "sandbox")
	if _cmd.has("mode"):
		_start(_cmd.mode)

# ============================================================================
# BODY CREATION
# ============================================================================
# Stars are coloured from their blackbody temperature unless a preset
# deliberately overrides it (the figure-eight uses colour to tell bodies apart).
func _star_color(b: Body):
	var spec := b.spec
	if spec.get("color") != null: return U.lin(int(spec.color))
	if b.teff != null: return Stellar.blackbody_color(float(b.teff))
	return null

# ---------------------------------------------------------------------------
# Build (or rebuild) a body's renderable half from its stored spec. Split out
# of spawnBody so the size convention can change at runtime — the physics body
# keeps its position, velocity and mass; only the meshes are thrown away.
# ---------------------------------------------------------------------------
func attach_visual(b: Body) -> void:
	var spec := b.spec
	var def := b.def
	var radius_scene := Derive.render_radius(b, spec, b.mass0, state.scene_scale, state.body_scale, state.true_scale)
	b.radius_scene = radius_scene
	# Destruction distance. By default a body is destroyed when it touches what
	# you can SEE, which keeps the exaggerated view self-consistent. A spec may
	# override it with a real distance in AU (the Roche limits in sim/presets),
	# and a MEASURED radius is such an override: the Moon orbits 0.00257 AU from
	# an Earth whose exaggerated disc is 0.15 AU across.
	b.contact_au = Derive.contact_au(b, spec, radius_scene, state.scene_scale)
	if spec.type == "bh": b.rs_scene = radius_scene

	var star_color = _star_color(b)
	var is_star_like: bool = spec.type == "star" or spec.type == "white-dwarf"
	# Rotational flattening and gravity darkening, from sim/structure.gd. A star
	# spun to 88% of break-up is measurably lens-shaped and measurably two-tone,
	# and both are consequences of the same one number.
	var st: Dictionary = b.structure
	var gd = null
	if is_star_like and b.teff != null:
		gd = Structure.gravity_darkened_temps(float(b.teff), b.spin_frac)
	var flat: float = float(st.get("flattening", 0.0)) if st else 0.0
	var opts := {
		"radiusScene": radius_scene,
		"oblate": 1.0 / (1.0 - flat) if flat else 1.0,
		"spinFrac": b.spin_frac,
		"tPole": gd.tPole if gd else null, "tEq": gd.tEq if gd else null, "gdBeta": gd.beta if gd else null,
		"radiusSun": b.radius_sun if b.radius_sun != null else (b.radius / Physics.AU_PER_RSUN if b.radius else null),
		"color": star_color if is_star_like else U.nz(spec.get("color"), def.color),
		"teff": b.teff,
		"glow": U.nz(spec.get("glow"), def.glow),
		"seed": spec.get("seed"),
		"obliquity": spec.get("obliquity"), "tidalLock": spec.get("tidalLock"),
		"paletteName": spec.get("palette"),
		"hot": spec.get("hot"), "atmosphere": spec.get("atmosphere"), "atmColor": spec.get("atmColor"),
		"seaLevel": spec.get("seaLevel"), "rings": spec.get("rings"), "ringColor": spec.get("ringColor"),
		# Surface/atmosphere model parameters. Every one of them has a physical
		# default, so a preset only names the ones where the body is unusual.
		"land": spec.get("land"), "albedo": spec.get("albedo"), "greenhouse": spec.get("greenhouse"),
		"surfaceK": spec.get("surfaceK"), "frostK": spec.get("frostK"), "biota": spec.get("biota"),
		"crater": spec.get("crater"), "regolith": spec.get("regolith"), "haze": spec.get("haze"),
		"cloudCover": spec.get("cloudCover"), "cloudColor": spec.get("cloudColor"), "atmThick": spec.get("atmThick"),
		"ringInner": spec.get("ringInner"), "ringOuter": spec.get("ringOuter"),
		"internalHeat": spec.get("internalHeat"), "vortices": spec.get("vortices"),
		"transport": spec.get("transport"), "season": spec.get("season"), "arid": spec.get("arid"),
		"plateScale": spec.get("plateScale"), "landRelief": spec.get("landRelief"), "oceanDepth": spec.get("oceanDepth"),
	}
	var viz = Bodies.create_body_visual(b, opts)
	b.viz = viz
	var g: Node3D = viz.group
	# Rotational flattening for everything that is NOT a star: the star shader
	# deforms its own mesh onto the Roche surface, but a planet or a neutron star
	# has no such shader, so its group is scaled into the spheroid instead.
	# Volume is conserved by sim/structure.gd, so this bulges the body rather
	# than inflating it — Jupiter really is 6.5% wider than it is tall.
	if flat > 1e-4 and spec.type != "star" and spec.type != "white-dwarf":
		var k := float(st.radiusEqAU) / (float(st.radiusAU) if st.radiusAU else 1.0)
		g.scale = Vector3(k, k * (1.0 - flat), k)
	g.set_meta("body_id", b.id)
	g.set_meta("base_scale", g.scale.x if g.scale.x else 1.0)
	# The full (possibly oblate) scale, kept so the size ease can multiply it
	# without flattening a spheroid back into a sphere.
	g.set_meta("base_vec", g.scale)
	b.size_k = 1.0
	g.position = b.scene_pos.rel_v3(cam_pos)
	pipe.world_root.add_child(g)

	# Point-source marker: what keeps a true-scale body visible once its disc
	# falls below a pixel. It lives in the scene rather than under the group so
	# its size is never coupled to whatever the body's own visual does to its
	# transform (tidal stretching, flare pulses).
	var emitter := is_star_like
	# What you see of a distant hole is not the hole, it is the disc, so the
	# marker takes the disc's peak temperature — colour AND the temperature the
	# imaging bands re-image from. A stellar-mass hole is then correctly dim in
	# the radio and blazing in X-ray, which is exactly how one is found.
	var is_hole: bool = spec.type == "bh"
	var disc_t := Derive.disc_peak_temp(b.mass) if is_hole else 0.0
	var marker_color: Color
	if emitter:
		marker_color = star_color if star_color != null else (Stellar.blackbody_color(float(b.teff)) if b.teff != null else U.lin(0xfff2cc))
	elif is_hole:
		# the Planck colour fit saturates long before 10⁷ K; past ~40 000 K the eye
		# has nothing left to say beyond "blue-white", so clamp rather than extrapolate
		marker_color = Stellar.blackbody_color(minf(disc_t, 4.0e4))
	else:
		marker_color = U.lin(int(U.nz(spec.get("color"), def.color)))
	var gain := 2.2
	if spec.type == "star": gain = 26.0
	elif spec.type == "neutron" or spec.type == "white-dwarf" or is_hole: gain = 18.0
	b.marker = Marker.create_marker({
		"color": marker_color,
		"teff": disc_t if is_hole else float(U.nz(b.teff, 0.0)),
		# Emitters must stay bright enough to survive tone mapping and trip the
		# bloom; reflectors only need to be seen.
		"gain": gain,
	})
	pipe.world_root.add_child(b.marker.mesh)

func detach_visual(b: Body) -> void:
	if b.viz != null:
		if b.viz.has_method("dispose"): b.viz.dispose()
		var g: Node3D = b.viz.group
		if is_instance_valid(g): g.queue_free()
		b.viz = null
	if b.marker != null:
		b.marker.dispose()
		if is_instance_valid(b.marker.mesh): b.marker.mesh.queue_free()
		b.marker = null

# ---------------------------------------------------------------------------
# Size easing. An edit rebuilds the mesh at the new radius immediately — it has
# to, because the whole visual is derived from that radius — so without this an
# object that doubles in mass CUTS to its new size. The mesh is started back at
# the size it had and grows into the new one over ~0.25 s, geometrically,
# because radius is a scale.
# ---------------------------------------------------------------------------
func apply_size_ease(b: Body, dt: float) -> void:
	var e = b.size_ease
	if e == null: return
	e.t = minf(1.0, e.t + dt / 0.25)
	var k: float = pow(e.from, 1.0 - e.t)          # from → 1
	b.size_k = k
	if b.viz != null:
		var base: Vector3 = b.viz.group.get_meta("base_vec", Vector3.ONE)
		b.viz.group.scale = base * k
	if e.t >= 1.0:
		b.size_ease = null
		b.size_k = 1.0

# Swap every body between true and exaggerated size in place. Rebuilding is the
# honest way to do this: each visual bakes its radius into geometry and into
# local-space offsets (corona span, ring radii, prominence loops).
func rebuild_visuals() -> void:
	for b in state.bodies:
		detach_visual(b)
		attach_visual(b)
	# the follow distance was framed for the old size and is now meaningless
	var fb := state.body_by_id(state.follow_id)
	if fb: jump_cam_radius(frame_radius(fb))
	if state.cam_mode == "orbit": update_orbit_cam()

func refresh_structure(b: Body) -> Dictionary:
	return Derive.refresh_structure(b)

func spawn_body(spec: Dictionary) -> Body:
	var b := Derive.new_body(state.next_id, spec)
	state.next_id += 1
	b.scene_pos = b.pos.scaled(state.scene_scale)
	attach_visual(b)
	if spec.type == "world" and spec.get("home"): state.home_id = b.id

	# trail — compact bodies (tight, fast inspirals) get a short, faint trail so
	# the dense loops don't obscure what's happening; everything else gets a long one.
	var compact: bool = spec.type == "bh" or spec.type == "neutron"
	b.trail_max = 130 if compact else TRAIL_MAX
	b.trail_opacity = 0.28 if compact else 0.5
	b.trail_color = U.lin(int(U.nz(spec.get("color"), U.nz(b.def.get("glow"), 0x88aaff))))
	b.trail_buf = PackedFloat64Array()
	b.trail_buf.resize(b.trail_max * 3)
	b.trail_head = 0
	b.trail_count = 0
	b.trail = Trail.new(b.trail_max, b.trail_color, b.trail_opacity)
	pipe.world_root.add_child(b.trail.node)

	state.bodies.append(b)
	return b

func remove_body(id) -> void:
	var idx := -1
	for i in state.bodies.size():
		if state.bodies[i].id == id:
			idx = i
			break
	if idx < 0: return
	var b: Body = state.bodies[idx]
	detach_visual(b)
	if b.trail != null:
		b.trail.node.queue_free()
		b.trail = null
	state.bodies.remove_at(idx)
	if state.focus_id == id:
		state.focus_id = null
		state.follow_id = null
	refresh_ui()

# Empty the scene. Not just the body list: flashes live on their own clock and
# everything the painter holds tracks a body by id, so both have to go with it
# or the scene is not actually clear.
func clear_bodies() -> void:
	while not state.bodies.is_empty():
		remove_body(state.bodies[0].id)
	for f in flashes:
		f.flash.kill()
	flashes.clear()
	painter.clear()
	state.consumed = 0
	refresh_ui()

# add a body orbiting the dominant mass (used by Spawn buttons)
func spawn_orbiting(type: String) -> void:
	var palette = ["jupiter", "saturn", "ice"][randi() % 3] if type == "gas-giant" else null
	spawn_body(place_spawn({"type": type, "palette": palette, "atmosphere": type == "planet", "seed": randi() % 1000000000}))
	refresh_ui()

func _dominant() -> Body:
	var c: Body = null
	for b in state.bodies:
		if c == null or b.mass > c.mass: c = b
	return c

# ---------------------------------------------------------------------------
# Put a spec on a circular orbit about the dominant mass. Shared by the quick
# spawn buttons and by the Object Foundry, so a hand-built 40 M☉ star arrives
# the same way a quick-spawn planet does.
# ---------------------------------------------------------------------------
func orbit_spec_around_dominant(spec: Dictionary) -> Dictionary:
	var center := _dominant()
	var Mc := maxf(center.mass, 1e-6) if center else 1.0
	var cpos := center.pos if center else DVec3.new()
	# Stay clear of whatever we are orbiting: outside its rendered disc, and
	# outside its horizon by a wide margin if it is a hole.
	var clear_au := maxf(maxf(center.radius_scene / state.scene_scale, center.rs * 8.0), center.radius) if center else 0.0
	var a_au := clear_au * 2.5 + (5.0 + randf() * 9.0) / state.scene_scale
	var ang := randf() * TAU
	var pos := cpos.add(DVec3.new(cos(ang), 0.0, sin(ang)).scaled(a_au))
	var v := Physics.circular_speed(Mc + float(U.nz(spec.get("mass"), 0.0)), a_au)
	var tang := DVec3.new(-sin(ang), 0.0, cos(ang)).scaled(v)
	if center: tang.add_in(center.vel)
	var out := spec.duplicate()
	out.pos = pos.to_array()
	out.vel = tang.to_array()
	return out

# ---------------------------------------------------------------------------
# Place a spec AT REST, in front of the camera. "At rest" means exactly zero
# velocity in the simulation frame, so a body dropped into a moving system
# really does get left behind by it. It goes where you are looking, offset by
# a fraction of the viewing distance so successive spawns do not land inside
# each other.
# ---------------------------------------------------------------------------
func rest_spec_at_rest(spec: Dictionary) -> Dictionary:
	var centre := DVec3.new()
	var reach: float
	if state.cam_mode == "free":
		var fwd := DVec3.new(sin(cam.yaw) * cos(cam.pitch), sin(cam.pitch), cos(cam.yaw) * cos(cam.pitch))
		reach = maxf(cam.free_speed * 1.5, 2.0)
		centre.copy_from(cam_pos).add_scaled_in(fwd, reach)
	else:
		centre.copy_from(cam.target)
		reach = cam.radius
	# Fan successive spawns around the look-at point instead of stacking them.
	rest_spawn_angle += 2.399963                       # golden angle, so they spread
	var off := reach * 0.32
	centre.x += cos(rest_spawn_angle) * off
	centre.z += sin(rest_spawn_angle) * off
	var pos_au := centre.scaled(1.0 / state.scene_scale)
	var out := spec.duplicate()
	out.pos = pos_au.to_array()
	out.vel = [0.0, 0.0, 0.0]
	return out

# Spawn placement, chosen by the scenario: at rest on the workbench, in orbit
# everywhere else. An empty scene has no dominant mass to orbit, so it always
# falls back to at-rest regardless of the toggle.
func place_spawn(spec: Dictionary) -> Dictionary:
	return rest_spec_at_rest(spec) if (state.spawn_at_rest or state.bodies.is_empty()) else orbit_spec_around_dominant(spec)

# ---------------------------------------------------------------------------
# LIVE EDIT — the Foundry's sliders, pointed at a body that already exists.
# Building an object and then editing one are the same operation here: both end
# in derive_body() re-reading a spec. The physics state survives; everything
# the spec implies is derived again, and the meshes with it. The edit is then
# passed straight to check_structural_limits: drag a 2.0 M☉ neutron star up and
# it becomes a black hole, at exactly the mass sim/structure.gd says it must.
# ---------------------------------------------------------------------------
func edit_body(b: Body, patch: Dictionary):
	if b == null or not b.alive: return null
	var spec := U.merged(b.spec, patch)
	if patch.get("mass") != null:
		b.mass = float(patch.mass); b.mass0 = float(patch.mass)
		spec.mass = float(patch.mass)
		# Measured beats modelled — but a measurement describes ONE star. Once you
		# have changed its mass those numbers are no longer about this object.
		for k in ["radiusSun", "teff", "luminosity", "radiusKm", "rs"]: spec.erase(k)
		b.radius_sun = null
	b.spec = spec
	var before := b.radius_scene
	detach_visual(b)
	Derive.derive_body(b, spec)
	attach_visual(b)
	# Keep the followed body framed while it is being edited: the camera glides
	# and the mesh eases from its old size over the same time constant.
	var r := maxf(b.radius_scene, b.rs_scene)
	if before > 0.0 and r > 0.0:
		var jump := r / before
		if absf(log(jump)) > 0.01:
			b.size_ease = {"from": 1.0 / jump, "t": 0.0}
			if b.id == state.follow_id and state.cam_mode == "orbit":
				cam.radius_to = minf(frame_radius(b), 20000.0)
	# A verdict the sim only prints is a bug.
	b.m_check = null
	check_structural_limits(b)
	refresh_ui()
	return b

# ============================================================================
# STRUCTURAL CONSEQUENCES
# ----------------------------------------------------------------------------
# The interior model is not decoration: when it says a body can no longer hold
# itself up, the body has to stop existing as that kind of body — a neutron
# star past its TOV mass collapses, a star at the end of its life goes core
# collapse (or leaves nothing), and a body that crosses an ignition threshold
# is rebuilt as the new kind of object.
# ============================================================================
func transmute(b: Body, new_type: String, why) -> void:
	var wpos := b.scene_pos.clone()
	b.type = new_type
	# spinFrac rides in the spec because derive_body reads it from there.
	b.spec = U.merged(b.spec, {"type": new_type, "mass": b.mass, "spinFrac": b.spin_frac})
	b.def = Derive.TYPE_DEFAULTS.get(new_type, Derive.TYPE_DEFAULTS.planet)
	if new_type == "bh":
		b.rs = Physics.schwarzschild(b.mass)
		b.radius = 0.0
		# A horizon has no photosphere; leaving a temperature behind would keep
		# re-imaging it as a star in the non-visible bands.
		b.teff = null; b.spectral = null; b.luminosity = null
		b.radius_sun = null
		b.emits_gw = true
		b.spec.rs = b.rs      # so derive_body keeps this horizon rather than re-deriving one
		spawn_flash(wpos, 0xffffff, maxf(b.rs * state.scene_scale * 9.0, 0.6), 1.4)
		spawn_flash(wpos, 0x9fd0ff, maxf(b.rs * state.scene_scale * 5.0, 0.4), 0.3)
	detach_visual(b)
	# Re-derive, don't just re-measure: building a body and editing one are the
	# same operation.
	Derive.derive_body(b, b.spec)
	attach_visual(b)
	if why: toast(why, 5200)
	refresh_ui()

# A star at the end of its life. What it leaves behind is decided by
# end_state_of(), and in the pair-instability window it leaves nothing.
func core_collapse(b: Body) -> void:
	var end: Dictionary = Structure.end_state_of(b.mass)
	var wpos := b.scene_pos.clone()
	var size := maxf(b.radius_scene * 22.0, 1.5)
	# Stand back far enough that the blast is something you watch rather than
	# something you are inside.
	recoil_camera(b, size)
	spawn_flash(wpos, 0xffffff, size, 0.55)
	spawn_flash(wpos, 0xffd0a0, size * 0.6, 0.16, {"kind": "shell", "grow": 12.0})
	state.consumed += 1
	if end.type == "none":
		toast("%s: pair-instability supernova — no remnant at all" % b.name, 6000)
		spawn_flash(wpos, 0x9fd8ff, size * 1.6, 0.10, {"kind": "shell", "grow": 18.0})
		remove_body(b.id)
		return
	b.mass = float(end.mass); b.mass0 = float(end.mass)
	b.spin_frac = minf(b.spin_frac + 0.55, 0.95)   # collapse spins it up
	if end.type == "neutron":
		b.radius = Physics.neutron_radius(b.mass)
		b.spec = U.merged(b.spec, {"type": "neutron", "mass": b.mass, "spin": 30})
		b.teff = null
		transmute(b, "neutron", "%s: core collapse → %s (%s)" % [b.name, end.label, CrossSection.fmt_mass(float(end.mass))])
	elif end.type == "bh":
		transmute(b, "bh", "%s: core collapse → %s (%s)" % [b.name, end.label, CrossSection.fmt_mass(float(end.mass))])
	else:
		b.radius_sun = Structure.white_dwarf_radius_sun(b.mass)
		b.radius = float(b.radius_sun) * Physics.AU_PER_RSUN
		b.teff = 30000.0
		b.spec = U.merged(b.spec, {"type": "white-dwarf", "mass": b.mass, "teff": 30000.0})
		transmute(b, "white-dwarf", "%s: envelope shed → %s (%s)" % [b.name, end.label, CrossSection.fmt_mass(float(end.mass))])

# Stand back from an explosion you were watching from close up — but only for
# whoever was following the body, never pulling IN, and as a glide.
func recoil_camera(b: Body, blast_size: float) -> void:
	if b.id != state.follow_id or state.cam_mode != "orbit": return
	cam.radius_to = minf(maxf(cam.radius, blast_size * 2.4), 20000.0)

# Called for any body whose mass has moved. Cheap — it only recomputes the
# structure when the mass actually changed by more than a part in a thousand.
func check_structural_limits(b: Body) -> void:
	if not b.alive or b.type == "bh": return
	if b.m_check != null and absf(b.mass - float(b.m_check)) < float(b.m_check) * 1e-3: return
	b.m_check = b.mass
	var st := refresh_structure(b)

	if b.type == "neutron" and b.mass > Structure.tov_limit(b.spin_frac):
		transmute(b, "bh", "%s passed the TOV limit at %s — nothing can hold it up. Collapsed to a black hole." % [b.name, CrossSection.fmt_mass(b.mass)])
		return
	if b.type == "white-dwarf" and b.mass >= Structure.LIMITS.chandrasekhar:
		var wpos := b.scene_pos.clone()
		var blast := maxf(b.radius_scene * 40.0, 2.0)
		recoil_camera(b, blast)
		spawn_flash(wpos, 0xffffff, blast, 0.4)
		# The ejecta. A Type Ia unbinds the entire star at ~10 000 km/s, so this
		# is the one that must not still be sitting there looking like a star.
		spawn_flash(wpos, 0xbfe0ff, blast * 0.6, 0.12, {"kind": "shell", "grow": 14.0})
		toast("%s reached the Chandrasekhar mass — Type Ia supernova, nothing left" % b.name, 6000)
		state.consumed += 1
		remove_body(b.id)
		return
	# A body that has crossed an ignition threshold is a different object.
	if st.get("type") != b.type and st.get("reclassifiedFrom"):
		transmute(b, st.type, "%s: %s" % [b.name, st.verdict.detail])

# ============================================================================
# FLASH SPRITES — sim/flash.gd holds the two kinds (light vs matter).
# ============================================================================
func spawn_flash(world_pos: DVec3, color: int, size: float, decay: float = 0.8, opt: Dictionary = {}) -> void:
	var f = Flash.create(color, size, decay, float(opt.get("grow", 2.0)), String(opt.get("kind", "flash")))
	pipe.world_root.add_child(f.node)
	f.node.position = world_pos.rel_v3(cam_pos)
	flashes.append({"flash": f, "abs": world_pos.clone()})

# ============================================================================
# PHYSICS STEP
# ============================================================================
func get_holes() -> Array:
	var hs := state.bodies.filter(func(b): return b.type == "bh")
	hs.sort_custom(func(a, b): return a.mass > b.mass)
	return hs

func get_stars() -> Array:
	# White dwarfs light a scene too — Sirius B is 25 000 K, hotter than Sirius A.
	return state.bodies.filter(func(b): return (b.type == "star" or b.type == "white-dwarf") and b.alive)

func get_home() -> Body:
	return state.body_by_id(state.home_id) if state.home_id != null else null

# Hottest emitter in the scene, in kelvin. The multi-wavelength imaging anchors
# its gain to this — see PostFX.set_scene_temp.
func scene_max_temp() -> float:
	var t := 0.0
	for b in state.bodies:
		if b.type == "star" or b.type == "white-dwarf": t = maxf(t, float(U.nz(b.teff, Stellar.effective_temp(b.mass))))
		elif b.type == "neutron": t = maxf(t, 1.0e6)
		elif b.type == "bh": t = maxf(t, Derive.disc_peak_temp(b.mass))
	return t if t else 5800.0

# Build the per-frame sun description used by every lighting path: the world
# shader, the sky shader and the surface view. Intensity is the star's flux AT
# THE HOME WORLD in solar constants, so the visual brightness of each sun
# tracks the same number the climate model is integrating. (The web build also
# drove a pool of THREE point lights from this; nothing in the orrery used a
# lit material, so they lit nothing and are not ported.)
func update_suns() -> void:
	var stars := get_stars()
	var home := get_home()
	state.suns.clear()
	for s in stars:
		var L: float = float(U.nz(s.luminosity, Stellar.luminosity(s.mass))) * (s.activity.flux if s.activity != null else 1.0)
		var d := maxf(home.pos.distance_to(s.pos), 1e-3) if home else 1.0
		state.suns.append({
			"body": s,
			"pos_rel": s.scene_pos.rel_v3(cam_pos),
			"pos_abs": s.scene_pos,
			"color": Stellar.blackbody_color(float(U.nz(s.teff, Stellar.effective_temp(s.mass)))),
			"intensity": L / (d * d) if home else L,
			"dist_au": d,
			# true angular RADIUS as rendered, for the sky pass
			"ang_radius": atan(s.radius_scene / maxf(d * state.scene_scale, 1e-4)),
			# and the physically true one, for the readout
			"ang_true": atan(Physics.stellar_radius(s.mass) / d),
		})
	state.suns.sort_custom(func(a, b): return a.intensity > b.intensity)

# Smallest resolved-needs timescale among bodies — the dynamical time of the
# tightest/fastest pair (sim/derive.gd).
func dynamic_step() -> float:
	return Derive.dynamic_step(state.bodies, state.max_step)

# Returns the simulated time actually integrated, which is <= sim_dt whenever
# the sub-step guard trips. Callers must drive anything on the simulated clock
# from the return value, not from what they passed in.
func step_physics(sim_dt: float) -> float:
	if sim_dt <= 0.0:
		state.last_steps = 0
		_commit_positions(false)
		return 0.0
	# The sub-step loop itself (dynamicStep, velocity-Verlet, GW reaction,
	# collisions) runs natively when native/ is built — sim/nbody.gd — and in
	# GDScript otherwise; handle_merger runs between sub-steps either way.
	var r := NBody.step_physics(state.bodies, sim_dt, state.max_step, state.gw_boost, handle_merger)
	var stepped: float = r.stepped
	state.last_steps = int(r.steps)
	# Advance the clock by what was actually integrated, not by what was asked
	# for: the deficit during a guarded close encounter is never repaid.
	state.sim_years += stepped
	_commit_positions(true)
	# advance the climate on the same simulated clock
	var home := get_home()
	if state.climate != null and home: state.climate.step(stepped, home, get_stars())
	return stepped

# commit scene positions + trails after the sub-steps
func _commit_positions(push: bool) -> void:
	for b in state.bodies:
		b.scene_pos.set_v(b.pos.x * state.scene_scale, b.pos.y * state.scene_scale, b.pos.z * state.scene_scale)
		if push: push_trail(b)

func handle_merger(ev: Dictionary) -> void:
	var surv: Body = ev.survivor
	var gone: Body = ev.absorbed
	var wpos := surv.pos.scaled(state.scene_scale)
	if surv.type == "bh" or gone.type == "bh":
		var was_bh := surv.type == "bh"
		surv.type = "bh"
		if was_bh:
			# r_s ∝ M, so summing the two horizons is exactly the horizon of the
			# merged mass — and it carries a preset's deliberately "fat" horizon
			# through the merger instead of collapsing it to the true one.
			surv.rs = surv.rs + (gone.rs if gone.type == "bh" else Physics.schwarzschild(gone.mass))
		else:
			# resolve_collisions keeps the heavier body, so a star heavier than the
			# hole survives and becomes one. Scale the absorbed horizon by the mass
			# it now contains.
			surv.rs = gone.rs * (surv.mass / gone.mass)
		if not surv.rs: surv.rs = Physics.schwarzschild(surv.mass)
		# The physics type changed, so the spec and the meshes have to follow it.
		if not was_bh:
			surv.spec = U.merged(surv.spec, {"type": "bh", "mass": surv.mass, "rs": surv.rs})
			surv.def = Derive.TYPE_DEFAULTS.bh
			surv.teff = null; surv.spectral = null
			detach_visual(surv)
			attach_visual(surv)
		var rs_s := surv.rs * state.scene_scale
		spawn_flash(wpos, 0xffffff, rs_s * 9.0, 1.6)             # bright ringdown burst
		spawn_flash(wpos, 0xffd2a0, rs_s * 5.0, 0.32)            # slow lingering afterglow
	elif surv.type == "neutron" and gone.type == "neutron":
		spawn_flash(wpos, 0xffffff, surv.radius_scene * 60.0, 1.4)
		# kilonova: the tidal tails and the disc wind, which really are ejecta
		spawn_flash(wpos, 0xbfe0ff, surv.radius_scene * 34.0, 0.28, {"kind": "shell", "grow": 10.0})
	else:
		spawn_flash(wpos, 0xffaa66, surv.radius_scene * 14.0, 0.8, {"kind": "shell", "grow": 6.0})
	state.consumed += 1
	remove_body(gone.id)
	refresh_ui()

func push_trail(b: Body) -> void:
	if b.trail == null: return
	var M := b.trail_max
	var head := b.trail_head
	b.trail_buf[head * 3] = b.scene_pos.x
	b.trail_buf[head * 3 + 1] = b.scene_pos.y
	b.trail_buf[head * 3 + 2] = b.scene_pos.z
	b.trail_head = (head + 1) % M
	b.trail_count = mini(b.trail_count + 1, M)
	b.trail.dirty = true

# ============================================================================
# CAMERA — orbit + free-fly + click-to-focus
# ============================================================================
# Put the camera at a distance immediately, cancelling any glide in progress.
func jump_cam_radius(r: float) -> void:
	cam.radius = r
	cam.radius_to = null

# The distance to frame a body from: seven of its radii, but never closer than
# the scene can actually resolve. (Positions reach shaders as float32 in the web
# build, so a body D units from the origin is known to D·1e-5; the floating
# origin removes most of that here, but the floor is kept so the two builds
# frame a collapsing star's remnant identically.)
func frame_radius(b: Body) -> float:
	var geometric := maxf(b.radius_scene, b.rs_scene) * 7.0
	var resolvable := maxf(1e-6, b.scene_pos.length() * 1e-5)
	if geometric >= resolvable: return geometric
	return maxf(cam.radius, resolvable)

# Ask for a distance instead of taking one. Geometric (log-space) easing,
# because viewing distance is a scale.
func ease_cam_radius(dt: float) -> void:
	if cam.radius_to == null: return
	var ratio: float = cam.radius_to / cam.radius
	if absf(log(ratio)) < 0.01:
		cam.radius = cam.radius_to
		cam.radius_to = null
		return
	# frame-rate independent: same time constant at 30 and 144 fps
	cam.radius *= pow(ratio, 1.0 - exp(-dt * 6.0))

# ---- following a moving body. Track the body EXACTLY, and carry the smoothing
# in a separate offset that decays to zero on its own (a fractional catch-up is
# a first-order lag with a steady-state error proportional to the body's speed
# — the rubber-banding — and no k below 1 removes it).
func track_follow(b: Body, dt: float) -> void:
	if cam_offset.length_sq() > 0.0:
		cam_offset.scale_in(exp(-dt * 5.0))
		if cam_offset.length_sq() < pow(cam.radius * 1e-4, 2.0): cam_offset.set_v(0, 0, 0)
	cam.target.copy_from(b.scene_pos).add_in(cam_offset)

# Hand the camera a new target without teleporting the view: the difference
# becomes the decaying offset, so the glide happens in track_follow.
func glide_target_to(p: DVec3) -> void:
	cam_offset.copy_from(cam.target).sub_in(p)
	# A jump across the whole system is not a glide, it is a cut.
	if cam_offset.length_sq() > pow(cam.radius * 40.0, 2.0): cam_offset.set_v(0, 0, 0)
	cam.target.copy_from(p).add_in(cam_offset)

func _look_at(target: DVec3, up := Vector3.UP) -> void:
	var d := target.rel_v3(cam_pos)
	if d.length_squared() > 0.0:
		cam_basis = Basis.looking_at(d.normalized(), up)

func update_orbit_cam() -> void:
	var r: float = cam.radius; var th: float = cam.theta; var ph: float = cam.phi
	cam_pos.set_v(r * sin(th) * cos(ph), r * cos(th), r * sin(th) * sin(ph)).add_in(cam.target)
	_look_at(cam.target)

# Pick radius in scene units. Clicking works off the body's rendered disc, and
# once a body has handed over to its point-source marker the marker's own
# on-screen footprint becomes the target instead.
func pick_radius_scene(b: Body) -> float:
	var geometric := maxf(b.radius_scene, b.rs_scene) * 1.6
	if b.marker == null or not b.marker.mesh.visible: return geometric
	return maxf(geometric, b.marker.mesh.scale.x * 0.42)

func set_follow(body: Body) -> void:
	state.follow_id = body.id if body else null
	state.focus_id = body.id if body else null
	if body:
		glide_target_to(body.scene_pos)
		# frame the body itself — a 4-unit floor put small worlds a hundred radii away
		jump_cam_radius(frame_radius(body))
		if state.cam_mode == "orbit": update_orbit_cam()
	refresh_ui()

func _view_size() -> Vector2:
	return Vector2(pipe.view_size)

func handle_pick(pos: Vector2) -> void:
	if state.cam_mode == "flight": return
	var vs := _view_size()
	var ndc := Vector2(pos.x / vs.x * 2.0 - 1.0, -(pos.y / vs.y) * 2.0 + 1.0)
	var f := tan(deg_to_rad(cam_fov) * 0.5)
	var dir := (cam_basis * Vector3(ndc.x * f * vs.x / vs.y, ndc.y * f, -1.0)).normalized()
	var best: Body = null
	var best_d := INF
	for b in state.bodies:
		var wp: Vector3 = b.scene_pos.rel_v3(cam_pos)       # the ray starts at the origin
		var along: float = wp.dot(dir)
		if along < 0.0: continue
		var d: float = (wp - dir * along).length()
		if d < pick_radius_scene(b) and along < best_d:
			best = b
			best_d = along
	set_follow(best)

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				dragging = true; drag_moved = false
				down_pos = mb.position; last_pos = mb.position
			else:
				# Only interactions that began on the canvas are picks.
				var was := dragging
				dragging = false
				if was and not drag_moved and not model_open: handle_pick(mb.position)
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			# A wheel notch is ~100 deltaY in a browser.
			var dy := -100.0 * mb.factor if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 100.0 * mb.factor
			_wheel(dy)
	elif e is InputEventPanGesture:
		_wheel((e as InputEventPanGesture).delta.y * 12.0)
	elif e is InputEventMouseMotion and dragging:
		var mm := e as InputEventMouseMotion
		var dx := mm.position.x - last_pos.x
		var dy := mm.position.y - last_pos.y
		if absf(mm.position.x - down_pos.x) + absf(mm.position.y - down_pos.y) > 4.0: drag_moved = true
		last_pos = mm.position
		if model_open:
			model_view.drag(dx, dy)
		elif state.cam_mode == "flight":
			flight.drag(dx, dy)
		elif state.cam_mode == "orbit":
			cam.phi -= dx * 0.005
			cam.theta = clampf(cam.theta - dy * 0.005, 0.05, PI - 0.05)
			update_orbit_cam()
		elif state.cam_mode == "surface":
			# scale the look speed with the zoom, so a narrow FOV pans slowly
			var k: float = observer.fov / 62.0 * 0.0032
			observer.look(-dx * k, -dy * k)
		else:
			cam.yaw -= dx * 0.0025
			cam.pitch = clampf(cam.pitch - dy * 0.0025, -1.5, 1.5)
	elif e is InputEventKey:
		_key(e as InputEventKey)

func _wheel(delta_y: float) -> void:
	# The zoom floor only has to stay clear of float32 denormals.
	if model_open: model_view.wheel(delta_y)
	elif state.cam_mode == "flight": flight.wheel(delta_y)
	elif state.cam_mode == "orbit":
		jump_cam_radius(clampf(cam.radius * (1.0 + delta_y * 0.001), 1e-6, 20000.0))
		update_orbit_cam()
	elif state.cam_mode == "surface": observer.zoom(1.0 + delta_y * 0.0012)
	else: cam.free_speed = maxf(0.5, cam.free_speed * (1.0 - delta_y * 0.001))

func _key(e: InputEventKey) -> void:
	var code := OS.get_keycode_string(e.physical_keycode)
	if not e.pressed:
		keys[e.physical_keycode] = false
		return
	keys[e.physical_keycode] = true
	if e.echo: return
	# Flight takes the keys it needs first; everything it does not claim falls
	# through to the orrery's own bindings.
	if state.cam_mode == "flight" and flight.key(e):
		get_viewport().set_input_as_handled()
		sync_warp_label()
		return
	var kc := e.keycode
	if kc == KEY_R:
		cam.target.set_v(0, 0, 0); cam_offset.set_v(0, 0, 0); jump_cam_radius(float(state.preset.camRadius))
		cam.theta = PI / 2.0 - 0.35; cam.phi = PI / 2.0
		if state.cam_mode == "orbit": update_orbit_cam()
	if kc == KEY_SPACE:
		state.paused = not state.paused
		get_viewport().set_input_as_handled()
	if kc == KEY_F: set_cam_mode("free" if state.cam_mode == "orbit" else "orbit")
	if kc == KEY_V: set_cam_mode("orbit" if state.cam_mode == "surface" else "surface")
	if kc == KEY_H: set_hud_hidden(not state.hud_hidden)
	# 1–7 select the imaging band, in spectrum order
	if kc >= KEY_1 and kc <= KEY_9:
		var n := int(kc - KEY_0)
		if n >= 1 and n <= Spectrum.BANDS.size(): set_band(n - 1)
	if (kc == KEY_DELETE or kc == KEY_BACKSPACE) and state.focus_id != null: remove_body(state.focus_id)
	var _unused := code

func set_cam_mode(mode: String) -> void:
	if mode == "surface" and get_home() == null: mode = "orbit"   # nowhere to stand
	if mode == "flight" and not (flight and flight.active): mode = "orbit"
	# Leaving flight hands the camera back to the orrery, which needs its own
	# near plane and field of view restored — the flight pass drives both.
	if state.cam_mode == "flight" and mode != "flight":
		cam_fov = 50.0; cam_near = 0.01
		apply_sky_boost_all(Vector3.ZERO)
	if mode == "free" and state.cam_mode != "free":
		# seed yaw/pitch from current look direction
		var dir: Vector3 = (cam.target as DVec3).rel_v3(cam_pos).normalized()
		cam.yaw = atan2(dir.x, dir.z)
		cam.pitch = asin(clampf(dir.y, -1.0, 1.0))
	var was_surface := state.cam_mode == "surface"
	state.cam_mode = mode
	if mode == "surface":
		cam_near = 0.002
		# At system speeds the planet spins tens of times a second and the sky is a
		# blur, so entering the surface view drops to a pace where a day is watchable.
		if not was_surface: apply_regime("day")
		aim_at_brightest_sun()
	elif was_surface:
		cam_near = 0.01
		cam_fov = 50.0
	hud.set_active("camOrbit", mode == "orbit")
	hud.set_active("camFree", mode == "free")
	hud.set_active("camSurface", mode == "surface")
	hud.set_shown("skyRow", mode == "surface")

# Turn the observer to face whichever sun is currently brightest overhead.
func aim_at_brightest_sun() -> void:
	var home := get_home()
	if home == null or state.suns.is_empty(): return
	_observe(home)
	var up: Vector3 = observer.up
	var north: Vector3 = observer.north
	var east := up.cross(north)
	# prefer a sun that is actually above the horizon
	var best = null
	var best_score := -INF
	for s in state.suns:
		var d: Vector3 = (s.pos_abs as DVec3).sub(observer.eye).to_v3().normalized()
		var elev := d.dot(up)
		var score: float = s.intensity * (elev + 0.2) if elev > -0.05 else -1.0 + s.intensity * 1e-3
		if score > best_score:
			best_score = score
			best = d
	if best == null: return
	observer.azimuth = atan2(best.dot(east), best.dot(north))
	# If every sun is down, look at the horizon rather than at our own feet.
	var sun_elev := asin(clampf(best.dot(up), -1.0, 1.0))
	observer.elevation = 0.12 if sun_elev < 0.05 else clampf(sun_elev, 0.05, 1.1)

func update_free_cam(dt: float) -> void:
	var fwd := Vector3(sin(cam.yaw) * cos(cam.pitch), sin(cam.pitch), cos(cam.yaw) * cos(cam.pitch)).normalized()
	var right := fwd.cross(Vector3.UP).normalized()
	var sp: float = cam.free_speed * (4.0 if (keys.get(KEY_SHIFT, false)) else 1.0) * dt
	var mv := Vector3.ZERO
	if keys.get(KEY_W, false): mv += fwd * sp
	if keys.get(KEY_S, false): mv -= fwd * sp
	if keys.get(KEY_D, false): mv += right * sp
	if keys.get(KEY_A, false): mv -= right * sp
	if keys.get(KEY_E, false) or keys.get(KEY_SPACE, false): mv += Vector3.UP * sp
	if keys.get(KEY_Q, false) or keys.get(KEY_CTRL, false): mv -= Vector3.UP * sp
	cam_pos.x += mv.x; cam_pos.y += mv.y; cam_pos.z += mv.z
	cam_basis = Basis.looking_at(fwd, Vector3.UP)

# ============================================================================
# PRESET LOADING
# ============================================================================
func load_preset(key: String) -> void:
	if not Presets.PRESETS.has(key): return
	var p: Dictionary = Presets.PRESETS[key]
	clear_bodies()          # bodies, painted swarms and any flash still burning

	state.preset = p
	state.preset_key = key
	# The preset SEEDS the live sky spec; the settings panel owns it from here.
	set_sky(preset_sky(p.get("sky", {})))
	state.scene_scale = float(p.sceneScale)
	state.body_scale = float(p.get("bodyScale", 1.0))
	state.true_scale = bool(p.get("trueScale", false))
	hud.set_active("[data-view=scale]", state.true_scale)
	hud.set_button_text("[data-view=scale]", "Sizes: Real" if state.true_scale else "Sizes: Boosted")
	state.time_scale = float(p.get("timeScale", 2.0))
	state.max_step = float(p.get("maxStep", 5e-3))
	state.gw_boost = float(p.get("gwBoost", 0.0))
	state.disc_intensity = float(p.get("discIntensity", 0.9))
	hud.set_slider("disc", state.disc_intensity, U.fixed(state.disc_intensity, 2))
	# The drift readout's reference belongs to THIS scenario's initial conditions.
	state.energy0 = null
	sync_sim_controls()
	set_spawn_at_rest(bool(p.get("spawnAtRest", false)))
	state.lensing = bool(p.get("lensing", false))
	state.show_lens = state.lensing
	hud.set_active("[data-view=lens]", state.show_lens)
	hud.set_button_text("[data-view=lens]", "Lens ON" if state.show_lens else "Lens OFF")
	# Sim Speed and the paused flag are USER settings, not scenario settings —
	# they carry over. timeScale does not: a neutron-star inspiral and the solar
	# system need values four orders of magnitude apart to be watchable at all.
	state.consumed = 0
	state.focus_id = null; state.follow_id = null
	state.sim_years = 0.0
	state.home_id = null
	state.suns.clear()

	# `seed=N` on the command line makes the scenario's random choices (the
	# solar system's orbital phases) the ones the web build makes with
	# Math.random replaced by mulberry32(N) for the duration of the build — so a
	# side-by-side check can compare the same sky, not two random ones.
	var specs: Array
	if _cmd.has("seed"):
		var rng := GiantVisual.Mulberry.new(int(_cmd.seed))
		Presets.rand_override = rng.next
		specs = p.build.call()
		Presets.rand_override = Callable()
	else:
		specs = p.build.call()
	for spec in specs: spawn_body(spec)

	# Anything the scenario paints on: rings, belts, ejecta. Applied after the
	# bodies exist, since each decoration is pinned to one of them by name.
	for spec in p.get("paint", []): apply_paint_spec(spec)

	# climate only exists for presets that give us a world to stand on
	state.climate = Climate.new(p.climate) if p.get("climate") else null
	if state.climate != null:
		var home := get_home()
		if home: state.climate.step(1e-6, home, get_stars())
	update_suns()

	# Camera reset. In a hierarchical system the total barycentre is nowhere near
	# the stars, so presets with a home world start the camera following it.
	cam.target.set_v(0, 0, 0); cam_offset.set_v(0, 0, 0); jump_cam_radius(float(p.camRadius))
	cam.theta = PI / 2.0 - 0.35; cam.phi = PI / 2.0
	set_cam_mode("orbit")
	if p.get("focus"):
		var f := state.body_named(String(p.focus))
		if f:
			set_follow(f)
			jump_cam_radius(float(p.camRadius))
	update_orbit_cam()
	# the spacetime slab is noise in a multi-star system; restore it elsewhere
	toggle_mesh(p.get("mesh") != false)

	# sync the time-scale slider to the preset's own pace
	hud.set_slider("timescale", U.log10(state.time_scale),
		("%s d/s" % U.fixed(state.time_scale * 365.25, 1)) if state.time_scale < 1.0 else ("%s yr/s" % U.fixed(state.time_scale, 1)))
	var home := get_home()
	if home: hud.set_slider("daylen", home.day_length * 365.25, "%s d" % U.fixed(home.day_length * 365.25, 1))
	if state.climate != null: hud.set_slider("mixed", state.climate.mixed_layer, "%s m" % U.fixed(state.climate.mixed_layer, 0))

	# UI
	hud.set_text("presetName", String(p.name))
	hud.set_text("blurb", String(p.get("blurb", "")))
	hud.set_shown("massRow", key == "sandbox")
	hud.set_shown("discRow", state.lensing)
	hud.set_shown("tempRow", state.lensing)
	hud.set_shown("bhPanel", not get_holes().is_empty())
	hud.set_shown("climatePanel", state.climate != null)
	hud.set_shown("starPanel", not get_stars().is_empty())
	hud.set_shown("camSurface", bool(p.get("surface", false)))
	# The button names the world you would be standing on.
	var hw := get_home()
	hud.set_button_text("camSurface", ("On %s" % hw.name) if hw else "Stand on it")
	spacetime_mesh.node.visible = state.show_mesh
	render_preset_groups()
	refresh_ui()

# ============================================================================
# PAINTING — the parameters are derived from the body rather than asked for:
# a ring's span is fixed by the Roche limit, and a belt's gaps are fixed by
# which resonances a perturber has cleared.
# ============================================================================
func apply_paint_spec(spec: Dictionary):
	var b: Body = state.body_named(String(spec.body)) if spec.get("body") else null
	if spec.get("body") and b == null: return null
	var common := {"bodyId": b.id if b else null, "sceneScale": state.scene_scale}
	if spec.kind == "cloud":
		return painter.add("cloud", U.merged(common, {
			"radius": U.nz(spec.get("radius"), 10.0), "lobes": U.nz(spec.get("lobes"), 1),
			"color": U.nz(spec.get("color"), 0xffcf9a), "density": U.nz(spec.get("density"), 0.7),
			"expandAUperYr": U.nz(spec.get("expand"), 0.0), "seed": U.nz(spec.get("seed"), randf() * 100.0),
			"label": U.nz(spec.get("label"), "ejecta"),
		}))
	var is_belt: bool = spec.kind == "belt"
	return painter.add("belt" if is_belt else "ring", U.merged(common, {
		"centralMass": b.mass if b else 1.0,
		"inner": spec.get("inner"), "outer": spec.get("outer"),
		"count": U.nz(spec.get("count"), 11000 if is_belt else 26000),
		"ecc": U.nz(spec.get("ecc"), 0.14 if is_belt else 0.0025),
		"incl": U.nz(spec.get("incl"), 0.16 if is_belt else 0.001),
		"color": U.nz(spec.get("color"), 0xcdbb99),
		"sizePx": U.nz(spec.get("sizePx"), 2.4 if is_belt else 2.0),
		"tilt": U.nz(spec.get("tilt"), 0.0),
		"perturberA": spec.get("perturber"),
		"surfaceDensity": U.nz(spec.get("surfaceDensity"), -1.5),
		"label": U.nz(spec.get("label"), spec.kind),
	}))

# The "Ring" button. What it mostly does is REFUSE, when the body it was aimed
# at cannot have one — and saying why is the point of the button.
func paint_ring_on(b: Body) -> void:
	if b == null: return toast("Focus a body first (click it, or pick it from Bodies)")
	if b.type == "bh":
		return toast("A black hole has no surface for a ring to sit above — what it gets instead is an accretion disc, which the lensing pass already draws.", 6000)
	var span: Dictionary = Painter.ring_span(b.mass, b.radius if b.radius else 1e-6, "ice")
	if not span.get("outer"):
		return toast("%s is too diffuse for a ring: its Roche limit falls inside its own surface, so any orbiting debris is outside the tidal zone and would simply accrete into a moon." % b.name, 7000)
	apply_paint_spec({"kind": "ring", "body": b.name, "inner": span.inner, "outer": span.outer,
		"tilt": (randf() - 0.5) * 0.5, "color": 0xffd8b4 if b.type == "star" else 0xcdbb99})
	toast("Ring around %s: %s–%s km, i.e. from just above the surface out to the Roche limit at %s body radii. Outside that, this material would clump into a moon instead." % [
		b.name, U.fixed(span.inner / Physics.AU_PER_KM, 0), U.fixed(span.outer / Physics.AU_PER_KM, 0),
		U.fixed(span.roche / (b.radius if b.radius else 1.0), 2)], 8000)

func paint_belt_on(b: Body) -> void:
	if b == null: return toast("Focus a body first (click it, or pick it from Bodies)")
	# The belt goes around whatever this body orbits, not around the body — a
	# belt is a heliocentric structure. If the focus IS the dominant mass, use it.
	var central := _dominant()
	var host := b if b == central else central
	if host == null: return
	var r_host := maxf(host.radius, host.rs)
	# Place it where the solar system's is, in units of the host's own scale:
	# 2.1–3.3 AU about 1 M☉ scales as √M for a fixed orbital period.
	var k := sqrt(maxf(host.mass, 1e-6))
	var inner := maxf(2.1 * k, r_host * 4.0)
	var outer := maxf(3.4 * k, r_host * 7.0)
	# The nearest more massive body outside the belt is what clears the gaps.
	var perturber = null
	var best := INF
	for o in state.bodies:
		if o == host or o.mass < host.mass * 1e-5: continue
		var a: float = o.pos.distance_to(host.pos)
		if a > outer and a < best:
			best = a
			perturber = a
	apply_paint_spec({"kind": "belt", "body": host.name, "inner": inner, "outer": outer,
		"perturber": perturber, "color": 0x9a8d7c, "surfaceDensity": -1.0})
	if perturber != null:
		toast("Belt from %s to %s AU, with Kirkwood gaps cleared at the 3:1, 5:2, 7:3 and 2:1 resonances with the body at %s AU." % [U.fixed(inner, 2), U.fixed(outer, 2), U.fixed(perturber, 2)], 8000)
	else:
		toast("Belt from %s to %s AU. No body outside it to clear resonance gaps, so it is smooth — which is what the asteroid belt would look like without Jupiter." % [U.fixed(inner, 2), U.fixed(outer, 2)], 8000)

func paint_cloud_on(b: Body) -> void:
	if b == null: return toast("Focus a body first (click it, or pick it from Bodies)")
	var r := maxf((b.radius if b.radius else 0.01) * 12.0, 0.6 / state.scene_scale)
	apply_paint_spec({"kind": "cloud", "body": b.name, "radius": r, "lobes": 2, "density": 0.7,
		# 650 km/s, the measured expansion of Eta Carinae's Homunculus, in AU/yr.
		"expand": 0.137,
		"color": 0xbcd6ff if float(U.nz(b.teff, 0.0)) > 9000.0 else 0xffcf9a})
	toast("Ejecta shell around %s, expanding at 650 km/s — the measured speed of η Carinae's Homunculus. It limb-brightens into a rim because it is optically thin and hollow." % b.name, 7000)

# ============================================================================
# UI — everything the Hud shows is pushed from here; everything it does comes
# back as a signal (see _bind_hud).
# ============================================================================
func render_preset_groups() -> void:
	hud.render_preset_groups(PRESET_GROUPS, Presets.PRESETS, state.preset_key)

func refresh_ui() -> void:
	if hud == null: return
	var rows := []
	for b in state.bodies: rows.append({"id": b.id, "name": b.name})
	hud.render_body_list(rows, state.focus_id)
	hud.set_text("count", "(%d)" % state.bodies.size())
	hud.set_text("bc", str(state.bodies.size()))
	hud.set_text("cc", str(state.consumed))
	var holes := get_holes()
	hud.set_text("rs", U.fixed(holes[0].rs, 3) if not holes.is_empty() else "0.000")
	hud.set_text("isco", U.fixed(3.0 * holes[0].rs, 3) if not holes.is_empty() else "0.000")
	# focus panel
	var fb := state.body_by_id(state.focus_id)
	if fb:
		hud.set_shown("focusPanel", true)
		hud.set_text("focusName", "%s · %s M☉" % [fb.name, U.expo(fb.mass, 2) if fb.mass < 0.01 else U.fixed(fb.mass, 2)])
	else:
		hud.set_shown("focusPanel", false)

static func fmt_years(y: float) -> String:
	if y < 1.0: return "%s d" % U.fixed(y * 365.25, 1)
	if y < 1000.0: return "%s yr" % U.fixed(y, 2)
	return "%s kyr" % U.fixed(y / 1000.0, 2)

func update_hud(dt: float) -> void:
	hud_acc += dt
	if hud_acc < 0.1: return
	hud_acc = 0.0
	hud.set_text("simClock", fmt_years(state.sim_years))

	# An open cross-section tracks the focused body. Bodies change — a star
	# being eaten loses mass every frame, and the diagram should say so.
	if xsec_open and not state.hud_hidden and not hud.is_collapsed("xsecPanel"):
		var fb := state.body_by_id(state.focus_id)
		if fb:
			show_cross_section(fb)
			if live_editor: live_editor.sync(fb)
		else:
			set_panel_open("xsecPanel", false)

	# --- star readout: what each sun actually is, and how bright it is here
	if not state.suns.is_empty():
		var rows := []
		for s in state.suns:
			var b: Body = s.body
			rows.append({"name": b.name, "cls": U.nz(b.spectral, ""), "mass": b.mass, "teff": float(U.nz(b.teff, 0.0)),
				"dist_au": s.dist_au, "intensity": s.intensity, "color": s.color,
				"flaring": b.activity != null and b.activity.flux > 1.05})
		hud.render_sun_list(rows)

	update_sim_stats()

	var cl = state.climate
	if cl == null or hud.is_collapsed("climatePanel"): return
	hud.update_climate({
		"label": cl.era.label, "cls": cl.era.cls, "desc": cl.era.desc,
		"celsius": cl.celsius, "S": cl.S, "ice": cl.ice, "clouds": cl.clouds,
		"tauYears": cl.tau_years, "Tmin": cl.extremes.Tmin, "Tmax": cl.extremes.Tmax,
		"history": cl.history,
	})

func toast(msg: String, ms: int = 2200) -> void:
	if hud: hud.toast(msg, ms)

func set_panel_open(id: String, open: bool) -> void:
	hud.set_panel_open(id, open)

func set_hud_hidden(hidden: bool) -> void:
	state.hud_hidden = hidden
	hud.set_hud_hidden(hidden)
	if hidden: toast("HUD hidden — press H to restore")

# ============================================================================
# APP MODE — the mode is a filter, not a separate application: the physics,
# the scene and the bodies are the same either way, and switching costs nothing.
# ============================================================================
func set_app_mode(mode: String, opts: Dictionary = {}) -> void:
	state.app_mode = mode
	hud.set_app_mode(mode)
	if mode != "learn" and lessons: lessons.close()
	if mode == "sandbox":
		close_model_viewer()
		if flight.active: end_flight()
		set_panel_open("scenarioPanel", true)
	elif mode == "learn":
		# The course replaces the scenario list rather than joining it.
		close_model_viewer()
		if flight.active: end_flight()
		set_panel_open("scenarioPanel", false)
		set_panel_open("coursePanel", true)
		# Settings is the tallest thing in the column and a beginner needs it
		# least of anyone, so it starts folded — its tab is right there.
		if not learn_entered:
			set_panel_open("settingsPanel", false)
			learn_entered = true
		if not opts.get("quiet", false) and not lessons.active: lessons.resume()
	elif opts.get("quiet", false):
		set_panel_open("scenarioPanel", false)
	else:
		set_panel_open("scenarioPanel", false)
		# Spaceflight starts ON EARTH, on the pad, at 1×. The vehicles name their
		# own home body (`launchFrom`) and every launcher's is Earth, so the
		# scenario has to be one that has an Earth in it.
		if state.body_named("Earth") == null: load_preset("solar")
		launch_craft(last_craft)
	hud.layout_left_column()

func _start(m: String) -> void:
	hud.dismiss_start()
	set_app_mode(m)
	if m == "flight": set_panel_open("controlPanel", true)

# ============================================================================
# IMAGING BAND
# ============================================================================
func set_band(i: int) -> void:
	var band: Dictionary = pipe.set_band(i)
	state.band = pipe.postfx.band
	hud.set_band(state.band, band)
	# The sky does not go through the spectral remap — it composites itself at
	# the band's own frequency, because most of what it contains outside the
	# visible is non-thermal and has no temperature to re-image from.
	SkyModel.apply_sky_band(pipe.sky_materials, state.band)

# ============================================================================
# SETTINGS PANEL — the cross-cutting knobs, as against the scenario's own.
# ============================================================================
## A preset's `sky` in the live spec's shape. Presets were written with
## `env: 'disc'` and must keep working unchanged, so the string is widened into
## the weight map the panel edits.
func preset_sky(spec = {}) -> Dictionary:
	if spec == null: spec = {}
	var pairs: Array = SkyModel.sky_env_weights(spec.get("env", "disc"))
	var env := {}
	for pw in (pairs if not pairs.is_empty() else [["disc", 1.0]]): env[pw[0]] = float(pw[1])
	var out: Dictionary = spec.duplicate()
	out.env = env
	out.tilt = float(spec.get("tilt", 0.34))
	out.roll = float(spec.get("roll", 0.9))
	return out

func apply_sky() -> void:
	SkyModel.apply_sky_environment(pipe.sky_materials, state.sky)

## Replace the live sky wholesale and put the controls where it says.
func set_sky(spec: Dictionary) -> void:
	state.sky = spec
	apply_sky()
	sync_sky_controls()

## One environment's weight, as edited by its slider. 0 removes it entirely.
func set_env_weight(name: String, w: float) -> void:
	var env: Dictionary = state.sky.env.duplicate()
	if w > 0.0: env[name] = w
	else: env.erase(name)
	state.sky = U.merged(state.sky, {"env": env})
	apply_sky()
	sync_sky_controls(true)

## Write the live spec back into the controls. The amplitude rows always show
## the EFFECTIVE value — blend output, or the pinned override — so the two
## halves of the page can never disagree about what the sky is made of.
func sync_sky_controls(skip_inputs := false) -> void:
	var eff := U.merged(SkyModel.blend_environments(state.sky.get("env")), state.sky)
	hud.sync_sky_controls(state.sky, eff, skip_inputs)

const FX_DEFAULTS := {"bloom": 0.55, "threshold": 1.0, "radius": 1.0, "vignette": 0.35, "grain": 0.02}
const FX_ROWS := [["fxBloom", "bloom", 2], ["fxThreshold", "threshold", 2], ["fxRadius", "radius", 2], ["fxVignette", "vignette", 2], ["fxGrain", "grain", 3]]

func _init_fx_rows() -> void:
	for row in FX_ROWS: _set_fx(row[0], FX_DEFAULTS[row[1]], true)
	var ls := pipe.lens.get_scale()
	hud.set_slider("lensScale", ls, "%sx" % U.fixed(ls, 2))
	hud.set_slider("renderScale", 1.0, "%sx" % U.fixed(pipe.render_scale, 2))

func _set_fx(id: String, v: float, write_slider := false) -> void:
	for row in FX_ROWS:
		if row[0] != id: continue
		pipe.postfx.set(row[1], v)
		if write_slider: hud.set_slider(id, v, U.fixed(v, row[2]))
		else: hud.set_text(id + "-val", U.fixed(v, row[2]))

func sync_sim_controls() -> void:
	hud.set_slider("maxStep", U.log10(state.max_step), "%s yr" % U.expo(state.max_step, 1))
	hud.set_slider("gwBoost", state.gw_boost, ("%s×" % U.fixed(state.gw_boost, 2)) if state.gw_boost else "off")

func update_sim_stats() -> void:
	# stepPhysics gives up after 8000 sub-steps and advances the clock by what
	# it actually integrated — which silently slows simulated time. Saying so
	# costs one class.
	var capped := state.last_steps >= STEP_GUARD
	hud.set_text("setSteps", ("%d capped" % state.last_steps) if capped else str(state.last_steps))
	hud.set_warn("setSteps", capped, "The integrator hit its 8000 sub-step guard. The answer is still correct — it advances the clock by what it actually integrated — but simulated time is now running slower than the Time panel says. Raise the step cap." if capped else "")
	# A merger removes mass and its binding energy with it, so the reference is
	# rebased on a body count change.
	var E := Derive.total_energy(state.bodies)
	if state.energy0 == null or state.energy_n != state.bodies.size():
		state.energy0 = E
		state.energy_n = state.bodies.size()
	var rel := absf((E - float(state.energy0)) / float(state.energy0)) if state.energy0 else 0.0
	hud.set_text("setDrift", "0" if rel < 1e-12 else U.expo(rel, 1))

# ----------------------------------------------------------------------------
# TIME CONTROL. The scale is logarithmic and backed by named regimes that are
# computed FROM the current world's day length and orbital period.
# ----------------------------------------------------------------------------
static func time_label(yr_per_sec: float) -> String:
	if yr_per_sec < 3e-3: return "%s hr/s" % U.fixed(yr_per_sec * 365.25 * 24.0, 2)
	if yr_per_sec < 1.0: return "%s d/s" % U.fixed(yr_per_sec * 365.25, 2)
	return "%s yr/s" % U.fixed(yr_per_sec, 1)

func set_time_scale(yr_per_sec: float) -> void:
	state.time_scale = clampf(yr_per_sec, 1e-5, 20.0)
	hud.set_slider("timescale", U.log10(state.time_scale), time_label(state.time_scale))

var _timescale_slider := -0.46
func apply_time_scale() -> void:
	set_time_scale(pow(10.0, _timescale_slider))

# Seconds of real time each regime should take for its characteristic event.
const TIME_REGIMES := {"sunset": 45.0, "day": 8.0, "season": 90.0, "era": 120.0}
func apply_regime(name: String) -> void:
	var home := get_home()
	var day := home.day_length if home else 0.011
	if name == "sunset": set_time_scale(day / TIME_REGIMES.sunset)
	elif name == "day": set_time_scale(day / TIME_REGIMES.day)
	elif name == "season": set_time_scale(1.69 / TIME_REGIMES.season)    # ~one orbit
	elif name == "era": set_time_scale(51.0 / TIME_REGIMES.era)          # ~one Gamma orbit
	for n in TIME_REGIMES: hud.set_active("[data-time=%s]" % n, n == name)

func set_spawn_at_rest(on: bool) -> void:
	state.spawn_at_rest = on
	hud.set_active("[data-view=spawnrest]", on)
	hud.set_button_text("[data-view=spawnrest]", "Spawn: At rest" if on else "Spawn: In orbit")

func toggle_mesh(on: bool) -> void:
	state.show_mesh = on
	spacetime_mesh.node.visible = on
	hud.set_active("[data-view=mesh]", on)
	hud.set_button_text("[data-view=mesh]", "Mesh ON" if on else "Mesh OFF")

func set_true_scale(on: bool) -> void:
	state.true_scale = on
	hud.set_active("[data-view=scale]", on)
	hud.set_button_text("[data-view=scale]", "Sizes: Real" if on else "Sizes: Boosted")
	rebuild_visuals()
	refresh_ui()

func apply_sky_boost_all(beta: Vector3) -> void:
	SkyModel.apply_sky_boost(pipe.sky_materials, beta)

# ============================================================================
# THE HUD'S SIGNALS
# ============================================================================
func _bind_hud() -> void:
	hud.start_chosen.connect(_start)
	hud.mode_chosen.connect(set_app_mode)
	hud.preset_chosen.connect(load_preset)
	hud.body_focus.connect(_on_body_focus)
	hud.body_remove.connect(remove_body)
	hud.spawn.connect(spawn_orbiting)
	hud.paint.connect(_on_paint)
	hud.clear_bodies.connect(clear_bodies)
	hud.delete_focus.connect(_on_delete_focus)
	hud.xsec_open.connect(open_cross_section.bind(true))
	hud.xsec_closed.connect(_on_xsec_closed)
	hud.cam_mode.connect(set_cam_mode)
	hud.view_toggle.connect(_on_view_toggle)
	hud.reset_view.connect(_on_reset_view)
	hud.band_chosen.connect(set_band)
	hud.time_regime.connect(apply_regime)
	hud.slider.connect(_on_slider)
	hud.sky_solo.connect(_on_sky_solo)
	hud.sky_reset.connect(_on_sky_reset)
	hud.sky_adv_clear.connect(_on_sky_adv_clear)
	hud.fx_reset.connect(_on_fx_reset)
	hud.sim_reset.connect(_on_sim_reset)
	hud.climate_reset.connect(_on_climate_reset)
	hud.craft_launch.connect(launch_craft)
	hud.craft_hover.connect(_on_craft_hover)
	hud.flight_exit.connect(end_flight)
	hud.flight_cam_cycle.connect(_on_flight_cam_cycle)
	hud.warp_step.connect(_on_warp_step)
	hud.model_open.connect(_on_model_open)
	hud.model_close.connect(close_model_viewer)
	hud.model_show.connect(show_model)
	hud.model_deploy.connect(_on_model_deploy)
	hud.model_spin.connect(_on_model_spin)
	hud.model_fly.connect(_on_model_fly)

func _on_body_focus(id: int) -> void:
	var b := state.body_by_id(id)
	if b: set_follow(b)

func _on_paint(kind: String) -> void:
	var b := state.body_by_id(state.focus_id)
	match kind:
		"ring": paint_ring_on(b)
		"belt": paint_belt_on(b)
		"cloud": paint_cloud_on(b)
		"clear":
			painter.clear()
			toast("Cleared everything painted")

func _on_delete_focus() -> void:
	if state.focus_id != null: remove_body(state.focus_id)

func _on_xsec_closed() -> void:
	xsec_open = false

func _on_view_toggle(v: String) -> void:
	match v:
		"mesh": toggle_mesh(not state.show_mesh)
		"scale": set_true_scale(not state.true_scale)
		"spawnrest": set_spawn_at_rest(not state.spawn_at_rest)
		_:
			state.show_lens = not state.show_lens
			hud.set_active("[data-view=lens]", state.show_lens)
			hud.set_button_text("[data-view=lens]", "Lens ON" if state.show_lens else "Lens OFF")

func _on_reset_view() -> void:
	set_follow(null)
	cam.target.set_v(0, 0, 0); cam_offset.set_v(0, 0, 0); jump_cam_radius(float(state.preset.camRadius))
	cam.theta = PI / 2.0 - 0.35; cam.phi = PI / 2.0
	set_cam_mode("orbit"); update_orbit_cam()

func _on_sky_solo(n: String) -> void:
	set_sky(U.merged(state.sky, {"env": {n: 1.0}}))

func _on_sky_reset() -> void:
	set_sky(preset_sky(state.preset.get("sky", {}) if state.preset else {}))
	toast("Sky reset to the scenario’s own")

func _on_sky_adv_clear() -> void:
	set_sky({"env": state.sky.env, "tilt": state.sky.tilt, "roll": state.sky.roll})

func _on_fx_reset() -> void:
	for row in FX_ROWS: _set_fx(row[0], FX_DEFAULTS[row[1]], true)

func _on_sim_reset() -> void:
	var p: Dictionary = state.preset if state.preset else {}
	state.max_step = float(p.get("maxStep", 5e-3))
	state.gw_boost = float(p.get("gwBoost", 0.0))
	state.disc_intensity = float(p.get("discIntensity", 0.9))
	hud.set_slider("disc", state.disc_intensity, U.fixed(state.disc_intensity, 2))
	sync_sim_controls()

func _on_climate_reset() -> void:
	if state.climate != null: state.climate.reset(288.0)

func _on_craft_hover(k: String) -> void:
	CraftAssets.preload_craft(k)

func _on_flight_cam_cycle() -> void:
	var modes := ["chase", "orbit", "cockpit", "pad"]
	flight.set_camera_mode(modes[(modes.find(flight.camera_mode()) + 1) % modes.size()])
	sync_warp_label()

func _on_warp_step(d: int) -> void:
	flight.set_warp(flight.warp_index() + d)
	sync_warp_label()

func _on_model_open() -> void:
	show_model(model_view.vehicle.key if model_view.vehicle else "saturnv")

func _on_model_deploy(on: bool) -> void:
	model_view.set_deploy(on)

func _on_model_spin(on: bool) -> void:
	model_view.cam.spin = 0.10 if on else 0.0
	model_view.cam.held = not on

func _on_model_fly() -> void:
	var k = model_view.vehicle.key if model_view.vehicle else null
	close_model_viewer()
	if k: launch_craft(k)

func _on_slider(id: String, v: float) -> void:
	if id.begins_with("env:"):
		set_env_weight(id.substr(4), v)
		return
	if id.begins_with("skyp:"):
		state.sky = U.merged(state.sky, {id.substr(5): v})
		apply_sky(); sync_sky_controls(true)
		return
	match id:
		"mass":
			state.mass = v
			hud.set_text("mass-val", U.fixed(v, 1))
			var holes := get_holes()
			if not holes.is_empty() and state.preset_key == "sandbox":
				var bh: Body = holes[0]
				bh.mass = state.mass; bh.rs = state.mass * 0.05
				bh.rs_scene = bh.rs * state.scene_scale; bh.radius_scene = bh.rs_scene
				refresh_ui()
		"disc":
			state.disc_intensity = v; hud.set_text("disc-val", U.fixed(v, 2))
		"temp":
			state.disc_temp = v; hud.set_text("temp-val", U.fixed(v, 2))
		"speed":
			state.speed = v; hud.set_text("speed-val", U.fixed(v, 2))
		"timescale":
			_timescale_slider = v
			apply_time_scale()
		"lat":
			observer.latitude = deg_to_rad(v)
			hud.set_text("lat-val", "%d°" % int(U.jround(v)))
		"daylen":
			var home := get_home()
			if home: home.day_length = v / 365.25
			hud.set_text("daylen-val", "%s d" % U.fixed(v, 1))
		"mixed":
			if state.climate != null: state.climate.mixed_layer = v
			hud.set_text("mixed-val", "%s m" % U.fixed(v, 0))
		"greenhouse":
			if state.climate != null: state.climate.greenhouse = v
			hud.set_text("greenhouse-val", U.fixed(v, 2))
		"renderScale":
			# The slider asks; the display caps. Report what the framebuffer got.
			var eff := pipe.set_render_scale(v)
			resize()
			hud.set_text("renderScale-val", "%sx" % U.fixed(eff, 2))
		"lensScale":
			pipe.lens.set_scale(v)
			hud.set_text("lensScale-val", "%sx" % U.fixed(v, 2))
		"maxStep":
			state.max_step = pow(10.0, v)
			hud.set_text("maxStep-val", "%s yr" % U.expo(state.max_step, 1))
		"gwBoost":
			state.gw_boost = v
			hud.set_text("gwBoost-val", ("%s×" % U.fixed(v, 2)) if v else "off")
		"skyTilt":
			state.sky = U.merged(state.sky, {"tilt": v}); apply_sky(); sync_sky_controls(true)
		"skyRoll":
			state.sky = U.merged(state.sky, {"roll": v}); apply_sky(); sync_sky_controls(true)
		"mvExplode":
			model_view.set_explode(v)
		_:
			if id.begins_with("fx"): _set_fx(id, v)

# ============================================================================
# RESIZE
# ============================================================================
func resize() -> void:
	var s := get_viewport().get_visible_rect().size
	pipe.set_view_size(Vector2i(int(s.x), int(s.y)))
	# The instrument PSF is pinned to the DEFAULT fov and only moves when the
	# framebuffer does, so zooming spreads a star over more pixels the way a real
	# telescope does instead of concentrating it into a brighter dot.
	SkyModel.apply_sky_optics(pipe.sky_materials, deg_to_rad(cam_fov), float(pipe.render_size.y))
	if flight: flight.set_size(s.x, s.y)
	if model_view: model_view.set_size(s.x, s.y)
	if hud: hud.layout_left_column()

# ============================================================================
# SPACEFLIGHT — the whole feature lives in sim/flight/; this is the wiring. It
# takes over the camera, the time scale and one extra render pass, and gives
# all three back when the flight ends.
# ============================================================================
# The vehicle picker. Each button carries the numbers the vehicle is actually
# built from, because "2 970 t, 14.3 km/s, TWR 1.20" says more about what a
# Saturn V is than any description could.
func render_craft_grid() -> void:
	var rows := []
	for v in flight.vehicles:
		var carries = v.get("carries")
		var pay: float = float(carries.mass) if carries else 0.0
		var dv := U.fixed(Vehicles.total_delta_v(v, pay) / 1000.0, 1)
		var m := Vehicles.gross_mass(v, pay)
		var mass := ("%s kt" % U.fixed(m / 1e6, 2)) if m > 1e5 else ("%s t" % U.fixed(m / 1000.0, 0))
		rows.append({"key": v.key, "name": v.name, "desc": "%s · %s km/s · %s" % [mass, dv, v.role], "blurb": v.get("blurb", "")})
	hud.render_craft_grid(rows)

func launch_craft(key: String) -> void:
	var veh = null
	for v in flight.vehicles:
		if v.key == key: veh = v
	if veh == null: return
	# The authored models are a cache build_craft reads synchronously, so THIS
	# vehicle's mesh has to be in it before the first build. One vehicle, not nine.
	await CraftAssets.craft_models_ready([key])
	last_craft = key
	# A launcher needs a body with a surface to leave; everything else is put in
	# orbit around whatever dominates the scenario.
	var v = flight.begin(key, {"mode": "pad" if veh.role == "launch" else "orbit"})
	if v == null: return
	set_panel_open("flightPanel", true)
	hud.layout_left_column()
	set_cam_mode("flight")
	hud.set_shown("flightRow", true)
	for vv in flight.vehicles: hud.set_active("[data-craft=%s]" % vv.key, vv.key == key)
	toast("%s — %s" % [veh.name, "ready on the pad" if v.phase == "prelaunch" else "in orbit"])
	sync_warp_label()

func end_flight() -> void:
	# Ending a flight is not leaving the planet: in flight mode the camera stays
	# on Earth, framed.
	var was_flight_mode := state.app_mode == "flight"
	flight.teardown()
	set_cam_mode("orbit")
	if was_flight_mode:
		var home := state.body_named("Earth")
		if home: set_follow(home)
	set_panel_open("flightPanel", false)
	hud.set_shown("flightRow", false)
	for vv in flight.vehicles: hud.set_active("[data-craft=%s]" % vv.key, false)
	# hand the orrery's own pacing back
	apply_time_scale()

func sync_warp_label() -> void:
	hud.set_text("warpLabel", "%s×" % U.grouped(flight.warp()))
	var m: String = flight.camera_mode()
	hud.set_button_text("flightCam", "Cam: " + m.substr(0, 1).to_upper() + m.substr(1))

# ============================================================================
# THE MODEL VIEWER — its own scene, its own camera, and it replaces the frame
# entirely: the whole point of it is that nothing else is in the way. It takes
# every panel away and puts back exactly what it borrowed.
# ============================================================================
const MODEL_WORLD := ["scenarioPanel", "controlPanel", "flightPanel", "xsecPanel"]

func show_model(key: String) -> void:
	var veh = model_view.load(key)
	if veh == null: return
	hud.show_model_stats(model_view.stats())
	for row in model_view.list(): hud.set_active("[data-mv=%s]" % row.key, row.key == key)
	model_open = true
	hud.set_shown("modelPanel", true)
	open_model_world()

func open_model_world() -> void:
	if model_restore == null:
		model_restore = MODEL_WORLD.filter(func(id): return not hud.is_collapsed(id))
	hud.set_model_open(true)
	for id in MODEL_WORLD: set_panel_open(id, false)
	pipe.set_mode(RenderPipeline.Mode.MODEL)

func close_model_viewer() -> void:
	model_open = false
	hud.set_model_open(false)
	hud.set_shown("modelPanel", false)
	# Put back what the studio borrowed — and only what it borrowed.
	if model_restore != null:
		for id in model_restore: set_panel_open(id, true)
		model_restore = null
	pipe.set_mode(RenderPipeline.Mode.FLIGHT if (flight and flight.active) else RenderPipeline.Mode.ORRERY)
	hud.layout_left_column()

# ============================================================================
# OBJECT FOUNDRY + CROSS-SECTION
# ============================================================================
func _build_foundry() -> void:
	foundry = Foundry.create_foundry({"mount": hud.mount("foundry"), "on_spawn": _on_foundry_spawn})
	inspector = Foundry.create_inspector({"mount": hud.mount("xsecCanvas")})
	# The live editor lives in the same panel as the diagram, because they are
	# two halves of one idea: the cross-section says what the body is, and the
	# sliders under it are the only way to argue with that.
	live_editor = Foundry.create_live_editor({"mount": hud.mount("liveEdit"), "on_edit": _on_live_edit})

func _on_foundry_spawn(spec: Dictionary, structure) -> void:
	var b := spawn_body(place_spawn(U.merged(spec, {"seed": randi() % 1000000000, "atmosphere": spec.type == "planet"})))
	set_follow(b)
	# A star built at the very end of its life does not get to sit there. The
	# foundry can put a 200 M☉ star one step from core collapse into the scene,
	# and the only honest thing for it to then do is collapse.
	if spec.type == "star" and float(spec.get("phase", 0.0)) >= 1.93:
		pending_collapse.append({"id": b.id, "at": state.time + 1.6})
		toast("%s is at core collapse — watch" % b.name, 3000)
	elif structure and structure.get("verdict", {}).get("state") == Structure.VERDICT.explode and spec.type == "star":
		toast(String(structure.verdict.label) + " — " + String(structure.verdict.detail).substr(0, 120) + "…", 7000)

func _on_live_edit(b: Body, patch: Dictionary) -> void:
	edit_body(b, patch)
	# The body may no longer be the object it was — a neutron star dragged past
	# the TOV mass is now a black hole — so re-read whatever survived.
	var now := state.body_by_id(b.id)
	if now:
		show_cross_section(now)
		live_editor.sync(now)
	else:
		set_panel_open("xsecPanel", false)

# Stars spawned at the end of their lives collapse a moment later, so the
# explosion is something you watch rather than something that has already
# happened by the time the panel closes.
func run_pending_collapse() -> void:
	for i in range(pending_collapse.size() - 1, -1, -1):
		if state.time < pending_collapse[i].at: continue
		var b := state.body_by_id(pending_collapse[i].id)
		pending_collapse.remove_at(i)
		if b and b.alive: core_collapse(b)

func show_cross_section(b: Body) -> void:
	if inspector == null or b == null: return
	hud.set_text("xsecName", "#%d %s" % [b.id, b.name])
	inspector.show(refresh_structure(b), b.structure.get("label"))

# Opening the cross-section is more than showing the panel: it has to be
# pointed at a body and told to keep tracking it.
func open_cross_section(on := true) -> bool:
	if not on:
		xsec_open = false
		set_panel_open("xsecPanel", false)
		return false
	var b := state.body_by_id(state.focus_id)
	if b == null: return false
	xsec_open = true
	set_panel_open("xsecPanel", true)
	show_cross_section(b)
	if live_editor: live_editor.sync(b)
	return true

# ============================================================================
# THE COURSE — sim/lessons.gd is the curriculum and knows nothing about this
# file; sim/lessonui.gd renders it and executes a step's requests against the
# small API below. This is the whole of the coupling, on purpose.
# ============================================================================
func _build_stage() -> void:
	stage = {
		"has_preset": _stage_has_preset,
		"current_preset": _stage_current_preset,
		"load_preset": load_preset,
		"set_focus": _stage_set_focus,
		"set_cam": _stage_set_cam,
		"set_band": set_band,
		"set_time_scale": set_time_scale,
		"set_mesh": _stage_set_mesh,
		"set_true_scale": _stage_set_true_scale,
		"set_sky": _stage_set_sky,
		# Controls are driven through the Hud exactly as if the learner had moved
		# them, so every binding downstream fires and the slider visibly moves.
		"set_control": _stage_set_control,
		"set_panel": _stage_set_panel,
		"set_paused": _stage_set_paused,
		"flare": _stage_flare,
		"collapse": _stage_collapse,
		"set_local_time": set_local_time,
		"bodies": _stage_bodies,
		"focus_body": _stage_focus_body,
		"scene_scale": _stage_scene_scale,
		"sim_years": _stage_sim_years,
		"camera": pipe.scene_cam,
		"cam_pos": _stage_cam_pos,
		"main": self,
		"toast": toast,
	}

func _stage_has_preset(k: String) -> bool: return Presets.PRESETS.has(k)
func _stage_current_preset() -> String: return state.preset_key
func _stage_bodies() -> Array: return state.bodies
func _stage_focus_body(): return state.body_by_id(state.focus_id)
func _stage_scene_scale() -> float: return state.scene_scale
func _stage_sim_years() -> float: return state.sim_years
func _stage_cam_pos() -> DVec3: return cam_pos
func _stage_set_mesh(on) -> void: toggle_mesh(bool(on))
func _stage_set_paused(p) -> void: state.paused = bool(p)
func _stage_set_control(id: String, value) -> void: hud.drive_slider(id, float(value))

func _stage_set_focus(n: String) -> void:
	var b := state.body_named(n)
	if b: set_follow(b)

func _stage_set_cam(o: Dictionary) -> void:
	if o.get("mode"): set_cam_mode(o.mode)
	if o.get("theta") != null: cam.theta = clampf(float(o.theta), 0.02, PI - 0.02)
	if o.get("phi") != null: cam.phi = float(o.phi)
	# jump_cam_radius rather than an assignment: an ease left running from the
	# last step would otherwise drag the view back out a frame later.
	if o.get("radius") != null: jump_cam_radius(float(o.radius))
	if state.cam_mode == "orbit": update_orbit_cam()

func _stage_set_true_scale(on) -> void:
	if bool(on) != state.true_scale: set_true_scale(bool(on))

func _stage_set_sky(spec: Dictionary) -> void:
	set_sky(preset_sky(U.merged(state.preset.get("sky", {}) if state.preset else {}, spec)))

func _stage_set_panel(id: String, open) -> void:
	# The cross-section is the one panel that is not just a box: see
	# open_cross_section. Everything else is a plain collapse.
	if id == "xsecPanel": open_cross_section(bool(open))
	else: set_panel_open(id, bool(open))

func _stage_flare(n: String) -> void:
	var b := state.body_named(n)
	if b == null:
		var st := get_stars()
		b = st[0] if not st.is_empty() else null
	if b == null or b.activity == null or b.activity.regions.is_empty(): return
	b.activity.ignite()
	if b.activity.flares.is_empty(): return
	# A real flare lasts hours and this one has to survive being looked at.
	b.activity.flares.back().duration = 0.15

func _stage_collapse(n: String) -> void:
	var b := state.body_named(n)
	if b: core_collapse(b)

# ---- WHAT TIME IT IS WHERE YOU ARE STANDING. The surface observer's longitude
# is fixed to the home world's own spin phase, so "put me somewhere it is
# daylight" means turning the PLANET, not moving the camera. Noon is found by
# search rather than by algebra because the local vertical carries the
# obliquity, which is the whole content of the seasons lesson.
func set_local_time(when = "noon") -> void:
	var home := get_home()
	if home == null or home.viz == null or state.suns.is_empty(): return
	var sun: Dictionary = state.suns[0]
	var g: Node3D = home.viz.group
	var q := g.global_transform.basis.get_rotation_quaternion()
	var sun_dir := (sun.pos_abs as DVec3).sub(home.scene_pos).to_v3().normalized()
	var cl := cos(observer.latitude); var sl := sin(observer.latitude)
	var best := -2.0; var noon := 0.0
	for i in 720:
		var phi := float(i) / 720.0 * TAU
		var up := q * Vector3(cl * cos(phi), sl, cl * sin(phi))
		var d := up.dot(sun_dir)
		if d > best:
			best = d; noon = phi
	# Fraction of a day, midnight = 0, noon = 0.5.
	var frac: float
	if when is float or when is int: frac = float(when)
	else: frac = {"midnight": 0.0, "dawn": 0.25, "noon": 0.5, "dusk": 0.75, "morning": 0.38}.get(when, 0.5)
	home.spin_phase = noon + (frac - 0.5) * TAU
	_observe(home)
	aim_at_brightest_sun()
	# ...and then look BESIDE it, and UP: the blue is a RATIO, and you only have
	# it while the path is still optically thin.
	observer.azimuth += 0.45
	observer.elevation = 0.34
	_observe(home)

# ============================================================================
# ANIMATION LOOP
# ============================================================================
## Step one frame by hand at a fixed step — the web build's SIM.frame(dt). A
## harness drives the sim with this so a run is reproducible.
func frame(dt: float = 1.0 / 60.0) -> void:
	manual_dt = dt

func _process(real_dt: float) -> void:
	# The cap matters in the honest direction: a frame that took longer than
	# 50 ms is integrated as 50 ms, so a slow machine runs the sim SLOW rather
	# than letting one long frame jump the whole state forward.
	var dt: float = float(manual_dt) if manual_dt != null else minf(real_dt, 0.05)
	manual_dt = null
	if _cmd.has("out"): dt = float(_cmd.get("dt", "0.0166666667"))
	animate(dt)
	_shot_tick()

# ---- the command-line screenshot mode — the Godot counterpart of the web
# build's SIM.frame() handle, which is what every headless check drove:
#   Godot --path godot -- preset=vega band=5 frames=60 dt=0.0166 hud=0 \
#         eval=<method>[,<method>...] out=/abs/shot.png [shot3d=1]
#         focus=<body> truescale=1 cammode=surface|free localtime=noon
#         timescale=<yr/s> paused=1 panel=<id>[,<id>] closed=<id>[,<id>]
# runs `frames` fixed steps, then writes the ROOT viewport (3D + HUD; `hud=0`
# hides the HUD first, `shot3d=1` writes the composited 3D frame alone) and quits.
var _shot_frame := 0
func _shot_tick() -> void:
	if not _cmd.has("out"):
		# `eval=` still runs without a screenshot (e.g. eval=_preset_check)
		if _shot_frame == 0 and _cmd.has("eval"):
			_shot_frame = 1
			for m in String(_cmd.eval).split(",", false):
				if has_method(m): call(m)
		return
	_shot_frame += 1
	if _shot_frame == 1:
		if _cmd.has("band"): set_band(int(_cmd.band))
		if _cmd.get("hud", "1") == "0": set_hud_hidden(true); hud.toast("", 1)
		if _cmd.has("focus"): _stage_set_focus(String(_cmd.focus))
		if _cmd.get("truescale", "0") == "1": set_true_scale(true)
		if _cmd.has("cammode"): set_cam_mode(String(_cmd.cammode))
		if _cmd.has("localtime"): set_local_time(String(_cmd.localtime))
		if _cmd.has("timescale"): set_time_scale(float(_cmd.timescale))
		if _cmd.get("paused", "0") == "1": state.paused = true
		# through the stage's panel verb, so `panel=xsecPanel` opens the
		# cross-section ON the focused body (open_cross_section), as the
		# page's own button does, rather than an empty box
		if _cmd.has("panel"):
			for pid in String(_cmd.panel).split(",", false): _stage_set_panel(pid, true)
		if _cmd.has("closed"):
			for pid in String(_cmd.closed).split(",", false): _stage_set_panel(pid, false)
		for m in String(_cmd.get("eval", "")).split(",", false):
			if has_method(m): call(m)
	if _shot_frame != int(_cmd.get("frames", "30")): return
	var out := String(_cmd.out)
	if _cmd.get("shot3d", "0") == "1":
		pipe.capture_next(func(img: Image):
			img.save_png(out)
			print("main: saved ", out)
			get_tree().quit())
	else:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(out)
		print("main: saved ", out)
		get_tree().quit()

func animate(dt: float) -> void:
	var sim_dt := 0.0 if state.paused else dt * state.speed * state.time_scale
	state.time += dt

	fps_acc += 1.0 / maxf(dt, 1e-4); fps_count += 1; fps_time += dt
	if fps_time > 0.5:
		hud.set_text("fps", str(int(U.jround(fps_acc / fps_count))))
		fps_acc = 0.0; fps_count = 0; fps_time = 0.0

	# Everything downstream runs on the time that was integrated, so a guarded
	# frame slows the spin, the clouds and the lens together with the bodies.
	var sim_stepped := step_physics(sim_dt)
	run_pending_collapse()
	painter.update(sim_stepped)
	pipe.postfx.set_scene_temp(scene_max_temp())

	# ---- spaceflight. It owns the camera while it is active, so this runs
	# before the orrery's own camera update and that update is skipped.
	if flight.active:
		flight.update(dt, state.time)
		if flight.vessel != null and state.cam_mode != "flight": set_cam_mode("flight")
		# Relativistic aberration and Doppler of the star field, from the ship's
		# own velocity. Zero except in interstellar cruise, where it is the view.
		apply_sky_boost_all(flight.boost)

	# camera follow / movement — BEFORE anything is placed (floating origin)
	var home := get_home()
	if state.cam_mode == "flight":
		pass    # the flight pass has already placed it (flight.update)
	elif state.cam_mode == "surface" and home:
		_observe(home)
	elif state.cam_mode == "free":
		update_free_cam(dt)
	else:
		if state.follow_id != null:
			var fb := state.body_by_id(state.follow_id)
			if fb: track_follow(fb, dt)
		ease_cam_radius(dt)
		update_orbit_cam()

	# ---- near plane, tied to how far the camera actually is.
	if state.cam_mode != "surface" and state.cam_mode != "flight":
		var cam_dist: float = cam.radius
		if state.cam_mode == "free":
			cam_dist = INF
			for b in state.bodies:
				var surf := cam_pos.distance_to(b.scene_pos) - maxf(b.radius_scene, b.rs_scene)
				if surf < cam_dist: cam_dist = surf
			cam_dist = maxf(cam_dist, 1e-6) if is_finite(cam_dist) else 1.0
		# The web build used camDist·1e-3 — a 24-bit integer depth buffer needs the
		# near plane as far out as it can go, but no further. Godot's depth is
		# reverse-Z float, whose precision does not depend on the near plane, so
		# it can sit at 5% of the viewing distance (the framed body's surface is
		# at 6/7 of it) — and it MUST, because Godot builds its culling frustum in
		# float32 and every far/near ratio past ~1e7 degenerates it (measured:
		# 1e8 already fails, and the frame is culled empty; PORT_GUIDE.md §3).
		# With near that far out, far = near·1e7 still reaches the whole system:
		# ~150 scene units even at a true-scale Earth close-up.
		var near := clampf(cam_dist * 0.05, 1e-7, 0.01)
		if absf(log(near / cam_near)) > 0.05: cam_near = near
	_apply_camera()

	# ---- place everything relative to the camera (the floating origin)
	update_suns()
	var holes := []
	for h in get_holes():
		holes.append({"pos_rel": h.scene_pos.rel_v3(cam_pos), "pos_abs": h.scene_pos, "rs_scene": h.rs_scene, "mass": h.mass, "body": h})
	var ctx := {
		"holes": holes, "camera": pipe.scene_cam, "cam_pos": cam_pos, "time": state.time,
		"scene_scale": state.scene_scale, "sim_dt": sim_stepped, "suns": state.suns,
		"climate": state.climate, "bodies": state.bodies, "viewport_h": float(pipe.view_size.y),
	}
	for b in state.bodies:
		if b.type == "bh":
			b.rs_scene = b.rs * state.scene_scale
			b.radius_scene = b.rs_scene
		if b.viz != null:
			b.viz.group.position = b.scene_pos.rel_v3(cam_pos)
			b.viz.update(dt * (0.0 if state.paused else 1.0) + 0.0001, ctx)   # keep shaders animating even paused-ish
		apply_size_ease(b, dt)
	# Structural limits, on anything whose mass moved this frame.
	for b in state.bodies.duplicate(): check_structural_limits(b)

	# Bodies stripped down to nothing by accretion are fully consumed, measured
	# against the body's ORIGINAL mass: a planet is born lighter than this
	# threshold, and must not be deleted just for being a planet.
	for b in state.bodies.duplicate():
		if b.type != "bh" and b.mass0 > 0.05 and b.mass <= maxf(0.012, b.mass0 * 0.02):
			spawn_flash(b.scene_pos.clone(), 0xffcaa0, b.radius_scene * 10.0, 0.7)
			state.consumed += 1
			remove_body(b.id)

	# Sample after this frame's camera and body updates: a photometer's line of
	# sight must match the image rather than lag a camera move by one frame.
	if lessons: lessons.update(dt)

	# ---- trails and painted swarms follow the floating origin
	for b in state.bodies:
		if b.trail != null:
			b.trail.update(b, cam_pos)
	painter.place(cam_pos)

	# ---- point-source markers. Not in surface view: the sky pass draws the suns
	# itself, with real angular radii and atmospheric scattering.
	for b in state.bodies:
		if b.marker == null: continue
		if state.cam_mode == "surface":
			b.marker.mesh.visible = false
			continue
		# (b.size_k) — during an edit the mesh is mid-glide, so the marker has to
		# hand over at the size actually being drawn or it pops.
		b.marker.update(pipe.scene_cam, b.scene_pos.rel_v3(cam_pos),
			maxf(b.radius_scene, b.rs_scene) * b.size_k, float(pipe.view_size.y), b.id == state.focus_id)

	# flashes
	for i in range(flashes.size() - 1, -1, -1):
		var fl = flashes[i]
		fl.flash.node.position = (fl.abs as DVec3).rel_v3(cam_pos)
		if not fl.flash.step(dt):
			fl.flash.kill()
			flashes.remove_at(i)

	# mesh wells — recenter the slab under the camera's focus so fast/distant
	# bodies never wander off it
	var mc: DVec3 = cam_pos if state.cam_mode == "free" else cam.target
	spacetime_mesh.update(state.bodies, mc.x, mc.z, sim_stepped, cam_pos)

	# ---- model viewer: a studio, not a view of the universe — the whole frame
	if model_open:
		model_view.update(dt)
		pipe.set_mode(RenderPipeline.Mode.MODEL)
		pipe.prepare_frame(null, state.time)
		update_hud(dt)
		return

	# lensing
	var use_lens: bool = state.show_lens and not holes.is_empty()
	var lens_params = null
	if use_lens:
		var n := mini(holes.size(), LensPass.MAX_HOLES)
		var hp := []
		for i in n: hp.append({"pos": holes[i].pos_rel, "rs": holes[i].rs_scene})
		lens_params = {
			"holes": hp, "basis": cam_basis, "fov": deg_to_rad(cam_fov),
			"aspect": float(pipe.render_size.x) / float(pipe.render_size.y),
			"time": _lens_time + sim_stepped, "disc_intensity": state.disc_intensity,
			"disc_temp": state.disc_temp,
			# True peak disc temperature, for the multi-wavelength imaging.
			"disc_tpeak_phys": Derive.disc_peak_temp(holes[0].mass),
			"disc_outer": float(state.preset.get("discOuter", 15.0)) if state.preset else 15.0,
		}
	_lens_time += sim_stepped

	# The sky's footprint reference has to track the CURRENT fov: it is what the
	# measured per-pixel footprint is compared against to recover the
	# magnification.
	SkyModel.update_pix_angle(pipe.sky_materials, deg_to_rad(cam_fov), float(pipe.render_size.y))

	# ---- surface view: the sky composite runs over the scene, the home world is
	# hidden (we are standing on it) and so is the spacetime slab
	if state.cam_mode == "surface" and home:
		_surface_frame(home, dt)
		pipe.surface_pass = sky_pass
		home.viz.group.visible = false
		spacetime_mesh.node.visible = false
	else:
		pipe.surface_pass = null
		if home and home.viz: home.viz.group.visible = true
		spacetime_mesh.node.visible = state.show_mesh and not (state.cam_mode == "flight" and flight.active)

	pipe.set_mode(RenderPipeline.Mode.FLIGHT if (state.cam_mode == "flight" and flight.active) else RenderPipeline.Mode.ORRERY)
	pipe.prepare_frame(lens_params, state.time)
	update_hud(dt)

var _lens_time := 0.0

func _apply_camera() -> void:
	var c := pipe.scene_cam
	c.transform = Transform3D(cam_basis, Vector3.ZERO)
	c.fov = cam_fov
	c.near = cam_near
	# THREE draws near 1e-7 / far 1e5 fine; Godot builds its culling frustum in
	# float32 and the planes degenerate past ~1e7, culling everything (measured —
	# PORT_GUIDE.md §3). Clamping far costs nothing at those distances: the
	# body being framed is millions of near-planes away from anything beyond it.
	c.far = minf(100000.0, cam_near * 1.0e7)

## The surface view's per-frame block: sun directions from the eye, eye
## adaptation and the climate's sky — sim/skyview.gd's update_frame is the
## web build's render-loop code for it, verbatim.
func _surface_frame(_home: Body, dt: float) -> void:
	sky_pass.update_frame(observer, pipe.scene_cam, state.suns, state.climate, dt,
		float(pipe.render_size.x) / float(pipe.render_size.y))
	state.exposure = sky_pass.exposure

## Stand on the home world: the observer sets the camera's orientation, fov and
## near plane, and its eye (a DVec3) becomes the floating origin.
func _observe(home: Body) -> void:
	observer.update(home, pipe.scene_cam)
	cam_pos.copy_from(observer.eye)
	cam_basis = pipe.scene_cam.transform.basis
	cam_fov = pipe.scene_cam.fov
	cam_near = pipe.scene_cam.near

# ============================================================================
# THE PRESET CHECK — .claude/presetcheck.js: load EVERY scenario, run a second
# of frames in each, and report anything that threw or quietly lost bodies. A
# GDScript runtime error does not throw, it prints, so each preset is bracketed
# by markers and tools/presetcheck.sh attributes SCRIPT ERROR lines between them.
#   Godot --path godot -- eval=_preset_check
# ============================================================================
func _preset_check() -> void:
	var rows := []
	var errs := []
	for key in Presets.PRESET_ORDER:
		print("PRESETCHECK BEGIN ", key)
		load_preset(key)
		var n0 := state.bodies.size()
		for i in 60: animate(1.0 / 60.0)
		var n1 := state.bodies.size()
		rows.append("%s: %d->%d" % [key, n0, n1])
		if n1 < n0 and not (key.contains("merger") or key.contains("feeding") or key.contains("binarystar") or key.contains("zoo")):
			errs.append("%s: lost %d bodies in one second (%s)" % [key, n0 - n1, Presets.PRESETS[key].name])
		print("PRESETCHECK END ", key)
	print("PRESETCHECK ROWS ", " | ".join(rows))
	print("PRESETCHECK LOST ", errs)
	print("PRESETCHECK DONE ", Presets.PRESET_ORDER.size())
	get_tree().quit()
