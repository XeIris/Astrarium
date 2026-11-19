"""Original static flight-instrument artwork. Each cabin shares one emissive atlas."""
from math import cos, sin, pi

import numpy as np

from evapod_materials import image
from lib import _obj, material

# Five-column engraved terminal alphabet, MSB at the left of each row.
GLYPHS = dict(zip("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-./: ",
    ("0e11111f111111 1e11111e11111e 0f10101010100f 1e11111111111e "
     "1f10101e10101f 1f10101e101010 0f10101311110f 1111111f111111 "
     "0e04040404040e 0702020212120c 11121418141211 1010101010101f "
     "111b1515111111 11191513111111 0e11111111110e 1e11111e101010 "
     "0e11111115120d 1e11111e141211 0f10100e01011e 1f040404040404 "
     "1111111111110e 11111111110a04 11111115151b11 11110a040a1111 "
     "11110a04040404 1f01020408101f 0e11131519110e 040c040404040e "
     "0e11010204081f 1e01010e01011e 02060a121f0202 1f10101e01011e "
     "0e10101e11110e 1f010204080808 0e11110e11110e 0e11110f01010e "
     "0000001f000000 00000000000c0c 01020204080810 000c0c000c0c00 "
     "00000000000000").split()))

PAGES = ('ATTITUDE', 'PROPULSION', 'FLIGHT SYSTEMS', 'DISTRIBUTION',
         'CABIN', 'THERMAL', 'COMMS', 'RENDEZVOUS')


