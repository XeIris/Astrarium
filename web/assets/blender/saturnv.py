# ---------------------------------------------------------------------------
# SATURN V / APOLLO — the expendable superheavy.
# ---------------------------------------------------------------------------
# Four stages in the model's sense: S-IC, S-II, S-IVB and the spacecraft.
# 110 m on the pad, and three things make it read as itself rather than as a
# white cylinder:
#
#   · THE ROLL PATTERN. The black quadrants were painted on so the tracking
#     cameras could measure the vehicle's roll attitude optically during first
#     stage flight. That is why they are asymmetric QUARTER PANELS and not
#     full bands — a full band tells you nothing about roll.
#   · IT NARROWS. 10.06 m, then 6.6 m, then 3.9 m, through two conical
#     interstages and the spacecraft-LM adapter. Drawn at one width from the
#     engines to the escape tower it is the single thing a Saturn V most
#     obviously is not.
#   · THE FINS. 18.8 m across the tips against a 10.06 m tank — the widest part
#     of the vehicle, at the one place anybody ever looks at it.
#
# And the escape tower is MOSTLY AIR. Drawing it solid turns the most
# distinctive nose in spaceflight into a crayon.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, dish, disc, empty,
                 finish, smooth, strut, bell, ball, ogive, lattice, wing,
                 stripe, rcs_ring, TAU)
from common import build, stage, ring_radius

SIC_L, SIC_D = 42.0, 10.06
SII_L = 24.9
SIVB_L, SIVB_D = 17.8, 6.60
CSM_L, CSM_D = 11.0, 3.90


def engines(M, g, key, count, spread, exit_d, ratio, z=-0.02, seg=24):
    """
    One centre plus a ring — the F-1 and J-2 quincunx. The four outboard
    engines gimbal; the centre one is fixed on the real vehicle, and on the
    S-IC it also shuts down early to hold the stack under 4 g.

    `spread` is a FLOOR, not the answer: the ring has to clear the engine on
    the axis and its own neighbours first. At the fraction of the diameter this
    used to take on faith, the S-IC's four outboard F-1s were drawn half a
    metre inside the centre one.
    """
    if count > 1:
        spread = max(spread, ring_radius(count - 1, exit_d, centre=True))
    def place(i, x, y, fixed):
        nm = f'gimbal_{key}_{i}' + ('_fixed' if fixed else '')
        piv = empty(nm, (x, y, z), g)
        b = bell(f'{key}_e{i}', exit_d, M['nozzle'], ratio=ratio, seg=seg, parent=piv)
        finish(b, 0.012, 2, 50)
        return piv
    if count == 1:
        place(0, 0, 0, False)
        return
    place(0, 0, 0, True)
    for i in range(count - 1):
        a = i / (count - 1) * TAU
        place(i + 1, cos(a) * spread, sin(a) * spread, False)


