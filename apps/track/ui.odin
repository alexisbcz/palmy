// The window.
//
// Four views over the same store, and nothing in here reads anything the CLI
// cannot: `frame` draws what `store_open` and `graph_build` returned, which
// is the whole of why the two front ends cannot drift.
//
//   * **Ready** — what is unblocked right now, biggest unblocker first. The
//     headline, and the view the application opens on, because it is the
//     question a tracker is for.
//   * **List** — everything, with its blockers written out.
//   * **Board** — a column per configured state.
//   * **Graph** — the DAG, laid out by dag.odin.
//
// Keyboard-driven throughout. That is not a stylistic preference: the
// headless compositor these demos record on has no pointer capability at all
// (`TODO.md` has the measurement), so an application that needs a mouse
// cannot be recorded, and one that does not can be.
//
// The window never runs a verification. It renders the verdict recorded in
// the file and labels an unrecorded one `unchecked`. There is no key, no
// button and no code path from here to `verify_run`.
package main

import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

HEADER_H :: 50
STATUS_H :: 26
SIDE_W :: 400

View :: enum {
	Ready,
	List,
	Board,
	Graph,
}

view_name :: proc(v: View) -> string {
	switch v {
	case .Ready:
		return "Ready"
	case .List:
		return "List"
	case .Board:
		return "Board"
	case .Graph:
		return "Graph"
	}
	return ""
}

App_State :: struct {
	store:    Store,
	graph:    Graph,
	dag:      Dag,
	dag_ok:   bool,
	view:     View,
	sel:      int, // store index
	show_closed: bool,
	detail:   bool,
	scroll:   [2]f32,
	zoom:     f32,
	identity: string,
	toast:    string,
	toast_at: f32,
	want_quit: bool,
}

app_reload :: proc(a: ^App_State) {
	if a.dag_ok {
		dag_free(&a.dag)
		a.dag_ok = false
	}
	graph_free(&a.graph)
	store_free(&a.store)
	a.store = store_open(a.identity)
	a.graph = graph_build(&a.store)
	app_rebuild_dag(a)
	if a.sel >= len(a.store.issues) {
		a.sel = max(len(a.store.issues) - 1, 0)
	}
}

app_rebuild_dag :: proc(a: ^App_State) {
	if a.dag_ok {
		dag_free(&a.dag)
	}
	vis := make([]bool, len(a.store.issues), context.temp_allocator)
	for i in 0 ..< len(a.store.issues) {
		vis[i] = a.show_closed || !a.graph.closed[i]
	}
	a.dag = dag_build(&a.store, &a.graph, vis)
	a.dag_ok = true
}

// visible_rows is the list the current view scrolls through: the same filter
// in one place, so the selection and what is drawn cannot disagree.
visible_rows :: proc(a: ^App_State, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	switch a.view {
	case .Ready:
		for i in ready_order(&a.store, &a.graph) {
			if a.graph.ready[i] {
				append(&out, i)
			}
		}
	case .List, .Board, .Graph:
		for i in 0 ..< len(a.store.issues) {
			if !a.show_closed && a.graph.closed[i] {
				continue
			}
			append(&out, i)
		}
	}
	return out[:]
}

// select_first puts the selection on the first row the opening view shows,
// so the detail pane is describing something the reader can see rather than
// whichever issue happens to sort first.
select_first :: proc(a: ^App_State) {
	rows := visible_rows(a)
	a.sel = len(rows) > 0 ? rows[0] : -1
}

gui_main :: proc() {
	a := new(App_State)
	a.identity = os.get_env("PALM_IDENTITY", context.temp_allocator)
	a.zoom = 0 // fit to the viewport until somebody pans or zooms
	a.detail = true
	a.store = store_open(a.identity)
	a.graph = graph_build(&a.store)
	app_rebuild_dag(a)
	select_first(a)

	app, err := kit.start({title = "track", width = 1280, height = 820, app_id = "palmy-track"})
	if err != "" {
		os.exit(1)
	}
	defer p.destroy(app)

	for ui in p.frames(app) {
		keys(ui, a)
		frame(ui, a)
		if a.want_quit {
			p.quit_app(app)
		}
	}
}

