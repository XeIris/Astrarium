# SPACE SHUTTLE, the Blender build. Nothing is stacked: vehicles.gd mounts all
# three (`look.mount`), the solids hang below the tank's base, and the orbiter is
# bolted to its side. Three non-revolved shapes:
#   · the fuselage: a rounded-square section whose width and height vary
#     independently (`loft`)
#   · the wing: a double delta kinked at x = 5.4 m (79° glove, 45° outer panel)
#   · the white/black split: RCC and black HRSI where the plasma goes (underside,
#     leading edges, nose cap), white LRSI and felt elsewhere
# The orbiter is nose-up along +Z, wings on ±X, belly toward the tank. `loft` and
# `wing` take vertical terms up-positive (see lib.py's axis note).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin, copysign
from mathutils import Vector
from lib import (revolve, cyl, lathe, tank, box, torus_z, disc, empty, finish,
                 smooth, strut, bell, ball, ogive, loft, wing, rcs_ring, naca, _obj, TAU)
from common import build, stage

SRB_L, SRB_D = 45.5, 3.71
ET_L, ET_D = 46.9, 8.40
ORB_L = 37.2
f = lambda u: u * ORB_L


# The orbiter's hull as a function, so details can be placed on it:
# (u, belly, back, half-width, superellipse n, black-line angle s). Heights are
# up-positive from the payload bay axis; s is the angle above the section's middle
# where the black tile stops (negative: below it).
_FUS = [
    (0.000, -2.50, 2.70, 2.35, 3.0, -0.30),
    (0.030, -2.80, 2.92, 2.62, 3.4, -0.30),
    (0.090, -2.90, 2.94, 2.78, 3.6, -0.30),
    (0.200, -2.86, 2.86, 2.80, 3.6, -0.30),
    (0.400, -2.80, 2.80, 2.80, 3.6, -0.30),
    (0.640, -2.76, 2.76, 2.80, 3.5, -0.30),
    (0.762, -2.76, 2.78, 2.80, 3.4, -0.28),
    (0.800, -2.76, 2.88, 2.74, 3.2, -0.22),
    (0.835, -2.72, 2.90, 2.62, 3.0, -0.12),
    (0.855, -2.64, 2.66, 2.50, 2.9, 0.00),
    (0.880, -2.52, 1.95, 2.30, 2.8, 0.14),
    (0.905, -2.36, 1.30, 2.05, 2.6, 0.26),
    (0.935, -2.12, 0.78, 1.72, 2.5, 0.22),
    (0.960, -1.84, 0.30, 1.30, 2.4, 0.14),
    (0.980, -1.56, -0.18, 0.86, 2.3, 0.10),
    (0.993, -1.32, -0.55, 0.46, 2.2, 0.10),
    (1.000, -1.05, -0.85, 0.10, 2.2, 0.10),
]


def orbiter_sections():
    return [{'u': u, 'z': f(u), 'w': w, 'h': (top - bot) / 2, 'cz': (top + bot) / 2, 'n': n, 's': sp}
            for (u, bot, top, w, n, sp) in _FUS]


def _sec_at(secs, u):
    for a, b in zip(secs, secs[1:]):
        if a['u'] <= u <= b['u']:
            k = (u - a['u']) / max(b['u'] - a['u'], 1e-9)
            return {key: a[key] + (b[key] - a[key]) * k for key in ('z', 'w', 'h', 'cz', 'n', 's')}
    return dict(secs[-1] if u > secs[-1]['u'] else secs[0])


def _pt(c, t):
    e = 2.0 / c['n']
    ct, st = cos(t), sin(t)
    x = c['w'] * copysign(abs(ct) ** e, ct)
    upv = c['h'] * copysign(abs(st) ** e, st) + c['cz']
    return Vector((x, -upv, c['z']))


