#!/usr/bin/env node
/**
 * Walks every route this site serves and asserts that nothing 404s.
 *
 * A docs site whose sidebar leads to a 404 is worse than one with fewer
 * pages, so this starts the production server, crawls outward from "/", and
 * fails on:
 *
 *   - any internal link that does not end at a 200
 *   - any "#fragment" whose id is not in the page it points at
 *   - a page count that does not match what the content files declare,
 *     which is how a page that nothing links to gets caught
 *
 * Usage: node scripts/check-links.mjs [--base http://host:port]
 * With no --base it builds nothing and expects ./build to exist already.
 */

import { spawn } from "node:child_process";
import { setTimeout as sleep } from "node:timers/promises";

const argv = process.argv.slice(2);
const baseArg = argv.includes("--base")
  ? argv[argv.indexOf("--base") + 1]
  : null;

const PORT = Number(process.env.PORT ?? 41731);
const BASE = baseArg ?? `http://127.0.0.1:${PORT}`;

/** What the content is expected to produce. Mismatch means a missing page. */
const EXPECT = {
  "/docs/": 17,
  "/palmframe/": 9,
  "/components/": 61,
};

/* -------------------------------------------------------------------------- */

let child = null;

async function startServer() {
  if (baseArg) return;
  child = spawn(
    process.execPath,
    ["node_modules/@react-router/serve/bin.cjs", "./build/server/index.js"],
    {
      env: { ...process.env, PORT: String(PORT), NODE_ENV: "production" },
      stdio: ["ignore", "pipe", "pipe"],
    },
  );
  let err = "";
  child.stderr.on("data", (d) => (err += d.toString()));
  child.stdout.on("data", () => {});

  for (let i = 0; i < 120; i++) {
    try {
      const r = await fetch(`${BASE}/`, { redirect: "manual" });
      if (r.status > 0) return;
    } catch {
      /* not up yet */
    }
    if (child.exitCode !== null) {
      throw new Error(`server exited (${child.exitCode})\n${err}`);
    }
    await sleep(250);
  }
  throw new Error(`server did not start within 30s\n${err}`);
}

function stopServer() {
  if (child && child.exitCode === null) child.kill("SIGTERM");
}

/* -------------------------------------------------------------------------- */

const HREF = /\bhref="([^"]+)"/g;
const ID = /\sid="([^"]+)"/g;

function internalLinks(html) {
  const out = new Set();
  for (const m of html.matchAll(HREF)) {
    const href = m[1];
    if (!href || href.startsWith("//")) continue;
    if (/^[a-z]+:/i.test(href)) continue; // http:, mailto:, data:
    if (href.startsWith("/assets/") || href.startsWith("/shots/")) continue;
    if (href.startsWith("#")) continue; // same-page, checked separately
    if (!href.startsWith("/")) continue; // relative; the site uses none
    out.add(href);
  }
  return [...out];
}

function idsIn(html) {
  const out = new Set();
  for (const m of html.matchAll(ID)) out.add(m[1]);
  return out;
}

function sameDocFragments(html) {
  const out = new Set();
  for (const m of html.matchAll(HREF)) {
    if (m[1].startsWith("#") && m[1].length > 1) out.add(m[1].slice(1));
  }
  return [...out];
}

/* -------------------------------------------------------------------------- */

const pages = new Map(); // path -> { status, html }
const problems = [];

async function visit(path, from) {
  if (pages.has(path)) return pages.get(path);

  let res;
  try {
    res = await fetch(BASE + path, { redirect: "follow" });
  } catch (e) {
    problems.push(`FETCH FAILED  ${path}  (linked from ${from})  ${e.message}`);
    pages.set(path, { status: 0, html: "" });
    return pages.get(path);
  }

  const html = res.headers
    .get("content-type")
    ?.includes("text/html")
    ? await res.text()
    : "";

  const entry = { status: res.status, html };
  pages.set(path, entry);

  if (res.status !== 200) {
    problems.push(
      `STATUS ${res.status}  ${path}  (linked from ${from ?? "the route list"})`,
    );
  }
  return entry;
}

async function crawl(seeds) {
  const queue = seeds.map((s) => ({ path: s, from: null }));
  const seen = new Set();

  while (queue.length > 0) {
    const { path, from } = queue.shift();
    const key = path.split("#")[0];
    if (seen.has(key)) continue;
    seen.add(key);

    const { html } = await visit(key, from);
    if (!html) continue;

    for (const href of internalLinks(html)) {
      queue.push({ path: href, from: key });
    }
  }
}

/** Second pass: every "#fragment" must exist in the page it points at. */
function checkFragments() {
  for (const [path, { html }] of pages) {
    if (!html) continue;
    const ids = idsIn(html);
    for (const frag of sameDocFragments(html)) {
      if (!ids.has(frag)) {
        problems.push(`MISSING ANCHOR  ${path}#${frag}`);
      }
    }
    // Cross-page fragments, e.g. /apps#wm
    for (const m of html.matchAll(HREF)) {
      const href = m[1];
      if (!href.startsWith("/") || !href.includes("#")) continue;
      const [target, frag] = href.split("#");
      if (!frag) continue;
      const page = pages.get(target || "/");
      if (!page || !page.html) continue;
      if (!idsIn(page.html).has(frag)) {
        problems.push(`MISSING ANCHOR  ${href}  (linked from ${path})`);
      }
    }
  }
}

function checkCounts() {
  for (const [prefix, want] of Object.entries(EXPECT)) {
    const got = [...pages.keys()].filter(
      (p) => p.startsWith(prefix) && p.length > prefix.length,
    ).length;
    if (got !== want) {
      problems.push(
        `COUNT  ${prefix}*  reached ${got}, expected ${want} — a page is unlinked or missing`,
      );
    }
  }
}

/* -------------------------------------------------------------------------- */

async function main() {
  await startServer();

  // Crawling from the home page reaches everything, because the sidebar on
  // every docs page links every docs page and the indexes link their items.
  await crawl(["/", "/docs", "/palmframe", "/components", "/apps"]);

  checkFragments();
  checkCounts();

  const ok = [...pages.values()].filter((p) => p.status === 200).length;
  console.log(`checked ${pages.size} routes, ${ok} returned 200`);

  const byPrefix = {};
  for (const p of pages.keys()) {
    const k = "/" + (p.split("/")[1] || "(root)");
    byPrefix[k] = (byPrefix[k] ?? 0) + 1;
  }
  for (const [k, n] of Object.entries(byPrefix).sort()) {
    console.log(`  ${k.padEnd(14)} ${n}`);
  }

  if (problems.length > 0) {
    console.error(`\n${problems.length} problem(s):`);
    for (const p of problems) console.error("  " + p);
    process.exitCode = 1;
  } else {
    console.log("\nevery internal link and anchor resolves");
  }
}

try {
  await main();
} catch (e) {
  console.error(e.message);
  process.exitCode = 1;
} finally {
  stopServer();
}
