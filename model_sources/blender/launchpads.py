"""Authored structural shells for the four flight launchpad styles.

The Godot launchsite owns motion, smoke and terrain. These meshes replace its
simple static tower/deck shapes when present; a fresh clone still uses the
procedural originals. Coordinates are metres with the mount's grade at Z=0.
"""
import math
import os
import sys
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import box, empty, finish, strut, torus_z
from common import build, srgb
from lib import material

args = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
STYLE = args[args.index('--style') + 1] if '--style' in args else 'lut'
if STYLE not in ('lut', 'fss', 'strongback', 'chopsticks'):
    raise ValueError(f'unknown pad style {STYLE}')


def xyz(p):
    """Godot (x, up, z) to Blender (x, -z, up)."""
    return (p[0], -p[2], p[1])


def block(name, width, height, depth, x, bottom, z, mat, parent=None, bevel=0.04):
    ob = box(name, (width, depth, height), xyz((x, bottom + height * 0.5, z)), mat, parent=parent)
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


def tower(M, x, base, height, side, parent, prefix):
    """Bevelled corner columns, bracing, open catwalks, stairs and service runs."""
    steel, grey, rail, copper = M['steel'], M['grey'], M['safety-yellow'], M['oxidized-copper']
    h = side * 0.5
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'{prefix}_column_{sx}_{sz}', 0.72, height, 0.72,
                  x + sx * h, base, sz * h, steel, parent, 0.08)
    bays = max(4, round(height / 7.0))
    for i in range(bays + 1):
        y = base + height * i / bays
        for sz in (-1, 1):
            beam(f'{prefix}_cross_x_{i}_{sz}', (x - h, y, sz * h),
                 (x + h, y, sz * h), 0.27, steel, parent)
        for sx in (-1, 1):
            beam(f'{prefix}_cross_z_{i}_{sx}', (x + sx * h, y, -h),
                 (x + sx * h, y, h), 0.27, steel, parent)
        if i == bays:
            continue
        y2 = base + height * (i + 1) / bays
        for sz in (-1, 1):
            beam(f'{prefix}_brace_x_{i}_{sz}', (x - h if i % 2 else x + h, y, sz * h),
                 (x + h if i % 2 else x - h, y2, sz * h), 0.23, steel, parent)
        for sx in (-1, 1):
            beam(f'{prefix}_brace_z_{i}_{sx}', (x + sx * h, y, -h if i % 2 else h),
                 (x + sx * h, y2, h if i % 2 else -h), 0.23, steel, parent)

    levels = max(3, round(height / 13.0))
    for i in range(1, levels + 1):
        y = base + height * i / levels
        # Perimeter grating leaves the centre visually open.
        for sign in (-1, 1):
            block(f'{prefix}_walk_x_{i}_{sign}', side + 1.8, 0.18, 1.25,
                  x, y, sign * (h - 0.35), grey, parent, 0.018)
            block(f'{prefix}_walk_z_{i}_{sign}', 1.25, 0.18, side - 1.5,
                  x + sign * (h - 0.35), y, 0, grey, parent, 0.018)
        # Guardrails and posts are full geometry rather than black lines.
        for sz in (-1, 1):
            for sx in (-1, 1):
                pipe(f'{prefix}_post_{i}_{sz}_{sx}', (x + sx * h, y, sz * (h + 0.55)),
                     (x + sx * h, y + 1.1, sz * (h + 0.55)), 0.045, rail, parent)
            pipe(f'{prefix}_rail_{i}_{sz}', (x - h, y + 1.1, sz * (h + 0.55)),
                 (x + h, y + 1.1, sz * (h + 0.55)), 0.055, rail, parent)
        if i < levels:
            y2 = base + height * (i + 1) / levels
            side_step = -1 if i % 2 else 1
            a = (x - h * 0.58, y + 0.2, side_step * 1.0)
            b = (x + h * 0.58, y2 - 0.1, side_step * 1.0)
            for off in (-0.48, 0.48):
                beam(f'{prefix}_stair_string_{i}_{off}',
                     (a[0], a[1], a[2] + off), (b[0], b[1], b[2] + off),
                     0.13, steel, parent)
            for step in range(1, 15):
                t = step / 15.0
                px = a[0] + (b[0] - a[0]) * t
                py = a[1] + (b[1] - a[1]) * t
                block(f'{prefix}_tread_{i}_{step}', 0.62, 0.08, 1.14,
                      px, py, a[2], grey, parent, 0.012)

    for sz in (-h - 0.65, -h - 0.25):
        pipe(f'{prefix}_fuel_line_{sz}', (x - h - 0.7, base + 0.2, sz),
             (x - h - 0.7, base + height * 0.94, sz), 0.14, copper, parent)
    for i in range(2, levels, 3):
        y = base + height * i / levels
        block(f'{prefix}_service_box_{i}', 2.0, 2.1, 1.4,
              x - h - 0.25, y + 0.2, h + 1.2, M['white'], parent, 0.12)


