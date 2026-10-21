// money — a personal banking and budgeting application for palmy.
//
// It reads bank statements off the disk and nothing else. There is no network
// code in this program: no open-banking client, no PSD2 flow, no aggregator,
// no scraping, no rate feed, and no password field anywhere in the interface,
// because there is nothing to log in to. The user exports a statement from
// their bank the way they already can, and imports the file.
//
// That is not a limitation worked around; it is the design. A finance tool
// that holds a bank credential is a liability to its user, and one that reads
// files is testable, which is why every import format here is asserted
// against fixtures.
//
// Files are read only when the user picks them in the dialog. The only
// directory this program writes to is ~/.local/share/palmy-money.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

main :: proc() {
	// Flags are read in a loop rather than only at args[0]: `--start-dir` is
	// a setting and not a mode, so whatever follows it — including `--help`
	// — still has to be honoured. Reading only the first argument meant
	// `money --start-dir X --help` silently opened a window, which is the
	// one thing a tool should never do when it was asked a question.
	args := os.args[1:]

	// The command line is the other front end over the same book: see cli.odin
	// for the declaration and apps/kit/cli.odin for the convention it is parsed
	// by. A declared verb, `help`, --help, --schema and --selftest go there.
	// The older spellings below keep their exact old behaviour, so nothing
	// that already drives this program changes. A bare FILE goes past the
	// kit first, which hands it back only when every bare word on the line
	// names a file (takes_word): a mistyped verb is a usage error rather
	// than a window that tries to import it.
	if len(args) > 0 && (is_cli_head(args[0]) || !strings.has_prefix(args[0], "-")) {
		if code, handled := kit.cli(surface()); handled {
			os.exit(code)
		}
	}

	start_dir := ""
	files := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		switch a {
		case "--help", "-h":
			fmt.print(kit.cli_help_text(surface()))
			return
		case "--selftest":
			os.exit(selftest_mode())
		case "--shot":
			os.exit(shot_mode(args[i + 1:]))
		case "--bench":
			os.exit(bench_mode(args[i + 1:]))
		case "--fixtures":
			os.exit(fixtures_mode(args[i + 1:]))
		case "--import":
			os.exit(import_mode(args[i + 1:]))
		case "--start-dir":
			// Only where the dialog opens; nothing is read from it until the
			// user picks a file.
			if i + 1 < len(args) {
				start_dir = args[i + 1]
				i += 1
			}
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("money: unknown flag %s", a)
				fmt.eprint(kit.cli_help_text(surface()))
				os.exit(2)
			}
			append(&files, a)
		}
	}

	papp, err := kit.start({title = "Comptes", app_id = "palmy-money", width = 1280, height = 800})
	if err != "" {
		fmt.eprintfln("money: %s", err)
		os.exit(1)
	}
	defer p.destroy(papp)

	app := new(App)
	defer free(app)
	app_init(app)
	defer app_destroy(app)
	app.fonts = &papp.fonts
	app.start_dir = start_dir
	store_load(app)
	if txn_count(&app.led) == 0 {
		// A first run with nothing saved opens on the fictitious demo book,
		// so the application is explorable before anybody hands it a real
		// statement. Nothing here came off the user's disk.
		seed_demo(app)
	}
	// A file named on the command line is an explicit request to import it,
	// which is the only other way a file reaches this program.
	for f in files {
		do_import(app, f)
	}
	ensure_categories(app)
	refilter(app)

	for ui in p.frames(papp) {
		frame(ui, app)
	}
	store_save(app)
}

// is_cli_head says whether the first argument belongs to the convention
// rather than to one of the older spellings handled in main.
is_cli_head :: proc(a: string) -> bool {
	switch a {
	case "help", "--help", "-h", "--schema", "--selftest", "--self-test", "-t":
		return true
	}
	for cmd in surface().commands {
		if cmd.verb == a {
			return true
		}
		for al in cmd.aliases {
			if al == a {
				return true
			}
		}
	}
	return false
}
