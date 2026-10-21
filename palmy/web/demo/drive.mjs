// drive.mjs: drive a palmy web build in Playwright's Chromium and capture its
// canvas.
//
//   node palmy/web/demo/drive.mjs <url> <scenario.json> <out-dir>
//
// The scenario is a list of steps, in canvas coordinates (logical pixels):
//
//   {"do": "click", "x": 158, "y": 206}         move there, press, release
//   {"do": "move", "x": 10, "y": 10}
//   {"do": "wheel", "x": 490, "y": 400, "dy": 300}   Chromium: 100 per notch
//   {"do": "type", "text": "Ada"}                 one keydown per character
//   {"do": "key", "key": "Control+a"}             Playwright key syntax
//   {"do": "viewport", "width": 900, "height": 600}   resize the page
//   {"do": "capture", "name": "after-click"}
//   {"do": "js", "js": "..."}                     run a page expression (awaited)
//   {"do": "expect", "js": "..."}                 a page expression that must be true
//
// After every step it waits until the program has drawn everything it is
// going to (palmy.state(): parked, nothing queued, no frame callback armed),
// then a capture reads the canvas with getImageData in the same task -- so the
// pixels and the frame number they belong to cannot come apart -- and writes
// web-<n>.rgba, where <n> is the frame's number in the frame log.
//
// It writes: web-<n>.rgba per capture, captures.json, frames.ndjson (the frame
// log, for native replay), web-times.json (per-present timings), and
// screenshot-<name>.png.
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { join, resolve } from "node:path";

async function loadPlaywright() {
	const tries = [process.env.PLAYWRIGHT_DIR, resolve("node_modules/playwright")].filter(Boolean);
	for (const t of tries) {
		try {
			return createRequire(join(t, "index.js"))(t);
		} catch {}
	}
	return await import("playwright");
}

const [url, scenarioPath, outDir] = process.argv.slice(2);
if (!url || !scenarioPath || !outDir) {
	console.error("usage: drive.mjs <url> <scenario.json> <out-dir>");
	process.exit(2);
}
const scenario = JSON.parse(await readFile(scenarioPath, "utf8"));
await mkdir(outDir, { recursive: true });

const { chromium } = await loadPlaywright();
const browser = await chromium.launch();
const context = await browser.newContext({
	viewport: scenario.viewport || { width: 1100, height: 820 },
	deviceScaleFactor: scenario.scale || 1,
});
await context.grantPermissions(["clipboard-read", "clipboard-write"], { origin: new URL(url).origin });
const page = await context.newPage();
const consoleLines = [];
page.on("console", (m) => consoleLines.push(`${m.type()}: ${m.text()}`));
page.on("pageerror", (e) => consoleLines.push(`pageerror: ${e.message}`));

const sep = url.includes("?") ? "&" : "?";
await page.goto(url + sep + "env=PALMY_WEB_LOG=1" + (scenario.query ? "&" + scenario.query : ""));
await page.waitForFunction(() => window.palmy || window.palmyError, null, { timeout: 60000 });
const err = await page.evaluate(() => window.palmyError);
if (err) throw new Error(err);

async function settle() {
	// Two consecutive quiet polls 40 ms apart.
	let quiet = 0;
	const t0 = Date.now();
	while (quiet < 2) {
		await page.waitForTimeout(40);
		const s = await page.evaluate(() => window.palmy.state());
		quiet = s.parked && s.queued === 0 && !s.frameArmed && s.presents > 0 ? quiet + 1 : 0;
		if (Date.now() - t0 > 15000) throw new Error("the program never went idle: " + JSON.stringify(s));
	}
}

const origin = await page.evaluate(() => {
	const r = document.getElementById("palmy-canvas").getBoundingClientRect();
	return [r.left, r.top];
});
const at = (s) => [origin[0] + s.x, origin[1] + s.y];

const captures = [];
const results = [];
await settle();
for (const step of scenario.steps) {
	switch (step.do) {
	case "click": {
		const [x, y] = at(step);
		await page.mouse.move(x, y);
		await settle();
		await page.mouse.down({ button: step.button || "left" });
		await settle();
		await page.mouse.up({ button: step.button || "left" });
		break;
	}
	case "move": {
		const [x, y] = at(step);
		await page.mouse.move(x, y, { steps: step.steps || 1 });
		break;
	}
	case "wheel": {
		const [x, y] = at(step);
		await page.mouse.move(x, y);
		await settle();
		await page.mouse.wheel(step.dx || 0, step.dy || 0);
		break;
	}
	case "type":
		await page.keyboard.type(step.text, { delay: step.delay || 0 });
		break;
	case "key":
		await page.keyboard.press(step.key);
		break;
	case "viewport":
		await page.setViewportSize({ width: step.width, height: step.height });
		break;
	case "wait":
		await page.waitForTimeout(step.ms);
		break;
	case "js":
		await page.evaluate(step.js);
		break;
	case "expect": {
		const ok = await page.evaluate(step.js);
		results.push({ expect: step.js, ok: !!ok });
		if (!ok) console.error("expectation failed: " + step.js);
		break;
	}
	case "capture": {
		await settle();
		const cap = await page.evaluate(() => {
			// One task: the state check, the pixels and the frame number.
			const s = window.palmy.state();
			const c = document.getElementById("palmy-canvas");
			const img = c.getContext("2d").getImageData(0, 0, c.width, c.height);
			const log = window.palmy.stats.log;
			// The canvas shows the last frame that was painted; a logic frame
			// after it (the page was not ready for pixels) left it alone.
			let last = 0;
			for (let i = log.length - 1; i >= 0; i--) {
				const f = JSON.parse(log[i]);
				if (f.paint) { last = f.n; break; }
			}
			let bin = "";
			const b = img.data;
			for (let i = 0; i < b.length; i += 0x8000) bin += String.fromCharCode.apply(null, b.subarray(i, i + 0x8000));
			return { n: last, w: c.width, h: c.height, parked: s.parked, data: btoa(bin) };
		});
		await writeFile(join(outDir, `web-${cap.n}.rgba`), Buffer.from(cap.data, "base64"));
		await page.screenshot({ path: join(outDir, `screenshot-${step.name}.png`) });
		captures.push({ name: step.name, n: cap.n, w: cap.w, h: cap.h });
		console.log(`capture ${step.name}: frame ${cap.n} (${cap.w}x${cap.h})`);
		break;
	}
	default:
		throw new Error("unknown step " + step.do);
	}
	await settle();
}

const stats = await page.evaluate(() => ({
	log: window.palmy.stats.log,
	frames: window.palmy.stats.frames,
	stderr: window.palmy.stats.stderr,
	exited: window.palmy.stats.exited,
	events: window.palmy.stats.events,
}));
await writeFile(join(outDir, "frames.ndjson"), stats.log.join("\n") + "\n");
await writeFile(join(outDir, "web-times.json"), JSON.stringify(stats.frames));
await writeFile(join(outDir, "captures.json"), JSON.stringify({ captures, expectations: results }, null, 1));
await writeFile(join(outDir, "console.txt"), consoleLines.join("\n") + "\n");
console.log(`frames logged: ${stats.log.length}, presented: ${stats.frames.length}, events: ${stats.events}, exited: ${stats.exited}`);
if (stats.stderr) console.log("stderr:\n" + stats.stderr);
await browser.close();
if (results.some((r) => !r.ok)) process.exit(1);