keys :: proc(ui: ^p.Ctx, a: ^App_State) {
	rows := visible_rows(a)
	move :: proc(a: ^App_State, rows: []int, d: int) {
		at := -1
		for r, i in rows {
			if r == a.sel {
				at = i
			}
		}
		if len(rows) == 0 {
			return
		}
		if at < 0 {
			a.sel = rows[0]
			return
		}
		at = clamp(at + d, 0, len(rows) - 1)
		a.sel = rows[at]
	}

	if p.shortcut(ui, 'j', {}) || p.shortcut(ui, p.KEY_DOWN, {}) {
		move(a, rows, 1)
	}
	if p.shortcut(ui, 'k', {}) || p.shortcut(ui, p.KEY_UP, {}) {
		move(a, rows, -1)
	}
	if p.shortcut(ui, p.KEY_TAB, {}) {
		a.view = View((int(a.view) + 1) % len(View))
	}
	for pair in ([?]struct {
		sym:  u32,
		view: View,
	}{{'1', .Ready}, {'2', .List}, {'3', .Board}, {'4', .Graph}}) {
		if p.shortcut(ui, pair.sym, {}) {
			a.view = pair.view
		}
	}
	if p.shortcut(ui, 'c', {}) {
		a.show_closed = !a.show_closed
		app_rebuild_dag(a)
	}
	if p.shortcut(ui, 'd', {}) {
		a.detail = !a.detail
	}
	if p.shortcut(ui, 'r', {}) {
		app_reload(a)
	}
	if p.shortcut(ui, 'q', {}) || p.shortcut(ui, p.KEY_ESCAPE, {}) {
		a.want_quit = true
	}
	if a.view == .Graph {
		step := f32(60)
		// Panning or zooming by hand leaves fit mode, which is why each of
		// these settles `zoom` to a real number first.
		if p.shortcut(ui, 'h', {}) || p.shortcut(ui, p.KEY_LEFT, {}) {
			a.scroll.x -= step
		}
		if p.shortcut(ui, 'l', {}) || p.shortcut(ui, p.KEY_RIGHT, {}) {
			a.scroll.x += step
		}
		if p.shortcut(ui, '-', {}) {
			a.zoom = max((a.zoom <= 0 ? 1 : a.zoom) - 0.1, 0.4)
		}
		if p.shortcut(ui, '=', {}) {
			a.zoom = min((a.zoom <= 0 ? 1 : a.zoom) + 0.1, 1.6)
		}
		if p.shortcut(ui, '0', {}) {
			a.zoom = 0
			a.scroll = {}
		}
		a.scroll.x = max(a.scroll.x, 0)
		a.scroll.y = max(a.scroll.y, 0)
	}
}

frame :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.col(ui, "w-full h-full bg-background text-foreground overflow-hidden")
	defer p.end(ui)

	header(ui, a)

	p.row(ui, "flex-1 min-h-0 w-full items-stretch")
	p.col(ui, "flex-1 min-w-0 h-full overflow-hidden")
	switch a.view {
	case .Ready:
		ready_view(ui, a)
	case .List:
		list_view(ui, a)
	case .Board:
		board_view(ui, a)
	case .Graph:
		graph_view(ui, a)
	}
	p.end(ui)
	if a.detail {
		detail_pane(ui, a)
	}
	p.end(ui)

	status(ui, a)
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

