# ---------------------------------------------------------------------------
# THE HAIL MARY — the Blender build.
# ---------------------------------------------------------------------------
#   assets/blender/build.sh          (or drive Blender yourself, see below)
#
# WHY THIS EXISTS AND THE PROCEDURAL BUILDER STILL DOES. sim/flight/craftmodel.js
# builds every vehicle out of Three.js primitives, which is the right trade for
# eight of the nine: a Saturn V is a stack of cylinders and cones and it is
# genuinely parametric — change spec.D and the whole thing follows. The Hail
# Mary is the one that is not. Its shape is three bent pressure vessels nested
# against a lathed spine, and what makes it read is a hundred small pieces of
# hardware with BEVELLED edges catching a highlight. A perfectly sharp edge
# catches nothing; that is why the primitive build looks like cardboard however
# right its silhouette is, and it is the one thing a runtime full of
# CylinderGeometry cannot fix.
#
# So: this script is the model, the .glb is a build artifact, and the
# procedural buildHailMary() stays as the fallback for when the asset is not
# there. Nothing here is clicked — the numbers are the same ones in
# craftmodel.js, so the two builds are the same ship.
#
# GEOMETRY. Blender is Z-up and the exporter converts to Three's Y-up, so the
# thrust axis is +Z here and the nose is toward +Z. z = 0 is the DRIVE EXIT
# PLANE. Metres throughout.
# ---------------------------------------------------------------------------
import bpy, sys, os, math
from math import cos, sin, pi, radians, hypot
from mathutils import Vector

sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from common import build, stage
from lib import (reset_scene, material, revolve, tube, ring_on, box, strut,
                 fin, finish, smooth, bevel, empty, group, frames, TAU)

# ---------------------------------------------------------------------------
# THE NUMBERS. Identical to sim/flight/vehicles.js and buildHailMary().
# ---------------------------------------------------------------------------
L, D = 47.0, 12.0
f = lambda u: u * L
AFT = f(0.132)                     # the aft plane, in build coords
TR = D * 0.265                     # tank centreline radius      3.180
TANK_R = D * 0.110                 # tank radius                 1.320
DR = TANK_R * 0.62                 # drive aperture radius       0.818
NECK_Z = DR * 1.42                 # drive neck height
TOP_Z = NECK_Z + DR * 0.62         # full drive height
PLATE_Z = AFT + TOP_Z + f(0.006)   # the spine's thrust plate

BAY = 2.6                          # tank barrel section length


# ---------------------------------------------------------------------------
# MATERIALS
# ---------------------------------------------------------------------------
M = {}
def build_materials():
    M['white']  = material('white',  (0.86, 0.86, 0.88), 0.62, 0.04)
    M['dirty']  = material('dirty',  (0.60, 0.60, 0.63), 0.78, 0.05)
    M['alu']    = material('alu',    (0.42, 0.45, 0.48), 0.40, 0.30)
    M['steel']  = material('steel',  (0.55, 0.59, 0.63), 0.30, 0.32)
    M['gold']   = material('gold',   (0.62, 0.40, 0.09), 0.46, 0.35)
    M['soot']   = material('soot',   (0.045, 0.045, 0.055), 0.80, 0.03)
    M['nozzle'] = material('nozzle', (0.16, 0.155, 0.145), 0.38, 0.30)
    M['solar']  = material('solar',  (0.016, 0.030, 0.13), 0.28, 0.22)
    M['glass']  = material('glass',  (0.01, 0.02, 0.035), 0.10, 0.20)
    M['rad']    = material('rad',    (0.78, 0.78, 0.80), 0.50, 0.06)
    # An emitter has to be lit BY ITSELF. A drive face points aft, away from
    # every light in the scene, so it renders black however it is coloured —
    # and the sim's pipeline is HDR and expects emitters well above 1.0.
    # Astrophage fires at 4.26 and 18.31 um, so the visible tail is deep red.
    M['emitPlate'] = material('emitPlate', (0.10, 0.09, 0.085), 0.52, 0.15,
                              emit=(0.55, 0.17, 0.07), emit_strength=1.4)
    M['emitCell']  = material('emitCell',  (0.05, 0.02, 0.015), 0.45, 0.08,
                              emit=(1.0, 0.38, 0.15), emit_strength=3.2)


# ---------------------------------------------------------------------------
# PATHS
# ---------------------------------------------------------------------------
def bent_path(x0, z0, zbend, turn_r, turn_deg, runout, n_straight=16, n_arc=28):
    """
    A centreline that runs straight and then bends in through a circular arc,
    ending with a short straight run on the new heading. Same construction as
    bentPath() in craftmodel.js and the same endpoints — only sampled finer,
    because here there is no per-ring cost to a smooth curve.
    """
    pts, th, cx = [], radians(turn_deg), x0 - turn_r
    for i in range(n_straight + 1):
        pts.append((x0, 0.0, z0 + (zbend - z0) * i / n_straight))
    for i in range(1, n_arc + 1):
        t = th * i / n_arc
        pts.append((cx + turn_r * cos(t), 0.0, zbend - turn_r * sin(t)))
    ex, _, ez = pts[-1]
    pts.append((ex - sin(th) * runout, 0.0, ez - cos(th) * runout))
    return pts


