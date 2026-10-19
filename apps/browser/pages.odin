// The internal pages -- palm://newtab, bookmarks, history, downloads,
// settings -- drawn by the chrome itself with shadcn, never by the engine. A
// web page cannot script them, and they look like the rest of Palmframe.
package browser

import "core:fmt"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

internal_page :: proc(ui: ^p.Ctx, s: ^State, t: ^Tab) {
	switch t.page {
	case .New_Tab:
		new_tab_page(ui, s)
	case .Bookmarks:
		bookmarks_page(ui, s)
	case .History:
		history_page(ui, s)
	case .Downloads:
		downloads_page(ui, s)
	case .Settings:
		settings_page(ui, s)
	case .Web:
	}
}

// page_field is the one text field an internal page has focused; it shares
// one Line_Edit, keyed by the page it belongs to.
page_field :: proc(ui: ^p.Ctx, s: ^State, page: Page_Kind, placeholder: string, class: string, text_class := "text-[13.5]", size: f32 = 13.5) -> (box: int, focused: bool) {
	if s.field_page != page {
		s.field_page = page
		edit_set(&s.field, "")
	}
	focused = s.focus == .Field
	box = p.row(ui, class)
	p.apply(ui, focused ? "border-ring ring-3 ring-ring/30" : "border-input hover:border-ring/60 cursor-text")
	p.icon(ui, ICON_SEARCH, "size-4 text-muted-foreground shrink-0")
	inner := p.row(ui, "flex-1 h-full items-center overflow-hidden")
	edit_draw(ui, &s.field, focused, placeholder, text_class, size, p.rect_of(ui, p.node_id(ui, inner)).w)
	p.end(ui)
	if focused && edit_text(&s.field) != "" {
		x := p.div(ui, "size-6 rounded-md items-center justify-center hover:bg-muted cursor-pointer shrink-0")
		p.icon(ui, ICON_X, "size-3.5 text-muted-foreground")
		p.end(ui)
		if p.clickable(ui, x) {
			edit_set(&s.field, "")
		}
	}
	p.end(ui)
	if p.clickable(ui, box) {
		set_focus(s, .Field)
	}
	return
}

time_ago :: proc(ms: i64) -> string {
	d := (now_ms() - ms) / 1000
	switch {
	case d < 60:
		return "just now"
	case d < 3600:
		return tfmt("%d min ago", d / 60)
	case d < 86400:
		return tfmt("%d h ago", d / 3600)
	case d < 86400 * 7:
		return tfmt("%d days ago", d / 86400)
	}
	return day_label(ms)
}

MONTHS := [?]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
WEEKDAYS := [?]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}

local_time :: proc(ms: i64) -> time.Time {
	t := time.unix(ms / 1000, 0)
	// the machine's offset, best effort: palmy has no tz database binding
	off := local_offset()
	return time.time_add(t, off)
}

local_offset :: proc() -> time.Duration {
	@(static) cached: Maybe(time.Duration)
	if v, ok := cached.?; ok {
		return v
	}
	d: time.Duration
	if out, ok := kit.run({"date", "+%z"}); ok && len(out) >= 5 {
		sign: i64 = out[0] == '-' ? -1 : 1
		h := i64(out[1] - '0') * 10 + i64(out[2] - '0')
		m := i64(out[3] - '0') * 10 + i64(out[4] - '0')
		d = time.Duration(sign * (h * 3600 + m * 60)) * time.Second
	}
	cached = d
	return d
}

day_label :: proc(ms: i64) -> string {
	t := local_time(ms)
	now := local_time(now_ms())
	y, m, d := time.date(t)
	ny, nm, nd := time.date(now)
	if y == ny && m == nm && d == nd {
		return "Today"
	}
	yd := local_time(now_ms() - 86400_000)
	yy, ym, ydd := time.date(yd)
	if y == yy && m == ym && d == ydd {
		return "Yesterday"
	}
	wd := time.weekday(t)
	if y == ny {
		return tfmt("%s %d %s", WEEKDAYS[int(wd)], d, MONTHS[int(m) - 1])
	}
	return tfmt("%d %s %d", d, MONTHS[int(m) - 1], y)
}

clock_label :: proc(ms: i64) -> string {
	t := local_time(ms)
	h, m, _ := time.clock(t)
	return tfmt("%02d:%02d", h, m)
}

// ---------------------------------------------------------------------------
// New tab
// ---------------------------------------------------------------------------

