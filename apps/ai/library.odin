package main

// The window's editing in place: the prompt library, renaming a
// conversation, and searching the conversations.
//
// One line editor (Line_Edit) serves all three, and while it has the keys
// nothing else does: Enter commits, Esc cancels, and the composer, the
// shortcuts and the view switches wait. That keeps each edit where its
// object is drawn — the title in its sidebar row, the prompt in its card —
// instead of in a dialog.
//
//	Ctrl+P / F7    the prompt library      (Enter: into the composer;
//	                                        E or F2: edit in place; N: new;
//	                                        Delete: remove)
//	Ctrl+S         save the composer's text as a new prompt
//	Ctrl+R / F9    rename this conversation, in its row
//	Ctrl+F / F8    search this identity's conversations
//
// The data is the CLI's: the same prompts.txt (store.odin) and the same
// conv_rename / conv_search (conv.odin), so what the window does, `ai
// prompts`, `ai rename` and `ai conversations --search` see, and the other
// way round.

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."
import kit "kit:."

Line_Edit :: struct {
	buf:   [dynamic]u8,
	caret: int,
}

line_edit_set :: proc(e: ^Line_Edit, s: string) {
	clear(&e.buf)
	append(&e.buf, ..transmute([]u8)s)
	e.caret = len(e.buf)
}

line_edit_text :: proc(e: ^Line_Edit) -> string {
	return string(e.buf[:])
}

// line_edit_keys applies this frame's typing. `multiline` lets Shift+Enter
// insert a newline. It reports Enter and Esc, which the caller acts on.
line_edit_keys :: proc(ui: ^p.Ctx, e: ^Line_Edit, multiline := false) -> (enter, escape, tab: bool) {
	if .Ctrl not_in ui.input.mods {
		if typed := printable(p.typed_text(ui)); len(typed) > 0 {
			inject_at_elems(&e.buf, e.caret, ..transmute([]u8)typed)
			e.caret += len(typed)
		}
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		if text, ok := kit.clipboard_get(context.temp_allocator); ok && text != "" {
			if !multiline {text = strings.trim_space(strings.split_lines(text, context.temp_allocator)[0])}
			inject_at_elems(&e.buf, e.caret, ..transmute([]u8)text)
			e.caret += len(text)
		}
	}
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if multiline && .Shift in k.mods {
				inject_at(&e.buf, e.caret, u8('\n'))
				e.caret += 1
			} else {
				enter = true
			}
		case p.KEY_ESCAPE:
			escape = true
		case p.KEY_TAB:
			tab = true
		case p.KEY_BACKSPACE:
			if e.caret > 0 {
				n := utf8_back(e.buf[:], e.caret)
				remove_range(&e.buf, e.caret - n, e.caret)
				e.caret -= n
			}
		case p.KEY_DELETE:
			if e.caret < len(e.buf) {
				n := utf8_fwd(e.buf[:], e.caret)
				remove_range(&e.buf, e.caret, e.caret + n)
			}
		case p.KEY_LEFT:
			if e.caret > 0 {e.caret -= utf8_back(e.buf[:], e.caret)}
		case p.KEY_RIGHT:
			if e.caret < len(e.buf) {e.caret += utf8_fwd(e.buf[:], e.caret)}
		case p.KEY_HOME:
			e.caret = 0
		case p.KEY_END:
			e.caret = len(e.buf)
		case 'u':
			if .Ctrl in k.mods {line_edit_set(e, "")}
		}
	}
	return
}

