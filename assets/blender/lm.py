# ---------------------------------------------------------------------------
# APOLLO LUNAR MODULE — the only crewed vehicle ever built that could not fly
# in an atmosphere at all, and it shows in every line of it.
# ---------------------------------------------------------------------------
# Two stages. The descent stage is an octagonal box wrapped in foil that lands;
# the ascent stage uses it as a launch pad and leaves it there. Nothing on
# either is streamlined, faired, or symmetric, because nothing had to be — the
# design freedom of never meeting air is the whole reason it looks like this.
#
# THREE THINGS HERE ARE FIXES RATHER THAN A PORT, and all three were visible.
#
#   · THE GEAR STANDS THE VEHICLE UP. Both builds hung the legs off a box whose
#     underside was the origin, so the footpads ended a metre and a half BELOW
#     the ground the LM was standing on and the engine bell was buried in it.
#     z = 0 here is the footpad bearing plane, GEAR is how far the descent stage
#     sits above it, and the ascent stage carries the same offset internally so
#     that buildCraft's stacking still lands it on the descent stage's roof.
#
#   · THE LEGS WENT THE WRONG WAY, and are no longer a deployable at all. A pad
#     placed separately on +X while the strut it belongs to was canted the other
#     way put the two on opposite sides of the vehicle, which is the
#     "disconnected" look; the pad is part of the leg now, and the cant is
#     derived from where the pad has to land. And the gear is built DEPLOYED and
#     left there: the LM's legs came out in lunar orbit, days before the
#     descent, where every other lander in the set extends its own on the way
#     down — so these are named `gear_` rather than `leg_` and update() does not
#     collect them. The names are the interface; opting out of it is done by
#     not matching, not by hoping.
#
#   · THE LADDER IS ON THE LEG. It was a pair of rails running out into space on
#     a diagonal from a point in mid-air. On the real vehicle it is bolted to
#     the forward primary strut and slants with it, which is why every
#     photograph of it is at an angle.
#
# The engine pivots are a port of an earlier fix: the procedural build hangs
# both bells straight off the stage group with no pivot, so `parts.gimbals`
# comes back EMPTY and the LM has always burned with no visible exhaust.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import math
from math import pi, cos, sin, atan2
from lib import (revolve, cyl, lathe, box, torus_z, dish, disc, empty, group, finish,
                 smooth, strut, bell, ball, landing_leg, TAU)
from common import build, stage

DES_L, DES_D = 3.05, 4.27
ASC_L, ASC_D = 3.76, 4.29

# ---------------------------------------------------------------------------
# THE STANCE. A landed LM stands about 1.5 m clear of the surface on a gear
# 9.4 m across the footpads, and those two numbers together are what set the
# leg: everything below follows from them rather than being dialled in.
# ---------------------------------------------------------------------------
GEAR = 1.52                         # descent stage underside above the pads
PAD_R = 4.30                        # footpad centre radius — 9.4 m span
HINGE_R = DES_D / 2 * 0.96          # primary strut root, on the top outrigger
HINGE_Z = GEAR + DES_L * 0.90
LEG_LEN = math.hypot(PAD_R - HINGE_R, HINGE_Z)
LEG_CANT = -atan2(PAD_R - HINGE_R, HINGE_Z)            # deployed, and stays
OCT = pi / 8                        # so a flat face is centred on +X


