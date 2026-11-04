"""THE OBSERVATORIES — every structure the Observatory mode stands among.

One library, assets/sites/observatories.glb, with one `stage_<name>` per structure,
built with its own datum at y = 0. sim/observatory/facilities.gd places them from
their published coordinates and sim/observatory/site_scene.gd instances them by name,
so the NAMES ARE AN INTERFACE. Driven pivots are `door_<stage>_<part>` nodes: the
optimiser keeps that prefix separate and they carry identity rotation.

Built with the boresight on +Y (el = 90°) and the azimuth reference on +Z. An el pivot
turns about +X by (90° − el) and an az pivot about +Y by −azimuth.

Sources (photographs are references only; nothing from them is in this file's output):
  Lovell: JBO "Lovell Telescope facts and figures": bowl 76.2 m, focal length 22.9 m,
    elevation axis 50.5 m, 89.0 m overall, wheel girders 38.5 m radius, track 107.5 m.
    JBO "Mark I": the bowl rests on bearings atop two towers, the thin stabilising
    girder under it, motors at each tower's foot. Member layout from photographs
    (Wikimedia Commons, Lovell Telescope 1, 3, 6, 16).
  Mark II: 38.1 × 25.4 m ellipse, 12.2 m focal length, 12.8 m roller track (Wikipedia,
    "Mark II (radio telescope)"); pylons and base from photographs.
  Keck: 10 m of 36 segments 1.8 m across, 17.5 m focal length (Keck, Wikipedia); domes
    "about 100 ft high", 700,000 ft³; the rest from photographs.
  VLT UT: 8.2 m primary, 14.4 m focus (ESO); slit "almost 12 metre wide" (ESO eso9414c);
    fixed drum and rotating dome (EIE, "The Enclosures"); ESO gives the height as both
    25 m and 35 m, so 29 m × 28.5 m is read from photographs against the known 8.2 m
    mirror and the UT spacing. AT from photographs against its 1.8 m mirror.

Where a size is read from a photograph it is an estimate. No part is a survey.
"""
import math
import os
import sys
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import box, empty, revolve, lathe, ball, smooth, material, _obj
from common import build, srgb

TAU = math.tau
_count = [0]


def nm(p='p'):
    _count[0] += 1
    return f'{p}_{_count[0]}'


def P(x, y, z):
    """Godot (x, up, z) to Blender (x, -z, up)."""
    return (x, -z, y)


def beam(par, a, b, w, mat, d=None):
    """A square member from a to b, Godot coordinates. Lattices are made of thousands,
    so no bevels: twelve triangles each."""
    p, q = Vector(P(*a)), Vector(P(*b))
    v = q - p
    if v.length < 1e-3:
        return None
    ob = box(nm('m'), (w, d or w, v.length), (p + q) * 0.5, mat, parent=par)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(v.normalized())
    return ob


def blk(par, w, h, d, x, y, z, mat, yaw=0.0):
    """A box standing on (x, y, z): w along x, h up, d along z."""
    ob = box(nm('b'), (w, d, h), P(x, y + h * 0.5, z), mat, parent=par)
    if yaw:
        ob.rotation_euler = (0, 0, yaw)
    return ob


def rev(par, profile, mat, x=0.0, y=0.0, z=0.0, seg=64, sm=40):
    """A body of revolution about the vertical through (x, z); `profile` is (r, height)."""
    ob = revolve(nm('rev'), profile, mat, seg=seg, parent=par)
    ob.location = P(x, y, z)
    smooth(ob, sm)
    return ob


def cyl_x(par, r, x0, x1, y, z, mat, seg=20):
    """A cylinder along Godot x."""
    ob = revolve(nm('cx'), [(0, 0), (r, 0), (r, x1 - x0), (0, x1 - x0)], mat, seg=seg, parent=par)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(Vector((1, 0, 0)))
    ob.location = P(x0, y, z)
    smooth(ob, 40)
    return ob


def circle(cx, cy, cz, r, a, axis='y'):
    """A point on a circle of radius r about (cx, cy, cz), its plane normal to `axis`."""
    c, s = math.cos(a), math.sin(a)
    if axis == 'y':
        return (cx + r * c, cy, cz + r * s)
    return (cx, cy + r * c, cz + r * s)      # plane normal to x


def ring(par, r, y, w, mat, n=48, a0=0.0, a1=TAU, cx=0.0, cz=0.0):
    pts = [circle(cx, y, cz, r, a0 + (a1 - a0) * i / n) for i in range(n + 1)]
    for p, q in zip(pts, pts[1:]):
        beam(par, p, q, w, mat)


def lattice_leg(par, a, b, w0, w1, axis, n, mat, chord=0.22, web=0.14):
    """A four-chord lattice column from a to b, w0 → w1 across, with zig-zag webs.
    `axis` is any direction not along it, setting which way its faces look."""
    a, b = Vector(a), Vector(b)
    d = (b - a).normalized()
    u = Vector(axis).cross(d).normalized()
    v = d.cross(u).normalized()
    corners = ((1, 1), (-1, 1), (-1, -1), (1, -1))
    stations = []
    for i in range(n + 1):
        t = i / n
        c = a.lerp(b, t)
        hw = (w0 + (w1 - w0) * t) * 0.5
        stations.append([c + u * (s * hw) + v * (q * hw) for s, q in corners])
    for k in range(4):
        beam(par, tuple(stations[0][k]), tuple(stations[-1][k]), chord, mat)
    for i in range(n):
        for k in range(4):
            beam(par, tuple(stations[i][k]), tuple(stations[i][(k + 1) % 4]), web, mat)
            beam(par, tuple(stations[i][k]), tuple(stations[i + 1][(k + 1) % 4]), web, mat)


def windows(par, face_x, face_z, y0, cols, rows, dx, dy, mat, axis='z', w=0.9, h=1.1):
    """A grid of dark window panes standing proud of a wall."""
    for i in range(cols):
        for j in range(rows):
            off = (i - (cols - 1) * 0.5) * dx
            y = y0 + j * dy
            if axis == 'z':
                blk(par, w, h, 0.12, face_x + off, y, face_z, mat)
            else:
                blk(par, 0.12, h, w, face_x, y, face_z + off, mat)


def gable_prism(par, name, x0, x1, y0, y_eave, y_ridge, z0, z1, mat):
    """A roof module along z: walls to y_eave, ridged at y_ridge above the x middle."""
    xm = (x0 + x1) * 0.5
    section = [(x0, y0), (x1, y0), (x1, y_eave), (xm, y_ridge), (x0, y_eave)]
    verts = [P(x, y, z0) for x, y in section] + [P(x, y, z1) for x, y in section]
    n = len(section)
    faces = [tuple(range(n - 1, -1, -1)), tuple(range(n, 2 * n))]
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    return _obj(name, verts, faces, mat, par)


# THE LOVELL TELESCOPE
LOVELL_R = 38.1            # bowl radius, m
LOVELL_F = 22.9            # focal length
LOVELL_AXIS = 50.5         # elevation axis above the ground
LOVELL_WHEEL = 38.5        # wheel girder radius
LOVELL_TRACK = 107.5 / 2   # outer rail radius
# The rim plane above the axis at the zenith, from photographs. Depth r²/4f = 15.85 m.
LOVELL_RIM_Y = 9.0


