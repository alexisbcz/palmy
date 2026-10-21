package main

// mailcore — the engine half of a mail client.
//
//	mailcore --selftest [--verbose] [--no-e2e] [--no-tls] [--testserver PATH]
//	mailcore layout | parse | extract | thread | folders | list
//	mailcore fetch | send | login | sync | status | logout
//	mailcore --schema | --help | help <command>
//
// The command line is declared in cli.odin and parsed by the shared
// convention in apps/kit/cli.odin (docs/PALM-CLI.md): every command takes
// --json, --dry-run where it changes anything, and exits with the documented
// codes. The older spellings all still work — `--layout`, `--parse FILE`,
// `--extract FILE`, `--thread` are aliases of the commands, and
// `mailcore palm login|sync|status|logout`, which apps/mail runs from its
// sign-in sheet, is the same four commands under their old prefix.
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
	os.exit(cli_main(os.args[1:]))
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
