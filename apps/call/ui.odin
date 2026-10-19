package call

// ---------------------------------------------------------------------------
// The interface.
//
// A call window is mostly one big picture with a thin layer of state around
// it, so the layout is a video stage that takes all the room it can and a
// fixed instrument column beside it. Everything that moves — the level
// meters, the remote frame, the self-view — is drawn through `p.pixels` or
// `p.draw_image` straight onto the buffer; everything that reads — names,
// badges, numbers, buttons — is shadcn.
//
// Clicks cannot be synthesised on this compositor, so every control has a
// letter and the letter is printed on the control. The buttons are live for a
// real pointer as well.
// ---------------------------------------------------------------------------

import "core:fmt"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// The video stage
// ---------------------------------------------------------------------------

// draw_remote blits the decoded remote frame, letterboxed into the tile. This
// is the one place in the app where a video frame becomes pixels: stb_image
// produced the Image, `fitted_rect` picks the destination, and `draw_image`
// samples it.
draw_remote :: proc(c: ^p.Canvas, r: p.Rect, v: ^Video) {
	p.fill_rect(c, r, p.hex(0xff09090b))
	// A peer who turned their camera off gets the placeholder, not their last
	// frame held forever. "Is it frozen, or did they stop sending?" is a
	// question a call application should never make you ask.
	if !v.has_remote || v.peer_cam_off || v.remote.w <= 0 {
		return
	}
	dst := p.fitted_rect(f32(v.remote.w), f32(v.remote.h), r, .Contain)
	p.draw_image(c, v.remote, dst)
}

// ---------------------------------------------------------------------------
// Level meter
//
// Twenty segments, the top four amber and the top two red, with a peak-hold
// tick. A bar that just grows tells you the level; segments tell you the level
// and the headroom, which is what you look at a meter for.
// ---------------------------------------------------------------------------

Meter :: struct {
	level: f32,
	peak:  f32,
	live:  bool,
}

METER_SEGMENTS :: 24

// The two fixed bars, in points. They are constants rather than classes
// because `draw_ui` subtracts them from the viewport to size the body; a
// mismatch between the number here and the class on the element would show up
// as a sliver of background at the bottom of the window.
HEADER_H :: 56
CONTROLS_H :: 64

draw_meter :: proc(c: ^p.Canvas, r: p.Rect, m: ^Meter) {
	gap: f32 = 2
	w := (r.w - gap * f32(METER_SEGMENTS - 1)) / f32(METER_SEGMENTS)
	if w <= 0 {
		return
	}
	lit := int(m.level * f32(METER_SEGMENTS) + 0.5)
	peak := int(m.peak * f32(METER_SEGMENTS) + 0.5)

	for i in 0 ..< METER_SEGMENTS {
		x := r.x + f32(i) * (w + gap)
		seg := p.Rect{x, r.y, w, r.h}

		on := i < lit && m.live
		is_peak := m.live && peak > 0 && i == peak - 1

		col: p.Color
		switch {
		case i >= METER_SEGMENTS - 2:
			col = on || is_peak ? p.hex(0xfff43f5e) : p.hex(0xff2a1620)
		case i >= METER_SEGMENTS - 6:
			col = on || is_peak ? p.hex(0xfff59e0b) : p.hex(0xff2a2113)
		case:
			col = on || is_peak ? p.hex(0xff34d399) : p.hex(0xff14251f)
		}
		p.fill_round_rect(c, seg, {1.5, 1.5, 1.5, 1.5}, col)
	}
}

// ---------------------------------------------------------------------------
// Small pieces
// ---------------------------------------------------------------------------

stat_row :: proc(ui: ^p.Ctx, label: string, value: string, tone := "") {
	p.row(ui, "w-full items-baseline justify-between gap-3 py-[1]")
	defer p.end(ui)
	// The number is what you came for, so it keeps its width and the label
	// truncates. The other way round gives you a three-line packet count.
	p.text(ui, label, "flex-1 text-xs text-muted-foreground truncate")
	cls :=
		tone == "" \
		? "text-xs font-mono text-foreground whitespace-nowrap" \
		: fmt.tprintf("text-xs font-mono whitespace-nowrap %s", tone)
	p.text(ui, value, cls)
	p.style(ui).shrink = 0
}

section_title :: proc(ui: ^p.Ctx, label: string) {
	p.text(ui, label, "text-[10] font-semibold uppercase tracking-wider text-muted-foreground pt-1")
}

