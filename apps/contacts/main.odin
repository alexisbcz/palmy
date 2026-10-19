// Contacts — address books for every Palmy identity, over CardDAV.
//
// The window and `contacts <verb>` share one model (model.odin). Cards live
// in the davclient cache and sync with cloud/dav; see cloud/docs/calendar-
// contacts.md for the server side.
package main

import "core:fmt"
import "core:os"
import kit "kit:."

tfmt :: fmt.tprintf

main :: proc() {
	args := os.args[1:]
	// `--shots <dir>` renders the window offscreen (shot.odin); it is not a
	// verb, so it is looked for before the CLI takes the line.
	for a, i in args {
		if a == "--shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("contacts --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
	}
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	os.exit(run_window())
}
