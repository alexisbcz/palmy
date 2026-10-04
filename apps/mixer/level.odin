package main

// The input level meter.
//
// PipeWire does not publish a peak level through `wpctl` or `pactl`, so the
// only honest way to show one is to open the source and look at the samples.
// That means recording from the user's microphone, which this applet will not
// do on its own: the meter is off until somebody presses M, it says in the
// window exactly what command is running while it is on, and it stops when the
// window closes.
//
// `parec` writes raw mono s16 to a file; the frame reads the tail of that file
// and computes a peak and an RMS over the last 25 ms. Nothing blocks: a read
// of the last few kilobytes of a local file is a couple of microseconds, and
// if parec has not written anything yet the meter simply says so.

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

RATE :: 8000 // plenty for a level meter, and 16 kB/s on disk
WINDOW :: 200 // samples per reading: 25 ms
TAIL :: WINDOW * 2 // bytes

// parec appends forever, so the capture is restarted once the file passes
// this. At 16 kB/s that is about four minutes.
MAX_BYTES :: 4 << 20

Level :: struct {
	on:       bool,
	source:   string, // the node name being listened to
	path:     string,
	proc_:    os.Process,
	have:     bool,
	peak:     f32, // 0..1
	rms:      f32,
	hold:     f32, // a decaying peak-hold, for the needle
	err:      string,
	bytes:    i64,
	// A short history, so the meter reads as a signal rather than a number.
	hist:     [120]f32,
	at:       int,
	n:        int,
}

level_cmd :: proc(l: ^Level) -> string {
	return fmt.tprintf(
		"parec --device=%s --format=s16le --rate=%d --channels=1 --latency-msec=50",
		l.source,
		RATE,
	)
}

// level_start opens the source. Returns false when parec is missing.
level_start :: proc(l: ^Level, source: string) -> bool {
	level_stop(l)
	if source == "" {
		l.err = "no input device selected"
		return false
	}
	l.source = strings.clone(source)
	l.path = fmt.aprintf("/tmp/palmy-mixer-level-%d.raw", os.get_pid())
	// Truncate anything left from a previous run.
	os.remove(l.path)

	sh := fmt.tprintf("exec %s > %s", level_cmd(l), l.path)
	p, err := os.process_start({command = {"sh", "-c", sh}})
	if err != nil {
		l.err = "could not start parec"
		return false
	}
	l.proc_ = p
	l.on = true
	l.err = ""
	l.have = false
	l.n, l.at = 0, 0
	log_cmd(level_cmd(l), true)
	return true
}

level_stop :: proc(l: ^Level) {
	if !l.on {
		return
	}
	_ = os.process_kill(l.proc_)
	// Reap it, so the applet does not leave a zombie behind.
	_, _ = os.process_wait(l.proc_, 0)

	if l.path != "" {
		os.remove(l.path)
		delete(l.path)
		l.path = ""
	}
	if l.source != "" {
		delete(l.source)
		l.source = ""
	}
	l.on = false
	l.have = false
	l.peak, l.rms, l.hold = 0, 0, 0
	log_cmd("kill parec", true)
}

// level_poll reads the tail of the capture. Called once a frame; it opens,
// reads 400 bytes at an offset and closes, which costs a few microseconds.
level_poll :: proc(l: ^Level, dt: f32) {
	// The hold needle falls back at a fixed rate whatever else happens.
	l.hold = max(0, l.hold - dt * 0.7)
	if !l.on {
		return
	}

	f, err := os.open(l.path)
	if err != nil {
		return
	}
	defer os.close(f)

	size, serr := os.file_size(f)
	if serr != nil || size < TAIL {
		return
	}
	l.bytes = size

	buf: [TAIL]u8
	// Start on an even byte so the frames line up with the sample boundaries.
	off := (size - TAIL) & ~i64(1)
	n, rerr := os.read_at(f, buf[:], off)
	if rerr != nil && n < 2 {
		return
	}

	peak: f32 = 0
	sum: f64 = 0
	count := n / 2
	for i in 0 ..< count {
		s := i16(u16(buf[i * 2]) | (u16(buf[i * 2 + 1]) << 8))
		v := f32(s) / 32768
		peak = max(peak, abs(v))
		sum += f64(v) * f64(v)
	}
	if count == 0 {
		return
	}
	l.peak = peak
	l.rms = f32(math.sqrt(sum / f64(count)))
	l.hold = max(l.hold, peak)
	l.have = true

	l.hist[l.at] = peak
	l.at = (l.at + 1) % len(l.hist)
	if l.n < len(l.hist) {
		l.n += 1
	}

	// Restart rather than fill the disk.
	if size > MAX_BYTES {
		src := strings.clone(l.source, context.temp_allocator)
		level_start(l, src)
	}
}

level_hist_at :: proc(l: ^Level, i: int) -> f32 {
	if l.n == 0 {
		return 0
	}
	start := l.n < len(l.hist) ? 0 : l.at
	return l.hist[(start + i) % len(l.hist)]
}

// db renders a linear amplitude the way a meter is read.
db_label :: proc(v: f32) -> string {
	if v <= 0.0001 {
		return "silent"
	}
	return fmt.tprintf("%.1f dB", 20 * math.log10(v))
}
