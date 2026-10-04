# SUPER HEAVY / STARSHIP, the Blender build: 71 m of booster under 52 m of ship,
# both 9 m across, 33 Raptors on the pad.
#   · Unpainted 301 stainless in weld rings ~1.83 m apart (the coil width), which
#     gives the bare cylinder its scale.
#   · Thirteen of the booster's engines gimbal and twenty are rigid; the ship has
#     three steering sea-level Raptors and three fixed vacuum ones. Rigid pivots
#     are suffixed `_fixed`.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import math
from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, disc, empty, finish,
                 smooth, strut, bell, ogive, grid_fin, rcs_ring, TAU)
from common import build, stage, hinge, vehicle_stages

S = vehicle_stages("starship")

SH_L, D = S["sh"]["L"], S["sh"]["D"]
SS_L = S["ss"]["L"]
R = D / 2
RING = 1.83                        # weld-ring pitch: the coil width, not a guess

# THE ENGINE PACKING, tested by nearest neighbour over the whole cluster (the
# closest pair is usually on different rings). Radii 0.90 / 2.05 / 3.45 exit
# diameters keep every pair ≥ 1.079 apart, outer edge at 3.95. Twenty 1.30 m bells
# want a 4.16 m ring inside a 4.50 m radius, so the drawn bell shrinks.
K1, K2, K3 = 0.90, 2.05, 3.45          # ring radii, in exit diameters
R_MAX = R * 0.95                       # the outermost bell edge, inside the skirt
RAPTOR_D = min(S["sh"]["engine"]["exitD"], R_MAX / (K3 + 0.5))
RVAC_D = S["ss"]["vacEngine"]["exitD"]                          # vacuum Raptor: nearly twice over
SH_RINGS = ((3, K1 * RAPTOR_D, 0.0, False),
            (10, K2 * RAPTOR_D, pi / 10, False),
            (20, K3 * RAPTOR_D, pi / 20, True))
# The ship's two clusters must miss each other: staggered, or the vacuum bells sit
# on top of the sea-level ones.
SS_SEA_R, SS_VAC_R = 0.95 * RAPTOR_D, 2.45


def weld_rings(name, z0, z1, mat, parent, r=R):
    """
    The horizontal weld seams. On a vehicle this size and this plain they are
    the ONLY thing carrying scale: bare steel with no rings on it reads as a
    smooth prop at any distance, and the eye has nothing to measure against.
    """
    n = int((z1 - z0) / RING)
    for i in range(1, n + 1):
        s = torus_z(f'{name}{i}', r * 1.003, 0.028, z0 + i * RING, mat,
                    seg=64, minor=6, parent=parent)
        smooth(s, 30)


