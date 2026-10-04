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
	out := make([dynamic]Output, 0, 4, al)
	// A deliberately small reader: the five fields wanted out of hyprctl's
	// monitor objects are all flat, so the JSON is walked rather than parsed.
	rest := text
	for {
		i := strings.index(rest, "\"name\":")
		if i < 0 {
			break
		}
		rest = rest[i + 7:]
		name := json_string(&rest)
		o := Output {
			name = strings.clone(name, al),
		}
		block := rest
		if nxt := strings.index(block, "\"name\":"); nxt > 0 {
			block = block[:nxt]
		}
		o.desc = strings.clone(json_str_field(block, "description"), al)
		o.w = json_int_field(block, "width")
		o.h = json_int_field(block, "height")
		o.x = json_int_field(block, "x")
		o.y = json_int_field(block, "y")
		o.scale = f32(json_int_field(block, "scale"))
		o.focused = strings.index(block, "\"focused\": true") >= 0
		if o.name != "" && o.w > 0 {
			append(&out, o)
		}
	}
	return out[:]
}

@(private)
json_string :: proc(rest: ^string) -> string {
	s := rest^
	q := strings.index_byte(s, '"')
	if q < 0 {
		rest^ = ""
		return ""
	}
	s = s[q + 1:]
	e := strings.index_byte(s, '"')
	if e < 0 {
		rest^ = ""
		return ""
	}
	val := s[:e]
	rest^ = s[e + 1:]
	return val
}

@(private)
json_str_field :: proc(block, key: string) -> string {
	needle := fmt.tprintf("\"%s\":", key)
	i := strings.index(block, needle)
	if i < 0 {
		return ""
	}
	r := block[i + len(needle):]
	return json_string(&r)
}

@(private)
json_int_field :: proc(block, key: string) -> int {
	needle := fmt.tprintf("\"%s\":", key)
	i := strings.index(block, needle)
	if i < 0 {
		return 0
	}
	r := strings.trim_space(block[i + len(needle):])
	n := 0
	for n < len(r) && (r[n] == '-' || (r[n] >= '0' && r[n] <= '9')) {
		n += 1
	}
	v, _ := strconv.parse_int(r[:n])
	return v
}

// ---------------------------------------------------------------------------
// The job
// ---------------------------------------------------------------------------

Job_Kind :: enum {
	None,
	Capture,
	Copy,
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
