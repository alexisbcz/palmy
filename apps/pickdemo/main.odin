// pickdemo — the file picker in kit, driven on its own.
//
// Four buttons, one for each mode, and whatever the dialog last handed back.
// It exists so the component can be exercised and recorded without dragging a
// whole application in behind it, and so `--selftest` has somewhere to live.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Demo :: struct {
	pick:    kit.Pick,
	picked:  [dynamic]string,
	label:   string,
	hint:    string,
	start:   string, // where the dialogs open; `pickdemo <dir>` sets it
	cancels: int,
}

FILTERS_OPEN := [?]kit.Pick_Filter{kit.PICK_ALL, kit.PICK_IMAGES, kit.PICK_TEXT, kit.PICK_ARCHIVES}
FILTERS_SAVE := [?]kit.Pick_Filter{kit.PICK_IMAGES, kit.PICK_TEXT, kit.PICK_ALL}

main :: proc() {
	start := ""
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" {
			selftest()
			return
		}
		// `pickdemo --shots <dir>` renders the dialog offscreen instead of
		// opening a window. See shot.odin.
		if a == "--shots" || a == "-shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("pickdemo: --shots needs a directory")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
		// `pickdemo <dir>` opens the dialogs there instead of the home
		// directory, which is what the recorded demo uses so that the video
		// shows a known tree rather than whatever is on this machine.
		if !strings.has_prefix(a, "-") && start == "" {
			start = a
		}
	}

	app, err := kit.start(
		{
			title = "File Picker",
			width = 1100,
			height = 720,
			min_width = 760,
			min_height = 480,
			root_class = "w-full h-full bg-background text-foreground",
		},
	)
	if err != "" {
		fmt.eprintfln("pickdemo: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	d := Demo{}
	d.start = strings.clone(start)
	d.label = strings.clone("Nothing chosen yet")
	d.hint = strings.clone("Ctrl O to open, Ctrl S to save, Ctrl D for a folder")
	defer kit.pick_destroy(&d.pick)

	for ui in p.frames(app) {
		if kit.pick_active(&d.pick) {
			if res, done := kit.pick_draw(ui, &d.pick); done {
				take(&d, res)
			}
			body(ui, &d)
			continue
		}

		// The host application's own shortcuts, which only run while the
		// dialog is down.
		if p.shortcut(ui, 'q', {.Ctrl}) {
			p.quit_app(app)
		}
		if p.shortcut(ui, 'o', {.Ctrl}) || p.key_pressed(ui, p.KEY_F1, false) {
			open_one(&d)
		}
		if p.shortcut(ui, 'o', {.Ctrl, .Shift}) || p.key_pressed(ui, p.KEY_F2, false) {
			open_many(&d)
		}
		if p.shortcut(ui, 'd', {.Ctrl}) || p.key_pressed(ui, p.KEY_F3, false) {
			open_folder(&d)
		}
		if p.shortcut(ui, 's', {.Ctrl}) || p.key_pressed(ui, p.KEY_F4, false) {
			save_as(&d)
		}
		body(ui, &d)
	}
}

open_one :: proc(d: ^Demo) {
	kit.pick_begin(&d.pick, .Open_File, {dir = d.start, filters = FILTERS_OPEN[:]})
}

open_many :: proc(d: ^Demo) {
	kit.pick_begin(&d.pick, .Open_Files, {dir = d.start, filters = FILTERS_OPEN[:]})
}

open_folder :: proc(d: ^Demo) {
	kit.pick_begin(&d.pick, .Open_Folder, {dir = d.start})
}

save_as :: proc(d: ^Demo) {
	kit.pick_begin(
		&d.pick,
		.Save_File,
		{
			dir = d.start,
			name = "untitled.png",
			filters = FILTERS_SAVE[:],
			confirm = "Save",
		},
	)
}

take :: proc(d: ^Demo, res: kit.Pick_Result) {
	defer kit.pick_result_free(res)
	delete(d.label)
	if !res.ok {
		d.cancels += 1
		d.label = strings.clone("Cancelled")
		return
	}
	for s in d.picked {
		delete(s)
	}
	clear(&d.picked)
	for s in res.paths {
		append(&d.picked, strings.clone(s))
	}
	d.label = strings.clone(
		len(res.paths) == 1 \
		? res.path \
		: fmt.tprintf("%d files, starting with %s", len(res.paths), res.path),
	)
}

// ---------------------------------------------------------------------------
// The host application behind the dialog
// ---------------------------------------------------------------------------

body :: proc(ui: ^p.Ctx, d: ^Demo) {
	p.col(ui, "w-full h-full items-center justify-center gap-5 px-10 relative")
	defer p.end(ui)

	p.col(ui, "items-center gap-1.5 shrink-0")
	p.div(ui, "flex-row size-12 items-center justify-center rounded-2xl bg-primary/12 shrink-0")
	p.icon(ui, kit.ICON_FOLDER_OPEN, "size-6 text-primary")
	p.end(ui)
	p.text(ui, "File Picker", "text-[22] font-semibold")
	p.text(ui, "A shared open and save dialog for palmy", "text-[13] text-muted-foreground")
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	if demo_button(ui, "b1", "Open File", "F1") {
		open_one(d)
	}
	if demo_button(ui, "b2", "Open Files", "F2") {
		open_many(d)
	}
	if demo_button(ui, "b3", "Choose Folder", "F3") {
		open_folder(d)
	}
	if demo_button(ui, "b4", "Save As", "F4") {
		save_as(d)
	}
	p.end(ui)

	p.col(ui, "w-[620] max-w-full shrink-0 gap-2 p-4 rounded-xl border border-border bg-card")
	p.text(ui, "Result", "text-[11] font-semibold text-muted-foreground tracking-wide")
	p.text(ui, d.label, "w-full truncate text-[13] font-medium")
	if len(d.picked) > 1 {
		for s, i in d.picked {
			if i >= 6 {
				p.text(
					ui,
					fmt.tprintf("and %d more", len(d.picked) - 6),
					"text-[12] text-muted-foreground",
				)
				break
			}
			p.text(ui, s, "w-full truncate text-[12] text-muted-foreground")
		}
	}
	p.end(ui)

	p.text(ui, d.hint, "text-[12] text-muted-foreground/80 shrink-0")
}

demo_button :: proc(ui: ^p.Ctx, key, label, hot: string) -> bool {
	p.key(ui, key)
	idx := sc.button_open(ui, .Outline, .Default, sc.State{})
	p.apply(ui, "shrink-0 px-3 gap-2", idx)
	if p.is_hovered(ui, idx) {
		p.apply(ui, sc.button_variant_class(.Outline, sc.State{hover = true}), idx)
	}
	fired := p.clickable(ui, idx)
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, hot)
	sc.button_end(ui)
	return fired
}
