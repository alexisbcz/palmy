package main

// Importing media: ffprobe for the facts, ffmpeg for a thumbnail and a
// waveform, all on a worker thread.
//
// Locking (one mutex, `Importer.mu`)
// ----------------------------------
// The importer is a queue in one direction and a handoff in the other. The UI
// thread appends paths to `queue`; the worker pops one, does every slow thing
// *with the lock released*, then pushes a finished `Import_Result` onto `done`
// under the lock. The UI thread drains `done` each frame and installs the
// result into `Project.media`, which only it ever touches.
//
// There is exactly one place that takes the lock per public procedure, and no
// procedure here calls another one that locks. That is the rule that keeps a
// self-deadlock impossible: slow work happens outside the lock, and the lock
// only ever guards two slices of plain data.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import p "palmy:."

THUMB_W :: 192

Probe :: struct {
	duration:  f64,
	width:     int,
	height:    int,
	fps:       f64,
	vcodec:    string,
	acodec:    string,
	has_video: bool,
	has_audio: bool,
	ok:        bool,
}

// probe_media runs ffprobe in its flat key=value form, which needs no JSON
// parser and cannot be confused by a codec name containing a comma.
probe_media :: proc(path: string, alloc := context.allocator) -> Probe {
	out, ok := run_capture(
		{
			"ffprobe",
			"-v",
			"error",
			"-show_entries",
			"format=duration",
			"-show_entries",
			"stream=index,codec_type,codec_name,width,height,r_frame_rate,channels,sample_rate",
			"-of",
			"default=noprint_wrappers=1",
			path,
		},
		context.temp_allocator,
	)
	if !ok || out == "" {
		return {}
	}

	pb := Probe{}
	// Streams arrive as blocks starting at `index=`; `duration=` belongs to
	// the format and comes last.
	cur_type := ""
	cur_codec := ""
	cur_w, cur_h := 0, 0
	cur_fps := f64(0)

	flush :: proc(pb: ^Probe, kind, codec: string, w, h: int, fps: f64, alloc: mem.Allocator) {
		switch kind {
		case "video":
			if !pb.has_video {
				pb.has_video = true
				pb.vcodec = strings.clone(codec, alloc)
				pb.width, pb.height = w, h
				pb.fps = fps
			}
		case "audio":
			if !pb.has_audio {
				pb.has_audio = true
				pb.acodec = strings.clone(codec, alloc)
			}
		}
	}

	for line in strings.split_lines_iterator(&out) {
		eq := strings.index_byte(line, '=')
		if eq < 0 {
			continue
		}
		key := line[:eq]
		val := line[eq + 1:]
		switch key {
		case "index":
			flush(&pb, cur_type, cur_codec, cur_w, cur_h, cur_fps, alloc)
			cur_type, cur_codec, cur_w, cur_h, cur_fps = "", "", 0, 0, 0
		case "codec_type":
			cur_type = val
		case "codec_name":
			cur_codec = val
		case "width":
			cur_w, _ = strconv.parse_int(val, 10)
		case "height":
			cur_h, _ = strconv.parse_int(val, 10)
		case "r_frame_rate":
			cur_fps = parse_rational(val)
		case "duration":
			pb.duration, _ = strconv.parse_f64(val)
		}
	}
	flush(&pb, cur_type, cur_codec, cur_w, cur_h, cur_fps, alloc)

	if pb.fps <= 0 {
		pb.fps = 30
	}
	pb.ok = pb.duration > 0 && (pb.has_video || pb.has_audio)
	return pb
}

parse_rational :: proc(s: string) -> f64 {
	if i := strings.index_byte(s, '/'); i >= 0 {
		n, _ := strconv.parse_f64(s[:i])
		d, _ := strconv.parse_f64(s[i + 1:])
		if d == 0 {
			return 0
		}
		return n / d
	}
	v, _ := strconv.parse_f64(s)
	return v
}

