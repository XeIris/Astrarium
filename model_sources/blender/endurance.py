"""Twelve-module Endurance-inspired ring; original surfaces from miniature study.
Dimensions, drive estimates and reconstruction limits: docs/movie-spacecraft.md.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from math import pi, sin, cos
from mathutils import Vector, Matrix, Quaternion
from lib import empty, box, strut, ball, revolve, ring_on, finish, smooth
from common import build, stage, vehicle_stages
from movie_materials import palette, assign_uvs, surface

S = vehicle_stages('endurance')['expedition']
C = Matrix(((1, 0, 0), (0, 0, -1), (0, 1, 0)))


def p(v):
    return C @ Vector(v)


def block(name, at, size, mat, parent, bevel=.06):
    ob = box(name, (size[0], size[2], size[1]), p(at), mat, parent=parent)
    if bevel:
        finish(ob, bevel, 3, 45)
    return ob


def rod(name, a, b, radius, mat, parent):
    return strut(name, p(a), p(b), radius, mat, seg=12, parent=parent)


def collar(name, at, axis, radius, mat, parent, tube=.08):
    return ring_on(p(at), p(axis), radius, tube, mat, name, seg=48, minor=8, parent=parent)


def module(index, parent, m):
    ring = S['look']['ring']
    angle = index * 2*pi/12
    mount = empty(f'inspection_module_{index}', p((0, ring['at'], 0)), parent)
    mount.rotation_euler = (0, 0, -angle)
    radius = ring['centerRadius']
    radial, depth, width = ring['moduleSize']
    block('bevelled module pressure shell', (radius, 0, 0), (radial, depth, width), m['enamel'], mount, .46)
    # A continuous pressure tunnel intersects both neighbouring shells. Its
    # exposed middle carries the rounded connector node seen on the miniature.
    a = (radius, 0, 0)
    b = (radius*cos(pi/6), 0, radius*sin(pi/6))
    rod('intermodule pressure tunnel', a, b, 1.04, m['enamel'], mount)
    mid = (Vector(a)+Vector(b))*.5
    node = ball('rounded intermodule junction', 1.55, p(mid), m['enamel'], seg=32, rings=20, parent=mount)
    smooth(node, 45)
    for direction in [-1, 1]:
        collar('connector inspection hatch rim', mid+Vector((0, direction*1.28, 0)), (0, 1, 0), .76, m['alloy'], mount)
        # Closed hatch, with a recessed dark face rather than an open tunnel.
        hatch = revolve('connector hatch', [(0, -.025), (.72, -.025), (.72, .025), (0, .025)], m['panel'], seg=40, parent=mount)
        hatch.location = p(mid+Vector((0, direction*1.30, 0)))
    for side in [-1, 1]:
        face = side*(depth/2+.025)
        block('panel perimeter backing', (radius, face, 0), (radial-.65, .055, width-.65), m['alloy'], mount, .22)
        if index % 3 == 0 and side < 0:
            # Four propulsion modules, three outlets each; all thrust along +Y.
            block('drive heat shield', (radius, face-.07, 0), (radial-1.05, .10, width-1.05), m['tps'], mount, .22)
            for engine, (x, z) in enumerate([(-1.55, -1.65), (1.55, -1.65), (0, 1.65)]):
                fixed = empty('engine mounting orientation', p((radius+x, face-.25, z)), mount)
                pivot = empty(f'gimbal_expedition_{index//3*3+engine}', (0, 0, 0), fixed)
                bell = revolve('plasma drive outlet', [(.72, .02), (.94, .07), (.95, .18), (.70, .80), (.40, 1.10)], m['alloy'], seg=40, parent=pivot)
                smooth(bell, 45)
                revolve('dark outlet interior', [(.70, .03), (.68, .45), (.38, .92)], m['nozzle'], seg=40, parent=pivot)
                collar('outlet flange', (0, .10, 0), (0, 1, 0), .96, m['alloy'], pivot, .05)
        elif index % 2 == 0:
            for column in range(3):
                z = (column-1)*(width-1.2)/3
                block('radiator face', (radius, face+side*.065, z), (radial-1.20, .10, (width-1.3)/3-.14), m['radiator'], mount, .05)
                for k in range(22):
                    x = radius-radial*.40+k*(radial*.80)/21
                    block('radiator fin', (x, face+side*.13, z), (.058, .045, (width-1.3)/3-.20), m['radiator'], mount, .006)
                for x in [radius-radial*.33,radius+radial*.33]:
                    block('radiator end manifold',(x,face+side*.13,z),(.15,.074,(width-1.3)/3-.10),m['alloy'],mount,.025)
        else:
            for k in range(3):
                x = radius+(k-1)*(radial-.95)/3
                block('insulated service panel', (x, face+side*.065, 0), ((radial-.95)/3-.10, .11, width-.95), m['blanket'], mount, .10)
                for z in [-width*.36, width*.36]:
                    block('captive access latch', (x, face+side*.15, z), (.38, .065, .12), m['alloy'], mount, .025)
    for edge in [-1, 1]:
        x = radius+edge*(radial/2-.18)
        for z in [-width/2+.20, width/2-.20]:
            rod('module edge rail', (x, -depth/2+.16, z), (x, depth/2-.16, z), .07, m['alloy'], mount)
    for k in range(4):
        z = (k-1.5)*.60
        block('outer service recess', (radius+radial/2+.015, .55, z), (.035, 1.10, .43), m['panel'], mount, .035)
    for end in [-1, 1]:
        x = radius+end*(radial/2+.015)
        for y in [-depth*.30, depth*.30]:
            block('end access cover', (x, y, 0), (.045, 1.35, width*.58), m['enamel'], mount, .045)
            for z in [-width*.24, width*.24]:
                block('end cover fastener', (x+end*.035, y, z), (.025, .16, .12), m['alloy'], mount, .01)
    for z in [-width/2-.02, width/2+.02]:
        block('tunnel service trunk', (radius, .65, z), (radial*.65, .55, .13), m['enamel'], mount, .07)
    if index % 4 == 1:
        for z in [-.90, -.30, .30, .90]:
            block('small observation window gasket', (radius+radial/2+.031, -1.15, z), (.085, .48, .44), m['rubber'], mount, .045)
            block('observation glazing', (radius+radial/2+.08, -1.15, z), (.025, .38, .34), m['glass'], mount, .035)


def hub(parent, m):
    length = float(S['look']['hubLength'])
    radius = float(S['look']['hubRadius'])
    axis = empty('hub axis', p((0, 0, 0)), parent)
    case = revolve('central docking spine', [(0, 0), (radius-.24, 0), (radius, .40), (radius, length-.4), (radius-.24, length), (0, length)], m['enamel'], seg=48, parent=axis)
    smooth(case, 45)
    for y in [length*f for f in [.0303, .1606, .3273, .4545, .5939, .7424, .8939, .9818]]:
        collar('hub pressure flange', (0, y, 0), (0, 1, 0), 1.67, m['alloy'], axis, .10)
    spokes = empty('inspection_spokes', (0,0,0), parent)
    for member in S['spokes']:
        start, end = Vector(member['start']), Vector(member['end'])
        tube = member['radius']
        rod('radial pressure tunnel', start, end, tube, m['enamel'], spokes)
        along = (end-start).normalized()
        for fraction in [.12, .33, .54, .75, .94]:
            at = start.lerp(end, fraction)
            rod('pressure tunnel coupling', at-along*.17, at+along*.17, tube+.07, m['panel'], spokes)
            collar('pressure flange', at+along*.16, along, member['flangeRadius']-.052, m['alloy'], spokes, .052)
    for y in [.14, length-.14]:
        collar('axial docking gasket', (0, y, 0), (0, 1, 0), 1.18, m['rubber'], axis, .14)
        for j in range(8):
            a = j*2*pi/8
            block('axial capture petal', (1.36*cos(a), y, 1.36*sin(a)), (.23, .22, .23), m['alloy'], axis, .035)
    # The smaller adapters contact the shuttle hatches while keeping the
    # Ranger's outboard nozzles and the Lander's canopy clear of the hub skin.
    reach = float(S['look']['axialAdapter'])
    rod('Ranger axial docking adapter', (0,length-.25,0), (0,length+reach,0), .58, m['alloy'], parent)
    collar('Ranger coupling lip', (0,length+reach-.06,0), (0,1,0), .60, m['panel'], parent, .045)
    cargo_port = Vector(S['look']['landerBerth'])
    inner = Vector((-radius+.22, cargo_port.y, 0))
    rod('Lander transverse docking adapter', inner, cargo_port+Vector((-.02,0,0)), 1.04, m['enamel'], parent)
    for fraction in [.20,.46,.72,.94]:
        collar('transverse adapter flange', inner.lerp(cargo_port,fraction), (1,0,0), 1.07, m['alloy'], parent, .06)


def make(_shared):
    m = palette()
    # The Endurance's light blankets lack the Ranger's strong tiled colour
    # variation; stitched relief belongs mainly in the normal/roughness maps.
    m['blanket'] = surface('expeditionBlanket', 0xd0cec1, .82, .015, 'blanket', .49)
    m['radiator'] = surface('expeditionRadiator', 0x606b72, .64, .24, 'alloy', .76)
    root = stage('expedition')
    rotor = empty('rotor_expedition_0', (0, 0, 0), root)
    for i in range(12):
        module(i, rotor, m)
    hub(rotor, m)
    support_craft(rotor, m)
    assign_uvs()


def support_craft(parent, materials):
    import ranger
    import lander
    for berth in S['berths']:
        if berth['vehicle']=='ranger':
            ranger.exterior(materials)
            root=bpy.data.objects['stage_ranger']
        else:
            lander.make(None)
            root=bpy.data.objects['stage_cargo']
        for ob in [root]+list(root.children_recursive):
            ob.name='berthed_'+ob.name
        mount=empty(berth['node'],p(berth['at']),parent)
        x,y,z,w=berth['q']
        mount.rotation_mode='QUATERNION'
        mount.rotation_quaternion=(C@Quaternion((w,x,y,z)).to_matrix()@C.inverted()).to_quaternion()
        root.parent=mount


build('endurance', make)
