// keys.odin — what the keyboard does before a client sees it.
//
// Every key goes through one gauntlet, in order: the lock screen, the
// compositor's open overlays (a menu, the cheat sheet, the overview, the
// switcher), Escape during a drag, the binding table, window mode — and only
// then the focused client.
//
// Bindings match on the key the user pressed, not on the character it typed
// (UX.md P0-11). With a US keymap Shift+2 types `at`, so a binding written
// `$mod SHIFT, 2` that compared keysyms the way the host delivers them never
// fired, and the client got an `@` instead. Now a binding matches when its
// symbol is the delivered one, or the key's level-one (unshifted) symbol, or —
// for the digits, on layouts whose number row is not digits at level one,
// such as French AZERTY — the key that sits where that digit sits on a US
// keyboard, which is what GNOME and KDE do. Punctuation the layout only
// types shifted (`/` on AZERTY) gets the same US-position fallback, and the
// shifted chord that types it fires the unshifted binding. A binding can
// also name a keycode outright: `code:10`.
package wm

import "core:fmt"
import "core:strings"
import p "palmy:."

KEY_SUPER_L :: 0xffeb
KEY_SUPER_R :: 0xffec
KEY_ISO_LEFT_TAB :: 0xfe20
SUPER_TAP :: 0.4 // s: a Super press released within this, alone, is a tap

// key_codes carries the evdev keycode of each entry of `app.win.input.keys`,
// in the same order, on bare metal (evdev.odin fills it). Nested, palmy only
// hands over symbols, and the keycode is found again through the keymap.
key_codes: [dynamic]u32

// ---------------------------------------------------------------------------
// Real presses and releases (bare metal)
//
// Nested, palmy hands over typed symbols and nothing else, so a key reaches a
// client as a press and release pair re-derived from the symbol. On bare
// metal the keycode, its direction and the xkb state are all known, so the
// client gets what happened: a press when the key goes down, a release when
// it comes up, the modifiers xkb computed after each, and no repeats, because
// wl_keyboard.repeat_info told it to repeat by itself. That is what lets a
// client see a key held down (games, push-to-talk, Shift+click, its own
// repeat rate).
//
// A key the compositor takes (a binding, an open overlay, a VT switch) is
// swallowed whole: its release, and any repeats in between, never reach a
// client either. A key a client got the press of gets its release, even if a
// binding fired in the meantime.
// ---------------------------------------------------------------------------

Key_Ev :: struct {
	code:   u32, // evdev
	time:   u32, // ms, CLOCK_MONOTONIC
	down:   bool,
	repeat: bool,
	idx:    int, // into app.win.input.keys for a press or repeat, else -1
	dep:    u32, // the xkb state after this key
	lat:    u32,
	lock:   u32,
	grp:    u32,
}

// key_evs is this frame's keys in order, presses and releases both. evdev.odin
// fills it on bare metal; nested it stays empty and the old path runs.
key_evs: [dynamic]Key_Ev

Kbd_Wire :: struct {
	sent:      [EV_KEY_MAX + 1]bool, // the focused client has this key's press
	swallowed: [EV_KEY_MAX + 1]bool, // the compositor took this key's press
	dep, lat, lock, grp: u32, // the modifier state last announced
	presses:   int, // counters for the self-test and the log
	releases:  int,
	took:      bool, // the compositor acted on a key since the last frame
}

kbd_wire: Kbd_Wire

// kbd_send_modifiers announces the modifier state on one wl_keyboard: the
// real xkb state on bare metal, the mask derived from palmy's set nested.
kbd_send_modifiers :: proc(s: ^Server, c: ^Client, kb: u32) {
	if session.bare {
		w := &kbd_wire
		event(c, kb, 4, next_serial(s), w.dep, w.lat, w.lock, w.grp)
		return
	}
	event(c, kb, 4, next_serial(s), s.mod_mask, u32(0), u32(0), s.kt.group)
}

