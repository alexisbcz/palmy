// network — a NetworkManager front end for palmy.
//
// Interfaces on the left, the selected interface's addressing and the live
// Wi-Fi scan on the right. Every number on screen came out of `nmcli -t`; see
// nm.odin for the parsing and the worker thread that runs it.
//
// Keyboard, because this compositor build cannot synthesize pointer clicks:
//
//	Tab / Shift-Tab   move between the toolbar, interfaces, networks and saved
//	Up / Down         move within the focused list   Home / End  ends
//	Left / Right      move along the toolbar
//	Enter / Space     activate — connect to the selected network
//	W                 toggle the Wi-Fi radio
//	R                 re-read interfaces             S  rescan for networks
//	Escape            close the dialog, or quit
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Section :: enum {
	Toolbar,
	Devices,
	Networks,
	Saved,
}

TOOLBAR_ITEMS :: 3 // Wi-Fi switch, Scan, Refresh

// Row pitches, which the list windowing below depends on being exact.
DEV_ROW :: f32(48)
AP_ROW :: f32(54)
SAVED_ROW :: f32(40)
ROW_GAP :: f32(4)

UI :: struct {
	st:         ^Store,
	section:    Section,
	sel:        [Section]int,
	first:      [Section]int, // first row drawn, for the windowed lists
	cap:        [Section]int, // how many rows fit, measured last frame
	counts:     [Section]int,
	picked_dev: bool, // the user chose an interface; stop auto-picking

	// The list viewports, so the next frame knows how tall they were.
	view_id:    [Section]u64,

	busy:       string, // what the worker is doing, "" when idle
	pending:    int,

	// Connect dialog.
	dialog:     bool,
	dlg_ssid:   string,
	dlg_desc:   string,
	pw:         [dynamic]u8,
	reveal:     bool,
}

