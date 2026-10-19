package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import ai "kit:appindex"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

SIDEBAR_W :: 236

ACCENTS := [?]struct {
	name, hex: string,
} {
	{"Indigo", "#6366f1"},
	{"Blue", "#3b82f6"},
	{"Sky", "#0ea5e9"},
	{"Teal", "#14b8a6"},
	{"Emerald", "#10b981"},
	{"Amber", "#f59e0b"},
	{"Rose", "#f43f5e"},
	{"Violet", "#8b5cf6"},
	{"Slate", "#64748b"},
}

WALL_COLORS := [?]struct {
	name, hex: string,
} {
	{"Night", "#0b1020"},
	{"Graphite", "#18181b"},
	{"Deep teal", "#134e4a"},
	{"Indigo", "#312e81"},
	{"Paper", "#f4f4f5"},
	{"Stone", "#e7e5e4"},
}

WP_FILTERS := [?]kit.Pick_Filter{kit.PICK_IMAGES, kit.PICK_ALL}

hexval :: proc(s: string) -> u32 {
	h := strings.trim_prefix(s, "#")
	v: u32
	for c in h {
		d: u32
		switch c {
		case '0' ..= '9':
			d = u32(c - '0')
		case 'a' ..= 'f':
			d = u32(c - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(c - 'A' + 10)
		}
		v = v * 16 + d
	}
	return v
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, m: ^Model) {
	p.row(ui, "w-full h-full")
	defer p.end(ui)

	sidebar(ui, m)

	p.col(ui, "flex-1 min-w-0 h-full")
	{
		header(ui, m)
		p.col(ui, "w-full flex-1 min-h-0 overflow-scroll")
		p.col(ui, "w-full max-w-[760] mx-auto px-10 pt-2 pb-12 gap-6")
		switch m.page {
		case .Appearance:
			page_appearance(ui, m)
		case .Displays:
			page_displays(ui, m)
		case .Keyboard:
			page_keyboard(ui, m)
		case .Mouse:
			page_mouse(ui, m)
		case .Sound:
			page_sound(ui, m)
		case .Network:
			page_network(ui, m)
		case .Datetime:
			page_datetime(ui, m)
		case .Users:
			page_users(ui, m)
		case .Updates:
			page_updates(ui, m)
		case .About:
			page_about(ui, m)
		}
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)

	if m.toast != "" {
		p.div(ui, "absolute bottom-5 right-5 z-50 flex-row items-center gap-2 px-4 py-2.5 rounded-lg border border-border bg-popover text-popover-foreground shadow-lg")
		p.icon(ui, ai.ICON_CHECK, "size-4 text-muted-foreground")
		p.text(ui, m.toast, "text-sm")
		p.end(ui)
	}

	if kit.pick_active(&m.pick) {
		if res, done := kit.pick_draw(ui, &m.pick); done {
			defer kit.pick_result_free(res)
			if res.ok && apply(m, "appearance.wallpaper", res.path) {
				delete(m.wallpaper)
				m.wallpaper = strings.clone(res.path)
				delete(m.wp_color)
				m.wp_color = ""
				toast(m, "Wallpaper set")
			}
		}
	}
}

sidebar :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, fmt.tprintf("w-[%d] shrink-0 h-full bg-sidebar border-r border-sidebar-border px-3 py-4 gap-0.5", SIDEBAR_W))
	defer p.end(ui)
	p.row(ui, "items-center gap-2.5 px-2.5 pb-4 pt-1")
	p.div(ui, "size-7 rounded-lg bg-primary flex-row items-center justify-center shrink-0")
	p.icon(ui, ai.ICON_SETTINGS, "size-4 text-primary-foreground")
	p.end(ui)
	p.text(ui, "Settings", "text-[15] font-semibold tracking-tight")
	p.end(ui)
	groups := [?][]Page{{.Appearance, .Displays}, {.Keyboard, .Mouse, .Sound}, {.Network, .Datetime, .Users}, {.Updates, .About}}
	for g, gi in groups {
		if gi > 0 {
			p.div(ui, "h-px w-full bg-sidebar-border my-2 shrink-0")
			p.end(ui)
		}
		for pg in g {
			active := pg == m.page
			idx := p.row(ui, "w-full h-9 shrink-0 items-center gap-2.5 px-2.5 rounded-md cursor-pointer")
			p.apply(ui, active ? "bg-sidebar-accent text-sidebar-accent-foreground font-medium" : "text-sidebar-foreground hover:bg-sidebar-accent/60")
			p.focusable(ui, idx)
			if p.activated(ui, idx) {
				m.page = pg
				p.redraw(ui)
			}
			p.icon(ui, PAGE_ICON[pg], active ? "size-4 shrink-0" : "size-4 shrink-0 text-muted-foreground")
			p.text(ui, PAGE_TITLE[pg], "text-sm whitespace-nowrap")
			p.end(ui)
		}
	}
}

