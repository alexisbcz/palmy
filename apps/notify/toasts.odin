// The toasts: one layer-shell surface at the top right, a stack of up to
// three, newest on top, a call pinned above everything.
//
//	notify toasts        (the daemon starts it; it stays up, and holds a
//	                      surface only while something is on screen)
//
// Each toast says whose it is before anything else -- a band and "● Northwind"
// in the identity's colour, then the app -- because a work message and a
// personal one look alike otherwise (cloud/docs/shell.md, "Notifications").
// A toast that broke through a quiet identity says so, in words.
//
// Expiry pauses while the pointer is over the stack. The keyboard reaches it
// through `notify focus` (the wm binding proposed in
// cloud/docs/notifications.md): the surface comes back with exclusive
// keyboard focus, Up/Down choose, Enter opens, 1-3 press an action, Delete
// dismisses, Escape gives the keyboard back.
//
// Two palmy limits shape this, both written up as requests: a layer surface
// cannot change its size after it is created, so the surface is re-created
// at the stack's measured height whenever that changes; and buffers are
// XRGB, so the surface is an opaque rectangle -- the toasts are one panel
// with dividers rather than floating cards with gaps and shadows between
// them.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

TOAST_W :: 384
TOAST_MAX :: 3

Toasts :: struct {
	view:    View,
	handles: [dynamic]string,
	left:    map[u32]f64, // ms of display left, per id
	total:   map[u32]f64,
	gone:    map[u32]bool, // hidden locally, waiting for the daemon to agree
	sel:     int,
	focused: bool,
	dark:    bool,
	tz:      i64,
	now:     i64, // wall ms, for "now"/"2 min"
	hover:   bool,
	offline: bool, // drawn for a screenshot: no daemon to talk to
}

// visible is the stack in drawing order: a call first, then newest first.
visible :: proc(t: ^Toasts, allocator := context.temp_allocator) -> []^View_Note {
	out := make([dynamic]^View_Note, allocator)
	for &n in t.view.notes {
		if n.showing && !t.gone[n.id] && strings.has_prefix(n.category, "call.") {
			append(&out, &n)
		}
	}
	for &n in t.view.notes {
		if n.showing && !t.gone[n.id] && !strings.has_prefix(n.category, "call.") {
			append(&out, &n)
		}
	}
	return out[:]
}

shown_count :: proc(t: ^Toasts) -> int {
	return min(len(visible(t)), TOAST_MAX)
}

clip :: proc(s: string, max_runes: int) -> string {
	n := 0
	for _, i in s {
		if n == max_runes {
			return fmt.tprintf("%s…", strings.trim_right_space(s[:i]))
		}
		n += 1
	}
	return s
}

// handles_sync keeps the colour tokens' order stable: identities in the
// order they were first seen, so a toast does not change colour when
// another arrives.
handles_sync :: proc(handles: ^[dynamic]string, notes: []View_Note) {
	for h in identity_handles() {
		found := false
		for x in handles {
			if x == h {
				found = true
			}
		}
		if !found {
			append(handles, strings.clone(h))
		}
	}
	for n in notes {
		if n.identity == "" {
			continue
		}
		found := false
		for x in handles {
			if x == n.identity {
				found = true
			}
		}
		if !found {
			append(handles, strings.clone(n.identity))
		}
	}
}

