# SPACE SHUTTLE, the Blender build. Nothing is stacked: vehicles.gd mounts all
# three (`look.mount`), the solids hang below the tank's base, and the orbiter is
# bolted to its side.
#
# Every station is in the program's own coordinates, inches, and converted once:
#   Xo/Yo/Zo  orbiter: nose tip Xo 236, payload bay axis Zo 400, +Yo starboard
#   XT        tank: nose tip XT 322.5;  XB  booster: nose tip XB 200
#   XS = XT = XB + 543 = Xo + 741, and the orbiter's Zo 400 plane is 336.5 in off
#   the tank axis (Space Shuttle News Reference, "Coordinate system").
# Sources for the lines (docs/physics/shuttle-geometry.md has the table):
#   NASA CR-134087 (DMS-DR-2083, configuration 140A/B): body, wing W116, vertical
#   V8, elevons, body flap, OMS pods and nozzles, full-scale; its model three-view
#   gives the side profile and the nose planform.
#   NASA TM X-58153: SSME gimbal centres and cant angles.
#   HAER TX-116: ET ring frames at XT 745, 852, 1129, 2058.
# Axes: the stage axis is Blender +Z (nose up), Yo is Blender X, and the orbiter's
# top (+Zo) is Blender -Y (lib.py's axis note).
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from math import pi, cos, sin, sqrt, atan2, radians, log
from mathutils import Vector, Matrix, Euler
import bmesh
from lib import (revolve, cyl, lathe, box, torus_z, disc, empty, finish, smooth,
                 strut, bell, ogive, _obj, TAU)
from common import build, stage, vehicle_stages

S = vehicle_stages("shuttle")
IN = 0.0254

SRB_L, SRB_D = S["srb"]["L"], S["srb"]["D"]
ET_L, ET_D = S["et"]["L"], S["et"]["D"]
ORB_L = S["orbiter"]["L"]

# The orbiter's datum (stage z = 0) is its aft-most point, the vertical tail's tip
# trailing edge, so the stage's L is the published 37.24 m overall length.
XO_NOSE = 236.0
XO_DATUM = XO_NOSE + ORB_L / IN
XT_AFT = 322.5 + ET_L / IN            # tank datum: the LH2 aft dome
XB_EXIT = 200.0 + SRB_L / IN          # booster datum: the nozzle exit plane
SRB_Y = 250.5 * IN                    # booster axes at Ys ±250.5


def P(xo, yo, zo):
    """Orbiter station → stage frame."""
    return Vector((yo * IN, -(zo - 400.0) * IN, (XO_DATUM - xo) * IN))


def PT(xt, yt, zt):
    """Tank station → stage frame; zt measured from the tank axis toward the orbiter."""
    return Vector((yt * IN, -zt * IN, (XT_AFT - xt) * IN))


def orient(ob, outward):
    """Flip any face whose normal disagrees with `outward(centre)`: hand-built
    strips are easy to wind backwards, and the shading shows it."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    for f in bm.faces:
        if f.normal.dot(outward(f.calc_center_median())) < 0.0:
            f.normal_flip()
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()
    return ob


def strip(name, rows, mat, parent=None, closed=False):
    """A quad mesh through rows of points (every row the same length)."""
    n = len(rows[0])
    verts = [tuple(p) for r in rows for p in r]
    faces = []
    m = n if closed else n - 1
    for i in range(len(rows) - 1):
        for j in range(m):
            j2 = (j + 1) % n
            a, b = i * n + j, i * n + j2
            faces.append((a, b, b + n, a + n))
    return _obj(name, verts, faces, mat, parent)


def local_to(node_matrix, rows):
    inv = node_matrix.inverted()
    return [[inv @ p for p in r] for r in rows]


def pchip(xs, ys):
    """A monotone cubic through tabulated stations: lines that are smooth between
    table rows without overshooting them (Fritsch–Carlson)."""
    n = len(xs)
    d = [(ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) for i in range(n - 1)]
    m = [d[0]] + [0.0 if d[i - 1] * d[i] <= 0 else
                  (3 * (xs[i + 1] - xs[i - 1])) / ((2 * xs[i + 1] - xs[i] - xs[i - 1]) / d[i - 1] +
                                                   (xs[i + 1] + xs[i] - 2 * xs[i - 1]) / d[i])
                  for i in range(1, n - 1)] + [d[-1]]

    def f(x):
        if x <= xs[0]:
            return ys[0]
        if x >= xs[-1]:
            return ys[-1]
        i = max(k for k in range(n - 1) if xs[k] <= x)
        h = xs[i + 1] - xs[i]
        t = (x - xs[i]) / h
        h00, h10 = 2 * t ** 3 - 3 * t * t + 1, t ** 3 - 2 * t * t + t
        h01, h11 = -2 * t ** 3 + 3 * t * t, t ** 3 - t * t
        return h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]
    return f


# THE FUSELAGE LINES
# Per station: belly Zo, top Zo, half-width, the height where the sides turn into
# the roof, the chine radius, the roof's superellipse exponent, and the height of
# the black/white tile boundary. Belly and top are the model three-view's profile;
# the half-widths are its planform to Xo 505 (where the wing glove meets the
# body), then the bay's 17 ft, flaring to the base's 262 in (CR-134087).
_FUS = [
    # Xo     belly  top    w      z_s    r_c   n_t   z_line
    (236.0, 335.6, 336.4, 0.4, 336.0, 0.4, 2.0, 999),
    (238.0, 327.0, 343.0, 9.0, 334.5, 7.5, 2.0, 999),
    (241.0, 320.0, 349.0, 14.0, 334.0, 12.0, 2.0, 999),
    (245.0, 313.5, 353.0, 19.0, 334.0, 17.0, 2.0, 999),
    (250.0, 308.5, 358.0, 24.0, 334.0, 21.0, 2.0, 999),
    (256.0, 304.0, 364.0, 29.0, 335.0, 25.0, 2.0, 999),
    (265.0, 300.0, 372.0, 34.0, 337.0, 29.0, 2.0, 380),
    (275.0, 296.0, 379.0, 39.0, 339.0, 32.0, 2.05, 375),
    (290.0, 291.5, 389.0, 46.0, 342.0, 35.0, 2.1, 370),
    (310.0, 288.0, 397.0, 53.0, 346.0, 37.0, 2.15, 365),
    (335.0, 283.5, 405.0, 62.0, 350.0, 37.0, 2.2, 358),
    (360.0, 281.0, 414.0, 69.0, 355.0, 35.0, 2.2, 352),
    (385.0, 279.5, 422.0, 75.0, 360.0, 33.0, 2.2, 346),
    (410.0, 278.5, 431.5, 80.5, 366.0, 30.0, 2.2, 340),
    (435.0, 277.5, 444.0, 84.8, 372.0, 28.0, 2.25, 335),
    (460.0, 276.5, 463.0, 88.7, 380.0, 26.0, 2.3, 330),
    (485.0, 275.5, 481.0, 92.8, 388.0, 24.0, 2.35, 325),
    (510.0, 274.5, 491.5, 96.5, 396.0, 22.0, 2.4, 320),
    (540.0, 273.5, 494.5, 100.0, 404.0, 20.0, 2.3, 316),
    (582.0, 272.0, 496.0, 102.0, 410.0, 18.0, 2.1, 312),
    (700.0, 267.5, 496.5, 102.0, 410.0, 18.0, 2.1, 308),
    (850.0, 264.0, 497.5, 102.0, 410.0, 18.0, 2.1, 306),
    (1000.0, 261.0, 498.5, 102.0, 410.0, 18.0, 2.1, 305),
    (1150.0, 259.2, 500.0, 102.0, 410.0, 17.0, 2.1, 305),
    (1307.0, 259.5, 501.0, 102.0, 410.0, 16.0, 2.1, 305),
    (1340.0, 260.0, 503.0, 107.0, 411.0, 15.0, 1.8, 304),
    (1400.0, 263.5, 510.0, 118.0, 412.0, 14.0, 1.45, 302),
    (1460.0, 268.0, 518.0, 126.0, 412.0, 12.0, 1.3, 300),
    (1500.0, 272.0, 522.0, 129.5, 411.0, 12.0, 1.3, 298),
    (1528.3, 275.6, 525.0, 131.0, 410.0, 12.0, 1.3, 296),
]
_KEYS = ('zb', 'zt', 'w', 'zs', 'rc', 'nt', 'zl')
_F = {k: pchip([r[0] for r in _FUS], [r[i + 1] for r in _FUS]) for i, k in enumerate(_KEYS)}
XO_BAY0, XO_BAY1, XO_BASE = 582.0, 1307.0, 1528.3


def sec(xo):
    c = {k: _F[k](xo) for k in _KEYS}
    c['xo'] = xo
    c['rc'] = min(c['rc'], c['w'], max(c['zs'] - c['zb'], 0.0))
    return c


def half_profile(c, n=96):
    """The right half of a section, bottom centre to top centre, as (yo, zo)
    points: flat belly, chine arc, side wall, roof superellipse."""
    w, zb, zt, zs, rc, nt = c['w'], c['zb'], c['zt'], c['zs'], c['rc'], c['nt']
    pts = [(0.0, zb)]
    if w - rc > 1e-3:
        pts.append((w - rc, zb))
    for i in range(1, 9):
        a = -pi / 2 + (i / 8) * pi / 2
        pts.append((w - rc + rc * cos(a), zb + rc + rc * sin(a)))
    if zs > zb + rc + 1e-3:
        pts.append((w, zs))
    e = 2.0 / nt
    for i in range(1, n + 1):
        a = (i / n) * pi / 2
        pts.append((w * cos(a) ** e, zs + (zt - zs) * sin(a) ** e))
    return pts


def _cum(pts):
    s = [0.0]
    for (a, b) in zip(pts, pts[1:]):
        s.append(s[-1] + ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5)
    return s


class Ring:
    """One station's half-profile, evaluated by arc-length fraction s ∈ [0, 1]
    (0 bottom centre, 1 top centre); negative s is the port side."""

    def __init__(self, xo):
        self.c = sec(xo)
        self.pts = half_profile(self.c)
        self.cum = _cum(self.pts)
        self.L = max(self.cum[-1], 1e-6)

    def at(self, s):
        sign = -1.0 if s < 0 else 1.0
        d = min(abs(s), 1.0) * self.L
        k = 0
        while k < len(self.cum) - 2 and self.cum[k + 1] < d:
            k += 1
        seg = max(self.cum[k + 1] - self.cum[k], 1e-9)
        t = (d - self.cum[k]) / seg
        y = self.pts[k][0] + (self.pts[k + 1][0] - self.pts[k][0]) * t
        z = self.pts[k][1] + (self.pts[k + 1][1] - self.pts[k][1]) * t
        return P(self.c['xo'], sign * y, z)

    def s_at_z(self, z):
        """The first s (from the belly up) where the profile reaches height z."""
        for k in range(len(self.pts) - 1):
            z0, z1 = self.pts[k][1], self.pts[k + 1][1]
            if (z0 - z) * (z1 - z) <= 0 and abs(z1 - z0) > 1e-9:
                t = (z - z0) / (z1 - z0)
                return (self.cum[k] + t * (self.cum[k + 1] - self.cum[k])) / self.L
        return 1.0 if z > self.pts[-1][1] else 0.0


def stations(x0, x1, step):
    n = max(int(round((x1 - x0) / step)), 1)
    return [x0 + (x1 - x0) * i / n for i in range(n + 1)]


FWD_X = stations(236.0, 262.0, 2.6) + stations(262.0, 582.0, 10.0)[1:]
BAY_X = stations(XO_BAY0, XO_BAY1, 36.25)
AFT_X = stations(XO_BAY1, XO_BASE, 13.0)


def hull_outward(c_axis_z=400.0):
    """Outward for the hull: away from the section's own centre line."""
    def f(p):
        xo = XO_DATUM - p.z / IN
        c = sec(min(max(xo, XO_NOSE), XO_BASE))
        mid = (c['zb'] + c['zt']) / 2
        v = Vector((p.x, p.y + (mid - 400.0) * IN, 0.0))
        if xo < XO_NOSE + 2.0:
            v.z = 1.0
        return v
    return f


