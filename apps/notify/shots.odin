// `notify shots <dir>`: the toasts and the center, offscreen, light and
// dark, over invented identities and notifications. No daemon, no
// compositor: the same draw procedures the surfaces run, through palmy's
// offscreen renderer.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// A fixed instant, so "now" and "12 min" are the same in every capture:
// Monday 19 October 2026, 18:42 in a UTC+2 zone.
FIX_TZ :: i64(7200)
FIX_NOW :: i64(1792428120000)

FIX_IDENTS := [?]Ident {
	{"camille", "Personal", "teal"},
	{"camille.roux", "Northwind", "blue"},
	{"hello", "Public", "amber"},
	{"halcyon", "Halcyon", "violet"},
}

fix_note :: proc(id: u32, ident, app, title, body: string, class: Class, ago_min: int, why := "", category := "", urgency := Urgency.Normal, delivery := Delivery.Toast, showing := false, held := false, read := false, actions: []View_Action = nil) -> View_Note {
	n := View_Note {
		id         = id,
		key        = strings.clone(fmt.tprintf("%s:%d", app, id)),
		app        = strings.clone(app),
		app_label  = strings.clone(app_label(app)),
		identity   = strings.clone(ident),
		ident_name = strings.clone(identity_name(ident)),
		class      = class,
		urgency    = urgency,
		category   = strings.clone(category),
		title      = strings.clone(title),
		body       = strings.clone(body),
		why        = strings.clone(why),
		delivery   = delivery,
		showing    = showing,
		held       = held,
		read       = read,
		created    = FIX_NOW - i64(ago_min) * 60_000,
	}
	acts := make([dynamic]View_Action)
	for a in actions {
		append(&acts, View_Action{strings.clone(a.key), strings.clone(a.label)})
	}
	n.actions = acts[:]
	tmp := Note {
		app      = app,
		identity = ident,
		class    = class,
		urgency  = urgency,
		category = category,
		title    = title,
		body     = body,
	}
	for a in actions {
		append(&tmp.actions, Action{a.key, a.label, ""})
	}
	n.spoken = strings.clone(spoken(&tmp))
	delete(tmp.actions)
	return n
}

fix_toasts :: proc(v: ^View, digest: bool) {
	view_clear(v)
	if digest {
		d := fix_note(41, "camille.roux", "notify", "6 notifications while quiet", "Mail 3 · Forge 2 · Drive 1\nIness Roux: Moved the design review to Thursday", .Machine, 0, why = "Northwind: while quiet", showing = true)
		d.is_digest = true
		d.count = 6
		append(&v.notes, d)
		append(&v.notes, fix_note(40, "camille", "calendar", "Pottery class in 15 minutes", "Atelier Céramique · Rue des Martyrs", .Time, 0, why = "At its time", showing = true, actions = {{"snooze", "Snooze"}, {"directions", "Directions"}}))
		return
	}
	append(&v.notes, fix_note(30, "camille", "chat", "Priya Shah", "Are we still on for dinner on Saturday? I booked the place near the canal.", .Person, 2, why = "From a person", showing = true, actions = {{"reply", "Reply"}, {"default", "Open"}}))
	append(&v.notes, fix_note(31, "camille.roux", "call", "Ines Roux", "Incoming call · Northwind design review", .Person, 0, why = "Northwind is quiet; calls break through", category = "call.incoming", urgency = .Critical, showing = true, actions = {{"answer", "Answer"}, {"decline", "Decline"}}))
	append(&v.notes, fix_note(32, "", "Chromium", "Your download is complete", "quarterly-report-final-v3.pdf · 2.4 MB · github.com", .Person, 1, why = "From a person", showing = true, actions = {{"default", "Open"}, {"settings", "Settings"}}))
	append(&v.notes, fix_note(33, "hello", "mail", "New subscriber reply", "Re: Studio newsletter, October", .Person, 1, showing = true))
}

