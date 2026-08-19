import puppeteer from 'puppeteer-core';
import { mkdirSync } from 'node:fs';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const FPS = 30, DUR = 87.5, TOTAL = Math.ceil(DUR * FPS);
const PAGE = process.env.PAGE || 'demo.html';
const OUTDIR = process.env.OUTDIR || 'frames';
const args = process.argv.slice(2);
const mode = args[0] || 'probe';

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  args: ['--hide-scrollbars', '--force-device-scale-factor=1', '--disable-lcd-text', '--force-color-profile=srgb'],
});

async function makePage() {
  const p = await browser.newPage();
  await p.setViewport({ width: 1920, height: 1080, deviceScaleFactor: 1 });
  await p.goto('file://' + process.cwd() + '/' + PAGE, { waitUntil: 'load' });
  await p.waitForFunction('window.READY === true', { timeout: 20000 });
  await p.evaluate('document.fonts.ready.then(() => 1)');
  return p;
}

if (mode === 'probe') {
  mkdirSync(OUTDIR, { recursive: true });
  const p = await makePage();
  for (const ts of args[1].split(',')) {
    const t = parseFloat(ts);
    await p.evaluate(`SEEK(${t})`);
    await p.screenshot({ path: `${OUTDIR}/t${t.toFixed(2).replace('.', '_')}.png` });
  }
} else {
  mkdirSync(OUTDIR, { recursive: true });
  const SHARDS = 4;
  const per = Math.ceil(TOTAL / SHARDS);
  let done = 0;
  await Promise.all(Array.from({ length: SHARDS }, async (_, s) => {
    const p = await makePage();
    for (let f = s * per; f < Math.min((s + 1) * per, TOTAL); f++) {
      await p.evaluate(`SEEK(${(f / FPS).toFixed(4)})`);
      await p.screenshot({ path: `${OUTDIR}/f${String(f).padStart(5, '0')}.png` });
      if (++done % 300 === 0) console.log(`${done}/${TOTAL}`);
    }
  }));
  console.log(`rendered ${done}/${TOTAL}`);
}
await browser.close();