// key_button is a button with its keyboard letter in a Kbd chip, which is the
// only honest way to present a control in a window that cannot be clicked by
// the test harness.
key_button :: proc(
	ui: ^p.Ctx,
	label: string,
	letter: string,
	ic: p.Icon,
	v: sc.Variant,
) -> bool {
	idx := sc.button_open(ui, v, .LG, {})
	p.apply(ui, "gap-2 px-3")
	hit := p.clickable(ui)
	if p.is_hovered(ui, idx) && v != .Default {
		p.apply(ui, "bg-muted")
	}
	p.icon(ui, ic, "size-4 shrink-0")
	p.text(ui, label, "whitespace-nowrap")
	p.style(ui).shrink = 0
	// On a filled button the chip sits on the primary colour, so it has to
	// take its contrast from the foreground rather than from the page.
	p.div(ui, "ml-1 px-1.5 rounded border shrink-0")
	p.apply(
		ui,
		v == .Default \
		? "border-primary-foreground/30 bg-primary-foreground/10" \
		: "border-border/60 bg-background/40",
	)
	p.text(ui, letter, "text-[10] font-mono whitespace-nowrap")
	p.apply(ui, v == .Default ? "text-primary-foreground/80" : "text-muted-foreground")
	p.end(ui)
	sc.button_end(ui)
	return hit
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

state_tone :: proc(s: Call_State) -> string {
	switch s {
	case .Connected:
		return "text-emerald-400"
	case .Connecting, .Dialing:
		return "text-amber-400"
	case .Ringing:
		return "text-sky-400"
	case .Ended:
		return "text-destructive"
	case .Idle:
		return "text-muted-foreground"
	}
	return ""
}

draw_header :: proc(app: ^App, ui: ^p.Ctx) {
	s := &app.s
	p.row(ui, "h-[56] shrink-0 items-center gap-3 px-4 border-b border-border bg-card")
	defer p.end(ui)

	// A pulsing dot while something is in flight; a steady one when up.
	pulse: f32 = 1
	if s.state == .Dialing || s.state == .Ringing || s.state == .Connecting {
		ph := f32(app.t) * 2.2
		pulse = 0.35 + 0.65 * (0.5 + 0.5 * sin01(ph))
	}
	p.div(ui, "size-2.5 rounded-full shrink-0")
	p.apply(
		ui,
		s.state == .Connected \
		? "bg-emerald-400" \
		: s.state == .Ended ? "bg-destructive" : s.state == .Idle ? "bg-muted-foreground" : "bg-amber-400",
	)
	p.style(ui).opacity = pulse
	p.end(ui)

	p.text(ui, "Call", "text-sm font-semibold")
	p.style(ui).shrink = 0

	sc.separator(ui, .Vertical, "h-5")

	p.textf(ui, "text-sm text-muted-foreground", "%s", s.name)
	p.style(ui).shrink = 0
	p.icon(ui, sc.ICON_ARROW_RIGHT, "size-3.5 text-muted-foreground shrink-0")
	p.textf(ui, "text-sm font-medium", "%s", s.peer_name)
	p.style(ui).shrink = 0

	p.spacer(ui)

	if s.reason != "" && s.state != .Connected {
		sc.badge(ui, s.reason, .Outline)
	}
	p.text(
		ui,
		state_label(s.state),
		fmt.tprintf("text-sm font-medium whitespace-nowrap %s", state_tone(s.state)),
	)
	p.style(ui).shrink = 0

	if s.state == .Connected || s.state == .Connecting {
		d := int(call_duration(s))
		p.div(ui, "px-2 py-0.5 rounded-md bg-muted")
		p.textf(ui, "text-sm font-mono", "%02d:%02d", d / 60, d % 60)
		p.end(ui)
	}
}

sin01 :: proc(x: f32) -> f32 {
	// A cheap sine without pulling in core:math for one value.
	t := x
	for t > 6.2831853 {
		t -= 6.2831853
	}
	for t < 0 {
		t += 6.2831853
	}
	// Bhaskara approximation, plenty for a pulsing dot.
	if t > 3.14159265 {
		return -sin01(t - 3.14159265)
	}
	return 16 * t * (3.14159265 - t) / (5 * 3.14159265 * 3.14159265 - 4 * t * (3.14159265 - t))
}

// ---------------------------------------------------------------------------
// The stage: remote tile, self-view, overlays
// ---------------------------------------------------------------------------

draw_stage :: proc(app: ^App, ui: ^p.Ctx) {
	s := &app.s
	v := &app.v

	p.div(ui, "relative flex-1 rounded-xl overflow-hidden border border-border bg-[#09090b]")
	defer p.end(ui)

	v.peer_cam_off = s.peer_cam_off
	p.pixels(ui, "absolute inset-0", v, draw_remote)

	if !v.has_remote || s.peer_cam_off {
		// Nothing decoded yet: say which of the several reasons applies
		// rather than showing a black rectangle.
		p.col(ui, "absolute inset-0 items-center justify-center gap-3")
		defer p.end(ui)

		if s.state == .Ringing {
			p.icon(ui, ICON_PHONE_INCOMING, "size-12 text-sky-400")
			p.textf(ui, "text-xl font-semibold whitespace-nowrap", "%s is calling", s.peer_name)
			p.text(ui, "Enter to answer, H to decline", "text-sm text-muted-foreground whitespace-nowrap")
		} else if s.state == .Dialing {
			p.icon(ui, ICON_PHONE_OUTGOING, "size-12 text-amber-400", f32(app.t) * 0.15)
			p.textf(ui, "text-xl font-semibold whitespace-nowrap", "Calling %s", s.peer_name)
			p.textf(ui, "text-sm text-muted-foreground whitespace-nowrap", "127.0.0.1:%d", s.peer.port)
		} else if call_active(s) {
			if s.peer_cam_off {
				p.icon(ui, ICON_VIDEO_OFF, "size-12 text-muted-foreground")
				p.textf(
					ui,
					"text-lg font-medium whitespace-nowrap",
					"%s turned their camera off",
					s.peer_name,
				)
			} else {
				p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-10 text-muted-foreground", f32(app.t) * 0.9)
				p.text(ui, "Waiting for video", "text-sm text-muted-foreground")
			}
		} else {
			p.icon(ui, ICON_PHONE, "size-12 text-muted-foreground")
			p.text(
				ui,
				s.state == .Ended ? s.reason : "Ready to call",
				"text-xl font-semibold whitespace-nowrap",
			)
			p.text(
				ui,
				s.state == .Ended ? "C to call again" : fmt.tprintf("C to call 127.0.0.1:%d", s.peer.port),
				"text-sm text-muted-foreground whitespace-nowrap",
			)
		}
	}

	// The peer's tile chrome: name, mute and camera state.
	p.row(ui, "absolute left-3 bottom-3 items-center gap-2")
	p.div(ui, "flex-row items-center gap-2 px-2.5 py-1 rounded-lg bg-black/60")
	sc.avatar(ui, initials(s.peer_name), .SM)
	p.text(ui, s.peer_name, "text-sm font-medium text-white whitespace-nowrap")
	p.style(ui).shrink = 0
	if s.peer_muted {
		p.icon(ui, ICON_MIC_OFF, "size-3.5 text-rose-400 shrink-0")
	}
	if s.peer_cam_off {
		p.icon(ui, ICON_VIDEO_OFF, "size-3.5 text-rose-400 shrink-0")
	}
	p.end(ui)
	if v.has_remote && !s.peer_cam_off {
		p.div(ui, "flex-row items-center gap-1.5 px-2 py-1 rounded-lg bg-black/60")
		// The codec belongs on the picture, not only in the statistics panel.
		// It is the single most consequential thing about the stream — 300
		// kbit/s or 3.9 Mbit/s for the same rectangle — and the panel it would
		// otherwise live in is below the fold on a tall, narrow window.
		p.textf(
			ui,
			"text-[11] font-mono text-white/70",
			"%s  %dx%d  %.1f fps  %.0f kbit/s",
			video_codec_name(v.codec),
			v.remote.w,
			v.remote.h,
			v.fps_rx,
			s.rx_kbps,
		)
		p.end(ui)
	}
	p.end(ui)

	// Self-view, picture in picture.
	p.div(ui, "absolute right-3 top-3 w-[196] h-[110] rounded-lg overflow-hidden border border-white/15 bg-[#121214]")
	defer p.end(ui)
	if v.has_local && !v.camera_off {
		p.image(ui, v.local, "w-full h-full", .Cover)
	} else {
		p.col(ui, "w-full h-full items-center justify-center gap-1")
		p.icon(ui, v.camera_off ? ICON_VIDEO_OFF : ICON_CAMERA, "size-5 text-muted-foreground")
		p.text(ui, v.camera_off ? "Camera off" : "No preview", "text-[10] text-muted-foreground")
		p.end(ui)
	}
	p.div(ui, "absolute left-1.5 bottom-1.5 px-1.5 rounded bg-black/65")
	p.text(ui, "You", "text-[10] font-medium text-white")
	p.end(ui)
	if app.a.muted {
		p.div(ui, "absolute right-1.5 bottom-1.5 px-1 rounded bg-black/65 flex-row items-center")
		p.icon(ui, ICON_MIC_OFF, "size-3 text-rose-400")
		p.end(ui)
	}
}

// initials is the avatar's single letter. Slicing a byte off a UTF-8 string
// would cut a multi-byte name in half, so take a rune.
initials :: proc(name: string) -> string {
	for r, i in name {
		_ = r
		for j in i + 1 ..= len(name) {
			if j == len(name) || name[j] & 0xC0 != 0x80 {
				return name[:j]
			}
		}
	}
	return "?"
}

// ---------------------------------------------------------------------------
// Audio strip
// ---------------------------------------------------------------------------

// meter_block is one channel: a name, a reading, and the bar.
//
// `min-w-0` on the column and `truncate` on the name are what stop the two
// channels from overlapping when the window is narrow. A label that refuses to
// shrink does not get clipped by its parent here — it is drawn straight over
// the next one.
meter_block :: proc(ui: ^p.Ctx, label: string, m: ^Meter, right: string, tone: string) {
	p.col(ui, "flex-1 min-w-0 gap-1.5")
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.text(ui, label, "flex-1 min-w-0 text-xs font-medium truncate")
	p.text(ui, right, fmt.tprintf("text-[11] font-mono whitespace-nowrap %s", tone))
	p.style(ui).shrink = 0
	p.end(ui)

	p.pixels(ui, "h-3 w-full", m, draw_meter)
}

draw_audio_strip :: proc(app: ^App, ui: ^p.Ctx) {
	a := &app.a
	p.row(ui, "shrink-0 items-start gap-6 p-4 rounded-xl border border-border bg-card")
	defer p.end(ui)

	tx := &app.meter_tx
	rx := &app.meter_rx

	// Before the first call the engine has no labels yet, so name the devices
	// that *would* be opened. An empty strip reading "Your microphone —" is
	// worse than no strip.
	src := a.cap.running ? a.source_label : sel_source(&app.devs).name
	sink := a.play.running ? a.sink_label : sel_sink(&app.devs).name

	label_tx := a.muted ? "Muted" : fmt.tprintf("%.0f dB", level_db(a.tx_level))
	meter_block(
		ui,
		fmt.tprintf("You — %s", src),
		tx,
		label_tx,
		a.muted ? "text-rose-400" : "text-muted-foreground",
	)

	sc.separator(ui, .Vertical, "h-10 self-center")

	meter_block(
		ui,
		fmt.tprintf("%s — %s", app.s.peer_name, sink),
		rx,
		call_active(&app.s) ? fmt.tprintf("%.0f dB", level_db(a.rx_level)) : "idle",
		"text-muted-foreground",
	)
}

level_db :: proc(level: f32) -> f32 {
	if level <= 0 {
		return -60
	}
	return level * 60 - 60
}

short :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	return fmt.tprintf("%s…", s[:n - 1])
}

