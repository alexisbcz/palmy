// A headless collaborator: the same editor, binding and session as the
// window, with no window, driven by a script. It exists for demos and tests
// — "Bob" in a recording is this, running beside Alice's real window, so what
// the recording shows is two real instances of the app editing one document.
//
//	docs --collab <id> --as <handle> --script steps.txt
//
// Steps, one per line ('#' comments):
//
//	wait <seconds>            let the other side work
//	sync <seconds>            wait until nothing of ours is unacknowledged
//	find <text>               put the caret just after the first occurrence
//	start | end               the caret at the start / end of the document
//	para <n> [off]            the caret in paragraph n (0-based)
//	select <n chars>          extend the selection forward
//	type <text>               type, a character at a time (40/s), like a person
//	paste <text>              type all at once
//	enter | backspace | delete
//	bold | italic | heading <0-3> | bullet
//	comment <text>            comment on the selection
//	reply <text>              reply to the newest comment
//	suggest on|off            suggestion mode
//	accept | reject           decide the suggestion at the caret
//	offline | online          drop and restore the connection
//	undo | redo
//	quit
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."
import client "../../cloud/collab/client"

run_script :: proc(ca: Collab_Args, path: string, seed_file := "") -> int {
	raw, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintfln("docs: cannot read %s", path)
		return 1
	}
	fonts: p.Fonts
	headless_fonts(&fonts)
	layout_fonts = &fonts
	st := new(State)
	state_init(st, &fonts)
	if seed_file != "" {
		do_open(st, seed_file)
	}
	if e := collab_start(st, nil, ca); e != "" {
		fmt.eprintfln("docs: %s", e)
		return 1
	}
	relayout(st)
	// wait for the first sync, so positions mean what the script expects
	pump(st, 10, proc(st: ^State) -> bool {return st.collab.sess.status == .Live})

	for line in strings.split_lines(string(raw), context.allocator) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		verb := l
		arg := ""
		if i := strings.index_byte(l, ' '); i > 0 {
			verb = l[:i]
			// text keeps its leading spaces: "type  paying" types " paying"
			arg = verb == "type" || verb == "paste" ? l[i + 1:] : strings.trim_space(l[i + 1:])
		}
		fmt.printfln("[%s] %s", st.collab.handle, l)
		switch verb {
		case "wait":
			s, _ := strconv.parse_f64(arg)
			pump(st, s, nil)
		case "sync":
			s, _ := strconv.parse_f64(arg)
			pump(st, s == 0 ? 10 : s, proc(st: ^State) -> bool {
				return st.collab.sess.status == .Live && client.pending_count(st.collab.sess) == 0
			})
		case "find":
			for blk in doc_blocks(&st.doc) {
				pa := blk_para(&st.doc, blk)
				if pa == nil {continue}
				t := para_text(pa, context.temp_allocator)
				if i := strings.index(t, arg); i >= 0 {
					st.caret = blk_pos(blk, i + len(arg))
					st.anchor = st.caret
					break
				}
			}
		case "start":
			st.caret, st.anchor = pos(0, 0), pos(0, 0)
		case "end":
			st.caret = doc_end(&st.doc)
			st.anchor = st.caret
		case "para":
			parts := strings.fields(arg, context.temp_allocator)
			n, _ := strconv.parse_int(parts[0])
			off := 0
			if len(parts) > 1 {off, _ = strconv.parse_int(parts[1])}
			st.caret = pos_clamp(&st.doc, pos(n, off))
			st.anchor = st.caret
		case "select":
			n, _ := strconv.parse_int(arg)
			for _ in 0 ..< n {move_h(st, 1, true)}
		case "type":
			for r in arg {
				buf: [4]u8
				s := encode_rune(buf[:], r)
				type_text(st, s)
				step(st)
				pump(st, 0.025, nil)
			}
		case "paste":
			type_text(st, arg)
		case "enter":
			split_line(st)
		case "backspace":
			backspace(st)
		case "delete":
			delete_forward(st)
		case "bold":
			toggle_bold(st)
		case "italic":
			toggle_italic(st)
		case "heading":
			n, _ := strconv.parse_int(arg)
			set_kind(st, Para_Kind(clamp(n, 0, 3)))
		case "bullet":
			set_list(st, .Bullet)
		case "comment":
			collab_comment(st, arg)
		case "reply":
			if n := len(st.collab.comments); n > 0 {
				collab_reply(st, st.collab.comments[n - 1].id, arg)
			}
		case "suggest":
			st.collab.suggest = arg == "on"
		case "accept":
			collab_decide(st, true)
		case "reject":
			collab_decide(st, false)
		case "offline":
			client.go_offline(st.collab.sess)
		case "online":
			client.reconnect(st.collab.sess)
		case "undo":
			do_undo(st)
		case "redo":
			do_redo(st)
		case "quit":
			step(st)
			pump(st, 3, proc(st: ^State) -> bool {return client.pending_count(st.collab.sess) == 0})
			state_destroy(st)
			return 0
		case:
			fmt.eprintfln("docs: unknown script step %q", l)
		}
		step(st)
	}
	pump(st, 3, proc(st: ^State) -> bool {return client.pending_count(st.collab.sess) == 0})
	state_destroy(st)
	return 0
}

encode_rune :: proc(buf: []u8, r: rune) -> string {
	b := strings.builder_from_bytes(buf)
	strings.write_rune(&b, r)
	return strings.to_string(b)
}

// step is one frame of the window's loop, without the window.
step :: proc(st: ^State) {
	collab_tick(nil, st)
	if st.dirty {
		relayout(st)
		st.dirty = false
	}
	free_all(context.temp_allocator)
}

pump :: proc(st: ^State, seconds: f64, until: proc(st: ^State) -> bool) {
	start := time.tick_now()
	for time.duration_seconds(time.tick_since(start)) < seconds {
		step(st)
		if until != nil && until(st) {
			return
		}
		time.sleep(15 * time.Millisecond)
	}
}
