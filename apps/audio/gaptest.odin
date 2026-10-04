package main

// Measuring the gap.
//
//   audio.bin --gap-test A B [--restart] [--lead S]
//
// The only honest way to claim gapless playback is to measure the thing that
// would be audible if it were not. The pump is the sink's only source, so the
// quantity that matters is **sink starvation**: the wall-clock interval across
// a track boundary during which pw-cat was handed nothing. It begins at the
// last byte of the outgoing track and ends at the first byte of the incoming
// one. A stall shorter than what the sink is holding (its own measured
// buffering plus the 21 ms pipe) is covered and inaudible; everything beyond
// that is silence you can hear.
//
// `--restart` forces the old route — tear down ffmpeg *and* pw-cat, then start
// two fresh processes — through the same instrument, so a before and an after
// come off the same machine in the same minute.
//
// Three stopwatches run on the same boundary, because no single number is
// honest about both routes. All three start at the moment the last byte of the
// outgoing track completed its write:
//
//   starve_ms  to the pump *offering* the next track's first byte. This is the
//              real starvation figure: the only window in which the sink has
//              nothing available to it.
//   write_ms   to that byte being *accepted*. A write that blocks means the
//              pipe is full, which is the opposite of starvation, so this
//              reads one pipeful (21 ms) in healthy steady state and is kept
//              only as a cross-check. Measuring only this would have made
//              gapless playback look 21 ms worse than it is.
//   sink_ms    to more than a pipeful having gone through, which cannot happen
//              until pw-cat has really consumed something. A write into an
//              empty pipe succeeds whether or not the process on the other end
//              has finished starting, so this is the one that catches a sink
//              started from cold.
//
// And `buffer_kept` matters when reading them: on the gapless route the sink
// survives the boundary, so the audio it is holding genuinely covers a short
// stall. On the restart route pw-cat is killed, so its buffer is *discarded* —
// the stall is not covered by anything, and the tail of the outgoing track is
// lost with it.
//
// The volume is pinned to zero: a measurement must never make a noise.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

GAP_LEAD_DEFAULT :: 7.0

gap_test_requested :: proc() -> (a: string, b: string, restart: bool, lead: f64, ok: bool) {
	args := os.args[1:]
	at := -1
	for v, i in args {
		if v == "--gap-test" {
			at = i
			break
		}
	}
	if at < 0 {
		return "", "", false, 0, false
	}
	lead = GAP_LEAD_DEFAULT
	files := make([dynamic]string, context.temp_allocator)
	i := at + 1
	for i < len(args) {
		v := args[i]
		switch {
		case v == "--restart":
			restart = true
		case v == "--lead" && i + 1 < len(args):
			if f, good := strconv.parse_f64(args[i + 1]); good {
				lead = f
			}
			i += 1
		case strings.has_prefix(v, "-"):
		// an unrelated flag
		case:
			append(&files, v)
		}
		i += 1
	}
	if len(files) < 2 {
		return "", "", restart, lead, true // reported as a usage error below
	}
	return files[0], files[1], restart, lead, true
}

run_gap_test :: proc(patha, pathb: string, restart: bool, lead: f64) -> int {
	if patha == "" || pathb == "" {
		fmt.eprintln("usage: audio --gap-test <trackA> <trackB> [--restart] [--lead seconds]")
		return 2
	}
	ma := probe_file(absolute(patha))
	mb := probe_file(absolute(pathb))
	if !ma.ok {
		fmt.eprintfln("gap-test: %s: %s", patha, ma.err)
		return 2
	}
	if !mb.ok {
		fmt.eprintfln("gap-test: %s: %s", pathb, mb.err)
		return 2
	}

	e: Engine
	engine_init(&e)
	engine_set_volume(&e, 0)
	e.gap_watch = true
	e.hard_restart = restart

	// Start far enough from the end that the sink's own buffering gets
	// measured (it needs about two seconds of writes) before the boundary.
	at := max(0, ma.duration - lead)
	engine_start(&e, ma, at, 0)
	if !e.live {
		fmt.eprintfln("gap-test: %s", e.err == "" ? "the pipeline would not start" : e.err)
		return 2
	}

	t0 := time.now()
	switched := false
	for time.duration_seconds(time.since(t0)) < lead + 25 {
		engine_tick(&e)
		if !restart {
			if engine_prefetch_due(&e) {
				_ = engine_prefetch(&e, mb, 1)
			}
		}
		if engine_eof(&e) {
			if restart && !switched {
				// Exactly what play() used to do at every track change.
				engine_stop(&e)
				engine_start(&e, mb, 0, 1)
				switched = true
			} else {
				break
			}
		}
		// Stop as soon as the incoming track has been running for a moment,
		// so both measured intervals are definitely closed.
		if engine_gap(&e) >= 0 && engine_sink_gap(&e) >= 0 && engine_feeding_track(&e) == 1 {
			if _, tr := engine_position(&e); tr == 1 {
				break
			}
		}
		time.sleep(2 * time.Millisecond)
	}

	gap := engine_gap(&e)
	starve := engine_starvation(&e)
	sink := engine_sink_gap(&e)
	buffered := engine_buffered(&e)
	lat, locked := engine_latency(&e)
	_, joins := engine_stats(&e)
	// On the gapless route the sink survives the boundary, so the audio it was
	// holding really does cover a short stall. On the restart route pw-cat is
	// killed and that audio is discarded, so nothing covers the stall and the
	// whole of it is silence — plus however long the fresh pw-cat takes to
	// reach the speakers, which cannot be seen from this side of the pipe.
	audible := restart ? starve : max(0, starve - buffered)
	engine_stop(&e)

	if gap < 0 {
		fmt.eprintln("gap-test: no boundary was crossed; try a longer --lead")
		return 1
	}
	// One line, parseable, so a shell loop can run it twenty times.
	fmt.printfln(
		"gap-test mode=%s starve_ms=%.2f write_ms=%.2f sink_ms=%.2f buffered_ms=%.2f uncovered_ms=%.2f buffer_kept=%v lat_ms=%.2f locked=%v joins=%d",
		restart ? "restart" : "gapless",
		starve * 1000,
		gap * 1000,
		sink * 1000,
		buffered * 1000,
		audible * 1000,
		!restart,
		lat * 1000,
		locked,
		joins,
	)
	return 0
}
