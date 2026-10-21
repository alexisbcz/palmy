package main

// The command-line front end: `accounts <verb>`, or `palm accounts <verb>`.
//
// Every verb is one of the act_* procedures in main.odin or one cloudkit
// call, so the window and the command line cannot disagree. Scope follows
// the convention (docs/PALM-CLI.md): PALM_IDENTITY, narrowed by --identity,
// selects the session stored for that identity, and the server refuses the
// rest. A refusal for scope exits 5.
//
// Passwords never go through standard input (the kit does not read it, so an
// agent cannot hang on a prompt). Give one with --password-file, or the
// PALM_CLOUD_PASSWORD environment variable, or --password for a throwaway
// account on a development stack.

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "whether this machine is signed in, as whom, and in what scope",
		effect = .Read,
		out = {
			{name = "signed_in", kind = .Bool},
			{name = "email", kind = .String, opt = true},
			{name = "user_id", kind = .String, opt = true},
			{name = "scope", kind = .String, help = "the identity handle this session acts for, or \"\" for the full account"},
			{name = "current", kind = .String, help = "the identity last switched to"},
			{name = "url", kind = .String},
			{name = "store", kind = .String, help = "the token store directory"},
		},
		examples = {"accounts status --json"},
		run = cmd_status,
	},
	{
		verb = "server",
		summary = "which Palmy server this machine uses, or change it (checked before it is kept)",
		effect = .Idempotent,
		args = {{name = "url", kind = .String, help = "the server to use from now on, e.g. https://cloud.example.org"}},
		out = {
			{name = "url", kind = .String},
			{name = "source", kind = .String, help = "argument, environment, config, or default"},
			{name = "reachable", kind = .Bool},
			{name = "config", kind = .String, help = "the file a new server is written to"},
		},
		examples = {"accounts server --json", "accounts server http://127.0.0.1:54321 --json"},
		run = cmd_server,
	},
	{
		verb = "signup",
		summary = "create the account, and its first identity with it",
		effect = .Mutate,
		args = {{name = "email", kind = .String, required = true}},
		flags = {
			{name = "name", kind = .String, help = "the first identity's display name", required = true},
			{name = "handle", kind = .String, help = "the first identity's handle (its mail local part)", required = true},
			{name = "password", kind = .String, help = "for development stacks only; prefer --password-file"},
			{name = "password-file", kind = .Path, help = "a file holding the password"},
		},
		out = {{name = "email", kind = .String}, {name = "user_id", kind = .String}, {name = "identity", kind = .Object}},
		examples = {"accounts signup alex@example.org --name \"Alex Rivera\" --handle alex --password-file ~/.pw --json"},
		run = cmd_signup,
	},
	{
		verb = "signin",
		summary = "sign this machine in with an email and password",
		effect = .Mutate,
		args = {{name = "email", kind = .String, required = true}},
		flags = {
			{name = "password", kind = .String, help = "for development stacks only; prefer --password-file"},
			{name = "password-file", kind = .Path, help = "a file holding the password"},
		},
		out = {{name = "email", kind = .String}, {name = "user_id", kind = .String}},
		examples = {"accounts signin alex@example.org --password-file ~/.pw --json"},
		run = cmd_signin,
	},
	{
		verb = "signout",
		summary = "end this machine's session and forget it",
		effect = .Mutate,
		out = {{name = "signed_in", kind = .Bool}},
		examples = {"accounts signout --json"},
		run = cmd_signout,
	},
	{
		verb = "list",
		summary = "the identities this session can see",
		effect = .Read,
		flags = {{name = "archived", kind = .Bool, help = "include archived identities"}},
		out = {
			{
				name = "identities",
				kind = .Array,
				of = {
					{name = "id", kind = .String},
					{name = "handle", kind = .String},
					{name = "address", kind = .String},
					{name = "display_name", kind = .String},
					{name = "kind", kind = .String},
					{name = "color", kind = .String},
					{name = "archived", kind = .Bool},
					{name = "current", kind = .Bool},
					{name = "session_here", kind = .Bool, help = "this machine holds a session scoped to it"},
				},
			},
			{name = "count", kind = .Int},
		},
		examples = {"accounts list --json", "PALM_IDENTITY=work accounts list --json"},
		run = cmd_list,
	},
	{
		verb = "current",
		summary = "the identity last switched to",
		effect = .Read,
		out = {{name = "current", kind = .String}},
		examples = {"accounts current --json"},
		run = cmd_current,
	},
	{
		verb = "create",
		summary = "make a new identity",
		effect = .Mutate,
		args = {{name = "handle", kind = .String, help = "permanent; also the mail local part", required = true}},
		flags = {
			{name = "name", kind = .String, help = "display name", required = true},
			{name = "kind", kind = .Enum, values = {"personal", "work", "public", "project"}, def = "personal"},
			{name = "color", kind = .Enum, values = {"slate", "gray", "zinc", "neutral", "stone", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose"}, def = "indigo"},
		},
		out = IDENTITY_FIELDS,
		examples = {"accounts create alex.northwind --name \"Alex at Northwind\" --kind work --color sky --json"},
		run = cmd_create,
	},
	{
		verb = "rename",
		summary = "change an identity's display name (the handle is permanent)",
		effect = .Idempotent,
		args = {
			{name = "identity", kind = .String, help = "a handle or an id", required = true},
			{name = "name", kind = .String, required = true},
		},
		out = IDENTITY_FIELDS,
		examples = {"accounts rename alex.northwind \"Alex, Northwind\" --json"},
		run = cmd_rename,
	},
	{
		verb = "color",
		summary = "change an identity's colour",
		effect = .Idempotent,
		args = {
			{name = "identity", kind = .String, help = "a handle or an id", required = true},
			{name = "color", kind = .Enum, values = {"slate", "gray", "zinc", "neutral", "stone", "red", "orange", "amber", "yellow", "lime", "green", "emerald", "teal", "cyan", "sky", "blue", "indigo", "violet", "purple", "fuchsia", "pink", "rose"}, required = true},
		},
		out = IDENTITY_FIELDS,
		examples = {"accounts color alex.northwind teal --json"},
		run = cmd_color,
	},
	{
		verb = "archive",
		summary = "archive an identity: its data stays, unreachable, and its sessions end",
		effect = .Destructive,
		args = {{name = "identity", kind = .String, help = "a handle or an id", required = true}},
		out = IDENTITY_FIELDS,
		examples = {"accounts archive old.project --yes --json"},
		run = cmd_archive,
	},
	{
		verb = "restore",
		summary = "bring an archived identity back",
		effect = .Idempotent,
		args = {{name = "identity", kind = .String, help = "a handle or an id", required = true}},
		out = IDENTITY_FIELDS,
		examples = {"accounts restore old.project --json"},
		run = cmd_restore,
	},
	{
		verb = "switch",
		summary = "make an identity current, and give this machine a session scoped to it",
		effect = .Idempotent,
		args = {{name = "identity", kind = .String, help = "a handle or an id", required = true}},
		out = {{name = "current", kind = .String}, {name = "store", kind = .String, help = "where its scoped session is"}},
		examples = {"accounts switch alex.northwind --json"},
		run = cmd_switch,
	},
	{
		verb = "delegate",
		summary = "mint a session that acts for one identity only, for an assistant or a device",
		effect = .Mutate,
		args = {{name = "identity", kind = .String, help = "a handle or an id", required = true}},
		flags = {
			{name = "name", kind = .String, help = "what to call it in the devices list", required = true},
			{name = "kind", kind = .Enum, values = {"assistant", "device"}, def = "assistant"},
			{name = "expires", kind = .Int, help = "seconds until it ends; 0 for never", def = "0"},
		},
		out = {
			{name = "device_id", kind = .String},
			{name = "session_id", kind = .String},
			{name = "identity", kind = .String},
			{name = "store", kind = .String, help = "the session file; hand it to the program as PALM_CLOUD_SESSION=<store>"},
		},
		examples = {"accounts delegate alex.northwind --name \"Mail assistant\" --kind assistant --expires 86400 --json"},
		run = cmd_delegate,
	},
	{
		verb = "devices",
		summary = "sessions delegated to identities, active and ended",
		effect = .Read,
		out = {
			{
				name = "devices",
				kind = .Array,
				of = {
					{name = "id", kind = .String},
					{name = "name", kind = .String},
					{name = "kind", kind = .String},
					{name = "identity", kind = .String},
					{name = "active", kind = .Bool},
					{name = "created_at", kind = .String},
					{name = "expires_at", kind = .String, opt = true},
				},
			},
		},
		examples = {"accounts devices --json"},
		run = cmd_devices,
	},
	{
		verb = "revoke",
		summary = "end a delegated session at once",
		effect = .Destructive,
		args = {{name = "device", kind = .String, help = "a device id, or a device name", required = true}},
		out = {{name = "device_id", kind = .String}, {name = "revoked", kind = .Bool}},
		examples = {"accounts revoke \"Mail assistant\" --yes --json"},
		run = cmd_revoke,
	},
	{
		verb = "sessions",
		summary = "every session on the account (a scoped session sees only itself)",
		effect = .Read,
		out = {
			{
				name = "sessions",
				kind = .Array,
				of = {
					{name = "session_id", kind = .String},
					{name = "name", kind = .String},
					{name = "scope", kind = .String, help = "an identity handle, or \"\" for the full account"},
					{name = "current", kind = .Bool},
					{name = "created_at", kind = .String},
					{name = "refreshed_at", kind = .String},
				},
			},
		},
		examples = {"accounts sessions --json"},
		run = cmd_sessions,
	},
	{
		verb = "end-session",
		summary = "sign another machine out of the account",
		effect = .Destructive,
		args = {{name = "session", kind = .String, help = "a session id", required = true}},
		out = {{name = "session_id", kind = .String}, {name = "ended", kind = .Bool}},
		examples = {"accounts end-session 5e55... --yes --json"},
		run = cmd_end_session,
	},
	{
		verb = "whoami",
		summary = "what the server says this session is",
		effect = .Read,
		out = {
			{name = "user_id", kind = .String},
			{name = "session_id", kind = .String},
			{name = "scoped", kind = .Bool},
			{name = "identity", kind = .Object, opt = true},
		},
		examples = {"accounts whoami --json", "PALM_IDENTITY=work accounts whoami --json"},
		run = cmd_whoami,
	},
	{
		verb = "avatar",
		summary = "set an identity's picture (PNG, JPEG or WebP, up to 2 MB)",
		effect = .Idempotent,
		args = {
			{name = "identity", kind = .String, help = "a handle or an id", required = true},
			{name = "image", kind = .Path, required = true},
		},
		out = {{name = "identity", kind = .String}, {name = "object", kind = .String}},
		examples = {"accounts avatar alex ~/me.png --json"},
		run = cmd_avatar,
	},
	{
		verb = "shots",
		summary = "render the interface offscreen into a directory of PNGs",
		effect = .Mutate,
		aliases = {"--shots"},
		args = {{name = "dir", kind = .Path, help = "where to write the PNGs", required = true}},
		flags = {{name = "lang", kind = .String, help = "render in this language, e.g. fr"}},
		out = {{name = "dir", kind = .String}, {name = "count", kind = .Int}},
		examples = {"accounts shots /tmp/accounts-shots"},
		run = cmd_shots,
	},
}

IDENTITY_FIELDS := []kit.Field {
	{name = "id", kind = .String},
	{name = "handle", kind = .String},
	{name = "address", kind = .String},
	{name = "display_name", kind = .String},
	{name = "kind", kind = .String},
	{name = "color", kind = .String},
	{name = "archived", kind = .Bool},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "accounts",
			summary  = "one Palmy account, several identities",
			gui      = true,
			selftest = cli_selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

@(private = "file")
SURFACE_NOTES :: `The cloud is $PALM_CLOUD_URL (default http://127.0.0.1:54321, the stack
cloud/dev/up.sh starts). Tokens live in ~/.local/share/palm/cloud, or
$PALM_CLOUD_DIR, readable only by you.

With PALM_IDENTITY=<handle> (or --identity <handle>) every verb runs on the
session stored for that identity: it sees that identity alone, and the
account-level verbs (create, delegate, switch, signin) are refused with
exit 5. "accounts switch <handle>" stores this machine's session for an
identity. "accounts delegate" mints one to hand to an assistant, stored apart
under delegated/ and used with PALM_CLOUD_SESSION=<file>; it must be a scoped
session, and it implies PALM_IDENTITY.`

// ---------------------------------------------------------------------------
// Plumbing
// ---------------------------------------------------------------------------

@(private = "file")
open_for :: proc(c: ^kit.Call) -> (st: ^St, code: int) {
	st = new(St)
	st_init(st)
	cl, e := ck.open(scope = c.identity, app = "accounts")
	st.c = cl
	if !ck.ok(e) {
		return st, fail(c, e)
	}
	return st, kit.EXIT_OK
}

// fail maps a cloudkit error onto the convention's exit codes.
@(private = "file")
fail :: proc(c: ^kit.Call, e: ck.Error) -> int {
	code := kit.EXIT_FAILED
	switch e.kind {
	case .Unavailable:
		code = kit.EXIT_UNAVAILABLE
	case .Out_Of_Scope:
		code = kit.EXIT_OUT_OF_SCOPE
	case .Not_Found:
		code = kit.EXIT_NOT_FOUND
	case .Invalid:
		code = kit.EXIT_USAGE
	case .None, .Not_Signed_In, .Unauthorized, .Conflict, .Failed:
	}
	r := kit.cli_fail(c, code, e.message)
	kit.cli_err_field(c, "reason", ck.error_kind_name(e.kind))
	if e.code != "" {
		kit.cli_err_field(c, "server_code", e.code)
	}
	if code == kit.EXIT_OUT_OF_SCOPE {
		kit.cli_err_field(c, "identity", c.identity == "" ? "unscoped" : c.identity)
	}
	return r
}

@(private = "file")
need_session :: proc(c: ^kit.Call, st: ^St) -> int {
	if ck.signed_in(st.c) {
		return kit.EXIT_OK
	}
	if c.identity != "" {
		code := kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, fmt.tprintf("no session is stored for %q on this machine; run: accounts switch %s", c.identity, c.identity))
		kit.cli_err_field(c, "identity", c.identity)
		return code
	}
	// The account is not available on this device: unavailable (6), as the
	// other apps say it, so a caller can tell it from a command that failed.
	code := kit.cli_fail(c, kit.EXIT_UNAVAILABLE, "not signed in; run: accounts signin <email>")
	kit.cli_err_field(c, "reason", "not signed in")
	return code
}

@(private = "file")
password_of :: proc(c: ^kit.Call) -> (pw: string, ok: bool) {
	if f := kit.cli_str(c, "password-file"); f != "" {
		data, err := os.read_entire_file_from_path(f, context.temp_allocator)
		if err != nil {
			return "", false
		}
		return strings.trim_right(string(data), "\r\n"), true
	}
	if pw = kit.cli_str(c, "password"); pw != "" {
		return pw, true
	}
	if pw = os.get_env("PALM_CLOUD_PASSWORD", context.temp_allocator); pw != "" {
		return pw, true
	}
	return "", false
}

@(private = "file")
identity_json :: proc(x: ck.Identity) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", x.id)
	kit.jset_str(o, "handle", x.handle)
	kit.jset_str(o, "address", fmt.tprintf("%s@%s", x.handle, MAIL_DOMAIN))
	kit.jset_str(o, "display_name", x.display_name)
	kit.jset_str(o, "kind", x.kind)
	kit.jset_str(o, "color", x.color)
	kit.jset_bool(o, "archived", x.archived)
	return o
}

