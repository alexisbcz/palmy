// `accounts shots <dir>`: render the interface offscreen and write PNGs.
//
// No compositor, no window and no network: the same `frame` the window runs,
// drawn over a fixture account invented here. Nobody's real account, token or
// machine name is anywhere near a picture.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_W :: 1120
SHOT_H :: 740

shot_fonts :: proc(off: ^p.Offscreen) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	register_colors()
}

FIX_HOME :: "6f1c2a4e-1b7d-4c55-9a0e-2d1b9c8e7a01"
FIX_WORK :: "a3b9e0c2-77d4-4e1a-b6f2-90c1d2e3f4a5"
FIX_PUBLIC :: "c0ffee00-1234-4abc-8def-001122334455"
FIX_OLD :: "dead0000-beef-4000-8000-000000000001"

// The fixture account. Package variables, not literals inside fixture():
// a slice literal in a procedure lives on its stack frame.
FIX_IDS := []ck.Identity {
	{id = FIX_HOME, handle = "alex", display_name = "Alex Rivera", kind = "personal", color = "indigo", created_at = "2026-09-02T09:12:00Z"},
	{id = FIX_WORK, handle = "alex.northwind", display_name = "Alex at Northwind", kind = "work", color = "sky", created_at = "2026-09-02T09:14:00Z"},
	{id = FIX_PUBLIC, handle = "riverastudio", display_name = "Rivera Studio", kind = "public", color = "amber", created_at = "2026-09-20T16:40:00Z"},
	{id = FIX_OLD, handle = "hackathon.2025", display_name = "Hackathon team", kind = "project", color = "emerald", archived = true, created_at = "2025-11-01T10:00:00Z"},
}
FIX_DEVS := []ck.Device {
	{id = "d1", identity_id = FIX_WORK, name = "Mail assistant", kind = "assistant", created_at = "2026-10-18T08:30:00Z", active = true},
	{id = "d2", identity_id = FIX_HOME, name = "Pixel 9", kind = "device", created_at = "2026-10-11T19:05:00Z", active = true},
	{id = "d3", identity_id = FIX_PUBLIC, name = "Posting assistant", kind = "assistant", created_at = "2026-10-01T12:00:00Z", active = false},
}
FIX_SESS := []ck.Account_Session {
	{session_id = "5e55a000-0000-4000-8000-000000000001", created_at = "2026-10-19T08:02:00Z", refreshed_at = "2026-10-19T10:41:00Z", user_agent = "palm-accounts/0.1 (workbench)", current = true},
	{session_id = "5e55a000-0000-4000-8000-000000000002", created_at = "2026-10-18T08:30:00Z", refreshed_at = "2026-10-19T10:38:00Z", identity_id = FIX_WORK, device_id = "d1", device_name = "Mail assistant", device_kind = "assistant", not_after = "2026-10-25T08:30:00Z"},
	{session_id = "5e55a000-0000-4000-8000-000000000003", created_at = "2026-10-11T19:05:00Z", refreshed_at = "2026-10-19T07:55:00Z", identity_id = FIX_HOME, device_id = "d2", device_name = "Pixel 9", device_kind = "device"},
	{session_id = "5e55a000-0000-4000-8000-000000000004", created_at = "2026-10-03T14:20:00Z", refreshed_at = "2026-10-17T22:10:00Z", user_agent = "palm-accounts/0.1 (travel-laptop)"},
}

// fixture fills a St with an invented account: three identities and an
// archived one, an assistant and a phone delegated, two signed-in machines.
fixture :: proc(st: ^St) {
	st.fixture = true
	st.signed_in = true
	st.email = "alex@rivera.example"
	st.user_id = "0b5e7c1a-4d2f-4e8b-9a6c-3f1d2e4b5a69"
	st.host = "workbench"
	st.ids = FIX_IDS
	st.devs = FIX_DEVS
	st.sess = FIX_SESS
	st.current = "alex.northwind"
	st.stored["alex"] = true
	st.stored["alex.northwind"] = true
}

