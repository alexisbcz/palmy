package main

// The command line: `vault <verb>`, or `palm vault <verb>`.
//
// Everything goes through the same engine as the window (book.odin). Three
// rules from docs/PALM-CLI.md bite hardest here:
//
//   - **No secret is printed unless the command was asked for it.** `get`
//     masks the password, the TOTP seed, secret fields and the passkey key;
//     `--reveal` prints them; `--field password` prints exactly that one
//     value and nothing else. `totp` prints a code, because a code is what it
//     is for. `list` prints titles, usernames and sites, never a secret.
//   - **Scope only narrows.** PALM_IDENTITY limits every verb to one
//     identity's vaults; `--identity` can narrow it, never widen it (exit 5).
//     There is no verb that lists secrets across identities.
//   - **The master password never goes through argv**, where every process on
//     the machine can read it in /proc. --password-file, or
//     PALM_VAULT_PASSWORD for a scripted demo (weaker: /proc/<pid>/environ is
//     readable by the same user).
//
// And one more of its own: **an assistant gets nothing.** A process holding
// a delegated assistant session (PALM_CLOUD_SESSION) is refused before
// anything is opened. The server refuses it too (vault_session_ok in the
// migration); this is the same rule said twice, so neither is load-bearing
// alone.

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."

@(private = "file")
ITEM_FIELDS :: []kit.Field {
	{name = "id", kind = .String},
	{name = "kind", kind = .String, help = "login, passkey, card, note, document, totp"},
	{name = "title", kind = .String},
	{name = "username", kind = .String},
	{name = "url", kind = .String},
	{name = "identity", kind = .String, help = "the identity it is seen as; \"\" for the local file"},
	{name = "vault", kind = .String},
	{name = "has_totp", kind = .Bool},
	{name = "tags", kind = .Array, of = {{kind = .String}}},
}

@(private = "file")
PW :: kit.Param{name = "password-file", kind = .Path, help = "a file holding the master password (never pass it as an argument)"}
@(private = "file")
LOCAL :: kit.Param{name = "local", kind = .Bool, help = "use the local vault file even on a device enrolled in an account"}
@(private = "file")
VAULTF :: kit.Param{name = "vault-file", kind = .Path, help = "the local vault file to use"}
@(private = "file")
OFFLINE :: kit.Param{name = "offline", kind = .Bool, help = "do not sync first; use what this device has"}

