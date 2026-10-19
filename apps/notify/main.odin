// notify: Palmy's notifications. One program, four faces:
//
//	notify daemon                the per-session service (palm-notifyd):
//	                             socket + org.freedesktop.Notifications
//	notify toasts                the toast surface; the daemon starts it
//	notify center                the notification center (also: no arguments)
//	notify send|list|quiet|dnd…  the command line, docs/PALM-CLI.md
//
// The CLI and both surfaces are clients of the daemon over the same socket
// apps use (apps/kit/notify.odin), so there is one implementation of what a
// notification is and what a policy decides: the daemon's.
//
// Build:
//
//	odin build apps/notify -collection:palmy=palmy -collection:kit=apps/kit \
//	    -collection:shadcn=shadcn -out:apps/notify/notify.bin
package main

import "core:os"
import kit "kit:."

main :: proc() {
	args := os.args[1:]
	if len(args) > 0 {
		switch args[0] {
		case "toasts":
			os.exit(toasts_main(args[1:]))
		case "shots":
			os.exit(shots_main(args[1:]))
		}
	}
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	os.exit(center_main(args))
}

@(private = "file")
g_surface: kit.Surface

surface :: proc() -> ^kit.Surface {
	if g_surface.noun == "" {
		g_surface = kit.Surface {
			noun     = "notify",
			summary  = "notifications: one service for the whole system, per identity, under a policy written in words",
			gui      = true,
			selftest = selftest,
			commands = COMMANDS,
			notes    = NOTES,
		}
	}
	return &g_surface
}

NOTES :: `Every notification has a class -- person (someone wrote to you, a call),
time (an event, a reminder, an alarm), machine (receipts, CI, sync) -- and an
identity. Each identity has a policy written as a sentence:

  notify quiet set --identity work "after 18:00"
  notify quiet add --identity work "daily digest at 17:00. calls break through"

A quiet identity's notifications go to its digest, released when quiet ends;
machines never interrupt; a call breaks through only when the policy says so.
The same key is delivered once, from whichever app sends it.

The daemon is "notify daemon" (palm-notifyd), started per session from
/etc/palm/session.d/60-notify. Exit code 6 means it is not running.`
