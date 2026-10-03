// Extract the lucide icons shadcn imports and emit an Odin table.
//
// Every primitive (circle, line, rect, polyline, ...) is converted to a single
// SVG path string here, so the Odin renderer only needs a path parser.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const ICON_DIR = "/home/alex/Work/palmy/parity/web/node_modules/lucide-react/dist/esm/icons";
const OUT_PATH = "/home/alex/Work/palmy/shadcn/icons.odin";

// Additive: keep every icon already generated and add whatever is asked for.
// Several agents regenerate this file, and a destructive rewrite would silently
// drop the icons the others depend on.
const existing = (() => {
  try {
    const src = readFileSync(OUT_PATH, "utf8");
    return [...src.matchAll(/name = "([a-z0-9-]+)"/g)].map((m) => m[1]);
  } catch {
    return [];
  }
})();

const kebabToPascal = (s) => s.split("-").map((w) => w[0].toUpperCase() + w.slice(1)).join("");
const WANTED = [...new Set([...existing.map(kebabToPascal), ...process.argv.slice(2)])];

const K = 0.5522847498307936; // circle -> cubic bezier

const num = (v) => Number(v);

// ---------------------------------------------------------------------------
// Path normalisation.
//
// The Odin parser only handles absolute M / L / C / Z. Everything else is
// resolved here: relative commands, shorthands, and elliptical arcs. Paths are
// also concatenated afterwards, so every subpath must be absolute or a leading
// relative moveto would compound off the previous path's end point.
// ---------------------------------------------------------------------------

function tokenizePath(d) {
  // Arc flags are single-character booleans and the spec allows them to be
  // written with no separator: `A2 2 0 0022 17` means large-arc 0, sweep 0,
  // x 22 — not the number 22. A greedy number scanner silently produces NaN
  // coordinates here, so the scanner has to know which parameter it is on.
  const out = [];
  const isCmd = (c) => /[MmLlHhVvCcSsQqTtAaZz]/.test(c);
  const isSep = (c) => /[\s,]/.test(c);
  const numRe = /^-?(?:\d*\.\d+|\d+)(?:[eE][-+]?\d+)?/;

  let i = 0;
  let cmd = null;
  let argIndex = 0;

  while (i < d.length) {
    const c = d[i];
    if (isSep(c)) { i++; continue; }
    if (isCmd(c)) { cmd = c; argIndex = 0; out.push(c); i++; continue; }

    const arc = cmd === "A" || cmd === "a";
    const argsPerCmd = { A: 7, a: 7, C: 6, c: 6, S: 4, s: 4, Q: 4, q: 4,
                         T: 2, t: 2, M: 2, m: 2, L: 2, l: 2, H: 1, h: 1, V: 1, v: 1 };
    const n = argsPerCmd[cmd] ?? 2;
    const slot = argIndex % n;

    if (arc && (slot === 3 || slot === 4)) {
      // Exactly one digit, however it is written.
      out.push(Number(d[i]));
      i++;
    } else {
      const m = numRe.exec(d.slice(i));
      if (!m) { i++; continue; }
      out.push(Number(m[0]));
      i += m[0].length;
    }
    argIndex++;
  }
  return out;
}