header :: proc(ui: ^p.Ctx, m: ^Model) {
	p.col(ui, "w-full shrink-0")
	p.col(ui, "w-full max-w-[760] mx-auto px-10 pt-8 pb-5 gap-1")
	p.row(ui, "w-full items-center gap-3")
	p.text(ui, PAGE_TITLE[m.page], "text-2xl font-semibold tracking-tight")
	p.spacer(ui)
	switch m.page {
	case .Displays, .Sound, .Network, .Updates, .About, .Users:
		if button(ui, "Refresh", .Outline, ai.ICON_REFRESH_CW) {
			refresh(m)
		}
	case .Appearance, .Keyboard, .Mouse, .Datetime:
	}
	p.end(ui)
	p.text(ui, PAGE_BLURB[m.page], "text-sm text-muted-foreground")
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Building blocks
// ---------------------------------------------------------------------------

button :: proc(ui: ^p.Ctx, label: string, v := sc.Variant.Outline, ic := p.Icon{}, disabled := false) -> bool {
	at := p.node_count(ui)
	hovered := p.hovered(ui, p.node_id(ui, at))
	sc.button_open(ui, v, .SM, sc.State{hover = hovered, focus = p.focused(ui), disabled = disabled})
	if !disabled {
		p.focusable(ui)
	}
	act := !disabled && p.activated(ui)
	if ic.d != "" {
		p.icon(ui, ic, "size-3.5 shrink-0")
	}
	p.text(ui, label, "whitespace-nowrap")
	sc.button_end(ui)
	return act
}

card_open :: proc(ui: ^p.Ctx, title := "", note := "") {
	if title != "" {
		p.col(ui, "w-full gap-0.5 px-1")
		p.text(ui, title, "text-sm font-semibold")
		if note != "" {
			p.text(ui, note, "text-xs text-muted-foreground leading-relaxed")
		}
		p.end(ui)
	}
	p.col(ui, "w-full rounded-xl border border-border bg-card text-card-foreground overflow-hidden")
}

card_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

section :: proc(ui: ^p.Ctx) {
	p.col(ui, "w-full gap-2.5")
}

// row_open starts a settings row: a title and a description on the left,
// the control on the right. Rows after the first get a rule above them.
row_open :: proc(ui: ^p.Ctx, title: string, desc := "", first := false) {
	p.row(ui, "w-full items-center gap-6 px-5 py-4 min-h-[64]")
	if !first {
		p.apply(ui, "border-t border-border")
	}
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, title, "text-sm font-medium")
	if desc != "" {
		p.text(ui, desc, "text-xs text-muted-foreground leading-relaxed")
	}
	p.end(ui)
}

row_close :: proc(ui: ^p.Ctx) {
	p.end(ui)
}