// kbd_wire_focus_changed forgets which keys the old focus held. It was sent
// wl_keyboard.leave, which ends every key it had (and its own repeat); the
// new focus is entered with no keys down, so their releases go nowhere.
kbd_wire_focus_changed :: proc() {
	kbd_wire.sent = {}
}

// key_send delivers one press or release to the focused client.
key_send :: proc(s: ^Server, code, t: u32, down: bool) {
	surf := s.kbd_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for kb in surf.client.keyboards {
		event(surf.client, kb, 3, next_serial(s), t, code, u32(down ? 1 : 0))
	}
	if down {
		kbd_wire.presses += 1
	} else {
		kbd_wire.releases += 1
	}
}

// key_send_state announces the xkb state if it changed since last time.
key_send_state :: proc(s: ^Server, dep, lat, lock, grp: u32) {
	w := &kbd_wire
	if dep == w.dep && lat == w.lat && lock == w.lock && grp == w.grp {
		return
	}
	w.dep, w.lat, w.lock, w.grp = dep, lat, lock, grp
	surf := s.kbd_surf
	if surf == nil || surf.client == nil || surf.client.dead {
		return
	}
	for kb in surf.client.keyboards {
		event(surf.client, kb, 4, next_serial(s), dep, lat, lock, grp)
	}
}

// handle_keys_bare is handle_keys for real keys: the same gauntlet in the
// same order, deciding per key whether the compositor or the client has it.
handle_keys_bare :: proc(s: ^Server, app: ^p.App) {
	in_ := &app.win.input
	w := &kbd_wire
	for ke in key_evs {
		code := min(ke.code, EV_KEY_MAX)
		if !ke.down {
			if w.swallowed[code] {
				w.swallowed[code] = false
			} else if w.sent[code] {
				w.sent[code] = false
				key_send(s, ke.code, ke.time, false)
			}
			key_send_state(s, ke.dep, ke.lat, ke.lock, ke.grp)
			continue
		}
		k := in_.keys[ke.idx]
		if ke.repeat {
			// The client repeats keys itself. A repeat only matters here when
			// the compositor owns the key: a held binding or an arrow key in
			// an open overlay.
			if w.swallowed[code] && locker_internal() {
				// Held Backspace in the lock's field.
				w.took = true
				locker_key(s, k)
			} else if w.swallowed[code] && !lock_active() {
				w.took = true
				if !overlays_key(s, app, k, ke.code) {
					wm_shortcut(s, app, k, ke.code)
				}
			}
			continue
		}
		log_line("key code %d sym 0x%x mods %v", ke.code, k.sym, k.mods)

		taken := false
		if vt_switch_key(ke.code, k.mods) {
			taken = true
		} else if lock_active() {
			// The lock screen has the keyboard. The compositor's own takes
			// every key; a client locker's surface gets them as usual. The
			// nested escape hatch (Ctrl+Alt+Q) is not here: on a real
			// session it would let whoever is at the keyboard end the
			// locked person's session.
			if locker_internal() {
				locker_key(s, k)
				taken = true
			}
		} else {
			if k.sym == KEY_SUPER_L || k.sym == KEY_SUPER_R {
				ix.super_armed = true
				ix.super_at = wall_now()
			} else {
				ix.super_armed = false
			}
			taken = overlays_key(s, app, k, ke.code) || wm_shortcut(s, app, k, ke.code)
			if !taken && k.sym != KEY_SUPER_L && k.sym != KEY_SUPER_R {
				ix.typed_at = wall_now()
			}
		}
		if taken {
			w.swallowed[code] = true
			w.took = true
		} else {
			w.sent[code] = true
			key_send(s, ke.code, ke.time, true)
		}
		key_send_state(s, ke.dep, ke.lat, ke.lock, ke.grp)
	}
	clear(&key_evs)

	if lock_active() {
		return
	}
	switcher_mods(s, in_.mods)
	if ix.super_armed && .Super not_in in_.mods {
		ix.super_armed = false
		if wall_now() - ix.super_at <= SUPER_TAP && s.cfg.super_tap && !session.kiosk && s.drag == .None {
			super_tap_fire(s)
		}
	}
}

