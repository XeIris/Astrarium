class_name VoyagerSpacecraft
extends RefCounted

# Inspection pivot in the scaled VTAD model (metres), orbit angles, distance (m).
const VIEWS := {
	"Full span": [Vector3(0, 1.8, 3), 0.52, -0.17, 29.25,
		"The lattice mast carries the low-field magnetometers clear of the bus. The two slender, perpendicular 10 m antennas sample plasma waves."],
	"Spacecraft bus": [Vector3(0, 0.6, 0), 0.52, -0.17, 14.56,
		"The ten-sided bus houses the electronics. The rectangular target below it gave the instruments a surface of known brightness for calibration."],
	"High-gain antenna": [Vector3(0, 1.4, 0), 0.7, 1.12, 7.2,
		"The 3.7 m high-gain reflector carries science and engineering data back to Earth. During normal communications, attitude-control thrusters keep the whole spacecraft pointed home."],
	"Science platform": [Vector3(0, 0.23, -3.3), 1.0, 0.16, 3.8,
		"The scan platform aimed the narrow- and wide-angle cameras, infrared spectrometer, ultraviolet spectrometer and photopolarimeter independently of the antenna."],
	"Radioisotope generators": [Vector3(0, -0.12, 3.4), -0.32, 0.23, 4.8,
		"Three finned generators sit end to end. Thermocouples convert heat from plutonium-238 into electricity, even where sunlight is too weak to power the instruments."],
	"Golden Record": [Vector3(0.92, 0, 0), 0.02, 0.02, 1.1,
		"Both probes carry a gold-plated copper record beneath an engraved aluminium cover. The diagrams give playback instructions, a pulsar map and a hydrogen time standard."],
}
