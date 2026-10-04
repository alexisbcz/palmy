package main

// Capturing, and the one background job that does it.
//
// `grim` takes about 80 ms for a full 1920x1080 output, which would be a
// visible hitch but not a disaster. `slurp` is different: it puts an overlay
// on the screen and does not return until somebody has dragged a rectangle,
// which could be a minute. Neither belongs in the frame, so both go through a
// single worker thread with the same handshake the rest of these applets use:
// two atomic booleans, one job in flight, the frame polls and never waits.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import kit "kit:."

Mode :: enum {
	Screen, // every output, composited
	Output, // one output
	Region, // a rectangle chosen with slurp
}

mode_label :: proc(m: Mode) -> string {
	switch m {
	case .Screen:
		return "Whole screen"
	case .Output:
		return "One output"
	case .Region:
		return "Region"
	}
	return ""
}

Output :: struct {
	name:        string,
	desc:        string,
	w, h, x, y:  int,
	scale:       f32,
	focused:     bool,
}

// read_outputs asks the compositor what it is driving. hyprctl is the only
// subprocess here that is not grim or slurp, and there is no file in /sys that
// describes a Wayland output's layout.
read_outputs :: proc(al := context.allocator) -> []Output {
	text, ok := kit.run({"hyprctl", "monitors", "-j"}, context.temp_allocator)
	if !ok || text == "" {
		return nil
	}
	return parse_outputs(text, al)
}

// parse_outputs is read_outputs with the subprocess taken out, so the
// self-test can hand it hyprctl documents — including a truncated one, which
// is what a compositor restarting mid-read produces.
//
// It walks the document rather than unmarshalling it, but it walks it with a
// brace counter rather than by searching for `"name":`. That distinction is
// not pedantry: every monitor object contains an `activeWorkspace` which has a
// `"name"` of its own, and a reader that searches for the next `"name":` stops
// the first monitor's fields at the workspace — which is three keys before
// `scale` and `focused`. Both came back zero and false for every monitor on
// this machine until this was counted properly.
parse_outputs :: proc(text: string, al := context.allocator) -> []Output {
	out := make([dynamic]Output, 0, 4, al)
	rest := text
	for obj in next_object(&rest) {
		o := Output {
			name = strings.clone(obj_str(obj, "name"), al),
			desc = strings.clone(obj_str(obj, "description"), al),
			w    = obj_int(obj, "width"),
			h    = obj_int(obj, "height"),
			x    = obj_int(obj, "x"),
			y    = obj_int(obj, "y"),
			scale = obj_f32(obj, "scale"),
			focused = obj_bool(obj, "focused"),
		}
		// A monitor with no name or no size is not something that can be
		// captured, whatever else the document said about it.
		if o.name == "" || o.w <= 0 || o.h <= 0 {
			delete(o.name, al)
			delete(o.desc, al)
			continue
		}
		if o.scale <= 0 {
			o.scale = 1
		}
		append(&out, o)
	}
	return out[:]
}

// next_object yields the text of each top-level `{...}` in a JSON array,
// braces included, advancing `rest`. A final object that never closes — a
// truncated read — is yielded as far as it got, and parse_outputs's own
// filter is what throws it away.
@(private)
next_object :: proc(rest: ^string) -> (obj: string, ok: bool) {
	s := rest^
	i := 0
	for i < len(s) && s[i] != '{' {
		if s[i] == '"' {
			i = skip_string(s, i)
			continue
		}
		i += 1
	}
	if i >= len(s) {
		rest^ = ""
		return "", false
	}
	start := i
	depth := 0
	for i < len(s) {
		switch s[i] {
		case '"':
			i = skip_string(s, i)
			continue
		case '{':
			depth += 1
		case '}':
			depth -= 1
			if depth == 0 {
				rest^ = s[i + 1:]
				return s[start:i + 1], true
			}
		}
		i += 1
	}
	rest^ = ""
	return s[start:], true
}

// skip_string returns the index just past the string literal starting at `i`.
@(private)
skip_string :: proc(s: string, i: int) -> int {
	j := i + 1
	for j < len(s) {
		if s[j] == '\\' {
			j += 2
			continue
		}
		if s[j] == '"' {
			return j + 1
		}
		j += 1
	}
	return len(s)
}

