// The Gecko engine host: `browser --gecko-host`, a separate process the
// window starts the way it starts palm-browser-cef.
//
// There is no maintained way to embed Gecko in a desktop application:
// GeckoView is Android-only, EmbedLite lives in Sailfish's fork, and XULRunner
// is long gone. So this host does not embed Gecko. It runs Firefox itself --
// the unmodified, Mozilla-built browser -- with two seams:
//
//   pixels and input  Firefox is a Wayland client of a compositor that lives
//                     in this process (server.odin, compose.odin, seat.odin).
//                     Its window is the view; what it draws reaches the chrome
//                     through the same shared buffer and FRAME messages the CEF
//                     host uses, and the chrome's input reaches Firefox as a
//                     real seat.
//   navigation        WebDriver BiDi, Firefox's standard remote protocol
//                     (bidi.odin): navigate, history, reload, tabs, load
//                     events, downloads, and a preload script that reports
//                     titles, favicons, hovered links, selections and context
//                     menus back to the chrome.
//
// Firefox runs in kiosk mode, so none of its own chrome is drawn: tabs,
// address bar and menus are the Palmframe chrome's. Each chrome tab is a
// Firefox tab (a BiDi browsing context); the one showing is the one
// activated, and it is what the compositor's one window shows.
package gecko

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:time"
import pb "../../pb"

View :: struct {
	id:       int,
	ctx:      string,
	pending:  string, // a URL to load once the context exists
	loading:  bool,
	hist:     [dynamic]string,
	idx:      int,
	travel:   int, // a history step in flight
	zoom:     f32,
	dl_ids:   [dynamic]string,
}

Pending_Kind :: enum {
	None,
	Session_New,
	Subscribe,
	Preload,
	Get_Tree,
	Create,
	Has_Focus,
	Fill_Tree,
	Fill_Call,
	Other,
}

Host :: struct {
	chrome:      pb.Conn,
	crx:         [dynamic]u8,
	wl_listen:   linux.Fd,
	wl_path:     string,
	firefox:     os.Process,
	ff_started:  bool,
	ff_bin:      string,
	ff_version:  string,
	profile:     string,
	downloads:   string,
	port:        int,
	ws:          Ws,
	ready:       bool,
	next_cmd:    int,
	pending:     map[int]struct {
		kind: Pending_Kind,
		view: int,
	},
	views:       map[int]^View,
	initial_ctx: string,
	foreign_ctx: map[string]bool, // contexts Firefox opened by itself (target=_blank)
	dark:        int,
	quitting:    bool,
	started_at:  time.Tick,
	next_dl:     u32,
	dl_ctx:      map[string]u32, // download navigation id -> our id
	clients:     [dynamic]^Client,
	test_certs:  bool,
	fill:        Fill_Pending,
}

// One fill at a time: the chrome sends FILL only after the person picked a
// login, and the host first asks Firefox where the view is now.
Fill_Pending :: struct {
	active:   bool,
	view:     int,
	origin:   string,
	username: string,
	password: string,
	otp:      string,
}

fill_clear :: proc(f: ^Fill_Pending) {
	for s in ([]string{f.username, f.password, f.otp}) {
		pb.wipe(transmute([]u8)s)
		delete(s)
	}
	delete(f.origin)
	f^ = {}
}

h: Host
TRACE: bool

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}

send_ev :: proc(m: pb.Msg) {
	m := m
	pb.send(&h.chrome, &m)
}

// ---------------------------------------------------------------------------
// Firefox
// ---------------------------------------------------------------------------

firefox_version :: proc(bin: string) -> string {
	dir := bin[:max(strings.last_index_byte(bin, '/'), 0)]
	data, err := os.read_entire_file(fmt.tprintf("%s/application.ini", dir), context.temp_allocator)
	if err == nil {
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if strings.has_prefix(line, "Version=") {
				return strings.clone(line[8:])
			}
		}
	}
	return "unknown"
}

USER_JS :: `// written by palm-browser-gecko on every start
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.aboutwelcome.enabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.reportingpolicy.firstRun", false);
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.tabs.inTitlebar", 0);
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.closeWindowWithLastTab", false);
user_pref("gfx.webrender.software", true);
user_pref("widget.wayland.fractional-scale.enabled", false);
user_pref("ui.key.menuAccessKeyFocuses", false);
user_pref("full-screen-api.warning.timeout", 0);
user_pref("browser.download.useDownloadDir", true);
user_pref("browser.download.folderList", 2);
user_pref("browser.download.always_ask_before_handling_new_types", false);
user_pref("browser.download.alwaysOpenPanel", false);
user_pref("browser.download.panel.shown", true);
user_pref("remote.active-protocols", 1);
user_pref("remote.prefs.recommended", false);
user_pref("app.update.auto", false);
user_pref("app.update.checkInstallTime", false);
user_pref("browser.translations.automaticallyPopup", false);
user_pref("extensions.pocket.enabled", false);
// Passwords live in the vault and nowhere else (cloud/docs/vault.md): no
// saving, no filling, no generation, no breach alerts from Firefox's own
// password manager; no form history (it keeps what was typed into text
// fields, usernames included), no address or card autofill; and no form
// contents in the session store.
user_pref("signon.rememberSignons", false);
user_pref("signon.autofillForms", false);
user_pref("signon.generation.enabled", false);
user_pref("signon.management.page.breach-alerts.enabled", false);
user_pref("signon.firefoxRelay.feature", "disabled");
user_pref("browser.formfill.enable", false);
user_pref("extensions.formautofill.addresses.enabled", false);
user_pref("extensions.formautofill.creditCards.enabled", false);
user_pref("browser.sessionstore.privacy_level", 2);
// the address bar is hidden in kiosk mode; it must never pop up suggestions
user_pref("browser.urlbar.suggest.searches", false);
user_pref("browser.urlbar.suggest.history", false);
user_pref("browser.urlbar.suggest.bookmark", false);
user_pref("browser.urlbar.suggest.openpage", false);
user_pref("browser.urlbar.suggest.topsites", false);
user_pref("browser.urlbar.suggest.engines", false);
user_pref("browser.urlbar.maxRichResults", 0);
user_pref("browser.search.suggest.enabled", false);
// Firefox's first-run Terms of Use modal would sit over the first page with
// no way to reach it from the chrome's keyboard flow; Mozilla's own switch
// for managed and automated installs turns it off. The settings page links
// Mozilla's terms instead, beside the engine choice.
user_pref("termsofuse.bypassNotification", true);
user_pref("browser.preonboarding.splashShown", true);
user_pref("browser.aboutwelcome.experimentsGate.enabled", false);
`

