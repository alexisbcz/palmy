// times.mjs: frame time, web against native, for the frames both drew.
//
//   node palmy/web/demo/times.mjs <dir>
//
// web-times.json (drive.mjs): for each frame the browser was shown, `ms` is
// the program's whole frame on the page -- input dispatch, the app's code,
// layout, paint, the damage diff and the canvas put -- and `put` the canvas
// copy alone. native-times.json (the replay): the same frame's build, layout
// and paint through an offscreen renderer on the build machine. The first
// frame (startup: font loading, glyph caches) is reported apart.
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const dir = process.argv[2];
const web = JSON.parse(await readFile(join(dir, "web-times.json"), "utf8"));
const nat = JSON.parse(await readFile(join(dir, "native-times.json"), "utf8"));
const natBy = new Map(nat.map((f) => [f.n, f.ms]));
const q = (a, p) => {
	const s = [...a].sort((x, y) => x - y);
	return s[Math.min(s.length - 1, Math.floor(p * (s.length - 1) + 0.5))];
};
const fmt = (a) => a.length ? `median ${q(a, 0.5).toFixed(2)} ms, p95 ${q(a, 0.95).toFixed(2)} ms, max ${Math.max(...a).toFixed(2)} ms (n=${a.length})` : "none";
const first = web[0];
const rest = web.slice(1);
const w = rest.map((f) => f.ms);
const put = rest.map((f) => f.put);
const n = rest.filter((f) => natBy.has(f.n)).map((f) => natBy.get(f.n));
const out = {
	first: { web: first.ms, native: natBy.get(first.n) },
	web: { median: q(w, 0.5), p95: q(w, 0.95), max: Math.max(...w), n: w.length },
	put: { median: q(put, 0.5), p95: q(put, 0.95), max: Math.max(...put) },
	native: { median: q(n, 0.5), p95: q(n, 0.95), max: Math.max(...n), n: n.length },
};
console.log(`first frame: web ${first.ms.toFixed(1)} ms, native ${(natBy.get(first.n) ?? NaN).toFixed(1)} ms`);
console.log(`web frames:    ${fmt(w)}`);
console.log(`  canvas put:  ${fmt(put)}`);
console.log(`native frames: ${fmt(n)}`);
console.log(JSON.stringify(out));
