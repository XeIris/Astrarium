class_name Vehicles
extends RefCounted

# Vehicle and engine catalogue in kg, N, m and s.
# Vacuum thrust/Isps are per engine; Rocketry derives pressure-dependent output.
# Stages share engine dictionaries by identity. Source record: web/docs/spaceflight-research.md.

# ENGINES. `throttleMin` is the real deep-throttle limit: a Merlin can't go below
# 57%, so an empty first stage lands by hoverslam. The Apollo DPS has a forbidden
# band from 60% to 92.5% (valve erosion) that the guidance must avoid.
static var ENGINES: Dictionary = _build_engines()

static func _build_engines() -> Dictionary:
	return {
		"F1": {
			"name": "F-1", "prop": "RP-1/LOX",
			"thrustVac": 7770e3, "ispSL": 263.0, "ispVac": 304.0, "throttleMin": 1.0, "gimbal": 5.15,
			"exitD": 3.53, "plume": "kerolox",
		},
		"J2": {
			"name": "J-2", "prop": "LH2/LOX",
			"thrustVac": 1033e3, "ispSL": 200.0, "ispVac": 421.0, "throttleMin": 1.0, "gimbal": 7.0,
			"exitD": 2.01, "plume": "hydrolox",
		},
		"MERLIN1D": {
			"name": "Merlin 1D", "prop": "RP-1/LOX",
			"thrustVac": 932e3, "ispSL": 282.0, "ispVac": 311.0, "throttleMin": 0.57, "gimbal": 5.0,
			"exitD": 0.92, "plume": "kerolox",
		},
		"MVAC": {
			"name": "Merlin 1D Vacuum", "prop": "RP-1/LOX",
			"thrustVac": 981e3, "ispSL": 200.0, "ispVac": 348.0, "throttleMin": 0.39, "gimbal": 5.0,
			"exitD": 3.30, "plume": "kerolox",
		},
		"RS25": {
			"name": "RS-25 (SSME)", "prop": "LH2/LOX",
			"thrustVac": 2279e3, "ispSL": 366.0, "ispVac": 452.3, "throttleMin": 0.67, "gimbal": 10.5,
			"maxThrottle": 1.09, "exitD": 2.30, "plume": "hydrolox",
		},
		"SRB_RSRM": {
			"name": "RSRM solid booster", "prop": "APCP solid",
			"thrustVac": 14000e3, "ispSL": 242.0, "ispVac": 268.0, "throttleMin": 1.0, "gimbal": 8.0,
			# A solid follows its grain, not the throttle — see solid_thrust_fraction.
			"solid": true, "exitD": 3.75, "plume": "solid",
		},
		"RAPTOR2": {
			"name": "Raptor 2", "prop": "CH4/LOX",
			"thrustVac": 2394e3, "ispSL": 327.0, "ispVac": 347.0, "throttleMin": 0.40, "gimbal": 15.0,
			"exitD": 1.30, "plume": "methalox",
		},
		"RAPTOR_VAC": {
			"name": "Raptor Vacuum", "prop": "CH4/LOX",
			"thrustVac": 2530e3, "ispSL": 200.0, "ispVac": 380.0, "throttleMin": 0.40, "gimbal": 0.0,
			"exitD": 2.40, "plume": "methalox",
		},
		"DPS": {
			"name": "LM Descent Engine", "prop": "Aerozine-50/N2O4",
			"thrustVac": 45040.0, "ispSL": 200.0, "ispVac": 311.0, "throttleMin": 0.10, "gimbal": 6.0,
			# The valve-erosion band. Guidance must sit either below 0.60 or above 0.925.
			"forbidden": [0.60, 0.925], "exitD": 1.52, "plume": "hypergolic",
		},
		"APS": {
			"name": "LM Ascent Engine", "prop": "Aerozine-50/N2O4",
			"thrustVac": 15600.0, "ispSL": 200.0, "ispVac": 311.0, "throttleMin": 1.0, "gimbal": 0.0,
			"exitD": 0.86, "plume": "hypergolic",
		},
		"SPS": {
			"name": "Service Propulsion System", "prop": "Aerozine-50/N2O4",
			"thrustVac": 91200.0, "ispSL": 200.0, "ispVac": 314.0, "throttleMin": 1.0, "gimbal": 6.0,
			"exitD": 2.24, "plume": "hypergolic",
		},
		"MLE": {
			"name": "Mars Descent Engine (MLE)", "prop": "Hydrazine",
			# Eight fixed MLEs steered by differential throttle, modelled as an equivalent
			# gimbal deflection.
			"thrustVac": 3060.0, "ispSL": 200.0, "ispVac": 210.0, "throttleMin": 0.20, "gimbal": 5.0,
			"exitD": 0.20, "plume": "hypergolic",
		},
		"NEXT_ION": {
			"name": "NEXT gridded ion", "prop": "Xenon",
			# 237 mN at 6.9 kW, Isp 4190 s. Four orders of magnitude below a Merlin, and
			# that is the whole character of the vehicle it flies on.
			"thrustVac": 0.237, "ispSL": 4190.0, "ispVac": 4190.0, "throttleMin": 0.10, "gimbal": 2.0,
			"electric": true, "powerW": 6900.0, "exitD": 0.36, "plume": "ion",
		},
		"SPIN_DRIVE": {
			"name": "Astrophage spin drive", "prop": "Astrophage",
			# A PHOTON ROCKET, derived: astrophage stores ~9e16 J/kg, c² to two figures, so the
			# exhaust is light, v_e = c, Isp = c/g₀ = 3.06e7 s. Throttled to hold a constant
			# proper acceleration (1.5 g), so vessel.gd sets F = m·a and ṁ = F/c
			# (photon_output; cruise in relativity.gd). thrustVac is the plate's ceiling.
			"thrustVac": 3.1e7, "ispSL": 3.0570e7, "ispVac": 3.0570e7, "throttleMin": 0.001,
			# Aperture 1.64 m: thrust is P/c, so the exit is sized by radiated power, not an
			# expansion ratio. The plume scales from it too.
			"gimbal": 0.0, "photon": true, "holdAccel": 1.5 * 9.80665, "exitD": 1.64, "plume": "spin",
		},
		"BEETLE_DRIVE": {
			"name": "Beetle spin drive", "prop": "Astrophage",
			"thrustVac": 1.4e5, "ispSL": 3.0570e7, "ispVac": 3.0570e7, "throttleMin": 0.001,
			"gimbal": 0.0, "photon": true, "holdAccel": 1.5 * 9.80665, "exitD": 0.9, "plume": "spin",
		},
		"DRACO": {
			"name": "Draco RCS", "prop": "MMH/NTO",
			"thrustVac": 400.0, "ispSL": 150.0, "ispVac": 300.0, "throttleMin": 0.05, "gimbal": 0.0,
			"exitD": 0.09, "plume": "hypergolic",
		},
	}

