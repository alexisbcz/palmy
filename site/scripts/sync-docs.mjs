#!/usr/bin/env node
/**
 * Turns the repository's Markdown, and tables read from its source, into the
 * pages under /distro and /reference.
 *
 *   node scripts/sync-docs.mjs            regenerate everything
 *   node scripts/sync-docs.mjs --if-repo  skip quietly when ../distro is absent
 *                                         (a deploy that uploads only site/)
 *   node scripts/sync-docs.mjs --check    fail if the committed output is stale
 *
 * Output, all committed so a build never needs the rest of the repository:
 *
 *   app/content/generated/nav.json         sidebars, titles, descriptions
 *   app/content/generated/pages/*.json     one page each: hast, TOC, source
 *   public/docs-img/...                    the images those pages show
 *
 * Every page is rendered here, at sync time, to a hast tree with Shiki's
 * highlighting already applied. The browser receives that tree and maps it to
 * React components; no Markdown parser or grammar ships to the client.
 */

import { execFileSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, normalize, posix, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import rehypeShiki from "@shikijs/rehype";
import { transformerStyleToClass } from "@shikijs/transformers";
import GithubSlugger from "github-slugger";
import { toString as hastText } from "hast-util-to-string";
import { toString as mdText } from "mdast-util-to-string";
import rehypeSlug from "rehype-slug";
import remarkDirective from "remark-directive";
import remarkGfm from "remark-gfm";
import remarkParse from "remark-parse";
import remarkRehype from "remark-rehype";
import { unified } from "unified";
import { visit, SKIP } from "unist-util-visit";

import { BRANCH, COLLECTIONS, REPO } from "../content/manifest.mjs";
import * as gen from "./lib/generators.mjs";

const SITE = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const ROOT = resolve(SITE, "..");
const OUT = join(SITE, "app/content/generated");
const IMG_OUT = join(SITE, "public/docs-img");
const PAGES_DIR = join(SITE, "content/pages");
const GH = `https://github.com/${REPO}`;

const args = process.argv.slice(2);
const CHECK = args.includes("--check");

if (!existsSync(join(ROOT, "distro/README.md"))) {
  if (args.includes("--if-repo")) {
    console.log("sync-docs: repository not present, using committed output");
    process.exit(0);
  }
  console.error(`sync-docs: ${ROOT}/distro/README.md not found`);
  process.exit(1);
}

/* -------------------------------------------------------------------------- */
/* Parsing                                                                     */
/* -------------------------------------------------------------------------- */

const parseRepoMd = (text) => unified().use(remarkParse).use(remarkGfm).parse(text);
const parsePageMd = (text) =>
  unified().use(remarkParse).use(remarkGfm).use(remarkDirective).parse(text);

const fileCache = new Map();
function repoFile(path) {
  if (!fileCache.has(path)) {
    const full = join(ROOT, path);
    if (!existsSync(full)) throw new Error(`sync-docs: ${path} does not exist`);
    fileCache.set(path, readFileSync(full, "utf8"));
  }
  return fileCache.get(path);
}

/** Tags every node of a subtree with the repository file it came from. */
function tagOrigin(nodes, file) {
  for (const n of nodes) {
    visit(n, (x) => {
      x.data = x.data || {};
      if (!x.data.origin) x.data.origin = file;
    });
  }
  return nodes;
}

/**
 * Picks nodes out of a parsed file. A section runs from its heading to the
 * next heading of the same or a higher level.
 */
function extract(file, { section, intro, level }) {
  const tree = parseRepoMd(repoFile(file));
  const kids = tree.children;
  if (!section) {
    if (intro) {
      const end = kids.findIndex((n) => n.type === "heading" && n.depth === 2);
      return kids.slice(0, end === -1 ? kids.length : end).filter((n) => !isTitle(n));
    }
    return kids.filter((n, i) => !(i === kids.findIndex(isTitle) && isTitle(n)));
  }
  const at = kids.findIndex(
    (n) =>
      n.type === "heading" &&
      mdText(n).trim() === section &&
      (level === undefined || n.depth === level),
  );
  if (at === -1) throw new Error(`sync-docs: ${file} has no section "${section}"`);
  const depth = kids[at].depth;
  let end = at + 1;
  while (end < kids.length && !(kids[end].type === "heading" && kids[end].depth <= depth)) {
    end++;
  }
  let body = kids.slice(at + 1, end);
  if (intro) {
    const sub = body.findIndex((n) => n.type === "heading");
    if (sub !== -1) body = body.slice(0, sub);
  }
  return body;
}

const isTitle = (n) => n.type === "heading" && n.depth === 1;

/** Shifts headings so the shallowest one in `nodes` lands on `top`. */
function shiftHeadings(nodes, top = 2) {
  let min = 7;
  for (const n of nodes) visit(n, "heading", (h) => void (min = Math.min(min, h.depth)));
  if (min === 7) return nodes;
  const by = top - min;
  for (const n of nodes) {
    visit(n, "heading", (h) => {
      h.depth = Math.max(2, Math.min(6, h.depth + by));
    });
  }
  return nodes;
}

/* -------------------------------------------------------------------------- */
/* Pages and the link map                                                      */
/* -------------------------------------------------------------------------- */

const pages = [];
for (const [cid, col] of Object.entries(COLLECTIONS)) {
  for (const g of col.groups) {
    for (const p of g.pages) {
      pages.push({ ...p, collection: cid, group: g.title, url: `${col.base}/${p.slug}` });
    }
  }
}
{
  const urls = new Set();
  for (const p of pages) {
    if (urls.has(p.url)) throw new Error(`sync-docs: duplicate page ${p.url}`);
    urls.add(p.url);
  }
}

/**
 * Where a link into the repository should go on the site. A whole file maps
 * to its page; a file split into sections maps each heading anchor to the
 * page holding it, the way GitHub would have slugged it.
 */
const fileToPage = new Map(); // file -> url of the page that represents it
const anchorToPage = new Map(); // `${file}#${slug}` -> url

for (const p of pages) {
  const s = p.source;
  if (!s.file) continue;
  if (!s.section && !s.intro) fileToPage.set(s.file, p.url);
  if (s.intro && !s.section) fileToPage.set(s.file, p.url);
}
for (const p of pages) {
  const s = p.source;
  if (!s.file || !s.section) continue;
  const slugger = new GithubSlugger();
  const tree = parseRepoMd(repoFile(s.file));
  let inside = false;
  let depth = 0;
  let seenTarget = false;
  for (const n of tree.children) {
    if (n.type !== "heading") continue;
    const slug = slugger.slug(mdText(n));
    if (
      !seenTarget &&
      mdText(n).trim() === s.section &&
      (s.level === undefined || n.depth === s.level)
    ) {
      inside = true;
      depth = n.depth;
      seenTarget = true;
      anchorToPage.set(`${s.file}#${slug}`, p.url);
      continue;
    }
    if (inside && n.depth <= depth) inside = false;
    if (inside) anchorToPage.set(`${s.file}#${slug}`, `${p.url}#${slug}`);
  }
}

const IMAGES = new Map(); // repo path -> { url, width, height }

function pngSize(file) {
  const b = readFileSync(file);
  if (b.length > 24 && b.toString("ascii", 1, 4) === "PNG") {
    return { width: b.readUInt32BE(16), height: b.readUInt32BE(20) };
  }
  return {};
}

function useImage(repoPath) {
  if (!IMAGES.has(repoPath)) {
    const src = join(ROOT, repoPath);
    if (!existsSync(src)) throw new Error(`sync-docs: image ${repoPath} does not exist`);
    IMAGES.set(repoPath, { url: `/docs-img/${repoPath}`, ...pngSize(src) });
  }
  return IMAGES.get(repoPath);
}

/** Rewrites one link target found in `origin`. */
function resolveLink(href, origin) {
  if (!href || /^(https?:|mailto:|#)/.test(href)) return href;
  if (href.startsWith("gh:")) return `${GH}/blob/${BRANCH}/${href.slice(3)}`;
  if (href.startsWith("/")) return href; // already a site path
  if (!origin) return href;
  const [pathPart, frag] = href.split("#");
  const target = posix.normalize(posix.join(posix.dirname(origin), pathPart));
  if (target.startsWith("..")) return href;
  if (frag && anchorToPage.has(`${target}#${frag}`)) return anchorToPage.get(`${target}#${frag}`);
  if (fileToPage.has(target)) return fileToPage.get(target) + (frag ? `#${frag}` : "");
  const full = join(ROOT, target);
  const kind = existsSync(full) && statSync(full).isDirectory() ? "tree" : "blob";
  return `${GH}/${kind}/${BRANCH}/${target}${frag ? `#${frag}` : ""}`;
}

function rewriteLinks(tree) {
  visit(tree, (n) => {
    const origin = n.data?.origin;
    if (n.type === "link" || n.type === "definition") {
      n.url = resolveLink(n.url, origin);
    } else if (n.type === "image") {
      if (/^https?:/.test(n.url)) return;
      const target = posix.normalize(posix.join(posix.dirname(origin ?? ""), n.url));
      const img = useImage(target);
      n.url = img.url;
      n.data = {
        ...n.data,
        hProperties: { width: img.width, height: img.height, loading: "lazy", decoding: "async" },
      };
    } else if (n.type === "html") {
      // The repository's Markdown carries no HTML on purpose; anything that
      // parses as a tag (`<pkg>` outside a code span) is shown as written.
      n.type = "text";
    }
  });
}

/* -------------------------------------------------------------------------- */
/* Callouts, steps, cards, key caps                                            */
/* -------------------------------------------------------------------------- */

const ALERTS = { NOTE: "info", TIP: "idea", IMPORTANT: "info", WARNING: "warning", CAUTION: "error" };

function callout(type, title, children) {
  return {
    type: "callout",
    children,
    data: { hName: "div", hProperties: { dataCallout: type, dataTitle: title ?? "" } },
  };
}

/** `> [!NOTE]` blockquotes, GitHub's alert syntax, become callouts. */
function alerts(tree) {
  visit(tree, "blockquote", (n, i, parent) => {
    const first = n.children[0];
    const t = first?.type === "paragraph" && first.children[0]?.type === "text" && first.children[0];
    const m = t && t.value.match(/^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/);
    if (!m) return;
    t.value = t.value.slice(m[0].length);
    if (!t.value) first.children.shift();
    if (first.children.length === 0) n.children.shift();
    parent.children[i] = callout(ALERTS[m[1]], null, n.children);
    return SKIP;
  });
}

/** ``⌨Super+Shift+T`` inline code becomes a row of <kbd> caps. */
function keycaps(tree) {
  visit(tree, "inlineCode", (n, i, parent) => {
    if (!n.value.startsWith("⌨")) return;
    const groups = n.value.slice(1).split(" / ");
    const kids = [];
    groups.forEach((g, gi) => {
      if (gi > 0) kids.push({ type: "text", value: " / " });
      // One chord never breaks across lines; alternatives may.
      const chord = [];
      const caps = g.split("+");
      caps.forEach((c, ci) => {
        if (ci > 0) chord.push({ type: "text", value: "+" });
        // "H J K L" on the last cap means four alternatives.
        c.split(" ").forEach((alt, ai) => {
          if (ai > 0) chord.push({ type: "text", value: " " });
          chord.push({ type: "kbd", data: { hName: "kbd" }, children: [{ type: "text", value: alt }] });
        });
      });
      kids.push({
        type: "chord",
        data: { hName: "span", hProperties: { className: ["chord"] } },
        children: chord,
      });
    });
    parent.children.splice(i, 1, {
      type: "keys",
      data: { hName: "span", hProperties: { className: ["keys"] } },
      children: kids,
    });
    return SKIP;
  });
}

const md = (text, origin) => tagOrigin(parseRepoMd(text).children, origin);

function component(name, props, fallbackText = "") {
  return {
    type: "component",
    children: [],
    data: {
      hName: "div",
      hProperties: { dataComponent: name, dataProps: JSON.stringify(props) },
      hChildren: fallbackText ? [{ type: "text", value: fallbackText }] : [],
    },
  };
}

/* -------------------------------------------------------------------------- */
/* Generated sections                                                          */
/* -------------------------------------------------------------------------- */

const esc = (s) => String(s ?? "").replace(/\|/g, "\\|").replace(/\n+/g, " ");
const ic = (s) => (String(s).includes("`") ? "`` " + s + " ``" : "`" + s + "`");

function genKeybindings() {
  const { rows } = gen.wmBindings(ROOT);
  const order = gen.wmGroupOrder(ROOT);
  const out = [];
  for (const g of order) {
    const rs = rows.filter((r) => r.group === g);
    if (!rs.length) continue;
    out.push(`### ${g}`, "", "| Keys | Action |", "| --- | --- |");
    for (const r of rs) {
      const keys = [r.keys, ...r.also].map((k) => k.join("+")).join(" / ");
      out.push(`| ${ic("⌨" + keys)} | ${esc(r.label)} |`);
    }
    out.push("");
  }
  return out.join("\n");
}

function genMouse() {
  const out = ["| Gesture | Action |", "| --- | --- |"];
  for (const m of gen.wmMouse(ROOT)) out.push(`| ${esc(m.gesture)} | ${esc(m.action)} |`);
  return out.join("\n");
}

function genWmConfig() {
  return "```ini title=\"apps/wm/config.odin, CFG_DEFAULT\"\n" + gen.wmDefaultConfig(ROOT) + "```";
}

const STATUS = { yes: "Works", partial: "Partly", no: "No" };

function genApps() {
  const apps = gen.appsTable(ROOT);
  const out = [];
  const section = (title, filter, blurb) => {
    const rs = apps.filter(filter);
    if (!rs.length) return;
    out.push(`### ${title} (${rs.length})`, "", blurb, "");
    out.push("| Application | Default install | Runtime needs | Notes |", "| --- | --- | --- | --- |");
    for (const a of rs) {
      const name = a.desktop?.name ? `${ic(a.binary)} ${esc(a.desktop.name)}` : ic(a.binary);
      out.push(
        `| ${name} | ${a.default ? "yes" : a.packaged ? "in the repository" : "no"} | ${esc(a.runtime_deps) || "nothing beyond the base"} | ${esc(a.notes)} |`,
      );
    }
    out.push("");
  };
  section("Works on the bare system", (a) => a.works_minimal === "yes", "Usable on a fresh Palmy install with nothing added.");
  section("Works partly", (a) => a.works_minimal === "partial", "Runs, but a named part of it needs something Palmy does not ship.");
  section("Does not work yet", (a) => a.works_minimal === "no", "Builds, but needs a program or service Palmy does not ship.");
  const other = apps.filter((a) => !["yes", "partial", "no"].includes(a.works_minimal));
  if (other.length) section("Unclassified", (a) => other.includes(a), "No status recorded in apps.tsv.");
  return out.join("\n");
}

function appCounts() {
  const apps = gen.appsTable(ROOT);
  const c = (v) => apps.filter((a) => a.works_minimal === v).length;
  return { total: apps.length, yes: c("yes"), partial: c("partial"), no: c("no"), defaults: apps.filter((a) => a.default).length };
}

function genPackages() {
  const pk = gen.packages(ROOT);
  const out = ["| Package | Version | Category | Installed by `palmy` | Description | Depends on |", "| --- | --- | --- | --- | --- | --- |"];
  for (const p of pk) {
    const ver = p.version ? `${p.version}${p.release ? "-r" + p.release : ""}` : "";
    out.push(
      `| ${ic(p.name)} | ${esc(ver)} | ${esc(p.category)} | ${p.name === "palmy" ? "(itself)" : p.inPalmy ? "yes" : "no"} | ${esc(p.desc)} | ${p.depends.map(ic).join(" ")} |`,
    );
  }
  return out.join("\n");
}

const CLASS_GROUPS = [
  ["Layout", ["items-", "self-", "justify-", "gap-x-", "gap-y-", "gap-", "grid-cols-"]],
  ["Sizing", ["min-w-", "min-h-", "max-w-", "max-h-", "basis-", "size-", "w-", "h-"]],
  ["Spacing", ["p{side}-", "m{side}-"]],
  ["Position", ["top-", "right-", "bottom-", "left-", "z-"]],
  ["Colour and background", ["bg-gradient-to-", "bg-", "from-", "to-"]],
  ["Borders, radius and rings", ["border-", "rounded-", "ring-", "ring-offset-", "outline-"]],
  ["Typography", ["text-", "text-outline-", "leading-", "tracking-"]],
  ["Effects and motion", ["shadow-", "opacity-", "duration-"]],
];

const VALUE_WORDS = {
  spacing: "spacing scale: `4` is 16px, `0.5` is 2px, `px` is 1px, `[12]` is 12px",
  size: "`full`, `screen`, `auto`, a fraction such as `1/2`, or the spacing scale",
  color: "a palette colour, `white`, `black`, `transparent`, `current`, `[#rrggbb]`; `/NN` sets alpha",
  radius: "a radius name (below) or `[N]`",
  "font-size": "a type-scale name (below) or `[N]`",
  "border-width": "`0`, `2`, `4`, `8` or `[N]` pixels; `border-t-2`, `border-x-red-500` for one side",
  align: "`start`, `center`, `end`, `stretch`, `baseline`, `auto`",
  number: "a number",
  pixels: "a number of pixels",
  ignored: "accepted and ignored",
};

function genClasses() {
  const c = gen.palmyClasses(ROOT);
  const out = [];

  out.push("## Variants", "");
  out.push(
    "A variant prefix applies the utility only in that interaction state. Prefixes stack (`hover:focus:`), and a prefix palmy does not know turns the utility off rather than applying it unconditionally.",
    "",
    "| Variant | Applies when |",
    "| --- | --- |",
  );
  const when = (w) =>
    w
      .replace(/st\./g, "")
      .replace(/ && /g, " and ")
      .replace(/!disabled/g, "not disabled");
  for (const v of c.variants) out.push(`| ${ic(v.name + ":")} | ${esc(when(v.when))} |`);
  out.push("");

  out.push("## Utilities with a fixed name", "");
  const fixed = c.exact.filter((e) => !e.noop);
  out.push(fixed.flatMap((e) => e.names).map(ic).join(" "), "");
  const noted = fixed.filter((e) => e.notes);
  if (noted.length) {
    out.push("Where palmy's behaviour needs a word:", "", "| Utility | Notes |", "| --- | --- |");
    for (const e of noted) out.push(`| ${e.names.map(ic).join(" ")} | ${esc(e.notes)} |`);
    out.push("");
  }

  out.push("## Prefixed utilities", "");
  out.push(
    "A prefix followed by a value. The value column names the grammar the parser uses for it; the scales are listed further down.",
    "",
  );
  const byPrefix = new Map(c.families.map((f) => [f.prefix, f]));
  const placed = new Set();
  const groups = [...CLASS_GROUPS, ["Other", c.families.map((f) => f.prefix)]];
  for (const [title, prefixes] of groups) {
    const fs = prefixes.map((p) => byPrefix.get(p)).filter((f) => f && !placed.has(f.prefix));
    if (!fs.length) continue;
    out.push(`### ${title}`, "", "| Prefix | Value | Notes |", "| --- | --- | --- |");
    for (const f of fs) {
      placed.add(f.prefix);
      const vals = [
        ...f.values.map((v) => VALUE_WORDS[v] ?? v),
        ...(f.named.length ? [f.named.map(ic).join(" ")] : []),
      ];
      const shown = f.prefix.replace("{side}", "");
      const note = f.setsSides
        ? `Sides: ${["", "x", "y", "t", "r", "b", "l", "s", "e"].map((s) => ic(f.prefix.replace("{side}", s) + "N")).join(" ")}. ${f.prefix.startsWith("m") ? "`mx-auto` and `m-auto` centre horizontally." : ""}`
        : f.note;
      out.push(`| ${ic(shown)} | ${esc(vals.join("; ") || "a keyword (see source)")} | ${esc(note)} |`);
    }
    out.push("");
  }

  out.push("## Scales", "");
  out.push("### Type scale", "", "`text-<name>` sets the size and its line height together, as Tailwind does.", "", "| Name | Size | Line height |", "| --- | --- | --- |");
  for (const f of c.fontSizes) {
    const [size, lead] = f.value.split(",").map((x) => x.trim());
    const lh = /\//.test(lead) ? `${lead.split("/")[0].replace(".0", "").trim()}px` : `${lead}×`;
    out.push(`| ${ic("text-" + f.name)} | ${size}px | ${lh} |`);
  }
  out.push("");
  out.push("### Radius", "", "| Utility | Radius |", "| --- | --- |");
  for (const r of c.radii) {
    out.push(`| ${ic(r.name ? "rounded-" + r.name : "rounded")} | ${r.value.split(",")[0]}px |`);
  }
  out.push("");
  out.push(
    "### Colour palette",
    "",
    `Tailwind's palette, as data in \`palmy/palette.odin\`: ${c.hues.map(ic).join(", ")}, each in shades ${c.shades.join(", ")}. So \`bg-slate-900\` is the same pixel value it is in a browser. Colours registered by the application with \`register_color\` win over the palette.`,
    "",
  );

  out.push("## Accepted, with no effect", "");
  out.push(
    "These parse and do nothing, so class strings copied from a web project do not have to be cleaned first. They are listed so that nobody mistakes acceptance for support.",
    "",
    "| Utilities | Why |",
    "| --- | --- |",
  );
  for (const e of c.exact.filter((e) => e.noop)) {
    out.push(`| ${e.names.map(ic).join(" ")} | ${esc(e.notes) || "No equivalent in palmy's model."} |`);
  }
  for (const f of c.families.filter((f) => f.values.includes("ignored"))) {
    out.push(`| ${ic(f.prefix + "*")} | ${esc(f.note) || "Not modelled."} |`);
  }
  out.push("");
  return out.join("\n");
}

/** Doc comments use a tab-indented block for examples; fence those as Odin. */
function docToMd(lines) {
  const out = [];
  let inCode = false;
  for (const l of lines) {
    const isCode = l.startsWith("\t");
    if (isCode && !inCode) {
      out.push("```odin");
      inCode = true;
    } else if (!isCode && inCode && l.trim() !== "") {
      out.push("```");
      inCode = false;
    }
    out.push(isCode ? l.slice(1) : l);
  }
  if (inCode) {
    while (out.at(-1) === "") out.pop();
    out.push("```");
  }
  return out.join("\n");
}

function genApi(dir) {
  const files = gen.odinApi(ROOT, dir);
  const out = [];
  for (const f of files) {
    out.push(`## ${f.file}`, "");
    out.push(`[${dir}/${f.file}](gh:${dir}/${f.file})`, "");
    if (f.head) out.push(docToMd(f.head.split("\n")), "");
    for (const d of f.decls) {
      out.push(`### ${d.name}`, "");
      out.push("```odin", d.sig, "```", "");
      if (d.doc.length) out.push(docToMd(d.doc), "");
    }
  }
  return out.join("\n");
}

function apiCounts(dir) {
  const files = gen.odinApi(ROOT, dir);
  const all = files.flatMap((f) => f.decls);
  return { files: files.length, procs: all.filter((d) => d.kind === "proc").length, types: all.filter((d) => d.kind === "type").length };
}

/* -------------------------------------------------------------------------- */
/* Hand-written pages                                                          */
/* -------------------------------------------------------------------------- */

function templateVars() {
  const v = gen.versions(ROOT);
  const a = appCounts();
  const pk = gen.packages(ROOT);
  const pa = apiCounts("palmy");
  const sa = apiCounts("shadcn");
  return {
    kernel: v.kernel,
    busybox: v.busybox,
    imageTools: gen.hostTools(ROOT, "distro/image/build.sh").map(ic).join(", "),
    isoTools: gen.hostTools(ROOT, "distro/live/build.sh").map(ic).join(", "),
    appTotal: a.total,
    appYes: a.yes,
    appPartial: a.partial,
    appNo: a.no,
    appDefault: a.defaults,
    packageCount: pk.length,
    palmyCount: pk.find((p) => p.name === "palmy")?.depends.length ?? 0,
    palmyProcs: pa.procs,
    palmyTypes: pa.types,
    palmyFiles: pa.files,
    shadcnProcs: sa.procs,
    shadcnTypes: sa.types,
    shadcnFiles: sa.files,
    bindingCount: gen.wmBindings(ROOT).raw.length,
  };
}

let VARS;

/** Expands the directives a hand-written page may use into mdast nodes. */
function expandDirectives(tree, pageFile) {
  visit(tree, (n, i, parent) => {
    if (!parent) return;
    if (n.type === "leafDirective") {
      const a = n.attributes || {};
      let nodes;
      switch (n.name) {
        case "include":
          nodes = tagOrigin(extract(a.file, { section: a.section, intro: "intro" in a, level: a.level ? Number(a.level) : undefined }), a.file);
          shiftHeadings(nodes, Number(a.depth ?? 3));
          break;
        case "keybindings":
          nodes = md(genKeybindings(), "apps/wm/config.odin");
          break;
        case "wm-mouse":
          nodes = md(genMouse(), "apps/wm/cheatsheet.odin");
          break;
        case "wm-config":
          nodes = md(genWmConfig(), "apps/wm/config.odin");
          break;
        case "app-table":
          nodes = md(genApps(), "distro/apps/apps.tsv");
          break;
        case "package-table":
          nodes = md(genPackages(), "distro/recipes/palmy/PALMBUILD");
          break;
        case "class-reference":
          nodes = md(genClasses(), "palmy/class.odin");
          break;
        case "api":
          nodes = md(genApi(a.dir), `${a.dir}/x.odin`);
          break;
        case "boot-chain":
          nodes = [component("boot-chain", { nodes: gen.bootChain(ROOT) })];
          break;
        default:
          throw new Error(`${pageFile}: unknown directive ::${n.name}`);
      }
      parent.children.splice(i, 1, ...nodes);
      return [SKIP, i + nodes.length];
    }
    if (n.type === "containerDirective") {
      const a = n.attributes || {};
      if (n.name === "callout") {
        parent.children[i] = callout(a.type ?? "info", a.title, n.children);
        return;
      }
      if (n.name === "steps") {
        // Each `###` heading starts a step.
        const steps = [];
        for (const c of n.children) {
          if (c.type === "heading" || steps.length === 0) steps.push([]);
          steps.at(-1).push(c);
        }
        parent.children[i] = {
          type: "steps",
          data: { hName: "div", hProperties: { className: ["fd-steps"] } },
          children: steps.map((s) => ({
            type: "step",
            data: { hName: "div", hProperties: { className: ["fd-step"] } },
            children: s,
          })),
        };
        return;
      }
      if (n.name === "cards") {
        parent.children[i] = {
          type: "cards",
          data: { hName: "div", hProperties: { dataCards: "" } },
          children: n.children,
        };
        return;
      }
      throw new Error(`${pageFile}: unknown container :::${n.name}`);
    }
    if (n.type === "textDirective") {
      // Not a directive: a colon in prose ("ratio:1"). Put the text back.
      parent.children.splice(i, 1, { type: "text", value: ":" + n.name + (n.children.length ? mdText(n) : "") });
      return [SKIP, i];
    }
  });
}

function handPage(file) {
  const raw = readFileSync(join(PAGES_DIR, file), "utf8").replace(/\{\{(\w+)\}\}/g, (m, k) => {
    if (!(k in VARS)) throw new Error(`${file}: unknown variable ${m}`);
    return String(VARS[k]);
  });
  const tree = parsePageMd(raw);
  expandDirectives(tree, file);
  return tree.children.filter((n) => !isTitle(n));
}

/* -------------------------------------------------------------------------- */
/* Rendering                                                                   */
/* -------------------------------------------------------------------------- */

const LANG_ALIAS = { sh: "bash", shell: "bash", console: "bash", conf: "ini", "": "text" };

const styleToClass = transformerStyleToClass({ classPrefix: "sk-" });

const processor = unified()
  .use(remarkRehype, {
    handlers: {
      callout: (state, node) => ({
        type: "element",
        tagName: "div",
        properties: node.data.hProperties,
        children: state.all(node),
      }),
    },
  })
  .use(rehypeSlug)
  .use(rehypeShiki, {
    themes: { light: "github-light", dark: "github-dark" },
    defaultColor: false,
    defaultLanguage: "text",
    fallbackLanguage: "text",
    langAlias: LANG_ALIAS,
    langs: ["bash", "odin", "json", "ini", "python", "tsx", "typescript", "javascript", "css", "make", "diff", "yaml", "toml", "markdown"],
    transformers: [
      styleToClass,
      {
        name: "title",
        pre(node) {
          const meta = this.options.meta?.__raw ?? "";
          const t = meta.match(/title="([^"]+)"/);
          if (t) node.properties["data-title"] = t[1];
          node.properties["data-lang"] = this.options.lang;
        },
      },
    ],
  });

/**
 * A compact encoding of hast for the wire: a text node is a string, an
 * element is [tagName, properties or 0, ...children]. It is a fraction of
 * hast's own JSON, which matters for pages with hundreds of code blocks.
 */
function compact(node) {
  // Shiki's rehype plugin leaves each highlighted block wrapped in a nested
  // `root`; those are flattened into their parent.
  const flat = (list) => list.flatMap((c) => (c.type === "root" ? flat(c.children) : [c]));
  const kids = () => flat(node.children).map(compact).filter((c) => c !== null);
  if (node.type === "text") return node.value;
  if (node.type === "element") {
    const props = node.properties && Object.keys(node.properties).length ? node.properties : 0;
    return [node.tagName, props, ...kids()];
  }
  if (node.type === "root") return ["#root", 0, ...kids()];
  return null; // comments, doctype
}

function stripPositions(node) {
  delete node.position;
  if (node.data && Object.keys(node.data).length === 0) delete node.data;
  if (node.children) node.children.forEach(stripPositions);
  return node;
}

/** h2/h3 (or h2 only) become the "On this page" rail. */
function tocOf(hast, depth) {
  const out = [];
  visit(hast, "element", (n) => {
    const d = { h2: 2, h3: 3 }[n.tagName];
    if (!d || d > depth || !n.properties?.id) return;
    out.push({ id: n.properties.id, title: hastText(n).trim(), depth: d });
  });
  return out;
}

function lastUpdated(paths) {
  try {
    const out = execFileSync("git", ["log", "-1", "--format=%cs", "--", ...paths], {
      cwd: ROOT,
      encoding: "utf8",
    }).trim();
    return out || null;
  } catch {
    return null;
  }
}

/* -------------------------------------------------------------------------- */
/* Main                                                                        */
/* -------------------------------------------------------------------------- */

VARS = templateVars();

const outputs = new Map(); // relative path -> string

for (const p of pages) {
  let nodes;
  if (p.source.file) {
    nodes = tagOrigin(extract(p.source.file, p.source), p.source.file);
  } else {
    nodes = handPage(p.source.page);
  }
  shiftHeadings(nodes, 2);
  if (p.after) nodes.push(...handPage(p.after.page));
  if (p.note) {
    const body = parsePageMd(p.note.body).children;
    nodes.unshift(callout(p.note.type, p.note.title, body));
  }

  const tree = { type: "root", children: nodes };
  rewriteLinks(tree);
  alerts(tree);
  keycaps(tree);

  const hast = stripPositions(await processor.run(tree));
  const toc = tocOf(hast, p.tocDepth ?? 3);

  const sourcePath = p.source.file ?? `site/content/pages/${p.source.page}`;
  const sources = [sourcePath, ...(p.generated ?? [])];
  const page = {
    url: p.url,
    slug: p.slug,
    collection: p.collection,
    group: p.group,
    title: p.title,
    description: p.description,
    toc,
    source: {
      path: sourcePath,
      edit: `${GH}/edit/${BRANCH}/${sourcePath}`,
      view: `${GH}/blob/${BRANCH}/${sourcePath}`,
      generated: (p.generated ?? []).map((g) => ({
        path: g,
        url: `${GH}/${existsSync(join(ROOT, g)) && statSync(join(ROOT, g)).isDirectory() ? "tree" : "blob"}/${BRANCH}/${g}`,
      })),
    },
    updated: lastUpdated(sources.map((s) => (s.startsWith("site/") ? s : s))),
    hast: compact(hast),
  };
  outputs.set(`pages/${p.collection}__${p.slug}.json`, JSON.stringify(page));
}

const nav = Object.fromEntries(
  Object.entries(COLLECTIONS).map(([cid, col]) => [
    cid,
    {
      base: col.base,
      title: col.title,
      groups: col.groups.map((g) => ({
        title: g.title,
        pages: g.pages.map((p) => ({
          slug: p.slug,
          url: `${col.base}/${p.slug}`,
          title: p.title,
          nav: p.nav ?? p.title,
          description: p.description,
        })),
      })),
    },
  ]),
);
outputs.set("shiki.css", "/* Generated by scripts/sync-docs.mjs. */\n" + styleToClass.getCSS() + "\n");
outputs.set("nav.json", JSON.stringify(nav, null, 2) + "\n");

/* -------------------------------------------------------------------------- */
/* Write, or compare                                                           */
/* -------------------------------------------------------------------------- */

let stale = [];
if (CHECK) {
  for (const [rel, text] of outputs) {
    const f = join(OUT, rel);
    if (!existsSync(f) || readFileSync(f, "utf8") !== text) stale.push(rel);
  }
  for (const [path] of IMAGES) {
    const f = join(IMG_OUT, path);
    if (!existsSync(f) || !readFileSync(f).equals(readFileSync(join(ROOT, path)))) stale.push(`docs-img/${path}`);
  }
  if (stale.length) {
    console.error(`sync-docs: ${stale.length} generated file(s) are stale; run npm run sync:\n  ${stale.slice(0, 20).join("\n  ")}`);
    process.exit(1);
  }
  console.log(`sync-docs: ${outputs.size} files up to date`);
  process.exit(0);
}

rmSync(join(OUT, "pages"), { recursive: true, force: true });
rmSync(IMG_OUT, { recursive: true, force: true });
for (const [rel, text] of outputs) {
  const f = join(OUT, rel);
  mkdirSync(dirname(f), { recursive: true });
  writeFileSync(f, text);
}
for (const [path] of IMAGES) {
  const f = join(IMG_OUT, path);
  mkdirSync(dirname(f), { recursive: true });
  copyFileSync(join(ROOT, path), f);
}
let bytes = 0;
for (const t of outputs.values()) bytes += t.length;
console.log(
  `sync-docs: ${pages.length} pages, ${IMAGES.size} images, ${(bytes / 1024).toFixed(0)} KiB of page data`,
);
