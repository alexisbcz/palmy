// A small but complete application: text entry, a keyed list, filtering,
// scrolling and persistence of per-item widget state across reorders.
package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import p "../../palmy"

Task :: struct {
	id:   int,
	text: string,
	done: bool,
}

Filter :: enum {
	All,
	Active,
	Done,
}

App_State :: struct {
	tasks:  [dynamic]Task,
	draft:  [dynamic]u8,
	filter: Filter,
	next:   int,
}

main :: proc() {
	app, err := p.create({title = "palmy · todo", width = 520, height = 620, min_width = 360})
	if err != "" {
		fmt.eprintfln("palmy: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	st: App_State
	defer {
		for t in st.tasks {
			delete(t.text)
		}
		delete(st.tasks)
		delete(st.draft)
	}

	add(&st, "Draw pixels on Wayland")
	add(&st, "Lay them out like CSS")
	add(&st, "Name the classes like Tailwind")
	st.tasks[0].done = true

	for ui in p.frames(app) {
		build(ui, &st)
	}
}

add :: proc(st: ^App_State, text: string) {
	trimmed := strings.trim_space(text)
	if trimmed == "" {
		return
	}
	st.next += 1
	append(&st.tasks, Task{id = st.next, text = strings.clone(trimmed), done = false})
}

build :: proc(ui: ^p.Ctx, st: ^App_State) {
	p.col(ui, "w-full h-full bg-slate-950 items-center")
	defer p.end(ui)

	p.col(ui, "w-full max-w-[460] h-full px-6 py-8 gap-5")
	defer p.end(ui)

	// Title.
	p.row(ui, "items-baseline gap-3 shrink-0")
	{
		defer p.end(ui)
		p.text(ui, "Today", "text-3xl font-bold text-white tracking-tight")
		p.spacer(ui)
		left := 0
		for t in st.tasks {
			if !t.done {
				left += 1
			}
		}
		p.textf(ui, "text-sm text-slate-500", "%d left", left)
	}

	// New task.
	p.row(ui, "gap-2 shrink-0")
	{
		defer p.end(ui)
		_, submitted := p.text_field(ui, &st.draft, "What needs doing?", "flex-1")
		pressed := p.button(ui, "Add", "bg-indigo-500 hover:bg-indigo-400 border-indigo-400 text-white")
		if submitted || pressed {
			add(st, string(st.draft[:]))
			clear(&st.draft)
		}
	}

	// Filters.
	p.row(ui, "gap-1 shrink-0")
	{
		defer p.end(ui)
		for f in Filter {
			p.key(ui, fmt.tprintf("filter-%v", f))
			class := "px-3 py-1.5 rounded-full text-xs font-semibold transition text-slate-500 hover:text-slate-200"
			if st.filter == f {
				class = "px-3 py-1.5 rounded-full text-xs font-semibold transition bg-slate-800 text-white"
			}
			p.div(ui, class)
			if p.clickable(ui) {
				st.filter = f
			}
			p.textf(ui, "", "%v", f)
			p.end(ui)
		}
	}

	// The list.
	p.col(ui, "flex-1 gap-2 overflow-scroll")
	{
		defer p.end(ui)

		remove_at := -1
		shown := 0
		for &t, i in st.tasks {
			switch st.filter {
			case .Active:
				if t.done {continue}
			case .Done:
				if !t.done {continue}
			case .All:
			}
			shown += 1

			// Keying by the task id means state follows the task, not the row.
			p.key(ui, fmt.tprintf("task-%d", t.id))
			p.row(ui, "items-center gap-3 px-4 py-3 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 transition shrink-0")
			defer p.end(ui)

			p.checkbox(ui, "", &t.done)

			class := "flex-1 text-sm text-slate-100"
			if t.done {
				class = "flex-1 text-sm text-slate-500 line-through"
			}
			p.text(ui, t.text, class)

			p.div(ui, "size-7 rounded-lg items-center justify-center hover:bg-rose-500/20 transition")
			if p.clickable(ui) {
				remove_at = i
			}
			p.text(ui, "×", "text-slate-500 text-lg")
			p.end(ui)
		}

		if shown == 0 {
			p.col(ui, "flex-1 items-center justify-center gap-2")
			defer p.end(ui)
			p.text(ui, "Nothing here", "text-sm text-slate-600")
		}

		if remove_at >= 0 {
			delete(st.tasks[remove_at].text)
			ordered_remove(&st.tasks, remove_at)
		}
	}

	// Footer.
	p.row(ui, "items-center gap-3 shrink-0 pt-1")
	{
		defer p.end(ui)
		p.textf(ui, "text-xs text-slate-600", "%d tasks", len(st.tasks))
		p.spacer(ui)
		any_done := slice.any_of_proc(st.tasks[:], proc(t: Task) -> bool {return t.done})
		if p.button(ui, "Clear done", "bg-transparent border-transparent text-slate-500 hover:text-rose-300 text-xs", !any_done) {
			for i := len(st.tasks) - 1; i >= 0; i -= 1 {
				if st.tasks[i].done {
					delete(st.tasks[i].text)
					ordered_remove(&st.tasks, i)
				}
			}
		}
	}
}