# ---------------------------------------------------------------------------
# DESCENT STAGE
# ---------------------------------------------------------------------------
def build_descent(M, root):
    g = stage('des', root)
    r = DES_D / 2
    z0, z1 = GEAR, GEAR + DES_L

    # ---- the octagonal box. Its whole character is that it is a box wrapped in
    # foil: eight flat faces, cut from the cruciform of four propellant tanks
    # and four equipment quadrants, and no attempt at anything else. Turned an
    # eighth of a face so a FLAT is centred on +X, which is where the ladder,
    # the porch and the forward leg all are.
    body = cyl('box', r, r, z0, z1, M['gold'], seg=8, parent=g, t0=OCT, t1=TAU + OCT)
    finish(body, 0.03, 2, 40)
    # Top and bottom decks, so the box is closed rather than a foil tube. A
    # revolve fans properly from the axis where a lathe would leave a ring of
    # coincident vertices; it starts its first vertex at angle zero, so the
    # whole flat plate is simply turned to line up with the faces above it.
    for z in (z0, z1):
        d = revolve(f'deck{z:.0f}', [(0, z), (r * 0.999, z)], M['gold'], seg=8, parent=g)
        d.rotation_euler = (0, 0, OCT)
        smooth(d, 20)

    # Quadrant panels in black MLI on the four DIAGONAL faces — the cut corners
    # between the tank bays. They are what breaks the shape up; an all-gold
    # octagon reads as a lump.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        p = box(f'quad{i}', (DES_D * 0.34, 0.07, DES_L * 0.82),
                (cos(a) * r * 0.95, sin(a) * r * 0.95, (z0 + z1) / 2),
                M['black'], rot=(0, 0, a), parent=g)
        finish(p, 0.012, 2, 40)
    # Frames at the deck lines: the box is a truss with foil over it, and the
    # frames are where the foil is tied down.
    for z in (z0 + DES_L * 0.04, z1 - DES_L * 0.10):
        fr = lathe(f'frame{z:.2f}', [(r * 1.012, z), (r * 1.012, z + DES_L * 0.06)],
                   M['alu'], seg=8, parent=g, t0=OCT, t1=TAU + OCT)
        smooth(fr, 30)

    # ---- the DPS. A deeply throttleable engine with a 47.5:1 bell, and the
    # only one on Apollo that could be throttled at all — the forbidden band
    # between 60% and 92.5% is in ENGINES because sustained running there ate
    # the throttle valve. The bell is foreshortened so its lip sits a hand's
    # breadth above the surface, which is where it really is: Apollo 15 landed
    # in a crater and crushed it.
    piv = empty('gimbal_des_0', (0, 0, z0), g)
    b = bell('dps', 1.52, M['nozzle'], ratio=47.5, chamber=True, seg=36, parent=piv)
    b.scale = (1.0, 1.0, 0.70)
    finish(b, 0.010, 2, 50)
    # The engine bay skirt it hangs out of, and the blast shield around it.
    sk = cyl('dps_skirt', 0.60, 1.05, z0, z0 + DES_L * 0.20, M['dirty'], seg=24, parent=g)
    finish(sk, 0.015, 2, 45)
    bs = lathe('dps_shield', [(1.04, z0 + 0.015), (r * 0.93, z0 + 0.015)], M['soot'],
               seg=32, parent=g)
    smooth(bs, 25)

    # ---- four legs. Primary strut from the TOP outrigger, which is where it
    # really attaches and which is also what lets the ladder run from the porch
    # to the pad in one straight line.
    for i in range(4):
        a = i / 4 * TAU
        h = group(f'gear_des_{i}', g, (cos(a) * HINGE_R, sin(a) * HINGE_R, HINGE_Z), a)
        mnt = h
        leg = landing_leg(f'leg{i}', LEG_LEN, 0.47, M['dirty'], M['alu'],
                          parent=h, probe=(0.0 if i == 0 else 1.7))
        leg.rotation_euler = (0, LEG_CANT, 0)
        # The outrigger the strut roots into. It is structure, not gear, so it
        # goes on the MOUNT and stays put while the leg swings.
        strut(f'out{i}', (r * 0.50, 0, 0), (r * 0.99, 0, 0), 0.09, M['alu'],
              seg=8, parent=mnt)

        # ---- THE LADDER, on the forward leg and slanting with it. Nine rungs
        # from the porch to a bottom rung that stops well short of the pad,
        # which is the gap Armstrong described before he stepped off it.
        if i == 0:
            for sgn in (-1, 1):
                strut(f'lad_rail{sgn}', (0.34, sgn * 0.26, LEG_LEN * 0.03),
                      (0.34, sgn * 0.26, -LEG_LEN * 0.80), 0.035, M['alu'],
                      seg=6, parent=leg)
            for k in range(9):
                u = k / 8
                box(f'rung{k}', (0.09, 0.56, 0.035),
                    (0.34, 0, LEG_LEN * 0.03 - LEG_LEN * 0.83 * u),
                    M['alu'], parent=leg)

    # ---- the egress porch above the forward leg, on the roof line.
    porch = box('porch', (0.86, 1.02, 0.07), (r * 0.86, 0, z1 - 0.03),
                M['alu'], parent=g)
    finish(porch, 0.012, 2, 40)
    for sgn in (-1, 1):
        strut(f'porch_rail{sgn}', (r * 0.52, sgn * 0.46, z1 + 0.02),
              (r * 1.20, sgn * 0.46, z1 + 0.02), 0.035, M['alu'], seg=6, parent=g)

    # ---- MESA: the equipment bay on the quadrant beside the ladder that swung
    # down, carrying the TV camera that broadcast the first step.
    mesa = box('mesa', (0.90, 1.20, 1.05), (cos(pi / 2) * r * 0.82 - 0.10,
                                            sin(pi / 2) * r * 0.82, z0 + DES_L * 0.62),
               M['dirty'], rot=(0, 0, pi / 2), parent=g)
    finish(mesa, 0.015, 2, 40)
    # The landing radar, under the aft face — it is what the guidance actually
    # flew on below high gate.
    lr = box('landing_radar', (0.66, 0.66, 0.14), (-r * 0.58, 0, z0 - 0.06),
             M['black'], parent=g)
    finish(lr, 0.012, 2, 40)
    return g


