// The chrome: the identity bar, tabs, the toolbar and omnibox, the bookmarks
// bar, and the web page between them. Internal pages are in pages.odin, the
// overlays (menus, dialogs, the suggestion list) in overlays.odin.
package browser

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:time"
import pb "pb"
import p "palmy:."
import sc "shadcn:."

tfmt :: fmt.tprintf

rgb :: proc(c: u32) -> p.Color {
	return p.rgba(u8(c >> 16), u8(c >> 8), u8(c))
}

hex :: proc(c: u32) -> string {
	return fmt.tprintf("#%06x", c & 0xffffff)
}

// letter_color picks a stable, pleasant colour for a site's letter tile.
TILE_COLORS := [?]u32{0x2563eb, 0x7c3aed, 0xdb2777, 0xea580c, 0x059669, 0x0891b2, 0x4f46e5, 0xca8a04, 0x16a34a, 0xdc2626}

letter_color :: proc(key: string) -> u32 {
	h: u32 = 2166136261
	for b in transmute([]u8)key {
		h = (h ~ u32(b)) * 16777619
	}
	return TILE_COLORS[h % len(TILE_COLORS)]
}

site_letter :: proc(url, title: string) -> string {
	host := url_host(url)
	src := host != "" ? host : title
	for c in src {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			return strings.to_upper(fmt.tprintf("%c", c), context.temp_allocator)
		}
	}
	return "•"
}

// favicon draws a tab's icon, a spinner while it loads, or a letter tile.
favicon :: proc(ui: ^p.Ctx, t: ^Tab, size := 16) {
	if t.page != .Web {
		p.icon(ui, page_icon(t.page), tfmt("size-[%d] text-muted-foreground shrink-0", size))
		return
	}
	if t.loading && !t.has_icon {
		p.icon(ui, ICON_LOADER_CIRCLE, tfmt("size-[%d] text-muted-foreground shrink-0", size), p.elapsed(ui) * 1.2)
		return
	}
	if t.has_icon {
		p.image(ui, t.icon, tfmt("size-[%d] shrink-0", size), .Contain)
		return
	}
	letter_tile(ui, t.url, t.title, size)
}

letter_tile :: proc(ui: ^p.Ctx, url, title: string, size: int, radius := 4) {
	idx := p.div(ui, tfmt("size-[%d] rounded-[%d] items-center justify-center shrink-0", size, radius))
	p.style(ui, idx).bg = p.flat(rgb(letter_color(url_host(url) != "" ? url_host(url) : title)))
	p.text(ui, site_letter(url, title), tfmt("text-[%d] font-semibold text-white", max(9, size * 6 / 10)))
	p.end(ui)
}

page_icon :: proc(k: Page_Kind) -> p.Icon {
	switch k {
	case .New_Tab:
		return ICON_HOUSE
	case .Bookmarks:
		return ICON_STAR
	case .History:
		return ICON_CLOCK
	case .Downloads:
		return ICON_DOWNLOAD
	case .Settings:
		return ICON_SETTINGS
	case .Web:
	}
	return ICON_GLOBE
}

