"""Reference-judged Ranger-inspired lifting body. Own meshes and baked finishes.
The runtime export supplies the apertured skin, dimensions and flight datums.
"""
import os
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bpy
from math import atan2, pi, sin, cos
from mathutils import Vector, Matrix
from lib import _obj, empty, box, strut, ring_on, revolve, finish, reset_scene
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


def liner_point(point):
    x,y,z=point
    return Vector((x*.978,y,.24+(z-.24)*.948))


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
    for chine in S['geometry']['chines']:
        mount = empty(chine['name'], (0,0,0), root)
        shell = _obj('raised chine', [p(v) for v in chine['vertices']], chine['faces'], m['tps'], mount)
        finish(shell, .012, 2, 40)
    socket=mounted('aft docking recess',(0,0,.15),root)
    revolve('dock pressure recess',[(.68,.008),(.66,.11),(.49,.15),(.47,.27),(0,.27)],m['rubber'],seg=64,parent=socket)
    ring_on((0,0,.055),(0,0,1),.575,.043,m['alloy'],'docking capture flange',seg=64,parent=socket)
    for i in range(12):
        a=2*pi*i/12
        block('docking latch lug',(.57*cos(a),.055,.57*sin(a)),(.075,.062,.075),m['alloy'],socket,.014)
    # Blanket seams on the long nose deck, and small replaceable panel patches.
    for y,w in [(11.5,2.0),(13.0,1.75),(14.5,1.4),(16.0,.94)]:
        z=section_at(y)[2]+.012
        rod('blanket cross seam',(-w,y,z),(w,y,z),.012,m['alloy'],root)
    for x in [-.7,.7]:
        for ya,yb in zip([11.1,12.7,14.5,16.0],[12.7,14.5,16.0,16.7]):
            rod('nose blanket seam',(x,ya,section_at(ya)[2]+.012),(x,yb,section_at(yb)[2]+.012),.009,m['alloy'],root)
    # One full-width, skin-conforming radiator band across the aft shoulder.
    ymin,ymax=1.42,2.24
    stations=[ymin,.10*S['L'],ymax]
    for a,b in zip(stations,stations[1:]):
        wa,_,_,ca=section_at(a);wb,_,_,cb=section_at(b)
        left=[-.92*wa,-ca,ca,.92*wa]
        right=[-.92*wb,-cb,cb,.92*wb]
        for j in range(3):
            points=[(x,y,roof_at(x,y)+.025) for x,y in [(left[j],a),(left[j+1],a),(right[j+1],b),(right[j],b)]]
            poly('radiator band backing',points,m['panel'],root)
    for i in range(57):
        fraction=(i-28)*.032
        for a,b in zip([ymin+.035,stations[1]],[stations[1],ymax-.035]):
            wa,_,_,_=section_at(a);wb,_,_,_=section_at(b)
            x0,x1=fraction*wa,fraction*wb
            rod('radiator plate rib',(x0,a,roof_at(x0,a)+.034),
                (x1,b,roof_at(x1,b)+.034),.014,m['tps'],root)
    for side in [-1,1]:
        # Twin rectangular outlets are mounted on independent gimbals at the exit.
        piv=mounted(f'gimbal_ranger_{0 if side<0 else 1}',(side*1.45,0,0),root)
        # A short open box nozzle, with a recessed throat and continuous walls.
        for x in [-.36,.36]: block('nozzle side',(x,.24,0),(.035,.48,.58),m['alloy'],piv,.009)
        for z in [-.29,.29]: block('nozzle lip',(0,.24,z),(.72,.48,.035),m['alloy'],piv,.009)
        block('nozzle throat',(0,.45,0),(.65,.025,.50),m['tps'],piv,.0)
        for y,x in [(2.65,3.29),(10.75,2.98),(16.8,2.43)]:
            for n in [-1,0,1]:
                yy=y+n*.18
                at=Vector((side*x,yy,roof_at(side*x,yy)))
                ring_on(p(at),p((0,0,1)),.077,.019,m['alloy'],'recessed RCS rim',seg=20,parent=root)
                block('RCS throat',at-Vector((0,0,.014)),(.116,.116,.045),m['rubber'],root,.026)
    block('recessed aft pressure hatch',(0,.234,.15),(.65,.072,.65),m['panel'],root,.07)
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


