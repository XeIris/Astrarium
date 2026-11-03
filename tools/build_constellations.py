#!/usr/bin/env python3
"""Build assets/sky/constellations.json: stick figures, names and IAU boundaries.

    python3 tools/build_constellations.py path/to/heasarc_bsc5p.tdat.gz path/to/constellations.bounds.json

- The stick figures are this project's own (FIGURES below, MIT like the rest of the
  code): chains of stars by Bayer letter ("alf", "the2"), Flamsteed number ("58") or
  HR number ("HR1713"), joined by "-"; "bet.Tau" names a star of another
  constellation. A Bayer letter without its superscript means the brightest of that
  letter. Each star is resolved in the Yale Bright Star Catalogue (the BSC5P table
  tools/build_starcat.py reads), which also gives its J2000 position and proper
  motion.
- The boundaries are the IAU's (Delporte 1930) as CDS catalogue VI/49 (Davenhall &
  Leggett 1989) gives them precessed to J2000, from d3-celestial's
  data/constellations.bounds.json (github.com/ofrohn/d3-celestial, BSD-3, © 2015 Olaf
  Frohn): GeoJSON polygons of vertices, longitude = RA in degrees. Their edges are
  arcs of B1875 parallels and meridians, which are not great circles at J2000, so
  each edge is filled in the B1875 frame (IAU 1976 precession, Lieske et al. 1977)
  at ≤ 1° steps and carried back.
- Each name sits on the constellation's own figure star nearest the mean direction
  of each of its boundary polygons (two for Serpens): a boundary that wraps around
  another constellation, as Draco's does round Ursa Minor, has its middle outside
  itself.

Output: {"figures": {abbr: {"name", "lines": [[ra, dec, μα cos δ, μδ] × 2 flattened],
"labels": [[ra, dec], ...]}}, "bounds": [{"c": abbr, "p": [[ra, dec], ...]}]}, degrees
and mas/yr.
"""
import json
import math
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_starcat  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "assets" / "sky" / "constellations.json"

NAMES = {
    "And": "Andromeda", "Ant": "Antlia", "Aps": "Apus", "Aqr": "Aquarius", "Aql": "Aquila", "Ara": "Ara",
    "Ari": "Aries", "Aur": "Auriga", "Boo": "Boötes", "Cae": "Caelum", "Cam": "Camelopardalis", "Cnc": "Cancer",
    "CVn": "Canes Venatici", "CMa": "Canis Major", "CMi": "Canis Minor", "Cap": "Capricornus", "Car": "Carina",
    "Cas": "Cassiopeia", "Cen": "Centaurus", "Cep": "Cepheus", "Cet": "Cetus", "Cha": "Chamaeleon",
    "Cir": "Circinus", "Col": "Columba", "Com": "Coma Berenices", "CrA": "Corona Australis",
    "CrB": "Corona Borealis", "Crv": "Corvus", "Crt": "Crater", "Cru": "Crux", "Cyg": "Cygnus",
    "Del": "Delphinus", "Dor": "Dorado", "Dra": "Draco", "Equ": "Equuleus", "Eri": "Eridanus", "For": "Fornax",
    "Gem": "Gemini", "Gru": "Grus", "Her": "Hercules", "Hor": "Horologium", "Hya": "Hydra", "Hyi": "Hydrus",
    "Ind": "Indus", "Lac": "Lacerta", "Leo": "Leo", "LMi": "Leo Minor", "Lep": "Lepus", "Lib": "Libra",
    "Lup": "Lupus", "Lyn": "Lynx", "Lyr": "Lyra", "Men": "Mensa", "Mic": "Microscopium", "Mon": "Monoceros",
    "Mus": "Musca", "Nor": "Norma", "Oct": "Octans", "Oph": "Ophiuchus", "Ori": "Orion", "Pav": "Pavo",
    "Peg": "Pegasus", "Per": "Perseus", "Phe": "Phoenix", "Pic": "Pictor", "Psc": "Pisces",
    "PsA": "Piscis Austrinus", "Pup": "Puppis", "Pyx": "Pyxis", "Ret": "Reticulum", "Sge": "Sagitta",
    "Sgr": "Sagittarius", "Sco": "Scorpius", "Scl": "Sculptor", "Sct": "Scutum", "Ser": "Serpens",
    "Sex": "Sextans", "Tau": "Taurus", "Tel": "Telescopium", "Tri": "Triangulum",
    "TrA": "Triangulum Australe", "Tuc": "Tucana", "UMa": "Ursa Major", "UMi": "Ursa Minor", "Vel": "Vela",
    "Vir": "Virgo", "Vol": "Volans", "Vul": "Vulpecula",
}