start_firefox :: proc() -> bool {
	if h.ff_started {
		return true
	}
	h.ff_started = true
	dir := fmt.tprintf("%s/gecko", h.profile)
	os.make_directory_all(dir, os.perm(0o700))
	prefs := strings.builder_make(context.temp_allocator)
	strings.write_string(&prefs, USER_JS)
	fmt.sbprintf(&prefs, "user_pref(\"browser.download.dir\", %s);\n", jq(h.downloads))
	if h.dark >= 0 {
		// 0 dark, 1 light: what prefers-color-scheme answers in pages
		fmt.sbprintf(&prefs, "user_pref(\"layout.css.prefers-color-scheme.content-override\", %d);\n", h.dark == 1 ? 0 : 1)
	}
	_ = os.write_entire_file(fmt.tprintf("%s/user.js", dir), transmute([]u8)strings.to_string(prefs))

	h.port = free_port()
	env := make([dynamic]string, context.temp_allocator)
	environ, _ := os.environ(context.temp_allocator)
	for e in environ {
		switch {
		case strings.has_prefix(e, "WAYLAND_DISPLAY="), strings.has_prefix(e, "DISPLAY="), strings.has_prefix(e, "WAYLAND_SOCKET="),
		     strings.has_prefix(e, "DBUS_SESSION_BUS_ADDRESS="), strings.has_prefix(e, "GDK_BACKEND="),
		     strings.has_prefix(e, "MOZ_"), strings.has_prefix(e, "LD_LIBRARY_PATH="):
			continue
		}
		append(&env, e)
	}
	append(&env, fmt.tprintf("WAYLAND_DISPLAY=%s", h.wl_path))
	// the firefox package carries the system libraries Palmframe does not
	// ship in syslib/, and a fontconfig file for a system without /etc/fonts
	ffdir := h.ff_bin[:max(strings.last_index_byte(h.ff_bin, '/'), 0)]
	if os.exists(fmt.tprintf("%s/syslib", ffdir)) {
		prev := os.get_env("LD_LIBRARY_PATH", context.temp_allocator)
		append(&env, fmt.tprintf("LD_LIBRARY_PATH=%s/syslib%s%s", ffdir, prev != "" ? ":" : "", prev))
	}
	if !os.exists("/etc/fonts/fonts.conf") && os.exists(fmt.tprintf("%s/fonts.conf", ffdir)) && os.get_env("FONTCONFIG_FILE", context.temp_allocator) == "" {
		append(&env, fmt.tprintf("FONTCONFIG_FILE=%s/fonts.conf", ffdir))
	}
	append(&env, "GDK_BACKEND=wayland")
	append(&env, "MOZ_ENABLE_WAYLAND=1")
	append(&env, "MOZ_CRASHREPORTER_DISABLE=1")
	append(&env, "MOZ_DBUS_REMOTE=0")
	append(&env, "GTK_USE_PORTAL=0")
	args := []string {
		h.ff_bin,
		"--kiosk",
		"--no-remote",
		"--new-instance",
		"--profile",
		dir,
		"--remote-debugging-port",
		fmt.tprintf("%d", h.port),
		"data:text/html,<title></title>",
	}
	p, err := os.process_start({command = args, env = env[:], stdout = os.stderr, stderr = os.stderr})
	if err != nil {
		logf("cannot start %s: %v", h.ff_bin, err)
		return false
	}
	h.firefox = p
	h.started_at = time.tick_now()
	logf("started Firefox %s (pid %d), BiDi on port %d", h.ff_version, p.pid, h.port)
	return true
}

bidi :: proc(method: string, params: string, kind := Pending_Kind.Other, view := 0) -> int {
	h.next_cmd += 1
	id := h.next_cmd
	h.pending[id] = {kind, view}
	if TRACE {
		// a fill carries a password: its arguments are never logged
		logf("bidi %d %s %s", id, method, kind == .Fill_Call ? "(the fill's arguments)" : len(params) > 200 ? params[:200] : params)
	}
	msg := strings.concatenate({`{"id":`, fmt.tprintf("%d", id), `,"method":`, jq(method), `,"params":`, params, "}"}, context.temp_allocator)
	ws_send(&h.ws, msg)
	return id
}

