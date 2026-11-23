#!/usr/bin/env python3
"""Build a red open-top roadster with a spacesuited mannequin at the wheel, as a GLB for the BoostBar Starships
screen saver ("Roadster with Starman"). An original, simplified model of a small two-seat roadster — no maker's
badges, logos or lettering — built from code: a lofted body with an open cockpit, raked windscreen, roll hoop,
two seats, a steering wheel, and the driver in a white suit and helmet with a dark visor, one arm on the door.

  scene nodes   roadster (root)
    body                       body, cockpit, windscreen, seats, driver (rigid)
    wheel_FL, wheel_FR, wheel_RL, wheel_RR   extras {wheel: 1}; spin about local x

Frame: metres, +z forward, +y up, +x to the driver's left (left-hand drive), wheels on the ground at y=0.

  python3 tools/roadster_glb.py Saver/src/Roadster.glb
"""
import io, json, math, struct, sys
import numpy as np
from PIL import Image

OUT = sys.argv[1]

# ---------------------------------------------------------------- geometry helpers
def rot(axis, a):
    c, s = math.cos(a), math.sin(a)
    return {'x': np.array([[1, 0, 0], [0, c, -s], [0, s, c]]),
            'y': np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]]),
            'z': np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])}[axis]


FLAT = ((0.01, 0.01),) * 4      # one texel: faces that shouldn't show the texture's pattern


class Mesh:
    def __init__(self):
        self.p, self.n, self.uv, self.i = [], [], [], []

    def quad(self, a, b, c, d, n, uv=((0, 0), (1, 0), (1, 1), (0, 1))):
        k = len(self.p)
        self.p += [a, b, c, d]; self.n += [n] * 4; self.uv += list(uv)
        self.i += [k, k + 1, k + 2, k, k + 2, k + 3]

    def box(self, cx, cy, cz, sx, sy, sz, top_uv=None, bottom=True, top=True):
        x0, x1 = cx - sx / 2, cx + sx / 2
        y0, y1 = cy - sy / 2, cy + sy / 2
        z0, z1 = cz - sz / 2, cz + sz / 2
        t = top_uv or FLAT
        if top: self.quad((x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0), (0, 1, 0), t)
        if bottom: self.quad((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1), (0, -1, 0), FLAT)
        self.quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1), (0, 0, 1), FLAT)
        self.quad((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (0, 0, -1), FLAT)
        self.quad((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (1, 0, 0), FLAT)
        self.quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0), (-1, 0, 0), FLAT)

    def cyl(self, r, h, seg=18, r2=None):
        """A capped cylinder (or cone frustum) along +y from y=0 to y=h, centred on the axis."""
        r2 = r if r2 is None else r2
        sl = (r - r2) / h
        for s in range(seg):
            a0, a1 = 2 * math.pi * s / seg, 2 * math.pi * (s + 1) / seg
            k = len(self.p)
            for a, y, rr in ((a0, 0, r), (a1, 0, r), (a1, h, r2), (a0, h, r2)):
                self.p.append((rr * math.cos(a), y, rr * math.sin(a)))
                L = math.sqrt(1 + sl * sl)
                self.n.append((math.cos(a) / L, sl / L, math.sin(a) / L)); self.uv.append(FLAT[0])
            self.i += [k, k + 2, k + 1, k, k + 3, k + 2]
            for y, rr, ny in ((0, r, -1), (h, r2, 1)):
                k = len(self.p)
                self.p += [(0, y, 0), (rr * math.cos(a0), y, rr * math.sin(a0)), (rr * math.cos(a1), y, rr * math.sin(a1))]
                self.n += [(0, ny, 0)] * 3; self.uv += [FLAT[0]] * 3
                self.i += [k, k + 1, k + 2] if ny < 0 else [k, k + 2, k + 1]
        return self

    def dish(self, r, depth, seg=24, rings=5):
        """A shallow parabolic reflector opening toward +y with its vertex at the origin, plus feed struts."""
        grid = []
        for j in range(rings + 1):
            rr = r * j / rings
            row = []
            for s in range(seg + 1):
                a = 2 * math.pi * s / seg
                nx, ny, nz = -2 * depth * rr / r ** 2 * math.cos(a), 1, -2 * depth * rr / r ** 2 * math.sin(a)
                L = math.sqrt(nx * nx + ny * ny + nz * nz)
                row.append(len(self.p))
                self.p.append((rr * math.cos(a), depth * (rr / r) ** 2, rr * math.sin(a)))
                self.n.append((nx / L, ny / L, nz / L)); self.uv.append(FLAT[0])
            grid.append(row)
        for j in range(rings):
            for s in range(seg):
                a, b, c, d = grid[j][s], grid[j][s + 1], grid[j + 1][s + 1], grid[j + 1][s]
                self.i += [a, c, b, a, d, c]
        return self

    def add(self, other, R=None, t=(0, 0, 0)):
        """Merge another mesh, rotated by R then moved by t."""
        R = np.eye(3) if R is None else R
        k = len(self.p)
        P = (np.array(other.p, 'f8') @ R.T) + np.array(t)
        N = np.array(other.n, 'f8') @ R.T
        self.p += [tuple(v) for v in P]; self.n += [tuple(v) for v in N]; self.uv += other.uv
        self.i += [k + v for v in other.i]
        return self

    def arrays(self):
        return (np.array(self.p, 'f4'), np.array(self.n, 'f4'), np.array(self.uv, 'f4'), np.array(self.i, 'u4'))