def hull(secs, u, t, off=0.0):
    """The point of the hull at (u, t), stood `off` metres out along its normal."""
    p = _pt(_sec_at(secs, u), t)
    if off == 0.0:
        return p
    du, dt = 1e-3, 1e-3
    a = _pt(_sec_at(secs, min(u + du, 1.0)), t) - _pt(_sec_at(secs, max(u - du, 0.0)), t)
    b = _pt(_sec_at(secs, u), t + dt) - _pt(_sec_at(secs, u), t - dt)
    n = b.cross(a)
    if n.length < 1e-9:
        n = Vector((0, 0, 1))
    # outward: away from the section's own axis (the tip, where the section
    # has shrunk to nothing, is outward along +z)
    c = _sec_at(secs, u)
    axis = Vector((0.0, -c['cz'], c['z']))
    if n.dot(p - axis) < 0 or (u > 0.999 and n.z < 0):
        n = -n
    return p + n.normalized() * off


def hull_normal(secs, u, t):
    return (hull(secs, u, t, 1.0) - hull(secs, u, t)).normalized()


def loft_split(name, secs, mat, rng, seg=32, parent=None):
    """`loft`, with each section's angular range its own (rng(section) ->
    (t0, t1)): what lets the black/white boundary climb toward the nose."""
    ring = seg + 1
    verts, faces = [], []
    for c in secs:
        t0, t1 = rng(c)
        for j in range(ring):
            verts.append(tuple(_pt(c, t0 + (t1 - t0) * j / seg)))
    for i in range(len(secs) - 1):
        for j in range(seg):
            a0 = i * ring + j
            faces.append((a0, a0 + ring, a0 + ring + 1, a0 + 1))
    return _obj(name, verts, faces, mat, parent)


def surf_patch(name, secs, u0, u1, t0, t1, off, mat, parent, nu=4, nt=4):
    """A patch OF the hull over u0..u1 × t0..t1, stood `off` off it."""
    verts, faces = [], []
    for i in range(nu + 1):
        u = u0 + (u1 - u0) * i / nu
        for j in range(nt + 1):
            verts.append(tuple(hull(secs, u, t0 + (t1 - t0) * j / nt, off)))
    R = nt + 1
    for i in range(nu):
        for j in range(nt):
            a = i * R + j
            faces.append((a, a + R, a + R + 1, a + 1))
    ob = _obj(name, verts, faces, mat, parent)
    smooth(ob, 40)
    return ob


def port(parent, secs, u, t, r, depth, mat, name):
    """A round feature — a thruster mouth, a hatch — set into the hull along
    its normal, half sunk."""
    n = hull_normal(secs, u, t)
    ob = cyl(name, r, r, -depth * 0.5, depth * 0.5, mat, seg=14, parent=parent)
    cap = disc(name + '_c', r, depth * 0.5, mat, seg=14, parent=parent)
    for o in (ob, cap):
        o.rotation_mode = 'QUATERNION'
        o.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(n)
        o.location = hull(secs, u, t)


