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


def tower(M, x, base, height, side, parent, prefix, clear_px=False):
    """Bevelled corner columns, bracing, open catwalks, stairs and service runs.

    clear_px keeps everything behind the tower's +x face. A strongback stands
    0.9 m off the vehicle, and catwalks that overhang by 0.9 m reach the skin:
    that face carries only what mates with the vehicle, which launchsite.gd
    fits to the measured skin itself.
    """
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
        over = 0.0 if clear_px else 0.9
        for sign in (-1, 1):
            block(f'{prefix}_walk_x_{i}_{sign}', side + 0.9 + over, 0.18, 1.25,
                  x + (over - 0.9) * 0.5, y, sign * (h - 0.35), grey, parent, 0.018)
            inset = 0.65 if (clear_px and sign > 0) else 0.35
            block(f'{prefix}_walk_z_{i}_{sign}', 1.25, 0.18, side - 1.5,
                  x + sign * (h - inset), y, 0, grey, parent, 0.018)
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


# Exhaust openings (centre x, centre z, width x, depth z), m. The Saturn V ML has one
# 13.7 m square for the five F-1s. The Shuttle MLP has three: 6.1 × 12.8 m under each
# booster and 10.4 × 9.4 m under the main engines, 7.4 m off the tank axis toward the
# orbiter (+z). Mirrored in sim/flight/launchsite.gd for the fallback.
DECK_HOLES = {
    'lut': [(0.0, 0.0, 13.7, 13.7)],
    'fss': [(-6.35, 0.0, 6.1, 12.8), (6.35, 0.0, 6.1, 12.8), (0.0, 7.4, 10.4, 9.4)],
}


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


