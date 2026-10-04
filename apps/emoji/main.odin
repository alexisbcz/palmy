package main

// palmy character picker.
//
// This started out as an emoji picker and is not one, for a reason worth
// stating plainly: the only emoji font on this machine is Noto Color Emoji,
// which is a CBDT/CBLC colour-bitmap font with no `glyf` table at all. palmy
// rasterises outlines through stb_truetype and has no colour-bitmap path and no
// font fallback, so every colour emoji would come out as an empty box. Shipping
// a grid of boxes would be worse than useless.
//
// So the picker is built around the characters that *do* render: 2753 of them,
// taken from the intersection of the Unicode Character Database (via Python's
// `unicodedata`, version 16.0.0) with the cmap of DejaVu Sans — arrows, maths,
// punctuation, currency, symbols, technical and keyboard glyphs, box drawing,
// shapes, Greek, Cyrillic, Latin, letterlike forms, dingbats, chess, cards,
// music, Braille, and the 64 emoticons DejaVu draws as monochrome outlines.
// See gen-chars.py; nothing in chars.odin was written from memory.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

WIN_W :: 1060
WIN_H :: 700

SIDEBAR_W :: 184
CELL :: 52
CELL_GAP :: 4
GRID_PAD :: 12
DETAIL_H :: 108

RECENT_CAP :: 96

// CAT_RECENT is the pseudo-category pinned above the real ones.
CAT_RECENT :: -1

St :: struct {
	lows:    []string, // name + aliases + category, lowercased, for search
	hits:    [dynamic]int, // indices into CHARS
	recent:  [dynamic]rune,

	query:   [dynamic]u8,
	caret:   int,
	cat:     int,
	sel:     int,
	top:     int, // first visible grid row
	cols:    int,
	vis:     int,

	toast:   string,
	toast_t: f64,
	have_wl: bool,
	glyphs:  bool, // the glyph face actually loaded
}

// g_test / g_test_clip make the clipboard write observable instead of real.
g_test: bool
g_test_clip: string

main :: proc() {
	for a in os.args[1:] {
		if a == "--selftest" || a == "-selftest" {
			os.exit(selftest() == 0 ? 0 : 1)
		}
	}

	app, err := kit.start(
		{
			title = "Characters",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 720,
			min_height = 440,
			root_class = "w-full h-full flex-col bg-background text-foreground overflow-hidden",
		},
	)
	if err != "" {
		fmt.eprintfln("emoji: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	register_dark_theme()

	// palmy has exactly two font families and no fallback, so the picker has
	// to spend one of them. DejaVu Sans goes into Mono/Regular — that is what
	// `font-mono` draws the grid with — while the heavier mono weights are left
	// as kit loaded them, so `font-mono font-medium` is still a real monospace
	// for the U+ readouts.
	glyphs := p.load_font(&app.fonts, GLYPH_FONT, .Mono, .Regular)

	st := St {
		hits    = make([dynamic]int),
		query   = make([dynamic]u8),
		recent  = make([dynamic]rune),
		cat     = 0,
		have_wl = kit.has_tool("wl-copy"),
		glyphs  = glyphs,
	}
	build_index(&st)
	load_recent(&st)
	refilter(&st)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)

		handle_keys(ui, app, &st)
		build(ui, &st)

		if st.toast != "" {
			if ui.now > st.toast_t {
				st.toast = ""
			} else {
				p.redraw(ui)
			}
		}
	}
}

register_dark_theme :: proc() {
	c :: p.hex
	p.register_color("background", c(0x0a0a0a))
	p.register_color("foreground", c(0xfafafa))
	p.register_color("card", c(0x141414))
	p.register_color("card-foreground", c(0xfafafa))
	p.register_color("popover", c(0x1c1c1c))
	p.register_color("popover-foreground", c(0xfafafa))
	p.register_color("primary", c(0xfafafa))
	p.register_color("primary-foreground", c(0x171717))
	p.register_color("secondary", c(0x262626))
	p.register_color("secondary-foreground", c(0xfafafa))
	p.register_color("muted", c(0x1f1f1f))
	p.register_color("muted-foreground", c(0xa1a1a1))
	p.register_color("accent", c(0x303033))
	p.register_color("accent-foreground", c(0xfafafa))
	p.register_color("destructive", c(0xff6467))
	p.register_color("destructive-foreground", c(0xfafafa))
	p.register_color("border", c(0x2c2c2c))
	p.register_color("input", c(0x2c2c2c))
	p.register_color("ring", c(0x8e8e8e))
}