# THE SOLIDS
def build_srb(M, root):
    """
    A PAIR, and the vehicle stands on them: z = 0 here is the NOZZLE EXIT
    PLANE, level with the pad, so the whole 45.5 m is measured the way the
    published number is rather than from an arbitrary datum.

    A solid's read is its JOINTS. The RSRM ships as four casting segments
    bolted together with tang-and-clevis field joints, and those four raised
    bands — plus the systems tunnel running the full length between them — are
    what separate a booster from a white pipe at any distance you see one from.
    """
    g = stage('srb', root)
    r = SRB_D / 2
    for side in (-1, 1):
        b = empty(f'srb{side}', (side * 6.35, 0, 0), g)

        # Aft skirt: the flared structure that actually carries the whole stack
        # on the pad, with the nozzle recessed inside it. Wider than the case.
        sk = cyl(f'skirt{side}', r * 1.30, r * 1.02, 0.0, SRB_L * 0.098,
                 M['dirty'], seg=40, parent=b)
        finish(sk, 0.02, 2, 45)
        # The nozzle hangs on a pivot, since plumes parent to parts.gimbals. The RSRM
        # vectors 8°, the stack's only control until the SSMEs have authority.
        piv = empty(f'gimbal_srb_{0 if side < 0 else 1}',
                    (side * 6.35, 0, SRB_L * 0.085), g)
        nz = bell(f'srbnoz{side}', 3.75, M['nozzle'], ratio=7.7, chamber=False,
                  seg=32, parent=piv)
        finish(nz, 0.015, 2, 50)

        # Motor case: four segments, so four field joints.
        case_z, case_l = SRB_L * 0.098, SRB_L * 0.735
        body = cyl(f'case{side}', r, r, case_z, case_z + case_l, M['white'],
                   seg=48, parent=b)
        finish(body, 0.02, 2, 40)
        for i in range(1, 5):
            j = torus_z(f'joint{side}_{i}', r * 1.018, SRB_D * 0.022,
                        case_z + case_l * i / 5, M['dirty'], seg=48, minor=8, parent=b)
            smooth(j, 30)
        # Systems tunnel — the cable raceway down the outboard face.
        tun = box(f'tunnel{side}', (SRB_D * 0.10, SRB_D * 0.07, case_l * 0.98),
                  (side * r * 0.99, 0, case_z + case_l / 2), M['dirty'], parent=b)
        finish(tun, 0.015, 2, 40)

        # Forward skirt, frustum and nose cap. The frustum is where the drogue
        # and main parachutes live, which is why it comes off separately.
        fs_z, fs_l = case_z + case_l, SRB_L * 0.070
        fs = cyl(f'fwdskirt{side}', r, r, fs_z, fs_z + fs_l, M['white'],
                 seg=40, parent=b)
        fr_l = SRB_L * 0.048
        fr = cyl(f'frustum{side}', r, r * 0.72, fs_z + fs_l, fs_z + fs_l + fr_l,
                 M['white'], seg=40, parent=b)
        finish(fr, 0.02, 2, 45)
        cap_z = fs_z + fs_l + fr_l
        cap = ogive(f'cap{side}', SRB_L - cap_z, r * 1.44, M['white'], seg=40,
                    parent=b, z0=cap_z)
        finish(cap, 0.02, 2, 45)

        # The forward attach fitting and the aft struts: the booster does not
        # touch the tank, it is HELD OFF it, and the gap is a structural fact.
        for k, (z, ln) in enumerate(((fs_z + fs_l * 0.4, 0.9),
                                     (case_z + case_l * 0.06, 1.1),
                                     (case_z + case_l * 0.13, 1.1))):
            strut(f'attach{side}{k}', (-side * r, 0, z),
                  (-side * (r + ln), 0, z), 0.16, M['dirty'], seg=8, parent=b)
    return g


# EXTERNAL TANK
def build_et(M, root):
    """
    46.9 m is the WHOLE tank, ogive included, so the barrel is SHORTENED to
    make room for the nose rather than the nose added on top — otherwise the
    stack stands 8 m taller than the real one.

    The tank draws no engines. `engineOn: 'orbiter'` in vehicles.js says the
    SSMEs are on the orbiter and merely fed from here; a tank that drew them
    too would fly the stack with six main engines, three of them bolted to
    something it throws away.
    """
    g = stage('et', root)
    r = ET_D / 2
    nose_l = ET_D * 1.45

    body = tank('et_body', ET_L - nose_l, ET_D, M['foam'], dome_top=0.0,
                dome_bot=0.02, seg=56, parent=g)
    finish(body, 0.03, 2, 40)
    nose = ogive('et_nose', nose_l, ET_D, M['foam'], seg=56, parent=g,
                 z0=ET_L - nose_l)
    finish(nose, 0.03, 2, 40)

    # ---- the intertank: the one stringered band on an otherwise smooth tank,
    # and the feature that stops 47 m of orange foam reading as a crayon.
    it_z, it_h = ET_L * 0.545, ET_L * 0.115
    for i in range(44):
        a = i / 44 * TAU
        box(f'stringer{i}', (0.16, 0.16, it_h),
            (cos(a) * r * 1.005, sin(a) * r * 1.005, it_z + it_h / 2),
            M['foam'], rot=(0, 0, a), parent=g)
    for k, zz in enumerate((it_z, it_z + it_h)):
        b_ = torus_z(f'itband{k}', r * 1.012, 0.10, zz, M['foam'],
                     seg=56, minor=8, parent=g)
        smooth(b_, 30)

    # ---- the LO2 feedline and the pressurisation lines, which run the length
    # of the tank on the orbiter's side. The only straight lines on the object.
    for k, (ax, pr) in enumerate(((0.34, 0.24), (-0.34, 0.13))):
        pipe = cyl(f'feedline{k}', pr, pr, ET_L * 0.05, ET_L * 0.85,
                   M['dirty'], seg=14, parent=g)
        pipe.location = (sin(ax) * r * 1.06, -cos(ax) * r * 1.06, 0)
        finish(pipe, 0.012, 2, 45)
        # Standoff brackets, every few metres, so the line is plumbed rather
        # than glued to the foam.
        for i in range(7):
            box(f'standoff{k}{i}', (0.10, 0.30, 0.10),
                (sin(ax) * r * 1.02, -cos(ax) * r * 1.02, ET_L * (0.10 + i * 0.12)),
                M['dirty'], parent=g)

    # ---- the bipod fitting the orbiter's nose hangs on, and the aft attach ring (the
    # foam ramp over the bipod is what came off on STS-107).
    for sgn in (-1, 1):
        strut(f'bipod{sgn}', (sgn * 0.9, -r * 0.98, ET_L * 0.60),
              (sgn * 1.4, -r * 1.9, ET_L * 0.56), 0.16, M['dirty'], seg=8, parent=g)
    ar = torus_z('aftring', r * 1.01, 0.14, ET_L * 0.15, M['dirty'],
                 seg=48, minor=8, parent=g)
    smooth(ar, 30)
    return g


