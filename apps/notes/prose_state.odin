package main

// The writing coach: state, scheduling, and the edit path a suggestion takes.
//
// The engine lives in `apps/prose` and is the same code `prose lint` runs —
// this file is the other front end, and holds only what a window needs that a
// command does not: when to re-analyse, which mark is selected, and how an
// accepted suggestion reaches the buffer.
//
// Scheduling, which is the part that can make an editor feel broken:
//
//   - Nothing runs on the keystroke itself. Two debounces hang off the last
//     edit: a short one that re-analyses the *paragraph* under the caret, and
//     a long one that does a full pass. Typing continuously means the short
//     one keeps being pushed back and neither fires, which is correct — marks
//     that move under your fingers are worse than marks that arrive late.
//   - The paragraph pass patches the alert list in place: alerts before the
//     window keep their offsets, alerts after it shift by the byte delta, and
//     the ones inside are replaced. So a mark three paragraphs down stays
//     where it belongs without the document being re-read.
//   - The document-level rules (readability, consistency, conditional) only
//     run in the full pass. A paragraph cannot decide whether a word is
//     spelled two ways elsewhere, and pretending otherwise would make the
//     report flicker.
//   - Everything is on the frame thread. `TODO.md` T1 says the toolkit has no
//     cross-thread frame wake, so going off-thread would need either a poll
//     or a sleeping frame loop — a poll is the bug already filed against ten
//     applications, and this work does not need a thread: a full pass over a
//     long note is single-digit milliseconds. `prose --bench FILE` prints the
//     measurement, and the application pays the same cost.
//   - While a pass is pending, `p.redraw` is called so the clock keeps
//     running; once it fires, nothing asks for another frame. The app returns
//     to being idle, exactly as the autosave timer already does.

import "core:os"
import "core:strings"
import p "palmy:."
import prose "../prose"

// The two debounces. 140 ms is under the threshold where a pause in typing
// feels deliberate; 700 ms is long enough that the full pass lands between
// sentences rather than between keystrokes.
PROSE_DEBOUNCE :: 0.14
PROSE_FULL_DEBOUNCE :: 0.7

Prose :: struct {
	eng:            prose.Engine,
	ready:          bool,
	on:             bool,
	style:          int, // index into eng.packs
	alerts:         [dynamic]prose.Alert, // owned: strings are ours to free
	counts:         prose.Counts,
	report:         prose.Report,
	have_report:    bool,
	show_report:    bool,
	mark:           int, // index into alerts, -1 for none
	// scheduling
	dirty:          bool,
	full_dirty:     bool,
	at:             f64,
	full_at:        f64,
	win_from:       int,
	win_to:         int,
	doc_len:        int,
	// what the user has switched off
	dismissed:      [dynamic]string, // everywhere
	note_dismissed: [dynamic]string, // this note only
	// the picker
	pick_sel:       int,
	global_style:   int, // the style every note uses unless it says otherwise
	note_style:     string, // this note's own style, "" when it has none
	last_pass_ms:   f64,
	passes:         int,
}

prose_init :: proc(nt: ^Notes) {
	nt.pr.eng = prose.engine_builtin()
	nt.pr.ready = true
	nt.pr.on = true
	nt.pr.style = 0
	nt.pr.global_style = 0
	nt.pr.mark = -1
	nt.pr.alerts = make([dynamic]prose.Alert, 0, 32)
	nt.pr.dismissed = make([dynamic]string, 0, 4)
	nt.pr.note_dismissed = make([dynamic]string, 0, 4)
	prose_conf_load(nt)
}

prose_destroy :: proc(nt: ^Notes) {
	prose_clear(nt)
	delete(nt.pr.alerts)
	for s in nt.pr.dismissed {
		delete(s)
	}
	delete(nt.pr.dismissed)
	for s in nt.pr.note_dismissed {
		delete(s)
	}
	delete(nt.pr.note_dismissed)
	delete(nt.pr.note_style)
	if nt.pr.have_report {
		prose.report_destroy(&nt.pr.report)
	}
	prose.engine_destroy(&nt.pr.eng)
	prose.cache_destroy()
}

