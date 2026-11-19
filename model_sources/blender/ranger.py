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
from cabin_displays import instrument_atlas, glass
from vehicle_data import vehicle_stages
from movie_materials import palette, assign_uvs

S = vehicle_stages('ranger')['ranger']
C = Matrix(((1,0,0),(0,0,-1),(0,1,0)))
CABIN_DECK = -.255


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
    rows=S['geometry']['sections']; length=S['L']; half=S['look']['hullSpan']/2
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
        w=min(w,section_at(y)[3]-.05)
        z=section_at(y)[2]+.012
        rod('blanket cross seam',(-w,y,z),(w,y,z),.012,m['alloy'],root)
    for x in [-.7,.7]:
        for ya,yb in zip([11.1,12.7,14.5,16.0],[12.7,14.5,16.0,16.7]):
            rod('nose blanket seam',(x,ya,section_at(ya)[2]+.012),(x,yb,section_at(yb)[2]+.012),.009,m['alloy'],root)
    # One full-width, skin-conforming radiator band across the aft shoulder.
    ymin,ymax=1.02,2.42
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
        for wall in [-1,1]:
            for k in range(8):
                x=(k-3.5)*.083
                leaf=block('overlapping nozzle petal',(x,.18,wall*.254),
                           (.081,.36,.026),m['nozzle'],piv,.006)
                leaf.rotation_euler.x=wall*.13
            for k in range(4):
                rod('nozzle trunnion bolt',(wall*.347,.068,(k-1.5)*.105),
                    (wall*.36,.068,(k-1.5)*.105),.016,m['panel'],piv)
        for y,inboard in [(2.65,.65),(10.75,.43),(16.8,.24)]:
            for n in [-1,0,1]:
                yy=y+n*.18
                x=section_at(yy)[0]-inboard
                at=Vector((side*x,yy,roof_at(side*x,yy)))
                ring_on(p(at),p((0,0,1)),.077,.019,m['alloy'],'recessed RCS rim',seg=20,parent=root)
                block('RCS throat',at-Vector((0,0,.014)),(.116,.116,.045),m['rubber'],root,.026)
    block('recessed aft pressure hatch',(0,.234,.15),(.65,.072,.65),m['panel'],root,.07)
    for well in S['geometry']['wells']:
        poly(well['name'],well['vertices'],m['panel'],root)
    tyre_radius=S['rollout']['tyreR']
    for i,gear in enumerate(S['geometry']['gear']):
        x,y,z=gear['at']
        height=gear['ceiling']-z
        block('gear hinge carrier',(x,y,z+height*.5),(.29,.22,height+.06),m['alloy'],root,.024)
        rod('hinge pin',(x-.17,y,z),(x+.17,y,z),.042,m['alloy'],root)
        mount=mounted(f'gear mount {i}',(x,y,z),root)
        basis=Matrix(((0,0,1),(1,0,0),(0,1,0)))
        mount.rotation_euler=(C@basis@C.inverted()).to_euler()
        leg=empty(f'leg_ranger_{i}',(0,0,0),mount)
        arm=gear['arm']
        offset=gear['tyreOffset']
        block('oleo',(.5*arm,0,0),(arm,.12,.12),m['alloy'],leg)
        rod('wheel axle',(arm,-offset-.045,0),(arm,offset+.045,0),.06,m['alloy'],leg)
        for side in [-1,1]:
            y=side*offset
            ring_on(p((arm,y,0)),p((0,1,0)),tyre_radius-.07,.07,m['rubber'],'tyre',parent=leg)
            rod('wheel hub',(arm,y-.061,0),(arm,y+.061,0),tyre_radius-.113,m['alloy'],leg)
    # Seven independent trailing control surfaces share Shuttle control ordering.
    for i,at in enumerate(S['geometry']['flaps']):
        mount=mounted(f'flap mount {i}',at,root)
        basis=Matrix(((0,0,1),(1,0,0),(0,1,0)))
        mount.rotation_euler=(C@basis@C.inverted()).to_euler()
        flap=empty(f'flap_ranger_{i}',(0,0,0),mount)
        block('trailing flap',(-.36,0,0),(.70,.08,S['geometry']['flapWidth']),m['tps'],flap,.012)


