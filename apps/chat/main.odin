// palmy-chat — a Slack-shaped team chat client.
//
// It speaks the protocol in ../PROTOCOL.md to a real TCP server on 127.0.0.1.
// Two of these running side by side on this machine are two clients talking to
// each other; nothing here is simulated.
//
// Pointer clicks cannot be synthesised on this compositor, so the whole
// application is keyboard-driven and modal: `Compose` has the keyboard by
// default, and F2/F3/F4 hand it to the channel list, the member list and
// search. F1 draws the full key map.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."
import w "wire"

WIN_W :: 1340
WIN_H :: 840

SIDEBAR_W :: 236
MEMBERS_W :: 208

Mode :: enum u8 {
	Compose,
	Browse,
	Channels,
	Members,
	Search,
}

Link :: enum u8 {
	Offline,
	Connecting,
	Online,
}

// A reaction is a name on the wire and a drawn icon here: the UI font has no
// emoji coverage and the only emoji font on this machine is a colour-bitmap
// face palmy's rasterizer cannot read. See PROTOCOL.md.
Reaction :: struct {
	key:   string,
	ic:    p.Icon,
	label: string,
}

REACTIONS := [6]Reaction {
	{"thumbsup", IC_THUMBS_UP, "+1"},
	{"heart", IC_HEART, "love"},
	{"party", IC_PARTY_POPPER, "party"},
	{"rocket", IC_ROCKET, "ship it"},
	{"fire", IC_FLAME, "fire"},
	{"grin", IC_FACE_GRINNING, "ha"},
}

Channel :: struct {
	name:    string,
	kind:    w.Chan_Kind,
	topic:   string,
	msgs:    [dynamic]w.Msg,
	loaded:  bool,
	more:    bool, // older history exists server-side

	// The read cursor, and the three numbers derived from it. All four come
	// from the server: `read_id` is the highest id this *person* has read,
	// persisted there, so closing the client and opening it again finds the
	// same unread count rather than zero.
	read_id: i64,
	unread:  int,  // new messages in the timeline
	threads: int,  // new replies inside threads, which are not timeline rows
	mention: bool,

	// Cloud mode (protocol v2). `name` is then the channel's id, the key
	// every frame uses, and `label` is what to draw.
	label:    string,
	space:    string,
	private:  bool,
	peer:     string, // a DM's other handle
	rev:      i64, // the newest change number seen: what to sync from
	call:     string, // the live call in this channel, "" for none
	call_who: [dynamic]Who,
	seen:     [dynamic]Seen, // read receipts: how far each other member has read
}

Member :: struct {
	nick:  string,
	state: w.Presence,
	name:  string, // cloud: the identity's display name
	color: string, // cloud: the identity's colour
}

Typer :: struct {
	nick: string,
	ch:   string,
	at:   f64,
}

Args :: struct {
	nick:     string,
	port:     int,
	dark:     bool,
	selftest: bool,
	server:   string,
	post_ch:  string,
	post_txt: string,
	att_ch:   string,
	att_path: string,
	thread:   i64,
	full:     bool,

	cloud:    bool, // speak protocol v2 to palm-rtc, as an account identity
	rtc_port: int,
	identity: string, // which identity to speak as (else PALM_IDENTITY)
	call_bin: string, // the call app to launch for a call
}

App :: struct {
	args:        Args,
	nick:        string,

	// Connection.
	sock:        net.TCP_Socket,
	watch:       Sock_Watch, // wakes the window when the socket has data; see wake.odin
	link:        Link,
	rd:          w.Reader,
	retry_at:    f64,
	retry_in:    f64,
	rq:          i64,
	err_text:    string,

	// Model.
	chans:       [dynamic]Channel,
	cur:         int,
	members:     [dynamic]Member,
	typers:      [dynamic]Typer,

	// Interaction.
	mode:        Mode,
	sel_msg:     i64,
	sel_chan:    int,
	sel_member:  int,
	help:        bool,

	// Composer.
	buf:         [dynamic]u8,
	caret:       int,
	editing:     i64,
	replying:    i64,
	compose_w:   f32,
	body_w:      f32,
	vlines:      [dynamic]Vline,

	// Thread view. `thread_root` is the root message id of the open thread, 0
	// when none is open. While it is open the composer posts *into* the thread
	// instead of the channel.
	thread_root: i64,
	thread_ch:   string,
	troot:       w.Msg,
	tmsgs:       [dynamic]w.Msg,
	tloaded:     bool,
	treplies:    int,  // the server's count, which a capped page may fall short of
	tmore:       bool, // older replies exist that this page does not hold

	// Attachments.
	pick:        kit.Pick,
	saving:      string, // where the `file` frame for `saving_rq` should be written
	saving_rq:   i64,

	// Search.
	query:       [dynamic]u8,
	qcaret:      int,
	results:     [dynamic]w.Msg,
	sel_result:  int,
	searched:    bool,
	pending_dm:  string,

	// Scrolling.
	list_id:     u64,
	pinned:      bool,
	new_below:   int,
	want_bottom: bool,

	// Typing / presence.
	typing_on:   bool,
	typing_at:   f64,
	last_key:    f64,
	away:        bool,

	toast:       string,
	toast_t:     f64,
	tz:          i64,
	now:         f64,

	// Cloud mode.
	cloud:           bool,
	ck:              ^ck.Client,
	me:              Ident_View,
	spaces:          [dynamic]Space,
	cur_space:       string,
	invites:         [dynamic]Invite,
	seen_invites:    int,
	inv_open:        bool,
	sel_invite:      int,
	token_exp:       i64,
	next_auth_check: f64,
	was_online:      bool,
	syncing:         bool,
	prompt:          Prompt_Kind,
	pbuf:            [dynamic]u8,
	pcaret:          int,
}

