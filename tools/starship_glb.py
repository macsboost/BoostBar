#!/usr/bin/env python3
"""Cut Starship (the 'ship' node and its four flap nodes) out of the X1 SkyRacer sim's Starbase pack
(X1_sim/dist/X1_SkyRacer_Starship.glb) into a small GLB for the BoostBar Starships screen saver.

The ship there is built from code by X1_sim/tools/starship/ship42.py (Ship 42, Block 3): steel hull with the
black heat shield on the windward (+z) side, nose up (+y), and four flaps, each its own node on its hinge line.
Flap node extras (kept): flap 'aft'|'fwd', s (+1/-1 side), a [stowed, belly flop, landing] degrees leeward;
the page turns each flap about its local y by s * angle. Nothing else from the pack (tower, booster) is copied.

  python3 -I tools/starship_glb.py X1_SkyRacer_Starship.glb Saver/src/Starship.glb
"""
import json, struct, sys

src, dst = sys.argv[1], sys.argv[2]
raw = open(src, 'rb').read()
jl = struct.unpack('<I', raw[12:16])[0]
J = json.loads(raw[20:20 + jl])
BIN = raw[20 + jl + 8:]

ship = next(i for i, n in enumerate(J['nodes']) if n.get('name') == 'ship')
keep = [ship] + list(J['nodes'][ship].get('children', []))
nmap = {old: new for new, old in enumerate(keep)}

meshes, mmap = [], {}
accs, amap = [], {}
views, out = [], bytearray()

def copy_acc(i):
    if i in amap: return amap[i]
    a = dict(J['accessors'][i]); bv = J['bufferViews'][a['bufferView']]
    o = bv.get('byteOffset', 0); data = BIN[o:o + bv['byteLength']]
    while len(out) % 4: out.append(0)
    nv = {'buffer': 0, 'byteOffset': len(out), 'byteLength': len(data)}
    for k in ('byteStride', 'target'):
        if k in bv: nv[k] = bv[k]
    out.extend(data)
    views.append(nv)
    a['bufferView'] = len(views) - 1
    accs.append(a)
    amap[i] = len(accs) - 1
    return amap[i]

nodes = []
for old in keep:
    n = dict(J['nodes'][old])
    if 'children' in n:
        n['children'] = [nmap[c] for c in n['children'] if c in nmap]
    if 'mesh' in n:
        m = J['meshes'][n['mesh']]
        prims = []
        for p in m['primitives']:
            q = dict(p)
            q['attributes'] = {k: copy_acc(v) for k, v in p['attributes'].items()}
            if 'indices' in p: q['indices'] = copy_acc(p['indices'])
            prims.append(q)
        meshes.append({'name': m.get('name'), 'primitives': prims})
        n['mesh'] = len(meshes) - 1
    nodes.append(n)
nodes[0]['translation'] = [0, 0, 0]

G = {'asset': {'version': '2.0', 'generator': 'BoostBar starship_glb.py',
               'extras': {'source': 'X1 SkyRacer sim, tools/starship/ship42.py (Ship 42, Block 3)'}},
     'scene': 0, 'scenes': [{'nodes': [0]}], 'nodes': nodes, 'meshes': meshes,
     'materials': J['materials'], 'accessors': accs, 'bufferViews': views,
     'buffers': [{'byteLength': len(out)}]}
js = json.dumps(G, separators=(',', ':')).encode()
js += b' ' * ((4 - len(js) % 4) % 4)
while len(out) % 4: out.append(0)
body = struct.pack('<II', len(js), 0x4E4F534A) + js + struct.pack('<II', len(out), 0x004E4942) + bytes(out)
open(dst, 'wb').write(struct.pack('<III', 0x46546C67, 2, 12 + len(body)) + body)
print(f'{dst}: {len(nodes)} nodes, {len(meshes)} meshes, {12 + len(body)} bytes')
