package main

// `launcher --shots <dir>`: render the launcher offscreen and write PNGs.
//
// The entries are not the machine's. A directory of fabricated `.desktop`
// files is written first and parsed with the app's own parser, so the ranking,
// the categories and the context menu are all the real code paths while the
// names on screen belong to nobody.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SHOT_APPS :: "/tmp/palmy-shot-fixtures/launcher/applications"

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("launcher: could not create %s", dir)
		return 1
	}

	off := p.offscreen_create(
		WIN_W,
		WIN_H,
		1,
		"w-full h-full flex-col bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(false)
	p.set_text_gamma(1.8)
	register_dark_theme()

	st := St {
		apps      = shot_entries(),
		terms     = shot_terms(),
		have_clip = true,
		pinned    = make(map[string]bool),
	}
	if len(st.apps) == 0 {
		fmt.eprintfln("launcher --shots: no fixture entries parsed")
		return 1
	}
	st.pinned["codex-editor.desktop"] = true
	st.hits = make([dynamic]Ranked)
	st.chips = make([dynamic]Chip)
	build_chips(&st)
	refilter(&st)

	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		st.moved = false
		st.started = true
		e := current(st)
		if st.menu && e == nil {
			st.menu = false
		}
		if st.menu && e != nil {
			st.spec = build_menu(st, e)
			st.sub_spec = st.sub != .None ? build_submenu(st, e, st.sub) : nil
			if st.menu_i < 0 {
				st.menu_i = first_selectable(st.spec)
			}
			// A submenu is anchored on the row that opens it, so the
			// selection has to sit there for `place_menu` to find it.
			if st.sub != .None {
				for m, i in st.spec {
					if m.kind == .Sub && m.sub == st.sub {
						st.menu_i = i
						break
					}
				}
			}
		}
		build(ui, st)
		p.offscreen_end(off)
	}

	n := 0
	shot :: proc(off: ^p.Offscreen, dir, name: string, n: ^int) {
		out := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}

	// The launcher as it opens: everything indexed, ranked by name.
	st.sel = 0
	step(off, &st)
	step(off, &st)
	shot(off, dir, "app-launcher", &n)

	// A query, fuzzily matched.
	append(&st.query, "edit"); st.caret = len(st.query)
	refilter(&st)
	st.sel = 0
	step(off, &st)
	step(off, &st)
	shot(off, dir, "02-launcher-query", &n)

	// A category chip.
	clear(&st.query)
	st.caret = 0
	st.chip = chip_index(&st, "Media")
	refilter(&st)
	st.sel = 0
	step(off, &st)
	step(off, &st)
	shot(off, dir, "03-launcher-category", &n)

	// The context menu on the selected entry — the part this launcher is
	// actually built around.
	st.chip = 0
	refilter(&st)
	st.sel = 1
	st.menu = true
	st.menu_i = -1
	step(off, &st)
	step(off, &st)
	shot(off, dir, "04-launcher-menu", &n)

	// And one of its submenus.
	st.sub = .Open_With
	st.sub_i = 1
	step(off, &st)
	step(off, &st)
	shot(off, dir, "05-launcher-submenu", &n)

	fmt.printfln("launcher --shots: %d PNGs in %s", n, dir)
	return 0
}

chip_index :: proc(st: ^St, label: string) -> int {
	for c, i in st.chips {
		if c.label == label {
			return i
		}
	}
	return 0
}

// shot_terms is a fabricated terminal list: `find_terminals` probes the real
// $PATH, and what is installed on the machine is not part of the picture.
shot_terms :: proc() -> []Term {
	out := make([dynamic]Term)
	append(&out, Term{bin = "/usr/bin/foot", name = "foot", a1 = "-e"})
	append(&out, Term{bin = "/usr/bin/alacritty", name = "alacritty", a1 = "-e"})
	append(&out, Term{bin = "/usr/bin/kitty", name = "kitty", a1 = "-e"})
	return out[:]
}

// ---------------------------------------------------------------------------
// The fabricated .desktop directory
// ---------------------------------------------------------------------------

Fixture :: struct {
	file, name, comment, exec, cats, keywords: string,
	actions:                                   string, // extra groups, verbatim
}

