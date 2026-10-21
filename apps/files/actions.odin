// What the browser does to files: New Folder, Rename…, Duplicate, Move to
// Trash. Each is a thin step over the core (fs.odin) — the same procedure the
// command line runs — plus what a window owes the person afterwards: a toast,
// a reload, and the selection left on the thing that changed.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

Ask :: enum u8 {
	None,
	Rename,
	New_Folder,
}

// select_name puts the selection on `name` in the current listing, if shown.
select_name :: proc(st: ^State, name: string) {
	for v, i in st.vis {
		if st.entries[v].name == name {
			st.sel = i
			ensure_visible(st)
			return
		}
	}
}

// act_new_folder makes "untitled folder" here and asks for its name at once,
// which is Finder's New Folder: the folder exists before you have named it.
act_new_folder :: proc(st: ^State) {
	made, fail, why := fs_new_folder(st.cwd)
	if fail != .None {
		note(st, fmt.tprintf("No new folder: %s", why))
		return
	}
	name := strings.clone(base_of(made), context.temp_allocator)
	reload(st)
	select_name(st, name)
	ask_open(st, .New_Folder, made)
}

act_rename :: proc(st: ^State) {
	if e, ok := selected(st); ok {
		ask_open(st, .Rename, e.path)
	}
}

act_duplicate :: proc(st: ^State) {
	e, ok := selected(st)
	if !ok {
		return
	}
	made, fail, why := fs_duplicate(e.path)
	if fail != .None {
		note(st, fmt.tprintf("Not duplicated: %s", why))
		return
	}
	name := strings.clone(base_of(made), context.temp_allocator)
	reload(st)
	select_name(st, name)
	note(st, fmt.tprintf("Duplicated as %s", name))
}

// act_trash moves the selection to the freedesktop trash. The selection stays
// on the row that took its place, so Delete pressed twice trashes two things.
act_trash :: proc(st: ^State) {
	e, ok := selected(st)
	if !ok {
		return
	}
	name := strings.clone(e.name, context.temp_allocator)
	_, fail, why := fs_trash(e.path, "", st.tz_offset)
	if fail != .None {
		note(st, fmt.tprintf("Not moved to the trash: %s", why))
		return
	}
	keep := st.sel
	load_dir(st, st.cwd)
	st.sel = clamp(keep, 0, max(0, len(st.vis) - 1))
	ensure_visible(st)
	note(st, fmt.tprintf("Moved %s to the trash", name))
}

// ---------------------------------------------------------------------------
// The name prompt
// ---------------------------------------------------------------------------

ask_open :: proc(st: ^State, kind: Ask, path: string) {
	if st.ask_path != "" {
		delete(st.ask_path)
	}
	st.ask = kind
	st.ask_path = strings.clone(path)
	clear(&st.ask_text)
	append(&st.ask_text, ..transmute([]u8)base_of(path))
	// A new folder's name is a placeholder, selected the way Finder selects
	// it, so the first key typed replaces it; a rename edits the name it had.
	st.ask_fresh = kind == .New_Folder
	st.swallow = true
	st.menu_open = false
}

ask_commit :: proc(st: ^State) {
	kind := st.ask
	st.ask = .None
	want := strings.trim_space(string(st.ask_text[:]))
	if want == base_of(st.ask_path) {
		if kind == .New_Folder {
			note(st, fmt.tprintf("Made %s", want))
		}
		return
	}
	made, fail, why := fs_rename(st.ask_path, want)
	if fail != .None {
		note(st, fmt.tprintf("Not renamed: %s", why))
		return
	}
	name := strings.clone(base_of(made), context.temp_allocator)
	reload(st)
	select_name(st, name)
	note(st, kind == .New_Folder ? fmt.tprintf("Made %s", name) : fmt.tprintf("Renamed to %s", name))
}

// ask_keys owns the keyboard while the prompt is open: typed text goes to the
// name, Enter commits, Escape keeps the name it had.
ask_keys :: proc(ui: ^p.Ctx, st: ^State) {
	if plain(ui, p.KEY_ESCAPE) {
		if st.ask == .New_Folder {
			note(st, fmt.tprintf("Made %s", base_of(st.ask_path)))
		}
		st.ask = .None
		return
	}
	if plain(ui, p.KEY_RETURN) {
		ask_commit(st)
		return
	}
	typed := st.swallow ? "" : p.typed_text(ui)
	st.swallow = false
	if st.ask_fresh && (len(typed) > 0 || key_times(ui, p.KEY_BACKSPACE) > 0) {
		clear(&st.ask_text)
		st.ask_fresh = false
	}
	for _ in 0 ..< key_times(ui, p.KEY_BACKSPACE) {
		n := 1
		for n < len(st.ask_text) && st.ask_text[len(st.ask_text) - n] & 0xc0 == 0x80 {
			n += 1
		}
		resize(&st.ask_text, max(0, len(st.ask_text) - n))
	}
	if p.shortcut(ui, 'u', {.Ctrl}) {
		clear(&st.ask_text)
	}
	for b in transmute([]u8)typed {
		if b >= 0x20 && b != '/' {
			append(&st.ask_text, b)
		}
	}
}

ask_dialog :: proc(ui: ^p.Ctx, st: ^State) {
	scrim := p.div(ui, "absolute inset-0 z-40 bg-black/40 items-center justify-center")
	if p.clickable(ui, scrim) {
		st.ask = .None
	}
	defer p.end(ui)
	p.col(ui, "w-[420] p-5 gap-3 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)
	title := st.ask == .New_Folder ? "Name the new folder" : fmt.tprintf("Rename %s", base_of(st.ask_path))
	p.text(ui, title, "text-[15] font-semibold text-foreground truncate")
	p.text(ui, fmt.tprintf("In %s", parent_of(st.ask_path)), "text-[12.5] text-muted-foreground truncate")
	p.row(ui, "h-9 w-full items-center px-3 rounded-lg border border-ring ring-3 ring-ring/40 bg-background")
	if st.ask_fresh {
		p.text(ui, string(st.ask_text[:]), "text-[13] text-foreground bg-selection/25 rounded-sm")
	} else {
		p.text(ui, string(st.ask_text[:]), "text-[13] text-foreground")
		p.div(ui, "w-[2] h-[16] bg-primary")
		p.end(ui)
	}
	p.end(ui)
	p.text(ui, "Enter to rename · Esc to keep the name", "text-[11.5] text-muted-foreground")
}
