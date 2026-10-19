// Everything drawn above the page: the omnibox suggestions, menus, the
// bookmark editor, the downloads panel, the page's own dialogs, and toasts.
// There is no xdg_popup in palmy, so all of it is drawn inside the window --
// which is also what lets a page's context menu be a shadcn menu rather than
// the engine's.
package browser

import "core:fmt"
import "core:strings"
import "core:time"
import kit "kit:."
import pb "pb"
import p "palmy:."
import sc "shadcn:."

overlays :: proc(ui: ^p.Ctx, s: ^State) {
	if s.focus == .Omnibox && s.omni_open && len(s.suggestions) > 0 {
		suggestions(ui, s)
	}
	switch s.overlay {
	case .None:
	case .App_Menu:
		app_menu(ui, s)
	case .Context_Menu:
		context_menu(ui, s)
	case .Identity_Menu:
		identity_menu(ui, s)
	case .Folder_Menu:
		folder_menu(ui, s)
	case .Bookmark_Edit:
		bookmark_editor(ui, s)
	case .Downloads:
		downloads_panel(ui, s)
	case .Shortcuts:
		shortcuts_sheet(ui, s)
	case .Confirm_Clear:
		confirm_clear(ui, s)
	case .Tab_Search:
	}
	if s.dialog.active {
		page_dialog(ui, s)
	}
	toast_view(ui, s)
	s.menu_enter = false
}

// scrim catches a click outside an overlay and closes it.
scrim :: proc(ui: ^p.Ctx, s: ^State, dim := false) -> bool {
	idx := p.div(ui, dim ? "absolute inset-0 z-40 bg-black/25" : "absolute inset-0 z-40")
	p.end(ui)
	if p.clickable(ui, idx) {
		close_overlay(s)
		return true
	}
	return false
}

close_overlay :: proc(s: ^State) {
	if s.overlay == .Context_Menu {
		engine_menu_reply(s.engine, s.ctx_menu.view, s.ctx_menu.id, -1)
	}
	if s.overlay == .Bookmark_Edit {
		commit_bookmark_edit(s)
	}
	s.overlay = .None
	if s.focus == .Dialog && !s.dialog.active {
		t := active_tab(s)
		set_focus(s, t != nil && t.page == .Web ? .Page : .None)
	}
}

panel_at :: proc(ui: ^p.Ctx, x, y, w: f32, class := "") -> int {
	win := p.size(ui)
	px := clamp(x, 8, max(8, win.x - w - 8))
	wrap := p.div(ui, "absolute z-50")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px(px)
	st.inset[p.TOP] = p.px(y)
	st.w = p.px(w)
	sc.menu_content_open(ui)
	p.apply(ui, p.concat(ui, "w-full border border-border shadow-xl ", class))
	return wrap
}

panel_end :: proc(ui: ^p.Ctx) {
	p.end(ui)
	p.end(ui)
}

// menu_item draws one row of a menu and reports whether it was chosen, by a
// click or by Enter while the keyboard selection is on it.
menu_item :: proc(ui: ^p.Ctx, s: ^State, ic: p.Icon, label: string, shortcut := "", enabled := true, destructive := false, checked := false) -> bool {
	i := s.menu_count
	s.menu_count += 1
	idx := sc.menu_item_open(ui, destructive)
	p.apply(ui, "h-8 px-2 gap-2.5")
	selected := s.menu_sel == i
	if !enabled {
		p.apply(ui, "opacity-45")
	} else if selected {
		p.apply(ui, destructive ? "bg-destructive/10" : "bg-accent")
	} else {
		p.apply(ui, "hover:bg-accent cursor-pointer")
	}
	if ic.d != "" {
		p.icon(ui, ic, destructive ? "size-4 text-destructive" : "size-4 text-muted-foreground")
	} else {
		p.div(ui, "size-4 shrink-0")
		p.end(ui)
	}
	sc.menu_item_text(ui, label)
	if checked {
		p.icon(ui, ICON_CHECK, "size-4 text-foreground")
	}
	if shortcut != "" {
		sc.menu_shortcut(ui, shortcut)
	}
	p.end(ui)
	if !enabled {
		return false
	}
	if p.is_hovered(ui, idx) && ui.input.mouse_delta != {0, 0} {
		s.menu_sel = i
	}
	return p.clickable(ui, idx) || (s.menu_enter && selected)
}

menu_sep :: proc(ui: ^p.Ctx) {
	sc.menu_separator(ui)
}

menu_heading :: proc(ui: ^p.Ctx, label: string) {
	sc.menu_label(ui, label)
}

// ---------------------------------------------------------------------------
// The omnibox's suggestions
// ---------------------------------------------------------------------------