def png(im):
    b = io.BytesIO(); im.save(b, 'PNG'); return b.getvalue()


# ---------------------------------------------------------------- glTF writer
G = {'asset': {'version': '2.0', 'generator': 'BoostBar roadster_glb.py'}, 'scene': 0, 'scenes': [{'nodes': []}],
     'nodes': [], 'meshes': [], 'materials': [], 'accessors': [], 'bufferViews': [], 'buffers': [],
     'textures': [], 'images': [], 'samplers': [{'magFilter': 9729, 'minFilter': 9987, 'wrapS': 10497, 'wrapT': 10497}]}
BIN = bytearray()


def view(data, target=None):
    while len(BIN) % 4: BIN.append(0)
    v = {'buffer': 0, 'byteOffset': len(BIN), 'byteLength': len(data)}
    if target: v['target'] = target
    BIN.extend(data); G['bufferViews'].append(v); return len(G['bufferViews']) - 1


def accessor(arr, typ, target):
    comp = 5126 if arr.dtype == np.float32 else 5125
    a = {'bufferView': view(arr.tobytes(), target), 'componentType': comp, 'count': len(arr), 'type': typ}
    if typ == 'VEC3': a['min'] = arr.min(0).tolist(); a['max'] = arr.max(0).tolist()
    G['accessors'].append(a); return len(G['accessors']) - 1


def material(name, color, metal, rough, tex=None, double=True, alpha=1.0):
    m = {'name': name, 'doubleSided': double, 'pbrMetallicRoughness': {'baseColorFactor': list(color) + [alpha], 'metallicFactor': metal, 'roughnessFactor': rough}}
    if alpha < 1: m['alphaMode'] = 'BLEND'
    if tex is not None:
        G['images'].append({'bufferView': view(png(tex)), 'mimeType': 'image/png'})
        G['textures'].append({'sampler': 0, 'source': len(G['images']) - 1})
        m['pbrMetallicRoughness']['baseColorTexture'] = {'index': len(G['textures']) - 1}
    G['materials'].append(m); return len(G['materials']) - 1


def mesh(name, parts):
    """parts: [(Mesh, material)]"""
    prims = []
    for m, mat in parts:
        p, n, uv, i = m.arrays()
        prims.append({'attributes': {'POSITION': accessor(p, 'VEC3', 34962), 'NORMAL': accessor(n, 'VEC3', 34962),
                                     'TEXCOORD_0': accessor(uv, 'VEC2', 34962)},
                      'indices': accessor(i, 'SCALAR', 34963), 'material': mat})
    G['meshes'].append({'name': name, 'primitives': prims}); return len(G['meshes']) - 1


