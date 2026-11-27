/* BoostBar Jet Racers — three jet racers (#16, #8, #3) race a buoy course; the winner celebrates.
   Saver/src/jetrace.js

   ===== race core: course generator + race simulation (no rendering; runs in node for tests) =====
   2D course frame: x east, y north, headings CCW from +x. A positive cross product / curvature is a LEFT turn. */
const CORE = (() => {
  const TAU = Math.PI * 2;
  const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
  function mulberry32(a) {
    return function () {
      a |= 0; a = (a + 0x6d2b79f5) | 0;
      let t = Math.imul(a ^ (a >>> 15), 1 | a);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }
  const BUOY_OFFSET = 4.6; // racing line passes this far outside each turn buoy (m)
  const LANE_MAX = 2.5; // skis run within +-this of the racing line
  const V_TOP = 23.5, A_LAT = 11.5, A_ACC = 6.5, A_BRK = 9.5, DS = 0.5;

  function crPoint(p0, p1, p2, p3, u) { // centripetal Catmull-Rom
    const d = (a, b) => Math.sqrt(Math.hypot(a[0] - b[0], a[1] - b[1]));
    const t0 = 0, t1 = t0 + d(p0, p1), t2 = t1 + d(p1, p2), t3 = t2 + d(p2, p3);
    const t = t1 + (t2 - t1) * u;
    const L = (a, b, ta, tb) => { const w = (t - ta) / (tb - ta); return [a[0] + (b[0] - a[0]) * w, a[1] + (b[1] - a[1]) * w]; };
    const A1 = L(p0, p1, t0, t1), A2 = L(p1, p2, t1, t2), A3 = L(p2, p3, t2, t3);
    const B1 = L(A1, A2, t0, t2), B2 = L(A2, A3, t1, t3);
    return L(B1, B2, t1, t2);
  }

  function tryCourse(rng) {
    const nB = 7 + Math.floor(rng() * 6); // 7..12 turn buoys
    const a = 135 + rng() * 40, b = 60 + rng() * 22;
    const dip = new Array(nB).fill(false);
    let nd = clamp(Math.round(nB * (0.24 + rng() * 0.16)), 2, 4);
    for (let g = 0; g < 60 && nd > 0; g++) {
      const i = Math.floor(rng() * nB);
      if (dip[i] || dip[(i + 1) % nB] || dip[(i + nB - 1) % nB]) continue;
      dip[i] = true; nd--;
    }
    const flip = rng() < 0.5 ? -1 : 1; // -1 runs the loop clockwise (mostly right turns)
    const ph = rng() * TAU;
    const V = [];
    for (let i = 0; i < nB; i++) {
      const ang = ph + ((i + (rng() - 0.5) * 0.5) / nB) * TAU;
      const rad = dip[i] ? 0.40 + rng() * 0.16 : 0.9 + rng() * 0.2;
      V.push([a * rad * Math.cos(ang), flip * b * rad * Math.sin(ang)]);
    }
    // turn direction at each buoy, and the racing-line point just outside it
    const buoys = [], Q = [];
    let nl = 0, nr = 0, longest = -1, longLen = 0;
    for (let i = 0; i < nB; i++) {
      const P = V[(i + nB - 1) % nB], C = V[i], N = V[(i + 1) % nB];
      const d1 = [C[0] - P[0], C[1] - P[1]], d2 = [N[0] - C[0], N[1] - C[1]];
      const l1 = Math.hypot(d1[0], d1[1]), l2 = Math.hypot(d2[0], d2[1]);
      if (l2 < 30) return null;
      const cr = d1[0] * d2[1] - d1[1] * d2[0], dt = d1[0] * d2[0] + d1[1] * d2[1];
      const ang = Math.atan2(cr, dt);
      if (Math.abs(ang) < 0.32 || Math.abs(ang) > 2.55) return null;
      let nx = -d1[0] / l1 + d2[0] / l2, ny = -d1[1] / l1 + d2[1] / l2; // into the inside of the corner
      const nn = Math.hypot(nx, ny); nx /= nn; ny /= nn;
      const left = cr > 0;
      left ? nl++ : nr++;
      buoys.push({ x: C[0], y: C[1], left, nx, ny });
      Q.push([C[0] - nx * BUOY_OFFSET, C[1] - ny * BUOY_OFFSET]);
      if (l2 > longLen) { longLen = l2; longest = i; }
    }
    if (Math.min(nl, nr) < 2 || Math.max(nl, nr) < 3 || longLen < 84) return null;
    // dense spline, then resample to even spacing
    const dense = [], segStart = [];
    let acc = 0;
    for (let i = 0; i < nB; i++) {
      segStart.push(acc);
      const p0 = Q[(i + nB - 1) % nB], p1 = Q[i], p2 = Q[(i + 1) % nB], p3 = Q[(i + 2) % nB];
      for (let k = 0; k < 80; k++) {
        const p = crPoint(p0, p1, p2, p3, k / 80);
        if (dense.length) { const q = dense[dense.length - 1]; acc += Math.hypot(p[0] - q[0], p[1] - q[1]); }
        dense.push([p[0], p[1], acc]);
      }
    }
    const total = acc + Math.hypot(dense[0][0] - dense[dense.length - 1][0], dense[0][1] - dense[dense.length - 1][1]);
    dense.push([dense[0][0], dense[0][1], total]);
    const n = Math.round(total / DS), ds = total / n;
    const X = new Float64Array(n), Y = new Float64Array(n), TH = new Float64Array(n), K = new Float64Array(n), VP = new Float64Array(n);
    for (let i = 0, j = 0; i < n; i++) {
      const s = i * ds;
      while (dense[j + 1][2] < s) j++;
      const A = dense[j], B = dense[j + 1], w = (s - A[2]) / Math.max(B[2] - A[2], 1e-9);
      X[i] = A[0] + (B[0] - A[0]) * w; Y[i] = A[1] + (B[1] - A[1]) * w;
    }
    for (let i = 0; i < n; i++) TH[i] = Math.atan2(Y[(i + 1) % n] - Y[(i + n - 1) % n], X[(i + 1) % n] - X[(i + n - 1) % n]);
    const wrap = (d) => { while (d > Math.PI) d -= TAU; while (d < -Math.PI) d += TAU; return d; };
    let k0 = new Float64Array(n);
    for (let i = 0; i < n; i++) k0[i] = wrap(TH[(i + 1) % n] - TH[(i + n - 1) % n]) / (2 * ds);
    for (let pass = 0; pass < 3; pass++) {
      const k1 = new Float64Array(n);
      for (let i = 0; i < n; i++) { let s = 0; for (let d = -3; d <= 3; d++) s += k0[(i + d + n) % n]; k1[i] = s / 7; }
      k0 = k1;
    }
    K.set(k0);
    // the loop must not come near itself
    const step = 6;
    for (let i = 0; i < n; i += step) for (let j = i + step; j < n; j += step) {
      const sep = Math.min(j - i, n - (j - i)) * ds;
      if (sep > 34 && Math.hypot(X[i] - X[j], Y[i] - Y[j]) < 11) return null;
    }
    // each buoy sits on the correct side with room for the inside lane
    for (const bu of buoys) {
      let md = 1e9;
      for (let i = 0; i < n; i++) { const d = Math.hypot(X[i] - bu.x, Y[i] - bu.y); if (d < md) md = d; }
      if (md < BUOY_OFFSET - 0.7) return null;
    }
    // speed profile on the racing line
    for (let i = 0; i < n; i++) VP[i] = Math.min(V_TOP, Math.sqrt(A_LAT / Math.max(Math.abs(K[i]), 1e-4)));
    for (let r = 0; r < 2; r++) {
      for (let i = n * 2; i >= 0; i--) { const a_ = i % n, b_ = (i + 1) % n; VP[a_] = Math.min(VP[a_], Math.sqrt(VP[b_] * VP[b_] + 2 * A_BRK * ds)); }
      for (let i = 0; i < n * 2; i++) { const a_ = (i + 1) % n, b_ = i % n; VP[a_] = Math.min(VP[a_], Math.sqrt(VP[b_] * VP[b_] + 2 * A_ACC * ds)); }
    }
    let lapT = 0;
    for (let i = 0; i < n; i++) lapT += ds / VP[i];
    // start gate and finish line on the longest leg
    const sA = segStart[longest], sB = longest + 1 < nB ? segStart[longest + 1] : total;
    const leg = sB - sA;
    const gate = sA + Math.max(24, leg * 0.2), fin = gate + 32;
    if (fin > sB - 22) return null;
    for (let s = gate - 8; s < fin + 6; s += ds) if (Math.abs(K[Math.round(s / ds) % n]) > 0.012) return null;
    const L = total;
    buoys.forEach((bu, i) => { bu.s = (((segStart[i] - gate) % L) + L) % L; });
    buoys.sort((p, q) => p.s - q.s);
    const C = {
      n, ds, L, X, Y, TH, K, VP, lapT, buoys, s0: gate, finS: fin - gate, nB,
      at(s, out) { // s measured from the start gate
        let u = ((((s + gate) % L) + L) % L) / ds;
        const i = Math.floor(u) % n, j = (i + 1) % n, w = u - Math.floor(u);
        out.x = X[i] + (X[j] - X[i]) * w; out.y = Y[i] + (Y[j] - Y[i]) * w;
        out.th = TH[i] + wrap(TH[j] - TH[i]) * w;
        out.k = K[i] + (K[j] - K[i]) * w; out.v = VP[i] + (VP[j] - VP[i]) * w;
        return out;
      },
    };
    return C;
  }
  function genCourse(rng) {
    for (let i = 0; i < 4000; i++) { const c = tryCourse(rng); if (c) return c; }
    throw new Error('course generation failed');
  }

  const TARGET = 120; // seconds
  class Race {
    constructor(seed, ids, pre) { // pre: a course already generated from this seed, with the generator it left behind
      this.seed = seed >>> 0;
      const rng = (this.rng = pre ? pre.rng : mulberry32(this.seed));
      const c = (this.course = pre ? pre.course : genCourse(rng));
      this.laps = clamp(Math.round((TARGET - 6) / c.lapT), 1, 8);
      this.scale = clamp((this.laps * c.lapT + 7) / TARGET, 0.78, 1.26); // nudge pace so the race lasts about two minutes
      this.dist = c.finS + this.laps * c.L;
      this.gridDur = 6.5 + rng() * 3;
      this.t = 0; this.raceT = 0; this.phase = 'grid'; this.doneT = 0;
      this.order = []; this.holeshot = null;
      const lanes = [-3.3, 0, 3.3];
      for (let i = 2; i > 0; i--) { const j = Math.floor(rng() * (i + 1)); [lanes[i], lanes[j]] = [lanes[j], lanes[i]]; }
      this.skis = ids.map((id, i) => ({
        id, i, s: -2.05, p: lanes[i], pv: 0, tp: lanes[i] * 0.72, v: 0, acc: 0,
        skill: (rng() - 0.5) * 0.012, react: 0.05 + rng() * 0.3, launch: A_ACC * (0.92 + rng() * 0.16),
        ph: [rng() * TAU, rng() * TAU, rng() * TAU], laneT: 3 + rng() * 3, mist: 0, wob: 0, touch: [false, false, false], hits: 0, cel: -1, celSide: 1, fin: false, ft: 0, place: 0, lap: 1,
        x: 0, y: 0, th: 0, k: 0,
      }));
      this._o = {};
      this.skis.forEach((k) => this._place(k));
    }
    _place(k) {
      const o = this.course.at(k.s, this._o);
      k.x = o.x - Math.sin(o.th) * k.p; k.y = o.y + Math.cos(o.th) * k.p;
      k.th = o.th + Math.atan2(k.pv, Math.max(k.v, 4)); k.k = o.k; k.pathV = o.v;
    }
    ranked() { return this.skis.slice().sort((a, b) => (a.fin && b.fin ? a.ft - b.ft : a.fin ? -1 : b.fin ? 1 : b.s - a.s)); }
    step(dt) {
      this.t += dt;
      if (this.phase === 'grid') { if (this.t >= this.gridDur) { this.phase = 'race'; this.raceT = 0; } else return; }
      if (this.phase === 'done') { this.doneT += dt; }
      this.raceT += dt;
      const rng = this.rng, c = this.course, S = this.skis, T = this.raceT;
      let lead = S[0], second = null;
      for (const k of S) if (k.s > lead.s) lead = k;
      for (const k of S) if (k !== lead && (!second || k.s > second.s)) second = k;
      for (const k of S) {
        const o = c.at(k.s, this._o);
        const form = 0.013 * Math.sin(T * 0.21 + k.ph[0]) + 0.011 * Math.sin(T * 0.083 + k.ph[1]) + 0.007 * Math.sin(T * 0.57 + k.ph[2]);
        let rub = 0.04 * clamp((lead.s - k.s) / 28, 0, 1);
        if (k === lead) rub = -0.012 * clamp((lead.s - second.s) / 18, 0, 1);
        let vt = o.v * (1 + k.skill + form + rub) * this.scale;
        if (k.mist > 0) { vt *= 0.7; k.mist -= dt; }
        else if (!k.fin && T > 7 && rng() < dt / 55) { k.mist = 0.9 + rng() * 0.7; k.wob = 1; }
        k.wob = Math.max(0, k.wob - dt * 0.8);
        // traffic: hold station behind a ski in the same lane, and look for the open side
        let blocked = null;
        for (const q of S) {
          if (q === k) continue;
          const gap = q.s - k.s, dp = q.p - k.p;
          if (gap > 0 && gap < 9 && Math.abs(dp) < 1.7) {
            if (!blocked || gap < blocked.s - k.s) blocked = q;
            if (gap < 4.6 && Math.abs(dp) < 1.35) vt = Math.min(vt, q.v * (gap < 3.4 ? 0.97 : 1.0));
          }
          // contact: hulls touch. Each ski is knocked away once per touch, scrubs a little speed and gets unsettled
          const touching = Math.abs(gap) < 2.75 && Math.abs(dp) < 1.02;
          if (touching && !k.touch[q.i] && T > 1.5) {
            k.touch[q.i] = true;
            const sd = Math.sign(dp || q.i - k.i), closing = Math.max(0, (k.pv - q.pv) * sd);
            if (Math.abs(dp) > 0.55) k.pv -= sd * (0.9 + 0.6 * closing); // side to side: shoved apart
            else if (gap > 0) k.v *= 0.93; else k.v *= 1.015; // nose to tail: the one behind is checked, the one ahead nudged on
            k.v *= 0.985; k.wob = Math.max(k.wob, 0.4); k.hits++;
          } else if (!touching && (Math.abs(dp) > 1.2 || Math.abs(gap) > 3.1)) k.touch[q.i] = false;
          if (Math.abs(gap) < 4.2 && Math.abs(dp) < 1.8) {
            const sg = Math.sign(dp || q.i - k.i), lim = Math.max(LANE_MAX, Math.abs(k.p));
            k.tp = clamp(k.tp - sg * dt * 4, -lim, lim);
            if (Math.abs(gap) < 3.1 && Math.abs(dp) < 1.0) { // never share the same water
              k.p = clamp(k.p - sg * Math.min(1.0 - Math.abs(dp), 2.6 * dt), -lim, lim);
              if (gap > 0 || (gap === 0 && k.i > q.i)) vt = Math.min(vt, q.v * 0.9);
            }
          }
        }
        k.laneT -= dt;
        if (blocked && k.laneT < 2.5) {
          const side = k.p >= blocked.p ? 1 : -1;
          let tp = blocked.p + side * 2.3;
          if (Math.abs(tp) > LANE_MAX) tp = blocked.p - side * 2.3;
          k.tp = clamp(tp, -LANE_MAX, LANE_MAX); k.laneT = 3 + rng() * 2;
        } else if (k.laneT <= 0) { k.tp = (rng() * 2 - 1) * LANE_MAX; k.laneT = 4 + rng() * 6; }
        if (k.fin) vt = Math.min(vt, k.place === 1 ? 9 : 6.5);
        if (k.fin && k.place === 1) { // the winner peels off the racing line and stops for the celebration
          k.cel = T - k.ft; k.tp = k.celSide * 6.5; k.laneT = 99;
          if (k.cel > 0.9) vt = 0;
        }
        if (T < k.react) vt = 0;
        k.acc = clamp((vt - k.v) / 0.25, k.cel > 0 ? -5.5 : -A_BRK * 1.15, k.launch);
        k.v = Math.max(0, k.v + k.acc * dt);
        if (k.v > 0.5) { k.pv += ((k.tp - k.p) * 5.5 - k.pv * 4.8) * dt; k.p += k.pv * dt; }
        const prev = k.s;
        k.s += (k.v * dt) / clamp(1 - o.k * k.p, 0.75, 1.35);
        if (!k.fin && k.s >= this.dist) {
          k.fin = true; k.ft = T - ((k.s - this.dist) / Math.max(k.s - prev, 1e-6)) * dt;
          this.order.push(k); k.place = this.order.length;
          if (k.place === 1) { k.cel = 0; k.celSide = c.buoys[0].left ? -1 : 1; }
          if (this.order.length === S.length) { this.phase = 'done'; this.doneT = 0; }
        }
        k.lap = clamp(Math.floor((k.s - c.finS) / c.L) + 1, 1, this.laps);
        this._place(k);
      }
      if (!this.holeshot) { // first to the first turn buoy
        let h = null; for (const k of S) if (k.s >= c.buoys[0].s && (!h || k.s > h.s)) h = k;
        if (h) this.holeshot = h;
      }
    }
  }
  /* Picking the winner: a race is decided entirely by its seed, so a race that a given racer wins is found by
     running candidate seeds to the flag ahead of time. SeedFinder does it a slice at a time, during the race before. */
  const rand32 = () => (Math.random() * 4294967296) >>> 0;
  class SeedFinder {
    constructor(want, ids) { this.want = want; this.ids = ids; this.found = null; this.tries = 0; this._next(); }
    _next() { this.seed = rand32(); this.rng = mulberry32(this.seed); this.race = null; this.n = 0; this.gen = 0; this.tries++; }
    advance(steps) { // true once a seed is found
      while (this.found === null && steps-- > 0) {
        if (!this.race) { // laying out the candidate's course takes many attempts: one per step, like the race itself
          const c = tryCourse(this.rng);
          if (c) this.race = new Race(this.seed, this.ids, { rng: this.rng, course: c });
          else if (++this.gen >= 4000) this._next();
          if (steps < 1000) break; // (unless asked to hurry) one attempt per call
          continue;
        }
        this.race.step(1 / 120);
        if (this.race.order.length) { if (this.race.order[0].id === this.want || this.tries >= 80) this.found = this.seed; else this._next(); }
        else if (++this.n > 60000) this._next();
      }
      return this.found !== null;
    }
  }
  return { mulberry32, genCourse, Race, SeedFinder, rand32, BUOY_OFFSET, LANE_MAX, V_TOP };
})();

/* ===== rendering, cameras, scoreboard =====
   Runs two ways. In a page (Windows, BoostBar's Preview window, a browser) it draws with three.js. With no document
   (the macOS screen saver: JavaScriptCore inside the .saver, with SceneKit drawing — Saver/native/JetRace.swift) the
   same race, riders, cameras and scoreboard run here and the results are handed over through `JR`. */
(() => {
  const G = typeof globalThis !== 'undefined' ? globalThis : this;
  const NATIVE = typeof document === 'undefined';
  const errors = [];
  const $ = (id) => document.getElementById(id);
  const fail = (m) => { errors.push(String(m)); if (NATIVE) return; console.error(m); const e = $('err'); e.style.display = 'block'; e.textContent += m + '\n'; };
  if (!NATIVE) {
    window.addEventListener('error', (e) => fail((e.message || 'error') + ' @' + (e.lineno || '')));
    window.addEventListener('unhandledrejection', (e) => fail('promise: ' + (e.reason && e.reason.message ? e.reason.message : e.reason)));
  }
  const THREE = G.THREE;
  if (!THREE) { if (!NATIVE) fail('3D library did not load'); return; }
  const V3 = THREE.Vector3, clamp = THREE.MathUtils.clamp, lerp = THREE.MathUtils.lerp, TAU = Math.PI * 2;
  const IDS = [16, 8, 3];
  const RACERS = {
    16: { ski: 'ski16', rider: 'riderTall', chip: ['#f5f5f5', '#d7191e'], name: 'Skeeter' },
    8: { ski: 'ski8', rider: 'rider8', chip: ['#cc121c', '#ffffff'], name: 'Skison' },
    3: { ski: 'ski3', rider: 'rider3', chip: ['#0e1222', '#d0d4da'], name: 'Jorge' },
  };

  /* ---------- settings ----------
     A screen saver host sets SAVER_CONFIG = { winner, celebration, camera, follow, board, captions } from BoostBar's
     settings. On its own in a browser the page keeps its own, edited in the gear panel. */
  const HOSTED = !!G.SAVER_CONFIG;
  const S = { camera: 'director', follow: 'leader', winner: 'random', celeb: 'random', board: true, caption: false };
  function configure(c) {
    if (!c) return;
    for (const [k, f] of [['camera', 'camera'], ['follow', 'follow'], ['winner', 'winner'], ['celebration', 'celeb']]) if (c[k] != null) S[f] = String(c[k]);
    if (c.board != null) S.board = !!c.board;
    if (c.captions != null) S.caption = !!c.captions;
  }
  if (HOSTED) configure(G.SAVER_CONFIG);
  else if (!NATIVE) try { Object.assign(S, JSON.parse(localStorage.getItem('boostbar-jetrace') || '{}')); } catch (e) {}
  const save = () => { if (HOSTED || NATIVE) return; try { localStorage.setItem('boostbar-jetrace', JSON.stringify(S)); } catch (e) {} };
  function sanitize() { // anything unknown falls back to its default
    if (!CAMS.some((c) => c[0] === S.camera)) S.camera = 'director';
    S.follow = String(S.follow); S.winner = String(S.winner);
    if (S.follow !== 'leader' && !IDS.includes(+S.follow)) S.follow = 'leader';
    if (S.winner !== 'random' && !IDS.includes(+S.winner)) S.winner = 'random';
    if (S.celeb !== 'random' && !CELEBS.includes(S.celeb)) S.celeb = 'random';
  }

  /* ---------- renderer, sky, water (water and sky shaders are the X1 SkyRacer sim's) ---------- */
  const scene = new THREE.Scene(), camera = new THREE.PerspectiveCamera(50, 1, 0.25, 16000);
  const SUN = new V3(-0.42, 0.5, -0.62).normalize();
  let renderer = null, skyMat = null, sky = null, water = null, waterU = { t: { value: 0 }, cam: { value: new V3() } };
  if (!NATIVE) {
    const canvas = $('view');
    renderer = new THREE.WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
    renderer.outputEncoding = THREE.sRGBEncoding;
    renderer.toneMapping = THREE.ACESFilmicToneMapping;
    renderer.toneMappingExposure = 0.95;
    renderer.setPixelRatio(Math.min(devicePixelRatio || 1, 1.75));
    const HAZE = new THREE.Color(0xc9d6e0);
    scene.fog = new THREE.Fog(HAZE, 900, 6200);
    scene.add(new THREE.HemisphereLight(0xdcecff, 0x47606e, 0.85));
    const sunL = new THREE.DirectionalLight(0xfff0dc, 2.3);
    sunL.position.copy(SUN).multiplyScalar(100);
    scene.add(sunL);
    skyMat = new THREE.ShaderMaterial({
      side: THREE.BackSide, depthWrite: false, fog: false,
      uniforms: { sun: { value: SUN }, t: { value: 0 }, tw: { value: 0 } },
      vertexShader: `varying vec3 d;void main(){d=normalize(position);gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.);}`,
      fragmentShader: `varying vec3 d;uniform vec3 sun;uniform float t,tw;
   float h(vec2 p){return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453);}
   float n(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x),f.y);}
   float fbm(vec2 p){float a=.5,s=0.;for(int i=0;i<5;i++){s+=a*n(p);p*=2.03;a*=.5;}return s;}
   void main(){vec3 v=normalize(d);float y=max(v.y,0.);float s=max(dot(v,sun),0.);
   vec2 sh=normalize(sun.xz+1e-5),vh=v.xz/max(length(v.xz),1e-4);float az=dot(vh,sh)*.5+.5;
   vec3 cd=mix(vec3(.80,.86,.90),vec3(.27,.50,.74),pow(y,.62))+vec3(1.,.9,.72)*(pow(s,600.)*6.+pow(s,14.)*.22);
   vec3 hz=mix(vec3(.40,.36,.52),vec3(1.,.50,.22),pow(az,3.));
   vec3 ct=mix(hz,mix(vec3(.55,.36,.50),vec3(.12,.17,.36),smoothstep(.02,.35,y)),smoothstep(.0,.16,y));ct=mix(ct,vec3(.05,.08,.21),smoothstep(.3,.95,y));
   ct+=vec3(1.,.55,.22)*(pow(s,900.)*5.+pow(s,10.)*.45);
   vec3 c=mix(cd,ct,tw);
   if(v.y>.01){vec2 p=v.xz/(v.y+.14)*1.5+t*.004;float f=fbm(p);float cl=smoothstep(.47,.74,f)*smoothstep(.01,.2,v.y);
     vec3 kd=vec3(.97,.96,.94)-.05*smoothstep(.62,.85,f);vec3 kt=mix(mix(vec3(.30,.26,.40),vec3(.92,.50,.40),pow(az,2.)),vec3(.18,.17,.28),smoothstep(.15,.6,y))-.06*smoothstep(.62,.85,f);
     c=mix(c,mix(kd,kt,tw),cl*.86);}
   c=mix(c,mix(vec3(.79,.84,.88),mix(vec3(.34,.29,.40),vec3(.80,.46,.28),pow(az,4.)),tw),smoothstep(.09,.0,abs(v.y))*.85);gl_FragColor=vec4(pow(c,vec3(2.2)),1.);}`,
    });
    sky = new THREE.Mesh(new THREE.SphereGeometry(9000, 32, 18), skyMat);
    sky.frustumCulled = false; scene.add(sky);
    {
      const envPS = new THREE.Scene();
      envPS.add(new THREE.Mesh(new THREE.SphereGeometry(100, 24, 12), skyMat));
      scene.environment = new THREE.PMREMGenerator(renderer).fromScene(envPS, 0.02).texture;
    }
    waterU = { t: { value: 0 }, sun: { value: SUN }, cam: { value: new V3() }, craft: { value: new V3(0, 0, 1e5) }, wash: { value: 0 }, tw: { value: 0 }, nt: { value: 0 } };
    water = new THREE.Mesh(
      new THREE.PlaneGeometry(26000, 26000, 1, 1).rotateX(-Math.PI / 2),
      new THREE.ShaderMaterial({
        uniforms: waterU, extensions: { derivatives: true },
        vertexShader: `varying vec3 w;void main(){vec4 p=modelMatrix*vec4(position,1.);w=p.xyz;gl_Position=projectionMatrix*viewMatrix*p;}`,
        fragmentShader: `varying vec3 w;uniform float t,wash,tw,nt;uniform vec3 sun,cam,craft;
   float h(vec2 p){vec3 p3=fract(vec3(p.xyx)*.1031);p3+=dot(p3,p3.yzx+33.33);return fract((p3.x+p3.y)*p3.z);}
   float n(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x),f.y);}
   vec4 ow;vec2 ow2; // two finer octaves than the X1 sim's, for cameras a metre off the water
   float H(vec2 p){return n(p*.11+t*.09)*ow.x+n(p*.27-t*.13)*.55*ow.y+n(p*.73+t*.25)*.28*ow.z+n(p*1.9-t*.42)*.13*ow.w+n(p*4.7+t*.8)*.06*ow2.x+n(p*11.3-t*1.3)*.026*ow2.y;}
   void main(){vec3 v=cam-w;float dist=length(v);v/=dist;vec2 q=w.xz;
   vec2 fw=fwidth(q);float fp=max(fw.x,fw.y);
   ow=vec4(1.)-smoothstep(vec4(.3),vec4(.75),fp*vec4(.11,.27,.73,1.9));ow2=vec2(1.)-smoothstep(vec2(.3),vec2(.75),fp*vec2(4.7,11.3));
   float e=max(mix(mix(.045,.28,smoothstep(2.,40.,dist)),5.,smoothstep(40.,1500.,dist)),fp*1.5);
   float d0=H(q),dx=H(q+vec2(e,0))-d0,dz=H(q+vec2(0,e))-d0;float amp=mix(.9,.1,smoothstep(60.,1100.,dist));
   vec3 N=normalize(vec3(-dx/e*amp,1.,-dz/e*amp));
   float dc=length(q-craft.xz);float ring=wash*exp(-pow((dc-13.)/9.,2.));N.xz+=normalize(q-craft.xz+.001)*ring*.12*sin(dc*1.6-t*11.);N=normalize(N);
   float F=.03+.97*pow(1.-max(dot(v,N),0.),5.);vec3 R=reflect(-v,N);R.y=abs(R.y);
   vec2 sh=normalize(sun.xz+1e-5),rh=R.xz/max(length(R.xz),1e-4);float az=dot(rh,sh)*.5+.5;
   vec3 sk=mix(mix(vec3(.62,.70,.76),vec3(.20,.40,.60),pow(R.y,.55)),pow(mix(mix(vec3(.36,.35,.50),vec3(1.,.52,.24),pow(az,4.)),vec3(.12,.16,.34),pow(R.y,.5)),vec3(2.2))*1.15,tw);vec3 deep=vec3(.012,.085,.125)*(1.-.6*tw)*(1.-.8*nt),shal=vec3(.02,.19,.21)*(1.-.6*tw)*(1.-.8*nt);sk=mix(sk,vec3(.004,.008,.022)+vec3(.05,.032,.03)*pow(1.-R.y,7.),nt);
   vec3 c=mix(mix(shal,deep,clamp(d0*.75,0.,1.)),sk,F);c+=mix(vec3(1.,.93,.8),vec3(1.,.5,.2),tw)*pow(max(dot(R,sun),0.),mix(320.,90.,tw))*mix(7.,4.,tw)*mix(1.,.12,smoothstep(150.,1400.,dist))*(1.-nt)+nt*vec3(.55,.62,.8)*pow(max(dot(R,sun),0.),260.)*2.5;
   c+=vec3(.5)*ring*ring*smoothstep(.35,.9,n(q*3.1+t*5.)*.6+n(q*7.+t*7.)*.4);
   float f=1.-exp(-pow(dist/5200.,2.));c=mix(c,mix(pow(mix(vec3(.79,.84,.88),vec3(.34,.29,.40),tw),vec3(2.2)),vec3(.004,.006,.014),nt),f);
   gl_FragColor=vec4(c,1.);
   #include <tonemapping_fragment>
   #include <encodings_fragment>
   }`,
      }),
    );
    water.frustumCulled = false; water.renderOrder = -2; scene.add(water);
  }

  /* ---------- shoreline backdrop ---------- */
  function canvasTex(w, h, draw) {
    const c = document.createElement('canvas'); c.width = w; c.height = h; draw(c.getContext('2d'), w, h);
    const t = new THREE.CanvasTexture(c); t.encoding = THREE.sRGBEncoding; t.anisotropy = 8; return t;
  }
  // Hills, palms, tents and the banner masts along the beach, placed the same way every time. The native renderer
  // builds the same beach from this list.
  const BANNER = 'BOOSTBAR  WATERCRAFT RACING  GRAND PRIX';
  const SHORE = (() => {
    const out = [], rnd = CORE.mulberry32(4242), cols = [0xe8432e, 0x2a6fd6, 0xf2c230, 0xffffff, 0x1c9c62];
    const beachY = (z) => (-(z + 150) / 370) * 7.5 - 0.5;
    for (let i = 0; i < 46; i++) {
      const r = 60 + rnd() * 110, x = -2500 + i * 110 + rnd() * 60, z = -520 - rnd() * 120;
      out.push({ k: 'hill', p: [x, 2, z], s: [r, r * (0.16 + rnd() * 0.14), r * 0.6] });
    }
    for (let i = 0; i < 70; i++) {
      const x = -900 + rnd() * 1800, z = -205 - rnd() * 250, h = 6 + rnd() * 5, y0 = beachY(z);
      out.push({ k: 'trunk', p: [x, y0 + h / 2, z], s: [1, h, 1], rz: (rnd() - 0.5) * 0.25 }, { k: 'leaf', p: [x, y0 + h, z], s: [2.8, 0.9, 2.8] });
    }
    for (let i = 0; i < 9; i++) {
      const x = -180 + i * 44 + rnd() * 14, z = -175 - rnd() * 16, y0 = beachY(z);
      out.push({ k: 'roof', p: [x, y0 + 3.3, z], c: cols[i % 5] });
      for (const [dx, dz] of [[-2, -2], [2, -2], [2, 2], [-2, 2]]) out.push({ k: 'post', p: [x + dx, y0 + 1.3, z + dz], s: [0.3, 2.6, 0.3] });
    }
    for (const sx of [-17, 17]) out.push({ k: 'mast', p: [sx, 4.4, -168.2], s: [0.8, 9, 0.8] });
    return out;
  })();
  if (!NATIVE) (function shore() {
    const g = new THREE.Group(), std = (color, roughness) => new THREE.MeshStandardMaterial({ color, roughness });
    const sand = new THREE.BufferGeometry();
    sand.setAttribute('position', new THREE.Float32BufferAttribute([-2600, -0.5, -150, 2600, -0.5, -150, 2600, 7, -520, -2600, 7, -520], 3));
    sand.setIndex([0, 1, 2, 0, 2, 3]); sand.computeVertexNormals();
    g.add(new THREE.Mesh(sand, std(0xd8c69a, 1)));
    const trunkG = new THREE.CylinderGeometry(0.16, 0.26, 1, 6);
    const geo = { hill: new THREE.SphereGeometry(1, 14, 8), trunk: trunkG, leaf: new THREE.SphereGeometry(1, 8, 5), roof: new THREE.ConeGeometry(3.2, 1.6, 4), post: trunkG, mast: trunkG };
    const mat = { hill: std(0x2f5a35, 1), trunk: std(0x6b5238, 1), leaf: std(0x2c6b3a, 0.9), post: std(0xdddddd, 1), mast: std(0x888888, 1) };
    for (const o of SHORE) {
      const m = new THREE.Mesh(geo[o.k], o.k === 'roof' ? std(o.c, 0.8) : mat[o.k]);
      m.position.set(o.p[0], o.p[1], o.p[2]);
      if (o.s) m.scale.set(o.s[0], o.s[1], o.s[2]);
      if (o.rz) m.rotation.z = o.rz;
      if (o.k === 'roof') m.rotation.y = Math.PI / 4;
      g.add(m);
    }
    const ban = new THREE.Mesh(new THREE.PlaneGeometry(34, 5), new THREE.MeshBasicMaterial({ map: canvasTex(1024, 152, (c, w, h) => {
      c.fillStyle = '#0b0b0c'; c.fillRect(0, 0, w, h); c.fillStyle = '#ff7a1a'; c.fillRect(0, h - 14, w, 14); c.fillRect(0, 0, w, 14);
      c.fillStyle = '#fff'; c.font = 'italic 900 84px Helvetica, Arial, sans-serif'; c.textAlign = 'center'; c.textBaseline = 'middle'; c.fillText(BANNER, w / 2, h / 2 + 4, w - 40);
    }) }));
    ban.position.set(0, 6.4, -168); g.add(ban);
    scene.add(g);
  })();

  /* ---------- models (GLBs embedded in the page) ---------- */
  function b64buf(id) {
    const s = atob($(id).textContent.trim()), n = s.length, u = new Uint8Array(n);
    for (let i = 0; i < n; i++) u[i] = s.charCodeAt(i);
    return u.buffer;
  }
  const loadGLB = (id) => new Promise((res, rej) => new THREE.GLTFLoader().parse(b64buf(id), '', res, (e) => rej(new Error('model ' + id + ': ' + (e && e.message ? e.message : e)))));
  const STEER_MAX = (30 * Math.PI) / 180;
  const JOINTS = ['Hips', 'Spine', 'Head', 'UpperArm_L', 'ForeArm_L', 'Hand_L', 'UpperArm_R', 'ForeArm_R', 'Hand_R', 'Thigh_L', 'Shin_L', 'Foot_L', 'Thigh_R', 'Shin_R', 'Foot_R'];

  /* ---------- winner celebrations ----------
     A pose gives Euler angles in the left side's sense (mirrored for the right): limbs hang along -Y at zero,
     x- swings a limb forward, z+ lifts the left one out sideways. Fields ending in R override the right side.
     Arms can instead be aimed: uaDL / faDL / uaDR / faDR are directions for the upper arm and forearm in the
     torso frame (+X rider's left, +Y up, +Z forward). */
  const CELEBS = ['shake', 'bow', 'bow2', 'backflip', 'dab', 'cart', 'mower', 'sprinkler', 'crane'];
  const POSE0 = { hy: 0, hz: 0, hips: [0, 0, 0], spine: [0.05, 0, 0], head: [0, 0, 0], ua: [0, 0, 0.14], fa: [-0.15, 0, 0], th: [0, 0, 0], sh: [0, 0, 0], ft: [0, 0.18, 0] };
  const P = (...parts) => Object.assign({}, POSE0, ...parts);
  const QT = THREE.Quaternion, DOWN = new V3(0, -1, 0), XAX = new V3(1, 0, 0), ZAX = new V3(0, 0, 1);
  const _e = new THREE.Euler(), _q = new QT(), _q2 = new QT(), _d = new V3();
  const sm = (u) => { u = clamp(u, 0, 1); return u * u * (3 - 2 * u); };
  const aim = (d) => new QT().setFromUnitVectors(DOWN, _d.set(d[0], d[1], d[2]).normalize());
  function poseQ(p) { // a pose as one quaternion per joint
    const eul = (a, side) => new QT().setFromEuler(_e.set(a[0], side * a[1], side * a[2], 'ZYX'));
    const o = { hy: p.hy, hz: p.hz, Hips: eul(p.hips, 1), Spine: eul(p.spine, 1), Head: eul(p.head, 1) };
    for (const [sfx, side, S2, R] of [['_L', 1, 'L', ''], ['_R', -1, 'R', 'R']]) {
      const g = (f) => p[f + R] || p[f], dU = p['uaD' + S2], dF = p['faD' + S2];
      const qU = dU ? aim(dU) : eul(g('ua'), side);
      o['UpperArm' + sfx] = qU; o['ForeArm' + sfx] = dF ? qU.clone().invert().multiply(aim(dF)) : eul(g('fa'), side);
      o['Thigh' + sfx] = eul(g('th'), side); o['Shin' + sfx] = eul(g('sh'), side); o['Foot' + sfx] = eul(g('ft'), side);
    }
    return o;
  }
  const nx = (d) => d && [-d[0], d[1], d[2]], nyz = (a) => [a[0], -a[1], -a[2]];
  function mirror(p) { // the same pose to the other side
    const o = Object.assign({}, p, { hips: nyz(p.hips), spine: nyz(p.spine), head: nyz(p.head), uaDL: nx(p.uaDR), uaDR: nx(p.uaDL), faDL: nx(p.faDR), faDR: nx(p.faDL) });
    for (const f of ['ua', 'fa', 'th', 'sh', 'ft']) { o[f] = p[f + 'R'] || p[f]; o[f + 'R'] = p[f]; }
    return o;
  }
  function celebKeys(kind, b) {
    const th = Math.asin(clamp((0.305 - b.hipX) / b.L, -0.6, 0.6)), k = b.k;
    const hs = -0.39 + 0.085 * k + b.L * Math.cos(th) + b.hipDrop; // hips height standing in the footwells
    const ht = -0.044 - 0.055 * (k - 0.9) + 0.08 * k + b.L + b.hipDrop; // hips height standing on the seat: the shoes press about 3 cm into the cushion, so they never read as hovering
    const wells = { hy: hs, hz: 0.1, th: [0, 0, th], ft: [0, 0.18, -th] }, seat = { hy: ht, hz: -0.05 };
    const knee = (a) => ({ hy: hs - b.L * (1 - Math.cos(a)), hz: 0.1, th: [-a, 0, th], sh: [2 * a, 0, 0], ft: [-a, 0.18, -th] }); // standing in the wells, knees bent
    const up = { ua: [0, 0, 2.55], fa: [0, 0, 0.35] }, wide = { ua: [0, 0, 1.45], fa: [0, 0, 0.1] };
    let K, extra = {};
    if (kind === 'bow') {
      const bow = { spine: [1.15, 0, 0], head: [0.3, 0, 0], hips: [0.3, 0, 0], th: [-0.3, 0, th], ua: [0.5, 0, 1.5], fa: [0, 0, 0.1] };
      K = [[0.6, P(wells, wide)], [1.2, P(wells, wide)], [1.9, P(wells, bow)], [2.5, P(wells, bow)], [3.2, P(wells, wide)], [3.7, P(wells, wide)], [4.4, P(wells, bow)], [5.0, P(wells, bow)], [5.7, P(wells, up)]];
      extra = { shake: 5.7, amp: 0.5 };
    } else if (kind === 'bow2') { // formal bow: one arm stays straight up while the other folds across the chest
      const chest = { uaDR: [-0.15, -0.85, 0.5], faDR: [0.9, 0.15, 0.4] }, pitch = 1.15; // torso pitch in the bow (hips + spine)
      const tall = P(wells, chest, { uaDL: [0.18, 0.97, 0.05], faDL: [0.12, 0.99, 0.02] });
      const upArm = [0.15, Math.cos(pitch), -Math.sin(pitch)]; // world-up seen from the bowed torso, so the raised arm stays vertical
      const down = P(wells, chest, { spine: [0.9, 0, 0], head: [0.3, 0, 0], hips: [0.25, 0, 0], th: [-0.25, 0, th], uaDL: upArm, faDL: upArm });
      K = [[0.6, tall], [1.2, tall], [1.9, down], [2.6, down], [3.3, tall], [3.8, mirror(tall)], [4.5, mirror(down)], [5.2, mirror(down)], [5.9, P(wells, up)]];
      extra = { shake: 5.9, amp: 0.5 };
    } else if (kind === 'backflip') {
      const crouch = { hy: ht - 0.365 * k, hz: -0.05, spine: [0.55, 0, 0], th: [-1.1, 0, 0], sh: [1.9, 0, 0], ft: [-0.8, 0.18, 0], ua: [0.9, 0, 0.25], fa: [-0.3, 0, 0] };
      const tuck = { hy: ht - 0.365 * k, hz: -0.05, spine: [0.5, 0, 0], head: [0.25, 0, 0], th: [-2.0, 0, 0], sh: [2.3, 0, 0], ft: [-0.3, 0.18, 0], ua: [-1.2, 0, 0.3], fa: [-1.2, 0, 0] };
      K = [[0.5, P(wells)], [1.2, P(seat, wide)], [1.6, P(seat, up)], [1.95, P(crouch)], [2.4, P(tuck)], [2.85, P(crouch)], [3.3, P(seat, up)]];
      extra = { flip: [1.95, 2.85], shake: 3.3, amp: 1 };
    } else if (kind === 'dab') { // straight arm up and out to one side, head tucked into the other elbow
      const dab = P(knee(0.14), { spine: [0.18, 0.25, 0.1], head: [0.5, -0.55, 0.1], uaDL: [0.68, 0.73, 0.05], faDL: [0.68, 0.73, 0.05], uaDR: [-0.22, 0.5, 0.84], faDR: [0.8, 0.6, -0.15] });
      const rest = P(wells), dabR = mirror(dab);
      K = [[0.6, rest], [0.85, dab], [1.9, dab], [2.25, rest], [2.5, dabR], [3.55, dabR], [3.9, rest], [4.15, dab], [5.2, dab], [5.7, P(wells, up)]];
      extra = { shake: 5.7, amp: 0.6 };
    } else if (kind === 'cart') { // shopping cart: push the cart, reach to a shelf, drop it in, both sides
      const arms = { spine: [0.2, 0, 0], uaDL: [0.16, -0.42, 0.9], faDL: [0.02, 0.12, 1], uaDR: [-0.16, -0.42, 0.9], faDR: [-0.02, 0.12, 1] };
      const push = (a) => P(knee(a), arms);
      const reach = P(knee(0.1), arms, { spine: [0.1, 0.3, -0.12], head: [0, 0.6, 0], uaDL: [0.85, 0.45, 0.25], faDL: [0.8, 0.55, 0.2] });
      const drop = P(knee(0.3), arms, { head: [0.3, 0, 0], uaDL: [0.3, -0.45, 0.84], faDL: [-0.35, -0.75, 0.55] });
      K = [[0.6, push(0.12)]];
      let t = 0.6;
      for (let i = 0; i < 6; i++) { const m = i % 2 ? mirror : (x) => x; K.push([t + 0.35, m(reach)], [t + 0.55, m(reach)], [t + 0.82, m(drop)], [t + 1.0, push(i % 2 ? 0.12 : 0.26)]); t += 1.0; }
      K.push([t + 0.5, P(wells, up)]); extra = { shake: t + 0.5, amp: 0.7 };
    } else if (kind === 'crane') { // up on the seat on one leg, arms out like wings; hop, kick with the standing leg, land on the other
      const wings = { uaDL: [0.8, 0.55, 0.1], faDL: [0.45, 0.85, 0.2], uaDR: [-0.8, 0.55, 0.1], faDR: [-0.45, 0.85, 0.2] };
      const kneeUp = { thR: [-1.5, 0, 0], shR: [1.75, 0, 0], ftR: [0.55, 0.18, 0] }; // right knee raised, toes pointed
      const crane = P(seat, wings, kneeUp, { spine: [0.02, 0, 0] }); // standing on the left leg
      const dip = P(seat, wings, kneeUp, { hy: ht - b.L * (1 - Math.cos(0.32)), th: [-0.32, 0, 0], sh: [0.64, 0, 0], ft: [-0.32, 0.18, 0], spine: [0.12, 0, 0] });
      const kick = P({ hy: ht + 0.3, hz: -0.05, spine: [-0.14, 0, 0], head: [0.1, 0, 0], th: [-1.7, 0, 0], sh: [0.05, 0, 0], ft: [0.45, 0.18, 0], // the left leg snaps out front
        thR: [-0.45, 0, 0], shR: [1.25, 0, 0], ftR: [0.3, 0.18, 0], uaDL: [0.75, -0.35, -0.3], faDL: [0.6, -0.6, 0.2], uaDR: [-0.75, -0.35, -0.3], faDR: [-0.6, -0.6, 0.2] });
      const craneR = mirror(crane);
      K = [[0.5, P(wells)], [1.2, P(seat, wide)], [1.75, crane], [2.9, crane], [3.08, dip], [3.3, kick], [3.56, craneR], [4.5, craneR], [4.68, mirror(dip)], [4.9, mirror(kick)], [5.16, crane], [5.9, crane], [6.4, P(seat, up)]];
      extra = { shake: 6.4, amp: 0.8 };
    } else if (kind === 'sprinkler') { // one hand behind the head, the other arm straight out; tick round one way, sweep back
      const at = (yaw, bob) => P(knee(bob), { spine: [0.08, yaw, 0], head: [0, yaw * 0.25, 0], uaDL: [0.25, -0.02, 0.97], faDL: [0.25, 0.04, 0.97], uaDR: [-0.85, 0.5, -0.1], faDR: [0.55, 0.6, -0.55] });
      K = [[0.6, at(-0.95, 0.1)]];
      let t = 0.9;
      for (let rep = 0; rep < 3; rep++) {
        for (let i = 1; i <= 7; i++) { const y = -0.95 + (1.9 * i) / 7; K.push([t + 0.09, at(y, i % 2 ? 0.2 : 0.08)], [t + 0.2, at(y, i % 2 ? 0.2 : 0.08)]); t += 0.2; } // ch-ch-ch-ch
        K.push([t + 0.42, at(-0.95, 0.1)], [t + 0.6, at(-0.95, 0.1)]); t += 0.6; // the sweep back
      }
      K.push([t + 0.5, P(wells, up)]); extra = { shake: t + 0.5, amp: 0.7 };
    } else if (kind === 'mower') { // lawn mower: three pulls on the starter cord, then push it along
      const hold = { uaDL: [0.15, -0.7, 0.7], faDL: [0.05, -0.55, 0.83] };
      const pullA = P(knee(0.3), hold, { spine: [0.75, 0.15, 0], head: [-0.25, 0, 0], uaDR: [-0.1, -0.8, 0.6], faDR: [0.05, -0.85, 0.55] });
      const pullB = P(knee(0.15), hold, { spine: [0.2, -0.6, 0], head: [0, 0.35, 0], uaDR: [-0.45, 0.15, -0.88], faDR: [-0.2, -0.85, 0.45] });
      const mow = { hy: hs - 0.01, hz: 0.1, spine: [0.28, 0, 0], uaDL: [0.2, -0.48, 0.85], faDL: [0, 0.08, 1], uaDR: [-0.2, -0.48, 0.85], faDR: [0, 0.08, 1] };
      const step = P(mow, { th: [-0.7, 0, th], sh: [1.0, 0, 0], ft: [-0.3, 0.18, -th], thR: [0, 0, th], shR: [0, 0, 0], ftR: [0, 0.18, -th] });
      K = [[0.6, pullA], [0.82, pullB], [1.25, pullA], [1.47, pullB], [1.9, pullA], [2.12, pullB], [2.6, P(wells, mow)]];
      let t = 2.6;
      for (let i = 0; i < 12; i++) { t += 0.3; K.push([t, i % 2 ? mirror(step) : step]); }
      K.push([t + 0.5, P(wells, up)]); extra = { vib: [2.3, t], shake: t + 0.5, amp: 0.7 };
    } else { K = [[0.6, P(wells, up)]]; extra = { shake: 0.6, amp: 1 }; }
    return Object.assign({ keys: K.map(([t, p]) => [t, poseQ(p)]) }, extra);
  }
  function applyCelebration(r, t, now) {
    const b = r.body, J = b.J;
    if (!b.seat) { b.seat = {}; for (const nm of JOINTS) b.seat[nm] = J[nm].quaternion.clone(); b.cel = celebKeys(CELEBS.includes(S.celeb) ? S.celeb : race.celeb, b); }
    const C = b.cel, K = C.keys;
    let i = 0; while (i < K.length - 1 && t > K[i][0]) i++;
    const A = i ? K[i - 1][1] : K[0][1], B = K[i][1], u = i ? sm((t - K[i - 1][0]) / (K[i][0] - K[i - 1][0])) : 1;
    const w = sm(t / K[0][0]); // blend out of the seated riding pose
    const sh = t > C.shake ? Math.min(1, (t - C.shake) / 0.3) * C.amp : 0, ph = now * 13;
    const vib = C.vib && t > C.vib[0] && t < C.vib[1] ? 1 : 0;
    const set = (nm, axis, ang) => {
      _q.slerpQuaternions(A[nm], B[nm], u);
      if (ang) _q.premultiply(_q2.setFromAxisAngle(axis, ang));
      J[nm].quaternion.copy(b.seat[nm]).slerp(_q, w);
    };
    set('Hips'); set('Spine', ZAX, sh * 0.07 * Math.sin(ph * 0.5) + vib * 0.02 * Math.sin(now * 47)); set('Head');
    for (const [sfx, side, o] of [['_L', 1, 0], ['_R', -1, 1.3]]) {
      set('UpperArm' + sfx, ZAX, side * sh * 0.28 * Math.sin(ph + o) + vib * 0.03 * Math.sin(now * 53 + o)); set('ForeArm' + sfx, ZAX, side * sh * 0.55 * Math.sin(ph + o + 0.9));
      J['Hand' + sfx].quaternion.copy(b.seat['Hand' + sfx]).slerp(_q.identity(), w);
      set('Thigh' + sfx); set('Shin' + sfx); set('Foot' + sfx);
    }
    let hy = lerp(A.hy, B.hy, u) + sh * 0.03 * Math.abs(Math.sin(ph * 0.5)) + vib * 0.008 * Math.sin(now * 47);
    if (C.flip && t > C.flip[0] && t < C.flip[1]) { // backflip: one full turn backwards about the hips
      const f = (t - C.flip[0]) / (C.flip[1] - C.flip[0]);
      hy += 4 * 0.95 * f * (1 - f);
      J.Hips.quaternion.premultiply(_q2.setFromAxisAngle(XAX, -TAU * f));
    }
    J.Hips.position.set(0, lerp(b.hipsRest.y, hy, w), lerp(b.hipsRest.z, lerp(A.hz, B.hz, u), w));
  }
  /* ---------- the rider as a mass on the ski ----------
     Three damped springs carry his weight: a vertical one between hips and seat (he lifts off it and sinks into it over
     chop; the seat is not deformed), and two that let his torso swing fore-aft and side to side about the hips. They
     are driven by the ski's own accelerations, measured frame to frame, so he is thrown back at the launch, pitches
     forward under braking, and is rocked the other way when another ski knocks his sideways. Two-bone IK then keeps
     his hands on the grips and feet in the footwells. */
  const LIMBS = [['UpperArm_L', 'ForeArm_L', 'Hand_L'], ['UpperArm_R', 'ForeArm_R', 'Hand_R'], ['Thigh_L', 'Shin_L', 'Foot_L'], ['Thigh_R', 'Shin_R', 'Foot_R']];
  const POSED = ['Spine', 'Head'].concat(...LIMBS.map((L) => [L[0], L[1]])); // joints this code turns each frame
  const TORSO_H = 0.35, TORSO_M = 0.48, TORSO_K = 60, TORSO_C = 7.7; // lever arm (m), share of the push that reaches the torso, spring, damping
  const _s = new V3(), _el = new V3(), _h = new V3(), _dir = new V3(), _pole = new V3(), _va = new V3(), _vb = new V3(), _wq = new QT(), _pq = new QT(), _dq = new QT();
  function swing(node, from, to) { // turn a joint, in world space, so that `from` points along `to`
    _dq.setFromUnitVectors(from, to);
    node.getWorldQuaternion(_wq); node.parent.getWorldQuaternion(_pq);
    node.quaternion.copy(_pq.invert()).multiply(_dq).multiply(_wq);
    node.updateWorldMatrix(false, true);
  }
  /* looking back: now and then the leader checks over his shoulder for the racer behind, and the middle rider does
     when he is being caught. Only on the straighter parts, on the side the chaser is on. */
  function updateLooks(dt) {
    const R = race, rk = R.ranked();
    racers.forEach((r) => { if (r.look) { r.look.t += dt; if (r.look.t > r.look.dur) r.look = null; } r.lookCool = Math.max(0, (r.lookCool || 0) - dt); });
    if (R.phase !== 'race' || R.raceT < 6) return;
    for (let pos = 0; pos < 2; pos++) {
      const k = rk[pos], q = rk[pos + 1], r = racers[idxOf(k)], gap = k.s - q.s;
      if (r.look || r.lookCool > 0 || k.fin || q.fin || k.mist > 0 || Math.abs(k.k) > 0.012) continue;
      const closing = q.v - k.v;
      const rate = pos === 0 ? (gap < 16 ? 0.22 : 0) : (gap < 11 && closing > 0.15 ? 0.6 : 0); // chances per second
      if (Math.random() < rate * dt) {
        r.look = { t: 0, dur: 1.0 + Math.random() * 0.6, side: q.p >= k.p ? 1 : -1, pos, q };
        r.lookCool = r.look.dur + 4 + Math.random() * 6; r.looks = (r.looks || 0) + 1;
      }
    }
  }
  const LOOK = { head: 0, spine: 0 }, NECK = 1.2, TWIST = 0.75; // how far the neck turns before the torso has to help (rad)
  function lookAngles(r, k) { // head and torso yaw needed to see the racer behind: the neck goes first, the torso twists for the rest
    const L = r.look; LOOK.head = LOOK.spine = 0;
    if (!L) return LOOK;
    const e = L.side * sm(L.t / 0.28) * sm((L.dur - L.t) / 0.32);
    const q = L.q, drawn = k.rx !== undefined && q.rx !== undefined; // the drawn (between-steps) places, so the head doesn't tick with the race steps
    let rel = drawn ? Math.atan2(q.ry - k.ry, q.rx - k.rx) - k.rth : Math.atan2(q.y - k.y, q.x - k.x) - k.th; rel = Math.abs(Math.atan2(Math.sin(rel), Math.cos(rel))); // how far round he is, 0 ahead .. pi dead astern
    LOOK.head = e * Math.min(rel, NECK); LOOK.spine = e * clamp(rel - NECK - 0.3, 0.2, TWIST); // 0.3: what his eyes cover
    return LOOK;
  }
  function riderMass(r, k, vf, now, dt, riding) {
    const b = r.body, J = b.J;
    if (!b.out) { b.out = {}; b.base = {}; b.bo = b.bv = b.th = b.thv = b.ph = b.phv = b.latSlow = 0; b.prev = null; }
    if (!riding) { b.bo = b.bv = b.th = b.thv = b.ph = b.phv = 0; b.prev = null; return; } // the celebration owns the pose
    if (!b.prev || b.prev.race !== race || ff) b.prev = { race, v: k.rv, pv: k.rpv, hits: k.hits }; // (fast-forward would read as huge accelerations)
    const idt = dt > 1e-4 ? 1 / dt : 0; // a zero-length frame carries no acceleration
    const aLon = clamp((k.rv - b.prev.v) * idt, -60, 60), aLatRaw = clamp((k.rpv - b.prev.pv) * idt, -90, 90);
    b.latSlow += (aLatRaw - b.latSlow) * (1 - Math.exp(-dt / 0.25)); // he rides ordinary lane changes; only the sharp part throws him
    const aLat = aLatRaw - b.latSlow, hit = k.hits !== b.prev.hits;
    b.prev.v = k.rv; b.prev.pv = k.rpv; b.prev.hits = k.hits;
    // vertical: hips against the seat
    const acc = -vf * (0.035 * 121 * Math.sin(now * 11 + r.ph) + 0.025 * 299 * Math.sin(now * 17.3 + r.ph * 2)); // hull's vertical acceleration over the chop
    if (hit) b.bv += 0.55;
    b.bv += (-acc * BOUNCE - 80 * b.bo - 10 * b.bv) * dt; // free both ways: up off the seat and down into it
    b.bo += b.bv * dt;
    if (Math.abs(b.bo) > 0.16) { b.bo = 0.16 * Math.sign(b.bo); b.bv = 0; }
    // torso: th pitches forward (+), ph leans to his left (+); the ski accelerating one way leaves the torso behind
    b.thv += ((-aLon / TORSO_H) * TORSO_M - TORSO_K * b.th - TORSO_C * b.thv) * dt; b.th += b.thv * dt;
    b.phv += ((-aLat / TORSO_H) * TORSO_M - TORSO_K * b.ph - TORSO_C * b.phv) * dt; b.ph += b.phv * dt;
    if (b.th > 0.5 || b.th < -0.38) { b.th = clamp(b.th, -0.38, 0.5); b.thv = 0; }
    if (Math.abs(b.ph) > 0.45) { b.ph = 0.45 * Math.sign(b.ph); b.phv = 0; }
    // the steer clip only rewrites a joint when its value changes, so put back the un-thrown pose where it did not
    for (const nm of POSED) {
      const q = J[nm].quaternion;
      if (b.out[nm] && q.equals(b.out[nm])) q.copy(b.base[nm]); else (b.base[nm] || (b.base[nm] = new QT())).copy(q);
    }
    J.Hips.position.y = b.hipsRest.y;
    const lk = lookAngles(r, k), tw = Math.abs(lk.spine) / TWIST;
    if (Math.abs(b.bo) < 0.002 && Math.abs(b.th) < 0.003 && Math.abs(b.ph) < 0.003 && !lk.head) return;
    r.g.updateMatrixWorld(true);
    const T = LIMBS.map((L) => J[L[2]].getWorldPosition(new V3())); // where the hands and feet belong
    J.Hips.position.y = b.hipsRest.y + b.bo;
    J.Spine.quaternion.multiply(_dq.setFromEuler(_e.set(b.th + LOOK_PITCH * tw, lk.spine, -b.ph - 0.08 * lk.spine, 'XYZ'))); // the torso twists toward the look, and folds forward so the far hand still reaches its grip
    J.Head.quaternion.multiply(_dq.setFromEuler(_e.set(-0.55 * b.th - (0.08 + LOOK_PITCH) * tw, lk.head, 0.55 * b.ph, 'XYZ'))); // the head stays nearer level, and turns over the shoulder
    r.g.updateMatrixWorld(true);
    LIMBS.forEach((L, i) => {
      const U = J[L[0]], Lo = J[L[1]], E = J[L[2]];
      U.getWorldPosition(_s); Lo.getWorldPosition(_el); E.getWorldPosition(_h);
      const L1 = _el.distanceTo(_s), L2 = _h.distanceTo(_el);
      _dir.copy(T[i]).sub(_s); const dist = Math.min(_dir.length(), L1 + L2 - 1e-3); _dir.normalize();
      const a = (L1 * L1 - L2 * L2 + dist * dist) / (2 * dist), h = Math.sqrt(Math.max(L1 * L1 - a * a, 0));
      _va.copy(_el).sub(_s);
      // which way the joint bends: elbows out and down, knees up and forward (the same rule the models were posed with),
      // so an arm folds naturally when its shoulder swings toward the grip
      const sx = i % 2 ? -1 : 1; if (i < 2) _pole.set(sx * 0.75, -0.6, -0.25); else _pole.set(sx * 0.35, 0.75, 0.65);
      _pole.applyQuaternion(J.Hips.parent.getWorldQuaternion(_wq)); _pole.addScaledVector(_dir, -_pole.dot(_dir));
      if (_pole.lengthSq() < 1e-8) return;
      _pole.normalize(); _vb.copy(_dir).multiplyScalar(a).addScaledVector(_pole, h).normalize();
      swing(U, _va.normalize(), _vb);
      Lo.getWorldPosition(_el); E.getWorldPosition(_h);
      _va.copy(_h).sub(_el).normalize(); _vb.copy(_s).addScaledVector(_dir, dist).sub(_el).normalize();
      swing(Lo, _va, _vb);
    });
    for (const nm of POSED) (b.out[nm] || (b.out[nm] = new QT())).copy(J[nm].quaternion);
  }
  const LOOK_PITCH = 0.06;
  const BOUNCE = 0.7; // how hard the chop throws the rider; 0 turns the bounce off
  function resetBody(r) { const b = r.body; for (const nm of JOINTS) b.J[nm].quaternion.copy(b.rest[nm]); b.J.Hips.position.copy(b.hipsRest); b.seat = null; }
  const racers = []; // visual state per ski, index-aligned with race.skis
  function mkBody(J) { // rest pose and the proportions the celebrations are fitted to
    const rest = {};
    for (const nm of JOINTS) rest[nm] = J[nm].quaternion.clone();
    const hipsRest = J.Hips.position.clone(), thighL = Math.abs(J.Shin_L.position.y), shinL = Math.abs(J.Foot_L.position.y), hipX = Math.abs(J.Thigh_L.position.x);
    return { J, rest, hipsRest, k: thighL / 0.43, L: thighL + shinL, hipX, hipDrop: Math.abs(J.Thigh_L.position.y), seat: null };
  }
  function mkRacer(id, g, inner, body, mxS, mxR, nodes, noz) {
    racers.push({ id, g, inner, body, mxS, mxR, nodes, noz, steer: 0, lean: 0, pitch: 0, y: 0, ph: Math.random() * TAU,
      pos: new V3(), fwd: new V3(1, 0, 0), left: new V3(0, 0, -1), vel: new V3(), trail: [], trailD: 0 });
  }
  async function buildRacers() {
    for (const id of IDS) {
      const R = RACERS[id];
      const [ski, rider] = await Promise.all([loadGLB(R.ski), loadGLB(R.rider)]);
      const seat = ski.scene.getObjectByName('SeatMount');
      if (!seat) throw new Error('SeatMount missing on ' + R.ski);
      seat.add(rider.scene); // rider root on the seat mount, identity transform
      const g = new THREE.Group(), inner = new THREE.Group();
      inner.add(ski.scene); g.add(inner); scene.add(g);
      const noz = ski.scene.getObjectByName('SteeringNozzle'); if (!noz) throw new Error('SteeringNozzle missing on ' + R.ski);
      g.traverse((o) => { if (o.isMesh) o.frustumCulled = false; });
      const mk = (root, clips) => { const m = new THREE.AnimationMixer(root); const c = clips.find((a) => a.name === 'Steer') || clips[0]; if (c) m.clipAction(c).play(); return m; };
      const J = {};
      for (const nm of JOINTS) { const o = rider.scene.getObjectByName(nm); if (!o) throw new Error('rider joint missing: ' + nm); J[nm] = o; }
      mkRacer(id, g, inner, mkBody(J), mk(ski.scene, ski.animations), mk(rider.scene, rider.animations), null, noz);
    }
  }
  /* Native: SceneKit owns the meshes, so here each ski and rider is only its moving parts — bare transforms made from
     Saver/src/jetrace/rigs.json (tools/jetrace_rigs.py: every node's rest pose and parent, and the Steer clips),
     hung in the same tree as the models so the rider's springs and reach can work in world space. */
  const SKI_PARTS = ['Handlebars', 'SteeringNozzle'];
  function buildRacersNative(rigs) {
    for (const id of IDS) {
      const R = RACERS[id], nodes = {}, g = new THREE.Object3D(), inner = new THREE.Object3D();
      g.add(inner);
      const rig = (key, mount) => { // mount: what this model's root hangs from
        const r = rigs[key];
        if (!r) throw new Error('rig missing: ' + key);
        for (const nm in r.nodes) { const o = new THREE.Object3D(); o.name = nm; o.position.fromArray(r.nodes[nm].p); o.quaternion.fromArray(r.nodes[nm].q); nodes[nm] = o; }
        for (const nm in r.nodes) (r.nodes[nm].u ? nodes[r.nodes[nm].u] : mount).add(nodes[nm]);
        const T = r.clip.times, n = T.length, ch = r.clip.ch;
        return { setTime(t) { // the Steer clip: straight slerp between its keys
          let i = 0; while (i < n - 2 && t > T[i + 1]) i++;
          const u = clamp((t - T[i]) / (T[i + 1] - T[i]), 0, 1);
          for (const nm in ch) { _q.fromArray(ch[nm], i * 4); _q2.fromArray(ch[nm], i * 4 + 4); _q.slerp(_q2, u); if (!nodes[nm].quaternion.equals(_q)) nodes[nm].quaternion.copy(_q); }
        } };
      };
      const mxS = rig(R.ski, inner);
      if (!nodes.SeatMount) throw new Error('SeatMount missing on ' + R.ski);
      const mxR = rig(R.rider, nodes.SeatMount), J = {};
      for (const nm of JOINTS.concat(SKI_PARTS)) if (!nodes[nm]) throw new Error('rig node missing: ' + nm);
      for (const nm of JOINTS) J[nm] = nodes[nm];
      mkRacer(id, g, inner, mkBody(J), mxS, mxR, nodes, nodes.SteeringNozzle);
    }
  }

  /* ---------- spray particles ---------- */
  const NP = 6000, pPos = new Float32Array(NP * 3), pVel = new Float32Array(NP * 3), pA = new Float32Array(NP), pS = new Float32Array(NP), pLife = new Float32Array(NP), pMax = new Float32Array(NP);
  let pNext = 0;
  let pGeo = null, pMat = null;
  if (!NATIVE) {
    pGeo = new THREE.BufferGeometry();
    pGeo.setAttribute('position', new THREE.BufferAttribute(pPos, 3)); pGeo.setAttribute('a', new THREE.BufferAttribute(pA, 1)); pGeo.setAttribute('sz', new THREE.BufferAttribute(pS, 1));
    pMat = new THREE.ShaderMaterial({
      transparent: true, depthWrite: false, uniforms: { sc: { value: 600 } },
      vertexShader: `attribute float a,sz;varying float va;uniform float sc;void main(){vec4 mv=modelViewMatrix*vec4(position,1.);float ps=sz*sc/max(-mv.z,.3);va=a*smoothstep(1.2,4.5,-mv.z)*clamp(ps*.6,0.,1.);gl_PointSize=clamp(ps,1.6,48.);gl_Position=projectionMatrix*mv;}`,
      fragmentShader: `varying float va;void main(){float d=length(gl_PointCoord-.5);float al=va*smoothstep(.5,.12,d);if(al<.01)discard;gl_FragColor=vec4(.93,.96,.98,al);}`,
    });
    const points = new THREE.Points(pGeo, pMat); points.frustumCulled = false; points.renderOrder = 3; scene.add(points);
  }
  function emit(x, y, z, vx, vy, vz, life, size) {
    const i = pNext; pNext = (pNext + 1) % NP;
    pPos[i * 3] = x; pPos[i * 3 + 1] = y; pPos[i * 3 + 2] = z; pVel[i * 3] = vx; pVel[i * 3 + 1] = vy; pVel[i * 3 + 2] = vz; pLife[i] = pMax[i] = life; pS[i] = size;
  }
  function stepParticles(dt) {
    for (let i = 0; i < NP; i++) {
      if (pLife[i] <= 0) { pA[i] = 0; continue; }
      pLife[i] -= dt; pVel[i * 3 + 1] -= 9.8 * dt;
      const dr = Math.exp(-1.6 * dt); pVel[i * 3] *= dr; pVel[i * 3 + 2] *= dr;
      pPos[i * 3] += pVel[i * 3] * dt; pPos[i * 3 + 1] += pVel[i * 3 + 1] * dt; pPos[i * 3 + 2] += pVel[i * 3 + 2] * dt;
      if (pPos[i * 3 + 1] < 0) pLife[i] = 0;
      const f = Math.max(pLife[i], 0) / pMax[i]; pA[i] = 0.42 * Math.min(1, f * 2.2); pS[i] += dt * 0.22;
    }
    if (pGeo) pGeo.attributes.position.needsUpdate = pGeo.attributes.a.needsUpdate = pGeo.attributes.sz.needsUpdate = true;
  }

  /* ---------- wake foam ribbons ---------- */
  const TR_N = 150, TR_LIFE = 10;
  const foamMat = NATIVE ? null : new THREE.ShaderMaterial({
    transparent: true, depthWrite: false, side: THREE.DoubleSide, uniforms: { t: waterU.t },
    polygonOffset: true, polygonOffsetFactor: -2, polygonOffsetUnits: -8, extensions: { derivatives: true }, // never depth-fights the water from high cameras
    vertexShader: `attribute vec3 u;varying vec3 vu;varying vec2 wp;void main(){vu=u;wp=position.xz;gl_Position=projectionMatrix*viewMatrix*vec4(position,1.);}`,
    fragmentShader: `varying vec3 vu;varying vec2 wp;uniform float t;
 float h(vec2 p){vec3 p3=fract(vec3(p.xyx)*.1031);p3+=dot(p3,p3.yzx+33.33);return fract((p3.x+p3.y)*p3.z);}
 float n(vec2 p){vec2 i=floor(p),f=fract(p);f=f*f*(3.-2.*f);return mix(mix(h(i),h(i+vec2(1,0)),f.x),mix(h(i+vec2(0,1)),h(i+vec2(1,1)),f.x),f.y);}
 void main(){float a=clamp(vu.y,0.,1.),x=abs(vu.x);
 float edge=smoothstep(.45,.85,x)*(1.-smoothstep(.85,1.,x));float core=(1.-smoothstep(0.,.55,x))*(1.-a)*(1.-a);
 float fp=max(fwidth(wp).x,fwidth(wp).y); // fade each foam octave to its mean once a pixel covers it, so it cannot sparkle from altitude
 float f=mix(n(wp*2.1+t*.5),.5,smoothstep(.3,.75,fp*2.1))*.6+mix(n(wp*5.7-t*.8),.5,smoothstep(.3,.75,fp*5.7))*.4;
 float al=(edge*.5+core)*smoothstep(.3,.72,f+.42*(1.-a))*pow(1.-a,1.4)*vu.z;
 gl_FragColor=vec4(.90,.95,.96,al*.9);}`,
  });
  /* ---------- pump jet: a tight stream out of the steering nozzle, along wherever the nozzle points, falling as a
     shallow arc until it meets the water. It barely spreads on the way; the spray starts where it lands. ---------- */
  const JET_N = 10, JET_M = 8;
  const jetMat = NATIVE ? null : new THREE.MeshBasicMaterial({ color: 0xeef8fb, transparent: true, opacity: 0.86, depthWrite: false });
  const _jp = new V3(), _jd = new V3(), _jt = new V3(), _js = new V3(), _ju = new V3(), _jc = new V3();
  function makeJet(r) {
    r.jp = new Float32Array(JET_N * JET_M * 3); r.jetHit = new V3(); r.jetDir = new V3(); r.jetOn = 0;
    if (NATIVE) return; // SceneKit draws the stream from r.jp
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(r.jp, 3));
    const idx = [];
    for (let i = 0; i < JET_N - 1; i++) for (let j = 0; j < JET_M; j++) { const a = i * JET_M + j, b = i * JET_M + ((j + 1) % JET_M); idx.push(a, b, a + JET_M, b, b + JET_M, a + JET_M); }
    geo.setIndex(idx);
    r.jet = new THREE.Mesh(geo, jetMat); r.jet.frustumCulled = false; r.jet.renderOrder = 2; r.jet.visible = false; scene.add(r.jet);
  }
  function updateJet(r, k, vf, now) {
    const nz = r.noz; r.g.updateMatrixWorld(true);
    _jp.set(0, 0, -0.13).applyMatrix4(nz.matrixWorld); // the nozzle's exit
    _jd.set(0, 0, -1.13).applyMatrix4(nz.matrixWorld).sub(_jp).normalize(); // and where it points
    const thr = k.v > 0.3 || k.acc > 0.5 ? clamp(0.2 + 0.55 * vf + 0.45 * clamp(k.acc / 6.5, 0, 1), 0, 1) : 0; // throttle
    const u = 5 + 17 * thr, by = _jd.y * u;
    r.jetDir.set(_jd.x, 0, _jd.z).normalize();
    const te = _jp.y > 0.012 && thr > 0 ? Math.min((by + Math.sqrt(by * by + 19.62 * _jp.y)) / 9.81, 0.7) : 0; // time for the water to fall to the surface
    r.jetOn = te > 0.02 ? 1 : 0;
    if (!r.jetOn) { if (r.jet) r.jet.visible = false; r.jetHit.set(r.pos.x - r.fwd.x * 1.4, 0, r.pos.z - r.fwd.z * 1.4); return; } // nozzle under water: it churns at the stern
    if (r.jet) r.jet.visible = true;
    for (let i = 0; i < JET_N; i++) {
      const t = (te * i) / (JET_N - 1), w = i / (JET_N - 1);
      _jc.copy(_jp).addScaledVector(_jd, u * t); _jc.y -= 4.905 * t * t;
      _jt.copy(_jd).multiplyScalar(u); _jt.y -= 9.81 * t; _jt.normalize();
      _js.set(-_jt.z, 0, _jt.x).normalize(); _ju.crossVectors(_js, _jt);
      const rad = (0.05 + 0.03 * w) * (1 + 0.06 * Math.sin(now * 40 + i * 1.7 + r.ph)); // 5 cm at the nozzle, 8 cm where it lands, with a shimmer
      for (let j = 0; j < JET_M; j++) { const a = (j / JET_M) * TAU, o = (i * JET_M + j) * 3;
        r.jp[o] = _jc.x + (_js.x * Math.cos(a) + _ju.x * Math.sin(a)) * rad; r.jp[o + 1] = _jc.y + (_js.y * Math.cos(a) + _ju.y * Math.sin(a)) * rad; r.jp[o + 2] = _jc.z + (_js.z * Math.cos(a) + _ju.z * Math.sin(a)) * rad; }
      if (i === JET_N - 1) r.jetHit.set(_jc.x, 0, _jc.z);
    }
    if (r.jet) r.jet.geometry.attributes.position.needsUpdate = true;
  }
  function makeTrail(r) {
    r.tp = new Float32Array(TR_N * 6); r.tu = new Float32Array(TR_N * 6); r.tn = 0;
    if (NATIVE) return;
    const geo = new THREE.BufferGeometry();
    geo.setAttribute('position', new THREE.BufferAttribute(r.tp, 3)); geo.setAttribute('u', new THREE.BufferAttribute(r.tu, 3));
    const idx = [];
    for (let i = 0; i < TR_N - 1; i++) idx.push(i * 2, i * 2 + 1, i * 2 + 2, i * 2 + 1, i * 2 + 3, i * 2 + 2);
    geo.setIndex(idx);
    r.tm = new THREE.Mesh(geo, foamMat); r.tm.frustumCulled = false; r.tm.renderOrder = -1; scene.add(r.tm);
  }
  function updateTrail(r, now, vf) {
    const sx = r.pos.x - r.fwd.x * 1.25, sz = r.pos.z - r.fwd.z * 1.25, T = r.trail;
    const head = { x: sx, z: sz, lx: r.left.x, lz: r.left.z, t: now, k: clamp(vf * 1.6, 0, 1) };
    if (!T.length || Math.hypot(T[0].x - sx, T[0].z - sz) > 0.7) { T.unshift(head); if (T.length > TR_N - 1) T.pop(); }
    while (T.length && now - T[T.length - 1].t > TR_LIFE) T.pop();
    const pts = [head].concat(T), n = Math.min(pts.length, TR_N);
    for (let i = 0; i < n; i++) {
      const p = pts[i], age = (now - p.t) / TR_LIFE, w = 0.3 + 3.4 * Math.sqrt(age);
      r.tp.set([p.x + p.lx * w, 0.03, p.z + p.lz * w, p.x - p.lx * w, 0.03, p.z - p.lz * w], i * 6);
      r.tu.set([1, age, p.k, -1, age, p.k], i * 6);
    }
    r.tn = n; // points along the ribbon (two vertices each)
    if (!r.tm) return;
    r.tm.geometry.setDrawRange(0, Math.max(0, (n - 1) * 6));
    r.tm.geometry.attributes.position.needsUpdate = r.tm.geometry.attributes.u.needsUpdate = true;
  }

  /* ---------- course objects (rebuilt for each race) ---------- */
  let race = null, courseG = null, gate = null, buoyMeshes = [], band = null, courseSerial = 0, bandSerial = 0;
  const BAND_M = 26, bandPts = new Float32Array((BAND_M + 1) * 3);
  const to3 = (x, y, h) => new V3(x, h || 0, -y);
  const checkTex = NATIVE ? null : canvasTex(256, 128, (c, w, h) => { const q = 32; for (let i = 0; i < w / q; i++) for (let j = 0; j < h / q; j++) { c.fillStyle = (i + j) % 2 ? '#0a0a0a' : '#f6f6f6'; c.fillRect(i * q, j * q, q, q); } });
  const BALL = new THREE.SphereGeometry(0.3048, 24, 16); // 24 inch ball buoys
  const redM = new THREE.MeshStandardMaterial({ color: 0xcc0408, roughness: 0.55, envMapIntensity: 0.25 }), greenM = new THREE.MeshStandardMaterial({ color: 0x008a2a, roughness: 0.55, envMapIntensity: 0.25 });
  const checkM = new THREE.MeshStandardMaterial({ map: checkTex, roughness: 0.4 });
  const bandM = new THREE.MeshStandardMaterial({ color: 0xf2d21c, roughness: 0.6 });
  function buildCourse() {
    const c = race.course, o = {};
    for (const b of c.buoys) { b.p3 = to3(b.x, b.y, 0); b.n3 = new V3(b.nx, 0, -b.ny); }
    const frame = (s) => { c.at(s, o); return { c: to3(o.x, o.y, 0), f: new V3(Math.cos(o.th), 0, -Math.sin(o.th)), l: new V3(-Math.sin(o.th), 0, -Math.cos(o.th)) }; };
    const G0 = frame(0), F = frame(c.finS);
    gate = { c: G0.c, f: G0.f, l: G0.l, A: G0.c.clone().addScaledVector(G0.l, 8.5), B: G0.c.clone().addScaledVector(G0.l, -8.5), fin: F };
    gate.finL = F.c.clone().addScaledVector(F.l, 7); gate.finR = F.c.clone().addScaledVector(F.l, -7); // the two checkered finish buoys
    gate.finCam = F.c.clone().addScaledVector(F.f, 24).addScaledVector(F.l, 4.2); gate.finCam.y = 1.15;
    courseSerial++;
    if (NATIVE) { band = { userData: { state: '' } }; updateBand(); return; }
    if (courseG) { scene.remove(courseG); courseG.traverse((m) => { if (m.geometry && m.geometry !== BALL) m.geometry.dispose(); }); }
    courseG = new THREE.Group(); scene.add(courseG); buoyMeshes = [];
    for (const b of c.buoys) {
      const m = new THREE.Mesh(BALL, b.left ? redM : greenM); m.position.copy(to3(b.x, b.y, 0.15)); m.userData.ph = Math.random() * TAU;
      courseG.add(m); buoyMeshes.push(m);
    }
    const poleG = new THREE.CylinderGeometry(0.07, 0.07, 3, 12), poleM = new THREE.MeshStandardMaterial({ color: 0xf4f4f4, roughness: 0.5 }), capM = new THREE.MeshStandardMaterial({ color: 0xff7a1a, roughness: 0.5 });
    for (const P of [gate.A, gate.B]) {
      const p = new THREE.Mesh(poleG, poleM); p.position.set(P.x, 0.35, P.z); courseG.add(p);
      const k = new THREE.Mesh(new THREE.CylinderGeometry(0.1, 0.1, 0.3, 12), capM); k.position.set(P.x, 1.85, P.z); courseG.add(k);
    }
    for (const P of [gate.finL, gate.finR]) {
      const m = new THREE.Mesh(new THREE.SphereGeometry(0.42, 28, 18), checkM); m.position.copy(P); m.position.y = 0.2; m.userData.ph = Math.random() * TAU;
      courseG.add(m); buoyMeshes.push(m);
    }
    band = new THREE.Mesh(new THREE.BufferGeometry(), bandM); band.frustumCulled = false; courseG.add(band); band.userData.state = '';
    updateBand();
  }
  const BAND_Y = 0.92, SNAP_T = 0.38;
  function updateBand() {
    const tau = race.phase === 'grid' ? -1 : race.raceT;
    const st = tau < 0 ? 'taut' : tau < SNAP_T ? 'snap' : 'limp';
    if (st !== 'snap' && band.userData.state === st) return;
    band.userData.state = st;
    const A = gate.A.clone().setY(BAND_Y), B = gate.B.clone().setY(BAND_Y), M = BAND_M, pts = [];
    if (st === 'taut') for (let j = 0; j <= M; j++) pts.push(A.clone().lerp(B, j / M).add(new V3(0, -0.05 * Math.sin((Math.PI * j) / M), 0)));
    else if (st === 'snap') { // released at pole A, the free end whips across to pole B
      const u = tau / SNAP_T, F = A.clone().lerp(B, Math.pow(u, 1.4)), e = 4 * u * (1 - u);
      for (let j = 0; j <= M; j++) {
        const w = j / M, p = F.clone().lerp(B, w);
        p.addScaledVector(gate.f, Math.sin(w * 9 + u * 14) * 1.1 * e * (1 - w)); p.y += Math.sin(Math.PI * w) * 0.7 * e - 0.25 * u * (1 - w);
        pts.push(p);
      }
    } else for (let j = 0; j <= M; j++) { const w = j / M; pts.push(B.clone().add(new V3(0, -1.25 * (1 - w), 0)).addScaledVector(gate.l, 0.12 * (1 - w) * (1 - w))); }
    if (NATIVE) { pts.forEach((p, j) => p.toArray(bandPts, j * 3)); bandSerial++; return; }
    band.geometry.dispose();
    band.geometry = new THREE.TubeGeometry(new THREE.CatmullRomCurve3(pts), 52, 0.035, 6, false);
  }

  /* ---------- per-frame racer visuals ---------- */
  function updateRacers(dt, now) {
    updateLooks(dt);
    race.skis.forEach((k, i) => {
      const r = racers[i], vf = clamp(k.v / CORE.V_TOP, 0, 1.2);
      const idle = 1 - clamp(k.v / 4, 0, 1);
      const chop = vf * (0.035 * Math.sin(now * 11 + r.ph) + 0.025 * Math.sin(now * 17.3 + r.ph * 2));
      const plane = sm((k.rv - 2) / 6); // up on the plane by about 8 m/s, and it stays there through the turns
      const y = -0.25 + 0.2 * plane + chop + idle * 0.03 * Math.sin(now * 1.7 + r.ph); // (the demo lifts 12 cm; BoostBar's hulls ride higher, as asked)
      r.pos.set(k.rx, 0, -k.ry);
      r.fwd.set(Math.cos(k.rth), 0, -Math.sin(k.rth)); r.left.set(-Math.sin(k.rth), 0, -Math.cos(k.rth));
      r.vel.copy(r.fwd).multiplyScalar(k.v);
      const wob = k.wob * Math.sin(now * 13 + r.ph) * 0.22;
      const leanT = clamp((k.v * k.v * k.k) / 9.81 * 0.75 + k.pv * 0.05, -0.62, 0.62) + wob;
      r.lean = lerp(r.lean, leanT, 1 - Math.exp(-7 * dt));
      const pitchT = -(0.035 * Math.min(vf, 1) + 0.085 * clamp(k.acc / 6.5, -0.8, 1) * (1 - 0.5 * Math.min(vf, 1))) + chop * 0.5;
      r.pitch = lerp(r.pitch, pitchT, 1 - Math.exp(-6 * dt));
      r.g.position.set(k.rx, y + 1.31 * Math.sin(Math.max(0, -r.pitch)), -k.ry); // the hull pitches about its stern, so nose-up never buries the pump
      // winner: a full spinout as the ski stops, then the celebration
      const sp = k.cel > 0 ? clamp((k.cel - 1.2) / 1.5, 0, 1) : 0, spinning = sp > 0 && sp < 1, dir = -k.celSide;
      const spinYaw = dir * TAU * (1 - Math.pow(1 - sp, 2.2));
      if (spinning) r.lean = lerp(r.lean, dir * 0.5 * Math.sin(Math.PI * sp), 1 - Math.exp(-12 * dt));
      r.g.rotation.set(0, k.rth + Math.PI / 2 + spinYaw, 0);
      if (spinning) {
        r.fwd.set(Math.cos(k.rth + spinYaw), 0, -Math.sin(k.rth + spinYaw)); r.left.set(-Math.sin(k.rth + spinYaw), 0, -Math.cos(k.rth + spinYaw));
        let ns = 1500 * Math.sin(Math.PI * sp) * dt; ns = Math.floor(ns) + (Math.random() < ns % 1 ? 1 : 0);
        for (let e = 0; e < ns; e++) { // wall of spray thrown off the outside rail
          const fz = (Math.random() - 0.5) * 2.4, o = 3 + Math.random() * 6;
          emit(r.pos.x + r.fwd.x * fz + r.left.x * dir * 0.45, 0.1, r.pos.z + r.fwd.z * fz + r.left.z * dir * 0.45, r.left.x * dir * o + r.vel.x * 0.4, 1.5 + Math.random() * 4.5, r.left.z * dir * o + r.vel.z * 0.4, 0.5 + Math.random() * 0.6, 0.05 + Math.random() * 0.1);
        }
      }
      r.inner.rotation.set(r.pitch, 0, -r.lean, 'YXZ');
      const stT = spinning ? dir * STEER_MAX : clamp(k.k * 7.5 + k.pv * 0.14 + wob, -STEER_MAX, STEER_MAX);
      r.steer = lerp(r.steer, stT, 1 - Math.exp(-9 * dt));
      const t = clamp(0.5 - r.steer / (2 * STEER_MAX), 0.002, 0.998);
      r.mxS.setTime(t);
      if (k.cel > 2.9) applyCelebration(r, k.cel - 2.9, now); else r.mxR.setTime(t);
      riderMass(r, k, Math.min(vf, 1), now, dt, !(k.cel > 2.9));
      updateJet(r, k, Math.min(vf, 1), now);
      // spray: where the pump jet lands, sheets off the bow sides, extra off the outside rail in a turn
      const rate = (k.v > 0.6 ? 90 + 520 * vf : 0) + (k.acc > 3 ? 380 : 0) + k.wob * 400;
      let nEm = rate * dt; nEm = Math.floor(nEm) + (Math.random() < nEm % 1 ? 1 : 0);
      for (let e = 0; e < nEm; e++) {
        const j = Math.random() * k.v * dt, sx = r.jetHit.x - r.fwd.x * j, sz = r.jetHit.z - r.fwd.z * j, lat = (Math.random() - 0.5) * 1.1, up = (1.6 + Math.random() * 3.6) * (0.35 + vf) * (k.acc > 3 ? 1.5 : 1);
        emit(sx, 0.1, sz, r.vel.x * 0.25 + r.jetDir.x * 2.5 + r.left.x * lat, up, r.vel.z * 0.25 + r.jetDir.z * 2.5 + r.left.z * lat, 0.45 + Math.random() * 0.6, 0.05 + Math.random() * 0.09);
      }
      let nB = (k.v > 5 ? 200 * vf + Math.abs(r.lean) * 600 : 0) * dt; nB = Math.floor(nB) + (Math.random() < nB % 1 ? 1 : 0);
      for (let e = 0; e < nB; e++) {
        const sd = Math.random() < 0.5 + r.lean * 0.9 ? -1 : 1, fz = 0.1 + Math.random() * 0.8 - Math.random() * k.v * dt, o = 1.2 + Math.random() * 2.4;
        emit(r.pos.x + r.fwd.x * fz + r.left.x * sd * 0.42, 0.1, r.pos.z + r.fwd.z * fz + r.left.z * sd * 0.42,
          r.vel.x * 0.55 + r.left.x * sd * o, 0.9 + Math.random() * 2.4 * vf, r.vel.z * 0.55 + r.left.z * sd * o, 0.3 + Math.random() * 0.4, 0.04 + Math.random() * 0.07);
      }
      updateTrail(r, now, vf);
    });
    for (const m of buoyMeshes) { m.position.y = (m.geometry === BALL ? 0.15 : 0.2) + 0.035 * Math.sin(now * 1.9 + m.userData.ph); m.rotation.z = 0.06 * Math.sin(now * 1.3 + m.userData.ph); }
  }

  /* ---------- cameras ---------- */
  const CAMS = [['director', 'Director (cinematic)'], ['chase', 'Chase'], ['onboard', 'Onboard'], ['side', 'Trackside boat'], ['front', 'Lead boat'], ['heli', 'Helicopter'], ['blimp', 'Overhead'], ['buoy', 'Buoy cam'], ['orbit', 'Drone orbit'], ['finish', 'Finish line']];
  const CAPTION = { chase: 'CHASE', onboard: 'ONBOARD', side: 'TRACKSIDE', front: 'LEAD BOAT', heli: 'HELICOPTER', blimp: 'OVERHEAD', buoy: 'BUOY CAM', orbit: 'DRONE', finish: 'FINISH LINE', gridFront: 'START LINE', gridSide: 'START LINE', gridBehind: 'START', winner: 'WINNER' };
  const cam = { pos: new V3(0, 30, 80), look: new V3(), fov: 50, roll: 0 };
  let shot = null, lastTypes = [], camKey = '';
  const des = new V3(), dlook = new V3(), tmp = new V3();
  const idxOf = (k) => race.skis.indexOf(k);
  function leader() { const R = race.ranked(); return R.find((k) => !k.fin) || R[0]; }
  function subject(sh) {
    if (S.follow !== 'leader') { const i = IDS.indexOf(+S.follow); if (i >= 0) return race.skis[i]; }
    if (sh.who === 'leader' || sh.who == null) return leader();
    return race.skis[sh.who];
  }
  function nextBuoy(k, minAhead) {
    const c = race.course, sm = ((k.s % c.L) + c.L) % c.L; let best = null, bd = 1e9;
    for (const b of c.buoys) { let d = b.s - sm; if (d < minAhead) d += c.L; if (d < bd) { bd = d; best = b; } }
    return { b: best, d: bd };
  }
  function pickShot() {
    const R = race, rnd = Math.random;
    if (R.phase === 'grid') {
      const rem = R.gridDur - R.t;
      if (rem < 2.8) return { type: 'gridBehind', dur: rem + 2.6 };
      const type = lastTypes[0] === 'gridFront' ? 'gridSide' : 'gridFront';
      return { type, dur: Math.max(0.6, Math.min(rem - 2.8, type === 'gridFront' ? 4.2 : 2.6)), sg: rnd() < 0.5 ? 1 : -1 };
    }
    if (R.phase === 'done' || (R.order.length && R.order[0].cel > 1.0)) return { type: 'winner', dur: 1e9, who: idxOf(R.order[0]), a0: rnd() * TAU };
    const lead = leader(), eta = (R.dist - lead.s) / Math.max(lead.v, 8);
    if (R.order.length || eta < 7.5) return { type: 'finish', dur: R.order.length ? 5 : eta + 2.5, who: 'leader' };
    // a close fight gets the coverage; otherwise the leader
    const rk = R.ranked(); let who = 'leader';
    const g12 = rk[0].s - rk[1].s, g23 = rk[1].s - rk[2].s;
    if (g23 < g12 && g23 < 9 && rnd() < 0.55) who = idxOf(rk[1]); else if (rnd() < 0.12) who = idxOf(rk[2]);
    const sub = who === 'leader' ? lead : R.skis[who];
    const opts = [['chase', 3], ['side', 2.4], ['front', 2], ['heli', 1.7], ['orbit', 1.3], ['onboard', 1.3], ['blimp', 0.5]];
    const nb = nextBuoy(sub, 0);
    if (nb.d > 24 && nb.d < 80) opts.push(['buoy', 4.5]);
    let tot = 0; const ok = opts.filter((o) => !lastTypes.slice(0, 2).includes(o[0])); ok.forEach((o) => (tot += o[1]));
    let x = rnd() * tot, type = ok[0][0];
    for (const o of ok) { x -= o[1]; if (x <= 0) { type = o[0]; break; } }
    const sh = { type, who, dur: 4.2 + rnd() * 3.4, sg: rnd() < 0.5 ? 1 : -1, a0: rnd() * TAU };
    if (type === 'buoy') { sh.buoy = nb.b; sh.dur = clamp((nb.d + 26) / Math.max(sub.v, 12), 3.5, 8); }
    if (type === 'blimp') sh.dur = 3.5; if (type === 'onboard') sh.dur = Math.min(sh.dur, 5);
    return sh;
  }
  function manualShot() {
    let type = S.camera;
    if (race.phase === 'grid' && (type === 'chase' || type === 'front' || type === 'side')) return { type: 'gridBehind', dur: 1e9 };
    const sh = { type, who: 'leader', dur: 1e9, sg: 1, a0: 0 };
    if (type === 'buoy') sh.buoy = nextBuoy(subject(sh), -14).b;
    return sh;
  }
  function evalShot(sh, now, dt) {
    const k = subject(sh), r = racers[idxOf(k)], P = r.pos, f = r.fwd, l = r.left, el = now - sh.t0;
    let rate = 5, fov = 50, roll = 0;
    switch (sh.type) {
      case 'chase': des.copy(P).addScaledVector(f, -7.8).addScaledVector(l, sh.sg * 0.9); des.y = 2.3; dlook.copy(P).addScaledVector(f, 4); dlook.y = 0.9; fov = 54; rate = 4.5; break;
      case 'side': des.copy(P).addScaledVector(l, sh.sg * 8.5).addScaledVector(f, 2.2); des.y = 1.05; dlook.copy(P); dlook.y = 0.75; fov = 40; rate = 6; break;
      case 'front': des.copy(P).addScaledVector(f, 11.5).addScaledVector(l, sh.sg * 2.6); des.y = 0.95; dlook.copy(P).addScaledVector(f, -1); dlook.y = 0.8; fov = 36; rate = 6; break;
      case 'onboard': des.copy(P).addScaledVector(f, -1.25).addScaledVector(l, 0.34); des.y = 1.72; dlook.copy(P).addScaledVector(f, 14); dlook.y = 0.5; fov = 76; rate = 30; roll = -r.lean * 0.55; break;
      case 'heli': { let cx = 0, cz = 0; racers.forEach((q) => { cx += q.pos.x / 3; cz += q.pos.z / 3; }); des.set(cx + Math.cos(sh.a0) * 46, 27, cz + Math.sin(sh.a0) * 46); dlook.set(cx, 0.5, cz); fov = 27; rate = 1.4; break; }
      case 'blimp': des.set(P.x * 0.35, 235, P.z * 0.35 + 70); dlook.set(P.x * 0.35, 0, P.z * 0.35); fov = 52; rate = 1; break;
      case 'orbit': { const a = sh.a0 + el * 0.32; des.set(P.x + Math.cos(a) * 12.5, 3.6, P.z + Math.sin(a) * 12.5); dlook.copy(P); dlook.y = 0.8; fov = 44; rate = 5; break; }
      case 'buoy': { const b = sh.buoy; des.copy(b.p3).addScaledVector(b.n3, 3.4); des.y = 0.72; dlook.copy(P); dlook.y = 0.7; fov = clamp((2 * Math.atan(4.2 / Math.max(des.distanceTo(P), 1)) * 180) / Math.PI, 7, 42); rate = 1e3; break; }
      case 'finish': { des.copy(gate.finCam); const R = race.ranked(), q = R.find((z) => !z.fin) || R[R.length - 1]; dlook.copy(racers[idxOf(q)].pos); fov = clamp((2 * Math.atan(5.5 / Math.max(des.distanceTo(dlook), 1)) * 180) / Math.PI, 7, 36); dlook.y = 0.8; rate = 1e3; break; }
      case 'winner': { const a = sh.a0 + el * 0.25; des.set(P.x + Math.cos(a) * 7.5, 2.2, P.z + Math.sin(a) * 7.5); dlook.copy(P); dlook.y = 1.25; fov = 42; rate = 4; break; }
      case 'gridFront': { const u = clamp(el / Math.max(sh.dur, 0.1), 0, 1); des.copy(gate.c).addScaledVector(gate.f, 8.5).addScaledVector(gate.l, sh.sg * lerp(-7.5, 7.5, u)); des.y = 1.0; dlook.copy(gate.c).addScaledVector(gate.f, -2); dlook.y = 0.85; fov = 42; rate = 1e3; break; }
      case 'gridSide': des.copy(gate.A).addScaledVector(gate.l, 2.6).addScaledVector(gate.f, 1.4 - el * 0.25); des.y = 1.25; dlook.copy(gate.B).addScaledVector(gate.f, -1.2); dlook.y = 0.8; fov = 30; rate = 1e3; break;
      case 'gridBehind': default: des.copy(gate.c).addScaledVector(gate.f, -9.5).addScaledVector(gate.l, 1.6); des.y = 1.7; dlook.copy(gate.c).addScaledVector(gate.f, 30); dlook.y = 0.6; fov = 58; rate = 1e3;
    }
    if (des.y < 0.45) des.y = 0.45;
    if (sh.type === 'chase' || sh.type === 'side' || sh.type === 'front' || sh.type === 'orbit' || sh.type === 'winner') // lift over a racer that is in the way
      for (const q of racers) if (q !== r && Math.hypot(q.pos.x - des.x, q.pos.z - des.z) < 3.4) des.y = Math.max(des.y, 3.7);
    if (sh.cut) { cam.pos.copy(des); cam.look.copy(dlook); cam.fov = fov; cam.roll = roll; sh.cut = false; }
    else {
      cam.pos.lerp(des, 1 - Math.exp(-rate * dt)); cam.look.lerp(dlook, 1 - Math.exp(-Math.max(rate, 9) * dt));
      cam.fov = lerp(cam.fov, fov, 1 - Math.exp(-(rate > 100 ? 12 : 3) * dt)); cam.roll = lerp(cam.roll, roll, 1 - Math.exp(-8 * dt));
    }
  }
  function updateCamera(now, dt) {
    const key = S.camera + '|' + S.follow + '|' + (S.camera === 'director' ? '' : race.phase);
    let need = !shot || key !== camKey || now - shot.t0 > shot.dur;
    if (shot && S.camera === 'director') {
      if (race.order.length && shot.type !== 'winner' && race.order[0].cel > 1.0) need = true;
      if (race.phase === 'race' && shot.type.startsWith('grid') && race.raceT > 2.6) need = true;
      if (race.phase === 'race' && shot.type !== 'finish' && !race.order.length && (race.dist - leader().s) / Math.max(leader().v, 8) < 6) need = true;
    }
    if (shot && S.camera === 'buoy' && shot.buoy) { const k = subject(shot), c = race.course, d = (((k.s % c.L) - shot.buoy.s + c.L * 1.5) % c.L) - c.L / 2; if (d > 16) need = true; }
    if (need) {
      camKey = key; shot = S.camera === 'director' ? pickShot() : manualShot();
      shot.t0 = now; shot.cut = true; lastTypes.unshift(shot.type); lastTypes.length = Math.min(lastTypes.length, 4);
      hud.cap = CAPTION[shot.type] || ''; hudT = 0;
    }
    evalShot(shot, now, dt);
    camera.position.copy(cam.pos); camera.up.set(0, 1, 0); camera.lookAt(cam.look);
    if (cam.roll) camera.rotateZ(cam.roll);
    const near = clamp(cam.pos.y * 0.08, 0.25, 6); // a deeper near plane up high keeps depth precision on the water
    if (Math.abs(camera.fov - cam.fov) > 0.01 || Math.abs(camera.near - near) > 0.01) { camera.fov = cam.fov; camera.near = near; camera.updateProjectionMatrix(); }
  }

  /* ---------- scoreboard + settings ---------- */
  const fmt = (t) => { const m = Math.floor(t / 60), s = t - m * 60; return m + ':' + (s < 10 ? '0' : '') + s.toFixed(1); };
  const hud = { board: true, lap: '', clock: '', rows: [], win: null, cap: '', capOn: false }; // what the scoreboard shows, whoever draws it
  let hudT = 0, hudSerial = 0, hudKey = '';
  function updateHud(dt) {
    hudT -= dt; if (hudT > 0) return; hudT = 0.12;
    const R = race, rk = R.ranked(), lead = rk[0];
    hud.board = S.board; hud.capOn = S.caption;
    hud.lap = R.phase === 'grid' ? 'ON THE LINE' : R.phase === 'done' ? 'FINAL' : 'LAP ' + leader().lap + ' / ' + R.laps;
    hud.clock = R.phase === 'grid' ? fmt(0) : fmt(R.order.length === 3 ? R.order[2].ft : R.raceT);
    hud.rows = rk.map((k, i) => ({
      id: k.id, name: RACERS[k.id].name.toUpperCase(), chip: RACERS[k.id].chip, hs: R.holeshot === k,
      gap: R.phase === 'grid' ? '' : k.fin ? fmt(k.ft) : i === 0 ? 'LEADER' : '+' + ((lead.fin ? R.dist - k.s : lead.s - k.s) / Math.max(k.v, 9)).toFixed(1),
    }));
    const w1 = R.order[0];
    hud.win = w1 ? { id: w1.id, name: RACERS[w1.id].name.toUpperCase(), chip: RACERS[w1.id].chip, sub: `${fmt(w1.ft)} · ${R.course.nB} buoys · ${R.laps} laps` } : null;
    if (NATIVE) { const key = JSON.stringify(hud); if (key !== hudKey) { hudKey = key; hudSerial++; } return; }
    $('board').style.display = hud.board ? 'block' : 'none'; $('cap').style.display = hud.capOn ? 'block' : 'none';
    $('cap').textContent = hud.cap; $('lap').textContent = hud.lap; $('clock').textContent = hud.clock;
    $('rows').innerHTML = hud.rows.map((r, i) =>
      `<div class="row"><span class="pos">${i + 1}</span><span class="chip" style="background:${r.chip[0]};color:${r.chip[1]}">${r.id}</span><span class="nm">${r.name}${r.hs ? ' <b class="hs" title="Holeshot">HS</b>' : ''}</span><span class="gap">${r.gap}</span></div>`).join('');
    const w = $('win');
    if (hud.win) { const c = hud.win.chip; w.innerHTML = `<span class="chip big" style="background:${c[0]};color:${c[1]}">${hud.win.id}</span> ${hud.win.name} WINS <small>${hud.win.sub}</small>`; w.classList.add('on'); }
    else w.classList.remove('on');
  }
  const WINNERS = [['random', 'Random (a fair race)'], ['16', 'Skeeter (#16) always wins'], ['8', 'Skison (#8) always wins'], ['3', 'Jorge (#3) always wins']];
  const CELEB_NAMES = [['random', 'Random'], ['shake', 'Stand and shake arms'], ['bow', 'Take a bow'], ['bow2', 'Formal bow, one arm up'], ['backflip', 'Backflip off the seat'], ['dab', 'Dab'], ['cart', 'Shopping cart dance'], ['mower', 'Lawn mower'], ['sprinkler', 'Sprinkler'], ['crane', 'Crane kick']];
  const FOLLOWS = [['leader', 'Race leader'], ['16', 'Skeeter (#16)'], ['8', 'Skison (#8)'], ['3', 'Jorge (#3)']];
  sanitize();
  let syncUI = () => {};
  if (!NATIVE && HOSTED) { $('gear').style.display = 'none'; $('panel').style.display = 'none'; } // BoostBar's settings hold the options
  if (!NATIVE && !HOSTED) {
    const fill = (id, list) => { const s = $(id); list.forEach(([v, n]) => s.add(new Option(n, v))); return s; };
    const selCam = fill('selCam', CAMS), selFol = fill('selFol', FOLLOWS), selWin = fill('selWin', WINNERS), selCel = fill('selCel', CELEB_NAMES);
    syncUI = () => { selCam.value = S.camera; selFol.value = S.follow; selWin.value = S.winner; selCel.value = S.celeb; $('chkBoard').checked = S.board; $('chkCap').checked = S.caption; };
    syncUI();
    selCam.onchange = () => { S.camera = selCam.value; save(); };
    selFol.onchange = () => { S.follow = selFol.value; save(); };
    selWin.onchange = () => { S.winner = selWin.value; save(); };
    selCel.onchange = () => { S.celeb = selCel.value; save(); };
    $('chkBoard').onchange = () => { S.board = $('chkBoard').checked; save(); hudT = 0; };
    $('chkCap').onchange = () => { S.caption = $('chkCap').checked; save(); hudT = 0; };
    $('btnNew').onclick = () => restart();
    $('gear').onclick = () => $('panel').classList.toggle('open');
    window.addEventListener('keydown', (e) => {
      const k = e.key.toLowerCase(), next = (list, v) => list[(list.findIndex((c) => c[0] === v) + 1) % list.length][0];
      if (k === 'c') S.camera = next(CAMS, S.camera);
      else if (k === 'd') S.camera = 'director';
      else if (k === 'l') S.follow = 'leader';
      else if (k === '1') S.follow = '16'; else if (k === '2') S.follow = '8'; else if (k === '3') S.follow = '3';
      else if (k === 'b') S.board = !S.board; else if (k === 'n') restart(); else if (k === 'f') { ff = !ff; return; }
      else if (k === 'p') { if (race.phase === 'race' && !race.order.length) race.dist = Math.min(race.dist, leader().s + 14); return; }
      else if (k === 'v') S.celeb = next(CELEB_NAMES, S.celeb); else if (k === 'w') S.winner = next(WINNERS, S.winner); else return;
      save(); syncUI(); hudT = 0;
    });
  }
  let idleT = 0;
  if (!NATIVE) {
    const wake = () => { idleT = 0; document.body.classList.add('active'); };
    ['mousemove', 'pointerdown', 'keydown', 'touchstart'].forEach((e) => window.addEventListener(e, wake, { passive: true }));
  }

  /* ---------- race lifecycle + main loop ---------- */
  let fading = 0, fadeV = 1, ff = false, lastCeleb = '', finder = null;
  function pickSeed() { // any race, or one the chosen winner takes
    if (S.winner === 'random') { finder = null; return CORE.rand32(); }
    if (!finder || finder.want !== +S.winner) finder = new CORE.SeedFinder(+S.winner, IDS);
    for (let i = 0; i < 400 && !finder.advance(20000); i++); // normally found already, during the race before
    const seed = finder.found === null ? finder.seed : finder.found;
    finder = null;
    return seed;
  }
  function newRace() {
    race = new CORE.Race(pickSeed(), IDS);
    for (const k of race.skis) { k.px = k.rx = k.x; k.py = k.ry = k.y; k.pth = k.rth = k.th; k.pvv = k.rv = k.v; k.ppv = k.rpv = k.pv; }
    let cb; do cb = CELEBS[Math.floor(Math.random() * CELEBS.length)]; while (cb === lastCeleb && Math.random() < 0.8);
    race.celeb = lastCeleb = cb; racers.forEach(resetBody);
    buildCourse();
    racers.forEach((r) => { r.trail.length = 0; r.lean = r.pitch = r.steer = 0; r.look = null; r.lookCool = 0; });
    pLife.fill(0); ff = false; shot = null; lastTypes = []; hudT = 0;
    if (renderer && racesRun++) betweenRaces();
  }
  let racesRun = 0;
  const STEP = 1 / 120;
  function stepRace() { for (const k of race.skis) { k.px = k.x; k.py = k.y; k.pth = k.th; k.pvv = k.v; k.ppv = k.pv; } race.step(STEP); }
  function restart() { if (!fading) fading = 0.0001; }
  let now = 0, accT = 0;
  function tick(dt) {
    now += dt;
    /* The race always advances in fixed 1/120 s steps, so a race is decided by its seed alone (the winner option
       depends on that). But a frame rarely holds a whole number of steps: drawn as-is, the skis would lurch fore and
       aft against the smoothly moving camera on anything but an even 60 Hz. So each ski is drawn part-way between
       its last two steps, by however much of a step is left over. */
    accT += dt * (ff ? 8 : 1); while (accT >= STEP) { stepRace(); accT -= STEP; }
    const part = accT / STEP;
    for (const k of race.skis) {
      let dth = k.th - k.pth; while (dth > Math.PI) dth -= TAU; while (dth < -Math.PI) dth += TAU;
      k.rx = k.px + (k.x - k.px) * part; k.ry = k.py + (k.y - k.py) * part; k.rth = k.pth + dth * part;
      k.rv = k.pvv + (k.v - k.pvv) * part; k.rpv = k.ppv + (k.pv - k.ppv) * part; // what the rider's body feels
    }
    if (race.phase === 'done' && race.order[0].cel > 12.5) restart();
    if (fading) { // fade to black, swap in the next race, fade back
      const was = fading; fading += dt;
      fadeV = fading < 0.7 ? fading / 0.7 : Math.max(0, 1 - (fading - 0.9) / 0.8);
      if (was < 0.8 && fading >= 0.8) newRace();
      if (fading > 1.7) { fading = 0; fadeV = 0; }
    }
    if (S.winner !== 'random' && race.phase !== 'grid') { // line up the next race this winner takes, a little each frame
      if (!finder || finder.want !== +S.winner) finder = new CORE.SeedFinder(+S.winner, IDS);
      if (finder.found === null) finder.advance(NATIVE ? 30 : 600);
    } else if (S.winner === 'random') finder = null;
    updateBand(); updateRacers(dt, now); stepParticles(dt); updateCamera(now, dt); updateHud(dt);
  }
  function start() { newRace(); fading = 0.9; fadeV = 1; } // fades in from black

  if (NATIVE) {
    /* What the native renderer reads each frame, in JR.out:
         0 camera position (3) · 3 camera rotation (4) · 7 field of view (vertical, degrees) · 8 near plane · 9 fade to
         black 0…1 · 10 course serial · 11 start band serial · 12 scoreboard serial · 13 clock · 14 which pump jets are
         showing (bit per racer; their rings of points are in JR.jetP) · 16 the racers, PER each:
         position (3), heading (4), pitch-and-lean (4), then a rotation (4) for each of JR.parts, the hips' position (3),
         the points along the wake (1), winner's spinout 0…1 (1). */
    const PARTS = SKI_PARTS.concat(JOINTS), PER = 11 + PARTS.length * 4 + 3 + 2, out = new Float32Array(16 + PER * IDS.length);
    G.JR = {
      errors, out, per: PER, parts: PARTS, pPos, pA, pS, np: NP, band: bandPts, trN: TR_N, trailP: [], trailU: [], jetN: JET_N, jetM: JET_M, jetP: [],
      init(config, rigs) {
        try {
          configure(typeof config === 'string' ? JSON.parse(config || '{}') : config); sanitize();
          buildRacersNative(typeof rigs === 'string' ? JSON.parse(rigs) : rigs);
          racers.forEach((r) => { makeTrail(r); this.trailP.push(r.tp); this.trailU.push(r.tu); makeJet(r); this.jetP.push(r.jp); });
          start();
          return JSON.stringify({ shore: SHORE, banner: BANNER, sun: SUN.toArray(), racers: IDS.map((id) => ({ id, ski: RACERS[id].ski, rider: RACERS[id].rider })) });
        } catch (e) { fail((e && e.message) || String(e)); return ''; }
      },
      tick(dt) {
        tick(Math.min(Math.max(dt, 0), 0.05));
        camera.position.toArray(out, 0); camera.quaternion.toArray(out, 3);
        out[7] = camera.fov; out[8] = camera.near; out[9] = fadeV; out[10] = courseSerial; out[11] = bandSerial; out[12] = hudSerial; out[13] = now;
        out[14] = racers.reduce((m, r, i) => m + (r.jetOn ? 1 << i : 0), 0);
        racers.forEach((r, i) => {
          let o = 16 + i * PER;
          r.g.position.toArray(out, o); r.g.quaternion.toArray(out, o + 3); r.inner.quaternion.toArray(out, o + 7); o += 11;
          for (const nm of PARTS) { r.nodes[nm].quaternion.toArray(out, o); o += 4; }
          r.nodes.Hips.position.toArray(out, o); out[o + 3] = r.tn;
          const k = race.skis[i]; out[o + 4] = k.cel > 0 ? clamp((k.cel - 1.2) / 1.5, 0, 1) : 0;
        });
      },
      course() { // buoys, the start gate's poles and the finish buoys, in world coordinates
        const xz = (p) => [p.x, p.z];
        return JSON.stringify({ buoys: race.course.buoys.map((b) => ({ x: b.p3.x, z: b.p3.z, left: b.left })), poles: [xz(gate.A), xz(gate.B)], finish: [xz(gate.finL), xz(gate.finR)] });
      },
      hud() { return hudKey; },
      state() { return JSON.stringify({ phase: race.phase, t: race.raceT, seed: race.seed, laps: race.laps, order: race.order.map((k) => k.id), celeb: CELEBS.includes(S.celeb) ? S.celeb : race.celeb, shot: shot && shot.type, S }); },
      debug: { get race() { return race; }, S, racers, CORE, skip(sec) { for (let i = 0; i < sec * 120; i++) stepRace(); } },
    };
    return;
  }

  function resize() {
    const w = window.innerWidth, h = window.innerHeight;
    renderer.setSize(w, h, false); camera.aspect = w / h; camera.updateProjectionMatrix();
  }
  window.addEventListener('resize', resize);
  const clock = new THREE.Clock();
  /* Keeping up. The water is worked out for every pixel, so a big window on modest graphics can drop frames, most of
     all in the close, low shots. When the frame rate sags the picture is drawn at a lower resolution (and stretched to
     fit). Each change of resolution is itself a small hitch, so it only ever goes back up between races, while the
     screen is black, and only after a race that never sagged. If a step down buys nothing, the slowness isn't the
     pixels (a 30 Hz display, a throttled window): the resolution is put back and left alone. */
  const PR_MAX = Math.min(devicePixelRatio || 1, 1.75), PR_MIN = 0.5;
  const pace = { pr: PR_MAX, ceil: PR_MAX, fps: 0, low: 99, t: 0, n: 0, warm: 3, before: null, noGain: 0, on: true };
  function setPR(v) { pace.pr = v; renderer.setPixelRatio(v); resize(); }
  function keepUp(raw) { // raw: the real time since the last frame
    if (raw > 0.5) { pace.t = pace.n = 0; return; } // a hitch or a hidden window says nothing about the pace
    pace.t += raw; pace.n++;
    if (pace.t < 1) return;
    const fps = (pace.fps = pace.n / pace.t); pace.t = pace.n = 0;
    if (pace.warm > 0) { pace.warm--; return; } // the first seconds include loading
    if (fading) return;
    pace.low = Math.min(pace.low, fps);
    if (!pace.on) return;
    if (pace.before) { // the second after a step down: did it help?
      const b = pace.before; pace.before = null;
      if (fps < b.fps * 1.06) { if (++pace.noGain >= 2) { pace.on = false; setPR(PR_MAX); return; } } else pace.noGain = 0;
    }
    if (fps < 48 && pace.pr > PR_MIN) {
      pace.before = { fps }; pace.ceil = pace.pr * 0.96;
      setPR(Math.max(PR_MIN, pace.pr * clamp(Math.sqrt(fps / 58), 0.7, 0.9)));
    }
  }
  function betweenRaces() { // called while the screen is black
    if (pace.on && pace.low >= 57 && pace.pr < pace.ceil - 0.01) setPR(Math.min(pace.ceil, pace.pr * 1.1));
    pace.low = 99;
  }
  function frame() {
    requestAnimationFrame(frame);
    const raw = clock.getDelta(), dt = Math.min(raw, 0.05);
    keepUp(raw);
    tick(dt);
    $('fade').style.opacity = fadeV;
    waterU.t.value = skyMat.uniforms.t.value = now; waterU.cam.value.copy(camera.position);
    sky.position.copy(camera.position);
    pMat.uniforms.sc.value = renderer.domElement.height / (2 * Math.tan((camera.fov * Math.PI) / 360));
    idleT += dt; if (idleT > 3 && !$('panel').classList.contains('open')) document.body.classList.remove('active');
    renderer.render(scene, camera);
  }
  buildRacers().then(() => {
    racers.forEach(makeTrail); racers.forEach(makeJet); resize(); start();
    const ld = $('loading'); if (ld) ld.remove();
    frame();
    window.__jr = { get race() { return race; }, S, racers, CORE, pace, get shot() { return shot; }, skip(sec) { for (let i = 0; i < sec * 120; i++) stepRace(); } };
  }).catch((e) => fail(e.message || String(e)));
})();
