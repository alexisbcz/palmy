package main

// Input: the keyboard map, the text editor behind in-place editing, snapping,
// and the mouse paths for selecting, moving and resizing on the canvas.
//
// Every action in the application is a `Cmd`, and `invoke` is the only place
// one happens. The keyboard, the command menu and the mouse all go through it,
// so a key and a menu item can never drift apart.

import "core:math"
import "core:strings"
import p "palmy:."

NUDGE :: f32(8) // slide units per arrow press
NUDGE_FINE :: f32(1)
NUDGE_BIG :: f32(40)
SNAP :: f32(7) // snapping threshold, slide units

Cmd :: enum u8 {
	None,
	Slide_New,
	Slide_Dup,
	Slide_Del,
	Slide_Up,
	Slide_Down,
	Layout_Title,
	Layout_Title_Content,
	Layout_Two,
	Layout_Section,
	Layout_Picture,
	Layout_Blank,
	Add_Text,
	Add_Rect,
	Add_Ellipse,
	Add_Line,
	Add_Arrow,
	Add_Image,
	Elem_Edit,
	Elem_Dup,
	Elem_Del,
	Elem_Front,
	Elem_Back,
	Elem_Raise,
	Elem_Lower,
	Elem_Fill,
	Elem_Stroke,
	Elem_Bold,
	Elem_Center,
	Run_Bold,
	Run_Italic,
	Run_Colour,
	Run_Bigger,
	Run_Smaller,
	Run_Plain,
	Transition_Next,
	Theme_Next,
	Toggle_Snap,
	Toggle_Notes,
	Toggle_Footer,
	Edit_Notes,
	Save,
	Open,
	Export,
	Export_Pptx,
	Export_Pdf,
	Present,
	Present_Start,
	Undo,
	Redo,
	Help,
	Quit,
}

MI :: struct {
	label: string,
	keys:  string,
	cmd:   Cmd,
	head:  bool, // a section heading rather than an item
}

// ---------------------------------------------------------------------------
// The command table. It is both the menu and the cheatsheet.
// ---------------------------------------------------------------------------

MENU := [?]MI {
	{label = "Slide", head = true},
	{label = "New slide", keys = "M", cmd = .Slide_New},
	{label = "Duplicate slide", keys = "Shift D", cmd = .Slide_Dup},
	{label = "Delete slide", keys = "Shift X", cmd = .Slide_Del},
	{label = "Move slide up", keys = "Shift K", cmd = .Slide_Up},
	{label = "Move slide down", keys = "Shift J", cmd = .Slide_Down},
	{label = "Speaker notes", keys = "N", cmd = .Edit_Notes},
	{label = "Layout", head = true},
	{label = "Title", keys = "1", cmd = .Layout_Title},
	{label = "Title + Content", keys = "2", cmd = .Layout_Title_Content},
	{label = "Two Content", keys = "3", cmd = .Layout_Two},
	{label = "Section Header", keys = "4", cmd = .Layout_Section},
	{label = "Picture", keys = "5", cmd = .Layout_Picture},
	{label = "Blank", keys = "6", cmd = .Layout_Blank},
	{label = "Insert", head = true},
	{label = "Text box", keys = "T", cmd = .Add_Text},
	{label = "Rectangle", keys = "R", cmd = .Add_Rect},
	{label = "Ellipse", keys = "E", cmd = .Add_Ellipse},
	{label = "Line", keys = "L", cmd = .Add_Line},
	{label = "Arrow", keys = "A", cmd = .Add_Arrow},
	{label = "Picture", keys = "I", cmd = .Add_Image},
	{label = "Element", head = true},
	{label = "Edit text", keys = "Enter", cmd = .Elem_Edit},
	{label = "Duplicate", keys = "D", cmd = .Elem_Dup},
	{label = "Delete", keys = "X", cmd = .Elem_Del},
	{label = "Bring to front", keys = "Shift ]", cmd = .Elem_Front},
	{label = "Send to back", keys = "Shift [", cmd = .Elem_Back},
	{label = "Raise", keys = "]", cmd = .Elem_Raise},
	{label = "Lower", keys = "[", cmd = .Elem_Lower},
	{label = "Cycle fill", keys = "C", cmd = .Elem_Fill},
	{label = "Cycle stroke", keys = "Shift C", cmd = .Elem_Stroke},
	{label = "Bold", keys = "B", cmd = .Elem_Bold},
	{label = "Centre on slide", keys = "Shift G", cmd = .Elem_Center},
	{label = "Styled text", head = true},
	{label = "Bold", keys = "Ctrl B", cmd = .Run_Bold},
	{label = "Italic", keys = "Ctrl I", cmd = .Run_Italic},
	{label = "Colour", keys = "Ctrl Shift C", cmd = .Run_Colour},
	{label = "Larger", keys = "Ctrl =", cmd = .Run_Bigger},
	{label = "Smaller", keys = "Ctrl -", cmd = .Run_Smaller},
	{label = "Plain", keys = "Ctrl Space", cmd = .Run_Plain},
	{label = "Select", keys = "Shift arrows", cmd = .None},
	{label = "Transition", keys = "Shift T", cmd = .Transition_Next},
	{label = "Deck", head = true},
	{label = "Next theme", keys = "G", cmd = .Theme_Next},
	{label = "Snapping", keys = "W", cmd = .Toggle_Snap},
	{label = "Notes pane", keys = "Shift N", cmd = .Toggle_Notes},
	{label = "Slide footer", keys = "F", cmd = .Toggle_Footer},
	{label = "Save deck", keys = "Ctrl S · F3", cmd = .Save},
	{label = "Load deck", keys = "Ctrl O", cmd = .Open},
	{label = "Export PNGs", keys = "Ctrl E", cmd = .Export},
	{label = "Export PowerPoint", keys = "Ctrl Shift E", cmd = .Export_Pptx},
	{label = "Export PDF", keys = "Ctrl Shift D", cmd = .Export_Pdf},
	{label = "Present from here", keys = "F5", cmd = .Present},
	{label = "Present from start", keys = "Shift F5", cmd = .Present_Start},
	{label = "Undo", keys = "U · Ctrl Z", cmd = .Undo},
	{label = "Redo", keys = "Shift U", cmd = .Redo},
	{label = "Keyboard map", keys = "? · F1", cmd = .Help},
	{label = "Quit", keys = "Q", cmd = .Quit},
}

