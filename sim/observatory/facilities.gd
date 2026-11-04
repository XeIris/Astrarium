class_name Facilities
extends RefCounted

# The observatories as places: what stands where, how the ground is levelled under it
# and how the camera sees it. Models: model_sources/blender/observatories.py, with
# SiteFallback's blocks to the same datums. Coordinates are metres east and north of
# the site's datum (ObservatorySites), from each observatory's published positions;
# docs/physics/observatory.md lists the sources and which sizes are estimates.

## Where 1″ of latitude and longitude come to at the site, m (WGS-84, rounded).
const ARCSEC := {"jodrell": [30.9, 18.6], "maunakea": [30.7, 29.1], "paranal": [30.72, 28.17]}

# parts: {stage, e, n, y (null = on the levelled ground), yaw (rad, about up), pose}.
# flats: [e, n, half-width east, half-width north, yaw, height (null = the DEM there), blend].
const DATA := {
	"jodrell": {
		"telescope": "Lovell Telescope", "kind": "76.2 m radio dish",
		"blurb": "The third-largest steerable dish in the world, built with gun-turret gears from two battleships. It tracked Sputnik's carrier rocket in 1957.",
		"facts": [["Bowl", "76.2 m, 1500 t"], ["Height", "89.0 m"], ["Focal length", "22.9 m"], ["Band", "radio, to about 5 cm"], ["Also here", "Mark II, 38 × 25 m"]],
		"patch_y": 60.0,
		"ground": "cheshire",
		"flats": [[0.0, 0.0, 74.0, 74.0, 0.0, 77.0, 45.0], [269.0, -329.0, 24.0, 24.0, 0.0, null, 25.0]],
		"parts": [
			{"stage": "lovell", "e": 0.0, "n": 0.0, "pose": {"az": 200.0, "el": 62.0}},
			# The 425 m baseline, on the bearing of the published coordinates.
			{"stage": "mark2", "e": 269.0, "n": -329.0, "pose": {"az": 200.0, "el": 62.0}},
		],
		"orbit": {"e": 0.0, "n": 0.0, "radius": 185.0, "height": 34.0, "look": 42.0, "secs": 40.0},
		"view": {"e": -125.0, "n": -105.0, "eye": 1.7, "az": 40.0, "alt": 22.0},
	},
	"maunakea": {
		"telescope": "W. M. Keck Observatory", "kind": "twin 10 m optical and infrared",
		"blurb": "Two telescopes of 36 hexagonal mirror segments each, 85 m apart, above most of the atmosphere's water vapour. Subaru and NASA's IRTF stand on the same ridge.",
		"facts": [["Mirrors", "2 × 10 m, 36 segments"], ["Altitude", "4145 m"], ["Focal length", "17.5 m"], ["Band", "optical, infrared"], ["Baseline", "85 m"]],
		"patch_y": 0.0,
		"ground": "cinder",
		"flats": [[-3.0, -15.0, 95.0, 42.0, 0.64, 4145.0, 36.0], [-175.0, -92.0, 30.0, 30.0, 0.0, null, 20.0], [262.0, -31.0, 30.0, 22.0, 0.0, null, 20.0]],
		"parts": [
			{"stage": "keck", "e": -28.8, "n": -48.8, "pose": {"dome": 150.0, "az": 150.0, "el": 62.0, "open": 1.0}},
			{"stage": "keck", "e": 22.2, "n": 18.9, "pose": {"dome": 210.0, "az": 210.0, "el": 70.0, "open": 1.0}},
			# Between the two, on the baseline.
			{"stage": "keck_hall", "e": -3.3, "n": -15.0, "yaw": 0.93},
			{"stage": "subaru", "e": -175.0, "n": -92.0},
			{"stage": "irtf", "e": 262.0, "n": -31.0},
		],
		"orbit": {"e": 0.0, "n": -15.0, "radius": 150.0, "height": 22.0, "look": 18.0, "secs": 40.0},
		"view": {"e": 70.0, "n": -105.0, "eye": 1.7, "az": 325.0, "alt": 22.0},
	},
	"paranal": {
		"telescope": "Very Large Telescope", "kind": "four 8.2 m, four 1.8 m optical and infrared",
		"blurb": "Four Unit Telescopes and four movable Auxiliary Telescopes on a platform cut from the top of Cerro Paranal, combined by tunnel as one interferometer. VISTA is on the next summit.",
		"facts": [["Mirrors", "4 × 8.2 m, 4 × 1.8 m"], ["Altitude", "2635 m"], ["Focal length", "14.4 m"], ["Band", "optical, infrared"], ["Longest baseline", "130 m (UTs)"]],
		"patch_y": 0.0,
		"ground": "atacama",
		"flats": [[65.0, 20.0, 125.0, 170.0, 0.0, 2635.43, 42.0], [758.0, 1318.0, 42.0, 42.0, 0.0, null, 30.0]],
		"parts": [
			# ESO's coordinates for UT1–UT4, VST and VISTA; ATs on four of its stations.
			{"stage": "vlt_platform", "e": 0.0, "n": 0.0},
			{"stage": "ut", "e": 0.0, "n": 0.0, "pose": {"dome": 300.0, "az": 300.0, "el": 62.0, "slide": 6.8}},
			{"stage": "ut", "e": 24.8, "n": 50.3, "pose": {"dome": 300.0, "az": 300.0, "el": 62.0, "slide": 6.8}},
			{"stage": "ut", "e": 54.9, "n": 86.0, "pose": {"dome": 300.0, "az": 300.0, "el": 62.0, "slide": 6.8}},
			{"stage": "ut", "e": 113.2, "n": 63.9, "pose": {"dome": 300.0, "az": 300.0, "el": 62.0, "slide": 6.8}},
			{"stage": "vst", "e": 112.6, "n": 142.8, "pose": {"dome": 40.0}},
			{"stage": "vista", "e": 758.0, "n": 1318.0, "pose": {"dome": 200.0}},
			# Stations D0, A0, G1 and J1.
			{"stage": "at", "e": 25.6, "n": -24.9},
			{"stage": "at", "e": -4.8, "n": -35.3},
			{"stage": "at", "e": 76.6, "n": -74.6},
			{"stage": "at", "e": 116.6, "n": -19.0},
		],
		"orbit": {"e": 60.0, "n": 25.0, "radius": 235.0, "height": 55.0, "look": 12.0, "secs": 40.0},
		"view": {"e": 72.0, "n": -22.0, "eye": 1.7, "az": 340.0, "alt": 20.0},
	},
}
