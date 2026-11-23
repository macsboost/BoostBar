#!/usr/bin/env python3
"""Bake the X1 SkyRacer + each livery into a ready-to-draw GLB for the native (SceneKit) screen saver.

A port of what the web saver does at load time (saver.js, itself ported from the sim's 30_livery.js), done once at
build time so the native renderer only has to load plain glTF:
  - wings deployed: the 'Fold' animation's first frame is written into the node transforms (rotors excluded)
  - Tank_ / Engine_ / Firewall parts dropped; the canopy gets a tinted glass material
  - the livery's side-projected base map goes on the 'Livery' material; the flank panels get UVs into it
  - recolours on Paint_White / Paint_Red parts
  - decals become their own meshes (children of the part they sit on), pushed out a hair to avoid z-fighting
UVs here use glTF's convention (v = 0 at the top of the image).

  python3 tools/bake_liveries.py Saver/src/X1_SkyRacer.glb Saver/src/liveries.json Saver/native
"""
import base64, copy, json, math, os, re, struct, sys
import numpy as np

SRC, LIVS, OUT = sys.argv[1:4]
raw = open(SRC, 'rb').read()
jl = struct.unpack('<I', raw[12:16])[0]
J0 = json.loads(raw[20:20 + jl])
BIN0 = raw[20 + jl + 8:]
CT = {5120: 'i1', 5121: 'u1', 5122: '<i2', 5123: '<u2', 5125: '<u4', 5126: '<f4'}
NC = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}
MM = 1000.0


def acc(J, BIN, i):
    a = J['accessors'][i]; bv = J['bufferViews'][a['bufferView']]
    n = NC[a['type']]; dt = np.dtype(CT[a['componentType']])
    stride = bv.get('byteStride', 0) or dt.itemsize * n
    off = bv.get('byteOffset', 0) + a.get('byteOffset', 0)
    if stride == dt.itemsize * n:
        return np.frombuffer(BIN, dtype=dt, count=a['count'] * n, offset=off).reshape(a['count'], n).astype('f8' if dt.kind == 'f' else 'i8')
    out = np.empty((a['count'], n))
    for k in range(a['count']):
        out[k] = np.frombuffer(BIN, dtype=dt, count=n, offset=off + k * stride)
    return out