# A stage as a table row. `look` is only for craftmodel, kept beside the masses so
# the stage is described once.
static func stage(o: Dictionary) -> Dictionary:
	var eng = o.get("engine")
	var s := {
		"gimbalDeg": eng.get("gimbal", 0.0) if eng != null else 0.0,
		"sep": "jettison",
	}
	for k in o:
		s[k] = o[k]
	# Reference area for drag: the stage's own frontal area unless something
	# wider is stacked on it. The vessel takes the maximum over live stages.
	s["area"] = o["area"] if o.get("area") != null else PI * pow(o.D / 2.0, 2.0)
	return s

# VEHICLES
static var VEHICLES: Dictionary = _build_vehicles()

static func _build_vehicles() -> Dictionary:
	var E := ENGINES
	return {

	# SATURN V — the expendable superheavy. Three stages, and the only vehicle
	# here whose third stage restarts to leave Earth entirely.
	"saturnv": {
		"id": "saturnv", "name": "Saturn V / Apollo", "role": "launch", "launchFrom": "Earth",
		"era": "1967–1973",
		"blurb": "Three stages, 2 970 t on the pad, 111 m tall. The S-IVB restarts for translunar injection; the CSM and LM ride under the fairing.",
		"limits": { "maxQ": 42e3, "maxG": 4.5, "qAlpha": 5e3, "heatLoad": 0.0 },
		"target": { "apoapsis": 185e3, "inclination": 32.5 },
		"stages": [
			stage({ "key": "sic", "name": "S-IC", "dry": 137000.0, "prop": 2077000.0,
				"engine": E.F1, "count": 5, "L": 42.0, "D": 10.06,
				"look": { "skin": "white", "pattern": "saturn", "fins": 4, "interstage": 1.5, "fixedGimbals": [0] } }),
			stage({ "key": "sii", "name": "S-II", "dry": 36200.0, "prop": 443000.0,
				"engine": E.J2, "count": 5, "L": 24.9, "D": 10.06,
				"rcs": { "thrust": 3300.0, "isp": 190.0, "prop": 400.0, "count": 8 },
				"look": { "skin": "white", "interstage": 2.0, "fixedGimbals": [0] } }),
			stage({ "key": "sivb", "name": "S-IVB", "dry": 13500.0, "prop": 109500.0,
				"engine": E.J2, "count": 1, "L": 17.8, "D": 6.60, "restarts": 1,
				# The auxiliary propulsion modules — also what settles the propellant
				# before the restart for translunar injection.
				"rcs": { "thrust": 654.0, "isp": 274.0, "prop": 250.0, "count": 6 },
				# The spacecraft-LM adapter: a cone from 6.6 m to 3.9 m, the LM folded inside.
				"look": { "skin": "white", "band": "black", "aftSkirt": true, "interstage": 6.5 } }),
			stage({ "key": "csm", "name": "CSM \"Columbia\"", "dry": 11900.0, "prop": 18410.0,
				"engine": E.SPS, "count": 1, "L": 11.0, "D": 3.9, "sep": "none",
				"rcs": { "thrust": 445.0, "isp": 290.0, "prop": 550.0, "count": 16 },
				"look": { "skin": "metal", "capsule": true, "dish": true, "radiators": true } }),
		],
		# Carried inside the spacecraft-LM adapter and extracted after TLI. It is a
		# vehicle in its own right (see `lm`), listed here so the stack has its mass.
		"carries": { "vehicle": "lm", "mass": 15200.0, "at": "sivb" },
	},

	# FALCON 9 BLOCK 5. The first stage separates at ~65 km with a third of its Δv left
	# for coming back.
	"falcon9": {
		"id": "falcon9", "name": "Falcon 9 Block 5", "role": "launch", "launchFrom": "Earth",
		"era": "2018–",
		"blurb": "Nine Merlins, a recoverable first stage with grid fins and legs, and a hoverslam that has to be solved for rather than scripted — minimum throttle gives TWR > 1, so it cannot hover.",
		"limits": { "maxQ": 45e3, "maxG": 6.0, "qAlpha": 5e3, "heatLoad": 180e6 },
		"target": { "apoapsis": 200e3, "inclination": 28.5 },
		"stages": [
			stage({ "key": "f9s1", "name": "Stage 1", "dry": 22200.0, "prop": 411000.0,
				"engine": E.MERLIN1D, "count": 9, "L": 41.2, "D": 3.66,
				"recover": "droneship", "gridFins": 4, "legs": 4,
				# Legs rated above Apollo's: a hoverslam arrives with no margin.
				"gear": { "vVert": 6.0, "vHoriz": 2.0 },
				"rcs": { "thrust": 400.0, "isp": 70.0, "prop": 400.0, "count": 8 },
				# Reserve held back for boostback, entry and landing. Not invented: it
				# is what a droneship profile actually keeps, ~8% of the load.
				"reserve": 0.08,
				"look": { "skin": "white", "soot": true, "octaweb": true, "interstage": 4.0,
						"interstageSkin": "black" } }),
			stage({ "key": "f9s2", "name": "Stage 2", "dry": 4000.0, "prop": 111500.0,
				"engine": E.MVAC, "count": 1, "L": 13.8, "D": 3.66, "restarts": 2,
				# Cold-gas N₂ RCS: the gimbal only has authority while thrusting.
				"rcs": { "thrust": 220.0, "isp": 70.0, "prop": 400.0, "count": 8 },
				"look": { "skin": "white", "nozzleExt": true } }),
			stage({ "key": "f9fair", "name": "Payload fairing", "dry": 1900.0, "prop": 0.0,
				"engine": null, "count": 0, "L": 13.1, "D": 5.2, "sep": "fairing",
				# Free-molecular heating below ~1135 W/m² is the real criterion, not an
				# altitude — so a lofted ascent sheds it earlier, as it should.
				"jettisonAt": { "heat": 1135.0 },
				"look": { "fairing": true } }),
			stage({ "key": "f9pl", "name": "Payload", "dry": 13000.0, "prop": 0.0,
				"engine": null, "count": 0, "L": 5.0, "D": 3.4, "sep": "none",
				# The payload rides inside the fairing.
				"look": { "satellite": true, "arrays": 2, "arrayCover": "f9fair", "mount": { "y": 61.0 } } }),
		],
	},

	# SPACE SHUTTLE: the orbiter's engines light on the pad and burn to cutoff, fed from
	# a tank it throws away.
	"shuttle": {
		"id": "shuttle", "name": "Space Shuttle", "role": "launch", "launchFrom": "Earth",
		"era": "1981–2011",
		"blurb": "Two solids that cannot be shut down, three engines fed from a tank that is not part of the orbiter, and a wing that only matters for the last twenty minutes of the mission.",
		"limits": { "maxQ": 45e3, "maxG": 3.2, "qAlpha": 4e3, "heatLoad": 900e6 },
		"target": { "apoapsis": 300e3, "inclination": 51.6 },
		"stages": [
			stage({ "key": "srb", "name": "SRB pair", "dry": 172000.0, "prop": 1004000.0,
				"engine": E.SRB_RSRM, "count": 2, "L": 45.5, "D": 3.71, "liftoff": true,
				# A solid cannot be throttled or shut down. Once lit, it burns out.
				"look": { "skin": "white", "srb": true, "chutes": 3, "mount": { "y": 1.1 } } }),
			stage({ "key": "et", "name": "External Tank + SSME", "dry": 26500.0, "prop": 719000.0,
				"engine": E.RS25, "count": 3, "L": 46.9, "D": 8.40,
				# The SSMEs light with the solids and burn six minutes past them (`liftoff`).
				"liftoff": true, "engineOn": "orbiter",
				# The SSMEs can't relight, so the tank drops 18 s after MECO and OMS inserts at apogee.
				"sepAfterCutoff": 18.0,
				"rcs": { "thrust": 3870.0, "isp": 289.0, "prop": 800.0, "count": 44 },
				"look": { "skin": "foam", "tank": true, "mount": { "y": 10.3 } } }),
			stage({ "key": "orbiter", "name": "Orbiter + payload", "dry": 99000.0, "prop": 10800.0,
				"engine": E.SPS, "count": 2, "L": 37.2, "D": 5.6, "sep": "none",
				"wings": { "span": 23.8, "area": 250.0, "clMax": 1.4 },
				"rcs": { "thrust": 3870.0, "isp": 289.0, "prop": 1460.0, "count": 44 },
				# z = tank radius (4.2 m) plus the orbiter's half-depth. y from the aft attach
				# points: the tank's 2.8 m above its base (ET station 2058), the orbiter's 27.4 m
				# behind its nose (Xo 1317), putting the nose at 40.5 m, level with the intertank.
				"look": { "skin": "tiles", "orbiter": true, "flaps": 1, "staticEngines": true, "mount": { "y": 3.3, "z": 7.05 } } }),
		],
	},

	# SUPER HEAVY / STARSHIP — both halves come back, which makes it the only
	# vehicle here with two landings per flight.
	"starship": {
		"id": "starship", "name": "Starship / Super Heavy", "role": "launch", "launchFrom": "Earth",
		"era": "2023–",
		"blurb": "33 Raptors under 3 400 t of methalox. Both stages return: the booster to the tower, the ship belly-first through the atmosphere and then flipped upright in the last seconds.",
		"limits": { "maxQ": 45e3, "maxG": 4.0, "qAlpha": 6e3, "heatLoad": 1.4e9 },
		"target": { "apoapsis": 250e3, "inclination": 28.5 },
		"stages": [
			stage({ "key": "sh", "name": "Super Heavy", "dry": 275000.0, "prop": 3400000.0,
				"engine": E.RAPTOR2, "count": 33, "L": 71.0, "D": 9.0,
				"recover": "tower", "gridFins": 4, "reserve": 0.06,
				"rcs": { "thrust": 8000.0, "isp": 80.0, "prop": 3000.0, "count": 8 },
				"look": { "skin": "steel", "hotStage": true, "fixedGimbals": range(13, 33) } }),
			stage({ "key": "ss", "name": "Starship", "dry": 120000.0, "prop": 1200000.0,
				"engine": E.RAPTOR2, "count": 3, "vacEngine": E.RAPTOR_VAC, "vacCount": 3,
				"L": 52.0, "D": 9.0, "recover": "tower", "restarts": 3,
				"rcs": { "thrust": 6000.0, "isp": 300.0, "prop": 2000.0, "count": 12 },
				"flaps": 4, "heatShield": { "area": 400.0, "ablator": false, "tiles": true },
				"look": { "skin": "steel", "tiles": true, "nosecone": true } }),
		],
	},

	# APOLLO LM — the lander, and the only crewed vehicle ever built that could
	# not fly in an atmosphere at all.
	"lm": {
		"id": "lm", "name": "Apollo Lunar Module", "role": "lander", "launchFrom": "Moon",
		"era": "1969–1972", "airless": true,
		"blurb": "Two stages: a throttleable descent stage that lands, and an ascent stage that uses it as a launch pad. Descent follows the real P63 / P64 / P66 program sequence and its published gate conditions.",
		"limits": { "maxQ": 1e9, "maxG": 6.0, "qAlpha": 1e9, "heatLoad": 0.0 },
		"stages": [
			stage({ "key": "des", "name": "Descent stage", "dry": 2134.0, "prop": 8248.0,
				"engine": E.DPS, "count": 1, "L": 3.05, "D": 4.27, "legs": 4,
				"gear": { "vVert": 3.0, "vHoriz": 1.2 },       # the qualified Apollo rating
				"rcs": { "thrust": 445.0, "isp": 290.0, "prop": 287.0, "count": 16 },
				"look": { "skin": "mli-gold", "octagon": true, "legs": true, "fixedLegs": true, "ladder": true } }),
			stage({ "key": "asc", "name": "Ascent stage", "dry": 2150.0, "prop": 2376.0,
				"engine": E.APS, "count": 1, "L": 3.76, "D": 4.29, "sep": "none",
				"rcs": { "thrust": 445.0, "isp": 290.0, "prop": 287.0, "count": 16 },
				"look": { "skin": "mli-gold", "cabin": true, "windows": 2, "dish": true } }),
		],
		# Apollo's own descent program, with the gate conditions from LUMINARY 1A.
		"descent": {
			"pdi":    { "alt": 15240.0, "vHoriz": 1697.0, "range": 457000.0 },
			"hiGate": { "alt": 2377.0, "range": 7000.0, "vVert": -45.0, "vHoriz": 129.0 },
			"loGate": { "alt": 30.0, "range": 11.0 },
			"touchdown": { "vVert": -1.0, "vHoriz": 0.5 },
		},
	},

	# MARS SKY CRANE — an aeroshell, a supersonic parachute, a rocket-powered
	# descent stage and a rover on cables. Four separations in seven minutes.
	"skycrane": {
		"id": "skycrane", "name": "Mars EDL — Sky Crane", "role": "lander", "launchFrom": "Mars",
		"era": "2012, 2021",
		"blurb": "Entry at 5.8 km/s behind a heat shield, a supersonic chute at Mach 1.7, then a descent stage that lowers the rover on cables and flies away to crash somewhere else.",
		# A Mars entry really does peak near 15 g — Curiosity's did — so the
		# structural limit has to be above the nominal entry, not at it.
		"limits": { "maxQ": 22e3, "maxG": 20.0, "qAlpha": 8e3, "heatLoad": 120e6 },
		"stages": [
			stage({ "key": "shell", "name": "Aeroshell", "dry": 600.0, "prop": 0.0,
				"engine": null, "count": 0, "L": 2.7, "D": 4.5, "sep": "jettison",
				"blunt": true, "heatShield": { "area": 15.9, "ablator": true, "mass": 385.0, "noseR": 1.125 },
				# An offset centre of mass trims the capsule to a lifting attitude.
				# L/D 0.24 is the flown value for the MSL aeroshell.
				"lift": { "LD": 0.24 },
				"chute": { "area": 200.0, "deployMach": 1.7, "deployQ": 750.0, "Cd": 0.62 },
				"look": { "skin": "ablator", "aeroshell": true } }),
			stage({ "key": "desc", "name": "Descent stage", "dry": 829.0, "prop": 390.0,
				"engine": E.MLE, "count": 8, "L": 2.0, "D": 3.2, "sep": "skycrane",
				"rcs": { "thrust": 60.0, "isp": 220.0, "prop": 25.0, "count": 8 },
				"look": { "skin": "metal", "skycrane": true, "enginesPerPivot": 2 } }),
			stage({ "key": "rover", "name": "Rover", "dry": 1025.0, "prop": 0.0,
				"engine": null, "count": 0, "L": 2.2, "D": 2.7, "sep": "none",
				# The six wheels ARE the landing gear — the rover is lowered onto them
				# on cables and they take the touchdown load. It has no other legs.
				"legs": 6, "gear": { "vVert": 3.0, "vHoriz": 1.0 },
				"look": { "skin": "metal", "rover": true, "fixedLegs": true, "rtg": true } }),
		],
		"edl": {
			"entry":      { "alt": 125000.0, "v": 5800.0, "fpa": -15.5 },
			"chute":      { "mach": 1.7, "altMax": 11000.0 },
			"shieldJett": { "alt": 8000.0 },
			"backshell":  { "alt": 1800.0, "v": 100.0 },
			"skycrane":   { "alt": 20.0, "cable": 7.5, "vTouch": -0.75 },
		},
	},

	# ION CRUISER — the interplanetary workhorse. 237 mN and months of burn: it
	# is the vehicle that makes the warp ladder necessary.
	"ioncruiser": {
		"id": "ioncruiser", "name": "Ion Cruiser (Dawn-class)", "role": "cruiser", "launchFrom": null,
		"era": "2007–",
		"blurb": "Three NEXT gridded ion engines and 425 kg of xenon. A quarter of a newton of thrust — a tenth the weight of a postcard — held for months at a time, which is why it can visit two main-belt worlds on one tank.",
		"limits": { "maxQ": 200.0, "maxG": 1.2, "qAlpha": 100.0, "heatLoad": 0.0 },
		"stages": [
			stage({ "key": "bus", "name": "Spacecraft bus", "dry": 747.0, "prop": 425.0,
				"engine": E.NEXT_ION, "count": 3, "L": 2.36, "D": 1.64, "sep": "none",
				"rcs": { "thrust": 0.9, "isp": 220.0, "prop": 45.0, "count": 12 },
				"solar": { "span": 19.7, "area": 36.4, "powerAU": 10000.0 },
				"look": { "skin": "mli-gold", "bus": true, "arrays": 2, "dish": true } }),
		],
	},

	# HAIL MARY, from the book and the 2026 film. With v_e = c, rapidity is
	# ln(mass ratio) = ln(21) = 3.05 (2000 t of fuel, a 100 t ship). Not enough to
	# flip-and-burn 11.9 ly to Tau Ceti (6.03 at 1.5 g), but enough to
	# accelerate–coast–decelerate: rapidity 1.52 (0.909 c, γ = 2.39), coast 10.1 ly,
	# turn over. 13.9 years Earth time, 6.6 ship time: the book's thirteen years.
	# relativity.gd solves for the coast fraction.
	"hailmary": {
		"id": "hailmary", "name": "Hail Mary", "role": "interstellar", "launchFrom": null,
		"era": "Project Hail Mary",
		"blurb": "Three parallel astrophage tanks around a central spine, a pressure vessel forward of them, and a nose that holds four beetles. Four spin drives on one thrust plane, 1.5 g and 2 000 t of fuel — enough to reach Tau Ceti in thirteen Earth years and six and a half aboard.",
		"limits": { "maxQ": 1e9, "maxG": 4.0, "qAlpha": 1e9, "heatLoad": 0.0 },
		"stages": [
			stage({ "key": "hm", "name": "Hail Mary", "dry": 100000.0, "prop": 2000000.0,
				# Four drives (one under each tank, one on the axis), matching the model.
				"engine": E.SPIN_DRIVE, "count": 4, "L": 47.0, "D": 12.0, "sep": "none",
				"rcs": { "thrust": 2200.0, "isp": 300.0, "prop": 900.0, "count": 16 },
				"centrifuge": false,
				"look": { "skin": "panel-white", "hailmary": true, "tanks": 3, "beetles": 4, "radiators": 4 } }),
		],
		# Mission stars: distance in ly, J2000 `ra` (h) and `dec` (°) for the departure
		# direction (Spaceflight.mission_direction), and measured `lum`, `teff`, `radius`
		# since the star also lights the arrival.
		"missions": [
			{ "name": "Tau Ceti", "ly": 11.9, "accel": 1.5, "ra": 1.7345, "dec": -15.937,
			  "lum": 0.52, "teff": 5344.0, "radius": 0.793 },
			{ "name": "Proxima Centauri", "ly": 4.246, "accel": 1.5, "ra": 14.4953, "dec": -62.679,
			  "lum": 0.00155, "teff": 3042.0, "radius": 0.1542 },
			{ "name": "40 Eridani", "ly": 16.3, "accel": 1.5, "ra": 4.2544, "dec": -7.653,
			  "lum": 0.46, "teff": 5072.0, "radius": 0.812 },
		],
	},

	# BEETLE: the data-return probes, four in the Hail Mary's nose, small enough for the
	# trip home.
	"beetle": {
		"id": "beetle", "name": "Beetle probe", "role": "interstellar", "launchFrom": null,
		"era": "Project Hail Mary",
		"blurb": "A one-way courier: no crew, no life support, and a mass ratio the Hail Mary itself cannot reach. It is the only part of the mission that was always going to make it home.",
		"limits": { "maxQ": 1e9, "maxG": 20.0, "qAlpha": 1e9, "heatLoad": 0.0 },
		"stages": [
			stage({ "key": "beetle", "name": "Beetle", "dry": 850.0, "prop": 20000.0,
				"engine": E.BEETLE_DRIVE, "count": 1, "L": 4.2, "D": 2.4, "sep": "none",
				"rcs": { "thrust": 40.0, "isp": 240.0, "prop": 30.0, "count": 8 },
				"look": { "skin": "panel-white", "beetle": true } }),
		],
	},
	}