// Vline is one visual line of the composer: a byte range in `buf`.
Vline :: struct {
	start, end: int,
}

main :: proc() {
	// A verb is the command line's (cli.odin, docs/PALM-CLI.md); everything
	// else is the window's own flags, unchanged.
	if len(os.args) > 1 && is_cli_invocation(os.args[1]) {
		code, _ := kit.cli(surface())
		os.exit(code)
	}
	a := new(App)
	a.args = parse_args()
	a.nick = a.args.nick
	a.cloud = a.args.cloud

	if a.args.selftest {
		os.exit(selftest(a.args))
	}
	if a.args.post_ch != "" || a.args.att_ch != "" {
		os.exit(post_once(a.args))
	}
	run_ui(a)
}

parse_args :: proc() -> Args {
	out := Args {
		nick = default_nick(),
		port = w.DEFAULT_PORT,
		dark = true,
	}
	args := os.args[1:]
	for i := 0; i < len(args); i += 1 {
		switch args[i] {
		case "--nick":
			if i + 1 < len(args) {
				i += 1
				out.nick = args[i]
			}
		case "--port":
			if i + 1 < len(args) {
				i += 1
				if n, ok := strconv.parse_int(args[i]); ok {
					out.port = n
				}
			}
		case "--server":
			if i + 1 < len(args) {
				i += 1
				out.server = args[i]
			}
		case "--fullscreen":
			out.full = true
		case "--cloud":
			out.cloud = true
		case "--rtc-port":
			if i + 1 < len(args) {
				i += 1
				if n, ok := strconv.parse_int(args[i]); ok {
					out.rtc_port = n
				}
			}
		case "--identity":
			if i + 1 < len(args) {
				i += 1
				out.identity = args[i]
			}
		case "--call-bin":
			if i + 1 < len(args) {
				i += 1
				out.call_bin = args[i]
			}
		case "--light":
			out.dark = false
		case "--dark":
			out.dark = true
		case "--selftest":
			out.selftest = true
		case "--shots":
			// Offscreen screenshots of the real interface, against a model
			// filled in here. No compositor, no window, and no socket.
			dir := "palmy-chat-shots"
			if i + 1 < len(args) {
				i += 1
				dir = args[i]
			}
			os.exit(shots(dir))
		case "--cloud-shots":
			dir := "palmy-chat-cloud-shots"
			if i + 1 < len(args) {
				i += 1
				dir = args[i]
			}
			os.exit(cloud_shots(dir))
		case "--post":
			if i + 2 < len(args) {
				out.post_ch = args[i + 1]
				out.post_txt = args[i + 2]
				i += 2
			}
		case "--attach":
			if i + 2 < len(args) {
				out.att_ch = args[i + 1]
				out.att_path = args[i + 2]
				i += 2
			}
		case "--thread":
			if i + 1 < len(args) {
				i += 1
				if n, ok := strconv.parse_i64(args[i]); ok {
					out.thread = n
				}
			}
		case "--help", "-h":
			fmt.println("palmy-chat client")
			fmt.println("  --nick NAME      nickname to join as (default $USER)")
			fmt.println("  --port N         server port on 127.0.0.1 (default 8787)")
			fmt.println("  --light          light theme")
			fmt.println("  --fullscreen     open fullscreen (handy for screenshots)")
			fmt.println("  --cloud          the Palmy cloud (palm-rtc) as an account identity")
			fmt.println("  --identity H     with --cloud: the identity to speak as (else PALM_IDENTITY)")
			fmt.println("  --rtc-port N     with --cloud: the gateway's port on 127.0.0.1 (default 8790)")
			fmt.println("  --call-bin PATH  the call app to launch for calls (default: call)")
			fmt.println("  spaces|channels|post|history|search|invite|invites|accept|dm|call|...")
			fmt.println("                   cloud commands; `chat help` lists them")
			fmt.println("  --post CH TEXT   post one message and exit")
			fmt.println("  --attach CH PATH upload one file and exit")
			fmt.println("  --thread ID      with --post or --attach: reply inside that thread")
			fmt.println("  --selftest       headless protocol test, no UI")
			fmt.println("  --shots DIR      render the interface offscreen into PNGs")
			fmt.println("  --server PATH    server binary for --selftest to spawn")
			os.exit(0)
		case:
			fmt.eprintfln("chat: unknown argument %q", args[i])
			os.exit(2)
		}
	}
	return out
}

default_nick :: proc() -> string {
	if v := os.get_env("PALM_IDENTITY", context.allocator); v != "" {
		return v
	}
	if v := os.get_env("USER", context.allocator); v != "" {
		return v
	}
	return "someone"
}

// ---------------------------------------------------------------------------
// The frame loop
// ---------------------------------------------------------------------------

