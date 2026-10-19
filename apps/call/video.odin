package call

// ---------------------------------------------------------------------------
// The video path.
//
//	capture+encode process ──pipe──▶ frame splitter ──▶ fragmenter ──▶ UDP
//	UDP ──▶ reassembler ──▶ decoder ──▶ palmy Image ──▶ p.draw_image
//
// Two codecs live here, negotiated per call (see `negotiate_video` in
// proto.odin):
//
//	H.264   libx264, baseline, ultrafast, zerolatency. 303 kbit/s measured at
//	        640x360@30. Decoded by a persistent `ffmpeg` child: access units in
//	        on stdin, BGRA frames out on stdout.
//	MJPEG   one JPEG per frame, 3.9 Mbit/s at the same size, decoded in
//	        process by stb_image through palmy's `decode_image`.
//
// MJPEG is kept, and is the floor of the negotiation, for three reasons: it is
// the format every version of this program has spoken, so it is what an old
// peer gets; every frame is independent, so it is the diagnostic to fall back
// to when the H.264 loss path is suspect; and it needs no child process at
// all on the receive side.
//
// Why H.264 is the default: 303 kbit/s against 3.9 Mbit/s for the same picture
// is an order of magnitude, and it was the single largest cost in this
// application. What it buys back, and what it costs, is the rest of this file:
// MJPEG frames are independent and H.264 frames are not, so a lost packet now
// damages everything until the next keyframe, and that has to be handled
// rather than hoped about.
//
// Framing on the pipe. The two codecs are self-delimiting in the same shape,
// which is why one splitter serves both:
//
//	MJPEG   JPEGs back to back; a frame ends at FF D9.
//	H.264   Annex-B access units, each opened by an access-unit delimiter
//	        (`-x264-params aud=1`), so a frame ends where the next AUD begins.
//
// Scanning resumes from where it left off, so the cost is linear in bytes.
// MJPEG's end marker means a frame can be sent the moment it is complete;
// H.264's AUD means a frame can only be sent once the *next* one has started,
// which is one frame of latency the MJPEG path does not pay. It is the price
// of the delimiter being at the head rather than the tail, and it is why the
// measured frame latency below is a frame higher than MJPEG's.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strings"
import p "palmy:."

// The call resolution. 640x360 is 16:9, and it fills the video tile of a
// 1180-point window without upscaling.
//
// It is a variable rather than a constant so `--video WxH@FPS` can ask for
// more and the measured frame rate can answer honestly. Measured end to end
// over loopback, at 30 fps requested, both codecs:
//
//	            MJPEG                          H.264 @ 300 kbit/s
//	 480x270    30.0 fps   9.6 KB   2.6 Mbit/s     30.0 fps   1.2 KB   0.30 Mbit/s
//	 640x360    29.9 fps  15.1 KB   3.9 Mbit/s     30.0 fps   1.2 KB   0.30 Mbit/s
//	 960x540    29.9 fps  24.1 KB   6.4 Mbit/s     30.0 fps   1.2 KB   0.30 Mbit/s
//	1280x720    30.0 fps  41.0 KB  10.7 Mbit/s     30.0 fps   1.2 KB   0.30 Mbit/s
//
// The right-hand column is flat because H.264 here is rate-targeted rather
// than quality-targeted: the resolution changes how much detail 300 kbit/s has
// to spread over, not how many bits go on the wire. That is the whole
// difference between a modern codec and MJPEG, in one table.
v_width := 640
v_height := 360
v_fps := 30
V_QUALITY :: "6" // ffmpeg -q:v for MJPEG, 2 best .. 31 worst

// The H.264 target. 300 kbit/s is the figure PROTOCOL.md has always named as
// what a real codec would cost; it is a variable so `--video-bitrate` can
// contradict it and the measurement can answer.
v_bitrate_kbps := 300

// V_GOP_SECONDS is the keyframe interval, in seconds of video.
//
// This is the loss story's first half. A keyframe is the only frame a receiver
// that has lost something can resume on, so this number is the worst case for
// blind recovery: two seconds of frozen picture if nothing else is done. The
// second half is `Control_Kind.Keyframe`, a receiver's request for one, which
// turns the usual case into about a tenth of a second.
//
// Two seconds rather than one because a 640x360 keyframe is 5-7 KB against
// 1.2 KB for a predicted frame, so at 30 fps one keyframe a second spends a
// fifth of a 300 kbit/s budget on frames nobody needed. Two seconds halves
// that, and the request path means the interval is a backstop rather than the
// mechanism.
V_GOP_SECONDS :: 2

// A frame over 400 KB is not a frame; something has gone wrong with the
// splitter and the accumulator should be dropped rather than grown.
V_MAX_FRAME :: 400 * 1024

// V_PLI_GAP is the minimum interval between keyframe requests we send. One
// burst of loss costs many frames, and a request per lost frame would be a
// request storm that makes the congestion it is reacting to worse.
V_PLI_GAP :: 0.2