PRELOAD :: `(ch) => {
  if (window.top !== window) return;
  const send = (o) => { try { ch(JSON.stringify(o)); } catch (e) {} };
  const iconHref = () => {
    const l = document.querySelector('link[rel~="icon"]');
    return l ? l.href : (location.protocol.startsWith('http') ? location.origin + '/favicon.ico' : '');
  };
  const nav = () => window.navigation ? [navigation.canGoBack, navigation.canGoForward] : [null, null];
  const report = () => { const n = nav(); send({t: 'page', title: document.title, url: location.href, back: n[0], fwd: n[1]}); };
  const icon = () => {
    const href = iconHref();
    if (!href) return;
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => {
      try {
        const c = document.createElement('canvas'); c.width = 32; c.height = 32;
        c.getContext('2d').drawImage(img, 0, 0, 32, 32);
        send({t: 'icon', href, png: c.toDataURL('image/png')});
      } catch (e) { send({t: 'icon', href, png: ''}); }
    };
    img.src = href;
  };
  document.addEventListener('DOMContentLoaded', () => {
    report();
    try { new MutationObserver(report).observe(document.querySelector('head') || document.documentElement, {subtree: true, childList: true, characterData: true}); } catch (e) {}
  });
  window.addEventListener('load', () => { report(); icon(); });
  window.addEventListener('popstate', report);
  window.addEventListener('hashchange', report);
  let lastHref = '';
  document.addEventListener('mouseover', (e) => {
    const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
    const href = a ? a.href : '';
    if (href !== lastHref) { lastHref = href; send({t: 'status', href}); }
  }, true);
  document.addEventListener('contextmenu', (e) => {
    e.preventDefault();
    const t = e.target;
    const a = t && t.closest ? t.closest('a[href]') : null;
    const img = t && t.closest ? t.closest('img') : null;
    const ed = !!(t && (t.isContentEditable || /^(INPUT|TEXTAREA)$/.test(t.tagName)));
    send({t: 'menu', x: e.clientX, y: e.clientY, link: a ? a.href : '', src: img ? img.src : '', sel: String(getSelection()), editable: ed});
  }, true);
  document.addEventListener('selectionchange', () => send({t: 'sel', text: String(getSelection())}));
}`

// The page half of autofill (engine/autofill.js, the file the CEF host
// embeds too), installed in a sandbox realm: page script shares the DOM with
// it but none of its globals, so `fill` and the channel are out of reach.
AUTOFILL_JS :: #load("../autofill.js", string)
AUTOFILL_SANDBOX :: "palm-autofill"
AUTOFILL_PRELOAD :: "(ch) => {\n  if (window.top !== window) return;\n  const fill = " + AUTOFILL_JS + "((...a) => { try { ch(JSON.stringify(a)); } catch (e) {} });\n  if (fill) globalThis.palmAutofillFill = fill;\n}"
AUTOFILL_CALL :: "(o, u, p, t) => typeof globalThis.palmAutofillFill === 'function' ? globalThis.palmAutofillFill(o, u, p, t) : 4"

on_ws_open :: proc() {
	if h.test_certs {
		// PALM_BROWSER_TEST_CERTS=1, for the autofill tests' local HTTPS
		// servers. BiDi has no per-host switch, so this is the whole session.
		logf("TEST MODE: certificate errors are accepted (PALM_BROWSER_TEST_CERTS=1)")
		bidi("session.new", `{"capabilities":{"alwaysMatch":{"acceptInsecureCerts":true,"unhandledPromptBehavior":{"default":"ignore"}}}}`, .Session_New)
		return
	}
	bidi("session.new", `{"capabilities":{"alwaysMatch":{"unhandledPromptBehavior":{"default":"ignore"}}}}`, .Session_New)
}

// ---------------------------------------------------------------------------
// BiDi messages
// ---------------------------------------------------------------------------

view_of_ctx :: proc(ctx: string) -> ^View {
	if ctx == "" {
		return nil
	}
	for _, v in h.views {
		if v.ctx == ctx {
			return v
		}
	}
	return nil
}

send_load :: proc(v: ^View) {
	send_ev(pb.ev_load(v.id, v.loading, v.idx > 0, v.idx + 1 < len(v.hist)))
}

note_url :: proc(v: ^View, url: string) {
	if url == "" || url == "about:blank" && len(v.hist) == 0 {
		return
	}
	if v.travel != 0 {
		v.idx = clamp(v.idx + v.travel, 0, max(len(v.hist) - 1, 0))
		v.travel = 0
		if v.idx < len(v.hist) {
			delete(v.hist[v.idx])
			v.hist[v.idx] = strings.clone(url)
		}
	} else if len(v.hist) == 0 || v.hist[v.idx] != url {
		resize(&v.hist, len(v.hist) == 0 ? 0 : v.idx + 1)
		append(&v.hist, strings.clone(url))
		v.idx = len(v.hist) - 1
	}
	send_ev(pb.ev_str(.Url, v.id, url))
}

assign_ctx :: proc(v: ^View, ctx: string) {
	v.ctx = strings.clone(ctx)
	if v.pending != "" {
		bidi("browsingContext.navigate", J(`{"context":%s,"url":%s,"wait":"none"}`, jq(v.ctx), jq(v.pending)))
		delete(v.pending)
		v.pending = ""
	}
	send_ev(pb.msg_begin(.Ready, v.id))
	if g.view == v.id {
		bidi("browsingContext.activate", J(`{"context":%s}`, jq(v.ctx)))
	}
}

realize_views :: proc() {
	if !h.ready {
		return
	}
	for _, v in h.views {
		if v.ctx != "" {
			continue
		}
		if h.initial_ctx != "" {
			c := h.initial_ctx
			h.initial_ctx = ""
			assign_ctx(v, c)
			continue
		}
		// already asked for?
		asked := false
		for _, p in h.pending {
			if p.kind == .Create && p.view == v.id {
				asked = true
			}
		}
		if !asked {
			bidi("browsingContext.create", `{"type":"tab","background":true}`, .Create, v.id)
		}
	}
}

