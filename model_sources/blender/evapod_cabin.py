"""A fitted, faceted cockpit from the film reference study in docs/eva-pod.md."""
from math import pi, sin, cos, sqrt
import bpy
import bmesh
from mathutils import Vector, Matrix
from lib import box, empty, revolve, strut, finish, smooth, _obj

M = {}
S = 1.0
EYE = Vector()


def block(name, pos, size, mat, parent, bevel=.004):
    ob = box(name,tuple(v*S for v in size),tuple(v*S for v in pos),M[mat],parent=parent)
    if bevel: finish(ob,bevel*S,3,40)
    return ob


def tube(name, a, b, radius, mat, parent, segments=12):
    ob = strut(name,tuple(v*S for v in a),tuple(v*S for v in b),radius*S,M[mat],seg=segments,parent=parent)
    smooth(ob,45)
    return ob


def disk(name, pos, radius, depth, mat, parent, axis=(0,-1,0)):
    d=depth*S/2; r=radius*S
    ob=revolve(name,[(0,-d),(r,-d),(r,d),(0,d)],M[mat],seg=24,parent=parent)
    ob.location=tuple(v*S for v in pos)
    ob.rotation_mode='QUATERNION'
    ob.rotation_quaternion=Vector((0,0,1)).rotation_difference(Vector(axis))
    finish(ob,min(.002,depth*.12)*S,2,40)
    smooth(ob,45)
    return ob


def mount(name, pos, parent, target=None):
    normal=(Vector(target if target is not None else EYE)-Vector(pos)).normalized()
    up=Vector((0,0,1)) if abs(normal.z)<.92 else Vector((0,-1,0))
    right=up.cross(normal).normalized(); up=normal.cross(right).normalized()
    ob=empty(name,tuple(v*S for v in pos),parent)
    ob.rotation_mode='QUATERNION'
    ob.rotation_quaternion=Matrix((right,-normal,up)).transposed().to_quaternion()
    return ob


def slab(name, outline, y0, y1, mat, parent, bevel=.002):
    n=len(outline)
    verts=[(x*S,y*S,z*S) for y in [y0,y1] for x,z in outline]
    faces=[tuple(range(n-1,-1,-1)),tuple(range(n,2*n))]
    faces += [(i,(i+1)%n,(i+1)%n+n,i+n) for i in range(n)]
    ob=_obj(name,verts,faces,M[mat],parent)
    bm=bmesh.new();bm.from_mesh(ob.data)
    bmesh.ops.recalc_face_normals(bm,faces=bm.faces)
    bm.to_mesh(ob.data);bm.free()
    if bevel:finish(ob,bevel*S,2,40)
    return ob


def text(parent, value, pos, size=.007, mat='podLegend'):
    curve=bpy.data.curves.new('Engraved legend','FONT')
    curve.body=value; curve.align_x='CENTER'; curve.align_y='CENTER'; curve.size=size*S
    curve.space_character=1.05;curve.extrude=0
    ob=bpy.data.objects.new('Legend '+value,curve);bpy.context.collection.objects.link(ob)
    ob.parent=parent;ob.location=tuple(v*S for v in pos);ob.rotation_euler=(pi/2,0,0)
    ob.data.materials.append(M[mat])
    bpy.ops.object.select_all(action='DESELECT');ob.select_set(True);bpy.context.view_layer.objects.active=ob
    bpy.ops.object.convert(target='MESH')


def rule(parent, x, z, w, h, mat='podLegend', y=-.029):
    for a,b in [((x-w/2,y,z-h/2),(x+w/2,y,z-h/2)),((x+w/2,y,z-h/2),(x+w/2,y,z+h/2)),
                ((x+w/2,y,z+h/2),(x-w/2,y,z+h/2)),((x-w/2,y,z+h/2),(x-w/2,y,z-h/2))]:
        tube('Silkscreen group outline',a,b,.00045,mat,parent,6)


def screw(parent, x, z, y=-.030):
    disk('Captive panel screw',(x,y,z),.0038,.002,'steel',parent)
    block('Screw slot',(x,y-.0013,z),(.004,.0007,.0007),'podInk',parent,.0001)


