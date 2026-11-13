#!/usr/bin/env python3
"""Show that a check rejects broken code: apply each mutation in place, run the check
that should catch it, require a failure, and restore the file. A mutation the check
passes is a hole in the check. Run on a clean tree; files are restored byte for byte
even on an interrupt.

    python3 tools/mutationcheck.py [--godot PATH] [--only NAME[,NAME]] [--list]
"""
import argparse
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent

GALAXYCHECK = ["--headless", "--script", "res://tools/galaxycheck.gd", "--", "quick=1"]
ENCOUNTERCHECK = ["--headless", "--script", "res://tools/encountercheck.gd"]
GALAXYLOOK = ["--always-on-top", "--resolution", "1280x720", "res://tools/galaxylookcheck.tscn"]
SOAK_JOIN = ["--always-on-top", "--resolution", "1280x720", "--", "eval=_soak_check", "soak=join", "rounds=3"]
COURSECHECK = ["--always-on-top", "--resolution", "1280x720", "res://tools/coursecheck.tscn", "--", "only=galaxies/localgroup"]

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
    "glow-gain": ("shaders/galaxy/galaxy_glow.gdshaderinc", "vec3 col = (disc + sph * uSphereCol) * uGain;",
                  "vec3 col = (disc + sph * uSphereCol) * uGain * 1.1;", GALAXYLOOK, "the glow's brightness by 10 %"),
    "glow-midpoint-attenuation": ("shaders/galaxy/galaxy_glow.gdshaderinc",
                                  "vec3 a = mix(trans * (vec3(1.0) - 0.5 * kc), (trans - t_next) / max(kc, vec3(1e-6)), step(vec3(1e-4), kc)) * len;",
                                  "vec3 a = trans * exp(-0.5 * kc) * len;", GALAXYLOOK,
                                  "a step's light attenuated at its midpoint, not by its mean over the step"),
    "sphere-ignores-dust": ("shaders/galaxy/galaxy_glow.gdshaderinc", "\treturn mix(tv[i], tv[i + 1], x - float(i));",
                            "\treturn 0.0;", GALAXYLOOK, "the spheroid's light inside the disc box unabsorbed"),
    "lattice-off-centre": ("sim/galaxy/gal_visual.gd", "var half := (SPAN - 1) / 2", "var half := (SPAN - 1) / 2 - 2",
                           GALAXYLOOK, "the star lattice not centred on the camera"),
    "star-flux-4pi": ("shaders/galaxy/galaxy_stars.gdshader", "float flux = ms.w * Y / (12.566371 * max(d * d, 1e-12));",
                      "float flux = ms.w * Y / (6.2831853 * max(d * d, 1e-12));", GALAXYLOOK, "a star's flux over 2π, not 4π"),
    "glow-no-handover": ("shaders/galaxy/galaxy_glow.gdshaderinc", "float near = (t < uRes ? faint : 1.0) * step(uInner, t);",
                         "float near = step(uInner, t);", GALAXYLOOK, "the disc's glow not giving up the drawn stars' light"),
    "join-no-giving-up": ("shaders/galaxy/galaxy_glow.gdshaderinc", "col = max(col - uCatGain * cat_map(uv), vec3(0.0));",
                          "col = max(col - 0.0 * uCatGain * cat_map(uv), vec3(0.0));", GALAXYLOOK,
                          "the glow keeping the real far stars' light, so it is counted twice"),
    "lattice-no-hole": ("shaders/galaxy/galaxy_stars.gdshader", "bool real = uHole.w > 0.0 && length(rel - uHole.xyz) < uHole.w;",
                        "bool real = false;", GALAXYLOOK, "procedural stars drawn among the real ones"),
    "sun-frame-mirrored": ("sim/galaxy/gal_neighbourhood.gd", "var ez := Vector3(sin(phi), 0.0, -cos(phi))",
                           "var ez := Vector3(-sin(phi), 0.0, cos(phi))", GALAXYCHECK, "the real stars mirrored across the Sun's orbit"),
    "near-cut-off-model": ("sim/galaxy/gal_neighbourhood.gd", "const M_V_RESOLVED := 8.541", "const M_V_RESOLVED := 9.0",
                           GALAXYCHECK, "the real stars cut at a limit other than the model's resolved one"),
    "far-map-leaks": ("sim/galaxy/gal_neighbourhood.gd", "out[yy * MAP_W + x] += v * kb[k]", "out[yy * MAP_W + x] += v * kb[k] * 1.01",
                      GALAXYCHECK, "the far stars' light map not holding their flux"),
    "mw-light-from-mass": ("sim/galaxy/gal_models.gd", "const MW_DISC_LIGHT := 0.596", "const MW_DISC_LIGHT := 1.0",
                           GALAXYCHECK, "the Milky Way's light from its mass and the population's M/L, not its measured column"),
    "far-map-narrow": ("sim/galaxy/gal_neighbourhood.gd", "const SMOOTH_DEG := 12.0", "const SMOOTH_DEG := 4.0",
                       GALAXYCHECK, "the far stars' light smoothed too narrowly, darkening the sky around bright groups"),
    "landmark-frame-mirrored": ("sim/galaxy/gal_landmarks.gd", "return Vector3(u.dot(c), u.dot(n), -u.dot(y))",
                                "return Vector3(u.dot(c), u.dot(n), u.dot(y))", GALAXYCHECK, "landmarks placed through a mirrored galactic frame"),
    "landmark-never-arrives": ("sim/galaxy/galaxy_scene.gd", "	stage.cam.track_point(DVec3.from_v3(GalLandmarks.position(lm, model, t_myr)), dt)",
                               "	pass", GALAXYLOOK, "a flight that never reaches its landmark"),
    "landmark-arm-static": ("sim/galaxy/gal_landmarks.gd", "if p.kind == GalPattern.Kind.SPIRAL: turn = GalPattern.angle(p, t_myr) - float(p.angle0)",
                            "if p.kind == GalPattern.Kind.SPIRAL: turn = 0.0", GALAXYCHECK, "the arm's landmark left behind as the pattern turns"),
    "neighbour-camera-unturned": ("sim/galaxy/galaxy_scene.gd", "		var cl := b.inverse() * -rel", "		var cl := -rel",
                                  GALAXYLOOK, "a neighbour's camera not turned into its own frame"),
    "neighbour-light-from-mass": ("sim/galaxy/gal_models.gd", "		for l in light: l.visible = float(l.visible) * k", "		pass",
                                  GALAXYCHECK, "a neighbour drawn from its stellar mass where its luminosity was measured"),
    "dust-kappa-off": ("sim/galaxy/gal_models.gd", "const DUST_KAPPA_V := 5.492e-6", "const DUST_KAPPA_V := 8.55e-6",
                       GALAXYCHECK, "dust opacity taken from absorption alone, or any other wrong κ"),
    "type-share-off": ("sim/galaxy/gal_models.gd", "		var mass := float(pp[0]) * lv /", "		var mass := float(pp[0]) * 1.2 * lv /",
                       GALAXYCHECK, "a galaxy's parts not adding up to its measured light"),
    "thin-dust-skipped": ("shaders/galaxy/galaxy_glow.gdshaderinc", "float sc = max(min(uDisc.z, uThin), 0.005)", "float sc = max(uDisc.z, 0.05)",
                          GALAXYLOOK, "the glow's sampling stepping over a 20 pc dust ring"),
    "lanes-downstream": ("sim/galaxy/gal_visual.gd", "var beta := _arm_beta(i, ra)[0] - dtheta", "var beta := _arm_beta(i, ra)[0] + dtheta",
                         GALAXYCHECK, "M51's dust lanes downstream of their arms"),
    "m51-old-disc-smooth": ("sim/galaxy/gal_visual.gd", "var cc := _contrast(R) - 1.0", "var cc := 0.0",
                            GALAXYCHECK, "M51's old disc without its measured arm contrast"),
    "m51-young-share": ("sim/galaxy/gal_visual.gd", "var fy := share * pres if mean > 1e-12 else 0.0", "var fy := pres if mean > 1e-12 else 0.0",
                        GALAXYCHECK, "all of M51's young light gathered into the arms"),
    "hii-dig-kept": ("sim/galaxy/gal_hii.gd", "var l_regions := l_all * (1.0 - float(spec.dig))", "var l_regions := l_all",
                     GALAXYCHECK, "the diffuse gas's Hα put in M51's H II regions"),
    "hii-unclustered": ("sim/galaxy/gal_hii.gd", "for c in maxi(_poisson(3.0, rng), 1):", "for c in 1:",
                        GALAXYCHECK, "M51's H II regions without their hierarchy"),
    "hii-undimmed": ("shaders/galaxy/galaxy_hii.gdshader", "vec3 att = exp(-dust_to_camera(c, -rel / dist, dist) * uExt);", "vec3 att = vec3(1.0);",
                     GALAXYLOOK, "M51's H II regions not dimmed by its dust"),
    "m87-extinction-kept": ("sim/galaxy/gal_models.gd", "lnI.append(-0.4 * (float(row[1]) - M87_AV - 4.83", "lnI.append(-0.4 * (float(row[1]) - 4.83",
                            GALAXYCHECK, "M87's profile left dimmed by the Galaxy's dust"),
    "m87-halo-cut": ("sim/galaxy/gal_models.gd", "	var rmax := 3.0 * R[R.size() - 1]", "	var rmax := R[R.size() - 1]",
                     GALAXYCHECK, "M87's halo cut off at its last measured point"),
    "lmc-bar-unsolved": ("sim/galaxy/gal_visual.gd", "	var f := 0.5 * (lo + hi)\n	for j in n:", "	var f := 0.0\n	for j in n:",
                         GALAXYCHECK, "the LMC's bar given no light"),
    "lmc-bar-sky-angle": ("sim/galaxy/gal_models.gd", "	return fposmod(atan2(-ca, cb), PI)", "	return deg_to_rad(float(spec.pa) - pa_deg)",
                          GALAXYCHECK, "the LMC's bar angle taken from the sky without deprojecting"),
    "ism-mean-kept": ("sim/galaxy/gal_ism.gd", "		ld += -b * n.x * n.x + 0.5 * log(1.0 + 2.0 * b)", "		ld += -b * n.x * n.x",
                      GALAXYCHECK, "the medium's dust sheets without their mean divided out"),
    "ism-norm-dropped": ("sim/galaxy/gal_ism.gd", "	return Vector2(exp(ld) * feather(fth, Vector2(q0.x, q0.z), foot) / nm.x, exp(ly) / nm.y)", "	return Vector2(exp(ld) * feather(fth, Vector2(q0.x, q0.z), foot), exp(ly))",
                         GALAXYCHECK, "the medium without each galaxy's realised mean divided out"),
    "ism-unbounded-shear": ("sim/galaxy/gal_ism.gd", "			th -= clampf((om[i + 1] - om[i]) * life, -lim, lim)", "			th -= (om[i + 1] - om[i]) * life",
                            GALAXYCHECK, "the medium sheared past one shear time"),
    "ism-gpu-unsheared": ("shaders/galaxy/gal_model.gdshaderinc", "		float ang = -mix(texelFetch(uISMTurn, ivec2(i, o), 0).r, texelFetch(uISMTurn, ivec2(i + 1, o), 0).r, f);", "		float ang = 0.0;",
                          GALAXYLOOK, "the GPU's medium not sheared as the CPU's is"),
    "ism-gpu-off": ("shaders/galaxy/galaxy_glow.gdshaderinc", "		vec2 ism = outside ? gal_ism(o + d * tc, tc * uPix) : vec2(1.0);", "		vec2 ism = vec2(1.0);",
                    GALAXYLOOK, "the glow drawn without the medium the CPU has"),
    "feathers-gpu-off": ("shaders/galaxy/gal_model.gdshaderinc", "	return vec2(exp(ld) * gal_feather(q.xz, foot), exp(ly))", "	return vec2(exp(ld), exp(ly))",
                         GALAXYLOOK, "the GPU's dust without the feathers the CPU has"),
    "feathers-mean-lost": ("sim/galaxy/gal_ism.gd", "	g /= sig * sqrt(TAU)", "	g /= sig",
                           GALAXYCHECK, "feathers that do not keep the dust's mean"),
    "glow-inside-spread": ("shaders/galaxy/galaxy_glow.gdshaderinc", "			sc = min(sc, SC_INSIDE);\n			tc = tbx.x;", "			sc = sc;",
                           GALAXYLOOK, "from inside the disc, the glow's samples spread evenly over the box's chord"),
    "m51-population-colours": ("sim/galaxy/gal_visual.gd", "	var measured: Dictionary = model.get(\"colours\", {})", "	var measured: Dictionary = {}",
                               GALAXYLOOK, "M51 drawn in its populations' colours rather than its measured ones"),
    "hii-lines-undimmed": ("sim/galaxy/gal_hii.gd", "		lines[i] = seen * (drawn[i] / ERG_LSUN)", "		lines[i] = line * (drawn[i] / ERG_LSUN)",
                           GALAXYCHECK, "M51's H II lines not dimmed by their own clouds"),
    "local-dust-added": ("sim/galaxy/gal_visual.gd", "	return (1.0 - w) * m + w * GalLocalDust.density(local_dust, s)",
                         "	return m + w * GalLocalDust.density(local_dust, s)",
                         GALAXYCHECK, "the measured dust added to the model's around the Sun instead of replacing it"),
    "local-dust-gpu-added": ("shaders/galaxy/galaxy_glow.gdshaderinc", "			keep = 1.0 - w;\n", "			keep = 1.0;\n",
                             GALAXYLOOK, "the glow keeping the model's dust inside the measured dust's shells"),
    "local-dust-mirrored": ("sim/galaxy/gal_local_dust.gd", "var l := fposmod(atan2(-u.z, u.x), TAU) / TAU", "var l := fposmod(atan2(u.z, u.x), TAU) / TAU",
                            GALAXYCHECK, "the measured dust read mirrored in galactic longitude"),
    "local-dust-units": ("sim/galaxy/gal_local_dust.gd", "const TAU_PER_E := 2.67 / 1.0857 * 1000.0", "const TAU_PER_E := 2.8 / 1.0857 * 1000.0",
                         GALAXYCHECK, "the map's E taken to A_V at 2.8 rather than ZGR23's 2.67"),
    "local-dust-shell-gpu": ("shaders/galaxy/gal_model.gdshaderinc", "texture(uLD, vec3(uv, float(k))).r", "texture(uLD, vec3(uv, float(k + 1))).r",
                             GALAXYLOOK, "the shader reading each shell's density from the next shell out"),
    "local-dust-not-applied": ("sim/galaxy/gal_visual.gd", "			apply_local_dust(GalLocalDust.bake())", "			pass",
                               GALAXYCHECK, "the Milky Way built without the measured dust around the Sun"),
    "m33-arms-smooth": ("sim/galaxy/gal_visual.gd", "	if thin_map.has(\"a2\"): share = _share_for_a2(img, sum, cnt, px)", "	if thin_map.has(\"a2\"): share = 0.0",
                        GALAXYCHECK, "M33's young light not gathered into its arms"),
    "orbits-no-friction": ("sim/galaxy/gal_orbits.gd", "	if friction: _friction(p, v, acc)", "	pass",
                           ENCOUNTERCHECK, "galaxies passing without dynamical friction"),
    "orbits-lnL-power": ("sim/galaxy/gal_orbits.gd", "float(lam[0]) * log(r / (float(lam[1]) * a[j]))", "pow(maxf(log(r / (float(lam[1]) * a[j])), 0.0), float(lam[0]))",
                         ENCOUNTERCHECK, "the Coulomb logarithm read as (ln r/Ca)^α"),
    "encounter-disc-flat": ("sim/galaxy/gal_encounter.gd", "		var fy := f * ly * s / zb", "		var fy := f * ly",
                            ENCOUNTERCHECK, "the encounter's disc pulling as a sphere across its plane"),
    "eddington-radius-linear": ("sim/galaxy/gal_eddington.gd", "		var s := sqrt(rng.randf()) * umax", "		var s := rng.randf() * umax",
                                ENCOUNTERCHECK, "a live halo's radii drawn as if M(<r)/M were r/(r + a)"),
    "eddington-no-disc": ("sim/galaxy/gal_eddington.gd", "			s += float(p[1]) * ((1.0 - (1.0 + y) * exp(-y)) / x + exp(-y) / rd)", "			s += 0.0",
                          ENCOUNTERCHECK, "a halo's speeds set without the disc's pull"),
    "live-open-wide": ("sim/galaxy/gal_live.gd", "	var ropen := 2.0 * half / _theta + sqrt(dx * dx + dy * dy + dz * dz)", "	var ropen := 2.0 * half / _theta",
                       ENCOUNTERCHECK, "the GDScript tree opening cells without the centre-of-mass offset"),
    "live-kick-whole": ("sim/galaxy/gal_live.gd", "	var h := 0.5 * step_dt\n", "	var h := step_dt\n",
                        ENCOUNTERCHECK, "the GDScript live kernel kicking a whole step each half"),
    "disc-no-drift": ("sim/galaxy/gal_encounter.gd", "	var vphi2 := v2 - sp * sp + sr * sr + drift", "	var vphi2 := v2",
                      ENCOUNTERCHECK, "a warm disc rotating at the circular speed, without asymmetric drift"),
    "switch-halo-at-rest": ("sim/galaxy/gal_encounter.gd", "[v[0] + hv[3 * q], v[1] + hv[3 * q + 1], v[2] + hv[3 * q + 2]]", "[hv[3 * q], hv[3 * q + 1], hv[3 * q + 2]]",
                            ENCOUNTERCHECK, "haloes going live at rest instead of with their galaxies"),
    "identikit-omega-ahead": ("sim/galaxy/gal_models.gd", "	var node := to_companion.rotated(z, -deg_to_rad(omega))", "	var node := to_companion.rotated(z, deg_to_rad(omega))",
                              ENCOUNTERCHECK, "the Antennae's discs turned with ω ahead of the companion instead of behind"),
    "antennae-view-zyx": ("sim/galaxy/gal_models.gd", "	var m := Basis(Vector3(1, 0, 0), deg_to_rad(v[0])) * Basis(Vector3(0, 1, 0), deg_to_rad(v[1])) * Basis(Vector3(0, 0, 1), deg_to_rad(v[2]))",
                          "	var m := Basis(Vector3(0, 0, 1), deg_to_rad(v[2])) * Basis(Vector3(0, 1, 0), deg_to_rad(v[1])) * Basis(Vector3(1, 0, 0), deg_to_rad(v[0]))",
                          ENCOUNTERCHECK, "the Antennae seen through the other Euler order"),
    "bh09-sigma-ratio": ("sim/galaxy/gal_encounter.gd", "		var mu := 1.0 + R / (R + qs)", "		var mu := 1.0",
                         ENCOUNTERCHECK, "Barnes & Hibbard's discs with σ_R = σ_z"),
    "nfw-taper-slope": ("sim/galaxy/gal_eddington.gd", "		beta = -1.0 - 2.0 * b / (b + a) + b / a", "		beta = -1.0 - 2.0 * b / (b + a)",
                        ENCOUNTERCHECK, "the halo's taper breaking its slope at b_h"),
    "chart-parts-copy": ("ui/widgets/rotation_chart.gd", "			parts[p.name] = curve", "			parts[p.name] = PackedVector2Array()",
                         GALAXYCHECK, "the rotation chart's parts left empty, as a packed array appended through a copy leaves them"),
    "lesson-landmark-typo": ("sim/lessons.gd", '"galaxy": {"landmark": "m33"}', '"galaxy": {"landmark": "m32"}',
                             COURSECHECK, "a lesson flying to a landmark the galaxy does not have"),
    "pro-retro-same-spin": ("sim/galaxy/gal_models.gd", '["Retrograde", 180.0, 0.0]', '["Retrograde", 0.0, 0.0]',
                            ENCOUNTERCHECK, "the retrograde disc spinning with the orbit after all"),
    "join-no-roll": ("main.gd", "	cam.roll = OrreryCamera.roll_onto(cam_basis, up)", "	cam.roll = 0.0",
                     SOAK_JOIN, "the Galaxy entered from the Solar System with its own up, the sky turned"),
    "companion-in-front": ("sim/galaxy/gal_landmarks.gd", "var rel := (cs[0] as Vector3) * float(spec.d) - (hs[0] as Vector3) * float(host.d)",
                           "var rel := (cs[0] as Vector3) * (2.0 * float(host.d) - float(spec.d)) - (hs[0] as Vector3) * float(host.d)",
                           GALAXYCHECK, "NGC 5195 placed in front of M51 rather than behind"),
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
        # A passing run prints "failures=0", for the course "COURSE …L …S 0E", for the soak an
        # empty failure list.
        passed = (" failures=0" in out or re.search(r"^COURSE \d+L \d+S 0E$", out, re.MULTILINE) is not None
                  or re.search(r"^SOAK FAILURES \[\]$", out, re.MULTILINE) is not None)
        failed = r.returncode != 0 or not passed
        fails = [l for l in out.splitlines() if l.startswith("FAIL") or "ERROR" in l][:3]
        known = name in KNOWN_MISSES
        print(f"MUTATION {name} {'caught' if failed else ('missed (known)' if known else 'MISSED')}: {what}")
        for l in fails: print("    " + l.strip())
        caught += failed == (not known)
    print(f"MUTATIONCHECK DONE as-expected={caught}/{len(names)} known-misses={len([n for n in names if n in KNOWN_MISSES])}")
    return 0 if caught == len(names) else 1


if __name__ == "__main__":
    sys.exit(main())
