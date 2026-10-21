// compare.mjs: byte-compare a web run's canvas captures with the native
// replay's frames.
//
//   node palmy/web/demo/compare.mjs <dir>
//
// <dir> holds what drive.mjs wrote (captures.json, web-<n>.rgba) and what the
// native replay wrote (native-<n>.rgba). For each capture it reports how many
// bytes and pixels differ, the largest channel difference and the bounding box
// of the difference, and writes web-<name>.png, native-<name>.png and, when
// they differ, diff-<name>.png (the frame dimmed, differing pixels red).
// Exits 1 if any capture differs other than by a text caret's blink phase.
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { deflateSync } from "node:zlib";

const dir = process.argv[2];
const { captures } = JSON.parse(await readFile(join(dir, "captures.json"), "utf8"));

function crc32(buf) {
	let c, crc = 0xffffffff;
	for (let n = 0; n < buf.length; n++) {
		c = (crc ^ buf[n]) & 0xff;
		for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
		crc = (crc >>> 8) ^ c;
	}
	return (crc ^ 0xffffffff) >>> 0;
}
function png(rgba, w, h) {
	const raw = Buffer.alloc((w * 4 + 1) * h);
	for (let y = 0; y < h; y++) {
		raw[y * (w * 4 + 1)] = 0;
		rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
	}
	const chunk = (type, data) => {
		const len = Buffer.alloc(4);
		len.writeUInt32BE(data.length);
		const td = Buffer.concat([Buffer.from(type), data]);
		const crc = Buffer.alloc(4);
		crc.writeUInt32BE(crc32(td));
		return Buffer.concat([len, td, crc]);
	};
	const ihdr = Buffer.alloc(13);
	ihdr.writeUInt32BE(w, 0);
	ihdr.writeUInt32BE(h, 4);
	ihdr[8] = 8;
	ihdr[9] = 6;
	return Buffer.concat([
		Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
		chunk("IHDR", ihdr),
		chunk("IDAT", deflateSync(raw)),
		chunk("IEND", Buffer.alloc(0)),
	]);
}

let failed = 0;
const report = [];
for (const c of captures) {
	const web = await readFile(join(dir, `web-${c.n}.rgba`));
	let nat;
	try {
		nat = await readFile(join(dir, `native-${c.n}.rgba`));
	} catch {
		console.log(`${c.name}: no native frame ${c.n}`);
		failed++;
		continue;
	}
	await writeFile(join(dir, `web-${c.name}.png`), png(web, c.w, c.h));
	await writeFile(join(dir, `native-${c.name}.png`), png(nat, c.w, c.h));
	const r = { name: c.name, frame: c.n, w: c.w, h: c.h, bytes: web.length, sizeMatch: web.length === nat.length };
	if (!r.sizeMatch) {
		console.log(`${c.name}: sizes differ, web ${web.length} native ${nat.length}`);
		failed++;
		report.push(r);
		continue;
	}
	let bytes = 0, pixels = 0, maxd = 0, x0 = c.w, y0 = c.h, x1 = -1, y1 = -1;
	const diff = Buffer.alloc(web.length);
	for (let i = 0; i < web.length; i += 4) {
		let d = 0;
		for (let k = 0; k < 4; k++) {
			const dd = Math.abs(web[i + k] - nat[i + k]);
			if (dd) bytes++;
			d = Math.max(d, dd);
		}
		const p = i / 4, x = p % c.w, y = (p / c.w) | 0;
		if (d) {
			pixels++;
			maxd = Math.max(maxd, d);
			x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y);
			diff[i] = 255; diff[i + 1] = 0; diff[i + 2] = 0; diff[i + 3] = 255;
		} else {
			diff[i] = web[i] >> 2; diff[i + 1] = web[i + 1] >> 2; diff[i + 2] = web[i + 2] >> 2; diff[i + 3] = 255;
		}
	}
	Object.assign(r, { bytesDiffer: bytes, pixelsDiffer: pixels, maxChannelDelta: maxd, bbox: pixels ? [x0, y0, x1, y1] : null });
	report.push(r);
	// A text caret blinks on the wall clock in a window (time since the last
	// keystroke) and on the renderer's synthetic clock offscreen
	// (widgets.odin, caret_on), so in any one frame it can be lit on one side
	// and not the other. A difference no wider than a caret and no taller
	// than a line of text is that, and is reported as such; anything else is
	// a failure.
	r.caretOnly = pixels > 0 && x1 - x0 + 1 <= 4 && y1 - y0 + 1 <= 96; // 2x: a 2 px caret, a 48 px line
	if (pixels && r.caretOnly) {
		await writeFile(join(dir, `diff-${c.name}.png`), png(diff, c.w, c.h));
		console.log(`${c.name} (frame ${c.n}): caret only -- ${pixels} pixels in a ${x1 - x0 + 1}x${y1 - y0 + 1} column at ${x0},${y0}`);
	} else if (pixels) {
		failed++;
		await writeFile(join(dir, `diff-${c.name}.png`), png(diff, c.w, c.h));
		console.log(`${c.name} (frame ${c.n}): ${pixels} pixels / ${bytes} bytes differ, max delta ${maxd}, box ${x0},${y0}..${x1},${y1}`);
	} else {
		console.log(`${c.name} (frame ${c.n}): identical, ${web.length} bytes`);
	}
}
await writeFile(join(dir, "compare.json"), JSON.stringify(report, null, 1));
process.exit(failed ? 1 : 0);
