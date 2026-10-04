package main

// The interface.
//
// Three panes: what is being converted and how, the document that came out,
// and — when the remote backend is selected — a consent overlay that has to be
// answered before anything happens.
//
// Keyboard first, throughout. The compositor these apps are developed against
// cannot synthesise pointer clicks, so every operation has a key. That turned
// out to be the better interface anyway for work that is "open it, look at the
// result, change one setting, do it again".
//
// There is no `xdg_popup` in palmy, so the consent dialog is an absolutely
// positioned overlay inside the window with a `z-` class, drawn over a scrim.
// That is a constraint of the toolkit and not a design choice, but for a
// modal question it is the right shape regardless: it cannot be dismissed by
// clicking somewhere else, because there is nowhere else.

import "core:fmt"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

build :: proc(ui: ^p.Ctx, m: ^App) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	header(ui, m)
	p.row(ui, "flex-1 w-full overflow-hidden")
	{
		sidebar(ui, m)
		document_pane(ui, m)
	}
	p.end(ui)
	footer(ui, m)

	if m.asking {
		consent_overlay(ui, m)
	}
	if m.help {
		help_overlay(ui, m)
	}
	pick_overlay(ui, m)
}

// ---------------------------------------------------------------------------

@(private = "file")
header :: proc(ui: ^p.Ctx, m: ^App) {
	p.row(ui, "w-full h-14 shrink-0 items-center gap-3 px-4 border-b border-border bg-card")
	defer p.end(ui)

	p.icon(ui, sc.ICON_FILE_TEXT, "size-5 text-muted-foreground")
	p.col(ui, "flex-1 gap-0.5 overflow-hidden")
	{
		if m.src == "" {
			p.text(ui, "No document", "text-sm font-semibold")
			p.text(ui, "press o to open a scan or a PDF", "text-xs text-muted-foreground")
		} else {
			p.text(ui, base_name(m.src), "text-sm font-semibold truncate")
			p.textf(
				ui,
				"text-xs text-muted-foreground truncate",
				"%s · %s%s",
				m.kind == .Pdf ? "PDF" : "image",
				human_bytes(m.src_bytes, context.temp_allocator),
				m.src_pages > 1 ? fmt.tprintf(" · %d pages", m.src_pages) : "",
			)
		}
	}
	p.end(ui)

	// The backend badge is the most important thing on this bar: it says
	// whether the next conversion stays on this machine.
	if m.backend == .Tesseract {
		sc.badge(ui, "local · offline", .Secondary)
	} else if m.consent.granted {
		sc.badge(ui, "remote · uploading", .Destructive)
	} else {
		sc.badge(ui, "remote · not consented", .Outline)
	}

	for v in View {
		cls := m.view == v ? "shrink-0 px-3 py-1.5 rounded-md text-xs font-medium whitespace-nowrap bg-accent" : "shrink-0 px-3 py-1.5 rounded-md text-xs whitespace-nowrap text-muted-foreground hover:bg-accent/60 transition"
		p.div(ui, cls)
		if p.clickable(ui) {
			m.view = v
		}
		p.textf(ui, "whitespace-nowrap", "%d %s", int(v) + 1, view_name(v))
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------

@(private = "file")
sidebar :: proc(ui: ^p.Ctx, m: ^App) {
	p.col(ui, "w-[300] shrink-0 h-full border-r border-border bg-card/40 overflow-hidden")
	defer p.end(ui)

	p.col(ui, "flex-1 gap-2 px-4 py-3 overflow-scroll")
	{
		field(ui, "Recogniser", "b")
		row_choice(ui, "tesseract, on this machine", m.backend == .Tesseract, m.tools.tesseract)
		row_choice(ui, "Mistral OCR, a hosted service", m.backend == .Mistral, m.key.source != .None)
		if m.backend == .Mistral {
			p.text(
				ui,
				m.consent.granted ? "You consented to upload this document." : "Nothing will be sent until you confirm.",
				m.consent.granted ? "text-xs text-destructive" : "text-xs text-muted-foreground",
			)
		}
		if m.key.source == .None {
			p.text(ui, "No API key, so the remote backend cannot run.", "text-xs text-muted-foreground")
		}

		sc.separator(ui)

		field(ui, "Language", "l")
		p.text(
			ui,
			m.lang_i < len(m.langs) ? m.langs[m.lang_i] : "eng",
			"text-sm font-mono",
		)

		field(ui, "Rasterise at", "d")
		p.textf(ui, "text-sm font-mono", "%d dpi", m.dpi)

		field(ui, "Text layer", "f")
		p.text(
			ui,
			m.force_ocr ? "OCR even when one is present" : "use it and skip OCR",
			"text-sm",
		)
		if m.force_ocr {
			p.text(ui, "A text layer is exact. OCRing it is strictly worse.", "text-xs text-destructive")
		}

		field(ui, "Segmentation", "s")
		p.text(
			ui,
			m.segment == .Auto ? "the engine finds the blocks" : "one block; we find the columns",
			"text-sm",
		)

		sc.separator(ui)

		if m.have_doc {
			field(ui, "Result", "")
			stat(ui, "pages", fmt.tprintf("%d", m.doc.pages))
			stat(ui, "words", fmt.tprintf("%d", m.doc.words))
			stat(ui, "blocks", fmt.tprintf("%d", len(m.doc.blocks)))
			stat(ui, "columns", fmt.tprintf("%d", max(1, m.stats.columns)))
			if m.stats.dropped > 0 {
				stat(ui, "furniture dropped", fmt.tprintf("%d lines", m.stats.dropped))
			}
			if m.stats.text_layer {
				stat(ui, "recognised", "not OCRed")
			} else {
				stat(ui, "OCR time", fmt.tprintf("%d ms", m.stats.ocr_ms))
			}
		}
	}
	p.end(ui)

	p.col(ui, "shrink-0 gap-1.5 p-3 border-t border-border")
	{
		action(ui, "o", "Open a file")
		action(ui, "c", job_busy() ? "Converting…" : "Convert")
		action(ui, "e", "Export EPUB")
		action(ui, "m", "Export Markdown")
		action(ui, "t", "Export plain text")
		action(ui, "?", "All keys")
	}
	p.end(ui)
}

@(private = "file")
field :: proc(ui: ^p.Ctx, label, key: string) {
	p.row(ui, "w-full items-center gap-2 mt-2")
	defer p.end(ui)
	p.text(ui, label, "text-xs font-semibold uppercase tracking-wide text-muted-foreground")
	p.spacer(ui)
	if key != "" {
		sc.kbd(ui, key)
	}
}

@(private = "file")
row_choice :: proc(ui: ^p.Ctx, label: string, on, available: bool) {
	p.row(ui, on ? "w-full items-center gap-2 px-2 py-1.5 rounded-md bg-accent" : "w-full items-center gap-2 px-2 py-1.5 rounded-md")
	defer p.end(ui)
	p.icon(
		ui,
		on ? sc.ICON_CIRCLE_CHECK : sc.ICON_CIRCLE_ALERT,
		on ? "size-4 text-primary" : "size-4 text-muted-foreground",
	)
	p.text(ui, label, available ? "text-sm" : "text-sm text-muted-foreground line-through")
}

@(private = "file")
stat :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full items-baseline gap-2")
	defer p.end(ui)
	p.text(ui, label, "text-xs text-muted-foreground")
	p.spacer(ui)
	p.text(ui, value, "text-xs font-mono tabular-nums")
}

@(private = "file")
action :: proc(ui: ^p.Ctx, key, label: string) {
	p.row(ui, "w-full items-center gap-2")
	defer p.end(ui)
	sc.kbd(ui, key)
	p.text(ui, label, "text-xs text-muted-foreground")
}

// ---------------------------------------------------------------------------

@(private = "file")
document_pane :: proc(ui: ^p.Ctx, m: ^App) {
	p.col(ui, "flex-1 h-full overflow-hidden")
	defer p.end(ui)

	if job_busy() {
		done, total := job_progress()
		p.col(ui, "w-full shrink-0 gap-2 px-6 py-3 border-b border-border")
		{
			p.row(ui, "w-full items-center gap-2")
			{
				p.text(ui, job_note(context.temp_allocator), "text-xs text-muted-foreground")
				p.spacer(ui)
				p.textf(ui, "text-xs font-mono tabular-nums text-muted-foreground", "%d/%d", done, total)
			}
			p.end(ui)
			p.progress(ui, total > 0 ? f32(done) / f32(total) : 0, "w-full h-1.5")
		}
		p.end(ui)
	}

	p.col(ui, "flex-1 w-full overflow-scroll px-10 py-8 gap-0")
	defer p.end(ui)

	switch m.view {
	case .Document:
		if !m.have_doc {
			empty_state(ui, m)
			return
		}
		p.col(ui, "w-full max-w-[720] mx-auto gap-0")
		defer p.end(ui)
		p.text(ui, m.doc.title, "text-2xl font-bold mb-1")
		p.textf(ui, "text-xs text-muted-foreground mb-6", "recognised by %s", m.doc.backend)
		for blk, i in m.doc.blocks {
			p.key(ui, fmt.tprintf("b%d", i))
			switch blk.kind {
			case .Heading:
				cls := blk.level == 1 ? "text-xl font-bold mt-6 mb-2" : blk.level == 2 ? "text-lg font-semibold mt-5 mb-2" : "text-base font-semibold mt-4 mb-1"
				p.text(ui, blk.text, cls)
			case .Paragraph:
				p.text(ui, blk.text, "text-sm leading-relaxed mb-3")
			case .Page_Break:
				p.row(ui, "w-full items-center gap-3 my-4")
				p.div(ui, "flex-1 h-px bg-border")
				p.end(ui)
				p.textf(ui, "text-[10] uppercase tracking-wide text-muted-foreground", "page %d", blk.page)
				p.div(ui, "flex-1 h-px bg-border")
				p.end(ui)
				p.end(ui)
			}
		}

	case .Structure:
		if !m.have_doc {
			empty_state(ui, m)
			return
		}
		p.col(ui, "w-full gap-1")
		defer p.end(ui)
		p.text(ui, "Every block, with what the geometry said about it.", "text-xs text-muted-foreground mb-3")
		for blk, i in m.doc.blocks {
			if blk.kind == .Page_Break {
				continue
			}
			p.key(ui, fmt.tprintf("s%d", i))
			p.row(ui, "w-full items-baseline gap-3 px-2 py-1.5 rounded-md hover:bg-accent/50 transition")
			{
				p.text(
					ui,
					blk.kind == .Heading ? fmt.tprintf("h%d", blk.level) : "p",
					"w-8 shrink-0 text-xs font-mono text-muted-foreground",
				)
				// Column -1 is a line that spanned the columns — a banner
				// headline over a two-column page — and "span" says that
				// where "c-1" reads like an error.
				p.textf(
					ui,
					"w-20 shrink-0 text-xs font-mono tabular-nums text-muted-foreground",
					"p%d %s",
					blk.page,
					blk.col < 0 ? "span" : fmt.tprintf("col%d", blk.col),
				)
				p.textf(ui, "w-14 shrink-0 text-xs font-mono tabular-nums text-muted-foreground", "%.0fpx", blk.size)
				p.textf(
					ui,
					blk.conf >= 0 && blk.conf < 75 ? "w-12 shrink-0 text-xs font-mono tabular-nums text-destructive" : "w-12 shrink-0 text-xs font-mono tabular-nums text-muted-foreground",
					"%.0f%%",
					max(blk.conf, 0),
				)
				p.text(ui, blk.text, "flex-1 text-xs truncate")
			}
			p.end(ui)
		}

	case .Notes:
		p.col(ui, "w-full gap-2 max-w-[760]")
		defer p.end(ui)
		p.text(ui, "What the pipeline decided, and why", "text-sm font-semibold mb-1")
		if m.have_doc && len(m.doc.notes) > 0 {
			for n, i in m.doc.notes {
				p.key(ui, fmt.tprintf("n%d", i))
				p.row(ui, "w-full items-start gap-2")
				p.text(ui, "·", "text-xs text-muted-foreground")
				p.text(ui, n, "flex-1 text-xs text-muted-foreground leading-relaxed")
				p.end(ui)
			}
		} else {
			p.text(ui, "Nothing yet — convert a document.", "text-xs text-muted-foreground")
		}

		sc.separator(ui, .Horizontal, "my-4")
		p.text(ui, "What would leave this machine", "w-full text-sm font-semibold mb-1")
		if m.trace.calls == 0 {
			p.text(
				ui,
				"Nothing has been sent. The local recogniser runs offline and makes no request of any kind.",
				"w-full text-xs text-muted-foreground",
			)
		} else {
			p.textf(
				ui,
				"text-xs text-muted-foreground mb-2",
				"%d request%s, %d bytes of document",
				m.trace.calls,
				m.trace.calls == 1 ? "" : "s",
				m.trace.bytes,
			)
			for l, i in m.trace.lines {
				p.key(ui, fmt.tprintf("t%d", i))
				p.text(ui, l, "text-xs font-mono text-muted-foreground")
			}
		}
	}
}

@(private = "file")
empty_state :: proc(ui: ^p.Ctx, m: ^App) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)
	p.icon(ui, sc.ICON_FILE_TEXT, "size-10 text-muted-foreground/40")
	if m.src == "" {
		p.text(ui, "Open a scan or a PDF", "text-sm text-muted-foreground")
		p.text(ui, "press o", "text-xs text-muted-foreground/70")
	} else {
		p.text(ui, "Ready to convert", "text-sm text-muted-foreground")
		p.text(ui, "press c", "text-xs text-muted-foreground/70")
	}
}

