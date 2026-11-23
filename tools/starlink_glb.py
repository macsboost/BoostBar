#!/usr/bin/env python3
"""Build stylised Starlink V2 and V3 satellites as one GLB for the BoostBar Starlink screen saver.

Modelled from the general layout of the public V1.5 / V2 / V3 comparison art (not traced): a flat silver bus with
dark panels on top, parabolic antennas at the corners, short booms out to two long solar wings. Each wing is a
chain of modules hinged to each other so the page can bend it like a bird's wing:

  scene nodes   V2, V3                      (roots; the page clones one per satellite)
    bus, dishes, booms                      (rigid)
    wL0 -> wL1 -> ... ,  wR0 -> wR1 -> ...  joint nodes, each placed on its hinge line; extras {wing: 'L'|'R', i}
       each joint carries one module mesh   (span along x, chord along z, cells face +y)

Frame: metres, +y up (the cells face up), +z forward (direction of flight, broadside like a bird), span along x.
Joint rotation about its local z lifts (R wing) / lowers (L wing) the outboard part; the page mirrors the sign.

  python3 tools/starlink_glb.py Saver/src/Starlink.glb
"""
import io, json, math, struct, sys
import numpy as np
from PIL import Image, ImageDraw

OUT = sys.argv[1]

# ---------------------------------------------------------------- geometry helpers
class Mesh:
    def __init__(self):
        self.p, self.n, self.uv, self.i = [], [], [], []

    def quad(self, a, b, c, d, n, uv=((0, 0), (1, 0), (1, 1), (0, 1))):
        k = len(self.p)
        self.p += [a, b, c, d]; self.n += [n] * 4; self.uv += list(uv)
        self.i += [k, k + 1, k + 2, k, k + 2, k + 3]

    def box(self, cx, cy, cz, sx, sy, sz, top_uv=None):
        x0, x1 = cx - sx / 2, cx + sx / 2
        y0, y1 = cy - sy / 2, cy + sy / 2
        z0, z1 = cz - sz / 2, cz + sz / 2
        t = top_uv or ((0, 0), (1, 0), (1, 1), (0, 1))
        self.quad((x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0), (0, 1, 0), t)        # top
        self.quad((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1), (0, -1, 0), t)       # bottom
        self.quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1), (0, 0, 1))            # front
        self.quad((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0), (0, 0, -1))           # back
        self.quad((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1), (1, 0, 0))            # right
        self.quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0), (-1, 0, 0))           # left

    def dish(self, cx, cy, cz, r, depth, up=1, seg=20, rings=4):
        """A shallow parabolic dish opening toward +y*up, with a small feed post."""
        k0 = len(self.p)
        grid = []
        for j in range(rings + 1):
            rr = r * j / rings
            row = []
            for s in range(seg + 1):
                a = 2 * math.pi * s / seg
                x, z = cx + rr * math.cos(a), cz + rr * math.sin(a)
                y = cy + up * depth * (rr / r) ** 2
                nx, ny, nz = -2 * depth * rr / r ** 2 * math.cos(a), up, -2 * depth * rr / r ** 2 * math.sin(a)
                L = math.sqrt(nx * nx + ny * ny + nz * nz)
                row.append(len(self.p)); self.p.append((x, y, z)); self.n.append((nx / L, ny / L, nz / L)); self.uv.append((0.5, 0.5))
            grid.append(row)
        for j in range(rings):
            for s in range(seg):
                a, b, c, d = grid[j][s], grid[j][s + 1], grid[j + 1][s + 1], grid[j + 1][s]
                self.i += ([a, b, c, a, c, d] if up > 0 else [a, c, b, a, d, c])
        self.box(cx, cy + up * depth * 0.9, cz, r * 0.12, depth * 1.6, r * 0.12)

    def arrays(self):
        return (np.array(self.p, 'f4'), np.array(self.n, 'f4'), np.array(self.uv, 'f4'), np.array(self.i, 'u4'))


# ---------------------------------------------------------------- textures
def cells_texture(cols, rows, px=64):
    """One wing module: dark blue cells, thin light gaps, a silver frame."""
    W, H = cols * px, rows * px
    im = Image.new('RGB', (W, H), (170, 176, 186))
    d = ImageDraw.Draw(im)
    for c in range(cols):
        for r in range(rows):
            x0, y0 = c * px + 3, r * px + 3
            d.rectangle([x0, y0, x0 + px - 7, y0 + px - 7], fill=(34, 52, 92))
            # faint diagonal sheen
            d.line([x0 + 4, y0 + px - 12, x0 + px - 12, y0 + 4], fill=(52, 74, 122), width=2)
    d.rectangle([0, 0, W - 1, H - 1], outline=(205, 210, 218), width=4)
    return im


def bus_texture():
    """Top of the bus: two dark solar-ish plates with silver borders and a seam."""
    im = Image.new('RGB', (512, 256), (150, 154, 160))
    d = ImageDraw.Draw(im)
    for x0 in (12, 262):
        d.rectangle([x0, 14, x0 + 238, 242], fill=(42, 44, 50))
        for k in range(1, 6):
            d.line([x0, 14 + k * 38, x0 + 238, 14 + k * 38], fill=(70, 72, 80), width=2)
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


