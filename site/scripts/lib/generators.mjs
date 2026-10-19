/**
 * Reference material read out of the repository's own source, so the site
 * cannot describe a key binding, a class or a procedure the code no longer
 * has. Every generator returns Markdown (or mdast built from it), which then
 * goes through the same pipeline as the hand-written pages.
 *
 * The parsers here are deliberately narrow: they match the shapes the Odin
 * files actually use and fail loudly (throw) when an anchor they rely on is
 * gone, rather than quietly producing an empty table.
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const read = (root, p) => readFileSync(join(root, p), "utf8");

function must(cond, what) {
  if (!cond) throw new Error(`generator: ${what}`);
}

/** Escapes a string for a Markdown table cell. */
const cell = (s) => String(s ?? "").replace(/\|/g, "\\|").replace(/\n+/g, " ");
const code = (s) => {
  const t = String(s);
  // A backtick inside needs a longer fence.
  return t.includes("`") ? "`` " + t + " ``" : "`" + t + "`";
};

/* -------------------------------------------------------------------------- */
/* Window manager: key bindings                                                */
/* -------------------------------------------------------------------------- */

const KEY_NAMES = {
  Return: "Enter",
  Slash: "/",
  Backslash: "\\",
  Prior: "Page Up",
  Next: "Page Down",
  Space: "Space",
  Tab: "Tab",
};

/** The `CFG_DEFAULT` text: the built-in wm.conf. */
export function wmDefaultConfig(root) {
  const src = read(root, "apps/wm/config.odin");
  const m = src.match(/^CFG_DEFAULT :: `\n([\s\S]*?)^`/m);
  must(m, "apps/wm/config.odin: CFG_DEFAULT not found");
  return m[1].replace(/\s+$/, "") + "\n";
}

/** verb -> action enum name, from `cfg_action`. */
function wmVerbs(root) {
  const src = read(root, "apps/wm/config.odin");
  const start = src.indexOf("cfg_action :: proc");
  must(start >= 0, "cfg_action not found");
  const body = src.slice(start, src.indexOf("\n}\n", start));
  const out = {};
  const re = /case ((?:"[^"]+",?\s*)+):([\s\S]*?)bind\.act = \.(\w+)/g;
  let m;
  while ((m = re.exec(body))) {
    const verbs = [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
    for (const v of verbs) out[v] = m[3];
  }
  must(out.close && out.workspace, "cfg_action: verb table looks wrong");
  return out;
}

/** Splits a `switch` body into `case .X, .Y:` -> body text. */
function enumCases(body) {
  const out = {};
  const re = /\n\tcase ((?:\.\w+,?\s*)+):\n([\s\S]*?)(?=\n\tcase |\n\t}\n)/g;
  let m;
  while ((m = re.exec(body))) {
    for (const name of m[1].match(/\.(\w+)/g).map((s) => s.slice(1))) {
      out[name] = m[2];
    }
  }
  return out;
}

function procBody(src, name) {
  const start = src.indexOf(`${name} :: proc`);
  must(start >= 0, `${name} not found`);
  return src.slice(start, src.indexOf("\n}\n", start) + 3);
}

/** The cheat sheet's heading for each action, from `bind_group`. */
function wmGroups(root) {
  const body = procBody(read(root, "apps/wm/keys.odin"), "bind_group");
  const out = {};
  for (const [name, b] of Object.entries(enumCases(body))) {
    const r = b.match(/return "([^"]+)"/);
    if (r) out[name] = r[1];
  }
  must(Object.keys(out).length > 10, "bind_group parsed to nothing");
  return out;
}

const DIRS = ["left", "right", "up", "down"];

/**
 * A binding's action in words, the way `bind_human` says it. The forms that
 * function uses are few: a literal, a format with the direction or the
 * number, a two-way ternary, and one nested switch on direction.
 */
function wmHumanizer(root) {
  const body = procBody(read(root, "apps/wm/keys.odin"), "bind_human");
  const cases = enumCases(body);
  return (act, arg, argv) => {
    const b = cases[act];
    if (!b) return null;
    if (act === "Spawn") return argv[0] ? `Open ${argv[0]}` : "Run a command";
    // Nested switch on direction.
    const nested = [...b.matchAll(/case \.(Left|Right|Up|Down):\s*\n\s*return "([^"]+)"/g)];
    if (nested.length) {
      const want = ["Left", "Right", "Up", "Down"][arg];
      const hit = nested.find((n) => n[1] === want);
      if (hit) return hit[2];
    }
    const tern = b.match(/b\.arg (<|==) (-?\d+) \? "([^"]+)" : "([^"]+)"/);
    if (tern) {
      const n = Number(tern[2]);
      const yes = tern[1] === "<" ? arg < n : arg === n;
      return yes ? tern[3] : tern[4];
    }
    const fmt = b.match(/fmt\.tprintf\("([^"]+)",\s*([^)]+\)?)\)/);
    if (fmt) {
      const v = fmt[2].includes("dir_word")
        ? DIRS[arg]
        : fmt[2].includes("cfg_session_name")
          ? argv[0]
          : String(arg);
      return fmt[1].replace(/%[sd]/, v);
    }
    const lit = b.match(/return "([^"]+)"/);
    return lit ? lit[1] : null;
  };
}

