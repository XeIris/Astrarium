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
