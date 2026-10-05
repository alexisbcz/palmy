// Configuration.
//
// A window manager you have to rebuild to retune is a window manager you stop
// retuning, so everything that is a matter of taste lives in a text file:
//
//     $XDG_CONFIG_HOME/palmy/wm.conf   (or ~/.config/palmy/wm.conf)
//
// There is no file by default and that is a supported state: `CFG_DEFAULT` is
// the same text, compiled in, and it is parsed by the same parser. The default
// and the format therefore cannot drift apart — if the built-in default stops
// parsing, the compositor says so on stderr at startup.
//
// The parser is deliberately dull: one directive per line, `name = value`,
// `#` or `//` to end of line is a comment. Repeatable directives (`bind`,
// `rule`, `output`, `exec`) accumulate; scalar ones take the last value.
package wm

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import p "palmy:."

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

// Cfg_Act is the closed set of things a key can do. `spawn` is the one escape
// hatch, and it carries its argv rather than a shell string, so nothing is
// word-split twice.
Cfg_Act :: enum u8 {
	None,
	Spawn,
	Close,
	Focus_Next,
	Focus_Prev,
	Focus_Dir,
	Move_Dir, // floating: nudge; tiled: swap with the neighbour
	Resize_Dir,
	Toggle_Float,
	Toggle_Maximize,
	Minimize,
	Toggle_Tiling,
	Next_Layout,
	Master_Ratio, // arg: percent delta
	Master_Count, // arg: delta
	Swap_Master,
	Workspace, // arg: 1-based workspace
	Workspace_Rel, // arg: +1 / -1
	Move_To_Workspace,
	Move_To_Workspace_Rel,
	Cascade,
	Window_Mode,
	Reload,
	Quit, // leave the compositor (the nested host window closes)
	Session, // intent only: logged, never executed
}

Cfg_Dir :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

Cfg_Bind :: struct {
	mods:    p.Modifiers,
	// `any_mods` means the binding fires whatever is held. It is what the bare
	// function keys need: the demo recorder can only synthesize unmodified
	// keys, and a daily driver still wants F11 to maximise.
	any_mods: bool,
	sym:     u32,
	act:     Cfg_Act,
	arg:     int,
	argv:    []string,
	label:   string,
}

Cfg_Placement :: enum u8 {
	Cascade,
	Center,
	Pointer,
}

// Cfg_Rule matches a toplevel once, when it maps. An empty field matches
// anything; `app_id` is an exact match and `title` a substring, which is the
// split that every other WM has converged on because titles change and
// app_ids do not.
Cfg_Rule :: struct {
	app_id:      string,
	title:       string,
	set_float:   bool,
	float:       bool,
	workspace:   int, // 0: unset
	no_border:   bool,
	no_title:    bool,
	maximize:    bool,
	set_size:    bool,
	w, h:        int,
}

Cfg_Output :: struct {
	name:  string,
	x, y:  int,
	w, h:  int,
	scale: f32,
	// Which workspaces live on this head, 1-based and inclusive. 0/0 means
	// "share the global set", which is what a single-output setup wants.
	ws_lo: int,
	ws_hi: int,
}

Cfg :: struct {
	path:            string,
	loaded:          bool, // a file was found and read
	mtime:           i64,
	errors:          [dynamic]string,

	mod:             p.Modifiers,
	workspaces:      int,
	gaps_in:         int,
	gaps_out:        int,
	border:          int,
	border_focus:    u32,
	border_unfocus:  u32,
	title_bar:       bool,
	title_h:         int,
	bar:             bool,
	bar_h:           int,
	focus_follows_mouse: bool,
	placement:       Cfg_Placement,
	layout:          int, // index into TILE_LAYOUTS
	tiling:          bool, // new workspaces start tiled
	master_ratio:    f32,
	master_count:    int,
	move_step:       int,
	resize_step:     int,

	binds:           [dynamic]Cfg_Bind,
	rules:           [dynamic]Cfg_Rule,
	outputs:         [dynamic]Cfg_Output,
	autostart:       [dynamic][]string,
}

// ---------------------------------------------------------------------------
// The built-in default, which is also the documentation for the format
// ---------------------------------------------------------------------------