// line_edit_view draws the text with a caret where it is: the text before
// the caret, a bar, the text after. A multiline edit wraps.
line_edit_view :: proc(ui: ^p.Ctx, e: ^Line_Edit, class, placeholder: string, focused: bool, multiline := false) {
	box := p.row(ui, multiline ? "w-full min-w-0 flex-wrap items-start" : "w-full min-w-0 items-center overflow-hidden")
	p.apply(ui, class, box)
	defer p.end(ui)
	text := line_edit_text(e)
	if text == "" && !focused {
		p.text(ui, placeholder, "text-muted-foreground whitespace-nowrap truncate")
		return
	}
	before, after := text[:e.caret], text[e.caret:]
	if before != "" {p.text(ui, before, multiline ? "" : "whitespace-nowrap shrink-0")}
	if focused {
		car := p.div(ui, "w-[1.5] h-4 shrink-0 rounded-full bg-foreground")
		_ = car
		p.end(ui)
	}
	if after != "" {p.text(ui, after, multiline ? "" : "whitespace-nowrap shrink-0")}
	if text == "" {p.text(ui, placeholder, "text-muted-foreground whitespace-nowrap truncate")}
}

// ---------------------------------------------------------------------------
// What is being edited
// ---------------------------------------------------------------------------

Editing :: enum u8 {
	None,
	Search, // the sidebar's search field
	Rename, // the selected conversation's title, in its row
	Prompt_Name, // the selected prompt's name, in its card
	Prompt_Body, // and its body
}

begin_search :: proc(st: ^St) {
	if cur_ident(st) == nil {return}
	st.editing = .Search
	line_edit_set(&st.ed, st.search_q)
}

end_search :: proc(st: ^St) {
	st.editing = .None
	delete(st.search_q)
	st.search_q = ""
	clear(&st.hits)
}

run_search :: proc(st: ^St) {
	q := strings.trim_space(line_edit_text(&st.ed))
	st.editing = .None
	if q == "" {
		end_search(st)
		return
	}
	delete(st.search_q)
	st.search_q = strings.clone(q)
	clear(&st.hits)
	v := cur_ident(st)
	if v == nil || st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {
		toast(st, err)
		return
	}
	hits, serr := conv_search(mc, i, q)
	if serr != "" {
		toast(st, serr)
		return
	}
	for h in hits {append(&st.hits, h)}
	delete(hits)
}

begin_rename :: proc(st: ^St) {
	if st.conv == "" {
		toast(st, "Nothing to rename yet: this conversation starts with its first request")
		return
	}
	for c in st.convs {
		if c.id == st.conv {
			st.editing = .Rename
			line_edit_set(&st.ed, c.title)
			return
		}
	}
}

commit_rename :: proc(st: ^St) {
	st.editing = .None
	title := title_clean(line_edit_text(&st.ed), context.temp_allocator)
	if title == "" {
		toast(st, "A title needs at least one character; the old one stays")
		return
	}
	stored := title
	if !st.fixture {
		v := cur_ident(st)
		if v == nil {return}
		i, _ := ident_of(st, v)
		mc, err := machine_session(&st.person, i)
		if err != "" {
			toast(st, err)
			return
		}
		s, rerr, _ := conv_rename(mc, i, st.conv, title)
		if rerr != "" {
			toast(st, rerr)
			return
		}
		stored = s
	}
	for &c in st.convs {
		if c.id == st.conv {c.title = strings.clone(stored)}
	}
	for &h in st.hits {
		if h.id == st.conv {h.title = strings.clone(stored)}
	}
	toast(st, fmt.tprintf("Renamed to “%s”", stored))
}

// ---------------------------------------------------------------------------
// The prompt library
// ---------------------------------------------------------------------------

prompts_reload :: proc(st: ^St) {
	if st.fixture && len(st.prompts) > 0 {return}
	clear(&st.prompts)
	ps := prompts_load()
	for pr in ps {append(&st.prompts, pr)}
	delete(ps)
	st.psel = clamp(st.psel, 0, max(0, len(st.prompts) - 1))
}

prompts_store :: proc(st: ^St) {
	if !st.fixture {prompts_save(st.prompts[:])}
}

open_prompts :: proc(st: ^St) {
	st.view = .Prompts
	prompts_reload(st)
}

