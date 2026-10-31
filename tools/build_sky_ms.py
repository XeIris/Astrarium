#!/usr/bin/env python3
"""Build sim/flight/sky_ms.gd: Earth's multiple-scattering table for the flight sky.

    python3 tools/build_sky_ms.py

Hillaire (2020), "A Scalable and Production Ready Sky and Atmosphere Rendering
Technique", §5.5: at each height and sun cosine, second-order light gathered over the
sphere with an isotropic phase, L2, and the fraction f_ms that one more isotropic
scattering returns; every higher order is the geometric series, Ψ = L2 / (1 − f_ms).
The flight sky adds σ_s(y)·Ψ(h(y), μ_s(y)) at each view sample. The atmosphere is the
sky dome's (shaders/flight/sky_dome.gdshader): Bruneton's 2017 coefficients, a 96 km
shell, ground albedo 0.3. Pure Python, about a minute.
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "sim" / "flight" / "sky_ms.gd"
R = 6.371e6
HR, HM = 8000.0, 1200.0
TOP = R + 12.0 * HR
BETA_R = (5.802e-6, 13.558e-6, 33.1e-6)
BETA_M, BETA_M_EXT = 3.996e-6, 4.44e-6
BETA_O = (0.650e-6, 1.881e-6, 0.085e-6)
ALBEDO = 0.3
N_MU, N_H = 32, 32
N_DIR, N_STEP, N_SUN = 64, 24, 12
# The shader's single scattering, for the gain that keeps the noon zenith calibrated.
SS_STEPS, SS_SUN = 16, 6
GAIN_SS = 15.0
CAL_SUN_ELEV = 60.0


def dens(z):
    z = max(z, 0.0)
    return math.exp(-z / HR), math.exp(-z / HM), max(1.0 - abs(z - 25000.0) / 15000.0, 0.0)


def extinction(p):
    r, m, o = dens(math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2) - R)
    return [BETA_R[c] * r + BETA_M_EXT * m + BETA_O[c] * o for c in range(3)], [BETA_R[c] * r + BETA_M * m for c in range(3)]


def ray_shell(p, d, radius):
    b = p[0] * d[0] + p[1] * d[1] + p[2] * d[2]
    c = p[0] ** 2 + p[1] ** 2 + p[2] ** 2 - radius * radius
    disc = b * b - c
    if disc < 0.0:
        return None
    s = math.sqrt(disc)
    return -b - s, -b + s


def sun_trans(p, s, steps=N_SUN, quadratic=False):
    g = ray_shell(p, s, R)
    if g is not None and g[0] > 0.0:
        return (0.0, 0.0, 0.0)
    t1 = ray_shell(p, s, TOP)[1]
    tau = [0.0, 0.0, 0.0]
    prev = 0.0
    for i in range(1, steps + 1):
        u = i / steps
        f = u * u if quadratic else u
        tm = t1 * 0.5 * (f + prev)
        ds = t1 * (f - prev)
        prev = f
        e, _ = extinction([p[k] + s[k] * tm for k in range(3)])
        for c in range(3):
            tau[c] += e[c] * ds
    return tuple(math.exp(-t) for t in tau)


def directions(n):
    out = []
    ga = math.pi * (3.0 - math.sqrt(5.0))
    for i in range(n):
        y = 1.0 - 2.0 * (i + 0.5) / n
        r = math.sqrt(1.0 - y * y)
        out.append((math.cos(ga * i) * r, y, math.sin(ga * i) * r))
    return out


def psi(h, mu_s, dirs):
    p = (0.0, R + h, 0.0)
    s = (math.sqrt(max(1.0 - mu_s * mu_s, 0.0)), mu_s, 0.0)
    pu = 1.0 / (4.0 * math.pi)
    l2 = [0.0, 0.0, 0.0]
    fms = [0.0, 0.0, 0.0]
    for d in dirs:
        top = ray_shell(p, d, TOP)
        t1 = top[1]
        ground = ray_shell(p, d, R)
        hit = ground is not None and ground[0] > 0.0
        if hit:
            t1 = ground[0]
        tr = [1.0, 1.0, 1.0]
        lp = [0.0, 0.0, 0.0]
        fp = [0.0, 0.0, 0.0]
        dt = t1 / N_STEP
        for i in range(N_STEP):
            tm = (i + 0.5) * dt
            y = [p[k] + d[k] * tm for k in range(3)]
            e, sc = extinction(y)
            ts = sun_trans(y, s)
            for c in range(3):
                step = math.exp(-e[c] * dt)
                # The step's in-scattering, integrated exactly over its own extinction.
                w = sc[c] * (1.0 - step) / max(e[c], 1e-12)
                lp[c] += tr[c] * w * ts[c] * pu
                fp[c] += tr[c] * w
                tr[c] *= step
        if hit:
            g = [p[k] + d[k] * t1 for k in range(3)]
            n = [g[k] / R for k in range(3)]
            cos_s = max(n[0] * s[0] + n[1] * s[1] + n[2] * s[2], 0.0)
            ts = sun_trans(g, s)
            for c in range(3):
                lp[c] += tr[c] * ts[c] * cos_s * ALBEDO / math.pi
        for c in range(3):
            l2[c] += lp[c] * pu * 4.0 * math.pi / len(dirs)
            fms[c] += fp[c] * pu * 4.0 * math.pi / len(dirs)
    return [l2[c] / (1.0 - fms[c]) for c in range(3)]


def lut_height(v):
    return (v * v) * (TOP - R)


def sample_psi(table, h, mu_s):
    u = min(max(mu_s * 0.5 + 0.5, 0.0), 1.0) * (N_MU - 1)
    v = math.sqrt(min(max(h / (TOP - R), 0.0), 1.0)) * (N_H - 1)
    i0, j0 = int(u), int(v)
    i1, j1 = min(i0 + 1, N_MU - 1), min(j0 + 1, N_H - 1)
    fu, fv = u - i0, v - j0
    out = []
    for c in range(3):
        a = table[j0][i0][c] * (1 - fu) + table[j0][i1][c] * fu
        b = table[j1][i0][c] * (1 - fu) + table[j1][i1][c] * fu
        out.append(a * (1 - fv) + b * fv)
    return out


def zenith(table, sun_elev, with_ms):
    """The shader's zenith radiance from sea level (without its gain)."""
    s = (math.cos(math.radians(sun_elev)), math.sin(math.radians(sun_elev)), 0.0)
    d = (0.0, 1.0, 0.0)
    o = (0.0, R, 0.0)
    t1 = TOP - R
    mu = s[1]
    pr = 3.0 / (16.0 * math.pi) * (1.0 + mu * mu)
    g = 0.8
    pm = (1.0 - g * g) / (4.0 * math.pi * max(1.0 + g * g - 2.0 * g * mu, 1e-4) ** 1.5)
    tau = [0.0, 0.0, 0.0]
    L = [0.0, 0.0, 0.0]
    prev = 0.0
    for i in range(1, SS_STEPS + 1):
        u = i / SS_STEPS
        f = u * u
        tm = t1 * 0.5 * (f + prev)
        ds = t1 * (f - prev)
        prev = f
        p = (0.0, R + tm, 0.0)
        r, m, oz = dens(tm)
        e = [BETA_R[c] * r + BETA_M_EXT * m + BETA_O[c] * oz for c in range(3)]
        ts = sun_trans(p, s, SS_SUN, True)
        ms = sample_psi(table, tm, mu) if with_ms else [0.0] * 3
        for c in range(3):
            tr = math.exp(-(tau[c] + 0.5 * e[c] * ds))
            L[c] += tr * (ts[c] * (BETA_R[c] * r * pr + BETA_M * m * pm) + (BETA_R[c] * r + BETA_M * m) * ms[c]) * ds
            tau[c] += e[c] * ds
    return L


