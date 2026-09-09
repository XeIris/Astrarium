# ---------------------------------------------------------------------------
# APOLLO LUNAR MODULE — the only crewed vehicle ever built that could not fly
# in an atmosphere at all, and it shows in every line of it.
# ---------------------------------------------------------------------------
# Two stages. The descent stage is an octagonal box wrapped in foil that lands;
# the ascent stage uses it as a launch pad and leaves it there. Nothing on
# either is streamlined, faired, or symmetric, because nothing had to be — the
# design freedom of never meeting air is the whole reason it looks like this.
#
# One thing here is a fix rather than a port. The procedural build hangs both
# engine bells straight off the stage group with no pivot, so `parts.gimbals`
# comes back EMPTY for this vehicle — and since spaceflight.js hangs the plumes
# on that list, the LM has always burned with no visible exhaust. The authored
# model gives each engine its pivot, at the bell's throat, with the authority
# the engine actually has: 6 degrees for the DPS, zero for the fixed APS.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, box, torus_z, dish, disc, empty, finish,
                 smooth, strut, bell, ball, landing_leg, rcs_ring, TAU)
from common import build, stage

DES_L, DES_D = 3.05, 4.27
ASC_L, ASC_D = 3.76, 4.29


# ---------------------------------------------------------------------------
# DESCENT STAGE
# ---------------------------------------------------------------------------
def build_descent(M, root):
    g = stage('des', root)
    r = DES_D / 2

    # ---- the octagonal box. Its whole character is that it is a box wrapped in
    # foil: eight flat faces, cut from the cruciform of four propellant tanks
    # and four equipment quadrants, and no attempt at anything else.
    body = cyl('box', r, r, 0.0, DES_L, M['gold'], seg=8, parent=g)
    finish(body, 0.03, 2, 40)
    # Top and bottom decks, so the box is closed rather than a foil tube.
    for z in (0.0, DES_L):
        d = disc(f'deck{z:.0f}', r * 0.999, z, M['gold'], seg=8, parent=g)
        smooth(d, 20)

    # Quadrant panels in black MLI on the four faces between the tank bays.
    # They are what breaks the shape up — an all-gold octagon reads as a lump.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        p = box(f'quad{i}', (DES_D * 0.30, 0.06, DES_L * 0.8),
                (cos(a) * r * 0.96, sin(a) * r * 0.96, DES_L / 2),
                M['black'], rot=(0, 0, a), parent=g)
        finish(p, 0.012, 2, 40)
    # Frames at the deck lines: the box is a truss with foil over it, and the
    # frames are where the foil is tied down.
    for z in (DES_L * 0.06, DES_L * 0.94):
        fr = lathe(f'frame{z:.2f}', [(r * 1.01, z), (r * 1.01, z + DES_L * 0.035)],
                   M['alu'], seg=8, parent=g)
        smooth(fr, 30)

    # ---- the DPS. A deeply throttleable engine with a 47.5:1 bell, and the
    # only one on Apollo that could be throttled at all — the forbidden band
    # between 60% and 92.5% is in ENGINES because sustained running there ate
    # the throttle valve.
    piv = empty('gimbal_des_0', (0, 0, 0.0), g)
    b = bell('dps', 1.52, M['nozzle'], ratio=47.5, chamber=True, seg=36, parent=piv)
    b.scale = (1.1, 1.1, 1.1)
    finish(b, 0.010, 2, 50)
    # The engine bay skirt it hangs out of, and the blast shield around it.
    sk = cyl('dps_skirt', 0.62, 0.95, 0.0, DES_L * 0.16, M['dirty'], seg=24, parent=g)
    finish(sk, 0.015, 2, 45)

    # ---- four legs on outriggers. The pre-cant lives on the LEG, not on the
    # hinge: update() assigns rotation.z to whatever is in parts.legs, so the
    # registered node has to be identity about that axis or the first frame
    # snaps it straight.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        h = empty(f'leg_des_{i}', (cos(a) * r * 0.9, sin(a) * r * 0.9, DES_L * 0.30), g)
        h.rotation_euler = (0, 0, a)
        leg = landing_leg(f'leg{i}', 3.2, 0.94, M['dirty'], M['alu'], parent=h)
        leg.rotation_euler = (0, 0.62, 0)             # Three's rotation.z = -0.62
        pad = revolve(f'pad{i}', [(0, -2.6), (0.47, -2.6), (0.42, -2.72), (0, -2.72)],
                      M['dirty'], seg=16, parent=h)
        pad.location = (2.0, 0, 0)
        smooth(pad, 30)
        # The contact probe: a 1.7 m wire hanging under three of the four pads,
        # and the thing that actually ended the landing — "contact light" is a
        # probe touching, not a footpad.
        if i != 0:
            pr = cyl(f'probe{i}', 0.02, 0.02, -3.4, -1.7, M['dirty'], seg=5, parent=h)
            pr.location = (2.1, 0, 0)
        # The outrigger truss that carries the leg back into the box corner.
        strut(f'out{i}', (r * 0.45, 0, 0), (r * 0.92, 0, 0), 0.07, M['alu'],
              seg=6, parent=h)

    # ---- the ladder on the +X leg, and the porch above it. This is the one
    # detail everybody has seen a photograph of.
    lad = empty('ladder', (r * 0.92, 0, DES_L * 0.30), g)
    for sgn in (-1, 1):
        strut(f'lad_rail{sgn}', (0.10, sgn * 0.22, 0.0), (1.55, sgn * 0.22, -2.15),
              0.035, M['alu'], seg=6, parent=lad)
    for k in range(8):
        u = (k + 0.5) / 8
        box(f'rung{k}', (0.10, 0.52, 0.03),
            (0.10 + 1.45 * u, 0, -2.15 * u), M['alu'], parent=lad)
    porch = box('porch', (0.62, 0.92, 0.05), (0.28, 0, DES_L * 0.30 + 0.02),
                M['alu'], parent=g)
    finish(porch, 0.01, 2, 40)

    # ---- MESA: the equipment bay on the -X quadrant that swung down, carrying
    # the TV camera that broadcast the first step.
    mesa = box('mesa', (0.34, 1.10, 0.90), (-r * 0.95, 0, DES_L * 0.50),
               M['dirty'], parent=g)
    finish(mesa, 0.015, 2, 40)
    return g


