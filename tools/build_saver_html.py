#!/usr/bin/env python3
"""Assemble a screensaver page: one self-contained HTML (three.js r147, GLTFLoader, the model GLB as base64,
the liveries and saver.js) so it runs offline inside the .saver bundle.

  python3 tools/build_saver_html.py <three.min.js> <GLTFLoader.js> <out.html> [cars|starships|starlink|jetrace]

The jet racers (jetrace) have their own page and script: Saver/src/jetrace.html, jetrace.js and the six models in
Saver/src/jetrace/.
"""
import base64, os, sys
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = os.path.join(R, "Saver", "src")
three, gltf, out = sys.argv[1:4]
scene = sys.argv[4] if len(sys.argv) > 4 else "cars"
SCENES = {
    "cars": dict(title="BoostBar Flying Cars", loading="⚡ BOOSTBAR FLYING CARS", glb="X1_SkyRacer.glb", liveries="liveries.json"),
    "starlink": dict(title="BoostBar Starlink", loading="🛰 BOOSTBAR STARLINK", glb="Starlink.glb", liveries=None),
    "starships": dict(title="BoostBar Starships", loading="🚀 BOOSTBAR STARSHIPS", glb="Starship.glb", liveries=None, glb2="Roadster.glb"),
}
if scene == "jetrace":
    html = open(os.path.join(S, "jetrace.html"), encoding="utf-8").read()
    parts = {
        "/*TITLE*/": "BoostBar Jet Racers",
        "/*LOADING*/": "🏁 BOOSTBAR JET RACERS",
        "/*THREE*/": open(three, encoding="utf-8").read(),
        "/*GLTFLOADER*/": open(gltf, encoding="utf-8").read(),
        "/*JETRACE*/": open(os.path.join(S, "jetrace.js"), encoding="utf-8").read(),
    }
    for name in ("ski16", "ski8", "ski3", "riderTall", "rider8", "rider3"):
        parts[f"/*GLB:{name}*/"] = base64.b64encode(open(os.path.join(S, "jetrace", name + ".glb"), "rb").read()).decode()
    for k, v in parts.items():
        assert k in html, k
        html = html.replace(k, v.replace("</script", "<\\/script"))
    open(out, "w", encoding="utf-8").write(html)
    print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB)")
    sys.exit(0)
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
    "/*GLB2*/": base64.b64encode(open(os.path.join(S, sc["glb2"]), "rb").read()).decode() if sc.get("glb2") else "",
    "/*SAVER*/": open(os.path.join(S, "saver.js"), encoding="utf-8").read(),
}
for k, v in parts.items():
    assert k in html, k
    html = html.replace(k, v.replace("</script", "<\\/script"))
open(out, "w", encoding="utf-8").write(html)
print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB)")