# ---------------------------------------------------------------------------
# S-IC
# ---------------------------------------------------------------------------
def build_sic(M, root):
    g = stage('sic', root)
    L, D = SIC_L, SIC_D
    r = D / 2

    body = tank('sic_body', L, D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=64, parent=g)
    finish(body, 0.03, 2, 40)

    # ---- the roll pattern.
    stripe('sic_aft', D, 0.0, L * 0.075, M['black'], seg=64, parent=g)
    stripe('sic_fwd', D, L * 0.955, L * 0.045, M['black'], seg=64, parent=g)
    for bi, (z, h) in enumerate(((L * 0.075, L * 0.115), (L * 0.545, L * 0.105))):
        for k in (0, 2):
            stripe(f'sic_q{bi}{k}', D, z, h, M['black'], seg=16, parent=g,
                   t0=k * pi / 2, t1=(k + 1) * pi / 2)
    # UNITED STATES down one side, and the flag opposite it.
    stripe('sic_usa', D, L * 0.78, L * 0.20, M['black'], seg=12, parent=g,
           t0=-0.34, t1=0.34, grow=1.006)
    stripe('sic_flag', D, L * 0.80, L * 0.075, M['red'], seg=10, parent=g,
           t0=pi - 0.24, t1=pi + 0.24, grow=1.006)

    # ---- five F-1s. 7.77 MN each and a 3.53 m bell; the four outboard ones
    # gimbal 5.15 degrees and that is the entire control authority of the
    # largest stage ever flown.
    engines(M, g, 'sic', 5, D * 0.30, 3.53, 16, seg=28)
    ts = cyl('sic_thrust', r * 0.80, r * 0.92, D * 0.02, D * 0.13, M['soot'],
             seg=40, parent=g)
    # The heat shield across the base, which is what you actually see between
    # the bells on the pad.
    hs = disc('sic_base', r * 0.94, D * 0.14, M['soot'], seg=48, parent=g)

    # ---- four fins and the four conical fairings ahead of them.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        bay = empty(f'finbay{i}', (0, 0, 0), g)
        bay.rotation_euler = (0, 0, a)
        # A faired cone over the outboard engine's actuators and the retros.
        fair = cyl(f'fair{i}', D * 0.165, D * 0.055, L * 0.042, L * 0.257,
                   M['white'], seg=20, parent=bay)
        fair.location = (r * 0.90, 0, 0)
        finish(fair, 0.02, 2, 45)
        # It is faired INTO the tank, not stood off it: a half-round fillet down
        # the joint stops it reading as a spike taped to the side.
        fil = cyl(f'fillet{i}', D * 0.075, D * 0.075, L * 0.042, L * 0.257,
                  M['white'], seg=12, parent=bay, t0=pi / 2, t1=3 * pi / 2)
        fil.location = (r * 0.99, 0, 0)
        # Fin: a clipped swept delta with a real leading edge, not a slab.
        wing(f'fin{i}', [
            {'x': D * 0.48, 'zLE': L * 0.150, 'chord': L * 0.128, 'thick': 0.09},
            {'x': D * 0.68, 'zLE': L * 0.098, 'chord': L * 0.105, 'thick': 0.10},
            {'x': D * 0.93, 'zLE': L * 0.030, 'chord': L * 0.072, 'thick': 0.12},
        ], M['black'], M['black'], parent=bay)

    # ---- the systems tunnels and the retro-rocket housings.
    for i in range(4):
        a = i / 4 * TAU
        box(f'sic_tun{i}', (D * 0.055, D * 0.09, L * 0.60),
            (cos(a) * r * 1.01, sin(a) * r * 1.01, L * 0.55),
            M['white'], rot=(0, 0, a), parent=g)

    # ---- interstage to the S-II. Cylindrical here (both stages are 10.06 m),
    # so it gets the separation band a real one has.
    isg = cyl('sic_is', r, r, SIC_L, SIC_L + 1.5, M['dirty'], seg=64, parent=g)
    finish(isg, 0.02, 2, 40)
    bd = torus_z('sic_band', r * 1.005, D * 0.006, SIC_L + 1.5, M['black'],
                 seg=48, minor=6, parent=g)
    smooth(bd, 30)
    return g


# ---------------------------------------------------------------------------
# S-II
# ---------------------------------------------------------------------------
def build_sii(M, root):
    g = stage('sii', root)
    L, D = SII_L, SIC_D
    r = D / 2
    body = tank('sii_body', L, D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=64, parent=g)
    finish(body, 0.03, 2, 40)
    # The S-II is the insulated one — spray-on foam over the LH2 tank, which is
    # why it is a slightly different white from the S-IC and has a visible
    # common-bulkhead line rather than an intertank.
    j = torus_z('sii_dome', r * 1.008, D * 0.008, L * 0.28, M['dirty'],
                seg=64, minor=6, parent=g)
    smooth(j, 30)
    for i in range(3):
        a = i / 3 * TAU + 0.3
        box(f'sii_tun{i}', (D * 0.05, D * 0.08, L * 0.86),
            (cos(a) * r * 1.01, sin(a) * r * 1.01, L * 0.50),
            M['white'], rot=(0, 0, a), parent=g)

    engines(M, g, 'sii', 5, D * 0.30, 2.01, 28, seg=24)
    cyl('sii_thrust', r * 0.80, r * 0.92, D * 0.02, D * 0.13, M['soot'],
        seg=40, parent=g)
    disc('sii_base', r * 0.94, D * 0.14, M['soot'], seg=48, parent=g)
    rcs_ring('sii_rcs', D, L * 0.88, M['dirty'], M['nozzle'], 4, parent=g)

    # ---- interstage to the S-IVB: 10.06 m down to 6.6 m. This is the piece
    # that stops the vehicle being one width from end to end.
    isg = cyl('sii_is', r, SIVB_D / 2, L, L + 2.0, M['dirty'], seg=64, parent=g)
    finish(isg, 0.02, 2, 40)
    return g


