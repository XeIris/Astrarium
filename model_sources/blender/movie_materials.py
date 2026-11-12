"""Original, tileable PBR finishes for the film-inspired craft.

Colour follows the surface structure. The same stitch, pore or scuff changes
roughness and relief where appropriate, without baking a light direction.
"""
from zlib import crc32

import numpy as np

from evapod_materials import DENSITY, assign_uvs, image
from common import build_materials, srgb
from lib import material


def _fields(name, kind, size):
    rng = np.random.default_rng(crc32(name.encode()))
    yy, xx = np.mgrid[0:size, 0:size]
    x, y = xx / size, yy / size
    fx = np.fft.rfftfreq(size)[None, :]
    fy = np.fft.fftfreq(size)[:, None]

    def noise(horizontal, vertical):
        spectrum = np.fft.rfft2(rng.standard_normal((size, size)))
        spectrum *= np.exp(-2 * np.pi**2 * ((horizontal * fx)**2 + (vertical * fy)**2))
        field = np.fft.irfft2(spectrum, s=(size, size), axes=(0, 1))
        return field / max(float(field.std()), 1e-8)

    grain = noise(.84, .84)
    fine = noise(.43, .43)
    cloud = noise(size / 12, size / 16)
    if kind in ('blanket', 'quilt'):
        across, along = (4, 6) if kind == 'blanket' else (5, 5)
        u, v = (x * across) % 1, (y * along) % 1
        edge = np.minimum(np.minimum(u, 1-u), np.minimum(v, 1-v))
        seam = np.exp(-(edge / .027)**2)
        thread = np.exp(-((edge - .045) / .012)**2)
        thread *= .57 + .43 * np.cos(2*np.pi*72*(y+x))
        cloth = np.sin(2*np.pi*120*x) * np.sin(2*np.pi*112*y)
        fold = np.sin(np.pi*u) * np.sin(np.pi*v)
        tint = rng.uniform(-.038, .030, (along, across))[yy*along//size, xx*across//size]
        return (1+tint+.008*cloud-.12*seam+.055*thread+.008*cloth,
                .035*cloud+.071*seam-.062*thread+.025*grain,
                .21*fold-.16*seam+.105*thread+.035*cloth+.016*grain)
    if kind == 'tile':
        across, along = 6, 8
        row = yy*along//size
        shifted = (x + (row % 2) * .5/across) % 1
        u, v = (shifted * across) % 1, (y * along) % 1
        edge = np.minimum(np.minimum(u, 1-u), np.minimum(v, 1-v))
        seam = np.exp(-(edge / .025)**2)
        tint = rng.uniform(-.11, .14, (along, across))[row, (shifted*across).astype(int)]
        pitting = np.maximum(grain-1.05, 0)
        return (1+tint-.31*seam+.044*cloud+.047*fine-.038*pitting,
                .045*cloud+.069*seam+.045*grain,
                -.34*seam-.075*pitting+.032*fine)
    if kind == 'alloy' or kind == 'hot':
        brush = noise(size/9, .60)
        abrasion = np.maximum(noise(size/18, .45)-1.10, 0)
        return (1+.035*cloud+.062*brush+.030*abrasion,
                .028*cloud+.055*brush-.037*abrasion,
                .060*brush+.043*abrasion+.014*grain)
    if kind == 'vinyl':
        pores = np.abs(grain)**1.3
        polished = np.clip(noise(size/13, size/9), 0, 2)
        return (1-.036*pores+.047*polished+.028*cloud,
                .054*pores-.072*polished+.019*grain,
                -.14*pores+.020*fine)
    if kind == 'weave':
        warp = np.cos(2*np.pi*56*x)
        weft = np.cos(2*np.pi*48*y)
        interlace = .5*(warp+weft) + .32*warp*weft
        return (1+.12*interlace+.018*cloud, .09*interlace+.018*grain,
                .20*interlace+.027*grain)
    if kind == 'rubber':
        stipple = np.maximum(grain-.2, 0)
        return (1+.044*cloud+.052*stipple, .048*cloud+.026*grain, .10*stipple+.012*fine)
    # Long, sparse streaks read as handling and service wear at a larger scale
    # than the small orange-peel relief in the paint.
    rub = np.clip(noise(size/5, size/45)-.45, 0, 2)
    return (1+.009*cloud-.015*rub+.008*fine,
            .014*cloud+.027*rub+.018*grain,
            .021*grain+.009*fine)


def surface(name, color, roughness, metalness, kind, density):
    size = 512 if kind in ('blanket', 'tile') else 256
    shade, spread, height = _fields(name, kind, size)
    mat = material(name, srgb(color), roughness, metalness)
    bsdf = mat.node_tree.nodes['Principled BSDF']
    rgba = np.ones((size, size, 4))
    rgb = np.array([(color >> n & 255)/255 for n in (16, 8, 0)])
    rgba[:, :, :3] = np.clip(shade[:, :, None] * rgb, 0, 1)
    albedo = image(name+' colour', rgba, 'sRGB')
    rgba[:, :, :3] = np.clip(roughness+spread, .10, .97)[:, :, None]
    rough = image(name+' roughness', rgba)
    dx = (np.roll(height, -1, 1)-np.roll(height, 1, 1)) * .72
    dy = (np.roll(height, -1, 0)-np.roll(height, 1, 0)) * .72
    normal = np.stack((-dx, -dy, np.ones_like(dx)), axis=2)
    normal /= np.linalg.norm(normal, axis=2, keepdims=True)
    rgba[:, :, :3] = .5+.5*normal
    normal_map = image(name+' relief', rgba)
    for socket, bitmap in [('Base Color', albedo), ('Roughness', rough), ('Normal', normal_map)]:
        tex = mat.node_tree.nodes.new('ShaderNodeTexImage')
        tex.image = bitmap
        if socket == 'Normal':
            convert = mat.node_tree.nodes.new('ShaderNodeNormalMap')
            mat.node_tree.links.new(tex.outputs['Color'], convert.inputs['Color'])
            mat.node_tree.links.new(convert.outputs['Normal'], bsdf.inputs[socket])
        else:
            mat.node_tree.links.new(tex.outputs['Color'], bsdf.inputs[socket])
    DENSITY[name] = density
    return mat


def palette(cabin=False):
    mats = dict(build_materials())
    rows = [
        ('thermal', 'surveyThermal', 0xc8c6b9, .79, .025, 'blanket', .58),
        ('enamel', 'surveyEnamel', 0xcdcdc7, .48, .05, 'paint', .91),
        ('tps', 'surveyCarbon', 0x323638, .84, .025, 'tile', 1.0),
        ('panel', 'surveyPanel', 0x3d454a, .56, .15, 'paint', 4),
        ('alloy', 'surveyAlloy', 0xb1b7bc, .39, .32, 'alloy', 3.6),
        ('rubber', 'surveyRubber', 0x222827, .80, .01, 'rubber', 12),
        ('nozzle', 'surveyHeatAlloy', 0x7c7167, .51, .37, 'hot', 3.0),
    ]
    if cabin:
        rows.extend([
            ('liner', 'surveyLiner', 0x85847b, .72, .025, 'paint', 4),
            ('cabin_quilt', 'surveyCabinQuilt', 0x8c8b80, .80, .02, 'quilt', 2.6),
            ('seat', 'surveySeat', 0x394147, .69, .015, 'vinyl', 8),
            ('webbing', 'surveyWebbing', 0x92918a, .86, .01, 'weave', 9),
            ('deck', 'surveyDeck', 0x4b5153, .80, .05, 'rubber', 5),
        ])
    for key, *settings in rows:
        mats[key] = surface(*settings)
    if not cabin:
        mats['liner'] = mats['enamel']
    mats['glass'] = material('surveyGlazing', srgb(0x182c34), .14, .12)
    for key, color, power in [('screen',0x0b1b22,0.0), ('ink',0x7ebac5,.9),
                              ('lamp',0xe5f3ff,2.2), ('amber',0xe0a656,1.0)]:
        mats[key] = material('survey'+key.title(), srgb(color), .42, .02,
                             srgb(color) if power else None, power)
    mats['legend'] = material('surveyLegend', srgb(0xc9d5ce), .65, .01)
    return mats
