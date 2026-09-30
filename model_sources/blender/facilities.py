"""THE REST OF THE COMPLEX — the buildings a launch pad stands among.

One library file, assets/pads/facilities.glb, holding one `stage_fac_<name>`
node per facility, each built with its own grade at y = 0 and its own origin at
the middle of its footprint. sim/flight/launchsite.gd lays the site out (which
facility, where, turned which way — see `_site_plan` there) and instances these
by name; a fresh clone without the build falls back to the procedural blocks it
always had. So the NAMES ARE AN INTERFACE, the same way the pads' `stage_deck`
and `stage_tower` are.

Every one is drawn from a real facility, at its published size where there is
one, and nothing here is a survey — the point is the SCALE the eye reads a
rocket against, and the kinds of things that are really there:

  LC-39A / 39B (Apollo, Shuttle, now Falcon):
    · the LOX sphere, 900 000 US gal, ~21 m outside diameter, NW corner
    · the LH2 sphere, 850 000 US gal, NE corner, with its burn pond
    · the sound-suppression water tower, 88.9 m (290 ft), 300 000 US gal,
      about 300 m north-east of the pad, and the 2.1 m mains that feed the pad
    · the RP-1 farm: three horizontal ~325 m³ tanks inside a bund (Apollo)
    · hypergolic storage at the SW and SE corners (Shuttle)
  SLC-40 / 39A (SpaceX):
    · the horizontal integration facility the vehicle is built in lying down,
      and rolled out of on a transporter-erector; SLC-40's is 69 × 23 × 15 m,
      39A's is wide enough for three Falcon Heavy cores side by side
  Starbase:
    · the orbital tank farm: eight GSE tanks, LOX, CH4, LN2 and water, each a
      9 m stainless tank inside an insulating "cryoshell", in a row
    · the subcoolers that chill the propellant with LN2 on its way to the pad
    · the GSE bunker the lines run through, horizontal CH4 tanks, and the
      deluge's pressurised water tanks
  Everywhere: gas storage (He / N2 tube banks, an LN2 dewar, ambient
  vaporizers), an electrical substation, an operations building, a shop, a
  gatehouse, floodlight masts and the camera sites ringing the pad.

Coordinates are Godot's — x, UP, z, metres — converted once in P(). The
optimiser joins by material under each `stage_` node, so each facility is a
handful of draw calls however many beams it has.
"""
import math
import os
import sys
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lib import box, empty, finish, strut, revolve, ball, dish, smooth, material, _obj
from common import build, srgb

TAU = math.tau
_count = [0]


def nm(p='p'):
    _count[0] += 1
    return f'{p}_{_count[0]}'


def P(x, y, z):
    """Godot (x, up, z) to Blender (x, -z, up)."""
    return (x, -z, y)


# PRIMITIVES, in Godot coordinates
def blk(par, w, h, d, x, y, z, mat, bev=0.04, yaw=0.0):
    """A box STANDING on (x, y, z): w along x, h up, d along z."""
    ob = box(nm('b'), (w, d, h), P(x, y + h * 0.5, z), mat, parent=par)
    if yaw:
        ob.rotation_euler = (0, 0, yaw)
    if bev:
        finish(ob, min(bev, w * 0.15, h * 0.15, d * 0.15), 2)
    return ob


def beam(par, a, b, w, mat, bev=0.02):
    p, q = Vector(P(*a)), Vector(P(*b))
    d = q - p
    if d.length < 1e-3:
        return None
    ob = box(nm('beam'), (w, w, d.length), (p + q) * 0.5, mat, parent=par)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    if bev:
        finish(ob, min(bev, w * 0.14), 1)
    return ob


def pipe(par, a, b, r, mat, seg=10):
    ob = strut(nm('pipe'), P(*a), P(*b), r, mat, seg=seg, parent=par)
    if ob is not None:
        smooth(ob, 50)
    return ob


