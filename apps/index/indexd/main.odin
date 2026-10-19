// palm-indexd — the per-person indexer daemon. The same loop as
// `index daemon`, as its own binary so a session can start it by name.
//
//	palm-indexd [--verbose] [--once]
//
// Scope: with $PALM_IDENTITY set it indexes that identity only.
package main

import "core:os"
import feed "../feed"

main :: proc() {
	once, verbose := false, false
	for a in os.args[1:] {
		switch a {
		case "--once":
			once = true
		case "--verbose", "-v":
			verbose = true
		}
	}
	os.exit(feed.daemon_main(os.get_env("PALM_IDENTITY", context.temp_allocator), once, verbose))
}