@(private = "file")
identity_out :: proc(c: ^kit.Call, x: ck.Identity) {
	kit.jset_str(c.out, "id", x.id)
	kit.jset_str(c.out, "handle", x.handle)
	kit.jset_str(c.out, "address", fmt.tprintf("%s@%s", x.handle, MAIL_DOMAIN))
	kit.jset_str(c.out, "display_name", x.display_name)
	kit.jset_str(c.out, "kind", x.kind)
	kit.jset_str(c.out, "color", x.color)
	kit.jset_bool(c.out, "archived", x.archived)
}

// resolve finds an identity by handle or id among what this session sees.
@(private = "file")
resolve :: proc(c: ^kit.Call, st: ^St, key: string) -> (x: ck.Identity, code: int) {
	reload(st)
	if found, ok := ck.find_identity(st.ids, key); ok {
		return found, kit.EXIT_OK
	}
	code = kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no identity %q that this session can see", key))
	kit.cli_err_field(c, "identity", key)
	return {}, code
}

// prologue is the start of every verb that needs a session.
@(private = "file")
prologue :: proc(c: ^kit.Call) -> (st: ^St, code: int) {
	st, code = open_for(c)
	if code != kit.EXIT_OK {
		return
	}
	return st, need_session(c, st)
}

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

cmd_status :: proc(c: ^kit.Call) -> int {
	st, code := open_for(c)
	if code != kit.EXIT_OK {
		return code
	}
	signed := ck.signed_in(st.c)
	kit.jset_bool(c.out, "signed_in", signed)
	if signed {
		kit.jset_str(c.out, "email", st.c.session.email)
		kit.jset_str(c.out, "user_id", st.c.session.user_id)
	}
	kit.jset_str(c.out, "scope", st.c.scope)
	kit.jset_str(c.out, "current", ck.current_identity(st.c, context.temp_allocator))
	kit.jset_str(c.out, "url", st.c.url_text)
	kit.jset_str(c.out, "store", st.c.dir)
	if !c.json {
		if signed {
			fmt.printfln("signed in as %s%s", st.c.session.email, st.c.scope != "" ? fmt.tprintf(", scoped to %s", st.c.scope) : "")
		} else {
			fmt.println("not signed in")
		}
	}
	return kit.EXIT_OK
}

