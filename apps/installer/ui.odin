package main

// The frame around every page: the rail of steps, the page heading, the
// Back/Next bar, the erase dialog, and the keyboard.
//
// It is the greeter's visual language (apps/greeter), because it is the same
// product and the installer is the first screen of it anyone sees: the same
// near-black wash, the same zinc card and border tokens, Geist, lucide icons,
// shadcn's buttons and inputs.
//
// Right to left. When the language is written right to left, `draw` puts
// palmy's `dir-rtl` on the root: every row below it runs right to left, as
// CSS's `direction: rtl` does, and the Tab order (the tree's order) follows
// the reading order. Text that sits in a column is aligned to the
// interface's direction through `txt`; chevrons are swapped by `fwd_icon`
// and `back_icon`; the log, being machine text, is `dir-ltr`.

import "core:fmt"
import "core:time"
import p "palmy:."
import sc "shadcn:."

// register_dark_theme is the greeter's palette, token for token.
register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x18181b))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x262626))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xe5e5e5))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x262626))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x3f3f46))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0x450a0a))
	p.register_color("border", c(0x2e2e32))
	p.register_color("input", c(0x3a3a3f))
	p.register_color("ring", c(0x8e8e93))
}

// ---------------------------------------------------------------------------
// Direction
// ---------------------------------------------------------------------------

// txt is p.text for a line that sits in a column, aligned to the
// interface's direction rather than the string's: in a right-to-left
// interface a device path or an English layout name hugs the right edge, and
// in a left-to-right one "العربية" on the language page lines up on the left
// with the names above it.
// text and textf are p.text and p.textf with `dir-auto`: under the root's
// `dir-rtl` a paragraph would otherwise be right to left whatever it says,
// and "/dev/vda" or "20.0 GiB" would be drawn "dev/vda/" and "GiB 20.0".
// Each paragraph takes its direction from its own first strong character,
// as it did before palmy had a layout direction; Arabic sentences that start
// with Latin text carry a RIGHT-TO-LEFT MARK from `tr` for that reason.
text :: proc(ui: ^p.Ctx, s: string, class := "") -> int {
	idx := p.text(ui, s, class)
	p.apply(ui, "dir-auto", idx)
	return idx
}

textf :: proc(ui: ^p.Ctx, class: string, format: string, args: ..any) -> int {
	idx := p.textf(ui, class, format, ..args)
	p.apply(ui, "dir-auto", idx)
	return idx
}

txt :: proc(ui: ^p.Ctx, s: string, class := "") -> int {
	idx := text(ui, s, class)
	p.apply(ui, is_rtl() ? "text-right" : "text-left", idx)
	return idx
}

fwd_icon :: proc() -> p.Icon {
	return is_rtl() ? II_CHEVRON_LEFT : II_CHEVRON_RIGHT
}

back_icon :: proc() -> p.Icon {
	return is_rtl() ? II_CHEVRON_RIGHT : II_CHEVRON_LEFT
}

// ---------------------------------------------------------------------------
// Buttons that work from the keyboard
// ---------------------------------------------------------------------------

// button is a shadcn button that is in the Tab order and answers Enter and
// Space when focused. `consumed` is set when it was activated from the
// keyboard, so the page-wide Enter (Next) does not fire as well.
button :: proc(ui: ^p.Ctx, st: ^St, label: string, ic: Maybe(p.Icon), v: sc.Variant, disabled := false, icon_after := false) -> bool {
	idx := sc.button_open(ui, v, .LG, {disabled = disabled})
	p.apply(ui, "px-4 gap-2")
	if !disabled {
		p.focusable(ui, idx)
	}
	if p.focused(ui, idx) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", idx)
	}
	hit := false
	if !disabled {
		key := p.focused(ui, idx) && (p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_KP_ENTER, false) || p.key_pressed(ui, p.KEY_SPACE, false))
		if key {
			consumed_enter = true
		}
		hit = key || p.clickable(ui, idx)
	}
	if i, has := ic.?; has && !icon_after {
		p.icon(ui, i, "size-4")
	}
	text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	if i, has := ic.?; has && icon_after {
		p.icon(ui, i, "size-4")
	}
	sc.button_end(ui)
	return hit
}

// Set by a focused button that took Enter this frame.
consumed_enter: bool

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

RAIL_W :: 272

