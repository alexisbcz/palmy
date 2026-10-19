package main

// The writing coach, drawn.
//
// Four surfaces, in the order they matter:
//
//   the marks        an underline under the words a rule fired on, coloured by
//                    severity and nothing else. No background fill, no box, no
//                    squiggle on every third word: prose has to stay readable
//                    while it is being written, so the mark is two pixels at
//                    the baseline and the only one that gets a wash is the one
//                    selected.
//   the explanation  a strip under the editor saying which rule fired, *why it
//                    matters*, and the rewrite it offers. "Avoid 'utilize'" is
//                    not worth a panel; "'utilize' → 'use'" is.
//   the report       a column on the right: readability with a plain-English
//                    band beside every number and the caveat at the bottom,
//                    the sentence-length shape, and — the part that actually
//                    changes how somebody writes — what they do repeatedly.
//   the picker       six packs, each with a sentence saying what it is *for*,
//                    switchable for this note or for everything.

import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."
import prose "../prose"

SEV_ERROR :: 0xdc2626
SEV_WARNING :: 0xd97706
SEV_SUGGESTION :: 0x6366f1

prose_register_colors :: proc() {
	p.register_color("sev-error", p.hex(SEV_ERROR))
	p.register_color("sev-warning", p.hex(SEV_WARNING))
	p.register_color("sev-suggestion", p.hex(SEV_SUGGESTION))
}

sev_color :: proc(s: prose.Severity) -> string {
	switch s {
	case .Error:
		return "sev-error"
	case .Warning:
		return "sev-warning"
	case .Suggestion:
		return "sev-suggestion"
	}
	return "sev-suggestion"
}

sev_icon :: proc(s: prose.Severity) -> p.Icon {
	switch s {
	case .Error:
		return ICON_CIRCLE_ALERT
	case .Warning:
		return ICON_TRIANGLE_ALERT
	case .Suggestion:
		return ICON_SPARKLES
	}
	return ICON_INFO
}

// ---------------------------------------------------------------------------
// Marks
// ---------------------------------------------------------------------------

// prose_marks_for_row draws the underlines on one visual row. It is called
// from inside the row node in `writing_pane`, where the row's own origin is
// the coordinate system.
prose_marks_for_row :: proc(ui: ^p.Ctx, nt: ^Notes, r: Vis, line_off: int) {
	if !nt.pr.on || len(nt.pr.alerts) == 0 {
		return
	}
	row_from := line_off + r.from
	row_to := line_off + r.to

	for a, i in nt.pr.alerts {
		if a.to <= row_from || a.from >= row_to {
			continue
		}
		// An alert can start on an earlier line (a repetition across a line
		// break), so both ends are clamped into this row.
		lo := clamp(a.from - line_off, r.from, r.to)
		hi := clamp(a.to - line_off, r.from, r.to)
		// "This sentence runs to 35 words" is not a complaint about the word
		// the alert happens to sit on, so an occurrence rule marks the whole
		// scope it judged — lightly, because a full sentence underlined as
		// heavily as one bad word would shout.
		if a.kind == .Occurrence {
			lo = clamp(a.scope_from - line_off, r.from, r.to)
			hi = clamp(a.scope_to - line_off, r.from, r.to)
		}
		if hi <= lo {
			continue
		}
		x0 := row_x(&nt.wrap, ui, &nt.buf, r, lo)
		x1 := row_x(&nt.wrap, ui, &nt.buf, r, hi)
		on := i == nt.pr.mark
		mark_band(ui, x0, max(4, x1 - x0), a.sev, on, a.kind == .Occurrence, r.h)
	}
}