// cmd_server reports or sets the server. Setting it is what the welcome
// app's "Change" does too: the address must answer /auth/v1/health before
// it is written to the token store's config.json, which every app reads
// (cloudkit.open) unless $PALM_CLOUD_URL says otherwise.
cmd_server :: proc(c: ^kit.Call) -> int {
	want := kit.cli_str(c, "url")
	cl, e := ck.open(url = want, app = "accounts")
	if !ck.ok(e) {
		return fail(c, e)
	}
	source := "default"
	switch {
	case want != "":
		source = "argument"
	case os.get_env("PALM_CLOUD_URL", context.temp_allocator) != "":
		source = "environment"
	case os.exists(fmt.tprintf("%s/config.json", cl.dir)):
		source = "config"
	}
	_, he := ck.call(cl, "GET", "/auth/v1/health", "", auth = false, allocator = context.temp_allocator)
	reachable := ck.ok(he)
	config := fmt.tprintf("%s/config.json", cl.dir)
	kit.jset_str(c.out, "url", cl.url_text)
	kit.jset_str(c.out, "source", source)
	kit.jset_bool(c.out, "reachable", reachable)
	kit.jset_str(c.out, "config", config)
	if want == "" {
		if !c.json {
			fmt.printfln("%s (%s)%s", cl.url_text, source, reachable ? "" : ", not answering")
		}
		return kit.EXIT_OK
	}
	if !reachable {
		code := kit.cli_failf(c, kit.EXIT_UNAVAILABLE, "%s does not answer /auth/v1/health; nothing was changed", cl.url_text)
		kit.cli_err_field(c, "url", cl.url_text)
		return code
	}
	if c.dry_run {
		return kit.EXIT_OK
	}
	os.make_directory_all(cl.dir, os.perm(0o700))
	text := fmt.tprintf("{{\"url\":%s,\"anon_key\":%s}}\n", ck.quote(cl.url_text), ck.quote(cl.anon_key))
	if os.write_entire_file(config, transmute([]u8)text) != nil {
		return kit.cli_failf(c, kit.EXIT_FAILED, "cannot write %s", config)
	}
	os.chmod(config, {.Read_User, .Write_User})
	if !c.json {
		fmt.printfln("now using %s", cl.url_text)
	}
	return kit.EXIT_OK
}

