// Checks the jet racer script the way the macOS screen saver runs it: in a bare JavaScript context (no page, no
// console, no timers), with three.js for its maths only.
//   node tools/jetrace_test.js <three.min.js> [races]
const fs = require('fs'), path = require('path'), vm = require('vm');
const [three, nRaces = '30'] = process.argv.slice(2);
const src = path.join(__dirname, '..', 'Saver', 'src');
const rigs = fs.readFileSync(path.join(src, 'jetrace', 'rigs.json'), 'utf8');
function boot(config) {
  const ctx = vm.createContext({});
  vm.runInContext(fs.readFileSync(three, 'utf8'), ctx, { filename: 'three.min.js' });
  vm.runInContext(fs.readFileSync(path.join(src, 'jetrace.js'), 'utf8'), ctx, { filename: 'jetrace.js' });
  const JR = vm.runInContext('JR', ctx);
  const info = JR.init(JSON.stringify(config), rigs);
  if (!info || JR.errors.length) throw new Error('init failed: ' + JR.errors.join('; '));
  return { JR, info: JSON.parse(info) };
}
const finite = (a, what) => { for (let i = 0; i < a.length; i++) if (!Number.isFinite(a[i])) throw new Error(what + ' not finite at ' + i); };
let fails = 0;
const check = (ok, msg) => { if (!ok) { fails++; console.log('FAIL', msg); } };

// 1. a whole race, frame by frame, as the saver steps it
{
  const { JR, info } = boot({});
  check(info.shore.length > 100 && info.racers.length === 3, 'static scene');
  let frames = 0, courses = new Set(), maxP = 0, sawSnap = false, sawSpin = false, sawCeleb = false;
  const t0 = Date.now();
  for (let t = 0; t < 150; t += 1 / 60) {
    JR.tick(1 / 60); frames++;
    finite(JR.out, 'out');
    courses.add(JR.out[10]);
    let alive = 0; for (let i = 0; i < JR.np; i++) if (JR.pA[i] > 0) alive++;
    maxP = Math.max(maxP, alive);
    const st = JSON.parse(JR.state());
    if (st.phase === 'race' && st.t < 0.3) sawSnap = true;
    if (JR.out[16 + JR.per - 1] > 0.2 || JR.out[16 + 2 * JR.per - 1] > 0.2 || JR.out[16 + 3 * JR.per - 1] > 0.2) sawSpin = true;
    if (st.shot === 'winner') sawCeleb = true;
  }
  const hud = JSON.parse(JR.hud()), course = JSON.parse(JR.course());
  console.log(`race: ${frames} frames in ${Date.now() - t0} ms, particles up to ${maxP}, courses ${[...courses].join(',')}, buoys ${course.buoys.length}, board`, hud.rows.map((r) => r.id + ' ' + r.gap).join(' | '));
  check(courses.size >= 2, 'a second race should have started'); check(sawSnap && sawSpin && sawCeleb, 'start, spinout and winner shot');
  check(maxP > 300, 'spray'); check(course.buoys.length >= 7 && course.poles.length === 2 && course.finish.length === 2, 'course');
  check(JR.band.every(Number.isFinite), 'band');
}

// 2. the winner option: the chosen racer wins every race; left on random, all three win sometimes
for (const want of ['16', '8', '3', 'random']) {
  const { JR } = boot({ winner: want, celebration: 'backflip' });
  const wins = { 16: 0, 8: 0, 3: 0 }, n = want === 'random' ? +nRaces : Math.ceil(+nRaces / 3);
  let serial = JR.out[10], slow = 0;
  for (let r = 0; r < n; r++) {
    let st, guard = 0;
    do { // a frame now and then keeps the next-race search going, then jump ahead
      const t0 = Date.now(); JR.tick(1 / 60); slow = Math.max(slow, Date.now() - t0);
      JR.debug.skip(0.5); st = JSON.parse(JR.state());
    } while (!st.order.length && guard++ < 2000);
    wins[st.order[0]]++;
    check(st.celeb === 'backflip', 'celebration option');
    while (JR.out[10] === serial && guard++ < 6000) { JR.tick(1 / 20); JR.debug.skip(0.5); }
    serial = JR.out[10];
  }
  console.log(`winner=${want}: wins`, JSON.stringify(wins), `slowest frame ${slow} ms`);
  if (want === 'random') check(wins[16] && wins[8] && wins[3], 'random should let everyone win');
  else check(wins[want] === n, `${want} should win all ${n}`);
}

// 3. every option value is accepted, and nonsense falls back to the defaults
{
  const { JR } = boot({ winner: '99', celebration: 'moonwalk', camera: 'nope', follow: 'x', board: false, captions: true });
  const S = JSON.parse(JR.state()).S;
  check(S.winner === 'random' && S.celeb === 'random' && S.camera === 'director' && S.follow === 'leader' && S.board === false && S.caption === true, 'bad options fall back: ' + JSON.stringify(S));
  for (const camera of ['chase', 'onboard', 'side', 'front', 'heli', 'blimp', 'buoy', 'orbit', 'finish'])
    for (const celebration of ['shake', 'bow', 'bow2', 'backflip', 'dab', 'cart', 'mower']) {
      const b = boot({ camera, celebration, follow: '8' });
      for (let i = 0; i < 40; i++) b.JR.tick(1 / 30);
      b.JR.debug.skip(140);
      for (let i = 0; i < 400; i++) { b.JR.tick(1 / 30); finite(b.JR.out, camera + '/' + celebration); }
    }
}
console.log(fails ? `${fails} FAILED` : 'ALL OK');
process.exit(fails ? 1 : 0);