// V_FORCE_GAP and V_FORCE_LIMIT bound how often we will honour one. Forcing a
// keyframe here means cycling the encoder process (see
// `video_on_keyframe_request`), so a peer that asks sixty times a second gets
// four keyframes a second and the counter says what it asked for.
//
// Four a second rather than one, because the restart turned out to cost less
// than it looks: measured over a thirty-second call with 2 % of video
// fragments deliberately dropped, seventeen forced restarts cost thirty-two
// frames in total — under two frames, about 63 ms, each. One a second was
// slower than the loss arrived, and the far end spent a third of the call
// frozen waiting for a budget that had run out.
V_FORCE_GAP :: 0.25
V_FORCE_LIMIT :: 160

// ---------------------------------------------------------------------------
// The H.264 decoder: a child process that holds the inter-frame state.
//
// palmy decodes JPEG in process through stb_image and nothing else, so an
// H.264 receiver has to be a decoder somewhere. `ffmpeg` is already the
// capture side of this application, so it is the decode side too: access units
// in on stdin, raw BGRA frames out on stdout, one frame per access unit,
// state kept between them.
//
// Three things make that fast enough to be worth doing, and all three were
// measured rather than assumed:
//
//  1. `-threads 1`. The h264 decoder is frame-threaded by default, and frame
//     threading *delays output by one frame per thread*: 68 ms of standing
//     latency on this machine, for a decode that costs under a millisecond.
//  2. A trailing access-unit delimiter after every frame we write. ffmpeg's
//     Annex-B parser will not emit an access unit until it has seen the start
//     of the next one, which is another whole frame of delay. Writing a
//     6-byte AUD sentinel behind each frame ends it immediately; the sentinel
//     then parses as an access unit with no picture in it and decodes to
//     nothing.
//  3. `-probesize 32 -analyzeduration 0`, so the first frame is not held
//     while ffmpeg works out what the stream is.
//
// Together those take the measured capture-to-decoded latency from 68 ms to
// under 2 ms of decoder cost. Both are in the report, because "we used
// ffmpeg" and "we used ffmpeg correctly" are 35x apart.
// ---------------------------------------------------------------------------

// The AUD sentinel: start code, NAL type 9, primary_pic_type 7.
H264_AUD :: [6]u8{0x00, 0x00, 0x00, 0x01, 0x09, 0x10}

// H264_FEED_RING is how many access units may be in flight inside the decoder
// before the oldest timestamp is given up on.
//
// It is small on purpose. The ring pairs a frame coming out with the access
// unit that went in, and that pairing holds only while the decoder emits one
// frame per unit — which it does, but a decoder that ever swallows one would
// otherwise skew every latency figure for the rest of the call by the depth of
// the ring. Eight frames is 266 ms: deep enough that the normal depth of one
// or two never touches it, shallow enough that the error is bounded and
// counted.
H264_FEED_RING :: 8

// DEC_PIPE_BYTES is the capacity asked for the decoder's output pipe, and it
// is the one number in this file that comes from the kernel rather than from
// the codec: an unprivileged F_SETPIPE_SZ is capped at
// /proc/sys/fs/pipe-max-size, which is 1 MiB on this machine.
//
// It matters because a frame loop drains at most one pipe-full per tick — once
// the pipe is empty the read returns EAGAIN and the tick is over, and ffmpeg
// only refills it when it is next scheduled. So the pipe capacity times the
// tick rate *is* the decoder's throughput ceiling. Measured: with the default
// 64 KiB pipe, a 30 fps 640x360 BGRA stream (921 KB a frame, 27 MB/s) came out
// at exactly 17 fps with three seconds of standing latency. At 1 MiB it runs
// at 30.0 fps, and the headroom is 2.3x even at the 60 Hz of a windowed call.
DEC_PIPE_BYTES :: 1 << 20

// decoder_output_size is the size the decoder is asked to scale to, which is
// the call resolution unless a frame of it would not fit in the pipe above.
//
// Above roughly 512x512 of BGRA it would not, so the picture a receiver
// displays is capped there while the *encoded* resolution is whatever the
// sender chose. That is a real limit and it is stated rather than hidden: the
// alternatives are yuv420p output and a colour-conversion loop in the frame
// loop, which is 2.7x less pipe traffic for a few milliseconds of CPU a frame,
// or a decoder linked into the process instead of spawned.
decoder_output_size :: proc(w, h: int) -> (int, int) {
	if w <= 0 || h <= 0 {
		return 2, 2
	}
	if w * h * 4 <= DEC_PIPE_BYTES {
		return w, h
	}
	f := math.sqrt(f64(DEC_PIPE_BYTES) / f64(w * h * 4))
	dw := int(f64(w) * f)
	dh := int(f64(h) * f)
	dw -= dw % 2
	dh -= dh % 2
	return max(2, dw), max(2, dh)
}

// H264_MAX_PENDING caps the bytes waiting for the decoder's stdin. Reaching it
// means the decoder has stopped consuming, so the queue is dropped and a
// keyframe asked for rather than growing a backlog of frames nobody will see
// in time.
H264_MAX_PENDING :: 1 << 20

H264_Fed :: struct {
	cap_ts: u64, // the sender's capture timestamp, for end-to-end latency
	at_us:  u64, // when we handed it over, for the decoder's own cost
}