def mobile_deck(M, parent, holes):
    pw, pd, ph = 49.4, 41.1, 7.6
    for k, (x0, x1, z0, z1) in enumerate(deck_cells(pw, pd, holes)):
        block(f'deck_cell_{k}', x1 - x0, ph, z1 - z0, (x0 + x1) / 2,
              0, (z0 + z1) / 2, M['grey'], parent, min(0.28, (x1 - x0) * 0.1, (z1 - z0) * 0.1))
    hx = max(abs(h[0]) + h[2] / 2 for h in holes)
    # Deep visible girder band and catwalk/guardrail along all four sides.
    for s in (-1, 1):
        beam(f'edge_x_{s}', (-pw * 0.5, ph - 0.2, s * pd * 0.5),
             (pw * 0.5, ph - 0.2, s * pd * 0.5), 0.38, M['steel'], parent)
        beam(f'edge_z_{s}', (s * pw * 0.5, ph - 0.2, -pd * 0.5),
             (s * pw * 0.5, ph - 0.2, pd * 0.5), 0.38, M['steel'], parent)
        for i in range(10):
            z = -pd * 0.47 + i * pd * 0.104
            block(f'grate_{s}_{i}', 1.8, 0.045, 1.9,
                  s * (hx + 3.7), ph, z, M['darkcon'], parent, 0.012)
        for i in range(12):
            x = -pw * 0.46 + i * pw * 0.084
            pipe(f'rail_post_{s}_{i}', (x, ph, s * (pd * 0.5 - 0.25)),
                 (x, ph + 1.2, s * (pd * 0.5 - 0.25)), 0.06, M['safety-yellow'], parent)
        pipe(f'rail_top_{s}', (-pw * 0.5, ph + 1.2, s * (pd * 0.5 - 0.25)),
             (pw * 0.5, ph + 1.2, s * (pd * 0.5 - 0.25)), 0.07, M['safety-yellow'], parent)
    # A hazard line a metre outside every opening's edge — cut where it
    # would run across a NEIGHBOURING opening, as the Shuttle's three do.
    for k, (cx, cz, w, d) in enumerate(holes):
        for s in (-1, 1):
            lines = ((0.35, d + 2.35, cx + s * (w / 2 + 1.0), cz),
                     (w + 2.35, 0.35, cx, cz + s * (d / 2 + 1.0)))
            for j, (lw, ld, lx, lz) in enumerate(lines):
                for q, (x0, x1, z0, z1) in enumerate(deck_cells(lw, ld, holes, lx, lz)):
                    block(f'hazard_{k}_{s}_{j}_{q}', x1 - x0, 0.025, z1 - z0,
                          (x0 + x1) / 2, ph, (z0 + z1) / 2, M['safety-yellow'], parent, 0.005)
    # Ribs under the deck, split where they would cross an opening.
    for i in range(8):
        x = -pw * 0.42 + i * pw * 0.12
        cuts = sorted((h[1] - h[3] / 2, h[1] + h[3] / 2) for h in holes if abs(x - h[0]) < h[2] / 2 + 0.3)
        z = -pd * 0.465
        for k, (a, b) in enumerate(cuts + [(pd * 0.465, pd * 0.465)]):
            if a - z > 0.5:
                block(f'under_rib_{i}_{k}', 0.45, 1.1, a - z, x, 1.4, (a + z) / 2,
                      M['steel'], parent, 0.08)
            z = max(z, b)
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
    # Grating on the ring's top only. The middle is the OPENING the nine
    # Merlins fire through; grating laid across it put the bells' exhaust
    # into 8 m of steel.
    for s in (-1, 1):
        for i in range(8):
            x = -4.5 + i * 1.28
            block(f'falcon_grate_{s}_{i}', 0.22, 0.045, 1.6, x, 9.6, s * 4.45,
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


# The catch arms, mirrored in sim/flight/launchsite.gd (ARM_* there): pivots at
# (6.8, 0, ±5.6) from the tower axis on a carriage that rides the tower, arms 36 m
# along +x, 1.6 m wide and 3.0 m deep, catch rails on top of the inner edge.
ARM_PIVOT_X, ARM_PIVOT_Z = 6.8, 5.6
ARM_LEN, ARM_W, ARM_D = 36.0, 1.6, 3.0
TOWER_HALF = 6.0
CARRIAGE_LAUNCH_Y = 62.0


def chopsticks(M, carriage):
    """The carriage frame around the tower, and two arms on driven pivots.

    Each `chopstick_<i>` empty is the driven node (identity rotation, yawed by
    launchsite.gd); everything that swings hangs under it, built along +x.
    """
    steel, grey, paint, rail = M['steel'], M['grey'], M['paint'], M['safety-yellow']
    half = TOWER_HALF + 1.0
    # A box frame girdling the tower: top and bottom rings, corner posts, braces.
    for y in (-1.5, 3.9):
        for s in (-1, 1):
            block(f'carriage_ring_x_{y}_{s}', half * 2.0 + 1.2, 0.6, 1.2, 0, y, s * half, grey, carriage, 0.05)
            block(f'carriage_ring_z_{y}_{s}', 1.2, 0.6, half * 2.0, s * half, y, 0, grey, carriage, 0.05)
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'carriage_post_{sx}_{sz}', 1.0, 6.0, 1.0, sx * half, -1.5, sz * half, steel, carriage, 0.05)
            beam(f'carriage_brace_{sx}_{sz}', (sx * half, -0.9, sz * half), (sx * half, 3.9, -sz * half * 0.2),
                 0.35, steel, carriage)
    # Skate pads riding the tower's corner columns.
    for sx in (-1, 1):
        for sz in (-1, 1):
            block(f'carriage_skate_{sx}_{sz}', 0.8, 2.4, 0.8, sx * (TOWER_HALF + 0.4), 0.3, sz * (TOWER_HALF + 0.4),
                  M['oxidized-copper'], carriage, 0.05)
    for i, sgn in enumerate((-1, 1)):
        z = sgn * ARM_PIVOT_Z
        # The pivot housing on the carriage's face, and its hinge pin.
        block(f'pivot_housing_{i}', 2.4, 4.5, 2.4, ARM_PIVOT_X - 0.6, -0.75, z, paint, carriage, 0.12)
        pipe(f'pivot_pin_{i}', (ARM_PIVOT_X, -1.2, z), (ARM_PIVOT_X, 4.2, z), 0.45, steel, carriage)
        pivot = empty(f'chopstick_{i}', xyz((ARM_PIVOT_X, 0, z)), carriage)
        arm_truss(M, pivot, i, sgn)


