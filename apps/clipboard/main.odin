package main

// palmy clipboard manager.
//
// A clipboard history is a log of everything you copied, so this app is built
// around three things in equal measure: finding an old entry quickly, putting
// it back on the clipboard, and being able to trust it with the rest.
// Selections that advertise a password-manager hint are never read at all,
// everything written to disk is mode 0600, and clearing the lot is one
// shortcut away and visible in the footer.
//
// The store and the watcher thread live in store.odin. The frame holds the
// store's mutex for its whole duration and never shells out.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1100
WIN_H :: 720

ROW_H :: 62

St :: struct {
	query:    [dynamic]u8,
	caret:    int,
	hits:     [dynamic]Ranked,
	sel:      int,
	filter:   Filter,

	// Full-size preview of the selected image, decoded lazily and once.
	prev_key: u64,
	prev:     p.Image,
	prev_ok:  bool,

	confirm:  bool, // the "clear everything" dialog

	toast:    string,
	toast_until: time.Tick, // on a real monotonic clock; see the frame loop

	have_wl:  bool,
	capture:  Capture,
}

// g_test / g_test_clip make the clipboard write observable instead of real.
g_test: bool
g_test_clip: string

// Capture is how this window learns about selections.
Capture :: enum u8 {
	None, // no way to: no data control and no wl-paste
	Offers, // palmy's offer API with data control: every change, focused or not
	Wl_Paste, // the fallback: `wl-paste --watch` and its spool (store.odin)
}