H264_Decoder :: struct {
	ch:      Child,
	pending: [dynamic]u8, // written bytes the decoder's stdin has not taken yet
	px:      []u8, // one output frame of BGRA, being filled
	have:    int,
	w, h:    int,

	fed:     [H264_FEED_RING]H264_Fed,
	fed_n:   int,
	fed_at:  int,

	frames:  int,
	pushed:  int,
	starts:  int,
	desync:  int,
	dropped: int, // access units discarded because the decoder fell behind
	error:   string,
}

h264_decoder_argv :: proc(w, h: int) -> []string {
	return slice.clone([]string {
			"ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error",
			// Input: a bare Annex-B elementary stream, decoded the moment each
			// access unit is complete.
			"-flags", "low_delay", "-probesize", "32", "-analyzeduration", "0",
			"-f", "h264", "-i", "-",
			// One thread, or frame threading holds two frames back.
			"-threads", "1", "-filter_threads", "1",
			// The sender's resolution is its own business: normalise here so
			// the output frame is a size this process already allocated.
			"-vf", fmt.tprintf("scale=%d:%d", w, h),
			"-f", "rawvideo", "-pix_fmt", "bgra", "-flush_packets", "1", "pipe:1",
		}, context.temp_allocator)
}

h264_dec_start :: proc(d: ^H264_Decoder, w, h: int) -> bool {
	h264_dec_stop(d)
	frame_bytes := w * h * 4
	if len(d.px) != frame_bytes {
		delete(d.px)
		d.px = make([]u8, frame_bytes)
	}
	d.w, d.h = w, h
	d.have = 0
	d.fed_n, d.fed_at = 0, 0
	clear(&d.pending)
	// A pipe deep enough for two frames each way: the decoder must never stall
	// on us and we must never stall on it inside one tick of the frame loop.
	c, err := spawn_duplex(h264_decoder_argv(w, h), 128 * 1024, DEC_PIPE_BYTES)
	if err != "" {
		d.error = err
		return false
	}
	d.ch = c
	d.error = ""
	d.starts += 1
	return true
}

h264_dec_stop :: proc(d: ^H264_Decoder) {
	child_stop(&d.ch)
	d.have = 0
	d.fed_n, d.fed_at = 0, 0
	clear(&d.pending)
}

h264_dec_destroy :: proc(d: ^H264_Decoder) {
	h264_dec_stop(d)
	delete(d.pending)
	d.pending = {}
	delete(d.px)
	d.px = nil
}

// h264_dec_push hands one access unit over, with the AUD sentinel that makes
// ffmpeg's parser emit it immediately instead of waiting for the next frame.
h264_dec_push :: proc(d: ^H264_Decoder, au: []u8, cap_ts: u64) -> bool {
	if !d.ch.running {
		return false
	}
	if len(d.pending) + len(au) > H264_MAX_PENDING {
		d.dropped += 1
		clear(&d.pending)
		d.fed_n, d.fed_at = 0, 0
		return false
	}
	d.pushed += 1
	append(&d.pending, ..au)
	sentinel := H264_AUD
	append(&d.pending, ..sentinel[:])
	if d.fed_n >= H264_FEED_RING {
		// The decoder is further behind than one frame of timestamps can
		// explain. Give up the oldest rather than the newest, and say so.
		d.fed_at = (d.fed_at + 1) % H264_FEED_RING
		d.fed_n -= 1
		d.desync += 1
	}
	idx := (d.fed_at + d.fed_n) % H264_FEED_RING
	d.fed[idx] = {cap_ts = cap_ts, at_us = now_us()}
	d.fed_n += 1
	return true
}

@(private = "file")
h264_fed_pop :: proc(d: ^H264_Decoder) -> (cap_ts, at_us: u64, ok: bool) {
	if d.fed_n == 0 {
		return 0, 0, false
	}
	f := d.fed[d.fed_at]
	d.fed_at = (d.fed_at + 1) % H264_FEED_RING
	d.fed_n -= 1
	return f.cap_ts, f.at_us, true
}

// h264_dec_pump offers the decoder whatever is still queued and takes back one
// finished frame if one is ready. The caller loops until it returns false.
h264_dec_pump :: proc(d: ^H264_Decoder) -> (px: []u8, cap_ts, fed_us: u64, ok: bool) {
	if !d.ch.running || len(d.px) == 0 {
		return nil, 0, 0, false
	}
	if len(d.pending) > 0 {
		n, broken := child_write(&d.ch, d.pending[:])
		if n > 0 {
			remove_range(&d.pending, 0, n)
		}
		if broken {
			d.error = "decoder stopped reading"
			h264_dec_stop(d)
			return nil, 0, 0, false
		}
	}
	if d.have < len(d.px) {
		n, eof := child_read(&d.ch, d.px[d.have:])
		d.have += n
		if eof && d.have < len(d.px) {
			d.error = d.ch.last_errno == .NONE \
				? "decoder exited" \
				: fmt.aprintf("decoder read failed: %v", d.ch.last_errno)
			h264_dec_stop(d)
			return nil, 0, 0, false
		}
	}
	if d.have >= len(d.px) {
		d.have = 0
		d.frames += 1
		ts, at, _ := h264_fed_pop(d)
		return d.px, ts, at, true
	}
	return nil, 0, 0, false
}

// ---------------------------------------------------------------------------