CFG_DEFAULT :: `
# palmy wm — default configuration.
#
# Copy to $XDG_CONFIG_HOME/palmy/wm.conf and edit. Reload without restarting
# with $mod+SHIFT+R; the file is also re-read within a second of being saved.

mod                 = SUPER
workspaces          = 9

gaps_in             = 6
gaps_out            = 10
border              = 1
border_focus        = #6366f1
border_unfocus      = #27272a
title_bar           = on
title_h             = 32
bar                 = on
bar_h               = 34

focus_follows_mouse = off
placement           = cascade

# Automatic layout. "master" is a master column plus a stack; "monocle" is one
# window at a time; "grid" is an even split. "floating" is no layout at all.
layout              = master
tiling              = on
master_ratio        = 0.58
master_count        = 1

move_step           = 36
resize_step         = 48

# Launchers. Commands are resolved against $PATH, so no absolute paths.
bind = $mod,       Return, spawn foot
bind = $mod,       T,      spawn foot
bind = $mod,       C,      spawn counter
bind = $mod,       G,      spawn gallery
bind = $mod,       O,      spawn todo
bind = $mod,       P,      spawn pixels

# Focus, stacking and the window itself.
bind = $mod,       Tab,    focusnext
bind = $mod SHIFT, Tab,    focusprev
bind = $mod,       Q,      close
bind = $mod,       M,      togglemaximize
bind = $mod,       N,      minimize
bind = $mod,       V,      togglefloat
bind = $mod,       F,      toggletiling
bind = $mod,       Space,  nextlayout
bind = $mod,       W,      windowmode
bind = $mod SHIFT, C,      cascade
bind = $mod SHIFT, R,      reload

# Master-stack tuning.
bind = $mod,       H,      masterratio -5
bind = $mod,       L,      masterratio +5
bind = $mod SHIFT, H,      mastercount -1
bind = $mod SHIFT, L,      mastercount +1
bind = $mod,       E,      swapmaster

# Directional focus and movement.
bind = $mod,       Left,   movefocus left
bind = $mod,       Right,  movefocus right
bind = $mod,       Up,     movefocus up
bind = $mod,       Down,   movefocus down
bind = $mod SHIFT, Left,   movewindow left
bind = $mod SHIFT, Right,  movewindow right
bind = $mod SHIFT, Up,     movewindow up
bind = $mod SHIFT, Down,   movewindow down
bind = $mod CTRL,  Left,   resizewindow left
bind = $mod CTRL,  Right,  resizewindow right
bind = $mod CTRL,  Up,     resizewindow up
bind = $mod CTRL,  Down,   resizewindow down

# Workspaces.
bind = $mod,       1,      workspace 1
bind = $mod,       2,      workspace 2
bind = $mod,       3,      workspace 3
bind = $mod,       4,      workspace 4
bind = $mod,       5,      workspace 5
bind = $mod,       6,      workspace 6
bind = $mod,       7,      workspace 7
bind = $mod,       8,      workspace 8
bind = $mod,       9,      workspace 9
bind = $mod SHIFT, 1,      movetoworkspace 1
bind = $mod SHIFT, 2,      movetoworkspace 2
bind = $mod SHIFT, 3,      movetoworkspace 3
bind = $mod SHIFT, 4,      movetoworkspace 4
bind = $mod SHIFT, 5,      movetoworkspace 5
bind = $mod SHIFT, 6,      movetoworkspace 6
bind = $mod SHIFT, 7,      movetoworkspace 7
bind = $mod SHIFT, 8,      movetoworkspace 8
bind = $mod SHIFT, 9,      movetoworkspace 9
bind = $mod,       Prior,  workspacerel -1
bind = $mod,       Next,   workspacerel +1

# Session. These are intent-only: the action is logged and nothing is run.
bind = $mod SHIFT, E,      exit
bind = $mod ALT,   Q,      quit

# Bare function keys, with no modifier at all. The host compositor eats SUPER
# when this one runs nested, and the scripted recorder can only synthesize
# unmodified keys, so every binding above that the demo needs has a twin here.
bind = ANY, F1,  spawn counter
bind = ANY, F2,  spawn gallery
bind = ANY, F3,  spawn todo
bind = ANY, F4,  spawn foot
bind = ANY, F5,  spawn pixels
bind = ANY, F6,  focusnext
bind = ANY, F7,  focusprev
bind = ANY, F8,  close
bind = ANY, F9,  toggletiling
bind = ANY, F10, windowmode
bind = ANY, F11, togglemaximize
bind = ANY, F12, nextlayout
bind = ANY, F13, workspacerel +1
bind = ANY, F14, workspacerel -1

# Per-application rules. Matched once, when the window maps.
#   rule = app_id=foot, float
#   rule = title~Volume Control, float, noborder
#   rule = app_id=pixels, workspace 3
#   rule = app_id=gallery, size 900x600

# Outputs. One line per head; the name is matched against the connector.
#   output = eDP-1,  1920x1080+0+0,    scale=1
#   output = DP-2,   2560x1440+1920+0, scale=1, workspaces=6-9

# Autostart. Empty on purpose: a fresh install must not run anything you did
# not ask for. One command per line, resolved against $PATH.
#   exec = waybar
`

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

