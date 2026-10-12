# SUPER HEAVY / STARSHIP V3, the Blender build: 72.3 m of booster (engines included)
# under 52.1 m of ship, both 9 m across, 124.4 m stacked, 33 Raptor 3s on the pad.
#   · Bare 304L stainless in weld rings ~1.83 m apart (the coil width), which gives
#     the plain cylinder its scale.
#   · Booster: the vented hot-staging interstage is part of it (a crown of truss
#     arches over a steel-shielded forward dome, never jettisoned); three grid fins
#     50 % larger than V2's in a T (port, starboard and away from the tower), the
#     side pair also the catch points; two chines down the lower 60 %; the Raptor 3s
#     bare under a ring of plumbing, with no shrouds.
#   · Ship: tiles on the windward half; forward flaps moved leeward (140° apart, the
#     aft pair 180°); docking/propellant-transfer ports on the leeward side.
# Thirteen of the booster's engines gimbal and twenty are rigid; the ship has three
# steering sea-level Raptors and three fixed vacuum ones. Rigid pivots are suffixed
# `_fixed`. Shared numbers with build_super_heavy() / build_starship_ship() in
# sim/flight/craftmodel.gd.
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import math
from math import pi, cos, sin
from lib import (revolve, cyl, lathe, tank, box, torus_z, disc, empty, finish,
                 smooth, strut, bell, ogive, rcs_ring, ring_on, _obj, TAU)
from common import build, stage, hinge, vehicle_stages

S = vehicle_stages("starship")

SH_L, D = S["sh"]["L"], S["sh"]["D"]
SS_L = S["ss"]["L"]
R = D / 2
RING = 1.83                        # weld-ring pitch: the coil width

# THE ENGINE PACKING, tested by nearest neighbour over the whole cluster. Radii 0.90 /
# 2.05 / 3.45 exit diameters keep every pair ≥ 1.079 apart, outer edge at 3.95.
K1, K2, K3 = 0.90, 2.05, 3.45
R_MAX = R * 0.95
RAPTOR_D = min(S["sh"]["engine"]["exitD"], R_MAX / (K3 + 0.5))
RVAC_D = S["ss"]["vacEngine"]["exitD"]
SH_RINGS = ((3, K1 * RAPTOR_D, 0.0, False),
            (10, K2 * RAPTOR_D, pi / 10, False),
            (20, K3 * RAPTOR_D, pi / 20, True))
SS_SEA_R, SS_VAC_R = 0.95 * RAPTOR_D, 2.45

# THE LAYOUT, metres up each stage. Booster: the engine bay's plumbing ring up to
# BAY_TOP, the crown's arches over the top CROWN metres, the vents and fins below it.
BAY_TOP = 2.0
CROWN = 1.3
VENT_Y = SH_L - 9.0
FIN_Y = SH_L - 3.4
FIN_W, FIN_H, FIN_DEPTH, FIN_PITCH = 5.2, 4.2, 0.75, 0.62
# Fins at the catch points (±X, where the tower's arms take the booster) and a third
# away from the tower, at −Y: 90/90/180°.
FIN_AZ = (0.0, pi, -pi / 2)
CHINE_AZ, CHINE_TOP, CHINE_OUT = (pi / 2 + 0.35, -pi / 2 + 0.35), SH_L * 0.60, 0.95
# Ship: the nose, the flaps (hinge azimuth, foot and head of the hinge line, span at
# the root and tip), the ports. The belly is +Y.
NOSE_L = D * 1.55
FWD_FLAP = (0.35, SS_L - NOSE_L + 1.0, SS_L - 4.6, 3.4, 1.6)
AFT_FLAP = (0.0, 1.2, 12.6, 4.6, 3.2)


def weld_rings(name, z0, z1, mat, parent, r=R):
    """The horizontal weld seams: on a vehicle this plain the only thing carrying scale."""
    n = int((z1 - z0) / RING)
    for i in range(1, n + 1):
        s = torus_z(f'{name}{i}', r * 1.003, 0.028, z0 + i * RING, mat,
                    seg=64, minor=6, parent=parent)
        smooth(s, 30)