new_tab_page :: proc(ui: ^p.Ctx, s: ^State) {
	page := p.col(ui, "relative flex-1 w-full items-center overflow-scroll bg-background")
	_ = page
	// a wash of the identity colour behind the top of the page
	wash := p.div(ui, "absolute left-0 top-0 w-full h-[340] bg-gradient-to-b")
	ws := p.style(ui, wash)
	c := rgb(s.prof.color)
	c.a = s.dark ? 46 : 30
	c2 := c
	c2.a = 0
	ws.bg = {color = c, color2 = c2, gradient = true, vertical = true}
	p.end(ui)

	p.col(ui, "relative w-full max-w-[760] px-8 pt-[88] pb-12 gap-8")

	// greeting
	now := local_time(now_ms())
	h, _, _ := time.clock(now)
	greet := h < 5 ? "Good night" : h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
	p.col(ui, "items-center gap-2")
	p.text(ui, clock_label(now_ms()), "text-[52] font-semibold tracking-tight tabular-nums leading-[56]")
	p.row(ui, "items-center gap-2")
	p.text(ui, tfmt("%s · %s", greet, day_label(now_ms())), "text-[14] text-muted-foreground")
	p.end(ui)
	p.end(ui)

	// the search box: a doorway to the omnibox, which does the work
	box := p.row(ui, "h-[52] w-full items-center gap-3 px-5 rounded-2xl bg-card border border-border shadow-lg cursor-text hover:border-ring/60 transition")
	p.icon(ui, ICON_SEARCH, "size-5 text-muted-foreground")
	p.text(ui, tfmt("Search %s or type a URL", search_engine(s.prof.settings.search).name), "flex-1 text-[15] text-muted-foreground")
	sc.kbd(ui, "Ctrl L", "border border-border")
	p.end(ui)
	if p.clickable(ui, box) {
		focus_omnibox(s, false)
	}

	// shortcuts: the most visited sites, then the bar's bookmarks
	tiles := make([dynamic]Site, context.temp_allocator)
	for st in history_top(&s.history, 8, context.temp_allocator) {
		append(&tiles, st)
	}
	if len(tiles) < 8 {
		for b in children(&s.bookmarks, ROOT_TOOLBAR, context.temp_allocator) {
			if b.kind != "bookmark" || len(tiles) >= 8 {
				continue
			}
			dup := false
			for x in tiles {
				if x.host == url_host(b.url) {dup = true}
			}
			if !dup {
				append(&tiles, Site{url = b.url, title = b.title, host = url_host(b.url)})
			}
		}
	}
	if len(tiles) > 0 {
		p.row(ui, "w-full flex-wrap justify-center gap-3")
		for st, i in tiles {
			p.key(ui, tfmt("tile-%d", i))
			tile := p.col(ui, "w-[150] h-[112] items-center justify-center gap-2.5 px-3 rounded-xl border border-transparent hover:bg-muted/70 hover:border-border cursor-pointer transition")
			p.focusable(ui, tile)
			if p.focused(ui, tile) {
				p.apply(ui, "bg-muted/70 border-ring ring-3 ring-ring/30", tile)
			}
			letter_tile(ui, st.url, st.title, 44, 12)
			p.col(ui, "w-full items-center gap-0")
			p.text(ui, st.title != "" ? st.title : st.host, "w-full text-center text-[12.5] font-medium truncate")
			p.text(ui, st.host, "w-full text-center text-[11] text-muted-foreground truncate")
			p.end(ui)
			p.end(ui)
			if p.activated(ui, tile) {
				if t := active_tab(s); t != nil {
					navigate(s, t, st.url)
					set_focus(s, .Page)
				}
			}
		}
		p.end(ui)
	}

	// two columns: recent visits and the bar
	p.row(ui, "w-full gap-4 items-start")
	card_list :: proc(ui: ^p.Ctx, title: string, ic: p.Icon) {
		p.col(ui, "flex-1 min-w-0 rounded-xl border border-border bg-card p-2 gap-0.5")
		p.row(ui, "items-center gap-2 px-2 pt-1 pb-2")
		p.icon(ui, ic, "size-4 text-muted-foreground")
		p.text(ui, title, "text-[13] font-semibold")
		p.end(ui)
	}
	link_row :: proc(ui: ^p.Ctx, s: ^State, url, title, right: string) {
		p.key(ui, url)
		r := p.row(ui, "h-9 items-center gap-2.5 px-2 rounded-md hover:bg-muted cursor-pointer")
		letter_tile(ui, url, title, 18, 5)
		p.text(ui, title != "" ? title : display_url(url), "flex-1 text-[12.5] truncate")
		if right != "" {
			p.text(ui, right, "text-[11] text-muted-foreground whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)
		if p.clickable(ui, r) {
			if t := active_tab(s); t != nil {
				navigate(s, t, url)
				set_focus(s, .Page)
			}
		}
	}
	card_list(ui, "Recently visited", ICON_CLOCK)
	shown := 0
	seen := make(map[string]bool, context.temp_allocator)
	#reverse for v in s.history.visits {
		if shown == 6 {break}
		if seen[v.url] {continue}
		seen[v.url] = true
		link_row(ui, s, v.url, v.title, time_ago(v.at))
		shown += 1
	}
	if shown == 0 {
		p.text(ui, "Pages you visit will show up here.", "text-[12.5] text-muted-foreground px-2 pb-2")
	}
	p.end(ui)
	card_list(ui, "Bookmarks", ICON_STAR)
	bms := all_visible(&s.bookmarks, context.temp_allocator)
	for b, i in bms {
		if i == 6 {break}
		link_row(ui, s, b.url, b.title, "")
	}
	if len(bms) == 0 {
		p.text(ui, "Press Ctrl D on any page to keep it here.", "text-[12.5] text-muted-foreground px-2 pb-2")
	}
	p.end(ui)
	p.end(ui)

	// what is drawing the web, and whose browser this is
	p.row(ui, "w-full justify-center items-center gap-2 pt-2")
	dot := p.div(ui, "size-2 rounded-full")
	p.style(ui, dot).bg = p.flat(rgb(s.prof.color))
	p.end(ui)
	ver := s.engine != nil && s.engine.ok ? s.engine.version : "not running"
	p.text(ui, tfmt("%s profile · %s %s", s.prof.identity, engine_label(s.engine_kind), short_version(ver)), "text-[12] text-muted-foreground")
	ch := p.text(ui, "Change", "text-[12] text-blue-600 underline cursor-pointer")
	if p.clickable(ui, ch) {
		open_internal(s, .Settings)
		s.settings_section = 0
	}
	p.end(ui)

	p.end(ui)
	p.end(ui)
}

short_version :: proc(v: string) -> string {
	if i := strings.index_byte(v, ' '); i > 0 {
		return v[:i]
	}
	return v
}

// ---------------------------------------------------------------------------
// Bookmarks manager
// ---------------------------------------------------------------------------

page_header :: proc(ui: ^p.Ctx, title, subtitle: string) {
	p.col(ui, "gap-1")
	p.text(ui, title, "text-2xl font-semibold tracking-tight")
	if subtitle != "" {
		p.text(ui, subtitle, "text-[13] text-muted-foreground")
	}
	p.end(ui)
}

bookmarks_page :: proc(ui: ^p.Ctx, s: ^State) {
	p.row(ui, "flex-1 w-full overflow-hidden")
	defer p.end(ui)

	// folders
	p.col(ui, "w-[260] h-full shrink-0 bg-sidebar border-r border-border p-3 gap-1 overflow-scroll")
	p.text(ui, "Folders", "text-[11.5] font-medium text-muted-foreground px-2 pt-1 pb-1.5 uppercase tracking-wide")
	for f in folders(&s.bookmarks, context.temp_allocator) {
		p.key(ui, f.id)
		on := s.bm_folder == f.id && edit_text(&s.field) == ""
		row := p.row(ui, "h-8 items-center gap-2 px-2 rounded-md cursor-pointer")
		p.apply(ui, on ? "bg-sidebar-accent text-sidebar-accent-foreground font-medium" : "hover:bg-sidebar-accent/60")
		pad := p.div(ui, "shrink-0")
		p.style(ui, pad).w = p.px(f32(f.depth) * 14)
		p.end(ui)
		p.icon(ui, f.depth == 0 ? (f.id == ROOT_TOOLBAR ? ICON_PANEL_TOP : ICON_FOLDER) : ICON_FOLDER, "size-4 text-muted-foreground")
		title := f.path
		if i := strings.last_index(title, " / "); i >= 0 {title = title[i + 3:]}
		p.text(ui, title, "flex-1 text-[13] truncate")
		n := len(children(&s.bookmarks, f.id, context.temp_allocator))
		if n > 0 {
			p.text(ui, tfmt("%d", n), "text-[11] text-muted-foreground tabular-nums")
		}
		p.end(ui)
		if p.clickable(ui, row) {
			s.bm_folder = strings.clone(f.id)
			edit_set(&s.field, "")
			s.list_sel = 0
		}
	}
	p.div(ui, "flex-1")
	p.end(ui)
	if outline_button(ui, "New folder", ICON_PLUS) {
		f := bookmark_add(&s.bookmarks, s.bm_folder, "New folder", "", "folder")
		bookmarks_save(&s.bookmarks)
		open_bookmark_editor(s, f.id, true)
	}
	p.end(ui)

	// the list
	p.col(ui, "flex-1 h-full min-w-0 overflow-scroll")
	p.col(ui, "w-full max-w-[860] px-10 pt-8 pb-12 gap-5")
	query := strings.to_lower(strings.trim_space(edit_text(&s.field)), context.temp_allocator)
	folder_title := "Bookmarks"
	if f := find(&s.bookmarks, s.bm_folder); f != nil {folder_title = f.title}
	n_all := len(all_visible(&s.bookmarks, context.temp_allocator))
	page_header(ui, query != "" ? "Search results" : folder_title, tfmt("%d bookmarks in the %s profile · synced format, ready for your Palmframe account", n_all, s.prof.identity))
	p.row(ui, "w-full items-center gap-2")
	page_field(ui, s, .Bookmarks, "Search bookmarks", "flex-1 h-9 items-center gap-2 px-3 rounded-lg border bg-background")
	if outline_button(ui, "Export", ICON_FILE_DOWN) {
		path := tfmt("%s/bookmarks-%s.html", downloads_dir(&s.prof, context.temp_allocator), s.prof.identity)
		if write_atomic(path, transmute([]u8)export_html(&s.bookmarks, context.temp_allocator)) {
			toast(s, tfmt("Exported to %s", file_name(path)))
		}
	}
	p.end(ui)

	items := make([dynamic]Bookmark, context.temp_allocator)
	if query != "" {
		for b in all_visible(&s.bookmarks, context.temp_allocator) {
			if strings.contains(strings.to_lower(b.title, context.temp_allocator), query) || strings.contains(strings.to_lower(b.url, context.temp_allocator), query) {
				append(&items, b)
			}
		}
	} else {
		append(&items, ..children(&s.bookmarks, s.bm_folder, context.temp_allocator))
	}
	s.list_len = len(items)
	s.list_sel = clamp(s.list_sel, 0, max(0, len(items) - 1))
	if len(items) == 0 {
		sc.empty_open(ui, "w-full py-14 rounded-xl border border-dashed border-border")
		sc.empty_header_open(ui)
		sc.empty_media_icon(ui, ICON_STAR)
		sc.empty_title(ui, query != "" ? "No bookmarks match" : "This folder is empty")
		sc.empty_description(ui, query != "" ? "Try another word, or part of the address." : "Press Ctrl D on a page to bookmark it, or move bookmarks here with the editor.")
		sc.empty_header_end(ui)
		sc.empty_end(ui)
		return_after_list(ui)
		return
	}
	p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
	for b, i in items {
		p.key(ui, b.id)
		sel := i == s.list_sel && s.focus != .Field
		row := p.row(ui, "h-12 items-center gap-3 px-3 border-b border-border/60 cursor-pointer")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-muted/60")
		switch b.kind {
		case "folder":
			box := p.div(ui, "size-7 rounded-md items-center justify-center bg-muted shrink-0")
			p.icon(ui, ICON_FOLDER, "size-4 text-muted-foreground")
			p.end(ui)
			_ = box
			p.col(ui, "flex-1 min-w-0")
			p.text(ui, b.title, "text-[13.5] font-medium truncate")
			p.text(ui, tfmt("%d items", len(children(&s.bookmarks, b.id, context.temp_allocator))), "text-[11.5] text-muted-foreground")
			p.end(ui)
		case "separator":
			p.div(ui, "flex-1 h-px bg-border")
			p.end(ui)
		case:
			letter_tile(ui, b.url, b.title, 28, 7)
			p.col(ui, "flex-1 min-w-0")
			p.text(ui, b.title != "" ? b.title : display_url(b.url), "text-[13.5] font-medium truncate")
			p.text(ui, display_url(b.url), "text-[11.5] text-muted-foreground truncate")
			p.end(ui)
		}
		if sel || p.is_hovered(ui, row) {
			if icon_button(ui, ICON_PENCIL, true, false, "size-7", "text-muted-foreground") {
				open_bookmark_editor(s, b.id, false)
			}
			if icon_button(ui, ICON_TRASH, true, false, "size-7", "text-muted-foreground") {
				delete_bookmark_undoable(s, b.id)
			}
		}
		p.end(ui)
		if p.clickable(ui, row) {
			if s.list_sel == i || ui.input.mods & {.Ctrl} != {} {
				open_bookmark_item(s, b, ui.input.mods & {.Ctrl} != {})
			}
			s.list_sel = i
			if s.focus == .Field {set_focus(s, .None)}
		}
		if sel && s.list_enter {
			open_bookmark_item(s, b, s.list_enter_new)
		}
		if sel && s.list_delete {
			delete_bookmark_undoable(s, b.id)
		}
		if sel && s.list_edit {
			open_bookmark_editor(s, b.id, false)
		}
		if sel && s.list_move != 0 && query == "" {
			j := i + s.list_move
			if j >= 0 && j < len(items) {
				after := ""
				if s.list_move < 0 {
					if j > 0 {after = items[j - 1].id}
				} else {
					after = items[j].id
				}
				bookmark_move(&s.bookmarks, b.id, s.bm_folder, after)
				bookmarks_save(&s.bookmarks)
				s.list_sel = j
			}
		}
	}
	p.end(ui)
	p.row(ui, "items-center gap-4 pt-1")
	hint_pair(ui, "↑↓", "select")
	hint_pair(ui, "Enter", "open")
	hint_pair(ui, "E", "edit")
	hint_pair(ui, "Del", "delete")
	hint_pair(ui, "Alt ↑↓", "reorder")
	hint_pair(ui, "/", "search")
	p.end(ui)
	return_after_list(ui)
}

return_after_list :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

open_bookmark_item :: proc(s: ^State, b: Bookmark, new_tab_: bool) {
	if b.kind == "folder" {
		s.bm_folder = strings.clone(b.id)
		s.list_sel = 0
		edit_set(&s.field, "")
		return
	}
	if b.kind != "bookmark" {
		return
	}
	if new_tab_ {
		new_tab(s, b.url, s.active + 1, false)
	} else if t := active_tab(s); t != nil {
		navigate(s, t, b.url)
		set_focus(s, .Page)
	}
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

history_page :: proc(ui: ^p.Ctx, s: ^State) {
	p.col(ui, "flex-1 w-full items-center overflow-scroll")
	p.col(ui, "w-full max-w-[860] px-10 pt-8 pb-12 gap-5")
	page_header(ui, "History", tfmt("Visits in the %s profile. History stays on this device; it is never synced.", s.prof.identity))
	p.row(ui, "w-full items-center gap-2")
	page_field(ui, s, .History, "Search history", "flex-1 h-9 items-center gap-2 px-3 rounded-lg border bg-background")
	if outline_button(ui, "Clear history", ICON_TRASH, true) {
		s.overlay = .Confirm_Clear
	}
	p.end(ui)

	query := strings.to_lower(strings.trim_space(edit_text(&s.field)), context.temp_allocator)
	rows := make([dynamic]Visit, context.temp_allocator)
	#reverse for v in s.history.visits {
		if query != "" && !strings.contains(strings.to_lower(v.title, context.temp_allocator), query) && !strings.contains(strings.to_lower(v.url, context.temp_allocator), query) {
			continue
		}
		append(&rows, v)
		if len(rows) >= 400 {break}
	}
	s.list_len = len(rows)
	s.list_sel = clamp(s.list_sel, 0, max(0, len(rows) - 1))
	if len(rows) == 0 {
		sc.empty_open(ui, "w-full py-14 rounded-xl border border-dashed border-border")
		sc.empty_header_open(ui)
		sc.empty_media_icon(ui, ICON_CLOCK)
		sc.empty_title(ui, query != "" ? "Nothing matches" : "No history yet")
		sc.empty_description(ui, query != "" ? "Try part of the title or the address." : "Pages you visit in this profile are listed here, newest first.")
		sc.empty_header_end(ui)
		sc.empty_end(ui)
	}
	day := ""
	for v, i in rows {
		d := day_label(v.at)
		if d != day {
			if day != "" {p.end(ui)}
			day = d
			p.text(ui, d, "text-[12.5] font-semibold text-muted-foreground pt-2")
			p.col(ui, "w-full rounded-xl border border-border overflow-hidden")
		}
		p.key(ui, v.id)
		sel := i == s.list_sel && s.focus != .Field
		row := p.row(ui, "h-11 items-center gap-3 px-3 border-b border-border/60 cursor-pointer")
		p.apply(ui, sel ? "bg-accent" : "hover:bg-muted/60")
		p.text(ui, clock_label(v.at), "w-[44] text-[12] text-muted-foreground tabular-nums shrink-0")
		letter_tile(ui, v.url, v.title, 20, 5)
		p.text(ui, v.title != "" ? v.title : display_url(v.url), "flex-1 text-[13] truncate")
		p.text(ui, url_host(v.url), "text-[12] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		if sel || p.is_hovered(ui, row) {
			if icon_button(ui, ICON_X, true, false, "size-7", "text-muted-foreground") {
				history_forget_url(&s.history, v.url)
			}
		}
		p.end(ui)
		if p.clickable(ui, row) {
			s.list_sel = i
			open_url_here(s, v.url, ui.input.mods & {.Ctrl} != {})
		}
		if sel && s.list_enter {
			open_url_here(s, v.url, s.list_enter_new)
		}
		if sel && s.list_delete {
			history_forget_url(&s.history, v.url)
		}
	}
	if day != "" {p.end(ui)}
	p.end(ui)
	p.end(ui)
}

open_url_here :: proc(s: ^State, url: string, new_tab_: bool) {
	if new_tab_ {
		new_tab(s, url, s.active + 1, false)
	} else if t := active_tab(s); t != nil {
		navigate(s, t, url)
		set_focus(s, .Page)
	}
}

// ---------------------------------------------------------------------------
// Downloads
// ---------------------------------------------------------------------------

downloads_page :: proc(ui: ^p.Ctx, s: ^State) {
	p.col(ui, "flex-1 w-full items-center overflow-scroll")
	p.col(ui, "w-full max-w-[760] px-10 pt-8 pb-12 gap-5")
	page_header(ui, "Downloads", tfmt("Saved to %s", downloads_dir(&s.prof, context.temp_allocator)))
	if len(s.downloads) == 0 {
		sc.empty_open(ui, "w-full py-14 rounded-xl border border-dashed border-border")
		sc.empty_header_open(ui)
		sc.empty_media_icon(ui, ICON_DOWNLOAD)
		sc.empty_title(ui, "No downloads")
		sc.empty_description(ui, "Files you download appear here, with their progress.")
		sc.empty_header_end(ui)
		sc.empty_end(ui)
	} else {
		p.col(ui, "w-full rounded-xl border border-border p-1.5 gap-0.5")
		#reverse for &d in s.downloads {
			download_row(ui, s, &d, false)
		}
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

SECTIONS := [?]struct {
	name: string,
	icon: p.Icon,
}{{"Engine", ICON_PUZZLE}, {"Search", ICON_SEARCH}, {"Appearance", ICON_SUN}, {"On startup", ICON_HOUSE}, {"Profile", ICON_CIRCLE_USER}, {"Sync", ICON_CLOUD}, {"Privacy", ICON_SHIELD}}

settings_page :: proc(ui: ^p.Ctx, s: ^State) {
	p.row(ui, "flex-1 w-full overflow-hidden")
	defer p.end(ui)
	p.col(ui, "w-[240] h-full shrink-0 bg-sidebar border-r border-border p-3 gap-0.5")
	p.text(ui, "Settings", "text-[15] font-semibold px-2 pt-1 pb-3")
	for sec, i in SECTIONS {
		row := p.row(ui, "h-8 items-center gap-2.5 px-2 rounded-md cursor-pointer")
		on := s.settings_section == i
		p.apply(ui, on ? "bg-sidebar-accent font-medium" : "hover:bg-sidebar-accent/60")
		p.focusable(ui, row)
		p.icon(ui, sec.icon, "size-4 text-muted-foreground")
		p.text(ui, sec.name, "text-[13]")
		p.end(ui)
		if p.activated(ui, row) {
			s.settings_section = i
		}
	}
	p.end(ui)

	p.col(ui, "flex-1 h-full min-w-0 overflow-scroll")
	p.col(ui, "w-full max-w-[720] px-10 pt-8 pb-14 gap-6")
	switch s.settings_section {
	case 0:
		settings_engine(ui, s)
	case 1:
		settings_search(ui, s)
	case 2:
		settings_appearance(ui, s)
	case 3:
		settings_startup(ui, s)
	case 4:
		settings_profile(ui, s)
	case 5:
		settings_sync(ui, s)
	case 6:
		settings_privacy(ui, s)
	}
	p.end(ui)
	p.end(ui)
}

section_card :: proc(ui: ^p.Ctx, title, desc: string) {
	p.col(ui, "w-full rounded-xl border border-border bg-card p-5 gap-4")
	p.col(ui, "gap-1")
	p.text(ui, title, "text-[15] font-semibold")
	if desc != "" {
		p.text(ui, desc, "text-[13] text-muted-foreground leading-[20]")
	}
	p.end(ui)
}

switch_row :: proc(ui: ^p.Ctx, label, desc: string, on: bool) -> bool {
	row := p.row(ui, "w-full items-center gap-4 py-1 cursor-pointer rounded-md")
	p.focusable(ui, row)
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, label, "text-[13.5] font-medium")
	if desc != "" {
		p.text(ui, desc, "text-[12.5] text-muted-foreground leading-[18]")
	}
	p.end(ui)
	sc.switch_(ui, on, .Default, {focus = p.focused(ui, row)})
	p.end(ui)
	return p.activated(ui, row)
}

choice_row :: proc(ui: ^p.Ctx, label, desc: string, on: bool, ic: p.Icon = {}) -> bool {
	row := p.row(ui, "w-full items-center gap-3 px-3 py-2.5 rounded-lg border cursor-pointer transition")
	p.apply(ui, on ? "border-primary bg-primary/5 ring-1 ring-primary" : "border-border hover:bg-muted/60")
	p.focusable(ui, row)
	if p.focused(ui, row) {
		p.apply(ui, "ring-3 ring-ring/30", row)
	}
	if ic.d != "" {
		p.icon(ui, ic, "size-4 text-muted-foreground")
	}
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, label, "text-[13.5] font-medium")
	if desc != "" {
		p.text(ui, desc, "text-[12.5] text-muted-foreground")
	}
	p.end(ui)
	dot := p.div(ui, "size-4 rounded-full border items-center justify-center shrink-0")
	p.apply(ui, on ? "border-primary" : "border-input", dot)
	if on {
		p.div(ui, "size-2 rounded-full bg-primary")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	return p.activated(ui, row)
}

settings_engine :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Engine", "Which engine draws web pages in this profile. Everything around the page — tabs, the address bar, bookmarks, these settings — is Palmframe's own, whichever you choose.")
	chosen := profile_engine(&s.prof)
	ENGINES := [2]struct {
		kind:  Engine_Kind,
		title: string,
		what:  string,
		pros:  [3]string,
		limit: string,
	}{
		{
			.Chromium,
			"Chromium",
			"Blink and V8, embedded through CEF's off-screen rendering",
			{"Pages are drawn straight into shared memory, only what changed", "Renderers run in Chromium's sandbox: their own user, PID and network namespaces, under seccomp", "Menus, page dialogs and downloads are this window's own"},
			"palm add palm-browser-cef — 164 MB to download, 375 MB installed.",
		},
		{
			.Firefox,
			"Firefox",
			"Gecko and SpiderMonkey, running Firefox itself as a client of a private compositor",
			{"Mozilla's own Firefox, unmodified, with its own content sandbox", "Firefox draws into a compositor that exists only for this window", "Steered over WebDriver BiDi, Firefox's standard remote protocol"},
			"palm add firefox — 158 MB, 397 MB installed. Find in page shows no match count, downloads no progress, and a page's own pop-up windows open as tabs.",
		},
	}
	for e in ENGINES {
		info := engine_info(e.kind)
		on := chosen == e.kind
		running := s.engine_kind == e.kind && s.engine != nil && s.engine.ok
		card := p.col(ui, "w-full rounded-xl border p-5 gap-3 cursor-pointer transition")
		p.apply(ui, on ? "border-foreground/40 bg-card" : "border-border bg-card hover:bg-muted/40")
		p.focusable(ui, card)
		if p.focused(ui, card) {
			p.apply(ui, "ring-3 ring-ring/30", card)
		}
		p.row(ui, "items-center gap-3")
		logo := p.div(ui, "size-10 rounded-xl items-center justify-center shrink-0")
		p.style(ui, logo).bg = p.flat(rgb(e.kind == .Chromium ? 0x1a73e8 : 0xff7139))
		p.icon(ui, e.kind == .Chromium ? ICON_EARTH : ICON_FLAME, "size-5 text-white")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5")
		p.row(ui, "items-center gap-2")
		p.text(ui, e.title, "text-[15] font-semibold")
		if running {
			sc.badge(ui, tfmt("Running · %s", short_version(s.engine.version)), .Secondary)
		} else if !info.available {
			sc.badge(ui, "Not installed", .Outline)
		} else {
			sc.badge(ui, "Installed", .Outline)
		}
		p.end(ui)
		p.text(ui, e.what, "text-[12.5] text-muted-foreground")
		p.end(ui)
		dot := p.div(ui, "size-5 rounded-full border-2 items-center justify-center shrink-0")
		p.apply(ui, on ? "border-primary" : "border-input", dot)
		if on {
			p.div(ui, "size-2.5 rounded-full bg-primary")
			p.end(ui)
		}
		p.end(ui)
		p.end(ui)
		p.col(ui, "gap-1.5 pl-[52]")
		for pro in e.pros {
			p.row(ui, "items-start gap-2")
			p.icon(ui, ICON_CHECK, "size-3.5 text-muted-foreground mt-[3]")
			p.text(ui, pro, "flex-1 text-[12.5] leading-[19]")
			p.end(ui)
		}
		p.text(ui, e.limit, "text-[12] text-muted-foreground pt-1 leading-[18]")
		if e.kind == .Firefox {
			terms := p.text(ui, "Firefox is subject to Mozilla's Terms of Use", "text-[12] text-blue-600 underline cursor-pointer")
			if p.clickable(ui, terms) {
				new_tab(s, "https://www.mozilla.org/about/legal/terms/firefox/", s.active + 1)
			}
		}
		if !info.available {
			p.text(ui, info.detail, "text-[12] text-destructive pt-1")
		}
		p.end(ui)
		p.end(ui)
		if p.activated(ui, card) && !on {
			s.prof.settings.engine = engine_name(e.kind)
			settings_save(&s.prof)
		}
	}
	if chosen != s.engine_kind {
		p.row(ui, "w-full items-center gap-3 px-4 py-3 rounded-xl border border-amber-500/40 bg-amber-500/10")
		p.icon(ui, ICON_REFRESH_CW, "size-4 text-amber-600")
		p.col(ui, "flex-1 gap-0.5")
		p.text(ui, tfmt("Restart to switch to %s", engine_label(chosen)), "text-[13.5] font-medium")
		p.text(ui, "Open tabs come back after the restart. Cookies and site data belong to each engine and are not carried over.", "text-[12.5] text-muted-foreground")
		p.end(ui)
		if primary_button(ui, "Restart now", ICON_REFRESH_CW) {
			s.restart_wanted = true
			s.quit = true
		}
		p.end(ui)
	}
}

