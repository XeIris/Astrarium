# ---------------------------------------------------------------------------
# SUPER HEAVY / STARSHIP — the only vehicle in the set with two landings per
# flight, and the only one made of stainless steel.
# ---------------------------------------------------------------------------
# 71 m of booster under 52 m of ship, both 9 m across, 33 Raptors on the pad.
# Two things drive the whole read:
#
#   · IT IS STEEL, not white paint. 301 stainless, unpainted, in horizontal
#     weld rings about 1.83 m apart — the ring spacing is a real number (the
#     coil width the barrels are rolled from) and it is what gives 123 m of
#     bare cylinder any scale at all.
#   · THE ENGINES ARE NOT ALL THE SAME. Thirteen of the booster's 33 gimbal and
#     twenty are rigid; the ship has three sea-level Raptors that steer and
#     three vacuum Raptors that do not. The model says so — a pivot suffixed
#     `_fixed` is bound with zero authority — because an engine that cannot
#     gimbal must not be drawn gimballing.
# ---------------------------------------------------------------------------
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import math
from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, disc, empty, finish,
                 smooth, strut, bell, ogive, grid_fin, rcs_ring, TAU)
from common import build, stage, hinge

SH_L, D = 71.0, 9.0
SS_L = 52.0
R = D / 2
RING = 1.83                        # weld-ring pitch: the coil width, not a guess

# ---------------------------------------------------------------------------
# THE ENGINE PACKING, which is a real constraint and not a layout choice.
# ---------------------------------------------------------------------------
# Thirty-three bells inside a 9 m skirt is the tightest cluster ever flown, and
# the test it has to pass is not "does each ring space its own engines" — it is
# the NEAREST NEIGHBOUR OVER THE WHOLE CLUSTER. Solving the rings one at a time
# passes every chord and still buries the inner three in the ten around them,
# because the closest pair in a three-ring pattern is usually a pair on
# DIFFERENT rings and no per-ring check ever looks at it.
#
# So the radii are fixed multiples of the exit diameter, chosen once against
# that global minimum: at 0.90 / 2.05 / 3.45 every pair in the cluster — same
# ring or not — is at least 1.079 exit diameters apart, and the outer bell's
# edge lands at 3.95. Scale that to fit inside the skirt and the engine follows:
# the DRAWN bell shrinks until it does. Twenty 1.30 m bells want a 4.16 m ring
# and the booster is 4.50 m in RADIUS, so something has to give, and a bell a
# fifth of a metre narrow is the smaller error — the only one of the two you
# cannot see.
K1, K2, K3 = 0.90, 2.05, 3.45          # ring radii, in exit diameters
R_MAX = R * 0.95                       # the outermost bell edge, inside the skirt
RAPTOR_D = min(1.30, R_MAX / (K3 + 0.5))
RVAC_D = 2.40                          # vacuum Raptor: nearly twice over
SH_RINGS = ((3, K1 * RAPTOR_D, 0.0, False),
            (10, K2 * RAPTOR_D, pi / 10, False),
            (20, K3 * RAPTOR_D, pi / 20, True))
# The ship's two clusters have to miss EACH OTHER, which is the same failure one
# level up: three 1.08 m bells inside three 2.40 m ones clear only if the two
# rings are staggered, and at the same phase the vacuum bells sit straight on
# top of the sea-level ones.
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