FIGURES = {
    "And": ["alf-del-bet-gam", "bet-mu-nu"],
    "Ant": ["eps-alf-iot"],
    "Aps": ["alf-del-bet-gam-del"],
    "Aqr": ["eps-bet-alf-gam-zet-eta", "alf-the-lam-del"],
    "Aql": ["gam-alf-bet", "alf-del-lam", "del-zet", "del-eta-the"],
    "Ara": ["the-alf-bet-gam-del", "bet-zet-eta"],
    "Ari": ["41-alf-bet-gam"],
    "Aur": ["alf-bet-the-bet.Tau-iot-alf", "alf-eps-zet-eta"],
    "Boo": ["alf-eps-del-bet-gam-rho-alf", "alf-eta", "alf-zet"],
    "Cae": ["del-alf-gam", "alf-bet"],
    "Cam": ["bet-alf-gam", "bet-7"],
    "Cnc": ["alf-del-gam-iot", "del-bet"],
    "CVn": ["alf-bet"],
    "CMa": ["bet-alf-omi2-del-eta", "del-eps", "alf-iot-gam"],
    "CMi": ["alf-bet"],
    "Cap": ["alf-bet-psi-ome-zet-del-gam-iot-the-alf"],
    "Car": ["alf-chi-eps-iot-the", "eps-bet-ome-the"],
    "Cas": ["eps-del-gam-alf-bet"],
    "Cen": ["alf-bet-eps-zet-mu-nu-the-iot", "eps-gam-del", "zet-eta-kap"],
    "Cep": ["alf-bet-gam-iot-zet-alf", "zet-eps-del"],
    "Cet": ["alf-gam-del-omi-zet-tau-bet-iot-eta-the-zet"],
    "Cha": ["alf-gam-bet-del-alf"],
    "Cir": ["bet-alf-gam"],
    "Col": ["eps-alf-bet-eta", "bet-gam-del"],
    "Com": ["alf-bet-gam"],
    "CrA": ["eps-gam-alf-bet-del-zet"],
    "CrB": ["the-bet-alf-gam-del-eps-iot"],
    "Crv": ["alf-eps-gam-del-bet-eps"],
    "Crt": ["alf-bet-gam-zet-eta", "gam-del-alf", "del-eps-the"],
    "Cru": ["alf-gam", "bet-del"],
    "Cyg": ["alf-gam-eta-bet", "del-gam-eps-zet"],
    "Del": ["eps-bet-alf-gam-del-bet"],
    "Dor": ["gam-alf-zet-bet-del"],
    "Dra": ["lam-kap-alf-iot-the-eta-zet-del-xi-nu-bet-gam-xi"],
    "Equ": ["alf-bet-del-gam-alf"],
    "Eri": ["bet-ome-mu-nu-omi1-gam-pi-del-eps-eta", "eta-tau3-tau4-tau5-tau6-tau9-ups2-the-iot-kap-chi-alf"],
    "For": ["alf-bet-nu"],
    "Gem": ["alf-tau-eps-mu-eta", "tau-iot-ups-bet", "ups-del-zet-gam", "eps-nu", "del-lam-xi"],
    "Gru": ["gam-lam-mu1-del1-bet-eps-zet", "alf-bet"],
    "Her": ["eps-zet-eta-pi-eps", "zet-bet-gam", "eps-del-alf", "pi-the-iot", "eta-sig-tau-phi-chi"],
    "Hor": ["alf-iot-eta-zet-mu-lam-bet"],
    "Hya": ["del-sig-eta-rho-eps-del", "zet-eps", "zet-the-iot-alf-ups1-lam-mu-nu-xi-gam-pi"],
    "Hyi": ["alf-bet-gam-alf"],
    "Ind": ["alf-the-del", "alf-bet"],
    "Lac": ["bet-alf-4-5-2-6-1"],
    "Leo": ["alf-eta-gam-del-bet-the-alf", "gam-zet-mu-eps"],
    "LMi": ["46-bet-21"],
    "Lep": ["eps-bet-alf-mu", "alf-zet-eta", "bet-gam-del"],
    "Lib": ["sig-alf-bet-gam-alf"],
    "Lup": ["alf-bet-del-gam-eta", "alf-zet"],
    "Lyn": ["alf-38-31-21-15-2"],
    "Lyr": ["alf-eps-zet-alf", "zet-del-gam-bet-zet"],
    "Men": ["alf-gam-eta-bet"],
    "Mic": ["the1-alf-gam-eps"],
    "Mon": ["alf-del-bet-gam", "del-eps"],
    "Mus": ["lam-eps-alf-bet-del-gam-alf"],
    "Nor": ["gam2-eps-eta-del-gam2"],
    "Oct": ["nu-bet-del-nu"],
    "Oph": ["alf-kap-zet-eta-bet-alf", "kap-del-eps"],
    "Ori": ["lam-alf", "lam-gam", "alf-zet-eps-del-gam", "zet-kap", "del-bet", "alf-mu-nu-xi-chi1",
            "gam-pi3", "pi1-pi2-pi3-pi4-pi5-pi6"],
    "Pav": ["alf-bet-gam", "bet-del-zet", "del-eta"],
    "Peg": ["alf-bet-alf.And-gam-alf", "alf-xi-zet-the-eps", "bet-mu-lam-iot-kap", "bet-eta"],
    "Per": ["eta-gam-alf-del-eps-xi-zet", "alf-bet-rho"],
    "Phe": ["eps-alf-bet-gam-del", "bet-zet"],
    "Pic": ["alf-gam-bet"],
    "PsA": ["alf-del-gam-bet-iot-mu-eps-alf"],
    "Psc": ["eta-omi-alf-nu-mu-zet-eps-del-ome", "ome-iot-the-gam-kap-lam-iot"],
    "Pup": ["xi-rho-zet-pi-nu", "pi-sig", "nu-tau"],
    "Pyx": ["bet-alf-gam"],
    "Ret": ["alf-bet-del-eps-alf"],
    "Sge": ["alf-del-gam", "bet-del"],
    "Sgr": ["gam-del-eps-gam", "del-lam-phi-del", "phi-sig-tau-zet-phi", "zet-eps"],
    "Sco": ["nu-bet-del-pi-rho", "del-sig-alf-tau-eps-mu1-zet2-eta-the-iot1-kap-lam-ups"],
    "Scl": ["alf-del-gam-bet"],
    "Sct": ["alf-bet-del-gam-alf"],
    "Ser": ["gam-kap-bet-gam", "bet-del-alf-eps-mu", "xi-eta-the"],
    "Sex": ["gam-alf-bet"],
    "Tau": ["bet-eps-del-gam-the2-alf-zet", "gam-lam"],
    "Tel": ["eps-alf-zet"],
    "Tri": ["alf-bet-gam-alf"],
    "TrA": ["alf-bet-gam-alf"],
    "Tuc": ["alf-gam-bet-zet-eps-gam"],
    "UMa": ["eta-zet-eps-del-alf-bet-gam-del", "gam-chi-psi-mu-lam", "chi-nu-xi", "alf-ups-the-iot"],
    "UMi": ["alf-del-eps-zet-bet-gam-eta-zet"],
    "Vel": ["gam-lam-mu-phi-kap-del-gam"],
    "Vir": ["eps-del-gam-eta-bet", "del-zet-alf"],
    "Vol": ["alf-bet-eps-alf", "eps-del-gam-zet"],
    "Vul": ["1-alf-13"],
}

