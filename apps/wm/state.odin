// state.odin — what the window manager tells other programs about itself.
//
// Settings (apps/settings) shows the displays and the keyboard layout as the
// compositor has them, which only the compositor knows: the heads it found,
// their modes and logical layout, the layout it compiled and why. Rather than
// a socket protocol for two readers, the wm writes one small JSON file
// whenever any of that changes:
//
//     $XDG_RUNTIME_DIR/palmy-wm.json
//
//     {"pid": 812, "display": "wayland-1", "bare": true,
//      "config": "/home/palm/.config/palmy/wm.conf",
//      "keyboard": {"layout": "fr", "file": "/etc/palm/keyboard", ...},
//      "outputs": [{"name": "Virtual-1", "description": "...",
//                   "x": 0, "y": 0, "width": 1280, "height": 800,
//                   "mode_width": 1280, "mode_height": 800,
//                   "refresh_mhz": 60000, "scale": 1,
//                   "physical_mm": [0, 0]}]}
//
// The other direction — Settings changing something — is wm.conf (and the
// keyboard file), which the wm already re-reads within a second of a save.
// Written to a temporary name and renamed, so a reader never sees half.
package wm

import "core:fmt"
import "core:os"
import "core:strings"

@(private = "file")
state_sig: string

state_path :: proc() -> string {
	rt := os.get_env("XDG_RUNTIME_DIR", context.temp_allocator)
	if rt == "" {
		return ""
	}
	return fmt.tprintf("%s/palmy-wm.json", rt)
}

state_publish :: proc(s: ^Server) {
	path := state_path()
	if path == "" {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	q :: proc(b: ^strings.Builder, v: string) {
		strings.write_byte(b, '"')
		for c in v {
			switch c {
			case '"':
				strings.write_string(b, `\"`)
			case '\\':
				strings.write_string(b, `\\`)
			case '\n':
				strings.write_string(b, `\n`)
			case:
				if c < 0x20 {
					fmt.sbprintf(b, `\u%04x`, int(c))
				} else {
					strings.write_rune(b, c)
				}
			}
		}
		strings.write_byte(b, '"')
	}
	strings.write_string(&b, `{"display": `)
	q(&b, s.display_name)
	fmt.sbprintf(&b, `, "bare": %v, "config": `, session.bare)
	q(&b, s.cfg.path)
	strings.write_string(&b, `, "keyboard": {"layout": `)
	q(&b, kbd.label)
	strings.write_string(&b, `, "rmlvo": `)
	q(&b, kbd_describe(kbd.current))
	strings.write_string(&b, `, "from": `)
	q(&b, kbd.origin)
	strings.write_string(&b, `, "file": `)
	q(&b, kbd_conf_path())
	fmt.sbprintf(&b, `, "fell_back": %v}`, kbd.fell_back)
	strings.write_string(&b, `, "outputs": [`)
	if len(out_list) > 0 {
		for o, i in out_list {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, `{"name": `)
			q(&b, o.name)
			strings.write_string(&b, `, "description": `)
			q(&b, o.desc)
			strings.write_string(&b, `, "make": `)
			q(&b, o.vendor)
			strings.write_string(&b, `, "model": `)
			q(&b, o.model)
			fmt.sbprintf(
				&b,
				`, "x": %d, "y": %d, "width": %d, "height": %d, "mode_width": %d, "mode_height": %d, "refresh_mhz": %d, "scale": %d, "physical_mm": [%d, %d], "fallback": %v}`,
				o.x, o.y, o.w, o.h, o.mode_w, o.mode_h, o.refresh, o.scale, o.pw, o.ph, o.fallback,
			)
		}
	} else {
		for o, i in s.outputs {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_string(&b, `{"name": `)
			q(&b, o.name)
			fmt.sbprintf(&b, `, "x": %d, "y": %d, "width": %d, "height": %d, "scale": %d, "nested": %v}`, o.x, o.y, o.w, o.h, int(o.scale), o.host)
		}
	}
	strings.write_string(&b, "]")
	body := strings.to_string(b)
	if body == state_sig {
		return
	}
	delete(state_sig)
	state_sig = strings.clone(body)
	// Concatenated, not formatted: fmt reads a brace as the start of a verb.
	text := strings.concatenate({"{", fmt.tprintf("\"pid\": %d, ", os.get_pid()), body[1:], "}\n"}, context.temp_allocator)
	tmp := fmt.tprintf("%s.tmp", path)
	if os.write_entire_file(tmp, transmute([]byte)text) == nil {
		os.rename(tmp, path)
	}
}
