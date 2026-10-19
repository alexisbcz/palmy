package main

// The eight pages, in INSTALLER.md's order. Each draws from St and changes it
// only through flow.odin's procedures, so what a click does and what a key
// does are the same code.

import "core:fmt"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."

page :: proc(st: ^St, ui: ^p.Ctx) {
	switch st.page {
	case .Language:
		page_language(st, ui)
	case .Keyboard:
		page_keyboard(st, ui)
	case .Timezone:
		page_timezone(st, ui)
	case .Disk:
		page_disk(st, ui)
	case .Account:
		page_account(st, ui)
	case .Summary:
		page_summary(st, ui)
	case .Install:
		page_install(st, ui)
	case .Done:
		page_done(st, ui)
	}
	scroll_selection = false
}

// take_focus gives a control the keyboard when the page has just opened.
take_focus :: proc(st: ^St, ui: ^p.Ctx, idx: int) {
	if st.want_focus {
		p.set_focus(ui, p.node_id(ui, idx))
		st.want_focus = false
		p.redraw(ui)
	}
}

// LIST_ROW is a selectable row; LIST_SEL and LIST_IDLE colour it.
LIST_ROW :: "w-full items-center gap-3 px-3 py-2 rounded-md"
LIST_SEL :: "bg-accent text-accent-foreground"
LIST_IDLE :: "hover:bg-muted cursor-pointer"

// list_box opens a scrolling list in a bordered box. `list_box_end` closes it.
list_box :: proc(ui: ^p.Ctx, class := "flex-1") -> int {
	idx := p.col(ui, "w-full min-h-0 p-1 gap-0.5 rounded-lg border border-border bg-card/60 overflow-scroll")
	p.apply(ui, class)
	return idx
}

// keep_visible scrolls the selected row into view after the arrows or the
// search moved it, and when a page opens on a selection further down.
// palmy scrolls by last frame's rectangles, so on the frame a row first
// appears there is nothing to scroll to yet: the request stays pending until
// the row has been laid out once.
keep_visible :: proc(st: ^St, ui: ^p.Ctx, list, row: int) {
	if !scroll_selection && !st.scroll_pending {
		return
	}
	id := p.node_id(ui, row)
	if p.rect_of(ui, id).h <= 0 {
		st.scroll_pending = true
		p.redraw(ui)
		return
	}
	p.scroll_into_view(ui, p.node_id(ui, list), id, 8)
	st.scroll_pending = false
}

// ---------------------------------------------------------------------------
// 1. Language
// ---------------------------------------------------------------------------

// language_name is a language's name in the interface's language — "Allemand"
// under "Deutsch" when the installer speaks French. Unknown codes fall back
// to the English name the core gives.
language_name :: proc(l: Language) -> string {
	switch {
	case strings.has_prefix(l.code, "en"):
		return tr("English")
	case strings.has_prefix(l.code, "fr"):
		return tr("French")
	case strings.has_prefix(l.code, "de"):
		return tr("German")
	case strings.has_prefix(l.code, "es"):
		return tr("Spanish")
	case strings.has_prefix(l.code, "ar"):
		return tr("Arabic")
	case strings.has_prefix(l.code, "ja"):
		return tr("Japanese")
	}
	return l.english_name
}