handle_keys :: proc(s: ^Server, app: ^p.App) {
	if session.bare {
		handle_keys_bare(s, app)
		return
	}
	if overlay_keys(s, app) {
		return
	}
	in_ := &app.win.input
	send_mods(s, mods_mask(s, in_.mods, false))

	for k, i in in_.keys {
		log_line("key sym 0x%x mods %v repeat %v", k.sym, k.mods, k.repeat)
		code := key_code_of(s, k, i)

		// A lone Super tap: armed by Super's own press, disarmed by any
		// other key or a click, fired when Super is let go (below).
		if k.sym == KEY_SUPER_L || k.sym == KEY_SUPER_R {
			if !k.repeat {
				ix.super_armed = true
				ix.super_at = wall_now()
			}
		} else {
			ix.super_armed = false
		}

		if overlays_key(s, app, k, code) {
			continue
		}
		if wm_shortcut(s, app, k, code) {
			continue
		}
		if k.sym != KEY_SUPER_L && k.sym != KEY_SUPER_R {
			ix.typed_at = wall_now()
		}
		forward_key(s, k)
	}

	// Modifier releases: the switcher commits when its modifier is let go,
	// and a Super that went down and up alone opens the overview.
	switcher_mods(s, in_.mods)
	if ix.super_armed && .Super not_in in_.mods {
		ix.super_armed = false
		if wall_now() - ix.super_at <= SUPER_TAP && s.cfg.super_tap && !session.kiosk && s.drag == .None {
			super_tap_fire(s)
		}
	}
}

// key_code_of finds the evdev keycode of the i-th key this frame.
key_code_of :: proc(s: ^Server, k: p.Key_Event, i: int) -> u32 {
	if i < len(key_codes) {
		return key_codes[i]
	}
	if rev, ok := keycode_for(&s.kt, k.sym); ok {
		return rev.code
	}
	return 0
}

// level1_of is the symbol a key types with no modifier, in the layout the
// reverse table was built for.
level1_of :: proc(kt: ^Key_Table, code: u32) -> u32 {
	if code == 0 || !kt.ok {
		return 0
	}
	for sym, rev in kt.rev {
		if rev.code == code && !rev.shift && !rev.level3 {
			return sym
		}
	}
	return 0
}

// us_digit_of is the digit printed on a key on a US keyboard: evdev codes
// 2..11 are the number row, 1 through 9 and then 0.
us_digit_of :: proc(code: u32) -> u32 {
	switch code {
	case 2 ..= 10:
		return '1' + (code - 2)
	case 11:
		return '0'
	}
	return 0
}

// us_punct_of is the punctuation printed on a key on a US keyboard, by evdev
// code. A binding to a symbol the current layout cannot type without Shift
// or AltGr — `$mod, Slash` on French AZERTY, where / is Shift+: — also
// matches the key in the US position, so the default table works on every
// layout (P0-11), as the digits already did.
us_punct_of :: proc(code: u32) -> u32 {
	switch code {
	case 12:
		return '-'
	case 13:
		return '='
	case 26:
		return '['
	case 27:
		return ']'
	case 39:
		return ';'
	case 40:
		return '\''
	case 41:
		return '`'
	case 43:
		return '\\'
	case 51:
		return ','
	case 52:
		return '.'
	case 53:
		return '/'
	}
	return 0
}

// bind_matches_key is the matching rule, pure: a binding's symbol against
// what the key delivered, what it types unshifted, and where it sits.
// `us_ok` says the binding's symbol is not on any key's first level in the
// current layout, so the US position may stand in for it.
bind_matches_key :: proc(b: ^Cfg_Bind, sym, level1, code: u32, us_ok := false) -> bool {
	if b.code != 0 {
		return code != 0 && b.code == code + 8
	}
	if cfg_sym_matches(b.sym, sym) {
		return true
	}
	if level1 != 0 && cfg_sym_matches(b.sym, level1) {
		return true
	}
	// Shift+Tab arrives as ISO_Left_Tab.
	if b.sym == p.KEY_TAB && sym == KEY_ISO_LEFT_TAB {
		return true
	}
	if b.sym >= '0' && b.sym <= '9' {
		if d := us_digit_of(code); d != 0 && d == b.sym {
			return true
		}
	}
	if us_ok && b.sym != 0 {
		if c := us_punct_of(code); c != 0 && cfg_sym_matches(b.sym, c) {
			return true
		}
	}
	return false
}

