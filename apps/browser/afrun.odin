// `browser autofill-run`: the window, offscreen, with a real engine and the
// real vault socket, driven by a script of keys and checks. It is how the
// autofill tests and screenshots run without a display: every key goes
// through the same input path a person's would (palmy's input queue, then
// handle_input), and the checks read what the chrome and the engine said.
//
// Steps, one per line ('#' starts a comment):
//
//   key <name>                 Down Up Return Escape Tab BackSpace, or a letter
//   type <text>                text into whatever has focus
//   sleep <seconds>            keep frames running
//   navigate <url>             the active tab goes there
//   wait-focus [kind]          a login field took focus (username password otp)
//   wait-state <state>         the vault is unlocked, locked, unpaired or not_running
//   wait-open                  the dropdown is up and the vault has answered
//   expect-rows <n>            that many logins in the dropdown
//   expect-open / expect-closed
//   wait-fill [status]         the engine answered a fill (ok origin_changed no_field form_action failed)
//   wait-vault-fill <allowed|refused>  the vault answered a fill request
//   wait-bar [save|update|locked]      the save bar is up and decided
//   wait-saved [saved|updated|refused] the vault answered a save
//   force-fill <title>         ask the vault for that login on this origin, as a pick would
//   fill-from-omnibox          the address bar's key (or the menu's "Fill login")
//   expect-trace <text>        something in the autofill trace contains it
//   expect-no-trace <text>
//   shot <file.png>
//
// Each check prints "ok" or "FAIL"; the exit status is the number of
// failures (0 when all pass).
package browser

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import kit "kit:."
import pb "pb"
import p "palmy:."

Afrun_Options :: struct {
	url:    string,
	steps:  string,
	dark:   bool,
	width:  int,
	height: int,
	engine: Engine_Kind,
	set:    bool,
}

@(private = "file")
Run :: struct {
	s:     ^State,
	off:   ^p.Offscreen,
	fails: int,
	oks:   int,
}

@(private = "file")
step_frame :: proc(r: ^Run) {
	s := r.s
	pump_engine(s)
	ui := p.offscreen_begin(r.off)
	r.off.input.over_surface = false
	handle_input(ui, s)
	frame(ui, s)
	sync_view_size(ui, s) // the save bar moves the page down, as in the window
	if rr := p.rect_of(ui, s.page_id); rr.w > 0 {
		s.page_rect = rr
	}
	p.offscreen_end(r.off)
}

@(private = "file")
run_for :: proc(r: ^Run, seconds: f64) {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < seconds {
		step_frame(r)
		time.sleep(25 * time.Millisecond)
	}
}

// wait_until runs frames until `cond` holds or `seconds` pass.
@(private = "file")
wait_until :: proc(r: ^Run, seconds: f64, cond: proc(s: ^State, arg: string) -> bool, arg: string) -> bool {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < seconds {
		step_frame(r)
		if cond(r.s, arg) {
			return true
		}
		time.sleep(25 * time.Millisecond)
	}
	return false
}

@(private = "file")
verdict :: proc(r: ^Run, ok: bool, what: string, args: ..any) {
	if ok {
		r.oks += 1
		fmt.printf("ok    ")
	} else {
		r.fails += 1
		fmt.printf("FAIL  ")
	}
	fmt.printfln(what, ..args)
}

@(private = "file")
key_sym :: proc(name: string) -> u32 {
	switch name {
	case "Down":
		return p.KEY_DOWN
	case "Up":
		return p.KEY_UP
	case "Return", "Enter":
		return p.KEY_RETURN
	case "Escape":
		return p.KEY_ESCAPE
	case "Tab":
		return p.KEY_TAB
	case "BackSpace":
		return 0xff08
	case "space":
		return ' '
	}
	if len(name) == 1 {
		return u32(name[0])
	}
	return 0
}

@(private = "file")
trace_has :: proc(s: ^State, text: string) -> bool {
	for t in s.af.trace {
		if strings.contains(t, text) {
			return true
		}
	}
	return false
}

// trace_starts: a fresh entry (the ones already checked are marked "(seen)")
@(private = "file")
trace_starts :: proc(s: ^State, prefix: string) -> bool {
	for t in s.af.trace {
		if strings.has_prefix(t, prefix) {
			return true
		}
	}
	return false
}

@(private = "file")
fill_rows :: proc(s: ^State) -> int {
	n := 0
	for row in af_rows(s) {
		if row.action == .Fill {
			n += 1
		}
	}
	return n
}