@(private = "file")
COMMANDS := []kit.Command {
	{
		verb = "status",
		summary = "which vault this device opens, whether it is enrolled, and what is waiting to sync",
		effect = .Read,
		flags = {LOCAL, VAULTF},
		out = {
			{name = "mode", kind = .String, help = "local or account"},
			{name = "path", kind = .String},
			{name = "exists", kind = .Bool},
			{name = "enrolled", kind = .Bool},
			{name = "email", kind = .String, opt = true},
			{name = "identities", kind = .Array, opt = true, of = {{kind = .String}}},
			{name = "pending", kind = .Int},
			{name = "synced_at", kind = .Int},
		},
		examples = {"vault status --json"},
		run = cmd_status,
	},
	{
		verb = "where",
		summary = "where the vault lives and why: which environment variable chose the directory",
		effect = .Read,
		out = {{name = "data_dir", kind = .String}, {name = "source", kind = .String}, {name = "account_dir", kind = .String}},
		examples = {"vault where --json"},
		run = cmd_where,
	},
	{
		verb = "setup",
		summary = "create the account vault on its first device: Secret Key, keys and a vault per identity",
		effect = .Mutate,
		flags = {PW},
		out = {{name = "secret_key", kind = .String, help = "shown once: write it down"}, {name = "identities", kind = .Array, of = {{kind = .String}}}},
		examples = {"vault setup --password-file ~/.vault-pw"},
		run = cmd_setup,
	},
	{
		verb = "enroll",
		summary = "add this device to the account vault: with the Secret Key, or by asking an enrolled device",
		effect = .Mutate,
		flags = {
			{name = "secret-key-file", kind = .Path, help = "a file holding the Secret Key from the emergency kit"},
			{name = "request", kind = .Bool, help = "ask an enrolled device to approve this one; prints a code to compare"},
			{name = "name", kind = .String, help = "what to call this device", def = "this device"},
			{name = "wait", kind = .Bool, help = "check whether the request has been approved"},
		},
		out = {{name = "enrolled", kind = .Bool}, {name = "device_id", kind = .String, opt = true}, {name = "code", kind = .String, opt = true}},
		examples = {"vault enroll --request --identity alice --json", "vault enroll --wait", "vault enroll --secret-key-file kit.txt"},
		run = cmd_enroll,
	},
	{
		verb = "devices",
		summary = "the devices enrolled in the vault of the identity in scope, and requests waiting",
		effect = .Read,
		out = {{name = "devices", kind = .Array, of = {
			{name = "id", kind = .String}, {name = "identity", kind = .String}, {name = "name", kind = .String},
			{name = "approved", kind = .Bool}, {name = "revoked", kind = .Bool}, {name = "code", kind = .String},
		}}},
		examples = {"vault devices --json"},
		run = cmd_devices,
	},
	{
		verb = "approve",
		summary = "approve a new device after checking that its code matches: seals the Secret Key to it",
		effect = .Mutate,
		args = {{name = "device", kind = .String, required = true}},
		flags = {{name = "code", kind = .String, required = true, help = "the six digits the new device shows"}},
		out = {{name = "approved", kind = .Bool}},
		examples = {"vault approve 3f2a... --code \"123 456\""},
		run = cmd_approve,
	},
	{
		verb = "sync",
		summary = "push this device's edits and pull everyone else's, merging conflicts per item",
		effect = .Idempotent,
		flags = {PW},
		out = {
			{name = "pulled", kind = .Int}, {name = "pushed", kind = .Int}, {name = "merged", kind = .Int},
			{name = "conflicted", kind = .Int}, {name = "dropped", kind = .Int}, {name = "removed", kind = .Int},
			{name = "items", kind = .Int},
		},
		examples = {"vault sync --password-file ~/.vault-pw --json"},
		run = cmd_sync,
	},
	{
		verb = "list",
		summary = "items: titles, usernames, sites and where they live -- never a secret",
		effect = .Read,
		flags = {PW, LOCAL, VAULTF, OFFLINE, {name = "search", kind = .String, help = "only items matching this"}},
		out = {{name = "items", kind = .Array, of = ITEM_FIELDS}, {name = "count", kind = .Int}},
		examples = {"vault list --json", "PALM_IDENTITY=work vault list --search github"},
		run = cmd_list,
	},
	{
		verb = "get",
		summary = "one item; secrets masked unless --reveal, or exactly one value with --field",
		effect = .Read,
		args = {{name = "item", kind = .String, required = true, help = "an id, a title, or part of one"}},
		flags = {PW, LOCAL, VAULTF, OFFLINE,
			{name = "reveal", kind = .Bool, help = "print the secrets too"},
			{name = "field", kind = .Enum, values = {"password", "username", "url", "totp", "notes", "title"}, help = "print only this value, raw"},
		},
		out = {
			{name = "item", kind = .Object, of = ITEM_FIELDS},
			{name = "password", kind = .String, help = "masked unless --reveal"},
			{name = "notes", kind = .String, help = "masked unless --reveal"},
			{name = "fields", kind = .Array, of = {{name = "label", kind = .String}, {name = "value", kind = .String}, {name = "secret", kind = .Bool}}},
			{name = "revealed", kind = .Bool},
		},
		examples = {"vault get github --json", "vault get github --field password"},
		run = cmd_get,
	},
	{
		verb = "totp",
		summary = "the current one-time code of an item, and the seconds it has left",
		effect = .Read,
		args = {{name = "item", kind = .String, required = true}},
		flags = {PW, LOCAL, VAULTF, OFFLINE},
		out = {{name = "code", kind = .String}, {name = "remaining", kind = .Int}, {name = "title", kind = .String}},
		examples = {"vault totp github --json"},
		run = cmd_totp,
	},
	{
		verb = "add",
		summary = "add a login; the password is generated unless --secret-file gives one",
		effect = .Mutate,
		flags = {PW, LOCAL, VAULTF, OFFLINE,
			{name = "title", kind = .String, required = true},
			{name = "username", kind = .String},
			{name = "url", kind = .String},
			{name = "tags", kind = .String},
			{name = "secret-file", kind = .Path, help = "a file holding the item's password"},
			{name = "length", kind = .Int, def = "24"},
			{name = "vault", kind = .String, help = "which vault (by name); default the identity's own"},
		},
		out = {{name = "item", kind = .Object, of = ITEM_FIELDS}},
		examples = {"vault add --title GitHub --username alice --url https://github.com"},
		run = cmd_add,
	},
	{
		verb = "rm",
		summary = "delete an item (a tombstone that reaches every device)",
		effect = .Destructive,
		args = {{name = "item", kind = .String, required = true}},
		flags = {PW, LOCAL, VAULTF, OFFLINE},
		out = {{name = "removed", kind = .String}},
		examples = {"vault rm \"Old router\" --yes"},
		run = cmd_rm,
	},
	{
		verb = "share",
		summary = "share one item (read-only) or a whole vault with another identity, yours or someone else's",
		effect = .Mutate,
		args = {{name = "item", kind = .String, help = "the item to share; omit with --vault"}},
		flags = {PW,
			{name = "with", kind = .String, required = true, help = "the identity's handle"},
			{name = "vault", kind = .String, help = "share this whole vault instead of one item"},
			{name = "role", kind = .Enum, values = {"read", "write"}, def = "read"},
		},
		out = {{name = "shared", kind = .String}, {name = "with", kind = .String}, {name = "fingerprint", kind = .String}},
		examples = {"vault share github --with bob", "vault share --vault Work --with alice --role write"},
		run = cmd_share,
	},
	{
		verb = "shares",
		summary = "shares made and received by the identities in scope",
		effect = .Read,
		flags = {PW, OFFLINE},
		out = {{name = "shares", kind = .Array, of = {
			{name = "id", kind = .String}, {name = "from", kind = .String}, {name = "to", kind = .String},
			{name = "what", kind = .String}, {name = "role", kind = .String}, {name = "revoked", kind = .Bool},
			{name = "verified", kind = .Bool},
		}}},
		examples = {"vault shares --json"},
		run = cmd_shares,
	},
	{
		verb = "revoke",
		summary = "revoke a share, then rotate the key so what is written next is closed to the old grantee",
		effect = .Destructive,
		args = {{name = "share", kind = .String, required = true}},
		flags = {PW},
		out = {{name = "revoked", kind = .String}, {name = "rotated", kind = .Int, help = "items re-encrypted under a new key"}},
		examples = {"vault revoke 5a00... --yes"},
		run = cmd_revoke,
	},
	{
		verb = "import",
		summary = "import from Bitwarden (JSON, CSV), 1Password (1PUX), KeePass (KDBX 4), Chrome or Firefox (CSV)",
		effect = .Mutate,
		args = {{name = "file", kind = .Path, required = true}},
		flags = {PW, LOCAL, VAULTF, OFFLINE,
			{name = "format", kind = .Enum, values = {"auto", "bitwarden-json", "bitwarden-csv", "1pux", "kdbx", "chrome", "firefox", "pvz"}, def = "auto"},
			{name = "source-password-file", kind = .Path, help = "the KeePass database's (or .pvz file's) own password"},
			{name = "vault", kind = .String, help = "which vault to import into"},
		},
		out = {{name = "format", kind = .String}, {name = "imported", kind = .Int}, {name = "skipped", kind = .Int}, {name = "warnings", kind = .Array, of = {{kind = .String}}}},
		examples = {"vault import bitwarden.json --dry-run --json", "vault import export.1pux"},
		run = cmd_import,
	},
	{
		verb = "export",
		summary = "export: an encrypted .pvz file, or an unencrypted Bitwarden JSON (needs --yes)",
		effect = .Destructive,
		flags = {PW, LOCAL, VAULTF, OFFLINE,
			{name = "format", kind = .Enum, values = {"pvz", "bitwarden-json"}, def = "pvz"},
			{name = "out", kind = .Path, required = true},
			{name = "export-password-file", kind = .Path, help = "the password the .pvz export is sealed with"},
		},
		out = {{name = "exported", kind = .Int}, {name = "path", kind = .String}, {name = "encrypted", kind = .Bool}},
		examples = {"vault export --out backup.pvz --export-password-file pw --yes"},
		run = cmd_export,
	},
	{
		verb = "health",
		summary = "reused, weak and exposed passwords; --breach also asks Have I Been Pwned (k-anonymity, off by default)",
		effect = .Read,
		flags = {PW, LOCAL, VAULTF, OFFLINE,
			{name = "breach", kind = .Bool, help = "send the first 5 hex digits of each password's SHA-1 to api.pwnedpasswords.com"},
		},
		out = {
			{name = "items", kind = .Int}, {name = "weak", kind = .Int}, {name = "reused", kind = .Int},
			{name = "exposed", kind = .Int}, {name = "breached", kind = .Int, opt = true},
			{name = "findings", kind = .Array, of = {{name = "title", kind = .String}, {name = "issue", kind = .String}, {name = "detail", kind = .String}}},
		},
		examples = {"vault health --json", "vault health --breach --yes"},
		run = cmd_health,
	},
	{
		verb = "passwd",
		summary = "change the master password (re-wraps the account key on every identity, or re-keys the local file)",
		effect = .Mutate,
		flags = {PW, LOCAL, VAULTF, {name = "new-password-file", kind = .Path, required = true}},
		out = {{name = "changed", kind = .Bool}},
		examples = {"vault passwd --password-file old --new-password-file new"},
		run = cmd_passwd,
	},
	{
		verb = "autofill",
		summary = "serve the autofill socket for the browser without a window (asks nothing: --allow decides)",
		effect = .Read,
		flags = {PW, OFFLINE,
			{name = "allow", kind = .Enum, values = {"deny", "once"}, def = "deny", help = "how to answer fill requests with no window to ask in"},
			{name = "socket", kind = .Path, help = "where to listen (default $XDG_RUNTIME_DIR/palm-vault/autofill.sock)"},
			{name = "max-requests", kind = .Int, def = "0", help = "exit after this many (0: run until killed)"},
		},
		out = {{name = "served", kind = .Int}},
		hidden = false,
		examples = {"vault autofill --password-file pw --allow deny"},
		run = cmd_autofill,
	},
	{
		verb = "autofill-client",
		summary = "the reference client of the autofill protocol: what the browser does, from a terminal",
		effect = .Read,
		args = {{name = "origin", kind = .String, required = true}},
		flags = {
			{name = "socket", kind = .Path},
			{name = "identity-of-tab", kind = .String, required = true, help = "the identity the browser tab belongs to"},
			{name = "pair-file", kind = .Path, help = "where the pairing secret is kept (created on first use)"},
			{name = "fill", kind = .String, help = "ask to fill this candidate id"},
		},
		out = {{name = "state", kind = .String}, {name = "candidates", kind = .Array, of = {
			{name = "id", kind = .String}, {name = "title", kind = .String}, {name = "username", kind = .String}, {name = "match", kind = .String},
		}}, {name = "filled", kind = .Bool, opt = true}},
		examples = {"vault autofill-client https://github.com --identity-of-tab alice"},
		run = cmd_autofill_client,
	},
}