// ---------------------------------------------------------------------------

@(private = "file")
footer :: proc(ui: ^p.Ctx, m: ^App) {
	p.row(ui, "w-full h-9 shrink-0 items-center gap-2 px-4 border-t border-border bg-card")
	defer p.end(ui)
	p.icon(
		ui,
		m.status_bad ? sc.ICON_TRIANGLE_ALERT : sc.ICON_INFO,
		m.status_bad ? "size-3.5 text-destructive" : "size-3.5 text-muted-foreground",
	)
	p.text(ui, m.status, m.status_bad ? "text-xs text-destructive truncate" : "text-xs text-muted-foreground truncate")
	p.spacer(ui)
	p.textf(ui, "text-xs text-muted-foreground", "writes only %s", data_dir())
}

// ---------------------------------------------------------------------------
// The consent overlay
//
// This is the whole reason the remote backend is acceptable at all, so it says
// the specific thing — this file, this many bytes, this host — rather than a
// general reassurance, and it takes a key that cannot be hit by accident.
// Enter and Space are deliberately not it: those are the keys a person presses
// to dismiss something.
// ---------------------------------------------------------------------------

@(private = "file")
consent_overlay :: proc(ui: ^p.Ctx, m: ^App) {
	p.div(ui, "absolute inset-0 z-50 bg-black/60")
	defer p.end(ui)
	p.col(ui, "w-full h-full items-center justify-center p-8")
	defer p.end(ui)

	p.col(ui, "w-[620] gap-4 p-6 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	{
		p.icon(ui, sc.ICON_TRIANGLE_ALERT, "size-5 text-destructive")
		p.text(ui, "This will send your document to another company", "text-base font-semibold")
	}
	p.end(ui)

	p.text(ui, m.plan.text, "text-sm leading-relaxed text-muted-foreground")

	p.col(ui, "gap-1 p-3 rounded-lg bg-muted/50")
	{
		detail(ui, "Host", m.plan.host)
		detail(ui, "File", m.plan.file)
		detail(ui, "Size", human_bytes(m.plan.bytes, context.temp_allocator))
		detail(ui, "Pages", fmt.tprintf("%d", m.plan.pages))
		detail(ui, "Endpoints", "POST /v1/files, GET /v1/files/{id}/url, POST /v1/ocr")
		detail(ui, "Credential", m.key.source == .Env ? "$MISTRAL_API_KEY" : m.key.from)
	}
	p.end(ui)

	p.text(
		ui,
		"The local recogniser is already installed and runs offline. It is the default for a reason.",
		"text-xs text-muted-foreground",
	)

	p.row(ui, "items-center gap-3 mt-1")
	{
		p.row(ui, "items-center gap-2")
		{
			sc.kbd(ui, "u")
			p.text(ui, "upload it", "text-xs")
		}
		p.end(ui)
		p.row(ui, "items-center gap-2")
		{
			sc.kbd(ui, "n")
			p.text(ui, "no, keep it on this machine", "text-xs text-muted-foreground")
		}
		p.end(ui)
	}
	p.end(ui)
}

