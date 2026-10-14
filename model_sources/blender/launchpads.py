"""Authored structures for the four flight launch complexes.

The Godot launchsite owns motion, smoke, terrain and every part fitted to the
vehicle's measured skin (swing arms, hold-downs, tail service masts); these meshes
replace its procedural stand-ins when present. Dimensions mirror the constants in
sim/flight/launchsite.gd. Coordinates are metres with the pad surface at Z=0.

References: Apollo 12 and Apollo 11 on 39A (the red LUT on its Mobile Launcher),
Atlantis and STS-129 on 39A (the grey FSS, the parked RSS, the MLP's tail service
masts), the 39A transporter-erector and Crew-4 (SpaceX's white TE, the dark crew
tower), Booster 7 / Ship 24 at Starbase (the stainless tower and dark arms).
"""
import math
import os
import sys
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import box, empty, finish, strut, torus_z, cyl
from common import build, srgb
from lib import material

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
STYLE = args[args.index('--style') + 1] if '--style' in args else 'lut'
if STYLE not in ('lut', 'fss', 'strongback', 'chopsticks'):
    raise ValueError(f'unknown pad style {STYLE}')

# Mirrored in sim/flight/launchsite.gd.
ML_H, ML_PED, ML_HALF_Z = 7.6, 6.7, 20.55
ML_DECK = ML_H + ML_PED
LUT_ML, LUT_X, LUT_SIDE, LUT_H = (-32.0, 17.4), -22.85, 12.2, 118.0
MLP_X, FSS_X, FSS_SIDE, FSS_H, MAST_H = (-21.5, 27.9), -28.1, 12.2, 75.3, 24.4
CREW_TOWER_H = 84.0
RSS_HINGE, RSS_YAW = (-22.0, -6.1), 2.618
TOWER_OFFSET, TOWER_HALF = 26.0, 6.0


def xyz(p):
    """Godot (x, up, z) to Blender (x, -z, up)."""
    return (p[0], -p[2], p[1])


def block(name, width, height, depth, x, bottom, z, mat, parent=None, bevel=0.04, yaw=0.0):
    ob = box(name, (width, depth, height), xyz((x, bottom + height * 0.5, z)), mat, parent=parent)
    if yaw:
        # Godot's Basis(UP, yaw) is a turn about Blender +Z by the same angle.
        ob.rotation_euler.z = yaw
    if bevel:
        finish(ob, min(bevel, width * 0.15, height * 0.15, depth * 0.15), 2)
    return ob


def beam(name, a, b, width, mat, parent=None, bevel=0.025):
    p, q = Vector(xyz(a)), Vector(xyz(b))
    d = q - p
    if d.length < 0.001:
        return None
    ob = box(name, (width, width, d.length), (p + q) * 0.5, mat, parent=parent)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    if bevel:
        finish(ob, min(bevel, width * 0.14), 2)
    return ob


def pipe(name, a, b, radius, mat, parent=None):
    return strut(name, xyz(a), xyz(b), radius, mat, seg=12, parent=parent)


def turned(origin, yaw, u, y, v):
    """A point (u, y, v) in a frame at `origin` turned by Godot's Basis(UP, yaw)."""
    c, s = math.cos(yaw), math.sin(yaw)
    return (origin[0] + u * c + v * s, y, origin[1] - u * s + v * c)


