#!/usr/bin/env python3
"""Build sim/flight/sky_ms.gd: the flight sky's scattering coefficients and multiple-
scattering tables for Earth, Mars and Titan.

    python3 tools/build_sky_ms.py

Hillaire (2020), "A Scalable and Production Ready Sky and Atmosphere Rendering
Technique", §5.5: at each height and sun cosine, second-order light gathered over the
sphere with an isotropic phase, L2, and the fraction f_ms that one more isotropic
scattering returns; every higher order is the geometric series, Ψ = L2 / (1 − f_ms).
The flight sky adds σ_s(y)·Ψ(h(y), μ_s(y)) at each view sample. Earth is Bruneton's
2017 atmosphere in a 96 km shell, ground albedo 0.3. Mars and Titan carry wavelength-
dependent aerosol (dust, haze): its own extinction, single-scattering albedo and
Henyey–Greenstein g per primary (docs/physics/sky.md#mars-and-titan). Pure Python,
a few minutes.
"""
import math
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "sim" / "flight" / "sky_ms.gd"
# Per body: radius, Rayleigh and aerosol scale heights, the shell's top, Rayleigh β,
# aerosol scattering and extinction β and its g per primary (680, 550, 440 nm), ozone,
# ground albedo.
BODIES = {
    "earth": dict(R=6.371e6, HR=8000.0, HM=1200.0, TOP=12.0 * 8000.0,
                  BETA_R=(5.802e-6, 13.558e-6, 33.1e-6), BETA_M=(3.996e-6,) * 3, BETA_M_EXT=(4.44e-6,) * 3,
                  G=(0.8,) * 3, BETA_O=(0.650e-6, 1.881e-6, 0.085e-6), ALBEDO=0.3),
    # CO₂ at 610 Pa and 210 K scatters 2.5× air per molecule at 0.83% of Earth's number
    # density. Dust: τ 0.5 well mixed to 11.1 km, single-scattering albedo 0.976/0.935/0.64
    # (red absorbs least, after Wolff et al. 2009). Henyey–Greenstein has no diffraction
    # peak, so g rising to 0.80 in the blue stands in for the narrower forward peak of
    # ~1.5 µm grains at short wavelengths, which makes the blue sunset.
    "mars": dict(R=3.3895e6, HR=11100.0, HM=11100.0, TOP=12.0 * 11100.0,
                 BETA_R=(1.20e-7, 2.80e-7, 6.83e-7),
                 BETA_M=(0.976 * 4.40e-5, 0.935 * 4.50e-5, 0.64 * 4.62e-5), BETA_M_EXT=(4.40e-5, 4.50e-5, 4.62e-5),
                 G=(0.62, 0.68, 0.80), BETA_O=(0.0, 0.0, 0.0), ALBEDO=0.25),
    # N₂ at 1.467 bar and 93.7 K: 4.45× Earth's number density, H ≈ 20.6 km. Haze: τ
    # 2.0/3.0/4.5 with a 65 km scale height, albedo 0.92/0.85/0.65 and g ≈ 0.6 (after
    # Tomasko et al. 2005, Huygens DISR); the shell reaches 520 km.
    "titan": dict(R=2.5747e6, HR=20600.0, HM=65000.0, TOP=520000.0,
                  BETA_R=(2.58e-5, 6.03e-5, 1.47e-4),
                  BETA_M=(0.92 * 2.0 / 65000.0, 0.85 * 3.0 / 65000.0, 0.65 * 4.5 / 65000.0),
                  BETA_M_EXT=(2.0 / 65000.0, 3.0 / 65000.0, 4.5 / 65000.0),
                  G=(0.65, 0.62, 0.58), BETA_O=(0.0, 0.0, 0.0), ALBEDO=0.15),
}
B = BODIES["earth"]
N_MU, N_H = 32, 32
N_DIR, N_STEP, N_SUN = 64, 24, 12
# The shader's single scattering, for the gain that keeps the noon zenith calibrated.
SS_STEPS, SS_SUN = 16, 6
GAIN_SS = 15.0
CAL_SUN_ELEV = 60.0


def dens(z):
    z = max(z, 0.0)
    return math.exp(-z / B["HR"]), math.exp(-z / B["HM"]), max(1.0 - abs(z - 25000.0) / 15000.0, 0.0)