def panel(name, pos, width, height, parent, heading, shape=None):
    ob=mount(name,pos,parent)
    pts=shape or [(-width/2,-height/2),(width/2,-height/2),(width/2,height/2),(-width/2,height/2)]
    slab(name+' enclosure',pts,-.020,.009,'podSeal',ob,.005)
    slab(name+' laminate',[(x*.975,z*.975) for x,z in pts],-.026,-.019,'podPanel',ob,.0015)
    text(ob,heading,(0,-.028,height/2-.023),.009)
    for x in [-width/2+.013,width/2-.013]:
        for z in [-height/2+.013,height/2-.013]: screw(ob,x,z)
    return ob


def key(parent, x, z, label, color='podBlue', width=.027, height=.021):
    block('Switch mounting flange',(x,-.029,z),(width+.006,.006,height+.006),'podKeyRim',parent,.002)
    block('Switch bezel',(x,-.033,z),(width+.003,.005,height+.003),'podSeal',parent,.0015)
    body='podKeyAmber' if color=='podAmber' else ('podKeyIvory' if color=='podWarm' else 'podKeyBlue')
    block('Moulded acrylic button',(x,-.038,z),(width,.013,height),body,parent,.002)
    block('Backlit button face',(x,-.044,z),(width-.003,.002,height-.003),color,parent,.0015)
    text(parent,label,(x,-.0452,z),.0037,'podInk')


def grid(parent, rows, x=0, z=0, pitch=.043, gap=.037):
    for j,row in enumerate(rows):
        for i,entry in enumerate(row):
            label,color=entry if isinstance(entry,tuple) else (entry,'podBlue')
            key(parent,x+(i-(len(row)-1)/2)*pitch,z+((len(rows)-1)/2-j)*gap,label,color)


def toggle(parent,x,z,label,up=True):
    disk('Toggle retaining nut',(x,-.033,z),.007,.006,'steel',parent)
    tube('Toggle stem',(x,-.036,z),(x,-.051,z+(.012 if up else -.012)),.0022,'steel',parent,8)
    block('Paddle switch handle',(x,-.051,z+(.012 if up else -.012)),(.008,.006,.013),'podSeal',parent,.002)
    text(parent,label,(x,-.030,z-.020),.0048)


def round_controls(parent, side):
    ob=mount('Circular service controls',(side*.53,-.20,1.37),parent)
    disk('Round recessed bezel',(0,0,0),.141,.026,'podSeal',ob)
    disk('Round control plate',(0,-.018,0),.129,.010,'podPanel',ob)
    text(ob,'D.C. POWER' if side>0 else 'RCS FEED',(0,-.025,.097),.008)
    for row in range(1 if side>0 else 2):
        for col in range(3):
            if side>0 and col==1:continue
            toggle(ob,(col-1)*.053,.042-row*.040,str(col+1+row*3),row==0)
    for i,label in enumerate(['ON','OFF','TEST']):key(ob,(i-1)*.043,-.072,label)
    for i in range(4):
        x=(i-1.5)*.035
        disk('Recessed panel lamp bezel',(x,-.025,.072),.0065,.004,'podKeyRim',ob)
        disk('Coloured panel lamp lens',(x,-.0275,.072),.0045,.003,
             'podAmber' if i==0 else 'podKeyOff',ob)
    for angle in [pi/4,3*pi/4,5*pi/4,7*pi/4]:screw(ob,.119*cos(angle),.119*sin(angle),-.026)