// obj_value returns the raw text of `key`'s value, but only when `key` is a
// member of this object rather than of something nested inside it.
@(private)
obj_value :: proc(obj, key: string) -> (val: string, ok: bool) {
	depth := 0
	i := 0
	for i < len(obj) {
		switch obj[i] {
		case '{', '[':
			depth += 1
			i += 1
			continue
		case '}', ']':
			depth -= 1
			i += 1
			continue
		case '"':
			end := skip_string(obj, i)
			name := obj[i + 1:max(i + 1, end - 1)]
			// Is this a key? A colon follows a key, and only a key.
			j := end
			for j < len(obj) && (obj[j] == ' ' || obj[j] == '\t' || obj[j] == '\n' || obj[j] == '\r') {
				j += 1
			}
			if j < len(obj) && obj[j] == ':' {
				j += 1
				for j < len(obj) &&
				    (obj[j] == ' ' || obj[j] == '\t' || obj[j] == '\n' || obj[j] == '\r') {
					j += 1
				}
				if depth == 1 && name == key {
					return obj[j:value_end(obj, j)], true
				}
				i = value_end(obj, j)
				continue
			}
			i = end
			continue
		}
		i += 1
	}
	return "", false
}

// value_end is the index just past the value starting at `i`.
@(private)
value_end :: proc(obj: string, i: int) -> int {
	if i >= len(obj) {
		return len(obj)
	}
	if obj[i] == '"' {
		return skip_string(obj, i)
	}
	if obj[i] == '{' || obj[i] == '[' {
		depth := 0
		j := i
		for j < len(obj) {
			switch obj[j] {
			case '"':
				j = skip_string(obj, j)
				continue
			case '{', '[':
				depth += 1
			case '}', ']':
				depth -= 1
				if depth == 0 {
					return j + 1
				}
			}
			j += 1
		}
		return len(obj)
	}
	j := i
	for j < len(obj) && obj[j] != ',' && obj[j] != '}' && obj[j] != ']' {
		j += 1
	}
	return j
}

@(private)
obj_str :: proc(obj, key: string) -> string {
	v, ok := obj_value(obj, key)
	if !ok || len(v) < 2 || v[0] != '"' {
		return ""
	}
	return v[1:len(v) - 1]
}

@(private)
obj_int :: proc(obj, key: string) -> int {
	v, ok := obj_value(obj, key)
	if !ok {
		return 0
	}
	n, _ := strconv.parse_int(number_prefix(strings.trim_space(v)))
	return n
}

@(private)
obj_f32 :: proc(obj, key: string) -> f32 {
	v, ok := obj_value(obj, key)
	if !ok {
		return 0
	}
	f, _ := strconv.parse_f32(strings.trim_space(v))
	return f32(f)
}

@(private)
obj_bool :: proc(obj, key: string) -> bool {
	v, ok := obj_value(obj, key)
	return ok && strings.trim_space(v) == "true"
}

// number_prefix is the leading integer of a number that may be a float: scale
// is "1" on one compositor build and "1.000000" on the next.
@(private)
number_prefix :: proc(s: string) -> string {
	n := 0
	for n < len(s) && (s[n] == '-' || (s[n] >= '0' && s[n] <= '9')) {
		n += 1
	}
	return s[:n]
}

// ---------------------------------------------------------------------------
// Geometry
//
// slurp and grim agree on one spelling for a rectangle, "X,Y WxH", and this is
// both ends of it. Region capture runs the two tools separately rather than
// piping one into the other, so the chosen rectangle is a number this program
// holds: it can be shown, confined to the desktop, and used again without
// asking for another drag.
// ---------------------------------------------------------------------------

Rect :: struct {
	x, y, w, h: int,
}

geom_arg :: proc(r: Rect, al := context.temp_allocator) -> string {
	return fmt.aprintf("%d,%d %dx%d", r.x, r.y, r.w, r.h, allocator = al)
}