cfg_path :: proc(allocator := context.allocator) -> string {
	if x := os.get_env("XDG_CONFIG_HOME", context.temp_allocator); x != "" {
		return fmt.aprintf("%s/palmy/wm.conf", x, allocator = allocator)
	}
	if h := os.get_env("HOME", context.temp_allocator); h != "" {
		return fmt.aprintf("%s/.config/palmy/wm.conf", h, allocator = allocator)
	}
	return strings.clone("palmy-wm.conf", allocator)
}

cfg_free :: proc(c: ^Cfg) {
	for e in c.errors {delete(e)}
	clear(&c.errors)
	for b in c.binds {
		for a in b.argv {delete(a)}
		delete(b.argv)
		delete(b.label)
	}
	clear(&c.binds)
	for r in c.rules {
		delete(r.app_id)
		delete(r.title)
	}
	clear(&c.rules)
	for o in c.outputs {delete(o.name)}
	clear(&c.outputs)
	for a in c.autostart {
		for w in a {delete(w)}
		delete(a)
	}
	clear(&c.autostart)
}

cfg_destroy :: proc(c: ^Cfg) {
	cfg_free(c)
	delete(c.errors)
	delete(c.binds)
	delete(c.rules)
	delete(c.outputs)
	delete(c.autostart)
	delete(c.path)
	c^ = {}
}

cfg_scalars :: proc(c: ^Cfg) {
	c.mod = {.Super}
	c.workspaces = 9
	c.gaps_in = 6
	c.gaps_out = 10
	c.border = 1
	c.border_focus = 0x6366f1
	c.border_unfocus = 0x27272a
	c.title_bar = true
	c.title_h = TITLE_H
	c.bar = true
	c.bar_h = BAR_H
	c.focus_follows_mouse = false
	c.placement = .Cascade
	c.layout = 0
	c.tiling = true
	c.master_ratio = 0.58
	c.master_count = 1
	c.move_step = 36
	c.resize_step = 48
}

// cfg_load resets `c` to the compiled-in default and then, if a file exists,
// layers it on top. A broken line is reported and skipped: a typo in one
// binding must never cost you every other binding.
cfg_load :: proc(c: ^Cfg) {
	cfg_free(c)
	cfg_scalars(c)
	cfg_parse(c, CFG_DEFAULT, "<built-in>")
	if len(c.errors) > 0 {
		// The compiled-in default failing to parse is a bug in this file.
		for e in c.errors {
			fmt.eprintfln("wm: built-in config: %s", e)
		}
	}

	if c.path == "" {
		c.path = cfg_path()
	}
	c.loaded = false
	c.mtime = 0
	data, err := os.read_entire_file(c.path, context.temp_allocator)
	if err != nil {
		return
	}
	if fi, serr := os.stat(c.path, context.temp_allocator); serr == nil {
		c.mtime = time.to_unix_nanoseconds(fi.modification_time)
	}
	c.loaded = true
	// A user file replaces the default bindings wholesale rather than adding
	// to them; otherwise there is no way to *remove* one.
	if cfg_has_binds(string(data)) {
		for b in c.binds {
			for a in b.argv {delete(a)}
			delete(b.argv)
			delete(b.label)
		}
		clear(&c.binds)
	}
	cfg_parse(c, string(data), c.path)
}

// cfg_changed is the cheap half of live reload: one stat, called at most once
// a second from the frame loop.
cfg_changed :: proc(c: ^Cfg) -> bool {
	fi, err := os.stat(c.path, context.temp_allocator)
	if err != nil {
		return c.loaded // the file was deleted: fall back to the default
	}
	return time.to_unix_nanoseconds(fi.modification_time) != c.mtime || !c.loaded
}

cfg_has_binds :: proc(text: string) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "bind") {
			return true
		}
	}
	return false
}