main :: proc() {
	// `--shots <dir>` renders the panel offscreen and exits without opening a
	// window and without running a single nmcli command. See shot.odin.
	for a, i in os.args[1:] {
		if a == "--shots" || a == "-shots" {
			rest := os.args[1:]
			if i + 1 >= len(rest) {
				fmt.eprintln("network --shots <dir>")
				os.exit(2)
			}
			os.exit(shots(rest[i + 1]))
		}
	}

	// The window class is "palmy" like every app here. NETWORK_APP_ID overrides
	// it, which is only useful while several of these applets are being driven
	// on one desktop and their capture scripts match windows by class.
	app, err := kit.start(
		{
			title = "Network",
			app_id = os.get_env("NETWORK_APP_ID", context.allocator),
			width = 1180,
			height = 772,
			min_width = 920,
			min_height = 560,
		},
	)
	if err != "" {
		fmt.eprintfln("network: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	store: Store
	store_start(&store)
	// Interfaces and whatever is already in NetworkManager's scan cache land
	// immediately; the fresh scan follows and replaces the list when it is done.
	submit(&store, .Refresh)
	submit(&store, .Wifi)
	submit(&store, .Rescan)

	ui := UI {
		st      = &store,
		section = .Networks,
		cap     = {.Toolbar = TOOLBAR_ITEMS, .Devices = 8, .Networks = 8, .Saved = 8},
	}
	ui.pw = make([dynamic]u8)
	defer delete(ui.pw)

	for ctx in p.frames(app) {
		// What the worker is up to, read under the queue lock before the data
		// lock is taken; `busy` is one of job_label's static strings.
		ui.busy, ui.pending = progress(&store)

		sync.mutex_lock(&store.mu)
		// Escape belongs to the dialog when one is open; it must not also close
		// the window on the frame that dismisses it.
		modal := ui.dialog
		keys(ctx, &ui)
		build(ctx, &ui)
		sync.mutex_unlock(&store.mu)

		// A job is in flight: keep asking for frames so the spinner turns and
		// the result appears the moment the worker publishes it. Otherwise the
		// loop goes back to blocking in poll and the window costs nothing.
		if ui.pending > 0 || ui.dialog {
			p.redraw(ctx)
		}
		if p.shortcut(ctx, 'q', {.Ctrl}) || (!modal && !ui.dialog && p.key_pressed(ctx, p.KEY_ESCAPE)) {
			p.quit_app(app)
		}
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

// keys runs with the store locked, so it can read the lists it is moving
// through. It never calls nmcli itself — everything goes on the worker queue.
keys :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	if u.dialog {
		dialog_keys(ctx, u)
		return
	}

	if p.key_pressed(ctx, p.KEY_TAB) {
		n := len(Section)
		back := .Shift in ctx.input.mods
		u.section = Section((int(u.section) + (back ? n - 1 : 1)) % n)
	}

	count := u.counts[u.section]
	step := 0
	if p.key_pressed(ctx, p.KEY_DOWN) {step += 1}
	if p.key_pressed(ctx, p.KEY_UP) {step -= 1}
	if u.section == .Toolbar {
		if p.key_pressed(ctx, p.KEY_RIGHT) {step += 1}
		if p.key_pressed(ctx, p.KEY_LEFT) {step -= 1}
	}
	if count > 0 {
		if step != 0 {
			u.sel[u.section] = clamp(u.sel[u.section] + step, 0, count - 1)
			if u.section == .Devices {u.picked_dev = true}
		}
		if p.key_pressed(ctx, p.KEY_HOME) {u.sel[u.section] = 0}
		if p.key_pressed(ctx, p.KEY_END) {u.sel[u.section] = count - 1}
	}

	if p.key_pressed(ctx, 'r') {submit(s, .Refresh)}
	if p.key_pressed(ctx, 's') {submit(s, .Rescan)}
	toggle_radio := p.key_pressed(ctx, 'w')

	if p.key_pressed(ctx, p.KEY_RETURN) || p.key_pressed(ctx, p.KEY_SPACE) {
		switch u.section {
		case .Toolbar:
			switch u.sel[.Toolbar] {
			case 0:
				toggle_radio = true
			case 1:
				submit(s, .Rescan)
			case 2:
				submit(s, .Refresh)
			}
		case .Networks:
			if i := u.sel[.Networks]; i >= 0 && i < len(s.aps) {
				open_dialog(u, s.aps[i])
			}
		case .Devices:
			u.picked_dev = true
		case .Saved:
			// Jump to the interface a saved profile is running on.
			if i := u.sel[.Saved]; i >= 0 && i < len(s.saved) && s.saved[i].device != "" {
				for d, k in s.devices {
					if d.name == s.saved[i].device {
						u.section = .Devices
						u.sel[.Devices] = k
						u.picked_dev = true
					}
				}
			}
		}
	}

	if toggle_radio {
		submit(s, s.radio_on ? .Radio_Off : .Radio_On)
	}
}

open_dialog :: proc(u: ^UI, ap: Ap) {
	if ap.active {
		set_message_locked(u.st, .Info, fmt.tprintf("Already connected to %s", ap.ssid))
		return
	}
	if ap.hidden {
		// `nmcli device wifi connect` needs a real SSID, and a hidden network
		// does not advertise one.
		set_message_locked(u.st, .Bad, "This network does not broadcast an SSID")
		return
	}
	free_dialog(u)
	u.dialog = true
	u.reveal = false
	clear(&u.pw)
	u.dlg_ssid = strings.clone(ap.ssid)
	u.dlg_desc = fmt.aprintf("%s · channel %d · %s · %s", ap.security, ap.channel, ap.band, ap.rate)
}

close_dialog :: proc(u: ^UI) {
	u.dialog = false
	free_dialog(u)
	clear(&u.pw)
}

free_dialog :: proc(u: ^UI) {
	if u.dlg_ssid != "" {delete(u.dlg_ssid);u.dlg_ssid = ""}
	if u.dlg_desc != "" {delete(u.dlg_desc);u.dlg_desc = ""}
}

// set_message_locked is `set_message` for a caller already holding the lock.
set_message_locked :: proc(s: ^Store, kind: Msg_Kind, text: string) {
	msg := strings.clone(text)
	if s.message != "" {delete(s.message)}
	s.message = msg
	s.msg_kind = kind
}

dialog_keys :: proc(ctx: ^p.Ctx, u: ^UI) {
	if p.key_pressed(ctx, p.KEY_ESCAPE) {
		close_dialog(u)
		return
	}
	if p.shortcut(ctx, 'r', {.Ctrl}) {
		u.reveal = !u.reveal
	}
	if p.key_pressed(ctx, p.KEY_BACKSPACE) && len(u.pw) > 0 {
		resize(&u.pw, rune_start(u.pw[:]))
	}
	for c in transmute([]u8)p.typed_text(ctx) {
		if c >= 0x20 && c != 0x7f {
			append(&u.pw, c)
		}
	}
	if p.key_pressed(ctx, p.KEY_RETURN) {
		connect_now(u)
	}
}

connect_now :: proc(u: ^UI) {
	submit(u.st, .Connect, u.dlg_ssid, string(u.pw[:]))
	set_message_locked(u.st, .Info, fmt.tprintf("Connecting to %s…", u.dlg_ssid))
	close_dialog(u)
}

// rune_start is the byte index of the last rune in a UTF-8 buffer, so Backspace
// removes a whole character rather than a byte.
rune_start :: proc(b: []u8) -> int {
	i := len(b) - 1
	for i > 0 && (b[i] & 0xc0) == 0x80 {
		i -= 1
	}
	return i
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

build :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	u.counts = {
		.Toolbar  = TOOLBAR_ITEMS,
		.Devices  = len(s.devices),
		.Networks = len(s.aps),
		.Saved    = len(s.saved),
	}
	for sec in Section {
		u.sel[sec] = clamp(u.sel[sec], 0, max(0, u.counts[sec] - 1))
	}

	// Default the interface selection to whatever is carrying real traffic.
	if !u.picked_dev {
		for d, i in s.devices {
			if d.state == .Connected && d.kind != "loopback" && d.ip4 != "" {
				u.sel[.Devices] = i
				break
			}
		}
	}

	// Lists are windowed rather than scrolled: palmy owns the scroll offset of
	// an `overflow-scroll` container and does not expose it, so there is no way
	// to scroll a keyboard selection into view. Drawing a window of rows is
	// under this app's control, keeps the selection visible by construction,
	// and is what a list widget does under the hood anyway. The row count comes
	// off the viewport measured on the previous frame.
	measure_window(ctx, u, .Devices, DEV_ROW)
	measure_window(ctx, u, .Networks, AP_ROW)
	measure_window(ctx, u, .Saved, SAVED_ROW)
	wheel(ctx, u)
	for sec in Section {
		slide(&u.first[sec], u.sel[sec], u.counts[sec], u.cap[sec])
	}

	p.col(ctx, "w-full h-full relative overflow-hidden")
	defer p.end(ctx)

	header(ctx, u)

	p.row(ctx, "w-full flex-1 items-stretch overflow-hidden")
	sidebar(ctx, u)
	detail_column(ctx, u)
	p.end(ctx)

	status_bar(ctx, u)

	if u.dialog {
		connect_dialog(ctx, u)
	}
}

measure_window :: proc(ctx: ^p.Ctx, u: ^UI, sec: Section, row: f32) {
	h := p.rect_of(ctx, u.view_id[sec]).h
	if h <= 0 {
		return // first frame; the seeded default stands
	}
	u.cap[sec] = max(1, int((h + ROW_GAP) / (row + ROW_GAP)))
}

// slide keeps `sel` inside the window of `cap` rows starting at `first`.
slide :: proc(first: ^int, sel, count, cap: int) {
	if count <= cap {
		first^ = 0
		return
	}
	if sel < first^ {first^ = sel}
	if sel >= first^ + cap {first^ = sel - cap + 1}
	first^ = clamp(first^, 0, count - cap)
}

// wheel scrolls whichever list the pointer is over. palmy only applies the
// wheel to `overflow-scroll` containers, so with none in the tree the delta
// arrives here untouched.
wheel :: proc(ctx: ^p.Ctx, u: ^UI) {
	dy := ctx.input.scroll.y
	if dy == 0 {
		return
	}
	m := p.mouse_pos(ctx)
	step := dy > 0 ? 1 : -1
	for sec in Section {
		if sec == .Toolbar {
			continue
		}
		r := p.rect_of(ctx, u.view_id[sec])
		if r.h <= 0 || m.x < r.x || m.x >= r.x + r.w || m.y < r.y || m.y >= r.y + r.h {
			continue
		}
		over := max(0, u.counts[sec] - u.cap[sec])
		u.first[sec] = clamp(u.first[sec] + step, 0, over)
		// Keep the selection inside the window the wheel just moved.
		u.sel[sec] = clamp(u.sel[sec], u.first[sec], u.first[sec] + u.cap[sec] - 1)
	}
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

header :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	p.row(ctx, "w-full h-[60] shrink-0 items-center gap-3 px-5 border-b border-border bg-card")
	defer p.end(ctx)

	p.div(ctx, "size-9 shrink-0 rounded-lg bg-primary flex-row items-center justify-center")
	p.icon(ctx, ICON_NETWORK, "size-[18] text-primary-foreground")
	p.end(ctx)

	p.col(ctx, "gap-1.5 shrink-0")
	p.text(ctx, "Network", "text-sm leading-none font-semibold whitespace-nowrap")
	p.text(ctx, headline(u), "text-xs leading-none text-muted-foreground whitespace-nowrap")
	p.end(ctx)

	p.spacer(ctx, "flex-1")

	if u.pending > 0 {
		p.row(ctx, "h-7 shrink-0 items-center gap-2 px-2.5 rounded-md bg-muted")
		spin(ctx, p.elapsed(ctx))
		p.text(
			ctx,
			u.busy == "" ? "Working" : u.busy,
			"text-xs text-muted-foreground whitespace-nowrap",
		)
		p.style(ctx).shrink = 0
		p.end(ctx)
	}

	// Toolbar slot 0: the radio switch.
	on := u.section == .Toolbar && u.sel[.Toolbar] == 0
	idx := p.row(ctx, "h-8 shrink-0 items-center gap-2.5 px-2.5 rounded-lg transition")
	if on {
		p.apply(ctx, "bg-accent ring-1 ring-ring")
	} else if p.is_hovered(ctx, idx) {
		p.apply(ctx, "bg-accent")
	}
	if p.clickable(ctx, idx) {
		u.section = .Toolbar
		u.sel[.Toolbar] = 0
		submit(s, s.radio_on ? .Radio_Off : .Radio_On)
	}
	p.icon(ctx, s.radio_on ? ICON_WIFI : ICON_WIFI_OFF, "size-4 shrink-0")
	p.apply(ctx, s.radio_on ? "text-foreground" : "text-muted-foreground")
	p.text(ctx, "Wi-Fi", "text-sm font-medium whitespace-nowrap")
	p.style(ctx).shrink = 0
	sc.switch_(ctx, s.radio_on)
	p.end(ctx)

	sc.separator(ctx, .Vertical, "h-5 mx-1")

	toolbar_button(ctx, u, 1, ICON_SATELLITE_DISH, "Scan", .Rescan)
	toolbar_button(ctx, u, 2, ICON_ROTATE_CW, "Refresh", .Refresh)
}

toolbar_button :: proc(ctx: ^p.Ctx, u: ^UI, slot: int, ic: p.Icon, label: string, job: Job_Kind) {
	on := u.section == .Toolbar && u.sel[.Toolbar] == slot
	at := p.node_count(ctx)
	hov := p.hovered(ctx, p.node_id(ctx, at))
	idx := sc.button_open(ctx, .Outline, .SM, sc.State{hover = hov, focus = on})
	if p.clickable(ctx, idx) {
		u.section = .Toolbar
		u.sel[.Toolbar] = slot
		submit(u.st, job)
	}
	p.icon(ctx, ic, "size-3.5 shrink-0")
	p.text(ctx, label, "whitespace-nowrap")
	p.style(ctx).shrink = 0
	sc.button_end(ctx)
}

headline :: proc(u: ^UI) -> string {
	s := u.st
	if !s.loaded {
		return "Reading NetworkManager…"
	}
	up := 0
	primary := ""
	for d in s.devices {
		if d.state == .Connected {up += 1}
		if primary == "" && d.state == .Connected && d.kind != "loopback" && d.ip4 != "" {
			primary = d.conn
		}
	}
	if primary == "" {
		return fmt.tprintf("%d interfaces · nothing carrying traffic", len(s.devices))
	}
	return fmt.tprintf("%d interfaces · %d up · %s", len(s.devices), up, primary)
}

// spin is a busy indicator. palmy has no `animate-spin` and icons are paths
// with no transform, so the ring is eight dots whose opacity rotates off the
// frame clock.
spin :: proc(ctx: ^p.Ctx, t: f32) {
	STEPS :: 8
	unit := [STEPS][2]f32{
		{1, 0},
		{0.707, 0.707},
		{0, 1},
		{-0.707, 0.707},
		{-1, 0},
		{-0.707, -0.707},
		{0, -1},
		{0.707, -0.707},
	}
	phase := int(t * 8) % STEPS
	p.div(ctx, "size-[14] shrink-0 relative")
	defer p.end(ctx)
	for i in 0 ..< STEPS {
		age := (i - phase + STEPS) % STEPS
		p.div(ctx, "absolute size-[2.5] rounded-full bg-muted-foreground")
		st := p.style(ctx)
		st.inset[p.LEFT] = p.px(5.75 + unit[i][0] * 5)
		st.inset[p.TOP] = p.px(5.75 + unit[i][1] * 5)
		st.opacity = 1 - f32(age) / f32(STEPS)
		p.end(ctx)
	}
}

// ---------------------------------------------------------------------------
// Sidebar: interfaces and saved profiles
// ---------------------------------------------------------------------------

sidebar :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	p.col(ctx, "w-[300] h-full shrink-0 border-r border-border bg-sidebar overflow-hidden p-3 gap-1")
	defer p.end(ctx)

	group_label(ctx, "Interfaces", len(s.devices))
	more_row(ctx, u.first[.Devices], "above")

	view := p.col(ctx, "w-full flex-1 min-h-[52] gap-1 overflow-hidden")
	u.view_id[.Devices] = p.node_id(ctx, view)
	if !s.loaded {
		for i in 0 ..< 5 {
			p.div(ctx, "w-full shrink-0 rounded-lg bg-muted")
			st := p.style(ctx)
			st.h = p.px(DEV_ROW)
			st.opacity = 1 - f32(i) * 0.15
			p.end(ctx)
		}
	}
	lo, hi := window(u, .Devices)
	for i in lo ..< hi {
		device_row(ctx, u, s.devices[i], i)
	}
	p.end(ctx)
	more_row(ctx, u.counts[.Devices] - hi, "below")

	p.div(ctx, "h-2 shrink-0")
	p.end(ctx)

	group_label(ctx, "Saved networks", len(s.saved))
	more_row(ctx, u.first[.Saved], "above")

	sview := p.col(ctx, "w-full flex-1 min-h-[44] gap-1 overflow-hidden")
	u.view_id[.Saved] = p.node_id(ctx, sview)
	slo, shi := window(u, .Saved)
	for i in slo ..< shi {
		saved_row(ctx, u, s.saved[i], i)
	}
	if s.loaded && len(s.saved) == 0 {
		p.text(ctx, "No saved profiles", "px-2.5 py-2 text-xs text-muted-foreground")
	}
	p.end(ctx)
	more_row(ctx, u.counts[.Saved] - shi, "below")
}

window :: proc(u: ^UI, sec: Section) -> (lo, hi: int) {
	lo = clamp(u.first[sec], 0, max(0, u.counts[sec]))
	hi = min(lo + u.cap[sec], u.counts[sec])
	return
}

// more_row is the "3 more" affordance above or below a windowed list.
more_row :: proc(ctx: ^p.Ctx, n: int, where_: string) {
	if n <= 0 {
		return
	}
	p.row(ctx, "w-full h-4 shrink-0 items-center gap-1 px-2.5")
	defer p.end(ctx)
	p.icon(ctx, where_ == "above" ? ICON_CHEVRON_UP : ICON_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	p.textf(ctx, "text-[10.5] leading-none text-muted-foreground whitespace-nowrap", "%d more", n)
}

device_row :: proc(ctx: ^p.Ctx, u: ^UI, d: Dev, i: int) {
	p.key(ctx, d.name)
	on := u.section == .Devices && u.sel[.Devices] == i
	cur := u.sel[.Devices] == i

	idx := p.row(ctx, "w-full shrink-0 items-center gap-2.5 px-2.5 rounded-lg transition")
	p.style(ctx).h = p.px(DEV_ROW)
	if on {
		p.apply(ctx, "bg-accent ring-1 ring-ring")
	} else if cur {
		p.apply(ctx, "bg-accent")
	} else if p.is_hovered(ctx, idx) {
		p.apply(ctx, "bg-accent/60")
	}
	if p.clickable(ctx, idx) {
		u.section = .Devices
		u.sel[.Devices] = i
		u.picked_dev = true
	}
	defer p.end(ctx)

	p.icon(ctx, dev_icon(d.kind), "size-4 shrink-0")
	p.apply(ctx, d.state == .Connected ? "text-foreground" : "text-muted-foreground")

	p.col(ctx, "flex-1 gap-1 min-w-0")
	p.text(ctx, d.name, "text-[13] leading-[16] font-medium truncate")
	p.text(
		ctx,
		d.conn != "" ? d.conn : state_word(d.state),
		"text-[11] leading-[14] text-muted-foreground truncate",
	)
	p.end(ctx)

	state_dot(ctx, d.state)
}

saved_row :: proc(ctx: ^p.Ctx, u: ^UI, v: Saved, i: int) {
	p.key(ctx, v.uuid)
	on := u.section == .Saved && u.sel[.Saved] == i

	idx := p.row(ctx, "w-full shrink-0 items-center gap-2.5 px-2.5 rounded-lg transition")
	p.style(ctx).h = p.px(SAVED_ROW)
	if on {
		p.apply(ctx, "bg-accent ring-1 ring-ring")
	} else if p.is_hovered(ctx, idx) {
		p.apply(ctx, "bg-accent/60")
	}
	if p.clickable(ctx, idx) {
		u.section = .Saved
		u.sel[.Saved] = i
	}
	defer p.end(ctx)

	p.icon(ctx, saved_icon(v.kind), "size-4 shrink-0 text-muted-foreground")

	p.col(ctx, "flex-1 gap-1 min-w-0")
	p.text(ctx, v.name, "text-[13] leading-[16] font-medium truncate")
	p.text(ctx, v.kind, "text-[11] leading-[14] text-muted-foreground truncate")
	p.end(ctx)

	if v.active {
		sc.badge(ctx, "Active", .Secondary)
	} else if !v.autoconnect {
		p.text(ctx, "manual", "text-[10.5] text-muted-foreground whitespace-nowrap")
		p.style(ctx).shrink = 0
	}
}

group_label :: proc(ctx: ^p.Ctx, text: string, n: int) {
	p.row(ctx, "w-full h-7 shrink-0 items-center gap-1.5 px-2.5")
	defer p.end(ctx)
	p.text(
		ctx,
		text,
		"text-[11] leading-none font-semibold uppercase tracking-wider text-muted-foreground whitespace-nowrap",
	)
	p.style(ctx).shrink = 0
	p.spacer(ctx, "flex-1")
	p.textf(ctx, "text-[11] leading-none text-muted-foreground", "%d", n)
}

state_dot :: proc(ctx: ^p.Ctx, st: Dev_State) {
	p.div(ctx, "size-2 shrink-0 rounded-full")
	switch st {
	case .Connected:
		p.apply(ctx, "bg-emerald-500")
	case .Connecting:
		p.apply(ctx, "bg-amber-500")
	case .Disconnected:
		p.apply(ctx, "bg-foreground/25")
	case .Unavailable, .Unmanaged, .Unknown:
		p.apply(ctx, "bg-foreground/10")
	}
	p.end(ctx)
}

// ---------------------------------------------------------------------------
// Right column: the selected interface, then the scan
// ---------------------------------------------------------------------------

detail_column :: proc(ctx: ^p.Ctx, u: ^UI) {
	// On a wide window the panel stops growing and centres, the way a settings
	// pane does; the cards would otherwise stretch to 1800px of whitespace.
	p.col(ctx, "flex-1 h-full items-center overflow-hidden")
	defer p.end(ctx)

	p.col(ctx, "w-full max-w-[1080] h-full overflow-hidden")
	defer p.end(ctx)

	p.div(ctx, "w-full shrink-0 px-5 pt-5 pb-4")
	detail_card(ctx, u)
	p.end(ctx)

	p.div(ctx, "w-full flex-1 px-5 pb-5 overflow-hidden")
	wifi_card(ctx, u)
	p.end(ctx)
}

detail_card :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	sc.card_open(ctx, .Default, false, "w-full shrink-0")
	defer sc.card_end(ctx)

	if !s.loaded || len(s.devices) == 0 {
		p.col(ctx, "px-4 gap-3 w-full")
		p.div(ctx, "w-[200] h-4 rounded-md bg-muted")
		p.end(ctx)
		p.div(ctx, "w-[320] h-3 rounded-md bg-muted opacity-70")
		p.end(ctx)
		p.div(ctx, "w-full h-3 rounded-md bg-muted opacity-50")
		p.end(ctx)
		p.end(ctx)
		return
	}
	d := s.devices[u.sel[.Devices]]

	p.row(ctx, "w-full px-4 items-center gap-3.5")
	p.div(ctx, "size-11 shrink-0 rounded-xl bg-muted flex-row items-center justify-center")
	p.icon(ctx, dev_icon(d.kind), "size-5")
	p.apply(ctx, d.state == .Connected ? "text-foreground" : "text-muted-foreground")
	p.end(ctx)

	p.col(ctx, "flex-1 gap-2 min-w-0")
	p.row(ctx, "items-center gap-2")
	p.text(ctx, d.conn != "" ? d.conn : d.name, "text-base leading-none font-semibold truncate")
	p.style(ctx).shrink = 0
	switch d.state {
	case .Connected:
		ok_pill(ctx, d.external ? "Up, external" : "Connected")
	case .Connecting:
		sc.badge(ctx, "Connecting", .Secondary)
	case .Disconnected, .Unavailable, .Unmanaged, .Unknown:
		sc.badge(ctx, state_word(d.state), .Outline)
	}
	p.end(ctx)
	if d.hwaddr == "" {
		p.textf(
			ctx,
			"text-xs leading-none text-muted-foreground truncate",
			"%s · %s",
			d.name,
			pretty_kind(d.kind),
		)
	} else {
		p.textf(
			ctx,
			"text-xs leading-none text-muted-foreground truncate",
			"%s · %s · %s",
			d.name,
			pretty_kind(d.kind),
			d.hwaddr,
		)
	}
	p.end(ctx)

	// A connected wifi interface gets its live signal here, off the same scan
	// the list below is drawn from.
	if d.kind == "wifi" && d.state == .Connected {
		for ap in s.aps {
			if !ap.active {
				continue
			}
			p.row(ctx, "shrink-0 items-center gap-3")
			signal_bars(ctx, ap.signal, 20)
			p.col(ctx, "items-end gap-1.5 shrink-0")
			p.textf(ctx, "text-sm leading-none font-semibold", "%d%%", ap.signal)
			p.textf(
				ctx,
				"text-[11] leading-none text-muted-foreground whitespace-nowrap",
				"%s · ch %d",
				ap.band,
				ap.channel,
			)
			p.end(ctx)
			p.end(ctx)
			break
		}
	}
	p.end(ctx)

	sc.separator(ctx)

	p.col(ctx, "w-full px-4 gap-4")
	defer p.end(ctx)

	p.row(ctx, "w-full gap-4 items-start")
	detail_cell(ctx, "IPv4 address", d.ip4 == "" ? "" : fmt.tprintf("%s%s", d.ip4, d.prefix))
	detail_cell(ctx, "Gateway", d.gw4)
	detail_cell(ctx, "DNS", d.dns)
	p.end(ctx)

	p.row(ctx, "w-full gap-4 items-start")
	detail_cell(ctx, "IPv6 address", d.ip6)
	detail_cell(ctx, "Link speed", d.speed)
	detail_cell(ctx, "MTU", d.mtu)
	p.end(ctx)
}

detail_cell :: proc(ctx: ^p.Ctx, label, value: string) {
	p.col(ctx, "flex-1 basis-0 gap-1.5 min-w-0")
	defer p.end(ctx)
	p.text(
		ctx,
		label,
		"text-[10.5] leading-none font-semibold uppercase tracking-wider text-muted-foreground",
	)
	p.text(ctx, value == "" ? "—" : value, "text-[13] leading-[17] font-mono truncate")
	if value == "" {
		p.apply(ctx, "text-muted-foreground")
	}
}

ok_pill :: proc(ctx: ^p.Ctx, label: string) {
	p.row(ctx, "h-5 shrink-0 items-center gap-1.5 rounded-4xl px-2 bg-emerald-500/10")
	defer p.end(ctx)
	p.div(ctx, "size-1.5 shrink-0 rounded-full bg-emerald-500")
	p.end(ctx)
	p.text(ctx, label, "text-xs font-medium text-emerald-700 whitespace-nowrap")
	p.style(ctx).shrink = 0
}

// ---------------------------------------------------------------------------
// The scan
// ---------------------------------------------------------------------------

wifi_card :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	sc.card_open(ctx, .Default, false, "w-full h-full")
	defer sc.card_end(ctx)

	p.row(ctx, "w-full px-4 shrink-0 items-center gap-2")
	p.col(ctx, "flex-1 gap-2 min-w-0")
	p.text(ctx, "Available networks", "text-base leading-none font-semibold")
	sub := "Sorted by signal strength"
	if !s.radio_on {
		sub = "The Wi-Fi radio is off"
	} else if s.scan_at != "" {
		sub = fmt.tprintf("%d in range · sorted by signal · scanned %s", len(s.aps), s.scan_at)
	}
	p.text(ctx, sub, "text-xs leading-none text-muted-foreground truncate")
	p.end(ctx)
	sc.kbd(ctx, "S")
	p.text(ctx, "rescan", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ctx).shrink = 0
	p.end(ctx)

	if !s.radio_on {
		empty_state(
			ctx,
			ICON_WIFI_OFF,
			"Wi-Fi is turned off",
			"Press W, or use the switch in the toolbar, to turn the radio back on.",
		)
		return
	}
	if !s.scanned {
		p.col(ctx, "w-full flex-1 px-2 gap-1 overflow-hidden")
		defer p.end(ctx)
		for i in 0 ..< 7 {
			p.div(ctx, "w-full shrink-0 rounded-lg bg-muted")
			st := p.style(ctx)
			st.h = p.px(AP_ROW)
			st.opacity = 1 - f32(i) * 0.13
			p.end(ctx)
		}
		return
	}
	if len(s.aps) == 0 {
		empty_state(
			ctx,
			ICON_SEARCH,
			"No networks in range",
			"Nothing answered the last scan. Press S to try again.",
		)
		return
	}

	more_row(ctx, u.first[.Networks], "above")

	view := p.col(ctx, "w-full flex-1 min-h-[58] px-2 gap-1 overflow-hidden")
	u.view_id[.Networks] = p.node_id(ctx, view)
	lo, hi := window(u, .Networks)
	for i in lo ..< hi {
		ap_row(ctx, u, s.aps[i], i)
	}
	p.end(ctx)

	more_row(ctx, u.counts[.Networks] - hi, "below")
	p.div(ctx, "h-1 shrink-0")
	p.end(ctx)
}

ap_row :: proc(ctx: ^p.Ctx, u: ^UI, ap: Ap, i: int) {
	p.key(ctx, ap.bssid)
	on := u.section == .Networks && u.sel[.Networks] == i

	idx := p.row(ctx, "w-full shrink-0 items-center gap-3 px-3 rounded-lg transition")
	p.style(ctx).h = p.px(AP_ROW)
	if on {
		p.apply(ctx, "bg-accent ring-1 ring-ring")
	} else if ap.active {
		p.apply(ctx, "bg-emerald-500/5")
	} else if p.is_hovered(ctx, idx) {
		p.apply(ctx, "bg-accent/60")
	}
	if p.clickable(ctx, idx) {
		u.section = .Networks
		u.sel[.Networks] = i
		open_dialog(u, ap)
	}
	defer p.end(ctx)

	signal_bars(ctx, ap.signal, 17)

	p.col(ctx, "flex-1 gap-2 min-w-0")
	p.row(ctx, "items-center gap-1.5")
	p.text(ctx, ap.ssid, "text-sm leading-none font-medium truncate")
	p.style(ctx).shrink = 0
	if ap.security == "Open" {
		p.icon(ctx, ICON_LOCK_OPEN, "size-3 shrink-0 text-amber-600")
	} else {
		p.icon(ctx, ICON_LOCK, "size-3 shrink-0 text-muted-foreground")
	}
	if ap.active {
		ok_pill(ctx, "Connected")
	}
	p.end(ctx)

	band := ap.band == "" ? "—" : ap.band
	if ap.bssids > 1 {
		p.textf(
			ctx,
			"text-[11.5] leading-none text-muted-foreground truncate",
			"%s · ch %d · %s · %s · %d radios",
			ap.security,
			ap.channel,
			band,
			ap.rate,
			ap.bssids,
		)
	} else {
		p.textf(
			ctx,
			"text-[11.5] leading-none text-muted-foreground truncate",
			"%s · ch %d · %s · %s",
			ap.security,
			ap.channel,
			band,
			ap.rate,
		)
	}
	p.end(ctx)

	p.col(ctx, "w-[66] shrink-0 items-end gap-2")
	p.textf(ctx, "text-[13] leading-none font-semibold font-mono", "%d%%", ap.signal)
	p.text(
		ctx,
		strength_word(ap.signal),
		"text-[10.5] leading-none text-muted-foreground whitespace-nowrap",
	)
	p.end(ctx)

	p.icon(ctx, ICON_CHEVRON_RIGHT, "size-4 shrink-0")
	p.apply(ctx, on ? "text-muted-foreground" : "text-transparent")
}

empty_state :: proc(ctx: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ctx, "w-full flex-1 items-center justify-center gap-4 px-6")
	defer p.end(ctx)
	sc.empty_media_icon(ctx, ic)
	p.col(ctx, "max-w-[360] items-center gap-2")
	p.text(ctx, title, "text-sm font-medium tracking-tight")
	p.text(ctx, body, "text-sm leading-relaxed text-muted-foreground text-center")
	p.end(ctx)
}

