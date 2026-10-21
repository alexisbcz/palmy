// Progress and background jobs, for commands that take a while.
//
// The convention's first rule is that stdout carries the result and nothing
// else, so progress cannot go there: a long command reports on stderr, as one
// JSON object per line under --json (NDJSON, which is what apps/ai already
// reads from ollama) and as a short line of text otherwise. The final result
// is still the one document on stdout.
//
// A command that outlives its caller — a download, a sync, a render — is a
// job: it writes a small record to $XDG_RUNTIME_DIR/palm/jobs (or $PALM_JOBS)
// when it starts, rewrites it as it goes, and marks it finished at the end.
// Another command, or another program, reads those records with `cli_jobs`
// rather than each application inventing its own status file.
//
//	job := kit.cli_job_begin(c, "fetch inbox")
//	for i in 0 ..< n {
//		...
//		kit.cli_job_progress(&job, i + 1, n)
//	}
//	kit.cli_job_end(&job, kit.EXIT_OK)
package kit

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// cli_progress reports how far a command has got, on stderr. `total` may be
// 0 when it is not known.
cli_progress :: proc(c: ^Call, done, total: int, what := "") {
	noun := c != nil && c.surface != nil ? c.surface.noun : ""
	verb := c != nil && c.cmd != nil ? c.cmd.verb : ""
	if c != nil && c.json {
		o := jobj(context.temp_allocator)
		p := jobj(context.temp_allocator)
		jset_str(p, "command", strings.trim_space(fmt.tprintf("%s %s", noun, verb)), context.temp_allocator)
		jset_int(p, "done", done, context.temp_allocator)
		jset_int(p, "total", total, context.temp_allocator)
		if what != "" {
			jset_str(p, "what", scrub_text(what, c.secrets), context.temp_allocator)
		}
		jset(o, "progress", p, context.temp_allocator)
		fmt.eprintln(json_text(o, 0, context.temp_allocator))
		return
	}
	label := what != "" ? what : strings.trim_space(fmt.tprintf("%s %s", noun, verb))
	if c != nil {
		label = scrub_text(label, c.secrets)
	}
	if total > 0 {
		fmt.eprintfln("[%s] %s %d/%d (%d%%)", noun, label, done, total, done * 100 / total)
	} else {
		fmt.eprintfln("[%s] %s %d", noun, label, done)
	}
}

// Job is one long-running command's record.
Job :: struct {
	id:      string, // <noun>-<pid>-<start>, unique on this machine
	path:    string, // the record on disk; "" when it could not be written
	noun:    string,
	verb:    string,
	what:    string,
	started: string,
	done:    int,
	total:   int,
	call:    ^Call,
}

// cli_jobs_dir is where job records live: $PALM_JOBS, else
// $XDG_RUNTIME_DIR/palm/jobs, else /tmp/palm-jobs-<uid-less fallback>.
cli_jobs_dir :: proc(allocator := context.allocator) -> string {
	if p := os.get_env("PALM_JOBS", context.temp_allocator); p != "" {
		return strings.clone(p, allocator)
	}
	if r := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator); r != "" {
		return fmt.aprintf("%s/palm/jobs", r, allocator = allocator)
	}
	return strings.clone("/tmp/palm-jobs", allocator)
}

// cli_job_begin starts a job record for the command in progress.
cli_job_begin :: proc(c: ^Call, what: string) -> Job {
	j: Job
	j.call = c
	j.noun = c != nil && c.surface != nil ? strings.clone(c.surface.noun) : ""
	j.verb = c != nil && c.cmd != nil ? strings.clone(c.cmd.verb) : ""
	j.what = strings.clone(c != nil ? scrub_text(what, c.secrets) : what)
	t := time.now()
	j.started = job_time(t)
	j.id = fmt.aprintf("%s-%d-%d", j.noun == "" ? "job" : j.noun, os.get_pid(), time.to_unix_nanoseconds(t) / 1_000_000)
	dir := cli_jobs_dir(context.temp_allocator)
	if os.make_directory_all(dir) == nil || os.is_dir(dir) {
		j.path = fmt.aprintf("%s/%s.json", dir, j.id)
	}
	job_write(&j, "running", -1)
	return j
}