// draw_toasts builds the stack and returns the index of its outer column,
// whose height is the surface's height.
draw_toasts :: proc(ui: ^p.Ctx, t: ^Toasts) -> int {
	vis := visible(t)
	stack := p.col(ui, "w-full shrink-0")
	defer p.end(ui)

	for n, i in vis {
		if i >= TOAST_MAX {
			break
		}
		toast(ui, t, n, i)
	}
	if len(vis) > TOAST_MAX {
		more := len(vis) - TOAST_MAX
		p.key(ui, "more")
		idx := p.row(ui, "w-full h-[34] items-center justify-center gap-1.5 border-t border-border bg-muted/50 hover:bg-muted cursor-pointer")
		p.icon(ui, ICON_LAYERS, "size-3.5 text-muted-foreground")
		p.text(ui, fmt.tprintf("%d more in the center", more), "text-[12] font-medium text-muted-foreground")
		p.end(ui)
		if p.clickable(ui, idx) && !t.offline {
			op("center", 0)
		}
	}
	if t.focused {
		p.row(ui, "w-full h-[30] items-center gap-3 px-3.5 border-t border-border bg-muted/50")
		hint :: proc(ui: ^p.Ctx, k, label: string) {
			p.row(ui, "items-center gap-1")
			sc.kbd(ui, k)
			p.text(ui, label, "text-[11] text-muted-foreground")
			p.end(ui)
		}
		hint(ui, "↑↓", "choose")
		hint(ui, "↵", "open")
		hint(ui, "1–3", "actions")
		hint(ui, "Del", "dismiss")
		hint(ui, "Esc", "done")
		p.end(ui)
	}
	return stack
}