@(private = "file")
alert_free :: proc(a: prose.Alert) {
	delete(a.match)
	delete(a.message)
	delete(a.fix)
}

prose_clear :: proc(nt: ^Notes) {
	for a in nt.pr.alerts {
		alert_free(a)
	}
	clear(&nt.pr.alerts)
	nt.pr.mark = -1
}

prose_pack :: proc(nt: ^Notes) -> ^prose.Pack {
	if !nt.pr.ready || nt.pr.style < 0 || nt.pr.style >= len(nt.pr.eng.packs) {
		return nil
	}
	return &nt.pr.eng.packs[nt.pr.style]
}

prose_style_name :: proc(nt: ^Notes) -> string {
	pk := prose_pack(nt)
	return pk == nil ? "none" : pk.name
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

// prose_opts gathers the dismissals, note-local first.
@(private = "file")
prose_opts :: proc(nt: ^Notes) -> prose.Opts {
	drop := make([dynamic]string, 0, len(nt.pr.dismissed) + len(nt.pr.note_dismissed), context.temp_allocator)
	append(&drop, ..nt.pr.dismissed[:])
	append(&drop, ..nt.pr.note_dismissed[:])
	return prose.Opts{pack = nt.pr.style, min_sev = .Suggestion, dismissed = drop[:]}
}

// prose_touch records that the text changed, and where. `line` is the buffer
// line the caret was on, which is enough to find the paragraph.
prose_touch :: proc(ui: ^p.Ctx, nt: ^Notes, line: int) {
	if !nt.pr.on || !nt.pr.ready {
		return
	}
	now := f64(p.elapsed(ui))
	nt.pr.dirty = true
	nt.pr.full_dirty = true
	nt.pr.at = now
	nt.pr.full_at = now
	// Widen the pending window to cover every edit since the last pass.
	off := line_offset(nt, line)
	if nt.pr.win_to == 0 && nt.pr.win_from == 0 {
		nt.pr.win_from, nt.pr.win_to = off, off
	} else {
		nt.pr.win_from = min(nt.pr.win_from, off)
		nt.pr.win_to = max(nt.pr.win_to, off)
	}
}

// prose_invalidate throws everything away: a different note, a different
// style, a dismissal.
prose_invalidate :: proc(ui: ^p.Ctx, nt: ^Notes) {
	prose_clear(nt)
	if nt.pr.have_report {
		prose.report_destroy(&nt.pr.report)
		nt.pr.have_report = false
	}
	nt.pr.dirty = true
	nt.pr.full_dirty = true
	nt.pr.win_from, nt.pr.win_to = 0, 0
	if ui != nil {
		nt.pr.at = f64(p.elapsed(ui))
		nt.pr.full_at = nt.pr.at
	} else {
		nt.pr.at = 0
		nt.pr.full_at = 0
	}
}

// prose_tick is called once per frame. It is the only thing that starts a
// pass, and it asks for a redraw only while one is still owed.
prose_tick :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pr.on || !nt.pr.ready {
		return
	}
	if !nt.pr.dirty && !nt.pr.full_dirty {
		return
	}
	now := f64(p.elapsed(ui))
	p.redraw(ui)

	if nt.pr.full_dirty && now - nt.pr.full_at >= PROSE_FULL_DEBOUNCE {
		prose_full(nt)
		return
	}
	if nt.pr.dirty && now - nt.pr.at >= PROSE_DEBOUNCE {
		prose_window(nt)
	}
}

// prose_force runs a full pass now, for the moments where waiting would look
// like the feature is broken: opening the report, switching style, or being
// asked to jump to the next issue.
prose_force :: proc(nt: ^Notes) {
	if !nt.pr.on || !nt.pr.ready {
		return
	}
	prose_full(nt)
}