page_language :: proc(st: ^St, ui: ^p.Ctx) {
	if st.want_focus {
		// Nothing to type on this page: Enter is Next, the arrows choose.
		p.set_focus(ui, 0)
		st.want_focus = false
	}
	p.col(ui, "w-full max-w-[600] gap-2")
	defer p.end(ui)
	for l, i in st.languages {
		p.key(ui, fmt.tprintf("lang-%s", l.code))
		sel := i == st.lang_i
		row := hrow(ui, "w-full items-center gap-4 px-4 py-3 rounded-lg border")
		p.apply(ui, sel ? "border-ring bg-accent/50" : "border-border bg-card/60 hover:bg-muted cursor-pointer")
		if p.clickable(ui, row) {
			pick_language(st, i)
		}
		{
			p.div(ui, "size-9 rounded-md bg-muted items-center justify-center shrink-0")
			p.icon(ui, II_GLOBE, l.available ? "size-4 text-foreground" : "size-4 text-muted-foreground")
			p.end(ui)
			p.col(ui, "flex-1 gap-0.5 min-w-0")
			txt(ui, l.native_name, l.available ? "text-base font-medium text-foreground" : "text-base font-medium text-muted-foreground")
			if l.available {
				txt(ui, language_name(l), "text-xs text-muted-foreground")
			} else {
				txt(ui, tr("Not available: no font for this script is installed"), "text-xs text-muted-foreground")
			}
			p.end(ui)
			if sel {
				p.icon(ui, II_CHECK, "size-4 text-foreground")
			}
		}
		hend(ui, row)
	}
}

// ---------------------------------------------------------------------------
// 2. Keyboard
// ---------------------------------------------------------------------------