def mobile_deck(M, parent):
    pw, pd, ph, hole = 49.4, 41.1, 7.6, 13.7
    side_w, side_d = (pw - hole) * 0.5, (pd - hole) * 0.5
    for s in (-1, 1):
        block(f'deck_side_{s}', side_w, ph, pd, s * (hole + side_w) * 0.5,
              0, 0, M['grey'], parent, 0.28)
        block(f'deck_end_{s}', hole, ph, side_d, 0,
              0, s * (hole + side_d) * 0.5, M['grey'], parent, 0.28)
    # Deep visible girder band and catwalk/guardrail along all four sides.
    for s in (-1, 1):
        beam(f'edge_x_{s}', (-pw * 0.5, ph - 0.2, s * pd * 0.5),
             (pw * 0.5, ph - 0.2, s * pd * 0.5), 0.38, M['steel'], parent)
        beam(f'edge_z_{s}', (s * pw * 0.5, ph - 0.2, -pd * 0.5),
             (s * pw * 0.5, ph - 0.2, pd * 0.5), 0.38, M['steel'], parent)
        for i in range(10):
            z = -pd * 0.47 + i * pd * 0.104
            block(f'grate_{s}_{i}', 1.8, 0.045, 1.9,
                  s * (hole * 0.5 + 3.7), ph, z, M['darkcon'], parent, 0.012)
        for i in range(12):
            x = -pw * 0.46 + i * pw * 0.084
            pipe(f'rail_post_{s}_{i}', (x, ph, s * (pd * 0.5 - 0.25)),
                 (x, ph + 1.2, s * (pd * 0.5 - 0.25)), 0.06, M['safety-yellow'], parent)
        pipe(f'rail_top_{s}', (-pw * 0.5, ph + 1.2, s * (pd * 0.5 - 0.25)),
             (pw * 0.5, ph + 1.2, s * (pd * 0.5 - 0.25)), 0.07, M['safety-yellow'], parent)
        block(f'hazard_x_{s}', 0.35, 0.025, hole + 4.0,
              s * (hole * 0.5 + 1.4), ph, 0, M['safety-yellow'], parent, 0.005)
        block(f'hazard_z_{s}', hole + 4.0, 0.025, 0.35,
              0, ph, s * (hole * 0.5 + 1.4), M['safety-yellow'], parent, 0.005)
    for i in range(8):
        x = -pw * 0.42 + i * pw * 0.12
        block(f'under_rib_{i}', 0.45, 1.1, pd * 0.93, x, 1.4, 0,
              M['steel'], parent, 0.08)
    for i in range(4):
        x = -pw * 0.3 + i * pw * 0.2
        block(f'utility_{i}', 2.2, 1.7, 1.4, x, ph,
              pd * 0.5 - 3.2, M['white'], parent, 0.1)


def falcon_deck(M, parent):
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'pedestal_{sx}_{sz}', 1.8, 8.0, 1.8,
                  sx * 3.1, 0, sz * 3.1, M['steel'], parent, 0.16)
    block('stool_ring_n', 11.0, 1.6, 2.1, 0, 8.0, 4.45, M['grey'], parent, 0.18)
    block('stool_ring_s', 11.0, 1.6, 2.1, 0, 8.0, -4.45, M['grey'], parent, 0.18)
    for s in (-1, 1):
        block(f'stool_ring_{s}', 2.1, 1.6, 6.8,
              s * 4.45, 8.0, 0, M['grey'], parent, 0.18)
    for i in range(8):
        x = -4.5 + i * 1.28
        block(f'falcon_grate_{i}', 0.22, 0.045, 8.2, x, 9.6, 0,
              M['darkcon'], parent, 0.012)
    for s in (-1, 1):
        pipe(f'falcon_fuel_{s}', (-13.0, 0.5, s * 1.5),
             (-5.0, 8.4, s * 1.5), 0.17, M['oxidized-copper'], parent)


