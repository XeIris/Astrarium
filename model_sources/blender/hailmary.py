# THE HAIL MARY, the Blender build (model_sources/blender/build.sh), after the 2026
# film's ship: three tanks in a triangle round a central drive drum, a train of crew
# modules standing forward of the drum between them, and two long solar wings astern.
# Each tank tapers aft through an S-bend to its own drive beside the drum. The
# proportions are measured off the film's concept art and stills; a suited figure
# on a module in one still sets the scale (modules ~6 m across, 104 m overall). The
# procedural build in craftmodel.gd is the fallback, from the same LAYOUT.
#
# Stack axis +Z (the exporter makes it Y-up), nose toward +Z; z = 0 is the drive
# exit plane. Metres.
import bpy, sys, os, math
from math import cos, sin, pi
from mathutils import Vector

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from common import build, stage, vehicle_stages

S = vehicle_stages("hailmary")
from lib import (material, revolve, tube, ring_on, box, strut, fin, finish, empty,
                 group, disc, dish, TAU)

# THE LAYOUT, in metres at the film's 104 m; `k` scales it to the catalogue's L.
# Identical to build_hail_mary() in sim/flight/craftmodel.gd.
L, D = S["hm"]["L"], S["hm"]["D"]
k = L / 104.0
TR = 11.4 * k             # tank centreline off the axis
TANK_R = 4.0 * k
TAPER_Z = 29.4 * k        # where a barrel starts to taper aft
TANK_TOP = 100.0 * k
TIP_X, TIP_Z, TIP_R = 6.6 * k, 1.6 * k, 1.45 * k     # each tank's aft end, over its drive
BAY = (42.7 * k, 51.5 * k)                           # the open truss bay, core exposed
CORE_R = 2.6 * k
DRUM_R, DRUM_Z0, DRUM_Z1 = 5.0 * k, 9.5 * k, 34.0 * k
DR = 0.82 * k             # a tank drive's aperture radius
DR0 = 1.1 * k             # the central drive's
UNIT_RING, UNIT_R = 2.9 * k, 0.75 * k                # thrust units round the central drive
WING_Z, WING_R0, WING_R1 = (5.5 * k, 13.9 * k, 15.6 * k, 24.0 * k), 15.0 * k, 52.0 * k
# The crew stack: (z0, z1, radius, material, kind), stern to bow.
MODULES = [(35.0, 42.0, 4.0, 'white', 'hub'), (42.0, 44.6, 2.6, 'gold', 'plain'),
           (44.6, 47.5, 2.1, 'alu', 'node'), (47.5, 54.0, 3.1, 'white', 'ringed'),
           (54.0, 55.6, 2.2, 'dirty', 'plain'), (55.6, 62.3, 3.0, 'white', 'quilt'),
           (62.3, 67.5, 3.0, 'white', 'berth'), (67.5, 77.8, 3.0, 'white', 'banded'),
           (77.8, 83.4, 2.1, 'white', 'plain'), (83.4, 86.0, 2.35, 'soot', 'plain'),
           (86.0, 93.4, 2.3, 'white', 'greeble'), (93.4, 100.6, 2.3, 'white', 'hatch'),
           (100.6, 104.0, 2.3, 'alu', 'dock')]


def taper_path(n=40):
    """A tank's centreline, bow to stern: straight down the barrel, then an S-bend in
       to the drive, vertical at both ends so the barrel and the drive stay square."""
    pts = []
    for i in range(24):
        z = TANK_TOP + (TAPER_Z - TANK_TOP) * i / 24
        pts.append((TR, 0.0, z))
    for i in range(n + 1):
        t = 1.0 - i / n                         # 1 at the barrel, 0 at the tip
        s = t * t * (3 - 2 * t)
        pts.append((TIP_X + (TR - TIP_X) * s, 0.0, TIP_Z + (TAPER_Z - TIP_Z) * t))
    return pts


def tank_radius(z):
    """The skin's radius at height z: the barrel, the waist of the truss bay, and the
       taper, slightly full, down to the tip."""
    if z >= TAPER_Z:
        w0, w1 = BAY
        if w0 < z < w1:
            e = min(z - w0, w1 - z) / (0.8 * k)
            return TANK_R + (CORE_R - TANK_R) * min(e, 1.0)
        return TANK_R
    t = max((z - TIP_Z) / (TAPER_Z - TIP_Z), 0.0)
    return TIP_R + (TANK_R - TIP_R) * t ** 0.85


