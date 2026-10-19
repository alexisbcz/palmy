package call

// ---------------------------------------------------------------------------
// The multi-party call screen.
//
// Two layouts, L toggles: a grid where everyone is the same size, and a
// speaker view where the dominant speaker — chosen by the SFU from audio
// levels — takes the stage and everyone else sits in a strip below. The
// speaking tile carries a ring in either layout, so who is talking is visible
// at a glance even in the grid.
//
// Every tile names its person in their identity's colour *and* in words
// (product.md: colour is never the only signal), and a camera-off tile shows
// the monogram in that colour. The encryption state is in the header, never
// behind a menu: a lock, the words, and the safety code everyone can read
// aloud to each other.
// ---------------------------------------------------------------------------

import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Room_Layout :: enum {
	Grid,
	Speaker,
}

ICON_LOCK :: p.Icon{name = "lock", d = "M5 11 L19 11 C20.105 11 21 11.895 21 13 L21 20 C21 21.105 20.105 22 19 22 L5 22 C3.895 22 3 21.105 3 20 L3 13 C3 11.895 3.895 11 5 11 Z M7 11 L7 7 C7 4.239 9.239 2 12 2 C14.761 2 17 4.239 17 7 L17 11", view = 24, stroke = 2}
ICON_LAYOUT_GRID :: p.Icon{name = "layout-grid", d = "M4 3 L9 3 C9.552 3 10 3.448 10 4 L10 9 C10 9.552 9.552 10 9 10 L4 10 C3.448 10 3 9.552 3 9 L3 4 C3 3.448 3.448 3 4 3 Z M15 3 L20 3 C20.552 3 21 3.448 21 4 L21 9 C21 9.552 20.552 10 20 10 L15 10 C14.448 10 14 9.552 14 9 L14 4 C14 3.448 14.448 3 15 3 Z M15 14 L20 14 C20.552 14 21 14.448 21 15 L21 20 C21 20.552 20.552 21 20 21 L15 21 C14.448 21 14 20.552 14 20 L14 15 C14 14.448 14.448 14 15 14 Z M4 14 L9 14 C9.552 14 10 14.448 10 15 L10 20 C10 20.552 9.552 21 9 21 L4 21 C3.448 21 3 20.552 3 20 L3 15 C3 14.448 3.448 14 4 14 Z", view = 24, stroke = 2}
ICON_LAYOUT_SPEAKER :: p.Icon{name = "layout-speaker", d = "M4 3 L20 3 C20.552 3 21 3.448 21 4 L21 13 C21 13.552 20.552 14 20 14 L4 14 C3.448 14 3 13.552 3 13 L3 4 C3 3.448 3.448 3 4 3 Z M3 18 L8 18 L8 21 L3 21 Z M10 18 L14 18 L14 21 L10 21 Z M16 18 L21 18 L21 21 L16 21 Z", view = 24, stroke = 2}
ICON_USERS :: p.Icon{name = "users", d = "M16 21 L16 19 C16 16.791 14.209 15 12 15 L6 15 C3.791 15 2 16.791 2 19 L2 21 M9 11 C11.209 11 13 9.209 13 7 C13 4.791 11.209 3 9 3 C6.791 3 5 4.791 5 7 C5 9.209 6.791 11 9 11 Z M22 21 L22 19 C21.999 17.177 20.765 15.586 19 15.13 M16 3.13 C17.77 3.583 19.008 5.178 19.008 7.005 C19.008 8.832 17.77 10.427 16 10.88", view = 24, stroke = 2}

IDENTITY_COLORS :: [?]string{"indigo", "emerald", "rose", "amber", "sky", "violet", "teal", "orange", "fuchsia", "lime", "cyan", "pink", "blue", "green", "red", "purple", "yellow", "zinc"}

id_color :: proc(c: string) -> string {
	for x in IDENTITY_COLORS {
		if x == c {
			return x
		}
	}
	return "indigo"
}

crypto_rand :: proc(dst: []u8) {
	crypto.rand_bytes(dst)
}

write_file :: proc(path, data: string) -> bool {
	return os.write_entire_file(path, transmute([]u8)data) == nil
}

// Tile_Who is everything a tile draws, gathered once so self and remote
// tiles go through the same procedure.
Tile_Who :: struct {
	src:      u16,
	name:     string,
	color:    string,
	img:      ^p.Image,
	has_img:  bool,
	cam_off:  bool,
	muted:    bool,
	speaking: bool,
	self:     bool,
	layer:    int, // -1 none / self
	level:    f32,
}

