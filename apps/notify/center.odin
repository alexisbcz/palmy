// The notification center: a panel down the right edge with everything that
// arrived, grouped by identity and then by app, each identity's policy at
// the top of its group as the sentence it is, with the one switch people
// reach for ("Quiet until 08:00") beside it.
//
//	notify center [--identity <handle>] [--window] [--dark]
//
// It is where machines' notifications are read (they never interrupt), where
// what a quiet identity held waits, and the only place a count is shown:
// there are no badges anywhere else (cloud/docs/product.md §8).
//
// Keyboard: ↑/↓ choose, Enter opens, R marks read, Delete clears one, 0–9
// filter by identity (0 is all), D do-not-disturb, Q quiet the identity in
// view, Escape closes.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

CENTER_W :: 440

Center :: struct {
	view:     View,
	handles:  [dynamic]string,
	filter:   string, // "" all, else a handle; "-" no identity
	sel:      int,
	rows:     [dynamic]u32, // ids in drawing order, for the keyboard
	dark:     bool,
	tz:       i64,
	now:      i64,
	offline:  bool, // drawn for a screenshot
	quit:     bool,
	keyboard: bool, // the arrows were used: show the selection
	scroll_h: f32,
}

// groups lists the identities that have something to show, in a stable
// order: the device's identities first, then any other, then none.
@(private = "file")
center_identities :: proc(c: ^Center, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	has :: proc(xs: []string, s: string) -> bool {
		for x in xs {
			if x == s {
				return true
			}
		}
		return false
	}
	for h in c.handles {
		any := false
		for n in c.view.notes {
			if n.identity == h {
				any = true
			}
		}
		for p in c.view.policies {
			if p.identity == h {
				any = true
			}
		}
		if any && !has(out[:], h) {
			append(&out, h)
		}
	}
	for n in c.view.notes {
		if n.identity == "" && !has(out[:], "") {
			append(&out, "")
		}
	}
	return out[:]
}

@(private = "file")
policy_of :: proc(c: ^Center, ident: string) -> ^View_Policy {
	for &p in c.view.policies {
		if p.identity == ident {
			return &p
		}
	}
	return nil
}

@(private = "file")
unread_of :: proc(c: ^Center, ident: string, all: bool) -> int {
	k := 0
	for n in c.view.notes {
		if !n.read && !n.held && (all || n.identity == ident) {
			k += 1
		}
	}
	return k
}