// bind_shift_consumed says Shift was spent producing the symbol rather than
// meant as a modifier: the binding names exactly what was delivered, and the
// key does not type that unshifted. `$mod, Slash` then fires on AZERTY's
// Super+Shift+: — the chord that types / there — as it does on Super+/ in
// the US position.
bind_shift_consumed :: proc(b: ^Cfg_Bind, sym, level1: u32) -> bool {
	return b.code == 0 && b.sym != 0 && cfg_sym_matches(b.sym, sym) && (level1 == 0 || !cfg_sym_matches(b.sym, level1))
}

// bind_us_ok is bind_matches_key's `us_ok` for the live layout.
bind_us_ok :: proc(kt: ^Key_Table, b: ^Cfg_Bind) -> bool {
	if !kt.ok || b.sym == 0 || b.code != 0 {
		return false
	}
	if b.sym >= 'a' && b.sym <= 'z' || b.sym >= 'A' && b.sym <= 'Z' {
		return false // letters are found by name on every Latin layout
	}
	rev, ok := kt.rev[b.sym]
	return !ok || rev.shift || rev.level3
}

// wm_bind_for prefers a binding whose modifiers match exactly. An `ANY`
// binding is the fallback, so `$mod, F11` and `ANY, F11` can coexist and the
// modified one wins when the modifier is actually held.
wm_bind_for :: proc(s: ^Server, mods: p.Modifiers, sym, code: u32) -> ^Cfg_Bind {
	level1 := level1_of(&s.kt, code)
	fallback, consumed: ^Cfg_Bind
	for &b in s.cfg.binds {
		if !bind_matches_key(&b, sym, level1, code, bind_us_ok(&s.kt, &b)) {
			continue
		}
		if b.any_mods {
			if fallback == nil {
				fallback = &b
			}
			continue
		}
		if b.mods == mods {
			return &b
		}
		if consumed == nil && .Shift in mods && b.mods == mods - {.Shift} && bind_shift_consumed(&b, sym, level1) {
			consumed = &b
		}
	}
	if consumed != nil {
		return consumed
	}
	return fallback
}

// wm_shortcut consults the binding table the configuration produced. It
// returns true when the key was consumed and must not reach the focused
// client.
//
// There is no hardcoded binding left except two: Ctrl+Alt+Q leaves the
// compositor, because a config file that bound nothing at all would
// otherwise be a trap; and Escape cancels a drag, because a drag is the
// compositor's and nothing else can end it.
wm_shortcut :: proc(s: ^Server, app: ^p.App, k: p.Key_Event, code: u32) -> bool {
	if .Alt in k.mods && .Ctrl in k.mods && (k.sym == 'q' || k.sym == 'Q') {
		p.quit_app(app)
		return true
	}
	if s.drag != .None && k.sym == p.KEY_ESCAPE {
		ix_cancel_drag(s)
		return true
	}

	mods := k.mods - {.Caps}
	if b := wm_bind_for(s, mods, k.sym, code); b != nil {
		wm_do(s, app, b^)
		return true
	}

	// Window mode is a sticky layer on top of the table: while it is on the
	// bare arrow keys belong to the compositor rather than to the client.
	if s.wm_mode {
		switch k.sym {
		case p.KEY_LEFT, p.KEY_RIGHT, p.KEY_UP, p.KEY_DOWN:
			nudge(s, k.sym, .Shift in k.mods)
			return true
		case p.KEY_PAGE_UP:
			grow(s, s.cfg.resize_step)
			return true
		case p.KEY_PAGE_DOWN:
			grow(s, -s.cfg.resize_step)
			return true
		case p.KEY_ESCAPE:
			s.wm_mode = false
			toast(s, "window mode off")
			return true
		}
	}
	return false
}

