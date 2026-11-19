"""Prepare NASA VTAD's Voyager.glb for the metre-scale studio (standard library)."""
import hashlib
import json
import math
import struct
import sys
from pathlib import Path

SOURCE_SHA256 = "5338241f2e89e9cfe3ebb82f519b4cad64c97e66883cccba6fdda98667aec731"


def prepare(source, output):
    data = source.read_bytes()
    if hashlib.sha256(data).hexdigest() != SOURCE_SHA256:
        raise ValueError("Expected NASA VTAD's September 2023 Voyager.glb")
    size = struct.unpack_from("<I", data, 12)[0]
    scene = json.loads(data[20:20 + size])
    buf = bytearray(data[28 + size:])
    root = scene["nodes"][3]
    del root["mesh"]  # Transparent registration cube.
    dish = scene["accessors"][8]
    scale = 3.7 / (dish["max"][0] - dish["min"][0])
    root["scale"] = [scale] * 3

    def offset(accessor):
        view = scene["bufferViews"][scene["accessors"][accessor]["bufferView"]]
        return view["byteOffset"] + scene["accessors"][accessor].get("byteOffset", 0)

    def array(accessor):
        return [struct.unpack_from("<3f", buf, offset(accessor) + i * 12)
                for i in range(scene["accessors"][accessor]["count"])]

    # The brass primitive contains the two abbreviated six-sided PRA/PWS whips.
    # Keep their feed points and the bisector of their plane. The PWS instrument
    # paper specifies two orthogonal ten-metre monopoles.
    rods, normals = array(4), array(5)
    for sign in (-1, 1):
        indices = [i for i, p in enumerate(rods) if p[0] * sign > 0]
        rings = [set(rods[i] for i in indices if (abs(rods[i][0]) > 1) == tip)
                 for tip in (False, True)]
        base, end = [[sum(v) / len(v) for v in zip(*ring)] for ring in rings]
        dx, dy, dz = [b - a for a, b in zip(base, end)]
        side = (dy / math.hypot(dy, dz), dz / math.hypot(dy, dz))
        angle = math.atan2(math.hypot(dy, dz), abs(dx))
        turn = math.pi / 4 - angle

        def rotate(v):
            x = v[0] * sign
            u = v[1] * side[0] + v[2] * side[1]
            new_u = math.sin(turn) * x + math.cos(turn) * u
            return (sign * (math.cos(turn) * x - math.sin(turn) * u),
                    v[1] + (new_u - u) * side[0], v[2] + (new_u - u) * side[1])

        axis = [sign / math.sqrt(2), *(v / math.sqrt(2) for v in side)]
        for i in indices:
            at_tip = abs(rods[i][0]) > 1
            pivot = end if at_tip else base
            ring_offset = rotate([v - p for v, p in zip(rods[i], pivot)])
            rods[i] = tuple(base[k] + ring_offset[k] + axis[k] * (10 / scale if at_tip else 0)
                            for k in range(3))
            struct.pack_into("<3f", buf, offset(4) + 12 * i, *rods[i])
            struct.pack_into("<3f", buf, offset(5) + 12 * i, *rotate(normals[i]))
    for accessor, points in [(4, rods), (5, array(5))]:
        scene["accessors"][accessor]["min"] = list(map(min, zip(*points)))
        scene["accessors"][accessor]["max"] = list(map(max, zip(*points)))
    scene["materials"][1]["pbrMetallicRoughness"]["metallicFactor"] = 0.45
    # The forward face of the raised record cover is a separate fan in the bus
    # atlas. Give the original vertices the photographed engraving at close range.
    positions = array(0)
    index = scene["accessors"][3]
    triangles = struct.iter_unpack("<3H", buf[offset(3):offset(3) + 2 * index["count"]])
    bus, cover = [], []
    for triangle in triangles:
        on_cover = all(abs(positions[i][0] - 0.951212) < 0.00001 for i in triangle)
        (cover if on_cover else bus).extend(triangle)
    if len(cover) != 20 * 3:
        raise ValueError("Expected the twenty triangles of the record cover")
    for i in set(cover):
        _, y, z = positions[i]
        # The photographed disc occupies 89% of the square, with +Z to the
        # viewer's left when looking straight at the +X bus face.
        uv = (0.502 - (z + 0.002123) * 0.445 / 0.157041,
              0.491 - (y + 1.281916) * 0.445 / 0.157041)
        struct.pack_into("<2f", buf, offset(2) + 8 * i, *uv)
    struct.pack_into(f"<{len(bus)}H", buf, offset(3), *bus)
    index["count"] = len(bus)
    start = len(buf)
    buf.extend(struct.pack(f"<{len(cover)}H", *cover))
    view = len(scene["bufferViews"])
    scene["bufferViews"].append({"buffer": 0, "byteOffset": start, "byteLength": len(cover)*2, "target": 34963})
    scene["accessors"].append({"bufferView": view, "componentType": 5123, "count": len(cover), "type": "SCALAR"})
    scene["buffers"][0]["byteLength"] = len(buf)
    source_image = len(scene["images"])
    scene["images"].append({"uri": "record-cover.jpg"})
    scene["textures"].append({"source": source_image})
    scene["materials"].append({"name": "Engraved cover", "pbrMetallicRoughness": {
        "baseColorTexture": {"index": len(scene["textures"])-1}, "metallicFactor": 0.2, "roughnessFactor": 0.6}})
    primitives = scene["meshes"][0]["primitives"]
    primitives.append(dict(primitives[0], indices=len(scene["accessors"])-1, material=len(scene["materials"])-1))
    payload = json.dumps(scene, separators=(",", ":")).encode()
    payload += b" " * (-len(payload) % 4)
    output.write_bytes(struct.pack("<4sIIII", b"glTF", 2, 28 + len(payload) + len(buf),
                                   len(payload), 0x4e4f534a) + payload
                       + struct.pack("<I4s", len(buf), b"BIN\0") + buf)


if __name__ == "__main__":
    prepare(Path(sys.argv[1]), Path(__file__).resolve().parents[1] / "assets/voyager/voyager.glb")
