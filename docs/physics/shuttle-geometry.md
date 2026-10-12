# The Space Shuttle's lines

`model_sources/blender/shuttle.py` (the authored model) and `sim/flight/shuttlelines.gd`
(the procedural fallback) build the orbiter, external tank and boosters from the same
tables, in the program's own coordinates. Every station is in inches and converted
once.

## Coordinates

| System | Datum | Axes |
|---|---|---|
| Orbiter (Xo, Yo, Zo) | nose tip Xo 236; payload bay axis Zo 400 | +Xo aft, +Yo starboard, +Zo up (landing attitude) |
| Tank (XT) | nose tip XT 322.5; tank axis ZT 400 | +XT aft, +ZT toward the orbiter |
| Booster (XB) | nose tip XB 200; booster axes at Ys ±250.5 | +XB aft |

XS = XT = XB + 543 = Xo + 741, and the orbiter's Zo 400 plane is 336.5 in off the tank
axis (Space Shuttle News Reference, "Space Shuttle coordinate system"). That fixes the
stack: the orbiter's nose is 30.26 m above the tank's aft dome, its payload bay axis
8.55 m off the tank's, and the boosters' nozzle exits 9.28 m below the tank. The stack
stands 55.98 m from nozzle exit to the tank's nose (published: 56.1 m).

Stage datums in `vehicles.gd` are the nozzle exits (boosters), the aft dome (tank) and
the fin tip (orbiter, Xo 1702.2, so its `L` is the published 37.24 m overall length).

## Orbiter

From NASA CR-134087 (DMS-DR-2083), configuration 140A/B, full-scale component tables
and model three-view, unless noted.

| Part | Data |
|---|---|
| Body | Xo 235 → 1528.3 (1293.3 in); 262 in wide at the base, 250 in deep at Xo 1464 |
| Side profile, planform to Xo 505 | digitised from the three-view (scale from its 1293.3 in and 415.72 in dimensions) |
| Payload bay | Xo 582 → 1307, two doors hinged at the sills, opening 175.5° |
| Canopy | Xo 434.6 → 670, 152.4 in wide |
| Wing (W116) | 2690 ft², span 936.68 in, root chord 689.24, tip 137.85, LE 45°, TE −10.06°, dihedral 3.5°, 0.25 MAC at Xo 1136.7 / BL 182.3, t/c 0.113 → 0.12 |
| Wing glove | leading edge meets the body at Xo 505 and the main leading edge at Xo 1003.5 (81°) |
| Elevons (E26) | hinge line unswept at Xo 1387; 0.40 of the chord outboard |
| Vertical tail (V8) | 413.25 ft², span 315.72, root chord 268.5 at WP 500, tip 108.47, LE 45°; 10° / 14.9° double wedge; rudder/speed brake aft of 60% chord |
| Body flap (F7) | Xo 1520 → 1613, 262 in wide, 23 in deep; hinge Xo 1532.3 / Zo 284.3 |
| OMS pods (M7) | Xo 1233 → 1560, 94.5 in wide at Xo 1450, 109 in deep at 1493 |
| OMS engines | gimbal Xo 1518 / Yo ±88 / Zo 492; null 15°49′ pitch-up, 12°17′ outboard |
| SSMEs | gimbals Xo 1445 / Zo 443 and Xo 1468.17 / Yo ±53 / Zo 342.64; engine 1 canted 16° pitch-up, 2 and 3 10° up and 3.5° outboard (NASA TM X-58153) |
| Landing gear | main-gear wells Xo 1040 → 1191 (HAER TX-116); main tyres 44.5 × 16 in, rated 225 kt; main sink rate 9.6 ft/s (JSC-12770 vol. 10D) |

The model three-view's overall checks: span 23.79 m, length 37.24 m, 14.12 m from the
lowest point to the fin tip (NASA's dimension drawing: 23.79, 37.24, 14.12).

Not from a table, and marked so in the code: the payload bay's 17 ft outer width, the
black/white tile boundary heights, the gear pivots and strut lengths, the window
outlines (from the three-view's planform) and the payload (a docking system forward and
a logistics module aft, a station flight).

## External tank

331 in across. Ring frames from HAER TX-116: the LO2 tank's ogive meets its barrel at
XT 745, the barrel ends at 852 (intertank), the intertank at 1123–1129 (LH2 tank), and
the LH2 tank's aft frame is 2058, where the orbiter's aft attach points are. The
forward bipod is at XT 1129.9 under the orbiter's Xo 378 bulkhead.

## Boosters

146 in across, 149.16 ft long. Field joints at XB 851.5, 1171.5 and 1491.5, the tank
attach ring at XB 1511, the aft skirt flaring to 212 in at its foot. The nose cap,
frustum and forward-skirt split is estimated from photographs.
