# Photorealism: the mission photographs, and how renderers get there

What the surface, the rovers and the Sky Crane are compared against, what the photographs teach, and the techniques
games and real-time renderers use for the same look. Each technique says where it is used here, or why not yet.

## The references

NASA's public-domain photojournal frames from Perseverance's landing and first sols. The asset URLs follow
`assets.science.nasa.gov/content/dam/science/psd/photojournal/pia/pia24/piaNNNNN/PIANNNNN.jpg`.

| Frame | What it shows | What it taught |
| --- | --- | --- |
| PIA24428 | The descent stage's camera looking down at her on the bridles, about 2 m above the ground | The stack's geometry: three bridles and the umbilical to the deck; the mast stowed along it and the arm folded. The plumes are invisible (hydrazine monopropellant); the dust they raise is what you see. |
| PIA24424 | Under the body, a Hazcam | Light, dusty metals; the wheels' 48 curved grousers; the soft, warm shadow under her |
| PIA24429 | A wheel, close | The grousers' height and curve; the rocks are vesicular and the soil's hue or lighter, not darker |
| PIA24426 | The first tracks, from the mast | Two ruts, each the grousers' imprint in a shallow trough with a soft berm |
| PIA24425 | The descent stage's crash plume on the horizon | The dark, slow column a flyaway leaves |
| PIA24430 | A Hazcam with her shadow | A butterscotch sky, low contrast, shadows filled by the sky's light |
| PIA24421, 24423 | The deck | The white deck dense with boxes; the MMRTG between its white panels at the back |
| PIA24431 | The parachute from the backshell | The orange-and-white disc-gap-band canopy |

The user's artist frame shows the same moment as PIA24428 from outside: the descent stage hovering with the rover
lowered under it.

### What was wrong before, against them

- **The Sky Crane** was an authored model of Curiosity's era: the descent stage drawn as a slab and a rover that was not
  the one that drives. There were no bridles, so nothing was lowered and nothing flew away. It now has its parts:
  - **The descent stage:** an open octagonal frame with its propellant and pressurant spheres in crinkled MLI, the
    radar plate and the bridle-umbilical device, and eight MLEs in canted pairs on four outriggers.
  - **The rover:** the same `RoverModel` that drives, built stowed.
  - **The drawn sequence (`SkyCraneRig`):** the heat shield drops at 8 km, and the drawn stack moves to her wheels
    once the shell has gone. The bridles pay out to 7.5 m and are cut a second after touchdown. Then the stage climbs,
    pitches over and flies about 650 m to crash, and smoke rises where it hits.
- **The rover model's** metals drew mirror-dark: the flight scene has no reflection probe, so metallic surfaces reflect
  only a dark ambient. The photographs show the metals light and nearly matte under the dust.
- **The rover's wheels** were inside-out in places: winding is now set from each face's outward direction, and the
  right side is mirrored in the mesh rather than with a negative scale.
- **The rocks** drew dark red-brown. The photographs' rocks are the soil's hue or lighter, greyer, wearing the same dust.
- **The tracks** were a flat darkening. They are now shaded as relief (below).
- **The dust:** the Sky Crane's plumes raised none, and Mars had no dust weather at all.

## How renderers get the look

### The ground at every distance

