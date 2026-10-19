// Drive — one Palmy account's files, one identity at a time.
//
// The window is the cloud view of an identity's drive: browse, preview with
// the system's own apps, share with another identity, trash and restore,
// search, see the quota. The folder on disk (~/Drive/<handle>) is kept in step
// by palm-drive (cloud/drive/palm-drive); this app and that daemon share one
// core, cloud/drive/core.
//
// Every request goes out with a token scoped to the identity on screen, so the
// separation between identities is the database's, not this window's.
package main

import "core:fmt"
import "core:os"
import "core:time"
import dc "drive:core"
import kit "kit:."
import p "palmy:."

main :: proc() {
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	cfg, err := dc.load_config(dc.config_path())
	if err != "" {
		fmt.eprintfln("drive: %s", err)
		fmt.eprintln("drive: run cloud/drive/dev/seed.sh to create a development configuration")
		os.exit(kit.EXIT_UNAVAILABLE)
	}
	if len(cfg.identities) == 0 {
		fmt.eprintln("drive: the configuration has no [identity]")
		os.exit(kit.EXIT_UNAVAILABLE)
	}

	app, aerr := kit.start({title = "Drive", width = 1240, height = 780, min_width = 900, min_height = 520, app_id = "palm-drive"})
	if aerr != "" {
		fmt.eprintfln("drive: %s", aerr)
		os.exit(1)
	}
	defer p.destroy(app)

	st := new(State)
	st.cfg = cfg
	st.view = .List
	st.inspector = true
	st.now = time.now()
	start := 0
	if want := kit.cli_scope(); want != "" {
		// Started inside an identity's scope: that identity, and no other.
		start = -1
		for id, i in cfg.identities {
			if id.handle == want {
				start = i
			}
		}
		if start < 0 {
			fmt.eprintfln("drive: no identity %q in %s", want, cfg.path)
			os.exit(kit.EXIT_OUT_OF_SCOPE)
		}
	}
	select_identity(st, start)
	st.locked = kit.cli_scope() != ""

	for ui in p.frames(app) {
		measure(ui, st)
		handle_keys(ui, st, app)
		frame(ui, st)
		if kit.pick_active(&st.pick) {
			if res, done := kit.pick_draw(ui, &st.pick); done {
				if res.ok {
					upload_paths(st, res.paths)
				}
				kit.pick_result_free(res)
			}
		}
	}
}
