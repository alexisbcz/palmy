package main

// The actions: everything the window and the command line both do. Each is
// one cloudkit call, or one run of another program's own command line, so
// the welcome app never re-implements what a service does to set itself up:
//
//	drive      PALM_IDENTITY=<h> palm-drive sync      (and `watch` after)
//	mail       the identity's mailboxes (mail_bootstrap, scoped), then
//	           mailcore palm login / sync for this computer
//	calendar   PALM_IDENTITY=<h> calendar sync, contacts sync
//	notes      PALM_IDENTITY=<h> notes sync           (when notes has it)
//	chat       PALM_IDENTITY=<h> chat whoami
//	passwords  vault setup (or vault enroll), with the master password in
//	           the environment, never on a command line
//
// Each child runs with PALM_IDENTITY set to the one identity it is for, and
// with this computer's session scoped to that identity minted first, so a
// service cannot reach another identity's data even if it tried: the
// database refuses it. That is the "nothing crosses identities silently"
// rule, enforced by the same mechanism every app uses.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."

// ---------------------------------------------------------------------------
// Appearance and language
// ---------------------------------------------------------------------------

// theme_from_environment: PALM_THEME, then the saved appearance, then dark,
// which is what the installer just showed, so install and first run read as
// one continuous thing.
theme_from_environment :: proc() -> bool {
	for name in ([?]string{"PALMY_THEME", "PALM_THEME"}) {
		switch os.get_env(name, context.temp_allocator) {
		case "dark":
			return true
		case "light":
			return false
		}
	}
	// The last `theme =` line in wm.conf wins, as it does for the wm. With no
	// explicit choice the welcome starts dark, like the installer before it.
	dark, found := true, false
	if text, ok := read_text(appearance_path()); ok {
		for line in strings.split_lines(text, context.temp_allocator) {
			if val, is := theme_value(line); is {
				dark, found = val == "dark", true
			}
		}
	}
	_ = found
	return dark
}

// theme_value is the value of a `theme = dark|light` line, comment removed.
theme_value :: proc(line: string) -> (string, bool) {
	l := strings.trim_space(line)
	if !strings.has_prefix(l, "theme") {
		return "", false
	}
	rest := strings.trim_space(l[len("theme"):])
	if !strings.has_prefix(rest, "=") {
		return "", false
	}
	val := strings.trim_space(rest[1:])
	if i := strings.index_byte(val, '#'); i >= 0 {
		val = strings.trim_space(val[:i])
	}
	val = strings.to_lower(val, context.temp_allocator)
	return val, val == "dark" || val == "light"
}

// save_appearance sets the theme line in wm.conf, keeping every other line:
// an existing theme line is replaced in place, otherwise one is appended.
save_appearance :: proc(dark: bool) -> bool {
	want := fmt.tprintf("theme = %s", dark ? "dark" : "light")
	b := strings.builder_make(context.temp_allocator)
	replaced := false
	if text, ok := read_text(appearance_path()); ok {
		lines := strings.split_lines(strings.trim_right(text, "\n"), context.temp_allocator)
		for line in lines {
			if _, is := theme_value(line); is {
				if !replaced {
					strings.write_string(&b, want)
					strings.write_byte(&b, '\n')
					replaced = true
				}
				continue
			}
			strings.write_string(&b, line)
			strings.write_byte(&b, '\n')
		}
	}
	if !replaced {
		strings.write_string(&b, want)
		strings.write_byte(&b, '\n')
	}
	return write_text(appearance_path(), strings.to_string(b))
}

save_language :: proc(code: string) -> bool {
	return write_text(locale_conf_path(), fmt.tprintf("# Written by welcome: this person's language (locale.conf(5)).\nLANG=%s.UTF-8\n", code))
}

// ---------------------------------------------------------------------------
// The cloud
// ---------------------------------------------------------------------------

