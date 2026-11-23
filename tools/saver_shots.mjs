// Renders the Flying Cars page in headless Chrome, waits for the cars to load, and
// takes a few frames. Usage: node tools/saver_shots.mjs out/saver.html out
import puppeteer from 'puppeteer-core';
const [html, outDir, prefix = "frame", cfg = ""] = process.argv.slice(2);
const browser = await puppeteer.launch({
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  headless: 'new',
  args: ['--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist', '--allow-file-access-from-files'],
});
const page = await browser.newPage();
await page.setViewport({ width: 1440, height: 900 });
page.on('console', (m) => console.log('PAGE', m.type(), m.text()));
page.on('pageerror', (e) => console.log('PAGE ERROR', e.message));
if (cfg) await page.evaluateOnNewDocument((c) => { window.SAVER_CONFIG = JSON.parse(c); }, cfg);
await page.goto('file://' + html);
try {
  await page.waitForFunction(() => !document.getElementById('loading'), { timeout: 120000 });
  console.log('scene loaded');
} catch {
  console.log('TIMEOUT waiting for scene; loading text =', await page.evaluate(() => document.getElementById('loading')?.textContent));
}
for (let i = 0; i < 4; i++) {
  await new Promise((r) => setTimeout(r, 2500));
  await page.screenshot({ path: `${outDir}/${prefix}_${i}.png` });
}
await browser.close();
