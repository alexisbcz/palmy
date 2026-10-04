package main

// The two screens: the library and the player.

import "core:fmt"
import "core:math"
import "core:strings"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Player
// ---------------------------------------------------------------------------

build_player :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	st.vrect = {
		0,
		TOPBAR_H,
		size.x - (st.info ? PANEL_W + 1 : 0),
		size.y - TOPBAR_H - CTRL_H - STATUS_H,
	}

	player_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		p.col(ui, "flex-1 min-w-0 min-h-0 overflow-hidden")
		{
			p.col(ui, "w-full flex-1 min-h-0 relative overflow-hidden bg-black")
			p.pixels(ui, "w-full flex-1 min-h-0", st, draw_video)
			// The cue is looked up against the clock, not against the frame
			// that happens to be on screen: a dropped frame must not take the
			// subtitle with it.
			if cue, has := subs_text_at(&st.subs, st.open ? engine_clock(&st.e) : 0); has {
				subtitle_overlay(ui, st, cue)
			}
			if st.pending {
				badge_overlay(ui, "Re-opening at the new size…")
			} else if !st.e.first_frame {
				badge_overlay(ui, "Starting ffmpeg…")
			} else if st.ended {
				badge_overlay(ui, "End of file — Space to replay")
			}
			if st.stats {
				stats_overlay(ui, st)
			}
			if st.subs.panel {
				subs_panel(ui, st)
			}
			p.end(ui)

			transport(ui, st)
		}
		p.end(ui)

		if st.info {
			info_panel(ui, st)
		}
	}
	p.end(ui)

	status_bar(ui, st)
}

// draw_video blits the frame the engine is holding. The decode size is kept
// equal to the destination, so the common path is a row copy per scanline;
// `draw_image` only runs in the moment between a resize and the restart.
draw_video :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	px, fw, fh := engine_frame(&st.e)
	if px == nil || fw <= 0 || fh <= 0 {
		return
	}
	dst := p.fitted_rect(f32(fw), f32(fh), r, .Contain)
	x0 := int(math.round(dst.x))
	y0 := int(math.round(dst.y))

	if int(math.round(dst.w)) == fw && int(math.round(dst.h)) == fh && c.scale == 1 {
		clip := p.rect_intersect(r, c.clip)
		cx0 := max(x0, int(clip.x))
		cy0 := max(y0, int(clip.y))
		cx1 := min(x0 + fw, int(math.ceil(p.rect_right(clip))))
		cy1 := min(y0 + fh, int(math.ceil(p.rect_bottom(clip))))
		cx0 = max(cx0, 0)
		cy0 = max(cy0, 0)
		cx1 = min(cx1, c.w)
		cy1 = min(cy1, c.h)
		if cx1 <= cx0 || cy1 <= cy0 {
			return
		}
		n := cx1 - cx0
		for y in cy0 ..< cy1 {
			src := px[(y - y0) * fw + (cx0 - x0):][:n]
			dstrow := c.px[y * c.w + cx0:][:n]
			copy(dstrow, src)
		}
		return
	}

	img := p.Image {
		px              = px,
		w               = fw,
		h               = fh,
		source_channels = 3,
	}
	p.draw_image(c, img, dst)
}

// speed_label is "0.5x", "1x", "1.75x" — never "1.8x". `%g` rounds a quarter
// step to two significant digits and turns 1.75 into 1.8, which is a different
// speed from the one the keys just set.
speed_label :: proc(s: f64) -> string {
	t := fmt.tprintf("%.2f", s)
	t = strings.trim_right(t, "0")
	t = strings.trim_right(t, ".")
	return fmt.tprintf("%sx", t)
}

// subtitle_overlay draws the active cue over the picture.
//
// Two things make it legible on any frame rather than most of them. It sits
// inside the *picture*, not inside the video box — the letterbox bars are
// subtracted, so a 4:3 clip in a 16:9 window does not put its subtitles on the
// black below the image. And it carries its own plate, because white text alone
// disappears the moment the shot cuts to snow or a white wall.
SUB_SIZE :: f32(17)
SUB_PAD :: f32(28) // px-3.5 on both sides