def lovell_bowl(M, el):
    white, grey, dark = M['lovell'], M['lovell-grey'], M['dark-steel']
    vy = LOVELL_RIM_Y - LOVELL_R ** 2 / (4 * LOVELL_F)     # vertex, relative to the axis
    surf = lambda r: vy + r * r / (4 * LOVELL_F)

    # The reflecting surface, then its seams: 7 rings and 28 ribs a hair proud.
    prof = [(LOVELL_R * i / 28, surf(LOVELL_R * i / 28)) for i in range(29)]
    rev(el, prof, white, seg=96, sm=60)
    for i in range(1, 8):
        r = LOVELL_R * i / 8
        rev(el, [(r - 0.05, surf(r) + 0.03), (r + 0.05, surf(r) + 0.03)], M['seam'], seg=72)
    for k in range(28):
        a = TAU * k / 28
        rs = [LOVELL_R * (0.125 + 0.875 * i / 6) for i in range(7)]
        for r0, r1 in zip(rs, rs[1:]):
            beam(el, (r0 * math.cos(a), surf(r0) + 0.03, r0 * math.sin(a)),
                 (r1 * math.cos(a), surf(r1) + 0.03, r1 * math.sin(a)), 0.06, M['seam'])
    # The underside: dark sheeting and the purlins carrying it.
    rev(el, [(r, y - 0.55) for r, y in prof], M['bowl-back'], seg=64, sm=60)
    for i in range(2, 8):
        ring(el, LOVELL_R * i / 8, surf(LOVELL_R * i / 8) - 0.9, 0.22, dark, n=48)
    for k in range(48):
        a = TAU * k / 48
        rs = [LOVELL_R * (0.2 + 0.8 * i / 4) for i in range(5)]
        for r0, r1 in zip(rs, rs[1:]):
            beam(el, (r0 * math.cos(a), surf(r0) - 1.0, r0 * math.sin(a)),
                 (r1 * math.cos(a), surf(r1) - 1.0, r1 * math.sin(a)), 0.26, dark)
    # The rim: a corrugated grey skirt round the lip, ribbed.
    y = LOVELL_RIM_Y
    rev(el, [(LOVELL_R - 0.1, y + 0.05), (LOVELL_R + 0.35, y + 0.15), (LOVELL_R + 0.9, y - 4.6),
             (LOVELL_R - 0.5, y - 5.0)], grey, seg=96, sm=20)
    for k in range(96):
        a = TAU * k / 96
        beam(el, ((LOVELL_R + 0.42) * math.cos(a), y + 0.1, (LOVELL_R + 0.42) * math.sin(a)),
             ((LOVELL_R + 0.97) * math.cos(a), y - 4.6, (LOVELL_R + 0.97) * math.sin(a)), 0.1, M['seam'])

    # THE DRUM: the cylindrical space-frame the bowl sits in, carried by the trunnions.
    R = LOVELL_R - 0.5
    levels = [y - 5.0, y - 11.5, y - 20.5]
    n = 24
    for lv in levels:
        ring(el, R, lv, 0.5, white, n=n)
    for k in range(n):
        a0, a1 = TAU * k / n, TAU * (k + 1) / n
        for lo, hi in zip(levels[1:], levels[:-1]):
            beam(el, circle(0, hi, 0, R, a0), circle(0, lo, 0, R, a0), 0.42, white)
            # Big diagonals crossing each bay, tied at the middle as in the photographs.
            beam(el, circle(0, hi, 0, R, a0), circle(0, lo, 0, R, a1), 0.3, white)
            beam(el, circle(0, hi, 0, R, a1), circle(0, lo, 0, R, a0), 0.3, white)
        # A second skin inside, trussed back to the bowl.
        beam(el, circle(0, levels[0], 0, R, a0), circle(0, surf(R * 0.72) - 0.6, 0, R * 0.72, a0), 0.26, white)
        beam(el, circle(0, levels[1], 0, R, a0), circle(0, surf(R * 0.72) - 0.6, 0, R * 0.72, a1), 0.2, white)

    # The lower plane: radial trusses meeting at a hub under the vertex.
    hub_y, low = vy - 2.5, levels[-1]
    ring(el, R * 0.5, low + 1.0, 0.3, white, n=24)
    for k in range(n):
        a = TAU * k / n
        beam(el, circle(0, low, 0, R, a), circle(0, low + 1.0, 0, R * 0.5, a), 0.34, white)
        beam(el, circle(0, low + 1.0, 0, R * 0.5, a), (0, hub_y - 2.0, 0), 0.28, white)
        beam(el, circle(0, low + 1.0, 0, R * 0.5, a), (0, hub_y, 0), 0.2, white)
        if k % 2 == 0:
            beam(el, circle(0, low + 1.0, 0, R * 0.5, a), circle(0, surf(R * 0.5) - 0.6, 0, R * 0.5, a), 0.22, white)
            beam(el, circle(0, low, 0, R, a), circle(0, low + 1.0, 0, R * 0.5, a + TAU / n), 0.18, white)

    # The trunnion girders: across the drum on the axis, to the bearings on each side.
    tx = LOVELL_R + 2.6
    for z in (-7.0, 7.0):
        beam(el, (-R, 0.0, z), (R, 0.0, z), 0.8, white)
        for s in (-1, 1):
            beam(el, (s * tx, 0.0, 0.0), (s * R, 0.0, z), 0.8, white)
    for i in range(13):
        x = -R + 2 * R * i / 12
        beam(el, (x, 0.0, -7.0), (x, 0.0, 7.0), 0.28, white)
        beam(el, (x, 0.0, -7.0), (x, -6.0, 0.0), 0.2, white)
        beam(el, (x, 0.0, 7.0), (x, -6.0, 0.0), 0.2, white)
    beam(el, (-R, -6.0, 0.0), (R, -6.0, 0.0), 0.5, white)
    for s in (-1, 1):
        # The 25 ft internal gear taken from a battleship's gun turret, and its trunnion.
        cyl_x(el, 3.81, s * tx - (0.5 if s > 0 else -0.1), s * tx + (0.1 if s > 0 else 0.5), 0.0, 0.0, M['dark-steel'], seg=32)
        cyl_x(el, 1.6, min(s * R, s * tx), max(s * R, s * tx), 0.0, 0.0, white, seg=20)

    # THE WHEEL: the great circular stabilising girder, in the plane through the axle's
    # middle, its double rim swept under the bowl and spoked back to the frame.
    rim = lambda a, x: (x, -LOVELL_WHEEL * math.cos(a), LOVELL_WHEEL * math.sin(a))
    span = math.radians(72)
    m = 30
    for i in range(m):
        a0, a1 = -span + 2 * span * i / m, -span + 2 * span * (i + 1) / m
        for x in (-2.6, 2.6):
            beam(el, rim(a0, x), rim(a1, x), 0.46, white)
        beam(el, rim(a0, -2.6), rim(a0, 2.6), 0.2, white)
        beam(el, rim(a0, -2.6), rim(a1, 2.6), 0.14, white)
        if i % 2 == 0:
            # Spokes, fanning up to the hub and the trunnion girders.
            beam(el, rim(a0, 0.0), (0, hub_y, 0), 0.3, white)
            beam(el, rim(a0, -2.6), (-9.0, low + 0.5, LOVELL_WHEEL * 0.55 * math.sin(a0)), 0.2, white)
            beam(el, rim(a0, 2.6), (9.0, low + 0.5, LOVELL_WHEEL * 0.55 * math.sin(a0)), 0.2, white)
    # The side arcs that make the wheel a shallow basket, seen in the photographs as
    # the two curves converging at the bottom.
    for x in (-19.0, 19.0):
        rx = math.sqrt(LOVELL_WHEEL ** 2 - x ** 2)
        sp = math.radians(58)
        for i in range(16):
            a0, a1 = -sp + 2 * sp * i / 16, -sp + 2 * sp * (i + 1) / 16
            p = (x, -rx * math.cos(a0), rx * math.sin(a0))
            q = (x, -rx * math.cos(a1), rx * math.sin(a1))
            beam(el, p, q, 0.3, white)
            if i % 2 == 0:
                beam(el, p, (0.0, -LOVELL_WHEEL * math.cos(a0) * 0.98, LOVELL_WHEEL * math.sin(a0) * 0.98), 0.16, white)
                beam(el, p, (x * 0.8, low + 0.5, p[2] * 0.7), 0.18, white)

    # THE FOCAL MAST: a lattice tower from the vertex to the focus box.
    base, top = vy + 0.1, vy + LOVELL_F - 1.5
    lattice_leg(el, (0, base, 0), (0, top, 0), 3.4, 1.0, (1, 0, 0), 9, white, 0.14, 0.07)
    blk(el, 4.2, 2.6, 4.2, 0, base, 0, white)
    blk(el, 3.0, 2.6, 3.0, 0, top - 0.2, 0, white)
    blk(el, 2.0, 1.2, 2.0, 0, top + 2.4, 0, M['lovell-grey'])
    for x, z in ((1.7, 1.7), (-1.7, 1.7), (-1.7, -1.7), (1.7, -1.7)):
        beam(el, (x, top - 0.3, z), (x, top + 0.8, z), 0.07, white)