run_ui :: proc(a: ^App) {
	app, err := kit.start(
		{
			title = fmt.tprintf("chat — %s", a.nick),
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 900,
			min_height = 560,
			root_class = "w-full h-full flex-row bg-background text-foreground overflow-hidden",
			// No `always`: the loop sleeps, and a thread watching the socket
			// wakes it when something arrives (wake.odin).
		},
		a.args.dark,
	)
	if err != "" {
		fmt.eprintfln("chat: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	a.chans = make([dynamic]Channel)
	a.members = make([dynamic]Member)
	a.typers = make([dynamic]Typer)
	a.buf = make([dynamic]u8)
	a.query = make([dynamic]u8)
	a.results = make([dynamic]w.Msg)
	a.vlines = make([dynamic]Vline)
	a.tmsgs = make([dynamic]w.Msg)
	a.pinned = true
	a.retry_in = 0.4
	a.tz = tz_offset()
	a.cur = -1

	a.now = mono()
	net_connect(a)
	if !watch_start(&a.watch, app) {
		fmt.eprintln("chat: cannot start the socket watcher")
		os.exit(1)
	}
	defer watch_stop(&a.watch)

	frame := 0
	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		a.now = mono()
		frame += 1
		if frame == 2 && a.args.full {
			p.set_fullscreen(app, true)
		}
		if p.key_pressed(ui, p.KEY_F11) {
			p.set_fullscreen(app, !p.is_fullscreen(app))
		}

		net_pump(a)
		watch_frame(&a.watch, a)
		cloud_tick(a)
		expire_typers(a)
		// The attach dialog is modal, so the list behind it must not react to
		// a wheel aimed at the dialog.
		if !kit.pick_active(&a.pick) {
			update_pin(a, ui)
		}
		handle_keys(ui, app, a)
		build(ui, a)
		pin_to_bottom(a, ui)

		if a.toast != "" && a.now > a.toast_t {
			// This frame still drew the toast; one more takes it off the
			// screen.
			a.toast = ""
			p.redraw(ui)
		}
		// Anything sent this frame (a key, a read cursor) may have a reply
		// already on its way; the watcher sees it. Deadlines are armed here.
		watch_frame(&a.watch, a)
		schedule_wakes(ui, a)
	}
	net_close(a)
}

tz_offset :: proc() -> i64 {
	// core:time has no timezone database, so the one authority on this machine
	// answers instead. Once, at startup.
	out, ok := kit.run({"date", "+%z"}, context.temp_allocator)
	if !ok || len(out) < 5 {
		return 0
	}
	sign: i64 = out[0] == '-' ? -1 : 1
	hh, _ := strconv.parse_int(out[1:3])
	mm, _ := strconv.parse_int(out[3:5])
	return sign * (i64(hh) * 3600 + i64(mm) * 60)
}

toast :: proc(a: ^App, msg: string) {
	a.toast = strings.clone(msg, context.allocator)
	a.toast_t = a.now + 3.5
}

// ---------------------------------------------------------------------------
// Model helpers
// ---------------------------------------------------------------------------

chan_at :: proc(a: ^App, i: int) -> ^Channel {
	if i < 0 || i >= len(a.chans) {
		return nil
	}
	return &a.chans[i]
}

current :: proc(a: ^App) -> ^Channel {
	return chan_at(a, a.cur)
}

find_chan :: proc(a: ^App, name: string) -> int {
	for c, i in a.chans {
		if c.name == name {
			return i
		}
	}
	return -1
}

// chan_label is what the sidebar and the header show: a channel's own name, or
// the other person's nickname for a DM.
chan_label :: proc(a: ^App, c: ^Channel) -> string {
	if c.label != "" {
		return c.label
	}
	if c.kind == .DM {
		return w.dm_other(c.name, a.nick)
	}
	return c.name
}

msg_at :: proc(c: ^Channel, id: i64) -> ^w.Msg {
	if c == nil {
		return nil
	}
	for &m in c.msgs {
		if m.id == id {
			return &m
		}
	}
	return nil
}

// selected resolves the browse cursor. It looks in the open thread as well,
// because a thread reply is never in the channel timeline and a selection
// that cannot be resolved silently disables every browse-mode action.
selected :: proc(a: ^App) -> ^w.Msg {
	if m := msg_at(current(a), a.sel_msg); m != nil {
		return m
	}
	if a.thread_root != 0 {
		if a.troot.id == a.sel_msg {
			return &a.troot
		}
		for &m in a.tmsgs {
			if m.id == a.sel_msg {
				return &m
			}
		}
	}
	return nil
}

switch_to :: proc(a: ^App, i: int) {
	if i < 0 || i >= len(a.chans) || i == a.cur {
		return
	}
	a.cur = i
	a.sel_msg = 0
	close_thread(a)
	a.pinned = true
	a.new_below = 0
	a.want_bottom = true
	c := current(a)
	if !c.loaded {
		req_history(a, c.name, 0)
	}
	mark_read(a)
}

step_channel :: proc(a: ^App, d: int) {
	if len(a.chans) == 0 {
		return
	}
	// In cloud mode the sidebar shows one space at a time, and stepping
	// stays inside it.
	i := a.cur
	for {
		i += d
		if i < 0 || i >= len(a.chans) {
			return
		}
		if in_view(a, i) {
			switch_to(a, i)
			return
		}
	}
}

// nth_in_view is the n-th channel (0-based) of the space on screen.
nth_in_view :: proc(a: ^App, n: int) -> int {
	k := 0
	for _, i in a.chans {
		if !in_view(a, i) {
			continue
		}
		if k == n {
			return i
		}
		k += 1
	}
	return -1
}

// mark_read moves the server-side cursor to the newest message on screen, and
// only while the user is actually looking at the bottom of the channel.
//
// The important part is where the number lives. Marking read is a request, not
// a local assignment: the server stores the cursor against the nickname and
// echoes back the count it derives from it. So the count a reconnecting client
// shows is the server's, which is the same one it had before — the old model,
// "the highest id seen while connected", reset to zero on every reconnect, and
// that is exactly what this replaces.
mark_read :: proc(a: ^App) {
	c := current(a)
	if c == nil || !a.pinned {
		return
	}
	newest: i64 = 0
	if len(c.msgs) > 0 {
		newest = c.msgs[len(c.msgs) - 1].id
	}
	// A thread reply is not a timeline row, but it shares the one cursor. If
	// its thread is open and loaded the user is looking at it, so the cursor
	// may move past it — and that is the only thing that can ever clear this
	// channel's thread marker.
	if a.thread_root != 0 && a.tloaded && a.thread_ch == c.name {
		for m in a.tmsgs {
			newest = max(newest, m.id)
		}
	}
	if newest <= c.read_id {
		// The cursor cannot move, so there is nothing to tell the server.
		// Announcing it anyway would be a round trip per frame that comes
		// back with the same count — which is how a stale badge becomes a
		// permanent one.
		return
	}
	c.read_id = newest
	c.unread = 0
	c.mention = false
	send_read(a, c.name, c.read_id)
}

expire_typers :: proc(a: ^App) {
	for i := len(a.typers) - 1; i >= 0; i -= 1 {
		if a.now - a.typers[i].at > 6 {
			ordered_remove(&a.typers, i)
		}
	}
}

typers_here :: proc(a: ^App, allocator := context.temp_allocator) -> []string {
	c := current(a)
	out := make([dynamic]string, allocator)
	if c == nil {
		return out[:]
	}
	for t in a.typers {
		if t.ch == c.name && t.nick != a.nick {
			append(&out, display_name(a, t.nick))
		}
	}
	return out[:]
}

presence_of_nick :: proc(a: ^App, nick: string) -> w.Presence {
	for m in a.members {
		if m.nick == nick {
			return m.state
		}
	}
	return .Offline
}

// ---------------------------------------------------------------------------
// Scrolling: pinned to the bottom unless the user has scrolled up
// ---------------------------------------------------------------------------

// update_pin decides whether the list is still following the newest message.
//
// It deliberately does NOT infer that from the scroll offset alone: when a
// message arrives the content grows while the offset stays put, which looks
// exactly like the user having scrolled up. The only thing that moves the
// offset behind this app's back is the wheel, so the wheel is what is read.
// Keyboard scrolling unpins at its own call sites.
update_pin :: proc(a: ^App, ui: ^p.Ctx) {
	if a.list_id == 0 {
		return
	}
	ext := p.scroll_extent(ui, a.list_id).y
	if ext <= 1 {
		// Nothing to scroll: the conversation is shorter than the pane.
		a.pinned = true
		a.new_below = 0
		return
	}
	if p.wheel(ui).y == 0 {
		return
	}
	// palmy applied this frame's wheel to the hovered container already.
	at := p.scroll_of(ui, a.list_id).y
	if at >= ext - 4 {
		if !a.pinned {
			a.pinned = true
			a.new_below = 0
			mark_read(a)
		}
	} else {
		a.pinned = false
	}
}

// pin_to_bottom runs after the tree is built. The clamp inside `scroll_to`
// uses the previous frame's extent, so asking for a huge offset every frame
// keeps the list glued to the newest message as it grows — within one frame,
// which at vsync is invisible.
pin_to_bottom :: proc(a: ^App, ui: ^p.Ctx) {
	if a.list_id == 0 {
		return
	}
	if a.pinned || a.want_bottom {
		p.scroll_to(ui, a.list_id, {0, 1e9})
		ext := p.scroll_extent(ui, a.list_id).y
		if a.want_bottom && p.scroll_of(ui, a.list_id).y >= ext - 4 {
			a.want_bottom = false
		}
	}
}

jump_to_latest :: proc(a: ^App) {
	a.pinned = true
	a.want_bottom = true
	a.new_below = 0
	mark_read(a)
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, a: ^App) {
	// The attach dialog owns the keyboard while it is up — it reads its own
	// input inside `pick_draw`, during the draw pass. Without this early
	// return an Escape would both cancel the dialog and leave browse mode.
	if kit.pick_active(&a.pick) {
		return
	}
	if len(ui.input.keys) > 0 || len(p.typed_text(ui)) > 0 {
		a.last_key = a.now
		if a.away {
			a.away = false
			send_presence(a, .Online)
		}
	} else if !a.away && a.link == .Online && a.now - a.last_key > 150 && a.last_key > 0 {
		a.away = true
		send_presence(a, .Away)
	}

	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}
	if p.key_pressed(ui, p.KEY_F1) {
		a.help = !a.help
		return
	}
	if a.help {
		if len(ui.input.keys) > 0 {
			a.help = false
		}
		return
	}

	// Mode switches, available from anywhere.
	if p.key_pressed(ui, p.KEY_F2) {
		a.mode = .Channels
		a.sel_chan = max(a.cur, 0)
		return
	}
	if p.key_pressed(ui, p.KEY_F3) {
		a.mode = .Members
		return
	}
	if p.key_pressed(ui, p.KEY_F4) || p.shortcut(ui, 'f', {.Ctrl}) {
		open_search(a)
		return
	}
	if p.shortcut(ui, p.KEY_DOWN, {.Ctrl}) {
		step_channel(a, 1)
		return
	}
	if p.shortcut(ui, p.KEY_UP, {.Ctrl}) {
		step_channel(a, -1)
		return
	}
	for n in 1 ..= 9 {
		if p.shortcut(ui, u32('0' + n), {.Ctrl}) {
			switch_to(a, nth_in_view(a, n - 1))
			return
		}
		if a.cloud && p.shortcut(ui, u32('0' + n), {.Alt}) {
			switch_space(a, n - 1)
			return
		}
	}
	if a.cloud {
		if a.prompt != .None {
			keys_prompt(ui, a)
			return
		}
		if a.inv_open {
			keys_invites(ui, a)
			return
		}
		if p.shortcut(ui, 'j', {.Ctrl}) {
			start_call(a)
			return
		}
		if p.key_pressed(ui, p.KEY_F6) {
			a.inv_open = len(a.invites) > 0
			if !a.inv_open {
				toast(a, "No invitations waiting")
			}
			return
		}
		if p.shortcut(ui, 'i', {.Ctrl}) {
			a.prompt = .Invite
			clear(&a.pbuf)
			a.pcaret = 0
			return
		}
		if p.shortcut(ui, 'n', {.Ctrl}) {
			a.prompt = .New_Channel
			clear(&a.pbuf)
			a.pcaret = 0
			return
		}
	}
	if p.shortcut(ui, 'l', {.Ctrl}) {
		jump_to_latest(a)
		return
	}
	if p.shortcut(ui, 't', {.Ctrl}) {
		if a.thread_root != 0 {
			close_thread(a)
		} else {
			open_thread(a)
		}
		return
	}
	if p.shortcut(ui, 'o', {.Ctrl}) {
		begin_attach(a)
		return
	}
	if p.shortcut(ui, 'g', {.Ctrl}) {
		a.away = !a.away
		send_presence(a, a.away ? .Away : .Online)
		return
	}

	switch a.mode {
	case .Compose:
		keys_compose(ui, a)
	case .Browse:
		keys_browse(ui, app, a)
	case .Channels:
		keys_channels(ui, a)
	case .Members:
		keys_members(ui, a)
	case .Search:
		keys_search(ui, a)
	}
}

