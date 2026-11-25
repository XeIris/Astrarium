class_name SurfaceGround
extends RefCounted

# The ground under a vessel coming down on a dry world: the measured grid (PlanetElevation: the Moon, Mars),
# or on a world without one (Titan) the crust its visual draws (PlanetRelief), until a landing site has been
# surveyed, then that site's carved terrain read off the
# triangles SiteScene draws, so what the gear touches is what is on screen. Physics only, owned by the
# Vessel; Spaceflight draws the adopted site. It reads the world and writes nothing back.
# docs/physics/surface.md#the-ground-under-a-landing. SI.

## Cells a side on each of a landing's grids, at every render quality, since the ground a vehicle lands
## on must not follow a display setting. SurfaceSite.CELLS' "high".
const CELLS := 129
## Flight seconds from asking for a survey to standing on it. Drawn or fast-forwarded, the ground changes
## at the same moment; a survey still running then is waited for. It takes 0.25–1.3 s of wall time.
const ADOPT_S := 20.0
## With no program asking first, a survey is asked for below this height over the measured ground, m,
const AUTO_AGL := 6000.0
## when slower over the ground than this, m/s.
const AUTO_VH := 300.0

var body: Body
## The measured grid, or null where the crust stands in for it.
var elevation: PlanetElevation
var crust: PlanetRelief
var run_seed := 0
## The surveyed site, once asked for.
var pin: PlanetPin = null
var relief: SurfaceRelief = null
## Coordinate time, s, at which the survey becomes the ground.
var adopt_at := INF
var adopted := false
## SurfaceSite.patch_level of the adopted grids, m: what the mesh's rim drops to.
var patch_y := 0.0
## The site's frame on the body, double: its datum point's radius (the flight figure under the pin), m,
## and unit up, east and north in the planet mesh's frame (+Y north, PlanetPin.direction).
var datum_r := 0.0
var c := DVec3.new()
var east := DVec3.new()
var north := DVec3.new()
var _task := -1
var _m := DVec3.new()

## The ground for a vessel whose parent is `b`, or null where the figure stays the ground: a world with seas
## or launch sites keeps it.
static func for_world(b: Body, env: Dictionary, seed_: int) -> SurfaceGround:
	if b == null or b.climate == null or b.viz == null or bool(env.get("oceans", false)): return null
	var viz = PlanetPin._viz(b)
	if viz == null or not ("surf_mat" in viz) or viz.surf_mat == null: return null
	var crust := PlanetRelief.of_body(b)
	# A map with coasts is Earth's; a dry map needs its measured grid; no map, the crust.
	if crust.map_kind == 1: return null
	var dem := PlanetElevation.of(b.name) if crust.map_kind == 2 else null
	if crust.map_kind == 2 and dem == null: return null
	var g := SurfaceGround.new()
	g.body = b
	g.elevation = dem
	g.crust = crust
	g.run_seed = seed_
	SurfaceStats.count("ground_init")
	return g

## A flight-frame point (pole on −Y, Vessel.body_angle `theta` turning the prime meridian) in the planet
## mesh's frame, into `out`.
static func to_mesh(rr: DVec3, theta: float, out: DVec3) -> DVec3:
	var ct := cos(theta)
	var st := sin(theta)
	return out.set_v(rr.x * ct + rr.z * st, -rr.y, rr.x * st - rr.z * ct)

## The inverse of to_mesh.
static func from_mesh(m: DVec3, theta: float, out: DVec3) -> DVec3:
	var ct := cos(theta)
	var st := sin(theta)
	var x := m.x
	var z := -m.z
	return out.set_v(x * ct - z * st, -m.y, x * st + z * ct)

## [latitude, east longitude], rad, of a mesh-frame vector; double, since a float32 radian is 0.2 m on Mars.
static func lat_lon(m: DVec3) -> PackedFloat64Array:
	return PackedFloat64Array([asin(clampf(m.y / maxf(m.length(), 1e-9), -1.0, 1.0)), atan2(-m.z, m.x)])