@(private = "file")
prose_full :: proc(nt: ^Notes) {
	src := note_text(nt, context.temp_allocator)
	res := prose.lint(&nt.pr.eng, src, prose_opts(nt), context.temp_allocator)

	keep := -1
	if nt.pr.mark >= 0 && nt.pr.mark < len(nt.pr.alerts) {
		keep = nt.pr.alerts[nt.pr.mark].from
	}
	prose_clear(nt)
	for a in res.alerts {
		append(&nt.pr.alerts, alert_own(a))
	}
	nt.pr.counts = res.counts

	if nt.pr.have_report {
		prose.report_destroy(&nt.pr.report)
	}
	nt.pr.report = prose.report_of(&res)
	nt.pr.have_report = true

	nt.pr.dirty = false
	nt.pr.full_dirty = false
	nt.pr.win_from, nt.pr.win_to = 0, 0
	nt.pr.doc_len = len(src)
	nt.pr.passes += 1

	// Keep the selection on the same place in the text if an alert is still
	// there, so accepting one suggestion does not scroll the panel away.
	if keep >= 0 {
		nt.pr.mark = prose.alert_at(nt.pr.alerts[:], keep)
	}
}

// prose_tick_now runs whatever pass is owed, with no clock and no frame. It
// exists for the selftest, which asserts that a paragraph pass and a full pass
// agree — the claim the whole per-keystroke design rests on.
prose_tick_now :: proc(nt: ^Notes) {
	if !nt.pr.on || !nt.pr.ready {
		return
	}
	if nt.pr.dirty {
		prose_window(nt)
	}
}

// prose_window re-analyses only the blocks the edits touched, and patches the
// alert list around them.
@(private = "file")
prose_window :: proc(nt: ^Notes) {
	src := note_text(nt, context.temp_allocator)
	delta := len(src) - nt.pr.doc_len
	from := clamp(nt.pr.win_from, 0, len(src))
	to := clamp(max(nt.pr.win_to + max(0, delta), from), from, len(src))

	res := prose.lint_window(&nt.pr.eng, src, from, to, prose_opts(nt), context.temp_allocator)

	// The window the engine actually used, widened to whole blocks.
	wf, wt := from, to
	for b in res.masked.blocks {
		if b.to > from && b.from < to {
			wf = min(wf, b.from)
			wt = max(wt, b.to)
		}
	}

	keep := -1
	if nt.pr.mark >= 0 && nt.pr.mark < len(nt.pr.alerts) {
		keep = nt.pr.alerts[nt.pr.mark].from
	}

	out := make([dynamic]prose.Alert, 0, len(nt.pr.alerts) + len(res.alerts))
	for a in nt.pr.alerts {
		// A document-level alert sits at offset 0 and is not the window's to
		// decide; it survives untouched until the next full pass.
		doc_level := a.kind == .Readability
		if a.to <= wf || doc_level {
			append(&out, a)
			continue
		}
		if a.from >= wt {
			b := a
			b.from += delta
			b.to += delta
			b.line = 0 // recomputed below
			append(&out, b)
			continue
		}
		alert_free(a) // inside the window: replaced
	}
	for a in res.alerts {
		append(&out, alert_own(a))
	}
	delete(nt.pr.alerts)
	nt.pr.alerts = out

	// Re-sort and recompute line/column from the new text.
	lines := prose.line_starts(src, context.temp_allocator)
	for &a in nt.pr.alerts {
		a.line, a.col = prose.line_col(lines, clamp(a.from, 0, len(src)))
		_, a.end_col = prose.line_col(lines, clamp(max(a.from, a.to - 1), 0, len(src)))
	}
	sort_alerts(nt.pr.alerts[:])

	nt.pr.dirty = false
	nt.pr.win_from, nt.pr.win_to = 0, 0
	nt.pr.doc_len = len(src)
	nt.pr.passes += 1
	if keep >= 0 {
		nt.pr.mark = prose.alert_at(nt.pr.alerts[:], keep)
	}
}

@(private = "file")
alert_own :: proc(a: prose.Alert) -> prose.Alert {
	b := a
	b.match = strings.clone(a.match)
	b.message = strings.clone(a.message)
	b.fix = strings.clone(a.fix)
	// `why` and `link` point into the rule, which outlives every alert.
	return b
}

@(private = "file")
sort_alerts :: proc(as: []prose.Alert) {
	// Insertion sort: the list is almost ordered already, because only one
	// window's worth of alerts moved.
	for i in 1 ..< len(as) {
		j := i
		for j > 0 && as[j - 1].from > as[j].from {
			as[j], as[j - 1] = as[j - 1], as[j]
			j -= 1
		}
	}
}