@(private = "file")
SURFACE_NOTES :: `The master password is never an argument: use --password-file, or
PALM_VAULT_PASSWORD in a scripted demo. A secret is printed only by
get --reveal, get --field, and totp. A delegated assistant session
(PALM_CLOUD_SESSION) is refused by every verb.`

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "vault",
			summary  = "a password manager: a local encrypted file, or end-to-end encrypted identity vaults synced through the Palmframe cloud",
			gui      = true,
			selftest = selftest,
			notes    = SURFACE_NOTES,
			commands = COMMANDS,
		}
	}
	return &g_surface
}

// ---------------------------------------------------------------------------
// Shared plumbing
// ---------------------------------------------------------------------------

// refuse_assistant is the CLI's half of "the assistant never reads the
// vault". A delegated session is how an assistant is handed an identity
// (cloud/docs/accounts.md); the vault does not open under one.
refuse_assistant :: proc(c: ^kit.Call) -> bool {
	if os.get_env("PALM_CLOUD_SESSION", context.temp_allocator) != "" {
		kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "the vault is not available to a delegated (assistant) session")
		kit.cli_err_field(c, "session", "delegated")
		return true
	}
	return false
}

read_secret_file :: proc(path: string) -> (s: string, ok: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	t := string(data)
	t = strings.trim_right(t, "\r\n")
	return t, true
}