// parse_geom reads what slurp prints. It refuses a non-positive extent: grim
// -g on a zero-width rectangle writes a file with no pixels in it.
parse_geom :: proc(s: string) -> (r: Rect, ok: bool) {
	t := strings.trim_space(s)
	// Take the first line only; slurp is quiet but a shell wrapper is not.
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = strings.trim_space(t[:nl])
	}
	comma := strings.index_byte(t, ',')
	space := strings.index_byte(t, ' ')
	if comma <= 0 || space <= comma {
		return {}, false
	}
	x, xo := strconv.parse_int(strings.trim_space(t[:comma]))
	y, yo := strconv.parse_int(strings.trim_space(t[comma + 1:space]))
	size := strings.trim_space(t[space + 1:])
	ex := strings.index_byte(size, 'x')
	if ex <= 0 {
		return {}, false
	}
	w, wo := strconv.parse_int(strings.trim_space(size[:ex]))
	h, ho := strconv.parse_int(strings.trim_space(size[ex + 1:]))
	if !xo || !yo || !wo || !ho || w <= 0 || h <= 0 {
		return {}, false
	}
	return Rect{x, y, w, h}, true
}

output_rect :: proc(o: Output) -> Rect {
	return Rect{o.x, o.y, o.w, o.h}
}

// outputs_bounds is the union of every output: the whole desktop, which is
// what `grim` with no -o captures.
outputs_bounds :: proc(outs: []Output) -> (b: Rect, ok: bool) {
	if len(outs) == 0 {
		return {}, false
	}
	x0, y0 := max(int), max(int)
	x1, y1 := min(int), min(int)
	for o in outs {
		x0 = min(x0, o.x)
		y0 = min(y0, o.y)
		x1 = max(x1, o.x + o.w)
		y1 = max(y1, o.y + o.h)
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}, true
}

// rect_clamp keeps the part of `r` that lies inside `b`. False means the two
// do not overlap at all, which is what a stale saved region looks like after a
// monitor has been unplugged.
rect_clamp :: proc(r, b: Rect) -> (Rect, bool) {
	x0 := max(r.x, b.x)
	y0 := max(r.y, b.y)
	x1 := min(r.x + r.w, b.x + b.w)
	y1 := min(r.y + r.h, b.y + b.h)
	if x1 <= x0 || y1 <= y0 {
		return {}, false
	}
	return Rect{x0, y0, x1 - x0, y1 - y0}, true
}

