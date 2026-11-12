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
from movie_materials import palette, assign_uvs, surface

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
        floor=block('pod berth floor',(x,floor_y,-2.88),(2.70,2.6,.12),m['bay_floor'],furniture)
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
        for side in [-1,1]:
            x_rack=x+side*1.02
            rack=block('berth wall service strip',(x_rack,floor_y-1.255,-1.68),(.31,.16,1.83),m['panel'],furniture,.022)
            fit_berth(rack)
            for zz in [-2.37,-1.71,-1.05]:
                plate=block('berth service cover',(x_rack,floor_y-1.16,zz),(.28,.09,.39),m['alloy'],furniture,.016)
                fit_berth(plate)
        lamp=block('berth work light recess',(x,floor_y-1.23,-.52),(.76,.18,.13),m['panel'],furniture,.017)
        fit_berth(lamp)
        lens=block('berth opal strip',(x,floor_y-1.135,-.52),(.68,.025,.085),m['lamp'],furniture,.010)
        fit_berth(lens)


def spine(m,root):
    # The narrow load path remains continuous through every equipment module.
    fore=S['look']['reactorFore']
    block('central structural spine',(0,(fore+CY-R)*.5,0),(.72,CY-R-fore+.16,.72),m['alloy'],root)
    count=int(S['look']['spineModules'])
    for i in range(count):
        start=fore+3.5
        y=start+(CY-R-3-start)*i/(count-1)
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
    at=S['look']['antennaAt']
    block('antenna base',(0,at,1.8),(2.3,3.6,.9),m['enamel'],root)
    rod('antenna mast',(0,at,2),(0,at,5.93),.22,m['alloy'],root)
    for y,z,sz in [(at,2.55,.45),(at,4.35,.38),(at,5.60,.43)]:
        block('antenna mast joint',(0,y,z),(.62,.65,sz),m['enamel'],root,.06)
    for index, spec in enumerate(S['dishes']):
        x,y,z=spec['at'];r=spec['radius']
        mount=empty(f'inspection_antenna_{index}',p((x,y,z)),root)
        # The feed follows the reflector's local +Z, which is ship aft here.
        mount.rotation_euler=(pi,0,0)
        dish=revolve('communications reflector',[(r*k/16,r*.20*(k/16)**2) for k in range(17)],m['enamel'],seg=64,parent=mount)
        smooth(dish,45)
        skin=dish.modifiers.new('reflector shell','SOLIDIFY');skin.thickness=.023
        ring_on((0,0,r*.20),(0,0,1),r,.035,m['alloy'],'reflector rim',seg=64,parent=mount)
        strut('antenna feed boom',(0,0,0),(0,0,r*.5),.035,m['alloy'],parent=mount)
        empty(f'inspection_feed_{index}',(0,0,r*.5),mount)
        for j in range(3):
            a=j*2*pi/3
            strut('reflector feed support',(r*.9*cos(a),r*.9*sin(a),r*.20*.9**2),(0,0,r*.5),.025,m['alloy'],parent=mount)
        if x:rod('antenna cross member',(0,at+.045,5.65),(x,at+.045,z),.10,m['alloy'],root)