settings_search :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Search", "What the address bar searches when what you type is not an address.")
	p.col(ui, "w-full gap-2")
	for e in SEARCH_ENGINES {
		if choice_row(ui, e.name, display_url(e.home), s.prof.settings.search == e.id, ICON_SEARCH) {
			s.prof.settings.search = e.id
			settings_save(&s.prof)
		}
	}
	p.end(ui)
}

settings_appearance :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Appearance", "")
	section_card(ui, "Theme", "Applies to the browser and to pages that follow the system's light or dark preference.")
	p.row(ui, "gap-2")
	for opt in ([?]struct {
		id, label: string,
		ic:        p.Icon,
	}{{"light", "Light", ICON_SUN}, {"dark", "Dark", ICON_MOON}}) {
		on := (opt.id == "dark") == s.dark
		b := p.row(ui, "h-9 items-center gap-2 px-4 rounded-lg border cursor-pointer")
		p.apply(ui, on ? "border-primary bg-primary/5 ring-1 ring-primary" : "border-border hover:bg-muted")
		p.focusable(ui, b)
		p.icon(ui, opt.ic, "size-4")
		p.text(ui, opt.label, "text-[13]")
		p.end(ui)
		if p.activated(ui, b) {
			set_theme(s, opt.id == "dark")
		}
	}
	p.end(ui)
	p.end(ui)
	section_card(ui, "Toolbar", "")
	if switch_row(ui, "Show the bookmarks bar", "Ctrl Shift B", s.prof.settings.show_bookmarks_bar) {
		toggle_bookmarks_bar(s)
	}
	p.end(ui)
}

