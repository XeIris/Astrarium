"""Discovery One-inspired exterior and an enclosed demonstrator centrifuge.
Reference interpretation and nuclear-drive estimates: docs/movie-spacecraft.md.
"""
import os
import sys
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
import bpy
from math import pi, sin, cos, sqrt
from mathutils import Vector, Matrix, Quaternion
from lib import empty, box, ball, cyl, revolve, strut, ring_on, finish, smooth, _obj
from common import build, stage, vehicle_stages, srgb
from movie_materials import palette, assign_uvs

S=vehicle_stages('discovery')['explorer']
L,D=S['L'],S['D']; R=D/2; CY=L-R-S['look']['noseSealAllowance']
BAY_RADIUS=S['look']['bayRadius']; BAY_SPACING=S['look']['baySpacing']; BAY_Z=S['look']['bayZ']
C=Matrix(((1,0,0),(0,0,-1),(0,1,0)))


def p(v):return C@Vector(v)


def block(name,at,size,mat,parent,bevel=.04):
    ob=box(name,(size[0],size[2],size[1]),p(at),mat,parent=parent)
    if bevel:finish(ob,bevel,2,45)
    return ob


def rod(name,a,b,r,mat,parent):
    return strut(name,p(a),p(b),r,mat,parent=parent,seg=8)


def sphere(name,at,r,mat,parent):
    ob=ball(name,r,p(at),mat,seg=96,rings=64,parent=parent)
    smooth(ob,55)
    return ob


def cut(ob,cutter):
    bpy.context.view_layer.objects.active=ob
    mod=ob.modifiers.new('opening','BOOLEAN');mod.operation='DIFFERENCE';mod.solver='EXACT';mod.object=cutter
    bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cutter,do_unlink=True)


def fit_berth(ob):
    # The ports lie on a sphere; fitting their circular cross-section alone leaves
    # the furniture's forward corners outside the pressure skin.
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96,ring_count=64,radius=R-.12,location=p((0,CY,0)))
    cutter=bpy.context.object;bpy.context.view_layer.objects.active=ob
    mod=ob.modifiers.new('inside pressure sphere','BOOLEAN');mod.operation='INTERSECT';mod.object=cutter
    bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cutter,do_unlink=True)


def hull(m,root):
    outer=empty('inspection_command_hull',(0,0,0),root)
    ob=sphere('command sphere',(0,CY,0),R,m['enamel'],outer)
    thickness=ob.modifiers.new('pressure skin','SOLIDIFY');thickness.thickness=.10
    bpy.context.view_layer.objects.active=ob;bpy.ops.object.modifier_apply(modifier=thickness.name)
    visor=block('visor cutter',(0,CY+R-.6,R*.29),(R*1.23,4.0,.50),m['panel'],None,.0)
    cut(ob,visor)
    for i in range(3):
        x=(i-1)*BAY_SPACING; z=BAY_Z
        bpy.ops.mesh.primitive_cylinder_add(vertices=96,radius=BAY_RADIUS,depth=R*1.7,location=p((x,CY+R*.77,z)))
        cut(ob,bpy.context.object)
    # Fine clean panel divisions, without weathering absent from the miniature.
    for z in [-R*.55,-R*.05,R*.55,R*.78]:
        y_radius=sqrt(R*R-z*z)
        ring_on(p((0,CY,z)),p((0,0,1)),y_radius+.007,.012,m['alloy'],'sphere panel seam',seg=128,minor=5,parent=outer)
    # The visor is a dark recessed slot with structural mullions, not a decal eye.
    vertices=[];faces=[]
    for z in [R*.29-.20,R*.29+.20]:
        for j in range(65):
            x=(j/64-.5)*R*1.18
            vertices.append(p((x,CY+sqrt(R*R-x*x-z*z)-.065,z)))
    for j in range(64):faces.append((j,j+65,j+66,j+1))
    glazing=_obj('curved command glazing',vertices,faces,m['glass'],outer);smooth(glazing,55)
    for x in [-R*.3,0,R*.3]:
        ends=[]
        for z in [R*.29-.24,R*.29+.24]:ends.append((x,CY+sqrt(R*R-x*x-z*z)+.008,z))
        rod('visor mullion',*ends,.035,m['enamel'],outer)
    for i in range(3):
        x=(i-1)*BAY_SPACING; z=BAY_Z
        y=CY+sqrt(max(1,R*R-x*x-z*z))
        for j in range(80):
            ends=[]
            for a in [j*2*pi/80,(j+1)*2*pi/80]:
                xx=x+(BAY_RADIUS+.022)*cos(a);zz=z+(BAY_RADIUS+.022)*sin(a)
                yy=CY+sqrt(max(.1,R*R-xx*xx-zz*zz))+.015
                ends.append((xx,yy,zz))
            rod('curved pod door seal',*ends,.035,m['panel'],root)
        # Idealised circumferential tracks preserve the curved cover's radius
        # throughout opening; the film's exact slide linkage is not documented.
        mount=empty('spherical hatch track',p((0,CY,0)),root)
        door=empty(f'door_explorer_{i}',(0,0,0),mount)
        def point(xx,zz):return p(Vector((xx,sqrt(R*R-xx*xx-zz*zz),zz))*(1+.055/R))
        points=[point(x,z)];faces=[]
        for band in range(1,6):
            for j in range(64):
                a=2*pi*j/64;rr=(BAY_RADIUS-.04)*band/5
                points.append(point(x+rr*cos(a),z+rr*sin(a)))
        for j in range(64):faces.append((0,1+(j+1)%64,1+j))
        for band in range(4):
            for j in range(64):
                a=1+band*64+j;b=1+band*64+(j+1)%64
                faces.append((a,b,b+64,a+64))
        mesh=bpy.data.meshes.new('curved hatch');mesh.from_pydata(points,[],faces);mesh.update()
        cap=bpy.data.objects.new('pod bay cover',mesh);bpy.context.collection.objects.link(cap);cap.parent=door;mesh.materials.append(m['enamel'])
        solid=cap.modifiers.new('hatch thickness','SOLIDIFY');solid.thickness=.015
        smooth(cap,55)
        floor_y=y-2.15
        furniture=empty(f'inspection_berth_{i}',(0,0,0),root)
        floor=block('pod berth floor',(x,floor_y,-2.88),(2.70,2.6,.12),m['panel'],furniture)
        bpy.ops.mesh.primitive_cylinder_add(vertices=96,radius=BAY_RADIUS-.04,depth=4.0,location=p((x,floor_y,z)))
        cutter=bpy.context.object
        bpy.context.view_layer.objects.active=floor
        trim=floor.modifiers.new('floor fits circular aperture','BOOLEAN');trim.operation='INTERSECT';trim.object=cutter
        bpy.ops.object.modifier_apply(modifier=trim.name);bpy.data.objects.remove(cutter,do_unlink=True)
        fit_berth(floor)
        for rail in [-.52,.52]:
            track=block('pod rail',(x+rail,floor_y,-2.78),(.08,2.4,.10),m['alloy'],furniture)
            fit_berth(track)
        wall=block('berth rear wall',(x,floor_y-1.3,-1.6),(2.7,.08,2.6),m['liner'],furniture)
        fit_berth(wall)


