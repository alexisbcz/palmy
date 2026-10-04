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
	if strings.has_suffix(path, ".odin") {
		b.valid = 0
		time.stopwatch_reset(&sw)
		time.stopwatch_start(&sw)
		lex_states_upto(&b, buf_lines(&b))
		time.stopwatch_stop(&sw)
		fmt.printfln("tokenise all  %.1f ms", ms(time.stopwatch_duration(sw)))
	}
}
