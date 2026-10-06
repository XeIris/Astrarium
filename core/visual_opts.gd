class_name VisualOpts
extends RefCounted

# What a body visual is built from (Bodies.create_body_visual), filled by
# main.gd attach_visual from the body and its spec. Most fields are the spec's own
# value or null: null means "the spec doesn't say", and every reader supplies the
# physical default (U.nz), so a preset names only what is unusual about a body.

var radius_scene: float = 1.0    # rendered radius, scene units
var oblate: float = 1.0          # equatorial / polar radius, 1/(1 − f)
var spin_frac: float = 0.0       # spin as a fraction of break-up
var t_pole = null                # gravity-darkened pole / equator temperatures, K
var t_eq = null
var gd_beta = null
var radius_sun = null
var color = null                 # linear Color (stars), sRGB hex, or null
var teff = null
var glow = null                  # sRGB hex
var spec_seed = null             # the spec's `seed`: nudges terrain without re-rolling it
var obliquity = null
var tidal_lock = null            # the parent's name
var palette_name = null          # a GiantVisual.GIANT_PALETTES key
var giant_palette = null         # the resolved palette Dictionary (Bodies.create_giant)
var quiet: bool = false          # no spots or flares (white dwarfs)

# Surface and atmosphere (rocky_visual.gd, world.gd, terrain.gd).
var hot = null
var atmosphere = null
var atm_color = null
var atm_thick = null
var sea_level = null
var land = null
var continent = null             # land fraction as terrain.gd takes it
var sea_km = null                # sea-level datum, km
var albedo = null
var greenhouse = null
var surface_k = null
var frost_k = null
var biota = null
var crater = null
var regolith = null
var haze = null
var cloud_cover = null
var cloud_color = null
var transport = null
var season = null
var arid = null
var plate_scale = null
var land_relief = null
var ocean_depth = null

# Giants (giant_visual.gd).
var rings = null
var ring_color = null
var ring_inner = null
var ring_outer = null
var internal_heat = null
var vortices = null

## A field-for-field copy (values are shared, as Dictionary.duplicate() shares them).
func copy() -> VisualOpts:
	var c := VisualOpts.new()
	for p in get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			c.set(p.name, get(p.name))
	return c

## From a camelCase fixture Dictionary (the render harnesses hold
## them). An unknown key is an error, not a silent drop.
static func from_dict(d: Dictionary) -> VisualOpts:
	var o := VisualOpts.new()
	var names := {}
	for p in o.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE: names[p.name] = true
	for k in d:
		var f: String = "spec_seed" if k == "seed" else String(k).to_snake_case()
		if not names.has(f):
			push_error("VisualOpts: no field for '%s'" % k)
			continue
		if d[k] == null and typeof(o.get(f)) != TYPE_NIL: continue
		o.set(f, d[k])
	return o