def stern(m,root):
    aft=S['look']['reactorAft'];fore=S['look']['reactorFore']
    outline=[(-4,-2),(-2.9,-3.1),(2.9,-3.1),(4,-2),(4,2),(2.9,3.1),(-2.9,3.1),(-4,2)]
    stations=[(aft,.82),(aft+2.1,1),(fore-5.0,1),(fore-1.8,.72),(fore,.25)]
    vertices=[p((x*f,y,z*f)) for y,f in stations for x,z in outline]
    faces=[tuple(range(7,-1,-1)),tuple(range(len(vertices)-8,len(vertices)))]
    for row in range(len(stations)-1):
        for j in range(8):faces.append((row*8+j,row*8+(j+1)%8,(row+1)*8+(j+1)%8,(row+1)*8+j))
    case=_obj('octagonal reactor case',vertices,faces,m['enamel'],root)
    import bmesh
    bm=bmesh.new();bm.from_mesh(case.data);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(case.data);bm.free()
    finish(case,.13,3,45)
    for side in [-1,1]:
        for y in [aft+3.35,aft+5.75,aft+8.15]:
            block('reactor service hatch',(side*4.025,y,0),(.17,2.1,3.6),m['alloy'],root,.07)
            block('inset reactor hatch cover',(side*4.11,y,.21),(.10,1.88,2.92),m['enamel'],root,.04)
            for z in [-1.28,-.69,-.10,.49,1.08]:
                block('recessed exchanger channel',(side*4.16,y,z),(.08,1.70,.115),m['panel'],root,.015)
        for k in range(7):
            y=aft+2.7+k*1.11
            block('reactor roof access plate',(side*1.4,y,3.113),(2.50,.93,.08),m['enamel'],root,.024)
            for x in [.40,2.40]:
                block('captive roof latch',(side*x,y,3.16),(.11,.30,.044),m['alloy'],root,.014)
    for i in range(3):
        x=(i-1)*2.65
        pivot=empty(f'gimbal_explorer_{i}',p((x,0,0)),root)
        housing=revolve('flared hexagonal drive housing',[(1.05,.02),(1.18,.13),(1.17,1.25),(.87,3.20),(.53,4.38)],m['enamel'],seg=6,parent=pivot)
        finish(housing,.035,2,40)
        plate=revolve('drive face',[(0,.035),(1.07,.035),(1.07,.14),(0,.14)],m['enamel'],seg=6,parent=pivot)
        for z in [-.48,.48]:
            bpy.ops.mesh.primitive_cylinder_add(vertices=48,radius=.40,depth=.8,location=p((x,0,z)))
            cut(plate,bpy.context.object)
            bell=revolve('paired nuclear outlet',[(.39,.025),(.36,.36),(.24,1.52),(.14,2.45)],m['nozzle'],seg=48,parent=pivot)
            bell.location=p((0,0,z));smooth(bell,45)
            ring_on(p((0,.03,z)),p((0,1,0)),.40,.027,m['alloy'],'outlet rim',seg=48,parent=pivot)
            for dx in [-.10,.10]:rod('outlet protective grille',(dx,.012,z-.34),(dx,.012,z+.34),.018,m['alloy'],pivot)
        for dx in [-.61,.61]:
            for z in [-.22,.22]:
                bpy.ops.mesh.primitive_cylinder_add(vertices=24,radius=.12,depth=.8,location=p((x+dx,0,z)))
                cut(plate,bpy.context.object)
                ring_on(p((dx,.03,z)),p((0,1,0)),.12,.018,m['alloy'],'auxiliary outlet lip',seg=24,parent=pivot)
        neck=empty(f'inspection_drive_neck_{i}',p((x,4.20,0)),root)
        length=aft-4.20
        shell=revolve('fixed drive duct',[(.57,0),(.52,.31),(.48,.70),(.48,length-.46),(.59,length+.25)],m['alloy'],seg=48,parent=neck)
        smooth(shell,45)
        for k in range(13):
            y=.36+k*(length-.75)/12
            ring_on((0,0,y),(0,0,1),.51,.049,m['enamel'],'duct bellows corrugation',seg=36,parent=neck)
        block('drive service flange',(x,aft-.012,0),(1.39,.12,1.54),m['enamel'],root,.052)
        for dx in [-.54,.54]:
            for z in [-.60,.60]:
                rod('captive mounting bolt',(x+dx,aft-.102,z),(x+dx,aft-.063,z),.061,m['alloy'],root)
        block('engine mounting saddle',(x,aft+.18,0),(1.60,1.25,1.82),m['enamel'],root,.13)


def rotor(m,root):
    at=S['centrifuge']['at'];radius=S['centrifuge']['radius']
    node=empty('rotor_explorer_0',p(at),root)
    for y in [-.85,.85]:
        ring_on(p((0,y,0)),p((0,1,0)),radius,.16,m['alloy'],'centrifuge rim',seg=96,parent=node)
    for j in range(24):
        a=j*2*pi/24
        pos=(radius*cos(a),0,radius*sin(a))
        mount=empty('habitat segment',p(pos),node);mount.rotation_euler=(0,0,-a)
        block('centrifuge floor',(0,0,0),(.10,1.7,1.15),m['bay_floor'],mount,.02)
        for y in [-.71,.71]:
            block('floor edge channel',(-.051,y,0),(.045,.12,1.15),m['alloy'],mount,.012)
        if j%3==0:
            block('habitat cabinet',(-.38,0,0),(.72,.89,.79),m['liner'],mount,.065)
            for dz in [-.235,0,.235]:
                block('habitat drawer bezel',(-.742,0,dz),(.034,.75,.20),m['alloy'],mount,.023)
                block('inset drawer grip',(-.764,0,dz),(.025,.28,.054),m['panel'],mount,.013)
            rod('centrifuge spoke',(0,-.95,0),(radius*cos(a),-.95,radius*sin(a)),.045,m['alloy'],node)


def make(_shared):
    m=palette();root=stage('explorer')
    m['liner']=surface('explorerBayPaint',0xa3a69b,.65,.045,'paint',3.0)
    m['bay_floor']=surface('explorerBayFloor',0x595e54,.79,.04,'rubber',4.1)
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