page_keyboard :: proc(st: ^St, ui: ^p.Ctx) {
	now := p.elapsed(ui)
	cols := hrow(ui, "w-full flex-1 min-h-0 gap-6")
	defer hend(ui, cols)

	// Layouts, searchable.
	p.col(ui, "flex-1 h-full min-w-0 gap-3")
	{
		txt(ui, tr("Layout"), "text-sm font-medium text-foreground")
		n := p.node_count(ui)
		if changed, _ := sc.input(ui, &st.kb_search, tr("Search layouts")); changed {
			if v := filtered_layouts(st); len(v) > 0 {
				pick_layout(st, v[0], now)
				scroll_selection = true
			}
		}
		take_focus(st, ui, n)
		list := list_box(ui)
		visible := filtered_layouts(st)
		for li in visible {
			k := st.keyboards[st.layouts[li]]
			p.key(ui, fmt.tprintf("kb-%s", k.layout))
			sel := li == st.layout_i
			row := hrow(ui, LIST_ROW)
			p.apply(ui, sel ? LIST_SEL : LIST_IDLE)
			if p.clickable(ui, row) {
				pick_layout(st, li, now)
			}
			p.col(ui, "flex-1 min-w-0")
			txt(ui, keyboard_name(k.description), "text-sm whitespace-nowrap truncate")
			p.end(ui)
			p.text(ui, k.layout, "text-xs font-mono text-muted-foreground")
			hend(ui, row)
			if sel {
				keep_visible(st, ui, list, row)
			}
		}
		if len(visible) == 0 {
			txt(ui, tr("No layout matches your search."), "text-sm text-muted-foreground p-3")
		}
		p.end(ui)
	}
	p.end(ui)

	// Variants of the chosen layout, then the test field.
	p.col(ui, "h-full gap-3")
	p.style(ui).w = p.px(380)
	p.style(ui).shrink = 0
	{
		txt(ui, tr("Variant"), "text-sm font-medium text-foreground")
		list := list_box(ui)
		base := cur_keyboard(st)
		{
			p.key(ui, "variant-default")
			sel := st.variant == ""
			row := hrow(ui, LIST_ROW)
			p.apply(ui, sel ? LIST_SEL : LIST_IDLE)
			if p.clickable(ui, row) {
				pick_variant(st, "", now)
			}
			p.col(ui, "flex-1 min-w-0")
			txt(ui, tr("Default"), "text-sm")
			p.end(ui)
			hend(ui, row)
		}
		for idx in variants_of(st) {
			k := st.keyboards[idx]
			p.key(ui, fmt.tprintf("variant-%s", k.variant))
			sel := st.variant == k.variant
			row := hrow(ui, LIST_ROW)
			p.apply(ui, sel ? LIST_SEL : LIST_IDLE)
			if p.clickable(ui, row) {
				pick_variant(st, k.variant, now)
			}
			p.col(ui, "flex-1 min-w-0")
			txt(ui, keyboard_name(k.description), "text-sm whitespace-nowrap truncate")
			p.end(ui)
			p.text(ui, k.variant, "text-xs font-mono text-muted-foreground")
			hend(ui, row)
		}
		_ = base
		p.end(ui)
		_ = list

		p.col(ui, "w-full gap-2 pt-2")
		txt(ui, tr("Try your keyboard"), "text-sm font-medium text-foreground")
		sc.input(ui, &st.kb_test, tr("Type here to test the layout"))
		k := cur_keyboard(st)
		txt(ui, trf("Active: %s", keyboard_name(k.description)), "text-xs text-muted-foreground")
		if core_keyboard_needs_latin(k.layout) {
			txt(ui, tr("This layout cannot type the Latin letters a user name needs, so English (US) comes with it: Alt+Shift switches between the two."), "text-xs text-muted-foreground")
		}
		if st.backend.demo && st.kb_said != "" {
			txt(ui, st.kb_said, "text-xs font-mono text-muted-foreground")
		}
		p.end(ui)
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 3. Time zone
// ---------------------------------------------------------------------------

month_name :: proc(m: int) -> string {
	names := [?]string {
		N("January"), N("February"), N("March"), N("April"), N("May"), N("June"),
		N("July"), N("August"), N("September"), N("October"), N("November"), N("December"),
	}
	return tr(names[clamp(m - 1, 0, 11)])
}

weekday_name :: proc(d: int) -> string {
	names := [?]string{N("Sunday"), N("Monday"), N("Tuesday"), N("Wednesday"), N("Thursday"), N("Friday"), N("Saturday")}
	return tr(names[clamp(d, 0, 6)])
}

// clock_now is the wall clock, which shots.odin pins so pictures do not
// depend on when they were taken.
clock_now :: proc() -> time.Time {
	if pinned_clock != {} {
		return pinned_clock
	}
	return time.now()
}

pinned_clock: time.Time

page_timezone :: proc(st: ^St, ui: ^p.Ctx) {
	p.col(ui, "w-full flex-1 min-h-0 gap-4")
	defer p.end(ui)

	// The clock, in the chosen zone.
	z := cur_zone(st)
	now := clock_now()
	off, abbrev, known := zone_offset(st, now)
	local := time.time_add(now, time.Duration(off) * time.Second)
	h, m, _ := time.clock_from_time(local)
	y, mon, d := time.date(local)
	wd := time.weekday(local)

	card := hrow(ui, "w-full items-center gap-5 px-5 py-4 rounded-xl border border-border bg-card")
	{
		p.div(ui, "size-11 rounded-full bg-muted items-center justify-center shrink-0")
		p.icon(ui, II_MAP_PIN, "size-5 text-foreground")
		p.end(ui)
		p.col(ui, "flex-1 gap-0.5 min-w-0")
		txt(ui, z.city, "text-lg font-semibold text-foreground")
		date := tr("{weekday}, {day} {month} {year}")
		date, _ = strings.replace_all(date, "{weekday}", weekday_name(int(wd)), context.temp_allocator)
		date, _ = strings.replace_all(date, "{day}", fmt.tprintf("%d", d), context.temp_allocator)
		date, _ = strings.replace_all(date, "{month}", month_name(int(mon)), context.temp_allocator)
		date, _ = strings.replace_all(date, "{year}", fmt.tprintf("%d", y), context.temp_allocator)
		txt(ui, date, "text-sm text-muted-foreground")
		if known {
			txt(ui, fmt.tprintf("%s · %s · %s", z.name, abbrev, offset_label(off)), "text-xs font-mono text-muted-foreground")
		} else {
			txt(ui, trf("%s · no time zone data on this system", z.name), "text-xs font-mono text-muted-foreground")
		}
		p.end(ui)
		p.textf(ui, "text-5xl font-semibold tracking-tight text-foreground tabular-nums", "%02d:%02d", h, m)
	}
	hend(ui, card)

	n := p.node_count(ui)
	if changed, _ := sc.input(ui, &st.zone_search, tr("Search for a city, a region or a country")); changed {
		if v := filtered_zones(st); len(v) > 0 {
			pick_zone(st, v[0])
			scroll_selection = true
		}
	}
	take_focus(st, ui, n)

	list := list_box(ui)
	visible := filtered_zones(st)
	for i in visible {
		zz := st.zones[i]
		p.key(ui, fmt.tprintf("tz-%s", zz.name))
		sel := i == st.zone_i
		row := hrow(ui, LIST_ROW)
		p.apply(ui, sel ? LIST_SEL : LIST_IDLE)
		if p.clickable(ui, row) {
			pick_zone(st, i)
		}
		p.col(ui, "flex-1 min-w-0")
		txt(ui, zz.city, "text-sm whitespace-nowrap truncate")
		p.end(ui)
		place := zz.region
		if zz.country != "" {
			country := country_name(zz.country_code, zz.country)
			place = zz.region == "" ? country : fmt.tprintf("%s · %s", country, zz.region)
		}
		p.text(ui, place, "text-xs text-muted-foreground whitespace-nowrap")
		hend(ui, row)
		if sel {
			keep_visible(st, ui, list, row)
		}
	}
	if len(visible) == 0 {
		txt(ui, tr("No time zone matches your search."), "text-sm text-muted-foreground p-3")
	}
	p.end(ui)
}

// ---------------------------------------------------------------------------
// 4. Disk
// ---------------------------------------------------------------------------

page_disk :: proc(st: ^St, ui: ^p.Ctx) {
	if st.want_focus {
		p.set_focus(ui, 0)
		st.want_focus = false
	}
	p.col(ui, "w-full max-w-[760] gap-4")
	defer p.end(ui)

	// The only mode, stated plainly before anything can be chosen.
	note := hrow(ui, "w-full items-start gap-3 p-4 rounded-lg border border-border bg-card/60")
	{
		p.icon(ui, II_INFO, "size-4 text-muted-foreground mt-px shrink-0")
		p.col(ui, "flex-1 gap-1 min-w-0")
		txt(ui, tr("The whole disk will be used"), "text-sm font-medium text-foreground")
		txt(
			ui,
			tr("Palmframe erases the disk you choose and creates a 512 MiB EFI system partition, a small BIOS boot partition so that older computers can start it too, and an ext4 root file system on the rest. Sharing a disk with another system is not supported."),
			"text-sm text-muted-foreground",
		)
		p.end(ui)
	}
	hend(ui, note)

	if len(st.disks) == 0 {
		txt(ui, tr("No disks were found. Attach a disk and restart the installer."), "text-sm text-destructive")
		return
	}

	for d, i in st.disks {
		p.key(ui, fmt.tprintf("disk-%s", d.name))
		usable, why := disk_usable(d)
		sel := i == st.disk_i
		row := hrow(ui, "w-full items-center gap-4 px-4 py-3 rounded-lg border")
		switch {
		case sel:
			p.apply(ui, "border-ring bg-accent/50")
		case usable:
			p.apply(ui, "border-border bg-card/60 hover:bg-muted cursor-pointer")
		case:
			p.apply(ui, "border-border bg-card/30 opacity-60")
		}
		if usable && p.clickable(ui, row) {
			pick_disk(st, i)
		}
		{
			// The radio.
			p.div(ui, sel ? "size-4 rounded-full border-4 border-foreground shrink-0" : "size-4 rounded-full border border-input shrink-0")
			p.end(ui)
			p.div(ui, "size-10 rounded-md bg-muted items-center justify-center shrink-0")
			p.icon(ui, d.removable ? II_USB : II_HARD_DRIVE, "size-5 text-foreground")
			p.end(ui)
			p.col(ui, "flex-1 gap-1 min-w-0")
			head := hrow(ui, "items-center gap-2")
			p.text(ui, d.path, "text-sm font-medium font-mono text-foreground")
			if d.removable {
				sc.badge(ui, tr("Removable"), .Secondary)
			}
			if d.has_partitions && usable {
				sc.badge(ui, tr("Has partitions"), .Outline)
			}
			hend(ui, head)
			txt(ui, disk_model(d), "text-xs text-muted-foreground")
			if !usable {
				txt(ui, tr(why), "text-xs text-muted-foreground")
			} else if d.has_partitions {
				txt(ui, tr("Its partitions and everything on them will be erased."), "text-xs text-muted-foreground")
			}
			p.end(ui)
			p.text(ui, size_label(d.size_bytes), "text-sm font-medium text-foreground whitespace-nowrap tabular-nums")
		}
		hend(ui, row)
	}

	// The swap file, under the disks because it takes room on the one chosen.
	p.div(ui, "w-full pt-2")
	p.end(ui)
	checkbox(ui, &st.swap, trf("Create a swap file of %s", size_label(st.swap_bytes)), tr("Room on the disk for memory that is not in use, so that a full memory slows the computer down instead of closing programs."))
}

// ---------------------------------------------------------------------------
// 5. Account
// ---------------------------------------------------------------------------

page_account :: proc(st: ^St, ui: ^p.Ctx) {
	probs := validate_account(account_of(st))
	cols := hrow(ui, "w-full max-w-[880] items-start gap-8")
	defer hend(ui, cols)

	p.col(ui, "flex-1 gap-5 min-w-0")
	{
		if text_field(st, ui, .Full_Name, &st.full_name, tr("Full name"), tr("Ada Lovelace"), probs, tr("Optional. Shown on the login screen.")) {
			full_name_changed(st)
		}
		if text_field(st, ui, .User, &st.user, tr("User name"), tr("ada"), probs, tr("Lowercase letters and digits; used to log in.")) {
			st.user_edited = len(st.user) > 0
		}
		text_field(st, ui, .Hostname, &st.hostname, tr("Computer name"), "palmframe", probs, tr("How this computer appears on a network."))
	}
	p.end(ui)

	p.col(ui, "flex-1 gap-5 min-w-0")
	{
		text_field(st, ui, .Password, &st.password, tr("Password"), "", probs, "", secret = true)
		strength_meter(ui, password_strength(string(st.password[:])))
		text_field(st, ui, .Confirm, &st.confirm, tr("Confirm password"), "", probs, "", secret = true)

		checkbox(ui, &st.same_root, tr("Use the same password for the administrator (root)"))

		if !st.same_root {
			text_field(st, ui, .Root_Password, &st.root_password, tr("Administrator password"), "", probs, "", secret = true)
			text_field(st, ui, .Root_Confirm, &st.root_confirm, tr("Confirm administrator password"), "", probs, "", secret = true)
		}
	}
	p.end(ui)
}

// text_field is a labelled shadcn input with its problem (or hint) under it.
// A problem shows once the field has been typed into, or once Next has been
// pressed; a confirmation field waits until it is as long as what it
// confirms, so it does not cry "do not match" at the first letter.
text_field :: proc(
	st: ^St,
	ui: ^p.Ctx,
	f: Field,
	buf: ^[dynamic]u8,
	label, placeholder: string,
	probs: Problems,
	hint: string,
	secret := false,
) -> (changed: bool) {
	p.col(ui, "w-full gap-2")
	defer p.end(ui)
	txt(ui, label, "text-sm font-medium text-foreground")

	problem := probs[f]
	shown := problem != "" && (st.tried || f in st.touched)
	if f == .Confirm && !st.tried && len(st.confirm) < len(st.password) {
		shown = false
	}
	if f == .Root_Confirm && !st.tried && len(st.root_confirm) < len(st.root_password) {
		shown = false
	}

	n := p.node_count(ui)
	ch, _ := sc.input(ui, buf, placeholder, {invalid = shown}, secret ? '•' : 0)
	if ch {
		st.touched += {f}
		changed = true
	}
	if want, has := st.focus_field.?; has && want == f {
		p.set_focus(ui, p.node_id(ui, n))
		st.focus_field = nil
		p.redraw(ui)
	} else if st.want_focus && f == .Full_Name {
		take_focus(st, ui, n)
	}

	if shown {
		r := hrow(ui, "items-center gap-1.5")
		p.icon(ui, II_CIRCLE_ALERT, "size-3.5 text-destructive shrink-0")
		// flex-1: one problem replaces another at the same id (see `draw`).
		txt(ui, tr(problem), "flex-1 min-w-0 text-xs text-destructive")
		hend(ui, r)
	} else if hint != "" {
		txt(ui, hint, "text-xs text-muted-foreground")
	}
	return
}

strength_meter :: proc(ui: ^p.Ctx, s: Strength) {
	if s == .None {
		return
	}
	r := hrow(ui, "w-full items-center gap-3 -mt-2")
	defer hend(ui, r)
	bars := hrow(ui, "flex-1 gap-1.5")
	lit := int(s) // Weak 1, Fair 2, Strong 3
	colour := "bg-destructive"
	if s == .Fair {
		colour = "bg-amber-500"
	} else if s == .Strong {
		colour = "bg-emerald-500"
	}
	for i in 1 ..= 3 {
		p.div(ui, i <= lit ? fmt.tprintf("flex-1 h-1 rounded-full %s", colour) : "flex-1 h-1 rounded-full bg-muted")
		p.end(ui)
	}
	hend(ui, bars)
	p.text(ui, strength_label(s), "text-xs text-muted-foreground whitespace-nowrap")
}

// ---------------------------------------------------------------------------
// 6. Summary
// ---------------------------------------------------------------------------

page_summary :: proc(st: ^St, ui: ^p.Ctx) {
	if st.want_focus {
		p.set_focus(ui, 0)
		st.want_focus = false
	}
	p.col(ui, "w-full max-w-[760] gap-4")
	defer p.end(ui)

	d, _ := cur_disk(st)
	warn := hrow(ui, "w-full items-start gap-3 p-4 rounded-lg border border-destructive/50 bg-destructive/10")
	{
		p.icon(ui, II_TRIANGLE_ALERT, "size-4 text-destructive mt-px shrink-0")
		p.col(ui, "flex-1 gap-1 min-w-0")
		txt(ui, trf("%s will be erased", d.path), "text-sm font-semibold text-destructive")
		txt(ui, trf("%s, %s. Everything on it will be lost when you press Install.", disk_model(d), size_label(d.size_bytes)), "text-sm text-destructive/90")
		p.end(ui)
	}
	hend(ui, warn)

	p.col(ui, "w-full rounded-xl border border-border bg-card")
	{
		k := cur_keyboard(st)
		z := cur_zone(st)
		a := account_of(st)
		lang := cur_language(st)
		summary_row(st, ui, .Language, II_LANGUAGES, tr("Language"), lang.native_name, "")
		summary_row(st, ui, .Keyboard, II_KEYBOARD, tr("Keyboard"), keyboard_name(k.description), k.variant == "" ? k.layout : fmt.tprintf("%s (%s)", k.layout, k.variant))
		summary_row(st, ui, .Timezone, II_CLOCK, tr("Time zone"), z.city, z.name)
		summary_row(st, ui, .Disk, II_HARD_DRIVE, tr("Disk"), d.path, tr("GPT: 512 MiB EFI system partition, ext4 root on the rest"))
		summary_row(st, ui, .Disk, II_MEMORY_STICK, tr("Swap"), st.swap ? trf("A swap file of %s", size_label(st.swap_bytes)) : tr("None"), "")
		who := a.full_name == "" ? a.user : fmt.tprintf("%s (%s)", a.full_name, a.user)
		summary_row(st, ui, .Account, II_USER, tr("Account"), who, a.same_root ? tr("The administrator uses the same password") : tr("The administrator has its own password"))
		summary_row(st, ui, .Account, II_SERVER, tr("Computer name"), a.hostname, "", last = true)
	}
	p.end(ui)

	if len(st.core_problems) > 0 {
		box := hrow(ui, "w-full items-start gap-3 p-4 rounded-lg border border-destructive/50 bg-destructive/10")
		p.icon(ui, II_CIRCLE_ALERT, "size-4 text-destructive mt-px shrink-0")
		p.col(ui, "flex-1 gap-1 min-w-0")
		txt(ui, tr("The installer refused this plan"), "text-sm font-semibold text-destructive")
		for pr in st.core_problems {
			txt(ui, text_tr(pr), "text-sm text-destructive/90")
		}
		p.end(ui)
		hend(ui, box)
	}
}

summary_row :: proc(st: ^St, ui: ^p.Ctx, target: Page, ic: p.Icon, label, value, detail: string, last := false) {
	p.key(ui, fmt.tprintf("sum-%s", label))
	r := hrow(ui, "w-full items-center gap-4 px-5 py-3")
	if !last {
		p.apply(ui, "border-b border-border")
	}
	p.icon(ui, ic, "size-4 text-muted-foreground shrink-0")
	p.col(ui, "w-[160] shrink-0")
	txt(ui, label, "text-sm text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 gap-0.5 min-w-0")
	txt(ui, value, "text-sm font-medium text-foreground")
	if detail != "" {
		txt(ui, detail, "text-xs text-muted-foreground")
	}
	p.end(ui)
	b := sc.button_open(ui, .Ghost, .SM, {})
	p.focusable(ui, b)
	if p.focused(ui, b) {
		p.apply(ui, "border-ring ring-3 ring-ring/50", b)
	}
	if p.clickable(ui, b) || (p.focused(ui, b) && (p.key_pressed(ui, p.KEY_RETURN, false) || p.key_pressed(ui, p.KEY_SPACE, false))) {
		consumed_enter = true
		go_to(st, target)
	}
	p.text(ui, tr("Change"), "whitespace-nowrap")
	sc.button_end(ui)
	hend(ui, r)
}

// ---------------------------------------------------------------------------
// 7. Install
// ---------------------------------------------------------------------------

step_name :: proc(s: Install_Step) -> string {
	switch s {
	case .Partition:
		return tr("Partitioning the disk")
	case .Format:
		return tr("Creating file systems")
	case .Mount:
		return tr("Mounting")
	case .Packages:
		return tr("Installing packages")
	case .Configure:
		return tr("Configuring the system")
	case .Bootloader:
		return tr("Installing the boot loader")
	case .Unmount:
		return tr("Finishing")
	case .Done:
		return tr("Done")
	}
	return ""
}

LOG_KEEP :: 400

page_install :: proc(st: ^St, ui: ^p.Ctx) {
	if st.worker == nil {
		return
	}
	snap := worker_snapshot(st.worker, LOG_KEEP)
	failed := snap.finished && !snap.ok
	frac := clamp(snap.progress.fraction, 0, 1)

	p.col(ui, "w-full max-w-[880] flex-1 min-h-0 gap-5")
	defer p.end(ui)

	card := p.col(ui, "w-full gap-4 p-6 rounded-xl border border-border bg-card")
	{
		head := hrow(ui, "w-full items-center gap-3")
		if failed {
			p.icon(ui, II_TRIANGLE_ALERT, "size-5 text-destructive shrink-0")
			p.text(ui, tr("The installation failed"), "text-lg font-semibold text-destructive whitespace-nowrap")
		} else {
			sc.spinner(ui, "size-5", f32(ui.now))
			p.text(ui, step_name(snap.progress.step), "text-lg font-semibold text-foreground whitespace-nowrap")
		}
		p.spacer(ui)
		p.textf(ui, "text-sm font-medium text-muted-foreground tabular-nums", "%d%%", int(frac * 100 + 0.5))
		hend(ui, head)

		sc.progress_track(ui, frac * 100)

		// The steps, ticked off as they pass.
		steps := hrow(ui, "w-full items-center gap-4 flex-wrap")
		for s in Install_Step {
			if s == .Done {
				continue
			}
			p.key(ui, fmt.tprintf("step-%v", s))
			r := hrow(ui, "items-center gap-1.5")
			switch {
			case s < snap.progress.step || snap.progress.step == .Done:
				p.icon(ui, II_CHECK, "size-3.5 text-emerald-400")
				p.text(ui, step_name(s), "text-xs text-foreground whitespace-nowrap")
			case s == snap.progress.step && !failed:
				p.icon(ui, II_LOADER_CIRCLE, "size-3.5 text-foreground", f32(ui.now))
				p.text(ui, step_name(s), "text-xs font-medium text-foreground whitespace-nowrap")
			case s == snap.progress.step && failed:
				p.icon(ui, II_CIRCLE_ALERT, "size-3.5 text-destructive")
				p.text(ui, step_name(s), "text-xs font-medium text-destructive whitespace-nowrap")
			case:
				p.div(ui, "size-3.5 rounded-full border border-border")
				p.end(ui)
				p.text(ui, step_name(s), "text-xs text-muted-foreground whitespace-nowrap")
			}
			hend(ui, r)
		}
		hend(ui, steps)

		if failed {
			txt(ui, snap.err, "text-sm font-mono text-destructive/90")
		} else if snap.progress.detail.msgid != "" {
			txt(ui, text_tr(snap.progress.detail), "text-sm text-muted-foreground whitespace-nowrap truncate")
		} else if snap.progress.message != "" {
			txt(ui, snap.progress.message, "text-sm font-mono text-muted-foreground whitespace-nowrap truncate")
		}
	}
	p.end(ui)
	_ = card

	// The log, folded away until asked for (and unfolded on failure).
	open := st.log_open || failed
	bar := hrow(ui, "w-full items-center gap-3")
	if button(ui, st, open ? tr("Hide details") : tr("Show details"), open ? II_CHEVRON_UP : II_CHEVRON_DOWN, .Ghost) {
		st.log_open = !st.log_open
	}
	p.spacer(ui)
	if failed {
		if button(ui, st, tr("Back to summary"), back_icon(), .Outline) {
			st.worker = nil
			move_to(st, .Summary)
		}
		if button(ui, st, tr("Restart"), II_ROTATE_CW, .Default) {
			st.note = restart_machine(&st.backend)
		}
	}
	hend(ui, bar)

	if open {
		box := p.col(ui, "w-full flex-1 min-h-0 p-3 gap-0.5 rounded-lg border border-border bg-black/40 overflow-scroll")
		for line in snap.log {
			p.text(ui, line, strings.has_prefix(line, "error") ? "text-xs font-mono text-destructive whitespace-nowrap" : "text-xs font-mono text-muted-foreground whitespace-nowrap")
			if is_rtl() {
				// A log is machine text: it reads left to right in any language.
				p.apply(ui, "text-left")
			}
		}
		p.end(ui)
		// Follow the newest line.
		p.scroll_to(ui, p.node_id(ui, box), {0, 1e9})
	}
	if st.note != "" {
		txt(ui, st.note, "text-xs font-mono text-muted-foreground")
	}
}

// ---------------------------------------------------------------------------
// 8. Done
// ---------------------------------------------------------------------------

page_done :: proc(st: ^St, ui: ^p.Ctx) {
	// From the top rather than centred: the compositor parks the pointer at
	// the centre of the screen, where a centred heading would sit under it.
	// This block ends about 360 px down, above the centre of any screen the
	// installer supports (768 px high and up).
	p.col(ui, "w-full flex-1 items-center justify-start pt-24 gap-6")
	defer p.end(ui)
	p.div(ui, "size-20 rounded-full bg-emerald-950 border border-emerald-700 items-center justify-center")
	p.icon(ui, II_CIRCLE_CHECK, "size-10 text-emerald-400")
	p.end(ui)
	p.text(ui, tr("Palmframe is installed"), "text-2xl font-semibold text-foreground text-center")
	p.text(
		ui,
		tr("Remove the installation medium, then restart the computer to start your new system."),
		"text-sm text-muted-foreground text-center max-w-[520]",
	)
	n := p.node_count(ui)
	if button(ui, st, tr("Restart now"), II_ROTATE_CW, .Default) {
		st.note = restart_machine(&st.backend)
	}
	take_focus(st, ui, n)
	if st.note != "" {
		p.text(ui, st.note, "text-xs font-mono text-muted-foreground text-center")
	}
}