# BSC5P's "alt_name" field: optional Flamsteed number, optional Bayer letter with an
# optional superscript, constellation; e.g. "58Alp Ori", "Alp1Cen", "46    LMi".
NAME = re.compile(r"^\s*(\d+)?\s*([A-Z][a-z]{1,2})?\s*(\d)?\s*([A-Z][A-Za-z]{2})\s*$")


def index(rows):
    """designation → star, with every star as {hr, ra, dec, v, pm}."""
    by = {}
    for r in rows:
        ra, dec, v = (build_starcat.number(r.get(k)) for k in ("ra", "dec", "vmag"))
        if math.isnan(ra) or math.isnan(dec):
            continue
        star = {"hr": int(build_starcat.number(r.get("hr"))), "ra": ra, "dec": dec,
                "v": 99.0 if math.isnan(v) else v, "pm": build_starcat.motion(r)}
        by[f"HR{star['hr']}"] = star
        m = NAME.match(r.get("alt_name") or "")
        if not m:
            continue
        flam, greek, sup, con = m.groups()
        if flam:
            by[f"{flam}.{con}"] = star
        if greek:
            g = {"alp": "alf"}.get(greek.lower(), greek.lower())
            for key in ([f"{g}{sup}.{con}"] if sup else []) + [f"{g}.{con}"]:
                # A bare letter is the brightest of its superscripts.
                if key not in by or by[key]["v"] > star["v"]:
                    by[key] = star
    return by


def resolve(by, token, con):
    t = token if "." in token else f"{token}.{con}"
    name, c = t.split(".")
    return by.get(f"HR{name[2:]}" if name.startswith("HR") else f"{name}.{c}")


def _unit(ra, dec):
    a, d = math.radians(ra), math.radians(dec)
    return (math.cos(d) * math.cos(a), math.cos(d) * math.sin(a), math.sin(d))


def _radec(v):
    return math.degrees(math.atan2(v[1], v[0])) % 360.0, math.degrees(math.asin(max(-1.0, min(1.0, v[2]))))


