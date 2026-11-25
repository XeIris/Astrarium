class_name SurfaceSea
extends RefCounted

# The sea under a vessel built to float (`floats` in its vehicle), coming down on a world with oceans or with
# seas stated where they were mapped (StatedSeas: Titan's): the recovery area's weather and its FFT sea, asked for when the chutes open and stood on 20 flight-seconds later,
# then the Floater that takes the vessel the last few metres down and holds it afloat. Physics only, owned by
# the Vessel; Spaceflight draws the site (SurfaceSite with this field) and the floating craft. It reads the
# world and writes nothing back. docs/physics/ocean.md#coming-down-at-sea. SI.

## Flight seconds from asking for the sea to standing on it: the same moment drawn or fast-forwarded.
const ADOPT_S := 20.0
## The Floater takes the vessel over this far above the mean sea, m: higher than any crest it meets.
const HANDOFF := 15.0
## The recovery area's fetch and depth, m: the open ocean's.
const FETCH := 6.0e5
const DEPTH := 4000.0
## Seconds after splashdown the crew cut the mains (an estimate; Apollo's were cut on contact).
const MAINS_CUT := 2.0
## Most of the floater's own time one integration step may run, s: warped hours at sea pass with it resting.
const CATCH_UP := 4.0

var body: Body
var run_seed := 0
var pin: PlanetPin = null
var weather: SurfaceWeather = null
var liquid := Liquid.SEAWATER
var field: OceanField = null
var floater: Floater = null
## What floats: Capsule (the Apollo CM) or TimeCapsule, by the vehicle's `floats`.
var hull = Capsule
var depth := DEPTH
var fetch := FETCH
var adopt_at := INF
var adopted := false
## Coordinate time of the site's clock zero, s; and when the bags were switched on, on that clock (−1 not).
var t0 := 0.0
var bags_at := -1.0
var splash_t := -1.0
var splash_v := 0.0
var _splash_logged := false
var datum_r := 0.0
var c := DVec3.new()
var east := DVec3.new()
var north := DVec3.new()
var _m := DVec3.new()

## The sea for a vessel of `vehicle` over `b`, or null.
static func for_world(b: Body, env: Dictionary, vehicle: Dictionary, seed_: int) -> SurfaceSea:
	var floats = vehicle.get("floats", false)
	if b == null or b.climate == null or not (floats is String or bool(floats)): return null
	if not bool(env.get("oceans", false)) and not StatedSeas.has(b.name): return null
	var s := SurfaceSea.new()
	s.body = b
	s.hull = hull_for(vehicle)
	s.run_seed = seed_
	SurfaceStats.count("sea_init")
	return s

## Read the sea where the vessel will come down (flight frame, m), once, if it is sea there.
func request(v: Vessel, rr: DVec3) -> void:
	if pin != null: return
	var theta := v.body_angle(v.coord)
	var ll := SurfaceGround.lat_lon(SurfaceGround.to_mesh(rr, theta, DVec3.new()))
	var p := PlanetPin.at(body, ll[0], ll[1])
	if str(p.ground.kind) != "sea":
		v.log_event("Coming down on land at %s° %s°" % [U.fixed(rad_to_deg(ll[0]), 1), U.fixed(rad_to_deg(ll[1]), 1)])
		return
	pin = p
	c.set_v(cos(ll[1]) * cos(ll[0]), sin(ll[0]), -sin(ll[1]) * cos(ll[0]))
	east.set_v(-sin(ll[1]), 0.0, -cos(ll[1]))
	north.cross_vectors(c, east)
	DQuat.nrm(north)
	datum_r = v.surface_r(rr)
	liquid = Liquid.of(body.name)
	# A stated mare's own depth under the point and its breadth for the fetch; the open ocean's elsewhere.
	if p.ground.has("mare"):
		var mare := StatedSeas.at(body.name, ll[0], ll[1], body.radius * Rocketry.AU_M)
		depth = maxf(float(mare.depth), 10.0)
		fetch = 2.0 * float(mare.reach)
	weather = SurfaceWeather.new()
	weather.setup(body, body.climate, pin.lat, pin.lon, SurfaceSite.site_seed(body, pin, run_seed))
	var w := weather.now()
	field = OceanField.new(float(body.climate.gravity), depth, liquid, Liquid.field_wind(liquid, float(w.wind)), float(w.wind_dir), fetch,
		SurfaceSite.site_seed(body, pin, run_seed))
	t0 = v.coord
	adopt_at = v.coord + ADOPT_S
	v.log_event("%s at %s° %s°: wind %s m/s, waves %s m" % [str(p.ground.get("mare", "Recovery area")), U.fixed(rad_to_deg(ll[0]), 2),
		U.fixed(rad_to_deg(ll[1]), 2), U.fixed(float(w.wind), 1), U.fixed(field.hs(), 2)])

## The site's clock at the vessel's coordinate time, s.
func site_time(v: Vessel) -> float:
	return v.coord - t0

var _last_coord := NAN