def node(name, mesh_i=None, t=(0, 0, 0), extras=None, children=None):
    n = {'name': name, 'translation': [float(v) for v in t]}
    if mesh_i is not None: n['mesh'] = mesh_i
    if extras: n['extras'] = extras
    if children: n['children'] = children
    G['nodes'].append(n); return len(G['nodes']) - 1



# ---------------------------------------------------------------- more shapes
def sphere(m, c, r, seg=20, rings=14, sy=1.0, cap=None):
    """A sphere (or y-squashed spheroid); cap=(axis vector, cos limit) keeps only the part facing that way."""
    grid = []
    for j in range(rings + 1):
        th = math.pi * j / rings
        row = []
        for i in range(seg + 1):
            ph = 2 * math.pi * i / seg
            n = np.array([math.sin(th) * math.cos(ph), math.cos(th), math.sin(th) * math.sin(ph)])
            row.append(n)
        grid.append(row)
    for j in range(rings):
        for i in range(seg):
            q = [grid[j][i], grid[j][i + 1], grid[j + 1][i + 1], grid[j + 1][i]]
            if cap is not None and min(float(np.dot(v, cap[0])) for v in q) < cap[1]:
                continue
            k = len(m.p)
            for v in q:
                m.p.append((c[0] + r * v[0], c[1] + r * sy * v[1], c[2] + r * v[2]))
                nn = np.array([v[0], v[1] / sy, v[2]]); nn /= np.linalg.norm(nn)
                m.n.append(tuple(nn)); m.uv.append(FLAT[0])
            m.i += [k, k + 2, k + 1, k, k + 3, k + 2]
    return m


def torus(m, c, R, r, axis_R, seg=28, tube=10):
    """A torus around `c`, its ring in the plane perpendicular to the unit vector after rotation R (3x3)."""
    pts = []
    for i in range(seg + 1):
        a = 2 * math.pi * i / seg
        ring = []
        for j in range(tube + 1):
            b = 2 * math.pi * j / tube
            n = np.array([math.cos(a) * math.cos(b), math.sin(b), math.sin(a) * math.cos(b)])
            p = np.array([(R + r * math.cos(b)) * math.cos(a), r * math.sin(b), (R + r * math.cos(b)) * math.sin(a)])
            ring.append((axis_R @ p + c, axis_R @ n))
        pts.append(ring)
    for i in range(seg):
        for j in range(tube):
            q = [pts[i][j], pts[i + 1][j], pts[i + 1][j + 1], pts[i][j + 1]]
            k = len(m.p)
            for p, n in q:
                m.p.append(tuple(p)); m.n.append(tuple(n)); m.uv.append(FLAT[0])
            m.i += [k, k + 1, k + 2, k, k + 2, k + 3]
    return m


def rod(m, p, q, r, seg=10):
    p, q = np.array(p, 'f8'), np.array(q, 'f8')
    d = q - p; L = float(np.linalg.norm(d)); d /= L
    ax = np.cross([0, 1, 0], d); sn = float(np.linalg.norm(ax)); cs = float(d[1])
    if sn < 1e-9: R = np.eye(3) if cs > 0 else rot('x', math.pi)
    else:
        ax /= sn; K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
        R = np.eye(3) + sn * K + (1 - cs) * (K @ K)
    m.add(Mesh().cyl(r, L, seg=seg), R, tuple(p))
    return m


def smooth(a, b, x):
    t = min(1.0, max(0.0, (x - a) / (b - a))); return t * t * (3 - 2 * t)