menu_first :: proc() -> int {
	for m, i in MENU {
		if !m.head {
			return i
		}
	}
	return 0
}

menu_step :: proc(from, dir: int) -> int {
	i := from
	for _ in 0 ..< len(MENU) {
		i = (i + dir + len(MENU)) % len(MENU)
		if !MENU[i].head {
			return i
		}
	}
	return from
}

// ---------------------------------------------------------------------------
// History
// ---------------------------------------------------------------------------

// cmd_mutates says whether a command changes the deck, which is the only
// question `invoke` has to answer before it runs one.
cmd_mutates :: proc(cmd: Cmd) -> bool {
	#partial switch cmd {
	case .Toggle_Snap, .Toggle_Notes, .Edit_Notes, .Save, .Open, .Export, .Export_Pptx, .Export_Pdf,
	     .Present, .Present_Start, .Help, .Quit, .None, .Elem_Edit, .Undo, .Redo:
		return false
	}
	return true
}

// push_history snapshots the deck. `coalesce` folds a burst of the same small
// edit — a held arrow key — into one undo step instead of thirty.
push_history :: proc(st: ^St, ui: ^p.Ctx, coalesce := false) {
	collab_note_edit()
	// A live text edit points the element at the editor's buffer, so it has to
	// be made a real string before anything copies it.
	if st.mode == .Text {
		if e := cur_elem(st); e != nil {
			commit_text(st, e)
		}
	}
	if coalesce && ui != nil && now_s(ui) - st.last_push < 1.2 {
		return
	}
	if st.undo == nil {
		st.undo = make([dynamic]Deck)
		st.redo = make([dynamic]Deck)
	}
	append(&st.undo, clone_deck(&st.deck))
	if len(st.undo) > HISTORY_MAX {
		d := st.undo[0]
		deck_free(&d)
		ordered_remove(&st.undo, 0)
	}
	for &r in st.redo {
		deck_free(&r)
	}
	clear(&st.redo)
	if ui != nil {
		st.last_push = now_s(ui)
	}
}

undo_step :: proc(st: ^St, ui: ^p.Ctx, forward: bool) {
	if collab.on {
		// shared: this window's own last change, never a collaborator's
		ok := collab_undo(st, forward)
		toast(st, ui, ok ? (forward ? "Redone" : "Undone") : (forward ? "Nothing to redo" : "Nothing to undo"))
		return
	}
	from := forward ? &st.redo : &st.undo
	to := forward ? &st.undo : &st.redo
	if from == nil || len(from^) == 0 {
		toast(st, ui, forward ? "Nothing to redo" : "Nothing to undo")
		return
	}
	if st.mode == .Text || st.mode == .Notes {
		st.mode = .Browse
	}
	append(to, clone_deck(&st.deck))
	d := from[len(from^) - 1]
	ordered_remove(from, len(from^) - 1)
	deck_free(&st.deck)
	st.deck = d
	st.dirty = true
	st.sel = -1
	clear(&st.guides)
	st.slide = clamp(st.slide, 0, len(st.deck.slides) - 1)
	toast(st, ui, forward ? "Redone" : "Undone")
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if st.mode == .Browse && collab_keys(ui, st) {
		return
	}
	switch st.mode {
	case .Help:
		if len(ui.input.keys) > 0 {
			st.mode = .Browse
		}
		return
	case .Menu:
		menu_keys(ui, app, st)
		return
	case .Text:
		text_keys(ui, st)
		return
	case .Notes:
		notes_keys(ui, st)
		return
	case .Browse:
		browse_keys(ui, app, st)
	}
}

menu_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_DOWN) || p.key_pressed(ui, 'j') {
		st.menu_i = menu_step(st.menu_i, 1)
	}
	if p.key_pressed(ui, p.KEY_UP) || p.key_pressed(ui, 'k') {
		st.menu_i = menu_step(st.menu_i, -1)
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.shortcut(ui, 'k', {.Ctrl}) {
		st.mode = .Browse
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		cmd := MENU[clamp(st.menu_i, 0, len(MENU) - 1)].cmd
		st.mode = .Browse
		invoke(st, ui, app, cmd)
	}
}