cmd_signup :: proc(c: ^kit.Call) -> int {
	st, code := open_for(c)
	if code != kit.EXIT_OK {
		return code
	}
	pw, ok := password_of(c)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a password is needed: --password-file, PALM_CLOUD_PASSWORD or --password")
	}
	handle := kit.cli_str(c, "handle")
	if !ck.handle_ok(handle) {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a handle is 2-63 of a-z 0-9 . _ - starting with a letter or digit")
	}
	if c.dry_run {
		kit.jset_str(c.out, "email", kit.cli_str(c, "email"))
		return kit.EXIT_OK
	}
	if e := act_create_account(st, kit.cli_str(c, "email"), pw, kit.cli_str(c, "name"), handle); !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_str(c.out, "email", st.c.session.email)
	kit.jset_str(c.out, "user_id", st.c.session.user_id)
	if x, found := ck.find_identity(st.ids, handle); found {
		kit.jset(c.out, "identity", identity_json(x))
	}
	if !c.json {
		fmt.printfln("created %s with %s@%s", st.c.session.email, handle, MAIL_DOMAIN)
	}
	return kit.EXIT_OK
}

cmd_signin :: proc(c: ^kit.Call) -> int {
	st, code := open_for(c)
	if code != kit.EXIT_OK {
		return code
	}
	pw, ok := password_of(c)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, "a password is needed: --password-file, PALM_CLOUD_PASSWORD or --password")
	}
	if c.dry_run {
		return kit.EXIT_OK
	}
	if e := act_sign_in(st, kit.cli_str(c, "email"), pw); !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_str(c.out, "email", st.c.session.email)
	kit.jset_str(c.out, "user_id", st.c.session.user_id)
	if !c.json {
		fmt.printfln("signed in as %s", st.c.session.email)
	}
	return kit.EXIT_OK
}

