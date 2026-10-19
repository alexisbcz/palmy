package main

// mailcore — the engine half of a mail client.
//
//	mailcore --selftest [--verbose] [--no-e2e] [--no-tls] [--testserver PATH]
//	mailcore --layout
//	mailcore --parse FILE
//	mailcore --extract FILE [--out DIR] [--section N] [--force]
//	mailcore --thread [--root DIR] [--folder NAME]
//	mailcore fetch  --proto imap|pop3|jmap --port N --user U --password P
//	                [--host 127.0.0.1] [--folder NAME] [--root DIR] [--tls MODE]
//	mailcore send   --port N --user U --password P --to ADDR --subject S --text T
//	                [--host 127.0.0.1] [--attach FILE] [--tls MODE]
//
// SAFETY, enforced by code and not by convention:
//
//   - `conn_dial` refuses every address outside 127.0.0.0/8, and this program
//     performs no DNS resolution of any kind. There is no argument that makes
//     it talk to a real mail provider.
//   - the only Maildir root it will write is $XDG_DATA_HOME/palmy-mail (or
//     ~/.local/share/palmy-mail), and `--root` is resolved under it.
//   - the only credentials that exist here are the ones invented for the test
//     server in apps/mailcore/testserver.
//
// Nothing in this program reads the user's existing mail; there is no code
// path that opens a mailbox it did not create.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

LAYOUT_TEXT :: `mailcore writes a standard Maildir, which is the whole interface
between this engine and any UI or mail tool that reads it.

  $XDG_DATA_HOME/palmy-mail/        (default ~/.local/share/palmy-mail)
    <account>/                      one directory per account
      cur/  new/  tmp/              INBOX lives at the account root
      .Sent/{cur,new,tmp}           Maildir++ subfolders: a leading dot, and
      .Archive/{cur,new,tmp}        the IMAP hierarchy flattened with '.'
      .Lists.odin/{cur,new,tmp}     e.g. IMAP "Lists/odin"
      <each subfolder>/maildirfolder   the Maildir++ marker file

Delivery follows maildir(5): the message is written to tmp/, fsynced, then
renamed into new/ (unread) or straight into cur/ with a flag suffix when the
server already told us the flags. rename(2) is atomic within a filesystem, so
a reader never sees a partial message.

Filenames are  <unixtime>.M<usec>P<pid>Q<seq>.<hostname>  with the flag suffix
":2,<letters>" appended once the flags are known. The letters are in ASCII
order, which is what every other Maildir tool expects:

  D draft    F flagged    P passed    R replied    S seen    T trashed

So ":2,RS" is replied+seen, ":2,FS" is flagged+seen, and a message with no
suffix at all, sitting in new/, is unread.

Per protocol, what can honestly be written:

  IMAP   every folder, with the server's flags translated into the suffix.
  JMAP   every mailbox, with keywords ($seen, $flagged, $answered, $draft,
         $forwarded) translated into the suffix.
  POP3   INBOX only, every message in new/ with no suffix — POP3 has neither
         folders nor flags, and inventing either would be a lie.
`

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 {
		usage()
		os.exit(2)
	}

	switch args[0] {
	case "--selftest":
		os.exit(cmd_selftest(args[1:]))
	case "--layout":
		fmt.print(LAYOUT_TEXT)
		os.exit(0)
	case "--parse":
		os.exit(cmd_parse(args[1:]))
	case "--extract":
		os.exit(cmd_extract(args[1:]))
	case "--thread":
		os.exit(cmd_thread(args[1:]))
	case "fetch":
		os.exit(cmd_fetch(args[1:]))
	case "send":
		os.exit(cmd_send(args[1:]))
	case "palm":
		os.exit(cmd_palm(args[1:]))
	case "-h", "--help":
		usage()
		os.exit(0)
	}
	fmt.eprintfln("mailcore: unknown command %q", args[0])
	usage()
	os.exit(2)
}

