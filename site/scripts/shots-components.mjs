#!/usr/bin/env node
/**
 * Component screenshots for the documentation site.
 *
 * `parity/out/odin/` already holds one PNG per parity case, rasterised by
 * palmy itself with no browser anywhere near it — which is exactly what a
 * component page promises under "Rendered by palmy". Nothing has to be
 * re-rendered; the cases only have to be mapped onto component slugs and
 * framed.
 *
 * Two things are done here beyond copying:
 *
 *  - A component with several cases is reduced to one. The ranking prefers
 *    `<slug>-default`, then the `-open` case for the widgets that are a flat
 *    nothing when closed, and pushes `@hover`/`@focus`, `-disabled`,
 *    `-invalid` and the colour variants to the back. A page should open on the
 *    component, not on one of its error states.
 *
 *  - Each case is centred on a 16:9 canvas. The parity renders are tight crops
 *    — `button-default` is 68x32 — and the site draws them `object-cover` in a
 *    16/9 box, so a straight copy is a thirteen-fold upscale of a button. The
 *    pixels that land in the canvas are the parity pixels, at an integer
 *    scale, nearest-neighbour, on the case's own background colour; nothing is
 *    resampled unless the case is taller than the frame.
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "../..");
const SRC = path.join(ROOT, "parity/out/odin");
const OUT = path.join(ROOT, "site/public/shots");

const W = 1200, H = 675, INSET = 0.86, MAXSCALE = 6;

/** The component slugs the site publishes, in its own order. */
function siteSlugs() {
  const src = fs.readFileSync(path.join(ROOT, "site/app/content/components.ts"), "utf8");
  const head = src.slice(0, src.indexOf("export function"));
  return [...head.matchAll(/slug: "([a-z0-9-]+)"/g)].map((m) => m[1]);
}

/** Longest slug that prefixes the case id — `button-group-text` is not a button. */
function owner(caseId, slugs) {
  let best = null;
  for (const s of slugs) {
    if (caseId === s || caseId.startsWith(s + "-") || caseId.startsWith(s + "@")) {
      if (!best || s.length > best.length) best = s;
    }
  }
  return best;
}

/** Hand-picked where "plainest" and "most representative" disagree. */
const PREFER = {
  "aspect-ratio": "aspect-ratio-16-9",
  "button-group": "button-group-horizontal",
  field: "field-vertical",
  message: "message-start",
  questionnaire: "questionnaire-choices",
  resizable: "resizable-horizontal",
  separator: "separator-horizontal",
};

function rank(slug, id) {
  const suffix = id.slice(slug.length + 1);
  let s = suffix.length * 0.01;
  if (id === slug + "-default") s -= 100;
  if (suffix === "open") s -= 60; // a closed menu is an empty frame
  if (id.includes("@")) s += 50;
  if (/-(disabled|invalid|error)$/.test(id)) s += 40;
  if (/-(closed|empty)$/.test(id)) s += 30;
  if (/-(destructive|muted|ghost|link|outline|secondary)$/.test(id)) s += 10;
  return s;
}

function size(file) {
  const out = execFileSync("magick", [file, "-format", "%w %h %[pixel:p{0,0}]", "info:"], {
    encoding: "utf8",
  });
  const [w, h, ...rest] = out.trim().split(" ");
  return { w: +w, h: +h, bg: rest.join(" ") };
}

export function captureComponents() {
  fs.mkdirSync(OUT, { recursive: true });
  const slugs = siteSlugs();
  const cases = fs
    .readdirSync(SRC)
    .filter((f) => f.endsWith(".png"))
    .map((f) => f.slice(0, -4));

  const bySlug = {};
  for (const c of cases) {
    const o = owner(c, slugs);
    if (o) (bySlug[o] ??= []).push(c);
  }

  const filled = [], missing = [];
  for (const slug of slugs) {
    const list = bySlug[slug];
    if (!list || list.length === 0) { missing.push(slug); continue; }
    const pick = list.includes(PREFER[slug])
      ? PREFER[slug]
      : [...list].sort((a, b) => rank(slug, a) - rank(slug, b))[0];

    const src = path.join(SRC, pick + ".png");
    const { w, h, bg } = size(src);
    const fitW = (W * INSET) / w, fitH = (H * INSET) / h;
    const fit = Math.min(fitW, fitH);
    // Capped: a 16x16 spinner would otherwise be blown up 36-fold into a blob.
    const scale = fit >= 1 ? Math.min(MAXSCALE, Math.max(1, Math.floor(fit))) : fit;
    // Lanczos rather than nearest-neighbour. A `switch-on` is 32x20 and the
    // frame magnifies it six-fold; point-sampled, the result reads as a
    // mistake rather than as a rendering, and the browser then resamples it
    // again on the way down to the article's column width, so the hard pixel
    // edges buy nothing. The geometry is still exactly the parity geometry.
    const args = [src, "-filter", "Lanczos",
      "-resize", `${Math.round(w * scale)}x${Math.round(h * scale)}`];
    args.push(
      "-background", bg, "-alpha", "remove", "-alpha", "off",
      "-gravity", "center", "-extent", `${W}x${H}`,
      "-define", "png:color-type=2", "-strip",
      path.join(OUT, `component-${slug}.png`),
    );
    execFileSync("magick", args);
    filled.push([slug, pick, `${w}x${h}`, scale >= 1 ? `${scale}x` : scale.toFixed(2) + "x"]);
  }
  return { filled, missing, slugs };
}

if (process.argv[1] === import.meta.filename) {
  const { filled, missing, slugs } = captureComponents();
  for (const [slug, pick, dim, sc] of filled) console.log(`  ${slug.padEnd(18)} <- ${pick.padEnd(28)} ${dim.padEnd(10)} ${sc}`);
  console.log(`components: ${filled.length}/${slugs.length} filled`);
  if (missing.length) console.log(`missing: ${missing.join(" ")}`);
}