def hull_strip(name, xs, s_fn, n, mat, parent):
    """A band of hull between per-station arc fractions s_fn(ring) -> (s0, s1)."""
    rows = []
    for xo in xs:
        r = Ring(xo)
        s0, s1 = s_fn(r)
        rows.append([r.at(s0 + (s1 - s0) * j / n) for j in range(n + 1)])
    ob = strip(name, rows, mat, parent)
    orient(ob, hull_outward())
    smooth(ob, 40)
    return ob


def hull_point(xo, s, off=0.0):
    """A point on the hull, `off` inches out along its normal."""
    r = Ring(xo)
    p = r.at(s)
    if off == 0.0:
        return p
    d = 0.6
    a = Ring(xo + d).at(s) - Ring(xo - d).at(s)
    b = r.at(s + 0.003) - r.at(s - 0.003)
    nrm = b.cross(a) if s >= 0 else a.cross(b)
    if nrm.length < 1e-9:
        return p
    nrm.normalize()
    if nrm.dot(hull_outward()(p)) < 0:
        nrm = -nrm
    return p + nrm * off * IN


def roof_point(xo, yo, off=0.0):
    """A point on the roof at (xo, yo), for features laid out in plan: the
    windows, the overhead jets."""
    r = Ring(xo)
    c = r.c
    yo = max(min(yo, c['w'] - 0.01), -c['w'] + 0.01)
    # roof superellipse solved for its height at |yo|
    u = 1.0 - (abs(yo) / c['w']) ** c['nt']
    z = c['zs'] + (c['zt'] - c['zs']) * max(u, 0.0) ** (1.0 / c['nt'])
    s = r.s_at_z(z)
    return hull_point(xo, s if yo >= 0 else -s, off)


def roof_patch(name, xa, xb, ya0, ya1, yb0, yb1, off, mat, parent, nu=6, nv=6):
    """A quad patch on the roof, its plan a trapezoid: at Xo xa it spans ya0..ya1,
    at xb yb0..yb1."""
    rows = []
    for i in range(nu + 1):
        t = i / nu
        xo = xa + (xb - xa) * t
        y0 = ya0 + (yb0 - ya0) * t
        y1 = ya1 + (yb1 - ya1) * t
        rows.append([roof_point(xo, y0 + (y1 - y0) * j / nv, off) for j in range(nv + 1)])
    ob = strip(name, rows, mat, parent)
    orient(ob, hull_outward())
    return ob


def roof_band(name, y0, y1, x_lo, x_hi, off, mat, parent, nu=4, nv=8):
    """A roof patch spanning yo ∈ [y0, y1], each column from x_lo(yo) to x_hi(yo)."""
    cols = []
    for j in range(nv + 1):
        yo = y0 + (y1 - y0) * j / nv
        cols.append([roof_point(x_lo(yo) + (x_hi(yo) - x_lo(yo)) * i / nu, yo, off) for i in range(nu + 1)])
    rows = [[cols[j][i] for j in range(nv + 1)] for i in range(nu + 1)]
    ob = strip(name, rows, mat, parent)
    orient(ob, hull_outward())
    return ob


def hull_patch(name, xa, xb, sa, sb, off, mat, parent, nu=4, nv=4):
    rows = []
    for i in range(nu + 1):
        xo = xa + (xb - xa) * i / nu
        rows.append([hull_point(xo, sa + (sb - sa) * j / nv, off) for j in range(nv + 1)])
    ob = strip(name, rows, mat, parent)
    orient(ob, hull_outward())
    return ob


def port(name, base, nrm, r, depth, mat, parent):
    """A thruster mouth set into the skin along `nrm`, half sunk."""
    ob = cyl(name, r, r, -depth * 0.5, depth * 0.5, mat, seg=12, parent=parent)
    cap = disc(name + '_c', r * 0.8, depth * 0.1, mat, seg=12, parent=parent)
    q = Vector((0, 0, 1)).rotation_difference(nrm.normalized())
    for o in (ob, cap):
        o.rotation_mode = 'QUATERNION'
        o.rotation_quaternion = q
        o.location = base
    return ob


def hull_port(name, xo, s, r_in, mat, parent):
    p = hull_point(xo, s)
    n = hull_point(xo, s, 1.0) - p
    return port(name, p, n, r_in * IN, r_in * 1.6 * IN, mat, parent)


