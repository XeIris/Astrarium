# Scenario files

Code: `sim/scenario_file.gd` (schema, orbits, checks), `sim/jsonc.gd` (the reader),
`sim/scenario_store.gd` (uploads). Check: `tools/scenariofilecheck.tscn`.

A scenario file sets up an orrery scene's initial conditions: its bodies, how
they start moving, the sky, the paint library's rings, belts and clouds, the
camera and the clock. It does not script anything and cannot ask for graphics
the game doesn't already draw. Scenarios that need code stay in GDScript:
`solar` and `jovian_voyage` (`sim/presets.gd`), the galaxy scenes, the title
reel and anything a lesson scripts.

## Files and where they live

- Built-in scenarios: `scenarios/<key>.jsonc`. The file name is the key that
  lessons and the command line use (`edu_hole.jsonc` is `preset=edu_hole`). A
  new file appears in the list under its `group`, after the scenarios
  `Presets.LISTED` orders, by `order` and then key. A built-in without a
  `group` loads but is not listed.
- Uploaded scenarios: **Upload scenario file…** below the scenario list copies
  the file, comments included, to `user://scenarios/custom_<name>.jsonc` and
  lists it under **Custom scenarios**. Uploading a file with the same name
  replaces the copy; ✕ removes it after asking. The original is never touched.
  A file that is refused is not copied. Checks use a temporary directory
  (`settings=default`), never the user's.
- A file is UTF-8 JSON with `//` and `/* */` comments and trailing commas
  allowed, at most 4 MB. Godot's JSON parser accepts neither comments nor
  reports duplicate keys (it keeps the last one), so the game reads these files
  with its own reader. That reader reports line and column, refuses duplicate
  keys and reads every number as the nearest double (`String.to_float` can be an
  ulp off).

## Values

- **Units are fixed per field** and listed below. There are no unit strings.
  Angles are in **degrees** and day lengths in **hours**; everything else is in
  the physics' units: AU, M☉, years, AU/yr, kelvin, L☉.
- **Leaving a key out, or writing `null`, means the same thing**: the model
  derives the value, or the default applies.
- `NaN` and `Infinity` are syntax errors. A number too large for a double
  (`1e400`) reads as infinite and is refused as not finite.
- `0` is checked against the field's range like any other number.
- Colours are `"#rrggbb"` strings. Integer fields must hold whole numbers.

## Validation

The whole file is checked before anything on the stage changes. Any **error**
refuses the file and leaves the current scene as it is. The message gives the
path, the line and the reason, e.g. `bodies[2].palete (line 31): unknown key`.
**Warnings** show a notice with **Load anyway**. A scenario with warnings keeps a
⚠ on its list entry and asks again each time.

### Errors

- A syntax error, an unknown key, or a key that doesn't apply to this body
  type (`rings` on a star).
- A wrong type, a value outside its range, or a name that doesn't exist (a
  palette, catalogue star, phase or composition).
- A body that `Structure.input_error` refuses, with the spawner's messages.
- Two bodies with the same name; more than one `home` world.
- A `focus`, `paint.body`, `paint.perturber`, `tidalLock` or `orbit.around`
  naming no other body, or orbits that name each other in a loop.
- `climate` or `surface` without a home world; `massSlider` without a black
  hole; `group` in an uploaded file.
- Both `orbit` and `pos`/`vel` on one body.
- Two bodies within contact distance at t = 0. They would merge on the first
  frame. The message names the pair.
- |v| ≥ c for any body.
- A white dwarf at or above the Chandrasekhar mass, or a neutron star above the
  TOV limit for its spin. They would explode or collapse on the first frame.
- More than 2048 bodies, or more than 500 000 paint particles in total. Past
  2048 the checks above alone take seconds, for a scene that would draw a
  frame every several seconds.

### Warnings (Load anyway)