cmd_signout :: proc(c: ^kit.Call) -> int {
	st, code := open_for(c)
	if code != kit.EXIT_OK {
		return code
	}
	if !c.dry_run {
		if e := ck.sign_out(st.c); !ck.ok(e) {
			return fail(c, e)
		}
	}
	kit.jset_bool(c.out, "signed_in", ck.signed_in(st.c))
	return kit.EXIT_OK
}

cmd_list :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	reload(st)
	arr := kit.jarr()
	all := kit.cli_bool(c, "archived")
	for x in st.ids {
		if x.archived && !all {
			continue
		}
		o := identity_json(x)
		kit.jset_bool(o, "current", x.handle == st.current)
		kit.jset_bool(o, "session_here", st.stored[x.handle])
		kit.jpush(arr, o)
		if !c.json {
			fmt.printfln("%s %s %s %s%s", x.handle == st.current ? "*" : " ", kit.cli_pad(x.handle, 24), kit.cli_pad(x.display_name, 22), x.kind, x.archived ? " (archived)" : "")
		}
	}
	kit.jset(c.out, "identities", arr)
	kit.jset_int(c.out, "count", kit.jlen(arr))
	return kit.EXIT_OK
}

cmd_current :: proc(c: ^kit.Call) -> int {
	st, code := open_for(c)
	if code != kit.EXIT_OK {
		return code
	}
	cur := ck.current_identity(st.c, context.temp_allocator)
	kit.jset_str(c.out, "current", cur)
	if !c.json {
		fmt.println(cur)
	}
	return kit.EXIT_OK
}