def resample(path, step):
    """Uniform arc-length resampling, so a panel line lands where it is asked
       for rather than wherever the source polyline happened to have a point."""
    P = [Vector(p) for p in path]
    seg = [0.0]
    for i in range(1, len(P)):
        seg.append(seg[-1] + (P[i] - P[i - 1]).length)
    total = seg[-1]
    n = max(2, int(round(total / step)))
    out, arc = [], []
    for k in range(n + 1):
        s = total * k / n
        i = 1
        while i < len(seg) - 1 and seg[i] < s:
            i += 1
        u = (s - seg[i - 1]) / max(seg[i] - seg[i - 1], 1e-9)
        out.append(tuple(P[i - 1].lerp(P[i], u)))
        arc.append(s)
    return out, arc, total


# ---------------------------------------------------------------------------
# THE SPIN DRIVE
# ---------------------------------------------------------------------------
def spin_drive(name, R, parent, loc, tag):
    """
    A spin drive, and deliberately NOT a bell.

    Astrophage radiates its energy as light, so there is no gas to expand and
    nothing for a nozzle contour to do: the drive is a plate of emitters behind
    a shallow reflector that collimates the beam. It is therefore SHORT — a
    chemical bell is long because gas needs length to expand — and SMALL, since
    a photon drive's thrust is P/c and the aperture is set by what the plate can
    radiate, not by an area ratio.

    The returned pivot's origin is ON THE EXIT PLANE, because spaceflight.js
    parents the plume straight to it; anywhere else and the beam starts inside
    the hardware. Its rotation is identity, which is what craftmodel's update()
    requires of anything it drives.
    """
    piv = empty(name, loc, parent)
    name = tag          # parts are named for the drive, not for the pivot

    prof = []
    for i in range(17):                              # the reflector
        u = i / 16
        prof.append((R * (1 - 0.42 * u * u), R * 1.05 * u))
    prof.append((R * 0.58, NECK_Z))
    finish(revolve(name + '_reflector', prof, M['nozzle'], seg=64, parent=piv),
           bevel_w=0.012)

    finish(ring_on((0, 0, 0), (0, 0, 1), R, R * 0.055, M['alu'],
                   name + '_lip', seg=64, minor=12, parent=piv), bevel_w=0.006)

    # The emitter plate, RECESSED inside the reflector: you should have to look
    # up the drive to see it, which is also what stops four glowing discs
    # reading as four tail-lights.
    pr, pz = R * 0.80, R * 0.55
    finish(revolve(name + '_plate',
                   [(0, pz), (pr, pz), (pr, pz + R * 0.07), (0, pz + R * 0.07)],
                   M['emitPlate'], seg=48, parent=piv), bevel_w=0.008)
    for ring in range(1, 4):                          # the emitter array
        rr, cnt = pr * 0.27 * ring, 6 * ring
        for k in range(cnt):
            b = k / cnt * TAU + ring * 0.4
            c = revolve(f'{name}_cell{ring}_{k}',
                        [(0, 0), (pr * 0.105, 0), (pr * 0.105, R * 0.045), (0, R * 0.045)],
                        M['emitCell'], seg=6, parent=piv)
            c.location = (cos(b) * rr, sin(b) * rr, pz - R * 0.01)
            finish(c, bevel_w=0.004)
    # Cooling ribs, standing OFF the reflector and following its curve. A drive
    # turning two thousand tonnes of fuel into light has to reject the waste
    # heat somewhere, and they are also what gives the cone a scale to read
    # against. Straight boxes were buried inside the bell for most of their
    # length — the wall is curved, so the rib has to be.
    for i in range(12):
        finish(fin(f'{name}_rib{i}', prof[2:], i / 12 * TAU, R * 0.085, R * 0.055,
                   M['alu'], parent=piv), bevel_w=0.006)
    # The emitter can — the machinery the plate is the front face of — and a
    # closing disc so you cannot see up inside the ship.
    finish(revolve(name + '_can',
                   [(0, NECK_Z), (R * 0.58, NECK_Z), (R * 0.64, NECK_Z + R * 0.06),
                    (R * 0.64, TOP_Z), (0, TOP_Z)],
                   M['dirty'], seg=48, parent=piv), bevel_w=0.010)
    finish(ring_on((0, 0, NECK_Z + R * 0.12), (0, 0, 1), R * 0.66, R * 0.05,
                   M['alu'], name + '_collar', seg=48, minor=10, parent=piv),
           bevel_w=0.006)
    for i in range(16):                               # fasteners round the collar
        a = i / 16 * TAU
        bo = revolve(f'{name}_bolt{i}',
                     [(0, 0), (R * 0.035, 0), (R * 0.035, R * 0.035), (0, R * 0.035)],
                     M['steel'], seg=6, parent=piv)
        bo.location = (cos(a) * R * 0.70, sin(a) * R * 0.70, NECK_Z + R * 0.24)
        finish(bo, bevel_w=0.004)
    return piv


