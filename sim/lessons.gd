class_name Lessons
extends RefCounted

# ============================================================================
# THE COURSE
# ----------------------------------------------------------------------------
# A beginner's astronomy syllabus, written against the running simulation.
#
# WHERE THE SHAPE OF IT COMES FROM. The module order follows the standard
# introductory university sequence — OpenStax *Astronomy 2e*, which is the free
# text most first-year courses in the US now use: sky and seasons, gravity and
# orbits, light and spectra, the Sun, the stars, stellar death, black holes,
# galaxies, cosmology, other worlds. The individual lessons are chosen against
# the Nebraska Astronomy Applet Project's fifteen lab modules (seasons, lunar
# phases, planetary orbits, blackbody curves, the HR diagram, eclipsing
# binaries, extrasolar planets, the cosmic distance ladder, habitable zones) —
# that list is, in effect, a published answer to the question "which ideas in
# introductory astronomy are the ones that need a simulator rather than a
# paragraph?", and it is exactly the question this file is answering. The
# framing of what a non-specialist should come away with is the IAU's eleven
# Big Ideas in Astronomy.
#
# TWO RULES, BOTH LEARNED FROM THE EDUCATION RESEARCH RATHER THAN INVENTED:
#
#   · NAME THE MISCONCEPTION. The two best-documented wrong ideas in the
#     subject — that the seasons come from the Earth's distance to the Sun, and
#     that the Moon's phases are the Earth's shadow — are held by most adults
#     INCLUDING most graduates, and they are famously resistant: they survive
#     being told the right answer, because being told is not the same as
#     seeing the geometry move. The constructivist finding is that what
#     dislodges them is testing the wrong idea and watching it fail. So a
#     lesson with a known misconception says it out loud (`myth`), and the
#     scenario it opens is one where the wrong idea makes a prediction you can
#     check.
#
#   · THE SIMULATION IS THE ARGUMENT. Nothing here is scripted or animated.
#     Every lesson opens a real scenario, and every claim it makes is one the
#     integrator, the structure model or the shaders produce on their own. If a
#     lesson says two orbits have the same period, the way you find out is that
#     they keep meeting. That is also the honest limit of the format: where the
#     sim genuinely cannot show something — parallax, the expansion of the
#     universe, the nuclear binding energy curve — the lesson says so and draws
#     a diagram instead of pretending.
#
# SHAPE OF THE DATA. This module is DATA, not behaviour: no DOM, no THREE, no
# imports at all. A step's `do` block is a declarative request — load this
# scenario, focus that body, slow the clock, open that panel — which
# sim/lessonui.gd executes against a small stage API handed to it by the
# orchestrator. Anything the stage does not recognise is ignored rather than
# thrown, so a lesson can ask for something a future version will do.
#
# A NOTE ON `cam.radius`. Most steps do not give one, and that is deliberate:
# `focus` already frames the body at seven of its own radii, which is the right
# distance under BOTH size conventions. A hard-coded distance written while
# looking at the exaggerated view puts the camera inside the planet at true
# scale, and vice versa — the symptom is a screen of flat colour that looks
# like a broken shader. State a distance only when the framing is the point.
#
# THE `do` VOCABULARY
#   preset      scenario key (see sim/presets.gd and sim/edupresets.gd)
#   focus       body name to follow
#   cam         { radius, theta, phi, mode }  — mode: orbit | free | surface
#   band        imaging band index, 0–6 (see sim/spectrum.gd BANDS)
#   timeScale   simulated years per second
#   speed       the dimensionless multiplier on top of it
#   trueScale   true = real body radii, false = the readable exaggeration
#   sky         { env, tilt, roll } — override the scenario's own sky
#   control     { id: value } — set a slider by the id it has in the HUD
#   panel       { id: true|false } — open or collapse a HUD panel. A lesson
#               that opens the cross-section also collapses the course list
#               (`coursePanel: false`): they share the left column and at any
#               ordinary window height the second one lands off the bottom of
#               the screen. The course's own tab brings it straight back.
#   localTime   'dawn' | 'morning' | 'noon' | 'dusk' | 'midnight', or a
#               fraction of a day — turns the home world so the surface
#               observer is standing in that local time. Only meaningful in
#               the surface view, and the reason it exists is that without it
#               half of the surface lessons open at midnight.
#   paused      true | false
#   flare       body name — force an eruption
#   collapse    body name — trigger core collapse
#   instrument  photometer | gw | hr | cutaway  (also settable per step)
# ============================================================================
#
# THE PORT. This file is generated from sim/lessons.js and holds the same
# data as Dictionaries with the JS keys VERBATIM (camelCase and all), because
# the course is data that the executor reads by key. Text is text: every body
# is the same HTML fragment the web build set as innerHTML, and
# sim/lessonui.gd interprets the handful of tags it uses (<p>, <em>, <strong>,
# <kbd>, and the <b> of the myth and look-for boxes). Integers stay integers
# (a band index is an index); the executor converts where a number is a scale.
# ============================================================================

# The web build wrapped every figure with
#   svg(viewBox, inner) = `<svg viewBox="${viewBox}" class="lfig" ...>${inner}</svg>`
# and built the repetitive ones (the ladder rungs, the redshift strips, the
# spectrum ticks) with .map().join(). What is stored here is the expanded
# result, character for character; sim/lessonui.gd rasterises the shapes and
# sets the <text> itself (Godot's SVG loader has no text).
# ---------------------------------------------------------------------------
# FIGURES — only for the things the simulation genuinely cannot show you.
# Every one of these is a case where the real phenomenon is either too slow
# (the expansion of the universe), too small (a parallax of one arcsecond), or
# not a thing in space at all (the nuclear binding energy curve).
# ---------------------------------------------------------------------------
const FIGURES := {
	"parallax": """<svg viewBox="0 0 320 150" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <circle cx="40" cy="75" r="9" fill="#ffd28a"/>
    <text x="40" y="100" text-anchor="middle" fill="currentColor" font-size="9">Sun</text>
    <ellipse cx="40" cy="75" rx="34" ry="12" fill="none" stroke="currentColor" stroke-opacity=".35" stroke-dasharray="3 3"/>
    <circle cx="74" cy="75" r="4" fill="#7fc4ff"/><circle cx="6" cy="75" r="4" fill="#7fc4ff"/>
    <text x="74" y="62" text-anchor="middle" fill="#7fc4ff" font-size="8">January</text>
    <text x="6" y="98" text-anchor="middle" fill="#7fc4ff" font-size="8">July</text>
    <circle cx="196" cy="60" r="5" fill="#fff"/>
    <text x="196" y="47" text-anchor="middle" fill="currentColor" font-size="9">nearby star</text>
    <line x1="74" y1="75" x2="300" y2="40" stroke="#7fc4ff" stroke-opacity=".6"/>
    <line x1="6" y1="75" x2="300" y2="82" stroke="#7fc4ff" stroke-opacity=".6"/>
    <line x1="196" y1="60" x2="300" y2="52" stroke="currentColor" stroke-opacity=".18"/>
    <circle cx="300" cy="40" r="2" fill="#fff" opacity=".8"/>
    <circle cx="300" cy="82" r="2" fill="#fff" opacity=".8"/>
    <text x="284" y="112" fill="currentColor" font-size="8" text-anchor="middle">distant stars</text>
    <path d="M150 66 q10 6 0 12" fill="none" stroke="#ffd28a" stroke-width="1.2"/>
    <text x="140" y="78" fill="#ffd28a" font-size="9" text-anchor="end">p</text></svg>""",
	"ladder": """<svg viewBox="0 0 320 128" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    
        <rect x="10" y="34" width="54" height="40" fill="none" stroke="currentColor" stroke-opacity=".4"/>
        <text x="37" y="50" text-anchor="middle" fill="#ffd28a" font-size="8">radar</text>
        <text x="37" y="62" text-anchor="middle" fill="currentColor" font-size="7.5" opacity=".75">the solar system</text>
        <text x="37" y="88" text-anchor="middle" fill="#7fc4ff" font-size="8">10⁻⁴ ly</text>
        <rect x="72" y="34" width="54" height="40" fill="none" stroke="currentColor" stroke-opacity=".4"/>
        <text x="99" y="50" text-anchor="middle" fill="#ffd28a" font-size="8">parallax</text>
        <text x="99" y="62" text-anchor="middle" fill="currentColor" font-size="7.5" opacity=".75">to ~10 000 ly</text>
        <text x="99" y="88" text-anchor="middle" fill="#7fc4ff" font-size="8">10⁴ ly</text>
        <rect x="134" y="34" width="54" height="40" fill="none" stroke="currentColor" stroke-opacity=".4"/>
        <text x="161" y="50" text-anchor="middle" fill="#ffd28a" font-size="8">main-seq fitting</text>
        <text x="161" y="62" text-anchor="middle" fill="currentColor" font-size="7.5" opacity=".75">clusters</text>
        <text x="161" y="88" text-anchor="middle" fill="#7fc4ff" font-size="8">10⁵ ly</text>
        <rect x="196" y="34" width="54" height="40" fill="none" stroke="currentColor" stroke-opacity=".4"/>
        <text x="223" y="50" text-anchor="middle" fill="#ffd28a" font-size="8">Cepheids</text>
        <text x="223" y="62" text-anchor="middle" fill="currentColor" font-size="7.5" opacity=".75">nearby galaxies</text>
        <text x="223" y="88" text-anchor="middle" fill="#7fc4ff" font-size="8">10⁸ ly</text>
        <rect x="258" y="34" width="54" height="40" fill="none" stroke="currentColor" stroke-opacity=".4"/>
        <text x="285" y="50" text-anchor="middle" fill="#ffd28a" font-size="8">Type Ia</text>
        <text x="285" y="62" text-anchor="middle" fill="currentColor" font-size="7.5" opacity=".75">the far universe</text>
        <text x="285" y="88" text-anchor="middle" fill="#7fc4ff" font-size="8">10¹⁰ ly</text>
    <line x1="64" y1="54" x2="72" y2="54" stroke="currentColor" stroke-opacity=".5" marker-end=""/>
    <line x1="126" y1="54" x2="134" y2="54" stroke="currentColor" stroke-opacity=".5"/>
    <line x1="188" y1="54" x2="196" y2="54" stroke="currentColor" stroke-opacity=".5"/>
    <line x1="250" y1="54" x2="258" y2="54" stroke="currentColor" stroke-opacity=".5"/>
    <text x="160" y="20" text-anchor="middle" fill="currentColor" font-size="9">each rung is calibrated by the one before it</text>
    <text x="160" y="112" text-anchor="middle" fill="currentColor" font-size="8" opacity=".7">an error low down propagates all the way up</text></svg>""",
	"redshift": """<svg viewBox="0 0 320 140" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <text x="160" y="14" text-anchor="middle" fill="currentColor" font-size="9">the same spectrum, three distances</text>
    
      <rect x="40" y="30" width="240" height="18" fill="url(#g30)"/>
      <line x1="92" y1="30" x2="92" y2="48" stroke="#000" stroke-width="2"/>
      <line x1="128" y1="30" x2="128" y2="48" stroke="#000" stroke-width="2"/>
      <text x="34" y="43" text-anchor="end" fill="currentColor" font-size="8">nearby</text>
      <rect x="40" y="66" width="240" height="18" fill="url(#g66)"/>
      <line x1="118" y1="66" x2="118" y2="84" stroke="#000" stroke-width="2"/>
      <line x1="154" y1="66" x2="154" y2="84" stroke="#000" stroke-width="2"/>
      <text x="34" y="79" text-anchor="end" fill="currentColor" font-size="8">×2 further</text>
      <rect x="40" y="102" width="240" height="18" fill="url(#g102)"/>
      <line x1="144" y1="102" x2="144" y2="120" stroke="#000" stroke-width="2"/>
      <line x1="180" y1="102" x2="180" y2="120" stroke="#000" stroke-width="2"/>
      <text x="34" y="115" text-anchor="end" fill="currentColor" font-size="8">×4 further</text>
    <defs>
      <linearGradient id="g30" x1="0" x2="1">
        <stop offset="0" stop-color="#6f4bff"/><stop offset=".3" stop-color="#4ec5ff"/>
        <stop offset=".6" stop-color="#9fe36b"/><stop offset="1" stop-color="#ff5a4e"/>
      </linearGradient>
      <linearGradient id="g66" x1="0" x2="1">
        <stop offset="0" stop-color="#6f4bff"/><stop offset=".3" stop-color="#4ec5ff"/>
        <stop offset=".6" stop-color="#9fe36b"/><stop offset="1" stop-color="#ff5a4e"/>
      </linearGradient>
      <linearGradient id="g102" x1="0" x2="1">
        <stop offset="0" stop-color="#6f4bff"/><stop offset=".3" stop-color="#4ec5ff"/>
        <stop offset=".6" stop-color="#9fe36b"/><stop offset="1" stop-color="#ff5a4e"/>
      </linearGradient></defs>
    <text x="160" y="134" text-anchor="middle" fill="currentColor" font-size="8" opacity=".75">
      the lines shift toward the red in proportion to distance — v = H₀d</text></svg>""",
	"binding": """<svg viewBox="0 0 320 150" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <line x1="34" y1="126" x2="308" y2="126" stroke="currentColor" stroke-opacity=".4"/>
    <line x1="34" y1="16" x2="34" y2="126" stroke="currentColor" stroke-opacity=".4"/>
    <path d="M38 120 L52 66 L60 84 L70 52 L84 44 L104 32 L140 24 L168 22 L186 24 L230 34 L300 54"
          fill="none" stroke="#ffd28a" stroke-width="1.8"/>
    <circle cx="168" cy="22" r="3" fill="#8fe0c0"/>
    <text x="168" y="16" text-anchor="middle" fill="#8fe0c0" font-size="8">⁵⁶Fe</text>
    <text x="96" y="52" fill="currentColor" font-size="8" opacity=".8">fusion releases →</text>
    <text x="236" y="30" fill="currentColor" font-size="8" opacity=".8">← fission releases</text>
    <text x="170" y="140" text-anchor="middle" fill="currentColor" font-size="8">mass number</text>
    <text x="16" y="72" fill="currentColor" font-size="8" transform="rotate(-90 16 72)" text-anchor="middle">binding energy / nucleon</text></svg>""",
	"emspectrum": """<svg viewBox="0 0 320 92" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <defs><linearGradient id="em" x1="0" x2="1">
      <stop offset="0" stop-color="#3a2a5a"/><stop offset=".28" stop-color="#4a3a7a"/>
      <stop offset=".42" stop-color="#ff5a4e"/><stop offset=".5" stop-color="#9fe36b"/>
      <stop offset=".58" stop-color="#4e6bff"/><stop offset=".72" stop-color="#9a6bff"/>
      <stop offset="1" stop-color="#e8f0ff"/></linearGradient></defs>
    <rect x="14" y="26" width="292" height="20" fill="url(#em)"/>
    <text x="24" y="20" text-anchor="middle" fill="currentColor" font-size="8">radio</text>
        <line x1="24" y1="22" x2="24" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="70" y="20" text-anchor="middle" fill="currentColor" font-size="8">micro</text>
        <line x1="70" y1="22" x2="70" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="112" y="20" text-anchor="middle" fill="currentColor" font-size="8">IR</text>
        <line x1="112" y1="22" x2="112" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="160" y="20" text-anchor="middle" fill="currentColor" font-size="8">vis</text>
        <line x1="160" y1="22" x2="160" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="200" y="20" text-anchor="middle" fill="currentColor" font-size="8">UV</text>
        <line x1="200" y1="22" x2="200" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="246" y="20" text-anchor="middle" fill="currentColor" font-size="8">X</text>
        <line x1="246" y1="22" x2="246" y2="26" stroke="currentColor" stroke-opacity=".5"/><text x="292" y="20" text-anchor="middle" fill="currentColor" font-size="8">γ</text>
        <line x1="292" y1="22" x2="292" y2="26" stroke="currentColor" stroke-opacity=".5"/>
    <text x="16" y="60" fill="currentColor" font-size="8">1 km</text>
    <text x="160" y="60" text-anchor="middle" fill="currentColor" font-size="8">500 nm</text>
    <text x="304" y="60" text-anchor="end" fill="currentColor" font-size="8">10⁻¹² m</text>
    <text x="160" y="80" text-anchor="middle" fill="currentColor" font-size="8" opacity=".75">
      the visible band is the narrow strip our eyes evolved for — not a special part of physics</text></svg>""",
	"transitgeom": """<svg viewBox="0 0 320 116" class="lfig" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
    <circle cx="70" cy="58" r="34" fill="#ffd28a"/>
    <circle cx="70" cy="42" r="6" fill="#20242e"/>
    <path d="M36 58 h68" stroke="#20242e" stroke-opacity=".35" stroke-dasharray="2 3"/>
    <text x="70" y="106" text-anchor="middle" fill="currentColor" font-size="8">the planet crosses the disc</text>
    <path d="M150 40 h150" stroke="currentColor" stroke-opacity=".35"/>
    <path d="M150 40 h34 q4 0 6 14 l4 22 q2 12 8 12 h18 q6 0 8-12 l4-22 q2-14 6-14 h56"
          fill="none" stroke="#ffd28a" stroke-width="1.6"/>
    <text x="225" y="104" text-anchor="middle" fill="currentColor" font-size="8">…and the star dims by (r/R)²</text>
    <text x="300" y="36" text-anchor="end" fill="currentColor" font-size="7.5" opacity=".7">depth</text></svg>""",
}