def build_fuselage(M, g):
    # Black where the plasma goes (the belly, the chines, the chin), white above.
    # The split follows each station's own boundary height, so it climbs toward
    # the nose cap the way the tile map does.
    def black(r):
        sl = r.s_at_z(r.c['zl'])
        return (-sl, sl)

    def white(r):
        sl = r.s_at_z(r.c['zl'])
        return (sl, 2.0 - sl)

    def white_bay(side):
        def f(r):
            sl = r.s_at_z(r.c['zl'])
            sh = r.s_at_z(r.c['zs'])
            return (sl, sh) if side > 0 else (-sh, -sl)
        return f

    # forward fuselage, closed rings; the white band wraps over the top, so its
    # port half is the mirror of `at` past s = 1
    class Wrap:
        def __init__(self, xo):
            self.r = Ring(xo)
            self.c = self.r.c

        def at(self, s):
            return self.r.at(s) if s <= 1.0 else self.r.at(-(2.0 - s))

        def s_at_z(self, z):
            return self.r.s_at_z(z)

    def wrap_strip(name, xs, fn, n, mat):
        rows = []
        for xo in xs:
            r = Wrap(xo)
            s0, s1 = fn(r)
            rows.append([r.at(s0 + (s1 - s0) * j / n) for j in range(n + 1)])
        ob = strip(name, rows, mat, g)
        orient(ob, hull_outward())
        smooth(ob, 40)
        return ob

    # The RCC nose cap is its own colour: carbon-carbon, grey-black, to Xo ~262.
    nose_x = [x for x in FWD_X if x <= 262.0]
    wrap_strip('nosecap', nose_x, lambda r: (-1.0, 1.0), 40, M['soot'])
    rest = [x for x in FWD_X if x >= 262.0]
    wrap_strip('fwd_black', rest, black, 24, M['tiles'])
    wrap_strip('fwd_white', rest, white, 36, M['white'])
    hull_strip('bay_black', BAY_X, black, 16, M['tiles'], g)
    for side in (1, -1):
        hull_strip(f'bay_side{side}', BAY_X, white_bay(side), 8, M['white'], g)
    wrap_strip('aft_black', AFT_X, black, 16, M['tiles'])
    wrap_strip('aft_white', AFT_X, white, 36, M['white'])

    # The base heat shield behind the engines.
    r = Ring(XO_BASE)
    rim = [r.at(-1.0 + 2.0 * j / 48) for j in range(49)]
    ctr = sum(rim, Vector()) / len(rim)
    verts = [tuple(ctr)] + [tuple(p) for p in rim]
    faces = [(0, j + 1, j + 2) for j in range(48)]
    base = _obj('base', verts, faces, M['tiles'], g)
    orient(base, lambda p: Vector((0, 0, -1)))

    # The cabin's windows: six forward panes in one C-shaped band round the cabin
    # front, the centre pair leading (planform from the three-view), and two
    # overhead; each set in black tile.
    lo = lambda yo: 444.0 + 0.0098 * yo * yo
    hi = lambda yo: lo(yo) + 27.0 - 0.10 * abs(yo)
    roof_band('ws_mask', -82.0, 82.0, lambda yo: lo(yo) - 4.0, lambda yo: hi(yo) + 4.0, 0.35, M['tiles'], g, nu=4, nv=40)
    edges = (0.0, 28.0, 54.0, 77.0)
    for sgn in (1, -1):
        for k in range(3):
            y0, y1 = edges[k] + 1.5, edges[k + 1] - 1.5
            a0, a1 = (y0, y1) if sgn > 0 else (-y1, -y0)
            roof_band(f'ws{sgn}{k}', a0, a1, lo, hi, 0.9, M['glass'], g, nu=3, nv=4)
    roof_band('oh_mask', -31.0, 31.0, lambda yo: 520.0, lambda yo: 552.0, 0.35, M['tiles'], g, nu=3, nv=8)
    for y0, y1 in ((4.0, 27.0), (-27.0, -4.0)):
        roof_band(f'oh{int(y0)}', y0, y1, lambda yo: 524.0, lambda yo: 548.0, 0.9, M['glass'], g, nu=2, nv=3)

    # Side hatch, port, middeck, with its window.
    r = Ring(525.0)
    s = -r.s_at_z(350.0)
    p = hull_point(525.0, s)
    n = hull_point(525.0, s, 1.0) - p
    port('hatch', p, n, 20 * IN, 0.8 * IN, M['dirty'], g)
    port('hatch_win', p + n * 0.6 * IN, n, 5 * IN, 0.8 * IN, M['glass'], g)

    # Forward RCS: three up-firing jets on the module's crown, a row of side jets
    # each side, and the down-firing pairs under the chin.
    for k, yo in enumerate((-15, 0, 15)):
        p = roof_point(352.0 + abs(yo) * 0.3, yo)
        n = roof_point(352.0 + abs(yo) * 0.3, yo, 1.0) - p
        port(f'frcs_up{k}', p, n, 5.5 * IN, 8 * IN, M['black'], g)
    for sgn in (1, -1):
        for k, xo in enumerate((322.0, 336.0, 350.0)):
            s = Ring(xo).s_at_z(372.0)
            hull_port(f'frcs_side{sgn}{k}', xo, sgn * s, 5.0, M['black'], g)
        for k, xo in enumerate((300.0, 314.0)):
            hull_port(f'frcs_dn{sgn}{k}', xo, sgn * 0.22, 5.0, M['black'], g)


# THE WING
# Spanwise stations: BL (in from the centreline), leading- and trailing-edge Xo,
# thickness (in), where the thickness peaks (fraction of chord), and the chord
# line's height at the leading and trailing edge. The main panel is CR-134087's
# W116: 45° leading edge from a theoretical root LE at Xo 835.7 (0.25 MAC at
# Xo 1136.7, BL 182.3), trailing edge swept −10.06°, 3.5° dihedral, 0.113 → 0.12
# thick. The glove meets the body at Xo 505 and the main leading edge at Xo 1003.5
# (81° sweep). Elevon hinge line Xo 1387, unswept.
WING = [
    # BL      LE      TE      T      u_max  zc_LE  zc_TE
    (95.0, 505.0, 1508.0, 66.0, 0.49, 296.0, 280.0),
    (110.0, 607.7, 1505.4, 65.0, 0.46, 294.5, 282.0),
    (140.0, 813.2, 1500.1, 62.0, 0.42, 291.5, 284.0),
    (165.0, 990.0, 1495.6, 57.0, 0.40, 290.0, 286.0),
    (190.0, 1025.7, 1491.2, 53.0, 0.40, 291.5, 289.5),
    (300.0, 1135.7, 1471.7, 39.0, 0.40, 298.2, 296.2),
    (420.0, 1255.7, 1450.4, 23.2, 0.40, 305.6, 303.6),
    (455.0, 1293.0, 1444.2, 18.0, 0.40, 307.8, 305.8),
    (466.0, 1312.0, 1442.2, 13.0, 0.42, 308.5, 306.5),
    (468.34, 1335.0, 1441.8, 5.0, 0.45, 308.6, 306.6),
]
LOWER = 0.30          # share of the thickness below the chord line: a flat belly
ELEVON_X = 1387.0


def _thick(u, um):
    """Normalised thickness (1 at its peak) at chord fraction u, peaking at um."""
    p = log(0.3) / log(um)
    v = max(min(u, 1.0), 0.0) ** p
    return 5 * 0.2 * (0.2969 * sqrt(v) - 0.1260 * v - 0.3516 * v * v
                      + 0.2843 * v ** 3 - 0.1015 * v ** 4) / 0.10002


def wing_point(st, u, side, sgn):
    bl, le, te, T, um, z0, z1 = st
    xo = le + (te - le) * u
    zc = z0 + (z1 - z0) * u
    t = T * _thick(u, um)
    zo = zc + (1.0 - LOWER) * t if side > 0 else zc - LOWER * t
    return P(xo, sgn * bl, zo)


def wing_at(bl):
    """A wing station interpolated at any BL."""
    for a, b in zip(WING, WING[1:]):
        if a[0] <= bl <= b[0]:
            t = (bl - a[0]) / (b[0] - a[0])
            return tuple(a[i] + (b[i] - a[i]) * t for i in range(7))
    return WING[-1]