draw_center :: proc(ui: ^p.Ctx, c: ^Center) {
	clear(&c.rows)
	idents := center_identities(c)

	// Header.
	p.col(ui, "w-full shrink-0 px-4 pt-4 pb-3 gap-3 border-b border-border")
	p.row(ui, "w-full items-center gap-2 h-[28]")
	p.text(ui, "Notifications", "text-[16] font-semibold")
	unread := unread_of(c, "", true)
	if unread > 0 {
		p.text(ui, fmt.tprintf("%d unread", unread), "text-[12.5] text-muted-foreground")
	}
	p.spacer(ui)
	// Do not disturb: for the whole person, every identity.
	p.key(ui, "dnd")
	dnd := p.row(ui, "items-center gap-2 px-2 h-[28] rounded-md hover:bg-muted cursor-pointer")
	p.icon(ui, ICON_MOON, c.view.dnd ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground")
	p.text(ui, "Do not disturb", "text-[12.5] font-medium whitespace-nowrap")
	sc.switch_(ui, c.view.dnd, .SM)
	p.end(ui)
	if p.clickable(ui, dnd) && !c.offline {
		op("dnd", 0, "on", c.view.dnd ? "false" : "true")
	}
	p.key(ui, "close")
	x := sc.button_open(ui, .Ghost, .Icon_SM, {})
	p.apply(ui, "text-muted-foreground", x)
	if p.is_hovered(ui, x) {
		p.apply(ui, sc.button_variant_class(.Ghost, {hover = true}), x)
	}
	p.icon(ui, ICON_X, "size-4")
	sc.button_end(ui)
	if p.clickable(ui, x) {
		c.quit = true
	}
	p.end(ui)

	// The identity filter: All, then each identity with its unread count.
	p.row(ui, "w-full items-center gap-1.5 flex-wrap")
	chip(ui, c, "", "All", unread, "")
	for h in idents {
		name := h == "" ? "No identity" : identity_name(h)
		chip(ui, c, h == "" ? "-" : h, name, unread_of(c, h, false), ident_token(c.handles[:], h))
	}
	p.end(ui)
	p.end(ui)

	// The list.
	p.key(ui, "list")
	p.col(ui, "flex-1 w-full min-h-0 overflow-y-auto")
	p.col(ui, "w-full pb-4 shrink-0")
	shown := 0
	for h in idents {
		key := h == "" ? "-" : h
		if c.filter != "" && c.filter != key {
			continue
		}
		shown += identity_section(ui, c, h)
	}
	if shown == 0 {
		p.col(ui, "w-full items-center pt-16 px-10 gap-2")
		p.div(ui, "flex-row size-10 items-center justify-center rounded-full bg-muted")
		p.icon(ui, ICON_BELL, "size-5 text-muted-foreground")
		p.end(ui)
		p.text(ui, "Nothing here", "text-[14] font-semibold pt-1")
		p.text(ui, "Notifications from every identity land here. Machines never interrupt; they wait here instead.", "text-[12.5] text-muted-foreground text-center leading-snug")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)

	// Footer.
	p.row(ui, "w-full shrink-0 items-center gap-2 px-4 h-[48] border-t border-border")
	if btn(ui, "Mark all read", .Outline) && !c.offline {
		if c.filter == "" {
			op("read", 0, "all", "true")
		} else {
			op("read", 0, "identity", c.filter == "-" ? "" : c.filter)
		}
	}
	if btn(ui, "Clear read", .Ghost) && !c.offline {
		for n in c.view.notes {
			if n.read && !n.held && (c.filter == "" || n.identity == (c.filter == "-" ? "" : c.filter)) {
				op("clear", n.id)
			}
		}
	}
	p.spacer(ui)
	p.row(ui, "items-center gap-1")
	sc.kbd(ui, "Esc")
	p.text(ui, "close", "text-[11] text-muted-foreground")
	p.end(ui)
	p.end(ui)
}

@(private = "file")
btn :: proc(ui: ^p.Ctx, label: string, v: sc.Variant) -> bool {
	p.key(ui, label)
	idx := sc.button_open(ui, v, .SM, {})
	p.focusable(ui, idx)
	if p.is_hovered(ui, idx) {
		p.apply(ui, sc.button_variant_class(v, {hover = true}), idx)
	}
	if p.focused(ui, idx) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	p.text(ui, label, "whitespace-nowrap")
	sc.button_end(ui)
	return p.activated(ui, idx)
}

@(private = "file")
chip :: proc(ui: ^p.Ctx, c: ^Center, key, label: string, count: int, tok: string) {
	on := c.filter == key
	p.key(ui, fmt.tprintf("chip-%s", key))
	idx := p.row(ui, "items-center gap-1.5 h-[26] px-2.5 rounded-full border cursor-pointer")
	p.apply(ui, on ? "bg-secondary border-border" : "border-transparent hover:bg-muted", idx)
	if tok != "" {
		p.div(ui, fmt.tprintf("size-[7] shrink-0 rounded-full bg-%s", tok))
		p.end(ui)
	}
	p.text(ui, label, on ? "text-[12.5] font-medium whitespace-nowrap" : "text-[12.5] text-muted-foreground whitespace-nowrap")
	if count > 0 {
		p.text(ui, fmt.tprintf("%d", count), "text-[11.5] text-muted-foreground/80")
	}
	p.end(ui)
	if p.clickable(ui, idx) {
		c.filter = key
		c.sel = 0
	}
}

@(private = "file")
identity_section :: proc(ui: ^p.Ctx, c: ^Center, ident: string) -> int {
	tok := ident_token(c.handles[:], ident)
	name := ident == "" ? "No identity" : identity_name(ident)
	pol := policy_of(c, ident)

	notes := make([dynamic]^View_Note, context.temp_allocator)
	for &n in c.view.notes {
		if n.identity == ident {
			append(&notes, &n)
		}
	}

	p.key(ui, fmt.tprintf("sec-%s", ident))
	p.col(ui, "w-full pt-4")
	defer p.end(ui)

	// The identity, and what its policy is doing right now.
	p.row(ui, "w-full items-center gap-2 px-4 pb-2")
	p.div(ui, fmt.tprintf("size-2 shrink-0 rounded-full bg-%s", tok))
	p.end(ui)
	p.text(ui, name, fmt.tprintf("text-[13] font-semibold text-%s", tok))
	p.spacer(ui)
	if u := unread_of(c, ident, false); u > 0 {
		p.text(ui, fmt.tprintf("%d new", u), "text-[12] text-muted-foreground")
	}
	p.end(ui)

	if pol != nil {
		held := pol.hold != .None
		p.key(ui, fmt.tprintf("pol-%s", ident))
		p.col(ui, "mx-4 rounded-lg border border-border bg-muted/40")
		p.row(ui, "w-full items-start gap-2.5 px-3 pt-2.5 pb-2")
		p.icon(ui, held ? ICON_BELL_OFF : ICON_BELL, "size-4 shrink-0 mt-[1] text-muted-foreground")
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		p.text(ui, pol.sentence, "text-[12.5] font-medium leading-snug")
		state := "Notifications are on"
		switch pol.hold {
		case .Quiet:
			state = pol.hold_ends != "" ? fmt.tprintf("Quiet now, until %s", pol.hold_ends) : "Quiet now"
		case .Dnd:
			state = pol.hold_ends != "" ? fmt.tprintf("Do not disturb, until %s", pol.hold_ends) : "Do not disturb"
		case .None:
		}
		p.text(ui, state, "text-[11.5] text-muted-foreground")
		p.end(ui)
		p.end(ui)
		p.key(ui, fmt.tprintf("q-%s", ident))
		q := p.row(ui, "w-full items-center gap-2 px-3 h-[34] border-t border-border cursor-pointer hover:bg-muted/60")
		// The switch is "held right now", whatever holds it: turning it off
		// during quiet hours sets them aside until they end, and turning it
		// on is a quiet until the morning.
		label := held ? (pol.hold_ends != "" ? fmt.tprintf("Quiet until %s", pol.hold_ends) : "Quiet") : fmt.tprintf("Quiet %s until 08:00", name)
		p.text(ui, label, "flex-1 min-w-0 text-[12] text-muted-foreground truncate")
		sc.switch_(ui, held, .SM)
		p.end(ui)
		if p.clickable(ui, q) && !c.offline {
			quiet_toggle(ident, held)
		}
		p.end(ui)
	}

	if len(notes) == 0 {
		p.text(ui, "Nothing new.", "px-4 pt-3 text-[12.5] text-muted-foreground")
		return 1
	}

	// By app, the app with the newest notification first.
	apps := make([dynamic]string, context.temp_allocator)
	for n in notes {
		found := false
		for a in apps {
			if a == n.app {
				found = true
			}
		}
		if !found {
			append(&apps, n.app)
		}
	}
	for app in apps {
		group := make([dynamic]^View_Note, context.temp_allocator)
		for n in notes {
			if n.app == app {
				append(&group, n)
			}
		}
		first := group[0]
		p.row(ui, "w-full items-center gap-1.5 px-4 pt-3.5 pb-1")
		p.icon(ui, class_icon(first), "size-3.5 text-muted-foreground")
		p.text(ui, strings.to_upper(first.app_label, context.temp_allocator), "text-[11] font-semibold tracking-wide text-muted-foreground")
		p.text(ui, fmt.tprintf("%d", len(group)), "text-[11] text-muted-foreground/60")
		p.end(ui)
		for n in group {
			item(ui, c, n, tok)
		}
	}
	return 1
}

@(private = "file")
item :: proc(ui: ^p.Ctx, c: ^Center, n: ^View_Note, tok: string) {
	k := len(c.rows)
	append(&c.rows, n.id)
	selected := c.keyboard && c.sel == k
	p.key(ui, fmt.tprintf("n-%d", n.id))
	row := p.row(ui, "mx-2 items-start gap-2.5 px-2 py-2 rounded-md cursor-pointer")
	p.apply(ui, selected ? "bg-accent" : "hover:bg-accent/60", row)
	defer p.end(ui)

	// Unread: a dot in the identity's colour. Read: nothing.
	p.div(ui, "w-[8] pt-[6] shrink-0 items-center")
	if !n.read && !n.held {
		p.div(ui, fmt.tprintf("size-[7] rounded-full bg-%s", tok))
		p.end(ui)
	}
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.row(ui, "w-full items-baseline gap-2")
	p.text(ui, clip(n.title, 70), (n.read || n.held) ? "flex-1 min-w-0 text-[13] font-medium text-muted-foreground truncate" : "flex-1 min-w-0 text-[13] font-semibold truncate")
	p.text(ui, when_text(n.created, c.now, c.tz), "text-[11.5] text-muted-foreground/80 whitespace-nowrap")
	p.end(ui)
	if n.body != "" {
		p.text(ui, clip(strings.trim_space(n.body), 140), "text-[12.5] text-muted-foreground leading-snug")
	}
	if n.held {
		p.row(ui, "items-center gap-1.5 pt-1")
		sc.badge(ui, "Held", .Secondary)
		p.text(ui, n.why, "text-[11.5] text-muted-foreground truncate min-w-0")
		p.end(ui)
	} else if n.delivery != .Toast && n.why != "" && !n.is_digest {
		// Why this did not interrupt, in the policy's words.
		p.text(ui, n.why, "text-[11.5] text-muted-foreground/70 pt-0.5")
	}
	acts := 0
	for a in n.actions {
		if a.key != "default" {
			acts += 1
		}
	}
	if acts > 0 && !n.read {
		p.row(ui, "items-center gap-1.5 pt-1.5")
		for a in n.actions {
			if a.key == "default" {
				continue
			}
			p.key(ui, fmt.tprintf("ca-%d-%s", n.id, a.key))
			b := sc.button_open(ui, .Outline, .XS, {})
			if p.is_hovered(ui, b) {
				p.apply(ui, sc.button_variant_class(.Outline, {hover = true}), b)
			}
			p.text(ui, a.label, "whitespace-nowrap")
			sc.button_end(ui)
			if p.clickable(ui, b) && !c.offline {
				op("invoke", n.id, "action", a.key)
			}
		}
		p.end(ui)
	}
	p.end(ui)

	if p.clickable(ui, row) && !c.offline {
		c.sel = k
		op("invoke", n.id, "action", "default")
	}
}

// quiet_toggle is the switch: a one-off quiet until the morning, on or off.
// Quiet hours stay as they are; this is the "Quiet Northwind until 08:00"
// the shell's identity menu offers, from here.
quiet_toggle :: proc(ident: string, on: bool) {
	op("quiet", 0, "identity", ident, "mode", "add", "sentence", on ? "resume" : "quiet until 08:00")
}

@(private = "file")
center_keys :: proc(ui: ^p.Ctx, c: ^Center) {
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		c.quit = true
		return
	}
	moved := p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP)
	if moved != 0 {
		c.keyboard = true
	}
	c.sel += moved
	c.sel = clamp(c.sel, 0, max(len(c.rows) - 1, 0))
	if c.offline {
		return
	}
	if len(c.rows) > 0 {
		id := c.rows[c.sel]
		if p.key_pressed(ui, p.KEY_RETURN, false) {
			op("invoke", id, "action", "default")
		}
		if p.key_pressed(ui, 'r', false) {
			op("read", id)
		}
		if p.key_pressed(ui, p.KEY_DELETE, false) {
			op("clear", id)
		}
	}
	if p.key_pressed(ui, 'd', false) {
		op("dnd", 0, "on", c.view.dnd ? "false" : "true")
	}
	idents := center_identities(c)
	if p.key_pressed(ui, '0', false) {
		c.filter = ""
	}
	for h, i in idents {
		if i < 9 && p.key_pressed(ui, u32('1' + i), false) {
			c.filter = h == "" ? "-" : h
			c.sel = 0
		}
	}
	if p.key_pressed(ui, 'q', false) && c.filter != "" && c.filter != "-" {
		if pol := policy_of(c, c.filter); pol != nil {
			quiet_toggle(c.filter, pol.hold != .None)
		}
	}
}