@(private = "file")
mark_band :: proc(ui: ^p.Ctx, x, w: f32, sev: prose.Severity, selected: bool, faint := false, h: f32 = BODY_LH) {
	col := sev_color(sev)
	if selected {
		// The selected mark gets a wash as well as the rule, because a panel
		// that explains "this" has to say which "this".
		bg := p.div(ui, tfmt("absolute rounded-[2] bg-%s/18", col))
		bs := p.style(ui, bg)
		bs.inset[p.LEFT] = p.px(x - 1)
		bs.inset[p.TOP] = p.px(1)
		bs.w = p.px(w + 2)
		bs.h = p.px(h - 2)
		bs.no_hit = true
		p.end(ui)
	}
	line := p.div(ui, tfmt("absolute rounded-full bg-%s%s", col, faint && !selected ? "/45" : ""))
	ls := p.style(ui, line)
	ls.inset[p.LEFT] = p.px(x)
	ls.inset[p.TOP] = p.px(h - (faint ? 3 : 5))
	ls.w = p.px(w)
	ls.h = p.px(selected ? 2.5 : (faint ? 1.5 : 2))
	ls.no_hit = true
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The header control
// ---------------------------------------------------------------------------

prose_header_button :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pr.ready {
		return
	}
	p.key(ui, "prose-style")
	idx := p.row(
		ui,
		"h-7 shrink-0 items-center gap-1.5 px-2 rounded-md border border-border bg-background hover:bg-accent transition cursor-pointer",
	)
	if p.clickable(ui, idx) {
		nt.mode = .Styles
		nt.pr.pick_sel = nt.pr.style
		nt.swallow = true
	}
	if nt.pr.on {
		p.icon(ui, ICON_SPARKLES, tfmt("size-3.5 shrink-0 text-%s", sev_color(.Suggestion)))
	} else {
		p.icon(ui, ICON_EYE_OFF, "size-3.5 shrink-0 text-muted-foreground")
	}
	p.text(
		ui,
		nt.pr.on ? prose_style_name(nt) : "Checks off",
		"text-[12] font-medium whitespace-nowrap",
	)
	p.style(ui).shrink = 0

	if nt.pr.on && len(nt.pr.alerts) > 0 {
		worst := prose.Severity.Suggestion
		for a in nt.pr.alerts {
			if a.sev > worst {
				worst = a.sev
			}
		}
		chip := p.row(ui, tfmt("shrink-0 h-[16] px-1.5 rounded-full items-center bg-%s", sev_color(worst)))
		_ = chip
		p.textf(ui, "text-[10] font-semibold text-white whitespace-nowrap", "%d", len(nt.pr.alerts))
		p.end(ui)
	}
	p.icon(ui, ICON_CHEVRON_DOWN, "size-3 shrink-0 text-muted-foreground")
	p.end(ui)
}

prose_report_button :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pr.ready {
		return
	}
	p.key(ui, "prose-report")
	idx := p.div(
		ui,
		"flex-row h-7 w-7 shrink-0 items-center justify-center rounded-md border border-border transition cursor-pointer",
	)
	p.apply(
		ui,
		nt.pr.show_report ? "bg-accent-blue border-accent-blue" : "bg-background hover:bg-accent",
		idx,
	)
	if p.clickable(ui, idx) {
		prose_show_report(nt, !nt.pr.show_report)
	}
	p.icon(
		ui,
		ICON_SIGMA,
		nt.pr.show_report ? "size-3.5 text-white" : "size-3.5 text-muted-foreground",
	)
	p.end(ui)
}

prose_show_report :: proc(nt: ^Notes, on: bool) {
	nt.pr.show_report = on
	if on {
		nt.pr.on = true
		prose_force(nt)
	}
}

// ---------------------------------------------------------------------------
// The explanation strip
// ---------------------------------------------------------------------------