subtitle_overlay :: proc(ui: ^p.Ctx, st: ^St, text: string) {
	// The cue is inset from the edges of the *picture*, so the letterbox bars
	// around a clip that does not match the window's aspect are not used.
	margin := f32(28)
	side := margin
	bottom := f32(24)
	avail := st.vrect.w - 2 * margin
	if st.e.w > 0 && st.e.h > 0 && st.vrect.w > 8 && st.vrect.h > 8 {
		r := p.fitted_rect(f32(st.e.w), f32(st.e.h), st.vrect, .Contain)
		side = margin + max(0, r.x - st.vrect.x)
		bottom = 24 + max(0, p.rect_bottom(st.vrect) - p.rect_bottom(r))
		avail = r.w - 2 * margin
	}
	avail = max(80, avail)

	lines := strings.split(text, "\n", context.temp_allocator)

	// The plate is sized from the text rather than left to the layout. A column
	// with `items-center` shrink-wraps its children, and a shrink-wrapped text
	// node has no width to wrap against until it has one — so left alone it
	// collapses to roughly one word per line. Measuring with the same font the
	// text will be drawn in and setting the width explicitly is the fix: under
	// the available width the plate is exactly as wide as its longest line and
	// nothing wraps, over it the plate takes the full width and the line wraps
	// where it should.
	widest := f32(0)
	nlines := 0
	for line in lines {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		nlines += 1
		if ui.fonts != nil {
			widest = max(widest, p.text_width(ui.fonts, t, SUB_SIZE, .Sans, .Medium))
		} else {
			widest = max(widest, f32(len(t)) * SUB_SIZE * 0.52)
		}
	}
	if nlines == 0 {
		return
	}
	plate_w := min(widest + SUB_PAD, avail)

	wrap := p.col(ui, "absolute items-center justify-end z-10")
	ws := p.style(ui, wrap)
	ws.inset[p.LEFT] = p.px(side)
	ws.inset[p.RIGHT] = p.px(side)
	ws.inset[p.BOTTOM] = p.px(bottom)
	ws.no_hit = true
	defer p.end(ui)

	plate := p.col(ui, "items-center gap-0.5 px-3.5 py-2 rounded-lg bg-black/70")
	ps := p.style(ui, plate)
	ps.w = p.px(plate_w)
	ps.shrink = 0
	ps.no_hit = true
	defer p.end(ui)

	// A cue is one or more lines and they have to stay separate lines: a two
	// line cue joined into one would overflow the plate and read wrong.
	for line in lines {
		t := strings.trim_space(line)
		if t == "" {
			continue
		}
		p.text(ui, t, "w-full text-[17] font-medium text-white text-center leading-snug")
		p.style(ui).no_hit = true
	}
}

// subs_panel lists every track that was found, including the ones that cannot
// be shown. A bitmap track silently doing nothing is the failure this avoids.
subs_panel :: proc(ui: ^p.Ctx, st: ^St) {
	box := p.col(
		ui,
		"absolute gap-1.5 p-3 rounded-lg bg-background/92 border border-border z-30 w-[320]",
	)
	bs := p.style(ui, box)
	bs.inset[p.LEFT] = p.px(14)
	// Top left, not bottom left: the cue plate lives at the bottom and a track
	// list covering the subtitle you are choosing a track for is no use.
	bs.inset[p.TOP] = p.px(14)
	defer p.end(ui)

	p.row(ui, "w-full items-center gap-2")
	p.icon(ui, IC_CAPTIONS, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "SUBTITLE TRACKS", "flex-1 text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70")
	sc.kbd(ui, "t")
	p.end(ui)

	if len(st.subs.tracks) == 0 {
		p.text(
			ui,
			"No sidecar file and no subtitle stream in this container.",
			"text-[11] text-muted-foreground",
		)
		return
	}

	for tr, i in st.subs.tracks {
		on := i == st.subs.active
		row := p.row(ui, "w-full items-center gap-2 px-2 py-1.5 rounded-md border")
		p.apply(ui, on ? "bg-accent border-border" : "border-transparent hover:bg-muted/60", row)
		if p.clickable(ui, row) {
			subs_select(&st.subs, i)
		}
		p.icon(
			ui,
			on ? IC_CHECK : (tr.bitmap ? IC_TRIANGLE_ALERT : IC_CAPTIONS),
			tr.bitmap ? "size-3.5 shrink-0 text-destructive" : "size-3.5 shrink-0 text-muted-foreground",
		)
		p.col(ui, "flex-1 min-w-0 gap-px")
		p.text(ui, tr.label, "text-[11] font-medium truncate")
		detail := ""
		switch {
		case tr.bitmap:
			detail = fmt.tprintf("%s — bitmap, cannot be shown as text", tr.codec)
		case tr.err != "":
			detail = tr.err
		case len(tr.cues) > 0:
			detail = fmt.tprintf(
				"%s · %d cues · %s",
				sub_format_name(tr.format),
				len(tr.cues),
				tr.src == .Sidecar ? base_of(tr.path) : fmt.tprintf("stream %d · %s", tr.index, tr.codec),
			)
		case:
			detail = tr.src == .Sidecar ? base_of(tr.path) : fmt.tprintf("stream %d · %s", tr.index, tr.codec)
		}
		p.text(ui, detail, tr.bitmap || tr.err != "" ? "text-[10] text-destructive truncate" : "text-[10] text-muted-foreground truncate")
		p.end(ui)
		p.end(ui)
	}

	p.row(ui, "w-full items-center gap-1.5 pt-1 border-t border-border")
	sc.kbd(ui, "c")
	p.text(ui, "cycle", "text-[10] text-muted-foreground whitespace-nowrap")
	sc.kbd(ui, "v")
	p.text(ui, "show/hide", "text-[10] text-muted-foreground whitespace-nowrap")
	sc.kbd(ui, "-")
	sc.kbd(ui, "=")
	p.textf(ui, "text-[10] text-muted-foreground whitespace-nowrap", "delay %+.1fs", st.subs.offset)
	p.end(ui)
}