| Technique | What it does | Here |
| --- | --- | --- |
| Rotated, domain-warped fbm (Quílez, [*Warping*](https://iquilezles.org/articles/warp/), [*fBM*](https://iquilezles.org/articles/fbm/)) | Each octave turned and offset, so no grid shows through the sum | The flight ground and the site ground |
| Breaking texture repetition (Quílez, [*Texture repetition*](https://iquilezles.org/articles/texturerepetition/); Heitz & Neyret 2018's histogram-preserving stochastic tiling) | A tile sampled under random offsets and rotations per cell, blended so the histogram holds | Not used: the ground is procedural, with no tile to repeat |
| Footprint filtering (`fwidth`) | Detail fades before it aliases rather than shimmering | Every procedural layer, including the tracks' grousers |
| Triplanar mapping | Steep slopes textured without stretching | The descent stage's MLI wrinkles |
| Height-blended layers | Sand settles into rock's cracks rather than cross-fading over them | Geology-driven colour, by slope and curvature |
| GPU procedural placement (van Muijden, *GPU-Based Run-Time Procedural Placement in Horizon Zero Dawn*, GDC 2017) | Scatter from density maps, regenerated about the camera | `SiteRocks`: Golombek & Rapp's size-frequency law in cells about the eye, one instanced mesh |
| Parallax occlusion mapping (Tatarchuk, I3D 2006) | Relief inside a flat polygon, with self-shadowing | **The tracks** |
| Deformation render targets (Barré-Brisebois, *Deformable Snow Rendering in Batman: Arkham Origins*, GDC 2014) | Footprints and ruts written into a height texture the terrain displaces by | Not yet. The site's grid is too coarse to displace by centimetres, so the ruts are a decal with parallax. A render target under a finer near patch is the next step. |

### Light and air

| Technique | What it does | Here |
| --- | --- | --- |
| Precomputed single and multiple scattering (Bruneton & Neyret 2008; Hillaire, *A Scalable and Production Ready Sky and Atmosphere Rendering Technique*, EGSR 2020) | A sky and aerial perspective from the air's own coefficients | The flight sky's multiple-scattering table (`sky_ms.gd`); Titan's deep haze by two-stream |
| Physically based units and exposure (Lagarde & de Rousiers, *Moving Frostbite to PBR*, SIGGRAPH 2014) | Light in real units, a camera that adapts | The sun's flux from the star; exposure follows the diffuse light under a haze |
| A sky's light in the shadows | Shadows filled by the sky, not black | The ground's skylight term; `LocalView`'s ambient from the sky |
| Volumetric clouds (Schneider, *The Real-time Volumetric Cloudscapes of Horizon Zero Dawn*, SIGGRAPH 2015) | Ray-marched cloud density with powder and silver-lining terms | The flight cloud pass |
| Fog by optical depth | The view closes by Beer–Lambert, coloured by the medium | **A dust storm**: the extra τ dims the Sun along its slant path and closes the view through a 3 km layer |

### Particles and effects

| Technique | What it does | Here |
| --- | --- | --- |
| Soft billboard sprites, lit by the scene's light | Dust and smoke without hard edges | Plume dust, dust devils, the crash smoke |
| Physical emitters | Particles leave where and as fast as the physics says | Wheel dust from the rim's velocity; plume dust from the jet's ground pressure |
| Population models | Weather systems spawned and retired by rate | Dust devils at Jezero's encounter rate, drifting with the wind |

### Models

The photographs set the parts, and the parts follow the rules the ground follows:

- **Materials:** dusty metals drawn nearly matte, light where the photographs are light.
- **Winding:** faces wound from their outward direction.
- **What is drawn is what is simulated:** the wheels are the tread the physics rolls on, and the rover lowered by the
  Sky Crane is the one that drives off.

## Where it stands against the references

The renders behind this table are in this change's evidence.

| Reference | Now | Still short of it |
| --- | --- | --- |
| PIA24428, the rover on the bridles | The stack, the bridles and the umbilical, the stowed mast and folded arm, the dust beneath | The descent stage's camera's fisheye framing, and the rover's harness and fine deck detail |
| PIA24426, the first tracks | Two ruts with grouser imprints, berms and their shadows | Displacement in the geometry; the soil's compaction and colour change in the rut |
| PIA24429, the wheel | 48 curved grousers, the spokes outboard | The wheel's real width (NASA gives no figure; the physics' 26 cm estimate is drawn) |
| PIA24425, the crash plume | A dark column 650 m off, drifting | Its timing is a visual flyaway, not a flown trajectory |
| Rocks in the frames | The soil's hue, greyed | Vesicular, rounded shapes. One angular mesh in many rotations is not yet enough. |
| The sky's colour | The butterscotch day sky; a storm's closing pall | Blue sunsets (dust's forward scattering) |

## What would come next

1. **Ruts in the geometry:** a render-target height field under a finer near patch, so the berms rise and occlude.
2. **Rocks:** several meshes, with vesicles in a normal map and rounded and angular shapes by the geology.
3. **A probe for the metals:** a reflection probe at the site, so a metal can be metal.
4. **Dust's phase function** in the sky, for the blue Martian sunset.
