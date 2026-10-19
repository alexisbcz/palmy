package main

// What the welcome flow is about: the steps, the person's choices, and the
// files those choices end up in.
//
// Files this app writes, all in the person's own home:
//
//	$XDG_STATE_HOME/palm/welcome/done   the marker: JSON, written when the
//	                                    flow is finished or dismissed
//	$XDG_CONFIG_HOME/palm/sync.conf     per identity, what this computer keeps
//	                                    in sync (the session.d hooks read it)
//	$XDG_CONFIG_HOME/palmy/wm.conf     theme = dark | light (the line the wm, Settings and kit read)
//	$XDG_CONFIG_HOME/locale.conf        LANG=..., only when the language is
//	                                    changed here (locale.conf(5) per user)
//
// Everything that talks to the cloud is apps/cloudkit, and every service is
// set up by that service's own command line (palm-drive, vault, mailcore,
// calendar, contacts, notes, chat) rather than imitated here. core.odin
// holds those calls; this file holds no I/O beyond the files above.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ck "../cloudkit"

Step :: enum u8 {
	Welcome, // language and appearance
	Account, // with an account, or only on this computer
	Sign_In, // create the account, or sign in
	Identities, // the first identities: handles, kinds, colours
	Sync, // per identity, what this computer keeps in sync
	Passwords, // the vault: master password, Secret Key, emergency kit
	Setup, // set up each chosen service, and say how it went
	Import, // from Google or Microsoft: coming
	Tour, // the start menu, the identity switcher, the keys
	Done,
}

// The steps that only exist with an account.
CLOUD_STEPS :: bit_set[Step]{.Sign_In, .Identities, .Sync, .Passwords, .Setup}

Mode :: enum u8 {
	Undecided,
	Account,
	Local,
}

Auth_Tab :: enum u8 {
	Create,
	Sign_In,
}

Service :: enum u8 {
	Mail,
	Drive,
	Calendar, // calendar and contacts: one CalDAV/CardDAV home
	Notes,
	Passwords,
	Chat,
}
Services :: bit_set[Service]

SERVICE_KEYS := [Service]string {
	.Mail      = "mail",
	.Drive     = "drive",
	.Calendar  = "calendar",
	.Notes     = "notes",
	.Passwords = "passwords",
	.Chat      = "chat",
}

KINDS := [?]string{"personal", "work", "public", "project"}

// The identity palette from cloud/docs/shell.md: eight hues, each with a
// light-theme and a dark-theme value checked for text contrast. Red is kept
// for "overdue" and "destructive", so no identity can be red.
Hue :: struct {
	name:  string,
	light: u32,
	dark:  u32,
}

PALETTE := [?]Hue {
	{"teal", 0x0f9488, 0x2dd4bf},
	{"blue", 0x2563eb, 0x60a5fa},
	{"amber", 0xc2620a, 0xfbbf24},
	{"violet", 0x7c3aed, 0xa78bfa},
	{"rose", 0xe11d48, 0xfb7185},
	{"emerald", 0x059669, 0x34d399},
	{"indigo", 0x4f46e5, 0x818cf8},
	{"slate", 0x475569, 0x94a3b8},
}

palette_index :: proc(name: string) -> int {
	for h, i in PALETTE {
		if h.name == name {
			return i
		}
	}
	// A colour from outside the palette (accounts allows every Tailwind
	// name): the nearest of ours by family, else slate.
	switch name {
	case "sky", "cyan":
		return 1
	case "orange", "yellow":
		return 2
	case "purple", "fuchsia":
		return 3
	case "pink", "red":
		return 4
	case "green", "lime":
		return 5
	}
	return 7
}

// Defaults by kind: what a person of that kind most often wants, shown as
// choices on the Sync page. Nothing is set up until the Setup page's button.
kind_default_services :: proc(kind: string) -> Services {
	switch kind {
	case "personal":
		return {.Mail, .Drive, .Calendar, .Notes}
	case "work":
		return {.Mail, .Drive, .Calendar, .Chat}
	case "public":
		return {.Mail}
	case "project":
		return {.Drive, .Notes, .Chat}
	}
	return {}
}

