// Records the Flying Cars screen saver frame by frame (virtual clock, so it's smooth even with
// software rendering). Usage: node tools/record_saver.mjs out/saver.html out/frames 30 14 [cars|starships]
import puppeteer from 'puppeteer-core';
import fs from 'node:fs';
const [html, dir, fpsArg, secsArg, scene = 'cars'] = process.argv.slice(2);
const fps = +fpsArg || 30, secs = +secsArg || 12;
fs.mkdirSync(dir, { recursive: true });
const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || '/usr/bin/google-chrome',
  headless: 'new',
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--allow-file-access-from-files', '--no-sandbox'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1280, height: 720, deviceScaleFactor: 1 });
page.on('pageerror', (e) => console.log('PAGE ERROR', e.message));
await page.evaluateOnNewDocument((scene) => {
  window.SAVER_CONFIG = { liveries: ['macsboost', 'yonder', 'xxone'], count: scene === 'starships' ? 11 : 9, speed: 1, stars: true, manual: true };
  Math.random = (() => { let s = 20261122; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296); })();
}, scene);
await page.goto('file://' + html);
await page.waitForFunction(() => window.__ready === true, { timeout: 180000 });
// let the flock settle in for a few seconds of virtual time, then record
let ms = 0;
for (let i = 0; i < 120; i++) { ms += 1000 / 30; await page.evaluate((t) => window.__frame(t), ms); }
const total = Math.round(fps * secs);
for (let i = 0; i < total; i++) {
  ms += 1000 / fps;
  await page.evaluate((t) => window.__frame(t), ms);
  await page.screenshot({ path: `${dir}/f${String(i).padStart(4, '0')}.png` });
  if (i % 60 === 0) console.log('frame', i, '/', total);
}
await browser.close();
