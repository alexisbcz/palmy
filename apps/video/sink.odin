package main

// Where the PCM goes, and a sink that is only a clock.
//
// A copy of apps/audio/sink.odin: the two engines share the design but not a
// package. The audio thread writes s16 stereo into a pipe and counts what the
// other end takes; that count is the master clock video frames are presented
// against. Normally the other end is `pw-cat`, and the count is a real device
// clock.
// That clock needs a sound device whose graph is running, which a headless
// machine does not have: in the build VM PipeWire 1.0.5 has a virtio sound
// card whose stream reports `ticks:0` forever, so pw-cat accepts one pipeful
// and then nothing — and its pw-cat has no `--raw` either, so it refuses the
// command line outright. The 2x clock-rate check failed on that, not on the
// engine.
//
// The null sink is the substitute. `PALMY_AUDIO_SINK=null` makes the engine
// start *this binary* as `--null-sink BPS` in pw-cat's place: a separate
// process at the far end of the same one-page pipe, which takes bytes exactly
// as fast as a sound card playing them would and throws them away. Everything
// on the near side — the pump, the back-pressure, the byte count, the sink
// outliving the track, the starvation stopwatch — runs unmodified, so a check
// that passes against it is a check of the engine, not of a stub. What it does
// not prove: that PipeWire itself buffers the way `lat_est` assumes, or that
// anything is audible. The self-test selects it unless the environment already
// names a sink, so `PALMY_AUDIO_SINK=pw-cat video --selftest` still measures a
// real device where there is one.
//
// The model of the device: it starts playing when the first byte arrives, plays
// `bps` bytes per second of wall time, and holds at most `NULL_HOLD` seconds of
// audio ahead of what it has played — the 40 ms the real sink is asked for. If
// it runs dry (a pause, a stall) it plays silence and resumes from where the
// data resumes, rather than swallowing the missed interval in one burst: that is
// what a real device does, and what keeps a paused clock frozen.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import kit "kit:."

NULL_HOLD :: 0.040

Sink_Kind :: enum {
	PipeWire,
	Null,
}

sink_kind :: proc() -> Sink_Kind {
	if os.get_env("PALMY_AUDIO_SINK", context.temp_allocator) == "null" {
		return .Null
	}
	return .PipeWire
}

@(private = "file")
pw_raw_checked: bool
@(private = "file")
pw_why: string

// sink_argv is the command the pump writes into. `ok` is false with a reason
// when no sink can be started, so the engine reports it instead of starting
// something that will accept one pipeful and stop.
sink_argv :: proc(rate, ch: int, latency: string) -> (argv: []string, why: string, ok: bool) {
	a := make([dynamic]string, context.temp_allocator)
	switch sink_kind() {
	case .Null:
		exe, err := os.get_executable_path(context.temp_allocator)
		if err != nil {
			exe = os.args[0]
		}
		append(&a, exe, "--null-sink", fmt.tprintf("%d", rate * ch * 2))
	case .PipeWire:
		if !pw_raw_checked {
			pw_raw_checked = true
			help, _ := kit.run({"sh", "-c", "pw-cat --help 2>&1"}, context.temp_allocator)
			if !strings.contains(help, "--playback") {
				pw_why = "pw-cat is not installed — no sound output"
			} else if !strings.contains(help, "--raw") {
				pw_why = "this pw-cat cannot play raw PCM (no --raw: PipeWire 1.2 or later)"
			}
		}
		if pw_why != "" {
			return nil, pw_why, false
		}
		append(
			&a,
			"pw-cat",
			"-p",
			"--raw",
			"--format",
			"s16",
			"--rate",
			fmt.tprintf("%d", rate),
			"--channels",
			fmt.tprintf("%d", ch),
			"--latency",
			latency,
			"-",
		)
	}
	return a[:], "", true
}

// null_sink_requested routes `--null-sink BPS`, which only the engine passes.
null_sink_requested :: proc() -> (bps: int, ok: bool) {
	if len(os.args) >= 3 && os.args[1] == "--null-sink" {
		n := 0
		for c in os.args[2] {
			if c < '0' || c > '9' {return 0, false}
			n = n * 10 + int(c - '0')
		}
		return n, n > 0
	}
	return 0, false
}

// null_sink_run consumes stdin at `bps` bytes per second until it closes.
null_sink_run :: proc(bps: int) -> int {
	buf: [4096]u8
	frame := 4
	consumed: i64 // bytes taken from the pipe
	anchor_t: time.Tick // the device position was anchor_b at anchor_t
	anchor_b: i64
	started := false
	for {
		want := len(buf)
		if started {
			pos := anchor_b + i64(time.duration_seconds(time.tick_since(anchor_t)) * f64(bps))
			due := pos + i64(NULL_HOLD * f64(bps))
			if consumed >= due {
				// Full: sleep until a quantum has been played.
				ahead := f64(consumed - due) / f64(bps)
				time.sleep(time.Duration((ahead + 0.004) * f64(time.Second)))
				continue
			}
			want = min(len(buf), int(due - consumed))
			want -= want % frame
			if want < frame {want = frame}
		}
		before := consumed
		n, err := os.read(os.stdin, buf[:want])
		if n <= 0 || err != nil {
			return 0
		}
		consumed += i64(n)
		if !started {
			started = true
			anchor_t = time.tick_now()
			anchor_b = 0
			continue
		}
		// Ran dry while waiting for that read: the device played silence, so
		// its position restarts from the data that just arrived.
		pos := anchor_b + i64(time.duration_seconds(time.tick_since(anchor_t)) * f64(bps))
		if pos > before {
			anchor_t = time.tick_now()
			anchor_b = before
		}
	}
}
