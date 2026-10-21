package main

// The command line, asserted. Every check that runs a command runs this very
// binary as a child, with its own $XDG_DATA_HOME and $PALM_AUDIT under /tmp,
// so what is tested is what a caller gets — stdout, exit code and all — and
// nothing here can touch a real Maildir, a real session or the real audit log.
// No socket is opened: the network commands are exercised with --dry-run or
// against an address the loopback gate refuses.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."

@(private = "file")
cli_cmd :: proc(verb: string) -> ^kit.Command {
	for &c in surface().commands {
		if c.verb == verb {
			return &c
		}
	}
	return nil
}

@(private = "file")
shq :: proc(s: string) -> string {
	return fmt.tprintf("'%s'", strings.join(strings.split(s, "'", context.temp_allocator), `'\''`, context.temp_allocator))
}

// run_self runs this binary with `env` prepended and returns stdout and the
// exit code. stderr is discarded: the convention says nothing a caller parses
// is ever there.
@(private = "file")
run_self :: proc(env: []string, args: ..string) -> (out: string, code: int) {
	exe, err := os.get_executable_path(context.temp_allocator)
	if err != nil {
		exe = os.args[0]
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "env")
	for e in env {
		fmt.sbprintf(&sb, " %s", shq(e))
	}
	fmt.sbprintf(&sb, " %s", shq(exe))
	for a in args {
		fmt.sbprintf(&sb, " %s", shq(a))
	}
	strings.write_string(&sb, " 2>/dev/null")
	state, sout, _, perr := os.process_exec({command = {"sh", "-c", strings.to_string(sb)}}, context.temp_allocator)
	if perr != nil {
		return "", -1
	}
	return string(sout), state.exit_code
}

@(private = "file")
valid :: proc(t: ^T, name, out, verb: string) -> bool {
	cmd := cli_cmd(verb)
	if cmd == nil {
		return tcheck(t, name, false, "no such command")
	}
	problems := kit.cli_validate_output(out, cmd.out, context.temp_allocator)
	return tcheck(t, name, len(problems) == 0, len(problems) > 0 ? problems[0] : "")
}

@(private = "file")
field :: proc(out, key: string) -> json.Value {
	v, err := json.parse_string(out, json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
	if err != nil {
		return nil
	}
	obj, ok := v.(json.Object)
	if !ok {
		return nil
	}
	return obj[key]
}

@(private = "file")
field_int :: proc(out, key: string) -> int {
	#partial switch n in field(out, key) {
	case json.Integer:
		return int(n)
	case json.Float:
		return int(n)
	}
	return -1
}

@(private = "file")
field_len :: proc(out, key: string) -> int {
	if a, ok := field(out, key).(json.Array); ok {
		return len(a)
	}
	return -1
}