// ---------------------------------------------------------------------------
// Index and filtering
// ---------------------------------------------------------------------------

build_index :: proc(st: ^St) {
	st.lows = make([]string, len(CHARS))
	for c, i in CHARS {
		st.lows[i] = strings.to_lower(
			fmt.tprintf("%s %s %s", c.name, c.alias, CATEGORIES[c.cat]),
		)
	}
}

query_text :: proc(st: ^St) -> string {
	return string(st.query[:])
}

// match requires every whitespace-separated term to appear, which is what makes
// "down arrow" find U+2193 without matching every arrow in the block.
match :: proc(hay: string, terms: []string) -> bool {
	for t in terms {
		if !strings.contains(hay, t) {
			return false
		}
	}
	return true
}

// parse_codepoint recognises "2192", "u+2192" and "0x2192", so a codepoint you
// already know is one search away.
parse_codepoint :: proc(q: string) -> (rune, bool) {
	s := strings.trim_space(q)
	s = strings.trim_prefix(s, "u+")
	s = strings.trim_prefix(s, "U+")
	s = strings.trim_prefix(s, "0x")
	if len(s) < 2 || len(s) > 6 {
		return 0, false
	}
	v: u32
	for i in 0 ..< len(s) {
		d: u32
		switch s[i] {
		case '0' ..= '9':
			d = u32(s[i] - '0')
		case 'a' ..= 'f':
			d = u32(s[i] - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(s[i] - 'A' + 10)
		case:
			return 0, false
		}
		v = v * 16 + d
	}
	return rune(v), true
}

refilter :: proc(st: ^St) {
	clear(&st.hits)
	q := strings.to_lower(strings.trim_space(query_text(st)), context.temp_allocator)

	if q == "" {
		if st.cat == CAT_RECENT {
			for r in st.recent {
				if i, ok := index_of_rune(r); ok {
					append(&st.hits, i)
				}
			}
		} else {
			for c, i in CHARS {
				if c.cat == st.cat {
					append(&st.hits, i)
				}
			}
		}
		st.sel = clamp(st.sel, 0, max(0, len(st.hits) - 1))
		return
	}

	// A literal codepoint wins, and is put first.
	if cp, ok := parse_codepoint(q); ok {
		if i, found := index_of_rune(cp); found {
			append(&st.hits, i)
		}
	}

	terms := strings.fields(q, context.temp_allocator)
	for i in 0 ..< len(CHARS) {
		if len(st.hits) > 0 && st.hits[0] == i {
			continue
		}
		if match(st.lows[i], terms) {
			append(&st.hits, i)
		}
	}
	st.sel = clamp(st.sel, 0, max(0, len(st.hits) - 1))
}

index_of_rune :: proc(r: rune) -> (int, bool) {
	for c, i in CHARS {
		if c.cp == r {
			return i, true
		}
	}
	return 0, false
}

current :: proc(st: ^St) -> (Char, bool) {
	if st.sel < 0 || st.sel >= len(st.hits) {
		return {}, false
	}
	return CHARS[st.hits[st.sel]], true
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if len(st.query) > 0 {
			clear(&st.query)
			st.caret = 0
			st.sel = 0
			refilter(st)
			return
		}
		quit(app)
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		quit(app)
		return
	}

	if presses := p.key_count(ui, p.KEY_TAB); presses > 0 {
		d := .Shift in ui.input.mods ? -presses : presses
		n := len(CATEGORIES)
		// Recent sits before the first real category, hence the -1 offset.
		// Recent sits at -1, before the first block, so the ring is n+1 wide.
		next := ((st.cat + 1 + d) % (n + 1) + (n + 1)) % (n + 1) - 1
		st.cat = next
		st.sel = 0
		st.top = 0
		clear(&st.query)
		st.caret = 0
		refilter(st)
		return
	}

	cols := max(1, st.cols)
	moved := false
	if n := p.key_count(ui, p.KEY_RIGHT); n > 0 {
		st.sel += n
		moved = true
	}
	if n := p.key_count(ui, p.KEY_LEFT); n > 0 {
		st.sel -= n
		moved = true
	}
	if n := p.key_count(ui, p.KEY_DOWN); n > 0 {
		st.sel += n * cols
		moved = true
	}
	if n := p.key_count(ui, p.KEY_UP); n > 0 {
		st.sel -= n * cols
		moved = true
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
		st.sel += cols * max(1, st.vis - 1)
		moved = true
	}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {
		st.sel -= cols * max(1, st.vis - 1)
		moved = true
	}
	if p.key_pressed(ui, p.KEY_HOME) && len(st.query) == 0 {
		st.sel = 0
		moved = true
	}
	if p.key_pressed(ui, p.KEY_END) && len(st.query) == 0 {
		st.sel = len(st.hits) - 1
		moved = true
	}
	if moved {
		st.sel = clamp(st.sel, 0, max(0, len(st.hits) - 1))
		keep_visible(st)
		return
	}

	if c, ok := current(st); ok {
		if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) ||
		   p.shortcut(ui, 'c', {.Ctrl}) {
			copy_text(st, ui, c.s, fmt.tprintf("%s (%s)", c.s, c.name))
			remember(st, c.cp)
			return
		}
		if p.shortcut(ui, 'u', {.Ctrl}) {
			copy_text(st, ui, fmt.tprintf("U+%04X", c.cp), fmt.tprintf("U+%04X", c.cp))
			return
		}
		if p.shortcut(ui, 'e', {.Ctrl}) {
			ent := fmt.tprintf("&#x%X;", c.cp)
			copy_text(st, ui, ent, ent)
			return
		}
		if p.shortcut(ui, 'n', {.Ctrl}) {
			copy_text(st, ui, c.name, c.name)
			return
		}
	}

	if p.shortcut(ui, 'k', {.Ctrl}) {
		clear(&st.query)
		st.caret = 0
		refilter(st)
		return
	}

	edit_query(ui, st)
}

