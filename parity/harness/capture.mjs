#!/usr/bin/env node
// Browser side of the palmy parity harness.
//
// For every case in ${BASE_URL}/parity/cases.json:
//   - goto ${BASE_URL}/iso/<id>
//   - wait for body[data-parity-ready] and document.fonts.ready
//   - write ../out/web/<id>.png   tight screenshot of [data-parity-root]
//   - write ../out/web/<id>.json  geometry tree per parity/CONTRACT.md
//
// Usage:
//   node capture.mjs                      all cases
//   node capture.mjs button-default       one case
//   node capture.mjs 'button-*' badge     exact ids and '*' globs
//   BASE_URL=http://localhost:3000 node capture.mjs
//
// Env:
//   BASE_URL        default http://localhost:5173
//   OUT_DIR         default <harness>/../out/web
//   CHROME_PATH     explicit browser executable (falls back to the
//                   playwright bundled chromium, then /usr/bin/chromium)
//   CASE_TIMEOUT    ms per case, default 20000
//   HEADLESS        "0" to watch the run

import { chromium } from 'playwright';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));

const BASE_URL = (process.env.BASE_URL || 'http://localhost:5173').replace(/\/+$/, '');
const OUT_DIR = process.env.OUT_DIR || path.resolve(HERE, '..', 'out', 'web');
const CASE_TIMEOUT = Number(process.env.CASE_TIMEOUT || 20000);
const HEADLESS = process.env.HEADLESS !== '0';

// Fixed conditions from CONTRACT.md "Fixed conditions".
const VIEWPORT = { width: 1280, height: 800 };
const DEVICE_SCALE_FACTOR = 1;
const MAX_DEPTH = 12;

const filters = process.argv.slice(2).filter((a) => !a.startsWith('-'));

function matchesFilter(id) {
  if (filters.length === 0) return true;
  return filters.some((f) => {
    if (f === id) return true;
    if (!f.includes('*')) return false;
    const rx = new RegExp('^' + f.split('*').map(escapeRx).join('.*') + '$');
    return rx.test(id);
  });
}
const escapeRx = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