browse_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	shift := .Shift in ui.input.mods
	ctrl := .Ctrl in ui.input.mods

	// The quit confirmation only survives the next keystroke.
	if st.quit_armed && len(ui.input.keys) > 0 && !p.key_pressed(ui, 'q') {
		st.quit_armed = false
	}

	// Chrome and files first, so a modifier never falls through to an edit.
	if p.shortcut(ui, 's', {.Ctrl}) {
		invoke(st, ui, app, .Save)
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		invoke(st, ui, app, .Open)
		return
	}
	if p.shortcut(ui, 'e', {.Ctrl}) {
		invoke(st, ui, app, .Export)
		return
	}
	if p.shortcut(ui, 'E', {.Ctrl, .Shift}) {
		invoke(st, ui, app, .Export_Pptx)
		return
	}
	if p.shortcut(ui, 'D', {.Ctrl, .Shift}) {
		invoke(st, ui, app, .Export_Pdf)
		return
	}
	// F2 and F3 are the modifier-free aliases: they are what a kiosk, a remote
	// or a recorded demo can actually send.
	if p.shortcut(ui, 'k', {.Ctrl}) || p.key_pressed(ui, p.KEY_F2) {
		st.mode = .Menu
		st.menu_i = menu_first()
		return
	}
	if p.key_pressed(ui, p.KEY_F3) {
		invoke(st, ui, app, .Save)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		invoke(st, ui, app, .Quit)
		return
	}
	if p.key_pressed(ui, p.KEY_F5) || p.shortcut(ui, 'p', {.Ctrl}) {
		invoke(st, ui, app, shift ? .Present_Start : .Present)
		return
	}
	if p.shortcut(ui, 'z', {.Ctrl}) {
		invoke(st, ui, app, .Undo)
		return
	}
	if p.key_pressed(ui, p.KEY_F1) || p.key_pressed(ui, '?') {
		invoke(st, ui, app, .Help)
		return
	}
	// Styling a whole box from outside it: the same commands as inside, over
	// all of its text.
	if p.shortcut(ui, 'b', {.Ctrl}) {
		invoke(st, ui, app, .Run_Bold)
		return
	}
	if p.shortcut(ui, 'i', {.Ctrl}) {
		invoke(st, ui, app, .Run_Italic)
		return
	}

	// Slide navigation. Counted rather than tested, because several presses of
	// the same key can land in one frame and a reader holding J expects every
	// one of them to move a slide.
	if n := p.key_count(ui, p.KEY_PAGE_DOWN) + (shift ? 0 : p.key_count(ui, 'j')); n > 0 {
		goto_slide(st, st.slide + n)
	}
	if n := p.key_count(ui, p.KEY_PAGE_UP) + (shift ? 0 : p.key_count(ui, 'k')); n > 0 {
		goto_slide(st, st.slide - n)
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		goto_slide(st, 0)
	}
	if p.key_pressed(ui, p.KEY_END) {
		goto_slide(st, len(st.deck.slides) - 1)
	}
	if shift && p.key_pressed(ui, 'J') {
		st.slide = slide_move(&st.deck, st.slide, 1)
		st.dirty = true
	}
	if shift && p.key_pressed(ui, 'K') {
		st.slide = slide_move(&st.deck, st.slide, -1)
		st.dirty = true
	}

	// Selection.
	if p.key_pressed(ui, p.KEY_TAB) {
		s := cur_slide(st)
		if len(s.elems) > 0 {
			d := shift ? -1 : 1
			if st.sel < 0 {
				st.sel = shift ? len(s.elems) - 1 : 0
			} else {
				st.sel = (st.sel + d + len(s.elems)) % len(s.elems)
			}
		}
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		st.sel = -1
		clear(&st.guides)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		invoke(st, ui, app, .Elem_Edit)
		return
	}

	// Nudge and resize. Arrows move the selected element; with nothing selected
	// they step through slides, which is what a reader expects.
	if e := cur_elem(st); e != nil {
		// Ctrl+Shift turns the arrows into a resize, and has to be tested
		// before the move or the move would swallow it.
		if ctrl && shift {
			dw := NUDGE * f32(p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT))
			dh := NUDGE * f32(p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP))
			if dw != 0 || dh != 0 {
				push_history(st, ui, true)
				e.w = max(16, e.w + dw)
				e.h = max(16, e.h + dh)
				if st.snap {
					snap_element(st, e, true)
				}
				st.dirty = true
				return
			}
		}

		step := NUDGE
		if ctrl {
			step = NUDGE_FINE
		} else if shift {
			step = NUDGE_BIG
		}
		dx := step * f32(p.key_count(ui, p.KEY_RIGHT) - p.key_count(ui, p.KEY_LEFT))
		dy := step * f32(p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP))
		if dx != 0 || dy != 0 {
			push_history(st, ui, true)
			e.x += dx
			e.y += dy
			if st.snap {
				snap_element(st, e, false)
			} else {
				clear(&st.guides)
			}
			st.dirty = true
			return
		}
	} else {
		if n := p.key_count(ui, p.KEY_DOWN); n > 0 {
			goto_slide(st, st.slide + n)
		}
		if n := p.key_count(ui, p.KEY_UP); n > 0 {
			goto_slide(st, st.slide - n)
		}
	}

	// The inspector's active property. Rows that do not apply to this element
	// are not shown, so stepping skips them.
	if n := p.key_count(ui, '.'); n > 0 {
		step_prop(st, n)
	}
	if n := p.key_count(ui, ','); n > 0 {
		step_prop(st, -n)
	}
	if n := p.key_count(ui, '=') + p.key_count(ui, '+'); n > 0 {
		push_history(st, ui, true)
		adjust_prop(st, n)
	}
	if n := p.key_count(ui, '-') + p.key_count(ui, '_'); n > 0 {
		push_history(st, ui, true)
		adjust_prop(st, -n)
	}

	// Single letter commands. Shifted letters arrive as the uppercase keysym.
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case 'm':
			invoke(st, ui, app, .Slide_New)
		case 'D':
			invoke(st, ui, app, .Slide_Dup)
		case 'X':
			invoke(st, ui, app, .Slide_Del)
		case 't':
			invoke(st, ui, app, .Add_Text)
		case 'r':
			invoke(st, ui, app, .Add_Rect)
		case 'e':
			invoke(st, ui, app, .Add_Ellipse)
		case 'l':
			invoke(st, ui, app, .Add_Line)
		case 'a':
			invoke(st, ui, app, .Add_Arrow)
		case 'i':
			invoke(st, ui, app, .Add_Image)
		case 'd':
			invoke(st, ui, app, .Elem_Dup)
		case 'x', p.KEY_DELETE:
			invoke(st, ui, app, .Elem_Del)
		case ']':
			invoke(st, ui, app, .Elem_Raise)
		case '[':
			invoke(st, ui, app, .Elem_Lower)
		case '}':
			invoke(st, ui, app, .Elem_Front)
		case '{':
			invoke(st, ui, app, .Elem_Back)
		case 'c':
			invoke(st, ui, app, .Elem_Fill)
		case 'C':
			invoke(st, ui, app, .Elem_Stroke)
		case 'b':
			invoke(st, ui, app, .Elem_Bold)
		case 'G':
			invoke(st, ui, app, .Elem_Center)
		case 'T':
			invoke(st, ui, app, .Transition_Next)
		case 'g':
			invoke(st, ui, app, .Theme_Next)
		case 'w':
			invoke(st, ui, app, .Toggle_Snap)
		case 'f':
			invoke(st, ui, app, .Toggle_Footer)
		case 'n':
			invoke(st, ui, app, .Edit_Notes)
		case 'N':
			invoke(st, ui, app, .Toggle_Notes)
		case 'u':
			invoke(st, ui, app, .Undo)
		case 'U':
			invoke(st, ui, app, .Redo)
		case 'q':
			invoke(st, ui, app, .Quit)
		case '1':
			invoke(st, ui, app, .Layout_Title)
		case '2':
			invoke(st, ui, app, .Layout_Title_Content)
		case '3':
			invoke(st, ui, app, .Layout_Two)
		case '4':
			invoke(st, ui, app, .Layout_Section)
		case '5':
			invoke(st, ui, app, .Layout_Picture)
		case '6':
			invoke(st, ui, app, .Layout_Blank)
		}
	}
}