draw :: proc(st: ^St, ui: ^p.Ctx) {
	consumed_enter = false
	now := p.elapsed(ui)
	settle_keyboard(st, now)
	poll_install(st)

	p.col(ui, "w-full h-full bg-background text-foreground")
	if is_rtl() {
		p.apply(ui, "dir-rtl")
	}
	defer p.end(ui)

	p.div(ui, "absolute inset-0 bg-gradient-to-b from-[#121217] to-[#07070a]")
	p.end(ui)

	body := p.row(ui, "w-full h-full")
	rail(st, ui)
	p.col(ui, "flex-1 h-full min-w-0")
	{
		heading(st, ui)
		p.col(ui, "flex-1 min-h-0 w-full px-12 pb-4")
		page(st, ui)
		p.end(ui)
		footer(st, ui)
	}
	p.end(ui)
	p.end(ui)

	if st.confirm_open {
		erase_dialog(st, ui)
	}

	handle_keys(st, ui)

	// Keep frames coming while something on screen changes by itself: the
	// clock, the progress, a keyboard selection waiting to settle.
	switch {
	case st.page == .Install:
		p.wake_after(ui, 100 * time.Millisecond)
	case st.kb_dirty:
		p.wake_after(ui, 60 * time.Millisecond)
	case st.page == .Timezone:
		p.wake_after(ui, time.Second)
	}
}

page_title :: proc(pg: Page) -> string {
	switch pg {
	case .Language:
		return tr("Language")
	case .Keyboard:
		return tr("Keyboard")
	case .Timezone:
		return tr("Time zone")
	case .Disk:
		return tr("Disk")
	case .Account:
		return tr("Account")
	case .Summary:
		return tr("Summary")
	case .Install:
		return tr("Install")
	case .Done:
		return tr("Done")
	}
	return ""
}

page_icon :: proc(pg: Page) -> p.Icon {
	switch pg {
	case .Language:
		return II_LANGUAGES
	case .Keyboard:
		return II_KEYBOARD
	case .Timezone:
		return II_CLOCK
	case .Disk:
		return II_HARD_DRIVE
	case .Account:
		return II_USER
	case .Summary:
		return II_CLIPBOARD_LIST
	case .Install:
		return II_DOWNLOAD
	case .Done:
		return II_CIRCLE_CHECK
	}
	return II_INFO
}