who_self :: proc(app: ^App) -> Tile_Who {
	r := app.room
	return Tile_Who {
		name = r.me.name,
		color = r.me.color,
		img = &app.v.local,
		has_img = app.v.has_local && !app.v.camera_off,
		cam_off = app.v.camera_off,
		muted = app.a.muted,
		speaking = r.speaker == r.src && r.src != 0,
		self = true,
		layer = -1,
		level = app.a.tx_level,
	}
}

who_remote :: proc(r: ^Room, rm: ^Remote) -> Tile_Who {
	return Tile_Who {
		src = rm.src,
		name = rm.name,
		color = rm.color,
		img = &rm.img,
		has_img = rm.has_img && !rm.cam_off && r.tier != "audio",
		cam_off = rm.cam_off,
		muted = rm.muted,
		speaking = r.speaker == rm.src,
		layer = rm.have_layer ? int(rm.layer) : -1,
		level = rm.level,
	}
}

draw_tile :: proc(ui: ^p.Ctx, who: Tile_Who, w, h: f32, compact := false) {
	col := id_color(who.color)
	p.div(ui, "relative shrink-0 rounded-xl overflow-hidden bg-[#1c1c1f]")
	p.style(ui).w = p.px(w)
	p.style(ui).h = p.px(h)
	defer p.end(ui)

	if who.has_img && who.img.w > 0 {
		p.image(ui, who.img^, "absolute inset-0 w-full h-full", .Cover)
	} else {
		// The monogram, in the identity's colour, on a wash of it.
		p.col(ui, "absolute inset-0 items-center justify-center gap-2")
		disc := compact ? "size-12 text-lg" : (h > 300 ? "size-28 text-4xl" : "size-20 text-2xl")
		p.div(ui, fmt.tprintf("%s rounded-full flex-row items-center justify-center bg-%s-500/25 border border-%s-400/40", disc, col, col))
		p.text(ui, initials(who.name), fmt.tprintf("font-semibold text-%s-200 whitespace-nowrap", col))
		p.end(ui)
		if !compact && who.cam_off {
			p.text(ui, "Camera off", "text-xs text-white/50 whitespace-nowrap")
		}
		p.end(ui)
	}

	// Name chip: colour dot, then the name in words.
	p.row(ui, compact ? "absolute left-2 bottom-2 items-center gap-1.5 px-2 py-0.5 rounded-md bg-black/60" : "absolute left-3 bottom-3 items-center gap-2 px-2.5 py-1 rounded-lg bg-black/60")
	p.div(ui, fmt.tprintf("size-2 rounded-full shrink-0 bg-%s-400", col))
	p.end(ui)
	p.text(ui, who.self ? fmt.tprintf("%s (you)", who.name) : who.name, compact ? "text-[11] font-medium text-white whitespace-nowrap truncate" : "text-sm font-medium text-white whitespace-nowrap")
	if who.muted {
		p.icon(ui, ICON_MIC_OFF, "size-3.5 text-rose-400 shrink-0")
	} else if who.level > 0.35 && !compact {
		// Three bars that follow the level: you can see who is making sound
		// even when they are not the dominant speaker.
		p.row(ui, "items-end gap-[2] h-3 shrink-0")
		for i in 0 ..< 3 {
			hh := clamp((who.level - 0.3) * 18 * (1 + 0.4 * f32(i % 2)), 3, 12)
			p.div(ui, "w-[3] rounded-full bg-emerald-400")
			p.style(ui).h = p.px(hh)
			p.end(ui)
		}
		p.end(ui)
	}
	p.end(ui)

	if !who.self && who.layer >= 0 && !compact {
		p.div(ui, "absolute right-3 top-3 px-1.5 py-0.5 rounded bg-black/55")
		p.text(ui, who.layer == 0 ? "HD" : "SD", "text-[10] font-mono font-semibold text-white/80")
		p.end(ui)
	}
	if who.speaking {
		p.div(ui, "absolute inset-0 rounded-xl border-[3] border-emerald-400")
		p.end(ui)
	}
}

// Fitted tile size for `n` tiles in a `aw` x `ah` box at 16:9.
grid_tile :: proc(n: int, aw, ah: f32, gap: f32) -> (cols: int, w, h: f32) {
	cols = 1
	switch {
	case n <= 1:
		cols = 1
	case n <= 4:
		cols = 2
	case n <= 9:
		cols = 3
	case:
		cols = 4
	}
	rows := (n + cols - 1) / cols
	w = (aw - gap * f32(cols - 1)) / f32(cols)
	h = w * 9 / 16
	maxh := (ah - gap * f32(rows - 1)) / f32(rows)
	if h > maxh {
		h = maxh
		w = h * 16 / 9
	}
	return
}

