package call

// ---------------------------------------------------------------------------
// The video path.
//
//	capture process ──pipe──▶ MJPEG splitter ──▶ fragmenter ──▶ UDP
//	UDP ──▶ reassembler ──▶ stb_image ──▶ palmy Image ──▶ p.draw_image
//
// The codec is Motion JPEG, chosen because it is the one video format where
// every piece already exists and none of it is a shim: ffmpeg encodes it
// natively, each frame is independent so a lost frame costs exactly one frame
// rather than a second of smeared prediction, and palmy already decodes JPEG
// through stb_image — which means the receive side is `decode_image` and
// `draw_image` and nothing in between.
//
// What that costs, stated plainly: there is no inter-frame prediction, so a
// 480x270 frame is 12-20 KB where H.264 would be 2 KB. At 30 fps that is
// roughly 3.5 Mbit/s. Over loopback it does not matter; over a real network it
// would, and the honest fix is a real video codec rather than a lower frame
// rate pretending to be one.
//
// Framing on the pipe: a raw MJPEG stream is JPEGs back to back, each starting
// FF D8 and ending FF D9. The splitter scans for the end marker from where it
// last left off, so the cost is linear in bytes and the latency is one frame.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:slice"
import p "palmy:."

// The call resolution. 640x360 is 16:9, encodes to about 16 KB a frame and
// decodes in under a millisecond, and fills the video tile of a 1180-point
// window without upscaling.
//
// It is a variable rather than a constant so `--video WxH@FPS` can ask for
// more and the measured frame rate can answer honestly. Measured end to end
// over loopback, at 30 fps requested:
//
//	 480x270   30.0 fps    9.6 KB/frame   0.58 ms to decode    2.6 Mbit/s
//	 640x360   29.9 fps   15.1 KB/frame   0.94 ms to decode    3.9 Mbit/s
//	 960x540   29.9 fps   24.1 KB/frame   1.78 ms to decode    6.4 Mbit/s
//	1280x720   30.0 fps   41.0 KB/frame   2.78 ms to decode   10.7 Mbit/s
//
// Zero dropped frames and zero partial reassemblies at every one of those, so
// the default is a choice about picture quality and bandwidth, not a ceiling
// the architecture imposed.
v_width := 640
v_height := 360
v_fps := 30
V_QUALITY :: "6" // ffmpeg -q:v, 2 best .. 31 worst

// A frame over 400 KB is not a frame; something has gone wrong with the
// splitter and the accumulator should be dropped rather than grown.
V_MAX_FRAME :: 400 * 1024

Video :: struct {
	cap:   Child,
	accum: [dynamic]u8,
	scan:  int, // where the FF D9 search resumes

	reasm: Reassembler,

	// The decoded remote frame, blitted by the UI. Double-buffered so a
	// half-decoded image is never on screen.
	remote:     p.Image,
	has_remote: bool,

	// The self-view is our own captured JPEG decoded locally. It costs a
	// second decode per frame, so it runs at a divided rate: the picture-in-
	// picture is 160 points wide and nobody can see 30 fps in it.
	local:     p.Image,
	has_local: bool,
	local_div: int,
	local_n:   int,

	camera_off: bool,

	// Measured, not configured.
	frames_captured: int,
	frames_sent:     int,
	frames_decoded:  int,
	frames_failed:   int,
	last_jpeg_bytes: int,

	fps_tx:    f32,
	fps_rx:    f32,
	fps_at:    f64,
	fps_tx0:   int,
	fps_rx0:   int,

	// Decode cost, exponentially smoothed, in milliseconds.
	decode_ms: f32,
	// Capture-to-rendered, microseconds, from the packet timestamp.
	latency_us:     f64,
	latency_sum_us: f64,
	latency_n:      int,

	source_label: string,
	cap_error:    string,
}

// ---------------------------------------------------------------------------
// Capture command
// ---------------------------------------------------------------------------

// The synthetic pattern. ffmpeg's testsrc2 by default: a moving pattern with a
// frame counter and a sweeping bar, so one still from a recording proves
// motion and a pair of stills proves the frame rate.
//
// It is overridable so the two ends of a call can look different. Watching one
// instance show the other's picture is only convincing if the two pictures are
// not the same picture.
synth_source := "testsrc2"

synth_pattern :: proc() -> string {
	// `realtime` paces on the frame count, the way `arealtime` paces the
	// synthetic microphone; `-re` gates on wall clock and runs fast.
	return fmt.tprintf("%s=size=%dx%d:rate=%d,realtime", synth_source, v_width, v_height, v_fps)
}