suggestions :: proc(ui: ^p.Ctx, s: ^State) {
	r := p.rect_of(ui, s.omni_id)
	wrap := p.div(ui, "absolute z-50")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px(r.x - 4)
	st.inset[p.TOP] = p.px(r.y + r.h + 4)
	st.w = p.px(r.w + 8)
	box := p.col(ui, "w-full p-1.5 rounded-xl bg-popover border border-border shadow-2xl")
	s.drop_id = p.node_id(ui, box)
	for sg, i in s.suggestions {
		p.key(ui, tfmt("sg-%d", i))
		row := p.row(ui, "h-10 items-center gap-3 px-2.5 rounded-lg cursor-pointer")
		if i == s.omni_sel {
			p.apply(ui, "bg-accent")
		} else {
			p.apply(ui, "hover:bg-accent/60")
		}
		ic := ICON_GLOBE
		switch sg.kind {
		case .Search:
			ic = ICON_SEARCH
		case .Bookmark:
			ic = ICON_STAR
		case .History:
			ic = ICON_CLOCK
		case .Tab:
			ic = ICON_LAYERS
		case .Page:
			ic = ICON_SETTINGS
			if k, ok := page_of_url(sg.url); ok {
				ic = page_icon(k)
			}
		case .Url:
			ic = ICON_GLOBE
		}
		box := p.div(ui, "size-7 rounded-md items-center justify-center bg-muted shrink-0")
		p.icon(ui, ic, sg.kind == .Bookmark ? "size-4 text-amber-500" : "size-4 text-muted-foreground")
		p.end(ui)
		_ = box
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, sg.title, "text-[13] truncate")
		if sg.url != "" && sg.kind != .Search {
			p.text(ui, display_url(sg.url), "text-[11.5] text-muted-foreground truncate")
		}
		p.end(ui)
		hint := ""
		switch sg.kind {
		case .Tab:
			hint = "Switch to tab"
		case .Bookmark:
			hint = "Bookmark"
		case .Search:
			hint = i == s.omni_sel ? "Enter" : ""
		case .Url, .History, .Page:
			hint = i == s.omni_sel ? "Enter" : ""
		}
		if hint != "" {
			sc.kbd(ui, hint, "bg-background border border-border")
		}
		p.end(ui)
		if p.clickable(ui, row) {
			s.omni_sel = i
			take_suggestion(s, i, false)
		}
	}
	// a footer that teaches the keyboard
	p.row(ui, "h-8 items-center gap-3 px-2.5 pt-1 mt-1 border-t border-border")
	hint_pair(ui, "↑↓", "choose")
	hint_pair(ui, "Enter", "open")
	hint_pair(ui, "Alt Enter", "new tab")
	hint_pair(ui, "Esc", "close")
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

