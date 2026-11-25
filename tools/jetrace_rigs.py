#!/usr/bin/env python3
"""Writes Saver/src/jetrace/rigs.json from the jet racer models: every node's rest pose and the Steer clip of each
ski and rider. The macOS screen saver runs jetrace.js without three.js's model loader (SceneKit draws the meshes), so
the script poses the riders from this file instead.

  python3 tools/jetrace_rigs.py
"""
import json, os, struct
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
D = os.path.join(R, "Saver", "src", "jetrace")
out = {}
for name in ("ski16", "ski8", "ski3", "riderTall", "rider8", "rider3"):
    b = open(os.path.join(D, name + ".glb"), "rb").read()
    jl = struct.unpack("<I", b[12:16])[0]
    J = json.loads(b[20:20 + jl])
    binary = b[20 + jl + 8:]

    def floats(i):
        a = J["accessors"][i]
        v = J["bufferViews"][a["bufferView"]]
        n = {"SCALAR": 1, "VEC3": 3, "VEC4": 4}[a["type"]] * a["count"]
        o = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        assert a["componentType"] == 5126
        return [round(x, 6) for x in struct.unpack_from("<%df" % n, binary, o)]

    nodes = {n["name"]: {"p": n.get("translation", [0, 0, 0]), "q": n.get("rotation", [0, 0, 0, 1])} for n in J["nodes"]}
    clip = next(a for a in J["animations"] if a["name"] == "Steer")
    times, ch = None, {}
    for c in clip["channels"]:
        s = clip["samplers"][c["sampler"]]
        assert c["target"]["path"] == "rotation" and s.get("interpolation", "LINEAR") == "LINEAR"
        t = floats(s["input"])
        assert times is None or t == times
        times = t
        ch[J["nodes"][c["target"]["node"]]["name"]] = floats(s["output"])
    out[name] = {"nodes": nodes, "clip": {"times": times, "ch": ch}}
p = os.path.join(D, "rigs.json")
json.dump(out, open(p, "w"), separators=(",", ":"))
print(f"wrote {p} ({os.path.getsize(p) / 1e3:.0f} kB)")