badge_overlay :: proc(ui: ^p.Ctx, label: string) {
	box := p.div(
		ui,
		"absolute flex-row items-center gap-2 h-8 px-3 rounded-lg bg-background/85 border border-border z-20",
	)
	bs := p.style(ui, box)
	bs.inset[p.LEFT] = p.px(14)
	bs.inset[p.TOP] = p.px(14)
	sc.spinner(ui, "size-3.5 text-muted-foreground")
	p.text(ui, label, "text-xs text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

stats_overlay :: proc(ui: ^p.Ctx, st: ^St) {
	shown, dropped, decoded, queued, avg, mx, last, lat, locked := engine_stats(&st.e)
	box := p.col(
		ui,
		"absolute gap-1 p-3 rounded-lg bg-background/85 border border-border z-20 w-[268]",
	)
	bs := p.style(ui, box)
	bs.inset[p.RIGHT] = p.px(14)
	bs.inset[p.TOP] = p.px(14)
	defer p.end(ui)

	p.text(ui, "PIPELINE", "text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70")
	stat(ui, "Decode", fmt.tprintf("%d × %d @ %.3f fps", st.e.w, st.e.h, st.e.fps))
	sp := engine_speed(&st.e)
	stat(
		ui,
		"Speed",
		fmt.tprintf("%s · needs %.1f fps", speed_label(sp), st.e.fps * sp),
	)
	stat(ui, "Delivered", fmt.tprintf("%.1f fps", engine_decode_fps(&st.e)))
	stat(ui, "Frames", fmt.tprintf("%d shown · %d dropped", shown, dropped))
	stat(ui, "Queue", fmt.tprintf("%d / %d", queued, RING))
	stat(ui, "Decoded", fmt.tprintf("%d", decoded))

	p.text(ui, "A/V SYNC", "text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70 pt-1")
	if st.e.have_audio {
		stat(ui, "Clock", "pw-cat byte count")
		stat(
			ui,
			"Sink buffer",
			fmt.tprintf("%.0f ms%s", lat * 1000, locked ? " (measured)" : " (settling)"),
		)
		stat(ui, "Frame error", fmt.tprintf("%+.1f ms", last * 1000))
		stat(ui, "Mean |error|", fmt.tprintf("%.1f ms", avg * 1000))
		stat(ui, "Worst", fmt.tprintf("%.1f ms", mx * 1000))
		_, _, _, lavg, lmx, ln := engine_sync_stats(&st.e)
		if ln > 0 {
			stat(ui, "Since lock", fmt.tprintf("%.1f ms mean · %.1f ms worst", lavg * 1000, lmx * 1000))
		}
	} else {
		stat(ui, "Clock", "wall clock (no audio)")
		stat(ui, "Mean |error|", fmt.tprintf("%.1f ms", avg * 1000))
	}
	if st.seek_count > 0 {
		stat(
			ui,
			"Seek cost",
			fmt.tprintf("%.0f ms avg of %d", st.seek_ms_sum / f64(st.seek_count), st.seek_count),
		)
	}
}

stat :: proc(ui: ^p.Ctx, k, v: string) {
	p.row(ui, "w-full items-baseline gap-2")
	defer p.end(ui)
	p.text(ui, k, "w-[92] shrink-0 text-[11] text-muted-foreground whitespace-nowrap")
	p.text(ui, v, "flex-1 min-w-0 text-[11] font-medium truncate")
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

transport :: proc(ui: ^p.Ctx, st: ^St) {
	dur := max(st.e.m.duration, 0.001)
	now := st.open ? engine_clock(&st.e) : 0
	if st.scrubbing {
		now = st.scrub_at
	}
	now = clamp(now, 0, dur)

	p.col(ui, "w-full shrink-0 gap-2 px-4 py-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(CTRL_H)
	defer p.end(ui)

	// The scrub bar.
	p.row(ui, "w-full items-center gap-3")
	p.text(
		ui,
		timecode(now),
		"w-[56] shrink-0 text-xs font-medium tabular-nums text-right whitespace-nowrap",
	)
	scrub_bar(ui, st, now, dur)
	p.text(
		ui,
		timecode(dur),
		"w-[56] shrink-0 text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
	p.end(ui)

	// The buttons.
	p.row(ui, "w-full items-center gap-1.5")
	defer p.end(ui)

	ctrl(ui, st, IC_SKIP_BACK, .Prev, st.sel > 0)
	ctrl(ui, st, IC_STEP_BACK, .Step_Back, st.open)
	play_button(ui, st)
	ctrl(ui, st, IC_STEP_FORWARD, .Step_Fwd, st.open)
	ctrl(ui, st, IC_SKIP_FORWARD, .Next, st.sel + 1 < len(st.lib))

	p.div(ui, "w-2 shrink-0")
	p.end(ui)

	p.textf(
		ui,
		"shrink-0 text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
		"−%s",
		timecode(max(0, dur - now)),
	)

	// The chapter the clock is in, named, because a mark on the bar alone does
	// not tell you which one you are watching.
	if len(st.e.m.chapters) > 0 {
		if ci := chapter_at(st.e.m.chapters, now); ci >= 0 {
			p.div(ui, "w-2 shrink-0")
			p.end(ui)
			p.icon(ui, IC_LIST, "size-3.5 shrink-0 text-muted-foreground")
			p.textf(
				ui,
				"shrink-0 text-[11] text-muted-foreground whitespace-nowrap max-w-[200] truncate",
				"%d/%d %s",
				ci + 1,
				len(st.e.m.chapters),
				st.e.m.chapters[ci].title,
			)
		}
	}

	p.spacer(ui)

	speed_control(ui, st)

	// Volume.
	p.row(ui, "shrink-0 items-center gap-2")
	vol_icon := st.e.muted || st.e.volume < 0.01 \
		? IC_VOLUME_X \
		: (st.e.volume < 0.5 ? IC_VOLUME_1 : IC_VOLUME_2)
	vb := p.div(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-lg transition cursor-pointer")
	p.apply(ui, st.e.muted ? "text-destructive bg-muted" : "text-muted-foreground hover:bg-muted hover:text-foreground", vb)
	if p.clickable(ui, vb) {
		engine_mute(&st.e, !st.e.muted)
	}
	p.icon(ui, vol_icon, "size-4")
	p.end(ui)
	volume_bar(ui, st)
	p.textf(
		ui,
		"w-[34] shrink-0 text-[11] text-muted-foreground tabular-nums text-right whitespace-nowrap",
		"%d%%",
		int(st.e.volume * 100 + 0.5),
	)
	p.end(ui)
}

// speed_control is the speed, the two keys that change it and a click target on
// each. The number is always on screen when it is not 1x, because a player
// running at 1.5x with nothing to say so is a bug report waiting to happen.
speed_control :: proc(ui: ^p.Ctx, st: ^St) {
	sp := engine_speed(&st.e)
	p.row(ui, "shrink-0 items-center gap-1 mr-2")
	defer p.end(ui)

	step :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, d: f64, enabled: bool) {
		idx := p.div(ui, "size-7 shrink-0 flex-row items-center justify-center rounded-md transition cursor-pointer")
		p.apply(
			ui,
			enabled ? "text-muted-foreground hover:bg-muted hover:text-foreground" : "text-muted-foreground/25",
			idx,
		)
		if enabled && p.clickable(ui, idx) {
			engine_set_speed(&st.e, engine_speed(&st.e) + d)
		}
		p.icon(ui, ic, "size-3.5")
		p.end(ui)
	}

	p.icon(ui, IC_GAUGE, "size-3.5 shrink-0 text-muted-foreground")
	step(ui, st, IC_MINUS, -SPEED_STEP, sp > SPEED_MIN + 1e-9)
	// Clicking the number resets it, which is the gesture people try first.
	lab := p.div(ui, "w-[56] shrink-0 flex-row items-center justify-center h-7 rounded-md border transition cursor-pointer")
	p.apply(
		ui,
		abs(sp - 1) > 1e-9 ? "bg-accent border-border text-foreground" : "border-transparent text-muted-foreground hover:bg-muted",
		lab,
	)
	if p.clickable(ui, lab) {
		engine_set_speed(&st.e, 1)
	}
	p.text(ui, speed_label(sp), "text-[11] font-medium tabular-nums whitespace-nowrap")
	p.end(ui)
	step(ui, st, IC_PLUS, SPEED_STEP, sp < SPEED_MAX - 1e-9)
}

Ctrl_Act :: enum u8 {
	Prev,
	Next,
	Step_Back,
	Step_Fwd,
}

ctrl :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, act: Ctrl_Act, enabled: bool) {
	idx := p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg transition cursor-pointer")
	p.apply(
		ui,
		enabled ? "text-muted-foreground hover:bg-muted hover:text-foreground" : "text-muted-foreground/30",
		idx,
	)
	if enabled && p.clickable(ui, idx) {
		switch act {
		case .Prev:
			st.sel = max(0, st.sel - 1)
			start_playing(st)
		case .Next:
			st.sel = min(len(st.lib) - 1, st.sel + 1)
			start_playing(st)
		case .Step_Back:
			engine_pause(&st.e, true)
			step_frame(st, -1)
		case .Step_Fwd:
			engine_pause(&st.e, true)
			step_frame(st, 1)
		}
	}
	p.icon(ui, ic, "size-[18]")
	p.end(ui)
}

play_button :: proc(ui: ^p.Ctx, st: ^St) {
	playing := st.open && !engine_paused(&st.e)
	idx := p.div(
		ui,
		"size-10 shrink-0 flex-row items-center justify-center rounded-full bg-primary text-primary-foreground transition cursor-pointer hover:bg-primary/80",
	)
	if p.clickable(ui, idx) {
		if st.ended {
			seek_to(st, 0)
			engine_pause(&st.e, false)
		} else {
			engine_pause(&st.e, !engine_paused(&st.e))
		}
	}
	p.icon(ui, playing ? IC_PAUSE : IC_PLAY, "size-[18]")
	p.end(ui)
}

// scrub_bar is a real control: click anywhere to seek, drag to scrub. It is
// also the only progress indicator, so it has to read at a glance.
scrub_bar :: proc(ui: ^p.Ctx, st: ^St, now, dur: f64) {
	idx := p.div(ui, "flex-1 min-w-0 h-4 relative flex-row items-center cursor-pointer")
	id := p.node_id(ui, idx)
	r := p.rect_of(ui, id)
	hot := p.is_hovered(ui, idx)
	active := p.is_active(ui, idx)
	_ = p.clickable(ui, idx)

	if r.w > 2 {
		if active {
			t := f64(clamp((p.mouse_pos(ui).x - r.x) / r.w, 0, 1)) * dur
			st.scrubbing = true
			st.scrub_at = t
		} else if st.scrubbing {
			st.scrubbing = false
			seek_to(st, st.scrub_at)
		}
	}

	frac := f32(clamp(now / max(dur, 0.001), 0, 1))

	// Track.
	p.div(ui, "absolute w-full rounded-full bg-muted")
	ts := p.style(ui)
	ts.h = p.px(hot || active ? 6 : 4)
	ts.inset[p.LEFT] = p.px(0)
	ts.inset[p.RIGHT] = p.px(0)
	ts.no_hit = true
	{
		p.div(ui, "absolute h-full rounded-full bg-primary")
		fs := p.style(ui)
		fs.inset[p.LEFT] = p.px(0)
		fs.inset[p.TOP] = p.px(0)
		fs.inset[p.BOTTOM] = p.px(0)
		fs.inset[p.RIGHT] = p.pct((1 - frac) * 100)
		fs.no_hit = true
		p.end(ui)
	}
	p.end(ui)

	// Chapter marks. Drawn over the track and under the thumb, so the mark the
	// playhead sits on is not hidden by it.
	//
	// They go inside a full-size positioned box rather than straight into the
	// bar, for the same reason the thumb does: a percentage inset resolves
	// against a parent with a width, and this bar's own width is `flex-1` and
	// not known where the children are declared.
	if len(st.e.m.chapters) > 0 {
		p.div(ui, "absolute w-full h-full")
		cs := p.style(ui)
		cs.inset[p.LEFT] = p.px(0)
		cs.inset[p.RIGHT] = p.px(0)
		cs.inset[p.TOP] = p.px(0)
		cs.no_hit = true
		for ch, ci in st.e.m.chapters {
			if ch.start <= 0.001 || ch.start >= dur {
				continue
			}
			p.key(ui, fmt.tprintf("chmark%d", ci))
			p.div(ui, "absolute w-[2] rounded-full bg-muted-foreground")
			ms := p.style(ui)
			ms.inset[p.LEFT] = p.pct(f32(ch.start / dur) * 100)
			ms.margin[p.LEFT] = -1
			ms.inset[p.TOP] = p.px(2)
			ms.h = p.px(12)
			ms.no_hit = true
			p.end(ui)
		}
		p.end(ui)
	}

	// Thumb.
	p.div(ui, "absolute w-full h-full")
	hs := p.style(ui)
	hs.inset[p.LEFT] = p.px(0)
	hs.inset[p.RIGHT] = p.px(0)
	hs.no_hit = true
	{
		p.div(ui, "absolute rounded-full bg-primary border-2 border-background")
		th := p.style(ui)
		sz := f32(hot || active ? 14 : 11)
		th.w = p.px(sz)
		th.h = p.px(sz)
		th.inset[p.LEFT] = p.pct(frac * 100)
		th.margin[p.LEFT] = -sz / 2
		th.inset[p.TOP] = p.px((16 - sz) / 2)
		th.no_hit = true
		p.end(ui)
	}
	p.end(ui)

	p.end(ui)
}

volume_bar :: proc(ui: ^p.Ctx, st: ^St) {
	idx := p.div(ui, "w-[96] h-4 shrink-0 relative flex-row items-center cursor-pointer")
	id := p.node_id(ui, idx)
	r := p.rect_of(ui, id)
	_ = p.clickable(ui, idx)
	if p.is_active(ui, idx) && r.w > 2 {
		engine_set_volume(&st.e, clamp((p.mouse_pos(ui).x - r.x) / r.w, 0, 1))
		engine_mute(&st.e, false)
	}
	v := st.e.muted ? 0 : st.e.volume

	p.div(ui, "absolute w-full h-1 rounded-full bg-muted")
	ts := p.style(ui)
	ts.inset[p.LEFT] = p.px(0)
	ts.inset[p.RIGHT] = p.px(0)
	ts.no_hit = true
	p.div(ui, "absolute h-full rounded-full bg-foreground/70")
	fs := p.style(ui)
	fs.inset[p.LEFT] = p.px(0)
	fs.inset[p.TOP] = p.px(0)
	fs.inset[p.BOTTOM] = p.px(0)
	fs.inset[p.RIGHT] = p.pct((1 - v) * 100)
	fs.no_hit = true
	p.end(ui)
	p.end(ui)

	p.end(ui)
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

player_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_FILM, "size-[18] text-muted-foreground")
	p.end(ui)

	m := st.e.m
	p.col(ui, "flex-1 min-w-0 gap-px overflow-hidden")
	p.text(ui, m.title != "" ? m.title : m.name, "text-sm font-medium truncate")
	p.row(ui, "w-full min-w-0 items-center gap-2 overflow-hidden")
	if m.width > 0 {
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"%d × %d · %.3g fps",
			m.width,
			m.height,
			m.fps,
		)
		p.style(ui).shrink = 0
	}
	p.text(ui, home_relative(dir_of(m.path)), "flex-1 min-w-0 text-[11] text-muted-foreground truncate")
	p.end(ui)
	p.end(ui)

	if len(st.lib) > 1 {
		sc.badge(ui, fmt.tprintf("%d / %d", st.sel + 1, len(st.lib)), .Secondary)
	}
	if m.vcodec != "" {
		sc.badge(ui, strings.to_upper(m.vcodec, context.temp_allocator), .Outline)
	}
	if st.e.have_audio {
		sc.badge(ui, strings.to_upper(m.acodec, context.temp_allocator), .Outline)
	} else if m.has_audio {
		sc.badge(ui, "silent", .Destructive)
	}
	if sp := engine_speed(&st.e); abs(sp - 1) > 1e-9 {
		sc.badge(ui, speed_label(sp), .Default)
	}
	if tr := subs_active(&st.subs); tr != nil && st.subs.show && len(tr.cues) > 0 {
		sc.badge(ui, tr.lang != "" ? fmt.tprintf("CC %s", strings.to_upper(tr.lang, context.temp_allocator)) : "CC", .Secondary)
	} else if len(st.subs.tracks) > 0 {
		sc.badge(ui, "CC off", .Outline)
	}

	p.row(ui, "shrink-0 items-center gap-1")
	chrome_toggle(ui, IC_GAUGE, st.stats, &st.stats)
	chrome_toggle(ui, IC_INFO, st.info, &st.info)
	p.end(ui)
}

chrome_toggle :: proc(ui: ^p.Ctx, ic: p.Icon, on: bool, flag: ^bool) {
	idx := p.div(
		ui,
		"size-8 shrink-0 flex-row items-center justify-center rounded-lg border border-transparent transition cursor-pointer",
	)
	p.apply(
		ui,
		on ? "bg-accent border-border text-foreground" : "text-muted-foreground hover:bg-muted hover:text-foreground",
		idx,
	)
	if p.clickable(ui, idx) {
		flag^ = !flag^
	}
	p.icon(ui, ic, "size-4")
	p.end(ui)
}

status_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(STATUS_H)
	defer p.end(ui)

	if st.toast != "" {
		p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
		p.text(ui, st.toast, "flex-1 text-[11] text-muted-foreground truncate")
		return
	}

	hint(ui, "Space", "", "Play")
	hint(ui, "Left", "Right", "±5s")
	hint(ui, ",", ".", "Frame")
	hint(ui, "Up", "Down", "Volume")
	hint(ui, "[", "]", "Speed")
	hint(ui, "c", "t", "Subs")
	hint(ui, "PgUp", "PgDn", "Chapter")
	hint(ui, "s", "", "Stats")
	hint(ui, "Esc", "", "Library")
	p.spacer(ui)

	if st.open {
		_, dropped, _, queued, avg, _, _, _, _ := engine_stats(&st.e)
		p.textf(
			ui,
			"shrink-0 text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"%s · %.1f fps in · queue %d · %d dropped · |err| %.0f ms",
			speed_label(engine_speed(&st.e)),
			engine_decode_fps(&st.e),
			queued,
			dropped,
			avg * 1000,
		)
		p.style(ui).shrink = 0
	}
}

hint :: proc(ui: ^p.Ctx, k1, k2, label: string) {
	p.row(ui, "shrink-0 items-center gap-1")
	defer p.end(ui)
	sc.kbd(ui, k1)
	if k2 != "" {
		sc.kbd(ui, k2)
	}
	p.text(ui, label, "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
}

info_panel :: proc(ui: ^p.Ctx, st: ^St) {
	m := st.e.m
	p.col(ui, "h-full shrink-0 border-l border-border bg-card/30 overflow-hidden")
	p.style(ui).w = p.px(PANEL_W)
	defer p.end(ui)

	p.row(ui, "w-full h-10 shrink-0 items-center gap-2 px-3.5 border-b border-border")
	p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Media", "flex-1 text-xs font-semibold uppercase tracking-wider")
	sc.kbd(ui, "i")
	p.end(ui)

	// The order is what the file is, then the two things you steer with — the
	// subtitle track and the chapters — then the decoder details. A 300 px
	// column at 800 px tall has room for about twenty rows, so the sections
	// below the fold are the ones also shown elsewhere: the codecs are badges
	// in the title bar and the pipeline numbers are behind `s`.
	p.col(ui, "flex-1 min-h-0 p-3.5 gap-3 overflow-hidden")
	defer p.end(ui)

	group(ui, "File")
	stat(ui, "Name", m.name)
	stat(ui, "Size", human_bytes(m.size))
	stat(ui, "Duration", timecode_ms(m.duration))
	stat(ui, "Container", m.container)

	group(ui, "Subtitles")
	if len(st.subs.tracks) == 0 {
		p.text(ui, "No sidecar file, no embedded track.", "text-[11] text-muted-foreground")
	} else {
		stat(ui, "Active", st.subs.show ? subs_summary(&st.subs) : "hidden — v to show")
		if tr := subs_active(&st.subs); tr != nil {
			stat(
				ui,
				"Source",
				tr.src == .Sidecar \
				? fmt.tprintf("%s · sidecar", base_of(tr.path)) \
				: fmt.tprintf("stream %d · %s", tr.index, tr.codec),
			)
			if tr.err != "" {
				p.text(ui, tr.err, "text-[11] text-destructive")
			}
		}
		nbitmap := 0
		for tr in st.subs.tracks {
			if tr.bitmap {
				nbitmap += 1
			}
		}
		if nbitmap > 0 {
			p.textf(
				ui,
				"text-[11] text-destructive",
				"%d of %d track%s is a bitmap format and cannot be shown as text",
				nbitmap,
				len(st.subs.tracks),
				nbitmap == 1 ? "" : "s",
			)
		} else {
			stat(ui, "Tracks", fmt.tprintf("%d · c cycles, t lists", len(st.subs.tracks)))
		}
		if abs(st.subs.offset) > 1e-9 {
			stat(ui, "Delay", fmt.tprintf("%+.1f s", st.subs.offset))
		}
	}

	if len(st.e.m.chapters) > 0 {
		chapter_list(ui, st)
	}

	if m.has_video {
		group(ui, "Video")
		stat(ui, "Codec", m.vcodec)
		stat(ui, "Resolution", fmt.tprintf("%d × %d", m.width, m.height))
		stat(ui, "Frame rate", fmt.tprintf("%.4g fps", m.fps))
		stat(ui, "Decoding at", fmt.tprintf("%d × %d", st.e.w, st.e.h))
	}

	if m.has_audio {
		group(ui, "Audio")
		stat(ui, "Codec", m.acodec)
		stat(ui, "Sample rate", fmt.tprintf("%d Hz · %d ch", m.sample_rate, m.channels))
		stat(ui, "Output", st.e.have_audio ? "pw-cat · s16 48 kHz" : "unavailable")
		if !st.e.have_audio && st.e.audio_err != "" {
			p.text(ui, st.e.audio_err, "text-[11] text-destructive")
		}
	} else {
		group(ui, "Audio")
		p.text(ui, "This file has no audio stream.", "text-[11] text-muted-foreground")
	}

	p.spacer(ui)
	p.row(ui, "items-center gap-1.5 pt-2 border-t border-border")
	sc.kbd(ui, "s")
	p.text(ui, "pipeline and sync numbers", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

// chapter_list is the one place the container's chapter marks are readable as
// a list, with the current one marked and the keys that jump between them.
chapter_list :: proc(ui: ^p.Ctx, st: ^St) {
	chs := st.e.m.chapters
	now := st.open ? engine_clock(&st.e) : 0
	cur := chapter_at(chs, now)

	p.row(ui, "w-full items-center gap-2 pt-1")
	p.text(
		ui,
		"CHAPTERS",
		"flex-1 text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70",
	)
	sc.kbd(ui, "PgUp")
	sc.kbd(ui, "PgDn")
	p.end(ui)

	p.col(ui, "w-full gap-px overflow-hidden")
	p.style(ui).shrink = 0
	defer p.end(ui)
	for ch, i in chs {
		p.key(ui, fmt.tprintf("chrow%d", i))
		row := p.row(ui, "w-full items-center gap-2 px-1.5 py-1 rounded-md border transition cursor-pointer")
		p.apply(ui, i == cur ? "bg-accent border-border" : "border-transparent hover:bg-muted/60", row)
		if p.clickable(ui, row) {
			seek_to(st, ch.start)
		}
		p.textf(
			ui,
			i == cur \
			? "w-[42] shrink-0 text-[11] font-medium tabular-nums text-foreground whitespace-nowrap" \
			: "w-[42] shrink-0 text-[11] tabular-nums text-muted-foreground whitespace-nowrap",
			"%s",
			timecode(ch.start),
		)
		p.text(ui, ch.title, i == cur ? "flex-1 min-w-0 text-[11] font-medium truncate" : "flex-1 min-w-0 text-[11] truncate")
		p.end(ui)
	}
}

group :: proc(ui: ^p.Ctx, label: string) {
	p.text(
		ui,
		label,
		"text-[10] font-semibold uppercase tracking-widest text-muted-foreground/70 pt-1",
	)
}

// ---------------------------------------------------------------------------
// Library
// ---------------------------------------------------------------------------

build_library :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_FILM, "size-[18] text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, "Video", "text-sm font-semibold")
	if st.lib_source != "" {
		p.textf(
			ui,
			"text-[11] text-muted-foreground truncate",
			"%s · %d %s",
			home_relative(st.lib_source),
			len(st.lib),
			len(st.lib) == 1 ? "file" : "files",
		)
	} else {
		p.textf(
			ui,
			"text-[11] text-muted-foreground truncate",
			"%d %s in ~/Videos, ~/Downloads and $PALMY_MEDIA_DIR",
			len(st.lib),
			len(st.lib) == 1 ? "file" : "files",
		)
	}
	p.end(ui)
	p.end(ui)

	if st.err != "" {
		p.row(ui, "w-full shrink-0 items-center gap-2.5 px-4 py-2.5 border-b border-border bg-destructive/10")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
		p.text(ui, st.err, "flex-1 text-xs text-destructive truncate")
		p.end(ui)
	}

	body_h := size.y - TOPBAR_H - STATUS_H - (st.err != "" ? 41 : 0)
	st.lib_vis = max(1, int((body_h - 24) / 60))
	if st.sel < st.lib_top {st.lib_top = st.sel}
	if st.sel >= st.lib_top + st.lib_vis {st.lib_top = st.sel - st.lib_vis + 1}
	st.lib_top = clamp(st.lib_top, 0, max(0, len(st.lib) - st.lib_vis))

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		p.col(ui, "flex-1 min-w-0 min-h-0 px-3 py-3 gap-1 overflow-hidden")
		if len(st.lib) == 0 {
			empty_library(ui)
		} else {
			last := min(st.lib_top + st.lib_vis, len(st.lib))
			for i in st.lib_top ..< last {
				p.key(ui, st.lib[i].path)
				library_row(ui, st, i)
			}
		}
		p.end(ui)

		if len(st.lib) > 0 {
			library_detail(ui, st)
		}
	}
	p.end(ui)

	p.row(ui, "w-full shrink-0 items-center gap-3 px-3 border-t border-border bg-card/40")
	p.style(ui).h = p.px(STATUS_H)
	hint(ui, "Up", "Down", "Move")
	hint(ui, "Enter", "", "Play")
	hint(ui, "Esc", "", "Quit")
	p.spacer(ui)
	p.text(ui, "palmy video", "text-[11] text-muted-foreground whitespace-nowrap")
	p.end(ui)
}

empty_library :: proc(ui: ^p.Ctx) {
	p.col(ui, "flex-1 w-full items-center justify-center gap-3")
	defer p.end(ui)
	p.div(ui, "size-14 flex-row items-center justify-center rounded-2xl bg-muted ring-1 ring-border")
	p.icon(ui, IC_FILM, "size-6 text-muted-foreground")
	p.end(ui)
	p.text(ui, "No videos found", "text-sm font-medium")
	p.text(
		ui,
		"Pass a file on the command line, or set $PALMY_MEDIA_DIR",
		"text-xs text-muted-foreground",
	)
}

library_row :: proc(ui: ^p.Ctx, st: ^St, i: int) {
	en := &st.lib[i]
	sel := i == st.sel
	idx := p.div(ui, "flex-row w-full h-[56] shrink-0 items-center gap-3 px-2.5 rounded-xl border transition cursor-pointer")
	p.apply(ui, sel ? "bg-accent border-border" : "border-transparent hover:bg-muted/60", idx)
	if p.clickable(ui, idx) {
		st.sel = i
		start_playing(st)
	}
	if st.moved && p.is_hovered(ui, idx) {
		st.sel = i
	}
	defer p.end(ui)

	if sel {
		bar := p.div(ui, "absolute w-[3] rounded-full bg-primary")
		bs := p.style(ui, bar)
		bs.inset[p.LEFT] = p.px(0)
		bs.inset[p.TOP] = p.px(17)
		bs.h = p.px(22)
		p.end(ui)
	}

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_PLAY, sel ? "size-4 text-foreground" : "size-4 text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, en.name, sel ? "text-sm font-medium truncate" : "text-sm truncate")
	p.textf(
		ui,
		"text-[11] text-muted-foreground truncate",
		"%s · %s",
		home_relative(en.dir),
		human_bytes(en.size),
	)
	p.end(ui)

	if sel {
		sc.kbd(ui, "Enter")
	}
}

// library_detail probes only the selected file, so a folder of a hundred
// videos does not cost a hundred ffprobe runs on open.
library_detail :: proc(ui: ^p.Ctx, st: ^St) {
	en := current(st)
	p.col(ui, "h-full shrink-0 border-l border-border bg-card/30 overflow-hidden")
	p.style(ui).w = p.px(PANEL_W)
	defer p.end(ui)

	p.row(ui, "w-full h-10 shrink-0 items-center gap-2 px-3.5 border-b border-border")
	p.icon(ui, IC_INFO, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Details", "flex-1 text-xs font-semibold uppercase tracking-wider")
	p.end(ui)

	if en == nil {
		return
	}
	ensure_probed(en)
	m := en.m

	p.col(ui, "flex-1 min-h-0 p-3.5 gap-4 overflow-hidden")
	defer p.end(ui)

	if !m.ok {
		p.row(ui, "items-center gap-2")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-4 shrink-0 text-destructive")
		p.text(ui, "Cannot be played", "text-xs font-medium text-destructive")
		p.end(ui)
		p.text(ui, m.err, "text-[11] text-muted-foreground")
		return
	}

	group(ui, "File")
	stat(ui, "Name", m.name)
	stat(ui, "Size", human_bytes(m.size))
	stat(ui, "Duration", timecode(m.duration))
	stat(ui, "Container", m.container)

	if m.has_video {
		group(ui, "Video")
		stat(ui, "Codec", m.vcodec)
		stat(ui, "Resolution", fmt.tprintf("%d × %d", m.width, m.height))
		stat(ui, "Frame rate", fmt.tprintf("%.4g fps", m.fps))
	}
	if m.has_audio {
		group(ui, "Audio")
		stat(ui, "Codec", m.acodec)
		stat(ui, "Channels", fmt.tprintf("%d", m.channels))
		stat(ui, "Sample rate", fmt.tprintf("%d Hz", m.sample_rate))
	}

	p.spacer(ui)
	p.row(ui, "items-center gap-1.5 pt-2 border-t border-border")
	sc.kbd(ui, "Enter")
	p.text(ui, "play this file", "text-[11] text-muted-foreground whitespace-nowrap")
	p.style(ui).shrink = 0
	p.end(ui)
}

home_relative :: proc(path: string) -> string {
	home, err := os_home()
	if err && strings.has_prefix(path, home) {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}