hint_pair :: proc(ui: ^p.Ctx, keys, what: string) {
	p.row(ui, "items-center gap-1 shrink-0")
	sc.kbd(ui, keys)
	p.text(ui, what, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

take_suggestion :: proc(s: ^State, i: int, new_tab_: bool) {
	if i < 0 || i >= len(s.suggestions) {
		open_input(s, edit_text(&s.omni), new_tab_)
		return
	}
	sg := s.suggestions[i]
	if sg.kind == .Tab {
		for t, j in s.tabs {
			if tab_url(t) == sg.url {
				activate_tab(s, j)
				return
			}
		}
	}
	if new_tab_ {
		new_tab(s, sg.url, s.active + 1)
	} else if t := active_tab(s); t != nil {
		navigate(s, t, sg.url)
		set_focus(s, t.page == .Web ? .Page : .None)
	}
}

// build_suggestions ranks what the typed text could mean: the literal URL or
// search first, then open tabs, bookmarks, history and internal pages.
build_suggestions :: proc(s: ^State) {
	// The list outlives the frame, so its strings are owned here: everything
	// below is gathered from temporary memory and cloned once at the end.
	for sg in s.suggestions {
		delete(sg.title)
		delete(sg.url)
	}
	clear(&s.suggestions)
	defer for &sg in s.suggestions {
		sg.title = strings.clone(sg.title)
		sg.url = strings.clone(sg.url)
	}
	text := strings.trim_space(edit_text(&s.omni))
	if text == "" {
		return
	}
	q := strings.to_lower(text, context.temp_allocator)
	eng := search_engine(s.prof.settings.search)
	url, is_search := resolve_input(text, eng, context.temp_allocator)
	if is_search {
		append(&s.suggestions, Suggestion{kind = .Search, title = strings.clone(tfmt("Search %s for “%s”", eng.name, text), context.temp_allocator), url = url})
	} else {
		append(&s.suggestions, Suggestion{kind = .Url, title = display_url(url), url = url})
	}
	seen := make(map[string]bool, context.temp_allocator)
	seen[url] = true
	matches :: proc(q, title, url: string) -> f32 {
		tl := strings.to_lower(title, context.temp_allocator)
		ul := strings.to_lower(url, context.temp_allocator)
		host := url_host(ul)
		switch {
		case strings.has_prefix(host, q):
			return 4
		case strings.has_prefix(tl, q):
			return 3
		case strings.contains(host, q):
			return 2.5
		case strings.contains(tl, q):
			return 2
		case strings.contains(ul, q):
			return 1
		}
		return 0
	}
	for t in s.tabs {
		if t == active_tab(s) || t.page != .Web {
			continue
		}
		if m := matches(q, t.title, t.url); m > 0 && !seen[t.url] {
			seen[t.url] = true
			append(&s.suggestions, Suggestion{kind = .Tab, title = tab_title(t), url = t.url, score = m + 2})
		}
	}
	for b in all_visible(&s.bookmarks, context.temp_allocator) {
		if m := matches(q, b.title, b.url); m > 0 && !seen[b.url] {
			seen[b.url] = true
			append(&s.suggestions, Suggestion{kind = .Bookmark, title = b.title, url = b.url, score = m + 1.5})
		}
	}
	// history, by how often each URL was visited
	counts := make(map[string]int, context.temp_allocator)
	titles := make(map[string]string, context.temp_allocator)
	#reverse for v in s.history.visits {
		counts[v.url] += 1
		if titles[v.url] == "" {
			titles[v.url] = v.title
		}
	}
	for u, n in counts {
		if seen[u] {
			continue
		}
		if m := matches(q, titles[u], u); m > 0 {
			append(&s.suggestions, Suggestion{kind = .History, title = titles[u] != "" ? titles[u] : display_url(u), url = u, score = m + min(f32(n) / 10, 1)})
		}
	}
	for k in Page_Kind {
		if k == .Web {
			continue
		}
		if strings.contains(strings.to_lower(PAGE_TITLES[k], context.temp_allocator), q) || strings.has_prefix(PAGE_URLS[k], q) {
			append(&s.suggestions, Suggestion{kind = .Page, title = PAGE_TITLES[k], url = PAGE_URLS[k], score = 1})
		}
	}
	rest := s.suggestions[1:]
	for i in 1 ..< len(rest) {
		for j := i; j > 0 && rest[j].score > rest[j - 1].score; j -= 1 {
			rest[j], rest[j - 1] = rest[j - 1], rest[j]
		}
	}
	if len(s.suggestions) > 8 {
		resize(&s.suggestions, 8)
	}
}

// ---------------------------------------------------------------------------
// Menus
// ---------------------------------------------------------------------------

app_menu :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	win := p.size(ui)
	panel_at(ui, win.x - 288, 92, 280)
	s.menu_count = 0
	t := active_tab(s)
	if menu_item(ui, s, ICON_PLUS, "New tab", "Ctrl T") {close_overlay(s);new_tab(s, PAGE_URLS[.New_Tab])}
	if menu_item(ui, s, ICON_PANEL_TOP, "New window", "Ctrl N") {close_overlay(s);new_window(s, s.prof.identity)}
	if menu_item(ui, s, ICON_UNDO_2, "Reopen closed tab", "Ctrl Shift T", len(s.closed) > 0) {close_overlay(s);reopen_closed(s)}
	menu_sep(ui)
	marked := t != nil && t.page == .Web && bookmarked(&s.bookmarks, t.url) != nil
	if menu_item(ui, s, ICON_STAR, marked ? "Edit bookmark" : "Bookmark this page", "Ctrl D", t != nil && t.page == .Web) {s.overlay = .None;toggle_bookmark(s)}
	if menu_item(ui, s, ICON_BOOKMARK, "Bookmarks", "Ctrl Shift O") {close_overlay(s);open_internal(s, .Bookmarks)}
	if menu_item(ui, s, ICON_PANEL_TOP, "Show bookmarks bar", "Ctrl Shift B", true, false, s.prof.settings.show_bookmarks_bar) {
		close_overlay(s)
		toggle_bookmarks_bar(s)
	}
	if menu_item(ui, s, ICON_CLOCK, "History", "Ctrl H") {close_overlay(s);open_internal(s, .History)}
	if menu_item(ui, s, ICON_DOWNLOAD, "Downloads", "Ctrl J") {close_overlay(s);open_internal(s, .Downloads)}
	menu_sep(ui)
	// zoom, as one row with its own buttons
	if t != nil && t.page == .Web {
		p.row(ui, "h-9 items-center gap-2 px-2")
		p.icon(ui, ICON_ZOOM_IN, "size-4 text-muted-foreground")
		p.text(ui, "Zoom", "flex-1 text-sm")
		if icon_button(ui, ICON_ZOOM_OUT, true, false, "size-7 border border-border") {zoom_step(s, -1)}
		p.text(ui, tfmt("%d%%", int(t.zoom * 100 + 0.5)), "w-[44] text-center text-[12.5] tabular-nums")
		if icon_button(ui, ICON_ZOOM_IN, true, false, "size-7 border border-border") {zoom_step(s, 1)}
		p.end(ui)
		if menu_item(ui, s, ICON_SEARCH, "Find in page", "Ctrl F") {close_overlay(s);open_find(s)}
		menu_sep(ui)
	}
	if menu_item(ui, s, ICON_SETTINGS, "Settings", "Ctrl ,") {close_overlay(s);open_internal(s, .Settings)}
	if menu_item(ui, s, ICON_KEYBOARD, "Keyboard shortcuts", "F1") {s.overlay = .Shortcuts}
	menu_sep(ui)
	if menu_item(ui, s, ICON_X, "Quit", "Ctrl Q") {close_overlay(s);s.quit = true}
	panel_end(ui)
}