keep_visible :: proc(st: ^St) {
	if st.cols <= 0 || st.vis <= 0 {
		return
	}
	row := st.sel / st.cols
	if row < st.top {
		st.top = row
	}
	if row >= st.top + st.vis {
		st.top = row - st.vis + 1
	}
	rows := (len(st.hits) + st.cols - 1) / st.cols
	st.top = clamp(st.top, 0, max(0, rows - st.vis))
}

edit_query :: proc(ui: ^p.Ctx, st: ^St) {
	changed := false
	if typed := p.typed_text(ui); len(typed) > 0 {
		inject_at_elems(&st.query, st.caret, ..transmute([]u8)typed)
		st.caret += len(typed)
		changed = true
	}
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case p.KEY_BACKSPACE:
			if st.caret > 0 {
				n := utf8_back(st.query[:], st.caret)
				remove_range(&st.query, st.caret - n, st.caret)
				st.caret -= n
				changed = true
			}
		case p.KEY_DELETE:
			if st.caret < len(st.query) {
				n := utf8_fwd(st.query[:], st.caret)
				remove_range(&st.query, st.caret, st.caret + n)
				changed = true
			}
		}
	}
	if changed {
		st.sel = 0
		st.top = 0
		refilter(st)
	}
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return max(1, at - i)
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return i - at
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

toast :: proc(st: ^St, ui: ^p.Ctx, msg: string) {
	if st.toast != "" {
		delete(st.toast)
	}
	st.toast = strings.clone(msg)
	st.toast_t = ui.now + 3.5
}

// quit is nil-safe so the headless self-test can drive `handle_keys` with no
// window behind it.
quit :: proc(app: ^p.App) {
	if app != nil {
		p.quit_app(app)
	}
}

copy_text :: proc(st: ^St, ui: ^p.Ctx, text, label: string) {
	// The self-test drives the real key handlers, and a test must not reach
	// out and change the user's clipboard.
	if g_test {
		if g_test_clip != "" {delete(g_test_clip)}
		g_test_clip = strings.clone(text)
		toast(st, ui, fmt.tprintf("Copied %s", label))
		return
	}
	if !st.have_wl {
		toast(st, ui, "wl-copy is not installed")
		return
	}
	if kit.clipboard_set(text) {
		toast(st, ui, fmt.tprintf("Copied %s", label))
	} else {
		toast(st, ui, "wl-copy failed")
	}
}

