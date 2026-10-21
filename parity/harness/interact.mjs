// Capture interaction states from the browser: hover, focus, typed text.
//
//   node interact.mjs [BASE_URL]
//
// Each state is written as `<case>@<state>.png` / `.json` next to the base
// captures, so the Odin side can register a case with the same id and the same
// diff pipeline measures it. Nothing here is specific to one component: the
// state list says which cases get which interactions.
import { chromium } from "playwright";
import { mkdirSync, writeFileSync } from "node:fs";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

// Paths are resolved from this file, so a worktree writes into its own out/web
// (as harness/capture.mjs does). OUT_DIR overrides, as there.
const HERE = path.dirname(fileURLToPath(import.meta.url));

const BASE = process.argv[2] || process.env.BASE_URL || "http://localhost:5173";
const OUT = process.env.OUT_DIR || path.resolve(HERE, "..", "out", "web");
mkdirSync(OUT, { recursive: true });

// What to do, per case. `type` sends keystrokes into the focused element.
const PLAN = [
  { id: "button-default", states: ["hover", "focus"] },
  { id: "button-secondary", states: ["hover"] },
  { id: "button-outline", states: ["hover"] },
  { id: "button-destructive", states: ["hover"] },
  { id: "button-ghost", states: ["hover"] },
  { id: "input-default", states: ["focus"] },
  { id: "input-placeholder", states: ["focus", "typed"] },
  { id: "checkbox-default", states: ["hover", "focus"] },
  { id: "switch-off", states: ["hover", "focus"] },
];

const TYPED_TEXT = "Hello";

const collect = readFileSync(
  path.join(HERE, "capture.mjs"),
  "utf8"
).includes("collectGeometry")
  ? null
  : null;

const browser = await chromium.launch();
const page = await browser.newPage({
  viewport: { width: 1280, height: 800 },
  deviceScaleFactor: 1,
  colorScheme: "light",
});

let ok = 0;
const failed = [];

for (const { id, states } of PLAN) {
  for (const state of states) {
    const outId = `${id}@${state}`;
    try {
      await page.goto(`${BASE}/iso/${id}`, { waitUntil: "load" });
      await page.waitForSelector("body[data-parity-ready]", { timeout: 15000 });
      await page.evaluate(() => document.fonts.ready);

      const root = page.locator("[data-parity-root]").first();

      if (state === "hover") {
        await root.hover({ force: true });
      } else if (state === "focus" || state === "typed") {
        // Tab, not element.focus(): `:focus-visible` only matches when focus
        // arrived from the keyboard, and that is the state shadcn styles. A
        // programmatic focus() gets the user-agent outline instead, which is a
        // different thing entirely.
        let landed = false;
        for (let i = 0; i < 12 && !landed; i++) {
          await page.keyboard.press("Tab");
          landed = await page.evaluate(() => {
            const r = document.querySelector("[data-parity-root]");
            const a = document.activeElement;
            return !!(r && a && (r === a || r.contains(a)));
          });
        }
        if (!landed) throw new Error("Tab never reached the component");
        // Tabbing into a text field selects its contents; collapse that so the
        // capture shows a focused field rather than a selection highlight.
        await page.keyboard.press("End");
        if (state === "typed") {
          await page.keyboard.type(TYPED_TEXT, { delay: 10 });
        }
      }

      // Let any state-driven style settle (transitions are already disabled).
      await page.waitForTimeout(80);

      await root.screenshot({ path: `${OUT}/${outId}.png` });

      const geom = await page.evaluate(() => {
        const r = document.querySelector("[data-parity-root]");
        const b = r.getBoundingClientRect();
        const cs = getComputedStyle(r);
        const px = (v) => parseFloat(v) || 0;
        const round = (v) => Math.round(v * 1000) / 1000;
        return {
          tag: r.tagName.toLowerCase(),
          cls: String(r.getAttribute("class") || ""),
          text: r.textContent.trim().slice(0, 120),
          rect: { x: 0, y: 0, w: round(b.width), h: round(b.height) },
          pageRect: { x: round(b.left), y: round(b.top), w: round(b.width), h: round(b.height) },
          cropOffset: {
            x: round(b.left - Math.floor(b.left)),
            y: round(b.top - Math.floor(b.top)),
          },
          style: {
            backgroundColor: cs.backgroundColor,
            color: cs.color,
            borderWidth: [cs.borderTopWidth, cs.borderRightWidth, cs.borderBottomWidth, cs.borderLeftWidth].map(px),
            borderColor: cs.borderTopColor,
            borderRadius: [cs.borderTopLeftRadius, cs.borderTopRightRadius, cs.borderBottomRightRadius, cs.borderBottomLeftRadius].map(px),
            padding: [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(px),
            fontSize: px(cs.fontSize),
            fontWeight: Number(cs.fontWeight) || 400,
            lineHeight: cs.lineHeight === "normal" ? "normal" : px(cs.lineHeight),
            letterSpacing: cs.letterSpacing === "normal" ? 0 : px(cs.letterSpacing),
            opacity: Number(cs.opacity),
            boxShadow: cs.boxShadow,
            textAlign: cs.textAlign,
            outlineWidth: px(cs.outlineWidth),
            outlineColor: cs.outlineColor,
          },
          children: [],
        };
      });

      writeFileSync(`${OUT}/${outId}.json`, JSON.stringify(geom, null, 2));
      console.log(`  ok   ${outId.padEnd(34)} ${geom.rect.w}x${geom.rect.h}`);
      ok++;
    } catch (e) {
      failed.push(`${outId}: ${e.message.split("\n")[0]}`);
      console.log(`  FAIL ${outId}: ${e.message.split("\n")[0]}`);
    }
  }
}

await browser.close();
console.log(`\n${ok} interaction states captured, ${failed.length} failed`);
if (failed.length) process.exit(1);
