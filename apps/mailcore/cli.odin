package main

// The command line of the mail engine, on the shared convention.
//
// mailcore has no window: it is the engine, and apps/mail is a separate
// program that reads the Maildir this writes and runs this binary to sign in
// and sync (`mailcore palm login`, `mailcore palm sync` — the same commands as
// `login` and `sync` below, under their old prefix). So "the GUI uses the same
// entry points as the CLI" holds by construction: the only way the mail GUI
// reaches the engine is through these commands.
//
// What each command touches, and the rules that do not bend:
//
//   - every network command refuses any address outside 127.0.0.0/8
//     (conn_dial) and resolves no names;
//   - the only Maildir root it reads or writes is $XDG_DATA_HOME/palmy-mail
//     (resolve_root), and the reads — folders, list, thread — never create
//     anything: a mailbox that is not there is "not found", not an empty one
//     made on the spot;
//   - passwords and tokens are taken out of the command line before the kit
//     sees it (see scrub_secrets), so the audit log never holds one.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."

@(private = "file")
TLS_MODES := []string{"none", "verify", "insecure"}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "layout",
		summary = "describe the Maildir this engine writes, and where it lives",
		effect = .Read,
		out = {
			{name = "root", kind = .String, help = "the one directory mailcore reads and writes"},
			{name = "text", kind = .String, help = "the layout, flags and per-protocol notes"},
		},
		examples = {"mailcore layout --json"},
		aliases = {"--layout"},
		run = cmd_layout,
	},
	{
		verb = "parse",
		summary = "a message's headers, MIME tree, text, attachments and warnings",
		effect = .Read,
		args = {{name = "file", kind = .Path, help = "an RFC 5322 message (.eml)", required = true}},
		out = {
			{name = "file", kind = .String},
			{name = "subject", kind = .String},
			{name = "from", kind = .Array, of = {{name = "name", kind = .String}, {name = "email", kind = .String}}},
			{name = "to", kind = .Array, of = {{name = "name", kind = .String}, {name = "email", kind = .String}}},
			{name = "cc", kind = .Array, of = {{name = "name", kind = .String}, {name = "email", kind = .String}}},
			{name = "date", kind = .String, help = "the Date header as written"},
			{name = "unix", kind = .Int, help = "the date in seconds since the epoch", opt = true},
			{name = "iso", kind = .String, help = "the date in UTC", opt = true},
			{name = "message_id", kind = .String},
			{name = "references", kind = .Array, of = {{kind = .String}}},
			{name = "parts", kind = .Array, help = "the MIME tree, depth first", of = {
				{name = "section", kind = .String},
				{name = "depth", kind = .Int},
				{name = "type", kind = .String},
				{name = "encoding", kind = .String},
				{name = "charset", kind = .String},
				{name = "raw_bytes", kind = .Int},
				{name = "decoded_bytes", kind = .Int},
				{name = "filename", kind = .String},
				{name = "unterminated", kind = .Bool},
			}},
			{name = "text_plain_bytes", kind = .Int},
			{name = "text_html_bytes", kind = .Int},
			{name = "preview", kind = .String},
			{name = "parts_differ", kind = .Bool, help = "text/plain and text/html say different things"},
			{name = "attachments", kind = .Array, of = {
				{name = "filename", kind = .String},
				{name = "mime_type", kind = .String},
				{name = "size", kind = .Int},
				{name = "inline", kind = .Bool},
				{name = "content_id", kind = .String},
				{name = "section", kind = .String},
			}},
			{name = "warnings", kind = .Array, of = {{kind = .String}}},
		},
		examples = {"mailcore parse apps/mailcore/testdata/report.eml --json"},
		aliases = {"--parse"},
		run = cmd_parse,
	},
	{
		verb = "extract",
		summary = "write a message's attachments into a directory, names sanitised and contained",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, help = "an RFC 5322 message (.eml)", required = true}},
		flags = {
			{name = "out", kind = .Path, help = "the directory to write into", def = "."},
			{name = "section", kind = .String, help = "only the part with this IMAP section number"},
			{name = "force", kind = .Bool, help = "overwrite a file that is already there"},
		},
		out = {
			{name = "file", kind = .String},
			{name = "out", kind = .String},
			{name = "written", kind = .Array, of = {
				{name = "filename", kind = .String},
				{name = "mime_type", kind = .String},
				{name = "size", kind = .Int},
				{name = "path", kind = .String},
			}},
			{name = "failed", kind = .Array, of = {{name = "filename", kind = .String}, {name = "error", kind = .String}}},
			{name = "inline", kind = .Array, help = "parts shown in the body, never written", of = {
				{name = "filename", kind = .String},
				{name = "mime_type", kind = .String},
				{name = "size", kind = .Int},
				{name = "content_id", kind = .String},
			}},
		},
		examples = {
			"mailcore extract apps/mailcore/testdata/report.eml --out . --dry-run --json",
			"mailcore extract message.eml --out attachments --section 2 --json",
		},
		aliases = {"--extract"},
		run = cmd_extract,
	},
	{
		verb = "thread",
		summary = "a Maildir folder as conversations (JWZ threading, subjects gathered)",
		effect = .Read,
		flags = {
			{name = "root", kind = .String, help = "an account directory under the Maildir root; the root itself if omitted"},
			{name = "folder", kind = .String, help = "the folder", def = INBOX},
		},
		out = {
			{name = "root", kind = .String},
			{name = "folder", kind = .String},
			{name = "messages", kind = .Int},
			{name = "threads", kind = .Array, of = {
				{name = "subject", kind = .String},
				{name = "size", kind = .Int},
				{name = "rows", kind = .Array, of = {
					{name = "depth", kind = .Int},
					{name = "subject", kind = .String},
					{name = "message_id", kind = .String},
					{name = "missing", kind = .Bool, help = "a message others refer to that is not here"},
				}},
			}},
		},
		examples = {"mailcore thread --json", "mailcore thread --root alice@palm.test --folder INBOX --json"},
		aliases = {"--thread"},
		run = cmd_thread,
	},
	{
		verb = "folders",
		summary = "one account's folders, with total and unread counts",
		effect = .Read,
		args = {{name = "account", kind = .String, help = "the account directory under the Maildir root, e.g. alice@palm.test", required = true}},
		out = {
			{name = "account", kind = .String},
			{name = "root", kind = .String},
			{name = "folders", kind = .Array, of = {
				{name = "name", kind = .String},
				{name = "total", kind = .Int},
				{name = "unread", kind = .Int},
			}},
		},
		examples = {"mailcore folders alice@palm.test --json"},
		run = cmd_folders,
	},
	{
		verb = "list",
		summary = "the messages in one folder of one account, newest first",
		effect = .Read,
		args = {{name = "account", kind = .String, help = "the account directory under the Maildir root", required = true}},
		flags = {
			{name = "folder", kind = .String, help = "the folder", def = INBOX},
			{name = "limit", kind = .Int, help = "at most this many; 0 is all", def = "0"},
			{name = "unread", kind = .Bool, help = "only messages not yet seen"},
		},
		out = {
			{name = "account", kind = .String},
			{name = "folder", kind = .String},
			{name = "total", kind = .Int},
			{name = "messages", kind = .Array, of = {
				{name = "id", kind = .String, help = "the Maildir unique name"},
				{name = "subject", kind = .String},
				{name = "from", kind = .String},
				{name = "date", kind = .String},
				{name = "unix", kind = .Int},
				{name = "flags", kind = .String, help = "Maildir flag letters, e.g. RS"},
				{name = "unread", kind = .Bool},
				{name = "attachments", kind = .Int},
				{name = "size", kind = .Int},
			}},
		},
		examples = {"mailcore list alice@palm.test --folder INBOX --limit 20 --json", "mailcore list alice@palm.test --unread --json"},
		run = cmd_list,
	},
	{
		verb = "fetch",
		summary = "download a mailbox from a loopback IMAP, POP3 or JMAP server into the Maildir",
		effect = .Mutate,
		flags = {
			{name = "proto", kind = .Enum, values = {"imap", "pop3", "jmap"}, help = "the protocol", required = true},
			{name = "port", kind = .Int, help = "the server's port; there are no defaults", required = true},
			{name = "host", kind = .String, help = "a 127.0.0.0/8 address; nothing else is dialled", def = "127.0.0.1"},
			{name = "user", kind = .String, help = "the login"},
			{name = "password", kind = .String, help = "the password (kept out of the audit log)"},
			{name = "token", kind = .String, help = "a bearer token instead of a password (JMAP)"},
			{name = "token-file", kind = .Path, help = "read the token from this file"},
			{name = "account", kind = .String, help = "which JMAP account, by id or name"},
			{name = "folder", kind = .String, help = "the folder, or * for all of them", def = INBOX},
			{name = "root", kind = .String, help = "the account directory under the Maildir root; the user name if omitted"},
			{name = "tls", kind = .Enum, values = {"none", "verify", "insecure"}, def = "none", help = "TLS"},
			{name = "ca", kind = .Path, help = "a CA bundle for --tls verify"},
			{name = "trace", kind = .Bool, help = "the protocol conversation on stderr"},
		},
		out = {
			{name = "proto", kind = .String},
			{name = "host", kind = .String},
			{name = "port", kind = .Int},
			{name = "maildir", kind = .String},
			{name = "folders", kind = .Array, of = {
				{name = "folder", kind = .String},
				{name = "messages", kind = .Int},
				{name = "bytes", kind = .Int},
			}},
		},
		examples = {
			"mailcore fetch --proto imap --port 1143 --user alice --password alice-pw --folder \"*\" --json",
			"mailcore fetch --proto jmap --port 55580 --token-file token.txt --dry-run --json",
		},
		run = cmd_fetch,
	},
	{
		verb = "send",
		summary = "compose a message and submit it to a loopback SMTP server",
		effect = .Mutate,
		flags = {
			{name = "port", kind = .Int, help = "the server's port", required = true},
			{name = "to", kind = .String, help = "the recipient", required = true},
			{name = "host", kind = .String, help = "a 127.0.0.0/8 address", def = "127.0.0.1"},
			{name = "user", kind = .String, help = "the login, and the From address"},
			{name = "password", kind = .String, help = "the password (kept out of the audit log)"},
			{name = "token", kind = .String, help = "an access token, used as the password"},
			{name = "token-file", kind = .Path, help = "read the token from this file"},
			{name = "subject", kind = .String},
			{name = "text", kind = .String, help = "the body"},
			{name = "attach", kind = .Path, help = "a file to attach"},
			{name = "tls", kind = .Enum, values = {"none", "verify", "insecure"}, def = "none", help = "TLS"},
			{name = "ca", kind = .Path, help = "a CA bundle for --tls verify"},
			{name = "trace", kind = .Bool, help = "the protocol conversation on stderr"},
		},
		out = {
			{name = "message_id", kind = .String},
			{name = "bytes", kind = .Int},
			{name = "accepted", kind = .Array, of = {{kind = .String}}},
		},
		examples = {
			"mailcore send --port 1025 --user alice --password alice-pw --to bob@localhost --subject Hello --text \"Hi Bob\" --json",
			"mailcore send --port 1025 --to bob@localhost --subject Hello --dry-run --json",
		},
		run = cmd_send,
	},
	{
		verb = "login",
		summary = "sign in to a Palmy account (on loopback) and keep the session, mode 0600",
		effect = .Mutate,
		flags = {
			{name = "email", kind = .String, help = "the account", required = true},
			{name = "password", kind = .String, help = "the password (kept out of the audit log)"},
			{name = "password-file", kind = .Path, help = "read the password from this file"},
			{name = "auth-port", kind = .Int, def = "55529", help = "GoTrue on 127.0.0.1"},
			{name = "jmap-port", kind = .Int, def = "55580", help = "palm-maild's JMAP on 127.0.0.1"},
			{name = "submit-port", kind = .Int, def = "55587", help = "palm-maild's SMTP submission on 127.0.0.1"},
		},
		out = {
			{name = "email", kind = .String},
			{name = "signed_in", kind = .Bool},
			{name = "session", kind = .String, help = "where the session is kept"},
		},
		examples = {"mailcore login --email alice@example.test --password-file pw.txt --json"},
		run = cmd_login,
	},
	{
		verb = "sync",
		summary = "every identity the session reaches into its own Maildir (or only the one in scope)",
		effect = .Mutate,
		flags = {
			{name = "jmap-port", kind = .Int, help = "override the session's JMAP port"},
			{name = "submit-port", kind = .Int, help = "override the session's submission port"},
		},
		out = {
			{name = "email", kind = .String},
			{name = "config", kind = .String, help = "palmy.conf, naming each identity for apps/mail"},
			{name = "identities", kind = .Array, of = {
				{name = "address", kind = .String},
				{name = "handle", kind = .String},
				{name = "kind", kind = .String},
				{name = "messages", kind = .Int},
				{name = "pushed", kind = .Int, help = "flag changes pushed to the server"},
				{name = "submitted", kind = .Int, help = "queued messages handed to the server"},
				{name = "held", kind = .Int, help = "recipients the server held rather than sent"},
				{name = "error", kind = .String, opt = true},
			}},
		},
		examples = {"mailcore sync --json", "mailcore sync --identity work --json"},
		run = cmd_sync,
	},
	{
		verb = "status",
		summary = "whether a Palmy session is kept here, for whom, and for how long",
		effect = .Read,
		out = {
			{name = "signed_in", kind = .Bool},
			{name = "email", kind = .String},
			{name = "expires_in", kind = .Int, help = "seconds; 0 or less means sync will refresh it"},
		},
		examples = {"mailcore status --json"},
		run = cmd_status,
	},
	{
		verb = "logout",
		summary = "forget the session; the synced Maildirs stay where they are",
		effect = .Idempotent,
		out = {
			{name = "signed_out", kind = .Bool},
			{name = "removed", kind = .Bool, help = "there was a session to forget"},
		},
		examples = {"mailcore logout --json"},
		run = cmd_logout,
	},
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "mailcore",
			summary  = "the mail engine: Maildir, MIME, IMAP, POP3, JMAP and SMTP, loopback only",
			gui      = false,
			selftest = cli_selftest,
			commands = COMMANDS,
			notes    = `Every network command refuses any host outside 127.0.0.0/8 and this
program never resolves a name. The Maildir root is $XDG_DATA_HOME/palmy-mail.
The older spellings still work: --layout, --parse FILE, --extract FILE and
--thread are aliases, and "mailcore palm login|sync|status|logout" is the
same as "mailcore login|sync|status|logout".`,
		}
	}
	return &g_surface
}