on_bidi :: proc(text: string) {
	v, err := json.parse_string(text, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	typ := jstr(v, "type")
	if typ == "success" || typ == "error" {
		id := int(jnum(v, "id"))
		p, ok := h.pending[id]
		if !ok {
			if typ == "error" {
				logf("BiDi error for no command of ours: %s %s", jstr(v, "error"), jstr(v, "message"))
			}
			return
		}
		delete_key(&h.pending, id)
		if typ == "error" || TRACE {
			logf("BiDi %s %d: %s %s", typ, id, jstr(v, "error"), jstr(v, "message"))
		}
		if typ == "error" {
			if p.kind == .Session_New {
				return
			}
		}
		#partial switch p.kind {
		case .Fill_Tree:
			fill_checked(v, typ == "success")
		case .Fill_Call:
			status := pb.Fill_Status.Failed
			if typ == "success" && jstr(v, "result", "type") == "success" {
				n := int(jnum(v, "result", "result", "value"))
				if n >= 0 && n <= int(pb.Fill_Status.Failed) {
					status = pb.Fill_Status(n)
				}
			}
			send_ev(pb.ev_fill_result(p.view, status))
		case .Has_Focus:
			if typ == "success" && jstr(v, "result", "type") == "success" {
				if !jbool(v, "result", "result", "value") && g.focused && p.view == g.view && g_client != nil {
					if TRACE {logf("the page has no focus: F6")}
					key_event(g_client, .Down, 0, 0xffc3, 0)
					key_event(g_client, .Up, 0, 0xffc3, 0)
				}
			}
		case .Session_New:
			bidi("session.subscribe", `{"events":["browsingContext","script.message"]}`, .Subscribe)
			bidi("script.addPreloadScript", J(`{"functionDeclaration":%s,"arguments":[{"type":"channel","value":{"channel":"palm"}}]}`, jq(PRELOAD)), .Preload)
			bidi("script.addPreloadScript", J(`{"functionDeclaration":%s,"sandbox":%s,"arguments":[{"type":"channel","value":{"channel":"palm-af"}}]}`, jq(AUTOFILL_PRELOAD), jq(AUTOFILL_SANDBOX)), .Preload)
			bidi("browsingContext.getTree", `{"maxDepth":0}`, .Get_Tree)
		case .Get_Tree:
			if ctxs, cok := jget(v, "result", "contexts").(json.Array); cok && len(ctxs) > 0 {
				h.initial_ctx = strings.clone(jstr(ctxs[0], "context"))
			}
			h.ready = true
			logf("Firefox ready after %.1f s", time.duration_seconds(time.tick_since(h.started_at)))
			realize_views()
		case .Create:
			ctx := jstr(v, "result", "context")
			delete_key(&h.foreign_ctx, ctx)
			if view, vok := h.views[p.view]; vok {
				assign_ctx(view, ctx)
			} else if ctx != "" {
				bidi("browsingContext.close", J(`{"context":%s}`, jq(ctx)))
			}
		}
		return
	}
	if typ != "event" {
		return
	}
	method := jstr(v, "method")
	params := jget(v, "params")
	ctx := jstr(params, "context")
	view := view_of_ctx(ctx)
	switch method {
	case "browsingContext.contextCreated":
		if _, is_null := jget(params, "parent").(json.Null); !is_null && jget(params, "parent") != nil {
			return
		}
		if view == nil && h.ready && ctx != h.initial_ctx {
			h.foreign_ctx[strings.clone(ctx)] = true
		}
	case "browsingContext.contextDestroyed":
		if view != nil && !h.quitting {
			view.ctx = ""
			send_ev(pb.msg_begin(.Closed, view.id))
		}
	case "browsingContext.navigationStarted":
		url := jstr(params, "url")
		if h.foreign_ctx[ctx] {
			if url != "" && url != "about:blank" {
				// a page opened a window: it becomes a chrome tab
				delete_key(&h.foreign_ctx, ctx)
				send_ev(pb.ev_open_tab(g.view, url, true))
				bidi("browsingContext.close", J(`{"context":%s}`, jq(ctx)))
			}
			return
		}
		if view != nil {
			view.loading = true
			note_url(view, url)
			send_load(view)
			send_ev(pb.ev_progress(view.id, 0.15))
		}
	case "browsingContext.domContentLoaded":
		if view != nil {
			send_ev(pb.ev_progress(view.id, 0.7))
		}
	case "browsingContext.load":
		if view != nil {
			if view.id == g.view && g.focused {
				// Firefox leaves focus in its (hidden) address bar after a
				// programmatic navigation; give it to the page
				focus_content(view)
			}
			view.loading = false
			send_load(view)
			send_ev(pb.ev_progress(view.id, 1))
		}
	case "browsingContext.fragmentNavigated", "browsingContext.historyUpdated":
		if view != nil {
			note_url(view, jstr(params, "url"))
			send_load(view)
		}
	case "browsingContext.navigationFailed":
		if view != nil {
			view.loading = false
			send_load(view)
		}
	case "browsingContext.downloadWillBegin":
		h.next_dl += 1
		nav := jstr(params, "navigation")
		h.dl_ctx[strings.clone(nav)] = h.next_dl
		name := jstr(params, "suggestedFilename")
		path := fmt.tprintf("%s/%s", h.downloads, name)
		send_ev(pb.ev_download(view != nil ? view.id : g.view, h.next_dl, .Progress, 0, -1, jstr(params, "url"), path, ""))
	case "browsingContext.downloadEnd":
		nav := jstr(params, "navigation")
		id := h.dl_ctx[nav] or_else 0
		status := jstr(params, "status")
		path := jstr(params, "filepath")
		size: i64
		if fi, ferr := os.stat(path, context.temp_allocator); ferr == nil {
			size = fi.size
		}
		send_ev(pb.ev_download(view != nil ? view.id : g.view, id, status == "complete" ? .Done : .Cancelled, size, size, jstr(params, "url"), path, ""))
	case "script.message":
		if jstr(params, "channel") == "palm-af" {
			autofill_message(params)
			// the message may have carried a submitted password
			pb.wipe(transmute([]u8)text)
			return
		}
		if jstr(params, "channel") != "palm" {
			return
		}
		src_ctx := jstr(params, "source", "context")
		sv := view_of_ctx(src_ctx)
		if sv == nil {
			return
		}
		inner, ierr := json.parse_string(jstr(params, "data", "value"), allocator = context.temp_allocator)
		if ierr != nil {
			return
		}
		page_message(sv, inner)
	}
}