// super_tap_fire is what a lone tap of Super does: the start menu, or the
// overview for `super_tap = overview`. A tap closes whichever is open.
super_tap_fire :: proc(s: ^Server) {
	switch {
	case start.open:
		start_close(s)
	case ov.open:
		overview_toggle(s)
	case s.cfg.super_menu:
		start_open(s)
	case:
		overview_toggle(s)
	}
}

// overlays_key gives each open overlay the key, topmost first.
overlays_key :: proc(s: ^Server, app: ^p.App, k: p.Key_Event, code: u32) -> bool {
	if power_key(s, k) {
		return true
	}
	if menu_key(s, app, k) {
		return true
	}
	if start_key(s, app, k) {
		return true
	}
	if cheat_key(s, app, k, code) {
		return true
	}
	if switcher_key(s, app, k, code) {
		return true
	}
	if overview_key(s, app, k) {
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Names for chords and actions — the one vocabulary (UX.md principle 6) the
// tooltips, the menus and the cheat sheet all print.
// ---------------------------------------------------------------------------

key_name :: proc(sym: u32) -> string {
	for e in CFG_KEYNAMES {
		if e.sym == sym {
			switch e.name {
			case "Prior":
				return "PgUp"
			case "Next":
				return "PgDn"
			case "Escape":
				return "Esc"
			case "Backslash":
				return "\\"
			case "Slash":
				return "/"
			case "Grave":
				return "`"
			case "Super_L", "Super_R":
				return "Super"
			}
			return e.name
		}
	}
	if sym >= 0x21 && sym < 0x7f {
		c := sym
		if c >= 'a' && c <= 'z' {
			c -= 32
		}
		return fmt.tprintf("%c", rune(c))
	}
	return fmt.tprintf("0x%x", sym)
}

chord_parts :: proc(b: ^Cfg_Bind, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, 0, 5, allocator)
	if !b.any_mods {
		if .Super in b.mods {append(&out, "Super")}
		if .Ctrl in b.mods {append(&out, "Ctrl")}
		if .Alt in b.mods {append(&out, "Alt")}
		if .Shift in b.mods {append(&out, "Shift")}
	}
	if b.code != 0 {
		append(&out, fmt.tprintf("code %d", b.code))
	} else {
		append(&out, key_name(b.sym))
	}
	return out[:]
}

chord_text :: proc(b: ^Cfg_Bind) -> string {
	return strings.join(chord_parts(b), "+", context.temp_allocator)
}

// bind_for_act is the first binding for an action (and argument), preferring
// a modified one over a bare function key.
bind_for_act :: proc(s: ^Server, act: Cfg_Act, arg: int) -> ^Cfg_Bind {
	fallback: ^Cfg_Bind
	for &b in s.cfg.binds {
		if b.act != act || b.arg != arg {
			continue
		}
		if !b.any_mods {
			return &b
		}
		if fallback == nil {
			fallback = &b
		}
	}
	return fallback
}

key_for_act :: proc(s: ^Server, act: Cfg_Act, arg: int) -> string {
	if b := bind_for_act(s, act, arg); b != nil {
		return chord_text(b)
	}
	return ""
}

label_with_key :: proc(s: ^Server, label: string, act: Cfg_Act, arg: int) -> string {
	if k := key_for_act(s, act, arg); k != "" {
		return fmt.tprintf("%s  (%s)", label, k)
	}
	return label
}

// bind_human is a binding's action in words: "Move window to workspace 3",
// not `movetoworkspace 3`.
bind_human :: proc(b: ^Cfg_Bind) -> string {
	dir_word :: proc(arg: int) -> string {
		switch Cfg_Dir(arg) {
		case .Left:
			return "left"
		case .Right:
			return "right"
		case .Up:
			return "up"
		case .Down:
			return "down"
		}
		return ""
	}
	switch b.act {
	case .None:
		return "Nothing"
	case .Spawn:
		if len(b.argv) > 0 {
			return fmt.tprintf("Open %s", b.argv[0])
		}
		return "Run a command"
	case .Close:
		return "Close window"
	case .Focus_Next:
		return "Focus next window"
	case .Focus_Prev:
		return "Focus previous window"
	case .Focus_Dir:
		return fmt.tprintf("Focus window %s", dir_word(b.arg))
	case .Move_Dir:
		return fmt.tprintf("Move window %s", dir_word(b.arg))
	case .Resize_Dir:
		return fmt.tprintf("Resize window %s", dir_word(b.arg))
	case .Toggle_Float:
		return "Float or tile window"
	case .Toggle_Maximize:
		return "Maximize or restore"
	case .Minimize:
		return "Minimize window"
	case .Toggle_Tiling:
		return "Tile or float workspace"
	case .Next_Layout:
		return "Next layout"
	case .Master_Ratio:
		return b.arg < 0 ? "Narrow master column" : "Widen master column"
	case .Master_Count:
		return b.arg < 0 ? "Fewer master windows" : "More master windows"
	case .Swap_Master:
		return "Make window master"
	case .Workspace:
		return fmt.tprintf("Workspace %d", b.arg)
	case .Workspace_Rel:
		return b.arg < 0 ? "Previous workspace" : "Next workspace"
	case .Move_To_Workspace:
		return fmt.tprintf("Move window to workspace %d", b.arg)
	case .Move_To_Workspace_Follow:
		return fmt.tprintf("Take window to workspace %d", b.arg)
	case .Move_To_Workspace_Rel:
		return b.arg < 0 ? "Move window to previous workspace" : "Move window to next workspace"
	case .Cascade:
		return "Cascade windows"
	case .Window_Mode:
		return "Window mode (arrows move)"
	case .Reload:
		return "Reload configuration"
	case .Quit:
		return "Quit the compositor"
	case .Session:
		return fmt.tprintf("Session: %s", cfg_session_name(b.arg))
	case .Snap_Dir:
		switch Cfg_Dir(b.arg) {
		case .Left:
			return "Snap left"
		case .Right:
			return "Snap right"
		case .Up:
			return "Maximize / snap up"
		case .Down:
			return "Restore / minimize"
		}
	case .Toggle_Fullscreen:
		return "Fullscreen"
	case .Toggle_On_Top:
		return "Always on top"
	case .Toggle_Sticky:
		return "Show on all workspaces"
	case .Lower:
		return "Lower window"
	case .Switcher:
		return b.arg == 1 ? "Switch windows (all workspaces)" : "Switch windows"
	case .Overview:
		return "Overview"
	case .Cheat_Sheet:
		return "Keyboard shortcuts"
	case .Window_Menu:
		return "Window menu"
	case .Debug_Hud:
		return "Debug overlay"
	}
	return b.label
}

// bind_group is the cheat sheet's heading for an action.
bind_group :: proc(act: Cfg_Act) -> string {
	switch act {
	case .Close, .Toggle_Float, .Toggle_Maximize, .Minimize, .Snap_Dir, .Toggle_Fullscreen, .Toggle_On_Top, .Toggle_Sticky, .Lower, .Window_Menu, .Move_Dir, .Resize_Dir, .Window_Mode:
		return "Windows"
	case .Focus_Next, .Focus_Prev, .Focus_Dir, .Switcher, .Overview:
		return "Focus"
	case .Workspace, .Workspace_Rel, .Move_To_Workspace, .Move_To_Workspace_Follow, .Move_To_Workspace_Rel:
		return "Workspaces"
	case .Toggle_Tiling, .Next_Layout, .Master_Ratio, .Master_Count, .Swap_Master, .Cascade:
		return "Layout"
	case .Spawn:
		return "Launch"
	case .Reload, .Quit, .Session, .Cheat_Sheet, .Debug_Hud, .None:
		return "Session"
	}
	return "Session"
}