header :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-3 px-4 bg-sidebar border-b border-border", HEADER_H))
	defer p.end(ui)

	p.col(ui, "gap-px shrink-0 max-w-[240] overflow-hidden")
	p.text(ui, "track", "text-sm font-semibold leading-tight")
	p.text(ui, scope_line(a), "text-[10px] text-muted-foreground leading-tight whitespace-nowrap")
	p.end(ui)

	p.div(ui, "w-6")
	p.end(ui)

	// The view tabs, numbered so the key that selects one is on it.
	p.row(ui, "shrink-0 items-center gap-1 p-1 rounded-lg bg-muted")
	for v, i in View {
		on := a.view == v
		p.row(
			ui,
			tfmt(
				"items-center gap-1.5 px-2.5 py-1 rounded-md %s",
				on ? "bg-background border border-border" : "",
			),
		)
		p.textf(ui, on ? "text-[10px] text-muted-foreground" : "text-[10px] text-muted-foreground/60", "%d", i + 1)
		p.text(ui, view_name(v), on ? "text-xs font-medium" : "text-xs text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	p.spacer(ui)

	// The counts that matter, in the order they matter.
	n_ready, n_open, n_stale, n_unver := 0, 0, 0, 0
	for &it, i in a.store.issues {
		// `ready` and `open` are about work in flight; `stale` and
		// `unchecked` are about whether the file is telling the truth, and a
		// closed issue can lie just as loudly as an open one.
		if it.verify != "" {
			if it.verdict == .Stale {
				n_stale += 1
			} else if it.verdict == .Unverified {
				n_unver += 1
			}
		}
		if a.graph.closed[i] {
			continue
		}
		n_open += 1
		if a.graph.ready[i] {
			n_ready += 1
		}
	}
	pill(ui, tfmt("%d ready", n_ready), "text-emerald-600", "border-emerald-600/30")
	pill(ui, tfmt("%d open", n_open), "text-muted-foreground", "border-border")
	if n_stale > 0 {
		pill(ui, tfmt("%d stale", n_stale), "text-destructive", "border-destructive/40")
	}
	if n_unver > 0 {
		pill(ui, tfmt("%d unchecked", n_unver), "text-amber-600", "border-amber-600/30")
	}
}

pill :: proc(ui: ^p.Ctx, label, fg, border: string) {
	p.row(ui, tfmt("shrink-0 items-center px-2 py-0.5 rounded-full border %s", border))
	p.text(ui, label, tfmt("text-[11px] font-medium %s", fg))
	p.end(ui)
}

// scope_line names the directory in two or three words rather than printing
// a path that pushes everything else out of the header. The whole path is in
// `track where`, which is where a path belongs.
scope_line :: proc(a: ^App_State) -> string {
	s := &a.store.scope
	tail := tail_path(s.dir, 2)
	if s.kind == "repo" {
		root := tail_path(s.root, 1)
		return tfmt("repo · %s", root == "" ? tail : root)
	}
	if s.identity != "" {
		return tfmt("%s · %s", s.identity, tail)
	}
	return tail
}

// tail_path is the last `n` components of a path, with a leading ellipsis if
// anything was dropped.
tail_path :: proc(path: string, n: int) -> string {
	if path == "" {
		return ""
	}
	at := len(path)
	cut := at
	for _ in 0 ..< n {
		sl := strings.last_index_byte(path[:cut], '/')
		if sl <= 0 {
			return path
		}
		cut = sl
	}
	return tfmt("…%s", path[cut:])
}

short_home :: proc(path: string) -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home != "" && strings.has_prefix(path, home) {
		return tfmt("~%s", path[len(home):])
	}
	return path
}

