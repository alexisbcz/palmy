#!/usr/bin/env node
/**
 * Runs after `react-router build`, over the prerendered pages in build/client:
 *
 *   search-index.json   the text of every page, split into sections, for the
 *                       search palette (fetched the first time it opens)
 *   sitemap.xml         every page that is not a redirect
 *   robots.txt          pointing at the sitemap
 *   og/<page>.png       a 1200x630 social card per page, from its own title
 *                       and description
 *
 * Reading the built HTML rather than the content sources means the index and
 * the cards cover every page however it was written: the hand-written .tsx
 * pages, the components, and the pages synced from the repository alike.
 */

import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { join, relative, sep } from "node:path";

import { Resvg } from "@resvg/resvg-js";
import { fromHtml } from "hast-util-from-html";
import satori from "satori";

const require = createRequire(import.meta.url);
const CLIENT = join(process.cwd(), "build", "client");
const SITE_URL = (process.env.VITE_SITE_URL ?? "https://palmy-os.vercel.app").replace(/\/$/, "");
const SKIP_OG = process.argv.includes("--no-og");

/* -------------------------------------------------------------------------- */

function walk(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) walk(p, out);
    else if (name === "index.html") out.push(p);
  }
  return out;
}

const pathOf = (file) => {
  const rel = relative(CLIENT, file).split(sep).slice(0, -1).join("/");
  return rel ? `/${rel}` : "/";
};

const GROUPS = [
  ["/distro/", "Distribution"],
  ["/docs/", "palmy"],
  ["/reference/", "palmy"],
  ["/components", "Components"],
  ["/apps", "Applications"],
  ["/vision/", "Vision"],
];
const groupOf = (path) => GROUPS.find(([p]) => path.startsWith(p))?.[1] ?? "Palmy";

const text = (n) =>
  n.type === "text" ? n.value : n.children ? n.children.map(text).join("") : "";

const find = (n, pred) => {
  if (pred(n)) return n;
  for (const c of n.children ?? []) {
    const r = find(c, pred);
    if (r) return r;
  }
  return null;
};

const SKIP_TAGS = new Set(["nav", "footer", "button", "svg", "script", "style", "figcaption", "aside", "pre"]);
const BLOCK = new Set(["p", "li", "td", "th", "pre", "div", "h4", "figure", "blockquote", "tr", "dd", "dt"]);

/** Splits a page's <article> (or <main>) into its lead and its h2/h3 sections. */
function sections(root) {
  const main =
    find(root, (n) => n.tagName === "article") ?? find(root, (n) => n.tagName === "main");
  if (!main) return null;
  const h1 = find(main, (n) => n.tagName === "h1");
  if (!h1) return null;
  const out = [{ id: "", title: "", parts: [] }];
  const visit = (n) => {
    if (n.type === "text") {
      out.at(-1).parts.push(n.value);
      return;
    }
    if (n.type !== "element" || SKIP_TAGS.has(n.tagName) || n === h1) return;
    if ((n.tagName === "h2" || n.tagName === "h3") && n.properties?.id) {
      out.push({ id: String(n.properties.id), title: text(n).trim(), parts: [] });
      return;
    }
    for (const c of n.children ?? []) visit(c);
    if (BLOCK.has(n.tagName)) out.at(-1).parts.push(" ");
  };
  for (const c of main.children) visit(c);
  return { title: text(h1).trim(), sections: out };
}

const squash = (s) => s.replace(/\s+/g, " ").trim();

/* -------------------------------------------------------------------------- */

const files = walk(CLIENT).sort();
const pages = [];
const index = [];

for (const file of files) {
  const html = readFileSync(file, "utf8");
  const path = pathOf(file);
  const tree = fromHtml(html);
  const head = find(tree, (n) => n.tagName === "head");
  const meta = (name) =>
    find(head, (n) => n.tagName === "meta" && (n.properties?.name === name || n.properties?.property === name))
      ?.properties?.content;
  const title = text(find(head, (n) => n.tagName === "title") ?? { type: "text", value: "" });
  const description = meta("description") ?? "";
  const parsed = sections(tree);
  if (!parsed && path !== "/") continue; // a redirect stub
  pages.push({ path, title, description, h1: parsed?.title ?? title });

  if (!parsed) continue;
  const g = groupOf(path);
  for (const s of parsed.sections) {
    const x = squash(s.parts.join("")).slice(0, 1200);
    if (!s.id && !x && !description) continue;
    index.push({
      u: s.id ? `${path}#${s.id}` : path,
      t: parsed.title,
      s: s.title,
      x: s.id ? x : squash(`${description} ${x}`).slice(0, 1200),
      g,
    });
  }
}