// begin_prompt_edit edits the selected prompt in its card, name first.
begin_prompt_edit :: proc(st: ^St, field := Editing.Prompt_Name) {
	if st.psel < 0 || st.psel >= len(st.prompts) {return}
	pr := st.prompts[st.psel]
	delete(st.pedit_from)
	st.pedit_from = strings.clone(pr.name)
	line_edit_set(&st.ped_name, pr.name)
	line_edit_set(&st.ped_body, pr.body)
	if field == .Prompt_Body {
		st.ped_body.caret = len(st.ped_body.buf)
	}
	st.editing = field
}

// new_prompt adds one, from the composer's text when there is some, and
// opens it for its name.
new_prompt :: proc(st: ^St, body: string) {
	open_prompts(st)
	base := strings.trim_space(body) != "" ? title_from(body, context.temp_allocator) : "New prompt"
	name := base
	for n := 2; prompt_find(st.prompts[:], name) >= 0; n += 1 {
		name = fmt.tprintf("%s (%d)", base, n)
	}
	prompt_set(&st.prompts, name, body)
	st.psel = len(st.prompts) - 1
	prompts_store(st)
	begin_prompt_edit(st)
}

commit_prompt_edit :: proc(st: ^St) {
	st.editing = .None
	name := strings.trim_space(line_edit_text(&st.ped_name))
	if name == "" || strings.contains_any(name, "\t\r\n") {
		toast(st, "A prompt's name is one line with at least one character; nothing changed")
		return
	}
	if name != st.pedit_from {
		if err := prompt_rename(&st.prompts, st.pedit_from, name); err != "" {
			toast(st, fmt.tprintf("Not renamed: %s", err))
			return
		}
	}
	prompt_set(&st.prompts, name, line_edit_text(&st.ped_body))
	st.psel = prompt_find(st.prompts[:], name)
	prompts_store(st)
	toast(st, fmt.tprintf("Saved “%s”", name))
}

use_prompt :: proc(st: ^St) {
	if st.psel < 0 || st.psel >= len(st.prompts) {return}
	clear(&st.input)
	append(&st.input, ..transmute([]u8)st.prompts[st.psel].body)
	st.caret = len(st.input)
	st.view = .Chat
}

delete_prompt :: proc(st: ^St) {
	if st.psel < 0 || st.psel >= len(st.prompts) {return}
	name := strings.clone(st.prompts[st.psel].name, context.temp_allocator)
	prompt_delete(&st.prompts, name)
	st.psel = clamp(st.psel, 0, max(0, len(st.prompts) - 1))
	prompts_store(st)
	toast(st, fmt.tprintf("Removed “%s” from the library", name))
}

// edit_keys has the keys while something is being edited. True when it
// took them.
edit_keys :: proc(ui: ^p.Ctx, st: ^St) -> bool {
	switch st.editing {
	case .None:
		return false
	case .Search:
		enter, esc, _ := line_edit_keys(ui, &st.ed)
		if esc {end_search(st)} else if enter {run_search(st)}
	case .Rename:
		enter, esc, _ := line_edit_keys(ui, &st.ed)
		if esc {st.editing = .None} else if enter {commit_rename(st)}
	case .Prompt_Name:
		enter, esc, tab := line_edit_keys(ui, &st.ped_name)
		if esc {
			st.editing = .None
		} else if enter || tab {
			st.editing = .Prompt_Body
		}
	case .Prompt_Body:
		enter, esc, tab := line_edit_keys(ui, &st.ped_body, multiline = true)
		if esc {
			st.editing = .None
		} else if tab {
			st.editing = .Prompt_Name
		} else if enter {
			commit_prompt_edit(st)
		}
	}
	return true
}

