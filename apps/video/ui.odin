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

	p.spacer(ui)

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
	hint(ui, "0-9", "", "Jump")
	hint(ui, "s", "", "Stats")
	hint(ui, "Esc", "", "Library")
	p.spacer(ui)

	if st.open {
		_, dropped, _, queued, avg, _, _, _, _ := engine_stats(&st.e)
		p.textf(
			ui,
			"shrink-0 text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"%.1f fps in · queue %d · %d dropped · |err| %.0f ms",
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

	p.col(ui, "flex-1 min-h-0 p-3.5 gap-4 overflow-hidden")
	defer p.end(ui)

	group(ui, "File")
	stat(ui, "Name", m.name)
	stat(ui, "Folder", home_relative(dir_of(m.path)))
	stat(ui, "Size", human_bytes(m.size))
	stat(ui, "Container", m.container)
	stat(ui, "Duration", timecode_ms(m.duration))
	stat(ui, "Bitrate", human_rate(m.bitrate))

	if m.has_video {
		group(ui, "Video")
		stat(ui, "Codec", m.vcodec)
		stat(ui, "Resolution", fmt.tprintf("%d × %d", m.width, m.height))
		stat(ui, "Frame rate", fmt.tprintf("%.4g fps", m.fps))
		stat(ui, "Pixel format", m.pix_fmt)
		if m.frames > 0 {
			stat(ui, "Frames", fmt.tprintf("%d", m.frames))
		}
		stat(ui, "Decoding at", fmt.tprintf("%d × %d", st.e.w, st.e.h))
	}

	if m.has_audio {
		group(ui, "Audio")
		stat(ui, "Codec", m.acodec)
		stat(ui, "Channels", fmt.tprintf("%d", m.channels))
		stat(ui, "Sample rate", fmt.tprintf("%d Hz", m.sample_rate))
		stat(ui, "Output", st.e.have_audio ? "pw-cat · s16 48 kHz stereo" : "unavailable")
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
