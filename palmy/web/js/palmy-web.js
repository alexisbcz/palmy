// palmy-web.js: the page half of palmy's web backend.
//
// It runs a palmy program compiled for wasi_wasm32 (apps/tools/web-build.sh)
// and gives it three things:
//
//   1. A small WASI implementation over an in-memory filesystem. The files a
//      build ships (manifest.json: fonts, mostly) appear at the absolute paths
//      the program asks for, so palmy's font scan and an app's load_font work
//      unchanged -- and find only what was shipped. Writes land in memory and
//      last as long as the page.
//   2. The `palmy_web` imports that palmy/web/odin/window_wasi.odin calls: a
//      canvas to present into, an input queue, the frame callback, the
//      cursor, the title, and the async clipboard.
//   3. JSPI. `palmy_web_wait`, the clipboard calls and WASI `poll_oneoff`
//      (time.sleep) are WebAssembly.Suspending, and `_start` is wrapped in
//      WebAssembly.promising, so the program's frame loop can block on the
//      next event while the browser keeps running.
//
// Single-threaded: no workers, no SharedArrayBuffer.

const KEYSYM = {
	Backspace: 0xff08, Tab: 0xff09, Enter: 0xff0d, Escape: 0xff1b, Delete: 0xffff,
	Home: 0xff50, ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54,
	PageUp: 0xff55, PageDown: 0xff56, End: 0xff57, Insert: 0xff63, ContextMenu: 0xff67,
	Shift: 0xffe1, Control: 0xffe3, CapsLock: 0xffe5, Meta: 0xffeb, Alt: 0xffe9, AltGraph: 0xfe03,
	NumLock: 0xff7f, ScrollLock: 0xff14, Pause: 0xff13, PrintScreen: 0xff61,
};
for (let i = 1; i <= 24; i++) KEYSYM["F" + i] = 0xffbd + i;

// The first-level character of each physical key on a US board, which is the
// most a page can know about `unshifted`: KeyboardEvent.code names the key,
// not what the active layout puts on it.
const UNSHIFTED = {
	Minus: "-", Equal: "=", BracketLeft: "[", BracketRight: "]", Backslash: "\\",
	Semicolon: ";", Quote: "'", Backquote: "`", Comma: ",", Period: ".", Slash: "/", Space: " ",
	IntlBackslash: "<",
};

const KEYPAD = {
	NumpadMultiply: 0xffaa, NumpadAdd: 0xffab, NumpadSubtract: 0xffad, NumpadDecimal: 0xffae,
	NumpadDivide: 0xffaf, NumpadEnter: 0xff8d,
};
for (let i = 0; i <= 9; i++) KEYPAD["Numpad" + i] = 0xffb0 + i;

const CURSORS = [
	"default", "default", "pointer", "text", "crosshair", "move", "wait", "progress", "help",
	"not-allowed", "grab", "grabbing", "col-resize", "row-resize",
];

function keysymOf(e) {
	if (e.code in KEYPAD && e.location === 3) return KEYPAD[e.code];
	if (e.key in KEYSYM) return KEYSYM[e.key];
	const cps = [...e.key];
	if (cps.length === 1) {
		const cp = cps[0].codePointAt(0);
		return cp < 0x100 ? cp : 0x01000000 + cp;
	}
	return 0;
}

function unshiftedOf(e) {
	const c = e.code;
	if (c.startsWith("Key") && c.length === 4) return c.charCodeAt(3) + 0x20;
	if (c.startsWith("Digit") && c.length === 6) return c.charCodeAt(5);
	if (c in UNSHIFTED) return UNSHIFTED[c].charCodeAt(0);
	if (c in KEYPAD) return KEYPAD[c];
	if (e.key in KEYSYM) return KEYSYM[e.key];
	return 0;
}

function modsOf(e) {
	return (e.shiftKey ? 1 : 0) | (e.ctrlKey ? 2 : 0) | (e.altKey ? 4 : 0) | (e.metaKey ? 8 : 0) |
		(e.getModifierState && e.getModifierState("CapsLock") ? 16 : 0);
}

// ---------------------------------------------------------------------------
// The filesystem
// ---------------------------------------------------------------------------

const E = { SUCCESS: 0, ACCES: 2, BADF: 8, EXIST: 20, INVAL: 28, IO: 29, ISDIR: 31, NOENT: 44, NOSYS: 52, NOTDIR: 54, NOTEMPTY: 55, NOTSUP: 58 };
const FT = { CHAR: 2, DIR: 3, FILE: 4 };

