# ---------------------------------------------------------------------------
# SPACE SHUTTLE — the winged one, and the only stack here that is not a stack.
# ---------------------------------------------------------------------------
# The orbiter's engines light on the pad and burn all the way to cutoff, fed
# from a tank that is not part of the orbiter and is thrown away. The solids
# cannot be shut down once lit. Nothing about the arrangement is stacked:
# vehicles.js MOUNTS all three (`look.mount`), the solids hang below the tank's
# base, and the orbiter is bolted to the SIDE.
#
# Three shapes here are not bodies of revolution, and that is the whole reason
# this vehicle is worth authoring:
#
#   · THE FUSELAGE is a rounded-square section whose width and height change
#     independently — `loft`, not a lathe. A cylinder is not a coarse model of
#     an orbiter, it is a different object.
#   · THE WING is a double delta. The kink at x = 5.4 m is the planform: a 79
#     degree glove that keeps the shock attached at hypersonic speed, then a 45
#     degree outer panel that still has a lift curve at 200 knots on final.
#   · THE WHITE/BLACK SPLIT is the thermal design made visible. Carbon-carbon
#     and black HRSI go where the plasma goes — underside, leading edges, nose
#     cap; everything that only ever sees space is white LRSI and felt. Getting
#     that boundary right does more for the read than any panel detail.
#
# Axes: the orbiter is built nose-up along +Z with the wings on +/-X and the
# BELLY toward the tank. `loft` and `wing` take their vertical terms as
# up-positive, so the section tables below transfer from craftmodel.js as
# written — see the axis note in lib.py.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, disc, empty, finish,
                 smooth, strut, bell, ball, ogive, loft, wing, rcs_ring, TAU)
from common import build, stage

SRB_L, SRB_D = 45.5, 3.71
ET_L, ET_D = 46.9, 8.40
ORB_L = 37.2
f = lambda u: u * ORB_L


# ---------------------------------------------------------------------------
# THE SOLIDS
# ---------------------------------------------------------------------------
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
        # The nozzle hangs on a PIVOT, and it has to: parts.gimbals is where
        # spaceflight.js hangs the plumes as well as where the deflection is
        # applied, so a booster with no pivot burns invisibly. These two
        # produce 71% of the thrust at liftoff. The RSRM's nozzle really does
        # gimbal 8 degrees — a solid cannot be throttled or shut down, so
        # vectoring it is the only control the stack has until the SSMEs have
        # authority.
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


# ---------------------------------------------------------------------------
# EXTERNAL TANK
# ---------------------------------------------------------------------------
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

    # ---- the bipod fitting the orbiter's nose hangs on, and the aft attach
    # ring. These carry the entire orbiter, and one of them is why STS-107 was
    # lost — the foam ramp over this bipod is what came off.
    for sgn in (-1, 1):
        strut(f'bipod{sgn}', (sgn * 0.9, -r * 0.98, ET_L * 0.60),
              (sgn * 1.4, -r * 1.9, ET_L * 0.56), 0.16, M['dirty'], seg=8, parent=g)
    ar = torus_z('aftring', r * 1.01, 0.14, ET_L * 0.15, M['dirty'],
                 seg=48, minor=8, parent=g)
    smooth(ar, 30)
    return g


