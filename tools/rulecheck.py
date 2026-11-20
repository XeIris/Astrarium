#!/usr/bin/env python3
"""Static guards for AGENTS.md rules that a pattern can state, in well under a second.

    tools/rulecheck.py [--list] [PATH...]

Each rule reads code with comments removed and names the line that breaks it. A rule's
`bad` and `good` samples run first, so a pattern that stopped matching fails the check
instead of passing everything. Runtime checks judge whether the physics is right; this
only catches the shape of a known mistake early (a second G, a threshold outside
structure.gd, a kernel constant changed on one side).
"""
import argparse
import ast
import fnmatch
import math
from pathlib import Path
import re
import subprocess
import sys
from typing import NamedTuple

ROOT = Path(__file__).resolve().parent.parent
CODE = ("sim/*", "ui/*", "core/*", "render/*", "main.gd", "native/*")


class Rule(NamedTuple):
    name: str
    why: str
    files: tuple
    pattern: str
    bad: tuple
    good: tuple
    exclude: tuple = ()


RULES = (
    Rule("one-G", "G = 4π² is defined once, in sim/physics.gd; other unit systems derive from Physics.G",
         ("sim/*.gd", "core/*.gd", "ui/*.gd", "render/*.gd", "main.gd"), r"^\s*const\s+G\s*(?::\s*\w+\s*)?:?=(?!.*\bPhysics\.G\b)",
         ("const G := 39.478", "const G: float = 4.0 * PI * PI"), ("const G := Physics.G * MASS_UNIT_SUN", "\tvar G := _pattern_table(k)"),
         exclude=("sim/physics.gd",)),
    Rule("one-GM-sun", "GM☉ is Rocketry.GM_SUN; a second copy drifts from the one the orrery year is built on",
         CODE, r"\b1\.327\d*e\+?20\b", ("var mu := 1.32712440018e20", "const GMS = 1.327e20;"), ("var mu := Rocketry.GM_SUN",),
         exclude=("sim/flight/rocketry.gd",)),
    Rule("thresholds-in-structure", "structural limits (Chandrasekhar, TOV) live in structure.gd's LIMITS, never in a second place",
         CODE, r"(?i)\b(?:chandra\w*|tov\w*)\b[^\n]{0,40}?(?<![\w.])(?:1\.[3-5]\d*|2\.[0-4]\d*)(?![\w.])",
         ('var chandra_mass := 1.44', 'var chandrasekhar := 1.44', 'const TOV_MAX := 2.17'),
         ('if mass > Structure.LIMITS.chandrasekhar:', 'var tov := Structure.tov_limit(spin)'),
         exclude=("sim/structure.gd",)),
    Rule("rs-from-mass", "a black hole's rs comes from its mass (Physics.schwarzschild); a spec cannot override it",
         CODE, r"\bspec\s*(?:\.rs\b|\[\s*\"rs\"\s*\]|\.get\(\s*\"rs\")", ('b.rs = spec.get("rs", 0.0)', 'var r: float = spec["rs"]'),
         ('b.rs = Physics.schwarzschild(b.mass)', 'out["rs"] = b.rs')),
    Rule("scale-free-physics", "scene/body scale and true-scale toggles must not change physics; they belong to rendering",
         ("sim/physics.gd", "sim/nbody.gd", "sim/structure.gd", "sim/stellar.gd", "sim/climate*.gd", "sim/atmosphere.gd", "sim/ebm.gd",
          "core/body.gd", "native/nbody.c"),
         r"\b(?:scene_scale|sceneScale|bodyScale|body_scale|true_scale|trueScale|render_radius|hole_render_radius)\b",
         ("var soft := b.radius * state.scene_scale", "if true_scale: r = b.radius"), ("var soft := b.contact_au",)),
    Rule("physics-double", "physics state is double: DVec3, never Vector3",
         ("sim/physics.gd", "sim/nbody.gd", "core/body.gd", "sim/flight/orbit.gd", "sim/flight/rocketry.gd", "sim/flight/vessel.gd"),
         r"\bVector3\b", ("var pos := Vector3()", "func at(p: Vector3) -> void:"), ("var pos := DVec3.new()",)),
    Rule("flight-si", "sim/flight is SI; AU-unit Physics constants enter only through Rocketry's conversions",
         ("sim/flight/*.gd",), r"\bPhysics\.(?:G|C|AU_PER_KM|AU_PER_RSUN|schwarzschild|circular_speed|vis_viva)\b",
         ("var mu := Physics.G * m", "var c := Physics.C"), ("var mu := Rocketry.GM_SUN * mass_sun", "var a := Physics.Gradient")),
    Rule("visuals-read-only", "a body visual must not change physical mass, position or velocity",
         ("sim/*_visual.gd", "sim/marker.gd", "sim/trail.gd", "sim/painter.gd", "render/*.gd"),
         r"\b\w+\.(?:mass|pos|vel|acc)\s*(?:[-+*/]?=)(?!=)|\.(?:pos|vel|acc)\.(?:set_v|copy_from|add_scaled_in|scale_in|add_in|sub_in)\(",
         ("b.mass = 2.0", "body.vel.copy_from(v)", "b.pos.add_scaled_in(d, 1.0)"), ("var m := b.mass", "if b.mass == 0.0:", "node.position = p")),
    Rule("surface-reads-only", "sim/surface reads the world and writes nothing back: not to Climate, not to any body "
         "(spin_phase, the visual's display turn, excepted)",
         ("sim/surface/*.gd",), r"\b(?:climate|Climate)\.\w+\s*(?:[-+*/]?=)(?!=)|\b(?:b|body|world)\.(?!spin_phase\b)\w+\s*(?:[-+*/]?=)(?!=)",
         ("b.climate.temp = t", "body.mass -= 1.0", "Climate.HOME_INPUTS = x"),
         ("var t: float = b.climate.temp", "self.temp = world_temp", "body.spin_phase = best_phase")),
    Rule("lessons-data-only", "sim/lessons.gd is data with no scene access; lessonui.gd executes its requests",
         ("sim/lessons.gd",), r"\b(?:get_tree|get_node|get_parent|Engine\.get_main_loop|add_child)\s*\(|(?<![\w\"'])\$[A-Za-z_\"]",
         ("get_tree().paused = true", "var hud = $HUD"), ('"do": {"focus": "earth"}', 'var cost := "$5"')),
)

