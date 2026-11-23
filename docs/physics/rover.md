# The rover: `sim/surface/rover.gd`, `rover_dust.gd`, `rover_tracks.gd`

The Apollo Lunar Roving Vehicle, put down beside a landed LM (`Spaceflight.deploy_rover`, key U; W A S D drive it)
on the surveyed site it landed on ([the ground under a landing](surface.md#the-ground-under-a-landing)). In the site's
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
The damper works on how fast the mount closes on the ground. Under load W, the wheel sinks by Bekker's rigid-wheel
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
series motor. The parking brake sets once the vehicle is nearly still with the controller centred. The vehicle that
put the rover down stands in its way as a cylinder of its own diameter.

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
| Parked on 15°, controller centred | 0.1 m in 20 s | statically stable on the slopes met |
| Roostertail, accelerating from rest | 4.2 m high | about 3 m, Apollo 15 |

The rigid wheel overstates a flexible wire-mesh tyre's sinkage, which is spread over a longer contact. The straight
torque line gives too little torque at low speed. It reaches 10 km/h twice as slowly as the crews did, and it stalls
up 20° (printed by `rovercheck`, not judged), where Apollo 16 climbed with the pitch gauge pegged at 20°.

`groundcheck` drives the LRV off the LM it lands: every wheel stands on the drawn triangles less its sinkage, to the
metre's last digit, and nothing of it is left after the flight.

## Dust

`rover_dust.gd`. A grain leaves the rim at the velocity the rim had there. For a point θ behind the contact, on a wheel
with rim speed u on a vehicle at v, that is v·h + u(−cos θ·h + sin θ·up). Rolling without slip it rises up and
forward, which is why the LRV had dust guards. A slipping wheel throws it back. There is no air, so each grain flies
an exact parabola under the world's g: the roostertail is as high as the rim speed makes it, u²/2g at most. That is
what the crews saw: no billowing. The guards catch what leaves under them, within 0.9 rad of the top. Under air, a
drag rate stands in for a 50 µm grain's (an estimate). Drawing only.

## Tracks

`rover_tracks.gd`. A strip the tread's width along each wheel's contact points, multiplied into the ground's shading
(`shaders/surface/track.gdshader`): the chevrons, and a darker floor the deeper Bekker's sinkage made it. A wheel that
left the ground starts a new strip. Drawing only. The soil does not yet remember being driven over (repetitive
loading compacts it).

Not modelled: rocks, the regolith's density with depth, a tyre's flex, the batteries' charge, a crew standing up.