# ORBITER
def build_orbiter(M, root):
    g = stage('orbiter', root)

    # ---- the fuselage from its own profile: belly line, back line and half-width per
    # station, with n going from near-circular at the nose to the payload bay's rounded
    # square. Belly and back are separate because the nose isn't symmetric: the belly
    # runs flat almost to a low tip, then the forward RCS module climbs to a steep
    # windscreen and a cabin roof just proud of the bay. u runs aft (0) to nose (1);
    # stations follow the Xo frame (bay Xo 582–1307, forward RCS Xo 238–378).
    fus = orbiter_sections()
    # Two shells split where the plasma reaches: low along the bay, climbing round the
    # chin to the windscreen corners.
    up = loft_split('fus_top', fus, M['white'], lambda c: (c['s'], pi - c['s']), seg=40, parent=g)
    lo = loft_split('fus_bot', fus, M['tiles'], lambda c: (pi - c['s'], TAU + c['s']), seg=40, parent=g)
    smooth(up, 32); smooth(lo, 32)

    # ---- wing: the double delta.
    ws = [
        {'x': 2.52, 'zLE': f(0.700), 'chord': f(0.673), 'thick': 0.055, 'cz': -1.30},
        {'x': 3.80, 'zLE': f(0.560), 'chord': f(0.533), 'thick': 0.060, 'cz': -1.20},
        {'x': 5.40, 'zLE': f(0.360), 'chord': f(0.333), 'thick': 0.070, 'cz': -1.10},
        {'x': 8.60, 'zLE': f(0.245), 'chord': f(0.218), 'thick': 0.085, 'cz': -0.85},
        {'x': 11.30, 'zLE': f(0.147), 'chord': f(0.112), 'thick': 0.100, 'cz': -0.62},
        {'x': 11.90, 'zLE': f(0.138), 'chord': f(0.062), 'thick': 0.110, 'cz': -0.58},
    ]
    for sgn in (1, -1):
        for w_ in wing(f'wing{sgn}', ws, M['white'], M['tiles'], sign=sgn, parent=g):
            smooth(w_, 34)
        # RCC leading edge: 22 panels a side, ~1500 °C, a different colour from the wing.
        for i in range(len(ws) - 1):
            a0, a1 = ws[i], ws[i + 1]
            strut(f'rcc{sgn}{i}',
                  (sgn * a0['x'], -a0.get('cz', 0), a0['zLE']),
                  (sgn * a1['x'], -a1.get('cz', 0), a1['zLE']),
                  0.16, M['tiles'], seg=8, parent=g)

    # ---- vertical tail. Built in the wing's own frame (span on X) and rotated
    # upright, so one function serves both surfaces.
    ts = [
        {'x': 0.0, 'zLE': f(0.185), 'chord': 6.10, 'thick': 0.13},
        {'x': 3.4, 'zLE': f(0.140), 'chord': 4.85, 'thick': 0.13},
        {'x': 6.6, 'zLE': f(0.100), 'chord': 3.55, 'thick': 0.14},
        {'x': 7.9, 'zLE': f(0.083), 'chord': 2.75, 'thick': 0.15},
    ]
    tail = empty('tail', (0, -2.55, 0), g)
    tail.rotation_euler = (0, 0, -pi / 2)
    for w_ in wing('vtail', ts, M['white'], M['white'], parent=tail):
        smooth(w_, 34)
    # the rudder/speedbrake hinge line and the split between its two halves
    for side in (1, -1):
        pts = [(st['x'], -side * (naca(0.62, st['thick']) * st['chord'] + 0.015), st['zLE'] - 0.62 * st['chord'])
               for st in ts]
        for k, (a_, b_) in enumerate(zip(pts, pts[1:])):
            strut(f'rudder_hinge{side}{k}', a_, b_, 0.03, M['tiles'], seg=5, parent=tail)

    # ---- OMS pods: the two bulges either side of the fin root. They hold the
    # orbiter's OWN engines, the only ones it keeps once the tank is gone.
    for sgn in (-1, 1):
        pod = loft(f'oms{sgn}', [
            {'z': f(0.020), 'w': 0.55, 'h': 0.55, 'n': 2.4},
            {'z': f(0.060), 'w': 1.05, 'h': 1.00, 'n': 2.6},
            {'z': f(0.120), 'w': 1.25, 'h': 1.15, 'n': 2.6},
            {'z': f(0.175), 'w': 1.05, 'h': 0.95, 'n': 2.5},
            {'z': f(0.215), 'w': 0.45, 'h': 0.42, 'n': 2.4},
        ], M['white'], seg=22, parent=g)
        pod.location = (sgn * 2.05, -1.95, 0)
        smooth(pod, 32)
        # The OMS bell, canted out and down the way the real one is.
        b = bell(f'omsbell{sgn}', 1.35, M['nozzle'], ratio=55, seg=20, parent=g)
        b.location = (sgn * 2.15, -1.55, f(0.035))
        b.rotation_euler = (-0.30, -sgn * 0.18, 0)
        finish(b, 0.008, 2, 50)
        # Aft RCS: clusters of black nozzle mouths in the pod, which is how you
        # actually spot them in a photograph.
        for k in range(3):
            n = cyl(f'arcs{sgn}{k}', 0.11, 0.13, 0, 0.22, M['black'], seg=8, parent=g)
            n.location = (sgn * (2.7 + k * 0.1), -(2.3 - k * 0.5), f(0.19 + k * 0.006))
            n.rotation_euler = (0, sgn * pi / 2, 0)

    # ---- three SSMEs: one high on the centreline, two low and outboard. They gimbal
    # 10.5°, the most in the set.
    for i, (x, zc) in enumerate(((0, 1.30), (-1.55, -0.55), (1.55, -0.55))):
        piv = empty(f'gimbal_orbiter_{i}', (x, -zc, f(0.045)), g)
        b = bell(f'ssme{i}', 2.30, M['nozzle'], ratio=69, seg=26, parent=piv)
        finish(b, 0.010, 2, 50)
    # The boat-tail shroud the engines hang out of.
    aft = loft('boattail', [
        {'z': f(0.000), 'w': 2.30, 'h': 2.45, 'cz': 0.10, 'n': 3.0},
        {'z': f(0.055), 'w': 2.70, 'h': 2.90, 'cz': 0.05, 'n': 3.4},
    ], M['black'], seg=28, parent=g)
    smooth(aft, 32)

    # ---- body flap: trims hypersonic flight and shields the bells. In parts.flaps, so
    # its node has no rotation about the driven axis (the cant is about X only).
    fl = empty('flap_orbiter_0', (0, 2.35, f(0.028)), g)
    fl.rotation_euler = (0.12, 0, 0)
    bf = box('bodyflap', (4.3, 0.36, 2.3), (0, 0, 0), M['tiles'], parent=fl)
    finish(bf, 0.02, 2, 40)

    # ---- payload bay doors, closed: centreline seam, hinge lines and door frames, as
    # lines on the fuselage skin.
    seam = M['dirty']
    surf_patch('bay_ctr', fus, 0.215, 0.762, pi / 2 - 0.0007, pi / 2 + 0.0007, 0.012, seam, g, nu=6, nt=1)
    for sgn, t in ((1, 0.30), (-1, pi - 0.30)):
        surf_patch(f'bay_hinge{sgn}', fus, 0.215, 0.762, t - 0.004, t + 0.004, 0.012, seam, g, nu=6, nt=1)
    for k in range(1, 4):
        u = 0.215 + (0.762 - 0.215) * k / 4
        surf_patch(f'bay_frame{k}', fus, u - 0.0008, u + 0.0008, 0.30, pi - 0.30, 0.012, seam, g, nu=1, nt=12)

    # ---- THE WINDSCREEN: six forward panes wrapping the cabin and two overhead, set in
    # black HRSI. Each pane is a patch of the hull, stood a few cm off it.
    surf_patch('ws_mask', fus, 0.852, 0.906, 0.64, pi - 0.64, 0.02, M['tiles'], g, nu=14, nt=24)
    pitch, half = 0.285, 0.098
    for i in range(6):
        c = pi / 2 + (i - 2.5) * pitch
        surf_patch(f'ws_pane{i}', fus, 0.8585, 0.8995, c - half, c + half, 0.034, M['glass'], g, nu=8, nt=4)
    surf_patch('oh_mask', fus, 0.826, 0.846, pi / 2 - 0.25, pi / 2 + 0.25, 0.02, M['tiles'], g, nu=4, nt=8)
    for sgn in (-1, 1):
        c = pi / 2 + sgn * 0.125
        surf_patch(f'oh_pane{sgn}', fus, 0.829, 0.843, c - 0.08, c + 0.08, 0.034, M['glass'], g, nu=3, nt=3)
    # the side hatch, port side of the middeck, with its round window
    port(g, fus, 0.834, pi + 0.04, 0.52, 0.03, M['dirty'], 'hatch')
    port(g, fus, 0.834, pi + 0.04, 0.14, 0.08, M['glass'], 'hatch_win')

    # ---- forward RCS: fourteen thrusters in three groups (two pairs up out of the
    # crown, a row out of each side).
    for sgn in (-1, 1):
        for k, u in enumerate((0.944, 0.951)):
            for j, dt in enumerate((0.10, 0.20)):
                port(g, fus, u, pi / 2 + sgn * dt, 0.10, 0.16, M['black'], f'frcs_up{sgn}{k}{j}')
        for k, u in enumerate((0.936, 0.944, 0.952)):
            port(g, fus, u, (0.34 if sgn > 0 else pi - 0.34), 0.10, 0.16, M['black'], f'frcs_side{sgn}{k}')
    # vernier and down-firing jets under the chin
    for sgn in (-1, 1):
        port(g, fus, 0.955, 3 * pi / 2 + sgn * 0.30, 0.08, 0.14, M['black'], f'frcs_dn{sgn}')

    # ---- black nose cap: the hottest single point on the vehicle, ~1 600 C,
    # reinforced carbon-carbon, with the tile ring round it.
    surf_patch('nosecap', fus, 0.968, 1.0, 0.0, TAU, 0.010, M['tiles'], g, nu=6, nt=40)

    # ---- elevons and rudder as separate panels, with their hinge lines and the
    # inboard/outboard elevon gap.
    for sgn in (1, -1):
        pts = []
        for st in ws[:-1]:
            u = 0.80
            upv = st['cz'] + naca(u, st['thick']) * st['chord'] + 0.015
            pts.append((sgn * st['x'], -upv, st['zLE'] - u * st['chord']))
        for a, b in zip(pts, pts[1:]):
            strut(f'elevon_hinge{sgn}_{a[0]:.1f}', a, b, 0.035, M['tiles'], seg=5, parent=g)
        # the inboard/outboard split, hinge to trailing edge
        st = ws[3]
        z0 = st['zLE'] - 0.80 * st['chord']
        z1 = st['zLE'] - 0.995 * st['chord']
        strut(f'elevon_split{sgn}', (sgn * st['x'], -(st['cz'] + naca(0.8, st['thick']) * st['chord'] + 0.015), z0),
              (sgn * st['x'], -(st['cz'] + 0.02), z1), 0.035, M['tiles'], seg=5, parent=g)
    return g


def build_shuttle(M):
    root = empty('Shuttle', (0, 0, 0))
    build_srb(M, root)
    build_et(M, root)
    build_orbiter(M, root)


build('shuttle', build_shuttle)