// ---------------------------------------------------------------------------
// Offsets
// ---------------------------------------------------------------------------

// The buffer is a line array and the engine speaks byte offsets into one
// string, so these two convert. The note is a few kilobytes, so walking the
// lines is cheaper than keeping a table in sync with every edit.

line_offset :: proc(nt: ^Notes, line: int) -> int {
	off := 0
	for i in 0 ..< clamp(line, 0, buf_lines(&nt.buf)) {
		off += len(buf_line(&nt.buf, i)) + 1
	}
	return off
}

doc_offset :: proc(nt: ^Notes, at: Pos) -> int {
	return line_offset(nt, at.line) + at.col
}

doc_pos :: proc(nt: ^Notes, off: int) -> Pos {
	rest := off
	for i in 0 ..< buf_lines(&nt.buf) {
		n := len(buf_line(&nt.buf, i))
		if rest <= n {
			return pos_clamp(&nt.buf, Pos{i, max(0, rest)})
		}
		rest -= n + 1
	}
	return buf_end(&nt.buf)
}

// ---------------------------------------------------------------------------
// Selection and navigation
// ---------------------------------------------------------------------------

prose_mark :: proc(nt: ^Notes) -> (prose.Alert, bool) {
	if nt.pr.mark < 0 || nt.pr.mark >= len(nt.pr.alerts) {
		return {}, false
	}
	return nt.pr.alerts[nt.pr.mark], true
}

// prose_select_at picks the mark under the caret, if any.
prose_select_at :: proc(nt: ^Notes) {
	if !nt.pr.on || len(nt.pr.alerts) == 0 {
		return
	}
	nt.pr.mark = prose.alert_at(nt.pr.alerts[:], doc_offset(nt, nt.cur))
}

// prose_goto moves to the next or previous issue and selects it.
prose_goto :: proc(ui: ^p.Ctx, nt: ^Notes, forward: bool) {
	if !nt.pr.on || !nt.pr.ready {
		return
	}
	if nt.pr.full_dirty {
		prose_force(nt)
	}
	if len(nt.pr.alerts) == 0 {
		note(nt, tfmt("No issues in this note from %s", prose_style_name(nt)))
		return
	}
	here := doc_offset(nt, nt.cur)
	want := -1
	if forward {
		for a, i in nt.pr.alerts {
			if a.from > here {
				want = i
				break
			}
		}
		if want < 0 {
			want = 0
		}
	} else {
		for i := len(nt.pr.alerts) - 1; i >= 0; i -= 1 {
			if nt.pr.alerts[i].from < here {
				want = i
				break
			}
		}
		if want < 0 {
			want = len(nt.pr.alerts) - 1
		}
	}
	nt.pr.mark = want
	a := nt.pr.alerts[want]
	nt.cur = doc_pos(nt, a.from)
	ed_clear_sel(nt)
	nt.pane = .Editor
	nt.preview = false
	ed_visible(ui, nt)
	nt.goal_x = caret_x(&nt.wrap, ui, &nt.buf, nt.cur)
}

// ---------------------------------------------------------------------------
// Accepting a suggestion
// ---------------------------------------------------------------------------

// prose_apply takes the selected suggestion through `buf_apply`, which is the
// editor's own edit path — so it lands on the undo stack and Ctrl-Z puts it
// back. It does not write to the lines directly, and there is an assertion in
// the selftest that says so.
prose_apply :: proc(ui: ^p.Ctx, nt: ^Notes) {
	a, ok := prose_mark(nt)
	if !ok {
		note(nt, "No issue selected — F8 finds the next one")
		return
	}
	if !a.has_fix {
		note(nt, tfmt("%s has no automatic rewrite", a.rule))
		return
	}
	from := doc_pos(nt, a.from)
	to := doc_pos(nt, a.to)
	text := a.fix

	// A rule whose suggestion is "delete this" leaves two spaces behind, so
	// one of them goes with the phrase.
	if text == "" {
		src := buf_line(&nt.buf, to.line)
		if to.col < len(src) && src[to.col] == ' ' && from.col > 0 {
			before := buf_line(&nt.buf, from.line)
			if from.col <= len(before) && from.col > 0 && before[from.col - 1] == ' ' {
				to.col += 1
			}
		}
	}

	was := a.match
	nt.cur = buf_apply(&nt.buf, from, to, text, nt.cur, .No)
	ed_clear_sel(nt)
	touch(ui, nt)
	prose_touch(ui, nt, from.line)
	// The alert list is stale the moment the text moves; drop the selection
	// rather than leave it pointing at bytes that have shifted.
	nt.pr.mark = -1
	if text == "" {
		note(nt, tfmt("Removed \"%s\"", was))
	} else {
		note(nt, tfmt("\"%s\" → \"%s\"", was, text))
	}
}

