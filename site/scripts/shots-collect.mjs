#!/usr/bin/env node
/**
 * Collect the raw application frames into `site/public/shots/`, and scan them.
 *
 * The raw frames come out of the applications at their own window sizes —
 * 1000x700 for the calculator, 1500x940 for the map — and at the full
 * resolution the offscreen renderer produced. Two things happen here:
 *
 *  - Each frame is downscaled so its long edge is at most MAX_W. The site
 *    draws app shots in a 16/10 box roughly 520px wide on a three-column grid
 *    and about 1000px wide on the landing page, so 1000px is already
 *    twice what the grid asks for. It is also, counter-intuitively, the
 *    smallest file: resampling a UI screenshot to a near-native size turns
 *    every crisp edge into a gradient and costs more bytes than either the
 *    original or an honest halving.
 *
 *  - Every frame is scanned, with OCR, for the account name, the home
 *    directory, the user's address and the machine's hostname. `strings` only
 *    finds what is in the file's metadata; what matters here is what is in the
 *    pixels, and tesseract reads that. A hit is reported and the frame is
 *    refused — the fix is always to regenerate with synthetic content, never
 *    to retouch the PNG.
 *
 *   usage: shots-collect.mjs <rawdir> [<rawdir>...]
 */
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const ROOT = path.resolve(import.meta.dirname, "../..");
const OUT = path.join(ROOT, "site/public/shots");
const MAX_W = 1000;

/**
 * What must not be in a committed frame. Written to survive OCR, which drops
 * spaces and confuses digits, so these are deliberately loose — a false
 * positive costs one look, a false negative costs a name in a git history.
 */
const FORBIDDEN = [
  { name: "account name", re: /(^|[^a-z0-9])alex([^a-z0-9]|$)/i },
  { name: "home directory", re: /\/home\//i },
  { name: "email address", re: /alexisbouchez/i },
  // The machine's hostname happens to be the same word as the distribution it
  // runs, so the OS line every system tool prints -- "Omarchy . Linux
  // 7.2.5-3-omarchy" -- is not a leak and is stripped before the check. What
  // is left is a bare `omarchy` where a host name is shown, and that is one.
  { name: "hostname", re: /(^|[^a-z])omarchy([^a-z]|$)/i },
  { name: "capture scratch path", re: /claude-1000/i },
];

function ocr(file) {
  try {
    return execFileSync("tesseract", [file, "-", "--psm", "6"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      maxBuffer: 1 << 24,
    });
  } catch {
    return "";
  }
}

function meta(file) {
  try {
    return execFileSync("strings", ["-n", "4", file], {
      encoding: "utf8",
      maxBuffer: 1 << 24,
    });
  } catch {
    return "";
  }
}

/** The distribution name and the kernel release, which are not a host name. */
const OS_LINE = /[-\w.]*-omarchy|omarchy\s*[-\u00b7.\u2022]*\s*linux/gi;

export function scan(file) {
  const text = (ocr(file) + "\n" + meta(file)).replace(OS_LINE, " ");
  const hits = [];
  for (const f of FORBIDDEN) {
    const m = text.match(f.re);
    if (m) hits.push(`${f.name}: ${JSON.stringify(m[0].trim())}`);
  }
  return hits;
}

export function collectApps(dirs) {
  fs.mkdirSync(OUT, { recursive: true });
  const taken = [], refused = [];
  const seen = new Set();

  for (const dir of dirs) {
    if (!fs.existsSync(dir)) continue;
    for (const f of fs.readdirSync(dir).sort()) {
      if (!/^app-[a-z0-9-]+\.png$/.test(f)) continue;
      if (seen.has(f)) continue;
      const src = path.join(dir, f);
      const hits = scan(src);
      if (hits.length) {
        refused.push([f, hits]);
        continue;
      }
      seen.add(f);
      // Write the frame twice -- at its native size and halved to MAX_W --
      // and keep whichever is smaller. Resampling a UI screenshot is not
      // monotonic: a 1180px frame nudged to 1000px turns every crisp edge
      // into a gradient and comes out *larger* than the original, while a
      // 1500px map genuinely halves. Measuring is shorter than guessing.
      const dst = path.join(OUT, f);
      const alt = dst + ".alt";
      execFileSync("magick", [src, "-strip", "-define", "png:color-type=2", dst]);
      execFileSync("magick", [src, "-resize", `${MAX_W}x${MAX_W}>`,
                              "-strip", "-define", "png:color-type=2", alt]);
      if (fs.statSync(alt).size < fs.statSync(dst).size) fs.renameSync(alt, dst);
      else fs.unlinkSync(alt);
      const w = execFileSync("magick", [dst, "-format", "%wx%h", "info:"], { encoding: "utf8" });
      taken.push([f, w.trim(), fs.statSync(dst).size]);
    }
  }
  return { taken, refused };
}

if (process.argv[1] === import.meta.filename) {
  const dirs = process.argv.slice(2);
  if (dirs.length === 0) {
    console.error("usage: shots-collect.mjs <rawdir> [<rawdir>...]");
    process.exit(1);
  }
  const { taken, refused } = collectApps(dirs);
  for (const [f, dim, size] of taken) {
    console.log(`  ${f.padEnd(24)} ${dim.padEnd(10)} ${(size / 1024).toFixed(0)} KiB`);
  }
  console.log(`apps: ${taken.length} collected`);
  for (const [f, hits] of refused) console.log(`REFUSED ${f}: ${hits.join("; ")}`);
}