def displays(parent):
    rack=panel('Dished forward display rack',(0,-.62,.83),.72,.25,parent,'FLIGHT / SYSTEM MONITOR',
               [(-.36,-.102),(-.29,-.143),(.29,-.143),(.36,-.102),(.35,.125),(-.35,.125)])
    for side in [-1,1]:
        ob=empty('Inward canted display',(side*.174*S,-.026*S,-.013*S),rack)
        ob.rotation_euler.z=side*.11
        block('Display gasket',(0,0,0),(.309,.026,.181),'podSeal',ob,.012)
        block('Anodised display frame',(0,-.013,0),(.292,.009,.163),'podKeyRim',ob,.006)
        block('Moulded CRT face',(0,-.020,0),(.282,.010,.153),'podScreen',ob,.008)
        rule(ob,0,0,.268,.139,'podKeyOff',-.026)
        text(ob,'ATTITUDE' if side<0 else 'VEHICLE SYSTEMS',(0,-.028,.059),.008,'podScreenInk')
        if side<0:
            for x in [-.07,0,.07]:
                tube('Display grid',(x,-.027,-.047),(x,-.027,.041),.0006,'podKeyOff',ob,5)
            for z in [-.033,0,.033]:
                tube('Display grid',(-.126,-.027,z),(.126,-.027,z),.0006,'podKeyOff',ob,5)
            for a,b in [((-.06,-.028,-.027),(0,-.028,.023)),((0,-.028,.023),(.06,-.028,-.027)),
                        ((-.06,-.028,-.027),(.06,-.028,-.027)),((0,-.028,-.04),(0,-.028,.039))]:
                tube('Attitude schematic',a,b,.0011,'podScreenInk',ob,6)
            text(ob,'ROLL       PITCH       YAW',(0,-.028,-.061),.006,'podScreenInk')
        else:
            for i,label in enumerate(['RCS','CABIN','BUS','FUEL']):
                z=.030-i*.023
                text(ob,label,(-.086,-.028,z),.007,'podScreenInk')
                rule(ob,.040,z,.139,.011,'podKeyOff',-.027)
                block('System status trace',(.018-i*.005,-.028,z),(.094-i*.010,.001,.003),'podScreenInk',ob,.0001)
        for x in [-.158,.158]:screw(ob,x,.072,-.018)
        for x in [-.138,.138]:
            tube('Display hood side',(x,-.020,.078),(x,-.039,.083),.0025,'podSeal',ob)
        block('Display glare lip',(0,-.029,.084),(.278,.024,.008),'podSeal',ob,.002)
    for side in [-1,1]:
        bracket=mount('Display rack support',(side*.27,-.55,.66),parent)
        block('Rack lower bracket',(0,0,0),(.065,.105,.11),'podRed',bracket,.008)
    return rack


def consoles(parent):
    for side in [-1,1]:
        shape=[(-.21,-.17),(.21,-.17),(.18,.17),(-.16,.17)]
        ob=panel('Polygonal manipulator console',(side*.425,-.33,.78),.42,.34,parent,
                 'PORT MANIPULATOR' if side>0 else 'STBD MANIPULATOR',shape)
        rows=[['LOCK','EXT','RET','HOLD','TEST'],
              ['YAW L','YAW R','UP','DOWN','IN'],
              ['WRIST','ROT L','ROT R','OPEN','CLOSE']]
        grid(ob,rows,x=-.031,z=.008,pitch=.052,gap=.043)
        for z,label,col in [(.061,'POWER','podWarm'),(.008,'ENABLE','podWarm'),(-.045,'SAFE','podAmber')]:
            key(ob,.150,z,label,col,.031,.033)
        rule(ob,0,.008,.358,.145)
        text(ob,'ATTITUDE / TRANSLATION',(0,-.028,-.091),.007)
        grid(ob,[[('OFF','podKeyOff'),'PRO','RET','NML','RAD',('ARM','podWarm')]],z=-.123,pitch=.054)
        # The lower switch rows mount through the face; cap backs overlap the bezels.
        for x in [-.165,.165]:screw(ob,x,-.080)
        for i in range(2):toggle(ob,-.12+i*.055,.124,'AUX',i==0)
        # The panel backs and their loom terminate on hull-mounted brackets.
        block('Console attachment rail',(0,.012,-.03),(.32,.028,.21),'podRed',ob,.006)


