// Accounts — one Palmframe account, several identities.
//
// The window and the command line (cli.odin) are two front ends over the same
// procedures in this file, which are themselves thin: everything that talks to
// the cloud is apps/cloudkit, and everything that decides who may see what is
// the database (cloud/supabase/migrations). This app cannot widen a scope even
// if it tried, which is the point of building it this way round.
//
// What a person does here:
//
//   - signs in, or creates the account and its first identity in one step;
//   - sees their identities, makes new ones, renames, recolours, archives;
//   - switches identity: the choice is remembered, and this machine gets a
//     session scoped to that identity, which is what every other app started
//     with PALM_IDENTITY=<handle> uses;
//   - delegates: mints a session for one identity to give an assistant or
//     another device, and revokes it, which takes effect at once;
//   - sees every session on the account and ends the ones they do not know.
package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."

View :: enum u8 {
	Identities,
	Devices,
	Session,
	Security,
}

Auth_Mode :: enum u8 {
	Sign_In,
	Create,
}

Confirm_Kind :: enum u8 {
	None,
	Archive,
	Revoke,
	End_Session,
	Sign_Out,
}

KINDS := [?]string{"personal", "work", "public", "project"}
COLORS := [?]string{"indigo", "sky", "emerald", "amber", "rose", "violet", "teal", "orange", "slate"}
EXPIRIES := [?]int{0, 3600, 86400, 7 * 86400}

// MAIL_DOMAIN is the local development mail domain (cloud/CONTRACT.md).
MAIL_DOMAIN :: "palm.test"

St :: struct {
	c:          ^ck.Client, // nil when drawing a fixture
	fixture:    bool,
	host:       string,

	// What the server said, reloaded after every change. Lives in `data`.
	data:       virtual.Arena,
	alloc:      mem.Allocator,
	signed_in:  bool,
	email:      string,
	user_id:    string,
	scope:      ck.Identity, // what this process's session is scoped to; id == "" for none
	ids:        []ck.Identity,
	devs:       []ck.Device,
	sess:       []ck.Account_Session,
	current:    string, // handle
	stored:     map[string]bool, // handles with a scoped session stored on this machine

	view:       View,
	auth_mode:  Auth_Mode,
	email_buf:  [dynamic]u8,
	pw_buf:     [dynamic]u8,
	name_buf:   [dynamic]u8,
	handle_buf: [dynamic]u8,
	handle_touched: bool,

	// the new-identity form
	new_open:   bool,
	new_kind:   int,
	new_color:  int,
	new_name:   [dynamic]u8,
	new_handle: [dynamic]u8,
	new_handle_touched: bool,

	// renaming in place
	rename_id:  string,
	rename_buf: [dynamic]u8,

	// delegating a scoped session
	del_open:   bool,
	del_ident:  int,
	del_kind:   int, // 0 assistant, 1 device
	del_expiry: int,
	del_name:   [dynamic]u8,
	minted:     string, // the last delegation's handle, for the confirmation line
	minted_path: string, // and where its session file is

	confirm:    Confirm_Kind,
	confirm_id: string,
	confirm_label: string,

	toast:      string,
	toast_bad:  bool,
	toast_at:   f64,
	now:        f64,
	sel:        int, // keyboard row in the identity list
	want_focus: string, // a field to focus on the next frame, by key
}