def display(title, at, w, h, m, parent, page):
    ob=mounted(title+' display',at,parent)
    block('blackened instrument chassis',(0,0,0),(w,.082,h),m['panel'],ob,.016)
    block('glass bedding seal',(0,-.040,0),(w*.895,.015,h*.855),m['rubber'],ob,.008)
    glass(title+' glass',page,w*.85,h*.79,.002,
          lambda x,z,d:p((x,-.050-d,z)),m['phosphor'],ob)
    block('overhanging brow',(0,-.053,h*.475),(w*.99,.080,.021),m['panel'],ob,.006)
    for side in [-1,1]:
        for z in [-h*.405,h*.405]:
            rod('captive bezel pin',(side*w*.465,-.038,z),(side*w*.465,-.048,z),.0055,m['alloy'],ob)
        for i in range(4):
            block('bezel key',(side*w*.465,-.047,h*(.24-i*.16)),(.012,.015,.017),m['rubber'],ob,.002)
    return ob


def switch_card(at, w, h, channels, m, parent):
    ob=mounted('replaceable switch card',at,parent)
    block('flanged instrument tray',(0,0,0),(w,.027,h),m['rubber'],ob,.008)
    block('anodised card face',(0,-.016,0),(w-.009,.009,h-.010),m['panel'],ob,.003)
    for i,legend in enumerate(channels):
        x=w*((i+.5)/len(channels)-.5)
        label('engraved circuit',legend,(x,-.022,h*.24),min(.011,w/len(channels)*.24),ob,m['legend'])
        for j in range(2):
            z=h*(.09-j*.34)
            block('indicator shoe',(x,-.023,z),(.028,.008,.016),m['rubber'],ob,.002)
            block('opal indicator',(x,-.028,z),(.019,.004,.009),
                  m['amber'] if (i+j)%3 else m['legend'],ob,.0015)
            rod('switch ferrule',(x,-.020,z-.020),(x,-.032,z-.020),.009,m['alloy'],ob)
            rod('switch bat',(x,-.031,z-.020),(x,-.054,z-.020+(.009 if (i+j)%2 else -.007)),.004,m['alloy'],ob)
    for side in [-1,1]:
        for end in [-1,1]:
            x,z=side*(w*.5-.014),end*(h*.5-.014)
            rod('quarter turn fastener',(x,-.020,z),(x,-.024,z),.005,m['alloy'],ob)


def desk_shell(name, parent, widths, stations, m):
    """Pairs of deck heights follow the slope of the face at each fore/aft station."""
    verts=[]
    for w,(y,top,bottom) in zip(widths,stations):
        for x,z in [(-w/2,bottom),(w/2,bottom),(w/2,top),(-w/2,top)]:
            verts.append(p((x,y,z)))
    faces=[(0,1,2,3)]
    for k in range(len(stations)-1):
        for j in range(4):
            a=k*4+j; b=k*4+(j+1)%4
            faces.append((a,a+4,b+4,b))
    faces.append(tuple(reversed(range(len(verts)-4,len(verts)))))
    ob=_obj(name,verts,faces,m['panel'],parent)
    finish(ob,.018,3,38)


