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

# Bandwidth bars (mirrored, white, left->right growing), behind the bolt
bars = Image.new('RGBA', (S,S), (0,0,0,0))
bd = ImageDraw.Draw(bars)
cx0, cx1 = inset+90, S-inset-90
mid = S*0.60
n = 18
bw = (cx1-cx0)/n
heights = [0.15,0.22,0.18,0.30,0.26,0.40,0.34,0.48,0.42,0.55,0.50,0.62,0.58,0.70,0.64,0.78,0.72,0.85]
for i,h in enumerate(heights):
    x = cx0 + i*bw
    up = h*150
    dn = h*110*(0.6+0.4*math.sin(i*1.3)**2)
    a = int(70 + 120*i/n)
    bd.rounded_rectangle([x+4, mid-up, x+bw-4, mid-3], radius=5, fill=(255,255,255,a))
    bd.rounded_rectangle([x+4, mid+3, x+bw-4, mid+dn], radius=5, fill=(255,255,255,int(a*0.55)))
bd.rectangle([cx0, mid-2, cx1, mid+2], fill=(255,255,255,120))
bg = Image.alpha_composite(bg, bars)

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

# Disk LED dot (top-right)
led = Image.new('L', (S,S), 0)
ImageDraw.Draw(led).ellipse([S*0.73, S*0.22, S*0.79, S*0.28], fill=255)
bg = Image.composite(Image.new('RGBA',(S,S),(90,255,90,255)), bg, led.filter(ImageFilter.GaussianBlur(14)))
bg = Image.composite(Image.new('RGBA',(S,S),(200,255,200,255)), bg, led)

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