// ---------------------------------------------------------------------------
// Dismissing
// ---------------------------------------------------------------------------

@(private = "file")
has_rule :: proc(list: [dynamic]string, name: string) -> bool {
	for s in list {
		if s == name {
			return true
		}
	}
	return false
}

prose_dismiss :: proc(ui: ^p.Ctx, nt: ^Notes, forever: bool) {
	a, ok := prose_mark(nt)
	if !ok {
		note(nt, "No issue selected")
		return
	}
	list := forever ? &nt.pr.dismissed : &nt.pr.note_dismissed
	if !has_rule(list^, a.rule) {
		append(list, strings.clone(a.rule))
	}
	prose_conf_save(nt)
	prose_invalidate(ui, nt)
	prose_force(nt)
	note(nt, forever ? tfmt("%s off everywhere", a.rule) : tfmt("%s off in this note", a.rule))
}

prose_undismiss_all :: proc(ui: ^p.Ctx, nt: ^Notes) {
	n := len(nt.pr.dismissed) + len(nt.pr.note_dismissed)
	for s in nt.pr.dismissed {
		delete(s)
	}
	clear(&nt.pr.dismissed)
	for s in nt.pr.note_dismissed {
		delete(s)
	}
	clear(&nt.pr.note_dismissed)
	prose_conf_save(nt)
	prose_invalidate(ui, nt)
	prose_force(nt)
	note(nt, n == 0 ? "Nothing was dismissed" : tfmt("%d rule(s) back on", n))
}

// ---------------------------------------------------------------------------
// Style
// ---------------------------------------------------------------------------

prose_set_style :: proc(ui: ^p.Ctx, nt: ^Notes, idx: int, for_note: bool) {
	if !nt.pr.ready {
		return
	}
	nt.pr.style = clamp(idx, 0, len(nt.pr.eng.packs) - 1)
	nt.pr.on = true
	if for_note {
		prose_conf_set_note_style(nt, prose_style_name(nt))
	} else {
		prose_conf_clear_note_style(nt)
	}
	prose_conf_save(nt)
	prose_invalidate(ui, nt)
	prose_force(nt)
	note(
		nt,
		for_note \
		? tfmt("%s for this note", prose_style_name(nt)) \
		: tfmt("%s everywhere", prose_style_name(nt)),
	)
}