# ---------------------------------------------------------------------------
# ORBITER
# ---------------------------------------------------------------------------
def build_orbiter(M, root):
    g = stage('orbiter', root)

    # ---- fuselage stations: half-width in X, half-height, centreline offset,
    # and a superellipse exponent carrying the section from near-circular at
    # the nose to the rounded square of the payload bay, which is a box with
    # a lid on it.
    sec = [
        {'z': f(0.000), 'w': 2.35, 'h': 2.60, 'cz': 0.10, 'n': 3.0},
        {'z': f(0.030), 'w': 2.62, 'h': 2.86, 'cz': 0.06, 'n': 3.4},
        {'z': f(0.090), 'w': 2.78, 'h': 2.92, 'cz': 0.02, 'n': 3.6},
        {'z': f(0.200), 'w': 2.80, 'h': 2.86, 'cz': 0.00, 'n': 3.6},
        {'z': f(0.400), 'w': 2.80, 'h': 2.80, 'cz': 0.00, 'n': 3.6},
        {'z': f(0.640), 'w': 2.80, 'h': 2.74, 'cz': 0.00, 'n': 3.5},
        {'z': f(0.720), 'w': 2.72, 'h': 2.58, 'cz': 0.02, 'n': 3.2},
        {'z': f(0.800), 'w': 2.44, 'h': 2.26, 'cz': 0.06, 'n': 2.9},
        {'z': f(0.865), 'w': 2.02, 'h': 1.84, 'cz': 0.10, 'n': 2.7},
        {'z': f(0.925), 'w': 1.42, 'h': 1.30, 'cz': 0.12, 'n': 2.5},
        {'z': f(0.968), 'w': 0.78, 'h': 0.72, 'cz': 0.12, 'n': 2.3},
        {'z': f(1.000), 'w': 0.10, 'h': 0.10, 'cz': 0.10, 'n': 2.2},
    ]
    # Two shells split at the waterline: white blanket over, black tile under.
    up = loft('fus_top', sec, M['white'], seg=34, t0=0.0, t1=pi, parent=g)
    lo = loft('fus_bot', sec, M['tiles'], seg=34, t0=pi, t1=TAU, parent=g)
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
        # Reinforced carbon-carbon leading edge: 22 panels a side, and the
        # hottest structure on the vehicle at about 1 500 C. It is a DIFFERENT
        # COLOUR from the wing behind it, which is how you read the planform.
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

    # ---- three SSMEs, in the triangle they actually sit in: one high on the
    # centreline, two low and outboard. They gimbal 10.5 degrees, which is the
    # most of any engine in this set, because they are steering the whole stack.
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

    # ---- body flap: the slab under the engines that trims the vehicle in
    # hypersonic flight and shields the bells. Small, and very recognisable.
    # It goes in parts.flaps, so the node it hangs on must have NO rotation
    # about the driven axis — the build-time cant is about X only.
    fl = empty('flap_orbiter_0', (0, 2.35, f(0.028)), g)
    fl.rotation_euler = (0.12, 0, 0)
    bf = box('bodyflap', (4.3, 0.36, 2.3), (0, 0, 0), M['tiles'], parent=fl)
    finish(bf, 0.02, 2, 40)

    # ---- payload bay doors, closed: two long panels along the top with the
    # radiator lines that live on their inner face showing as seams.
    for k, sgn in enumerate((-1, 1)):
        t0 = 0.10 if sgn > 0 else pi - 0.10
        t1 = pi / 2 - 0.03 if sgn > 0 else pi / 2 + 0.03
        door = loft(f'paydoor{k}', [
            {'z': f(0.215), 'w': 2.62, 'h': 2.62, 'n': 3.4},
            {'z': f(0.640), 'w': 2.62, 'h': 2.60, 'n': 3.4},
        ], M['dirty'], seg=16, t0=min(t0, t1), t1=max(t0, t1), parent=g)
        smooth(door, 30)

    # ---- forward flight deck windows. Nothing else on the vehicle says "there
    # are people in this". The surface has to be EVALUATED rather than guessed:
    # the section here is a superellipse, so solve it for the height at the
    # window's own x and stand the glass a few centimetres proud of it. Placed
    # at a fixed offset they sit inside the hull and never show at all.
    win = {'w': 1.72, 'h': 1.56, 'cz': 0.11, 'n': 2.7}
    def surf(x):
        return win['cz'] + win['h'] * max(1 - (abs(x) / win['w']) ** win['n'], 0) ** (1 / win['n'])
    for i in range(6):
        a = (i - 2.5) / 2.5
        x = a * 1.30
        w_ = box(f'win{i}', (0.52, 0.10, 0.46),
                 (x, -(surf(x) + 0.02), f(0.897)), M['glass'],
                 rot=(0.62, 0, a * 0.42), parent=g)
    for k, dx in enumerate((-0.42, 0.42)):
        ov = box(f'overhead{k}', (0.44, 0.10, 0.44),
                 (dx, -(surf(dx) + 0.10), f(0.856)), M['glass'],
                 rot=(0.05, 0, 0), parent=g)
    # Side hatch, on the port side of the crew cabin.
    hatch = cyl('hatch', 0.50, 0.50, -0.04, 0.04, M['dirty'], seg=20, parent=g)
    hatch.location = (-1.86, -0.55, f(0.845))
    hatch.rotation_euler = (0, pi / 2, 0)

    # Forward RCS, in the nose.
    for k in range(4):
        a = (k - 1.5) * 0.35
        n = cyl(f'frcs{k}', 0.09, 0.11, 0, 0.20, M['black'], seg=8, parent=g)
        n.location = (sin(a) * 1.15, -cos(a) * 1.15, f(0.940))
        n.rotation_euler = (pi / 2, 0, a)

    # ---- black nose cap: the hottest single point on the vehicle, ~1 600 C.
    cap = loft('nosecap', [
        {'z': f(0.962), 'w': 0.90, 'h': 0.84, 'cz': 0.10, 'n': 2.3},
        {'z': f(0.985), 'w': 0.56, 'h': 0.52, 'cz': 0.10, 'n': 2.2},
        {'z': f(1.000), 'w': 0.10, 'h': 0.10, 'cz': 0.10, 'n': 2.2},
    ], M['tiles'], seg=24, parent=g)
    smooth(cap, 32)
    return g


def build_shuttle(M):
    root = empty('Shuttle', (0, 0, 0))
    build_srb(M, root)
    build_et(M, root)
    build_orbiter(M, root)


build('shuttle', build_shuttle)
