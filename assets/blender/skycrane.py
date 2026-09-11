# ---------------------------------------------------------------------------
# MARS EDL — AEROSHELL, SKY CRANE, CURIOSITY.
# ---------------------------------------------------------------------------
# Three stages and four separations in seven minutes. Each one is a different
# machine and none of them looks like a rocket:
#
#   shell  a 70 degree sphere-cone that arrives at 5.8 km/s
#   desc   an eight-engine deck that flies, then lowers the rover on cables
#   rover  a rocker-bogie chassis whose SIX WHEELS ARE THE LANDING GEAR
#
# The heat shield's sense is the one thing here worth being pedantic about, and
# lib.sphere_cone now fixes it rather than trusting a caller's rotation: apex
# lowest, shoulder at the joint plane. Blunt-forward is not a detail of the
# drawing, it is the entire reason the vehicle survives entry.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin, tan
from lib import (revolve, cyl, lathe, box, torus_z, dish, disc, empty, finish,
                 smooth, strut, bell, ball, sphere_cone, loft, TAU)
from common import build, stage


# ---------------------------------------------------------------------------
# AEROSHELL
# ---------------------------------------------------------------------------
def build_shell(M, root):
    g = stage('shell', root)
    D = 4.5
    nose_r = 1.125
    joint = D * 0.30                        # the plane the two halves split on

    # ---- heat shield, apex DOWN into the flow, shoulder on the joint plane.
    hs = sphere_cone('heatshield', D, nose_r, 70, M['ablator'], seg=56, parent=g)
    hs.location = (0, 0, joint)
    finish(hs, 0.02, 2, 45)
    # PICA tiles are laid as a gore pattern on the real article, and the gores
    # are the only thing that gives an otherwise featureless brown dish scale.
    # The long axis is LOCAL X so that the azimuthal rotation about Z lays it
    # radially; written along Y it came out tangential, i.e. a chord across the
    # dish rather than a gore. And the flank of a 70 degree sphere-cone is not
    # level, so a strip at a constant z crosses the surface — floating near the
    # centre and buried further out. Blender's XYZ order applies the pitch
    # before the azimuth, which is exactly what puts the strip on the flank.
    flank = pi / 2 - 70 * pi / 180
    for i in range(16):
        a = i / 16 * TAU
        r_gore = D * 0.24
        gore = box(f'gore{i}', (D * 0.46, 0.035, 0.03),
                   (cos(a) * r_gore, sin(a) * r_gore,
                    joint - (D / 2 - r_gore) * tan(flank)),
                   M['dirty'], rot=(0, -flank, a), parent=g)

    # ---- backshell: a shallower cone closing the top, in white blanket.
    bs = cyl('backshell', D / 2, D * 0.19, joint, joint + D * 0.36, M['white'],
             seg=56, parent=g)
    finish(bs, 0.02, 2, 45)
    ring = torus_z('joint', D / 2 * 1.005, D * 0.012, joint, M['dirty'],
                   seg=56, minor=8, parent=g)
    smooth(ring, 30)

    # ---- parachute cone and its cover. The chute is 21.5 m across and opens at
    # Mach 1.7 — it is the largest supersonic parachute ever flown, and this
    # small can is all of it that is visible until it is not.
    pc = cyl('chutecan', D * 0.19, D * 0.155, joint + D * 0.36,
             joint + D * 0.46, M['white'], seg=32, parent=g)
    finish(pc, 0.015, 2, 45)
    lid = revolve('chutelid', [(D * 0.155, joint + D * 0.46),
                               (D * 0.150, joint + D * 0.50),
                               (D * 0.115, joint + D * 0.54),
                               (0, joint + D * 0.56)], M['dirty'], seg=32, parent=g)
    smooth(lid, 30)

    # ---- cruise-stage RCS quads, and the tungsten balance masses. The offset
    # centre of mass those masses create is what gives this capsule its L/D of
    # 0.24 — an entry capsule with no lift cannot steer, and MSL's landing
    # ellipse was 20 km long instead of 150 because this one can.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        q = box(f'rcs{i}', (D * 0.07, D * 0.07, D * 0.05),
                (cos(a) * D * 0.34, sin(a) * D * 0.34, joint + D * 0.22),
                M['dirty'], rot=(0, 0, a), parent=g)
        finish(q, 0.012, 2, 40)
        for k in (-1, 1):
            n = revolve(f'rcs{i}_n{k}', [(0, 0), (D * 0.016, 0), (D * 0.008, D * 0.03)],
                        M['nozzle'], seg=8, parent=g)
            n.location = (cos(a) * D * 0.36, sin(a) * D * 0.36,
                          joint + D * 0.22 + k * D * 0.035)
            n.rotation_euler = (0, 0, 0) if k > 0 else (pi, 0, 0)
    # The two ejectable balance masses, on the flank where they actually ride.
    for sgn in (-1, 1):
        bm = ball(f'ballast{sgn}', D * 0.055,
                  (sgn * D * 0.30, 0, joint + D * 0.10), M['steel'],
                  seg=14, rings=10, parent=g)
        smooth(bm, 30)
    return g


