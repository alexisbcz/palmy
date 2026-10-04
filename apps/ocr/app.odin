package main

// Application state, and the one worker thread everything slow runs on.
//
// Converting a page is seconds, not milliseconds: tesseract on a 1600x2200
// page is around a second, and a forty-page PDF is a minute. None of that may
// happen on the frame loop, so there is one job in flight at a time, started
// by a keystroke and run on a thread. The frame polls two atomics — a stage
// string and a done/total pair — and draws a progress bar from them. The
// resulting Doc is only read after `finished` is seen, which is the point at
// which the worker has stopped touching it.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import kit "kit:."
import p "palmy:."

View :: enum u8 {
	Document,
	Structure,
	Notes,
}

view_name :: proc(v: View) -> string {
	switch v {
	case .Document:
		return "Document"
	case .Structure:
		return "Structure"
	case .Notes:
		return "Notes"
	}
	return ""
}

App :: struct {
	app:        ^p.App,
	tools:      Tools,
	langs:      []string,
	lang_i:     int,

	// The source.
	src:        string, // heap-owned
	kind:       Source_Kind,
	src_pages:  int,
	src_bytes:  int,
	preview:    p.Image,
	preview_ok: bool,

	// Settings.
	backend:    Backend_Id,
	dpi:        int,
	force_ocr:  bool,
	segment:    Segmentation,

	// The result.
	doc:        Doc,
	have_doc:   bool,
	stats:      Convert_Stats,

	// Chrome.
	view:       View,
	scroll:     f32,
	status:     string, // heap-owned
	status_bad: bool,
	help:       bool,
	quit:       bool,

	// Consent. One per session, and it is a value the user constructs by
	// agreeing to a named payload — never a boolean somebody flipped.
	consent:    Consent,
	plan:       Upload_Plan,
	asking:     bool, // the consent overlay is up
	key:        Key_Info,

	trace:      Trace,

	// The file dialog.
	pick:       kit.Pick,
	picking:    bool,
}

// ---------------------------------------------------------------------------
// The job
// ---------------------------------------------------------------------------

Job :: struct {
	src:      string, // heap-owned
	opts:     Convert_Opts,
	doc:      Doc,
	stats:    Convert_Stats,
	err:      string, // heap-owned

	running:  bool,
	finished: bool,
	done:     i64,
	total:    i64,
	mu:       sync.Mutex,
	note_buf: [160]u8,
	note_len: int,
}

g_job: Job

job_busy :: proc() -> bool {
	return sync.atomic_load(&g_job.running)
}

job_progress :: proc() -> (done, total: int) {
	return int(sync.atomic_load(&g_job.done)), int(sync.atomic_load(&g_job.total))
}

job_note :: proc(allocator := context.temp_allocator) -> string {
	sync.mutex_lock(&g_job.mu)
	defer sync.mutex_unlock(&g_job.mu)
	return strings.clone(string(g_job.note_buf[:g_job.note_len]), allocator)
}

@(private = "file")
set_note :: proc(text: string) {
	sync.mutex_lock(&g_job.mu)
	defer sync.mutex_unlock(&g_job.mu)
	n := min(len(text), len(g_job.note_buf))
	copy(g_job.note_buf[:], text[:n])
	g_job.note_len = n
}

@(private = "file")
on_stage :: proc(user: rawptr, stage: string, done, total: int) {
	set_note(stage)
	sync.atomic_store(&g_job.done, i64(done))
	sync.atomic_store(&g_job.total, i64(max(total, 1)))
}

@(private = "file")
job_run :: proc() {
	doc_init(&g_job.doc)
	err := convert(g_job.src, g_job.opts, &g_job.doc, &g_job.stats)
	g_job.err = err == "" ? "" : strings.clone(err)
	sync.atomic_store(&g_job.finished, true)
	sync.atomic_store(&g_job.running, false)
}

// start_convert hands the current settings to the worker. It is the only place
// a conversion begins, so the consent gate below it cannot be bypassed by a
// second entry point.
start_convert :: proc(m: ^App) {
	if job_busy() || m.src == "" {
		return
	}
	b := backend_by_id(m.backend)
	if b.remote && !m.consent.granted {
		ask_consent(m)
		return
	}
	if ok, why := b.probe(&b); !ok {
		set_status(m, why, true)
		delete(why)
		return
	}

	if g_job.src != "" {
		delete(g_job.src)
	}
	g_job = Job {
		src = strings.clone(m.src),
	}
	g_job.opts = Convert_Opts {
		backend   = m.backend,
		lang      = m.lang_i < len(m.langs) ? m.langs[m.lang_i] : "eng",
		dpi       = m.dpi,
		segment   = m.segment,
		force_ocr = m.force_ocr,
		endpoint  = endpoint_default(),
		consent   = &m.consent,
		trace     = &m.trace,
		on_stage  = on_stage,
	}
	sync.atomic_store(&g_job.running, true)
	sync.atomic_store(&g_job.total, 1)
	set_note("starting")
	thread.create_and_start(job_run)
	set_status(m, "converting", false)
}