page_message :: proc(v: ^View, m: json.Value) {
	switch jstr(m, "t") {
	case "page":
		send_ev(pb.ev_str(.Title, v.id, jstr(m, "title")))
		url := jstr(m, "url")
		if url != "" && (len(v.hist) == 0 || v.hist[v.idx] != url) {
			note_url(v, url)
		}
		// the Navigation API knows the real history, when Firefox has it
		if b, ok := jget(m, "back").(json.Boolean); ok {
			f, _ := jget(m, "fwd").(json.Boolean)
			send_ev(pb.ev_load(v.id, v.loading, bool(b), bool(f)))
		}
	case "status":
		send_ev(pb.ev_str(.Status, v.id, jstr(m, "href")))
	case "sel":
		send_ev(pb.ev_str(.Selection, v.id, jstr(m, "text")))
	case "icon":
		data := jstr(m, "png")
		png: []u8
		if i := strings.index(data, "base64,"); i >= 0 {
			png, _ = base64.decode(data[i + 7:], allocator = context.temp_allocator)
		}
		send_ev(pb.ev_favicon(v.id, jstr(m, "href"), png))
	case "menu":
		z := v.zoom > 0 ? v.zoom : 1
		mm := pb.msg_begin(.Menu, v.id)
		pb.w_u32(&mm, 0)
		pb.w_f32(&mm, f32(jnum(m, "x")) * z)
		pb.w_f32(&mm, f32(jnum(m, "y")) * z)
		pb.w_str(&mm, jstr(m, "link"))
		pb.w_str(&mm, jstr(m, "sel"))
		pb.w_str(&mm, jstr(m, "src"))
		pb.w_u8(&mm, jbool(m, "editable") ? 1 : 0)
		pb.w_u32(&mm, 0) // no engine items: the chrome's own menu is complete
		send_ev(mm)
	}
}

// ---------------------------------------------------------------------------
// Autofill
// ---------------------------------------------------------------------------

// view_origin is the top-level origin of a view as this host knows it: the
// URL BiDi last reported for the top-level context.
view_origin :: proc(v: ^View) -> string {
	if v == nil || len(v.hist) == 0 || v.idx >= len(v.hist) {
		return ""
	}
	return pb.origin_of(v.hist[v.idx])
}

// autofill_message is a report from autofill.js in the palm-autofill
// sandbox. It counts only from a top-level context the chrome owns (an
// iframe has a context of its own, which matches no view), and only when the
// page's location.origin agrees with the URL BiDi reported for that context.
autofill_message :: proc(params: json.Value) {
	v := view_of_ctx(jstr(params, "source", "context"))
	if v == nil {
		return
	}
	raw := jstr(params, "data", "value")
	m, err := json.parse_string(raw, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	a, ok := m.(json.Array)
	if !ok || len(a) < 1 {
		return
	}
	str :: proc(a: json.Array, i: int) -> string {
		if i < len(a) {
			if s, ok := a[i].(json.String); ok {
				return string(s)
			}
		}
		return ""
	}
	num :: proc(a: json.Array, i: int) -> f32 {
		if i < len(a) {
			#partial switch x in a[i] {
			case json.Float:
				return f32(x)
			case json.Integer:
				return f32(x)
			}
		}
		return 0
	}
	top := view_origin(v)
	z := v.zoom > 0 ? v.zoom : 1
	switch str(a, 0) {
	case "focus":
		said := str(a, 6)
		if top == "" || said != top {
			if TRACE {logf("autofill: focus report from %s on a view at %s dropped", said, top)}
			return
		}
		k := int(num(a, 1))
		kind := k >= 0 && k <= int(pb.Field_Kind.Otp) ? pb.Field_Kind(k) : .None
		send_ev(pb.ev_field_focus(v.id, kind, num(a, 2) * z, num(a, 3) * z, num(a, 4) * z, num(a, 5) * z, top))
	case "submit":
		said := str(a, 1)
		pass := str(a, 3)
		if top == "" || said != top || pass == "" {
			return
		}
		m := pb.ev_form_submit(v.id, top, str(a, 2), pass, str(a, 4))
		pb.send_secret(&h.chrome, &m)
	}
	pb.wipe(transmute([]u8)raw)
}