// cli_selftest is --selftest, with the options it has always taken read
// from the command line: kit hands over control the moment it sees the flag.
cli_selftest :: proc() -> int {
	rest := make([dynamic]string, context.temp_allocator)
	for a in os.args[1:] {
		if a != "--selftest" && a != "--self-test" {
			append(&rest, a)
		}
	}
	return cmd_selftest(rest[:])
}

// cli_main is main. The two legacy shapes are folded into the declared ones
// here and nowhere else: `palm <verb>` loses its prefix, and secrets leave the
// command line.
cli_main :: proc(args: []string) -> int {
	argv := args
	if len(argv) == 0 {
		fmt.eprint(kit.cli_help_text(surface()))
		return kit.EXIT_USAGE
	}
	if argv[0] == "palm" {
		if len(argv) == 1 {
			fmt.eprint(kit.cli_help_text(surface()))
			return kit.EXIT_USAGE
		}
		argv = argv[1:]
	}
	argv = scrub_secrets(argv)
	code, _ := kit.cli_args(surface(), argv)
	return code
}

// ---------------------------------------------------------------------------
// Secrets
//
// kit writes the argv of every command that is not a read into the audit log,
// and a password given as --password would land there in clear. The kit has
// no notion of a secret parameter, so the value is lifted out here, before
// the kit ever sees it, and the command line carries a placeholder instead.
// ---------------------------------------------------------------------------

