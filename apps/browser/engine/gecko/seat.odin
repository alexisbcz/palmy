// The seat: the chrome's input, delivered to Firefox as a pointer and a
// keyboard.
//
// The keyboard is the interesting half. The chrome sends keysyms -- what the
// person's own layout produced -- not hardware key codes, and Firefox, as a
// Wayland client, only understands key codes interpreted through a keymap.
// So this host writes the keymap: every keysym it is asked to type gets a key
// code of its own, and when a new one appears the keymap is extended and sent
// again (the trick wtype uses). Any character in any script can be typed this
// way, with no layout to agree on.
package gecko

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import pb "../../pb"

KEY_FIRST :: 9
KEY_LAST :: 255

Keymap :: struct {
	syms:   [256]u32, // xkb key code -> keysym, 0 when free
	next:   int,
	dirty:  bool,
}

km: Keymap
cur_mods: u32
pointer_x, pointer_y: f32
buttons_down: int
cursor_cb: proc(c: pb.Page_Cursor)

// the four modifier keys always exist, at their usual evdev places
MOD_KEYS := [?]struct {
	code: int,
	sym:  u32,
	mod:  string,
}{{50, 0xffe1, "Shift"}, {37, 0xffe3, "Control"}, {64, 0xffe9, "Mod1"}, {133, 0xffeb, "Mod4"}}

keymap_reset :: proc() {
	km = {}
	for m in MOD_KEYS {
		km.syms[m.code] = m.sym
	}
	km.next = KEY_FIRST
	km.dirty = true
}

keycode_for :: proc(sym: u32) -> int {
	for code in KEY_FIRST ..= KEY_LAST {
		if km.syms[code] == sym {
			return code
		}
	}
	for {
		if km.next > KEY_LAST {
			// full: start over, keeping the modifiers
			keymap_reset()
		}
		code := km.next
		km.next += 1
		if km.syms[code] == 0 {
			km.syms[code] = sym
			km.dirty = true
			return code
		}
	}
}

keymap_text :: proc(allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	strings.write_string(&sb, "xkb_keymap {\nxkb_keycodes \"palm\" {\n minimum = 8;\n maximum = 255;\n")
	for code in 8 ..= 255 {
		fmt.sbprintf(&sb, " <K%d> = %d;\n", code, code)
	}
	strings.write_string(&sb, "};\nxkb_types \"palm\" { include \"complete\" };\n")
	strings.write_string(&sb, "xkb_compatibility \"palm\" { include \"complete\" };\n")
	strings.write_string(&sb, "xkb_symbols \"palm\" {\n")
	for code in 8 ..= 255 {
		if km.syms[code] != 0 {
			fmt.sbprintf(&sb, " key <K%d> {{ [ 0x%x ] }};\n", code, km.syms[code])
		}
	}
	for m in MOD_KEYS {
		fmt.sbprintf(&sb, " modifier_map %s {{ <K%d> }};\n", m.mod, m.code)
	}
	strings.write_string(&sb, "};\n};\n")
	return strings.to_string(sb)
}

send_keymap :: proc(c: ^Client, kbd: u32) {
	text := keymap_text()
	if path := os.get_env("PALM_GECKO_DUMP_KEYMAP", context.temp_allocator); path != "" {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}
	size := len(text) + 1
	fd, err := linux.memfd_create("palm-keymap", {.CLOEXEC})
	if err != .NONE {
		return
	}
	buf := make([]u8, size, context.temp_allocator)
	copy(buf, text)
	linux.write(fd, buf)
	event(c, kbd, 0, u32(1), Fd(fd), u32(size))
}

keyboard_init :: proc(c: ^Client, kbd: u32, version: u32) {
	if km.next == 0 {
		keymap_reset()
	}
	send_keymap(c, kbd)
	if version >= 4 {
		event(c, kbd, 5, i32(0), i32(0)) // no client-side repeat: the chrome repeats
	}
	if g.kbd_focus != nil {
		g.serial += 1
		event(c, kbd, 1, g.serial, g.kbd_focus.id, []u8{})
		event(c, kbd, 4, g.serial, cur_mods, u32(0), u32(0), u32(0))
	}
}

keymap_flush :: proc(c: ^Client) {
	if !km.dirty {
		return
	}
	km.dirty = false
	for k in c.keyboards {
		send_keymap(c, k)
	}
}