def side_banks(parent):
    for side in [-1,1]:
        ob=panel('Side services console',(side*.685,.045,1.16),.28,.37,parent,
                 'LIFE SUPPORT' if side>0 else 'POWER / COMMS')
        services=[[('ON','podWarm'),'AUTO','OFF'],['O2','CO2','VENT'],['PUMP','HEAT','FAN']]
        power=[[('ON','podWarm'),'AUTO','OFF'],['BUS A','BUS B','AUX'],['TX','RX','MUTE']]
        grid(ob,services if side>0 else power,z=.048,pitch=.061)
        rule(ob,0,.048,.207,.127)
        text(ob,'CABIN SERVICES' if side>0 else 'BUS DISTRIBUTION',(0,-.028,-.045),.007)
        grid(ob,[['PRI','SEC','TIE'],[('TEST','podWarm'),'RESET',('ISOL','podAmber')]],z=-.102,pitch=.061)
        rule(ob,0,-.102,.207,.090)
        aft=panel('Rear electrical panel',(side*.44,.55,1.24),.27,.32,parent,
                  'PRESSURIZATION' if side>0 else 'COMMUNICATIONS')
        grid(aft,[['MAIN','RES','REG'],['ON','AUTO','OFF']],z=.066,pitch=.064)
        rule(aft,0,.066,.217,.086)
        for i in range(4):toggle(aft,(i-1.5)*.052,-.025,str(i+1),i%2==0)
        grid(aft,[[('LINK','podWarm'),'LOCAL',('TEST','podKeyOff')]],z=-.104,pitch=.064)
        for i in range(4):
            disk('Bus indicator bezel',((i-1.5)*.052,-.030,-.062),.005,.005,'podSeal',aft)
            disk('Bus indicator lens',((i-1.5)*.052,-.034,-.062),.0035,.003,'podGreen',aft)


def upholstery(parent):
    # Leave the centre aft sector open for the pressure hatch and its controls.
    for a in [pi*.46,pi*.65,pi*.82,pi*1.18,pi*1.35,pi*1.54]:
        for z in [.78,1.12,1.46]:
            radius=sqrt(max(.08,.945**2-(abs(z-1.03)+.16)**2))
            ob=mount('Leatherette cushion mount',(radius*sin(a),-radius*cos(a),z),parent,(0,0,z))
            block('Upholstery backing',(0,0,0),(.325,.028,.302),'podSeal',ob,.012)
            block('Foam padded leatherette',(0,-.023,0),(.311,.048,.288),'podPad',ob,.028)
            rule(ob,0,0,.270,.247,'podSeam',-.048)
            for x in [-.145,.145]:
                for dz in [-.126,.126]:disk('Upholstery fixing',(x,-.037,dz),.0025,.0015,'podSeal',ob)
    parent=empty('interior_seat',(0,0,0),parent)
    block('Seat pedestal',(0,.31,.42),(.36,.35,.23),'alu',parent,.008)
    for x in [-.205,.205]:
        tube('Seat chassis',(x,.04,.37),(x,.55,.37),.015,'alu',parent)
        tube('Seat back frame',(x,.50,.39),(x,.55,1.35),.013,'alu',parent)
    block('Seat cushion',(0,.28,.585),(.44,.46,.13),'podPad',parent,.045)
    for side in [-1,1]:
        block('Seat side bolster',(side*.21,.27,.625),(.075,.44,.12),'podPad',parent,.035)
        block('Padded armrest',(side*.335,.19,.76),(.11,.42,.075),'podPad',parent,.025)
    back=block('Seat back',(0,.52,.97),(.44,.13,.65),'podPad',parent,.050)
    back.rotation_euler.x=-.10
    block('Headrest',(0,.555,1.34),(.30,.13,.18),'podPad',parent,.035)
    for x in [-.135,.135]:
        strap=block('Woven harness',(x,.439,.97),(.032,.013,.57),'podWebbing',parent,.003)
        strap.rotation_euler.x=-.10
        block('Harness fitting',(x,.445,.77),(.045,.012,.043),'alu',parent,.004)
        block('Harness buckle',(x,.436,.77),(.022,.008,.018),'podSeal',parent,.002)
    for x in [-.20,.20]:
        tube('Footrest support',(x,-.29,.30),(x,-.46,.36),.012,'alu',parent)
        block('Footrest',(x,-.42,.355),(.16,.20,.025),'podFloor',parent,.008)
        for i in range(7):block('Footrest grip',(x,-.50+i*.025,.371),(.14,.007,.005),'podSeal',parent,.001)