def display(title, at, w, h, m, parent, traces=None):
    ob=mounted(title+' display',at,parent)
    block('display case',(0,0,0),(w,.084,h),m['rubber'],ob,.016)
    block('machined screen frame',(0,-.038,0),(w*.91,.023,h*.86),m['alloy'],ob,.009)
    block('dark display face',(0,-.051,0),(w*.84,.011,h*.76),m['screen'],ob,.008)
    block('glare lip',(0,-.058,h*.444),(w*.91,.052,h*.055),m['panel'],ob,.005)
    face=-.058
    label('display header',title,(0,face,h*.27),h*.087,ob,m['ink'])
    if traces:
        for i,(channel,value) in enumerate(traces):
            z=h*(.12-i*.128)
            label('readout channel',channel,(-w*.25,face,z),h*.068,ob,m['ink'])
            block('graph baseline',(w*.10,face,z),(w*.32,.002,h*.025),m['panel'],ob,0)
            width=w*.32*value
            block('channel level',(-w*.06+width/2,face-.002,z),(width,.002,h*.024),m['ink'],ob,0)
            label('channel value',f'{round(value*100):02d}',(w*.32,face,z),h*.068,ob,m['ink'])
    else:
        compact=w<h*1.2
        center=0 if compact else -w*.11
        radius=min(h*.245,w*.20)
        for i in range(32):
            a,b=i*pi/16,(i+1)*pi/16
            rod('attitude arc',(center+radius*cos(a),face,-.04*h+radius*sin(a)),
                (center+radius*cos(b),face,-.04*h+radius*sin(b)),.0014,m['ink'],ob)
        for i in range(-2,3):
            block('pitch ladder',(center,face,h*(i*.075-.04)),(radius*(1.0-abs(i)*.18),.002,.0025),m['ink'],ob,0)
            for sign in [-1,1]:
                block('attitude scale tick',(sign*w*.31,face,i*.10*h),(w*.039,.002,.002),m['ink'],ob,0)
        if not compact: label('attitude axes','PITCH / ROLL',(w*.22,face,-h*.24),h*.066,ob,m['ink'])
    for side in [-1,1]:
        for i in range(4):
            block('bezel key',(side*w*.47,-.047,h*(.27-i*.18)),(.020,.015,.019),m['legend'],ob,.003)


def annunciators(at, width, names, m, parent):
    ob=mounted('annunciator module',at,parent)
    block('annunciator housing',(0,0,0),(width,.054,.104),m['rubber'],ob,.008)
    pitch=width/(len(names)+.4)
    for i,name in enumerate(names):
        x=(i-(len(names)-1)/2)*pitch
        block('indicator bezel',(x,-.031,.012),(pitch*.76,.013,.035),m['alloy'],ob,.004)
        block('indicator lens',(x,-.040,.012),(pitch*.58,.009,.023),m['amber'] if i==0 else m['screen'],ob,.003)
        label('indicator legend',name,(x,-.029,-.033),.019,ob,m['legend'])