fix_center :: proc(v: ^View) {
	view_clear(v)
	v.dnd = false
	add :: proc(v: ^View, n: View_Note) {
		append(&v.notes, n)
	}
	add(v, fix_note(20, "camille.roux", "call", "Ines Roux", "Missed call · Northwind design review", .Person, 4, why = "Northwind is quiet; calls break through", category = "call.incoming", urgency = .Critical, delivery = .Toast, actions = {{"callback", "Call back"}}))
	add(v, fix_note(19, "camille", "chat", "Priya Shah", "Are we still on for dinner on Saturday? I booked the place near the canal.", .Person, 6, why = "From a person", actions = {{"reply", "Reply"}}))
	add(v, fix_note(18, "camille.roux", "mail", "Iness Roux", "Moved the design review to Thursday; the room is booked.", .Person, 12, why = "Northwind is quiet", held = true, delivery = .Digest))
	add(v, fix_note(17, "camille.roux", "forge", "Review requested: palmy#412", "Theo asked you to review “layer surfaces resize”", .Person, 30, why = "Northwind is quiet", held = true, delivery = .Digest))
	add(v, fix_note(16, "camille.roux", "forge", "CI passed on main", "4f2a1c0 · 6 checks · 3 min 12 s", .Machine, 52, why = "Machines go in the 17:00 digest", delivery = .Center, read = true))
	add(v, fix_note(15, "hello", "store", "3 updates are ready", "palmy-wm, notify and term", .Machine, 80, why = "Machines never interrupt", delivery = .Center))
	add(v, fix_note(14, "hello", "mail", "Your invoice from Fastmail", "Receipt #48213 · €5.00", .Machine, 140, why = "Machines never interrupt", delivery = .Center, read = true))
	add(v, fix_note(13, "camille", "drive", "Sync conflict in Taxes 2026.xlsx", "Both copies were kept: “Taxes 2026 (laptop).xlsx”", .Machine, 200, why = "Machines never interrupt", delivery = .Center, actions = {{"resolve", "Resolve"}}))
	add(v, fix_note(12, "", "Chromium", "Your download is complete", "quarterly-report-final-v3.pdf · 2.4 MB", .Person, 9, why = "From a person", read = true))

	pol :: proc(v: ^View, ident, sentence: string, hold: Hold, ends: string, quiet_until: bool) {
		append(&v.policies, View_Policy{strings.clone(ident), strings.clone(identity_name(ident)), strings.clone(sentence), hold, strings.clone(ends), quiet_until})
	}
	pol(v, "camille", "People only", .None, "", false)
	pol(v, "camille.roux", "Quiet after 18:00. Daily digest at 17:00. Calls break through", .Quiet, "08:00", false)
	pol(v, "hello", "Daily digest at 17:00. Mute Chromium", .None, "", false)
}

@(private = "file")
fonts_for :: proc(off: ^p.Offscreen, dark: bool) {
	load_ui_fonts(&off.fonts, dark)
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
}

shots_main :: proc(args: []string) -> int {
	dir := len(args) > 0 ? args[0] : "shots"
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		fmt.eprintfln("notify shots: cannot create %s", dir)
		return 1
	}
	identities_set(FIX_IDENTS[:])
	n := 0
	for dark in ([?]bool{false, true}) {
		theme := dark ? "dark" : "light"

		// Toasts: the stack, then the same stack with the keyboard in it,
		// then a digest after quiet hours.
		for variant in 0 ..< 3 {
			t := new(Toasts)
			t.dark = dark
			t.tz = FIX_TZ
			t.now = FIX_NOW
			t.offline = true
			fix_toasts(&t.view, variant == 2)
			handles_sync(&t.handles, t.view.notes[:])
			if variant == 1 {
				t.focused = true
				t.sel = 1
			}
			for &x in t.view.notes {
				t.total[x.id] = 8000
				t.left[x.id] = x.id == 30 ? 5200 : 7400
			}
			measure_off := p.offscreen_create(TOAST_W, 1400, 1, TOAST_ROOT)
			fonts_for(measure_off, dark)
			register_view_colors(t.handles[:], dark)
			h := 0
			for _ in 0 ..< 2 {
				ui := p.offscreen_begin(measure_off)
				idx := draw_toasts(ui, t)
				p.offscreen_end(measure_off)
				h = int(p.node_rect(&measure_off.ctx, idx).h + 0.999)
			}
			p.offscreen_destroy(measure_off)

			off := p.offscreen_create(TOAST_W, h, 1, TOAST_ROOT)
			fonts_for(off, dark)
			register_view_colors(t.handles[:], dark)
			for _ in 0 ..< 3 {
				ui := p.offscreen_begin(off)
				draw_toasts(ui, t)
				p.offscreen_end(off)
			}
			names := [?]string{"toasts", "toasts-keyboard", "toasts-digest"}
			name := names[variant]
			path := fmt.tprintf("%s/%s-%s.png", dir, name, theme)
			if p.offscreen_write_png(off, path) {
				fmt.printfln("  %s (%dx%d)", path, TOAST_W, h)
				n += 1
			}
			p.offscreen_destroy(off)
		}

		// The center: everything, then one identity.
		for variant in 0 ..< 2 {
			c := new(Center)
			c.dark = dark
			c.tz = FIX_TZ
			c.now = FIX_NOW
			c.offline = true
			fix_center(&c.view)
			handles_sync(&c.handles, c.view.notes[:])
			if variant == 1 {
				c.filter = "camille.roux"
			}
			off := p.offscreen_create(CENTER_W, 820, 1, "w-full h-full flex-col bg-background text-foreground border-l border-border overflow-hidden")
			fonts_for(off, dark)
			register_view_colors(c.handles[:], dark)
			for _ in 0 ..< 3 {
				ui := p.offscreen_begin(off)
				draw_center(ui, c)
				p.offscreen_end(off)
			}
			name := variant == 0 ? "center" : "center-northwind"
			path := fmt.tprintf("%s/%s-%s.png", dir, name, theme)
			if p.offscreen_write_png(off, path) {
				fmt.printfln("  %s", path)
				n += 1
			}
			p.offscreen_destroy(off)
		}
	}
	fmt.printfln("notify shots: %d PNGs in %s", n, dir)
	return 0
}