// signal_bars is the four-bar meter every network list has, filled from
// nmcli's own SIGNAL percentage.
signal_bars :: proc(ctx: ^p.Ctx, signal: int, full: f32) {
	filled := 1
	switch {
	case signal >= 75:
		filled = 4
	case signal >= 50:
		filled = 3
	case signal >= 25:
		filled = 2
	}
	p.row(ctx, "shrink-0 items-end gap-[2]")
	p.style(ctx).h = p.px(full)
	defer p.end(ctx)

	for i in 0 ..< 4 {
		p.div(ctx, "shrink-0 rounded-[1.5]")
		p.apply(ctx, i < filled ? "bg-foreground" : "bg-foreground/15")
		st := p.style(ctx)
		st.h = p.px(full * (0.34 + 0.22 * f32(i)))
		st.w = p.px(max(3, full * 0.2))
		p.end(ctx)
	}
}

strength_word :: proc(signal: int) -> string {
	switch {
	case signal >= 75:
		return "Excellent"
	case signal >= 55:
		return "Good"
	case signal >= 35:
		return "Fair"
	case signal >= 20:
		return "Weak"
	}
	return "Very weak"
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

status_bar :: proc(ctx: ^p.Ctx, u: ^UI) {
	s := u.st

	p.row(ctx, "w-full h-[34] shrink-0 items-center gap-3.5 px-5 border-t border-border bg-card")
	defer p.end(ctx)

	hint(ctx, "Tab", section_word(u.section))
	hint(ctx, "Up Dn", "Move")
	hint(ctx, "Enter", "Connect")
	hint(ctx, "W", "Radio")
	hint(ctx, "S", "Scan")
	hint(ctx, "R", "Refresh")

	p.spacer(ctx, "flex-1")

	if s.message != "" {
		p.div(ctx, "size-1.5 shrink-0 rounded-full")
		switch s.msg_kind {
		case .Good:
			p.apply(ctx, "bg-emerald-500")
		case .Bad:
			p.apply(ctx, "bg-destructive")
		case .Info, .None:
			p.apply(ctx, "bg-muted-foreground")
		}
		p.end(ctx)
		p.text(ctx, s.message, "text-[11] whitespace-nowrap")
		p.apply(ctx, s.msg_kind == .Bad ? "text-destructive" : "text-muted-foreground")
		p.style(ctx).shrink = 0
	}
}

hint :: proc(ctx: ^p.Ctx, key, label: string) {
	p.row(ctx, "shrink-0 items-center gap-1.5")
	defer p.end(ctx)
	sc.kbd(ctx, key)
	p.text(ctx, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ctx).shrink = 0
}

section_word :: proc(s: Section) -> string {
	switch s {
	case .Toolbar:
		return "Toolbar"
	case .Devices:
		return "Interfaces"
	case .Networks:
		return "Networks"
	case .Saved:
		return "Saved"
	}
	return ""
}

// ---------------------------------------------------------------------------
// Connect dialog
// ---------------------------------------------------------------------------

connect_dialog :: proc(ctx: ^p.Ctx, u: ^UI) {
	// There is no xdg_popup in palmy, so a modal is an absolutely positioned
	// overlay inside the window.
	p.div(ctx, "absolute inset-0 z-50 flex-col items-center justify-center bg-foreground/55")
	defer p.end(ctx)

	p.div(ctx, "w-[440] shrink-0 rounded-xl shadow-2xl")
	defer p.end(ctx)

	sc.dialog_content_open(ctx)
	defer p.end(ctx)

	sc.dialog_header_open(ctx)
	p.row(ctx, "w-full items-center gap-2.5")
	p.div(ctx, "size-9 shrink-0 rounded-lg bg-muted flex-row items-center justify-center")
	p.icon(ctx, ICON_LOCK_KEYHOLE, "size-4")
	p.end(ctx)
	p.col(ctx, "flex-1 gap-2 min-w-0")
	p.textf(ctx, "text-base leading-none font-medium truncate", "Connect to %s", u.dlg_ssid)
	p.text(ctx, u.dlg_desc, "text-xs leading-none text-muted-foreground truncate")
	p.end(ctx)
	p.end(ctx)
	p.end(ctx)

	// The field. palmy's text_field cannot mask its contents, so the buffer is
	// driven by hand (see dialog_keys) and drawn as bullets with its own caret.
	p.col(ctx, "w-full gap-2.5")
	sc.label(ctx, "Password")

	p.row(ctx, sc.INPUT_BASE + " h-9 gap-0 border-ring ring-3 ring-ring/50")
	if len(u.pw) == 0 {
		p.text(ctx, "Network password", "text-muted-foreground whitespace-nowrap")
		p.style(ctx).shrink = 0
	} else {
		shown := string(u.pw[:])
		if !u.reveal {
			n := 0
			for _ in shown {n += 1}
			shown = strings.repeat("•", n, ctx.alloc)
		}
		p.text(ctx, shown, "text-foreground whitespace-nowrap")
		p.style(ctx).shrink = 0
	}
	if int(p.elapsed(ctx) * 2) % 2 == 0 {
		p.div(ctx, "w-px h-4 shrink-0 bg-foreground ml-px")
		p.end(ctx)
	}
	p.spacer(ctx, "flex-1")
	eye := p.div(ctx, "size-6 shrink-0 rounded-md flex-row items-center justify-center")
	if p.is_hovered(ctx, eye) {
		p.apply(ctx, "bg-muted")
	}
	if p.clickable(ctx, eye) {
		u.reveal = !u.reveal
	}
	p.icon(ctx, u.reveal ? ICON_EYE_OFF : ICON_EYE, "size-3.5 text-muted-foreground")
	p.end(ctx)
	p.end(ctx)

	p.row(ctx, "items-center gap-1.5")
	p.text(ctx, "Reveal with", "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ctx).shrink = 0
	sc.kbd(ctx, "Ctrl")
	sc.kbd(ctx, "R")
	p.end(ctx)
	p.end(ctx)

	sc.dialog_footer_open(ctx)
	defer p.end(ctx)

	p.row(ctx, "flex-1 items-center gap-1.5")
	sc.kbd(ctx, "Esc")
	p.text(ctx, "cancel", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ctx).shrink = 0
	p.end(ctx)

	at := p.node_count(ctx)
	sc.button_open(ctx, .Outline, .Default, sc.State{hover = p.hovered(ctx, p.node_id(ctx, at))})
	if p.clickable(ctx) {
		close_dialog(u)
	}
	p.text(ctx, "Cancel", "whitespace-nowrap")
	p.style(ctx).shrink = 0
	sc.button_end(ctx)

	at2 := p.node_count(ctx)
	sc.button_open(ctx, .Default, .Default, sc.State{hover = p.hovered(ctx, p.node_id(ctx, at2))})
	if p.clickable(ctx) {
		connect_now(u)
	}
	p.icon(ctx, ICON_WIFI, "size-3.5 shrink-0")
	p.text(ctx, "Connect", "whitespace-nowrap")
	p.style(ctx).shrink = 0
	sc.button_end(ctx)
}

// ---------------------------------------------------------------------------
// Small mappings
// ---------------------------------------------------------------------------

dev_icon :: proc(kind: string) -> p.Icon {
	switch kind {
	case "wifi":
		return ICON_WIFI
	case "wifi-p2p":
		return ICON_RADIO_TOWER
	case "ethernet":
		return ICON_CABLE
	case "loopback":
		return ICON_REPEAT
	case "wireguard", "tun", "vpn", "ip-tunnel":
		return ICON_SHIELD_CHECK
	case "bridge", "bond", "team":
		return ICON_NETWORK
	case "modem":
		return ICON_SATELLITE
	}
	return ICON_SERVER
}

saved_icon :: proc(kind: string) -> p.Icon {
	switch kind {
	case "Wi-Fi":
		return ICON_WIFI
	case "Ethernet":
		return ICON_CABLE
	case "WireGuard", "VPN", "Tunnel":
		return ICON_SHIELD_CHECK
	case "Loopback":
		return ICON_REPEAT
	}
	return ICON_SERVER
}

pretty_kind :: proc(kind: string) -> string {
	switch kind {
	case "wifi":
		return "Wi-Fi"
	case "wifi-p2p":
		return "Wi-Fi Direct"
	case "ethernet":
		return "Ethernet"
	case "loopback":
		return "Loopback"
	case "wireguard":
		return "WireGuard"
	case "bridge":
		return "Bridge"
	}
	return kind
}

state_word :: proc(st: Dev_State) -> string {
	switch st {
	case .Connected:
		return "Connected"
	case .Connecting:
		return "Connecting"
	case .Disconnected:
		return "Disconnected"
	case .Unavailable:
		return "Unavailable"
	case .Unmanaged:
		return "Unmanaged"
	case .Unknown:
		return "Unknown"
	}
	return ""
}