toggle_bookmarks_bar :: proc(s: ^State) {
	s.prof.settings.show_bookmarks_bar = !s.prof.settings.show_bookmarks_bar
	settings_save(&s.prof)
}

open_find :: proc(s: ^State) {
	t := active_tab(s)
	if t == nil || t.page != .Web {
		return
	}
	s.find_open = true
	edit_set(&s.find, edit_text(&s.find), true)
	set_focus(s, .Find)
}

new_window :: proc(s: ^State, identity: string) {
	args := []string{tfmt("%s/browser", exe_dir()), "--new-window", "--identity", identity}
	if bin := own_binary(); bin != "" {
		args[0] = bin
	}
	kit.launch(args)
}

context_menu :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	m := &s.ctx_menu
	win := p.size(ui)
	w: f32 = 260
	y := m.y
	if y > win.y - 320 {
		y = max(8, y - 300)
	}
	panel_at(ui, m.x, y, w)
	s.menu_count = 0
	t := tab_by_view(s, m.view)
	done := false
	reply :: proc(s: ^State) {
		engine_menu_reply(s.engine, s.ctx_menu.view, s.ctx_menu.id, -1)
		s.overlay = .None
	}
	if m.link != "" {
		if menu_item(ui, s, ICON_EXTERNAL_LINK, "Open link in new tab") {new_tab(s, m.link, s.active + 1, false);done = true}
		if menu_item(ui, s, ICON_PANEL_TOP, "Open link in new window") {
			kit.launch({own_binary(), "--new-window", "--identity", s.prof.identity, m.link})
			done = true
		}
		if menu_item(ui, s, ICON_BOOKMARK_PLUS, "Bookmark link") {
			bookmark_add(&s.bookmarks, ROOT_OTHER, display_url(m.link), m.link)
			bookmarks_save(&s.bookmarks)
			toast(s, "Added to Other bookmarks")
			done = true
		}
		if menu_item(ui, s, ICON_LINK, "Copy link address") {kit.clipboard_set(m.link);done = true}
		menu_sep(ui)
	}
	if m.src != "" {
		if menu_item(ui, s, ICON_IMAGE, "Open image in new tab") {new_tab(s, m.src, s.active + 1, false);done = true}
		if menu_item(ui, s, ICON_LINK, "Copy image address") {kit.clipboard_set(m.src);done = true}
		menu_sep(ui)
	}
	if m.selection != "" {
		short := m.selection
		if len(short) > 28 {
			short = tfmt("%s…", short[:28])
		}
		if menu_item(ui, s, ICON_COPY, "Copy", "Ctrl C") {
			kit.clipboard_set(m.selection)
			if t != nil {engine_edit(s.engine, t.id, .Copy)}
			done = true
		}
		if menu_item(ui, s, ICON_SEARCH, tfmt("Search %s for “%s”", search_engine(s.prof.settings.search).name, short)) {
			q, _ := resolve_input(m.selection, search_engine(s.prof.settings.search))
			new_tab(s, q, s.active + 1)
			done = true
		}
		menu_sep(ui)
	}
	if m.editable {
		if menu_item(ui, s, ICON_UNDO_2, "Undo", "Ctrl Z") {if t != nil {engine_edit(s.engine, t.id, .Undo)};done = true}
		if menu_item(ui, s, ICON_SCISSORS, "Cut", "Ctrl X", m.selection != "") {
			kit.clipboard_set(m.selection)
			if t != nil {engine_edit(s.engine, t.id, .Cut)}
			done = true
		}
		if menu_item(ui, s, ICON_CLIPBOARD_PASTE, "Paste", "Ctrl V") {
			if text, ok := kit.clipboard_get(context.temp_allocator); ok && t != nil {
				engine_edit(s.engine, t.id, .Insert, text)
			}
			done = true
		}
		if menu_item(ui, s, ICON_SQUARE_DASHED, "Select all", "Ctrl A") {if t != nil {engine_edit(s.engine, t.id, .Select_All)};done = true}
		menu_sep(ui)
	}
	if m.link == "" && m.selection == "" && !m.editable && m.src == "" {
		if menu_item(ui, s, ICON_ARROW_LEFT, "Back", "Alt ←", t != nil && t.can_back) {go_back(s);done = true}
		if menu_item(ui, s, ICON_ARROW_RIGHT, "Forward", "Alt →", t != nil && t.can_forward) {go_forward(s);done = true}
		if menu_item(ui, s, ICON_ROTATE_CW, "Reload", "Ctrl R") {reload(s);done = true}
		menu_sep(ui)
		marked := t != nil && bookmarked(&s.bookmarks, t.url) != nil
		if menu_item(ui, s, ICON_STAR, marked ? "Edit bookmark" : "Bookmark this page", "Ctrl D") {
			reply(s)
			toggle_bookmark(s)
			panel_end(ui)
			return
		}
		if menu_item(ui, s, ICON_LINK, "Copy page address") {if t != nil {kit.clipboard_set(t.url)};done = true}
	}
	if menu_item(ui, s, ICON_SQUARE, "Select all", "", !m.editable) {if t != nil {engine_edit(s.engine, t.id, .Select_All)};done = true}
	panel_end(ui)
	if done {
		reply(s)
		set_focus(s, .Page)
	}
}