usage :: proc() {
	fmt.eprintln(
		`mailcore — IMAP, POP3, JMAP, SMTP, MIME and Maildir, for loopback only.

  mailcore --selftest [--verbose] [--no-e2e] [--no-tls] [--testserver PATH]
  mailcore --layout                       describe the Maildir this writes
  mailcore --parse FILE                   dump a message's MIME tree
  mailcore --extract FILE [--out DIR] [--section N] [--force]
                                          write a message's attachments out
  mailcore --thread [--root DIR] [--folder NAME]
  mailcore fetch --proto imap|pop3|jmap --port N --user U --password P
                 [--host 127.0.0.1] [--folder NAME] [--root DIR]
                 [--tls none|verify|insecure] [--ca FILE] [--trace]
  mailcore send  --port N --user U --password P --to ADDR
                 [--host 127.0.0.1] [--subject S] [--text T] [--attach FILE]
                 [--tls none|verify|insecure] [--ca FILE] [--trace]
  (fetch --proto jmap also takes --token T | --token-file F, and --account ID|NAME)
  mailcore palm login --email E --password P [--auth-port N]
  mailcore palm sync  [--jmap-port N] [--submit-port N]
  mailcore palm status | logout
                 a Palmframe account: sign in, then sync every identity the
                 session can reach into its own Maildir. See palm.odin.

Every network command refuses any host outside 127.0.0.0/8, and this program
never resolves a name.`,
	)
}

// ---------------------------------------------------------------------------
// --selftest
// ---------------------------------------------------------------------------

cmd_selftest :: proc(args: []string) -> int {
	t := T {
		failures = make([dynamic]string, 0, 16),
	}
	run_e2e := true
	want_tls := true
	testserver := ""
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--verbose", "-v":
			t.verbose = true
		case "--no-e2e":
			run_e2e = false
		case "--no-tls":
			want_tls = false
		case "--testserver":
			i += 1
			if i < len(args) {testserver = args[i]}
		case:
			fmt.eprintfln("mailcore --selftest: unknown option %q", args[i])
			return 2
		}
	}

	fmt.println("mailcore selftest")
	fmt.println(strings.repeat("═", 72, context.temp_allocator))
	fmt.println("No network except 127.0.0.1. No real credentials. No real mail.")

	selftest_unit(&t)
	unit_total := t.passed + t.failed
	fmt.printfln("\nunit assertions: %d passed, %d failed", t.passed, t.failed)

	if run_e2e {
		selftest_e2e(&t, testserver, want_tls)
	} else {
		tsection(&t, "end to end")
		tcheck(&t, "the end-to-end pass was skipped by request (--no-e2e)", true)
	}

	fmt.println()
	fmt.println(strings.repeat("═", 72, context.temp_allocator))
	total := t.passed + t.failed
	fmt.printfln("assertions : %d", total)
	fmt.printfln("  unit     : %d", unit_total)
	fmt.printfln("  e2e      : %d", total - unit_total)
	fmt.printfln("passed     : %d", t.passed)
	fmt.printfln("failed     : %d", t.failed)
	if t.failed > 0 {
		fmt.println("\nfailures:")
		for f in t.failures {
			fmt.printfln("  %s", f)
		}
		fmt.println("\nRESULT: FAIL")
		return 1
	}
	fmt.println("\nRESULT: PASS")
	return 0
}

// ---------------------------------------------------------------------------
// --parse
// ---------------------------------------------------------------------------

