# ---------------------------------------------------------------------------
# THE BEETLE — the Hail Mary's data-return probe. Four of them ride in her nose.
# ---------------------------------------------------------------------------
# 4.2 m long, 2.4 m across, and its whole design argument is mass ratio: it is
# a one-way courier with no crew and no life support, small enough that the
# rocket equation closes for the trip home when the mothership's does not.
#
# PLAIN IS NOT THE SAME AS BARE. The first pass took "built by people who had
# months, not years" as licence to draw a grey cylinder with four hoops on it,
# and a grey cylinder with four hoops on it is not a spacecraft — it is a
# barrel. What makes a small probe read is the hardware a small probe cannot do
# without and cannot hide: a high-gain antenna big enough to close the link over
# four light years, thermal blanket where the hull is warm and radiator where it
# is not, thrusters in clusters far enough apart to give a moment arm, a star
# tracker with a sun shade, and the tank and the drive it spends its whole
# journey burning. Every one of those is load-bearing on the design; none of
# them is decoration; and together they are what says this thing was built to
# cross interstellar space and TRANSMIT at the far end.
#
# See common.py for the axis convention: +Z is the nose here.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, dish, disc, empty, group,
                 finish, smooth, strut, ball, ring_on, TAU)
from common import build, stage

L, D = 4.2, 2.4
R = D / 2
DR = R * 0.46                       # drive aperture radius
NECK = DR * 1.42                    # drive neck height

# ---------------------------------------------------------------------------
# THE STACK, bottom up, because a 4.2 m vehicle has no room for anything to be
# approximately anywhere. z = 0 is the DRIVE EXIT PLANE — the drive is the aft
# end of the probe, not a part buried in the middle of it, and the first pass
# had the propellant tank hanging BELOW the emitter array where the exhaust
# goes.
# ---------------------------------------------------------------------------
CAN_Z = NECK * 1.15                 # top of the emitter can
CAP = R * 0.42                      # dome depth: a shallow welded head, not
HZ0, HZ1 = 1.55, 3.70               # a hemisphere — the barrel is the vehicle
SK_Z = 1.30                         # where the aft skirt meets the lower dome


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

    # Reflector: a shallow paraboloid opening aft (-Z), lipped at the rim.
    prof = [(r * (i / 8), NECK * (1.0 - (i / 8) ** 2) * 0.62) for i in range(9)]
    prof.append((r * 1.06, -0.02))
    refl = revolve(f'{name}_refl', prof, MM['alu'], seg=40, parent=piv)
    finish(refl, 0.012, 2, 45)
    lip = ring_on((0, 0, -0.01), (0, 0, 1), r * 1.05, r * 0.055, MM['alu'],
                  f'{name}_lip', seg=40, minor=10, parent=piv)
    smooth(lip, 30)

    # Emitter plate, recessed inside the reflector, and the cells on it. They
    # have to be BRIGHT: the face points aft, away from every light in the
    # scene, so it renders black however it is coloured.
    plate = revolve(f'{name}_plate',
                    [(0, NECK * 0.34), (r * 0.90, NECK * 0.34),
                     (r * 0.90, NECK * 0.40), (0, NECK * 0.40)],
                    MM['emitPlate'], seg=36, parent=piv)
    smooth(plate, 20)
    for ring, count in ((0.30, 6), (0.58, 12), (0.80, 16)):
        for i in range(count):
            a = TAU * i / count + ring * 3.0
            c = revolve(f'{name}_c{ring}_{i}',
                        [(0, 0), (r * 0.075, 0), (r * 0.075, r * 0.030),
                         (r * 0.055, r * 0.045), (0, r * 0.045)],
                        MM['emitCell'], seg=8, parent=piv)
            c.location = (cos(a) * r * ring, sin(a) * r * ring, NECK * 0.33)
            finish(c, 0.004, 2, 45)

    # The can behind the plate, the collar that ties it to the hull, and the
    # fasteners round it — hardware at a size the eye can measure the probe
    # against, which on a 4 m vehicle is most of what scale there is.
    can = cyl(f'{name}_can', r * 0.82, r * 0.72, NECK * 0.40, NECK * 1.15,
              MM['dirty'], seg=28, parent=piv)
    finish(can, 0.010, 2, 45)
    col = torus_z(f'{name}_collar', r * 0.86, r * 0.05, NECK * 1.08,
                  MM['alu'], seg=28, minor=8, parent=piv)
    smooth(col, 30)
    for i in range(12):
        a = i / 12 * TAU
        bo = revolve(f'{name}_bolt{i}', [(0, 0), (r * 0.045, 0),
                                         (r * 0.045, r * 0.035), (0, r * 0.035)],
                     MM['steel'], seg=6, parent=piv)
        bo.location = (cos(a) * r * 0.88, sin(a) * r * 0.88, NECK * 1.14)
        finish(bo, 0.004, 2, 45)
    return piv