// tick collects a finished job. It runs at the top of every frame, before any
// element exists, so the Doc never changes under a painter.
tick :: proc(m: ^App) {
	if !sync.atomic_load(&g_job.finished) {
		return
	}
	sync.atomic_store(&g_job.finished, false)

	if m.have_doc {
		doc_destroy(&m.doc)
		stats_destroy(&m.stats)
		m.have_doc = false
	}
	if g_job.err != "" {
		set_status(m, g_job.err, true)
		delete(g_job.err)
		g_job.err = ""
		doc_destroy(&g_job.doc)
		stats_destroy(&g_job.stats)
		return
	}
	m.doc = g_job.doc
	m.stats = g_job.stats
	g_job.doc = {}
	g_job.stats = {}
	m.have_doc = true
	m.scroll = 0
	set_status(
		m,
		fmt.tprintf(
			"%d page%s, %d words, %d blocks in %d ms",
			m.doc.pages,
			m.doc.pages == 1 ? "" : "s",
			m.doc.words,
			len(m.doc.blocks),
			m.stats.ocr_ms,
		),
		false,
	)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

app_init :: proc(m: ^App) {
	m.tools = check_tools()
	m.langs = tess_langs(context.allocator)
	m.dpi = 300
	m.backend = .Tesseract
	m.view = .Document
	doc_init(&m.doc)
	trace_init(&m.trace)
	_, m.key = mistral_key()
	m.src = strings.clone("")
	m.status = strings.clone("")

	if !m.tools.tesseract {
		set_status(
			m,
			"tesseract is not installed, so nothing can be recognised on this machine. Install it; nothing will be uploaded instead.",
			true,
		)
	} else if !m.tools.pdftoppm {
		set_status(m, "poppler is missing, so PDFs cannot be read. Images still work.", true)
	} else {
		set_status(m, "press o to open a scan or a PDF", false)
	}
}

app_destroy :: proc(m: ^App) {
	doc_destroy(&m.doc)
	stats_destroy(&m.stats)
	consent_destroy(&m.consent)
	plan_destroy(&m.plan)
	key_info_destroy(&m.key)
	trace_destroy(&m.trace)
	if m.preview_ok {
		p.image_destroy(&m.preview)
	}
	for l in m.langs {
		delete(l)
	}
	delete(m.langs)
	if m.src != "" {delete(m.src)}
	if m.status != "" {delete(m.status)}
	kit.pick_destroy(&m.pick)
}

set_status :: proc(m: ^App, text: string, bad: bool) {
	if m.status != "" {
		delete(m.status)
	}
	m.status = strings.clone(text)
	m.status_bad = bad
}

// open_path loads a file the user picked or named. Nothing else in this
// program opens anything the user did not choose.
open_path :: proc(m: ^App, path: string) {
	expanded := path
	if strings.has_prefix(path, "~/") {
		expanded = fmt.tprintf("%s%s", kit.pick_home(context.temp_allocator), path[1:])
	}
	abs := kit.pick_normalize(expanded, "/", "", context.temp_allocator)
	if !kit.pick_exists(abs) {
		set_status(m, fmt.tprintf("no such file: %s", abs), true)
		return
	}
	kind := sniff(abs)
	if kind == .Unknown {
		set_status(m, fmt.tprintf("%s is not a PDF or an image this build can read", base_name(abs)), true)
		return
	}
	if m.src != "" {delete(m.src)}
	m.src = strings.clone(abs)
	m.kind = kind
	m.src_pages = kind == .Pdf ? pdf_page_count(abs) : 1
	m.src_bytes = 0
	if fi, ferr := os.stat(abs, context.temp_allocator); ferr == nil {
		m.src_bytes = int(fi.size)
	}

	if m.preview_ok {
		p.image_destroy(&m.preview)
		m.preview_ok = false
	}
	if kind == .Image {
		m.preview, m.preview_ok = p.load_image(abs)
	}
	if m.have_doc {
		doc_destroy(&m.doc)
		stats_destroy(&m.stats)
		doc_init(&m.doc)
		m.have_doc = false
	}
	set_status(m, fmt.tprintf("%s loaded — press c to convert", base_name(abs)), false)
}

// ---------------------------------------------------------------------------
// Consent, from the interface
// ---------------------------------------------------------------------------

// ask_consent puts up the overlay. It does not grant anything: only
// `confirm_consent`, bound to one deliberate key, does that.
ask_consent :: proc(m: ^App) {
	plan_destroy(&m.plan)
	pages := max(1, m.src_pages)
	m.plan = mistral_plan({m.src}, endpoint_default(), pages)
	m.asking = true
}

confirm_consent :: proc(m: ^App) {
	if !m.asking {
		return
	}
	consent_grant(&m.consent, m.plan.host, m.plan.file, m.plan.bytes, m.plan.pages, 0)
	m.asking = false
	set_status(m, fmt.tprintf("consented to upload %s to %s", m.plan.file, m.plan.host), false)
	start_convert(m)
}

decline_consent :: proc(m: ^App) {
	m.asking = false
	m.backend = .Tesseract
	set_status(m, "nothing was uploaded; back to the local recogniser", false)
}
