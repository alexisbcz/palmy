// The prose checker as the editor sees it: the state it keeps, the four
// commands it adds, the squiggles under the text and the problems panel.
//
// Three things here are worth reading for the reasoning rather than the code.
//
// **The frame loop.** vale is a 110-160ms process (measured), so it cannot run
// inside a frame, and the toolkit has no cross-thread frame wake (TODO.md T1).
// The compromise is bounded rather than hidden: the lint runs on a worker
// thread, and *while a run is in flight* the frame asks for the next frame, so
// the result is picked up two or three frames later. That is a poll, but it
// lasts exactly as long as one vale process and then stops — the window goes
// idle again, and nothing here makes the app always-animate. The debounce
// itself needs no frames of its own: the caret blink already asks for frames
// for eight seconds after the last keystroke, which comfortably covers the
// 0.9s wait.
//
// **Accepting a suggestion** goes through `edit_begin` / `delete_range` /
// `insert_text` / `history_break`, exactly as find-and-replace does, so one
// undo takes it back. Nothing here touches runs directly.
//
// **Nothing is ever reported as clean unless it was checked.** A missing vale,
// a broken style package and output that is not JSON all end up in
// `prose.status` with the reason, and the panel says so instead of showing an
// empty list that reads as "no problems".
package main

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

PROSE_W :: f32(380)

Prose :: struct {
	show:      bool, // the panel is open
	enabled:   bool, // re-lint after an edit settles
	probed:    bool,
	available: bool,
	why:       string, // owned: why vale cannot be used
	status:    string, // owned: what the last run did, in one line
	ran:       bool, // a run has completed, so an empty list means something
	stale:     bool, // the document changed since the last run
	skipped:   int, // blocks deliberately not handed to vale
	unmapped:  int, // alerts that failed the position invariant
	last_ms:   int,
	config:    string, // owned: the .vale.ini in use
	project:   bool, // that config is the document's own, not ours
	alerts:    [dynamic]Prose_Alert,
	sel:       int,
	ignored:   [dynamic]string, // rules switched off for this document
	text:      Prose_Text, // the map for the run in flight
}

prose_init :: proc(pr: ^Prose) {
	pr.alerts = make([dynamic]Prose_Alert, 0, 32)
	pr.ignored = make([dynamic]string, 0, 4)
	pr.enabled = true
}

prose_clear_alerts :: proc(pr: ^Prose) {
	for &a in pr.alerts {
		prose_alert_destroy(&a)
	}
	clear(&pr.alerts)
	pr.sel = 0
}

prose_destroy :: proc(pr: ^Prose) {
	prose_clear_alerts(pr)
	delete(pr.alerts)
	for s in pr.ignored {delete(s)}
	delete(pr.ignored)
	delete(pr.why)
	delete(pr.status)
	delete(pr.config)
	prose_text_destroy(&pr.text)
	pr^ = {}
}

prose_status :: proc(st: ^State, msg: string, args: ..any) {
	delete(st.prose.status)
	st.prose.status = strings.clone(fmt.tprintf(msg, ..args))
}

