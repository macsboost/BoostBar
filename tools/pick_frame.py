#!/usr/bin/env python3
"""Pick the best still from a recording (a directory of fNNNN.png): the frame and crop window (of the given aspect,
`frac` of the frame height) holding the most lit pixels, so thumbnails and README stills show the craft instead of
empty sky. Writes the crop to OUT.   python3 tools/pick_frame.py out/sats 1.55 0.6 out.png"""
import glob, sys
import numpy as np
from PIL import Image
d, aspect, frac, out = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
best = (-1, None, None)
for f in sorted(glob.glob(d + "/f*.png"))[::4]:
    im = Image.open(f).convert("L")
    W, H = im.size
    small = np.asarray(im.resize((W // 8, H // 8))) > 55
    h = int(H * frac / 8); w = min(int(h * aspect), small.shape[1])
    ii = np.pad(small.cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    for y in range(0, small.shape[0] - h + 1, 2):
        for x in range(0, small.shape[1] - w + 1, 2):
            s = ii[y + h, x + w] - ii[y, x + w] - ii[y + h, x] + ii[y, x]
            if s > best[0]: best = (s, f, (x * 8, y * 8, (x + w) * 8, (y + h) * 8))
Image.open(best[1]).convert("RGB").crop(best[2]).save(out)
print(best[1], best[2])
