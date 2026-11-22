#!/usr/bin/env python3
"""Assemble a screensaver page: one self-contained HTML (three.js r147, GLTFLoader, the model GLB as base64,
the liveries and saver.js) so it runs offline inside the .saver bundle.

  python3 tools/build_saver_html.py <three.min.js> <GLTFLoader.js> <out.html> [cars|starships]
"""
import base64, os, sys
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = os.path.join(R, "Saver", "src")
three, gltf, out = sys.argv[1:4]
scene = sys.argv[4] if len(sys.argv) > 4 else "cars"
SCENES = {
    "cars": dict(title="BoostBar Flying Cars", loading="⚡ BOOSTBAR FLYING CARS", glb="X1_SkyRacer.glb", liveries="liveries.json"),
    "starships": dict(title="BoostBar Starships", loading="🚀 BOOSTBAR STARSHIPS", glb="Starship.glb", liveries=None),
}
sc = SCENES[scene]
html = open(os.path.join(S, "saver.html"), encoding="utf-8").read()
parts = {
    "/*THREE*/": open(three, encoding="utf-8").read(),
    "/*GLTFLOADER*/": open(gltf, encoding="utf-8").read(),
    "/*TITLE*/": sc["title"],
    "/*LOADING*/": sc["loading"],
    "/*SCENE*/": '"' + scene + '"',
    "/*LIVERIES*/": open(os.path.join(S, sc["liveries"]), encoding="utf-8").read() if sc["liveries"] else "[]",
    "/*GLB*/": base64.b64encode(open(os.path.join(S, sc["glb"]), "rb").read()).decode(),
    "/*SAVER*/": open(os.path.join(S, "saver.js"), encoding="utf-8").read(),
}
for k, v in parts.items():
    assert k in html, k
    html = html.replace(k, v.replace("</script", "<\\/script"))
open(out, "w", encoding="utf-8").write(html)
print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB)")