remember :: proc(st: ^St, r: rune) {
	for c, i in st.recent {
		if c == r {
			ordered_remove(&st.recent, i)
			break
		}
	}
	inject_at(&st.recent, 0, r)
	for len(st.recent) > RECENT_CAP {
		pop(&st.recent)
	}
	save_recent(st)
}

recent_path :: proc(al := context.temp_allocator) -> string {
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return ""
	}
	return fmt.aprintf("%s/.local/share/palmy-emoji", home, allocator = al)
}

load_recent :: proc(st: ^St) {
	dir := recent_path()
	if dir == "" {
		return
	}
	data, err := os.read_entire_file_from_path(
		fmt.tprintf("%s/recent", dir),
		context.temp_allocator,
	)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		if cp, ok := parse_codepoint(strings.trim_space(line)); ok {
			if _, found := index_of_rune(cp); found {
				append(&st.recent, cp)
			}
		}
		if len(st.recent) >= RECENT_CAP {
			break
		}
	}
}

save_recent :: proc(st: ^St) {
	dir := recent_path()
	if dir == "" {
		return
	}
	_ = os.make_directory_all(dir)
	_ = os.chmod(dir, os.perm_number(0o700))
	b := strings.builder_make(context.temp_allocator)
	for r in st.recent {
		fmt.sbprintfln(&b, "U+%04X", r)
	}
	path := fmt.tprintf("%s/recent", dir)
	_ = os.write_entire_file(path, transmute([]u8)strings.to_string(b), os.perm_number(0o600))
}

// ---------------------------------------------------------------------------
// The frame
// ---------------------------------------------------------------------------

build :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)

	grid_w := size.x - SIDEBAR_W - GRID_PAD * 2
	st.cols = max(1, int((grid_w + CELL_GAP) / (CELL + CELL_GAP)))
	grid_h := size.y - 56 - DETAIL_H - 34 - GRID_PAD * 2
	st.vis = max(1, int((grid_h + CELL_GAP) / (CELL + CELL_GAP)))
	keep_visible(st)

	header(ui, st)

	p.row(ui, "w-full flex-1 min-h-0")
	sidebar(ui, st)
	grid(ui, st)
	p.end(ui)

	detail(ui, st)
	footer(ui, st)
}

header :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[56] shrink-0 items-center gap-3 px-4 border-b border-border")
	defer p.end(ui)

	p.icon(ui, IC_LANGUAGES, "size-[18] shrink-0 text-muted-foreground")

	p.row(ui, "flex-1 h-full items-center overflow-hidden")
	txt := query_text(st)
	if len(txt) == 0 {
		p.textf(
			ui,
			"text-base text-muted-foreground whitespace-nowrap",
			"Search %d characters by name, or type a codepoint like 2192…",
			len(CHARS),
		)
	} else {
		p.text(ui, txt, "text-base whitespace-nowrap")
	}
	p.style(ui).shrink = 0

	// The caret is the only animation in the app, and it only blinks while the
	// window has focus — an unfocused palmy window should cost nothing.
	if ui.input.focused {
		ui.animating = true
	}
	if ui.input.focused && math.mod_f32(f32(ui.now), 1.1) < 0.62 {
		w := p.text_width(ui.fonts, txt[:clamp(st.caret, 0, len(txt))], 16, .Sans, .Regular)
		car := p.div(ui, "absolute w-[2] rounded-full bg-foreground")
		cs := p.style(ui, car)
		cs.inset[p.LEFT] = p.px(w)
		cs.inset[p.TOP] = p.px(18)
		cs.h = p.px(20)
		p.end(ui)
	}
	p.end(ui)

	p.row(ui, "shrink-0 items-center gap-2")
	if !st.glyphs {
		sc.badge(ui, "glyph font missing", .Destructive)
	}
	sc.badge(ui, fmt.tprintf("Unicode %s", UNICODE_VERSION), .Secondary)
	p.textf(ui, "text-xs text-muted-foreground whitespace-nowrap", "%d shown", len(st.hits))
	p.style(ui).shrink = 0
	p.end(ui)
}