function keyLabel(k) {
  return KEY_NAMES[k] ?? k;
}

/**
 * Every binding in the built-in configuration, grouped as the wm's own
 * Super+/ cheat sheet groups them, with families folded the way it folds
 * them (Super+1 ... Super+9 is one row).
 */
export function wmBindings(root) {
  const cfg = wmDefaultConfig(root);
  const verbs = wmVerbs(root);
  const groups = wmGroups(root);
  const human = wmHumanizer(root);
  const modLine = cfg.match(/^mod\s*=\s*(\S+)/m);
  const MOD = modLine ? modLine[1] : "SUPER";

  const rows = [];
  for (const line of cfg.split("\n")) {
    const m = line.match(/^bind\s*=\s*([^,]+),\s*([^,]+),\s*(.+?)\s*$/);
    if (!m) continue;
    const mods = m[1]
      .trim()
      .split(/\s+/)
      .map((x) => (x === "$mod" ? MOD : x));
    const anyMods = mods.includes("ANY");
    const key = m[2].trim();
    const [verb, ...rest] = m[3].trim().split(/\s+/);
    const act = verbs[verb.toLowerCase()];
    if (!act) throw new Error(`wm: unknown action ${verb} in CFG_DEFAULT`);
    const argText = rest.join(" ");
    let arg = 0;
    if (DIRS.includes(argText.toLowerCase())) arg = DIRS.indexOf(argText.toLowerCase());
    else if (/^[+-]?\d+$/.test(argText)) arg = Number(argText);
    else if (act === "Switcher") arg = argText.toLowerCase() === "all" ? 1 : 0;
    const argv = act === "Session" ? [verb.toLowerCase()] : rest;
    const order = ["SUPER", "CTRL", "ALT", "SHIFT"];
    const keys = anyMods
      ? [keyLabel(key)]
      : [
          ...order
            .filter((o) => mods.map((x) => x.toUpperCase()).includes(o))
            .map((o) => o[0] + o.slice(1).toLowerCase()),
          keyLabel(key),
        ];
    rows.push({
      group: groups[act] ?? "Session",
      label: human(act, arg, argv) ?? m[3].trim(),
      keys,
      config: line.trim(),
    });
  }
  must(rows.length > 20, "wm: fewer than 20 bindings parsed");

  // One row per action label; later chords for the same label become "also".
  const merged = [];
  const seen = new Map();
  for (const r of rows) {
    const k = r.group + "\0" + r.label;
    if (seen.has(k)) {
      seen.get(k).also.push(r.keys);
      continue;
    }
    const row = { ...r, also: [] };
    seen.set(k, row);
    merged.push(row);
  }

  // Fold digit runs: "Workspace 1".."Workspace 9" -> "Workspace 1…9".
  const folded = [];
  for (let i = 0; i < merged.length; i++) {
    const r = merged[i];
    const digit = /^\d$/.test(r.keys.at(-1)) && /\d$/.test(r.label);
    if (digit) {
      let j = i;
      while (
        j + 1 < merged.length &&
        merged[j + 1].group === r.group &&
        merged[j + 1].keys.slice(0, -1).join() === r.keys.slice(0, -1).join() &&
        Number(merged[j + 1].keys.at(-1)) === Number(merged[j].keys.at(-1)) + 1 &&
        merged[j + 1].label.replace(/\d+$/, "") === r.label.replace(/\d+$/, "")
      ) {
        j++;
      }
      if (j > i) {
        const last = merged[j];
        folded.push({
          ...r,
          label: r.label.replace(/\d+$/, `${r.keys.at(-1)}…${last.keys.at(-1)}`),
          keys: [...r.keys.slice(0, -1), `${r.keys.at(-1)}…${last.keys.at(-1)}`],
          also: [],
        });
        i = j;
        continue;
      }
    }
    folded.push(r);
  }

  // Fold direction families: four rows that differ only in the direction.
  const out = [];
  const used = new Set();
  for (let i = 0; i < folded.length; i++) {
    if (used.has(i)) continue;
    const r = folded[i];
    const dm = r.label.match(/^(.*) (left|right|up|down)$/);
    if (!dm) {
      out.push(r);
      continue;
    }
    const fam = [i];
    for (let j = i + 1; j < folded.length; j++) {
      const o = folded[j];
      const om = o.label.match(/^(.*) (left|right|up|down)$/);
      if (
        om &&
        om[1] === dm[1] &&
        o.group === r.group &&
        o.keys.slice(0, -1).join() === r.keys.slice(0, -1).join()
      ) {
        fam.push(j);
      }
    }
    if (fam.length < 2) {
      out.push(r);
      continue;
    }
    for (const j of fam) used.add(j);
    out.push({
      ...r,
      label: `${dm[1]} ${fam.map((j) => folded[j].label.match(/(left|right|up|down)$/)[1]).join(", ")}`,
      keys: [...r.keys.slice(0, -1), fam.map((j) => folded[j].keys.at(-1)).join(" ")],
    });
  }
  return { mod: MOD, rows: out, raw: rows };
}

