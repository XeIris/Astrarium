"""Original 2001-inspired pod. Reference choices and estimates: docs/eva-pod.md.
Blender -Y is the window direction; +Z is cabin up and the thrust axis.
"""
import os
import sys
from math import pi, sin, cos, sqrt
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from mathutils import Vector
from lib import box, ball, cyl, revolve, strut, empty, material, _obj, finish, smooth, reset_scene
from common import build, stage, vehicle_stages, srgb, build_materials, optimise, export, out_path

SPEC = vehicle_stages('evapod')['pod']
R = SPEC['D'] / 2
S = R / 1.03
M = {}
WX, WZ, WC = .44, .51, 1.42


def palette():
    from evapod_materials import palette as finishes
    M.clear()
    M.update(finishes())


def block(name, loc, size, mat, parent, bevel=.012):
    ob = box(name, tuple(v*S for v in size), tuple(v*S for v in loc), M[mat], parent=parent)
    if bevel: finish(ob, bevel*S, 3, 40)
    return ob


def tube(name, a, b, radius, mat, parent):
    ob = strut(name, tuple(v*S for v in a), tuple(v*S for v in b), radius*S, M[mat], seg=20, parent=parent)
    smooth(ob, 35)
    return ob


def disk(name, loc, radius, depth, mat, parent, axis=(0, -1, 0)):
    ob = revolve(name, [(0,-depth*S/2),(radius*S,-depth*S/2),(radius*S,depth*S/2),(0,depth*S/2)], M[mat], seg=48, parent=parent)
    ob.location = tuple(v*S for v in loc)
    ob.rotation_mode = 'QUATERNION'
    ob.rotation_quaternion = Vector((0, 0, 1)).rotation_difference(Vector(axis))
    finish(ob, min(.006, depth*.12)*S, 2, 40)
    smooth(ob, 40)
    return ob


def poly(name, points, y0, y1, mat, parent):
    n = len(points)
    verts = [(x*S, y*S, z*S) for y in (y0, y1) for x,z in points]
    faces = [tuple(range(n-1,-1,-1)), tuple(range(n,2*n))]
    faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    ob = _obj(name, verts, faces, M[mat], parent)
    # Polygon outlines are used on both faces, so derive winding consistently.
    import bmesh
    bm=bmesh.new(); bm.from_mesh(ob.data); bmesh.ops.recalc_face_normals(bm,faces=bm.faces); bm.to_mesh(ob.data); bm.free()
    finish(ob, .012*S, 3, 40)
    return ob


def boolean(ob, cutter):
    bpy.context.view_layer.objects.active = ob
    mod = ob.modifiers.new('Opening', 'BOOLEAN'); mod.operation='DIFFERENCE'; mod.solver='EXACT'; mod.object=cutter
    bpy.ops.object.modifier_apply(modifier=mod.name)
    bpy.data.objects.remove(cutter, do_unlink=True)