main :: proc() {
	// Everything but an empty line is the command line's (cli.odin): the
	// history, read and edited headlessly, and the older --selftest and
	// --shots spellings.
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	app, err := kit.start(
		{
			title = "Clipboard",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 760,
			min_height = 420,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
	)
	if err != "" {
		fmt.eprintfln("clipboard: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_dark_theme()

	st := St {
		query   = make([dynamic]u8),
		hits    = make([dynamic]Ranked),
		have_wl = kit.has_tool("wl-paste") && kit.has_tool("wl-copy"),
	}

	ensure_dirs()
	load()

	// The offer path when palmy can see every change; the wl-paste path when
	// it can see them only while focused, or not at all. Either way the
	// sensitivity gate runs before anything is read (store.odin).
	switch p.clipboard_watch(app) {
	case .Always:
		st.capture = .Offers
		sync.atomic_store(&g.enabled, true)
		set_status("watching the selection (data control, focused or not)")
	case .Focused, .Unsupported:
		// `.Focused` would hand this window an offer only when it gains
		// focus; a clipboard manager that misses everything copied while it
		// is in the background is not one. Stop watching and fall back.
		p.clipboard_watch(app, {})
		if st.have_wl {
			st.capture = .Wl_Paste
			watcher_start()
		}
	}
	if os.get_env("PALMY_CLIPBOARD_TRACE", context.temp_allocator) != "" {
		fmt.eprintfln("[clipboard] capture: %v", st.capture)
	}
	defer if st.capture == .Wl_Paste {
		watcher_stop()
	}

	// The window used to keep drawing at vsync while it had focus, to notice
	// the watcher thread's captures. A second, tiny thread now watches the
	// watcher's counters — and the history file, which `clipboard delete` in
	// a terminal may have changed — and wakes the loop when one moves, so the
	// window sleeps whether it has focus or not. Offers wake the loop through
	// palmy themselves.
	waker := waker_start(app)
	defer waker_stop(waker)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		// Offers first, before the frame takes the store: storing one takes
		// the lock itself.
		if st.capture == .Offers {
			drain_offers(ui)
		}

		// The frame owns the store for its whole duration. Nothing below may
		// call a procedure that locks again — `sync.Mutex` is not reentrant.
		sync.mutex_lock(&g.mu)

		// Free whatever was retired while the last frame was still on screen.
		reap_locked()

		// Another process — `clipboard` on the command line — rewrote the
		// history: take its version rather than overwrite it on the next save.
		if sync.atomic_exchange(&g.reload, false) {
			reload_locked()
			drop_preview(&st)
		}

		refilter(&st)
		handle_keys(ui, app, &st)
		refilter(&st)
		build(ui, &st)

		// The rows say how long ago each entry was taken ("12s ago"), so the
		// next time one of those labels changes is the next frame worth
		// drawing.
		if at, ok := next_ago_change(now_unix()); ok {
			wall := time.now()
			p.wake_after(ui, time.diff(wall, time.unix(at, 0)) + 5 * time.Millisecond)
		}

		sync.mutex_unlock(&g.mu)

		// The toast expires on a real clock with one wake at its deadline.
		// `ui.now` is clamped per frame and cannot time anything.
		if st.toast != "" {
			left := time.tick_diff(time.tick_now(), st.toast_until)
			if left <= 0 {
				// This frame still drew the toast. Two more take it off the
				// screen: measured on headless sway, the first frame after a
				// clear is presented and the toast stays visible (palmy's
				// damage tracking; PALMY_DAMAGE=off needs only one).
				delete(st.toast)
				st.toast = ""
				p.redraw(ui)
				p.wake_after(ui, 50 * time.Millisecond)
			} else {
				p.wake_after(ui, left + time.Millisecond)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Waking the window for a capture
// ---------------------------------------------------------------------------

// WAKER_PERIOD is how often the waker looks at the watcher's counters. The
// watcher itself drains its spool every 50 ms, so this is the same order.
WAKER_PERIOD :: 100 * time.Millisecond

Waker :: struct {
	app:  ^p.App,
	stop: bool,
	th:   ^thread.Thread,
}

// waker_start runs a thread that wakes the frame loop whenever the watcher has
// captured or skipped something since it last looked. It reads two atomics
// and takes no lock, so it cannot contend with the frame for the store.
waker_start :: proc(app: ^p.App) -> ^Waker {
	wk := new(Waker)
	wk.app = app
	wk.th = thread.create_and_start_with_data(wk, proc(data: rawptr) {
		wk := (^Waker)(data)
		seen_c := sync.atomic_load(&g.captured)
		seen_s := sync.atomic_load(&g.secrets)
		for !sync.atomic_load(&wk.stop) {
			time.sleep(WAKER_PERIOD)
			c := sync.atomic_load(&g.captured)
			s := sync.atomic_load(&g.secrets)
			if c != seen_c || s != seen_s {
				seen_c, seen_s = c, s
				p.wake(wk.app)
			}
			if !sync.atomic_load(&g.reload) && history_changed() {
				sync.atomic_store(&g.reload, true)
				p.wake(wk.app)
			}
			free_all(context.temp_allocator)
		}
	})
	return wk
}

waker_stop :: proc(wk: ^Waker) {
	sync.atomic_store(&wk.stop, true)
	thread.join(wk.th)
	thread.destroy(wk.th)
	free(wk)
}

// next_ago_change is the unix second at which the earliest of the rows'
// relative timestamps (see `ago`) next reads differently. Caller holds `g.mu`.
next_ago_change :: proc(now: i64) -> (at: i64, ok: bool) {
	for e in g.items {
		d := now - e.when_
		next: i64
		switch {
		case d < 0:
			next = e.when_
		case d < 5:
			next = e.when_ + 5
		case d < 60:
			next = now + 1
		case d < 3600:
			next = e.when_ + (d / 60 + 1) * 60
		case d < 86400:
			next = e.when_ + (d / 3600 + 1) * 3600
		case d < 7 * 86400:
			next = e.when_ + (d / 86400 + 1) * 86400
		case:
			continue
		}
		if !ok || next < at {
			at, ok = next, true
		}
	}
	return
}

register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x141414))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c1c))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1f1f1f))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x303033))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x2c2c2c))
	p.register_color("input", c(0x2c2c2c))
	p.register_color("ring", c(0x8e8e8e))
}

