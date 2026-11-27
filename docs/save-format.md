# Saved games

Sandbox, Spaceflight and Planetary exploration each have ten slots. A slot is one
JSON file, `user://saves/<kind>/slot_NN.json`, where kind is `sandbox`, `spaceflight` or
`planetary`. On macOS that is under
`~/Library/Application Support/Godot/app_userdata/Astrarium/saves/`.

The code is in three places. `sim/save_store.gd` owns the slots and the file envelope.
`sim/save_game.gd` decides what a save holds and puts it back on the stage.
`sim/save_codec.gd` keeps JSON from changing a value. `ui/save_browser.gd` is the card,
and `tools/gamesavecheck.tscn` checks all of it.

## The file

```jsonc
{
  "format": 1,                 // a newer number is refused: "saved by a newer version"
  "kind": "sandbox",           // must match the folder it is in
  "name": "Before the flyby",  // 1–48 characters, no control characters
  "saved": 1796000000.0,       // Unix seconds when it was saved; renaming keeps it
  "summary": "Solar System · 1 star, 8 rocky worlds, 4 gas giants · 12.30 yr in",
  "state": { "world": { … }, "flight": { … } }   // or "explore"
}
```

An unknown top-level field is an error. A file over 64 MB, or a recovery file
(`slot_NN.json.bak`) over it, is refused before it is parsed, and a save that would be
over it is not written. A slot is written next to its file and renamed over it
(`core/json_file.gd`), so a failed save leaves the slot as it was. A slot whose state
does not pass `SaveGame.validate` is listed as unreadable, with the reason, like a
damaged file.

JSON loses three things, and the codec puts them back:

| tag | holds | why |
|---|---|---|
| `{"@i": "42"}` | an int | Godot reads every JSON number as a float. A world's climate draw is keyed on the text of its seed, so `42` and `42.0` give different worlds. |
| `{"@f": "inf"}` | `inf`, `-inf`, `nan` | JSON has no non-finite numbers. A climate's empty S range is ±∞. |
| `{"@d": "<16 hex>"}` | a double's IEEE-754 bytes | Godot's JSON parser does not round every decimal correctly, so some doubles come back one ulp off. A double stays a plain number only when it reads back bit for bit. |

Keys starting with `@` are reserved. Objects, Callables and vectors cannot be saved.

## What a save holds

**world** (every kind):

- **scene**: the scenario's settings (`name`, `sceneScale`, `bodyScale`, `camRadius`,
  `timeScale`, …, as in [scenario files](scenario-format.md)) and the key it was loaded
  from.
- **sky**: the live sky, with the weight of each environment.
- **live**: sizes, pace, step cap, GW boost, lens and mesh, spawn mode, speed, pause,
  the clock and its compensated remainder, bodies consumed, pin-on-focus, and the
  climate turn (which worlds' climates step on the next frame).
- **tides**: the Roche check's last sample of each pair it watches (`r·v` and when), so
  a periapsis passed between the save and the next check is still found.
- **bodies**: each body's spec, with its position and velocity, plus its live state.
  The live state is its mass, spin fraction, stellar phase, spin rate and whether that
  rate is tracked, its rotation and cloud phases, its day length (the Day length slider
  sets it directly), `extra`, the structural-limit memo,
  and its climate (temperature, ice, ocean, steam, the latitude profile, extremes,
  history, and the inputs drawn for it).
- **paint**: each ring, belt and cloud, as the spec it was made from (random parts
  drawn, and the mass a ring or belt orbits, which fixes its particles' rates) and its age.
- **camera**: orbit or free, angles, distance, target, offset, and which body is
  followed and focused (by index).

A body's structure can trail its live mass, spin and age: it is re-derived only past a
margin (`main.check_structural_limits`). So the spec stores what the structure was last
derived from, and the live values are put back after the body is derived again. A loaded
body has the original's radius bit for bit, and re-derives its structure on the frame the
original would have.

**flight** (Spaceflight): the vehicle and the keys of the stages it flies (a scenario
may fly a subset), and the parent body. On the pad, that is all, and the count starts
again. In flight it adds position, velocity, attitude and body rates in the parent's
frame, phase, clocks, throttle and the other control settings, each stage's propellant,
RCS, ignition, engines lit and gear, the launch site, the chute, the milestones, the
last 300 log lines, the autopilot's mode and program, the mission's destination and
goal, the target, and the camera.

**explore** (Planetary exploration): the world explored (by index), the pin's number
in its sequence, whether a pin was still to drop, and whether you were standing on it.

## Loading

The state is validated whole before the stage changes: every spec through
`Structure.input_error`, every number finite, every index in range, the vehicle and
its stages in the catalogue, the phase one that can be restored. A refused load says
why, and the scene stays as it was. Capture runs the same validation, so a scene that
would not load back is not saved; a body whose spec the stage would refuse is one
example.

A loaded world plays on bit for bit: the check flies it 240 frames against the
original. A loaded flight comes back bit for bit, and under power it stays within
0.5 m of the original after 5 s. The difference is attitude control's rate memory
(`Vessel._prev_dir`), which starts again from nothing.

## Not kept, or kept approximately

- **Stellar flares and spots.** The activity model draws from Godot's unseeded global RNG,
  so no two runs replay it the same way, saved or not. A loaded star starts a new
  sequence; in total output a flare is about 1e-3 of a star's light.
- **Trails** start empty. **Energy drift** is measured from the load.
- **Galaxy scenes**, **docking approaches**, the **Kerr demonstration**, an
  **interstellar cruise**, a **mission skip** in progress, a **rollout**, a **booster
  returning to its tower** and a **Sky Crane mid-lowering** cannot be saved; Settings ›
  Saves says which.
- **Dropped stages** still falling, and a **deployed rover or rotorcraft**, are not saved.
  After a load the rover or rotorcraft is back aboard its lander.
- A **mission in progress** is planned again from where the craft is. A **running
  program** is engaged again on the restored state, so its internal filters start
  fresh. The guidance laws are closed loops on the vehicle's own state.
- The **surface camera's** look direction is not kept. A save made standing on a
  world stands at the same pin, facing the visit's default direction.