# ---------------------------------------------------------------------------
# ASCENT STAGE
# ---------------------------------------------------------------------------
def build_ascent(M, root):
    """
    Built with the SAME ground clearance baked in: buildCraft stacks this stage
    at the descent stage's 3.05 m, and the descent stage's roof is GEAR higher
    than that, so the offset lives inside this builder. A stage builder must not
    write to its own group's transform — the parent owns it.
    """
    g = stage('asc', root)
    B = GEAR                              # the descent stage's roof, locally

    # ---- crew cabin: a fat horizontal cylinder with the two triangular
    # windows canted DOWN, because the crew flew standing up looking at the
    # ground they were about to land on. Lumpy on purpose.
    cab = revolve('cabin', [(0, -1.05), (0.92, -1.12), (1.17, -0.92),
                            (1.17, 0.95), (0.92, 1.05), (0, 1.05)],
                  M['gold'], seg=28, parent=g)
    cab.location = (0, -0.30, B + 2.02)
    cab.rotation_euler = (pi / 2, 0, 0)
    finish(cab, 0.025, 2, 40)

    # The equipment bay behind it — the ascent stage is a cabin bolted to a box
    # of tanks, and the join between the two is visible from every angle.
    mid = box('midsection', (2.46, 2.30, 1.86), (0, 0.22, B + 0.98), M['gold'], parent=g)
    finish(mid, 0.03, 2, 40)
    aft = box('aftbay', (1.90, 0.80, 1.30), (0, 1.30, B + 1.30), M['black'], parent=g)
    finish(aft, 0.02, 2, 40)
    # Two spherical propellant tanks either side, in their conical fairings —
    # oxidiser to the right of the crew, fuel to the left, and the asymmetry of
    # that was trimmed out with ballast on the real vehicle.
    for sgn in (-1, 1):
        t = ball(f'tank{sgn}', 0.72, (sgn * 1.34, 0.30, B + 1.02), M['gold'],
                 seg=24, rings=14, parent=g)
        smooth(t, 30)
        fr = revolve(f'tankfair{sgn}', [(0.74, 0), (0.74, 0.30), (0.30, 0.62)],
                     M['alu'], seg=20, parent=g)
        fr.rotation_euler = (0, sgn * pi / 2, 0)
        fr.location = (sgn * 1.34, 0.30, B + 1.02)
        smooth(fr, 30)

    # ---- the front face. Canted, flat, and carrying everything the crew used:
    # two triangular windows looking down at the landing site, the forward
    # hatch between them, and the docking target above.
    for sgn in (-1, 1):
        w = box(f'window{sgn}', (0.62, 0.12, 0.44), (sgn * 0.46, -1.30, B + 2.36),
                M['glass'], rot=(0.42, 0, 0), parent=g)
        finish(w, 0.008, 2, 40)
        surr = box(f'winsurr{sgn}', (0.76, 0.09, 0.58), (sgn * 0.46, -1.26, B + 2.36),
                   M['black'], rot=(0.42, 0, 0), parent=g)
        finish(surr, 0.010, 2, 40)
    # Forward hatch, square, 32 inches: the one they had to go through backwards.
    hatch = box('hatch', (0.85, 0.12, 0.85), (0, -1.22, B + 1.02), M['black'], parent=g)
    finish(hatch, 0.012, 2, 40)
    # Overhead docking window, the tunnel and the drogue above it.
    tun = cyl('tunnel', 0.48, 0.48, B + 2.90, B + 3.22, M['alu'], seg=20, parent=g)
    smooth(tun, 30)
    dr = revolve('drogue', [(0.44, B + 3.22), (0.58, B + 3.62), (0.58, B + 3.70),
                            (0, B + 3.70)], M['dirty'], seg=20, parent=g)
    finish(dr, 0.015, 2, 45)

    # ---- rendezvous radar and the steerable S-band dish, which is how it found
    # the CSM again. Getting home depended on both of these working — and on
    # both of them POINTING somewhere: a dish is an aim, and the rendezvous
    # antenna was aimed back into its own cabin roof by a sign.
    arm = empty('sband', (1.16, 0.52, B + 3.00), g)
    arm.rotation_euler = (0, 0.85, 0)
    strut('sband_boom', (0, 0, -0.55), (0, 0, -0.05), 0.05, M['alu'], seg=8, parent=arm)
    d = dish('sband_dish', 0.62, M['white'], seg=28, parent=arm)
    finish(d, 0.010, 2, 40)
    rr = empty('rrmount', (0, -0.86, B + 3.05), g)
    rr.rotation_euler = (1.15, 0, 0)          # FORWARD and up, not into the hull
    strut('rr_boom', (0, 0, -0.42), (0, 0, -0.02), 0.05, M['alu'], seg=8, parent=rr)
    rd = dish('rr_dish', 0.40, M['dirty'], seg=22, parent=rr)
    finish(rd, 0.008, 2, 40)
    # The two VHF whips, which is how they talked to each other on the surface.
    for sgn in (-1, 1):
        strut(f'vhf{sgn}', (sgn * 0.70, 0.30, B + 2.70), (sgn * 1.30, 0.60, B + 3.40),
              0.022, M['alu'], seg=5, parent=g)

    # ---- the APS. Fixed — no gimbal at all — so the ascent stage steers on
    # RCS alone, which is why there are sixteen of those and why they matter.
    piv = empty('gimbal_asc_0', (0, 0, B + 0.06), g)
    b = bell('aps', 0.86, M['nozzle'], ratio=45, chamber=True, seg=32, parent=piv)
    finish(b, 0.008, 2, 50)

    # ---- four RCS quads on outriggers, canted 45 degrees so each cluster has
    # authority about two axes. They are the ascent stage's only control, and
    # each nozzle has to point somewhere useful: up, down, and one pair fore
    # and aft. A quad whose four nozzles all face the same way is a decoration.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        q = empty(f'rcsq{i}', (cos(a) * 1.78, sin(a) * 1.78, B + 2.48), g)
        q.rotation_euler = (0, 0, a)
        strut(f'rcsq{i}_arm', (-0.62, 0, 0), (0, 0, 0), 0.07, M['alu'], seg=6, parent=q)
        bxx = box(f'rcsq{i}_box', (0.44, 0.44, 0.44), (0, 0, 0), M['dirty'], parent=q)
        finish(bxx, 0.012, 2, 40)
        for k, (loc, rot) in enumerate((((0, 0, 0.32), (0, 0, 0)),
                                        ((0, 0, -0.32), (pi, 0, 0)),
                                        ((0.32, 0, 0), (0, pi / 2, 0)),
                                        ((0, 0.32, 0), (-pi / 2, 0, 0)))):
            n = revolve(f'rcsq{i}_n{k}',
                        [(0, 0), (0.060, 0), (0.034, 0.14)], M['nozzle'],
                        seg=10, parent=q)
            n.location = loc
            n.rotation_euler = rot
    return g


def build_lm(M):
    root = empty('LM', (0, 0, 0))
    build_descent(M, root)
    build_ascent(M, root)


build('lm', build_lm)