// switch_row is a row whose whole width toggles.
switch_row :: proc(ui: ^p.Ctx, title, desc: string, on: bool, first := false) -> bool {
	idx := p.row(ui, "w-full items-center gap-6 px-5 py-4 min-h-[64] cursor-pointer hover:bg-accent/40 transition duration-100")
	if !first {
		p.apply(ui, "border-t border-border")
	}
	p.focusable(ui, idx)
	hit := p.activated(ui, idx)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, title, "text-sm font-medium")
	if desc != "" {
		p.text(ui, desc, "text-xs text-muted-foreground leading-relaxed")
	}
	p.end(ui)
	sc.switch_(ui, on, .Default, sc.State{focus = p.focused(ui, idx)})
	p.end(ui)
	return hit
}

// segmented is a row of mutually exclusive choices. Returns the one picked
// this frame, or -1.
segmented :: proc(ui: ^p.Ctx, labels: []string, cur: int) -> int {
	picked := -1
	p.row(ui, "shrink-0 items-center p-0.5 gap-0.5 rounded-lg bg-muted")
	for l, i in labels {
		idx := p.row(ui, "h-7 px-3 items-center rounded-md cursor-pointer transition duration-100")
		p.apply(ui, i == cur ? "bg-background shadow-sm text-foreground" : "text-muted-foreground hover:text-foreground")
		p.focusable(ui, idx)
		if p.activated(ui, idx) && i != cur {
			picked = i
		}
		p.text(ui, l, "text-xs font-medium whitespace-nowrap")
		p.end(ui)
	}
	p.end(ui)
	return picked
}

kv :: proc(ui: ^p.Ctx, k, v: string, first := false, mono := false) {
	p.row(ui, "w-full items-center gap-6 px-5 py-3")
	if !first {
		p.apply(ui, "border-t border-border")
	}
	p.text(ui, k, "w-[170] shrink-0 text-sm text-muted-foreground")
	p.text(ui, v == "" ? "—" : v, mono ? "flex-1 min-w-0 text-sm font-mono" : "flex-1 min-w-0 text-sm")
	p.end(ui)
}

empty_state :: proc(ui: ^p.Ctx, ic: p.Icon, title, body: string) {
	p.col(ui, "w-full items-center gap-2 px-8 py-10 rounded-xl border border-dashed border-border")
	p.div(ui, "size-10 rounded-full bg-muted flex-row items-center justify-center")
	p.icon(ui, ic, "size-5 text-muted-foreground")
	p.end(ui)
	p.text(ui, title, "text-sm font-medium")
	p.text(ui, body, "text-xs text-muted-foreground text-center leading-relaxed max-w-[440]")
	p.end(ui)
}

note :: proc(ui: ^p.Ctx, text: string) {
	p.row(ui, "w-full items-start gap-2 px-1")
	p.icon(ui, ai.ICON_INFO, "size-3.5 shrink-0 text-muted-foreground mt-0.5")
	p.text(ui, text, "flex-1 min-w-0 text-xs text-muted-foreground leading-relaxed")
	p.end(ui)
}

// slider_row is a labelled slider; returns the new value when it moved.
slider_row :: proc(ui: ^p.Ctx, title, desc: string, v: ^f32, lo, hi: f32, label: string, first := false) -> bool {
	row_open(ui, title, desc, first)
	p.row(ui, "w-[260] shrink-0 items-center gap-3")
	t := [1]f32{(v^ - lo) / (hi - lo)}
	p.col(ui, "flex-1 min-w-0")
	nv, moved := sc.slider(ui, t[:])
	p.end(ui)
	p.text(ui, label, "w-[64] shrink-0 text-xs text-muted-foreground text-right tabular-nums")
	p.end(ui)
	row_close(ui)
	if moved {
		v^ = lo + nv * (hi - lo)
	}
	return moved
}