def prism(name, az, z0, z1, half_w, out, mat, parent, taper=3.0):
    """A chine: a triangular fairing standing off the hull, its apex `out` from the skin
       and its base `half_w` either side, tapering to nothing over the top `taper` m."""
    verts, faces = [], []
    zs = [z0, z1 - taper, z1 - taper * 0.5, z1]
    hs = [out, out, out * 0.45, 0.02]
    dw = half_w / R
    for z, h in zip(zs, hs):
        for a, r in ((az - dw, R * 0.995), (az, R + h), (az + dw, R * 0.995)):
            verts.append((cos(a) * r, sin(a) * r, z))
    for i in range(len(zs) - 1):
        o, p = i * 3, (i + 1) * 3
        faces += [(o, o + 1, p + 1, p), (o + 1, o + 2, p + 2, p + 1)]
    faces += [(2, 1, 0), (len(verts) - 3, len(verts) - 2, len(verts) - 1)]
    return _obj(name, verts, faces, mat, parent)


def hex_grid_fin(name, mat, parent):
    """
    A V3 grid fin: an elongated hexagon of deep diamond cells, the flow passing through
    them (along local Z). Span along +X from the hinge, width along Y.
    """
    g = empty(name, (0, 0, 0), parent)
    W, H, dz = FIN_W, FIN_H, FIN_DEPTH
    hull = [(0, -H * 0.25), (W * 0.22, -H / 2), (W * 0.78, -H / 2), (W, -H * 0.25),
            (W, H * 0.25), (W * 0.78, H / 2), (W * 0.22, H / 2), (0, H * 0.25)]
    for i in range(len(hull)):
        a, b = hull[i], hull[(i + 1) % len(hull)]
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        box(f'{name}_rim{i}', (ln + 0.12, 0.14, dz), (mx, my, 0), mat,
            rot=(0, 0, math.atan2(b[1] - a[1], b[0] - a[0])), parent=g)
    # Diagonal bars at ±45°, each clipped to the hexagon.
    def clip(p, d):
        t0, t1 = -1e9, 1e9
        for i in range(len(hull)):
            a, b = hull[i], hull[(i + 1) % len(hull)]
            ex, ey = b[0] - a[0], b[1] - a[1]
            nx, ny = ey, -ex                       # outward for a CCW hull
            den = nx * d[0] + ny * d[1]
            num = nx * (a[0] - p[0]) + ny * (a[1] - p[1])
            if abs(den) < 1e-9:
                if num < 0: return None
                continue
            t = num / den
            if den > 0: t1 = min(t1, t)
            else: t0 = max(t0, t)
        return (t0, t1) if t1 > t0 else None
    k = 0
    for sgn in (1, -1):
        d = (math.sqrt(0.5), sgn * math.sqrt(0.5))
        n = int((W + H) / FIN_PITCH) + 2
        for j in range(-n, n + 1):
            # A line through the hull's centre, offset along its normal.
            nrm = (-d[1], d[0])
            p = (W / 2 + nrm[0] * j * FIN_PITCH, nrm[1] * j * FIN_PITCH)
            seg = clip(p, d)
            if seg is None or seg[1] - seg[0] < 0.2: continue
            t = (seg[0] + seg[1]) / 2
            box(f'{name}_bar{k}', (seg[1] - seg[0], 0.05, dz * 0.92),
                (p[0] + d[0] * t, p[1] + d[1] * t, 0), mat,
                rot=(0, 0, math.atan2(d[1], d[0])), parent=g)
            k += 1
    return g