# ---------------------------------------------------------------- materials
PAINT = material('paint', (0.42, 0.012, 0.018), 0.55, 0.26)
INTERIOR = material('interior', (0.035, 0.03, 0.03), 0.1, 0.7)
SEAT = material('seat', (0.30, 0.02, 0.025), 0.05, 0.6)
BLACK = material('trim', (0.02, 0.02, 0.022), 0.4, 0.35)
GLASS = material('glass', (0.05, 0.07, 0.09), 0.9, 0.05, alpha=0.32)
TIRE = material('tire', (0.025, 0.025, 0.025), 0.0, 0.8)
RIM = material('rim', (0.10, 0.10, 0.11), 0.85, 0.3)
CHROME = material('chrome', (0.8, 0.8, 0.82), 1.0, 0.12)
SUIT = material('suit', (0.86, 0.86, 0.84), 0.0, 0.55)
SUITGREY = material('suitgrey', (0.18, 0.18, 0.19), 0.1, 0.6)
VISOR = material('visor', (0.01, 0.01, 0.012), 0.9, 0.04)
LAMP = material('lamp', (0.9, 0.92, 0.95), 0.6, 0.1)
TAIL = material('taillamp', (0.6, 0.02, 0.02), 0.3, 0.2)

# ---------------------------------------------------------------- body: a lofted shell
L2 = 1.98                                          # half length
WHEEL_Z, WHEEL_X, WHEEL_R, WHEEL_W = 1.24, 0.80, 0.32, 0.24
CK0, CK1 = -0.55, 0.62                             # cockpit from the roll hoop to the windscreen base


def half_w(z):
    w = 0.89 + 0.03 * math.exp(-((z + 1.0) / 0.5) ** 2)                 # rear haunches
    if z > 1.35: w -= 0.30 * ((z - 1.35) / (L2 - 1.35)) ** 2            # nose taper
    if z < -1.55: w -= 0.12 * ((-1.55 - z) / (L2 - 1.55)) ** 2          # tail taper
    return w


def top_y(z):
    if z > CK1: return 0.56 + (0.86 - 0.56) * smooth(L2, CK1, z) ** 0.7  # hood falls to the nose
    if z < -0.75: return 0.86 + 0.07 * smooth(-L2, -0.9, z)             # rear deck up to the tail
    return 0.88 + 0.05 * smooth(CK1, CK0 - 0.2, z)


def bot_y(z):
    y = 0.17 + 0.05 * (smooth(1.6, L2, z) + smooth(-1.6, -L2, z))
    for wz in (WHEEL_Z, -WHEEL_Z):                                       # wheel arches
        d = abs(z - wz)
        if d < 0.46: y = max(y, 0.30 + 0.38 * math.sqrt(1 - (d / 0.46) ** 2))
    return y


NZ, NR, SE = 72, 56, 3.2
zs = [L2 * (2 * k / (NZ - 1) - 1) for k in range(NZ)]
P = np.zeros((NZ, NR, 3)); INSIDE = np.zeros((NZ, NR), bool)
for k, z in enumerate(zs):
    w, yt, yb = half_w(z), top_y(z), bot_y(z)
    c, hh = (yt + yb) / 2, (yt - yb) / 2
    cock = smooth(CK0 - 0.06, CK0 + 0.06, z) * smooth(CK1 + 0.06, CK1 - 0.06, z)
    for i in range(NR):
        a = 2 * math.pi * i / NR
        ca, sa = math.cos(a), math.sin(a)
        x = w * math.copysign(abs(ca) ** (2 / SE), ca)
        y = c + hh * math.copysign(abs(sa) ** (2 / SE), sa)
        if sa > 0: x *= 1 - 0.07 * sa ** 3                                # tumblehome
        if cock > 0.01 and sa > 0.2 and abs(x) < w - 0.13:               # the open cockpit: a well inside the doors
            y -= 0.40 * cock; INSIDE[k, i] = True
        P[k, i] = (x, y, z)
# smooth normals from the grid
N = np.zeros_like(P)
for k in range(NZ):
    for i in range(NR):
        du = P[k, (i + 1) % NR] - P[k, (i - 1) % NR]
        dv = P[min(k + 1, NZ - 1), i] - P[max(k - 1, 0), i]
        n = np.cross(dv, du); L = np.linalg.norm(n)
        N[k, i] = n / L if L > 1e-9 else (0, 1, 0)
paint, inner = Mesh(), Mesh()
for k in range(NZ - 1):
    for i in range(NR):
        j = (i + 1) % NR
        q = [(k, i), (k, j), (k + 1, j), (k + 1, i)]
        m = inner if any(INSIDE[a, b] for a, b in q) else paint
        base = len(m.p)
        for a, b in q:
            m.p.append(tuple(P[a, b])); m.n.append(tuple(N[a, b])); m.uv.append(FLAT[0])
        m.i += [base, base + 1, base + 2, base, base + 2, base + 3]