kind_default_color :: proc(kind: string, taken: []int) -> int {
	want := 0
	switch kind {
	case "personal":
		want = 0
	case "work":
		want = 1
	case "public":
		want = 2
	case "project":
		want = 3
	}
	// No two identities share a hue (shell.md): take the next free one.
	for n in 0 ..< len(PALETTE) {
		c := (want + n) % len(PALETTE)
		free := true
		for t in taken {
			if t == c {
				free = false
			}
		}
		if free {
			return c
		}
	}
	return want
}

// Plan is one identity as the flow sees it: one already on the account, or
// one this run will create.
Plan :: struct {
	existing:       bool,
	id:             string,
	name:           [dynamic]u8,
	handle:         [dynamic]u8,
	handle_touched: bool,
	kind:           int,
	color:          int,
	services:       Services,
	err:            string, // the server's refusal for this one row
}

plan_handle :: proc(pl: ^Plan) -> string {
	return string(pl.handle[:])
}

plan_name :: proc(pl: ^Plan) -> string {
	return strings.trim_space(string(pl.name[:]))
}

Task_State :: enum u8 {
	Waiting,
	Running,
	Done,
	Pending_Server, // set up; the server did not answer, and will be tried again
	Not_Installed, // the program is not on this computer
	Coming, // the service cannot sync yet
	Failed,
	Skipped,
}

Task_What :: enum u8 {
	Session, // this computer's session scoped to the identity
	Mailbox, // the identity's mailboxes on the server
	Mail_Client, // mail on this computer, for the account
	Drive,
	Calendar,
	Contacts,
	Notes,
	Chat,
	Vault,
	Sync_Conf, // the choices, written to sync.conf
}

Task :: struct {
	handle: string, // "" for an account-wide task
	what:   Task_What,
	state:  Task_State,
	detail: string,
}

Language :: struct {
	code:    string, // what goes in LANG, without .UTF-8
	native:  string,
	english: string,
}

LANGUAGES := [?]Language {
	{"en_US", "English", "English"},
	{"fr_FR", "Français", "French"},
	{"de_DE", "Deutsch", "German"},
	{"es_ES", "Español", "Spanish"},
	{"ar", "العربية", "Arabic"},
	{"ja_JP", "日本語", "Japanese"},
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

home_dir :: proc() -> string {
	h := os.get_env("HOME", context.temp_allocator)
	return h != "" ? h : "/tmp"
}

xdg :: proc(var, fallback: string) -> string {
	if v := os.get_env(var, context.temp_allocator); v != "" {
		return v
	}
	return fmt.tprintf("%s/%s", home_dir(), fallback)
}

marker_path :: proc() -> string {
	return fmt.tprintf("%s/palm/welcome/done", xdg("XDG_STATE_HOME", ".local/state"))
}

sync_conf_path :: proc() -> string {
	return fmt.tprintf("%s/palm/sync.conf", xdg("XDG_CONFIG_HOME", ".config"))
}

// appearance_path is the window manager's per-user config: its `theme`
// line is what the shell, Settings and every app (kit.system_theme_dark)
// read, so the welcome writes the same line rather than a file of its own.
appearance_path :: proc() -> string {
	return fmt.tprintf("%s/palmy/wm.conf", xdg("XDG_CONFIG_HOME", ".config"))
}

locale_conf_path :: proc() -> string {
	return fmt.tprintf("%s/locale.conf", xdg("XDG_CONFIG_HOME", ".config"))
}

kit_dir_default :: proc() -> string {
	return fmt.tprintf("%s/Documents", home_dir())
}

ensure_parent :: proc(path: string) {
	i := strings.last_index_byte(path, '/')
	if i > 0 {
		os.make_directory_all(path[:i], os.perm(0o700))
	}
}

// write_text writes a whole file through a temporary name, so a crash leaves
// the old file or the new one and never half of either.
write_text :: proc(path, text: string, private := false) -> bool {
	ensure_parent(path)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]u8)text) != nil {
		return false
	}
	if private {
		os.chmod(tmp, {.Read_User, .Write_User})
	}
	return os.rename(tmp, path) == nil
}

