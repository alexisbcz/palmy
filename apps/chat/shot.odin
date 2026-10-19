package main

// `chat --shots <dir>`: render the real interface offscreen and write PNGs.
//
// The same `build` the window runs, through palmy's offscreen renderer: no
// compositor, no window, and -- the point here -- no socket. The client's
// model is filled in directly with an invented conversation between invented
// people, so a screenshot needs neither a server nor anybody's history.

import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."
import w "wire"

SHOT_W :: 1340
SHOT_H :: 840

@(private = "file")
shot_fonts :: proc(f: ^p.Fonts) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(f, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(f, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(f, path, .Mono, .Regular) {
			p.load_font(f, path, .Mono, .Medium)
			p.load_font(f, path, .Mono, .Semibold)
			p.load_font(f, path, .Mono, .Bold)
			break
		}
	}
}

@(private = "file")
Shot_Line :: struct {
	nick:    string,
	text:    string,
	minutes: int, // how long ago
	react:   string,
	reactor: string,
	replies: int,
	file:    string,
	mime:    string,
	size:    int,
}

@(private = "file")
shot_msgs :: proc(ch: string, lines: []Shot_Line, now: i64, first_id: i64) -> [dynamic]w.Msg {
	out := make([dynamic]w.Msg)
	for l, i in lines {
		m := w.Msg {
			id     = first_id + i64(i),
			ch     = strings.clone(ch),
			nick   = strings.clone(l.nick),
			text   = strings.clone(l.text),
			ts     = now - i64(l.minutes) * 60,
			reacts = make([dynamic]w.React),
		}
		if l.react != "" {
			nicks := make([dynamic]string)
			append(&nicks, strings.clone(l.reactor))
			append(&m.reacts, w.React{key = strings.clone(l.react), nicks = nicks})
		}
		if l.replies > 0 {
			m.replies = l.replies
			m.last_reply = m.ts + 120
		}
		if l.file != "" {
			m.file = w.Attach {
				id   = 900 + i64(i),
				name = strings.clone(l.file),
				mime = strings.clone(l.mime),
				size = l.size,
			}
		}
		append(&out, m)
	}
	return out
}