# end caps (nose and tail)
for k, s in ((0, -1), (NZ - 1, 1)):
    ctr = P[k].mean(0); base = len(paint.p)
    paint.p.append(tuple(ctr)); paint.n.append((0, 0, s)); paint.uv.append(FLAT[0])
    for i in range(NR):
        paint.p.append(tuple(P[k, i])); paint.n.append((0, 0, s)); paint.uv.append(FLAT[0])
    for i in range(NR):
        a, b = base + 1 + i, base + 1 + (i + 1) % NR
        paint.i += [base, a, b] if s > 0 else [base, b, a]

trim, glass, seat, suit, suitg, visor, chrome, lamp, tail = (Mesh() for _ in range(9))
# windscreen: raked glass in a black frame
ws = []
for t in (0, 1):
    zz, yy = CK1 + 0.02 - 0.42 * t, 0.88 + 0.33 * t
    hw = half_w(zz) - 0.12 - 0.08 * t
    ws.append((zz, yy, hw))
(z0, y0, w0), (z1, y1, w1) = ws
glass.quad((-w0, y0, z0), (w0, y0, z0), (w1, y1, z1), (-w1, y1, z1), (0, 0.79, 0.61))
rod(trim, (-w0, y0, z0), (-w1, y1, z1), 0.025); rod(trim, (w0, y0, z0), (w1, y1, z1), 0.025)
rod(trim, (-w1, y1, z1), (w1, y1, z1), 0.03); rod(trim, (-w0, y0, z0), (w0, y0, z0), 0.02)
# roll hoop and buttresses behind the seats
hz = CK0 + 0.08
rod(trim, (-0.72, 0.86, hz), (-0.62, 1.12, hz), 0.04); rod(trim, (0.72, 0.86, hz), (0.62, 1.12, hz), 0.04)
rod(trim, (-0.62, 1.12, hz), (0.62, 1.12, hz), 0.04)
# seats
for sx in (-0.37, 0.37):
    seat.box(sx, 0.56, 0.0, 0.46, 0.12, 0.5)
    back = Mesh(); back.box(0, 0.32, 0, 0.46, 0.64, 0.12)
    seat.add(back, rot('x', -0.32), (sx, 0.52, CK0 + 0.25))
# dash and steering wheel (driver on the left, +x)
trim.box(0, 0.80, CK1 - 0.05, 1.5, 0.12, 0.22)
torus(trim, np.array([0.37, 0.92, CK1 - 0.26]), 0.17, 0.022, rot('x', math.pi / 2 - 0.45))
rod(trim, (0.37, 0.92, CK1 - 0.26), (0.37, 0.86, CK1 - 0.12), 0.025)
# the driver: white suit, helmet with a dark visor, right hand on the wheel, left arm on the door
dx = 0.37
rod(suit, (dx, 0.62, -0.05), (dx, 1.02, -0.18), 0.17, seg=16)                  # torso, leaning back
sphere(suit, (dx, 1.02, -0.18), 0.17)
sphere(suitg, (dx, 1.08, -0.16), 0.13)                                         # neck ring
sphere(suit, (dx, 1.27, -0.14), 0.175, seg=24, rings=16)                       # helmet
sphere(visor, (dx, 1.27, -0.12), 0.165, seg=24, rings=16, cap=(np.array([0, 0.15, 1.0]) / np.linalg.norm([0, 0.15, 1.0]), 0.35))
sphere(suit, (dx, 0.66, 0.20), 0.15)                                           # lap / thighs
rod(suit, (dx, 0.66, 0.20), (dx, 0.56, 0.48), 0.11)
rod(suit, (dx - 0.17, 0.98, -0.12), (dx - 0.12, 0.86, 0.12), 0.07)             # right arm to the wheel
rod(suit, (dx - 0.12, 0.86, 0.12), (dx - 0.06, 0.95, CK1 - 0.28), 0.06)
sphere(suitg, (dx - 0.06, 0.95, CK1 - 0.28), 0.06)
rod(suit, (dx + 0.17, 0.98, -0.12), (0.78, 0.92, 0.02), 0.07)                 # left arm out on the door
rod(suit, (0.78, 0.92, 0.02), (0.86, 0.96, 0.28), 0.06)
sphere(suitg, (0.86, 0.96, 0.30), 0.065)
# mirrors, lamps
for s in (-1, 1):
    rod(trim, (s * 0.8, 0.9, CK1 - 0.05), (s * 0.96, 0.94, CK1 - 0.08), 0.015)
    paint.box(s * 1.0, 0.95, CK1 - 0.08, 0.1, 0.07, 0.12)
    lamp.add(sphere(Mesh(), (0, 0, 0), 0.09, sy=0.6), None, (s * 0.58, 0.60, 1.78))
    tail.box(s * 0.55, 0.80, -L2 + 0.02, 0.28, 0.07, 0.04)
    for zz in (-0.62, -0.45):                                                   # side intakes
        trim.box(s * (half_w(-0.75) - 0.01), 0.52, -0.75 + zz * 0.2, 0.02, 0.12, 0.28)