cmd_create :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	handle := kit.cli_str(c, "handle")
	if c.dry_run {
		kit.jset_str(c.out, "handle", handle)
		return kit.EXIT_OK
	}
	x, e := act_create_identity(st, handle, kit.cli_str(c, "name"), kit.cli_str(c, "kind"), kit.cli_str(c, "color"))
	if !ck.ok(e) {
		return fail(c, e)
	}
	identity_out(c, x)
	return kit.EXIT_OK
}

@(private = "file")
change :: proc(c: ^kit.Call, what: enum {
		Rename,
		Color,
		Archive,
		Restore,
	}) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	x, rcode := resolve(c, st, kit.cli_str(c, "identity"))
	if rcode != kit.EXIT_OK {
		return rcode
	}
	if c.dry_run {
		identity_out(c, x)
		return kit.EXIT_OK
	}
	out: ck.Identity
	e: ck.Error
	switch what {
	case .Rename:
		out, e = ck.rename_identity(st.c, x.id, kit.cli_str(c, "name"))
	case .Color:
		out, e = ck.set_identity_color(st.c, x.id, kit.cli_str(c, "color"))
	case .Archive:
		out, e = ck.archive_identity(st.c, x.id)
	case .Restore:
		out, e = ck.restore_identity(st.c, x.id)
	}
	if !ck.ok(e) {
		return fail(c, e)
	}
	identity_out(c, out)
	return kit.EXIT_OK
}

