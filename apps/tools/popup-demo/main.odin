// popup-demo: shadcn's floating widgets as real popups.
//
// A small window with a dropdown menu near its bottom edge, a select against
// its right edge, and a tooltip on a button at its top: on Wayland each opens
// as an xdg_popup and goes past the window where it has to; elsewhere (X11,
// PALMY_POPUPS=0) they are drawn inside it. Keyboard: m opens the menu, s the
// select, t toggles the tooltip, Down/Up move, Return picks, Escape closes.
// Each open, pick and dismissal is printed on stdout for scripted checks.
package popup_demo

import "core:fmt"
import "core:os"
import p "palmy:."
import sc "shadcn:."

FRUITS := [?]string{"Apple", "Banana", "Blueberry", "Grapes", "Pineapple", "Strawberry", "Watermelon"}

State :: struct {
	menu_open:   bool,
	select_open: bool,
	tip:         bool,
	sel:         int,
	fruit:       int,
	last:        string,
}

main :: proc() {
	sc.register_shadcn_theme()
	app, err := p.create({title = "popup-demo", app_id = "popup-demo", width = 480, height = 300, root_class = "w-full h-full bg-background text-foreground"})
	if err != "" {
		fmt.eprintln(err)
		os.exit(1)
	}
	defer p.destroy(app)
	st := State{fruit = -1, last = "nothing yet"}
	for ui in p.frames(app) {
		frame(ui, &st)
		os.flush(os.stdout)
	}
}

say :: proc(st: ^State, s: string) {
	st.last = s
	fmt.println(s)
}

frame :: proc(ui: ^p.Ctx, st: ^State) {
	if p.key_pressed(ui, 'm', false) && !st.menu_open && !st.select_open {
		st.menu_open, st.sel = true, 0
		say(st, "OPEN menu")
	} else if p.key_pressed(ui, 's', false) && !st.menu_open && !st.select_open {
		st.select_open, st.sel = true, max(st.fruit, 0)
		say(st, "OPEN select")
	} else if p.key_pressed(ui, 't', false) {
		st.tip = !st.tip
	}

	p.div(ui, "w-full h-full flex-col p-4 gap-3")
	defer p.end(ui)

	// The tooltip's trigger, at the top edge: the tooltip flips below it when
	// it is drawn in the window, and goes above the window when it is real.
	p.row(ui, "w-full")
	tb := sc.button_open(ui, .Outline, .Default, {})
	p.clickable(ui, tb)
	p.text(ui, "Hover for a tooltip")
	sc.button_end(ui)
	p.end(ui)
	if st.tip || p.is_hovered(ui, tb) {
		sc.tooltip_popup_open(ui, p.rect_of(ui, p.node_id(ui, tb)))
		p.text(ui, "A tooltip, outside the window when it must be", "whitespace-nowrap")
		sc.tooltip_popup_close(ui)
	}

	p.text(ui, fmt.tprintf("last: %s", st.last), "text-sm text-muted-foreground")
	p.div(ui, "flex-1")
	p.end(ui)

	// The bottom row: a menu trigger at the left, a select at the right.
	p.row(ui, "w-full items-end justify-between")
	menu_btn := p.row(ui, "w-fit")
	p.key(ui, "menu-trigger")
	b := sc.button_open(ui, .Default, .Default, {})
	if p.clickable(ui, b) {
		st.menu_open = !st.menu_open
		st.sel = 0
		say(st, st.menu_open ? "OPEN menu" : "CLOSE menu")
	}
	p.text(ui, "Open menu")
	sc.button_end(ui)
	p.end(ui)

	sel_box := p.div(ui, "w-[150]")
	p.key(ui, "select-trigger")
	t := p.div(ui, "w-full")
	if p.clickable(ui, t) {
		st.select_open = !st.select_open
		st.sel = max(st.fruit, 0)
		say(st, st.select_open ? "OPEN select" : "CLOSE select")
	}
	sc.select_trigger(ui, st.fruit >= 0 ? FRUITS[st.fruit] : "", "Pick a fruit", st = {focus = st.select_open})
	p.end(ui)
	p.end(ui)
	p.end(ui)

	if st.menu_open {
		menu_items := [?]string{"New file", "Open...", "Save", "Save as...", "Export", "Print", "Close window"}
		if sc.menu_popup_open(ui, p.rect_of(ui, p.node_id(ui, menu_btn))) {
			st.menu_open = false
			say(st, "DISMISSED menu")
		}
		p.apply(ui, "w-[200]")
		for item, i in menu_items {
			p.key(ui, item)
			idx := sc.menu_item_open(ui)
			p.apply(ui, "cursor-pointer", idx)
			if i == st.sel || p.is_hovered(ui, idx) {
				p.apply(ui, "bg-accent text-accent-foreground", idx)
			}
			if p.clickable(ui, idx) {
				st.menu_open = false
				say(st, fmt.tprintf("PICK menu %s", item))
			}
			sc.menu_item_text(ui, item)
			sc.menu_shortcut(ui, fmt.tprintf("Ctrl+%d", i + 1))
			p.end(ui)
		}
		sc.menu_popup_close(ui)
		if keys(ui, st, len(menu_items)) {
			st.menu_open = false
			say(st, fmt.tprintf("PICK menu %s", menu_items[st.sel]))
		}
	}

	if st.select_open {
		if sc.select_popup_open(ui, p.rect_of(ui, p.node_id(ui, sel_box))) {
			st.select_open = false
			say(st, "DISMISSED select")
		}
		for f, i in FRUITS {
			p.key(ui, f)
			p.div(ui, "w-full")
			hit := p.clickable(ui)
			sc.select_item(ui, f, i == st.sel || p.is_hovered(ui))
			p.end(ui)
			if hit {
				st.select_open, st.fruit = false, i
				say(st, fmt.tprintf("PICK select %s", f))
			}
		}
		sc.select_popup_close(ui)
		if keys(ui, st, len(FRUITS)) {
			st.select_open, st.fruit = false, st.sel
			say(st, fmt.tprintf("PICK select %s", FRUITS[st.sel]))
		}
	}
}

// keys moves the highlighted row; true when Return picked it. Escape closes.
keys :: proc(ui: ^p.Ctx, st: ^State, n: int) -> bool {
	st.sel = (st.sel + p.key_count(ui, p.KEY_DOWN) - p.key_count(ui, p.KEY_UP) + n * 8) % n
	if p.key_pressed(ui, p.KEY_ESCAPE, false) {
		st.menu_open, st.select_open = false, false
		say(st, "ESCAPE")
	}
	return p.key_pressed(ui, p.KEY_RETURN, false)
}
