#!/usr/bin/env python3
"""Build Starlink V2 (V2 Mini class) and V3 satellites as one GLB for the BoostBar Starlink screen saver.

Original models, shaped after the general layout seen in public photos and renders (nothing traced or copied): a
thin flat-panel bus whose long edges carry the two solar arrays, square phased-array antennas tiled on one face,
gimballed parabolic dishes on outriggers at the ends, laser terminals at the corners, a Hall thruster at the back.
The arrays are fan-fold blankets: many narrow panels (dark silicon cells one side, pale backing the other) joined
by piano hinges, each array as wide as the bus is long.

  scene nodes   V2, V3                      (roots; the saver clones one per satellite)
    <name>_bus                              (rigid)
    lkL, lkR                                array linkage: a hinge at the bus edge carrying a strut frame out to
                                            the array's root yoke (the gap between bus and array); extras {link}
      wL0 -> wL1 -> ... ,  wR0 -> ...       joint nodes on the hinge lines; extras {wing: 'L'|'R', i, n}
       each joint carries one panel         (span along x, chord along z, cells face +y)

Frame: metres, +y up (cells and antennas face up), +z forward (direction of flight, broadside like a bird), span
along x. A joint turned about its local z by s*a (s = +1 right, -1 left) lifts everything outboard of it by a; the
saver uses that both for the wingbeat and to fan-fold the arrays into a stack on the bus (alternate panels at
180°-d and d from flat), unfold them straight up, then lay them out flat.

  python3 tools/starlink_glb.py Saver/src/Starlink.glb
"""
import io, json, math, struct, sys
import numpy as np
from PIL import Image, ImageDraw

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


# ---------------------------------------------------------------- textures
def cells_texture(cols, rows, px=32, seed=1):
    """One fan-fold panel, cells side: near-black blue silicon cells with clipped corners, fine bus bars and thin
    interconnect gaps; strings of six separated by a slightly wider gap; a narrow pale edge strip."""
    rng = np.random.default_rng(seed)
    m = 10                                                     # edge strip (hinge side / frame)
    W, H = cols * px + 2 * m, rows * px + 2 * m
    im = Image.new('RGB', (W, H), (150, 152, 150))
    d = ImageDraw.Draw(im)
    d.rectangle([m - 3, m - 3, W - m + 2, H - m + 2], fill=(196, 190, 172))   # backing sheet showing in the gaps
    for c in range(cols):
        for r in range(rows):
            x0, y0 = m + c * px, m + r * px
            g = 2 if c % 6 else 4
            k = rng.uniform(-1, 1)
            base = (int(11 + 4 * k), int(19 + 6 * k), int(46 + 12 * k))
            x1, y1, cc = x0 + px - 2, y0 + px - 2, 5
            d.polygon([(x0 + g + cc, y0 + 1), (x1 - cc, y0 + 1), (x1, y0 + 1 + cc), (x1, y1 - cc), (x1 - cc, y1),
                       (x0 + g + cc, y1), (x0 + g, y1 - cc), (x0 + g, y0 + 1 + cc)], fill=base)
            hi = tuple(min(255, v + 34) for v in base)
            for f in (0.33, 0.67):                             # bus bars
                d.line([x0 + g + 1, y0 + int(px * f), x1 - 1, y0 + int(px * f)], fill=hi, width=1)
            for f in range(4, px - 3, 4):                      # faint fingers
                d.line([x0 + g + f, y0 + 3, x0 + g + f, y1 - 3], fill=tuple(v + 5 for v in base), width=1)
    # a soft sheen band so the glass doesn't look flat
    a = np.asarray(im).astype('f4')
    yy, xx = np.mgrid[0:H, 0:W]
    band = np.exp(-(((xx / W) - 0.35 - 0.25 * (yy / H)) / 0.2) ** 2)
    a[..., :] += band[..., None] * np.array([6, 10, 20])
    return Image.fromarray(np.clip(a, 0, 255).astype('u1'))


