package main

// ai — the assistant: one per identity, confined to it.
//
// The window and the command line are two front ends over the same code
// (assist.odin). Picking an identity on the left picks whose assistant you
// are talking to; "All identities" has no assistant and says so. A request
// runs on a worker thread: assist() mints or reuses the identity's delegated
// session, starts the sandboxed `ai agent`, brokers its model calls and
// streams its events back here, where each one becomes a line of the
// transcript — the tool it called, what came back, what it drafted, and
// every proposal as a card you confirm or decline.
//
// The shape of the program:
//
//   main.odin       state, the frame loop, keys, loading and actions
//   ui.odin         the frame
//   assist.odin     the person's side: scope check, delegation, the child, confirmations
//   agent.odin      the child: `ai agent`, confined, running the engine
//   cli.odin        `ai <verb>` on the kit convention
//   md.odin         markdown rendering (links shown with their address, never fetched)
//   ollama.odin     the runtime probe: which local models exist
//   selftest.odin   `ai --selftest`
//   shot.odin       `ai --shots <dir>`: the window offscreen, from a fixture

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import ck "../cloudkit"
import en "../../cloud/assistant/engine"
import kit "kit:."
import p "palmy:."

WIN_W :: 1320
WIN_H :: 840
SIDEBAR_W :: 268
TOPBAR_H :: 56
FOOTER_H :: 30

secs :: proc(s: f64) -> time.Duration {
	return time.Duration(max(s, 0) * f64(time.Second))
}

View :: enum u8 {
	Chat,
	Log,
	Settings,
}

Item_Kind :: enum u8 {
	User,
	Step, // a tool call, and once it is back, its result
	Refused,
	Draft,
	Proposal,
	Answer,
	Notice, // the scope check's refusal, and other things the runtime says
	Error,
}

Warn :: struct {
	level, text: string,
}

Item :: struct {
	kind:      Item_Kind,
	tool:      string,
	class:     string, // read | draft | confirm
	text:      string, // what is shown: the arguments, the answer, the summary
	result:    string, // a step's outcome, one line
	data:      string, // a step's raw result (JSON), for the expanded view
	done:      bool, // a step has its result
	ok:        bool,
	untrusted: bool,
	open:      bool, // expanded
	action_id: string,
	status:    string, // a proposal's: proposed | executed | declined | failed
	warnings:  [dynamic]Warn,
	sources:   string,
}

Ident_View :: struct {
	id, handle, name, kind, color: string,
	enabled:                       bool,
	model, provider, remote_model: string,
	opted_in_at:                   string,
	pending:                       int,
	address:                       string,
}

Conv_View :: struct {
	id, title, updated: string,
}

Log_Row :: struct {
	id, tool, class, status, summary, created: string,
	tainted:                                   bool,
	warnings:                                  [dynamic]Warn,
}

// Shared is what the worker running a request and the frame both touch.
Shared :: struct {
	mu:      sync.Mutex,
	lines:   [dynamic]string, // events not yet taken by the frame
	running: bool,
	cancel:  bool,
	out:     Outcome,
	done:    bool,
}

St :: struct {
	person:       Person,
	online:       bool,
	offline:      string, // why not, for the empty state
	idents:       [dynamic]Ident_View,
	sel:          int, // -1: All identities
	convs:        [dynamic]Conv_View,
	conv:         string,
	items:        [dynamic]Item,
	log:          [dynamic]Log_Row,
	view:         View,
	input:        [dynamic]u8,
	caret:        int,
	sh:           ^Shared,
	worker:       ^thread.Thread,
	queued:       string, // asked while another request was running; sent when it ends
	queued_new:   bool, // and in a new conversation
	probe:        Probe,
	last_probe:   f64,
	sandbox:      string, // "Landlock 10 · 2 ports · seccomp", from the last run
	toast:        string,
	toast_t:      f64,
	pinned:       bool,
	tr_id:        u64,
	end_id:       u64,
	composer_id:  u64,
	footer_id:    u64,
	main_id:      u64,
	fixture:      bool, // a screenshot: no network, no worker
	remote_ask:   bool, // the opt-in dialog is up
	started_at:   f64,
}