cfg_err :: proc(c: ^Cfg, src: string, n: int, format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	append(&c.errors, fmt.aprintf("%s:%d: %s", src, n, msg))
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

// cfg_strip_comment removes a comment from a line.
//
// `#` only comments at the *start* of a line. Stripping it anywhere was the
// obvious thing and it was wrong in the most quietly damaging way: every
// `border_focus = #6366f1` parsed as an empty value and fell back to the
// compiled-in default, so colours in a config file did nothing and the
// built-in default happened to agree with the fallback, which hid it.
// An inline comment is ` // ...`, and it has to be preceded by whitespace so
// a path or a URL inside a `spawn` survives.
cfg_strip_comment :: proc(line: string) -> string {
	out := strings.trim_space(line)
	if strings.has_prefix(out, "#") || strings.has_prefix(out, "//") {
		return ""
	}
	for i in 1 ..< max(len(out) - 1, 1) {
		if out[i] == '/' && out[i + 1] == '/' && (out[i - 1] == ' ' || out[i - 1] == '\t') {
			out = out[:i]
			break
		}
	}
	return strings.trim_space(out)
}

cfg_parse :: proc(c: ^Cfg, text: string, src: string) {
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		t := cfg_strip_comment(line)
		if t == "" {
			continue
		}
		eq := strings.index_byte(t, '=')
		if eq < 0 {
			cfg_err(c, src, n, "expected name = value, got %q", t)
			continue
		}
		name := strings.trim_space(t[:eq])
		val := strings.trim_space(t[eq + 1:])
		cfg_set(c, name, val, src, n)
	}
}

cfg_set :: proc(c: ^Cfg, name, val, src: string, n: int) {
	switch name {
	case "mod":
		m, ok := cfg_mods(c, val)
		if !ok {
			cfg_err(c, src, n, "unknown modifier in %q", val)
			return
		}
		c.mod = m
	case "workspaces":
		c.workspaces = clamp(cfg_int(val, c.workspaces), 1, 32)
	case "gaps_in":
		c.gaps_in = clamp(cfg_int(val, c.gaps_in), 0, 200)
	case "gaps_out":
		c.gaps_out = clamp(cfg_int(val, c.gaps_out), 0, 400)
	case "border":
		c.border = clamp(cfg_int(val, c.border), 0, 32)
	case "border_focus":
		c.border_focus = cfg_color(val, c.border_focus)
	case "border_unfocus":
		c.border_unfocus = cfg_color(val, c.border_unfocus)
	case "title_bar":
		c.title_bar = cfg_bool(val, c.title_bar)
	case "title_h":
		c.title_h = clamp(cfg_int(val, c.title_h), 12, 96)
	case "bar":
		c.bar = cfg_bool(val, c.bar)
	case "bar_h":
		c.bar_h = clamp(cfg_int(val, c.bar_h), 0, 96)
	case "focus_follows_mouse":
		c.focus_follows_mouse = cfg_bool(val, c.focus_follows_mouse)
	case "placement":
		switch strings.to_lower(val, context.temp_allocator) {
		case "cascade":
			c.placement = .Cascade
		case "center", "centre":
			c.placement = .Center
		case "pointer", "mouse":
			c.placement = .Pointer
		case:
			cfg_err(c, src, n, "unknown placement %q", val)
		}
	case "layout":
		if strings.to_lower(val, context.temp_allocator) == "floating" {
			c.tiling = false
			return
		}
		i, ok := tile_layout_by_name(val)
		if !ok {
			cfg_err(c, src, n, "unknown layout %q", val)
			return
		}
		c.layout = i
	case "tiling":
		c.tiling = cfg_bool(val, c.tiling)
	case "master_ratio":
		c.master_ratio = clamp(cfg_f32(val, c.master_ratio), 0.15, 0.85)
	case "master_count":
		c.master_count = clamp(cfg_int(val, c.master_count), 1, 8)
	case "move_step":
		c.move_step = clamp(cfg_int(val, c.move_step), 1, 400)
	case "resize_step":
		c.resize_step = clamp(cfg_int(val, c.resize_step), 1, 400)
	case "bind":
		cfg_bind(c, val, src, n)
	case "rule":
		cfg_rule(c, val, src, n)
	case "output":
		cfg_output(c, val, src, n)
	case "exec", "autostart":
		argv := cfg_argv(val)
		if len(argv) == 0 {
			cfg_err(c, src, n, "exec needs a command")
			return
		}
		append(&c.autostart, argv)
	case:
		cfg_err(c, src, n, "unknown setting %q", name)
	}
}