// extract_thumb grabs one frame as a PNG on stdout and decodes it in process,
// so nothing is left behind in /tmp.
extract_thumb :: proc(path: string, at: f64, width: int) -> (img: p.Image, ok: bool) {
	png, good := run_capture_bytes(
		{
			"ffmpeg",
			"-v",
			"error",
			"-ss",
			fmt.tprintf("%.3f", at),
			"-i",
			path,
			"-frames:v",
			"1",
			"-vf",
			fmt.tprintf("scale=%d:-2", width),
			"-f",
			"image2pipe",
			"-vcodec",
			"png",
			"-",
		},
		context.temp_allocator,
	)
	if !good || len(png) == 0 {
		return {}, false
	}
	return p.decode_image(png)
}

// extract_peaks reads mono 16-bit PCM at 8 kHz and reduces it to a peak per
// bucket. 8 kHz is plenty: a waveform drawn 60 pixels tall cannot show more.
extract_peaks :: proc(path: string, duration: f64) -> []f32 {
	raw, ok := run_capture_bytes(
		{"ffmpeg", "-v", "error", "-i", path, "-f", "s16le", "-ac", "1", "-ar", "8000", "-"},
		context.temp_allocator,
	)
	if !ok || len(raw) < 2 {
		return nil
	}
	samples := len(raw) / 2
	rate := 8000
	nbuckets := max(1, int(f64(samples) / f64(rate) * PEAKS_PER_SEC))
	peaks := make([]f32, nbuckets)
	for b in 0 ..< nbuckets {
		s0 := b * samples / nbuckets
		s1 := max(s0 + 1, (b + 1) * samples / nbuckets)
		if s1 > samples {
			s1 = samples
		}
		peak := i32(0)
		for s in s0 ..< s1 {
			v := i32(i16(u16(raw[s * 2]) | (u16(raw[s * 2 + 1]) << 8)))
			if v < 0 {
				v = -v
			}
			if v > peak {
				peak = v
			}
		}
		peaks[b] = f32(peak) / 32768.0
	}
	return peaks
}

// ---------------------------------------------------------------------------
// The importer thread
// ---------------------------------------------------------------------------

Import_Result :: struct {
	path:     string,
	name:     string,
	probe:    Probe,
	thumb:    p.Image,
	thumb_ok: bool,
	peaks:    []f32,
	ms:       f64,
	ok:       bool,
}

Importer :: struct {
	mu:      sync.Mutex,
	sem:     sync.Sema,
	quit:    bool,
	worker:  ^thread.Thread,
	queue:   [dynamic]string,
	done:    [dynamic]Import_Result,
	busy:    bool,
}

importer_start :: proc(im: ^Importer) {
	im.worker = thread.create(importer_main)
	im.worker.data = rawptr(im)
	thread.start(im.worker)
}

importer_stop :: proc(im: ^Importer) {
	sync.lock(&im.mu)
	im.quit = true
	sync.unlock(&im.mu)
	sync.sema_post(&im.sem)
	if im.worker != nil {
		thread.join(im.worker)
		thread.destroy(im.worker)
		im.worker = nil
	}
}

importer_push :: proc(im: ^Importer, path: string) {
	cloned := strings.clone(path)
	sync.lock(&im.mu)
	append(&im.queue, cloned)
	sync.unlock(&im.mu)
	sync.sema_post(&im.sem)
}

// importer_drain moves every finished result to the caller, which then owns
// the images and peak slices.
importer_drain :: proc(im: ^Importer, out: ^[dynamic]Import_Result) {
	sync.lock(&im.mu)
	for r in im.done {
		append(out, r)
	}
	clear(&im.done)
	sync.unlock(&im.mu)
}

importer_busy :: proc(im: ^Importer) -> bool {
	sync.lock(&im.mu)
	defer sync.unlock(&im.mu)
	return im.busy || len(im.queue) > 0 || len(im.done) > 0
}

@(private)
importer_main :: proc(t: ^thread.Thread) {
	im := (^Importer)(t.data)
	for {
		free_all(context.temp_allocator)

		sync.lock(&im.mu)
		if im.quit {
			sync.unlock(&im.mu)
			return
		}
		if len(im.queue) == 0 {
			im.busy = false
			sync.unlock(&im.mu)
			sync.sema_wait(&im.sem)
			continue
		}
		path := im.queue[0]
		ordered_remove(&im.queue, 0)
		im.busy = true
		sync.unlock(&im.mu)

		// Everything below runs with no lock held.
		res := import_media(path)

		sync.lock(&im.mu)
		append(&im.done, res)
		sync.unlock(&im.mu)
	}
}

