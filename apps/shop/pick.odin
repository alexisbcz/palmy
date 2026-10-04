// Opening a real product feed, through the shared file dialog in `kit`.
//
// This is the only path by which this program reads a file it was not given on
// the command line, and it reads exactly the one file the user picked. It does
// not walk the home directory, index anything, or remember what it saw.
package main

import "core:fmt"
import kit "kit:."
import p "palmy:."

// The formats the importer actually reads. "All files" stays, because an
// affiliate network will hand you a feed called `export` with no extension at
// all and the parser sniffs the first character anyway.
FEED_FILTERS := [?]kit.Pick_Filter {
	{"Flux produits", {"xml", "rss", "csv", "tsv", "txt"}},
	{"Google Merchant (RSS)", {"xml", "rss"}},
	{"CSV / TSV", {"csv", "tsv"}},
	kit.PICK_ALL,
}

begin_pick :: proc(st: ^State) {
	kit.pick_begin(
		&st.pick,
		.Open_File,
		{
			title = "Ouvrir un flux produits",
			confirm = "Importer",
			dir = st.data_dir,
			filters = FEED_FILTERS[:],
		},
	)
}

pick_active :: proc(st: ^State) -> bool {
	return kit.pick_active(&st.pick)
}

// pick_overlay is drawn after the rest of the window, so the dialog is a
// sibling at the top level and its absolute insets resolve against the window.
pick_overlay :: proc(ui: ^p.Ctx, st: ^State) {
	if !kit.pick_active(&st.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &st.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	if !res.ok {
		return
	}
	import_path(st, res.path)
	st.view = .Import
	toast_now(st, fmt.tprintf("%s", st.import_msg))
}
