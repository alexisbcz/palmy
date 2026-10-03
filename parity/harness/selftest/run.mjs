// Self-test: boot the stub server, capture its two cases, assert the output.
// node selftest/run.mjs   (or: npm run selftest)
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 5174);
const BASE = `http://localhost:${PORT}`;
const OUT = path.join(HERE, 'out');

const fails = [];
const check = (name, cond, got) => {
  if (cond) console.log(`  pass  ${name}`);
  else {
    console.log(`  FAIL  ${name}${got === undefined ? '' : ` -> got ${JSON.stringify(got)}`}`);
    fails.push(name);
  }
};

const server = spawn(process.execPath, [path.join(HERE, 'server.mjs')], {
  env: { ...process.env, PORT: String(PORT) },
  stdio: 'inherit',
});
const stop = () => server.kill();
process.on('exit', stop);

async function waitForServer() {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`${BASE}/parity/cases.json`);
      if (r.ok) return;
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('stub server did not come up');
}

function pngSize(buf) {
  return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
}

try {
  await waitForServer();
  await fs.rm(OUT, { recursive: true, force: true });

  const code = await new Promise((resolve) => {
    const p = spawn(process.execPath, [path.join(HERE, '..', 'capture.mjs')], {
      env: { ...process.env, BASE_URL: BASE, OUT_DIR: OUT },
      stdio: 'inherit',
    });
    p.on('close', resolve);
  });
  // selftest-missing is a deliberate failure, so exit code 1 is expected.
  check('capture survived the broken case', code === 1, code);

  const basic = JSON.parse(await fs.readFile(path.join(OUT, 'selftest-basic.json'), 'utf8'));
  const png = pngSize(await fs.readFile(path.join(OUT, 'selftest-basic.png')));

  check('root rect is 0,0 300x120', JSON.stringify(basic.rect) === JSON.stringify({ x: 0, y: 0, w: 300, h: 120 }), basic.rect);
  check('png px == css px at DPR 1', png.w === 300 && png.h === 120, png);
  check('root own text', basic.text === 'Hello parity', basic.text);
  check('root backgroundColor', basic.style.backgroundColor === 'rgb(23, 23, 23)', basic.style.backgroundColor);
  check('root borderWidth [t,r,b,l]', String(basic.style.borderWidth) === '1,1,1,1', basic.style.borderWidth);
  check('root borderRadius [tl,tr,br,bl]', String(basic.style.borderRadius) === '8,8,8,8', basic.style.borderRadius);
  check('root padding [t,r,b,l]', String(basic.style.padding) === '8,16,8,16', basic.style.padding);

  const inner = basic.children.find((c) => c.cls === 'inner');
  // border 1 + padding-left 16 + margin-left 20 = 37; 1 + 8 + a 20px line + 10 margin = 39
  check('child rect is relative to the root', inner && JSON.stringify(inner.rect) === JSON.stringify({ x: 37, y: 39, w: 100, h: 40 }), inner && inner.rect);
  check('oklch resolved to rgb()', inner && inner.style.backgroundColor === 'rgb(245, 74, 0)', inner && inner.style.backgroundColor);

  const hoisted = basic.children.find((c) => c.cls === 'translucent');
  check('child of a zero-area element is kept', !!hoisted);
  check('rgba alpha preserved', hoisted && hoisted.style.backgroundColor === 'rgba(0, 128, 255, 0.5)', hoisted && hoisted.style.backgroundColor);
  const oka = basic.children.find((c) => c.cls === 'oklcha');
  check('oklch with alpha -> rgba()', oka && oka.style.backgroundColor === 'rgba(0, 116, 122, 0.4)', oka && oka.style.backgroundColor);

  const deep = JSON.parse(await fs.readFile(path.join(OUT, 'selftest-deep.json'), 'utf8'));
  let d = 0;
  for (let n = deep; n.children.length; n = n.children[0]) d++;
  check('depth capped at 12', d === 12, d);

  console.log(fails.length ? `\nselftest: ${fails.length} FAILED: ${fails.join(', ')}` : '\nselftest: all checks passed');
} finally {
  stop();
}
process.exit(fails.length ? 1 : 0);