# SUPER HEAVY
def build_sh(M, root):
    g = stage('sh', root)

    body = tank('sh_body', SH_L, D, M['steel'], dome_top=0.0, dome_bot=0.02,
                seg=64, parent=g)
    finish(body, 0.03, 2, 40)
    weld_rings('sh_ring', 0.6, SH_L - 1.0, M['steel'], g)
    # The LOX/CH4 common dome joint, and the downcomer that runs the LOX past
    # the methane tank to the engines.
    j = torus_z('sh_dome', R * 1.010, 0.10, SH_L * 0.66, M['dirty'],
                seg=64, minor=8, parent=g)
    smooth(j, 30)

    # ---- hot-stage ring: the vented adapter the ship lights inside.
    hs = cyl('hotstage', R * 0.99, R * 0.99, SH_L * 0.978, SH_L + 1.2,
             M['hot'], seg=64, parent=g)
    finish(hs, 0.03, 2, 40)
    for i in range(24):
        a = i / 24 * TAU
        box(f'hsvent{i}', (0.22, 0.55, 1.0),
            (cos(a) * R * 0.99, sin(a) * R * 0.99, SH_L + 0.5),
            M['black'], rot=(0, 0, a), parent=g)

    # ---- 33 Raptors (3 + 10 + 20). The inner thirteen gimbal; the outer twenty don't.
    idx = 0
    for count, rr, phase, fixed in SH_RINGS:
        for i in range(count):
            a = i / count * TAU + phase
            nm = f'gimbal_sh_{idx:02d}' + ('_fixed' if fixed else '')
            piv = empty(nm, (cos(a) * rr, sin(a) * rr, -0.02), g)
            b = bell(f'raptor{idx}', RAPTOR_D, M['nozzle'], ratio=34, seg=16, parent=piv)
            finish(b, 0.008, 2, 50)
            idx += 1
    # The thrust puck and the shielding around the outer ring.
    puck = cyl('thrustpuck', R * 0.42, R * 0.30, 0.30, 1.60, M['soot'], seg=32, parent=g)
    sk = cyl('sh_skirt', R, R * 0.98, 0.0, 2.6, M['soot'], seg=64, parent=g)
    finish(sk, 0.02, 2, 45)
    # One cable raceway, as on the real vehicle.
    a = pi / 4
    rc = box('sh_raceway', (0.62, 0.30, SH_L * 0.90),
             (cos(a) * (R + 0.12), sin(a) * (R + 0.12), SH_L * 0.47),
             M['steel'], rot=(0, 0, a), parent=g)
    finish(rc, 0.03, 2, 40)

    # ---- four grid fins on the forward dome. They never fold, but are registered as
    # fins; built at −1.35 so the deploy's +1.35 about Blender Y leaves them square.
    for i in range(4):
        a = i / 4 * TAU + 0.4
        h, _ = hinge(f'fin_sh_{i}', (cos(a) * R, sin(a) * R, SH_L * 0.955), a, g)
        arm = empty(f'shgfarm{i}', (0, 0, 0), h)
        arm.rotation_euler = (0, -1.35, 0)
        gf = grid_fin(f'shgf{i}', D * 0.34, M['hot'], parent=arm)
        gf.location = (D * 0.20, 0, 0)
        strut(f'shfinhinge{i}', (0, 0, 0), (D * 0.14, 0, 0), 0.24, M['hot'],
              seg=10, parent=arm)

    # The catch pins the tower's arms actually take the booster's weight on.
    for sgn in (-1, 1):
        box(f'catchpin{sgn}', (0.9, 0.36, 0.36),
            (sgn * R * 1.06, 0, SH_L * 0.93), M['hot'], parent=g)
    rcs_ring('sh_rcs', D * 1.055, SH_L * 0.905, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# STARSHIP
def nose_r(z, nose_l):
    """The ship's local radius at height z — R on the barrel, and the ogive's
       own curve above it. Anything bolted to the upper hull has to ask: the
       forward flaps sit 12 m up the nose, where the skin has already drawn in
       by two thirds of a metre, and hanging them off R leaves them FLOATING
       clear of the ship with daylight behind the hinge."""
    z0 = SS_L - nose_l
    if z <= z0:
        return R
    t = min(z - z0, nose_l)
    rho = (R * R + nose_l * nose_l) / (2 * R)
    return max(math.sqrt(max(rho * rho - t * t, 0.0)) - rho + R, 0.02)


def build_ss(M, root):
    g = stage('ss', root)
    nose_l = D * 1.55

    body = tank('ss_body', SS_L - nose_l, D, M['steel'], dome_top=0.0,
                dome_bot=0.02, seg=64, parent=g)
    finish(body, 0.03, 2, 40)
    weld_rings('ss_ring', 0.6, SS_L - nose_l - 0.6, M['steel'], g)
    nose = ogive('ss_nose', nose_l, D, M['steel'], seg=64, parent=g, z0=SS_L - nose_l)
    finish(nose, 0.03, 2, 40)

    # ---- heat tiles on the windward half only (belly-first entry at 60° AoA). The belly
    # is Blender +Y (Godot −Z); the flaps' hinge axis must agree.
    tiles = lathe('ss_tiles', [(R * 1.006, SS_L * 0.02), (R * 1.006, SS_L * 0.72)],
                  M['tiles'], seg=40, t0=-0.06, t1=pi + 0.06, parent=g)
    smooth(tiles, 25)
    tnose = lathe('ss_tilenose', [(R * 1.006 * (1 - (u / 12) ** 2 * 0.55),
                                   SS_L * 0.72 + (SS_L * 0.22) * (u / 12))
                                  for u in range(13)],
                  M['tiles'], seg=40, t0=-0.06, t1=pi + 0.06, parent=g)
    smooth(tnose, 25)

    # ---- four flaps (two forward, two aft), moved to shift the centre of pressure in a
    # belly-first fall. Each hinge node rests at identity about the driven axis, which
    # is the node's local Blender −Y; the node is turned a quarter about Z and the flap
    # built along local +Y, so the driven axis is spanwise and the flap feathers.
    for i, (sx, zf, aft) in enumerate(((1, SS_L * 0.80, False), (-1, SS_L * 0.80, False),
                                       (1, SS_L * 0.085, True), (-1, SS_L * 0.085, True))):
        rr = nose_r(zf, nose_l)
        h, _ = hinge(f'flap_ss_{i}', (sx * rr * 0.98, 0, zf), -sx * pi / 2, g)
        span, chord = D * (0.42 if aft else 0.34), D * (0.52 if aft else 0.42)
        f = box(f'ssflap{i}', (0.34, span, chord), (0, span * 0.52, 0),
                M['tiles'], parent=h)
        finish(f, 0.02, 2, 40)
        # The hinge fairing, which is the part that actually failed on the early
        # flights and the part every photograph of a re-entry shows glowing.
        hf = cyl(f'sshinge{i}', 0.40, 0.40, -0.05, span * 0.30, M['hot'],
                 seg=16, parent=h)
        hf.rotation_euler = (-pi / 2, 0, 0)
        finish(hf, 0.015, 2, 45)

    # ---- six Raptors: three gimballing sea-level inside three fixed vacuum (2.4 m
    # bells, no room to swing), staggered 60° so they clear.
    for i in range(3):
        a = i / 3 * TAU + 0.5
        piv = empty(f'gimbal_ss_{i}', (cos(a) * SS_SEA_R, sin(a) * SS_SEA_R, -0.02), g)
        b = bell(f'ssraptor{i}', RAPTOR_D, M['nozzle'], ratio=34, seg=18, parent=piv)
        finish(b, 0.008, 2, 50)
    for i in range(3):
        a = i / 3 * TAU + 0.5 + pi / 3
        piv = empty(f'gimbal_ss_{i + 3}_fixed',
                    (cos(a) * SS_VAC_R, sin(a) * SS_VAC_R, -0.02), g)
        b = bell(f'ssrvac{i}', RVAC_D, M['nozzle'], ratio=90, seg=22, parent=piv)
        finish(b, 0.010, 2, 50)
    sk = cyl('ss_skirt', R, R * 0.99, 0.0, 2.2, M['soot'], seg=64, parent=g)
    finish(sk, 0.02, 2, 45)

    # ---- the payload bay door, on the leeward side opposite the tiles.
    door = lathe('ss_door', [(R * 1.008, SS_L * 0.52), (R * 1.008, SS_L * 0.70)],
                 M['dirty'], seg=18, t0=pi + 0.35, t1=TAU - 0.35, parent=g)
    smooth(door, 25)
    # On the BARREL, where the skin is still 4.5 m: a pod pinned to R part way
    # up a tangent ogive stands off in mid air.
    rcs_ring('ss_rcs', D * 1.055, SS_L * 0.72, M['dirty'], M['nozzle'], 4, parent=g)
    return g


def build_starship(M):
    root = empty('Starship', (0, 0, 0))
    build_sh(M, root)
    build_ss(M, root)


build('starship', build_starship)