// elide_tokens shortens any single run of non-space characters longer than
// `n`. A command line wraps on spaces, and one 90-character lavfi expression
// with no spaces in it does not wrap at all — it just runs off the panel.
elide_tokens :: proc(cmd: string, n: int) -> string {
	b := strings.builder_make(context.temp_allocator)
	for tok, i in strings.split(cmd, " ", context.temp_allocator) {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if len(tok) > n {
			strings.write_string(&b, tok[:n - 1])
			strings.write_string(&b, "…")
		} else {
			strings.write_string(&b, tok)
		}
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// The instrument column
// ---------------------------------------------------------------------------

// kpi is one of the three numbers you actually watch during a call. They go
// above the detail because a panel you have to scroll to read is a panel you
// stop reading.
KPI_NONE :: "—"

kpi :: proc(ui: ^p.Ctx, label, value, unit, tone: string) {
	p.col(ui, "flex-1 items-center gap-0.5 py-2 rounded-lg bg-muted/40")
	defer p.end(ui)
	p.row(ui, "items-baseline gap-0.5")
	// A placeholder is not a reading, so it does not get a reading's colour.
	t := value == KPI_NONE ? "text-muted-foreground" : tone
	p.text(ui, value, fmt.tprintf("text-lg font-semibold font-mono whitespace-nowrap %s", t))
	p.style(ui).shrink = 0
	p.text(ui, unit, "text-[10] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
	p.text(ui, label, "text-[10] uppercase tracking-wider text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

draw_stats :: proc(app: ^App, ui: ^p.Ctx) {
	s := &app.s
	a := &app.a
	v := &app.v

	p.col(ui, "gap-1 px-4 pb-4")
	defer p.end(ui)

	p.row(ui, "w-full gap-2 pb-2")
	live := call_active(s)
	kpi(
		ui,
		"Audio",
		live && a.stats.n > 0 ? fmt.tprintf("%.0f", audio_end_to_end_ms(a)) : KPI_NONE,
		"ms",
		"text-emerald-400",
	)
	kpi(
		ui,
		"Video",
		live && v.fps_rx > 0 ? fmt.tprintf("%.0f", v.fps_rx) : KPI_NONE,
		"fps",
		live && v.fps_rx > f32(v_fps) * 0.85 ? "text-emerald-400" : "text-amber-400",
	)
	kpi(
		ui,
		"Loss",
		live ? fmt.tprintf("%.1f", jb_loss_percent(&a.jb)) : KPI_NONE,
		"%",
		a.jb.concealed > 0 ? "text-amber-400" : "text-foreground",
	)
	p.end(ui)

	section_title(ui, "Transport")
	stat_row(ui, "Local", fmt.tprintf("127.0.0.1:%d", s.bind_port))
	stat_row(ui, "Peer", fmt.tprintf("127.0.0.1:%d", s.peer.port))
	stat_row(ui, "Framing", fmt.tprintf("PCP1 · %d B hdr · %d B MTU", HDR, MTU_PAYLOAD))
	stat_row(ui, "Sent", fmt.tprintf("%d pkt · %.0f kbit/s", s.tx_packets, s.tx_kbps))
	stat_row(ui, "Received", fmt.tprintf("%d pkt · %.0f kbit/s", s.rx_packets, s.rx_kbps))
	stat_row(
		ui,
		"Rejected",
		fmt.tprintf("%d", s.rx_bad),
		s.rx_bad > 0 ? "text-amber-400" : "text-muted-foreground",
	)

	section_title(ui, "Audio")
	stat_row(ui, "Codec", short(a.codec, 28))
	stat_row(ui, "Format", fmt.tprintf("%d Hz mono · %d ms", A_RATE, A_FRAME_MS))
	if a.stats.n > 0 {
		stat_row(ui, "Capture to player", fmt.tprintf("%.1f ms", a.stats.last_us / 1000))
		stat_row(
			ui,
			"Latency mean",
			fmt.tprintf("%.1f ms · n=%d", stat_mean(&a.stats) / 1000, a.stats.n),
		)
		stat_row(
			ui,
			"Latency min/max",
			fmt.tprintf("%.1f / %.1f ms", a.stats.min_us / 1000, a.stats.max_us / 1000),
		)
		stat_row(ui, "Player queue", fmt.tprintf("%.1f ms · mean %.1f", a.play_queue_us / 1000, play_queue_mean_us(a) / 1000))
		stat_row(
			ui,
			"Capture to speaker",
			fmt.tprintf("%.1f ms", audio_end_to_end_ms(a)),
			"text-emerald-400",
		)
	} else {
		stat_row(ui, "Latency", "—")
	}
	if a.stats.wire_n > 0 {
		stat_row(ui, "Of which wire", fmt.tprintf("%.2f ms", stat_wire_mean(&a.stats) / 1000))
	}
	stat_row(ui, "Frames sent", fmt.tprintf("%d", a.frames_sent))
	stat_row(ui, "Frames played", fmt.tprintf("%d", a.frames_played))

	section_title(ui, "Jitter buffer")
	stat_row(
		ui,
		"Depth",
		fmt.tprintf("%.0f ms of %d", jb_depth_ms(&a.jb, A_FRAME_MS), JB_DEPTH * A_FRAME_MS),
	)
	stat_row(ui, "Target", fmt.tprintf("%d ms (%d frames)", JB_TARGET * A_FRAME_MS, JB_TARGET))
	stat_row(
		ui,
		"Concealed",
		fmt.tprintf("%d · %.2f%%", a.jb.concealed, jb_loss_percent(&a.jb)),
		a.jb.concealed > 0 ? "text-amber-400" : "text-muted-foreground",
	)
	stat_row(ui, "Duplicates", fmt.tprintf("%d", a.jb.duplicates))
	stat_row(
		ui,
		"Too late",
		fmt.tprintf("%d", a.jb.too_late),
		a.jb.too_late > 0 ? "text-amber-400" : "text-muted-foreground",
	)
	stat_row(ui, "Resyncs", fmt.tprintf("%d", a.jb.resyncs))
	if app.restarts > 0 {
		stat_row(
			ui,
			"Capture restarts",
			fmt.tprintf("%d of %d", app.restarts, RESTART_LIMIT),
			"text-amber-400",
		)
	}
	stat_row(ui, "Ceiling", fmt.tprintf("%d ms · %d trimmed", JB_MAX_HOLD * A_FRAME_MS, a.jb.trimmed))
	stat_row(
		ui,
		"Capture backlog",
		fmt.tprintf("%.0f ms · %d dropped", a.cap_backlog_us / 1000, a.cap_backlog_drops),
	)

	section_title(ui, "Video")
	stat_row(
		ui,
		"Codec",
		v.codec == .H264 \
		? fmt.tprintf("H.264 baseline · %d kbit/s", v_bitrate_kbps) \
		: fmt.tprintf("MJPEG q%s", V_QUALITY),
	)
	stat_row(
		ui,
		"Negotiated",
		fmt.tprintf("ours %s · peer %s", codec_offer_label(v.offer), codec_offer_label(v.peer_offer)),
	)
	stat_row(ui, "Configured", fmt.tprintf("%dx%d · %d fps", v_width, v_height, v_fps))
	stat_row(
		ui,
		"Measured out",
		fmt.tprintf("%.1f fps", v.fps_tx),
		v.fps_tx > f32(v_fps) * 0.85 ? "text-emerald-400" : "text-amber-400",
	)
	stat_row(
		ui,
		"Measured in",
		fmt.tprintf("%.1f fps", v.fps_rx),
		v.fps_rx > f32(v_fps) * 0.85 ? "text-emerald-400" : "text-amber-400",
	)
	if v.has_remote {
		stat_row(ui, "Decoded size", fmt.tprintf("%dx%d", v.remote.w, v.remote.h))
	}
	stat_row(
		ui,
		"Frame size",
		fmt.tprintf("%.2f KB · mean %.2f", f32(v.last_frame_bytes) / 1024, video_mean_frame_bytes(v) / 1024),
	)
	stat_row(ui, "Decode cost", fmt.tprintf("%.2f ms", v.decode_ms))
	if v.latency_n > 0 {
		stat_row(
			ui,
			"Frame latency",
			fmt.tprintf("%.1f ms · mean %.1f", v.latency_us / 1000, video_latency_mean_us(v) / 1000),
		)
	}
	stat_row(
		ui,
		"Reassembly",
		fmt.tprintf("%d ok · %d partial · %d late", v.reasm.completed, v.reasm.dropped, v.reasm.late),
	)
	stat_row(
		ui,
		"Decode fail",
		fmt.tprintf("%d", v.frames_failed),
		v.frames_failed > 0 ? "text-destructive" : "text-muted-foreground",
	)
	if v.codec == .H264 {
		stat_row(
			ui,
			"Keyframes",
			fmt.tprintf("%d out · %d in · every %d s", v.keyframes_sent, v.keyframes_rx, V_GOP_SECONDS),
		)
		stat_row(
			ui,
			"Loss recovery",
			fmt.tprintf(
				"%d gap · %d asked · %d forced · %d skipped",
				v.loss_events,
				v.pli_sent,
				v.keyframes_forced,
				v.frames_skipped,
			),
			v.loss_events > 0 ? "text-amber-400" : "text-muted-foreground",
		)
	}

	section_title(ui, "Window")
	stat_row(ui, "UI", fmt.tprintf("%.0f fps", p.frames_per_second(ui)))
}

device_row :: proc(ui: ^p.Ctx, app: ^App, label: string, list: []Device, sel: int, row: int) {
	focused := app.panel == .Devices && app.focus_row == row
	p.col(ui, "gap-1.5 p-2.5 rounded-lg border")
	p.apply(ui, focused ? "border-ring bg-muted/40" : "border-border/60 bg-background/40")
	defer p.end(ui)

	p.row(ui, "items-center gap-2")
	p.text(ui, label, "text-[10] font-semibold uppercase tracking-wider text-muted-foreground")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.textf(ui, "text-[10] font-mono text-muted-foreground", "%d/%d", sel + 1, max(1, len(list)))
	p.style(ui).shrink = 0
	p.end(ui)

	cur := Device{}
	if len(list) > 0 {
		cur = list[clamp(sel, 0, len(list) - 1)]
	}

	p.row(ui, "items-center gap-2")
	p.icon(ui, sc.ICON_CHEVRON_LEFT, focused ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground/40")
	p.text(ui, short(cur.name, 30), "flex-1 text-xs font-medium")
	p.icon(ui, sc.ICON_CHEVRON_RIGHT, focused ? "size-3.5 text-foreground" : "size-3.5 text-muted-foreground/40")
	p.end(ui)

	p.row(ui, "items-center gap-1.5")
	if cur.kind == .Synthetic {
		sc.badge(ui, "synthetic", .Secondary)
	} else if cur.real {
		sc.badge(ui, app.allow_real ? "real device" : "locked", app.allow_real ? .Default : .Destructive)
	} else {
		sc.badge(ui, "system default", .Outline)
	}
	if cur.is_default && cur.kind != .Synthetic {
		sc.badge(ui, "default", .Outline)
	}
	if cur.path != "" {
		p.text(ui, cur.path, "text-[10] font-mono text-muted-foreground")
	} else if cur.kind == .Camera {
		p.text(ui, "no /dev node", "text-[10] font-mono text-muted-foreground")
	}
	p.end(ui)
}

draw_devices :: proc(app: ^App, ui: ^p.Ctx) {
	d := &app.devs
	p.col(ui, "gap-2 px-4 pb-4")
	defer p.end(ui)

	p.text(
		ui,
		"Up/Down picks a row, Left/Right picks a device. R rescans.",
		"text-[11] text-muted-foreground leading-relaxed",
	)

	device_row(ui, app, "Microphone", d.sources[:], d.src_sel, 0)
	device_row(ui, app, "Camera", d.cameras[:], d.cam_sel, 1)
	device_row(ui, app, "Output", d.sinks[:], d.sink_sel, 2)

	if !app.allow_real {
		p.col(ui, "gap-1 p-2.5 rounded-lg border border-amber-500/30 bg-amber-500/5")
		p.row(ui, "items-center gap-1.5")
		p.icon(ui, sc.ICON_CIRCLE_ALERT, "size-3.5 text-amber-400 shrink-0")
		p.text(ui, "Real devices are locked", "text-xs font-medium text-amber-300")
		p.end(ui)
		p.text(
			ui,
			"Enumerated from wpctl and v4l2-ctl, but not openable. Start with --allow-real-devices to use the camera or microphone.",
			"text-[11] text-muted-foreground leading-relaxed",
		)
		p.end(ui)
	}

	if app.denied != "" && app.t - app.denied_at < 4 {
		p.div(ui, "p-2 rounded-lg bg-destructive/10 border border-destructive/30")
		p.text(ui, app.denied, "text-[11] text-destructive leading-relaxed")
		p.end(ui)
	}

	section_title(ui, "Pipelines")
	p.div(ui, "w-full p-2 rounded-lg bg-muted/40")
	p.text(
		ui,
		app.a.cap.running ? elide_tokens(app.a.cap.argv, 30) : "audio capture not running",
		"text-[10] font-mono text-muted-foreground leading-relaxed",
	)
	p.end(ui)
	p.div(ui, "w-full p-2 rounded-lg bg-muted/40")
	p.text(
		ui,
		app.v.cap.running ? elide_tokens(app.v.cap.argv, 30) : "video capture not running",
		"text-[10] font-mono text-muted-foreground leading-relaxed",
	)
	p.end(ui)
	p.div(ui, "w-full p-2 rounded-lg bg-muted/40")
	p.text(
		ui,
		app.a.play.running ? elide_tokens(app.a.play.argv, 30) : "playback not running",
		"text-[10] font-mono text-muted-foreground leading-relaxed",
	)
	p.end(ui)
	if app.a.cap_error != "" {
		p.text(ui, app.a.cap_error, "text-[11] text-destructive")
	}
	if app.v.cap_error != "" {
		p.text(ui, app.v.cap_error, "text-[11] text-destructive")
	}
}

// COMPACT_H is the window height below which the sidebar drops everything
// that is not a number. A tiled half-screen window on this display is 508
// points tall, and that has to still be a usable call window.
COMPACT_H :: 620

draw_sidebar :: proc(app: ^App, ui: ^p.Ctx) {
	compact := p.size(ui).y < COMPACT_H

	p.col(ui, "h-full w-[376] shrink-0 gap-0 rounded-xl border border-border bg-card overflow-hidden")
	defer p.end(ui)

	// Two tabs, switched by key as well as by click.
	p.row(ui, "shrink-0 items-center gap-1 p-2 border-b border-border")
	for tab, i in ([?]struct {
		label:  string,
		letter: string,
		panel:  Panel,
	}{{"Statistics", "S", .Stats}, {"Devices", "D", .Devices}}) {
		on := app.panel == tab.panel
		idx := p.div(ui, "flex-1 flex-row items-center justify-center gap-1.5 h-7 rounded-md cursor-pointer transition")
		p.apply(ui, on ? "bg-muted text-foreground" : "text-muted-foreground hover:bg-muted/50")
		if p.clickable(ui) {
			app.panel = tab.panel
		}
		p.text(ui, tab.label, "text-xs font-medium whitespace-nowrap")
		p.style(ui).shrink = 0
		p.div(ui, "px-1 rounded border border-border/60")
		p.text(ui, tab.letter, "text-[9] font-mono")
		p.end(ui)
		p.end(ui)
		_ = i
		_ = idx
	}
	p.end(ui)

	// flex-1 with min-h-0 is what lets this scroll instead of growing past the
	// card and painting over the activity log underneath it.
	p.col(ui, "flex-1 min-h-0 gap-0 pt-3 pb-3 overflow-scroll")
	switch app.panel {
	case .Stats:
		draw_stats(app, ui)
	case .Devices:
		draw_devices(app, ui)
	}
	p.end(ui)

	// The activity log: a call app has to say what it did. It is the first
	// thing to go when the window is short, because a tiled half-screen
	// window leaves the statistics panel clipping mid-row otherwise, and the
	// numbers are what the panel is for.
	if !compact {
		p.col(ui, "shrink-0 gap-0.5 p-3 border-t border-border bg-background/30")
		section_title(ui, "Activity")
		// The last four lines; this is a status strip, not a terminal.
		first := max(0, app.log_n - 4)
		for i in first ..< app.log_n {
			p.text(ui, app.log[i], "w-full text-[10] font-mono text-muted-foreground leading-snug truncate")
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

draw_controls :: proc(app: ^App, ui: ^p.Ctx) {
	s := &app.s
	before := s.state

	p.row(ui, "h-[64] shrink-0 items-center justify-center gap-2 px-4 border-t border-border bg-card")
	defer p.end(ui)

	// Mute and camera are always available: you set them before you dial.
	if key_button(
		ui,
		app.a.muted ? "Unmute" : "Mute",
		"M",
		app.a.muted ? ICON_MIC_OFF : ICON_MIC,
		app.a.muted ? .Destructive : .Outline,
	) {
		app.a.muted = !app.a.muted
		send_control(s, .State, app.a.muted, app.v.camera_off)
	}
	if key_button(
		ui,
		app.v.camera_off ? "Camera on" : "Camera off",
		"V",
		app.v.camera_off ? ICON_VIDEO_OFF : ICON_VIDEO,
		app.v.camera_off ? .Destructive : .Outline,
	) {
		app.v.camera_off = !app.v.camera_off
		send_control(s, .State, app.a.muted, app.v.camera_off)
	}

	sc.separator(ui, .Vertical, "h-8 mx-1")

	switch s.state {
	case .Idle, .Ended:
		if key_button(ui, s.state == .Ended ? "Call again" : "Call", "C", ICON_PHONE, .Default) {
			dial(s, app.a.muted, app.v.camera_off)
		}
		if s.state == .Ended {
			if key_button(ui, "Dismiss", "H", sc.ICON_X, .Ghost) {
				reset_call(s)
			}
		}
	case .Ringing:
		if key_button(ui, "Answer", "Enter", ICON_PHONE_CALL, .Default) {
			accept_call(s, app.a.muted, app.v.camera_off)
		}
		if key_button(ui, "Decline", "H", ICON_PHONE_OFF, .Destructive) {
			decline_call(s)
		}
	case .Dialing:
		if key_button(ui, "Cancel", "H", ICON_PHONE_OFF, .Destructive) {
			hang_up(s)
		}
	case .Connecting, .Connected:
		if key_button(ui, "Hang up", "H", ICON_PHONE_OFF, .Destructive) {
			hang_up(s)
		}
	}

	sc.separator(ui, .Vertical, "h-8 mx-1")

	// Volume, shown rather than hidden: it is restarted into pw-play.
	p.row(ui, "items-center gap-2 px-2")
	p.icon(ui, app.a.volume <= 0.001 ? ICON_VOLUME_X : sc.ICON_VOLUME_2, "size-4 text-muted-foreground")
	p.div(ui, "relative flex-row w-24 h-1 items-center rounded-full bg-muted overflow-hidden")
	p.div(ui, "h-full bg-primary")
	p.style(ui).w = p.pct(app.a.volume * 100)
	p.end(ui)
	p.end(ui)
	p.textf(ui, "text-[11] font-mono text-muted-foreground w-9", "%.0f%%", app.a.volume * 100)
	p.div(ui, "px-1 rounded border border-border/60")
	p.text(ui, "[ ]", "text-[9] font-mono text-muted-foreground")
	p.end(ui)
	p.end(ui)

	p.spacer(ui)

	p.textf(
		ui,
		"text-[10] font-mono text-muted-foreground whitespace-nowrap",
		"%s  ·  Q quits",
		app.allow_real ? "real devices unlocked" : "synthetic sources",
	)
	p.style(ui).shrink = 0

	if before != s.state {
		on_state_change(app, before)
	}
}

// ---------------------------------------------------------------------------
// Frame
// ---------------------------------------------------------------------------

draw_ui :: proc(app: ^App, ui: ^p.Ctx) {
	if app.room != nil {
		draw_room_ui(app, ui)
		return
	}
	// The meters are read by the draw procedures, which run after the tree is
	// built, so they are refreshed here rather than inside the layout.
	app.meter_tx = {level = app.a.tx_level, peak = app.a.tx_peak, live = app.a.cap.running}
	app.meter_rx = {level = app.a.rx_level, peak = app.a.rx_peak, live = app.a.play.running}

	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	draw_header(app, ui)

	// The body's height is set explicitly rather than left to `flex-1`.
	//
	// palmy resolves `flex-1` and `h-full` against the height the row had
	// *before* its children were shrunk to fit, so a row whose child is a tall
	// scrolling column reports a height larger than the space it was given,
	// and its siblings — here the controls bar — are laid out below the
	// window. `min-h-0` does not change that. Subtracting the two fixed bars
	// from the viewport is exact and does not depend on the measuring pass.
	sz := p.size(ui)
	body_h := max(160, sz.y - HEADER_H - CONTROLS_H)

	p.row(ui, "w-full items-stretch gap-4 p-4 overflow-hidden")
	p.style(ui).h = p.px(body_h)
	p.style(ui).shrink = 0

	p.col(ui, "h-full flex-1 min-w-0 gap-4 overflow-hidden")
	draw_stage(app, ui)
	draw_audio_strip(app, ui)
	p.end(ui)

	draw_sidebar(app, ui)
	p.end(ui)

	draw_controls(app, ui)
}
