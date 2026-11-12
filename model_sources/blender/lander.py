"""Original Lander-inspired cargo shuttle, sharing its apertured runtime skin."""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from math import pi
from mathutils import Vector, Matrix
from lib import empty, box, strut, revolve, ring_on, finish, smooth, _obj
from common import build, stage, vehicle_stages
from movie_materials import palette, assign_uvs, surface

S = vehicle_stages('lander')['cargo']
C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def p(v):
    return C @ Vector(v)


def block(name, at, size, mat, parent, bevel=.04):
    ob = box(name, (size[0], size[2], size[1]), p(at), mat, parent=parent)
    if bevel:
        finish(ob, bevel, 3, 45)
    return ob


def rod(name, a, b, radius, mat, parent):
    return strut(name, p(a), p(b), radius, mat, seg=10, parent=parent)


def polygon(row, mat, parent, offset=0):
    points = [Vector(v) for v in row['vertices']]
    normal = (points[1]-points[0]).cross(points[2]-points[0]).normalized()
    mesh = bpy.data.meshes.new(row['name'])
    mesh.from_pydata([p(v+normal*offset) for v in points], [], [list(range(len(points)))])
    mesh.update()
    ob = bpy.data.objects.new(row['name'], mesh)
    bpy.context.collection.objects.link(ob)
    ob.parent = parent
    mesh.materials.append(mat)
    return points


def cargo_panels(points, normal, m, parent):
    # Match the underlying skin's diagonal so access covers follow even the
    # transition facets. Their return flanges extend into the pressure skin.
    def at(u, v):
        a, b, c, d = points
        return a*(1-u)+b*(u-v)+c*v if u>=v else a*(1-v)+c*u+d*(v-u)

    uv = [(.13, .12), (.79, .12), (.89, .25), (.89, .82), (.77, .90), (.12, .90)]
    edge = [at(u, v) for u, v in uv]
    count = len(edge)
    verts = [p(v+normal*depth) for depth in [-.035, .028] for v in edge]
    faces = [tuple(range(count, 2*count))]
    faces.extend((i, (i+1)%count, (i+1)%count+count, i+count) for i in range(count))
    cover = _obj('cargo access cover', verts, faces, m['enamel'], parent)
    finish(cover, .013, 2, 45)
    for v in [.21, .81]:
        a = at(.29, v)+normal*.027
        b = at(.37, v)+normal*.027
        rod('cargo cover latch', a, b, .034, m['alloy'], parent)


def make(_shared):
    m = palette()
    m['blanket'] = surface('cargoBlanket', 0xb8b1a1, .82, .02, 'blanket', .67)
    m['tps'] = surface('cargoCeramic', 0x494440, .86, .025, 'tile', .97)
    root = stage('cargo')
    length, beam = S['L'], S['D']
    for row in S['geometry']['faces']:
        points = polygon(row, m['tps'] if row['material']=='tps' else m['panel'] if row['material']=='panel' else m['blanket'], root)
        if row['name']=='cargo pod skin':
            normal = (points[1]-points[0]).cross(points[2]-points[0]).normalized()
            if normal.z>.8:
                a = points[0].lerp(points[3], .5)+normal*.006
                b = points[1].lerp(points[2], .5)+normal*.006
                rod('blanket panel seam', a, b, .012, m['alloy'], root)
            elif normal.x*points[0].x>1.5 and normal.z>0.0:
                cargo_panels(points, normal, m, root)
    glazing = empty('window_shade', (0, 0, 0), root)
    for row in S['geometry']['windows']:
        points = polygon(row, m['glass'], glazing, -.012)
        for a, b in zip(points, points[1:]+points[:1]):
            rod('bonded glazing gasket', a, b, .022, m['rubber'], root)
    for side in [-1, 1]:
        block('cargo pod load bridge', (side*beam*.27, length*.44, 0), (beam*.30, length*.20, length*.045), m['enamel'], root, .10)
        # Equipment fairings are mounted on the broad bridge, overlapping its
        # thickness; the sloping shoulder skins remain visible around them.
        block('bridge equipment fairing', (side*beam*.305, length*.45, length*.045), (beam*.14, length*.12, length*.07), m['enamel'], root, .20)
    for index, at in enumerate(S['enginePositions']):
        mount = empty('drive mount', p(at), root)
        pivot = empty(f'gimbal_cargo_{index}', (0, 0, 0), mount)
        ob = revolve('cargo thruster shroud', [(.43, 0), (.47, .06), (.47, .17), (.30, .52)], m['alloy'], seg=40, parent=pivot)
        smooth(ob, 45)
        revolve('recessed thruster throat', [(.42, .02), (.39, .16), (.22, .47)], m['nozzle'], seg=40, parent=pivot)
        ring_on((0, 0, .06), (0, 0, 1), .44, .025, m['alloy'], 'drive lip', seg=40, parent=pivot)
        block('drive attachment', (0, .65, 0), (.64, .32, .64), m['panel'], pivot, .05)
    # Closed dorsal capture collar; a later inhabited interior can cut its
    # pressure opening independently of the external docking hardware.
    dock = S['dockPort']
    collar = empty('inspection_docking_collar', (0, 0, 0), root)
    at = Vector(dock['at'])
    ring_on(p(at), p(dock['normal']), dock['radius'], .12, m['alloy'], 'cargo docking collar', seg=64, parent=collar)
    slope = -dock['normal'][1]
    for x in [-.7, .7]:
        ends = []
        for fraction in dock['handrails']:
            y = length*fraction
            z = at.z-.04+slope*(y-at.y)
            rod('handrail foot', (x, y, z), (x, y, z+.10), .035, m['alloy'], collar)
            ends.append((x, y, z+.10))
        rod('dorsal handrail', *ends, .035, m['alloy'], collar)
    assign_uvs()


if __name__ == '__main__':
    build('lander', make)