# MATERIALS
M = {}
def build_materials():
    M['white']  = material('white',  (0.86, 0.86, 0.88), 0.62, 0.04)
    M['dirty']  = material('dirty',  (0.60, 0.60, 0.63), 0.78, 0.05)
    M['alu']    = material('alu',    (0.42, 0.45, 0.48), 0.40, 0.30)
    M['steel']  = material('steel',  (0.55, 0.59, 0.63), 0.30, 0.32)
    M['gold']   = material('gold',   (0.62, 0.40, 0.09), 0.46, 0.35)
    M['soot']   = material('soot',   (0.045, 0.045, 0.055), 0.80, 0.03)
    M['nozzle'] = material('nozzle', (0.16, 0.155, 0.145), 0.38, 0.30)
    M['solar']  = material('solar',  (0.016, 0.030, 0.13), 0.28, 0.22)
    M['glass']  = material('glass',  (0.01, 0.02, 0.035), 0.10, 0.20)
    # Emitters light themselves at HDR values (the drive faces point away from every
    # light). Astrophage fires in the infrared, so the visible tail is deep red.
    M['emitPlate'] = material('emitPlate', (0.10, 0.09, 0.085), 0.52, 0.15,
                              emit=(0.55, 0.17, 0.07), emit_strength=1.4)
    M['emitCell']  = material('emitCell',  (0.05, 0.02, 0.015), 0.45, 0.08,
                              emit=(1.0, 0.38, 0.15), emit_strength=3.2)


# THE SPIN DRIVE
def spin_drive(name, R, parent, loc, tag):
    """
    A spin drive, not a bell: Astrophage radiates its energy as light, so there is
    no gas to expand. A plate of emitters behind a shallow reflector, short and small
    (thrust is P/c). The pivot's origin is on the exit plane, where the plume
    parents, and its rotation is identity, as craftmodel's update() requires.
    """
    piv = empty(name, loc, parent)
    name = tag
    neck_z = R * 1.42
    top_z = neck_z + R * 0.62
    prof = [(R * (1 - 0.42 * (i / 16) ** 2), R * 1.05 * i / 16) for i in range(17)]
    prof.append((R * 0.58, neck_z))
    finish(revolve(name + '_reflector', prof, M['nozzle'], seg=64, parent=piv), bevel_w=0.012)
    finish(ring_on((0, 0, 0), (0, 0, 1), R, R * 0.055, M['alu'], name + '_lip',
                   seg=64, minor=12, parent=piv), bevel_w=0.006)
    pr, pz = R * 0.80, R * 0.55
    finish(revolve(name + '_plate', [(0, pz), (pr, pz), (pr, pz + R * 0.07), (0, pz + R * 0.07)],
                   M['emitPlate'], seg=48, parent=piv), bevel_w=0.008)
    for ring in range(1, 4):
        rr, cnt = pr * 0.27 * ring, 6 * ring
        for j in range(cnt):
            b = j / cnt * TAU + ring * 0.4
            c = revolve(f'{name}_cell{ring}_{j}',
                        [(0, 0), (pr * 0.105, 0), (pr * 0.105, R * 0.045), (0, R * 0.045)],
                        M['emitCell'], seg=6, parent=piv)
            c.location = (cos(b) * rr, sin(b) * rr, pz - R * 0.01)
    for i in range(12):
        finish(fin(f'{name}_rib{i}', prof[2:], i / 12 * TAU, R * 0.085, R * 0.055,
                   M['alu'], parent=piv), bevel_w=0.006)
    finish(revolve(name + '_can', [(0, neck_z), (R * 0.58, neck_z), (R * 0.64, neck_z + R * 0.06),
                                   (R * 0.64, top_z), (0, top_z)], M['dirty'], seg=48, parent=piv),
           bevel_w=0.010)
    finish(ring_on((0, 0, neck_z + R * 0.12), (0, 0, 1), R * 0.66, R * 0.05, M['alu'],
                   name + '_collar', seg=48, minor=10, parent=piv), bevel_w=0.006)
    return piv