video_capture_argv :: proc(dev: Device) -> []string {
	if dev.kind == .Synthetic {
		return slice.clone([]string{
			"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
			"-f", "lavfi", "-i", synth_pattern(),
			"-q:v", V_QUALITY, "-f", "mjpeg", "-",
		}, context.temp_allocator)
	}
	// A real camera. The Brio advertises YUYV and MJPG at 640x480/30; let
	// ffmpeg negotiate and scale down to the call resolution.
	return slice.clone([]string{
		"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
		"-f", "v4l2", "-framerate", fmt.tprintf("%d", v_fps), "-video_size", "640x480",
		"-i", dev.path,
		"-vf", fmt.tprintf("scale=%d:%d", v_width, v_height),
		"-q:v", V_QUALITY, "-f", "mjpeg", "-",
	}, context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

video_init :: proc(v: ^Video) {
	v.accum = make([dynamic]u8, 0, 128 * 1024)
	v.local_div = 3 // the self-view runs at 10 fps
	reasm_init(&v.reasm)
}

video_destroy :: proc(v: ^Video) {
	video_stop(v)
	delete(v.accum)
	reasm_destroy(&v.reasm)
	if v.has_remote {
		p.image_destroy(&v.remote)
	}
	if v.has_local {
		p.image_destroy(&v.local)
	}
}

video_start :: proc(v: ^Video, dev: Device) {
	video_stop(v)
	clear(&v.accum)
	v.scan = 0
	// A new call means a new frame-id sequence at both ends.
	reasm_reset(&v.reasm)
	argv := video_capture_argv(dev)
	// Two frames of pipe. A JPEG is ~15 KB, so 64 KiB would be four frames of
	// backlog before we even look.
	c, err := spawn_reader(argv, 48 * 1024)
	if err != "" {
		v.cap_error = err
	} else {
		v.cap = c
		v.cap_error = ""
	}
	v.source_label = dev.name
}

video_stop :: proc(v: ^Video) {
	child_stop(&v.cap)
}

// ---------------------------------------------------------------------------
// Split, encode-side
// ---------------------------------------------------------------------------

// next_jpeg finds a complete JPEG at the front of the accumulator, returning
// its length including the FF D9 end marker.
//
// Scanning for the end marker rather than for the *next* start marker is worth
// one whole frame of latency: waiting for the next SOI means a frame cannot be
// sent until its successor has started arriving.
next_jpeg :: proc(v: ^Video) -> (n: int, ok: bool) {
	b := v.accum[:]
	if len(b) < 4 {
		return 0, false
	}
	// Resynchronise if the stream does not start on a marker, which happens
	// once if ffmpeg ever writes a partial header.
	if !(b[0] == 0xFF && b[1] == 0xD8) {
		for i in 0 ..< len(b) - 1 {
			if b[i] == 0xFF && b[i + 1] == 0xD8 {
				remove_range(&v.accum, 0, i)
				v.scan = 0
				return 0, false
			}
		}
		clear(&v.accum)
		v.scan = 0
		return 0, false
	}
	i := max(v.scan, 2)
	for i < len(b) - 1 {
		if b[i] == 0xFF && b[i + 1] == 0xD9 {
			v.scan = 0
			return i + 2, true
		}
		i += 1
	}
	v.scan = max(2, len(b) - 1)
	return 0, false
}

video_pump_capture :: proc(v: ^Video, s: ^Session, t: f64) {
	if !v.cap.running {
		return
	}

	chunk: [64 * 1024]u8
	for {
		n, eof := child_read(&v.cap, chunk[:])
		if n > 0 {
			append(&v.accum, ..chunk[:n])
		}
		if eof {
			v.cap_error = "capture ended"
			child_stop(&v.cap)
			break
		}
		if n == 0 {
			break
		}
	}

	if len(v.accum) > V_MAX_FRAME * 2 {
		clear(&v.accum)
		v.scan = 0
		return
	}

	// Send every complete frame that has arrived. More than one per UI frame
	// means we fell behind; sending them all keeps the far end's frame id
	// sequence dense, and the far reassembler evicts the stale ones.
	for {
		n, ok := next_jpeg(v)
		if !ok {
			break
		}
		v.frames_captured += 1
		jpeg := v.accum[:n]
		v.last_jpeg_bytes = n

		if !v.camera_off {
			send_media(s, .Video_JPEG, jpeg, now_us())
			v.frames_sent += 1

			v.local_n += 1
			if v.local_n % v.local_div == 0 {
				decode_into(&v.local, &v.has_local, jpeg)
			}
		} else if v.has_local {
			p.image_destroy(&v.local)
			v.has_local = false
		}

		remove_range(&v.accum, 0, n)
	}

	if v.fps_at == 0 {
		v.fps_at = t
		v.fps_tx0 = v.frames_sent
		v.fps_rx0 = v.frames_decoded
	} else if t - v.fps_at >= 1.0 {
		dt := f32(t - v.fps_at)
		v.fps_tx = f32(v.frames_sent - v.fps_tx0) / dt
		v.fps_rx = f32(v.frames_decoded - v.fps_rx0) / dt
		v.fps_at = t
		v.fps_tx0 = v.frames_sent
		v.fps_rx0 = v.frames_decoded
	}
}

// ---------------------------------------------------------------------------
// Receive, decode
// ---------------------------------------------------------------------------

decode_into :: proc(dst: ^p.Image, has: ^bool, jpeg: []u8) -> bool {
	img, ok := p.decode_image(jpeg)
	if !ok {
		return false
	}
	if has^ {
		p.image_destroy(dst)
	}
	dst^ = img
	has^ = true
	return true
}

video_receive :: proc(v: ^Video, h: Header, payload: []u8) {
	frame, ts, done := reasm_push(&v.reasm, h, payload)
	if !done {
		return
	}
	t0 := now_us()
	if decode_into(&v.remote, &v.has_remote, frame) {
		v.frames_decoded += 1
		ms := f32(now_us() - t0) / 1000
		v.decode_ms = v.decode_ms == 0 ? ms : v.decode_ms * 0.9 + ms * 0.1
		lat := f64(now_us() - ts)
		v.latency_us = lat
		v.latency_sum_us += lat
		v.latency_n += 1
	} else {
		v.frames_failed += 1
	}
}

video_latency_mean_us :: proc(v: ^Video) -> f64 {
	if v.latency_n == 0 {
		return 0
	}
	return v.latency_sum_us / f64(v.latency_n)
}

video_clear_remote :: proc(v: ^Video) {
	if v.has_remote {
		p.image_destroy(&v.remote)
		v.has_remote = false
	}
	if v.has_local {
		p.image_destroy(&v.local)
		v.has_local = false
	}
}