rail :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "h-full gap-8 px-5 py-8 bg-card/40")
	p.style(ui).w = p.px(RAIL_W)
	p.style(ui).shrink = 0
	p.apply(ui, is_rtl() ? "border-l border-border" : "border-r border-border")
	defer p.end(ui)

	// The product.
	brand := p.row(ui, "items-center gap-3 px-2")
	{
		p.div(ui, "size-9 rounded-lg bg-primary items-center justify-center")
		p.icon(ui, II_PACKAGE, "size-5 text-primary-foreground")
		p.end(ui)
		p.col(ui, "gap-0")
		txt(ui, "Palmframe", "text-base font-semibold text-foreground")
		txt(ui, tr("Installer"), "text-xs text-muted-foreground")
		p.end(ui)
	}
	p.end(ui)

	// The steps.
	p.col(ui, "gap-1")
	for pg in Page {
		p.key(ui, fmt.tprintf("rail-%v", pg))
		current := pg == st.page
		done := pg < st.page || (pg == .Done && st.page == .Done)
		reachable := can_go_to(st, pg) && !current
		item := p.row(ui, "items-center gap-3 px-2 py-2 rounded-lg")
		if current {
			p.apply(ui, "bg-accent")
		} else if reachable {
			p.apply(ui, "hover:bg-muted cursor-pointer")
			if p.clickable(ui, item) {
				go_to(st, pg)
			}
		}
		{
			DISC :: "size-7 rounded-full items-center justify-center border shrink-0"
			switch {
			case done:
				p.div(ui, DISC + " bg-primary border-primary")
				p.icon(ui, II_CHECK, "size-4 text-primary-foreground")
			case current:
				p.div(ui, DISC + " border-foreground bg-background")
				textf(ui, "text-xs font-semibold text-foreground", "%d", int(pg) + 1)
			case:
				p.div(ui, DISC + " border-border")
				textf(ui, "text-xs text-muted-foreground", "%d", int(pg) + 1)
			}
			p.end(ui)
			p.col(ui, "flex-1 min-w-0")
			txt(
				ui,
				page_title(pg),
				current ? "text-sm font-medium text-foreground" : (done ? "text-sm text-foreground" : "text-sm text-muted-foreground"),
			)
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	p.spacer(ui)

	// What the keys do, and what kind of run this is.
	p.col(ui, "gap-3 px-2")
	if st.backend.demo {
		b := p.row(ui, "items-center gap-2")
		sc.badge(ui, tr("Demo"), .Destructive)
		p.end(ui)
		txt(ui, tr("Nothing on this computer will be changed."), "text-xs text-muted-foreground")
	}
	if st.page < .Install {
		keys_hint(ui, "Tab", tr("Move"))
		keys_hint(ui, "Enter", tr("Next"))
		keys_hint(ui, "Esc", tr("Back"))
	}
	p.end(ui)
}

keys_hint :: proc(ui: ^p.Ctx, key, what: string) {
	r := p.row(ui, "items-center gap-2")
	sc.kbd(ui, key)
	text(ui, what, "text-xs text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

page_subtitle :: proc(pg: Page) -> string {
	switch pg {
	case .Language:
		return tr("Choose the language for the installer and for the new system.")
	case .Keyboard:
		return tr("Choose your keyboard layout. It takes effect at once, so you can try it below.")
	case .Timezone:
		return tr("Choose the city nearest to you. The clock shows the time there.")
	case .Disk:
		return tr("Choose the disk to install Palmframe on.")
	case .Account:
		return tr("This account can administer the computer.")
	case .Summary:
		return tr("Check your choices. Nothing has been changed yet.")
	case .Install:
		return tr("This takes a few minutes. Every step is in the log.")
	case .Done:
		return ""
	}
	return ""
}

page_heading :: proc(pg: Page) -> string {
	switch pg {
	case .Language:
		return tr("Welcome to Palmframe")
	case .Keyboard:
		return tr("Keyboard layout")
	case .Timezone:
		return tr("Time zone")
	case .Disk:
		return tr("Installation disk")
	case .Account:
		return tr("Your account")
	case .Summary:
		return tr("Ready to install")
	case .Install:
		return tr("Installing Palmframe")
	case .Done:
		return ""
	}
	return ""
}

heading :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full gap-2 px-12 pt-10 pb-6")
	defer p.end(ui)
	if st.page == .Done {
		// The page says it all, in the middle of the screen.
		return
	}
	txt(ui, trf("Step %d of %d", int(st.page) + 1, len(Page)), "text-xs font-medium text-muted-foreground")
	txt(ui, page_heading(st.page), "text-3xl font-semibold tracking-tight text-foreground")
	txt(ui, page_subtitle(st.page), "text-sm text-muted-foreground")
}

footer :: proc(st: ^St, ui: ^p.Ctx) {
	if st.page == .Install || st.page == .Done {
		// No way back once the disk has been touched, and the Done page has
		// its own button.
		return
	}
	bar := p.row(ui, "w-full items-center gap-4 px-12 py-5 border-t border-border")
	defer p.end(ui)

	if can_go_back(st) {
		if button(ui, st, tr("Back"), back_icon(), .Outline) {
			go_back(st)
		}
	}
	// The reason Next is not available fills the space between the buttons.
	ok, why := can_leave(st)
	reason := ""
	if !ok && why != "" && (st.page != .Account || st.tried) {
		reason = tr(why)
	}
	text(ui, reason, is_rtl() ? "flex-1 text-xs text-muted-foreground text-left" : "flex-1 text-xs text-muted-foreground text-right")

	label := tr("Next")
	variant := sc.Variant.Default
	ic: p.Icon = fwd_icon()
	if st.page == .Summary {
		label = tr("Install")
		ic = II_DOWNLOAD
	}
	// The account page's Next stays live while fields are wrong: pressing it
	// is how every problem gets shown at once.
	disabled := !ok && st.page != .Account
	if button(ui, st, label, ic, variant, disabled = disabled, icon_after = st.page != .Summary) {
		go_next(st)
	}
}

// erase_dialog is the explicit confirmation INSTALLER.md asks for: it names
// the device, its model and size, and the destructive button says what it
// does. Cancel holds the focus when it opens, so Enter alone never erases.
erase_dialog :: proc(st: ^St, ui: ^p.Ctx) {
	d, have := cur_disk(st)
	if !have {
		st.confirm_open = false
		return
	}
	p.div(ui, "absolute inset-0 bg-black/70 items-center justify-center p-8")
	defer p.end(ui)

	p.col(ui, "w-[520] p-6 gap-5 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)

	top := p.row(ui, "items-start gap-4")
	{
		p.div(ui, "size-10 rounded-full bg-destructive/15 items-center justify-center shrink-0")
		p.icon(ui, II_TRIANGLE_ALERT, "size-5 text-destructive")
		p.end(ui)
		p.col(ui, "flex-1 gap-2 min-w-0")
		txt(ui, trf("Erase %s?", d.path), "text-lg font-semibold text-foreground")
		txt(ui, trf("%s, %s", disk_model(d), size_label(d.size_bytes)), "text-sm font-medium text-foreground")
		txt(
			ui,
			tr("Everything on this disk will be deleted: every partition, every file and any other operating system on it. This cannot be undone."),
			"text-sm text-muted-foreground",
		)
		p.end(ui)
	}
	p.end(ui)

	actions := p.row(ui, "items-center gap-3 justify-end")
	{
		n := p.node_count(ui)
		if button(ui, st, tr("Cancel"), nil, .Outline) {
			cancel_erase(st)
		}
		if st.dialog_focus {
			p.set_focus(ui, p.node_id(ui, n))
			st.dialog_focus = false
			p.redraw(ui)
		}
		if button(ui, st, trf("Erase %s", d.path), II_TRIANGLE_ALERT, .Destructive) {
			confirm_erase(st)
		}
	}
	p.end(ui)
}

disk_model :: proc(d: Disk) -> string {
	if d.model == "" {
		return tr("Unknown model")
	}
	return d.model
}

// checkbox is a focusable row with a box and a label (and an optional line
// under it). Space or a click toggles it; Enter on it is Next, as everywhere
// else.
checkbox :: proc(ui: ^p.Ctx, on: ^bool, label: string, detail := "") {
	check := p.row(ui, "w-full items-start gap-3 py-1 rounded-md")
	p.focusable(ui, check)
	p.apply(ui, "cursor-pointer")
	if p.focused(ui, check) {
		p.apply(ui, "ring-3 ring-ring/50")
	}
	toggled := p.clickable(ui, check) || (p.focused(ui, check) && p.key_pressed(ui, p.KEY_SPACE, false))
	{
		p.div(ui, on^ ? "size-4 mt-0.5 rounded-sm bg-primary border border-primary items-center justify-center shrink-0" : "size-4 mt-0.5 rounded-sm border border-input shrink-0")
		if on^ {
			p.icon(ui, II_CHECK, "size-3 text-primary-foreground")
		}
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, label, "text-sm text-foreground")
		if detail != "" {
			txt(ui, detail, "text-xs text-muted-foreground")
		}
		p.end(ui)
	}
	p.end(ui)
	if toggled {
		on^ = !on^
	}
}

// size_label: binary units, which is what partition sizes are stated in
// (512 MiB ESP) and what the 4 GiB minimum means.
size_label :: proc(b: u64) -> string {
	gib := f64(b) / f64(1 << 30)
	if gib >= 1024 {
		return trf("%.1f TiB", gib / 1024)
	}
	if gib >= 1 {
		return trf("%.1f GiB", gib)
	}
	return trf("%d MiB", b >> 20)
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

// handle_keys runs after the page is built, so it knows whether a focused
// button already took Enter this frame.
handle_keys :: proc(st: ^St, ui: ^p.Ctx) {
	for k in ui.input.keys {
		if k.repeat {
			switch k.sym {
			case p.KEY_RETURN, p.KEY_KP_ENTER, p.KEY_ESCAPE:
				continue
			}
		}
		switch k.sym {
		case p.KEY_ESCAPE:
			go_back(st)
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if !consumed_enter && !st.confirm_open {
				go_next(st)
			}
		case p.KEY_UP:
			list_step(st, ui, -1)
		case p.KEY_DOWN:
			list_step(st, ui, 1)
		case p.KEY_PAGE_UP:
			list_step(st, ui, -8)
		case p.KEY_PAGE_DOWN:
			list_step(st, ui, 8)
		}
	}
}

// list_step moves the selection of the page's list, which is the only thing
// the vertical arrows mean anywhere in the installer.
list_step :: proc(st: ^St, ui: ^p.Ctx, d: int) {
	if st.confirm_open {
		return
	}
	now := p.elapsed(ui)
	#partial switch st.page {
	case .Language:
		pick_language(st, clamp(st.lang_i + d, 0, len(st.languages) - 1))
	case .Keyboard:
		pick_layout(st, step_in(filtered_layouts(st), st.layout_i, d), now)
	case .Timezone:
		pick_zone(st, step_in(filtered_zones(st), st.zone_i, d))
	case .Disk:
		// Walk the usable disks only.
		i := st.disk_i
		for _ in 0 ..< len(st.disks) {
			i += d > 0 ? 1 : -1
			if i < 0 || i >= len(st.disks) {
				break
			}
			if ok, _ := disk_usable(st.disks[i]); ok {
				pick_disk(st, i)
				break
			}
		}
	}
	scroll_selection = true
}

// Set when the arrows moved a selection, so the page scrolls it into view.
scroll_selection: bool
