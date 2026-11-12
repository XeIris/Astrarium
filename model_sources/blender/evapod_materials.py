"""Self-contained pod finishes with tileable colour, roughness and normal maps.
Maps are embedded in the GLB; no external texture download or shader is required.
"""
import bpy
import bmesh
import numpy as np
from mathutils import Vector
from common import build_materials, srgb
from lib import material

DENSITY = {
    'podWhite': 8.0, 'podRed': 7.0, 'podPanel': 5.0, 'podPad': 14.0,
    'podSeal': 18.0, 'podWebbing': 25.0, 'podAluminium': 5.0,
    'podSteel': 6.0, 'podNozzle': 5.0, 'podFloor': 12.0,
    'podKeyRim': 6.0, 'podOlive': 7.0,
}


def image(name, data, color_space='Non-Color'):
    size = data.shape[0]
    im = bpy.data.images.new(name, size, size, alpha=True)
    im.colorspace_settings.name = color_space
    im.pixels.foreach_set(data.astype(np.float32).ravel())
    im.update()
    im.pack()
    return im


def maps(name, kind, rough, color):
    n = 256
    y, x = np.mgrid[0:n, 0:n] * (2*np.pi/n)
    rng = np.random.default_rng(2001)
    fx = np.fft.fftfreq(n)[None,:]
    fy = np.fft.fftfreq(n)[:,None]
    def noise(sx,sy):
        spectrum = np.fft.fft2(rng.standard_normal((n,n)))
        field = np.fft.ifft2(spectrum*np.exp(-2*np.pi**2*(sx*sx*fx*fx+sy*sy*fy*fy))).real
        return field/max(float(field.std()),1e-8)
    grain = noise(1.8,1.8)
    fine = noise(.55,.55)
    if kind == 'quilt':
        qx=(4*x)%(2*np.pi); qy=(4*y)%(2*np.pi)
        edge = np.minimum(np.minimum(qx,2*np.pi-qx), np.minimum(qy,2*np.pi-qy))
        height = -.14*np.exp(-(edge/.09)**2)+.006*(np.cos(48*x)+np.cos(48*y))+.004*grain
        variation = .04*np.exp(-(edge/.16)**2)+.015*grain
        strength = .30
    elif kind == 'vinyl':
        height = -.055*np.abs(grain)+.009*fine
        variation = .018*grain+.006*fine
        strength = .28
    elif kind == 'weave':
        height = .035*(np.cos(32*x)+np.cos(32*y))+.015*np.sin(16*x)*np.sin(16*y)
        variation = .035*np.sin(32*x)*np.sin(32*y)
        strength = .45
    elif kind == 'brush':
        height = .010*noise(24,.65)+.003*grain
        variation = .018*noise(30,.7)+.006*grain
        strength = .25
    elif kind == 'rubber':
        height = .014*grain+.004*fine
        variation = .018*grain
        strength = .30
    else:
        height = .008*grain+.002*fine
        variation = .013*grain+.004*fine
        strength = .25
    dx = (np.roll(height,-1,1)-np.roll(height,1,1))*strength
    dy = (np.roll(height,-1,0)-np.roll(height,1,0))*strength
    normals = np.stack((-dx,-dy,np.ones_like(dx)),axis=2)
    normals /= np.linalg.norm(normals,axis=2,keepdims=True)
    rgba = np.ones((n,n,4)); rgba[:,:,:3]=normals*.5+.5
    normal = image(name+' micro normal',rgba)
    rgba[:,:,:3]=np.clip(rough+variation,.05,.98)[:,:,None]
    roughness = image(name+' roughness',rgba)
    pigment = np.array([(color >> shift & 255)/255 for shift in (16, 8, 0)])
    wear = .020*noise(18,11) - .70*variation + .018*height
    rgba[:,:,:3] = np.clip((1.0+wear[:,:,None])*pigment,0,1)
    return normal, roughness, image(name+' colour',rgba,'sRGB')


def finish(name, color, rough, metal, kind, coat=0.0):
    mat = material(name, srgb(color), rough, metal)
    bsdf = mat.node_tree.nodes['Principled BSDF']
    bsdf.inputs['Coat Weight'].default_value = coat
    bsdf.inputs['Coat Roughness'].default_value = .25
    normal, roughness, albedo = maps(name,kind,rough,color)
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = albedo
    mat.node_tree.links.new(tex.outputs['Color'],bsdf.inputs['Base Color'])
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = roughness
    mat.node_tree.links.new(tex.outputs['Color'],bsdf.inputs['Roughness'])
    tex = mat.node_tree.nodes.new('ShaderNodeTexImage'); tex.image = normal
    node = mat.node_tree.nodes.new('ShaderNodeNormalMap')
    mat.node_tree.links.new(tex.outputs['Color'],node.inputs['Color'])
    mat.node_tree.links.new(node.outputs['Normal'],bsdf.inputs['Normal'])
    return mat