SECRET_FLAGS :: [?]string{"password", "token"}
REDACTED :: "<redacted>"

@(private = "file")
g_secrets: map[string]string

scrub_secrets :: proc(args: []string) -> []string {
	out := make([dynamic]string, 0, len(args), context.allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		matched := false
		for name in SECRET_FLAGS {
			flag := fmt.tprintf("--%s", name)
			if a == flag && i + 1 < len(args) {
				g_secrets[name] = args[i + 1]
				append(&out, flag, REDACTED)
				i += 1
				matched = true
				break
			}
			if strings.has_prefix(a, fmt.tprintf("%s=", flag)) {
				g_secrets[name] = a[len(flag) + 1:]
				append(&out, fmt.aprintf("%s=%s", flag, REDACTED))
				matched = true
				break
			}
		}
		if !matched {
			append(&out, a)
		}
	}
	return out[:]
}

// secret is a secret flag's real value.
@(private = "file")
secret :: proc(c: ^kit.Call, name: string) -> string {
	v := kit.cli_str(c, name)
	if v == REDACTED {
		return g_secrets[name]
	}
	return v
}

// secret_or_file is a secret flag, or the trimmed contents of its -file twin.
@(private = "file")
secret_or_file :: proc(c: ^kit.Call, name: string) -> (v: string, err: string) {
	file := kit.cli_str(c, fmt.tprintf("%s-file", name))
	if file != "" {
		data, rerr := os.read_entire_file_from_path(file, context.allocator)
		if rerr != nil {
			return "", fmt.aprintf("cannot read %s", file)
		}
		return strings.trim_space(string(data)), ""
	}
	return secret(c, name), ""
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

@(private = "file")
addrs_json :: proc(list: []Address) -> ^kit.Json {
	a := kit.jarr()
	for it in list {
		o := kit.jobj()
		kit.jset_str(o, "name", it.name)
		kit.jset_str(o, "email", it.email)
		kit.jpush(a, o)
	}
	return a
}

@(private = "file")
strs_json :: proc(list: []string) -> ^kit.Json {
	a := kit.jarr()
	for s in list {
		kit.jpush(a, kit.jstr(s))
	}
	return a
}

@(private = "file")
iso_utc :: proc(unix: i64) -> string {
	t := time.unix(unix, 0)
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

@(private = "file")
read_message :: proc(c: ^kit.Call, path: string) -> (m: Message, code: int) {
	if !os.exists(path) {
		return m, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s does not exist", path)
	}
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return m, kit.cli_failf(c, kit.EXIT_FAILED, "cannot read %s: %v", path, err)
	}
	return parse_message(data, context.allocator), kit.EXIT_OK
}

// account_dir resolves an account under the Maildir root without creating
// anything, and checks the identity in scope may see it.
@(private = "file")
account_dir :: proc(c: ^kit.Call, account: string) -> (path: string, code: int) {
	p, perr := resolve_root(account)
	if perr != "" {
		return "", kit.cli_fail(c, kit.EXIT_USAGE, perr)
	}
	if owner := account_identity(account); owner != "" && !kit.cli_scope_require(c, owner) {
		return "", kit.EXIT_OUT_OF_SCOPE
	}
	if !os.is_dir(p) {
		return "", kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no Maildir at %s", p)
	}
	return p, kit.EXIT_OK
}

// account_identity is the identity that owns an account directory, as the
// last sync wrote it into palmy.conf — the handle, or "" when the account was
// not synced from a Palmy session (a loopback fetch) and so belongs to no
// identity in particular.
account_identity :: proc(account: string) -> string {
	conf := strings.concatenate({maildir_default_root(context.temp_allocator), "/palmy.conf"}, context.temp_allocator)
	data, err := os.read_entire_file_from_path(conf, context.temp_allocator)
	if err != nil {
		return ""
	}
	handle, address, path := "", "", ""
	found := ""
	text := string(data)
	flush :: proc(account, handle, address, path: string, found: ^string) {
		if found^ == "" && handle != "" && (account == address || account == path) {
			found^ = handle
		}
	}
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "[identity]" || l == "[session]" {
			flush(account, handle, address, path, &found)
			handle, address, path = "", "", ""
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		k, v := strings.trim_space(l[:eq]), strings.trim_space(l[eq + 1:])
		switch k {
		case "handle":
			handle = v
		case "address":
			address = v
		case "path":
			path = v
		}
	}
	flush(account, handle, address, path, &found)
	return strings.clone(found)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

cmd_layout :: proc(c: ^kit.Call) -> int {
	kit.jset_str(c.out, "root", maildir_default_root())
	kit.jset_str(c.out, "text", LAYOUT_TEXT)
	return kit.EXIT_OK
}

cmd_parse :: proc(c: ^kit.Call) -> int {
	file := kit.cli_str(c, "file")
	m, code := read_message(c, file)
	if code != kit.EXIT_OK {
		return code
	}
	o := c.out
	kit.jset_str(o, "file", file)
	kit.jset_str(o, "subject", m.subject)
	kit.jset(o, "from", addrs_json(m.from))
	kit.jset(o, "to", addrs_json(m.to))
	kit.jset(o, "cc", addrs_json(m.cc))
	kit.jset_str(o, "date", m.date_raw)
	if m.date.ok {
		kit.jset_i64(o, "unix", m.date.unix)
		kit.jset_str(o, "iso", iso_utc(m.date.unix))
	}
	kit.jset_str(o, "message_id", m.message_id)
	kit.jset(o, "references", strs_json(m.references))
	parts := kit.jarr()
	walk :: proc(arr: ^kit.Json, p: ^Part, depth: int) {
		e := kit.jobj()
		kit.jset_str(e, "section", p.section)
		kit.jset_int(e, "depth", depth)
		kit.jset_str(e, "type", fmt.aprintf("%s/%s", p.main, p.sub))
		kit.jset_str(e, "encoding", p.encoding)
		kit.jset_str(e, "charset", p.charset_name)
		kit.jset_int(e, "raw_bytes", len(p.raw_body))
		kit.jset_int(e, "decoded_bytes", len(p.content))
		kit.jset_str(e, "filename", p.filename)
		kit.jset_bool(e, "unterminated", p.unterminated)
		kit.jpush(arr, e)
		for i in 0 ..< len(p.parts) {
			walk(arr, &p.parts[i], depth + 1)
		}
	}
	walk(parts, &m.root, 0)
	kit.jset(o, "parts", parts)
	kit.jset_int(o, "text_plain_bytes", len(m.text_plain))
	kit.jset_int(o, "text_html_bytes", len(m.text_html))
	kit.jset_str(o, "preview", m.preview)
	kit.jset_bool(o, "parts_differ", m.parts_differ)
	atts := kit.jarr()
	for a in m.attachments {
		e := kit.jobj()
		kit.jset_str(e, "filename", a.filename)
		kit.jset_str(e, "mime_type", a.mime_type)
		kit.jset_int(e, "size", a.size)
		kit.jset_bool(e, "inline", a.is_inline)
		kit.jset_str(e, "content_id", a.content_id)
		kit.jset_str(e, "section", a.section)
		kit.jpush(atts, e)
	}
	kit.jset(o, "attachments", atts)
	kit.jset(o, "warnings", strs_json(m.warnings))
	return kit.EXIT_OK
}

// cmd_extract is the other half of `parse`: not "what parts are in here" but
// "put them on disk". Every byte written is the transfer-decoded content, and
// every name goes through the sanitiser and then the containment check, so a
// message whose filename is "../../.bashrc" writes ".bashrc" into the
// directory that was asked for and nowhere else.
cmd_extract :: proc(c: ^kit.Call) -> int {
	file := kit.cli_str(c, "file")
	out_dir := kit.cli_str(c, "out")
	section := kit.cli_str(c, "section")
	force := kit.cli_bool(c, "force")
	m, code := read_message(c, file)
	if code != kit.EXIT_OK {
		return code
	}
	if !os.is_dir(out_dir) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s is not a directory", out_dir)
	}
	written := kit.jarr()
	failed := kit.jarr()
	n_failed := 0
	for s in message_saveable(&m, context.allocator) {
		if section != "" && s.section != section {
			continue
		}
		path := ""
		if c.dry_run {
			path = fmt.aprintf("%s/%s", strings.trim_right(out_dir, "/"), s.filename)
		} else {
			p, werr := attachment_write(out_dir, s, force, context.allocator)
			if werr != "" {
				e := kit.jobj()
				kit.jset_str(e, "filename", s.filename)
				kit.jset_str(e, "error", werr)
				kit.jpush(failed, e)
				n_failed += 1
				kit.cli_note(c, "mailcore: %s: %s", s.filename, werr)
				continue
			}
			path = p
		}
		e := kit.jobj()
		kit.jset_str(e, "filename", s.filename)
		kit.jset_str(e, "mime_type", s.mime_type)
		kit.jset_int(e, "size", s.size)
		kit.jset_str(e, "path", path)
		kit.jpush(written, e)
	}
	inl := kit.jarr()
	for a in message_inline_parts(&m, context.allocator) {
		e := kit.jobj()
		kit.jset_str(e, "filename", a.filename)
		kit.jset_str(e, "mime_type", a.mime_type)
		kit.jset_int(e, "size", a.size)
		kit.jset_str(e, "content_id", a.content_id)
		kit.jpush(inl, e)
	}
	kit.jset_str(c.out, "file", file)
	kit.jset_str(c.out, "out", out_dir)
	kit.jset(c.out, "written", written)
	kit.jset(c.out, "failed", failed)
	kit.jset(c.out, "inline", inl)
	if n_failed > 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%d attachment(s) could not be written", n_failed)
	}
	return kit.EXIT_OK
}