cfg_int :: proc(s: string, def: int) -> int {
	v, ok := strconv.parse_int(strings.trim_space(s))
	return ok ? v : def
}

cfg_f32 :: proc(s: string, def: f32) -> f32 {
	v, ok := strconv.parse_f32(strings.trim_space(s))
	return ok ? v : def
}

cfg_bool :: proc(s: string, def: bool) -> bool {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "on", "true", "yes", "1", "enable", "enabled":
		return true
	case "off", "false", "no", "0", "disable", "disabled":
		return false
	}
	return def
}

cfg_color :: proc(s: string, def: u32) -> u32 {
	t := strings.trim_space(s)
	t = strings.trim_prefix(t, "#")
	t = strings.trim_prefix(t, "0x")
	if len(t) != 6 && len(t) != 8 {
		return def
	}
	v: u32 = 0
	for ch in t {
		d: u32
		switch {
		case ch >= '0' && ch <= '9':
			d = u32(ch - '0')
		case ch >= 'a' && ch <= 'f':
			d = u32(ch-'a') + 10
		case ch >= 'A' && ch <= 'F':
			d = u32(ch-'A') + 10
		case:
			return def
		}
		v = v * 16 + d
	}
	return v & 0xffffff
}

// cfg_argv word-splits on runs of whitespace. Single and double quotes keep a
// word together, which is all the quoting a launcher line ever needs.
cfg_argv :: proc(s: string) -> []string {
	out := make([dynamic]string, 0, 4)
	cur := strings.builder_make()
	defer strings.builder_destroy(&cur)
	quote: rune = 0
	have := false
	flush :: proc(out: ^[dynamic]string, cur: ^strings.Builder, have: ^bool) {
		if have^ {
			append(out, strings.clone(strings.to_string(cur^)))
			strings.builder_reset(cur)
			have^ = false
		}
	}
	for ch in s {
		switch {
		case quote != 0 && ch == quote:
			quote = 0
		case quote != 0:
			strings.write_rune(&cur, ch)
			have = true
		case ch == '"' || ch == '\'':
			quote = ch
			have = true
		case ch == ' ' || ch == '\t':
			flush(&out, &cur, &have)
		case:
			strings.write_rune(&cur, ch)
			have = true
		}
	}
	flush(&out, &cur, &have)
	return out[:]
}

cfg_mods :: proc(c: ^Cfg, s: string) -> (p.Modifiers, bool) {
	m: p.Modifiers
	rest := s
	for part in strings.fields_iterator(&rest) {
		toks := part
		for tok in strings.split_by_byte_iterator(&toks, '+') {
			t := strings.to_lower(strings.trim_space(tok), context.temp_allocator)
			switch t {
			case "":
			case "$mod", "mod":
				m += c.mod
			case "super", "win", "logo", "meta":
				m += {.Super}
			case "alt", "mod1":
				m += {.Alt}
			case "ctrl", "control":
				m += {.Ctrl}
			case "shift":
				m += {.Shift}
			case "caps":
				m += {.Caps}
			case "none":
			case:
				return m, false
			}
		}
	}
	return m, true
}

// cfg_bind parses `<mods>, <key>, <action> [arg...]`.
cfg_bind :: proc(c: ^Cfg, val, src: string, n: int) {
	a := strings.index_byte(val, ',')
	if a < 0 {
		cfg_err(c, src, n, "bind needs <mods>, <key>, <action>")
		return
	}
	rest := val[a + 1:]
	b := strings.index_byte(rest, ',')
	if b < 0 {
		cfg_err(c, src, n, "bind needs <mods>, <key>, <action>")
		return
	}
	mods_s := strings.trim_space(val[:a])
	key_s := strings.trim_space(rest[:b])
	act_s := strings.trim_space(rest[b + 1:])

	bind: Cfg_Bind
	if strings.to_lower(mods_s, context.temp_allocator) == "any" {
		bind.any_mods = true
	} else {
		m, ok := cfg_mods(c, mods_s)
		if !ok {
			cfg_err(c, src, n, "unknown modifier in %q", mods_s)
			return
		}
		bind.mods = m
	}
	sym, ok := cfg_keysym(key_s)
	if !ok {
		cfg_err(c, src, n, "unknown key %q", key_s)
		return
	}
	bind.sym = sym
	if !cfg_action(c, &bind, act_s, src, n) {
		return
	}
	bind.label = strings.clone(act_s)

	// A later binding on the same chord replaces an earlier one, so a user
	// file can override one default without clearing the rest.
	for &old, i in c.binds {
		if old.sym == bind.sym && old.mods == bind.mods && old.any_mods == bind.any_mods {
			for s2 in old.argv {delete(s2)}
			delete(old.argv)
			delete(old.label)
			c.binds[i] = bind
			return
		}
	}
	append(&c.binds, bind)
}

