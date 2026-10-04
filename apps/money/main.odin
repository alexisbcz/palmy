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

USAGE :: `money — comptes et budget, pour palmy

  money                        open the application
  money --selftest             run the test suite: no window, no files touched
  money --shot OUT.png [steps] render one frame offscreen
  money --bench [n]            import and search timings over n transactions
  money --fixtures DIR         write the (fictitious) test fixtures to DIR
  money --import FILE          import a statement headless and print a summary
  money --start-dir DIR        where the import dialog opens
  money FILE                   import FILE at startup
  money --help`

main :: proc() {
	args := os.args[1:]
	start_dir := ""
	if len(args) > 0 {
		switch args[0] {
		case "--help", "-h":
			fmt.println(USAGE)
			return
		case "--selftest":
			os.exit(selftest_mode())
		case "--shot":
			os.exit(shot_mode(args[1:]))
		case "--bench":
			os.exit(bench_mode(args[1:]))
		case "--fixtures":
			os.exit(fixtures_mode(args[1:]))
		case "--import":
			os.exit(import_mode(args[1:]))
		case "--start-dir":
			// Only where the dialog opens; nothing is read from it until the
			// user picks a file.
			if len(args) > 1 {
				start_dir = args[1]
				args = args[2:]
			} else {
				args = args[1:]
			}
		case:
			if strings.has_prefix(args[0], "-") {
				fmt.eprintfln("money: unknown flag %s", args[0])
				fmt.eprintln(USAGE)
				os.exit(2)
			}
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
	for a in args {
		if strings.has_prefix(a, "-") {
			continue
		}
		do_import(app, a)
		break
	}
	ensure_categories(app)
	refilter(app)

	for ui in p.frames(papp) {
		frame(ui, app)
	}
	store_save(app)
}
