# ---------------------------------------------------------------------------
# COMMON — the material set, the optimiser and the exporter, shared by every
# authored vehicle.
# ---------------------------------------------------------------------------
# The .py files beside this one are the MODELS. This file is what they all
# agree on, and it exists for one reason above the others: a vehicle whose
# authored mesh is a different colour from the procedural fallback it replaces
# is a vehicle that changes appearance depending on whether a build has been
# run. So the palette here is craftMaterials() in sim/flight/craftmodel.js,
# converted rather than re-picked — see srgb() below.
#
# NAMING IS AN INTERFACE. craftassets.js binds moving parts by name, so the
# prefixes in NODE_PREFIXES are load-bearing: rename one here and the legs stop
# deploying, silently, with no error anywhere.
# ---------------------------------------------------------------------------
import math
import bpy, os, sys
from mathutils import Matrix

from lib import reset_scene, material, empty


# ---------------------------------------------------------------------------
# PALETTE
# ---------------------------------------------------------------------------
def srgb(hex_):
    """
    An sRGB hex triple as LINEAR floats, which is what Blender's Base Color
    wants and what the glTF exporter writes.

    This conversion is the whole reason the palette is not hand-picked. Three
    reads `new MeshStandardMaterial({ color: 0xe8e8ea })` as sRGB and converts
    it on the way in (ColorManagement has been on by default since r152), so
    writing 0.91 into Blender because the hex says 0xe8 gives a material that is
    visibly lighter than the fallback it is standing in for. Eyeballing the
    difference across fifteen materials is exactly the kind of drift that makes
    an authored asset stop matching the code it replaced.
    """
    r, g, b = ((hex_ >> 16) & 255) / 255, ((hex_ >> 8) & 255) / 255, (hex_ & 255) / 255
    f = lambda c: c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    return (f(r), f(g), f(b))


M = {}

# (name, colour, roughness, metalness) — mirroring craftMaterials() exactly.
# METALNESS IS DELIBERATELY LOW, and it is not an oversight: nothing in this
# renderer sets scene.environment, local space is lit by punctual lights only,
# and a PBR metal is entirely reflection with no diffuse term — so at metalness
# 0.8 it renders BLACK. Until there is an environment to sample, the base
# colour has to carry the material.
_PALETTE = [
    ('white',   0xe8e8ea, 0.72, 0.04),
    ('dirty',   0xb9b9bd, 0.85, 0.05),
    ('black',   0x1b1b1f, 0.62, 0.10),
    ('soot',    0x33333a, 0.95, 0.02),
    ('steel',   0xc4ccd4, 0.30, 0.34),
    ('alu',     0xa9b0b7, 0.46, 0.26),
    ('gold',    0xd8a13a, 0.52, 0.38),
    ('foam',    0xc2663a, 0.95, 0.02),
    ('tiles',   0x24242a, 0.88, 0.03),
    ('ablator', 0x6b5344, 0.94, 0.02),
    ('solar',   0x21306a, 0.38, 0.22),
    ('nozzle',  0x6e6b66, 0.42, 0.32),
    ('hot',     0x3a322c, 0.56, 0.26),
    ('glass',   0x16242e, 0.14, 0.24),
    ('red',     0xa02a22, 0.70, 0.05),
]


def build_materials():
    """Fill M. Called after reset_scene(), which drops the previous datablocks."""
    M.clear()
    for name, hexv, rough, metal in _PALETTE:
        M[name] = material(name, srgb(hexv), rough, metal)
    # An emitter has to be lit BY ITSELF, and brightly. An engine bell's throat
    # or a drive face points aft, away from every light in the scene, so it
    # renders black however it is coloured. The pipeline is HDR and expects
    # emitters well above 1.0 — a value that "looks right as hex" lands back at
    # almost nothing once ACES has had it.
    M['emitPlate'] = material('emitPlate', srgb(0x4a4744), 0.52, 0.18,
                              emit=srgb(0x8c3418), emit_strength=1.4)
    M['emitCell'] = material('emitCell', srgb(0x2a1410), 0.45, 0.10,
                             emit=srgb(0xff6a30), emit_strength=3.2)
    return M