# A TANK
def build_tank(idx, root):
    a = idx / 3 * TAU + pi / 2
    g = group(f'tank{idx}', root, rot_z=a)
    pts = taper_path()
    # Panel grooves every 4 m of barrel and round the taper: the skin dips at each joint.
    def rfun(i, j, ang):
        z = pts[i][2]
        r = tank_radius(z)
        if z > TAPER_Z:
            d = abs(((z - TAPER_Z) / (4.0 * k) + 0.5) % 1.0 - 0.5) * 4.0 * k
            if d < 0.14 * k:
                r -= TANK_R * 0.018 * (1 - (d / (0.14 * k)) ** 2)
        for s in range(6):
            da = abs(((ang - s * TAU / 6 + pi) % TAU) - pi)
            if da < 0.06:
                r -= r * 0.012 * (1 - (da / 0.06) ** 2)
        return r
    finish(tube(f'tank{idx}_skin', pts, TANK_R, M['white'], seg=96, parent=g, rfun=rfun),
           bevel_w=0.010)
    # The forward end: a narrower cap ring and a shallow dome, closing the vessel.
    cap_r = TANK_R * 0.93
    top = [(TANK_R * 0.999, TANK_TOP), (cap_r, TANK_TOP + 0.25 * k), (cap_r, TANK_TOP + 1.0 * k)]
    for i in range(1, 9):
        u = i / 8 * pi / 2
        top.append((cap_r * cos(u), TANK_TOP + 1.0 * k + 0.7 * k * sin(u)))
    cap = revolve(f'tank{idx}_cap', top, M['dirty'], seg=72, parent=g)
    cap.location = (TR, 0, 0)
    finish(cap, bevel_w=0.012)
    def band(name, z0, z1, mat, grow=1.012):
        b = revolve(name, [(TANK_R * grow, z0), (TANK_R * grow * 1.004, (z0 + z1) / 2), (TANK_R * grow, z1)],
                    mat, seg=96, parent=g)
        b.location = (TR, 0, 0)
        finish(b, bevel_w=0.006)
    band(f'tank{idx}_soot', 57.7 * k, 61.8 * k, M['soot'])
    band(f'tank{idx}_mli', 87.0 * k, 89.6 * k, M['gold'], 1.016)
    band(f'tank{idx}_cuff', 94.0 * k, 94.6 * k, M['soot'])
    band(f'tank{idx}_box', 36.6 * k, 42.7 * k, M['dirty'], 1.006)
    # The collar where the taper starts, with its lattice.
    finish(ring_on((TR, 0, TAPER_Z + 0.2 * k), (0, 0, 1), TANK_R * 1.03, 0.16 * k, M['alu'],
                   f'tank{idx}_collar0', seg=96, minor=10, parent=g), bevel_w=0.006)
    finish(ring_on((TR, 0, 33.0 * k), (0, 0, 1), TANK_R * 1.03, 0.16 * k, M['alu'],
                   f'tank{idx}_collar1', seg=96, minor=10, parent=g), bevel_w=0.006)
    for s in range(16):
        a0 = s / 16 * TAU
        a1 = a0 + TAU / 16
        p0 = (TR + cos(a0) * TANK_R * 1.03, sin(a0) * TANK_R * 1.03, TAPER_Z + 0.2 * k)
        p1 = (TR + cos(a1) * TANK_R * 1.03, sin(a1) * TANK_R * 1.03, 33.0 * k)
        finish(strut(f'tank{idx}_lat{s}', p0, p1, 0.07 * k, M['alu'], parent=g), bevel_w=0.004)
    # The open bay: longerons and hoops round the exposed core.
    w0, w1 = BAY
    for z in (w0, w1, (w0 + w1) / 2):
        finish(ring_on((TR, 0, z), (0, 0, 1), TANK_R * 1.0, 0.18 * k, M['alu'],
                       f'tank{idx}_hoop{z:.0f}', seg=96, minor=10, parent=g), bevel_w=0.006)
    for s in range(10):
        b = s / 10 * TAU
        p0 = (TR + cos(b) * TANK_R, sin(b) * TANK_R, w0)
        p1 = (TR + cos(b) * TANK_R, sin(b) * TANK_R, w1)
        finish(strut(f'tank{idx}_lon{s}', p0, p1, 0.12 * k, M['alu'], parent=g), bevel_w=0.006)
        q1 = (TR + cos(b + TAU / 10) * TANK_R, sin(b + TAU / 10) * TANK_R, (w0 + w1) / 2)
        finish(strut(f'tank{idx}_dia{s}', p0, q1, 0.06 * k, M['alu'], parent=g), bevel_w=0.004)
    for s in range(5):                                     # plumbing in the bay
        b = s / 5 * TAU + 0.3
        rr = CORE_R + 0.35 * k
        finish(strut(f'tank{idx}_pipe{s}', (TR + cos(b) * rr, sin(b) * rr, w0 - 0.4 * k),
                     (TR + cos(b) * rr, sin(b) * rr, w1 + 0.4 * k), 0.14 * k,
                     M['gold'] if s % 2 else M['dirty'], parent=g), bevel_w=0.006)
    # Equipment on the outboard flank and a black access panel.
    for n, (z, w, h) in enumerate([(39.6, 1.8, 1.4), (65.0, 1.2, 1.2), (75.0, 2.2, 0.9), (83.0, 1.0, 1.6)]):
        side = 1 if n % 2 else -1
        ang = side * 0.45
        px = TR + cos(ang) * TANK_R * 1.03
        py = sin(ang) * TANK_R * 1.03
        finish(box(f'tank{idx}_eq{n}', (0.35 * k, w * k, h * k), (px, py, z * k),
                   M['dirty'], rot=(0, 0, ang), parent=g), bevel_w=0.02)
    finish(box(f'tank{idx}_door', (0.08 * k, 2.4 * k, 2.4 * k), (TR + TANK_R * 1.01, 0, 63.5 * k),
               M['soot'], parent=g), bevel_w=0.01)
    # A conduit down the inboard side and round the bend.
    run = []
    for p in pts[::2]:
        r = tank_radius(p[2]) * 1.06 + 0.15 * k
        run.append((p[0] - r, 0.0, p[2]))
    finish(tube(f'tank{idx}_trunk', run, 0.22 * k, M['dirty'], seg=12, parent=g, caps=(True, True)),
           bevel_w=0.010)
    # The tip: a bulkhead ring and the drive square under it.
    finish(ring_on((TIP_X, 0, TIP_Z), (0, 0, 1), TIP_R * 1.01, 0.12 * k, M['alu'],
                   f'tank{idx}_tipring', seg=64, minor=10, parent=g), bevel_w=0.006)
    cap0 = disc(f'tank{idx}_tipcap', TIP_R, 0, M['dirty'], seg=64, parent=g)
    cap0.rotation_euler = (pi, 0, 0)
    cap0.location = (TIP_X, 0, TIP_Z)
    spin_drive(f'gimbal_hm_{idx + 1}', DR, g, (TIP_X, 0, 0), f'drv{idx + 1}')
    return g