def polyline(par, pts, r, mat, seg=8):
    for a, b in zip(pts, pts[1:]):
        pipe(par, a, b, r, mat, seg)
    # elbows, so a bend is not a crack
    for p in pts[1:-1]:
        ob = ball(nm('elbow'), r, P(*p), mat, seg=seg, rings=max(4, seg // 2), parent=par)
        smooth(ob, 60)


def grp(par, x=0.0, y=0.0, z=0.0, yaw=0.0):
    g = empty(nm('g'), P(x, y, z), par)
    g.rotation_euler = (0, 0, yaw)
    return g


def lathe_up(par, profile, x, y, z, mat, seg=32, smooth_angle=40):
    """A body of revolution about the vertical through (x, z), its profile's
    heights measured from y."""
    ob = revolve(nm('rev'), profile, mat, seg=seg, parent=par)
    ob.location = P(x, y, z)
    smooth(ob, smooth_angle)
    return ob


def drum(par, r, h, x, y, z, mat, seg=32, top='flat', cap=0.0):
    """A vertical drum standing on (x, y, z), with a flat, domed or coned top."""
    prof = [(0.0, 0.0), (r, 0.0), (r, h)]
    if top == 'dome':
        for i in range(1, 7):
            a = i / 6 * math.pi / 2
            prof.append((r * math.cos(a), h + cap * math.sin(a)))
    elif top == 'cone':
        prof += [(r * 0.08, h + cap), (0.0, h + cap)]
    else:
        prof.append((0.0, h))
    return lathe_up(par, prof, x, y, z, mat, seg)


def vessel_profile(r, L, head=0.5):
    """A pressure vessel lying along its own axis, centred: a barrel with 2:1
    elliptical heads (depth r·head), the standard for storage tanks."""
    hb = r * head
    pts = [(0.0, -L / 2)]
    for i in range(1, 8):
        a = i / 8 * math.pi / 2
        pts.append((r * math.sin(a), -L / 2 + hb * (1 - math.cos(a))))
    for i in range(0, 8):
        a = i / 8 * math.pi / 2
        pts.append((r * math.cos(a), L / 2 - hb + hb * math.sin(a)))
    pts.append((0.0, L / 2))
    return pts


def htank(par, r, L, x, y, z, mat, yaw=0.0, seg=32, saddles=2, saddle_mat=None):
    """A horizontal tank centred at (x, y, z), its axis along x turned by yaw,
    on concrete saddles."""
    g = grp(par, x, 0.0, z, yaw)
    ob = revolve(nm('htank'), vessel_profile(r, L), mat, seg=seg, parent=g)
    ob.location = P(0, y, 0)
    ob.rotation_euler = (0, math.pi / 2, 0)          # Blender Z (tank axis) to X
    smooth(ob, 40)
    if saddle_mat is not None and saddles:
        span = L - 2 * r * 0.5
        for k in range(saddles):
            sx = -span * 0.35 + span * 0.7 * (k / max(1, saddles - 1)) if saddles > 1 else 0.0
            blk(g, 0.9, y - r * 0.55, r * 1.6, sx, 0.0, 0, saddle_mat, 0.06)
            blk(g, 0.5, r * 0.5, r * 1.3, sx, y - r * 0.8, 0, saddle_mat, 0.04)
    return g


def rail(par, pts, mat, h=1.1, post=2.0, r=0.035):
    """A guardrail along a polyline: posts, top rail and knee rail."""
    for a, b in zip(pts, pts[1:]):
        A, B = Vector(a), Vector(b)
        L = (B - A).length
        n = max(1, int(L / post))
        for k in range(n + 1):
            p = A.lerp(B, k / n)
            pipe(par, tuple(p), (p.x, p.y + h, p.z), r, mat, 5)
        for hh in (h, h * 0.5):
            pipe(par, (A.x, A.y + hh, A.z), (B.x, B.y + hh, B.z), r, mat, 5)


def ring_rail(par, cx, y, cz, R, mat, n=24, h=1.1):
    pts = [(cx + R * math.cos(TAU * i / n), y, cz + R * math.sin(TAU * i / n)) for i in range(n + 1)]
    for a, b in zip(pts, pts[1:]):
        pipe(par, a, (a[0], a[1] + h, a[2]), 0.035, mat, 5)
        pipe(par, (a[0], a[1] + h, a[2]), (b[0], b[1] + h, b[2]), 0.035, mat, 5)
        pipe(par, (a[0], a[1] + h * 0.5, a[2]), (b[0], b[1] + h * 0.5, b[2]), 0.03, mat, 5)


def stair(par, a, b, width, M, rails=True):
    """A straight flight from a to b (both on the centreline of the treads)."""
    A, B = Vector(a), Vector(b)
    d = B - A
    run = math.hypot(d.x, d.z)
    rise = d.y
    n = max(3, int(abs(rise) / 0.2))
    side = Vector((-d.z, 0.0, d.x)).normalized() * (width * 0.5) if run > 1e-3 else Vector((width * 0.5, 0, 0))
    for s in (-1, 1):
        o = side * s
        beam(par, tuple(A + o), tuple(B + o), 0.16, M['steel'], 0)
    yaw = math.atan2(-d.z, d.x) if run > 1e-3 else 0.0
    for k in range(1, n):
        p = A.lerp(B, k / n)
        blk(par, max(0.3, run / n + 0.05), 0.05, width, p.x, p.y, p.z, M['darkcon'], 0, yaw=yaw)
    if rails:
        for s in (-1, 1):
            o = side * s * 1.05
            pa, pb = A + o, B + o
            pipe(par, (pa.x, pa.y + 1.0, pa.z), (pb.x, pb.y + 1.0, pb.z), 0.03, M['safety-yellow'], 5)
            for t in (0.0, 0.5, 1.0):
                q = pa.lerp(pb, t)
                pipe(par, tuple(q), (q.x, q.y + 1.0, q.z), 0.03, M['safety-yellow'], 5)


def ladder(par, x, y0, y1, z, M, face=(1, 0), cage=True):
    """A caged ladder up a face whose outward normal is `face` (in x, z)."""
    fx, fz = face
    tx, tz = -fz, fx
    for s in (-0.22, 0.22):
        pipe(par, (x + tx * s, y0, z + tz * s), (x + tx * s, y1, z + tz * s), 0.03, M['steel'], 4)
    y = y0 + 0.3
    while y < y1:
        pipe(par, (x - tx * 0.22, y, z - tz * 0.22), (x + tx * 0.22, y, z + tz * 0.22), 0.018, M['steel'], 4)
        y += 0.6
    if cage and y1 - y0 > 4:
        yc = y0 + 2.5
        while yc < y1:
            pts = []
            for i in range(7):
                a = math.pi * i / 6
                ox, oz = math.cos(a) * 0.38, math.sin(a) * 0.38 + 0.38
                pts.append((x + tx * ox + fx * oz, yc, z + tz * ox + fz * oz))
            for p0, p1 in zip(pts, pts[1:]):
                pipe(par, p0, p1, 0.02, M['safety-yellow'], 4)
            yc += 1.2
        for i in (0, 3, 6):
            a = math.pi * i / 6
            ox, oz = math.cos(a) * 0.38, math.sin(a) * 0.38 + 0.38
            pipe(par, (x + tx * ox + fx * oz, y0 + 2.5, z + tz * ox + fz * oz),
                 (x + tx * ox + fx * oz, y1, z + tz * ox + fz * oz), 0.02, M['safety-yellow'], 4)


def vaporizer_bank(par, x, z, n, M, h=7.0, pitch=1.6, yaw=0.0):
    """Ambient-air vaporizers: tall finned aluminium columns in a row, the
    white frosted forest beside every cryogen tank."""
    g = grp(par, x, 0, z, yaw)
    blk(g, n * pitch + 1.0, 0.3, 2.6, 0, 0, 0, M['concrete'], 0.05)
    for k in range(n):
        cx = -(n - 1) * pitch * 0.5 + k * pitch
        blk(g, 0.22, h, 0.22, cx, 0.3, 0, M['alu'], 0.02)
        for a in range(4):
            yaw_f = a * math.pi / 4
            blk(g, 1.25, h - 0.6, 0.06, cx, 0.6, 0, M['alu'], 0.0, yaw=yaw_f)
    pipe(g, (-(n - 1) * pitch * 0.5, h + 0.5, 0), ((n - 1) * pitch * 0.5, h + 0.5, 0), 0.12, M['steel'])
    pipe(g, (-(n - 1) * pitch * 0.5, 0.6, 0.8), ((n - 1) * pitch * 0.5, 0.6, 0.8), 0.12, M['steel'])
    return g


def shed(par, w, h, d, x, z, M, yaw=0.0, wall='cladding', roof='roof', doors=1, door_mat='cladding-blue',
         pitch=0.08):
    """A steel-framed metal building: walls with the column lines standing
    proud of the cladding (which is what makes one read as a building and not
    as a box), a girt band, a low-pitched roof with its eaves and ridge, and
    roll-up doors on the +z face."""
    g = grp(par, x, 0, z, yaw)
    blk(g, w + 2.0, 0.2, d + 2.0, 0, 0, 0, M['concrete'], 0.05)
    blk(g, w, h, d, 0, 0.2, 0, M[wall], 0.06)
    # pilasters on the column lines
    nx = max(2, round(w / 6.0))
    for k in range(nx + 1):
        px = -w / 2 + w * k / nx
        for s in (-1, 1):
            blk(g, 0.35, h, 0.18, px, 0.2, s * (d / 2 + 0.06), M[wall], 0.03)
    nz = max(2, round(d / 6.0))
    for k in range(nz + 1):
        pz = -d / 2 + d * k / nz
        for s in (-1, 1):
            blk(g, 0.18, h, 0.35, s * (w / 2 + 0.06), 0.2, pz, M[wall], 0.03)
    # girt band and base flashing
    for s in (-1, 1):
        blk(g, w + 0.3, 0.25, 0.1, 0, 0.2 + h * 0.55, s * (d / 2 + 0.1), M['grey'], 0)
        blk(g, 0.1, 0.25, d + 0.3, s * (w / 2 + 0.1), 0.2 + h * 0.55, 0, M['grey'], 0)
        blk(g, w + 0.3, 0.6, 0.12, 0, 0.2, s * (d / 2 + 0.1), M['grey'], 0)
    # low-pitched gable roof, ridge along x
    rise = d * 0.5 * pitch
    ang = math.atan2(rise, d * 0.5)
    for s in (-1, 1):
        L = math.hypot(d * 0.5, rise) + 0.6
        ob = box(nm('roof'), (w + 0.8, L, 0.25), P(0, 0.2 + h + rise * 0.5 + 0.1, s * d * 0.25), M[roof], parent=g)
        ob.rotation_euler = (s * ang, 0, 0)
        finish(ob, 0.04, 1)
    blk(g, w + 0.8, 0.35, 0.8, 0, 0.2 + h + rise - 0.05, 0, M['grey'], 0.05)
    for s in (-1, 1):   # gable ends
        tri = _obj(nm('gable'), [P(s * (w / 2 + 0.05), 0.2 + h, -d / 2), P(s * (w / 2 + 0.05), 0.2 + h, d / 2),
                                 P(s * (w / 2 + 0.05), 0.2 + h + rise, 0)], [(0, 1, 2)], M[wall], g)
    # doors on +z
    for k in range(doors):
        dx = -w / 2 + w * (k + 0.5) / doors
        dw = min(5.0, w / doors - 2.0)
        dh = min(h - 1.5, 5.5)
        blk(g, dw, dh, 0.14, dx, 0.2, d / 2 + 0.07, M[door_mat], 0.02)
        for j in range(1, int(dh / 0.6)):
            blk(g, dw - 0.1, 0.04, 0.05, dx, 0.2 + j * 0.6, d / 2 + 0.16, M['grey'], 0)
        blk(g, dw + 0.5, 0.5, 0.5, dx, 0.2 + dh, d / 2 + 0.25, M['grey'], 0.05)   # coil box
    # personnel doors, one per long side
    for s in (-1, 1):
        blk(g, 1.0, 2.2, 0.1, w * 0.35 * s, 0.2, -(d / 2 + 0.06), M['cladding-blue'], 0.01)
        blk(g, 1.4, 0.12, 1.0, w * 0.35 * s, 2.6, -(d / 2 + 0.5), M['grey'], 0.01)
    # roof ventilators
    for k in range(max(1, nx // 2)):
        vx = -w / 2 + w * (k + 0.5) / max(1, nx // 2)
        drum(g, 0.45, 0.9, vx, 0.2 + h + rise - 0.1, 0, M['alu'], 12, 'cone', 0.35)
    return g


def glazed_block(par, w, h_floor, floors, d, x, z, M, yaw=0.0):
    """A multi-storey office: white spandrels, a continuous glazed band per
    floor with mullions, a parapet, and a stair core that stands above it."""
    g = grp(par, x, 0, z, yaw)
    H = h_floor * floors + 1.2
    blk(g, w + 2, 0.35, d + 2, 0, 0, 0, M['concrete'], 0.05)
    blk(g, w, H, d, 0, 0.35, 0, M['cladding'], 0.08)
    blk(g, w + 0.4, 0.9, d + 0.4, 0, 0.35 + H, 0, M['cladding'], 0.06)   # parapet
    blk(g, w - 0.6, 0.12, d - 0.6, 0, 0.35 + H + 0.2, 0, M['roof'], 0)
    for f in range(floors):
        y = 0.35 + 1.1 + h_floor * f
        for s in (-1, 1):
            blk(g, w - 2.4, 1.8, 0.1, 0, y, s * (d / 2 + 0.04), M['glass'], 0)
            n = int((w - 2.4) / 3.0)
            for k in range(n + 1):
                mx = -(w - 2.4) / 2 + (w - 2.4) * k / n
                blk(g, 0.14, 1.8, 0.14, mx, y, s * (d / 2 + 0.08), M['grey'], 0)
            blk(g, w - 2.2, 0.12, 0.35, 0, y + 1.8, s * (d / 2 + 0.2), M['grey'], 0)   # sunshade fin
        for s in (-1, 1):
            blk(g, 0.1, 1.8, d - 2.4, s * (w / 2 + 0.04), y, 0, M['glass'], 0)
    # stair core, standing above the roof, in the accent colour
    blk(g, 5.0, H + 3.2, 6.0, w / 2 - 4.0, 0.35, -d / 2 + 2.4, M['cladding-blue'], 0.08)
    blk(g, 5.4, 0.3, 6.4, w / 2 - 4.0, 0.35 + H + 3.2, -d / 2 + 2.4, M['grey'], 0.05)
    # entrance canopy on the +z face
    blk(g, 12.0, 0.45, 5.0, 0, 4.2, d / 2 + 2.5, M['cladding'], 0.06)
    for s in (-1, 1):
        drum(g, 0.22, 3.85, s * 5.2, 0.35, d / 2 + 4.4, M['grey'], 12)
    blk(g, 6.0, 2.8, 0.1, 0, 0.35, d / 2 + 0.06, M['glass'], 0)
    # rooftop plant
    for k in range(4):
        ux = -w * 0.35 + k * w * 0.2
        blk(g, 4.2, 1.9, 2.8, ux, 0.35 + H, 1.5, M['grey'], 0.06)
        for f in (-1, 1):
            drum(g, 0.7, 0.2, ux + f * 1.0, 0.35 + H + 1.9, 1.5, M['darkcon'], 16)
    return g, H + 0.35


def lattice_mast(par, x, z, h, w, M, mat='steel'):
    """A square lattice mast: four legs, horizontals and alternating diagonals."""
    g = grp(par, x, 0, z)
    hw = w / 2
    for sx in (-1, 1):
        for sz in (-1, 1):
            pipe(g, (sx * hw, 0, sz * hw), (sx * hw, h, sz * hw), max(0.05, w * 0.05), M[mat], 6)
    bays = max(3, int(h / (w * 1.4)))
    for i in range(bays + 1):
        y = h * i / bays
        corners = [(-hw, -hw), (hw, -hw), (hw, hw), (-hw, hw), (-hw, -hw)]
        for (ax, az), (bx, bz) in zip(corners, corners[1:]):
            pipe(g, (ax, y, az), (bx, y, bz), max(0.03, w * 0.03), M[mat], 5)
        if i < bays:
            y2 = h * (i + 1) / bays
            for j, ((ax, az), (bx, bz)) in enumerate(zip(corners, corners[1:])):
                if (i + j) % 2:
                    pipe(g, (ax, y, az), (bx, y2, bz), max(0.025, w * 0.025), M[mat], 4)
                else:
                    pipe(g, (bx, y, bz), (ax, y2, az), max(0.025, w * 0.025), M[mat], 4)
    return g


def fence(par, pts, M, h=2.4, post=3.0):
    """Chain-link as it reads from further than a few metres: posts, a top
    rail and a barbed-wire outrigger. The mesh itself is invisible at range."""
    for a, b in zip(pts, pts[1:]):
        A, B = Vector(a), Vector(b)
        L = (B - A).length
        n = max(1, int(L / post))
        for k in range(n + 1):
            p = A.lerp(B, k / n)
            pipe(par, tuple(p), (p.x, h, p.z), 0.04, M['steel'], 5)
        pipe(par, (A.x, h, A.z), (B.x, h, B.z), 0.03, M['steel'], 5)
        pipe(par, (A.x, 0.15, A.z), (B.x, 0.15, B.z), 0.02, M['steel'], 4)
        pipe(par, (A.x, h + 0.45, A.z), (B.x, h + 0.45, B.z), 0.012, M['steel'], 4)


# LC-39: CRYOGEN SPHERES
def cryo_sphere(M, key, R, legs, vaps):
    """A Horton sphere on legs: columns tangent to the equator, rod X-bracing
    between them, a girder at the equator, a stair that climbs round the
    outside and up the shoulder to a platform with the vents and relief
    valves. It is a vacuum bottle — an inner vessel with perlite round it —
    and what shows is the outer one."""
    root = empty(f'stage_fac_{key}', (0, 0, 0))
    c = R + 3.8                                   # centre height
    blk(root, 2 * R + 14, 0.35, 2 * R + 14, 0, 0, 0, M['darkcon'], 0.05)
    ob = ball(nm('sphere'), R, P(0, c, 0), M['tank-white'], seg=56, rings=28, parent=root)
    smooth(ob, 40)
    lathe_up(root, [(R * 1.004, -0.35), (R * 1.004, 0.35)], 0, c, 0, M['grey'], 56)   # equator band
    for i in range(legs):
        a = TAU * (i + 0.5) / legs
        x, z = math.cos(a) * R, math.sin(a) * R
        blk(root, 1.8, 0.9, 1.8, x, 0.35, z, M['concrete'], 0.08)
        pipe(root, (x, 1.25, z), (x, c + 0.6, z), 0.42, M['tank-white'], 14)
        # the rods: an X between each pair of columns
        b = TAU * (i + 1.5) / legs
        x2, z2 = math.cos(b) * R, math.sin(b) * R
        pipe(root, (x, 1.6, z), (x2, c - 1.2, z2), 0.06, M['steel'], 5)
        pipe(root, (x2, 1.6, z2), (x, c - 1.2, z), 0.06, M['steel'], 5)
    # the stair: round the outside of the columns to the equator ...
    Rs = R + 1.8
    lower, upper = [], []
    n1 = 28
    for i in range(n1 + 1):
        a = -0.4 + 2.4 * i / n1
        lower.append((math.cos(a) * Rs, 0.35 + (c - 0.35) * i / n1, math.sin(a) * Rs))
    # ... then up the shoulder, following the shell
    n2 = 14
    for i in range(n2 + 1):
        t = i / n2
        y = c + R * 0.93 * t
        rr = math.sqrt(max(R * R - (y - c) ** 2, 0.0)) + 1.3 + 0.5 * (1 - t)
        a = 2.0 + 0.8 * t
        upper.append((math.cos(a) * rr, y, math.sin(a) * rr))
    path = lower + upper[1:]
    for p0, p1 in zip(path, path[1:]):
        A, B = Vector(p0), Vector(p1)
        d = B - A
        yaw = math.atan2(-d.z, d.x)
        blk(root, math.hypot(d.x, d.z) + 0.1, 0.06, 1.0, (A.x + B.x) / 2, (A.y + B.y) / 2, (A.z + B.z) / 2,
            M['darkcon'], 0, yaw=yaw)
    outer = []
    for p in path:
        v = Vector((p[0], 0, p[2]))
        o = v.normalized() * 0.55
        outer.append((p[0] + o.x, p[1], p[2] + o.z))
    polyline(root, outer, 0.07, M['steel'], 6)
    polyline(root, [(q[0], q[1] + 1.05, q[2]) for q in outer], 0.035, M['safety-yellow'], 5)
    for q in outer[::3]:
        pipe(root, q, (q[0], q[1] + 1.05, q[2]), 0.03, M['safety-yellow'], 4)
    # top platform, vents and valves
    top = c + R
    lathe_up(root, [(0.0, 0.0), (3.4, 0.0), (3.4, 0.18), (0.0, 0.18)], 0, top - 0.25, 0, M['darkcon'], 24)
    ring_rail(root, 0, top - 0.07, 0, 3.3, M['safety-yellow'], 16)
    for k, (vx, vz) in enumerate([(0.9, 0.4), (-0.8, 0.9), (-0.3, -1.1)]):
        pipe(root, (vx, top - 0.1, vz), (vx, top + 2.6 + k * 0.6, vz), 0.14, M['steel'], 8)
        blk(root, 0.5, 0.5, 0.5, vx, top + 0.6, vz, M['safety-yellow'], 0.04)
    # bottom outlet: the transfer line leaves toward the pad (local +x) on
    # sleepers, as a vacuum-jacketed pipe
    polyline(root, [(0, c - R, 0), (0, 1.3, 0), (R + 7, 1.3, 0), (R + 32, 1.3, 0)], 0.32, M['steel'], 12)
    for k in range(6):
        sx = R + 4 + k * 5.0
        blk(root, 0.4, 0.9, 1.4, sx, 0.35, 0, M['concrete'], 0.04)
    # the pump and valve house, the vaporizers, the fill-station hardstand
    shed(root, 12, 5.0, 7, R + 9, R + 2, M, doors=1)
    vaporizer_bank(root, 0, -(R + 6.5), vaps, M, yaw=0.0)
    blk(root, 16, 0.3, 9, -(R + 2), 0, R + 3, M['concrete'], 0.04)      # tanker fill bay
    pipe(root, (-(R + 6), 0.9, R + 3), (-(R + 1.5), 0.9, R + 1.5), 0.12, M['steel'])
    return root


# LC-39: THE WATER TOWER
def water_tower(M):
    """88.9 m to the top of the vent, and 300 000 US gallons (1 135 m³) in a
    14 m tank on eight battered legs: released through 2.1 m mains, starting
    before ignition, it empties in about forty seconds."""
    root = empty('stage_fac_water_tower', (0, 0, 0))
    Rt = 7.0
    y_bot, y_rim, y_top = 74.0, 78.0, 84.0
    prof = []
    for i in range(0, 8):
        a = i / 8 * math.pi / 2
        prof.append((Rt * math.sin(a), y_bot + (y_rim - y_bot) * (1 - math.cos(a))))
    prof += [(Rt, y_rim), (Rt, y_top), (Rt * 0.1, y_top + 3.3), (0.0, y_top + 3.3)]
    lathe_up(root, prof, 0, 0, 0, M['tank-white'], 48)
    lathe_up(root, [(Rt * 1.005, y_top - 1.2), (Rt * 1.005, y_top - 0.3)], 0, 0, 0, M['red'], 48)
    drum(root, 0.9, 1.6, 0, y_top + 3.2, 0, M['grey'], 16, 'cone', 0.5)
    # balcony round the rim
    lathe_up(root, [(Rt, 0), (Rt + 1.3, 0), (Rt + 1.3, 0.15), (Rt, 0.15)], 0, y_rim - 0.15, 0, M['darkcon'], 48)
    ring_rail(root, 0, y_rim, 0, Rt + 1.25, M['safety-yellow'], 32)
    # eight legs, battered from 13 m at grade to the tank's rim
    legs = 8
    Rb = 13.0
    tops, bots = [], []
    for i in range(legs):
        a = TAU * i / legs
        bots.append((math.cos(a) * Rb, 1.0, math.sin(a) * Rb))
        tops.append((math.cos(a) * (Rt - 0.2), y_rim, math.sin(a) * (Rt - 0.2)))
        blk(root, 2.4, 1.0, 2.4, bots[-1][0], 0, bots[-1][2], M['concrete'], 0.1)
        pipe(root, bots[-1], tops[-1], 0.55, M['tank-white'], 14)
    levels = [0.0, 0.22, 0.44, 0.66, 0.88]
    for li, t in enumerate(levels):
        ring = [Vector(b).lerp(Vector(tp), t) for b, tp in zip(bots, tops)]
        for i in range(legs):
            p, q = ring[i], ring[(i + 1) % legs]
            if t > 0:
                pipe(root, tuple(p), tuple(q), 0.28, M['tank-white'], 10)
            if li + 1 < len(levels):
                t2 = levels[li + 1]
                p2 = Vector(bots[i]).lerp(Vector(tops[i]), t2)
                q2 = Vector(bots[(i + 1) % legs]).lerp(Vector(tops[(i + 1) % legs]), t2)
                pipe(root, tuple(p), tuple(q2), 0.06, M['steel'], 5)
                pipe(root, tuple(q), tuple(p2), 0.06, M['steel'], 5)
    # the central riser, and the mains leaving for the pad (local +x)
    drum(root, 1.25, y_bot, 0, 0, 0, M['tank-white'], 24)
    blk(root, 6.0, 1.4, 6.0, 0, 0, 0, M['concrete'], 0.1)
    polyline(root, [(0, 1.4, 1.4), (6, 1.3, 1.4), (60, 1.3, 1.4)], 1.05, M['tank-white'], 20)
    polyline(root, [(0, 1.4, -1.4), (6, 1.3, -1.4), (60, 1.3, -1.4)], 1.05, M['tank-white'], 20)
    for k in range(9):
        blk(root, 1.0, 0.5, 6.0, 8 + k * 6.5, 0, 0, M['concrete'], 0.05)
    # ladder up one leg-line to the balcony, and the warning beacon
    ladder(root, 1.3, 1.4, y_bot, 0, M, face=(1, 0), cage=True)
    ball(nm('beacon'), 0.35, P(0, y_top + 5.2, 0), M['red'], 12, 8, root)
    # the pump house at its foot
    shed(root, 14, 5.5, 8, -26, 18, M, doors=1)
    return root


# LC-39: RP-1, HYPERGOLS
def rp1_farm(M):
    """Three horizontal kerosene tanks (Apollo's were 86 000 US gal, 325 m³
    each), inside a bund that holds more than one of them, with the pump house
    and the manifold outside it."""
    root = empty('stage_fac_rp1_farm', (0, 0, 0))
    W, D = 36.0, 30.0
    blk(root, W, 0.25, D, 0, 0, 0, M['concrete'], 0.05)
    for s in (-1, 1):
        blk(root, W + 0.6, 1.6, 0.4, 0, 0, s * D / 2, M['concrete'], 0.06)
        blk(root, 0.4, 1.6, D, s * W / 2, 0, 0, M['concrete'], 0.06)
    for k in range(3):
        htank(root, 2.3, 20.0, 0, 3.5, -8.5 + k * 8.5, M['tank-white'], saddles=3, saddle_mat=M['concrete'])
        lathe_up(root, [(0, 0), (0.35, 0), (0.35, 1.2), (0, 1.2)], 3.0, 5.7, -8.5 + k * 8.5, M['steel'], 10)
        pipe(root, (10.4, 3.5, -8.5 + k * 8.5), (W / 2 + 3, 3.5, -8.5 + k * 8.5), 0.18, M['steel'])
    pipe(root, (W / 2 + 3, 3.5, -10), (W / 2 + 3, 3.5, 10), 0.22, M['steel'])
    pipe(root, (W / 2 + 3, 3.5, 10), (W / 2 + 3, 1.0, 10), 0.22, M['steel'])
    # catwalk along the tank tops, with its stair over the bund
    blk(root, 1.2, 0.12, 20.0, 5.0, 6.05, 0, M['darkcon'], 0)
    for z in (-9.5, 0.0, 9.5):
        pipe(root, (5.0, 0.25, z), (5.0, 6.0, z), 0.12, M['steel'])
    rail(root, [(5.6, 6.17, -10), (5.6, 6.17, 10)], M['safety-yellow'])
    stair(root, (5.0, 0.3, -D / 2 - 7.0), (5.0, 6.1, -10.2), 1.0, M)
    shed(root, 10, 4.5, 7, W / 2 + 10, 8, M, doors=1)
    return root


def hypergol(M):
    """Shuttle hypergolic storage: the fuel (monomethyl hydrazine) at the SW
    corner of the pad and the oxidizer (N2O4) at the SE, each a pair of small
    tanks under a sun canopy in a curbed basin, with the vapour scrubber."""
    root = empty('stage_fac_hypergol', (0, 0, 0))
    blk(root, 26, 0.25, 18, 0, 0, 0, M['concrete'], 0.04)
    for s in (-1, 1):
        blk(root, 22.5, 0.6, 0.3, 0, 0.25, s * 7.5, M['concrete'], 0.04)
        blk(root, 0.3, 0.6, 15, s * 11.1, 0.25, 0, M['concrete'], 0.04)
    for k in (-1, 1):
        htank(root, 1.6, 9.0, 0, 2.4, k * 3.2, M['tank-white'], saddles=2, saddle_mat=M['concrete'])
        lathe_up(root, [(1.62, -0.2), (1.62, 0.2)], 0, 2.4, k * 3.2, M['safety-yellow'], 24)
    # the canopy: portal frames and a roof
    for x in (-9.0, -3.0, 3.0, 9.0):
        for s in (-1, 1):
            blk(root, 0.35, 6.5, 0.35, x, 0.25, s * 6.5, M['steel'], 0.03)
        beam(root, (x, 6.9, -6.8), (x, 6.9, 6.8), 0.45, M['steel'])
    blk(root, 20.5, 0.18, 14.5, 0, 7.12, 0, M['roof'], 0.03)
    # scrubber column and stack
    drum(root, 1.1, 7.5, 14.5, 0.25, -4.0, M['tank-white'], 20, 'dome', 0.6)
    pipe(root, (14.5, 8.3, -4.0), (14.5, 12.5, -4.0), 0.25, M['steel'])
    pipe(root, (9.0, 2.4, -3.2), (14.5, 2.4, -4.0), 0.12, M['steel'])
    shed(root, 6, 3.2, 4, 15.0, 4.0, M, doors=1)
    fence(root, [(-14, 0, -10), (18, 0, -10), (18, 0, 10), (-14, 0, 10), (-14, 0, -10)], M)
    return root


# COMMON: GAS, POWER, PEOPLE, LIGHT, CAMERAS
def gas_farm(M):
    """High-pressure gas: helium and nitrogen at 400 bar in banks of long
    forged bottles, an LN2 dewar that the nitrogen boils off, and its
    ambient vaporizers."""
    root = empty('stage_fac_gas_farm', (0, 0, 0))
    blk(root, 50, 0.25, 30, 0, 0, 0, M['concrete'], 0.05)
    for rack, cz in enumerate((-7.0, 3.0)):
        g = grp(root, -6.0, 0.25, cz)
        for row in range(4):
            for col in range(5):
                htank(g, 0.3, 12.0, 0, 0.9 + row * 0.72, -1.8 + col * 0.72, M['grey'], seg=12, saddles=0)
        for x in (-5.5, 0.0, 5.5):
            blk(g, 0.3, 3.9, 4.2, x, 0, -0.35, M['steel'], 0.02)
        blk(g, 1.2, 3.2, 4.2, 6.9, 0, -0.35, M['safety-yellow'], 0.04)   # manifold cabinet
        pipe(g, (7.5, 2.5, -0.35), (11.0, 2.5, -0.35), 0.08, M['steel'])
    # sunshade over the bottle banks
    for x in (-12.5, -6.0, 0.5):
        for z in (-10.0, 6.0):
            blk(root, 0.3, 5.3, 0.3, x, 0.25, z, M['steel'], 0.02)
    blk(root, 14.5, 0.15, 17.0, -6.0, 5.55, -2.0, M['roof'], 0.02)
    # the LN2 dewar and its vaporizers
    dew = 3.2
    for i in range(4):
        a = TAU * (i + 0.5) / 4
        pipe(root, (14 + math.cos(a) * 1.9, 0.25, -6 + math.sin(a) * 1.9),
             (14 + math.cos(a) * 1.6, 3.2, -6 + math.sin(a) * 1.6), 0.2, M['steel'])
    drum(root, 1.8, 14.0, 14.0, 2.6, -6.0, M['tank-white'], 28, 'dome', 1.0)
    lathe_up(root, [(0, 0), (1.8, 0), (1.8, 0.01)], 14.0, 2.6, -6.0, M['tank-white'], 28)
    ladder(root, 14.0, 0.25, 16.6, -6.0 + 1.85, M, face=(0, 1))
    vaporizer_bank(root, 14.0, 6.5, 6, M, h=6.0, yaw=0.0)
    pipe(root, (14.0, 1.2, -4.2), (14.0, 1.2, 5.2), 0.1, M['steel'])
    fence(root, [(-25, 0, -15), (25, 0, -15), (25, 0, 15), (-25, 0, 15), (-25, 0, -15)], M)
    return root


def insulator(par, x, y, z, h, M, r=0.28):
    """A porcelain bushing: a stack of sheds, which is what makes a substation
    read as electrical rather than as plumbing."""
    prof = [(0.0, 0.0)]
    n = int(h / 0.22)
    for k in range(n):
        y0 = k * h / n
        prof += [(r * 0.55, y0), (r, y0 + h / n * 0.3), (r * 0.55, y0 + h / n * 0.7)]
    prof += [(r * 0.55, h), (0.0, h)]
    lathe_up(par, prof, x, y, z, M['insulator'], 12, 60)


def substation(M):
    """Gravel yard, three transformers with radiator banks, conservators and
    bushings, a steel bus gantry with insulator strings and conductors, the
    switchgear house, and the fence round all of it."""
    root = empty('stage_fac_substation', (0, 0, 0))
    blk(root, 44, 0.14, 32, 0, 0, 0, M['gravel'], 0.02)
    for k in range(3):
        x = -12 + k * 12
        blk(root, 5.2, 0.5, 4.0, x, 0.14, 4.0, M['concrete'], 0.05)
        blk(root, 3.8, 3.2, 2.6, x, 0.64, 4.0, M['grey'], 0.06)
        for s in (-1, 1):
            for f in range(6):
                blk(root, 0.06, 2.6, 1.2, x - 1.5 + f * 0.6, 0.9, 4.0 + s * 1.95, M['grey'], 0)
            blk(root, 3.4, 0.12, 1.3, x, 3.5, 4.0 + s * 1.95, M['grey'], 0)
        htank(root, 0.45, 2.4, x, 4.6, 5.0, M['grey'], seg=14, saddles=0)
        for b in range(3):
            insulator(root, x - 1.1 + b * 1.1, 3.84, 3.4, 1.9, M)
        # conductors up to the gantry
        for b in range(3):
            pipe(root, (x - 1.1 + b * 1.1, 5.74, 3.4), (x - 1.1 + b * 1.1, 9.0, -7.5), 0.025, M['oxidized-copper'], 4)
    # the gantry
    for k in range(4):
        x = -18 + k * 12
        lattice_mast(root, x, -8.0, 11.0, 0.9, M)
    for y in (9.2, 11.0):
        beam(root, (-18.4, y, -8.0), (18.4, y, -8.0), 0.55, M['steel'])
    for k in range(9):
        x = -16 + k * 4
        insulator(root, x, 7.9, -8.0, 1.3, M, 0.18)
    for b in range(3):
        pipe(root, (-18, 7.9, -8.0 + (b - 1) * 0.0 + 0.0), (18, 7.9, -8.0), 0.03, M['oxidized-copper'], 4)
    # switchgear house
    shed(root, 14, 3.6, 5, 12, -2.0, M, doors=1, yaw=math.pi)
    fence(root, [(-22, 0, -16), (22, 0, -16), (22, 0, 16), (-22, 0, 16), (-22, 0, -16)], M, h=2.6)
    return root


def ops_building(M):
    """The operations building: three storeys, a glazed band a floor, the
    stair core in the site's accent colour, an entrance canopy, rooftop plant,
    and the comms mast with its dishes. Flagpoles out front."""
    root = empty('stage_fac_ops_building', (0, 0, 0))
    g, H = glazed_block(root, 64, 3.9, 3, 20, 0, 0, M)
    lattice_mast(root, -24, -4, H + 14, 1.2, M)
    for k, (dy, yaw) in enumerate([(H + 6, 0.6), (H + 10, -1.1)]):
        dg = grp(root, -24 + 0.9, dy, -4, yaw)
        ob = dish(nm('dish'), 1.4, M['tank-white'], parent=dg)
        ob.rotation_euler = (0, math.pi / 2 - 0.3, 0)
        smooth(ob, 60)
    for k in range(3):
        pipe(root, (-6 + k * 6, 0, 22), (-6 + k * 6, 12, 22), 0.07, M['alu'], 8)
    blk(root, 30, 0.12, 8, 0, 0, 15.5, M['concrete'], 0.02)
    return root


def warehouse(M):
    """A shop or converter-compressor building: a plain steel-frame shed
    with roll-up doors, as a launch complex has half a dozen of."""
    root = empty('stage_fac_warehouse', (0, 0, 0))
    shed(root, 40, 10, 24, 0, 0, M, doors=3)
    # a lean-to along the back
    blk(root, 24, 4.0, 6, -6, 0.2, -15, M['cladding'], 0.05)
    blk(root, 25, 0.2, 7, -6, 4.2, -15, M['roof'], 0.02)
    for k in range(3):
        blk(root, 2.4, 2.0, 1.6, 10 + k * 3.2, 0.2, -13.5, M['grey'], 0.05)  # compressors
    return root


def guard_house(M):
    """The gate: a booth between two lanes under a canopy, and the booms."""
    root = empty('stage_fac_guard_house', (0, 0, 0))
    blk(root, 18, 0.2, 12, 0, 0, 0, M['concrete'], 0.03)
    blk(root, 2.6, 0.25, 11, 0, 0.2, 0, M['concrete'], 0.04)            # island
    blk(root, 2.2, 3.0, 4.0, 0, 0.45, 0, M['cladding'], 0.05)
    for s in (-1, 1):
        blk(root, 0.08, 1.3, 3.4, s * 1.12, 1.6, 0, M['glass'], 0)
    blk(root, 2.0, 1.3, 0.08, 0, 1.6, 2.02, M['glass'], 0)
    for sx in (-1, 1):
        for sz in (-1, 1):
            drum(root, 0.2, 5.3, sx * 7.0, 0.2, sz * 4.5, M['grey'], 10)
    blk(root, 16, 0.6, 11, 0, 5.5, 0, M['cladding'], 0.06)
    blk(root, 16.2, 0.2, 11.2, 0, 6.1, 0, M['cladding-blue'], 0.02)
    for s in (-1, 1):
        blk(root, 0.5, 1.1, 0.5, s * 1.6, 0.45, s * 3.5, M['safety-yellow'], 0.04)
        g = grp(root, s * 1.6, 1.2, s * 3.5)
        for k in range(6):
            blk(g, 1.0, 0.12, 0.12, s * (0.6 + k * 1.0), 0, 0, M['red'] if k % 2 else M['tank-white'], 0)
    for x in (-8.5, -3.2, 3.2, 8.5):
        for z in (-5.5, 5.5):
            drum(root, 0.15, 1.0, x, 0.2, z, M['safety-yellow'], 8)
    return root


def floodlight(M):
    """A tapered floodlight mast with a lamp head of a dozen fittings and a
    service platform, the tall landmark at every pad after dark."""
    root = empty('stage_fac_floodlight', (0, 0, 0))
    blk(root, 2.4, 0.6, 2.4, 0, 0, 0, M['concrete'], 0.08)
    lathe_up(root, [(0.0, 0.0), (0.55, 0.0), (0.28, 32.0), (0.0, 32.0)], 0, 0.6, 0, M['steel'], 16)
    lathe_up(root, [(0.0, 0.0), (2.2, 0.0), (2.2, 0.15), (0.0, 0.15)], 0, 30.8, 0, M['darkcon'], 16)
    ring_rail(root, 0, 30.95, 0, 2.1, M['safety-yellow'], 12)
    blk(root, 5.6, 0.25, 0.3, 0, 32.4, 0.4, M['steel'], 0.02)
    blk(root, 5.6, 0.25, 0.3, 0, 34.6, 0.4, M['steel'], 0.02)
    for r in range(3):
        for c in range(4):
            g = grp(root, -2.1 + c * 1.4, 32.6 + r * 0.8, 0.7)
            ob = blk(g, 1.05, 0.62, 0.35, 0, 0, 0, M['grey'], 0.03)
            blk(g, 0.9, 0.5, 0.05, 0, 0.06, 0.19, M['lamp'], 0)
    ladder(root, 0, 0.6, 30.8, -0.5, M, face=(0, -1))
    return root


def camera_site(M):
    """A launch camera site: a concrete pad, a steel enclosure on a post with
    a sunshield, a junction box, and a blast shield on the pad side (+x)."""
    root = empty('stage_fac_camera_site', (0, 0, 0))
    blk(root, 3.2, 0.25, 3.2, 0, 0, 0, M['concrete'], 0.04)
    pipe(root, (0, 0.25, 0), (0, 1.5, 0), 0.08, M['steel'], 8)
    blk(root, 0.6, 0.6, 1.1, 0, 1.5, 0, M['tank-white'], 0.04, yaw=0.0)
    blk(root, 0.8, 0.05, 1.3, 0, 2.15, 0, M['tank-white'], 0.01)
    lathe_up(root, [(0.0, 0.0), (0.12, 0.0), (0.12, 0.08), (0.0, 0.08)], 0.56, 1.8, 0, M['glass'], 10)
    blk(root, 0.5, 0.7, 0.3, -0.9, 0.25, 0.9, M['grey'], 0.03)
    blk(root, 0.25, 1.4, 2.6, 1.4, 0.25, 0, M['concrete'], 0.04)
    return root


def burn_pond(M):
    """Liquid hydrogen boil-off is not vented, it is BURNED: piped under a
    shallow pond through bubbler headers, and lit off on the surface. With the
    flare stack for a big dump, guyed three ways."""
    root = empty('stage_fac_burn_pond', (0, 0, 0))
    S = 34.0
    for s in (-1, 1):
        blk(root, S + 1.2, 1.0, 0.6, 0, 0, s * S / 2, M['concrete'], 0.05)
        blk(root, 0.6, 1.0, S, s * S / 2, 0, 0, M['concrete'], 0.05)
    ob = _obj(nm('water'), [P(-S / 2, 0.55, -S / 2), P(S / 2, 0.55, -S / 2), P(S / 2, 0.55, S / 2), P(-S / 2, 0.55, S / 2)],
              [(0, 1, 2, 3)], M['pond'], root)
    for k in range(5):
        z = -12 + k * 6
        pipe(root, (-13, 0.5, z), (13, 0.5, z), 0.1, M['steel'], 6)
    pipe(root, (-S / 2 - 6, 0.6, 0), (-13, 0.5, 0), 0.25, M['steel'])
    pipe(root, (-13, 0.5, -12), (-13, 0.5, 12), 0.18, M['steel'])
    fx = S / 2 + 10
    blk(root, 3, 1.0, 3, fx, 0, 0, M['concrete'], 0.08)
    lathe_up(root, [(0.0, 0.0), (0.55, 0.0), (0.42, 26.0), (0.0, 26.0)], fx, 1.0, 0, M['steel'], 14)
    drum(root, 0.8, 1.4, fx, 27.0, 0, M['grey'], 14, 'cone', 0.6)
    for i in range(3):
        a = TAU * i / 3 + 0.5
        gx, gz = fx + math.cos(a) * 18, math.sin(a) * 18
        blk(root, 1.2, 0.6, 1.2, gx, 0, gz, M['concrete'], 0.05)
        pipe(root, (gx, 0.6, gz), (fx, 20.0, 0), 0.03, M['steel'], 4)
    return root


# SPACEX: THE HANGAR
def hif(M):
    """The horizontal integration facility. The vehicle is assembled lying on
    its side, then carried out through the end door on the transporter-
    erector's rails and stood up on the pad; so the door is on the end that
    faces the pad (local +z), and it is as wide as three Falcon Heavy cores
    side by side. Portal-frame shed, the column lines proud of the siding,
    ridge ventilator, and a two-storey office strip down one side."""
    root = empty('stage_fac_hif', (0, 0, 0))
    W, L, H = 52.0, 100.0, 21.0
    rise = 4.5
    blk(root, W + 30, 0.3, L + 12, 0, 0, 0, M['concrete'], 0.05)
    blk(root, W, H, L, 0, 0.3, 0, M['cladding'], 0.1)
    # column lines, both long faces
    n = 16
    for k in range(n + 1):
        z = -L / 2 + L * k / n
        for s in (-1, 1):
            blk(root, 0.25, H, 0.6, s * (W / 2 + 0.1), 0.3, z, M['cladding'], 0.04)
    for s in (-1, 1):
        for y in (H * 0.35, H * 0.7):
            blk(root, 0.14, 0.3, L + 0.4, s * (W / 2 + 0.2), 0.3 + y, 0, M['grey'], 0)
        blk(root, 0.3, 1.2, L + 0.6, s * (W / 2 + 0.12), 0.3, 0, M['black'], 0.02)   # dado
        blk(root, 0.5, 0.6, L + 1.2, s * (W / 2 + 0.3), 0.3 + H - 0.1, 0, M['black'], 0.03)   # gutter
        for k in range(0, n + 1, 4):
            z = -L / 2 + L * k / n + 1.0
            pipe(root, (s * (W / 2 + 0.45), 0.3, z), (s * (W / 2 + 0.45), 0.3 + H, z), 0.1, M['black'], 6)
    # the roof: two slabs and the ridge ventilator
    ang = math.atan2(rise, W / 2)
    for s in (-1, 1):
        Ls = math.hypot(W / 2, rise) + 0.8
        ob = box(nm('roof'), (Ls, L + 1.2, 0.35), P(s * W / 4, 0.3 + H + rise / 2 + 0.15, 0), M['roof'], parent=root)
        ob.rotation_euler = (0, s * ang, 0)
        finish(ob, 0.05, 1)
    blk(root, 3.0, 1.4, L * 0.8, 0, 0.3 + H + rise - 0.2, 0, M['grey'], 0.06)
    blk(root, 3.6, 0.2, L * 0.8 + 0.4, 0, 0.3 + H + rise + 1.2, 0, M['roof'], 0.03)
    for s in (-1, 1):   # gable ends
        _obj(nm('gable'), [P(-W / 2, 0.3 + H, s * (L / 2 + 0.02)), P(W / 2, 0.3 + H, s * (L / 2 + 0.02)),
                           P(0, 0.3 + H + rise, s * (L / 2 + 0.02))], [(0, 1, 2)], M['cladding'], root)
    # the end door: a vertical-lift fabric door in six leaves, its head box
    DW, DH = 44.0, 18.5
    z0 = L / 2 + 0.05
    blk(root, DW, DH, 0.2, 0, 0.3, z0, M['grey'], 0.02)
    for k in range(1, 6):
        blk(root, 0.35, DH, 0.3, -DW / 2 + DW * k / 6, 0.3, z0 + 0.1, M['black'], 0)
    y = 0.3 + 1.6
    while y < DH:
        blk(root, DW - 0.4, 0.1, 0.12, 0, y, z0 + 0.12, M['black'], 0)
        y += 1.6
    blk(root, DW + 3, 2.4, 1.6, 0, 0.3 + DH, z0 + 0.7, M['black'], 0.06)
    for s in (-1, 1):
        blk(root, 1.6, DH + 2.4, 1.2, s * (DW / 2 + 0.8), 0.3, z0 + 0.5, M['cladding'], 0.05)
    # the back door (the far end) is smaller: payload and stage deliveries
    blk(root, 14, 12, 0.2, 0, 0.3, -L / 2 - 0.05, M['grey'], 0.02)
    y = 1.9
    while y < 12:
        blk(root, 13.6, 0.08, 0.12, 0, y, -L / 2 - 0.15, M['black'], 0)
        y += 1.4
    # the office strip down the -x side
    g, _ = glazed_block(root, 60, 3.8, 2, 10, -(W / 2 + 5.2), -12, M, yaw=-math.pi / 2)
    # transporter-erector rails from inside the door out across the apron
    for rx in (-9.0, -6.0, 6.0, 9.0):
        blk(root, 0.25, 0.14, 50, rx, 0.3, L / 2 + 5, M['steel'], 0.02)
    blk(root, 26, 0.02, 60, 0, 0.3, L / 2 + 5, M['darkcon'], 0)
    # personnel doors and a few windows on the +x face
    for k in range(4):
        z = -L / 2 + 10 + k * 26
        blk(root, 0.1, 2.3, 1.2, W / 2 + 0.06, 0.3, z, M['black'], 0.01)
        blk(root, 0.1, 1.2, 6.0, W / 2 + 0.06, 3.5, z + 4.5, M['glass'], 0)
    # rooftop plant and a line of intake louvres
    for k in range(4):
        blk(root, 5.0, 2.2, 3.4, 10.0, 0.3 + H + rise * 0.35, -30 + k * 20, M['grey'], 0.05)
    return root


# STARBASE
def tank_farm(M):
    """The orbital tank farm. Eight GSE tanks in a row — three LOX, two CH4,
    two LN2 and the deluge water — each a 9 m stainless tank built the way the
    ships are, inside an insulating cryoshell with perlite between. What shows
    is the shell: stainless, seams every ring, a shallow dome, the vents and
    relief stacks on top, and a catwalk from roof to roof."""
    root = empty('stage_fac_tank_farm', (0, 0, 0))
    R = 6.0
    pitch = 14.6
    heights = [34.0, 34.0, 34.0, 30.0, 30.0, 28.0, 28.0, 24.0]
    n = len(heights)
    x0 = -(n - 1) * pitch / 2
    blk(root, n * pitch + 10, 0.35, 20, 0, 0, 0, M['concrete'], 0.05)
    for k, h in enumerate(heights):
        x = x0 + k * pitch
        drum(root, R + 0.6, 1.2, x, 0.35, 0, M['concrete'], 32)
        drum(root, R, h, x, 1.55, 0, M['stainless'], 40, 'dome', 1.6)
        yy = 1.55 + 1.83
        while yy < 1.55 + h - 0.5:
            lathe_up(root, [(R * 1.003, yy), (R * 1.003, yy + 0.08)], x, 0, 0, M['weld'], 40, 10)
            yy += 1.83
        top = 1.55 + h + 1.6
        for v, (vx, vz) in enumerate([(1.4, 0.6), (-1.2, -1.0)]):
            pipe(root, (x + vx, top - 0.3, vz), (x + vx, top + 3.0 + v, vz), 0.22, M['steel'], 8)
        blk(root, 4.0, 0.15, 2.4, x, top - 0.2, 0, M['darkcon'], 0)
        rail(root, [(x - 2, top - 0.05, -1.2), (x + 2, top - 0.05, -1.2)], M['safety-yellow'])
        rail(root, [(x - 2, top - 0.05, 1.2), (x + 2, top - 0.05, 1.2)], M['safety-yellow'])
        # the bottom line out to the pipe rack
        polyline(root, [(x, 2.0, R), (x, 2.0, R + 2.5), (x, 5.0, R + 2.5), (x, 5.0, R + 4.0)], 0.28, M['stainless'], 10)
    # catwalk bridges between neighbouring roofs
    for k in range(n - 1):
        xa = x0 + k * pitch + 2.0
        xb = x0 + (k + 1) * pitch - 2.0
        ya = 1.55 + heights[k] + 1.4
        yb = 1.55 + heights[k + 1] + 1.4
        beam(root, (xa, ya, -0.5), (xb, yb, -0.5), 0.2, M['steel'], 0)
        beam(root, (xa, ya, 0.5), (xb, yb, 0.5), 0.2, M['steel'], 0)
        rail(root, [(xa, ya, -0.6), (xb, yb, -0.6)], M['safety-yellow'])
        rail(root, [(xa, ya, 0.6), (xb, yb, 0.6)], M['safety-yellow'])
    # stair tower at the east end
    sx = x0 + (n - 1) * pitch + R + 5.0
    st = lattice_mast(root, sx, 0.0, 36.5, 4.0, M)
    for f in range(9):
        y0 = 0.35 + f * 4.0
        a = (sx - 1.3, y0, -1.2 if f % 2 == 0 else 1.2)
        b = (sx + 1.3, y0 + 4.0, -1.2 if f % 2 == 0 else 1.2)
        if f % 2:
            a, b = (a[0] + 2.6, a[1], a[2]), (b[0] - 2.6, b[1], b[2])
        stair(root, a, b, 0.9, M, rails=False)
        blk(root, 4.0, 0.1, 4.0, sx, y0 + 4.0, 0, M['darkcon'], 0)
    beam(root, (sx - 2.0, 36.9, 0), (x0 + (n - 1) * pitch + 2.0, 1.55 + heights[-1] + 1.4, 0), 0.25, M['steel'], 0)
    # the pipe rack along the front (+z), toward the subcoolers
    rz = R + 4.0
    for k in range(n * 2 + 1):
        x = x0 - 4 + (n * pitch) * k / (n * 2)
        for s in (-1.2, 1.2):
            pipe(root, (x, 0.35, rz + s), (x, 6.2, rz + s), 0.14, M['steel'], 6)
        beam(root, (x, 6.2, rz - 1.4), (x, 6.2, rz + 1.4), 0.25, M['steel'], 0)
    for j, r in enumerate((0.34, 0.34, 0.3, 0.3, 0.22)):
        z = rz - 1.0 + j * 0.5
        pipe(root, (x0 - 4, 6.2 + r + 0.13, z), (x0 - 4 + n * pitch, 6.2 + r + 0.13, z), r, M['stainless'], 12)
    return root


def subcooler(M):
    """The subcoolers: LN2 in open-frame steel structures chilling the
    propellant below its boiling point on the way to the pad, so the tanks
    hold more of it. Vertical vessels, shell-and-tube exchangers lying across
    the frame, vent stacks, and three floors of grating."""
    root = empty('stage_fac_subcooler', (0, 0, 0))
    W, D, H = 26.0, 14.0, 18.0
    blk(root, W + 6, 0.35, D + 6, 0, 0, 0, M['concrete'], 0.05)
    nx, nz = 4, 2
    for i in range(nx + 1):
        for j in range(nz + 1):
            x = -W / 2 + W * i / nx
            z = -D / 2 + D * j / nz
            blk(root, 0.45, H, 0.45, x, 0.35, z, M['steel'], 0.03)
    for y in (6.0, 12.0, H):
        for j in range(nz + 1):
            z = -D / 2 + D * j / nz
            beam(root, (-W / 2, y, z), (W / 2, y, z), 0.5, M['steel'])
        for i in range(nx + 1):
            x = -W / 2 + W * i / nx
            beam(root, (x, y, -D / 2), (x, y, D / 2), 0.45, M['steel'])
        if y < H:
            blk(root, W, 0.08, D, 0, y + 0.25, 0, M['darkcon'], 0)
            rail(root, [(-W / 2, y + 0.33, -D / 2), (W / 2, y + 0.33, -D / 2), (W / 2, y + 0.33, D / 2),
                        (-W / 2, y + 0.33, D / 2), (-W / 2, y + 0.33, -D / 2)], M['safety-yellow'], post=3.0)
    for i in range(nx):
        x0 = -W / 2 + W * i / nx
        x1 = -W / 2 + W * (i + 1) / nx
        beam(root, (x0, 0.4, -D / 2), (x1, 6.0, -D / 2), 0.25, M['steel'])
        beam(root, (x1, 6.0, -D / 2), (x0, 12.0, -D / 2), 0.25, M['steel'])
    for k in range(4):
        drum(root, 1.2, 15.5, -W / 2 + 3.2 + k * 6.5, 0.35, -2.5, M['tank-white'], 24, 'dome', 0.7)
    for k, y in enumerate((7.8, 13.8)):
        htank(root, 0.8, 11.0, 2.0, y, 3.5, M['stainless'], seg=20, saddles=0)
        htank(root, 0.8, 11.0, -8.0 if k else 8.5, y, 3.5, M['stainless'], seg=20, saddles=0)
    for s in (-1, 1):
        pipe(root, (s * (W / 2 + 1.5), 0.35, D / 2 + 1.5), (s * (W / 2 + 1.5), 27.0, D / 2 + 1.5), 0.45, M['stainless'], 12)
    for j in range(4):
        z = -5 + j * 3.2
        polyline(root, [(-W / 2 - 3, 2.5, z), (-W / 2 + 2, 2.5, z), (-W / 2 + 2, 6.8 + j, z), (W / 2 - 2, 6.8 + j, z)],
                 0.24, M['stainless'], 10)
    stair(root, (W / 2 + 1.2, 0.35, -D / 2 + 2), (W / 2 + 1.2, 6.2, D / 2 - 3), 1.0, M)
    return root


def horizontal_tanks(M):
    """Starbase's horizontal CH4 storage beside the farm: two long tanks on
    saddles with a walkway along their crowns."""
    root = empty('stage_fac_horizontal_tanks', (0, 0, 0))
    blk(root, 44, 0.3, 22, 0, 0, 0, M['concrete'], 0.05)
    for k, z in enumerate((-5.0, 5.0)):
        htank(root, 2.8, 36.0, 0, 4.2, z, M['tank-white'], saddles=4, saddle_mat=M['concrete'])
    blk(root, 32, 0.1, 1.2, 0, 7.3, 0, M['darkcon'], 0)
    for x in (-15, -5, 5, 15):
        pipe(root, (x, 0.3, 0), (x, 7.3, 0), 0.12, M['steel'])
    rail(root, [(-16, 7.4, 0.6), (16, 7.4, 0.6)], M['safety-yellow'])
    rail(root, [(-16, 7.4, -0.6), (16, 7.4, -0.6)], M['safety-yellow'])
    stair(root, (19.5, 0.3, 0), (16.2, 7.35, 0), 1.0, M)
    for z in (-5.0, 5.0):
        polyline(root, [(-18.8, 4.2, z), (-21.0, 4.2, z), (-21.0, 1.2, z), (-21.0, 1.2, 10.5)], 0.25, M['steel'])
    return root


def deluge_tanks(M):
    """The deluge: a water-cooled steel plate under the mount, fed from
    pressurised tanks — tall vertical vessels with nitrogen above the water,
    and the manifold that sends it to the pad (local +x)."""
    root = empty('stage_fac_deluge_tanks', (0, 0, 0))
    blk(root, 32, 0.35, 24, 0, 0, 0, M['concrete'], 0.05)
    for i, (x, z) in enumerate([(-8, -6), (0, -6), (8, -6), (-8, 6), (0, 6), (8, 6)]):
        drum(root, 3.0, 18.0, x, 0.35, z, M['stainless'], 32, 'dome', 1.4)
        yy = 2.2
        while yy < 18:
            lathe_up(root, [(3.009, yy), (3.009, yy + 0.08)], x, 0.35, z, M['weld'], 32, 10)
            yy += 1.83
        polyline(root, [(x, 1.2, z + (3.0 if z < 0 else -3.0)), (x, 1.2, 0), (13, 1.2, 0)], 0.4, M['stainless'], 12)
    polyline(root, [(13, 1.2, 0), (30, 1.2, 0)], 0.9, M['stainless'], 16)
    for x in (-8, 0, 8):
        beam(root, (x, 18.9, -6), (x, 18.9, 6), 0.25, M['steel'], 0)
    blk(root, 20, 0.1, 1.2, 0, 19.3, 0, M['darkcon'], 0)
    rail(root, [(-10, 19.4, 0.6), (10, 19.4, 0.6)], M['safety-yellow'])
    ladder(root, 11.2, 0.35, 19.3, -6, M, face=(1, 0))
    return root


def gse_bunker(M):
    """The GSE bunker the propellant lines pass through between the farm and
    the mount: a squat reinforced-concrete box, its sides banked, its pipes
    going in one wall and out the other."""
    root = empty('stage_fac_gse_bunker', (0, 0, 0))
    W, D, H = 30.0, 16.0, 5.0
    blk(root, W, H, D, 0, 0, 0, M['concrete'], 0.15)
    blk(root, W + 0.6, 0.6, D + 0.6, 0, H, 0, M['concrete'], 0.1)
    for s in (-1, 1):   # banked ends
        ob = _obj(nm('berm'), [P(s * W / 2, 0, -D / 2), P(s * W / 2, 0, D / 2), P(s * (W / 2 + 8), 0, D / 2),
                               P(s * (W / 2 + 8), 0, -D / 2), P(s * W / 2, H, -D / 2), P(s * W / 2, H, D / 2)],
                  [(0, 1, 2, 3) if s < 0 else (3, 2, 1, 0), (3, 2, 5, 4) if s < 0 else (4, 5, 2, 3),
                   (0, 3, 4), (1, 5, 2)], M['gravel'], root)
    for j in range(5):
        z = -4 + j * 2
        pipe(root, (-8 + j * 3, 1.6, -D / 2 - 18), (-8 + j * 3, 1.6, -D / 2 + 0.1), 0.3, M['stainless'], 10)
        pipe(root, (-8 + j * 3, 1.6, D / 2 - 0.1), (-8 + j * 3, 1.6, D / 2 + 12), 0.3, M['stainless'], 10)
    for x in (-10, 10):
        blk(root, 2.4, 0.6, 2.4, x, H + 0.6, 0, M['grey'], 0.05)
    blk(root, 1.2, 2.3, 0.2, 11, 0, D / 2 + 0.1, M['grey'], 0.01)
    return root



# THE CLUTTER — what makes a site look worked in rather than finished
def lattice_between(par, a, b, w, M, mat, taper=0.35):
    """A four-chord lattice from a to b, square in section, narrowing to
    `taper` of its width at both ends — a crane boom."""
    A, B = Vector(a), Vector(b)
    d = (B - A)
    L = d.length
    d.normalize()
    up = Vector((0, 1, 0)) if abs(d.y) < 0.95 else Vector((1, 0, 0))
    u = d.cross(up).normalized()
    v = u.cross(d).normalized()
    bays = max(4, int(L / (w * 1.3)))
    def width(t):
        e = min(t, 1 - t) / 0.12
        return w * (taper + (1 - taper) * min(1.0, e))
    def corner(t, i):
        hw = width(t) * 0.5
        su, sv = ((-1, -1), (1, -1), (1, 1), (-1, 1))[i]
        return A + d * (L * t) + u * (su * hw) + v * (sv * hw)
    for i in range(4):
        pts = [tuple(corner(k / bays, i)) for k in range(bays + 1)]
        for p0, p1 in zip(pts, pts[1:]):
            pipe(par, p0, p1, w * 0.035, mat, 5)
    for k in range(bays):
        t0, t1 = k / bays, (k + 1) / bays
        for i in range(4):
            j = (i + 1) % 4
            if k % 2:
                pipe(par, tuple(corner(t0, i)), tuple(corner(t1, j)), w * 0.02, mat, 4)
            else:
                pipe(par, tuple(corner(t0, j)), tuple(corner(t1, i)), w * 0.02, mat, 4)
            pipe(par, tuple(corner(t0, i)), tuple(corner(t0, j)), w * 0.02, mat, 4)


def wheel(par, x, y, z, r, w, M):
    """A wheel, its axle along z: tyre and hub."""
    ob = revolve(nm('tyre'), [(0.0, -w / 2), (r * 0.55, -w / 2), (r, -w * 0.4), (r, w * 0.4), (r * 0.55, w / 2), (0.0, w / 2)],
                 M['rubber'], seg=16, parent=par)
    ob.location = P(x, y, z)
    ob.rotation_euler = (math.pi / 2, 0, 0)
    smooth(ob, 50)


def crawler_crane(M):
    """A heavy crawler crane of the class that stacks Starbase's tank shells
    and tower sections: 100 m of lattice boom on a luffing A-frame, counter-
    weight slabs, and the hook hanging on its falls. Boom toward local +x."""
    root = empty('stage_fac_crawler_crane', (0, 0, 0))
    Y = M['crane-yellow']
    for s in (-1, 1):
        blk(root, 13.0, 1.7, 2.2, 0, 0, s * 3.4, M['black'], 0.12)
        for k in range(12):
            blk(root, 0.35, 0.12, 2.3, -5.9 + k * 1.07, 1.7, s * 3.4, M['grey'], 0)
        for k in range(5):
            wheel(root, -4.6 + k * 2.3, 0.85, s * 3.4 + s * 1.15, 0.55, 0.12, M)
    blk(root, 6.0, 1.2, 5.6, 0, 1.4, 0, M['grey'], 0.08)
    blk(root, 10.5, 3.2, 5.2, -1.5, 2.6, 0, Y, 0.1)                         # house
    blk(root, 2.2, 2.6, 1.8, 3.6, 2.9, 3.0, Y, 0.08)                        # cab
    blk(root, 0.08, 1.4, 1.5, 4.72, 3.8, 3.0, M['glass'], 0)
    blk(root, 1.8, 1.4, 0.08, 3.6, 3.8, 3.92, M['glass'], 0)
    for k in range(5):
        blk(root, 3.2, 1.05, 5.8, -7.8, 2.6 + k * 1.1, 0, M['grey'], 0.06)   # counterweight
    foot = (3.0, 5.5, 0.0)
    ang = math.radians(74)
    Lb = 100.0
    tip = (foot[0] + Lb * math.cos(ang), foot[1] + Lb * math.sin(ang), 0.0)
    lattice_between(root, foot, tip, 3.0, M, Y)
    # the A-frame and the pendants that hold the boom
    af = (-5.0, 18.0, 0.0)
    for s in (-1, 1):
        pipe(root, (-3.5, 5.8, s * 2.0), af, 0.22, Y, 8)
        pipe(root, (1.5, 5.8, s * 2.0), af, 0.18, Y, 8)
    pipe(root, af, tip, 0.06, M['steel'], 5)
    pipe(root, (af[0] - 0.3, af[1], 0.3), (-8.5, 7.8, 0.3), 0.06, M['steel'], 5)
    # the hook on its falls
    hy = tip[1] - 34.0
    for s in (-0.35, 0.35):
        pipe(root, (tip[0], tip[1], s), (tip[0], hy + 1.6, s), 0.03, M['steel'], 4)
    blk(root, 1.1, 1.6, 0.9, tip[0], hy, 0, Y, 0.06)
    lathe_up(root, [(0.0, 0.0), (0.25, 0.0), (0.25, -1.0), (0.0, -1.0)], tip[0], hy, 0, M['steel'], 8)
    return root


def tanker(M):
    """A cryogen road tanker: tractor and a vacuum-jacketed trailer. Every
    kilogram of propellant a pad holds arrived a trailer at a time (Starbase
    took hundreds per launch), so they queue at the fill bays. Nose +x."""
    root = empty('stage_fac_tanker', (0, 0, 0))
    for s in (-0.45, 0.45):
        blk(root, 20.0, 0.3, 0.2, -0.5, 0.9, s, M['black'], 0)
    blk(root, 2.3, 2.7, 2.45, 7.6, 1.1, 0, M['tank-white'], 0.12)          # cab
    blk(root, 1.7, 1.25, 2.2, 9.6, 1.1, 0, M['tank-white'], 0.12)          # hood
    blk(root, 0.06, 1.1, 2.1, 8.78, 2.4, 0, M['glass'], 0)
    for s in (-1, 1):
        blk(root, 1.0, 0.9, 0.06, 7.9, 2.5, s * 1.24, M['glass'], 0)
        pipe(root, (6.4, 1.2, s * 1.0), (6.4, 4.2, s * 1.0), 0.09, M['steel'], 8)   # stacks
    blk(root, 0.3, 0.5, 2.5, 10.5, 0.7, 0, M['grey'], 0.03)
    htank(root, 1.15, 12.5, -2.5, 2.45, 0, M['stainless'], seg=24, saddles=0)
    blk(root, 1.2, 1.5, 2.2, -9.3, 1.0, 0, M['grey'], 0.05)                # hose cabinet
    for x in (9.5, 6.2, 5.0, -6.6, -7.8, -9.0):
        for s in (-1, 1):
            wheel(root, x, 0.52, s * 1.05, 0.52, 0.34, M)
    for s in (-1, 1):
        blk(root, 0.15, 0.9, 0.15, 1.8, 0.0, s * 0.9, M['grey'], 0)
    return root


def containers(M):
    """ISO containers — 12.2 × 2.44 × 2.59 m — stacked two high in rows, in
    the colours shipping lines paint them. Every working site has a yard."""
    root = empty('stage_fac_containers', (0, 0, 0))
    cols = ['cont-a', 'cont-b', 'cont-c', 'cont-d', 'cont-b', 'cont-a', 'cont-d', 'cont-c']
    blk(root, 30, 0.12, 26, 0, 0, 0, M['gravel'], 0.02)
    k = 0
    for row in range(4):
        for col in range(2):
            n = 2 if (row + col) % 3 else 1
            for lev in range(n):
                mat = M[cols[k % len(cols)]]
                k += 1
                x = -6.8 + col * 13.6
                z = -9.0 + row * 6.0 + (0.0 if row % 2 == 0 else 0.0)
                y = 0.12 + lev * 2.59
                blk(root, 12.19, 2.59, 2.44, x, y, z, mat, 0.03)
                for s in (-1, 1):
                    for r in range(1, 12):
                        blk(root, 0.1, 2.3, 0.05, x - 6.1 + r * 1.016, y + 0.14, z + s * 1.24, mat, 0)
                blk(root, 0.06, 2.4, 2.3, x + 6.12, y + 0.1, z, M['black'], 0)
    return root


def trailers(M):
    """A village of portable office trailers on blocks, with their steps
    and air-conditioners, round a boardwalk: the site offices."""
    root = empty('stage_fac_trailers', (0, 0, 0))
    blk(root, 40, 0.1, 26, 0, 0, 0, M['gravel'], 0.02)
    blk(root, 34, 0.2, 2.4, 0, 0.1, 0, M['darkcon'], 0.02)                  # boardwalk
    for row, s in enumerate((-1, 1)):
        for k in range(3):
            x = -11.5 + k * 11.5
            z = s * 5.2
            for bx in (-5.5, -1.5, 2.5, 5.5):
                blk(root, 0.4, 0.6, 3.0, x + bx, 0.1, z, M['concrete'], 0)
            blk(root, 9.8, 3.0, 3.6, x, 0.7, z, M['cladding'], 0.06)
            blk(root, 10.0, 0.15, 3.8, x, 3.7, z, M['roof'], 0.02)
            face = z - s * 1.82
            for w in (-3.2, -1.2, 2.4):
                blk(root, 1.2, 1.0, 0.06, x + w, 2.0, face - s * 0.02, M['glass'], 0)
            blk(root, 0.95, 2.1, 0.06, x + 0.6, 0.72, face - s * 0.02, M['cladding-blue'], 0)
            blk(root, 1.6, 0.12, 1.2, x + 0.6, 0.6, face - s * 0.62, M['darkcon'], 0)
            blk(root, 1.0, 0.8, 0.9, x - 4.2, 3.85, z, M['grey'], 0.04)      # A/C
    return root

def build_facilities(M):
    extra = (
        ('concrete', 0x8d8d88, 0.95, 0.02),
        ('darkcon', 0x5c5c58, 0.96, 0.02),
        ('grey', 0x6e7276, 0.75, 0.35),
        ('safety-yellow', 0xd7ad38, 0.72, 0.04),
        ('oxidized-copper', 0x657a79, 0.58, 0.35),
        ('gravel', 0x9a958a, 0.97, 0.0),
        ('pond', 0x1f3a40, 0.10, 0.0),
        ('cladding', 0xd6d8d6, 0.78, 0.06),
        ('cladding-blue', 0x3f5f7e, 0.62, 0.12),
        ('roof', 0x8b9196, 0.66, 0.3),
        ('tank-white', 0xe4e5e2, 0.62, 0.05),
        ('stainless', 0xbcc1c5, 0.4, 0.22),
        ('weld', 0x979ca1, 0.5, 0.2),
        ('insulator', 0x6a4636, 0.3, 0.02),
        ('lamp', 0xf3efdc, 0.25, 0.0),
        ('rubber', 0x1e1f21, 0.9, 0.0),
        ('crane-yellow', 0xd9a91c, 0.6, 0.1),
        ('cont-a', 0x8c3326, 0.72, 0.15),
        ('cont-b', 0x2e5a86, 0.72, 0.15),
        ('cont-c', 0x3d6e56, 0.72, 0.15),
        ('cont-d', 0xb6b7b1, 0.72, 0.15),
    )
    for name, color, rough, metal in extra:
        M[name] = material(name, srgb(color), rough, metal)
    M['steel'] = material('fac-steel', srgb(0x7a8288), 0.62, 0.45)
    cryo_sphere(M, 'lox_sphere', 10.5, 10, 8)
    cryo_sphere(M, 'lh2_sphere', 10.9, 12, 12)
    water_tower(M)
    rp1_farm(M)
    hypergol(M)
    gas_farm(M)
    substation(M)
    ops_building(M)
    warehouse(M)
    guard_house(M)
    floodlight(M)
    camera_site(M)
    burn_pond(M)
    hif(M)
    tank_farm(M)
    subcooler(M)
    horizontal_tanks(M)
    deluge_tanks(M)
    gse_bunker(M)
    crawler_crane(M)
    tanker(M)
    containers(M)
    trailers(M)


build('facilities', build_facilities, 'assets/pads/facilities.glb')
