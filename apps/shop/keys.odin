// The keyboard. Everything this application does can be done without the
// mouse, which is the only way a shop with six thousand rows is usable.
//
// Two rules learned from the other palmy apps and respected here:
//
//   - A command key must not auto-repeat. Holding `a` should not put sixty of
//     something in the basket, so commands go through `plain`, which ignores
//     the compositor's repeats.
//   - Navigation must count presses rather than ask "was it pressed". Several
//     key events arrive in one frame — always under a driver script, often
//     under key repeat — and a selection that advances by one falls behind.
//     So the arrows read `key_times`.
package main

import "core:fmt"
import "core:strings"
import p "palmy:."

@(private = "file")
plain :: proc(ui: ^p.Ctx, sym: u32) -> bool {
	for k in ui.input.keys {
		if k.sym == sym && !k.repeat && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			return true
		}
	}
	return false
}

@(private = "file")
key_times :: proc(ui: ^p.Ctx, sym: u32) -> int {
	n := 0
	for k in ui.input.keys {
		if k.sym == sym && k.mods & {.Shift, .Ctrl, .Alt, .Super} == {} {
			n += 1
		}
	}
	return n
}

handle_keys :: proc(ui: ^p.Ctx, st: ^State, app: ^p.App) {
	// The file dialog owns the keyboard entirely while it is open.
	if pick_active(st) {
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		if app != nil {
			p.quit_app(app)
		}
		return
	}

	// The wheel. The compositor reports surface units, about ten to a notch.
	if sy := ui.input.scroll.y; sy != 0 {
		st.scroll_acc += sy / 10
		step := int(st.scroll_acc)
		if step != 0 {
			st.scroll_acc -= f32(step)
			st.top = clamp(st.top + step, 0, max(0, len(st.vis) - st.rows))
		}
	}

	if st.help_open {
		if plain(ui, p.KEY_ESCAPE) || plain(ui, '?') || plain(ui, p.KEY_RETURN) {
			st.help_open = false
		}
		return
	}

	// Navigation works whether or not the search field has the keyboard: a
	// shopper types a word and then reaches for the arrow keys without
	// clicking anything.
	moved := 0
	moved += key_times(ui, p.KEY_DOWN)
	moved -= key_times(ui, p.KEY_UP)
	if !st.searching {
		moved += key_times(ui, 'j')
		moved -= key_times(ui, 'k')
	}
	if n := key_times(ui, p.KEY_PAGE_DOWN); n > 0 {
		moved += n * st.rows
	}
	if n := key_times(ui, p.KEY_PAGE_UP); n > 0 {
		moved -= n * st.rows
	}

	switch st.view {
	case .List:
		if moved != 0 {
			st.list_sel = clamp(st.list_sel + moved, 0, max(0, len(st.list) - 1))
		}
		if plain(ui, p.KEY_SPACE) {
			grouped := list_by_aisle(st, context.temp_allocator)
			if st.list_sel >= 0 && st.list_sel < len(grouped) {
				list_toggle(st, grouped[st.list_sel])
			}
		}
	case .Basket:
		if moved != 0 {
			st.basket_sel = clamp(st.basket_sel + moved, 0, max(0, len(st.basket) - 1))
		}
		if st.basket_sel >= 0 && st.basket_sel < len(st.basket) {
			line := st.basket[st.basket_sel]
			if n := key_times(ui, '+'); n > 0 {
				basket_add(st, line.product, n)
			}
			if n := key_times(ui, '-'); n > 0 {
				basket_add(st, line.product, -n)
			}
			if plain(ui, p.KEY_DELETE) {
				basket_remove(st, st.basket_sel)
			}
		}
	case .Catalogue, .Compare, .Prices, .Import:
		if moved != 0 {
			st.sel = clamp(st.sel + moved, 0, max(0, len(st.vis) - 1))
			st.compare_of = selected_product(st)
			ensure_visible(st)
		}
		if plain(ui, p.KEY_HOME) {
			st.sel, st.top = 0, 0
			st.compare_of = selected_product(st)
		}
		if plain(ui, p.KEY_END) {
			st.sel = max(0, len(st.vis) - 1)
			ensure_visible(st)
			st.compare_of = selected_product(st)
		}
	}

	// The search field owns the letters while it has the keyboard.
	if st.searching {
		if plain(ui, p.KEY_ESCAPE) {
			p.set_focus(ui, 0)
			st.searching = false
			if len(st.query) > 0 {
				clear(&st.query)
				refilter(st)
			}
		}
		if plain(ui, p.KEY_RETURN) {
			p.set_focus(ui, 0)
			st.searching = false
			if idx := selected_product(st); idx >= 0 {
				st.compare_of = idx
				st.view = .Compare
			}
		}
		return
	}

	if plain(ui, '/') {
		st.want_focus_search = true
		st.view = .Catalogue
		return
	}
	if plain(ui, '?') {
		st.help_open = true
		return
	}
	if plain(ui, p.KEY_ESCAPE) {
		switch {
		case len(st.query) > 0:
			clear(&st.query)
			refilter(st)
		case filter_any(st.filter):
			reset_filters(st)
		case st.view != .Catalogue:
			st.view = .Catalogue
		}
		return
	}

	// Views.
	if plain(ui, '1') {
		set_view(st, .Catalogue)
	}
	if plain(ui, '2') {
		set_view(st, .Compare)
	}
	if plain(ui, '3') {
		set_view(st, .Basket)
	}
	if plain(ui, '4') {
		set_view(st, .List)
	}
	if plain(ui, '5') {
		set_view(st, .Prices)
	}
	if plain(ui, 'i') {
		set_view(st, .Import)
	}
	if plain(ui, 'o') || p.shortcut(ui, 'o', {.Ctrl}) {
		begin_pick(st)
		return
	}

	if plain(ui, p.KEY_RETURN) {
		if idx := selected_product(st); idx >= 0 {
			st.compare_of = idx
			set_view(st, .Compare)
		}
	}

	// Commands on the current product.
	idx := st.view == .Compare && st.compare_of >= 0 ? st.compare_of : selected_product(st)
	if idx >= 0 {
		if plain(ui, 'a') {
			basket_add(st, idx)
			toast_now(st, "Ajouté au panier")
		}
		if plain(ui, 'l') {
			list_add(st, idx)
			toast_now(st, "Ajouté à la liste de courses")
		}
		if plain(ui, 'b') {
			if alert_find(st, idx) >= 0 {
				alert_clear(st, idx)
				toast_now(st, "Alerte retirée")
			} else {
				alert_set(st, idx)
				toast_now(st, "Alerte armée à 5 % sous le prix du jour")
			}
		}
	}

	// Sorting and the quick filters.
	if plain(ui, 'u') {
		st.sort = st.sort == .Unit_Up ? .Unit_Down : .Unit_Up
		refilter(st)
		save_state(st)
	}
	if plain(ui, 'x') {
		st.sort = st.sort == .Price_Up ? .Price_Down : .Price_Up
		refilter(st)
		save_state(st)
	}
	if plain(ui, 's') {
		st.filter.in_stock = !st.filter.in_stock
		refilter(st)
	}
	if plain(ui, 'm') {
		if toggle_my_size(st) {
			toast_now(
				st,
				tfmt(
					"Ma taille: %s %s (%s)",
					size_system_label(st.filter.size_system),
					st.filter.size_label,
					size_chart_label(st.filter.size_chart),
				),
			)
		} else {
			toast_now(st, "Filtre taille retiré")
		}
	}
	if plain(ui, 'p') {
		st.filter.promo_only = !st.filter.promo_only
		refilter(st)
	}
	if plain(ui, 'n') {
		// Cycle the Nutri-Score ceiling: off, A, B, C, D, E, off.
		switch st.filter.nutri_max {
		case .None:
			st.filter.nutri_max = .A
		case .A:
			st.filter.nutri_max = .B
		case .B:
			st.filter.nutri_max = .C
		case .C:
			st.filter.nutri_max = .D
		case .D:
			st.filter.nutri_max = .E
		case .E:
			st.filter.nutri_max = .None
		}
		refilter(st)
	}
	if plain(ui, 'e') {
		xp, cp, good := export_fixture(st)
		if good {
			toast_now(st, tfmt("Flux écrits: %s et %s", xp, cp))
		} else {
			toast_now(st, "Export impossible")
		}
		delete(xp)
		delete(cp)
	}
}

// toast_now is the toast used from the keyboard; the UI's own one is file
// private to ui.odin.
toast_now :: proc(st: ^State, msg: string) {
	delete(st.toast)
	st.toast = strings.clone(msg)
	st.toast_at = st.now
}

tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}