// Elliptical arc -> cubic beziers (SVG implementation notes F.6.5).
function arcToCubics(x1, y1, rx, ry, phiDeg, fa, fs, x2, y2) {
  if (x1 === x2 && y1 === y2) return [];
  if (!rx || !ry) return [["L", x2, y2]];
  rx = Math.abs(rx); ry = Math.abs(ry);
  const phi = (phiDeg * Math.PI) / 180;
  const cosp = Math.cos(phi), sinp = Math.sin(phi);
  const dx = (x1 - x2) / 2, dy = (y1 - y2) / 2;
  const x1p = cosp * dx + sinp * dy;
  const y1p = -sinp * dx + cosp * dy;

  let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry);
  if (lambda > 1) { const s = Math.sqrt(lambda); rx *= s; ry *= s; }

  const sign = fa === fs ? -1 : 1;
  const num = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p;
  const den = rx * rx * y1p * y1p + ry * ry * x1p * x1p;
  const co = sign * Math.sqrt(Math.max(0, num / den));
  const cxp = (co * rx * y1p) / ry;
  const cyp = (-co * ry * x1p) / rx;
  const cx = cosp * cxp - sinp * cyp + (x1 + x2) / 2;
  const cy = sinp * cxp + cosp * cyp + (y1 + y2) / 2;

  const ang = (ux, uy, vx, vy) => {
    const dot = ux * vx + uy * vy;
    const len = Math.hypot(ux, uy) * Math.hypot(vx, vy);
    let a = Math.acos(Math.min(1, Math.max(-1, dot / len)));
    if (ux * vy - uy * vx < 0) a = -a;
    return a;
  };

  const theta1 = ang(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry);
  let dtheta = ang((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry);
  if (!fs && dtheta > 0) dtheta -= 2 * Math.PI;
  if (fs && dtheta < 0) dtheta += 2 * Math.PI;

  const segs = Math.ceil(Math.abs(dtheta / (Math.PI / 2)));
  const delta = dtheta / segs;
  const t = (4 / 3) * Math.tan(delta / 4);
  const out = [];
  let th = theta1;
  for (let i = 0; i < segs; i++) {
    const cos1 = Math.cos(th), sin1 = Math.sin(th);
    const th2 = th + delta;
    const cos2 = Math.cos(th2), sin2 = Math.sin(th2);

    const p1x = cx + rx * cosp * cos1 - ry * sinp * sin1;
    const p1y = cy + rx * sinp * cos1 + ry * cosp * sin1;
    const p2x = cx + rx * cosp * cos2 - ry * sinp * sin2;
    const p2y = cy + rx * sinp * cos2 + ry * cosp * sin2;

    const d1x = -rx * cosp * sin1 - ry * sinp * cos1;
    const d1y = -rx * sinp * sin1 + ry * cosp * cos1;
    const d2x = -rx * cosp * sin2 - ry * sinp * cos2;
    const d2y = -rx * sinp * sin2 + ry * cosp * cos2;

    out.push(["C", p1x + t * d1x, p1y + t * d1y, p2x - t * d2x, p2y - t * d2y, p2x, p2y]);
    th = th2;
  }
  return out;
}