# ============================================================================
# THE MODULES
# ============================================================================
const MODULES := [

# ---------------------------------------------------------------------------
{
	"id": "sky",
	"title": "The sky from here",
	"icon": "☉",
	"blurb": "What you can see without leaving the ground, and why it does what it does. Two of the five lessons here exist to break a specific wrong idea that survives most science educations.",
	"lessons": [

	{
		"id": "scale",
		"title": "How big, how far",
		"mins": 4,
		"goal": "Get the scale of the solar system right — which means getting it wrong-looking.",
		"steps": [
			{
				"title": "Every diagram you have ever seen is a lie",
				"do": {"preset": "solar", "trueScale": true, "cam": {"radius": 90}, "timeScale": 6},
				"body": """<p>This is the solar system with the distances <em>and</em> the sizes both true. Notice what
          happened to the planets: they vanished. Each one is now a point of light, because that is what
          a planet is at this distance — a rock a few thousand kilometres across, tens of millions of
          kilometres away.</p>
          <p>Every textbook diagram cheats by drawing the planets thousands of times too big. It has to,
          or the page would be blank. But the cheat is why almost everyone's mental picture of space is
          far too crowded.</p>""",
				"look": "The bright points strung out along their orbits ARE the planets. Click one to follow it.",
			},
			{
				"title": "Fly down to one",
				"do": {"preset": "solar", "trueScale": true, "focus": "Earth", "cam": {"radius": 0.0006}},
				"body": """<p>The camera is now following Earth, and the sub-pixel dot has resolved into a world with
          weather on it. Nothing changed except how close you are. That gap — between "a point of light"
          and "a place" — is the whole history of planetary astronomy, and it took telescopes four
          centuries to cross it.</p>""",
				"look": "Press the \"Sizes\" button in the controls to switch to the exaggerated view and back. The orbits do not move; only the drawing convention does.",
			},
			{
				"title": "Light takes time",
				"body": """<p>Light is fast but not instant: 8 minutes from the Sun to here, 4.2 <em>years</em> from the
          nearest other star. So every view outward is also a view backward. The Sun you see is the Sun of
          eight minutes ago; a galaxy ten million light years away is being seen as it was when our
          ancestors were still in the trees.</p>
          <p>Nothing in this simulation can violate that, because nothing in it moves faster than light.
          It is not a rule that was imposed — it falls out of the same relativity that bends light around
          the black holes later in this course.</p>""",
			},
		],
	},

	{
		"id": "daynight",
		"title": "Why the sky turns",
		"mins": 4,
		"goal": "Separate what the Earth does from what the sky appears to do.",
		"steps": [
			{
				"title": "Stand on the planet",
				"do": {
					"preset": "edu_seasons",
					"focus": "Earth",
					"cam": {"mode": "surface"},
					"timeScale": 0.003,
					"localTime": "morning",
				},
				"body": """<p>You are now standing on the surface, looking out. The Sun climbs, crosses, and sets — and
          it is doing none of those things. <em>You</em> are being carried east at about 1000 miles an hour
          by a planet that turns once a day, and the sky is standing still.</p>
          <p>That is genuinely hard to believe, and it took people about two thousand years to agree on
          it. Nothing you can feel distinguishes the two explanations, which is why the argument lasted.</p>""",
				"look": "Drag to look around. Find the horizon, then watch the Sun move relative to it.",
			},
			{
				"title": "Latitude changes everything",
				"do": {
					"preset": "edu_seasons",
					"cam": {"mode": "surface"},
					"timeScale": 0.003,
					"control": {"lat": 66.56},
					"localTime": "noon",
				},
				"body": """<p>The observer has been moved to about 66.56° north — the Arctic Circle. From here the Sun's daily
          path is tilted right over: it skims the horizon instead of climbing overhead, and for part of
          the year it does not set at all.</p>
          <p>Drag the Latitude slider in the controls. At the equator the Sun goes straight up and straight
          down; at the pole it circles the horizon. Same planet, same Sun, same day — all that changed is
          where you are standing on a sphere.</p>""",
				"look": "Latitude is in the control panel on the right, under the surface view settings.",
			},
		],
	},

	{
		"id": "seasons",
		"title": "Why there are seasons",
		"mins": 6,
		"goal": "Kill the distance explanation with the geometry, not with an assertion.",
		"myth": "Summer is when the Earth is closer to the Sun.",
		"steps": [
			{
				"title": "Test the wrong idea first",
				"do": {"preset": "edu_seasons", "focus": "Earth", "cam": {"mode": "orbit", "radius": 12}, "timeScale": 0.06},
				"body": """<p>Here is the Earth on its real orbit — a very slightly squashed circle, eccentricity 0.0167.
          It genuinely does get nearer and further: 147 million km in January, 152 million in July, a
          difference of about 3%.</p>
          <p>So the distance idea makes a prediction. If it were right, January would be summer <em>everywhere</em>
          and July would be winter everywhere. Neither of those is true, and the closest approach happens
          in the first week of January — in the middle of the northern winter.</p>""",
				"look": "Watch the orbit for a full year. The change in distance is real, and far too small to see.",
			},
			{
				"title": "What actually does it",
				"do": {"preset": "edu_seasons", "focus": "Earth", "cam": {"radius": 3.5}, "timeScale": 0.05},
				"body": """<p>The axis is tilted 23.44° — and, crucially, it keeps pointing at the same place in space all
          year. It does not swing round to follow the Sun. So for half the orbit the northern half leans
          <em>into</em> the light and for the other half it leans away.</p>
          <p>Leaning in does two things at once, and both matter: the Sun climbs higher, so the same beam of
          sunlight is spread over less ground, and the day is longer, so it arrives for more hours. Lean
          away and both reverse.</p>""",
				"look": "Watch the line between day and night on the planet. It does not pass through the poles — it slides, and which pole is in permanent light swaps over the year.",
			},
			{
				"title": "The two hemispheres disagree",
				"do": {
					"preset": "edu_seasons",
					"cam": {"mode": "surface"},
					"timeScale": 0.03,
					"control": {"lat": -35},
					"localTime": "noon",
				},
				"body": """<p>The observer has been moved to 35° <em>south</em>. The seasons here run exactly opposite to
          the northern ones, which no distance explanation can produce — the whole planet is at the same
          distance at the same time.</p>
          <p>This is the decisive test, and it is why the tilt explanation is the right one. Two places on
          one planet, one sweltering and one freezing, on the same day.</p>""",
			},
			{
				"title": "And on other worlds",
				"do": {"preset": "solar", "focus": "Uranus", "trueScale": false},
				"body": """<p>If the tilt is what makes seasons, then a differently tilted planet should have differently
          strange ones — and it does. Uranus is tipped 98°, which is to say its axis lies almost in its
          orbital plane. Its poles take turns pointing nearly straight at the Sun for forty-two years at a
          time.</p>
          <p>Mars is tilted 25°, almost the same as Earth, and has seasons you would recognise — except
          that its polar caps are frozen carbon dioxide, so every Martian winter freezes a chunk of the
          atmosphere onto the ground.</p>""",
			},
		],
	},

	{
		"id": "phases",
		"title": "Phases of the Moon",
		"mins": 5,
		"goal": "Show that a phase is a viewing angle, not a shadow.",
		"myth": "The Moon's phases are the Earth's shadow falling on it.",
		"steps": [
			{
				"title": "Half of it is always lit",
				"do": {"preset": "edu_moon", "focus": "Moon", "timeScale": 0.006},
				"body": """<p>Look at the Moon from out here, off to the side. Exactly half of it is in sunlight, and the
          lit half is always the half facing the Sun. That is true at every instant, everywhere in the
          orbit, and it never changes.</p>
          <p>So there is nothing about the Moon itself that has phases. What changes is how much of that
          permanently-lit half happens to be turned toward <em>us</em>.</p>""",
			},
			{
				"title": "Now watch from Earth",
				"do": {"preset": "edu_moon", "focus": "Earth", "cam": {"radius": 6.5}},
				"body": """<p>From here you see the Earth and Moon together, and you can see both at once: the geometry,
          and the phase it produces. When the Moon is on the far side from the Sun we see its whole lit
          face — full moon. When it is between us and the Sun we are looking at its unlit back — new moon.
          In between we see a slice, at an angle.</p>
          <p>Notice what the Earth's shadow is doing during all of this: nothing. It points directly away
          from the Sun, and at most full moons the Moon passes above or below it.</p>""",
				"look": "Follow one full cycle — 29.5 days. The phase tracks the angle between the Sun, the Moon and you, and nothing else.",
			},
			{
				"title": "The same face, always",
				"do": {"preset": "edu_moon", "focus": "Moon"},
				"body": """<p>One more thing the Moon does that is easy to get wrong: it turns. It turns exactly once per
          orbit, which is why the same side always faces us. A moon that did not rotate at all would show
          us every side over a month.</p>
          <p>This is not a coincidence — it is <em>tidal locking</em>, and the tides that caused it are the
          subject of a later lesson. Almost every large moon in the solar system has ended up this way.</p>""",
			},
		],
	},

	{
		"id": "eclipses",
		"title": "Eclipses, and why they are rare",
		"mins": 4,
		"goal": "Explain the 5° tilt, and the coincidence that makes total eclipses possible at all.",
		"steps": [
			{
				"title": "Why not every month?",
				"do": {"preset": "edu_moon", "focus": "Earth", "cam": {"radius": 5}, "timeScale": 0.006},
				"body": """<p>If the Moon's orbit were in exactly the same plane as the Earth's, there would be a solar
          eclipse at every new moon and a lunar eclipse at every full moon — twenty-four a year, like
          clockwork.</p>
          <p>It is tilted by 5.14°. That sounds tiny, and it is enough: at most new moons the Moon passes
          above or below the Sun–Earth line and nothing happens at all. Only when the
          crossing points of the two orbits happen to line up with the Sun does a shadow land. This demo
          shows those alignments; it does not render mutual eclipse shadows.</p>""",
				"look": "Watch the Moon relative to the line between the Sun and the Earth. It passes above, then below, then above.",
			},
			{
				"title": "An outrageous coincidence",
				"do": {"preset": "edu_moon", "focus": "Moon"},
				"body": """<p>The Sun is about 400 times wider than the Moon, and it is about 400 times further away. So
          from Earth, and only from Earth, and only right now, the two discs are almost exactly the same
          size in the sky. That is why a total solar eclipse is a thin ring of corona around a perfectly
          fitted black disc, rather than a dot crossing a blaze.</p>
          <p>It is genuinely a coincidence, and a temporary one. The Moon is receding about 3.8 cm a year.
          In 600 million years or so the last total eclipse will happen, and after that they will all be
          annular.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "gravity",
	"title": "Gravity and orbits",
	"icon": "◍",
	"blurb": "One force, one equation, and everything from a falling apple to a merging black hole. This module is where the simulation stops being an illustration and starts being the argument.",
	"lessons": [

	{
		"id": "ellipse",
		"title": "Orbits are ellipses",
		"mins": 5,
		"goal": "Kepler's first and second laws, watched rather than stated.",
		"steps": [
			{
				"title": "Three planets, one star",
				"do": {"preset": "edu_kepler", "cam": {"radius": 62}, "timeScale": 0.6},
				"body": """<p>Nothing here is on rails. Each planet was given a position and a velocity once, at the
          start, and everything since has come from one equation — the force between two masses falls off
          as the square of the distance between them.</p>
          <p>That single rule produces closed, repeating <em>ellipses</em>, and it took Kepler twenty years
          of Tycho Brahe's measurements to work out that they were ellipses and not circles. Newton then
          showed that the inverse-square law makes them ellipses necessarily.</p>""",
			},
			{
				"title": "The star is not in the middle",
				"do": {"preset": "edu_kepler", "focus": "Ellipse", "cam": {"radius": 40}},
				"body": """<p>Follow the eccentric one. The star is not at the centre of its ellipse — it sits at one
          <em>focus</em>, off to one side. So the planet has a nearest point and a furthest point, 0.42 AU
          and 2.58 AU, and it is at a different distance every day of its year.</p>
          <p>A circle is not the normal case that ellipses deviate from. It is the special case where the
          two foci happen to coincide, and nothing in nature is obliged to hit it exactly.</p>""",
			},
			{
				"title": "Equal areas: the second law",
				"do": {"preset": "edu_kepler", "cam": {"radius": 62}, "timeScale": 0.25},
				"body": """<p>Watch the trail behind the eccentric planet. Near the star it is stretched out; far from the
          star it is bunched up. The planet is moving 6.1 times faster at its closest point than at its
          furthest — the ratio is (1+e)/(1−e), and it comes out of the geometry.</p>
          <p>Kepler's way of putting this: the line from the star to the planet sweeps out equal areas in
          equal times. The modern way: angular momentum is conserved, so if the radius halves the
          sideways speed must double.</p>""",
				"look": "Slow the clock right down with the Sim Speed slider and watch the planet accelerate into its close approach.",
			},
		],
	},

	{
		"id": "harmonic",
		"title": "The law that weighs the universe",
		"mins": 5,
		"goal": "Kepler's third law, and what it is used for.",
		"steps": [
			{
				"title": "Same size, different shape, same year",
				"do": {"preset": "edu_kepler", "cam": {"radius": 62}, "timeScale": 0.6},
				"body": """<p>Circle and Ellipse could hardly look less alike — one is a neat circle at 1.5 AU, the other
          a long thin ellipse — and they have exactly the same <em>semi-major axis</em>, the average of
          their nearest and furthest distances.</p>
          <p>So Kepler's third law says they must have the same period. Watch them for a few laps. They
          were started together and they keep arriving together, forever, and nothing in the code makes
          them do that.</p>""",
				"look": "They separate wildly in the middle of each lap and re-converge at the far point. Every time.",
			},
			{
				"title": "Count the laps",
				"do": {"preset": "edu_kepler", "cam": {"radius": 70}, "timeScale": 1.2},
				"body": """<p>The third planet is at 2.381 AU, which was picked so that its semi-major axis cubed is
          exactly four times the inner one's. The law says P² ∝ a³, so its period should be exactly twice
          theirs.</p>
          <p>Count. Two laps of the inner pair to one of the outer, every time, with no drift. That is not
          a fitted curve — it is what the integrator does with an inverse-square force.</p>""",
			},
			{
				"title": "What it is actually for",
				"do": {"preset": "solar", "trueScale": true, "cam": {"radius": 80}},
				"body": """<p>Newton's version of the third law has the masses in it, and that turns it into the only
          scale that astronomy has: measure how long something takes to orbit and how far away it is, and
          you have weighed what it is orbiting.</p>
          <p>Every mass in this course was obtained that way — the Sun's, Jupiter's, the mass of a star in
          a binary, the mass of the black hole at the centre of the galaxy, the mass of a galaxy cluster.
          There is no other way to weigh something you cannot touch.</p>""",
			},
		],
	},

	{
		"id": "nbody",
		"title": "When there are three",
		"mins": 4,
		"goal": "Show the boundary between predictable and chaotic — honestly.",
		"steps": [
			{
				"title": "Two bodies are solvable",
				"do": {"preset": "edu_kepler", "cam": {"radius": 62}},
				"body": """<p>Two bodies under gravity have an exact solution, written down in the 1600s. Give me the
          positions and velocities now and I will tell you where they are in ten million years, in closed
          form, with a pencil.</p>""",
			},
			{
				"title": "Three are not",
				"do": {"preset": "threebody", "cam": {"radius": 22}, "timeScale": 1},
				"body": """<p>Three bodies have no such solution, and Poincaré proved in the 1890s that there cannot be
          one. What you are watching here is one of the rare exact special cases — the figure-eight
          choreography, discovered in 1993, in which three equal masses chase each other round one shared
          track.</p>
          <p>It is also unstable: nudge it and it does not come back. That is what "no solution" means in
          practice — the answer exists, but only a step at a time.</p>""",
			},
			{
				"title": "Chaos is not randomness",
				"do": {"preset": "trisolaris_wander", "cam": {"radius": 30}},
				"body": """<p>Three ordinary stars, no exact solution, and the result is this: orbits that never repeat
          and never settle. It is completely deterministic — run it twice from the same numbers and you
          get the same thing — but a difference in the tenth decimal place grows until it dominates, so
          prediction has a horizon.</p>
          <p>The solar system is in this category too. It is stable enough for billions of years, and yet
          nobody can tell you where Mercury will be in 100 million years.</p>""",
			},
		],
	},

	{
		"id": "tides",
		"title": "Tides, and how to tear a moon apart",
		"mins": 4,
		"goal": "Tidal force as a difference in gravity, and the Roche limit.",
		"steps": [
			{
				"title": "Gravity is not the same everywhere on you",
				"do": {"preset": "solar", "focus": "Earth", "trueScale": false},
				"body": """<p>The Moon pulls on the near side of the Earth slightly harder than on the far side, because
          the near side is closer. The <em>difference</em> is the tidal force, and it stretches the Earth
          along the Earth–Moon line — which is why there are two high tides a day and not one.</p>
          <p>Tidal force falls off as 1/r³, not 1/r². That much steeper fall-off is why the Moon beats the
          Sun at raising tides despite being unimaginably lighter.</p>""",
			},
			{
				"title": "Close enough, and it wins",
				"do": {"preset": "feeding", "cam": {"radius": 30}, "timeScale": 0.4},
				"body": """<p>Bring anything close enough to a heavy object and the stretch across it exceeds the object's
          own gravity holding it together. That distance is the <em>Roche limit</em>, and inside it nothing
          held together only by its own weight can survive.</p>
          <p>Here a star is being stripped by a black hole: the material is being pulled off the near side
          faster than the star can hold it, and it trails away into a stream.</p>""",
			},
			{
				"title": "Which is why there are rings",
				"do": {"preset": "solar", "focus": "Saturn", "trueScale": false},
				"body": """<p>Saturn's rings are entirely inside its Roche limit, and every one of its moons is outside.
          That is not a coincidence — it is the same line. Inside it, material cannot clump into a moon;
          outside it, material clumps into a moon within a few orbits.</p>
          <p>Every ring system in the solar system obeys this. In the sandbox you can paint a ring onto any
          body, and the span you get is calculated from that limit rather than chosen.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "light",
	"title": "Light, the only messenger",
	"icon": "≈",
	"blurb": "Nothing in this course has ever been touched, weighed, or visited. Everything we know came in as light — so the first question in astronomy is always: what can light tell you?",
	"lessons": [

	{
		"id": "inverse",
		"title": "Brightness and distance",
		"mins": 4,
		"goal": "The inverse square law, and the difference between bright and close.",
		"steps": [
			{
				"title": "The same star, three distances",
				"do": {"preset": "edu_habitable", "cam": {"radius": 22}, "timeScale": 0.25},
				"body": """<p>Three identical planets at 0.55, 1.0 and 1.9 AU from one star. The light leaving the star
          spreads out over a sphere, and the area of a sphere goes as r², so the light arriving per square
          metre falls as 1/r².</p>
          <p>That is a steep law. The inner planet gets 3.3 times the sunlight Earth does; the outer gets
          0.28 times. Same star, in the same system, at the same moment.</p>""",
			},
			{
				"title": "Which is why brightness is not luminosity",
				"do": {"preset": "stellar_zoo", "trueScale": true, "cam": {"radius": 60}},
				"body": """<p>A star's <em>luminosity</em> is how much light it makes. Its <em>brightness</em> is how much
          of that reaches you, and the two are related only through distance. So the brightest star in our
          sky, Sirius, is a fairly ordinary star that happens to be close, and the most luminous stars in
          the galaxy are invisible to the naked eye because they are far away.</p>
          <p>Almost every hard problem in astronomy for three hundred years was a version of this: to turn
          a brightness into a luminosity, you must already know the distance.</p>""",
			},
		],
	},

	{
		"id": "blackbody",
		"title": "Colour is temperature",
		"mins": 5,
		"goal": "Blackbody radiation: why hot things are blue and cool things are red.",
		"steps": [
			{
				"title": "Eleven stars, one rule",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}, "trueScale": false, "timeScale": 0.5},
				"body": """<p>These eleven stars run from 0.1 to 60 solar masses, and their colours are not chosen — each
          one is computed from its surface temperature by the Planck law, the same curve that makes an
          electric hob glow dull red and a welding arc glow blue-white.</p>
          <p>Anything warm radiates. The hotter it is, the more it radiates <em>and</em> the shorter the
          wavelength it radiates most strongly at. That second part is Wien's law, and it is why colour
          is a thermometer you can read from across the galaxy.</p>""",
			},
			{
				"title": "And it is a steep rule",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}},
				"body": """<p>Total power per square metre goes as T⁴ — the Stefan–Boltzmann law. Double the temperature
          and each square metre puts out sixteen times as much.</p>
          <p>That is why the range in this scene is so violent. The red dwarf at one end is 3000 K; the O
          star at the other is 45 000 K, fifteen times hotter and — with its much greater surface as well —
          nearly half a million times more luminous.</p>""",
			},
			{
				"title": "The classes are a temperature sequence",
				"do": {"preset": "hr_ladder", "cam": {"radius": 40}},
				"instrument": "hr",
				"body": """<p>Stars are classified O, B, A, F, G, K, M — an order that looks arbitrary because it is
          historical: it began as an alphabetical ranking of how strong the hydrogen lines were, decades
          before anyone realised that what it was really sorting was temperature.</p>
          <p>O is 30 000 K and blue. M is 3000 K and red. The Sun is G, at 5772 K, and is neither
          especially hot nor especially cool — it is a completely unremarkable star, which was itself one
          of the more unsettling discoveries of the last century.</p>""",
			},
		],
	},

	{
		"id": "spectrum",
		"title": "The seven skies",
		"mins": 6,
		"goal": "The electromagnetic spectrum as seven different views of one universe.",
		"steps": [
			{
				"title": "Visible light is a narrow slit",
				"fig": "emspectrum",
				"body": """<p>Our eyes respond to wavelengths between about 400 and 700 nanometres. That is not a special
          region of physics — it is the band that gets through the atmosphere and through water, which is
          where eyes were invented.</p>
          <p>Everything either side is the same phenomenon at a different wavelength: radio waves,
          microwaves, infrared, ultraviolet, X-rays and gamma rays are all light. Astronomy spent its
          first few thousand years with one of the seven windows open.</p>""",
			},
			{
				"title": "Change the band",
				"do": {"preset": "edu_galaxy", "band": 3, "cam": {"radius": 12}},
				"body": """<p>Press the keys <kbd>1</kbd> to <kbd>7</kbd>, or use the band buttons in the controls. You
          are looking at the same sky re-imaged at seven different frequencies — radio, microwave,
          infrared, visible, ultraviolet, X-ray, gamma.</p>
          <p>The dark lanes that split the Milky Way in visible light are dust, and dust is cold. In the
          infrared that same dust is the brightest thing in the sky. In radio you are seeing electrons
          spiralling in magnetic fields, which has no temperature at all.</p>""",
				"look": "Try 3 (visible), then 2 (infrared), then 1 (radio), then 6 (X-ray). Four different universes.",
			},
			{
				"title": "Why a flare is invisible and then blinding",
				"do": {"preset": "edu_sun", "band": 3, "timeScale": 0.0028, "flare": "Sun"},
				"body": """<p>A solar flare heats gas to about ten million kelvin. By Wien's law, gas that hot radiates
          mostly in X-rays — so in visible light a flare is a barely noticeable brightening on a surface
          already blazing at 5772 K.</p>
          <p>Switch to the X-ray band (<kbd>6</kbd>). Now the 5772 K surface is a black silhouette,
          because it is far too cool to emit at that frequency, and the flare is the brightest thing for
          a hundred million miles.</p>""",
				"look": "Watch it in band 4 (visible) first, then press 6. Same event, opposite picture.",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "stars",
	"title": "The Sun, and the other stars",
	"icon": "★",
	"blurb": "One ordinary star close enough to study in detail, and a hundred billion too far away to see as anything but points. Everything we know about the second group, we worked out from the first.",
	"lessons": [

	{
		"id": "sun",
		"title": "The Sun is a star",
		"mins": 6,
		"goal": "What a star is, all the way down.",
		"steps": [
			{
				"title": "A ball of gas holding itself up",
				"do": {
					"preset": "edu_sun",
					"focus": "Sun",
					"cam": {"radius": 6},
					"timeScale": 0.0028,
					"panel": {"coursePanel": false, "xsecPanel": true},
				},
				"instrument": "cutaway",
				"body": """<p>A star is a very simple object in one respect: it is a sphere of gas trying to collapse under
          its own weight and failing, because the pressure inside pushes back exactly as hard. That balance
          is called hydrostatic equilibrium, and it fixes everything else about the star.</p>
          <p>The cutaway here is not a drawing. It is built from the interior model — layer radii,
          temperatures and densities computed from the mass — the same model the rest of this simulation
          uses to decide what a body is.</p>""",
				"look": "The core is the small bright ball at the middle. It is a quarter of the radius and holds a third of the mass.",
			},
			{
				"title": "Where the energy comes from",
				"fig": "binding",
				"body": """<p>In the core, at 15 million kelvin, hydrogen nuclei fuse into helium. Four hydrogen nuclei
          weigh very slightly more than the one helium nucleus they make, and the missing 0.7% comes out
          as energy, via E = mc².</p>
          <p>The curve is why fusion works at all. Binding energy per nucleon rises steeply from hydrogen,
          peaks at iron, and falls again — so fusing anything lighter than iron releases energy and fusing
          anything heavier costs it. That peak at iron is going to end a star's life later in this course.</p>""",
			},
			{
				"title": "The light takes a very long time to get out",
				"do": {"preset": "edu_sun", "cam": {"radius": 4.5}},
				"body": """<p>A photon made in the core does not fly out. The gas is so dense that it is absorbed and
          re-emitted constantly, in a random walk that takes somewhere between ten thousand and a hundred
          thousand years to reach the surface — after which the last eight minutes to Earth are the easy
          part.</p>
          <p>The granulation you can see on the surface is the top of that journey: convection cells, each
          about the size of a country, carrying heat up, radiating it away and sinking back down.</p>""",
			},
		],
	},

	{
		"id": "activity",
		"title": "A star with weather",
		"mins": 6,
		"goal": "Magnetic activity: spots, flares, prominences, CMEs.",
		"steps": [
			{
				"title": "Spots are cold, and that is odd",
				"do": {"preset": "edu_sun", "focus": "Sun", "cam": {"radius": 5}, "timeScale": 0.0028, "band": 3},
				"body": """<p>Sunspots are about 1500 K cooler than the surface around them, which is why they look dark —
          they are still brighter than an arc lamp, just dimmer than their surroundings. What cools them is
          magnetism: a strong enough field stops the convection that brings heat up.</p>
          <p>The Sun is not a solid body. Its equator turns in 25 days and its poles in 35, and that
          shearing winds the magnetic field up like a spring. Spots are where the wound-up field breaks
          through the surface.</p>""",
			},
			{
				"title": "The field decides where the gas can go",
				"do": {"preset": "edu_sun", "cam": {"radius": 3.4}, "flare": "Sun", "timeScale": 0.0022},
				"body": """<p>In the atmosphere above a star, the magnetic field is much stronger than the gas pressure,
          so the gas simply cannot cross field lines — it slides along them. That is why what you see above
          an active region is a bundle of separate <em>threads</em> rather than a cloud.</p>
          <p>An eruption is a whole row of these loops — an arcade — anchored in two ribbons that pull
          apart as the reconnection front climbs. It is not one arch.</p>""",
				"look": "The clock is very slow here on purpose. A flare lasts hours; at normal orbital pace the whole event happens between two frames.",
			},
			{
				"title": "The same object, bright or dark",
				"do": {"preset": "edu_sun", "cam": {"radius": 3.2}, "flare": "Sun"},
				"body": """<p>The cool gas suspended in those loops is called a <em>prominence</em> when you see it off the
          edge of the Sun, glowing against black sky, and a <em>filament</em> when you see the same thing
          against the bright surface, where it appears as a dark thread in absorption.</p>
          <p>Same material, same loops. Only the background changed. In this simulation it is literally one
          set of geometry drawn twice, in two blend modes, because that is what it actually is.</p>""",
			},
			{
				"title": "And it reaches us",
				"do": {"preset": "edu_sun", "cam": {"radius": 8}, "flare": "Sun", "band": 5},
				"body": """<p>A big flare can be followed by a coronal mass ejection — a billion tonnes of magnetised
          plasma thrown off at a thousand kilometres a second. When one hits Earth it compresses the
          magnetosphere, lights up aurorae, and can trip power grids: Quebec lost its grid to one in 1989.</p>
          <p>This is the part of astronomy that has a civil-engineering department.</p>""",
			},
		],
	},

	{
		"id": "distances",
		"title": "How far away is a star?",
		"mins": 5,
		"goal": "Parallax and the distance ladder — the hardest measurement in astronomy.",
		"steps": [
			{
				"title": "Hold up a finger",
				"fig": "parallax",
				"body": """<p>Close one eye, then the other, and a nearby object jumps against the background. The nearer
          it is, the bigger the jump. That is parallax, and it is the only direct way we have of measuring
          a distance to a star.</p>
          <p>The baseline is the Earth's orbit: look at a star in January and again in July and you have
          moved 300 million km sideways. The nearest star shifts by 0.77 arcseconds — about the width of a
          coin seen from three miles away. This is why nobody managed it until 1838, and why its failure
          was for centuries the best argument against the Earth moving at all.</p>""",
			},
			{
				"title": "Which gives us a unit",
				"do": {"preset": "alphacen", "trueScale": true, "cam": {"radius": 60}},
				"body": """<p>A star whose parallax is one arcsecond is one <em>parsec</em> away — 3.26 light years. There
          are no stars that close. Alpha Centauri, the nearest system, is 1.34 parsecs out, and this
          scenario is it: a real binary on its real 80-year orbit, with Proxima bound to the pair 13 000 AU
          away.</p>
          <p>The Gaia spacecraft has now measured parallaxes for nearly two billion stars, which is most of
          what we know about the shape of our galaxy.</p>""",
			},
			{
				"title": "Everything else is a ladder",
				"fig": "ladder",
				"body": """<p>Parallax runs out at a few thousand light years — a rounding error on the size of the galaxy.
          Beyond that, every distance is measured with a <em>standard candle</em>: an object whose real
          luminosity you think you know, so that its brightness tells you how far away it is.</p>
          <p>Cepheid variable stars pulse at a rate set by their luminosity. Type Ia supernovae all
          detonate at very nearly the same mass and so at very nearly the same brightness. Each rung is
          calibrated by the one below it, which is why an error low down — as happened with the Cepheids
          in the 1950s — moves the size of the entire universe.</p>""",
			},
		],
	},

	{
		"id": "hr",
		"title": "The most important diagram in astronomy",
		"mins": 6,
		"goal": "The HR diagram, and what it means that stars are not scattered.",
		"steps": [
			{
				"title": "Plot them and see",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}},
				"instrument": "hr",
				"body": """<p>Take every star whose temperature and luminosity you can measure and plot one against the
          other. They do not fill the graph. Around 90% of them fall on a single band running from hot and
          bright to cool and faint — the <em>main sequence</em>.</p>
          <p>The band in this diagram is not a fitted line through data. It is the model in this simulation,
          sampled across mass: for each mass, the physics returns a radius, a luminosity and a temperature,
          and the points land where you see them.</p>""",
				"look": "The coloured dots are the stars currently in the scene, plotted live.",
			},
			{
				"title": "What the band means",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}},
				"instrument": "hr",
				"body": """<p>A star on the main sequence is a star burning hydrogen in its core — that is the whole
          definition. The band is a mass sequence: the bottom left is 0.1 solar masses and the top right is
          60, and every position on it is fixed by one number.</p>
          <p>This is the single most useful fact in stellar astronomy. Mass determines luminosity,
          temperature, radius, colour, lifetime and mode of death. A star has almost no freedom.</p>""",
			},
			{
				"title": "The clumps off the band",
				"do": {"preset": "stellar_zoo", "trueScale": true, "cam": {"radius": 60}},
				"instrument": "hr",
				"body": """<p>Up and to the right are the giants and supergiants: cool surfaces, enormous luminosity —
          which by the T⁴ law can only mean enormous surface area. Betelgeuse is 764 times the Sun's radius.
          Down and to the left are the white dwarfs: hot, and so faint that they must be tiny. Sirius B is
          the size of the Earth.</p>
          <p>Neither group is a different kind of object. They are main-sequence stars later on, and the
          next module is about how they got there.</p>""",
			},
		],
	},

	{
		"id": "binaries",
		"title": "How to weigh a star",
		"mins": 5,
		"goal": "Binaries as the only direct measurement of stellar mass.",
		"steps": [
			{
				"title": "Half of all stars have a partner",
				"do": {"preset": "sirius", "trueScale": true, "cam": {"radius": 40}, "timeScale": 3},
				"body": """<p>Sirius A and B, on their real orbit: 7.5 AU average separation, eccentricity 0.59, fifty
          years to go round. Binaries are not unusual — roughly half of all star systems have more than one
          star in them, and the Sun being alone is the slightly odd case.</p>""",
			},
			{
				"title": "And that is how we know any masses at all",
				"do": {"preset": "sirius", "cam": {"radius": 30}},
				"body": """<p>Watch the two of them swing around their common centre of mass. Measure the period, measure
          the separation, and Kepler's third law gives you the total mass. Measure how far each one moves
          and the ratio of the two masses falls out as well.</p>
          <p>That is the <em>only</em> direct way to weigh a star. Every stellar mass you have ever seen
          quoted traces back to a binary, and the main-sequence mass–luminosity relation was calibrated
          from a few hundred of them.</p>""",
			},
			{
				"title": "The companion that was found by arithmetic",
				"do": {"preset": "sirius", "focus": "Sirius B", "trueScale": true, "cam": {"radius": 8}},
				"body": """<p>Sirius B is the small one. Bessel noticed in 1844 that Sirius was wobbling, concluded there
          must be something pulling on it, and calculated the companion's mass before anyone saw it —
          eighteen years before it was first observed.</p>
          <p>It has about the mass of the Sun inside the volume of the Earth. Nobody could explain that
          until quantum mechanics arrived, and it is where the next module ends up.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "lives",
	"title": "The lives of stars",
	"icon": "✦",
	"blurb": "Stars are born, they change, and they die — and the way they die depends almost entirely on one number they were born with. This is also where the atoms you are made of came from.",
	"lessons": [

	{
		"id": "birth",
		"title": "Where stars come from",
		"mins": 5,
		"goal": "Cloud collapse, the disc, and why planets exist at all.",
		"steps": [
			{
				"title": "A cold cloud that is too heavy",
				"do": {"preset": "edu_starbirth", "cam": {"radius": 70}, "timeScale": 2},
				"body": """<p>Between the stars there is gas — mostly hydrogen, some of it in dense cold clouds at about
          10 kelvin. A clump inside one is held up by its own pressure until it gets too heavy, and then it
          is not: it collapses under its own gravity.</p>
          <p>The mass at which that happens — the Jeans mass — comes out at a few solar masses for a cloud
          at those temperatures and densities. That is why stars are the size stars are, rather than being
          the size of planets or of galaxies.</p>""",
			},
			{
				"title": "It cannot land on a point",
				"do": {"preset": "edu_starbirth", "focus": "Protostar", "cam": {"radius": 40}},
				"body": """<p>Whatever collapsed was turning a little, and rotation cannot be thrown away. So as the cloud
          shrinks it spins faster, and material with too much angular momentum to fall straight in settles
          into a <em>disc</em> instead.</p>
          <p>That disc is where planets come from, and it is why every planet in our solar system orbits in
          the same direction, in nearly the same plane, in the same sense as the Sun's own rotation. Those
          three facts are the strongest evidence we have for how we got here.</p>""",
				"look": "The disc particles are on real Keplerian orbits — the inner ones lap the outer ones, which is the third law again.",
			},
			{
				"title": "Not a star yet",
				"do": {
					"preset": "edu_starbirth",
					"focus": "Protostar",
					"cam": {"radius": 14},
					"panel": {"coursePanel": false, "xsecPanel": true},
				},
				"instrument": "cutaway",
				"body": """<p>The object at the centre is a protostar. It is shining, but not from fusion — it is
          radiating the gravitational energy of its own collapse, and it is bigger, cooler and redder now
          than it will ever be again.</p>
          <p>When the core reaches about 3 million kelvin, hydrogen ignites, the contraction stops, and the
          star arrives on the main sequence. For a solar-mass star the whole process takes about 30 million
          years — which is nothing.</p>""",
			},
		],
	},

	{
		"id": "mainseq",
		"title": "Mass is destiny",
		"mins": 5,
		"goal": "Why heavy stars are short-lived, and what the main sequence lifetime means.",
		"steps": [
			{
				"title": "More fuel, less time",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}},
				"instrument": "hr",
				"body": """<p>A star's fuel supply is proportional to its mass. Its luminosity — how fast it burns that
          fuel — goes roughly as mass to the power 3.5. So the lifetime goes as M/M³·⁵ = M⁻²·⁵, and heavier
          stars live spectacularly shorter lives.</p>
          <p>The Sun gets about 10 billion years. A 0.1 solar-mass red dwarf gets ten <em>trillion</em> —
          longer than the current age of the universe by a factor of seven hundred, which means no red
          dwarf has ever died of old age. A 60 solar-mass star gets about three million.</p>""",
			},
			{
				"title": "Which means the sky is a survivor bias",
				"do": {"preset": "stellar_zoo", "trueScale": true, "cam": {"radius": 60}},
				"body": """<p>Most of the stars you can see with your naked eye are far heavier and more luminous than
          average, because those are the ones bright enough to see from a long way off. Most of the stars
          that actually <em>exist</em> are red dwarfs, and you cannot see a single one of them without a
          telescope.</p>
          <p>About three quarters of all stars are M dwarfs. The sky is not a fair sample of anything.</p>""",
			},
		],
	},

	{
		"id": "giants",
		"title": "Leaving the main sequence",
		"mins": 6,
		"goal": "What happens when core hydrogen runs out — watched, with the interior open.",
		"steps": [
			{
				"title": "Open the star up",
				"do": {"preset": "edu_lifecycle", "focus": "Sol", "panel": {"coursePanel": false, "xsecPanel": true}},
				"instrument": "cutaway",
				"body": """<p>One solar-mass star, at the start of its main-sequence life, with its interior showing. The
          cross-section panel on the left has a slider marked <strong>Life burned</strong> — that is the star's
          evolutionary track, and every stop on it recomputes the radius, temperature, colour and interior
          from the model.</p>
          <p>Drag it slowly to the right and watch both the star in the scene and the cutaway here.</p>""",
				"look": "\"Life burned\" is the third slider in the cross-section panel, and the label beside it names the stage you are at. Take it a little at a time — the camera pulls back on its own as the star grows, because by the end it is 144 times wider than it is now.",
			},
			{
				"title": "The core runs out, and the star gets bigger",
				"do": {"preset": "edu_lifecycle", "panel": {"coursePanel": false}},
				"instrument": "cutaway",
				"body": """<p>This is the part that feels backwards. The core exhausts its hydrogen and, with nothing
          generating heat, it contracts — and contracting makes it <em>hotter</em>. That heats a shell of
          unburnt hydrogen around it, which burns furiously, and the envelope above expands enormously in
          response.</p>
          <p>So the star's core shrinks and its surface balloons. Spread over 25 times the radius, the
          surface cools to about 4000 K and turns red. That is a red giant: a tiny hot core inside an
          enormous cool envelope.</p>""",
			},
			{
				"title": "And the planets are in the way",
				"do": {"preset": "edu_lifecycle", "panel": {"coursePanel": false}},
				"body": """<p>Push "Life burned" up to the AGB stop. The star is now over a hundred times its original
          radius — beyond Mercury's orbit, and on the way to Earth's. In about five billion years this will
          happen here.</p>
          <p>What ends it is not an explosion. A star this light cannot get hot enough to burn carbon, so
          when helium runs out the envelope simply drifts away as a planetary nebula and the naked core is
          left behind — a white dwarf, cooling forever.</p>""",
			},
			{
				"title": "Held up by nothing but the exclusion principle",
				"do": {
					"preset": "sirius",
					"focus": "Sirius B",
					"trueScale": true,
					"panel": {"coursePanel": false, "xsecPanel": true},
				},
				"instrument": "cutaway",
				"body": """<p>Sirius B again, now that you know what it is. There is no fusion in it and no heat holding
          it up. What stops it collapsing is that electrons cannot be squeezed into the same quantum state
          — degeneracy pressure, which does not care about temperature at all.</p>
          <p>That support has a limit: above about 1.4 solar masses — the Chandrasekhar mass — it fails.
          Chandrasekhar worked this out at nineteen, on the boat to England, and was publicly ridiculed for
          it by the most eminent astrophysicist of the day. He was right.</p>""",
			},
		],
	},

	{
		"id": "supernova",
		"title": "The death of a heavy star",
		"mins": 6,
		"goal": "Core collapse, and what is left.",
		"steps": [
			{
				"title": "The onion",
				"do": {
					"preset": "edu_supernova",
					"focus": "Doomed",
					"cam": {"radius": 44},
					"panel": {"coursePanel": false, "xsecPanel": true},
				},
				"instrument": "cutaway",
				"body": """<p>Twenty solar masses, at the very end. A star this heavy can keep going after helium: it
          burns carbon, then neon, then oxygen, then silicon, each in a shell around the last, each stage
          hotter and faster than the one before.</p>
          <p>Look at the timescales in those shells. Hydrogen lasted 10 million years. Carbon lasts
          centuries. Oxygen, months. Silicon burning takes about a <em>day</em>, and it makes iron.</p>""",
			},
			{
				"title": "And iron cannot burn",
				"fig": "binding",
				"body": """<p>Iron sits at the peak of the binding energy curve. Fusing it does not release energy, it
          absorbs it. So the iron core just grows, inert, until it passes 1.4 solar masses — the same
          Chandrasekhar limit — and electron degeneracy gives way.</p>
          <p>The collapse takes about a quarter of a second. The inner core slams to a halt at nuclear
          density, rebounds, and the shock — helped by an immense flood of neutrinos — blows the rest of
          the star apart.</p>""",
			},
			{
				"title": "Watch it",
				"do": {"preset": "edu_supernova", "focus": "Doomed", "cam": {"radius": 44}},
				"collapseHint": "Doomed",
				"body": """<p>Use the button below to trigger the collapse. What is left over is not chosen by the
          scenario — the structure model works it out from the mass, and at 20 solar masses that is a black
          hole. Below about 20 it would be a neutron star instead.</p>
          <p>For a few weeks a supernova outshines its entire galaxy. Most of the energy is not in the light
          at all: 99% of it leaves as neutrinos, which is why the 1987A supernova was detected by three
          neutrino detectors three hours before anybody saw it.</p>""",
				"act": {"label": "Collapse the core", "collapse": "Doomed"},
			},
			{
				"title": "We are made of the debris",
				"body": """<p>The hydrogen in you is from the Big Bang. Essentially everything else — the carbon, the
          oxygen you are breathing, the calcium in your bones, the iron in your blood — was made inside a
          star and thrown out by one of these.</p>
          <p>Elements heavier than iron need something even more extreme. Most of the gold and platinum in
          the universe appears to have been made in <em>neutron star mergers</em>, which is the subject of
          the black hole module — and which we only confirmed in 2017.</p>""",
			},
		],
	},

	{
		"id": "neutron",
		"title": "Neutron stars and pulsars",
		"mins": 5,
		"goal": "The densest matter there is, and the lighthouse.",
		"steps": [
			{
				"title": "A star the size of a city",
				"do": {"preset": "edu_pulsar", "focus": "Pulsar", "trueScale": true},
				"panelHint": "xsecPanel",
				"body": """<p>When the core of a heavy star collapses and stops, this is what stops it: neutrons, packed
          at the density of an atomic nucleus. A solar mass and a half inside a sphere 24 km across. A
          teaspoon of it would weigh as much as a mountain range.</p>
          <p>Its surface gravity is two hundred billion times Earth's, and it bends the light leaving its
          own surface so hard that you can see well past the limb — more than half of the sphere at once.
          That is being ray-traced here, not approximated.</p>""",
			},
			{
				"title": "The lighthouse",
				"do": {"preset": "edu_pulsar", "band": 0},
				"body": """<p>Collapse conserves angular momentum, so a star that turned once a month ends up turning
          thirty times a second. It also concentrates the magnetic field to a trillion times the Sun's.</p>
          <p>Beams of radiation come out of the magnetic poles — which are not the rotation poles, so they
          sweep round like a lighthouse. If one happens to cross the Earth, we see a pulse every rotation,
          regular to better than an atomic clock.</p>""",
				"look": "You are in the radio band now — this is roughly what a radio telescope sees.",
			},
			{
				"title": "Discovered by someone who noticed something odd",
				"body": """<p>Jocelyn Bell Burnell found the first one in 1967 as a bit of "scruff" on a chart recorder,
          pulsing every 1.337 seconds. It was so regular that the team briefly labelled it LGM-1, for
          Little Green Men, before finding a second one somewhere else in the sky.</p>
          <p>Pulsars are now used as clocks: a network of them is one of the ways gravitational waves at
          very long wavelengths are being detected, by watching their pulses arrive slightly early and
          slightly late as space between us stretches and squeezes.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "holes",
	"title": "Black holes and spacetime",
	"icon": "●",
	"blurb": "What happens when gravity wins completely — and how, a century after they were predicted and dismissed, we finally heard two of them collide.",
	"lessons": [

	{
		"id": "escape",
		"title": "Escape velocity, taken to its limit",
		"mins": 5,
		"goal": "Build the event horizon from something familiar.",
		"steps": [
			{
				"title": "Throw something hard enough",
				"do": {"preset": "edu_hole", "cam": {"radius": 26}, "control": {"disc": 0}},
				"body": """<p>Throw a ball up and it comes back. Throw it at 11.2 km/s and it does not — that is Earth's
          escape velocity. It depends on mass and radius: squeeze the same mass into a smaller ball and the
          surface is closer to the centre, so escaping gets harder.</p>
          <p>Keep squeezing. At some radius the escape velocity reaches the speed of light, and since
          nothing goes faster, nothing gets out. That radius is 2GM/c², and it is called the Schwarzschild
          radius. For the Sun it is 3 km; for the Earth, 9 mm.</p>""",
			},
			{
				"title": "It is a place, not an object",
				"do": {"preset": "edu_hole", "cam": {"radius": 18}, "control": {"disc": 0}, "mesh": true},
				"body": """<p>The Newtonian argument above gets the right answer for the wrong reason. The real story,
          from general relativity, is that mass curves spacetime, and inside that radius the curvature is
          such that every possible future path leads inward. Falling in is not a matter of thrust — it is
          in the same category as next Tuesday.</p>
          <p>There is no surface there. The horizon is a boundary in spacetime, and someone falling through
          it notices nothing locally at all.</p>""",
			},
			{
				"title": "Nothing about it is special from far away",
				"do": {"preset": "edu_hole", "cam": {"radius": 60}, "control": {"disc": 0}},
				"body": """<p>A common misconception: black holes "suck". They do not. Replace the Sun with a black hole
          of exactly one solar mass and every planet would carry on in exactly the same orbit — colder, but
          undisturbed. Gravity at a distance depends on mass, and the mass did not change.</p>
          <p>What is different is only that you can now get very close to all of it.</p>""",
			},
		],
	},

	{
		"id": "shadow",
		"title": "The shadow and the ring",
		"mins": 5,
		"goal": "What you actually see when you look at a black hole.",
		"steps": [
			{
				"title": "A hole in the sky",
				"do": {"preset": "edu_hole", "cam": {"radius": 16}, "control": {"disc": 0}},
				"body": """<p>There is nothing to see here in the ordinary sense — the object emits nothing. Everything
          visible is the sky <em>behind</em> being bent around it, and the dark disc in the middle is where
          the sky is missing.</p>
          <p>That disc is bigger than the horizon: 5.2 Schwarzschild radii across, compared with two for the horizon. Light that comes
          closer than the photon sphere at 1.5 r_s cannot get back out even if it was never heading in, so
          the shadow is the horizon plus everything that grazes too close.</p>""",
				"look": "Look at the stars near the edge of the shadow. They are smeared into arcs — that is the same star, seen twice.",
			},
			{
				"title": "The photon ring",
				"do": {"preset": "edu_hole", "cam": {"radius": 11}, "control": {"disc": 0}},
				"body": """<p>At exactly 1.5 r_s, light can orbit. The thin bright circle at the edge of the shadow is
          light that went most of the way round and came back out toward you — and there is not one ring
          but an infinite nested series of them, each from light that went round one more time.</p>
          <p>The Event Horizon Telescope’s 2019 image shows a broad ring of emitting plasma around the
          shadow. It does not resolve this nested series of photon rings.</p>""",
			},
			{
				"title": "Turn the disc on",
				"do": {"preset": "sandbox", "cam": {"radius": 34}, "control": {"disc": 0.9}},
				"body": """<p>Now add an accretion disc. The extraordinary thing here is that you can see the <em>far
          side</em> of the disc — the part that should be hidden behind the hole — bent up and over the top,
          and again underneath. Light from behind the hole is being steered around it into your eye.</p>
          <p>One side of the disc is also much brighter than the other: it is coming toward you at a
          substantial fraction of light speed, and relativistic beaming concentrates its light forward.</p>""",
			},
		],
	},

	{
		"id": "accretion",
		"title": "How black holes shine",
		"mins": 4,
		"goal": "Accretion as the most efficient engine in the universe.",
		"steps": [
			{
				"title": "Friction in a spiral",
				"do": {"preset": "feeding", "cam": {"radius": 30}, "timeScale": 0.4},
				"body": """<p>Gas falling toward a black hole cannot fall straight in — it has angular momentum, so it
          settles into a disc and spirals slowly inward while friction between neighbouring rings drags on
          it. That friction turns orbital energy into heat, and the inner disc reaches millions of kelvin.</p>
          <p>So the brightest objects in the universe are powered by things that emit nothing at all.</p>""",
			},
			{
				"title": "The most efficient engine there is",
				"do": {"preset": "feeding", "cam": {"radius": 18}, "band": 5},
				"body": """<p>Nuclear fusion converts about 0.7% of mass into energy. Accretion onto a black hole
          converts between 6% and 40%, depending on spin — an order of magnitude better than the process
          that powers stars.</p>
          <p>That is why quasars exist: a supermassive black hole eating a few solar masses a year can
          outshine its entire host galaxy, which contains a hundred billion stars.</p>""",
				"look": "You are in X-ray now. The inner disc is million-kelvin gas, and this is the band it lives in.",
			},
			{
				"title": "There is one at the centre of this galaxy",
				"do": {"preset": "edu_galaxy", "sky": {"env": "core"}, "cam": {"radius": 12}, "band": 3},
				"body": """<p>Sagittarius A*, four million solar masses, 26 000 light years away. We know its mass
          because we have watched individual stars orbit it for thirty years — one of them, S2, goes round
          in sixteen years on an orbit that takes it within 120 AU.</p>
          <p>That is Kepler's third law again, applied to the darkest object in the galaxy. The 2020 Nobel
          Prize was for those measurements.</p>""",
			},
		],
	},

	{
		"id": "gw",
		"title": "Ripples in spacetime",
		"mins": 6,
		"goal": "What a gravitational wave is, and what it does to a detector.",
		"steps": [
			{
				"title": "Two holes, spiralling in",
				"do": {"preset": "bhmerger", "cam": {"radius": 72}, "timeScale": 0.08},
				"instrument": "gw",
				"body": """<p>Two black holes in orbit stir spacetime, and the stirring carries energy away. The orbit
          therefore shrinks, which makes them go faster, which radiates harder — a runaway that ends in a
          collision. This is not an animation: the energy loss is applied to the orbit as a force, and the
          speed-up follows from it.</p>
          <p>The trace on the left is the <em>strain</em> — the fractional stretch of space — that a detector
          on Earth could receive in an ideal orientation. This is a rescaled, leading-order inspiral
          illustration, not a detector waveform prediction: the demo accelerates the inspiral and does
          not model merger or ringdown.</p>""",
			},
			{
				"title": "Read the chirp",
				"do": {"preset": "bhmerger", "cam": {"radius": 50}},
				"instrument": "gw",
				"body": """<p>Two things rise together: the frequency and the amplitude. That characteristic sweep is
          called a chirp, and its shape encodes the <em>chirp mass</em> — a particular combination of the
          two masses that the waveform alone determines.</p>
          <p>The wave comes out at twice the orbital frequency. A binary looks the same after half a turn
          — swap the two objects and nothing has changed — so the pattern repeats twice per orbit.</p>""",
				"look": "Watch the frequency readout climb into the LIGO band as the separation shrinks.",
			},
			{
				"title": "How absurdly small it is",
				"do": {"preset": "bhmerger", "cam": {"radius": 28}},
				"instrument": "gw",
				"body": """<p>The L-shaped figure is an interferometer, and the numbers beside it are real. A strain of
          10⁻²¹ gives a differential change of about 4×10⁻¹⁸ metres between 4 km arms
          (about 2×10⁻¹⁸ metres per arm) — one thousandth of the width
          of a proton.</p>
          <p>Einstein predicted these in 1916 and spent years doubting they were real rather than an artefact
          of coordinates. He also thought they could never possibly be measured. It took a century and two
          detectors, and it worked on 14 September 2015.</p>""",
			},
			{
				"title": "And when neutron stars do it",
				"do": {"preset": "nsmerger", "cam": {"radius": 26}, "timeScale": 0.08},
				"instrument": "gw",
				"body": """<p>In 2017 two neutron stars were seen to merge — in gravitational waves, and then, 1.7 seconds
          later, in gamma rays, and then over the following weeks in every other band. Seventy observatories
          looked at it.</p>
          <p>The debris turned out to be manufacturing heavy elements: several Earth-masses of gold and
          platinum in one event. This is where that part of the periodic table comes from, and we did not
          know it for certain until that night.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "galaxies",
	"title": "Galaxies and the universe",
	"icon": "◈",
	"blurb": "Zoom out until stars are dust. The last two centuries of astronomy have been a repeated discovery that we are smaller and less central than the previous generation assumed.",
	"lessons": [

	{
		"id": "milkyway",
		"title": "The galaxy we are inside",
		"mins": 5,
		"goal": "Why the Milky Way is a band and not an object.",
		"steps": [
			{
				"title": "Look up",
				"do": {"preset": "edu_galaxy", "cam": {"radius": 12}, "band": 3, "timeScale": 0.1},
				"body": """<p>The Milky Way is not something in our sky. It <em>is</em> our sky — a disc about 100 000
          light years across and a thousand thick, with us two thirds of the way out from the middle. Look
          along the disc and there are thousands of stars behind each other; look perpendicular to it and
          you are looking out of the galaxy after a few hundred.</p>
          <p>That is why it is a band all the way round, and why it is narrow: you are seeing a flat thing
          edge-on from inside it.</p>""",
				"look": "Use the free camera (F, then WASD) or drag to turn. The band closes on itself.",
			},
			{
				"title": "The dark lanes are not gaps",
				"do": {"preset": "edu_galaxy", "cam": {"radius": 12}, "band": 3},
				"body": """<p>Splitting the band lengthways are dark rifts. They are not holes in the star distribution —
          they are dust clouds in the way, in the plane of the disc, blocking the light of everything
          behind them.</p>
          <p>That dust is why the centre of our own galaxy cannot be seen at all in visible light. We are
          26 000 light years from it and there are about thirty magnitudes of extinction in the way: a
          factor of 10¹².</p>""",
			},
			{
				"title": "Unless you change band",
				"do": {"preset": "edu_galaxy", "band": 2, "cam": {"radius": 12}},
				"body": """<p>Infrared light goes through dust. In this band the galactic centre is not hidden, and the
          dust itself glows — it is absorbing starlight, warming to a few tens of kelvin, and re-radiating
          at a wavelength it is transparent to.</p>
          <p>Try radio (<kbd>1</kbd>) too. There you are seeing hydrogen's 21 cm line and electrons
          spiralling in the galactic magnetic field — neither of which has anything to do with how hot
          anything is.</p>""",
			},
		],
	},

	{
		"id": "clusters",
		"title": "Star clusters",
		"mins": 4,
		"goal": "Open vs globular, and why clusters are how we date the universe.",
		"steps": [
			{
				"title": "Stars are born in batches",
				"do": {"preset": "edu_cluster", "cam": {"radius": 12}, "band": 3},
				"body": """<p>A cloud that collapses does not make one star, it makes hundreds or thousands at once — all
          from the same material, all at the same time, all at the same distance from us. That combination
          is extraordinarily useful.</p>
          <p>This is the view from inside a globular cluster: a million stars in a ball thirty light years
          across, bound to each other for twelve billion years.</p>""",
			},
			{
				"title": "Which turns the HR diagram into a clock",
				"do": {"preset": "hr_ladder", "cam": {"radius": 46}},
				"instrument": "hr",
				"body": """<p>Plot a cluster on an HR diagram and the main sequence is there — but only up to a point.
          Above a certain mass the stars have already died and left. The place where the sequence stops is
          the <em>turn-off</em>, and the lifetime of a star at that mass is the age of the cluster.</p>
          <p>Globular clusters come out at 12 to 13 billion years old. For decades that was awkward, because
          some estimates of the age of the universe were younger — a contradiction that helped force the
          cosmology to be re-measured.</p>""",
			},
			{
				"title": "Old clusters look old",
				"do": {"preset": "edu_cluster", "cam": {"radius": 10}},
				"body": """<p>Almost every star in a globular is either a red dwarf that has barely aged or a red giant on
          its way out. Everything in between has already gone. Open clusters, in the disc, are young — a few
          hundred stars, a few hundred million years, still full of blue stars, and they fall apart within a
          few orbits of the galaxy.</p>""",
			},
		],
	},

	{
		"id": "galaxytypes",
		"title": "A hundred billion others",
		"mins": 5,
		"goal": "That the \"spiral nebulae\" are galaxies, and what kinds there are.",
		"steps": [
			{
				"title": "The Great Debate",
				"do": {"preset": "edu_galaxy", "sky": {"env": "halo"}, "cam": {"radius": 12}},
				"body": """<p>In 1920 it was an open question whether the spiral nebulae were clouds inside our own galaxy
          or separate "island universes". Two astronomers argued it out in public and neither convinced the
          other.</p>
          <p>Hubble settled it in 1924 by finding a Cepheid variable in Andromeda and measuring its distance.
          It was far outside the Milky Way. In one measurement the known universe went from one galaxy to
          an unknown number of them.</p>""",
			},
			{
				"title": "Spirals, ellipticals and the mess",
				"do": {
					"preset": "edu_galaxy",
					"sky": {
						"env": [
							"disc",
							"starburst",
						],
					},
					"cam": {"radius": 12},
				},
				"body": """<p>Spirals are rotating discs with ongoing star formation, which is why their arms are blue —
          the blue stars are the ones that die before they can drift out of the arm they were born in.
          Ellipticals are old, gas-poor, and full of red stars; they are mostly the result of galaxies
          having merged.</p>
          <p>The Milky Way is a barred spiral. Andromeda is heading toward us at 110 km/s and in about four
          billion years the two will merge into an elliptical.</p>""",
			},
			{
				"title": "And most of the mass is invisible",
				"do": {"preset": "edu_galaxy", "sky": {"env": "halo"}, "cam": {"radius": 12}},
				"body": """<p>Stars at the edge of a spiral galaxy orbit far too fast for the mass you can see. By
          Kepler's third law they should be slowing with distance the way the outer planets do, and they do
          not — the rotation curve is flat.</p>
          <p>Either gravity is wrong on large scales, or there is five times more mass than there is light.
          The second option is called dark matter and, as of now, it fits a great deal of other evidence
          that the first one does not.</p>""",
			},
		],
	},

	{
		"id": "bigbang",
		"title": "The expanding universe",
		"mins": 5,
		"goal": "Redshift, expansion, and what the Big Bang actually claims.",
		"steps": [
			{
				"title": "Everything is moving away",
				"fig": "redshift",
				"body": """<p>Every distant galaxy's spectrum is shifted toward the red, and the shift is proportional to
          its distance — twice as far, twice as fast. Hubble found this in 1929.</p>
          <p>It does not mean we are at the centre of an explosion. Every observer in an expanding universe
          sees exactly the same thing, because it is not the galaxies moving through space so much as the
          space between them growing.</p>""",
			},
			{
				"title": "Run it backwards",
				"body": """<p>If everything is getting further apart, then everything used to be closer together, and
          there is a time — about 13.8 billion years ago — when it was all in the same place, at
          unimaginable density and temperature.</p>
          <p>That is the whole claim. It is not a theory of how the universe began; it is a theory of what it
          has been doing since, and it stops being able to say anything at all in the first fraction of a
          second.</p>""",
			},
			{
				"title": "And there is a photograph of it",
				"do": {"preset": "edu_galaxy", "band": 1, "cam": {"radius": 12}},
				"body": """<p>If the early universe was hot and dense, it was opaque — and it would have become
          transparent all at once when it cooled enough for atoms to form, 380 000 years in. That flash
          should still be arriving from every direction, stretched by the expansion into microwaves.</p>
          <p>Penzias and Wilson found it in 1964 while trying to get rid of a hiss in a radio antenna. It is
          2.7 kelvin, it is the oldest light there is, and its tiny ripples are the seeds of every galaxy.
          You are in the microwave band now.</p>""",
			},
		],
	},
	],
},

# ---------------------------------------------------------------------------
{
	"id": "worlds",
	"title": "Other worlds",
	"icon": "◉",
	"blurb": "Thirty years ago we knew of eight planets. Now we know of nearly six thousand, and none of them were seen directly — they were all inferred from a star behaving oddly.",
	"lessons": [

	{
		"id": "planets",
		"title": "What a planet looks like, and why",
		"mins": 5,
		"goal": "That a planet's appearance is a consequence of its circumstances.",
		"steps": [
			{
				"title": "Four rocky planets, four outcomes",
				"do": {"preset": "solar", "focus": "Venus", "trueScale": false, "timeScale": 1},
				"body": """<p>Venus is almost exactly Earth's size and mass, and it is 737 K at the surface under 92
          atmospheres of carbon dioxide — hot enough to melt lead, and hotter than Mercury, which is twice
          as close to the Sun. What went wrong was a runaway greenhouse.</p>
          <p>Use the Bodies list to visit Mercury, Earth and Mars. Same formation, same era, four completely
          different worlds, and the differences are almost all about mass and distance.</p>""",
			},
			{
				"title": "Craters are a clock",
				"do": {"preset": "solar", "focus": "Moon", "trueScale": false},
				"body": """<p>The Moon is covered in craters and the Earth is not, and the difference is not that the
          Earth was not hit. It is that the Earth erases: water, wind, and plate tectonics recycle the
          entire surface every few hundred million years.</p>
          <p>So a heavily cratered surface is an <em>old</em> surface, and counting craters is how planetary
          scientists date terrain on worlds nobody has visited.</p>""",
			},
			{
				"title": "Ice depends on what the ice is made of",
				"do": {"preset": "solar", "focus": "Pluto", "trueScale": false},
				"body": """<p>Earth's polar caps are water, freezing at 273 K. Mars's caps are mostly carbon dioxide,
          freezing at 148 K — so every Martian winter freezes part of the atmosphere onto the ground and
          every spring returns it. Pluto sits at 37 K, which is where <em>nitrogen</em> freezes, and so it
          has a nitrogen frost cycle.</p>
          <p>In this simulation that is one number per world — the condensation temperature of its dominant
          volatile. Everything else about the caps follows from where the planet is.</p>""",
			},
			{
				"title": "Gas giants have weather bands",
				"do": {"preset": "solar", "focus": "Jupiter", "trueScale": false},
				"body": """<p>Jupiter has no surface. What you see is the top of a cloud deck on a ball of hydrogen that
          just gets denser until it is a liquid metal. The bands are jet streams — alternating east and
          west winds — and the storms between them are vortices that ride their own jet.</p>
          <p>The planet also radiates about 1.7 times more heat than it receives from the Sun. It is still
          slowly contracting, and that is its own leftover formation energy leaking out.</p>""",
			},
		],
	},

	{
		"id": "transit",
		"title": "Finding planets: the transit",
		"mins": 6,
		"goal": "The method that found most of the planets we know.",
		"steps": [
			{
				"title": "A very small shadow",
				"fig": "transitgeom",
				"body": """<p>If a planet's orbit happens to be edge-on to us, the planet crosses in front of its star
          once per orbit and blocks a little of its light. The fraction blocked is just the ratio of the
          areas: (r_planet/R_star)².</p>
          <p>For a Jupiter across a Sun that is about 1%. For an Earth it is 0.008% — 84 parts per million,
          which is the reason this needed a dedicated space telescope.</p>""",
			},
			{
				"title": "Measure it",
				"do": {"preset": "edu_transit", "cam": {"radius": 26, "theta": 1.5708}, "timeScale": 0.005},
				"instrument": "photometer",
				"body": """<p>The chart is measuring the actual scene: it adds up the light of every star and subtracts
          whatever is in front, including the limb darkening that makes the middle of a stellar disc
          brighter than its edge. That is why the dip has a rounded bottom rather than a flat one.</p>
          <p>The deep dips are the hot Jupiter, once every 2 seconds or so — that is its 4.08-day year,
          sped up. The outer planet’s year is about 54 days, so its transits are much rarer
          and roughly two hundred times shallower.</p>""",
				"look": "The depth readout under the chart is the deepest dip so far, in parts per million. It reads about 21 000 — deeper than the 17 000 the area ratio alone would give, because the planet is crossing the bright middle of the disc.",
			},
			{
				"title": "Now break it",
				"do": {"preset": "edu_transit", "cam": {"radius": 26, "theta": 0.6}},
				"instrument": "photometer",
				"body": """<p>The camera has been lifted out of the orbital plane, and the transits have stopped. Nothing
          about the planets changed — only the viewing angle.</p>
          <p>This is the method's fundamental limitation. For an Earth at 1 AU round a Sun-like star, the
          chance that the geometry points at us is about one in two hundred. So for every transiting planet
          found there are roughly two hundred that are there and will never be found this way.</p>""",
				"look": "Drag the view back down into the plane and they come back.",
			},
			{
				"title": "What else a transit tells you",
				"do": {"preset": "edu_transit", "cam": {"radius": 20, "theta": 1.5708}},
				"instrument": "photometer",
				"body": """<p>The depth gives the planet's size. The interval between dips gives its orbital period, and
          hence its distance. The <em>duration</em> of a dip, compared with the period, says something about
          the orbit's inclination and eccentricity.</p>
          <p>And if the planet has an atmosphere, a little starlight filters through it on the way past,
          picking up the fingerprints of whatever molecules are there. That is how atmospheres are being
          measured on planets we cannot see.</p>""",
			},
		],
	},

	{
		"id": "wobble",
		"title": "Finding planets: the wobble",
		"mins": 5,
		"goal": "Radial velocity, and why it was the first method to work.",
		"steps": [
			{
				"title": "The star moves too",
				"do": {"preset": "edu_transit", "focus": "Kepler-ish", "cam": {"radius": 6, "theta": 1.5708}},
				"instrument": "photometer",
				"body": """<p>A planet does not orbit its star; both orbit their common centre of mass. The star's share
          of that motion is small but not zero — and when it is moving toward us, every line in its
          spectrum shifts slightly blue; away, slightly red.</p>
          <p>The lower trace is that motion, read straight off the simulation's velocity vector and
          converted to metres per second. The hot Jupiter here swings its star by about 152 m/s.</p>""",
			},
			{
				"title": "It is a speed measurement, in a spectrum",
				"do": {"preset": "edu_transit", "cam": {"radius": 10, "theta": 1.5708}},
				"instrument": "photometer",
				"body": """<p>152 m/s is a Doppler shift of about one part in two million. Measuring that in the spectrum
          of a star is what the first exoplanet discovery did in 1995 — 51 Pegasi b, a Jupiter-mass planet
          in a four-day orbit, which nobody had thought possible.</p>
          <p>Modern spectrographs reach about 30 cm/s. An Earth at 1 AU moves the Sun by 9 cm/s, so we are
          close, and not there yet.</p>""",
			},
			{
				"title": "The two methods together",
				"do": {"preset": "edu_transit", "cam": {"radius": 26, "theta": 1.5708}},
				"instrument": "photometer",
				"body": """<p>A transit gives you the planet's radius. A wobble gives you its mass. Get both for the same
          planet and you have its <em>density</em> — which is the difference between a rocky world, a water
          world and a puffball of hydrogen.</p>
          <p>Notice that the two traces are locked together: the transit happens exactly when the radial
          velocity passes through zero on its way from receding to approaching. Same orbit, two
          instruments.</p>""",
			},
		],
	},

	{
		"id": "habitable",
		"title": "The habitable zone",
		"mins": 5,
		"goal": "Where liquid water can exist — and how narrow the question really is.",
		"steps": [
			{
				"title": "Three identical planets",
				"do": {"preset": "edu_habitable", "cam": {"radius": 22}, "timeScale": 0.25},
				"body": """<p>Same mass, same radius, same albedo, same atmosphere — at 0.55, 1.0 and 1.9 AU. Nothing
          about how they look has been set. Each works out the sunlight falling on it, turns that into a
          surface temperature, and its ice, its deserts and its vegetation follow.</p>
          <p>Click each one in turn. One is a furnace, one is frozen solid, and the one in between is not
          special in any way except its distance.</p>""",
			},
			{
				"title": "And the zone moves",
				"do": {"preset": "edu_habitable", "focus": "Temperate"},
				"body": """<p>The habitable zone is not a property of a planet, it is a property of a star: it scales as
          the square root of luminosity. Round a red dwarf it is closer in than Mercury is to the Sun; round
          an A star it is out past Mars.</p>
          <p>It also moves over time. The Sun is about 30% brighter than when life began, and its habitable
          zone has been sliding outward ever since.</p>""",
			},
			{
				"title": "But \"habitable\" is doing a lot of work",
				"do": {"preset": "edu_habitable", "focus": "Scorched"},
				"body": """<p>The zone is defined by liquid water at the surface, which is a deliberately crude criterion
          — it ignores atmosphere, magnetic field, plate tectonics, and the star's temper. Venus is in the
          optimistic zone for the Sun. Europa is far outside it and has more liquid water than Earth,
          underneath ten kilometres of ice, kept warm by tides.</p>
          <p>It is a first filter for where to point a telescope, and not a claim about anywhere.</p>""",
			},
		],
	},

	{
		"id": "alone",
		"title": "Are we alone?",
		"mins": 4,
		"goal": "What the question actually decomposes into.",
		"steps": [
			{
				"title": "The terms of the question",
				"do": {"preset": "edu_galaxy", "cam": {"radius": 12}, "band": 3},
				"body": """<p>The Drake equation is not a formula for an answer — it is a way of splitting one unanswerable
          question into seven smaller ones. How many stars form; how many have planets; how many of those
          are habitable; how often life starts; how often it gets complicated; how often it gets
          technological; how long that lasts.</p>
          <p>When it was written in 1961, every one of those seven was a guess. Thirty years of exoplanet
          work has now nailed down the first three: planets are ordinary, and small rocky ones in habitable
          zones are common.</p>""",
			},
			{
				"title": "The rest is still open",
				"body": """<p>The fourth term — how often life actually starts — has a sample size of one, and you cannot
          do statistics on one. We do not know whether life is nearly inevitable given liquid water and a
          few hundred million years, or whether it is a fluke that happened once.</p>
          <p>Finding it a second time anywhere, even a microbe under the ice of Europa, would settle the
          most important open question in the field in a single afternoon.</p>""",
			},
			{
				"title": "Where the course leaves you",
				"do": {"preset": "solar", "trueScale": true, "cam": {"radius": 90}},
				"body": """<p>Back where it started, and with the scale now meaning something. One unremarkable G star,
          two thirds of the way out along one arm of one barred spiral, among a hundred billion galaxies.</p>
          <p>Everything in this course — the orbits, the interiors, the spectra, the collapse, the lensing —
          came from measuring light and applying physics found on Earth. That it works at all, on objects
          nobody will ever visit, is the actual achievement.</p>""",
			},
		],
	},
	],
},
]

# ---------------------------------------------------------------------------
# The course as a flat, ordered list. Two ways through it are both first-class:
# straight down the line, and jumping to whatever you came for. The linear
# order is what "next" means and what the progress bar measures; the module
# list is what makes jumping possible. Neither is the "real" one.
# ---------------------------------------------------------------------------
static var LESSON_ORDER: Array = _order()
static var LESSON_COUNT: int = LESSON_ORDER.size()
static var STEP_COUNT: int = _step_count()

static func _order() -> Array:
	var out: Array = []
	for m in MODULES:
		for l in m.lessons:
			out.append({"moduleId": m.id, "lessonId": l.id, "key": "%s/%s" % [m.id, l.id]})
	return out

static func _step_count() -> int:
	var n := 0
	for m in MODULES:
		for l in m.lessons:
			n += l.steps.size()
	return n

## { module, lesson, key } for "moduleId/lessonId", or null.
static func find_lesson(key) -> Variant:
	var parts := str(key if key != null else "").split("/")
	var mid := parts[0]
	var lid := parts[1] if parts.size() > 1 else ""
	for m in MODULES:
		if m.id != mid: continue
		for l in m.lessons:
			if l.id == lid:
				return {"module": m, "lesson": l, "key": key}
		return null
	return null

static func neighbours(key) -> Dictionary:
	var i := -1
	for j in LESSON_ORDER.size():
		if LESSON_ORDER[j].key == key:
			i = j
			break
	return {
		"index": i,
		"prev": LESSON_ORDER[i - 1].key if i > 0 else null,
		"next": LESSON_ORDER[i + 1].key if i >= 0 and i < LESSON_ORDER.size() - 1 else null,
	}

# Every scenario key the course asks for, so a start-up check can prove the
# curriculum and the preset catalogue have not drifted apart. There is no test
# runner here; this is the next best thing, and sim/lessonui.gd runs it once.
static func presets_used() -> Array:
	var seen := {}
	var out: Array = []
	for m in MODULES:
		for l in m.lessons:
			for s in l.steps:
				var d = s.get("do")
				if d is Dictionary and d.get("preset") and not seen.has(d.preset):
					seen[d.preset] = true
					out.append(d.preset)
	return out