xkb_mods :: proc(m: u32) -> u32 {
	r: u32
	if m & pb.MOD_SHIFT != 0 {r |= 1}
	if m & pb.MOD_CTRL != 0 {r |= 4}
	if m & pb.MOD_ALT != 0 {r |= 8}
	if m & pb.MOD_SUPER != 0 {r |= 64}
	return r
}

keyboard_focus_update :: proc(c: ^Client) {
	if c == nil {
		return
	}
	want: ^Surface
	if g.focused {
		#reverse for p in g.popups {
			if p.grab && p.surface != nil && p.surface.mapped {
				want = p.surface
				break
			}
		}
		if want == nil && g.toplevel != nil && g.toplevel.surface != nil && g.toplevel.surface.mapped {
			want = g.toplevel.surface
		}
	}
	if want == g.kbd_focus {
		return
	}
	if g.kbd_focus != nil {
		g.serial += 1
		for k in c.keyboards {
			event(c, k, 2, g.serial, g.kbd_focus.id)
		}
	}
	g.kbd_focus = want
	if want != nil {
		g.serial += 1
		for k in c.keyboards {
			event(c, k, 1, g.serial, want.id, []u8{})
			event(c, k, 4, g.serial, xkb_mods(cur_mods), u32(0), u32(0), u32(0))
		}
	}
}

set_mods :: proc(c: ^Client, m: u32) {
	if m == cur_mods {
		return
	}
	cur_mods = m
	g.serial += 1
	for k in c.keyboards {
		event(c, k, 4, g.serial, xkb_mods(m), u32(0), u32(0), u32(0))
	}
}

// key_event types one key. Down and up are separate so a held key could be
// expressed, though the chrome sends them as a pair.
key_event :: proc(c: ^Client, kind: pb.Key_Kind, mods: u32, sym: u32, cp: u32) {
	if g.kbd_focus == nil {
		keyboard_focus_update(c)
		if g.kbd_focus == nil {
			return
		}
	}
	use := sym
	if kind == .Char || use == 0 {
		use = pb.rune_keysym(rune(cp))
	}
	code := keycode_for(use)
	keymap_flush(c)
	t := u32(now_ms() - g.start_ms)
	switch kind {
	case .Down:
		set_mods(c, mods)
		g.serial += 1
		for k in c.keyboards {
			event(c, k, 3, g.serial, t, u32(code - 8), u32(1))
		}
	case .Up:
		g.serial += 1
		for k in c.keyboards {
			event(c, k, 3, g.serial, t, u32(code - 8), u32(0))
		}
	case .Char:
		set_mods(c, 0)
		for state in ([2]u32{1, 0}) {
			g.serial += 1
			for k in c.keyboards {
				event(c, k, 3, g.serial, t, u32(code - 8), state)
			}
		}
	}
}

// type_text types a string, one character at a time; how a paste reaches a
// page whose clipboard is not the system's.
type_text :: proc(c: ^Client, text: string) {
	for r in text {
		key_event(c, .Char, 0, 0, u32(r))
	}
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

// surface_at finds the topmost surface under a point (logical, view
// coordinates): popups first, then the toplevel tree, children above parents.
surface_at :: proc(x, y: f32) -> ^Surface {
	#reverse for p in g.popups {
		if p.surface != nil {
			if s := hit_tree(p.surface, x, y); s != nil {
				return s
			}
		}
	}
	if g.toplevel != nil && g.toplevel.surface != nil {
		return hit_tree(g.toplevel.surface, x, y)
	}
	return nil
}

@(private = "file")
hit_tree :: proc(s: ^Surface, x, y: f32) -> ^Surface {
	if !s.mapped || s.destroyed {
		return nil
	}
	#reverse for ch in s.children {
		if h := hit_tree(ch, x, y); h != nil {
			return h
		}
	}
	ox, oy := surface_origin(s)
	sc := f32(max(s.scale, 1))
	w := f32(s.w) / sc
	h := f32(s.h) / sc
	if x >= f32(ox) && y >= f32(oy) && x < f32(ox) + w && y < f32(oy) + h {
		return s
	}
	return nil
}

in_popup :: proc(s: ^Surface) -> bool {
	at := s
	for at != nil {
		if at.role == .Popup {
			return true
		}
		at = at.parent
	}
	return false
}