keys_compose :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		if a.editing != 0 || a.replying != 0 {
			cancel_draft(a)
		} else if a.thread_root != 0 {
			close_thread(a)
		} else {
			a.mode = .Browse
			if a.sel_msg == 0 {
				select_last(a)
			}
		}
		return
	}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {
		scroll_list(a, ui, -1)
		return
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
		scroll_list(a, ui, 1)
		return
	}

	submitted := false
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if .Shift in k.mods {
				insert_text(a, "\n")
			} else {
				submitted = true
			}
		}
	}

	changed := edit_buffer(ui, a, &a.buf, &a.caret, true)

	if submitted {
		send_draft(a)
	} else if changed && len(a.buf) > 0 {
		// Only a real keystroke renews the indicator, so a draft left sitting
		// stops claiming someone is typing.
		note_typing(a)
	} else if a.typing_on && a.now - a.typing_at > 5 {
		stop_typing(a)
	}
}

keys_browse :: proc(ui: ^p.Ctx, app: ^p.App, a: ^App) {
	c := current(a)
	if c == nil {
		return
	}
	if a.sel_msg == 0 {
		select_last(a)
	}

	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.mode = .Compose
		return
	}
	if p.key_pressed(ui, p.KEY_UP) {
		step_message(a, -1)
		return
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		step_message(a, 1)
		return
	}
	if p.key_pressed(ui, p.KEY_HOME) {
		if len(c.msgs) > 0 {
			a.sel_msg = c.msgs[0].id
			a.pinned = false
		}
		return
	}
	if p.key_pressed(ui, p.KEY_END) {
		select_last(a)
		jump_to_latest(a)
		return
	}
	if p.key_pressed(ui, p.KEY_PAGE_UP) {
		scroll_list(a, ui, -1)
		return
	}
	if p.key_pressed(ui, p.KEY_PAGE_DOWN) {
		scroll_list(a, ui, 1)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		if m := selected(a); m != nil && m.replies > 0 && a.thread_root != m.id {
			open_thread(a)
		} else {
			a.mode = .Compose
		}
		return
	}
	if p.key_pressed(ui, p.KEY_DELETE) {
		delete_selected(a)
		return
	}

	for k in ui.input.keys {
		if .Ctrl in k.mods || .Alt in k.mods {
			continue
		}
		switch k.sym {
		case 'j':
			step_message(a, 1)
		case 'k':
			step_message(a, -1)
		case 'i':
			a.mode = .Compose
		case 'r':
			begin_reply(a)
		case 't':
			open_thread(a)
		case 'o':
			save_attachment(a)
		case 'e':
			begin_edit(a)
		case 'd':
			delete_selected(a)
		case 'y':
			if m := selected(a); m != nil {
				if kit.clipboard_set(m.text) {
					toast(a, "Message copied")
				} else {
					toast(a, "wl-copy is not installed")
				}
			}
		case 'g':
			jump_to_latest(a)
		case '/':
			open_search(a)
		case 'q':
			p.quit_app(app)
		case '1', '2', '3', '4', '5', '6':
			toggle_reaction(a, int(k.sym - '1'))
		}
	}
}