step_prop :: proc(st: ^St, by: int) {
	e := cur_elem(st)
	n := int(max(Prop)) + 1
	dir := by < 0 ? -1 : 1
	for _ in 0 ..< abs(by) {
		for _ in 0 ..< n {
			st.prop = Prop((int(st.prop) + dir + n) % n)
			if e == nil || prop_applies(st.prop, e) {
				break
			}
		}
	}
}

goto_slide :: proc(st: ^St, to: int) {
	n := len(st.deck.slides)
	if n == 0 {
		return
	}
	next := clamp(to, 0, n - 1)
	if next != st.slide {
		st.slide = next
		st.sel = -1
		st.mode = .Browse
		clear(&st.guides)
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

invoke :: proc(st: ^St, ui: ^p.Ctx, app: ^p.App, cmd: Cmd) {
	// One place takes the snapshot, so no command can forget to.
	if cmd_mutates(cmd) {
		push_history(st, ui)
	}
	s := cur_slide(st)
	e := cur_elem(st)

	set_layout :: proc(st: ^St, ui: ^p.Ctx, l: Layout) {
		apply_layout(&st.deck, st.slide, l)
		st.sel = -1
		st.dirty = true
		toast(st, ui, tprintf("Layout: %s", LAYOUT_NAMES[l]))
	}

	switch cmd {
	case .None:

	case .Slide_New:
		st.slide = slide_add(&st.deck, st.slide + 1, .Title_Content)
		st.sel = -1
		st.dirty = true
		toast(st, ui, tprintf("Slide %d added", st.slide + 1))
	case .Slide_Dup:
		st.slide = slide_duplicate(&st.deck, st.slide)
		st.sel = -1
		st.dirty = true
		toast(st, ui, "Slide duplicated")
	case .Slide_Del:
		if len(st.deck.slides) <= 1 {
			toast(st, ui, "A deck needs at least one slide")
		} else {
			slide_delete(&st.deck, st.slide)
			st.slide = clamp(st.slide, 0, len(st.deck.slides) - 1)
			st.sel = -1
			st.dirty = true
			toast(st, ui, "Slide deleted")
		}
	case .Slide_Up:
		st.slide = slide_move(&st.deck, st.slide, -1)
		st.dirty = true
	case .Slide_Down:
		st.slide = slide_move(&st.deck, st.slide, 1)
		st.dirty = true

	case .Layout_Title:
		set_layout(st, ui, .Title)
	case .Layout_Title_Content:
		set_layout(st, ui, .Title_Content)
	case .Layout_Two:
		set_layout(st, ui, .Two_Content)
	case .Layout_Section:
		set_layout(st, ui, .Section_Header)
	case .Layout_Picture:
		set_layout(st, ui, .Picture)
	case .Layout_Blank:
		set_layout(st, ui, .Blank)

	case .Add_Text:
		// Empty rather than "New text": the box goes straight into editing,
		// and typing fills it instead of having to clear it first.
		st.sel = elem_add(s, text_box("", .Body, 240, 300, 520, 120))
		st.dirty = true
		begin_text(st)
		toast(st, ui, "Text box added — type, then Escape")
	case .Add_Rect:
		st.sel = elem_add(s, shape(.Rect, 420, 260, 440, 240, SLOT_ACCENT))
		st.dirty = true
		toast(st, ui, "Rectangle added")
	case .Add_Ellipse:
		st.sel = elem_add(s, shape(.Ellipse, 460, 260, 320, 320, SLOT_ACCENT2))
		st.dirty = true
		toast(st, ui, "Ellipse added")
	case .Add_Line:
		st.sel = elem_add(s, shape(.Line, 360, 400, 560, 0, SLOT_FG))
		st.dirty = true
		toast(st, ui, "Line added")
	case .Add_Arrow:
		st.sel = elem_add(s, shape(.Arrow, 360, 380, 480, 120, SLOT_ACCENT))
		st.dirty = true
		toast(st, ui, "Arrow added")
	case .Add_Image:
		src := next_asset(st)
		st.sel = elem_add(s, image_box(src, 360, 220, 560, 340))
		st.dirty = true
		toast(st, ui, tprintf("Picture: %s", src))

	case .Elem_Edit:
		if e != nil && e.kind == .Text {
			begin_text(st)
		} else if e != nil {
			toast(st, ui, tprintf("%s has no text", KIND_NAMES[e.kind]))
		}
	case .Elem_Dup:
		if e != nil {
			st.sel = elem_duplicate(s, st.sel)
			st.dirty = true
		}
	case .Elem_Del:
		if e != nil {
			elem_delete(s, st.sel)
			st.sel = min(st.sel, len(s.elems) - 1)
			st.dirty = true
		}
	case .Elem_Front:
		if e != nil {
			st.sel = elem_to_front(s, st.sel)
			st.dirty = true
		}
	case .Elem_Back:
		if e != nil {
			st.sel = elem_to_back(s, st.sel)
			st.dirty = true
		}
	case .Elem_Raise:
		if e != nil {
			st.sel = elem_raise(s, st.sel)
			st.dirty = true
		}
	case .Elem_Lower:
		if e != nil {
			st.sel = elem_lower(s, st.sel)
			st.dirty = true
		}
	case .Elem_Fill:
		if e != nil {
			switch e.kind {
			case .Text:
				e.color = next_paint(e.color, 1)
			case .Line, .Arrow:
				// A line has no interior, so its colour is its stroke.
				e.stroke = next_paint(e.stroke, 1)
			case .Rect, .Ellipse, .Image:
				e.fill = next_paint(e.fill, 1)
			}
			st.dirty = true
		}
	case .Elem_Stroke:
		if e != nil {
			e.stroke = next_paint(e.stroke, 1)
			if e.stroke != SLOT_NONE && e.stroke_w <= 0 {
				e.stroke_w = 3
			}
			st.dirty = true
		}
	case .Elem_Bold:
		if e != nil {
			e.bold = !e.bold
			st.dirty = true
		}
	case .Elem_Center:
		if e != nil {
			e.x = (SLIDE_W - e.w) / 2
			st.dirty = true
			toast(st, ui, "Centred horizontally")
		}

	case .Run_Bold, .Run_Italic, .Run_Colour, .Run_Bigger, .Run_Smaller, .Run_Plain:
		if e == nil || e.kind != .Text {
			toast(st, ui, "Select a text box to style its text")
		} else {
			msg := style_text(st, e, cmd)
			st.dirty = true
			toast(st, ui, msg)
		}

	case .Transition_Next:
		n := int(max(Transition)) + 1
		s.transition = Transition((int(s.transition) + 1) % n)
		st.dirty = true
		toast(st, ui, tprintf("Transition: %s", TRANSITION_NAMES[s.transition]))

	case .Theme_Next:
		st.deck.theme = theme_after(st.deck.theme.name)
		st.dirty = true
		toast(st, ui, tprintf("Theme: %s", st.deck.theme.name))
	case .Toggle_Snap:
		st.snap = !st.snap
		clear(&st.guides)
		toast(st, ui, st.snap ? "Snapping on" : "Snapping off")
	case .Toggle_Notes:
		st.show_notes = !st.show_notes
	case .Toggle_Footer:
		st.footer = !st.footer
		st.dirty = true
	case .Edit_Notes:
		st.show_notes = true
		st.mode = .Notes
		ed_begin(st, s.notes)

	case .Save:
		if err := save_deck(&st.deck, st.path); err != "" {
			toast(st, ui, err)
		} else {
			st.dirty = false
			toast(st, ui, tprintf("Saved %s", st.path))
		}
	case .Open:
		d, err := load_deck(st.path)
		if err != "" {
			toast(st, ui, err)
		} else {
			st.deck = d
			st.slide = clamp(st.slide, 0, len(d.slides) - 1)
			st.sel = -1
			st.dirty = false
			toast(st, ui, tprintf("Loaded %s (%d slides)", st.path, len(d.slides)))
		}
	case .Export:
		// deck_export is what `slides export` runs too.
		dir := default_export_dir(context.temp_allocator)
		n, err := deck_export(&st.deck, dir, .Png, st.fonts, &st.imgs)
		if err != "" {
			toast(st, ui, err)
		} else {
			toast(st, ui, tprintf("Exported %d slides to %s", n - 1, dir))
		}

	case .Export_Pptx, .Export_Pdf:
		f: Export_Format = cmd == .Export_Pptx ? .Pptx : .Pdf
		out := tprintf("%s/%s.%s", default_export_dir(context.temp_allocator), deck_slug(st), EXPORT_EXT[f])
		if _, err := deck_export(&st.deck, out, f, st.fonts, &st.imgs); err != "" {
			toast(st, ui, err)
		} else {
			toast(st, ui, tprintf("Wrote %s", out))
		}

	case .Present:
		st.want_present = true
	case .Present_Start:
		st.slide = 0
		st.want_present = true

	case .Undo:
		undo_step(st, ui, false)
	case .Redo:
		undo_step(st, ui, true)

	case .Help:
		st.mode = .Help
	case .Quit:
		// One confirmation when there is something to lose. The deck lives in
		// memory until Ctrl+S, so quitting dirty is the one destructive thing
		// a single keystroke could do here.
		if st.dirty && !st.quit_armed {
			st.quit_armed = true
			toast(st, ui, "Unsaved changes — press Q again to quit, or Ctrl+S to save")
			return
		}
		st.quit = true
		if app != nil {
			p.quit_app(app)
		}
	}
}

// next_asset cycles the generated pictures, so adding an image from the
// keyboard inserts something visible rather than opening a file dialog this
// toolkit cannot have.
next_asset :: proc(st: ^St) -> string {
	assets := [?]string{"assets/vista.png", "assets/bars.png"}
	s := cur_slide(st)
	used := 0
	for e in s.elems {
		if e.kind == .Image {
			used += 1
		}
	}
	return assets[used % len(assets)]
}

// ---------------------------------------------------------------------------
// The inspector's adjustable property
// ---------------------------------------------------------------------------

adjust_prop :: proc(st: ^St, dir: int) {
	e := cur_elem(st)
	if e == nil {
		return
	}
	st.dirty = true
	f := f32(dir)
	switch st.prop {
	case .Fill:
		switch e.kind {
		case .Text:
			e.color = next_paint(e.color, dir)
		case .Line, .Arrow:
			e.stroke = next_paint(e.stroke, dir)
		case .Rect, .Ellipse, .Image:
			e.fill = next_paint(e.fill, dir)
		}
	case .Fill_Alpha:
		e.fill_a = clamp(e.fill_a + f * 0.05, 0.05, 1)
	case .Stroke:
		e.stroke = next_paint(e.stroke, dir)
		if e.stroke != SLOT_NONE && e.stroke_w <= 0 {
			e.stroke_w = 3
		}
	case .Stroke_Width:
		e.stroke_w = clamp(e.stroke_w + f, 0, 40)
	case .Radius:
		e.radius = clamp(e.radius + f * 2, 0, 200)
	case .Opacity:
		e.opacity = clamp(e.opacity + f * 0.05, 0.05, 1)
	case .Rotation:
		e.rotation = math.mod_f32(e.rotation + f * 3 + 360, 360)
	case .Style:
		n := int(max(Style)) + 1
		e.style = Style((int(e.style) + dir + n) % n)
		e.size = 0
	case .Size:
		base := text_size(e)
		e.size = clamp(base + f * 2, 8, 220)
	case .Align:
		n := int(max(Halign)) + 1
		e.halign = Halign((int(e.halign) + dir + n) % n)
	case .Valign:
		n := int(max(Valign)) + 1
		e.valign = Valign((int(e.valign) + dir + n) % n)
	}
}

prop_value :: proc(st: ^St, pr: Prop, e: ^Element) -> string {
	if e == nil {
		return "—"
	}
	switch pr {
	case .Fill:
		return paint_label(elem_colour(e))
	case .Fill_Alpha:
		return tprintf("%d%%", int(e.fill_a * 100 + 0.5))
	case .Stroke:
		return paint_label(e.stroke)
	case .Stroke_Width:
		return tprintf("%.0f px", e.stroke_w)
	case .Radius:
		return tprintf("%.0f px", e.radius)
	case .Opacity:
		return tprintf("%d%%", int(e.opacity * 100 + 0.5))
	case .Rotation:
		return tprintf("%.0f°", e.rotation)
	case .Style:
		return STYLE_NAMES[e.style]
	case .Size:
		return tprintf("%.0f pt", text_size(e))
	case .Align:
		return e.halign == .Left ? "left" : (e.halign == .Center ? "centre" : "right")
	case .Valign:
		return e.valign == .Top ? "top" : (e.valign == .Middle ? "middle" : "bottom")
	}
	return ""
}

// ---------------------------------------------------------------------------
// Text editing
// ---------------------------------------------------------------------------

begin_text :: proc(st: ^St, ui: ^p.Ctx = nil) {
	e := cur_elem(st)
	if e == nil || e.kind != .Text {
		return
	}
	// One undo step for the whole edit: the text as it was before it started.
	// A box that was just created has nothing worth restoring.
	if e.text != "" {
		push_history(st, ui)
	}
	st.mode = .Text
	ed_begin(st, e.text)
	st.ed.caret = len(st.ed.buf)
	st.ed.anchor = st.ed.caret
}

ed_begin :: proc(st: ^St, text: string) {
	if st.ed.buf == nil {
		st.ed.buf = make([dynamic]u8)
	}
	clear(&st.ed.buf)
	append(&st.ed.buf, ..transmute([]u8)text)
	st.ed.caret = len(st.ed.buf)
	st.ed.anchor = st.ed.caret
	clear(&st.ed.pending)
}

ed_text :: proc(st: ^St) -> string {
	return string(st.ed.buf[:])
}

// ed_sel is the selection as an ordered byte range; empty when nothing is
// selected.
ed_sel :: proc(ed: ^Editor) -> (a, b: int) {
	n := len(ed.buf)
	return clamp(min(ed.caret, ed.anchor), 0, n), clamp(max(ed.caret, ed.anchor), 0, n)
}

// ed_replace is the one way the buffer changes: [a, b) becomes `ins`, the
// caret lands after it with nothing selected, and the edit is logged.
ed_replace :: proc(ed: ^Editor, a, b: int, ins: []u8, typed := false) {
	remove_range(&ed.buf, a, b)
	if len(ins) > 0 {
		inject_at_elems(&ed.buf, a, ..ins)
	}
	ed.caret = a + len(ins)
	ed.anchor = ed.caret
	append(&ed.log, Ed_Edit{at = a, removed = b - a, inserted = len(ins), typed = typed})
}

text_keys :: proc(ui: ^p.Ctx, st: ^St) {
	e := cur_elem(st)
	if e == nil || e.kind != .Text {
		st.mode = .Browse
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, p.KEY_TAB) {
		commit_text(st, e)
		st.mode = .Browse
		return
	}

	// Styling the selection. These are the same commands the menu and the
	// command line reach; inside a box they act on the selection, or arm
	// the style for what is typed next when nothing is selected.
	style_keys := [?]struct {
		sym:  u32,
		mods: p.Modifiers,
		cmd:  Cmd,
	} {
		{'b', {.Ctrl}, .Run_Bold},
		{'i', {.Ctrl}, .Run_Italic},
		{'C', {.Ctrl, .Shift}, .Run_Colour},
		{'=', {.Ctrl}, .Run_Bigger},
		{'+', {.Ctrl, .Shift}, .Run_Bigger},
		{'-', {.Ctrl}, .Run_Smaller},
		{p.KEY_SPACE, {.Ctrl}, .Run_Plain},
	}
	for sk in style_keys {
		if p.shortcut(ui, sk.sym, sk.mods) {
			invoke(st, ui, nil, sk.cmd)
		}
	}

	clear(&st.ed.log)
	before := len(e.text)
	if ed_keys(ui, &st.ed, true, true) {
		// The runs move through exactly the edits that were made, so a
		// style stays on its words while the words around it change.
		n := before
		for ev in st.ed.log {
			n = n - ev.removed + ev.inserted
			if len(e.runs) > 0 {
				e.runs = runs_splice(e.runs, ev.at, ev.removed, ev.inserted, n)
			}
			if ev.typed && len(st.ed.pending) > 0 {
				for ps in st.ed.pending {
					e.runs = runs_apply(e.runs, n, ev.at, ev.at + ev.inserted, ps.op, ps.on, ps.color, ps.size)
				}
			}
		}
		// The element shows the live buffer, so the canvas is the text field.
		e.text = ed_text(st)
		st.dirty = true
	}
}

// style_text runs one of the Run_* commands on a text box: over the selection
// while editing it, armed for the next typing when the selection is empty, and
// over the whole box otherwise. It returns what to say about it.
style_text :: proc(st: ^St, e: ^Element, cmd: Cmd) -> string {
	n := len(e.text)
	a, b := 0, n
	editing := st.mode == .Text
	if editing {
		a, b = ed_sel(&st.ed)
		n = len(st.ed.buf)
	}
	at := a < n ? a : max(a - 1, 0) // the byte whose style a toggle reads
	cur := style_at(e, at)
	ps := Pending_Style{}
	label := ""
	#partial switch cmd {
	case .Run_Bold:
		on := a < b ? !range_all(e, a, b, false) : !cur.bold
		ps = {op = .Bold, on = on}
		label = on ? "Bold" : "Not bold"
	case .Run_Italic:
		on := a < b ? !range_all(e, a, b, true) : !cur.italic
		ps = {op = .Italic, on = on}
		label = on ? "Italic" : "Not italic"
	case .Run_Colour:
		c := next_paint(cur.color, 1)
		ps = {op = .Color, color = c}
		label = tprintf("Colour: %s", c == SLOT_NONE ? "the box's" : paint_label(c))
	case .Run_Bigger, .Run_Smaller:
		base := cur.size > 0 ? cur.size : text_size(e)
		z := clamp(base + (cmd == .Run_Bigger ? 4 : -4), 8, 220)
		if z == text_size(e) {
			z = 0
		}
		ps = {op = .Size, size = z}
		label = tprintf("Size %.0f", z > 0 ? z : text_size(e))
	case .Run_Plain:
		ps = {op = .Plain}
		label = "Plain text"
	case:
		return ""
	}
	if editing && a == b {
		append(&st.ed.pending, ps)
		return tprintf("%s — for what you type next", label)
	}
	e.runs = runs_apply(e.runs, n, a, b, ps.op, ps.on, ps.color, ps.size)
	if editing {
		return label
	}
	return tprintf("%s — the whole box", label)
}

commit_text :: proc(st: ^St, e: ^Element) {
	elem_set_text(e, ed_text(st))
}

notes_keys :: proc(ui: ^p.Ctx, st: ^St) {
	s := cur_slide(st)
	if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, p.KEY_TAB) {
		slide_set_notes(s, ed_text(st))
		st.mode = .Browse
		return
	}
	if ed_keys(ui, &st.ed, true) {
		s.notes = ed_text(st)
		st.dirty = true
	}
}