class Vfs {
	constructor() {
		this.root = { dir: new Map(), ino: 1 };
		this.nextIno = 2;
	}
	split(path) {
		const out = [];
		for (const p of path.split("/")) {
			if (p === "" || p === ".") continue;
			if (p === "..") out.pop();
			else out.push(p);
		}
		return out;
	}
	lookup(parts) {
		let n = this.root;
		for (const p of parts) {
			if (!n.dir) return null;
			n = n.dir.get(p);
			if (!n) return null;
		}
		return n;
	}
	mkdirp(parts) {
		let n = this.root;
		for (const p of parts) {
			let c = n.dir.get(p);
			if (!c) {
				c = { dir: new Map(), ino: this.nextIno++ };
				n.dir.set(p, c);
			}
			n = c;
		}
		return n;
	}
	put(path, bytes) {
		const parts = this.split(path);
		const dir = this.mkdirp(parts.slice(0, -1));
		dir.dir.set(parts[parts.length - 1], { data: bytes, size: bytes.length, ino: this.nextIno++, mtime: BigInt(Date.now()) * 1000000n });
	}
	get(path) {
		const n = this.lookup(this.split(path));
		return n && n.data ? n.data.subarray(0, n.size) : null;
	}
}

// ---------------------------------------------------------------------------
// The runner
// ---------------------------------------------------------------------------

class Exit extends Error {
	constructor(code) {
		super("exit " + code);
		this.code = code;
	}
}

