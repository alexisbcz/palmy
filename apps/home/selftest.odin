// `home --selftest`: the search and scoping rules, asserted over the fixtures.
package main

import "core:fmt"
import p "palmy:."

failures := 0

check :: proc(ok: bool, what: string) {
	if !ok {
		failures += 1
		fmt.eprintfln("FAIL  %s", what)
	} else {
		fmt.printfln("ok    %s", what)
	}
}

run_selftest :: proc() {
	s := fixtures_load()

	r := search(&s, "roadmap", -1)
	check(len(r.hits) == 9, "roadmap finds nine things across identities")

	// The rule the window is held to: inside one identity, nothing else.
	for i in 0 ..< len(s.identities) {
		r = search(&s, "roadmap", i)
		leaked := false
		for hit in r.hits {
			if s.items[hit.item].ident != i {
				leaked = true
			}
		}
		check(!leaked, fmt.tprintf("search inside %s returns only %s", s.identities[i].name, s.identities[i].name))
	}

	// `in:` and the window's identity must agree, or nothing matches.
	r = search(&s, "roadmap in:halcyon", 1)
	check(len(r.hits) == 0, "in:halcyon inside Northwind finds nothing")
	r = search(&s, "in:work type:mail", -1)
	all_work_mail := len(r.hits) > 0
	for hit in r.hits {
		it := s.items[hit.item]
		if it.ident != 1 || it.kind != .Mail {
			all_work_mail = false
		}
	}
	check(all_work_mail, "in:work type:mail is Northwind's mail only")

	q := parse_query(&s, "in:nowhere")
	check(q.bad == "in:nowhere", "an unknown identity is reported, not ignored")

	// Grouping: kinds never interleave.
	r = search(&s, "roadmap", -1)
	ordered := true
	for k in 1 ..< len(r.hits) {
		if s.items[r.hits[k].item].kind < s.items[r.hits[k - 1].item].kind {
			ordered = false
		}
	}
	check(ordered, "results are grouped by kind")

	pre, mid, post := split_match("Q4 Roadmap", {"roadmap"})
	check(pre == "Q4 " && mid == "Roadmap" && post == "", "the match is cut out case-insensitively")

	ui_checks()
	fmt.printfln("%d failures", failures)
}

// ui_checks drives the real keys and frame offscreen.
ui_checks :: proc() {
	off := p.offscreen_create(1280, 820, 1, "w-full h-full")
	defer p.offscreen_destroy(off)
	h := Home{}
	home_init(&h, false)
	register_identity_colors(&h.store, false)
	step :: proc(off: ^p.Offscreen, h: ^Home) {
		ui := p.offscreen_begin(off)
		keys(ui, h)
		frame(ui, h)
		p.offscreen_end(off)
	}
	step(off, &h)

	p.type_text(off, "roadmap")
	step(off, &h)
	check(string(h.query[:]) == "roadmap", "typing anywhere searches")
	step(off, &h)
	check(len(h.rows) == 9, "the results are the selectable rows")

	p.press_key(off, '4', {.Ctrl})
	step(off, &h)
	step(off, &h)
	check(h.ident == 3 && len(h.rows) == 2, "Ctrl 4 narrows to Halcyon")

	p.press_key(off, p.KEY_ESCAPE)
	step(off, &h)
	check(len(h.query) == 0, "Esc clears the search")

	p.press_key(off, '0', {.Ctrl})
	step(off, &h)
	p.press_key(off, 'n', {.Ctrl})
	step(off, &h)
	check(h.mode == .Create && h.new_ident == -1, "Ctrl N in all identities does not guess the sender")
	p.press_key(off, p.KEY_RETURN)
	step(off, &h)
	check(h.mode == .Create && h.new_err != "", "and refuses to create until one is chosen")
	p.press_key(off, '2', {.Ctrl})
	step(off, &h)
	p.press_key(off, p.KEY_RETURN)
	step(off, &h)
	check(h.mode == .Normal, "Ctrl 2 then Enter creates it in Northwind")

	p.press_key(off, 'k', {.Ctrl})
	step(off, &h)
	check(h.mode == .Palette, "Ctrl K opens the palette")
	p.type_text(off, "halcyon assistant")
	step(off, &h)
	list := palette_filter(&h)
	check(len(list) == 1 && list[0].action == .Ask && list[0].arg == 3, "the palette filters to the Halcyon assistant")
}