st_init :: proc(st: ^St) {
	_ = virtual.arena_init_growing(&st.data)
	st.alloc = virtual.arena_allocator(&st.data)
	st.stored = make(map[string]bool)
	st.host = strings.clone(ck.machine_name() != "" ? ck.machine_name() : "this machine")
	st.del_expiry = 2
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

main :: proc() {
	kit.i18n_init("accounts")
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	st := new(St)
	st_init(st)
	c, oerr := ck.open(app = "accounts")
	st.c = c
	if !ck.ok(oerr) {
		fmt.eprintfln("accounts: %s", oerr.message)
		os.exit(2)
	}
	reload(st)

	app, err := kit.start(
		{
			title = "Accounts",
			app_id = "palm-accounts",
			width = 1120,
			height = 740,
			min_width = 880,
			min_height = 560,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("accounts: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	register_colors()

	for ui in p.frames(app) {
		st.now = f64(p.elapsed(ui))
		keys(st, ui)
		frame(st, ui)
	}
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

// reload asks the server for everything the window shows. On a scoped
// session the server answers with that identity alone, and the window shows
// exactly that, which is the honest picture.
reload :: proc(st: ^St) {
	if st.fixture {
		return
	}
	free_all(st.alloc)
	st.ids, st.devs, st.sess = nil, nil, nil
	st.scope = {}
	clear(&st.stored)
	st.signed_in = ck.signed_in(st.c)
	if !st.signed_in {
		return
	}
	a := st.alloc
	st.email = strings.clone(st.c.session.email, a)
	st.user_id = strings.clone(st.c.session.user_id, a)

	e: ck.Error
	st.ids, e = ck.identities(st.c, a)
	if !ck.ok(e) {
		if e.kind == .Unauthorized || e.kind == .Not_Signed_In {
			st.signed_in = ck.signed_in(st.c)
		}
		say(st, e.message, bad = true)
		return
	}
	st.devs, _ = ck.devices(st.c, a)
	st.sess, _ = ck.sessions(st.c, a)
	if who, werr := ck.whoami(st.c, context.temp_allocator); ck.ok(werr) && ck.get_bool(who, "scoped") {
		if x, found := ck.find_identity(st.ids, ck.get_str(who, "identity", "id")); found {
			st.scope = x
		}
	}
	st.current = ck.current_identity(st.c, a)
	if _, found := ck.find_identity(st.ids, st.current); !found || st.current == "" {
		st.current = ""
		for x in st.ids {
			if !x.archived {
				st.current = x.handle
				break
			}
		}
	}
	for x in st.ids {
		if os.exists(ck.scoped_path(st.c, x.handle, context.temp_allocator)) {
			st.stored[strings.clone(x.handle, a)] = true
		}
	}
	st.sel = clamp(st.sel, 0, max(len(st.ids) - 1, 0))
}

say :: proc(st: ^St, msg: string, bad := false) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_bad = bad
	st.toast_at = st.now
}

err_text :: proc(e: ck.Error) -> string {
	switch e.kind {
	case .Unavailable:
		return kit.tr("The Palmframe cloud is not reachable.")
	case .Unauthorized:
		if e.code == "invalid_credentials" {
			return kit.tr("That email and password do not match.")
		}
		return kit.tr("The session was refused. Sign in again.")
	case .Conflict:
		return kit.tr("That is already taken.")
	case .Out_Of_Scope:
		return kit.tr("Refused: this session acts for one identity only.")
	case .None, .Not_Signed_In, .Not_Found, .Invalid, .Failed:
	}
	return e.message
}

// ---------------------------------------------------------------------------
// Actions. Each is one cloudkit call and a reload; the CLI calls the same.
// ---------------------------------------------------------------------------

act_sign_in :: proc(st: ^St, email, password: string) -> ck.Error {
	e := ck.sign_in(st.c, strings.trim_space(email), password)
	reload(st)
	return e
}

// act_create_account signs up and creates the first identity in one step, so
// there is never an account with nothing in it.
act_create_account :: proc(st: ^St, email, password, display_name, handle: string) -> ck.Error {
	if e := ck.sign_up(st.c, strings.trim_space(email), password); !ck.ok(e) {
		return e
	}
	_, e := ck.create_identity(st.c, handle, display_name, "personal", "indigo", context.temp_allocator)
	if ck.ok(e) {
		ck.set_current_identity(st.c, handle)
	}
	reload(st)
	return e
}

act_create_identity :: proc(st: ^St, handle, display_name, kind, color: string) -> (ck.Identity, ck.Error) {
	x, e := ck.create_identity(st.c, handle, display_name, kind, color, context.temp_allocator)
	reload(st)
	return x, e
}

// act_switch makes `handle` the current identity and makes sure this
// machine holds a session scoped to it, so apps started for that identity
// can reach the cloud as it and only as it.
act_switch :: proc(st: ^St, handle: string) -> ck.Error {
	x, found := ck.find_identity(st.ids, handle)
	if !found {
		return ck.Error{kind = .Not_Found, message = fmt.aprintf("no identity %q", handle)}
	}
	if x.archived {
		return ck.Error{kind = .Invalid, message = fmt.aprintf("%s is archived", handle)}
	}
	if e := ck.set_current_identity(st.c, handle); !ck.ok(e) {
		return e
	}
	if !os.exists(ck.scoped_path(st.c, handle, context.temp_allocator)) && !ck.scoped(st.c) {
		if _, e := ck.scope_to(st.c, x, fmt.tprintf("%s · desktop", st.host), "device"); !ck.ok(e) {
			reload(st)
			return e
		}
	}
	reload(st)
	return {}
}

// act_delegate mints a session for one identity and keeps it apart from
// this machine's own, under delegated/, to be handed to the program that
// will hold it: PALM_CLOUD_SESSION=<path> <program>.
act_delegate :: proc(st: ^St, x: ck.Identity, name, kind: string, expires_in: int) -> (ck.Minted, ck.Error) {
	m, e := ck.scope_to(st.c, x, name, kind, expires_in, .Delegated)
	reload(st)
	return m, e
}

act_revoke :: proc(st: ^St, device_id: string) -> ck.Error {
	// If this machine holds the session being revoked, forget it too.
	handle := ""
	for d in st.devs {
		if d.id == device_id {
			if x, found := ck.find_identity(st.ids, d.identity_id); found {
				handle = x.handle
			}
		}
	}
	e := ck.revoke_device(st.c, device_id)
	if ck.ok(e) && handle != "" {
		os.remove(ck.delegated_path(st.c, handle, device_id, context.temp_allocator))
		forget_if_revoked(st, handle)
	}
	reload(st)
	return e
}

// forget_if_revoked drops a stored scoped session the server no longer
// honours: it tries to refresh it, and cloudkit forgets it on refusal.
forget_if_revoked :: proc(st: ^St, handle: string) {
	sc, oerr := ck.open(url = st.c.url_text, anon_key = st.c.anon_key, dir = st.c.dir, scope = handle, app = "accounts")
	defer ck.close(sc)
	if ck.ok(oerr) && ck.signed_in(sc) {
		ck.refresh(sc)
	}
}

act_end_session :: proc(st: ^St, session_id: string) -> ck.Error {
	e := ck.end_session(st.c, session_id)
	reload(st)
	return e
}

act_sign_out :: proc(st: ^St) -> ck.Error {
	e := ck.sign_out(st.c)
	reload(st)
	return e
}

// ---------------------------------------------------------------------------
// Small helpers the window and the CLI share
// ---------------------------------------------------------------------------

// handle_from turns a display name into a suggested handle: lower case,
// spaces to dots, everything else dropped.
handle_from :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	last_dot := true
	for r in strings.to_lower(name, context.temp_allocator) {
		switch {
		case (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9'):
			strings.write_rune(&b, r)
			last_dot = false
		case r == ' ' || r == '.' || r == '-' || r == '_':
			if !last_dot {
				strings.write_byte(&b, '.')
				last_dot = true
			}
		}
		if strings.builder_len(b) >= 40 {
			break
		}
	}
	return strings.trim_right(strings.to_string(b), ".")
}

initials :: proc(name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for word in strings.fields(name, context.temp_allocator) {
		for r in word {
			strings.write_rune(&b, r)
			break
		}
		n += 1
		if n == 2 {
			break
		}
	}
	if n == 0 {
		return "?"
	}
	return strings.to_upper(strings.to_string(b), context.temp_allocator)
}

identity_name :: proc(st: ^St, id: string) -> (ck.Identity, bool) {
	return ck.find_identity(st.ids, id)
}

kind_label :: proc(kind: string) -> string {
	switch kind {
	case "personal":
		return kit.tr("Personal")
	case "work":
		return kit.tr("Work")
	case "public":
		return kit.tr("Public")
	case "project":
		return kit.tr("Project")
	}
	return kind
}

// short_time renders a Postgres timestamp as "19 Oct, 10:04".
short_time :: proc(ts: string) -> string {
	if len(ts) < 16 {
		return ts == "" ? "—" : ts
	}
	months := [?]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	mo := int(ts[5] - '0') * 10 + int(ts[6] - '0')
	day := ts[8:10]
	if day[0] == '0' {
		day = day[1:]
	}
	if mo < 1 || mo > 12 {
		return ts
	}
	return fmt.tprintf("%s %s, %s", day, kit.tr(months[mo - 1]), ts[11:16])
}
