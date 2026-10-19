// Who an identity is, as far as this device knows: its display name and its
// colour, so a toast can say "● Northwind" in Northwind's blue.
//
// The registry is $XDG_CONFIG_HOME/palmy/identities.json, the same seam
// apps/browser reads (profile.odin: registry_color):
//
//	[{"handle": "camille.roux", "name": "Northwind", "color": "blue"}, ...]
//
// `color` is a palette name (public.identities.color) or "#rrggbb". When an
// identity is not in the file its handle is the name and the colour comes
// from a hash of the handle, so the same identity always gets the same
// colour on every surface even before Accounts has written the file.
package main

import "core:encoding/json"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

Ident :: struct {
	handle: string,
	name:   string,
	color:  string, // palette name or #hex
}

g_idents: [dynamic]Ident
g_idents_loaded: bool

identities_path :: proc() -> string {
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {
		cfg = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	return fmt.tprintf("%s/palmy/identities.json", cfg)
}

identities_reload :: proc() {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	for x in g_idents {
		delete(x.handle)
		delete(x.name)
		delete(x.color)
	}
	clear(&g_idents)
	g_idents_loaded = true
	data, err := os.read_entire_file(identities_path(), context.temp_allocator)
	if err != nil {
		return
	}
	Entry :: struct {
		handle: string,
		name:   string,
		display_name: string,
		color:  string,
	}
	entries: []Entry
	if json.unmarshal(data, &entries, allocator = context.temp_allocator) != nil {
		return
	}
	for e in entries {
		if e.handle == "" {
			continue
		}
		name := e.name != "" ? e.name : e.display_name
		append(&g_idents, Ident{strings.clone(e.handle), strings.clone(name != "" ? name : e.handle), strings.clone(e.color)})
	}
}

// identities_set replaces the registry in memory (the screenshots and the
// self-test use invented identities and must not read the user's).
identities_set :: proc(xs: []Ident) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	for x in g_idents {
		delete(x.handle)
		delete(x.name)
		delete(x.color)
	}
	clear(&g_idents)
	for x in xs {
		append(&g_idents, Ident{strings.clone(x.handle), strings.clone(x.name), strings.clone(x.color)})
	}
	g_idents_loaded = true
	g_idents_fixed = true
}

g_idents_fixed: bool // set by identities_set: the screenshots' invented ones
g_idents_mtime: i64
g_idents_checked: i64

// identities_changed notices Accounts rewriting the registry during a
// session, looking at the file at most every two seconds.
identities_changed :: proc() -> bool {
	if g_idents_fixed {
		return false
	}
	now := time.to_unix_nanoseconds(time.now())
	if now - g_idents_checked < 2_000_000_000 {
		return false
	}
	g_idents_checked = now
	mt := i64(0)
	if fi, err := os.stat(identities_path(), context.temp_allocator); err == nil {
		mt = time.to_unix_nanoseconds(fi.modification_time)
	}
	if mt == g_idents_mtime {
		return false
	}
	g_idents_mtime = mt
	return true
}

identity_lookup :: proc(handle: string) -> (Ident, bool) {
	if !g_idents_loaded || identities_changed() {
		identities_reload()
	}
	for x in g_idents {
		if x.handle == handle || strings.equal_fold(x.name, handle) {
			return x, true
		}
	}
	return {}, false
}

identity_name :: proc(handle: string) -> string {
	if handle == "" {
		return ""
	}
	if x, ok := identity_lookup(handle); ok {
		return x.name
	}
	// "alex.northwind" reads better as "Northwind" than as a handle, but
	// guessing is worse than showing what we have.
	return handle
}

// The palette, light and dark, as apps/home draws identities.
PALETTE := [?]struct {
	name:  string,
	light: u32,
	dark:  u32,
}{
	{"indigo", 0x4f46e5, 0x818cf8},
	{"blue", 0x2563eb, 0x60a5fa},
	{"teal", 0x0f9488, 0x2dd4bf},
	{"emerald", 0x059669, 0x34d399},
	{"amber", 0xc2620a, 0xfbbf24},
	{"rose", 0xe11d48, 0xfb7185},
	{"violet", 0x7c3aed, 0xa78bfa},
	{"sky", 0x0284c7, 0x38bdf8},
	{"orange", 0xea580c, 0xfb923c},
	{"pink", 0xdb2777, 0xf472b6},
	{"green", 0x16a34a, 0x4ade80},
	{"cyan", 0x0891b2, 0x22d3ee},
	{"red", 0xdc2626, 0xf87171},
	{"purple", 0x9333ea, 0xc084fc},
	{"fuchsia", 0xc026d3, 0xe879f9},
	{"lime", 0x65a30d, 0xa3e635},
	{"yellow", 0xca8a04, 0xfacc15},
	{"slate", 0x475569, 0x94a3b8},
	{"gray", 0x4b5563, 0x9ca3af},
	{"zinc", 0x52525b, 0xa1a1aa},
	{"neutral", 0x525252, 0xa3a3a3},
	{"stone", 0x57534e, 0xa8a29e},
}

parse_hex :: proc(s: string) -> (u32, bool) {
	if len(s) != 7 || s[0] != '#' {
		return 0, false
	}
	v: u32
	for ch in s[1:] {
		d: u32
		switch ch {
		case '0' ..= '9':
			d = u32(ch - '0')
		case 'a' ..= 'f':
			d = u32(ch - 'a' + 10)
		case 'A' ..= 'F':
			d = u32(ch - 'A' + 10)
		case:
			return 0, false
		}
		v = v * 16 + d
	}
	return v, true
}

// identity_color is the identity's colour for the theme in use.
identity_color :: proc(handle: string, dark: bool) -> u32 {
	if handle == "" {
		return dark ? 0xa1a1aa : 0x71717a
	}
	name := ""
	if x, ok := identity_lookup(handle); ok {
		if v, hex := parse_hex(x.color); hex {
			return v
		}
		name = x.color
	}
	for c in PALETTE {
		if c.name == name {
			return dark ? c.dark : c.light
		}
	}
	h: u32 = 2166136261
	for b in transmute([]u8)handle {
		h = (h ~ u32(b)) * 16777619
	}
	c := PALETTE[h % 8] // the first eight are the distinct ones
	return dark ? c.dark : c.light
}

// identity_handles is every identity the device knows, in registry order.
identity_handles :: proc(allocator := context.temp_allocator) -> []string {
	if !g_idents_loaded || identities_changed() {
		identities_reload()
	}
	out := make([]string, len(g_idents), allocator)
	for x, i in g_idents {
		out[i] = x.handle
	}
	return out
}