# SUPER HEAVY
def build_sh(M, root):
    g = stage('sh', root)
    body = tank('sh_body', SH_L - BAY_TOP - CROWN, D, M['steel'], dome_top=0.0, dome_bot=0.0,
                seg=72, parent=g, z0=BAY_TOP)
    finish(body, 0.03, 2, 40)
    weld_rings('sh_ring', BAY_TOP, SH_L - CROWN - 0.4, M['steel'], g)
    # The common dome, the LOX frost line on a fuelled booster sits below it.
    smooth(torus_z('sh_dome', R * 1.008, 0.08, SH_L * 0.70, M['dirty'], seg=72, minor=8, parent=g), 30)

    # ---- the vented interstage: a crown of truss arches over the forward dome, which a
    # steel shield and its own tank pressure protect from the ship's engines.
    smooth(torus_z('crown_base', R * 1.0, 0.14, SH_L - CROWN, M['steel'], seg=72, minor=8, parent=g), 30)
    smooth(torus_z('crown_top', R * 0.99, 0.12, SH_L - 0.12, M['steel'], seg=72, minor=8, parent=g), 30)
    disc('crown_shield', R * 0.99, SH_L - CROWN - 0.02, M['hot'], seg=72, parent=g)
    n = 30
    for i in range(n):
        a0, a1 = i / n * TAU, (i + 1) / n * TAU
        am = (a0 + a1) / 2
        lo0 = (cos(a0) * R, sin(a0) * R, SH_L - CROWN)
        lo1 = (cos(a1) * R, sin(a1) * R, SH_L - CROWN)
        hi = (cos(am) * R * 0.99, sin(am) * R * 0.99, SH_L - 0.12)
        strut(f'crown_a{i}', lo0, hi, 0.07, M['steel'], seg=6, parent=g)
        strut(f'crown_b{i}', lo1, hi, 0.07, M['steel'], seg=6, parent=g)
    # The band of vent slots below it.
    for i in range(36):
        a = i / 36 * TAU
        box(f'vent{i}', (0.06, 0.32, 1.7), (cos(a) * R * 1.004, sin(a) * R * 1.004, VENT_Y),
            M['black'], rot=(0, 0, a), parent=g)

    # ---- 33 Raptor 3s (3 + 10 + 20). The inner thirteen gimbal; the outer twenty don't.
    idx = 0
    for count, rr, phase, fixed in SH_RINGS:
        for i in range(count):
            a = i / count * TAU + phase
            nm = f'gimbal_sh_{idx:02d}' + ('_fixed' if fixed else '')
            piv = empty(nm, (cos(a) * rr, sin(a) * rr, -0.02), g)
            b = bell(f'raptor{idx}', RAPTOR_D, M['soot'], ratio=34, seg=16, parent=piv)
            finish(b, 0.008, 2, 50)
            idx += 1
    # Raptor 3 needs no shroud: the bay is open, ringed with its plumbing, the aft dome
    # tiled above it.
    disc('sh_aftdome', R * 0.97, BAY_TOP - 0.05, M['black'], seg=72, parent=g)
    for z in (0.35, 0.95, 1.55):
        smooth(torus_z(f'sh_manifold{z}', R * 0.955, 0.13, z, M['soot'], seg=72, minor=8, parent=g), 30)
    for i in range(40):
        a = i / 40 * TAU + 0.04
        strut(f'sh_pipe{i}', (cos(a) * R * 0.95, sin(a) * R * 0.95, 0.15),
              (cos(a) * R * 0.95, sin(a) * R * 0.95, BAY_TOP), 0.06, M['soot'], seg=6, parent=g)
    finish(cyl('sh_skirt', R * 1.006, R * 1.006, BAY_TOP, BAY_TOP + 0.5, M['dirty'], seg=72, parent=g), 0.02)
    # ---- two chines down the lower 60 % (batteries, pressurant), and a conduit to the top.
    for i, az in enumerate(CHINE_AZ):
        finish(prism(f'sh_chine{i}', az, BAY_TOP + 0.3, CHINE_TOP, 0.85, CHINE_OUT, M['steel'], g), 0.02)
    a = -pi / 2 - 0.5
    finish(box('sh_raceway', (0.30, 0.42, SH_L - 6.0), (cos(a) * (R + 0.15), sin(a) * (R + 0.15), SH_L / 2 - 1.0),
               M['steel'], rot=(0, 0, a), parent=g), 0.02)
    # Quick-disconnect plate, on the tower side.
    finish(box('sh_qd', (0.4, 2.2, 1.8), (0, R + 0.15, 4.0), M['dirty'], parent=g), 0.03)

    # ---- three grid fins, fixed (never folded); registered as fins and built at −1.35
    # so the deploy's +1.35 leaves them square.
    for i, az in enumerate(FIN_AZ):
        h, _ = hinge(f'fin_sh_{i}', (cos(az) * R, sin(az) * R, FIN_Y), az, g)
        arm = empty(f'shgfarm{i}', (0, 0, 0), h)
        arm.rotation_euler = (0, -1.35, 0)
        gf = hex_grid_fin(f'shgf{i}', M['hot'], arm)
        gf.location = (0.9, 0, 0)
        strut(f'shfinhinge{i}', (0, 0, 0), (0.95, 0, 0), 0.32, M['hot'], seg=10, parent=arm)
    rcs_ring('sh_rcs', D * 1.04, SH_L - 6.0, M['dirty'], M['nozzle'], 4, parent=g)
    return g