read_text :: proc(path: string, allocator := context.temp_allocator) -> (string, bool) {
	data, err := os.read_entire_file_from_path(path, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// ---------------------------------------------------------------------------
// The marker
// ---------------------------------------------------------------------------

Marker :: struct {
	done:         bool,
	completed_at: string,
	mode:         string, // account | local | dismissed
}

read_marker :: proc() -> Marker {
	text, ok := read_text(marker_path())
	if !ok {
		return {}
	}
	m := Marker{done = true}
	v, pok := ck.parse(text, context.temp_allocator)
	if pok {
		m.completed_at = strings.clone(ck.get_str(v, "completed_at"), context.temp_allocator)
		m.mode = strings.clone(ck.get_str(v, "mode"), context.temp_allocator)
	}
	return m
}

write_marker :: proc(mode: string) -> bool {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	stamp := fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
	return write_text(marker_path(), fmt.tprintf("{{\"completed_at\":%s,\"mode\":%s}}\n", ck.quote(stamp), ck.quote(mode)))
}

remove_marker :: proc() -> bool {
	if !os.exists(marker_path()) {
		return false
	}
	return os.remove(marker_path()) == nil
}

// ---------------------------------------------------------------------------
// sync.conf: the choices, per identity
// ---------------------------------------------------------------------------

Sync_Entry :: struct {
	handle:   string,
	services: Services,
}

Sync_Conf :: struct {
	mode:    string, // account | local
	url:     string,
	entries: [dynamic]Sync_Entry,
}

sync_conf_text :: proc(mode, url: string, plans: []Plan) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "# Written by welcome: what this computer keeps in sync, per identity.\n")
	strings.write_string(&b, "# /etc/palm/session.d/60-palm-drive reads it at every login. Change it with\n")
	strings.write_string(&b, "# `welcome run` (or Settings, later); editing it by hand works too.\n")
	fmt.sbprintf(&b, "mode = %s\n", mode)
	if url != "" {
		fmt.sbprintf(&b, "url = %s\n", url)
	}
	for &pl in plans {
		h := plan_handle(&pl)
		if h == "" || (!pl.existing && pl.id == "") {
			continue
		}
		fmt.sbprintf(&b, "\n[identity]\nhandle = %s\n", h)
		for s in Service {
			fmt.sbprintf(&b, "%s = %s\n", SERVICE_KEYS[s], s in pl.services ? "on" : "off")
		}
	}
	return strings.to_string(b)
}

read_sync_conf :: proc(allocator := context.temp_allocator) -> (sc: Sync_Conf, ok: bool) {
	text, found := read_text(sync_conf_path(), allocator)
	if !found {
		return {}, false
	}
	sc.entries = make([dynamic]Sync_Entry, allocator)
	cur := -1
	for raw in strings.split_lines(text, allocator) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		if line == "[identity]" {
			append(&sc.entries, Sync_Entry{})
			cur = len(sc.entries) - 1
			continue
		}
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		k := strings.trim_space(line[:eq])
		v := strings.trim_space(line[eq + 1:])
		if cur < 0 {
			switch k {
			case "mode":
				sc.mode = v
			case "url":
				sc.url = v
			}
			continue
		}
		if k == "handle" {
			sc.entries[cur].handle = v
			continue
		}
		for s in Service {
			if k == SERVICE_KEYS[s] && v == "on" {
				sc.entries[cur].services += {s}
			}
		}
	}
	return sc, true
}

