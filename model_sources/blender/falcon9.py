# FALCON 9 BLOCK 5, the Blender build: booster, second stage, fairing, payload. The
# booster separates at ~65 km with a third of its Δv left, and its recovery hardware
# is what distinguishes it: grid fins, four stowed legs as dark strakes, a soot-black
# interstage, the octaweb.
#
# Dimensions from vehicles.gd: booster 41.2 m × 3.66 m, second stage 13.8 m, fairing
# 13.1 m × 5.2 m, payload mounted at 61 m inside the shroud.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, dish, disc, empty,
                 finish, smooth, strut, bell, ball, ogive, grid_fin,
                 landing_leg, solar_array, stripe, rcs_ring, TAU)
from common import build, stage, hinge, ring_radius, vehicle_stages

S = vehicle_stages("falcon9")

S1_L, S1_D = S["f9s1"]["L"], S["f9s1"]["D"]
S1_IS = S["f9s1"]["look"]["interstage"]                        # interstage, black composite
S2_L, S2_D = S["f9s2"]["L"], S["f9s2"]["D"]
FR_L, FR_D = S["f9fair"]["L"], S["f9fair"]["D"]
PL_L, PL_D = S["f9pl"]["L"], S["f9pl"]["D"]


# STAGE 1
def build_s1(M, root):
    g = stage('f9s1', root)
    r = S1_D / 2

    # The barrel. A flat top, because the interstage sits on it: the lathe's
    # dome would curve away underneath and leave a pinched gap at the joint.
    body = tank('s1_body', S1_L, S1_D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=56, parent=g)
    finish(body, 0.02, 2, 40)

    # The soot band on the bottom few metres of a flight-proven booster.
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

    # ---- nine Merlins, eight around one (the centre one lands the stage). The ring
    # clears the centre engine and its neighbours (a naive 1.11 m ring overlaps by 0.07 m).
    spread = max(S1_D * 0.30, ring_radius(S["f9s1"]["count"] - 1, S["f9s1"]["engine"]["exitD"], centre=True))
    def place(i, x, y):
        piv = empty(f'gimbal_f9s1_{i}', (x, y, -0.02), g)
        b = bell(f'merlin{i}', S['f9s1']['engine']['exitD'], M['nozzle'], ratio=16, seg=20, parent=piv)
        finish(b, 0.006, 2, 50)
        return piv
    place(0, 0, 0)
    for i in range(S["f9s1"]["count"] - 1):
        a = i / (S["f9s1"]["count"] - 1) * TAU + 0.39
        place(i + 1, cos(a) * spread, sin(a) * spread)
    # The thrust structure the bells hang out of.
    ts = cyl('thruststruct', r * 0.80, r * 0.92, S1_D * 0.13, S1_D * 0.21,
             M['soot'], seg=32, parent=g)

    # ---- the four leg bay fairings, lying along the body; the legs are the deployables
    # below.
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

    # ---- the legs, hinged at the base of each bay. update() swings a leg +1.15·d about
    # the node's Blender Y, which folds a leg built along −Z inward. To end 60° out
    # (−1.047 about Y), the leg carries −1.047 − 1.15; stowed it lies along the body.
    leg_cant = -1.047 - 1.15
    for i in range(4):
        a = i / 4 * TAU + 0.78
        h, _ = hinge(f'leg_f9s1_{i}',
                     (cos(a) * r * 0.92, sin(a) * r * 0.92, S1_L * 0.055), a, g)
        leg = landing_leg(f'f9leg{i}', S1_D * 0.82, S1_D * 0.10, M['dirty'], M['alu'],
                          parent=h)
        leg.rotation_euler = (0, leg_cant, 0)

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
    # Fins get the same pre-cant: −1.35, so the deploy's +1.35 leaves them square.
    for i in range(4):
        a = i / 4 * TAU + 0.4
        h, _ = hinge(f'fin_f9s1_{i}', (cos(a) * r, sin(a) * r, fin_z), a, g)
        arm = empty(f'gfarm{i}', (0, 0, 0), h)
        arm.rotation_euler = (0, -1.35, 0)
        gf = grid_fin(f'gf{i}', S1_D * 0.42, M['hot'], parent=arm)
        gf.location = (S1_D * 0.22, 0, 0)
        strut(f'finhinge{i}', (0, 0, 0), (S1_D * 0.16, 0, 0), 0.11, M['hot'],
              seg=8, parent=arm)

    # Cold-gas nitrogen thrusters at the top: without attitude control that does
    # not need the main engine, the booster cannot point itself for the flip.
    rcs_ring('rcs_s1', S1_D, S1_L + S1_IS * 0.30, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# STAGE 2
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

    # ---- MVac: a 3.3 m niobium extension on a 0.92 m Merlin, glowing cherry red in
    # flight, so the skirt is its own material.
    piv = empty('gimbal_f9s2_0', (0, 0, -0.02), g)
    b = bell('mvac', S['f9s2']['engine']['exitD'], M['nozzle'], ratio=165, seg=32, parent=piv)
    finish(b, 0.010, 2, 50)
    ext = cyl('mvac_ext', 1.30, 1.65, -4.0, -2.2, M['hot'], seg=32, parent=piv)
    smooth(ext, 30)
    # Cold-gas thrusters and the aft bulkhead skirt.
    sk = cyl('s2_skirt', r, r * 0.62, 0.0, S2_L * 0.06, M['dirty'], seg=40, parent=g)
    finish(sk, 0.015, 2, 45)
    rcs_ring('rcs_s2', S2_D, S2_L * 0.90, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# FAIRING
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


# PAYLOAD — rides INSIDE the fairing, which is why vehicles.gd mounts it at 61 m
# rather than stacking it on the shroud's nose.
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

    # Two deployable wings: `array_*` is held folded until the flight state asks, so only
    # these go in it.
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
