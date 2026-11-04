extends SceneTree

# The Observatory's sky on a date (sim/observatory/, docs/physics/observatory.md):
#   Godot --headless --path . --script res://tools/observatorycheck.gd
# Earth-orientation angles against the IAU SOFA test vectors, ΔT and its badges,
# Polaris at each site's latitude, the solstice noon Sun, a bright star's rise and
# transit against published times, the orrery's bodies against JPL Horizons, and Earth's
# composed orientation, the sites' offsets and the topocentric Moon against IAU SOFA.

const DEG := 180.0 / PI
const AS := PI / 648000.0

var checks := 0
var failures := 0

func check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		printerr("OBSERVATORYCHECK FAIL ", what)

## The orrery's bodies where the Observatory puts them at TT `tt` (main.restate_solar).
func solar_at(tt: float) -> Dictionary:
	var out := {}
	var at := Observatory.solar_state(tt)
	for n in at: out[n] = at[n][0]
	return out

## GCRS unit vector from the site to body `n` (AU positions in orrery axes).
func toward(bodies: Dictionary, n: String, s: Dictionary) -> DVec3:
	var site_au: DVec3 = s.offset.scaled(1.0 / Rocketry.AU_M)
	var rel: DVec3 = EarthFrame.from_scene(bodies[n].sub(bodies.Earth)).sub(site_au)
	return rel.normalized()

