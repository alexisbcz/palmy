// A headless collaborator for demos and tests: the same workbook, binding and
// session as the window, driven by a script.
//
//	sheets --collab <id> --as <handle> --script steps.txt
//
//	wait <s> | sync <s>        let time pass / wait for acknowledgement
//	goto <A1>                  the cursor
//	set <text>                 type into the cursor's cell and commit
//	insert-row | delete-row | insert-col | delete-col   at the cursor
//	bold
//	comment <text>
//	sheet <n>                  switch to sheet n (0-based)
//	offline | online | undo | redo | quit
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."
import sc "shadcn:."
import client "../../cloud/collab/client"
import collabui "../../cloud/collab/ui"

run_script :: proc(app: ^App, win: ^p.App, ca: collabui.Args) -> int {
	raw, err := os.read_entire_file_from_path(ca.script, context.allocator)
	if err != nil {
		fmt.eprintfln("sheets: cannot read %s", ca.script)
		return 1
	}
	a := ca
	a.script = ""
	if e := collab_start(app, nil, a); e != "" {
		fmt.eprintfln("sheets: %s", e)
		return 1
	}
	spin(app, 10, proc(app: ^App) -> bool {return collab.ui.sess.status == .Live})
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
			spin(app, s, nil)
		case "sync":
			s, _ := strconv.parse_f64(arg)
			spin(app, s == 0 ? 10 : s, proc(app: ^App) -> bool {
				return collab.ui.sess.status == .Live && client.pending_count(collab.ui.sess) == 0
			})
		case "goto":
			if r, ok := ref_parse(strings.trim_space(arg)); ok && r.row != NO_ROW && r.col != NO_COL {
				app.cur = {r.row, r.col}
				app.anchor = app.cur
			}
		case "set":
			line_set(&app.edit, arg)
			commit_edit(app, 0, 0)
		case "insert-row":
			run_cmd(app, .Insert_Row)
		case "delete-row":
			run_cmd(app, .Delete_Row)
		case "insert-col":
			run_cmd(app, .Insert_Col)
		case "delete-col":
			run_cmd(app, .Delete_Col)
		case "bold":
			run_cmd(app, .Bold)
		case "comment":
			collab_comment(app, arg)
		case "sheet":
			n, _ := strconv.parse_int(strings.trim_space(arg))
			use_sheet(app, n)
		case "offline":
			client.go_offline(collab.ui.sess)
		case "online":
			client.reconnect(collab.ui.sess)
		case "undo":
			do_undo(app)
		case "redo":
			do_redo(app)
		case "shot":
			parts := strings.fields(arg, context.temp_allocator)
			if len(parts) > 0 {
				collab_shot(app, parts[0], len(parts) > 1 && parts[1] == "dark")
			}
		case "panel":
			switch strings.trim_space(arg) {
			case "comments":
				collab.ui.panel = .Comments
				collab_refresh_comments(app)
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
			spin(app, 3, proc(app: ^App) -> bool {return client.pending_count(collab.ui.sess) == 0})
			collabui.destroy(&collab.ui)
			return 0
		case:
			fmt.eprintfln("sheets: unknown script step %q", l)
		}
		spin(app, 0.02, nil)
	}
	spin(app, 3, proc(app: ^App) -> bool {return client.pending_count(collab.ui.sess) == 0})
	collabui.destroy(&collab.ui)
	return 0
}

collab_shot :: proc(app: ^App, path: string, dark: bool) {
	off := p.offscreen_create(1440, 900, 1, "w-full h-full bg-background text-foreground")
	defer p.offscreen_destroy(off)
	load_sans(&off.fonts)
	load_italics(&off.fonts)
	sc.register_shadcn_theme(dark)
	p.set_text_gamma(1.8)
	saved_fonts := app.fonts
	app.fonts = &off.fonts
	app.pal = palette_build()
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		measure_viewport(app, p.size(ui))
		frame(ui, app)
		p.offscreen_end(off)
	}
	app.fonts = saved_fonts
	if p.offscreen_write_png(off, path) {
		fmt.printfln("  wrote %s", path)
	}
}

spin :: proc(app: ^App, seconds: f64, until: proc(app: ^App) -> bool) {
	start := time.tick_now()
	for {
		collab_tick(nil, app)
		free_all(context.temp_allocator)
		if until != nil && until(app) {return}
		if time.duration_seconds(time.tick_since(start)) >= seconds {return}
		time.sleep(15 * time.Millisecond)
	}
}