cmd_thread :: proc(c: ^kit.Call) -> int {
	given := kit.cli_str(c, "root")
	folder := kit.cli_str(c, "folder")
	path := ""
	if given == "" {
		path = maildir_default_root(context.allocator)
		if !os.is_dir(path) {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no Maildir at %s", path)
		}
	} else {
		p, code := account_dir(c, given)
		if code != kit.EXIT_OK {
			return code
		}
		path = p
	}
	md := Maildir {
		root = path,
	}
	th, items := maildir_thread(&md, folder, true, context.allocator)
	threads := kit.jarr()
	for r in th.roots {
		t := kit.jobj()
		rows := kit.jarr()
		subject := ""
		size := 0
		for row in thread_flatten(th, r, context.allocator) {
			e := kit.jobj()
			kit.jset_int(e, "depth", row.depth)
			if row.item < 0 {
				kit.jset_str(e, "subject", "")
				kit.jset_str(e, "message_id", "")
				kit.jset_bool(e, "missing", true)
			} else {
				it := items[row.item]
				if subject == "" {
					subject = it.subject
				}
				size += 1
				kit.jset_str(e, "subject", it.subject)
				kit.jset_str(e, "message_id", it.message_id)
				kit.jset_bool(e, "missing", false)
			}
			kit.jpush(rows, e)
		}
		kit.jset_str(t, "subject", subject)
		kit.jset_int(t, "size", size)
		kit.jset(t, "rows", rows)
		kit.jpush(threads, t)
	}
	kit.jset_str(c.out, "root", path)
	kit.jset_str(c.out, "folder", folder)
	kit.jset_int(c.out, "messages", len(items))
	kit.jset(c.out, "threads", threads)
	return kit.EXIT_OK
}