pointer_motion :: proc(c: ^Client, x, y: f32, leave := false) {
	pointer_x, pointer_y = x, y
	target: ^Surface
	if !leave {
		target = buttons_down > 0 && g.pointer_focus != nil ? g.pointer_focus : surface_at(x, y)
	}
	if target != g.pointer_focus {
		if g.pointer_focus != nil {
			g.serial += 1
			for p in c.pointers {
				event(c, p, 1, g.serial, g.pointer_focus.id)
				event(c, p, 5)
			}
		}
		g.pointer_focus = target
		if target != nil {
			ox, oy := surface_origin(target)
			g.serial += 1
			for p in c.pointers {
				event(c, p, 0, g.serial, target.id, fixed(x - f32(ox)), fixed(y - f32(oy)))
				event(c, p, 5)
			}
		}
	}
	if target != nil {
		ox, oy := surface_origin(target)
		t := u32(now_ms() - g.start_ms)
		for p in c.pointers {
			event(c, p, 2, t, fixed(x - f32(ox)), fixed(y - f32(oy)))
			event(c, p, 5)
		}
	}
}

BTN_LEFT :: u32(0x110)
BTN_RIGHT :: u32(0x111)
BTN_MIDDLE :: u32(0x112)

pointer_button :: proc(c: ^Client, button: pb.Button, down: bool, x, y: f32) {
	code := button == .Right ? BTN_RIGHT : button == .Middle ? BTN_MIDDLE : BTN_LEFT
	if down {
		target := surface_at(x, y)
		// a click outside an open popup closes it and goes no further
		if len(g.popups) > 0 && (target == nil || !in_popup(target)) {
			dismiss_popups(c)
			return
		}
		pointer_motion(c, x, y)
		buttons_down += 1
	} else {
		if buttons_down == 0 {
			return
		}
		buttons_down -= 1
	}
	if g.pointer_focus == nil {
		return
	}
	t := u32(now_ms() - g.start_ms)
	g.serial += 1
	for p in c.pointers {
		event(c, p, 3, g.serial, t, code, u32(down ? 1 : 0))
		event(c, p, 5)
	}
	if !down && buttons_down == 0 {
		pointer_motion(c, x, y)
	}
}

pointer_axis :: proc(c: ^Client, x, y: f32, dx, dy: f32) {
	pointer_motion(c, x, y)
	if g.pointer_focus == nil {
		return
	}
	t := u32(now_ms() - g.start_ms)
	// the chrome sends Blink's convention (up positive, ~60 a notch);
	// Wayland's is down positive in surface pixels, ~15 a notch
	vy := -dy / 4
	vx := -dx / 4
	for p in c.pointers {
		ver := c.objects[p].version
		if ver >= 5 {
			event(c, p, 6, u32(0)) // source: wheel
		}
		if vy != 0 {
			if ver >= 5 {
				steps := i32(vy / 15)
				if steps == 0 {steps = vy > 0 ? 1 : -1}
				event(c, p, 8, u32(0), steps)
			}
			event(c, p, 4, t, u32(0), fixed(vy))
		}
		if vx != 0 {
			if ver >= 5 {
				steps := i32(vx / 15)
				if steps == 0 {steps = vx > 0 ? 1 : -1}
				event(c, p, 8, u32(1), steps)
			}
			event(c, p, 4, t, u32(1), fixed(vx))
		}
		if ver >= 5 {
			event(c, p, 5)
		}
	}
}

dismiss_popups :: proc(c: ^Client) {
	for len(g.popups) > 0 {
		p := pop(&g.popups)
		event(c, p.role_id, 1) // popup_done
		if p.surface != nil {
			p.surface.mapped = false
		}
	}
	damage_all()
	keyboard_focus_update(c)
}

cursor_shape :: proc(shape: u32) {
	c: pb.Page_Cursor = .Default
	switch shape {
	case 4:
		c = .Pointer
	case 9, 10:
		c = .Text
	case 5, 6:
		c = .Wait
	case 8, 7:
		c = .Crosshair
	case 13, 34:
		c = .Move
	case 14, 15:
		c = .Not_Allowed
	case 16, 17:
		c = .Grab
	case 18, 22, 26, 32:
		c = .EW_Resize
	case 19, 23, 27, 33:
		c = .NS_Resize
	}
	if cursor_cb != nil {
		cursor_cb(c)
	}
}