// open_cloud opens the token store (no network), against `url` or whatever
// the environment and cloudkit's config.json say.
open_cloud :: proc(st: ^St, url := "") -> ck.Error {
	if st.c != nil {
		ck.close(st.c)
		st.c = nil
	}
	c, e := ck.open(url = url, app = "welcome")
	st.c = c
	if !ck.ok(e) {
		return e
	}
	clear(&st.url_buf)
	append(&st.url_buf, ..transmute([]u8)c.url_text)
	st.signed_in = ck.signed_in(c)
	delete(st.email)
	st.email = st.signed_in ? strings.clone(c.session.email) : ""
	return {}
}

// open_store is the start of a run: if this computer is already signed in
// (the welcome being run again), the account choice is already made.
open_store :: proc(st: ^St) {
	if st.opts.fixture {
		return
	}
	if e := open_cloud(st); ck.ok(e) && st.signed_in {
		st.choice = .Account
	}
}

// refresh_account reads what the token store says, and, signed in, the
// identities on the account and the mail domain.
refresh_account :: proc(st: ^St) {
	st.signed_in = st.c != nil && ck.signed_in(st.c)
	delete(st.email)
	st.email = ""
	if !st.signed_in {
		return
	}
	st.email = strings.clone(st.c.session.email)
	if v, e := ck.rpc(st.c, "mail_default_domain", "{}", context.temp_allocator); ck.ok(e) {
		if s, is := v.(string); is && s != "" {
			delete(st.domain)
			st.domain = strings.clone(s)
		}
	}
	load_existing(st)
}

// load_existing puts every identity already on the account in front of the
// plans this run makes, with the choices sync.conf remembers for it.
load_existing :: proc(st: ^St) {
	ids, e := ck.identities(st.c, context.temp_allocator)
	if !ck.ok(e) {
		return
	}
	remembered, _ := read_sync_conf()
	for x in ids {
		if x.archived {
			continue
		}
		found := false
		for &pl in st.plans {
			if plan_handle(&pl) == x.handle {
				found = true
				pl.existing = true
				delete(pl.id)
				pl.id = strings.clone(x.id)
			}
		}
		if found {
			continue
		}
		pl := Plan{existing = true, id = strings.clone(x.id)}
		append(&pl.name, ..transmute([]u8)x.display_name)
		append(&pl.handle, ..transmute([]u8)x.handle)
		pl.handle_touched = true
		pl.kind = kind_index(x.kind)
		pl.color = palette_index(x.color)
		pl.services = kind_default_services(x.kind)
		for en in remembered.entries {
			if en.handle == x.handle {
				pl.services = en.services
			}
		}
		// Existing identities go before new rows, in the server's order.
		n := 0
		for &q in st.plans {
			if q.existing {
				n += 1
			}
		}
		inject_at(&st.plans, n, pl)
	}
}

kind_index :: proc(kind: string) -> int {
	for k, i in KINDS {
		if k == kind {
			return i
		}
	}
	return 0
}

err_text :: proc(e: ck.Error) -> string {
	switch e.kind {
	case .Unavailable:
		return tr("The Palmy server is not reachable. Check the address, or continue without an account.")
	case .Unauthorized:
		if e.code == "invalid_credentials" {
			return tr("That email and password do not match.")
		}
		return tr("The server refused the session. Sign in again.")
	case .Conflict:
		return tr("That is already taken.")
	case .Invalid:
		switch e.code {
		case "user_already_exists", "email_exists":
			return tr("An account with this email already exists. Sign in instead.")
		case "weak_password":
			return tr("The server wants a stronger password.")
		case "confirmation_required":
			return tr("The account was created. Confirm your email address, then sign in.")
		}
	case .Out_Of_Scope:
		return tr("Refused: this session acts for one identity only.")
	case .None, .Not_Signed_In, .Not_Found, .Failed:
	}
	if strings.contains(e.message, "already") {
		return tr("An account with this email already exists. Sign in instead.")
	}
	return e.message
}

do_sign_in :: proc(st: ^St) -> string {
	e := ck.sign_in(st.c, strings.trim_space(string(st.email_buf[:])), string(st.pw_buf[:]))
	if !ck.ok(e) {
		return err_text(e)
	}
	refresh_account(st)
	return ""
}

