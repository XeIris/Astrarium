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


def key(parent, x, z, label, color='podBlue'):
    block('Switch bezel',(x,-.030,z),(.029,.008,.023),'podSeal',parent,.002)
    block('Perspex pushbutton',(x,-.037,z),(.024,.012,.018),color,parent,.0018)
    text(parent,label,(x,-.0435,z),.0039,'podInk')


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
    for angle in [pi/4,3*pi/4,5*pi/4,7*pi/4]:screw(ob,.119*cos(angle),.119*sin(angle),-.026)


def displays(parent):
    rack=panel('Dished forward display rack',(0,-.62,.83),.72,.25,parent,'FLIGHT / SYSTEM MONITOR')
    for side in [-1,1]:
        ob=empty('Inward canted display',(side*.174*S,-.026*S,-.013*S),rack)
        ob.rotation_euler.z=side*.11
        block('Display gasket',(0,0,0),(.309,.026,.181),'podSeal',ob,.012)
        block('Flat display face',(0,-.016,0),(.282,.010,.153),'podScreen',ob,.005)
        rule(ob,0,0,.271,.145,'podKeyOff',-.022)
        text(ob,'ATTITUDE' if side<0 else 'VEHICLE SYSTEMS',(0,-.024,.059),.008,'podScreenInk')
        if side<0:
            for x in [-.07,0,.07]:
                tube('Display grid',(x,-.024,-.047),(x,-.024,.041),.0006,'podKeyOff',ob,5)
            for z in [-.033,0,.033]:
                tube('Display grid',(-.126,-.024,z),(.126,-.024,z),.0006,'podKeyOff',ob,5)
            for a,b in [((-.06,-.024,-.027),(0,-.024,.023)),((0,-.024,.023),(.06,-.024,-.027)),
                        ((-.06,-.024,-.027),(.06,-.024,-.027)),((0,-.024,-.04),(0,-.024,.039))]:
                tube('Attitude schematic',a,b,.0011,'podScreenInk',ob,6)
            text(ob,'ROLL       PITCH       YAW',(0,-.025,-.061),.006,'podScreenInk')
        else:
            for i,label in enumerate(['RCS','CABIN','BUS','FUEL']):
                z=.030-i*.023
                text(ob,label,(-.086,-.024,z),.007,'podScreenInk')
                rule(ob,.040,z,.139,.011,'podKeyOff',-.024)
                block('System status trace',(.018-i*.005,-.025,z),(.094-i*.010,.001,.003),'podScreenInk',ob,.0001)
        for x in [-.158,.158]:screw(ob,x,.072,-.018)
    return rack


def consoles(parent):
    for side in [-1,1]:
        shape=[(-.21,-.17),(.21,-.17),(.18,.17),(-.16,.17)]
        ob=panel('Polygonal manipulator console',(side*.425,-.33,.78),.42,.34,parent,
                 'PORT MANIPULATOR' if side>0 else 'STBD MANIPULATOR',shape)
        rows=[[('POWER','podWarm'),'LOCK','EXT','RET','HOLD','TEST'],
              ['YAW L','YAW R','UP','DOWN','IN','OUT'],
              ['WRIST','ROT L','ROT R','OPEN','CLOSE',('SAFE','podAmber')]]
        grid(ob,rows,z=.008,pitch=.054,gap=.041)
        rule(ob,0,.008,.354,.132)
        text(ob,'ATTITUDE / TRANSLATION',(0,-.028,-.091),.007)
        grid(ob,[[('OFF','podKeyOff'),'PRO','RET','NML','RAD',('ARM','podWarm')]],z=-.123,pitch=.054)
        # The lower switch rows mount through the face; cap backs overlap the bezels.
        for x in [-.165,.165]:screw(ob,x,-.080)
        for i in range(2):toggle(ob,-.12+i*.055,.124,'AUX',i==0)


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