// import_media is the whole of importing one file: probe it, then derive the
// thumbnail and the waveform. The importer thread runs it for the window and
// the command line (`videoedit new`, `videoedit add`) runs it directly, so a
// clip imported either way is the same row. `derived = false` skips the
// thumbnail and the waveform, which only the window draws; the probe — the
// part a project file and an export depend on — is identical. `path` becomes
// the result's, as it always did on the importer's queue.
import_media :: proc(path: string, derived := true) -> Import_Result {
	t0 := time.now()
	res := Import_Result {
		path = path,
		name = strings.clone(filepath.base(path)),
	}
	res.probe = probe_media(path)
	if res.probe.ok {
		if derived && res.probe.has_video {
			at := min(res.probe.duration * 0.25, 2.0)
			res.thumb, res.thumb_ok = extract_thumb(path, at, THUMB_W)
		}
		if derived && res.probe.has_audio {
			res.peaks = extract_peaks(path, res.probe.duration)
		}
		res.ok = true
	}
	res.ms = time.duration_milliseconds(time.since(t0))
	return res
}

// install_import turns a finished result into a Media entry, or returns -1.
install_import :: proc(pr: ^Project, r: Import_Result) -> int {
	if !r.ok {
		delete(r.path)
		delete(r.name)
		delete(r.peaks)
		return -1
	}
	// Already in the bin? Keep the row but adopt anything it is missing. A
	// loaded project has media rows with no thumbnail and no waveform — those
	// are derived data, not saved — and re-probing is how they come back, so
	// this path has to install them rather than throw them away.
	for &m, i in pr.media {
		if m.path != r.path {
			continue
		}
		delete(r.path)
		delete(r.name)
		if r.thumb_ok && !m.thumb_ok {
			m.thumb = r.thumb
			m.thumb_ok = true
		} else {
			t := r.thumb
			if t.px != nil {
				p.image_destroy(&t)
			}
		}
		if r.peaks != nil && m.peaks == nil {
			m.peaks = r.peaks
		} else {
			delete(r.peaks)
		}
		if !m.probed {
			m.duration = r.probe.duration
			m.width, m.height, m.fps = r.probe.width, r.probe.height, r.probe.fps
			m.has_video, m.has_audio = r.probe.has_video, r.probe.has_audio
			delete(m.vcodec)
			delete(m.acodec)
			m.vcodec, m.acodec = r.probe.vcodec, r.probe.acodec
			m.probed = true
		} else {
			delete(r.probe.vcodec)
			delete(r.probe.acodec)
		}
		return i
	}
	append(
		&pr.media,
		Media {
			path = r.path,
			name = r.name,
			duration = r.probe.duration,
			width = r.probe.width,
			height = r.probe.height,
			fps = r.probe.fps,
			vcodec = r.probe.vcodec,
			acodec = r.probe.acodec,
			has_video = r.probe.has_video,
			has_audio = r.probe.has_audio,
			thumb = r.thumb,
			thumb_ok = r.thumb_ok,
			peaks = r.peaks,
			probed = true,
		},
	)
	return len(pr.media) - 1
}

// ---------------------------------------------------------------------------
// Running commands
// ---------------------------------------------------------------------------

// run_capture_bytes runs a command and returns its whole stdout. Unlike
// kit.run it does not trim, because a PNG and a PCM stream are not text.
run_capture_bytes :: proc(argv: []string, alloc := context.allocator) -> ([]u8, bool) {
	state, sout, serr, err := os.process_exec({command = argv}, alloc)
	if err != nil {
		return nil, false
	}
	delete(serr, alloc)
	if state.exit_code != 0 {
		delete(sout, alloc)
		return nil, false
	}
	return sout, true
}

run_capture :: proc(argv: []string, alloc := context.allocator) -> (string, bool) {
	b, ok := run_capture_bytes(argv, alloc)
	if !ok {
		return "", false
	}
	return string(b), true
}