// do_sign_up creates the account. The first identity is created on the next
// page, with its handle chosen there; the account is never left with none
// for longer than this flow, because the next page cannot be passed without
// one (and resumes there if the window is closed in between).
do_sign_up :: proc(st: ^St) -> string {
	e := ck.sign_up(st.c, strings.trim_space(string(st.email_buf[:])), string(st.pw_buf[:]))
	if !ck.ok(e) {
		return err_text(e)
	}
	refresh_account(st)
	return ""
}

// do_identities creates every new row. A row the server refuses keeps its
// reason and stays editable; the rest are created all the same.
do_identities :: proc(st: ^St) -> (failed: int) {
	for &pl in st.plans {
		if pl.existing {
			continue
		}
		delete(pl.err)
		pl.err = ""
		x, e := ck.create_identity(st.c, plan_handle(&pl), plan_name(&pl), KINDS[pl.kind], PALETTE[pl.color].name, context.temp_allocator)
		if !ck.ok(e) {
			msg := err_text(e)
			if e.kind == .Conflict || strings.contains(e.message, "duplicate") {
				msg = tr("Someone already has this handle. Try another.")
			} else if strings.contains(e.message, "reserved") {
				msg = tr("That handle is reserved.")
			}
			pl.err = strings.clone(msg)
			failed += 1
			continue
		}
		pl.existing = true
		pl.id = strings.clone(x.id)
	}
	// The first personal identity becomes the current one, which is what the
	// shell's switcher shows first.
	if ck.current_identity(st.c, context.temp_allocator) == "" {
		for &pl in st.plans {
			if pl.existing {
				ck.set_current_identity(st.c, plan_handle(&pl))
				break
			}
		}
	}
	return
}

identity_of :: proc(pl: ^Plan) -> ck.Identity {
	return ck.Identity{id = pl.id, handle = plan_handle(pl), display_name = plan_name(pl), kind = KINDS[pl.kind], color = PALETTE[pl.color].name}
}

// ensure_scoped makes sure this computer holds a session scoped to the
// identity, as `accounts switch` does. Every service below runs on it.
ensure_scoped :: proc(st: ^St, pl: ^Plan) -> string {
	if os.exists(ck.scoped_path(st.c, plan_handle(pl), context.temp_allocator)) {
		return ""
	}
	host := ck.machine_name()
	if host == "" {
		host = "this computer"
	}
	if _, e := ck.scope_to(st.c, identity_of(pl), fmt.tprintf("%s · desktop", host), "device"); !ck.ok(e) {
		return e.message
	}
	return ""
}

// ---------------------------------------------------------------------------
// Running another program's command line
// ---------------------------------------------------------------------------

Run :: struct {
	found: bool,
	code:  int,
	out:   string,
	err:   string,
}

// find_tool looks a program up in $WELCOME_BIN_DIR (tests point it at a
// build tree) and then $PATH.
find_tool :: proc(name: string) -> (string, bool) {
	dirs := make([dynamic]string, context.temp_allocator)
	if d := os.get_env("WELCOME_BIN_DIR", context.temp_allocator); d != "" {
		for x in strings.split(d, ":", context.temp_allocator) {
			append(&dirs, x)
		}
	}
	path := os.get_env("PATH", context.temp_allocator)
	if path == "" {
		path = "/usr/local/bin:/usr/bin:/bin"
	}
	for x in strings.split(path, ":", context.temp_allocator) {
		append(&dirs, x)
	}
	for d in dirs {
		if d == "" {
			continue
		}
		p := fmt.tprintf("%s/%s", d, name)
		if fi, err := os.stat(p, context.temp_allocator); err == nil && fi.type == .Regular && .Execute_User in fi.mode {
			return p, true
		}
	}
	return "", false
}