# THE DRUM AND THE CENTRAL DRIVE
def build_drum(root):
    prof = [(0, DRUM_Z0), (3.6 * k, DRUM_Z0), (4.5 * k, DRUM_Z0 + 0.6 * k), (DRUM_R, DRUM_Z0 + 1.6 * k)]
    for n in range(1, 6):                     # grooves between the drum's sections
        z = DRUM_Z0 + 1.6 * k + (DRUM_Z1 - DRUM_Z0 - 2.6 * k) * n / 6
        prof += [(DRUM_R, z - 0.15 * k), (DRUM_R * 0.985, z), (DRUM_R, z + 0.15 * k)]
    prof += [(DRUM_R, DRUM_Z1 - 1.0 * k), (5.6 * k, DRUM_Z1), (5.7 * k, DRUM_Z1 + 0.6 * k),
             (5.4 * k, DRUM_Z1 + 0.9 * k), (4.4 * k, DRUM_Z1 + 0.7 * k), (0, DRUM_Z1 + 0.7 * k)]
    finish(revolve('drum', prof, M['dirty'], seg=96, parent=root), bevel_w=0.02)
    for z in (15.0, 28.0):
        finish(ring_on((0, 0, z * k), (0, 0, 1), DRUM_R * 1.01, 0.14 * k, M['alu'], f'drum_band{z:.0f}',
                       seg=96, minor=10, parent=root), bevel_w=0.006)
    # Stringers, and rows of brackets: small hardware the eye measures the drum by.
    for i in range(12):
        finish(fin(f'drum_str{i}', [(DRUM_R, DRUM_Z0 + 2 * k), (DRUM_R, DRUM_Z1 - 1.2 * k)],
                   i / 12 * TAU + 0.13, 0.16 * k, 0.18 * k, M['alu'], parent=root), bevel_w=0.006)
    for row, z in enumerate((12.5, 21.0, 31.0)):
        for i in range(16):
            b = i / 16 * TAU + row * 0.2
            finish(box(f'drum_brk{row}_{i}', (0.35 * k, 0.6 * k, 0.8 * k),
                       (cos(b) * DRUM_R * 1.03, sin(b) * DRUM_R * 1.03, z * k), M['alu'],
                       rot=(0, 0, b), parent=root), bevel_w=0.01)
    # The central drive, and the thrust units ringed round it under the drum.
    spin_drive('gimbal_hm_0', DR0, root, (0, 0, 0), 'drv0')
    top0 = DR0 * 2.04
    finish(revolve('drum_neck', [(0, top0 - 0.05 * k), (0.9 * k, top0 - 0.05 * k),
                                 (1.2 * k, DRUM_Z0 + 0.05 * k), (0, DRUM_Z0 + 0.05 * k)],
                   M['dirty'], seg=48, parent=root), bevel_w=0.010)
    for i in range(6):
        b = i / 6 * TAU + pi / 6
        z0 = (0.7 + 0.45 * ((i * 3) % 5)) * k
        u = empty(f'unit{i}', (cos(b) * UNIT_RING, sin(b) * UNIT_RING, 0), root)
        finish(revolve(f'unit{i}_body', [(0, z0), (UNIT_R * 0.9, z0), (UNIT_R, z0 + 0.15 * k),
                                         (UNIT_R, DRUM_Z0 + 0.1 * k), (0, DRUM_Z0 + 0.1 * k)],
                       M['nozzle'], seg=32, parent=u), bevel_w=0.01)
        face = disc(f'unit{i}_face', UNIT_R * 0.72, 0, M['emitPlate'], seg=24, parent=u)
        face.rotation_euler = (pi, 0, 0)
        face.location = (0, 0, z0 - 0.01 * k)
        for z in (z0 + 1.2 * k, (z0 + DRUM_Z0) / 2 + 0.6 * k):
            finish(ring_on((0, 0, z), (0, 0, 1), UNIT_R * 1.04, 0.07 * k, M['alu'], f'unit{i}_r{z:.1f}',
                           seg=32, minor=8, parent=u), bevel_w=0.004)