prose_explain_strip :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pr.on || nt.preview {
		return
	}
	a, ok := prose_mark(nt)
	if !ok {
		prose_hint_strip(ui, nt)
		return
	}
	col := sev_color(a.sev)

	p.col(ui, "w-full shrink-0 border-t border-border bg-muted/40 px-6 py-3 gap-2")
	defer p.end(ui)

	// What fired, and how loudly.
	p.row(ui, "w-full items-center gap-2 shrink-0")
	p.icon(ui, sev_icon(a.sev), tfmt("size-4 shrink-0 text-%s", col))
	p.text(ui, a.message, "flex-1 min-w-0 text-[13] font-medium text-foreground")
	p.row(ui, tfmt("shrink-0 h-[18] px-2 rounded-full items-center bg-%s/15", col))
	p.text(ui, a.rule, tfmt("text-[10.5] font-semibold whitespace-nowrap text-%s", col))
	p.end(ui)
	p.end(ui)

	// Why it matters. This is the whole point of the panel.
	if a.why != "" {
		p.text(
			ui,
			one_line(a.why),
			"w-full text-[12] leading-[18] text-muted-foreground",
		)
	}

	// The rewrite, where the rule type can produce one.
	p.row(ui, "w-full items-center gap-2 shrink-0 pt-0.5 flex-wrap")
	if a.has_fix {
		chip(ui, a.match, "line-through text-muted-foreground")
		p.icon(ui, ICON_ARROW_RIGHT, "size-3.5 shrink-0 text-muted-foreground")
		chip(ui, a.fix == "" ? "(nothing)" : a.fix, tfmt("font-semibold text-%s", col))
		p.row(ui, "items-center gap-1.5 shrink-0 pl-1")
		sc.kbd(ui, "Ctrl .")
		p.text(ui, "accept", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	} else {
		p.text(
			ui,
			"No mechanical rewrite for this one — it needs a decision.",
			"flex-1 min-w-0 text-[11.5] text-muted-foreground",
		)
	}
	p.spacer(ui, "flex-1")
	hint(ui, "F8", "next")
	hint(ui, "Ctrl D", "not here")
	hint(ui, "Ctrl Shift D", "never")
	p.end(ui)
}

@(private = "file")
chip :: proc(ui: ^p.Ctx, text, class: string) {
	p.row(ui, "shrink-0 px-2 py-0.5 rounded-md bg-background border border-border items-center")
	p.text(ui, text, tfmt("text-[12] whitespace-nowrap %s", class))
	p.end(ui)
}

// one_line collapses a block scalar's newlines, because the rule files write
// `description` as wrapped prose and the panel does its own wrapping.
one_line :: proc(s: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	space := false
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '\n' || c == '\r' || c == '\t' || c == ' ' {
			space = true
			continue
		}
		if space && strings.builder_len(sb) > 0 {
			strings.write_byte(&sb, ' ')
		}
		space = false
		strings.write_byte(&sb, c)
	}
	return strings.to_string(sb)
}