// run_tool runs `name args...` with PALM_IDENTITY set to `scope` (or unset)
// and `extra` added to the environment, and waits for it.
run_tool :: proc(st: ^St, name: string, args: []string, scope := "", extra: []string = nil) -> Run {
	bin, ok := find_tool(name)
	if !ok {
		return {found = false}
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, bin)
	append(&argv, ..args)
	if why := kit.cli_guard_check(argv[:]); why != "" {
		return {found = true, code = kit.EXIT_FAILED, err = why}
	}
	env := make([dynamic]string, context.temp_allocator)
	base, _ := os.environ(context.temp_allocator)
	for e in base {
		if strings.has_prefix(e, "PALM_IDENTITY=") || strings.has_prefix(e, "PALM_CLOUD_SESSION=") || strings.has_prefix(e, "PALM_CLOUD_URL=") {
			continue
		}
		append(&env, e)
	}
	if scope != "" {
		append(&env, fmt.tprintf("PALM_IDENTITY=%s", scope))
	}
	if st.c != nil {
		// The server chosen here, whatever the environment said before.
		append(&env, fmt.tprintf("PALM_CLOUD_URL=%s", st.c.url_text))
	}
	append(&env, ..extra)
	state, sout, serr, err := os.process_exec({command = argv[:], env = env[:]}, context.temp_allocator)
	if err != nil {
		return {found = true, code = -1, err = fmt.tprintf("%v", err)}
	}
	return {found = true, code = state.exit_code, out = string(sout), err = string(serr)}
}

// spawn_tool starts a long-running program and does not wait for it.
spawn_tool :: proc(st: ^St, name: string, args: []string, scope := "") -> bool {
	bin, ok := find_tool(name)
	if !ok {
		return false
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, bin)
	append(&argv, ..args)
	if kit.cli_guard_check(argv[:]) != "" {
		return false
	}
	env := make([dynamic]string, context.temp_allocator)
	base, _ := os.environ(context.temp_allocator)
	for e in base {
		if !strings.has_prefix(e, "PALM_IDENTITY=") && !strings.has_prefix(e, "PALM_CLOUD_SESSION=") {
			append(&env, e)
		}
	}
	if scope != "" {
		append(&env, fmt.tprintf("PALM_IDENTITY=%s", scope))
	}
	_, err := os.process_start({command = argv[:], env = env[:]})
	return err == nil
}

// tilde shortens a path in the home directory for display.
tilde :: proc(path: string) -> string {
	h := home_dir()
	if h != "" && h != "/" && strings.has_prefix(path, h) {
		return fmt.tprintf("~%s", path[len(h):])
	}
	return path
}

last_line :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if i := strings.last_index_byte(t, '\n'); i >= 0 {
		t = t[i + 1:]
	}
	if len(t) > 160 {
		t = t[:160]
	}
	return t
}

// json_reason pulls "error"/"detail" out of a kit CLI's --json failure.
json_reason :: proc(r: Run) -> string {
	for text in ([?]string{r.out, r.err}) {
		if v, ok := ck.parse(strings.trim_space(text), context.temp_allocator); ok {
			if d := ck.get_str(v, "detail"); d != "" {
				return d
			}
			if d := ck.get_str(v, "error"); d != "" {
				return d
			}
		}
	}
	return last_line(r.err != "" ? r.err : r.out)
}

// outcome maps a kit CLI's exit code onto a task state.
outcome :: proc(r: Run) -> (Task_State, string) {
	if !r.found {
		return .Not_Installed, ""
	}
	switch r.code {
	case kit.EXIT_OK:
		return .Done, ""
	case kit.EXIT_UNAVAILABLE:
		return .Pending_Server, json_reason(r)
	case kit.EXIT_USAGE:
		// An unknown verb: the program has no such command yet.
		if strings.contains(r.err, "unknown") || strings.contains(r.out, "unknown") {
			return .Coming, ""
		}
	}
	reason := json_reason(r)
	low := strings.to_lower(reason, context.temp_allocator)
	if strings.contains(low, "refused") || strings.contains(low, "connect") || strings.contains(low, "not reachable") || strings.contains(low, "unreachable") {
		return .Pending_Server, reason
	}
	return .Failed, reason
}