master_password :: proc(c: ^kit.Call, flag := "password-file") -> (pw: string, code: int) {
	if f := kit.cli_str(c, flag); f != "" {
		s, ok := read_secret_file(f)
		if !ok {
			return "", kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", f)
		}
		return s, kit.EXIT_OK
	}
	if flag == "password-file" {
		if s := os.get_env("PALM_VAULT_PASSWORD", context.temp_allocator); s != "" {
			return s, kit.EXIT_OK
		}
	}
	return "", kit.cli_failf(c, kit.EXIT_USAGE, "give --%s (the master password is never an argument)", flag)
}

// open_book opens and unlocks the vault this command is about.
open_book :: proc(c: ^kit.Call, b: ^Book, need_unlock := true, sync_first := true) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	force_local := kit.cli_bool(c, "local") || kit.cli_str(c, "vault-file") != ""
	b.path = kit.cli_str(c, "vault-file")
	if b.path == "" {
		b.path = default_vault_path(context.allocator)
	}
	if !force_local {
		b.acct = acct_open()
	}
	b.mode = book_mode_for(force_local, b.acct)
	b.scope = c.identity
	if b.mode == .Local && !os.exists(b.path) {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no vault at %s and this device is not enrolled in an account vault", short_path(b.path))
	}
	if b.mode == .Account && c.identity != "" && ident_by_handle(b.acct, c.identity) == nil {
		return kit.cli_failf(c, kit.EXIT_OUT_OF_SCOPE, "this device holds no vault for %q", c.identity)
	}
	if !need_unlock {
		return kit.EXIT_OK
	}
	pw, code := master_password(c)
	if code != kit.EXIT_OK {
		return code
	}
	if b.mode == .Account && sync_first && !kit.cli_bool(c, "offline") {
		// Pull before unlocking so a key rotated elsewhere is already here.
		rep: Sync_Report
		if err := acct_connect(b.acct); err == "" {
			if perr := acct_pull(b.acct, &rep); perr != "" {
				kit.cli_note(c, "vault: working offline (%s)", perr)
			} else {
				reload_cache(b.acct)
			}
		} else {
			kit.cli_note(c, "vault: working offline (%s)", err)
		}
	}
	if err := book_unlock(b, pw); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	if b.mode == .Account && sync_first && !kit.cli_bool(c, "offline") && b.acct.client != nil {
		// Push anything left over from an earlier offline run.
		if _, err := book_sync(b); err != "" {
			kit.cli_note(c, "vault: sync incomplete (%s)", err)
		}
	}
	for p in b.acct != nil ? b.acct.problems[:] : nil {
		kit.cli_note(c, "vault: %s", p)
	}
	return kit.EXIT_OK
}

close_book :: proc(b: ^Book) {
	book_lock(b)
	if b.acct != nil {
		acct_close(b.acct)
	}
}

KIND_NAME := [Item_Kind]string {
	.Login    = "login",
	.Passkey  = "passkey",
	.Card     = "card",
	.Note     = "note",
	.Document = "document",
	.Totp     = "totp",
}

item_json :: proc(b: ^Book, e: ^Entry) -> ^kit.Json {
	o := kit.jobj()
	kit.jset_str(o, "id", e.id)
	kit.jset_str(o, "kind", KIND_NAME[e.kind])
	kit.jset_str(o, "title", e.title)
	kit.jset_str(o, "username", e.username)
	kit.jset_str(o, "url", e.url)
	ident, vault := book_label(b, e)
	kit.jset_str(o, "identity", ident)
	kit.jset_str(o, "vault", vault)
	kit.jset_bool(o, "has_totp", e.totp != "")
	tags := kit.jarr()
	for t in e.tags {
		kit.jpush(tags, kit.jstr(t))
	}
	kit.jset(o, "tags", tags)
	return o
}

// find_item resolves an item argument: an exact id (or a unique id prefix of
// at least 6), then an exact title (any case), then a unique substring of the
// title, URL or username.
find_item :: proc(c: ^kit.Call, b: ^Book, q: string) -> (idx: int, code: int) {
	needle := strings.to_lower(strings.trim_space(q), context.temp_allocator)
	if needle == "" {
		return -1, kit.cli_fail(c, kit.EXIT_USAGE, "which item?")
	}
	for &e, i in b.v.entries {
		if e.id == q || (len(q) >= 6 && strings.has_prefix(e.id, q)) {
			return i, kit.EXIT_OK
		}
	}
	for &e, i in b.v.entries {
		if strings.to_lower(e.title, context.temp_allocator) == needle {
			return i, kit.EXIT_OK
		}
	}
	hits := make([dynamic]int, context.temp_allocator)
	for &e, i in b.v.entries {
		if entry_matches(&e, needle) {
			append(&hits, i)
		}
	}
	if len(hits) == 1 {
		return hits[0], kit.EXIT_OK
	}
	if len(hits) == 0 {
		return -1, kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no item matches %q", q)
	}
	names := make([dynamic]string, context.temp_allocator)
	for h in hits[:min(len(hits), 8)] {
		append(&names, fmt.tprintf("%s (%s)", b.v.entries[h].title, b.v.entries[h].id[:8]))
	}
	return -1, kit.cli_failf(c, kit.EXIT_USAGE, "%q matches %d items: %s", q, len(hits), strings.join(names[:], ", ", context.temp_allocator))
}