// --- the in-page geometry walker -------------------------------------------
// Serialized into the page by page.evaluate. Must be self contained.
function collectGeometry({ maxDepth }) {
  const root = document.querySelector('[data-parity-root]');
  if (!root) throw new Error('no [data-parity-root] in document');

  const rootRect = root.getBoundingClientRect();

  // oklch()/lab()/color() computed values are converted to 8-bit sRGB by
  // painting them, so the JSON always carries rgb()/rgba() as the contract
  // requires. Legacy rgb()/rgba() values pass straight through.
  const canvas = document.createElement('canvas');
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const colorCache = new Map();

  function toRgb(value) {
    if (value == null) return value;
    const v = String(value).trim();
    if (v === '' || v === 'none') return v;
    if (/^rgba?\(/.test(v)) return v;
    if (colorCache.has(v)) return colorCache.get(v);
    let out = v;
    try {
      // Alpha is read off the source string: reading it back from the canvas
      // would quantize it to n/255.
      let alpha = 1;
      let opaque = v;
      const slash = v.match(/\/\s*([0-9.]+%?)\s*\)\s*$/);
      if (slash) {
        alpha = slash[1].endsWith('%')
          ? parseFloat(slash[1]) / 100
          : parseFloat(slash[1]);
        // Paint the colour fully opaque so the channels come back exact; the
        // alpha comes from the source string, not from a /255 pixel read.
        opaque = v.replace(/\/\s*[0-9.]+%?\s*\)\s*$/, ')');
      }
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = '#000';
      ctx.fillStyle = opaque;
      ctx.globalCompositeOperation = 'copy';
      ctx.fillRect(0, 0, 1, 1);
      const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
      if (a === 0 && alpha === 1) alpha = 0;
      out =
        alpha >= 1
          ? `rgb(${r}, ${g}, ${b})`
          : `rgba(${r}, ${g}, ${b}, ${round(alpha, 4)})`;
    } catch {
      out = v;
    }
    colorCache.set(v, out);
    return out;
  }

  function round(n, places = 3) {
    if (!Number.isFinite(n)) return 0;
    const p = Math.pow(10, places);
    return Math.round(n * p) / p;
  }

  // "8px" -> 8, "8px 4px" -> 8 (first component of an elliptical radius),
  // "normal" -> fallback.
  function px(value, fallback = 0) {
    if (value == null) return fallback;
    const m = String(value).match(/-?[\d.]+/);
    if (!m) return fallback;
    const n = parseFloat(m[0]);
    return Number.isFinite(n) ? round(n) : fallback;
  }

  function ownText(el) {
    let out = '';
    for (const node of el.childNodes) {
      if (node.nodeType === Node.TEXT_NODE) out += node.nodeValue;
    }
    return out.replace(/\s+/g, ' ').trim();
  }

  function styleOf(el) {
    const cs = getComputedStyle(el);
    // letter-spacing: normal is exactly 0 extra tracking in CSS.
    const ls = cs.letterSpacing === 'normal' ? 0 : px(cs.letterSpacing);
    // line-height: normal has no px form in getComputedStyle; keep the
    // keyword rather than invent a number.
    const lh = cs.lineHeight === 'normal' ? 'normal' : px(cs.lineHeight);
    return {
      backgroundColor: toRgb(cs.backgroundColor),
      color: toRgb(cs.color),
      borderWidth: [
        px(cs.borderTopWidth),
        px(cs.borderRightWidth),
        px(cs.borderBottomWidth),
        px(cs.borderLeftWidth),
      ],
      // One string when the four sides agree (the contract's shape), the four
      // values space separated otherwise, matching CSS shorthand order.
      borderColor: (() => {
        const sides = [
          toRgb(cs.borderTopColor),
          toRgb(cs.borderRightColor),
          toRgb(cs.borderBottomColor),
          toRgb(cs.borderLeftColor),
        ];
        return sides.every((c) => c === sides[0]) ? sides[0] : sides.join(' ');
      })(),
      borderRadius: [
        px(cs.borderTopLeftRadius),
        px(cs.borderTopRightRadius),
        px(cs.borderBottomRightRadius),
        px(cs.borderBottomLeftRadius),
      ],
      padding: [
        px(cs.paddingTop),
        px(cs.paddingRight),
        px(cs.paddingBottom),
        px(cs.paddingLeft),
      ],
      fontSize: px(cs.fontSize),
      fontWeight: Number(cs.fontWeight) || px(cs.fontWeight),
      lineHeight: lh,
      letterSpacing: ls,
      opacity: round(parseFloat(cs.opacity)),
      boxShadow: cs.boxShadow,
      textAlign: cs.textAlign,
    };
  }

  let skippedZeroArea = 0;
  let depthClipped = 0;

  function walk(el, depth) {
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) {
      skippedZeroArea++;
      // Zero-area element: drop the node but keep whatever its children
      // paint, hoisted into the parent, so nothing visible is lost.
      return depth + 1 > maxDepth ? [] : childNodesOf(el, depth);
    }
    const node = {
      tag: el.tagName.toLowerCase(),
      cls: typeof el.className === 'string' ? el.className : String(el.getAttribute('class') || ''),
      text: ownText(el),
      rect: {
        x: round(r.left - rootRect.left),
        y: round(r.top - rootRect.top),
        w: round(r.width),
        h: round(r.height),
      },
      style: styleOf(el),
      children: [],
    };
    if (depth + 1 > maxDepth) {
      if (el.children.length > 0) depthClipped++;
    } else {
      node.children = childNodesOf(el, depth);
    }
    if (el === root) {
      // Playwright clips an element screenshot on whole pixels, so the element
      // starts at a fractional offset inside its own image. Record the page
      // position; the renderer needs the same offset or every glyph lands a
      // fraction of a pixel off.
      node.pageRect = {
        x: round(r.left),
        y: round(r.top),
        w: round(r.width),
        h: round(r.height),
      };
      node.cropOffset = {
        x: round(r.left - Math.floor(r.left)),
        y: round(r.top - Math.floor(r.top)),
      };
    }
    return [node];
  }

  function childNodesOf(el, depth) {
    const out = [];
    for (const child of el.children) {
      // <template>/<script>/<style> contribute no boxes.
      const tag = child.tagName.toLowerCase();
      if (tag === 'script' || tag === 'style' || tag === 'template' || tag === 'link') continue;
      out.push(...walk(child, depth + 1));
    }
    return out;
  }

  const tree = walk(root, 0);
  if (tree.length === 0) {
    throw new Error('[data-parity-root] has zero area');
  }
  let count = 0;
  (function tally(n) {
    count++;
    n.children.forEach(tally);
  })(tree[0]);

  return { tree: tree[0], stats: { nodes: count, skippedZeroArea, depthClipped } };
}

