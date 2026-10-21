package main

// The command line: `welcome <verb>`, or `palm welcome <verb>`. The window
// and `setup` run the same procedures (core.odin), in the same order.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "whether the welcome was finished on this computer, and what was chosen",
		effect = .Read,
		out = {
			{name = "done", kind = .Bool},
			{name = "completed_at", kind = .String, opt = true},
			{name = "mode", kind = .String, help = "account, local, or \"\" when not finished"},
			{name = "marker", kind = .String, help = "the file that says it was finished"},
			{name = "signed_in", kind = .Bool},
			{name = "email", kind = .String, opt = true},
			{name = "url", kind = .String, help = "the Palmy server"},
			{name = "theme", kind = .String},
			{
				name = "identities",
				kind = .Array,
				help = "from sync.conf: what this computer keeps in sync, per identity",
				of = {{name = "handle", kind = .String}, {name = "services", kind = .Array, of = {{kind = .String}}}},
			},
		},
		examples = {"welcome status --json"},
		run = cmd_status,
	},
	{
		verb = "run",
		summary = "open the welcome window",
		effect = .Mutate,
		flags = {
			{name = "first-login", kind = .Bool, help = "do nothing if it was finished before (what session.d runs)"},
			{name = "lang", kind = .String, help = "start in this language, e.g. fr_FR"},
			{name = "theme", kind = .Enum, values = {"light", "dark"}, help = "start in this appearance"},
		},
		out = {{name = "shown", kind = .Bool}},
		examples = {"welcome run", "welcome run --first-login"},
		run = cmd_run,
	},
	{
		verb = "reset",
		summary = "forget that the welcome was finished, so it opens at the next login; the account and choices stay",
		effect = .Destructive,
		out = {{name = "removed", kind = .Bool}, {name = "marker", kind = .String}},
		examples = {"welcome reset --yes --json"},
		run = cmd_reset,
	},
	{
		verb = "setup",
		summary = "the whole flow without a window: account, identities, what syncs, the vault, the services",
		effect = .Mutate,
		flags = {
			{name = "local", kind = .Bool, help = "use this computer only: no account"},
			{name = "url", kind = .String, help = "the Palmy server (default: $PALM_CLOUD_URL, cloudkit's config, the local stack)"},
			{name = "email", kind = .String},
			{name = "password-file", kind = .Path, help = "the account password"},
			{name = "create", kind = .Bool, help = "create the account rather than sign in"},
			{name = "name", kind = .String, help = "your name, with --create"},
			{name = "identities", kind = .String, help = "new identities: handle:kind:colour:Display Name, separated by ;"},
			{name = "sync", kind = .String, help = "per identity: handle=mail,drive,calendar,notes,passwords,chat, separated by ;"},
			{name = "vault-password-file", kind = .Path, help = "the vault's master password, when passwords sync"},
			{name = "secret-key-file", kind = .Path, help = "the Secret Key, to join a vault the account already has"},
			{name = "kit-dir", kind = .Path, help = "where to save the Emergency Kit (default ~/Documents)"},
			{name = "lang", kind = .String, help = "save this language for the person, e.g. fr_FR"},
			{name = "theme", kind = .Enum, values = {"light", "dark"}},
			{name = "start-daemons", kind = .Bool, help = "start palm-drive watch for each drive, as the window does"},
			{name = "finish", kind = .Bool, help = "write the marker, as the Done page does"},
		},
		out = {
			{name = "mode", kind = .String},
			{name = "email", kind = .String, opt = true},
			{name = "identities", kind = .Array, of = {{name = "handle", kind = .String}, {name = "address", kind = .String}, {name = "kind", kind = .String}, {name = "color", kind = .String}, {name = "created", kind = .Bool}, {name = "services", kind = .Array, of = {{kind = .String}}}, {name = "error", kind = .String, opt = true}}},
			{name = "tasks", kind = .Array, of = {{name = "identity", kind = .String}, {name = "task", kind = .String}, {name = "state", kind = .String}, {name = "detail", kind = .String}}},
			{name = "vault", kind = .Object, opt = true},
			{name = "finished", kind = .Bool},
		},
		examples = {
			"welcome setup --local --finish --json",
			"welcome setup --create --email camille@example.org --name \"Camille Roux\" --password-file pw --identities \"camille:personal:teal:Camille Roux;camille.nw:work:blue:Camille at Northwind\" --sync \"camille=mail,drive,passwords;camille.nw=mail,drive\" --vault-password-file vpw --finish --json",
		},
		run = cmd_setup,
	},
	{
		verb = "kit",
		summary = "write an Emergency Kit (PNG and text) for a Secret Key",
		effect = .Mutate,
		hidden = true,
		flags = {
			{name = "secret-key-file", kind = .Path, required = true},
			{name = "email", kind = .String},
			{name = "url", kind = .String},
			{name = "out-dir", kind = .Path, required = true},
			{name = "lang", kind = .String},
		},
		out = {{name = "png", kind = .String}, {name = "txt", kind = .String}},
		examples = {"welcome kit --secret-key-file key --email a@b.org --out-dir ~/Documents --json"},
		run = cmd_kit,
	},
	{
		verb = "shots",
		summary = "render every step offscreen into PNGs, light and dark",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, required = true}},
		flags = {{name = "lang", kind = .String, help = "only this language, e.g. ar"}},
		out = {{name = "dir", kind = .String}, {name = "count", kind = .Int}},
		examples = {"welcome shots /tmp/welcome-shots"},
		run = cmd_shots,
	},
	{
		verb = "drive",
		summary = "run the whole window offscreen, typing the keys a person would, against a live server",
		effect = .Mutate,
		hidden = true,
		flags = {
			{name = "local", kind = .Bool, help = "take the local-only path"},
			{name = "email", kind = .String},
			{name = "shots", kind = .Path, help = "write a PNG of every step as it is reached"},
			{name = "lang", kind = .String},
			{name = "theme", kind = .Enum, values = {"light", "dark"}},
		},
		out = {{name = "steps", kind = .Array, of = {{kind = .String}}}, {name = "finished", kind = .Bool}, {name = "keys", kind = .Int}},
		examples = {"welcome drive --email e2e@palm.test --shots /tmp/drive --json"},
		run = cmd_drive,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "welcome",
			summary  = "Palmy's first run: account, identities, what syncs",
			gui      = true,
			selftest = selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The window opens once per person, at the first login
(/etc/palm/session.d/90-welcome runs "welcome run --first-login"), until it
is finished. "welcome reset --yes" makes it open again; "welcome run" opens
it now.

What it writes: the marker ($XDG_STATE_HOME/palm/welcome/done), the choices
per identity ($XDG_CONFIG_HOME/palm/sync.conf, which
/etc/palm/session.d/60-palm-drive reads), the appearance
($XDG_CONFIG_HOME/palmy/wm.conf, its theme line) and, when changed, the language
($XDG_CONFIG_HOME/locale.conf). The account and its sessions are cloudkit's
($PALM_CLOUD_DIR). Each service is set up by its own command line, with
PALM_IDENTITY set to one identity: palm-drive, vault, mailcore, calendar,
contacts, notes, chat. $WELCOME_BIN_DIR is searched before $PATH.

Mail on this computer signs in through mailcore with the account password,
on GoTrue's own port: $PALM_MAIL_AUTH_PORT, else the gateway's port + 10 on
a local cloud/dev stack. $PALM_MAIL_JMAP_PORT and $PALM_MAIL_SUBMIT_PORT
name the mail server's ports.`


// private_temp gives a verb that draws frames its own temporary allocator.
// Every frame (windowed or offscreen) frees the temporary allocator, and
// the kit keeps the call's own strings there until it writes the audit
// record after the verb returns.
private_temp :: proc(a: ^virtual.Arena) -> mem.Allocator {
	_ = virtual.arena_init_growing(a)
	return virtual.arena_allocator(a)
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

cmd_status :: proc(c: ^kit.Call) -> int {
	m := read_marker()
	kit.jset_bool(c.out, "done", m.done)
	if m.done {
		kit.jset_str(c.out, "completed_at", m.completed_at)
	}
	kit.jset_str(c.out, "mode", m.mode)
	kit.jset_str(c.out, "marker", marker_path())
	cl, e := ck.open(app = "welcome")
	signed := ck.ok(e) && ck.signed_in(cl)
	kit.jset_bool(c.out, "signed_in", signed)
	if signed {
		kit.jset_str(c.out, "email", cl.session.email)
	}
	kit.jset_str(c.out, "url", cl != nil ? cl.url_text : "")
	kit.jset_str(c.out, "theme", theme_from_environment() ? "dark" : "light")
	arr := kit.jarr()
	if sc, ok := read_sync_conf(); ok {
		for en in sc.entries {
			o := kit.jobj()
			kit.jset_str(o, "handle", en.handle)
			kit.jset(o, "services", services_json(en.services))
			kit.jpush(arr, o)
		}
	}
	kit.jset(c.out, "identities", arr)
	if !c.json {
		if m.done {
			fmt.printfln("finished %s (%s)", m.completed_at, m.mode)
		} else {
			fmt.println("not finished: it opens at the next login")
		}
	}
	return kit.EXIT_OK
}

services_json :: proc(s: Services) -> ^kit.Json {
	a := kit.jarr()
	for x in Service {
		if x in s {
			kit.jpush(a, kit.jstr(SERVICE_KEYS[x]))
		}
	}
	return a
}

cmd_run :: proc(c: ^kit.Call) -> int {
	scratch: virtual.Arena
	context.temp_allocator = private_temp(&scratch)
	defer virtual.arena_destroy(&scratch)
	first := kit.cli_bool(c, "first-login")
	if first && read_marker().done {
		kit.jset_bool(c.out, "shown", false)
		return kit.EXIT_OK
	}
	if c.dry_run {
		kit.jset_bool(c.out, "shown", false)
		return kit.EXIT_OK
	}
	code := run_window({spawn = true, first_login = first}, kit.cli_str(c, "lang"), kit.cli_str(c, "theme"))
	kit.jset_bool(c.out, "shown", true)
	return code
}

cmd_reset :: proc(c: ^kit.Call) -> int {
	kit.jset_str(c.out, "marker", marker_path())
	if c.dry_run {
		kit.jset_bool(c.out, "removed", false)
		return kit.EXIT_OK
	}
	kit.jset_bool(c.out, "removed", remove_marker())
	return kit.EXIT_OK
}

read_secret :: proc(c: ^kit.Call, flag: string) -> (string, bool) {
	f := kit.cli_str(c, flag)
	if f == "" {
		return "", false
	}
	text, ok := read_text(f)
	if !ok {
		return "", false
	}
	return strings.trim_right(text, "\r\n"), true
}

cmd_setup :: proc(c: ^kit.Call) -> int {
	st := new(St)
	st_init(st, {spawn = kit.cli_bool(c, "start-daemons")})
	if lang := kit.cli_str(c, "lang"); lang != "" && !c.dry_run {
		save_language(lang)
	}
	if theme := kit.cli_str(c, "theme"); theme != "" && !c.dry_run {
		save_appearance(theme == "dark")
	}
	finished := false
	if kit.cli_bool(c, "local") {
		st.mode = .Local
		kit.jset_str(c.out, "mode", "local")
		if !c.dry_run && kit.cli_bool(c, "finish") {
			finished = finish(st)
		}
		kit.jset(c.out, "identities", kit.jarr())
		kit.jset(c.out, "tasks", kit.jarr())
		kit.jset_bool(c.out, "finished", finished)
		return kit.EXIT_OK
	}

	st.mode = .Account
	kit.jset_str(c.out, "mode", "account")
	if e := open_cloud(st, kit.cli_str(c, "url")); !ck.ok(e) {
		return kit.cli_fail(c, kit.EXIT_USAGE, e.message)
	}
	if c.dry_run {
		kit.jset(c.out, "identities", kit.jarr())
		kit.jset(c.out, "tasks", kit.jarr())
		kit.jset_bool(c.out, "finished", false)
		return kit.EXIT_OK
	}

	// The account.
	email := kit.cli_str(c, "email")
	pw, have_pw := read_secret(c, "password-file")
	if email != "" {
		if !have_pw {
			return kit.cli_fail(c, kit.EXIT_USAGE, "--password-file is needed with --email")
		}
		append(&st.email_buf, ..transmute([]u8)email)
		append(&st.pw_buf, ..transmute([]u8)pw)
		append(&st.name_buf, ..transmute([]u8)kit.cli_str(c, "name"))
		err := ""
		if kit.cli_bool(c, "create") {
			err = do_sign_up(st)
		} else {
			err = do_sign_in(st)
		}
		if err != "" {
			code := kit.cli_fail(c, kit.EXIT_FAILED, err)
			kit.cli_err_field(c, "step", "account")
			return code
		}
	} else if !st.signed_in {
		return kit.cli_fail(c, kit.EXIT_USAGE, "not signed in: give --email and --password-file")
	} else {
		refresh_account(st)
	}

	// New identities.
	if spec := kit.cli_str(c, "identities"); spec != "" {
		for item in strings.split(spec, ";", context.temp_allocator) {
			parts := strings.split_n(strings.trim_space(item), ":", 4, context.temp_allocator)
			if len(parts) < 4 {
				return kit.cli_failf(c, kit.EXIT_USAGE, "an identity is handle:kind:colour:Display Name, not %q", item)
			}
			if find_plan(st, parts[0]) != nil {
				continue
			}
			pl := add_plan(st, kind_index(parts[1]), parts[3])
			clear(&pl.handle)
			append(&pl.handle, ..transmute([]u8)parts[0])
			pl.handle_touched = true
			pl.color = palette_index(parts[2])
		}
		if p := identities_problem(st); p != "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, p)
		}
		do_identities(st)
	}

	// What syncs. With --sync, exactly what it says; identities it does not
	// name sync nothing. Without it, what sync.conf remembers, or nothing.
	if spec := kit.cli_str(c, "sync"); spec != "" {
		for &pl in st.plans {
			pl.services = {}
		}
		for item in strings.split(spec, ";", context.temp_allocator) {
			eq := strings.index_byte(item, '=')
			if eq < 0 {
				return kit.cli_failf(c, kit.EXIT_USAGE, "--sync takes handle=service,service; not %q", item)
			}
			pl := find_plan(st, strings.trim_space(item[:eq]))
			if pl == nil || !pl.existing {
				return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no identity %q on the account", strings.trim_space(item[:eq]))
			}
			for name in strings.split(item[eq + 1:], ",", context.temp_allocator) {
				n := strings.trim_space(name)
				found := false
				for s in Service {
					if SERVICE_KEYS[s] == n {
						pl.services += {s}
						found = true
					}
				}
				if !found && n != "" {
					return kit.cli_failf(c, kit.EXIT_USAGE, "not a service: %q", n)
				}
			}
		}
	} else {
		for &pl in st.plans {
			pl.services = {}
		}
	}

	failed := false
	vault := kit.jobj()
	if any_service(st, .Passwords) {
		if key, ok := read_secret(c, "secret-key-file"); ok {
			append(&st.secret_buf, ..transmute([]u8)key)
			st.vault_enroll = true
		}
		vpw, ok := read_secret(c, "vault-password-file")
		if !st.vault_enroll && !ok {
			return kit.cli_fail(c, kit.EXIT_USAGE, "passwords sync: --vault-password-file is needed")
		}
		append(&st.vault_pw, ..transmute([]u8)vpw)
		append(&st.vault_pw2, ..transmute([]u8)vpw)
		err := ""
		if st.vault_enroll {
			err = do_vault_enroll(st)
		} else if p := vault_problem(st); p != "" {
			err = p
		} else {
			err = do_vault(st)
			if err == "" {
				dir := kit.cli_str(c, "kit-dir")
				if dir == "" {
					dir = kit_dir_default()
				}
				if kerr := do_kit(st, dir); kerr != "" {
					err = kerr
				}
			}
		}
		kit.jset_bool(vault, "set_up", st.vault_done)
		kit.jset_bool(vault, "enrolled", st.vault_enroll)
		if st.kit_paths[0] != "" {
			kit.jset_str(vault, "kit_png", st.kit_paths[0])
			kit.jset_str(vault, "kit_txt", st.kit_paths[1])
		}
		if err != "" {
			kit.jset_str(vault, "error", err)
			failed = true
		}
		kit.jset(c.out, "vault", vault)
	}

	plan_tasks(st)
	st.setup_ran = true
	do_services(st)

	ids := kit.jarr()
	for &pl in st.plans {
		o := kit.jobj()
		kit.jset_str(o, "handle", plan_handle(&pl))
		kit.jset_str(o, "address", fmt.tprintf("%s@%s", plan_handle(&pl), st.domain))
		kit.jset_str(o, "kind", KINDS[pl.kind])
		kit.jset_str(o, "color", PALETTE[pl.color].name)
		kit.jset_bool(o, "created", pl.existing)
		kit.jset(o, "services", services_json(pl.services))
		if pl.err != "" {
			kit.jset_str(o, "error", pl.err)
			failed = true
		}
		kit.jpush(ids, o)
	}
	kit.jset(c.out, "identities", ids)
	tasks := kit.jarr()
	for t in st.tasks {
		o := kit.jobj()
		kit.jset_str(o, "identity", t.handle)
		kit.jset_str(o, "task", fmt.tprintf("%v", t.what))
		kit.jset_str(o, "state", fmt.tprintf("%v", t.state))
		kit.jset_str(o, "detail", t.detail)
		kit.jpush(tasks, o)
		if t.state == .Failed {
			failed = true
		}
		if !c.json {
			fmt.printfln("%s %s %s %s", kit.cli_pad(t.handle == "" ? "(computer)" : t.handle, 16), kit.cli_pad(fmt.tprintf("%v", t.what), 12), kit.cli_pad(fmt.tprintf("%v", t.state), 15), t.detail)
		}
	}
	kit.jset(c.out, "tasks", tasks)
	kit.jset_str(c.out, "email", st.email)
	if kit.cli_bool(c, "finish") {
		finished = finish(st)
	}
	kit.jset_bool(c.out, "finished", finished)
	if failed {
		return kit.cli_fail(c, kit.EXIT_FAILED, "some steps did not finish; each says why")
	}
	return kit.EXIT_OK
}

cmd_kit :: proc(c: ^kit.Call) -> int {
	scratch: virtual.Arena
	context.temp_allocator = private_temp(&scratch)
	defer virtual.arena_destroy(&scratch)
	secret, ok := read_secret(c, "secret-key-file")
	if !ok || strings.trim_space(secret) == "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "cannot read the Secret Key file")
	}
	if lang := kit.cli_str(c, "lang"); lang != "" {
		set_language(lang)
	}
	dir := kit.cli_str(c, "out-dir")
	if c.dry_run {
		return kit.EXIT_OK
	}
	png, txt, err := write_kit(dir, strings.trim_space(secret), kit.cli_str(c, "email"), kit.cli_str(c, "url"))
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_str(c.out, "png", png)
	kit.jset_str(c.out, "txt", txt)
	return kit.EXIT_OK
}

