// Throwaway stand-in for the real web app while it is being built.
// Serves /parity/cases.json and /iso/<id> from the static files next to it.
import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 5174);

const CASES = [
  { id: 'selftest-basic', component: 'selftest', title: 'Basic card', file: 'basic.html' },
  { id: 'selftest-deep', component: 'selftest', title: 'Deep nesting', file: 'deep.html' },
  { id: 'selftest-missing', component: 'selftest', title: 'Deliberately broken', file: 'nope.html' },
];

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  if (url.pathname === '/parity/cases.json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(CASES.map(({ id, component, title }) => ({ id, component, title }))));
    return;
  }
  const m = url.pathname.match(/^\/iso\/(.+)$/);
  if (m) {
    const c = CASES.find((x) => x.id === decodeURIComponent(m[1]));
    if (c) {
      try {
        const html = await fs.readFile(path.join(HERE, c.file), 'utf8');
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        res.end(html);
        return;
      } catch {
        res.writeHead(500); res.end('missing file'); return;
      }
    }
  }
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

server.listen(PORT, () => console.log(`selftest server on http://localhost:${PORT}`));