## Height above the ground under `rr` (flight frame, m) along the local vertical, m: the vessel's
## altitude over the figure less the measured height, or, over an adopted survey, the drawn terrain.
func agl(v: Vessel, rr: DVec3) -> float:
	to_mesh(rr, v.body_angle(v.coord), _m)
	var up_c := _m.dot(c)
	# The tangent plane's coordinates are small again at the antipode.
	if adopted and up_c > 0.5 * datum_r:
		var e := _m.dot(east)
		var n := _m.dot(north)
		var g := SiteScene.drawn_height(relief.grids, e, n, patch_y, relief.radius_m, false)
		# A stated sea's floor is under its liquid, which is what stops a fall.
		if relief.stated != "" and not is_nan(g): g = maxf(g, 0.0)
		if not is_nan(g):
			var h := up_c - datum_r - g
			# The grid's rim is eased down to the planet's patch (SurfaceRelief._ramp_rim), which the measured ground
			# is not: a radar altimeter crossing it must not read a kilometre's step.
			var half := float(relief.grids[1].half)
			var t := smoothstep(1.0 - SurfaceRelief.RIM, 1.0, maxf(absf(e), absf(n)) / half)
			if t <= 0.0: return h
			var lr := lat_lon(_m)
			return lerpf(h, v.altitude(rr) - coarse_m(lr[0], lr[1]), t)
	var ll := lat_lon(_m)
	return v.altitude(rr) - coarse_m(ll[0], ll[1])

## Whether `rr` (flight frame, m) is over the surveyed grid.
func covers(v: Vessel, rr: DVec3) -> bool:
	return adopted and near_side(v, rr) and maxf(absf(_m.dot(east)), absf(_m.dot(north))) <= float(relief.grids[1].half)

## Whether a landing at `rr` is off this survey, which is then done with.
func outgrown(v: Vessel, rr: DVec3) -> bool:
	return adopted and not covers(v, rr)

var _visited := false
## Flown twice the grid's half-width from a survey it has been over, or coming down somewhere off it.
func left(v: Vessel) -> bool:
	if not adopted or v.phase == Vessel.PHASE.LANDED: return false
	if covers(v, v.r):
		_visited = true
		return false
	if not _visited:
		var at = _coming_down(v)
		return at != null and not covers(v, at)
	to_mesh(v.r, v.body_angle(v.coord), _m)
	return acos(clampf(_m.dot(c) / maxf(_m.length(), 1.0), -1.0, 1.0)) * datum_r > 2.0 * float(relief.grids[1].half)

## The ground's height over the figure at a latitude and longitude before a survey, m: measured, or the crust's
## as a pin reads it (PlanetPin.read_ground).
func coarse_m(lat: float, lon: float) -> float:
	if elevation != null: return elevation.at(lat, lon)
	var h := crust.height(PlanetPin.direction(lat, lon)).x
	var m := (h - crust.sea_km if crust.sea_km > -30.0 else h) * 1000.0
	# Over a stated sea, what an altimeter ranges to is the liquid, at the datum.
	if StatedSeas.has(body.name) and _at_sea(lat, lon): return 0.0
	return m

func _at_sea(lat: float, lon: float) -> bool:
	var mare := StatedSeas.at(body.name, lat, lon, body.radius * Rocketry.AU_M)
	return not mare.is_empty() and float(mare.inside) > 0.0