cmd_folders :: proc(c: ^kit.Call) -> int {
	account := kit.cli_str(c, "account")
	path, code := account_dir(c, account)
	if code != kit.EXIT_OK {
		return code
	}
	md := Maildir {
		root = path,
	}
	arr := kit.jarr()
	for f in maildir_folders(&md, context.allocator) {
		entries := maildir_list(&md, f, context.allocator)
		unread := 0
		for e in entries {
			if .Seen not_in e.flags {
				unread += 1
			}
		}
		o := kit.jobj()
		kit.jset_str(o, "name", f)
		kit.jset_int(o, "total", len(entries))
		kit.jset_int(o, "unread", unread)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "account", account)
	kit.jset_str(c.out, "root", path)
	kit.jset(c.out, "folders", arr)
	return kit.EXIT_OK
}

cmd_list :: proc(c: ^kit.Call) -> int {
	account := kit.cli_str(c, "account")
	folder := kit.cli_str(c, "folder")
	limit := kit.cli_int(c, "limit")
	only_unread := kit.cli_bool(c, "unread")
	path, code := account_dir(c, account)
	if code != kit.EXIT_OK {
		return code
	}
	md := Maildir {
		root = path,
	}
	if folder != INBOX && !os.is_dir(maildir_folder_dir(&md, folder, context.temp_allocator)) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s has no folder %q", account, folder)
	}
	Row :: struct {
		e: Maildir_Entry,
		m: Message,
	}
	rows := make([dynamic]Row, context.allocator)
	for e in maildir_list(&md, folder, context.allocator) {
		if only_unread && .Seen in e.flags {
			continue
		}
		data, rerr := maildir_read(e, context.allocator)
		if rerr != "" {
			kit.cli_note(c, "mailcore: %s", rerr)
			continue
		}
		append(&rows, Row{e = e, m = parse_message(data, context.allocator)})
	}
	slice.sort_by(rows[:], proc(a, b: Row) -> bool {
		if a.m.date.unix != b.m.date.unix {
			return a.m.date.unix > b.m.date.unix
		}
		return a.e.unique > b.e.unique
	})
	arr := kit.jarr()
	for &r, i in rows {
		if limit > 0 && i >= limit {
			break
		}
		o := kit.jobj()
		kit.jset_str(o, "id", r.e.unique)
		kit.jset_str(o, "subject", r.m.subject)
		from := ""
		if len(r.m.from) > 0 {
			f := r.m.from[0]
			from = f.name != "" ? fmt.aprintf("%s <%s>", f.name, f.email) : f.email
		}
		kit.jset_str(o, "from", from)
		kit.jset_str(o, "date", r.m.date.ok ? iso_utc(r.m.date.unix) : r.m.date_raw)
		kit.jset_i64(o, "unix", r.m.date.ok ? r.m.date.unix : 0)
		kit.jset_str(o, "flags", maildir_flags_string(r.e.flags))
		kit.jset_bool(o, "unread", .Seen not_in r.e.flags)
		kit.jset_int(o, "attachments", len(message_saveable(&r.m, context.temp_allocator)))
		kit.jset_i64(o, "size", r.e.size)
		kit.jpush(arr, o)
	}
	kit.jset_str(c.out, "account", account)
	kit.jset_str(c.out, "folder", folder)
	kit.jset_int(c.out, "total", len(rows))
	kit.jset(c.out, "messages", arr)
	return kit.EXIT_OK
}