sidebar :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "w-[184] shrink-0 h-full min-h-0 p-2 gap-0.5 border-r border-border overflow-scroll")
	defer p.end(ui)

	searching := len(strings.trim_space(query_text(st))) > 0

	cat_row(ui, st, CAT_RECENT, "Recently used", len(st.recent), IC_CLOCK, !searching && st.cat == CAT_RECENT)

	p.row(ui, "w-full h-7 shrink-0 items-center px-2")
	p.text(
		ui,
		"Blocks",
		"text-[10] font-semibold uppercase tracking-wide text-muted-foreground whitespace-nowrap",
	)
	p.end(ui)

	for name, i in CATEGORIES {
		n := 0
		for c in CHARS {
			if c.cat == i {n += 1}
		}
		cat_row(ui, st, i, name, n, cat_icon(i), !searching && st.cat == i)
	}

	p.spacer(ui)
	if searching {
		p.col(ui, "w-full shrink-0 gap-1 p-2 rounded-lg bg-muted")
		p.text(ui, "Searching every block", "text-[11] font-medium whitespace-nowrap")
		p.text(ui, "Esc clears the search", "text-[10] text-muted-foreground whitespace-nowrap")
		p.end(ui)
	}
}

cat_row :: proc(ui: ^p.Ctx, st: ^St, cat: int, label: string, n: int, ic: p.Icon, on: bool) {
	p.key(ui, label)
	idx := p.row(ui, "w-full h-8 shrink-0 items-center gap-2 px-2 rounded-md transition")
	p.apply(ui, on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-muted", idx)
	if p.clickable(ui, idx) {
		st.cat = cat
		st.sel = 0
		st.top = 0
		clear(&st.query)
		st.caret = 0
		refilter(st)
	}
	defer p.end(ui)

	p.icon(ui, ic, "size-3.5 shrink-0")
	p.text(ui, label, "flex-1 text-xs font-medium whitespace-nowrap truncate")
	p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap", "%d", n)
	p.style(ui).shrink = 0
}

cat_icon :: proc(i: int) -> p.Icon {
	switch CATEGORIES[i] {
	case "Arrows":
		return IC_ARROW_RIGHT
	case "Maths":
		return IC_SIGMA
	case "Punctuation":
		return IC_PILCROW
	case "Currency":
		return IC_TAG
	case "Symbols":
		return IC_SPARKLES
	case "Technical":
		return IC_COMMAND
	case "Shapes":
		return IC_SQUARE
	case "Box drawing":
		return IC_TABLE
	case "Greek":
		return IC_OMEGA
	case "Cyrillic":
		return IC_CASE_SENSITIVE
	case "Latin":
		return IC_BASELINE
	case "Letterlike":
		return IC_SUPERSCRIPT
	case "Super & sub":
		return IC_SUPERSCRIPT
	case "Emoticons":
		return IC_CIRCLE
	case "Games":
		return IC_PLAY
	case "Music":
		return IC_MUSIC
	case "Braille":
		return IC_LAYOUT_GRID
	}
	return IC_HASH
}

// grid draws a window of rows rather than every cell. 2753 elements a frame
// would be 2753 nodes, a layout pass over all of them and a scrollbar with
// nothing to do; a window of rows is the same thing the launcher's list does.
grid :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 min-w-0 min-h-0 p-3 gap-1 overflow-hidden relative")
	defer p.end(ui)

	if len(st.hits) == 0 {
		empty_state(ui, st)
		return
	}

	rows := (len(st.hits) + st.cols - 1) / st.cols
	last := min(st.top + st.vis, rows)
	for r in st.top ..< last {
		p.key(ui, fmt.tprintf("r%d", r))
		p.row(ui, "w-full shrink-0 gap-1")
		for c in 0 ..< st.cols {
			i := r * st.cols + c
			if i >= len(st.hits) {
				break
			}
			cell(ui, st, i)
		}
		p.end(ui)
	}

	if rows > st.vis {
		track := f32(st.vis) * (CELL + CELL_GAP) - 8
		th := max(24, track * f32(st.vis) / f32(rows))
		frac := f32(st.top) / f32(max(1, rows - st.vis))
		bar := p.div(ui, "absolute w-[3] rounded-full bg-border")
		bs := p.style(ui, bar)
		bs.position = .Absolute
		bs.inset[p.RIGHT] = p.px(3)
		bs.inset[p.TOP] = p.px(12 + (track - th) * frac)
		bs.h = p.px(th)
		p.end(ui)
	}
}