def _cos_u(n, u0, u1):
    return [u0 + (u1 - u0) * (1 - cos(pi * i / n)) / 2 for i in range(n + 1)]


def build_wing(M, g):
    le_u = 0.022
    band = 0.075            # the black tile border along the upper leading edge
    for sgn in (1, -1):
        def surf(name, sts, u0, u1, side, mat, n):
            rows = [[wing_point(st, u, side, sgn) for u in _cos_u(n, u0, u1)] for st in sts]
            ob = strip(name, rows, mat, g)
            up = Vector((0, -1, 0)) if side > 0 else Vector((0, 1, 0))
            orient(ob, lambda p, up=up: up)
            smooth(ob, 38)
            return ob

        surf(f'wing_top_b{sgn}', WING, le_u, band, 1, M['tiles'], 4)
        surf(f'wing_top_w{sgn}', WING, band, 1.0, 1, M['white'], 18)
        surf(f'wing_bot{sgn}', WING, le_u, 1.0, -1, M['tiles'], 20)
        # The leading edge itself: black tile on the glove, grey RCC panels (22 a
        # side) on the main wing, where it runs at ~1500 °C.
        for nm, sts, mat in (('glove_le', WING[:4], M['tiles']), ('rcc', WING[3:], M['soot'])):
            rows = []
            for st in sts:
                row = [wing_point(st, u, -1, sgn) for u in _cos_u(4, le_u, 0.0)]
                row += [wing_point(st, u, 1, sgn) for u in _cos_u(4, 0.0, le_u)[1:]]
                rows.append(row)
            ob = strip(f'{nm}{sgn}', rows, mat, g)
            orient(ob, lambda p, sg=sgn: Vector((0, 0, 1)))
            smooth(ob, 60)
        # Tip closure: the last station's two surfaces sewn together.
        st = WING[-1]
        us = _cos_u(10, 0.0, 1.0)
        tip = [wing_point(st, u, 1, sgn) for u in us] + [wing_point(st, u, -1, sgn) for u in reversed(us[1:-1])]
        verts = [tuple(p) for p in tip]
        ob = _obj(f'wingtip{sgn}', verts, [tuple(range(len(verts)))], M['tiles'], g)
        orient(ob, lambda p, sg=sgn: Vector((sg, 0, 0)))

        # Elevon hinge line and the inboard/outboard split, as seams on the top.
        seam = []
        for bl in [115 + (455 - 115) * i / 12 for i in range(13)]:
            st = wing_at(bl)
            u = (ELEVON_X - st[1]) / (st[2] - st[1])
            seam.append(wing_point(st, u, 1, sgn) + Vector((0, -0.006, 0)))
        ribbon(f'elevon_hinge{sgn}', seam, 0.035, M['soot'], g)
        for bl in (115.0, 285.0, 455.0):
            st = wing_at(bl)
            u = (ELEVON_X - st[1]) / (st[2] - st[1])
            pts = [wing_point(st, u + (1 - u) * k / 6, 1, sgn) + Vector((0, -0.006, 0)) for k in range(7)]
            ribbon(f'elevon_edge{sgn}_{int(bl)}', pts, 0.03, M['soot'], g, across=Vector((1, 0, 0)))


def ribbon_rows(pts, width, across=None):
    rows = []
    for i, p in enumerate(pts):
        t = (pts[min(i + 1, len(pts) - 1)] - pts[max(i - 1, 0)]).normalized()
        a = across if across is not None else t.cross(Vector((0, 1, 0))).normalized()
        rows.append([p - a * width / 2, p + a * width / 2])
    return rows


def ribbon(name, pts, width, mat, parent, across=None):
    """A thin flat strip along a polyline: a seam, a panel line."""
    return strip(name, ribbon_rows(pts, width, across), mat, parent)


# THE VERTICAL TAIL (V8): 413.25 ft², 45° leading edge, root chord 268.5 in at
# WP 500, tip 108.47 in at WP 815.72, so the tip's trailing edge is the
# orbiter's aft-most point (Xo 1702.2). A 10° wedge forward and 14.9° aft: the
# section is thickest at 60% chord, where the rudder/speed brake hinges.
def tail_section(zo):
    f = (zo - 500.0) / 315.72
    le = 1278.0 + (zo - 500.0)
    ch = 268.5 + (108.47 - 268.5) * f
    return le, ch


def tail_half(u, ch):
    T = 0.105 * ch
    if u < 0.6:
        return T / 2 * min(u / 0.6, 1.0) ** 0.62
    return T / 2 * max((1.0 - u) / 0.4, 0.0) + 0.15


def build_tail(M, g):
    zs = [494.0, 500.0, 540.0, 600.0, 670.0, 740.0, 790.0, 815.72]
    us = _cos_u(18, 0.0, 1.0)
    rows_w, rows_b = [], []
    for zo in zs:
        le, ch = tail_section(zo)
        ring = [P(le + u * ch, tail_half(u, ch), zo) for u in reversed(us)]
        ring += [P(le + u * ch, -tail_half(u, ch), zo) for u in us[1:]]
        rows_w.append(ring)
    # one mesh, the leading-edge band in black tile
    n = len(us)
    ob = strip('fin', rows_w, M['white'], g)
    orient(ob, lambda p: Vector((p.x, 0, 0)) if abs(p.x) > 1e-4 else Vector((0, 0, 1)))
    smooth(ob, 40)
    le_rows = []
    for zo in zs:
        le, ch = tail_section(zo)
        ring = [P(le + u * ch, tail_half(u, ch) + 0.25, zo) for u in reversed(_cos_u(3, 0.0, 0.05))]
        ring += [P(le + u * ch, -tail_half(u, ch) - 0.25, zo) for u in _cos_u(3, 0.0, 0.05)[1:]]
        le_rows.append(ring)
    ob = strip('fin_le', le_rows, M['tiles'], g)
    orient(ob, lambda p: Vector((p.x, 0, 0)) if abs(p.x) > 1e-4 else Vector((0, 0, 1)))
    # tip cap
    le, ch = tail_section(815.72)
    cap = [P(le + u * ch, tail_half(u, ch), 815.72) for u in reversed(us)]
    cap += [P(le + u * ch, -tail_half(u, ch), 815.72) for u in us[1:-1]]
    ob = _obj('fin_tip', [tuple(p) for p in cap], [tuple(range(len(cap)))], M['white'], g)
    orient(ob, lambda p: Vector((0, -1, 0)))
    # Rudder/speed brake: hinge at 60% chord, Zo 573 → 787, split into upper and
    # lower panels, each opening as a V.
    for sgn in (1, -1):
        hinge = []
        for zo in [573 + (787 - 573) * i / 6 for i in range(7)]:
            le, ch = tail_section(zo)
            hinge.append(P(le + 0.6 * ch, sgn * (tail_half(0.6, ch) + 0.3), zo))
        ribbon(f'rudder_hinge{sgn}', hinge, 0.03, M['soot'], g, across=Vector((0, 0, 1)))
        for zo in (573.0, 680.0, 787.0):
            le, ch = tail_section(zo)
            pts = [P(le + u * ch, sgn * (tail_half(u, ch) + 0.3), zo) for u in (0.6, 0.7, 0.8, 0.9, 1.0)]
            ribbon(f'rudder_edge{sgn}_{int(zo)}', pts, 0.03, M['soot'], g, across=Vector((0, 1, 0)))
    # The drag-chute housing at the foot of the rudder (flown from 1992).
    hs = [P(1528, 0, 503), P(1600, 0, 503)]
    b = box('chute', (24 * IN, 34 * IN, 70 * IN), tuple((hs[0] + hs[1]) / 2 + Vector((0, -17 * IN, 0))), M['white'], parent=g)
    finish(b, 0.03, 2, 40)