prose_toggle :: proc(ui: ^p.Ctx, nt: ^Notes) {
	nt.pr.on = !nt.pr.on
	if nt.pr.on {
		prose_invalidate(ui, nt)
		prose_force(nt)
		note(nt, tfmt("Writing checks on — %s", prose_style_name(nt)))
	} else {
		prose_clear(nt)
		nt.pr.show_report = false
		note(nt, "Writing checks off")
	}
	prose_conf_save(nt)
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------
//
// One file beside the notes, in the same directory, in a format `cat` reads:
//
//   on 1
//   style Plain
//   dismiss Plain.Hedging
//   note-style welcome-to-notes.md Business
//   note-dismiss welcome-to-notes.md Plain.Passive
//
// Nothing outside the note directory is read or written, and the per-note keys
// are file names within it — never paths.

PROSE_CONF :: "prose.conf"

@(private = "file")
conf_path :: proc(nt: ^Notes) -> string {
	return tfmt("%s/%s", nt.dir, PROSE_CONF)
}

prose_note_key :: proc(nt: ^Notes) -> string {
	return base_of(nt.open_path)
}

prose_conf_load :: proc(nt: ^Notes) {
	data, err := os.read_entire_file_from_path(conf_path(nt), context.temp_allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if t == "" || t[0] == '#' {
			continue
		}
		key, _, val := strings.partition(t, " ")
		val = strings.trim_space(val)
		switch key {
		case "on":
			nt.pr.on = val != "0"
		case "style":
			if i := prose.pack_index(&nt.pr.eng, val); i >= 0 {
				nt.pr.style = i
				nt.pr.global_style = i
			}
		case "dismiss":
			if val != "" {
				append(&nt.pr.dismissed, strings.clone(val))
			}
		}
	}
}

// prose_conf_apply_note is called when a note is opened: it picks up that
// note's own style and dismissals.
prose_conf_apply_note :: proc(nt: ^Notes) {
	for s in nt.pr.note_dismissed {
		delete(s)
	}
	clear(&nt.pr.note_dismissed)
	// A note with no style of its own gets the global one back. Without this
	// reset, opening a note after one that had an override would silently
	// inherit it.
	delete(nt.pr.note_style)
	nt.pr.note_style = ""
	nt.pr.style = nt.pr.global_style
	if nt.open_path == "" {
		return
	}
	key := prose_note_key(nt)
	data, err := os.read_entire_file_from_path(conf_path(nt), context.temp_allocator)
	if err != nil {
		return
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		k, _, r := strings.partition(t, " ")
		name, _, val := strings.partition(strings.trim_space(r), " ")
		val = strings.trim_space(val)
		if name != key {
			continue
		}
		switch k {
		case "note-style":
			if i := prose.pack_index(&nt.pr.eng, val); i >= 0 {
				nt.pr.style = i
				nt.pr.note_style = strings.clone(val)
			}
		case "note-dismiss":
			if val != "" {
				append(&nt.pr.note_dismissed, strings.clone(val))
			}
		}
	}
}

prose_conf_set_note_style :: proc(nt: ^Notes, style: string) {
	delete(nt.pr.note_style)
	nt.pr.note_style = strings.clone(style)
}

prose_conf_clear_note_style :: proc(nt: ^Notes) {
	delete(nt.pr.note_style)
	nt.pr.note_style = ""
	nt.pr.global_style = nt.pr.style
}

prose_conf_save :: proc(nt: ^Notes) {
	if nt.dir == "" {
		return
	}
	// Read the existing file so another note's settings are not lost.
	keep := make([dynamic]string, 0, 16, context.temp_allocator)
	key := prose_note_key(nt)
	if data, err := os.read_entire_file_from_path(conf_path(nt), context.temp_allocator); err == nil {
		rest := string(data)
		for line in strings.split_lines_iterator(&rest) {
			t := strings.trim_space(line)
			if t == "" || t[0] == '#' {
				continue
			}
			k, _, r := strings.partition(t, " ")
			switch k {
			case "on", "style", "dismiss":
				continue // rewritten below
			case "note-style", "note-dismiss":
				name, _, _ := strings.partition(strings.trim_space(r), " ")
				if name == key {
					continue // rewritten below
				}
			}
			append(&keep, t)
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "# apps/notes writing settings. Safe to edit or delete.\n")
	strings.write_string(&sb, tfmt("on %s\n", nt.pr.on ? "1" : "0"))
	strings.write_string(
		&sb,
		tfmt("style %s\n", nt.pr.eng.packs[clamp(nt.pr.global_style, 0, len(nt.pr.eng.packs) - 1)].name),
	)
	for s in nt.pr.dismissed {
		strings.write_string(&sb, tfmt("dismiss %s\n", s))
	}
	if key != "" && nt.pr.note_style != "" {
		strings.write_string(&sb, tfmt("note-style %s %s\n", key, nt.pr.note_style))
	}
	if key != "" {
		for s in nt.pr.note_dismissed {
			strings.write_string(&sb, tfmt("note-dismiss %s %s\n", key, s))
		}
	}
	for s in keep {
		strings.write_string(&sb, s)
		strings.write_byte(&sb, '\n')
	}
	if werr := os.write_entire_file(conf_path(nt), transmute([]u8)strings.to_string(sb)); werr != nil {
		// Losing a preference is not worth a dialog; the note is what matters.
		note(nt, "Could not save the writing settings")
	}
}