cmd_parse :: proc(args: []string) -> int {
	if len(args) < 1 {
		fmt.eprintln("mailcore --parse: needs a file")
		return 2
	}
	data, err := os.read_entire_file_from_path(args[0], context.allocator)
	if err != nil {
		fmt.eprintfln("mailcore: cannot read %s: %v", args[0], err)
		return 1
	}
	m := parse_message(data, context.allocator)
	fmt.printfln("Subject : %s", m.subject)
	for a in m.from {
		fmt.printfln("From    : %s <%s>", a.name, a.email)
	}
	for a in m.to {
		fmt.printfln("To      : %s <%s>", a.name, a.email)
	}
	fmt.printfln("Date    : %s", m.date_raw)
	if m.date.ok {
		fmt.printfln("          unix %d, offset %+d minutes%s", m.date.unix, m.date.tz_minutes, m.date.tz_known ? "" : " (unknown)")
	} else {
		fmt.println("          UNPARSEABLE")
	}
	fmt.printfln("Msg-ID  : %s", m.message_id)
	if len(m.references) > 0 {
		fmt.printfln("Refs    : %s", strings.join(m.references, " ", context.temp_allocator))
	}
	fmt.println("\nstructure:")
	dump_part(&m.root, 0)
	fmt.printfln("\ntext/plain: %d bytes", len(m.text_plain))
	fmt.printfln("text/html : %d bytes", len(m.text_html))
	if len(m.attachments) > 0 {
		fmt.println("\nattachments:")
		for a in m.attachments {
			fmt.printfln(
				"  %-40s %-28s %7d bytes%s%s",
				a.filename == "" ? "<unnamed>" : a.filename,
				a.mime_type,
				a.size,
				a.is_inline ? " inline" : "",
				a.content_id == "" ? "" : fmt.tprintf(" cid:%s", a.content_id),
			)
		}
	}
	if len(m.warnings) > 0 {
		fmt.printfln("\n%d warning(s):", len(m.warnings))
		for w in m.warnings {
			fmt.printfln("  %s", w)
		}
	} else {
		fmt.println("\nno warnings")
	}
	return 0
}

dump_part :: proc(p: ^Part, depth: int) {
	pad := strings.repeat("  ", depth, context.temp_allocator)
	label := p.section == "" ? "(root)" : p.section
	extra := ""
	if p.filename != "" {
		extra = fmt.tprintf(" filename=%q", p.filename)
	}
	if p.boundary != "" {
		extra = fmt.tprintf("%s boundary=%q", extra, p.boundary)
	}
	fmt.printfln(
		"%s%-8s %s/%s  cte=%s charset=%s raw=%d decoded=%d%s%s",
		pad,
		label,
		p.main,
		p.sub,
		p.encoding,
		p.charset_name == "" ? "-" : p.charset_name,
		len(p.raw_body),
		len(p.content),
		extra,
		p.unterminated ? "  [UNTERMINATED]" : "",
	)
	for i in 0 ..< len(p.parts) {
		dump_part(&p.parts[i], depth + 1)
	}
}

// ---------------------------------------------------------------------------
// --extract
//
// The other half of `--parse`: not "what parts are in here" but "put them on
// disk". Every byte written is the transfer-decoded content, and every name is
// run through the sanitiser and then through the containment check, so a
// message whose filename is "../../.bashrc" writes ".bashrc" into the
// directory that was asked for and nowhere else.
// ---------------------------------------------------------------------------