# Constants both N-body kernels define: they must agree exactly (both must stay bit-identical).
TWINS = (("sim/physics.gd", "native/nbody.c", {"G": "G", "C": "C_LIGHT", "PN_LIMIT": "PN_LIMIT", "YOSHIDA_W1": "YOSHIDA_W1",
                                                "YOSHIDA_W0": "YOSHIDA_W0", "TIDE_REACH": "TIDE_REACH"}),
         ("sim/nbody.gd", "native/nbody.c", {"STRIDE": "STRIDE"}),
         ("main.gd", "native/nbody.c", {"STEP_GUARD": "STEP_GUARD"}))


def strip_comments(text, suffix):
    """Comments blanked, strings and line numbers kept."""
    out, i, n = [], 0, len(text)
    hash_comments = suffix in (".gd", ".py", ".sh")
    while i < n:
        c = text[i]
        if c in "\"'":
            quote = text[i:i + 3] if text[i:i + 3] in ('"""', "'''") else c
            j = i + len(quote)
            while j < n and not text.startswith(quote, j):
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + len(quote)])
            i = j + len(quote)
        elif (hash_comments and c == "#") or (not hash_comments and text.startswith("//", i)):
            while i < n and text[i] != "\n":
                i += 1
        elif not hash_comments and text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("\n" * text.count("\n", i, j))
            i = j
        else:
            out.append(c)
            i += 1
    return "".join(out)


LISTED = []


def tracked(patterns, exclude=()):
    if not LISTED:
        LISTED.extend(subprocess.run(["git", "ls-files", "--cached", "--others", "--exclude-standard"], cwd=ROOT,
                                     capture_output=True, text=True, check=True, timeout=60).stdout.splitlines())
    listed = LISTED
    return sorted(p for p in listed if any(fnmatch.fnmatch(p, g) for g in patterns) and not any(fnmatch.fnmatch(p, g) for g in exclude)
                  and p.endswith((".gd", ".c", ".h")) and (ROOT / p).is_file())