MM = {}


def build_beetle(M):
    MM.update(M)
    root = stage('beetle')

    # ---- pressure hull: a capsule, because a sphere is the cheapest pressure
    # vessel and a cylinder is the cheapest thing to pack four of into a nose.
    # Built as a lathe rather than a capsule primitive so the shoulders can be
    # a little fuller than a hemisphere, which is what a welded dome is.
    prof = [(0.0, HZ0 - CAP)]
    for i in range(1, 9):
        a = (i / 8) * pi / 2
        prof.append((R * sin(a), HZ0 - CAP * cos(a)))
    prof.append((R, HZ1))
    for i in range(1, 9):
        a = (i / 8) * pi / 2
        prof.append((R * cos(a), HZ1 + CAP * sin(a)))
    hull = revolve('hull', prof, M['dirty'], seg=56, parent=root)
    finish(hull, 0.018, 2, 40)

    # Hoop frames. On a hull this plain they are most of the read — they are
    # what says "pressure vessel" rather than "tube".
    for k in range(4):
        r_ = torus_z(f'frame{k}', R * 1.015, D * 0.018, HZ0 + (HZ1 - HZ0) * (k + 0.5) / 4,
                     M['alu'], seg=40, minor=8, parent=root)
        smooth(r_, 30)

    # ---- MLI. Gold blanket over the warm forward bay where the transmitter and
    # the batteries are. Its seams are the tape over the stitching, spaced far
    # enough apart to read as a blanket rather than as a birdcage.
    bl0, bl1 = HZ0 + (HZ1 - HZ0) * 0.52, HZ1 + CAP * 0.62
    bl = lathe('mli', [(R * 1.020, bl0), (R * 1.032, bl0 + 0.10),
                       (R * 1.024, (bl0 + bl1) / 2), (R * 1.032, bl1 - 0.20),
                       (R * 0.84, bl1)], M['gold'], seg=48, parent=root)
    smooth(bl, 25)
    for k in range(8):
        a = k / 8 * TAU + 0.2
        q = strut(f'mliseam{k}', (cos(a) * R * 1.027, sin(a) * R * 1.027, bl0 + 0.05),
                  (cos(a) * R * 1.027, sin(a) * R * 1.027, bl1 - 0.22),
                  0.009, M['alu'], seg=5, parent=root)
        smooth(q, 30)

    # A longitudinal raceway for the harness, and the two umbilical connectors
    # on it. The raceway is the only straight line on a hull of curves.
    ray = box('raceway', (D * 0.07, D * 0.13, 1.60), (-R * 1.03, 0, 2.62),
              M['dirty'], parent=root)
    finish(ray, 0.014, 2, 40)
    for k in range(2):
        u = revolve(f'umbilical{k}', [(0, 0), (0.085, 0), (0.085, 0.11), (0, 0.11)],
                    M['alu'], seg=12, parent=root)
        u.rotation_euler = (0, -pi / 2, 0)
        u.location = (-R * 1.12, 0, 2.10 + 1.00 * k)
        finish(u, 0.010, 2, 40)

    # ---- the astrophage bay: the dark band at the base of the barrel, between
    # the pressure hull and the drive. It is a third of the vehicle's mass and
    # it has nowhere to hide, so it is drawn as what it is rather than tucked
    # out of sight — with the fill and drain couplings on it.
    bay = cyl('fuelbay', R * 1.005, R * 1.005, HZ0 + 0.02, HZ0 + 0.56,
              M['soot'], seg=48, parent=root)
    finish(bay, 0.012, 2, 40)
    for k in range(3):
        a = k / 3 * TAU + 0.9
        c = revolve(f'fill{k}', [(0, 0), (0.075, 0), (0.075, 0.10), (0, 0.10)],
                    M['alu'], seg=10, parent=root)
        c.rotation_euler = (0, pi / 2, -a)
        c.location = (cos(a) * R * 1.03, sin(a) * R * 1.03, HZ0 + 0.29)
        finish(c, 0.008, 2, 40)

    # ---- the drive, on the axis at the aft end: the beetle steers by
    # attitude, not by differential power, because there is only one of it.
    spin_drive('gimbal_beetle_0', DR, root, (0, 0, 0))

    # The aft skirt, which fairs the drive can out to the barrel and hides the
    # hull's lower dome inside itself, and four thrust struts through it so the
    # drive is carried by something.
    skirt = cyl('skirt', DR * 1.15, R * 0.92, CAN_Z * 0.94, SK_Z,
                M['dirty'], seg=40, parent=root)
    finish(skirt, 0.014, 2, 45)
    for k in range(4):
        a = k / 4 * TAU + pi / 4
        strut(f'thruststrut{k}',
              (cos(a) * DR * 0.95, sin(a) * DR * 0.95, CAN_Z * 0.95),
              (cos(a) * R * 0.74, sin(a) * R * 0.74, SK_Z + 0.02),
              0.042, M['alu'], seg=6, parent=root)

    # ---- HIGH-GAIN ANTENNA. The beetle's entire purpose is to arrive and
    # TRANSMIT, so the dish is not a detail on it — it is the payload, and
    # everything else is a bus for it. On a two-axis gimbal, on a boom that
    # stands it clear of the hull, and OPENING FORWARD: a paraboloid radiates
    # along its own +Z, and the first version had that axis tipped back into the
    # hull it is bolted to, so the probe crossed four light years aiming its
    # only transmitter at its own tank.
    yoke = group('hga', root, loc=(R * 0.98, 0, HZ1 - 0.30), rot_z=0.0)
    strut('hga_boom', (-R * 0.26, 0, 0), (D * 0.19, 0, 0), 0.05, M['alu'],
          seg=8, parent=yoke)
    gim = revolve('hga_gimbal', [(0, -0.10), (0.13, -0.10), (0.13, 0.10), (0, 0.10)],
                  M['dirty'], seg=14, parent=yoke)
    gim.rotation_euler = (pi / 2, 0, 0)
    gim.location = (D * 0.19, 0, 0)
    finish(gim, 0.010, 2, 40)

    aim = empty('hga_aim', (D * 0.19, 0, 0), yoke)
    aim.rotation_euler = (0, 0.62, 0)          # outboard and AHEAD
    rd = D * 0.33
    d = revolve('hga_dish', [(rd * (i / 12), rd * 0.30 * (i / 12) ** 2) for i in range(13)],
                M['white'], seg=36, parent=aim)
    finish(d, 0.008, 2, 40)
    # The backing structure, which lives BEHIND the reflector — at lower z than
    # the surface at the same radius, since the dish opens along +Z. Level with
    # it, the ribs are not ribs: they are spars straight across the aperture.
    def back_z(u):
        return rd * (0.30 * u * u - 0.075)
    finish(revolve('hga_back', [(0, back_z(0)), (rd * 0.36, back_z(0.36)),
                                (rd * 0.74, back_z(0.74)), (rd * 0.99, back_z(0.99))],
                   M['dirty'], seg=36, parent=aim), bevel_w=0.008)
    for k in range(8):
        a = k / 8 * TAU
        strut(f'hga_rib{k}', (0, 0, back_z(0) - rd * 0.05),
              (cos(a) * rd * 0.95, sin(a) * rd * 0.95, back_z(0.95)),
              0.020, M['alu'], seg=5, parent=aim)
    # The feed at the focus on its tripod, which is what makes a dish read as
    # an antenna rather than as a bowl.
    fd = revolve('hga_feed', [(0, rd * 0.76), (rd * 0.11, rd * 0.79),
                              (rd * 0.14, rd * 0.90), (0, rd * 0.90)],
                 M['dirty'], seg=14, parent=aim)
    finish(fd, 0.006, 2, 40)
    for k in range(3):
        a = k / 3 * TAU + 0.5
        strut(f'hga_feedleg{k}',
              (cos(a) * rd * 0.88, sin(a) * rd * 0.88, rd * 0.30 * 0.88 ** 2),
              (cos(a) * rd * 0.07, sin(a) * rd * 0.07, rd * 0.79),
              0.015, M['alu'], seg=5, parent=aim)
    # The low-gain backup, a plain horn on the nose. It is what you have left
    # when the gimbal jams, so it points where the vehicle points.
    lga = revolve('lga', [(0.05, HZ1 + CAP * 0.96), (0.05, HZ1 + CAP + 0.16),
                          (0.17, HZ1 + CAP + 0.30)], M['alu'], seg=16, parent=root)
    smooth(lga, 30)

    # ---- star tracker under a sun shade, on the cold side. Without an attitude
    # reference a probe that steers by attitude cannot steer at all.
    stm = group('startracker', root, loc=(0, R * 0.99, HZ1 - 0.16), rot_z=pi / 2)
    finish(box('st_body', (0.26, 0.26, 0.32), (0.10, 0, 0), M['black'], parent=stm),
           bevel_w=0.010)
    sh = revolve('st_shade', [(0.15, 0), (0.15, 0.28), (0.21, 0.44)],
                 M['soot'], seg=18, parent=stm)
    sh.rotation_euler = (0, pi / 2, 0)
    sh.location = (0.23, 0, 0)
    smooth(sh, 30)

    # ---- two radiator wings, standing OFF the hull on brackets. Flush to the
    # skin they radiate into the hull they are cooling, which is why a real one
    # is always held clear — and it is the standoff, not the panel, that makes
    # them read as radiators rather than as painted stripes.
    for sgn in (-1, 1):
        rad = group(f'rad{sgn}', root, loc=(0, 0, 2.78),
                    rot_z=(pi / 2 if sgn > 0 else -pi / 2))
        finish(box(f'rad{sgn}_panel', (0.05, D * 0.36, 1.30),
                   (R + 0.30, 0, 0), M['white'], parent=rad), bevel_w=0.008)
        for k in range(6):
            finish(box(f'rad{sgn}_fin{k}', (0.075, D * 0.33, 0.032),
                       (R + 0.30, 0, -0.65 + 1.30 * (k + 0.5) / 6),
                       M['soot'], parent=rad), bevel_w=0.006)
        for s2 in (-1, 1):
            strut(f'rad{sgn}_arm{s2}', (R * 0.99, s2 * D * 0.13, 0),
                  (R + 0.28, s2 * D * 0.13, 0), 0.042, M['alu'], seg=6, parent=rad)

    # ---- attitude control: two rings of clusters as far apart as the hull
    # allows, three nozzles each. The moment arm is the whole point, so they go
    # on the shoulders rather than tidily amidships.
    for k in range(4):
        a = k / 4 * TAU + pi / 4
        for zq, tag in ((HZ1 - 0.10, 'f'), (HZ0 + 0.78, 'a')):
            q = empty(f'rcs{tag}{k}', (cos(a) * R * 1.01, sin(a) * R * 1.01, zq), root)
            q.rotation_euler = (0, 0, a)
            finish(box(f'rcs{tag}{k}_b', (0.16, 0.24, 0.24), (0.06, 0, 0),
                       M['dirty'], parent=q), bevel_w=0.010)
            for j, rot in enumerate(((0, 0, 0), (pi, 0, 0), (0, pi / 2, 0))):
                n = revolve(f'rcs{tag}{k}_n{j}', [(0, 0), (0.038, 0), (0.022, 0.09)],
                            M['nozzle'], seg=8, parent=q)
                n.rotation_euler = rot
                n.location = ((0.06, 0, 0.13), (0.06, 0, -0.13), (0.17, 0, 0))[j]


build('beetle', build_beetle)