def _precession_1875():
    """J2000 → mean equator and equinox of B1875 (IAU 1976 angles, Lieske et al. 1977)."""
    t = (2405889.258550475 - 2451545.0) / 36525.0
    a = math.radians(1.0 / 3600.0)
    zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t ** 3) * a
    z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t ** 3) * a
    th = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t ** 3) * a
    cz, sz, cZ, sZ, ct, st = math.cos(zeta), math.sin(zeta), math.cos(z), math.sin(z), math.cos(th), math.sin(th)
    return ((cZ * ct * cz - sZ * sz, -cZ * ct * sz - sZ * cz, -cZ * st),
            (sZ * ct * cz + cZ * sz, -sZ * ct * sz + cZ * cz, -sZ * st),
            (st * cz, -st * sz, ct))


def _mul(m, v, transpose=False):
    if transpose:
        return tuple(m[0][i] * v[0] + m[1][i] * v[1] + m[2][i] * v[2] for i in range(3))
    return tuple(r[0] * v[0] + r[1] * v[1] + r[2] * v[2] for r in m)


def boundaries(path):
    """[(abbr, [[ra°, dec°], ...])], one closed polygon each, filled along B1875 arcs."""
    p = _precession_1875()
    out = []
    for f in json.loads(Path(path).read_text())["features"]:
        abbr, g = f["id"], f["geometry"]
        if abbr not in NAMES:
            sys.exit(f"build_constellations: unknown constellation {abbr!r} in {path}")
        for ring in ([g["coordinates"][0]] if g["type"] == "Polygon" else [poly[0] for poly in g["coordinates"]]):
            old = [_radec(_mul(p, _unit(ra % 360.0, dec))) for ra, dec in ring]
            pts = []
            for (ra0, d0), (ra1, d1) in zip(old, old[1:] + old[:1]):
                dra = (ra1 - ra0 + 180.0) % 360.0 - 180.0
                n = max(1, int(math.ceil(max(abs(dra), abs(d1 - d0)))))
                for k in range(n):
                    ra, dec = _radec(_mul(p, _unit(ra0 + dra * k / n, d0 + (d1 - d0) * k / n), True))
                    pts.append([round(ra, 4), round(dec, 4)])
            out.append((abbr, pts))
    return out


def centre(points):
    x = y = z = 0.0
    for ra, dec in points:
        a, d = math.radians(ra), math.radians(dec)
        x += math.cos(d) * math.cos(a); y += math.cos(d) * math.sin(a); z += math.sin(d)
    n = math.sqrt(x * x + y * y + z * z)
    return [round(math.degrees(math.atan2(y, x)) % 360.0, 4), round(math.degrees(math.asin(z / n)), 4)]


def nearest(stars, at):
    """The star of `stars` closest to `at` ([ra°, dec°]), as [ra°, dec°]; `at` without stars."""
    if not stars:
        return at
    u = _unit(*at)
    s = max(stars, key=lambda s: sum(a * b for a, b in zip(_unit(s["ra"], s["dec"]), u)))
    return [round(s["ra"], 4), round(s["dec"], 4)]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    by = index(build_starcat.table(sys.argv[1]))
    bounds = boundaries(sys.argv[2])
    missing, figures, segments = [], {}, 0
    for con, chains in FIGURES.items():
        lines, own = [], []
        for chain in chains:
            stars = [resolve(by, t, con) for t in chain.split("-")]
            own += [s for t, s in zip(chain.split("-"), stars) if s and "." not in t]
            for t, s in zip(chain.split("-"), stars):
                if s is None:
                    missing.append(f"{con}: {t}")
            for a, b in zip(stars, stars[1:]):
                if a and b:
                    lines.append([round(a["ra"], 5), round(a["dec"], 5), *a["pm"], round(b["ra"], 5), round(b["dec"], 5), *b["pm"]])
        segments += len(lines)
        figures[con] = {"name": NAMES[con], "lines": lines,
                        "labels": [nearest(own, centre(p)) for c, p in bounds if c == con]}
    if missing:
        sys.exit("build_constellations: unresolved stars:\n  " + "\n  ".join(missing))
    if set(FIGURES) != set(NAMES) or {c for c, _ in bounds} != set(NAMES):
        sys.exit("build_constellations: expected all 88 constellations in the figures and the boundaries")
    OUT.write_text(json.dumps({"figures": figures, "bounds": [{"c": c, "p": p} for c, p in bounds]},
                              separators=(",", ":"), ensure_ascii=False))
    print(f"build_constellations: 88 constellations, {segments} figure segments, "
          f"{len(bounds)} boundary polygons of {sum(len(p) for _, p in bounds)} points -> {OUT}")


if __name__ == "__main__":
    main()
