# ---------------------------------------------------------------------------
# BLENDER BUILD LIBRARY — the primitives the Hail Mary is assembled from.
# ---------------------------------------------------------------------------
# Everything here generates a mesh from numbers rather than from a click, for
# the same reason the rest of this repo does: a shape you can re-derive is a
# shape you can argue with. The script is the model; the .glb is a build
# artifact.
#
# CONVENTIONS
#   · Blender is Z-UP and the glTF exporter converts to the Y-up that Three
#     expects, so the ship is built with its THRUST AXIS ALONG +Z and its nose
#     toward +Z. After conversion that is +Y, which is what vessel.js thrusts
#     along (BODY_FWD) and what buildCraft stacks along.
#   · z = 0 is the DRIVE EXIT PLANE, because y = 0 on a craft is whatever the
#     vehicle stands on and this one stands on its own exhaust.
#   · Metres. Blender's default unit, and the sim's.
# ---------------------------------------------------------------------------
import bpy, bmesh, math
from math import cos, sin, pi, hypot
from mathutils import Vector, Quaternion

TAU = 2 * pi


# ---------------------------------------------------------------------------
# SCENE
# ---------------------------------------------------------------------------
def reset_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    for block in (bpy.data.meshes, bpy.data.materials, bpy.data.objects):
        for item in list(block):
            block.remove(item)


def material(name, base, rough=0.6, metal=0.05, emit=None, emit_strength=1.0,
             alpha=1.0):
    """
    A Principled BSDF that survives the trip through glTF.

    METALNESS IS DELIBERATELY LOW, for exactly the reason the procedural
    materials keep it low: nothing in this renderer sets `scene.environment`,
    local space is lit by punctual lights only, and a PBR metal is entirely
    reflection with no diffuse term — so at metalness 0.8 it renders BLACK.
    Until there is an environment to sample, the base colour carries it.

    Backface culling is left OFF, which the exporter writes as doubleSided.
    Most of this vehicle is open shells — lathed reflectors, aft skirts, an
    interstage — and a single-sided shell has no inner wall.
    """
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    m.use_backface_culling = False
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = (*base, 1.0)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if emit is not None:
        b.inputs["Emission Color"].default_value = (*emit, 1.0)
        b.inputs["Emission Strength"].default_value = emit_strength
    if alpha < 1.0:
        b.inputs["Alpha"].default_value = alpha
        m.blend_method = 'BLEND'
    return m