def hand_controls(parent):
    apron=mount('Controller support apron',(0,-.20,.50),parent,(0,-1,.50))
    slab('Brick red controller apron',[(-.35,-.13),(.35,-.13),(.35,.13),(-.35,.13)],-.018,.025,'podRed',apron,.009)
    for side in [-1,1]:
        block('Controller attachment plinth',(side*.315,-.11,.58),(.10,.15,.19),'podRed',parent,.010)
    for side in [-1,1]:
        ob=mount('Waldo control mount',(side*.315,-.18,.735),parent,(side*.315,-.6,.80))
        disk('Controller body',(0,0,0),.046,.145,'alu',ob)
        for y in [-.065,.055]:disk('Controller end ring',(0,y,0),.049,.012,'podSeal',ob)
        disk('Controller face',(0,-.078,0),.040,.010,'steel',ob)
        for x in [-.025,.025]:
            tube('Waldo finger frame',(x,-.081,-.012),(x,-.138,.034),.004,'steel',ob,10)
        tube('Waldo hand grip',(-.025,-.138,.034),(.025,-.138,.034),.008,'podSeal',ob)
        block('Controller trigger',(0,-.095,.008),(.013,.021,.013),'podWarning',ob,.003)
        tube('Controller support',(0,.015,-.02),(0,.04,-.14),.014,'alu',ob)
        for y in [.01,.035,.060]:disk('Controller collar',(0,y,0),.047,.004,'steel',ob)
        # Cable strain relief terminates in a supported loom below the console.
        tube('Controller cable',(0,.072,0),(0,.15,-.10),.007,'podSeal',ob)
        tube('Controller cable',(0,.15,-.10),(0,.12,-.19),.007,'podSeal',ob)
    equipment=mount('Apron relay equipment',(-.17,-.233,.50),parent,(0,-1,.50))
    block('Relay mounting plate',(0,0,0),(.16,.016,.11),'podRed',equipment,.003)
    for i in range(4):
        block('Relay can',((i-1.5)*.034,-.022,.007),(.024,.036,.062),'podRed',equipment,.003)
        tube('Relay fastener',((i-1.5)*.034,-.041,-.040),((i-1.5)*.034,-.041,.045),.0015,'podRed',equipment)
    for x in [-.052,.052]:disk('Relay service connector',(x,-.026,-.041),.010,.026,'podWarning',equipment)


def fixtures(parent):
    positions=[(-.56,.15,1.59),(.56,.15,1.59),(-.45,.53,.93),(.45,.53,.93),(0,-.34,1.83)]
    for i,pos in enumerate(positions):
        ob=mount('Recessed cabin luminaire',pos,parent)
        block('Lamp recess',(0,0,0),(.155,.033,.064),'podSeal',ob,.009)
        block('Frosted opal diffuser edge',(0,-.018,0),(.135,.010,.047),'podKeyIvory',ob,.005)
        block('Red-lit acrylic diffuser',(0,-.024,0),(.126,.010,.040),'podCabinLamp',ob,.005)
        for x in [-.070,.070]:screw(ob,x,0,-.018)
        normal=ob.rotation_quaternion@Vector((0,-1,0))
        p=Vector(pos)*S+normal*.045*S
        empty('interior_light_'+str(i),tuple(p),parent)