# STARSHIP
def nose_r(z):
    """The ship's local radius at height z: R on the barrel, the ogive's curve above."""
    z0 = SS_L - NOSE_L
    if z <= z0:
        return R
    t = min(z - z0, NOSE_L)
    rho = (R * R + NOSE_L * NOSE_L) / (2 * R)
    return max(math.sqrt(max(rho * rho - t * t, 0.0)) - rho + R, 0.02)


def flap(name, az, z0, z1, span0, span1, mat, hinge_mat, parent):
    """
    A flap on its hinge line. The driven node's local −Y runs up the hinge (Godot's
    local Z, which update() turns), so the flap swings about the body's own axis as
    the real ones do; its mount carries the azimuth and that quarter turn. The plate
    spans along local +X from the hull, its chord along −Y.
    """
    r0, r1 = nose_r(z0), nose_r(z1)
    mount = empty(f'mount_{name}', (cos(az) * r0 * 0.99, sin(az) * r0 * 0.99, z0), parent)
    mount.rotation_euler = (-pi / 2, 0, az)
    # Up a nose the hinge leans in with the skin, by the slope between its ends.
    tilt = empty(f'tilt_{name}', (0, 0, 0), mount)
    tilt.rotation_euler = (0, 0, -math.atan2(r0 - r1, z1 - z0))
    node = empty(name, (0, 0, 0), tilt)
    L = math.hypot(z1 - z0, r0 - r1)
    th = 0.32
    # Trapezoid: root along the hinge (span0 out at the foot, span1 at the head).
    verts = []
    for x, y in ((0, 0), (span0, 0), (span1, -L * 0.92), (0, -L)):
        for zz in (-th / 2, th / 2):
            verts.append((x + 0.05, y, zz))
    faces = [(0, 2, 4, 6), (7, 5, 3, 1), (0, 1, 3, 2), (2, 3, 5, 4), (4, 5, 7, 6), (6, 7, 1, 0)]
    finish(_obj(f'{name}_plate', verts, faces, mat, node), 0.05, 2, 40)
    hf = cyl(f'{name}_hinge', 0.36, 0.36, 0.0, L, hinge_mat, seg=16, parent=node)
    hf.rotation_euler = (pi / 2, 0, 0)
    finish(hf, 0.015, 2, 45)
    return node


