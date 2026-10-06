"""Blender --background --python-exit-code 1 --python primitivecheck.py [-- --lib /absolute/lib.py]."""
import argparse
from collections import defaultdict
import importlib.util
import math
from pathlib import Path
import sys

from mathutils import Vector


def audit(label, obj, exterior):
    mesh = obj.data
    mesh.update()
    edges = defaultdict(list)
    inward = 0 if len(mesh.polygons) else 1
    for face in mesh.polygons:
        vertices = list(face.vertices)
        for a, b in zip(vertices, vertices[1:] + vertices[:1]):
            edges[tuple(sorted((a, b)))].append((a, b))
        facing = face.normal.dot(exterior(face.center))
        if not math.isfinite(face.area) or face.area <= 0.0 or not math.isfinite(facing) or facing <= 0.0:
            inward += 1
    bad_edges = sum(len(uses) != 2 or uses[0] != uses[1][::-1] for uses in edges.values())
    print(f"PRIMITIVECHECK {label} faces={len(mesh.polygons)} bad_edges={bad_edges} inward={inward}")
    return bad_edges + inward


def cylinder_normal(point):
    if abs(point.z) < 1e-6:
        return Vector((0, 0, -1))
    if abs(point.z - 1) < 1e-6:
        return Vector((0, 0, 1))
    return Vector((point.x, point.y, 0))


def torus_normal(point):
    return point - Vector((point.x, point.y, 0)).normalized() * 2.0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lib", type=Path, default=Path(__file__).with_name("lib.py"))
    args = parser.parse_args(sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else [])
    spec = importlib.util.spec_from_file_location("primitive_library", args.lib)
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    lib.reset_scene()
    failures = audit("revolve", lib.revolve("probe_revolve",
        [(0, 0), (1, 0), (1, 1), (0, 1)], None, seg=16), cylinder_normal)
    failures += audit("fin", lib.fin("probe_fin", [(1, 0), (1, 1)],
        0, 1, 0.2, None, r_pad=0), lambda p: p - Vector((1.5, 0, 0.5)))
    failures += audit("ring_on", lib.ring_on((0, 0, 0), (0, 0, 1),
        2, 0.25, None, "probe_ring", seg=24, minor=12), torus_normal)
    failures += audit("box-control", lib.box("probe_box", (2, 2, 2), (0, 0, 0), None), lambda p: p)
    failures += audit("tube-control", lib.tube("probe_tube", [(0, 0, 0), (0, 0, 1)],
        1, None, seg=16, caps=(True, True)), cylinder_normal)
    print(f"PRIMITIVECHECK DONE cases=5 failures={failures}")
    if failures:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