cmd_extract :: proc(args: []string) -> int {
	file := ""
	out := "."
	section := ""
	force := false
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--out":
			i += 1;if i < len(args) {out = args[i]}
		case "--section":
			i += 1;if i < len(args) {section = args[i]}
		case "--force":
			force = true
		case:
			if strings.has_prefix(args[i], "-") {
				fmt.eprintfln("mailcore --extract: unknown option %q", args[i])
				return 2
			}
			file = args[i]
		}
	}
	if file == "" {
		fmt.eprintln("mailcore --extract: needs a file")
		return 2
	}
	data, err := os.read_entire_file_from_path(file, context.allocator)
	if err != nil {
		fmt.eprintfln("mailcore: cannot read %s: %v", file, err)
		return 1
	}
	if !os.is_dir(out) {
		fmt.eprintfln("mailcore: %s is not a directory", out)
		return 1
	}
	m := parse_message(data, context.allocator)

	inline_parts := message_inline_parts(&m, context.allocator)
	saveable := message_saveable(&m, context.allocator)
	if len(saveable) == 0 {
		fmt.printfln("%s: nothing to extract (%d inline part(s))", file, len(inline_parts))
		return 0
	}

	wrote, failed := 0, 0
	for s in saveable {
		if section != "" && s.section != section {
			continue
		}
		path, werr := attachment_write(out, s, force, context.allocator)
		if werr != "" {
			fmt.eprintfln("  %-30s FAILED  %s", s.filename, werr)
			failed += 1
			continue
		}
		fmt.printfln("  %-30s %-28s %d bytes -> %s", s.filename, s.mime_type, s.size, path)
		wrote += 1
	}
	for a in inline_parts {
		fmt.printfln("  %-30s %-28s %d bytes    inline, cid:%s — not written", a.filename == "" ? "<unnamed>" : a.filename, a.mime_type, a.size, a.content_id)
	}
	fmt.printfln("%d written, %d failed, %d inline", wrote, failed, len(inline_parts))
	return failed > 0 ? 1 : 0
}

// ---------------------------------------------------------------------------
// --thread
// ---------------------------------------------------------------------------

cmd_thread :: proc(args: []string) -> int {
	root := ""
	folder := INBOX
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--root":
			i += 1;if i < len(args) {root = args[i]}
		case "--folder":
			i += 1;if i < len(args) {folder = args[i]}
		case:
			fmt.eprintfln("mailcore --thread: unknown option %q", args[i])
			return 2
		}
	}
	path, perr := resolve_root(root)
	if perr != "" {
		fmt.eprintfln("mailcore: %s", perr)
		return 2
	}
	md, oerr := maildir_open(path, context.allocator)
	if oerr != "" {
		fmt.eprintfln("mailcore: %s", oerr)
		return 1
	}
	th, items := maildir_thread(&md, folder, true, context.allocator)
	fmt.printfln("%s / %s: %d messages in %d threads\n", path, folder, len(items), len(th.roots))
	for r in th.roots {
		for row in thread_flatten(th, r, context.temp_allocator) {
			pad := strings.repeat("  ", row.depth, context.temp_allocator)
			if row.item < 0 {
				fmt.printfln("%s(missing message)", pad)
				continue
			}
			it := items[row.item]
			fmt.printfln("%s%s  [%s]", pad, it.subject == "" ? "(no subject)" : it.subject, it.message_id)
		}
		fmt.println()
	}
	return 0
}

// resolve_root keeps every path under the one permitted Maildir location.
resolve_root :: proc(given: string) -> (path: string, err: string) {
	base := maildir_default_root(context.allocator)
	if given == "" {
		return base, ""
	}
	if strings.has_prefix(given, "/") {
		if !strings.has_prefix(given, base) {
			return "", fmt.aprintf(
				"refusing %q: mailcore only ever writes under %s",
				given,
				base,
			)
		}
		return given, ""
	}
	if strings.contains(given, "..") {
		return "", fmt.aprintf("refusing %q: it contains ..", given)
	}
	return strings.concatenate({base, "/", given}, context.allocator), ""
}

// ---------------------------------------------------------------------------
// fetch / send
// ---------------------------------------------------------------------------

Net_Args :: struct {
	host:     string,
	port:     int,
	user:     string,
	password: string,
	proto:    string,
	folder:   string,
	root:     string,
	tls:      Tls_Mode,
	ca:       string,
	trace:    bool,
	to:       string,
	subject:  string,
	text:     string,
	attach:   string,
	token:    string, // a bearer token instead of --user/--password (JMAP)
	account:  string, // which JMAP account, by id or name
}