func _init() -> void:
	angles()
	delta_t()
	polaris()
	solstices()
	rise_transit()
	horizons()
	terrain()
	facilities()
	orientation()
	print("OBSERVATORYCHECK DONE checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)

# The IAU SOFA library's own test cases (t_sofa_c.c, release 2023-10-11): the same
# dates and expected values its iauObl06, iauPfw06, iauNut00b, iauEra00 and iauGmst06
# tests use, so a transcription error in a series shows here.
func angles() -> void:
	var t := (2400000.5 + 54388.0 - EarthFrame.J2000) / 36525.0
	check(absf(EarthFrame.obliquity(t) - 0.4090749229387258204) < 1e-14, "IAU 2006 obliquity")
	check(absf(EarthFrame.era_angle(2400000.5 + 54388.0) - 0.4022837240028158102) < 1e-12, "Earth rotation angle")
	var tg := (2400000.5 + 53736.0 - EarthFrame.J2000) / 36525.0
	var nut := EarthFrame.nutation(tg)
	check(absf(nut[0] - -0.9632552291148362783e-5) < 1e-13 and absf(nut[1] - 0.4063197106621159367e-4) < 1e-13,
		"IAU 2000B nutation: Δψ %s Δε %s" % [String.num_scientific(nut[0]), String.num_scientific(nut[1])])
	var gmst := EarthFrame.gast(2400000.5 + 53736.0, tg, PackedFloat64Array([0.0, 0.0])) \
		- (0.00264096 * sin(fmod(450160.398036 - 6962890.5431 * tg, EarthFrame.TURNAS) * AS) \
		+ 0.00006352 * sin(2.0 * fmod(450160.398036 - 6962890.5431 * tg, EarthFrame.TURNAS) * AS)) * AS
	check(absf(gmst - 1.754174971870091203) < 1e-12, "IAU 2006 GMST %.15f" % gmst)
	var fw := EarthFrame.fw_angles((2400000.5 + 50123.9999 - EarthFrame.J2000) / 36525.0)
	check(absf(fw[0] - -0.2243387670997995690e-5) < 1e-16 and absf(fw[1] - 0.4091014602391312808) < 1e-12
		and absf(fw[2] - -0.9501954178013031895e-3) < 1e-14, "IAU 2006 Fukushima–Williams angles %s" % fw)

func delta_t() -> void:
	var last: float = DeltaT.TABLE[-1][0]
	# Continuous where the table hands over to the polynomials.
	check(absf(EarthFrame.delta_t(last - 1e-6) - EarthFrame.delta_t(last + 1e-6)) < 1e-3, "ΔT continuous at the table's end")
	var first: float = DeltaT.TABLE[0][0]
	check(absf(EarthFrame.delta_t(first - 1e-6) - EarthFrame.delta_t(first + 1e-6)) < 1e-3, "ΔT continuous at the table's start")
	check(EarthFrame.era(1950.0) == "measured" and EarthFrame.era(last + 1.0) == "extrapolated"
		and EarthFrame.era(2126.99) != "outside"
		and EarthFrame.era(1925.99) == "outside" and EarthFrame.era(2127.0) == "outside", "the date range's badges")
	# Huber's walk reproduces NASA's uncertainty table (Espenak & Meeus), calibrated at
	# 2005: 612 s in 2500 and 1885 s in 3000; and at −500: 622 s in −1000.
	check(absf(EarthFrame.huber_sigma(495.0) - 612.0) < 2.0 and absf(EarthFrame.huber_sigma(995.0) - 1885.0) < 6.0
		and absf(EarthFrame.delta_t_sigma(-1000.0) - 622.0) < 2.0,
		"Huber's ΔT walk: %.0f s at 495 yr, %.0f s at 995 yr" % [EarthFrame.huber_sigma(495.0), EarthFrame.huber_sigma(995.0)])
	check(EarthFrame.delta_t_sigma(1950.0) < 0.1 and EarthFrame.delta_t_sigma(2126.0) > 30.0 and EarthFrame.delta_t_sigma(2126.0) < 80.0,
		"ΔT σ 1950: %.3f s, 2126: %.0f s" % [EarthFrame.delta_t_sigma(1950.0), EarthFrame.delta_t_sigma(2126.0)])
	# The measured values as the USNO's tables give them: 1926.000 23.95 s
	# (historic_deltat.data), 2000 January 1 63.8285 s (deltat.data).
	check(absf(EarthFrame.delta_t(1926.0) - 23.95) < 1e-3 and absf(EarthFrame.delta_t(2000.0) - 63.8285) < 2e-3,
		"measured ΔT 1926.0 %.2f s, 2000.0 %.3f s" % [EarthFrame.delta_t(1926.0), EarthFrame.delta_t(2000.0)])
	# Civil time round-trips through TT, in both the UTC and the UT1 eras.
	for jd in [Observatory.julian_day(1926, 1, 1), 2441317.5 + 0.3, Observatory.julian_day(2026, 11, 3) + 0.25, Observatory.julian_day(2126, 1, 1)]:
		check(absf(EarthFrame.civil_of_tt(EarthFrame.tt_of_civil(jd)) - jd) * 86400.0 < 1e-3, "civil ↔ TT at JD %.2f" % jd)
	print("OBSERVATORYCHECK ΔT 1926.0 %.2f s, 2000.0 %.2f s, %.1f (table end) %.2f s, 2126.0 %.1f ± %.0f s" % [
		EarthFrame.delta_t(1926.0), EarthFrame.delta_t(2000.0), last, EarthFrame.delta_t(last),
		EarthFrame.delta_t(2126.0), EarthFrame.delta_t_sigma(2126.0)])

# Polaris (HIP 11767; Hipparcos 2007: RA 02h31m49.09s, Dec +89°15′50.8″, μα cos δ
# 44.48, μδ −11.85 mas/yr) circles the pole once a sidereal day, so the middle of its
# daily altitude range is the site's latitude, and half the range its polar distance.
func polaris() -> void:
	var ra := deg_to_rad((2.0 + 31.0 / 60.0 + 49.09 / 3600.0) * 15.0)
	var dec := deg_to_rad(89.0 + 15.0 / 60.0 + 50.8 / 3600.0)
	for key in ObservatorySites.ORDER:
		var site: Dictionary = ObservatorySites.SITES[key]
		for jd0 in [Observatory.julian_day(1926, 1, 1), Observatory.julian_day(2026, 11, 3), Observatory.julian_day(2126, 1, 1)]:
			var tt := EarthFrame.tt_of_civil(jd0)
			var p := EarthFrame.proper_motion(ra, dec, 44.48, -11.85, 2000.0, EarthFrame.year_of(tt))
			var lo := INF
			var hi := -INF
			for i in 96:
				var s := EarthFrame.site(tt + float(i) / 96.0, deg_to_rad(site.lat), deg_to_rad(site.lon), site.h)
				var alt := EarthFrame.altitude(s, p) * DEG
				lo = minf(lo, alt); hi = maxf(hi, alt)
			var mid := (lo + hi) * 0.5
			# The geodetic vertical is the latitude's; sampling every 15 min of a 0.4–1.1°
			# circle leaves under 0.005° in the middle.
			check(absf(mid - float(site.lat)) < 0.01, "%s %s: Polaris mid-altitude %.4f° vs latitude %.4f°" % [key, TimeScales.stamp(jd0, false), mid, site.lat])
			check((hi - lo) * 0.5 > 0.35 and (hi - lo) * 0.5 < 1.2, "%s: Polaris's polar distance %.3f°" % [key, (hi - lo) * 0.5])
			if key == "jodrell":
				print("OBSERVATORYCHECK Polaris %s at Jodrell Bank: %.3f°..%.3f° (latitude %.3f°)" % [TimeScales.stamp(jd0, false), lo, hi, site.lat])

# The noon Sun at the solstices: its highest altitude in the day is 90° − |φ − δ☉|,
# with δ☉ = ±ε, the obliquity of date (the solstice instant is not noon, but δ☉ moves
# under 1″ in the half day around it). Geometric, without refraction.
func solstices() -> void:
	# Solstices (UTC) from the USNO's "Earth's Seasons" table (aa.usno.navy.mil, Data
	# Services, Seasons): 2026 June 21 08:24, 2026 December 21 20:50.
	var cases := [[2461212.5 + (8.0 + 24.0 / 60.0) / 24.0, 1.0], [2461395.5 + (20.0 + 50.0 / 60.0) / 24.0, -1.0]]
	for c in cases:
		var tt := EarthFrame.tt_of_civil(float(c[0]))
		var eps := EarthFrame.obliquity((tt - EarthFrame.J2000) / 36525.0) * DEG
		for key in ObservatorySites.ORDER:
			var site: Dictionary = ObservatorySites.SITES[key]
			var best := -INF
			for i in 721:
				var t := tt - 0.5 + float(i) / 720.0
				var s := EarthFrame.site(t, deg_to_rad(site.lat), deg_to_rad(site.lon), site.h)
				best = maxf(best, EarthFrame.altitude(s, toward(solar_at(t), "Sun", s)) * DEG)
			var want := 90.0 - absf(float(site.lat) - float(c[1]) * eps)
			check(absf(best - want) < 0.02, "%s solstice %s: noon Sun %.3f° vs %.3f°" % [key, TimeScales.stamp(float(c[0]), false), best, want])
			print("OBSERVATORYCHECK %s solstice %s: noon Sun %.3f° (90° − |φ − δ| = %.3f°)" % [key, TimeScales.stamp(float(c[0]), false), best, want])

# Sirius (HR 2491, BSC5's place and motion as bsc5.bin holds them), its UTC (UT1 before
# 1972) rise, transit and set on a civil day at each site, against:
# - 1926 Jan 1 and 2050 Dec 31: the USNO's "Rise/Set/Transit Times for Major Solar
#   System Objects and Bright Stars" (aa.usno.navy.mil/data/mrst, 1800–2050), queried
#   2026 November 3 at the sites' coordinates; printed to the minute.
# - 2126 Jan 1: IAU SOFA through pyerfa (tools/observatory_ref.py), with this ΔT, since
#   the USNO stops at 2050 and any ΔT for 2126 is a forecast.
# Rise and set at a geometric altitude of −34′ (standard refraction; the USNO applies
# no dip for height). Annual aberration (≤ 20″, ≤ 2 s) is not applied here.
const SIRIUS := [101.28710174560547, -16.716100692749023, -553.0, -1205.0]
const EVENTS := [
	["paranal", 1926, 1, 1, [22.0 + 6.0 / 60.0, 4.0 + 43.0 / 60.0, 11.0 + 16.0 / 60.0], 0.75, "USNO"],
	["jodrell", 1926, 1, 1, [19.0 + 38.0 / 60.0, 0.0 + 12.0 / 60.0, 4.0 + 41.0 / 60.0], 0.75, "USNO"],
	["maunakea", 1926, 1, 1, [4.0 + 46.0 / 60.0, 10.0 + 23.0 / 60.0, 15.0 + 59.0 / 60.0], 0.75, "USNO"],
	["paranal", 2050, 12, 31, [22.0 + 12.0 / 60.0, 4.0 + 50.0 / 60.0, 11.0 + 23.0 / 60.0], 1.0, "USNO"],
	["jodrell", 2050, 12, 31, [19.0 + 46.0 / 60.0, 0.0 + 18.0 / 60.0, 4.0 + 46.0 / 60.0], 1.0, "USNO"],
	["maunakea", 2050, 12, 31, [4.0 + 52.0 / 60.0, 10.0 + 29.0 / 60.0, 16.0 + 6.0 / 60.0], 1.0, "USNO"],
	["paranal", 2126, 1, 1, [22.22748, 4.85292, 11.41282], 0.05, "SOFA"],
	["jodrell", 2126, 1, 1, [19.80063, 0.32545, 4.78475], 0.05, "SOFA"],
	["maunakea", 2126, 1, 1, [4.90131, 10.50873, 16.11614], 0.05, "SOFA"],
]

## [altitude + 34′ (°), hour angle (°, −180..180)] of Sirius at civil Julian date `jd`.
func sirius(jd: float, site: Dictionary) -> PackedFloat64Array:
	var tt := EarthFrame.tt_of_civil(jd)
	var s := EarthFrame.site(tt, deg_to_rad(site.lat), deg_to_rad(site.lon), site.h)
	var d := EarthFrame.proper_motion(deg_to_rad(SIRIUS[0]), deg_to_rad(SIRIUS[1]), SIRIUS[2], SIRIUS[3], 2000.0, EarthFrame.year_of(tt))
	var tru := EarthFrame.apply(s.npb, d)
	var ha := rad_to_deg(angle_difference(atan2(tru.y, tru.x), float(s.last)))
	return PackedFloat64Array([EarthFrame.altitude(s, d) * DEG + 34.0 / 60.0, ha])

## The hour (0–24, civil) on day `jd0` where component `k` of sirius() rises through 0.
func crossing(jd0: float, site: Dictionary, k: int, up: bool) -> float:
	var step := 5.0 / 1440.0
	var prev := sirius(jd0, site)[k]
	for i in 288:
		var a := jd0 + float(i) * step
		var b := a + step
		var vb := sirius(b, site)[k]
		if (prev < 0.0 and vb >= 0.0 and up) or (prev >= 0.0 and vb < 0.0 and not up):
			if k == 0 or absf(vb - prev) < 90.0:
				for j in 40:
					var m := 0.5 * (a + b)
					var vm := sirius(m, site)[k]
					if (vm >= 0.0) == up: b = m
					else: a = m
				return (0.5 * (a + b) - jd0) * 24.0
		prev = vb
	return NAN

func rise_transit() -> void:
	for e in EVENTS:
		var site: Dictionary = ObservatorySites.SITES[e[0]]
		var jd0 := Observatory.julian_day(e[1], e[2], e[3])
		# Hour angle rises through 0 at transit (it increases with time).
		var got := [crossing(jd0, site, 0, true), crossing(jd0, site, 1, true), crossing(jd0, site, 0, false)]
		var want: Array = e[4]
		var worst := 0.0
		for i in 3: worst = maxf(worst, absf(float(got[i]) - float(want[i])) * 60.0)
		var ok := is_finite(worst) and worst <= float(e[5])
		check(ok, "Sirius at %s %d-%02d-%02d: rise %s transit %s set %s vs %s %s (worst %.2f min)" % [
			e[0], e[1], e[2], e[3], _hm(got[0]), _hm(got[1]), _hm(got[2]), e[6], [_hm(want[0]), _hm(want[1]), _hm(want[2])], worst])
		print("OBSERVATORYCHECK Sirius %s %d-%02d-%02d rise %s transit %s set %s; %s %s %s %s; worst %.2f min" % [
			e[0], e[1], e[2], e[3], _hm(got[0]), _hm(got[1]), _hm(got[2]), e[6], _hm(want[0]), _hm(want[1]), _hm(want[2]), worst])

static func _hm(h: float) -> String:
	if not is_finite(h): return "—"
	var s := int(roundf(h * 3600.0))
	return "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]

# The orrery's geocentric Sun, Moon and planets where the Observatory puts them, against
# JPL Horizons (DE441; geometric, geocentric, ICRF, AU), queried 2026 November 3 at
# 0h TDB 1926 Jan 1, 12h TDB 2000 Jan 1 and 0h TDB 2126 Jan 1. Each limit is the
# measured error rounded up, so a regression fails; docs/physics/observatory.md lists them.
const HORIZONS := {
	"Sun": [[2424516.5, 1.853573748860275E-01, -8.858443300108426E-01, -3.842364787291954E-01], [2451545, 1.771350992727098E-01, -8.874285223255191E-01, -3.847428990882070E-01], [2497565.5, 1.459428150208845E-01, -8.923611792688715E-01, -3.865852596896310E-01]],
	"Moon": [[2424516.5, -1.426909589724154E-03, 2.101662210269386E-03, 9.367056647780456E-04], [2451545, -1.949281649686695E-03, -1.782891912873099E-03, -5.087137066222156E-04], [2497565.5, 2.699755789503044E-03, -7.570593347943242E-05, 8.841159127910920E-05]],
	"Mercury": [[2424516.5, -2.076713125375172E-01, -9.369281290230790E-01, -3.706716765929445E-01], [2451545, 4.704149389725756E-02, -1.288022243967845E+00, -5.852322011049330E-01], [2497565.5, 2.935524425617841E-01, -1.260037592454776E+00, -5.983166495551200E-01]],
	"Venus": [[2424516.5, 3.330372293217612E-01, -2.393250200913858E-01, -1.028947118944733E-01], [2451545, -5.411671970726792E-01, -9.337027690276324E-01, -3.601022606327784E-01], [2497565.5, -1.292633394285806E-01, -2.936258753770036E-01, -9.958353103507568E-02]],
	"Mars": [[2424516.5, -9.891731196614916E-01, -1.845178187273845E+00, -7.922630050186880E-01], [2451545, 1.567851021019061E+00, -8.860273046975010E-01, -4.217030662836571E-01], [2497565.5, 1.527136272090619E+00, -9.921015061483541E-01, -4.692652685975481E-01]],
	"Jupiter": [[2424516.5, 3.006055821650757E+00, -4.781538137527794E+00, -2.123142978886325E+00], [2451545, 4.178312534862136E+00, 1.849149906689260E+00, 6.907692464036385E-01], [2497565.5, -1.398439379304754E+00, -5.591493911765510E+00, -2.362845588494708E+00]],
	"Saturn": [[2424516.5, -6.215703180018659E+00, -7.959441984175106E+00, -3.029957842923313E+00], [2451545, 6.583545527651366E+00, 5.287228021380708E+00, 1.890027837059550E+00], [2497565.5, -8.338879516054124E+00, 2.456946580657223E+00, 1.364417911505181E+00]],
	"Uranus": [[2424516.5, 2.022197490968449E+01, -2.174100812443737E+00, -1.232567094065370E+00], [2451545, 1.460899037519676E+01, -1.339369652354772E+01, -6.066433800400348E+00], [2497565.5, -1.167273723603491E+01, 1.206851239049276E+01, 5.456705687621471E+00]],
	"Neptune": [[2424516.5, -2.422707417169193E+01, 1.519527496883321E+01, 6.805418244783888E+00], [2451545, 1.698918270511707E+01, -2.386752921506716E+01, -1.020917103509665E+01], [2497565.5, -2.302243722795578E+01, -1.921615293032717E+01, -7.309756158720082E+00]],
	"Pluto": [[2424516.5, -1.052143216987596E+01, 3.708739047707279E+01, 1.468873241853162E+01], [2451545, -9.698212159308254E+00, -2.886629024956224E+01, -6.138422595053962E+00], [2497565.5, 2.648180331419679E+01, 4.015613384878310E+01, 4.487462266774175E+00]],
}
const LIMIT_DEG := {"Sun": 0.005, "Moon": 0.03, "Mercury": 0.005, "Venus": 0.005, "Mars": 0.005,
	"Jupiter": 0.2, "Saturn": 0.5, "Uranus": 0.2, "Neptune": 0.04, "Pluto": 0.03}

func horizons() -> void:
	for n in HORIZONS:
		var line := "OBSERVATORYCHECK Horizons %s" % n
		for row: Array in HORIZONS[n]:
			var tt := EarthFrame.tt_of_tdb(float(row[0]))
			var at := solar_at(tt)
			var g := EarthFrame.from_scene(at[n].sub(at.Earth))
			var h := DVec3.new(float(row[1]), float(row[2]), float(row[3]))
			var ang := acos(clampf(g.normalized().dot(h.normalized()), -1.0, 1.0)) * DEG
			var dr := g.length() / h.length() - 1.0
			check(ang < float(LIMIT_DEG[n]) and absf(dr) < 2e-3, "%s %s: %.4f° and %+.5f in distance from Horizons" % [n, TimeScales.stamp(float(row[0]), false), ang, dr])
			line += "  %s %.4f° %+.5f" % [TimeScales.stamp(float(row[0]), false).left(4), ang, dr]
		print(line)

# The packed Copernicus tiles against places a wrong axis or datum would miss: Armazones
# (3046 m, 24.589° S, 70.192° W) is 21.6 km east and 4.3 km north of Paranal's datum;
# Mauna Kea's summit (4207 m) 0.6 km south and 0.7 km east of Keck's; Hilo Bay's sea
# 34 km east and 11 km north of it; the Atacama's Pacific 12 km west of Paranal at most.
func terrain() -> void:
	var par := SiteScene.read_grids("paranal")
	var kea := SiteScene.read_grids("maunakea")
	var jod := SiteScene.read_grids("jodrell")
	check(par.size() == 2 and kea.size() == 2 and jod.size() == 2, "each site has two terrain grids")
	var arm := 0.0
	for de in range(-1500, 1501, 300):
		for dn in range(-1500, 1501, 300):
			arm = maxf(arm, SiteScene.sample(par, 21600.0 + de, 4300.0 + dn))
	# The far grid's 320 m cells take the top off a peak.
	check(absf(arm - 3046.0) < 80.0, "Armazones in the Paranal tile: %.0f m" % arm)
	check(absf(SiteScene.sample(par, 0.0, 0.0) - 2635.43) < 6.0, "Paranal's datum: %.1f m vs ESO's 2635.43 m" % SiteScene.sample(par, 0.0, 0.0))
	check(absf(SiteScene.sample(kea, 660.0, -630.0) - 4207.0) < 25.0, "Mauna Kea's summit: %.0f m" % SiteScene.sample(kea, 660.0, -630.0))
	check(SiteScene.sample(kea, 34000.0, 11000.0) < 5.0 and SiteScene.sample(kea, 0.0, 0.0) > 4000.0, "sea off Hilo in the Mauna Kea tile")
	check(SiteScene.sample(par, -25000.0, 0.0) < 5.0 and SiteScene.sample(par, 25000.0, 0.0) > 1000.0, "the Pacific lies west of Paranal")
	var j: float = SiteScene.sample(jod, 0.0, 0.0)
	check(j > 60.0 and j < 110.0, "Jodrell Bank's ground: %.1f m" % j)
	print("OBSERVATORYCHECK terrain: Armazones %.0f m, Paranal %.1f m, Mauna Kea %.0f m, Jodrell Bank %.1f m" % [arm, SiteScene.sample(par, 0.0, 0.0), SiteScene.sample(kea, 660.0, -630.0), j])

## Top of a structure's meshes above its datum, with any el pivot at the horizon.
func top_of(n: Node, xf: Transform3D) -> float:
	var top := -INF
	var t := xf * ((n as Node3D).transform if n is Node3D else Transform3D.IDENTITY)
	if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
		var ab: AABB = (n as MeshInstance3D).mesh.get_aabb()
		for i in 8: top = maxf(top, (t * ab.get_endpoint(i)).y)
	for c in n.get_children(): top = maxf(top, top_of(c, t))
	return top

# Published separations from the table, and each structure's height in both builds: the
# authored library when it has been built, the fallback blocks always.
func facilities() -> void:
	var sep := func(site: String, a: int, b: int) -> float:
		var p: Array = Facilities.DATA[site].parts
		return Vector2(float(p[a].e) - float(p[b].e), float(p[a].n) - float(p[b].n)).length()
	check(absf(sep.call("maunakea", 0, 1) - 85.0) < 1.5, "Keck I–II: %.1f m vs the published 85 m" % sep.call("maunakea", 0, 1))
	check(absf(sep.call("jodrell", 0, 1) - 425.0) < 1.0, "Lovell–Mark II: %.1f m vs the published 425 m" % sep.call("jodrell", 0, 1))
	check(absf(sep.call("paranal", 1, 4) - 130.0) < 1.0, "UT1–UT4: %.1f m vs the published 130 m" % sep.call("paranal", 1, 4))
	for site in Facilities.DATA:
		for p: Dictionary in Facilities.DATA[site].parts:
			check(SiteFallback.HEIGHTS.has(p.stage), "%s: %s has a height" % [site, p.stage])
	var lib: Node = null
	if ResourceLoader.exists(SiteScene.LIBRARY):
		lib = (load(SiteScene.LIBRARY) as PackedScene).instantiate()
	# assets=1 is the authored gate: it cannot pass by substituting the fallback.
	var authored_required := OS.get_cmdline_user_args().has("assets=1")
	check(lib != null or not authored_required, "the authored library is built (assets=1)")
	# A telescope told to point somewhere points there, in the frame's axes: x west, y up, z north.
	for stage: String in ["lovell", "keck", "ut"]:
		# The fallback's blocks only carry the Lovell's elevation; its enclosures have no telescope.
		var builds := [SiteFallback.build(stage)]
		if lib != null and lib.find_child("stage_" + stage, true, false) != null:
			builds.append(lib.find_child("stage_" + stage, true, false).duplicate())
		for k in builds.size():
			var node: Node3D = builds[k]
			node.transform = Transform3D(Basis(Vector3.UP, 0.4), Vector3.ZERO)
			SiteScene.aim_pose(node, stage, {}, 130.0, 40.0)
			var el := node.find_child("door_%s_el" % stage, true, false) as Node3D
			check(el != null or (k == 0 and stage != "lovell"), "%s has an elevation pivot" % stage)
			if el != null:
				var b := Basis()
				var n: Node = el
				while n != null and n is Node3D:
					b = (n as Node3D).transform.basis * b
					if n == node: break
					n = n.get_parent()
				var want := Vector3(-sin(deg_to_rad(130.0)) * cos(deg_to_rad(40.0)), sin(deg_to_rad(40.0)), cos(deg_to_rad(130.0)) * cos(deg_to_rad(40.0)))
				check((b * Vector3.UP).dot(want) > 0.9999, "%s aims where it is told: %s against %s" % [stage, b * Vector3.UP, want])
			node.free()
	for stage: String in SiteFallback.HEIGHTS:
		var want: float = SiteFallback.HEIGHTS[stage]
		var builds := [["fallback", SiteFallback.build(stage)]]
		if lib != null:
			var src := lib.find_child("stage_" + stage, true, false)
			check(src != null, "%s is in the authored library" % stage)
			if src != null: builds.append(["authored", src.duplicate()])
		for b: Array in builds:
			var node: Node3D = b[1]
			node.transform = Transform3D.IDENTITY
			var el := node.find_child("door_%s_el" % stage, true, false) as Node3D
			if el != null and stage in ["lovell", "mark2"]: el.rotation.x = PI * 0.5
			var top := top_of(node, Transform3D.IDENTITY)
			# The authored build has rails and shutters proud of the nominal shell.
			check(absf(top - want) < maxf(0.06 * want, 0.8), "%s %s: top %.1f m vs %.1f m" % [b[0], stage, top, want])
			print("OBSERVATORYCHECK %s %s: top %.1f m (nominal %.1f m)" % [b[0], stage, top, want])
			node.free()
	if lib != null:
		for piv: String in ["door_lovell_az", "door_lovell_el", "door_keck_dome", "door_keck_shutter_l", "door_keck_shutter_r",
				"door_keck_el", "door_ut_dome", "door_ut_door_l", "door_ut_door_r", "door_ut_az", "door_ut_el", "door_mark2_el"]:
			check(lib.find_child(piv, true, false) != null, "pivot %s is in the authored library" % piv)
		lib.free()
		print("OBSERVATORYCHECK authored library: %d stages" % SiteFallback.HEIGHTS.size())
	else:
		print("OBSERVATORYCHECK authored library not built: fallback only")

# tools/observatory_ref.py: IAU SOFA's composed matrix (eraPfw06, eraNut00b, eraFw2m) and
# the sites' GCRS offsets (m) through eraGd2gc and eraGst06, at the Horizons dates.
const ORIENTATION := [
	[2424516.5, [0.9998360008150324, 0.016608539797000846, 0.007219963989797387, -0.016608701160041497, 0.9998620653025707, -3.761189137568698e-05, -0.007219592784843757, -8.230850123658437e-05, 0.999973935012974],
		{"jodrell": [-597670.305, 3783927.266, 5082514.508], "maunakea": [3452109.968, -4904286.465, 2175608.351], "paranal": [5028128.286, 2931305.403, -2606258.25]}],
	[2451545.0, [0.999999997721214, 6.189835627598374e-05, 2.6947459869646315e-05, -6.189911088782092e-05, 0.9999999976921621, 2.80031452829974e-05, -2.6945726458792363e-05, -2.8004813242940276e-05, 0.9999999992448292],
		{"jodrell": [524810.151, -3789651.89, 5086293.536], "maunakea": [-3420990.934, 4936804.912, 2151078.555], "paranal": [-5036757.531, -2883244.899, -2642949.093]}],
	[2497565.5, [0.999526664630042, -0.028218502152065516, -0.012254094411153592, 0.028219017421702648, 0.9996017556625868, -0.00013088937198131313, 0.01225290778946916, -0.00021497108626354608, 0.9999249071996031],
		{"jodrell": [-329639.536, 3804466.347, 5091624.756], "maunakea": [3272158.426, -5054027.45, 2110011.002], "paranal": [5101892.835, 2705843.864, -2704867.088]}],
]

func orientation() -> void:
	var moons: Array = HORIZONS.Moon
	for r in ORIENTATION.size():
		var row: Array = ORIENTATION[r]
		var tt := EarthFrame.tt_of_tdb(float(row[0]))
		var worst_m := 0.0
		var m := EarthFrame.npb((tt - EarthFrame.J2000) / 36525.0, EarthFrame.nutation((tt - EarthFrame.J2000) / 36525.0))
		for i in 9: worst_m = maxf(worst_m, absf(m[i] - float(row[1][i])))
		# IAU 2000B is the same series on both sides, so only rounding is left.
		check(worst_m < 1e-12, "composed NPB at JD %.1f: worst element off by %s" % [row[0], String.num_scientific(worst_m)])
		var line := "OBSERVATORYCHECK SOFA JD %.1f: NPB %s" % [row[0], String.num_scientific(worst_m)]
		var geo := DVec3.new(float(moons[r][1]), float(moons[r][2]), float(moons[r][3]))
		for key in row[2]:
			var site: Dictionary = ObservatorySites.SITES[key]
			var s := EarthFrame.site(tt, deg_to_rad(site.lat), deg_to_rad(site.lon), site.h)
			var want := DVec3.new(float(row[2][key][0]), float(row[2][key][1]), float(row[2][key][2]))
			# 0.1 m is 3 mas of turn, about the complementary terms the two paths treat differently.
			var off: float = s.offset.distance_to(want)
			check(off < 0.1, "%s offset at JD %.1f: %.3f m from SOFA" % [key, row[0], off])
			# The topocentric Moon: Horizons' geocentric place less SOFA's site, and the
			# parallax that subtraction makes against the orrery's own.
			var topo := geo.sub(want.scaled(1.0 / Rocketry.AU_M))
			var ours := toward(solar_at(tt), "Moon", s)
			var ours_geo: DVec3 = EarthFrame.from_scene(solar_at(tt).Moon.sub(solar_at(tt).Earth))
			var along := acos(clampf(ours.dot(topo.normalized()), -1.0, 1.0)) * DEG
			var par_want := acos(clampf(topo.normalized().dot(geo.normalized()), -1.0, 1.0)) * DEG
			var par_got := acos(clampf(ours.dot(ours_geo.normalized()), -1.0, 1.0)) * DEG
			check(along < float(LIMIT_DEG.Moon), "%s topocentric Moon at JD %.1f: %.4f° from Horizons with SOFA's site" % [key, row[0], along])
			check(absf(par_got - par_want) < 2e-3, "%s Moon's parallax at JD %.1f: %.4f° vs %.4f°" % [key, row[0], par_got, par_want])
			line += "  %s %.3f m, Moon %.4f°, parallax %.4f° (%.4f°)" % [key, off, along, par_got, par_want]
		print(line)
	# The offset from a geodetic site to Earth's centre has no east part, and leans north or
	# south of the zenith by a·e²·sin φ·cos φ/√(1 − e² sin² φ) whatever the height.
	var fig: Dictionary = Rocketry.FIGURES.Earth
	var e2: float = float(fig.f) * (2.0 - float(fig.f))
	for key in ObservatorySites.ORDER:
		var site: Dictionary = ObservatorySites.SITES[key]
		var phi := deg_to_rad(float(site.lat))
		var s := EarthFrame.site(EarthFrame.J2000, phi, deg_to_rad(float(site.lon)), site.h)
		var want := -float(fig.a) * e2 * sin(phi) * cos(phi) / sqrt(1.0 - e2 * sin(phi) * sin(phi))
		check(absf(s.offset.dot(s.north) - want) < 0.01 and absf(s.offset.dot(s.east)) < 0.01,
			"%s offset north %.2f m (want %.2f m), east %.2f m" % [key, s.offset.dot(s.north), want, s.offset.dot(s.east)])
		print("OBSERVATORYCHECK %s centre of Earth from the zenith: north %.1f km, east %.1f km" % [key, s.offset.dot(s.north) / 1000.0, s.offset.dot(s.east) / 1000.0])