def quat_mat(q):
    x, y, z, w = q
    return np.array([[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
                     [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
                     [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)]])


def local_mat(n):
    if 'matrix' in n:
        return np.array(n['matrix']).reshape(4, 4).T
    M = np.eye(4)
    S = np.diag(n.get('scale', [1, 1, 1]))
    M[:3, :3] = quat_mat(n.get('rotation', [0, 0, 0, 1])) @ S
    M[:3, 3] = n.get('translation', [0, 0, 0])
    return M


def data_url_bytes(u):
    return base64.b64decode(u.split(',', 1)[1])


def bake(L):
    J = copy.deepcopy(J0)
    BIN = bytearray(BIN0)

    def add_view(data, target=None):
        while len(BIN) % 4: BIN.append(0)
        v = {'buffer': 0, 'byteOffset': len(BIN), 'byteLength': len(data)}
        if target: v['target'] = target
        BIN.extend(data); J['bufferViews'].append(v); return len(J['bufferViews']) - 1

    def add_acc(arr, typ):
        arr = np.ascontiguousarray(arr, dtype='<f4')
        a = {'bufferView': add_view(arr.tobytes(), 34962), 'componentType': 5126, 'count': len(arr), 'type': typ}
        if typ == 'VEC3': a['min'] = arr.min(0).tolist(); a['max'] = arr.max(0).tolist()
        J['accessors'].append(a); return len(J['accessors']) - 1

    def add_image(png):
        J.setdefault('images', []).append({'bufferView': add_view(png), 'mimeType': 'image/png'})
        J.setdefault('samplers', [{'magFilter': 9729, 'minFilter': 9987}])
        J.setdefault('textures', []).append({'sampler': 0, 'source': len(J['images']) - 1})
        return len(J['textures']) - 1

    def add_mat(m):
        J['materials'].append(m); return len(J['materials']) - 1

    nodes = J['nodes']
    names = [n.get('name', '') for n in nodes]

    # 1. Fold animation, first frame (wings deployed); rotors keep their own pose
    for an in J.get('animations', []):
        if an.get('name') != 'Fold': continue
        for ch in an['channels']:
            ni = ch['target'].get('node'); path = ch['target']['path']
            if ni is None or re.match(r'Rotor_', names[ni]): continue
            s = an['samplers'][ch['sampler']]
            v = acc(J, BIN, s['output'])[0]
            nodes[ni][path] = [float(x) for x in v]
            nodes[ni].pop('matrix', None)
    J.pop('animations', None)

    # world matrices
    parent = {}
    for i, n in enumerate(nodes):
        for c in n.get('children', []): parent[c] = i
    world = {}
    def W(i):
        if i not in world:
            world[i] = (W(parent[i]) if i in parent else np.eye(4)) @ local_mat(nodes[i])
        return world[i]

    # 2. hidden parts, canopy glass, double-sided opaque materials
    for i, n in enumerate(nodes):
        if re.match(r'^(Tank_|Engine_|Firewall)', names[i]): n.pop('mesh', None)
    for m in J['materials']:
        if m.get('alphaMode') != 'BLEND': m['doubleSided'] = True
    glass = add_mat({'name': 'CanopyGlass', 'alphaMode': 'BLEND', 'doubleSided': True,
                     'pbrMetallicRoughness': {'baseColorFactor': [0.159, 0.254, 0.352, 0.55], 'metallicFactor': 0.2, 'roughnessFactor': 0.05}})

    meshes_used = {}
    for i, n in enumerate(nodes):
        if 'mesh' in n: meshes_used.setdefault(n['mesh'], []).append(i)
    def own_mesh(i):
        """Give node i its own copy of its mesh (so per-part changes don't leak to others)."""
        mi = nodes[i]['mesh']
        if len(meshes_used[mi]) > 1:
            J['meshes'].append(copy.deepcopy(J['meshes'][mi]))
            meshes_used[mi].remove(i)
            nodes[i]['mesh'] = len(J['meshes']) - 1
            meshes_used[nodes[i]['mesh']] = [i]
        return J['meshes'][nodes[i]['mesh']]

    mat_name = [m.get('name', '') for m in J['materials']]
    livery_mat = mat_name.index('Livery') if 'Livery' in mat_name else None
    if livery_mat is not None:
        J['materials'][livery_mat]['pbrMetallicRoughness']['baseColorTexture'] = {'index': add_image(data_url_bytes(L['base']))}

    for i, n in enumerate(nodes):
        if 'mesh' not in n: continue
        part = names[i]
        if part == 'Canopy':
            for p in own_mesh(i)['primitives']: p['material'] = glass
        if re.match(r'^Flank_Swoosh_[LR]$', part) and livery_mat is not None:
            Mw = W(i)
            for p in own_mesh(i)['primitives']:
                P = acc(J, BIN, p['attributes']['POSITION'])
                Pw = (Mw[:3, :3] @ P.T).T + Mw[:3, 3]
                uv = np.stack([0.5 - 0.178571 * Pw[:, 2], 1.263158 - 1.052632 * Pw[:, 1]], 1)
                p['attributes']['TEXCOORD_0'] = add_acc(uv, 'VEC2')
                p['material'] = livery_mat
        # recolours
        for rx, paint, hexc in L['recolor']:
            if not re.search(rx, part): continue
            want = 'Paint_Red' if paint == 'red' else 'Paint_White'
            for p in own_mesh(i)['primitives']:
                if mat_name[p['material']] if p['material'] < len(mat_name) else None != want: pass
                if p['material'] < len(mat_name) and mat_name[p['material']] == want:
                    m = copy.deepcopy(J['materials'][p['material']])
                    c = [int(hexc[k:k + 2], 16) / 255 for k in (1, 3, 5)]
                    lin = [(x / 12.92) if x <= 0.04045 else ((x + 0.055) / 1.055) ** 2.4 for x in c]
                    m['pbrMetallicRoughness']['baseColorFactor'] = lin + [1]
                    m['name'] = want + '_' + hexc
                    p['material'] = add_mat(m)
            # (first matching rule per paint wins, like the web saver: stop after one hit per paint)
        mat_name = [m.get('name', '') for m in J['materials']]

    # 3. decals
    def tri_data(i, p):
        P = acc(J, BIN, p['attributes']['POSITION'])
        idx = acc(J, BIN, p['indices']).reshape(-1) if 'indices' in p else np.arange(len(P))
        loc = P[idx]
        Mw = W(i)
        Pw = (Mw[:3, :3] @ loc.T).T + Mw[:3, 3]
        mm = np.stack([Pw[:, 0] * MM, -Pw[:, 2] * MM, Pw[:, 1] * MM], 1)
        return loc, mm

    sill = None
    if 'Canopy' in names:
        ci = names.index('Canopy')
        if 'mesh' in nodes[ci]:
            by = {}
            for p in J['meshes'][nodes[ci]['mesh']]['primitives']:
                _, mm = tri_data(ci, p)
                for x, y, z in mm:
                    k = round(y / 10) * 10
                    r = by.setdefault(k, [0, 0.0, 1e9])
                    r[0] += 1; r[1] = max(r[1], abs(x)); r[2] = min(r[2], z)
            S = sorted([(y, r[1], r[2]) for y, r in by.items() if r[0] >= 6])
            sill = S if len(S) > 1 else None

    def under_glass(x, y, z):
        if not sill or y < sill[0][0] or y > sill[-1][0]: return False
        k = 1
        while k < len(sill) - 1 and sill[k][0] < y: k += 1
        a, b = sill[k - 1], sill[k]
        t = (y - a[0]) / ((b[0] - a[0]) or 1)
        hw = a[1] + (b[1] - a[1]) * t; sz = a[2] + (b[2] - a[2]) * t
        return abs(x) < hw + 15 and z > sz - 10

    decal_tex = {}
    decal_mat = {}
    for i in range(len(nodes)):
        n = nodes[i]
        if 'mesh' not in n: continue
        part = names[i]
        lst = [d for d in L['decals'] if re.search(d['parts'], part)]
        if not lst: continue
        right = bool(re.search(r'_R$', part))
        for p in J['meshes'][n['mesh']]['primitives']:
            if p.get('mode', 4) != 4: continue
            loc, q = tri_data(i, p)
            nt = len(q) // 3
            c = q.mean(0)
            A = q[0::3] - c; B = q[1::3] - c; E = q[2::3] - c
            vol = np.sum(A[:, 0] * (B[:, 1] * E[:, 2] - B[:, 2] * E[:, 1]) - A[:, 1] * (B[:, 0] * E[:, 2] - B[:, 2] * E[:, 0]) + A[:, 2] * (B[:, 0] * E[:, 1] - B[:, 1] * E[:, 0]))
            out = -1 if vol < 0 else 1
            for d in lst:
                b = d['box']
                x0 = (-b['x'][1] if right else b['x'][0]) if 'x' in b else 0
                x1 = (-b['x'][0] if right else b['x'][1]) if 'x' in b else 0
                ps, us = [], []
                for f in range(nt):
                    vv = q[f * 3:f * 3 + 3]
                    nrm = np.cross(vv[1] - vv[0], vv[2] - vv[0])
                    ln = np.linalg.norm(nrm)
                    if ln < 1e-9: continue
                    nrm = nrm * out / ln
                    if d['proj'] == 'side':
                        if abs(nrm[0]) < d['nmin']: continue
                        sd = 1 if nrm[0] > 0 else -1
                        uv = [((pp[1] - b['y'][0]) / (b['y'][1] - b['y'][0]) if sd > 0 else (b['y'][1] - pp[1]) / (b['y'][1] - b['y'][0]),
                               (pp[2] - b['z'][0]) / (b['z'][1] - b['z'][0])) for pp in vv]
                    elif d['proj'] == 'top':
                        if nrm[2] < d['nmin']: continue
                        uv = [((x1 - pp[0]) / (x1 - x0), (b['y'][1] - pp[1]) / (b['y'][1] - b['y'][0])) for pp in vv]
                    elif d['proj'] == 'top-out':
                        if nrm[2] < d['nmin']: continue
                        uv = [((b['y'][1] - pp[1]) / (b['y'][1] - b['y'][0]), (pp[0] - x0) / (x1 - x0)) if right else
                              ((pp[1] - b['y'][0]) / (b['y'][1] - b['y'][0]), (x1 - pp[0]) / (x1 - x0)) for pp in vv]
                    else:
                        if nrm[2] > -d['nmin']: continue
                        uv = [((pp[0] - b['x'][0]) / (b['x'][1] - b['x'][0]), (b['y'][1] - pp[1]) / (b['y'][1] - b['y'][0])) for pp in vv]
                    if all(t[0] < 0 for t in uv) or all(t[0] > 1 for t in uv) or all(t[1] < 0 for t in uv) or all(t[1] > 1 for t in uv):
                        continue
                    if d.get('clear_glass') and not part.startswith('Canopy'):
                        m = vv.mean(0)
                        if under_glass(*m): continue
                    lv = loc[f * 3:f * 3 + 3]
                    ln_loc = np.cross(lv[1] - lv[0], lv[2] - lv[0]); ll = np.linalg.norm(ln_loc)
                    push = (ln_loc / ll * out * 0.0025) if ll > 1e-12 else 0
                    for k in ([0, 1, 2] if out > 0 else [0, 2, 1]):
                        ps.append(lv[k] + push)
                        us.append((uv[k][0], 1 - uv[k][1]))   # web uses flipY=true for decals
                if not ps: continue
                P = np.array(ps)
                N = np.zeros_like(P)
                for f in range(0, len(P), 3):
                    nn = np.cross(P[f + 1] - P[f], P[f + 2] - P[f]); l = np.linalg.norm(nn)
                    N[f:f + 3] = nn / l if l > 0 else [0, 1, 0]
                if d['id'] not in decal_mat:
                    if d['png'] not in decal_tex: decal_tex[d['png']] = add_image(data_url_bytes(d['png']))
                    decal_mat[d['id']] = add_mat({'name': 'Decal_' + d['id'], 'alphaMode': 'BLEND', 'doubleSided': True,
                        'extras': {'decal': True},
                        'pbrMetallicRoughness': {'baseColorTexture': {'index': decal_tex[d['png']]}, 'metallicFactor': 0, 'roughnessFactor': 0.35}})
                J['meshes'].append({'name': f'{part}_{d["id"]}', 'primitives': [{
                    'attributes': {'POSITION': add_acc(P, 'VEC3'), 'NORMAL': add_acc(N, 'VEC3'), 'TEXCOORD_0': add_acc(np.array(us), 'VEC2')},
                    'material': decal_mat[d['id']]}]})
                nodes.append({'name': f'{part}__decal_{d["id"]}', 'mesh': len(J['meshes']) - 1, 'extras': {'decal': True}})
                n.setdefault('children', []).append(len(nodes) - 1)

    J['buffers'] = [{'byteLength': len(BIN)}]
    js = json.dumps(J, separators=(',', ':')).encode()
    js += b' ' * ((4 - len(js) % 4) % 4)
    while len(BIN) % 4: BIN.append(0)
    body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(BIN), 0x004E4942) + bytes(BIN)
    path = os.path.join(OUT, f'X1_{L["id"]}.glb')
    open(path, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
    print(f'{path}: {len(nodes)} nodes, {len(decal_mat)} decals, {(12 + len(body)) // 1024} KB')


os.makedirs(OUT, exist_ok=True)
for L in json.load(open(LIVS)):
    bake(L)
