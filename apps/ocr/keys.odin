package main

// Keyboard handling, which is the whole interface.
//
// Two rules worth stating. First, `key_count` rather than `key_pressed` for
// anything where one press must equal one step: several presses can arrive in
// one frame and collapse to a single `true`, which under synthetic input
// means two taps of `j` scroll one line.
//
// Second, when a modal is up it eats every key. The consent overlay in
// particular must not be dismissible by whatever key the user happened to be
// pressing — only `u` and `n` do anything while it is open, and neither Enter
// nor Escape grants it.

import "core:fmt"
import "core:os"
import kit "kit:."
import p "palmy:."

SCROLL_STEP :: f32(60)

keys :: proc(ui: ^p.Ctx, m: ^App) {
	// The file dialog owns the keyboard while it is open.
	if kit.pick_active(&m.pick) {
		return
	}

	// The consent overlay is modal and deliberately narrow: two keys, and
	// Escape declines rather than doing nothing, because a modal with no exit
	// is worse than one with a cautious one.
	if m.asking {
		if p.key_pressed(ui, 'u') || p.key_pressed(ui, 'U') {
			confirm_consent(m)
		}
		if p.key_pressed(ui, 'n') || p.key_pressed(ui, 'N') || p.key_pressed(ui, p.KEY_ESCAPE) {
			decline_consent(m)
		}
		return
	}

	if m.help {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, '?') || p.key_pressed(ui, 'q') {
			m.help = false
		}
		return
	}

	if p.key_pressed(ui, '?') {
		m.help = true
	}
	if p.key_pressed(ui, 'q') {
		m.quit = true
		p.quit_app(m.app)
	}

	if p.key_pressed(ui, 'o') {
		begin_pick(m)
	}
	if p.key_pressed(ui, 'c') {
		start_convert(m)
	}

	if p.key_pressed(ui, 'b') {
		toggle_backend(m)
	}
	if p.key_pressed(ui, 'l') && len(m.langs) > 0 {
		m.lang_i = (m.lang_i + 1) % len(m.langs)
		set_status(m, fmt.tprintf("language: %s", m.langs[m.lang_i]), false)
	}
	if n := p.key_count(ui, 'd'); n > 0 {
		for _ in 0 ..< n {
			m.dpi = next_dpi(m.dpi)
		}
		set_status(m, fmt.tprintf("rasterising PDFs at %d dpi", m.dpi), false)
	}
	if p.key_pressed(ui, 'f') {
		m.force_ocr = !m.force_ocr
		on := "a PDF's own text layer will be ignored — it is exact, and OCR is not"
		off := "a PDF's own text layer will be used, and nothing will be OCRed"
		set_status(m, m.force_ocr ? on : off, m.force_ocr)
	}
	if p.key_pressed(ui, 's') {
		m.segment = m.segment == .Auto ? .Block : .Auto
		auto := "the engine segments the page into blocks and columns"
		block := "one block from the engine; the columns are found here"
		set_status(m, m.segment == .Auto ? auto : block, false)
	}

	if p.key_pressed(ui, '1') {m.view = .Document}
	if p.key_pressed(ui, '2') {m.view = .Structure}
	if p.key_pressed(ui, '3') {m.view = .Notes}

	if p.key_pressed(ui, 'e') {export_now(m, .Epub)}
	if p.key_pressed(ui, 'm') {export_now(m, .Markdown)}
	if p.key_pressed(ui, 't') {export_now(m, .Text)}

	if n := p.key_count(ui, 'j') + p.key_count(ui, p.KEY_DOWN); n > 0 {
		m.scroll += SCROLL_STEP * f32(n)
	}
	if n := p.key_count(ui, 'k') + p.key_count(ui, p.KEY_UP); n > 0 {
		m.scroll = max(0, m.scroll - SCROLL_STEP * f32(n))
	}
}

next_dpi :: proc(d: int) -> int {
	switch d {
	case 150:
		return 200
	case 200:
		return 300
	case 300:
		return 400
	case 400:
		return 600
	}
	return 150
}

// toggle_backend is the only way to select the remote recogniser, and
// selecting it does not upload anything: it puts the consent question up the
// next time a conversion is asked for.
toggle_backend :: proc(m: ^App) {
	if m.backend == .Tesseract {
		if m.key.source == .None {
			set_status(
				m,
				fmt.tprintf(
					"Mistral OCR needs an API key. Set $MISTRAL_API_KEY or create %s. Nothing is uploaded until you confirm.",
					m.key.from,
				),
				true,
			)
			return
		}
		m.backend = .Mistral
		set_status(m, "Mistral OCR selected. Nothing has been sent; converting will ask first.", true)
		return
	}
	m.backend = .Tesseract
	consent_revoke(&m.consent)
	set_status(m, "back to the local recogniser; it runs offline", false)
}

export_now :: proc(m: ^App, f: Export_Format) {
	if !m.have_doc {
		set_status(m, "nothing to export yet — press c to convert", true)
		return
	}
	path := default_export_path(m.src == "" ? "document" : m.src, f, context.temp_allocator)
	if err := write_export(&m.doc, f, path); err != "" {
		set_status(m, err, true)
		return
	}
	size := 0
	if fi, ferr := os.stat(path, context.temp_allocator); ferr == nil {
		size = int(fi.size)
	}
	set_status(
		m,
		fmt.tprintf("wrote %s — %s, %s", base_name(path), export_name(f), human_bytes(size, context.temp_allocator)),
		false,
	)
}