// ---------------------------------------------------------------------------
// Filtering
// ---------------------------------------------------------------------------

query_text :: proc(st: ^St) -> string {
	return string(st.query[:])
}

refilter :: proc(st: ^St) {
	rank_locked(&st.hits, query_text(st), st.filter)
	st.sel = clamp(st.sel, 0, max(0, len(st.hits) - 1))
}

current :: proc(st: ^St) -> ^Entry {
	if st.sel < 0 || st.sel >= len(st.hits) {
		return nil
	}
	return &g.items[st.hits[st.sel].idx]
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if st.confirm {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'n') {
			st.confirm = false
			return
		}
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, 'y') {
			n := clear_all_locked()
			st.confirm = false
			st.sel = 0
			drop_preview(st)
			toast(st, ui, fmt.tprintf("Cleared %d entries and every stored image", n))
		}
		return
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(st.query) > 0 {
			clear(&st.query)
			st.caret = 0
			return
		}
		quit(app)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		quit(app)
		return
	}

	// `key_count`, not `key_pressed`: several presses can arrive in one frame
	// — key repeat, or simply a fast hand — and a boolean cannot tell one from
	// three. A held Down that moves one row per frame is this going wrong.
	if d := p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP); d != 0 {
		move(st, d)
		return
	}
	if d := p.key_count(ui, p.KEY_PAGE_DOWN) - p.key_count(ui, p.KEY_PAGE_UP); d != 0 {
		move(st, d * 6)
		return
	}
	if n := p.key_count(ui, p.KEY_TAB); n > 0 {
		d := .Shift in ui.input.mods ? -n : n
		c := len(Filter)
		st.filter = Filter(((int(st.filter) + d) % c + c) % c)
		st.sel = 0
		return
	}

	if p.shortcut(ui, 'm', {.Ctrl}) {
		on := !sync.atomic_load(&g.enabled)
		sync.atomic_store(&g.enabled, on)
		toast(st, ui, on ? "Monitoring the clipboard" : "Monitoring paused — nothing is recorded")
		return
	}
	if p.shortcut(ui, 'l', {.Ctrl, .Shift}) || p.shortcut(ui, 'l', {.Ctrl}) {
		st.confirm = true
		return
	}
	if p.shortcut(ui, 'u', {.Ctrl}) {
		clear(&st.query)
		st.caret = 0
		return
	}

	if e := current(st); e != nil {
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
			copy_back(st, ui, e)
			return
		}
		if p.shortcut(ui, 'p', {.Ctrl}) {
			set_pinned_locked(st.hits[st.sel].idx, !e.pinned)
			toast(st, ui, e.pinned ? "Pinned" : "Unpinned")
			return
		}
		if p.key_pressed(ui, p.KEY_DELETE, false) || p.shortcut(ui, 'd', {.Ctrl}) {
			delete_locked(st.hits[st.sel].idx)
			drop_preview(st)
			toast(st, ui, "Deleted")
			return
		}
	}

	edit_query(ui, st)
}

move :: proc(st: ^St, d: int) {
	if len(st.hits) == 0 {
		return
	}
	st.sel = clamp(st.sel + d, 0, len(st.hits) - 1)
}

edit_query :: proc(ui: ^p.Ctx, st: ^St) {
	if typed := p.typed_text(ui); len(typed) > 0 {
		inject_at_elems(&st.query, st.caret, ..transmute([]u8)typed)
		st.caret += len(typed)
		st.sel = 0
	}
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case p.KEY_BACKSPACE:
			if st.caret > 0 {
				n := utf8_back(st.query[:], st.caret)
				remove_range(&st.query, st.caret - n, st.caret)
				st.caret -= n
				st.sel = 0
			}
		case p.KEY_DELETE:
			if st.caret < len(st.query) {
				n := utf8_fwd(st.query[:], st.caret)
				remove_range(&st.query, st.caret, st.caret + n)
				st.sel = 0
			}
		case p.KEY_LEFT:
			if st.caret > 0 {st.caret -= utf8_back(st.query[:], st.caret)}
		case p.KEY_RIGHT:
			if st.caret < len(st.query) {st.caret += utf8_fwd(st.query[:], st.caret)}
		case p.KEY_HOME:
			st.caret = 0
		case p.KEY_END:
			st.caret = len(st.query)
		}
	}
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return max(1, at - i)
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return i - at
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	if st.toast != "" {
		delete(st.toast)
	}
	st.toast = strings.clone(msg)
	st.toast_until = time.tick_add(time.tick_now(), 4 * time.Second)
}