set_theme :: proc(s: ^State, dark: bool) {
	s.dark = dark
	s.prof.settings.theme = dark ? "dark" : "light"
	settings_save(&s.prof)
	sc.register_shadcn_theme(dark)
	engine_theme(s.engine, dark)
}

settings_startup :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "On startup", "")
	section_card(ui, "Session", "")
	if switch_row(ui, "Reopen the tabs from last time", "Tabs load when you first switch to them, so a long session starts quickly.", s.prof.settings.restore_session) {
		s.prof.settings.restore_session = !s.prof.settings.restore_session
		settings_save(&s.prof)
	}
	p.end(ui)
	section_card(ui, "Downloads", tfmt("Files are saved to %s without asking.", downloads_dir(&s.prof, context.temp_allocator)))
	p.end(ui)
}

settings_profile :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Profile", "One browser profile per Palmframe identity. Cookies, site storage, history and bookmarks never cross between them: each identity's engine is started with its own directory and nothing else.")
	section_card(ui, "This window", "")
	p.row(ui, "items-center gap-3")
	dot := p.div(ui, "size-10 rounded-full items-center justify-center shrink-0")
	p.style(ui, dot).bg = p.flat(rgb(s.prof.color))
	p.text(ui, strings.to_upper(s.prof.identity[:1], context.temp_allocator), "text-[16] font-bold text-white")
	p.end(ui)
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, s.prof.identity, "text-[14] font-semibold")
	p.text(ui, s.prof.dir, "text-[12] font-mono text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)
	p.end(ui)
	section_card(ui, "Other identities", "Each opens in its own window, with its own colour along the top.")
	others := profile_list(context.temp_allocator)
	any := false
	for n in others {
		if n == s.prof.identity {continue}
		any = true
		p.key(ui, n)
		p.row(ui, "items-center gap-3 h-10")
		d := p.div(ui, "size-5 rounded-full shrink-0")
		p.style(ui, d).bg = p.flat(rgb(identity_color(n)))
		p.end(ui)
		p.text(ui, n, "flex-1 text-[13.5]")
		if outline_button(ui, "Open window", ICON_PANEL_TOP) {
			new_window(s, n)
		}
		p.end(ui)
	}
	if !any {
		p.text(ui, "No other profiles yet. A window opened with --identity work creates one.", "text-[12.5] text-muted-foreground")
	}
	p.end(ui)
}

