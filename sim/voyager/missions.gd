class_name VoyagerMissions
extends RefCounted

const PROBES := {"voyager1": "Voyager 1", "voyager2": "Voyager 2"}
const LIGHT_DAY := "2026-11-18T10:16:07"
const END := "2026-11-19T23:59:59"
# UTC, title, encounter body (for a moving local frame), mission context.
# Date-only records retain their published precision in the landmark picker.
const LOG := {
	"Voyager 1": [
		["1977-09-05T12:56:01", "Launch from Cape Canaveral", "", "A Titan IIIE–Centaur launched the second Voyager onto the faster route to Jupiter."],
		["1977-09-18", "Earth and Moon portrait", "", "Looking back from 11.7 million km, Voyager caught the crescent Earth and Moon together."],
		["1979-03-05T12:05:26", "Jupiter gravity assist", "Jupiter", "Jupiter bent the flight path toward Saturn. The encounter revealed a faint ring and resolved structure in the Great Red Spot."],
		["1979-03-05T15:13:21", "Io flyby", "Io", "Io’s mottled surface and volcanic plumes gave the first evidence of active volcanism beyond Earth."],
		["1980-11-12T05:41", "Titan flyby", "Titan", "Radio signals passed through Titan’s atmosphere. The measurements revealed dense air beneath the opaque haze."],
		["1980-11-12T23:46:30", "Saturn gravity assist", "Saturn", "The geometry chosen for Titan carried Voyager north out of the planetary plane after Saturn."],
		["1990-02-14T04:48", "Pale Blue Dot", "", "From about 40 AU, Voyager turned its cameras toward home. Earth occupied less than a pixel in the Solar System family portrait."],
		["1998-02-17", "Beyond Pioneer 10", "", "Voyager overtook Pioneer 10 in distance from the Sun, at about 69.4 AU."],
		["2004-12-16", "Termination shock", "", "At roughly 94 AU, the outward solar wind slowed abruptly. Voyager had entered the heliosheath."],
		["2012-08-25", "Heliopause crossing", "", "Changes in the particle environment marked the first spacecraft crossing into interstellar space."],
		[LIGHT_DAY, "One light-day from Earth", "", "A radio signal now needed a full day to cross the 25.902 billion km between Earth and Voyager 1."],
	],
	"Voyager 2": [
		["1977-08-20T14:29:44", "Launch from Cape Canaveral", "", "The first twin to leave Earth lifted off from Launch Complex 41 on a Titan IIIE–Centaur."],
		["1979-07-09T22:29:51", "Jupiter gravity assist", "Jupiter", "A wider passage than Voyager 1’s kept the outer-planet tour possible and gave a close look at Europa’s fractured ice."],
		["1981-08-26T03:24:57", "Saturn gravity assist", "Saturn", "Saturn redirected the spacecraft toward Uranus. The cameras resolved spokes in the rings and structure in the narrow F ring."],
		["1986-01-24T17:03", "Miranda encounter", "Miranda", "Near Miranda the cameras resolved giant cliffs, ridges and sharply bounded patches of icy terrain."],
		["1986-01-24T17:59:47", "Uranus gravity assist", "Uranus", "The first passage by Uranus revealed a tilted, off-centre magnetic field. Uranus redirected Voyager toward Neptune."],
		["1989-08-25T03:56:36", "Neptune gravity assist", "Neptune", "Voyager swept over the north pole, just under 5,000 km above the cloud tops. The encounter bent its path south of the ecliptic."],
		["1989-08-25T09:10", "Triton flyby", "Triton", "Hours after Neptune, Voyager passed its retrograde moon. Images revealed dark plumes rising over Triton’s icy south polar terrain."],
		["2007-08-30", "Termination shock", "", "Voyager sampled the shocked solar wind directly at about 84 AU, closer to the Sun than its twin’s crossing."],
		["2018-11-05", "Heliopause crossing", "", "The plasma instrument measured the disappearance of the solar wind as Voyager 2 entered interstellar space."],
	],
}

static func epoch(s: String) -> int:
	var iso := s if "T" in s else s + "T00:00:00"
	return Time.get_unix_time_from_datetime_string(iso + ":00" if iso.length() == 16 else iso)

static func hangar_info(key: String) -> Dictionary:
	var probe: String = PROBES[key]
	var route := "Jupiter · Saturn" if key == "voyager1" else "Jupiter · Saturn · Uranus · Neptune"
	return {"name": probe, "role": "Interstellar probe", "blurb": "A ten-sided electronics bus carries a steerable instrument platform and the Golden Record. Three radioisotope generators power the spacecraft.",
		"rows": [["Launched", str(LOG[probe][0][0]).left(10)], ["Dish diameter", "3.7 m"],
			["Science investigations", "11 at launch"], ["Planetary encounters", route]],
		"missions": [{"label": "Mission replay", "goal": "voyager", "dest": "", "ok": true,
			"brief": "Scrub the flight from launch, jump to an encounter, or inspect the deployed spacecraft beside NASA’s references."}]}