# ---------------------------------------------------------------------------
# SUPER HEAVY
# ---------------------------------------------------------------------------
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

    # ---- hot-stage ring: the vented adapter the second stage lights INSIDE.
    # Hot staging is why it exists — the ship's engines fire while still
    # attached, and the exhaust has to go somewhere.
    hs = cyl('hotstage', R * 0.99, R * 0.99, SH_L * 0.978, SH_L + 1.2,
             M['hot'], seg=64, parent=g)
    finish(hs, 0.03, 2, 40)
    for i in range(24):
        a = i / 24 * TAU
        box(f'hsvent{i}', (0.22, 0.55, 1.0),
            (cos(a) * R * 0.99, sin(a) * R * 0.99, SH_L + 0.5),
            M['black'], rot=(0, 0, a), parent=g)

    # ---- 33 Raptors: 3 + 10 + 20, on the radii at the top of this file. The
    # inner thirteen gimbal; the outer twenty are bolted down and steer nothing,
    # which is why the booster's control authority falls away as it throttles
    # the centre engines back.
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
    # ONE cable raceway, not four. It is the only vertical feature on the
    # booster and the thing that makes 71 m of bare cylinder read as engineered
    # — but there is exactly one of it on the real vehicle, and four evenly
    # spaced slabs turn a rocket into a column.
    a = pi / 4
    rc = box('sh_raceway', (0.62, 0.30, SH_L * 0.90),
             (cos(a) * (R + 0.12), sin(a) * (R + 0.12), SH_L * 0.47),
             M['steel'], rot=(0, 0, a), parent=g)
    finish(rc, 0.03, 2, 40)

    # ---- four grid fins, fixed to the forward dome. Unlike the Falcon's these
    # never fold — there is no reason to on a booster that is caught rather than
    # landed — but they are registered as fins so the model and the code agree.
    # The pre-cant is the same derivation as the Falcon's: update() swings a
    # registered fin by +1.35 about the node's Blender Y on deploy, so the fin
    # is built at -1.35 and the deploy hands it back square to the body.
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


# ---------------------------------------------------------------------------
# STARSHIP
# ---------------------------------------------------------------------------
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

    # ---- heat tiles on the WINDWARD HALF ONLY, which is what they are for.
    # The ship re-enters belly-first at 60 degrees angle of attack, so exactly
    # one side of it is a heat shield and the other is bare steel. That split is
    # the vehicle's whole silhouette on the way down.
    #
    # The belly is Blender +Y, i.e. Three -Z. The flaps below hinge about the
    # axis update() drives, so the two have to agree about which side is which.
    tiles = lathe('ss_tiles', [(R * 1.006, SS_L * 0.02), (R * 1.006, SS_L * 0.72)],
                  M['tiles'], seg=40, t0=-0.06, t1=pi + 0.06, parent=g)
    smooth(tiles, 25)
    tnose = lathe('ss_tilenose', [(R * 1.006 * (1 - (u / 12) ** 2 * 0.55),
                                   SS_L * 0.72 + (SS_L * 0.22) * (u / 12))
                                  for u in range(13)],
                  M['tiles'], seg=40, t0=-0.06, t1=pi + 0.06, parent=g)
    smooth(tnose, 25)

    # ---- four flaps: two forward, two aft. They are not control surfaces in
    # the aircraft sense — the ship falls belly-first like a skydiver and moves
    # these to shift its centre of pressure, which is why they are so big and
    # so slow.
    #
    # Each hangs on a hinge node update() drives; the node's rest pose must be
    # identity about the driven axis or the first frame snaps it.
    #
    # THE HINGE AXIS IS SPANWISE, and getting that right is a frame problem
    # rather than a modelling one. update() drives these nodes by assigning
    # Three's rotation.z, which is a rotation about the node's OWN local axis —
    # Blender -Y — so a flap laid out along X hinges about the vehicle's
    # up-axis and SWEEPS fore and aft instead of feathering. The node is
    # therefore turned a quarter turn about Z and the flap built along its
    # local +Y: then the driven axis is the span, and the flap tips edge-on to
    # the flow the way the real one does.
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

    # ---- six Raptors: three sea-level that gimbal, three vacuum that do not.
    # The vacuum bells are nearly twice the exit diameter and they are fixed —
    # a 2.4 m bell has no room to swing inside a 9 m skirt.
    # The sea-level three sit INSIDE the vacuum three, STAGGERED sixty degrees
    # against them: at the same phase a 2.4 m vacuum bell 1.4 m outboard of a
    # 1.08 m sea-level one sits straight on top of it, and no amount of ring
    # radius fixes that on its own.
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
