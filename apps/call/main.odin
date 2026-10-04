package call

// ---------------------------------------------------------------------------
// call — real-time audio and video calling, in Odin, on palmy.
//
// Two instances of this binary call each other over UDP on 127.0.0.1. Media
// is captured by a child process, encoded in-process, fragmented into an
// RTP-shaped framing, sent, reordered by a jitter buffer, decoded, and either
// written to a sound card or blitted into the window.
//
//	call --bind 47811 --peer 47812 --name Alice
//	call --bind 47812 --peer 47811 --name Bob
//
//	--autocall          dial as soon as the window opens
//	--autoanswer        answer an incoming call automatically
//	--allow-real-devices
//	                    permit selecting the real camera and microphone.
//	                    Without it both are listed and both are refused, and
//	                    the call runs on synthetic sources. Recordings and
//	                    screenshots are made without this flag, always.
//	--self-test         run the headless pipeline tests and exit
//	--quit-after SECS   exit after a while, for scripted runs
//
// The frame loop is `always = true`, so palmy presents every vsync rather
// than only on input, and every I/O operation in the loop is non-blocking.
// That is the whole concurrency design: there are no threads, and at 60 Hz a
// 16 ms budget is ample for one JPEG decode, one Opus frame and a few hundred
// datagrams.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

// Receiving is bounded per frame so a burst cannot stall the compositor. At
// 30 fps video the steady state is about sixteen datagrams per frame, so this
// is two-thirds of a second of catch-up headroom.
RX_BUDGET :: 512

Panel :: enum {
	Stats,
	Devices,
}

App :: struct {
	win:  ^p.App,
	s:    Session,
	a:    Audio,
	v:    Video,
	devs: Devices,

	allow_real: bool,
	autocall:   bool,
	autoanswer: bool,
	quit_after: f64,

	panel: Panel,
	focus_row: int,

	t:  f64,
	dt: f32,

	rx: [MAX_PACKET + 64]u8,

	// A short activity log, which is how a call app says what it just did
	// without a terminal.
	log:   [8]string,
	log_n: int,

	denied: string, // set when a real device was selected without the flag
	denied_at: f64,

	// Last reported pipeline failure, so each is announced once, and the
	// supervisor's budget for bringing a dead one back.
	last_cap_error:  string,
	last_vid_error:  string,
	last_play_error: string,
	restarts:        int,
	last_restart:    f64,

	// Snapshots the pixel draw procedures read, refreshed once per frame.
	meter_tx: Meter,
	meter_rx: Meter,
}

