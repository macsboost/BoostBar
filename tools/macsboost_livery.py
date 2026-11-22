#!/usr/bin/env python3
"""Make the MacsBoost livery for the X1 SkyRacer, in the same format as the sim's src/liveries.json
(XXONE 51 / Yonder 01): a side-projected paint map, a recolour table, and projected decals.

Colours follow the MacsBoost "Ultimate Energy" art: lime / Boost green body, black + yellow slashes,
white MACSBOOST lettering, yellow lightning bolts.

  python3 tools/macsboost_livery.py Saver/src/liveries_sim.json Saver/src/liveries.json
writes the sim's liveries plus MacsBoost into the second file.
"""
import base64, io, json, math, sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter

FONT = "/usr/share/fonts/truetype/google-fonts/ofl/montserrat/Montserrat-Italic[wght].ttf"
LIME, GREEN, DARK, YELLOW, BLACK, WHITE = (116, 251, 76), (86, 190, 55), (20, 80, 20), (245, 228, 0), (14, 15, 14), (245, 247, 245)


def font(size):
    f = ImageFont.truetype(FONT, size)
    try:
        f.set_variation_by_name("Black Italic")
    except Exception:
        pass
    return f


def png_url(im):
    a = io.BytesIO()
    im.save(a, "PNG", optimize=True)
    return "data:image/png;base64," + base64.b64encode(a.getvalue()).decode()


