# The rovers: `sim/surface/rover.gd`, `rover_arm.gd`, `rover_dust.gd`, `rover_tracks.gd`

Two vehicles, as data on one physics (`Rover.LRV`, `Rover.PERSEVERANCE`), on the world's soil (`Rover.SOILS`):
- the Apollo Lunar Roving Vehicle, put down beside a landed LM;
- Perseverance, the stage the Sky Crane lowered, driven off from where it touched down.

Key U deploys either, W A S D drive, and on Perseverance G sends the arm to the ground and C reaches the mast
camera (`Spaceflight.deploy_rover`). They drive on the surveyed site the lander came down on
([the ground under a landing](surface.md#the-ground-under-a-landing)). In the site's
frame (x west, y up, z north), SI, doubles, a fixed 1/600 s step, on the flight clock whether drawn or not. It reads
the ground and writes nothing back.

## The vehicle

From [NSSDC's LRV page](https://nssdc.gsfc.nasa.gov/planetary/lunar/apollo_lrv.html):

| | |
| --- | --- |
| Frame, wheelbase | 3.1 m, 2.3 m |
| Tyres | 81.8 cm × 23 cm, woven steel strands; titanium chevrons over half the contact area |
| Mass | 210 kg empty, 490 kg of payload (700 kg here, two crew aboard) |
| Drive | four 0.25 hp series-wound DC motors capable of 10 000 rpm, 80:1 harmonic drives |
| Suspension | double wishbones on torsion bars, a damper to the upper wishbone |
| Steering | front and rear, a 3.1 m steering radius |
| Ground clearance, loaded | 36 cm |

Tread 1.83 m is the handbook's 72 in; NSSDC does not give it. These are estimates:
- the drive's efficiency, 0.8;
- the centre of mass, 0.76 m up with the crew aboard;
- the suspension, 5 cm of static deflection in lunar gravity, a damping ratio of 0.35 and 18 cm of travel;
- a wheel's inertia, a 5.4 kg rim;
- the steering motors' rate;
- the brakes' torque.

## Wheels in soil

Each wheel is a rigid wheel on the drawn triangles (`SiteScene.drawn_height`), pressed by its spring and damper.
The damper works on how fast the mount closes on the ground along its normal, so driving down a slope is not a
fall. Under load W, the wheel sinks by Bekker's rigid-wheel
form,

    z = [3W / ((3 − n)(k_c/b + k_φ) b √D)]^(2/(2n+1)),

and the soil resists its rolling by the compaction b(k_c/b + k_φ) z^(n+1)/(n+1). Thrust and side force are
Janosi–Hanamoto's, (A c + W tan φ)[1 − K/j (1 − e^(−j/K))], on a contact length √(Dz). The shear displacement j is the
slip times that length along the wheel, and the length times tan α across it, capped together at the soil's
strength. The soil:
- Bekker's moduli from the Lunar Sourcebook's Table 9.14 (k_c 1.4 kN/m^(n+1), k_φ 820 kN/m^(n+2), n 1), and
  Mohr–Coulomb strength for the top 15 cm (c 0.52 kPa, φ 42°), as [arXiv 2610.30080](https://arxiv.org/pdf/2610.30080)
  quotes them.
- K, 1.8 cm, is an estimate in the range Wong gives for dry sands.

The motors are a straight torque–speed line from stall to 10 000 rpm, peak power at half speed: an estimate of the
series motor. The parking brake sets once the vehicle is nearly still with the controller centred. A wheel held still shears the
soil under it up to its strength and stays sheared, so a parked rover holds a slope without creeping; once it has stood
still with nothing asked of it, it sleeps. Near rest the slip has a floor on its denominator, and the wheel's spin is
taken implicitly there. The vehicle that put the rover down stands in its way as a cylinder of its own diameter. At the
surveyed ground's edge it stops.

## What tests it (`rovercheck`)

Against what the crews and engineers recorded
([the ALSJ's LRV performance pages](https://nasa.gov/wp-content/uploads/static/history/alsj/WOTM/WOTM-LRVPerformance.html)).
None of the record is an input.

| Test | This model | The record |
| --- | --- | --- |
| Sinkage at rest, level | 1.83 cm (Bekker's closed form exactly) | tracks about half an inch, 1.27 cm ([Smithsonian, the spare wheel](https://www.airandspace.si.edu/es/collection-objects/wheel-lunar-rover/nasm_A19750830000)) |
| Full throttle on the level | 13.2 km/h | 13 km/h, Apollo 15 |
| Slip at it | 3.8% | "very little wheel slippage" |
| To 10 km/h from rest | 21 m | "approximately three vehicle lengths" |
| Across 15°, downhill and uphill wheels | 1.95 and 1.63 cm | deeper downhill, "perhaps up to 3 or 4 centimeters" on steep slopes |
| Full lock at walking pace | 3.16 m radius | 3.1 m |
| Hard over at 10 km/h, rear side slip | 36° (8.6° at 4 km/h) | "a breakout of the rear wheels" at 10 km/h |
| Parked on 15°, controller centred | 0.0005 m in 20 s | statically stable on the slopes met |
| Down 10° and 15° at full throttle | all four wheels on the ground, 4.9 cm of travel against the static 5.0 | — |
| Roostertail, accelerating from rest | 4.2 m high | about 3 m, Apollo 15 |

The rigid wheel overstates a flexible wire-mesh tyre's sinkage, which is spread over a longer contact. The straight
torque line gives too little torque at low speed. It reaches 10 km/h twice as slowly as the crews did, and it stalls
up 20° (printed by `rovercheck`, not judged), where Apollo 16 climbed with the pitch gauge pegged at 20°.

`groundcheck` drives the LRV off the LM it lands: every wheel stands on the built mesh's own triangles less its sinkage,
and nothing of it is left after the flight. The near grid's outer 8% is eased to the far grid as drawn, so crossing its
edge is a step of under 3 m over a 50 m cell (the far grid's kinks), not the tens of metres its own relief would end in.

## Dust

`rover_dust.gd`. A grain leaves the rim at the velocity the rim had there. For a point θ behind the contact, on a wheel
with rim speed u on a vehicle at v, that is v·h + u(−cos θ·h + sin θ·up). Rolling without slip it rises up and
forward, which is why the LRV had dust guards. A slipping wheel throws it back. There is no air, so each grain flies
an exact parabola under the world's g: the roostertail is as high as the rim speed makes it, u²/2g at most. That is
what the crews saw: no billowing. The guards catch what leaves under them, within 0.9 rad of the top. Under air, a
drag rate stands in for a 50 µm grain's (an estimate). Drawing only.

## Tracks

`rover_tracks.gd`. A strip along each wheel's contact points, the tread's width plus a margin either side, multiplied
into the ground's shading (`shaders/surface/track.gdshader`), so the rut keeps the ground's own colour. The shader
relights it as relief from a height field:

- a trough as deep as Bekker's sinkage, its floor rounding up into the walls over the tread's outer eighth;
- berms of the displaced soil just outside the walls, a third as high as the rut is deep (an estimate);
- the grousers' imprints along it, 2πr over the wheel's own count (`grousers`: the LRV's 24 chevrons, Perseverance's
  48 gently curved treads).

It is seen with parallax (a 12-step march down the eye ray) and shaded by its slope's light over the flat ground's,
with a short march toward the Sun for the walls' shadow on the floor and less sky in the rut. Multiplying cannot
lift the ground, so the berms only shade: the strip's own geometry stays on the surface. With the Sun down, or behind a
storm's dust, the shading goes. The strip is meshed in chunks, so a long drive rebuilds only its last one. A wheel that
left the ground starts a new strip. Drawing only. The soil does not yet remember being driven over (repetitive loading compacts it).

## Perseverance

From [NASA's rover pages](https://science.nasa.gov/mission/mars-2020-perseverance/rover-components/) and
[JPL's press kit](https://www.jpl.nasa.gov/news/press_kits/mars_2020/launch/mission/spacecraft/perseverance_rover/):
1025 kg, 3 × 2.7 × 2.2 m, six 52.5 cm wheels each with its own motor, the corner four steering, a rocker-bogie,
152 m/h on flat hard ground, a 45° tilt without tipping, and a five-jointed 2 m arm with a 45 kg turret.

These are estimates: the axles' places and the track inside the 3 × 2.7 m, the tread (narrower than Curiosity's 40 cm, NASA
says, without a figure; the drawn wheel is the tread the physics uses), the
centre of mass, the drive's torque limit, the steering's least radius (2 m) and rate. The rocker-bogie is a passive
linkage, stood in for here by stiff springs with its travel, so the loads it shares are not the linkage's. The drive
is speed-controlled: each wheel is commanded for its own arc about the turn's centre and held there as far as its
torque allows.

The soil is M90, a simulant of the sand of Martian dunes and ripples: kc 572.1 kN/m^(n+1), kφ 4915.3 kN/m^(n+2),
n 1.3, c 2 kPa, φ 35°, K 0.0254. These are Oravec et al. 2021's values, as [arXiv 2606.06790](https://arxiv.org/html/2606.06790)'s
Table 2 gives them, untuned there. Its K is labelled mm, and read here in metres, as the dry sand's beside it is.

| Test (`rovercheck`) | This model | The record |
| --- | --- | --- |
| Sinkage at rest in M90 | 1.95 cm (Bekker's exactly) | Curiosity's wheels went in about 1 cm on Gale's firmer ground ([Arvidson et al. 2014](https://agupubs.onlinelibrary.wiley.com/doi/full/10.1002/2013JE004605)) |
| Level sand, full speed | 135 m/h, 10.9% slip | 152 m/h on flat hard ground, less its slip in sand |
| Up 15° of sand | 85 m/h, 44% slip | — (25°: 17 m/h, 88% slip, printed) |
| Full lock | 2.00 m radius | its corner wheels set for 2 m |
| Parked on 15° of it | 0.00000 m in two minutes | — |
| Parked across 40° of firm ground (φ 50°, as M90's 35° cannot hold 40°) | stands; would tip past 49° | a 45° tilt without tipping |

## The arm

`rover_arm.gd`. A shoulder that turns and lifts, an elbow, and a wrist that keeps the turret square to the ground.
Its links are estimates within JPL's 2 m. It places the turret's face on a point of ground the rover can reach, by
the law of cosines in the arm's vertical plane, elbow up, and moves there at 0.15 rad/s a joint. It is kinematics
only: its mass does not move the rover. `rovercheck` holds the solve to the forward kinematics: 241 points reached,
the worst 2.5e-7 m out, and 159 out of reach refused. `groundcheck` puts the turret on the drawn ground 1.5 m ahead
of Perseverance after its Sky Crane landing.

## Instruments

The flight HUD's rover line carries MEDA's air: the pressure, temperature and wind the surface model has at the site
(`SurfaceSite`, [the surface's weather](surface.md#weather)). It is the model's, not a measurement, and the model's
Martian winds run two to three times high. The mast camera (C) looks from the mast's head, 2.2 m up, ahead and a
little down. Mastcam-Z's zoom is not modelled.

Not modelled: rocks, the regolith's density with depth, a tyre's flex, the batteries' charge or the MMRTG's power,
a crew standing up, what the instruments would read off the rocks (no composition). Dust devils are drawn
([the surface's dust](surface.md#dust-devils)), not felt.

## The model

`RoverModel` draws her from NASA's photographs (PIA24428 from the descent stage, PIA24424 and PIA24429 under her, PIA24426
from the mast):

- the white deck dense with boxes, the coring-bit carousel at the front, the Hazcams;
- the MMRTG canted at the back between its heat-rejection panels, open above;
- the hexagonal high-gain antenna, the mast with SuperCam over Mastcam-Z;
- the titanium rocker-bogie with the corner wheels' steering actuators;
- six wheels: 48 curved treads, curved spokes on the outboard face, a hub motor inboard.

The metals are dusty and nearly matte: in the photographs the wheels and links are light, and the flight scene has no
reflection probe, so a metallic surface would draw mirror-dark. As the Sky Crane lowers her, the mast lies along the
deck and the arm folds across her front.