// ed_keys is a text editor over a byte buffer: typed runes, the motions,
// Backspace and Delete, Ctrl-A/E/U/W, line up/down, and — when `selecting` —
// a selection made with Shift and the motions (Ctrl+Shift+A selects all).
// palmy gives the rune-safe measurement; the model is the application's, as
// its README says it has to be.
ed_keys :: proc(ui: ^p.Ctx, ed: ^Editor, multiline: bool, selecting := false) -> (changed: bool) {
	if !selecting {
		ed.anchor = ed.caret
	}
	if typed := p.typed_text(ui); len(typed) > 0 {
		a, b := ed_sel(ed)
		ed_replace(ed, a, b, transmute([]u8)typed, true)
		changed = true
	}

	line_start :: proc(b: []u8, at: int) -> int {
		i := at
		for i > 0 && b[i - 1] != '\n' {i -= 1}
		return i
	}
	line_end :: proc(b: []u8, at: int) -> int {
		i := at
		for i < len(b) && b[i] != '\n' {i += 1}
		return i
	}

	for k in ui.input.keys {
		moved := false
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if multiline {
				a, b := ed_sel(ed)
				ed_replace(ed, a, b, {'\n'})
				changed = true
			}
		case p.KEY_BACKSPACE:
			if .Ctrl in k.mods {
				continue
			}
			if a, b := ed_sel(ed); a < b {
				ed_replace(ed, a, b, nil)
				changed = true
			} else if ed.caret > 0 {
				n := utf8_back(ed.buf[:], ed.caret)
				ed_replace(ed, ed.caret - n, ed.caret, nil)
				changed = true
			}
		case p.KEY_DELETE:
			if a, b := ed_sel(ed); a < b {
				ed_replace(ed, a, b, nil)
				changed = true
			} else if ed.caret < len(ed.buf) {
				n := utf8_fwd(ed.buf[:], ed.caret)
				ed_replace(ed, ed.caret, ed.caret + n, nil)
				changed = true
			}
		case p.KEY_LEFT:
			if ed.caret > 0 {
				ed.caret -= utf8_back(ed.buf[:], ed.caret)
			}
			moved = true
		case p.KEY_RIGHT:
			if ed.caret < len(ed.buf) {
				ed.caret += utf8_fwd(ed.buf[:], ed.caret)
			}
			moved = true
		case p.KEY_UP:
			ls := line_start(ed.buf[:], ed.caret)
			col := ed.caret - ls
			if ls > 0 {
				prev := line_start(ed.buf[:], ls - 1)
				ed.caret = min(prev + col, ls - 1)
			}
			moved = true
		case p.KEY_DOWN:
			ls := line_start(ed.buf[:], ed.caret)
			col := ed.caret - ls
			le := line_end(ed.buf[:], ed.caret)
			if le < len(ed.buf) {
				ne := line_end(ed.buf[:], le + 1)
				ed.caret = min(le + 1 + col, ne)
			}
			moved = true
		case p.KEY_HOME:
			ed.caret = line_start(ed.buf[:], ed.caret)
			moved = true
		case p.KEY_END:
			ed.caret = line_end(ed.buf[:], ed.caret)
			moved = true
		case 'a':
			if .Ctrl in k.mods {
				ed.caret = line_start(ed.buf[:], ed.caret)
				moved = true
			}
		case 'A':
			if .Ctrl in k.mods && selecting {
				ed.anchor = 0
				ed.caret = len(ed.buf)
				clear(&ed.pending)
				continue
			}
		case 'e':
			if .Ctrl in k.mods {
				ed.caret = line_end(ed.buf[:], ed.caret)
				moved = true
			}
		case 'u':
			if .Ctrl in k.mods {
				ls := line_start(ed.buf[:], ed.caret)
				ed_replace(ed, ls, ed.caret, nil)
				changed = true
			}
		case 'w':
			if .Ctrl in k.mods && ed.caret > 0 {
				i := ed.caret
				for i > 0 && ed.buf[i - 1] == ' ' {i -= 1}
				for i > 0 && ed.buf[i - 1] != ' ' && ed.buf[i - 1] != '\n' {i -= 1}
				ed_replace(ed, i, ed.caret, nil)
				changed = true
			}
		}
		if moved {
			// Shift extends the selection; any other motion collapses it and
			// forgets a style armed for typing at the old caret.
			if !(selecting && .Shift in k.mods) {
				ed.anchor = ed.caret
			}
			clear(&ed.pending)
		}
	}
	ed.caret = clamp(ed.caret, 0, len(ed.buf))
	ed.anchor = clamp(ed.anchor, 0, len(ed.buf))
	return
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
// Snapping
//
// What makes moving an element feel like a design tool rather than like typing
// coordinates: edges and centres snap to the slide's own guides and to every
// other element on the slide, and the guide that caught is drawn while it
// holds. The candidates are gathered fresh each time because the set depends on
// what else is on the slide.
// ---------------------------------------------------------------------------