keys_channels :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.mode = .Compose
		return
	}
	if p.key_pressed(ui, p.KEY_UP) {
		a.sel_chan = next_in_view(a, a.sel_chan, -1)
		return
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		a.sel_chan = next_in_view(a, a.sel_chan, 1)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		switch_to(a, a.sel_chan)
		a.mode = .Compose
		return
	}
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case 'j':
			a.sel_chan = next_in_view(a, a.sel_chan, 1)
		case 'k':
			a.sel_chan = next_in_view(a, a.sel_chan, -1)
		}
	}
}

keys_members :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.mode = .Compose
		return
	}
	if p.key_pressed(ui, p.KEY_UP) {
		a.sel_member = max(0, a.sel_member - 1)
		return
	}
	if p.key_pressed(ui, p.KEY_DOWN) {
		a.sel_member = min(len(a.members) - 1, a.sel_member + 1)
		return
	}
	if p.key_pressed(ui, p.KEY_RETURN) || p.key_pressed(ui, p.KEY_KP_ENTER) {
		open_dm(a)
		return
	}
	for k in ui.input.keys {
		if .Ctrl in k.mods {
			continue
		}
		switch k.sym {
		case 'j':
			a.sel_member = min(len(a.members) - 1, a.sel_member + 1)
		case 'k':
			a.sel_member = max(0, a.sel_member - 1)
		}
	}
}

keys_search :: proc(ui: ^p.Ctx, a: ^App) {
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		a.mode = .Compose
		a.searched = false
		return
	}
	if a.searched {
		if p.key_pressed(ui, p.KEY_UP) {
			a.sel_result = max(0, a.sel_result - 1)
			return
		}
		if p.key_pressed(ui, p.KEY_DOWN) {
			a.sel_result = min(len(a.results) - 1, a.sel_result + 1)
			return
		}
	}

	submitted := false
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			submitted = true
		}
	}

	changed := edit_buffer(ui, a, &a.query, &a.qcaret, false)
	if changed {
		a.searched = false
	}

	if submitted {
		if a.searched && len(a.results) > 0 {
			jump_to_result(a)
		} else {
			run_search(a)
		}
	}
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