cfg_action :: proc(c: ^Cfg, bind: ^Cfg_Bind, s, src: string, n: int) -> bool {
	rest := s
	verb := ""
	for f in strings.fields_iterator(&rest) {
		verb = f
		break
	}
	arg := strings.trim_space(rest)
	switch strings.to_lower(verb, context.temp_allocator) {
	case "spawn", "exec":
		bind.act = .Spawn
		bind.argv = cfg_argv(arg)
		if len(bind.argv) == 0 {
			cfg_err(c, src, n, "spawn needs a command")
			return false
		}
	case "close", "killactive":
		bind.act = .Close
	case "focusnext", "cyclenext":
		bind.act = .Focus_Next
	case "focusprev", "cycleprev":
		bind.act = .Focus_Prev
	case "movefocus":
		d, ok := cfg_dir(arg)
		if !ok {
			cfg_err(c, src, n, "movefocus needs left|right|up|down")
			return false
		}
		bind.act = .Focus_Dir
		bind.arg = int(d)
	case "movewindow":
		d, ok := cfg_dir(arg)
		if !ok {
			cfg_err(c, src, n, "movewindow needs left|right|up|down")
			return false
		}
		bind.act = .Move_Dir
		bind.arg = int(d)
	case "resizewindow":
		d, ok := cfg_dir(arg)
		if !ok {
			cfg_err(c, src, n, "resizewindow needs left|right|up|down")
			return false
		}
		bind.act = .Resize_Dir
		bind.arg = int(d)
	case "togglefloat", "togglefloating":
		bind.act = .Toggle_Float
	case "togglemaximize", "fullscreen", "maximize":
		bind.act = .Toggle_Maximize
	case "minimize":
		bind.act = .Minimize
	case "toggletiling":
		bind.act = .Toggle_Tiling
	case "nextlayout", "cyclelayout":
		bind.act = .Next_Layout
	case "masterratio":
		bind.act = .Master_Ratio
		bind.arg = cfg_signed(arg, 5)
	case "mastercount":
		bind.act = .Master_Count
		bind.arg = cfg_signed(arg, 1)
	case "swapmaster":
		bind.act = .Swap_Master
	case "workspace":
		bind.act = .Workspace
		bind.arg = cfg_int(arg, 1)
	case "workspacerel":
		bind.act = .Workspace_Rel
		bind.arg = cfg_signed(arg, 1)
	case "movetoworkspace":
		bind.act = .Move_To_Workspace
		bind.arg = cfg_int(arg, 1)
	case "movetoworkspacerel":
		bind.act = .Move_To_Workspace_Rel
		bind.arg = cfg_signed(arg, 1)
	case "cascade":
		bind.act = .Cascade
	case "windowmode":
		bind.act = .Window_Mode
	case "reload":
		bind.act = .Reload
	case "quit":
		bind.act = .Quit
	case "exit", "logout", "reboot", "poweroff", "shutdown", "suspend", "lock":
		// Intent only. See cfg_session_name / act_session.
		bind.act = .Session
		bind.arg = cfg_session_id(verb)
	case:
		cfg_err(c, src, n, "unknown action %q", verb)
		return false
	}
	return true
}

cfg_signed :: proc(s: string, def: int) -> int {
	t := strings.trim_space(s)
	if t == "" {
		return def
	}
	neg := false
	if strings.has_prefix(t, "+") {
		t = t[1:]
	} else if strings.has_prefix(t, "-") {
		neg = true
		t = t[1:]
	}
	v, ok := strconv.parse_int(t)
	if !ok {
		return def
	}
	return neg ? -v : v
}