# OMS PODS (CR-134087 M7): Xo 1233 → 1560, 94.5 in wide at Xo 1450, 109 in deep at
# 1493, centred Yo ±100 on the aft fuselage's shoulders. Engines: gimbal Xo 1518,
# Yo ±88, Zo 492; null position 15°49' pitch-up and 12°17' outboard.
POD = [
    # Xo     hw     hh     zc
    (1233.0, 1.0, 1.0, 472.0),
    (1240.0, 12.0, 13.0, 472.5),
    (1255.0, 23.0, 25.0, 474.0),
    (1280.0, 32.0, 35.0, 476.0),
    (1320.0, 39.5, 44.0, 478.0),
    (1370.0, 44.0, 50.0, 479.5),
    (1420.0, 46.5, 53.0, 480.5),
    (1450.0, 47.25, 54.0, 481.0),
    (1493.0, 46.5, 54.5, 481.5),
    (1530.0, 45.0, 53.5, 481.5),
    (1560.0, 43.5, 52.0, 481.5),
]
POD_Y = 100.0
POD_N = 2.3


def pod_point(row, a, sgn):
    xo, hw, hh, zc = row
    e = 2.0 / POD_N
    ca, sa = cos(a), sin(a)
    y = hw * (abs(ca) ** e) * (1 if ca >= 0 else -1)
    z = hh * (abs(sa) ** e) * (1 if sa >= 0 else -1)
    return P(xo, sgn * (POD_Y + y), zc + z)


def build_pods(M, g):
    for sgn in (1, -1):
        seg = 28
        rows = [[pod_point(r, TAU * j / seg, sgn) for j in range(seg + 1)] for r in POD]
        cut = 2                                      # the black-tiled nose
        for nm, rr, mat in (('pod_nose', rows[:cut + 1], M['tiles']), ('pod', rows[cut:], M['white'])):
            ob = strip(f'{nm}{sgn}', rr, mat, g)
            orient(ob, lambda p, sg=sgn: Vector((p.x - sg * POD_Y * IN, p.y + 481 * IN - 400 * IN, 0)))
            smooth(ob, 45)
        # aft face
        last = rows[-1][:-1]
        ctr = sum(last, Vector()) / len(last)
        verts = [tuple(ctr)] + [tuple(p) for p in last]
        faces = [(0, j + 1, (j + 1) % len(last) + 1) for j in range(len(last))]
        ob = _obj(f'pod_aft{sgn}', verts, faces, M['soot'], g)
        orient(ob, lambda p: Vector((0, 0, -1)))
        # The OMS engine (static: the stage's SPS has no gimbal nodes).
        mnt = empty(f'oms_mount{sgn}', tuple(P(1518.0, sgn * 88.0, 492.0)), g)
        mnt.rotation_euler = (radians(-15.82), radians(-sgn * 12.28), 0.0)
        bl = bell(f'omsbell{sgn}', 1.17, M['nozzle'], ratio=55, seg=24, parent=mnt, loc=(0, 0, -0.30))
        finish(bl, 0.006, 2, 50)
        # Aft RCS: a row of side jets on the outboard face, up-firing on top,
        # down-firing below, two firing aft.
        for k, xo in enumerate((1512.0, 1524.0, 1536.0, 1548.0)):
            row = (xo, 46.0, 53.8, 481.5)
            p = pod_point(row, 0.0, sgn)
            port(f'arcs_side{sgn}{k}', p, Vector((sgn, 0, 0)), 5 * IN, 8 * IN, M['black'], g)
        for k, xo in enumerate((1515.0, 1530.0, 1545.0)):
            row = (xo, 46.0, 53.8, 481.5)
            p = pod_point(row, pi / 2 - sgn * 0.25, sgn)
            port(f'arcs_up{sgn}{k}', p, Vector((0, -1, 0)), 5 * IN, 8 * IN, M['black'], g)
            p = pod_point(row, -pi / 2 + sgn * 0.6, sgn)
            port(f'arcs_dn{sgn}{k}', p, Vector((sgn * 0.5, 0.85, 0)), 5 * IN, 8 * IN, M['black'], g)
        for k, dz in enumerate((-22.0, 22.0)):
            port(f'arcs_aft{sgn}{k}', P(1560.5, sgn * (POD_Y + 18.0), 481.5 + dz), Vector((0, 0, -1)),
                 5 * IN, 4 * IN, M['black'], g)


# MAIN ENGINES (TM X-58153): gimbal centres Xo 1445 / Yo 0 / Zo 443 and Xo 1468.17 /
# Yo ±53 / Zo 342.64; engine 1 canted 16° pitch-up, 2 and 3 10° pitch-up and 3.5°
# outboard, so all three thrust lines pass near the mated stack's centre of mass.
# The pivot is the gimbal; the throat is 0.95 m aft of it along the engine axis.
SSME = [(1445.0, 0.0, 443.0, 16.0, 0.0), (1468.17, -53.0, 342.64, 10.0, -3.5),
        (1468.17, 53.0, 342.64, 10.0, 3.5)]


def build_engines(M, g):
    exit_d = S['et']['engine']['exitD']
    for i, (xo, yo, zo, pitch, yaw) in enumerate(SSME):
        mnt = empty(f'mount_gimbal_orbiter_{i}', tuple(P(xo, yo, zo)), g)
        mnt.rotation_euler = (radians(-pitch), radians(-yaw), 0.0)
        piv = empty(f'gimbal_orbiter_{i}', (0, 0, 0), mnt)
        b = bell(f'ssme{i}', exit_d, M['nozzle'], ratio=69, seg=32, parent=piv, loc=(0, 0, -0.95))
        finish(b, 0.008, 2, 50)
        # the powerhead's main combustion chamber, between gimbal and throat
        mcc = cyl(f'mcc{i}', 0.24, 0.30, -0.95, -0.15, M['hot'], seg=16, parent=piv)
        smooth(mcc, 40)


# BODY FLAP (F7): Xo 1520 → 1613, 262 in wide, 23 in deep at its root; hinge Xo
# 1532.3, Zo 284.3. Driven about its own span (the mount turns local Z onto X).
def build_body_flap(M, g):
    hinge = P(1532.3, 0.0, 284.3)
    mnt = empty('mount_flap_orbiter_0', tuple(hinge), g)
    mnt.rotation_euler = (0.0, 0.0, pi / 2)
    node = empty('flap_orbiter_0', (0, 0, 0), mnt)
    mw = Matrix.Translation(hinge) @ Euler((0.0, 0.0, pi / 2)).to_matrix().to_4x4()
    xs = (1520.0, 1560.0, 1613.0)
    tops = (296.0, 294.0, 288.0)
    bots = (273.0, 275.0, 281.0)
    for nm, zz, up in (('bf_top', tops, -1.0), ('bf_bot', bots, 1.0)):
        rows = [[P(x, y, z) for y in (-131.0, -60.0, 0.0, 60.0, 131.0)] for x, z in zip(xs, zz)]
        ob = strip(nm, local_to(mw, rows), M['tiles'], node)
        _orient_world(ob, mw, lambda p, u=up: Vector((0, u, 0)), 1)
    # edges: the two side faces and the trailing edge
    for sgn in (-1, 1):
        rows = [[P(x, sgn * 131.0, zt), P(x, sgn * 131.0, zb)] for x, zt, zb in zip(xs, tops, bots)]
        ob = strip(f'bf_side{sgn}', local_to(mw, rows), M['tiles'], node)
        _orient_world(ob, mw, lambda p, s=sgn: Vector((s, 0, 0)), 1)
    rows = [[P(1613.0, y, 288.0), P(1613.0, y, 281.0)] for y in (-131.0, 131.0)]
    ob = strip('bf_te', local_to(mw, rows), M['tiles'], node)
    _orient_world(ob, mw, lambda p: Vector((0, 0, -1)), 1)


# PAYLOAD BAY: 60 × 15 ft, Xo 582 → 1307. Two doors, hinged at the sill longerons
# and opening 175°; radiators on their inner faces. Inside: the RMS on the port
# sill, the docking system forward and a logistics module aft (a station flight).
DOOR_SEGMENTS = 5