// prompts_keys is the library's own keys, when nothing is being edited.
prompts_keys :: proc(ui: ^p.Ctx, st: ^St) {
	for k in ui.input.keys {
		if .Ctrl in k.mods {continue}
		switch k.sym {
		case p.KEY_UP:
			st.psel = max(0, st.psel - 1)
		case p.KEY_DOWN:
			st.psel = min(len(st.prompts) - 1, st.psel + 1)
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			use_prompt(st)
			return
		case 'e', p.KEY_F2:
			begin_prompt_edit(st)
			return
		case 'n':
			new_prompt(st, "")
			return
		case p.KEY_DELETE:
			delete_prompt(st)
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

prompts_view :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	p.col(ui, "w-full flex-1 min-h-0 px-6 py-5 gap-3 overflow-scroll")
	defer p.end(ui)
	p.row(ui, "w-full items-end gap-3")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, "Prompts", "text-sm font-semibold whitespace-nowrap")
	t := p.textf(ui, "text-xs text-muted-foreground", "Requests you ask again. They are yours, kept on this machine and offered in every identity's composer; one reaches the %s assistant only when you send it.", v.name)
	p.style(ui, t).max_w = p.px(680)
	p.end(ui)
	if btn(ui, "New prompt", .Outline, .SM) {new_prompt(st, "")}
	p.end(ui)

	if len(st.prompts) == 0 {
		p.text(ui, "The library is empty. N adds a prompt; Ctrl+S in the composer saves what you typed.", "text-xs text-muted-foreground")
	}
	maxw := min(f32(860), max(f32(360), p.size(ui).x - SIDEBAR_W - 48))
	for pr, k in st.prompts {
		p.key(ui, fmt.tprintf("pr%d", k))
		sel := k == st.psel
		editing := sel && (st.editing == .Prompt_Name || st.editing == .Prompt_Body)
		card := p.col(ui, "w-full shrink-0 gap-1.5 rounded-xl border px-4 py-3 transition cursor-pointer")
		p.style(ui, card).max_w = p.px(maxw)
		p.apply(ui, sel ? fmt.tprintf("%s bg-muted/40", tone(v, "border", 500)) : "border-border hover:bg-muted/40", card)
		if p.clickable(ui, card) && !editing {
			if sel {use_prompt(st)} else {st.psel = k}
		}
		if editing {
			p.text(ui, "NAME", "text-[10] font-semibold tracking-wide text-muted-foreground whitespace-nowrap")
			line_edit_view(ui, &st.ped_name, fmt.tprintf("rounded-md border px-2 py-1 text-sm font-semibold %s", st.editing == .Prompt_Name ? tone(v, "border", 500) : "border-border"), "a name", st.editing == .Prompt_Name)
			p.text(ui, "PROMPT", "text-[10] font-semibold tracking-wide text-muted-foreground whitespace-nowrap pt-1")
			line_edit_view(ui, &st.ped_body, fmt.tprintf("rounded-md border px-2 py-1.5 text-sm %s", st.editing == .Prompt_Body ? tone(v, "border", 500) : "border-border"), "what to ask", st.editing == .Prompt_Body, multiline = true)
			p.row(ui, "w-full items-center gap-3 pt-1")
			hint(ui, "Tab", "name / prompt")
			hint(ui, "Enter", st.editing == .Prompt_Name ? "to the prompt" : "save")
			hint(ui, "⇧Enter", "new line")
			hint(ui, "Esc", "cancel")
			p.end(ui)
		} else {
			p.row(ui, "w-full items-center gap-2")
			p.icon(ui, IC_BOOKMARK, sel ? "size-3.5 shrink-0 text-foreground" : "size-3.5 shrink-0 text-muted-foreground")
			p.text(ui, pr.name, "flex-1 min-w-0 text-sm font-medium truncate whitespace-nowrap")
			if sel {
				hint(ui, "Enter", "use")
				hint(ui, "E", "edit")
				hint(ui, "Del", "remove")
			}
			p.end(ui)
			body := strings.trim_space(pr.body)
			if body == "" {body = "(empty)"}
			b := p.text(ui, body, "text-xs text-muted-foreground")
			p.style(ui, b).max_w = p.px(maxw - 40)
		}
		p.end(ui)
	}
}

// conv_list draws the sidebar's conversations: the search field when it is
// open or holds a query, then either the hits or the whole list, with the
// selected row an editor while it is being renamed.
conv_list :: proc(ui: ^p.Ctx, st: ^St, v: ^Ident_View) {
	searching := st.editing == .Search || st.search_q != ""
	if searching {
		p.row(ui, "w-full shrink-0 px-2.5 pb-1.5 items-center")
		f := p.row(ui, "flex-1 min-w-0 h-8 items-center gap-2 px-2.5 rounded-lg border bg-background")
		p.apply(ui, st.editing == .Search ? tone(v, "border", 500) : "border-border", f)
		p.icon(ui, sc.ICON_SEARCH, "size-3.5 shrink-0 text-muted-foreground")
		if st.editing == .Search {
			line_edit_view(ui, &st.ed, "flex-1 text-xs", "search titles and messages", true)
		} else {
			p.text(ui, st.search_q, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
			sc.kbd(ui, "Esc")
		}
		p.end(ui)
		p.end(ui)
	}
	p.col(ui, "w-full flex-1 min-h-0 px-2 pb-2 gap-0.5 overflow-scroll")
	defer p.end(ui)
	if st.search_q != "" {
		p.textf(ui, "px-2 pb-1 text-[10] font-semibold tracking-wide text-muted-foreground whitespace-nowrap", "%d IN %s", len(st.hits), strings.to_upper(v.name, context.temp_allocator))
		for h in st.hits {
			p.key(ui, h.id)
			sel := h.id == st.conv
			row := p.col(ui, "w-full shrink-0 gap-0.5 px-2 py-1.5 rounded-lg transition cursor-pointer")
			p.apply(ui, sel ? "bg-sidebar-accent" : "hover:bg-muted", row)
			if p.clickable(ui, row) && !st.sh.running && st.editing == .None {
				open_conv(st, h.id)
				st.view = .Chat
			}
			if sel && st.editing == .Rename {
				line_edit_view(ui, &st.ed, fmt.tprintf("rounded-md border %s bg-background px-1.5 py-0.5 text-xs", tone(v, "border", 500)), "a title", true)
			} else {
				p.row(ui, "w-full items-center gap-2")
				p.icon(ui, IC_MESSAGE_SQUARE, "size-3 shrink-0 text-muted-foreground")
				p.text(ui, h.title, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
				p.end(ui)
			}
			if !h.in_title {
				p.text(ui, h.snippet, "w-full pl-5 text-[10.5] text-muted-foreground truncate whitespace-nowrap")
			}
			p.end(ui)
		}
		if len(st.hits) == 0 {
			p.textf(ui, "text-xs text-muted-foreground p-2", "Nothing in %s's conversations says “%s”.", v.name, st.search_q)
		}
		return
	}
	for c in st.convs {
		p.key(ui, c.id)
		sel := c.id == st.conv
		row := p.row(ui, "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-lg transition cursor-pointer")
		p.apply(ui, sel ? "bg-sidebar-accent" : "hover:bg-muted", row)
		if p.clickable(ui, row) && !st.sh.running && st.editing == .None {
			open_conv(st, c.id)
			st.view = .Chat
		}
		p.icon(ui, sel && st.editing == .Rename ? IC_PENCIL : IC_MESSAGE_SQUARE, sel ? "size-3 shrink-0 text-foreground" : "size-3 shrink-0 text-muted-foreground")
		if sel && st.editing == .Rename {
			line_edit_view(ui, &st.ed, fmt.tprintf("flex-1 rounded-md border %s bg-background px-1.5 py-0.5 text-xs", tone(v, "border", 500)), "a title", true)
		} else {
			p.text(ui, c.title, "flex-1 min-w-0 text-xs truncate whitespace-nowrap")
		}
		p.end(ui)
	}
	if len(st.convs) == 0 {
		p.text(ui, "No conversations yet", "text-xs text-muted-foreground p-2")
	}
}