// shot_state fills the client's model the way a server's history would, with
// an invented crew talking about an invented ferry survey.
@(private = "file")
shot_state :: proc(a: ^App, now: i64) {
	a.nick = strings.clone("mira")

	append(
		&a.chans,
		Channel {
			name = strings.clone("survey"),
			kind = .Channel,
			topic = strings.clone("Tidewater ferry survey — findings, drafts and the board paper"),
			loaded = true,
			more = true,
			msgs = shot_msgs(
				"survey",
				{
					{nick = "teodor", text = "Morning. I have the tide gate table reconciled against the gauge readings at last.", minutes = 240},
					{nick = "teodor", text = "31 evenings held out of 92. Median hold 24 minutes, worst 51.", minutes = 238, react = "thumbsup", reactor = "alina"},
					{nick = "alina", text = "That matches what I get from the timetable side, which is reassuring given we counted them completely differently.", minutes = 232},
					{
						nick = "alina",
						text = "Six of the 31 were also weather holds though. If we attribute the whole delay to the gate we overstate it.",
						minutes = 230,
						replies = 4,
					},
					{nick = "mira", text = "Agreed. Let's quote both: **31 held**, **25 held by tide alone**, and say plainly which is which.", minutes = 225, react = "heart", reactor = "teodor"},
					{nick = "sabine", text = "From the crew side: nobody believes the seven minute turn on the northern reach. Eleven is what it takes with a full deck and one ramp.", minutes = 180},
					{nick = "sabine", text = "Put thirteen in the next timetable and we will keep it every single sailing.", minutes = 179},
					{
						nick = "teodor",
						text = "Here is the per-evening table, with the depth at the shoal in column four.",
						minutes = 96,
						file = "tide-holds-by-evening.csv",
						mime = "text/csv",
						size = 18244,
					},
					{nick = "alina", text = "Version four of the southern timetable moves the 18:40 to 19:05 on spring tides only. That clears the shoal on every evening in the survey except two.", minutes = 42},
					{nick = "rupert", text = "Board wants one number for dredging and one number for doing nothing. If the second is larger the paper writes itself.", minutes = 18, react = "rocket", reactor = "sabine"},
					{nick = "mira", text = "Both numbers are in the draft. The second one is larger.", minutes = 9},
				},
				now,
				101,
			),
			read_id = 110,
		},
	)
	append(
		&a.chans,
		Channel {
			name = strings.clone("dispatch"),
			kind = .Channel,
			topic = strings.clone("Overnight logs and sailing notices"),
			loaded = false,
			unread = 3,
		},
	)
	append(
		&a.chans,
		Channel {
			name = strings.clone("quayside"),
			kind = .Channel,
			topic = strings.clone("Berths, ramps and the eighteen metres we keep arguing about"),
			loaded = false,
			unread = 1,
			threads = 2,
		},
	)
	append(
		&a.chans,
		Channel {
			name = strings.clone("mira+sabine"),
			kind = .DM,
			loaded = false,
			unread = 2,
			mention = true,
		},
	)
	append(&a.chans, Channel{name = strings.clone("mira+rupert"), kind = .DM, loaded = false})

	for who in ([?]struct {
		nick:  string,
		state: w.Presence,
	}{
		{"mira", .Online},
		{"teodor", .Online},
		{"alina", .Online},
		{"sabine", .Away},
		{"rupert", .Away},
		{"dispatch", .Offline},
		{"lior", .Offline},
	}) {
		append(&a.members, Member{nick = strings.clone(who.nick), state = who.state})
	}

	append(&a.typers, Typer{nick = strings.clone("alina"), ch = strings.clone("survey"), at = 0})

	a.cur = 0
	a.link = .Online
	a.pinned = true
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("chat --shots: cannot create %s", dir)
		return 1
	}

	off := p.offscreen_create(
		SHOT_W,
		SHOT_H,
		1,
		"w-full h-full flex-row bg-background text-foreground overflow-hidden",
	)
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	sc.register_shadcn_theme(true)
	p.set_text_gamma(1.8)

	a := new(App)
	a.chans = make([dynamic]Channel)
	a.members = make([dynamic]Member)
	a.typers = make([dynamic]Typer)
	a.buf = make([dynamic]u8)
	a.query = make([dynamic]u8)
	a.results = make([dynamic]w.Msg)
	a.vlines = make([dynamic]Vline)
	a.tmsgs = make([dynamic]w.Msg)
	a.retry_in = 0.4
	// The footer prints the address the client would dial. Loopback, and the
	// default port, because nothing is dialled here at all.
	a.args.port = w.DEFAULT_PORT
	a.args.dark = true

	// A fixed wall clock, so the day dividers and the times beside each
	// message are the same in every run.
	now := i64(1791100800) // a round hour, used only as "when these arrived"
	shot_state(a, now)

	step :: proc(off: ^p.Offscreen, a: ^App) {
		ui := p.offscreen_begin(off)
		a.now = ui.now
		// The typing indicator expires against the frame clock; keep the one
		// typer alive so the strip above the composer has something in it.
		for &t in a.typers {
			t.at = ui.now
		}
		update_pin(a, ui)
		build(ui, a)
		pin_to_bottom(a, ui)
		p.offscreen_end(off)
	}

	// Hover, hit testing and the scroll pin all run against the previous
	// frame, so the settled picture is a few frames in.
	shot :: proc(off: ^p.Offscreen, a: ^App, dir, name: string) {
		for _ in 0 ..< 4 {
			step(off, a)
		}
		path := fmt.tprintf("%s/%s.png", dir, name)
		if p.offscreen_write_png(off, path) {
			fmt.printfln("  %s", path)
		} else {
			fmt.eprintfln("  could not write %s", path)
		}
	}

	// The representative frame: the channel, a draft half typed in the
	// composer, the member list on the right.
	a.mode = .Compose
	clear(&a.buf)
	append(&a.buf, "Dredging estimate is in the draft paper — I will post the figure here once")
	a.caret = len(a.buf)
	shot(off, a, dir, "app-chat")

	// The thread view, opened on the message that has replies.
	clear(&a.buf)
	a.caret = 0
	a.thread_root = 104
	a.thread_ch = strings.clone("survey")
	a.troot = a.chans[0].msgs[3]
	a.tloaded = true
	a.treplies = 4
	clear(&a.tmsgs)
	for m in shot_msgs(
		"survey",
		{
			{nick = "teodor", text = "Six is the number I have as well. All six were wind, none were fog.", minutes = 228},
			{nick = "mira", text = "Then the honest line is: 31 evenings held, of which 25 by tide alone.", minutes = 226},
			{nick = "alina", text = "I will split the weather column into wind and fog for the appendix.", minutes = 224, react = "thumbsup", reactor = "mira"},
			{nick = "rupert", text = "Good. The board will ask, and an answer that is already written is worth two that are not.", minutes = 220},
		},
		now,
		201,
	) {
		append(&a.tmsgs, m)
	}
	shot(off, a, dir, "02-chat-thread")
	a.thread_root = 0

	// Search.
	a.mode = .Search
	clear(&a.query)
	append(&a.query, "tide")
	a.qcaret = len(a.query)
	a.searched = true
	clear(&a.results)
	for m in shot_msgs(
		"survey",
		{
			{nick = "teodor", text = "31 evenings held out of 92. Median hold 24 minutes, worst 51.", minutes = 238},
			{nick = "alina", text = "Version four of the southern timetable moves the 18:40 to 19:05 on spring tides only.", minutes = 42},
			{nick = "mira", text = "Agreed. Let's quote both: 31 held, 25 held by tide alone.", minutes = 225},
		},
		now,
		301,
	) {
		append(&a.results, m)
	}
	shot(off, a, dir, "03-chat-search")
	a.mode = .Compose
	a.searched = false

	// The key map.
	a.help = true
	shot(off, a, dir, "04-chat-keys")
	a.help = false

	// Browsing: a message selected, its action bar and reaction palette up.
	a.mode = .Browse
	a.sel_msg = 105
	shot(off, a, dir, "05-chat-browse")

	fmt.printfln("chat --shots: wrote PNGs to %s", dir)
	return 0
}