@(private = "file")
detail :: proc(ui: ^p.Ctx, label, value: string) {
	p.row(ui, "w-full items-baseline gap-3")
	defer p.end(ui)
	p.text(ui, label, "w-20 shrink-0 text-xs text-muted-foreground")
	p.text(ui, value, "flex-1 text-xs font-mono truncate")
}

// ---------------------------------------------------------------------------

@(private = "file")
help_overlay :: proc(ui: ^p.Ctx, m: ^App) {
	p.div(ui, "absolute inset-0 z-40 bg-black/50")
	defer p.end(ui)
	p.col(ui, "w-full h-full items-center justify-center p-8")
	defer p.end(ui)
	p.col(ui, "w-[560] gap-2 p-6 rounded-xl border border-border bg-card shadow-2xl")
	defer p.end(ui)
	p.text(ui, "Keys", "text-base font-semibold mb-2")
	for k in ([?][2]string {
		{"o", "open a scan or a PDF"},
		{"c", "convert"},
		{"e / m / t", "export EPUB, Markdown, plain text"},
		{"b", "switch recogniser (local or remote)"},
		{"l", "next language"},
		{"d", "cycle rasterisation dpi"},
		{"f", "OCR a PDF that already has text"},
		{"s", "segmentation: engine blocks, or our columns"},
		{"1 / 2 / 3", "document, structure, notes"},
		{"j / k", "scroll"},
		{"?", "this"},
		{"q", "quit"},
	}) {
		p.row(ui, "w-full items-center gap-3")
		sc.kbd(ui, k[0], "w-24")
		p.text(ui, k[1], "text-xs text-muted-foreground")
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// The file dialog
// ---------------------------------------------------------------------------

OCR_FILTERS := [?]kit.Pick_Filter {
	{"Scans and PDFs", {"pdf", "png", "jpg", "jpeg", "bmp", "gif", "tga", "pnm", "pgm", "ppm"}},
	{"PDF", {"pdf"}},
	kit.PICK_IMAGES,
	kit.PICK_ALL,
}

begin_pick :: proc(m: ^App) {
	dir := m.src != "" ? kit.pick_parent(m.src) : kit.pick_home(context.temp_allocator)
	kit.pick_begin(
		&m.pick,
		.Open_File,
		{title = "Open a scan or a PDF", dir = dir, filters = OCR_FILTERS[:], confirm = "Open"},
	)
	m.picking = true
}

@(private = "file")
pick_overlay :: proc(ui: ^p.Ctx, m: ^App) {
	if !kit.pick_active(&m.pick) {
		return
	}
	res, done := kit.pick_draw(ui, &m.pick)
	if !done {
		return
	}
	defer kit.pick_result_free(res)
	m.picking = false
	if !res.ok {
		return
	}
	open_path(m, res.path)
}