MASKED :: "•••••••• (hidden; --reveal shows it)"

// ---------------------------------------------------------------------------
// Verbs
// ---------------------------------------------------------------------------

cmd_where :: proc(c: ^kit.Call) -> int {
	dir, why := data_dir_explained()
	kit.jset_str(c.out, "data_dir", dir)
	kit.jset_str(c.out, "source", why)
	kit.jset_str(c.out, "account_dir", account_dir())
	return kit.EXIT_OK
}

cmd_status :: proc(c: ^kit.Call) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	b: Book
	defer close_book(&b)
	force_local := kit.cli_bool(c, "local") || kit.cli_str(c, "vault-file") != ""
	b.path = kit.cli_str(c, "vault-file")
	if b.path == "" {
		b.path = default_vault_path(context.allocator)
	}
	if !force_local {
		b.acct = acct_open()
	}
	b.mode = book_mode_for(force_local, b.acct)
	kit.jset_str(c.out, "mode", b.mode == .Local ? "local" : "account")
	kit.jset_str(c.out, "path", b.mode == .Local ? b.path : b.acct.dir)
	kit.jset_bool(c.out, "exists", book_exists(&b))
	kit.jset_bool(c.out, "enrolled", b.acct != nil && b.acct.has_secret)
	pending := 0
	synced: i64 = 0
	if b.acct != nil && b.acct.have_cache {
		kit.jset_str(c.out, "email", b.acct.cache.email)
		ids := kit.jarr()
		for i in b.acct.cache.idents {
			if c.identity == "" || c.identity == i.handle {
				kit.jpush(ids, kit.jstr(i.handle))
			}
		}
		kit.jset(c.out, "identities", ids)
		pending = len(b.acct.cache.pending)
		synced = b.acct.cache.synced_at
	}
	kit.jset_int(c.out, "pending", pending)
	kit.jset_int(c.out, "synced_at", int(synced))
	return kit.EXIT_OK
}

cmd_setup :: proc(c: ^kit.Call) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	pw, code := master_password(c)
	if code != kit.EXIT_OK {
		return code
	}
	a := acct_open()
	defer acct_close(a)
	if a.has_secret && acct_set_up(a) {
		return kit.cli_fail(c, kit.EXIT_FAILED, "this device is already enrolled in an account vault")
	}
	if c.dry_run {
		kit.jset_str(c.out, "secret_key", "")
		kit.jset(c.out, "identities", kit.jarr())
		return kit.EXIT_OK
	}
	secret, err := acct_setup(a, pw)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_str(c.out, "secret_key", secret)
	ids := kit.jarr()
	for i in a.cache.idents {
		kit.jpush(ids, kit.jstr(i.handle))
	}
	kit.jset(c.out, "identities", ids)
	kit.cli_note(c, "vault: write the Secret Key down with your master password (an emergency kit). Both are needed on a new device unless an enrolled device approves it; neither can be recovered by anyone.")
	return kit.EXIT_OK
}

cmd_enroll :: proc(c: ^kit.Call) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	a := acct_open()
	defer acct_close(a)
	switch {
	case kit.cli_str(c, "secret-key-file") != "":
		s, ok := read_secret_file(kit.cli_str(c, "secret-key-file"))
		if !ok {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "cannot read the Secret Key file")
		}
		if err := acct_enroll_with_secret(a, s); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		kit.jset_bool(c.out, "enrolled", true)
	case kit.cli_bool(c, "request"):
		handle := c.identity
		if handle == "" {
			return kit.cli_fail(c, kit.EXIT_USAGE, "say which identity this device is for: --identity <handle>")
		}
		did, code, err := acct_device_request(a, handle, kit.cli_str(c, "name"))
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		kit.jset_bool(c.out, "enrolled", false)
		kit.jset_str(c.out, "device_id", did)
		kit.jset_str(c.out, "code", code)
		kit.cli_note(c, "vault: on an enrolled device run `vault approve %s --code \"%s\"` after checking this code matches", did, code)
	case kit.cli_bool(c, "wait"):
		ok, err := acct_device_poll(a)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		kit.jset_bool(c.out, "enrolled", ok)
	case:
		return kit.cli_fail(c, kit.EXIT_USAGE, "give --secret-key-file, --request or --wait")
	}
	return kit.EXIT_OK
}

cmd_devices :: proc(c: ^kit.Call) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	a := acct_open()
	defer acct_close(a)
	if err := acct_connect(a); err == "" {
		rep: Sync_Report
		if perr := acct_pull(a, &rep); perr == "" {
			reload_cache(a)
		}
	}
	arr := kit.jarr()
	for d in a.cache.devices {
		h := handle_of(a, d.identity_id)
		if c.identity != "" && h != c.identity {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "id", d.id)
		kit.jset_str(o, "identity", h)
		kit.jset_str(o, "name", d.name)
		kit.jset_bool(o, "approved", d.sealed_secret != "")
		kit.jset_bool(o, "revoked", d.revoked)
		pub, _ := unb64(d.pub, context.temp_allocator)
		kit.jset_str(o, "code", len(pub) == 32 ? device_code(pub) : "")
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "devices", arr)
	return kit.EXIT_OK
}