// ---------------------------------------------------------------------------
// Cloud mode: `chat --cloud-shots <dir>`
//
// The same offscreen build, with the model a palm-rtc session would fill in:
// an identity speaking as itself, two spaces, a private channel, a live call,
// a thread, a DM with its read receipt, and invitations waiting.
// ---------------------------------------------------------------------------

@(private = "file")
Cloud_Line :: struct {
	nick, name, color, text: string,
	minutes:                 int,
	react, reactor:          string,
	replies:                 int,
	file, mime:              string,
	size:                    int,
	edited:                  bool,
}

@(private = "file")
cloud_msgs :: proc(ch: string, lines: []Cloud_Line, now: i64, first_id: i64, thread: i64 = 0) -> [dynamic]w.Msg {
	out := make([dynamic]w.Msg)
	for l, i in lines {
		m := w.Msg {
			id     = first_id + i64(i),
			ch     = strings.clone(ch),
			nick   = strings.clone(l.nick),
			name   = strings.clone(l.name),
			color  = strings.clone(l.color),
			text   = strings.clone(l.text),
			ts     = now - i64(l.minutes) * 60,
			thread = thread,
			seq    = i64(i + 1),
			rev    = i64(i + 1),
			reacts = make([dynamic]w.React),
		}
		if l.edited {
			m.edited = m.ts + 60
		}
		if l.react != "" {
			nicks := make([dynamic]string)
			for r in strings.split(l.reactor, ",", context.temp_allocator) {
				append(&nicks, strings.clone(r))
			}
			append(&m.reacts, w.React{key = strings.clone(l.react), nicks = nicks})
		}
		if l.replies > 0 {
			m.replies = l.replies
			m.last_reply = m.ts + 300
		}
		if l.file != "" {
			m.file = w.Attach{id = first_id + i64(i), name = strings.clone(l.file), mime = strings.clone(l.mime), size = l.size}
		}
		append(&out, m)
	}
	return out
}