export async function run(opts) {
	const canvas = opts.canvas;
	const base = opts.base || "./";
	if (typeof WebAssembly.Suspending !== "function" || typeof WebAssembly.promising !== "function") {
		throw new Error("this browser has no JavaScript Promise Integration (WebAssembly.Suspending): use Chromium 137 or later");
	}

	const manifest = opts.manifest || await (await fetch(base + "manifest.json")).json();
	const vfs = new Vfs();
	await Promise.all((manifest.files || []).map(async (f) => {
		const r = await fetch(base + f.url);
		if (!r.ok) throw new Error(`could not fetch ${f.url}: ${r.status}`);
		vfs.put(f.path, new Uint8Array(await r.arrayBuffer()));
	}));
	vfs.mkdirp(vfs.split("/tmp"));
	vfs.mkdirp(vfs.split("/home/web"));

	const args = (opts.args || manifest.args || ["palmy"]).map(String);
	const envList = ["HOME=/home/web", "USER=web", "XDG_RUNTIME_DIR=/tmp", ...(manifest.env || []), ...(opts.env || [])];

	const stats = {
		started: performance.now(),
		frames: [],      // {n, ms, rects, px} for every present
		waits: 0,
		events: 0,
		log: [],         // PALMY_WEB_LOG lines
		stdout: "",
		stderr: "",
		exited: null,
		presents: 0,
		lastPresentAt: 0,
		idleSince: 0,
	};

	let memory = null;
	const u8 = () => new Uint8Array(memory.buffer);
	const dv = () => new DataView(memory.buffer);
	const dec = new TextDecoder();
	const enc = new TextEncoder();
	const str = (p, n) => dec.decode(new Uint8Array(memory.buffer, p, n));

	// --- canvas and input ---------------------------------------------------

	const ctx2d = canvas.getContext("2d", { alpha: false });
	let image = null; // full-size ImageData the frame is copied into
	let image32 = null;
	let logicalW = 0, logicalH = 0;
	const fixedSize = !opts.fill;

	const queue = [];
	let wake = null; // resolver of the parked wait
	let frameDone = false;
	let rafArmed = false;
	let busySince = performance.now();

	function poke() {
		if (wake) {
			const w = wake;
			wake = null;
			w();
		}
	}
	function push(kind, mods, a = 0, b = 0, c = 0, d = 0, x = 0, y = 0) {
		queue.push([kind, mods, a, b, c, d, x, y]);
		stats.events++;
		poke();
	}

	function pos(e) {
		const r = canvas.getBoundingClientRect();
		return [e.clientX - r.left, e.clientY - r.top];
	}

	function currentScale() {
		return Math.max(1, Math.round(opts.scale || window.devicePixelRatio || 1));
	}
	function viewSize() {
		if (fixedSize) return [logicalW, logicalH];
		const host = canvas.parentElement || document.body;
		return [Math.max(1, Math.floor(host.clientWidth)), Math.max(1, Math.floor(host.clientHeight))];
	}

	// Keyboard input goes to a transparent textarea that holds the focus while
	// the canvas is in use, not to the canvas itself: a canvas never receives
	// composed text (IME, dead keys on some platforms, the emoji picker,
	// insertText from automation), and a textarea does.
	const ta = document.createElement("textarea");
	for (const [k, v] of Object.entries({ autocapitalize: "off", autocomplete: "off", autocorrect: "off", spellcheck: "false", "aria-label": "palmy keyboard input" })) ta.setAttribute(k, v);
	Object.assign(ta.style, { position: "fixed", left: "0", top: "0", width: "1px", height: "1px", opacity: "0", border: "0", padding: "0", resize: "none", pointerEvents: "none" });
	document.body.appendChild(ta);
	const focusInput = () => ta.focus({ preventScroll: true });

	canvas.style.outline = "none";
	canvas.style.touchAction = "none";
	canvas.addEventListener("pointermove", (e) => {
		const [x, y] = pos(e);
		push(1, modsOf(e), 0, 0, 0, 0, x, y);
	});
	canvas.addEventListener("pointerenter", (e) => {
		const [x, y] = pos(e);
		push(10, modsOf(e), 0, 0, 0, 0, x, y);
	});
	canvas.addEventListener("pointerleave", (e) => {
		if (canvas.hasPointerCapture && canvas.hasPointerCapture(e.pointerId)) return;
		push(8, modsOf(e));
	});
	canvas.addEventListener("pointerdown", (e) => {
		focusInput();
		canvas.setPointerCapture(e.pointerId);
		const [x, y] = pos(e);
		push(1, modsOf(e), 0, 0, 0, 0, x, y);
		push(2, modsOf(e), e.button === 2 ? 1 : e.button === 1 ? 2 : 0, 1);
		e.preventDefault();
	});
	canvas.addEventListener("pointerup", (e) => {
		const [x, y] = pos(e);
		push(1, modsOf(e), 0, 0, 0, 0, x, y);
		push(2, modsOf(e), e.button === 2 ? 1 : e.button === 1 ? 2 : 0, 0);
	});
	canvas.addEventListener("contextmenu", (e) => e.preventDefault());
	canvas.addEventListener("wheel", (e) => {
		// One wheel notch is SCROLL_NOTCH (10) in palmy's units, which is what
		// X11 delivers per button press and Wayland's axis value per detent.
		// Chromium reports a notch as 100 pixels, Firefox as 3 lines.
		let k = 0.1;
		if (e.deltaMode === 1) k = 10 / 3;
		else if (e.deltaMode === 2) k = 100;
		push(3, modsOf(e), 0, 0, 0, 0, e.deltaX * k, e.deltaY * k);
		e.preventDefault();
	}, { passive: false });

	const PASS = new Set(["F5", "F11", "F12"]);
	const pushText = (str, m) => {
		for (const ch of str) {
			const cp = ch.codePointAt(0);
			if (cp >= 0x20 && cp !== 0x7f) push(5, m, cp);
		}
	};
	ta.addEventListener("keydown", (e) => {
		if (e.isComposing || e.key === "Process") return; // the IME has it
		if (PASS.has(e.key) || (e.ctrlKey && e.shiftKey && (e.key === "I" || e.key === "J"))) return;
		const m = modsOf(e);
		const sym = keysymOf(e);
		if (sym !== 0 && !(sym >= 0xffe1 && sym <= 0xffee) && sym !== 0xfe03 && sym !== 0xffe5) {
			push(4, m, sym, unshiftedOf(e), e.repeat ? 1 : 0);
		} else {
			push(9, m);
		}
		// Text: what the key typed, unless Ctrl or Super is held -- the rule
		// palmy's Wayland and X11 paths apply to xkb's output.
		if (e.key === "Dead" || e.key === "Unidentified") return; // arrives as input
		if (!e.ctrlKey && !e.metaKey && e.key.length > 0 && !(e.key in KEYSYM)) pushText(e.key, m);
		e.preventDefault();
	});
	ta.addEventListener("keyup", (e) => push(9, modsOf(e)));
	// Text that arrives without a key that typed it: a dead-key sequence, an
	// emoji picker, insertText. Composition is taken whole at its end.
	ta.addEventListener("input", (e) => {
		if (!e.isComposing && e.inputType !== "insertCompositionText" && e.data) pushText(e.data, 0);
		if (!e.isComposing) ta.value = "";
	});
	ta.addEventListener("compositionend", (e) => {
		if (e.data) pushText(e.data, 0);
		ta.value = "";
	});
	ta.addEventListener("focus", () => push(7, 0, 1));
	ta.addEventListener("blur", () => push(7, 0, 0));

	function reportSize() {
		const [w, h] = viewSize();
		push(6, 0, w, h, currentScale());
	}
	if (!fixedSize) {
		new ResizeObserver(reportSize).observe(canvas.parentElement || document.body);
	}
	window.addEventListener("resize", reportSize);

	function onFrame() {
		rafArmed = false;
		frameDone = true;
		poke();
	}

	// --- clipboard ----------------------------------------------------------

	let clipPending = null;

	// --- imports ------------------------------------------------------------

	const web = {
		palmy_web_open(w, h, tp, tn, out) {
			logicalW = w;
			logicalH = h;
			document.title = str(tp, tn);
			const [vw, vh] = viewSize();
			const d = dv();
			d.setInt32(out, vw, true);
			d.setInt32(out + 4, vh, true);
			d.setInt32(out + 8, currentScale(), true);
			return 1;
		},
		palmy_web_buffer(dw, dh, lw, lh) {
			canvas.width = dw;
			canvas.height = dh;
			canvas.style.width = lw + "px";
			canvas.style.height = lh + "px";
			image = ctx2d.createImageData(dw, dh);
			image32 = new Uint32Array(image.data.buffer);
		},
		palmy_web_present(px, bw, bh, rp, nr, frame) {
			const t0 = performance.now();
			const src = new Uint32Array(memory.buffer, px, bw * bh);
			const d = dv();
			let area = 0;
			for (let i = 0; i < nr; i++) {
				const o = rp + i * 16;
				const rx = d.getInt32(o, true), ry = d.getInt32(o + 4, true);
				const rw = d.getInt32(o + 8, true), rh = d.getInt32(o + 12, true);
				for (let y = ry; y < ry + rh; y++) {
					let k = y * bw + rx;
					const end = k + rw;
					for (; k < end; k++) {
						const v = src[k];
						// 0xAARRGGBB words, read little-endian as B,G,R,A bytes,
						// become R,G,B,255.
						image32[k] = 0xff000000 | (v & 0x00ff00) | ((v >>> 16) & 0xff) | ((v & 0xff) << 16);
					}
				}
				ctx2d.putImageData(image, 0, 0, rx, ry, rw, rh);
				area += rw * rh;
			}
			stats.presents++;
			const now = performance.now();
			// ms: the program's whole frame, from the wait that ended to the pixels
			// being on the canvas; put: the copy and putImageData alone.
			stats.frames.push({ n: frame, ms: now - busySince, put: now - t0, rects: nr, px: area, at: now });
			stats.lastPresentAt = now;
			if (!rafArmed) {
				rafArmed = true;
				requestAnimationFrame(onFrame);
			}
		},
		palmy_web_wait: new WebAssembly.Suspending((timeout) => {
			stats.waits++;
			if (queue.length > 0 || frameDone || timeout === 0) {
				// Nothing to wait for: return without suspending.
				busySince = performance.now();
				return 0;
			}
			stats.idleSince = performance.now();
			return new Promise((resolve) => {
				let timer = 0;
				wake = () => {
					clearTimeout(timer);
					busySince = performance.now();
					resolve(0);
				};
				if (timeout > 0) timer = setTimeout(poke, timeout);
			});
		}),
		palmy_web_take_frame_done() {
			const f = frameDone;
			frameDone = false;
			return f ? 1 : 0;
		},
		palmy_web_next_event(p) {
			const ev = queue.shift();
			if (!ev) return 0;
			const d = dv();
			for (let i = 0; i < 6; i++) d.setInt32(p + i * 4, ev[i] | 0, true);
			d.setFloat32(p + 24, ev[6], true);
			d.setFloat32(p + 28, ev[7], true);
			return 1;
		},
		palmy_web_set_title(p, n) {
			document.title = str(p, n);
		},
		palmy_web_set_cursor(shape) {
			canvas.style.cursor = CURSORS[shape] || "default";
		},
		palmy_web_set_fullscreen(on) {
			if (on && !document.fullscreenElement) canvas.requestFullscreen?.().catch(() => {});
			if (!on && document.fullscreenElement) document.exitFullscreen?.().catch(() => {});
		},
		palmy_web_log(p, n) {
			stats.log.push(str(p, n));
		},
		palmy_web_clip_write: new WebAssembly.Suspending(async (kind, p, n) => {
			const text = str(p, n);
			try {
				await navigator.clipboard.writeText(text);
				return 1;
			} catch (e) {
				return 0;
			}
		}),
		palmy_web_clip_read: new WebAssembly.Suspending(async (kind) => {
			try {
				const t = await navigator.clipboard.readText();
				clipPending = enc.encode(t);
				return clipPending.length;
			} catch (e) {
				clipPending = null;
				return -1;
			}
		}),
		palmy_web_clip_take(p, n) {
			if (clipPending) u8().set(clipPending.subarray(0, n), p);
			clipPending = null;
		},
	};

	// --- WASI ---------------------------------------------------------------

	const fds = new Map();
	fds.set(0, { kind: "stdin" });
	fds.set(1, { kind: "out", name: "stdout" });
	fds.set(2, { kind: "out", name: "stderr" });
	fds.set(3, { kind: "dir", node: vfs.root, path: [], preopen: "/" });
	let nextFd = 4;

	function resolve(dirfd, p, n) {
		const f = fds.get(dirfd);
		if (!f || f.kind !== "dir") return null;
		const rel = str(p, n);
		return rel.startsWith("/") ? vfs.split(rel) : vfs.split([...f.path, rel].join("/"));
	}
	function iovs(ptr, n) {
		const d = dv();
		const out = [];
		for (let i = 0; i < n; i++) out.push([d.getUint32(ptr + i * 8, true), d.getUint32(ptr + i * 8 + 4, true)]);
		return out;
	}
	function writeStat(ptr, node, isChar) {
		const d = dv();
		for (let i = 0; i < 64; i += 4) d.setUint32(ptr + i, 0, true);
		d.setBigUint64(ptr + 8, BigInt(node ? node.ino : 0), true);
		d.setUint8(ptr + 16, isChar ? FT.CHAR : node.dir ? FT.DIR : FT.FILE);
		d.setBigUint64(ptr + 24, 1n, true);
		d.setBigUint64(ptr + 32, BigInt(node && node.data ? node.size : 0), true);
		const t = node && node.mtime ? node.mtime : 0n;
		d.setBigUint64(ptr + 40, t, true);
		d.setBigUint64(ptr + 48, t, true);
		d.setBigUint64(ptr + 56, t, true);
	}
	function growTo(node, size) {
		if (node.data.length < size) {
			const nd = new Uint8Array(Math.max(size, node.data.length * 2, 64));
			nd.set(node.data.subarray(0, node.size));
			node.data = nd;
		}
		if (size > node.size) node.size = size;
	}
	function fileWrite(f, at, chunks) {
		let total = 0;
		const m = u8();
		for (const [p, n] of chunks) {
			growTo(f.node, at + total + n);
			f.node.data.set(m.subarray(p, p + n), at + total);
			total += n;
		}
		f.node.mtime = BigInt(Date.now()) * 1000000n;
		return total;
	}
	function fileRead(f, at, chunks) {
		let total = 0;
		const m = u8();
		for (const [p, n] of chunks) {
			const avail = Math.max(0, f.node.size - (at + total));
			const k = Math.min(n, avail);
			if (k > 0) m.set(f.node.data.subarray(at + total, at + total + k), p);
			total += k;
			if (k < n) break;
		}
		return total;
	}

	const wasi = {
		args_sizes_get(cp, sp) {
			const d = dv();
			d.setUint32(cp, args.length, true);
			d.setUint32(sp, args.reduce((s, a) => s + enc.encode(a).length + 1, 0), true);
			return 0;
		},
		args_get(argv, buf) {
			const d = dv(), m = u8();
			for (const a of args) {
				d.setUint32(argv, buf, true);
				argv += 4;
				const b = enc.encode(a);
				m.set(b, buf);
				m[buf + b.length] = 0;
				buf += b.length + 1;
			}
			return 0;
		},
		environ_sizes_get(cp, sp) {
			const d = dv();
			d.setUint32(cp, envList.length, true);
			d.setUint32(sp, envList.reduce((s, a) => s + enc.encode(a).length + 1, 0), true);
			return 0;
		},
		environ_get(envp, buf) {
			const d = dv(), m = u8();
			for (const a of envList) {
				d.setUint32(envp, buf, true);
				envp += 4;
				const b = enc.encode(a);
				m.set(b, buf);
				m[buf + b.length] = 0;
				buf += b.length + 1;
			}
			return 0;
		},
		clock_res_get(id, p) {
			dv().setBigUint64(p, 1000n, true);
			return 0;
		},
		clock_time_get(id, precision, p) {
			let ns;
			if (id === 0) ns = BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));
			else ns = BigInt(Math.round(performance.now() * 1e6));
			dv().setBigUint64(p, ns, true);
			return 0;
		},
		random_get(p, n) {
			const m = u8();
			for (let off = 0; off < n; off += 65536) {
				crypto.getRandomValues(m.subarray(p + off, p + Math.min(n, off + 65536)));
			}
			return 0;
		},
		proc_exit(code) {
			throw new Exit(code);
		},
		sched_yield() {
			return 0;
		},
		fd_write(fd, ip, n, outp) {
			const f = fds.get(fd);
			if (!f) return E.BADF;
			const chunks = iovs(ip, n);
			let total = 0;
			if (f.kind === "out") {
				for (const [p, k] of chunks) {
					const s = str(p, k);
					stats[f.name] += s;
					total += k;
				}
				flushConsole(f.name);
			} else if (f.kind === "file") {
				const at = f.append ? f.node.size : f.pos;
				total = fileWrite(f, at, chunks);
				f.pos = at + total;
			} else return E.BADF;
			dv().setUint32(outp, total, true);
			return 0;
		},
		fd_pwrite(fd, ip, n, off, outp) {
			const f = fds.get(fd);
			if (!f || f.kind !== "file") return E.BADF;
			dv().setUint32(outp, fileWrite(f, Number(off), iovs(ip, n)), true);
			return 0;
		},
		fd_read(fd, ip, n, outp) {
			const f = fds.get(fd);
			if (!f) return E.BADF;
			if (f.kind === "stdin") {
				dv().setUint32(outp, 0, true);
				return 0;
			}
			if (f.kind !== "file") return E.BADF;
			const k = fileRead(f, f.pos, iovs(ip, n));
			f.pos += k;
			dv().setUint32(outp, k, true);
			return 0;
		},
		fd_pread(fd, ip, n, off, outp) {
			const f = fds.get(fd);
			if (!f || f.kind !== "file") return E.BADF;
			dv().setUint32(outp, fileRead(f, Number(off), iovs(ip, n)), true);
			return 0;
		},
		fd_seek(fd, off, whence, outp) {
			const f = fds.get(fd);
			if (!f || f.kind !== "file") return E.BADF;
			let p = Number(off);
			if (whence === 1) p += f.pos;
			else if (whence === 2) p += f.node.size;
			if (p < 0) return E.INVAL;
			f.pos = p;
			dv().setBigUint64(outp, BigInt(p), true);
			return 0;
		},
		fd_tell(fd, outp) {
			const f = fds.get(fd);
			if (!f || f.kind !== "file") return E.BADF;
			dv().setBigUint64(outp, BigInt(f.pos), true);
			return 0;
		},
		fd_close(fd) {
			if (!fds.has(fd) || fd < 4) return fd < 4 ? 0 : E.BADF;
			fds.delete(fd);
			return 0;
		},
		fd_sync() { return 0; },
		fd_datasync() { return 0; },
		fd_advise() { return 0; },
		fd_allocate() { return 0; },
		fd_fdstat_set_flags() { return 0; },
		fd_filestat_set_times() { return 0; },
		path_filestat_set_times() { return 0; },
		fd_fdstat_get(fd, p) {
			const f = fds.get(fd);
			if (!f) return E.BADF;
			const d = dv();
			d.setUint8(p, f.kind === "dir" ? FT.DIR : f.kind === "file" ? FT.FILE : FT.CHAR);
			d.setUint16(p + 2, 0, true);
			d.setBigUint64(p + 8, 0xffffffffffffffffn, true);
			d.setBigUint64(p + 16, 0xffffffffffffffffn, true);
			return 0;
		},
		fd_filestat_get(fd, p) {
			const f = fds.get(fd);
			if (!f) return E.BADF;
			writeStat(p, f.node, f.kind !== "file" && f.kind !== "dir");
			return 0;
		},
		fd_filestat_set_size(fd, size) {
			const f = fds.get(fd);
			if (!f || f.kind !== "file") return E.BADF;
			const s = Number(size);
			growTo(f.node, s);
			f.node.size = s;
			return 0;
		},
		fd_prestat_get(fd, p) {
			const f = fds.get(fd);
			if (!f || !f.preopen) return E.BADF;
			const d = dv();
			d.setUint8(p, 0);
			d.setUint32(p + 4, enc.encode(f.preopen).length, true);
			return 0;
		},
		fd_prestat_dir_name(fd, p, n) {
			const f = fds.get(fd);
			if (!f || !f.preopen) return E.BADF;
			u8().set(enc.encode(f.preopen).subarray(0, n), p);
			return 0;
		},
		fd_readdir(fd, buf, len, cookie, outp) {
			const f = fds.get(fd);
			if (!f || f.kind !== "dir") return E.BADF;
			const names = [".", "..", ...[...f.node.dir.keys()].sort()];
			const d = dv(), m = u8();
			let used = 0;
			for (let i = Number(cookie); i < names.length; i++) {
				const name = enc.encode(names[i]);
				const child = i < 2 ? f.node : f.node.dir.get(names[i]);
				const ent = new Uint8Array(24 + name.length);
				const ed = new DataView(ent.buffer);
				ed.setBigUint64(0, BigInt(i + 1), true);
				ed.setBigUint64(8, BigInt(child.ino), true);
				ed.setUint32(16, name.length, true);
				ed.setUint8(20, child.dir ? FT.DIR : FT.FILE);
				ent.set(name, 24);
				const k = Math.min(ent.length, len - used);
				m.set(ent.subarray(0, k), buf + used);
				used += k;
				if (used >= len) break;
			}
			d.setUint32(outp, used, true);
			return 0;
		},
		path_open(dirfd, dirflags, p, n, oflags, rights, rightsInh, fdflags, outp) {
			const parts = resolve(dirfd, p, n);
			if (!parts) return E.BADF;
			let node = vfs.lookup(parts);
			if (node && (oflags & 4)) return E.EXIST;
			if (!node) {
				if (!(oflags & 1)) return E.NOENT;
				const dir = vfs.lookup(parts.slice(0, -1));
				if (!dir || !dir.dir) return E.NOENT;
				node = { data: new Uint8Array(0), size: 0, ino: vfs.nextIno++, mtime: BigInt(Date.now()) * 1000000n };
				dir.dir.set(parts[parts.length - 1], node);
			}
			if ((oflags & 2) && !node.dir) return E.NOTDIR;
			const fd = nextFd++;
			if (node.dir) {
				fds.set(fd, { kind: "dir", node, path: parts });
			} else {
				if (oflags & 8) node.size = 0;
				fds.set(fd, { kind: "file", node, pos: 0, append: !!(fdflags & 1) });
			}
			dv().setUint32(outp, fd, true);
			return 0;
		},
		path_filestat_get(dirfd, flags, p, n, outp) {
			const parts = resolve(dirfd, p, n);
			if (!parts) return E.BADF;
			const node = vfs.lookup(parts);
			if (!node) return E.NOENT;
			writeStat(outp, node, false);
			return 0;
		},
		path_create_directory(dirfd, p, n) {
			const parts = resolve(dirfd, p, n);
			if (!parts) return E.BADF;
			if (vfs.lookup(parts)) return E.EXIST;
			const dir = vfs.lookup(parts.slice(0, -1));
			if (!dir || !dir.dir) return E.NOENT;
			vfs.mkdirp(parts);
			return 0;
		},
		path_unlink_file(dirfd, p, n) {
			const parts = resolve(dirfd, p, n);
			if (!parts) return E.BADF;
			const dir = vfs.lookup(parts.slice(0, -1));
			const node = dir && dir.dir && dir.dir.get(parts[parts.length - 1]);
			if (!node) return E.NOENT;
			if (node.dir) return E.ISDIR;
			dir.dir.delete(parts[parts.length - 1]);
			return 0;
		},
		path_remove_directory(dirfd, p, n) {
			const parts = resolve(dirfd, p, n);
			if (!parts) return E.BADF;
			const dir = vfs.lookup(parts.slice(0, -1));
			const node = dir && dir.dir && dir.dir.get(parts[parts.length - 1]);
			if (!node) return E.NOENT;
			if (!node.dir) return E.NOTDIR;
			if (node.dir.size > 0) return E.NOTEMPTY;
			dir.dir.delete(parts[parts.length - 1]);
			return 0;
		},
		path_rename(fd1, p1, n1, fd2, p2, n2) {
			const a = resolve(fd1, p1, n1), b = resolve(fd2, p2, n2);
			if (!a || !b) return E.BADF;
			const da = vfs.lookup(a.slice(0, -1)), db = vfs.lookup(b.slice(0, -1));
			const node = da && da.dir && da.dir.get(a[a.length - 1]);
			if (!node) return E.NOENT;
			if (!db || !db.dir) return E.NOENT;
			da.dir.delete(a[a.length - 1]);
			db.dir.set(b[b.length - 1], node);
			return 0;
		},
		path_readlink() { return E.INVAL; },
		path_symlink() { return E.NOTSUP; },
		path_link() { return E.NOTSUP; },
		fd_renumber(from, to) {
			const f = fds.get(from);
			if (!f) return E.BADF;
			fds.set(to, f);
			fds.delete(from);
			return 0;
		},
		// time.sleep: clock subscriptions only, served by a suspending timer.
		poll_oneoff: new WebAssembly.Suspending(async (inp, outp, n, neventsp) => {
			const d = dv();
			let wait = 0;
			for (let i = 0; i < n; i++) {
				const s = inp + i * 48;
				if (d.getUint8(s + 8) === 0) {
					let t = Number(d.getBigUint64(s + 24, true)) / 1e6;
					if (d.getUint16(s + 40, true) & 1) t -= performance.now();
					wait = Math.max(wait, t);
				}
			}
			if (wait > 0) await new Promise((r) => setTimeout(r, wait));
			const d2 = dv();
			for (let i = 0; i < n; i++) {
				const s = inp + i * 48, e = outp + i * 32;
				d2.setBigUint64(e, d2.getBigUint64(s, true), true);
				d2.setUint16(e + 8, 0, true);
				d2.setUint8(e + 10, d2.getUint8(s + 8));
			}
			d2.setUint32(neventsp, n, true);
			return 0;
		}),
	};

	const pending = { stdout: "", stderr: "" };
	function flushConsole(name) {
		const s = stats[name];
		const nl = s.lastIndexOf("\n");
		if (nl < 0) return;
		const chunk = s.slice(pending[name].length, nl + 1);
		pending[name] = s.slice(0, nl + 1);
		for (const line of chunk.split("\n").slice(0, -1)) {
			(name === "stderr" ? console.warn : console.log)(line);
			if (opts.onLine) opts.onLine(name, line);
		}
	}

	// Single-precision maths the C objects (stb) import from the environment.
	const env = {
		expf: (x) => Math.fround(Math.exp(x)),
		logf: (x) => Math.fround(Math.log(x)),
		powf: (x, y) => Math.fround(Math.pow(x, y)),
		sinf: (x) => Math.fround(Math.sin(x)),
		cosf: (x) => Math.fround(Math.cos(x)),
		exp: Math.exp, log: Math.log, pow: Math.pow, sin: Math.sin, cos: Math.cos,
		fmodf: (x, y) => Math.fround(x % y), fmod: (x, y) => x % y,
		acosf: (x) => Math.fround(Math.acos(x)), acos: Math.acos,
		atan2f: (y, x) => Math.fround(Math.atan2(y, x)), atan2: Math.atan2,
	};

	const wasmUrl = base + (opts.wasm || "app.wasm");
	const module = await WebAssembly.compileStreaming(fetch(wasmUrl));
	const palmy_libm = {
		palmy_libm_sin: Math.sin, palmy_libm_cos: Math.cos, palmy_libm_pow: Math.pow, palmy_libm_exp: Math.exp,
	};
	const imports = { wasi_snapshot_preview1: wasi, palmy_web: web, palmy_libm, env };
	// Anything the program imports that is not provided fails loudly when
	// called, not at instantiation, so a build that links a WASI call this
	// page does not serve still starts.
	for (const imp of WebAssembly.Module.imports(module)) {
		const ns = (imports[imp.module] ||= {});
		if (imp.kind === "function" && !(imp.name in ns)) {
			ns[imp.name] = () => {
				console.warn(`palmy-web: ${imp.module}.${imp.name} is not implemented`);
				return E.NOSYS;
			};
		}
	}
	const instance = await WebAssembly.instantiate(module, imports);
	memory = instance.exports.memory;

	const start = WebAssembly.promising(instance.exports._start);
	const done = start().then(
		() => (stats.exited = 0),
		(e) => {
			if (e instanceof Exit) return (stats.exited = e.code);
			stats.exited = "trap: " + e.message;
			console.error(e);
			throw e;
		},
	);
	focusInput();
	// parked: the program is waiting with nothing queued and no frame
	// callback outstanding -- it has drawn everything it is going to.
	const state = () => ({ parked: wake !== null, queued: queue.length, frameArmed: rafArmed, presents: stats.presents });
	return { stats, done, vfs, push, state };
}
