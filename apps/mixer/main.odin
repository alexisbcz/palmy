package main

// An audio mixer for Wayland, drawn by palmy's software rasterizer and driven
// by PipeWire's own command line tools.
//
// Reads come from `pactl -f json` (verified to work on this build before
// anything depended on it), writes go through `wpctl`, and every write is read
// back with `wpctl get-volume` so the window shows what the server did rather
// than what it was asked to do. See pipewire.odin.
//
// This program changes real audio state, so two things are deliberate:
//
//   * nothing is ever set above 1.0. PipeWire will happily amplify past it and
//     hand somebody a clipped headphone output they did not ask for.
//   * the volume and mute of the default sink are recorded at launch, shown in
//     the footer, and restorable with one key.
//
// There is no worker thread here. pactl answers in about six milliseconds, so
// a refresh happens inside the frame and nothing can deadlock.

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"
import p "palmy:."

HEADER_H :: 96
FOOTER_H :: 46
RIGHT_W :: 424

REFRESH :: 1.5

Item_Kind :: enum {
	Out,
	In,
	Stream,
}

Item :: struct {
	kind: Item_Kind,
	i:    int, // index into a.outs / a.ins / a.streams
}

Model :: struct {
	arena:        virtual.Arena, // the model's own strings
	scratch:      virtual.Arena, // where the JSON documents are parsed
	al:           mem.Allocator,
	sl:           mem.Allocator,

	a:            Audio,
	level:        Level,

	items:        []Item,
	sel:          [96]u8, // the selected item's stable key
	sel_len:      int,
	at:           int, // its position in `items`, -1 when it has gone away

	next_refresh: f64,
	refresh_ms:   f32,
	have_tools:   bool,
	loaded:       bool,

	log_open:     bool,
	help_open:    bool,

	// What the default sink was when this window opened, so it can be put back.
	orig_name:    string,
	orig_default: string, // the node *name* of the default sink at launch
	orig_node:    int,
	orig_vol:     f32,
	orig_mute:    bool,
	orig_ok:      bool,
	touched:      bool, // has this applet changed anything at all

	toast:        [192]u8,
	toast_len:    int,
	toast_until:  f64,
	toast_bad:    bool,
}

g_now: f64

