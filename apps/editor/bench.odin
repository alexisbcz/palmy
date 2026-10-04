// `editor <path> --bench` measures the buffer without a compositor.
//
// The point is not a score, it is a guarantee: every number here is a thing
// the interactive editor does on one keystroke or one scroll notch, so if
// these are in microseconds the window cannot be slow.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

ms :: proc(d: time.Duration) -> f64 {
	return time.duration_milliseconds(d)
}

run_bench :: proc(path: string) {
	if path == "" {
		fmt.eprintln("editor --bench needs a file")
		os.exit(2)
	}

	b := Buffer{}
	sw: time.Stopwatch

	time.stopwatch_start(&sw)
	ok := buf_load(&b, path)
	time.stopwatch_stop(&sw)
	if !ok {
		fmt.eprintfln("editor --bench: cannot read %s", path)
		os.exit(2)
	}
	load := time.stopwatch_duration(sw)

	// Loading and saving has to be byte-exact, or an editor quietly rewrites
	// files it was only asked to look at.
	tmp := "/tmp/palmy-editor-roundtrip.tmp"
	saved := buf_save(&b, tmp)
	orig, _ := os.read_entire_file_from_path(path, context.temp_allocator)
	back, _ := os.read_entire_file_from_path(tmp, context.temp_allocator)
	same := saved && len(orig) == len(back) && string(orig) == string(back)
	os.remove(tmp)
	delete(b.path)
	b.path = strings.clone(path)

	n := buf_lines(&b)
	bytes := buf_byte_size(&b)
	fmt.printfln("file          %s", path)
	fmt.printfln("size          %d bytes, %d lines", bytes, n)
	fmt.printfln("load          %.1f ms", ms(load))
	fmt.printfln("round trip    %s", same ? "byte for byte identical" : "DIFFERS")

	// A frame builds one Disp per visible line. 40 lines is a full window.
	ROWS :: 40
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	frames :: 200
	cells := 0
	for f in 0 ..< frames {
		top := (f * 977) % max(1, n - ROWS)
		for i in top ..< min(top + ROWS, n) {
			cells += len(buf_line(&b, i))
		}
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"viewport      %.3f ms per 40-line window (%d windows, %d bytes read)",
		ms(time.stopwatch_duration(sw)) / frames,
		frames,
		cells,
	)

	// Typing at the top of the file: the worst case for a line array, because
	// a line split memmoves every descriptor after it.
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	cur := Pos{0, 0}
	for i in 0 ..< 2000 {
		_ = i
		cur = buf_apply(&b, cur, cur, "x", cur, .Type)
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"insert@top    %.4f ms per character (2000 chars at line 0)",
		ms(time.stopwatch_duration(sw)) / 2000,
	)

	// Splitting lines at the top: 500 newlines, each one a descriptor memmove
	// of the whole file.
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	for i in 0 ..< 500 {
		_ = i
		cur = buf_apply(&b, cur, cur, "\n", cur, .No)
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"newline@top   %.4f ms per line split (500 splits in a %d-line file)",
		ms(time.stopwatch_duration(sw)) / 500,
		buf_lines(&b),
	)

	// Typing at the end, the common case.
	end := buf_end(&b)
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	for i in 0 ..< 2000 {
		_ = i
		end = buf_apply(&b, end, end, "y", end, .Type)
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"insert@end    %.4f ms per character (2000 chars at the last line)",
		ms(time.stopwatch_duration(sw)) / 2000,
	)

	// Undo the whole session.
	depth := len(b.undo)
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	for {
		_, more := buf_undo(&b)
		if !more {
			break
		}
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"undo all      %.1f ms for %d entries",
		ms(time.stopwatch_duration(sw)),
		depth,
	)
	fmt.printfln("lines after   %d (back to %d: %v)", buf_lines(&b), n, buf_lines(&b) == n)

	// A whole-file search, which is what the match counter in the find bar
	// recomputes on every keystroke.
	needle := "the"
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	hits := buf_count(&b, needle, true)
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"count \"%s\"     %.1f ms, %d hits",
		needle,
		ms(time.stopwatch_duration(sw)),
		hits,
	)

	// Highlighting the whole file, the worst case for the token cache.
	if lang_highlights(lang_for_path(path)) {
		b.valid = 0
		time.stopwatch_reset(&sw)
		time.stopwatch_start(&sw)
		lex_states_upto(&b, buf_lines(&b), lang_for_path(path))
		time.stopwatch_stop(&sw)
		fmt.printfln("tokenise all  %.1f ms", ms(time.stopwatch_duration(sw)))
	}

	bench_wrap(&b, path)
	bench_carets(path)
}

