// welcome — Palmframe's first run: the steps between the installer's last
// page and an ordinary desktop.
//
//	welcome                    open the window (as `welcome run`)
//	welcome run --first-login  open it only if it was never finished: what
//	                           /etc/palm/session.d/90-welcome runs at login
//	welcome status --json      finished or not, and what was chosen
//	welcome reset --yes        forget that it was finished (nothing else)
//	welcome setup ...          the whole flow without a window, for tests
//	welcome shots DIR          every step, offscreen, light and dark
//
// The steps, each skippable except the first and the last:
//
//	 1 Welcome     the language and the appearance, confirmed or changed
//	 2 Account     with a Palmframe account, or only on this computer
//	 3 Sign in     create the account, or sign in; the server is a setting
//	 4 Identities  the first identities: names, handles, kinds, colours
//	 5 Sync        per identity: mail, drive, calendar & contacts, notes,
//	               passwords, chat
//	 6 Passwords   the vault: master password, Secret Key, Emergency Kit
//	 7 Set up      each chosen service set up by its own program, per identity
//	 8 Import      from Google or Microsoft: coming
//	 9 Tour        the start menu, the identity switcher, the keys
//	10 Done
//
// Steps 3 to 7 exist only with an account. Using Palmframe on this computer
// alone is a first-class choice, not a lesser one: every app works without
// the cloud, and the account can be added later by running this again.
//
// Files: model.odin (steps, choices, the files written), core.odin (the
// actions), flow.odin (Next, Back, Skip), worker.odin (the background job),
// ui.odin (the frame), pages.odin (the pages), cli.odin, shot.odin,
// kitpage.odin (the Emergency Kit), selftest.odin.
package main

import "core:fmt"
import "core:os"
import "core:time"
import kit "kit:."
import p "palmy:."

main :: proc() {
	i18n_start()
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}
	os.exit(run_window({spawn = true}))
}

run_window :: proc(opts: Options, lang := "", theme := "") -> int {
	if opts.first_login && read_marker().done {
		return 0
	}
	if lang != "" {
		set_language(lang)
	}
	st := new(St)
	st_init(st, opts)
	switch theme {
	case "dark":
		st.dark = true
	case "light":
		st.dark = false
	}
	open_store(st)

	app, err := kit.start(
		{
			title = "Welcome to Palmframe",
			app_id = "palm-welcome",
			width = 1200,
			height = 780,
			min_width = 960,
			min_height = 640,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("welcome: %s", err)
		return 1
	}
	defer p.destroy(app)
	register_theme(st.dark)

	for ui in p.frames(app) {
		if st.finished {
			break
		}
		draw(st, ui)
		if st.job.running {
			p.wake_after(ui, 100 * time.Millisecond)
		}
	}
	if st.job.running {
		wait_job(st)
	}
	return 0
}