def extinction(p):
    r, m, o = dens(math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2) - B["R"])
    return ([B["BETA_R"][c] * r + B["BETA_M_EXT"][c] * m + B["BETA_O"][c] * o for c in range(3)],
            [B["BETA_R"][c] * r + B["BETA_M"][c] * m for c in range(3)])


def ray_shell(p, d, radius):
    b = p[0] * d[0] + p[1] * d[1] + p[2] * d[2]
    c = p[0] ** 2 + p[1] ** 2 + p[2] ** 2 - radius * radius
    disc = b * b - c
    if disc < 0.0:
        return None
    s = math.sqrt(disc)
    return -b - s, -b + s


def sun_trans(p, s, steps=N_SUN, quadratic=False):
    g = ray_shell(p, s, B["R"])
    if g is not None and g[0] > 0.0:
        return (0.0, 0.0, 0.0)
    t1 = ray_shell(p, s, B["R"] + B["TOP"])[1]
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
    R, TOP, ALBEDO = B["R"], B["R"] + B["TOP"], B["ALBEDO"]
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
    return (v * v) * B["TOP"]


def sample_psi(table, h, mu_s):
    u = min(max(mu_s * 0.5 + 0.5, 0.0), 1.0) * (N_MU - 1)
    v = math.sqrt(min(max(h / B["TOP"], 0.0), 1.0)) * (N_H - 1)
    i0, j0 = int(u), int(v)
    i1, j1 = min(i0 + 1, N_MU - 1), min(j0 + 1, N_H - 1)
    fu, fv = u - i0, v - j0
    out = []
    for c in range(3):
        a = table[j0][i0][c] * (1 - fu) + table[j0][i1][c] * fu
        b = table[j1][i0][c] * (1 - fu) + table[j1][i1][c] * fu
        out.append(a * (1 - fv) + b * fv)
    return out


def radiance(table, d, sun_elev, with_ms, sun_az=0.0):
    """The shader's radiance from the ground along unit direction d (without its gain)."""
    R, TOP = B["R"], B["R"] + B["TOP"]
    s = (math.cos(math.radians(sun_elev)) * math.cos(sun_az), math.sin(math.radians(sun_elev)),
         math.cos(math.radians(sun_elev)) * math.sin(sun_az))
    o = (0.0, R, 0.0)
    t1 = ray_shell(o, d, TOP)[1]
    mu = s[0] * d[0] + s[1] * d[1] + s[2] * d[2]
    pr = 3.0 / (16.0 * math.pi) * (1.0 + mu * mu)
    pm = [(1.0 - g * g) / (4.0 * math.pi * max(1.0 + g * g - 2.0 * g * mu, 1e-4) ** 1.5) for g in B["G"]]
    tau = [0.0, 0.0, 0.0]
    L = [0.0, 0.0, 0.0]
    prev = 0.0
    for i in range(1, SS_STEPS + 1):
        u = i / SS_STEPS
        f = u * u
        tm = t1 * 0.5 * (f + prev)
        ds = t1 * (f - prev)
        prev = f
        p = (d[0] * tm, R + d[1] * tm, d[2] * tm)
        r, m, oz = dens(math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2) - R)
        e = [B["BETA_R"][c] * r + B["BETA_M_EXT"][c] * m + B["BETA_O"][c] * oz for c in range(3)]
        ts = sun_trans(p, s, SS_SUN, True)
        rp = math.sqrt(p[0] ** 2 + p[1] ** 2 + p[2] ** 2)
        ms = sample_psi(table, rp - R, (p[0] * s[0] + p[1] * s[1] + p[2] * s[2]) / rp) if with_ms else [0.0] * 3
        for c in range(3):
            tr = math.exp(-(tau[c] + 0.5 * e[c] * ds))
            L[c] += tr * (ts[c] * (B["BETA_R"][c] * r * pr + B["BETA_M"][c] * m * pm[c])
                          + (B["BETA_R"][c] * r + B["BETA_M"][c] * m) * ms[c]) * ds
            tau[c] += e[c] * ds
    return L


def zenith(table, sun_elev, with_ms):
    return radiance(table, (0.0, 1.0, 0.0), sun_elev, with_ms)


