#!/usr/bin/env python3
"""Show that the checks reject broken code: apply each mutation in place, run the checks
that should catch it, require every one to fail, and restore the files. A mutation a
check passes is a hole in that check. First every check named must pass the unchanged
tree, or it would catch everything. Files are restored byte for byte, on an interrupt
or SIGTERM too (check.py sends one before it kills), and a run killed outright leaves a
journal that the next run restores first.

    python3 tools/mutationcheck.py [--godot PATH] [--only NAME|core|galaxy[,...]] [--checks NAME[,...]] [--list]

A mutation that edits native/ rebuilds the library with native/build.sh, then puts
native/bin back; the unchanged tree is then checked with a rebuilt library too, so that
a compiler differing from the committed build's cannot be what catches them.
--checks runs the named check.py checks against every selected mutation instead of
its own and reports each, to find what catches a new mutation.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import types

import check as runner

ROOT = Path(__file__).resolve().parent.parent
JOURNAL = ROOT / "tools/evidence/mutationcheck-journal.json"
NATIVE_BIN = "native/bin"

GALAXYCHECK = ["--headless", "--script", "res://tools/galaxycheck.gd", "--", "quick=1"]
ENCOUNTERCHECK = ["--headless", "--script", "res://tools/encountercheck.gd"]
GALAXYLOOK = ["--always-on-top", "--resolution", "1280x720", "res://tools/galaxylookcheck.tscn"]
SOAK_JOIN = ["--always-on-top", "--resolution", "1280x720", "--", "eval=_soak_check", "soak=join", "rounds=3"]
COURSECHECK = ["--always-on-top", "--resolution", "1280x720", "res://tools/coursecheck.tscn", "--", "only=galaxies/localgroup"]

# Two shapes. One edit: name: (file, text, replacement, Godot arguments, what it breaks).
# Several: name: ([(file, text, replacement), ...], [checks], what it breaks[, assertions]),
# where a check is a check.py name or Godot arguments; every check must fail, and each
# assertion must appear in one of their FAIL lines. KNOWN_MISSES are defects no check
# resolves yet; they are run and reported, and must stay missed or move into the table
# proper.
GALAXY = {
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
    # Both of the CPU's copies: the fused arm sampler's and _dust_arm's.
    "dust-arm-cutoff": ([("sim/galaxy/gal_visual.gd", "\t\tvar cut: float = exp(-pow((R - dust.rm) / dust.ra, 2.0)) if R > dust.rm else 1.0",
                          "\t\tvar cut: float = exp(-pow((R - dust.rm) / dust.ra, 2.0)) if R < dust.rm else 1.0"),
                         ("sim/galaxy/gal_visual.gd", "\n\tvar cut: float = exp(-pow((R - dust.rm) / dust.ra, 2.0)) if R > dust.rm else 1.0",
                          "\n\tvar cut: float = exp(-pow((R - dust.rm) / dust.ra, 2.0)) if R < dust.rm else 1.0")],
                        [GALAXYCHECK], "the dust arms cut off inside r_m rather than outside"),
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
    "local-grid-not-drawn": ("sim/galaxy/gal_visual.gd", "Vector4(half.x, half.y, half.z, 0.0 if levels.is_empty() else 1.0 - f)",
                             "Vector4(half.x, half.y, half.z, 0.0)", GALAXYLOOK, "the measured dust's grid left off the GPU away from the Sun"),
    "local-grid-mirrored": ("sim/galaxy/gal_local_dust.gd", "	var u := (s / (2.0 * half) + Vector3(0.5, 0.5, 0.5)) * Vector3(n) - Vector3(0.5, 0.5, 0.5)",
                            "	var u := (Vector3(s.x, s.y, -s.z) / (2.0 * half) + Vector3(0.5, 0.5, 0.5)) * Vector3(n) - Vector3(0.5, 0.5, 0.5)",
                            GALAXYCHECK, "the measured dust's grid read mirrored across the Galactic centre's line"),
    "local-grid-point-read": ("shaders/galaxy/galaxy_glow.gdshaderinc", "gal_disc_sample(o + d * t, foot,",
                              "gal_disc_sample(o + d * t, 0.0,", GALAXYLOOK, "the grid read at a point where a step stands for tens of pc"),
    "local-grid-weight-sharp": ("sim/galaxy/gal_local_dust.gd", "	return 1.0 - smoothstep(BLEND.x - 0.5 * foot, BLEND.y + 0.5 * foot, r)",
                                "	return 1.0 - smoothstep(BLEND.x, BLEND.y, r)", GALAXYLOOK,
                                "the CPU's grid weight at a point, not as the glow's jittered steps give it on average"),
    "local-grid-log-read": ("sim/galaxy/gal_local_dust.gd", "		for c in rho.size(): rho[c] = lut[raw[at + c]]",
                            "		for c in rho.size(): rho[c] = lut[raw[at + c]] * 0.94", GALAXYCHECK, "the grid losing 6 % of its dust, as a read in ln ρ does"),
    "dust-shares-overlap-gpu": ("shaders/galaxy/galaxy_glow.gdshaderinc", "		float kk = max(keep - wg, 0.0) * dk * gal_ism_dust(ism.x) + dg + rate;",
                                "		float kk = keep * ((1.0 - wg) * dk * gal_ism_dust(ism.x) + dg) + rate;", GALAXYLOOK,
                                "the shells' share taken from the grid's as well as the model's, as the fade lets the model back in"),
    "dust-shares-overlap": ("sim/galaxy/gal_local_dust.gd", "	return Vector3(maxf(1.0 - w_shell - w_grid, 0.0), w_shell, w_grid)",
                            "	return Vector3((1.0 - w_shell) * (1.0 - w_grid), w_shell, (1.0 - w_shell) * w_grid)", GALAXYCHECK,
                            "the model's dust kept beside the measured dust while the shells fade"),
    "glow-inside-beside-box": ("shaders/galaxy/galaxy_glow.gdshaderinc", "bool outside = abs(o.y) > uISMLayer.y || any(greaterThan(abs(o), uBox));",
                               "bool outside = abs(o.y) > uISMLayer.y;", GALAXYLOOK,
                               "a camera beside a galaxy's box, near its plane, marched as if inside it"),
    "ism-not-seen": ("sim/galaxy/gal_visual.gd", "	if pix > 0.0 and ism_ready and ism_enabled and t1 > t0 and outside:",
                     "	if pix > 0.0 and ism_ready and ism_enabled and t1 > t0 and outside and false:", GALAXYCHECK,
                     "the medium never applied to the CPU's march, as its check could not see"),
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
    "switch-halo-at-rest": ("sim/galaxy/gal_encounter.gd", "v[0] + hv[w], v[1] + hv[w + 1], v[2] + hv[w + 2], mass", "hv[w], hv[w + 1], hv[w + 2], mass",
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

PHYSICS = "sim/physics.gd"
NBODY = "native/nbody.c"


def twin(edits, native):
    """The same mistake in both kernels, so parity cannot catch it; only physics can."""
    return edits + native


T3 = [(PHYSICS, "var t3 := 3.5 * mu / r", "var t3 := -3.5 * mu / r")]
COEF = [(PHYSICS, "var coef := -4.0 * phi[i]", "var coef := -3.0 * phi[i]")]
KERNEL = [(PHYSICS, "\t\t\t\t\tkernel = G * dist / denominator", "\t\t\t\t\tkernel = G / denominator")]
YOSHIDA = [(PHYSICS, "const YOSHIDA_W1 := 1.3512071919596578", "const YOSHIDA_W1 := 1.35")]
TIDE_POWER = [(PHYSICS, "/ pow(r, 7.0)", "/ pow(r, 6.0)")]
TIDE_SIGN = [(PHYSICS, "var fr := -3.0 * A * rdot / r", "var fr := 3.0 * A * rdot / r")]
WIND = [(PHYSICS, "var dm := minf(b.wind_mdot * dt, 0.001 * b.mass)\n\t\tb.mass -= dm", "var dm := minf(b.wind_mdot * dt, 0.001 * b.mass)\n\t\tb.mass += dm")]
MERGER = [(PHYSICS, ".add_scaled_in(small.vel, small.mass)", "")]

# The orrery's physics. A "-twin" makes the same mistake in native/nbody.c as well.
CORE = {
    "g-one-percent": ([(PHYSICS, "const G := 4.0 * PI * PI", "const G := 4.0 * PI * PI * 1.01")], ["invariantcheck"],
                      "G a per cent off 4π², so it no longer carries GM☉ in the orrery's year", ["orrery G is GM☉"]),
    "softened-inverse-cube": (KERNEL, ["invariantcheck"], "softened pairs pulling as 1/r³ in the GDScript kernel",
                              ["force matches energy gradient"]),
    "softened-inverse-cube-twin": (twin(KERNEL, [(NBODY, "kernel = G * dist / denominator;", "kernel = G / denominator;")]),
                                   ["invariantcheck"], "softened pairs pulling as 1/r³ in both kernels",
                                   ["force matches energy gradient", "PSR B1913+16 periastron"]),
    "pn-response-sign": (T3, ["invariantcheck"], "the 1PN term in the other body's acceleration reversed, GDScript kernel",
                         ["force antisymmetry", "PSR B1913+16 gd 1PN energy"]),
    "pn-response-sign-twin": (twin(T3, [(NBODY, "double t3 = 3.5 * mu / r;", "double t3 = -3.5 * mu / r;")]), ["invariantcheck"],
                              "the 1PN term in the other body's acceleration reversed in both kernels",
                              ["force antisymmetry", "PSR B1913+16 periastron", "PSR B1913+16 native 1PN energy"]),
    "pn-potential-coefficient": (COEF, ["invariantcheck"], "the 1PN 4Φ term weighted 3, GDScript kernel",
                                 ["force antisymmetry", "PSR B1913+16 gd 1PN energy"]),
    "pn-potential-coefficient-twin": (twin(COEF, [(NBODY, "double coef = -4.0 * pn_phi[i]", "double coef = -3.0 * pn_phi[i]")]),
                                      ["invariantcheck", "sciencecheck"], "the 1PN 4Φ term weighted 3 in both kernels",
                                      ["Mercury's perihelion advances", "PSR B1913+16 periastron", "edu_mercury over 300 yr with 1PN on"]),
    "yoshida-weight": (YOSHIDA, ["numericalcheck"], "a Yoshida weight rounded to 1.35, so the step falls to second order, GDScript kernel",
                       ["phase converges with halved step"]),
    "yoshida-weight-twin": (twin(YOSHIDA, [(NBODY, "static const double YOSHIDA_W1 = 1.3512071919596578;", "static const double YOSHIDA_W1 = 1.35;"),
                                           (NBODY, "static const double YOSHIDA_W0 = 1.0 - 2.0 * 1.3512071919596578;",
                                            "static const double YOSHIDA_W0 = 1.0 - 2.0 * 1.35;")]),
                            ["numericalcheck", "sciencecheck"], "a Yoshida weight rounded to 1.35 in both kernels",
                            ["phase converges with halved step", "edu_mercury over 300 yr with 1PN off"]),
    "tide-power": (TIDE_POWER, ["secularcheck"], "the tidal force falling as r⁻⁶, GDScript kernel", ["against Hut's"]),
    "tide-power-twin": (twin(TIDE_POWER, [(NBODY, "/ pow(r, 7.0)", "/ pow(r, 6.0)")]), ["secularcheck"],
                        "the tidal force falling as r⁻⁶ in both kernels", ["against Hut's"]),
    "tide-radial-sign": (TIDE_SIGN, ["secularcheck"], "the tide's radial drag pushing, GDScript kernel", ["against Hut's"]),
    "tide-radial-sign-twin": (twin(TIDE_SIGN, [(NBODY, "double fr = -3.0 * A * rdot / r;", "double fr = 3.0 * A * rdot / r;")]),
                              ["secularcheck"], "the tide's radial drag pushing in both kernels", ["against Hut's"]),
    "wind-adds-mass": (WIND, ["secularcheck"], "a wind that adds mass, GDScript kernel", ["the wind took"]),
    "wind-adds-mass-twin": (twin(WIND, [(NBODY, "double dm = jmin(b[MDOT] * dt, 0.001 * b[MASS]);\n\t\tb[MASS] -= dm;",
                                         "double dm = jmin(b[MDOT] * dt, 0.001 * b[MASS]);\n\t\tb[MASS] += dm;")]),
                            ["secularcheck"], "a wind that adds mass in both kernels", ["the wind took"]),
    "merger-drops-momentum": (MERGER, ["invariantcheck"], "a merger keeping only the larger body's momentum, GDScript kernel",
                              ["direct collision", "gd collision"]),
    "merger-drops-momentum-twin": (twin(MERGER, [(NBODY, "vel[c] = (g[VX + c] * g[MASS] + s[VX + c] * s[MASS]) * invM;",
                                                  "vel[c] = (g[VX + c] * g[MASS]) * invM;")]),
                                   ["invariantcheck"], "a merger keeping only the larger body's momentum in both kernels",
                                   ["native collision"]),
    "schwarzschild-without-two": ([(PHYSICS, "return 2.0 * G * mass_sun / (C * C)", "return G * mass_sun / (C * C)")], ["invariantcheck"],
                                  "the Schwarzschild radius GM/c², half the horizon", ["cannot change physical horizon"]),
    "roche-coefficient": ([(PHYSICS, "return 2.44 * r_au * U.cbrt(rho_star / body_density)", "return 1.44 * r_au * U.cbrt(rho_star / body_density)")],
                          ["invariantcheck"], "the fluid Roche limit's 2.44 as 1.44, letting a world pass closer to the Trisolaris suns",
                          ["Roche limit of an Earth-density world", "contact is its Roche limit"]),
    "chandrasekhar-mass": ([("sim/structure.gd", '"chandrasekhar": 1.44', '"chandrasekhar": 1.6')], ["structureinputcheck"],
                           "white dwarfs supported past 1.44 M☉", ["Chandrasekhar event still detonates"]),
    "tov-mass": ([("sim/structure.gd", '"tov": 2.20', '"tov": 1.20')], ["sciencecheck"], "neutron stars collapsing at 1.2 M☉",
                 ["neutron star inside NICER's"]),
    "flight-gm-sun": ([("sim/flight/rocketry.gd", "const GM_SUN := 1.32712440018e20", "const GM_SUN := 1.32712440018e19")],
                      ["invariantcheck"], "flight's GM☉ a tenth of the orrery's", ["orrery G is GM☉"]),
}
GROUPS = {"core": list(CORE), "galaxy": list(GALAXY) + list(KNOWN_MISSES)}
TABLE = {**CORE, **GALAXY, **KNOWN_MISSES}
# What check.run_child reads. A stall shorter than check.py's own (90 s) judges a check a
# mutation hangs as rejecting it, before check.py stops this whole run as stalled.
OPTIONS = types.SimpleNamespace(godot=None, timeout=None, allow_macos_ca_error=False, stall=60)


def normal(entry):
    """(edits, checks, what, assertions), whichever table the entry is from."""
    if isinstance(entry[0], str):
        path, old, new, args, what = entry
        return [(path, old, new)], [args], what, ()
    edits, checks, what, *assertions = entry
    return edits, checks, what, tuple(assertions[0]) if assertions else ()


def put(path, data, mode=None):
    """Replace, never rewrite in place: macOS can kill a process that loads a signed
    library overwritten in place."""
    tmp = path.with_name(path.name + ".mutationcheck")
    tmp.write_bytes(data)
    os.chmod(tmp, mode if mode is not None else path.stat().st_mode)
    os.replace(tmp, path)


def snapshot(paths, native):
    files = {p: (ROOT / p).read_bytes() for p in paths}
    if native:
        files.update({f"{NATIVE_BIN}/{f.name}": f.read_bytes() for f in (ROOT / NATIVE_BIN).iterdir() if f.is_file()})
    return {p: (data, (ROOT / p).stat().st_mode) for p, data in files.items()}


def restore(saved, native):
    for p, (data, mode) in saved.items():
        f = ROOT / p
        if not f.is_file() or f.read_bytes() != data:
            put(f, data, mode)
    if native:
        for f in (ROOT / NATIVE_BIN).iterdir():
            if f.is_file() and f"{NATIVE_BIN}/{f.name}" not in saved:
                f.unlink()
    assert all((ROOT / p).read_bytes() == data for p, (data, _) in saved.items())


def write_journal(saved, native):
    JOURNAL.parent.mkdir(parents=True, exist_ok=True)
    body = {"native": native, "files": {p: [base64.b64encode(data).decode(), mode] for p, (data, mode) in saved.items()}}
    tmp = JOURNAL.with_suffix(".tmp")
    tmp.write_text(json.dumps(body))
    os.replace(tmp, JOURNAL)


def recover():
    """Put back what a run killed mid-mutation left behind."""
    if not JOURNAL.exists():
        return
    body = json.loads(JOURNAL.read_text())
    restore({p: (base64.b64decode(data), mode) for p, (data, mode) in body["files"].items()}, body["native"])
    JOURNAL.unlink()
    print(f"MUTATIONCHECK RESTORED {', '.join(body['files'])}, left mutated by an interrupted run", flush=True)


def interrupted(signum, frame):
    raise KeyboardInterrupt


FAILURE = re.compile(r"^\s*(?:\w+ )?FAIL\b|^\s*(?:SCRIPT |SHADER )?ERROR:")


def run_named(check, folder, index):
    """check.py's own run and verdict, in a thread so an interrupt here can still kill
    the child it started in its own session. Returns (rejected, failing lines)."""
    live, out = {}, []
    worker = threading.Thread(target=lambda: out.append(runner.run_child(check, folder, index, OPTIONS, None, live)), daemon=True)
    worker.start()
    try:
        while worker.is_alive():
            worker.join(0.2)
    finally:
        # No grace: this runs inside our own SIGTERM's grace, and the restore comes after it.
        runner.stop_tree(*[p.pid for p in list(live.values()) if p.returncode is None], grace=0)
    if not out:
        raise RuntimeError(f"check.py could not run {check.name}")
    result = out[0][0]
    text = Path(result["log"]).read_text(errors="replace")
    return result["problem"] is not None, [l.strip() for l in text.splitlines() if FAILURE.match(l)] or [result["problem"] or ""]


def run_raw(godot, args):
    r = subprocess.run([godot, "--path", str(ROOT), *args], cwd=ROOT, capture_output=True, text=True, timeout=900)
    out = r.stdout + r.stderr
    # A passing run prints "failures=0", for the course "COURSE …L …S 0E", for the soak an
    # empty failure list.
    passed = (" failures=0" in out or re.search(r"^COURSE \d+L \d+S 0E$", out, re.MULTILINE) is not None
              or re.search(r"^SOAK FAILURES \[\]$", out, re.MULTILINE) is not None)
    return r.returncode != 0 or not passed, [l.strip() for l in out.splitlines() if l.startswith("FAIL") or "ERROR" in l]


def trial(edits, checks, folder, godot, named, native=False):
    """Apply `edits`, rebuild native/ if they touch it (or `native`), run `checks` and
    restore. Returns [(check, rejected, failing lines)], or why nothing could run."""
    paths = list(dict.fromkeys(p for p, _, _ in edits))
    native = native or any(p.startswith("native/") for p in paths)
    saved = snapshot(paths, native)
    texts = {p: saved[p][0].decode() for p in paths}
    for p, old, new in edits:
        if texts[p].count(old) != 1:
            return f"STALE: the text to break is not in {p} exactly once"
        texts[p] = texts[p].replace(old, new)
    folder.mkdir(parents=True, exist_ok=True)
    write_journal(saved, native)
    try:
        for p in paths:
            put(ROOT / p, texts[p].encode())
        if native:
            build = subprocess.run(["sh", str(ROOT / "native/build.sh")], cwd=ROOT, capture_output=True, text=True, timeout=600)
            if build.returncode != 0:
                said = (build.stdout + build.stderr).strip().splitlines() or [f"exit {build.returncode}"]
                return "BUILD FAILED: " + next((l for l in said if "error" in l), said[-1])
        return [(c, *(run_named(named[c], folder, i) if isinstance(c, str) else run_raw(godot, c))) for i, c in enumerate(checks)]
    finally:
        restore(saved, native)
        JOURNAL.unlink()


def quoted(line):
    """A child's line, echoed. check.py would read its "ERROR:" as this run's own."""
    return line.replace("ERROR:", "ERROR")


def label(c):
    return c if isinstance(c, str) else next((a for a in c if a.startswith("res://")), " ".join(a for a in c if "=" in a))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", default=os.environ.get("GODOT"))
    ap.add_argument("--only", help="mutations or groups (core, galaxy), comma-separated")
    ap.add_argument("--checks", help="check.py checks to run against every selected mutation instead of its own")
    ap.add_argument("--log-dir", type=Path, help="where the named checks' logs go (default: a temporary folder)")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    signal.signal(signal.SIGTERM, interrupted)
    recover()
    names = [n for part in (a.only.split(",") if a.only else list(GROUPS)) for n in GROUPS.get(part, [part])]
    unknown = [n for n in names if n not in TABLE]
    if unknown:
        sys.exit(f"MUTATIONCHECK FAIL: unknown mutation {', '.join(unknown)}")
    if a.list:
        for n in names: print(n, "-", normal(TABLE[n])[2], "(known miss)" if n in KNOWN_MISSES else "")
        return 0
    try:
        godot = runner.godot_path(a.godot)
    except ValueError:
        sys.exit("MUTATIONCHECK FAIL: no Godot; pass --godot")
    OPTIONS.godot = godot
    output = a.log_dir.resolve() if a.log_dir else Path(tempfile.mkdtemp(prefix="astrarium-mutation-"))
    named = {}
    (output / "suite").mkdir(parents=True, exist_ok=True)
    for suite in ("fast", "native", "rendered", "flight"):
        for c in map(lambda c: runner.Check(*c), runner.checks(suite, godot, output / "suite", 1, "macOS")):
            named.setdefault(c.name, c)
    survey = a.checks.split(",") if a.checks else None
    plan = {n: normal(TABLE[n]) for n in names}
    for n, (_, checks, _, _) in plan.items():
        missing = [c for c in survey or checks if isinstance(c, str) and c not in named]
        if missing:
            sys.exit(f"MUTATIONCHECK FAIL: {n} names {', '.join(missing)}, which check.py does not have")
    distinct = []
    for _, checks, _, _ in plan.values():
        distinct += [c for c in survey or checks if c not in distinct]
    native = any(p.startswith("native/") for edits, _, _, _ in plan.values() for p, _, _ in edits)
    control = trial([], distinct, output / "control", godot, named, native)
    rejected = [label(c) for c, failed, _ in control if failed] if not isinstance(control, str) else [control]
    if rejected:
        sys.exit(f"MUTATIONCHECK FAIL: the unchanged tree{' with native/ rebuilt' if native else ''} already fails {', '.join(rejected)}")
    print(f"CONTROL the unchanged tree{' with native/ rebuilt' if native else ''} passes {', '.join(map(label, distinct))}", flush=True)
    good = 0
    for name, (edits, checks, what, assertions) in plan.items():
        results = trial(edits, survey or checks, output / name, godot, named)
        known = name in KNOWN_MISSES
        if isinstance(results, str):
            print(f"MUTATION {name} {results}", flush=True)
            continue
        lines = [l for _, failed, fails in results if failed for l in fails]
        broken = [l for l in lines if any(s in l for s in ("Parse Error", "Compile Error", "SHADER ERROR"))]
        if broken:
            print(f"MUTATION {name} BROKEN: the mutated code does not compile, so it tests nothing\n        {quoted(broken[0])}", flush=True)
            continue
        caught = any(failed for _, failed, _ in results) if survey else all(failed for _, failed, _ in results)
        absent = [s for s in assertions if not any(s in l for l in lines if FAILURE.match(l))] if caught and not survey else []
        verdict = ("caught" if not absent else "caught, but not by " + "; ".join(absent)) if caught else ("missed (known)" if known else "MISSED")
        print(f"MUTATION {name} {verdict}: {what}")
        for c, failed, fails in results:
            print(f"    {label(c)} {'rejects' if failed else 'passes'}" + "".join(f"\n        {quoted(l)}" for l in fails[:3] if failed), flush=True)
        good += (caught and not absent) == (not known)
    print(f"MUTATIONCHECK DONE as-expected={good}/{len(plan)} known-misses={len([n for n in plan if n in KNOWN_MISSES])} logs={output}")
    return 0 if good == len(plan) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit("MUTATIONCHECK INTERRUPTED; every file is restored")