def spine(m,root):
    # The narrow load path remains continuous through every equipment module.
    block('central structural spine',(0,(20+CY-R)*.5,0),(.72,CY-R-20,.72),m['alloy'],root)
    count=int(S['look']['spineModules'])
    for i in range(count):
        y=24+(CY-R-3-24)*i/(count-1)
        for j in range(4):
            a=j*pi/2
            mount=empty('module orientation',p((0,y,0)),root);mount.rotation_euler=(0,0,-a)
            block('service module',(1.25,0,0),(2.1,4.6,2.5),m['enamel'],mount,.29)
            block('module end cover',(2.30,0,0),(.12,3.90,2.05),m['enamel'],mount,.04)
            for z in [-.87,.87]:block('module edge flange',(2.37,0,z),(.08,3.95,.11),m['alloy'],mount,.018)
            for k in range(3):
                block('service connector',(2.40,(k-1)*.7,.23),(.15,.26,.25),m['panel'],mount,.025)
            for direction in [-1,1]:
                rod('module diagonal',(direction*.32,-1.8,.35),(1.25,-1.6,.9),.04,m['alloy'],mount)
    # Three-dish antenna group, all faces radiating away from the spine.
    at=40.0
    block('antenna base',(0,at,1.8),(2.3,3.6,.9),m['enamel'],root)
    rod('antenna mast',(0,at,2),(0,at,5.6),.22,m['alloy'],root)
    for x,r in [(0,2.3),(-3.0,.85),(3.0,.85)]:
        mount=empty('antenna orientation',p((x,at,5.9)),root)
        # Blender +Z points forward along the vessel; tilt the dish toward +Yb.
        mount.rotation_euler=(pi/2,0,0)
        dish=revolve('communications reflector',[(r*k/16,r*.20*(k/16)**2) for k in range(17)],m['enamel'],seg=64,parent=mount)
        smooth(dish,45)
        ring_on((0,0,r*.20),(0,0,1),r,.035,m['alloy'],'reflector rim',seg=64,parent=mount)
        strut('antenna feed boom',(0,0,0),(0,0,r*.5),.035,m['alloy'],parent=mount)
        for j in range(3):
            a=j*2*pi/3
            strut('reflector feed support',(r*.9*cos(a),r*.9*sin(a),r*.20*.9**2),(0,0,r*.5),.025,m['alloy'],parent=mount)
        if x:rod('antenna cross member',(0,at,5.5),(x,at,5.9),.10,m['alloy'],root)