function normalizePath(d) {
  const tk = tokenizePath(d);
  const ops = [];
  let i = 0, cmd = null;
  let x = 0, y = 0, sx = 0, sy = 0;
  let lastC = null, lastQ = null;
  const n = () => tk[i++];

  while (i < tk.length) {
    if (typeof tk[i] === "string") cmd = tk[i++];
    if (cmd == null) break;
    const rel = cmd === cmd.toLowerCase() && cmd !== "Z" && cmd !== "z";
    const C = cmd.toUpperCase();

    if (C === "Z") { ops.push(["Z"]); x = sx; y = sy; lastC = lastQ = null; continue; }

    switch (C) {
      case "M": {
        let px = n(), py = n();
        if (rel) { px += x; py += y; }
        x = px; y = py; sx = x; sy = y;
        ops.push(["M", x, y]);
        cmd = rel ? "l" : "L"; // subsequent pairs are implicit linetos
        lastC = lastQ = null;
        break;
      }
      case "L": {
        let px = n(), py = n();
        if (rel) { px += x; py += y; }
        x = px; y = py; ops.push(["L", x, y]); lastC = lastQ = null;
        break;
      }
      case "H": { let px = n(); if (rel) px += x; x = px; ops.push(["L", x, y]); lastC = lastQ = null; break; }
      case "V": { let py = n(); if (rel) py += y; y = py; ops.push(["L", x, y]); lastC = lastQ = null; break; }
      case "C": {
        let c1x = n(), c1y = n(), c2x = n(), c2y = n(), px = n(), py = n();
        if (rel) { c1x += x; c1y += y; c2x += x; c2y += y; px += x; py += y; }
        ops.push(["C", c1x, c1y, c2x, c2y, px, py]);
        lastC = [c2x, c2y]; lastQ = null; x = px; y = py;
        break;
      }
      case "S": {
        let c2x = n(), c2y = n(), px = n(), py = n();
        if (rel) { c2x += x; c2y += y; px += x; py += y; }
        const c1 = lastC ? [2 * x - lastC[0], 2 * y - lastC[1]] : [x, y];
        ops.push(["C", c1[0], c1[1], c2x, c2y, px, py]);
        lastC = [c2x, c2y]; lastQ = null; x = px; y = py;
        break;
      }
      case "Q": {
        let qx = n(), qy = n(), px = n(), py = n();
        if (rel) { qx += x; qy += y; px += x; py += y; }
        ops.push(["C", x + (2 / 3) * (qx - x), y + (2 / 3) * (qy - y),
                       px + (2 / 3) * (qx - px), py + (2 / 3) * (qy - py), px, py]);
        lastQ = [qx, qy]; lastC = null; x = px; y = py;
        break;
      }
      case "T": {
        let px = n(), py = n();
        if (rel) { px += x; py += y; }
        const q = lastQ ? [2 * x - lastQ[0], 2 * y - lastQ[1]] : [x, y];
        ops.push(["C", x + (2 / 3) * (q[0] - x), y + (2 / 3) * (q[1] - y),
                       px + (2 / 3) * (q[0] - px), py + (2 / 3) * (q[1] - py), px, py]);
        lastQ = q; lastC = null; x = px; y = py;
        break;
      }
      case "A": {
        const rx = n(), ry = n(), rot = n(), fa = n(), fs = n();
        let px = n(), py = n();
        if (rel) { px += x; py += y; }
        for (const seg of arcToCubics(x, y, rx, ry, rot, fa, fs, px, py)) ops.push(seg);
        x = px; y = py; lastC = lastQ = null;
        break;
      }
      default:
        return d; // unknown command: leave it alone rather than mangle it
    }
  }

  const f = (v) => (Math.round(v * 1000) / 1000).toString();
  return ops.map((o) => o[0] + o.slice(1).map(f).join(" ")).join(" ");
}


function circleToPath(cx, cy, rx, ry) {
  const [x, y] = [num(cx), num(cy)];
  const [a, b] = [num(rx), num(ry)];
  const ox = a * K, oy = b * K;
  return [
    `M${x - a} ${y}`,
    `C${x - a} ${y - oy} ${x - ox} ${y - b} ${x} ${y - b}`,
    `C${x + ox} ${y - b} ${x + a} ${y - oy} ${x + a} ${y}`,
    `C${x + a} ${y + oy} ${x + ox} ${y + b} ${x} ${y + b}`,
    `C${x - ox} ${y + b} ${x - a} ${y + oy} ${x - a} ${y}`,
    "Z",
  ].join(" ");
}

function rectToPath(a) {
  const x = num(a.x), y = num(a.y), w = num(a.width), h = num(a.height);
  const r = Math.min(num(a.rx ?? a.ry ?? 0), w / 2, h / 2);
  if (!r) return `M${x} ${y} L${x + w} ${y} L${x + w} ${y + h} L${x} ${y + h} Z`;
  const o = r * K;
  return [
    `M${x + r} ${y}`,
    `L${x + w - r} ${y}`,
    `C${x + w - r + o} ${y} ${x + w} ${y + r - o} ${x + w} ${y + r}`,
    `L${x + w} ${y + h - r}`,
    `C${x + w} ${y + h - r + o} ${x + w - r + o} ${y + h} ${x + w - r} ${y + h}`,
    `L${x + r} ${y + h}`,
    `C${x + r - o} ${y + h} ${x} ${y + h - r + o} ${x} ${y + h - r}`,
    `L${x} ${y + r}`,
    `C${x} ${y + r - o} ${x + r - o} ${y} ${x + r} ${y}`,
    "Z",
  ].join(" ");
}