def lovell_tower(M, az, s):
    white, glass = M['lovell'], M['glass']
    top = (s * (LOVELL_R + 6.0), LOVELL_AXIS - 18.5, 0.0)
    foot_x = s * (LOVELL_TRACK - 2.0)
    for z in (-26.0, 26.0):
        # The raked legs, foot on the track, head under the machine house.
        lattice_leg(az, (foot_x, 1.6, z), (top[0], top[1], z * 0.13), 3.6, 2.6, (1, 0, 0), 9, white, 0.3, 0.14)
        # The bogie.
        blk(az, 9.0, 1.6, 4.5, foot_x, 0.0, z, M['dark-steel'])
        for dx in (-3, -1, 1, 3):
            cyl_x(az, 0.55, foot_x + dx - 0.25, foot_x + dx + 0.25, 0.55, z - 2.3, M['rail'], seg=10)
            cyl_x(az, 0.55, foot_x + dx - 0.25, foot_x + dx + 0.25, 0.55, z + 2.3, M['rail'], seg=10)
        # The 1976 diagonal bracing girders, back in to the column.
        beam(az, (foot_x, 1.6, z), (s * (LOVELL_R + 8.0), 22.0, 0.0), 0.5, white)
    # The central column and the ties across the legs.
    lattice_leg(az, (s * (LOVELL_TRACK - 8.0), 0.8, 0), top, 4.5, 3.4, (0, 0, 1), 9, white, 0.3, 0.14)
    for h in (8.0, 15.5, 23.0):
        t = (h - 1.6) / (top[1] - 1.6)
        x = foot_x + (top[0] - foot_x) * t
        z = 26.0 + (26.0 * 0.13 - 26.0) * t
        beam(az, (x, h, -z), (x, h, z), 0.5, white)
        beam(az, (x, h, -z), (x - s * 7.0, h + 3.0, 0.0), 0.3, white)
        beam(az, (x, h, z), (x - s * 7.0, h + 3.0, 0.0), 0.3, white)

    # THE MACHINE HOUSE: the stepped white block holding the elevation drive, windows
    # high in each face.
    x = s * (LOVELL_R + 6.2)
    y = top[1] - 0.4
    for w, h, d in ((8.0, 9.0, 11.0), (7.0, 8.0, 9.0), (6.0, 7.0, 7.0)):
        blk(az, w, h, d, x, y, 0, white)
        # A batten line round each step, to read at distance.
        blk(az, w + 0.25, 0.25, d + 0.25, x, y + h - 0.25, 0, M['lovell-grey'])
        if h > 4.0:
            for k in range(1, 3):
                yy = y + h * k / 3 - 0.5
                windows(az, x, d * 0.5 + 0.03, yy, 3, 1, w / 4.0, 0, glass)
                windows(az, x, -d * 0.5 - 0.03, yy, 3, 1, w / 4.0, 0, glass)
                windows(az, x + s * (w * 0.5 + 0.03), 0.0, yy, 2, 1, d / 3.5, 0, glass, axis='x')
        y += h
    # The jib crane on the roof.
    beam(az, (x, y, 0), (x - s * 3.5, y + 1.2, 0), 0.22, M['lovell-grey'])
    # The rotator ring the trunnion turns in.
    cyl_x(az, 4.1, min(x - s * 4.0, x - s * 5.0), max(x - s * 4.0, x - s * 5.0), LOVELL_AXIS, 0.0, white, seg=32)
    # The drive motor at the tower's foot.
    blk(az, 4.0, 2.4, 3.0, foot_x - s * 5.0, 0.0, 0.0, M['dark-steel'])


def lovell(M):
    st = empty('stage_lovell', (0, 0, 0))
    # THE TRACK: a double railway on a concrete ring, sunk on 27 m foundations.
    for r, w in ((LOVELL_TRACK - 1.0, 3.4), (LOVELL_TRACK - 11.0, 2.4)):
        rev(st, [(r - w, 0.02), (r - w, 0.35), (r + w, 0.35), (r + w, 0.02)], M['concrete'], seg=96, sm=20)
        for dr in (-0.72, 0.72):
            rev(st, [(r + dr - 0.09, 0.35), (r + dr - 0.09, 0.55), (r + dr + 0.09, 0.55), (r + dr + 0.09, 0.35)], M['rail'], seg=96, sm=20)
    # The central pivot, delivered 1954, and the plinth round it.
    rev(st, [(0, 0.02), (7.0, 0.02), (7.0, 1.4), (3.4, 1.8), (3.4, 4.4), (0, 4.4)], M['concrete'], seg=32, sm=20)

    az = empty('door_lovell_az', (0, 0, 0), st)
    # The base frame between the towers: deep trusses across the diameter.
    for z in (-10.0, 10.0):
        beam(az, (-LOVELL_TRACK + 2, 1.2, z), (LOVELL_TRACK - 2, 1.2, z), 0.7, M['lovell'])
        beam(az, (-LOVELL_TRACK + 8, 9.0, z), (LOVELL_TRACK - 8, 9.0, z), 0.6, M['lovell'])
        for i in range(19):
            x = -LOVELL_TRACK + 2 + (2 * LOVELL_TRACK - 4) * i / 18
            xu = -LOVELL_TRACK + 8 + (2 * LOVELL_TRACK - 16) * i / 18
            beam(az, (x, 1.2, z), (xu, 9.0, z), 0.3, M['lovell'])
            if i < 18:
                xu2 = -LOVELL_TRACK + 8 + (2 * LOVELL_TRACK - 16) * (i + 1) / 18
                beam(az, (x, 1.2, z), (xu2, 9.0, z), 0.2, M['lovell'])
    for i in range(10):
        x = -LOVELL_TRACK + 8 + (2 * LOVELL_TRACK - 16) * i / 9
        beam(az, (x, 9.0, -10.0), (x, 9.0, 10.0), 0.3, M['lovell'])
        beam(az, (x, 1.2, -10.0), (x, 1.2, 10.0), 0.3, M['lovell'])
    for s in (-1, 1):
        lovell_tower(M, az, s)
    # The small swinging laboratory under the bowl hangs from the frame.
    blk(az, 7.0, 3.0, 5.0, 0, 9.3, 0, M['lovell-grey'])
    windows(az, 0, 2.55, 10.2, 3, 1, 2.0, 0, M['glass'])

    el = empty('door_lovell_el', P(0, LOVELL_AXIS, 0), az)
    lovell_bowl(M, el)