cfg_dir :: proc(s: string) -> (Cfg_Dir, bool) {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "left", "l":
		return .Left, true
	case "right", "r":
		return .Right, true
	case "up", "u":
		return .Up, true
	case "down", "d":
		return .Down, true
	}
	return .Left, false
}

CFG_SESSIONS := [?]string{"exit", "logout", "reboot", "poweroff", "suspend", "lock"}

cfg_session_id :: proc(verb: string) -> int {
	v := strings.to_lower(verb, context.temp_allocator)
	if v == "shutdown" {v = "poweroff"}
	for name, i in CFG_SESSIONS {
		if name == v {
			return i
		}
	}
	return 0
}

cfg_session_name :: proc(id: int) -> string {
	if id < 0 || id >= len(CFG_SESSIONS) {
		return "exit"
	}
	return CFG_SESSIONS[id]
}

// cfg_rule parses `app_id=foo, title~bar, float, workspace 3, noborder`.
cfg_rule :: proc(c: ^Cfg, val, src: string, n: int) {
	r: Cfg_Rule
	rest := val
	any := false
	for part in strings.split_iterator(&rest, ",") {
		t := strings.trim_space(part)
		if t == "" {
			continue
		}
		switch {
		case strings.has_prefix(t, "app_id="):
			r.app_id = strings.clone(strings.trim_space(t[len("app_id="):]))
			any = true
		case strings.has_prefix(t, "class="):
			r.app_id = strings.clone(strings.trim_space(t[len("class="):]))
			any = true
		case strings.has_prefix(t, "title~"):
			r.title = strings.clone(strings.trim_space(t[len("title~"):]))
			any = true
		case strings.has_prefix(t, "title="):
			r.title = strings.clone(strings.trim_space(t[len("title="):]))
			any = true
		case t == "float" || t == "floating":
			r.set_float = true
			r.float = true
		case t == "tile" || t == "tiled":
			r.set_float = true
			r.float = false
		case t == "noborder":
			r.no_border = true
		case t == "notitle":
			r.no_title = true
		case t == "maximize" || t == "maximise":
			r.maximize = true
		case strings.has_prefix(t, "workspace"):
			r.workspace = cfg_int(strings.trim_space(t[len("workspace"):]), 0)
		case strings.has_prefix(t, "size"):
			dims := strings.trim_space(t[len("size"):])
			if x := strings.index_byte(dims, 'x'); x > 0 {
				r.w = cfg_int(dims[:x], 0)
				r.h = cfg_int(dims[x + 1:], 0)
				r.set_size = r.w > 0 && r.h > 0
			}
		case:
			cfg_err(c, src, n, "unknown rule clause %q", t)
		}
	}
	if !any {
		cfg_err(c, src, n, "a rule needs app_id= or title~")
		delete(r.app_id)
		delete(r.title)
		return
	}
	append(&c.rules, r)
}

// cfg_output parses `NAME, 1920x1080+0+0, scale=1, workspaces=1-5`.
cfg_output :: proc(c: ^Cfg, val, src: string, n: int) {
	o := Cfg_Output {
		scale = 1,
	}
	rest := val
	first := true
	for part in strings.split_iterator(&rest, ",") {
		t := strings.trim_space(part)
		if t == "" {
			continue
		}
		if first {
			o.name = strings.clone(t)
			first = false
			continue
		}
		switch {
		case strings.has_prefix(t, "scale="):
			o.scale = clamp(cfg_f32(t[len("scale="):], 1), 0.25, 8)
		case strings.has_prefix(t, "workspaces="):
			rng := t[len("workspaces="):]
			if d := strings.index_byte(rng, '-'); d > 0 {
				o.ws_lo = cfg_int(rng[:d], 0)
				o.ws_hi = cfg_int(rng[d + 1:], 0)
			}
		case t == "disable" || t == "off":
			o.w, o.h = 0, 0
		case:
			// Geometry: WxH+X+Y, with +X+Y optional.
			geom := t
			plus := strings.index_byte(geom, '+')
			dims := plus >= 0 ? geom[:plus] : geom
			if x := strings.index_byte(dims, 'x'); x > 0 {
				o.w = cfg_int(dims[:x], 0)
				o.h = cfg_int(dims[x + 1:], 0)
			} else {
				cfg_err(c, src, n, "unknown output clause %q", t)
				continue
			}
			if plus >= 0 {
				pos := geom[plus + 1:]
				if x := strings.index_byte(pos, '+'); x > 0 {
					o.x = cfg_int(pos[:x], 0)
					o.y = cfg_int(pos[x + 1:], 0)
				}
			}
		}
	}
	if o.name == "" {
		cfg_err(c, src, n, "an output needs a name")
		return
	}
	append(&c.outputs, o)
}