# ---------------------------------------------------------------------------
# DESCENT STAGE — the sky crane itself
# ---------------------------------------------------------------------------
def build_desc(M, root):
    g = stage('desc', root)
    D = 3.2
    deck_z = 1.05

    # ---- octagonal deck, ribbed underneath the way a real truss deck is.
    deck = revolve('deck', [(0, deck_z - 0.21), (D / 2 * 0.94, deck_z - 0.21),
                            (D / 2, deck_z + 0.21), (0, deck_z + 0.21)],
                   M['alu'], seg=8, parent=g)
    deck.rotation_euler = (0, 0, pi / 8)
    finish(deck, 0.02, 2, 40)
    for i in range(8):
        a = i / 8 * TAU
        box(f'rib{i}', (D * 0.44, 0.09, 0.10),
            (cos(a) * D * 0.24, sin(a) * D * 0.24, deck_z - 0.24),
            M['dirty'], rot=(0, 0, a), parent=g)

    # ---- four spherical hydrazine tanks on top. 390 kg of propellant, and
    # most of the stage's dry volume is the pressure vessels that hold it.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        t = ball(f'tank{i}', 0.42, (cos(a) * D * 0.26, sin(a) * D * 0.26, deck_z + 0.52),
                 M['gold'], seg=20, rings=12, parent=g)
        smooth(t, 30)
    av = box('avionics', (0.62, 0.52, 0.34), (0, 0, deck_z + 0.42), M['dirty'], parent=g)
    finish(av, 0.015, 2, 40)
    # The descent-stage antenna, and the radar altimeter that flies the landing.
    d = dish('tlga', 0.28, M['white'], seg=20, parent=g)
    d.location = (0, 0, deck_z + 0.62)
    for i in range(6):
        a = i / 6 * TAU
        box(f'radar{i}', (0.16, 0.16, 0.06),
            (cos(a) * D * 0.30, sin(a) * D * 0.30, deck_z - 0.26),
            M['black'], rot=(0, 0, a), parent=g)

    # ---- eight MLEs in four canted pairs. THE CANT IS THE ARCHITECTURE: eight
    # plumes pointed straight down at a rover hanging seven metres below would
    # blast it, and would dig the crater Viking and Phoenix both had to be flown
    # around. It is the reason the sky crane exists at all.
    #
    # The cant lives on an OUTER mount and the driven pivot is inside it, at
    # identity — update() assigns Euler angles to whatever is in parts.gimbals,
    # and assigning wipes any orientation set at build time. Without the split
    # all eight engines snap upright on the first frame.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        cant = empty(f'cant{i}', (cos(a) * D * 0.44, sin(a) * D * 0.44, deck_z - 0.20), g)
        cant.rotation_euler = (0.26, 0, a)
        piv = empty(f'gimbal_desc_{i}', (0, 0, 0), cant)
        for dx in (-0.22, 0.22):
            b = bell(f'mle{i}_{dx}', 0.28, M['nozzle'], ratio=40, seg=20, parent=piv)
            b.location = (dx, 0, 0)
            b.scale = (1.15, 1.15, 1.15)
            finish(b, 0.006, 2, 50)
        # The thrust block each pair is bolted to.
        box(f'block{i}', (0.62, 0.26, 0.18), (0, 0, 0.10), M['alu'], parent=cant)

    # ---- the bridle: three cables and the descent-rate limiter they spool
    # from. This is the part that makes it a crane rather than a lander.
    for i in range(3):
        a = i / 3 * TAU
        c = cyl(f'cable{i}', 0.018, 0.018, -1.5, 0, M['dirty'], seg=5, parent=g)
        c.location = (cos(a) * D * 0.20, sin(a) * D * 0.20, deck_z - 0.85)
        c.rotation_euler = (0.16, 0, a)
    spool = cyl('spool', 0.20, 0.20, deck_z - 0.34, deck_z - 0.20, M['dirty'],
                seg=16, parent=g)
    finish(spool, 0.01, 2, 45)
    return g