## Once per integration step.
func tick(v: Vessel) -> void:
	if pin == null: return
	# By the time the integrator accepted, not the step it was asked for.
	if not is_nan(_last_coord): weather.step(maxf(v.coord - _last_coord, 0.0))
	_last_coord = v.coord
	if not adopted and v.coord >= adopt_at:
		adopted = true
	if floater == null: return
	var now := site_time(v)
	if floater.t < now - CATCH_UP: floater.t = now - CATCH_UP
	var w := weather.now()
	var wv := SurfaceSite.wind_vector(float(w.wind_dir)) * float(w.wind)
	floater.wind = PackedFloat64Array([wv.x, 0.0, wv.z])
	if floater.chute != null and splash_t >= 0.0 and now - splash_t > MAINS_CUT:
		floater.chute = null
		v.log_event("Main chutes released")
	if bags_at >= 0.0: hull.inflate(floater, (now - bags_at) / Capsule.INFLATE_S)
	var was_wet := floater.wet
	var vz := floater.v[1]
	floater.advance(now)
	if floater.wet and not was_wet and splash_t < 0.0:
		splash_t = floater.t
		splash_v = absf(vz)
		_from = Vector2(floater.p[0], floater.p[2])
	# Logged once the impact is over, with its peak.
	if splash_t >= 0.0 and not _splash_logged and floater.t - splash_t > 1.0:
		_splash_logged = true
		v.log_event("Splashdown — %s m/s, peak %s g" % [U.fixed(splash_v, 1), U.fixed(floater.peak_accel / 9.81, 1)])

## Hand the vessel to the sea: a Floater at its place, velocity and attitude, under the chute it has out.
func take(v: Vessel, chute_at_y: float) -> void:
	floater = hull.floater(float(body.climate.gravity), liquid, float(Rocketry.density(v.env.atm, 0.0)) if v.env.atm != null else 0.0)
	floater.field = field
	floater.t = site_time(v)
	var at := site_point(v, v.r)
	# The vessel's centre is its stage origin, the shield's lowest point; the floater's is the centre of mass.
	var ax := site_axes(v)
	var to_site := Basis(_v3(ax[1]), _v3(ax[2]), _v3(ax[3])).inverse()
	var body_b := to_site * Basis(v.q.to_quaternion())
	floater.set_basis(body_b)
	var centre: Vector3 = hull.centre()
	var cg := body_b * centre
	# Its height is over the mean sea under it: the site's plane leaves the ball by metres where the survey was
	# asked for kilometres off.
	floater.p = PackedFloat64Array([at.x + cg.x, v.altitude() + cg.y, at.z + cg.z])
	_from = Vector2(at.x, at.z)
	var gv := v.ground_velocity(v.r, v.v, DVec3.new())
	var sv := to_site * gv.to_v3()
	floater.v = PackedFloat64Array([sv.x, sv.y, sv.z])
	if v.chute_open != null:
		floater.chute = {"at": PackedFloat64Array([-centre.x, chute_at_y - centre.y, 0.0]),
			"area": float(v.chute_open.area), "cd": float(v.chute_open.Cd)}
	v.log_event("On the sea's own physics — %s m up" % U.fixed(v.altitude(), 1))

## What floats for a vehicle: TimeCapsule for `floats: "time"`, otherwise the CM.
static func hull_for(vehicle: Dictionary):
	return TimeCapsule if str(vehicle.get("floats", "")) == "time" else Capsule

## Start the uprighting bags' compressors, on a craft that has them.
func inflate_bags(v: Vessel) -> void:
	if floater == null or bags_at >= 0.0 or hull != Capsule: return
	bags_at = site_time(v)
	v.log_event("Uprighting bags inflating")

static func _v3(d: DVec3) -> Vector3:
	return d.to_v3()

## A flight-frame point in the site's frame: (west, up from the mean sea, north), m.
func site_point(v: Vessel, rr: DVec3) -> Vector3:
	SurfaceGround.to_mesh(rr, v.body_angle(v.coord), _m)
	return Vector3(-_m.dot(east), _m.dot(c) - datum_r, _m.dot(north))

## The site's origin and axes in the flight frame at the vessel's coordinate time: [origin, west, up, north].
func site_axes(v: Vessel) -> Array:
	var theta := v.body_angle(v.coord)
	var o := SurfaceGround.from_mesh(c.clone().scale_in(datum_r), theta, DVec3.new())
	var w := SurfaceGround.from_mesh(east.clone().negate_in(), theta, DVec3.new())
	var u := SurfaceGround.from_mesh(c, theta, DVec3.new())
	var nn := SurfaceGround.from_mesh(north, theta, DVec3.new())
	return [o, w, u, nn]

var _from := Vector2.ZERO

## How far the craft has drifted over the sea from where it came down, m.
func drift() -> float:
	return 0.0 if floater == null else Vector2(floater.p[0], floater.p[2]).distance_to(_from)

## Heel of the floating craft from upright, degrees; 0 before it floats.
func heel() -> float:
	if floater == null: return 0.0
	return rad_to_deg(acos(clampf(floater.rot[4], -1.0, 1.0)))

func dispose() -> void:
	SurfaceStats.count("sea_dispose")
