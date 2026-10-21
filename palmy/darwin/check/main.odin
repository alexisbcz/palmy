// The macOS backend's windowed self-check: one real Cocoa window, driven by
// events this process posts to itself, with assertions on what palmy's frame
// loop saw. Nothing is sent to other applications and nothing is read from
// the keyboard or the mouse: key and mouse events are synthesised NSEvents
// queued on this application, and the clipboard is a private named
// pasteboard (PALMY_MAC_PASTEBOARD) so the person's real clipboard is never
// read or overwritten.
//
//	odin build palmy/darwin/check -out:macos-check && ./macos-check
//
// It opens one window for about five seconds and closes it. Exit status is
// the number of failed assertions (0 is a pass).
package macos_check

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import "core:sys/posix"
import "core:thread"
import "core:time"
import p "../.."

msg :: intrinsics.objc_send

g_pass, g_fail: int

check :: proc(ok: bool, what: string, args: ..any) {
	if ok {
		g_pass += 1
	} else {
		g_fail += 1
		fmt.eprintfln("FAIL: %s", fmt.tprintf(what, ..args))
	}
}

Step :: enum {
	First,
	Geometry,
	Click_Button,
	Click_Field,
	Type,
	Scroll,
	Wake_Thread,
	Wake_After,
	Clipboard,
	Resize,
	Hide,
	Show,
	Close,
	Done,
}

State :: struct {
	step:        Step,
	step_frame:  int,
	frame:       int,
	clicks:      int,
	field:       [dynamic]u8,
	scrolled:    [2]f32,
	keys_seen:   [dynamic]u32,
	unshifted:   [dynamic]u32,
	waked_at:    time.Tick,
	wake_sent:   time.Tick,
	logic_seen:  int,
	presents_at: u64,
	t_step:      time.Tick,
}

win_of :: proc(app: ^p.App) -> ^NS.Window {
	return app.win.cocoa.window
}

// post queues an event on this application, as the window server would.
post :: proc(ev: ^NS.Event) {
	NS.Application_postEvent(NS.Application_sharedApplication(), ev, false)
}

mouse_event :: proc(app: ^p.App, type: NS.EventType, x, y: f64) -> ^NS.Event {
	w := win_of(app)
	b := NS.View_bounds(app.win.cocoa.view)
	loc := NS.Point{NS.Float(x), b.size.height - NS.Float(y)}
	return msg(
		^NS.Event,
		NS.Event,
		"mouseEventWithType:location:modifierFlags:timestamp:windowNumber:context:eventNumber:clickCount:pressure:",
		type,
		loc,
		NS.UInteger(0),
		NS.TimeInterval(0),
		msg(NS.Integer, w, "windowNumber"),
		NS.id(nil),
		NS.Integer(0),
		NS.Integer(1),
		f32(1),
	)
}

key_event :: proc(app: ^p.App, down: bool, chars, plain: string, code: u16, flags: NS.UInteger = 0) -> ^NS.Event {
	w := win_of(app)
	return msg(
		^NS.Event,
		NS.Event,
		"keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:",
		down ? NS.EventType.KeyDown : NS.EventType.KeyUp,
		NS.Point{},
		flags,
		NS.TimeInterval(0),
		msg(NS.Integer, w, "windowNumber"),
		NS.id(nil),
		ns(chars),
		ns(plain),
		NS.BOOL(false),
		code,
	)
}

ns :: proc(s: string) -> ^NS.String {
	str := NS.String_initWithOdinString(NS.String_alloc(), s)
	msg(^NS.String, str, "autorelease")
	return str
}

foreign import cg "system:CoreGraphics.framework"
foreign cg {
	CGEventCreateScrollWheelEvent2 :: proc "c" (source: rawptr, units: u32, count: u32, w1, w2, w3: i32) -> rawptr ---
	CFRelease :: proc "c" (obj: rawptr) ---
}

advance :: proc(s: ^State, to: Step) {
	s.step = to
	s.step_frame = s.frame
	s.t_step = time.tick_now()
}