def palette():
    mats = dict(build_materials())
    rows = [
        ('podWhite',0xdfddd6,.39,.025,'paint',.20),
        ('podRed',0x502b2b,.49,.025,'paint',.08),
        ('podPanel',0x111517,.52,.04,'brush',0),
        ('podPad',0x171619,.54,.015,'vinyl',0),
        ('podSeal',0x111314,.82,.01,'rubber',0),
        ('podWebbing',0x282a2b,.87,.01,'weave',0),
        ('podAluminium',0xb5bec3,.29,.32,'brush',0),
        ('podSteel',0xc7ccd0,.23,.34,'brush',0),
        ('podNozzle',0x665f58,.51,.27,'brush',0),
        ('podFloor',0x303338,.79,.02,'rubber',0),
        ('podKeyRim',0x555e63,.34,.30,'brush',0),
        ('podOlive',0x4c5740,.48,.12,'paint',.06),
    ]
    for name,col,rough,metal,kind,coat in rows:
        mats[name] = finish(name,col,rough,metal,kind,coat)
    mats['alu']=mats['podAluminium']; mats['steel']=mats['podSteel']; mats['nozzle']=mats['podNozzle']
    for name,col,power in [('podBlue',0x229be7,2.2),('podWarm',0xf4e1ba,1.35),
                           ('podAmber',0xe98736,1.0),('podLamp',0xe2e9ed,3.0),
                           ('podCabinLamp',0xff4733,1.5),('podScreenInk',0xa6d8d9,1.2),
                           ('podGreen',0x54b886,.9)]:
        mats[name] = material(name,srgb(col),.40,.015,srgb(col),power)
    for name,col in [('podLegend',0xd7dcd8),('podInk',0x0b1216),('podKeyOff',0x254255),
                      ('podScreen',0x070e13),('podWarning',0xbf4434),('podSeam',0x454145)]:
        mats[name] = material(name,srgb(col),.32 if name=='podScreen' else .51,.03)
    # Separate pigmented sidewalls from the illuminated face: a cap has depth even when lit.
    for name,col in [('podKeyBlue',0x18445e),('podKeyIvory',0xc3b697),('podKeyAmber',0x925325)]:
        mats[name]=material(name,srgb(col),.24,.015)
    return mats


def assign_uvs(bake_modifiers=False):
    """Metre-scaled box projection survives material joins and arm articulation."""
    if bake_modifiers:
        # Clamp-overlap bevels can leave collapsed strips on thin plates and cushions.
        bpy.ops.object.select_all(action='DESELECT')
        meshes=[o for o in bpy.context.scene.objects if o.type=='MESH']
        for ob in meshes:ob.select_set(True)
        if meshes:
            bpy.context.view_layer.objects.active=meshes[0]
            bpy.ops.object.convert(target='MESH')
        bpy.ops.object.select_all(action='DESELECT')
    bpy.context.view_layer.update()
    for ob in bpy.context.scene.objects:
        if ob.type != 'MESH' or not ob.data.materials:
            continue
        density = DENSITY.get(ob.data.materials[0].name.split('.')[0])
        if density is None:
            continue
        if bake_modifiers:
            bm=bmesh.new();bm.from_mesh(ob.data)
            bmesh.ops.remove_doubles(bm,verts=list(bm.verts),dist=1e-7)
            bmesh.ops.dissolve_degenerate(bm,edges=list(bm.edges),dist=1e-7)
            bad=[f for f in bm.faces if f.calc_area()<1e-14]
            if bad:bmesh.ops.delete(bm,geom=bad,context='FACES_ONLY')
            bmesh.ops.triangulate(bm,faces=list(bm.faces))
            bm.normal_update();bm.to_mesh(ob.data);bm.free()
        uv = ob.data.uv_layers.active or ob.data.uv_layers.new(name='UVMap')
        uv.name = 'UVMap'
        uv.active_render = True
        normal_matrix = ob.matrix_world.to_3x3().inverted().transposed()
        for face in ob.data.polygons:
            normal = normal_matrix @ face.normal
            axis = max(range(3), key=lambda k: abs(normal[k]))
            for loop_index in face.loop_indices:
                p = ob.matrix_world @ ob.data.vertices[ob.data.loops[loop_index].vertex_index].co
                if axis == 0: u,v = p.y*(1 if normal.x>=0 else -1),p.z
                elif axis == 1: u,v = p.x*(1 if normal.y<=0 else -1),p.z
                else: u,v = p.x*(1 if normal.z>=0 else -1),p.y
                uv.data[loop_index].uv = (u*density,v*density)