log_line :: proc(app: ^App, format: string, args: ..any) {
	msg := fmt.aprintf(format, ..args)
	if app.log_n >= len(app.log) {
		delete(app.log[0])
		for i in 0 ..< len(app.log) - 1 {
			app.log[i] = app.log[i + 1]
		}
		app.log[len(app.log) - 1] = msg
	} else {
		app.log[app.log_n] = msg
		app.log_n += 1
	}
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

Args :: struct {
	bind:       int,
	peer:       int,
	name:       string,
	allow_real: bool,
	autocall:   bool,
	autoanswer: bool,
	self_test:  bool,
	headless:   bool,
	shot:       string,
	shot_at:    string,
	shot_size:  string,
	pattern:    string,
	video:      string,
	codec:      string,
	bitrate:    int,
	loss:       int,
	no_pli:     bool,
	volume:     f64,
	quit_after: f64,
}

// parse_codec_offer reads `--video-codec` into an offer bitmask. The flag is
// an *offer*, not a choice: naming one codec means refusing the other, which is
// how the MJPEG-only peer in the report is produced from the same binary.
parse_codec_offer :: proc(spec: string) -> (mask: u8, err: string) {
	switch spec {
	case "auto", "both", "":
		return CODEC_ALL, ""
	case "h264", "h.264", "avc":
		return CODEC_H264, ""
	case "mjpeg", "jpeg", "mjpg":
		return CODEC_MJPEG, ""
	}
	return 0, "--video-codec takes auto, h264 or mjpeg"
}

parse_args :: proc() -> (a: Args, err: string) {
	a.bind = 47811
	a.peer = 47812
	a.name = "Alice"
	a.volume = -1 // "unset"; audio_init picks the default

	args := os.args[1:]
	i := 0
	next :: proc(args: []string, i: ^int) -> (string, bool) {
		if i^ + 1 >= len(args) {
			return "", false
		}
		i^ += 1
		return args[i^], true
	}
	for i < len(args) {
		switch args[i] {
		case "--bind":
			v, ok := next(args, &i)
			if !ok {
				return a, "--bind needs a port"
			}
			n, good := strconv.parse_int(v)
			if !good {
				return a, "--bind needs a number"
			}
			a.bind = n
		case "--peer":
			v, ok := next(args, &i)
			if !ok {
				return a, "--peer needs a port"
			}
			n, good := strconv.parse_int(v)
			if !good {
				return a, "--peer needs a number"
			}
			a.peer = n
		case "--name":
			v, ok := next(args, &i)
			if !ok {
				return a, "--name needs a value"
			}
			a.name = v
		case "--quit-after":
			v, ok := next(args, &i)
			if !ok {
				return a, "--quit-after needs seconds"
			}
			f, good := strconv.parse_f64(v)
			if !good {
				return a, "--quit-after needs a number"
			}
			a.quit_after = f
		case "--allow-real-devices":
			a.allow_real = true
		case "--autocall":
			a.autocall = true
		case "--autoanswer":
			a.autoanswer = true
		case "--self-test", "--selftest":
			a.self_test = true
		case "--headless":
			a.headless = true
		case "--shot":
			v, ok := next(args, &i)
			if !ok {
				return a, "--shot needs a path prefix"
			}
			a.shot = v
		case "--shot-size":
			v, ok := next(args, &i)
			if !ok {
				return a, "--shot-size needs WxH"
			}
			a.shot_size = v
		case "--shot-at":
			v, ok := next(args, &i)
			if !ok {
				return a, "--shot-at needs a list like 4,8:d,12:s"
			}
			a.shot_at = v
		case "--video":
			v, ok := next(args, &i)
			if !ok {
				return a, "--video needs WxH@FPS, e.g. 640x360@30"
			}
			a.video = v
		case "--pattern":
			v, ok := next(args, &i)
			if !ok {
				return a, "--pattern needs a lavfi source name"
			}
			a.pattern = v
		case "--video-codec":
			v, ok := next(args, &i)
			if !ok {
				return a, "--video-codec needs auto, h264 or mjpeg"
			}
			a.codec = v
		case "--video-bitrate":
			v, ok := next(args, &i)
			if !ok {
				return a, "--video-bitrate needs kbit/s"
			}
			n, good := strconv.parse_int(v)
			if !good || n < 32 || n > 20000 {
				return a, "--video-bitrate needs 32..20000 kbit/s"
			}
			a.bitrate = n
		case "--loss":
			v, ok := next(args, &i)
			if !ok {
				return a, "--loss needs a count per thousand"
			}
			n, good := strconv.parse_int(v)
			if !good || n < 0 || n > 500 {
				return a, "--loss needs 0..500 per thousand"
			}
			a.loss = n
		case "--no-keyframe-request":
			a.no_pli = true
		case "--volume":
			v, ok := next(args, &i)
			if !ok {
				return a, "--volume needs 0..1"
			}
			f, good := strconv.parse_f64(v)
			if !good || f < 0 || f > 1 {
				return a, "--volume needs a number in 0..1"
			}
			a.volume = f
		case "-h", "--help":
			return a, "help"
		case:
			return a, fmt.aprintf("unknown argument %q", args[i])
		}
		i += 1
	}
	if a.bind == a.peer {
		return a, "--bind and --peer must differ: two instances, two ports"
	}
	if a.bind < 1024 || a.bind > 65535 || a.peer < 1024 || a.peer > 65535 {
		return a, "ports must be in 1024..65535"
	}
	return a, ""
}

USAGE :: `call — real-time audio and video calling over loopback UDP

  call --bind 47811 --peer 47812 --name Alice
  call --bind 47812 --peer 47811 --name Bob

  --bind PORT             UDP port to bind on 127.0.0.1   (default 47811)
  --peer PORT             the other instance's port         (default 47812)
  --name NAME             display name                      (default Alice)
  --autocall              dial on startup
  --autoanswer            answer incoming calls
  --allow-real-devices    permit opening the real camera and microphone
  --volume 0..1           playback volume                     (default 0.35)
  --video WxH@FPS         call resolution and frame rate   (default 480x270@30)
  --pattern NAME          lavfi video source for the synthetic camera, so the
                          two ends of a call look different
                          (testsrc2, smptehdbars, rgbtestsrc, mandelbrot, ...)
  --video-codec WHICH     which video codecs to *offer*: auto (H.264 and
                          MJPEG, the default), h264, or mjpeg. The peer offers
                          too and the best both sides have wins, so
                          --video-codec mjpeg on one end is how you get an
                          MJPEG-only peer out of this binary.
  --video-bitrate KBPS    the H.264 target, in kbit/s          (default 300)
  --loss N                drop N of every thousand outgoing video fragments,
                          on purpose, with a fixed seed. Loopback has no loss
                          and H.264's whole risk is loss, so this is how the
                          keyframe path gets exercised against a real stream.
  --no-keyframe-request   never ask a peer for a keyframe, so recovery waits
                          for the keyframe interval instead. The two runs
                          together are what the report compares.
  --headless              no window: capture, encode, send, receive, decode
                          and play, with a statistics line every second. This
                          is the other end of a call when you only want one
                          window on screen, and it is how the measured numbers
                          in the report were taken.
  --shot PREFIX           render the real interface offscreen, with the media
  --shot-at 4,8:d,12:s    pipeline live, and write PREFIX-<n>.png at each of
  --shot-size WxH         those times. An entry may carry a key to press just
                          before the shot. No compositor involved.
  --quit-after SECS       exit after SECS
  --self-test             run the headless pipeline tests and exit

Keys: C call  Enter answer  H hang up  M mute  V camera  D devices
      R rescan  [ ] volume  Tab panel  Q quit
`

// parse_video_size reads `WxH@FPS` into the capture settings.
parse_video_size :: proc(spec: string) -> string {
	rest := spec
	fps := v_fps
	if at := strings.index_byte(rest, '@'); at >= 0 {
		n, ok := strconv.parse_int(rest[at + 1:])
		if !ok || n < 1 || n > 120 {
			return "--video frame rate must be 1..120"
		}
		fps = n
		rest = rest[:at]
	}
	x := strings.index_byte(rest, 'x')
	if x <= 0 {
		return "--video needs WxH@FPS, e.g. 640x360@30"
	}
	w, wok := strconv.parse_int(rest[:x])
	h, hok := strconv.parse_int(rest[x + 1:])
	if !wok || !hok || w < 16 || h < 16 || w > 1920 || h > 1080 {
		return "--video dimensions must be 16x16 .. 1920x1080"
	}
	// An odd dimension makes ffmpeg's chroma subsampling complain.
	v_width, v_height, v_fps = w - w % 2, h - h % 2, fps
	return ""
}

// ---------------------------------------------------------------------------
// Receive
// ---------------------------------------------------------------------------

pump_receive :: proc(app: ^App) {
	if !app.s.open {
		return
	}
	for _ in 0 ..< RX_BUDGET {
		n, from, err := net.recv_udp(app.s.sock, app.rx[:])
		if err == .Would_Block || n == 0 {
			break // nothing more waiting
		}
		if err != nil {
			// A stray datagram too big for the buffer, or a transient error.
			// Count it and keep draining: one bad packet must not stall the
			// rest of the frame's media.
			app.s.rx_bad += 1
			continue
		}
		// Loopback only, and only from the port we are paired with. A
		// datagram from anywhere else is not part of this call.
		if from.port != app.s.peer.port || from.address != app.s.peer.address {
			app.s.rx_bad += 1
			continue
		}
		app.s.rx_packets += 1
		app.s.rx_bytes += n

		h, payload, ok := parse(app.rx[:n])
		if !ok {
			app.s.rx_bad += 1
			continue
		}

		switch h.ptype {
		case .Control:
			c, good := read_control(payload)
			if !good {
				app.s.rx_bad += 1
				continue
			}
			before := app.s.state
			handle_control(&app.s, c, app.a.muted, app.v.camera_off)
			app.s.last_peer_rx = app.t
			if before != app.s.state {
				on_state_change(app, before)
			}
			if c.kind == .Keyframe {
				// The peer has lost something and cannot decode until it is
				// given a frame that stands alone.
				if video_on_keyframe_request(&app.v, app.t) {
					log_line(app, "keyframe requested by peer — cycling the encoder")
				}
			}
		case .Audio_Opus, .Audio_PCM:
			app.s.last_peer_rx = app.t
			if app.s.state == .Connecting {
				before := app.s.state
				set_state(&app.s, .Connected)
				on_state_change(app, before)
			}
			audio_receive(&app.a, h, payload)
		case .Video_JPEG, .Video_H264:
			app.s.last_peer_rx = app.t
			if app.s.state == .Connecting {
				before := app.s.state
				set_state(&app.s, .Connected)
				on_state_change(app, before)
			}
			video_receive(&app.v, &app.s, h, payload, app.t)
		}
	}
}

// ---------------------------------------------------------------------------
// Media lifecycle, driven off the state machine
// ---------------------------------------------------------------------------

on_state_change :: proc(app: ^App, before: Call_State) {
	now := app.s.state
	was_active := before == .Connecting || before == .Connected
	is_active := now == .Connecting || now == .Connected

	if is_active && !was_active {
		app.restarts = 0
		app.last_restart = 0
		start_media(app)
		log_line(app, "media up — %s", app.a.codec)
	}
	if was_active && !is_active {
		stop_media(app)
		log_line(app, "media down — %s", app.s.reason)
	}
	switch now {
	case .Dialing:
		log_line(app, "calling 127.0.0.1:%d", app.s.peer.port)
	case .Ringing:
		log_line(app, "incoming call from %s", app.s.peer_name)
	case .Connected:
		log_line(app, "connected")
	case .Ended:
		log_line(app, "ended: %s", app.s.reason)
	case .Idle, .Connecting:
	}
}

// resolve_capture decides what will actually be opened.
//
// This is the privacy guarantee, in one pure function so the self-test can
// assert it rather than the comments claiming it: unless `allow_real` was
// passed on the command line, a microphone or a camera that touches hardware
// is replaced by the synthetic source. The device picker already refuses to
// move the selection onto a real device without the flag; this is the check
// at the point where it matters, which is the moment before a process is
// spawned with a device on its command line.
//
// The output sink is deliberately *not* substituted: playing to the real
// speakers records nothing and reveals nothing.
resolve_capture :: proc(allow_real: bool, src, cam: Device) -> (out_src, out_cam: Device) {
	out_src, out_cam = src, cam
	if !allow_real {
		if out_src.real {
			out_src = Device{kind = .Synthetic, name = SYNTH_AUDIO_NAME}
		}
		if out_cam.real {
			out_cam = Device{kind = .Synthetic, name = SYNTH_VIDEO_NAME}
		}
	}
	// wpctl lists PipeWire's own video nodes, which have an id but no /dev
	// path — informative in the picker, not openable by ffmpeg. Falling back
	// is better than handing ffmpeg an empty `-i`.
	if out_cam.real && out_cam.path == "" {
		out_cam = Device{kind = .Synthetic, name = SYNTH_VIDEO_NAME}
	}
	return
}

// RESTART_GAP is the minimum time between supervisor restarts, and
// RESTART_LIMIT the number allowed in one call. Both exist so a capture that
// cannot start — a camera that has been unplugged, say — degrades into a
// stated error rather than a loop that respawns ffmpeg sixty times a second.
RESTART_GAP :: 1.0
RESTART_LIMIT :: 5

// supervise_media notices a dead capture or playback process and brings it
// back. A microphone that stops is the worst failure a call application can
// have, because its only symptom is a meter that stops moving and the person
// at the other end saying "hello?"; it should be announced and repaired, not
// endured.
supervise_media :: proc(app: ^App) {
	for pair in ([?]struct {
		msg:  string,
		dead: bool,
		err:  string,
		slot: ^string,
	} {
		{"microphone", !app.a.cap.running, app.a.cap_error, &app.last_cap_error},
		{"camera", !app.v.cap.running && !app.v.camera_off, app.v.cap_error, &app.last_vid_error},
		{"playback", !app.a.play.running, app.a.play_error, &app.last_play_error},
	}) {
		if !pair.dead || pair.err == "" || pair.err == pair.slot^ {
			continue
		}
		pair.slot^ = pair.err
		log_line(app, "%s: %s", pair.msg, pair.err)
		fmt.eprintfln("call: %s stopped: %s", pair.msg, pair.err)
	}

	if app.a.cap.running && app.v.cap.running && app.a.play.running {
		return
	}
	if app.restarts >= RESTART_LIMIT || app.t - app.last_restart < RESTART_GAP {
		return
	}
	app.restarts += 1
	app.last_restart = app.t
	log_line(app, "restarting capture (%d of %d)", app.restarts, RESTART_LIMIT)
	start_media(app)
}

start_media :: proc(app: ^App) {
	app.last_cap_error, app.last_vid_error, app.last_play_error = "", "", ""
	sink := sel_sink(&app.devs)
	src, cam := resolve_capture(app.allow_real, sel_source(&app.devs), sel_camera(&app.devs))
	if cam.kind == .Synthetic && sel_camera(&app.devs).kind == .Camera {
		log_line(app, "%s not opened; using the synthetic camera", sel_camera(&app.devs).name)
	}
	audio_start(&app.a, src, sink)

	// The codec is not a setting, it is the intersection of two offers. Both
	// ends compute it from the same two bitmasks, so there is no answer
	// message and no round trip: see `negotiate_video`.
	codec := negotiate_video(app.v.offer, app.s.peer_codecs)
	app.v.peer_offer = app.s.peer_codecs
	app.v.negotiated = true
	video_start(&app.v, cam, codec)
	log_line(
		app,
		"video codec %s (we offer %s, peer offers %s)",
		video_codec_name(codec),
		codec_offer_label(app.v.offer),
		codec_offer_label(app.s.peer_codecs),
	)
}

// codec_offer_label renders an offer bitmask the way the log and the statistics
// panel want to read it.
codec_offer_label :: proc(mask: u8) -> string {
	switch mask & CODEC_ALL {
	case CODEC_ALL:
		return "H.264+MJPEG"
	case CODEC_H264:
		return "H.264"
	case CODEC_MJPEG:
		return "MJPEG"
	}
	return "none"
}

// renegotiate_video handles the offer arriving after the media did. In practice
// it cannot: `Connecting` is only reachable through an INVITE or an ACCEPT and
// both carry the offer. But a peer that restarts mid-call, or one whose first
// control message was lost, would otherwise be stuck on the MJPEG floor for
// the rest of the call, and the cost of noticing is one comparison a frame.
renegotiate_video :: proc(app: ^App) {
	if !call_active(&app.s) || !app.v.negotiated {
		return
	}
	want := negotiate_video(app.v.offer, app.s.peer_codecs)
	if want == app.v.codec {
		return
	}
	app.v.peer_offer = app.s.peer_codecs
	log_line(
		app,
		"peer now offers %s — switching to %s",
		codec_offer_label(app.s.peer_codecs),
		video_codec_name(want),
	)
	src, cam := resolve_capture(app.allow_real, sel_source(&app.devs), sel_camera(&app.devs))
	_ = src
	video_start(&app.v, cam, want)
}

stop_media :: proc(app: ^App) {
	audio_stop(&app.a)
	video_stop(&app.v)
	video_clear_remote(&app.v)
	jb_reset(&app.a.jb)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

try_select :: proc(app: ^App, list: []Device, sel: ^int, delta: int) {
	if len(list) == 0 {
		return
	}
	n := (sel^ + delta) % len(list)
	if n < 0 {
		n += len(list)
	}
	if list[n].real && !app.allow_real {
		delete(app.denied)
		app.denied = fmt.aprintf(
			"%s is a real device — start with --allow-real-devices to open it",
			list[n].name,
		)
		app.denied_at = app.t
		return
	}
	sel^ = n
	// Mid-call, the capture and playback processes are restarted on the new
	// device. The call itself is untouched: same socket, same sequence
	// numbers, so the far end sees a brief gap and nothing more.
	if call_active(&app.s) {
		start_media(app)
		log_line(app, "device changed, capture restarted")
	}
}

handle_keys :: proc(app: ^App, ui: ^p.Ctx) {
	s := &app.s

	// Letter keys are plain keysyms; there is no text field in this window, so
	// single letters are the command surface.
	//
	// `app.win` is nil in the offscreen capture mode, which drives this same
	// procedure with synthetic keys.
	if app.win != nil && p.key_pressed(ui, 'q', false) {
		p.quit_app(app.win)
	}

	if p.key_pressed(ui, p.KEY_TAB, false) {
		app.panel = app.panel == .Stats ? .Devices : .Stats
	}
	if p.key_pressed(ui, 'd', false) {
		app.panel = .Devices
	}
	if p.key_pressed(ui, 's', false) {
		app.panel = .Stats
	}
	if p.key_pressed(ui, 'r', false) {
		devices_scan(&app.devs)
		log_line(app, "rescanned: %s", app.devs.note)
	}

	if p.key_pressed(ui, 'm', false) {
		app.a.muted = !app.a.muted
		send_control(s, .State, app.a.muted, app.v.camera_off)
		log_line(app, app.a.muted ? "microphone muted" : "microphone live")
	}
	if p.key_pressed(ui, 'v', false) {
		app.v.camera_off = !app.v.camera_off
		send_control(s, .State, app.a.muted, app.v.camera_off)
		log_line(app, app.v.camera_off ? "camera off" : "camera on")
	}

	before := s.state
	if p.key_pressed(ui, 'c', false) {
		if s.state == .Idle || s.state == .Ended {
			dial(s, app.a.muted, app.v.camera_off)
		}
	}
	if p.key_pressed(ui, p.KEY_RETURN, false) {
		switch s.state {
		case .Ringing:
			accept_call(s, app.a.muted, app.v.camera_off)
		case .Idle, .Ended:
			dial(s, app.a.muted, app.v.camera_off)
		case .Dialing, .Connecting, .Connected:
		}
	}
	if p.key_pressed(ui, 'h', false) || p.key_pressed(ui, p.KEY_ESCAPE, false) {
		if s.state == .Ended {
			reset_call(s)
		} else {
			hang_up(s)
		}
	}
	if before != s.state {
		on_state_change(app, before)
	}

	// Volume, which is applied by restarting the player — pw-play takes its
	// volume once, at startup.
	vol_changed := false
	if p.key_pressed(ui, ']') {
		app.a.volume = min(1, app.a.volume + 0.05)
		vol_changed = true
	}
	if p.key_pressed(ui, '[') {
		app.a.volume = max(0, app.a.volume - 0.05)
		vol_changed = true
	}
	if vol_changed && call_active(s) {
		child_stop(&app.a.play)
		pargv := audio_playback_argv(sel_sink(&app.devs), app.a.volume)
		pc, perr := spawn_writer(pargv, A_FRAME_BYTES * 4)
		if perr == "" {
			app.a.play = pc
		}
	}

	if app.panel == .Devices {
		if p.key_pressed(ui, p.KEY_UP) {
			app.focus_row = max(0, app.focus_row - 1)
		}
		if p.key_pressed(ui, p.KEY_DOWN) {
			app.focus_row = min(2, app.focus_row + 1)
		}
		delta := 0
		if p.key_pressed(ui, p.KEY_RIGHT) {
			delta = 1
		}
		if p.key_pressed(ui, p.KEY_LEFT) {
			delta = -1
		}
		if delta != 0 {
			switch app.focus_row {
			case 0:
				try_select(app, app.devs.sources[:], &app.devs.src_sel, delta)
			case 1:
				try_select(app, app.devs.cameras[:], &app.devs.cam_sel, delta)
			case 2:
				try_select(app, app.devs.sinks[:], &app.devs.sink_sel, delta)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// One step of the pipeline, shared by the windowed loop and the headless one.
// ---------------------------------------------------------------------------

step :: proc(app: ^App, t: f64, dt: f32) {
	app.t = t
	app.dt = dt

	pump_receive(app)

	if app.autoanswer && app.s.state == .Ringing {
		before := app.s.state
		accept_call(&app.s, app.a.muted, app.v.camera_off)
		on_state_change(app, before)
	}

	before := app.s.state
	session_tick(&app.s, app.t, app.a.muted, app.v.camera_off)
	if before != app.s.state {
		on_state_change(app, before)
	}

	if call_active(&app.s) {
		renegotiate_video(app)
		audio_pump_capture(&app.a, &app.s, app.dt)
		audio_pump_playout(&app.a, app.dt)
		video_pump_capture(&app.v, &app.s, app.t)
		// A decoder is a process and answers on its own schedule, so it is
		// drained every tick rather than only when a datagram arrives.
		video_pump_decoders(&app.v)

		supervise_media(app)
	} else {
		meter_follow(&app.a.tx_level, 0, app.dt)
		meter_follow(&app.a.rx_level, 0, app.dt)
	}
}

// ---------------------------------------------------------------------------
// The headless peer.
//
// The same pipeline with no window: a call needs two ends and a screenshot
// only wants one of them on screen. It also makes the measurements honest —
// the latency and frame-rate figures come out of this loop with no rasteriser
// competing for the CPU.
//
// It ticks at 250 Hz, which is twelve times the 20 ms audio frame and eight
// times the 30 fps video frame: often enough that the pipes are never the
// bottleneck, cheap enough to be invisible in `top`.
// ---------------------------------------------------------------------------

HEADLESS_TICK :: 4 * time.Millisecond

headless_run :: proc(app: ^App, seconds: f64) {
	fmt.printfln(
		"call: headless, bound 127.0.0.1:%d, peer 127.0.0.1:%d, %s, video offer %s",
		app.s.bind_port,
		app.s.peer.port,
		app.a.codec,
		codec_offer_label(app.v.offer),
	)
	start := time.tick_now()
	last := start
	report := 0.0

	if app.autocall {
		before := app.s.state
		dial(&app.s, app.a.muted, app.v.camera_off)
		on_state_change(app, before)
	}

	for {
		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last, now)))
		last = now
		t := time.duration_seconds(time.tick_diff(start, now))

		step(app, t, clamp(dt, 0, 0.1))

		if t - report >= 1.0 {
			report = t
			print_stats(app, t)
		}
		if seconds > 0 && t > seconds {
			break
		}
		time.sleep(HEADLESS_TICK)
	}

	// Summarise before tearing the pipelines down, so the figures describe the
	// call rather than the moment after it.
	print_summary(app)
	if call_active(&app.s) {
		for _ in 0 ..< 3 {
			send_control(&app.s, .Bye, false, false)
		}
	}
	stop_media(app)
}

print_stats :: proc(app: ^App, t: f64) {
	a := &app.a
	v := &app.v
	s := &app.s
	fmt.printfln(
		"%.1fs  %-10s  audio %.1f ms (wire %.2f, player q %.1f)  jb hold %.0f ms conceal %d late %d  "+
		"video %s out %.1f in %.1f fps %dx%d  net tx %.0f rx %.0f kbit/s",
		t,
		state_label(s.state),
		a.stats.last_us / 1000,
		a.stats.wire_last_us / 1000,
		a.play_queue_us / 1000,
		jb_depth_ms(&a.jb, A_FRAME_MS),
		a.jb.concealed,
		a.jb.too_late,
		video_codec_name(v.codec),
		v.fps_tx,
		v.fps_rx,
		v.has_remote ? v.remote.w : 0,
		v.has_remote ? v.remote.h : 0,
		s.tx_kbps,
		s.rx_kbps,
	)
}

print_summary :: proc(app: ^App) {
	a := &app.a
	v := &app.v
	s := &app.s
	fmt.println("")
	fmt.println("── measured over the whole call ──")
	fmt.printfln("  audio codec        %s", a.codec)
	fmt.printfln(
		"  video codec        %s  (offered %s, peer offered %s)",
		video_codec_name(v.codec),
		codec_offer_label(v.offer),
		codec_offer_label(v.peer_offer),
	)
	fmt.printfln("  audio frames       %d sent, %d played", a.frames_sent, a.frames_played)
	if a.stats.n > 0 {
		fmt.printfln(
			"  capture→player     mean %.2f ms   min %.2f   max %.2f   n=%d",
			stat_mean(&a.stats) / 1000,
			a.stats.min_us / 1000,
			a.stats.max_us / 1000,
			a.stats.n,
		)
		fmt.printfln(
			"  player queue       mean %.2f ms, peak %.2f ms (modelled from the 48 kHz drain, after priming)",
			play_queue_mean_us(a) / 1000,
			a.play_queue_max_us / 1000,
		)
		fmt.printfln(
			"  capture backlog    %.2f ms now, %.2f ms peak (measured on the capture pipe)",
			a.cap_backlog_us / 1000,
			a.cap_backlog_max_us / 1000,
		)
		fmt.printfln(
			"  framer→speaker     %.2f ms   = measured %.2f + downstream %.2f",
			audio_end_to_end_ms(a),
			stat_mean(&a.stats) / 1000,
			max(play_queue_mean_us(a) / 1000, PLAYER_LATENCY_MS),
		)
	}
	if a.stats.wire_n > 0 {
		fmt.printfln(
			"  capture→received   mean %.3f ms   n=%d",
			stat_wire_mean(&a.stats) / 1000,
			a.stats.wire_n,
		)
	}
	fmt.printfln(
		"  jitter buffer      %d played, %d concealed (%.2f%%), %d duplicate, %d late, %d resync, %d trimmed, %d starve",
		a.jb.played,
		a.jb.concealed,
		jb_loss_percent(&a.jb),
		a.jb.duplicates,
		a.jb.too_late,
		a.jb.resyncs,
		a.jb.trimmed,
		a.jb.starved,
	)
	fmt.printfln("  capture drops      %d (pipe %d B)", a.cap_backlog_drops, a.cap_pipe_bytes)
	fmt.printfln(
		"  video              %d sent, %d decoded, %d failed, %.1f fps out, %.1f fps in",
		v.frames_sent,
		v.frames_decoded,
		v.frames_failed,
		v.fps_tx,
		v.fps_rx,
	)
	if v.has_remote {
		fmt.printfln("  frame size         %dx%d, %.2f KB mean, %.2f KB last, %.2f ms to decode",
			v.remote.w, v.remote.h,
			video_mean_frame_bytes(v) / 1024,
			f32(v.last_frame_bytes) / 1024,
			v.decode_ms)
	}
	fmt.printfln(
		"  video wire         %.0f kbit/s of video alone (%d frames, %.2f MB)",
		f32(v.bytes_sent) * 8 / 1000 / f32(max(0.001, s.t)),
		v.frames_sent,
		f32(v.bytes_sent) / 1_000_000,
	)
	fmt.printfln(
		"  keyframes          %d sent, %d received, %d forced by request (interval %d s)",
		v.keyframes_sent,
		v.keyframes_rx,
		v.keyframes_forced,
		V_GOP_SECONDS,
	)
	fmt.printfln(
		"  loss path          %d gaps seen, %d keyframe requests out, %d in, %d frames skipped waiting",
		v.loss_events,
		v.pli_sent,
		v.pli_rx,
		v.frames_skipped,
	)
	if v.dec.starts > 0 || v.dec_self.starts > 0 {
		fmt.printfln(
			"  h264 decoders      peer %d in / %d out / %d dropped / %d starts, self %d in / %d out%s",
			v.dec.pushed,
			v.dec.frames,
			v.dec.dropped,
			v.dec.starts,
			v.dec_self.pushed,
			v.dec_self.frames,
			v.dec.error == "" ? "" : fmt.tprintf(" — %s", v.dec.error),
		)
	}
	if v.latency_n > 0 {
		fmt.printfln("  video latency      mean %.2f ms, n=%d", video_latency_mean_us(v) / 1000, v.latency_n)
	}
	fmt.printfln(
		"  reassembly         %d complete, %d partial-evicted, %d late",
		v.reasm.completed,
		v.reasm.dropped,
		v.reasm.late,
	)
	fmt.printfln(
		"  transport          %d pkt / %.1f MB out, %d pkt / %.1f MB in, %d rejected",
		s.tx_packets,
		f32(s.tx_bytes) / 1_000_000,
		s.rx_packets,
		f32(s.rx_bytes) / 1_000_000,
		s.rx_bad,
	)
	if s.drop_permille > 0 {
		fmt.printfln(
			"  deliberate loss    %d of 1000 video fragments asked for, %d actually dropped",
			s.drop_permille,
			s.tx_dropped,
		)
	}
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
	args, aerr := parse_args()
	if aerr == "help" {
		fmt.print(USAGE)
		return
	}
	if aerr != "" {
		fmt.eprintfln("call: %s", aerr)
		fmt.eprint(USAGE)
		os.exit(2)
	}
	if args.self_test {
		os.exit(run_self_test())
	}

	app := new(App)
	defer free(app)
	app.allow_real = args.allow_real
	app.autocall = args.autocall
	app.autoanswer = args.autoanswer
	app.quit_after = args.quit_after

	devices_init(&app.devs)
	devices_scan(&app.devs)
	defer devices_destroy(&app.devs)

	audio_init(&app.a)
	if args.volume >= 0 {
		app.a.volume = f32(args.volume)
	}
	defer audio_destroy(&app.a)
	video_init(&app.v)
	if args.pattern != "" {
		synth_source = args.pattern
	}
	if args.video != "" {
		if e := parse_video_size(args.video); e != "" {
			fmt.eprintfln("call: %s", e)
			os.exit(2)
		}
	}
	if args.bitrate > 0 {
		v_bitrate_kbps = args.bitrate
	}
	app.v.ask_keyframes = !args.no_pli
	{
		mask, e := parse_codec_offer(args.codec)
		if e != "" {
			fmt.eprintfln("call: %s", e)
			os.exit(2)
		}
		app.v.offer = mask
	}
	defer video_destroy(&app.v)

	if e := session_open(&app.s, args.bind, args.peer, args.name); e != "" {
		fmt.eprintfln("call: %s", e)
		os.exit(1)
	}
	defer session_close(&app.s)
	// What we advertise on every control message is exactly what this instance
	// can decode, so there is one source of truth for it.
	app.s.codecs = app.v.offer
	app.s.drop_permille = args.loss

	log_line(app, "bound 127.0.0.1:%d, peer 127.0.0.1:%d", args.bind, args.peer)
	log_line(app, "%s", app.devs.note)
	if !app.allow_real {
		log_line(app, "real devices listed but locked (synthetic sources)")
	}

	if args.shot != "" {
		sw, sh := 1180, 780
		if args.shot_size != "" {
			if x := strings.index_byte(args.shot_size, 'x'); x > 0 {
				w, wok := strconv.parse_int(args.shot_size[:x])
				h, hok := strconv.parse_int(args.shot_size[x + 1:])
				if wok && hok && w >= 320 && h >= 240 {
					sw, sh = w, h
				}
			}
		}
		shot_run(app, args.shot, args.shot_at, args.quit_after, sw, sh)
		return
	}

	if args.headless {
		headless_run(app, args.quit_after)
		return
	}

	win, werr := kit.start(
		{
			title = fmt.tprintf("Call — %s", args.name),
			width = 1180,
			height = 780,
			min_width = 920,
			min_height = 620,
			always = true, // media, not a form: present every vsync
		},
		true, // dark; a call app is a dark room
	)
	if werr != "" {
		fmt.eprintfln("call: %s", werr)
		os.exit(1)
	}
	app.win = win
	defer p.destroy(win)

	// Announce ourselves so the other instance can show a name before anyone
	// dials. A lost hello costs nothing; the invite carries the name too.
	send_control(&app.s, .Hello, false, false)

	started := false
	for ui in p.frames(win) {
		if !started {
			started = true
			if app.autocall {
				before := app.s.state
				dial(&app.s, app.a.muted, app.v.camera_off)
				on_state_change(app, before)
			}
		}

		handle_keys(app, ui)
		step(app, f64(p.app_elapsed(win)), ui.dt)
		draw_ui(app, ui)

		if app.quit_after > 0 && app.t > app.quit_after {
			p.quit_app(win)
		}
	}

	// Never leave a capture process holding a device.
	if call_active(&app.s) {
		for _ in 0 ..< 3 {
			send_control(&app.s, .Bye, false, false)
		}
	}
	stop_media(app)
}

// ---------------------------------------------------------------------------
// Offscreen capture.
//
// The same interface, the same live media pipeline, rendered into an ordinary
// pixel buffer with no compositor involved. This exists because iterating on a
// call UI by taking screenshots of a real window is miserable on a machine
// where several other programs are opening and closing windows: the grab is a
// screen region, so anything that overlaps ends up in the picture.
//
// It is not a mock. The capture processes are running, the sockets are open,
// the far end is a second instance, and the numbers on screen are the numbers
// the pipeline is producing — the only difference is where the pixels land.
// ---------------------------------------------------------------------------

Shot :: struct {
	at:   f64,
	key:  u32,
	sent: bool, // the key has been queued; once is once
	done: bool,
}

parse_shots :: proc(spec: string) -> []Shot {
	out := make([dynamic]Shot)
	if spec == "" {
		append(&out, Shot{at = 6})
		return out[:]
	}
	for part in strings.split(spec, ",", context.temp_allocator) {
		t := strings.trim_space(part)
		if t == "" {
			continue
		}
		key: u32
		if c := strings.index_byte(t, ':'); c >= 0 {
			name := t[c + 1:]
			t = t[:c]
			switch name {
			case "Tab":
				key = p.KEY_TAB
			case "Return":
				key = p.KEY_RETURN
			case "Escape":
				key = p.KEY_ESCAPE
			case "Down":
				key = p.KEY_DOWN
			case "Up":
				key = p.KEY_UP
			case "Left":
				key = p.KEY_LEFT
			case "Right":
				key = p.KEY_RIGHT
			case:
				if len(name) > 0 {
					key = u32(name[0])
				}
			}
		}
		secs, ok := strconv.parse_f64(strings.trim_space(t))
		if !ok {
			continue
		}
		append(&out, Shot{at = secs, key = key})
	}
	return out[:]
}

shot_run :: proc(app: ^App, prefix, spec: string, seconds: f64, width, height: int) {
	shots := parse_shots(spec)
	defer delete(shots)
	last_at := 0.0
	for sh in shots {
		last_at = max(last_at, sh.at)
	}
	deadline := seconds > 0 ? seconds : last_at + 1.5

	off := p.offscreen_create(width, height, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)

	start := time.tick_now()
	last := start
	n := 0

	if app.autocall {
		before := app.s.state
		dial(&app.s, app.a.muted, app.v.camera_off)
		on_state_change(app, before)
	}

	for {
		now := time.tick_now()
		dt := f32(time.duration_seconds(time.tick_diff(last, now)))
		last = now
		t := time.duration_seconds(time.tick_diff(start, now))

		step(app, t, clamp(dt, 0, 0.1))

		// A key for the next due shot goes in before the frame is built, so
		// the picture shows the state the key produced.
		for &sh in shots {
			if !sh.sent && sh.key != 0 && t >= sh.at - 0.12 {
				sh.sent = true
				p.press_key(off, sh.key)
			}
		}

		off.dt = clamp(dt, 0, 0.1)
		ui := p.offscreen_begin(off)
		handle_keys(app, ui)
		draw_ui(app, ui)
		p.offscreen_end(off)

		for &sh in shots {
			if !sh.done && t >= sh.at {
				sh.done = true
				n += 1
				path := fmt.tprintf("%s-%d.png", prefix, n)
				p.offscreen_write_png(off, path)
				fmt.printfln("wrote %s at %.1fs — %s", path, t, state_label(app.s.state))
			}
		}

		if t > deadline {
			break
		}
		time.sleep(8 * time.Millisecond)
	}

	print_summary(app)
	if call_active(&app.s) {
		for _ in 0 ..< 3 {
			send_control(&app.s, .Bye, false, false)
		}
	}
	stop_media(app)
}