def paint_map():
    """2048 x 352, u along the craft from nose (left) to tail, v from the roof line (top) down."""
    W, H = 2048, 352
    im = Image.new("RGB", (W, H), GREEN)
    d = ImageDraw.Draw(im)
    # lime upper body fading to Boost green
    for y in range(H):
        t = min(1, y / (H * 0.55))
        c = tuple(int(LIME[i] + (GREEN[i] - LIME[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)
    # black keel band with yellow pinstripe
    d.rectangle([0, int(H * 0.84), W, H], fill=BLACK)
    d.rectangle([0, int(H * 0.815), W, int(H * 0.835)], fill=YELLOW)

    def slash(x, w, col, lean=0.42):
        d.polygon([(x, 0), (x + w, 0), (x + w - lean * H, H), (x - lean * H, H)], fill=col)

    # energy slashes, nose and tail, like the art
    for x0 in (300, 1690):
        slash(x0, 46, BLACK)
        slash(x0 + 58, 18, YELLOW)
        slash(x0 + 88, 70, BLACK)
        slash(x0 + 170, 12, YELLOW)
    # long black "speed" stripe along the flank, tapering to the tail
    d.polygon([(420, int(H * 0.58)), (1700, int(H * 0.64)), (1700, int(H * 0.70)), (380, int(H * 0.69))], fill=BLACK)
    d.polygon([(440, int(H * 0.545)), (1700, int(H * 0.62)), (1700, int(H * 0.635)), (430, int(H * 0.57))], fill=YELLOW)
    return im


def text_decal(text, size, fill, stroke=BLACK, stroke_w=None, pad=12, w=None, h=None):
    f = font(size)
    sw = stroke_w if stroke_w is not None else max(2, size // 12)
    box = ImageDraw.Draw(Image.new("RGBA", (1, 1))).textbbox((0, 0), text, font=f, stroke_width=sw)
    tw, th = box[2] - box[0], box[3] - box[1]
    W, H = w or tw + 2 * pad, h or th + 2 * pad
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.text(((W - tw) / 2 - box[0], (H - th) / 2 - box[1]), text, font=f, fill=fill, stroke_width=sw, stroke_fill=stroke)
    return im


def bolt(W, H, fill=YELLOW, outline=BLACK, rotate=0):
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    pts = [(0.62, 0.02), (0.22, 0.58), (0.47, 0.58), (0.36, 0.98), (0.80, 0.38), (0.54, 0.38), (0.70, 0.02)]
    poly = [(x * W, y * H) for x, y in pts]
    d = ImageDraw.Draw(im)
    d.polygon(poly, fill=outline)
    cx, cy = W / 2, H / 2
    inner = [(cx + (x - cx) * 0.86, cy + (y - cy) * 0.9) for x, y in poly]
    d.polygon(inner, fill=fill)
    return im.rotate(rotate, resample=Image.BICUBIC, expand=False) if rotate else im


def fit(im, W, H):
    """Place im centred on a W x H transparent canvas, scaled to fit."""
    k = min(W / im.width, H / im.height)
    im = im.resize((max(1, int(im.width * k)), max(1, int(im.height * k))), Image.LANCZOS)
    c = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    c.paste(im, ((W - im.width) // 2, (H - im.height) // 2), im)
    return c


def stacked(lines, W, H, fill=WHITE):
    parts = [text_decal(t, 160, fill) for t in lines]
    tw = max(p.width for p in parts)
    th = sum(p.height for p in parts)
    c = Image.new("RGBA", (tw, th), (0, 0, 0, 0))
    y = 0
    for p in parts:
        c.paste(p, ((tw - p.width) // 2, y), p)
        y += p.height
    return fit(c, W, H)


def build(sim_x1_sponson_png):
    base = paint_map()
    decals = [
        # side lettering on the nose flank (same box as Yonder's side mark)
        dict(id="mb_side", parts="^Body$", proj="side", nmin=0.4, box={"y": [-2300, -950], "z": [583, 770]},
             png=fit(text_decal("MACSBOOST", 150, WHITE), 800, 110)),
        # rear flank: ULTIMATE ENERGY
        dict(id="mb_rear", parts="^(Body|Flank_Swoosh_[LR])$", proj="side", nmin=0.4, box={"y": [280, 1750], "z": [592, 822]},
             png=fit(text_decal("ULTIMATE ENERGY", 130, YELLOW), 800, 125)),
        # X1 RACING on the sponsons (from the sim's liveries)
        dict(id="x1_sponson", parts="^Sponson_[LR]$", proj="side", nmin=0.4, box={"y": [-720, 420], "z": [392, 528]},
             png=sim_x1_sponson_png),
        # big bolt on the roof behind the canopy
        dict(id="bolt_roof", parts="^(Body|Engine_Louvres)$", proj="top", nmin=0.45, box={"x": [-480, 480], "y": [620, 1680]},
             png=bolt(672, 742)),
        # wings
        dict(id="mb_front_wing", parts="^Front_Wing(_Root|_Fillet)?_[LR]$", proj="top-out", nmin=0.5,
             box={"x": [590, 1270], "y": [-1960, -1040]}, png=stacked(["MACS", "BOOST"], 644, 476)),
        dict(id="mb_rear_wing", parts="^Rear_Wing(_Stub)?_[LR]$", proj="top-out", nmin=0.5,
             box={"x": [655, 1078], "y": [670, 1735]}, png=fit(text_decal("MACSBOOST", 150, WHITE), 746, 296)),
        # belly bolt
        dict(id="bolt_belly", parts="^Body$", proj="bottom", nmin=0.55, box={"x": [-430, 430], "y": [930, 1820]},
             png=bolt(482, 498)),
    ]
    out = dict(id="macsboost", name="MacsBoost", base=png_url(base), recolor=[
        ["^Duct_", "white", "#56be37"],
        ["^(Front|Rear)_Wing_Fillet", "white", "#f5e400"],
        ["^(Front_Wing|Rear_Wing)", "white", "#0e0f0e"],
        ["^Thruster_[LR]", "white", "#0e0f0e"],
        ["^Thruster_[LR]", "red", "#74fb4c"],
        ["^Sponson_Pylon", "white", "#0e0f0e"],
        ["^Fuel_Filler", "red", "#f5e400"],
    ], decals=[])
    for d in decals:
        png = d.pop("png")
        out["decals"].append(dict(d, clear_glass=False, png=png if isinstance(png, str) else png_url(png)))
    return out, base, decals


if __name__ == "__main__":
    sim = json.load(open(sys.argv[1]))
    spon = next(d["png"] for d in sim[0]["decals"] if d["id"] == "x1_sponson")
    mb, base, _ = build(spon)
    json.dump([mb] + sim, open(sys.argv[2], "w"), separators=(",", ":"))
    if len(sys.argv) > 3:  # preview images
        base.save(sys.argv[3] + "_base.png")
        for d in mb["decals"]:
            Image.open(io.BytesIO(base64.b64decode(d["png"].split(",")[1]))).save(f"{sys.argv[3]}_{d['id']}.png")
    print("wrote", sys.argv[2])