# ---------------------------------------------------------------------------
# THE NAME INTERFACE
# ---------------------------------------------------------------------------
# Every one of these is a node craftmodel's update() drives, or the stage
# boundary buildCraft positions. They are JOIN BOUNDARIES for the optimiser
# below — a mesh may only be merged with another mesh under the same node, or
# a leg would be welded to the body it is supposed to swing away from.
#
# Blender object names are unique SCENE-WIDE, so these carry the stage key:
# two stages both wanting `gimbal_0` would silently become `gimbal_0` and
# `gimbal_0.001`, and the second would never be found. `gimbal_sic_0` cannot
# collide, and sorting by name keeps the bind order deterministic.
NODE_PREFIXES = ('stage_', 'gimbal_', 'leg_', 'fin_', 'array_', 'flap_', 'half_')


def is_node(ob):
    return ob.type == 'EMPTY' and ob.name.startswith(NODE_PREFIXES)


def nearest_node(ob):
    """The join bucket a mesh belongs to: its closest node ancestor, or None."""
    p = ob.parent
    while p is not None:
        if is_node(p):
            return p
        p = p.parent
    return None


def stage(key, parent=None, loc=(0, 0, 0)):
    """A stage root. buildCraft positions the group this ends up inside, so the
       stage is built with its own datum — whatever it stands on — at z = 0."""
    return empty(f'stage_{key}', loc, parent)


def ring_radius(n, exit_d, centre=False, margin=1.08):
    """
    The smallest radius a ring of n bells of this exit diameter can stand on —
    and, with `centre`, one that also clears an engine on the axis.

    A CLUSTER'S SPACING IS SET BY ITS ENGINE, not by a fraction of the stage.
    Written as `D * 0.30` it is right for nothing in particular: on an S-IC that
    is 3.02 m for four 3.53 m F-1s, so each outboard engine was drawn half a
    metre INSIDE the centre one, and on a Falcon the eight outer Merlins were
    0.07 m into their neighbours. Solving it also gets the real numbers for
    free — four F-1s land on a 3.67 m ring, which is where they are, and which
    is why an S-IC's bells hang outside the line of the tank above them.

    The caller may still ask for more (a Saturn V's J-2s are further out than
    they need to be), so this is a floor and not an answer. The 8 per cent is
    DAYLIGHT rather than slack: bells a centimetre apart read as touching, and
    the three-ring Super Heavy cluster is spaced to the same fraction.
    """
    r = exit_d * margin / (2 * math.sin(math.pi / n))
    return max(r, exit_d * margin if centre else 0.0)


def hinge(name, loc, azim=0.0, parent=None):
    """
    A DRIVEN NODE, with its azimuth carried outside it. Returns (node, mount):
    hang the moving part on `node` and the fixed structure around it on `mount`.

    update() deploys a leg, a fin or a flap by ASSIGNING Three's rotation.z —
    into an Euler triple Three decomposed from the quaternion glTF actually
    stores, because glTF has no Eulers. For a node whose only rotation is about
    Blender Z that decomposition comes back as (0, azimuth, 0) and the
    assignment means what it looks like. Past ninety degrees it does not: the
    XYZ solver returns the equally valid (pi, pi - azimuth, pi), the assignment
    overwrites a z term that was carrying half the rotation, and the part swings
    somewhere arbitrary. On the Apollo gear that was exactly one leg of the four
    — the one at 180 degrees — deploying UPWARD through the ascent stage while
    its three neighbours came down correctly, which is the kind of asymmetry
    that looks like a modelling slip and is actually a frame bug.

    The procedural build never meets this because it sets `hinge.rotation.y`
    itself and the Euler is whatever it wrote. An authored node has to earn it,
    so the azimuth goes on a mount and the driven node is left at IDENTITY.
    That is the rule the gimbal pivots already follow, one level up, and for the
    same reason: the parent owns the pose the child is not allowed to keep.
    """
    m = empty(f'mount_{name}', loc, parent)
    m.rotation_euler = (0, 0, azim)
    return empty(name, (0, 0, 0), m), m