# ---------------------------------------------------------------------------
# A TANK
# ---------------------------------------------------------------------------
def build_tank(idx, root, path):
    """One astrophage tank, its hardware, and the drive square underneath it."""
    a = idx / 3 * TAU + pi / 2
    g = group(f'tank{idx}', root, rot_z=a)

    pts, arc, total = resample(path, 0.125)
    tan, nrm, bi = frames(pts)

    # PANEL GROOVES, cut into the skin as real geometry rather than painted on
    # as a stripe. The tank is built as a run of barrel sections and the radius
    # dips at every joint; spaced by ARC LENGTH, because the source polyline is
    # eighteen times denser round the bend than down the barrel and indexing by
    # point puts all the detail on the turn.
    seams = [n * BAY for n in range(1, int(total / BAY) + 1)]
    W = 0.17
    def rfun(i, j, ang):
        s, r = arc[i], TANK_R
        for sm in seams:
            d = abs(s - sm)
            if d < W:
                r -= TANK_R * 0.020 * (1 - (d / W) ** 2)
        # and six longitudinal seams down the length. The half-width has to be
        # comfortably wider than the angular step or the groove falls between
        # two samples and is smoothed away — at 72 segments that step is 0.087
        # rad, and a 0.045 groove was invisible.
        for k in range(6):
            da = abs(((ang - k * TAU / 6 + pi) % TAU) - pi)
            if da < 0.075:
                r -= TANK_R * 0.015 * (1 - (da / 0.075) ** 2)
        return r
    finish(tube(f'tank{idx}_skin', pts, TANK_R, M['white'], seg=84, parent=g,
                rfun=rfun), bevel_w=0.010)

    def at(s):
        i = 1
        while i < len(arc) - 1 and arc[i] < s:
            i += 1
        u = (s - arc[i - 1]) / max(arc[i] - arc[i - 1], 1e-9)
        return (Vector(pts[i - 1]).lerp(Vector(pts[i]), u),
                tan[i - 1].lerp(tan[i], u).normalized(),
                nrm[i - 1].lerp(nrm[i], u).normalized(),
                bi[i - 1].lerp(bi[i], u).normalized())

    # Ring frames, halfway between the grooves.
    for n in range(int(total / BAY) + 1):
        s = BAY * (n + 0.5)
        if s > total - 0.45:
            break
        p, t, _, _ = at(s)
        finish(ring_on(p, t, TANK_R * 1.012, TANK_R * 0.038, M['alu'],
                       f'tank{idx}_frame{n}', seg=64, minor=10, parent=g),
               bevel_w=0.006)

    def surf(s, phi, rr):
        p, t, nv, bv = at(s)
        return p + nv * (cos(phi) * rr) + bv * (sin(phi) * rr)

    # Cable trays, a propellant trunk on the inboard face and a conduit run on
    # the outboard one, all carried round the bend on the tank's own frame.
    # These are most of what tells you a tank is a machine and not a cylinder.
    runs = [(0.62, TANK_R * 1.05, 0.085, 'alu'), (-0.62, TANK_R * 1.05, 0.085, 'alu'),
            (pi * 0.5, TANK_R * 1.09, 0.135, 'dirty'),
            (pi * 1.5, TANK_R * 1.06, 0.090, 'soot'),
            (pi * 1.5 - 0.30, TANK_R * 1.04, 0.055, 'alu')]
    for ri, (phi, rr, rad, mk) in enumerate(runs):
        line = [tuple(surf(s, phi, rr)) for s in
                [total * k / 60 for k in range(61)]]
        finish(tube(f'tank{idx}_run{ri}', line, rad, M[mk], seg=12, parent=g,
                    caps=(True, True)), bevel_w=0.010)
    # Standoff brackets, so the runs are held off the skin rather than sunk in it.
    for n in range(1, int(total / 2.0)):
        s = n * 2.0
        for phi in (pi * 0.5, pi * 1.5):
            finish(strut(f'tank{idx}_brk{n}_{phi:.1f}', surf(s, phi, TANK_R * 0.99),
                         surf(s, phi, TANK_R * 1.11), 0.05, M['alu'], parent=g),
                   bevel_w=0.006)

    p0 = Vector(pts[0])
    # ---- FORWARD DOME. An ellipsoidal head, RIM ON THE BARREL and apex above
    # it, and — like every other lathed part here — moved out to the tank's own
    # centreline rather than left on the ship's axis.
    #
    # Both of those were wrong and the two errors hid each other. Written the
    # other way round (full radius at full height, closing to the axis at the
    # barrel's top) the dome is a CONCAVE FUNNEL whose rim floats a tank radius
    # clear of the skin, so the tank is left open at the top and you look
    # straight down the inside of it; revolved about the origin it was not over
    # the tank at all, but a 1.3 m cone standing on the centreline. A tank is a
    # pressure vessel and the one thing it has to be is CLOSED.
    hd = TANK_R * 0.72                      # a sqrt(2) ellipsoidal head
    dome = [(TANK_R * cos(i / 12 * pi / 2), p0.z + hd * sin(i / 12 * pi / 2))
            for i in range(13)]
    dm = revolve(f'tank{idx}_dome', dome, M['white'], seg=72, parent=g)
    dm.location = (p0.x, 0, 0)
    finish(dm, bevel_w=0.010)
    finish(ring_on((p0.x, 0, p0.z), (0, 0, 1), TANK_R * 1.015, TANK_R * 0.05,
                   M['alu'], f'tank{idx}_collar', seg=64, minor=10, parent=g),
           bevel_w=0.006)
    v = revolve(f'tank{idx}_vent',
                [(0, 0), (TANK_R * 0.22, 0), (TANK_R * 0.18, TANK_R * 0.30),
                 (0, TANK_R * 0.30)], M['dirty'], seg=20, parent=g)
    v.location = (p0.x + TANK_R * 0.40, 0, p0.z + hd * 0.86)
    finish(v, bevel_w=0.008)

    # MLI: one band on the straight run above the bend, one under the dome.
    for bi2, (z, h) in enumerate([(f(0.285), f(0.030)), (f(0.640), f(0.022))]):
        finish(revolve(f'tank{idx}_mli{bi2}',
                       [(TANK_R * 1.018, z), (TANK_R * 1.022, z + h * 0.5),
                        (TANK_R * 1.018, z + h)], M['gold'], seg=72, parent=g),
               bevel_w=0.004).location = (p0.x, 0, 0)

    # Equipment on the outboard flanks, clear of the conduit run. The boxes are
    # small, and being able to SEE that they are small next to a 2.6 m tank is
    # most of what they are there for.
    for n, (z, w, h2, phi) in enumerate([(f(0.330), 1.5, 1.1, pi * 1.5 + 0.62),
                                         (f(0.455), 0.9, 0.8, pi * 1.5 - 0.62),
                                         (f(0.545), 1.2, 0.6, pi * 1.5 + 0.62),
                                         (f(0.612), 0.7, 0.9, pi * 1.5 - 0.62)]):
        px = p0.x - sin(phi) * TANK_R * 1.06
        py = cos(phi) * TANK_R * 1.06
        finish(box(f'tank{idx}_box{n}', (0.34, w, h2), (px, py, z), M['dirty'],
                   rot=(0, 0, math.atan2(cos(phi), -sin(phi))), parent=g),
               bevel_w=0.020)

    # ---- the aft end: a bulkhead, a thrust block, and the drive square under it.
    endP, endT = Vector(pts[-1]), tan[-1]
    finish(ring_on(endP, endT, TANK_R * 1.005, TANK_R * 0.055, M['alu'],
                   f'tank{idx}_capring', seg=64, minor=10, parent=g), bevel_w=0.006)
    cap = revolve(f'tank{idx}_cap',
                  [(0, 0), (TANK_R, 0), (TANK_R, 0.10), (0, 0.10)],
                  M['dirty'], seg=64, parent=g)
    cap.rotation_mode = 'QUATERNION'
    cap.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(endT)
    cap.location = endP
    finish(cap, bevel_w=0.010)

    # The thrust block. This is what makes an axial drive under a bent tank an
    # honest structure rather than a floating one: the tank's aft face is
    # oblique, the drive is square to the ship, and the whole sixteen degrees
    # is taken up in one short piece of hardware instead of being carried out
    # into the thrust vector.
    b_bot, b_top = AFT + TOP_Z, endP.z + TANK_R * 0.62
    blk = revolve(f'tank{idx}_block',
                  [(0, b_bot), (DR * 0.80, b_bot), (DR * 0.92, b_top), (0, b_top)],
                  M['dirty'], seg=40, parent=g)
    blk.location = (endP.x, 0, 0)
    finish(blk, bevel_w=0.012)
    # Gussets out to the bulkhead ring. The cap is oblique and the block is
    # square, so no two of them are the same length — which is what taking an
    # angle out of a structure actually looks like.
    for k in range(8):
        phi = k / 8 * TAU
        p2 = endP + nrm[-1] * (cos(phi) * TANK_R * 0.90) + bi[-1] * (sin(phi) * TANK_R * 0.90)
        p1 = Vector((endP.x - sin(phi) * DR * 0.88, cos(phi) * DR * 0.88, b_bot + 0.22))
        finish(strut(f'tank{idx}_gusset{k}', p1, p2, 0.055, M['alu'], parent=g),
               bevel_w=0.008)
    # The feed line, off the inboard trunk and down the side of the block into
    # the emitter can. Routed outboard of the spine's thrust plate, because the
    # shortest path from there to here goes straight through it.
    feed = [tuple(surf(total * 0.90, pi * 0.5, TANK_R * 1.09)),
            tuple(surf(total * 0.97, pi * 0.5, TANK_R * 1.15)),
            (endP.x - DR * 1.05, 0, b_bot + 0.75),
            (endP.x - DR * 0.90, 0, b_bot + 0.30)]
    dense = []
    for i in range(len(feed) - 1):
        for t2 in range(6):
            dense.append(tuple(Vector(feed[i]).lerp(Vector(feed[i + 1]), t2 / 6)))
    dense.append(feed[-1])
    finish(tube(f'tank{idx}_feed', dense, 0.12, M['alu'], seg=12, parent=g,
                caps=(True, True)), bevel_w=0.010)

    spin_drive(f'gimbal_hm_{idx + 1}', DR, g, (endP.x, 0, AFT), f'drv{idx + 1}')
    return g, endP