function pointsToPath(points, close) {
  const pts = String(points).trim().split(/[\s,]+/).map(Number);
  let d = "";
  for (let i = 0; i + 1 < pts.length; i += 2) {
    d += (i === 0 ? "M" : " L") + pts[i] + " " + pts[i + 1];
  }
  return close ? d + " Z" : d;
}

function nodeToPath([tag, attrs]) {
  switch (tag) {
    case "path": return normalizePath(String(attrs.d));
    case "circle": return circleToPath(attrs.cx, attrs.cy, attrs.r, attrs.r);
    case "ellipse": return circleToPath(attrs.cx, attrs.cy, attrs.rx, attrs.ry);
    case "line": return `M${attrs.x1} ${attrs.y1} L${attrs.x2} ${attrs.y2}`;
    case "rect": return rectToPath(attrs);
    case "polyline": return pointsToPath(attrs.points, false);
    case "polygon": return pointsToPath(attrs.points, true);
    default: return null;
  }
}

// Build name -> iconData over every shipped icon.
const byName = new Map();
for (const file of readdirSync(ICON_DIR)) {
  if (!file.endsWith(".mjs")) continue;
  const src = readFileSync(join(ICON_DIR, file), "utf8");
  const m = src.match(/const __iconData = (\{[\s\S]*?\n\});/);
  if (!m) continue;
  let data;
  try {
    data = new Function(`return ${m[1]}`)();
  } catch {
    continue;
  }
  byName.set(data.name, data);
}

// lucide renames icons and keeps the old names as aliases; map the ones
// shadcn still imports under their historical names.
const ALIASES = {
  "loader2": "loader-circle",
  "more-horizontal": "ellipsis",
  "more-vertical": "ellipsis-vertical",
};

const pascalToKebab = (s) =>
  s.replace(/Icon$/, "")
    .replace(/([a-z0-9])([A-Z])/g, "$1-$2")
    .replace(/([A-Z])([A-Z][a-z])/g, "$1-$2")
    .toLowerCase();

const out = [];
const seen = new Set();
const missing = [];
for (const want of WANTED) {
  let kebab = pascalToKebab(want);
  if (!byName.has(kebab) && ALIASES[kebab]) kebab = ALIASES[kebab];
  const data = byName.get(kebab);
  if (!data) { missing.push(`${want} (looked for "${kebab}")`); continue; }
  const d = data.node.map(nodeToPath).filter(Boolean).join(" ");
  if (!d) { missing.push(`${want} (no convertible shapes)`); continue; }
  const name = "ICON_" + kebab.replace(/-/g, "_").toUpperCase();
  if (seen.has(name)) continue; // several agents may ask for the same icon
  seen.add(name);
  out.push({ const: name, name: kebab, d });
}

const odin = `package shadcn

// Generated by parity/tools/gen-icons.mjs from lucide-react ${JSON.parse(
  readFileSync("/home/alex/Work/palmy/parity/web/node_modules/lucide-react/package.json", "utf8")
).version}.
//
// Every lucide primitive has been converted to a single path string, so the
// renderer only needs a path parser. The geometry is lucide's; the rasterising
// is palmy's.

import p "palmy:."

${out
  .map(
    (i) =>
      `${i.const} :: p.Icon{name = "${i.name}", d = "${i.d.replace(/"/g, '\\"')}", view = 24, stroke = 2}`
  )
  .join("\n")}
`;

writeFileSync(OUT_PATH, odin);
console.log(`wrote ${out.length} icons`);
if (missing.length) console.log("MISSING:", missing.join(", "));