const VEHICLE_ORDER := [
	"saturnv", "falcon9", "shuttle", "starship", "lm", "skycrane",
	"ioncruiser", "hailmary", "beetle",
]

# Ideal Δv of one stage, carrying everything above it. Derived, never stored. `pa`
# selects sea level or vacuum.
static func stage_delta_v(vehicle: Dictionary, index: int, pa: float = 0.0, extra_payload: float = 0.0) -> float:
	var st: Array = vehicle.stages
	var above := extra_payload
	for i in range(index + 1, st.size()):
		above += st[i].dry + st[i].prop
	var s: Dictionary = st[index]
	if s.get("engine") == null or s.prop <= 0.0: return 0.0
	# Parallel boosters burn alongside the stage above them, so their propellant
	# is not available to it; serial stages carry theirs whole.
	var m0: float = s.dry + s.prop + above
	var m1: float = s.dry + above + (s.prop * s.reserve if s.get("reserve", 0.0) else 0.0)
	var ve := Rocketry.G0 * Rocketry.isp_at(s.engine, pa)
	return ve * log(m0 / maxf(m1, 1.0))

static func total_delta_v(vehicle: Dictionary, extra_payload: float = 0.0) -> float:
	# First stage at sea level, the rest in vacuum: the usual quoted figure, within a
	# few percent of an integrated ascent.
	var a := 0.0
	for i in vehicle.stages.size():
		a += stage_delta_v(vehicle, i, 101325.0 * 0.4 if i == 0 else 0.0, extra_payload)
	return a

static func gross_mass(vehicle: Dictionary, extra_payload: float = 0.0) -> float:
	var a := extra_payload
	for s in vehicle.stages:
		a += s.dry + s.prop
	return a

## Pad thrust-to-weight (real launchers sit at 1.2–1.5).
static func pad_twr(vehicle: Dictionary, g_surf: float = 9.80665, extra_payload: float = 0.0, pa: float = 101325.0) -> float:
	return liftoff_thrust(vehicle, pa) / (gross_mass(vehicle, extra_payload) * g_surf)

## Sea-level thrust of everything lit at T-0. The launch check won't release below
## TWR 1.0.
static func liftoff_thrust(vehicle: Dictionary, pa: float = 101325.0) -> float:
	var F := 0.0
	var st: Array = vehicle.stages
	for i in st.size():
		var s: Dictionary = st[i]
		if s.get("engine") == null or not (i == 0 or s.get("liftoff", false)): continue
		# Through engine_output, which owns the pressure and grain terms (an RSRM starts at
		# 0.86 of its rating).
		F += Rocketry.engine_output(s.engine, s.count, pa, 1.0, 0.0).F
	return F

## A vehicle Dictionary by id (null if unknown).
static func get_vehicle(key: String):
	return VEHICLES.get(key)