Video :: struct {
	cap:   Child,
	accum: [dynamic]u8,
	scan:  int, // where the frame-boundary search resumes

	// The codec in use for the frames we send, and the set we can decode.
	// `offer` rides every control message; `codec` is what both ends computed
	// from the two offers.
	codec:      Video_Codec,
	offer:      u8,
	peer_offer: u8,
	negotiated: bool,

	// What the capture device is, kept so a keyframe request can cycle the
	// encoder without going back to the device list.
	src_kind: Device_Kind,
	src_path: string,

	reasm: Reassembler,

	// The H.264 decoders: one for the peer's picture, one for the self-view.
	// The self-view's is scaled to the size of the picture-in-picture rather
	// than the call resolution, because its output crosses a pipe and a
	// 160-point tile does not need 27 MB a second.
	dec:      H264_Decoder,
	dec_self: H264_Decoder,

	// The decoded remote frame, blitted by the UI.
	remote:     p.Image,
	has_remote: bool,

	// The self-view is our own captured frame decoded locally. Under MJPEG it
	// costs a second stb_image decode per frame, so it runs at a divided rate;
	// under H.264 every frame has to go to the decoder or the next one cannot
	// be decoded, so the division is in the resolution instead.
	local:     p.Image,
	has_local: bool,
	local_div: int,
	local_n:   int,

	camera_off: bool,
	// What the peer says about its own camera, mirrored here so the draw
	// procedure — which runs after the tree is built and has only this struct
	// — can tell "no video yet" from "they turned it off".
	peer_cam_off: bool,

	// Measured, not configured.
	frames_captured: int,
	frames_sent:     int,
	frames_decoded:  int,
	frames_failed:   int,
	last_frame_bytes: int,
	bytes_sent:      int,

	// The loss and keyframe story, all counted because every one of these is
	// invisible otherwise.
	keyframes_sent:   int,
	keyframes_rx:     int,
	keyframes_forced: int,
	pli_sent:         int,
	pli_rx:           int,
	loss_events:      int, // detected gaps in the peer's frame-id sequence
	frames_skipped:   int, // frames dropped while waiting for a keyframe
	need_keyframe:    bool,
	// Whether to ask at all. `--no-keyframe-request` turns it off, which is
	// how the report measures what the request is worth: with it, recovery is
	// the encoder restart; without it, recovery waits for the GOP timer.
	ask_keyframes:    bool,
	rx_frame:         u32,
	have_rx_frame:    bool,
	last_pli_tx:      f64,
	last_forced:      f64,

	fps_tx:  f32,
	fps_rx:  f32,
	fps_at:  f64,
	fps_tx0: int,
	fps_rx0: int,

	// Decode cost, exponentially smoothed, in milliseconds. For MJPEG that is
	// stb_image; for H.264 it is hand-over to frame-back, which is the same
	// question asked of a decoder that lives in another process.
	decode_ms: f32,
	// Capture-to-rendered, microseconds, from the packet timestamp.
	latency_us:     f64,
	latency_sum_us: f64,
	latency_n:      int,

	source_label: string,
	cap_error:    string,

	// SFU mode. Each simulcast layer is its own Video with its own encoder.
	// `room_mode` skips the peer decoder (remote pictures belong to the
	// room's participants, not to this struct) and `no_self` skips the
	// self-view decoder on the low layer, which would only duplicate it.
	enc_w, enc_h, enc_fps, enc_kbps: int,
	layer:     u8,
	room_mode: bool,
	no_self:   bool,
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

synth_pattern :: proc(w := 0, h := 0, fps := 0) -> string {
	// `realtime` paces on the frame count, the way `arealtime` paces the
	// synthetic microphone; `-re` gates on wall clock and runs fast.
	return fmt.tprintf(
		"%s=size=%dx%d:rate=%d,realtime",
		synth_source,
		w > 0 ? w : v_width,
		h > 0 ? h : v_height,
		fps > 0 ? fps : v_fps,
	)
}

// h264_encode_args is the encoder settings, stated once.
//
//	ultrafast + zerolatency   no lookahead, no B-frames, sliced threads, so an
//	                          access unit leaves the encoder in the frame it
//	                          was captured in. Lookahead is latency.
//	baseline                  no CABAC, no B-frames: cheap to decode, and what
//	                          a conferencing profile actually is.
//	g / keyint_min / sc_threshold=0
//	                          a keyframe exactly every V_GOP_SECONDS, not
//	                          whenever the picture happens to cut. A
//	                          deterministic interval is what makes the
//	                          worst-case recovery time a number.
//	aud=1                     an access-unit delimiter at the head of every
//	                          frame, which is what the splitter cuts on.
//	repeat-headers + dump_extra=freq=keyframe
//	                          SPS and PPS in front of every keyframe. Without
//	                          them the parameter sets exist only in the first
//	                          datagrams of the call, and losing those means
//	                          losing the stream for its whole duration.
h264_encode_args :: proc(fps := 0, kbps := 0) -> []string {
	fps := fps > 0 ? fps : v_fps
	kbps := kbps > 0 ? kbps : v_bitrate_kbps
	keyint := fmt.tprintf("%d", max(1, fps * V_GOP_SECONDS))
	rate := fmt.tprintf("%dk", kbps)
	return slice.clone([]string {
			"-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency",
			"-profile:v", "baseline", "-pix_fmt", "yuv420p",
			"-g", keyint, "-keyint_min", keyint, "-sc_threshold", "0", "-bf", "0",
			"-b:v", rate, "-maxrate", rate, "-bufsize", fmt.tprintf("%dk", kbps / 2),
			"-x264-params", "aud=1:repeat-headers=1",
			"-bsf:v", "dump_extra=freq=keyframe",
			"-flush_packets", "1", "-f", "h264", "-",
		}, context.temp_allocator)
}

mjpeg_encode_args :: proc() -> []string {
	return slice.clone([]string{"-q:v", V_QUALITY, "-flush_packets", "1", "-f", "mjpeg", "-"},
		context.temp_allocator)
}

// screen_share replaces the camera with the screen (`--share-screen`).
//
// It works on a compositor that speaks wlr-screencopy — sway, Hyprland, any
// wlroots one — through `grim`, which writes one PPM per capture; a loop of
// grim feeds ffmpeg's image2pipe, stamped with the wall clock and resampled
// to the call's frame rate, into the same encoder a camera would use. So a
// shared screen is just another video source to everything downstream:
// simulcast, SFrame and the SFU do not know the difference.
//
// It does **not** work under Palmframe's own window manager today: apps/wm
// implements no screen-capture protocol (neither wlr-screencopy nor
// ext-image-copy-capture-v1), so there is nothing for grim to ask. That is
// the wm's gap, stated in apps/call/PROTOCOL.md; the source here is ready for
// it.
screen_share := false

screen_capture_argv :: proc(codec: Video_Codec, w, h, fps, kbps: int) -> []string {
	enc := codec == .H264 ? h264_encode_args(fps, kbps) : mjpeg_encode_args()
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		"while grim -t ppm - 2>/dev/null; do :; done | ffmpeg -nostdin -hide_banner -loglevel error " +
		"-use_wallclock_as_timestamps 1 -f image2pipe -c:v ppm -i - -vf fps=%d,scale=%d:%d ",
		fps > 0 ? fps : v_fps,
		w > 0 ? w : v_width,
		h > 0 ? h : v_height,
	)
	for a in enc {
		strings.write_string(&b, a)
		strings.write_byte(&b, ' ')
	}
	return slice.clone([]string{"sh", "-c", strings.to_string(b)}, context.temp_allocator)
}

