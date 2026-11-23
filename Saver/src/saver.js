/* BoostBar screen savers, flying-toasters style.
   scene 'cars'      BoostBar Flying Cars: X1 SkyRacers; liveries use the same format and paint logic as the
                     X1 SkyRacer Flying Car Race Sim (src/game/30_livery.js), applied per craft.
   scene 'starlink'  BoostBar Starlink: stylised Starlink V2 / V3 satellites (tools/starlink_glb.py), solar wings
                     built from hinged modules that bend like a bird's wings as they flap.
   scene 'starships' BoostBar Starships: Starship (Ship 42, from the sim's Starbase world, built from code by
                     X1_sim/tools/starship/ship42.py) with its four flaps flapping like the toasters' wings. */
(() => {
  'use strict';
  const CFG = Object.assign(
    { scene: 'cars', liveries: ['macsboost', 'yonder', 'xxone'], count: 7, speed: 1, flapSpeed: 1, stunts: true, stars: true, oxidation: 0.35, preview: false },
    window.SAVER_CONFIG || {},
  );
  const D2R = Math.PI / 180;
  // report to the screen saver (it shows a message instead of a blank screen if the scene never starts)
  function tell(msg) {
    try { window.webkit.messageHandlers.boostbar.postMessage(String(msg)); } catch (e) {}
  }
  window.addEventListener('error', (e) => tell('error: ' + (e.message || e)));
  const SCENE = window.SAVER_SCENE || CFG.scene;
  const SHIPS = SCENE === 'starships';
  const SATS = SCENE === 'starlink';
  // Angle (CFG.tilt, degrees): how far each craft is rolled about its flight path toward the viewer. Defaults:
  // cars -32° (shows the roof), Starships -11°, Starlink -66° (three-quarter top view of the wings).
  const TILT = (CFG.tilt != null && isFinite(+CFG.tilt) ? +CFG.tilt : SATS ? -66 : SHIPS ? -11.5 : -32) * (Math.PI / 180);
  const $ = (id) => document.getElementById(id);

  // ---------- renderer / scene ----------
  const renderer = new THREE.WebGLRenderer({ antialias: true, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, CFG.preview ? 1 : 2));
  renderer.setSize(innerWidth, innerHeight);
  renderer.outputEncoding = THREE.sRGBEncoding;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = SHIPS ? 0.85 : SATS ? 0.9 : 1.35;
  renderer.setClearColor(0x000000, 1);
  document.body.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(28, innerWidth / innerHeight, 1, 400);
  camera.position.set(0, 0, 52);
  camera.lookAt(0, 0, 0);
  scene.add(new THREE.HemisphereLight(0xffffff, 0x334433, 1.6));
  const sun = new THREE.DirectionalLight(0xffffff, 2.6);
  sun.position.set(-30, 40, 60);
  scene.add(sun);
  const rim = new THREE.DirectionalLight(SHIPS ? 0xffb070 : SATS ? 0x88aaff : 0x88ff66, SHIPS || SATS ? 0.7 : 0.5);
  rim.position.set(40, -20, -30);
  scene.add(rim);

  // faint starfield
  if (CFG.stars) {
    const n = 500,
      p = new Float32Array(n * 3);
    for (let i = 0; i < n; i++) {
      p[i * 3] = (Math.random() - 0.5) * 300;
      p[i * 3 + 1] = (Math.random() - 0.5) * 200;
      p[i * 3 + 2] = -120 - Math.random() * 60;
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(p, 3));
    scene.add(new THREE.Points(g, new THREE.PointsMaterial({ color: 0x8899aa, size: 0.6, sizeAttenuation: true })));
  }

  addEventListener('resize', () => {
    camera.aspect = innerWidth / innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(innerWidth, innerHeight);
  });

  // ---------- liveries (ported from the sim's 30_livery.js, per craft) ----------
  const LIVERIES = $('liveries') ? JSON.parse($('liveries').textContent) : [];
  const LIV_MM = 1000;
  const texCache = {};
  function livTexture(url, flipY) {
    const k = url.length + ':' + url.slice(-64) + flipY;
    if (texCache[k]) return texCache[k];
    const t = new THREE.TextureLoader().load(url);
    t.encoding = THREE.sRGBEncoding;
    t.flipY = !!flipY;
    t.wrapS = t.wrapT = THREE.ClampToEdgeWrapping;
    t.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
    return (texCache[k] = t);
  }
  function livPart(o) {
    return o.parent && o.parent.name && o.name.indexOf(o.parent.name) === 0 && /_\d+$/.test(o.name)
      ? o.parent.name
      : o.name;
  }
  function livTris(o, inv) {
    const g = o.geometry,
      p = g.attributes.position,
      ix = g.index,
      n = ix ? ix.count : p.count,
      M = new THREE.Matrix4().multiplyMatrices(inv, o.matrixWorld),
      v = new THREE.Vector3(),
      mm = new Float32Array(n * 3),
      loc = new Float32Array(n * 3);
    for (let k = 0; k < n; k++) {
      const i = ix ? ix.getX(k) : k;
      v.fromBufferAttribute(p, i);
      loc[k * 3] = v.x;
      loc[k * 3 + 1] = v.y;
      loc[k * 3 + 2] = v.z;
      v.applyMatrix4(M);
      mm[k * 3] = v.x * LIV_MM;
      mm[k * 3 + 1] = -v.z * LIV_MM;
      mm[k * 3 + 2] = v.y * LIV_MM;
    }
    return { mm, loc, n: n / 3 };
  }
  function canopySill(root, inv) {
    const o = root.getObjectByName('Canopy');
    if (!o) return null;
    const T = livTris(o, inv),
      by = new Map();
    for (let k = 0; k < T.n * 3; k++) {
      const y = Math.round(T.mm[k * 3 + 1] / 10) * 10;
      let r = by.get(y);
      if (!r) by.set(y, (r = { n: 0, hw: 0, z: 1e9 }));
      r.n++;
      r.hw = Math.max(r.hw, Math.abs(T.mm[k * 3]));
      r.z = Math.min(r.z, T.mm[k * 3 + 2]);
    }
    const S = [...by]
      .filter(([, r]) => r.n >= 6)
      .map(([y, r]) => [y, r.hw, r.z])
      .sort((a, b) => a[0] - b[0]);
    return S.length > 1 ? S : null;
  }
  function underGlass(S, x, y, z) {
    if (!S || y < S[0][0] || y > S[S.length - 1][0]) return false;
    let i = 1;
    while (i < S.length - 1 && S[i][0] < y) i++;
    const a = S[i - 1],
      b = S[i],
      t = (y - a[0]) / (b[0] - a[0] || 1),
      hw = a[1] + (b[1] - a[1]) * t,
      sz = a[2] + (b[2] - a[2]) * t;
    return Math.abs(x) < hw + 15 && z > sz - 10;
  }

  function applyLivery(root, L) {
    // paint: the side-projected map on the 'Livery' material, recolours on Paint_White / Paint_Red parts
    let livMat = null;
    root.traverse((o) => {
      if (o.isMesh && o.material && o.material.name === 'Livery' && !livMat) livMat = o.material;
    });
    if (livMat) {
      livMat = livMat.clone();
      livMat.map = livTexture(L.base, false);
      livMat.needsUpdate = true;
    }
    root.updateMatrixWorld(true);
    const inv = new THREE.Matrix4().copy(root.matrixWorld).invert();
    // flank panels get the body's side projection
    const M = new THREE.Matrix4(),
      v = new THREE.Vector3();
    root.traverse((o) => {
      if (!o.isMesh || !/^Flank_Swoosh_[LR]$/.test(o.name) || o.geometry.attributes.uv2done) return;
      const p = o.geometry.attributes.position,
        uv = new Float32Array(p.count * 2);
      M.multiplyMatrices(inv, o.matrixWorld);
      for (let k = 0; k < p.count; k++) {
        v.fromBufferAttribute(p, k).applyMatrix4(M);
        uv[k * 2] = 0.5 - 0.178571 * v.z;
        uv[k * 2 + 1] = 1.263158 - 1.052632 * v.y;
      }
      o.geometry = o.geometry.clone();
      o.geometry.setAttribute('uv', new THREE.BufferAttribute(uv, 2));
    });
    const rec = L.recolor.map(([re, paint, hex]) => [new RegExp(re), paint === 'red' ? 'Paint_Red' : 'Paint_White', hex]);
    const recMats = new Map();
    root.traverse((o) => {
      if (!o.isMesh || !o.material) return;
      const base = o.material,
        part = livPart(o);
      if (base.name === 'Livery' && livMat) {
        o.material = livMat;
        return;
      }
      if (/^Flank_Swoosh_[LR]$/.test(part) && livMat) {
        o.material = livMat;
        return;
      }
      for (const [re, paint, hex] of rec)
        if (re.test(part) && base.name === paint) {
          const k = base.uuid + hex;
          let m = recMats.get(k);
          if (!m) {
            m = base.clone();
            m.color.set(hex).convertSRGBToLinear();
            recMats.set(k, m);
          }
          o.material = m;
          break;
        }
    });

    // decals: separate meshes parented to the part they sit on
    const sill = canopySill(root, inv);
    const meshes = [];
    root.traverse((o) => {
      if (o.isMesh && !o.userData.decal) meshes.push(o);
    });
    const mats = {};
    for (const o of meshes) {
      const name = livPart(o),
        list = L.decals.filter((d) => new RegExp(d.parts).test(name));
      if (!list.length) continue;
      const T = livTris(o, inv),
        q = T.mm;
      let vol = 0,
        cx = 0,
        cy = 0,
        cz = 0;
      for (let k = 0; k < T.n * 3; k++) {
        cx += q[k * 3];
        cy += q[k * 3 + 1];
        cz += q[k * 3 + 2];
      }
      cx /= T.n * 3;
      cy /= T.n * 3;
      cz /= T.n * 3;
      for (let f = 0; f < T.n; f++) {
        const a = f * 9,
          ax = q[a] - cx,
          ay = q[a + 1] - cy,
          az = q[a + 2] - cz,
          bx = q[a + 3] - cx,
          by = q[a + 4] - cy,
          bz = q[a + 5] - cz,
          ex = q[a + 6] - cx,
          ey = q[a + 7] - cy,
          ez = q[a + 8] - cz;
        vol += ax * (by * ez - bz * ey) - ay * (bx * ez - bz * ex) + az * (bx * ey - by * ex);
      }
      const out = vol < 0 ? -1 : 1,
        right = /_R$/.test(name);
      for (const d of list) {
        const b = d.box,
          x0 = b.x ? (right ? -b.x[1] : b.x[0]) : 0,
          x1 = b.x ? (right ? -b.x[0] : b.x[1]) : 0,
          ps = [],
          us = [];
        for (let f = 0; f < T.n; f++) {
          const a = f * 9,
            vv = [
              [q[a], q[a + 1], q[a + 2]],
              [q[a + 3], q[a + 4], q[a + 5]],
              [q[a + 6], q[a + 7], q[a + 8]],
            ],
            e1 = [vv[1][0] - vv[0][0], vv[1][1] - vv[0][1], vv[1][2] - vv[0][2]],
            e2 = [vv[2][0] - vv[0][0], vv[2][1] - vv[0][1], vv[2][2] - vv[0][2]];
          let n = [e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0]];
          const len = Math.hypot(n[0], n[1], n[2]);
          if (len < 1e-9) continue;
          n = n.map((c) => (c * out) / len);
          let uv;
          if (d.proj === 'side') {
            if (Math.abs(n[0]) < d.nmin) continue;
            const sd = n[0] > 0 ? 1 : -1;
            uv = vv.map((p) => [
              sd > 0 ? (p[1] - b.y[0]) / (b.y[1] - b.y[0]) : (b.y[1] - p[1]) / (b.y[1] - b.y[0]),
              (p[2] - b.z[0]) / (b.z[1] - b.z[0]),
            ]);
          } else if (d.proj === 'top') {
            if (n[2] < d.nmin) continue;
            uv = vv.map((p) => [(x1 - p[0]) / (x1 - x0), (b.y[1] - p[1]) / (b.y[1] - b.y[0])]);
          } else if (d.proj === 'top-out') {
            if (n[2] < d.nmin) continue;
            uv = vv.map((p) =>
              right
                ? [(b.y[1] - p[1]) / (b.y[1] - b.y[0]), (p[0] - x0) / (x1 - x0)]
                : [(p[1] - b.y[0]) / (b.y[1] - b.y[0]), (x1 - p[0]) / (x1 - x0)],
            );
          } else {
            if (n[2] > -d.nmin) continue;
            uv = vv.map((p) => [(p[0] - b.x[0]) / (b.x[1] - b.x[0]), (b.y[1] - p[1]) / (b.y[1] - b.y[0])]);
          }
          if (
            uv.every((t) => t[0] < 0) ||
            uv.every((t) => t[0] > 1) ||
            uv.every((t) => t[1] < 0) ||
            uv.every((t) => t[1] > 1)
          )
            continue;
          if (
            d.clear_glass &&
            !/^Canopy/.test(name) &&
            underGlass(
              sill,
              (vv[0][0] + vv[1][0] + vv[2][0]) / 3,
              (vv[0][1] + vv[1][1] + vv[2][1]) / 3,
              (vv[0][2] + vv[1][2] + vv[2][2]) / 3,
            )
          )
            continue;
          for (const k of out > 0 ? [0, 1, 2] : [0, 2, 1]) {
            ps.push(T.loc[a + k * 3], T.loc[a + k * 3 + 1], T.loc[a + k * 3 + 2]);
            us.push(uv[k][0], uv[k][1]);
          }
        }
        if (!ps.length) continue;
        const geo = new THREE.BufferGeometry();
        geo.setAttribute('position', new THREE.Float32BufferAttribute(ps, 3));
        geo.setAttribute('uv', new THREE.Float32BufferAttribute(us, 2));
        geo.computeVertexNormals();
        const mat =
          mats[d.id] ||
          (mats[d.id] = new THREE.MeshStandardMaterial({
            map: livTexture(d.png, true),
            transparent: true,
            depthWrite: false,
            roughness: 0.35,
            metalness: 0,
            polygonOffset: true,
            polygonOffsetFactor: -4,
            polygonOffsetUnits: -4,
            side: THREE.DoubleSide,
          }));
        const mesh = new THREE.Mesh(geo, mat);
        mesh.renderOrder = 5;
        mesh.frustumCulled = false;
        mesh.userData.decal = L.id;
        o.add(mesh);
      }
    }
  }

  // ---------- load one airframe per livery ----------
  const bin = atob($('glb').textContent.trim()),
    buf = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) buf[i] = bin.charCodeAt(i);

  function loadAirframe() {
    return new Promise((res, rej) =>
      new THREE.GLTFLoader().parse(
        buf.buffer.slice(0),
        '',
        (g) => {
          const root = g.scene;
          // wings deployed: hold the Fold clip at its first frame
          const fold = g.animations.find((a) => a.name === 'Fold');
          if (fold) {
            fold.tracks = fold.tracks.filter((t) => !/Rotor_/.test(t.name));
            const mixer = new THREE.AnimationMixer(root),
              act = mixer.clipAction(fold);
            act.play();
            act.paused = true;
            act.time = 0;
            mixer.update(0);
          }
          root.traverse((o) => {
            if (!o.isMesh) return;
            o.frustumCulled = false;
            if (o.material && !o.material.transparent) o.material.side = THREE.DoubleSide;
            if (/^(Tank_|Engine_|Firewall)/.test(o.name)) o.visible = false;
            if (/^Canopy$/.test(o.name)) {
              o.material = o.material.clone();
              o.material.color.set(0x6f8aa0);
              o.material.roughness = 0.05;
              o.material.metalness = 0.2;
              o.material.opacity = 0.55;
              o.material.transparent = true;
              o.material.depthWrite = false;
            }
          });
          res(root);
        },
        rej,
      ),
    );
  }

  // ---------- Starship ----------
  // The ship model stands nose up (+y), heat shield on +z, flaps on +-x. A pivot lays it down nose-first (+z, which
  // lookAt points along the flight path) with the heat shield underneath, like a belly-flopping ship gliding along.
  const SHIP_SCALE = 0.19; // 60 m ship -> 11 scene units (a SkyRacer is about 4)
  function glowTexture(inner, outer) {
    const cv = document.createElement('canvas');
    cv.width = cv.height = 64;
    const x = cv.getContext('2d'),
      g = x.createRadialGradient(32, 32, 0, 32, 32, 32);
    g.addColorStop(0, inner);
    g.addColorStop(0.35, outer);
    g.addColorStop(1, 'rgba(0,0,0,0)');
    x.fillStyle = g;
    x.fillRect(0, 0, 64, 64);
    return new THREE.CanvasTexture(cv);
  }
  // Re-entry oxidation on the heat shield (CFG.oxidation 0..1): procedural, nothing from photos. Rust-orange streaks
  // run along the ship from the windward centre line, densest low on the hull and fading toward the nose; brighter
  // copper where it's hottest, a few white flecks of exposed insulation, dark tiles still showing through. Higher
  // values spread it wider and make it denser, from clean black tiles to a fully cooked ship.
  const OX = { value: Math.max(0, Math.min(1, +CFG.oxidation || 0)) };
  function oxidise(mat, y0, y1) {
    mat.onBeforeCompile = (sh) => {
      sh.uniforms.uOx = OX;
      sh.uniforms.uY = { value: new THREE.Vector2(y0, y1) };
      sh.vertexShader = sh.vertexShader
        .replace('#include <common>', '#include <common>\nvarying vec3 vOxPos;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvOxPos = position;');
      sh.fragmentShader = sh.fragmentShader
        .replace('#include <common>', `#include <common>
varying vec3 vOxPos;
uniform float uOx;
uniform vec2 uY;
float oxK = 0.0;
float oxH(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float oxN(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(oxH(i), oxH(i + vec2(1, 0)), u.x), mix(oxH(i + vec2(0, 1)), oxH(i + vec2(1, 1)), u.x), u.y);
}
float oxF(vec2 p) { float v = 0.0, a = 0.5; for (int k = 0; k < 4; k++) { v += a * oxN(p); p *= 2.03; a *= 0.5; } return v; }`)
        .replace('#include <color_fragment>', `#include <color_fragment>
{
  // Zones along the ship, like Starship after re-entry: frosty white-blue toward the nose, scorched dark tiles in
  // the middle, rust-orange toward the rear. Streaks are swept: they start near the windward centre line up front
  // and fan out toward the sides going aft, so they run diagonally across the belly.
  float th = atan(vOxPos.x, vOxPos.z);                          // 0 on the windward centre line
  float at = abs(th);
  float yn = clamp((vOxPos.y - uY.x) / (uY.y - uY.x), 0.0, 1.0); // 0 tail .. 1 nose
  float side = 1.0 - smoothstep(0.6, 1.5, at);                  // heating falls off round the sides
  float sweep = mix(0.9, 1.7, smoothstep(0.5, 0.9, yn));       // steeper sweep on the nose
  float u = at + sweep * yn;                                     // constant along each swept streak
  float wob = 0.06 * (oxN(vec2(yn * 6.0, at * 4.0)) - 0.5);
  float streak = oxF(vec2((u + wob) * 9.0, yn * 1.2));
  float thin = oxN(vec2((u + wob) * 95.0, yn * 1.8)) * 0.7 + oxN(vec2((u + wob) * 36.0, yn * 0.9)) * 0.3;
  float fine = oxN(vec2(th * 70.0, yn * 6.0));
  float on = step(0.001, uOx);

  float rearW = 1.0 - smoothstep(0.38, 0.6, yn);
  float midW = smoothstep(0.38, 0.58, yn) * (1.0 - smoothstep(0.64, 0.78, yn));
  float frontW = smoothstep(0.62, 0.8, yn) * (1.0 - smoothstep(0.95, 1.0, yn));

  // rear: rust-orange, patchy at first, filling in as it gets hotter
  float m = side * (0.45 + 0.75 * streak) + 0.16 * (fine - 0.5);
  float cover = clamp((m - (1.0 - 1.15 * uOx)) * 2.6, 0.0, 1.0) * on;
  float patchy = smoothstep(0.32, 0.62, streak * 0.75 + thin * 0.35 + fine * 0.15);
  float keep = smoothstep(0.64, 0.82, oxN(vec2(th * 24.0, yn * 9.0))) * (1.0 - 0.6 * uOx);  // clumps that stayed black
  float rustK = rearW * cover * mix(patchy, 1.0, smoothstep(0.55, 1.0, uOx) * 0.75) * (1.0 - keep);
  float glow = clamp(streak * 1.2 + thin * 0.4 - 0.3, 0.0, 1.0);
  vec3 rust = mix(vec3(0.30, 0.06, 0.012), vec3(0.98, 0.42, 0.08), glow);
  rust = mix(rust, vec3(0.10, 0.04, 0.02), smoothstep(0.8, 0.97, 1.0 - thin) * 0.5);
  // the orange reaches up into the middle in a few thin swept tongues
  float tongue = midW * side * on * smoothstep(0.62, 0.8, thin) * smoothstep(0.35, 0.8, uOx) * 0.8;
  rustK = max(rustK, tongue);

  // middle: scorched, slightly blue-black tiles
  float scorch = midW * side * uOx * (0.5 + 0.5 * streak);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.05, 0.06, 0.08), scorch * 0.6);

  // front: frosty white to steel-blue streaks swept back from the nose
  float frostK = frontW * side * on * smoothstep(1.0 - 0.95 * uOx, 1.25 - 0.95 * uOx, 0.35 + 0.8 * streak + 0.25 * (thin - 0.5));
  vec3 frost = mix(vec3(0.36, 0.45, 0.58), vec3(0.88, 0.91, 0.95), clamp(thin * 1.3 - 0.15, 0.0, 1.0));

  diffuseColor.rgb = mix(diffuseColor.rgb, rust, rustK);
  diffuseColor.rgb = mix(diffuseColor.rgb, frost, frostK);
  oxK = max(rustK, frostK * 0.6);

  // white flecks: insulation where tiles came off, mostly toward the rear
  float fleck = step(0.993 - 0.02 * uOx, oxH(floor(vec2(th * 90.0, yn * 260.0)))) * on * side * (rearW + 0.4 * midW) * smoothstep(0.1, 0.5, uOx);
  diffuseColor.rgb = mix(diffuseColor.rgb, vec3(0.9, 0.9, 0.88), fleck);
}`)
        .replace('#include <roughnessmap_fragment>', '#include <roughnessmap_fragment>\nroughnessFactor = mix(roughnessFactor, 0.5, oxK);')
        .replace('#include <metalnessmap_fragment>', '#include <metalnessmap_fragment>\nmetalnessFactor = mix(metalnessFactor, 0.22, oxK);');
    };
    mat.customProgramCacheKey = () => 'oxidised';
  }

  function loadStarship() {
    return new Promise((res, rej) =>
      new THREE.GLTFLoader().parse(
        buf.buffer.slice(0),
        '',
        (g) => {
          const ship = g.scene.getObjectByName('ship') || g.scene;
          const box = new THREE.Box3().setFromObject(ship);
          const mid = box.getCenter(new THREE.Vector3());
          ship.position.sub(mid); // centre the hull on the pivot
          ship.traverse((o) => {
            if (!o.isMesh) return;
            o.frustumCulled = false;
            const m = (o.material = o.material.clone());
            m.side = THREE.DoubleSide;
            if (m.name === 'steel') { m.metalness = 0.5; m.roughness = 0.38; m.color.setHex(0xb9bec4); } // brushed stainless, not chrome-white
            if (m.name === 'tile' && o.parent && o.parent.name === 'ship' || (m.name === 'tile' && o.name === 'ship')) {
              o.geometry.computeBoundingBox();
              const bb = o.geometry.boundingBox;
              oxidise(m, bb.min.y, bb.max.y);
            }
          });
          const pivot = new THREE.Group();
          pivot.rotation.x = Math.PI / 2; // nose (+y) -> +z, heat shield (+z) -> down
          pivot.scale.setScalar(SHIP_SCALE);
          pivot.add(ship);
          const root = new THREE.Group();
          root.add(pivot);
          // Raptor glow out of the engines
          const tail = (box.min.y - mid.y) * SHIP_SCALE;
          const plume = new THREE.Sprite(new THREE.SpriteMaterial({
            map: glowTexture('rgba(255,255,255,1)', 'rgba(255,150,60,0.75)'),
            blending: THREE.AdditiveBlending, depthWrite: false, transparent: true,
          }));
          plume.position.set(0, 0, tail - 0.4);
          plume.scale.set(1.9, 1.9, 1);
          plume.name = 'plume';
          root.add(plume);
          const core = new THREE.Sprite(new THREE.SpriteMaterial({
            map: glowTexture('rgba(220,235,255,1)', 'rgba(120,160,255,0.6)'),
            blending: THREE.AdditiveBlending, depthWrite: false, transparent: true,
          }));
          core.position.set(0, 0, tail - 0.15);
          core.scale.set(0.9, 0.9, 1);
          core.name = 'core';
          root.add(core);
          res(root);
        },
        rej,
      ),
    );
  }
  // ---------- Starlink ----------
  const INCH_SCALE = 0.85; // the little V1.5 drawn bigger so its inchworm gait reads
  const SAT_SCALE = 0.4; // V3 spans ~41 m -> 16 scene units, V2 ~29 m -> 12
  function loadStarlink(names) {
    return new Promise((res, rej) =>
      new THREE.GLTFLoader().parse(
        buf.buffer.slice(0),
        '',
        (g) => {
          const out = {};
          for (const n of names) {
            const sat = g.scene.getObjectByName(n);
            if (!sat) continue;
            sat.parent && sat.parent.remove(sat);
            sat.traverse((o) => {
              if (!o.isMesh) return;
              o.frustumCulled = false;
              o.material.side = THREE.DoubleSide;
            });
            const pivot = new THREE.Group();
            pivot.scale.setScalar(n === 'V15' ? INCH_SCALE : SAT_SCALE);
            pivot.add(sat);
            const root = new THREE.Group();
            root.add(pivot);
            out[n] = root;
          }
          res(out);
        },
        rej,
      ),
    );
  }
  function wingsOf(root) {
    const joints = [];
    root.traverse((o) => {
      if (o.userData && o.userData.link) joints.push({ o, q0: o.quaternion.clone(), s: o.userData.link === 'R' ? 1 : -1, link: true });
      else if (o.userData && o.userData.wing) joints.push({ o, q0: o.quaternion.clone(), s: o.userData.wing === 'R' ? 1 : -1, i: o.userData.i, n: o.userData.n });
    });
    return joints;
  }
  const zAxis = new THREE.Vector3(0, 0, 1);

  function flapsOf(root) {
    const flaps = [];
    root.traverse((o) => {
      if (o.userData && o.userData.flap) flaps.push({ o, q0: o.quaternion.clone(), s: o.userData.s || 1, fwd: o.userData.flap === 'fwd' });
    });
    return flaps;
  }
  const yAxis = new THREE.Vector3(0, 1, 0),
    flapQ = new THREE.Quaternion();

  const wanted = CFG.liveries.filter((id) => LIVERIES.some((l) => l.id === id));
  const ids = wanted.length ? wanted : ['macsboost'];

  // ---------- the flock ----------
  // CFG.manual (used to record the README video): the page doesn't animate on its own; the
  // recorder calls window.__frame(ms) for each video frame, so the clock is virtual.
  let vt = 0;
  const clock = () => (CFG.manual ? vt : performance.now() / 1000);
  window.__frame = (ms) => frame(ms);
  const craft = [];
  const DIR = new THREE.Vector3(-1, -0.52, 0).normalize(); // toward lower-left, like the toasters
  function viewHalf(z) {
    const h = Math.tan((camera.fov * D2R) / 2) * (camera.position.z - z);
    return { w: h * camera.aspect, h };
  }
  // ---------- Starlink: crossing orbital lanes ----------
  // Two sets of lanes cross on screen (ascending and descending passes): each lane is a straight line at one depth,
  // its satellites all at one speed so they keep their spacing, like the strings of Starlinks seen from the ground.
  const lanes = [];
  const laneLen = (l) => { const { w, h } = viewHalf(l.z); return Math.hypot(w, h) + 24; };
  function lanePoint(l, s) {
    const { h } = viewHalf(l.z);
    return { x: -l.d.y * l.off * h + l.d.x * s, y: l.d.x * l.off * h + l.d.y * s };
  }
  function makeLanes() {
    const dirs = [new THREE.Vector3(-1, -0.62, 0).normalize(), new THREE.Vector3(-1, 0.62, 0).normalize()];
    const perDir = Math.max(1, Math.min(4, Math.round(craft.length / 4)));
    dirs.forEach((d, k) => {
      for (let i = 0; i < perDir; i++) {
        const off = perDir === 1 ? (Math.random() - 0.5) * 0.5 : ((i / (perDir - 1)) * 2 - 1) * 0.75 + (Math.random() - 0.5) * 0.2;
        lanes.push({ d, off, z: (k === 0 ? -6 : -20) + (Math.random() * 2 - 1) * 8, speed: (6 + Math.random() * 3) * CFG.speed });
      }
    });
    lanes.sort(() => Math.random() - 0.5);
    const members = lanes.map(() => []);
    craft.forEach((c, i) => members[i % lanes.length].push(c));
    members.forEach((group, li) => {
      const l = lanes[li], L = laneLen(l);
      group.forEach((c, k) => {
        c.lane = li; c.d = l.d; c.z = l.z; c.speed = l.speed;
        const p = lanePoint(l, -L + (2 * L * (k + Math.random() * 0.35)) / group.length);
        c.x = p.x; c.y = p.y;
      });
    });
  }
  function relane(c) {
    const l = lanes[c.lane], p = lanePoint(l, -laneLen(l));
    c.x = p.x; c.y = p.y; c.z = l.z;
    c.phase = Math.random() * Math.PI * 2;
    c.dep = 0; c.depStarted = false;
    c.man = null; c.kx = c.ky = c.kz = 0; c.wob = 0;
    c.next = clock() + 2 + Math.random() * 9;
    c.gen = (c.gen || 0) + 1;
  }

  // ---------- Starlink: laser links ----------
  // Red optical links from the four corner terminals to nearby satellites, on screen or just off it: unseen "ghost"
  // satellites fly with the flock in a band outside the view so the mesh carries on past the edges. A new link
  // grows across when two come in range; an old one is only dropped once both ends hold another link (make before
  // break), or when it's stretched far out of range. Bright ripples run along the beams and they flicker a little.
  const beams = [], ghosts = [];
  const MAKE_R = 34, BREAK_R = 46, HARD_R = 64;
  const beamGeo = new THREE.CylinderGeometry(1, 1, 1, 10, 1, true).translate(0, 0.5, 0);
  const beamTime = { value: 0 };
  const beamShader = (color, opacity) =>
    new THREE.ShaderMaterial({
      uniforms: { uColor: { value: new THREE.Color(color) }, uOpacity: { value: opacity }, uTime: beamTime },
      vertexShader: 'varying vec3 wp; void main(){ vec4 w = modelMatrix * vec4(position,1.0); wp = w.xyz; gl_Position = projectionMatrix * viewMatrix * w; }',
      fragmentShader: [
        'uniform vec3 uColor; uniform float uOpacity; uniform float uTime; varying vec3 wp;',
        'void main(){',
        '  float along = dot(wp, vec3(0.83, 0.47, 0.31));',
        '  float ripple = 0.55 + 0.45 * sin(along * 2.6 - uTime * 21.0) * sin(along * 0.7 + uTime * 5.3);',
        '  float flick = 0.78 + 0.22 * sin(uTime * 37.0 + wp.x * 0.9) * sin(uTime * 11.0 + wp.y * 1.3);',
        '  gl_FragColor = vec4(uColor * uOpacity * ripple * flick, 1.0);',
        '}',
      ].join('\n'),
      transparent: true, blending: THREE.AdditiveBlending, depthWrite: false, side: THREE.DoubleSide,
    });
  const BEAM_LAYERS = [{ c: 0xff7366, o: 0.55, r: 0.04 }, { c: 0xff120a, o: 0.3, r: 0.12 }, { c: 0xff0505, o: 0.09, r: 0.3 }];
  const upY = new THREE.Vector3(0, 1, 0), pa = new THREE.Vector3(), pb = new THREE.Vector3(), bv = new THREE.Vector3();
  const readyFor = (c) => c.terminals && c.terminals.length > 0 && !(c.deploys && c.dep < 7.8);
  function newBeam() {
    const g = new THREE.Group();
    for (const L of BEAM_LAYERS) {
      const m = new THREE.Mesh(beamGeo, beamShader(L.c, L.o));
      m.userData.r = L.r; m.userData.o = L.o; m.frustumCulled = false; m.renderOrder = 20;
      g.add(m);
    }
    scene.add(g);
    return g;
  }
  function placeGhost(g, anywhere) {
    const d = lanes.length ? lanes[(Math.random() * lanes.length) | 0].d : DIR;
    const z = -40 + Math.random() * 44;
    const { w, h } = viewHalf(z);
    const band = 6 + Math.random() * 34, r = () => Math.random() * 2 - 1;
    let x, y;
    if (anywhere) {
      const s = (Math.random() * 4) | 0;
      if (s === 0) { x = w + band; y = r() * (h + 30); }
      else if (s === 1) { x = -w - band; y = r() * (h + 30); }
      else if (s === 2) { x = r() * (w + 30); y = h + band; }
      else { x = r() * (w + 30); y = -h - band; }
    } else if (Math.random() < 0.55) { x = w + band; y = r() * (h + 30); }
    else { x = (Math.random() * 1.2 - 0.2) * (w + 30); y = d.y < 0 ? h + band : -h - band; }
    g.p = new THREE.Vector3(x, y, z);
    g.v = d.clone().multiplyScalar((6 + Math.random() * 3) * CFG.speed);
    g.gen = (g.gen || 0) + 1;
  }
  function updateLasers(dt) {
    if (!CFG.lasers || !SATS) return;
    beamTime.value += dt;
    const n = craft.length;
    if (!ghosts.length) for (let k = 0; k < Math.max(8, n); k++) { const g = {}; placeGhost(g, true); ghosts.push(g); }
    for (const g of ghosts) {
      g.p.addScaledVector(g.v, dt);
      const { w, h } = viewHalf(g.p.z);
      const inside = Math.abs(g.p.x) < w + 4 && Math.abs(g.p.y) < h + 4;
      const gone = g.p.x < -w - 48 || Math.abs(g.p.y) > h + 48;
      if (inside || gone) placeGhost(g, false);
    }
    const center = (i) => (i < n ? craft[i].g.position : ghosts[i - n].p);
    const gen = (i) => (i < n ? craft[i].gen || 0 : ghosts[i - n].gen);
    const isReady = (i) => (i < n ? readyFor(craft[i]) : true);
    const endOf = (i, t, out) => (i < n ? craft[i].terminals[t].getWorldPosition(out) : out.copy(ghosts[i - n].p));
    const total = n + ghosts.length;
    const cap = (i) => (i < n ? craft[i].terminals.length : 4);
    const holdsOther = (i, ex) => beams.some((b) => b !== ex && !b.dying && b.grow >= 1 && (b.a === i || b.b === i));
    for (const b of beams) {
      if (gen(b.a) !== b.ga || gen(b.b) !== b.gb) {
        if ((b.a < n && gen(b.a) !== b.ga) || (b.b < n && gen(b.b) !== b.gb)) b.fade = 0;
        if (gen(b.a) !== b.ga) b.holdA = true;
        if (gen(b.b) !== b.gb) b.holdB = true;
        b.dying = true;
      }
      const d = (b.holdA ? b.lastA : center(b.a)).distanceTo(b.holdB ? b.lastB : center(b.b));
      if (!b.dying) {
        if (!isReady(b.a) || !isReady(b.b) || d > HARD_R) b.dying = true;
        else if (d > BREAK_R && holdsOther(b.a, b) && holdsOther(b.b, b)) b.dying = true;
      }
      b.grow = Math.min(1, b.grow + dt / 0.35);
      if (b.dying) b.fade -= dt / 0.45;
    }
    for (let k = beams.length - 1; k >= 0; k--) if (beams[k].fade <= 0) { scene.remove(beams[k].g); beams.splice(k, 1); }
    const used = (i) => {
      const s = new Set();
      for (const b of beams) if (!(b.dying && b.fade < 0.5)) { if (b.a === i) s.add(b.ta); if (b.b === i) s.add(b.tb); }
      return s;
    };
    for (let round = 0; round < 2; round++) {
      let best = null;
      for (let i = 0; i < total; i++) {
        if (!isReady(i)) continue;
        for (let j = i + 1; j < total; j++) {
          if (!isReady(j)) continue;
          const d = center(i).distanceTo(center(j));
          if (d >= MAKE_R || (best && d >= best.d)) continue;
          if (beams.some((b) => !b.dying && ((b.a === i && b.b === j) || (b.a === j && b.b === i)))) continue;
          if (used(i).size >= cap(i) || used(j).size >= cap(j)) continue;
          best = { i, j, d };
        }
      }
      if (!best) break;
      const pick = (i, to) => {
        const u = used(i);
        let bi = -1, bd = Infinity;
        for (let k = 0; k < cap(i); k++) {
          if (u.has(k)) continue;
          if (i >= n) return k;
          const d = endOf(i, k, pa).distanceTo(to);
          if (d < bd) { bd = d; bi = k; }
        }
        return bi;
      };
      const ta = pick(best.i, center(best.j)), tb = pick(best.j, center(best.i));
      beams.push({ a: best.i, b: best.j, ta, tb, ga: gen(best.i), gb: gen(best.j), g: newBeam(), grow: 0, fade: 1, dying: false,
        lastA: new THREE.Vector3(), lastB: new THREE.Vector3(), holdA: false, holdB: false });
    }
    for (const b of beams) {
      if (b.holdA) pa.copy(b.lastA); else endOf(b.a, b.ta, pa);
      if (b.holdB) pb.copy(b.lastB); else endOf(b.b, b.tb, pb);
      b.lastA.copy(pa); b.lastB.copy(pb);
      bv.subVectors(pb, pa).multiplyScalar(b.grow);
      const len = Math.max(1e-3, bv.length());
      b.g.position.copy(pa);
      b.g.quaternion.setFromUnitVectors(upY, bv.divideScalar(len));
      const k = Math.max(0, b.fade);
      for (const m of b.g.children) { m.scale.set(m.userData.r, len, m.userData.r); m.material.uniforms.uOpacity.value = m.userData.o * k; }
    }
  }

  // V1.5 gait: the array arches up in the middle (its tail drawing in toward the bus, which holds still), then
  // stretches flat again (the tail holding still, so the stretch pushes the bus forward). Returns the bus's advance.
  const xAxis = new THREE.Vector3(1, 0, 0), inchQ = new THREE.Quaternion();
  function inchworm(c, dt) {
    const rate = 0.9 * CFG.speed * Math.sqrt(Math.max(0.3, +CFG.flapSpeed || 1));
    c.inchPh += dt * 2 * Math.PI * rate;
    const A = (1.15 * (1 - Math.cos(c.inchPh))) / 2;
    let length = 0, prev = 0;
    for (const j of c.inch) {
      const a = A * Math.cos((Math.PI * (j.i + 0.5)) / j.n); // up at the root, down at the tail: one hump
      j.o.quaternion.copy(j.q0).multiply(inchQ.setFromAxisAngle(xAxis, a - prev));
      prev = a;
      length += Math.cos(a);
    }
    const adv = c.inchL < 0 ? 0 : Math.max(0, length - c.inchL) * 1.04 * INCH_SCALE;
    c.inchL = length;
    return adv;
  }

  function spawn(c, initial) {
    c.z = -40 + Math.random() * 45;
    const { w, h } = viewHalf(c.z);
    c.speed = (6 + Math.random() * 4) * CFG.speed;
    if (initial) {
      c.x = (Math.random() * 2 - 1) * w * 1.1;
      c.y = (Math.random() * 2 - 1) * h * 1.1;
    } else if (Math.random() < w / (w + h)) {
      // enter along the top edge
      c.x = (Math.random() * 2 - 0.6) * w;
      c.y = h + (SATS ? 17 : SHIPS ? 10 : 6);
    } else {
      // enter along the right edge
      c.x = w + (SATS ? 19 : SHIPS ? 13 : 8);
      c.y = (Math.random() * 2 - 0.6) * h;
    }
    c.phase = Math.random() * Math.PI * 2;
    c.dep = initial ? Math.random() * 9 : 0; // Starlink "deploying": new arrivals come in stowed
    c.depStarted = !!initial;
    c.man = null;
    c.kx = c.ky = c.kz = 0; // knock-back velocity from bumping into another car
    c.wob = 0; // wobble left over from a bump
    c.next = clock() + 2 + Math.random() * 9;
    c.gen = (c.gen || 0) + 1;
  }

  // ---------- stunts ----------
  // Every few seconds a car either barrel-rolls or veers left/right (banking into it) and back.
  const PERP = new THREE.Vector3(-DIR.y, DIR.x, 0); // in-screen sideways
  const LAT = PERP.clone().multiplyScalar(0.45).add(new THREE.Vector3(0, 0, 0.9)).normalize(); // car's own left/right
  const ease = (x) => (x < 0 ? 0 : x > 1 ? 1 : x * x * (3 - 2 * x));
  function stunt(c, t) {
    // returns { off: Vector3 offset, roll: extra roll (rad) }
    if (!c.man && t >= c.next && CFG.stunts === false) { c.next = t + 5; return null; } // stunts switched off
    if (!c.man && t >= c.next) {
      const r = Math.random();
      if (r < 0.3) {
        // gentle climb or dive, then level off
        c.man = { type: 'alt', t0: t, dur: 3 + Math.random() * 2.5, dirn: Math.random() < 0.5 ? -1 : 1, amp: 1.2 + Math.random() * 2.2 };
        return null;
      }
      const roll = r < 0.55;
      c.man = roll
        ? { type: 'roll', t0: t, dur: 1.5 + Math.random() * 0.8, dirn: Math.random() < 0.5 ? -1 : 1, r: 0.9 + Math.random() * 0.6 }
        : { type: 'veer', t0: t, dur: 2.6 + Math.random() * 1.6, dirn: Math.random() < 0.5 ? -1 : 1, amp: 2.5 + Math.random() * 3 };
    }
    const m = c.man;
    if (!m) return null;
    const u = (t - m.t0) / m.dur;
    if (u >= 1) {
      c.man = null;
      c.next = t + 4 + Math.random() * 12;
      return null;
    }
    if (m.type === 'alt') {
      // up (or down) and back, nose pitching with the climb
      const s = Math.sin(u * Math.PI);
      const vy = Math.cos(u * Math.PI) * Math.sin(u * Math.PI) * 2; // shape of the climb rate
      return { off: new THREE.Vector3(0, s * s * m.amp * m.dirn, 0), roll: 0, pitch: vy * 0.22 * m.dirn * Math.min(1, m.amp / 2) };
    }
    if (m.type === 'roll') {
      const a = ease(u) * Math.PI * 2 * m.dirn;
      // fly a small corkscrew around the path while rolling
      const off = PERP.clone().multiplyScalar(Math.sin(a) * m.r * m.dirn).add(new THREE.Vector3(0, 0, (1 - Math.cos(a)) * m.r));
      return { off, roll: a };
    }
    // veer: out and back along the car's left/right, banking with the sideways speed
    const s = Math.sin(u * Math.PI);
    const vel = Math.cos(u * Math.PI);
    const off = LAT.clone().multiplyScalar(s * s * m.amp * m.dirn);
    return { off, roll: -vel * s * 0.55 * m.dirn };
  }

  function fansOf(root) {
    const fans = [];
    root.traverse((o) => {
      const m = /^Rotor_(FL|FR|RL|RR)_(Upper|Lower)/.exec(o.name);
      if (m && !o.userData.decal)
        fans.push({ o, y0: o.rotation.y, sg: /FL_Upper|FR_Lower|RR_Upper|RL_Lower/.test(o.name) ? 1 : -1, rate: 34 });
      const t = /^Thruster_Fan_(L|R)/.exec(o.name);
      if (t && !o.userData.decal) fans.push({ o, y0: o.rotation.y, sg: t[1] === 'L' ? 1 : -1, rate: 40 });
    });
    return fans;
  }

  async function build() {
    if (SATS) {
      const want = (CFG.liveries || []).map((x) => String(x).toUpperCase()).filter((x) => x === 'V2' || x === 'V3' || x === 'DEPLOY' || x === 'V15');
      const names = want.length ? want : ['V2', 'V3', 'DEPLOY'];
      const model = (k) => (k === 'DEPLOY' ? 'V3' : k); // the deploying one is a V3, fresh off Starship
      const tpls = await loadStarlink([...new Set(names.map(model))]);
      const have = names.filter((n) => tpls[model(n)]);
      const n = Math.max(1, Math.min(20, CFG.count | 0));
      for (let i = 0; i < n; i++) {
        const pick = have[i % have.length];
        const root = tpls[model(pick)].clone(true),
          g = new THREE.Group();
        g.add(root);
        scene.add(g);
        const terminals = [];
        root.traverse((o) => { if (o.userData && o.userData.laser !== undefined) terminals.push(o); });
        terminals.sort((p, q) => (p.name < q.name ? -1 : 1));
        const inch = [];
        root.traverse((o) => { if (o.userData && o.userData.inch !== undefined) inch.push({ o, q0: o.quaternion.clone(), i: o.userData.inch, n: o.userData.n }); });
        inch.sort((p, q) => p.i - q.i);
        const wings = wingsOf(root);
        const c = { g, fans: [], wings: wings.length ? wings : null, inch: inch.length ? inch : null, inchPh: Math.random() * Math.PI * 2, inchL: -1,
          flapRate: 3.6 + Math.random() * 1.6, spin: Math.random() * 10, deploys: pick === 'DEPLOY', terminals };
        spawn(c, true);
        craft.push(c);
      }
      if (CFG.crossing) makeLanes();
      $('loading') && $('loading').remove();
      return;
    }
    if (SHIPS) {
      const tpl = await loadStarship();
      const n = Math.max(1, Math.min(20, CFG.count | 0));
      for (let i = 0; i < n; i++) {
        const root = tpl.clone(true),
          g = new THREE.Group();
        root.traverse((o) => { if (o.isSprite) o.material = o.material.clone(); });
        g.add(root);
        scene.add(g);
        const c = { g, fans: [], flaps: flapsOf(root), plume: root.getObjectByName('plume'), core: root.getObjectByName('core'),
          flapRate: 5.2 + Math.random() * 2.2, spin: Math.random() * 10 };
        spawn(c, true);
        craft.push(c);
      }
      $('loading') && $('loading').remove();
      return;
    }
    const templates = {};
    for (const id of ids) {
      const root = await loadAirframe();
      applyLivery(root, LIVERIES.find((l) => l.id === id));
      templates[id] = root;
    }
    const n = Math.max(1, Math.min(20, CFG.count | 0));
    for (let i = 0; i < n; i++) {
      const id = ids[i % ids.length],
        root = templates[id].clone(true),
        g = new THREE.Group();
      g.add(root);
      scene.add(g);
      const c = { g, fans: fansOf(root), spin: Math.random() * 10 };
      spawn(c, true);
      craft.push(c);
    }
    $('loading') && $('loading').remove();
  }

  // ---------- animate ----------
  const tmpQ = new THREE.Quaternion(),
    tgt = new THREE.Vector3();
  let last = CFG.manual ? 0 : performance.now(),
    paused = false;
  window.__pause = () => (paused = true);
  window.__resume = () => {
    paused = false;
    last = performance.now();
  };
  // ---------- bumping ----------
  // Cars that get too close bounce apart (and wobble a bit) instead of flying through each other.
  const R = SATS ? 3.2 : SHIPS ? 2.8 : 1.7; // rough radius of a SkyRacer / a Starship in scene units
  const lastHit = new Map();
  const n = new THREE.Vector3();
  function bump(t) {
    for (let i = 0; i < craft.length; i++) {
      for (let j = i + 1; j < craft.length; j++) {
        const a = craft[i], b = craft[j];
        if (a.lane !== undefined && b.lane !== undefined && a.d !== b.d) continue; // crossing passes: different altitudes
        if (!a.inch !== !b.inch) continue; // V1.5s fly in a lower shell
        n.subVectors(a.g.position, b.g.position);
        const d = n.length();
        if (d >= 2 * R || d < 1e-4) continue;
        n.divideScalar(d);
        // push them apart so they don't overlap
        const push = (2 * R - d) / 2;
        a.x += n.x * push; a.y += n.y * push; a.z += n.z * push;
        b.x -= n.x * push; b.y -= n.y * push; b.z -= n.z * push;
        a.g.position.addScaledVector(n, push);
        b.g.position.addScaledVector(n, -push);
        // and give each a kick away from the other (once per encounter)
        const key = i * 64 + j;
        if (t - (lastHit.get(key) || 0) > 0.8) {
          lastHit.set(key, t);
          const k = 3.2 + Math.random() * 1.5;
          a.kx += n.x * k; a.ky += n.y * k; a.kz += n.z * k;
          b.kx -= n.x * k; b.ky -= n.y * k; b.kz -= n.z * k;
          a.wob = Math.min(1, a.wob + 0.8);
          b.wob = Math.min(1, b.wob + 0.8);
        }
      }
    }
  }

  function frame(now) {
    if (!CFG.manual) requestAnimationFrame(frame);
    vt = now / 1000;
    if (paused) return;
    const dt = Math.max(0, Math.min(0.05, (now - last) / 1000));
    last = now;
    const t = now / 1000;
    const damp = Math.exp(-2.2 * dt);
    for (const c of craft) {
      // a deploying Starlink drifts at half speed until its arrays are out and flapping
      const pk = (c.dep - 7.8) / 1.5, pace = c.deploys ? 0.5 + 0.5 * (pk < 0 ? 0 : pk > 1 ? 1 : pk * pk * (3 - 2 * pk)) : 1;
      const D = c.d || DIR;
      const adv = c.inch ? inchworm(c, dt) : c.speed * pace * dt; // V1.5 only moves while it stretches out
      c.x += D.x * adv + c.kx * dt;
      c.y += D.y * adv + c.ky * dt;
      c.z = Math.max(-45, Math.min(8, c.z + c.kz * dt));
      c.kx *= damp; c.ky *= damp; c.kz *= damp;
      c.wob *= Math.exp(-1.6 * dt);
      const { w, h } = viewHalf(c.z);
      if (c.lane !== undefined) { if (c.x * D.x + c.y * D.y > laneLen(lanes[c.lane])) relane(c); }
      else if (c.x < -w - (SATS ? 22 : SHIPS ? 15 : 10) || c.y < -h - (SATS ? 20 : SHIPS ? 12 : 8)) spawn(c, false);
      // a slow, lazy drift up and down on top of the little bob
      const straight = !!c.inch; // V1.5 keeps to a straight line: no bob, no stunts
      const bob = straight ? 0 : Math.sin(t * 1.3 + c.phase) * 0.35 + Math.sin(t * 0.23 + c.phase * 2.7) * 0.9;
      const stowed = (c.deploys && c.dep < 7.8) || straight; // no stunts until the arrays are out
      if (stowed) { c.man = null; c.next = Math.max(c.next, clock() + 2); }
      const st = stowed ? null : stunt(c, t);
      c.g.position.set(c.x, c.y + bob, c.z);
      if (st) c.g.position.add(st.off);
      // nose along the direction of travel, left flank toward the viewer, rolled a little to show the roof
      tgt.copy(c.g.position).add(D);
      c.g.lookAt(tgt);
      const wobble = c.wob * Math.sin(t * 11 + c.phase) * 0.35;
      // base tilt ≈ 32° for the cars (shows the roof); Starships fly flatter, side-on, so the flaps flap in profile
      if (straight) c.g.rotateZ(TILT + wobble);
      else {
        if (SATS) c.g.rotateY(0.45); // three-quarter view, like the satellites in the comparison art
        c.g.rotateZ(TILT + Math.sin(t * 0.9 + c.phase) * 0.05 + (st ? st.roll : 0) + wobble);
        c.g.rotateX(Math.sin(t * 1.3 + c.phase + 1) * 0.04 - (st && st.pitch ? st.pitch : 0) + wobble * 0.5);
      }
      c.spin += dt * Math.max(0.05, +CFG.flapSpeed || 1); // fans, flaps and wings all run on this clock
      for (const f of c.fans) f.o.rotation.y = f.y0 + f.sg * f.rate * c.spin;
      if (c.wings) {
        // bird-like wingbeat: a quick downstroke and a slower upstroke, travelling out along the wing so each module
        // lags the one inside it and the tips whip; the body rises a little on each downstroke
        const ph0 = c.spin * c.flapRate + c.phase;
        // deploying: u unfolds the fan-fold stack straight up, v lays the arrays flat, amp fades the wingbeat in
        let u = 1, v = 1, amp = 1, link = 0;
        if (c.deploys) {
          if (!c.depStarted && Math.abs(c.x) < w * 0.85 && Math.abs(c.y) < h * 0.85) c.depStarted = true;
          if (c.depStarted) c.dep += dt;
          const es = (x) => (x < 0 ? 0 : x > 1 ? 1 : x * x * (3 - 2 * x));
          link = Math.PI * (1 - es((c.dep - 0.8) / 1.8)); // the linkage swings the stack out from over the bus
          u = es((c.dep - 2.8) / 3.2);
          v = es((c.dep - 6.0) / 1.8);
          amp = es((c.dep - 7.8) / 1.5);
        }
        // a panel's angle up from flat: stowed they alternate 180°-d / d (a stack lying on the bus), then 90°, then 0°
        const fold = (i) => (Math.PI / 2 - (i % 2 === 0 ? 1 : -1) * (Math.PI / 2 - 0.044) * (1 - u)) * (1 - v);
        for (const j of c.wings) {
          if (j.link) { j.o.quaternion.copy(j.q0).multiply(flapQ.setFromAxisAngle(zAxis, j.s * link)); continue; }
          const ph = ph0 - j.i * 0.42;
          const beat = Math.sin(ph) + 0.28 * Math.sin(2 * ph);
          const flap = j.i === 0 ? 0.05 + 0.34 * beat : 0.012 + (0.95 / j.n) * beat;
          const a = (j.i === 0 ? fold(0) - link : fold(j.i) - fold(j.i - 1)) + amp * flap;
          j.o.quaternion.copy(j.q0).multiply(flapQ.setFromAxisAngle(zAxis, j.s * a));
        }
        c.g.position.y -= 0.35 * Math.cos(ph0) * amp;
      }
      if (c.flaps) {
        // flap like the toasters' wings: each flap swings about its hinge, the forward pair a beat behind the aft
        for (const f of c.flaps) {
          const ph = c.spin * c.flapRate + c.phase - (f.fwd ? 0.6 : 0);
          // degrees leeward of straight out: ~5° (spread, pointing at you) up to ~95° (raised over the hull) and back
          const deg = f.fwd ? 42 + 40 * Math.sin(ph) : 50 + 45 * Math.sin(ph);
          f.o.quaternion.copy(f.q0).multiply(flapQ.setFromAxisAngle(yAxis, f.s * deg * D2R));
        }
        const fl = 0.85 + 0.15 * Math.sin(t * 37 + c.phase) + 0.08 * Math.sin(t * 61);
        if (c.plume) c.plume.scale.set(1.9 * fl, 1.9 * fl, 1);
        if (c.core) c.core.scale.set(0.9 * fl, 0.9 * fl, 1);
      }
    }
    bump(t);
    updateLasers(dt);
    renderer.render(scene, camera);
  }
  build()
    .then(() => {
      tell('ready');
      return CFG.manual ? (window.__ready = true) : requestAnimationFrame(frame);
    })
    .catch((e) => {
      const el = $('loading');
      if (el) el.textContent = (SHIPS ? 'Could not load Starship: ' : 'Could not load the SkyRacer: ') + e;
      tell('could not load the scene: ' + e);
    });
})();