SILVER = material('silver', (0.78, 0.80, 0.83), 0.85, 0.3)
DARK = material('dark', (0.18, 0.19, 0.21), 0.5, 0.45)
BUS_TOP = material('busTop', (1, 1, 1), 0.55, 0.4, bus_texture())


def satellite(name, bus, dishes, boom, wing):
    """bus (sx, sy, sz); dishes [(x, z, r, up)]; boom length; wing (modules, module_len, chord, gap, cols, rows)."""
    bx, by, bz = bus
    nodes = []
    # bus: silver box with the textured top plate, a darker underside slab and edge greebles
    b = Mesh(); b.box(0, 0, 0, bx, by, bz)
    top = Mesh(); top.box(0, by / 2 + 0.02, 0, bx * 0.96, 0.04, bz * 0.92)
    under = Mesh(); under.box(0, -by / 2 - 0.05, 0, bx * 0.8, 0.1, bz * 0.7)
    rng = np.random.default_rng(len(name) * 97 + int(bx * 10))
    for _ in range(int(bx * 6)):
        side = rng.choice([-1, 1])
        x = rng.uniform(-bx / 2, bx / 2)
        under.box(x, -by / 2 + rng.uniform(-0.05, 0.1), side * (bz / 2 + 0.06), rng.uniform(0.15, 0.4), rng.uniform(0.1, 0.3), 0.12)
    d = Mesh()
    for x, z, r, up in dishes:
        d.dish(x, (by / 2 + 0.05) * up, z, r, r * 0.35, up)
        d.box(x, (by / 2) * up, z, r * 0.25, 0.25, r * 0.25)
    nodes.append(node(name + '_bus', mesh(name + '_bus', [(b, SILVER), (top, BUS_TOP), (under, DARK), (d, SILVER)])))

    mods, ml, chord, gap, cols, rows = wing
    cell_mat = material(name + '_cells', (0.85, 0.88, 0.95), 0.6, 0.28, cells_texture(cols, rows))
    for side, s in (('L', -1), ('R', 1)):
        # boom from the bus edge to the first hinge
        bm = Mesh()
        x0 = s * bx / 2
        for zz in (-chord * 0.18, chord * 0.18):
            bm.box(x0 + s * boom / 2, 0, zz, boom, 0.06, 0.06)
        bm.box(x0 + s * boom, 0, 0, 0.1, 0.1, chord * 0.5)  # yoke
        nodes.append(node(f'{name}_boom{side}', mesh(f'{name}_boom{side}', [(bm, SILVER)])))
        # the wing: a chain of joints, each holding one module that starts just past its hinge
        parent = None
        first = None
        for i in range(mods):
            m = Mesh()
            cx = s * (gap + ml / 2)
            uv = ((0, 1), (1, 1), (1, 0), (0, 0)) if s > 0 else ((1, 1), (0, 1), (0, 0), (1, 0))
            m.box(cx, 0, 0, ml, 0.05, chord, top_uv=uv)
            hinge = Mesh()  # little hinge barrel bridging the gap
            hinge.box(s * gap / 2, 0, -chord * 0.3, gap + 0.06, 0.07, 0.12)
            hinge.box(s * gap / 2, 0, chord * 0.3, gap + 0.06, 0.07, 0.12)
            mi = mesh(f'{name}_{side}{i}', [(m, cell_mat), (hinge, SILVER)])
            t = (x0 + s * boom, 0, 0) if i == 0 else (s * (gap + ml), 0, 0)
            j = node(f'{name}_w{side}{i}', mi, t, {'wing': side, 'i': i, 'n': mods})
            if parent is None:
                first = j
            else:
                G['nodes'][parent].setdefault('children', []).append(j)
            parent = j
        nodes.append(first)
    root = node(name, None, (0, 0, 0), {'sat': name}, nodes)
    G['scenes'][0]['nodes'].append(root)


# V2 (as flown, "V2 mini" class): ~4 m bus, two wings of 6 modules (~13 m each)
satellite('V2', bus=(4.2, 0.35, 2.8),
          dishes=[(-1.5, 1.6, 0.42, -1), (1.5, 1.6, 0.42, -1), (-1.5, -1.6, 0.42, -1), (1.5, -1.6, 0.42, -1)],
          boom=1.6, wing=(6, 2.1, 2.6, 0.12, 8, 10))
# V3: much bigger bus with four big corner dishes on top, two wings of 11 modules (~27 m each)
satellite('V3', bus=(7.2, 0.5, 4.4),
          dishes=[(-3.2, 2.6, 0.75, 1), (3.2, 2.6, 0.75, 1), (-3.2, -2.6, 0.75, 1), (3.2, -2.6, 0.75, 1),
                  (-1.2, 2.5, 0.45, -1), (1.2, -2.5, 0.45, -1)],
          boom=2.2, wing=(11, 2.45, 3.2, 0.12, 8, 10))

js = json.dumps(G, separators=(',', ':')).encode()
G['buffers'][0:] = [{'byteLength': len(BIN)}]
js = json.dumps(G, separators=(',', ':')).encode()
js += b' ' * ((4 - len(js) % 4) % 4)
while len(BIN) % 4: BIN.append(0)
body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(BIN), 0x004E4942) + bytes(BIN)
open(OUT, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
print(f'{OUT}: {len(G["nodes"])} nodes, {len(G["meshes"])} meshes, {12 + len(body) / 1024:.0f} KB')