# ---------------------------------------------------------------------------
# OPTIMISE
# ---------------------------------------------------------------------------
def optimise():
    """
    Apply every modifier, then JOIN THE MESHES BY MATERIAL, within each node.

    Blender is happy to export six hundred objects and GLTFLoader is happy to
    read them, but six hundred meshes is six hundred DRAW CALLS every frame for
    a body that never moves relative to itself — and this is drawn in a second
    pass on top of a whole orrery. The Hail Mary went 612 → 34 on this.

    The bucketing is what keeps it honest. A mesh is joined only with meshes
    under the SAME node, so a landing leg stays a landing leg and a stage stays
    separable; without that the optimiser would weld the Falcon's legs to its
    tank and the deploy would move nothing.

    Bevels have to be baked HERE rather than left to the exporter's
    export_apply: once meshes are joined there is no per-object modifier stack
    left to apply, and the exporter would write the unbevelled cages.
    """
    vl = bpy.context.view_layer
    bpy.ops.object.select_all(action='DESELECT')

    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not meshes:
        return

    # Bake modifiers on everything at once — one convert is far cheaper than
    # one per object, and it does not disturb parenting.
    for ob in meshes:
        ob.select_set(True)
    vl.objects.active = meshes[0]
    bpy.ops.object.convert(target='MESH')
    bpy.ops.object.select_all(action='DESELECT')

    buckets = {}
    for ob in [o for o in bpy.context.scene.objects if o.type == 'MESH']:
        node = nearest_node(ob)
        mat = ob.data.materials[0].name if ob.data.materials else '_none'
        buckets.setdefault((node.name if node else '', mat), []).append(ob)

    for (node_name, mat), objs in buckets.items():
        node = bpy.data.objects.get(node_name) if node_name else None
        label = f'm_{node_name or "root"}_{mat}'
        # Join into a FRESH object sitting exactly on the node, rather than into
        # whichever member happened to be first. Blender's join expresses each
        # incoming mesh in the survivor's frame, so joining into a member would
        # bake the whole bucket into that member's parent — a scaffolding empty
        # with a rotation on it, in the worst case — and leave geometry whose
        # placement depends on a helper that means nothing any more. An empty
        # mesh pinned to the node makes the result read the way it is built:
        # everything static under a node is one mesh per material, in that
        # node's own coordinates.
        host = bpy.data.objects.new(label, bpy.data.meshes.new(label))
        bpy.context.collection.objects.link(host)
        if node is not None:
            host.parent = node
            host.matrix_parent_inverse = Matrix()      # so host sits ON the node
        host.matrix_basis = Matrix()

        for ob in objs:
            ob.select_set(True)
        host.select_set(True)
        vl.objects.active = host
        bpy.ops.object.join()
        vl.objects.active.name = label
        bpy.ops.object.select_all(action='DESELECT')

    # Repeatedly, because removing a leaf makes its parent a leaf: one pass
    # leaves a chain of empties standing on nothing.
    while True:
        dead = [o for o in bpy.context.scene.objects
                if o.type == 'EMPTY' and not o.children and not is_node(o)]
        if not dead:
            break
        for ob in dead:
            bpy.data.objects.remove(ob, do_unlink=True)


# ---------------------------------------------------------------------------
# EXPORT
# ---------------------------------------------------------------------------
def out_path(default):
    argv = sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else []
    if '--out' in argv:
        return argv[argv.index('--out') + 1]
    return default


def export(out, label):
    tris = 0
    for ob in bpy.context.scene.objects:
        if ob.type == 'MESH':
            ob.data.calc_loop_triangles()
            tris += len(ob.data.loop_triangles)
    draws = len([o for o in bpy.context.scene.objects if o.type == 'MESH'])
    print(f'[{label}] {len(bpy.context.scene.objects)} objects, '
          f'{tris} triangles, {draws} draw calls')

    path = os.path.abspath(out)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        export_apply=True,          # no-op after optimise(), kept as a belt
        export_yup=True,            # Blender +Z becomes Three +Y
        export_materials='EXPORT',
        export_cameras=False,
        export_lights=False,
        export_extras=False,
        use_selection=False,
    )
    print(f'[{label}] wrote {out} ({os.path.getsize(path) / 1e6:.2f} MB)')


def build(label, fn, default_out=None):
    """
    The whole outer shell of a model script: reset, materials, build, optimise,
    export. Every vehicle file ends in one call to this.
    """
    out = out_path(default_out or f'assets/{label}.glb')
    reset_scene()
    build_materials()
    fn(M)
    bpy.ops.object.select_all(action='DESELECT')
    optimise()
    export(out, label)
