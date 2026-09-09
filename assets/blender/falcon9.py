# ---------------------------------------------------------------------------
# FALCON 9 BLOCK 5 — the working reusable launcher.
# ---------------------------------------------------------------------------
# Four stages in the model's sense: booster, second stage, fairing, payload.
# The booster is the interesting object — it separates at ~65 km with a third
# of its delta-v still in the tanks and spends it on coming back — and almost
# everything that distinguishes it from a plain white tube is recovery
# hardware: grid fins, four stowed legs lying along the body as dark strakes,
# a soot-black interstage, and the octaweb they all bolt to.
#
# Dimensions are vehicles.js: 41.2 m and 3.66 m for the booster, 13.8 m for
# the second stage, a 13.1 m x 5.2 m fairing, and the payload MOUNTED at 61 m
# rather than stacked — it rides inside the shroud, not on its nose.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, dish, disc, empty,
                 finish, smooth, strut, bell, ball, ogive, grid_fin,
                 landing_leg, solar_array, stripe, rcs_ring, TAU)
from common import build, stage

S1_L, S1_D = 41.2, 3.66
S1_IS = 4.0                        # interstage, black composite
S2_L, S2_D = 13.8, 3.66
FR_L, FR_D = 13.1, 5.2
PL_L, PL_D = 5.0, 3.4