def back_texture(cols, rows, px=32):
    """The same panel from behind: pale backing film, stiffening ribs, a harness along one edge."""
    m = 10
    W, H = cols * px + 2 * m, rows * px + 2 * m
    im = Image.new('RGB', (W, H), (150, 152, 150))
    d = ImageDraw.Draw(im)
    d.rectangle([m - 3, m - 3, W - m + 2, H - m + 2], fill=(203, 197, 180))
    for c in range(0, cols + 1, 3):
        d.line([m + c * px, m, m + c * px, H - m], fill=(176, 170, 154), width=2)
    for r in range(0, rows + 1, 4):
        d.line([m, m + r * px, W - m, m + r * px], fill=(182, 176, 160), width=2)
    d.line([m, H - m - 8, W - m, H - m - 8], fill=(120, 96, 62), width=3)       # harness
    for c in range(cols):
        d.ellipse([m + c * px + 12, m + 14, m + c * px + 18, m + 20], fill=(168, 162, 148))
    return im


def deck_texture(sx, sz, items, px=110):
    """The antenna face of the bus. items: (kind, x, z, w, h) in metres, origin at the bus centre."""
    W, H = int(sx * px), int(sz * px)
    im = Image.new('RGB', (W, H), (34, 36, 40))
    d = ImageDraw.Draw(im)
    def R(x, z, w, h):
        return [int((x - w / 2 + sx / 2) * px), int((z - h / 2 + sz / 2) * px), int((x + w / 2 + sx / 2) * px), int((z + h / 2 + sz / 2) * px)]
    # panel seams of the chassis skin
    for k in range(1, int(sz)):
        d.line([0, int(k * H / int(sz)), W, int(k * H / int(sz))], fill=(48, 50, 55), width=2)
    d.rectangle([2, 2, W - 3, H - 3], outline=(84, 86, 92), width=5)
    for kind, x, z, w, h in items:
        r = R(x, z, w, h)
        if kind == 'ku':        # phased array: pale radome tile, element grid, fastener frame
            d.rectangle(r, fill=(96, 98, 100))
            d.rectangle([r[0] + 5, r[1] + 5, r[2] - 5, r[3] - 5], fill=(198, 200, 196))
            step = 9
            for yy in range(r[1] + 11, r[3] - 8, step):
                for xx in range(r[0] + 11 + (step // 2 if (yy // step) % 2 else 0), r[2] - 8, step):
                    d.ellipse([xx - 2, yy - 2, xx + 2, yy + 2], fill=(170, 173, 170))
            for q in (0.25, 0.5, 0.75):
                d.line([r[0] + 5, r[1] + (r[3] - r[1]) * q, r[2] - 5, r[1] + (r[3] - r[1]) * q], fill=(150, 152, 150), width=2)
                d.line([r[0] + (r[2] - r[0]) * q, r[1] + 5, r[0] + (r[2] - r[0]) * q, r[3] - 5], fill=(150, 152, 150), width=2)
        elif kind == 'dark':    # dark-coated array / absorber
            d.rectangle(r, fill=(70, 72, 76))
            d.rectangle([r[0] + 4, r[1] + 4, r[2] - 4, r[3] - 4], fill=(22, 23, 27))
            for yy in range(r[1] + 10, r[3] - 6, 10):
                d.line([r[0] + 6, yy, r[2] - 6, yy], fill=(36, 38, 44), width=1)
        elif kind == 'mirror':  # mirror-film radiator
            d.rectangle(r, fill=(120, 124, 130))
            d.rectangle([r[0] + 3, r[1] + 3, r[2] - 3, r[3] - 3], fill=(206, 212, 220))
            for xx in range(r[0] + 14, r[2] - 6, 16):
                d.line([xx, r[1] + 4, xx, r[3] - 4], fill=(180, 186, 196), width=1)
        elif kind == 'pad':     # hold-down / stacking pad
            d.ellipse(r, fill=(140, 142, 146)); d.ellipse([r[0] + 6, r[1] + 6, r[2] - 6, r[3] - 6], fill=(60, 62, 66))
    return im


def png(im):
    b = io.BytesIO(); im.save(b, 'PNG'); return b.getvalue()


# ---------------------------------------------------------------- glTF writer
G = {'asset': {'version': '2.0', 'generator': 'BoostBar starlink_glb.py'}, 'scene': 0, 'scenes': [{'nodes': []}],
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


def material(name, color, metal, rough, tex=None, double=True):
    m = {'name': name, 'doubleSided': double, 'pbrMetallicRoughness': {'baseColorFactor': list(color) + [1], 'metallicFactor': metal, 'roughnessFactor': rough}}
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


SILVER = material('silver', (0.74, 0.76, 0.79), 0.85, 0.32)
CHASSIS = material('chassis', (0.085, 0.09, 0.10), 0.55, 0.5)
WHITE = material('radiator', (0.80, 0.82, 0.85), 0.25, 0.45)
DISH = material('dish', (0.86, 0.87, 0.88), 0.35, 0.38)
LENS = material('lens', (0.05, 0.07, 0.12), 0.9, 0.08)
COPPER = material('thruster', (0.72, 0.45, 0.25), 0.9, 0.35)


def gimbal_dish(r, tilt_axis, tilt):
    """A reflector on a yoke and post, tipped by `tilt` about `tilt_axis`. Returns (white mesh, metal mesh)."""
    white, metal = Mesh(), Mesh()
    refl = Mesh().dish(r, r * 0.3)
    feed = Mesh()
    for a in range(3):                                           # tripod to the feed horn
        ang = a * 2 * math.pi / 3
        x, z = r * 0.8 * math.cos(ang), r * 0.8 * math.sin(ang)
        strut = Mesh().cyl(0.012, math.sqrt((r * 0.8) ** 2 + (r * 0.55) ** 2), seg=5)
        lean = math.atan2(r * 0.8, r * 0.55)
        feed.add(strut, rot('y', -ang) @ rot('z', lean), (x, r * 0.3 * 0.64, z))
    feed.add(Mesh().cyl(r * 0.09, r * 0.14, seg=10), None, (0, r * 0.74, 0))
    Rt = rot(tilt_axis, tilt)
    white.add(refl, Rt, (0, 0.2, 0))
    metal.add(feed, Rt, (0, 0.2, 0))
    metal.add(Mesh().cyl(0.045, 0.2, seg=10))                    # post
    metal.box(0, 0.19, 0, r * 0.5, 0.05, 0.07)                   # yoke
    return white, metal


def satellite(name, bus, deck, dishes, boom, wing, seed):
    """bus (sx span, sy thick, sz chord); deck items; dishes [(x, z_end(+1/-1), r)];
    wing (panels, panel_len, chord, gap, cols, rows)."""
    bx, by, bz = bus
    nodes = []
    ch, top, white, metal, dish, lens, cu = Mesh(), Mesh(), Mesh(), Mesh(), Mesh(), Mesh(), Mesh()
    ch.box(0, 0, 0, bx, by, bz)
    DECK = material(name + '_deck', (0.72, 0.72, 0.72), 0.3, 0.5, deck_texture(bx, bz, deck))
    top.box(0, by / 2 + 0.012, 0, bx * 0.985, 0.024, bz * 0.985, top_uv=((0, 1), (1, 1), (1, 0), (0, 0)), bottom=False)
    # the other face: mirror-film radiator plates and four stacking feet
    for k in (-1, 1):
        white.box(0, -by / 2 - 0.012, k * bz * 0.24, bx * 0.86, 0.024, bz * 0.42)
    for sx_ in (-1, 1):
        for sz_ in (-1, 1):
            metal.add(Mesh().cyl(0.09, 0.2, seg=12), rot('x', math.pi), (sx_ * (bx / 2 - 0.22), -by / 2, sz_ * (bz / 2 - 0.3)))
    # aluminium edge rails along the two array sides, end frames
    for k in (-1, 1):
        metal.box(k * bx / 2, 0, 0, 0.07, by + 0.05, bz + 0.04)
        metal.box(0, 0, k * bz / 2, bx * 0.6, by * 0.6, 0.05)
    # laser terminals: a stubby turret at each corner of the end faces, lens outward
    for sx_ in (-1, 1):
        for sz_ in (-1, 1):
            R = rot('x', sz_ * math.pi / 2)
            ch.add(Mesh().cyl(0.11, 0.2, seg=14), R, (sx_ * (bx / 2 - 0.2), 0, sz_ * bz / 2))
            lens.add(Mesh().cyl(0.075, 0.03, seg=14), R, (sx_ * (bx / 2 - 0.2), 0, sz_ * (bz / 2 + 0.2)))
    # Hall thruster on the trailing end, star trackers on the leading end
    R = rot('x', -math.pi / 2)
    cu.add(Mesh().cyl(0.1, 0.16, seg=16, r2=0.15), R, (0, -by * 0.1, -bz / 2))
    ch.add(Mesh().cyl(0.06, 0.05, seg=12), R, (0, -by * 0.1, -bz / 2 - 0.1))
    for k in (-1, 1):
        ch.add(Mesh().cyl(0.05, 0.16, seg=10, r2=0.075), rot('x', math.pi / 2 - 0.5), (k * 0.3, by * 0.2, bz / 2))
    # gimballed dishes on short outriggers past the ends (clear of the stowed arrays)
    for x, e, r in dishes:
        z = e * (bz / 2 + r * 0.75)
        metal.box(x, 0, e * (bz / 2 + r * 0.38), 0.08, 0.06, r * 0.8)
        w, m = gimbal_dish(r, 'x', e * 0.45)
        dish.add(w, None, (x, 0, z)); metal.add(m, None, (x, 0, z))
    mods, ml, chord, gap, cols, rows = wing
    hy = by / 2 + 0.1
    for k in (-1, 1):
        for zz in (-bz * 0.16, bz * 0.16):                        # clevis posts carrying the array hinges
            metal.box(k * bx / 2, (by / 2 + hy) / 2, zz, 0.09, hy - by / 2 + 0.06, 0.12)
    nodes.append(node(name + '_bus', mesh(name + '_bus', [(ch, CHASSIS), (top, DECK), (white, WHITE), (metal, SILVER),
                                                             (dish, DISH), (lens, LENS), (cu, COPPER)])))

    mods, ml, chord, gap, cols, rows = wing
    cell_mat = material(name + '_cells', (0.5, 0.53, 0.62), 0.05, 0.16, cells_texture(cols, rows, seed=seed))
    back_mat = material(name + '_back', (0.8, 0.8, 0.8), 0.0, 0.55, back_texture(cols, rows))
    hy = by / 2 + 0.1                                             # hinge line sits just above the antenna face
    th = 0.024
    for side, s in (('L', -1), ('R', 1)):
        x0 = s * bx / 2
        zb = bz * 0.16
        # the linkage: clevis posts on the bus edge, a hinge, then a strut frame across the gap to the root yoke
        lk = Mesh()
        lk.add(Mesh().cyl(0.035, zb * 2 + 0.2, seg=10), rot('x', math.pi / 2), (0, 0, -(zb + 0.1)))   # hinge pin
        def rod(p, q, r):
            p, q = np.array(p, 'f8'), np.array(q, 'f8')
            d = q - p; L = float(np.linalg.norm(d)); d /= L
            # rotate +y onto d
            ax = np.cross([0, 1, 0], d); sn = float(np.linalg.norm(ax)); cs = float(d[1])
            if sn < 1e-9: R = np.eye(3) if cs > 0 else rot('x', math.pi)
            else:
                ax /= sn; K = np.array([[0, -ax[2], ax[1]], [ax[2], 0, -ax[0]], [-ax[1], ax[0], 0]])
                R = np.eye(3) + sn * K + (1 - cs) * (K @ K)
            lk.add(Mesh().cyl(r, L, seg=8), R, tuple(p))
        bx_, yo = s * boom, chord * 0.42
        rod((0, 0, -zb), (bx_, 0, -yo), 0.03)                     # the two diverging struts
        rod((0, 0, zb), (bx_, 0, yo), 0.03)
        rod((0, 0, -zb), (bx_, 0, yo * 0.35), 0.018)              # cross bracing
        rod((0, 0, zb), (bx_, 0, -yo * 0.35), 0.018)
        rod((0, 0, 0), (bx_, 0, 0), 0.04)                         # central drive / harness tube
        rod((bx_, 0, -chord / 2), (bx_, 0, chord / 2), 0.035)     # root yoke the array hangs from
        lk.box(bx_ * 0.55, 0, 0, 0.16, 0.08, 0.16)                # harness box on the tube
        link = node(f'{name}_lk{side}', mesh(f'{name}_lk{side}', [(lk, SILVER)]), (x0, hy, 0), {'link': side})
        # one panel: cells up, backing down, thin edge; the piano hinge sits in the gap at the joint
        cells, back, hinge = Mesh(), Mesh(), Mesh()
        xa, xb = s * gap, s * (gap + ml)
        lo, hi = min(xa, xb), max(xa, xb)
        z0, z1 = -chord / 2, chord / 2
        cells.quad((lo, th / 2, z1), (hi, th / 2, z1), (hi, th / 2, z0), (lo, th / 2, z0), (0, 1, 0), ((0, 0), (0, 1), (1, 1), (1, 0)))
        back.quad((lo, -th / 2, z0), (hi, -th / 2, z0), (hi, -th / 2, z1), (lo, -th / 2, z1), (0, -1, 0), ((1, 0), (1, 1), (0, 1), (0, 0)))
        hinge.box((lo + hi) / 2, 0, z1, ml, th, 0.012); hinge.box((lo + hi) / 2, 0, z0, ml, th, 0.012)
        hinge.box(lo, 0, 0, 0.012, th, chord); hinge.box(hi, 0, 0, 0.012, th, chord)
        k = 9
        for q in range(k):                                        # hinge knuckles
            hinge.box(s * gap / 2, 0, z0 + chord * (q + 0.5) / k, gap, 0.035, chord / k * 0.55)
        mi = mesh(f'{name}_{side}', [(cells, cell_mat), (back, back_mat), (hinge, SILVER)])
        parent, first = None, None
        for i in range(mods):
            t = (s * boom, 0, 0) if i == 0 else (s * (gap + ml), 0, 0)
            j = node(f'{name}_w{side}{i}', mi, t, {'wing': side, 'i': i, 'n': mods})
            if parent is None:
                first = j
            else:
                G['nodes'][parent].setdefault('children', []).append(j)
            parent = j
        G['nodes'][link]['children'] = [first]
        nodes.append(link)
    # optical inter-satellite link terminals: anchors at the four corner pods' lenses, for the saver's laser beams
    k = 0
    for sx_ in (-1, 1):
        for sz_ in (-1, 1):
            nodes.append(node(f'{name}_lz{k}', None, (sx_ * (bx / 2 - 0.2), 0, sz_ * (bz / 2 + 0.24)), {'laser': k}))
            k += 1
    root = node(name, None, (0, 0, 0), {'sat': name}, nodes)
    G['scenes'][0]['nodes'].append(root)


def satellite15(name='V15', seed=4):
    """V1.5: a small flat bus (~2.8 x 1.3 m) with a single long array (~8 x 2.6 m) trailing from its rear edge on a
    short boom, two bright white laser terminals on diagonally opposite corners and a pair of small dishes.
    The array is a chain of eight hinged segments (extras {inch: i, n}) so the saver can arch it like an inchworm:
    joints turn about local x, a positive angle lifting everything behind it."""
    bx, by, bz = 1.3, 0.18, 2.8
    nodes = []
    ch, top, white, metal, dish, lens = Mesh(), Mesh(), Mesh(), Mesh(), Mesh(), Mesh()
    ch.box(0, 0, 0, bx, by, bz)
    DECK = material(name + '_deck', (0.72, 0.72, 0.72), 0.3, 0.5, deck_texture(bx, bz, [
        ('ku', -0.3, -0.75, 0.55, 0.55), ('ku', 0.3, -0.75, 0.55, 0.55), ('ku', -0.3, 0.0, 0.55, 0.55), ('ku', 0.3, 0.0, 0.55, 0.55),
        ('dark', 0, 0.85, 1.1, 0.7)]))
    top.box(0, by / 2 + 0.012, 0, bx * 0.97, 0.024, bz * 0.98, top_uv=((0, 1), (1, 1), (1, 0), (0, 0)), bottom=False)
    metal.box(0, -by / 2 - 0.012, 0, bx * 0.85, 0.024, bz * 0.85)
    for k in (-1, 1):
        metal.box(k * bx / 2, 0, 0, 0.05, by + 0.04, bz + 0.03)
    # the two bright white laser terminals, on diagonally opposite corners: a squat drum with a domed cap
    term = []
    for sx_, sz_ in ((1, 1), (-1, -1)):
        x, z = sx_ * (bx / 2 + 0.06), sz_ * (bz / 2 - 0.12)
        white.add(Mesh().cyl(0.17, 0.2, seg=18), None, (x, by / 2, z))
        white.add(Mesh().cyl(0.17, 0.09, seg=18, r2=0.07), None, (x, by / 2 + 0.2, z))
        lens.add(Mesh().cyl(0.06, 0.03, seg=12), rot('z', -sx_ * math.pi / 2), (x + sx_ * 0.16, by / 2 + 0.12, z))
        term.append((x + sx_ * 0.2, by / 2 + 0.14, z))
    # small gimballed dishes at the other two corners
    for sx_, sz_ in ((-1, 1), (1, -1)):
        w, m = gimbal_dish(0.2, 'x', sz_ * 0.4)
        dish.add(w, None, (sx_ * (bx / 2 - 0.18), by / 2, sz_ * (bz / 2 + 0.12)))
        metal.add(m, None, (sx_ * (bx / 2 - 0.18), by / 2, sz_ * (bz / 2 + 0.12)))
    # the boom off the rear edge to the array's root hinge
    hy, hz = by / 2 + 0.08, -bz / 2 - 0.45
    for zz in (-bz / 2 - 0.05, hz):
        metal.box(0, (by / 2 + hy) / 2 if zz > hz else hy, zz, 0.12, (hy - by / 2 + 0.06) if zz > hz else 0.07, 0.1)
    metal.box(0, hy, (-bz / 2 + hz) / 2, 0.07, 0.06, abs(hz + bz / 2))
    metal.box(0, hy, hz, 2.6, 0.05, 0.05)                                  # root yoke
    GREY = material(name + '_dish', (0.36, 0.37, 0.39), 0.6, 0.4)          # dull, so the white terminals stand out
    BRIGHT = material(name + '_term', (0.97, 0.97, 0.97), 0.1, 0.25)
    nodes.append(node(name + '_bus', mesh(name + '_bus', [(ch, CHASSIS), (top, DECK), (white, BRIGHT), (metal, SILVER),
                                                             (dish, GREY), (lens, LENS)])))
    for k, p in enumerate(term):
        nodes.append(node(f'{name}_lz{k}', None, p, {'laser': k}))
    # the array: eight segments, each 1.0 m long (along -z) by 2.6 m wide, cells up
    n, L, gap, chord = 8, 1.0, 0.04, 2.6
    cell_mat = material(name + '_cells', (0.5, 0.53, 0.62), 0.05, 0.16, cells_texture(13, 5, seed=seed))
    back_mat = material(name + '_back', (0.8, 0.8, 0.8), 0.0, 0.55, back_texture(13, 5))
    th = 0.02
    cells, back, hinge = Mesh(), Mesh(), Mesh()
    x0, x1, zA, zB = -chord / 2, chord / 2, -gap, -gap - L
    cells.quad((x0, th / 2, zA), (x1, th / 2, zA), (x1, th / 2, zB), (x0, th / 2, zB), (0, 1, 0), ((0, 0), (1, 0), (1, 1), (0, 1)))
    back.quad((x0, -th / 2, zB), (x1, -th / 2, zB), (x1, -th / 2, zA), (x0, -th / 2, zA), (0, -1, 0), ((0, 1), (1, 1), (1, 0), (0, 0)))
    hinge.box(x0, 0, (zA + zB) / 2, 0.012, th, L); hinge.box(x1, 0, (zA + zB) / 2, 0.012, th, L)
    hinge.box(0, 0, zB, chord, th, 0.012)
    for q in range(7):
        hinge.box(x0 + chord * (q + 0.5) / 7, 0, -gap / 2, chord / 7 * 0.55, 0.03, gap)
    mi = mesh(f'{name}_seg', [(cells, cell_mat), (back, back_mat), (hinge, SILVER)])
    parent, first = None, None
    for i in range(n):
        t = (0, hy, hz) if i == 0 else (0, 0, -(gap + L))
        j = node(f'{name}_s{i}', mi, t, {'inch': i, 'n': n})
        if parent is None: first = j
        else: G['nodes'][parent].setdefault('children', []).append(j)
        parent = j
    nodes.append(first)
    G['scenes'][0]['nodes'].append(node(name, None, (0, 0, 0), {'sat': name}, nodes))


satellite15()

# V2 (the "V2 Mini" class flown on Falcon 9): ~4.1 x 2.7 m flat bus, two ~12.8 x 4.1 m arrays
satellite('V2', bus=(2.7, 0.24, 4.1),
          deck=[('ku', -0.62, -1.3, 1.2, 1.2), ('ku', -0.62, 0.0, 1.2, 1.2), ('ku', -0.62, 1.3, 1.2, 1.2),
                ('dark', 0.72, -1.05, 1.0, 1.7), ('mirror', 0.72, 0.55, 1.0, 1.1), ('ku', 0.72, 1.5, 0.8, 0.6),
                ('pad', -1.2, -1.9, 0.16, 0.16), ('pad', 1.2, -1.9, 0.16, 0.16), ('pad', -1.2, 1.9, 0.16, 0.16), ('pad', 1.2, 1.9, 0.16, 0.16)],
          dishes=[(-0.75, 1, 0.36), (0.75, 1, 0.36), (0.6, -1, 0.3)],
          boom=1.3, wing=(10, 1.25, 4.0, 0.05, 24, 7), seed=2)
# V3 (Starship-launched): a far larger bus and arrays, bigger phased arrays and more backhaul dishes
satellite('V3', bus=(3.6, 0.34, 7.0),
          deck=[('ku', -0.85, -2.5, 1.6, 1.6), ('ku', -0.85, -0.83, 1.6, 1.6), ('ku', -0.85, 0.83, 1.6, 1.6), ('ku', -0.85, 2.5, 1.6, 1.6),
                ('ku', 0.9, -2.3, 1.5, 2.0), ('dark', 0.9, -0.2, 1.5, 2.0), ('mirror', 0.9, 1.55, 1.5, 1.3), ('ku', 0.9, 2.85, 1.5, 1.0),
                ('pad', -1.65, -3.3, 0.2, 0.2), ('pad', 1.65, -3.3, 0.2, 0.2), ('pad', -1.65, 3.3, 0.2, 0.2), ('pad', 1.65, 3.3, 0.2, 0.2),
                ('pad', -1.65, 0, 0.2, 0.2), ('pad', 1.65, 0, 0.2, 0.2)],
          dishes=[(-1.1, 1, 0.55), (1.1, 1, 0.55), (-1.1, -1, 0.55), (1.1, -1, 0.55), (0, 1, 0.34)],
          boom=1.75, wing=(12, 1.5, 6.8, 0.05, 40, 8), seed=3)

js = json.dumps(G, separators=(',', ':')).encode()
G['buffers'][0:] = [{'byteLength': len(BIN)}]
js = json.dumps(G, separators=(',', ':')).encode()
js += b' ' * ((4 - len(js) % 4) % 4)
while len(BIN) % 4: BIN.append(0)
body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(BIN), 0x004E4942) + bytes(BIN)
open(OUT, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
print(f'{OUT}: {len(G["nodes"])} nodes, {len(G["meshes"])} meshes, {12 + len(body) / 1024:.0f} KB')
