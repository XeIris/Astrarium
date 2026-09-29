# ---------------------------------------------------------------------------
# ION CRUISER (Dawn-class) — the interplanetary workhorse.
# ---------------------------------------------------------------------------
# 237 mN of thrust, a tenth the weight of a postcard, held for months at a
# time. Everything about the shape follows from that: there is no thrust
# structure worth the name, no tankage worth the name, and 19.7 m of solar
# array carrying a 1.64 m bus — because on this vehicle the power system IS the
# propulsion system and the bus is a rounding error hung between the wings.
#
# The arrays are DEPLOYABLES and go in `array_*`, which craftmodel's update()
# holds folded until the flight state asks. Radiators and dishes must not: a
# ship that flies with its heat rejection stowed is a ship that cooks.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, box, torus_z, dish, disc, empty, finish, smooth,
                 strut, solar_array, ball, TAU)
from common import build, stage

BUS_W, BUS_H = 1.64, 1.36          # the bus is 1.64 x 1.36 x 1.64 m
BUS_Z = 0.9                        # its centre, matching the procedural build


def build_ioncruiser(M):
    root = stage('bus')

    # ---- the bus: a gold-blanketed box. Multi-layer insulation is not a
    # colour choice, it is the reason a spacecraft this far from the Sun keeps
    # its propellant liquid, and it is the only warm thing in the frame.
    bus = box('bus', (BUS_W, BUS_W, BUS_H), (0, 0, BUS_Z), M['gold'], parent=root)
    finish(bus, 0.03, 2, 40)
    # MLI is quilted, not smooth. A few tension seams across each face do more
    # for the read than any amount of surface detail, because they are what
    # makes it look like fabric over a frame rather than a painted solid.
    for i in (-1, 0, 1):
        for ax in (0, 1):
            sz = (BUS_W * 1.01, 0.035, 0.035) if ax else (0.035, BUS_W * 1.01, 0.035)
            box(f'seam{ax}{i}', sz, (0, 0, BUS_Z + i * BUS_H * 0.30),
                M['dirty'], parent=root)
    # Corner longerons: the load path from the launch vehicle adapter to the
    # array yokes, and the only structure on the vehicle that carries real load.
    for sx in (-1, 1):
        for sy in (-1, 1):
            box(f'long{sx}{sy}', (0.07, 0.07, BUS_H * 1.02),
                (sx * BUS_W * 0.5, sy * BUS_W * 0.5, BUS_Z), M['alu'], parent=root)

    # ---- the launch adapter cone under it, which is also what it stands on.
    ad = cyl('adapter', BUS_W * 0.30, BUS_W * 0.46, 0.0, BUS_Z - BUS_H / 2,
             M['alu'], seg=24, parent=root)
    finish(ad, 0.02, 2, 45)

    # ---- solar arrays. 19.7 m tip to tip, 36.4 m^2, and at Ceres they return
    # about a tenth of what they do at Earth — which is the constraint the whole
    # mission profile is built around.
    for k, sgn in enumerate((1, -1)):
        arm = empty(f'array_bus_{k}', (sgn * (BUS_W / 2 + 0.10), 0, BUS_Z), root)
        # The yoke, then the panel outboard of it. The panel's own group sits at
        # +X in the arm's frame so the arm rotates it about the bus like a real
        # hinge — update() drives `array_*` and nothing else here moves.
        strut(f'yoke{k}', (0, 0, 0), (sgn * 0.55, 0, 0), 0.05, M['alu'], seg=8, parent=arm)
        pan = solar_array(f'panel{k}', 8.3, 2.2, M['solar'], M['alu'], parent=arm)
        pan.location = (sgn * (0.55 + 8.3 / 2), 0, 0)
        # Cell blocks, so the wing is not one flat sheet of blue. Real arrays
        # are a grid of strings with gaps at every substrate joint.
        for i in range(4):
            box(f'gap{k}_{i}', (0.06, 2.24, 0.07),
                (sgn * (0.55 + 8.3 * (i + 1) / 5), 0, 0), M['alu'], parent=arm)

    # ---- high-gain antenna, on the +Z face. 1.64 m dish for the 8.4 GHz
    # downlink; at Vesta it is doing about 120 kbit/s and that is the mission.
    d = dish('hga', 0.82, M['white'], seg=32, parent=root)
    d.location = (0, 0, BUS_Z + BUS_H / 2)
    finish(d, 0.012, 2, 40)
    strut('hga_feed', (0, 0, BUS_Z + BUS_H / 2 + 0.10),
          (0, 0, BUS_Z + BUS_H / 2 + 0.56), 0.03, M['dirty'], seg=8, parent=root)
    fd = ball('hga_horn', 0.09, (0, 0, BUS_Z + BUS_H / 2 + 0.58), M['dirty'],
              seg=12, rings=8, parent=root)
    smooth(fd, 30)
    # The two low-gain horns, which are what it talks through when it has lost
    # attitude and cannot point the dish. Small, and the reason a mission
    # survives a safe-mode.
    for sgn in (-1, 1):
        lg = revolve(f'lga{sgn}', [(0.05, 0), (0.05, 0.16), (0.12, 0.30)],
                     M['dirty'], seg=12, parent=root)
        lg.location = (sgn * BUS_W * 0.34, BUS_W * 0.52, BUS_Z + BUS_H * 0.30)
        lg.rotation_euler = (-pi / 2, 0, 0)

    # ---- xenon tank, visible through the open bay on the -Y face. 425 kg of
    # xenon at 100 bar is a sphere, and it is most of the vehicle's dry volume.
    xt = ball('xenon', 0.44, (0, -BUS_W * 0.10, BUS_Z), M['steel'], seg=24,
              rings=14, parent=root)
    smooth(xt, 30)

    # ---- three NEXT gridded ion thrusters, on a shallow aft ring. They are
    # SMALL and they should look it: 0.36 m across, and each one is a quarter of
    # a newton. Drawing them at chemical-engine scale is the single easiest way
    # to make this vehicle lie about what it is.
    for i in range(3):
        a = i / 3 * TAU
        piv = empty(f'gimbal_bus_{i}', (cos(a) * 0.42, sin(a) * 0.42, 0.10), root)
        # The discharge chamber, then the grids. The grids are the engine: two
        # perforated molybdenum discs a millimetre apart holding 1 800 V.
        ch = cyl(f'ion{i}_ch', 0.18, 0.16, -0.32, 0.0, M['nozzle'], seg=20, parent=piv)
        finish(ch, 0.008, 2, 45)
        gr = disc(f'ion{i}_grid', 0.17, -0.33, M['black'], seg=20, parent=piv)
        smooth(gr, 20)
        # The magnetic-circuit ring and the neutraliser cathode beside it.
        rg = torus_z(f'ion{i}_ring', 0.185, 0.022, -0.30, M['alu'], seg=20,
                     minor=6, parent=piv)
        smooth(rg, 30)
        nc = cyl(f'ion{i}_neut', 0.03, 0.03, -0.30, -0.10, M['dirty'], seg=8, parent=piv)
        nc.location = (0.22, 0, 0)

    # ---- the star trackers and the framing camera, which is the payload.
    for sgn in (-1, 1):
        st = box(f'startracker{sgn}', (0.18, 0.18, 0.24),
                 (sgn * BUS_W * 0.30, -BUS_W * 0.52, BUS_Z + BUS_H * 0.36),
                 M['black'], parent=root)
        finish(st, 0.01, 2, 40)
    cam = cyl('camera', 0.13, 0.13, 0, 0.34, M['black'], seg=16, parent=root)
    cam.location = (BUS_W * 0.30, -BUS_W * 0.62, BUS_Z)
    cam.rotation_euler = (pi / 2, 0, 0)


build('ioncruiser', build_ioncruiser)