// prose_hint_strip is what sits there when nothing is selected: the count, and
// the two keys that do something about it.
@(private = "file")
prose_hint_strip :: proc(ui: ^p.Ctx, nt: ^Notes) {
	n := len(nt.pr.alerts)
	p.row(ui, "h-[34] w-full shrink-0 items-center gap-2 border-t border-border bg-muted/30 px-6")
	defer p.end(ui)

	if nt.pr.dirty || nt.pr.full_dirty {
		p.icon(ui, ICON_CLOCK, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, "reading…", "text-[11.5] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
	} else if n == 0 {
		p.icon(ui, ICON_CIRCLE_CHECK, "size-3.5 shrink-0 text-emerald-600")
		p.textf(
			ui,
			"text-[11.5] text-muted-foreground whitespace-nowrap",
			"Nothing flagged by %s",
			prose_style_name(nt),
		)
		p.style(ui).shrink = 0
	} else {
		errs, warns, sugs := 0, 0, 0
		for a in nt.pr.alerts {
			switch a.sev {
			case .Error:
				errs += 1
			case .Warning:
				warns += 1
			case .Suggestion:
				sugs += 1
			}
		}
		for pair in ([?]struct {
			n:   int,
			sev: prose.Severity,
		}{{errs, .Error}, {warns, .Warning}, {sugs, .Suggestion}}) {
			if pair.n == 0 {
				continue
			}
			p.row(ui, "shrink-0 items-center gap-1.5")
			p.div(ui, tfmt("size-2 rounded-full shrink-0 bg-%s", sev_color(pair.sev)))
			p.end(ui)
			p.textf(
				ui,
				"text-[11.5] text-muted-foreground whitespace-nowrap shrink-0",
				"%d %s",
				pair.n,
				prose.SEVERITY_NAME[pair.sev],
			)
			p.end(ui)
		}
	}
	p.spacer(ui, "flex-1")
	hint(ui, "F8", "next issue")
	hint(ui, "F6", "report")
	hint(ui, "F7", "style")
}

// ---------------------------------------------------------------------------
// The writing report
// ---------------------------------------------------------------------------

PROSE_PANEL_W :: 318

prose_report_panel :: proc(ui: ^p.Ctx, nt: ^Notes) {
	if !nt.pr.show_report || !nt.pr.ready {
		return
	}
	rp := &nt.pr.report
	p.col(
		ui,
		tfmt(
			"w-[%d] shrink-0 h-full bg-sidebar border-l border-border overflow-scroll px-4 py-3 gap-3",
			PROSE_PANEL_W,
		),
	)
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2 shrink-0")
	p.icon(ui, ICON_SIGMA, "size-4 shrink-0 text-muted-foreground")
	p.text(ui, "Writing report", "flex-1 min-w-0 text-[13.5] font-semibold")
	sc.kbd(ui, "F6")
	p.end(ui)

	if !nt.pr.have_report {
		p.text(ui, "Reading the note…", "w-full text-[11.5] text-muted-foreground")
		return
	}

	// --- the shape of the note -------------------------------------------
	p.row(ui, "w-full gap-2 shrink-0")
	stat(ui, tfmt("%d", rp.words), "words")
	stat(ui, tfmt("%d", rp.sentences), "sentences")
	stat(
		ui,
		rp.words == 0 ? "—" : (rp.minutes < 1 ? "<1" : tfmt("%d", int(rp.minutes + 0.5))),
		"min to read",
	)
	p.end(ui)

	// --- readability ------------------------------------------------------
	section(ui, "READABILITY, ROUGHLY")
	if rp.grade_ok {
		p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5 rounded-lg bg-background border border-border")
		p.row(ui, "w-full items-end gap-2")
		p.text(
			ui,
			tfmt("%.0f", rp.grade_mean),
			tfmt("shrink-0 text-[26] leading-[28] font-semibold text-%s", grade_color(rp.grade_mean)),
		)
		p.col(ui, "flex-1 min-w-0 gap-0 pb-0.5")
		p.text(ui, "US grade, about", "w-full text-[10] text-muted-foreground")
		p.text(ui, prose.band(rp.grade_mean), "w-full text-[11] font-medium text-foreground")
		p.end(ui)
		p.end(ui)
		// The spread is computed, not asserted. Saying "they disagree by two
		// grades" when on this note they disagree by five would be exactly
		// the false precision the caveat warns about.
		lo, hi := f64(1e9), f64(-1e9)
		n := 0
		for g in rp.grades {
			if !g.ok || g.metric == .Flesch_Reading_Ease {
				continue
			}
			lo = min(lo, g.value)
			hi = max(hi, g.value)
			n += 1
		}
		p.text(
			ui,
			n > 1 \
			? tfmt("The mean of %d formulas, which disagree with each other by %.1f grades here.", n, hi - lo) \
			: "From one formula, which is a single rough estimate.",
			"w-full text-[10.5] leading-[15] text-muted-foreground",
		)
		p.end(ui)
	} else {
		p.text(
			ui,
			"Too little text for a grade to mean anything.",
			"w-full text-[11.5] text-muted-foreground",
		)
	}

	// --- what recurs ------------------------------------------------------
	section(ui, "WHAT YOU DO REPEATEDLY")
	if len(rp.issues) == 0 {
		p.text(
			ui,
			tfmt("Nothing recurs. %s found no issues here.", prose_style_name(nt)),
			"w-full text-[11.5] text-muted-foreground",
		)
	}
	for t, i in rp.issues {
		p.key(ui, t.rule)
		row := p.row(ui, "w-full shrink-0 items-center gap-2 px-2 py-1.5 rounded-md hover:bg-accent cursor-pointer")
		if p.clickable(ui, row) {
			nt.pr.mark = prose.alert_at(nt.pr.alerts[:], t.first)
			nt.cur = doc_pos(nt, t.first)
			ed_clear_sel(nt)
			nt.pane = .Editor
		}
		p.div(ui, tfmt("size-2 rounded-full shrink-0 bg-%s", sev_color(t.sev)))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, short_rule(t.rule), "w-full truncate text-[11.5] font-medium text-foreground")
		if t.fix {
			p.text(ui, "a rewrite is offered", "w-full text-[10] text-muted-foreground")
		}
		p.end(ui)
		p.textf(
			ui,
			"shrink-0 text-[12] font-semibold text-muted-foreground",
			"%d",
			t.n,
		)
		p.end(ui)
		_ = i
	}

	// --- sentence shape ---------------------------------------------------
	section(ui, "SENTENCE LENGTH")
	p.text(
		ui,
		tfmt(
			"shortest %d, median %d, longest %d words",
			rp.len_min,
			rp.len_median,
			rp.len_max,
		),
		"w-full text-[11] text-muted-foreground",
	)
	maxn := 1
	for n in rp.buckets {
		maxn = max(maxn, n)
	}
	for n, i in rp.buckets {
		p.row(ui, "w-full items-center gap-2 shrink-0 h-[16]")
		p.text(
			ui,
			prose.BUCKET_LABEL[i],
			"w-[34] shrink-0 text-right text-[10] text-muted-foreground",
		)
		track := p.div(ui, "flex-1 min-w-0 h-[8] rounded-full bg-muted overflow-hidden flex-row")
		_ = track
		if n > 0 {
			bar := p.div(ui, tfmt("h-[8] rounded-full bg-%s", i >= 4 ? "sev-warning" : "accent-blue"))
			p.style(ui, bar).w = p.pct(f32(n) / f32(maxn) * 100)
			p.end(ui)
		}
		p.end(ui)
		p.textf(ui, "w-[18] shrink-0 text-[10] text-muted-foreground", "%d", n)
		p.end(ui)
	}
	p.text(
		ui,
		tfmt("Variation: %.1f words either side — %s", rp.len_sd, prose.variance_note(rp)),
		"w-full text-[10.5] leading-[15] text-muted-foreground",
	)

	// --- repeated openers -------------------------------------------------
	if len(rp.openers) > 0 {
		section(ui, "SENTENCES THAT START ALIKE")
		for o in rp.openers {
			p.row(ui, "w-full items-center gap-2 shrink-0")
			p.text(ui, o.word, "flex-1 min-w-0 truncate text-[11.5] font-medium text-foreground")
			p.textf(
				ui,
				"shrink-0 text-[11] text-muted-foreground whitespace-nowrap",
				"%d times",
				o.n,
			)
			p.end(ui)
		}
	}

	// --- the formulas, one by one -----------------------------------------
	section(ui, "EACH FORMULA SEPARATELY")
	for g in rp.grades {
		p.row(ui, "w-full items-center gap-2 shrink-0")
		p.text(
			ui,
			prose.METRIC_NAME[g.metric],
			"flex-1 min-w-0 truncate text-[11] text-muted-foreground",
		)
		if g.ok {
			p.text(
				ui,
				tfmt("%.1f", g.value),
				"shrink-0 w-[34] text-right text-[11] font-medium text-foreground",
			)
		} else {
			p.text(ui, "—", "shrink-0 w-[34] text-right text-[11] text-muted-foreground/60")
		}
		p.end(ui)
	}

	// --- the caveat, which is not optional --------------------------------
	p.div(ui, "w-full h-px my-1 shrink-0 bg-border")
	p.end(ui)
	p.row(ui, "w-full items-start gap-2 shrink-0 pb-2")
	p.icon(ui, ICON_INFO, "size-3.5 shrink-0 mt-px text-muted-foreground")
	p.text(ui, rp.caveat, "flex-1 min-w-0 text-[10.5] leading-[15] text-muted-foreground")
	p.end(ui)
}