identity_menu :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	panel_at(ui, 8, 44, 300)
	s.menu_count = 0
	// the header: who this window is
	p.row(ui, "items-center gap-3 px-2 py-2.5")
	dot := p.div(ui, "size-9 rounded-full items-center justify-center shrink-0")
	p.style(ui, dot).bg = p.flat(rgb(s.prof.color))
	p.text(ui, strings.to_upper(s.prof.identity[:1], context.temp_allocator), "text-[15] font-bold text-white")
	p.end(ui)
	p.col(ui, "gap-0.5 min-w-0")
	p.text(ui, s.prof.identity, "text-[14] font-semibold")
	p.text(ui, "Cookies, history and bookmarks stay in this identity.", "text-[11.5] text-muted-foreground leading-[16]")
	p.end(ui)
	p.end(ui)
	menu_sep(ui)
	menu_heading(ui, "Open a window as")
	others := profile_list(context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for n in ([]string{"personal", "work"}) {
		append(&names, n)
	}
	for n in others {
		found := false
		for x in names {
			if x == n {found = true}
		}
		if !found {append(&names, n)}
	}
	for n in names {
		if n == s.prof.identity {
			continue
		}
		i := s.menu_count
		s.menu_count += 1
		row := sc.menu_item_open(ui)
		p.apply(ui, "h-8 px-2 gap-2.5")
		if s.menu_sel == i {p.apply(ui, "bg-accent")} else {p.apply(ui, "hover:bg-accent cursor-pointer")}
		d := p.div(ui, "size-4 rounded-full shrink-0")
		p.style(ui, d).bg = p.flat(rgb(identity_color(n)))
		p.end(ui)
		sc.menu_item_text(ui, n)
		p.end(ui)
		if p.clickable(ui, row) || (s.menu_enter && s.menu_sel == i) {
			close_overlay(s)
			new_window(s, n)
		}
	}
	menu_sep(ui)
	if menu_item(ui, s, ICON_SETTINGS, "Profile settings") {
		close_overlay(s)
		open_internal(s, .Settings)
		s.settings_section = 4
	}
	panel_end(ui)
}

folder_menu :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	panel_at(ui, s.folder_menu_at.x, s.folder_menu_at.y, 260, "max-h-[480] overflow-scroll")
	s.menu_count = 0
	kids := children(&s.bookmarks, s.folder_menu, context.temp_allocator)
	if len(kids) == 0 {
		p.text(ui, "This folder is empty", "text-[12.5] text-muted-foreground px-2 py-2")
	}
	for k in kids {
		p.key(ui, k.id)
		switch k.kind {
		case "separator":
			menu_sep(ui)
		case "folder":
			if menu_item(ui, s, ICON_FOLDER, k.title) {
				delete(s.folder_menu)
				s.folder_menu = strings.clone(k.id)
				s.menu_sel = 0
			}
		case:
			if menu_item(ui, s, ICON_GLOBE, k.title != "" ? k.title : display_url(k.url)) {
				close_overlay(s)
				if t := active_tab(s); t != nil {
					navigate(s, t, k.url)
					set_focus(s, .Page)
				}
			}
		}
	}
	menu_sep(ui)
	if menu_item(ui, s, ICON_BOOKMARK, "Open bookmarks manager") {
		s.bm_folder = strings.clone(s.folder_menu)
		close_overlay(s)
		open_internal(s, .Bookmarks)
	}
	panel_end(ui)
}

// ---------------------------------------------------------------------------
// The bookmark editor (Ctrl+D)
// ---------------------------------------------------------------------------