// ---------------------------------------------------------------------------
// The vault
// ---------------------------------------------------------------------------

// do_vault creates the account vault: one Secret Key for the account, a
// separate vault per identity. The master password goes to `vault` in its
// environment (PALM_VAULT_PASSWORD), never on a command line where `ps`
// would show it.
do_vault :: proc(st: ^St) -> string {
	r := run_tool(st, "vault", {"setup", "--json"}, "", {fmt.tprintf("PALM_VAULT_PASSWORD=%s", string(st.vault_pw[:]))})
	if !r.found {
		return tr("The vault is not installed on this computer.")
	}
	if r.code != 0 {
		reason := json_reason(r)
		if strings.contains(reason, "already exists") || strings.contains(reason, "already enrolled") {
			st.vault_enroll = true
			return tr("Your account already has a vault. Enter the Secret Key from your Emergency Kit to add this computer to it.")
		}
		return reason
	}
	v, ok := ck.parse(strings.trim_space(r.out), context.temp_allocator)
	if !ok || ck.get_str(v, "secret_key") == "" {
		return tr("The vault did not return a Secret Key.")
	}
	delete(st.secret)
	st.secret = strings.clone(ck.get_str(v, "secret_key"))
	st.vault_done = true
	return ""
}

// do_vault_enroll adds this computer to a vault that exists already, with
// the Secret Key the person typed from their kit. It passes through a 0600
// file that is removed at once, because `vault` reads it from a file.
do_vault_enroll :: proc(st: ^St) -> string {
	dir := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if dir == "" {
		dir = fmt.tprintf("%s/.cache", home_dir())
	}
	f := fmt.tprintf("%s/welcome-secret-%d", dir, os.get_pid())
	if !write_text(f, strings.trim_space(string(st.secret_buf[:])), private = true) {
		return tr("Could not hand the Secret Key to the vault.")
	}
	r := run_tool(st, "vault", {"enroll", "--secret-key-file", f, "--json"})
	os.remove(f)
	if !r.found {
		return tr("The vault is not installed on this computer.")
	}
	if r.code != 0 {
		return json_reason(r)
	}
	st.vault_done = true
	return ""
}

// do_kit writes the emergency kit: a printable PNG and the same as text,
// rendered by this binary in a process of its own (`welcome kit`), so the
// window's frame is never interrupted by an offscreen render.
do_kit :: proc(st: ^St, dir: string) -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		rt = fmt.tprintf("%s/.cache", home_dir())
	}
	f := fmt.tprintf("%s/welcome-kit-%d", rt, os.get_pid())
	if !write_text(f, st.secret, private = true) {
		return tr("Could not write the Emergency Kit.")
	}
	defer os.remove(f)
	self := os.args[0]
	if !strings.contains(self, "/") {
		if p, ok := find_tool(self); ok {
			self = p
		}
	}
	argv := []string{self, "kit", "--secret-key-file", f, "--email", st.email, "--url", st.c != nil ? st.c.url_text : "", "--out-dir", dir, "--lang", LANGUAGES[st.lang_i].code, "--json"}
	state, sout, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	if err != nil || state.exit_code != 0 {
		return fmt.tprintf("%s %s", tr("Could not write the Emergency Kit."), last_line(string(serr)))
	}
	v, ok := ck.parse(strings.trim_space(string(sout)), context.temp_allocator)
	if !ok {
		return tr("Could not write the Emergency Kit.")
	}
	delete(st.kit_paths[0])
	delete(st.kit_paths[1])
	st.kit_paths[0] = strings.clone(ck.get_str(v, "png"))
	st.kit_paths[1] = strings.clone(ck.get_str(v, "txt"))
	return ""
}

// ---------------------------------------------------------------------------
// The services
// ---------------------------------------------------------------------------