def service_tower(M, parent, prefix, height, side, paint, level=6.1, brace=1, mid=False,
                  flare=1.0, flare_h=0.0, col=0.9, floors=True, core=True, rooms=2,
                  clad=None, clad_from=0.0, lamps=True, core_mat=None):
    """A service tower standing on the parent's origin, vehicle on +x.

    Floors every `level` (KSC's are 20 ft apart), girts and bracing on every face,
    the corner legs splayed over the lowest `flare_h`, an elevator core, rooms on
    some floors, work lights at each floor, and cladding on the three faces away
    from the vehicle when asked. Mirrors LaunchSite.service_tower.
    """
    grey, white, lamp = M['ml-grey'], M['white'], M['lamp']
    h = side * 0.5

    def half_at(y):
        return h if flare_h <= 0.0 or y >= flare_h else h * flare + (h - h * flare) * y / flare_h

    for sx in (-1, 1):
        for sz in (-1, 1):
            if flare_h > 0:
                beam(f'{prefix}_leg_{sx}_{sz}', (sx * h * flare, 0, sz * h * flare),
                     (sx * h, flare_h, sz * h), col * 1.15, paint, parent)
            beam(f'{prefix}_column_{sx}_{sz}', (sx * h, flare_h, sz * h), (sx * h, height, sz * h),
                 col, paint, parent, 0.06)
    if mid:
        for f in range(4):
            ux, uz = round(math.cos(f * math.pi / 2)), round(math.sin(f * math.pi / 2))
            beam(f'{prefix}_mid_{f}', (ux * h, flare_h, uz * h), (ux * h, height, uz * h), col * 0.6, paint, parent)
            if flare_h > 0:
                beam(f'{prefix}_mid_leg_{f}', (ux * h * flare, 0, uz * h * flare), (ux * h, flare_h, uz * h),
                     col * 0.7, paint, parent)
    n = max(2, int(height // level))
    ys = [min(i * level, height) for i in range(n + 1)]
    if ys[-1] < height - 0.5:
        ys.append(height)
    for i, y in enumerate(ys):
        hh = half_at(y)
        c = [(-hh, y, -hh), (hh, y, -hh), (hh, y, hh), (-hh, y, hh)]
        for k in range(4):
            beam(f'{prefix}_girt_{i}_{k}', c[k], c[(k + 1) % 4], col * 0.55, paint, parent)
        if i == 0:
            continue
        if floors:
            block(f'{prefix}_floor_{i}', 2 * hh - 0.3, 0.22, 2 * hh - 0.3, 0, y - 0.22, 0, grey, parent, 0.02)
            # grating bars, which is what a KSC tower floor is
            for g in range(int(2 * hh / 1.2)):
                gx = -hh + 0.8 + g * 1.2
                block(f'{prefix}_grate_{i}_{g}', 0.08, 0.06, 2 * hh - 0.6, gx, y, 0, M['darkcon'], parent, 0)
        if lamps:
            for k, (cx, _, cz) in enumerate(c):
                d = math.hypot(cx, cz)
                block(f'{prefix}_lamp_{i}_{k}', 0.35, 0.28, 0.35, cx - cx / d * 0.9, y + 2.4,
                      cz - cz / d * 0.9, lamp, parent, 0)
    i0 = 0
    while i0 < len(ys) - 1:
        i1 = min(i0 + brace, len(ys) - 1)
        y0, y1 = ys[i0], ys[i1]
        h0, h1 = half_at(y0), half_at(y1)
        for f in range(4):
            a = f * math.pi / 2
            ux, uz = math.cos(a), math.sin(a)
            tx, tz = -uz, ux
            p00 = (ux * h0 - tx * h0, y0, uz * h0 - tz * h0)
            p01 = (ux * h0 + tx * h0, y0, uz * h0 + tz * h0)
            p10 = (ux * h1 - tx * h1, y1, uz * h1 - tz * h1)
            p11 = (ux * h1 + tx * h1, y1, uz * h1 + tz * h1)
            w = col * 0.42
            if mid:
                m0 = tuple((p00[k] + p01[k]) * 0.5 for k in range(3))
                m1 = tuple((p10[k] + p11[k]) * 0.5 for k in range(3))
                for j, (pa, pb) in enumerate(((p00, m1), (m0, p11), (p01, m1), (m0, p10))):
                    beam(f'{prefix}_brace_{i0}_{f}_{j}', pa, pb, w, paint, parent, 0.015)
            else:
                beam(f'{prefix}_brace_{i0}_{f}_a', p00, p11, w, paint, parent, 0.015)
                beam(f'{prefix}_brace_{i0}_{f}_b', p01, p10, w, paint, parent, 0.015)
        i0 = i1
    if core:
        block(f'{prefix}_core', side * 0.28, height - 0.5, side * 0.34, -side * 0.18, 0, side * 0.12,
              core_mat or grey, parent, 0.05)
        # the elevator machine house on the roof
        block(f'{prefix}_machine', side * 0.34, 3.2, side * 0.4, -side * 0.18, height, side * 0.12, white, parent, 0.08)
    for i in range(1, len(ys) - 1):
        if rooms and i % rooms == 1:
            w = side * (0.55 if i % 2 == 0 else 0.38)
            block(f'{prefix}_room_{i}', w, min(level * 0.7, 3.6), side * 0.42, -h + w * 0.5 + 0.4, ys[i],
                  -h * 0.35 * (1 if i % 3 == 0 else -1), white, parent, 0.06)
            # a window band and a door on the room's long side
            block(f'{prefix}_window_{i}', w * 0.8, 0.7, 0.06, -h + w * 0.5 + 0.4, ys[i] + 1.8,
                  -h * 0.35 * (1 if i % 3 == 0 else -1) + side * 0.21 + 0.03, M['glass'], parent, 0)
    if clad is not None:
        block(f'{prefix}_clad_back', 0.12, height - clad_from, side, -h - 0.25, clad_from, 0, clad, parent, 0.02)
        for sz in (-1, 1):
            block(f'{prefix}_clad_{sz}', side, height - clad_from, 0.12, 0, clad_from, sz * (h + 0.25), clad, parent, 0.02)
            # the panel seams that give the dark cladding its scale
            for k in range(int((height - clad_from) / 6.1)):
                block(f'{prefix}_seam_{sz}_{k}', side + 0.1, 0.18, 0.06, 0, clad_from + k * 6.1, sz * (h + 0.33),
                      M['steel'], parent, 0)


def crane(M, parent, prefix, top, yaw, paint, mast):
    """A hammerhead crane at `top` (Godot coords), jib parked toward `yaw`."""
    o = (top[0], top[2])
    block(f'{prefix}_slew', 3.2, 4.2, 3.2, top[0], top[1], top[2], paint, parent, 0.1)
    hx, _, hz = turned(o, yaw, -7.0, 0, 0)
    block(f'{prefix}_house', 4.6, 3.4, 3.4, hx, top[1] + 4.2, hz, M['white'], parent, 0.1, yaw)
    y = top[1] + 4.2
    for z in (-1.1, 1.1):
        for dy in (0.0, 2.2):
            a = turned(o, yaw, -9.0, y + dy, z)
            b = turned(o, yaw, 20.0, y + dy, z)
            beam(f'{prefix}_chord_{z}_{dy}', a, b, 0.3, paint, parent)
    for i in range(10):
        x = -9.0 + i * 2.9
        for z in (-1.1, 1.1):
            beam(f'{prefix}_lace_{i}_{z}', turned(o, yaw, x, y, z), turned(o, yaw, x + 2.9, y + 2.2, z), 0.18, paint, parent)
        beam(f'{prefix}_tie_{i}', turned(o, yaw, x, y + 2.2, -1.1), turned(o, yaw, x, y + 2.2, 1.1), 0.16, paint, parent)
    kx, _, kz = turned(o, yaw, 12.0, 0, 0)
    block(f'{prefix}_hook', 1.4, 1.6, 1.4, kx, y - 1.6, kz, M['safety-yellow'], parent, 0.1)
    if mast > 0:
        pipe(f'{prefix}_mast', (top[0], y + 2.2, top[2]), (top[0], y + 2.2 + mast, top[2]), 0.22, paint, parent)


def deck_cells(pw, pd, holes, cx0=0.0, cz0=0.0):
    """A rectangle (the platform, by default) minus the holes, as rectangles:
    cut the plan at every hole edge inside it and keep the cells no hole
    covers, merged along x so a row is one slab where it can be."""
    x_lo, x_hi, z_lo, z_hi = cx0 - pw / 2, cx0 + pw / 2, cz0 - pd / 2, cz0 + pd / 2
    xs = sorted({x_lo, x_hi, *[min(max(h[0] + s * h[2] / 2, x_lo), x_hi) for h in holes for s in (-1, 1)]})
    zs = sorted({z_lo, z_hi, *[min(max(h[1] + s * h[3] / 2, z_lo), z_hi) for h in holes for s in (-1, 1)]})
    cells = []
    for j in range(len(zs) - 1):
        z0, z1 = zs[j], zs[j + 1]
        run = None
        for i in range(len(xs) - 1):
            x0, x1 = xs[i], xs[i + 1]
            cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
            solid = not any(abs(cx - h[0]) < h[2] / 2 and abs(cz - h[1]) < h[3] / 2 for h in holes)
            if solid and run is not None and abs(run[1] - x0) < 1e-6:
                run[1] = x1
            elif solid:
                run = [x0, x1, z0, z1]
                cells.append(run)
            else:
                run = None
    return cells


# Exhaust openings (centre x, centre z, width x, depth z), m. The Saturn V ML has one
# 13.7 m square for the five F-1s. The Shuttle MLP has three: 6.1 × 12.8 m under each
# booster and 10.4 × 9.4 m under the main engines, 7.4 m off the tank axis toward the
# orbiter (+z). Mirrored in sim/flight/launchsite.gd.
DECK_HOLES = {
    'lut': [(0.0, 0.0, 13.7, 13.7)],
    'fss': [(-6.35, 0.0, 6.1, 12.8), (6.35, 0.0, 6.1, 12.8), (0.0, 7.4, 10.4, 9.4)],
}


def mobile_launcher(M, parent, x0, x1, holes):
    """The ML base on its pedestals: two storeys of steel box girder, plated, with
    a belt and ribs, exposed piping along its long sides and lights on its edge."""
    grey, steel, dark = M['ml-grey'], M['steel'], M['darkcon']
    hz, cx, pw = ML_HALF_Z, (x0 + x1) / 2, x1 - x0
    for k, (a0, a1, b0, b1) in enumerate(deck_cells(pw, hz * 2, holes, cx, 0.0)):
        block(f'deck_cell_{k}', a1 - a0, ML_H, b1 - b0, (a0 + a1) / 2, ML_PED, (b0 + b1) / 2, grey, parent,
              min(0.2, (a1 - a0) * 0.1, (b1 - b0) * 0.1))
    for k in range(3):
        x = x0 + 5.0 + (pw - 10.0) * k * 0.5
        for sz in (-1, 1):
            block(f'pedestal_{k}_{sz}', 3.4, ML_PED, 3.4, x, 0, sz * (hz - 4.5), M['concrete'], parent, 0.08)
            block(f'mount_{k}_{sz}', 2.2, 0.6, 2.2, x, ML_PED - 0.6, sz * (hz - 4.5), steel, parent, 0.05)
    for x in (x0 + 2.0, x1 - 2.0):
        for sz in (-1, 1):
            block(f'column_{x}_{sz}', 1.3, ML_PED, 1.3, x, 0, sz * (hz - 1.6), steel, parent, 0.05)
    for sz in (-1, 1):
        block(f'belt_{sz}', pw + 0.3, 0.55, 0.3, cx, ML_PED + 3.6, sz * (hz + 0.1), dark, parent, 0.03)
        block(f'cap_{sz}', pw + 0.3, 0.4, 0.3, cx, ML_PED + ML_H - 0.4, sz * (hz + 0.1), steel, parent, 0.03)
        nr = int(pw / 4.1)
        for i in range(nr + 1):
            block(f'rib_{sz}_{i}', 0.32, ML_H, 0.3, x0 + pw * i / nr, ML_PED, sz * (hz + 0.12), steel, parent, 0.03)
        for k in range(2):
            py = ML_PED + 1.4 + k * 1.1
            pipe(f'side_pipe_{sz}_{k}', (x0 + 1.0, py, sz * (hz + 0.65)), (x1 - 1.0, py, sz * (hz + 0.65)),
                 0.32, M['white'], parent)
        for i in range(12):
            x = x0 + 1.0 + (pw - 2.0) * i / 11
            block(f'edge_lamp_{sz}_{i}', 0.6, 0.2, 0.5, x, ML_PED + ML_H - 1.0, sz * (hz + 0.35), M['lamp'], parent, 0)
            if i % 3 == 1:
                # pipe hangers and valve boxes on the exposed runs
                block(f'valve_{sz}_{i}', 1.2, 1.0, 0.9, x, ML_PED + 1.0, sz * (hz + 0.75), M['oxidized-copper'], parent, 0.06)
        # the guard rail on the deck edge
        for i in range(16):
            x = x0 + 0.5 + (pw - 1.0) * i / 15
            pipe(f'rail_post_{sz}_{i}', (x, ML_DECK, sz * (hz - 0.3)), (x, ML_DECK + 1.1, sz * (hz - 0.3)),
                 0.05, M['safety-yellow'], parent)
        pipe(f'rail_{sz}', (x0, ML_DECK + 1.1, sz * (hz - 0.3)), (x1, ML_DECK + 1.1, sz * (hz - 0.3)),
             0.06, M['safety-yellow'], parent)
    for sx in (-1, 1):
        ex = x1 if sx > 0 else x0
        block(f'belt_end_{sx}', 0.3, 0.55, hz * 2 + 0.3, ex + sx * 0.1, ML_PED + 3.6, 0, dark, parent, 0.03)
        nr = int(hz * 2 / 4.1)
        for i in range(nr + 1):
            block(f'rib_end_{sx}_{i}', 0.3, ML_H, 0.32, ex + sx * 0.12, ML_PED, -hz + hz * 2 * i / nr, steel, parent, 0.03)
    # Underside girders, seen between the pedestals.
    for i in range(int(pw / 6.0) + 1):
        x = x0 + 1.0 + i * 6.0
        if x > x1 - 1.0:
            break
        cuts = sorted((h[1] - h[3] / 2, h[1] + h[3] / 2) for h in holes if abs(x - h[0]) < h[2] / 2 + 0.4)
        z = -hz + 1.0
        for k, (a, b) in enumerate(cuts + [(hz - 1.0, hz - 1.0)]):
            if a - z > 0.5:
                block(f'under_girder_{i}_{k}', 0.5, 1.2, a - z, x, ML_PED - 1.2, (a + z) / 2, steel, parent, 0.05)
            z = max(z, b)
    # hazard lines a metre outside every opening, cut where they cross a neighbour
    for k, (hx, hzc, w, d) in enumerate(holes):
        for s in (-1, 1):
            lines = ((0.35, d + 2.35, hx + s * (w / 2 + 1.0), hzc), (w + 2.35, 0.35, hx, hzc + s * (d / 2 + 1.0)))
            for j, (lw, ld, lx, lz) in enumerate(lines):
                for q, (a0, a1, b0, b1) in enumerate(deck_cells(lw, ld, holes, lx, lz)):
                    block(f'hazard_{k}_{s}_{j}_{q}', a1 - a0, 0.025, b1 - b0, (a0 + a1) / 2, ML_DECK, (b0 + b1) / 2,
                          M['safety-yellow'], parent, 0)
    # deck furniture: utility boxes along the edge away from the tower
    for i in range(4):
        x = x0 + pw * (0.55 + i * 0.1)
        block(f'utility_{i}', 2.2, 1.7, 1.4, x, ML_DECK, hz - 3.2, M['white'], parent, 0.1)


def rotating_service_structure(M, parent):
    """Shuttle-era 39A's RSS parked open: a clad box 31 × 40 × 15 m whose underside is
    18 m up, on its hinge column at the FSS and a two-legged wheeled far column."""
    o, yaw = RSS_HINGE, RSS_YAW
    steel, white, grey = M['steel'], M['white'], M['fss-grey']

    def at(u, y, v):
        return turned(o, yaw, u, y, v)

    x, _, z = at(17.5, 0, 7.5)
    block('rss_body', 31.0, 40.0, 15.0, x, 18.0, z, white, parent, 0.1, yaw)
    x, _, z = at(20.0, 0, 7.5)
    block('rss_roof_storey', 22.0, 6.0, 11.0, x, 58.0, z, grey, parent, 0.1, yaw)
    for k in range(9):
        x, _, z = at(17.5, 0, 7.5)
        block(f'rss_floor_line_{k}', 31.3, 0.45, 15.3, x, 22.0 + k * 4.2, z, grey, parent, 0.02, yaw)
    x, _, z = at(17.5, 0, -0.1)
    block('rss_pcr_door', 18.0, 19.0, 0.3, x, 22.0, z, M['ml-grey'], parent, 0.04, yaw)
    for u in (2.0, 12.3, 22.6, 33.0):
        for v in (-0.2, 15.2):
            beam(f'rss_post_{u}_{v}', at(u, 18.0, v), at(u, 58.0, v), 0.7, steel, parent)
    for y in (18.0, 31.3, 44.6, 58.0):
        for v in (-0.2, 15.2):
            beam(f'rss_girder_{y}_{v}', at(2.0, y, v), at(33.0, y, v), 0.55, steel, parent)
    # platforms and their hand rails cantilevered off the far end
    for k in range(5):
        y = 20.0 + k * 8.0
        x, _, z = at(34.6, 0, 7.5)
        block(f'rss_end_platform_{k}', 3.0, 0.2, 13.0, x, y, z, grey, parent, 0.02, yaw)
        x, _, z = at(33.4, 0, 7.5)
        block(f'rss_lamp_{k}', 0.6, 0.2, 0.6, x, y + 3.0, z, M['lamp'], parent, 0, yaw)
    beam('rss_hinge_column', at(0, 0, 0), at(0, 58.0, 0), 1.3, steel, parent)
    beam('rss_hinge_strut', at(2.0, 18.0, 0), at(0, 30.0, 0), 0.6, steel, parent)
    for v in (1.0, 14.0):
        beam(f'rss_leg_{v}', at(37.0, 0, v), at(32.0, 18.0, v), 1.1, steel, parent)
        beam(f'rss_leg_brace_{v}', at(37.0, 0, v), at(37.0, 9.0, 7.5), 0.6, steel, parent)
        x, _, z = at(37.0, 0, v)
        block(f'rss_truck_{v}', 3.0, 1.6, 2.2, x, 0, z, M['ml-grey'], parent, 0.08, yaw)


def strongback(M, parent, h=63.0):
    """Falcon's 39A TE: a white closed-box spine with lattice cheeks, an A-frame base
    out to its hinge beam, four hydraulic rams and the clamp arms. Vehicle face at
    local x = 1.7, matching LaunchSite.strongback."""
    white, steel = M['white'], M['steel']
    block('te_spine', 2.4, h, 2.0, 0.5, 0, 0, white, parent, 0.08)
    n = int(h / 3.2)
    for sz in (-1, 1):
        for i in range(n):
            beam(f'te_cheek_{sz}_{i}', (1.5, i * h / n, sz * 1.15), (-0.5, (i + 1) * h / n, sz * 1.15), 0.16, white, parent)
        beam(f'te_aframe_{sz}', (0.3, 16.0, sz * 1.0), (-0.2, 0.6, sz * 9.0), 1.0, white, parent)
        beam(f'te_aframe_strut_{sz}', (0.3, 9.0, sz * 1.0), (-0.2, 1.6, sz * 6.0), 0.5, white, parent)
        block(f'te_clamp_{sz}', 0.5, 1.2, 0.8, 1.95, h - 2.5, sz * 1.0, white, parent, 0.05)
    block('te_hinge_beam', 2.6, 1.8, 19.0, -0.2, 0, 0, white, parent, 0.1)
    for z in (-2.2, -0.8, 0.8, 2.2):
        pipe(f'te_ram_{z}', (-2.2, -7.0, z), (-0.6, 10.0, z), 0.24, steel, parent)
        pipe(f'te_ram_rod_{z}', (-0.6, 10.0, z), (-0.4, 13.0, z), 0.13, M['steel'], parent)
    # the umbilical brackets flush on the vehicle face
    for y in (18.0, 36.0, 54.0):
        block(f'te_umbilical_{y}', 0.3, 1.3, 2.4, 1.55, y, 0, white, parent, 0.05)


def falcon_deck(M, parent):
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'pedestal_{sx}_{sz}', 1.8, 8.0, 1.8, sx * 3.1, 0, sz * 3.1, M['steel'], parent, 0.16)
    block('stool_ring_n', 11.0, 1.6, 2.1, 0, 8.0, 4.45, M['ml-grey'], parent, 0.18)
    block('stool_ring_s', 11.0, 1.6, 2.1, 0, 8.0, -4.45, M['ml-grey'], parent, 0.18)
    for s in (-1, 1):
        block(f'stool_ring_{s}', 2.1, 1.6, 6.8, s * 4.45, 8.0, 0, M['ml-grey'], parent, 0.18)
    # Grating on the ring's top only: the middle is the opening the nine Merlins
    # fire through.
    for s in (-1, 1):
        for i in range(8):
            block(f'falcon_grate_{s}_{i}', 0.22, 0.045, 1.6, -4.5 + i * 1.28, 9.6, s * 4.45,
                  M['darkcon'], parent, 0.012)
        pipe(f'falcon_fuel_{s}', (-13.0, 0.5, s * 1.5), (-5.0, 8.4, s * 1.5), 0.17, M['oxidized-copper'], parent)


def crew_tower(M, parent, arm_y):
    """39A's crew access tower in its own frame (vehicle on +x), dark-clad, with its
    lightning mast and the crew access arm parked along its face."""
    service_tower(M, parent, 'crew', CREW_TOWER_H, FSS_SIDE, M['fss-grey'], brace=1, rooms=0,
                  clad=M['dark-clad'], clad_from=4.0)
    block('crew_mast_base', 2.4, 3.0, 2.4, 0, CREW_TOWER_H, 0, M['steel'], parent, 0.06)
    cyl('crew_mast', 0.75, 0.32, *(CREW_TOWER_H + 3.0, CREW_TOWER_H + 3.0 + MAST_H), M['white'], seg=16, parent=parent)
    ax = FSS_SIDE * 0.5 + 1.8
    block('crew_arm', 3.0, 3.4, 19.0, ax, arm_y - 1.7, 9.5, M['white'], parent, 0.1)
    block('crew_white_room', 4.2, 4.0, 4.0, ax, arm_y - 2.0, 21.0, M['white'], parent, 0.1)
    block('crew_arm_hinge', 1.8, 4.0, 1.8, FSS_SIDE * 0.5 + 0.9, arm_y - 2.0, 0.6, M['steel'], parent, 0.06)


def starship_deck(M, parent):
    dark = M['darkcon']
    for i in range(6):
        a = math.tau * i / 6
        x, z = math.cos(a) * 12.0, math.sin(a) * 12.0
        ob = cyl(f'olm_leg_{i}', 2.4, 1.6, 0, 20.0, dark, seg=16, parent=parent)
        ob.location = xyz((x, 0, z))
        beam(f'olm_knee_{i}', (x, 11.0, z), (math.cos(a) * 15.3, 20.0, math.sin(a) * 15.3), 0.64, M['steel'], parent, 0.09)
    cyl('olm_table_outer', 14.0, 14.0, 20.0, 23.5, M['ml-grey'], seg=72, parent=parent)
    cyl('olm_table_inner', 6.5, 6.5, 20.0, 23.5, M['ml-grey'], seg=48, parent=parent)
    for r in (7.1, 13.4):
        finish(torus_z(f'olm_ring_{r}', r, 0.47, 23.5, M['steel'], seg=72, minor=8, parent=parent), 0.03, 2)
    for i in range(32):
        a = math.tau * i / 32
        ob = block(f'cooled_plate_{i}', 2.1, 0.16, 6.1, math.cos(a) * 10.2, 23.5, math.sin(a) * 10.2, M['steel'], parent, 0.035)
        ob.rotation_euler.z = -a
        if i % 4 == 0:
            block(f'clamp_{i}', 1.4, 2.8, 1.4, math.cos(a) * 7.4, 23.5, math.sin(a) * 7.4, M['paint'], parent, 0.13)
    for i in range(12):
        a = math.tau * i / 12
        pipe(f'water_manifold_{i}', (math.cos(a) * 14.7, 9.0, math.sin(a) * 14.7),
             (math.cos(a) * 13.1, 23.2, math.sin(a) * 13.1), 0.19, M['oxidized-copper'], parent)
    ob = cyl('deflector_plate', 11.0, 11.0, 0.0, 0.6, M['steel'], seg=48, parent=parent)
    block('booster_qd', 4.0, 5.0, 5.0, -13.5, 23.5, 0, M['dark-clad'], parent, 0.1)


# The catch arms, mirrored in sim/flight/launchsite.gd (ARM_* there): pivots at
# (6.8, 0, ±5.6) from the tower axis on a carriage that rides the tower, arms 36 m
# along +x, 1.6 m wide and 3.0 m deep, catch rails on top of the inner edge.
ARM_PIVOT_X, ARM_PIVOT_Z = 6.8, 5.6
ARM_LEN, ARM_W, ARM_D = 36.0, 1.6, 3.0
CARRIAGE_LAUNCH_Y = 62.0


def chopsticks(M, carriage):
    """The carriage frame around the tower, and two arms on driven pivots.

    Each `chopstick_<i>` empty is the driven node (identity rotation, yawed by
    launchsite.gd); everything that swings hangs under it, built along +x.
    """
    dark, paint = M['dark-clad'], M['paint']
    half = TOWER_HALF + 1.0
    for y in (-1.5, 3.9):
        for s in (-1, 1):
            block(f'carriage_ring_x_{y}_{s}', half * 2.0 + 1.2, 0.6, 1.2, 0, y, s * half, dark, carriage, 0.05)
            block(f'carriage_ring_z_{y}_{s}', 1.2, 0.6, half * 2.0, s * half, y, 0, dark, carriage, 0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'carriage_post_{sx}_{sz}', 1.0, 6.0, 1.0, sx * half, -1.5, sz * half, dark, carriage, 0.05)
            beam(f'carriage_brace_{sx}_{sz}', (sx * half, -0.9, sz * half), (sx * half, 3.9, -sz * half * 0.2),
                 0.35, dark, carriage)
            block(f'carriage_skate_{sx}_{sz}', 0.8, 2.4, 0.8, sx * (TOWER_HALF + 0.4), 0.3, sz * (TOWER_HALF + 0.4),
                  M['oxidized-copper'], carriage, 0.05)
    for i, sgn in enumerate((-1, 1)):
        z = sgn * ARM_PIVOT_Z
        block(f'pivot_housing_{i}', 2.4, 4.5, 2.4, ARM_PIVOT_X - 0.6, -0.75, z, paint, carriage, 0.12)
        pipe(f'pivot_pin_{i}', (ARM_PIVOT_X, -1.2, z), (ARM_PIVOT_X, 4.2, z), 0.45, M['steel'], carriage)
        pivot = empty(f'chopstick_{i}', xyz((ARM_PIVOT_X, 0, z)), carriage)
        arm_truss(M, pivot, i, sgn)


def arm_truss(M, pivot, i, sgn):
    dark, paint, rail = M['dark-clad'], M['paint'], M['safety-yellow']
    hw = ARM_W * 0.5
    for y0 in (0.0, ARM_D):
        for z0 in (-hw, hw):
            y1 = y0 if y0 == ARM_D else ARM_D * 0.45
            beam(f'arm{i}_chord_{y0}_{z0}', (0.0, y0, z0), (ARM_LEN, y1, z0), 0.4, dark, pivot)
    bays = 12
    for b in range(bays + 1):
        x = ARM_LEN * b / bays
        yb = ARM_D * 0.45 * (x / ARM_LEN)
        for z0 in (-hw, hw):
            beam(f'arm{i}_post_{b}_{z0}', (x, yb, z0), (x, ARM_D, z0), 0.28, dark, pivot)
        beam(f'arm{i}_tie_top_{b}', (x, ARM_D, -hw), (x, ARM_D, hw), 0.24, dark, pivot)
        beam(f'arm{i}_tie_bot_{b}', (x, yb, -hw), (x, yb, hw), 0.24, dark, pivot)
        if b < bays:
            x2 = ARM_LEN * (b + 1) / bays
            yb2 = ARM_D * 0.45 * (x2 / ARM_LEN)
            for z0 in (-hw, hw):
                beam(f'arm{i}_diag_{b}_{z0}', (x, yb, z0), (x2, ARM_D, z0), 0.22, dark, pivot)
    inner = -sgn * hw * 0.5
    block(f'arm{i}_rail', ARM_LEN * 0.5, 0.3, ARM_W * 0.5, ARM_LEN * 0.55, ARM_D - 0.3, inner, rail, pivot, 0.04)
    block(f'arm{i}_absorber', 3.0, 1.4, ARM_W * 0.9, ARM_LEN * 0.53, ARM_D - 1.7, 0, paint, pivot, 0.08)
    pipe(f'arm{i}_ram', (0.8, ARM_D * 0.5, 0.0), (7.0, ARM_D * 0.85, 0.0), 0.32, M['oxidized-copper'], pivot)


def build_pad(M):
    for name, color, rough, metal in (
        ('grey', 0x6e7276, 0.75, 0.35),
        ('darkcon', 0x5c5c58, 0.96, 0.02),
        ('concrete', 0x8d8d88, 0.95, 0.02),
        ('paint', 0x9c3f2e, 0.8, 0.1),
        ('safety-yellow', 0xd7ad38, 0.72, 0.04),
        ('oxidized-copper', 0x657a79, 0.58, 0.35),
        # tower paints, mirrored in launchsite.gd
        ('lut-red', 0xb3402a, 0.78, 0.12),
        ('fss-grey', 0x9a9fa3, 0.74, 0.22),
        ('dark-clad', 0x2e3236, 0.82, 0.15),
        ('stainless', 0xa9afb4, 0.48, 0.32),
        ('ml-grey', 0x7d8186, 0.8, 0.2),
    ):
        M[name] = material(name, srgb(color), rough, metal)
    # launchsite.gd swaps this for its own lamp material, whose glow follows the daylight
    M['lamp'] = material('lamp', srgb(0xfff1d6), 0.6, 0.0, emit=srgb(0xffdb9e), emit_strength=1.0)
    deck = empty('stage_deck', (0, 0, 0))
    if STYLE == 'lut':
        mobile_launcher(M, deck, LUT_ML[0], LUT_ML[1], DECK_HOLES['lut'])
        node = empty('stage_tower', xyz((LUT_X, ML_DECK, 0)))
        service_tower(M, node, 'lut', LUT_H, LUT_SIDE, M['lut-red'], brace=1, mid=True, flare=1.3, flare_h=12.2,
                      col=1.0, rooms=2)
        crane(M, node, 'crane', (0, LUT_H, 0), -1.75, M['lut-red'], 9.0)
        for z in (-3.6, -2.9, 3.0):
            pipe(f'lut_feed_{z}', (LUT_SIDE * 0.5 + 0.5, 0, z), (LUT_SIDE * 0.5 + 0.5, LUT_H * 0.9, z), 0.2, M['white'], node)
    elif STYLE == 'fss':
        mobile_launcher(M, deck, MLP_X[0], MLP_X[1], DECK_HOLES['fss'])
        node = empty('stage_tower', xyz((FSS_X, 0, 0)))
        service_tower(M, node, 'fss', FSS_H, FSS_SIDE, M['fss-grey'], brace=1, mid=True, rooms=2)
        crane(M, node, 'crane', (0, FSS_H, 0), math.pi, M['fss-grey'], 0.0)
        block('mast_base', 2.4, 3.0, 2.4, 0, FSS_H + 6.4, 0, M['steel'], node, 0.06)
        cyl('mast', 0.75, 0.32, FSS_H + 9.4, FSS_H + 9.4 + MAST_H, M['white'], seg=16, parent=node)
        rss = empty('stage_rss', (0, 0, 0))
        rotating_service_structure(M, rss)
    elif STYLE == 'strongback':
        falcon_deck(M, deck)
        te = empty('stage_strongback', (0, 0, 0))
        strongback(M, te)
        crew = empty('stage_crew', (0, 0, 0))
        # The parked arm's height follows Falcon 9's stack (70 m) on its 9.6 m mount.
        crew_tower(M, crew, 9.6 + 70.0 - 6.0)
    else:
        starship_deck(M, deck)
        node = empty('stage_tower', xyz((-TOWER_OFFSET, 0, 0)))
        service_tower(M, node, 'sb', 146.0, 12.0, M['stainless'], level=9.1, brace=1, floors=False, rooms=0,
                      col=1.1, core_mat=M['stainless'])
        block('sb_base', 16.0, 9.0, 16.0, -1.0, 0, 0, M['concrete'], node, 0.1)
        pipe('sb_lightning_rod', (0, 146.0, 0), (0, 156.0, 0), 0.2, M['steel'], node)
        carriage = empty('stage_carriage', xyz((-TOWER_OFFSET, CARRIAGE_LAUNCH_Y, 0)))
        chopsticks(M, carriage)


build('pad_' + STYLE, build_pad)