# ---------------------------------------------------------------------------
# CURIOSITY
# ---------------------------------------------------------------------------
def build_rover(M, root):
    g = stage('rover', root)
    wr = 0.2625                                # 0.525 m wheels
    z0 = wr
    body_z = z0 + 0.62

    # ---- warm electronics box: 3.0 x 2.7 x 0.8 m, so a SLAB. loft stacks its
    # sections along +Z, and w/h are half-extents — writing the long axis into
    # the section list and rotating it upright is what made an earlier pass a
    # 2.7 m tall blob instead of a chassis the wheels hang off.
    body = loft('web', [
        {'z': body_z - 0.34, 'w': 1.16, 'h': 0.95, 'n': 3.2},
        {'z': body_z - 0.26, 'w': 1.34, 'h': 1.12, 'n': 3.8},
        {'z': body_z + 0.26, 'w': 1.34, 'h': 1.12, 'n': 3.8},
        {'z': body_z + 0.34, 'w': 1.18, 'h': 0.98, 'n': 3.2},
    ], M['alu'], seg=28, parent=g)
    finish(body, 0.02, 2, 40)

    # ---- RTG at the back, canted up, with its cooling fins. 110 W electrical
    # from 2 kW of plutonium heat, and the one part of this rover that is
    # visibly hot: the fins are there to throw away the other 1 890 W.
    rtg = cyl('rtg', 0.27, 0.27, -0.31, 0.31, M['black'], seg=16, parent=g)
    rtg.location = (-1.42, 0, body_z + 0.34)
    rtg.rotation_euler = (0, pi / 2 - 0.30, 0)
    finish(rtg, 0.012, 2, 45)
    fins = empty('rtgfins', (-1.42, 0, body_z + 0.34), g)
    fins.rotation_euler = (0, -0.30, 0)
    for i in range(8):
        a = i / 8 * TAU
        box(f'fin{i}', (0.022, 0.22, 0.56),
            (0, sin(a) * 0.26, cos(a) * 0.26), M['dirty'], rot=(a, 0, 0), parent=fins)

    # ---- remote sensing mast. The camera head is 2 m up because that is
    # roughly eye height: the images are meant to look like standing there.
    mast = cyl('mast', 0.055, 0.07, 0, 1.15, M['dirty'], seg=10, parent=g)
    mast.location = (0.72, -0.30, body_z + 0.34)
    head = box('camhead', (0.56, 0.20, 0.20), (0.72, -0.30, body_z + 1.55),
               M['dirty'], parent=g)
    finish(head, 0.012, 2, 40)
    for dx in (-0.20, 0.20):
        eye = cyl(f'eye{dx}', 0.055, 0.055, 0, 0.08, M['glass'], seg=12, parent=g)
        eye.location = (0.72 + dx, -0.41, body_z + 1.55)
        eye.rotation_euler = (pi / 2, 0, 0)
    # ChemCam, on top of the head: the laser that vaporises rock at 7 m.
    cc = cyl('chemcam', 0.12, 0.12, 0, 0.16, M['dirty'], seg=12, parent=g)
    cc.location = (0.72, -0.30, body_z + 1.68)

    # ---- high-gain antenna and the stowed arm.
    hga = box('hga', (0.30, 0.05, 0.30), (-0.55, 0.55, body_z + 0.55),
              M['dirty'], rot=(0.5, 0, -0.6), parent=g)
    finish(hga, 0.01, 2, 40)
    arm = cyl('arm', 0.07, 0.07, -0.52, 0.52, M['alu'], seg=10, parent=g)
    arm.location = (1.18, 0, body_z - 0.18)
    arm.rotation_euler = (0, 1.15, 0)
    turret = ball('turret', 0.16, (1.55, 0, body_z - 0.52), M['dirty'],
                  seg=14, rings=10, parent=g)

    # ---- rocker-bogie. THE LINKAGE IS THE VEHICLE'S SIGNATURE: six driven
    # wheels on a passive linkage with NO SPRINGS anywhere in it, which is what
    # keeps all six loaded over a rock half a wheel high. A box with six discs
    # stuck to it has none of that.
    for sz in (1, -1):
        side = empty(f'side{sz}', (0, sz * 0.72, 0), g)
        rk = cyl(f'rocker{sz}', 0.045, 0.045, -0.775, 0.775, M['dirty'], seg=8, parent=side)
        rk.location = (0.20, 0, body_z - 0.16)
        rk.rotation_euler = (0, pi / 2 - 0.30, 0)
        bg = cyl(f'bogie{sz}', 0.04, 0.04, -0.475, 0.475, M['dirty'], seg=8, parent=side)
        bg.location = (-0.75, 0, z0 + 0.30)
        bg.rotation_euler = (0, pi / 2 + 0.22, 0)
        for wi, x in enumerate((1.05, -0.30, -1.18)):
            lg = cyl(f'wl{sz}{wi}', 0.035, 0.035, -0.26, 0.26, M['dirty'], seg=8, parent=side)
            lg.location = (x, 0, z0 + 0.26)
            # Wheel: a drum with grousers, because the cleats are what you see —
            # and on Curiosity they are also what wore through.
            w = revolve(f'wheel{sz}{wi}', [(0, -0.20), (wr, -0.20), (wr, 0.20), (0, 0.20)],
                        M['dirty'], seg=20, parent=side)
            w.location = (x, 0, z0)
            w.rotation_euler = (pi / 2, 0, 0)
            smooth(w, 30)
            for k in range(12):
                a = k / 12 * TAU
                box(f'cl{sz}{wi}{k}', (0.022, 0.38, 0.05),
                    (x + cos(a) * wr * 0.99, 0, z0 + sin(a) * wr * 0.99),
                    M['alu'], rot=(0, -a, 0), parent=side)
    return g


def build_skycrane(M):
    root = empty('MSL', (0, 0, 0))
    build_shell(M, root)
    build_desc(M, root)
    build_rover(M, root)


build('skycrane', build_skycrane)