// ---------------------------------------------------------------------------
// Handles
// ---------------------------------------------------------------------------

// The local parts accounts refuses (handle_reserved in the accounts
// migration), checked here too so the page says so before the server does.
RESERVED := [?]string {
	"abuse", "admin", "administrator", "hostmaster", "info", "mailer-daemon",
	"noc", "no-reply", "noreply", "postmaster", "root", "security", "support",
	"webmaster", "www", "palm", "palmy", "system", "help", "billing",
}

// handle_problem is "" for a handle the server will take (unless someone
// else already has it), or the reason it will not, as a msgid.
handle_problem :: proc(h: string) -> string {
	if h == "" {
		return N("Choose a handle.")
	}
	if len(h) < 2 {
		return N("A handle is at least 2 characters.")
	}
	if len(h) > 63 {
		return N("A handle is at most 63 characters.")
	}
	if !ck.handle_ok(h) {
		return N("Use a-z, 0-9, dots, dashes and underscores, starting with a letter or digit.")
	}
	for r in RESERVED {
		if h == r {
			return N("That handle is reserved.")
		}
	}
	return ""
}

// handle_from turns a display name into a suggested handle: lower case,
// spaces to dots, accents dropped, everything else left out.
handle_from :: proc(name: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	last_dot := true
	// The little words that say "of this organisation" make a handle longer
	// and say nothing in it.
	lower := strings.to_lower(name, context.temp_allocator)
	for w in ([?]string{" at ", " chez ", " bei ", " @ "}) {
		lower, _ = strings.replace_all(lower, w, " ", context.temp_allocator)
	}
	for r in lower {
		c := fold_accent(r)
		switch {
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'):
			strings.write_rune(&b, c)
			last_dot = false
		case c == ' ' || c == '.' || c == '-' || c == '_':
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

fold_accent :: proc(r: rune) -> rune {
	switch r {
	case 'à', 'á', 'â', 'ã', 'ä', 'å':
		return 'a'
	case 'ç':
		return 'c'
	case 'è', 'é', 'ê', 'ë':
		return 'e'
	case 'ì', 'í', 'î', 'ï':
		return 'i'
	case 'ñ':
		return 'n'
	case 'ò', 'ó', 'ô', 'õ', 'ö', 'ø':
		return 'o'
	case 'ù', 'ú', 'û', 'ü':
		return 'u'
	case 'ý', 'ÿ':
		return 'y'
	case 'ß':
		return 's'
	}
	return r
}

monogram :: proc(name: string) -> string {
	for r in name {
		if r == ' ' {
			continue
		}
		return strings.to_upper(fmt.tprintf("%c", r), context.temp_allocator)
	}
	return "?"
}

// plan_mono is an identity's letter: the first of its name, unless another
// identity starts with the same one ("Camille Roux", "Camille at
// Northwind"), when the handle's last part says it better (N, for
// camille.northwind). Colour is never the only difference (shell.md).
plan_mono :: proc(st: ^St, pl: ^Plan) -> string {
	mine := monogram(plan_name(pl))
	clash := false
	for &q in st.plans {
		if &q == pl {
			break
		}
		if monogram(plan_name(&q)) == mine {
			clash = true
		}
	}
	if !clash {
		return mine
	}
	h := plan_handle(pl)
	cut := -1
	for c, i in h {
		if c == '.' || c == '-' || c == '_' {
			cut = i
		}
	}
	if cut >= 0 && cut + 1 < len(h) {
		return strings.to_upper(h[cut + 1:cut + 2], context.temp_allocator)
	}
	return mine
}

email_ok :: proc(e: string) -> bool {
	at := strings.index_byte(e, '@')
	if at <= 0 || at != strings.last_index_byte(e, '@') {
		return false
	}
	dom := e[at + 1:]
	return len(dom) >= 3 && strings.contains(dom, ".") && !strings.contains(e, " ")
}
