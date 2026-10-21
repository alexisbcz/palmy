package main

// The one screen: what is playing, what it looks like, and what is next.

import "core:fmt"

import "core:strings"
import p "palmy:."
import sc "shadcn:."

build :: proc(ui: ^p.Ctx, st: ^St) {
	size := p.size(ui)
	narrow := size.x < 820
	list_w := narrow ? size.x : LIST_W

	top_bar(ui, st)

	p.row(ui, "w-full flex-1 min-h-0 overflow-hidden")
	{
		if !narrow {
			p.col(ui, "flex-1 min-w-0 min-h-0 overflow-hidden")
			now_playing(ui, st)
			p.end(ui)
		}
		playlist(ui, st, list_w, narrow)
	}
	p.end(ui)

	status_bar(ui, st)
}

// ---------------------------------------------------------------------------
// Now playing
// ---------------------------------------------------------------------------

now_playing :: proc(ui: ^p.Ctx, st: ^St) {
	cur := current(st)

	// Header: art and tags.
	p.row(ui, "w-full shrink-0 items-center gap-5 px-5 py-5")
	{
		p.div(
			ui,
			"size-[132] shrink-0 flex-row items-center justify-center rounded-2xl overflow-hidden bg-muted ring-1 ring-border",
		)
		if st.cover_ok {
			p.image(ui, st.cover, "w-full h-full", .Cover)
		} else {
			p.icon(ui, IC_DISC_3, "size-10 text-muted-foreground/60")
		}
		p.end(ui)

		p.col(ui, "flex-1 min-w-0 gap-1.5")
		if cur == nil {
			p.text(ui, "Nothing playing", "text-2xl font-semibold")
			p.text(ui, "Pick a track and press Enter", "text-sm text-muted-foreground")
		} else {
			p.text(ui, track_title(cur), "text-2xl font-semibold truncate")
			p.text(ui, track_artist(cur), "text-sm text-muted-foreground truncate")
			if cur.m.album != "" {
				p.text(ui, cur.m.album, "text-xs text-muted-foreground/80 truncate")
			}
			p.row(ui, "items-center gap-1.5 pt-1 flex-wrap")
			if cur.m.acodec != "" {
				sc.badge(ui, strings.to_upper(cur.m.acodec, context.temp_allocator), .Outline)
			}
			if cur.m.sample_rate > 0 {
				sc.badge(ui, fmt.tprintf("%.1f kHz", f64(cur.m.sample_rate) / 1000), .Outline)
			}
			if cur.m.channels > 0 {
				sc.badge(ui, cur.m.channels == 1 ? "mono" : "stereo", .Outline)
			}
			if cur.m.bitrate > 0 {
				sc.badge(ui, human_rate(cur.m.bitrate), .Outline)
			}
			if cur.m.date != "" {
				sc.badge(ui, cur.m.date, .Secondary)
			}
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	// The visualiser.
	p.col(ui, "w-full flex-1 min-h-0 mx-5 relative rounded-xl overflow-hidden bg-[#0d0d10] ring-1 ring-border")
	p.style(ui).margin = {0, 20, 0, 20}
	p.pixels(ui, "w-full flex-1 min-h-0", st, draw_vis)
	vis_label(ui, st)
	p.end(ui)

	// The waveform, which is also the scrubber.
	wave_strip(ui, st)
	transport(ui, st)
}

vis_label :: proc(ui: ^p.Ctx, st: ^St) {
	ready, ok, ms, n := analysis_ready(ana(st))
	box := p.row(
		ui,
		"absolute items-center gap-2 h-7 px-2.5 rounded-lg bg-background/90 border border-border z-20",
	)
	bs := p.style(ui, box)
	bs.inset[p.LEFT] = p.px(10)
	bs.inset[p.TOP] = p.px(10)
	defer p.end(ui)

	if current(st) == nil {
		p.icon(ui, IC_AUDIO_LINES, "size-3.5 text-muted-foreground/60 shrink-0")
		p.text(
			ui,
			"Nothing loaded — the spectrum is drawn from the track's own samples",
			"text-[11] text-muted-foreground whitespace-nowrap",
		)
		p.style(ui).shrink = 0
		return
	}
	if !ready {
		sc.spinner(ui, "size-3.5 text-muted-foreground")
		p.text(ui, "Decoding PCM…", "text-[11] text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}
	if !ok {
		p.icon(ui, IC_TRIANGLE_ALERT, "size-3.5 text-destructive shrink-0")
		p.text(ui, "No samples", "text-[11] text-destructive whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}
	p.icon(
		ui,
		st.vis_mode == .Spectrum ? IC_AUDIO_LINES : IC_ACTIVITY,
		"size-3.5 text-muted-foreground shrink-0",
	)
	if st.vis_mode == .Spectrum {
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"%d-point FFT @ %d kHz · %d Hz–%d kHz · decoded in %.0f ms",
			FFT_N,
			SPEC_RATE / 1000,
			int(SPEC_LO),
			SPEC_RATE / 2000,
			ms,
		)
	} else {
		p.textf(
			ui,
			"text-[11] text-muted-foreground whitespace-nowrap",
			"Oscilloscope · %d samples @ %d kHz · decoded in %.0f ms",
			n,
			WAVE_RATE / 1000,
			ms,
		)
	}
	p.style(ui).shrink = 0
}

// draw_vis paints whichever analysis is selected. Both are computed from the
// track's own samples at the playhead, so a paused player draws a still frame
// of the sound that is actually there.
draw_vis :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	if r.w < 4 || r.h < 4 {
		return
	}
	switch st.vis_mode {
	case .Spectrum:
		pad := 10 * c.scale
		inner := p.Rect{r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad}
		gap := max(2 * c.scale, inner.w / f32(BARS) * 0.22)
		bw := (inner.w - gap * f32(BARS - 1)) / f32(BARS)
		for i in 0 ..< BARS {
			v := clamp(st.bars[i], 0, 1)
			h := max(2 * c.scale, inner.h * v)
			x := inner.x + f32(i) * (bw + gap)
			y := inner.y + inner.h - h
			// Low notes warm, high notes cool: the bar's colour says where it
			// sits in the spectrum without needing an axis.
			t := f32(i) / f32(BARS - 1)
			col := p.Color {
				u8(90 + 150 * (1 - t) + 40 * v),
				u8(110 + 60 * t + 70 * v),
				u8(170 + 70 * t),
				255,
			}
			p.fill_round_rect(
				c,
				{x, y, bw, h},
				{bw / 2, bw / 2, 0, 0},
				col,
			)
			// A dot resting on the floor keeps the display alive in silence.
			p.fill_rect(c, {x, inner.y + inner.h - 1 * c.scale, bw, 1 * c.scale}, p.Color{70, 70, 80, 255})
		}
	case .Scope:
		mid := r.y + r.h / 2
		p.fill_rect(c, {r.x, mid, r.w, 1 * c.scale}, p.Color{50, 50, 58, 255})
		n := len(st.scope_buf)
		prev_y := mid
		for i in 0 ..< n {
			x := r.x + r.w * f32(i) / f32(n - 1)
			y := mid - clamp(st.scope_buf[i], -1, 1) * (r.h * 0.44)
			if i > 0 {
				px := r.x + r.w * f32(i - 1) / f32(n - 1)
				p.draw_line(c, px, prev_y, x, y, 1.6 * c.scale, p.Color{120, 200, 255, 255})
			}
			prev_y = y
		}
	}
}

// ---------------------------------------------------------------------------
// The waveform scrubber
// ---------------------------------------------------------------------------

wave_strip :: proc(ui: ^p.Ctx, st: ^St) {
	cur := current(st)
	dur := cur != nil ? max(cur.m.duration, 0.001) : 1

	p.col(ui, "w-full shrink-0 px-5 pt-4 gap-1")
	defer p.end(ui)

	idx := p.pixels(ui, "w-full rounded-lg overflow-hidden cursor-pointer", st, draw_wave)
	ws := p.style(ui, idx)
	ws.h = p.px(WAVE_H)
	id := p.node_id(ui, idx)
	r := p.rect_of(ui, id)
	_ = p.clickable(ui, idx)
	if r.w > 2 && cur != nil {
		if p.is_active(ui, idx) {
			st.scrubbing = true
			st.scrub_at = f64(clamp((p.mouse_pos(ui).x - r.x) / r.w, 0, 1)) * dur
		} else if st.scrubbing {
			st.scrubbing = false
			seek_to(st, st.scrub_at)
		}
	}
	ensure_wave(st, max(1, int(r.w)))

	now := st.scrubbing ? st.scrub_at : st.now
	p.row(ui, "w-full items-center")
	defer p.end(ui)
	if cur == nil {
		p.text(ui, "—:—", "text-xs text-muted-foreground tabular-nums whitespace-nowrap")
		p.style(ui).shrink = 0
		p.spacer(ui)
		p.text(ui, "no track", "text-xs text-muted-foreground whitespace-nowrap")
		p.style(ui).shrink = 0
		return
	}
	p.text(ui, timecode(clamp(now, 0, dur)), "text-xs font-medium tabular-nums whitespace-nowrap")
	p.style(ui).shrink = 0
	p.spacer(ui)
	p.textf(
		ui,
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
		"−%s",
		timecode(max(0, dur - clamp(now, 0, dur))),
	)
	p.style(ui).shrink = 0
	p.text(ui, "  /  ", "text-xs text-muted-foreground/50 whitespace-nowrap")
	p.style(ui).shrink = 0
	p.text(
		ui,
		timecode(dur),
		"text-xs text-muted-foreground tabular-nums whitespace-nowrap",
	)
	p.style(ui).shrink = 0
}

draw_wave :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	p.fill_rect(c, r, p.Color{18, 18, 22, 255})
	cols := len(st.wave)
	if cols == 0 || !st.wave_ready {
		return
	}
	cur := current(st)
	dur := cur != nil ? max(cur.m.duration, 0.001) : 1
	now := st.scrubbing ? st.scrub_at : st.now
	frac := f32(clamp(now / dur, 0, 1))
	split := r.x + r.w * frac
	mid := r.y + r.h / 2

	played := p.Color{250, 250, 250, 255}
	ahead := p.Color{86, 86, 96, 255}

	step := max(1, cols / max(1, int(r.w)))
	for i := 0; i < cols; i += step {
		x := r.x + r.w * f32(i) / f32(cols)
		w := max(1 * c.scale, r.w / f32(cols) * f32(step) - 1 * c.scale)
		v := clamp(st.wave[i], 0, 1)
		// A floor so silence is still a line rather than nothing.
		h := max(1.5 * c.scale, v * (r.h * 0.46))
		p.fill_round_rect(
			c,
			{x, mid - h, w, h * 2},
			{w / 2, w / 2, w / 2, w / 2},
			x + w <= split ? played : ahead,
		)
	}
	p.fill_rect(c, {split - 1 * c.scale, r.y, 2 * c.scale, r.h}, p.Color{255, 255, 255, 210})
}

// ---------------------------------------------------------------------------
// Transport
// ---------------------------------------------------------------------------

transport :: proc(ui: ^p.Ctx, st: ^St) {
	playing := st.e.live && !engine_paused(&st.e)

	p.row(ui, "w-full shrink-0 items-center gap-2 px-5 py-4")
	p.style(ui).h = p.px(TRANSPORT_H)
	defer p.end(ui)

	tbutton(ui, st, IC_SHUFFLE, .Shuffle, st.shuffle)
	tbutton(ui, st, IC_SKIP_BACK, .Prev, false)

	idx := p.div(
		ui,
		"size-11 shrink-0 flex-row items-center justify-center rounded-full bg-primary text-primary-foreground transition cursor-pointer hover:bg-primary/80",
	)
	if p.clickable(ui, idx) {
		if !st.e.live {
			play(st, st.sel)
		} else {
			engine_pause(&st.e, !engine_paused(&st.e))
		}
	}
	p.icon(ui, playing ? IC_PAUSE : IC_PLAY, "size-5")
	p.end(ui)

	tbutton(ui, st, IC_SKIP_FORWARD, .Next, false)
	tbutton(ui, st, IC_REPEAT_1, .Repeat, st.repeat)
	tbutton(ui, st, st.vis_mode == .Spectrum ? IC_ACTIVITY : IC_AUDIO_LINES, .Vis, false)

	p.spacer(ui)

	// Output level, taken from the samples actually handed to pw-cat.
	p.row(ui, "shrink-0 items-center gap-2")
	p.text(ui, "OUT", "text-[10] font-semibold tracking-widest text-muted-foreground/60 whitespace-nowrap")
	p.style(ui).shrink = 0
	level_meter(ui, st)
	p.end(ui)

	p.div(ui, "w-3 shrink-0")
	p.end(ui)

	vb := p.div(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-lg transition cursor-pointer")
	p.apply(
		ui,
		st.e.muted ? "text-destructive bg-muted" : "text-muted-foreground hover:bg-muted hover:text-foreground",
		vb,
	)
	if p.clickable(ui, vb) {
		engine_mute(&st.e, !st.e.muted)
	}
	p.icon(
		ui,
		st.e.muted || st.e.volume < 0.01 ? IC_VOLUME_X : (st.e.volume < 0.5 ? IC_VOLUME_1 : IC_VOLUME_2),
		"size-4",
	)
	p.end(ui)
	volume_bar(ui, st)
	p.textf(
		ui,
		"w-[34] shrink-0 text-[11] text-muted-foreground tabular-nums text-right whitespace-nowrap",
		"%d%%",
		int(st.e.volume * 100 + 0.5),
	)
}

TAct :: enum u8 {
	Prev,
	Next,
	Shuffle,
	Repeat,
	Vis,
}

tbutton :: proc(ui: ^p.Ctx, st: ^St, ic: p.Icon, act: TAct, on: bool) {
	idx := p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg transition cursor-pointer")
	p.apply(
		ui,
		on ? "bg-accent text-foreground" : "text-muted-foreground hover:bg-muted hover:text-foreground",
		idx,
	)
	if p.clickable(ui, idx) {
		switch act {
		case .Prev:
			advance(st, -1)
		case .Next:
			advance(st, 1)
		case .Shuffle:
			st.shuffle = !st.shuffle
			rebuild_order(st)
			rethink_next(st)
		case .Repeat:
			st.repeat = !st.repeat
			rethink_next(st)
		case .Vis:
			st.vis_mode = st.vis_mode == .Spectrum ? .Scope : .Spectrum
		}
	}
	p.icon(ui, ic, "size-[18]")
	p.end(ui)
}

level_meter :: proc(ui: ^p.Ctx, st: ^St) {
	p.pixels(ui, "w-[72] h-2 shrink-0 rounded-full overflow-hidden", st, draw_level)
}

draw_level :: proc(c: ^p.Canvas, r: p.Rect, st: ^St) {
	p.fill_round_rect(c, r, {r.h / 2, r.h / 2, r.h / 2, r.h / 2}, p.Color{40, 40, 46, 255})
	v := clamp(engine_level(&st.e), 0, 1)
	if v <= 0.001 {
		return
	}
	w := r.w * v
	col := v > 0.92 ? p.Color{248, 113, 113, 255} : p.Color{120, 200, 255, 255}
	p.fill_round_rect(c, {r.x, r.y, w, r.h}, {r.h / 2, r.h / 2, r.h / 2, r.h / 2}, col)
}

volume_bar :: proc(ui: ^p.Ctx, st: ^St) {
	idx := p.div(ui, "w-[88] h-4 shrink-0 relative flex-row items-center cursor-pointer")
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
// Playlist
// ---------------------------------------------------------------------------

playlist :: proc(ui: ^p.Ctx, st: ^St, w: f32, narrow: bool) {
	p.col(ui, "h-full shrink-0 border-l border-border bg-card/30 overflow-hidden")
	p.style(ui).w = p.px(w)
	defer p.end(ui)

	p.row(ui, "w-full h-10 shrink-0 items-center gap-2 px-3.5 border-b border-border")
	p.icon(ui, IC_LIST_MUSIC, "size-3.5 shrink-0 text-muted-foreground")
	p.text(ui, "Playlist", "flex-1 text-xs font-semibold uppercase tracking-wider")
	p.textf(
		ui,
		"text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
		"%d",
		len(st.list),
	)
	p.style(ui).shrink = 0
	p.end(ui)

	size := p.size(ui)
	avail := size.y - TOPBAR_H - STATUS_H - 40 - 12
	st.vis = max(1, int(avail / 52))
	if st.sel < st.top {st.top = st.sel}
	if st.sel >= st.top + st.vis {st.top = st.sel - st.vis + 1}
	st.top = clamp(st.top, 0, max(0, len(st.list) - st.vis))

	p.col(ui, "flex-1 min-h-0 p-1.5 gap-0.5 overflow-hidden")
	defer p.end(ui)

	if len(st.list) == 0 {
		p.col(ui, "flex-1 items-center justify-center gap-3 p-4")
		p.div(ui, "size-12 flex-row items-center justify-center rounded-2xl bg-muted ring-1 ring-border")
		p.icon(ui, IC_MUSIC, "size-5 text-muted-foreground")
		p.end(ui)
		p.text(ui, "No tracks found", "text-sm font-medium")
		p.text(
			ui,
			"Pass a file or folder, or set $PALMY_MEDIA_DIR",
			"text-xs text-muted-foreground text-center",
		)
		p.end(ui)
		return
	}

	last := min(st.top + st.vis, len(st.list))
	for i in st.top ..< last {
		p.key(ui, st.list[i].path)
		track_row(ui, st, i)
	}
}

track_row :: proc(ui: ^p.Ctx, st: ^St, i: int) {
	t := &st.list[i]
	sel := i == st.sel
	playing := i == st.cur
	idx := p.div(ui, "flex-row w-full h-[50] shrink-0 items-center gap-2.5 px-2 rounded-lg border transition cursor-pointer")
	p.apply(
		ui,
		sel ? "bg-accent border-border" : "border-transparent hover:bg-muted/60",
		idx,
	)
	if p.clickable(ui, idx) {
		st.sel = i
		play(st, i)
	}
	if st.moved && p.is_hovered(ui, idx) {
		st.sel = i
	}
	defer p.end(ui)

	p.div(ui, "size-8 shrink-0 flex-row items-center justify-center rounded-md bg-muted ring-1 ring-border")
	if playing {
		p.icon(
			ui,
			engine_paused(&st.e) ? IC_PAUSE : IC_AUDIO_LINES,
			"size-3.5 text-foreground",
		)
	} else {
		p.textf(ui, "text-[11] text-muted-foreground tabular-nums", "%d", i + 1)
	}
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(
		ui,
		track_title(t),
		playing ? "text-[13] font-semibold truncate" : (sel ? "text-[13] font-medium truncate" : "text-[13] truncate"),
	)
	p.text(ui, track_artist(t), "text-[11] text-muted-foreground truncate")
	p.end(ui)

	if t.m.duration > 0 {
		p.text(
			ui,
			timecode(t.m.duration),
			"shrink-0 text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
		)
	}
}

// ---------------------------------------------------------------------------
// Chrome
// ---------------------------------------------------------------------------

top_bar :: proc(ui: ^p.Ctx, st: ^St) {
	p.row(ui, "w-full shrink-0 items-center gap-3 px-4 border-b border-border bg-card/40")
	p.style(ui).h = p.px(TOPBAR_H)
	defer p.end(ui)

	p.div(ui, "size-9 shrink-0 flex-row items-center justify-center rounded-lg bg-muted ring-1 ring-border")
	p.icon(ui, IC_HEADPHONES, "size-[18] text-muted-foreground")
	p.end(ui)

	p.col(ui, "flex-1 min-w-0 gap-px")
	p.text(ui, "Audio", "text-sm font-semibold")
	folder := "no folder"
	if len(st.list) > 0 {
		folder = home_relative(st.list[clamp(st.sel, 0, len(st.list) - 1)].dir)
	}
	p.textf(ui, "text-[11] text-muted-foreground truncate", "%s · %d tracks", folder, len(st.list))
	p.end(ui)

	if st.err != "" {
		p.row(ui, "shrink-0 items-center gap-1.5 h-7 px-2.5 rounded-lg bg-destructive/10")
		p.icon(ui, IC_TRIANGLE_ALERT, "size-3.5 shrink-0 text-destructive")
		p.text(ui, st.err, "text-[11] text-destructive whitespace-nowrap")
		p.style(ui).shrink = 0
		p.end(ui)
	}

	if lat, locked := engine_latency(&st.e); st.e.live {
		sc.badge(
			ui,
			fmt.tprintf("sink %.0f ms%s", lat * 1000, locked ? "" : " …"),
			.Outline,
		)
	}
	if nt, armed := engine_prefetched(&st.e); armed {
		name := nt >= 0 && nt < len(st.list) ? track_title(&st.list[nt]) : "next"
		sc.badge(ui, fmt.tprintf("Next ready: %s", name), .Secondary)
	}
	if st.shuffle {
		sc.badge(ui, "Shuffle", .Secondary)
	}
	if st.repeat {
		sc.badge(ui, "Repeat", .Secondary)
	}
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
	hint(ui, "Enter", "", "Open")
	hint(ui, "n", "p", "Track")
	hint(ui, "Left", "Right", "±5s")
	hint(ui, "v", "", "Visual")
	hint(ui, "s", "r", "Shuffle / repeat")
	hint(ui, "Esc", "", "Quit")
	p.spacer(ui)

	if st.e.live {
		written, joins := engine_stats(&st.e)
		p.textf(
			ui,
			"shrink-0 text-[11] text-muted-foreground tabular-nums whitespace-nowrap",
			"%s · s16 48 kHz stereo · %.2f s written · %d gapless %s",
			sink_name(),
			written,
			joins,
			joins == 1 ? "join" : "joins",
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

home_relative :: proc(path: string) -> string {
	home, ok := os_home()
	if ok && strings.has_prefix(path, home) {
		return fmt.tprintf("~%s", path[len(home):])
	}
	return path
}