# ---------------------------------------------------------------------------
# ASCENT STAGE
# ---------------------------------------------------------------------------
def build_ascent(M, root):
    g = stage('asc', root)

    # ---- crew cabin: a fat horizontal cylinder with the two triangular
    # windows canted DOWN, because the crew flew standing up looking at the
    # ground they were about to land on. Lumpy on purpose.
    cab = revolve('cabin', [(0, -1.0), (1.15, -1.0), (1.15, 1.0), (0, 1.0)],
                  M['gold'], seg=24, parent=g)
    cab.location = (0, -0.35, 2.0)
    cab.rotation_euler = (pi / 2, 0, 0)
    finish(cab, 0.025, 2, 40)

    # The equipment bay behind it — the ascent stage is a cabin bolted to a box
    # of tanks, and the join between the two is visible from every angle.
    mid = box('midsection', (2.5, 2.4, 1.9), (0, 0.2, 1.0), M['gold'], parent=g)
    finish(mid, 0.03, 2, 40)
    # Two spherical propellant tanks either side, faired into the midsection.
    for sgn in (-1, 1):
        t = ball(f'tank{sgn}', 0.74, (sgn * 1.30, 0.35, 1.05), M['gold'],
                 seg=20, rings=12, parent=g)
        smooth(t, 30)

    # ---- the windows. Triangular, canted, and the only thing on the vehicle
    # that says there are people in it.
    for sgn in (-1, 1):
        w = box(f'window{sgn}', (0.60, 0.10, 0.42), (sgn * 0.44, -1.32, 2.35),
                M['glass'], rot=(0.45, 0, 0), parent=g)
        finish(w, 0.008, 2, 40)
    # Forward hatch, square, 32 inches: the one they had to go through backwards.
    hatch = box('hatch', (0.85, 0.10, 0.85), (0, -1.24, 1.05), M['black'], parent=g)
    finish(hatch, 0.012, 2, 40)
    # Overhead docking window and the drogue above it.
    dr = cyl('drogue', 0.42, 0.55, 3.2, 3.7, M['dirty'], seg=18, parent=g)
    finish(dr, 0.015, 2, 45)
    tun = cyl('tunnel', 0.48, 0.48, 2.9, 3.2, M['alu'], seg=18, parent=g)
    smooth(tun, 30)

    # ---- rendezvous radar and the steerable S-band dish, which is how it found
    # the CSM again. Getting home depended on both of these working.
    arm = empty('sband', (1.10, 0.60, 3.0), g)
    arm.rotation_euler = (0, 0.9, 0)
    d = dish('sband_dish', 0.66, M['white'], seg=24, parent=arm)
    finish(d, 0.010, 2, 40)
    rr = dish('rr_dish', 0.42, M['dirty'], seg=20, parent=g)
    rr.location = (0, -0.90, 3.15)
    rr.rotation_euler = (-1.1, 0, 0)

    # ---- the APS. Fixed — no gimbal at all — so the ascent stage steers on
    # RCS alone, which is why there are sixteen of those and why they matter.
    piv = empty('gimbal_asc_0', (0, 0, 0.0), g)
    b = bell('aps', 0.86, M['nozzle'], ratio=45, chamber=True, seg=32, parent=piv)
    finish(b, 0.008, 2, 50)

    # ---- four RCS quads on outriggers, canted 45 degrees so each cluster has
    # authority about two axes. They are the ascent stage's only control.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        q = empty(f'rcsq{i}', (cos(a) * 1.70, sin(a) * 1.70, 2.55), g)
        q.rotation_euler = (0, 0, a)
        strut(f'rcsq{i}_arm', (-0.55, 0, 0), (0, 0, 0), 0.06, M['alu'], seg=6, parent=q)
        bxx = box(f'rcsq{i}_box', (0.42, 0.42, 0.42), (0, 0, 0), M['dirty'], parent=q)
        finish(bxx, 0.012, 2, 40)
        for (dx, dy, dz, rot) in ((0.30, 0, 0.10, (0, pi / 2, 0)),
                                  (-0.10, 0, 0.30, (0, 0, 0)),
                                  (-0.10, 0, -0.30, (pi, 0, 0)),
                                  (0, 0.30, 0.10, (-pi / 2, 0, 0))):
            n = revolve(f'rcsq{i}_n{dx}{dy}{dz}',
                        [(0, 0), (0.055, 0), (0.030, 0.13)], M['nozzle'], seg=8, parent=q)
            n.location = (dx, dy, dz)
            n.rotation_euler = rot
    return g


def build_lm(M):
    root = empty('LM', (0, 0, 0))
    build_descent(M, root)
    # buildCraft stacks the ascent stage on the descent stage's 3.05 m, so the
    # ascent stage is built in ITS OWN frame with z = 0 at its base. A stage
    # builder must not write to its own group's transform — the parent owns it.
    build_ascent(M, root)


build('lm', build_lm)