def constants(path):
    """{name: value} of a file's numeric constants, evaluated (PI, TAU and the file's own
    earlier constants, plus Rocketry's for physics.gd)."""
    text = strip_comments((ROOT / path).read_text(encoding="utf-8"), Path(path).suffix)
    env = {"PI": math.pi, "TAU": math.tau}
    if path.endswith(".gd"):
        rocketry = strip_comments((ROOT / "sim/flight/rocketry.gd").read_text(encoding="utf-8"), ".gd")
        found = re.findall(r"^const\s+(\w+)\s*:?=\s*([^\n]+)$", rocketry, re.M)
        env.update({f"Rocketry.{k}": v for k, v in evaluate(found, {"PI": math.pi, "TAU": math.tau}).items()})
        pairs = re.findall(r"^const\s+(\w+)\s*(?::\s*\w+\s*)?:?=\s*([^\n]+)$", text, re.M)
    else:
        pairs = re.findall(r"^static\s+const\s+double\s+(\w+)\s*=\s*([^;]+);", text, re.M)
        pairs += re.findall(r"^#define\s+(\w+)\s+([-+0-9.eE]+)\s*$", text, re.M)
    return evaluate(pairs, env)


def evaluate(pairs, env):
    values = {}
    for name, expression in pairs:
        expression = expression.strip()
        for key in sorted(env, key=len, reverse=True):
            expression = re.sub(rf"(?<![\w.]){re.escape(key)}(?![\w])", repr(env[key]), expression)
        try:
            tree = ast.parse(expression, mode="eval")
            if all(isinstance(node, (ast.Expression, ast.BinOp, ast.UnaryOp, ast.Constant, ast.operator, ast.unaryop)) for node in ast.walk(tree)):
                values[name] = env[name] = float(eval(compile(tree, "<const>", "eval"), {"__builtins__": {}}))
        except (SyntaxError, ValueError, TypeError, ZeroDivisionError):
            continue
    return values


def selftest():
    problems = []
    for rule in RULES:
        regex = re.compile(rule.pattern)
        problems += [f"{rule.name}: bad sample not matched: {s!r}" for s in rule.bad if not regex.search(s)]
        problems += [f"{rule.name}: good sample matched: {s!r}" for s in rule.good if regex.search(s)]
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("paths", nargs="*", help="only these repository paths (default: every file a rule covers)")
    parser.add_argument("--list", action="store_true", help="print the rules and why each exists")
    options = parser.parse_args()
    if options.list:
        for rule in RULES:
            print(f"{rule.name}: {rule.why}")
        print("kernel-twins: a constant both N-body kernels define has one value (they must stay bit-identical)")
        return 0
    failures = selftest()
    for problem in failures:
        print(f"RULECHECK SELFTEST FAIL {problem}")
    violations = 0
    for rule in RULES:
        regex = re.compile(rule.pattern)
        for path in tracked(rule.files, rule.exclude):
            if options.paths and path not in options.paths:
                continue
            code = strip_comments((ROOT / path).read_text(encoding="utf-8", errors="replace"), Path(path).suffix)
            for number, line in enumerate(code.splitlines(), 1):
                if regex.search(line):
                    violations += 1
                    print(f"RULECHECK VIOLATION {rule.name} {path}:{number}: {line.strip()[:160]}\n  rule: {rule.why}")
    for gd, c, names in TWINS:
        if options.paths and gd not in options.paths and c not in options.paths:
            continue
        left, right = constants(gd), constants(c)
        for name, twin in names.items():
            if name not in left or twin not in right:
                violations += 1
                print(f"RULECHECK VIOLATION kernel-twins {name}: not a plain numeric constant in {gd if name not in left else c} any more")
            elif left[name] != right[twin]:
                violations += 1
                print(f"RULECHECK VIOLATION kernel-twins {gd} {name} = {left[name]!r} but {c} {twin} = {right[twin]!r}\n"
                      "  rule: both kernels must stay bit-identical; change them together")
    print(f"RULECHECK DONE rules={len(RULES) + 1} violations={violations + len(failures)}")
    return 1 if violations or failures else 0


if __name__ == "__main__":
    sys.exit(main())