def stern(m,root):
    outline=[(-4,-2),(-2.9,-3.1),(2.9,-3.1),(4,-2),(4,2),(2.9,3.1),(-2.9,3.1),(-4,2)]
    vertices=[p((x,y,z)) for y,f in [(3.0,1),(17.8,1),(20,.30)] for x,z in [(x*f,z*f) for x,z in outline]]
    faces=[tuple(range(7,-1,-1)),tuple(range(16,24))]
    for row in range(2):
        for j in range(8):faces.append((row*8+j,row*8+(j+1)%8,(row+1)*8+(j+1)%8,(row+1)*8+j))
    case=_obj('octagonal reactor case',vertices,faces,m['enamel'],root)
    import bmesh
    bm=bmesh.new();bm.from_mesh(case.data);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(case.data);bm.free()
    finish(case,.13,3,45)
    for side in [-1,1]:
        for y in [3.5,7.5,11.5,15.5]:
            block('reactor side box',(side*4.03,y,0),(.24,3.0,3.8),m['enamel'],root,.10)
            for z in [-1.3,-.7,0,.7,1.3]:
                block('heat exchanger channel',(side*4.18,y,z),(.10,2.8,.16),m['alloy'],root,.02)
        for k in range(12):
            y=3.0+k*1.3
            block('reactor top detail',(side*1.35,y,3.16),(.90,.75,.20),m['panel'] if k%4==0 else m['enamel'],root,.04)
    for i in range(3):
        x=(i-1)*2.65
        pivot=empty(f'gimbal_explorer_{i}',p((x,0,0)),root)
        housing=revolve('hexagonal drive housing',[(1.05,.02),(1.18,.13),(1.18,1.8),(.53,2.5)],m['enamel'],seg=6,parent=pivot)
        finish(housing,.035,2,40)
        plate=revolve('drive face',[(0,.035),(1.07,.035),(1.07,.14),(0,.14)],m['enamel'],seg=6,parent=pivot)
        for z in [-.48,.48]:
            bpy.ops.mesh.primitive_cylinder_add(vertices=48,radius=.40,depth=.8,location=p((x,0,z)))
            cut(plate,bpy.context.object)
            bell=revolve('paired nuclear outlet',[(.39,.025),(.36,.22),(.22,.9),(.14,1.55)],m['nozzle'],seg=48,parent=pivot)
            bell.location=p((0,0,z));smooth(bell,45)
            ring_on(p((0,.03,z)),p((0,1,0)),.40,.027,m['alloy'],'outlet rim',seg=48,parent=pivot)
            for dx in [-.10,.10]:rod('outlet protective grille',(dx,.012,z-.34),(dx,.012,z+.34),.018,m['alloy'],pivot)
        for dx in [-.61,.61]:
            for z in [-.22,.22]:
                bpy.ops.mesh.primitive_cylinder_add(vertices=24,radius=.12,depth=.8,location=p((x+dx,0,z)))
                cut(plate,bpy.context.object)
                ring_on(p((dx,.03,z)),p((0,1,0)),.12,.018,m['alloy'],'auxiliary outlet lip',seg=24,parent=pivot)
        neck=revolve('drive neck',[(.47,2.0),(.47,3.6)],m['alloy'],seg=48,parent=pivot)
        for y in [2.05,2.3,2.55,2.8,3.05,3.3]:
            ring_on((0,0,y),(0,0,1),.49,.045,m['enamel'],'drive neck flange',seg=40,parent=pivot)
        block('engine mounting block',(x,3.5,0),(2.12,1.1,2.3),m['enamel'],root,.15)


def rotor(m,root):
    at=S['centrifuge']['at'];radius=S['centrifuge']['radius']
    node=empty('rotor_explorer_0',p(at),root)
    for y in [-.85,.85]:
        ring_on(p((0,y,0)),p((0,1,0)),radius,.16,m['alloy'],'centrifuge rim',seg=96,parent=node)
    for j in range(24):
        a=j*2*pi/24
        pos=(radius*cos(a),0,radius*sin(a))
        mount=empty('habitat segment',p(pos),node);mount.rotation_euler=(0,0,-a)
        block('centrifuge floor',(0,0,0),(.10,1.7,1.15),m['liner'],mount,.02)
        if j%3==0:
            block('habitat cabinet',(-.40,0,0),(.7,.8,.70),m['enamel'],mount,.08)
            rod('centrifuge spoke',(0,-.95,0),(radius*cos(a),-.95,radius*sin(a)),.045,m['alloy'],node)


def make(_shared):
    m=palette();root=stage('explorer')
    hull(m,root);spine(m,root);stern(m,root);rotor(m,root)
    docked_pods(root)
    assign_uvs()


def docked_pods(root):
    import evapod
    evapod.exterior(None)
    template=bpy.data.objects['stage_pod']
    tree=[template]+list(template.children_recursive)
    for ob in tree: ob.name='berthed_'+ob.name
    mounts=[]
    for berth in S['berths']:
        mount=empty(berth['node'],p(berth['at']),root)
        x,y,z,w=berth['q']
        mount.rotation_mode='QUATERNION'
        mount.rotation_quaternion=(C@Quaternion((w,x,y,z)).to_matrix()@C.inverted()).to_quaternion()
        mounts.append(mount)
    template.parent=mounts[0]
    for i in [1,2]:
        copies={}
        for ob in tree:
            clone=ob.copy();bpy.context.collection.objects.link(clone);copies[ob]=clone
        for ob,clone in copies.items():clone.parent=mounts[i] if ob==template else copies[ob.parent]


build('discovery',make)