// plan_tasks lays out what the Setup page will do, before it does any of it,
// so the page can show the whole list first and nothing happens unseen.
plan_tasks :: proc(st: ^St) {
	clear(&st.tasks)
	append(&st.tasks, Task{what = .Sync_Conf})
	for &pl in st.plans {
		if !pl.existing || pl.services == {} {
			continue
		}
		h := strings.clone(plan_handle(&pl))
		append(&st.tasks, Task{handle = h, what = .Session})
		if .Mail in pl.services {
			append(&st.tasks, Task{handle = h, what = .Mailbox})
		}
		if .Drive in pl.services {
			append(&st.tasks, Task{handle = h, what = .Drive})
		}
		if .Calendar in pl.services {
			append(&st.tasks, Task{handle = h, what = .Calendar})
			append(&st.tasks, Task{handle = h, what = .Contacts})
		}
		if .Notes in pl.services {
			append(&st.tasks, Task{handle = h, what = .Notes})
		}
		if .Chat in pl.services {
			append(&st.tasks, Task{handle = h, what = .Chat})
		}
		if .Passwords in pl.services {
			append(&st.tasks, Task{handle = h, what = .Vault})
		}
	}
	if any_service(st, .Mail) {
		append(&st.tasks, Task{what = .Mail_Client})
	}
}

set_task :: proc(st: ^St, i: int, state: Task_State, detail := "") {
	lock(st)
	defer unlock(st)
	st.tasks[i].state = state
	delete(st.tasks[i].detail)
	st.tasks[i].detail = strings.clone(detail)
}

find_plan :: proc(st: ^St, handle: string) -> ^Plan {
	for &pl in st.plans {
		if plan_handle(&pl) == handle {
			return &pl
		}
	}
	return nil
}

// do_services runs every task in order. A task that cannot finish says why
// and the rest go on: a mail server that is down does not stop the drive.
do_services :: proc(st: ^St) {
	session_ok := make(map[string]bool, context.temp_allocator)
	for i in 0 ..< len(st.tasks) {
		t := st.tasks[i]
		set_task(st, i, .Running)
		pl := t.handle != "" ? find_plan(st, t.handle) : nil
		if t.handle != "" && t.what != .Session && !session_ok[t.handle] {
			set_task(st, i, .Skipped, tr("No session for this identity on this computer."))
			continue
		}
		switch t.what {
		case .Sync_Conf:
			if write_text(sync_conf_path(), sync_conf_text("account", st.c.url_text, st.plans[:])) {
				set_task(st, i, .Done, tilde(sync_conf_path()))
			} else {
				set_task(st, i, .Failed, sync_conf_path())
			}
		case .Session:
			if e := ensure_scoped(st, pl); e != "" {
				set_task(st, i, .Failed, e)
			} else {
				session_ok[t.handle] = true
				set_task(st, i, .Done)
			}
		case .Mailbox:
			// Scoped to the identity: mail_bootstrap provisions the mailboxes
			// of what the session can reach, which is this identity alone.
			sc, oe := ck.open(url = st.c.url_text, anon_key = st.c.anon_key, dir = st.c.dir, scope = t.handle, app = "welcome")
			if !ck.ok(oe) || !ck.signed_in(sc) {
				set_task(st, i, .Failed, oe.message)
			} else if _, e := ck.rpc(sc, "mail_bootstrap", "{}", context.temp_allocator); !ck.ok(e) {
				set_task(st, i, e.kind == .Unavailable ? .Pending_Server : .Failed, e.message)
			} else {
				set_task(st, i, .Done, fmt.tprintf("%s@%s", t.handle, st.domain))
			}
			ck.close(sc)
		case .Drive:
			r := run_tool(st, "palm-drive", {"sync", "--json"}, t.handle)
			state, why := outcome(r)
			if state == .Done {
				why = fmt.tprintf("~/Drive/%s", t.handle)
				if st.opts.spawn {
					spawn_tool(st, "palm-drive", {"watch"}, t.handle)
				}
			}
			set_task(st, i, state, why)
		case .Calendar:
			state, why := outcome(run_tool(st, "calendar", {"sync", "--json"}, t.handle))
			set_task(st, i, state, why)
		case .Contacts:
			state, why := outcome(run_tool(st, "contacts", {"sync", "--json"}, t.handle))
			set_task(st, i, state, why)
		case .Notes:
			state, why := outcome(run_tool(st, "notes", {"sync", "--json"}, t.handle))
			set_task(st, i, state, why)
		case .Chat:
			state, why := outcome(run_tool(st, "chat", {"whoami", "--json"}, t.handle))
			set_task(st, i, state, why)
		case .Vault:
			if st.vault_done {
				set_task(st, i, .Done)
			} else {
				set_task(st, i, .Skipped, tr("The vault was not set up."))
			}
		case .Mail_Client:
			state, why := mail_client(st)
			set_task(st, i, state, why)
		}
	}
}