// ---------------------------------------------------------------------------
// Keysyms
//
// The config names keys the way xkb does, because that is what `wev` prints
// and what every other Wayland config file uses.
// ---------------------------------------------------------------------------

CFG_KEYNAMES := [?]struct {
	name: string,
	sym:  u32,
}{
	{"Return", p.KEY_RETURN},
	{"Enter", p.KEY_RETURN},
	{"Tab", p.KEY_TAB},
	{"Escape", p.KEY_ESCAPE},
	{"Esc", p.KEY_ESCAPE},
	{"Space", p.KEY_SPACE},
	{"BackSpace", p.KEY_BACKSPACE},
	{"Delete", p.KEY_DELETE},
	{"Insert", p.KEY_INSERT},
	{"Home", p.KEY_HOME},
	{"End", p.KEY_END},
	{"Prior", p.KEY_PAGE_UP},
	{"Page_Up", p.KEY_PAGE_UP},
	{"Next", p.KEY_PAGE_DOWN},
	{"Page_Down", p.KEY_PAGE_DOWN},
	{"Left", p.KEY_LEFT},
	{"Right", p.KEY_RIGHT},
	{"Up", p.KEY_UP},
	{"Down", p.KEY_DOWN},
	{"F1", 0xffbe},
	{"F2", 0xffbf},
	{"F3", 0xffc0},
	{"F4", 0xffc1},
	{"F5", 0xffc2},
	{"F6", 0xffc3},
	{"F7", 0xffc4},
	{"F8", 0xffc5},
	{"F9", 0xffc6},
	{"F10", 0xffc7},
	{"F11", 0xffc8},
	{"F12", 0xffc9},
	{"F13", 0xffca},
	{"F14", 0xffcb},
	{"F15", 0xffcc},
}

cfg_keysym :: proc(name: string) -> (u32, bool) {
	t := strings.trim_space(name)
	if t == "" {
		return 0, false
	}
	for e in CFG_KEYNAMES {
		if strings.equal_fold(e.name, t) {
			return e.sym, true
		}
	}
	// A single printable character is itself.
	r := []rune{}
	count := 0
	last: rune
	for ch in t {
		last = ch
		count += 1
	}
	_ = r
	if count == 1 && last >= 0x20 && last < 0x7f {
		return u32(cfg_lower(last)), true
	}
	return 0, false
}

cfg_lower :: proc(r: rune) -> rune {
	if r >= 'A' && r <= 'Z' {
		return r + 32
	}
	return r
}

// cfg_sym_matches compares a bound keysym with one the host delivered. The
// host sends the *shifted* symbol, so a binding written `$mod SHIFT, Q` would
// otherwise never fire; letters are therefore compared case-insensitively and
// the SHIFT requirement is carried by the modifier set alone.
cfg_sym_matches :: proc(bound, got: u32) -> bool {
	if bound == got {
		return true
	}
	if bound >= 'a' && bound <= 'z' && got == bound - 32 {
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Resolving a command against $PATH
//
// The old hardcoded table pointed at one person's home directory. Nothing in
// the configuration may be an absolute path by necessity, so a bare name is
// looked up in $PATH, and then in this build's own bin/ as a convenience when
// the compositor is run from the source tree.
// ---------------------------------------------------------------------------

cfg_which :: proc(cmd: string, allocator := context.temp_allocator) -> (string, bool) {
	if cmd == "" {
		return "", false
	}
	if strings.contains_rune(cmd, '/') {
		return cmd, os.exists(cmd)
	}
	path := os.get_env("PATH", context.temp_allocator)
	rest := path
	for dir in strings.split_by_byte_iterator(&rest, ':') {
		if dir == "" {
			continue
		}
		cand := fmt.tprintf("%s/%s", dir, cmd)
		if os.exists(cand) {
			return strings.clone(cand, allocator), true
		}
	}
	// Running out of the source tree: ./bin/<cmd> next to the working dir.
	for dir in ([?]string{"bin", "../bin", "../../bin"}) {
		cand := fmt.tprintf("%s/%s", dir, cmd)
		if os.exists(cand) {
			return strings.clone(cand, allocator), true
		}
	}
	return "", false
}
