class_name ObservatorySites
extends RefCounted

# Observing sites: geodetic latitude and east longitude (degrees, WGS-84) and height (m).
# Jodrell Bank: the Lovell Telescope, JBO "Lovell Telescope facts and figures"
#   (jb.man.ac.uk/aboutus/lovell/facts.html); the page gives no height, so 80 m is the
#   ground level the issue's table quotes.
# Mauna Kea: Keck, Wikidata Q210997 (Keck's own telescope page was unreachable).
# Paranal: VLT UT1 and the platform's 2635.43 m, ESO Paranal astroclimate site page
#   (eso.org/sci/facilities/paranal/astroclimate/site.html).

const SITES := {
	"jodrell": {"name": "Jodrell Bank", "where": "Cheshire, UK", "lat": 53.0 + 14.0 / 60.0 + 10.50 / 3600.0,
		"lon": -(2.0 + 18.0 / 60.0 + 25.74 / 3600.0), "h": 80.0},
	"maunakea": {"name": "Mauna Kea", "where": "Hawaiʻi, USA", "lat": 19.0 + 49.0 / 60.0 + 35.0 / 3600.0,
		"lon": -(155.0 + 28.0 / 60.0 + 28.0 / 3600.0), "h": 4145.0},
	"paranal": {"name": "Cerro Paranal", "where": "Atacama, Chile", "lat": -(24.0 + 37.0 / 60.0 + 39.44 / 3600.0),
		"lon": -(70.0 + 24.0 / 60.0 + 18.27 / 3600.0), "h": 2635.43},
}
const ORDER := ["jodrell", "maunakea", "paranal"]

## "53.236° N, 2.307° W, 80 m".
static func describe(lat: float, lon: float, h: float) -> String:
	return "%.3f° %s, %.3f° %s, %d m" % [absf(lat), "N" if lat >= 0.0 else "S", absf(lon), "E" if lon >= 0.0 else "W", int(roundf(h))]
