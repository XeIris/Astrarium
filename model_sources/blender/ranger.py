"""Reference-judged Ranger-inspired lifting body. Own meshes and baked finishes.
The runtime export supplies the apertured skin, dimensions and flight datums.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from math import pi, sin, cos
from mathutils import Vector, Matrix
from lib import empty, box, strut, ring_on, finish, material, reset_scene
from common import stage, optimise, export, out_path, validate_vehicle
from vehicle_data import vehicle_stages
from movie_materials import palette, assign_uvs

S = vehicle_stages('ranger')['ranger']
C = Matrix(((1,0,0),(0,0,-1),(0,1,0)))


def p(v):
    return C @ Vector(v)


def poly(name, points, mat, parent, offset=0):
    points = [Vector(v) for v in points]
    normal = (points[1]-points[0]).cross(points[2]-points[0]).normalized()
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata([p(v+normal*offset) for v in points], [], [list(range(len(points)))])
    mesh.update()
    ob = bpy.data.objects.new(name,mesh); bpy.context.collection.objects.link(ob)
    ob.parent=parent; mesh.materials.append(mat)
    return ob


def block(name, at, size, mat, parent, bevel=.025):
    ob=box(name,(size[0],size[2],size[1]),p(at),mat,parent=parent)
    if bevel: finish(ob,bevel,2,45)
    return ob


def rod(name,a,b,r,mat,parent):
    return strut(name,p(a),p(b),r,mat,parent=parent,seg=8)


def label(name,text,at,size,parent,mat,rot=None):
    curve=bpy.data.curves.new(name,'FONT'); curve.body=text; curve.size=size
    curve.align_x='CENTER'; curve.extrude=.0003
    ob=bpy.data.objects.new(name,curve); bpy.context.collection.objects.link(ob)
    ob.parent=parent; ob.location=p(at)
    # Labels lie on the console's aft-facing face, with their vertical along +Z.
    ob.rotation_euler=(pi,0,0) if rot is None else rot
    curve.materials.append(mat)
    return ob


def mounted(name,at,parent):
    return empty(name,p(at),parent)


def section_at(y):
    rows=S['geometry']['sections']; length=S['L']; half=S['D']/2
    for a,b in zip(rows,rows[1:]):
        if y<=b[0]*length:
            t=max(0,min(1,(y/length-a[0])/(b[0]-a[0])))
            v=[a[i]*(1-t)+b[i]*t for i in range(6)]
            return v[1]*half,v[3]*length,v[4]*length,v[5]*half
    return rows[-1][1]*half,rows[-1][3]*length,rows[-1][4]*length,rows[-1][5]*half


def roof_at(x,y):
    width,chine,roof,crown=section_at(y)
    t=max(0,min(1,(abs(x)-crown)/(width-crown)))
    return roof*(1-t)+chine*t


def exterior(m):
    root=stage('ranger')
    for row in S['geometry']['faces']:
        poly(row['name'],row['vertices'],m[row['material']],root)
    shade=empty('window_shade',(0,0,0),root)
    for row in S['geometry']['windows']:
        points=[Vector(v) for v in row['vertices']]
        poly(row['name'],points,m['glass'],shade,-.012)
        center=sum(points,Vector())/len(points)
        inner=[center+(v-center)*.96 for v in points]
        for j in range(len(points)):
            poly('window gasket',[points[j],points[(j+1)%len(points)],inner[(j+1)%len(points)],inner[j]],m['rubber'],root,.003)
    # A slim carbon leading-edge rail, attached to the chine along the deck.
    for side in [-1,1]:
        points=[(side*w,y,z+.01) for y in [17.5,14.5,10.5,5.3,1.8,.35]
                for w,z,_roof,_crown in [section_at(y)]]
        for a,b in zip(points,points[1:]):
            rod('chine rail',a,b,.055,m['tps'],root)
        # Raised fences follow the wing sweep rather than floating over the roof.
        for a,b in zip(points[1:-1],points[2:]):
            poly('leading edge fence',[a,b,Vector(b)+Vector((0,0,.30)),Vector(a)+Vector((0,0,.30))],m['tps'],root)
    # Blanket seams on the long nose deck, and small replaceable panel patches.
    for y,w in [(11.5,2.0),(13.0,1.75),(14.5,1.4),(16.0,.94)]:
        z=section_at(y)[2]+.012
        rod('blanket cross seam',(-w,y,z),(w,y,z),.012,m['alloy'],root)
    for x in [-.7,.7]:
        for ya,yb in zip([11.1,12.7,14.5,16.0],[12.7,14.5,16.0,16.7]):
            rod('nose blanket seam',(x,ya,section_at(ya)[2]+.012),(x,yb,section_at(yb)[2]+.012),.009,m['alloy'],root)
    # Rear shoulder thermal radiators, with physically separated ribs.
    for side in [-1,1]:
        block('radiator backing',(side*2.5,1.5,1.46),(3.7,1.1,.12),m['tps'],root)
        for k in range(25):
            block('radiator fin',(side*2.5+(k-12)*.135,1.5,1.535),(.035,1.04,.035),m['panel'],root,.006)
        # Twin rectangular outlets are mounted on independent gimbals at the exit.
        piv=mounted(f'gimbal_ranger_{0 if side<0 else 1}',(side*1.45,0,0),root)
        # A short open box nozzle, with a recessed throat and continuous walls.
        for x in [-.36,.36]: block('nozzle side',(x,.24,0),(.035,.48,.58),m['alloy'],piv,.009)
        for z in [-.29,.29]: block('nozzle lip',(0,.24,z),(.72,.48,.035),m['alloy'],piv,.009)
        block('nozzle throat',(0,.45,0),(.65,.025,.50),m['tps'],piv,.0)
        for y in [2.6,9.0]:
            at=(side*(3.85 if y<5 else 2.7),y,.56)
            block('RCS manifold',at,(.32,.74,.16),m['alloy'],root)
            for n in range(3): block('RCS socket',(at[0],y+(n-1)*.22,.655),(.13,.13,.045),m['rubber'],root,.035)
    # Docking collar has a closed central hatch; no loose ring behind the ship.
    for radius,tube in [(.58,.09),(.48,.035)]:
        ring_on(p((0,.10,.13)),p((0,1,0)),radius,tube,m['alloy'],'docking collar',parent=root)
    block('aft hatch',(0,.10,.13),(.84,.14,.84),m['panel'],root,.1)
    for i in range(3):
        at=(0 if i==0 else (-2.8 if i==1 else 2.8),13.8 if i==0 else 3.7,-.47)
        mount=mounted(f'gear mount {i}',at,root)
        basis=Matrix(((0,0,1),(1,0,0),(0,1,0)))
        mount.rotation_euler=(C@basis@C.inverted()).to_euler()
        leg=empty(f'leg_ranger_{i}',(0,0,0),mount)
        block('oleo',(.48,0,0),(.96,.12,.12),m['alloy'],leg)
        for j in [-1,1]:
            ring_on(p((.98,j*.15,0)),p((0,1,0)),.25,.07,m['rubber'],'tyre',parent=leg)
        block('gear well ceiling',(at[0],at[1]+.52,-.10),(.96,1.7,.07),m['tps'],root)
        for side in [-1,1]:
            block('gear well side',(at[0]+side*.48,at[1]+.52,-.38),(.025,1.7,.54),m['alloy'],root,.006)
    # Seven independent trailing control surfaces share Shuttle control ordering.
    for i in range(7):
        mount=mounted(f'flap mount {i}',((i-3)*.95,.9,.1),root)
        basis=Matrix(((0,0,1),(1,0,0),(0,1,0)))
        mount.rotation_euler=(C@basis@C.inverted()).to_euler()
        flap=empty(f'flap_ranger_{i}',(0,0,0),mount)
        block('trailing flap',(-.36,0,0),(.70,.08,.85),m['tps'],flap,.012)


def display(name,at,w,h,m,parent):
    block(name,at,(w,.085,h),m['panel'],parent,.025)
    block('screen',Vector(at)+Vector((0,.0,.0)),(w*.87,.098,h*.80),m['screen'],parent,.01)
    # Original vector-like graphics; the film's graphics are observed, never copied.
    face=at[1]-.055
    for i in range(7):
        z=at[2]+h*(.28-i*.085)
        block('schematic trace',(at[0]+w*.23,face,z),(w*(.18+.025*(i%3)),.004,.004),m['ink'],parent,.0)
    radius=min(w*.25,h*.32)
    for i in range(36):
        a,b=i*pi/18,(i+1)*pi/18
        rod('attitude circle',(at[0]-w*.16+radius*cos(a),face,at[2]+radius*sin(a)),
            (at[0]-w*.16+radius*cos(b),face,at[2]+radius*sin(b)),.0018,m['ink'],parent)
    for dz in [-.12,0,.12]:
        block('attitude ladder',(at[0]-w*.16,face,at[2]+dz*h),(radius*.9,.003,.003),m['ink'],parent,.0)
    label('display header','SYS / NAV',(at[0],face-.003,at[2]+h*.32),h*.065,parent,m['ink'])
    for x in [-1,1]:
        for i in range(4):
            block('display bezel key',(at[0]+x*w*.46,at[1]-.06,at[2]+h*(.27-i*.18)),(.023,.015,.023),m['legend'],parent,.004)


def interior(m):
    root=stage('ranger')
    liner=empty('window_liner',(0,0,0),root)
    # The liner follows the very same apertures, inset from the exterior skin.
    for row in S['geometry']['faces']:
        if row['name'] in ['aft','nose']: continue
        poly('pressure liner',row['vertices'],m['liner'],liner,-.065)
    for row in S['geometry']['windows']:
        vs=[Vector(v) for v in row['vertices']]
        normal=(vs[1]-vs[0]).cross(vs[2]-vs[0]).normalized()
        for j in range(len(vs)): rod('window inner frame',vs[j]-normal*.07,vs[(j+1)%len(vs)]-normal*.07,.028,m['alloy'],root)
    block('flight deck',(0,6.0,-.37),(4.8,6.3,.075),m['panel'],root)
    block('aft pressure bulkhead',(0,2.65,.56),(4.5,.10,2.1),m['liner'],root)
    block('crew passage',(0,2.71,.48),(.95,.04,1.75),m['rubber'],root)
    for x in [-.72,.72]:
        block('seat pedestal',(x,7.0,-.18),(.45,.65,.4),m['alloy'],root)
        block('seat cushion',(x,7.05,.06),(.64,.72,.19),m['seat'],root,.09)
        block('seat back',(x,6.72,.51),(.64,.18,.88),m['seat'],root,.08)
        block('headrest',(x,6.71,1.04),(.47,.20,.25),m['seat'],root,.07)
        for dx in [-.22,.22]:
            block('harness',(x+dx,6.61,.54),(.065,.025,.79),m['webbing'],root,.007)
            block('armrest',(x+dx*1.65,7.05,.37),(.12,.66,.12),m['seat'],root)
        block('harness buckle',(x,6.61,.19),(.12,.03,.10),m['alloy'],root)
        rod('control stalk',(x,7.58,.1),(x,7.58,.49),.025,m['alloy'],root)
        block('controller pedestal',(x,7.58,-.10),(.25,.28,.46),m['panel'],root)
        block('hand controller',(x,7.58,.55),(.12,.11,.20),m['rubber'],root,.035)
        block('controller trigger',(x+.065,7.57,.60),(.025,.06,.06),m['amber'],root,.008)
        for dx in [-.16,.16]:
            block('rudder pedal',(x+dx,8.0,-.14),(.2,.30,.07),m['rubber'],root)
            rod('pedal support',(x+dx,8.05,-.33),(x+dx,8.0,-.16),.025,m['alloy'],root)
    # Low forward consoles preserve a view through the four sloped windshields.
    for x in [-1.20,0,1.20]:
        block('console floor plinth',(x,8.98,-.27),(1.0,.40,.14),m['alloy'],root)
        block('console cabinet',(x,9.0,.25 if x else .55),(1.10,.38,.9 if x else 1.5),m['panel'],root)
        if x: display('flight display',(x,8.78,.61),.84,.43,m,root)
        label('console legend','NAVIGATION' if x<0 else 'FLIGHT SYSTEMS' if x==0 else 'PROPULSION',(x,8.718,.88 if x else 1.32),.035,root,m['legend'])
        for k in range(21 if x else 28):
            sx=x+(k%7-3)*.115 if x else [-.46,-.34,.34,.46][k%4]
            sz=.13+(k//7)*.085 if x else -.1+(k//4)*.2
            block('switch plinth',(sx,8.72,sz),(.045,.025,.045),m['alloy'],root,.005)
            rod('toggle lever',(sx,8.70,sz),(sx,8.655,sz+.015),.008,m['legend'],root)
        for k in range(4):
            block('annunciator',(x+(k-1.5)*.19,8.72,-.05),(.12,.015,.035),m['amber'] if k==0 else m['panel'],root,.004)
    # A central instrument stack and paired side-wall monitors.
    for z in [.22,.63,1.03]: display('central stack',(0,8.72,z),.38,.31,m,root)
    for side in [-1,1]:
        sideboard=mounted('side instruments',(side*1.45,7.65,.58),root)
        sideboard.rotation_euler=(0,-side*.30,0)
        display('side display',(0,0,0),.65,.46,m,sideboard)
        for k in range(9):
            block('side switches',((k%3-1)*.16,-.06,-.40+(k//3)*.07),(.06,.035,.035),m['legend'],sideboard,.005)
    for i,y in enumerate([4.0,6.2,7.8]):
        for side in [-1,1]:
            at=(side*1.50,y,roof_at(side*1.50,y)-.09)
            block('recessed ceiling lamp',at,(.27,.65,.04),m['lamp'],root,.02)
            mounted(f'interior_light_{i*2+(0 if side<0 else 1)}',Vector(at)-Vector((0,0,.10)),root)
    for side in [-1,1]:
        for y in [3.7,5.0]:
            block('equipment rack',(side*1.88,y,.17),(.5,.96,1.0),m['panel'],root)
            for z in [-.05,.25,.55]:
                block('equipment drawer',(side*1.6,y,z),(.07,.75,.22),m['alloy'],root)
        for y in [3.1,4.8,6.6,8.4]:
            rod('cabin rail',(side*2.05,y,-.35),(side*2.05,y,roof_at(side*2.05,y)-.055),.028,m['alloy'],root)
    label('own identification','SURVEY / FLIGHT DECK',(0,2.72,1.34),.10,root,m['legend'])


def main():
    out=out_path('assets/craft/ranger.glb')
    reset_scene(); m=palette(); exterior(m); assign_uvs(); validate_vehicle('ranger'); optimise(); export(out,'ranger')
    reset_scene(); m=palette(); interior(m); assign_uvs(); optimise()
    folder=os.path.dirname(out)
    name='.ranger_interior.build.glb' if os.path.basename(out).startswith('.') else 'ranger_interior.glb'
    export(os.path.join(folder,name),'ranger interior')


main()