parse_net_args :: proc(args: []string) -> (na: Net_Args, err: string) {
	na.host = "127.0.0.1"
	na.folder = INBOX
	for i := 0; i < len(args); i += 1 {
		next :: proc(args: []string, i: ^int) -> string {
			i^ += 1
			return i^ < len(args) ? args[i^] : ""
		}
		switch args[i] {
		case "--host":
			na.host = next(args, &i)
		case "--port":
			na.port, _ = strconv.parse_int(next(args, &i), 10)
		case "--user":
			na.user = next(args, &i)
		case "--password":
			na.password = next(args, &i)
		case "--proto":
			na.proto = strings.to_lower(next(args, &i), context.allocator)
		case "--folder":
			na.folder = next(args, &i)
		case "--root":
			na.root = next(args, &i)
		case "--ca":
			na.ca = next(args, &i)
		case "--to":
			na.to = next(args, &i)
		case "--subject":
			na.subject = next(args, &i)
		case "--text":
			na.text = next(args, &i)
		case "--attach":
			na.attach = next(args, &i)
		case "--token":
			na.token = next(args, &i)
		case "--token-file":
			path := next(args, &i)
			data, rerr := os.read_entire_file_from_path(path, context.allocator)
			if rerr != nil {
				return na, fmt.aprintf("cannot read %s", path)
			}
			na.token = strings.trim_space(string(data))
		case "--account":
			na.account = next(args, &i)
		case "--trace":
			na.trace = true
		case "--tls":
			switch strings.to_lower(next(args, &i), context.temp_allocator) {
			case "none", "":
				na.tls = .None
			case "verify":
				na.tls = .Verify
			case "insecure":
				na.tls = .Insecure
			case:
				return na, "--tls takes none, verify or insecure"
			}
		case:
			return na, fmt.aprintf("unknown option %q", args[i])
		}
	}
	if na.port == 0 {
		return na, "--port is required (there are no default ports here; this only talks to a local test server)"
	}
	return na, ""
}

cmd_fetch :: proc(args: []string) -> int {
	na, aerr := parse_net_args(args)
	if aerr != "" {
		fmt.eprintfln("mailcore fetch: %s", aerr)
		return 2
	}
	root, rerr := resolve_root(na.root == "" ? fmt.tprintf("%s", na.user == "" ? "account" : na.user) : na.root)
	if rerr != "" {
		fmt.eprintfln("mailcore: %s", rerr)
		return 2
	}
	md, oerr := maildir_open(root, context.allocator)
	if oerr != "" {
		fmt.eprintfln("mailcore: %s", oerr)
		return 1
	}
	opts := Dial_Opts {
		tls     = na.tls,
		ca_file = na.ca,
		trace   = na.trace,
	}

	switch na.proto {
	case "imap":
		im: IMAP
		if err := imap_connect(&im, na.host, na.port, opts, context.allocator); err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		defer imap_close(&im)
		if err := imap_login(&im, na.user, na.password); err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		if na.folder == "*" {
			results, err := imap_sync_all(&im, &md, context.allocator)
			if err != "" {
				fmt.eprintfln("mailcore: %s", err)
				return 1
			}
			for r in results {
				fmt.printfln("%-24s %4d messages, %8d bytes", r.folder, r.fetched, r.bytes)
			}
		} else {
			r, err := imap_sync(&im, &md, na.folder, na.folder, context.allocator)
			if err != "" {
				fmt.eprintfln("mailcore: %s", err)
				return 1
			}
			fmt.printfln("%-24s %4d messages, %8d bytes", r.folder, r.fetched, r.bytes)
		}
		imap_logout(&im)

	case "pop3":
		p: POP3
		if err := pop3_connect(&p, na.host, na.port, opts, context.allocator); err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		defer pop3_close(&p)
		pop3_capa(&p)
		if err := pop3_login(&p, na.user, na.password); err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		// POP3 has no folders: only INBOX can be filled, and the existing
		// UIDLs are used so a second run is a no-op.
		seen := make(map[string]bool, 64, context.allocator)
		r, err := pop3_sync(&p, &md, seen, context.allocator)
		if err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		fmt.printfln("INBOX                    %4d messages, %8d bytes (POP3 has no folders)", r.fetched, r.bytes)
		pop3_quit(&p)

	case "jmap":
		j: JMAP
		err: string
		if na.token != "" {
			err = jmap_connect_bearer(&j, na.host, na.port, na.token, opts, context.allocator)
		} else {
			err = jmap_connect(&j, na.host, na.port, na.user, na.password, opts, context.allocator)
		}
		if err == "" && na.account != "" {
			err = jmap_use_account(&j, na.account)
		}
		if err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
		defer jmap_close(&j)
		boxes, berr := jmap_mailbox_get(&j, context.allocator)
		if berr != "" {
			fmt.eprintfln("mailcore: %s", berr)
			return 1
		}
		for b in boxes {
			if na.folder != "*" && !strings.equal_fold(b.name, na.folder) && !(na.folder == INBOX && strings.equal_fold(b.role, "inbox")) {
				continue
			}
			folder := strings.equal_fold(b.role, "inbox") ? INBOX : b.name
			r, err := jmap_sync(&j, &md, b.id, folder, context.allocator)
			if err != "" {
				fmt.eprintfln("mailcore: %s", err)
				return 1
			}
			fmt.printfln("%-24s %4d messages, %8d bytes", r.folder, r.fetched, r.bytes)
		}

	case "":
		fmt.eprintln("mailcore fetch: --proto is required (imap, pop3 or jmap)")
		return 2
	case:
		fmt.eprintfln("mailcore fetch: unknown protocol %q", na.proto)
		return 2
	}
	fmt.printfln("Maildir: %s", root)
	return 0
}