def build(name):
    global B
    B = BODIES[name]
    dirs = directions(N_DIR)
    table = []
    for j in range(N_H):
        h = lut_height(j / (N_H - 1))
        table.append([psi(h, i / (N_MU - 1) * 2.0 - 1.0, dirs) for i in range(N_MU)])
    return table


def flat(table):
    # Below float32's normal range a value is 0 on the GPU anyway.
    return ", ".join("%.5g" % (x if x > 1e-30 else 0.0) for row in table for cell in row for x in cell)


def main():
    tables = {name: build(name) for name in BODIES}
    global B
    B = BODIES["earth"]
    table = tables["earth"]
    noon_ss = zenith(table, CAL_SUN_ELEV, False)[1]
    noon_ms = zenith(table, CAL_SUN_ELEV, True)[1]
    gain = GAIN_SS * noon_ss / noon_ms
    report = []
    for elev in (60.0, 10.0, 0.0, -3.0, -6.0):
        ss, ms = zenith(table, elev, False), zenith(table, elev, True)
        report.append("#   sun %+5.1f°: zenith G %.3e single, ×%.2f with multiple scattering" % (elev, ss[1], ms[1] / max(ss[1], 1e-30)))
    # Mars and Titan: the noon zenith's colour, and the sky 5° from a setting sun
    # against the sky opposite it.
    for name in ("mars", "titan"):
        B = BODIES[name]
        t = tables[name]
        z = zenith(t, 60.0, True)
        el = 2.0
        near = radiance(t, (math.cos(math.radians(el + 5.0)), math.sin(math.radians(el + 5.0)), 0.0), el, True)
        away = radiance(t, (-math.cos(math.radians(20.0)), math.sin(math.radians(20.0)), 0.0), el, True)
        report.append("#   %s: noon zenith RGB %.3e %.3e %.3e (B/R %.2f); sun 2° up: 5° from it B/R %.2f, opposite B/R %.2f"
                      % (name, z[0], z[1], z[2], z[2] / z[0], near[2] / near[0], away[2] / away[0]))
    coeffs = []
    for name, b in BODIES.items():
        coeffs.append('\t"%s": {"R": %r, "HR": %r, "HM": %r, "top": %r, "betaR": Vector3%r, "betaM": Vector3%r, '
                      '"betaMExt": Vector3%r, "g": Vector3%r, "betaO": Vector3%r},'
                      % (name, b["R"], b["HR"], b["HM"], b["TOP"], tuple(b["BETA_R"]), tuple(b["BETA_M"]),
                         tuple(b["BETA_M_EXT"]), tuple(b["G"]), tuple(b["BETA_O"])))
    OUT.write_text(f'''class_name SkyMS
extends RefCounted

# The flight sky's atmospheres and their multiple scattering, Ψ(h, μ_s) per R, G, B
# primary, from tools/build_sky_ms.py (Hillaire 2020 §5.5; generated, do not edit). Rows
# are height h = v²·top for v in [0, 1]; columns the sun cosine μ_s in [−1, 1]. From
# the ground, single scattering and the factor multiple scattering adds:
{chr(10).join(report)}

const N_MU := {N_MU}
const N_H := {N_H}
## The sky's gain with Ψ added: Earth's noon zenith (sun {CAL_SUN_ELEV:.0f}° up) as bright as
## single scattering at a gain of {GAIN_SS:g}. One gain for every body, so their skies
## keep their physical ratios.
const GAIN := {gain:.4f}
## Scattering coefficients per body (m⁻¹ and m), as sky_dome.gdshader takes them.
const ATMOS := {{
{chr(10).join(coeffs)}
}}
const PSI := [{flat(tables["earth"])}]
const PSI_MARS := [{flat(tables["mars"])}]
const PSI_TITAN := [{flat(tables["titan"])}]

static var _tex := {{}}

## A body's table as an N_MU × N_H RGBF texture, built once.
static func texture(body: String = "earth") -> ImageTexture:
	if not _tex.has(body):
		var data: Array = {{"earth": PSI, "mars": PSI_MARS, "titan": PSI_TITAN}}[body]
		var img := Image.create_from_data(N_MU, N_H, false, Image.FORMAT_RGBF, PackedFloat32Array(data).to_byte_array())
		_tex[body] = ImageTexture.create_from_image(img)
	return _tex[body]
''')
    print("\n".join(report))
    print("gain", gain, "->", OUT)


if __name__ == "__main__":
    main()