def build_bay(M, g):
    for sgn in (1, -1):
        hinge = P(XO_BAY0, sgn * 102.0, 410.0)
        hinge.z = 0.0
        mnt_rot = (-pi / 2 if sgn > 0 else pi / 2, 0.0, 0.0)
        mnt = empty(f'mount_door_orbiter_{0 if sgn > 0 else 1}', (hinge.x, hinge.y, 0.0), g)
        mnt.rotation_euler = mnt_rot
        node = empty(f'door_orbiter_{0 if sgn > 0 else 1}', (0, 0, 0), mnt)
        mw = Matrix.Translation(Vector((hinge.x, hinge.y, 0.0))) @ Euler(mnt_rot).to_matrix().to_4x4()
        xs = stations(XO_BAY0 + 0.5, XO_BAY1 - 0.5, 36.25)

        def ring_rows(off, s1=0.9985):
            rows = []
            for xo in xs:
                r = Ring(xo)
                sh = r.s_at_z(r.c['zs']) - 0.004       # lapping over the sill
                row = []
                for j in range(17):
                    s = sh + (s1 - sh) * j / 16
                    p = r.at(sgn * s)
                    if off:
                        q = r.at(sgn * min(s + 0.003, 1.0)) - r.at(sgn * max(s - 0.003, 0.0))
                        nrm = Vector((0, 0, 1)).cross(q) if sgn > 0 else q.cross(Vector((0, 0, 1)))
                        nrm.normalize()
                        if nrm.dot(hull_outward()(p)) > 0:
                            nrm = -nrm
                        p = p + nrm * off * IN
                    row.append(p)
                rows.append(row)
            return rows

        outer = ring_rows(0.0)
        inner = ring_rows(2.0)
        ob = strip(f'door_skin{sgn}', local_to(mw, outer), M['white'], node)
        out_w = hull_outward()
        _orient_world(ob, mw, out_w, 1)
        smooth(ob, 40)
        ob = strip(f'door_rad{sgn}', local_to(mw, inner), M['alu'], node)
        _orient_world(ob, mw, out_w, -1)
        smooth(ob, 40)
        # the door's edge along the centreline, and its two ends
        rows = [[o[-1], i[-1]] for o, i in zip(outer, inner)]
        strip(f'door_edge{sgn}', local_to(mw, rows), M['white'], node)
        for k in (0, -1):
            strip(f'door_end{sgn}{k}', local_to(mw, [outer[k], inner[k]]), M['white'], node)
        # the expansion joints between its five segments
        for k in range(1, DOOR_SEGMENTS):
            xo = XO_BAY0 + (XO_BAY1 - XO_BAY0) * k / DOOR_SEGMENTS
            r = Ring(xo)
            sh = r.s_at_z(r.c['zs'])
            pts = [hull_point(xo, sgn * (sh + (0.998 - sh) * j / 10), 0.25) for j in range(11)]
            rows = ribbon_rows(pts, 0.04, Vector((0, 0, 1)))
            strip(f'door_joint{sgn}{k}', local_to(mw, rows), M['dirty'], node)

    # bay liner: walls, floor and the two bulkheads, white blanket
    wall_x = (XO_BAY0, XO_BAY1)
    for sgn in (1, -1):
        rows = [[P(x, sgn * 97.0, 300.0), P(x, sgn * 97.0, 409.0)] for x in wall_x]
        ob = strip(f'bay_wall{sgn}', rows, M['dirty'], g)
        orient(ob, lambda p, s=sgn: Vector((-s, 0, 0)))
    rows = [[P(x, -97.0, 300.0), P(x, 97.0, 300.0)] for x in wall_x]
    ob = strip('bay_floor', rows, M['dirty'], g)
    orient(ob, lambda p: Vector((0, -1, 0)))
    for xo, face in ((XO_BAY0 + 0.3, -1), (XO_BAY1 - 0.3, 1)):
        r = Ring(xo)
        sh = r.s_at_z(r.c['zs'])
        rim = [r.at(sh + (1.0 - sh) * j / 16) for j in range(17)]
        rim += [r.at(-(1.0 - (1.0 - sh) * j / 16)) for j in range(1, 17)]
        rim = [P(xo, 97.0, 300.0)] + [p for p in rim] + [P(xo, -97.0, 300.0)]
        ctr = sum(rim, Vector()) / len(rim)
        verts = [tuple(ctr)] + [tuple(p) for p in rim]
        faces = [(0, j + 1, j + 2) for j in range(len(rim) - 1)] + [(0, len(rim), 1)]
        ob = _obj(f'bulkhead{int(xo)}', verts, faces, M['dirty'], g)
        orient(ob, lambda p, f=face: Vector((0, 0, f)))
    # the two aft flight-deck windows, looking into the bay
    for y0 in (-40.0, 14.0):
        rows = [[P(XO_BAY0 + 0.6, y0, 446.0), P(XO_BAY0 + 0.6, y0 + 26.0, 446.0)],
                [P(XO_BAY0 + 0.6, y0, 468.0), P(XO_BAY0 + 0.6, y0 + 26.0, 468.0)]]
        ob = strip(f'aft_win{int(y0)}', rows, M['glass'], g)
        orient(ob, lambda p: Vector((0, 0, -1)))

    # Orbiter docking system: the external airlock and its APAS ring, forward.
    ods = P(650.0, 0.0, 300.0)
    a = cyl('ods', 0.80, 0.80, 0.0, 3.6, M['dirty'], seg=28, parent=g)
    a.rotation_euler = (pi / 2, 0, 0)
    a.location = ods
    smooth(a, 40)
    cap = disc('ods_top', 0.80, 3.6, M['dirty'], seg=28, parent=g)
    cap.rotation_euler = (pi / 2, 0, 0)
    cap.location = ods
    ring = cyl('apas', 0.62, 0.55, 3.6, 4.05, M['alu'], seg=24, parent=g)
    ring.rotation_euler = (pi / 2, 0, 0)
    ring.location = ods
    finish(ring, 0.01, 2, 45)
    box('ods_truss', (4.6, 0.5, 2.2), tuple(P(650.0, 0.0, 309.0)), M['alu'], parent=g)

    # A logistics module aft: 4.57 m across, 6.4 m long, on the bay axis.
    z0, z1 = P(XO_BAY1 - 20.0, 0, 400).z, P(XO_BAY1 - 20.0 - 252.0, 0, 400).z
    mp = cyl('mplm', 2.20, 2.20, z0 + 0.25, z1 - 0.25, M['white'], seg=40, parent=g)
    smooth(mp, 40)
    for zz, zend in ((z0 + 0.25, z0), (z1 - 0.25, z1)):
        dome = cyl(f'mplm_end{int(zz * 10)}', 2.20, 1.6, zz, zend, M['dirty'], seg=40, parent=g)
        smooth(dome, 40)
        disc(f'mplm_cap{int(zz * 10)}', 1.6, zend, M['dirty'], seg=40, parent=g)
    cyl('cbm', 0.95, 0.95, z1, z1 + 0.3, M['alu'], seg=24, parent=g)

    # The RMS: shoulder at Xo 679.5 on the port longeron, then the upper and lower
    # booms (6.4 and 7.1 m) and the wrist and end effector, cradled along the sill.
    y, zo = -88.0, 428.0
    sh = P(679.5, y, zo)
    box('rms_shoulder', (0.55, 0.55, 0.7), tuple(sh), M['dirty'], parent=g)
    el = P(679.5 + 6.37 / IN, y, zo)
    wr = P(679.5 + (6.37 + 7.06) / IN, y, zo)
    strut('rms_upper', sh, el, 0.17, M['white'], seg=16, parent=g)
    strut('rms_lower', el, wr, 0.17, M['white'], seg=16, parent=g)
    for nm, p in (('rms_elbow', el), ('rms_wrist', wr)):
        box(nm, (0.42, 0.42, 0.5), tuple(p), M['black'], parent=g)
    ee = P(679.5 + (6.37 + 7.06 + 0.5) / IN, y, zo)
    strut('rms_ee', wr, ee, 0.18, M['dirty'], seg=14, parent=g)
    for xo in (760.0, 1000.0, 1200.0):
        strut(f'rms_cradle{int(xo)}', P(xo, y, zo - 6), P(xo, y - 6, 409.0), 0.05, M['alu'], seg=6, parent=g)


def _orient_world(ob, mw, outward, sign):
    """`orient` for a mesh built in a node's frame against a stage-frame outward."""
    bm = bmesh.new()
    bm.from_mesh(ob.data)
    rot = mw.to_3x3()
    for f in bm.faces:
        c = mw @ f.calc_center_median()
        if (rot @ f.normal).dot(outward(c)) * sign < 0.0:
            f.normal_flip()
    bm.to_mesh(ob.data)
    bm.free()
    ob.data.update()