// list_filter is a search field over a list.
list_filter :: proc(ui: ^p.Ctx, buf: ^[dynamic]u8, placeholder: string) {
	p.row(ui, "w-full items-center gap-2 px-4 h-11 border-b border-border")
	p.icon(ui, ai.ICON_SEARCH, "size-4 shrink-0 text-muted-foreground")
	p.text_field(ui, buf, placeholder, "flex-1 min-w-0 h-9 bg-transparent border-0 text-sm px-0")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Appearance
// ---------------------------------------------------------------------------

Preview :: struct {
	light:  bool,
	accent: u32,
}

// paint_preview is a small picture of the desktop in a look: a bar, a
// window, the accent on the current workspace.
paint_preview :: proc(c: ^p.Canvas, r: p.Rect, pv: ^Preview) {
	bg := pv.light ? p.hex(0xe7eaf3) : p.hex(0x111427)
	bar := pv.light ? p.hex(0xfafafa) : p.hex(0x0a0a0c)
	win := pv.light ? p.hex(0xffffff) : p.hex(0x18181b)
	title := pv.light ? p.hex(0xf4f4f5) : p.hex(0x27272a)
	line := pv.light ? p.hex(0xe4e4e7) : p.hex(0x27272a)
	ink := pv.light ? p.hex(0xd4d4d8) : p.hex(0x3f3f46)
	p.fill_round_rect(c, r, {8, 8, 8, 8}, bg)
	p.fill_round_rect(c, {r.x, r.y, r.w, 14}, {8, 8, 0, 0}, bar)
	p.fill_rect(c, {r.x, r.y + 14, r.w, 1}, line)
	p.fill_round_rect(c, {r.x + 6, r.y + 4, 6, 6}, {2, 2, 2, 2}, p.hex(pv.accent))
	p.fill_round_rect(c, {r.x + 18, r.y + 4, 8, 6}, {2, 2, 2, 2}, p.hex(pv.accent))
	p.fill_round_rect(c, {r.x + 29, r.y + 4, 8, 6}, {2, 2, 2, 2}, ink)
	w := p.Rect{r.x + r.w * 0.16, r.y + 26, r.w * 0.68, r.h - 38}
	p.drop_shadow(c, w, {6, 6, 6, 6}, 10, 0, {0, 4}, p.hexa(pv.light ? 0x00000022 : 0x00000088))
	p.fill_round_rect(c, w, {6, 6, 6, 6}, win)
	p.fill_round_rect(c, {w.x, w.y, w.w, 12}, {6, 6, 0, 0}, title)
	p.fill_rect(c, {w.x + 10, w.y + 22, w.w * 0.5, 4}, ink)
	p.fill_rect(c, {w.x + 10, w.y + 32, w.w * 0.7, 4}, ink)
	p.fill_rect(c, {w.x + 10, w.y + 42, w.w * 0.35, 4}, ink)
	p.fill_round_rect(c, {w.x + w.w - 40, w.y + w.h - 18, 30, 10}, {3, 3, 3, 3}, p.hex(pv.accent))
}

Swatch :: struct {
	color:    u32,
	gradient: bool,
	light:    bool,
	image:    bool,
}

paint_swatch :: proc(c: ^p.Canvas, r: p.Rect, sw: ^Swatch) {
	rad := p.Radius{8, 8, 8, 8}
	switch {
	case sw.gradient:
		// The wm's generated wallpaper, in miniature: a diagonal, two glows,
		// kept inside the tile.
		top := sw.light ? p.hex(0xeef1f8) : p.hex(0x0b1020)
		bot := sw.light ? p.hex(0xd9ddf0) : p.hex(0x1e1b4b)
		p.fill_round_rect_paint(c, r, rad, p.gradient(top, bot))
		p.push_clip(c, p.rect_inset(r, 3))
		p.fill_circle(c, r.x + r.w * 0.22, r.y + r.h * 0.25, r.h * 0.26, p.hexa(0x6366f11c))
		p.fill_circle(c, r.x + r.w * 0.8, r.y + r.h * 0.78, r.h * 0.24, p.hexa(0x0d948814))
		p.pop_clip(c)
	case sw.image:
		p.fill_round_rect(c, r, rad, sw.light ? p.hex(0xf4f4f5) : p.hex(0x27272a))
	case:
		p.fill_round_rect(c, r, rad, p.hex(sw.color))
	}
	// A hairline, so a colour close to the card's own still reads as a tile.
	p.stroke_round_rect(c, r, rad, 1, p.hexa(0x80808040))
}

page_appearance :: proc(ui: ^p.Ctx, m: ^Model) {
	accent := hexval(m.accent)

	// Style.
	section(ui)
	card_open(ui, "Style", "The bar, title bars, menus and the start menu. Settings follows it too.")
	p.row(ui, "w-full gap-4 p-5")
	for light in ([2]bool{false, true}) {
		sel := m.light == light
		idx := p.col(ui, "flex-1 min-w-0 gap-2.5 p-2 rounded-xl border-2 cursor-pointer transition duration-100")
		p.apply(ui, sel ? "border-primary" : "border-transparent hover:border-border")
		p.focusable(ui, idx)
		if p.activated(ui, idx) && !sel {
			set_theme(m, light)
		}
		pv := new(Preview, context.temp_allocator)
		pv^ = {light, accent}
		p.pixels(ui, "w-full h-[118]", pv, paint_preview)
		p.row(ui, "items-center gap-2 px-1")
		sc.radio(ui, sel)
		p.text(ui, light ? "Light" : "Dark", "text-sm font-medium")
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
	card_close(ui)
	p.end(ui)

	// Accent.
	section(ui)
	card_open(ui, "Accent colour", "The current workspace, the focused window's edge, selections and checks.")
	p.row(ui, "w-full items-center gap-3 px-5 py-4 flex-wrap")
	for a in ACCENTS {
		sel := strings.to_lower(m.accent, context.temp_allocator) == a.hex
		idx := p.div(ui, "size-9 rounded-full flex-row items-center justify-center cursor-pointer border-2 transition duration-100")
		p.apply(ui, sel ? "border-foreground" : "border-transparent hover:border-border")
		p.focusable(ui, idx)
		if p.activated(ui, idx) && !sel && apply(m, "appearance.accent", a.hex) {
			delete(m.accent)
			m.accent = strings.clone(a.hex)
		}
		p.div(ui, fmt.tprintf("size-7 rounded-full bg-[%s] flex-row items-center justify-center", a.hex))
		if sel {
			p.icon(ui, ai.ICON_CHECK, "size-4 text-white")
		}
		p.end(ui)
		p.end(ui)
	}
	p.spacer(ui)
	name := m.accent
	for a in ACCENTS {
		if a.hex == strings.to_lower(m.accent, context.temp_allocator) {
			name = a.name
		}
	}
	p.text(ui, name, "text-xs text-muted-foreground")
	p.end(ui)
	card_close(ui)
	p.end(ui)

	// Wallpaper.
	section(ui)
	card_open(ui, "Wallpaper", "The generated gradient follows the style; a colour or a picture stays as chosen.")
	p.row(ui, "w-full gap-3 px-5 pt-5 pb-4 flex-wrap")
	{
		cur_default := m.wallpaper == "" && m.wp_color == ""
		if wall_tile(ui, "Gradient", Swatch{gradient = true, light = m.light}, cur_default) && !cur_default {
			if apply(m, "appearance.wallpaper", "") && apply(m, "appearance.wallpaper_color", "") {
				delete(m.wallpaper)
				delete(m.wp_color)
				m.wallpaper, m.wp_color = "", ""
			}
		}
		for wc in WALL_COLORS {
			sel := m.wallpaper == "" && strings.to_lower(m.wp_color, context.temp_allocator) == wc.hex
			if wall_tile(ui, wc.name, Swatch{color = hexval(wc.hex)}, sel) && !sel && apply(m, "appearance.wallpaper_color", wc.hex) {
				delete(m.wp_color)
				m.wp_color = strings.clone(wc.hex)
				delete(m.wallpaper)
				m.wallpaper = ""
			}
		}
		pic := m.wallpaper != ""
		if wall_tile(ui, pic ? "Picture" : "Picture…", Swatch{image = true, light = m.light}, pic, ai.ICON_IMAGE) && !m.fixture {
			dir := fmt.tprintf("%s/Pictures", os.get_env("HOME", context.temp_allocator))
			kit.pick_begin(&m.pick, .Open_File, {title = "Choose a Wallpaper", filters = WP_FILTERS[:], dir = os.is_dir(dir) ? dir : "", confirm = "Set Wallpaper"})
		}
	}
	p.end(ui)
	if m.wallpaper != "" {
		row_open(ui, "Picture", m.wallpaper)
		modes := [?]string{"Fill", "Fit", "Center", "Tile"}
		ids := [?]string{"fill", "fit", "center", "tile"}
		cur := 0
		for id, i in ids {
			if id == m.wp_mode {
				cur = i
			}
		}
		if i := segmented(ui, modes[:], cur); i >= 0 && apply(m, "appearance.wallpaper_mode", ids[i]) {
			delete(m.wp_mode)
			m.wp_mode = strings.clone(ids[i])
		}
		if button(ui, "Change…", .Outline) && !m.fixture {
			kit.pick_begin(&m.pick, .Open_File, {title = "Choose a Wallpaper", filters = WP_FILTERS[:], confirm = "Set Wallpaper"})
		}
		row_close(ui)
	}
	card_close(ui)
	p.end(ui)

	// The desktop's behaviour.
	section(ui)
	card_open(ui, "Desktop")
	row_open(ui, "The Super key", "A tap of Super on its own opens this.", first = true)
	{
		labels := [?]string{"Start menu", "Overview", "Nothing"}
		ids := [?]string{"menu", "overview", "off"}
		cur := 0
		for id, i in ids {
			if id == m.super_tap {
				cur = i
			}
		}
		if i := segmented(ui, labels[:], cur); i >= 0 && apply(m, "shell.super_tap", ids[i]) {
			delete(m.super_tap)
			m.super_tap = strings.clone(ids[i])
		}
	}
	row_close(ui)
	if switch_row(ui, "Pinned apps in the bar", "Apps pinned to the bar sit beside the Palmy button.", m.bar_pins) && apply(m, "shell.bar_pins", m.bar_pins ? "off" : "on") {
		m.bar_pins = !m.bar_pins
	}
	if switch_row(ui, "Hot corner", "Pushing the pointer into the top-left corner opens the overview.", m.hot_corner) && apply(m, "shell.hot_corner", m.hot_corner ? "off" : "on") {
		m.hot_corner = !m.hot_corner
	}
	row_open(ui, "Animations", "Windows and menus moving into place. Reduced keeps only fades.")
	{
		labels := [?]string{"On", "Reduced", "Off"}
		ids := [?]string{"on", "reduced", "off"}
		cur := 0
		for id, i in ids {
			if id == m.animations {
				cur = i
			}
		}
		if i := segmented(ui, labels[:], cur); i >= 0 && apply(m, "shell.animations", ids[i]) {
			delete(m.animations)
			m.animations = strings.clone(ids[i])
		}
	}
	row_close(ui)
	card_close(ui)
	p.end(ui)
}

wall_tile :: proc(ui: ^p.Ctx, label: string, sw: Swatch, sel: bool, ic := p.Icon{}) -> bool {
	idx := p.col(ui, "w-[104] shrink-0 gap-1.5 cursor-pointer")
	p.focusable(ui, idx)
	hit := p.activated(ui, idx)
	p.div(ui, "w-full h-[66] rounded-[10] border-2 p-0.5 transition duration-100")
	p.apply(ui, sel ? "border-primary" : "border-transparent hover:border-border")
	s := new(Swatch, context.temp_allocator)
	s^ = sw
	p.div(ui, "w-full h-full relative")
	p.pixels(ui, "absolute inset-0", s, paint_swatch)
	if ic.d != "" {
		p.div(ui, "absolute inset-0 flex-row items-center justify-center")
		p.icon(ui, ic, "size-5 text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	p.text(ui, label, sel ? "text-xs font-medium text-center" : "text-xs text-muted-foreground text-center")
	p.end(ui)
	return hit
}

// ---------------------------------------------------------------------------
// Displays
// ---------------------------------------------------------------------------

page_displays :: proc(ui: ^p.Ctx, m: ^Model) {
	ds := m.wm.ok ? m.wm.displays : m.sysfs
	if len(ds) == 0 {
		empty_state(ui, ai.ICON_MONITOR, "No display information", "The window manager publishes the screens it drives in $XDG_RUNTIME_DIR/palmy-wm.json, and the kernel lists connected ones under /sys/class/drm. Neither said anything here.")
		return
	}
	for d, i in ds {
		section(ui)
		card_open(ui)
		p.row(ui, "w-full items-center gap-4 px-5 py-5")
		p.div(ui, "size-12 rounded-xl bg-muted flex-row items-center justify-center shrink-0")
		p.icon(ui, ai.ICON_MONITOR, "size-6 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		title := d.desc != "" ? d.desc : (d.make_ != "" ? fmt.tprintf("%s %s", d.make_, d.model) : d.name)
		p.text(ui, title, "text-base font-semibold truncate")
		p.text(ui, fmt.tprintf("%s · %s", d.name, i == 0 ? "primary" : "secondary"), "text-xs text-muted-foreground")
		p.end(ui)
		sc.badge(ui, m.wm.ok ? (m.wm.bare ? "Driven by the window manager" : "Nested window") : "Connected", .Secondary)
		p.end(ui)
		mode := fmt.tprintf("%d × %d", d.mode_w, d.mode_h)
		kv(ui, "Resolution", mode)
		kv(ui, "Refresh rate", d.refresh_mhz > 0 ? fmt.tprintf("%.2f Hz", f64(d.refresh_mhz) / 1000) : "")
		kv(ui, "Scale", fmt.tprintf("%d× (%d × %d logical)", d.scale, d.w, d.h))
		kv(ui, "Position", fmt.tprintf("%d, %d", d.x, d.y))
		if d.mm_w > 0 {
			diag := f64(d.mm_w * d.mm_w + d.mm_h * d.mm_h)
			inches := 0.0
			if diag > 0 {
				inches = sqrt_f64(diag) / 25.4
			}
			kv(ui, "Size", fmt.tprintf("%d × %d mm (%.1f″)", d.mm_w, d.mm_h, inches))
		}
		if len(d.modes) > 0 {
			kv(ui, "Modes offered", strings.join(d.modes[:min(len(d.modes), 6)], ", ", context.temp_allocator))
		}
		card_close(ui)
		p.end(ui)
	}
	note(ui, "Each screen runs at its preferred mode and integer scale, chosen by the window manager when it starts or a screen is plugged in. Choosing another mode or a fractional scale here is not supported yet.")
}

sqrt_f64 :: proc(x: f64) -> f64 {
	if x <= 0 {
		return 0
	}
	g := x
	for _ in 0 ..< 30 {
		g = 0.5 * (g + x / g)
	}
	return g
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

layout_name :: proc(m: ^Model, code: string) -> string {
	for l in m.layouts {
		if l.code == code {
			return l.name
		}
	}
	return code
}

page_keyboard :: proc(ui: ^p.Ctx, m: ^Model) {
	eff := m.layout != "" ? m.layout : m.sys_layout
	section(ui)
	card_open(ui, "Layout", "What each key types. The window manager switches as soon as you pick one, and every open window follows.")
	p.row(ui, "w-full items-center gap-4 px-5 py-4")
	p.div(ui, "h-10 min-w-[48] px-3 rounded-lg bg-muted flex-row items-center justify-center shrink-0")
	p.text(ui, strings.to_upper(eff, context.temp_allocator), "text-sm font-semibold font-mono")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, layout_name(m, eff), "text-sm font-medium")
	src := m.layout != "" ? fmt.tprintf("Yours, in %s", kbd_user_path()) : fmt.tprintf("The system's, from %s", KBD_SYSTEM_PATH)
	p.text(ui, src, "text-xs text-muted-foreground truncate")
	p.end(ui)
	if m.layout != "" {
		if button(ui, fmt.tprintf("Use the system's (%s)", m.sys_layout), .Outline) && apply(m, "keyboard.layout", "") {
			delete(m.layout)
			m.layout = ""
			toast(m, "Back to the system layout")
		}
	}
	p.end(ui)
	list_filter(ui, &m.kfilter, "Find a layout — French, Deutsch, dvorak…")
	p.col(ui, "w-full h-[264] overflow-scroll py-1")
	q := strings.to_lower(string(m.kfilter[:]), context.temp_allocator)
	shown := 0
	for l in m.layouts {
		if q != "" && !strings.contains(strings.to_lower(l.name, context.temp_allocator), q) && !strings.has_prefix(l.code, q) {
			continue
		}
		shown += 1
		if shown > 120 {
			break
		}
		sel := l.code == eff
		p.key(ui, l.code)
		idx := p.row(ui, "w-full h-9 shrink-0 items-center gap-3 px-5 cursor-pointer hover:bg-accent/50")
		if sel {
			p.apply(ui, "bg-accent/60")
		}
		p.focusable(ui, idx)
		if p.activated(ui, idx) && !sel && apply(m, "keyboard.layout", l.code) {
			delete(m.layout)
			m.layout = strings.clone(l.code)
			toast(m, fmt.tprintf("Keyboard: %s", l.name))
		}
		p.text(ui, l.code, "w-[56] shrink-0 text-xs font-mono text-muted-foreground")
		p.text(ui, l.name, "flex-1 min-w-0 text-sm truncate")
		if sel {
			p.icon(ui, ai.ICON_CHECK, "size-4 shrink-0")
		}
		p.end(ui)
	}
	if shown == 0 {
		p.text(ui, "No layout matches.", "px-5 py-3 text-sm text-muted-foreground")
	}
	p.end(ui)
	card_close(ui)
	p.end(ui)

	section(ui)
	card_open(ui, "Typing", "How long a key is held before it repeats, and how fast it then repeats.")
	d := f32(m.delay)
	if slider_row(ui, "Repeat delay", "Shorter is quicker to start repeating.", &d, 150, 1000, fmt.tprintf("%d ms", int(d)), first = true) {
		m.delay = int(d / 10 + 0.5) * 10
		m.dirty += {.Delay}
	}
	r := f32(m.rate)
	if slider_row(ui, "Repeat rate", "Characters per second while a key is held.", &r, 5, 60, fmt.tprintf("%d / s", int(r + 0.5))) {
		m.rate = int(r + 0.5)
		m.dirty += {.Rate}
	}
	// A slider is written once it is let go, not on every frame of a drag.
	if !p.mouse_down(ui) {
		if .Delay in m.dirty {
			apply(m, "keyboard.repeat_delay", fmt.tprintf("%d", m.delay))
		}
		if .Rate in m.dirty {
			apply(m, "keyboard.repeat_rate", fmt.tprintf("%d", m.rate))
		}
		m.dirty -= {.Delay, .Rate}
	}
	row_open(ui, "Try it", "Hold a key down in this field.")
	p.text_field(ui, &m.ktest, "Type here…", "w-[260] shrink-0")
	row_close(ui)
	card_close(ui)
	p.end(ui)
	if m.wm.ok && m.wm.kbd_fell_back {
		note(ui, fmt.tprintf("The window manager could not compile %s and is typing with us. Check the layout code.", m.wm.kbd_rmlvo))
	} else if m.wm.ok {
		note(ui, fmt.tprintf("The window manager is typing with %s (%s).", m.wm.kbd_rmlvo, m.wm.kbd_from))
	}
}
