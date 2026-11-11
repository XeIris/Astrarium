#!/usr/bin/env python3
"""Show that a check rejects broken code: apply each mutation in place, run the check
that should catch it, require a failure, and restore the file. A mutation the check
passes is a hole in the check. Run on a clean tree; files are restored byte for byte
even on an interrupt.

    python3 tools/mutationcheck.py [--godot PATH] [--only NAME[,NAME]] [--list]
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

GALAXYCHECK = ["--headless", "--script", "res://tools/galaxycheck.gd", "--", "quick=1"]
GALAXYLOOK = ["--always-on-top", "--resolution", "1280x720", "res://tools/galaxylookcheck.tscn"]

# name: (file, text, replacement, check arguments, what it breaks). KNOWN_MISSES are
# defects no check resolves yet; they are run and reported, and must stay missed or
# move into the table proper.
MUTATIONS = {
    "units-julian-year": ("sim/galaxy/gal_units.gd", "const KMS := 1000.0 * Rocketry.YR_S", "const KMS := 1000.0 * 31557600.0",
                          GALAXYCHECK, "km/s converted with a Julian year, not the one G is exact for"),
    "normalise-disc": ("sim/galaxy/gal_models.gd", "[0.05, 0.6, 0.35]", "[0.05, 0.65, 0.35]",
                       GALAXYCHECK, "the disc's share of the force at R0"),
    "mn-z-force": ("sim/galaxy/gal_potential.gd", "acc[k + 1] += f * y * s / zb", "acc[k + 1] += f * y",
                   GALAXYCHECK, "the Miyamoto–Nagai vertical force"),
    "kernel-z-force": ("sim/galaxy/gal_tracers.gd", "ay += f * y * sa / zb", "ay += f * y",
                       GALAXYCHECK, "the integrator's inlined disc force"),
    "bulge-table-slope": ("sim/galaxy/gal_potential.gd", "d[i] = 2.0 * TAU * p.amp", "d[i] = TAU * p.amp",
                          GALAXYCHECK, "the bulge mass table's derivative"),
    "half-kick": ("sim/galaxy/gal_tracers.gd", "vx += ax * dt; vy += ay * dt; vz += az * dt",
                  "vx += ax * h; vy += ay * h; vz += az * h", GALAXYCHECK, "a leapfrog kick of half a step"),
    "jeans-sign": ("sim/galaxy/gal_curve.gd", "(1.0 + k_nu * R[i] + k_vr * R[i])", "(1.0 - k_nu * R[i] + k_vr * R[i])",
                   GALAXYCHECK, "the Jeans equation's density term"),
    "no-giants": ("sim/galaxy/gal_population.gd", "	p.post_ms_light = lp / (ll + lp)", "	lp = 0.0\n	p.post_ms_light = lp / (ll + lp)",
                  GALAXYCHECK, "the light of stars past the main sequence"),
    "bolometric-colour": ("sim/galaxy/gal_population.gd", "		var c := visible(Stellar.effective_temp(m))\n		n += w",
                          "		var c := Stellar.blackbody_color(Stellar.effective_temp(m))\n		n += w",
                          GALAXYCHECK, "colours per visible light, not peak-normalised"),
    "linear-quantiles": ("sim/galaxy/gal_population.gd", "	return 1.0 - pow(10.0, -Q_DECADES * float(k) / 64.0)", "	return float(k) / 64.0",
                         GALAXYCHECK, "the mass table's top tail, sampled linearly in u"),
    "pattern-spiral-force": ("sim/galaxy/gal_pattern.gd", "var dPhi_dR := -A * f * S * (df_f * cg - g_R * sg + dS_S * cg)",
                             "var dPhi_dR := -A * f * S * (df_f * cg + g_R * sg + dS_S * cg)", GALAXYCHECK, "the spiral's radial force"),
    "fused-bar-gradient": ("sim/galaxy/gal_tracers.gd", "dh = 5.0 * rb3 / (r2 * r2 * r2)", "dh = 4.0 * rb3 / (r2 * r2 * r2)",
                           GALAXYCHECK, "the bar's force in the GDScript kernel only (the native one disagrees)"),
    "work-sign": ("sim/galaxy/gal_tracers.gd", "work[i] = w\n", "work[i] = -w\n",
                  GALAXYCHECK, "the work tally's sign"),
    "dust-arm-cutoff": ("sim/galaxy/gal_visual.gd", "if R > dust.rm else 1.0", "if R < dust.rm else 1.0",
                        GALAXYCHECK, "the dust arms cut off inside r_m rather than outside"),
    "young-normalisation": ("sim/galaxy/gal_visual.gd", "	young_k = _l_young / float(baked.integral)", "	young_k = _l_young / float(baked.integral) * 2.0",
                            GALAXYCHECK, "the young arms' brightness"),
    "glow-gain": ("shaders/galaxy/galaxy_glow.gdshader", "vec3 col = (disc + sph * uSphereCol) * uGain;",
                  "vec3 col = (disc + sph * uSphereCol) * uGain * 1.1;", GALAXYLOOK, "the glow's brightness by 10 %"),
    "glow-midpoint-attenuation": ("shaders/galaxy/galaxy_glow.gdshader",
                                  "vec3 att = mix(trans * (vec3(1.0) - 0.5 * kc), (trans - t_next) / max(kc, vec3(1e-6)), step(vec3(1e-4), kc));",
                                  "vec3 att = exp(-(tau + 0.5 * dk * ds) * uExt);", GALAXYLOOK,
                                  "a step's light attenuated at its midpoint, not by its mean over the step"),
    "sphere-ignores-dust": ("shaders/galaxy/galaxy_glow.gdshader", "\treturn mix(tv[i], tv[i + 1], x - float(i));",
                            "\treturn 0.0;", GALAXYLOOK, "the spheroid's light inside the disc box unabsorbed"),
    "lattice-off-centre": ("sim/galaxy/gal_visual.gd", "var half := (SPAN - 1) / 2", "var half := (SPAN - 1) / 2 - 2",
                           GALAXYLOOK, "the star lattice not centred on the camera"),
    "star-flux-4pi": ("shaders/galaxy/galaxy_stars.gdshader", "float flux = ms.w * Y / (12.566371 * max(d * d, 1e-12));",
                      "float flux = ms.w * Y / (6.2831853 * max(d * d, 1e-12));", GALAXYLOOK, "a star's flux over 2π, not 4π"),
    "glow-no-handover": ("shaders/galaxy/galaxy_glow.gdshader", "float near = (t < uRes ? faint : 1.0) * step(uInner, t);",
                         "float near = step(uInner, t);", GALAXYLOOK, "the disc's glow not giving up the drawn stars' light"),
    "join-no-giving-up": ("shaders/galaxy/galaxy_glow.gdshader", "col = max(col - uCatGain * texture(uCatMap, uv).rgb, vec3(0.0));",
                          "col = max(col - 0.0 * uCatGain * texture(uCatMap, uv).rgb, vec3(0.0));", GALAXYLOOK,
                          "the glow keeping the real far stars' light, so it is counted twice"),
    "lattice-no-hole": ("shaders/galaxy/galaxy_stars.gdshader", "bool real = uHole.w > 0.0 && length(rel - uHole.xyz) < uHole.w;",
                        "bool real = false;", GALAXYLOOK, "procedural stars drawn among the real ones"),
    "sun-frame-mirrored": ("sim/galaxy/gal_neighbourhood.gd", "var ez := Vector3(sin(phi), 0.0, -cos(phi))",
                           "var ez := Vector3(-sin(phi), 0.0, cos(phi))", GALAXYCHECK, "the real stars mirrored across the Sun's orbit"),
    "near-cut-off-model": ("sim/galaxy/gal_neighbourhood.gd", "const M_V_RESOLVED := 8.541", "const M_V_RESOLVED := 9.0",
                           GALAXYCHECK, "the real stars cut at a limit other than the model's resolved one"),
    "far-map-leaks": ("sim/galaxy/gal_neighbourhood.gd", "out[yy * MAP_W + x] += v * kb[k]", "out[yy * MAP_W + x] += v * kb[k] * 1.01",
                      GALAXYCHECK, "the far stars' light map not holding their flux"),
    "far-map-narrow": ("sim/galaxy/gal_neighbourhood.gd", "const SMOOTH_DEG := 12.0", "const SMOOTH_DEG := 4.0",
                       GALAXYCHECK, "the far stars' light smoothed too narrowly, darkening the sky around bright groups"),
}
KNOWN_MISSES = {
    # For σR/vc ≈ 0.16 the radial period changes by a few per cent across the energies
    # drawn, so dropping its weight reshapes the eccentric tail below the stationarity
    # test's noise (docs/physics/galaxies.md).
    "shu-no-period-weight": ("sim/galaxy/gal_tracers.gd", "if rng.randf() * t_cap <= o.t:", "if true:",
                             GALAXYCHECK, "the radial-period weight of Shu's distribution"),
}


def godot_path(value):
    for c in [value, shutil.which("godot"), "/Applications/Godot.app/Contents/MacOS/Godot"]:
        if c and Path(c).is_file():
            return c
    sys.exit("MUTATIONCHECK FAIL: no Godot; pass --godot")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", default=os.environ.get("GODOT"))
    ap.add_argument("--only")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    table = {**MUTATIONS, **KNOWN_MISSES}
    names = list(table) if not a.only else a.only.split(",")
    if a.list:
        for n in names: print(n, "-", table[n][4], "(known miss)" if n in KNOWN_MISSES else "")
        return 0
    godot = godot_path(a.godot)
    caught = 0
    for name in names:
        path, old, new, args, what = table[name]
        f = ROOT / path
        original = f.read_bytes()
        text = original.decode()
        if text.count(old) != 1:
            print(f"MUTATION {name} STALE: the text to break is not in {path} exactly once")
            continue
        try:
            f.write_text(text.replace(old, new))
            r = subprocess.run([godot, "--path", str(ROOT), *args], cwd=ROOT, capture_output=True, text=True, timeout=900)
        finally:
            f.write_bytes(original)
        assert f.read_bytes() == original
        out = r.stdout + r.stderr
        failed = r.returncode != 0 or " failures=0" not in out
        fails = [l for l in out.splitlines() if l.startswith("FAIL") or "ERROR" in l][:3]
        known = name in KNOWN_MISSES
        print(f"MUTATION {name} {'caught' if failed else ('missed (known)' if known else 'MISSED')}: {what}")
        for l in fails: print("    " + l.strip())
        caught += failed == (not known)
    print(f"MUTATIONCHECK DONE as-expected={caught}/{len(names)} known-misses={len([n for n in names if n in KNOWN_MISSES])}")
    return 0 if caught == len(names) else 1


if __name__ == "__main__":
    sys.exit(main())