@(private = "file")
dial_opts :: proc(c: ^kit.Call) -> Dial_Opts {
	mode := Tls_Mode.None
	switch kit.cli_str(c, "tls") {
	case "verify":
		mode = .Verify
	case "insecure":
		mode = .Insecure
	}
	return Dial_Opts{tls = mode, ca_file = kit.cli_str(c, "ca"), trace = kit.cli_bool(c, "trace")}
}

// loopback_only is checked before anything else happens, so a refusal is the
// same whether or not the run is a dry one. conn_dial refuses the same
// addresses again at the socket; this is the earlier, clearer answer.
@(private = "file")
loopback_only :: proc(c: ^kit.Call) -> int {
	host := kit.cli_str(c, "host")
	if !strings.has_prefix(host, "127.") {
		kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "refusing %q: mailcore only talks to 127.0.0.0/8 and resolves no names", host)
		kit.cli_err_field(c, "host", host)
		return kit.EXIT_OUT_OF_SCOPE
	}
	return kit.EXIT_OK
}

@(private = "file")
fetch_row :: proc(arr: ^kit.Json, folder: string, n, bytes: int) {
	o := kit.jobj()
	kit.jset_str(o, "folder", folder)
	kit.jset_int(o, "messages", n)
	kit.jset_int(o, "bytes", bytes)
	kit.jpush(arr, o)
}