cmd_shots :: proc(c: ^kit.Call) -> int {
	scratch: virtual.Arena
	context.temp_allocator = private_temp(&scratch)
	defer virtual.arena_destroy(&scratch)
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		return kit.EXIT_OK
	}
	n := shots(dir, kit.cli_str(c, "lang"))
	if n < 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render into %s", dir)
	}
	kit.jset_int(c.out, "count", n)
	return kit.EXIT_OK
}

cmd_drive :: proc(c: ^kit.Call) -> int {
	scratch: virtual.Arena
	context.temp_allocator = private_temp(&scratch)
	defer virtual.arena_destroy(&scratch)
	if c.dry_run {
		return kit.EXIT_OK
	}
	res := drive_flow(kit.cli_bool(c, "local"), kit.cli_str(c, "email"), kit.cli_str(c, "shots"), kit.cli_str(c, "lang"), kit.cli_str(c, "theme"))
	arr := kit.jarr()
	for s in res.steps {
		kit.jpush(arr, kit.jstr(s))
	}
	kit.jset(c.out, "steps", arr)
	kit.jset_bool(c.out, "finished", res.finished)
	kit.jset_int(c.out, "keys", res.keys)
	if res.err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, res.err)
	}
	return kit.EXIT_OK
}

_ :: os