def ceiling_and_door(parent):
    roof=panel('Overhead switchboard',(0,.12,1.815),.47,.28,parent,'EMERGENCY / SYSTEM CONTROL')
    grid(roof,[[('POWER','podAmber'),'BUS A','BUS B','AUX','TEST','OFF'],
               ['VALVE','PURGE','VENT','LOCK','OPEN',('SAFE','podWarm')]],z=.013,pitch=.065,gap=.055)
    rule(roof,0,.013,.414,.118)
    text(roof,'MANUAL OVERRIDE',(0,-.028,-.092),.008)
    for x in [-.12,.12]:toggle(roof,x,-.095,'ARM',False)
    block('Switchboard roof support',(0,.12,1.90),(.32,.21,.16),'podRed',parent,.018)
    door=mount('interior_hatch',(0,.755,1.12),parent,(0,-1,1.12))
    pts=[(-.27,-.48),(.27,-.48),(.29,-.34),(.24,.42),(.16,.49),(-.16,.49),(-.24,.42),(-.29,-.34)]
    slab('Hatch gasket',pts,-.015,.018,'podSeal',door,.012)
    slab('Pressure hatch',[(x*.95,z*.95) for x,z in pts],-.025,-.013,'podRed',door,.010)
    block('Hatch warning plate',(0,-.029,.353),(.27,.005,.090),'podWarning',door,.002)
    text(door,'CAUTION',(0,-.032,.371),.017)
    text(door,'PRESSURE HATCH',(0,-.032,.340),.010)
    block('Hatch equipment panel',(0,-.031,-.004),(.243,.012,.390),'podPanel',door,.006)
    block('Recessed hatch instruction plate',(0,-.039,.116),(.195,.004,.047),'podWarm',door,.001)
    text(door,'CHECK SEAL BEFORE RELEASE',(0,-.042,.116),.005,'podInk')
    for i in range(3):
        disk('Hatch lock collar',((i-1)*.064,-.042,.030),.016,.012,'alu',door)
        disk('Hatch lock centre',((i-1)*.064,-.050,.030),.009,.006,'podSeal',door)
    block('Hatch latch mechanism',(0,-.045,-.093),(.135,.027,.109),'podRed',door,.006)
    disk('Hatch latch spindle',(0,-.067,-.093),.027,.024,'alu',door)
    block('Hatch latch lever',(.025,-.083,-.110),(.073,.014,.018),'podSeal',door,.006)
    for side in [-1,1]:
        x=side*.16
        block('Handhold recessed escutcheon',(x,-.029,.026),(.067,.011,.249),'podPanel',door,.015)
        tube('Hatch handhold',(x,-.035,-.07),(x,-.09,-.07),.009,'podSeal',door)
        tube('Hatch handhold',(x,-.09,-.07),(x,-.09,.12),.009,'podSeal',door)
        tube('Hatch handhold',(x,-.09,.12),(x,-.035,.12),.009,'podSeal',door)
        disk('Hatch lock',(side*.21,-.03,.21),.021,.012,'alu',door)
    box_=panel('Guarded release control',(.34,.55,1.54),.16,.15,parent,'HATCH RELEASE')
    block('Release controller casting',(0,-.036,-.008),(.117,.025,.070),'podOlive',box_,.007)
    for x in [-.035,.035]:
        disk('Release connector rim',(x,-.055,-.008),.017,.020,'alu',box_)
        disk('Release connector socket',(x,-.067,-.008),.011,.008,'podSeal',box_)
    text(box_,'ARM       FIRE',(0,-.029,-.057),.006)
    for x in [-.067,.067]:tube('Release guard rail',(x,-.035,-.041),(x,-.035,.040),.003,'alu',box_)
    for y in [.37,.50,.63]:
        block('Ceiling service junction',(-.31,y,1.66),(.11,.08,.065),'podRed',parent,.008)
    for x in [-.36,-.27]:tube('Overhead conduit',(x,.30,1.67),(x,.65,1.67),.008,'podRed',parent)
    for x in [-.17,.17]:
        tube('Overdoor grab rail support',(x,.62,1.62),(x,.57,1.62),.008,'podSeal',parent)
    tube('Overdoor grab rail',(-.17,.57,1.62),(.17,.57,1.62),.009,'podSeal',parent)