select_last :: proc(a: ^App) {
	c := current(a)
	if c == nil || len(c.msgs) == 0 {
		a.sel_msg = 0
		return
	}
	a.sel_msg = c.msgs[len(c.msgs) - 1].id
}

step_message :: proc(a: ^App, d: int) {
	c := current(a)
	if c == nil || len(c.msgs) == 0 {
		return
	}
	at := -1
	for m, i in c.msgs {
		if m.id == a.sel_msg {
			at = i
			break
		}
	}
	if at < 0 {
		at = len(c.msgs) - 1
	}
	at = clamp(at + d, 0, len(c.msgs) - 1)
	a.sel_msg = c.msgs[at].id
	// Moving off the newest message is a deliberate scroll up.
	if at < len(c.msgs) - 1 {
		a.pinned = false
	} else {
		jump_to_latest(a)
	}
}

scroll_list :: proc(a: ^App, ui: ^p.Ctx, dir: int) {
	if a.list_id == 0 {
		return
	}
	page := max(f32(120), p.size(ui).y * 0.6)
	p.scroll_nudge(ui, a.list_id, {0, f32(dir) * page})
	at := p.scroll_of(ui, a.list_id).y
	ext := p.scroll_extent(ui, a.list_id).y
	if dir < 0 {
		a.pinned = false
		// Reaching the top is the cue to page older history in.
		if at <= 2 {
			load_older(a)
		}
	} else if at >= ext - 4 {
		jump_to_latest(a)
	}
}

load_older :: proc(a: ^App) {
	c := current(a)
	if c == nil || !c.more || len(c.msgs) == 0 {
		return
	}
	req_history(a, c.name, c.msgs[0].id)
}

begin_reply :: proc(a: ^App) {
	m := selected(a)
	if m == nil || m.deleted {
		return
	}
	a.replying = m.id
	a.editing = 0
	a.mode = .Compose
}

// ---------------------------------------------------------------------------
// Threads
//
// A thread is a first-class place, not a decoration on a reply. Its root is a
// message id; its replies carry `thread = <root>` and never appear in the
// channel timeline. Opening one asks the server for it rather than filtering
// what happens to be loaded, so a thread is complete even when its replies
// are older than the history on screen.
// ---------------------------------------------------------------------------

open_thread :: proc(a: ^App) {
	c := current(a)
	m := selected(a)
	if c == nil {
		return
	}
	if m == nil {
		// No selection yet: the newest message is the sensible root.
		select_last(a)
		m = selected(a)
		if m == nil {
			return
		}
	}
	root := m.thread != 0 ? m.thread : m.id
	if a.thread_root == root {
		return
	}
	a.thread_root = root
	if a.thread_ch != "" {
		delete(a.thread_ch, context.allocator)
	}
	a.thread_ch = strings.clone(c.name, context.allocator)
	thread_clear(a)
	req_thread(a, root)
	a.mode = .Compose
}

close_thread :: proc(a: ^App) {
	if a.thread_root == 0 {
		return
	}
	a.thread_root = 0
	thread_clear(a)
}

// thread_clear drops the loaded thread and frees it. The messages in it are
// clones, and a thread is opened and closed on a keystroke, so clearing the
// list without freeing leaks a little every time.
thread_clear :: proc(a: ^App) {
	a.tloaded = false
	a.treplies = 0
	a.tmore = false
	w.msgs_destroy(&a.tmsgs)
	w.msg_destroy(&a.troot)
}

thread_reply_count :: proc(a: ^App) -> int {
	return max(a.treplies, a.troot.replies)
}

// ---------------------------------------------------------------------------
// Attachments
// ---------------------------------------------------------------------------

begin_attach :: proc(a: ^App) {
	if a.link != .Online {
		toast(a, "Not connected — nothing can be uploaded")
		return
	}
	if current(a) == nil {
		return
	}
	kit.pick_begin(
		&a.pick,
		.Open_File,
		{
			title = "Attach a file",
			confirm = "Attach",
			filters = ATTACH_FILTERS[:],
			dir = os.get_env("PALMY_CHAT_ATTACH_DIR", context.temp_allocator),
		},
	)
}

finish_attach :: proc(a: ^App, path: string) {
	c := current(a)
	if c == nil {
		return
	}
	ok, why := send_attach(a, c.name, path, a.thread_root)
	if !ok {
		toast(a, why)
		return
	}
	toast(a, fmt.tprintf("Uploading %s…", pick_name(path)))
	jump_to_latest(a)
}

// save_attachment asks the server for the selected message's file and writes
// it next to the user's other downloads. The client never learns the server's
// path and never asks for one: it asks by message id.
// save_attachment takes the message it was asked about rather than looking it
// up again. A thread reply lives in `a.tmsgs`, not in the channel timeline, so
// re-resolving through `selected()` would fail for exactly the attachment the
// user just clicked on.
save_attachment :: proc(a: ^App, msg: ^w.Msg = nil) {
	m := msg if msg != nil else selected(a)
	if m == nil || m.file.id == 0 {
		toast(a, "That message has no attachment")
		return
	}
	dir := download_dir()
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) {
		toast(a, fmt.tprintf("cannot create %s", dir))
		return
	}
	// The name is the server's, so it is sanitised again here: nothing a peer
	// sends may decide where this process writes.
	name := w.safe_filename(m.file.name, context.temp_allocator)
	if !send_fetch(a, m.file.id, fmt.tprintf("%s/%s", dir, name)) {
		toast(a, "Not connected — nothing was fetched")
		return
	}
	toast(a, fmt.tprintf("Fetching %s…", name))
}