// --- browser launch ---------------------------------------------------------
async function launchBrowser() {
  const attempts = [];
  if (process.env.CHROME_PATH) {
    attempts.push({ label: `CHROME_PATH (${process.env.CHROME_PATH})`, opts: { executablePath: process.env.CHROME_PATH } });
  }
  attempts.push({ label: 'playwright bundled chromium', opts: {} });
  attempts.push({ label: 'system /usr/bin/chromium', opts: { executablePath: '/usr/bin/chromium' } });

  let lastErr;
  for (const a of attempts) {
    try {
      const browser = await chromium.launch({
        headless: HEADLESS,
        args: ['--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb'],
        ...a.opts,
      });
      return { browser, which: a.label };
    } catch (err) {
      lastErr = err;
      console.error(`[warn] could not launch ${a.label}: ${String(err).split('\n')[0]}`);
    }
  }
  throw lastErr;
}

async function loadCases() {
  const url = `${BASE_URL}/parity/cases.json`;
  let res;
  try {
    res = await fetch(url);
  } catch (err) {
    throw new Error(
      `cannot reach ${url} (${err?.cause?.code || err?.message || err}). ` +
        'Is the web app running? Set BASE_URL if it is on another port.',
    );
  }
  if (!res.ok) throw new Error(`GET ${url} -> ${res.status} ${res.statusText}`);
  const body = await res.json();
  const raw = Array.isArray(body)
    ? body
    : Array.isArray(body?.cases)
      ? body.cases
      : null;
  if (!raw) throw new Error(`${url} is neither an array nor { cases: [...] }`);
  return raw
    .map((c) => (typeof c === 'string' ? { id: c } : c))
    .filter((c) => c && typeof c.id === 'string' && c.id.length > 0);
}

