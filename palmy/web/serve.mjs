// serve.mjs: a static server for a web-build.sh output directory.
//
//   node palmy/web/serve.mjs <dir> [port] [host]
//
// Any static server works if it sends .wasm as application/wasm (which
// WebAssembly.compileStreaming insists on). This one also sends the two
// cross-origin isolation headers, harmless today and what a threaded build
// (SharedArrayBuffer) would need.
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { extname, join, normalize, resolve } from "node:path";

const root = resolve(process.argv[2] || ".");
const port = Number(process.argv[3] || 8790);
const host = process.argv[4] || "127.0.0.1";
const TYPES = {
	".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".mjs": "text/javascript; charset=utf-8",
	".json": "application/json", ".wasm": "application/wasm", ".ttf": "font/ttf", ".otf": "font/otf",
	".png": "image/png", ".css": "text/css",
};

createServer(async (req, res) => {
	const url = new URL(req.url, "http://x");
	let path = normalize(decodeURIComponent(url.pathname)).replace(/^(\.\.[/\\])+/, "");
	let file = join(root, path);
	if (!file.startsWith(root)) return res.writeHead(403).end();
	try {
		if ((await stat(file)).isDirectory()) file = join(file, "index.html");
		const body = await readFile(file);
		res.writeHead(200, {
			"content-type": TYPES[extname(file)] || "application/octet-stream",
			"cross-origin-opener-policy": "same-origin",
			"cross-origin-embedder-policy": "require-corp",
			"cache-control": "no-store",
		});
		res.end(body);
	} catch {
		res.writeHead(404).end("not found");
	}
}).listen(port, host, () => console.log(`serving ${root} on http://${host}:${port}/`));