# THE CREW STACK
def build_modules(root):
    for n, (z0, z1, r, mk, kind) in enumerate(MODULES):
        z0, z1, r = z0 * k, z1 * k, r * k
        c = 0.25 * k
        if kind == 'dock':
            prof = [(0, z0), (r, z0), (r, z0 + 1.0 * k), (1.6 * k, z1 - 0.4 * k), (1.6 * k, z1), (0, z1)]
        elif kind == 'node':
            prof = [(0, z0)] + [(r * (0.75 + 0.25 * sin(i / 8 * pi)), z0 + (z1 - z0) * i / 8) for i in range(9)] + [(0, z1)]
        else:
            prof = [(0, z0), (r * 0.92, z0), (r, z0 + c), (r, z1 - c), (r * 0.92, z1), (0, z1)]
        finish(revolve(f'mod{n}', prof, M[mk], seg=72, parent=root), bevel_w=0.012)
        if kind == 'hub':
            for z in (z0 + 1.2 * k, z1 - 1.2 * k):
                finish(ring_on((0, 0, z), (0, 0, 1), r * 1.01, 0.12 * k, M['alu'], f'mod{n}_band{z:.1f}',
                               seg=72, minor=8, parent=root), bevel_w=0.004)
        elif kind == 'ringed':
            for i in range(4):
                z = z0 + (z1 - z0) * (i + 0.5) / 4
                finish(ring_on((0, 0, z), (0, 0, 1), r * 1.02, 0.10 * k, M['alu'], f'mod{n}_frame{i}',
                               seg=72, minor=8, parent=root), bevel_w=0.004)
        elif kind == 'quilt':
            for row in range(3):
                for i in range(10):
                    b = i / 10 * TAU + row * 0.31
                    z = z0 + (z1 - z0) * (row + 0.5) / 3
                    finish(box(f'mod{n}_pad{row}_{i}', (0.08 * k, 1.5 * k, 1.7 * k),
                               (cos(b) * r * 1.01, sin(b) * r * 1.01, z), M['dirty'],
                               rot=(0, 0, b), parent=root), bevel_w=0.02)
        elif kind == 'berth':
            zc = (z0 + z1) / 2
            finish(ring_on((r * 1.0, 0, zc), (1, 0, 0), 1.25 * k, 0.16 * k, M['alu'], f'mod{n}_berth',
                           seg=48, minor=10, parent=root), bevel_w=0.006)
            hatch = disc(f'mod{n}_hatch', 1.1 * k, 0, M['dirty'], seg=32, parent=root)
            hatch.rotation_euler = (0, pi / 2, 0)
            hatch.location = (r * 1.02, 0, zc)
        elif kind == 'banded':
            zc = (z0 + z1) / 2
            finish(revolve(f'mod{n}_band', [(r * 1.01, zc - 0.5 * k), (r * 1.015, zc), (r * 1.01, zc + 0.5 * k)],
                           M['soot'], seg=72, parent=root), bevel_w=0.004)
        elif kind == 'greeble':
            for i in range(9):
                b = i / 9 * TAU + 0.4
                z = z0 + (z1 - z0) * (0.2 + 0.6 * ((i * 4) % 9) / 8)
                finish(box(f'mod{n}_gb{i}', ((0.4 + 0.2 * (i % 3)) * k, (0.6 + 0.3 * (i % 2)) * k, (0.8 + 0.4 * (i % 4)) * k),
                           (cos(b) * r * 1.08, sin(b) * r * 1.08, z), M['alu'] if i % 3 else M['soot'],
                           rot=(0, 0, b), parent=root), bevel_w=0.012)
        elif kind == 'hatch':
            zc = z0 + (z1 - z0) * 0.55
            finish(ring_on((0, -r, zc), (0, 1, 0), 0.8 * k, 0.10 * k, M['alu'], f'mod{n}_hring',
                           seg=40, minor=8, parent=root), bevel_w=0.004)
            w = disc(f'mod{n}_window', 0.3 * k, 0, M['glass'], seg=20, parent=root)
            w.rotation_euler = (0, pi / 2, 0)
            w.location = (r * 1.01, 0, zc)
        elif kind == 'dock':
            finish(ring_on((0, 0, z1), (0, 0, 1), 1.45 * k, 0.12 * k, M['alu'], f'mod{n}_ring',
                           seg=48, minor=8, parent=root), bevel_w=0.004)
    # The mast and the high-gain antenna, forward.
    finish(strut('mast', (0, 2.2 * k, 97.0 * k), (0, 5.5 * k, 97.0 * k), 0.09 * k, M['alu'], parent=root),
           bevel_w=0.004)
    hga = empty('hga', (-2.3 * k, 0, 90.0 * k), root)
    finish(strut('hga_boom', (0, 0, 0), (-1.8 * k, 0, 0), 0.10 * k, M['alu'], parent=hga), bevel_w=0.006)
    yoke = empty('hga_yoke', (-1.8 * k, 0, 0), hga)
    yoke.rotation_euler = (0, -0.9, 0)
    finish(dish('hga_dish', 1.2 * k, M['white'], seg=40, parent=yoke), bevel_w=0.006)
    # RCS quads, and four beetles on the narrow module.
    for zq, rq in ((65.0, 3.0), (98.5, 2.3)):
        for i in range(4):
            b = i / 4 * TAU + pi / 4
            pod = group(f'rcs{zq:.0f}_{i}', root, loc=(cos(b) * rq * k, sin(b) * rq * k, zq * k), rot_z=b)
            finish(box(f'rcs{zq:.0f}_{i}_b', (0.35 * k, 0.5 * k, 0.5 * k), (0, 0, 0), M['dirty'], parent=pod), bevel_w=0.01)
    for i in range(4):
        b = i / 4 * TAU
        pod = group(f'beetle{i}', root, loc=(cos(b) * 2.75 * k, sin(b) * 2.75 * k, 80.6 * k), rot_z=b)
        body = [(0, -0.9 * k)] + [(0.42 * k * sin(j / 6 * pi / 2), -0.9 * k + 0.42 * k * (1 - cos(j / 6 * pi / 2))) for j in range(1, 7)]
        body += [(0.42 * k, 0.9 * k)] + [(0.42 * k * cos(j / 6 * pi / 2), 0.9 * k + 0.42 * k * sin(j / 6 * pi / 2)) for j in range(1, 7)]
        finish(revolve(f'beetle{i}_body', body, M['dirty'], seg=24, parent=pod), bevel_w=0.006)