@(private = "file")
cloud_state :: proc(a: ^App, now: i64) {
	a.cloud = true
	a.me = Ident_View{id = "a2", handle = "alice.northwind", name = "Alice Martin", color = "indigo", kind = "work"}
	a.nick = a.me.handle
	append(&a.spaces, Space{id = "nw", name = "Northwind", role = "owner", owner = "alice.northwind", members = 4})
	append(&a.spaces, Space{id = "lh", name = "Lumen Health", role = "member", owner = "theo.lumen", members = 9})
	a.cur_space = "nw"

	A, B, C := "alice.northwind", "bob.northwind", "carol.diaz"
	general := cloud_msgs("c-general", {
		{nick = B, name = "Bob Chen", color = "emerald", text = "Infra freeze lifts at 18:00 tonight. Anything that needs the window, say so here.", minutes = 190},
		{nick = A, name = "Alice Martin", color = "indigo", text = "The **release** goes out Friday at 10:00, after standup. Blockers?", minutes = 64, react = "thumbsup", reactor = "bob.northwind,carol.diaz", replies = 3, edited = true},
		{nick = C, name = "Carol Diaz", color = "sky", text = "Board deck v4 is up — the pricing slide changed, the rest is wording.", minutes = 41, file = "board-deck-v4.pdf", mime = "application/pdf", size = 2_380_000},
		{nick = B, name = "Bob Chen", color = "emerald", text = "Ran the migration against a copy of production: `4m12s`, no locks held longer than 300 ms.", minutes = 18, react = "rocket", reactor = "alice.northwind"},
		{nick = B, name = "Bob Chen", color = "emerald", text = "Jumping on a call to walk through the rollback plan — join if you have ten minutes.", minutes = 3},
	}, now, 1201)
	append(&a.chans, Channel{
		name = strings.clone("c-general"), label = strings.clone("general"), space = "nw", kind = .Channel,
		topic = strings.clone("Everyone in Northwind — releases, freezes, the board"), loaded = true, msgs = general,
		call = "call-1",
	})
	c0 := &a.chans[0]
	append(&c0.call_who, Who{nick = B, name = "Bob Chen", color = "emerald"})
	append(&c0.call_who, Who{nick = C, name = "Carol Diaz", color = "sky"})
	append(&a.chans, Channel{name = strings.clone("c-design"), label = strings.clone("design"), space = "nw", kind = .Channel, private = true, unread = 2, threads = 1, topic = strings.clone("Pixels and the board deck")})
	append(&a.chans, Channel{name = strings.clone("c-launch"), label = strings.clone("launch"), space = "nw", kind = .Channel, unread = 1, mention = true})
	append(&a.chans, Channel{name = strings.clone("d-bob"), label = strings.clone("Bob Chen"), peer = B, space = "nw", kind = .DM})
	append(&a.chans, Channel{name = strings.clone("d-carol"), label = strings.clone("Carol Diaz"), peer = C, space = "nw", kind = .DM, unread = 1})
	append(&a.chans, Channel{name = strings.clone("c-ops"), label = strings.clone("ops"), space = "lh", kind = .Channel, unread = 4})

	for who in ([?]struct {
		nick, name, color: string,
		state:             w.Presence,
	}{
		{A, "Alice Martin", "indigo", .Online},
		{B, "Bob Chen", "emerald", .Online},
		{C, "Carol Diaz", "sky", .Away},
		{"dana.okafor", "Dana Okafor", "teal", .Offline},
	}) {
		append(&a.members, Member{nick = strings.clone(who.nick), name = strings.clone(who.name), color = strings.clone(who.color), state = who.state})
	}
	append(&a.invites, Invite{
		id = "inv-1", space = "lh2", space_name = "Lumen Health", role = "guest", ch = "c-x", ch_name = "partner-pilot",
		from_name = "Théo Laurent", from_handle = "theo.lumen", from_color = "amber",
	})
	append(&a.invites, Invite{
		id = "inv-2", space = "kc", space_name = "Kestrel Collective", role = "member",
		from_name = "Priya Raman", from_handle = "priya.kestrel", from_color = "violet",
	})
	a.seen_invites = len(a.invites)
	append(&a.typers, Typer{nick = strings.clone(C), ch = strings.clone("c-general"), at = 0})
	a.cur = 0
	a.link = .Online
	a.pinned = true
}