def instrument_deck(m, root):
    # The set's side stations hang above open footwells. The centre unit meets
    # the floor in the aisle and carries a second, inclined set of controls.
    for side in [-1,1]:
        bank=mounted('wraparound instrument wing',(side*1.16,8.53,.45),root)
        bank.rotation_euler=(C @ Matrix.Rotation(-side*.18,3,'Z') @
                             Matrix.Rotation(-.14,3,'X') @ C.inverted()).to_euler()
        desk_shell('faceted suspended instrument bay',bank,[1.18,1.28,1.21],
                   [(-.02,.159,-.145),(.12,.205,-.183),(.39,.135,-.12)],m)
        for col,page in enumerate((0,7,2) if side<0 else (1,5,4)):
            display('station monitor',((col-1)*.374,-.046,.001),.366,.265,m,bank,page)
        for end in [-1,1]:
            # The cabinet is pitched up. Resolve each leg against the horizontal deck.
            foot=(CABIN_DECK-.45+.31*sin(.14))/cos(.14)
            rod('rack support',(end*.48,.16,-.13),(end*.41,.31,foot),.028,m['alloy'],bank)
            block('rack foot flange',(end*.41,.31,foot+.004),(.102,.085,.016),m['panel'],bank,.004)
            rod('rack brace',(end*.48,-.01,-.13),(end*.41,.31,-.55),.016,m['panel'],bank)
        switch_card((-.275,.023,-.266),.50,.188,('NAV','TRIM','REF','GYRO'),m,bank)
        switch_card((.275,.023,-.266),.50,.188,('BUS','FEED','PUMP','TIE'),m,bank)
        block('panel hanger',(0,.072,-.17),(1.11,.066,.38),m['panel'],bank,.015)
        for dx in [-.46,.46]:
            rod('selector skirt',(dx,-.002,-.295),(dx,-.034,-.295),.031,m['alloy'],bank)
            rod('fluted selector',(dx,-.034,-.295),(dx,-.062,-.295),.026,m['rubber'],bank)
            block('selector witness',(dx,-.063,-.280),(.004,.003,.015),m['legend'],bank,.001)
        kick=mounted('insulated footwell',(side*1.11,9.04,.07),root)
        kick.rotation_euler.x=-.19
        block('insulated pressure panel',(0,0,0),(1.36,.10,.53),m['cabin_quilt'],kick,.04)
        block('maintenance recess',(0,-.052,0),(.97,.025,.24),m['rubber'],kick,.025)
        for k in range(12):
            u=(k-5.5)*.073
            block('return air grille vane',(u,-.070,0),(.020,.031,.18),m['panel'],kick,.004)
        for k in [-1,1]:
            rod('footwell kick rail',(k*.54,-.070,-.19),(k*.54,-.070,.19),.018,m['alloy'],kick)

    pedestal=mounted('centre aisle pedestal',(0,0,0),root)
    desk_shell('tapered pedestal fairing',pedestal,[.51,.61,.70,.74,.72],
               [(7.28,-.11,CABIN_DECK),(7.84,.205,CABIN_DECK),(8.32,.343,CABIN_DECK),
                (8.57,.724,CABIN_DECK),(8.89,.70,CABIN_DECK)],m)
    main=mounted('canted centre display frame',(0,8.445,.518),pedestal)
    main.rotation_euler.x=-.58
    for j in range(2):
        for i in range(3):
            display('systems repeater',((i-1)*.218,-.019,.09-j*.177),.213,.174,m,main,
                    [(2,3,6),(4,0,5)][j][i])
    for col in [-1,1]:
        card=mounted('throttle quadrant',(col*.146,8.04,.269),pedestal)
        card.rotation_euler.x=-1.28
        switch_card((0,0,0),.254,.36,('ARM','OMS','RCS'),m,card)
        for j in [-1,1]:
            rod('quadrant guard foot',(j*.107,0,-.16),(j*.107,-.044,-.16),.006,m['alloy'],card)
            rod('card guard',(j*.107,-.044,-.16),(j*.107,-.027,.16),.006,m['alloy'],card)
    for j in range(3):
        # Overlapping maintenance leaves continue down the sloping pedestal toward the aisle.
        y=7.38+j*.153
        lid=mounted('inclined pedestal access cover',(0,y,-.109+(y-7.28)*.5625+.006),pedestal)
        lid.rotation_euler.x=-1.058
        block('gasketed access leaf',(0,0,0),(.481,.014,.169),m['rubber'],lid,.006)
        block('removable cover',(0,-.008,0),(.468,.010,.158),m['panel'],lid,.005)
        for x in [-.204,.204]:
            rod('recessed cover screw',(x,-.013,-.049),(x,-.017,-.049),.007,m['alloy'],lid)
    for side in [-1,1]:
        for j in range(8):
            block('pedestal cooling fin',(side*.345,8.41+j*.045,.06),(.019,.014,.23),m['rubber'],pedestal,.003)


def overhead(m, root):
    crown=mounted('interior_overhead',(0,0,0),root)
    for y0,y1 in [(5.8,7.697),(7.697,9.22)]:
        a,b=roof_at(0,y0),roof_at(0,y1)
        base=block('crown raceway',(0,(y0+y1)/2,(a+b)/2-.083),(.31,y1-y0+.012,.045),m['panel'],crown,.008)
        base.rotation_euler.x=atan2(b-a,y1-y0)
    for y,title,page in [(7.32,'BUS',3),(8.42,'ENV',4)]:
        z=roof_at(0,y)-.20
        bracket=block('crown instrument bracket',(0,y+.036,roof_at(0,y+.036)-.127),
                      (.25,.16,.105),m['alloy'],crown,.013)
        bracket.rotation_euler.x=atan2(roof_at(0,y+.12)-roof_at(0,y-.04),.16)
        unit=mounted('overhead equipment tray',(0,y,z),crown)
        unit.rotation_euler.x=.67
        display(title,(0,0,0),.26,.15,m,unit,page)
        for side in [-1,1]:
            switch_card((side*.203,0,0),.131,.136,('A','B'),m,unit)
        for dy in [-.11,.12]:
            bridge_z=roof_at(0,y+dy)-.083
            block('overhead handhold bridge',(0,y+dy,bridge_z),(.45,.057,.04),m['panel'],crown,.008)
        for side in [-1,1]:
            x=side*.201
            for dy in [-.11,.12]:
                rod('overhead handle foot',(x,y+dy,roof_at(0,y+dy)-.083),(x,y+dy,z+.037),.015,m['alloy'],crown)
            rod('overhead handhold',(x,y-.11,z+.037),(x,y+.12,z+.037),.016,m['rubber'],crown)


