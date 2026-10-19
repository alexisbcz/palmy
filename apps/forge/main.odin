// forge — the Palmy forge, as a window and as a command.
//
//	forge                         the window
//	forge repo list --json        the command line (`forge --help`)
//	forge shots <dir> [--dark]    render the window offscreen to PNGs
//	forge --selftest
//
// Repositories are owned by identities, not by the account: the window says
// which identity you are acting as, in its colour, on every screen, and a
// scoped session (PALM_IDENTITY, or `accounts switch`) shows only what that
// identity can see — enforced by the database, not by the window.
package main

import "core:fmt"
import "core:os"
import kit "kit:."

main :: proc() {
	argv := rewrite_argv(os.args[1:])
	if len(argv) >= 1 && argv[0] == "shots" {
		dir := len(argv) >= 2 ? argv[1] : "apps/forge/shots"
		dark := false
		for a in argv {
			if a == "--dark" {
				dark = true
			}
		}
		n := shots(dir, dark)
		fmt.printfln("forge: wrote %d screenshot(s) to %s", n, dir)
		os.exit(0 if n > 0 else 1)
	}
	if code, handled := kit.cli_args(surface(), argv); handled {
		os.exit(code)
	}
	gui_main()
}