def upholstery(parent):
    for a in [pi*.46,pi*.65,pi*.82,pi,pi*1.18,pi*1.35,pi*1.54]:
        for z in [.78,1.12,1.46]:
            radius=sqrt(max(.08,.945**2-(abs(z-1.03)+.16)**2))
            ob=mount('Leatherette cushion mount',(radius*sin(a),-radius*cos(a),z),parent,(0,0,z))
            block('Upholstery backing',(0,0,0),(.325,.028,.302),'podSeal',ob,.012)
            block('Foam padded leatherette',(0,-.023,0),(.311,.048,.288),'podPad',ob,.028)
            rule(ob,0,0,.270,.247,'podSeam',-.048)
            for x in [-.145,.145]:
                for dz in [-.126,.126]:disk('Upholstery fixing',(x,-.037,dz),.0025,.0015,'podSeal',ob)
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
        block('Woven harness',(x,.437,.97),(.032,.013,.57),'podWebbing',parent,.003)
        block('Harness fitting',(x,.423,.77),(.045,.012,.043),'alu',parent,.004)
        block('Harness buckle',(x,.414,.77),(.022,.008,.018),'podSeal',parent,.002)
    for x in [-.20,.20]:
        tube('Footrest support',(x,-.29,.30),(x,-.46,.36),.012,'alu',parent)
        block('Footrest',(x,-.42,.355),(.16,.20,.025),'podFloor',parent,.008)
        for i in range(7):block('Footrest grip',(x,-.50+i*.025,.371),(.14,.007,.005),'podSeal',parent,.001)


def hand_controls(parent):
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


def fixtures(parent):
    positions=[(-.56,.15,1.59),(.56,.15,1.59),(-.45,.53,.93),(.45,.53,.93),(0,-.34,1.83)]
    for i,pos in enumerate(positions):
        ob=mount('Recessed cabin luminaire',pos,parent)
        block('Lamp recess',(0,0,0),(.155,.033,.064),'podSeal',ob,.009)
        block('Opal red practical',(0,-.020,0),(.128,.014,.042),'podCabinLamp',ob,.005)
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
    door=mount('Rear pressure hatch',(0,.755,1.12),parent,(0,-1,1.12))
    pts=[(-.27,-.48),(.27,-.48),(.29,-.34),(.24,.42),(.16,.49),(-.16,.49),(-.24,.42),(-.29,-.34)]
    slab('Hatch gasket',pts,-.015,.018,'podSeal',door,.012)
    slab('Pressure hatch',[(x*.95,z*.95) for x,z in pts],-.025,-.013,'podRed',door,.010)
    text(door,'CAUTION',(0,-.030,.37),.020,'podWarning')
    text(door,'PRESSURE HATCH',(0,-.030,.325),.011)
    for side in [-1,1]:
        x=side*.16
        tube('Hatch handhold',(x,-.035,-.07),(x,-.09,-.07),.009,'podSeal',door)
        tube('Hatch handhold',(x,-.09,-.07),(x,-.09,.12),.009,'podSeal',door)
        tube('Hatch handhold',(x,-.09,.12),(x,-.035,.12),.009,'podSeal',door)
        disk('Hatch lock',(side*.21,-.03,.21),.021,.012,'alu',door)
    box_=panel('Guarded release control',(.34,.55,1.54),.16,.15,parent,'HATCH RELEASE')
    for x in [-.035,.035]:disk('Release selector',(x,-.037,-.008),.015,.019,'alu',box_)
    text(box_,'ARM       FIRE',(0,-.029,-.047),.006)
    for y in [.37,.50,.63]:
        block('Ceiling service junction',(-.31,y,1.66),(.11,.08,.065),'podRed',parent,.008)
    for x in [-.36,-.27]:tube('Overhead conduit',(x,.30,1.67),(x,.65,1.67),.008,'podRed',parent)


def build(parent, mats, scale, eye):
    global M,S,EYE
    M=mats;S=scale
    EYE=Vector((eye[0],-eye[2],eye[1]))/S
    upholstery(parent)
    consoles(parent)
    displays(parent)
    side_banks(parent)
    round_controls(parent,-1);round_controls(parent,1)
    hand_controls(parent)
    ceiling_and_door(parent)
    fixtures(parent)
    block('Anti-slip floor',(0,.03,.276),(.88,.92,.038),'podFloor',parent,.008)
    for side in [-1,1]:
        ob=block('Angled storage lid',(side*.44,.25,.66),(.18,.34,.025),'podPanel',parent,.008)
        block('Storage latch',(side*.44,.08,.66),(.045,.018,.016),'alu',parent,.002)