test_cli :: proc(t: ^T) {
	tsection(t, "the command line (palm convention)")

	s := surface()
	tcheck(t, "the surface is named mailcore", s.noun == "mailcore")
	tcheck(t, "and declares its commands", len(s.commands) >= 12)
	examples := 0
	for &c in s.commands {
		tcheck(t, fmt.tprintf("%s declares what it prints", c.verb), len(c.out) > 0)
		tcheck(t, fmt.tprintf("%s has a summary and an example", c.verb), c.summary != "" && len(c.examples) > 0)
		for ex in c.examples {
			words := kit.cli_split_example(ex)
			if !tcheck(t, fmt.tprintf("%q is typed as the binary is named", ex), len(words) > 1 && words[0] == "mailcore") {
				continue
			}
			call, code := kit.cli_bind(s, words[1:])
			teq_int(t, fmt.tprintf("%q parses", ex), code, kit.EXIT_OK)
			tcheck(t, fmt.tprintf("and binds to %s", c.verb), call.cmd != nil && call.cmd.verb == c.verb)
			examples += 1
		}
	}
	tcheck(t, "there are examples to check", examples >= 15)
	for legacy in ([?][2]string{{"--layout", "layout"}, {"--parse", "parse"}, {"--extract", "extract"}, {"--thread", "thread"}}) {
		c := cli_cmd(legacy[1])
		found := false
		if c != nil {
			for a in c.aliases {
				found ||= a == legacy[0]
			}
		}
		tcheck(t, fmt.tprintf("the old spelling %s is still accepted", legacy[0]), found)
	}
	// Reads are reads, and nothing here is destructive: the one command that
	// throws something away (logout) loses a token a sign-in gives back.
	for &c in s.commands {
		switch c.verb {
		case "layout", "parse", "thread", "folders", "list", "status":
			tcheck(t, fmt.tprintf("%s is a read", c.verb), c.effect == .Read)
		case "fetch", "send", "login", "sync", "extract":
			tcheck(t, fmt.tprintf("%s is a mutation", c.verb), c.effect == .Mutate)
		}
	}

	// A private world under /tmp.
	tmp := fmt.tprintf("/tmp/mailcore-cli-%d", os.get_pid())
	os.remove_all(tmp)
	defer os.remove_all(tmp)
	xdg := fmt.tprintf("%s/xdg", tmp)
	audit := fmt.tprintf("%s/audit.jsonl", tmp)
	env := []string{fmt.tprintf("XDG_DATA_HOME=%s", xdg), fmt.tprintf("PALM_AUDIT=%s", audit), "PALM_IDENTITY="}
	os.make_directory_all(xdg)

	exe, _ := os.get_executable_path(context.temp_allocator)
	dir := exe
	if i := strings.last_index_byte(dir, '/'); i >= 0 {
		dir = dir[:i]
	}
	fixture := fmt.tprintf("%s/testdata/report.eml", dir)
	tcheck(t, "the synthetic fixture is beside the binary", os.exists(fixture), fixture)

	{
		_, code := run_self(env)
		teq_int(t, "no command is a usage error, never a prompt", code, kit.EXIT_USAGE)
		out, sc := run_self(env, "--schema")
		teq_int(t, "--schema answers", sc, 0)
		tcheck(t, "with the declaration", strings.contains(out, `"noun": "mailcore"`))
	}

	// parse, under both spellings.
	{
		out, code := run_self(env, "parse", fixture, "--json")
		teq_int(t, "parse --json exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "parse")
		if sub, ok := field(out, "subject").(json.String); ok {
			teq(t, "the encoded-word subject is decoded", string(sub), "Quarterly réport")
		} else {
			tcheck(t, "the subject is a string", false)
		}
		teq_int(t, "one attachment", field_len(out, "attachments"), 1)
		teq_int(t, "five parts in the tree", field_len(out, "parts"), 5)
		old, ocode := run_self(env, "--parse", fixture, "--json")
		teq_int(t, "--parse FILE still works", ocode, 0)
		tcheck(t, "and prints the same document", old == out)
		miss, mcode := run_self(env, "parse", fmt.tprintf("%s/nope.eml", tmp), "--json")
		teq_int(t, "a missing message is not found", mcode, kit.EXIT_NOT_FOUND)
		tcheck(t, "with the documented token", strings.contains(miss, `"error": "not found"`))
	}

	// extract: the dry run writes nothing, the real run writes the decoded bytes.
	{
		outdir := fmt.tprintf("%s/out", tmp)
		os.make_directory_all(outdir)
		out, code := run_self(env, "extract", fixture, "--out", outdir, "--dry-run", "--json")
		teq_int(t, "extract --dry-run exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "extract")
		tcheck(t, "and writes nothing", !os.exists(fmt.tprintf("%s/figures.csv", outdir)))
		out2, code2 := run_self(env, "--extract", fixture, "--out", outdir, "--json")
		teq_int(t, "--extract FILE --out DIR still works", code2, 0)
		teq_int(t, "and reports one file written", field_len(out2, "written"), 1)
		data, _ := os.read_entire_file_from_path(fmt.tprintf("%s/figures.csv", outdir), context.temp_allocator)
		teq(t, "the attachment is the decoded bytes", string(data), "quarter,revenue\nQ1,100\nQ2,120\nQ3,135\n")
		_, code3 := run_self(env, "extract", fixture, "--out", outdir, "--json")
		teq_int(t, "a second extract without --force refuses to overwrite", code3, kit.EXIT_FAILED)
	}

	// A Maildir made by the engine itself, read back through the commands.
	{
		root := fmt.tprintf("%s/palmy-mail/ada@example.test", xdg)
		md, oerr := maildir_open(root)
		teq(t, "a scratch Maildir opens", oerr, "")
		raw, _ := os.read_entire_file_from_path(fixture, context.temp_allocator)
		_, e1 := maildir_deliver(&md, INBOX, raw)
		_, e2 := maildir_deliver(&md, INBOX, raw, {.Seen}, false)
		_, e3 := maildir_deliver(&md, "Archive", raw, {.Seen}, false)
		tcheck(t, "and three copies of the fixture are delivered", e1 == "" && e2 == "" && e3 == "")

		out, code := run_self(env, "folders", "ada@example.test", "--json")
		teq_int(t, "folders --json exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "folders")
		teq_int(t, "INBOX and Archive", field_len(out, "folders"), 2)
		tcheck(t, "INBOX has two, one unread", strings.contains(out, `"name": "INBOX",
      "total": 2,
      "unread": 1`))

		out, code = run_self(env, "list", "ada@example.test", "--json")
		teq_int(t, "list --json exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "list")
		teq_int(t, "two messages in INBOX", field_int(out, "total"), 2)
		out, code = run_self(env, "list", "ada@example.test", "--unread", "--json")
		teq_int(t, "one of them unread", field_int(out, "total"), 1)
		out, code = run_self(env, "list", "ada@example.test", "--folder", "Archive", "--json")
		teq_int(t, "and one in Archive", field_int(out, "total"), 1)
		_, code = run_self(env, "list", "ada@example.test", "--folder", "Nope", "--json")
		teq_int(t, "a folder that is not there is not found", code, kit.EXIT_NOT_FOUND)
		_, code = run_self(env, "folders", "nobody@example.test", "--json")
		teq_int(t, "an account that is not there is not found", code, kit.EXIT_NOT_FOUND)
		tcheck(t, "and reading it created nothing", !os.exists(fmt.tprintf("%s/palmy-mail/nobody@example.test", xdg)))
		_, code = run_self(env, "list", "../../etc", "--json")
		teq_int(t, "a path that climbs out of the root is refused", code, kit.EXIT_USAGE)

		out, code = run_self(env, "thread", "--root", "ada@example.test", "--json")
		teq_int(t, "thread --json exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "thread")
		teq_int(t, "it threads both messages", field_int(out, "messages"), 2)
		_, code = run_self(env, "--thread", "--root", "ada@example.test")
		teq_int(t, "--thread --root DIR still works", code, 0)

		// Scope: an account synced for the work identity is not readable from
		// inside the personal one.
		conf := "[session]\nemail = ada@example.test\n\n[identity]\nid = 1\nhandle = work\nkind = work\naddress = ada@example.test\npath = ada@example.test\n"
		_ = os.write_entire_file(fmt.tprintf("%s/palmy-mail/palmy.conf", xdg), transmute([]u8)conf)
		scoped := []string{env[0], env[1], "PALM_IDENTITY=personal"}
		refused, rcode := run_self(scoped, "list", "ada@example.test", "--json")
		teq_int(t, "another identity's account is out of scope", rcode, kit.EXIT_OUT_OF_SCOPE)
		tcheck(t, "with the documented token", strings.contains(refused, `"error": "out of scope"`))
		_, rcode = run_self(env, "folders", "ada@example.test", "--identity", "personal", "--json")
		teq_int(t, "and narrowing to it by flag is refused too", rcode, kit.EXIT_OUT_OF_SCOPE)
		owner := []string{env[0], env[1], "PALM_IDENTITY=work"}
		_, rcode = run_self(owner, "list", "ada@example.test", "--json")
		teq_int(t, "while its own identity reads it", rcode, 0)
	}

	// The session commands, and the old `palm` prefix apps/mail still uses.
	{
		out, code := run_self(env, "status", "--json")
		teq_int(t, "status with no session is not found", code, kit.EXIT_NOT_FOUND)
		tcheck(t, "with the documented error object", strings.contains(out, `"detail": "not signed in"`))
		_, code = run_self(env, "palm", "status")
		teq_int(t, "`mailcore palm status` is the same command", code, kit.EXIT_NOT_FOUND)
		out, code = run_self(env, "palm", "logout", "--json")
		teq_int(t, "`mailcore palm logout` works with nothing to forget", code, 0)
		valid(t, "and matches its declared schema", out, "logout")
		_, code = run_self(env, "sync", "--json")
		teq_int(t, "sync with no session is not found", code, kit.EXIT_NOT_FOUND)

		out, code = run_self(env, "palm", "login", "--email", "ada@example.test", "--password", "synthetic-secret-42", "--dry-run", "--json")
		teq_int(t, "login --dry-run exits 0 without dialling", code, 0)
		valid(t, "and matches its declared schema", out, "login")
		log, _ := os.read_entire_file_from_path(audit, context.temp_allocator)
		tcheck(t, "the login is in the audit log", strings.contains(string(log), `"verb": "login"`))
		tcheck(t, "but its password is not", !strings.contains(string(log), "synthetic-secret-42"))
		tcheck(t, "only a placeholder", strings.contains(string(log), kit.CLI_REDACTED))
		out, code = run_self(env, "login", "--email", "ada@example.test", "--password=synthetic-secret-43", "--nope", "--json")
		teq_int(t, "a login line the kit refuses", code, kit.EXIT_USAGE)
		tcheck(t, "does not repeat its password", !strings.contains(out, "synthetic-secret-43"))
		log, _ = os.read_entire_file_from_path(audit, context.temp_allocator)
		tcheck(t, "nor log it, though the line never bound", !strings.contains(string(log), "synthetic-secret-43"))
		out, code = run_self(env, "login", "--email", "ada@example.test", "--json")
		teq_int(t, "login with neither --password nor --password-file is a usage error", code, kit.EXIT_USAGE)
		tcheck(t, "which names both", strings.contains(out, "--password-file"))
		schema, _ := run_self(env, "--schema")
		tcheck(t, "the schema says the password is secret", strings.contains(schema, `"secret": true`))
		tcheck(t, "and its examples do not carry one", !strings.contains(schema, "alice-pw"))
		tcheck(t, "and no session was written", !os.exists(fmt.tprintf("%s/palmy-mail/.palmy/session", xdg)))
	}

	// The network commands: the gate, and dry runs that dial nothing.
	{
		out, code := run_self(env, "fetch", "--proto", "imap", "--port", "143", "--host", "192.0.2.1", "--json")
		teq_int(t, "fetch from outside 127.0.0.0/8 is refused", code, kit.EXIT_OUT_OF_SCOPE)
		tcheck(t, "and says why", strings.contains(out, "127.0.0.0/8"))
		_, code = run_self(env, "send", "--port", "25", "--host", "mail.example.test", "--to", "bob@example.test", "--json")
		teq_int(t, "send to a name is refused before any lookup", code, kit.EXIT_OUT_OF_SCOPE)
		out, code = run_self(env, "fetch", "--proto", "pop3", "--port", "1", "--user", "ada", "--dry-run", "--json")
		teq_int(t, "fetch --dry-run exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "fetch")
		tcheck(t, "and creates no Maildir", !os.exists(fmt.tprintf("%s/palmy-mail/ada", xdg)))
		out, code = run_self(env, "send", "--port", "1", "--to", "bob@example.test", "--subject", "Hi", "--attach", fixture, "--dry-run", "--json")
		teq_int(t, "send --dry-run composes and exits 0", code, 0)
		valid(t, "and matches its declared schema", out, "send")
		tcheck(t, "with a message id", field_int(out, "bytes") > 600)
		_, code = run_self(env, "fetch", "--proto", "smtp", "--port", "1", "--json")
		teq_int(t, "an unknown protocol is a usage error", code, kit.EXIT_USAGE)
		_, code = run_self(env, "fetch", "--proto", "imap", "--json")
		teq_int(t, "a missing --port is a usage error", code, kit.EXIT_USAGE)
	}

	{
		out, code := run_self(env, "--layout")
		teq_int(t, "--layout still works", code, 0)
		tcheck(t, "and still describes the flag letters", strings.contains(out, "D draft"))
		out, code = run_self(env, "layout", "--json")
		valid(t, "layout --json matches its declared schema", out, "layout")
	}
}

// e2e_cli drives the network commands as a caller would — this binary as a
// child, --json on stdout — against the loopback test server the end-to-end
// pass has already started: alice sends bob a message with `send`, bob's
// INBOX comes down with `fetch`, and `list` finds it there.
e2e_cli :: proc(t: ^T, e: ^E2E) {
	tsection(t, "end to end: the command line against the test server")
	audit := fmt.tprintf("/tmp/mailcore-cli-e2e-%d.jsonl", os.get_pid())
	defer os.remove(audit)
	env := []string{fmt.tprintf("PALM_AUDIT=%s", audit), "PALM_IDENTITY="}
	subject := fmt.tprintf("cli e2e %d", os.get_pid())

	out, code := run_self(
		env,
		"send",
		"--port", fmt.tprintf("%d", e.smtp_port),
		"--user", ALICE,
		"--password", ALICE_PW,
		"--to", "bob@localhost",
		"--subject", subject,
		"--text", "sent through the command line",
		"--json",
	)
	teq_int(t, "send --json exits 0", code, 0)
	valid(t, "and matches its declared schema", out, "send")
	teq_int(t, "and the server accepted one recipient", field_len(out, "accepted"), 1)

	account := "_e2e/cli-bob"
	out, code = run_self(
		env,
		"fetch",
		"--proto", "imap",
		"--port", fmt.tprintf("%d", e.imap_port),
		"--user", BOB,
		"--password", BOB_PW,
		"--root", account,
		"--json",
	)
	teq_int(t, "fetch --json exits 0", code, 0)
	valid(t, "and matches its declared schema", out, "fetch")

	out, code = run_self(env, "list", account, "--json")
	teq_int(t, "list --json over the fetched Maildir exits 0", code, 0)
	valid(t, "and matches its declared schema", out, "list")
	tcheck(t, "and the message sent a moment ago is in it", strings.contains(out, subject))

	_, code = run_self(env, "fetch", "--proto", "imap", "--port", fmt.tprintf("%d", e.imap_port), "--user", BOB, "--password", "wrong", "--root", account, "--json")
	teq_int(t, "a wrong password is a failure, not a hang", code, kit.EXIT_FAILED)

	log, _ := os.read_entire_file_from_path(audit, context.temp_allocator)
	tcheck(t, "both passwords stayed out of the audit log", !strings.contains(string(log), ALICE_PW) && !strings.contains(string(log), BOB_PW))
}