// fill_start asks Firefox where the view's top-level context is now; the
// answer (fill_checked) decides whether the fill runs.
fill_start :: proc(q: pb.Request) {
	if h.fill.active {
		fill_clear(&h.fill)
	}
	v := h.views[q.view] or_else nil
	if v == nil || v.ctx == "" {
		send_ev(pb.ev_fill_result(q.view, .Failed))
		return
	}
	h.fill = Fill_Pending {
		active   = true,
		view     = q.view,
		origin   = strings.clone(q.str),
		username = strings.clone(q.str2),
		password = strings.clone(q.str3),
		otp      = strings.clone(q.str4),
	}
	bidi("browsingContext.getTree", J(`{"root":%s,"maxDepth":0}`, jq(v.ctx)), .Fill_Tree, q.view)
}

fill_checked :: proc(resp: json.Value, ok: bool) {
	f := &h.fill
	if !f.active {
		return
	}
	defer fill_clear(f)
	v := h.views[f.view] or_else nil
	url := ""
	if ok {
		if ctxs, cok := jget(resp, "result", "contexts").(json.Array); cok && len(ctxs) > 0 {
			url = jstr(ctxs[0], "url")
		}
	}
	now := pb.origin_of(url)
	if v == nil || v.ctx == "" || now == "" || now != f.origin {
		logf("autofill: dropped a fill for %s: the view is at %s", f.origin, now != "" ? now : "a non-web page")
		send_ev(pb.ev_fill_result(f.view, .Origin_Changed))
		return
	}
	// The values travel as BiDi arguments -- serialized by the protocol into
	// the sandbox, never spliced into source -- and autofill.js checks the
	// origin once more, in the page, as it fills.
	sb := strings.builder_make(context.temp_allocator)
	// (built by concatenation: fmt reads braces as its own)
	for part in ([]string{`{"functionDeclaration":`, jq(AUTOFILL_CALL), `,"target":{"context":`, jq(v.ctx), `,"sandbox":`, jq(AUTOFILL_SANDBOX), `},"awaitPromise":false,"arguments":[`}) {
		strings.write_string(&sb, part)
	}
	for s, i in ([]string{f.origin, f.username, f.password, f.otp}) {
		strings.write_string(&sb, i > 0 ? `,{"type":"string","value":` : `{"type":"string","value":`)
		strings.write_string(&sb, jq(s))
		strings.write_string(&sb, "}")
	}
	strings.write_string(&sb, "]}")
	params := strings.to_string(sb)
	bidi("script.callFunction", params, .Fill_Call, f.view)
	pb.wipe(sb.buf[:])
}

// ---------------------------------------------------------------------------
// Requests from the chrome
// ---------------------------------------------------------------------------

eval_in :: proc(v: ^View, expr: string) {
	if v == nil || v.ctx == "" {
		return
	}
	bidi("script.evaluate", J(`{"expression":%s,"target":{"context":%s},"awaitPromise":false,"userActivation":true}`, jq(expr), jq(v.ctx)))
}

on_request :: proc(raw: []u8) {
	q, ok := pb.decode_request(raw)
	if !ok {
		return
	}
	v := h.views[q.view] or_else nil
	c := g_client
	if TRACE && q.op != .Mouse && q.op != .Frame_Ack {
		logf("request %v view %d", q.op, q.view)
	}
	#partial switch q.op {
	case .Theme:
		h.dark = q.flag ? 1 : 0
	case .Create:
		if g.w == 0 || len(h.views) == 0 {
			resize_view(int(q.w), int(q.h), q.scale)
		}
		nv := new(View)
		nv.id = q.view
		nv.zoom = 1
		url := q.str != "" ? q.str : "about:blank"
		nv.pending = strings.clone(url)
		h.views[q.view] = nv
		if g.view == 0 {
			g.view = q.view
		}
		start_firefox()
		realize_views()
	case .Close:
		if v != nil {
			if v.ctx != "" {
				owned := 0
				for _, x in h.views {
					if x.ctx != "" {owned += 1}
				}
				if owned <= 1 {
					// Firefox exits with its last tab; keep it, blank, for reuse
					bidi("browsingContext.navigate", J(`{"context":%s,"url":"about:blank","wait":"none"}`, jq(v.ctx)))
					h.initial_ctx = strings.clone(v.ctx)
				} else {
					bidi("browsingContext.close", J(`{"context":%s}`, jq(v.ctx)))
				}
			}
			delete_key(&h.views, q.view)
			if g.view == q.view {
				g.view = 0
			}
		}
	case .Navigate:
		if v != nil {
			if v.ctx == "" {
				delete(v.pending)
				v.pending = strings.clone(q.str)
			} else {
				bidi("browsingContext.navigate", J(`{"context":%s,"url":%s,"wait":"none"}`, jq(v.ctx), jq(q.str)))
			}
		}
	case .History:
		if v != nil && v.ctx != "" {
			v.travel = int(q.n)
			bidi("browsingContext.traverseHistory", J(`{"context":%s,"delta":%d}`, jq(v.ctx), q.n))
		}
	case .Reload:
		if v != nil && v.ctx != "" {
			bidi("browsingContext.reload", J(`{"context":%s,"ignoreCache":%v,"wait":"none"}`, jq(v.ctx), q.flag))
		}
	case .Stop:
		eval_in(v, "window.stop()")
	case .Resize:
		resize_view(int(q.w), int(q.h), q.scale)
	case .Show:
		if q.flag && v != nil {
			if g.view != v.id {
				g.view = v.id
				// the new view needs its own buffer and a whole frame
				if g.shm != nil {
					linux.munmap(raw_data(g.shm), uint(g.sw * g.sh * 4))
					linux.close(g.shm_fd)
					g.shm = nil
				}
				g.inflight = false
				damage_all()
			}
			if v.ctx != "" {
				bidi("browsingContext.activate", J(`{"context":%s}`, jq(v.ctx)))
			}
		}
	case .Focus:
		g.focused = q.flag
		keyboard_focus_update(c)
		if q.flag {
			if fv := h.views[g.view] or_else nil; fv != nil {
				focus_content(fv)
			}
		}
	case .Mouse:
		if c == nil {return}
		switch q.mouse {
		case .Move:
			pointer_motion(c, q.x, q.y)
		case .Leave:
			pointer_motion(c, q.x, q.y, true)
		case .Down, .Up:
			pointer_button(c, q.button, q.mouse == .Down, q.x, q.y)
		}
	case .Wheel:
		if c != nil {pointer_axis(c, q.x, q.y, q.dx, q.dy)}
	case .Key:
		if c != nil {key_event(c, q.key, q.mods, q.keysym, q.codepoint)}
	case .Frame_Ack:
		frame_ack()
	case .Zoom:
		if v != nil && v.ctx != "" {
			v.zoom = q.factor
			bidi("browsingContext.setViewport", J(`{"context":%s,"devicePixelRatio":%.3f}`, jq(v.ctx), f32(g.scale) * q.factor))
		}
	case .Find:
		if q.str != "" {
			eval_in(v, fmt.tprintf("window.find(%s, false, %v, true)", jq(q.str), !q.flag))
			send_ev(pb.ev_find_result(q.view, -1, -1))
		} else {
			eval_in(v, "getSelection().removeAllRanges()")
		}
	case .Edit:
		switch q.edit {
		case .Undo:
			eval_in(v, "document.execCommand('undo')")
		case .Redo:
			eval_in(v, "document.execCommand('redo')")
		case .Cut:
			eval_in(v, "document.execCommand('cut')")
		case .Copy:
			eval_in(v, "document.execCommand('copy')")
		case .Select_All:
			eval_in(v, "document.execCommand('selectAll')")
		case .Paste, .Insert:
			if q.str != "" {
				eval_in(v, fmt.tprintf("document.execCommand('insertText', false, %s)", jq(q.str)))
			}
		}
	case .Fill:
		fill_start(q)
		pb.wipe(raw)
	case .Quit:
		quit()
	}
}