def main():
    dirs = directions(N_DIR)
    table = []
    for j in range(N_H):
        h = lut_height(j / (N_H - 1))
        table.append([psi(h, i / (N_MU - 1) * 2.0 - 1.0, dirs) for i in range(N_MU)])
    noon_ss = zenith(table, CAL_SUN_ELEV, False)[1]
    noon_ms = zenith(table, CAL_SUN_ELEV, True)[1]
    gain = GAIN_SS * noon_ss / noon_ms
    report = []
    for elev in (60.0, 10.0, 0.0, -3.0, -6.0):
        ss, ms = zenith(table, elev, False), zenith(table, elev, True)
        report.append("#   sun %+5.1f°: zenith G %.3e single, ×%.2f with multiple scattering" % (elev, ss[1], ms[1] / max(ss[1], 1e-30)))
    # Below float32's normal range a value is 0 on the GPU anyway.
    flat = ", ".join("%.5g" % (x if x > 1e-30 else 0.0) for row in table for cell in row for x in cell)
    OUT.write_text(f'''class_name SkyMS
extends RefCounted

# Earth's multiple scattering for the flight sky, Ψ(h, μ_s) per R, G, B primary, from
# tools/build_sky_ms.py (Hillaire 2020 §5.5; generated, do not edit). Rows are height
# h = v²·96 km for v in [0, 1]; columns the sun cosine μ_s in [−1, 1]. Zenith radiance
# from sea level, single scattering and the factor multiple scattering adds:
{chr(10).join(report)}

const N_MU := {N_MU}
const N_H := {N_H}
## The sky's gain with Ψ added: the noon zenith (sun {CAL_SUN_ELEV:.0f}° up) as bright as
## single scattering at a gain of {GAIN_SS:g}.
const GAIN := {gain:.4f}
const PSI := [{flat}]

static var _tex: ImageTexture

## The table as an N_MU × N_H RGBF texture, built once.
static func texture() -> ImageTexture:
	if _tex == null:
		var img := Image.create_from_data(N_MU, N_H, false, Image.FORMAT_RGBF, PackedFloat32Array(PSI).to_byte_array())
		_tex = ImageTexture.create_from_image(img)
	return _tex
''')
    print("\n".join(report))
    print("gain", gain, "->", OUT)


if __name__ == "__main__":
    main()