cmd_approve :: proc(c: ^kit.Call) -> int {
	if refuse_assistant(c) {
		return kit.EXIT_OUT_OF_SCOPE
	}
	a := acct_open()
	defer acct_close(a)
	if c.dry_run {
		kit.jset_bool(c.out, "approved", false)
		return kit.EXIT_OK
	}
	if err := acct_device_approve(a, kit.cli_str(c, "device"), kit.cli_str(c, "code")); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_bool(c.out, "approved", true)
	return kit.EXIT_OK
}

cmd_sync :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b, sync_first = false); code != kit.EXIT_OK {
		return code
	}
	if b.mode != .Account {
		return kit.cli_fail(c, kit.EXIT_USAGE, "this device is not enrolled in an account vault; the local file does not sync")
	}
	rep, err := book_sync(&b)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
	}
	kit.jset_int(c.out, "pulled", rep.pulled)
	kit.jset_int(c.out, "pushed", rep.pushed)
	kit.jset_int(c.out, "merged", rep.merged)
	kit.jset_int(c.out, "conflicted", rep.conflicted)
	kit.jset_int(c.out, "dropped", rep.dropped)
	kit.jset_int(c.out, "removed", rep.removed)
	kit.jset_int(c.out, "items", len(b.v.entries))
	return kit.EXIT_OK
}

cmd_list :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	needle := strings.to_lower(kit.cli_str(c, "search"), context.temp_allocator)
	arr := kit.jarr()
	n := 0
	for &e in b.v.entries {
		if !entry_matches(&e, needle) {
			continue
		}
		kit.jpush(arr, item_json(&b, &e))
		n += 1
	}
	kit.jset(c.out, "items", arr)
	kit.jset_int(c.out, "count", n)
	return kit.EXIT_OK
}

cmd_get :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	idx, code := find_item(c, &b, kit.cli_str(c, "item"))
	if code != kit.EXIT_OK {
		return code
	}
	e := &b.v.entries[idx]
	if f := kit.cli_str(c, "field"); f != "" {
		// Exactly one value, raw, on stdout: `vault get x --field password |
		// some-tool`. Asking for it by name is the explicit request.
		v := ""
		switch f {
		case "password":
			v = e.password
		case "username":
			v = e.username
		case "url":
			v = e.url
		case "totp":
			v = e.totp
		case "notes":
			v = e.notes
		case "title":
			v = e.title
		}
		fmt.println(v)
		return kit.EXIT_OK
	}
	reveal := kit.cli_bool(c, "reveal")
	kit.jset(c.out, "item", item_json(&b, e))
	mask :: proc(s: string, reveal: bool) -> string {
		if s == "" || reveal {
			return s
		}
		return MASKED
	}
	kit.jset_str(c.out, "password", mask(e.password, reveal))
	kit.jset_str(c.out, "notes", mask(e.notes, reveal))
	fields := kit.jarr()
	for f in e.fields {
		o := kit.jobj()
		kit.jset_str(o, "label", f.label)
		kit.jset_str(o, "value", f.secret ? mask(f.value, reveal) : f.value)
		kit.jset_bool(o, "secret", f.secret)
		kit.jpush(fields, o)
	}
	if e.passkey.credential_id != "" {
		o := kit.jobj()
		kit.jset_str(o, "label", "passkey")
		kit.jset_str(o, "value", fmt.tprintf("%s for %s", e.passkey.user_name, e.passkey.rp_id))
		kit.jset_bool(o, "secret", false)
		kit.jpush(fields, o)
	}
	kit.jset(c.out, "fields", fields)
	kit.jset_bool(c.out, "revealed", reveal)
	return kit.EXIT_OK
}

cmd_totp :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	idx, code := find_item(c, &b, kit.cli_str(c, "item"))
	if code != kit.EXIT_OK {
		return code
	}
	e := &b.v.entries[idx]
	now := now_unix()
	cv, ok := totp_code(e.totp, now, e.totp_period, int(e.totp_digits), e.totp_algo)
	if !ok {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "%s has no TOTP secret", e.title)
	}
	kit.jset_str(c.out, "code", cv)
	kit.jset_int(c.out, "remaining", totp_remaining(now, e.totp_period))
	kit.jset_str(c.out, "title", e.title)
	return kit.EXIT_OK
}