# ---------------------------------------------------------------------------
# THE SPINE, THE MODULE STACK AND EVERYTHING BOLTED TO THEM
# ---------------------------------------------------------------------------
def build_spine(root):
    """
    The central body: a FAT cone the tanks lie AGAINST, not a spike they bend
    past. Its radius at any height is set by the geometry around it — it has to
    equal the tank centreline's radius there minus the tank's own radius, or the
    bend curves around nothing — and it terminates on a THRUST PLATE rather than
    closing to a point, because that plate is what the axial drive hangs from
    and what the aft truss ties to.
    """
    prof = [(0, PLATE_Z), (DR * 1.55, PLATE_Z),
            (DR * 1.75, PLATE_Z + f(0.014)), (D * 0.132, f(0.212)),
            (D * 0.146, f(0.238)), (D * 0.155, f(0.266)), (D * 0.155, f(0.468))]
    finish(revolve('spine', prof, M['dirty'], seg=72, parent=root), bevel_w=0.020)
    finish(revolve('spine_rim',
                   [(DR * 1.42, PLATE_Z - f(0.016)), (DR * 1.57, PLATE_Z - f(0.008)),
                    (DR * 1.55, PLATE_Z)], M['alu'], seg=72, parent=root),
           bevel_w=0.008)
    finish(revolve('spine_neck',
                   [(0, AFT + TOP_Z - 0.05), (DR * 0.66, AFT + TOP_Z - 0.05),
                    (DR * 0.66, PLATE_Z + 0.05), (0, PLATE_Z + 0.05)],
                   M['dirty'], seg=40, parent=root), bevel_w=0.010)
    for rr, u in [(D * 0.142, 0.222), (D * 0.152, 0.252),
                  (D * 0.158, 0.330), (D * 0.158, 0.420)]:
        finish(ring_on((0, 0, f(u)), (0, 0, 1), rr, D * 0.006, M['alu'],
                       f'spine_ring{u}', seg=72, minor=10, parent=root), bevel_w=0.006)
    # MLI where the spine runs between the tanks, and the plumbing that feeds
    # four drives from three tanks — the cross-feed is why the middle of this
    # ship is machinery rather than skin.
    finish(revolve('spine_mli',
                   [(D * 0.157, f(0.300)), (D * 0.160, f(0.315)), (D * 0.157, f(0.330))],
                   M['gold'], seg=72, parent=root), bevel_w=0.004)
    for i in range(8):
        a = i / 8 * TAU + 0.5
        h = f(0.150 + 0.055 * ((i * 5) % 7) / 7)
        z0 = f(0.352) - f(0.075)
        finish(tube(f'spine_run{i}', [(cos(a) * D * 0.163, sin(a) * D * 0.163, z0),
                                      (cos(a) * D * 0.163, sin(a) * D * 0.163, z0 + h)],
                    D * 0.008, M['alu'] if i % 3 else M['soot'], seg=10,
                    parent=root, caps=(True, True)), bevel_w=0.008)
    for i in range(3):                                # valve packages
        a = i / 3 * TAU + 0.9
        finish(box(f'spine_valve{i}', (D * 0.055, D * 0.045, D * 0.075),
                   (cos(a) * D * 0.172, sin(a) * D * 0.172, f(0.288)), M['alu'],
                   rot=(0, 0, a), parent=root), bevel_w=0.018)
    # Greebling on the aft bay — small hardware at a size the eye can measure
    # the ship against. Nothing here is structural; it is all scale reference.
    for i in range(22):
        a = i / 22 * TAU + 0.21
        z = f(0.150) + (i % 5) * f(0.014)
        r = D * 0.128 + (i % 3) * 0.05
        finish(box(f'spine_greeble{i}', (0.22 + 0.10 * (i % 3), 0.34, 0.18 + 0.09 * (i % 4)),
                   (cos(a) * r, sin(a) * r, z), M['alu'] if i % 4 else M['soot'],
                   rot=(0, 0, a), parent=root), bevel_w=0.012)