FIXTURES := [?]Fixture {
	{
		"aurora-browser.desktop",
		"Aurora Browser",
		"Browse the web",
		"aurora-browser %u",
		"Network;WebBrowser;",
		"internet;web;",
		"[Desktop Action private]\nName=New Private Window\nExec=aurora-browser --private\n\n[Desktop Action window]\nName=New Window\nExec=aurora-browser --new-window\n",
	},
	{
		"codex-editor.desktop",
		"Codex Editor",
		"Edit source code",
		"codex %F",
		"Development;IDE;TextEditor;",
		"code;programming;",
		"[Desktop Action empty]\nName=New Empty Window\nExec=codex --new-window\n",
	},
	{"tessera.desktop", "Tessera", "Tiled image viewer", "tessera %F", "Graphics;Viewer;", "image;photo;", ""},
	{"lumen-player.desktop", "Lumen Player", "Play music and video", "lumen %U", "AudioVideo;Player;", "music;video;", ""},
	{"waveform.desktop", "Waveform", "Record and edit audio", "waveform", "AudioVideo;Audio;", "sound;record;", ""},
	{"ledger-sheet.desktop", "Ledger Sheet", "Spreadsheets and figures", "ledger-sheet %F", "Office;Spreadsheet;", "numbers;", ""},
	{"quill.desktop", "Quill", "Write and format documents", "quill %F", "Office;WordProcessor;", "write;text;", ""},
	{"postbox.desktop", "Postbox", "Read and send mail", "postbox", "Office;Email;Network;", "mail;", ""},
	{"atlas-maps.desktop", "Atlas Maps", "Look up places and routes", "atlas", "Network;Maps;", "map;travel;", ""},
	{"foundry.desktop", "Foundry", "Build and package projects", "foundry", "Development;Building;", "compile;make;", ""},
	{"shellward.desktop", "Shellward", "A terminal emulator", "shellward", "System;TerminalEmulator;", "console;shell;", ""},
	{"sentinel.desktop", "Sentinel", "Watch processes and load", "sentinel", "System;Monitor;", "process;top;", ""},
	{"keyring.desktop", "Keyring", "Store passwords safely", "keyring", "Utility;Security;", "password;vault;", ""},
	{"abacus.desktop", "Abacus", "A desk calculator", "abacus", "Utility;Calculator;", "maths;", ""},
	{"chronicle.desktop", "Chronicle", "Keep a journal", "chronicle", "Utility;TextEditor;", "notes;diary;", ""},
	{"palette-studio.desktop", "Palette Studio", "Draw and paint", "palette-studio %F", "Graphics;RasterGraphics;", "draw;art;", ""},
	{"ember-chat.desktop", "Ember Chat", "Talk to other people", "ember", "Network;InstantMessaging;", "chat;message;", ""},
	{"voyage-settings.desktop", "Voyage Settings", "Configure the desktop", "voyage-settings", "Settings;System;", "preferences;", ""},
	{"caverns.desktop", "Caverns", "A tile-crawling adventure", "caverns", "Game;AdventureGame;", "roguelike;", ""},
	{"orbit-racer.desktop", "Orbit Racer", "Race around a ring world", "orbit-racer", "Game;ArcadeGame;", "racing;", ""},
	{"archivist.desktop", "Archivist", "Open and make archives", "archivist %F", "Utility;Archiving;", "zip;tar;", ""},
	{"transit.desktop", "Transit", "Copy files between machines", "transit", "Network;FileTransfer;", "sftp;sync;", ""},
}

shot_entries :: proc() -> []Entry {
	if err := os.make_directory_all(SHOT_APPS, os.perm(0o700));
	   err != nil && !os.exists(SHOT_APPS) {
		fmt.eprintfln("launcher: could not create %s", SHOT_APPS)
		return nil
	}

	entries := make([dynamic]Entry)
	uses := [?]int{0, 41, 3, 17, 0, 6, 11, 28, 2, 9, 34, 1, 7, 13, 0, 4, 19, 0, 2, 0, 5, 0}
	for fx, i in FIXTURES {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "[Desktop Entry]\nType=Application\n")
		fmt.sbprintf(&b, "Name=%s\n", fx.name)
		fmt.sbprintf(&b, "Comment=%s\n", fx.comment)
		fmt.sbprintf(&b, "Exec=%s\n", fx.exec)
		fmt.sbprintf(&b, "Icon=%s\n", fx.file[:len(fx.file) - len(".desktop")])
		fmt.sbprintf(&b, "Categories=%s\n", fx.cats)
		fmt.sbprintf(&b, "Keywords=%s\n", fx.keywords)
		if fx.actions != "" {
			ids := make([dynamic]string, context.temp_allocator)
			rest := fx.actions
			for {
				k := strings.index(rest, "[Desktop Action ")
				if k < 0 {
					break
				}
				rest = rest[k + len("[Desktop Action "):]
				e := strings.index_byte(rest, ']')
				if e < 0 {
					break
				}
				append(&ids, rest[:e])
			}
			fmt.sbprintf(&b, "Actions=%s;\n", strings.join(ids[:], ";", context.temp_allocator))
			strings.write_string(&b, "\n")
			strings.write_string(&b, fx.actions)
		}
		path := fmt.tprintf("%s/%s", SHOT_APPS, fx.file)
		if werr := os.write_entire_file(path, transmute([]u8)strings.to_string(b));
		   werr != nil {
			continue
		}
		e, ok := parse_desktop(strings.clone(path), fx.file)
		if !ok {
			continue
		}
		e.uses = uses[i % len(uses)]
		append(&entries, e)
	}

	out := entries[:]
	slice.sort_by(out, proc(a, b: Entry) -> bool {
		return a.lower < b.lower
	})
	return out
}

// ---------------------------------------------------------------------------
// Fonts, exactly as `kit.start` loads them
// ---------------------------------------------------------------------------

shot_fonts :: proc(fonts: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(fonts, path, .Mono, .Regular) {
			p.load_font(fonts, path, .Mono, .Medium)
			p.load_font(fonts, path, .Mono, .Semibold)
			p.load_font(fonts, path, .Mono, .Bold)
			break
		}
	}
}