cmd_fetch :: proc(c: ^kit.Call) -> int {
	if code := loopback_only(c); code != kit.EXIT_OK {
		return code
	}
	proto := kit.cli_str(c, "proto")
	host := kit.cli_str(c, "host")
	port := kit.cli_int(c, "port")
	user := kit.cli_str(c, "user")
	folder := kit.cli_str(c, "folder")
	password := secret(c, "password")
	token, terr := secret_or_file(c, "token")
	if terr != "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, terr)
	}
	given := kit.cli_str(c, "root")
	root, rerr := resolve_root(given != "" ? given : (user == "" ? "account" : user))
	if rerr != "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, rerr)
	}
	kit.jset_str(c.out, "proto", proto)
	kit.jset_str(c.out, "host", host)
	kit.jset_int(c.out, "port", port)
	kit.jset_str(c.out, "maildir", root)
	rows := kit.jarr()
	kit.jset(c.out, "folders", rows)
	if c.dry_run {
		// Nothing is dialled and nothing is created: the plan is the
		// protocol, the server and where the mail would land.
		return kit.EXIT_OK
	}
	md, oerr := maildir_open(root, context.allocator)
	if oerr != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, oerr)
	}
	opts := dial_opts(c)

	switch proto {
	case "imap":
		im: IMAP
		if err := imap_connect(&im, host, port, opts, context.allocator); err != "" {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
		}
		defer imap_close(&im)
		if err := imap_login(&im, user, password); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		if folder == "*" {
			results, err := imap_sync_all(&im, &md, context.allocator)
			if err != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, err)
			}
			for r in results {
				fetch_row(rows, r.folder, r.fetched, r.bytes)
			}
		} else {
			r, err := imap_sync(&im, &md, folder, folder, context.allocator)
			if err != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, err)
			}
			fetch_row(rows, r.folder, r.fetched, r.bytes)
		}
		imap_logout(&im)

	case "pop3":
		p: POP3
		if err := pop3_connect(&p, host, port, opts, context.allocator); err != "" {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
		}
		defer pop3_close(&p)
		pop3_capa(&p)
		if err := pop3_login(&p, user, password); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		// POP3 has no folders: only INBOX can be filled, and the existing
		// UIDLs are used so a second run is a no-op.
		seen := make(map[string]bool, 64, context.allocator)
		r, err := pop3_sync(&p, &md, seen, context.allocator)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		fetch_row(rows, INBOX, r.fetched, r.bytes)
		pop3_quit(&p)

	case "jmap":
		j: JMAP
		err: string
		if token != "" {
			err = jmap_connect_bearer(&j, host, port, token, opts, context.allocator)
		} else {
			err = jmap_connect(&j, host, port, user, password, opts, context.allocator)
		}
		if err == "" && kit.cli_str(c, "account") != "" {
			err = jmap_use_account(&j, kit.cli_str(c, "account"))
		}
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		defer jmap_close(&j)
		boxes, berr := jmap_mailbox_get(&j, context.allocator)
		if berr != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, berr)
		}
		for b in boxes {
			if folder != "*" && !strings.equal_fold(b.name, folder) && !(folder == INBOX && strings.equal_fold(b.role, "inbox")) {
				continue
			}
			name := strings.equal_fold(b.role, "inbox") ? INBOX : b.name
			r, serr := jmap_sync(&j, &md, b.id, name, context.allocator)
			if serr != "" {
				return kit.cli_fail(c, kit.EXIT_FAILED, serr)
			}
			fetch_row(rows, r.folder, r.fetched, r.bytes)
		}
	}
	return kit.EXIT_OK
}