def build_modules(root):
    """The module stack, standing on the cone and running past the tanks."""
    hull_z0, hull_z1, hull_d = f(0.566), f(0.855), D * 0.205

    def band(z, dia, h, mat, name):
        finish(revolve(name, [(dia / 2 * 1.02, z), (dia / 2 * 1.03, z + h * 0.5),
                              (dia / 2 * 1.02, z + h)], mat, seg=64, parent=root),
               bevel_w=0.004)

    band(f(0.468), D * 0.150, f(0.022), M['gold'], 'mod_band0')
    finish(revolve('mod_machinery',
                   [(0, f(0.468)), (D * 0.075, f(0.468)), (D * 0.075, f(0.560)),
                    (0, f(0.560))], M['dirty'], seg=64, parent=root), bevel_w=0.014)
    band(f(0.560), D * 0.180, f(0.022), M['gold'], 'mod_band1')

    # The pressure hull, with its panel joints CUT IN rather than painted on.
    r = hull_d / 2
    prof = [(0, hull_z0), (r, hull_z0)]
    for k in range(1, 4):
        z = hull_z0 + (hull_z1 - hull_z0) * (0.17 + (k - 1) * 0.30)
        prof += [(r, z - 0.10), (r * 0.982, z), (r, z + 0.10)]
    prof += [(r, hull_z1), (0, hull_z1)]
    finish(revolve('mod_hull', prof, M['white'], seg=72, parent=root), bevel_w=0.014)
    for side in (1, -1):
        w = revolve('mod_window' + ('a' if side > 0 else 'b'),
                    [(0, 0), (0.30, 0), (0.30, 0.12), (0, 0.12)], M['glass'],
                    seg=24, parent=root)
        w.rotation_euler = (0, side * pi / 2, 0)
        w.location = (side * r * 0.99, 0, hull_z0 + (hull_z1 - hull_z0) * 0.78)
        finish(w, bevel_w=0.010)
    lock = revolve('mod_airlock', [(0, 0), (0.55, 0), (0.55, 0.26), (0.44, 0.30), (0, 0.30)],
                   M['alu'], seg=32, parent=root)
    lock.rotation_euler = (-pi / 2, 0, 0)
    lock.location = (0, r * 0.98, hull_z0 + (hull_z1 - hull_z0) * 0.40)
    finish(lock, bevel_w=0.012)
    band(hull_z1, D * 0.170, f(0.022), M['gold'], 'mod_band2')

    finish(revolve('mod_instr',
                   [(0, f(0.861)), (D * 0.070, f(0.861)), (D * 0.070, f(1.013)),
                    (0, f(1.013))], M['dirty'], seg=64, parent=root), bevel_w=0.014)
    # ---- THE NOSE HAS TO BE ONE OBJECT. The docking node sat with its lower
    # surface three quarters of a metre above the instrument module's roof and
    # the mast another metre above THAT, so the top of the ship was a sphere and
    # a rod floating in company — which is exactly what it looked like. The node
    # now overlaps the module it stands on, a collar closes the joint, and the
    # mast starts inside the node.
    NODE_R, NODE_Z = D * 0.088, f(1.028)
    node = revolve('mod_node',
                   [(NODE_R * sin(i / 16 * pi), NODE_Z - NODE_R * cos(i / 16 * pi))
                    for i in range(17)], M['alu'], seg=48, parent=root)
    finish(node, bevel_w=0.010)
    finish(revolve('mod_node_collar',
                   [(D * 0.082, f(0.998)), (D * 0.082, f(1.010)), (D * 0.072, f(1.018))],
                   M['dirty'], seg=48, parent=root), bevel_w=0.008)
    for i in range(4):
        a = i / 4 * TAU
        # CLOSED at both ends: an open tube is a hole you can see the sky
        # through from the far side, and there are four of them on the nose.
        p = revolve(f'mod_port{i}', [(0, 0), (D * 0.030, 0), (D * 0.034, D * 0.055),
                                     (D * 0.030, D * 0.062), (0, D * 0.062)],
                    M['dirty'], seg=24, parent=root)
        p.rotation_euler = (pi / 2, 0, a + pi / 2)
        p.location = (cos(a) * D * 0.082, sin(a) * D * 0.082, NODE_Z)
        finish(p, bevel_w=0.008)
    mast_z0 = NODE_Z + NODE_R * 0.55
    finish(revolve('mod_mast', [(0, mast_z0), (0.07, mast_z0), (0.07, f(1.148)),
                                (0, f(1.148))], M['alu'], seg=12, parent=root), bevel_w=0.006)

    # ---- THE HIGH-GAIN ANTENNA, ON A YOKE, LOOKING FORWARD.
    #
    # Which way a dish points is the whole of what it is for, and this one was
    # aimed back down the ship: a paraboloid opens along its own +Z, and the
    # rotation applied to it swung that past the beam onto the hull it is
    # mounted on. The Hail Mary spends thirteen years talking to a transmitter
    # that is ASTERN of her for the outbound leg and ahead of her coming home,
    # so the dish is on a two-axis yoke — which is also why the boom, the
    # trunnion and the counterweight are worth drawing: a fixed dish would be a
    # decoration, a steerable one is the reason the mission returns an answer.
    # Standing it off far enough that the reflector clears the instrument
    # module: a 2.5 m dish hung a metre from a 1.7 m cylinder cuts into it.
    hga = group('mod_hga', root, loc=(D * 0.172, 0, f(1.000)), rot_z=0.0)
    finish(strut('mod_hga_boom', (-D * 0.102, 0, 0), (0, 0, 0), 0.075, M['alu'],
                 seg=10, parent=hga), bevel_w=0.008)
    trn = revolve('mod_hga_trunnion', [(0, -D * 0.026), (D * 0.030, -D * 0.026),
                                       (D * 0.030, D * 0.026), (0, D * 0.026)],
                  M['dirty'], seg=16, parent=hga)
    trn.rotation_euler = (pi / 2, 0, 0)
    finish(trn, bevel_w=0.010)
    # The dish proper, tipped 32 degrees off the thrust axis and OPENING
    # FORWARD. Rotating about +Y by theta takes the paraboloid's own +Z to
    # (sin theta, 0, cos theta), so a positive angle here is outboard and
    # ahead — the sign is the whole fix.
    yoke = empty('mod_hga_yoke', (0, 0, D * 0.030), hga)
    yoke.rotation_euler = (0, 0.56, 0)
    rD = D * 0.105
    dsh = revolve('mod_dish',
                  [(rD * (i / 10), rD * 0.30 * (i / 10) ** 2) for i in range(11)],
                  M['white'], seg=48, parent=yoke)
    finish(dsh, bevel_w=0.008)
    # The back of it — a dish has a ribbed rear face, and this one is seen from
    # behind for the whole outbound cruise. BEHIND is the operative word: the
    # reflector opens along +Z, so its structure lives at lower z than the
    # surface at the same radius. Laid out at the same z it is not backing the
    # dish at all, it is a set of spars across the aperture.
    def back_z(u):                       # the reflector's own surface, offset aft
        return rD * (0.30 * u * u - 0.075)
    finish(revolve('mod_dish_back',
                   [(0, back_z(0)), (rD * 0.36, back_z(0.36)), (rD * 0.74, back_z(0.74)),
                    (rD * 0.99, back_z(0.99))], M['dirty'], seg=48, parent=yoke),
           bevel_w=0.008)
    for k in range(8):
        ak = k / 8 * TAU
        finish(strut(f'mod_dish_rib{k}', (0, 0, back_z(0) - rD * 0.04),
                     (cos(ak) * rD * 0.95, sin(ak) * rD * 0.95, back_z(0.95)),
                     0.030, M['alu'], seg=6, parent=yoke), bevel_w=0.005)
    # Subreflector at the focus, on a tripod. Without it a dish reads as a bowl.
    sub = revolve('mod_dish_sub', [(0, rD * 0.40), (rD * 0.13, rD * 0.40),
                                   (rD * 0.10, rD * 0.46), (0, rD * 0.46)],
                  M['alu'], seg=20, parent=yoke)
    finish(sub, bevel_w=0.006)
    for k in range(3):
        ak = k / 3 * TAU + 0.4
        finish(strut(f'mod_dish_leg{k}',
                     (cos(ak) * rD * 0.86, sin(ak) * rD * 0.86, rD * 0.30 * 0.86 ** 2),
                     (cos(ak) * rD * 0.09, sin(ak) * rD * 0.09, rD * 0.40),
                     0.022, M['alu'], seg=6, parent=yoke), bevel_w=0.004)
    # RCS quads. Small detail that does more for realism than anything its size.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        pod = group(f'rcs{i}', root, loc=(cos(a) * r, sin(a) * r,
                                          hull_z0 + (hull_z1 - hull_z0) * 0.55), rot_z=a)
        finish(box(f'rcs{i}_body', (D * 0.05, D * 0.07, D * 0.07), (0, 0, 0),
                   M['dirty'], parent=pod), bevel_w=0.014)
        for k, s in enumerate((1, -1)):
            n = revolve(f'rcs{i}_nz{k}', [(D * 0.014, 0), (D * 0.022, D * 0.028)],
                        M['nozzle'], seg=12, parent=pod)
            n.rotation_euler = (0, 0, 0) if s > 0 else (pi, 0, 0)
            n.location = (0, 0, s * D * 0.036)
            finish(n, bevel_w=0.005)
    return hull_z0, hull_z1, hull_d


