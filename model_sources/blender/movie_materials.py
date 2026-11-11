"""Original surface finishes shared by the cinematic spacecraft builds."""
import numpy as np
from evapod_materials import finish, assign_uvs, DENSITY, image
from common import build_materials, srgb
from lib import material


def palette(cabin=False):
    mats = dict(build_materials())
    for key, name, color, rough, metal, kind, density in [
        ('thermal', 'surveyThermal', 0xcac9bc, .83, .02, 'quilt', .5),
        ('enamel', 'surveyEnamel', 0xdbded8, .46, .035, 'paint', 4),
        ('tps', 'surveyCarbon', 0x262b2e, .89, .025, 'rubber', 6),
        ('panel', 'surveyPanel', 0x333c40, .50, .12, 'brush', 5),
        ('liner', 'surveyLiner', 0x78817d, .77, .02, 'vinyl', 8),
        ('seat', 'surveySeat', 0x30383b, .72, .015, 'vinyl', 10),
        ('webbing', 'surveyWebbing', 0x92918a, .86, .01, 'weave', 20),
        ('alloy', 'surveyAlloy', 0xa6afb1, .34, .32, 'brush', 5),
        ('rubber', 'surveyRubber', 0x101719, .86, .01, 'rubber', 12),
    ]:
        mats[key] = finish(name, color, rough, metal, kind)
        DENSITY[name] = density
    if cabin:
        name='surveyCabinQuilt'
        mats['cabin_quilt']=finish(name,0x7d8682,.80,.02,'quilt')
        DENSITY[name]=5.0
    # Newly generated stitched blanket colour, rather than a downloaded image.
    n=512; yy,xx=np.mgrid[0:n,0:n]; cell=n//4
    rng=np.random.default_rng(2014)
    shade=rng.uniform(.95,1.035,(4,4))[yy//cell,xx//cell]
    edge=np.minimum(np.minimum(xx%cell,cell-xx%cell),np.minimum(yy%cell,cell-yy%cell))
    shade=shade-.09*np.exp(-(edge/1.8)**2)+rng.normal(0,.005,(n,n))
    rgba=np.ones((n,n,4)); rgba[:,:,:3]=np.array(srgb(0xcac9bc))[None,None,:]*shade[:,:,None]
    tex=mats['thermal'].node_tree.nodes.new('ShaderNodeTexImage')
    tex.image=image('survey stitched blanket colour',rgba)
    bsdf=mats['thermal'].node_tree.nodes['Principled BSDF']
    mats['thermal'].node_tree.links.new(tex.outputs['Color'],bsdf.inputs['Base Color'])
    for key, color, power in [('screen',0x0b1b22,.0),('ink',0x7ebac5,.9),
                              ('lamp',0xe5f3ff,2.2),('amber',0xe0a656,1.0)]:
        mats[key] = material('survey'+key.title(), srgb(color), .42, .02,
                             srgb(color) if power else None, power)
    mats['legend'] = material('surveyLegend',srgb(0xc9d5ce),.65,.01)
    return mats