draw_room_stage :: proc(app: ^App, ui: ^p.Ctx, aw, ah: f32) {
	r := app.room
	tiles := make([dynamic]Tile_Who, context.temp_allocator)
	append(&tiles, who_self(app))
	for rm in r.remotes {
		if rm.present {
			append(&tiles, who_remote(r, rm))
		}
	}

	p.col(ui, "flex-1 min-w-0 h-full items-center justify-center gap-3 overflow-hidden")
	defer p.end(ui)

	if r.state == .Ended {
		p.icon(ui, ICON_PHONE_OFF, "size-12 text-muted-foreground")
		p.text(ui, r.reason == "" ? "You left the call" : r.reason, "text-xl font-semibold whitespace-nowrap")
		p.text(ui, "Q to close", "text-sm text-muted-foreground")
		return
	}
	if r.state == .Joining {
		p.icon(ui, sc.ICON_LOADER_CIRCLE, "size-10 text-muted-foreground", f32(app.t) * 0.9)
		p.text(ui, "Joining the call…", "text-lg font-medium whitespace-nowrap")
		p.textf(ui, "text-sm text-muted-foreground whitespace-nowrap", "through %s", net.endpoint_to_string(r.sfu))
		return
	}

	gap: f32 = 12
	if app.layout == .Speaker && len(tiles) > 1 {
		// The stage goes to the last person other than you who held the
		// floor; before anyone has, to someone whose camera is on. Never to
		// yourself unless you are alone: you know what you look like.
		main := -1
		for t, i in tiles {
			if !t.self && t.src == r.stage {
				main = i
			}
		}
		if main < 0 {
			for t, i in tiles {
				if !t.self && t.has_img {
					main = i
					break
				}
			}
		}
		if main < 0 {
			main = 1
		}
		strip_h: f32 = 112
		mw := aw
		mh := ah - strip_h - gap
		if mw * 9 / 16 > mh {
			mw = mh * 16 / 9
		} else {
			mh = mw * 9 / 16
		}
		draw_tile(ui, tiles[main], mw, mh)
		p.row(ui, "shrink-0 items-center justify-center gap-3")
		for t, i in tiles {
			if i != main {
				draw_tile(ui, t, strip_h * 16 / 9, strip_h, true)
			}
		}
		p.end(ui)
		return
	}

	cols, tw, th := grid_tile(len(tiles), aw, ah, gap)
	for i := 0; i < len(tiles); i += cols {
		p.row(ui, "shrink-0 items-center justify-center gap-3")
		for j in i ..< min(i + cols, len(tiles)) {
			draw_tile(ui, tiles[j], tw, th)
		}
		p.end(ui)
	}
}

draw_room_header :: proc(app: ^App, ui: ^p.Ctx) {
	r := app.room
	p.row(ui, "h-[56] shrink-0 items-center gap-3 px-4 border-b border-border bg-card")
	defer p.end(ui)

	p.div(ui, "size-2.5 rounded-full shrink-0")
	p.apply(ui, r.state == .Joined ? "bg-emerald-400" : r.state == .Ended ? "bg-destructive" : "bg-amber-400")
	p.end(ui)
	p.text(ui, "Call", "text-sm font-semibold")
	p.style(ui).shrink = 0
	n := 1
	for rm in r.remotes {
		if rm.present {
			n += 1
		}
	}
	p.textf(ui, "text-sm text-muted-foreground whitespace-nowrap", "%d %s", n, n == 1 ? "person" : "people")
	p.style(ui).shrink = 0

	if r.state == .Joined {
		secs := int(r.t - r.joined_at)
		p.textf(ui, "text-sm font-mono text-muted-foreground whitespace-nowrap", "%02d:%02d", secs / 60, secs % 60)
		p.style(ui).shrink = 0
	}

	sc.separator(ui, .Vertical, "h-5")

	// Encryption is a fact about the call, so it is stated, with the code.
	if r.e2ee {
		p.row(ui, "items-center gap-2 px-2.5 py-1 rounded-lg bg-emerald-500/10 border border-emerald-500/30 shrink-0")
		p.icon(ui, ICON_LOCK, "size-3.5 text-emerald-500 shrink-0")
		p.text(ui, "End-to-end encrypted", app.light ? "text-xs font-medium text-emerald-700 whitespace-nowrap" : "text-xs font-medium text-emerald-400 whitespace-nowrap")
		p.end(ui)
		if r.safety != "" {
			p.textf(ui, "text-xs font-mono text-muted-foreground whitespace-nowrap", "Safety code %s", r.safety)
			p.style(ui).shrink = 0
		}
	} else if r.state == .Joined {
		sc.badge(ui, "Not end-to-end encrypted", .Destructive)
	}

	p.spacer(ui)

	tier := r.tier == "high" ? "HD" : r.tier == "low" ? "SD — low bandwidth" : "Audio only — low bandwidth"
	if r.tier != "high" {
		sc.badge(ui, tier, .Secondary)
	}

	// Who you are in this call: the identity chip, in its colour and words.
	col := id_color(r.me.color)
	p.row(ui, fmt.tprintf("items-center gap-2 px-2.5 py-1 rounded-lg bg-%s-500/10 border border-%s-500/30 shrink-0", col, col))
	p.div(ui, fmt.tprintf("size-2 rounded-full bg-%s-500", col))
	p.end(ui)
	p.textf(ui, fmt.tprintf("text-xs font-medium whitespace-nowrap text-%s-%s", col, app.light ? "700" : "300"), "as %s", r.me.name)
	p.end(ui)
}

