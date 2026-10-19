package appindex

import "core:fmt"
import "core:os"
import "core:strings"

// selftest checks the index, the matcher and the user state against
// fixtures, writing only under a temporary directory it makes and removes.
// Both front ends run it: `launcher --selftest`, and wm --selftest.
selftest :: proc() -> (pass, fail: int) {
	check :: proc(pass, fail: ^int, ok: bool, what: string) {
		if ok {
			pass^ += 1
		} else {
			fail^ += 1
			fmt.eprintfln("appindex: FAIL %s", what)
		}
	}

	// --- parsing ---------------------------------------------------------
	files, ok := parse_desktop_text(
		"[Desktop Entry]\nType=Application\nName=Files\nName[fr]=Fichiers\nComment=Browse your folders\n" +
		"Exec=files %U\nIcon=folder\nCategories=System;FileManager;\nMimeType=inode/directory;\n" +
		"Actions=new;\n[Desktop Action new]\nName=New Window\nExec=files --new\n",
		"/x/files.desktop",
		"files.desktop",
		context.temp_allocator,
	)
	check(&pass, &fail, ok && files.name == "Files", "a plain entry parses and the localised name is skipped")
	check(&pass, &fail, files.exec == "files" && files.takes_file, "field codes are stripped and remembered")
	check(&pass, &fail, files.cat == .System && len(files.actions) == 1, "category and actions")
	check(&pass, &fail, exec_name(&files) == "files", "exec_name is the program")
	argv := exec_with_file(&files, "/home/palm/Documents", context.temp_allocator)
	check(&pass, &fail, len(argv) == 2 && argv[0] == "files" && argv[1] == "/home/palm/Documents", "exec_with_file puts the path where %U was")

	_, hidden := parse_desktop_text("[Desktop Entry]\nType=Application\nName=X\nExec=x\nNoDisplay=true\n", "/x/x.desktop", "x.desktop", context.temp_allocator)
	check(&pass, &fail, !hidden, "NoDisplay entries are left out")
	_, link := parse_desktop_text("[Desktop Entry]\nType=Link\nName=X\nURL=http://x\n", "/x/l.desktop", "l.desktop", context.temp_allocator)
	check(&pass, &fail, !link, "a Link is not an application")
	demo, _ := parse_desktop_text("[Desktop Entry]\nType=Application\nName=Shop\nExec=shop\nCategories=Network;\nX-Palmy-Demo=true\n", "/x/shop.desktop", "shop.desktop", context.temp_allocator)
	check(&pass, &fail, demo.demo && demo.cat == .Demo, "X-Palmy-Demo puts an entry with the demos")

	term, _ := parse_desktop_text("[Desktop Entry]\nType=Application\nName=Terminal\nExec=term\nIcon=square-terminal\nCategories=System;TerminalEmulator;\n", "/x/term.desktop", "term.desktop", context.temp_allocator)
	htop, _ := parse_desktop_text("[Desktop Entry]\nType=Application\nName=Top\nExec=term -e top\nCategories=System;\n", "/x/top.desktop", "top.desktop", context.temp_allocator)
	editor, _ := parse_desktop_text("[Desktop Entry]\nType=Application\nName=Text Editor\nExec=editor %f\nMimeType=text/plain;text/markdown;\nCategories=Development;TextEditor;\n", "/x/editor.desktop", "editor.desktop", context.temp_allocator)
	entries := []Entry{htop, term, files, editor}
	check(&pass, &fail, find_program(entries, "/usr/bin/term") == 1, "find_program prefers the bare entry")
	check(&pass, &fail, find_id(entries, "editor") == 3 && find_id(entries, "editor.desktop") == 3, "find_id with and without the suffix")
	check(&pass, &fail, opener_for(entries, "/home/palm/notes.md") == 3, "a .md file opens in the editor")
	check(&pass, &fail, opener_for(entries, "/home/palm/x.unknown") == -1, "an unknown type has no opener")

	ic := icon_for(&term)
	check(&pass, &fail, ic.name == "square-terminal", "Icon= names the lucide glyph")

	// --- ranking -----------------------------------------------------------
	r1, ok1 := rank_entry(&entries[3], "tex")
	r2, ok2 := rank_entry(&entries[1], "tex")
	check(&pass, &fail, ok1 && (!ok2 || r1.score > r2.score), "a prefix match ranks first")
	_, ok3 := rank_entry(&entries[3], "te")
	check(&pass, &fail, ok3, "an acronym or prefix still matches")

	// --- usage and pins, in a scratch home ---------------------------------
	lines := parse_usage("3 term.desktop 1700000000\n1 files.desktop\nbad line\n")
	check(&pass, &fail, len(lines) == 2 && lines[0].last == 1700000000 && lines[1].last == 0, "usage lines with and without a time")

	tmp := fmt.tprintf("/tmp/appindex-selftest-%d", os.get_pid())
	_ = os.make_directory_all(tmp)
	defer os.remove_all(tmp)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	old_cfg := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", tmp)
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/.config", tmp))
	defer {
		os.set_env("HOME", old_home)
		if old_cfg == "" {
			os.unset_env("XDG_CONFIG_HOME")
		} else {
			os.set_env("XDG_CONFIG_HOME", old_cfg)
		}
	}

	defs := pins_or_default(.Start, entries, context.temp_allocator)
	check(&pass, &fail, len(defs) == 3 && defs[0] == "term.desktop", "the default pins are the installed ones, in order")
	pins, saved := load_pins(.Start, context.temp_allocator)
	check(&pass, &fail, !saved, "no pins file means no saved list")
	check(&pass, &fail, toggle_pin(.Start, &pins, "editor.desktop", context.temp_allocator), "pinning adds")
	toggle_pin(.Start, &pins, "files.desktop", context.temp_allocator)
	again, saved2 := load_pins(.Start, context.temp_allocator)
	check(&pass, &fail, saved2 && len(again) == 2 && again[0] == "editor.desktop", "pins persist in order")
	check(&pass, &fail, !toggle_pin(.Start, &again, "editor.desktop", context.temp_allocator), "pinning twice unpins")
	bar, _ := load_pins(.Bar, context.temp_allocator)
	check(&pass, &fail, len(bar) == 0, "the bar's pins are a list of their own")

	note_launch(entries, 2)
	entries[2].uses = 0
	entries[2].last = 0
	load_usage(entries)
	check(&pass, &fail, entries[2].uses == 1 && entries[2].last > 0, "a launch is recorded with its time")
	rec := recent_apps(entries, 5)
	check(&pass, &fail, len(rec) == 1 && rec[0] == 2, "recent apps are the launched ones")

	_ = os.make_directory_all(fmt.tprintf("%s/Documents", tmp))
	_ = os.write_entire_file(fmt.tprintf("%s/Documents/report.md", tmp), transmute([]byte)string("# hi\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/.hidden", tmp), transmute([]byte)string("x"))
	rf := recent_files(5, context.temp_allocator)
	check(&pass, &fail, len(rf) == 1 && rf[0].name == "report.md", "recent files skip hidden ones")
	return
}