# ---------------------------------------------------------------------------
# S-IVB
# ---------------------------------------------------------------------------
def build_sivb(M, root):
    g = stage('sivb', root)
    L, D = SIVB_L, SIVB_D
    r = D / 2
    body = tank('sivb_body', L, D, M['white'], dome_top=0.0, dome_bot=0.02,
                seg=56, parent=g)
    finish(body, 0.03, 2, 40)
    stripe('sivb_band', D, L * 0.62, L * 0.10, M['black'], seg=56, parent=g)
    # The aft skirt and the aft interstage flare.
    sk = cyl('sivb_skirt', r * 1.02, r, 0.0, L * 0.14, M['dirty'], seg=56, parent=g)
    finish(sk, 0.02, 2, 45)

    # One J-2, restartable: the only engine on the vehicle that has to light a
    # second time, three hours later, to leave Earth entirely.
    engines(M, g, 'sivb', 1, 0, 2.01, 28, seg=24)

    # The two auxiliary propulsion modules — also what settles the propellant
    # before the restart. They are on opposite sides, and they are the only
    # thing hanging off the S-IVB's skin.
    for sgn in (-1, 1):
        apsm = box(f'aps{sgn}', (0.62, 0.90, 1.60),
                   (sgn * r * 1.06, 0, L * 0.16), M['dirty'], parent=g)
        finish(apsm, 0.015, 2, 40)
        for k in range(3):
            n = revolve(f'apsn{sgn}{k}', [(0, 0), (0.075, 0), (0.04, 0.18)],
                        M['nozzle'], seg=8, parent=g)
            n.location = (sgn * r * 1.14, 0, L * 0.16 + (k - 1) * 0.55)
            n.rotation_euler = (0, sgn * pi / 2, 0)

    # ---- the spacecraft-LM adapter: 6.6 m down to the service module's 3.9 m,
    # with the lunar module folded inside it. Four panels that hinge open after
    # TLI, and the hinge lines are visible on the closed cone.
    sla = cyl('sla', r, CSM_D / 2, L, L + 6.5, M['white'], seg=56, parent=g)
    finish(sla, 0.02, 2, 40)
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        # A hinge line has to follow the cone, so it is a thin wedge of the
        # same lathe rather than a straight box laid over a slope.
        lathe(f'slahinge{i}', [(r * 1.004, L), (CSM_D / 2 * 1.004, L + 6.5)],
              M['dirty'], seg=2, t0=a - 0.02, t1=a + 0.02, parent=g)
    return g