cmd_rename :: proc(c: ^kit.Call) -> int {return change(c, .Rename)}
cmd_color :: proc(c: ^kit.Call) -> int {return change(c, .Color)}
cmd_archive :: proc(c: ^kit.Call) -> int {return change(c, .Archive)}
cmd_restore :: proc(c: ^kit.Call) -> int {return change(c, .Restore)}

cmd_switch :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	if c.identity != "" {
		code = kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "switching identity is the person's choice, not a scoped session's")
		kit.cli_err_field(c, "identity", c.identity)
		return code
	}
	x, rcode := resolve(c, st, kit.cli_str(c, "identity"))
	if rcode != kit.EXIT_OK {
		return rcode
	}
	kit.jset_str(c.out, "current", x.handle)
	kit.jset_str(c.out, "store", ck.scoped_path(st.c, x.handle, context.temp_allocator))
	if c.dry_run {
		return kit.EXIT_OK
	}
	if e := act_switch(st, x.handle); !ck.ok(e) {
		return fail(c, e)
	}
	if !c.json {
		fmt.printfln("now %s (%s@%s)", x.display_name, x.handle, MAIL_DOMAIN)
	}
	return kit.EXIT_OK
}

cmd_delegate :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	x, rcode := resolve(c, st, kit.cli_str(c, "identity"))
	if rcode != kit.EXIT_OK {
		return rcode
	}
	kit.jset_str(c.out, "identity", x.handle)
	if c.dry_run {
		return kit.EXIT_OK
	}
	m, e := act_delegate(st, x, kit.cli_str(c, "name"), kit.cli_str(c, "kind"), kit.cli_int(c, "expires", 0))
	if !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_str(c.out, "device_id", m.device_id)
	kit.jset_str(c.out, "session_id", m.session_id)
	kit.jset_str(c.out, "store", m.path)
	if !c.json {
		fmt.printfln("%s now acts for %s; start it with PALM_CLOUD_SESSION=%s", kit.cli_str(c, "name"), x.handle, m.path)
	}
	return kit.EXIT_OK
}

cmd_devices :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	reload(st)
	arr := kit.jarr()
	for d in st.devs {
		o := kit.jobj()
		kit.jset_str(o, "id", d.id)
		kit.jset_str(o, "name", d.name)
		kit.jset_str(o, "kind", d.kind)
		x, _ := ck.find_identity(st.ids, d.identity_id)
		kit.jset_str(o, "identity", x.handle)
		kit.jset_bool(o, "active", d.active)
		kit.jset_str(o, "created_at", d.created_at)
		if d.expires_at != "" {
			kit.jset_str(o, "expires_at", d.expires_at)
		}
		kit.jpush(arr, o)
		if !c.json {
			fmt.printfln("%s  %s %s %s %s", d.id, kit.cli_pad(d.name, 20), kit.cli_pad(d.kind, 10), kit.cli_pad(x.handle, 20), d.active ? "active" : "ended")
		}
	}
	kit.jset(c.out, "devices", arr)
	return kit.EXIT_OK
}

cmd_revoke :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	reload(st)
	key := kit.cli_str(c, "device")
	id := ""
	for d in st.devs {
		if (d.id == key || d.name == key) && d.active {
			id = d.id
		}
	}
	if id == "" {
		code = kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("no active device %q", key))
		return code
	}
	kit.jset_str(c.out, "device_id", id)
	if c.dry_run {
		kit.jset_bool(c.out, "revoked", false)
		return kit.EXIT_OK
	}
	if e := act_revoke(st, id); !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_bool(c.out, "revoked", true)
	return kit.EXIT_OK
}