def arm_truss(M, pivot, i, sgn):
    steel, paint, rail = M['steel'], M['paint'], M['safety-yellow']
    hw = ARM_W * 0.5
    # Four chords, tapering toward the tip.
    for y0 in (0.0, ARM_D):
        for z0 in (-hw, hw):
            y1 = y0 if y0 == ARM_D else ARM_D * 0.45
            beam(f'arm{i}_chord_{y0}_{z0}', (0.0, y0, z0), (ARM_LEN, y1, z0), 0.34, steel, pivot)
    bays = 12
    for b in range(bays + 1):
        x = ARM_LEN * b / bays
        yb = ARM_D * 0.45 * (x / ARM_LEN)        # the bottom chord's rise toward the tip
        for z0 in (-hw, hw):
            beam(f'arm{i}_post_{b}_{z0}', (x, yb, z0), (x, ARM_D, z0), 0.24, steel, pivot)
        beam(f'arm{i}_tie_top_{b}', (x, ARM_D, -hw), (x, ARM_D, hw), 0.22, steel, pivot)
        beam(f'arm{i}_tie_bot_{b}', (x, yb, -hw), (x, yb, hw), 0.22, steel, pivot)
        if b < bays:
            x2 = ARM_LEN * (b + 1) / bays
            yb2 = ARM_D * 0.45 * (x2 / ARM_LEN)
            for z0 in (-hw, hw):
                beam(f'arm{i}_diag_{b}_{z0}', (x, yb, z0), (x2, ARM_D, z0), 0.2, steel, pivot)
    # The catch rail on the inner top edge (toward the booster), where the pins land,
    # with its shock-absorber housing.
    inner = -sgn * hw * 0.5
    block(f'arm{i}_rail', ARM_LEN * 0.5, 0.3, ARM_W * 0.5, ARM_LEN * 0.55, ARM_D - 0.3, inner, rail, pivot, 0.04)
    block(f'arm{i}_absorber', 3.0, 1.4, ARM_W * 0.9, ARM_LEN * 0.53, ARM_D - 1.7, 0, paint, pivot, 0.08)
    # The hydraulic ram that swings the arm, mounted on the arm's root.
    pipe(f'arm{i}_ram', (0.8, ARM_D * 0.5, 0.0), (7.0, ARM_D * 0.85, 0.0), 0.32, M['oxidized-copper'], pivot)


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
        mobile_deck(M, deck, DECK_HOLES[STYLE])
        height = 116.0 if STYLE == 'lut' else 75.3
        tower_node = empty('stage_tower', xyz((-22.85, 7.6, 0)))
        tower(M, 0, 0, height, 12.2, tower_node, STYLE)
        if STYLE == 'fss':
            rss_node = empty('stage_rss', (0, 0, 0))
            shuttle_rss(M, rss_node)
    elif STYLE == 'strongback':
        falcon_deck(M, deck)
        strongback = empty('stage_strongback', (0, 0, 0))
        tower(M, 0, 0, 63.0, 3.4, strongback, STYLE, clear_px=True)
        # Brackets FLUSH on the vehicle face: 0.45 m proud of a face that
        # stands 0.9 m off the skin. They were 2.3 m deep once and stood a
        # metre inside the booster.
        for y in (18.0, 36.0, 54.0):
            block(f'umbilical_mount_{y}', 0.5, 1.3, 2.8,
                  1.7 + 0.2, y, 0, M['white'], strongback, 0.08)
    else:
        starship_deck(M, deck)
        tower_node = empty('stage_tower', xyz((-26.0, 0, 0)))
        tower(M, 0, 0, 146.0, 12.0, tower_node, STYLE)
        carriage = empty('stage_carriage', xyz((-26.0, CARRIAGE_LAUNCH_Y, 0)))
        chopsticks(M, carriage)


build('pad_' + STYLE, build_pad)