def build_structure(root):
    """Struts tying the tanks to the drum and the stack, girth ties between them, and
       an aft truss from each tip to the drum's base: one structure, not four parts."""
    def rp(i, r, z):
        a = i / 3 * TAU + pi / 2
        return (cos(a) * r, sin(a) * r, z)
    for z, r_in in ((22.0, DRUM_R), (38.0, 4.0 * k), (60.0, 3.0 * k), (91.0, 2.3 * k)):
        z *= k
        for i in range(3):
            # Both sides of the tank's inboard face, so each tie is a V, not a pin.
            for s in (-0.035, 0.035):
                finish(strut(f'tie{i}_{z:.0f}_{s}', rp(i, r_in * 0.98, z), rp(i + s * 3, TR - TANK_R * 0.97, z),
                             0.16 * k, M['alu'], parent=root), bevel_w=0.008)
    for z in (70.0, 97.0):
        for i in range(3):
            finish(strut(f'girth{i}_{z:.0f}', rp(i + 0.13, TR - TANK_R * 0.2, z * k),
                         rp(i + 0.87, TR - TANK_R * 0.2, z * k), 0.14 * k, M['alu'], parent=root),
                   bevel_w=0.008)
    for i in range(3):
        tip = rp(i, TIP_X, TIP_Z + 0.6 * k)
        for s in (-1, 1):
            finish(strut(f'aft{i}_{s}', tip, rp(i + s * 0.25, 3.8 * k, DRUM_Z0 + 0.3 * k), 0.13 * k,
                         M['alu'], parent=root), bevel_w=0.008)


