#!/usr/bin/env python3
"""Print the frame (from a directory of fNNNN.png) with the most lit pixels in its centre crop, so thumbnails and
README stills show ships rather than empty sky.   python3 tools/pick_frame.py out/ships [aspect]"""
import glob, sys
from PIL import Image
d = sys.argv[1]; aspect = float(sys.argv[2]) if len(sys.argv) > 2 else 1.55
best, score = None, -1
for f in sorted(glob.glob(d + "/f*.png"))[::5]:
    im = Image.open(f).convert("L")
    w, h = im.size; cw = int(h * aspect)
    c = im.crop(((w - cw) // 2, 0, (w + cw) // 2, h)).resize((160, int(160 / aspect)))
    s = sum(1 for p in c.getdata() if p > 60)
    if s > score: best, score = f, s
print(best)