/** The mouse gestures the cheat sheet lists (they have no binding to read). */
export function wmMouse(root) {
  const src = read(root, "apps/wm/cheatsheet.odin");
  const m = src.match(/CHEAT_MOUSE :=[^{]*{([\s\S]*?)\n}/);
  must(m, "CHEAT_MOUSE not found");
  return [...m[1].matchAll(/{"([^"]+)",\s*"([^"]+)"}/g)].map((x) => ({
    gesture: x[1],
    action: x[2],
  }));
}

export function wmGroupOrder(root) {
  const src = read(root, "apps/wm/cheatsheet.odin");
  const m = src.match(/CHEAT_GROUPS := \[\?\]string{([^}]*)}/);
  must(m, "CHEAT_GROUPS not found");
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

/* -------------------------------------------------------------------------- */
/* palmy: the class grammar                                                    */
/* -------------------------------------------------------------------------- */

/**
 * Reads `apply_classes` and `apply_token` in palmy/class.odin. The output is a
 * structured description: variants, exact utilities (and which of them are
 * accepted but do nothing), prefixed families with the value grammar each
 * uses, and the named scales.
 */
export function palmyClasses(root) {
  const src = read(root, "palmy/class.odin");

  // Variants.
  const ac = procBody(src, "apply_classes");
  const variants = [...ac.matchAll(/case "([^"]+)":\n\s*active &= ([^\n]+)/g)].map(
    (m) => ({ name: m[1], when: m[2].trim() }),
  );
  must(variants.length >= 4, "apply_classes: variants not found");

  const at = procBody(src, "apply_token");
  const lines = at.split("\n");

  // Top-level exact cases are indented by exactly one tab.
  const exact = [];
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^\tcase ((?:"[^"]+",?\s*)+):\s*$/);
    // Multi-line case lists continue on lines indented with a tab and spaces.
    let header = lines[i];
    let j = i;
    if (!m && /^\tcase "/.test(lines[i]) && !lines[i].trimEnd().endsWith(":")) {
      while (j + 1 < lines.length && !lines[j].trimEnd().endsWith(":")) {
        j++;
        header += " " + lines[j].trim();
      }
    } else if (!m) {
      continue;
    }
    const names = [...header.matchAll(/"([^"]+)"/g)].map((x) => x[1]);
    const body = [];
    let k = j + 1;
    while (k < lines.length && !/^\tcase |^\t}/.test(lines[k])) body.push(lines[k++]);
    const stmts = body
      .map((l) => l.trim())
      .filter((l) => l && !l.startsWith("//"));
    const notes = body
      .map((l) => l.trim())
      .filter((l) => l.startsWith("//"))
      .map((l) => l.replace(/^\/\/\s?/, ""))
      .join(" ");
    const noop = stmts.length === 0 || stmts.every((s) => s === "return");
    exact.push({ names, noop, notes });
    i = k - 1;
  }
  must(exact.length > 20, "apply_token: exact utilities not found");

  // Prefixed families, in source order, with the comment group they sit under.
  const families = [];
  let section = "";
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const sec = l.match(/^\t\/\/ ([A-Z][\w ,]{0,40})\.$/);
    if (sec) section = sec[1];
    const pm = l.match(/^\tif v, ok := strip\(t, "([^"]+)"\); ok {/);
    const sp = l.match(/^\tif strings\.has_prefix\(t, "([^"]+)"\) {/);
    if (!pm && !sp) continue;
    let depth = 0;
    const body = [];
    for (let k = i; k < lines.length; k++) {
      depth += (lines[k].match(/{/g) || []).length;
      depth -= (lines[k].match(/}/g) || []).length;
      body.push(lines[k]);
      if (depth === 0) break;
    }
    const b = body.join("\n");
    const prefix = pm ? pm[1] : sp[1] + "{side}-";
    const values = [];
    if (/_ = v/.test(b) && !/s\./.test(b.replace(/_ = v/, ""))) values.push("ignored");
    if (/\bdim_of\(/.test(b)) values.push("size");
    if (/\bscale\(/.test(b)) values.push("spacing");
    if (/\bscale_px\(/.test(b)) values.push("pixels");
    if (/parse_color\(/.test(b)) values.push("color");
    if (/radius_of\(/.test(b)) values.push("radius");
    if (/font_size_of\(/.test(b)) values.push("font-size");
    if (/border_width\(/.test(b)) values.push("border-width");
    if (/align_of_name\(/.test(b)) values.push("align");
    if (/strconv\.parse_(f32|int)\(v\)/.test(b)) values.push("number");
    const named = [...b.matchAll(/^\t\tcase "([^"]+)":/gm)].map((x) => x[1]);
    const comment = [];
    for (let k = i - 1; k >= 0 && /^\t\/\//.test(lines[k]); k--) {
      comment.unshift(lines[k].replace(/^\t\/\/\s?/, ""));
    }
    families.push({
      prefix,
      section,
      values,
      named,
      note: body
        .filter((x) => /^\t\t\/\//.test(x))
        .map((x) => x.trim().replace(/^\/\/\s?/, ""))
        .join(" "),
      setsSides: sp ? true : false,
    });
  }
  must(families.length > 20, "apply_token: prefixed utilities not found");

  const caseTable = (procName) => {
    const body = procBody(src, procName);
    return [...body.matchAll(/case "([^"]*)":\n\s*return ([^\n]+)/g)].map((m) => ({
      name: m[1],
      value: m[2].trim(),
    }));
  };

  const hues = [...read(root, "palmy/palette.odin").matchAll(/{"(\w+)", {/g)].map(
    (m) => m[1],
  );
  const shades = read(root, "palmy/palette.odin")
    .match(/SHADES :: \[\d+\]int{([^}]*)}/)[1]
    .split(",")
    .map((s) => s.trim());

  return {
    variants,
    exact,
    families,
    fontSizes: caseTable("font_size_of"),
    radii: caseTable("radius_of"),
    hues,
    shades,
  };
}

/* -------------------------------------------------------------------------- */
/* Odin API: exported procedures and types                                     */
/* -------------------------------------------------------------------------- */

/**
 * Public declarations of an Odin package directory: every top-level `name ::
 * proc` or type not marked `@(private)`, with the `//` comment block above it.
 */
export function odinApi(root, dir) {
  const files = readdirSync(join(root, dir))
    .filter((f) => f.endsWith(".odin") && !f.endsWith("_test.odin"))
    .sort();
  const out = [];
  for (const f of files) {
    const lines = read(root, join(dir, f)).split("\n");
    // The file's own header comment, up to the package line.
    const head = [];
    for (const l of lines) {
      if (l.startsWith("package ")) break;
      if (l.startsWith("//")) head.push(l.replace(/^\/\/ ?/, ""));
      else if (head.length && l.trim() === "") head.push("");
    }
    const decls = [];
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(
        /^([A-Za-z][A-Za-z0-9_]*) :: (proc|struct|enum|union|distinct|#force_inline proc)\b/,
      );
      if (!m) continue;
      let k = i - 1;
      let isPrivate = false;
      while (k >= 0 && lines[k].startsWith("@(")) {
        if (/private/.test(lines[k])) isPrivate = true;
        k--;
      }
      if (isPrivate || m[1].startsWith("_")) continue;
      const doc = [];
      while (k >= 0 && lines[k].startsWith("//")) {
        doc.unshift(lines[k].replace(/^\/\/ ?/, ""));
        k--;
      }
      let sig;
      if (m[2].includes("proc")) {
        const parts = [lines[i]];
        let j = i;
        while (!/(\{|---)\s*$/.test(parts.at(-1)) && j + 1 < lines.length && j - i < 12) {
          parts.push(lines[++j]);
        }
        sig = parts
          .join("\n")
          .replace(/\s*\{\s*$/, "")
          .replace(/\s*---\s*$/, "");
        // A one-line body (`proc() -> T { return x }`) keeps only the signature.
        sig = sig.replace(/\s*\{[^{}]*\}\s*$/, "");
      } else {
        sig = lines[i].replace(/\s*\{\s*$/, "");
      }
      decls.push({ name: m[1], kind: m[2].includes("proc") ? "proc" : "type", sig, doc });
    }
    if (decls.length) out.push({ file: f, head: head.join("\n").trim(), decls });
  }
  return out;
}

/* -------------------------------------------------------------------------- */
/* Distribution: applications, packages, host tools, boot chain                */
/* -------------------------------------------------------------------------- */

export function appsTable(root) {
  const tsv = read(root, "distro/apps/apps.tsv").trimEnd().split("\n");
  const head = tsv[0].split("\t");
  const rows = tsv.slice(1).map((l) => {
    const c = l.split("\t");
    return Object.fromEntries(head.map((h, i) => [h, c[i] ?? ""]));
  });
  const defaults = read(root, "distro/apps/default.list")
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l && !l.startsWith("#"));
  const desktop = new Map();
  const ddir = join(root, "distro/apps/desktop");
  if (existsSync(ddir)) {
    for (const f of readdirSync(ddir)) {
      const t = readFileSync(join(ddir, f), "utf8");
      const name = t.match(/^Name=(.*)$/m)?.[1];
      const comment = t.match(/^Comment=(.*)$/m)?.[1];
      desktop.set(f.replace(/\.desktop$/, ""), { name, comment });
    }
  }
  const recipes = new Set(readdirSync(join(root, "distro/recipes")));
  return rows.map((r) => ({
    ...r,
    default: defaults.includes(r.binary),
    packaged: recipes.has(r.binary),
    desktop: desktop.get(r.binary) ?? null,
  }));
}

export function packages(root) {
  const dir = join(root, "distro/recipes");
  const out = [];
  for (const name of readdirSync(dir).sort()) {
    const f = join(dir, name, "PALMBUILD");
    if (!existsSync(f)) continue;
    const text = readFileSync(f, "utf8");
    const field = (k) => {
      const all = [...text.matchAll(new RegExp(`^${k}\\s*=\\s*(.*)$`, "gm"))].map((m) =>
        m[1].trim(),
      );
      return all;
    };
    const generated = /^# Generated by/m.test(text);
    out.push({
      name: field("pkgname")[0] ?? name,
      version: field("pkgver")[0] ?? "",
      release: field("pkgrel")[0] ?? "",
      desc: field("pkgdesc")[0] ?? "",
      category: field("category")[0] ?? "",
      depends: field("depend").join(" ").split(/\s+/).filter(Boolean),
      license: field("license")[0] ?? "",
      generated,
    });
  }
  const meta = out.find((p) => p.name === "palmy");
  const inMeta = new Set(meta ? meta.depends : []);
  return out.map((p) => ({ ...p, inPalmy: inMeta.has(p.name) }));
}

/** Tools a build script checks for with `for t in ...; do command -v`. */
export function hostTools(root, script) {
  const src = read(root, script);
  const m = src.match(/for t in ([^;]+); do\s*\n?\s*command -v/);
  must(m, `${script}: host tool check not found`);
  return m[1].trim().split(/\s+/);
}

export function versions(root) {
  const k = read(root, "distro/kernel/build.sh").match(/KERNEL_VERSION:-([0-9.]+)/);
  const bbFile = ["distro/busybox/build.sh"].find((p) => existsSync(join(root, p)));
  const b = bbFile ? read(root, bbFile).match(/(?:VER|VERSION)[^0-9]*([0-9]+\.[0-9]+(?:\.[0-9]+)?)/) : null;
  return { kernel: k?.[1] ?? "unknown", busybox: b?.[1] ?? "unknown" };
}

/**
 * The boot chain drawn in distro/README.md as an indented tree, read back as
 * nodes so the site can draw it as a diagram without a second copy.
 */
export function bootChain(root) {
  const md = read(root, "distro/README.md");
  const sec = md.match(/## The boot chain\s*\n+```[^\n]*\n([\s\S]*?)```/);
  must(sec, "distro/README.md: boot chain block not found");
  const nodes = [];
  for (const raw of sec[1].split("\n")) {
    if (!raw.trim()) continue;
    const m = raw.match(/^([\s│]*)(?:[└├]─\s*)?(.+)$/);
    const indent = m[1].length + (raw.match(/[└├]─/) ? 3 : 0);
    const text = m[2].trimEnd();
    // Name and note are separated by a run of two or more spaces.
    const parts = text.split(/\s{2,}/);
    nodes.push({ depth: indent, name: parts[0], note: parts.slice(1).join(" ") });
  }
  // Normalise indentation to levels.
  const levels = [...new Set(nodes.map((n) => n.depth))].sort((a, b) => a - b);
  return nodes.map((n) => ({ ...n, depth: levels.indexOf(n.depth) }));
}