def fitted_furnishings(name, parent, scale, y=0):
    # The feet of the seat tracks and console cabinets share the deck datum.
    mount=mounted(name,(0,y,CABIN_DECK+.33*scale),parent)
    mount.scale.y=scale
    return mount


def interior(m):
    root=stage('ranger')
    m['phosphor']=instrument_atlas('Ranger MFD',[(.60,.95,.99),(.18,.68,.77),(.05,.26,.34),(.99,.67,.25)])
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
            rod('pressure frame lip',seal[j]-normal*.012,seal[k]-normal*.012,.014,m['liner'],root)
            if (seal[k]-seal[j]).length>.36:
                for t in [.17,.83]:
                    v=seal[j].lerp(seal[k],t)-normal*.013
                    rod('glazing retainer stud',v,v-normal*.007,.009,m['alloy'],root)
    seating=fitted_furnishings('flight deck fittings',root,.78)
    block('flight deck',(0,6.0,-.37),(3.50,6.3,.075),m['deck'],seating)
    for y in [3.30,4.10,4.90,5.70,6.50,7.30,8.10]:
        block('inset aisle tread',(0,y,-.330),(.55,.76,.018),m['rubber'],seating,.006)
        for side in [-1,1]:
            block('tread retainer',(side*.278,y,-.323),(.026,.76,.027),m['alloy'],seating,.003)
        for dy in [-.27,-.135,0,.135,.27]:
            block('anti-slip ridge',(0,y+dy,-.317),(.47,.026,.013),m['tps'],seating,.003)
    aft=fitted_furnishings('aft pressure fittings',root,.70)
    y=2.711
    width,_,roof,crown=section_at(y)
    edge=width*.86
    bulkhead=poly('aft pressure bulkhead',[(edge,y,CABIN_DECK-.045),(-edge,y,CABIN_DECK-.045),
        (-edge,y,roof_at(edge,y)-.04),(-crown,y,roof-.04),(crown,y,roof-.04),
        (edge,y,roof_at(edge,y)-.04)],m['liner'],root)
    bulkhead.modifiers.new('pressure panel thickness','SOLIDIFY').thickness=.037
    block('crew passage seal',(0,2.712,.48),(1.04,.049,1.78),m['rubber'],aft,.025)
    block('recessed pressure hatch',(0,2.739,.48),(.93,.035,1.65),m['panel'],aft,.036)
    for side in [-1,1]:
        x=side*.39
        rod('hatch handle post',(x,2.748,.53),(x,2.84,.53),.021,m['alloy'],aft)
        rod('hatch handle post',(x,2.748,.77),(x,2.84,.77),.021,m['alloy'],aft)
        rod('hatch grab handle',(x,2.84,.53),(x,2.84,.77),.023,m['rubber'],aft)
        block('aft blanket locker',(side*1.46,2.765,.52),(.63,.20,1.21),m['cabin_quilt'],aft,.046)
        for dx in [-.21,.21]:
            block('locker retention webbing',(side*1.46+dx,2.868,.52),(.044,.020,1.12),m['webbing'],aft,.005)
            block('locker strap buckle',(side*1.46+dx,2.887,.70),(.061,.027,.077),m['alloy'],aft,.012)
        for y in [5.56,7.70]:
            w,_,_,crown=section_at(y)
            a=Vector((side*.20,y,roof_at(.20,y)-.071))
            b=Vector((side*crown,y,roof_at(crown,y)-.071))
            c=Vector((side*min(w-.13,crown+.78),y,roof_at(crown+.78,y)-.070))
            for start,end in [(a,b),(b,c)]:
                top=Vector((0,0,.043))
                along=(end-start).normalized()
                rod('pressure arch return',start+top,end+top,.016,m['liner'],root)
                rod('arch retention bead',start+top*.80,end+top*.80,.010,m['rubber'],root)
                for t in [.14,.44,.75]:
                    v=start.lerp(end,t)+top
                    rod('arch spigot',v-along*.024,v+along*.024,.020,m['panel'],root)
    for x in [-.72,.72]:
        block('seat height actuator',(x,7.0,-.18),(.24,.44,.36),m['panel'],seating,.048)
        for dx in [-.142,.142]:
            for y in [6.82,7.18]:
                rod('seat lift ram',(x+dx,y,-.31),(x+dx,y,.004),.035,m['alloy'],seating)
                rod('actuator dust boot',(x+dx,y,-.30),(x+dx,y,-.12),.043,m['rubber'],seating)
        block('seat cushion',(x,7.05,.06),(.64,.72,.19),m['seat'],seating,.09)
        block('seat back',(x,6.72,.51),(.64,.18,.88),m['seat'],seating,.08)
        for j in range(4):
            block('sewn transverse back roll',(x,6.631,.36+j*.134),
                  (.56-.020*abs(j-1),.070,.13),m['seat'],seating,.031)
        block('headrest',(x,6.71,1.04),(.47,.20,.25),m['seat'],seating,.07)
        block('backrest centre insert',(x,6.803,.54),(.36,.040,.72),m['seat'],seating,.025)
        for z in [.30,.47,.64,.81]:
            rod('seat insert seam',(x-.145,6.825,z),(x+.145,6.825,z),.0028,m['webbing'],seating)
        for dx in [-.22,.22]:
            block('harness',(x+dx,6.817,.54),(.065,.025,.79),m['webbing'],seating,.007)
            block('armrest',(x+dx*1.65,7.05,.37),(.12,.66,.12),m['seat'],seating)
            block('seat track',(x+dx,7.0,-.319),(.081,1.12,.061),m['rubber'],seating,.008)
            block('seat track cap',(x+dx,7.0,-.286),(.048,1.06,.028),m['alloy'],seating,.004)
            block('rear seatback rail',(x+dx,6.626,.49),(.048,.039,.82),m['alloy'],seating,.006)
        for side in [-1,1]:
            shell=block('contoured shoulder bolster',(x+side*.236,6.82,.62),(.135,.18,.67),m['seat'],seating,.060)
            shell.rotation_euler.z=side*.17
            for y in [6.71,7.23]:
                rod('seat pan pivot',(x+side*.262,y,-.13),(x+side*.30,y,-.13),.047,m['alloy'],seating)
            rod('seat carriage link',(x+side*.28,6.72,-.13),(x+side*.28,7.15,-.28),.026,m['panel'],seating)
            for k in range(7):
                block('slotted seatback pressing',(x+side*.20,6.599,.45+k*.052),(.105,.028,.017),m['panel'],seating,.005)
        block('rear seatback crossbar',(x,6.608,.28),(.48,.043,.09),m['panel'],seating,.010)
        block('lap harness',(x,6.818,.18),(.49,.023,.058),m['webbing'],seating,.006)
        block('harness buckle',(x,6.836,.18),(.12,.025,.082),m['alloy'],seating,.009)
        rod('control stalk',(x,7.58,.1),(x,7.58,.49),.025,m['alloy'],seating)
        block('controller pedestal',(x,7.58,-.10),(.25,.28,.46),m['panel'],seating)
        grip=mounted('flight controller grip',(x,7.58,.47),seating)
        grip.rotation_euler.x=.20
        handle=revolve('tapered elastomer grip',[(0,0),(.047,0),(.052,.025),(.040,.064),
                       (.042,.13),(.054,.17),(.049,.196),(0,.201)],m['rubber'],seg=24,parent=grip)
        handle.rotation_euler.x=pi/2
        handle.scale.y=.78
        for j in range(3):
            z=.052+j*.031
            rod('finger ledge',(-.032,.014,z),(.032,.014,z),.017,m['rubber'],grip)
        block('trigger paddle',(0,.044,.131),(.046,.022,.058),m['panel'],grip,.010)
        rod('thumb hat collar',(0,-.025,.17),(0,-.055,.17),.019,m['alloy'],grip)
        rod('thumb hat',(0,-.054,.17),(0,-.061,.17),.014,m['rubber'],grip)
        for dx in [-.16,.16]:
            block('rudder pedal',(x+dx,8.0,-.14),(.2,.30,.07),m['rubber'],seating)
            rod('pedal support',(x+dx,8.05,-.33),(x+dx,8.0,-.16),.025,m['alloy'],seating)
    instrument_deck(m,root)
    overhead(m,root)
    for side in [-1,1]:
        sideboard=mounted('side instruments',(side*1.60,7.42,.56),seating)
        # These are side-facing stations. Swing the complete instrument tray toward the seat.
        sideboard.rotation_euler.y=side*1.08
        block('side cabinet',(0,.065,-.14),(.71,.25,.82),m['panel'],sideboard,.025)
        rod('side cabinet floor support',(side*.18,.11,-.43),(side*.18,.11,-.93),.034,m['alloy'],sideboard)
        display('COMMS' if side<0 else 'ENVIRONMENT',(0,0,0),.65,.46,m,sideboard,
                6 if side<0 else 5)
        for k in range(9):
            block('side switches',((k%3-1)*.16,-.06,-.40+(k//3)*.07),(.06,.035,.035),m['legend'],sideboard,.005)
    for i,y in enumerate([4.0,6.2,7.34]):
        for side in [-1,1]:
            x=side*1.50
            fixture=mounted('ceiling strip mount',(x,y,roof_at(x,y)-.09),root)
            fixture.rotation_euler.x=atan2(roof_at(x,y+.325)-roof_at(x,y-.325),.65)
            block('ceiling light housing',(0,0,0),(.27,.65,.051),m['rubber'],fixture,.02)
            for dx in [-.065,.065]:
                block('recessed strip lamp',(dx,0,-.021),(.052,.56,.023),m['lamp'],fixture,.009)
            mounted(f'interior_light_{i*2+(0 if side<0 else 1)}',(0,0,-.10),fixture)
    for side in [-1,1]:
        for y in [3.7,5.0]:
            block('equipment rack',(side*1.47,y,.17),(.5,.96,1.0),m['panel'],seating)
            for z in [-.05,.25,.55]:
                block('equipment drawer',(side*1.19,y,z),(.07,.75,.22),m['alloy'],seating)
                block('drawer recessed pull',(side*1.146,y,z+.018),(.027,.32,.058),m['rubber'],seating,.012)
                for dy in [-.27,.27]:
                    block('drawer captive fastener',(side*1.15,y+dy,z),(.022,.043,.052),m['panel'],seating,.008)
        # An insulated knee wall closes the gap from the seat rails to the sloping hull.
        for j,(rear,front) in enumerate([(3.14,4.65),(4.68,6.15),(6.18,7.45),(7.48,8.85)]):
            x=side*1.89
            lip=roof_at(x,front)*.34
            points=[(x,rear,CABIN_DECK),(x,front,CABIN_DECK),
                    (x+side*.27,front,lip),(x+side*.27,rear,lip)]
            poly('tailored sidewall insulation',points,m['cabin_quilt'],root)
            rod('blanket edge channel',points[2],points[3],.017,m['liner'],root)
            for y in [rear+.08,front-.08]:
                rod('blanket tie down',(x,y,CABIN_DECK),(x+side*.27,y,lip),.008,m['webbing'],root)
        for y in [5.56,7.70]:
            x=side*1.50
            for dx in [-.15,.15]:
                v=(x+dx,y,roof_at(x+dx,y)-.085)
                rod('overhead grip foot',v,(v[0],y,v[2]-.043),.014,m['liner'],root)
            rod('overhead grab bar',(x-.15,y,roof_at(x-.15,y)-.128),
                (x+.15,y,roof_at(x+.15,y)-.128),.012,m['alloy'],root)
    label('own identification','SURVEY / FLIGHT DECK',(0,2.72,1.34),.10,aft,m['legend'])


def main():
    out=out_path('assets/craft/ranger.glb')
    reset_scene(); m=palette(); exterior(m); assign_uvs(); validate_vehicle('ranger'); optimise(); export(out,'ranger')
    reset_scene(); m=palette(cabin=True); interior(m)
    lettering=[ob for ob in bpy.context.scene.objects if ob.type=='FONT']
    bpy.ops.object.select_all(action='DESELECT')
    for ob in lettering: ob.select_set(True)
    bpy.context.view_layer.objects.active=lettering[0]
    bpy.ops.object.convert(target='MESH')
    assign_uvs(); optimise()
    folder=os.path.dirname(out)
    name='.ranger_interior.build.glb' if os.path.basename(out).startswith('.') else 'ranger_interior.glb'
    export(os.path.join(folder,name),'ranger interior')


if __name__ == '__main__':
    main()
