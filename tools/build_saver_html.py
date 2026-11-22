#!/usr/bin/env python3
"""Assemble the screensaver page: one self-contained HTML (three.js r147, GLTFLoader, the SkyRacer GLB as base64,
the liveries and saver.js) so it runs offline inside the .saver bundle.

  python3 tools/build_saver_html.py <three.min.js> <GLTFLoader.js> <out.html>
"""
import base64, os, sys
R = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
S = os.path.join(R, "Saver", "src")
three, gltf, out = sys.argv[1:4]
html = open(os.path.join(S, "saver.html"), encoding="utf-8").read()
parts = {
    "/*THREE*/": open(three, encoding="utf-8").read(),
    "/*GLTFLOADER*/": open(gltf, encoding="utf-8").read(),
    "/*LIVERIES*/": open(os.path.join(S, "liveries.json"), encoding="utf-8").read(),
    "/*GLB*/": base64.b64encode(open(os.path.join(S, "X1_SkyRacer.glb"), "rb").read()).decode(),
    "/*SAVER*/": open(os.path.join(S, "saver.js"), encoding="utf-8").read(),
}
for k, v in parts.items():
    assert k in html, k
    html = html.replace(k, v.replace("</script", "<\\/script"))
open(out, "w", encoding="utf-8").write(html)
print(f"wrote {out} ({os.path.getsize(out) / 1e6:.1f} MB)")