main :: proc() {
	if os.get_env("PALMY_MAC_PASTEBOARD", context.temp_allocator) == "" {
		os.set_env("PALMY_MAC_PASTEBOARD", "org.palmy.macos-check")
	}
	app, err := p.create({title = "palmy macOS check", width = 420, height = 260})
	if err != "" {
		fmt.eprintfln("macos-check: %s", err)
		os.exit(1)
	}
	check(p.backend_name(app) == "cocoa", "backend is cocoa, got %s", p.backend_name(app))

	// Make the window key inside this application without activating it: the
	// posted key events reach it, and nothing the person types elsewhere does.
	msg(nil, win_of(app), "makeKeyWindow")

	s: State
	start := time.tick_now()
	for ui in p.frames(app) {
		s.frame += 1
		if time.tick_since(start) > 20 * time.Second {
			check(false, "timed out at step %v", s.step)
			break
		}

		// --- the UI under test: a button at the top, a field below it
		p.col(ui, "w-full h-full bg-slate-950 p-0 gap-0")
		if p.button(ui, "Click me", "w-[200] h-[40] rounded-none") {
			s.clicks += 1
		}
		p.text_field(ui, &s.field, "type here", "w-[300] h-[40]")
		// Changes every frame, so an animating frame is never skipped as
		// identical to the last one.
		p.textf(ui, "text-white", "frame %d", s.frame)
		p.end(ui)
		s.scrolled += ui.input.scroll
		for k in ui.input.keys {
			append(&s.keys_seen, k.sym)
			append(&s.unshifted, k.unshifted)
		}
		if app.logic {
			s.logic_seen += 1
		}

		in_step := s.frame - s.step_frame
		switch s.step {
		case .First:
			advance(&s, .Geometry)
			p.wake(app)

		case .Geometry:
			sc := p.window_scale(ui)
			sz := p.size(ui)
			b := app.win.buffers[0]
			check(sc >= 1, "scale %d", sc)
			check(sz == {420, 260}, "logical size %v", sz)
			check(b.w == 420 * sc && b.h == 260 * sc, "buffer %dx%d at scale %d", b.w, b.h, sc)
			advance(&s, .Click_Button)
			post(mouse_event(app, .LeftMouseDown, 100, 20))
			post(mouse_event(app, .LeftMouseUp, 100, 20))

		case .Click_Button:
			if s.clicks > 0 || time.tick_since(s.t_step) > time.Second {
				check(s.clicks == 1, "the posted click pressed the button once (%d)", s.clicks)
				advance(&s, .Click_Field)
				post(mouse_event(app, .LeftMouseDown, 100, 60))
				post(mouse_event(app, .LeftMouseUp, 100, 60))
			}

		case .Click_Field:
			if in_step >= 2 {
				advance(&s, .Type)
				clear(&s.keys_seen)
				clear(&s.unshifted)
				// h, i, Shift+1 (!), Return, Left
				post(key_event(app, true, "h", "h", 4))
				post(key_event(app, false, "h", "h", 4))
				post(key_event(app, true, "i", "i", 34))
				post(key_event(app, true, "!", "!", 18, 1 << 17))
				post(key_event(app, true, "\r", "\r", 0x24))
				post(key_event(app, true, "", "", 0x7b))
			}

		case .Type:
			if len(s.keys_seen) >= 5 || time.tick_since(s.t_step) > time.Second {
				text := string(s.field[:])
				check(text == "hi!", "typed text reached the field: %q", text)
				check(len(s.keys_seen) == 5, "five key events, got %d %x", len(s.keys_seen), s.keys_seen[:])
				if len(s.keys_seen) == 5 {
					check(s.keys_seen[0] == 'h' && s.keys_seen[1] == 'i', "letters are their keysyms: %x", s.keys_seen[:2])
					check(s.keys_seen[2] == '!', "Shift+1 is '!' (%x)", s.keys_seen[2])
					// The layout's own first level: '1' on US/ABC, '&' on French AZERTY.
					check(s.unshifted[2] != 0 && s.unshifted[2] != '!', "and its unshifted keysym is the layout's (%c)", rune(s.unshifted[2]))
					fmt.printfln("macos-check: the key with code 18 is %c unshifted in this layout", rune(s.unshifted[2]))
					check(s.keys_seen[3] == p.KEY_RETURN, "Return (%x)", s.keys_seen[3])
					check(s.keys_seen[4] == p.KEY_LEFT, "Left (%x)", s.keys_seen[4])
				}
				advance(&s, .Scroll)
				s.scrolled = {}
				// A scroll event carries the real pointer's screen position, so
				// it is handed to the view from the run loop (during palmy's
				// wait, where any event would arrive) rather than posted.
				ev := CGEventCreateScrollWheelEvent2(nil, 0, 2, -30, 0, 0) // pixels: 30 down
				nse := msg(^NS.Event, NS.Event, "eventWithCGEvent:", ev)
				msg(nil, (^NS.Object)(app.win.cocoa.view), "performSelector:withObject:afterDelay:", NS.sel_registerName("scrollWheel:"), nse, NS.TimeInterval(0))
				CFRelease(ev)
			}

		case .Scroll:
			if s.scrolled.y != 0 || time.tick_since(s.t_step) > time.Second {
				check(s.scrolled.y > 0, "content scrolled down 30px reads as positive y (%v)", s.scrolled)
				advance(&s, .Wake_Thread)
				// A worker wakes the idle loop 200 ms from now.
				s.wake_sent = time.tick_now()
				t := thread.create_and_start_with_poly_data2(app, &s, proc(app: ^p.App, s: ^State) {
					time.sleep(200 * time.Millisecond)
					s.waked_at = time.tick_now()
					p.wake(app)
				}, self_cleanup = true)
				_ = t
			}

		case .Wake_Thread:
			if s.waked_at != {} {
				lag := time.duration_milliseconds(time.tick_since(s.waked_at))
				idle := time.duration_milliseconds(time.tick_diff(s.wake_sent, s.waked_at))
				check(idle >= 150, "the loop slept until the wake (%.0f ms)", idle)
				check(lag < 50, "a wake from another thread ran a frame within %.1f ms", lag)
				fmt.printfln("macos-check: idle %.0f ms, then a cross-thread wake ran its frame %.2f ms later", idle, lag)
				advance(&s, .Wake_After)
				p.wake_after(app, 300 * time.Millisecond)
			}

		case .Wake_After:
			ms := time.duration_milliseconds(time.tick_since(s.t_step))
			if ms >= 250 {
				check(ms >= 295 && ms < 360, "wake_after(300 ms) fired after %.1f ms", ms)
				fmt.printfln("macos-check: wake_after(300 ms) ran its frame after %.1f ms", ms)
				advance(&s, .Clipboard)
				ok := p.clipboard_set(ui, "palmy ↔ macOS")
				check(ok, "clipboard_set on a named pasteboard")
				got, gok := p.clipboard_get(ui, context.temp_allocator)
				check(gok && got == "palmy ↔ macOS", "clipboard round trip: %q", got)
				pb := msg(^NS.Object, (^NS.Object)(NS.objc_lookUpClass("NSPasteboard")), "pasteboardWithName:", ns(os.get_env("PALMY_MAC_PASTEBOARD", context.temp_allocator)))
				raw := msg(^NS.String, pb, "stringForType:", ns("public.utf8-plain-text"))
				check(raw != nil && string(NS.String_UTF8String(raw)) == "palmy ↔ macOS", "NSPasteboard holds the text")
				check(p.clipboard_watch(app) == .Always, "the pasteboard can be watched")
				o, have := p.clipboard_next_offer(app)
				check(have && o.own && p.clipboard_offer_has(o, "text/plain;charset=utf-8"), "the current contents are the first offer, ours: %v", o)
				data, e := p.clipboard_offer_read(app, o, "text/plain;charset=utf-8", context.temp_allocator)
				check(e == .None && string(data) == "palmy ↔ macOS", "offer read %v %q", e, string(data))
				p.primary_set(ui, "primary")
				pr, _ := p.primary_get(ui, context.temp_allocator)
				check(pr == "primary", "primary selection, in process: %q", pr)
				p.clipboard_watch(app, {})
				msg(nil, pb, "clearContents")
			}

		case .Clipboard:
			advance(&s, .Resize)
			msg(nil, win_of(app), "setContentSize:", NS.Size{500, 300})

		case .Resize:
			if p.size(ui) == {500, 300} || time.tick_since(s.t_step) > time.Second {
				sc := p.window_scale(ui)
				check(p.size(ui) == {500, 300}, "resized to 500x300: %v", p.size(ui))
				b := app.win.buffers[0]
				check(b.w == 500 * sc && b.h == 300 * sc, "buffers follow: %dx%d", b.w, b.h)
				p.set_title(app, "palmy macOS check: retitled")
				t := msg(^NS.String, win_of(app), "title")
				check(string(NS.String_UTF8String(t)) == "palmy macOS check: retitled", "title set")
				advance(&s, .Hide)
				s.presents_at = 0
				NS.Window_orderOut(win_of(app), nil)
			}

		case .Hide:
			// Hidden: an animating window must not paint, but a due wake
			// still runs the application's code. AppKit reports the
			// occlusion change a little after orderOut, so the count starts
			// when it does.
			ui.animating = true
			if app.win.cocoa.visible {
				if time.tick_since(s.t_step) > 2 * time.Second {
					check(false, "orderOut never made the window not visible")
					advance(&s, .Show)
				}
				break
			}
			if s.presents_at == 0 {
				s.presents_at = p.frames_presented(app)
				s.logic_seen = 0
				s.t_step = time.tick_now()
			}
			ms := time.duration_milliseconds(time.tick_since(s.t_step))
			if ms < 600 {
				p.wake_after(app, 50 * time.Millisecond)
			} else {
				painted := p.frames_presented(app) - s.presents_at
				check(!app.win.cocoa.visible, "ordered out reads as not visible")
				check(painted <= 1, "a hidden animating window painted %d frames in 600 ms", painted)
				check(s.logic_seen >= 3, "due wakes ran %d logic frames while hidden", s.logic_seen)
				fmt.printfln("macos-check: hidden for 600 ms while animating: %d frames painted, %d logic frames", painted, s.logic_seen)
				advance(&s, .Show)
				s.presents_at = 0
				msg(nil, win_of(app), "orderFrontRegardless")
			}

		case .Show:
			ui.animating = true
			if !app.win.cocoa.visible {
				if time.tick_since(s.t_step) > 2 * time.Second {
					check(false, "orderFront never made the window visible")
					advance(&s, .Close)
					msg(nil, win_of(app), "performClose:", NS.id(nil))
				}
				break
			}
			if s.presents_at == 0 {
				s.presents_at = p.frames_presented(app)
				s.t_step = time.tick_now()
			}
			ms := time.duration_milliseconds(time.tick_since(s.t_step))
			if ms >= 500 {
				painted := p.frames_presented(app) - s.presents_at
				check(app.win.cocoa.visible, "shown again reads as visible")
				// ~60 or ~120 a second, paced by the screen, not unbounded.
				fps := f64(painted) / (ms / 1000)
				check(fps >= 20 && fps <= 130, "an animating visible window ran at %.0f fps", fps)
				fmt.printfln("macos-check: visible and animating: %.0f frames a second (screen interval %.2f ms)", fps, f64(app.win.cocoa.interval) / 1e6)
				advance(&s, .Close)
				msg(nil, win_of(app), "performClose:", NS.id(nil))
			}

		case .Close:
			if time.tick_since(s.t_step) > time.Second {
				check(false, "performClose: did not end the loop")
				advance(&s, .Done)
			}

		case .Done:
		}
		if s.step == .Done {
			break
		}
	}
	check(s.step == .Close || s.step == .Done, "the loop ended at step %v", s.step)
	check(app.win.should_close, "closing the window asked the app to close")

	fmt.printfln("macos-check: %d assertions, %d failed", g_pass + g_fail, g_fail)
	_ = strings.clone
	_ = posix.getpid
	p.destroy(app)
	os.exit(g_fail)
}