- More than 256 bodies.
- A predicted CPU cost over 100 ms per frame, which is under 10 FPS. See
  [limits](#limits-measured).
- More starting sub-steps per frame than the 8000 `STEP_GUARD` allows. Time
  would run slower than asked.
- Any body faster than 0.1c, beyond the weak-field 1PN model.

### Loading anyway, and a frozen load

A scenario loaded anyway spawns its bodies over several frames, with a progress
notice, while the clock is held. If spawning passes **15 s**, it stops: the
previous scenario is reloaded (Blank Canvas if that one also needed asking), and
the notice says the load failed. If two frames in the first 3 s after loading
each take over a second (under **1 FPS**), the simulation pauses and the notice
says so. The scene stays loaded, so it can be inspected or unloaded. A load
without warnings stays synchronous, because lessons rely on it.

## The top level

| key | type, unit | range | when omitted |
|---|---|---|---|
| `format` | integer | `1` | **required** |
| `name` | string | 1–80 characters | **required** |
| `blurb` | string | ≤ 4000 characters | empty |
| `group` | string | a list group id; built-ins only | `custom` for uploads; unlisted for built-ins |
| `order` | number | finite | after the group's other new files, by key |
| `sky` | object | `SkyModel.request_error` ([sky schema](scenarios.md)) | the default sky |
| `bodies` | array of bodies | ≤ 2048 | **required** (may be empty) |
| `paint` | array of paint specs | see Paint | none |
| `sceneScale` | scene units per AU | > 0 | the widest start distance from the barycentre becomes 20 units; 2.0 with < 2 bodies |
| `bodyScale` | factor | > 0 | 1 |
| `trueScale` | bool | | false |
| `camRadius` | scene units | 1e-6–20000 | 2.5 × the widest start distance (50 when `sceneScale` is derived); 12 with one body, which is then the focus |
| `focus` | body name | an existing body | none |
| `lensing` | bool | | true if there is a black hole |
| `mesh` | bool | | true |
| `discIntensity` | factor | 0–1 | 0.9 |
| `discOuter` | horizon radii | > 0 | the disc model's own |
| `gwBoost` | factor | ≥ 0 | 0 |
| `timeScale` | years per second | > 0 | the shortest bound two-body period at the start takes 10 s, clamped to 1e-6–100; 2.0 without one |
| `maxStep` | years | > 0 | 5e-3; the integrator already shortens steps for close pairs |
| `epochJD` | Julian date | finite | none (the clock shows years) |
| `spawnAtRest` | bool | | false |
| `surface` | bool | needs a home world | false |
| `climate` | object | `ClimateInputs.KEYS` and their domains | the home world's drawn or stated inputs |
| `massSlider` | bool | needs a black hole | false (the sandbox's mass row) |

## Bodies

Every body has `type` (`planet`, `world`, `gas-giant`, `star`, `white-dwarf`,
`neutron`, `bh`) and `name` (unique, 1–40 characters). `mass` defaults to the
type's default. Placement is either `pos` + `vel` or an `orbit`; with neither,
the body starts at rest at the origin.

### Placement

| key | unit | notes |
|---|---|---|
| `pos` | AU, `[x, y, z]` | barycentric frame; y is up |
| `vel` | AU/yr, `[x, y, z]` | |
| `orbit.around` | a body name, or a list of names | that body, or those bodies' barycentre |
| `orbit.a` | AU | > 0, **required** |
| `orbit.e` | | 0 ≤ e < 1, default 0 |
| `orbit.i` | degrees | default 0; tilts the orbit about the x axis, as `Presets.kepler` does |
| `orbit.nu` | degrees | true anomaly, default 0 (periapsis on +x); 180 starts at apoapsis |
| `orbit.testParticle` | bool | default false; see below |

Bodies may be listed in any order. Each orbit is placed once every body it
names is placed, in file order among those ready, and the file's order is the
bodies' order. The parent is the named bodies together with everything already
placed around them, so a planet's moon moves with the planet.

By default the body and its parent move as a two-body pair. The Kepler mass is
parent + body, and the parent is shifted to keep the shared barycentre fixed.
With `testParticle: true`, the Kepler mass is the parent's alone and the parent
stays where it is; the body joins the parent's mass but not its barycentre.
Those are the conventions of the Trisolaris hierarchies (docs/scenarios.md). Ω
and ω are not in format 1, since no scenario needs them yet; adding them later
won't break existing files.

### Physics and structure (every type unless stated)

| key | unit | range |
|---|---|---|
| `mass` | M☉ | `Structure.input_error`: > 0; ≥ 1e-12 except for black holes; neutron ≥ its minimum |
| `spinFrac` | fraction of break-up | ≥ 0, below mass-shedding |
| `spinHz` | cycles per second (neutron) | ≥ 0; overrides `spinFrac` |
| `visualSpinRadS` | rad per render second | finite; display only |
| `phase` | a phase id (`protostar` `zams` `tams` `subgiant` `rgb` `rgbTip` `heburn` `agb` `preSN` `remnant`) or a number | star, white dwarf |
| `catalog` | a `Starcat` key (`siriusA`, `vega`, …) | star, white dwarf, neutron of that type: fills mass, radius, teff, luminosity, phase and spin; stated keys win |
| `radiusSun` / `radiusKm` | R☉ / km | > 0; measured beats modelled |
| `teff` | K | > 0 (star, white dwarf) |
| `luminosity` | L☉ | ≥ 0 (star, white dwarf) |
| `Z` | mass fraction | 0–1 |
| `ageYr` | years | > 0, ≤ 1e11 |
| `composition` | `iron` `mercury` `earth` `silicate` … | planet, world |
| `contactAU` | AU | ≥ 0; not for black holes, whose contact is derived |
| `softening` | AU | ≥ 0 |
| `emitsGW` | bool | default: black holes and neutron stars |
| `k2`, `tideLagS` | Love number / seconds | ≥ 0 |
| `dayLength` | **hours** | > 0 (planet, world, gas giant) |
| `obliquity` | degrees | finite |
| `tidalLock` | a body name | planet, world: the body it keeps one face towards |
| `home` | bool | a `world`; one at most |
| `seed` | number | finite; seeds the climate draw |

### Climate (planet, world)

The flat climate inputs of `ClimateInputs.DOMAIN`, with their ranges and units:
`mixedLayer` (m), `albedoBase`, `albedoIce`, `albedo`, `T0` (K), `oceans`
(bool), `salinity`, `land`, `oceanDepth` (km), `pN2` `pO2` `pAr` `pCO2` `pCH4`
`pSO2` (bar). Anything left unstated is drawn once, as for a spawned world.

### Look

Each look key has a physical or climate-derived default, so a file only states
what is unusual about the body.

| key | types | unit / values |
|---|---|---|
| `color`, `glow` | all | `"#rrggbb"` (a star's own colour comes from teff) |
| `palette` | gas giant | `GiantVisual.GIANT_PALETTES`: `jupiter`, `saturn`, `ice`, … |
| `rings` | gas giant | bool |
| `ringInner`, `ringOuter` | gas giant | planet radii, 1–20 |
| `ringColor` | gas giant | `"#rrggbb"` |
| `internalHeat` | gas giant | 0–100 |
| `vortices` | gas giant | whole number 0–8 |
| `hot`, `atmosphere` | planet, world | bool |
| `atmColor`, `cloudColor`, `regolith` | planet, world | `"#rrggbb"` |
| `haze`, `crater`, `cloudCover`, `biota`, `arid`, `transport` | planet, world | 0–1 |
| `atmThick` | planet, world | 0–4 |
| `cloudSpin` | planet, world | −100–100 |
| `surfaceK`, `frostK` | planet, world | K, above 0 and ≤ 5000 |
| `seaLevel` | planet, world | 0–1.3 |
| `plateScale`, `landRelief` | planet, world | above 0 / at least 0, ≤ 20 |
| `season` | planet, world | K of seasonal swing, 0–200 |

## Paint

| key | kinds | unit |
|---|---|---|
| `kind` | | `ring`, `belt` or `cloud`, **required** |
| `body` | all | an existing body name |
| `inner`, `outer` | ring, belt | AU, 0 < inner < outer, both required |
| `count` | ring, belt | whole number, 1–500 000 |
| `ecc` | ring, belt | 0–1 |
| `incl`, `tilt` | ring, belt | degrees |
| `surfaceDensity` | ring, belt | power-law index |
| `perturber` | ring, belt | a body name |
| `sizePx` | ring, belt | 0.5–16 |
| `decretion` | ring | bool |
| `radius`, `lobes`, `expand` | cloud | AU / whole number 1–4 / AU per year |
| `color`, `density`, `label`, `seed` | all | `"#rrggbb"` / 0–1 / text / finite |

## The built-in scenarios

Every scenario except `solar` and `jovian_voyage` is a file. Each was written
from the build it replaced, and `tools/fixtures/scenario_states.json` holds those
builds bit for bit (`-0.0` equal to `0.0`). The check refuses any file whose
settings or starting bodies differ from it. After an intended change, rewrite
the fixture with `tools/scenariofilecheck.tscn -- snapshot=1` and say why in the
commit.

`trisolaris`, `trisolaris_alpha`, `trisolaris_wide` and `sirius` are written
as orbits, which the orbit engine reproduces exactly. The rest are written as
`pos`/`vel`: their builders computed orbits in a different arithmetic order, or
summed the N-body pull (`star_ring`). `trisolaris_compact` is also states,
because its outer orbit's 12° inclination has no degree value that converts to
the same double. The stability study's `world_eccentricity=` override edits
`scenarios/trisolaris.jsonc`'s orbit before building it.

## Limits measured

Apple M5, Metal, 1280×720, render scale 1, VSync off. The frame is CPU-bound
throughout. Bodies circle a 50 M☉ hole at 3–60 AU, 5 sub-steps a frame unless
stated. Measure again with `tools/scenariolimits.tscn` (windowed; its header lists
the modes), and update `ScenarioFile.COST`, when per-body costs change.

| case | 10 FPS at |
|---|---|
| stars only | ~400 bodies |
| rocky planets, rocky worlds or gas giants, unlit | ~500 |
| rocky worlds lit by a 0.2 AU pair of suns (17 sub-steps) | ~300 |
| any bodies plus a 0.02 AU binary (524 sub-steps per frame) | ~65 |

The warning's model of frame time in ms:
`0.1 N + 0.07 × stars + 4e-5 N² × sub-steps`. The last term is the integrator,
3.6–3.8e-5 ms per pair per sub-step from 64 to 1024 bodies. A lit world costs
about 0.02 ms more than an unlit one, too little to model. The fitted
coefficients are 0.095, 0.065 and 3.7e-5. Rounded up, the model reads 3% under
to 16% over the measured cases near 100 ms whose sub-steps held steady, so it
mostly warns early.

The sub-steps are the starting ones, from `Derive.dynamic_step`. A scene that
draws its bodies into close passes later costs more than predicted: 256 bodies
mixing every type started at 5 sub-steps and settled at 16 (78 ms); 384 white
dwarfs, neutron stars and holes settled at 331 (1.8 s a frame).

Loading takes about 0.1 s at 128 bodies, 0.2 s at 256 and 0.2–0.5 s at 512,
depending on how many climates it builds.
