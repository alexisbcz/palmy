import { chromium } from "playwright";
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 1280, height: 800 }, deviceScaleFactor: 1 });
await p.goto("http://localhost:5190/iso/button-default", { waitUntil: "networkidle" });
await p.waitForSelector("body[data-parity-ready]");
const out = await p.evaluate(() => {
  const el = document.querySelector("[data-parity-root]");
  const cs = getComputedStyle(el);
  const c = document.createElement("canvas").getContext("2d");
  const probe = (font) => { c.font = font; return c.measureText("Button").width; };
  return {
    computedFontFamily: cs.fontFamily,
    computedFontSize: cs.fontSize,
    computedWeight: cs.fontWeight,
    letterSpacing: cs.letterSpacing,
    fontKerning: cs.fontKerning,
    rootWidth: el.getBoundingClientRect().width,
    textWidth: (() => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect().width; })(),
    probes: {
      geistParity500: probe('500 14px GeistParity'),
      geistVariable500: probe('500 14px "Geist Variable"'),
      systemSans500: probe('500 14px sans-serif'),
    },
    loaded: [...document.fonts].map(f => `${f.family} ${f.weight} ${f.status}`),
  };
});
console.log(JSON.stringify(out, null, 2));
// Which physical font did Chromium pick?
const cdp = await p.context().newCDPSession(p);
await cdp.send("DOM.enable"); await cdp.send("CSS.enable");
const { root } = await cdp.send("DOM.getDocument");
const { nodeId } = await cdp.send("DOM.querySelector", { nodeId: root.nodeId, selector: "[data-parity-root]" });
const fonts = await cdp.send("CSS.getPlatformFontsForNode", { nodeId });
console.log("platform fonts:", JSON.stringify(fonts.fonts));
await b.close();
