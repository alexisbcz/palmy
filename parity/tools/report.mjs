// Turn out/diff/metrics.ndjson into a readable report.
import { readFileSync, writeFileSync, existsSync, readdirSync } from "node:fs";

const ROOT = "/home/alex/Work/palmy/parity";
const lines = existsSync(`${ROOT}/out/diff/metrics.ndjson`)
  ? readFileSync(`${ROOT}/out/diff/metrics.ndjson`, "utf8").trim().split("\n").filter(Boolean)
  : [];

const rows = lines.map((l) => JSON.parse(l));
const done = rows.filter((r) => r.status === "ok");
const missing = rows.filter((r) => r.status !== "ok");

const allCases = existsSync(`${ROOT}/out/web`)
  ? readdirSync(`${ROOT}/out/web`).filter((f) => f.endsWith(".png")).map((f) => f.slice(0, -4))
  : [];

const byComponent = new Map();
for (const r of rows) {
  const comp = r.id.split("-")[0];
  if (!byComponent.has(comp)) byComponent.set(comp, []);
  byComponent.get(comp).push(r);
}

const n = (v, d = 2) => (v === undefined ? "—" : Number(v).toFixed(d));
const sortKey = (r) => (r.status === "ok" ? r.metrics.mae : 1e9);
done.sort((a, b) => sortKey(a) - sortKey(b));

const mean = (xs) => (xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : 0);
const overallMae = mean(done.map((r) => r.metrics.mae));
const overallWithin2 = mean(done.map((r) => r.metrics.within_2_pct));
const sizeMismatches = done.filter((r) => !r.metrics.size_match);

let md = `# shadcn/ui parity report

Browser (Chromium, shadcn Base UI) vs palmy (Odin, software rasterizer, Wayland).
Both sides use the same four static Geist TTFs with kerning and ligatures off.

- cases captured from the browser: **${allCases.length}**
- cases rendered by palmy: **${done.length}**
- not implemented yet: **${missing.length}**
- mean absolute error across implemented cases: **${n(overallMae, 3)}/255**
- mean share of pixels within 2/255: **${n(overallWithin2)}%**
- size mismatches (layout wrong, not just antialiasing): **${sizeMismatches.length}**

A mean absolute error of 0 is not reachable: Chromium rasterises glyphs through
FreeType with its own hinting and gamma, palmy uses stb_truetype with grayscale
coverage. Geometry, colour and layout can match exactly, and the size column is
where that is visible.

## Per case, best first

| case | size | mae | within 2/255 | within 8/255 | worst row |
| --- | --- | --- | --- | --- | --- |
`;

for (const r of done) {
  const m = r.metrics;
  md += `| \`${r.id}\` | ${m.width}x${m.height}${m.size_match ? "" : " ⚠"} | ${n(m.mae, 3)} | ${n(m.within_2_pct)}% | ${n(m.within_8_pct)}% | ${m.worst_row} |\n`;
}

if (missing.length) {
  md += `\n## Captured but not implemented\n\n`;
  md += missing.map((r) => `- \`${r.id}\``).join("\n") + "\n";
}

md += `\n## By component\n\n| component | cases | implemented | mean mae |\n| --- | --- | --- | --- |\n`;
for (const [comp, rs] of [...byComponent.entries()].sort()) {
  const ok = rs.filter((r) => r.status === "ok");
  md += `| ${comp} | ${rs.length} | ${ok.length} | ${ok.length ? n(mean(ok.map((r) => r.metrics.mae)), 3) : "—"} |\n`;
}

writeFileSync(`${ROOT}/out/report.md`, md);

// A browsable HTML version with the triptychs inline.
let html = `<!doctype html><meta charset="utf-8"><title>shadcn parity</title>
<style>
 :root{color-scheme:dark}
 body{background:#09090b;color:#e4e4e7;font:14px/1.5 ui-sans-serif,system-ui;margin:0;padding:32px}
 h1{font-size:20px;margin:0 0 4px}
 .sub{color:#a1a1aa;margin-bottom:24px}
 .stats{display:flex;gap:24px;flex-wrap:wrap;margin-bottom:28px}
 .stat{background:#18181b;border:1px solid #27272a;border-radius:12px;padding:12px 16px;min-width:140px}
 .stat b{display:block;font-size:22px}
 .case{background:#18181b;border:1px solid #27272a;border-radius:12px;padding:12px;margin-bottom:14px}
 .case h3{margin:0 0 6px;font-size:13px;font-family:ui-monospace,monospace}
 .m{color:#a1a1aa;font-size:12px;margin-bottom:8px}
 img{max-width:100%;image-rendering:pixelated;border-radius:6px;background:#000}
 .bad{color:#fb7185}.good{color:#4ade80}
</style>
<h1>shadcn/ui parity</h1>
<div class=sub>left: Chromium &middot; middle: palmy (Odin) &middot; right: difference heat map</div>
<div class=stats>
 <div class=stat><b>${allCases.length}</b>cases captured</div>
 <div class=stat><b>${done.length}</b>rendered by palmy</div>
 <div class=stat><b>${n(overallMae, 2)}</b>mean abs error /255</div>
 <div class=stat><b>${n(overallWithin2, 1)}%</b>pixels within 2/255</div>
 <div class=stat><b>${sizeMismatches.length}</b>size mismatches</div>
</div>`;

for (const r of done) {
  const m = r.metrics;
  html += `<div class=case><h3>${r.id}</h3>
  <div class=m>${m.width}&times;${m.height} ${m.size_match ? "" : "<span class=bad>size mismatch</span>"}
   &middot; mae <b class="${m.mae < 6 ? "good" : "bad"}">${n(m.mae, 3)}</b>
   &middot; within 2/255 ${n(m.within_2_pct)}% &middot; within 8/255 ${n(m.within_8_pct)}%</div>
  <img loading=lazy src="diff/${r.id}.png"></div>`;
}

writeFileSync(`${ROOT}/out/report.html`, html);
console.log(`report: ${done.length} cases, mean mae ${n(overallMae, 3)}, ${missing.length} not implemented`);