// client_gone forgets a client. Firefox opens a short-lived probe connection
// before its real one, so a hang-up is not a crash; the process exiting is.
client_gone :: proc(c: ^Client) {
	linux.close(c.fd)
	for x, i in h.clients {
		if x == c {
			ordered_remove(&h.clients, i)
			break
		}
	}
	if c == g_client {
		g.toplevel = nil
		g.toplevel_mapped = false
		clear(&g.popups)
		g.pointer_focus = nil
		g.kbd_focus = nil
		g_client = len(h.clients) > 0 ? h.clients[len(h.clients) - 1] : nil
		damage_all()
	}
}

// focus_content moves Firefox's keyboard focus from its chrome (the hidden
// address bar, in kiosk mode) to the page.
focus_content :: proc(v: ^View) {
	if v == nil || v.ctx == "" {
		return
	}
	bidi("browsingContext.activate", J(`{"context":%s}`, jq(v.ctx)))
	// Ask the page whether it has focus. If the hidden address bar has it,
	// F6 -- Firefox's own "move focus between the toolbar and the page" key
	// -- hands it over; the answer arrives in on_bidi as .Has_Focus.
	bidi("script.evaluate", J(`{"expression":"document.hasFocus()","target":{"context":%s},"awaitPromise":false}`, jq(v.ctx)), .Has_Focus, v.id)
}

resize_view :: proc(w, h_: int, scale: f32) {
	g.w = max(w, 1)
	g.h = max(h_, 1)
	g.scale = max(int(scale + 0.5), 1)
	c := g_client
	if c != nil {
		for o in c.outputs {
			send_output(c, o, c.objects[o].version)
		}
		configure_toplevel(c)
		for p in g.popups {
			place_popup(p)
		}
	}
	damage_all()
}