cmd_send :: proc(c: ^kit.Call) -> int {
	if code := loopback_only(c); code != kit.EXIT_OK {
		return code
	}
	host := kit.cli_str(c, "host")
	port := kit.cli_int(c, "port")
	user := kit.cli_str(c, "user")
	to := kit.cli_str(c, "to")
	text := kit.cli_str(c, "text")
	attach := kit.cli_str(c, "attach")
	token, terr := secret_or_file(c, "token")
	if terr != "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, terr)
	}
	from := user
	if !strings.contains(from, "@") {
		from = fmt.tprintf("%s@localhost", from == "" ? "mailcore" : from)
	}
	msg := Compose {
		from    = {email = from},
		to      = {{email = to}},
		subject = kit.cli_str(c, "subject"),
		text    = text == "" ? "(no body)\n" : strings.concatenate({text, "\n"}, context.allocator),
	}
	if attach != "" {
		data, rerr := os.read_entire_file_from_path(attach, context.allocator)
		if rerr != nil {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s: %v", attach, rerr)
		}
		name := attach
		if i := strings.last_index_byte(name, '/'); i >= 0 {
			name = name[i + 1:]
		}
		msg.attachments = {{filename = name, content = data}}
	}
	body, msgid := compose_build(msg, context.allocator)
	kit.jset_str(c.out, "message_id", msgid)
	kit.jset_int(c.out, "bytes", len(body))
	accepted := kit.jarr()
	kit.jset(c.out, "accepted", accepted)
	if c.dry_run {
		// Composed, measured, and not sent: nothing is dialled.
		return kit.EXIT_OK
	}

	s: SMTP
	if err := smtp_connect(&s, host, port, dial_opts(c), context.allocator); err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	defer smtp_close(&s)
	if err := smtp_ehlo(&s, "mailcore"); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	if user != "" {
		// A Palmy submission server takes the access token as the password.
		pw := token != "" ? token : secret(c, "password")
		if err := smtp_auth_plain(&s, user, pw); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	}
	got, serr := smtp_send(&s, compose_envelope(msg, body, context.allocator))
	if serr != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, serr)
	}
	for a in got {
		kit.jpush(accepted, kit.jstr(a))
	}
	smtp_quit(&s)
	return kit.EXIT_OK
}

cmd_login :: proc(c: ^kit.Call) -> int {
	s := Palm_Session {
		email       = kit.cli_str(c, "email"),
		auth_port   = kit.cli_int(c, "auth-port", 55529),
		jmap_port   = kit.cli_int(c, "jmap-port", 55580),
		submit_port = kit.cli_int(c, "submit-port", 55587),
	}
	password, perr := secret_or_file(c, "password")
	if perr != "" {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, perr)
	}
	if password == "" {
		return kit.cli_fail(c, kit.EXIT_USAGE, "--password or --password-file is required")
	}
	kit.jset_str(c.out, "email", s.email)
	kit.jset_str(c.out, "session", palm_session_path())
	if c.dry_run {
		kit.jset_bool(c.out, "signed_in", false)
		return kit.EXIT_OK
	}
	if e := palm_login(&s, password); e != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, e)
	}
	kit.jset_bool(c.out, "signed_in", true)
	return kit.EXIT_OK
}

cmd_sync :: proc(c: ^kit.Call) -> int {
	s, ok := palm_load()
	if !ok {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "not signed in (mailcore login)")
	}
	if kit.cli_has(c, "jmap-port") {
		s.jmap_port = kit.cli_int(c, "jmap-port")
	}
	if kit.cli_has(c, "submit-port") {
		s.submit_port = kit.cli_int(c, "submit-port")
	}
	kit.jset_str(c.out, "email", s.email)
	kit.jset_str(c.out, "config", strings.concatenate({maildir_default_root(context.temp_allocator), "/palmy.conf"}))
	ids := kit.jarr()
	kit.jset(c.out, "identities", ids)
	if c.dry_run {
		return kit.EXIT_OK
	}
	if e := palm_fresh(&s); e != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, e)
	}
	rows, _, err := palm_sync(&s, c.identity)
	failed := 0
	for r in rows {
		o := kit.jobj()
		kit.jset_str(o, "address", r.address)
		kit.jset_str(o, "handle", r.handle)
		kit.jset_str(o, "kind", r.kind)
		kit.jset_int(o, "messages", r.messages)
		kit.jset_int(o, "pushed", r.pushed)
		kit.jset_int(o, "submitted", r.submitted)
		kit.jset_int(o, "held", r.held)
		if r.error != "" {
			kit.jset_str(o, "error", r.error)
			kit.cli_note(c, "mailcore: %s: %s", r.address, r.error)
			failed += 1
		}
		kit.jpush(ids, o)
	}
	if err != "" {
		return kit.cli_fail(c, len(rows) == 0 ? kit.EXIT_UNAVAILABLE : kit.EXIT_FAILED, err)
	}
	if failed > 0 {
		return kit.cli_failf(c, kit.EXIT_FAILED, "%d identit%s did not sync", failed, failed == 1 ? "y" : "ies")
	}
	return kit.EXIT_OK
}

// cmd_status keeps the old exit status for "not signed in" — non-zero — so a
// script that ran `mailcore palm status && ...` reads the same; it is now the
// documented "not found", with the documented error object under --json.
cmd_status :: proc(c: ^kit.Call) -> int {
	s, ok := palm_load()
	if !ok {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "not signed in")
	}
	left := s.expires_at - time.time_to_unix(time.now())
	kit.jset_bool(c.out, "signed_in", true)
	kit.jset_str(c.out, "email", s.email)
	kit.jset_i64(c.out, "expires_in", left)
	return kit.EXIT_OK
}

cmd_logout :: proc(c: ^kit.Call) -> int {
	removed := os.exists(palm_session_path())
	if !c.dry_run {
		removed = palm_logout()
	}
	kit.jset_bool(c.out, "signed_out", true)
	kit.jset_bool(c.out, "removed", removed)
	return kit.EXIT_OK
}