// bench_carets is what a keystroke costs with a lot of cursors.
//
// `Add Cursor at Every Match` can genuinely produce a thousand of them, and
// every keystroke is then a thousand replacements plus a sort. If that is not
// well inside a frame, the feature is a trap.
bench_carets :: proc(path: string) {
	ed := Editor{}
	buf_init_empty(&ed.buf)
	ed.lang = .Plain
	ed.cols = 100
	ed.rows = 40
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	N :: 1000
	for i in 0 ..< N {
		fmt.sbprintf(&sb, "name_here = %d\n", i)
	}
	buf_apply(&ed.buf, {0, 0}, {0, 0}, strings.to_string(sb), {0, 0}, .No)
	ed.cur = {0, 0}

	sw: time.Stopwatch
	time.stopwatch_start(&sw)
	caret_add_all(&ed)
	time.stopwatch_stop(&sw)
	placed := carets_count(&ed)
	fmt.printfln(
		"carets place  %.3f ms to put %d cursors on every match in %d lines",
		ms(time.stopwatch_duration(sw)),
		placed,
		N,
	)

	KEYS :: 20
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	for _ in 0 ..< KEYS {
		carets_edit(&ed, .Insert, "x")
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"carets type   %.3f ms per keystroke across %d cursors",
		ms(time.stopwatch_duration(sw)) / KEYS,
		placed,
	)

	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	buf_undo(&ed.buf)
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"carets undo   %.3f ms to take the whole run of %d keystrokes back",
		ms(time.stopwatch_duration(sw)),
		KEYS,
	)
	delete(ed.extra)
	delete(ed.vis)
	delete(ed.scratch)
}

// bench_wrap is the cost soft wrap adds to a frame.
//
// Nothing is wrapped except what is on screen, so the number that matters is
// one window's worth — and, separately, what it costs to scroll one row, since
// `vis_advance` and `ensure_visible` wrap a line each time they step over one.
// Both have to be well inside a frame or wrapping would make scrolling slow in
// exactly the files it is for.
bench_wrap :: proc(b: ^Buffer, path: string) {
	ed := Editor{}
	ed.buf = b^
	ed.lang = lang_for_path(path)
	ed.cols = 80
	ed.rows = 40
	ed.wrap = true
	n := buf_lines(b)

	sw: time.Stopwatch
	frames :: 200
	rows := 0
	time.stopwatch_start(&sw)
	for f in 0 ..< frames {
		ed.top = (f * 977) % max(1, n - 1)
		ed.top_sub = 0
		build_visible(&ed)
		rows += len(ed.vis)
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"wrap window   %.4f ms per %d-row window (%d windows, %d rows laid out)",
		ms(time.stopwatch_duration(sw)) / frames,
		ed.rows,
		frames,
		rows,
	)

	// Scrolling one visual row at a time, which is what the wheel does.
	steps :: 2000
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	line, sub := 0, 0
	for _ in 0 ..< steps {
		line, sub = vis_advance(&ed, line, sub, 1)
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"wrap scroll   %.4f ms per visual row (%d rows walked)",
		ms(time.stopwatch_duration(sw)) / steps,
		steps,
	)

	// The caret round trip, which every keystroke does twice.
	trips :: 20000
	time.stopwatch_reset(&sw)
	time.stopwatch_start(&sw)
	sink := 0
	for i in 0 ..< trips {
		li := (i * 7919) % n
		src := buf_line(b, li)
		col := len(src) > 0 ? (i * 31) % len(src) : 0
		s, dx := caret_vis(&ed, pos_clamp(b, {li, col}))
		sink += col_at(&ed, li, s, dx).col
		if i % 512 == 0 {
			free_all(context.temp_allocator)
		}
	}
	time.stopwatch_stop(&sw)
	fmt.printfln(
		"wrap caret    %.4f ms per round trip (%d trips, %d)",
		ms(time.stopwatch_duration(sw)) / trips,
		trips,
		sink & 1,
	)
	delete(ed.vis)
	delete(ed.scratch)
}