def shuttle_rss(M, parent):
    """Open, ribbed rotating service structure; the old one was one huge cube."""
    for x in (5.0, 23.0):
        for z in (-7.0, 7.0):
            block(f'rss_post_{x}_{z}', 0.7, 40.0, 0.7,
                  x, 12.0, z, M['steel'], parent, 0.08)
    for level in range(6):
        y = 12.0 + level * 8.0
        for z in (-7.0, 7.0):
            beam(f'rss_face_rail_{level}_{z}', (5.0, y, z),
                 (23.0, y, z), 0.38, M['steel'], parent)
        for x in (5.0, 23.0):
            beam(f'rss_side_rail_{level}_{x}', (x, y, -7.0),
                 (x, y, 7.0), 0.38, M['steel'], parent)
        if level < 5:
            block(f'rss_platform_{level}', 16.8, 0.22, 12.8,
                  14.0, y, 0, M['grey'], parent, 0.03)
            # Cladding is a succession of shallow panels with real voids.
            for z in (-7.2, 7.2):
                for bay in range(3):
                    block(f'rss_panel_{level}_{z}_{bay}', 5.2, 5.8, 0.18,
                          8.1 + bay * 5.9, y + 1.0, z,
                          M['white'], parent, 0.10)
            for x in (5.0, 23.0):
                beam(f'rss_diagonal_{level}_{x}', (x, y, -7.0),
                     (x, y + 8.0, 7.0), 0.25, M['steel'], parent)
            for j in range(8):
                block(f'rss_grate_{level}_{j}', 0.12, 0.035, 12.0,
                      6.2 + j * 2.15, y + 0.22, 0,
                      M['darkcon'], parent, 0.007)
    for y in (19.5, 35.5, 51.5):
        for z in (-6.0, 6.0):
            pipe(f'rss_umbilical_{y}_{z}', (5.0, y, z),
                 (0.5, y + 0.5, z), 0.16, M['oxidized-copper'], parent)


def starship_deck(M, parent):
    for i in range(6):
        a = math.tau * i / 6
        x, z = math.cos(a) * 12.0, math.sin(a) * 12.0
        block(f'olm_column_{i}', 3.2, 20.0, 3.2, x, 0, z,
              M['grey'], parent, 0.26)
        beam(f'olm_knee_{i}', (x, 11.0, z),
             (math.cos(a) * 15.3, 20.0, math.sin(a) * 15.3),
             0.64, M['steel'], parent, 0.09)
    for r in (7.1, 13.4):
        ob = torus_z(f'olm_ring_{r}', r, 0.47, 23.5,
                     M['steel'], seg=72, minor=8, parent=parent)
        finish(ob, 0.03, 2)
    for i in range(32):
        a = math.tau * i / 32
        x, z = math.cos(a) * 10.2, math.sin(a) * 10.2
        ob = block(f'cooled_plate_{i}', 2.1, 0.16, 6.1,
                   x, 23.5, z, M['steel'], parent, 0.035)
        ob.rotation_euler.z = -a
        if i % 4 == 0:
            block(f'clamp_{i}', 1.4, 2.8, 1.4,
                  math.cos(a) * 7.4, 23.5, math.sin(a) * 7.4,
                  M['paint'], parent, 0.13)
    for i in range(12):
        a = math.tau * i / 12
        pipe(f'water_manifold_{i}', (math.cos(a) * 14.7, 9.0, math.sin(a) * 14.7),
             (math.cos(a) * 13.1, 23.2, math.sin(a) * 13.1),
             0.19, M['oxidized-copper'], parent)


def build_pad(M):
    for name, color, rough, metal in (
        ('grey', 0x6e7276, 0.75, 0.35),
        ('darkcon', 0x5c5c58, 0.96, 0.02),
        ('paint', 0x9c3f2e, 0.8, 0.1),
        ('safety-yellow', 0xd7ad38, 0.72, 0.04),
        ('oxidized-copper', 0x657a79, 0.58, 0.35),
    ):
        M[name] = material(name, srgb(color), rough, metal)
    deck = empty('stage_deck', (0, 0, 0))
    if STYLE in ('lut', 'fss'):
        mobile_deck(M, deck)
        height = 116.0 if STYLE == 'lut' else 75.3
        tower_node = empty('stage_tower', xyz((-22.85, 7.6, 0)))
        tower(M, 0, 0, height, 12.2, tower_node, STYLE)
        if STYLE == 'fss':
            rss_node = empty('stage_rss', (0, 0, 0))
            shuttle_rss(M, rss_node)
    elif STYLE == 'strongback':
        falcon_deck(M, deck)
        strongback = empty('stage_strongback', (0, 0, 0))
        tower(M, 0, 0, 63.0, 3.4, strongback, STYLE)
        for y in (18.0, 36.0, 54.0):
            block(f'umbilical_mount_{y}', 2.3, 1.3, 2.8,
                  2.2, y, 0, M['white'], strongback, 0.12)
    else:
        starship_deck(M, deck)
        tower_node = empty('stage_tower', xyz((-26.0, 0, 0)))
        tower(M, 0, 0, 146.0, 12.0, tower_node, STYLE)


build('pad_' + STYLE, build_pad)