// download_dir is where a fetched attachment lands. `PALMY_CHAT_DOWNLOADS`
// exists so the demo recording can point it at a scratch directory instead of
// dropping files into the user's own ~/Downloads.
download_dir :: proc() -> string {
	if v := os.get_env("PALMY_CHAT_DOWNLOADS", context.temp_allocator); v != "" {
		return v
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil {
		return "/tmp"
	}
	return fmt.tprintf("%s/Downloads", home)
}

pick_name :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

mime_of :: proc(path: string) -> string {
	lower := strings.to_lower(pick_name(path), context.temp_allocator)
	switch {
	case strings.has_suffix(lower, ".png"):
		return "image/png"
	case strings.has_suffix(lower, ".jpg"), strings.has_suffix(lower, ".jpeg"):
		return "image/jpeg"
	case strings.has_suffix(lower, ".gif"):
		return "image/gif"
	case strings.has_suffix(lower, ".webp"):
		return "image/webp"
	case strings.has_suffix(lower, ".svg"):
		return "image/svg+xml"
	case strings.has_suffix(lower, ".pdf"):
		return "application/pdf"
	case strings.has_suffix(lower, ".json"):
		return "application/json"
	case strings.has_suffix(lower, ".md"), strings.has_suffix(lower, ".txt"),
	     strings.has_suffix(lower, ".odin"), strings.has_suffix(lower, ".log"):
		return "text/plain"
	}
	return "application/octet-stream"
}

ATTACH_FILTERS := [?]kit.Pick_Filter {
	{label = "Everything", exts = nil},
	{label = "Images", exts = []string{"png", "jpg", "jpeg", "gif", "webp"}},
	{label = "Text", exts = []string{"txt", "md", "odin", "json", "log"}},
}

begin_edit :: proc(a: ^App) {
	m := selected(a)
	if m == nil {
		return
	}
	if m.nick != a.nick {
		toast(a, "Only the author can edit a message")
		return
	}
	if m.deleted {
		return
	}
	a.editing = m.id
	a.replying = 0
	clear(&a.buf)
	append(&a.buf, ..transmute([]u8)m.text)
	a.caret = len(a.buf)
	a.mode = .Compose
}

delete_selected :: proc(a: ^App) {
	m := selected(a)
	if m == nil || m.deleted {
		return
	}
	if m.nick != a.nick {
		toast(a, "Only the author can delete a message")
		return
	}
	send_delete(a, m.id)
}

toggle_reaction :: proc(a: ^App, n: int) {
	if n < 0 || n >= len(REACTIONS) {
		return
	}
	m := selected(a)
	if m == nil || m.deleted {
		return
	}
	key := REACTIONS[n].key
	send_react(a, m.id, key, !w.react_has(m^, key, a.nick))
}

cancel_draft :: proc(a: ^App) {
	if a.editing != 0 {
		clear(&a.buf)
		a.caret = 0
	}
	a.editing = 0
	a.replying = 0
}

send_draft :: proc(a: ^App) {
	text := strings.trim_space(string(a.buf[:]))
	if text == "" {
		cancel_draft(a)
		return
	}
	c := current(a)
	if c == nil {
		return
	}
	if a.link != .Online {
		toast(a, "Not connected — nothing was sent")
		return
	}

	if a.editing != 0 {
		send_edit(a, a.editing, text)
	} else {
		// With a thread open the composer posts *into* it. That is the whole
		// difference between a thread and a quoted reply: this never appears
		// in the channel timeline.
		send_post(a, c.name, text, a.replying, a.thread_root)
	}
	clear(&a.buf)
	a.caret = 0
	a.editing = 0
	a.replying = 0
	stop_typing(a)
	jump_to_latest(a)
}

open_dm :: proc(a: ^App) {
	if a.sel_member < 0 || a.sel_member >= len(a.members) {
		return
	}
	other := a.members[a.sel_member].nick
	if other == a.nick {
		toast(a, "That is you")
		return
	}
	if a.cloud {
		open_dm_cloud(a, other)
		return
	}
	name := w.dm_name(a.nick, other, context.temp_allocator)
	if i := find_chan(a, name); i >= 0 {
		switch_to(a, i)
		a.mode = .Compose
		return
	}
	a.pending_dm = strings.clone(name, context.allocator)
	send_join(a, name, "dm")
	a.mode = .Compose
	toast(a, fmt.tprintf("Opening a direct message with %s", other))
}

open_search :: proc(a: ^App) {
	a.mode = .Search
	a.searched = false
	a.sel_result = 0
}

run_search :: proc(a: ^App) {
	q := strings.trim_space(string(a.query[:]))
	if q == "" {
		return
	}
	send_search(a, q)
}

jump_to_result :: proc(a: ^App) {
	if a.sel_result < 0 || a.sel_result >= len(a.results) {
		return
	}
	m := a.results[a.sel_result]
	if i := find_chan(a, m.ch); i >= 0 {
		switch_to(a, i)
		a.sel_msg = m.id
		a.pinned = false
		a.mode = .Browse
		a.searched = false
		// The message may be older than what is loaded; the row only exists
		// to scroll to once history reaches back that far.
		if msg_at(current(a), m.id) == nil {
			req_history(a, m.ch, m.id + 1)
		}
	}
}

// ---------------------------------------------------------------------------
// Typing indicator
// ---------------------------------------------------------------------------

note_typing :: proc(a: ^App) {
	c := current(a)
	if c == nil || a.link != .Online {
		return
	}
	// One `typing on` every two seconds while the draft is alive, rather than
	// one per keystroke.
	if !a.typing_on || a.now - a.typing_at > 2 {
		send_typing(a, c.name, true)
		a.typing_on = true
		a.typing_at = a.now
	}
}

stop_typing :: proc(a: ^App) {
	if !a.typing_on {
		return
	}
	c := current(a)
	if c != nil {
		send_typing(a, c.name, false)
	}
	a.typing_on = false
}

// ---------------------------------------------------------------------------
// The composer's text model
//
// palmy's `text_field` is single line and submits on any Return, so the
// composer owns its own buffer: a byte array plus a caret, soft-wrapped for
// display and navigated by visual line. Shift+Enter is handled by the caller,
// before this runs.
// ---------------------------------------------------------------------------

// edit_buffer applies this frame's text input to `buf`. `multiline` enables
// Up/Down across wrapped lines.
edit_buffer :: proc(
	ui: ^p.Ctx,
	a: ^App,
	buf: ^[dynamic]u8,
	caret: ^int,
	multiline: bool,
) -> (changed: bool) {
	caret^ = clamp(caret^, 0, len(buf))

	if typed := p.typed_text(ui); len(typed) > 0 {
		inject_at_elems(buf, caret^, ..transmute([]u8)typed)
		caret^ += len(typed)
		changed = true
	}

	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_BACKSPACE:
			if .Ctrl in k.mods {
				continue
			}
			if caret^ > 0 {
				n := utf8_back(buf[:], caret^)
				remove_range(buf, caret^ - n, caret^)
				caret^ -= n
				changed = true
			}
		case p.KEY_DELETE:
			if caret^ < len(buf) {
				n := utf8_fwd(buf[:], caret^)
				remove_range(buf, caret^, caret^ + n)
				changed = true
			}
		case p.KEY_LEFT:
			if caret^ > 0 {
				caret^ -= utf8_back(buf[:], caret^)
			}
		case p.KEY_RIGHT:
			if caret^ < len(buf) {
				caret^ += utf8_fwd(buf[:], caret^)
			}
		case p.KEY_UP:
			if multiline {
				caret^ = caret_by_line(a, buf[:], caret^, -1)
			}
		case p.KEY_DOWN:
			if multiline {
				caret^ = caret_by_line(a, buf[:], caret^, 1)
			}
		case p.KEY_HOME:
			caret^ = multiline ? line_start(a, caret^) : 0
		case p.KEY_END:
			caret^ = multiline ? line_end(a, caret^) : len(buf)
		case 'a':
			if .Ctrl in k.mods {
				caret^ = multiline ? line_start(a, caret^) : 0
			}
		case 'e':
			if .Ctrl in k.mods {
				caret^ = multiline ? line_end(a, caret^) : len(buf)
			}
		case 'u':
			if .Ctrl in k.mods {
				clear(buf)
				caret^ = 0
				changed = true
			}
		case 'w':
			if .Ctrl in k.mods && caret^ > 0 {
				i := caret^
				for i > 0 && buf[i - 1] == ' ' {i -= 1}
				for i > 0 && buf[i - 1] != ' ' && buf[i - 1] != '\n' {i -= 1}
				remove_range(buf, i, caret^)
				caret^ = i
				changed = true
			}
		}
	}
	return changed
}