# ---------------------------------------------------------------------------
# STAGE 1
# ---------------------------------------------------------------------------
def build_s1(M, root):
    g = stage('f9s1', root)
    r = S1_D / 2

    # The barrel. A flat top, because the interstage sits on it: the lathe's
    # dome would curve away underneath and leave a pinched gap at the joint.
    body = tank('s1_body', S1_L, S1_D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=56, parent=g)
    finish(body, 0.02, 2, 40)

    # The soot band. A flight-proven booster is BLACK for the bottom few metres
    # and that is not weathering for its own sake — it is the single clearest
    # sign that this vehicle is on its second flight or its twentieth.
    st = stripe('soot', S1_D, 0.0, S1_L * 0.12, M['soot'], seg=56, parent=g)
    # The LOX/RP-1 dome joint, roughly two thirds up, and the raceway that runs
    # the full length carrying the harness and the helium lines.
    j = torus_z('domejoint', r * 1.008, S1_D * 0.008, S1_L * 0.63, M['dirty'],
                seg=56, minor=6, parent=g)
    smooth(j, 30)
    ray = box('raceway', (S1_D * 0.10, S1_D * 0.07, S1_L * 0.92),
              (0, -r * 1.02, S1_L * 0.50), M['dirty'], parent=g)
    finish(ray, 0.015, 2, 40)

    # ---- octaweb: a visible black machined structure, not a smooth base.
    ow = revolve('octaweb', [(0, 0), (r * 0.97, 0), (r * 1.01, S1_D * 0.26),
                             (0, S1_D * 0.26)], M['black'], seg=8, parent=g)
    ow.rotation_euler = (0, 0, pi / 8)
    finish(ow, 0.02, 2, 40)

    # ---- nine Merlins: eight around one, the octaweb arrangement. The centre
    # engine is the one that lands the stage, and it is the only one lit for
    # the last twenty seconds of the flight.
    spread = S1_D * 0.30
    def place(i, x, y):
        piv = empty(f'gimbal_f9s1_{i}', (x, y, -0.02), g)
        b = bell(f'merlin{i}', 0.92, M['nozzle'], ratio=16, seg=20, parent=piv)
        finish(b, 0.006, 2, 50)
        return piv
    place(0, 0, 0)
    for i in range(8):
        a = i / 8 * TAU + 0.39
        place(i + 1, cos(a) * spread, sin(a) * spread)
    # The thrust structure the bells hang out of.
    ts = cyl('thruststruct', r * 0.80, r * 0.92, S1_D * 0.13, S1_D * 0.21,
             M['soot'], seg=32, parent=g)

    # ---- four stowed landing legs, lying along the body as dark strakes. They
    # are there for the whole ascent and are half the booster's aft silhouette.
    # These are the FAIRINGS, not the legs — the legs themselves are the
    # deployables below and swing out of these bays.
    for i in range(4):
        a = i / 4 * TAU + 0.78
        holder = empty(f'legbay{i}', (0, 0, 0), g)
        holder.rotation_euler = (0, 0, a)
        bay_l = S1_D * 1.15
        fair = cyl(f'legfair{i}', S1_D * 0.075, S1_D * 0.075,
                   S1_D * 0.14, S1_D * 0.14 + bay_l, M['black'], seg=10,
                   parent=holder, t0=-pi / 2, t1=pi / 2)
        fair.location = (r * 0.985, 0, 0)
        tip = revolve(f'legtip{i}', [(S1_D * 0.075, 0), (S1_D * 0.050, S1_D * 0.14),
                                     (0, S1_D * 0.20)], M['black'], seg=10, parent=holder)
        tip.location = (r * 0.985, 0, S1_D * 0.14 + bay_l)
        finish(tip, 0.012, 2, 45)

    # ---- the legs themselves, hinged at the base of each bay.
    for i in range(4):
        a = i / 4 * TAU + 0.78
        h = empty(f'leg_f9s1_{i}', (cos(a) * r * 0.92, sin(a) * r * 0.92, S1_L * 0.055), g)
        h.rotation_euler = (0, 0, a)
        landing_leg(f'f9leg{i}', S1_D * 0.82, S1_D * 0.10, M['dirty'], M['alu'], parent=h)

    # ---- interstage: BLACK composite, and the one place the vehicle changes
    # colour along its length. The grid fins hinge off the top of it.
    isg = cyl('interstage', r, r, S1_L, S1_L + S1_IS, M['black'], seg=56, parent=g)
    finish(isg, 0.02, 2, 40)
    band = torus_z('sepband', r * 1.005, S1_D * 0.006, S1_L + S1_IS, M['black'],
                   seg=48, minor=6, parent=g)
    smooth(band, 30)
    # Pusher pistons, visible at the separation plane.
    for i in range(2):
        a = i * pi + 0.4
        box(f'pusher{i}', (0.22, 0.22, 0.5),
            (cos(a) * r * 0.9, sin(a) * r * 0.9, S1_L + S1_IS - 0.3),
            M['dirty'], rot=(0, 0, a), parent=g)

    # ---- four grid fins. An actual waffle: they are titanium, they glow on
    # entry, and they are the single most recognisable thing on the booster.
    fin_z = S1_L + S1_IS * 0.72
    for i in range(4):
        a = i / 4 * TAU + 0.4
        h = empty(f'fin_f9s1_{i}', (cos(a) * r, sin(a) * r, fin_z), g)
        h.rotation_euler = (0, 0, a)
        gf = grid_fin(f'gf{i}', S1_D * 0.42, M['hot'], parent=h)
        gf.location = (S1_D * 0.22, 0, 0)
        strut(f'finhinge{i}', (0, 0, 0), (S1_D * 0.16, 0, 0), 0.11, M['hot'],
              seg=8, parent=h)

    # Cold-gas nitrogen thrusters at the top: without attitude control that does
    # not need the main engine, the booster cannot point itself for the flip.
    rcs_ring('rcs_s1', S1_D, S1_L + S1_IS * 0.30, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# ---------------------------------------------------------------------------
# STAGE 2
# ---------------------------------------------------------------------------
def build_s2(M, root):
    g = stage('f9s2', root)
    r = S2_D / 2
    body = tank('s2_body', S2_L, S2_D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=56, parent=g)
    finish(body, 0.02, 2, 40)
    j = torus_z('s2_joint', r * 1.008, S2_D * 0.008, S2_L * 0.52, M['dirty'],
                seg=56, minor=6, parent=g)
    smooth(j, 30)
    ray = box('s2_raceway', (S2_D * 0.09, S2_D * 0.06, S2_L * 0.86),
              (0, -r * 1.02, S2_L * 0.48), M['dirty'], parent=g)
    finish(ray, 0.012, 2, 40)

    # ---- MVac. A 3.3 m niobium extension on a 0.92 m Merlin: the nozzle is
    # most of the engine and it glows cherry red in flight, which is why the
    # skirt is a different material from the bell it hangs off.
    piv = empty('gimbal_f9s2_0', (0, 0, -0.02), g)
    b = bell('mvac', 3.30, M['nozzle'], ratio=165, seg=32, parent=piv)
    finish(b, 0.010, 2, 50)
    ext = cyl('mvac_ext', 1.30, 1.65, -4.0, -2.2, M['hot'], seg=32, parent=piv)
    smooth(ext, 30)
    # Cold-gas thrusters and the aft bulkhead skirt.
    sk = cyl('s2_skirt', r, r * 0.62, 0.0, S2_L * 0.06, M['dirty'], seg=40, parent=g)
    finish(sk, 0.015, 2, 45)
    rcs_ring('rcs_s2', S2_D, S2_L * 0.90, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# ---------------------------------------------------------------------------
# FAIRING
# ---------------------------------------------------------------------------
def build_fairing(M, root):
    g = stage('f9fair', root)
    r = FR_D / 2
    # Two halves that hinge apart and tumble — the classic separation. The
    # profile is a cylinder for the first 55% and an ogival cap above it.
    prof = []
    for i in range(17):
        u = i / 16
        if u < 0.55:
            rr = r
        else:
            t = (u - 0.55) / 0.45
            rr = r * (max(1 - t * t, 0.0) ** 0.5)
        prof.append((max(rr, 0.02), u * FR_L))
    for k, sgn in enumerate((1, -1)):
        h = empty(f'half_f9fair_{k}', (0, 0, 0), g)
        t0 = (-pi / 2) if sgn > 0 else (pi / 2)
        sh = lathe(f'fairhalf{k}', prof, M['white'], seg=28, t0=t0, t1=t0 + pi, parent=h)
        smooth(sh, 25)
        # The longeron down the split line. A fairing that separates has a real
        # joint, and the joint is the only vertical line on 13 m of white.
        for s2 in (0, 1):
            ang = t0 + s2 * pi
            box(f'fairlong{k}{s2}', (0.10, 0.16, FR_L * 0.54),
                (cos(ang) * r * 0.99, sin(ang) * r * 0.99, FR_L * 0.27),
                M['dirty'], rot=(0, 0, ang), parent=h)
        # Acoustic blanket bands, which is what stops it reading as a plastic cone.
        for b_ in range(3):
            zz = FR_L * (0.12 + b_ * 0.16)
            lathe(f'fairband{k}{b_}', [(r * 1.004, zz), (r * 1.004, zz + FR_L * 0.02)],
                  M['dirty'], seg=24, t0=t0, t1=t0 + pi, parent=h)
    return g


# ---------------------------------------------------------------------------
# PAYLOAD — rides INSIDE the fairing, which is why vehicles.js mounts it at 61 m
# rather than stacking it on the shroud's nose.
# ---------------------------------------------------------------------------
def build_payload(M, root):
    g = stage('f9pl', root)
    bus = box('satbus', (2.4, 2.4, 3.0), (0, 0, 1.5), M['gold'], parent=g)
    finish(bus, 0.03, 2, 40)
    for i in (0, 1, 2):
        box(f'satseam{i}', (2.44, 2.44, 0.04), (0, 0, 0.6 + i * 0.9),
            M['dirty'], parent=g)
    # The payload adapter it actually bolts to.
    ad = cyl('padapter', 0.94, 0.66, 0.0, 0.55, M['alu'], seg=28, parent=g)
    finish(ad, 0.015, 2, 45)

    # Two deployable wings. `array_*` is what update() holds FOLDED until the
    # flight state asks — which is right for a solar array and wrong for
    # anything structural, so only these go in it.
    for k, sgn in enumerate((1, -1)):
        arm = empty(f'array_f9pl_{k}', (sgn * 1.2, 0, 1.6), g)
        strut(f'satyoke{k}', (0, 0, 0), (sgn * 0.4, 0, 0), 0.05, M['alu'],
              seg=8, parent=arm)
        pan = solar_array(f'satpanel{k}', 7.5, 2.0, M['solar'], M['alu'], parent=arm)
        pan.location = (sgn * 4.0, 0, 0)

    d = dish('satdish', 1.1, M['white'], seg=28, parent=g)
    d.location = (0, 0, 3.1)
    finish(d, 0.012, 2, 40)
    strut('satfeed', (0, 0, 3.2), (0, 0, 3.7), 0.04, M['dirty'], seg=8, parent=g)
    return g


def build_falcon9(M):
    root = empty('Falcon9', (0, 0, 0))
    build_s1(M, root)
    build_s2(M, root)
    build_fairing(M, root)
    build_payload(M, root)


build('falcon9', build_falcon9)