draw_room_side :: proc(app: ^App, ui: ^p.Ctx) {
	r := app.room
	p.col(ui, "w-[300] shrink-0 h-full gap-4 overflow-hidden")
	defer p.end(ui)

	p.col(ui, "w-full gap-1 rounded-xl border border-border bg-card p-3")
	p.row(ui, "items-center gap-2 pb-1")
	p.icon(ui, ICON_USERS, "size-4 text-muted-foreground")
	p.text(ui, "People", "text-sm font-semibold")
	p.end(ui)
	person :: proc(ui: ^p.Ctx, light: bool, name, handle, color: string, muted, speaking: bool, detail: string) {
		col := id_color(color)
		p.row(ui, "w-full items-center gap-2.5 py-1.5")
		p.div(ui, fmt.tprintf("size-8 rounded-full shrink-0 flex-row items-center justify-center bg-%s-500/20", col))
		p.text(ui, initials(name), fmt.tprintf("text-xs font-semibold text-%s-%s", col, light ? "700" : "300"))
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0")
		p.text(ui, name, "text-sm font-medium truncate")
		p.text(ui, detail, "text-[11] text-muted-foreground truncate")
		p.end(ui)
		if speaking {
			p.div(ui, "size-2 rounded-full bg-emerald-400 shrink-0")
			p.end(ui)
		}
		p.icon(ui, muted ? ICON_MIC_OFF : ICON_MIC, muted ? "size-3.5 text-rose-400 shrink-0" : "size-3.5 text-muted-foreground shrink-0")
		p.end(ui)
	}
	person(ui, app.light, fmt.tprintf("%s (you)", r.me.name), r.me.handle, r.me.color, app.a.muted, r.speaker == r.src, fmt.tprintf("@%s · sending HD + SD", r.me.handle))
	for rm in r.remotes {
		if !rm.present {
			continue
		}
		detail := fmt.tprintf("@%s · %s · %.0f ms", rm.handle, rm.cam_off ? "camera off" : rm.have_layer ? (rm.layer == 0 ? "HD" : "SD") : "no video", rm.a_wire.last_us / 1000)
		person(ui, app.light, rm.name, rm.handle, rm.color, rm.muted, r.speaker == rm.src, detail)
	}
	p.end(ui)

	p.col(ui, "w-full gap-2 rounded-xl border border-border bg-card p-3")
	p.row(ui, "items-center gap-2")
	p.icon(ui, ICON_LOCK, r.e2ee ? "size-4 text-emerald-500" : "size-4 text-destructive")
	p.text(ui, r.e2ee ? "End-to-end encrypted" : "Not encrypted end to end", "text-sm font-semibold")
	p.end(ui)
	if r.e2ee {
		p.text(ui, "Each person's audio and video is sealed with SFrame before it leaves their device. The server forwards it and cannot read it. Keys change whenever someone joins or leaves.", "text-xs text-muted-foreground")
		p.text(ui, "Read this code to each other. If it matches, nobody is in the middle.", "text-xs text-muted-foreground pt-1")
		p.div(ui, "w-full rounded-lg bg-muted px-3 py-2 flex-row justify-center")
		p.text(ui, r.safety, "text-sm font-mono font-semibold whitespace-nowrap")
		p.end(ui)
		p.textf(ui, "text-[11] text-muted-foreground", "Key generation %d · %d frames sealed", r.gen, r.frames_encrypted)
	}
	p.end(ui)

	p.col(ui, "w-full gap-0.5 rounded-xl border border-border bg-card p-3")
	p.text(ui, "Connection", "text-sm font-semibold pb-1")
	stat_row(ui, "Receiving", fmt.tprintf("%.0f kbit/s", r.rx_kbps))
	stat_row(ui, "Sending", fmt.tprintf("%.0f kbit/s", r.tx_kbps))
	stat_row(ui, "Video tier", r.tier)
	stat_row(ui, "Through", net.endpoint_to_string(r.sfu))
	p.end(ui)
}