quit :: proc() {
	h.quitting = true
	if h.ws.open {
		bidi("browser.close", "{}")
	}
	if h.ff_started {
		deadline := time.tick_now()
		for time.tick_since(deadline) < 3 * time.Second {
			state, err := os.process_wait(h.firefox, 100 * time.Millisecond)
			if err == nil && state.exited {
				break
			}
		}
		_ = os.process_kill(h.firefox)
	}
	os.remove(h.wl_path)
	os.exit(0)
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

arg_value :: proc(name: string) -> string {
	for a, i in os.args {
		if strings.has_prefix(a, name) && len(a) > len(name) && a[len(name)] == '=' {
			return a[len(name) + 1:]
		}
		if a == name && i + 1 < len(os.args) {
			return os.args[i + 1]
		}
	}
	return ""
}

host_main :: proc() {
	sock := arg_value("--socket")
	h.profile = arg_value("--profile")
	h.downloads = arg_value("--downloads")
	h.ff_bin = arg_value("--firefox")
	if h.ff_bin == "" {
		h.ff_bin = os.get_env("PALM_BROWSER_FIREFOX", context.allocator)
	}
	h.dark = -1
	TRACE = os.get_env("PALM_GECKO_TRACE", context.temp_allocator) != ""
	h.test_certs = os.get_env("PALM_BROWSER_TEST_CERTS", context.temp_allocator) == "1"
	if len(os.args) > 1 && os.args[1] == "--version" {
		fmt.println("browser --gecko-host", h.ff_bin != "" ? firefox_version(h.ff_bin) : "")
		return
	}
	if sock == "" || h.profile == "" || h.ff_bin == "" {
		fmt.eprintln("usage: browser --gecko-host --socket PATH --profile DIR --firefox BIN [--downloads DIR]")
		os.exit(2)
	}
	if h.downloads == "" {
		h.downloads = fmt.aprintf("%s/Downloads", os.get_env("HOME", context.temp_allocator))
	}
	h.ff_version = firefox_version(h.ff_bin)
	g.start_ms = now_ms()
	g.scale = 1
	keymap_reset()

	fd, ok := pb.connect_unix(sock)
	if !ok {
		logf("cannot connect to %s", sock)
		os.exit(6)
	}
	h.chrome.fd = fd
	g.chrome = &h.chrome

	// the private Wayland display
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {rt = "/tmp"}
	h.wl_path = fmt.aprintf("%s/palm-gecko-%d", rt, os.get_pid())
	lfd, lok := pb.listen_unix(h.wl_path)
	if !lok {
		logf("cannot listen on %s", h.wl_path)
		os.exit(7)
	}
	h.wl_listen = lfd

	send_ev(pb.ev_hello("firefox", h.ff_version))

	for {
		fds := make([dynamic]linux.Poll_Fd, context.temp_allocator)
		append(&fds, linux.Poll_Fd{fd = h.chrome.fd, events = {.IN}})
		append(&fds, linux.Poll_Fd{fd = h.wl_listen, events = {.IN}})
		ws_slot := -1
		first_client := len(fds)
		for c in h.clients {
			append(&fds, linux.Poll_Fd{fd = c.fd, events = {.IN}})
		}
		if h.ws.open {
			ws_slot = len(fds)
			append(&fds, linux.Poll_Fd{fd = h.ws.fd, events = {.IN}})
		}
		timeout: i32 = 200
		if g.cb_waiting && !g.inflight {
			timeout = i32(max(0, FRAME_MS - (now_ms() - g.last_cb)))
		}
		if g.need_compose {
			timeout = 0
		}
		linux.poll(fds[:], timeout)
		if g.cb_waiting && frames_due() {
			send_frame_callbacks()
		}

		if .IN in fds[0].revents || .HUP in fds[0].revents {
			buf: [65536]u8
			n, err := linux.recv(h.chrome.fd, buf[:], {.DONTWAIT})
			if err == .NONE && n > 0 {
				append(&h.crx, ..buf[:n])
			} else if err != .EAGAIN && err != .EINTR {
				quit()
			}
			for len(h.crx) >= 8 {
				size := int((^u32)(raw_data(h.crx))^)
				if size < 8 || size > 64 << 20 {
					quit()
				}
				if len(h.crx) < size {
					break
				}
				msg := make([]u8, size, context.temp_allocator)
				copy(msg, h.crx[:size])
				before := len(h.crx)
				remove_range(&h.crx, 0, size)
				if pb.Op((^u16)(&msg[4])^) == .Fill {
					pb.wipe(([^]u8)(raw_data(h.crx))[len(h.crx):before])
				}
				on_request(msg)
			}
		}
		// existing clients first, so a hang-up is seen before a new connection
		gone := make([dynamic]^Client, context.temp_allocator)
		for c, i in h.clients {
			if fds[first_client + i].revents == {} {
				continue
			}
			if !client_read(c) {
				c.dead = true
			}
			client_dispatch(c)
			client_flush(c)
			if c.dead {
				append(&gone, c)
			}
		}
		for c in gone {
			logf("a Wayland client disconnected")
			client_gone(c)
		}
		if .IN in fds[1].revents {
			cfd, err := linux.accept(h.wl_listen, cast(^linux.Sock_Addr_Un)nil, {.CLOEXEC, .NONBLOCK})
			if err == .NONE {
				c := new(Client)
				c.fd = cfd
				c.objects[DISPLAY_ID] = {.Display, 1, nil}
				append(&h.clients, c)
				if g_client == nil {
					g_client = c
				}
				logf("a Wayland client connected (%d now)", len(h.clients))
			}
		}
		if ws_slot >= 0 && fds[ws_slot].revents != {} {
			msgs := make([dynamic]string, context.temp_allocator)
			ws_read(&h.ws, &msgs)
			for m in msgs {
				on_bidi(m)
			}
		}
		// connect to BiDi once Firefox is listening
		if h.ff_started && !h.ws.open && !h.quitting {
			if ws, wok := ws_connect(h.port, "/session"); wok {
				h.ws = ws
				on_ws_open()
			} else if time.tick_since(h.started_at) > 60 * time.Second {
				logf("Firefox never opened its remote protocol")
				for _, v in h.views {
					send_ev(pb.ev_str(.Crashed, v.id, "Firefox did not start"))
				}
				h.ff_started = false
			}
		}
		// Firefox exiting on its own
		if h.ff_started && !h.quitting {
			if state, err := os.process_wait(h.firefox, 0); err == nil && state.exited {
				logf("Firefox exited (%d)", state.exit_code)
				for _, v in h.views {
					send_ev(pb.ev_str(.Crashed, v.id, fmt.tprintf("Firefox exited (status %d)", state.exit_code)))
				}
				h.ff_started = false
				h.ws.open = false
			}
		}
		compose()
		for c in h.clients {
			client_flush(c)
		}
		free_all(context.temp_allocator)
	}
}