writeFileSync(join(CLIENT, "search-index.json"), JSON.stringify(index));

/* -------------------------------------------------------------------------- */

const urls = pages
  .map((p) => `  <url><loc>${SITE_URL}${p.path === "/" ? "/" : p.path}</loc></url>`)
  .join("\n");
writeFileSync(
  join(CLIENT, "sitemap.xml"),
  `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`,
);
writeFileSync(join(CLIENT, "robots.txt"), `User-agent: *\nAllow: /\n\nSitemap: ${SITE_URL}/sitemap.xml\n`);

/* -------------------------------------------------------------------------- */
/* Social cards                                                                */
/* -------------------------------------------------------------------------- */

const font = (w) =>
  readFileSync(require.resolve(`@fontsource/geist-sans/files/geist-sans-latin-${w}-normal.woff`));
const FONTS = [
  { name: "Geist", data: font(400), weight: 400, style: "normal" },
  { name: "Geist", data: font(600), weight: 600, style: "normal" },
  { name: "Geist", data: font(700), weight: 700, style: "normal" },
];

const ogSlug = (path) => {
  const p = path.replace(/^\/+|\/+$/g, "");
  return p ? p.replace(/\//g, "--") : "index";
};

const h = (type, style, ...children) => ({
  type,
  props: { style, children: children.length === 1 ? children[0] : children },
});

function card({ path, h1, description }) {
  const eyebrow = path === "/" ? "palmy-os.vercel.app" : groupOf(path);
  const desc = description.length > 150 ? description.slice(0, 147).replace(/\s+\S*$/, "") + "…" : description;
  return h(
    "div",
    {
      width: "1200px",
      height: "630px",
      display: "flex",
      flexDirection: "column",
      justifyContent: "flex-start",
      padding: "64px 72px",
      background: "#0a0a0a",
      backgroundImage: "radial-gradient(circle at 85% 0%, #1e1b4b 0%, #0a0a0a 55%)",
      color: "#fafafa",
      fontFamily: "Geist",
    },
    h(
      "div",
      { display: "flex", alignItems: "center", gap: "16px", width: "1056px" },
      h(
        "div",
        {
          width: "44px",
          height: "44px",
          borderRadius: "10px",
          background: "#fafafa",
          color: "#0a0a0a",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: "28px",
          fontWeight: 700,
        },
        "P",
      ),
      h("div", { fontSize: "28px", fontWeight: 600 }, "Palmy"),
      h("div", { fontSize: "26px", color: "#a1a1aa", marginLeft: "8px" }, eyebrow),
      h("div", { fontSize: "22px", color: "#71717a", marginLeft: "auto" }, "github.com/alexisbcz/palmy"),
    ),
    h(
      "div",
      { display: "flex", flexDirection: "column", gap: "24px", width: "1056px", marginTop: "150px" },
      h(
        "div",
        { fontSize: h1.length > 40 ? "60px" : "72px", fontWeight: 700, lineHeight: 1.05, letterSpacing: "-0.02em" },
        h1,
      ),
      desc ? h("div", { fontSize: "28px", lineHeight: 1.4, color: "#a1a1aa", width: "1056px" }, desc) : h("div", {}, ""),
    ),
  );
}

if (!SKIP_OG) {
  mkdirSync(join(CLIENT, "og"), { recursive: true });
  for (const p of pages) {
    const svg = await satori(card(p), { width: 1200, height: 630, fonts: FONTS });
    const png = new Resvg(svg, { fitTo: { mode: "width", value: 1200 } }).render().asPng();
    writeFileSync(join(CLIENT, "og", `${ogSlug(p.path)}.png`), png);
  }
}

console.log(
  `postbuild: ${pages.length} pages, ${index.length} search records (${(JSON.stringify(index).length / 1024).toFixed(0)} KiB), sitemap${SKIP_OG ? "" : `, ${pages.length} social cards`}`,
);