snap_element :: proc(st: ^St, e: ^Element, resizing: bool) {
	clear(&st.guides)
	if !st.snap {
		return
	}
	s := cur_slide(st)

	// Candidate lines: slide centre and thirds, the margins, then the edges
	// and centres of the other elements.
	Cand :: struct {
		at:   f32,
		kind: u8,
	}
	vs := make([dynamic]Cand, context.temp_allocator)
	hs := make([dynamic]Cand, context.temp_allocator)
	append(&vs, Cand{SLIDE_W / 2, 0}, Cand{MARGIN, 0}, Cand{SLIDE_W - MARGIN, 0})
	append(&hs, Cand{SLIDE_H / 2, 0}, Cand{MARGIN, 0}, Cand{SLIDE_H - MARGIN, 0})
	for &o, i in s.elems {
		if i == st.sel {
			continue
		}
		append(&vs, Cand{o.x, 1}, Cand{o.x + o.w / 2, 1}, Cand{o.x + o.w, 1})
		append(&hs, Cand{o.y, 1}, Cand{o.y + o.h / 2, 1}, Cand{o.y + o.h, 1})
	}

	// The element's own anchors. While resizing only the far edge moves.
	exs, eys: [3]f32
	n_anchor := 1
	if resizing {
		exs[0] = e.x + e.w
		eys[0] = e.y + e.h
	} else {
		exs = {e.x, e.x + e.w / 2, e.x + e.w}
		eys = {e.y, e.y + e.h / 2, e.y + e.h}
		n_anchor = 3
	}

	best_v, best_h := f32(SNAP + 1), f32(SNAP + 1)
	adj_v, adj_h := f32(0), f32(0)
	gv, gh := Cand{}, Cand{}
	found_v, found_h := false, false

	for a in exs[:n_anchor] {
		for cd in vs {
			d := cd.at - a
			if abs(d) < abs(best_v) && abs(d) <= SNAP {
				best_v = d
				adj_v = d
				gv = cd
				found_v = true
			}
		}
	}
	for a in eys[:n_anchor] {
		for cd in hs {
			d := cd.at - a
			if abs(d) < abs(best_h) && abs(d) <= SNAP {
				best_h = d
				adj_h = d
				gh = cd
				found_h = true
			}
		}
	}

	if found_v {
		if resizing {
			e.w = max(16, e.w + adj_v)
		} else {
			e.x += adj_v
		}
		append(&st.guides, Guide{vertical = true, at = gv.at, kind = gv.kind})
	}
	if found_h {
		if resizing {
			e.h = max(16, e.h + adj_h)
		} else {
			e.y += adj_h
		}
		append(&st.guides, Guide{vertical = false, at = gh.at, kind = gh.kind})
	}
}

