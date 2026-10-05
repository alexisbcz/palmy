// Compare the browser's boxes with palmy's for one case.
//
//   node tools/geomdiff.mjs <case-id>
//
// The browser tree and palmy's tree are not the same shape, so this compares
// the root box exactly and then matches remaining boxes greedily by size, which
// is enough to spot a wrong padding, radius or height.
import { readFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Derived from this file's location so it follows the tree it is run from;
// PARITY_ROOT and PARITY_WEB override it, as in tools/diff-all.sh.
const ROOT = process.env.PARITY_ROOT || path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const WEB = process.env.PARITY_WEB || `${ROOT}/out/web`;
const id = process.argv[2];
if (!id) { console.error("usage: geomdiff.mjs <case-id>"); process.exit(2); }

const webPath = `${WEB}/${id}.json`;
const odinPath = `${ROOT}/out/odin/${id}.geom.json`;
if (!existsSync(webPath)) { console.error(`no browser capture for ${id}`); process.exit(2); }
if (!existsSync(odinPath)) { console.error(`no palmy render for ${id}`); process.exit(2); }

const web = JSON.parse(readFileSync(webPath, "utf8"));
const odin = JSON.parse(readFileSync(odinPath, "utf8"));

// palmy node 0 is the canvas root, node 1 the positioning wrapper, node 2 the
// component itself.
const comp = odin.nodes[2];
if (!comp) { console.error("palmy produced no component node"); process.exit(1); }

const f = (v) => Number(v).toFixed(2);
const d = (a, b) => {
  const delta = a - b;
  const mark = Math.abs(delta) < 0.51 ? "ok " : "OFF";
  return `${mark} browser ${f(a)}  palmy ${f(b)}  delta ${delta >= 0 ? "+" : ""}${f(delta)}`;
};

console.log(`case ${id}`);
console.log(`  width   ${d(web.rect.w, comp.rect.w)}`);
console.log(`  height  ${d(web.rect.h, comp.rect.h)}`);

const toHex = (rgb) => {
  const m = String(rgb).match(/rgba?\(([^)]+)\)/);
  if (!m) return rgb;
  const [r, g, b, a = 1] = m[1].split(",").map(Number);
  const h = (v) => Math.round(v).toString(16).padStart(2, "0");
  return `#${h(r)}${h(g)}${h(b)}${a < 1 ? h(a * 255) : "ff"}`;
};
console.log(`  bg      browser ${toHex(web.style.backgroundColor)}  palmy ${comp.bg}`);
console.log(`  fg      browser ${toHex(web.style.color)}  palmy ${comp.fg}`);
console.log(`  radius  browser [${web.style.borderRadius}]  palmy [${comp.radius.map(f)}]`);
console.log(`  font    browser ${web.style.fontSize}/${web.style.lineHeight} w${web.style.fontWeight}  palmy ${comp.font} ${comp.weight}`);

// Flatten both trees and report the boxes palmy has no counterpart for.
const webBoxes = [];
(function walk(n, ox = 0, oy = 0) {
  webBoxes.push({ tag: n.tag, x: n.rect.x, y: n.rect.y, w: n.rect.w, h: n.rect.h, text: n.text });
  for (const c of n.children || []) walk(c, ox, oy);
})(web);

const odinBoxes = odin.nodes.slice(2).map((n) => ({ ...n.rect, kind: n.kind, text: n.text }));
console.log(`  boxes   browser ${webBoxes.length}  palmy ${odinBoxes.length}`);

const unmatched = [];
const used = new Set();
for (const wb of webBoxes) {
  let best = -1, bestErr = Infinity;
  odinBoxes.forEach((ob, i) => {
    if (used.has(i)) return;
    const err = Math.abs(wb.x - ob.x) + Math.abs(wb.y - ob.y) + Math.abs(wb.w - ob.w) + Math.abs(wb.h - ob.h);
    if (err < bestErr) { bestErr = err; best = i; }
  });
  if (best >= 0 && bestErr <= 2) used.add(best);
  else unmatched.push({ wb, bestErr });
}
if (unmatched.length) {
  console.log(`  unmatched browser boxes (${unmatched.length}):`);
  for (const u of unmatched.slice(0, 10)) {
    console.log(`    <${u.wb.tag}> ${f(u.wb.x)},${f(u.wb.y)} ${f(u.wb.w)}x${f(u.wb.h)}` +
      (u.wb.text ? ` "${u.wb.text.slice(0, 24)}"` : "") + `  nearest off by ${f(u.bestErr)}`);
  }
}