def storage(parent):
    for side in [-1,1]:
        ob=empty('interior_storage_'+str(0 if side<0 else 1),(side*.48*S,.22*S,.60*S),parent)
        # The rear edge is angled in the publicity photo; a closed box supports its lid.
        outline=[(-.13,-.20),(.13,-.20),(.13,.12),(.065,.20),(-.13,.15)]
        if side<0:outline=[(-x,y) for x,y in reversed(outline)]
        outline=[(x,-y) for x,y in outline]
        shell=slab('Storage box',outline,-.055,.055,'podRed',ob,.007)
        shell.rotation_euler.x=pi/2
        gasket=slab('Storage lid gasket',outline,-.001,.002,'podSeal',ob,.001)
        gasket.rotation_euler.x=pi/2;gasket.location.z=.056*S
        lid=slab('Trapezoidal storage lid',outline,-.004,.014,'podPanel',ob,.005)
        lid.rotation_euler.x=pi/2;lid.location.z=.062*S
        block('Storage recessed latch',(0,-.168,.078),(.063,.035,.008),'podSeal',ob,.005)
        block('Storage latch pull',(0,-.168,.084),(.037,.013,.007),'alu',ob,.002)
        for x in [-.068,.068]:
            disk('Storage lid hinge',(x,.145,.066),.009,.050,'steel',ob,(1,0,0))


def shell_services(parent):
    for side in [-1,1]:
        hose=[]
        for y,z in [(.34,1.73),(.60,1.48)]:
            p=Vector((side*.37,y,z-1.03)).normalized()*.975+Vector((0,0,1.03))
            ob=mount('Hull service fitting',tuple(p),parent,(0,0,1.03))
            block('Service block foot',(0,0,0),(.115,.024,.075),'podRed',ob,.006)
            block('Service valve casting',(0,-.024,0),(.085,.042,.052),'podRed',ob,.006)
            for dx in [-.047,.047]:disk('Service hose coupling',(dx,-.027,0),.014,.026,'podRed',ob,(1,0,0))
            for dx in [-.045,.045]:screw(ob,dx,.025,-.015)
            hose.append(p+ob.rotation_quaternion@Vector((side*.047,-.027,0)))
        middle=(hose[0]+hose[1])*.5+Vector((-side*.015,-.012,-.012))
        tube('Hull service hose',tuple(hose[0]),tuple(middle),.009,'podRed',parent)
        tube('Hull service hose',tuple(middle),tuple(hose[1]),.009,'podRed',parent)


def window_surround(parent):
    # The shooting set used painted fibreglass inside the reveal, rather than the exterior ribs.
    n=128; verts=[]
    for rx,rz,mode in [(.438,.508,0),(.350,.411,1),(.319,.374,2)]:
        for i in range(n):
            a=i*2*pi/n; x=rx*cos(a); z=1.42+rz*sin(a)
            y=-sqrt(max(.01,1.030**2-x*x-(z-1.03)**2))+.004 if mode==0 else (-.390 if mode==1 else -.368)
            verts.append((x*S,y*S,z*S))
    faces=[(j*n+i,j*n+(i+1)%n,(j+1)*n+(i+1)%n,(j+1)*n+i) for j in range(2) for i in range(n)]
    ob=_obj('Moulded interior window reveal',verts,faces,M['podRed'],parent);smooth(ob,60)
    def edge(t):
        x=.438*cos(t);z=1.42+.508*sin(t)
        return (x,-sqrt(max(.01,1.03**2-x*x-(z-1.03)**2))+.004,z)
    for i in range(n):
        a=i*2*pi/n;b=(i+1)*2*pi/n
        tube('Interior glazing seal',(.319*cos(a),-.366,1.42+.374*sin(a)),
             (.319*cos(b),-.366,1.42+.374*sin(b)),.005,'podSeal',parent,8)
        tube('Outer reveal trim',edge(a),edge(b),.005,'podSeal',parent,8)


def build(parent, mats, scale, eye):
    global M,S,EYE
    M=mats;S=scale
    EYE=Vector((eye[0],-eye[2],eye[1]))/S
    window_surround(bpy.data.objects['window_liner'])
    upholstery(parent)
    consoles(parent)
    displays(parent)
    side_banks(parent)
    round_controls(parent,-1);round_controls(parent,1)
    hand_controls(parent)
    ceiling_and_door(parent)
    shell_services(parent)
    fixtures(parent)
    block('Anti-slip floor',(0,.03,.276),(.88,.92,.038),'podFloor',parent,.008)
    storage(parent)