@(private = "file")
grade_color :: proc(g: f64) -> string {
	switch {
	case g < 9:
		return "emerald-600"
	case g < 13:
		return "foreground"
	case g < 17:
		return "sev-warning"
	}
	return "sev-error"
}

@(private = "file")
short_rule :: proc(name: string) -> string {
	if i := strings.index_byte(name, '.'); i >= 0 {
		return name[i + 1:]
	}
	return name
}

@(private = "file")
section :: proc(ui: ^p.Ctx, title: string) {
	p.text(
		ui,
		title,
		"w-full shrink-0 pt-2 text-[9.5] font-semibold tracking-wide text-muted-foreground/70",
	)
}

@(private = "file")
stat :: proc(ui: ^p.Ctx, big, label: string) {
	p.col(ui, "flex-1 min-w-0 gap-0 px-2 py-1.5 rounded-lg bg-background border border-border")
	p.text(ui, big, "w-full text-[15] font-semibold text-foreground")
	p.text(ui, label, "w-full truncate text-[9.5] text-muted-foreground")
	p.end(ui)
}

// ---------------------------------------------------------------------------
// The style picker
// ---------------------------------------------------------------------------

prose_styles_sheet :: proc(ui: ^p.Ctx, nt: ^Notes) {
	scrim(ui, nt)
	win := p.size(ui)
	sheet_open(ui, 600, max(8, (win.y - 560) / 2))
	defer sheet_close(ui)

	p.row(ui, "w-full items-center gap-2.5 px-5 pt-5 pb-1")
	p.icon(ui, ICON_SPARKLES, "size-4 shrink-0 text-muted-foreground")
	p.col(ui, "gap-0.5 min-w-0 flex-1")
	p.text(ui, "Pick a writing style", "text-[15] font-semibold")
	p.text(
		ui,
		"Each pack flags different things. The same paragraph looks different under two of them.",
		"text-[11.5] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.col(ui, "w-full px-4 py-3 gap-1.5")
	for pk, i in nt.pr.eng.packs {
		on := i == nt.pr.pick_sel
		active := i == nt.pr.style && nt.pr.on
		p.key(ui, pk.name)
		idx := p.col(ui, "w-full shrink-0 gap-1 px-3 py-2.5 rounded-lg border transition cursor-pointer")
		switch {
		case on:
			p.apply(ui, "bg-accent border-ring ring-3 ring-ring/30", idx)
		case:
			p.apply(ui, "bg-background border-border hover:bg-accent/60", idx)
		}
		if p.clickable(ui, idx) {
			nt.pr.pick_sel = i
			prose_set_style(ui, nt, i, false)
			nt.mode = .Normal
		}

		p.row(ui, "w-full items-center gap-2")
		p.text(ui, pk.name, "shrink-0 text-[13] font-semibold text-foreground")
		if active {
			p.row(ui, "shrink-0 h-[16] px-1.5 rounded-full items-center bg-accent-blue")
			p.text(ui, "in use", "text-[9.5] font-semibold text-white whitespace-nowrap")
			p.end(ui)
		}
		p.spacer(ui, "flex-1")
		p.textf(
			ui,
			"shrink-0 text-[10.5] text-muted-foreground whitespace-nowrap",
			"%d rules",
			len(pk.rules),
		)
		p.end(ui)

		p.text(ui, pk.about, "w-full text-[11.5] leading-[16] text-muted-foreground")
		p.end(ui)
	}

	// Off is a first-class choice, not a hidden setting.
	p.key(ui, "prose-off")
	off := p.row(ui, "w-full shrink-0 items-center gap-2 px-3 py-2 rounded-lg border border-border bg-background hover:bg-accent/60 transition cursor-pointer mt-1")
	if p.clickable(ui, off) {
		nt.pr.on = false
		prose_clear(nt)
		nt.pr.show_report = false
		prose_conf_save(nt)
		nt.mode = .Normal
		note(nt, "Writing checks off")
	}
	p.icon(ui, ICON_EYE_OFF, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "No checks", "shrink-0 text-[12.5] font-medium")
	p.text(
		ui,
		"Write without anything looking over your shoulder.",
		"flex-1 min-w-0 text-[11] text-muted-foreground",
	)
	p.end(ui)
	p.end(ui)

	p.row(ui, "h-[40] w-full shrink-0 items-center gap-3 px-5 border-t border-border bg-muted/40")
	p.text(
		ui,
		tfmt("%d rule(s) dismissed", len(nt.pr.dismissed) + len(nt.pr.note_dismissed)),
		"text-[11] text-muted-foreground whitespace-nowrap shrink-0",
	)
	p.spacer(ui, "flex-1")
	hint(ui, "Enter", "everywhere")
	hint(ui, "N", "this note")
	hint(ui, "R", "restore dismissed")
	hint(ui, "Esc", "cancel")
	p.end(ui)
}

_ :: math