def build_structure(root, endP):
    """Radial struts, girth ties between adjacent tanks, and an aft truss tying
       all four drive blocks into ONE thrust structure: four drives on one plane
       are only one thrust structure if something actually ties them together."""
    def rp(i, r, z):
        a = i / 3 * TAU + pi / 2
        return (cos(a) * r, sin(a) * r, z)

    for z in (f(0.290), f(0.584)):
        for i in range(3):
            finish(strut(f'strut_r{i}_{z:.0f}', rp(i, D * 0.075, z),
                         rp(i, TR - TANK_R * 0.9, z), 0.09, M['alu'], parent=root),
                   bevel_w=0.010)
    for z in (f(0.330), f(0.620)):
        for i in range(3):
            finish(strut(f'strut_g{i}_{z:.0f}', rp(i, TR - TANK_R * 0.2, z),
                         rp(i + 1, TR - TANK_R * 0.2, z), 0.075, M['alu'], parent=root),
                   bevel_w=0.010)
    for i in range(3):
        p = rp(i, endP.x, AFT + DR * 2.0)
        for s in (-1, 1):
            finish(strut(f'truss_{i}_{s}', p, rp(i + s * 0.22, DR * 1.5, PLATE_Z - f(0.010)),
                         0.075, M['alu'], parent=root), bevel_w=0.010)
        finish(strut(f'truss_ring{i}', p, rp(i + 1, endP.x, AFT + DR * 2.0),
                     0.065, M['alu'], parent=root), bevel_w=0.010)


