// A headless collaborator for demos and tests: the same deck, binding and
// session as the window, driven by a script.
//
//	slides --collab <id> --as <handle> --script steps.txt
//
//	wait <s> | sync <s>
//	slide <n>               go to slide n (0-based)
//	select <n>              select element n on the slide
//	move <dx> <dy>          move the selected element, in slide units
//	text <text>             replace the selected element's text, typed out
//	fill                    step the selected element's fill to the next theme colour
//	new-slide               add a slide after this one
//	offline | online | undo | redo | quit
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."
import client "../../cloud/collab/client"
import collabui "../../cloud/collab/ui"

run_script :: proc(st: ^St, ca: collabui.Args) -> int {
	raw, err := os.read_entire_file_from_path(ca.script, context.allocator)
	if err != nil {
		fmt.eprintfln("slides: cannot read %s", ca.script)
		return 1
	}
	a := ca
	a.script = ""
	if e := collab_start(st, nil, a); e != "" {
		fmt.eprintfln("slides: %s", e)
		return 1
	}
	spin(st, 10, proc(st: ^St) -> bool {return collab.ui.sess.status == .Live})
	for line in strings.split_lines(string(raw), context.allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		verb, arg := l, ""
		if i := strings.index_byte(l, ' '); i > 0 {
			verb = l[:i]
			arg = l[i + 1:]
		}
		fmt.printfln("[%s] %s", collab.ui.handle, l)
		switch verb {
		case "wait":
			s, _ := strconv.parse_f64(arg)
			spin(st, s, nil)
		case "sync":
			s, _ := strconv.parse_f64(arg)
			spin(st, s == 0 ? 10 : s, proc(st: ^St) -> bool {
				return collab.ui.sess.status == .Live && client.pending_count(collab.ui.sess) == 0
			})
		case "slide":
			n, _ := strconv.parse_int(strings.trim_space(arg))
			st.slide = clamp(n, 0, len(st.deck.slides) - 1)
			st.sel = -1
		case "select":
			n, _ := strconv.parse_int(strings.trim_space(arg))
			st.sel = clamp(n, -1, len(cur_slide(st).elems) - 1)
		case "move":
			parts := strings.fields(arg, context.temp_allocator)
			if e := cur_elem(st); e != nil && len(parts) == 2 {
				dx, _ := strconv.parse_f32(parts[0])
				dy, _ := strconv.parse_f32(parts[1])
				steps := 12
				for _ in 0 ..< steps {
					push_history(st, nil)
					e.x += dx / f32(steps)
					e.y += dy / f32(steps)
					spin(st, 0.04, nil)
				}
			}
		case "text":
			if e := cur_elem(st); e != nil {
				push_history(st, nil)
				e.text = ""
				for i in 0 ..< len(arg) {
					push_history(st, nil)
					e.text = strings.clone(arg[:i + 1])
					spin(st, 0.03, nil)
				}
			}
		case "fill":
			if e := cur_elem(st); e != nil {
				push_history(st, nil)
				e.fill = next_paint(e.fill, 1)
			}
		case "peers":
			// what this replica sees of everyone else, for tests and debugging
			for &peer in collab.ui.sess.peers {
				fmt.printfln("  peer %s state=%s", peer.identity.handle, client.jstr(peer.state, "s"))
			}
			for pm in peer_marks(st) {
				fmt.printfln("  mark %s slide=%d elem=%d typing=%v", pm.name, pm.slide, pm.elem, pm.typing)
			}
		case "new-slide":
			push_history(st, nil)
			st.slide = slide_add(&st.deck, st.slide + 1, .Title_Content)
		case "offline":
			client.go_offline(collab.ui.sess)
		case "online":
			client.reconnect(collab.ui.sess)
		case "undo":
			collab_undo(st, false)
		case "redo":
			collab_undo(st, true)
		case "shot":
			parts := strings.fields(arg, context.temp_allocator)
			if len(parts) > 0 {
				collab_shot(st, parts[0])
			}
		case "panel":
			switch strings.trim_space(arg) {
			case "history":
				collab.ui.panel = .History
				collabui.load_history(&collab.ui)
			case "share":
				collab.ui.panel = .Share
				collabui.load_people(&collab.ui)
			case:
				collab.ui.panel = .None
			}
		case "quit":
			spin(st, 3, proc(st: ^St) -> bool {return client.pending_count(collab.ui.sess) == 0})
			collabui.destroy(&collab.ui)
			return 0
		case:
			fmt.eprintfln("slides: unknown script step %q", l)
		}
		spin(st, 0.02, nil)
	}
	spin(st, 3, proc(st: ^St) -> bool {return client.pending_count(collab.ui.sess) == 0})
	collabui.destroy(&collab.ui)
	return 0
}

collab_shot :: proc(st: ^St, path: string) {
	off := p.offscreen_create(1440, 900, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(&off.fonts)
	register_chrome_theme()
	p.set_text_gamma(1.8)
	if st.exe_dir == "" {st.exe_dir = exe_directory()}
	if st.imgs.m == nil {
		root := st.exe_dir
		if !os.exists(fmt.tprintf("%s/assets/vista.png", root)) {root = #directory}
		st.imgs = img_cache_make(root)
	}
	if st.guides == nil {st.guides = make([dynamic]Guide)}
	for i in 0 ..< MAX_THUMBS {st.thumbs[i] = {st, i}}
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		st.fonts = ui.fonts
		clamp_state(st)
		build(ui, st)
		p.offscreen_end(off)
	}
	if p.offscreen_write_png(off, path) {
		fmt.printfln("  wrote %s", path)
	}
}

spin :: proc(st: ^St, seconds: f64, until: proc(st: ^St) -> bool) {
	start := time.tick_now()
	for {
		collab_tick(nil, st)
		free_all(context.temp_allocator)
		if until != nil && until(st) {return}
		if time.duration_seconds(time.tick_since(start)) >= seconds {return}
		time.sleep(15 * time.Millisecond)
	}
}