trim.box(0, 0.30, L2 - 0.02, 0.9, 0.12, 0.03)                                  # grille slot
trim.box(0, 0.93, -L2 + 0.28, 1.2, 0.03, 0.14)                                 # rear lip
body = mesh('body', [(paint, PAINT), (inner, INTERIOR), (trim, BLACK), (glass, GLASS), (seat, SEAT), (suit, SUIT),
                     (suitg, SUITGREY), (visor, VISOR), (lamp, LAMP), (tail, TAIL)])
kids = [node('body', body)]
# wheels: tyre, five-spoke dark rim, chrome hub; one mesh, spun about its own axle (local x)
tyre, rim, hub = Mesh(), Mesh(), Mesh()
tyre.add(Mesh().cyl(WHEEL_R, WHEEL_W, seg=32), rot('z', math.pi / 2), (WHEEL_W / 2, 0, 0))
tyre.add(Mesh().cyl(WHEEL_R * 0.98, WHEEL_W * 1.02, seg=32), rot('z', math.pi / 2), (WHEEL_W * 0.51, 0, 0))
for side in (-1, 1):
    x = side * (WHEEL_W / 2 + 0.004)
    rim.add(Mesh().cyl(WHEEL_R * 0.66, 0.01, seg=32), rot('z', -side * math.pi / 2), (x - side * 0.01, 0, 0))
    for k in range(5):
        a = 2 * math.pi * k / 5
        spoke = Mesh(); spoke.box(0, WHEEL_R * 0.33, 0, 0.012, WHEEL_R * 0.62, 0.07)
        rim.add(spoke, rot('x', a), (x + side * 0.008, 0, 0))
    hub.add(Mesh().cyl(0.05, 0.02, seg=14), rot('z', -side * math.pi / 2), (x + side * 0.004, 0, 0))
wm = mesh('wheel', [(tyre, TIRE), (rim, RIM), (hub, CHROME)])
for name, (sx, sz) in {'FL': (1, 1), 'FR': (-1, 1), 'RL': (1, -1), 'RR': (-1, -1)}.items():
    kids.append(node(f'wheel_{name}', wm, (sx * WHEEL_X, WHEEL_R, sz * WHEEL_Z), {'wheel': 1}))
G['scenes'][0]['nodes'].append(node('roadster', None, (0, 0, 0), {'roadster': 1}, kids))

js = json.dumps(G, separators=(',', ':')).encode()
G['buffers'][0:] = [{'byteLength': len(BIN)}]
js = json.dumps(G, separators=(',', ':')).encode()
js += b' ' * ((4 - len(js) % 4) % 4)
while len(BIN) % 4: BIN.append(0)
body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(BIN), 0x004E4942) + bytes(BIN)
open(OUT, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
print(f'{OUT}: {len(G["nodes"])} nodes, {len(G["meshes"])} meshes, {12 + len(body) / 1024:.0f} KB')