cmd_add :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	target := book_find_target(&b, kit.cli_str(c, "vault"))
	if b.mode == .Account && target < 0 {
		return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no writable vault called %q in scope", kit.cli_str(c, "vault"))
	}
	e := entry_new(kit.cli_str(c, "title"))
	replace_string(&e.username, kit.cli_str(c, "username"))
	replace_string(&e.url, kit.cli_str(c, "url"))
	entry_set_tags(&e, kit.cli_str(c, "tags"))
	if f := kit.cli_str(c, "secret-file"); f != "" {
		s, ok := read_secret_file(f)
		if !ok {
			entry_free(&e)
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", f)
		}
		entry_set_password(&e, s)
	} else {
		opts := GEN_DEFAULT
		opts.length = clamp(kit.cli_int(c, "length", 24), GEN_MIN_LEN, GEN_MAX_LEN)
		pw, _ := gen_password(opts, context.temp_allocator)
		entry_set_password(&e, pw)
	}
	if c.dry_run {
		kit.jset(c.out, "item", item_json(&b, &e))
		entry_free(&e)
		return kit.EXIT_OK
	}
	idx, err := book_add(&b, e, target)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	if b.mode == .Account && !kit.cli_bool(c, "offline") {
		if _, serr := book_sync(&b); serr != "" {
			kit.cli_note(c, "vault: saved on this device; not yet synced (%s)", serr)
		}
		for &x, i in b.v.entries {
			if x.title == kit.cli_str(c, "title") {
				idx = i
			}
		}
	}
	kit.jset(c.out, "item", item_json(&b, &b.v.entries[idx]))
	return kit.EXIT_OK
}

cmd_rm :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	idx, code := find_item(c, &b, kit.cli_str(c, "item"))
	if code != kit.EXIT_OK {
		return code
	}
	if !book_writable(&b, &b.v.entries[idx]) {
		return kit.cli_fail(c, kit.EXIT_OUT_OF_SCOPE, "that item is shared with you read-only")
	}
	title := strings.clone(b.v.entries[idx].title, context.temp_allocator)
	if c.dry_run {
		kit.jset_str(c.out, "removed", title)
		return kit.EXIT_OK
	}
	if err := book_remove(&b, idx); err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	if b.mode == .Account && !kit.cli_bool(c, "offline") {
		book_sync(&b)
	}
	kit.jset_str(c.out, "removed", title)
	return kit.EXIT_OK
}

cmd_share :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	if b.mode != .Account {
		return kit.cli_fail(c, kit.EXIT_USAGE, "sharing needs the account vault; the local file is yours alone")
	}
	with := kit.cli_str(c, "with")
	if vname := kit.cli_str(c, "vault"); vname != "" {
		s := book_find_target(&b, vname)
		if s < 0 || b.acct.sources[s].kind != .Own {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "no vault of yours called %q in scope", vname)
		}
		if c.dry_run {
			kit.jset_str(c.out, "shared", b.acct.sources[s].name)
			kit.jset_str(c.out, "with", with)
			kit.jset_str(c.out, "fingerprint", "")
			return kit.EXIT_OK
		}
		if err := acct_share_vault(b.acct, b.acct.sources[s].vault_id, with, kit.cli_str(c, "role")); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		kit.jset_str(c.out, "shared", b.acct.sources[s].name)
	} else {
		idx, code := find_item(c, &b, kit.cli_str(c, "item"))
		if code != kit.EXIT_OK {
			return code
		}
		e := &b.v.entries[idx]
		if c.dry_run {
			kit.jset_str(c.out, "shared", e.title)
			kit.jset_str(c.out, "with", with)
			kit.jset_str(c.out, "fingerprint", "")
			return kit.EXIT_OK
		}
		title := strings.clone(e.title, context.temp_allocator)
		if err := acct_share_item(b.acct, e.id, with); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		kit.jset_str(c.out, "shared", title)
	}
	kit.jset_str(c.out, "with", with)
	fp := ""
	if who, pk, err := lookup_identity(b.acct, with); err == "" {
		_ = who
		fp = fingerprint(&pk)
	}
	kit.jset_str(c.out, "fingerprint", fp)
	if fp != "" && ident_by_handle(b.acct, with) == nil {
		kit.cli_note(c, "vault: %s is another account; read them this safety number to check the key: %s", with, fp)
	}
	return kit.EXIT_OK
}

cmd_shares :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	if b.mode != .Account {
		return kit.cli_fail(c, kit.EXIT_USAGE, "the local vault has no shares")
	}
	a := b.acct
	arr := kit.jarr()
	for &s in a.cache.shares {
		from, to := handle_of(a, s.identity_id), handle_of(a, s.grantee)
		if c.identity != "" && from != c.identity && to != c.identity {
			continue
		}
		o := kit.jobj()
		kit.jset_str(o, "id", s.id)
		kit.jset_str(o, "from", from)
		kit.jset_str(o, "to", to)
		what := "vault"
		if s.item_id != "" {
			what = "item"
			for &e in b.v.entries {
				if e.id == s.item_id {
					what = fmt.tprintf("item: %s", e.title)
				}
			}
		} else {
			n, _ := vault_label(a, s.vault_id)
			what = fmt.tprintf("vault: %s", n)
		}
		kit.jset_str(o, "what", what)
		kit.jset_str(o, "role", s.role)
		kit.jset_bool(o, "revoked", s.revoked)
		kit.jset_bool(o, "verified", share_verify(a, &s))
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "shares", arr)
	return kit.EXIT_OK
}

cmd_revoke :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	if b.mode != .Account {
		return kit.cli_fail(c, kit.EXIT_USAGE, "the local vault has no shares")
	}
	id := kit.cli_str(c, "share")
	for &s in b.acct.cache.shares {
		if strings.has_prefix(s.id, id) && len(id) >= 6 {
			id = strings.clone(s.id, context.temp_allocator)
		}
	}
	if c.dry_run {
		kit.jset_str(c.out, "revoked", id)
		kit.jset_int(c.out, "rotated", 0)
		return kit.EXIT_OK
	}
	n, err := acct_revoke(b.acct, id)
	if err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, err)
	}
	kit.jset_str(c.out, "revoked", id)
	kit.jset_int(c.out, "rotated", n)
	kit.cli_note(c, "vault: revoked and rotated. What the grantee already read, it may have kept: change those passwords at the sites (vault health lists them as exposed).")
	return kit.EXIT_OK
}