afrun :: proc(prof: ^Profile, opt: Afrun_Options) -> int {
	profile_ensure(prof)
	s := new(State)
	g_state = s
	state_init(s, prof^)
	s.headless = true
	s.dark = opt.dark
	if opt.set {
		s.engine_kind = opt.engine
	}
	s.window_w = opt.width
	r := Run{s = s}
	r.off = p.offscreen_create(opt.width, opt.height, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(r.off)
	shot_fonts(r.off, opt.dark)

	t := new_tab(s, PAGE_URLS[.New_Tab])
	step_frame(&r)
	step_frame(&r)
	{
		ui := p.offscreen_begin(r.off)
		frame(ui, s)
		rr := p.rect_of(ui, s.page_id)
		p.offscreen_end(r.off)
		s.page_size = {int(rr.w), int(rr.h)}
	}
	s.engine = engine_start(s.engine_kind, &s.prof, nil)
	if !s.engine.ok {
		fmt.eprintln("browser autofill-run:", s.engine.error)
		return 100
	}
	engine_theme(s.engine, s.dark)
	af_init(s)
	defer state_shutdown(s)
	fmt.printfln("#     %s %s, identity %s (vault handle %s)", s.engine.name, s.engine.version, s.prof.identity, s.af.identity)

	if opt.url != "" {
		navigate(s, t, opt.url)
		set_focus(s, .Page)
		wait_until(&r, 30, proc(s: ^State, _: string) -> bool {
			t := active_tab(s)
			return t != nil && !t.loading && t.title != "" && surface_of(s.engine, t.id).frames > 0
		}, "")
	}

	for raw_line in strings.split_lines(opt.steps, context.allocator) {
		line := strings.trim_space(raw_line)
		if line == "" || line[0] == '#' {
			continue
		}
		cmd := line
		arg := ""
		if i := strings.index_byte(line, ' '); i >= 0 {
			cmd = line[:i]
			arg = strings.trim_space(line[i + 1:])
		}
		switch cmd {
		case "key":
			sym := key_sym(arg)
			append(&r.off.input.keys, p.Key_Event{sym = sym, unshifted = sym})
			if sym >= 0x20 && sym < 0x7f {
				strings.write_rune(&r.off.input.text, rune(sym))
			}
			step_frame(&r)
			run_for(&r, 0.15)
		case "type":
			for c in arg {
				sym := pb.rune_keysym(c)
				append(&r.off.input.keys, p.Key_Event{sym = sym, unshifted = sym})
				strings.write_rune(&r.off.input.text, c)
				step_frame(&r)
			}
			run_for(&r, 0.15)
		case "fill-from-omnibox":
			// what the address bar's key and the menu's "Fill login" do
			af_fill_from_omnibox(s)
			step_frame(&r)
		case "stamp":
			// the wall clock, for checks against the test site's log
			fmt.printfln("# stamp %s %.3f", arg, f64(time.time_to_unix_nano(time.now())) / 1e9)
		case "sleep":
			secs, _ := strconv.parse_f64(arg)
			run_for(&r, secs)
		case "navigate":
			if at := active_tab(s); at != nil {
				navigate(s, at, arg)
				set_focus(s, .Page)
			}
			step_frame(&r)
		case "wait-focus":
			ok := wait_until(&r, 15, proc(s: ^State, kind: string) -> bool {
				if s.af.view == 0 || s.af.origin == "" {
					return false
				}
				switch kind {
				case "username":
					return s.af.kind == .Username
				case "password":
					return s.af.kind == .Password
				case "otp":
					return s.af.kind == .Otp
				}
				return s.af.kind != .None
			}, arg)
			verdict(&r, ok, "a login field took focus (%s): %v on %s", arg != "" ? arg : "any", s.af.kind, s.af.origin)
		case "wait-state":
			ok := wait_until(&r, 15, proc(s: ^State, want: string) -> bool {
				return strings.to_lower(fmt.tprint(s.af.vault), context.temp_allocator) == want
			}, arg)
			verdict(&r, ok, "the vault is %s (%v)", arg, s.af.vault)
		case "wait-open":
			ok := wait_until(&r, 15, proc(s: ^State, _: string) -> bool {
				return s.af.open && s.af.vault != .Unknown && (s.af.vault != .Unlocked || s.af.cand_origin == s.af.origin)
			}, "")
			verdict(&r, ok, "the dropdown is up (%v, %d logins)", s.af.vault, fill_rows(s))
		case "expect-rows":
			want, _ := strconv.parse_int(arg)
			verdict(&r, fill_rows(s) == want, "%d login(s) offered (wanted %d)", fill_rows(s), want)
		case "expect-open":
			verdict(&r, s.af.open, "the dropdown is open")
		case "expect-closed":
			verdict(&r, !s.af.open, "the dropdown is closed")
		case "wait-fill":
			want := arg != "" ? arg : "ok"
			ok := wait_until(&r, 20, proc(s: ^State, want: string) -> bool {
				return trace_starts(s, "fill result ")
			}, want)
			got := ""
			for x in s.af.trace {
				if strings.has_prefix(x, "fill result ") {
					got = x[len("fill result "):]
				}
			}
			verdict(&r, ok && strings.to_lower(got, context.temp_allocator) == want, "the engine answered the fill: %s (wanted %s)", got, want)
			clear_trace_prefix(s, "fill result ")
		case "wait-vault-fill":
			ok := wait_until(&r, 20, proc(s: ^State, _: string) -> bool {
				return trace_starts(s, "vault fill: ")
			}, "")
			got := ""
			for x in s.af.trace {
				if strings.has_prefix(x, "vault fill: ") {
					got = x[len("vault fill: "):]
				}
			}
			allowed := got == "allowed"
			verdict(&r, ok && (arg == "allowed") == allowed, "the vault answered the fill: %s (wanted %s)", got, arg)
			clear_trace_prefix(s, "vault fill: ")
		case "force-fill":
			found := false
			for c in s.af.candidates {
				if c.title == arg {
					found = true
				}
			}
			if !found {
				// a login of another identity, say: ask by the id the
				// test passes as "id:<uuid>"
				if strings.has_prefix(arg, "id:") {
					delete(s.af.fill_item)
					s.af.fill_item = strings.clone(arg[3:])
					s.af.fill_seq = af_queue(s, {kind = .Fill, view = s.af.view, origin = strings.clone(s.af.origin), id = strings.clone(arg[3:])})
					af_trace(s, "forced a fill of %s", arg)
				}
			} else {
				for c, i in af_rows(s) {
					if c.action == .Fill && c.cand.title == arg {
						af_pick(s, i)
					}
				}
			}
		case "wait-bar":
			ok := wait_until(&r, 20, proc(s: ^State, _: string) -> bool {
				return s.af.bar.active && !s.af.bar.waiting
			}, "")
			kind := !s.af.bar.active ? "none" : s.af.vault != .Unlocked ? "locked" : s.af.bar.update ? "update" : "save"
			verdict(&r, ok && (arg == "" || arg == kind), "the save bar is up: %s (wanted %s)", kind, arg)
		case "expect-no-bar":
			run_for(&r, 1.5)
			verdict(&r, !s.af.bar.active, "no save bar")
		case "wait-saved":
			ok := wait_until(&r, 20, proc(s: ^State, _: string) -> bool {
				return trace_starts(s, "save: ")
			}, "")
			got := ""
			for x in s.af.trace {
				if strings.has_prefix(x, "save: ") {
					got = x[len("save: "):]
				}
			}
			verdict(&r, ok && (arg == "" || got == arg || (arg == "refused" && got != "saved" && got != "updated")), "the vault answered the save: %s (wanted %s)", got, arg)
		case "expect-trace":
			verdict(&r, trace_has(s, arg), "the trace has %q", arg)
		case "expect-no-trace":
			verdict(&r, !trace_has(s, arg), "the trace has no %q", arg)
		case "shot":
			for _ in 0 ..< 6 {
				step_frame(&r)
				time.sleep(40 * time.Millisecond)
			}
			ok := p.offscreen_write_png(r.off, arg)
			verdict(&r, ok, "wrote %s", arg)
		case:
			fmt.eprintfln("browser autofill-run: unknown step %q", cmd)
			r.fails += 1
		}
	}
	fmt.printfln("#     trace:")
	for x in s.af.trace {
		fmt.printfln("#       %s", x)
	}
	fmt.printfln("#     %d ok, %d failed", r.oks, r.fails)
	return r.fails
}

@(private = "file")
clear_trace_prefix :: proc(s: ^State, prefix: string) {
	for &x in s.af.trace {
		if strings.has_prefix(x, prefix) {
			old := x
			x = strings.concatenate({"(seen) ", old})
			delete(old)
		}
	}
}

cmd_autofill_run :: proc(c: ^kit.Call) -> int {
	id := identity_of(c.identity)
	prof, ok := profile_open(id)
	if !ok {
		return kit.cli_fail(c, kit.EXIT_USAGE, fmt.tprintf("%q is not a usable identity name", id))
	}
	steps := kit.cli_str(c, "steps")
	if f := kit.cli_str(c, "steps-file"); f != "" {
		data, err := os.read_entire_file(f, context.allocator)
		if err != nil {
			return kit.cli_fail(c, kit.EXIT_NOT_FOUND, fmt.tprintf("cannot read %s", f))
		}
		steps = string(data)
	}
	steps, _ = strings.replace_all(steps, ";", "\n")
	opt := Afrun_Options {
		url    = kit.cli_str(c, "url"),
		steps  = steps,
		dark   = kit.cli_str(c, "theme") == "dark",
		width  = kit.cli_int(c, "width", 1100),
		height = kit.cli_int(c, "height", 720),
	}
	if e := kit.cli_str(c, "engine"); e != "" {
		opt.engine, _ = engine_parse(e)
		opt.set = true
	}
	fails := afrun(&prof, opt)
	kit.jset_int(c.out, "failed", fails)
	if fails != 0 {
		return kit.cli_fail(c, kit.EXIT_FAILED, fmt.tprintf("%d check(s) failed", fails))
	}
	return kit.EXIT_OK
}
