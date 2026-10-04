package main

// Headless measurement.
//
//   video.bin <media> --measure <speed> <seconds>
//
// The real engine — real ffmpeg, real pw-cat, real reader threads, real audio
// clock — run for a fixed wall time at a fixed speed with no window at all,
// printing the numbers a screenshot cannot show. This is the instrument the
// speed work was built against: the clock arithmetic in `clock_from_bytes` is
// easy to write three plausible ways, and only one of them holds up here.
//
// Two decisions worth stating, because they decide what the numbers mean.
//
// The loop polls much faster than a display would. A window redraws at vsync,
// so a 60 fps clip at 2x needs 120 presentations a second from a 60 Hz
// compositor and cannot have them: half the frames would be reported dropped by
// definition, which measures the display, not the engine. Polling at 2 ms
// separates the two. The real app is still vsync bound, and `--measure` says so
// by printing the poll interval next to the delivered rate.
//
// And the error is reported twice: over every frame, and over only the frames
// presented after the sink's buffering was measured. For the first ~2.5 s the
// clock runs on a guessed 100 ms and every frame is systematically early or
// late by whatever the guess was wrong by. Averaging that in forever would
// flatter or libel the engine depending on the machine, so the second number is
// the one that describes steady state.

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"

measure_requested :: proc() -> (speed: f64, seconds: f64, poll_ms: f64, ok: bool) {
	args := os.args[1:]
	for a, i in args {
		if a != "--measure" {
			continue
		}
		speed, seconds, poll_ms = 1, 8, 2
		if i + 1 < len(args) {
			if v, good := strconv.parse_f64(args[i + 1]); good {
				speed = v
			}
		}
		if i + 2 < len(args) {
			if v, good := strconv.parse_f64(args[i + 2]); good {
				seconds = v
			}
		}
		// The poll interval decides what "dropped" means, so it is a knob
		// rather than a constant. 2 ms measures the engine; 16.667 ms is what
		// a 60 Hz window can actually ask for, and is the only setting whose
		// drop count is comparable to the running application's.
		if i + 3 < len(args) {
			if v, good := strconv.parse_f64(args[i + 3]); good && v > 0 {
				poll_ms = v
			}
		}
		return speed, seconds, poll_ms, true
	}
	return 0, 0, 0, false
}

// measure_strip drops the flag and its arguments, the same way shot_strip does,
// so the media path in front of it is still found.
measure_strip :: proc(args: []string) -> []string {
	for a, i in args {
		if a == "--measure" {
			return args[:i]
		}
	}
	return args
}

run_measure :: proc(path: string, speed, seconds, poll_ms: f64) -> int {
	poll := time.Duration(poll_ms * f64(time.Millisecond))
	m := probe_file(path)
	if !m.ok {
		fmt.eprintfln("measure: %s: %s", path, m.err != "" ? m.err : "cannot be read")
		return 1
	}

	e: Engine
	engine_init(&e, m)
	defer engine_destroy(&e)
	// Silence. The bytes still have to be written — they are the clock, and
	// pw-cat's back-pressure is the whole point — but a measurement run should
	// not play sound out of the machine it is measuring on. Volume is applied
	// to the samples, not to the sink, so this changes nothing the clock sees.
	engine_set_volume(&e, 0)
	e.speed = clamp(speed, SPEED_MIN, SPEED_MAX)
	// Decode at the source size: the point is to measure the pipeline, and a
	// smaller scale would quietly make the decoder's job easier.
	w := clamp(m.width & ~int(1), 16, 1920)
	h := clamp(m.height & ~int(1), 16, 1200)
	engine_open(&e, 0, w, h)

	fmt.printfln(
		"file=%s %dx%d@%.4ffps dur=%.2fs audio=%v",
		base_of(m.path),
		m.width,
		m.height,
		m.fps,
		m.duration,
		e.have_audio,
	)
	fmt.printfln("volume=0 (the bytes are the clock; the speakers are not needed)")
	fmt.printfln(
		"speed=%.4gx decode=%dx%d poll=%.1fms needs=%.1f fps of media per wall second",
		e.speed,
		e.w,
		e.h,
		poll_ms,
		m.fps * e.speed,
	)

	t0 := time.now()
	polls := 0
	for time.duration_seconds(time.since(t0)) < seconds {
		engine_tick(&e)
		engine_take(&e, engine_clock(&e))
		polls += 1
		if engine_finished(&e) {
			break
		}
		time.sleep(poll)
	}
	elapsed := time.duration_seconds(time.since(t0))

	shown, dropped, decoded, queued, _, _, _, lat, locked := engine_stats(&e)
	all_avg, all_max, all_n, lk_avg, lk_max, lk_n := engine_sync_stats(&e)
	clock := engine_clock(&e)

	fmt.printfln(
		"ran %.2fs wall, %d polls, clock reached %.3fs of media (%.3gx wall)",
		elapsed,
		polls,
		clock,
		clock / max(elapsed, 1e-6),
	)
	fmt.printfln(
		"frames shown=%d dropped=%d decoded=%d queued=%d",
		shown,
		dropped,
		decoded,
		queued,
	)
	fmt.printfln(
		"delivered=%.2f fps (decoder) presented=%.2f fps (to the screen) wanted=%.2f fps",
		f64(decoded) / max(elapsed, 1e-6),
		f64(shown) / max(elapsed, 1e-6),
		m.fps * e.speed,
	)
	// A frame is "dropped" when two of them fall due in one poll and only the
	// newer is shown. At a speed where the media's frame rate exceeds what the
	// poll can ask for, that is arithmetic rather than a shortfall — 120 fps of
	// media cannot be shown 60 times a second — so the floor is printed beside
	// the measurement to keep the two apart.
	askable := 1000 / max(poll_ms, 1e-6)
	floor := max(0.0, 1 - askable / max(m.fps * e.speed, 1e-6))
	fmt.printfln(
		"dropped=%.1f%% of %d due; unavoidable at this poll rate=%.1f%% (%.0f asks/s for %.0f frames/s)",
		100 * f64(dropped) / max(f64(shown + dropped), 1),
		shown + dropped,
		100 * floor,
		askable,
		m.fps * e.speed,
	)
	fmt.printfln(
		"sink buffering=%.1f ms%s",
		lat * 1000,
		locked ? " (measured)" : " (never locked: too short a run, or paused)",
	)
	// Media time is the right unit for a presentation error: it is the gap
	// between the media position of the picture and the media position of the
	// sound, which is what lip sync means at any speed. The wall equivalent is
	// that divided by the speed, and is printed beside it so neither reading
	// has to be inferred.
	fmt.printfln(
		"presentation error, all %d frames:   mean=%.2f ms worst=%.2f ms (media time)",
		all_n,
		all_avg * 1000,
		all_max * 1000,
	)
	fmt.printfln(
		"presentation error, %d after lock:   mean=%.2f ms worst=%.2f ms (media time)",
		lk_n,
		lk_avg * 1000,
		lk_max * 1000,
	)
	fmt.printfln(
		"                                     mean=%.2f ms worst=%.2f ms (wall time)",
		lk_avg * 1000 / max(e.speed, 1e-9),
		lk_max * 1000 / max(e.speed, 1e-9),
	)
	if !e.have_audio {
		fmt.println("note: no audio sink, so the clock is the wall clock and the error is self-referential")
	}
	return 0
}