// Mail on this computer: mailcore signs in once for the account and syncs
// every identity whose mailboxes exist. Its ports are the mail server's
// (cloud/mail): PALM_MAIL_AUTH_PORT (GoTrue itself, not the gateway; on a
// cloud/dev stack that is the gateway's port + 10), PALM_MAIL_JMAP_PORT and
// PALM_MAIL_SUBMIT_PORT, else mailcore's own defaults.
mail_client :: proc(st: ^St) -> (Task_State, string) {
	pw := string(st.pw_buf[:])
	if pw == "" {
		pw = string(st.mail_pw_buf[:])
	}
	if pw == "" {
		return .Skipped, tr("Mail needs your account password once. Run the welcome again to finish it.")
	}
	auth := os.get_env("PALM_MAIL_AUTH_PORT", context.temp_allocator)
	if auth == "" && st.c != nil && st.c.url.port != 0 && (st.c.url.host == "127.0.0.1" || st.c.url.host == "localhost") {
		auth = fmt.tprintf("%d", st.c.url.port + 10)
	}
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		rt = fmt.tprintf("%s/.cache", home_dir())
	}
	f := fmt.tprintf("%s/welcome-mail-%d", rt, os.get_pid())
	if !write_text(f, pw, private = true) {
		return .Failed, ""
	}
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "palm", "login", "--email", st.email, "--password-file", f)
	if auth != "" {
		append(&args, "--auth-port", auth)
	}
	login := run_tool(st, "mailcore", args[:])
	os.remove(f)
	if !login.found {
		return .Not_Installed, ""
	}
	if login.code != 0 {
		return .Pending_Server, last_line(login.err)
	}
	sargs := make([dynamic]string, context.temp_allocator)
	append(&sargs, "palm", "sync")
	if v := os.get_env("PALM_MAIL_JMAP_PORT", context.temp_allocator); v != "" {
		append(&sargs, "--jmap-port", v)
	}
	if v := os.get_env("PALM_MAIL_SUBMIT_PORT", context.temp_allocator); v != "" {
		append(&sargs, "--submit-port", v)
	}
	sync := run_tool(st, "mailcore", sargs[:])
	if sync.code != 0 {
		return .Pending_Server, last_line(sync.err != "" ? sync.err : sync.out)
	}
	n := 0
	for line in strings.split_lines(sync.out, context.temp_allocator) {
		if strings.contains(line, " messages;") {
			n += 1
		}
	}
	return .Done, trf("%d mailboxes on this computer", n)
}

// finish writes what the flow decided: the marker, and in local-only mode a
// sync.conf that says so (nothing else needs writing there).
finish :: proc(st: ^St) -> bool {
	if st.opts.fixture {
		return true
	}
	if st.mode != .Account {
		if !os.exists(sync_conf_path()) {
			write_text(sync_conf_path(), sync_conf_text("local", "", nil))
		}
	}
	mode := st.mode == .Account ? "account" : "local"
	return write_marker(mode)
}

parse_int :: proc(s: string, def: int) -> int {
	if n, ok := strconv.parse_int(s, 10); ok {
		return n
	}
	return def
}