def build_ss(M, root):
    g = stage('ss', root)
    body = tank('ss_body', SS_L - NOSE_L, D, M['steel'], dome_top=0.0, dome_bot=0.02, seg=72, parent=g)
    finish(body, 0.03, 2, 40)
    weld_rings('ss_ring', 0.6, SS_L - NOSE_L - 0.6, M['steel'], g)
    finish(ogive('ss_nose', NOSE_L, D, M['steel'], seg=72, parent=g, z0=SS_L - NOSE_L), 0.03, 2, 40)

    # ---- tiles on the windward half (+Y), up the nose to a black cap. The edge stands a
    # little past the flaps' hinge lines, which is where the real tiling stops.
    prof = [(R * 1.006, 0.6), (R * 1.006, SS_L - NOSE_L)]
    for i in range(1, 25):
        z = SS_L - NOSE_L + NOSE_L * 0.985 * i / 24
        prof.append((nose_r(z) * 1.006 + 0.004, z))
    smooth(lathe('ss_tiles', prof, M['tiles'], seg=48, t0=-0.10, t1=pi + 0.10, parent=g), 25)
    cap = [(nose_r(SS_L - 1.6) * 1.008, SS_L - 1.6)] + [(nose_r(SS_L - 1.6 + 1.6 * i / 6) * 1.008, SS_L - 1.6 + 1.6 * i / 6) for i in range(1, 6)] + [(0, SS_L + 0.004)]
    smooth(revolve('ss_tipcap', cap, M['tiles'], seg=48, parent=g), 25)

    # ---- four flaps: aft pair at the tile boundary (180° apart), forward pair moved
    # leeward (140° apart), both swinging about hinge lines along the body.
    fa, f0, f1, fs0, fs1 = FWD_FLAP
    aa, a0, a1, as0, as1 = AFT_FLAP
    for i, (az, z0, z1, s0, s1) in enumerate(((-fa, f0, f1, fs0, fs1), (pi + fa, f0, f1, fs0, fs1),
                                              (aa, a0, a1, as0, as1), (pi - aa, a0, a1, as0, as1))):
        flap(f'flap_ss_{i}', az, z0, z1, s0, s1, M['tiles'], M['hot'], g)

    # ---- six Raptor 3s: three gimballing sea-level inside three fixed vacuum, staggered.
    for i in range(3):
        a = i / 3 * TAU + 0.5
        piv = empty(f'gimbal_ss_{i}', (cos(a) * SS_SEA_R, sin(a) * SS_SEA_R, -0.02), g)
        finish(bell(f'ssraptor{i}', RAPTOR_D, M['soot'], ratio=34, seg=18, parent=piv), 0.008, 2, 50)
    for i in range(3):
        a = i / 3 * TAU + 0.5 + pi / 3
        piv = empty(f'gimbal_ss_{i + 3}_fixed', (cos(a) * SS_VAC_R, sin(a) * SS_VAC_R, -0.02), g)
        finish(bell(f'ssrvac{i}', RVAC_D, M['nozzle'], ratio=90, seg=24, parent=piv), 0.010, 2, 50)
    finish(cyl('ss_skirt', R, R * 0.99, 0.0, 1.6, M['soot'], seg=72, parent=g), 0.02, 2, 45)

    # ---- leeward: the docking / propellant-transfer ports, a raceway, and the catch pins.
    for z, s in ((SS_L * 0.74, 1.3), (SS_L * 0.31, 1.9)):
        finish(box(f'ss_port{z:.0f}', (s, 0.10, s), (0, -R * 1.006, z), M['black'], parent=g), 0.02)
    a = -pi / 2 + 0.45
    finish(box('ss_raceway', (0.26, 0.36, SS_L - NOSE_L - 3.0), (cos(a) * (R + 0.13), sin(a) * (R + 0.13), (SS_L - NOSE_L) / 2),
               M['steel'], rot=(0, 0, a), parent=g), 0.02)
    for sgn in (-1, 1):
        finish(box(f'ss_catchpin{sgn}', (0.7, 0.5, 0.5), (sgn * R * 1.04, -0.6, SS_L * 0.70), M['hot'], parent=g), 0.02)
    rcs_ring('ss_rcs', D * 1.04, SS_L * 0.66, M['dirty'], M['nozzle'], 4, parent=g)
    return g


def build_starship(M):
    root = empty('Starship', (0, 0, 0))
    build_sh(M, root)
    build_ss(M, root)


build('starship', build_starship)