def instrument_atlas(name, phosphor):
    atlas = np.zeros((1024, 1024, 4), dtype=float)
    atlas[:, :, 3] = 1
    for index, title in enumerate(PAGES):
        canvas = np.zeros((256, 512, 3))
        bright, mid, dim, alert = np.array(phosphor)
        canvas[:] = dim * .16

        def rect(x, y, w, h, color):
            canvas[y:y+h, x:x+w] = color

        def line(x1, y1, x2, y2, color, weight=1):
            count = int(max(abs(x2-x1), abs(y2-y1))) + 1
            x = np.linspace(x1, x2, count).round().astype(int)
            y = np.linspace(y1, y2, count).round().astype(int)
            for k in range(weight):
                canvas[y+k, x] = color

        def lettering(value, x, y, color, scale=2):
            for char in value:
                for row, bits in enumerate(bytes.fromhex(GLYPHS[char])):
                    for col in range(5):
                        if bits & (16 >> col):
                            rect(x+col*scale, y+row*scale, scale, scale, color)
                x += 6*scale

        def arc(cx, cy, rx, ry, start, stop, color):
            angles = np.linspace(start, stop, 129)
            points = zip(cx+rx*np.cos(angles), cy+ry*np.sin(angles))
            prev = next(points)
            for pt in points:
                line(*prev, *pt, color)
                prev = pt

        lettering(title, 16, 12, bright, 3)
        lettering('CH 0'+str(index+1), 396, 16, mid)
        rect(14, 41, 482, 2, mid)
        rect(296, 52, 2, 157, dim)
        if index in (0, 7):
            for x in range(28, 280, 16):
                rect(x, 65, 1, 133, dim*.4)
            for y in range(65, 199, 16):
                rect(28, y, 247, 1, dim*.4)
            if index == 0:
                arc(154, 134, 83, 76, pi, 2*pi, mid)
                for tick in range(-6, 7):
                    a = tick*pi/18
                    line(154+76*sin(a), 134-68*cos(a), 154+84*sin(a), 134-76*cos(a), bright, 2)
                for tick in range(-3, 4):
                    w = 65 if tick == 0 else 38-4*abs(tick)
                    y = 135+tick*15
                    line(154-w,y-5,146,y,bright,2)
                    line(162,y+1,154+w,y+5,bright,2)
                for side in [-1, 1]:
                    line(154+side*8,139,154+side*18,131,alert,2)
                    line(154+side*18,131,154+side*35,131,alert,2)
            else:
                arc(144, 131, 94, 46, 0, 2*pi, mid)
                arc(157, 129, 48, 61, 0, 2*pi, bright)
                line(40,174,243,89,dim)
                rect(187,83,6,6,alert)
            channels = ('ROLL', 'PITCH', 'YAW') if index == 0 else ('RANGE','RATE','TIME')
        elif index in (1, 3, 4):
            channels = {1: ('FEED A','FEED B','RCS'), 3: ('BUS A','BUS B','LOAD'),
                        4: ('O2','CO2','PRESS')}[index]
            for j, label in enumerate(channels):
                x=35+j*84
                lettering(label, x-4, 57, mid, 1)
                for k in range(16):
                    rect(x, 174-6*k, 7, 2, mid)
                    rect(x+12, 174-6*k, 28, 4, bright if k<(12-j+index%2) else dim)
                lettering(str(89-7*j-index), x+4, 188, bright)
        else:
            channels = {2: ('GUID','LINK','CLOCK'), 5: ('INLET','OUTLET','FLOW'),
                        6: ('UHF','S BAND','GAIN')}[index]
            for j in range(3):
                y = 79+j*51
                for tick in range(16):
                    rect(25+16*tick,y-14,1,30,dim)
                rect(24,y,244,1,dim)
                pts = [(25+k*3, y+6*sin(k*.14+j)+5*sin(k*.41+index)) for k in range(81)]
                for a,b in zip(pts,pts[1:]):
                    line(*a,*b,bright,2)
        for j, channel in enumerate(channels):
            y = 58+j*55
            lettering(channel, 312, y, mid)
            lettering(f'{(index+2)*(j+3):03d}.{7-j}', 345, y+18, bright, 3)
            rect(313,y+43,177,1,dim)
        rect(14, 216, 482, 2, mid)
        lettering('AUTO', 20, 227, bright)
        lettering('STATUS / NOMINAL', 137, 229, mid, 1)
        lettering('SYS 0'+str(index+1),398,227,bright)
        # Scan lines and face falloff belong to the phosphor, independent of cabin lighting.
        yy, xx = np.mgrid[-1:1:256j, -1:1:512j]
        canvas *= (1-.18*(xx**2+yy**2))[:, :, None]
        canvas[::2] *= .84
        x, y = (index % 2)*512, (index//2)*256
        atlas[y:y+256, x:x+512, :3] = canvas[::-1]

    bitmap = image(name+' phosphor', atlas, 'sRGB')
    mat = material(name, (.012,.016,.018), .21, .07, emit=(1,1,1), emit_strength=1.65)
    nodes = mat.node_tree.nodes
    tex = nodes.new('ShaderNodeTexImage')
    tex.image = bitmap
    mat.node_tree.links.new(tex.outputs['Color'], nodes['Principled BSDF'].inputs['Emission Color'])
    return mat


def glass(name, page, width, height, sag, project, mat, parent):
    """Crowned glass face with a chamfered perimeter. Project maps face XYZ to Blender."""
    verts, coords, faces = [], [], []
    outline = [(-.94,-1),(.94,-1),(1,-.91),(1,.91),(.94,1),(-.94,1),(-1,.91),(-1,-.91)]
    for r in (1, .90, .67, .36):
        for u,v in outline:
            verts.append(project(u*width*.5*r, v*height*.5*r, sag*(1-r*r)))
            coords.append(((page%2+.5+u*r*.49)/2, (page//2+.5+v*r*.48)/4))
        start = len(verts)-8
        if start:
            for i in range(8):
                j=(i+1)%8
                faces.append((start-8+i,start-8+j,start+j,start+i))
    faces.append(tuple(range(24,32)))
    ob = _obj(name, verts, faces, mat, parent)
    uv = ob.data.uv_layers.new(name='UVMap')
    for face in ob.data.polygons:
        face.use_smooth = True
        for loop in face.loop_indices:
            uv.data[loop].uv = coords[ob.data.loops[loop].vertex_index]
    return ob