cloud_shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o755)); err != nil && !os.exists(dir) {
		fmt.eprintfln("chat --cloud-shots: cannot create %s", dir)
		return 1
	}
	for dark in ([2]bool{true, false}) {
		off := p.offscreen_create(SHOT_W + RAIL_W, SHOT_H, 1, "w-full h-full flex-row bg-background text-foreground overflow-hidden")
		shot_fonts(&off.fonts)
		sc.register_shadcn_theme(dark)
		p.set_text_gamma(1.8)
		theme := dark ? "dark" : "light"

		a := new(App)
		a.chans = make([dynamic]Channel)
		a.members = make([dynamic]Member)
		a.typers = make([dynamic]Typer)
		a.buf = make([dynamic]u8)
		a.query = make([dynamic]u8)
		a.results = make([dynamic]w.Msg)
		a.vlines = make([dynamic]Vline)
		a.tmsgs = make([dynamic]w.Msg)
		a.retry_in = 0.4
		a.args.dark = dark
		now := i64(1791100800)
		cloud_state(a, now)

		step :: proc(off: ^p.Offscreen, a: ^App) {
			ui := p.offscreen_begin(off)
			a.now = ui.now
			for &t in a.typers {
				t.at = ui.now
			}
			update_pin(a, ui)
			build(ui, a)
			pin_to_bottom(a, ui)
			p.offscreen_end(off)
		}
		shot :: proc(off: ^p.Offscreen, a: ^App, dir, name: string) {
			for _ in 0 ..< 4 {
				step(off, a)
			}
			path := fmt.tprintf("%s/%s.png", dir, name)
			if p.offscreen_write_png(off, path) {
				fmt.printfln("  %s", path)
			}
		}

		// The channel, a call live in it, a draft in the composer.
		a.mode = .Compose
		append(&a.buf, "I can join in five — is the rollback plan in the doc?")
		a.caret = len(a.buf)
		shot(off, a, dir, fmt.aprintf("cloud-channel-%s", theme))
		clear(&a.buf)
		a.caret = 0

		// The thread under the release message.
		a.thread_root = 1202
		a.thread_ch = strings.clone("c-general")
		a.troot = a.chans[0].msgs[1]
		a.tloaded = true
		a.treplies = 3
		clear(&a.tmsgs)
		for m in cloud_msgs("c-general", {
			{nick = "bob.northwind", name = "Bob Chen", color = "emerald", text = "None from infra once the freeze lifts.", minutes = 60},
			{nick = "carol.diaz", name = "Carol Diaz", color = "sky", text = "Deck needs sign-off by Thursday noon, otherwise fine.", minutes = 55, react = "check", reactor = "alice.northwind"},
			{nick = "alice.northwind", name = "Alice Martin", color = "indigo", text = "Then Friday 10:00 it is. I'll post the checklist here.", minutes = 50},
		}, now, 1301, 1202) {
			append(&a.tmsgs, m)
		}
		shot(off, a, dir, fmt.aprintf("cloud-thread-%s", theme))
		a.thread_root = 0

		// A DM, with the other side's read receipt.
		dm := find_chan(a, "d-bob")
		a.chans[dm].loaded = true
		a.chans[dm].msgs = cloud_msgs("d-bob", {
			{nick = "bob.northwind", name = "Bob Chen", color = "emerald", text = "Can you take the release notes this time? I'm on the migration.", minutes = 30},
			{nick = "alice.northwind", name = "Alice Martin", color = "indigo", text = "Yes — I'll have a draft in the doc by 16:00.", minutes = 28},
		}, now, 1401)
		append(&a.chans[dm].seen, Seen{nick = "bob.northwind", id = 1402})
		// Set directly: switch_to would announce a read cursor, and there is
		// no socket here to announce it on.
		a.cur = dm
		a.want_bottom = true
		shot(off, a, dir, fmt.aprintf("cloud-dm-%s", theme))
		a.cur = 0

		// The invitations.
		a.inv_open = true
		shot(off, a, dir, fmt.aprintf("cloud-invites-%s", theme))
		a.inv_open = false

		// Inviting someone: the From card leads.
		a.prompt = .Invite
		append(&a.pbuf, "dana.okafor")
		a.pcaret = len(a.pbuf)
		shot(off, a, dir, fmt.aprintf("cloud-invite-%s", theme))
		a.prompt = .None

		p.offscreen_destroy(off)
	}
	fmt.printfln("chat --cloud-shots: wrote PNGs to %s", dir)
	return 0
}