draw_room_controls :: proc(app: ^App, ui: ^p.Ctx) {
	r := app.room
	p.row(ui, "h-[64] shrink-0 items-center justify-center gap-2 px-4 border-t border-border bg-card")
	defer p.end(ui)

	if key_button(ui, app.a.muted ? "Unmute" : "Mute", "M", app.a.muted ? ICON_MIC_OFF : ICON_MIC, app.a.muted ? .Destructive : .Outline) {
		app.a.muted = !app.a.muted
	}
	if key_button(ui, app.v.camera_off ? "Camera on" : "Camera off", "V", app.v.camera_off ? ICON_VIDEO_OFF : ICON_VIDEO, app.v.camera_off ? .Destructive : .Outline) {
		app.v.camera_off = !app.v.camera_off
		app.v_lo.camera_off = app.v.camera_off
	}
	if key_button(ui, app.layout == .Grid ? "Speaker view" : "Grid view", "L", app.layout == .Grid ? ICON_LAYOUT_SPEAKER : ICON_LAYOUT_GRID, .Outline) {
		app.layout = app.layout == .Grid ? .Speaker : .Grid
	}
	if key_button(ui, app.side ? "Hide people" : "People", "P", ICON_USERS, app.side ? .Secondary : .Outline) {
		app.side = !app.side
	}
	sc.separator(ui, .Vertical, "h-8 mx-1")
	if r.state != .Ended {
		if key_button(ui, "Leave", "H", ICON_PHONE_OFF, .Destructive) {
			room_leave(app)
		}
	}
}

room_leave :: proc(app: ^App) {
	r := app.room
	if r.state == .Ended {
		return
	}
	for _ in 0 ..< 3 {
		room_ctl(r, .Leave, "{}")
	}
	r.state = .Ended
	r.reason = "You left the call"
	stop_media(app)
}

draw_room_ui :: proc(app: ^App, ui: ^p.Ctx) {
	p.col(ui, "w-full h-full bg-background text-foreground")
	defer p.end(ui)

	draw_room_header(app, ui)
	sz := p.size(ui)
	body_h := max(160, sz.y - HEADER_H - CONTROLS_H)
	p.row(ui, "w-full items-stretch gap-4 p-4 overflow-hidden")
	p.style(ui).h = p.px(body_h)
	p.style(ui).shrink = 0
	aw := sz.x - 32 - (app.side ? 316 : 0)
	ah := body_h - 32
	draw_room_stage(app, ui, aw, ah)
	if app.side {
		draw_room_side(app, ui)
	}
	p.end(ui)
	draw_room_controls(app, ui)
}

room_handle_keys :: proc(app: ^App, ui: ^p.Ctx) {
	if app.win != nil && p.key_pressed(ui, 'q', false) {
		p.quit_app(app.win)
	}
	if p.key_pressed(ui, 'm', false) {
		app.a.muted = !app.a.muted
		log_line(app, app.a.muted ? "microphone muted" : "microphone live")
	}
	if p.key_pressed(ui, 'v', false) {
		app.v.camera_off = !app.v.camera_off
		app.v_lo.camera_off = app.v.camera_off
	}
	if p.key_pressed(ui, 'l', false) {
		app.layout = app.layout == .Grid ? .Speaker : .Grid
	}
	if p.key_pressed(ui, 'p', false) || p.key_pressed(ui, p.KEY_TAB, false) {
		app.side = !app.side
	}
	if p.key_pressed(ui, 'h', false) || p.key_pressed(ui, p.KEY_ESCAPE, false) {
		room_leave(app)
	}
}

room_window :: proc(app: ^App) {
	r := app.room
	win, werr := kit.start(
		{
			title = fmt.tprintf("Call — %s", r.me.name),
			width = 1280,
			height = 800,
			min_width = 920,
			min_height = 620,
			always = true,
		},
		!app.light,
	)
	if werr != "" {
		fmt.eprintfln("call: %s", werr)
		os.exit(1)
	}
	app.win = win
	defer p.destroy(win)
	for ui in p.frames(win) {
		handle_keys(app, ui)
		step(app, f64(p.app_elapsed(win)), ui.dt)
		draw_ui(app, ui)
		if app.quit_after > 0 && app.t > app.quit_after {
			p.quit_app(win)
		}
	}
	stop_media(app)
}

_ :: strings.Builder