def overhead(m, root):
    crown=mounted('interior_overhead',(0,0,0),root)
    for y0,y1 in [(5.8,7.697),(7.697,9.22)]:
        a,b=roof_at(0,y0),roof_at(0,y1)
        base=block('crown raceway',(0,(y0+y1)/2,(a+b)/2-.083),(.31,y1-y0+.012,.045),m['panel'],crown,.008)
        base.rotation_euler.x=atan2(b-a,y1-y0)
    for y,title,levels in [(7.85,'BUS', [('A',.81),('B',.76),('AUX',.57)]),
                           (8.42,'ENV', [('PRES',.73),('O2',.88),('TEMP',.46)])]:
        z=roof_at(0,y)-.20
        bracket=block('crown instrument bracket',(0,y+.036,roof_at(0,y+.036)-.127),
                      (.25,.16,.105),m['alloy'],crown,.013)
        bracket.rotation_euler.x=atan2(roof_at(0,y+.12)-roof_at(0,y-.04),.16)
        display(title,(0,y,z),.26,.15,m,crown,levels)
        for dy in [-.11,.12]:
            bridge_z=roof_at(0,y+dy)-.083
            block('overhead handhold bridge',(0,y+dy,bridge_z),(.45,.057,.04),m['panel'],crown,.008)
        for side in [-1,1]:
            x=side*.201
            for dy in [-.11,.12]:
                rod('overhead handle foot',(x,y+dy,roof_at(0,y+dy)-.083),(x,y+dy,z+.037),.015,m['alloy'],crown)
            rod('overhead handhold',(x,y-.11,z+.037),(x,y+.12,z+.037),.016,m['rubber'],crown)