cell :: proc(ui: ^p.Ctx, st: ^St, i: int) {
	c := CHARS[st.hits[i]]
	sel := i == st.sel

	p.key(ui, fmt.tprintf("c%d", c.cp))
	idx := p.div(
		ui,
		"w-[52] h-[52] shrink-0 flex-row items-center justify-center rounded-lg border transition",
	)
	p.apply(
		ui,
		sel ? "bg-accent border-ring" : "border-transparent hover:bg-muted hover:border-border",
		idx,
	)
	if p.clickable(ui, idx) {
		st.sel = i
	}
	defer p.end(ui)

	// `font-mono` is DejaVu Sans here — see the note in main().
	p.text(ui, c.s, sel ? "text-2xl font-mono text-foreground" : "text-2xl font-mono")
	p.style(ui).shrink = 0
}

empty_state :: proc(ui: ^p.Ctx, st: ^St) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)

	p.div(ui, "size-12 flex-row items-center justify-center rounded-full bg-muted ring-1 ring-border")
	p.icon(ui, IC_SEARCH, "size-5 text-muted-foreground")
	p.end(ui)

	q := strings.trim_space(query_text(st))
	if q != "" {
		p.text(ui, "No character matches", "text-sm font-medium")
		p.textf(
			ui,
			"text-xs text-muted-foreground whitespace-nowrap",
			"Nothing is named “%s”. Try a word from the Unicode name, like “arrow” or “heart”.",
			q,
		)
		return
	}
	if st.cat == CAT_RECENT {
		p.text(ui, "Nothing used yet", "text-sm font-medium")
		p.text(
			ui,
			"Characters you copy with Enter collect here, newest first",
			"text-xs text-muted-foreground",
		)
		return
	}
	p.text(ui, "This block is empty", "text-sm font-medium")
}

// ---------------------------------------------------------------------------
// Detail
// ---------------------------------------------------------------------------

detail :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[108] shrink-0 items-center gap-4 px-4 border-t border-border bg-card")
	defer p.end(ui)

	c, ok := current(st)
	if !ok {
		p.text(ui, "Nothing selected", "text-xs text-muted-foreground")
		return
	}

	p.div(ui, "w-[76] h-[76] shrink-0 flex-row items-center justify-center rounded-xl bg-background ring-1 ring-border")
	p.text(ui, c.s, "text-5xl font-mono")
	p.style(ui).shrink = 0
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-1.5")
	p.text(ui, c.name, "text-sm font-semibold whitespace-nowrap truncate")
	if c.alias != "" {
		p.text(ui, c.alias, "text-[11] text-muted-foreground whitespace-nowrap truncate")
	}
	p.row(ui, "items-center gap-2 flex-wrap")
	chip(ui, fmt.tprintf("U+%04X", c.cp))
	chip(ui, fmt.tprintf("&#x%X;", c.cp))
	chip(ui, utf8_bytes(c.s))
	chip(ui, CATEGORIES[c.cat])
	p.end(ui)
	p.end(ui)

	p.col(ui, "shrink-0 items-end gap-1.5")
	keyline(ui, "Enter", "copy the character")
	keyline(ui, "Ctrl U", "copy U+XXXX")
	keyline(ui, "Ctrl E", "copy &#x…;")
	keyline(ui, "Ctrl N", "copy the name")
	p.end(ui)
}

chip :: proc(ui: ^p.Ctx, s: string) {
	p.row(ui, "shrink-0 h-5 items-center px-1.5 rounded-md bg-muted")
	defer p.end(ui)
	p.text(ui, s, "text-[11] font-mono font-medium text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

keyline :: proc(ui: ^p.Ctx, keys, label: string) {
	p.row(ui, "shrink-0 items-center gap-1.5")
	defer p.end(ui)
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	for part in strings.split(keys, " ", context.temp_allocator) {
		sc.kbd(ui, part)
	}
}

utf8_bytes :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		fmt.sbprintf(&b, "%02X", s[i])
	}
	return strings.to_string(b)
}

footer :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full h-[34] shrink-0 items-center gap-3 px-4 border-t border-border")
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-xs text-muted-foreground whitespace-nowrap truncate")
		return
	}

	hint(ui, "Arrows", "", "Move")
	hint(ui, "Tab", "", "Block")
	hint(ui, "Enter", "", "Copy")
	p.spacer(ui)
	p.text(
		ui,
		"Colour emoji cannot be drawn here: the only emoji font installed is a bitmap font",
		"text-[11] text-muted-foreground whitespace-nowrap truncate",
	)
	p.spacer(ui)
	hint(ui, "Esc", "", "Close")
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}