// icon_button is a ghost icon button; returns whether it was activated.
icon_button :: proc(ui: ^p.Ctx, ic: p.Icon, enabled := true, active := false, class := "", tint := "") -> bool {
	idx := p.div(ui, "size-8 rounded-md items-center justify-center shrink-0 transition")
	if enabled {
		p.apply(ui, "hover:bg-muted cursor-pointer")
	} else {
		p.apply(ui, "opacity-35")
	}
	if active {
		p.apply(ui, "bg-muted")
	}
	p.apply(ui, class)
	p.icon(ui, ic, p.concat(ui, "size-4 ", tint == "" ? "text-foreground/80" : tint))
	p.end(ui)
	return enabled && p.clickable(ui, idx)
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

frame :: proc(ui: ^p.Ctx, s: ^State) {
	root := p.col(ui, "relative w-full h-full bg-background text-foreground overflow-hidden")
	_ = root
	defer p.end(ui)

	identity_bar(ui, s)
	tab_strip(ui, s)
	toolbar(ui, s)
	if s.prof.settings.show_bookmarks_bar {
		bookmarks_bar(ui, s)
	}
	content(ui, s)
	overlays(ui, s)
}

// identity_bar is a 3 px band in the identity's colour across the top of the
// window: the one thing that says, before anything is read, whose browser this
// is.
identity_bar :: proc(ui: ^p.Ctx, s: ^State) {
	idx := p.div(ui, "w-full h-[3] shrink-0")
	p.style(ui, idx).bg = p.flat(rgb(s.prof.color))
	p.end(ui)
}

tab_strip :: proc(ui: ^p.Ctx, s: ^State) {
	p.row(ui, "w-full h-[40] shrink-0 items-end gap-1 px-2 pt-1.5 bg-muted/70 border-b border-border")
	defer p.end(ui)

	// the identity chip
	chip := p.row(ui, "h-7 mb-1 items-center gap-1.5 pl-1.5 pr-2 rounded-full shrink-0 cursor-pointer hover:bg-background/70 transition")
	if s.overlay == .Identity_Menu {
		p.apply(ui, "bg-background")
	}
	dot := p.div(ui, "size-4 rounded-full items-center justify-center shrink-0")
	p.style(ui, dot).bg = p.flat(rgb(s.prof.color))
	p.text(ui, strings.to_upper(s.prof.identity[:1], context.temp_allocator), "text-[9] font-bold text-white")
	p.end(ui)
	p.text(ui, s.prof.identity, "text-[12.5] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
	p.icon(ui, ICON_CHEVRON_DOWN, "size-3 text-muted-foreground")
	p.end(ui)
	if p.clickable(ui, chip) {
		s.overlay = s.overlay == .Identity_Menu ? .None : .Identity_Menu
		s.menu_sel = 0
	}

	p.div(ui, "w-px h-5 mb-2 bg-border shrink-0")
	p.end(ui)

	// the tabs share what is left, each between 56 and 232 px
	close_idx := -1
	activate := -1
	for t, i in s.tabs {
		p.key(ui, tfmt("tab-%d", t.id))
		active := i == s.active
		tab := p.row(ui, "relative h-[33] flex-1 min-w-[56] max-w-[232] items-center gap-2 pl-3 pr-1.5 rounded-t-lg transition")
		if active {
			p.apply(ui, "bg-background border border-border border-b-0 shadow-sm")
		} else {
			p.apply(ui, "hover:bg-background/55 cursor-pointer")
		}
		favicon(ui, t, 16)
		p.text(ui, tab_title(t), active ? "flex-1 truncate text-[12.5] font-medium" : "flex-1 truncate text-[12.5] text-muted-foreground")
		p.style(ui).shrink = 1
		hovered := p.is_hovered(ui, tab)
		if active || hovered {
			x := p.div(ui, "size-5 rounded-md items-center justify-center shrink-0 hover:bg-muted cursor-pointer")
			p.icon(ui, ICON_X, "size-3.5 text-muted-foreground")
			p.end(ui)
			if p.clickable(ui, x) {
				close_idx = i
			}
		} else {
			p.div(ui, "size-5 shrink-0")
			p.end(ui)
		}
		if t.loading && t.page == .Web && active {
			bar := p.div(ui, "absolute left-[10] bottom-0 h-[2] rounded-full bg-primary/70")
			p.style(ui, bar).w = p.px(max(8, (s.tab_w - 20) * clamp(t.progress, 0.05, 1)))
			p.end(ui)
		}
		p.end(ui)
		if p.clickable(ui, tab) && close_idx != i {
			activate = i
		}
		if hovered && ui.input.pressed[.Middle] {
			close_idx = i
		}
		if active {
			s.tab_w = p.node_rect(ui, tab).w
		}
	}

	plus := p.div(ui, "size-7 mb-1 rounded-md items-center justify-center shrink-0 hover:bg-background/70 cursor-pointer")
	p.icon(ui, ICON_PLUS, "size-4 text-muted-foreground")
	p.end(ui)
	if p.clickable(ui, plus) {
		new_tab(s, PAGE_URLS[.New_Tab])
	}
	p.div(ui, "flex-1")
	p.end(ui)

	// which engine is drawing the pages, always visible
	eng := p.row(ui, "h-6 mb-1.5 items-center gap-1.5 px-2 rounded-full border border-border bg-background/60 shrink-0 cursor-pointer hover:bg-background")
	dotc := s.engine != nil && s.engine.ok ? "bg-emerald-500" : "bg-destructive"
	p.div(ui, p.concat(ui, "size-1.5 rounded-full ", dotc))
	p.end(ui)
	p.text(ui, engine_label(s.engine_kind), "text-[11.5] font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	if p.clickable(ui, eng) {
		open_internal(s, .Settings)
		s.settings_section = 0
	}

	if close_idx >= 0 {
		close_tab(s, close_idx)
	} else if activate >= 0 {
		activate_tab(s, activate)
	}
}

open_internal :: proc(s: ^State, k: Page_Kind) {
	// reuse a tab already showing it
	for t, i in s.tabs {
		if t.page == k {
			activate_tab(s, i)
			return
		}
	}
	t := active_tab(s)
	if t != nil && t.page == .New_Tab {
		navigate(s, t, PAGE_URLS[k])
		activate_tab(s, s.active)
		return
	}
	new_tab(s, PAGE_URLS[k], s.active + 1)
}

toolbar :: proc(ui: ^p.Ctx, s: ^State) {
	t := active_tab(s)
	p.row(ui, "relative w-full h-[46] shrink-0 items-center gap-0.5 px-2 bg-background border-b border-border")
	defer p.end(ui)

	if icon_button(ui, ICON_ARROW_LEFT, can_go_back(t)) {go_back(s)}
	if icon_button(ui, ICON_ARROW_RIGHT, can_go_forward(t)) {go_forward(s)}
	loading := t != nil && t.page == .Web && t.loading
	if icon_button(ui, loading ? ICON_X : ICON_ROTATE_CW, t != nil && t.page == .Web) {
		if loading {stop_loading(s)} else {reload(s)}
	}
	p.div(ui, "w-1.5 shrink-0")
	p.end(ui)

	omnibox(ui, s, t)

	p.div(ui, "w-1.5 shrink-0")
	p.end(ui)
	n, frac := downloads_active(s)
	dl := p.div(ui, "relative size-8 rounded-md items-center justify-center shrink-0 hover:bg-muted cursor-pointer transition")
	if s.overlay == .Downloads {
		p.apply(ui, "bg-muted")
	}
	p.icon(ui, ICON_DOWNLOAD, n > 0 ? "size-4 text-primary" : "size-4 text-foreground/80")
	if n > 0 {
		track := p.div(ui, "absolute left-[7] bottom-[5] w-[18] h-[2] rounded-full bg-muted")
		_ = track
		fill := p.div(ui, "h-[2] rounded-full bg-primary")
		p.style(ui, fill).w = p.px(18 * clamp(frac, 0.08, 1))
		p.end(ui)
		p.end(ui)
	}
	p.end(ui)
	if p.clickable(ui, dl) {
		s.overlay = s.overlay == .Downloads ? .None : .Downloads
	}
	if icon_button(ui, ICON_ELLIPSIS, true, s.overlay == .App_Menu) {
		s.overlay = s.overlay == .App_Menu ? .None : .App_Menu
		s.menu_sel = -1
	}

	// load progress along the toolbar's bottom edge
	if loading {
		bar := p.div(ui, "absolute left-0 bottom-[-1] h-[2] bg-primary")
		p.style(ui, bar).w = p.px(f32(s.window_w) * clamp(t.progress, 0.08, 1))
		p.end(ui)
	}
}

omnibox :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	focused := s.focus == .Omnibox
	box := p.row(ui, "relative flex-1 h-[34] items-center gap-2 pl-3 pr-1 rounded-full border transition")
	if focused {
		p.apply(ui, "bg-background border-ring ring-3 ring-ring/30")
	} else {
		p.apply(ui, "bg-muted/80 border-transparent hover:bg-muted cursor-text")
	}
	s.omni_id = p.node_id(ui, box)

	// the scheme icon
	if focused {
		p.icon(ui, ICON_SEARCH, "size-4 text-muted-foreground shrink-0")
	} else if t == nil || t.page != .Web {
		p.icon(ui, t != nil ? page_icon(t.page) : ICON_SEARCH, "size-4 text-muted-foreground shrink-0")
	} else if strings.has_prefix(t.url, "https://") {
		p.icon(ui, ICON_LOCK, "size-[15] text-muted-foreground shrink-0")
	} else {
		p.icon(ui, ICON_GLOBE, "size-4 text-muted-foreground shrink-0")
	}

	field := p.row(ui, "flex-1 h-full items-center overflow-hidden")
	width := p.rect_of(ui, p.node_id(ui, field)).w
	if focused {
		edit_draw(ui, &s.omni, true, tfmt("Search %s or type a URL", search_engine(s.prof.settings.search).name), "text-[13.5]", 13.5, width)
	} else if t != nil && t.page == .Web && t.url != "" {
		// host emphasised, the rest of the URL muted, the way it is read
		u := t.url
		scheme := ""
		if strings.has_prefix(u, "https://") {
			u = u[8:]
		} else if i := strings.index(u, "://"); i >= 0 {
			scheme = u[:i + 3]
			u = u[i + 3:]
		}
		host_end := strings.index_any(u, "/?#")
		if host_end < 0 {host_end = len(u)}
		if scheme != "" {
			p.text(ui, scheme, "text-[13.5] text-muted-foreground whitespace-nowrap shrink-0")
		}
		p.text(ui, u[:host_end], "text-[13.5] text-foreground whitespace-nowrap shrink-0")
		rest := u[host_end:]
		if rest == "/" {rest = ""}
		if rest != "" {
			p.text(ui, rest, "text-[13.5] text-muted-foreground whitespace-nowrap shrink-0")
		}
	} else {
		p.text(ui, tfmt("Search %s or type a URL", search_engine(s.prof.settings.search).name), "text-[13.5] text-muted-foreground whitespace-nowrap shrink-0")
	}
	p.end(ui)

	if t != nil && t.page == .Web && t.zoom != 1 && !focused {
		z := p.row(ui, "h-6 px-2 items-center rounded-full bg-background border border-border shrink-0 cursor-pointer")
		p.text(ui, tfmt("%d%%", int(t.zoom * 100 + 0.5)), "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.end(ui)
		if p.clickable(ui, z) {set_zoom(s, 1)}
	}
	if !focused {
		af_key_button(ui, s, t)
	}
	if t != nil && t.page == .Web && t.url != "" && !focused {
		marked := bookmarked(&s.bookmarks, t.url) != nil
		star := p.div(ui, "size-7 rounded-full items-center justify-center shrink-0 hover:bg-background cursor-pointer")
		p.icon(ui, ICON_STAR, marked ? "size-4 text-amber-500" : "size-4 text-muted-foreground")
		p.end(ui)
		if p.clickable(ui, star) {toggle_bookmark(s)}
	}
	p.end(ui)

	if !focused && p.clickable(ui, box) {
		focus_omnibox(s, true)
	}
}

bookmarks_bar :: proc(ui: ^p.Ctx, s: ^State) {
	p.row(ui, "w-full h-[32] shrink-0 items-center gap-0.5 px-2 bg-background border-b border-border overflow-hidden")
	defer p.end(ui)
	kids := children(&s.bookmarks, ROOT_TOOLBAR, context.temp_allocator)
	if len(kids) == 0 {
		p.text(ui, "Bookmarks you add to the bar appear here.", "text-[12] text-muted-foreground whitespace-nowrap px-2")
		p.style(ui).shrink = 0
		hint := p.text(ui, "Ctrl D", "text-[11] text-muted-foreground/70 whitespace-nowrap")
		_ = hint
	}
	for k in kids {
		p.key(ui, k.id)
		switch k.kind {
		case "separator":
			p.div(ui, "w-px h-4 mx-1 bg-border shrink-0")
			p.end(ui)
		case "folder":
			b := p.row(ui, "h-6 items-center gap-1.5 px-2 rounded-md shrink-0 hover:bg-muted cursor-pointer")
			p.icon(ui, ICON_FOLDER, "size-3.5 text-muted-foreground")
			p.text(ui, k.title, "text-[12] whitespace-nowrap max-w-[160] truncate")
			p.end(ui)
			if p.clickable(ui, b) {
				s.overlay = .Folder_Menu
				delete(s.folder_menu)
				s.folder_menu = strings.clone(k.id)
				r := p.node_rect(ui, b)
				s.folder_menu_at = {r.x, r.y + r.h + 4}
				s.menu_sel = 0
			}
		case:
			b := p.row(ui, "h-6 items-center gap-1.5 px-2 rounded-md shrink-0 hover:bg-muted cursor-pointer")
			letter_tile(ui, k.url, k.title, 14, 3)
			p.text(ui, k.title != "" ? k.title : display_url(k.url), "text-[12] whitespace-nowrap max-w-[160] truncate")
			p.end(ui)
			if p.clickable(ui, b) {
				if ui.input.mods & {.Ctrl} != {} {
					new_tab(s, k.url, s.active + 1, false)
				} else if t := active_tab(s); t != nil {
					navigate(s, t, k.url)
					set_focus(s, .Page)
				}
			}
		}
	}
	p.div(ui, "flex-1")
	p.end(ui)
	other := p.row(ui, "h-6 items-center gap-1.5 px-2 rounded-md shrink-0 hover:bg-muted cursor-pointer")
	p.icon(ui, ICON_FOLDER, "size-3.5 text-muted-foreground")
	p.text(ui, "Other bookmarks", "text-[12] whitespace-nowrap")
	p.end(ui)
	if p.clickable(ui, other) {
		s.overlay = .Folder_Menu
		delete(s.folder_menu)
		s.folder_menu = strings.clone(ROOT_OTHER)
		r := p.node_rect(ui, other)
		s.folder_menu_at = {r.x + r.w - 260, r.y + r.h + 4}
		s.menu_sel = 0
	}
}

// ---------------------------------------------------------------------------
// The page
// ---------------------------------------------------------------------------

content :: proc(ui: ^p.Ctx, s: ^State) {
	t := active_tab(s)
	area := p.col(ui, "relative flex-1 w-full overflow-hidden bg-background")
	defer p.end(ui)
	if t == nil {
		return
	}
	if t.page != .Web {
		internal_page(ui, s, t)
		s.page_id = p.node_id(ui, area)
		return
	}
	if s.engine == nil || !s.engine.ok {
		engine_missing_page(ui, s)
		return
	}
	if t.crashed != "" {
		crashed_page(ui, s, t)
		return
	}
	if t.error.active {
		error_page(ui, s, t)
		return
	}
	af_bar(ui, s)
	page := p.pixels(ui, "w-full flex-1", t, draw_page)
	st := p.style(ui, page)
	st.cursor = page_cursor(t.cursor)
	s.page_id = p.node_id(ui, page)

	if t.status != "" && s.pointer_in {
		bubble := p.row(ui, "absolute left-0 bottom-0 z-20 max-w-[60%] h-6 items-center px-2.5 rounded-tr-lg bg-popover border-t border-r border-border shadow-sm")
		_ = bubble
		p.text(ui, t.status, "text-[11.5] text-muted-foreground truncate")
		p.end(ui)
	}
	if s.find_open {
		find_bar(ui, s, t)
	}
}

page_cursor :: proc(c: pb.Page_Cursor) -> p.Cursor {
	switch c {
	case .Pointer:
		return .Pointer
	case .Text:
		return .Text
	case .Wait:
		return .Wait
	case .Crosshair:
		return .Crosshair
	case .Move:
		return .Move
	case .Not_Allowed:
		return .Not_Allowed
	case .Grab:
		return .Grab
	case .EW_Resize:
		return .Col_Resize
	case .NS_Resize:
		return .Row_Resize
	case .None, .Default:
	}
	return .Default
}

// draw_page copies the engine's pixels for a tab into the window. The engine
// paints in device pixels, the same scale as the canvas, so this is a row
// copy; while a resize is in flight the uncovered edge is painted white,
// which is what a page's background is far more often than not.
draw_page :: proc(c: ^p.Canvas, r: p.Rect, t: ^Tab) {
	s := g_state
	x0 := int(r.x * c.scale)
	y0 := int(r.y * c.scale)
	w := int(r.w * c.scale)
	h := int(r.h * c.scale)
	clip_x0 := max(x0, int(c.clip.x), 0)
	clip_y0 := max(y0, int(c.clip.y), 0)
	clip_x1 := min(x0 + w, int(c.clip.x + c.clip.w), c.w)
	clip_y1 := min(y0 + h, int(c.clip.y + c.clip.h), c.h)
	if clip_x1 <= clip_x0 || clip_y1 <= clip_y0 {
		return
	}
	surf: ^View_Surface
	if s != nil && s.engine != nil {
		sync.mutex_lock(&s.engine.slock)
		surf = s.engine.surfaces[t.id]
		sync.mutex_unlock(&s.engine.slock)
	}
	white := u32(0xffffffff)
	if surf == nil {
		for y in clip_y0 ..< clip_y1 {
			row := c.px[y * c.w:]
			for x in clip_x0 ..< clip_x1 {
				row[x] = white
			}
		}
		return
	}
	sync.mutex_lock(&surf.lock)
	defer sync.mutex_unlock(&surf.lock)
	for y in clip_y0 ..< clip_y1 {
		sy := y - y0
		dst := c.px[y * c.w:]
		cx1 := clip_x0
		if sy < surf.h && surf.px != nil {
			src := surf.px[sy * surf.w:]
			n := min(clip_x1, x0 + surf.w) - clip_x0
			if n > 0 {
				copy(dst[clip_x0:clip_x0 + n], src[clip_x0 - x0:clip_x0 - x0 + n])
				cx1 = clip_x0 + n
			}
		}
		for x in cx1 ..< clip_x1 {
			dst[x] = white
		}
	}
	surf.dirty = false
}

find_bar :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	bar := p.row(ui, "absolute top-3 right-4 z-30 w-[340] h-10 items-center gap-1 pl-3 pr-1 rounded-lg bg-popover border border-border shadow-lg")
	_ = bar
	f := p.row(ui, "flex-1 h-full items-center overflow-hidden")
	edit_draw(ui, &s.find, s.focus == .Find, "Find in page", "text-[13]", 13, p.rect_of(ui, p.node_id(ui, f)).w)
	p.end(ui)
	if edit_text(&s.find) != "" {
		p.text(ui, tfmt("%d/%d", t.find_active, t.find_count), "text-[12] text-muted-foreground tabular-nums whitespace-nowrap px-1")
		p.style(ui).shrink = 0
	}
	if icon_button(ui, ICON_CHEVRON_DOWN, true, false, "size-7", "text-muted-foreground") {
		engine_find(s.engine, t.id, edit_text(&s.find), true, true)
	}
	if icon_button(ui, ICON_X, true, false, "size-7", "text-muted-foreground") {
		close_find(s)
	}
	p.end(ui)
}

close_find :: proc(s: ^State) {
	if t := active_tab(s); t != nil && t.has_view {
		engine_find(s.engine, t.id, "", true, false)
	}
	s.find_open = false
	set_focus(s, .Page)
}

// ---------------------------------------------------------------------------
// Pages the chrome draws when the engine cannot
// ---------------------------------------------------------------------------

message_page :: proc(ui: ^p.Ctx, ic: p.Icon, tint, title, body: string, detail := "") -> int {
	p.col(ui, "flex-1 w-full items-center justify-center p-8 bg-background")
	p.col(ui, "w-full max-w-[520] gap-4 items-start")
	box := p.div(ui, "size-12 rounded-xl items-center justify-center bg-muted")
	p.icon(ui, ic, p.concat(ui, "size-6 ", tint))
	p.end(ui)
	_ = box
	p.text(ui, title, "text-2xl font-semibold tracking-tight")
	p.text(ui, body, "text-[14] text-muted-foreground leading-[22]")
	if detail != "" {
		p.text(ui, detail, "text-[12] font-mono text-muted-foreground/80")
	}
	return p.row(ui, "gap-2 pt-2")
}

message_page_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

primary_button :: proc(ui: ^p.Ctx, label: string, ic: p.Icon = {}, kbd := "") -> bool {
	idx := sc.button_open(ui, .Default, .Default, {hover = false})
	if ic.d != "" {
		p.icon(ui, ic, "size-4")
	}
	p.text(ui, label, "whitespace-nowrap")
	if kbd != "" {
		p.text(ui, kbd, "text-[11] opacity-60 whitespace-nowrap pl-1")
	}
	sc.button_end(ui)
	p.apply(ui, "hover:bg-primary/85", idx)
	p.focusable(ui, idx)
	return p.activated(ui, idx)
}

outline_button :: proc(ui: ^p.Ctx, label: string, ic: p.Icon = {}, destructive := false) -> bool {
	idx := sc.button_open(ui, destructive ? .Destructive : .Outline, .Default, {})
	if ic.d != "" {
		p.icon(ui, ic, "size-4")
	}
	p.text(ui, label, "whitespace-nowrap")
	sc.button_end(ui)
	p.apply(ui, destructive ? "hover:bg-destructive/20" : "hover:bg-muted", idx)
	p.focusable(ui, idx)
	return p.activated(ui, idx)
}

error_page :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	host := url_host(t.error.url)
	title := "This page could not be reached"
	body := "The page did not load."
	switch t.error.code {
	case -105, -137:
		title = tfmt("%s could not be found", host)
		body = "The address may be mistyped, or the site may not exist. Check the spelling, or search for it instead."
	case -106:
		title = "You are offline"
		body = "This computer is not connected to a network."
	case -102, -118, -109:
		title = tfmt("%s did not respond", host)
		body = "The site refused the connection or took too long to answer."
	case -200 ..= -201, -202 ..= -219:
		title = "The connection is not private"
		body = tfmt("%s presented a certificate this browser does not trust. Somebody may be trying to read what you send it.", host)
	}
	if message_page(ui, ICON_CLOUD_OFF, "text-muted-foreground", title, body, tfmt("%s (%d)", t.error.text, t.error.code)) >= 0 {
		if primary_button(ui, "Try again", ICON_ROTATE_CW, "Ctrl R") {
			reload(s)
		}
		if host != "" && outline_button(ui, tfmt("Search for %s", host), ICON_SEARCH) {
			q, _ := resolve_input(host, search_engine(s.prof.settings.search))
			navigate(s, t, q)
		}
	}
	message_page_end(ui)
}

crashed_page :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	message_page(
		ui,
		ICON_TRIANGLE_ALERT,
		"text-amber-500",
		"This page stopped working",
		tfmt("%s's process for this tab ended. Other tabs are unaffected.", engine_label(s.engine_kind)),
		t.crashed,
	)
	if primary_button(ui, "Reload", ICON_ROTATE_CW) {
		reload(s)
	}
	message_page_end(ui)
}

engine_missing_page :: proc(ui: ^p.Ctx, s: ^State) {
	why := s.engine != nil ? s.engine.error : "no engine"
	message_page(
		ui,
		ICON_PUZZLE,
		"text-muted-foreground",
		tfmt("%s is not available", engine_label(s.engine_kind)),
		"Web pages are drawn by an engine this window starts when it opens. The one this profile is set to use did not start. Bookmarks, history and settings still work; choose another engine in Settings, or install this one.",
		why,
	)
	if primary_button(ui, "Open settings", ICON_SETTINGS) {
		open_internal(s, .Settings)
	}
	message_page_end(ui)
}

@(private = "file")
_unused :: time.Duration