def build_wings(root):
    """Two wings astern, between the tanks: a mast from the drum, each wing two
       columns of cells either side of it, from just outside the tanks to 52 m out."""
    zc = (WING_Z[1] + WING_Z[2]) / 2
    for si, az in enumerate((0.0, pi)):
        w = group(f'wing{si}', root, rot_z=az)
        finish(strut(f'wing{si}_mast', (DRUM_R * 0.98, 0, zc), (WING_R1 + 0.6 * k, 0, zc), 0.30 * k,
                     M['alu'], parent=w), bevel_w=0.01)
        for z in (WING_Z[0], WING_Z[3]):
            finish(strut(f'wing{si}_brace{z:.0f}', (DRUM_R * 0.98, 0, z + 1.5 * k), (WING_R0, 0, zc), 0.14 * k,
                         M['alu'], parent=w), bevel_w=0.006)
        n = 9
        seg = (WING_R1 - WING_R0) / n
        for c, (z0, z1) in enumerate(((WING_Z[0], WING_Z[1]), (WING_Z[2], WING_Z[3]))):
            for j in range(n):
                x = WING_R0 + seg * (j + 0.5)
                finish(box(f'wing{si}_c{c}_{j}', (seg * 0.96, 0.08 * k, z1 - z0), (x, 0, (z0 + z1) / 2),
                           M['solar'], parent=w), bevel_w=0.01)
                finish(box(f'wing{si}_rib{c}_{j}', (0.10 * k, 0.14 * k, z1 - z0), (WING_R0 + seg * j, 0, (z0 + z1) / 2),
                           M['alu'], parent=w), bevel_w=0.006)
            for z in (z0, z1):
                finish(box(f'wing{si}_edge{c}_{z:.0f}', (WING_R1 - WING_R0, 0.12 * k, 0.12 * k),
                           ((WING_R0 + WING_R1) / 2, 0, z), M['alu'], parent=w), bevel_w=0.006)


def build_hailmary(_M):
    build_materials()
    root = stage('hm')
    build_drum(root)
    for i in range(3):
        build_tank(i, root)
    build_structure(root)
    build_modules(root)
    build_wings(root)


build('hailmary', build_hailmary)