def interior(m):
    root=stage('ranger')
    liner=empty('window_liner',(0,0,0),root)
    # The liner follows the very same apertures, inset from the exterior skin.
    for row in S['geometry']['faces']:
        if row['name'] in ['aft','nose']: continue
        mat=m['cabin_quilt'] if row['name']=='window_frame' else m['liner']
        poly('pressure liner',[liner_point(v) for v in row['vertices']],mat,liner)
    for row in S['geometry']['windows']:
        vs=[Vector(v) for v in row['vertices']]
        normal=(vs[1]-vs[0]).cross(vs[2]-vs[0]).normalized()
        seal=[liner_point(v) for v in vs]
        center=sum(seal,Vector())/len(seal)
        inner=[center+(v-center)*.965 for v in seal]
        for j in range(len(vs)):
            k=(j+1)%len(vs)
            poly('window reveal',[vs[j]-normal*.004,vs[k]-normal*.004,seal[k],seal[j]],m['rubber'],root)
            poly('window seal',[seal[j],seal[k],inner[k],inner[j]],m['rubber'],root,-.004)
            rod('window inner frame',seal[j]-normal*.012,seal[k]-normal*.012,.019,m['alloy'],root)
    block('flight deck',(0,6.0,-.37),(4.8,6.3,.075),m['deck'],root)
    for y in [3.30,4.10,4.90,5.70,6.50,7.30,8.10]:
        block('inset aisle tread',(0,y,-.330),(.55,.76,.018),m['rubber'],root,.006)
        for side in [-1,1]:
            block('tread retainer',(side*.278,y,-.323),(.026,.76,.027),m['alloy'],root,.003)
        for dy in [-.27,-.135,0,.135,.27]:
            block('anti-slip ridge',(0,y+dy,-.317),(.47,.026,.013),m['tps'],root,.003)
    block('aft pressure bulkhead',(0,2.65,.56),(4.5,.10,2.1),m['liner'],root)
    block('crew passage seal',(0,2.712,.48),(1.04,.049,1.78),m['rubber'],root,.025)
    block('recessed pressure hatch',(0,2.739,.48),(.93,.035,1.65),m['panel'],root,.036)
    for side in [-1,1]:
        x=side*.39
        rod('hatch handle post',(x,2.748,.53),(x,2.84,.53),.021,m['alloy'],root)
        rod('hatch handle post',(x,2.748,.77),(x,2.84,.77),.021,m['alloy'],root)
        rod('hatch grab handle',(x,2.84,.53),(x,2.84,.77),.023,m['rubber'],root)
        block('aft blanket locker',(side*1.46,2.765,.52),(.63,.20,1.21),m['cabin_quilt'],root,.046)
        for dx in [-.21,.21]:
            block('locker retention webbing',(side*1.46+dx,2.868,.52),(.044,.020,1.12),m['webbing'],root,.005)
            block('locker strap buckle',(side*1.46+dx,2.887,.70),(.061,.027,.077),m['alloy'],root,.012)
        for y in [5.56,7.70]:
            w,_,_,crown=section_at(y)
            a=Vector((side*.20,y,roof_at(.20,y)-.071))
            b=Vector((side*crown,y,roof_at(crown,y)-.071))
            c=Vector((side*min(w-.13,crown+.78),y,roof_at(crown+.78,y)-.070))
            rod('canopy frame crown web',a,b,.027,m['alloy'],root)
            rod('canopy frame shoulder web',b,c,.027,m['alloy'],root)
    for x in [-.72,.72]:
        block('seat pedestal',(x,7.0,-.18),(.45,.65,.4),m['alloy'],root)
        block('seat cushion',(x,7.05,.06),(.64,.72,.19),m['seat'],root,.09)
        block('seat back',(x,6.72,.51),(.64,.18,.88),m['seat'],root,.08)
        block('headrest',(x,6.71,1.04),(.47,.20,.25),m['seat'],root,.07)
        block('backrest centre insert',(x,6.803,.54),(.36,.040,.72),m['seat'],root,.025)
        for z in [.30,.47,.64,.81]:
            rod('seat insert seam',(x-.145,6.825,z),(x+.145,6.825,z),.0028,m['webbing'],root)
        for dx in [-.22,.22]:
            block('harness',(x+dx,6.817,.54),(.065,.025,.79),m['webbing'],root,.007)
            block('armrest',(x+dx*1.65,7.05,.37),(.12,.66,.12),m['seat'],root)
            block('seat track',(x+dx,7.0,-.319),(.081,1.12,.061),m['rubber'],root,.008)
            block('seat track cap',(x+dx,7.0,-.286),(.048,1.06,.028),m['alloy'],root,.004)
            block('rear seatback rail',(x+dx,6.626,.49),(.048,.039,.82),m['alloy'],root,.006)
        block('rear seatback crossbar',(x,6.608,.28),(.48,.043,.09),m['panel'],root,.010)
        block('lap harness',(x,6.818,.18),(.49,.023,.058),m['webbing'],root,.006)
        block('harness buckle',(x,6.836,.18),(.12,.025,.082),m['alloy'],root,.009)
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
        height=.90 if x else 1.36
        block('console cabinet',(x,8.965,height*.5-.20),(1.10,.47,height),m['panel'],root)
        for side in [-1,1]:
            block('console frame rail',(x+side*.517,8.718,height*.5-.20),(.038,.043,height-.055),m['alloy'],root,.008)
            for z in [-.13,height-.26]:
                ring_on(p((x+side*.517,8.694,z)),p((0,1,0)),.009,.0027,m['rubber'],
                        'captive console screw',seg=12,minor=6,parent=root)
        if x<0:
            display('FLIGHT DIRECTOR',(x,8.78,.61),.84,.43,m,root)
        elif x>0:
            display('PROPULSION',(x,8.78,.61),.84,.43,m,root,[('FEED A',.83),('FEED B',.74),('CHAMB',.61),('RCS',.52)])
        if x:
            block('recessed switch plate',(x,8.721,.218),(.94,.043,.247),m['rubber'],root,.013)
            label('switch plate legend','NAV / ATTITUDE' if x<0 else 'FEED / REACTION CONTROL',
                  (x,8.696,.325),.022,root,m['legend'])
            for dx in [-.41,.41]:
                rod('rotary selector shaft',(x+dx,8.72,.062),(x+dx,8.659,.062),.034,m['alloy'],root)
                rod('rotary selector grip',(x+dx,8.69,.062),(x+dx,8.643,.062),.030,m['rubber'],root)
                block('selector position mark',(x+dx,8.641,.078),(.009,.004,.024),m['legend'],root,.002)
        for k in range(21 if x else 28):
            sx=x+(k%7-3)*.115 if x else [-.46,-.34,.34,.46][k%4]
            sz=.13+(k//7)*.085 if x else -.1+(k//4)*.2
            block('switch plinth',(sx,8.72,sz),(.045,.025,.045),m['alloy'],root,.005)
            rod('toggle lever',(sx,8.70,sz),(sx,8.655,sz+.015),.008,m['legend'],root)
        annunciators((x,8.71,-.075),.63,('PWR','WARN','AUX','TEST'),m,root)
    display('FLIGHT SYSTEMS',(0,8.72,1.045),.49,.29,m,root)
    display('DISTRIBUTION',(-.145,8.72,.69),.26,.27,m,root,[('BUS A',.81),('BUS B',.76),('BAT',.58)])
    display('CABIN',(.145,8.72,.69),.26,.27,m,root,[('O2',.88),('PRES',.75),('CO2',.20)])
    display('ATTITUDE',(-.145,8.72,.35),.26,.27,m,root)
    display('THERMAL',(.145,8.72,.35),.26,.27,m,root,[('LOOP A',.67),('LOOP B',.57),('OIL',.41)])
    annunciators((0,8.71,.115),.53,('ARM','RCS','OMS'),m,root)
    overhead(m,root)
    for side in [-1,1]:
        sideboard=mounted('side instruments',(side*1.45,7.65,.58),root)
        sideboard.rotation_euler=(0,-side*.30,0)
        block('side cabinet',(0,.065,-.14),(.71,.25,.82),m['panel'],sideboard,.025)
        rod('side cabinet floor support',(side*.18,.11,-.43),(side*.18,.11,-.93),.034,m['alloy'],sideboard)
        display('COMMS' if side<0 else 'ENVIRONMENT',(0,0,0),.65,.46,m,sideboard,
                [('UHF',.65),('S BAND',.92),('LINK',.73)] if side<0 else [('LOOP A',.71),('LOOP B',.64),('FAN',.82)])
        for k in range(9):
            block('side switches',((k%3-1)*.16,-.06,-.40+(k//3)*.07),(.06,.035,.035),m['legend'],sideboard,.005)
    for i,y in enumerate([4.0,6.2,7.8]):
        for side in [-1,1]:
            at=(side*1.50,y,roof_at(side*1.50,y)-.09)
            block('ceiling light housing',at,(.27,.65,.051),m['rubber'],root,.02)
            for dx in [-.065,.065]:
                block('recessed strip lamp',Vector(at)+Vector((dx,0,-.021)),(.052,.56,.023),m['lamp'],root,.009)
            mounted(f'interior_light_{i*2+(0 if side<0 else 1)}',Vector(at)-Vector((0,0,.10)),root)
    for side in [-1,1]:
        for y in [3.7,5.0]:
            block('equipment rack',(side*1.88,y,.17),(.5,.96,1.0),m['panel'],root)
            for z in [-.05,.25,.55]:
                block('equipment drawer',(side*1.6,y,z),(.07,.75,.22),m['alloy'],root)
                block('drawer recessed pull',(side*1.556,y,z+.018),(.027,.32,.058),m['rubber'],root,.012)
                for dy in [-.27,.27]:
                    block('drawer captive fastener',(side*1.56,y+dy,z),(.022,.043,.052),m['panel'],root,.008)
        for y in [3.1,4.8,6.6,8.4]:
            rod('cabin rail',(side*2.05,y,-.35),(side*2.05,y,roof_at(side*2.05,y)-.055),.028,m['alloy'],root)
    label('own identification','SURVEY / FLIGHT DECK',(0,2.72,1.34),.10,root,m['legend'])


def main():
    out=out_path('assets/craft/ranger.glb')
    reset_scene(); m=palette(); exterior(m); assign_uvs(); validate_vehicle('ranger'); optimise(); export(out,'ranger')
    reset_scene(); m=palette(cabin=True); interior(m); assign_uvs(); optimise()
    folder=os.path.dirname(out)
    name='.ranger_interior.build.glb' if os.path.basename(out).startswith('.') else 'ranger_interior.glb'
    export(os.path.join(folder,name),'ranger interior')


if __name__ == '__main__':
    main()