set_buf :: proc(b: ^[dynamic]u8, s: string) {
	clear(b)
	append(b, ..transmute([]u8)s)
}

// shots returns how many PNGs it wrote, or -1.
shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm_number(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("accounts shots: cannot create %s", dir)
		return -1
	}
	off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off)

	st := new(St)
	st_init(st)
	suffix := ""
	if lang := kit.i18n_language(); lang != "" && !strings.has_prefix(lang, "en") && lang != "C" {
		base := lang
		if i := strings.index_any(base, "_.@"); i > 0 {
			base = base[:i]
		}
		// Cloned: offscreen_end frees the temp allocator every frame.
		suffix = strings.clone(fmt.tprintf("-%s", base))
	}

	n := 0
	settle :: proc(off: ^p.Offscreen, st: ^St, frames := 3) {
		for _ in 0 ..< frames {
			ui := p.offscreen_begin(off)
			st.now = f64(p.elapsed(ui))
			frame(st, ui)
			p.offscreen_end(off)
		}
	}
	write :: proc(off: ^p.Offscreen, dir, name, suffix: string, n: ^int) {
		path := fmt.tprintf("%s/%s%s.png", dir, name, suffix)
		if p.offscreen_write_png(off, path) {
			n^ += 1
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// Signed out: sign in.
	st.fixture = true
	st.auth_mode = .Sign_In
	set_buf(&st.email_buf, "alex@rivera.example")
	set_buf(&st.pw_buf, "correct horse battery")
	st.want_focus = "password"
	settle(off, st)
	write(off, dir, "01-sign-in", suffix, &n)

	// Signed out: create the account and its first identity.
	st.auth_mode = .Create
	set_buf(&st.name_buf, "Alex Rivera")
	set_buf(&st.handle_buf, "alex")
	set_buf(&st.pw_buf, "")
	st.want_focus = "password"
	settle(off, st)
	write(off, dir, "02-create-account", suffix, &n)

	// Signed in.
	fixture(st)
	st.view = .Identities
	settle(off, st)
	write(off, dir, "03-identities", suffix, &n)

	open_new_identity(st)
	set_buf(&st.new_name, "Side project")
	set_buf(&st.new_handle, "alex.side")
	st.new_kind = 3
	st.new_color = 6
	settle(off, st)
	write(off, dir, "04-new-identity", suffix, &n)
	st.new_open = false

	st.view = .Devices
	settle(off, st)
	write(off, dir, "05-devices", suffix, &n)

	st.del_open = true
	st.del_ident = 1
	st.del_kind = 0
	st.del_expiry = 3
	set_buf(&st.del_name, "Calendar assistant")
	st.minted = strings.clone("alex.northwind")
	st.minted_path = strings.clone("~/.local/share/palm/cloud/delegated/alex.northwind-7c41e2d0.json")
	settle(off, st)
	write(off, dir, "06-delegate", suffix, &n)
	st.del_open = false

	st.view = .Session
	settle(off, st)
	write(off, dir, "07-session-full", suffix, &n)

	// The same window, opened with PALM_IDENTITY=alex.northwind.
	st.scope = st.ids[1]
	ids_all := st.ids
	st.ids = st.ids[1:2]
	sess_all := st.sess
	st.sess = sess_all[1:2]
	st.sess[0].current = true
	settle(off, st)
	write(off, dir, "08-session-scoped", suffix, &n)
	st.view = .Identities
	settle(off, st)
	write(off, dir, "09-identities-scoped", suffix, &n)
	st.sess[0].current = false
	st.scope = {}
	st.ids = ids_all
	st.sess = sess_all

	st.view = .Security
	settle(off, st)
	write(off, dir, "10-security", suffix, &n)

	st.view = .Identities
	st.confirm = .Archive
	st.confirm_id = FIX_PUBLIC
	st.confirm_label = "Rivera Studio"
	settle(off, st)
	write(off, dir, "11-archive-confirm", suffix, &n)
	st.confirm = .None

	fmt.printfln("accounts shots: %d PNGs in %s", n, dir)
	return n
}