def build_appendages(root, hull_z0, hull_z1, hull_d):
    # ---- solar wings: two long flat panels, the widest thing on the ship.
    for si, side in enumerate((1, -1)):
        wing = group(f'wing{si}', root, loc=(0, 0, f(0.360)),
                     rot_z=0.0 if side > 0 else pi)
        nP, pw, ph = 7, D * 0.235, D * 0.40
        for k in range(nP):
            finish(box(f'wing{si}_p{k}', (pw, 0.06, ph),
                       (D * 0.46 + pw * (k + 0.5) * 1.02, 0, 0), M['solar'], parent=wing),
                   bevel_w=0.012)
            finish(box(f'wing{si}_rib{k}', (0.07, 0.11, ph),
                       (D * 0.46 + pw * k * 1.02, 0, 0), M['alu'], parent=wing),
                   bevel_w=0.010)
        sp = revolve(f'wing{si}_spar', [(0, 0), (0.10, 0), (0.10, D * 1.20), (0, D * 1.20)],
                     M['alu'], seg=12, parent=wing)
        sp.rotation_euler = (0, pi / 2, 0)
        sp.location = (D * 0.46, 0, 0)
        finish(sp, bevel_w=0.008)

    # ---- radiators. FIXED structure, not deployables: a ship under power for
    # thirteen years rejects heat continuously. They sit on the hull ABOVE the
    # tank tops, the only band of the spine with a clear horizon.
    for i in range(4):
        arm = group(f'rad{i}', root, loc=(0, 0, f(0.775)), rot_z=i / 4 * TAU + pi / 4)
        finish(box(f'rad{i}_panel', (D * 0.22, 0.07, f(0.085)),
                   (hull_d * 0.5 + D * 0.175, 0, 0), M['rad'], parent=arm), bevel_w=0.012)
        for k in range(7):
            finish(box(f'rad{i}_fin{k}', (D * 0.207, 0.10, 0.09),
                       (hull_d * 0.5 + D * 0.175, 0,
                        -f(0.085) / 2 + f(0.085) * (k + 0.5) / 7), M['soot'], parent=arm),
                   bevel_w=0.008)
        finish(strut(f'rad{i}_arm', (hull_d * 0.46, 0, 0),
                     (hull_d * 0.5 + D * 0.09, 0, 0), 0.07, M['alu'], parent=arm),
               bevel_w=0.008)

    # ---- four beetles on the spine below the pressure vessel. Next to the ship
    # they are deliberately tiny, and they are the only way an answer gets home.
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        b = group(f'beetle{i}', root, loc=(cos(a) * D * 0.105, sin(a) * D * 0.105,
                                           f(0.520)), rot_z=a)
        body = [(0, -D * 0.063)]
        for k in range(9):
            body.append((D * 0.028 * sin(k / 8 * pi / 2), -D * 0.063 + D * 0.028 * (1 - cos(k / 8 * pi / 2))))
        body.append((D * 0.028, D * 0.063))
        for k in range(1, 9):
            body.append((D * 0.028 * cos(k / 8 * pi / 2), D * 0.063 + D * 0.028 * sin(k / 8 * pi / 2)))
        finish(revolve(f'beetle{i}_body', body, M['dirty'], seg=32, parent=b), bevel_w=0.008)
        for k in range(3):
            finish(ring_on((0, 0, -D * 0.03 + k * D * 0.035), (0, 0, 1), D * 0.029,
                           D * 0.005, M['alu'], f'beetle{i}_r{k}', seg=32, minor=8,
                           parent=b), bevel_w=0.003)
        nz = revolve(f'beetle{i}_nz', [(D * 0.026, -D * 0.096), (D * 0.018, -D * 0.070)],
                     M['emitPlate'], seg=20, parent=b)
        finish(nz, bevel_w=0.005)


# ---------------------------------------------------------------------------
# OPTIMISE
# ---------------------------------------------------------------------------
def build_hailmary(_M):
    """
    The build proper. common.build() has already reset the scene; this file
    keeps its OWN palette rather than common's because the ship carries two
    materials nothing else has — the radiator white and the two emitter
    materials, whose strengths are tuned to the drive's own scale.
    """
    build_materials()

    root = stage('hm')
    spin_drive('gimbal_hm_0', DR, root, (0, 0, AFT), 'drv0')
    build_spine(root)
    path = bent_path(TR, f(0.679), f(0.245), D * 0.55, 16, D * 0.14)
    endP = None
    for i in range(3):
        _, endP = build_tank(i, root, path)
    build_structure(root, endP)
    hz0, hz1, hd = build_modules(root)
    build_appendages(root, hz0, hz1, hd)

    # The layout above is written around the aft plane at f(0.132); shift the
    # ship so the drives' exit plane is the origin. It goes on the STAGE ROOT,
    # which is a child of the group buildCraft positions — a stage builder must
    # not write to its own group's transform.
    root.location = (0, 0, -AFT)


build('hailmary', build_hailmary)