main :: proc() {
	args := os.args[1:]
	// The assistant's own process, started by `ai ask` or the window: not a
	// verb for people, so not in the declared surface.
	if len(args) > 0 && args[0] == "agent" {
		os.exit(agent_main(args[1:]))
	}
	if len(args) > 0 && args[0] == "agent-tool" {
		os.exit(agent_tool_main(args[1:]))
	}
	if len(args) > 0 && args[0] == "sandbox-probe" {
		os.exit(sandbox_probe_main(args[1:]))
	}
	for a, i in args {
		// `ai --shots <dir>` renders the window offscreen from a fixture. See
		// shot.odin: it opens no socket and reads nothing of the person's.
		if a == "--shots" || a == "-shots" {
			if i + 1 >= len(args) {
				fmt.eprintln("ai: --shots needs a directory")
				os.exit(2)
			}
			os.exit(shots(args[i + 1]))
		}
	}
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	dark := os.get_env("PALM_THEME", context.temp_allocator) != "light"
	app, err := kit.start(
		{
			title = "Assistant",
			app_id = "palmy",
			width = WIN_W,
			height = WIN_H,
			min_width = 980,
			min_height = 600,
			root_class = "w-full h-full flex-row bg-background text-foreground overflow-hidden",
		},
		dark,
	)
	if err != "" {
		fmt.eprintfln("ai: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)
	WAKE = app

	st := new(St)
	st_init(st)
	probe_init(&st.probe)
	probe_refresh(&st.probe)
	st.last_probe = mono()
	reload_people(st)

	for ui in p.frames(app) {
		free_all(context.temp_allocator)
		drain(st)
		if mono() - st.last_probe > 10 {
			st.last_probe = mono()
			probe_refresh(&st.probe)
		}
		handle_keys(ui, app, st)
		build(ui, st)
		if st.sh.running {
			// The spinner and the elapsed time are clocks; ask for the frames
			// that run them, four a second, only while a request is out.
			p.wake_after(ui, 250 * time.Millisecond)
		}
		if st.toast != "" {
			if mono() > st.toast_t {st.toast = ""} else {p.wake_after(ui, secs(st.toast_t - mono()))}
		}
	}
	if st.sh.running {
		sync.atomic_store(&st.sh.cancel, true)
		for _ in 0 ..< 25 {
			if !st.sh.running {break}
			time.sleep(20 * time.Millisecond)
		}
	}
}

st_init :: proc(st: ^St) {
	st.idents = make([dynamic]Ident_View)
	st.convs = make([dynamic]Conv_View)
	st.items = make([dynamic]Item)
	st.log = make([dynamic]Log_Row)
	st.input = make([dynamic]u8)
	st.sh = new(Shared)
	st.sh.lines = make([dynamic]string)
	st.sel = -1
	st.pinned = true
}

toast :: proc(st: ^St, msg: string) {
	st.toast = msg
	st.toast_t = mono() + 3.5
}

cur_ident :: proc(st: ^St) -> ^Ident_View {
	if st.sel < 0 || st.sel >= len(st.idents) {return nil}
	return &st.idents[st.sel]
}

// ---------------------------------------------------------------------------
// Loading
//
// Everything below talks to the local cloud gateway on loopback, synchronously
// from the frame: each is one or two small requests. The request itself — the
// model and the tools, seconds long — runs on the worker.
// ---------------------------------------------------------------------------

reload_people :: proc(st: ^St) {
	clear(&st.idents)
	pp, err := person_open()
	st.person = pp
	if err != "" {
		st.online = false
		st.offline = strings.clone(err)
		return
	}
	st.online = true
	for i in pp.identities {
		if i.archived {continue}
		v := Ident_View {
			id = strings.clone(i.id), handle = strings.clone(i.handle), name = strings.clone(i.display_name),
			kind = strings.clone(i.kind), color = strings.clone(i.color),
		}
		if mc, merr := machine_session(&st.person, i); merr == "" {
			s, _ := settings_get(mc, i)
			v.enabled = s.enabled
			v.model = strings.clone(s.model)
			v.provider = strings.clone(s.provider)
			v.remote_model = strings.clone(s.remote_model)
			v.opted_in_at = strings.clone(s.opted_in_at)
			pend, _ := actions_list(mc, i, true, 100)
			v.pending = len(pend)
		}
		append(&st.idents, v)
	}
	// Start where the person last was, if that is an identity; otherwise in
	// All identities, which asks them to choose.
	cur := ck.current_identity(st.person.c, context.temp_allocator)
	for v, k in st.idents {
		if v.handle == cur {st.sel = k}
	}
	select_identity(st, st.sel)
}

ident_of :: proc(st: ^St, v: ^Ident_View) -> (ck.Identity, bool) {
	return find_ident(&st.person, v.handle)
}

select_identity :: proc(st: ^St, k: int) {
	if st.sh.running {
		toast(st, "Wait for the assistant to finish, or press Esc to stop it")
		return
	}
	st.sel = k
	clear(&st.convs)
	clear(&st.items)
	clear(&st.log)
	st.conv = ""
	v := cur_ident(st)
	if v == nil || st.fixture {return}
	_ = ck.set_current_identity(st.person.c, v.handle)
	load_convs(st)
	if len(st.convs) > 0 {open_conv(st, st.convs[0].id)}
	if st.view == .Log {load_log(st)}
}

load_convs :: proc(st: ^St) {
	clear(&st.convs)
	v := cur_ident(st)
	if v == nil || st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	rows, e := ck.select(mc, "assistant_conversations", fmt.tprintf("select=id,title,updated_at&identity_id=eq.%s&order=updated_at.desc&limit=60", v.id), context.temp_allocator)
	if !ck.ok(e) {return}
	for r in ck.array(rows) {
		append(&st.convs, Conv_View{strings.clone(ck.get_str(r, "id")), strings.clone(ck.get_str(r, "title")), strings.clone(ck.get_str(r, "updated_at"))})
	}
}

warns_from :: proc(v: ck.Value) -> [dynamic]Warn {
	out := make([dynamic]Warn)
	for w in ck.array(v) {
		append(&out, Warn{strings.clone(ck.get_str(w, "level")), strings.clone(ck.get_str(w, "text"))})
	}
	return out
}

// open_conv rebuilds a transcript from the stored messages, and the cards'
// current state from the action log, so a proposal confirmed from the CLI
// shows as done here.
open_conv :: proc(st: ^St, id: string) {
	clear(&st.items)
	st.conv = strings.clone(id)
	v := cur_ident(st)
	if v == nil {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	rows, e := ck.select(mc, "assistant_messages", fmt.tprintf("select=role,content,tool,tainted&conversation_id=eq.%s&order=seq", id), context.temp_allocator)
	if !ck.ok(e) {return}
	acts, _ := actions_list(mc, i, false, 200, id)
	for r in ck.array(rows) {
		switch ck.get_str(r, "role") {
		case "user":
			append(&st.items, Item{kind = .User, text = strings.clone(ck.get_str(r, "content"))})
		case "assistant":
			append(&st.items, Item{kind = .Answer, text = strings.clone(ck.get_str(r, "content"))})
		case "notice":
			append(&st.items, Item{kind = .Notice, text = strings.clone(ck.get_str(r, "content"))})
		case "tool":
			tv := ck.get(r, "tool")
			add_event(st, tv, acts)
		}
	}
	st.pinned = true
}

load_log :: proc(st: ^St) {
	clear(&st.log)
	v := cur_ident(st)
	if v == nil || st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	acts, _ := actions_list(mc, i, false, 200)
	for a in acts {
		append(&st.log, Log_Row{
			id = strings.clone(a.id), tool = strings.clone(a.tool), class = strings.clone(a.class),
			status = strings.clone(a.status), summary = strings.clone(a.summary), created = strings.clone(a.created),
			tainted = a.tainted, warnings = warns_from(a.warnings),
		})
	}
	v.pending = 0
	for r in st.log {if r.status == "proposed" {v.pending += 1}}
}

// ---------------------------------------------------------------------------
// Events to transcript items
// ---------------------------------------------------------------------------

add_event :: proc(st: ^St, v: ck.Value, acts: []Action = nil) {
	t := ck.get_str(v, "t")
	switch t {
	case "sandbox":
		if ck.get_bool(v, "ok") {
			st.sandbox = fmt.aprintf("Landlock %d · %d ports · seccomp", ck.get_int(v, "landlock_abi"), len(ck.array(ck.get(v, "ports"))))
		} else {
			append(&st.items, Item{kind = .Error, text = fmt.aprintf("The sandbox could not be applied, so the assistant did not run: %s", ck.get_str(v, "error"))})
		}
	case "step":
		append(&st.items, Item{kind = .Step, tool = strings.clone(ck.get_str(v, "tool")), class = strings.clone(ck.get_str(v, "class")),
			text = strings.clone(ck.get_str(v, "shown"))})
	case "result", "draft":
		// Back on the step that asked for it.
		tool := ck.get_str(v, "tool")
		for k := len(st.items) - 1; k >= 0; k -= 1 {
			it := &st.items[k]
			if it.kind == .Step && it.tool == tool && !it.done {
				it.done = true
				it.ok = ck.get_bool(v, "ok")
				it.result = strings.clone(ck.get_str(v, "summary"))
				it.untrusted = ck.get_bool(v, "untrusted")
				if d := ck.get(v, "data"); d != nil {it.data = pretty(d)}
				if t == "draft" {it.class = "draft"}
				return
			}
		}
		append(&st.items, Item{kind = t == "draft" ? .Draft : .Step, tool = strings.clone(tool), done = true,
			ok = ck.get_bool(v, "ok"), result = strings.clone(ck.get_str(v, "summary")), class = t == "draft" ? "draft" : "read"})
	case "refused":
		append(&st.items, Item{kind = .Refused, tool = strings.clone(ck.get_str(v, "tool")), text = strings.clone(ck.get_str(v, "why"))})
	case "proposal":
		id := ck.get_str(v, "action_id")
		status := "proposed"
		for a in acts {if a.id == id {status = a.status}}
		it := Item{kind = .Proposal, tool = strings.clone(ck.get_str(v, "tool")), text = strings.clone(ck.get_str(v, "summary")),
			action_id = strings.clone(id), status = strings.clone(status), warnings = warns_from(ck.get(v, "warnings"))}
		srcs := make([dynamic]string, context.temp_allocator)
		for s in ck.array(ck.get(v, "sources")) {append(&srcs, ck.get_str(s, "label"))}
		it.sources = strings.join(srcs[:], "; ")
		append(&st.items, it)
	case "answer":
		append(&st.items, Item{kind = .Answer, text = strings.clone(ck.get_str(v, "text"))})
	case "error":
		append(&st.items, Item{kind = .Error, text = strings.clone(ck.get_str(v, "message"))})
	}
}

pretty :: proc(v: ck.Value) -> string {
	return en.value_text(v, 4000, context.allocator)
}

// ---------------------------------------------------------------------------
// Asking
// ---------------------------------------------------------------------------

Job_Args :: struct {
	st:      ^St,
	handle:  string,
	request: string,
	conv:    string,
}

@(private = "file")
sink :: proc(data: rawptr, line: string, v: ck.Value) {
	sh := cast(^Shared)data
	sync.mutex_lock(&sh.mu)
	append(&sh.lines, strings.clone(line))
	sync.mutex_unlock(&sh.mu)
	wake_ui()
}

@(private = "file")
job :: proc(t: ^thread.Thread) {
	a := cast(^Job_Args)t.data
	st := a.st
	out := assist(&st.person, Ask{
		handle = a.handle, request = a.request, conversation_id = a.conv,
		sink = sink, sink_data = st.sh, cancel = &st.sh.cancel,
	})
	sync.mutex_lock(&st.sh.mu)
	st.sh.out = out
	st.sh.done = true
	sync.mutex_unlock(&st.sh.mu)
	sync.atomic_store(&st.sh.running, false)
	wake_ui()
}

send :: proc(st: ^St) {
	if st.sh.running {return}
	v := cur_ident(st)
	if v == nil {
		toast(st, "Choose an identity first: the assistant works inside one")
		return
	}
	text := strings.trim_space(string(st.input[:]))
	if text == "" {return}
	if !v.enabled {
		toast(st, fmt.tprintf("The %s assistant is off — turn it on in Settings", v.name))
		return
	}
	append(&st.items, Item{kind = .User, text = strings.clone(text)})
	clear(&st.input)
	st.caret = 0
	st.pinned = true
	st.started_at = mono()
	st.sh.done = false
	st.sh.cancel = false
	sync.atomic_store(&st.sh.running, true)
	a := new(Job_Args)
	a^ = {st = st, handle = strings.clone(v.handle), request = strings.clone(text), conv = strings.clone(st.conv)}
	if st.worker != nil {
		thread.join(st.worker)
		thread.destroy(st.worker)
	}
	st.worker = thread.create(job)
	st.worker.data = a
	thread.start(st.worker)
}

// drain takes the worker's events into the transcript, and when the request
// is over, the outcome: the conversation it was filed under, and the scope
// check's refusal when that is what answered.
drain :: proc(st: ^St) {
	sync.mutex_lock(&st.sh.mu)
	lines := st.sh.lines[:]
	taken := make([]string, len(lines), context.temp_allocator)
	copy(taken, lines)
	clear(&st.sh.lines)
	done := st.sh.done
	out := st.sh.out
	if done {st.sh.done = false}
	sync.mutex_unlock(&st.sh.mu)
	for l in taken {
		v, ok := ck.parse(l, context.temp_allocator)
		if ok {add_event(st, v)}
		delete(l)
	}
	if done {
		if out.refused {
			append(&st.items, Item{kind = .Notice, text = strings.clone(out.refusal)})
		} else if out.error != "" && out.answer == "" {
			append(&st.items, Item{kind = .Error, text = strings.clone(out.error)})
		}
		if out.conversation_id != "" && out.conversation_id != st.conv {
			st.conv = strings.clone(out.conversation_id)
		}
		load_convs(st)
		if v := cur_ident(st); v != nil {
			v.pending += len(out.proposals)
		}
		if st.queued_new {
			st.queued_new = false
			new_conversation(st)
		}
		if st.queued != "" && !st.sh.running {
			q := st.queued
			st.queued = ""
			clear(&st.input)
			append(&st.input, ..transmute([]u8)q)
			st.caret = len(st.input)
			send(st)
		}
	}
}

stop :: proc(st: ^St) {
	if st.sh.running {
		sync.atomic_store(&st.sh.cancel, true)
		toast(st, "Stopping…")
	}
}

new_conversation :: proc(st: ^St) {
	if st.sh.running {
		st.queued_new = true
		return
	}
	st.conv = ""
	clear(&st.items)
	st.view = .Chat
}

// decide_action is the card's Confirm or Decline: the person's own session,
// through the same code `ai confirm` uses.
decide_action :: proc(st: ^St, id: string, yes: bool) {
	v := cur_ident(st)
	if v == nil {return}
	if st.fixture {
		for &it in st.items {if it.action_id == id {it.status = yes ? "executed" : "declined"}}
		return
	}
	status := ""
	if yes {
		_, err := confirm(&st.person, v.handle, id)
		status = err == "" ? "executed" : "failed"
		toast(st, err == "" ? "Done, as you" : err)
	} else {
		err := decline(&st.person, v.handle, id)
		status = err == "" ? "declined" : "proposed"
		toast(st, err == "" ? "Declined; nothing was done" : err)
	}
	for &it in st.items {if it.action_id == id {it.status = strings.clone(status)}}
	if st.view == .Log {load_log(st)}
	v.pending = max(0, v.pending - 1)
}

set_enabled :: proc(st: ^St, on: bool) {
	v := cur_ident(st)
	if v == nil {return}
	v.enabled = on
	if st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	s, _ := settings_get(mc, i)
	s.enabled = on
	if e := settings_put(mc, i, s); e != "" {toast(st, e)}
}

set_model :: proc(st: ^St, model: string) {
	v := cur_ident(st)
	if v == nil {return}
	v.model = strings.clone(model)
	if st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	s, _ := settings_get(mc, i)
	s.model = strings.clone(model)
	if e := settings_put(mc, i, s); e != "" {toast(st, e)} else {toast(st, fmt.tprintf("%s now answers for %s", model, v.name))}
}

set_remote :: proc(st: ^St, on: bool) {
	v := cur_ident(st)
	if v == nil {return}
	v.provider = on ? "anthropic" : "local"
	v.remote_model = on ? REMOTE_MODEL_DEFAULT : ""
	v.opted_in_at = on ? now_iso() : ""
	if st.fixture {return}
	i, _ := ident_of(st, v)
	mc, err := machine_session(&st.person, i)
	if err != "" {return}
	s, _ := settings_get(mc, i)
	s.provider = v.provider
	s.remote_model = v.remote_model
	s.opted_in_at = v.opted_in_at
	if e := settings_put(mc, i, s); e != "" {toast(st, e)}
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

handle_keys :: proc(ui: ^p.Ctx, app: ^p.App, st: ^St) {
	if st.remote_ask {
		if p.key_pressed(ui, p.KEY_ESCAPE) {st.remote_ask = false}
		return
	}
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
		return
	}
	if p.key_pressed(ui, p.KEY_ESCAPE) {
		stop(st)
		return
	}
	// Ctrl+0 is All identities; Ctrl+1..9 an identity, as in the shell.
	for d in 0 ..= 9 {
		if p.shortcut(ui, u32('0' + d), {.Ctrl}) {
			k := d - 1
			if k < len(st.idents) {select_identity(st, k)}
			return
		}
	}
	// Function keys duplicate the Ctrl bindings for the recorder, which
	// cannot hold a modifier.
	if p.shortcut(ui, 'n', {.Ctrl}) || p.key_pressed(ui, p.KEY_F2) {
		new_conversation(st)
		return
	}
	if p.shortcut(ui, 'l', {.Ctrl}) || p.key_pressed(ui, p.KEY_F3) {
		st.view = st.view == .Log ? .Chat : .Log
		if st.view == .Log {load_log(st)}
		return
	}
	if p.shortcut(ui, ',', {.Ctrl}) || p.key_pressed(ui, p.KEY_F4) {
		st.view = st.view == .Settings ? .Chat : .Settings
		return
	}
	if p.key_pressed(ui, p.KEY_F5) {
		// Next identity, wrapping through All identities.
		select_identity(st, st.sel + 1 >= len(st.idents) ? -1 : st.sel + 1)
		return
	}
	if p.key_pressed(ui, p.KEY_F6) {
		// Confirm the newest waiting proposal: the recorder's way to press
		// the card's button.
		for k := len(st.items) - 1; k >= 0; k -= 1 {
			if st.items[k].kind == .Proposal && st.items[k].status == "proposed" {
				decide_action(st, st.items[k].action_id, true)
				break
			}
		}
		return
	}
	if st.view == .Chat && cur_ident(st) != nil {
		composer_keys(ui, st)
	}
}

composer_keys :: proc(ui: ^p.Ctx, st: ^St) {
	if .Ctrl not_in ui.input.mods {
		if typed := printable(p.typed_text(ui)); len(typed) > 0 {
			inject_at_elems(&st.input, st.caret, ..transmute([]u8)typed)
			st.caret += len(typed)
		}
	}
	if p.shortcut(ui, 'v', {.Ctrl}) {
		if text, ok := kit.clipboard_get(context.temp_allocator); ok && text != "" {
			inject_at_elems(&st.input, st.caret, ..transmute([]u8)text)
			st.caret += len(text)
		}
	}
	for k in ui.input.keys {
		switch k.sym {
		case p.KEY_RETURN, p.KEY_KP_ENTER:
			if .Shift in k.mods {
				inject_at(&st.input, st.caret, u8('\n'))
				st.caret += 1
			} else if st.sh.running {
				// Not lost: asked as soon as the current request ends.
				st.queued = strings.clone(strings.trim_space(string(st.input[:])))
				clear(&st.input)
				st.caret = 0
				toast(st, "Queued — it will be asked when the current request ends")
			} else {
				send(st)
				return
			}
		case p.KEY_BACKSPACE:
			if st.caret > 0 {
				n := utf8_back(st.input[:], st.caret)
				remove_range(&st.input, st.caret - n, st.caret)
				st.caret -= n
			}
		case p.KEY_DELETE:
			if st.caret < len(st.input) {
				n := utf8_fwd(st.input[:], st.caret)
				remove_range(&st.input, st.caret, st.caret + n)
			}
		case p.KEY_LEFT:
			if st.caret > 0 {st.caret -= utf8_back(st.input[:], st.caret)}
		case p.KEY_RIGHT:
			if st.caret < len(st.input) {st.caret += utf8_fwd(st.input[:], st.caret)}
		case p.KEY_HOME:
			st.caret = 0
		case p.KEY_END:
			st.caret = len(st.input)
		case 'u':
			if .Ctrl in k.mods {
				clear(&st.input)
				st.caret = 0
			}
		}
	}
}

printable :: proc(s: string) -> string {
	ok := true
	for c in transmute([]u8)s {
		if c < 0x20 || c == 0x7f {ok = false}
	}
	if ok {return s}
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)s {
		if c >= 0x20 && c != 0x7f {strings.write_byte(&b, c)}
	}
	return strings.to_string(b)
}

utf8_back :: proc(b: []u8, at: int) -> int {
	i := at - 1
	for i > 0 && b[i] & 0xc0 == 0x80 {i -= 1}
	return at - i
}

utf8_fwd :: proc(b: []u8, at: int) -> int {
	i := at + 1
	for i < len(b) && b[i] & 0xc0 == 0x80 {i += 1}
	return i - at
}
