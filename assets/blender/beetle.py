# ---------------------------------------------------------------------------
# THE BEETLE — the Hail Mary's data-return probe. Four of them ride in her nose.
# ---------------------------------------------------------------------------
# 4.2 m long, 2.4 m across, and its whole design argument is mass ratio: it is
# a one-way courier with no crew and no life support, small enough that the
# rocket equation closes for the trip home when the mothership's does not.
#
# So it is deliberately PLAIN. A ship built by people who had months, not
# years — a pressure hull, a spin drive, an antenna, and nothing else. The one
# thing it shares with the Hail Mary is the drive, because that is the part
# that was already understood.
#
# See common.py for the axis convention: +Z is the nose here.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, tank, box, torus_z, dish, disc, empty, group,
                 finish, smooth, strut, ball, TAU)
from common import build, stage

L, D = 4.2, 2.4
R = D / 2
DR = R * 0.62                       # drive aperture radius


def spin_drive(name, r, parent, loc):
    """
    The same emitter array as the Hail Mary's, one quarter the size.

    NOT a bell: astrophage radiates its energy as light at 4.26 and 18.31 um, so
    there is no gas to expand and nothing for a nozzle contour to do. What the
    shape has to show is a shallow reflector over a plate of emitters — short,
    because there is no expansion to accommodate, and wide, because the emitting
    area is what sets the power.

    The pivot's origin is ON THE EXIT PLANE and its rotation is identity:
    spaceflight.js parents the plume straight to this node, and craftmodel's
    update() drives it by ASSIGNING Euler angles, which wipes any orientation
    set at build time.
    """
    # The outer mount carries the placement; the inner pivot is the node
    # craftmodel drives, and its name must NOT itself start with a binding
    # prefix or it would be collected as a second gimbal.
    mount = empty(f'mount_{name}', loc, parent)
    piv = empty(name, (0, 0, 0), mount)

    neck_z = r * 1.42
    # Reflector: a shallow paraboloid opening aft (-Z), lipped at the rim.
    prof = []
    for i in range(9):
        u = i / 8
        prof.append((r * u, neck_z * (1.0 - u * u) * 0.62))
    prof.append((r * 1.06, -0.02))
    refl = revolve(f'{name}_refl', prof, MM['alu'], seg=40, parent=piv)
    finish(refl, 0.012, 2, 45)

    # Emitter plate, recessed inside the reflector, and the cells on it. They
    # have to be BRIGHT: the face points aft, away from every light in the
    # scene, so it renders black however it is coloured.
    plate = disc(f'{name}_plate', r * 0.90, neck_z * 0.34, MM['emitPlate'],
                 seg=36, parent=piv)
    smooth(plate, 20)
    for ring, count in ((0.30, 6), (0.58, 12), (0.80, 16)):
        for i in range(count):
            a = TAU * i / count + ring * 3.0
            c = revolve(f'{name}_c{ring}_{i}',
                        [(0, 0), (r * 0.075, 0), (r * 0.060, -r * 0.03)],
                        MM['emitCell'], seg=6, parent=piv)
            c.location = (cos(a) * r * ring, sin(a) * r * ring, neck_z * 0.34 - 0.005)

    # The can behind the plate, and the collar that ties it to the hull.
    can = cyl(f'{name}_can', r * 0.82, r * 0.72, neck_z * 0.36, neck_z * 1.15,
              MM['dirty'], seg=28, parent=piv)
    finish(can, 0.010, 2, 45)
    col = torus_z(f'{name}_collar', r * 0.86, r * 0.05, neck_z * 1.10,
                  MM['alu'], seg=28, minor=8, parent=piv)
    smooth(col, 30)
    return piv


MM = {}


def build_beetle(M):
    MM.update(M)
    root = stage('beetle')

    # ---- pressure hull: a capsule, because a sphere is the cheapest pressure
    # vessel and a cylinder is the cheapest thing to pack four of into a nose.
    # Built as a lathe rather than a capsule primitive so the shoulders can be
    # a little fuller than a hemisphere, which is what a welded dome is.
    hz0, hz1 = L * 0.16, L * 0.92
    prof = [(0.0, hz0 - R * 0.86)]
    for i in range(1, 9):
        a = (i / 8) * pi / 2
        prof.append((R * sin(a), hz0 - R * 0.86 * cos(a)))
    prof.append((R, hz1 - R * 0.86))
    for i in range(1, 9):
        a = (i / 8) * pi / 2
        prof.append((R * cos(a), hz1 - R * 0.86 + R * 0.86 * sin(a)))
    hull = revolve('hull', prof, M['dirty'], seg=56, parent=root)
    finish(hull, 0.018, 2, 40)

    # Four hoop frames. On a hull this plain they are most of the read — they
    # are what says "pressure vessel" rather than "tube".
    for k in range(4):
        r_ = torus_z(f'frame{k}', R * 1.015, D * 0.020, L * (0.28 + k * 0.17),
                     M['alu'], seg=40, minor=8, parent=root)
        smooth(r_, 30)

    # A single longitudinal raceway for the harness, opposite the antenna.
    ray = box('raceway', (D * 0.11, D * 0.07, L * 0.60),
              (-R * 0.99, 0, L * 0.52), M['dirty'], parent=root)
    finish(ray, 0.012, 2, 40)

    # ---- the drive. One, on the axis: the beetle steers by attitude, not by
    # differential power, because there is only one of it.
    spin_drive('gimbal_beetle_0', DR, root, (0, 0, DR * 1.42 * 1.0))

    # The aft skirt the drive hangs in, tapering out of the hull.
    skirt = cyl('skirt', R * 0.62, R * 0.98, DR * 1.42, hz0 + R * 0.10,
                M['dirty'], seg=40, parent=root)
    finish(skirt, 0.014, 2, 45)

    # ---- high-gain antenna, canted off the shoulder. The beetle's entire
    # purpose is to arrive and TRANSMIT, so the dish is not a detail on it —
    # it is the payload, and everything else is a bus for it.
    arm = empty('hga', (R * 0.72, 0, L * 0.80), root)
    arm.rotation_euler = (0, 1.20, 0)
    d = dish('hga_dish', D * 0.34, M['white'], seg=32, parent=arm)
    finish(d, 0.008, 2, 40)
    strut('hga_boom', (0, 0, -D * 0.30), (0, 0, 0), 0.035, M['alu'], seg=6, parent=arm)
    # The feed at the focus, which is what makes a dish read as an antenna
    # rather than as a bowl.
    fd = revolve('hga_feed', [(0.05, D * 0.10), (0.05, D * 0.20), (0.09, D * 0.22)],
                 M['dirty'], seg=10, parent=arm)
    smooth(fd, 30)

    # ---- star tracker and the two radiator strips. Small, and they break up
    # 4 m of plain cylinder more than anything else this size would.
    st = box('startracker', (0.22, 0.22, 0.30), (0, R * 0.92, L * 0.86),
             M['black'], parent=root)
    finish(st, 0.010, 2, 40)
    for sgn in (-1, 1):
        rad = box(f'rad{sgn}', (0.05, D * 0.44, L * 0.34),
                  (sgn * R * 1.02, 0, L * 0.50), M['white'], parent=root)
        finish(rad, 0.008, 2, 40)


build('beetle', build_beetle)