# LANDING GEAR: nose gear under the cabin, mains in the wing roots (wells Xo 1040 →
# 1191), both retracting forward. Built stowed, along +Xo-forward from each pivot;
# the drive swings them 90° down (`look.gearSwing`). Deployed, the main tyres touch
# at Xo 1180 / Zo 150, the stage's `gear.point`.
GEAR = [
    # pivot Xo, Yo, Zo, strut (in), tyre diameter, tyre width (in)
    (470.0, 0.0, 300.0, 124.0, 32.0, 9.0),
    (1180.0, -135.0, 295.0, 123.0, 44.5, 16.0),
    (1180.0, 135.0, 295.0, 123.0, 44.5, 16.0),
]


def build_gear(M, g):
    for i, (xo, yo, zo, L, dia, wid) in enumerate(GEAR):
        pivot = P(xo, yo, zo)
        mnt = empty(f'mount_leg_orbiter_{i}', tuple(pivot), g)
        mnt.rotation_euler = (0.0, 0.0, pi / 2)
        node = empty(f'leg_orbiter_{i}', (0, 0, 0), mnt)
        mw = Matrix.Translation(pivot) @ Euler((0.0, 0.0, pi / 2)).to_matrix().to_4x4()
        loc = lambda p: mw.inverted() @ p
        axle = P(xo - L, yo, zo)
        strut('gear_strut', loc(pivot), loc(axle), (5.5 if i else 4.5) * IN, M['steel'], seg=12, parent=node)
        strut('gear_brace', loc(P(xo - L * 0.55, yo, zo + 4.0)), loc(P(xo - 4.0, yo, zo + 14.0)),
              2.5 * IN, M['steel'], seg=8, parent=node)
        for side in (-1, 1):
            c0 = P(xo - L, yo + side * 2.0, zo)
            c1 = P(xo - L, yo + side * (2.0 + wid), zo)
            tyre = strut('gear_tyre', loc(c0), loc(c1), dia / 2 * IN, M['black'], seg=20, parent=node)
            smooth(tyre, 40)
            strut('gear_hub', loc(c0 + (c1 - c0) * 0.1), loc(c1 + (c1 - c0) * 0.02), dia / 2 * 0.55 * IN,
                  M['alu'], seg=14, parent=node)
        strut('gear_axle', loc(P(xo - L, yo - 2.5, zo)), loc(P(xo - L, yo + 2.5, zo)), 3.0 * IN, M['steel'],
              seg=8, parent=node)


def build_orbiter(M, root):
    g = stage('orbiter', root)
    build_fuselage(M, g)
    build_wing(M, g)
    build_tail(M, g)
    build_pods(M, g)
    build_engines(M, g)
    build_body_flap(M, g)
    build_bay(M, g)
    build_gear(M, g)
    return g


# EXTERNAL TANK: 331 in across. LO2 tank ogive to XT 745 and barrel to 852.8; the
# intertank to 1123; the LH2 barrel to its aft ring frame at 2058 and the aft dome
# to the datum. The orbiter hangs on a bipod at XT 1129.9 and on the aft
# crossbeam at XT 2058; the solids' thrust goes into the intertank.
def build_et(M, root):
    g = stage('et', root)
    R = ET_D / 2 / IN                                  # in

    def y(xt):
        return (XT_AFT - xt) * IN

    prof = []
    # aft dome, ellipsoidal, 110 in high
    h_dome = XT_AFT - 2058.0
    for i in range(0, 9):
        a = (i / 8) * pi / 2
        prof.append((R * sin(a) * IN, y(XT_AFT - h_dome * (1 - cos(a)))))
    prof.append((R * IN, y(745.0)))
    # tangent ogive from XT 745 to a blunt tip at 322.5
    L_og = 745.0 - 322.5
    rho = (R * R + L_og * L_og) / (2 * R)
    for i in range(1, 15):
        x = L_og * i / 14
        r = sqrt(max(rho * rho - x * x, 0.0)) - rho + R
        prof.append((max(r, 3.0) * IN, y(745.0 - x)))
    prof.append((0.0, y(322.5)))
    body = revolve('et_body', prof, M['foam'], seg=64, parent=g)
    smooth(body, 35)
    # the lightning rod on the nose cone
    strut('et_spike', (0, 0, y(322.5) - 0.05), (0, 0, y(322.5) + 0.9), 0.025, M['alu'], seg=6, parent=g)
    # the nose cone's join and the LO2 barrel weld
    torus_z('et_cone_join', 0.62, 0.025, y(371.0), M['foam'], seg=24, minor=6, parent=g)

    # The intertank: the one stringered band, its foam a shade darker.
    it0, it1 = 852.8, 1123.0
    ring = cyl('intertank', R * IN * 1.004, R * IN * 1.004, y(it1), y(it0), M['foam'], seg=64, parent=g)
    smooth(ring, 35)
    n = 72
    for i in range(n):
        a = i / n * TAU
        box(f'stringer{i}', (0.05, 0.16, (it1 - it0) * IN * 0.98),
            (cos(a) * (R * IN * 1.004 + 0.022), sin(a) * (R * IN * 1.004 + 0.022), (y(it0) + y(it1)) / 2),
            M['foam'], rot=(0, 0, a), parent=g)
    for k, xt in enumerate((it0, it1)):
        torus_z(f'itband{k}', R * IN * 1.012, 0.06, y(xt), M['foam'], seg=64, minor=8, parent=g)

    # LO2 feedline: 17 in, down the LH2 tank's port side to the aft umbilical.
    fa = radians(-26.0)
    fr = (R + 16.0) * IN
    fl = cyl('feedline', 0.24, 0.24, y(2045.0), y(1110.0), M['foam'], seg=16, parent=g)
    fl.location = (sin(fa) * fr, -cos(fa) * fr, 0.0)
    smooth(fl, 40)
    for i in range(6):
        xt = 1180.0 + i * 160.0
        strut(f'fl_bracket{i}', (sin(fa) * R * IN, -cos(fa) * R * IN, y(xt)),
              (sin(fa) * fr, -cos(fa) * fr, y(xt)), 0.07, M['dirty'], seg=6, parent=g)
    # The GH2 pressurisation line and cable tray down the LH2 tank, starboard; the
    # LO2 tank's own line and tray down its crown from the nose, following the ogive.
    rho = (R * R + L_og * L_og) / (2 * R)

    def r_at(xt):
        if xt >= 745.0:
            return R
        x = 745.0 - xt
        return sqrt(max(rho * rho - x * x, 0.0)) - rho + R

    for k, (a, x0, x1, r) in enumerate(((radians(30.0), 1110.0, 2045.0, 0.09),
                                        (radians(12.0), 420.0, 852.0, 0.07))):
        xs = [x0 + (x1 - x0) * i / 12 for i in range(13)]
        for i, (xa, xb) in enumerate(zip(xs, xs[1:])):
            pa = Vector((sin(a) * (r_at(xa) + 6.0) * IN, -cos(a) * (r_at(xa) + 6.0) * IN, y(xa)))
            pb = Vector((sin(a) * (r_at(xb) + 6.0) * IN, -cos(a) * (r_at(xb) + 6.0) * IN, y(xb)))
            strut(f'pressline{k}_{i}', pa, pb, r, M['foam'], seg=8, parent=g)
            ta = Vector((sin(a + 0.04) * (r_at(xa) + 2.5) * IN, -cos(a + 0.04) * (r_at(xa) + 2.5) * IN, y(xa)))
            tb = Vector((sin(a + 0.04) * (r_at(xb) + 2.5) * IN, -cos(a + 0.04) * (r_at(xb) + 2.5) * IN, y(xb)))
            strut(f'cabletray{k}_{i}', ta, tb, 0.09, M['foam'], seg=4, parent=g)

    # The bipod the orbiter's nose hangs on (its foam ramp is what came off on
    # STS-107), and the aft crossbeam with the two 17 in umbilical plates.
    apex = PT(1119.0, 0.0, 336.5 - (400.0 - 279.0))
    for sgn in (-1, 1):
        foot = PT(1132.0, sgn * 40.0, sqrt(R * R - 40.0 * 40.0))
        strut(f'bipod{sgn}', foot, apex, 0.09, M['dirty'], seg=8, parent=g)
        box(f'bipod_ramp{sgn}', (0.5, 0.25, 0.9), tuple(foot + Vector((0, 0.08, 0.1))), M['foam'], parent=g)
    zbeam = R + 6.0
    strut('aft_crossbeam', PT(2058.0, -125.0, sqrt(R * R - 125.0 ** 2) + 4.0), PT(2058.0, 125.0, sqrt(R * R - 125.0 ** 2) + 4.0),
          0.16, M['dirty'], seg=10, parent=g)
    belly = 336.5 - (400.0 - 259.5)
    for sgn in (-1, 1):
        top = PT(2058.0, sgn * 48.0, belly)
        bot = PT(2058.0, sgn * 48.0, sqrt(R * R - 48.0 ** 2))
        b = box(f'umbilical{sgn}', (0.75, abs(top.y - bot.y) + 0.1, 0.75), tuple((top + bot) / 2), M['dirty'], parent=g)
        strut(f'aft_strut{sgn}', PT(2058.0, sgn * 110.0, sqrt(R * R - 110.0 ** 2)),
              PT(2050.0, sgn * 70.0, belly), 0.08, M['dirty'], seg=8, parent=g)
    torus_z('aft_ring', R * IN * 1.006, 0.05, y(2058.0), M['foam'], seg=64, minor=6, parent=g)
    # The solids' forward thrust fittings, out of the intertank.
    for sgn in (-1, 1):
        strut(f'srb_fwd_fit{sgn}', (sgn * R * IN, 0, y(987.0)), (sgn * (SRB_Y - SRB_D / 2 + 0.02), 0, y(987.0)),
              0.14, M['dirty'], seg=8, parent=g)
    return g