insert_text :: proc(a: ^App, s: string) {
	inject_at_elems(&a.buf, a.caret, ..transmute([]u8)s)
	a.caret += len(s)
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return max(1, at - i)
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return min(i, len(b)) - at
}

// wrap_compose recomputes the composer's visual lines for the width measured
// on the previous frame. Called once per frame from the UI, before the caret
// navigation of the next frame needs it.
wrap_compose :: proc(a: ^App, fonts: ^p.Fonts, size: f32) {
	clear(&a.vlines)
	s := string(a.buf[:])
	width := max(a.compose_w, 80)

	start := 0
	for start <= len(s) {
		// One logical line at a time.
		nl := strings.index_byte(s[start:], '\n')
		stop := nl < 0 ? len(s) : start + nl

		at := start
		for {
			if at >= stop {
				append(&a.vlines, Vline{at, stop})
				break
			}
			// Greedy: the longest prefix that fits, broken at the last space.
			fit := at
			last_space := -1
			for i := at; i < stop; i += 1 {
				if s[i] == ' ' {
					last_space = i
				}
				wpx := p.text_width(fonts, s[at:i + 1], size, .Sans, .Regular)
				if wpx > width {
					break
				}
				fit = i + 1
			}
			if fit >= stop {
				append(&a.vlines, Vline{at, stop})
				break
			}
			cut := last_space > at ? last_space + 1 : max(fit, at + utf8_fwd(a.buf[:], at))
			append(&a.vlines, Vline{at, cut})
			at = cut
		}

		if nl < 0 {
			break
		}
		start = stop + 1
		if start > len(s) {
			append(&a.vlines, Vline{start, start})
			break
		}
	}
	if len(a.vlines) == 0 {
		append(&a.vlines, Vline{0, 0})
	}
}

// caret_line returns -1 before the first frame has wrapped anything.
caret_line :: proc(a: ^App, caret: int) -> int {
	if len(a.vlines) == 0 {
		return -1
	}
	for v, i in a.vlines {
		if caret >= v.start && caret <= v.end {
			return i
		}
	}
	return len(a.vlines) - 1
}

line_start :: proc(a: ^App, caret: int) -> int {
	i := caret_line(a, caret)
	return i < 0 ? 0 : a.vlines[i].start
}

line_end :: proc(a: ^App, caret: int) -> int {
	i := caret_line(a, caret)
	return i < 0 ? len(a.buf) : a.vlines[i].end
}

caret_by_line :: proc(a: ^App, buf: []u8, caret: int, d: int) -> int {
	li := caret_line(a, caret)
	if li < 0 {
		return caret
	}
	target := li + d
	if target < 0 || target >= len(a.vlines) {
		return caret
	}
	col := caret - a.vlines[li].start
	v := a.vlines[target]
	return min(v.start + col, v.end)
}