## Survey the ground around the flight-frame point `rr`, once. The first request stands.
func request(v: Vessel, rr: DVec3) -> void:
	if pin != null: return
	var theta := v.body_angle(v.coord)
	var ll := lat_lon(to_mesh(rr, theta, DVec3.new()))
	pin = PlanetPin.at(body, ll[0], ll[1])
	# At sea the liquid is the ground, and SurfaceSea stands under a craft built to float.
	if str(pin.ground.kind) == "sea":
		v.log_event("Coming down on %s" % str(pin.ground.get("mare", "the sea")))
		return
	c.set_v(cos(ll[1]) * cos(ll[0]), sin(ll[0]), -sin(ll[1]) * cos(ll[0]))
	east.set_v(-sin(ll[1]), 0.0, -cos(ll[1]))
	north.cross_vectors(c, east)
	DQuat.nrm(north)
	# The figure depends on latitude alone, so the radius under the pin is the radius under rr's direction.
	datum_r = v.surface_r(rr)
	var crust := PlanetRelief.of_body(body)
	relief = SurfaceSite.plan_relief(body, pin, crust, CELLS, SurfaceSite.site_seed(body, pin, run_seed))
	_task = WorkerThreadPool.add_task(relief.build, false, "landing survey")
	adopt_at = v.coord + ADOPT_S
	v.log_event("Surveying the ground at %s° %s°" % [U.fixed(rad_to_deg(ll[0]), 3), U.fixed(rad_to_deg(ll[1]), 3)])

## Once per integration step: ask for a survey if nothing has and the vessel is low and slow, and stand
## on it when its time comes.
func tick(v: Vessel) -> void:
	if pin == null:
		var at = _coming_down(v)
		if at != null: request(v, at)
		return
	if adopted or v.coord < adopt_at: return
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	if relief.grids.is_empty(): return
	patch_y = SurfaceSite.patch_level(relief.grids, false)
	adopted = true
	# Already down when it came: onto the ground as surveyed.
	if v.phase == Vessel.PHASE.LANDED and not v.flown and not v.afloat():
		DQuat.set_len(v.r, v.ground_r(v.r) - v.gear_off)
	v.log_event("Standing on the surveyed ground")

## Whether `rr` is on the pin's side of the world, where the site's plane means anything.
func near_side(v: Vessel, rr: DVec3) -> bool:
	return to_mesh(rr, v.body_angle(v.coord), _m).dot(c) > 0.5 * datum_r

# Where a vessel low and slow enough to be landing comes down (flight frame, m), or null.
func _coming_down(v: Vessel):
	var h := agl(v, v.r)
	if h > AUTO_AGL: return null
	var up := DQuat.nrm(v.r.clone())
	var gv := v.ground_velocity(v.r, v.v, DVec3.new())
	var vv := gv.dot(up)
	gv.add_scaled_in(up, -vv)
	var vh := gv.length()
	if vh > AUTO_VH or vv >= 0.0: return null
	# Where a steady deceleration to rest on the ground would put it: v_h · h / |v_z|.
	var lead := minf(vh * maxf(h, 0.0) / maxf(-vv, 1.0), SurfaceRelief.FAR_HALF * 0.5)
	var at := up.clone().scale_in(v.r.length())
	if vh > 1e-3: at.add_scaled_in(gv, lead / vh)
	return at

## A flight-frame point in the adopted site's frame: (west, up, north), m, as the site's group is laid out.
func site_point(v: Vessel, rr: DVec3) -> Vector3:
	to_mesh(rr, v.body_angle(v.coord), _m)
	return Vector3(-_m.dot(east), _m.dot(c) - datum_r, _m.dot(north))

## The site's origin and axes in the flight frame at the vessel's coordinate time: [origin, west, up, north].
func site_axes(v: Vessel) -> Array:
	var theta := v.body_angle(v.coord)
	var o := from_mesh(c.clone().scale_in(datum_r), theta, DVec3.new())
	var w := from_mesh(east.clone().negate_in(), theta, DVec3.new())
	var u := from_mesh(c, theta, DVec3.new())
	var nn := from_mesh(north, theta, DVec3.new())
	return [o, w, u, nn]

func dispose() -> void:
	if _task >= 0:
		relief.cancelled = true
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	SurfaceStats.count("ground_dispose")