bookmark_editor :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	b := find(&s.bookmarks, s.bm_edit.id)
	if b == nil {
		s.overlay = .None
		return
	}
	win := p.size(ui)
	panel_at(ui, win.x - 388, 92, 360, "p-4 gap-3")
	p.row(ui, "items-center gap-2")
	p.icon(ui, ICON_STAR, "size-4 text-amber-500")
	p.text(ui, s.bm_edit.is_new ? "Bookmark added" : "Edit bookmark", "flex-1 text-[14] font-semibold")
	p.end(ui)

	field :: proc(ui: ^p.Ctx, label: string, e: ^Line_Edit, focused: bool) -> int {
		p.col(ui, "gap-1.5")
		p.text(ui, label, "text-[12] font-medium text-muted-foreground")
		box := p.row(ui, "h-8 items-center px-2.5 rounded-md border overflow-hidden cursor-text")
		p.apply(ui, focused ? "border-ring ring-3 ring-ring/30" : "border-input")
		edit_draw(ui, e, focused, "", "text-[13]", 13, p.rect_of(ui, p.node_id(ui, box)).w - 20)
		p.end(ui)
		p.end(ui)
		return box
	}
	t := field(ui, "Name", &s.bm_edit.title, s.bm_edit.field == 0)
	if p.clickable(ui, t) {s.bm_edit.field = 0}
	if b.kind == "bookmark" {
		u := field(ui, "Address", &s.bm_edit.url, s.bm_edit.field == 1)
		if p.clickable(ui, u) {s.bm_edit.field = 1}
	}
	// the folder, as a row of choices
	p.col(ui, "gap-1.5")
	p.text(ui, "Folder", "text-[12] font-medium text-muted-foreground")
	p.col(ui, "max-h-[132] overflow-scroll rounded-md border border-input p-1")
	for f in folders(&s.bookmarks, context.temp_allocator) {
		if f.id == b.id {
			continue
		}
		p.key(ui, f.id)
		row := p.row(ui, "h-7 items-center gap-2 px-2 rounded-sm cursor-pointer")
		on := s.bm_edit.folder == f.id
		p.apply(ui, on ? "bg-accent" : "hover:bg-accent/60")
		pad := p.div(ui, "shrink-0")
		p.style(ui, pad).w = p.px(f32(f.depth) * 14)
		p.end(ui)
		p.icon(ui, ICON_FOLDER, "size-3.5 text-muted-foreground")
		title := f.path
		if i := strings.last_index(title, " / "); i >= 0 {
			title = title[i + 3:]
		}
		p.text(ui, title, "flex-1 text-[12.5] truncate")
		if on {
			p.icon(ui, ICON_CHECK, "size-3.5")
		}
		p.end(ui)
		if p.clickable(ui, row) {
			s.bm_edit.folder = strings.clone(f.id)
		}
	}
	p.end(ui)
	p.end(ui)

	p.row(ui, "items-center gap-2 pt-1")
	if outline_button(ui, "Remove", ICON_TRASH, true) {
		s.overlay = .None
		delete_bookmark_undoable(s, b.id)
		set_focus(s, .Page)
	}
	p.div(ui, "flex-1")
	p.end(ui)
	if primary_button(ui, "Done", {}, "Enter") {
		close_overlay(s)
	}
	p.end(ui)
	panel_end(ui)
}

commit_bookmark_edit :: proc(s: ^State) {
	b := find(&s.bookmarks, s.bm_edit.id)
	if b == nil {
		return
	}
	title := edit_text(&s.bm_edit.title)
	url := b.kind == "bookmark" ? edit_text(&s.bm_edit.url) : ""
	if title != b.title || url != b.url {
		bookmark_edit(&s.bookmarks, b.id, title, url)
	}
	if s.bm_edit.folder != "" && s.bm_edit.folder != b.parent {
		last := ""
		kids := children(&s.bookmarks, s.bm_edit.folder, context.temp_allocator)
		if len(kids) > 0 {
			last = kids[len(kids) - 1].id
		}
		bookmark_move(&s.bookmarks, b.id, s.bm_edit.folder, last)
	}
	if s.bookmarks.dirty {
		bookmarks_save(&s.bookmarks)
	}
}

// ---------------------------------------------------------------------------
// Downloads panel
// ---------------------------------------------------------------------------

human_bytes :: proc(n: i64) -> string {
	switch {
	case n < 0:
		return "?"
	case n < 1024:
		return tfmt("%d B", n)
	case n < 1024 * 1024:
		return tfmt("%.0f KB", f64(n) / 1024)
	case n < 1024 * 1024 * 1024:
		return tfmt("%.1f MB", f64(n) / (1024 * 1024))
	}
	return tfmt("%.2f GB", f64(n) / (1024 * 1024 * 1024))
}