# ---------------------------------------------------------------------------
# CSM + LAUNCH ESCAPE SYSTEM
# ---------------------------------------------------------------------------
def build_csm(M, root):
    g = stage('csm', root)
    sm_d, sm_l = CSM_D, 4.70
    r = sm_d / 2

    # ---- service module: a plain cylinder, and almost all of it is propellant.
    sm = cyl('sm', r, r, 0.0, sm_l, M['alu'], seg=48, parent=g)
    finish(sm, 0.02, 2, 40)
    disc('sm_aft', r * 0.999, 0.0, M['alu'], seg=48, parent=g)
    # Its six radiator/RCS bays read as vertical seams around the drum.
    for i in range(6):
        a = i / 6 * TAU
        box(f'sm_seam{i}', (0.05, 0.14, sm_l * 0.96),
            (cos(a) * r, sin(a) * r, sm_l / 2), M['dirty'], rot=(0, 0, a), parent=g)
    # Four RCS quads, canted, at the top of the drum.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        q = empty(f'sm_rcs{i}', (cos(a) * r, sin(a) * r, sm_l * 0.86), g)
        q.rotation_euler = (0, 0, a)
        box(f'sm_rcsb{i}', (0.30, 0.42, 0.42), (0.06, 0, 0), M['dirty'], parent=q)
        for k in (-1, 1):
            n = revolve(f'sm_rcsn{i}{k}', [(0, 0), (0.05, 0), (0.028, 0.12)],
                        M['nozzle'], seg=8, parent=q)
            n.location = (0.20, 0, k * 0.14)
            n.rotation_euler = (0, pi / 2, 0)

    # The SPS: one engine, no backup, and the only thing that could get them
    # out of lunar orbit. Its bell is nearly as wide as the module.
    piv = empty('gimbal_csm_0', (0, 0, 0.0), g)
    b = bell('sps', 2.24, M['nozzle'], ratio=62, seg=28, parent=piv)
    b.scale = (1.15, 1.15, 1.15)
    finish(b, 0.012, 2, 50)
    # High-gain antenna: four dishes on a boom, folded against the SM at launch.
    hga = empty('hga', (r * 1.15, 0, sm_l * 0.24), g)
    hga.rotation_euler = (0, 1.15, 0)
    for k, (dx, dy) in enumerate(((-0.44, 0), (0.44, 0), (0, -0.44), (0, 0.44))):
        d = dish(f'hga{k}', 0.40, M['white'], seg=18, parent=hga)
        d.location = (dx, dy, 0)

    # ---- command module: the 33 degree cone, apex up, on its heat shield.
    # That angle and the spherical shield under it ARE the re-entry design.
    cm_z, cm_h, cm_r = sm_l, 3.20, 1.955
    cm = cyl('cm', cm_r, cm_r * 0.28, cm_z, cm_z + cm_h, M['alu'], seg=40, parent=g)
    finish(cm, 0.02, 2, 40)
    shield = revolve('cm_shield',
                     [(cm_r * (1 - (i / 10) ** 2) ** 0.5 if i < 10 else 0.0,
                       # Apex DOWN, into the flow. Written with the signs the
                       # other way the rim still lands on cm_z but the apex
                       # rises 0.82 m above it, so the dome bulges up inside a
                       # cone that is 1.59 m wide there — fully enclosed, never
                       # visible, and the module's base left open.
                       cm_z + cm_r * 0.42 * (1 - (i / 10) ** 2) ** 0.5 - cm_r * 0.42)
                      for i in range(11)][::-1],
                     M['ablator'], seg=40, parent=g)
    smooth(shield, 30)
    tun = cyl('cm_tunnel', cm_r * 0.28, cm_r * 0.26, cm_z + cm_h, cm_z + cm_h + 0.42,
              M['alu'], seg=24, parent=g)
    finish(tun, 0.012, 2, 45)
    # The three crew windows and the hatch — the only sign of people aboard.
    for k, a in enumerate((-0.5, 0.0, 0.5)):
        w = box(f'cm_win{k}', (0.42, 0.10, 0.36),
                (sin(a) * cm_r * 0.80, -cos(a) * cm_r * 0.80, cm_z + cm_h * 0.52),
                M['glass'], rot=(0, 0, a), parent=g)

    # ---- launch escape system. Tower, motor, and the canted nozzles that pull
    # the command module off a failing stack fast enough to matter — 10 g in
    # under a second. It is MOSTLY AIR and has to look it.
    tow_z, tow_h = cm_z + cm_h + 0.40, 3.05
    lattice('les_tower', tow_h, cm_r * 1.05, cm_r * 0.62, M['dirty'], parent=g).location = (0, 0, tow_z)
    motor_z, motor_l = tow_z + tow_h, 4.75
    mot = cyl('les_motor', 0.33, 0.33, motor_z, motor_z + motor_l, M['white'],
              seg=24, parent=g)
    finish(mot, 0.015, 2, 45)
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        n = revolve(f'les_n{i}', [(0, 0), (0.17, 0), (0.09, 0.42)],
                    M['nozzle'], seg=12, parent=g)
        n.location = (cos(a) * 0.33, sin(a) * 0.33, motor_z + motor_l * 0.30)
        n.rotation_euler = (sin(a) * 0.45, -cos(a) * 0.45, 0)
    # Ballast nose and the Q-ball that measures angle of attack at the very tip.
    nose = ogive('les_nose', 1.55, 0.66, M['white'], seg=20, parent=g,
                 z0=motor_z + motor_l)
    finish(nose, 0.012, 2, 45)
    return g


def build_saturnv(M):
    root = empty('SaturnV', (0, 0, 0))
    build_sic(M, root)
    build_sii(M, root)
    build_sivb(M, root)
    build_csm(M, root)


build('saturnv', build_saturnv)