async function main() {
  await fs.mkdir(OUT_DIR, { recursive: true });

  const all = await loadCases();
  const cases = all.filter((c) => matchesFilter(c.id));
  console.log(`base url   ${BASE_URL}`);
  console.log(`out dir    ${OUT_DIR}`);
  console.log(`cases      ${cases.length} of ${all.length}${filters.length ? ` (filter: ${filters.join(' ')})` : ''}`);
  if (cases.length === 0) {
    console.log('nothing to do');
    return 0;
  }

  const { browser, which } = await launchBrowser();
  console.log(`browser    ${which} (${browser.version()})`);

  const context = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: DEVICE_SCALE_FACTOR,
    colorScheme: 'light',
    reducedMotion: 'reduce',
    forcedColors: 'none',
    locale: 'en-US',
    timezoneId: 'UTC',
    bypassCSP: true,
  });
  context.setDefaultTimeout(CASE_TIMEOUT);
  // Belt and braces: the iso route disables animation itself, this makes the
  // harness independent of that.
  await context.addInitScript(() => {
    const kill = () => {
      const s = document.createElement('style');
      s.setAttribute('data-parity-harness', '');
      s.textContent =
        '*,*::before,*::after{animation:none!important;transition:none!important;' +
        'animation-duration:0s!important;transition-duration:0s!important;' +
        'scroll-behavior:auto!important;caret-color:transparent!important}';
      document.documentElement.appendChild(s);
    };
    if (document.documentElement) kill();
    else document.addEventListener('DOMContentLoaded', kill, { once: true });
  });

  const page = await context.newPage();
  const ok = [];
  const failed = [];

  for (const c of cases) {
    const id = c.id;
    const pngPath = path.join(OUT_DIR, `${id}.png`);
    const jsonPath = path.join(OUT_DIR, `${id}.json`);
    try {
      const url = `${BASE_URL}/iso/${encodeURIComponent(id)}`;
      const resp = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: CASE_TIMEOUT });
      if (resp && resp.status() >= 400) {
        throw new Error(`${url} -> HTTP ${resp.status()}`);
      }
      await page.waitForSelector('body[data-parity-ready]', { state: 'attached', timeout: CASE_TIMEOUT });
      await page.waitForFunction(() => document.fonts.ready.then(() => true), null, {
        timeout: CASE_TIMEOUT,
      });

      const root = page.locator('[data-parity-root]');
      const n = await root.count();
      if (n === 0) throw new Error('no [data-parity-root]');
      if (n > 1) console.warn(`[warn] ${id}: ${n} [data-parity-root] elements, using the first`);
      const el = root.first();
      await el.waitFor({ state: 'visible', timeout: CASE_TIMEOUT });
      // Settle layout: two frames after fonts are in.
      await page.evaluate(
        () => new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r))),
      );

      const box = await el.boundingBox();
      if (!box || box.width <= 0 || box.height <= 0) {
        throw new Error('[data-parity-root] has no area');
      }

      const { tree, stats } = await page.evaluate(collectGeometry, { maxDepth: MAX_DEPTH });

      await el.screenshot({ path: pngPath, animations: 'disabled', caret: 'hide', scale: 'css' });
      await fs.writeFile(jsonPath, JSON.stringify(tree, null, 2) + '\n', 'utf8');

      const png = await pngSize(pngPath);
      const expect = { w: Math.round(tree.rect.w), h: Math.round(tree.rect.h) };
      const dimOk = png && png.w === expect.w && png.h === expect.h;
      console.log(
        `  ok   ${id.padEnd(32)} ${tree.rect.w}x${tree.rect.h} css  png ${png ? `${png.w}x${png.h}` : '?'}` +
          `${dimOk ? '' : ' [!] png/css size mismatch'}  nodes ${stats.nodes}` +
          `${stats.skippedZeroArea ? ` zero-area ${stats.skippedZeroArea}` : ''}` +
          `${stats.depthClipped ? ` depth-clipped ${stats.depthClipped}` : ''}`,
      );
      ok.push(id);
    } catch (err) {
      failed.push(id);
      console.error(`  FAIL ${id}: ${String(err && err.message ? err.message : err).split('\n')[0]}`);
    }
  }

  await context.close();
  await browser.close();

  console.log(
    `\n${ok.length} captured, ${failed.length} failed${failed.length ? `: ${failed.join(', ')}` : ''}`,
  );
  return failed.length === 0 ? 0 : 1;
}

// PNG IHDR width/height, so the run can assert png px == css px at DPR 1.
async function pngSize(file) {
  try {
    const fd = await fs.open(file, 'r');
    try {
      const buf = Buffer.alloc(24);
      await fd.read(buf, 0, 24, 0);
      if (buf.toString('latin1', 1, 4) !== 'PNG') return null;
      return { w: buf.readUInt32BE(16), h: buf.readUInt32BE(20) };
    } finally {
      await fd.close();
    }
  } catch {
    return null;
  }
}

main()
  .then((code) => process.exit(code))
  .catch((err) => {
    console.error(`fatal: ${err && err.message ? err.message : err}`);
    if (process.env.DEBUG) console.error(err);
    process.exit(2);
  });