// quit is nil-safe so the headless self-test can drive `handle_keys` with no
// window behind it.
quit :: proc(app: ^p.App) {
	if app != nil {
		p.quit_app(app)
	}
}

// copy_back is Enter: copy_entry, with its answer in the footer.
copy_back :: proc(st: ^St, ui: ^p.Ctx, e: ^Entry) {
	msg, _ := copy_entry(e)
	toast(st, ui, msg)
}

drop_preview :: proc(st: ^St) {
	if st.prev_ok {
		p.image_destroy(&st.prev)
		st.prev_ok = false
	}
	st.prev_key = 0
}

short :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && s[cut] & 0xc0 == 0x80 {cut -= 1}
	return fmt.tprintf("%s…", s[:cut])
}

human_size :: proc(n: int) -> string {
	switch {
	case n < 1024:
		return fmt.tprintf("%d B", n)
	case n < 1024 * 1024:
		return fmt.tprintf("%.1f KB", f64(n) / 1024)
	}
	return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
}

// ago renders a timestamp the way a list wants it: relative while that is
// useful, absolute once it is not.
ago :: proc(then: i64) -> string {
	d := now_unix() - then
	switch {
	case d < 5:
		return "just now"
	case d < 60:
		return fmt.tprintf("%ds ago", d)
	case d < 3600:
		return fmt.tprintf("%dm ago", d / 60)
	case d < 86400:
		return fmt.tprintf("%dh ago", d / 3600)
	case d < 7 * 86400:
		return fmt.tprintf("%dd ago", d / 86400)
	}
	t := time.unix(then, 0)
	y, mo, dd := time.date(t)
	return fmt.tprintf("%d-%02d-%02d", y, int(mo), dd)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, st: ^St) {
	header(ui, st)
	filter_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0")
	list_pane(ui, st)
	detail_pane(ui, st)
	p.end(ui)

	footer(ui, st)

	if st.confirm {
		confirm_dialog(ui, st)
	}
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.icon(ui, IC_CLIPBOARD_LIST, "size-[18] shrink-0 text-muted-foreground")

	p.row(ui, "flex-1 h-full items-center overflow-hidden")
	txt := query_text(st)
	if len(txt) == 0 {
		p.text(ui, "Search the clipboard history…", "text-base text-muted-foreground whitespace-nowrap")
	} else {
		p.text(ui, txt, "text-base whitespace-nowrap")
	}
	p.style(ui).shrink = 0

	// caret_on wakes the loop once per blink edge on a real clock, where
	// `animating = true` held a focused window at vsync to blink this.
	if !st.confirm && ui.input.focused {
		if p.caret_on(ui) {
			w := p.text_width(ui.fonts, txt[:clamp(st.caret, 0, len(txt))], 16, .Sans, .Regular)
			car := p.div(ui, "absolute w-[2] rounded-full bg-foreground")
			cs := p.style(ui, car)
			cs.inset[p.LEFT] = p.px(w)
			cs.inset[p.TOP] = p.px(18)
			cs.h = p.px(20)
			p.end(ui)
		}
	}
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	on := sync.atomic_load(&g.enabled)
	if st.capture == .None {
		// No data control and no wl-paste: nothing can be recorded.
		sc.badge(ui, "cannot watch the clipboard", .Destructive)
	} else if on {
		p.row(ui, "shrink-0 items-center gap-1.5 h-5 px-2 rounded-4xl bg-emerald-500/15")
		p.div(ui, "size-1.5 rounded-full bg-emerald-400")
		p.end(ui)
		p.text(ui, "Recording", "text-xs font-medium text-emerald-400 whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		sc.badge(ui, "Paused", .Outline)
	}
	if n := sync.atomic_load(&g.secrets); n > 0 {
		sc.badge_icon(ui, fmt.tprintf("%d skipped", n), IC_SHIELD_CHECK, .Secondary)
	}
	p.textf(
		ui,
		"text-xs text-muted-foreground whitespace-nowrap",
		"%d of %d · cap %d",
		len(st.hits),
		len(g.items),
		HISTORY_CAP,
	)
	p.style(ui).shrink = 0
	p.end(ui)
}

filter_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[38] shrink-0 items-center gap-1.5 px-3 border-b border-border")
	defer p.end(ui)

	for f in Filter {
		n := 0
		for e in g.items {
			switch f {
			case .All:
				n += 1
			case .Text:
				if e.kind == .Text {n += 1}
			case .Images:
				if e.kind == .Image {n += 1}
			case .Pinned:
				if e.pinned {n += 1}
			}
		}
		p.key(ui, FILTER_LABEL[f])
		idx := p.div(ui, "flex-row shrink-0 items-center gap-1.5 h-6 px-2 rounded-md border transition")
		p.apply(
			ui,
			f == st.filter \
			? "bg-accent border-foreground/15 text-foreground" \
			: "border-transparent text-muted-foreground hover:bg-muted",
			idx,
		)
		if p.clickable(ui, idx) {
			st.filter = f
			st.sel = 0
		}
		p.text(ui, FILTER_LABEL[f], "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.textf(ui, "text-[11] text-muted-foreground whitespace-nowrap", "%d", n)
		p.style(ui).shrink = 0
		p.end(ui)
	}

	p.spacer(ui)
	p.row(ui, "shrink-0 items-center gap-1.5")
	p.text(ui, "Filter", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	sc.kbd(ui, "Tab")
	p.end(ui)
}

list_pane :: proc(ui: ^p.Ctx, st: ^St) {
	list := p.col(ui, "flex-1 min-w-0 min-h-0 p-2 gap-1 overflow-scroll")

	if len(st.hits) == 0 {
		empty_state(ui, st)
		p.end(ui)
		return
	}

	sel_node := -1
	for r, i in st.hits {
		e := &g.items[r.idx]
		p.key(ui, fmt.tprintf("%016x", e.id))
		n := row(ui, st, e, r, i == st.sel)
		if i == st.sel {
			sel_node = n
		}
	}
	p.end(ui)

	// The newly public `scroll_into_view` is exactly what a keyboard-driven
	// list needs: the container scrolls the shortest distance that puts the
	// selection back on screen, and nothing else moves.
	if sel_node >= 0 {
		p.scroll_into_view(ui, p.node_id(ui, list), p.node_id(ui, sel_node), 6)
	}
}

row :: proc(ui: ^p.Ctx, st: ^St, e: ^Entry, r: Ranked, sel: bool) -> int {
	idx := p.div(
		ui,
		"flex-row w-full shrink-0 h-[62] items-center gap-3 px-2 rounded-lg transition overflow-hidden",
	)
	p.apply(ui, sel ? "bg-accent" : "hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		st.sel = index_of(st, r.idx)
	}
	defer p.end(ui)

	if sel {
		bar := p.div(ui, "absolute w-[3] rounded-full bg-primary")
		bs := p.style(ui, bar)
		bs.inset[p.LEFT] = p.px(0)
		bs.inset[p.TOP] = p.px(19)
		bs.h = p.px(24)
		p.end(ui)
	}

	// The leading box is the real thumbnail for an image, which is the whole
	// point of decoding them: a row that says "image/png" tells you nothing
	// when you have eight screenshots in the history.
	if e.kind == .Image && e.has_thumb {
		p.div(ui, "w-[64] h-[44] shrink-0 rounded-md overflow-hidden ring-1 ring-border bg-muted")
		p.image(ui, e.thumb, "w-full h-full", .Cover)
		p.end(ui)
	} else {
		p.div(ui, "w-[64] h-[44] shrink-0 flex-row items-center justify-center rounded-md bg-muted ring-1 ring-border")
		p.icon(ui, entry_icon(e), "size-4 text-muted-foreground")
		p.end(ui)
	}

	p.col(ui, "flex-1 min-w-0 gap-1 overflow-hidden")
	runs(ui, e.preview, r.hit, sel)
	p.row(ui, "items-center gap-2")
	p.text(ui, ago(e.when_), "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, "·", "text-[11] text-muted-foreground")
	p.style(ui).shrink = 0
	p.text(ui, human_size(e.size), "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(ui, "·", "text-[11] text-muted-foreground")
	p.style(ui).shrink = 0
	p.text(ui, e.mime, "text-[11] text-muted-foreground whitespace-nowrap truncate")
	p.end(ui)
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	if e.truncated {
		sc.badge(ui, "truncated", .Outline)
	}
	if e.pinned {
		p.icon(ui, IC_PIN, "size-3.5 shrink-0 text-amber-400")
	}
	if sel {
		sc.kbd(ui, "Enter")
	}
	p.end(ui)

	return idx
}

index_of :: proc(st: ^St, item: int) -> int {
	for r, i in st.hits {
		if r.idx == item {
			return i
		}
	}
	return st.sel
}

entry_icon :: proc(e: ^Entry) -> p.Icon {
	if e.kind == .Image {
		return IC_IMAGE
	}
	t := e.preview
	switch {
	case strings.has_prefix(t, "http://"), strings.has_prefix(t, "https://"):
		return IC_LINK
	case strings.has_prefix(t, "/"), strings.has_prefix(t, "~/"):
		return IC_FOLDER
	case strings.contains(t, "{") && strings.contains(t, "}"):
		return IC_FILE_CODE
	}
	return IC_FILE_TEXT
}

// runs draws the preview with the fuzzy match picked out, so the reason a row
// survived the filter is visible.
runs :: proc(ui: ^p.Ctx, s: string, h: Hit, strong: bool) {
	base := strong ? "text-sm font-medium whitespace-nowrap" : "text-sm whitespace-nowrap"
	if !hit_any(h) {
		p.text(ui, s, base)
		p.style(ui).truncate = true
		return
	}
	p.row(ui, "w-full items-baseline overflow-hidden")
	defer p.end(ui)

	dim := p.concat(ui, base, " text-muted-foreground")
	hot := p.concat(ui, base, " text-foreground font-semibold")
	i := 0
	for i < len(s) && i < 160 {
		on := hit_at(h, i)
		j := i
		for j < len(s) && hit_at(h, j) == on && j < 160 {
			j += 1
		}
		p.text(ui, s[i:j], on ? hot : dim)
		p.style(ui).shrink = 0
		i = j
	}
}

empty_state :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)

	p.div(ui, "size-12 flex-row items-center justify-center rounded-full bg-muted ring-1 ring-border")
	p.icon(ui, len(g.items) == 0 ? IC_CLIPBOARD : IC_SEARCH, "size-5 text-muted-foreground")
	p.end(ui)

	if len(g.items) == 0 {
		p.text(ui, "Nothing copied yet", "text-sm font-medium")
		p.text(
			ui,
			sync.atomic_load(&g.enabled) \
			? "Copy something anywhere and it will appear here within a second" \
			: "Monitoring is paused — Ctrl+M starts recording",
			"text-xs text-muted-foreground",
		)
		return
	}

	q := strings.trim_space(query_text(st))
	if q != "" {
		p.text(ui, "No entry matches", "text-sm font-medium")
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap",
			"Nothing in %s contains “%s”",
			FILTER_LABEL[st.filter],
			q,
		)
	} else {
		p.text(ui, "This filter is empty", "text-sm font-medium")
		p.text(ui, FILTER_LABEL[st.filter], "text-xs text-muted-foreground")
	}

	p.row(ui, "items-center gap-1.5 pt-1")
	sc.kbd(ui, "Ctrl")
	sc.kbd(ui, "U")
	p.text(ui, "clear the search", "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

detail_pane :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[400] shrink-0 h-full min-h-0 border-l border-border")
	defer p.end(ui)

	e := current(st)
	if e == nil {
		p.col(ui, "flex-1 items-center justify-center gap-2 p-6")
		p.icon(ui, IC_INFO, "size-5 text-muted-foreground")
		p.text(ui, "Nothing selected", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}

	p.row(ui, "w-full h-[44] shrink-0 items-center gap-2 px-4 border-b border-border")
	p.icon(ui, entry_icon(e), "size-3.5 shrink-0 text-muted-foreground")
	p.text(
		ui,
		e.kind == .Image ? "Image" : "Text",
		"text-xs font-semibold uppercase tracking-wide whitespace-nowrap",
	)
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.text(ui, ago(e.when_), "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.col(ui, "w-full flex-1 min-h-0 p-4 gap-3 overflow-scroll")
	switch e.kind {
	case .Image:
		image_detail(ui, st, e)
	case .Text:
		text_detail(ui, e)
	}

	meta(ui, "Type", e.mime)
	meta(ui, "Size", human_size(e.size))
	if e.kind == .Image {
		meta(ui, "Pixels", fmt.tprintf("%d × %d", e.w, e.h))
		meta(ui, "Stored at", e.blob)
	} else {
		meta(ui, "Characters", fmt.tprintf("%d", len(e.text)))
		if e.truncated {
			meta(ui, "Note", fmt.tprintf("stored truncated at %s", human_size(TEXT_CAP)))
		}
	}
	meta(ui, "Pinned", e.pinned ? "yes — never evicted by the cap" : "no")
	p.end(ui)

	p.col(ui, "w-full shrink-0 gap-1.5 p-3 border-t border-border")
	action(ui, IC_CLIPBOARD_CHECK, "Copy back to clipboard", "Enter")
	action(ui, e.pinned ? IC_PIN_OFF : IC_PIN, e.pinned ? "Unpin" : "Pin to the top", "Ctrl P")
	action(ui, IC_TRASH, "Delete this entry", "Del")
	p.end(ui)
}

image_detail :: proc(ui: ^p.Ctx, st: ^St, e: ^Entry) {
	// The row shows a thumbnail; the panel shows the real thing, decoded once
	// and kept until the selection moves.
	if st.prev_key != e.id {
		drop_preview(st)
		if img, ok := p.load_image(e.blob); ok {
			st.prev = img
			st.prev_ok = true
			st.prev_key = e.id
		} else {
			st.prev_key = e.id
		}
	}

	p.div(ui, "w-full h-[200] shrink-0 rounded-lg overflow-hidden ring-1 ring-border bg-muted")
	if st.prev_ok {
		p.image(ui, st.prev, "w-full h-full", .Contain)
	} else if e.has_thumb {
		p.image(ui, e.thumb, "w-full h-full", .Contain)
	} else {
		p.col(ui, "w-full h-full items-center justify-center gap-1")
		p.icon(ui, IC_IMAGE, "size-5 text-muted-foreground")
		p.text(ui, "The stored image could not be decoded", "text-[11] text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
}

text_detail :: proc(ui: ^p.Ctx, e: ^Entry) {
	if entry_secret(e) {
		p.col(ui, "w-full shrink-0 p-3 rounded-lg bg-muted ring-1 ring-border")
		p.text(ui, "This entry is flagged as a secret. Its text is not shown or copied; Del removes it.", "text-xs text-muted-foreground")
		p.end(ui)
		return
	}
	body := e.text
	if len(body) > 2400 {
		cut := 2400
		for cut > 0 && body[cut] & 0xc0 == 0x80 {cut -= 1}
		body = body[:cut]
	}
	// palmy's text layout has no tab stops, so a literal tab reaches the glyph
	// cache and comes back as .notdef. Expanding to four spaces here is the
	// honest fix in an app; the alternative would be patching the toolkit.
	body = expand_tabs(body)
	p.col(ui, "w-full shrink-0 max-h-[280] p-3 rounded-lg bg-muted ring-1 ring-border overflow-hidden")
	p.text(ui, body, "text-xs font-mono leading-relaxed")
	p.end(ui)
	if len(body) < len(e.text) {
		p.textf(
			ui,
			"text-[11] text-muted-foreground",
			"showing the first %d of %d characters",
			len(body),
			len(e.text),
		)
	}
}

expand_tabs :: proc(s: string) -> string {
	if !strings.contains(s, "\t") {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		if s[i] == '\t' {
			strings.write_string(&b, "    ")
		} else {
			strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

meta :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full shrink-0 items-start gap-3")
	defer p.end(ui)
	p.text(ui, label, "w-[76] shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.text(ui, value, "flex-1 text-[11] font-mono truncate whitespace-nowrap")
}

action :: proc(ui: ^p.Ctx, ic: p.Icon, label, key: string) {
	p.row(ui, "w-full h-8 shrink-0 items-center gap-2 px-2 rounded-md")
	defer p.end(ui)
	p.icon(ui, ic, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, label, "flex-1 text-xs whitespace-nowrap truncate")
	for part in strings.split(key, " ", context.temp_allocator) {
		sc.kbd(ui, part)
	}
}

// ---------------------------------------------------------------------------
// Footer and the clear dialog
// ---------------------------------------------------------------------------

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
		return
	}

	hint(ui, "Enter", "", "Copy back")
	hint(ui, "Ctrl", "P", "Pin")
	hint(ui, "Del", "", "Delete")
	hint(ui, "Ctrl", "M", sync.atomic_load(&g.enabled) ? "Pause" : "Record")
	hint(ui, "Ctrl", "L", "Clear history")
	p.spacer(ui)
	hint(ui, "Esc", "", "Close")
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

// confirm_dialog is drawn inside the window, because palmy has no xdg_popup.
confirm_dialog :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)

	p.div(ui, "absolute inset-0 bg-background/70 z-40")
	p.end(ui)

	W :: f32(420)
	H :: f32(196)
	panel := p.col(ui, "absolute z-50 gap-3 p-5 rounded-xl bg-popover ring-1 ring-border shadow-2xl")
	ps := p.style(ui, panel)
	ps.position = .Absolute
	ps.inset[p.LEFT] = p.px((size.x - W) * 0.5)
	ps.inset[p.TOP] = p.px((size.y - H) * 0.4)
	ps.w = p.px(W)
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.div(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-lg bg-destructive/15")
	p.icon(ui, IC_TRIANGLE_ALERT, "size-4 text-destructive")
	p.end(ui)
	p.text(ui, "Clear the whole history?", "text-sm font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)

	p.textf(
		ui,
		"text-xs text-muted-foreground",
		"This deletes all %d entries, including pinned ones, and removes every image stored under ~/.local/share/palmy-clipboard/blobs. It cannot be undone.",
		len(g.items),
	)

	p.row(ui, "w-full items-center gap-2 pt-1")
	p.spacer(ui)
	p.row(ui, "shrink-0 items-center gap-1.5")
	sc.kbd(ui, "Esc")
	p.text(ui, "Keep", "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.row(ui, "shrink-0 items-center gap-1.5 h-8 px-3 rounded-md bg-destructive/15")
	sc.kbd(ui, "Enter")
	p.text(ui, "Delete everything", "text-xs font-medium text-destructive whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.end(ui)
}