status :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.row(ui, tfmt("h-[%d] shrink-0 w-full items-center gap-4 px-4 bg-sidebar border-t border-border", STATUS_H))
	defer p.end(ui)
	hint :: proc(ui: ^p.Ctx, k, what: string) {
		p.row(ui, "items-center gap-1 shrink-0")
		p.text(ui, k, "text-[10px] font-mono px-1 rounded bg-muted text-muted-foreground whitespace-nowrap")
		p.text(ui, what, "text-[10px] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
	hint(ui, "1-4", "view")
	hint(ui, "j/k", "move")
	hint(ui, "c", a.show_closed ? "hide closed" : "show closed")
	hint(ui, "d", "detail")
	hint(ui, "r", "reload")
	if a.view == .Graph {
		hint(ui, "h/l", "pan")
		hint(ui, "-/=", "zoom")
	}
	p.spacer(ui)
	if a.dag_ok && a.view == .Graph {
		p.textf(ui, "text-[10px] text-muted-foreground shrink-0 whitespace-nowrap", "%d edge crossings", a.dag.crossings)
	}
	if len(a.graph.cycle) > 0 {
		p.textf(ui, "text-[10px] text-destructive font-medium shrink-0 whitespace-nowrap", "cycle: %s", cycle_text(a.graph.cycle))
	}
}

// ---------------------------------------------------------------------------
// The verification badge, which is the same in every view
// ---------------------------------------------------------------------------

verify_badge :: proc(ui: ^p.Ctx, it: ^Issue) {
	if it.verify == "" {
		return
	}
	label, cls: string
	switch it.verdict {
	case .Stale:
		label, cls = "STALE", "bg-destructive text-white"
	case .True:
		label, cls = "true", "bg-emerald-600/15 text-emerald-700"
	case .Unverified:
		// Said in its own words, never as a shade of one of the other two.
		// This is the common case and the whole point is that it is not
		// mistaken for an answer.
		label, cls = "unchecked", "bg-amber-500/15 text-amber-700"
	}
	p.row(ui, tfmt("shrink-0 items-center px-1.5 py-0.5 rounded %s", cls))
	p.text(ui, label, "text-[9px] font-semibold tracking-wide")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Ready
// ---------------------------------------------------------------------------

ready_view :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.col(ui, "w-full h-full overflow-hidden")
	defer p.end(ui)

	p.col(ui, "shrink-0 w-full px-5 pt-4 pb-3 gap-0.5 border-b border-border")
	p.text(ui, "Unblocked right now", "text-base font-semibold")
	p.text(
		ui,
		"Nothing open is in front of these. Ordered by how much each one frees.",
		"text-xs text-muted-foreground",
	)
	p.end(ui)

	if len(a.graph.cycle) > 0 {
		p.col(ui, "m-5 p-4 rounded-lg border border-destructive/40 bg-destructive/5 gap-1")
		p.text(ui, "The graph has a cycle, so nothing can be called ready.", "text-sm font-medium text-destructive")
		p.text(ui, cycle_text(a.graph.cycle), "text-xs font-mono text-muted-foreground")
		p.end(ui)
		return
	}

	p.key(ui, "ready-scroll")
	p.col(ui, "flex-1 min-h-0 w-full overflow-y-auto px-3 py-3 gap-2")
	defer p.end(ui)
	rows := visible_rows(a)
	if len(rows) == 0 {
		empty(ui, "Nothing is unblocked.", "Every open issue is waiting for something else.")
		return
	}
	for i in rows {
		ready_card(ui, a, i)
	}
}

ready_card :: proc(ui: ^p.Ctx, a: ^App_State, i: int) {
	it := &a.store.issues[i]
	on := a.sel == i
	p.key(ui, it.id)
	p.row(
		ui,
		tfmt(
			"w-full shrink-0 items-center gap-3 px-3 py-2.5 rounded-lg border %s",
			on ? "border-primary bg-accent" : "border-border bg-card",
		),
	)
	defer p.end(ui)

	p.div(ui, "w-1 self-stretch rounded-full bg-emerald-600 shrink-0")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "items-center gap-2 min-w-0")
	p.text(ui, it.id, "text-[11px] font-mono text-muted-foreground shrink-0")
	p.text(ui, it.title, "text-sm font-medium min-w-0")
	verify_badge(ui, it)
	p.end(ui)
	p.row(ui, "items-center gap-2")
	if it.project != "" {
		p.text(ui, it.project, "text-[10px] text-muted-foreground")
	}
	for l in it.labels {
		p.row(ui, "shrink-0 px-1.5 rounded bg-muted")
		p.text(ui, l, "text-[9px] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	n := len(a.graph.dependants[i])
	p.col(ui, "shrink-0 items-end gap-0.5")
	p.textf(ui, n > 0 ? "text-sm font-semibold text-emerald-600" : "text-sm font-semibold text-muted-foreground", "%d", n)
	p.text(ui, n == 1 ? "unblocks" : "unblocks", "text-[9px] text-muted-foreground")
	p.end(ui)

	if it.assignee != "" {
		p.row(ui, "shrink-0 px-2 py-0.5 rounded-full bg-muted")
		p.text(ui, it.assignee, "text-[10px] text-muted-foreground")
		p.end(ui)
	}
}

empty :: proc(ui: ^p.Ctx, title, sub: string) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-1")
	p.text(ui, title, "text-sm font-medium text-muted-foreground")
	p.text(ui, sub, "text-xs text-muted-foreground/70")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

list_view :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.col(ui, "w-full h-full overflow-hidden")
	defer p.end(ui)

	p.row(ui, "shrink-0 w-full items-center gap-3 px-5 h-8 border-b border-border bg-muted/40")
	p.text(ui, "ID", "text-[10px] font-medium text-muted-foreground w-[56] shrink-0")
	p.text(ui, "STATE", "text-[10px] font-medium text-muted-foreground w-[72] shrink-0")
	p.text(ui, "ISSUE", "text-[10px] font-medium text-muted-foreground flex-1 min-w-0")
	p.text(ui, "BLOCKED BY", "text-[10px] font-medium text-muted-foreground w-[150] shrink-0")
	p.text(ui, "VERIFY", "text-[10px] font-medium text-muted-foreground w-[80] shrink-0")
	p.end(ui)

	p.key(ui, "list-scroll")
	p.col(ui, "flex-1 min-h-0 w-full overflow-y-auto")
	defer p.end(ui)
	for i in visible_rows(a) {
		list_row(ui, a, i)
	}
}

list_row :: proc(ui: ^p.Ctx, a: ^App_State, i: int) {
	it := &a.store.issues[i]
	on := a.sel == i
	closed := a.graph.closed[i]
	p.key(ui, it.id)
	p.row(
		ui,
		tfmt(
			"w-full shrink-0 items-center gap-3 px-5 py-2 border-b border-border/50 %s",
			on ? "bg-accent" : "",
		),
	)
	defer p.end(ui)

	p.text(ui, it.id, "text-[11px] font-mono text-muted-foreground w-[56] shrink-0")

	p.row(ui, "w-[72] shrink-0")
	p.row(ui, tfmt("px-1.5 py-0.5 rounded %s", closed ? "bg-muted" : "bg-primary/10"))
	p.text(ui, it.state, tfmt("text-[10px] %s", closed ? "text-muted-foreground" : "text-primary"))
	p.end(ui)
	p.end(ui)

	p.row(ui, "flex-1 min-w-0 items-center gap-2")
	p.text(ui, it.title, tfmt("text-xs min-w-0 %s", closed ? "text-muted-foreground" : ""))
	if a.graph.ready[i] {
		p.div(ui, "size-1.5 rounded-full bg-emerald-600 shrink-0")
		p.end(ui)
	}
	p.end(ui)

	blockers := graph_blockers(&a.graph, i)
	p.row(ui, "w-[150] shrink-0 items-center gap-1")
	if len(blockers) == 0 {
		p.text(ui, "—", "text-[10px] text-muted-foreground/50")
	} else {
		for b, n in blockers {
			if n >= 3 {
				p.textf(ui, "text-[10px] text-muted-foreground", "+%d", len(blockers) - 3)
				break
			}
			p.row(ui, "shrink-0 px-1 rounded bg-muted")
			p.text(ui, b, "text-[9px] font-mono text-muted-foreground")
			p.end(ui)
		}
	}
	p.end(ui)

	p.row(ui, "w-[80] shrink-0")
	verify_badge(ui, it)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------

board_view :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.key(ui, "board-scroll")
	p.row(ui, "w-full h-full items-stretch gap-3 p-4 overflow-x-auto")
	defer p.end(ui)
	for s in a.store.states {
		board_column(ui, a, s)
	}
}

board_column :: proc(ui: ^p.Ctx, a: ^App_State, s: State_Def) {
	n := 0
	for it in a.store.issues {
		if it.state == s.name {
			n += 1
		}
	}
	p.key(ui, s.name)
	p.col(ui, "w-[272] shrink-0 h-full rounded-lg bg-muted/50 border border-border overflow-hidden")
	defer p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2 px-3 h-9 border-b border-border")
	p.div(ui, tfmt("size-2 rounded-full shrink-0 %s", s.closed ? "bg-muted-foreground/40" : "bg-primary"))
	p.end(ui)
	p.text(ui, s.name, "text-xs font-medium")
	p.spacer(ui)
	p.textf(ui, "text-[10px] text-muted-foreground", "%d", n)
	p.end(ui)

	p.col(ui, "flex-1 min-h-0 overflow-y-auto p-2 gap-2")
	defer p.end(ui)
	for &it, i in a.store.issues {
		if it.state != s.name {
			continue
		}
		p.key(ui, it.id)
		p.col(
			ui,
			tfmt(
				"w-full shrink-0 gap-1.5 p-2.5 rounded-md border bg-card %s",
				a.sel == i ? "border-primary" : "border-border",
			),
		)
		p.row(ui, "items-center gap-1.5")
		p.text(ui, it.id, "text-[10px] font-mono text-muted-foreground")
		verify_badge(ui, &it)
		p.spacer(ui)
		if a.graph.ready[i] {
			p.div(ui, "size-1.5 rounded-full bg-emerald-600 shrink-0")
			p.end(ui)
		}
		p.end(ui)
		p.text(ui, it.title, "text-xs leading-snug")
		blockers := graph_blockers(&a.graph, i)
		if len(blockers) > 0 {
			p.row(ui, "items-center gap-1")
			p.text(ui, "waits for", "text-[9px] text-muted-foreground")
			for b, k in blockers {
				if k >= 2 {
					break
				}
				p.row(ui, "shrink-0 px-1 rounded bg-background")
				p.text(ui, b, "text-[9px] font-mono text-muted-foreground")
				p.end(ui)
			}
			p.end(ui)
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Graph
// ---------------------------------------------------------------------------

Graph_Draw :: struct {
	view: Dag_View,
}

graph_view :: proc(ui: ^p.Ctx, a: ^App_State) {
	if !a.dag_ok {
		app_rebuild_dag(a)
	}
	// The draw state must outlive the tree build: `p.pixels` borrows its user
	// pointer until the frame is painted, so a struct on this stack would be
	// gone by then. It lives in `App_State` through a pointer kept here.
	gd := p.state(ui, "graph-draw", Graph_Draw{})
	gd.view = Dag_View {
		dag    = &a.dag,
		store  = &a.store,
		graph  = &a.graph,
		fonts  = ui.fonts,
		theme  = dag_theme_light(),
		focus  = a.sel,
		scroll = a.scroll,
		zoom   = a.zoom,
	}
	p.pixels(ui, "w-full h-full", gd, proc(c: ^p.Canvas, r: p.Rect, gd: ^Graph_Draw) {
		dag_draw(c, r, &gd.view)
	})
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

detail_pane :: proc(ui: ^p.Ctx, a: ^App_State) {
	p.col(ui, tfmt("w-[%d] shrink-0 h-full border-l border-border bg-sidebar overflow-hidden", SIDE_W))
	defer p.end(ui)

	if a.sel < 0 || a.sel >= len(a.store.issues) {
		empty(ui, "No issue selected", "j and k move the selection")
		return
	}
	it := &a.store.issues[a.sel]
	i := a.sel

	p.col(ui, "shrink-0 w-full gap-2 px-4 pt-4 pb-3 border-b border-border")
	p.row(ui, "items-center gap-2")
	p.text(ui, it.id, "text-[11px] font-mono text-muted-foreground")
	p.row(ui, tfmt("px-1.5 py-0.5 rounded %s", a.graph.closed[i] ? "bg-muted" : "bg-primary/10"))
	p.text(ui, it.state, tfmt("text-[10px] %s", a.graph.closed[i] ? "text-muted-foreground" : "text-primary"))
	p.end(ui)
	verify_badge(ui, it)
	p.spacer(ui)
	if it.assignee != "" {
		p.text(ui, it.assignee, "text-[10px] text-muted-foreground")
	}
	p.end(ui)
	p.text(ui, it.title, "text-sm font-semibold leading-snug")
	p.end(ui)

	p.key(ui, "detail-scroll")
	p.col(ui, "flex-1 min-h-0 w-full overflow-y-auto px-4 py-3 gap-4")
	defer p.end(ui)

	// Blocking first. It is the question being asked.
	blockers := graph_blockers(&a.graph, i)
	section(ui, a.graph.ready[i] ? "Unblocked" : "Waiting for")
	if len(blockers) == 0 {
		p.text(
			ui,
			a.graph.closed[i] ? "This is closed." : "Nothing open is in front of this.",
			"text-xs text-muted-foreground",
		)
	} else {
		for b in blockers {
			p.row(ui, "items-center gap-2 w-full")
			p.div(ui, "size-1.5 rounded-full bg-amber-500 shrink-0")
			p.end(ui)
			p.text(ui, b, "text-xs font-mono")
			if other := store_find(&a.store, b); other != nil {
				p.text(ui, ellipsis(other.title, 34), "text-xs text-muted-foreground min-w-0")
			}
			p.end(ui)
		}
	}

	if len(a.graph.dependants[i]) > 0 {
		section(ui, "Unblocks")
		for d in a.graph.dependants[i] {
			p.row(ui, "items-center gap-2 w-full")
			p.text(ui, a.graph.ids[d], "text-xs font-mono")
			p.text(ui, ellipsis(a.store.issues[d].title, 36), "text-xs text-muted-foreground min-w-0")
			p.end(ui)
		}
	}

	// Verification, in its own panel, with the command visible. Showing the
	// command in the window rather than hiding it behind the badge is part of
	// the gate: the only way to run it is to type `track stale --run`, and
	// nobody should type that without having read what it will execute.
	section(ui, "Verification")
	if it.verify == "" {
		p.text(ui, "None declared. Nothing checks that this is still true.", "text-xs text-muted-foreground")
	} else {
		p.col(ui, "w-full gap-1.5 p-2.5 rounded-md border border-border bg-background")
		p.text(ui, it.verify, "text-[11px] font-mono leading-snug w-full")
		p.col(ui, "w-full gap-0.5")
		switch it.verdict {
		case .Stale:
			p.text(ui, "Exited non-zero: this issue is lying.", "text-[10px] text-destructive font-medium")
		case .True:
			p.text(ui, "Exited zero when last run.", "text-[10px] text-emerald-700")
		case .Unverified:
			p.text(ui, "Never run. Not an answer either way.", "text-[10px] text-amber-700")
		}
		if it.checked != "" {
			p.textf(ui, "text-[10px] text-muted-foreground", "checked %s", it.checked)
		}
		p.end(ui)
		p.text(ui, "track stale --run executes it; nothing here does.", "text-[10px] text-muted-foreground")
		p.end(ui)
	}

	if it.body != "" {
		section(ui, "Notes")
		p.text(ui, it.body, "text-xs leading-relaxed text-muted-foreground w-full")
	}

	if it.prompt != "" {
		section(ui, "Prompt")
		p.col(ui, "w-full gap-1.5 p-3 rounded-md border border-border bg-background")
		p.text(ui, ellipsis(it.prompt, 900), "text-[11px] leading-relaxed w-full")
		p.end(ui)
		p.textf(ui, "text-[10px] text-muted-foreground", "track prompt %s --bare", it.id)
	}

	section(ui, "File")
	// From the left: the end of a path is the part that identifies it, and a
	// path with no spaces in it does not wrap.
	p.text(ui, tail_path(short_home(it.path), 3), "text-[10px] font-mono text-muted-foreground w-full")
}

section :: proc(ui: ^p.Ctx, title: string) {
	p.text(ui, title, "text-[10px] font-semibold tracking-wide text-muted-foreground uppercase shrink-0")
}