prose_ignored :: proc(pr: ^Prose, check: string) -> bool {
	for s in pr.ignored {
		if s == check {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

// prose_setup probes vale and writes the embedded style package out. Done once
// per session; a missing vale is remembered rather than re-probed every run.
prose_setup :: proc(st: ^State) {
	pr := &st.prose
	if pr.probed {
		return
	}
	pr.probed = true
	ok, why := prose_probe()
	pr.available = ok
	delete(pr.why)
	pr.why = why
	if !ok {
		return
	}
	ini, err := prose_materialise()
	if err != "" {
		pr.available = false
		delete(pr.why)
		pr.why = fmt.aprintf("vale is installed, but the style package could not be written: %s", err)
		delete(ini)
		return
	}
	delete(pr.config)
	pr.config = ini
	pr.project = false
}

// prose_pick_config prefers the document's own project config when there is
// one. A writer who keeps a style guide beside their prose expects it to be
// the one that applies; ours is the fallback for a document that has none.
prose_pick_config :: proc(st: ^State) {
	pr := &st.prose
	if !pr.available {
		return
	}
	found := prose_project_config(st.path)
	if found != "" {
		if pr.project && pr.config == found {
			delete(found)
			return
		}
		delete(pr.config)
		pr.config = found
		pr.project = true
		return
	}
	if !pr.project {
		return
	}
	// Back to ours.
	ini, err := prose_materialise()
	if err == "" {
		delete(pr.config)
		pr.config = ini
		pr.project = false
	} else {
		delete(ini)
	}
}

// prose_mark_stale is the edit hook. It never starts anything: the tick does
// that once the typing has stopped.
prose_mark_stale :: proc(st: ^State) {
	st.prose.stale = true
}

prose_run :: proc(st: ^State) -> bool {
	pr := &st.prose
	prose_setup(st)
	if !pr.available {
		pr.stale = false
		prose_status(st, "%s", pr.why)
		return false
	}
	if prose_busy() {
		return false
	}
	prose_pick_config(st)
	prose_text_destroy(&pr.text)
	pr.text = prose_serialize(&st.doc)
	pr.skipped = pr.text.skipped
	if !prose_start(strings.clone(pr.text.md), pr.config) {
		return false
	}
	pr.stale = false
	return true
}

// prose_lint_sync runs a lint on this thread and installs the result.
//
// The editor never calls it: a 150ms process inside a frame is the whole
// reason `prose_tick` exists. The offscreen screenshots have no frame loop to
// poll with, and there a deterministic picture is worth more than a smooth
// one, so this is the path they take.
prose_lint_sync :: proc(st: ^State) {
	pr := &st.prose
	prose_setup(st)
	if !pr.available {
		prose_status(st, "%s", pr.why)
		return
	}
	prose_pick_config(st)
	prose_text_destroy(&pr.text)
	pr.text = prose_serialize(&st.doc)
	pr.skipped = pr.text.skipped

	list, _, err := prose_lint_text(&st.doc, pr.config)
	defer delete(list)
	prose_clear_alerts(pr)
	pr.stale = false
	if err != "" {
		pr.ran = false
		prose_status(st, "%s", err)
		return
	}
	pr.ran = true
	for &a in list {
		if prose_ignored(pr, a.check) {
			prose_alert_destroy(&a)
			continue
		}
		append(&pr.alerts, a)
	}
	prose_sort(pr.alerts[:])
	if len(pr.alerts) == 0 {
		prose_status(st, "No problems. %s.", prose_engine_label(pr))
	} else {
		prose_status(st, "%s. %s.", prose_tally(pr), prose_engine_label(pr))
	}
	st.dirty = true
}

// prose_absorb takes one finished run: parse, map, verify, keep.
prose_absorb :: proc(st: ^State, out: string, ok: bool, ms: int) {
	pr := &st.prose
	pr.last_ms = ms
	pr.ran = true
	pr.unmapped = 0

	list, unmapped, err := prose_parse(out, &pr.text, &st.doc)
	defer delete(out)
	if err != "" {
		// A linter that did not run must not look like a clean document.
		prose_clear_alerts(pr)
		pr.ran = false
		prose_status(st, "%s", err)
		return
	}

	prose_clear_alerts(pr)
	dropped := 0
	for &a in list {
		if prose_ignored(pr, a.check) {
			prose_alert_destroy(&a)
			continue
		}
		// The invariant, enforced at run time. An alert whose text no longer
		// matches is about a document the user has since changed.
		if !prose_verify(&st.doc, &a) {
			dropped += 1
			prose_alert_destroy(&a)
			continue
		}
		append(&pr.alerts, a)
	}
	delete(list)
	pr.unmapped = unmapped + dropped
	prose_sort(pr.alerts[:])
	pr.sel = clamp(pr.sel, 0, max(0, len(pr.alerts) - 1))

	if len(pr.alerts) == 0 {
		prose_status(st, "No problems. %s, %d ms.", prose_engine_label(pr), ms)
	} else {
		prose_status(st, "%s. %s, %d ms.", prose_tally(pr), prose_engine_label(pr), ms)
	}
	_ = ok
	st.dirty = true
}

prose_engine_label :: proc(pr: ^Prose) -> string {
	return pr.project ? "The project's own .vale.ini" : "The Palm house style"
}

// prose_plural is the difference between "1 error" and "3 errors", which is
// the kind of thing a panel is judged on even though nothing depends on it.
prose_plural :: proc(n: int, one: string) -> string {
	return fmt.tprintf("%d %s%s", n, one, n == 1 ? "" : "s")
}

prose_tally :: proc(pr: ^Prose, alloc := context.temp_allocator) -> string {
	errs, warns, sugs := prose_counts(pr)
	return fmt.aprintf(
		"%s, %s, %s",
		prose_plural(errs, "error"),
		prose_plural(warns, "warning"),
		prose_plural(sugs, "suggestion"),
		allocator = alloc,
	)
}

prose_counts :: proc(pr: ^Prose) -> (errs, warns, sugs: int) {
	for &a in pr.alerts {
		switch a.sev {
		case .Error:
			errs += 1
		case .Warning:
			warns += 1
		case .Suggestion:
			sugs += 1
		}
	}
	return
}

// prose_tick is called once a frame. See the header for why the poll here is
// bounded rather than an always-animate.
prose_tick :: proc(ui: ^p.Ctx, st: ^State) {
	if out, ok, ms, got := prose_collect(); got {
		prose_absorb(st, out, ok, ms)
	}
	if prose_busy() {
		p.redraw(ui)
		return
	}
	pr := &st.prose
	if !pr.show || !pr.enabled || !pr.stale {
		return
	}
	if p.elapsed(ui) - st.last_input < PROSE_DEBOUNCE {
		p.redraw(ui)
		return
	}
	prose_run(st)
}

// ---------------------------------------------------------------------------
// Commands
// ---------------------------------------------------------------------------

prose_toggle :: proc(st: ^State) {
	pr := &st.prose
	pr.show = !pr.show
	st.dirty = true
	if !pr.show {
		// Closing the panel means stop checking, so the squiggles go with it.
		// A mark on the page with nothing to explain it is worse than none.
		prose_clear_alerts(pr)
		pr.ran = false
		pr.stale = true
		note(st, "Prose check off")
		return
	}
	prose_setup(st)
	if !pr.available {
		prose_status(st, "%s", pr.why)
		note(st, "vale is not installed")
		return
	}
	pr.stale = true
	if prose_run(st) {
		note(st, "Checking prose…")
	}
}

prose_current :: proc(st: ^State) -> ^Prose_Alert {
	pr := &st.prose
	if len(pr.alerts) == 0 {
		return nil
	}
	i := clamp(pr.sel, 0, len(pr.alerts) - 1)
	return &pr.alerts[i]
}

// prose_at_caret is the alert the caret is inside, which is what the two
// keyboard commands act on when the panel has not been clicked.
prose_at_caret :: proc(st: ^State) -> int {
	here := Blk{st.caret.para, st.caret.row, st.caret.col, st.caret.cpara}
	for &a, i in st.prose.alerts {
		if a.blk != here {
			continue
		}
		if st.caret.off >= a.from && st.caret.off <= a.to {
			return i
		}
	}
	return -1
}

prose_go :: proc(st: ^State, i: int) {
	pr := &st.prose
	if i < 0 || i >= len(pr.alerts) {
		return
	}
	pr.sel = i
	a := &pr.alerts[i]
	st.anchor = blk_pos(a.blk, a.from)
	st.caret = blk_pos(a.blk, a.to)
	st.goal_ok = false
	history_break(&st.hist)
	scroll_to_caret(st)
	note(st, fmt.tprintf("%s — %s", a.check, a.message))
}

prose_step :: proc(st: ^State, delta: int) {
	pr := &st.prose
	if !pr.show {
		prose_toggle(st)
		return
	}
	if len(pr.alerts) == 0 {
		note(st, pr.ran ? "No problems to step through" : "Nothing has been checked yet")
		return
	}
	// Step from where the caret is, not from where the panel was last clicked.
	at := prose_at_caret(st)
	i := at >= 0 ? at + delta : pr.sel
	if at < 0 {
		// Nearest alert after (or before) the caret.
		i = delta > 0 ? 0 : len(pr.alerts) - 1
		for &a, k in pr.alerts {
			if pos_less(st.caret, blk_pos(a.blk, a.from)) {
				i = delta > 0 ? k : max(0, k - 1)
				break
			}
		}
	}
	n := len(pr.alerts)
	prose_go(st, ((i % n) + n) % n)
}

// prose_case_fix keeps the capitalisation of what is being replaced. vale's
// substitution rules are case-insensitive, so the replacement comes back in
// lower case and would otherwise lower-case the first word of a sentence.
prose_case_fix :: proc(match, fix: string, alloc := context.temp_allocator) -> string {
	if len(match) == 0 || len(fix) == 0 {
		return fix
	}
	up := match[0] >= 'A' && match[0] <= 'Z'
	if !up || !(fix[0] >= 'a' && fix[0] <= 'z') {
		return fix
	}
	b := strings.builder_make(alloc)
	strings.write_byte(&b, fix[0] - 32)
	strings.write_string(&b, fix[1:])
	return strings.to_string(b)
}

// prose_accept applies the linter's own replacement, through the edit path so
// undo takes it back in one step.
prose_accept :: proc(st: ^State) {
	pr := &st.prose
	i := prose_at_caret(st)
	if i < 0 {
		i = clamp(pr.sel, 0, max(0, len(pr.alerts) - 1))
	}
	if i < 0 || i >= len(pr.alerts) {
		note(st, "No problem selected")
		return
	}
	a := pr.alerts[i]
	if a.fix == "" {
		note(st, fmt.tprintf("%s has no replacement to apply", a.check))
		return
	}
	if !prose_verify(&st.doc, &a) {
		note(st, "That text has changed; checking again")
		pr.stale = true
		return
	}

	lo := blk_pos(a.blk, a.from)
	hi := blk_pos(a.blk, a.to)
	cs := style_after(&st.doc, lo)
	repl := prose_case_fix(a.match, a.fix, context.temp_allocator)

	edit_begin(st, .Structural)
	st.caret = delete_range(&st.doc, lo, hi)
	st.anchor = st.caret
	st.caret = insert_text(&st.doc, st.caret, repl, cs)
	st.anchor = st.caret
	history_break(&st.hist)

	// Shift the alerts that follow in the same block, so the remaining
	// squiggles stay on the right words until the next run lands.
	delta := len(repl) - (a.to - a.from)
	for &b in pr.alerts {
		if b.blk == a.blk && b.from >= a.to {
			b.from += delta
			b.to += delta
		}
	}
	note(st, fmt.tprintf("Replaced %q with %q", a.match, repl))
	prose_alert_destroy(&pr.alerts[i])
	ordered_remove(&pr.alerts, i)
	pr.sel = clamp(pr.sel, 0, max(0, len(pr.alerts) - 1))
	// The tally has to move with the list, or the panel reads as one count
	// while the pips above it read as another.
	prose_status(st, "%s. %s, after one accepted.", prose_tally(pr), prose_engine_label(pr))
	pr.stale = true
}

// prose_ignore switches one rule off for this document. The rule still runs —
// turning it off in the config would mean rewriting a file the user may own —
// its alerts are simply not kept, which is also what makes it reversible.
prose_ignore :: proc(st: ^State) {
	pr := &st.prose
	i := prose_at_caret(st)
	if i < 0 {
		i = clamp(pr.sel, 0, max(0, len(pr.alerts) - 1))
	}
	if i < 0 || i >= len(pr.alerts) {
		note(st, "No problem selected")
		return
	}
	check := strings.clone(pr.alerts[i].check)
	if prose_ignored(pr, check) {
		delete(check)
		return
	}
	append(&pr.ignored, check)
	for k := 0; k < len(pr.alerts); {
		if pr.alerts[k].check == check {
			prose_alert_destroy(&pr.alerts[k])
			ordered_remove(&pr.alerts, k)
			continue
		}
		k += 1
	}
	pr.sel = clamp(pr.sel, 0, max(0, len(pr.alerts) - 1))
	st.dirty = true
	note(st, fmt.tprintf("%s off for this document", check))
	prose_status(st, "%s. %s off.", prose_tally(pr), prose_plural(len(pr.ignored), "rule"))
}

prose_restore_rules :: proc(st: ^State) {
	pr := &st.prose
	if len(pr.ignored) == 0 {
		note(st, "No rules are off")
		return
	}
	for s in pr.ignored {delete(s)}
	clear(&pr.ignored)
	pr.stale = true
	note(st, "Every rule back on")
}

// ---------------------------------------------------------------------------
// Drawing: the marks under the text
// ---------------------------------------------------------------------------

COL_PROSE_ERROR :: u32(0xdc2626)
COL_PROSE_WARN :: u32(0xd97706)
COL_PROSE_SUG :: u32(0x2563eb)

prose_sev_color :: proc(s: Prose_Severity) -> u32 {
	switch s {
	case .Error:
		return COL_PROSE_ERROR
	case .Warning:
		return COL_PROSE_WARN
	case .Suggestion:
		return COL_PROSE_SUG
	}
	return COL_PROSE_SUG
}

// draw_prose_marks underlines the flagged spans on one line.
//
// A squiggle rather than a solid rule, and under the baseline rather than
// through it, because the text has to stay readable: three severities on a page
// of prose is a lot of ink, and a solid underline also collides with the
// `underline` character style the document itself can carry. The selected
// alert gets a faint wash as well, which is what makes "jump to" land visibly.
draw_prose_marks :: proc(c: ^p.Canvas, st: ^State, li: int, ox, ly, lh, k: f32) {
	pr := &st.prose
	l := st.lay.lines[li]
	blk := line_blk(l)
	base_y := ly + lh - 2.5 * k

	for &a, i in pr.alerts {
		if a.blk != blk {
			continue
		}
		from := max(a.from, l.start)
		to := min(a.to, l.end)
		if to <= from {
			continue
		}
		x0 := caret_x(&st.lay, li, from)
		x1 := caret_x(&st.lay, li, to)
		if x1 - x0 < 0.5 {
			continue
		}
		col := p.hex(prose_sev_color(a.sev))
		if i == pr.sel && pr.show {
			wash := col
			wash.a = 34
			p.fill_rect(c, {ox + x0 * k, ly, (x1 - x0) * k, lh}, wash)
		}
		// Two-pixel teeth, alternating by one pixel: a squiggle that survives
		// being drawn at one device pixel, which a sine wave does not.
		step := max(2, 2 * k)
		th := max(1, 1.1 * k)
		x := ox + x0 * k
		end := ox + x1 * k
		up := false
		for x < end {
			w := min(step, end - x)
			p.fill_rect(c, {x, base_y + (up ? -th : 0), w, th}, col)
			x += step
			up = !up
		}
	}
}

// ---------------------------------------------------------------------------
// The problems panel
// ---------------------------------------------------------------------------

PROSE_ROWS :: 8

prose_panel :: proc(ui: ^p.Ctx, st: ^State) {
	pr := &st.prose

	p.col(ui, tfmt("w-[%.0f] h-full shrink-0 bg-muted/30 overflow-hidden", PROSE_W))
	defer p.end(ui)

	// --- header
	p.row(ui, "w-full h-10 shrink-0 items-center gap-2 px-3")
	p.icon(ui, ICON_FILE_TEXT, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Problems", "text-[12.5] font-semibold whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	errs, warns, sugs := prose_counts(pr)
	if len(pr.alerts) > 0 {
		if errs > 0 {prose_pip(ui, .Error, errs)}
		if warns > 0 {prose_pip(ui, .Warning, warns)}
		if sugs > 0 {prose_pip(ui, .Suggestion, sugs)}
	}
	if prose_busy() {
		sc.spinner(ui, "size-3.5")
	}
	p.end(ui)
	sc.separator(ui)

	// --- the one line that says whether anything actually ran
	p.col(ui, "w-full shrink-0 gap-1 px-3 py-2")
	cls := "text-[11] text-muted-foreground whitespace-normal"
	if !pr.available && pr.probed {
		cls = tfmt("text-[11] %s whitespace-normal", kit.BAD_CLASS)
	}
	p.text(ui, pr.status == "" ? "Not checked yet." : pr.status, cls)
	if pr.skipped > 0 {
		p.text(
			ui,
			tfmt("%s not checked (code, a picture or a grid).", prose_plural(pr.skipped, "block")),
			"text-[11] text-muted-foreground whitespace-normal",
		)
	}
	if pr.unmapped > 0 {
		p.text(
			ui,
			tfmt("%s dropped: the text no longer matches the document.", prose_plural(pr.unmapped, "alert")),
			"text-[11] text-amber-600 whitespace-normal",
		)
	}
	if len(pr.ignored) > 0 {
		p.text(
			ui,
			tfmt("Off for this document: %s", strings.join(pr.ignored[:], ", ", context.temp_allocator)),
			"text-[11] text-muted-foreground whitespace-normal",
		)
	}
	p.end(ui)
	sc.separator(ui)

	// --- the list. The keyboard hints below are a sibling of this column, not
	// a child of it: inside, a tall list pushes them off the bottom edge.
	p.col(ui, "flex-1 w-full min-h-0 overflow-hidden")

	if len(pr.alerts) == 0 {
		p.col(ui, "w-full flex-1 items-center justify-center px-6")
		p.text(
			ui,
			!pr.available ? "Nothing was checked." : pr.ran ? "No problems found." : "Press Ctrl+G to check.",
			"text-[12] text-muted-foreground whitespace-normal",
		)
		p.end(ui)
		p.end(ui)
		prose_footer(ui, st, 0, 0)
		return
	}

	// A fixed window of rows scrolled by the selection: palmy has a scroll
	// area, but a list driven entirely from the keyboard reads better when the
	// selection pulls the window rather than a bar the keyboard cannot reach.
	first := clamp(pr.sel - PROSE_ROWS / 2, 0, max(0, len(pr.alerts) - PROSE_ROWS))
	last := min(len(pr.alerts), first + PROSE_ROWS)
	for i in first ..< last {
		a := &pr.alerts[i]
		p.key(ui, tfmt("alert-%d", i))
		idx := p.col(ui, "w-full shrink-0 gap-0.5 px-3 py-2 cursor-pointer transition")
		if i == pr.sel {
			p.apply(ui, "bg-accent", idx)
		} else {
			p.apply(ui, "hover:bg-accent/50", idx)
		}
		if p.clickable(ui, idx) {
			prose_go(st, i)
		}

		p.row(ui, "w-full items-center gap-2")
		p.div(ui, tfmt("size-2 shrink-0 rounded-full %s", prose_dot_class(a.sev)))
		p.end(ui)
		p.text(ui, a.check, "text-[11] font-medium text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		if a.fix != "" {
			p.text(ui, tfmt("→ %s", a.fix), "text-[11] text-emerald-600 whitespace-nowrap")
			p.style(ui).shrink = 0
		}
		p.end(ui)

		p.text(ui, a.message, "text-[12] text-foreground whitespace-normal")
		p.text(
			ui,
			tfmt("%q · line %d, column %d", a.match, a.line, a.col),
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.end(ui)
	}
	p.spacer(ui)
	p.end(ui)
	prose_footer(ui, st, first + 1, last)
}

// prose_footer carries the keyboard, and the window into the list. The window
// line lives here rather than at the end of the list because the list is
// clipped and anything after the last row that fits is not drawn.
prose_footer :: proc(ui: ^p.Ctx, st: ^State, from, to: int) {
	pr := &st.prose
	sc.separator(ui)
	p.col(ui, "w-full shrink-0 gap-1 px-3 py-2")
	defer p.end(ui)

	if to > from && to < len(pr.alerts) || from > 1 {
		p.text(
			ui,
			tfmt("Showing %d–%d of %d", from, to, len(pr.alerts)),
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
	}
	for row in ([?][2]string {
		{"Alt+N / Alt+P", "next / previous problem"},
		{"Alt+Y", "accept the replacement"},
		{"Alt+X", "this rule off for the document"},
		{"Ctrl+G", "close the panel"},
	}) {
		p.key(ui, row[0])
		p.row(ui, "w-full items-center gap-2")
		sc.kbd(ui, row[0])
		p.text(ui, row[1], "text-[11] text-muted-foreground truncate")
		p.end(ui)
	}
}

prose_dot_class :: proc(s: Prose_Severity) -> string {
	switch s {
	case .Error:
		return "bg-red-600"
	case .Warning:
		return "bg-amber-600"
	case .Suggestion:
		return "bg-blue-600"
	}
	return "bg-blue-600"
}

prose_pip :: proc(ui: ^p.Ctx, s: Prose_Severity, n: int) {
	p.key(ui, prose_sev_label(s))
	p.row(ui, "h-5 shrink-0 items-center gap-1 px-1.5 rounded-full bg-background border border-border")
	defer p.end(ui)
	p.div(ui, tfmt("size-1.5 shrink-0 rounded-full %s", prose_dot_class(s)))
	p.end(ui)
	p.text(ui, tfmt("%d", n), "text-[10.5] font-medium whitespace-nowrap")
	p.style(ui).shrink = 0
}