# ---------------------------------------------------------------------------
# MESH CONSTRUCTION
# ---------------------------------------------------------------------------
def _obj(name, verts, faces, mat, parent=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate()
    me.update()
    if mat:
        me.materials.append(mat)
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    if parent:
        ob.parent = parent
    return ob


def revolve(name, profile, mat, seg=64, parent=None, close=False):
    """
    A surface of revolution about +Z from a profile of (radius, z) pairs.

    A profile point at r = 0 becomes a single apex vertex and a triangle fan,
    not a ring of coincident vertices — a degenerate quad ring shades as a
    black crease and no amount of smoothing removes it.
    """
    verts, faces = [], []
    rings = []                                   # index of each profile row
    for (r, z) in profile:
        if abs(r) < 1e-9:
            rings.append(('apex', len(verts)))
            verts.append((0.0, 0.0, z))
        else:
            rings.append(('ring', len(verts)))
            for j in range(seg):
                a = TAU * j / seg
                verts.append((r * cos(a), r * sin(a), z))
    for i in range(len(profile) - 1):
        k0, i0 = rings[i]
        k1, i1 = rings[i + 1]
        if k0 == 'apex' and k1 == 'ring':
            for j in range(seg):
                faces.append((i0, i1 + j, i1 + (j + 1) % seg))
        elif k0 == 'ring' and k1 == 'apex':
            for j in range(seg):
                faces.append((i0 + j, i1, i0 + (j + 1) % seg))
        elif k0 == 'ring' and k1 == 'ring':
            for j in range(seg):
                j2 = (j + 1) % seg
                faces.append((i0 + j, i0 + j2, i1 + j2, i1 + j))
    return _obj(name, verts, faces, mat, parent)


def frames(path):
    """
    PARALLEL-TRANSPORTED frames along a polyline, the same construction the
    procedural bent tube uses and for the same reason: a fresh 'up' per ring
    flips wherever the tangent passes near an axis and the tube turns inside
    out at that ring. Returns (tangents, normals, binormals).
    """
    n = len(path)
    P = [Vector(p) for p in path]
    tan = [(P[min(i + 1, n - 1)] - P[max(i - 1, 0)]).normalized() for i in range(n)]
    nrm = [Vector((0, 1, 0))]
    if abs(nrm[0].dot(tan[0])) > 0.9:
        nrm[0] = Vector((1, 0, 0))
    nrm[0] = (nrm[0] - tan[0] * nrm[0].dot(tan[0])).normalized()
    for i in range(1, n):
        q = tan[i - 1].rotation_difference(tan[i])
        nrm.append((q @ nrm[i - 1]).normalized())
    bi = [tan[i].cross(nrm[i]).normalized() for i in range(n)]
    return tan, nrm, bi


def tube(name, path, radius, mat, seg=32, parent=None, caps=(False, False),
         rfun=None):
    """
    A swept circular section along a polyline, on transported frames.

    `rfun(i, j, angle) -> radius` is what makes a PANEL LINE real geometry
    rather than a painted stripe: dipping the radius by a couple of percent
    over a couple of samples cuts a groove into the skin, and a groove reads as
    a joint between two barrel sections where a raised ring reads as a hoop
    strapped round the outside. Three.js has no equivalent — CylinderGeometry
    takes one radius — which is a large part of why this model is built here.
    """
    tan, nrm, bi = frames(path)
    P = [Vector(p) for p in path]
    verts, faces = [], []
    for i in range(len(P)):
        for j in range(seg):
            a = TAU * j / seg
            r = rfun(i, j, a) if rfun else radius
            v = P[i] + nrm[i] * (cos(a) * r) + bi[i] * (sin(a) * r)
            verts.append(tuple(v))
    for i in range(len(P) - 1):
        for j in range(seg):
            j2 = (j + 1) % seg
            a = i * seg + j; b = i * seg + j2
            faces.append((a, b, b + seg, a + seg))
    if caps[0]:
        faces.append(tuple(range(seg - 1, -1, -1)))
    if caps[1]:
        o = (len(P) - 1) * seg
        faces.append(tuple(range(o, o + seg)))
    return _obj(name, verts, faces, mat, parent)


def ring_on(path_pt, tangent, r, tube_r, mat, name, seg=32, minor=10, parent=None):
    """A torus lying in the plane normal to `tangent` — a frame or a collar."""
    t = Vector(tangent).normalized()
    up = Vector((0, 0, 1))
    if abs(t.dot(up)) > 0.95:
        up = Vector((1, 0, 0))
    u = (up - t * up.dot(t)).normalized()
    v = t.cross(u).normalized()
    c = Vector(path_pt)
    verts, faces = [], []
    for i in range(seg):
        a = TAU * i / seg
        centre = c + u * (cos(a) * r) + v * (sin(a) * r)
        radial = (u * cos(a) + v * sin(a))
        for j in range(minor):
            b = TAU * j / minor
            verts.append(tuple(centre + radial * (cos(b) * tube_r) + t * (sin(b) * tube_r)))
    for i in range(seg):
        i2 = (i + 1) % seg
        for j in range(minor):
            j2 = (j + 1) % minor
            faces.append((i * minor + j, i * minor + j2, i2 * minor + j2, i2 * minor + j))
    return _obj(name, verts, faces, mat, parent)


def fin(name, profile, angle, out, thick, mat, parent=None, r_pad=0.01):
    """
    A stiffener standing OFF a surface of revolution, following its profile.

    A cooling rib on a bell is not a box: the wall it is welded to is curved, so
    a straight box either buries itself in the wall at one end or floats off it
    at the other. This one is a box-section beam swept along the same (r, z)
    profile the wall was lathed from, which is what a real one is.
    """
    a = angle
    ca, sa = cos(a), sin(a)
    tx, ty = -sa * thick * 0.5, ca * thick * 0.5      # tangential half-thickness
    verts, faces = [], []
    for (r, z) in profile:
        ri, ro = r + r_pad, r + r_pad + out
        for rr in (ri, ro):
            verts.append((rr * ca + tx, rr * sa + ty, z))
            verts.append((rr * ca - tx, rr * sa - ty, z))
    n = len(profile)
    for i in range(n - 1):
        a0, b0 = i * 4, (i + 1) * 4
        # 0,1 inner pair  2,3 outer pair
        faces += [(a0 + 0, a0 + 2, b0 + 2, b0 + 0),      # +t face
                  (a0 + 3, a0 + 1, b0 + 1, b0 + 3),      # -t face
                  (a0 + 2, a0 + 3, b0 + 3, b0 + 2),      # outer edge
                  (a0 + 1, a0 + 0, b0 + 0, b0 + 1)]      # inner edge
    faces += [(0, 1, 3, 2), ((n - 1) * 4 + 2, (n - 1) * 4 + 3, (n - 1) * 4 + 1, (n - 1) * 4 + 0)]
    return _obj(name, verts, faces, mat, parent)


def box(name, size, loc, mat, rot=None, parent=None):
    sx, sy, sz = (s * 0.5 for s in size)
    verts = [(-sx, -sy, -sz), (sx, -sy, -sz), (sx, sy, -sz), (-sx, sy, -sz),
             (-sx, -sy, sz), (sx, -sy, sz), (sx, sy, sz), (-sx, sy, sz)]
    faces = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4),
             (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    ob = _obj(name, verts, faces, mat, parent)
    ob.location = loc
    if rot:
        ob.rotation_euler = rot
    return ob


def strut(name, p1, p2, r, mat, seg=8, parent=None):
    """A beam between two points. Structure is most of what makes a ship of
       parts read as one object rather than as parts."""
    a, b = Vector(p1), Vector(p2)
    d = b - a
    L = d.length
    if L < 1e-6:
        return None
    ob = revolve(name, [(0, 0), (r, 0), (r, L), (0, L)], mat, seg=seg, parent=parent)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(d.normalized())
    ob.location = a
    return ob


# ---------------------------------------------------------------------------
# FINISHING — the part a procedural Three.js build cannot do
# ---------------------------------------------------------------------------
def bevel(ob, width=0.03, segments=2, angle=40.0, clamp=True):
    """
    A BEVEL is the single highest-value thing available here. A perfectly sharp
    edge catches no specular highlight at all, so a hard-surface model built
    from primitives reads as flat shaded cardboard however good the silhouette
    is; two segments of 3 cm is enough to put a bright line down every corner
    and is what makes machined metal look machined.
    """
    m = ob.modifiers.new("bevel", 'BEVEL')
    m.width = width
    m.segments = segments
    m.limit_method = 'ANGLE'
    m.angle_limit = math.radians(angle)
    m.use_clamp_overlap = clamp
    m.harden_normals = True
    return m


def smooth(ob, angle=35.0):
    """
    Shade smooth with an angle split, so a 72-sided cylinder reads as round and
    the flat plate on the end of it still reads as flat.

    Done by marking sharp edges rather than by `use_auto_smooth`, which was
    removed in Blender 4.1 — from there on smooth shading plus a sharp_edge
    attribute IS the auto-smooth, and it is also what the glTF exporter reads.
    """
    me = ob.data
    for p in me.polygons:
        p.use_smooth = True
    bm = bmesh.new()
    bm.from_mesh(me)
    thr = math.radians(angle)
    for e in bm.edges:
        if len(e.link_faces) == 2:
            try:
                e.smooth = e.calc_face_angle() <= thr
            except ValueError:
                e.smooth = False
        else:
            e.smooth = False
    bm.to_mesh(me)
    bm.free()
    return ob


def finish(ob, bevel_w=0.03, seg=2, angle=40.0, smooth_angle=35.0):
    """Bevel then smooth — the standard treatment for a hard-surface part."""
    if ob is None:
        return None
    smooth(ob, smooth_angle)
    bevel(ob, bevel_w, seg, angle)
    return ob


def empty(name, loc, parent=None):
    """
    A pivot. It carries NOTHING but a position and an identity rotation,
    because craftmodel's update() drives these by ASSIGNING Euler angles and
    assigning a rotation wipes whatever orientation was set at build time.
    """
    ob = bpy.data.objects.new(name, None)
    ob.empty_display_size = 0.5
    bpy.context.collection.objects.link(ob)
    if parent:
        ob.parent = parent
    ob.location = loc
    return ob


def group(name, parent=None, loc=(0, 0, 0), rot_z=0.0):
    ob = empty(name, loc, parent)
    ob.rotation_euler = (0, 0, rot_z)
    return ob


# ===========================================================================
# THE REST OF THE SET — primitives the other eight vehicles are built from.
# ---------------------------------------------------------------------------
# AXES, once, because every sign error in this file is the same sign error.
# The exporter converts Blender Z-up to the Y-up Three wants, which means
#
#       Blender +X  ->  Three +X          (span, wings, left/right)
#       Blender +Z  ->  Three +Y          (the stack axis: nose is +Z here)
#       Blender +Y  ->  Three -Z          (so the vehicle's UP is Blender -Y)
#
# That last one is the trap. Anything with a top and a bottom — a lofted
# fuselage, a wing section, a payload bay door — is written in the procedural
# builder with its upper surface on +Z, and porting it here without the flip
# gives a Shuttle flying upside down with its tiles facing the sky.
#
# So `loft` and `wing` below take their vertical terms as UP-POSITIVE and do the
# negation internally: a section's `cz` and a wing's top surface mean the same
# thing here as they do in sim/flight/craftmodel.js, and transfer verbatim.
# ===========================================================================

def lathe(name, profile, mat, seg=48, t0=0.0, t1=TAU, parent=None, caps=False):
    """
    `revolve` with an angular range, for the half-shells: a fairing splits into
    two 180-degree pieces, and an orbiter's white back and black belly are one
    loft swept twice. A partial sweep is left OPEN at the ends unless `caps`,
    because a fairing half really is an open shell.
    """
    closed = abs((t1 - t0) - TAU) < 1e-9
    ring = seg if closed else seg + 1
    verts, faces = [], []
    for (r, z) in profile:
        for j in range(ring):
            a = t0 + (t1 - t0) * (j / seg)
            verts.append((r * cos(a), r * sin(a), z))
    for i in range(len(profile) - 1):
        for j in range(seg):
            j2 = (j + 1) % ring if closed else j + 1
            a0 = i * ring + j
            b0 = i * ring + j2
            faces.append((a0, b0, b0 + ring, a0 + ring))
    if caps and not closed:
        for i in range(len(profile) - 1):
            a0 = i * ring
            faces.append((a0, a0 + ring, a0 + ring + ring - 1, a0 + ring - 1))
    return _obj(name, verts, faces, mat, parent)


def cyl(name, r0, r1, z0, z1, mat, seg=48, parent=None, t0=0.0, t1=TAU):
    """A cone frustum from (r0, z0) to (r1, z1). Open at both ends — almost
       everything on a rocket butts onto something else."""
    return lathe(name, [(r0, z0), (r1, z1)], mat, seg, t0, t1, parent)


def tank(name, L, D, mat, dome_top=0.12, dome_bot=0.06, seg=48, parent=None,
         z0=0.0):
    """
    A tank barrel with domed ends, as a lathe so the domes are real geometry.

    A stage that carries a nose or an interstage passes dome_top=0: the lathe's
    dome curves away underneath whatever sits on it and leaves a pinched gap at
    the joint, which is what read as odd spacing up the Saturn V.
    """
    r = D / 2
    hb, ht = r * dome_bot, r * dome_top
    pts = [(0.0, z0)]
    for i in range(1, 7):
        a = (i / 6) * pi / 2
        pts.append((r * sin(a), z0 + hb * (1 - cos(a))))
    pts.append((r, z0 + L - ht))
    for i in range(1, 7):
        a = (i / 6) * pi / 2
        pts.append((r * cos(a), z0 + L - ht + ht * sin(a)))
    return revolve(name, pts, mat, seg=seg, parent=parent)


def bell(name, exit_d, mat, ratio=3.6, chamber=True, seg=32, parent=None,
         loc=(0, 0, 0)):
    """
    A bell nozzle as a real contour: a converging throat, then a parabolic (Rao)
    expansion. The shape carries information — an 80% Rao bell is visibly not a
    cone, and the exit-to-throat ratio is what tells you at a glance whether an
    engine is a sea-level or a vacuum design.

    The ORIGIN IS THE THROAT and the exit hangs BELOW it, matching the
    procedural bell, because the origin is where the gimbal pivot goes and
    spaceflight.js parents the plume to the pivot.
    """
    re = exit_d / 2
    rt = re / math.sqrt(ratio)
    L = re * 2.6
    pts = []
    if chamber:
        pts += [(rt * 1.9, -L * 0.42), (rt * 1.9, -L * 0.26), (rt * 1.25, -L * 0.10)]
    pts.append((rt, 0.0))
    for i in range(1, 11):
        u = i / 10
        pts.append((rt + (re - rt) * (u ** 0.62), L * u))
    ob = revolve(name, pts, mat, seg=seg, parent=parent)
    ob.rotation_euler = (pi, 0, 0)          # open end downward, i.e. -Z
    ob.location = loc
    return ob


def ogive(name, L, D, mat, seg=48, parent=None, z0=0.0):
    """A tangent ogive — the curve a real fairing is struck on, visibly fuller
       than the half-ellipse a naive lathe gives."""
    r = D / 2
    rho = (r * r + L * L) / (2 * r)
    pts = []
    for i in range(15):
        z = (i / 14) * L
        # Full radius at the BASE: the z term is measured from the base, not the
        # apex. The other way round the curve turns inside out and every nose on
        # the vehicle renders as a funnel.
        pts.append((max(math.sqrt(max(rho * rho - z * z, 0)) - rho + r, 1e-3), z0 + z))
    return revolve(name, pts, mat, seg=seg, parent=parent)


def sphere_cone(name, D, nose_r, half_deg, mat, seg=48, parent=None):
    """
    A spherical nose cap blended into a straight flank, closed by a shoulder
    radius. Every Mars lander since Viking has flown this at 70 degrees, and
    BLUNT is the whole point: a sharp body puts the shock on the skin and the
    vehicle absorbs the heat, a blunt one stands the shock off ahead of itself
    so the gas heats instead.

    WHICH WAY IT POINTS IS THE WHOLE CONTRACT, so it is fixed here rather than
    left to a caller's rotation: the apex is the LOWEST point and the shoulder
    sits exactly at z = 0. An entering vehicle flies nose-first into the flow,
    the flow comes from below, and the shoulder is the plane the backshell bolts
    to — so a caller places this at the joint and cannot get the sense wrong.
    An inverted heat shield is not a cosmetic error; it is a shape that would
    kill the vehicle it is supposed to protect.
    """
    R = D / 2
    half = math.radians(half_deg)
    shoulder = R * 0.06
    tA = pi / 2 - half
    pts = []
    for i in range(11):
        a = (i / 10) * tA
        pts.append((nose_r * sin(a), nose_r * (1 - cos(a))))
    xT, zT = nose_r * sin(tA), nose_r * (1 - cos(tA))
    xF = R - shoulder * cos(half)
    zF = zT + (xF - xT) / math.tan(half)
    pts.append((xF, zF))
    for i in range(1, 6):
        a = half + (i / 5) * (pi / 2 - half)
        pts.append((xF + shoulder * (cos(a) - cos(half)),
                    zF + shoulder * (sin(a) - sin(half))))
    # Shift so the shoulder — the last point, the widest — is the z = 0 plane.
    top = pts[-1][1]
    pts = [(r, z - top) for (r, z) in pts]
    return revolve(name, pts, mat, seg=seg, parent=parent)


def naca(u, t):
    """NACA symmetric thickness distribution, as a fraction of chord."""
    return 5 * t * (0.2969 * math.sqrt(u) - 0.1260 * u - 0.3516 * u * u
                    + 0.2843 * u ** 3 - 0.1015 * u ** 4)


def loft(name, sections, mat, seg=32, t0=0.0, t1=TAU, parent=None):
    """
    A LOFTED HULL — the one shape a lathe cannot give you.

    `sections` are cross-sections along +Z, each `{z, w, h, cz, n}`: half-width
    in X, half-height, the section's centreline offset, and a superellipse
    exponent — n = 2 is an ellipse, n = 4 the rounded square an aircraft
    fuselage actually is.

    `h`, `cz` and the angle are all UP-POSITIVE, i.e. +h is toward the vehicle's
    back and is written into Blender -Y: see the axis note at the top of this
    section. That is what lets a section list be moved here from craftmodel.js
    without touching a single sign.

    An orbiter is not a body of revolution. Its width and height change
    independently along its length and its section is square-ish, so a cylinder
    is not a poor approximation of it — it is a different object.
    """
    closed = abs((t1 - t0) - TAU) < 1e-9
    ring = seg if closed else seg + 1
    verts, faces = [], []
    for c in sections:
        n = c.get('n', 2.0)
        e = 2.0 / n
        w, h = c.get('w', 0.0), c.get('h', 0.0)
        cz, z = c.get('cz', 0.0), c['z']
        for j in range(ring):
            t = t0 + (t1 - t0) * (j / seg)
            ct, st = cos(t), sin(t)
            x = w * math.copysign(abs(ct) ** e, ct)
            up = h * math.copysign(abs(st) ** e, st) + cz
            verts.append((x, -up, z))          # up is -Y
    for s in range(len(sections) - 1):
        for j in range(seg):
            j2 = (j + 1) % ring if closed else j + 1
            a0 = s * ring + j
            b0 = s * ring + j2
            faces.append((a0, a0 + ring, b0 + ring, b0))
    return _obj(name, verts, faces, mat, parent)


def wing(name, stations, mat_top, mat_bot, n_chord=14, sign=1, parent=None):
    """
    A WING from real spanwise stations, each `{x, zLE, chord, thick, cz}`: where
    the leading edge is at that station, how long the chord is there, and how
    thick the section is. A kinked planform — the orbiter's double delta — is
    just a station at the kink.

    The section is an airfoil rather than a rectangle because a flat plate has
    no leading edge, and on a re-entry wing the leading edge is the part you
    look at: it is the hottest structure on the vehicle and a different colour
    from everything around it.

    Two meshes come back, top and bottom, because a Shuttle wing is white above
    and black below and that split IS the shape's read. `cz` is up-positive, as
    everywhere else here.
    """
    out = []
    for side, mat in ((+1, mat_top), (-1, mat_bot)):
        verts, faces = [], []
        for st in stations:
            for i in range(n_chord + 1):
                u = i / n_chord
                up = side * naca(u, st['thick']) * st['chord'] + st.get('cz', 0.0)
                verts.append((sign * st['x'], -up, st['zLE'] - u * st['chord']))
        R = n_chord + 1
        flip = (side * sign > 0)
        for s in range(len(stations) - 1):
            for i in range(n_chord):
                a = s * R + i
                b = a + 1
                # Mirroring the panel to the other wing reverses the winding, so
                # `sign` has to flip it back or the left wing is inside-out.
                faces.append((a, b, b + R) if flip else (a, b + R, b))
                faces.append((a, b + R, a + R) if flip else (a, a + R, b + R))
        out.append(_obj(f'{name}_{"t" if side > 0 else "b"}', verts, faces, mat, parent))
    return out


def torus_z(name, r, tube_r, z, mat, seg=40, minor=8, parent=None):
    """A hoop lying in the XY plane at height z — a field joint, a separation
       band, a stiffening frame."""
    return ring_on((0, 0, z), (0, 0, 1), r, tube_r, mat, name, seg, minor, parent)


def ball(name, r, loc, mat, seg=20, rings=12, parent=None):
    pts = []
    for i in range(rings + 1):
        a = pi * i / rings
        pts.append((r * sin(a), -r * cos(a)))
    ob = revolve(name, pts, mat, seg=seg, parent=parent)
    ob.location = loc
    return ob


def disc(name, r, z, mat, seg=32, parent=None):
    verts = [(0.0, 0.0, z)] + [(r * cos(TAU * j / seg), r * sin(TAU * j / seg), z)
                               for j in range(seg)]
    faces = [(0, 1 + j, 1 + (j + 1) % seg) for j in range(seg)]
    return _obj(name, verts, faces, mat, parent)


def dish(name, r, mat, seg=28, parent=None):
    """A parabolic high-gain antenna. Shallow — a deep one reads as a bowl."""
    pts = [(r * (i / 8), r * 0.34 * (i / 8) ** 2) for i in range(9)]
    return revolve(name, pts, mat, seg=seg, parent=parent)


def lattice(name, h, w_bot, w_top, mat, parent=None):
    """
    An open lattice tower. The Apollo escape tower is MOSTLY AIR, and drawing it
    as a solid cone is what made the old Saturn V's nose read as a crayon — it
    is the most distinctive nose in spaceflight and its distinctiveness is that
    you can see through it.
    """
    g = empty(name, (0, 0, 0), parent)
    t = w_bot * 0.055
    for i in range(4):
        a = i / 4 * TAU + pi / 4
        strut(f'{name}_leg{i}',
              (cos(a) * w_bot / 2, sin(a) * w_bot / 2, 0.0),
              (cos(a) * w_top / 2, sin(a) * w_top / 2, h), t, mat, seg=6, parent=g)
    for k in range(1, 4):
        z = h * k / 4
        w = w_bot + (w_top - w_bot) * (k / 4)
        # Four bracing members per level, corner to corner.
        for i in range(4):
            a0 = i / 4 * TAU + pi / 4
            a1 = (i + 1) / 4 * TAU + pi / 4
            strut(f'{name}_br{k}_{i}',
                  (cos(a0) * w / 2, sin(a0) * w / 2, z),
                  (cos(a1) * w / 2, sin(a1) * w / 2, z), t * 0.7, mat, seg=5, parent=g)
    return g


def grid_fin(name, size, mat, parent=None):
    """An actual waffle, because that is what makes it recognisable at any
       distance you ever see one from."""
    g = empty(name, (0, 0, 0), parent)
    t = size * 0.06
    box(f'{name}_frame', (size, size * 0.75, t), (0, 0, 0), mat, parent=g)
    for i in range(-2, 3):
        box(f'{name}_a{i}', (t * 0.7, size * 0.75, size * 0.42),
            (i * size / 5, 0, size * 0.21), mat, parent=g)
        box(f'{name}_b{i}', (size, t * 0.7, size * 0.42),
            (0, i * size * 0.15, size * 0.21), mat, parent=g)
    return g


def landing_leg(name, length, foot_r, mat, mat2, parent=None, probe=0.0):
    """
    A landing leg: a primary strut with its shock cartridge, a pair of
    secondary struts, a footpad on a ball joint, and optionally the contact
    probe hanging under it.

    Built straight DOWN from the hinge, along -Z, with the footpad's bearing
    face at exactly z = -length. The caller sets the deployment angle — see the
    pre-cant note in falcon9.py, which is where the sign is derived — so this
    primitive must not carry one of its own.

    The secondaries splay in +/-Y, sideways in the leg's OWN frame. That is
    where they are on both the Apollo gear and the Falcon's, and it is the only
    arrangement that does not depend on which way the leg happens to be swung:
    a brace placed in X is either inside the primary or out in space depending
    on the cant, which is what the single rotated tube here used to do.
    """
    g = empty(name, (0, 0, 0), parent)
    # The primary, with the crushable-honeycomb cartridge at the bottom of it —
    # a visibly fatter section, and the part that actually absorbs the landing.
    revolve(f'{name}_strut', [(length * 0.050, 0), (length * 0.042, -length * 0.58),
                              (length * 0.066, -length * 0.63),
                              (length * 0.066, -length * 0.955),
                              (length * 0.040, -length * 0.975)],
            mat, seg=12, parent=g)
    # The ball joint, so the pad can lie flat on a slope instead of on one edge.
    ball(f'{name}_joint', length * 0.052, (0, 0, -length * 0.972), mat2,
         seg=12, rings=7, parent=g)
    # The footpad: a shallow dish, closed top and bottom.
    revolve(f'{name}_pad', [(0, -length + foot_r * 0.16), (foot_r * 0.55, -length + foot_r * 0.16),
                            (foot_r, -length), (foot_r * 0.94, -length - foot_r * 0.13),
                            (0, -length - foot_r * 0.13)],
            mat, seg=20, parent=g)
    # The secondaries, off the hinge line out to the cartridge.
    for s in (-1, 1):
        strut(f'{name}_sec{"p" if s > 0 else "m"}',
              (0, s * length * 0.135, length * 0.02),
              (0, s * length * 0.028, -length * 0.60),
              length * 0.024, mat2, seg=8, parent=g)
    # The contact probe, where there is one: a wire under the pad, and the thing
    # that actually ended the Apollo landings — "contact light" is a probe
    # touching, not a footpad.
    if probe > 0:
        revolve(f'{name}_probe', [(length * 0.010, -length), (length * 0.010, -length - probe)],
                     mat2, seg=6, parent=g)
        revolve(f'{name}_probetip', [(0, -length - probe), (length * 0.026, -length - probe),
                                     (0, -length - probe - length * 0.03)],
                mat2, seg=8, parent=g)
    return g


def solar_array(name, span, chord, mat_panel, mat_rib, parent=None):
    g = empty(name, (0, 0, 0), parent)
    box(f'{name}_panel', (span, chord, 0.05), (0, 0, 0), mat_panel, parent=g)
    for i in range(1, 6):
        box(f'{name}_rib{i}', (0.04, chord, 0.07),
            (-span / 2 + span * i / 6, 0, 0), mat_rib, parent=g)
    return g


def radiator(name, w, h, mat, mat_line, parent=None):
    g = empty(name, (0, 0, 0), parent)
    box(f'{name}_panel', (w, h, 0.04), (0, 0, 0), mat, parent=g)
    for i in range(7):
        box(f'{name}_l{i}', (w * 0.94, h * 0.02, 0.06),
            (0, -h / 2 + h * (i + 0.5) / 7, 0), mat_line, parent=g)
    return g


def rcs_ring(name, D, z, mat, mat_nozzle, n=4, parent=None):
    """
    A ring of RCS thruster quads. Small detail that does more for realism than
    anything else its size — it is the thing that says the vehicle is controlled.
    """
    g = empty(name, (0, 0, z), parent)
    for i in range(n):
        a = i / n * TAU
        pod = empty(f'{name}_p{i}', (cos(a) * D / 2, sin(a) * D / 2, 0), g)
        pod.rotation_euler = (0, 0, a)
        box(f'{name}_b{i}', (D * 0.07, D * 0.07, D * 0.05), (0, 0, 0), mat, parent=pod)
        for k in (0, 1):
            nz = revolve(f'{name}_n{i}_{k}',
                         [(0, 0), (D * 0.014, 0), (D * 0.006, D * 0.03)],
                         mat_nozzle, seg=8, parent=pod)
            nz.location = (0, 0, (D * 0.035) if k else -(D * 0.035))
            nz.rotation_euler = (0, 0, 0) if k else (pi, 0, 0)
    return g


def stripe(name, D, z, h, mat, seg=48, parent=None, t0=0.0, t1=TAU, grow=1.004):
    """A painted band, standing a hair proud of the skin it is on. `grow` is not
       optional: coincident surfaces z-fight, and a z-fighting stripe flickers."""
    return cyl(name, D / 2 * grow, D / 2 * grow, z, z + h, mat, seg, parent, t0, t1)