@(private = "file")
toast :: proc(ui: ^p.Ctx, t: ^Toasts, n: ^View_Note, i: int) {
	tok := ident_token(t.handles[:], n.identity)
	call := strings.has_prefix(n.category, "call.")
	selected := t.focused && t.sel == i

	p.key(ui, fmt.tprintf("toast-%d", n.id))
	row := p.row(ui, "relative w-full items-stretch")
	if i > 0 {
		p.apply(ui, "border-t border-border", row)
	}
	if selected {
		p.apply(ui, "bg-accent", row)
	}
	defer p.end(ui)

	// The identity band: 3 px on the leading edge, the identity's colour.
	p.div(ui, fmt.tprintf("w-[3] shrink-0 bg-%s", tok))
	p.end(ui)

	body := p.col(ui, "flex-1 min-w-0 pl-3.5 pr-2 pt-3 pb-3 gap-1")
	if p.clickable(ui, body) && !t.offline {
		op("invoke", n.id, "action", "default")
		t.gone[n.id] = true
	}

	// Header: ● Northwind · Mail                     now  ✕
	p.row(ui, "w-full items-center gap-1.5 h-[20]")
	p.div(ui, fmt.tprintf("size-[7] shrink-0 rounded-full bg-%s", tok))
	p.end(ui)
	ident := n.ident_name != "" ? n.ident_name : "No identity"
	p.text(ui, ident, fmt.tprintf("text-[12] font-semibold whitespace-nowrap text-%s", tok))
	p.text(ui, "·", "text-[12] text-muted-foreground/60")
	p.icon(ui, class_icon(n), "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, n.app_label, "text-[12] text-muted-foreground whitespace-nowrap truncate min-w-0")
	p.spacer(ui)
	p.text(ui, when_text(n.created, t.now, t.tz), "text-[11.5] text-muted-foreground/80 whitespace-nowrap")
	p.key(ui, fmt.tprintf("x-%d", n.id))
	x := sc.button_open(ui, .Ghost, .Icon_XS, {})
	p.apply(ui, "text-muted-foreground -mr-0.5", x)
	if p.is_hovered(ui, x) {
		p.apply(ui, sc.button_variant_class(.Ghost, {hover = true}), x)
	}
	p.icon(ui, ICON_X, "size-3.5")
	sc.button_end(ui)
	if p.clickable(ui, x) && !t.offline {
		op("dismiss", n.id)
		t.gone[n.id] = true
	}
	p.end(ui)

	// The words.
	p.text(ui, clip(n.title, 80), call ? "text-[15] font-semibold leading-snug pt-0.5" : "text-[14] font-semibold leading-snug pt-0.5")
	if n.body != "" {
		p.text(ui, clip(n.body, n.is_digest ? 200 : 150), "text-[13] text-muted-foreground leading-snug")
	}

	// Why this interrupted, when it is not the obvious reason: it broke
	// through a quiet identity, or it is the digest standing for the rest.
	if strings.contains(n.why, "break") || n.is_digest {
		p.row(ui, "items-center gap-1.5 pt-0.5")
		p.icon(ui, n.is_digest ? ICON_BELL_OFF : ICON_BELL, "size-3 shrink-0 text-muted-foreground/80")
		p.text(ui, n.why, "text-[11.5] text-muted-foreground/80 truncate min-w-0")
		p.end(ui)
	}

	// Actions: the first is the primary one for a call, the rest outline.
	shown := 0
	for a in n.actions {
		if a.key != "default" {
			shown += 1
		}
	}
	if shown > 0 {
		p.row(ui, "w-full items-center gap-2 pt-1.5")
		k := 0
		for a in n.actions {
			if a.key == "default" {
				continue
			}
			k += 1
			if k > 3 {
				break
			}
			v := sc.Variant.Outline
			if call && k == 1 {
				v = .Default
			}
			p.key(ui, fmt.tprintf("a-%d-%s", n.id, a.key))
			b := sc.button_open(ui, v, .SM, {})
			if p.is_hovered(ui, b) {
				p.apply(ui, sc.button_variant_class(v, {hover = true}), b)
			}
			if call && k == 1 {
				p.icon(ui, ICON_PHONE_INCOMING, "size-3.5")
			}
			if selected {
				p.text(ui, fmt.tprintf("%d", k), "text-[11] font-mono text-muted-foreground")
			}
			p.text(ui, a.label, "whitespace-nowrap")
			sc.button_end(ui)
			if p.clickable(ui, b) && !t.offline {
				op("invoke", n.id, "action", a.key)
				t.gone[n.id] = true
			}
		}
		p.end(ui)
	}
	p.end(ui) // body

	// Time left, as a hairline along the bottom: it stops while the pointer
	// is over the stack, which is the point of drawing it.
	if total := t.total[n.id]; total > 0 && n.urgency != .Critical {
		frac := clamp(f32(t.left[n.id] / total), 0, 1)
		p.div(ui, "absolute left-[3] right-0 bottom-0 h-[2] bg-transparent")
		p.div(ui, fmt.tprintf("h-full w-[%.2f%%] bg-%s/40", frac * 100, tok))
		p.end(ui)
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The process
// ---------------------------------------------------------------------------

@(private = "file")
measure :: proc(off: ^p.Offscreen, t: ^Toasts) -> int {
	h := 0
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		idx := draw_toasts(ui, t)
		p.offscreen_end(off)
		h = int(p.node_rect(&off.ctx, idx).h + 0.999)
	}
	return max(h, 40)
}

@(private = "file")
sync_view :: proc(t: ^Toasts) {
	view_refresh(&t.view, true)
	t.now = wall_ms()
	handles_sync(&t.handles, t.view.notes[:])
	register_view_colors(t.handles[:], t.dark)
	seen := make(map[u32]bool, allocator = context.temp_allocator)
	for &n in t.view.notes {
		seen[n.id] = true
		if _, has := t.left[n.id]; !has {
			ms := f64(n.timeout_ms)
			if ms <= 0 {
				ms = f64(toast_ms_view(&n))
			}
			t.left[n.id] = ms
			t.total[n.id] = ms
			fmt.eprintfln("notify toasts: %s", n.spoken)
		}
	}
	for id in t.left {
		if !seen[id] {
			delete_key(&t.left, id)
			delete_key(&t.total, id)
		}
	}
	for id in t.gone {
		if !seen[id] {
			delete_key(&t.gone, id)
		}
	}
}

toast_ms_view :: proc(n: ^View_Note) -> int {
	switch {
	case n.urgency == .Critical:
		return 0
	case n.is_digest:
		return 12_000
	case n.class == .Person:
		return 8000
	case n.class == .Time:
		return 10_000
	}
	return 6000
}

TOAST_ROOT :: "w-full h-full flex-col bg-popover text-popover-foreground border border-border overflow-hidden"

toasts_main :: proc(args: []string) -> int {
	find_display()
	t := new(Toasts)
	t.dark = theme_dark(args)
	t.tz = local_offset()
	w: Watch
	if !watch_start(&w, "toasts") {
		fmt.eprintln("notify toasts: palm-notifyd is not running")
		return kit.EXIT_UNAVAILABLE
	}

	off := p.offscreen_create(TOAST_W, 1400, 1, TOAST_ROOT)
	load_ui_fonts(&off.fonts, t.dark)
	sc.register_shadcn_theme(t.dark)
	p.set_text_gamma(1.8)

	app: ^p.App
	cur_h := 0
	cur_kbd := p.Keyboard_Mode.None
	last := time.tick_now()

	for !sync.atomic_load(&w.gone) {
		if sync.atomic_exchange(&w.dirty, false) {
			sync_view(t)
		}
		if sync.atomic_exchange(&w.focus, false) {
			t.focused = true
			t.sel = 0
		}
		count := shown_count(t)
		if count == 0 {
			t.focused = false
			if app != nil {
				sync.atomic_store(&w.app, nil)
				p.destroy(app)
				app = nil
				cur_h = 0
			}
			watch_idle(&w, 2000)
			free_all(context.temp_allocator)
			continue
		}
		t.sel = clamp(t.sel, 0, count - 1)

		want_h := measure(off, t)
		want_kbd := t.focused ? p.Keyboard_Mode.Exclusive : p.Keyboard_Mode.On_Demand
		if app == nil || want_h != cur_h || want_kbd != cur_kbd {
			if app != nil {
				sync.atomic_store(&w.app, nil)
				p.destroy(app)
			}
			err: string
			app, err = kit.start(
				{
					title = "Notifications",
					app_id = "palm-notify-toasts",
					width = TOAST_W,
					height = want_h,
					root_class = TOAST_ROOT,
					layer = true,
					layer_level = .Overlay,
					layer_anchor = {.Top, .Right},
					layer_keyboard = want_kbd,
					layer_margin = {10, 10, 0, 0},
				},
				t.dark,
			)
			if err != "" {
				fmt.eprintfln("notify toasts: %s", err)
				return kit.EXIT_FAILED
			}
			register_view_colors(t.handles[:], t.dark)
			sync.atomic_store(&w.app, app)
			cur_h, cur_kbd = want_h, want_kbd
			last = time.tick_now()
		}

		ui, ok := p.frames(app)
		if !ok {
			sync.atomic_store(&w.app, nil)
			p.destroy(app)
			app = nil
			continue
		}
		dt := time.duration_milliseconds(time.tick_since(last))
		last = time.tick_now()
		t.now = wall_ms()
		t.hover = app.win.input.over_surface

		// Count down, unless the pointer is resting on the stack or the
		// keyboard is in it.
		vis := visible(t)
		running := false
		for n, i in vis {
			if i >= TOAST_MAX || n.urgency == .Critical || t.total[n.id] <= 0 {
				continue
			}
			if !t.hover && !t.focused {
				t.left[n.id] -= dt
			}
			running = true
			if t.left[n.id] <= 0 {
				op("hide", n.id)
				t.gone[n.id] = true
			}
		}

		keys(ui, t, vis)
		draw_toasts(ui, t)
		if running {
			// The hairline moves; eight frames a second is plenty for it.
			p.wake_after(app, 125 * time.Millisecond)
		}
		free_all(context.temp_allocator)
	}
	if app != nil {
		p.destroy(app)
	}
	return 0
}

@(private = "file")
keys :: proc(ui: ^p.Ctx, t: ^Toasts, vis: []^View_Note) {
	if !t.focused || len(vis) == 0 {
		return
	}
	count := min(len(vis), TOAST_MAX)
	t.sel += p.key_count(ui, p.KEY_DOWN) + p.key_count(ui, p.KEY_TAB)
	t.sel -= p.key_count(ui, p.KEY_UP)
	t.sel = clamp(t.sel, 0, count - 1)
	n := vis[t.sel]
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		t.focused = false
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) {
		op("invoke", n.id, "action", "default")
		t.gone[n.id] = true
		return
	}
	if p.key_pressed(ui, p.KEY_DELETE, false) || p.key_pressed(ui, p.KEY_BACKSPACE, false) {
		op("dismiss", n.id)
		t.gone[n.id] = true
		return
	}
	k := 0
	for a in n.actions {
		if a.key == "default" {
			continue
		}
		k += 1
		if k <= 3 && p.key_pressed(ui, u32('0' + k), false) {
			op("invoke", n.id, "action", a.key)
			t.gone[n.id] = true
			return
		}
	}
}