center_sync :: proc(c: ^Center) {
	view_refresh(&c.view, false)
	c.now = wall_ms()
	handles_sync(&c.handles, c.view.notes[:])
	for pol in c.view.policies {
		found := false
		for h in c.handles {
			if h == pol.identity {
				found = true
			}
		}
		if !found && pol.identity != "*" {
			append(&c.handles, strings.clone(pol.identity))
		}
	}
	register_view_colors(c.handles[:], c.dark)
}

center_main :: proc(args: []string) -> int {
	c := new(Center)
	c.dark = theme_dark(args)
	c.tz = local_offset()
	window := false
	for a, i in args {
		switch a {
		case "--window":
			window = true
		case "--identity":
			if i + 1 < len(args) {
				c.filter = args[i + 1]
			}
		}
	}
	if c.filter == "none" {
		c.filter = "-"
	}
	w: Watch
	if !watch_start(&w, "center") {
		fmt.eprintln("notify center: palm-notifyd is not running")
		return kit.EXIT_UNAVAILABLE
	}
	cfg := p.Config {
		title      = "Notifications",
		app_id     = "palm-notify-center",
		width      = CENTER_W,
		height     = 760,
		root_class = "w-full h-full flex-col bg-background text-foreground border-l border-border overflow-hidden",
	}
	if !window {
		cfg.layer = true
		cfg.layer_level = .Overlay
		cfg.layer_anchor = {.Top, .Right, .Bottom}
		cfg.layer_keyboard = .Exclusive
		cfg.height = 0
	}
	app, err := kit.start(cfg, c.dark)
	if err != "" && !window {
		// No layer shell (another compositor): an ordinary window will do.
		cfg.layer = false
		cfg.height = 760
		app, err = kit.start(cfg, c.dark)
	}
	if err != "" {
		fmt.eprintfln("notify center: %s", err)
		return kit.EXIT_FAILED
	}
	sync.atomic_store(&w.app, app)
	for ui in p.frames(app) {
		if sync.atomic_load(&w.gone) {
			break
		}
		if sync.atomic_exchange(&w.dirty, false) {
			center_sync(c)
		}
		sync.atomic_exchange(&w.center, false)
		c.now = wall_ms()
		center_keys(ui, c)
		draw_center(ui, c)
		if c.quit {
			break
		}
		// "2 min" ages on its own.
		p.wake_after(app, 30 * time.Second)
	}
	sync.atomic_store(&w.app, nil)
	p.destroy(app)
	return 0
}