def mark2(M):
    st = empty('stage_mark2', (0, 0, 0))
    # A white concrete drum holding the roller track, then the plant room above.
    rev(st, [(0, 0.0), (13.2, 0.0), (13.2, 5.0), (0, 5.0)], M['lovell'], seg=64, sm=20)
    windows(st, 0.0, 13.3, 2.4, 2, 1, 7.0, 0, M['glass'], w=2.2, h=1.0)
    az = empty('door_mark2_az', P(0, 5.0, 0), st)
    blk(az, 12.0, 6.0, 9.0, 0, 0, 0, M['lovell'])
    windows(az, 0, 4.55, 3.0, 2, 1, 5.0, 0, M['glass'], w=1.0, h=2.2)
    # The two raking concrete pylons up to the bearings, their faces flat.
    axis_y = 18.0
    for s in (-1, 1):
        x0, x1 = s * 10.2, s * 16.2
        verts = [P(x0, 0, -4.0), P(x0, 0, 4.0), P(x0 + s * 3.4, 0, 4.0), P(x0 + s * 3.4, 0, -4.0),
                 P(x1 - s * 1.0, axis_y, -1.6), P(x1 - s * 1.0, axis_y, 1.6), P(x1 + s * 1.0, axis_y, 1.6), P(x1 + s * 1.0, axis_y, -1.6)]
        faces = [(0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        _obj(nm('pylon'), verts, faces, M['concrete'], az)
    el = empty('door_mark2_el', P(0, axis_y, 0), az)
    a, b, f = 38.1 / 2, 25.4 / 2, 12.2
    # An elliptical bowl, built as a grid of (u, v) on the unit disc.
    n_r, n_t = 16, 64
    vy = -9.5
    verts, faces = [], []
    for i in range(n_r + 1):
        r = i / n_r
        for k in range(n_t):
            t = TAU * k / n_t
            x, z = a * r * math.cos(t), b * r * math.sin(t)
            verts.append(P(x, vy + (x * x + z * z) / (4 * f), z))
    for i in range(n_r):
        for k in range(n_t):
            k2 = (k + 1) % n_t
            faces.append((i * n_t + k, i * n_t + k2, (i + 1) * n_t + k2, (i + 1) * n_t + k))
    ob = _obj(nm('m2dish'), verts, faces, M['lovell'], el)
    smooth(ob, 60)
    # The 1987 circular surface laid over the old one, leaving the ears at each end.
    rm = b + 1.2
    rev(el, [(rm - 0.12, vy + rm * rm / (4 * f) + 0.06), (rm + 0.12, vy + rm * rm / (4 * f) + 0.06)], M['seam'], seg=64)
    # The back frame: a lattice box behind the dish to the trunnions.
    for t in range(12):
        ang = TAU * t / 12
        x, z = a * 0.9 * math.cos(ang), b * 0.9 * math.sin(ang)
        beam(el, (x, vy + (x * x + z * z) / (4 * f) - 0.3, z), (0.0, vy - 2.0, 0.0), 0.3, M['lovell'])
        beam(el, (x, vy + (x * x + z * z) / (4 * f) - 0.3, z), (math.copysign(15.0, x), 0.0, 0.0), 0.3, M['lovell'])
        nx = a * 0.9 * math.cos(ang + TAU / 12)
        nz = b * 0.9 * math.sin(ang + TAU / 12)
        beam(el, (x, vy + (x * x + z * z) / (4 * f) - 0.3, z), (nx, vy + (nx * nx + nz * nz) / (4 * f) - 0.3, nz), 0.26, M['lovell'])
    for s in (-1, 1):
        cyl_x(el, 1.2, min(s * 15.0, s * 16.4), max(s * 15.0, s * 16.4), 0.0, 0.0, M['dark-steel'], seg=16)
    # The focus: a white box on a ladder mast with two stays.
    fy = vy + f
    lattice_leg(el, (0, vy, -b * 0.75), (0, fy, 0), 0.9, 0.7, (1, 0, 0), 6, M['lovell'], 0.08, 0.04)
    beam(el, (-a * 0.6, vy + (a * a * 0.36) / (4 * f), 0), (0, fy, 0), 0.14, M['lovell'])
    beam(el, (a * 0.6, vy + (a * a * 0.36) / (4 * f), 0), (0, fy, 0), 0.14, M['lovell'])
    blk(el, 2.4, 2.0, 2.4, 0, fy, 0, M['lovell'])


# A hexagon's vertices, flat side up, for the segmented primaries.
def _hex_prism(par, cx, cz, r, y_of, mat, thick=0.12):
    verts = []
    for dy in (0.0, -thick):
        for k in range(6):
            a = TAU * k / 6
            x, z = cx + r * math.cos(a), cz + r * math.sin(a)
            verts.append(P(x, y_of(x, z) + dy, z))
    faces = [(0, 1, 2, 3, 4, 5), (11, 10, 9, 8, 7, 6)]
    faces += [(k, 6 + k, 6 + (k + 1) % 6, (k + 1) % 6) for k in range(6)]
    return _obj(nm('hex'), verts, faces, mat, par)


def _dome_sphere(par, name, r, cy, ymin, slit, mat):
    """A sphere cut at ymin with a slit of half-width `slit` from the front to past the
    top, as a grid of latitude and longitude."""
    n_lat, n_lon = 24, 72
    verts, faces = [], []
    for i in range(n_lat + 1):
        lat = -math.asin(min(1.0, (cy - ymin) / r)) + (math.pi / 2 + math.asin(min(1.0, (cy - ymin) / r))) * i / n_lat
        for k in range(n_lon):
            a = TAU * k / n_lon
            verts.append(P(r * math.cos(lat) * math.cos(a), cy + r * math.sin(lat), r * math.cos(lat) * math.sin(a)))
    for i in range(n_lat):
        for k in range(n_lon):
            k2 = (k + 1) % n_lon
            q = (i * n_lon + k, i * n_lon + k2, (i + 1) * n_lon + k2, (i + 1) * n_lon + k)
            xs = [verts[v] for v in q]
            mx = sum(v[0] for v in xs) / 4
            mz = -sum(v[1] for v in xs) / 4          # back to Godot z
            my = sum(v[2] for v in xs) / 4
            if abs(mx) < slit and mz > -r * 0.14 and my > cy - r * 0.4:
                continue
            faces.append(q)
    return smooth(_obj(name, verts, faces, mat, par), 50) or par


def keck(M):
    st = empty('stage_keck', (0, 0, 0))
    white, steel = M['dome-white'], M['dark-steel']
    R, cy = 15.5, 15.0
    # The fixed drum: pale panels, a dark service band, a catwalk with a rail.
    rev(st, [(0, 0.0), (R + 1.2, 0.0), (R + 1.2, 6.6), (0, 6.6)], M['lovell'], seg=72, sm=20)
    rev(st, [(R + 1.25, 2.2), (R + 1.25, 3.1)], M['seam'], seg=72)
    for k in range(36):
        a = TAU * k / 36
        beam(st, circle(0, 0.0, 0, R + 1.25, a), circle(0, 6.6, 0, R + 1.25, a), 0.14, M['lovell-grey'])
    rev(st, [(R + 1.2, 6.6), (R + 2.6, 6.6), (R + 2.6, 6.8), (R + 1.2, 6.8)], M['lovell-grey'], seg=72, sm=20)
    ring(st, R + 2.5, 7.9, 0.06, M['lovell-grey'], n=48)
    for k in range(48):
        a = TAU * k / 48
        beam(st, circle(0, 6.8, 0, R + 2.5, a), circle(0, 7.9, 0, R + 2.5, a), 0.05, M['lovell-grey'])
    for k in range(6):
        a = TAU * k / 6 + 0.3
        blk(st, 3.2, 3.0, 0.2, (R + 1.3) * math.cos(a), 0.0, (R + 1.3) * math.sin(a), M['lovell-grey'], yaw=-a + math.pi / 2)

    # THE DOME: a white sphere with its slit facing +z and two shutters sliding over it.
    dome = empty('door_keck_dome', (0, 0, 0), st)
    slit = 6.0
    _dome_sphere(dome, nm('sphere'), R, cy, 6.7, slit, white)
    # The raised frame round the slit, running up over the top: two rails.
    for s in (-1, 1):
        pts = []
        for i in range(25):
            phi = -0.42 + (math.pi / 2 + 0.42 + 0.3) * i / 24
            rr = R + 0.55
            zz = rr * math.cos(phi)
            yy = cy + rr * math.sin(phi)
            xx = s * (slit + 0.7)
            scale = math.sqrt(max(0.0, rr * rr - xx * xx)) / rr
            pts.append((xx, cy + (yy - cy) * scale, zz * scale))
        for p, q in zip(pts, pts[1:]):
            beam(dome, p, q, 0.9, white, d=0.7)
    # The fixed wind screen across the slit's foot: the shutters' axis runs through it.
    verts, faces = [], []
    rr = R + 0.1
    for i in range(7):
        phi = -0.42 + 0.87 * i / 6
        for j in range(7):
            xx = -(slit + 0.5) + 2 * (slit + 0.5) * j / 6
            rho = math.sqrt(max(0.0, rr * rr - xx * xx))
            verts.append(P(xx, cy + rho * math.sin(phi), rho * math.cos(phi)))
    for i in range(6):
        for j in range(6):
            a0 = i * 7 + j
            faces.append((a0, a0 + 1, a0 + 8, a0 + 7))
    smooth(_obj(nm('screen'), verts, faces, M['lovell-grey'], dome), 50)
    # The shutters: curved leaves pivoted on the sphere's horizontal axis.
    for s, name in ((-1, 'l'), (1, 'r')):
        leaf = empty(f'door_keck_shutter_{name}', P(0, cy, 0), dome)
        verts, faces = [], []
        rr = R + 0.25
        m, w = 16, 6
        for i in range(m + 1):
            phi = 0.45 + (math.pi / 2 - 0.45 + 0.3) * i / m
            for j in range(w + 1):
                xx = s * (0.02 + (slit + 0.5) * j / w)
                rho = math.sqrt(max(0.0, rr * rr - xx * xx))
                verts.append(P(xx, rho * math.sin(phi), rho * math.cos(phi)))
        for i in range(m):
            for j in range(w):
                a0 = i * (w + 1) + j
                faces.append((a0, a0 + 1, a0 + w + 2, a0 + w + 1))
        smooth(_obj(nm('leaf'), verts, faces, white, leaf), 50)

    # THE TELESCOPE: alt-az, seen through the slit. Floor, azimuth disc, yoke, mirror.
    rev(st, [(0, 6.7), (R + 1.0, 6.7), (R + 1.0, 7.0), (0, 7.0)], M['dark-steel'], seg=48, sm=20)
    az = empty('door_keck_az', P(0, 7.0, 0), st)
    rev(az, [(0, 0.0), (6.8, 0.0), (6.8, 1.0), (0, 1.0)], M['telescope'], seg=48, sm=20)
    el_y = 8.0
    for s in (-1, 1):
        verts = [P(s * 6.3, 1.0, -5.5), P(s * 6.3, 1.0, 5.5), P(s * 7.3, 1.0, 5.5), P(s * 7.3, 1.0, -5.5),
                 P(s * 6.3, el_y + 1.5, -1.6), P(s * 6.3, el_y + 1.5, 1.6), P(s * 7.3, el_y + 1.5, 1.6), P(s * 7.3, el_y + 1.5, -1.6)]
        faces = [(0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        _obj(nm('yoke'), verts, faces, M['telescope'], az)
    el = empty('door_keck_el', P(0, el_y, 0), az)
    cyl_x(el, 1.4, -6.3, 6.3, 0.0, 0.0, M['telescope'], seg=16)
    # 36 hexagons in three rings about a missing centre; a parabolic surface, f = 17.5 m.
    surf = lambda x, z: -3.0 + (x * x + z * z) / (4 * 17.5)
    size = 0.9
    dx, dz = size * 1.5, size * math.sqrt(3) * 0.5
    for q in range(-3, 4):
        for r in range(-3, 4):
            if q == 0 and r == 0 or abs(q + r) > 3:
                continue
            x, z = q * dx * 1.015, (2 * r + q) * dz * 1.015
            _hex_prism(el, x, z, size, surf, M['mirror'])
    blk(el, 11.0, 1.6, 11.0, 0, -5.0, 0, M['telescope'])
    # The Serrurier truss to the top ring and the secondary's spider.
    top = -3.0 + 15.5
    ring_r = 5.8
    ring(el, ring_r, top, 0.32, M['telescope'], n=24)
    for k in range(8):
        a = TAU * k / 8
        beam(el, circle(0, -3.5, 0, 5.4, a), circle(0, top, 0, ring_r, a + TAU / 8), 0.24, M['telescope'])
        beam(el, circle(0, -3.5, 0, 5.4, a + TAU / 8), circle(0, top, 0, ring_r, a), 0.24, M['telescope'])
    for a in (0.0, math.pi / 2, math.pi, -math.pi / 2):
        beam(el, circle(0, top, 0, ring_r, a), (0, top, 0), 0.1, M['telescope'])
    rev(el, [(0, top - 0.9), (0.75, top - 0.9), (0.75, top + 0.5), (0, top + 0.5)], M['mirror'], y=0, seg=16)
    # The tertiary tower up the axis.
    blk(el, 1.2, 4.0, 1.2, 0, -3.2, 0, M['telescope'])
    # A crane and the working platforms that fill the dome's slit from outside.
    blk(st, 2.0, 0.8, 8.0, 0, 16.5, -R + 3.5, M['dark-steel'])


def keck_hall(M):
    """The shared building between the domes, on the baseline along local x: 85 m long."""
    st = empty('stage_keck_hall', (0, 0, 0))
    blk(st, 58.0, 5.5, 16.0, 0, 0, 0, M['lovell'])
    blk(st, 58.6, 0.5, 16.6, 0, 5.5, 0, M['lovell-grey'])
    for z in (8.05, -8.05):
        windows(st, 0.0, z, 2.3, 14, 1, 3.9, 0, M['glass'], w=1.6, h=1.2)
    # The covered walkways out to each dome's drum.
    for s in (-1, 1):
        blk(st, 8.0, 3.2, 4.0, s * 31.5, 3.0, 0, M['lovell'])
        for x in (28.5, 34.5):
            blk(st, 0.4, 3.0, 0.4, s * x, 0.0, 2.0, M['dark-steel'])
            blk(st, 0.4, 3.0, 0.4, s * x, 0.0, -2.0, M['dark-steel'])


def subaru(M):
    """Subaru: a stepped silver cylinder, its upper block rotating (photographs; 8.2 m)."""
    st = empty('stage_subaru', (0, 0, 0))
    rev(st, [(0, 0), (20.0, 0), (20.0, 6.0), (0, 6.0)], M['lovell'], seg=48, sm=20)
    rev(st, [(0, 6.0), (15.0, 6.0), (15.0, 16.0), (0, 16.0)], M['alu'], seg=32, sm=20)
    for k in range(5):
        blk(st, 5.2, 27.0, 18.0, -12.0 + 6.0 * k, 16.0 - 9.0, 0.0, M['alu'])
    blk(st, 31.0, 1.0, 19.0, 0, 34.0 - 9.0 + 7.0, 0, M['dark-steel'])


def irtf(M):
    """NASA IRTF: a silver dome on a low white building (photographs; 3.0 m)."""
    st = empty('stage_irtf', (0, 0, 0))
    blk(st, 34.0, 5.0, 20.0, 0, 0, 0, M['lovell'])
    windows(st, 0.0, 10.05, 2.0, 6, 1, 5.0, 0, M['glass'], w=2.0, h=1.0)
    rev(st, [(0, 5.0), (8.8, 5.0), (8.8, 7.5), (0, 7.5)], M['dark-steel'], seg=32, sm=20)
    prof = [(8.6 * math.cos(i / 12 * math.pi / 2), 7.5 + 8.6 * math.sin(i / 12 * math.pi / 2)) for i in range(13)]
    rev(st, prof, M['chrome'], seg=48, sm=60)
    for s in (-1, 1):
        beam(st, (s * 2.4, 7.5, 8.2), (s * 2.4, 15.9, 0.0), 0.3, M['chrome'])


# THE VLT
UT_R, UT_H = 14.5, 28.5
UT_FACETS = 20


def _facet_wall(par, r, y0, y1, a0, a1, n, mat, mat_rib, name='fw'):
    """A faceted cylindrical wall from angle a0 to a1 (measured with +z at 0, toward +x),
    with a rib at each post."""
    verts, faces = [], []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        for y in (y0, y1):
            verts.append(P(r * math.sin(a), y, r * math.cos(a)))
    for i in range(n):
        v = i * 2
        faces.append((v, v + 2, v + 3, v + 1))
    ob = _obj(nm(name), verts, faces, mat, par)
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        rr = r + 0.15
        beam(par, (rr * math.sin(a), y0, rr * math.cos(a)), (rr * math.sin(a), y1, rr * math.cos(a)), 0.25, mat_rib)
    return ob


def _enclosure(M, st, name, r, h, slit_half, fixed_h):
    """The VLT family's enclosure: a fixed glazed drum on a blue ring, a faceted rotating
    dome, and two ridged roof modules that slide apart over the slit (+z)."""
    alu, grey = M['alu'], M['lovell-grey']
    # The fixed drum: a blue footing, posts round a recessed wall with its glazed
    # bays, a pale upper band.
    rev(st, [(0, 0), (r + 0.6, 0), (r + 0.6, 0.9), (0, 0.9)], M['blue'], seg=48, sm=20)
    rev(st, [(0, 0.9), (r - 1.2, 0.9), (r - 1.2, fixed_h * 0.42), (0, fixed_h * 0.42)], M['lovell-grey'], seg=UT_FACETS, sm=10)
    n_posts = 16
    for k in range(n_posts):
        a = TAU * k / n_posts
        beam(st, circle(0, 0.9, 0, r - 0.4, a), circle(0, fixed_h * 0.42, 0, r - 0.4, a), 0.5, M['dark-steel'])
        if k % 4 == 1:
            ob = blk(st, r * 0.42, fixed_h * 0.24, 0.2, (r - 1.15) * math.sin(a + TAU / 32), fixed_h * 0.12, (r - 1.15) * math.cos(a + TAU / 32), M['glass'])
            ob.rotation_euler = (0, 0, a + TAU / 32)
    _facet_wall(st, r, fixed_h * 0.42, fixed_h, 0.0, TAU, UT_FACETS, alu, grey)

    # The dome rotates about the telescope's azimuth axis.
    dome = empty(f'door_{name}_dome', P(0, fixed_h, 0), st)
    hd = h - fixed_h
    half = math.asin(min(0.95, slit_half / r))
    _facet_wall(dome, r, 0.0, hd * 0.86, half, TAU - half, UT_FACETS, alu, grey)
    # The back of the slit is dark, so the telescope reads against it.
    _facet_wall(dome, r - 0.6, 0.0, hd * 0.86, half, TAU - half, UT_FACETS, M['interior'], M['interior'], name='fi')
    rev(dome, [(0, 0.05), (r - 0.6, 0.05)], M['interior'], seg=UT_FACETS, sm=10)
    # Bands of louvres round the wall, two rows at every other facet.
    for k in range(UT_FACETS):
        a = half + (TAU - 2 * half) * (k + 0.5) / UT_FACETS
        if k % 2 == 0:
            for y in (hd * 0.26, hd * 0.58):
                ob = blk(dome, 3.2, 2.6, 0.3, (r + 0.14) * math.sin(a), y, (r + 0.14) * math.cos(a), M['glass'], yaw=-a + math.pi)
                ob.rotation_euler = (0, 0, a)
    # Roof shoulders on the back half and over each side of the slit.
    roof_y = hd * 0.86
    for s in (-1, 1):
        # The fixed roof each side of the moving modules.
        verts = [P(s * slit_half * 2.05, roof_y, -r * 0.85), P(s * r * 0.98, roof_y, -r * 0.2), P(s * r * 0.98, roof_y, r * 0.2), P(s * slit_half * 2.05, roof_y, r * 0.85),
                 P(s * slit_half * 2.05, roof_y + hd * 0.08, -r * 0.8), P(s * r * 0.86, roof_y + hd * 0.02, -r * 0.2), P(s * r * 0.86, roof_y + hd * 0.02, r * 0.2), P(s * slit_half * 2.05, roof_y + hd * 0.08, r * 0.8)]
        faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
        _obj(nm('shoulder'), verts, faces, alu, dome)
        # The sliding module: a ridged block whose hip carries louvres.
        door = empty(f'door_{name}_door_{"l" if s < 0 else "r"}', (0, 0, 0), dome)
        x0, x1 = (0.02, slit_half + 0.4) if s > 0 else (-slit_half - 0.4, -0.02)
        g = gable_prism(door, nm('door'), x0, x1, roof_y - 0.4, roof_y + hd * 0.1, roof_y + hd * 0.14, -r * 0.82, r + 0.6, alu)
        g.data.update()
        for k in range(6):
            z = -r * 0.7 + (2 * r * 0.7) * k / 5
            beam(door, ((x0 + x1) * 0.5, roof_y + hd * 0.14 + 0.05, z), (x0 if s > 0 else x1, roof_y + hd * 0.1 + 0.05, z), 0.15, grey)
    # The slit's front jambs, carried up to the roof.
    for s in (-1, 1):
        beam(dome, (s * slit_half, 0.0, r * math.cos(half)), (s * slit_half, roof_y, r * math.cos(half)), 0.6, grey)
    return dome


def ut(M):
    st = empty('stage_ut', (0, 0, 0))
    fixed = 9.5
    _enclosure(M, st, 'ut', UT_R, UT_H, 6.0, fixed)
    # THE TELESCOPE: fork mount, Nasmyth platforms each side, primary cell, top ring.
    az = empty('door_ut_az', P(0, fixed, 0), st)
    rev(az, [(0, 0), (9.5, 0), (9.5, 0.8), (0, 0.8)], M['telescope'], seg=48, sm=20)
    el_y = 7.2
    for s in (-1, 1):
        # Fork arm: a deep blue box, tapered, each carrying its Nasmyth platform.
        verts = [P(s * 5.2, 0.8, -6.5), P(s * 5.2, 0.8, 6.5), P(s * 6.6, 0.8, 6.5), P(s * 6.6, 0.8, -6.5),
                 P(s * 5.2, el_y + 1.3, -1.8), P(s * 5.2, el_y + 1.3, 1.8), P(s * 6.6, el_y + 1.3, 1.8), P(s * 6.6, el_y + 1.3, -1.8)]
        faces = [(0, 1, 2, 3), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
        _obj(nm('fork'), verts, faces, M['telescope'], az)
        blk(az, 3.4, 0.25, 8.0, s * 8.4, 4.8, 0, M['dark-steel'])
        for x, z in ((6.8, 3.9), (10.0, 3.9), (6.8, -3.9), (10.0, -3.9)):
            beam(az, (s * x, 0.8, z), (s * x, 4.8, z), 0.2, M['dark-steel'])
        blk(az, 2.4, 2.4, 2.4, s * 8.4, 5.05, 0, M['lovell'])
    el = empty('door_ut_el', P(0, el_y, 0), az)
    cyl_x(el, 1.2, -5.2, 5.2, 0.0, 0.0, M['telescope'], seg=16)
    # The 8.2 m meniscus in its cell, f = 14.4 m (radius of curvature 28.8 m).
    v = -2.4
    rm = 4.1
    prof = [(rm * i / 12, v + (rm * i / 12) ** 2 / (4 * 14.4)) for i in range(13)]
    rev(el, prof, M['mirror'], seg=48, sm=60)
    rev(el, [(0, v - 1.8), (4.6, v - 1.8), (4.6, v + 0.2), (0, v + 0.2)], M['telescope'], seg=32, sm=20)
    # The Serrurier truss to the secondary ring.
    top = v + 12.2
    ring(el, 4.4, top, 0.28, M['telescope-top'], n=24)
    for k in range(6):
        a = TAU * k / 6
        beam(el, circle(0, v, 0, 4.6, a), circle(0, top, 0, 4.4, a + TAU / 6), 0.22, M['telescope-top'])
        beam(el, circle(0, v, 0, 4.6, a + TAU / 6), circle(0, top, 0, 4.4, a), 0.22, M['telescope-top'])
    for a in (0.0, math.pi / 2, math.pi, -math.pi / 2):
        beam(el, circle(0, top, 0, 4.4, a), (0, top, 0), 0.08, M['telescope-top'])
    rev(el, [(0, top - 0.8), (0.65, top - 0.8), (0.65, top + 0.4), (0, top + 0.4)], M['telescope-top'], seg=16)


def small_enclosure(M, name, r, h):
    st = empty(f'stage_{name}', (0, 0, 0))
    _enclosure(M, st, name, r, h, r * 0.4, h * 0.34)
    # A telescope tube glimpsed through the slit.
    tube = empty(f'door_{name}_el', P(0, h * 0.42, 0), st)
    rev(tube, [(0, -r * 0.3), (r * 0.42, -r * 0.3), (r * 0.42, r * 0.5), (0, r * 0.5)], M['telescope'], seg=20, sm=20)
    return st


def at(M):
    """An Auxiliary Telescope on its transporter (photographs against the 1.8 m mirror)."""
    st = empty('stage_at', (0, 0, 0))
    white, grey = M['dome-white'], M['lovell-grey']
    W, D = 3.6, 3.6
    # Rail bogies and a yellow-black plinth line.
    blk(st, W + 0.3, 0.32, D + 0.3, 0, 0.1, 0, M['dark-steel'])
    blk(st, W + 0.32, 0.08, D + 0.32, 0, 0.42, 0, M['hazard'])
    # The transporter: panelled box with louvres, side columns and a numbered corner.
    blk(st, W, 2.45, D, 0, 0.5, 0, white)
    for s in (-1, 1):
        blk(st, 0.55, 2.0, 0.7, s * (W * 0.5 + 0.1), 1.0, D * 0.5 - 0.5, white)
        blk(st, 0.55, 2.0, 0.7, s * (W * 0.5 + 0.1), 1.0, -D * 0.5 + 0.5, white)
        for k in (-1, 0, 1):
            blk(st, 0.02, 1.55, 0.72, s * (W * 0.5 + 0.015), 0.95, k * 0.86, grey)
    blk(st, 0.55, 0.45, 0.04, 0.5, 2.05, D * 0.5 + 0.02, M['seam'])
    blk(st, 0.55, 0.45, 0.04, 0.5, 1.55, D * 0.5 + 0.02, M['seam'])
    # The pyramid up to the enclosure, a hatch plate on it.
    verts = [P(-W / 2, 2.95, -D / 2), P(W / 2, 2.95, -D / 2), P(W / 2, 2.95, D / 2), P(-W / 2, 2.95, D / 2),
             P(-0.6, 4.2, -0.6), P(0.6, 4.2, -0.6), P(0.6, 4.2, 0.6), P(-0.6, 4.2, 0.6)]
    faces = [(0, 1, 2, 3), (7, 6, 5, 4), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    _obj(nm('plinth'), verts, faces, white, st)
    # The dome: a sphere in two three-part shells that open like petals.
    R, cy = 2.35, 4.9
    prof = [(R * math.cos(-0.72 + (math.pi / 2 + 0.72) * i / 16), cy + R * math.sin(-0.72 + (math.pi / 2 + 0.72) * i / 16)) for i in range(17)]
    dome = empty('door_at_dome', (0, 0, 0), st)
    rev(dome, prof, white, seg=48, sm=60)
    # The seams: the equator and two meridian arcs.
    rev(dome, [(R + 0.015, cy - 0.04), (R + 0.015, cy + 0.04)], M['hazard-seam'], seg=48)
    for s in (-1, 1):
        pts = [(s * (R + 0.02) * math.cos(t) * 0.7, cy + (R + 0.02) * math.sin(t), (R + 0.02) * math.cos(t) * 0.71) for t in [i / 8 * math.pi / 2 for i in range(9)]]
        for p, q in zip(pts, pts[1:]):
            beam(dome, p, q, 0.04, M['seam'])
    # The ladder and rails on the top.
    for dx in (-0.2, 0.2):
        pts = [(dx, cy + R * math.sin(t) + 0.08, R * math.cos(t) + 0.08) for t in [0.15 + i / 8 * (math.pi / 2 - 0.15) for i in range(9)]]
        for p, q in zip(pts, pts[1:]):
            beam(dome, p, q, 0.035, white)
    # Service mast, as in the photographs, on one corner.
    beam(st, (-W * 0.5 - 0.2, 0.3, D * 0.5), (-W * 0.5 - 0.2, 3.2, D * 0.5), 0.09, grey)


# Site offsets on the Paranal platform from ESO's table (Paranal astroclimate site page):
# station → (seconds of latitude and longitude past 24°37′ S, 70°24′ W).
_STATIONS = {
    'A0': (40.59, 18.44), 'A1': (41.08, 18.26), 'B0': (40.50, 18.17), 'B1': (40.99, 17.99), 'B2': (41.24, 17.89),
    'B3': (41.48, 17.80), 'B4': (41.73, 17.71), 'B5': (41.97, 17.62), 'C0': (40.42, 17.90), 'C1': (40.91, 17.72),
    'C2': (41.15, 17.63), 'C3': (41.40, 17.53), 'D0': (40.25, 17.36), 'D1': (41.23, 16.99), 'D2': (41.72, 16.81),
    'E0': (40.08, 16.83), 'G0': (39.91, 16.29), 'G1': (41.87, 15.55), 'G2': (39.18, 16.57), 'H0': (39.58, 15.21),
    'I1': (40.72, 14.48), 'J1': (40.06, 14.13), 'J2': (40.79, 13.85), 'J3': (37.61, 15.05), 'J4': (37.12, 15.24),
    'J5': (36.39, 15.52), 'J6': (35.65, 15.79), 'K0': (39.24, 14.14), 'L0': (39.16, 13.87), 'M0': (39.07, 13.60),
}
_UT1 = (39.44, 18.27)


def platform_xz(st):
    """Local (x, z) of a station: x is west, z is north, the datum on UT1."""
    lat, lon = _STATIONS[st]
    n = (_UT1[0] - lat) * 30.72          # 1″ of latitude at 24.6° S, m
    e = (_UT1[1] - lon) * 28.17          # 1″ of longitude there, m
    return (-e, n)


def _strip(par, a, b, w, mat, y=0.14):
    pa, pb = Vector((a[0], a[1])), Vector((b[0], b[1]))
    d = (pb - pa)
    if d.length < 0.01:
        return
    n = Vector((-d.y, d.x)).normalized() * (w * 0.5)
    verts = [P(pa.x + n.x, y, pa.y + n.y), P(pb.x + n.x, y, pb.y + n.y), P(pb.x - n.x, y, pb.y - n.y), P(pa.x - n.x, y, pa.y - n.y),
             P(pa.x + n.x, 0.0, pa.y + n.y), P(pb.x + n.x, 0.0, pb.y + n.y), P(pb.x - n.x, 0.0, pb.y - n.y), P(pa.x - n.x, 0.0, pa.y - n.y)]
    faces = [(0, 1, 2, 3), (4, 7, 6, 5), (0, 4, 5, 1), (1, 5, 6, 2), (2, 6, 7, 3), (3, 7, 4, 0)]
    _obj(nm('strip'), verts, faces, mat, par)


def vlt_platform(M):
    """The Paranal platform's surfaces and buildings, datum on UT1, x west, z north."""
    st = empty('stage_vlt_platform', (0, 0, 0))
    # The AT rail grid: a concrete strip from each trunk station out to its numbered ones.
    white = M['pale-concrete']
    trunk = ['A0', 'B0', 'C0', 'D0', 'E0', 'G0', 'H0', 'K0', 'L0', 'M0']
    for a, b in zip(trunk, trunk[1:]):
        _strip(st, platform_xz(a), platform_xz(b), 9.0, white)
    for head, tail in (('A0', 'A1'), ('B0', 'B5'), ('C0', 'C3'), ('D0', 'D2'), ('G0', 'G1'), ('H0', 'I1'),
                       ('K0', 'J2'), ('H0', 'J6'), ('K0', 'J1')):
        _strip(st, platform_xz(head), platform_xz(tail), 4.0, white)
    # A dark rail pair down each strip.
    for a, b in zip(trunk, trunk[1:]):
        pa, pb = Vector(platform_xz(a)), Vector(platform_xz(b))
        off = Vector((-(pb - pa).y, (pb - pa).x)).normalized() * 1.6
        for s in (-1, 1):
            _strip(st, tuple(pa + off * s), tuple(pb + off * s), 0.18, M['dark-steel'], y=0.2)
    # The paved apron round each UT and the VLTI laboratory between them.
    for e, n, r in ((0.0, 0.0, 23.0), (24.8, 50.3, 23.0), (54.9, 86.0, 23.0), (113.2, 63.9, 23.0)):
        rev(st, [(0, 0.1), (r, 0.1)], white, x=-e, z=n, seg=48, sm=20)
    _strip(st, (0.0, 0.0), (-24.8, 50.3), 46.0, white, y=0.11)
    _strip(st, (-24.8, 50.3), (-54.9, 86.0), 46.0, white, y=0.11)
    _strip(st, (-54.9, 86.0), (-113.2, 63.9), 46.0, white, y=0.11)
    # The perimeter road round the levelled top.
    pts = [(-65.0 - 116.0 * math.sin(TAU * i / 64), 20.0 + 160.0 * math.cos(TAU * i / 64)) for i in range(65)]
    for a, b in zip(pts, pts[1:]):
        _strip(st, a, b, 9.0, M['asphalt'], y=0.08)
    # The VLTI laboratory: sunken, a pale flat roof with a blue-grey skylight strip.
    bx, bz = -72.0, 30.0
    blk(st, 46.0, 3.0, 13.0, bx, 0.0, bz, M['lovell'])
    blk(st, 15.0, 0.6, 6.0, bx + 8.0, 3.0, bz, M['lovell-grey'])
    # The control building by the platform's southern edge: two white wings and blue glass.
    cx, cz = -44.0, -112.0
    blk(st, 30.0, 8.0, 15.0, cx - 22.0, -4.0, cz, M['lovell'])
    blk(st, 13.0, 7.0, 15.0, cx - 1.0, -4.0, cz, M['blue-glass'])
    blk(st, 30.0, 8.0, 15.0, cx + 20.0, -4.0, cz, M['lovell'])
    blk(st, 74.0, 0.5, 16.0, cx, 4.0, cz, M['lovell-grey'])
    for sx in (-22.0, 20.0):
        windows(st, cx + sx, cz + 7.55, -1.0, 8, 2, 3.4, 3.2, M['glass'], w=2.0, h=1.5)
        windows(st, cx + sx, cz - 7.55, -1.0, 8, 2, 3.4, 3.2, M['glass'], w=2.0, h=1.5)


def build_observatories(M):
    extra = (
        ('lovell', 0xeeecE4, 0.72, 0.03), ('lovell-grey', 0x9aa1a3, 0.66, 0.1), ('seam', 0x8d9396, 0.8, 0.02),
        ('bowl-back', 0x3c4648, 0.85, 0.05), ('dark-steel', 0x3a4046, 0.7, 0.2), ('concrete', 0xb6b2a8, 0.92, 0.0),
        ('pale-concrete', 0xd8d4c8, 0.9, 0.0), ('rail', 0x5e5a56, 0.45, 0.4), ('dome-white', 0xf3f3ee, 0.42, 0.03),
        ('telescope', 0x25406e, 0.62, 0.12), ('telescope-top', 0x8896a4, 0.55, 0.2), ('mirror', 0xc8d0d8, 0.08, 0.7),
        ('interior', 0x14171b, 0.95, 0.0), ('hazard', 0xc9a227, 0.7, 0.0), ('hazard-seam', 0xbba48c, 0.8, 0.0),
        ('blue-glass', 0x1e3a78, 0.22, 0.25), ('chrome', 0xb8c0c8, 0.16, 0.65), ('alu', 0xc6cbce, 0.5, 0.2),
        ('asphalt', 0x47413c, 0.95, 0.0),
    )
    for name, color, rough, metal in extra:
        M[name] = material(name, srgb(color), rough, metal)
    M['blue'] = material('site-blue', srgb(0x2a55a8), 0.6, 0.05)
    lovell(M)
    mark2(M)
    keck(M)
    keck_hall(M)
    subaru(M)
    irtf(M)
    ut(M)
    at(M)
    vlt_platform(M)
    small_enclosure(M, 'vst', 7.0, 13.0)
    small_enclosure(M, 'vista', 10.0, 19.0)


build('observatories', build_observatories, 'assets/sites/observatories.glb')