// `w`, `h`, `fps` and `kbps` override the call-wide settings for one encoder.
// SFU mode runs two encoders, one per simulcast layer, and the low layer is
// a quarter of the pixels at half the frame rate.
video_capture_argv :: proc(dev: Device, codec: Video_Codec, w := 0, h := 0, fps := 0, kbps := 0) -> []string {
	if screen_share {
		return screen_capture_argv(codec, w, h, fps, kbps)
	}
	enc := codec == .H264 ? h264_encode_args(fps, kbps) : mjpeg_encode_args()
	out := make([dynamic]string, 0, 32, context.temp_allocator)
	append(&out, "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error")
	if dev.kind == .Synthetic {
		append(&out, "-f", "lavfi", "-i", synth_pattern(w, h, fps))
	} else {
		// A real camera. The Brio advertises YUYV and MJPG at 640x480/30; let
		// ffmpeg negotiate and scale down to the call resolution.
		append(&out, "-f", "v4l2", "-framerate", fmt.tprintf("%d", v_fps))
		append(&out, "-video_size", "640x480", "-i", dev.path)
		append(&out, "-vf", fmt.tprintf("scale=%d:%d", w > 0 ? w : v_width, h > 0 ? h : v_height))
	}
	append(&out, ..enc)
	return out[:]
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

video_init :: proc(v: ^Video) {
	v.accum = make([dynamic]u8, 0, 128 * 1024)
	v.dec.pending = make([dynamic]u8, 0, 64 * 1024)
	v.dec_self.pending = make([dynamic]u8, 0, 64 * 1024)
	v.local_div = 3 // the MJPEG self-view runs at 10 fps
	v.codec = .MJPEG
	v.offer = CODEC_ALL
	v.ask_keyframes = true
	v.peer_offer = CODEC_MJPEG
	reasm_init(&v.reasm)
}

video_destroy :: proc(v: ^Video) {
	video_stop(v)
	delete(v.accum)
	reasm_destroy(&v.reasm)
	h264_dec_destroy(&v.dec)
	h264_dec_destroy(&v.dec_self)
	delete(v.src_path)
	v.src_path = ""
	if v.has_remote {
		p.image_destroy(&v.remote)
	}
	if v.has_local {
		p.image_destroy(&v.local)
	}
}

// self_view_size is the self-view decoder's output size: the aspect of the
// call, at the width the picture-in-picture is actually drawn at.
self_view_size :: proc() -> (w, h: int) {
	w = 256
	h = max(2, v_height * w / max(1, v_width))
	return w - w % 2, h - h % 2
}

video_start :: proc(v: ^Video, dev: Device, codec: Video_Codec) {
	video_stop(v)
	clear(&v.accum)
	v.scan = 0
	v.codec = codec
	// A new call means a new frame-id sequence at both ends.
	reasm_reset(&v.reasm)
	v.have_rx_frame = false
	// An H.264 decoder cannot decode anything until it has an IDR, and the
	// parameter sets that come with it. Starting in "waiting for a keyframe"
	// is therefore not a precaution, it is the only correct initial state —
	// and getting this wrong was measurable: a call whose first keyframe was
	// lost fed fifty predicted frames to a decoder with no parameter sets,
	// which answered "non-existing PPS 0 referenced" fifty times and produced
	// no picture until the next keyframe interval came round.
	v.need_keyframe = codec == .H264
	v.keyframes_forced = 0
	v.last_forced = 0

	v.src_kind = dev.kind
	if v.src_path != "" {
		delete(v.src_path)
	}
	v.src_path = clone_string(dev.path)
	v.source_label = dev.name

	video_spawn_capture(v)

	// The decoders are started here rather than on the first datagram so a
	// failure to start one is reported while the call is coming up.
	if codec == .H264 {
		if !v.room_mode {
			dw, dh := decoder_output_size(v_width, v_height)
			h264_dec_start(&v.dec, dw, dh)
		}
		if !v.no_self {
			sw, sh := self_view_size()
			if v.room_mode {
				// In a grid the self tile is as big as anyone's, so it is
				// decoded at a size that does not pixelate there.
				sw, sh = 480, 270
			}
			h264_dec_start(&v.dec_self, sw, sh)
		}
	}
}

video_spawn_capture :: proc(v: ^Video) {
	child_stop(&v.cap)
	clear(&v.accum)
	v.scan = 0
	dev := Device {
		kind = v.src_kind,
		path = v.src_path,
	}
	argv := video_capture_argv(dev, v.codec, v.enc_w, v.enc_h, v.enc_fps, v.enc_kbps)
	// Two frames of pipe. An MJPEG frame is ~15 KB, so 64 KiB would be four
	// frames of backlog before we even look; an H.264 frame is 1.2 KB, so the
	// same pipe is a quarter of a second of it and the bound has to be lower.
	pipe := v.codec == .H264 ? 8 * 1024 : 48 * 1024
	c, err := spawn_reader(argv, pipe)
	if err != "" {
		v.cap_error = err
	} else {
		v.cap = c
		v.cap_error = ""
	}
}

video_stop :: proc(v: ^Video) {
	child_stop(&v.cap)
	h264_dec_stop(&v.dec)
	h264_dec_stop(&v.dec_self)
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

// ---------------------------------------------------------------------------
// Annex-B access units
//
// A NAL unit begins with the three-byte start code 00 00 01, optionally
// preceded by a zero byte that makes it the four-byte form. The low five bits
// of the byte after the start code are the NAL type: 1 a predicted slice, 5 an
// IDR slice, 7 SPS, 8 PPS, 9 an access-unit delimiter.
//
// Working out where one *frame* ends in general means parsing slice headers for
// `first_mb_in_slice`, because a frame may be several slices — and at
// `-tune zerolatency` x264 emits five of them. Asking x264 for access-unit
// delimiters instead turns that into a byte scan, which is why `aud=1` is in
// the encoder arguments: the delimiter is the frame boundary, stated by the
// encoder rather than inferred by the receiver.
// ---------------------------------------------------------------------------

nal_type_at :: proc(b: []u8, i: int) -> (t: u8, ok: bool) {
	if i + 4 <= len(b) && b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1 {
		return b[i + 3] & 0x1F, true
	}
	return 0, false
}

// at_aud reports whether an access-unit delimiter starts exactly at `i`, in
// either the three- or four-byte start-code form.
at_aud :: proc(b: []u8, i: int) -> bool {
	if t, ok := nal_type_at(b, i); ok && t == 9 {
		return true
	}
	if i + 5 <= len(b) && b[i] == 0 {
		if t, ok := nal_type_at(b, i + 1); ok && t == 9 {
			return true
		}
	}
	return false
}

// find_aud returns the index of the next access-unit delimiter at or after
// `from`, taking in the leading zero of a four-byte start code so the
// delimiter is handed on whole.
find_aud :: proc(b: []u8, from: int) -> int {
	for i := max(from, 0); i + 4 <= len(b); i += 1 {
		if t, ok := nal_type_at(b, i); ok && t == 9 {
			if i > 0 && b[i - 1] == 0 {
				return i - 1
			}
			return i
		}
	}
	return -1
}

// au_has_idr reports whether an access unit can be decoded on its own: it
// carries an IDR slice, and therefore the SPS and PPS that `repeat-headers`
// puts in front of one.
au_has_idr :: proc(au: []u8) -> bool {
	for i := 0; i + 4 <= len(au); i += 1 {
		t, ok := nal_type_at(au, i)
		if !ok {
			continue
		}
		if t == 5 {
			return true
		}
		i += 2
	}
	return false
}

// next_au finds one complete access unit at the front of the accumulator. It
// is the H.264 half of the same contract `next_jpeg` fulfils.
next_au :: proc(v: ^Video) -> (n: int, keyframe: bool, ok: bool) {
	b := v.accum[:]
	if len(b) < 8 {
		return 0, false, false
	}
	if !at_aud(b, 0) {
		// Resynchronise on the first delimiter in the buffer. This fires once,
		// if ever: x264 opens its stream with one.
		j := find_aud(b, 0)
		if j > 0 {
			remove_range(&v.accum, 0, j)
		} else if j < 0 {
			// Keep only enough tail for a start code that straddles the read.
			if len(v.accum) > 8 {
				remove_range(&v.accum, 0, len(v.accum) - 8)
			}
		}
		v.scan = 0
		return 0, false, false
	}
	j := find_aud(b, max(v.scan, 4))
	if j < 0 {
		v.scan = max(4, len(b) - 5)
		return 0, false, false
	}
	v.scan = 0
	return j, au_has_idr(b[:j]), true
}

// next_frame is the codec-agnostic face of the two splitters above.
next_frame :: proc(v: ^Video) -> (n: int, keyframe: bool, ok: bool) {
	if v.codec == .H264 {
		return next_au(v)
	}
	// Every MJPEG frame is a keyframe. Saying so on the wire rather than
	// special-casing MJPEG in the receiver is what keeps the loss logic to one
	// code path.
	n, ok = next_jpeg(v)
	return n, true, ok
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
			v.cap_error = v.cap.last_errno == .NONE \
				? "capture process exited" \
				: fmt.aprintf("capture read failed: %v", v.cap.last_errno)
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
		n, kf, ok := next_frame(v)
		if !ok {
			break
		}
		v.frames_captured += 1
		frame := v.accum[:n]
		v.last_frame_bytes = n

		if !v.camera_off {
			flags: u8 = kf ? FLAG_KEYFRAME : 0
			send_media(s, video_codec_payload(v.codec), frame, now_us(), flags, v.layer)
			v.frames_sent += 1
			v.bytes_sent += n
			if kf {
				v.keyframes_sent += 1
			}

			if !v.no_self {
				video_self_view(v, frame)
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

// video_self_view decodes our own frame for the picture-in-picture.
//
// Under MJPEG that is a second stb_image decode, so it runs at a third of the
// frame rate. Under H.264 a frame cannot be skipped — the next one predicts
// from it — so every access unit goes to the self-view decoder and the saving
// is taken in its output size instead.
video_self_view :: proc(v: ^Video, frame: []u8) {
	if v.codec == .H264 {
		h264_dec_push(&v.dec_self, frame, now_us())
		return
	}
	v.local_n += 1
	if v.local_n % v.local_div == 0 {
		decode_into(&v.local, &v.has_local, frame)
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

// publish_bgra lands a raw frame from a decoder child into a palmy Image.
// `bgra` little-endian is byte-for-byte the 0xAARRGGBB the rasteriser wants, so
// this is a memcpy and not a conversion loop — which is the reason the decoder
// is asked for bgra rather than rgba.
publish_bgra :: proc(dst: ^p.Image, has: ^bool, bgra: []u8, w, h: int) {
	if !has^ || dst.w != w || dst.h != h {
		if has^ {
			p.image_destroy(dst)
		}
		dst^ = p.Image {
			px              = make([]u32, w * h),
			w               = w,
			h               = h,
			source_channels = 4,
		}
		has^ = true
	}
	n := min(len(bgra), len(dst.px) * 4)
	if n > 0 {
		mem.copy(raw_data(dst.px), raw_data(bgra), n)
	}
}

// video_receive takes one fragment off the wire.
//
// The loss story, in full, is here. MJPEG needed none of it: a lost frame was
// one lost frame. H.264 predicts, so a frame that never arrived leaves every
// later frame referring to a picture the decoder does not have, and feeding
// those to the decoder produces a smear that lasts until the next keyframe and
// looks exactly like a broken application.
//
// So:
//
//  1. A gap is *detected*, from the frame-id sequence. Every fragment of a
//     frame carries the same id and ids are dense, so a completed frame whose
//     id is not its predecessor's plus one means a frame was lost — whether it
//     was lost on the wire or evicted half-assembled by the reassembler.
//  2. A keyframe is *asked for*, with `Control_Kind.Keyframe` on the same
//     socket. That is this protocol's PLI, and it is rate limited to one every
//     V_PLI_GAP so a burst of loss is one request.
//  3. Nothing is fed to the decoder until one arrives. The picture freezes on
//     the last good frame instead of dissolving, and `frames_skipped` counts
//     exactly how many frames that cost.
//
// The sender's half is `video_on_keyframe_request`.
video_receive :: proc(v: ^Video, s: ^Session, h: Header, payload: []u8, t: f64) {
	frame, ts, done := reasm_push(&v.reasm, h, payload)
	if !done {
		return
	}
	kf := keyframed(h)
	if kf {
		v.keyframes_rx += 1
	}

	// Gap detection. A peer that restarted goes backwards, which
	// `reasm_reset` has already dealt with; this only has to notice forward
	// jumps.
	if v.have_rx_frame && seq_newer_u32(h.frame, v.rx_frame) && h.frame != v.rx_frame + 1 {
		v.loss_events += 1
		if h.ptype == .Video_H264 {
			v.need_keyframe = true
			video_request_keyframe(v, s, t)
		}
	}
	v.rx_frame = h.frame
	v.have_rx_frame = true

	if h.ptype == .Video_H264 {
		if v.need_keyframe {
			if !kf {
				// Nothing decodable can be done with this frame. Ask again —
				// the request is rate limited, and the first one may have been
				// lost along with the frame that caused it.
				v.frames_skipped += 1
				video_request_keyframe(v, s, t)
				return
			}
			v.need_keyframe = false
		}
		if !v.dec.ch.running {
			// The decoder died, or the peer switched to H.264 mid-call. Either
			// way the next decodable frame is a keyframe, so ask for one.
			dw, dh := decoder_output_size(v_width, v_height)
			if !h264_dec_start(&v.dec, dw, dh) {
				v.frames_failed += 1
				return
			}
			if !kf {
				v.need_keyframe = true
				v.frames_skipped += 1
				video_request_keyframe(v, s, t)
				return
			}
		}
		if !h264_dec_push(&v.dec, frame, ts) {
			v.need_keyframe = true
			video_request_keyframe(v, s, t)
		}
		return
	}

	// MJPEG: in process, immediately.
	t0 := now_us()
	if decode_into(&v.remote, &v.has_remote, frame) {
		video_count_decoded(v, f32(now_us() - t0) / 1000, ts)
	} else {
		v.frames_failed += 1
	}
}

video_count_decoded :: proc(v: ^Video, ms: f32, cap_ts: u64) {
	v.frames_decoded += 1
	v.decode_ms = v.decode_ms == 0 ? ms : v.decode_ms * 0.9 + ms * 0.1
	if cap_ts != 0 {
		lat := f64(now_us() - cap_ts)
		v.latency_us = lat
		v.latency_sum_us += lat
		v.latency_n += 1
	}
}

// video_pump_decoders moves frames out of the decoder children. It runs every
// tick, not only when a datagram arrives, because a decoder is a process and
// answers on its own schedule.
video_pump_decoders :: proc(v: ^Video) {
	if v.codec != .H264 && !v.dec.ch.running {
		return
	}
	for {
		px, cap_ts, fed_us, ok := h264_dec_pump(&v.dec)
		if !ok {
			break
		}
		publish_bgra(&v.remote, &v.has_remote, px, v.dec.w, v.dec.h)
		cost := fed_us == 0 ? 0 : f32(now_us() - fed_us) / 1000
		video_count_decoded(v, cost, cap_ts)
	}
	for {
		px, _, _, ok := h264_dec_pump(&v.dec_self)
		if !ok {
			break
		}
		if v.camera_off {
			continue
		}
		publish_bgra(&v.local, &v.has_local, px, v.dec_self.w, v.dec_self.h)
	}
}

// ---------------------------------------------------------------------------
// Keyframes: asking, and answering
// ---------------------------------------------------------------------------

video_request_keyframe :: proc(v: ^Video, s: ^Session, t: f64) {
	if !v.ask_keyframes {
		return
	}
	if t - v.last_pli_tx < V_PLI_GAP && v.pli_sent > 0 {
		return
	}
	v.last_pli_tx = t
	v.pli_sent += 1
	send_control(s, .Keyframe, false, false)
}

// video_on_keyframe_request is the sender's half: the peer has lost something
// and cannot decode anything until it is given a frame that stands alone.
//
// There is no way to ask a running `ffmpeg` for a keyframe. Its CLI takes no
// commands, `-force_key_frames` is fixed at startup, and the encoder is on the
// far side of a pipe we only read. So the honest implementation is to cycle
// the encoder: a fresh `ffmpeg` emits SPS, PPS and an IDR as its first access
// unit, measured at about 120 ms on this machine.
//
// That is blunt and it is stated as blunt. It costs the pipeline restart —
// with the synthetic source, the pattern restarts visibly; with a camera, the
// device is reopened — which is why it is rate limited to one a second and
// budgeted at V_FORCE_LIMIT a call. An in-process encoder would set
// `pict_type = I` on one frame and cost nothing, and that is the single
// strongest argument for linking libx264 rather than spawning it.
//
// Under MJPEG this is a no-op that still counts the request, because every
// frame is already a keyframe and the peer will recover on the next one.
video_on_keyframe_request :: proc(v: ^Video, t: f64) -> bool {
	v.pli_rx += 1
	if v.codec != .H264 || v.camera_off {
		return false
	}
	if v.keyframes_forced > 0 && t - v.last_forced < V_FORCE_GAP {
		return false
	}
	if v.keyframes_forced >= V_FORCE_LIMIT {
		return false
	}
	v.last_forced = t
	v.keyframes_forced += 1
	video_spawn_capture(v)
	return true
}

// ---------------------------------------------------------------------------

video_latency_mean_us :: proc(v: ^Video) -> f64 {
	if v.latency_n == 0 {
		return 0
	}
	return v.latency_sum_us / f64(v.latency_n)
}

// video_mean_frame_bytes is what a frame of this codec actually costs, which
// is the number the whole exercise was about.
video_mean_frame_bytes :: proc(v: ^Video) -> f32 {
	if v.frames_sent == 0 {
		return 0
	}
	return f32(v.bytes_sent) / f32(v.frames_sent)
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