// cli_job_progress records how far the job has got, and reports it as
// cli_progress does.
cli_job_progress :: proc(j: ^Job, done, total: int, what := "") {
	j.done = done
	j.total = total
	job_write(j, "running", -1)
	cli_progress(j.call, done, total, what != "" ? what : j.what)
}

// cli_job_end marks the job finished with an exit code. The record stays, so
// a caller that comes back later can read how it ended; cli_job_forget
// removes it.
cli_job_end :: proc(j: ^Job, code: int) {
	job_write(j, code == EXIT_OK ? "done" : "failed", code)
}

// cli_job_forget removes a job's record.
cli_job_forget :: proc(j: ^Job) {
	if j.path != "" {
		os.remove(j.path)
	}
}

// cli_jobs is every job record, optionally of one noun, as an array of
// objects. A record still marked running whose process has gone is reported
// as `lost`, which is the truth about it.
cli_jobs :: proc(noun := "", allocator := context.allocator) -> ^Json {
	out := jarr(allocator)
	dir := cli_jobs_dir(context.temp_allocator)
	f, err := os.open(dir)
	if err != nil {
		return out
	}
	defer os.close(f)
	infos, _ := os.read_dir(f, -1, context.temp_allocator)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".json") {
			continue
		}
		data, rerr := os.read_entire_file_from_path(fi.fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		v, perr := json.parse_string(string(data), json.DEFAULT_SPECIFICATION, true, context.temp_allocator)
		if perr != nil {
			continue
		}
		obj, ok := v.(json.Object)
		if !ok {
			continue
		}
		if noun != "" {
			if n, is_s := obj["noun"].(json.String); !is_s || string(n) != noun {
				continue
			}
		}
		rec := jobj(allocator)
		for key in ([?]string{"id", "noun", "verb", "what", "started", "updated", "state"}) {
			if sv, is_s := obj[key].(json.String); is_s {
				jset_str(rec, key, string(sv), allocator)
			}
		}
		for key in ([?]string{"pid", "done", "total", "code"}) {
			#partial switch nv in obj[key] {
			case json.Integer:
				jset_i64(rec, key, i64(nv), allocator)
			case json.Float:
				jset_i64(rec, key, i64(nv), allocator)
			}
		}
		if st, is_s := obj["state"].(json.String); is_s && string(st) == "running" {
			if pid, is_i := obj["pid"].(json.Integer); is_i && !os.exists(fmt.tprintf("/proc/%d", pid)) {
				jset_str(rec, "state", "lost", allocator)
			}
		}
		jpush(out, rec)
	}
	return out
}

@(private = "file")
job_time :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.aprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

@(private = "file")
job_write :: proc(j: ^Job, state: string, code: int) {
	if j.path == "" {
		return
	}
	a := context.temp_allocator
	o := jobj(a)
	jset_str(o, "id", j.id, a)
	jset_str(o, "noun", j.noun, a)
	jset_str(o, "verb", j.verb, a)
	jset_str(o, "what", j.what, a)
	jset_int(o, "pid", os.get_pid(), a)
	jset_str(o, "started", j.started, a)
	jset_str(o, "updated", job_time(time.now()), a)
	jset_str(o, "state", state, a)
	jset_int(o, "done", j.done, a)
	jset_int(o, "total", j.total, a)
	if code >= 0 {
		jset_int(o, "code", code, a)
	}
	// Written beside and renamed over, so a reader never sees half a record.
	tmp := fmt.tprintf("%s.tmp", j.path)
	if os.write_entire_file(tmp, transmute([]u8)json_text(o, 2, a)) != nil {
		return
	}
	os.rename(tmp, j.path)
}