cmd_sessions :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	ss, e := ck.sessions(st.c, context.temp_allocator)
	if !ck.ok(e) {
		return fail(c, e)
	}
	reload(st)
	arr := kit.jarr()
	for s in ss {
		o := kit.jobj()
		kit.jset_str(o, "session_id", s.session_id)
		kit.jset_str(o, "name", s.device_name != "" ? s.device_name : s.user_agent)
		x, _ := ck.find_identity(st.ids, s.identity_id)
		kit.jset_str(o, "scope", x.handle)
		kit.jset_bool(o, "current", s.current)
		kit.jset_str(o, "created_at", s.created_at)
		kit.jset_str(o, "refreshed_at", s.refreshed_at)
		kit.jpush(arr, o)
		if !c.json {
			fmt.printfln("%s %s  %s %s", s.current ? "*" : " ", s.session_id, kit.cli_pad(s.device_name != "" ? s.device_name : s.user_agent, 28), x.handle != "" ? x.handle : "full account")
		}
	}
	kit.jset(c.out, "sessions", arr)
	return kit.EXIT_OK
}

cmd_end_session :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	id := kit.cli_str(c, "session")
	kit.jset_str(c.out, "session_id", id)
	if c.dry_run {
		kit.jset_bool(c.out, "ended", false)
		return kit.EXIT_OK
	}
	if e := act_end_session(st, id); !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_bool(c.out, "ended", true)
	return kit.EXIT_OK
}

cmd_whoami :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	v, e := ck.whoami(st.c, context.temp_allocator)
	if !ck.ok(e) {
		return fail(c, e)
	}
	kit.jset_str(c.out, "user_id", ck.get_str(v, "user_id"))
	kit.jset_str(c.out, "session_id", ck.get_str(v, "session_id"))
	scoped := ck.get_bool(v, "scoped")
	kit.jset_bool(c.out, "scoped", scoped)
	if scoped {
		o := kit.jobj()
		kit.jset_str(o, "id", ck.get_str(v, "identity", "id"))
		kit.jset_str(o, "handle", ck.get_str(v, "identity", "handle"))
		kit.jset_str(o, "display_name", ck.get_str(v, "identity", "display_name"))
		kit.jset(c.out, "identity", o)
	}
	if !c.json {
		if scoped {
			fmt.printfln("%s, acting for %s only", st.c.session.email, ck.get_str(v, "identity", "handle"))
		} else {
			fmt.printfln("%s, full account", st.c.session.email)
		}
	}
	return kit.EXIT_OK
}

cmd_avatar :: proc(c: ^kit.Call) -> int {
	st, code := prologue(c)
	if code != kit.EXIT_OK {
		return code
	}
	x, rcode := resolve(c, st, kit.cli_str(c, "identity"))
	if rcode != kit.EXIT_OK {
		return rcode
	}
	kit.jset_str(c.out, "identity", x.handle)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if e := ck.set_avatar(st.c, x.id, kit.cli_str(c, "image")); !ck.ok(e) {
		return fail(c, e)
	}
	v, _ := ck.select(st.c, "profiles", fmt.tprintf("identity_id=eq.%s&select=avatar_path", x.id), context.temp_allocator)
	rows := ck.array(v)
	if len(rows) > 0 {
		kit.jset_str(c.out, "object", ck.get_str(rows[0], "avatar_path"))
	}
	return kit.EXIT_OK
}

cmd_shots :: proc(c: ^kit.Call) -> int {
	dir := kit.cli_str(c, "dir")
	kit.jset_str(c.out, "dir", dir)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if lang := kit.cli_str(c, "lang"); lang != "" {
		kit.i18n_set_language(lang)
	}
	n := shots(dir)
	if n < 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "could not render into %s", dir)
	}
	kit.jset_int(c.out, "count", n)
	return kit.EXIT_OK
}