main :: proc() {
	args := os.args[1:]
	for a, i in args {
		if a == "--selftest" {
			selftest()
			return
		}
		// `--shot out.png [key ...]` renders one frame offscreen, with any
		// keys given after the path pressed first. No compositor involved.
		if a == "--shot" && i + 1 < len(args) {
			keys_wanted := make([dynamic]u32, context.allocator)
			for extra in args[i + 2:] {
				if len(extra) > 0 {
					append(&keys_wanted, u32(extra[0]))
				}
			}
			shot(args[i + 1], keys_wanted[:])
			return
		}
	}

	app, err := start_window()
	if err != "" {
		fmt.eprintfln("mixer: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	m := new(Model)
	virtual.arena_init_growing(&m.arena) or_else panic("arena")
	virtual.arena_init_growing(&m.scratch) or_else panic("scratch")
	m.al = virtual.arena_allocator(&m.arena)
	m.sl = virtual.arena_allocator(&m.scratch)
	m.at = -1

	m.have_tools = kit_has("pactl") && kit_has("wpctl")
	refresh(m)
	capture_original(m)

	defer level_stop(&m.level)

	for ui in p.frames(app) {
		g_now = f64(p.elapsed(ui))

		if g_now >= m.next_refresh {
			refresh(m)
			m.next_refresh = g_now + REFRESH
		}
		level_poll(&m.level, p.delta_time(ui))

		rebuild_items(m)
		keys(ui, app, m)
		rebuild_items(m)
		build(ui, m)
	}
}

kit_has :: proc(name: string) -> bool {
	_, ok := run_quiet({"sh", "-c", fmt.tprintf("command -v %s", name)})
	return ok
}

run_quiet :: proc(argv: []string) -> (string, bool) {
	state, sout, serr, err := os.process_exec({command = argv}, context.temp_allocator)
	_ = serr
	if err != nil {
		return "", false
	}
	return strings.trim_space(string(sout)), state.exit_code == 0
}

note :: proc(m: ^Model, s: string, bad := false) {
	n := min(len(s), len(m.toast))
	copy(m.toast[:], s[:n])
	m.toast_len = n
	m.toast_bad = bad
	m.toast_until = g_now + 6
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

refresh :: proc(m: ^Model) {
	t0 := time.tick_now()
	virtual.arena_free_all(&m.arena)
	virtual.arena_free_all(&m.scratch)
	m.al = virtual.arena_allocator(&m.arena)
	m.sl = virtual.arena_allocator(&m.scratch)
	m.a = audio_read(m.al, m.sl)
	m.loaded = true
	m.refresh_ms = f32(time.duration_milliseconds(time.tick_diff(t0, time.tick_now())))
}

// capture_original records the state of the default sink at launch. Nothing
// else in this program writes to it.
capture_original :: proc(m: ^Model) {
	for d in m.a.outs {
		if !d.default {
			continue
		}
		v, mute, ok := read_back(d.node)
		m.orig_name = strings.clone(d.desc)
		m.orig_default = strings.clone(d.name)
		m.orig_node = d.node
		m.orig_vol = ok ? v : d.vol
		m.orig_mute = ok ? mute : d.mute
		m.orig_ok = true
		fmt.eprintfln(
			"[mixer] default sink at launch: %s  volume %.2f  muted %v",
			d.desc,
			m.orig_vol,
			m.orig_mute,
		)
		return
	}
}

restore_original :: proc(m: ^Model) {
	if !m.orig_ok {
		note(m, "Nothing recorded to restore", true)
		return
	}
	set_volume(m.orig_node, m.orig_vol)
	set_mute(m.orig_node, m.orig_mute)
	// Making another device the default is the one change this applet makes
	// that a volume slider cannot undo, so U puts that back too.
	moved := false
	for d in m.a.outs {
		if d.default && d.name != m.orig_default {
			moved = true
		}
	}
	if moved && m.orig_node >= 0 {
		set_default(m.orig_node)
	}
	v, mute, ok := read_back(m.orig_node)
	refresh(m)
	m.touched = false
	if ok {
		note(
			m,
			fmt.tprintf(
				"%s restored to %.0f%%%s%s",
				m.orig_name,
				v * 100,
				mute ? " (muted, as it was)" : "",
				moved ? " and made the default again" : "",
			),
		)
	} else {
		note(m, "Restore issued but wpctl did not confirm", true)
	}
}

// ---------------------------------------------------------------------------
// The flat list the keyboard walks
// ---------------------------------------------------------------------------

rebuild_items :: proc(m: ^Model) {
	items := make([dynamic]Item, 0, 24, context.temp_allocator)
	for _, i in m.a.outs {
		append(&items, Item{.Out, i})
	}
	for _, i in m.a.ins {
		append(&items, Item{.In, i})
	}
	for _, i in m.a.streams {
		append(&items, Item{.Stream, i})
	}
	m.items = items[:]

	m.at = -1
	want := string(m.sel[:m.sel_len])
	for it, k in m.items {
		if item_key(m, it) == want {
			m.at = k
			break
		}
	}
	if m.at < 0 && len(m.items) > 0 {
		m.at = 0
		set_sel(m, item_key(m, m.items[0]))
	}
}

// item_key identifies a row across refreshes. Devices keep their node name;
// a stream is identified by its index, which is all PipeWire gives it.
item_key :: proc(m: ^Model, it: Item) -> string {
	switch it.kind {
	case .Out:
		return fmt.tprintf("o:%s", m.a.outs[it.i].name)
	case .In:
		return fmt.tprintf("i:%s", m.a.ins[it.i].name)
	case .Stream:
		s := m.a.streams[it.i]
		return fmt.tprintf("s:%d:%d", s.record ? 1 : 0, s.index)
	}
	return ""
}

set_sel :: proc(m: ^Model, key: string) {
	n := min(len(key), len(m.sel))
	copy(m.sel[:], key[:n])
	m.sel_len = n
}

move_sel :: proc(m: ^Model, delta: int) {
	if len(m.items) == 0 {
		return
	}
	at := m.at < 0 ? 0 : clamp(m.at + delta, 0, len(m.items) - 1)
	set_sel(m, item_key(m, m.items[at]))
	m.at = at
}

sel_node :: proc(m: ^Model) -> (node: int, vol: f32, mute: bool, label: string, ok: bool) {
	if m.at < 0 || m.at >= len(m.items) {
		return -1, 0, false, "", false
	}
	it := m.items[m.at]
	switch it.kind {
	case .Out:
		d := m.a.outs[it.i]
		return d.node, d.vol, d.mute, d.desc, true
	case .In:
		d := m.a.ins[it.i]
		return d.node, d.vol, d.mute, d.desc, true
	case .Stream:
		s := m.a.streams[it.i]
		return s.node, s.vol, s.mute, s.app, true
	}
	return -1, 0, false, "", false
}

sel_kind :: proc(m: ^Model) -> (Item_Kind, bool) {
	if m.at < 0 || m.at >= len(m.items) {
		return .Out, false
	}
	return m.items[m.at].kind, true
}

// ---------------------------------------------------------------------------
// Actions
// ---------------------------------------------------------------------------

nudge :: proc(m: ^Model, delta: f32) {
	node, vol, _, label0, ok := sel_node(m)
	if !ok || node < 0 {
		return
	}
	// `refresh` throws the arena away, and the device description lives in it.
	// Everything printed after a refresh has to be copied out first.
	label := strings.clone(label0, context.temp_allocator)
	target := nudge_target(vol, delta)
	if abs(target - vol) < 0.001 {
		if target >= VOL_CEILING {
			note(m, "100% is the ceiling this mixer will set", true)
		}
		return
	}
	set_volume(node, target)
	v, mute, got := read_back(node)
	m.touched = true
	refresh(m)
	if got {
		note(
			m,
			fmt.tprintf("%s · %.0f%%%s (wpctl confirms %.2f)", label, v * 100, mute ? " muted" : "", v),
		)
	} else {
		note(m, fmt.tprintf("%s · set to %.0f%%", label, target * 100), true)
	}
}

toggle_mute :: proc(m: ^Model) {
	node, _, mute, label0, ok := sel_node(m)
	if !ok || node < 0 {
		return
	}
	label := strings.clone(label0, context.temp_allocator)
	set_mute(node, !mute)
	v, now_mute, got := read_back(node)
	m.touched = true
	refresh(m)
	if got {
		note(m, fmt.tprintf("%s · %s at %.0f%%", label, now_mute ? "muted" : "unmuted", v * 100))
	} else {
		note(m, fmt.tprintf("%s · mute toggled", label), true)
	}
}

make_default :: proc(m: ^Model) {
	kind, ok := sel_kind(m)
	if !ok {
		return
	}
	if kind == .Stream {
		note(m, "A stream has no default to set — pick a device", true)
		return
	}
	node, _, _, label0, _ := sel_node(m)
	label := strings.clone(label0, context.temp_allocator)
	set_default(node)
	m.touched = true
	refresh(m)
	note(m, fmt.tprintf("%s is now the default %s", label, kind == .Out ? "output" : "input"))
}

toggle_level :: proc(m: ^Model) {
	if m.level.on {
		level_stop(&m.level)
		note(m, "Input meter stopped; parec killed")
		return
	}
	// The meter listens to whichever input is selected, falling back to the
	// default source.
	source := ""
	if kind, ok := sel_kind(m); ok && kind == .In {
		source = m.a.ins[m.items[m.at].i].name
	} else if m.a.default_in != "" {
		source = m.a.default_in
	} else if len(m.a.ins) > 0 {
		source = m.a.ins[0].name
	}
	if source == "" {
		note(m, "No input device to listen to", true)
		return
	}
	if level_start(&m.level, source) {
		note(m, "Input meter on — this applet is now recording from that source")
	} else {
		note(m, m.level.err == "" ? "Could not start parec" : m.level.err, true)
	}
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

keys :: proc(ui: ^p.Ctx, app: ^p.App, m: ^Model) {
	if p.shortcut(ui, 'q', {.Ctrl}) {
		p.quit_app(app)
	}

	if m.help_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, '?') {
			m.help_open = false
		}
		return
	}
	if m.log_open {
		if p.key_pressed(ui, p.KEY_ESCAPE) || p.key_pressed(ui, 'c') {
			m.log_open = false
		}
		return
	}

	if p.key_pressed(ui, p.KEY_DOWN) {move_sel(m, 1)}
	if p.key_pressed(ui, p.KEY_UP) {move_sel(m, -1)}
	if p.key_pressed(ui, p.KEY_HOME) {move_sel(m, -1 << 20)}
	if p.key_pressed(ui, p.KEY_END) {move_sel(m, 1 << 20)}

	// Fine steps on Shift, because a mixer that can only move in fives is not
	// a mixer.
	fine := p.shortcut(ui, p.KEY_LEFT, {.Shift}, true) || p.shortcut(ui, p.KEY_RIGHT, {.Shift}, true)
	step: f32 = fine ? 0.01 : 0.05
	if p.key_pressed(ui, p.KEY_RIGHT) {nudge(m, step)}
	if p.key_pressed(ui, p.KEY_LEFT) {nudge(m, -step)}

	if p.key_pressed(ui, 'm') {toggle_mute(m)}
	if p.key_pressed(ui, 'd') || p.key_pressed(ui, p.KEY_RETURN) {make_default(m)}
	if p.key_pressed(ui, 'l') {toggle_level(m)}
	if p.key_pressed(ui, 'c') {m.log_open = true}
	if p.key_pressed(ui, 'u') {restore_original(m)}
	if p.key_pressed(ui, 'r') {
		refresh(m)
		note(m, fmt.tprintf("Re-read the graph in %.0f ms", m.refresh_ms))
	}
	if p.key_pressed(ui, '?') {m.help_open = true}
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

pct_label :: proc(v: f32) -> string {
	return fmt.tprintf("%.0f%%", v * 100)
}

bus_label :: proc(d: Dev) -> string {
	switch d.bus {
	case "bluetooth":
		return d.codec == "" ? "Bluetooth" : fmt.tprintf("Bluetooth · %s", upper(d.codec))
	case "usb":
		return "USB"
	case "pci":
		return "Built-in"
	}
	return d.bus == "" ? "" : d.bus
}

upper :: proc(s: string) -> string {
	b := make([]u8, len(s), context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		b[i] = c >= 'a' && c <= 'z' ? c - 32 : c
	}
	return string(b)
}

state_label :: proc(s: string) -> string {
	switch s {
	case "RUNNING":
		return "playing"
	case "IDLE":
		return "idle"
	case "SUSPENDED":
		return "suspended"
	}
	return s == "" ? "" : s
}