settings_sync :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Sync", "Bookmarks can sync through your Palmframe account, per identity: a work window syncs work bookmarks and cannot see personal ones — the database refuses, not just this window.")
	section_card(ui, "Bookmarks", "")
	pend := pending(&s.bookmarks, context.temp_allocator)
	p.row(ui, "items-center gap-3")
	p.icon(ui, s.prof.settings.sync_bookmarks ? ICON_CLOUD : ICON_CLOUD_OFF, "size-5 text-muted-foreground")
	p.col(ui, "flex-1 gap-0.5")
	p.text(ui, s.prof.settings.sync_bookmarks ? "Sync is on" : "Sync is off", "text-[13.5] font-medium")
	status := s.sync_status
	if status == "" {
		status = tfmt("%d changes waiting to be sent", len(pend))
	}
	p.text(ui, status, "text-[12.5] text-muted-foreground")
	p.end(ui)
	if s.prof.settings.sync_bookmarks {
		if outline_button(ui, s.sync_busy ? "Syncing…" : "Sync now", ICON_REFRESH_CW) && !s.sync_busy {
			sync_now(s)
		}
	}
	p.end(ui)
	if switch_row(ui, "Sync bookmarks", tfmt("Signs in through the Palmframe account on this machine, with a session scoped to the %s identity.", s.prof.identity), s.prof.settings.sync_bookmarks) {
		s.prof.settings.sync_bookmarks = !s.prof.settings.sync_bookmarks
		settings_save(&s.prof)
		if s.prof.settings.sync_bookmarks {
			sync_now(s)
		}
	}
	p.end(ui)
	section_card(ui, "History, passwords and cookies", "Not synced. History stays on this device; passwords belong in the vault; cookies belong to the engine.")
	p.end(ui)
}

settings_privacy :: proc(ui: ^p.Ctx, s: ^State) {
	page_header(ui, "Privacy", "")
	section_card(ui, "Browsing history", tfmt("%d visits are kept for the %s profile, on this device only.", len(s.history.visits), s.prof.identity))
	p.row(ui, "gap-2")
	if outline_button(ui, "Clear history…", ICON_TRASH, true) {
		s.overlay = .Confirm_Clear
	}
	p.end(ui)
	p.end(ui)
	section_card(ui, "Sandbox", sandbox_text(s))
	p.end(ui)
}

sandbox_text :: proc(s: ^State) -> string {
	switch s.engine_kind {
	case .Chromium:
		return "Pages run in Chromium's renderer processes, inside its namespace sandbox with a seccomp filter. The browser window itself never touches page content: it receives pixels and sends input."
	case .Firefox:
		return "Pages run in Firefox's content processes under Firefox's own sandbox. Firefox talks to a private compositor that exists only for this window, so it cannot see the rest of the desktop."
	}
	return ""
}

@(private = "file")
_unused :: fmt.Info