downloads_panel :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s)
	win := p.size(ui)
	panel_at(ui, win.x - 376, 92, 360, "p-2")
	p.row(ui, "items-center px-2 pt-1 pb-2")
	p.text(ui, "Downloads", "flex-1 text-[14] font-semibold")
	all := p.text(ui, "Show all", "text-[12.5] text-primary cursor-pointer")
	if p.clickable(ui, all) {
		close_overlay(s)
		open_internal(s, .Downloads)
	}
	p.end(ui)
	if len(s.downloads) == 0 {
		p.col(ui, "items-center gap-2 py-6")
		p.icon(ui, ICON_DOWNLOAD, "size-6 text-muted-foreground")
		p.text(ui, "Nothing downloaded yet", "text-[12.5] text-muted-foreground")
		p.end(ui)
	}
	shown := 0
	#reverse for &d in s.downloads {
		if shown == 5 {
			break
		}
		shown += 1
		download_row(ui, s, &d, true)
	}
	panel_end(ui)
}

download_row :: proc(ui: ^p.Ctx, s: ^State, d: ^Download, compact: bool) {
	p.key(ui, tfmt("dl-%d-%d", d.id, d.started))
	row := p.row(ui, "items-center gap-3 px-2 py-2 rounded-md hover:bg-accent/60")
	_ = row
	box := p.div(ui, "size-9 rounded-md items-center justify-center bg-muted shrink-0")
	p.icon(ui, d.state == "failed" ? ICON_CIRCLE_ALERT : ICON_FILE_DOWN, d.state == "failed" ? "size-4 text-destructive" : "size-4 text-muted-foreground")
	p.end(ui)
	_ = box
	p.col(ui, "flex-1 min-w-0 gap-1")
	name := file_name(d.path)
	if name == "" {name = display_url(d.url)}
	p.text(ui, name, "text-[13] font-medium truncate")
	switch d.state {
	case "progress":
		frac: f32 = d.total > 0 ? f32(f64(d.received) / f64(d.total)) : 0
		sc.progress_track(ui, frac * 100, d.total <= 0)
		p.text(ui, d.total > 0 ? tfmt("%s of %s", human_bytes(d.received), human_bytes(d.total)) : human_bytes(d.received), "text-[11.5] text-muted-foreground")
	case "done":
		p.text(ui, tfmt("%s · %s", human_bytes(d.received), url_host(d.url)), "text-[11.5] text-muted-foreground truncate")
	case "cancelled":
		p.text(ui, "Cancelled", "text-[11.5] text-muted-foreground")
	case:
		p.text(ui, "Failed", "text-[11.5] text-destructive")
	}
	p.end(ui)
	if d.state == "progress" {
		if icon_button(ui, ICON_X, true, false, "size-7", "text-muted-foreground") {
			engine_download_cancel(s.engine, d.id)
		}
	} else if d.state == "done" {
		if icon_button(ui, ICON_FOLDER_OPEN, true, false, "size-7", "text-muted-foreground") {
			dir := d.path
			if i := strings.last_index_byte(dir, '/'); i > 0 {
				dir = dir[:i]
			}
			kit.launch({"xdg-open", dir})
		}
	} else if !compact {
		if icon_button(ui, ICON_ROTATE_CW, true, false, "size-7", "text-muted-foreground") {
			new_tab(s, d.url, s.active + 1, false)
		}
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The page's own dialogs: alert, confirm, prompt, leave-page
// ---------------------------------------------------------------------------

page_dialog :: proc(ui: ^p.Ctx, s: ^State) {
	d := &s.dialog
	dim := p.div(ui, "absolute inset-0 z-40 bg-black/30")
	p.end(ui)
	_ = dim
	win := p.size(ui)
	w: f32 = 440
	wrap := p.div(ui, "absolute z-50")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px((win.x - w) / 2)
	st.inset[p.TOP] = p.px(max(80, win.y * 0.22))
	st.w = p.px(w)
	sc.dialog_content_open(ui)
	p.apply(ui, "w-full")
	t := tab_by_view(s, d.view)
	origin := t != nil ? url_host(t.url) : ""
	title := ""
	switch d.kind {
	case .Alert, .Confirm, .Prompt:
		title = origin != "" ? tfmt("%s says", origin) : "This page says"
	case .Before_Unload:
		title = "Leave this page?"
	}
	sc.dialog_header_open(ui)
	sc.dialog_title(ui, title)
	msg := d.message
	if d.kind == .Before_Unload {
		msg = "Changes you made may not be saved."
	}
	sc.dialog_description(ui, msg)
	p.end(ui)
	if d.kind == .Prompt {
		box := p.row(ui, "h-9 items-center px-3 rounded-md border border-ring ring-3 ring-ring/30 overflow-hidden")
		edit_draw(ui, &d.field, true, "", "text-[13.5]", 13.5, p.rect_of(ui, p.node_id(ui, box)).w - 24)
		p.end(ui)
	}
	p.row(ui, "justify-end gap-2")
	if d.kind != .Alert {
		if outline_button(ui, d.kind == .Before_Unload ? "Stay" : "Cancel") {
			answer_dialog(s, false)
		}
	}
	if primary_button(ui, d.kind == .Before_Unload ? "Leave" : "OK", {}, "Enter") {
		answer_dialog(s, true)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

answer_dialog :: proc(s: ^State, ok: bool) {
	d := &s.dialog
	if !d.active {
		return
	}
	engine_dialog_reply(s.engine, d.view, d.id, ok, d.kind == .Prompt ? edit_text(&d.field) : "")
	d.active = false
	set_focus(s, .Page)
}

// ---------------------------------------------------------------------------
// Shortcuts, confirmations, toasts
// ---------------------------------------------------------------------------

SHORTCUTS := [?][2]string {
	{"Ctrl L", "Focus the address bar"},
	{"Ctrl T", "New tab"},
	{"Ctrl W", "Close tab"},
	{"Ctrl Shift T", "Reopen closed tab"},
	{"Ctrl Tab", "Next tab"},
	{"Ctrl Shift Tab", "Previous tab"},
	{"Ctrl 1–9", "Go to tab"},
	{"Alt ← / Alt →", "Back / forward"},
	{"Ctrl R", "Reload"},
	{"Ctrl D", "Bookmark this page"},
	{"Ctrl Shift B", "Show the bookmarks bar"},
	{"Ctrl Shift O", "Bookmarks"},
	{"Ctrl H", "History"},
	{"Ctrl J", "Downloads"},
	{"Ctrl F", "Find in page"},
	{"Ctrl + / − / 0", "Zoom"},
	{"Ctrl ,", "Settings"},
	{"Ctrl N", "New window"},
	{"F11", "Full screen"},
}

shortcuts_sheet :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s, true)
	win := p.size(ui)
	w: f32 = 560
	wrap := p.div(ui, "absolute z-50")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px((win.x - w) / 2)
	st.inset[p.TOP] = p.px(70)
	st.w = p.px(w)
	sc.dialog_content_open(ui)
	p.apply(ui, "w-full")
	sc.dialog_header_open(ui)
	sc.dialog_title(ui, "Keyboard shortcuts")
	sc.dialog_description(ui, "Everything in the browser can be reached without the mouse.")
	p.end(ui)
	p.row(ui, "flex-wrap gap-y-1")
	for sh in SHORTCUTS {
		p.row(ui, "w-1/2 h-8 items-center gap-3 pr-3")
		p.text(ui, sh[1], "flex-1 text-[13] truncate")
		sc.kbd(ui, sh[0], "border border-border")
		p.end(ui)
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

confirm_clear :: proc(ui: ^p.Ctx, s: ^State) {
	scrim(ui, s, true)
	win := p.size(ui)
	w: f32 = 440
	wrap := p.div(ui, "absolute z-50")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px((win.x - w) / 2)
	st.inset[p.TOP] = p.px(max(80, win.y * 0.22))
	st.w = p.px(w)
	sc.dialog_content_open(ui)
	p.apply(ui, "w-full")
	sc.dialog_header_open(ui)
	sc.dialog_title(ui, "Clear browsing history?")
	sc.dialog_description(ui, tfmt("Every visit in the %s profile is forgotten. Bookmarks, cookies and downloaded files are kept.", s.prof.identity))
	p.end(ui)
	p.row(ui, "justify-end gap-2")
	if outline_button(ui, "Cancel") {
		s.overlay = .None
	}
	if outline_button(ui, "Clear history", ICON_TRASH, true) || s.menu_enter {
		n := history_forget_all(&s.history)
		history_compact(&s.history)
		toast(s, tfmt("Forgot %d visits", n))
		s.overlay = .None
	}
	p.end(ui)
	p.end(ui)
	p.end(ui)
}

toast_view :: proc(ui: ^p.Ctx, s: ^State) {
	if s.toast.text == "" || time.tick_diff(time.tick_now(), s.toast.until) <= 0 {
		return
	}
	win := p.size(ui)
	w: f32 = s.toast.action != "" ? 300 : 220
	wrap := p.row(ui, "absolute z-50 h-10 items-center gap-3 pl-4 pr-2 rounded-lg bg-foreground text-background shadow-xl")
	st := p.style(ui, wrap)
	st.inset[p.LEFT] = p.px((win.x - w) / 2)
	st.inset[p.TOP] = p.px(win.y - 64)
	st.min_w = p.px(w)
	p.text(ui, s.toast.text, "flex-1 text-[13] whitespace-nowrap")
	p.style(ui).shrink = 0
	if s.toast.action == "undo" {
		u := p.row(ui, "h-7 px-2.5 items-center rounded-md bg-background/15 hover:bg-background/25 cursor-pointer")
		p.text(ui, "Undo", "text-[12.5] font-medium")
		p.text(ui, "Ctrl Z", "text-[11] opacity-60")
		p.end(ui)
		if p.clickable(ui, u) {
			undo_delete(s)
		}
	}
	p.end(ui)
}

@(private = "file")
_unused :: fmt.Info
@(private = "file")
_unused2 :: pb.Op