cmd_send :: proc(args: []string) -> int {
	na, aerr := parse_net_args(args)
	if aerr != "" {
		fmt.eprintfln("mailcore send: %s", aerr)
		return 2
	}
	if na.to == "" {
		fmt.eprintln("mailcore send: --to is required")
		return 2
	}
	s: SMTP
	opts := Dial_Opts {
		tls     = na.tls,
		ca_file = na.ca,
		trace   = na.trace,
	}
	if err := smtp_connect(&s, na.host, na.port, opts, context.allocator); err != "" {
		fmt.eprintfln("mailcore: %s", err)
		return 1
	}
	defer smtp_close(&s)
	if err := smtp_ehlo(&s, "mailcore"); err != "" {
		fmt.eprintfln("mailcore: %s", err)
		return 1
	}
	if na.user != "" {
		// A Palmframe submission server takes the access token as the
		// password (--token / --token-file).
		secret := na.token != "" ? na.token : na.password
		if err := smtp_auth_plain(&s, na.user, secret); err != "" {
			fmt.eprintfln("mailcore: %s", err)
			return 1
		}
	}
	from := na.user
	if !strings.contains(from, "@") {
		from = fmt.tprintf("%s@localhost", from)
	}
	c := Compose {
		from    = {email = from},
		to      = {{email = na.to}},
		subject = na.subject,
		text    = na.text == "" ? "(no body)\n" : strings.concatenate({na.text, "\n"}, context.allocator),
	}
	if na.attach != "" {
		data, rerr := os.read_entire_file_from_path(na.attach, context.allocator)
		if rerr != nil {
			fmt.eprintfln("mailcore: cannot read %s: %v", na.attach, rerr)
			return 1
		}
		name := na.attach
		if i := strings.last_index_byte(name, '/'); i >= 0 {
			name = name[i + 1:]
		}
		c.attachments = {{filename = name, content = data}}
	}
	body, msgid := compose_build(c, context.allocator)
	accepted, serr := smtp_send(&s, compose_envelope(c, body, context.allocator))
	if serr != "" {
		fmt.eprintfln("mailcore: %s", serr)
		return 1
	}
	fmt.printfln("sent <%s> to %d recipient(s): %v", msgid, len(accepted), accepted)
	smtp_quit(&s)
	return 0
}