// output_containing is the output a rectangle's centre sits on, or -1.
output_containing :: proc(outs: []Output, r: Rect) -> int {
	cx := r.x + r.w / 2
	cy := r.y + r.h / 2
	for o, i in outs {
		if cx >= o.x && cx < o.x + o.w && cy >= o.y && cy < o.y + o.h {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// The job
// ---------------------------------------------------------------------------

Job_Kind :: enum {
	None,
	Capture,
	Copy,
	Pick, // slurp, waiting for a rectangle to be dragged
}

Job :: struct {
	argv:     []string,
	kind:     Job_Kind,
	path:     string,
	out:      string,
	ok:       bool,
	running:  bool, // atomic
	finished: bool, // atomic
}

g_job: Job

job_busy :: proc() -> bool {
	return sync.atomic_load(&g_job.running)
}

job_kind :: proc() -> Job_Kind {
	if !job_busy() {
		return .None
	}
	return g_job.kind
}

@(private = "file")
job_worker :: proc() {
	out, ok := kit.run(g_job.argv, context.allocator)
	g_job.out = out
	g_job.ok = ok
	sync.atomic_store(&g_job.finished, true)
}

// job_start takes ownership of a heap-allocated argv.
job_start :: proc(kind: Job_Kind, path: string, argv: []string) -> bool {
	if job_busy() {
		for s in argv {delete(s)}
		delete(argv)
		return false
	}
	g_job.argv = argv
	g_job.kind = kind
	g_job.path = path
	g_job.out = ""
	g_job.ok = false
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, true)
	thread.create_and_start(job_worker, self_cleanup = true)
	return true
}

job_collect :: proc() -> (kind: Job_Kind, path, out: string, ok, got: bool) {
	if !sync.atomic_load(&g_job.running) || !sync.atomic_load(&g_job.finished) {
		return
	}
	kind = g_job.kind
	path = g_job.path
	out = g_job.out
	ok = g_job.ok
	got = true
	log_cmd(strings.join(g_job.argv, " ", context.temp_allocator), ok)
	for s in g_job.argv {delete(s)}
	delete(g_job.argv)
	g_job.argv = nil
	sync.atomic_store(&g_job.finished, false)
	sync.atomic_store(&g_job.running, false)
	return
}

argv_own :: proc(words: ..string) -> []string {
	out := make([]string, len(words))
	for w, i in words {
		out[i] = strings.clone(w)
	}
	return out
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

// stamp is the filename convention already in use on this machine:
// screenshot-2026-10-04_12-27-03.png
stamp :: proc(prefix: string, al := context.temp_allocator) -> string {
	t := time.now()
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.aprintf(
		"%s-%04d-%02d-%02d_%02d-%02d-%02d.png",
		prefix,
		y,
		int(mo),
		d,
		h,
		mi,
		s,
		allocator = al,
	)
}

pictures_dir :: proc() -> string {
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	return fmt.tprintf("%s/Pictures", home)
}

temp_path :: proc(n: int) -> string {
	return fmt.aprintf("/tmp/palmy-screenshot-%d-%d.png", os.get_pid(), n)
}

file_bytes :: proc(path: string) -> i64 {
	f, err := os.open(path)
	if err != nil {
		return 0
	}
	defer os.close(f)
	n, serr := os.file_size(f)
	if serr != nil {
		return 0
	}
	return n
}

// unique_path never names a file that already exists. This tool writes only
// into its own output directory, and even there it will not silently replace
// somebody else's file: screenshot-2026-10-04_12-27-03.png becomes
// ...-2.png, ...-3.png and so on. Overwriting is possible only by being told
// to, which nothing in this program currently does.
unique_path :: proc(dir, name: string, al := context.allocator) -> string {
	first := fmt.aprintf("%s/%s", dir, name, allocator = al)
	if !os.exists(first) {
		return first
	}
	stem := name
	ext := ""
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		stem, ext = name[:dot], name[dot:]
	}
	for n in 2 ..= 999 {
		cand := fmt.aprintf("%s/%s-%d%s", dir, stem, n, ext, allocator = al)
		if !os.exists(cand) {
			delete(first, al)
			return cand
		}
		delete(cand, al)
	}
	return first
}

// save_copy writes the capture into ~/Pictures. The bytes are copied rather
// than the file renamed, so a capture stays viewable in the preview whether or
// not it has been saved, and /tmp is still cleaned up on exit.
save_copy :: proc(src, dst: string) -> (ok: bool, err: string) {
	data, rerr := os.read_entire_file_from_path(src, context.temp_allocator)
	if rerr != nil {
		return false, "could not read the capture back"
	}
	if werr := os.write_entire_file(dst, data); werr != nil {
		return false, fmt.tprintf("could not write %s", dst)
	}
	return true, ""
}

// ---------------------------------------------------------------------------
// The command log
// ---------------------------------------------------------------------------

Log_Entry :: struct {
	cmd:  string,
	ok:   bool,
	used: bool,
}

LOG_N :: 48
g_log: [LOG_N]Log_Entry
g_log_at: int
g_log_count: int

log_cmd :: proc(cmd: string, ok: bool) {
	e := &g_log[g_log_at % LOG_N]
	if e.used {
		delete(e.cmd)
	}
	e^ = {cmd = strings.clone(cmd), ok = ok, used = true}
	g_log_at += 1
	g_log_count += 1
	fmt.eprintfln("[screenshot] %s%s", cmd, ok ? "" : "   (failed)")
}

log_recent :: proc(n: int, al := context.temp_allocator) -> []Log_Entry {
	count := min(n, min(g_log_count, LOG_N))
	out := make([]Log_Entry, count, al)
	for i in 0 ..< count {
		out[count - 1 - i] = g_log[(g_log_at - 1 - i + LOG_N * 4) % LOG_N]
	}
	return out
}
