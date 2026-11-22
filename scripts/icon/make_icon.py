from PIL import Image, ImageDraw, ImageFilter, ImageChops
import math, sys

S = 1024
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(len(a)))

def squircle_mask(size, inset, radius):
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([inset, inset, size-inset, size-inset], radius=radius, fill=255)
    return m

img = Image.new('RGBA', (S, S), (0,0,0,0))
inset = 100            # macOS icon grid: 824px body inside 1024 canvas
body = S - 2*inset
radius = int(body * 0.225)

# Background: diagonal dark gradient with green glow bottom
bg = Image.new('RGBA', (S, S))
px = bg.load()
for y in range(S):
    for x in range(S):
        t = (x*0.35 + y*0.65) / S
        c = lerp((14,18,16), (6,26,12), t)
        px[x,y] = c + (255,)
# radial glow
glow = Image.new('L', (S,S), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([S*0.18, S*0.30, S*0.86, S*0.98], fill=150)
glow = glow.filter(ImageFilter.GaussianBlur(120))
green = Image.new('RGBA', (S,S), (80,255,60,255))
bg = Image.composite(green, bg, glow.point(lambda v: int(v*0.45)))

# Carbon-fibre-ish subtle grid
grid = Image.new('RGBA', (S,S), (0,0,0,0))
gdr = ImageDraw.Draw(grid)
for k in range(-S, S, 28):
    gdr.line([(k,0),(k+S,S)], fill=(255,255,255,10), width=2)
bg = Image.alpha_composite(bg, grid)

# Strip chart (like BoostBar's hover chart): upload area above the center line, download below
import random
random.seed(7)
chart = Image.new('RGBA', (S,S), (0,0,0,0))
cd = ImageDraw.Draw(chart)
cx0, cx1 = inset+70, S-inset-70
mid = S*0.62
N = 64
def series(amp, base, phase):
    vals, v = [], base
    for i in range(N):
        v += random.uniform(-0.22, 0.22)
        v = 0.65*v + 0.35*(base + 0.35*math.sin(i*0.35+phase))
        vals.append(max(0.04, min(1.0, v + (0.55 if i in (18,19,40,41,52) else 0))))
    return [x*amp for x in vals]
up = series(150, 0.45, 0.0)
dn = series(115, 0.40, 1.7)
step = (cx1-cx0)/(N-1)
pts_up = [(cx0+i*step, mid-up[i]) for i in range(N)]
pts_dn = [(cx0+i*step, mid+dn[i]) for i in range(N)]
cd.polygon([(cx0,mid)]+pts_up+[(cx1,mid)], fill=(255,255,255,70))
cd.polygon([(cx0,mid)]+pts_dn+[(cx1,mid)], fill=(116,251,76,70))
cd.line(pts_up, fill=(255,255,255,235), width=7, joint="curve")
cd.line(pts_dn, fill=(140,255,100,235), width=7, joint="curve")
cd.rectangle([cx0, mid-2, cx1, mid+2], fill=(255,255,255,150))
# fade the chart toward the left edge like a scrolling strip chart
fade = Image.new('L', (S,S), 0)
fdp = fade.load()
for x in range(S):
    t = min(max((x-cx0)/(cx1-cx0), 0), 1)
    a_ = int(255*(0.25+0.75*t))
    for y in range(S):
        fdp[x,y] = a_
chart.putalpha(ImageChops.multiply(chart.getchannel('A'), fade))
bg = Image.alpha_composite(bg, chart)

# Lightning bolt polygon (normalized coords)
pts = [(0.565,0.175),(0.345,0.545),(0.488,0.545),(0.420,0.840),(0.665,0.445),(0.520,0.445),(0.610,0.175)]
poly = [(x*S, y*S) for x,y in pts]
bolt_mask = Image.new('L', (S,S), 0)
ImageDraw.Draw(bolt_mask).polygon(poly, fill=255)

# Neon glow under bolt
neon = bolt_mask.filter(ImageFilter.GaussianBlur(28))
bg = Image.composite(Image.new('RGBA',(S,S),(120,255,40,255)), bg, neon.point(lambda v: int(v*0.85)))

# Bolt fill: yellow (top) -> neon green (bottom)
fill = Image.new('RGBA', (S,S))
fp = fill.load()
for y in range(S):
    t = min(max((y - S*0.17)/(S*0.67), 0), 1)
    c = lerp((240,255,60), (60,230,40), t)
    for x in range(S):
        fp[x,y] = c + (255,)
bg = Image.composite(fill, bg, bolt_mask)

# Highlight edge on bolt
edge = bolt_mask.filter(ImageFilter.FIND_EDGES).filter(ImageFilter.GaussianBlur(1.5))
bg = Image.composite(Image.new('RGBA',(S,S),(255,255,220,255)), bg, edge.point(lambda v: min(255, v*2)))

# Googly eyes stuck on the bolt
def googly_eye(img, cx, cy, r, look):
    layer = Image.new('RGBA', (S,S), (0,0,0,0))
    sh = Image.new('L', (S,S), 0)
    ImageDraw.Draw(sh).ellipse([cx-r+6, cy-r+12, cx+r+6, cy+r+12], fill=150)
    layer = Image.composite(Image.new('RGBA',(S,S),(0,0,0,170)), layer, sh.filter(ImageFilter.GaussianBlur(10)))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx-r, cy-r, cx+r, cy+r], fill=(250,250,250,255), outline=(20,20,20,255), width=7)
    # subtle shading on the white
    shade = Image.new('L', (S,S), 0)
    ImageDraw.Draw(shade).ellipse([cx-r*0.95, cy-r*0.15, cx+r*0.95, cy+r*0.95], fill=60)
    shade = ImageChops.multiply(shade.filter(ImageFilter.GaussianBlur(r*0.25)), Image.new('L',(S,S),255))
    layer = Image.composite(Image.new('RGBA',(S,S),(170,180,175,255)), layer, ImageChops.multiply(shade, layer.getchannel('A')))
    d = ImageDraw.Draw(layer)
    d.ellipse([cx-r, cy-r, cx+r, cy+r], outline=(20,20,20,255), width=7)
    pr = r*0.52
    px, py = cx + look[0]*(r-pr-9), cy + look[1]*(r-pr-9)
    d.ellipse([px-pr, py-pr, px+pr, py+pr], fill=(12,12,12,255))
    g = pr*0.32
    d.ellipse([px-pr*0.45-g, py-pr*0.45-g, px-pr*0.45+g, py-pr*0.45+g], fill=(255,255,255,235))
    # plastic dome highlight
    hl = Image.new('L', (S,S), 0)
    ImageDraw.Draw(hl).ellipse([cx-r*0.70, cy-r*0.85, cx+r*0.05, cy-r*0.35], fill=130)
    layer = Image.composite(Image.new('RGBA',(S,S),(255,255,255,255)), layer, hl.filter(ImageFilter.GaussianBlur(6)))
    return Image.alpha_composite(img, layer)

bg = googly_eye(bg, S*0.445, S*0.375, S*0.082, (0.55, -0.35))
bg = googly_eye(bg, S*0.590, S*0.345, S*0.072, (0.75, 0.15))

# Clip to rounded square + inner rim + drop shadow
mask = squircle_mask(S, inset, radius)
body_img = Image.new('RGBA', (S,S), (0,0,0,0))
body_img.paste(bg, (0,0), mask)
rim = Image.new('RGBA', (S,S), (0,0,0,0))
ImageDraw.Draw(rim).rounded_rectangle([inset+1, inset+1, S-inset-1, S-inset-1], radius=radius, outline=(255,255,255,38), width=3)
body_img = Image.alpha_composite(body_img, rim)

shadow = Image.new('RGBA', (S,S), (0,0,0,0))
sm = squircle_mask(S, inset, radius).filter(ImageFilter.GaussianBlur(18))
shadow.paste(Image.new('RGBA',(S,S),(0,0,0,110)), (0,12), sm)
out = Image.alpha_composite(shadow, body_img)
out.save(sys.argv[1])