cmd_import :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	target := book_find_target(&b, kit.cli_str(c, "vault"))
	if b.mode == .Account && target < 0 {
		return kit.cli_fail(c, kit.EXIT_NOT_FOUND, "no writable vault in scope to import into")
	}
	src_pw := ""
	if f := kit.cli_str(c, "source-password-file"); f != "" {
		s, ok := read_secret_file(f)
		if !ok {
			return kit.cli_failf(c, kit.EXIT_NOT_FOUND, "cannot read %s", f)
		}
		src_pw = s
	}
	res := import_path(kit.cli_str(c, "file"), kit.cli_str(c, "format"), src_pw)
	defer import_result_free(&res)
	if res.err != "" {
		return kit.cli_fail(c, kit.EXIT_FAILED, res.err)
	}
	kit.jset_str(c.out, "format", res.format)
	warnings := kit.jarr()
	for w in res.warnings {
		kit.jpush(warnings, kit.jstr(w))
	}
	if c.dry_run {
		kit.jset_int(c.out, "imported", len(res.entries))
		kit.jset_int(c.out, "skipped", res.skipped)
		kit.jset(c.out, "warnings", warnings)
		return kit.EXIT_OK
	}
	n := 0
	for len(res.entries) > 0 {
		e := pop_front(&res.entries)
		if _, err := book_add(&b, e, target); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		n += 1
	}
	if b.mode == .Account && !kit.cli_bool(c, "offline") {
		if _, serr := book_sync(&b); serr != "" {
			kit.cli_note(c, "vault: imported on this device; not yet synced (%s)", serr)
		}
	}
	kit.jset_int(c.out, "imported", n)
	kit.jset_int(c.out, "skipped", res.skipped)
	kit.jset(c.out, "warnings", warnings)
	return kit.EXIT_OK
}

cmd_export :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	out := kit.cli_str(c, "out")
	format := kit.cli_str(c, "format")
	kit.jset_int(c.out, "exported", len(b.v.entries))
	kit.jset_str(c.out, "path", out)
	kit.jset_bool(c.out, "encrypted", format == "pvz")
	if c.dry_run {
		return kit.EXIT_OK
	}
	switch format {
	case "bitwarden-json":
		kit.cli_note(c, "vault: this file holds every password in the clear. Delete it once it has been imported elsewhere.")
		text := export_bitwarden_json(&b.v)
		err := write_atomic(out, transmute([]byte)text)
		wipe_string(text)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	case:
		pw, code := master_password(c, "export-password-file")
		if code != kit.EXIT_OK {
			return code
		}
		if err := export_pvz(&b.v, out, pw); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	}
	return kit.EXIT_OK
}

cmd_health :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	breach := kit.cli_bool(c, "breach")
	if breach && !c.yes {
		return kit.cli_fail(c, kit.EXIT_NEEDS_YES, "--breach makes network requests to api.pwnedpasswords.com (5 hex digits of each password's SHA-1); add --yes to allow it")
	}
	h := health_check(&b.v)
	defer health_free(&h)
	if breach {
		if err := health_breach(&h, &b.v, hibp_fetch_curl); err != "" {
			return kit.cli_fail(c, kit.EXIT_UNAVAILABLE, err)
		}
		kit.jset_int(c.out, "breached", h.breached)
	}
	kit.jset_int(c.out, "items", len(b.v.entries))
	kit.jset_int(c.out, "weak", h.weak)
	kit.jset_int(c.out, "reused", h.reused)
	kit.jset_int(c.out, "exposed", h.exposed)
	arr := kit.jarr()
	for f in h.findings {
		o := kit.jobj()
		kit.jset_str(o, "title", b.v.entries[f.entry].title)
		kit.jset_str(o, "issue", HEALTH_ISSUE[f.issue])
		kit.jset_str(o, "detail", f.detail)
		kit.jpush(arr, o)
	}
	kit.jset(c.out, "findings", arr)
	return kit.EXIT_OK
}

cmd_passwd :: proc(c: ^kit.Call) -> int {
	b: Book
	defer close_book(&b)
	if code := open_book(c, &b); code != kit.EXIT_OK {
		return code
	}
	np, code := master_password(c, "new-password-file")
	if code != kit.EXIT_OK {
		return code
	}
	if c.dry_run {
		kit.jset_bool(c.out, "changed", false)
		return kit.EXIT_OK
	}
	switch b.mode {
	case .Local:
		fresh, err := store_rekey(b.path, &b.v, &b.sess, np)
		if err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
		session_zero(&b.sess)
		b.sess = fresh
	case .Account:
		if err := acct_change_password(b.acct, np); err != "" {
			return kit.cli_fail(c, kit.EXIT_FAILED, err)
		}
	}
	kit.jset_bool(c.out, "changed", true)
	return kit.EXIT_OK
}

// whoami_is_assistant asks the server whether the session in use is an
// assistant's; used by the self-test against a live stack.
whoami_is_assistant :: proc(cl: ^ck.Client) -> bool {
	v, e := ck.whoami(cl, context.temp_allocator)
	if !ck.ok(e) {
		return false
	}
	return ck.get_str(v, "device", "kind") == "assistant"
}