# SOLID ROCKET BOOSTERS, Ys ±250.5. Nose cap XB 200 → 326, frustum → 402 (the
# parachutes and four separation motors), forward skirt → 532, the four-segment
# motor case to 1819 with field joints at XB 851.5, 1171.5, 1491.5 and the tank
# attach ring at 1511, then the aft skirt, flaring to 212 in at its foot.
def build_srb(M, root):
    g = stage('srb', root)
    r = SRB_D / 2

    def y(xb):
        return (XB_EXIT - xb) * IN

    # Each booster is a piece of its own (`piece_srb_i`, port first), nozzle included,
    # because at separation the two fly apart on their own paths.
    for side in (-1, 1):
        b = empty(f'piece_srb_{0 if side < 0 else 1}', (side * SRB_Y, 0, 0), g)
        # Aft skirt, carrying the whole stack on four hold-down posts.
        sk = cyl(f'skirt{side}', 106.0 * IN, r, y(1958.0), y(1819.0), M['white'], seg=48, parent=b)
        finish(sk, 0.02, 2, 45)
        disc(f'skirt_floor{side}', 106.0 * IN, y(1958.0), M['soot'], seg=48, parent=b)
        for k in range(4):
            a = pi / 4 + k * pi / 2
            box(f'holddown{side}{k}', (0.5, 0.5, 0.6),
                (cos(a) * 98.0 * IN, sin(a) * 98.0 * IN, y(1958.0) + 0.25), M['dirty'], parent=b)
        # The nozzle hangs on a pivot (plumes parent to parts.gimbals). The RSRM
        # vectors 8°, the stack's only control until the SSMEs have authority. Its
        # throat sits up inside the case, as the real submerged nozzle's does.
        exd = S['srb']['engine']['exitD']
        L_bell = exd / 2 * 2.6
        piv = empty(f'gimbal_srb_{0 if side < 0 else 1}', (0, 0, L_bell), b)
        nz = bell(f'srbnoz{side}', exd, M['nozzle'], ratio=7.7, chamber=False, seg=40, parent=piv)
        finish(nz, 0.015, 2, 50)

        # Motor case, its field joints and the tank attach ring.
        body = cyl(f'case{side}', r, r, y(1819.0), y(532.0), M['white'], seg=56, parent=b)
        finish(body, 0.02, 2, 40)
        for k, xb in enumerate((851.5, 1171.5, 1491.5)):
            j = cyl(f'joint{side}{k}', r * 1.012, r * 1.012, y(xb + 9.0), y(xb - 9.0), M['dirty'], seg=56, parent=b)
            smooth(j, 30)
        for k, xb in enumerate((1650.0, 1735.0)):
            torus_z(f'stiffener{side}{k}', r * 1.01, 0.035, y(xb), M['white'], seg=56, minor=6, parent=b)
        eta = cyl(f'eta_ring{side}', r * 1.03, r * 1.03, y(1517.0), y(1505.0), M['dirty'], seg=56,
                  parent=b, t0=(-0.75 if side < 0 else 0.25) * pi, t1=(0.75 if side < 0 else 1.75) * pi)
        smooth(eta, 30)
        # Three struts to the tank's aft ring: upper, diagonal, lower.
        inner = -side
        for k, (dz, dx) in enumerate(((0.55, 0.0), (0.0, -0.25), (-0.55, 0.0))):
            strut(f'eta_strut{side}{k}', (inner * r * 1.02, dz, y(1511.0)),
                  (inner * (r + 0.35), dz * 0.6, y(1511.0) + dx), 0.06, M['dirty'], seg=6, parent=b)
        # Systems tunnel: the cable raceway down the outboard side.
        tun = box(f'tunnel{side}', (0.32, 0.22, (1819.0 - 540.0) * IN),
                  (side * r * 0.99, 0, (y(540.0) + y(1819.0)) / 2), M['dirty'], parent=b)
        finish(tun, 0.015, 2, 40)

        # Forward skirt, frustum and nose cap. The frustum carries the drogue and
        # main parachutes and comes off separately, as does the cap before it, so
        # each is a node of its own (`frustum_srb_i`, `nosecap_srb_i`).
        fs = cyl(f'fwdskirt{side}', r, r, y(532.0), y(402.0), M['white'], seg=48, parent=b)
        i = 0 if side < 0 else 1
        fn = empty(f'frustum_srb_{i}', (0, 0, 0), b)
        cn = empty(f'nosecap_srb_{i}', (0, 0, 0), b)
        r_fr = 54.0 * IN
        fr = cyl(f'frustum{side}', r, r_fr, y(402.0), y(326.0), M['white'], seg=48, parent=fn)
        finish(fr, 0.02, 2, 45)
        # Separation motors: four in the frustum and four on the aft skirt, all on the
        # side facing the tank. They fire forward, inboard and toward the orbiter at 40°
        # to the axis and 20° off the inboard line (TM X-64967 fig. 1), so the push
        # takes the booster aft, outboard and under the wing (Separation.exhaust_dir).
        c40, s40, c20, s20 = cos(radians(40)), sin(radians(40)), cos(radians(20)), sin(radians(20))
        ex = Vector((-side * s40 * c20, -s40 * s20, c40))
        az = atan2(-s20, -side * c20)
        for k in range(4):
            ar = r - (r - r_fr) * (402.0 - 390.0) / 76.0
            a = az + (k % 2 - 0.5) * 0.18
            port(f'bsm_fwd{side}{k}', Vector((cos(a) * ar, sin(a) * ar, y(390.0) + (k // 2 - 0.5) * 0.32)),
                 ex, 0.09, 0.15, M['black'], fn)
            sr = r + (106.0 * IN - r) * (1884.5 - 1819.0) / 139.0
            a = az + (k - 1.5) * 0.1355
            port(f'bsm_aft{side}{k}', Vector((cos(a) * sr, sin(a) * sr, y(1884.5))), ex, 0.09, 0.15, M['black'], b)
        cap = ogive(f'cap{side}', y(200.0) - y(326.0), r_fr * 2, M['white'], seg=48, parent=cn, z0=y(326.0))
        finish(cap, 0.02, 2, 45)
        # The forward attach fitting on the skirt: the booster's thrust goes into the
        # tank's intertank here, not at the aft struts.
        strut(f'fwd_attach{side}', (inner * r, 0, y(444.0)), (inner * (r + 0.3), 0, y(444.0)),
              0.13, M['dirty'], seg=8, parent=b)
    return g


def build_shuttle(M):
    root = empty('Shuttle', (0, 0, 0))
    build_srb(M, root)
    build_et(M, root)
    build_orbiter(M, root)


build('shuttle', build_shuttle)