// ---------------------------------------------------------------------------
// The mouse
//
// Clicks cannot be synthesized on this compositor, so none of this is in the
// demo — but an editor whose canvas does not answer the mouse is not an editor,
// and all of it works under a real pointer. The canvas rectangle comes from the
// last painted frame, which is the same geometry palmy's own hit testing uses.
// ---------------------------------------------------------------------------

mouse_edit :: proc(ui: ^p.Ctx, st: ^St) {
	if st.canvas.w <= 1 || st.mode == .Menu || st.mode == .Help {
		return
	}
	m := p.mouse_pos(ui)
	sx := (m.x - st.canvas.x) / st.canvas_sc
	sy := (m.y - st.canvas.y) / st.canvas_sc
	down := p.mouse_down(ui)
	pressed := ui.input.pressed[.Left]

	if pressed && p.rect_contains(p.rect_inset(st.canvas, -20), m.x, m.y) {
		s := cur_slide(st)
		if e := cur_elem(st); e != nil {
			pts := handle_points(st.canvas, st.canvas_sc, e)
			for pt, i in pts {
				if abs(pt.x - m.x) < 10 && abs(pt.y - m.y) < 10 {
					push_history(st, ui)
					st.drag = .Resize
					st.handle = i
					st.orig = e^
					st.grab = {sx, sy}
					return
				}
			}
		}
		hit := hit_elem(s, sx, sy)
		if hit >= 0 {
			if st.mode == .Text && hit == st.sel {
				e := &s.elems[hit]
				box := p.Rect {
					st.canvas.x + e.x * st.canvas_sc,
					st.canvas.y + e.y * st.canvas_sc,
					e.w * st.canvas_sc,
					e.h * st.canvas_sc,
				}
				st.ed.caret = caret_at(st.fonts, box, st.canvas_sc, e, m.x, m.y, theme_family(&st.deck.theme))
				st.ed.anchor = st.ed.caret
				clear(&st.ed.pending)
			} else {
				if st.mode == .Text {
					if e := cur_elem(st); e != nil {
						commit_text(st, e)
					}
				}
				st.sel = hit
				st.mode = .Browse
				e := &s.elems[hit]
				push_history(st, ui)
				st.drag = .Move
				st.grab = {sx - e.x, sy - e.y}
				st.orig = e^
			}
		} else {
			if st.mode == .Text {
				if e := cur_elem(st); e != nil {
					commit_text(st, e)
				}
			}
			st.sel = -1
			st.mode = .Browse
		}
	}

	if !down {
		if st.drag != .None {
			st.drag = .None
			clear(&st.guides)
		}
		return
	}

	e := cur_elem(st)
	if e == nil || st.drag == .None {
		return
	}
	switch st.drag {
	case .None:
	case .Move:
		e.x = sx - st.grab.x
		e.y = sy - st.grab.y
		snap_element(st, e, false)
		st.dirty = true
	case .Resize:
		o := st.orig
		x0, y0 := o.x, o.y
		x1, y1 := o.x + o.w, o.y + o.h
		switch st.handle {
		case 0:
			x0, y0 = sx, sy
		case 1:
			y0 = sy
		case 2:
			x1, y0 = sx, sy
		case 3:
			x1 = sx
		case 4:
			x1, y1 = sx, sy
		case 5:
			y1 = sy
		case 6:
			x0, y1 = sx, sy
		case 7:
			x0 = sx
		}
		e.x = min(x0, x1)
		e.y = min(y0, y1)
		e.w = max(16, abs(x1 - x0))
		e.h = max(16, abs(y1 - y0))
		snap_element(st, e, true)
		st.dirty = true
	}
	p.redraw(ui)
}