def window_ring(parent):
    # The rim follows the sphere; the inner rim is a cylindrical glazing opening.
    n=128; verts=[]
    for rx,rz,mode in [(WX,WZ,0),(.34,.395,1),(.33,.385,2)]:
        for i in range(n):
            a=i*2*pi/n; x=rx*cos(a); z=WC+rz*sin(a)
            y=-sqrt(max(.01,1.03**2-x*x-(z-1.03)**2))-.008 if mode==0 else (-.40 if mode==1 else -.39)
            verts.append((x*S,y*S,z*S))
    faces=[(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    faces += [(i+n,(i+1)%n+n,(i+1)%n+2*n,i+2*n) for i in range(n)]
    ob=_obj('Window deep reveal',verts,faces,M['podSeal'],parent); smooth(ob,60)
    for i in range(100):
        a=i*2*pi/100; c=cos(a); s=sin(a)
        x=(WX-.005)*c; z=WC+(WZ-.005)*s; y=-sqrt(max(.01,1.03**2-x*x-(z-1.03)**2))-.014
        tube('Window radial rib', (x,y,z),(.343*c,-.404,WC+.398*s),.0033,'black',parent)
    # Glazing is omitted: the opening is transparent without alpha sorting artifacts.
    for rx,rz,y in [(.331,.386,-.393),(.341,.396,-.403)]:
        for i in range(96):
            a=i*2*pi/96; b=(i+1)*2*pi/96
            tube('Glazing gasket', (rx*cos(a),y,WC+rz*sin(a)),(rx*cos(b),y,WC+rz*sin(b)),.005,'podSeal',parent)


def arm(parent, side, index):
    disk('Shoulder socket',(side*.67,-.77,.64),.12,.30,'podWhite',parent)
    shoulder=empty(f'arm_pod_{index}',(side*.67*S,-.97*S,.64*S),parent)
    disk('Shoulder bearing',(0,0,0),.104,.12,'podWhite',shoulder,(1,0,0))
    disk('Shoulder hub',(side*.067,0,0),.056,.018,'alu',shoulder,(1,0,0))
    for x in [-.047,.047]:
        tube('Upper parallel link',(x,0,.01),(x,0,.36),.025,'podWhite',shoulder)
        tube('Upper silver sleeve',(x,0,.04),(x,0,.12),.029,'steel',shoulder)
    tube('Arm cable',(0,.032,.07),(0,.032,.31),.011,'podSeal',shoulder)
    elbow=empty(f'arm_pod_{index+1}',(0,0,.36*S),shoulder)
    disk('Elbow bearing',(0,0,0),.079,.14,'podWhite',elbow,(1,0,0))
    for x in [-.047,.047]: tube('Forearm link',(x,0,0),(x,0,.36),.022,'podWhite',elbow)
    disk('Wrist',(0,0,.36),.07,.10,'podWhite',elbow,(0,0,1))
    for jaw in range(2):
        sign=-1 if jaw==0 else 1
        node=empty(f'arm_pod_{index+2+jaw}',(sign*.046*S,0,.40*S),elbow)
        tube('Claw upright',(0,0,0),(sign*.058,0,.115),.016,'podWhite',node)
        tube('Claw hook',(sign*.058,0,.115),(sign*.012,0,.16),.016,'podWhite',node)
        block('Gripper pad',(sign*.02,0,.15),(.045,.035,.032),'podSeal',node,.005)


def exterior(_):
    palette(); root=stage('pod')
    bpy.ops.mesh.primitive_uv_sphere_add(segments=128,ring_count=80,radius=R,location=(0,0,R))
    hull=bpy.context.object; hull.name='Pressure sphere'; hull.parent=root; hull.data.materials.append(M['podWhite'])
    # Keep the outside and inside as separate surfaces with a real sealed reveal.
    sol=hull.modifiers.new('Pressure wall','SOLIDIFY'); sol.thickness=.035*S
    bpy.context.view_layer.objects.active=hull; bpy.ops.object.modifier_apply(modifier=sol.name)
    bpy.ops.mesh.primitive_cylinder_add(vertices=128,radius=1,depth=2,location=(0,-1.0*S,WC*S),rotation=(pi/2,0,0))
    cut=bpy.context.object; cut.scale=(WX*S,WZ*S,.8*S); bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    boolean(hull,cut); smooth(hull,55)
    bpy.ops.mesh.primitive_cylinder_add(vertices=96,radius=1,depth=1.4*S,location=(0,1.4*S,1.10*S),rotation=(pi/2,0,0))
    cutter=bpy.context.object; cutter.scale=(.425*S,.55*S,1)
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    boolean(hull,cutter)
    window_ring(empty('window_reveal',(0,0,0),root))
    shade=empty('window_shade',(0,0,0),root)
    ob=disk('Dark cabin behind glazing',(0,-.38,WC),1,.006,'podSeal',shade)
    ob.scale=(.33, .385, 1)
    # The cradle frames the sphere from the sides; its centre stays open for the cabin.
    for side in [-1,1]:
        outline=[(.50,.12),(.82,.22),(.96,.42),(.96,.96),(.80,1.13),(.62,.99),(.62,.65),(.50,.36)]
        if side<0: outline=[(-x,z) for x,z in reversed(outline)]
        poly('Side cradle',outline,-.77,.43,'podWhite',root)
    block('Lower cradle bridge',(0,.05,.15),(1.18,.90,.12),'podWhite',root)
    for side in [-1,1]:
        for z in [.38,.91]:
            x=side*(.82 if z>.5 else .72)
            disk('Lamp recess',(x,-.755,z),.115,.025,'podSeal',root)
            disk('Lamp bezel',(x,-.78,z),.098,.035,'alu',root)
            disk('Headlamp',(x,-.805,z),.082,.014,'podLamp',root)
            # Three concentric rings give the lights a reflector rather than a flat dot.
            for rad in [.028,.052,.075]:
                for j in range(24):
                    a=j*2*pi/24; b=(j+1)*2*pi/24
                    tube('Lamp reflector',(x+rad*cos(a),-.815,z+rad*sin(a)),(x+rad*cos(b),-.815,z+rad*sin(b)),.0017,'steel',root)
        # Concentric conical ears, their roots intersect the sphere over a broad mount.
        verts=[]; faces=[]; n=240
        for dx,rad in [(0,.61),(.07,.64),(.23,.57),(.27,.46)]:
            for j in range(n):
                a=2*pi*j/n
                notch=.035*max(0,1-abs(j%12-6)/1.5)
                rr=rad-notch
                verts.append((side*(.86+dx)*S,(.13+rr*cos(a))*S,(1.03+rr*sin(a))*S))
        for ring in range(3):
            for j in range(n):
                k=ring*n+j; q=ring*n+(j+1)%n
                faces.append((k,q,q+n,k+n) if side>0 else (k+n,q+n,q,k))
        near=len(verts); verts.append((side*.86*S,.13*S,1.03*S))
        far=len(verts); verts.append((side*1.13*S,.13*S,1.03*S))
        for j in range(n):
            cap_a=(near,(j+1)%n,j)
            cap_b=(far,3*n+j,3*n+(j+1)%n)
            faces.extend([cap_a,cap_b] if side>0 else [tuple(reversed(cap_a)),tuple(reversed(cap_b))])
        ob=_obj('Notched thruster ear',verts,faces,M['podWhite'],root); smooth(ob,35)
        disk('Ear face',(side*1.137,.13,1.03),.46,.018,'podWhite',root,(side,0,0))
        profile=[(0,0),(.29,0)]
        profile += [(.29*cos(i*pi/32),.21*sin(i*pi/32)) for i in range(1,17)]
        cap=revolve('RCS central dome',profile,M['podWhite'],seg=48,parent=root)
        cap.location=(side*1.14*S,.13*S,1.03*S)
        cap.scale=(S,S,S)
        cap.rotation_mode='QUATERNION'
        cap.rotation_quaternion=Vector((0,0,1)).rotation_difference(Vector((side,0,0)))
        smooth(cap,50)
        for dy,dz in [(0,0),(.18,0),(-.18,0),(0,.18),(0,-.18)]:
            dx=sqrt(max(.03,1-(dy/.29)**2-(dz/.29)**2))*.21
            normal=Vector((side*dx/.21**2,dy/.29**2,dz/.29**2)).normalized()
            p=Vector((side*(1.14+dx),.13+dy,1.03+dz))
            disk('RCS port rim',tuple(p),.052,.027,'podWhite',root,tuple(normal))
            disk('RCS black port',tuple(p+normal*.015),.043,.007,'podSeal',root,tuple(normal))
        for j in range(4):
            a=pi/4+j*pi/2
            disk('Fine RCS ring',(side*1.154,.13+.37*cos(a),1.03+.37*sin(a)),.033,.014,'alu',root,(side,0,0))
            disk('Fine RCS throat',(side*1.165,.13+.37*cos(a),1.03+.37*sin(a)),.022,.008,'podSeal',root,(side,0,0))
        arm(root,side,0 if side<0 else 4)
    for side in [-1,1]:
        for x,z in [(side*.57,1.74),(side*.70,1.52)]:
            y=-sqrt(max(.01,1.03**2-x*x-(z-1.03)**2))
            normal=Vector((x,y,z-1.03)).normalized(); p=Vector((x,y,z))
            disk('Navigation camera surround',tuple(p),.047,.018,'podWhite',root,tuple(normal))
            disk('Navigation camera lens',tuple(p+normal*.012),.031,.008,'glass',root,tuple(normal))
    def surface(x,z,offset=.012):
        y=-sqrt(max(.01,1.03**2-x*x-(z-1.03)**2))
        normal=Vector((x,y,z-1.03)).normalized()
        return Vector((x,y,z))+normal*offset,normal
    # The service panel is conformal, with a curved lower edge, never a box over the hull.
    boundary=[(-.55,.80),(.55,.80),(.55,.53)]
    boundary += [(.55*cos(a*pi/40),.53-.30*sin(a*pi/40)) for a in range(1,41)]
    boundary += [(-.55,.80)]
    for i in range(len(boundary)-1):
        a,_=surface(*boundary[i]); b,_=surface(*boundary[i+1])
        tube('Service panel seam',tuple(a),tuple(b),.003,'dirty',root)
    for i in range(24):
        x=(i-11.5)*.034; p,n=surface(x,.856,.012)
        ob=block('Vent slot',tuple(p),(.009,.008,.033),'podSeal',root,.001)
        ob.rotation_mode='QUATERNION'; ob.rotation_quaternion=Vector((0,-1,0)).rotation_difference(n)
    for x,z,rad in [(0,.52,.077),(-.29,.49,.055),(.28,.57,.037),(.28,.39,.052)]:
        p,n=surface(x,z,.018)
        disk('Service socket',tuple(p),rad,.022,'alu',root,tuple(n))
        disk('Service recess',tuple(p+n*.014),rad*.70,.008,'podSeal',root,tuple(n))
    for i in range(6):
        p,n=surface(-.43+i*.024,.48,.018)
        ob=block('Service ribs',tuple(p),(.011,.017,.10),'alu',root,.002)
        ob.rotation_mode='QUATERNION'; ob.rotation_quaternion=Vector((0,-1,0)).rotation_difference(n)
    # Rear hatch: fixed for flight, with a bevelled recessed emergency panel.
    poly('Rear hatch',[(-.41,.49),(.41,.49),(.48,.70),(.43,1.53),(.27,1.70),(-.27,1.70),(-.43,1.53),(-.48,.70)],.78,.86,'podSeal',root)
    poly('Rear hatch skin',[(-.37,.52),(.37,.52),(.44,.70),(.39,1.51),(.25,1.66),(-.25,1.66),(-.39,1.51),(-.44,.70)],.84,.88,'podWhite',root)
    block('Emergency panel recess',(0,.89,1.08),(.46,.045,.65),'dirty',root,.04)
    block('Emergency panel',(0,.918,1.08),(.35,.025,.54),'podWhite',root,.035)
    block('Hatch caution',(0,.94,1.24),(.27,.008,.065),'red',root,.001)
    for x in [-.15,.15]: tube('Hatch pull',(x,.947,.92),(x,.947,1.06),.012,'steel',root)
    block('Rear step',(0,.82,.30),(.51,.38,.06),'podWhite',root)
    for x in [-.23,.23]: tube('Step bracket',(x,.57,.20),(x,.87,.28),.018,'alu',root)
    # The outlet and pivot share z=0; runtime plumes attach at the exit plane.
    pivot=empty('gimbal_pod_0_fixed',(0,0,0),root)
    bell=revolve('Recessed thruster',[(.09,0),(.084,.025),(.04,.12),(.025,.18)],M['nozzle'],seg=48,parent=pivot)
    bell.scale=(S,S,S); smooth(bell,45)
    # The cradle is a shell around the cabin, not a solid plug through its console.
    for name in ['Side cradle','Side cradle.001','Lower cradle bridge','Shoulder socket','Shoulder socket.001','Notched thruster ear','Notched thruster ear.001']:
        ob=bpy.data.objects.get(name)
        bpy.context.view_layer.objects.active=ob
        for modifier in list(ob.modifiers):
            bpy.ops.object.modifier_apply(modifier=modifier.name)
        bpy.ops.mesh.primitive_uv_sphere_add(segments=80,ring_count=48,radius=.985*S,location=(0,0,R))
        boolean(ob,bpy.context.object)
    for x in [-.43,.43]: block('Cradle foot',(x,.20,.035),(.12,.56,.07),'podSeal',root)
    from evapod_materials import assign_uvs
    assign_uvs()


def interior():
    reset_scene(); palette(); root=stage('pod')
    bpy.ops.mesh.primitive_uv_sphere_add(segments=96,ring_count=64,radius=.983*S,location=(0,0,R))
    liner=bpy.context.object; liner.name='Continuous cabin liner'; liner.parent=empty('window_liner',(0,0,0),root); liner.data.materials.append(M['podRed'])
    bpy.ops.mesh.primitive_cylinder_add(vertices=128,radius=1,depth=2*S,location=(0,-S,WC*S),rotation=(pi/2,0,0))
    cutter=bpy.context.object; cutter.scale=(WX*S,WZ*S,.8)
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    wall=liner.modifiers.new('Liner thickness','SOLIDIFY'); wall.thickness=.009*S
    bpy.context.view_layer.objects.active=liner; bpy.ops.object.modifier_apply(modifier=wall.name)
    boolean(liner,cutter); smooth(liner,55)
    from evapod_cabin import build as build_cabin
    from evapod_materials import assign_uvs
    build_cabin(root, M, S, SPEC["interior"]["eye"])
    assign_uvs(bake_modifiers=True)
    optimise()
    target=out_path('assets/craft/evapod.glb')
    dst=os.path.join(os.path.dirname(target),'.evapod_interior.build.glb' if os.path.basename(target).startswith('.') else 'evapod_interior.glb')
    export(dst,'evapod interior')


if __name__=='__main__':
    build('evapod',exterior)
    interior()
