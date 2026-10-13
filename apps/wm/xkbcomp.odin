// An XKB keymap, originated rather than borrowed.
//
// xkbmap.odin solves the nested problem: the host hands us a keymap string and
// we reparse it. On bare metal there is no host to ask, and `wl_keyboard.keymap`
// still has to hand every client an fd containing a keymap in `xkb_keymap { }`
// format or none of them will have a keyboard at all.
//
// So this file compiles one. It reads the system XKB data under
// /usr/share/X11/xkb -- the same files libxkbcommon reads -- resolves the
// rules file down to a set of components, follows the include graph through
// keycodes, types, compat and symbols, and produces two things:
//
//   1. in-memory tables that turn a keycode plus a modifier state into a
//      keysym, with levels, groups and locking modifiers, and
//   2. the text of a keymap, which is what goes in the fd.
//
// Both come out of the same parse, so what a client is told the keyboard does
// and what the compositor thinks it does cannot drift apart.
//
// When /usr/share/X11/xkb is missing -- an initramfs, a container, a machine
// where somebody uninstalled xkeyboard-config -- there is a hardcoded US
// keymap at the bottom of this file, compiled through the same path. The
// compositor is never left with a dead keyboard.
//
// Not implemented, deliberately and stated rather than faked: Compose
// sequences and dead-key composition. Dead keysyms resolve and are delivered
// (a French layout's dead_circumflex arrives as dead_circumflex); what is
// missing is the table that turns dead_circumflex followed by `e` into
// ecircumflex. Clients that run their own Compose (GTK, Qt, anything using
// xkbcommon-compose) are unaffected, because they do that from the keymap we
// hand them. See the report.
package wm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import p "palmy:."

XKB_MAX_GROUPS :: 4
XKB_MAX_LEVELS :: 8
XKB_MIN_KEYCODE :: 8
XKB_MAX_KEYCODE :: 255
XKB_KEYCODE_SPAN :: 768 // evdev codes go to KEY_MAX, 0x2ff

// Real modifier bits, in the order the protocol numbers them.
XKB_MOD_SHIFT :: u32(1 << 0)
XKB_MOD_LOCK :: u32(1 << 1)
XKB_MOD_CONTROL :: u32(1 << 2)
XKB_MOD_MOD1 :: u32(1 << 3)
XKB_MOD_MOD2 :: u32(1 << 4)
XKB_MOD_MOD3 :: u32(1 << 5)
XKB_MOD_MOD4 :: u32(1 << 6)
XKB_MOD_MOD5 :: u32(1 << 7)

XKB_SYM_NO :: u32(0)
XKB_SYM_VOID :: u32(0x00ffffff)
XKB_SYM_CAPS_LOCK :: u32(0xffe5)
XKB_SYM_SHIFT_LOCK :: u32(0xffe6)
XKB_SYM_NUM_LOCK :: u32(0xff7f)
XKB_SYM_ISO_NEXT_GROUP :: u32(0xfe08)
XKB_SYM_ISO_PREV_GROUP :: u32(0xfe0a)
XKB_SYM_MODE_SWITCH :: u32(0xff7e)

// ---------------------------------------------------------------------------
// Lexer
//
// All five XKB component languages share one syntax: brace-nested statements,
// `<KEYNAME>` atoms, quoted strings, C comments. One lexer serves them all,
// and the section-specific interpreters below run over its tokens.
// ---------------------------------------------------------------------------

Xkb_Tok_Kind :: enum u8 {
	End,
	Ident,
	Str,
	Num,
	Key,
	Punct,
}

Xkb_Tok :: struct {
	kind: Xkb_Tok_Kind,
	text: string, // for Str, without the quotes; for Key, without the angles
	pos:  int,
	end:  int,
}

xkb_is_ident_start :: proc(c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'
}
xkb_is_ident :: proc(c: u8) -> bool {
	return xkb_is_ident_start(c) || (c >= '0' && c <= '9')
}
xkb_is_digit :: proc(c: u8) -> bool {return c >= '0' && c <= '9'}

xkb_lex :: proc(src: string, allocator := context.allocator) -> []Xkb_Tok {
	toks := make([dynamic]Xkb_Tok, allocator)
	i := 0
	n := len(src)
	for i < n {
		c := src[i]
		switch {
		case c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v':
			i += 1
		case c == '\\' && i + 1 < n && src[i + 1] == '\n':
			i += 2
		case c == '/' && i + 1 < n && src[i + 1] == '/':
			for i < n && src[i] != '\n' {i += 1}
		case c == '#':
			for i < n && src[i] != '\n' {i += 1}
		case c == '/' && i + 1 < n && src[i + 1] == '*':
			i += 2
			for i + 1 < n && !(src[i] == '*' && src[i + 1] == '/') {i += 1}
			i = min(i + 2, n)
		case c == '"':
			start := i
			i += 1
			b := strings.builder_make(allocator)
			for i < n && src[i] != '"' {
				if src[i] == '\\' && i + 1 < n {
					i += 1
					switch src[i] {
					case 'n':
						strings.write_byte(&b, '\n')
					case 't':
						strings.write_byte(&b, '\t')
					case:
						strings.write_byte(&b, src[i])
					}
				} else {
					strings.write_byte(&b, src[i])
				}
				i += 1
			}
			i = min(i + 1, n)
			append(&toks, Xkb_Tok{kind = .Str, text = strings.to_string(b), pos = start, end = i})
		case c == '<':
			start := i
			i += 1
			s := i
			for i < n && src[i] != '>' {i += 1}
			name := src[s:i]
			i = min(i + 1, n)
			append(&toks, Xkb_Tok{kind = .Key, text = name, pos = start, end = i})
		case xkb_is_ident_start(c):
			s := i
			for i < n && xkb_is_ident(src[i]) {i += 1}
			append(&toks, Xkb_Tok{kind = .Ident, text = src[s:i], pos = s, end = i})
		case xkb_is_digit(c):
			s := i
			if c == '0' && i + 1 < n && (src[i + 1] == 'x' || src[i + 1] == 'X') {
				i += 2
				for i < n && (xkb_is_digit(src[i]) || (src[i] | 0x20 >= 'a' && src[i] | 0x20 <= 'f')) {i += 1}
			} else {
				for i < n && (xkb_is_digit(src[i]) || src[i] == '.') {i += 1}
			}
			append(&toks, Xkb_Tok{kind = .Num, text = src[s:i], pos = s, end = i})
		case:
			append(&toks, Xkb_Tok{kind = .Punct, text = src[i:i + 1], pos = i, end = i + 1})
			i += 1
		}
	}
	append(&toks, Xkb_Tok{kind = .End, pos = n, end = n})
	return toks[:]
}

Xkb_Src :: struct {
	path: string,
	src:  string,
	toks: []Xkb_Tok,
}

xkb_src_cache: map[string]^Xkb_Src

xkb_root :: proc() -> string {
	if v := os.get_env("XKB_CONFIG_ROOT", context.temp_allocator); v != "" {
		return v
	}
	return "/usr/share/X11/xkb"
}

xkb_src_load :: proc(dir, file: string) -> (^Xkb_Src, bool) {
	path := fmt.tprintf("%s/%s/%s", xkb_root(), dir, file)
	if s, ok := xkb_src_cache[path]; ok {
		return s, s != nil
	}
	data, rok := ev_read_file(path)
	if !rok {
		xkb_src_cache[strings.clone(path)] = nil
		return nil, false
	}
	s := new(Xkb_Src)
	s.path = strings.clone(path)
	s.src = data
	s.toks = xkb_lex(s.src)
	xkb_src_cache[s.path] = s
	return s, true
}

// xkb_section finds `xkb_<kind> "name" { ... }` and returns the token range of
// its body. An empty name takes the section flagged `default`, or the first.
xkb_section :: proc(s: ^Xkb_Src, kind: string, name: string) -> (lo, hi: int, ok: bool) {
	best_lo, best_hi := -1, -1
	for i := 0; i < len(s.toks); i += 1 {
		t := s.toks[i]
		if t.kind != .Ident || t.text != kind {
			continue
		}
		j := i + 1
		sect_name := ""
		if j < len(s.toks) && s.toks[j].kind == .Str {
			sect_name = s.toks[j].text
			j += 1
		}
		if j >= len(s.toks) || s.toks[j].kind != .Punct || s.toks[j].text != "{" {
			continue
		}
		// Match the braces.
		depth := 0
		k := j
		for k < len(s.toks) {
			if s.toks[k].kind == .Punct {
				if s.toks[k].text == "{" {depth += 1} else if s.toks[k].text == "}" {
					depth -= 1
					if depth == 0 {break}
				}
			}
			k += 1
		}
		body_lo, body_hi := j + 1, k

		if name != "" {
			if strings.equal_fold(sect_name, name) {
				return body_lo, body_hi, true
			}
			continue
		}
		// Is this the default section? The flags sit before the keyword.
		is_default := false
		for b := i - 1; b >= 0; b -= 1 {
			bt := s.toks[b]
			if bt.kind != .Ident {
				break
			}
			if bt.text == "default" {
				is_default = true
				break
			}
		}
		if is_default {
			return body_lo, body_hi, true
		}
		if best_lo < 0 {
			best_lo, best_hi = body_lo, body_hi
		}
	}
	if name == "" && best_lo >= 0 {
		return best_lo, best_hi, true
	}
	return 0, 0, false
}

// xkb_stmt_end returns the token index just past the statement starting at i,
// stopping at a `;` at depth zero or at the end of the enclosing body.
xkb_stmt_end :: proc(toks: []Xkb_Tok, i, hi: int) -> int {
	depth := 0
	j := i
	for j < hi {
		t := toks[j]
		if t.kind == .Punct {
			switch t.text {
			case "{", "[", "(":
				depth += 1
			case "}", "]", ")":
				depth -= 1
			case ";":
				if depth <= 0 {return j + 1}
			}
		}
		j += 1
	}
	return hi
}

xkb_raw :: proc(s: ^Xkb_Src, lo, hi: int) -> string {
	if lo >= hi || hi > len(s.toks) {
		return ""
	}
	return s.src[s.toks[lo].pos:s.toks[hi - 1].end]
}

// ---------------------------------------------------------------------------
// Include specifications
// ---------------------------------------------------------------------------

Xkb_Merge :: enum u8 {
	Override, // later wins; this is what plain `include` and `+` do
	Augment, // earlier wins; `augment` and `|`
	Replace,
}

Xkb_Include :: struct {
	file:    string, // "us", "macintosh_vndr/apple"
	section: string, // "basic", or empty for the default section
	merge:   Xkb_Merge,
	group:   int, // the `:2` suffix, 0 when absent
}

// xkb_parse_include_list splits "pc+fr(oss):2|inet(evdev)" into its parts.
xkb_parse_include_list :: proc(spec: string, first: Xkb_Merge, allocator := context.allocator) -> []Xkb_Include {
	out := make([dynamic]Xkb_Include, allocator)
	merge := first
	i := 0
	start := 0
	flush :: proc(out: ^[dynamic]Xkb_Include, piece: string, merge: Xkb_Merge, allocator: runtime.Allocator) {
		s := strings.trim_space(piece)
		if s == "" {
			return
		}
		inc := Xkb_Include {
			merge = merge,
		}
		// Trailing ":N" group index.
		if c := strings.last_index_byte(s, ':'); c >= 0 {
			if g, ok := strconv.parse_int(s[c + 1:]); ok {
				inc.group = g
				s = s[:c]
			}
		}
		if o := strings.index_byte(s, '('); o >= 0 && strings.has_suffix(s, ")") {
			inc.section = strings.clone(s[o + 1:len(s) - 1], allocator)
			s = s[:o]
		}
		inc.file = strings.clone(s, allocator)
		append(out, inc)
	}
	depth := 0
	for i < len(spec) {
		c := spec[i]
		switch c {
		case '(':
			depth += 1
		case ')':
			depth -= 1
		case '+', '|':
			if depth == 0 {
				flush(&out, spec[start:i], merge, allocator)
				merge = c == '+' ? .Override : .Augment
				start = i + 1
			}
		}
		i += 1
	}
	flush(&out, spec[start:], merge, allocator)
	return out[:]
}

// ---------------------------------------------------------------------------
// Keymap model
// ---------------------------------------------------------------------------

Xkb_Type_Map :: struct {
	mods:  []string, // modifier names, resolved to a mask later
	mask:  u32,
	level: int,
}

Xkb_Type :: struct {
	name:     string,
	mod_names: []string,
	mask:     u32,
	maps:     [dynamic]Xkb_Type_Map,
	preserve: [dynamic]Xkb_Type_Map, // `level` unused; `mask` is what survives
	nlevels:  int,
	raw:      string, // body text, re-emitted verbatim
}

Xkb_Group_Def :: struct {
	used:      bool,
	type_name: string,
	syms:      [dynamic]string, // keysym names, as written
	vals:      [dynamic]u32,
}

Xkb_Key :: struct {
	name:     string,
	code:     u32, // xkb keycode, i.e. evdev + 8
	groups:   [XKB_MAX_GROUPS]Xkb_Group_Def,
	ngroups:  int,
	repeat:   i8, // -1 unset, 0 no, 1 yes
	vmods:    string,
}

Xkb_Keymap :: struct {
	ok:           bool,
	source:       string,
	rules:        string,
	model:        string,
	layout:       string,
	variant:      string,
	options:      string,
	comp_keycodes: string,
	comp_types:   string,
	comp_compat:  string,
	comp_symbols: string,

	min_code:     u32,
	max_code:     u32,
	code_of:      map[string]u32,
	name_of:      map[u32]string,
	alias:        map[string]string,
	indicators:   [dynamic]Xkb_Indicator,

	types:        [dynamic]Xkb_Type,
	type_of:      map[string]int,

	compat:       [dynamic]string, // statements, verbatim
	compat_vmod_of: map[string]string, // keysym name -> virtual modifier

	keys:         [dynamic]Xkb_Key,
	key_of:       map[string]int,
	by_code:      [XKB_KEYCODE_SPAN]int, // xkb keycode -> key index + 1

	modmap:       map[string]u32, // key name -> real modifier mask
	modmap_sym:   [dynamic]Xkb_Sym_Modmap,

	vmods:        [dynamic]string,
	vmod_mask:    map[string]u32,

	group_names:  [XKB_MAX_GROUPS]string,
	ngroups:      int,

	text:         string,
}

Xkb_Indicator :: struct {
	index: int,
	name:  string,
}

Xkb_Sym_Modmap :: struct {
	sym:  string,
	mask: u32,
}

xkb_km: Xkb_Keymap

// ---------------------------------------------------------------------------
// Keysym names
// ---------------------------------------------------------------------------

xkb_sym_by_name: map[string]u32
xkb_name_by_sym: map[u32]string

xkb_syms_init :: proc() {
	if len(xkb_sym_by_name) > 0 {
		return
	}
	xkb_sym_by_name = make(map[string]u32, 4096)
	xkb_name_by_sym = make(map[u32]string, 4096)
	rest := XKB_KEYSYM_TABLE
	for len(rest) > 0 {
		line: string
		nl := strings.index_byte(rest, '\n')
		if nl < 0 {
			line = rest
			rest = ""
		} else {
			line = rest[:nl]
			rest = rest[nl + 1:]
		}
		sp := strings.index_byte(line, ' ')
		if sp <= 0 {
			continue
		}
		name := line[:sp]
		v, ok := strconv.parse_u64_of_base(line[sp + 1:], 16)
		if !ok {
			continue
		}
		sym := u32(v)
		if _, taken := xkb_sym_by_name[name]; !taken {
			xkb_sym_by_name[name] = sym
		}
		if _, taken := xkb_name_by_sym[sym]; !taken {
			xkb_name_by_sym[sym] = name
		}
	}
}

// xkb_sym_from_name resolves a keysym as the symbols files write it: by name,
// as `UXXXX` for a Unicode codepoint, or as a bare hex literal.
xkb_sym_from_name :: proc(name: string) -> u32 {
	xkb_syms_init()
	// xkbcomp's own spelling rules: `any` and `nosymbol` leave a level
	// undefined, `none` and `voidsymbol` fill it with a symbol that does
	// nothing. The difference matters, because an undefined level falls
	// through to whatever an earlier include put there and a void one does
	// not.
	if name == "" || strings.equal_fold(name, "NoSymbol") || strings.equal_fold(name, "any") {
		return XKB_SYM_NO
	}
	if strings.equal_fold(name, "VoidSymbol") || strings.equal_fold(name, "none") {
		return XKB_SYM_VOID
	}
	if v, ok := xkb_sym_by_name[name]; ok {
		return v
	}
	// `XF86_Switch_VT_1` in the symbols files is `XF86XK_Switch_VT_1` in the
	// header, which our table records as `XF86Switch_VT_1`.
	if strings.has_prefix(name, "XF86_") {
		if v, ok := xkb_sym_by_name[fmt.tprintf("XF86%s", name[5:])]; ok {
			return v
		}
	}
	if strings.has_prefix(name, "0x") || strings.has_prefix(name, "0X") {
		if v, ok := strconv.parse_u64_of_base(name[2:], 16); ok {
			return u32(v)
		}
	}
	if len(name) >= 5 && name[0] == 'U' {
		if v, ok := strconv.parse_u64_of_base(name[1:], 16); ok {
			cp := u32(v)
			if cp < 0x100 {
				return cp
			}
			return cp | 0x0100_0000
		}
	}
	if v, ok := strconv.parse_u64(name); ok && v < 0x1000 {
		// A decimal keysym, which a few generated files still use.
		return u32(v)
	}
	return XKB_SYM_NO
}

xkb_sym_to_name :: proc(sym: u32) -> string {
	xkb_syms_init()
	if sym == XKB_SYM_NO {
		return "NoSymbol"
	}
	if sym == XKB_SYM_VOID {
		return "VoidSymbol"
	}
	if n, ok := xkb_name_by_sym[sym]; ok {
		return n
	}
	if sym & 0xff00_0000 == 0x0100_0000 {
		return fmt.tprintf("U%04X", sym & 0x00ff_ffff)
	}
	return fmt.tprintf("0x%08x", sym)
}

// xkb_sym_to_rune is what a client would get from the keysym. Only the two
// easy families are handled: Latin-1 and the Unicode keysym range.
xkb_sym_to_rune :: proc(sym: u32) -> rune {
	switch {
	case sym >= 0x20 && sym <= 0x7e:
		return rune(sym)
	case sym >= 0xa0 && sym <= 0xff:
		return rune(sym)
	case sym & 0xff00_0000 == 0x0100_0000:
		return rune(sym & 0x00ff_ffff)
	}
	return 0
}

// ---------------------------------------------------------------------------
// Modifier names
// ---------------------------------------------------------------------------

xkb_real_mod :: proc(name: string) -> (u32, bool) {
	switch {
	case strings.equal_fold(name, "shift"):
		return XKB_MOD_SHIFT, true
	case strings.equal_fold(name, "lock"):
		return XKB_MOD_LOCK, true
	case strings.equal_fold(name, "control"), strings.equal_fold(name, "ctrl"):
		return XKB_MOD_CONTROL, true
	case strings.equal_fold(name, "mod1"):
		return XKB_MOD_MOD1, true
	case strings.equal_fold(name, "mod2"):
		return XKB_MOD_MOD2, true
	case strings.equal_fold(name, "mod3"):
		return XKB_MOD_MOD3, true
	case strings.equal_fold(name, "mod4"):
		return XKB_MOD_MOD4, true
	case strings.equal_fold(name, "mod5"):
		return XKB_MOD_MOD5, true
	case strings.equal_fold(name, "none"), strings.equal_fold(name, "nonexistent"):
		return 0, true
	case strings.equal_fold(name, "all"):
		return 0xff, true
	}
	return 0, false
}

// The canonical virtual-to-real bindings. They are what every PC layout ends
// up with, and they are the floor: anything the compat and modifier_map data
// actually establishes overrides them.
xkb_default_vmods := [?]struct {
	name: string,
	mask: u32,
}{
	{"NumLock", XKB_MOD_MOD2},
	{"Alt", XKB_MOD_MOD1},
	{"Meta", XKB_MOD_MOD1},
	{"Super", XKB_MOD_MOD4},
	{"Hyper", XKB_MOD_MOD4},
	{"ScrollLock", XKB_MOD_MOD3},
	{"LevelThree", XKB_MOD_MOD5},
	{"LevelFive", XKB_MOD_MOD3},
	{"AltGr", XKB_MOD_MOD5},
}

xkb_mod_mask :: proc(km: ^Xkb_Keymap, names: []string) -> u32 {
	m := u32(0)
	for n in names {
		if v, ok := xkb_real_mod(n); ok {
			m |= v
			continue
		}
		if v, ok := km.vmod_mask[n]; ok {
			m |= v
			continue
		}
		for d in xkb_default_vmods {
			if strings.equal_fold(d.name, n) {
				m |= d.mask
				break
			}
		}
	}
	return m
}

// ---------------------------------------------------------------------------
// Component loaders
// ---------------------------------------------------------------------------

xkb_tok_text :: proc(t: Xkb_Tok) -> string {return t.text}

// xkb_names_until collects the identifier/plus list that modifier expressions
// use: `Shift + Lock`, `AnyOf(Shift+Lock)`, `none`.
xkb_mod_names :: proc(s: ^Xkb_Src, lo, hi: int, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for i in lo ..< hi {
		t := s.toks[i]
		if t.kind == .Ident {
			append(&out, t.text)
		}
	}
	return out[:]
}

xkb_load_keycodes :: proc(km: ^Xkb_Keymap, spec: string, merge: Xkb_Merge, depth: int) {
	if depth > 12 {
		return
	}
	for inc in xkb_parse_include_list(spec, merge, context.temp_allocator) {
		src, ok := xkb_src_load("keycodes", inc.file)
		if !ok {
			continue
		}
		lo, hi, sok := xkb_section(src, "xkb_keycodes", inc.section)
		if !sok {
			continue
		}
		xkb_keycodes_body(km, src, lo, hi, inc.merge, depth)
	}
}

xkb_keycodes_body :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge, depth: int) {
	i := lo
	for i < hi {
		t := s.toks[i]
		if t.kind == .Punct && t.text == ";" {
			i += 1
			continue
		}
		if t.kind == .Ident && (t.text == "include" || t.text == "augment" || t.text == "override" || t.text == "replace") {
			if i + 1 < hi && s.toks[i + 1].kind == .Str {
				m: Xkb_Merge = t.text == "augment" ? .Augment : t.text == "replace" ? .Replace : .Override
				xkb_load_keycodes(km, s.toks[i + 1].text, m, depth + 1)
				i += 2
				continue
			}
		}
		e := xkb_stmt_end(s.toks, i, hi)
		switch {
		case t.kind == .Key:
			// <NAME> = number;
			if i + 2 < hi && s.toks[i + 1].text == "=" && s.toks[i + 2].kind == .Num {
				v, _ := strconv.parse_u64(s.toks[i + 2].text)
				name := strings.clone(t.text)
				if _, exists := km.code_of[name]; !exists || merge != .Augment {
					km.code_of[name] = u32(v)
					km.name_of[u32(v)] = name
				}
			}
		case t.kind == .Ident && t.text == "alias":
			if i + 3 < hi && s.toks[i + 1].kind == .Key && s.toks[i + 3].kind == .Key {
				km.alias[strings.clone(s.toks[i + 1].text)] = strings.clone(s.toks[i + 3].text)
			}
		case t.kind == .Ident && t.text == "indicator":
			if i + 3 < hi && s.toks[i + 1].kind == .Num && s.toks[i + 3].kind == .Str {
				idx, _ := strconv.parse_int(s.toks[i + 1].text)
				found := false
				for ind in km.indicators {
					if ind.index == idx {found = true}
				}
				if !found {
					append(&km.indicators, Xkb_Indicator{index = idx, name = strings.clone(s.toks[i + 3].text)})
				}
			}
		case t.kind == .Ident && t.text == "minimum":
			if i + 2 < hi && s.toks[i + 2].kind == .Num {
				v, _ := strconv.parse_u64(s.toks[i + 2].text)
				km.min_code = u32(v)
			}
		case t.kind == .Ident && t.text == "maximum":
			if i + 2 < hi && s.toks[i + 2].kind == .Num {
				v, _ := strconv.parse_u64(s.toks[i + 2].text)
				km.max_code = u32(v)
			}
		}
		i = max(e, i + 1)
	}
}

xkb_load_types :: proc(km: ^Xkb_Keymap, spec: string, merge: Xkb_Merge, depth: int) {
	if depth > 12 {
		return
	}
	for inc in xkb_parse_include_list(spec, merge, context.temp_allocator) {
		src, ok := xkb_src_load("types", inc.file)
		if !ok {
			continue
		}
		lo, hi, sok := xkb_section(src, "xkb_types", inc.section)
		if !sok {
			continue
		}
		xkb_types_body(km, src, lo, hi, inc.merge, depth)
	}
}

xkb_add_vmod :: proc(km: ^Xkb_Keymap, name: string) {
	for v in km.vmods {
		if v == name {
			return
		}
	}
	append(&km.vmods, strings.clone(name))
}

xkb_types_body :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge, depth: int) {
	i := lo
	for i < hi {
		t := s.toks[i]
		if t.kind == .Punct && t.text == ";" {
			i += 1
			continue
		}
		if t.kind == .Ident && (t.text == "include" || t.text == "augment" || t.text == "override" || t.text == "replace") && i + 1 < hi && s.toks[i + 1].kind == .Str {
			m: Xkb_Merge = t.text == "augment" ? .Augment : .Override
			xkb_load_types(km, s.toks[i + 1].text, m, depth + 1)
			i += 2
			continue
		}
		e := xkb_stmt_end(s.toks, i, hi)
		if t.kind == .Ident && t.text == "virtual_modifiers" {
			for j in i + 1 ..< e {
				if s.toks[j].kind == .Ident {
					xkb_add_vmod(km, s.toks[j].text)
				}
			}
		} else if t.kind == .Ident && t.text == "type" && i + 1 < hi && s.toks[i + 1].kind == .Str {
			xkb_parse_type(km, s, i, e, merge)
		}
		i = max(e, i + 1)
	}
}

xkb_parse_type :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge) {
	name := s.toks[lo + 1].text
	// Body between the braces.
	bo := lo + 2
	for bo < hi && !(s.toks[bo].kind == .Punct && s.toks[bo].text == "{") {bo += 1}
	if bo >= hi {
		return
	}
	depth := 0
	bc := bo
	for bc < hi {
		if s.toks[bc].kind == .Punct {
			if s.toks[bc].text == "{" {depth += 1} else if s.toks[bc].text == "}" {
				depth -= 1
				if depth == 0 {break}
			}
		}
		bc += 1
	}

	ty := Xkb_Type {
		name    = strings.clone(name),
		raw     = strings.clone(strings.trim_space(xkb_raw(s, bo + 1, bc))),
		nlevels = 1,
	}
	ty.maps = make([dynamic]Xkb_Type_Map)
	ty.preserve = make([dynamic]Xkb_Type_Map)

	j := bo + 1
	for j < bc {
		t := s.toks[j]
		e := xkb_stmt_end(s.toks, j, bc)
		switch {
		case t.kind == .Ident && t.text == "modifiers":
			ty.mod_names = xkb_mod_names(s, j + 1, e)
		case t.kind == .Ident && (t.text == "map" || t.text == "preserve"):
			// map[ Shift+Lock ] = Level2;
			ob, cb, eq := -1, -1, -1
			for k in j ..< e {
				if s.toks[k].kind == .Punct {
					if s.toks[k].text == "[" && ob < 0 {ob = k}
					if s.toks[k].text == "]" && cb < 0 {cb = k}
					if s.toks[k].text == "=" && eq < 0 {eq = k}
				}
			}
			if ob < 0 || cb < 0 || eq < 0 {
				break
			}
			m := Xkb_Type_Map {
				mods = xkb_mod_names(s, ob + 1, cb),
			}
			if t.text == "map" {
				lvl := 1
				for k in eq + 1 ..< e {
					tk := s.toks[k]
					if tk.kind == .Num {
						lvl, _ = strconv.parse_int(tk.text)
						break
					}
					if tk.kind == .Ident && len(tk.text) > 5 && strings.has_prefix(strings.to_lower(tk.text, context.temp_allocator), "level") {
						lvl, _ = strconv.parse_int(tk.text[5:])
						break
					}
					if tk.kind == .Ident && strings.equal_fold(tk.text, "any") {
						lvl = 1
						break
					}
				}
				m.level = max(lvl, 1)
				ty.nlevels = max(ty.nlevels, m.level)
				append(&ty.maps, m)
			} else {
				// preserve[X] = Y: the modifiers on the right are not
				// consumed by the key, so an application still sees them.
				m.mods = xkb_mod_names(s, eq + 1, e)
				append(&ty.preserve, m)
			}
		case t.kind == .Ident && t.text == "level_name":
			for k in j ..< e {
				if s.toks[k].kind == .Punct && s.toks[k].text == "[" && k + 1 < e {
					tk := s.toks[k + 1]
					if tk.kind == .Ident && strings.has_prefix(strings.to_lower(tk.text, context.temp_allocator), "level") {
						if lv, ok := strconv.parse_int(tk.text[5:]); ok {
							ty.nlevels = max(ty.nlevels, lv)
						}
					} else if tk.kind == .Num {
						if lv, ok := strconv.parse_int(tk.text); ok {
							ty.nlevels = max(ty.nlevels, lv)
						}
					}
					break
				}
			}
		}
		j = max(e, j + 1)
	}

	if idx, exists := km.type_of[ty.name]; exists {
		if merge != .Augment {
			km.types[idx] = ty
		}
		return
	}
	km.type_of[ty.name] = len(km.types)
	append(&km.types, ty)
}

xkb_load_compat :: proc(km: ^Xkb_Keymap, spec: string, merge: Xkb_Merge, depth: int) {
	if depth > 12 {
		return
	}
	for inc in xkb_parse_include_list(spec, merge, context.temp_allocator) {
		src, ok := xkb_src_load("compat", inc.file)
		if !ok {
			continue
		}
		lo, hi, sok := xkb_section(src, "xkb_compatibility", inc.section)
		if !sok {
			continue
		}
		xkb_compat_body(km, src, lo, hi, inc.merge, depth)
	}
}

xkb_compat_body :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge, depth: int) {
	i := lo
	for i < hi {
		t := s.toks[i]
		if t.kind == .Punct && t.text == ";" {
			i += 1
			continue
		}
		if t.kind == .Ident && (t.text == "include" || t.text == "augment" || t.text == "override" || t.text == "replace") && i + 1 < hi && s.toks[i + 1].kind == .Str {
			m: Xkb_Merge = t.text == "augment" ? .Augment : .Override
			xkb_load_compat(km, s.toks[i + 1].text, m, depth + 1)
			i += 2
			continue
		}
		e := xkb_stmt_end(s.toks, i, hi)
		if t.kind == .Ident && t.text == "virtual_modifiers" {
			for j in i + 1 ..< e {
				if s.toks[j].kind == .Ident {
					xkb_add_vmod(km, s.toks[j].text)
				}
			}
			i = max(e, i + 1)
			continue
		}
		raw := strings.trim_space(xkb_raw(s, i, e))
		if raw != "" {
			if !strings.has_suffix(raw, ";") {
				raw = fmt.aprintf("%s;", raw)
			} else {
				raw = strings.clone(raw)
			}
			append(&km.compat, raw)
		}
		// `interpret Num_Lock+Any { virtualModifier= NumLock; }` is how a
		// virtual modifier gets bound to whatever real modifier the key
		// carrying that keysym is mapped to.
		if t.kind == .Ident && t.text == "interpret" && i + 1 < e && s.toks[i + 1].kind == .Ident {
			sym := s.toks[i + 1].text
			for j in i ..< e {
				if s.toks[j].kind == .Ident && strings.equal_fold(s.toks[j].text, "virtualModifier") {
					for k in j + 1 ..< e {
						if s.toks[k].kind == .Ident {
							km.compat_vmod_of[strings.clone(sym)] = strings.clone(s.toks[k].text)
							xkb_add_vmod(km, s.toks[k].text)
							break
						}
					}
					break
				}
			}
		}
		i = max(e, i + 1)
	}
}

// ---------------------------------------------------------------------------
// Symbols
// ---------------------------------------------------------------------------

Xkb_Sym_Ctx :: struct {
	default_type: [XKB_MAX_GROUPS]string,
	group_shift:  int,
}

xkb_load_symbols :: proc(km: ^Xkb_Keymap, spec: string, merge: Xkb_Merge, group_shift: int, depth: int) {
	if depth > 16 {
		return
	}
	for inc in xkb_parse_include_list(spec, merge, context.temp_allocator) {
		src, ok := xkb_src_load("symbols", inc.file)
		if !ok {
			continue
		}
		lo, hi, sok := xkb_section(src, "xkb_symbols", inc.section)
		if !sok {
			continue
		}
		shift := group_shift
		if inc.group > 0 {
			shift = inc.group - 1
		}
		ctx := Xkb_Sym_Ctx {
			group_shift = shift,
		}
		xkb_symbols_body(km, src, lo, hi, inc.merge, &ctx, depth)
	}
}

xkb_key_slot :: proc(km: ^Xkb_Keymap, name: string) -> ^Xkb_Key {
	real := name
	if a, ok := km.alias[name]; ok {
		if _, has := km.code_of[name]; !has {
			real = a
		}
	}
	if idx, ok := km.key_of[real]; ok {
		return &km.keys[idx]
	}
	code, ok := km.code_of[real]
	if !ok {
		return nil
	}
	append(&km.keys, Xkb_Key{name = strings.clone(real), code = code, repeat = -1})
	km.key_of[strings.clone(real)] = len(km.keys) - 1
	if code < XKB_KEYCODE_SPAN {
		km.by_code[code] = len(km.keys)
	}
	return &km.keys[len(km.keys) - 1]
}

xkb_symbols_body :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge, ctx: ^Xkb_Sym_Ctx, depth: int) {
	i := lo
	for i < hi {
		t := s.toks[i]
		if t.kind == .Punct && (t.text == ";" || t.text == ",") {
			i += 1
			continue
		}
		// Merge prefixes: `include "x"`, or `override key <X> {...};`
		stmt_merge := merge
		if t.kind == .Ident && (t.text == "include" || t.text == "augment" || t.text == "override" || t.text == "replace") {
			m: Xkb_Merge = t.text == "augment" ? .Augment : .Override
			if i + 1 < hi && s.toks[i + 1].kind == .Str {
				xkb_load_symbols(km, s.toks[i + 1].text, m, ctx.group_shift, depth + 1)
				i += 2
				continue
			}
			stmt_merge = m
			i += 1
			if i >= hi {
				break
			}
			t = s.toks[i]
		}
		e := xkb_stmt_end(s.toks, i, hi)
		switch {
		case t.kind == .Ident && t.text == "virtual_modifiers":
			for j in i + 1 ..< e {
				if s.toks[j].kind == .Ident {
					xkb_add_vmod(km, s.toks[j].text)
				}
			}
		case t.kind == .Ident && t.text == "name":
			// name[Group1] = "English (US)";
			g := xkb_group_index(s, i, e)
			for j in i ..< e {
				if s.toks[j].kind == .Str {
					gi := clamp(g + ctx.group_shift, 0, XKB_MAX_GROUPS - 1)
					km.group_names[gi] = strings.clone(s.toks[j].text)
					km.ngroups = max(km.ngroups, gi + 1)
					break
				}
			}
		case t.kind == .Ident && t.text == "key" && i + 1 < e && s.toks[i + 1].kind == .Punct && s.toks[i + 1].text == ".":
			// key.type[group1] = "ALPHABETIC";
			g := xkb_group_index(s, i, e)
			for j in i ..< e {
				if s.toks[j].kind == .Str {
					gi := clamp(g + ctx.group_shift, 0, XKB_MAX_GROUPS - 1)
					ctx.default_type[gi] = strings.clone(s.toks[j].text)
					break
				}
			}
		case t.kind == .Ident && t.text == "key" && i + 1 < e && s.toks[i + 1].kind == .Key:
			xkb_parse_key(km, s, i, e, stmt_merge, ctx)
		case t.kind == .Ident && (t.text == "modifier_map" || t.text == "modmap"):
			xkb_parse_modmap(km, s, i, e)
		}
		i = max(e, i + 1)
	}
}

// xkb_group_index reads `[Group2]` / `[group2]` / `[2]` out of a statement and
// returns a zero-based group number.
xkb_group_index :: proc(s: ^Xkb_Src, lo, hi: int) -> int {
	for j in lo ..< hi {
		if s.toks[j].kind == .Punct && s.toks[j].text == "[" && j + 1 < hi {
			t := s.toks[j + 1]
			if t.kind == .Num {
				if v, ok := strconv.parse_int(t.text); ok {return max(v - 1, 0)}
			}
			if t.kind == .Ident {
				l := strings.to_lower(t.text, context.temp_allocator)
				if strings.has_prefix(l, "group") {
					if v, ok := strconv.parse_int(l[5:]); ok {return max(v - 1, 0)}
				}
			}
			return 0
		}
		if s.toks[j].kind == .Punct && s.toks[j].text == "{" {
			break
		}
	}
	return 0
}

xkb_parse_key :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int, merge: Xkb_Merge, ctx: ^Xkb_Sym_Ctx) {
	kname := s.toks[lo + 1].text
	k := xkb_key_slot(km, kname)
	if k == nil {
		return
	}
	// Body between braces.
	bo := lo + 2
	for bo < hi && !(s.toks[bo].kind == .Punct && s.toks[bo].text == "{") {bo += 1}
	if bo >= hi {
		return
	}
	depth := 0
	bc := bo
	for bc < hi {
		if s.toks[bc].kind == .Punct {
			if s.toks[bc].text == "{" {depth += 1} else if s.toks[bc].text == "}" {
				depth -= 1
				if depth == 0 {break}
			}
		}
		bc += 1
	}

	implicit_group := 0
	j := bo + 1
	for j < bc {
		// Split the body on commas at depth zero.
		ce := j
		d := 0
		for ce < bc {
			tk := s.toks[ce]
			if tk.kind == .Punct {
				switch tk.text {
				case "[", "(", "{":
					d += 1
				case "]", ")", "}":
					d -= 1
				case ",":
					if d == 0 {
						break
					}
				}
				if tk.text == "," && d == 0 {
					break
				}
			}
			ce += 1
		}
		xkb_parse_key_clause(km, s, j, ce, k, ctx, merge, &implicit_group)
		j = ce + 1
	}
}

xkb_parse_key_clause :: proc(
	km: ^Xkb_Keymap,
	s: ^Xkb_Src,
	lo, hi: int,
	k: ^Xkb_Key,
	ctx: ^Xkb_Sym_Ctx,
	merge: Xkb_Merge,
	implicit_group: ^int,
) {
	if lo >= hi {
		return
	}
	t := s.toks[lo]

	// A bare `[ sym, sym ]` is the next group's symbol list.
	if t.kind == .Punct && t.text == "[" {
		g := implicit_group^
		implicit_group^ += 1
		xkb_set_group_syms(km, s, lo, hi, k, g + ctx.group_shift, ctx, merge)
		return
	}
	if t.kind != .Ident {
		return
	}
	lname := strings.to_lower(t.text, context.temp_allocator)
	switch {
	case lname == "symbols":
		g := xkb_group_index(s, lo, hi)
		implicit_group^ = max(implicit_group^, g + 1)
		ob := -1
		// The symbol list is the `[` that follows the `=`.
		eq := -1
		for j in lo ..< hi {
			if s.toks[j].kind == .Punct && s.toks[j].text == "=" {
				eq = j
				break
			}
		}
		if eq >= 0 {
			for j in eq ..< hi {
				if s.toks[j].kind == .Punct && s.toks[j].text == "[" {
					ob = j
					break
				}
			}
		}
		if ob >= 0 {
			xkb_set_group_syms(km, s, ob, hi, k, g + ctx.group_shift, ctx, merge)
		}
	case lname == "type":
		indexed := false
		for j in lo ..< hi {
			if s.toks[j].kind == .Punct && s.toks[j].text == "[" {indexed = true}
		}
		g := xkb_group_index(s, lo, hi)
		for j in lo ..< hi {
			if s.toks[j].kind == .Str {
				name := strings.clone(s.toks[j].text)
				if indexed {
					gi := clamp(g + ctx.group_shift, 0, XKB_MAX_GROUPS - 1)
					k.groups[gi].type_name = name
				} else {
					for gi in 0 ..< XKB_MAX_GROUPS {
						k.groups[gi].type_name = name
					}
				}
				break
			}
		}
	case lname == "repeat":
		for j in lo ..< hi {
			if s.toks[j].kind == .Ident {
				l := strings.to_lower(s.toks[j].text, context.temp_allocator)
				if l == "yes" || l == "true" || l == "on" {k.repeat = 1}
				if l == "no" || l == "false" || l == "off" {k.repeat = 0}
			}
		}
	case lname == "virtualmods", lname == "virtualmodifiers":
		for j in lo ..< hi {
			if s.toks[j].kind == .Ident && j > lo {
				k.vmods = strings.clone(s.toks[j].text)
				xkb_add_vmod(km, s.toks[j].text)
				break
			}
		}
	case lname == "actions", lname == "locks", lname == "locking", lname == "overlay", lname == "groupswrap", lname == "groupsclamp", lname == "groupsredirect":
	// Actions come from the compat section; the rest do not affect lookup.
	}
}

// xkb_set_group_syms merges a symbol list into a key's group.
//
// The merge is per level, not per key, and that is not a detail: layouts are
// built by stacking partial definitions, and a file like rs(latlevel3) writes
// `key <AD01> { [ any, any, backslash, Greek_OMEGA ] }` meaning "leave levels
// one and two alone and add two more". Replacing the whole list instead would
// erase the q that latin(type3) put there.
xkb_set_group_syms :: proc(
	km: ^Xkb_Keymap,
	s: ^Xkb_Src,
	lo, hi: int,
	k: ^Xkb_Key,
	group: int,
	ctx: ^Xkb_Sym_Ctx,
	merge: Xkb_Merge,
) {
	gi := clamp(group, 0, XKB_MAX_GROUPS - 1)
	g := &k.groups[gi]

	// Collect the names inside the brackets.
	names := make([dynamic]string, context.temp_allocator)
	d := 0
	for j in lo ..< hi {
		t := s.toks[j]
		if t.kind == .Punct {
			if t.text == "[" {
				d += 1
				continue
			}
			if t.text == "]" {
				d -= 1
				if d == 0 {break}
				continue
			}
			continue
		}
		if d == 0 {
			continue
		}
		if t.kind == .Ident || t.kind == .Num {
			append(&names, t.text)
		}
	}
	if len(names) == 0 {
		return
	}
	if g.syms == nil {
		g.syms = make([dynamic]string)
		g.vals = make([dynamic]u32)
	}

	old_syms := make([dynamic]string, context.temp_allocator)
	old_vals := make([dynamic]u32, context.temp_allocator)
	if g.used {
		for v in g.syms {append(&old_syms, v)}
		for v in g.vals {append(&old_vals, v)}
	}
	clear(&g.syms)
	clear(&g.vals)

	n := max(len(names), len(old_vals))
	for i in 0 ..< n {
		nn := i < len(names) ? names[i] : ""
		nv := nn == "" ? XKB_SYM_NO : xkb_sym_from_name(nn)
		on := i < len(old_syms) ? old_syms[i] : ""
		ov := i < len(old_vals) ? old_vals[i] : XKB_SYM_NO

		use_new := true
		switch {
		case nv == XKB_SYM_NO:
			use_new = false
		case ov == XKB_SYM_NO:
			use_new = true
		case:
			use_new = merge != .Augment
		}
		if use_new {
			append(&g.syms, strings.clone(nn))
			append(&g.vals, nv)
		} else {
			append(&g.syms, on == "" ? "NoSymbol" : on)
			append(&g.vals, ov)
		}
	}

	g.used = true
	if g.type_name == "" && ctx.default_type[gi] != "" {
		g.type_name = ctx.default_type[gi]
	}
	k.ngroups = max(k.ngroups, gi + 1)
	km.ngroups = max(km.ngroups, gi + 1)
}

xkb_parse_modmap :: proc(km: ^Xkb_Keymap, s: ^Xkb_Src, lo, hi: int) {
	// modifier_map Shift { Shift_L, Shift_R };  or  { <LFSH>, <RTSH> }
	if lo + 1 >= hi || s.toks[lo + 1].kind != .Ident {
		return
	}
	mask, ok := xkb_real_mod(s.toks[lo + 1].text)
	if !ok {
		return
	}
	for j in lo + 2 ..< hi {
		t := s.toks[j]
		switch t.kind {
		case .Key:
			km.modmap[strings.clone(t.text)] = km.modmap[t.text] | mask
		case .Ident:
			append(&km.modmap_sym, Xkb_Sym_Modmap{sym = strings.clone(t.text), mask = mask})
		case .End, .Str, .Num, .Punct:
		}
	}
}

// ---------------------------------------------------------------------------
// Rules
//
// rules/evdev maps an RMLVO description onto component file names. The file is
// a list of tables, each introduced by `! <fields> = <component>`, with `*` as
// a wildcard and `$name` groups defined by `! $name = a b c`. Only the
// single-layout tables are implemented; the `layout[2]`..`layout[4]` tables
// that build a multi-layout keymap are skipped, and the report says so.
// ---------------------------------------------------------------------------

Xkb_Rule_Row :: struct {
	fields: []string,
	value:  string,
}

Xkb_Rule_Table :: struct {
	fields: []string, // "model", "layout", "variant", "option"
	output: string, // "symbols", "types", "compat", "keycodes", "geometry"
	rows:   [dynamic]Xkb_Rule_Row,
}

Xkb_Rules :: struct {
	ok:     bool,
	groups: map[string][]string,
	tables: [dynamic]Xkb_Rule_Table,
}

xkb_rules_parse :: proc(path: string) -> (r: Xkb_Rules, ok: bool) {
	text, rok := ev_read_file(path, context.temp_allocator)
	if !rok {
		return {}, false
	}
	// Join continuation lines.
	joined, _ := strings.replace_all(text, "\\\n", " ", context.temp_allocator)

	r.groups = make(map[string][]string)
	r.tables = make([dynamic]Xkb_Rule_Table)
	cur: ^Xkb_Rule_Table

	for raw_line in strings.split_lines_iterator(&joined) {
		line := strings.trim_space(raw_line)
		if line == "" || strings.has_prefix(line, "//") {
			continue
		}
		if strings.has_prefix(line, "!") {
			body := strings.trim_space(line[1:])
			if strings.has_prefix(body, "$") {
				eq := strings.index_byte(body, '=')
				if eq < 0 {
					continue
				}
				name := strings.trim_space(body[:eq])
				vals := strings.fields(strings.trim_space(body[eq + 1:]))
				r.groups[strings.clone(name)] = vals
				cur = nil
				continue
			}
			eq := strings.index_byte(body, '=')
			if eq < 0 {
				cur = nil
				continue
			}
			fields := strings.fields(strings.trim_space(body[:eq]))
			out := strings.trim_space(body[eq + 1:])
			tb := Xkb_Rule_Table {
				fields = fields,
				output = strings.clone(out),
			}
			tb.rows = make([dynamic]Xkb_Rule_Row)
			append(&r.tables, tb)
			cur = &r.tables[len(r.tables) - 1]
			continue
		}
		if cur == nil {
			continue
		}
		parts := strings.fields(line)
		nf := len(cur.fields)
		if len(parts) < nf + 1 {
			continue
		}
		vi := nf
		if parts[vi] == "=" {
			vi += 1
		}
		if vi >= len(parts) {
			continue
		}
		row := Xkb_Rule_Row {
			fields = parts[:nf],
			value  = strings.join(parts[vi:], "", context.temp_allocator),
		}
		row.value = strings.clone(strings.trim_left(row.value, "="))
		append(&cur.rows, row)
	}
	r.ok = len(r.tables) > 0
	return r, r.ok
}

xkb_rule_match :: proc(r: ^Xkb_Rules, pattern, value: string) -> bool {
	if pattern == "*" {
		return true
	}
	if strings.has_prefix(pattern, "$") {
		if list, ok := r.groups[pattern]; ok {
			for v in list {
				if v == value {
					return true
				}
			}
		}
		return false
	}
	return pattern == value
}

Xkb_Rmlvo :: struct {
	rules:   string,
	model:   string,
	layout:  string,
	variant: string,
	options: []string,
}

xkb_rule_field_value :: proc(name: string, m: ^Xkb_Rmlvo, option: string) -> string {
	switch {
	case strings.has_prefix(name, "model"):
		return m.model
	case strings.has_prefix(name, "layout"):
		return m.layout
	case strings.has_prefix(name, "variant"):
		return m.variant
	case strings.has_prefix(name, "option"):
		return option
	}
	return ""
}

// xkb_rule_subst expands %m, %l, %v and the parenthesised %(v) form.
xkb_rule_subst :: proc(tmpl: string, m: ^Xkb_Rmlvo) -> string {
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(tmpl) {
		c := tmpl[i]
		if c != '%' {
			strings.write_byte(&b, c)
			i += 1
			continue
		}
		i += 1
		if i >= len(tmpl) {
			break
		}
		paren := false
		if tmpl[i] == '(' {
			paren = true
			i += 1
			if i >= len(tmpl) {
				break
			}
		}
		which := tmpl[i]
		i += 1
		// An optional [N] index, which we treat as layout 1 only.
		if i < len(tmpl) && tmpl[i] == '[' {
			for i < len(tmpl) && tmpl[i] != ']' {i += 1}
			i = min(i + 1, len(tmpl))
		}
		if paren && i < len(tmpl) && tmpl[i] == ')' {
			i += 1
		}
		val := ""
		switch which {
		case 'm':
			val = m.model
		case 'l':
			val = m.layout
		case 'v':
			val = m.variant
		}
		if val == "" {
			continue
		}
		if paren {
			strings.write_byte(&b, '(')
			strings.write_string(&b, val)
			strings.write_byte(&b, ')')
		} else {
			strings.write_string(&b, val)
		}
	}
	return strings.clone(strings.to_string(b), context.temp_allocator)
}

// xkb_rules_resolve returns the component spec for one output kind.
xkb_rules_resolve :: proc(r: ^Xkb_Rules, m: ^Xkb_Rmlvo, output: string) -> string {
	base := ""
	extra := make([dynamic]string, context.temp_allocator)
	for &tb in r.tables {
		if tb.output != output {
			continue
		}
		// Tables that key on layout[2..4] build a multi-layout keymap.
		skip := false
		has_option := false
		for f in tb.fields {
			for n in ([?]string{"[2]", "[3]", "[4]"}) {
				if strings.has_suffix(f, n) {skip = true}
			}
			if strings.has_prefix(f, "option") {has_option = true}
		}
		if skip {
			continue
		}
		if has_option {
			// Every matching option contributes.
			for opt in m.options {
				for row in tb.rows {
					hit := true
					for f, fi in tb.fields {
						v := xkb_rule_field_value(f, m, opt)
						if !xkb_rule_match(r, row.fields[fi], v) {
							hit = false
							break
						}
					}
					if hit {
						append(&extra, xkb_rule_subst(row.value, m))
						break
					}
				}
			}
			continue
		}
		for row in tb.rows {
			hit := true
			for f, fi in tb.fields {
				v := xkb_rule_field_value(f, m, "")
				if !xkb_rule_match(r, row.fields[fi], v) {
					hit = false
					break
				}
			}
			if hit {
				v := xkb_rule_subst(row.value, m)
				if strings.has_prefix(v, "+") || strings.has_prefix(v, "|") {
					append(&extra, v)
				} else if base == "" {
					base = v
				}
				break
			}
		}
	}
	if base == "" && len(extra) == 0 {
		return ""
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, base)
	for e in extra {
		if strings.has_prefix(e, "+") || strings.has_prefix(e, "|") {
			strings.write_string(&b, e)
		} else {
			strings.write_string(&b, "+")
			strings.write_string(&b, e)
		}
	}
	return strings.clone(strings.to_string(b), context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Compiling
// ---------------------------------------------------------------------------

xkb_keymap_free :: proc(km: ^Xkb_Keymap) {
	delete(km.code_of)
	delete(km.name_of)
	delete(km.alias)
	delete(km.type_of)
	delete(km.key_of)
	delete(km.modmap)
	delete(km.vmod_mask)
	delete(km.compat_vmod_of)
	km^ = {}
}

xkb_keymap_init :: proc(km: ^Xkb_Keymap) {
	xkb_keymap_free(km)
	km.code_of = make(map[string]u32, 512)
	km.name_of = make(map[u32]string, 512)
	km.alias = make(map[string]string)
	km.type_of = make(map[string]int)
	km.key_of = make(map[string]int, 512)
	km.modmap = make(map[string]u32)
	km.vmod_mask = make(map[string]u32)
	km.compat_vmod_of = make(map[string]string)
	km.indicators = make([dynamic]Xkb_Indicator)
	km.types = make([dynamic]Xkb_Type)
	km.compat = make([dynamic]string)
	km.keys = make([dynamic]Xkb_Key)
	km.modmap_sym = make([dynamic]Xkb_Sym_Modmap)
	km.vmods = make([dynamic]string)
	km.min_code = XKB_MIN_KEYCODE
	km.max_code = XKB_MAX_KEYCODE
	km.ngroups = 1
}

// xkb_compile is the entry point: an RMLVO description in, a usable keymap
// out. It falls back to the built-in US keymap when the system XKB data is
// absent or unusable, and never returns a keymap that cannot type.
xkb_compile :: proc(km: ^Xkb_Keymap, rmlvo: Xkb_Rmlvo) -> bool {
	xkb_syms_init()
	m := rmlvo
	if m.layout == "" {m.layout = "us"}
	if m.rules == "" {m.rules = "evdev"}
	if m.model == "" {m.model = "pc105"}

	xkb_keymap_init(km)
	km.rules, km.model, km.layout, km.variant = strings.clone(m.rules), strings.clone(m.model), strings.clone(m.layout), strings.clone(m.variant)
	km.options = strings.clone(strings.join(m.options, ",", context.temp_allocator))

	// Several layouts (`us,ru`, variants `,phonetic`) become several groups.
	// The rules file's layout[N] sections are not interpreted here; instead
	// the first layout is resolved as a single one and the others are spliced
	// in after it as `+ru(phonetic):2`, which is the symbols line libxkbcommon
	// produces from the same rules for every multi-layout case in evdev.
	layouts := strings.split(m.layout, ",", context.temp_allocator)
	variants := strings.split(m.variant, ",", context.temp_allocator)
	extra := ""
	if len(layouts) > 1 {
		b := strings.builder_make(context.temp_allocator)
		for l, i in layouts[1:] {
			l := strings.trim_space(l)
			v := i + 1 < len(variants) ? strings.trim_space(variants[i + 1]) : ""
			if l == "" {
				continue
			}
			if v != "" {
				fmt.sbprintf(&b, "+%s(%s):%d", l, v, i + 2)
			} else {
				fmt.sbprintf(&b, "+%s:%d", l, i + 2)
			}
		}
		extra = strings.to_string(b)
		m.layout = strings.trim_space(layouts[0])
		m.variant = len(variants) > 0 ? strings.trim_space(variants[0]) : ""
	}

	kc, ty, cm, sy := "evdev", "complete", "complete", ""
	rules, rok := xkb_rules_parse(fmt.tprintf("%s/rules/%s", xkb_root(), m.rules))
	if rok {
		if v := xkb_rules_resolve(&rules, &m, "keycodes"); v != "" {kc = v}
		if v := xkb_rules_resolve(&rules, &m, "types"); v != "" {ty = v}
		if v := xkb_rules_resolve(&rules, &m, "compat"); v != "" {cm = v}
		if v := xkb_rules_resolve(&rules, &m, "symbols"); v != "" {sy = v}
	}
	if sy == "" {
		// The canonical evdev composition, for when the rules file is missing
		// or says nothing useful.
		if m.variant != "" {
			sy = fmt.tprintf("pc+%s(%s)+inet(evdev)", m.layout, m.variant)
		} else {
			sy = fmt.tprintf("pc+%s+inet(evdev)", m.layout)
		}
	}
	if extra != "" {
		first := m.variant != "" ? fmt.tprintf("%s(%s)", m.layout, m.variant) : m.layout
		parts := strings.split(sy, "+", context.temp_allocator)
		at := -1
		for part, i in parts {
			if part == first {
				at = i
				break
			}
		}
		if at >= 0 {
			sy = fmt.tprintf("%s%s+%s", strings.join(parts[:at + 1], "+", context.temp_allocator), extra, strings.join(parts[at + 1:], "+", context.temp_allocator))
			sy = strings.trim_suffix(sy, "+")
		} else {
			sy = fmt.tprintf("%s%s", sy, extra)
		}
	}
	km.comp_keycodes = strings.clone(kc)
	km.comp_types = strings.clone(ty)
	km.comp_compat = strings.clone(cm)
	km.comp_symbols = strings.clone(sy)

	xkb_load_keycodes(km, kc, .Override, 0)
	xkb_load_types(km, ty, .Override, 0)
	xkb_load_compat(km, cm, .Override, 0)
	xkb_load_symbols(km, sy, .Override, 0, 0)

	if len(km.code_of) == 0 || len(km.keys) == 0 || len(km.types) == 0 {
		return xkb_compile_fallback(km, "the built-in US keymap (no usable /usr/share/X11/xkb)")
	}

	xkb_finish(km)
	km.source = fmt.aprintf("%s/%s (%s%s)", xkb_root(), m.rules, km.layout, km.variant != "" ? fmt.tprintf(":%s", km.variant) : "")
	km.ok = true
	return true
}

// xkb_finish is everything that can only be done once all four components are
// loaded: binding virtual modifiers to real ones, resolving every type's
// modifier mask, filling in implicit key types, and building the text.
xkb_finish :: proc(km: ^Xkb_Keymap) {
	// Trailing undefined levels do not count. A key written
	// `[ 5, colon, NoSymbol ]` is a two-level key, not a three-level one with
	// an empty top, and the difference decides which type it is given and so
	// what AltGr does on it.
	for &k in km.keys {
		ng := 0
		for gi in 0 ..< XKB_MAX_GROUPS {
			g := &k.groups[gi]
			if !g.used {
				continue
			}
			n := len(g.vals)
			for n > 0 && g.vals[n - 1] == XKB_SYM_NO {n -= 1}
			if n < len(g.vals) {
				resize(&g.vals, n)
				resize(&g.syms, n)
			}
			if n == 0 {
				g.used = false
				continue
			}
			ng = gi + 1
		}
		k.ngroups = ng
	}

	// Seed the canonical bindings, then let the data override them.
	for d in xkb_default_vmods {
		km.vmod_mask[d.name] = d.mask
		xkb_add_vmod(km, d.name)
	}

	// `modifier_map Mod1 { Alt_L }` names a keysym, not a key. Resolve those
	// now that the symbols are loaded.
	for ms in km.modmap_sym {
		sym := xkb_sym_from_name(ms.sym)
		if sym == XKB_SYM_NO {
			continue
		}
		for &k in km.keys {
			hit := false
			for gi in 0 ..< XKB_MAX_GROUPS {
				for v in k.groups[gi].vals {
					if v == sym {hit = true}
				}
			}
			if hit {
				km.modmap[k.name] = km.modmap[k.name] | ms.mask
			}
		}
	}

	// A virtual modifier is bound to whatever real modifier the keys carrying
	// its interpret keysym are mapped to. That is how LevelThree becomes Mod5
	// on a layout that includes level3(ralt_switch).
	for sym_name, vmod in km.compat_vmod_of {
		sym := xkb_sym_from_name(sym_name)
		if sym == XKB_SYM_NO {
			continue
		}
		mask := u32(0)
		for &k in km.keys {
			hit := false
			for gi in 0 ..< XKB_MAX_GROUPS {
				for v in k.groups[gi].vals {
					if v == sym {hit = true}
				}
			}
			if hit {
				mask |= km.modmap[k.name]
			}
		}
		if mask != 0 {
			km.vmod_mask[vmod] = mask
		}
	}

	// Resolve every type's masks now that the virtual modifiers are known.
	for &t in km.types {
		t.mask = xkb_mod_mask(km, t.mod_names)
		for &mp in t.maps {
			mp.mask = xkb_mod_mask(km, mp.mods) & t.mask
		}
	}

	// Keys with no explicit type get the one their level count implies, the
	// same rule xkbcomp uses.
	for &k in km.keys {
		for gi in 0 ..< XKB_MAX_GROUPS {
			g := &k.groups[gi]
			if !g.used {
				continue
			}
			if g.type_name != "" {
				if _, ok := km.type_of[g.type_name]; ok {
					continue
				}
			}
			g.type_name = xkb_implicit_type(km, g)
		}
		if k.ngroups == 0 && k.groups[0].used {
			k.ngroups = 1
		}
	}

	if km.ngroups == 0 {
		km.ngroups = 1
	}
	if km.group_names[0] == "" {
		km.group_names[0] = fmt.aprintf("%s", km.layout == "" ? "Default" : km.layout)
	}

	km.text = xkb_keymap_text(km)
}

// xkb_implicit_type picks a key type from the symbols alone: two alphabetic
// levels that differ only in case is ALPHABETIC, two of anything else is
// TWO_LEVEL, one is ONE_LEVEL, four is FOUR_LEVEL_SEMIALPHABETIC or
// FOUR_LEVEL.
xkb_implicit_type :: proc(km: ^Xkb_Keymap, g: ^Xkb_Group_Def) -> string {
	n := len(g.vals)
	has :: proc(km: ^Xkb_Keymap, name: string) -> bool {
		_, ok := km.type_of[name]
		return ok
	}
	pick :: proc(km: ^Xkb_Keymap, want, fallback: string) -> string {
		if has(km, want) {
			return want
		}
		return fallback
	}
	at :: proc(g: ^Xkb_Group_Def, i: int) -> u32 {
		return i < len(g.vals) ? g.vals[i] : XKB_SYM_NO
	}
	switch {
	case n <= 1:
		return "ONE_LEVEL"
	case n == 2:
		if xkb_alpha_pair(at(g, 0), at(g, 1)) {
			return pick(km, "ALPHABETIC", "TWO_LEVEL")
		}
		if xkb_sym_is_keypad(at(g, 0)) || xkb_sym_is_keypad(at(g, 1)) {
			return pick(km, "KEYPAD", "TWO_LEVEL")
		}
		return "TWO_LEVEL"
	case n <= 4:
		if xkb_alpha_pair(at(g, 0), at(g, 1)) {
			if xkb_alpha_pair(at(g, 2), at(g, 3)) {
				return pick(km, "FOUR_LEVEL_ALPHABETIC", pick(km, "FOUR_LEVEL", "TWO_LEVEL"))
			}
			return pick(km, "FOUR_LEVEL_SEMIALPHABETIC", pick(km, "FOUR_LEVEL", "TWO_LEVEL"))
		}
		if xkb_sym_is_keypad(at(g, 0)) || xkb_sym_is_keypad(at(g, 1)) {
			return pick(km, "FOUR_LEVEL_KEYPAD", pick(km, "FOUR_LEVEL", "TWO_LEVEL"))
		}
		return pick(km, "FOUR_LEVEL", "TWO_LEVEL")
	}
	return pick(km, "EIGHT_LEVEL", pick(km, "FOUR_LEVEL", "TWO_LEVEL"))
}

// xkb_sym_is_keypad is the KP_Space..KP_Equal block, which is what makes a key
// take the KEYPAD type without anyone saying so.
xkb_sym_is_keypad :: proc(sym: u32) -> bool {
	return sym >= 0xff80 && sym <= 0xffbd
}

// xkb_alpha_pair asks whether two keysyms are the lower and upper case of one
// letter, across the three cased alphabets X11 numbers contiguously.
xkb_alpha_pair :: proc(lo, up: u32) -> bool {
	if lo == XKB_SYM_NO || up == XKB_SYM_NO {
		return false
	}
	switch {
	case lo >= 'a' && lo <= 'z':
		return up == lo - 0x20
	case lo >= 0xe0 && lo <= 0xfe && lo != 0xf7:
		return up == lo - 0x20
	case lo >= 0x6c0 && lo <= 0x6df: // Cyrillic
		return up == lo + 0x20
	case lo >= 0x7e1 && lo <= 0x7f9: // Greek
		return up == lo - 0x20
	}
	return false
}

// ---------------------------------------------------------------------------
// Keymap text
// ---------------------------------------------------------------------------

xkb_write_vmods :: proc(b: ^strings.Builder, km: ^Xkb_Keymap) {
	if len(km.vmods) == 0 {
		return
	}
	strings.write_string(b, "\tvirtual_modifiers ")
	for v, i in km.vmods {
		if i > 0 {strings.write_string(b, ",")}
		strings.write_string(b, v)
	}
	strings.write_string(b, ";\n\n")
}

xkb_keymap_text :: proc(km: ^Xkb_Keymap) -> string {
	xkb_sort_km = km
	b := strings.builder_make()
	strings.write_string(&b, "xkb_keymap {\n")

	// --- keycodes ---
	strings.write_string(&b, "xkb_keycodes \"palmy\" {\n")
	fmt.sbprintf(&b, "\tminimum = %d;\n\tmaximum = %d;\n", km.min_code, km.max_code)
	codes := make([dynamic]u32, 0, len(km.name_of), context.temp_allocator)
	for c in km.name_of {
		append(&codes, c)
	}
	slice.sort(codes[:])
	for c in codes {
		if c < km.min_code || c > km.max_code {
			continue
		}
		fmt.sbprintf(&b, "\t<%s> = %d;\n", km.name_of[c], c)
	}
	anames := make([dynamic]string, 0, len(km.alias), context.temp_allocator)
	for a in km.alias {
		append(&anames, a)
	}
	slice.sort(anames[:])
	for a in anames {
		target := km.alias[a]
		if _, ok := km.code_of[target]; !ok {
			continue
		}
		if _, dup := km.code_of[a]; dup {
			continue
		}
		fmt.sbprintf(&b, "\talias <%s> = <%s>;\n", a, target)
	}
	for ind in km.indicators {
		fmt.sbprintf(&b, "\tindicator %d = \"%s\";\n", ind.index, ind.name)
	}
	strings.write_string(&b, "};\n\n")

	// --- types ---
	strings.write_string(&b, "xkb_types \"palmy\" {\n")
	xkb_write_vmods(&b, km)
	for t in km.types {
		fmt.sbprintf(&b, "\ttype \"%s\" ", t.name)
		strings.write_string(&b, "{\n")
		raw := t.raw
		for line in strings.split_lines_iterator(&raw) {
			l := strings.trim_space(line)
			if l == "" {
				continue
			}
			fmt.sbprintf(&b, "\t\t%s\n", l)
		}
		strings.write_string(&b, "\t};\n")
	}
	strings.write_string(&b, "};\n\n")

	// --- compatibility ---
	strings.write_string(&b, "xkb_compatibility \"palmy\" {\n")
	xkb_write_vmods(&b, km)
	for st in km.compat {
		body := st
		for line in strings.split_lines_iterator(&body) {
			l := strings.trim_space(line)
			if l == "" {
				continue
			}
			fmt.sbprintf(&b, "\t%s\n", l)
		}
	}
	strings.write_string(&b, "};\n\n")

	// --- symbols ---
	strings.write_string(&b, "xkb_symbols \"palmy\" {\n")
	xkb_write_vmods(&b, km)
	for gi in 0 ..< km.ngroups {
		if km.group_names[gi] != "" {
			fmt.sbprintf(&b, "\tname[Group%d]=\"%s\";\n", gi + 1, km.group_names[gi])
		}
	}
	strings.write_string(&b, "\n")
	order := make([dynamic]int, 0, len(km.keys), context.temp_allocator)
	for _, i in km.keys {
		append(&order, i)
	}
	slice.sort_by(order[:], proc(a, b: int) -> bool {
		return xkb_km_sort_key(a) < xkb_km_sort_key(b)
	})
	for ki in order {
		k := &km.keys[ki]
		if k.ngroups == 0 {
			continue
		}
		fmt.sbprintf(&b, "\tkey <%s> ", k.name)
		strings.write_string(&b, "{")
		first := true
		if k.repeat >= 0 {
			fmt.sbprintf(&b, "\n\t\trepeat= %s", k.repeat == 1 ? "Yes" : "No")
			first = false
		}
		if k.vmods != "" {
			fmt.sbprintf(&b, "%s\n\t\tvirtualMods= %s", first ? "" : ",", k.vmods)
			first = false
		}
		for gi in 0 ..< k.ngroups {
			g := &k.groups[gi]
			if !g.used {
				continue
			}
			if g.type_name != "" {
				fmt.sbprintf(&b, "%s\n\t\ttype[Group%d]= \"%s\"", first ? "" : ",", gi + 1, g.type_name)
				first = false
			}
			fmt.sbprintf(&b, "%s\n\t\tsymbols[Group%d]= [", first ? "" : ",", gi + 1)
			first = false
			for v, si in g.vals {
				if si > 0 {strings.write_string(&b, ",")}
				fmt.sbprintf(&b, " %s", xkb_sym_to_name(v))
			}
			strings.write_string(&b, " ]")
		}
		strings.write_string(&b, "\n\t};\n")
	}
	strings.write_string(&b, "\n")
	for mi in 0 ..< 8 {
		mask := u32(1) << uint(mi)
		names := make([dynamic]string, context.temp_allocator)
		for k in km.keys {
			if km.modmap[k.name] & mask != 0 {
				append(&names, k.name)
			}
		}
		if len(names) == 0 {
			continue
		}
		slice.sort(names[:])
		fmt.sbprintf(&b, "\tmodifier_map %s ", xkb_real_mod_name(mi))
		strings.write_string(&b, "{")
		for n, i in names {
			fmt.sbprintf(&b, "%s <%s>", i == 0 ? "" : ",", n)
		}
		strings.write_string(&b, " };\n")
	}
	strings.write_string(&b, "};\n\n")

	strings.write_string(&b, "};\n")
	return strings.to_string(b)
}

// A sort that keeps the emitted symbols section in keycode order. The closure
// needs the keymap, and Odin's sort_by takes a plain procedure, so the keymap
// goes through a package global for the duration of the sort.
xkb_sort_km: ^Xkb_Keymap
xkb_km_sort_key :: proc(i: int) -> u32 {
	if xkb_sort_km == nil || i >= len(xkb_sort_km.keys) {
		return 0
	}
	return xkb_sort_km.keys[i].code
}

xkb_real_mod_name :: proc(i: int) -> string {
	switch i {
	case 0:
		return "Shift"
	case 1:
		return "Lock"
	case 2:
		return "Control"
	case 3:
		return "Mod1"
	case 4:
		return "Mod2"
	case 5:
		return "Mod3"
	case 6:
		return "Mod4"
	case 7:
		return "Mod5"
	}
	return "Mod1"
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

Xkb_State :: struct {
	depressed:    u32,
	latched:      u32,
	locked:       u32,
	group:        int,
	latched_group: int,
	locked_group: int,
	down:         [XKB_KEYCODE_SPAN]bool,
}

xkb_st: Xkb_State

xkb_state_reset :: proc() {
	xkb_st = {}
}

xkb_release_all :: proc() {
	for i in 0 ..< XKB_KEYCODE_SPAN {
		xkb_st.down[i] = false
	}
	xkb_st.depressed = 0
	xkb_st.latched = 0
}

xkb_key_by_code :: proc(km: ^Xkb_Keymap, xkb_code: u32) -> ^Xkb_Key {
	if xkb_code >= XKB_KEYCODE_SPAN {
		return nil
	}
	i := km.by_code[xkb_code]
	if i == 0 {
		return nil
	}
	return &km.keys[i - 1]
}

xkb_effective :: proc(st: ^Xkb_State) -> u32 {
	return st.depressed | st.latched | st.locked
}

xkb_effective_group :: proc(km: ^Xkb_Keymap, st: ^Xkb_State) -> int {
	n := max(km.ngroups, 1)
	g := st.group + st.latched_group + st.locked_group
	// Wrap, which is the default group handling.
	g %= n
	if g < 0 {g += n}
	return g
}

// xkb_lookup resolves a keycode to a keysym under the given modifier state.
// This is the core of the translation table the brief asks for: level and
// group handling in one place.
xkb_lookup :: proc(km: ^Xkb_Keymap, xkb_code: u32, mods: u32, group: int) -> (sym: u32, level: int, consumed: u32) {
	k := xkb_key_by_code(km, xkb_code)
	if k == nil || k.ngroups == 0 {
		return XKB_SYM_NO, 0, 0
	}
	n := max(k.ngroups, 1)
	g := group % n
	if g < 0 {g += n}
	gd := &k.groups[g]
	if !gd.used {
		for i in 0 ..< n {
			if k.groups[i].used {
				gd = &k.groups[i]
				break
			}
		}
	}
	if !gd.used || len(gd.vals) == 0 {
		return XKB_SYM_NO, 0, 0
	}

	lvl := 0
	cons := u32(0)
	if ti, ok := km.type_of[gd.type_name]; ok {
		ty := &km.types[ti]
		masked := mods & ty.mask
		for mp in ty.maps {
			if mp.mask == masked {
				lvl = mp.level - 1
				break
			}
		}
		cons = ty.mask
		for pr in ty.preserve {
			cons &~= xkb_mod_mask(km, pr.mods)
		}
	} else {
		// No type: shift picks level two if there is one.
		if mods & XKB_MOD_SHIFT != 0 && len(gd.vals) > 1 {
			lvl = 1
			cons = XKB_MOD_SHIFT
		}
	}
	if lvl >= len(gd.vals) {
		// The type has more levels than the key defines symbols for, which is
		// what `key.type[Group1] = "FOUR_LEVEL"` over a two-symbol key means.
		// The level is real and empty, not a fall back to level one.
		return XKB_SYM_NO, lvl, cons
	}
	sym = gd.vals[lvl]

	// Caps Lock on a key whose type does not itself handle Lock still has to
	// uppercase, or a two-level non-alphabetic key would ignore caps entirely.
	if mods & XKB_MOD_LOCK != 0 {
		if ti, ok := km.type_of[gd.type_name]; !ok || km.types[ti].mask & XKB_MOD_LOCK == 0 {
			sym = xkb_sym_upper(sym)
		}
	}
	return sym, lvl, cons
}

xkb_sym_upper :: proc(sym: u32) -> u32 {
	switch {
	case sym >= 'a' && sym <= 'z':
		return sym - 0x20
	case sym >= 0xe0 && sym <= 0xfe && sym != 0xf7:
		return sym - 0x20
	}
	return sym
}

// xkb_update_key feeds one key transition into the state. It takes an *evdev*
// keycode, because that is what the input backend has.
xkb_update_key :: proc(evdev_code: u32, down: bool) {
	km := &xkb_km
	if !km.ok {
		return
	}
	code := evdev_code + EV_XKB_OFFSET
	if code >= XKB_KEYCODE_SPAN {
		return
	}
	k := xkb_key_by_code(km, code)

	if down {
		if xkb_st.down[code] {
			return
		}
		xkb_st.down[code] = true
		if k != nil {
			xkb_st.depressed |= km.modmap[k.name]
			// Locking modifiers and group switches act on press. The level
			// that counts is the one the current modifiers select, because
			// toggles like grp:alt_shift_toggle put ISO_Next_Group on the
			// second level of Alt and of Shift; the unmodified level is the
			// fallback for keys whose action sits on level one regardless.
			g := xkb_effective_group(km, &xkb_st)
			sym, _, _ := xkb_lookup(km, code, xkb_effective(&xkb_st), g)
			switch sym {
			case XKB_SYM_CAPS_LOCK, XKB_SYM_SHIFT_LOCK, XKB_SYM_NUM_LOCK, XKB_SYM_ISO_NEXT_GROUP, XKB_SYM_ISO_PREV_GROUP:
			case:
				sym, _, _ = xkb_lookup(km, code, 0, g)
			}
			switch sym {
			case XKB_SYM_CAPS_LOCK:
				xkb_st.locked ~= XKB_MOD_LOCK
			case XKB_SYM_SHIFT_LOCK:
				xkb_st.locked ~= XKB_MOD_SHIFT
			case XKB_SYM_NUM_LOCK:
				xkb_st.locked ~= xkb_mod_mask(km, {"NumLock"})
			case XKB_SYM_ISO_NEXT_GROUP:
				xkb_st.locked_group = (xkb_st.locked_group + 1) % max(km.ngroups, 1)
			case XKB_SYM_ISO_PREV_GROUP:
				xkb_st.locked_group = (xkb_st.locked_group - 1 + max(km.ngroups, 1)) % max(km.ngroups, 1)
			}
		}
	} else {
		if !xkb_st.down[code] {
			return
		}
		xkb_st.down[code] = false
		// Recompute from scratch: a modifier can be mapped by more than one
		// key, and subtracting its mask would unset it while the other is
		// still held.
		xkb_st.depressed = 0
		for c in 0 ..< u32(XKB_KEYCODE_SPAN) {
			if !xkb_st.down[c] {
				continue
			}
			if kk := xkb_key_by_code(km, c); kk != nil {
				xkb_st.depressed |= km.modmap[kk.name]
			}
		}
	}
}

xkb_sym_for :: proc(evdev_code: u32) -> u32 {
	km := &xkb_km
	if !km.ok {
		return XKB_SYM_NO
	}
	sym, _, _ := xkb_lookup(km, evdev_code + EV_XKB_OFFSET, xkb_effective(&xkb_st), xkb_effective_group(km, &xkb_st))
	return sym
}

xkb_serialize :: proc() -> (depressed, latched, locked, group: u32) {
	return xkb_st.depressed, xkb_st.latched, xkb_st.locked, u32(xkb_effective_group(&xkb_km, &xkb_st))
}

// xkb_mods_now is the bridge to palmy's modifier set, which is what the
// nested path already hands handle_keys.
xkb_mods_now :: proc() -> p.Modifiers {
	m := p.Modifiers{}
	e := xkb_effective(&xkb_st)
	if e & XKB_MOD_SHIFT != 0 {m += {.Shift}}
	if e & XKB_MOD_CONTROL != 0 {m += {.Ctrl}}
	if e & XKB_MOD_LOCK != 0 {m += {.Caps}}
	alt := xkb_mod_mask(&xkb_km, {"Alt"})
	sup := xkb_mod_mask(&xkb_km, {"Super"})
	if alt == 0 {alt = XKB_MOD_MOD1}
	if sup == 0 {sup = XKB_MOD_MOD4}
	if e & alt != 0 {m += {.Alt}}
	if e & sup != 0 {m += {.Super}}
	return m
}

// xkb_repeats says whether a key should repeat. The compat data's repeat
// handling is richer than this; the rule used here is that modifiers and locks
// do not repeat and everything else does, which is what a user would say if
// asked.
xkb_repeats :: proc(evdev_code: u32) -> bool {
	km := &xkb_km
	if !km.ok {
		return true
	}
	k := xkb_key_by_code(km, evdev_code + EV_XKB_OFFSET)
	if k == nil {
		return false
	}
	if k.repeat >= 0 {
		return k.repeat == 1
	}
	if km.modmap[k.name] != 0 {
		return false
	}
	if len(k.groups[0].vals) > 0 {
		s := k.groups[0].vals[0]
		if s >= 0xffe1 && s <= 0xffee {
			return false
		}
		if s == XKB_SYM_NUM_LOCK || s == XKB_SYM_CAPS_LOCK || s == XKB_SYM_MODE_SWITCH {
			return false
		}
	}
	return true
}

xkb_keymap_string :: proc() -> string {
	if !xkb_km.ok {
		return ""
	}
	return xkb_km.text
}

// ---------------------------------------------------------------------------
// The hardcoded fallback
//
// Everything above assumes /usr/share/X11/xkb exists. When it does not, this
// is what the compositor uses: a compact US keymap, run through the same
// parser so that the in-memory tables and the text handed to clients come from
// one source here too.
// ---------------------------------------------------------------------------

xkb_compile_fallback :: proc(km: ^Xkb_Keymap, why: string) -> bool {
	xkb_keymap_init(km)
	km.layout = "us"
	km.model = "pc105"
	km.rules = "builtin"
	km.comp_keycodes = "(built in)"
	km.comp_types = "(built in)"
	km.comp_compat = "(built in)"
	km.comp_symbols = "(built in)"
	if !xkb_parse_keymap_text(km, XKB_FALLBACK_KEYMAP) {
		return false
	}
	xkb_finish(km)
	km.source = strings.clone(why)
	km.ok = true
	return true
}

// xkb_parse_keymap_text runs the four section interpreters over a complete
// `xkb_keymap { ... }` document rather than over the component files. It is
// what compiles the fallback, and it is also how a keymap handed to us by
// someone else could be read back.
xkb_parse_keymap_text :: proc(km: ^Xkb_Keymap, text: string) -> bool {
	s := new(Xkb_Src)
	s.path = "<builtin>"
	s.src = text
	s.toks = xkb_lex(text)
	ok := false
	if lo, hi, f := xkb_section(s, "xkb_keycodes", ""); f {
		xkb_keycodes_body(km, s, lo, hi, .Override, 0)
		ok = true
	}
	if lo, hi, f := xkb_section(s, "xkb_types", ""); f {
		xkb_types_body(km, s, lo, hi, .Override, 0)
	}
	if lo, hi, f := xkb_section(s, "xkb_compatibility", ""); f {
		xkb_compat_body(km, s, lo, hi, .Override, 0)
	}
	if lo, hi, f := xkb_section(s, "xkb_symbols", ""); f {
		ctx := Xkb_Sym_Ctx{}
		xkb_symbols_body(km, s, lo, hi, .Override, &ctx, 0)
	}
	return ok && len(km.keys) > 0
}

// ---------------------------------------------------------------------------
// Self test and dump
// ---------------------------------------------------------------------------

xkb_test_pass := 0
xkb_test_fail := 0

xkb_check :: proc(cond: bool, format: string, args: ..any) {
	if cond {
		xkb_test_pass += 1
	} else {
		xkb_test_fail += 1
		fmt.printf("  FAIL  %s\n", fmt.tprintf(format, ..args))
	}
}

xkb_host_rmlvo :: proc(layout_override: string) -> Xkb_Rmlvo {
	env :: proc(n: string) -> string {return os.get_env(n, context.temp_allocator)}
	m := Xkb_Rmlvo {
		rules   = env("XKB_DEFAULT_RULES"),
		model   = env("XKB_DEFAULT_MODEL"),
		layout  = env("XKB_DEFAULT_LAYOUT"),
		variant = env("XKB_DEFAULT_VARIANT"),
	}
	if opts := env("XKB_DEFAULT_OPTIONS"); opts != "" {
		m.options = strings.split(opts, ",")
	}
	// Where a bare-metal machine actually records its layout: systemd-localed
	// writes /etc/vconsole.conf, and the X server's own drop-in is the older
	// place to look. Nothing here runs a command or touches the session.
	if m.layout == "" {
		if text, ok := ev_read_file("/etc/vconsole.conf", context.temp_allocator); ok {
			for line in strings.split_lines_iterator(&text) {
				l := strings.trim_space(line)
				eq := strings.index_byte(l, '=')
				if strings.has_prefix(l, "#") || eq <= 0 {
					continue
				}
				key := strings.trim_space(l[:eq])
				val := strings.trim(strings.trim_space(l[eq + 1:]), "\"")
				switch key {
				case "XKBLAYOUT":
					m.layout = val
				case "XKBVARIANT":
					m.variant = val
				case "XKBMODEL":
					m.model = val
				case "XKBOPTIONS":
					if val != "" {
						m.options = strings.split(val, ",")
					}
				}
			}
		}
	}
	if m.layout == "" {
		if text, ok := ev_read_file("/etc/X11/xorg.conf.d/00-keyboard.conf", context.temp_allocator); ok {
			for line in strings.split_lines_iterator(&text) {
				l := strings.trim_space(line)
				if strings.has_prefix(l, "Option") {
					f := strings.fields(l, context.temp_allocator)
					if len(f) >= 3 {
						key := strings.trim(f[1], "\"")
						val := strings.trim(f[2], "\"")
						switch key {
						case "XkbLayout":
							m.layout = val
						case "XkbVariant":
							m.variant = val
						case "XkbModel":
							m.model = val
						case "XkbOptions":
							m.options = strings.split(val, ",")
						}
					}
				}
			}
		}
	}
	if layout_override != "" {
		// `--xkb-dump fr(oss)` selects a variant too.
		l := layout_override
		if o := strings.index_byte(l, '('); o >= 0 && strings.has_suffix(l, ")") {
			m.variant = l[o + 1:len(l) - 1]
			l = l[:o]
		}
		m.layout = l
	}
	return m
}

xkb_level_mask :: proc(km: ^Xkb_Keymap, level: int) -> u32 {
	alt_gr := xkb_mod_mask(km, {"LevelThree"})
	switch level {
	case 0:
		return 0
	case 1:
		return XKB_MOD_SHIFT
	case 2:
		return alt_gr
	case 3:
		return XKB_MOD_SHIFT | alt_gr
	}
	return 0
}

// xkb_oracle_compare compiles our generated keymap text with libxkbcommon and
// compares every keycode at four modifier states against our own tables. If
// libxkbcommon is not installed the comparison is skipped and says so; when it
// is, this is the strongest check available here, because it proves the text
// we hand to clients means the same thing as the tables we keep.
xkb_oracle_compare :: proc(km: ^Xkb_Keymap, label: string) -> (checked: int, mismatch: int, available: bool) {
	if !xkb_load() {
		return 0, 0, false
	}
	ctx := xkb.xkb_context_new(0)
	if ctx == nil {
		return 0, 0, false
	}
	defer xkb.xkb_context_unref(ctx)
	ctext := strings.clone_to_cstring(km.text, context.temp_allocator)
	lib_km := xkb.xkb_keymap_new_from_string(ctx, ctext, 1, 0)
	if lib_km == nil {
		fmt.printfln("  %s: libxkbcommon REJECTED our keymap text", label)
		return 0, 1, true
	}
	defer xkb.xkb_keymap_unref(lib_km)
	st := xkb.xkb_state_new(lib_km)
	if st == nil {
		return 0, 1, true
	}
	defer xkb.xkb_state_unref(st)

	shown := 0
	for level in 0 ..< 4 {
		mask := xkb_level_mask(km, level)
		xkb.xkb_state_update_mask(st, mask, 0, 0, 0, 0, 0)
		for code in km.min_code ..= km.max_code {
			k := xkb_key_by_code(km, code)
			if k == nil || k.ngroups == 0 {
				continue
			}
			ours, _, _ := xkb_lookup(km, code, mask, 0)
			theirs := xkb.xkb_state_key_get_one_sym(st, code)
			checked += 1
			if ours != theirs {
				mismatch += 1
				if shown < 8 {
					fmt.printfln(
						"  %s: <%s> (%d) level %d: ours %s (0x%x), libxkbcommon %s (0x%x)",
						label,
						k.name,
						code,
						level,
						xkb_sym_to_name(ours),
						ours,
						xkb_sym_to_name(theirs),
						theirs,
					)
					shown += 1
				}
			}
		}
	}
	return checked, mismatch, true
}

// xkb_oracle_rmlvo asks the harder question. The comparison above only proves
// that the text we emit and the tables we keep agree with each other; this one
// asks libxkbcommon to compile the same layout from the same files and
// compares keysym for keysym, which is what says whether the keymap means what
// the layout actually means.
xkb_oracle_rmlvo :: proc(km: ^Xkb_Keymap, layout, variant: string) -> (checked: int, mismatch: int, available: bool) {
	if !xkb_load() {
		return 0, 0, false
	}
	ctx := xkb.xkb_context_new(0)
	if ctx == nil {
		return 0, 0, false
	}
	defer xkb.xkb_context_unref(ctx)
	names := Rule_Names {
		rules   = "evdev",
		model   = strings.clone_to_cstring(km.model, context.temp_allocator),
		layout  = strings.clone_to_cstring(layout, context.temp_allocator),
		variant = variant == "" ? nil : strings.clone_to_cstring(variant, context.temp_allocator),
		options = km.options == "" ? nil : strings.clone_to_cstring(km.options, context.temp_allocator),
	}
	lib := xkb.xkb_keymap_new_from_names(ctx, &names, 0)
	if lib == nil {
		return 0, 0, false
	}
	defer xkb.xkb_keymap_unref(lib)
	st := xkb.xkb_state_new(lib)
	if st == nil {
		return 0, 0, false
	}
	defer xkb.xkb_state_unref(st)

	shown := 0
	for level in 0 ..< 4 {
		mask := xkb_level_mask(km, level)
		xkb.xkb_state_update_mask(st, mask, 0, 0, 0, 0, 0)
		for code in km.min_code ..= km.max_code {
			k := xkb_key_by_code(km, code)
			if k == nil || k.ngroups == 0 {
				continue
			}
			ours, _, _ := xkb_lookup(km, code, mask, 0)
			theirs := xkb.xkb_state_key_get_one_sym(st, code)
			checked += 1
			if ours != theirs {
				mismatch += 1
				if shown < 10 && !xkb_oracle_quiet {
					fmt.printfln(
						"    %s: <%s> (%d) level %d: ours %s, xkbcommon %s",
						layout,
						k.name,
						code,
						level + 1,
						xkb_sym_to_name(ours),
						xkb_sym_to_name(theirs),
					)
					shown += 1
				}
			}
		}
	}
	return checked, mismatch, true
}

xkb_oracle_quiet := false

xkb_oracle_rmlvo_quiet :: proc(km: ^Xkb_Keymap, layout: string) -> (checked: int, mismatch: int, available: bool) {
	xkb_oracle_quiet = true
	defer xkb_oracle_quiet = false
	return xkb_oracle_rmlvo(km, layout, "")
}

xkb_selftest :: proc() -> int {
	xkb_test_pass = 0
	xkb_test_fail = 0
	fmt.println("xkb compiler self test")
	fmt.println()

	// --- Lexer --------------------------------------------------------------
	fmt.println("lexer")
	{
		toks := xkb_lex("// a comment\nkey <AE01> {[ 1, exclam ]}; /* block */ x", context.temp_allocator)
		kinds := make([dynamic]Xkb_Tok_Kind, context.temp_allocator)
		for t in toks {
			append(&kinds, t.kind)
		}
		xkb_check(len(toks) >= 10, "the statement lexes, got %d tokens", len(toks))
		xkb_check(toks[0].kind == .Ident && toks[0].text == "key", "comments are skipped, first token is %v %q", toks[0].kind, toks[0].text)
		xkb_check(toks[1].kind == .Key && toks[1].text == "AE01", "a key name loses its angles, got %q", toks[1].text)
		last := toks[len(toks) - 2]
		xkb_check(last.kind == .Ident && last.text == "x", "a block comment is skipped, last token is %q", last.text)
	}
	{
		toks := xkb_lex("name[Group1]= \"English (US)\";", context.temp_allocator)
		found := false
		for t in toks {
			if t.kind == .Str && t.text == "English (US)" {found = true}
		}
		xkb_check(found, "a quoted string with parentheses survives")
	}

	// --- Keysym names -------------------------------------------------------
	fmt.println("keysym names")
	{
		xkb_check(xkb_sym_from_name("a") == 0x61, "a is 0x61, got 0x%x", xkb_sym_from_name("a"))
		xkb_check(xkb_sym_from_name("A") == 0x41, "A is 0x41")
		xkb_check(xkb_sym_from_name("1") == 0x31, "1 is 0x31, got 0x%x", xkb_sym_from_name("1"))
		xkb_check(xkb_sym_from_name("exclam") == 0x21, "exclam is 0x21")
		xkb_check(xkb_sym_from_name("BackSpace") == 0xff08, "BackSpace is 0xff08")
		xkb_check(xkb_sym_from_name("eacute") == 0xe9, "eacute is 0xe9, got 0x%x", xkb_sym_from_name("eacute"))
		xkb_check(xkb_sym_from_name("EuroSign") == 0x20ac, "EuroSign is 0x20ac")
		xkb_check(xkb_sym_from_name("dead_circumflex") == 0xfe52, "dead_circumflex is 0xfe52, got 0x%x", xkb_sym_from_name("dead_circumflex"))
		xkb_check(xkb_sym_from_name("ISO_Level3_Shift") == 0xfe03, "ISO_Level3_Shift is 0xfe03")
		xkb_check(xkb_sym_from_name("U2022") == 0x1002022, "U2022 becomes a Unicode keysym, got 0x%x", xkb_sym_from_name("U2022"))
		xkb_check(xkb_sym_from_name("U00E9") == 0xe9, "a Unicode keysym below 0x100 folds to Latin-1, got 0x%x", xkb_sym_from_name("U00E9"))
		xkb_check(xkb_sym_from_name("XF86_Switch_VT_1") != 0, "the XF86_ spelling resolves")
		xkb_check(xkb_sym_from_name("XF86AudioRaiseVolume") == 0x1008ff13, "XF86AudioRaiseVolume resolves")
		xkb_check(xkb_sym_from_name("NoSymbol") == 0, "NoSymbol is zero")
		xkb_check(xkb_sym_to_name(0x61) == "a", "the reverse of 0x61 is a, got %q", xkb_sym_to_name(0x61))
		xkb_check(xkb_sym_to_rune(0x1002022) == '•', "a Unicode keysym carries its codepoint")
	}

	// --- Include specs ------------------------------------------------------
	fmt.println("include specifications")
	{
		incs := xkb_parse_include_list("pc+fr(oss):2|inet(evdev)", .Override, context.temp_allocator)
		xkb_check(len(incs) == 3, "three components, got %d", len(incs))
		if len(incs) == 3 {
			xkb_check(incs[0].file == "pc" && incs[0].section == "", "the first is pc with no section")
			xkb_check(incs[1].file == "fr" && incs[1].section == "oss", "the second is fr(oss), got %q(%q)", incs[1].file, incs[1].section)
			xkb_check(incs[1].group == 2, "with a group index of 2, got %d", incs[1].group)
			xkb_check(incs[1].merge == .Override, "+ means override")
			xkb_check(incs[2].merge == .Augment, "| means augment")
		}
		one := xkb_parse_include_list("macintosh_vndr/apple(alukbd)", .Override, context.temp_allocator)
		xkb_check(len(one) == 1 && one[0].file == "macintosh_vndr/apple", "a vendor subdirectory survives, got %q", one[0].file)
	}

	// --- The built-in fallback ---------------------------------------------
	fmt.println("the hardcoded fallback keymap")
	{
		fb: Xkb_Keymap
		ok := xkb_compile_fallback(&fb, "self test")
		xkb_check(ok, "the fallback compiles")
		xkb_check(len(fb.keys) > 80, "and has a full keyboard, %d keys", len(fb.keys))
		rc, rb, ra := xkb_oracle_rmlvo(&fb, "us", "")
		if ra {
			xkb_check(rb == 0, "and types the same as a real US layout, %d of %d keysyms differ", rb, rc)
		}
		xkb_check(fb.code_of["AD01"] == 24, "Q is keycode 24, got %d", fb.code_of["AD01"])

		saved := xkb_km
		xkb_km = fb
		xkb_sort_km = &xkb_km
		xkb_state_reset()
		q := u32(EV_KEY_Q) // evdev 16, xkb 24
		xkb_check(xkb_sym_for(q) == 'q', "evdev 16 is q, got %s", xkb_sym_to_name(xkb_sym_for(q)))
		xkb_update_key(EV_KEY_LEFTSHIFT, true)
		xkb_check(xkb_sym_for(q) == 'Q', "shifted it is Q, got %s", xkb_sym_to_name(xkb_sym_for(q)))
		xkb_check(.Shift in xkb_mods_now(), "and the modifier set says shift")
		xkb_update_key(EV_KEY_LEFTSHIFT, false)
		xkb_check(xkb_sym_for(q) == 'q', "and q again after release")

		// Caps Lock is a locking modifier: one press, and it stays.
		xkb_update_key(EV_KEY_CAPSLOCK, true)
		xkb_update_key(EV_KEY_CAPSLOCK, false)
		xkb_check(xkb_sym_for(q) == 'Q', "caps lock locks, got %s", xkb_sym_to_name(xkb_sym_for(q)))
		_, _, locked, _ := xkb_serialize()
		xkb_check(locked & XKB_MOD_LOCK != 0, "and shows up in the locked mask, got 0x%x", locked)
		xkb_check(.Caps in xkb_mods_now(), "and in the modifier set")
		// A digit is not alphabetic, so caps must leave it alone.
		xkb_check(xkb_sym_for(2) == '1', "caps does not shift the number row, got %s", xkb_sym_to_name(xkb_sym_for(2)))
		xkb_update_key(EV_KEY_CAPSLOCK, true)
		xkb_update_key(EV_KEY_CAPSLOCK, false)
		xkb_check(xkb_sym_for(q) == 'q', "a second press unlocks it")

		// Two keys mapped to the same modifier: releasing one must not clear it.
		xkb_update_key(EV_KEY_LEFTSHIFT, true)
		xkb_update_key(54, true) // RIGHTSHIFT
		xkb_update_key(EV_KEY_LEFTSHIFT, false)
		xkb_check(xkb_sym_for(q) == 'Q', "shift survives while the other shift is held")
		xkb_update_key(54, false)
		xkb_check(xkb_sym_for(q) == 'q', "and goes when both are up")

		xkb_check(xkb_repeats(EV_KEY_Q), "a letter repeats")
		xkb_check(!xkb_repeats(EV_KEY_LEFTSHIFT), "a modifier does not")
		xkb_check(!xkb_repeats(EV_KEY_CAPSLOCK), "nor does caps lock")

		// Num Lock drives the keypad through the KEYPAD type.
		xkb_update_key(71, false)
		kp7 := u32(71) // KEY_KP7, xkb 79
		base := xkb_sym_for(kp7)
		xkb_update_key(69, true) // NUMLOCK
		xkb_update_key(69, false)
		numd := xkb_sym_for(kp7)
		xkb_check(base != numd, "num lock changes the keypad: %s then %s", xkb_sym_to_name(base), xkb_sym_to_name(numd))
		xkb_check(numd == xkb_sym_from_name("KP_7"), "and gives KP_7, got %s", xkb_sym_to_name(numd))
		xkb_update_key(69, true)
		xkb_update_key(69, false)

		xkb_check(strings.contains(fb.text, "xkb_keymap {"), "the fallback emits a keymap document")
		xkb_check(strings.contains(fb.text, "xkb_symbols"), "with a symbols section")
		checked, bad, avail := xkb_oracle_compare(&fb, "fallback")
		if avail {
			xkb_check(bad == 0, "libxkbcommon agrees with the fallback on all %d lookups, %d differ", checked, bad)
			xkb_check(checked > 300, "and the comparison covered %d lookups", checked)
		} else {
			fmt.println("  (libxkbcommon not available; the oracle comparison was skipped)")
		}
		xkb_km = saved
		xkb_sort_km = &xkb_km
	}

	// --- The system XKB data ------------------------------------------------
	fmt.println("the system XKB data")
	{
		_, rok := ev_read_file(fmt.tprintf("%s/rules/evdev", xkb_root()), context.temp_allocator)
		if !rok {
			fmt.printfln("  (%s is missing; the system-data tests were skipped)", xkb_root())
		} else {
			rules, ok := xkb_rules_parse(fmt.tprintf("%s/rules/evdev", xkb_root()))
			xkb_check(ok, "rules/evdev parses")
			xkb_check(len(rules.tables) > 10, "into %d tables", len(rules.tables))
			xkb_check(len(rules.groups) > 5, "and %d $groups", len(rules.groups))

			m := Xkb_Rmlvo {
				rules  = "evdev",
				model  = "pc105",
				layout = "us",
			}
			sy := xkb_rules_resolve(&rules, &m, "symbols")
			xkb_check(strings.contains(sy, "pc") && strings.contains(sy, "us"), "us resolves to %q", sy)
			xkb_check(strings.contains(sy, "inet(evdev)"), "including the inet media keys")
			kc := xkb_rules_resolve(&rules, &m, "keycodes")
			xkb_check(strings.contains(kc, "evdev"), "keycodes resolve to %q", kc)

			mv := Xkb_Rmlvo {
				rules   = "evdev",
				model   = "pc105",
				layout  = "fr",
				variant = "oss",
			}
			syv := xkb_rules_resolve(&rules, &mv, "symbols")
			xkb_check(strings.contains(syv, "fr(oss)"), "a variant resolves to %q", syv)

			for lay in ([?]string{"us", "fr", "de", "gb"}) {
				k: Xkb_Keymap
				cok := xkb_compile(&k, Xkb_Rmlvo{layout = lay})
				xkb_check(cok, "%s compiles", lay)
				xkb_check(len(k.keys) > 100, "%s has %d keys", lay, len(k.keys))
				xkb_check(len(k.types) > 10, "%s has %d key types", lay, len(k.types))
				xkb_check(k.text != "", "%s produced keymap text, %d bytes", lay, len(k.text))
				xkb_check(len(k.compat) > 10, "%s carried %d compat statements", lay, len(k.compat))
				xkb_check(k.modmap["LFSH"] == XKB_MOD_SHIFT, "%s maps left shift to Shift, got 0x%x", lay, k.modmap["LFSH"])
				xkb_check(k.modmap["LCTL"] == XKB_MOD_CONTROL, "%s maps left control to Control", lay)
				xkb_check(k.modmap["LWIN"] == XKB_MOD_MOD4, "%s maps the super key to Mod4", lay)
				xkb_check(k.vmod_mask["LevelThree"] != 0, "%s bound LevelThree to 0x%x", lay, k.vmod_mask["LevelThree"])

				// Layout-specific spot checks against what the layout is for.
				ad01 := k.code_of["AD01"]
				s0, _, _ := xkb_lookup(&k, ad01, 0, 0)
				switch lay {
				case "us", "gb":
					xkb_check(s0 == 'q', "%s: the first key of the top row is q, got %s", lay, xkb_sym_to_name(s0))
				case "fr":
					xkb_check(s0 == 'a', "fr: AZERTY puts a there, got %s", xkb_sym_to_name(s0))
				case "de":
					xkb_check(s0 == 'q', "de: QWERTZ still starts with q, got %s", xkb_sym_to_name(s0))
				}

				ch, bad, avail := xkb_oracle_compare(&k, lay)
				if avail {
					xkb_check(bad == 0, "%s: libxkbcommon reads our keymap text the way we do, %d of %d lookups differ", lay, bad, ch)
					xkb_check(ch > 400, "%s: the comparison covered %d lookups", lay, ch)
				}
				rch, rbad, ravail := xkb_oracle_rmlvo(&k, lay, "")
				if ravail {
					rate := rch == 0 ? 0.0 : f64(rbad) / f64(rch) * 100
					fmt.printfln("  %s: against libxkbcommon's own compile of the same layout: %d of %d keysyms differ (%.2f%%)", lay, rbad, rch, rate)
					xkb_check(rch > 400, "%s: the independent comparison covered %d lookups", lay, rch)
					xkb_check(rbad == 0, "%s: every keysym matches libxkbcommon, %d of %d differ (%.2f%%)", lay, rbad, rch, rate)
				}
			}

			// A French layout is where levels and dead keys actually matter.
			fr: Xkb_Keymap
			if xkb_compile(&fr, Xkb_Rmlvo{layout = "fr"}) {
				ae02 := fr.code_of["AE02"]
				s0, _, _ := xkb_lookup(&fr, ae02, 0, 0)
				s1, _, _ := xkb_lookup(&fr, ae02, XKB_MOD_SHIFT, 0)
				l3 := fr.vmod_mask["LevelThree"]
				s2, lv2, _ := xkb_lookup(&fr, ae02, l3, 0)
				xkb_check(s0 == xkb_sym_from_name("eacute"), "fr AE02 unshifted is eacute, got %s", xkb_sym_to_name(s0))
				xkb_check(s1 == '2', "fr AE02 shifted is 2, got %s", xkb_sym_to_name(s1))
				xkb_check(lv2 == 2, "AltGr selects level three, got level %d", lv2 + 1)
				xkb_check(s2 == xkb_sym_from_name("asciitilde"), "and gives asciitilde, got %s", xkb_sym_to_name(s2))
				ad11 := fr.code_of["AD11"]
				sd, _, _ := xkb_lookup(&fr, ad11, 0, 0)
				xkb_check(sd == xkb_sym_from_name("dead_circumflex"), "fr AD11 is the dead circumflex, got %s", xkb_sym_to_name(sd))
				ad03 := fr.code_of["AD03"]
				se, _, _ := xkb_lookup(&fr, ad03, l3, 0)
				xkb_check(se == xkb_sym_from_name("EuroSign"), "AltGr+e is the euro sign, got %s", xkb_sym_to_name(se))
			}

			// A dvorak variant proves variant resolution end to end.
			dv: Xkb_Keymap
			if xkb_compile(&dv, Xkb_Rmlvo{layout = "us", variant = "dvorak"}) {
				s, _, _ := xkb_lookup(&dv, dv.code_of["AD01"], 0, 0)
				xkb_check(s == xkb_sym_from_name("apostrophe"), "us(dvorak) puts an apostrophe on AD01, got %s", xkb_sym_to_name(s))
			}
		}
	}


	// --- Layout sweep -------------------------------------------------------
	//
	// Four layouts is not a claim about the other three hundred. This walks
	// every layout file xkeyboard-config ships, compiles it, and compares the
	// whole keymap against libxkbcommon's own compile of the same thing. The
	// number it prints is the real coverage figure.
	fmt.println("layout sweep")
	{
		dir, derr := os.open(fmt.tprintf("%s/symbols", xkb_root()))
		if derr == nil {
			defer os.close(dir)
			entries, rerr := os.read_dir(dir, -1, context.temp_allocator)
			if rerr == nil {
				names := make([dynamic]string, context.temp_allocator)
				for e in entries {
					if e.type != .Regular || strings.contains(e.name, ".") || e.name == "README" {
						continue
					}
					append(&names, strings.clone(e.name, context.temp_allocator))
				}
				slice.sort(names[:])
				total, exact, compared, syms, bad_syms := 0, 0, 0, 0, 0
				worst := ""
				worst_n := 0
				for n in names {
					k: Xkb_Keymap
					if !xkb_compile(&k, Xkb_Rmlvo{layout = n}) {
						continue
					}
					if k.rules == "builtin" {
						continue // no such layout; the fallback kicked in
					}
					total += 1
					ch, bd, av := xkb_oracle_rmlvo_quiet(&k, n)
					if !av || ch == 0 {
						continue
					}
					compared += 1
					syms += ch
					bad_syms += bd
					if bd == 0 {
						exact += 1
					} else if bd > worst_n {
						worst_n = bd
						worst = n
					}
				}
				if compared > 0 {
					fmt.printfln(
						"  %d of %d layout files compile to a keymap identical to libxkbcommon's, %d of %d keysyms differ overall",
						exact,
						compared,
						bad_syms,
						syms,
					)
					if worst != "" {
						fmt.printfln("  worst layout: %s, %d keysyms", worst, worst_n)
					}
					xkb_check(compared > 100, "the sweep covered %d layouts", compared)
					xkb_check(exact == compared, "every layout matches libxkbcommon exactly, %d of %d do", exact, compared)
					xkb_check(bad_syms == 0, "no keysym anywhere differs, %d of %d do", bad_syms, syms)
				}
			}
		}
	}

	// --- Options and groups -------------------------------------------------
	fmt.println("options and layout groups")
	{
		k: Xkb_Keymap
		if xkb_compile(&k, Xkb_Rmlvo{layout = "us", options = {"terminate:ctrl_alt_bksp"}}) {
			xkb_check(
				strings.contains(k.comp_symbols, "terminate"),
				"an option reaches the symbol list, got %q",
				k.comp_symbols,
			)
			found := false
			for key in k.keys {
				for v in key.groups[0].vals {
					if v == xkb_sym_from_name("Terminate_Server") {found = true}
				}
			}
			xkb_check(found, "and Terminate_Server is actually bound")
		}

		// A second group, loaded with the `:2` suffix the rules use for a
		// multi-layout keymap.
		g: Xkb_Keymap
		xkb_keymap_init(&g)
		g.layout = "us"
		xkb_load_keycodes(&g, "evdev", .Override, 0)
		xkb_load_types(&g, "complete", .Override, 0)
		xkb_load_compat(&g, "complete", .Override, 0)
		xkb_load_symbols(&g, "pc+us+de:2", .Override, 0, 0)
		xkb_finish(&g)
		g.ok = true
		xkb_check(g.ngroups == 2, "two layouts make two groups, got %d", g.ngroups)
		ad06 := g.code_of["AD06"]
		s1, _, _ := xkb_lookup(&g, ad06, 0, 0)
		s2, _, _ := xkb_lookup(&g, ad06, 0, 1)
		xkb_check(s1 == 'y', "group one is QWERTY, got %s", xkb_sym_to_name(s1))
		xkb_check(s2 == 'z', "group two is QWERTZ, got %s", xkb_sym_to_name(s2))
		xkb_check(g.group_names[1] != "", "and group two has a name: %q", g.group_names[1])

		saved := xkb_km
		xkb_km = g
		xkb_state_reset()
		xkb_check(xkb_sym_for(21) == 'y', "the state machine starts in group one")
		xkb_st.locked_group = 1
		xkb_check(xkb_sym_for(21) == 'z', "and follows a group switch, got %s", xkb_sym_to_name(xkb_sym_for(21)))
		_, _, _, grp := xkb_serialize()
		xkb_check(grp == 1, "which is what goes on the wire, got %d", grp)
		xkb_state_reset()
		xkb_km = saved
		xkb_sort_km = &xkb_km
	}

	fmt.println()
	fmt.printf("xkb: %d passed, %d failed\n", xkb_test_pass, xkb_test_fail)
	return xkb_test_fail
}

xkb_dump :: proc(layout: string) -> int {
	m := xkb_host_rmlvo(layout)
	km: Xkb_Keymap
	if !xkb_compile(&km, m) {
		fmt.eprintfln("xkb: could not compile a keymap for %q", layout)
		return 1
	}
	xkb_sort_km = &km
	km.text = xkb_keymap_text(&km)

	fmt.printfln("rules    %s", km.rules)
	fmt.printfln("model    %s", km.model)
	fmt.printfln("layout   %s", km.layout)
	fmt.printfln("variant  %s", km.variant == "" ? "(none)" : km.variant)
	fmt.printfln("options  %s", km.options == "" ? "(none)" : km.options)
	fmt.println()
	fmt.printfln("keycodes %s", km.comp_keycodes)
	fmt.printfln("types    %s", km.comp_types)
	fmt.printfln("compat   %s", km.comp_compat)
	fmt.printfln("symbols  %s", km.comp_symbols)
	fmt.println()
	fmt.printfln(
		"%d keycode names, %d keys, %d types, %d compat statements, %d groups, %d bytes of keymap text",
		len(km.code_of),
		len(km.keys),
		len(km.types),
		len(km.compat),
		km.ngroups,
		len(km.text),
	)
	for v in km.vmods {
		if mask, ok := km.vmod_mask[v]; ok && mask != 0 {
			fmt.printf("  %s=0x%02x", v, mask)
		}
	}
	fmt.println()
	checked, bad, avail := xkb_oracle_compare(&km, "dump")
	if avail {
		fmt.printfln("libxkbcommon re-reading our text: %d lookups, %d mismatches", checked, bad)
		rch, rbad, _ := xkb_oracle_rmlvo(&km, km.layout, km.variant)
		fmt.printfln("libxkbcommon compiling the same layout itself: %d lookups, %d mismatches", rch, rbad)
	} else {
		fmt.println("libxkbcommon cross-check: skipped, the library is not available")
	}
	fmt.println()
	fmt.println(km.text)
	return bad == 0 ? 0 : 1
}

// xkb_init_default is what main.odin calls on bare metal in place of
// `keytable_build(&s.kt, p.host_keymap(app), host_layout())`. It never fails
// in a way that leaves the keyboard dead.
xkb_init_default :: proc(layout := "") -> bool {
	m := xkb_host_rmlvo(layout)
	if !xkb_compile(&xkb_km, m) {
		xkb_compile_fallback(&xkb_km, "the built-in US keymap")
	}
	xkb_sort_km = &xkb_km
	xkb_km.text = xkb_keymap_text(&xkb_km)
	xkb_state_reset()
	return xkb_km.ok
}

// ---------------------------------------------------------------------------
// Data
// ---------------------------------------------------------------------------

// XKB_FALLBACK_KEYMAP is the keyboard the compositor has when the system has
// no XKB data at all. It is a US pc105 layout, written out by hand: every key
// that a laptop or a desktop keyboard actually has, the four key types those
// keys need, and enough compat for Caps Lock and Num Lock to latch. It is
// parsed by the same code that reads /usr/share/X11/xkb, so the tables and the
// text clients receive come from one place here as well.
XKB_FALLBACK_KEYMAP :: `xkb_keymap {
xkb_keycodes "palmy_fallback" {
	minimum = 8;
	maximum = 255;
	<ESC>  =   9;
	<AE01> =  10;  <AE02> =  11;  <AE03> =  12;  <AE04> =  13;
	<AE05> =  14;  <AE06> =  15;  <AE07> =  16;  <AE08> =  17;
	<AE09> =  18;  <AE10> =  19;  <AE11> =  20;  <AE12> =  21;
	<BKSP> =  22;
	<TAB>  =  23;
	<AD01> =  24;  <AD02> =  25;  <AD03> =  26;  <AD04> =  27;
	<AD05> =  28;  <AD06> =  29;  <AD07> =  30;  <AD08> =  31;
	<AD09> =  32;  <AD10> =  33;  <AD11> =  34;  <AD12> =  35;
	<RTRN> =  36;
	<LCTL> =  37;
	<AC01> =  38;  <AC02> =  39;  <AC03> =  40;  <AC04> =  41;
	<AC05> =  42;  <AC06> =  43;  <AC07> =  44;  <AC08> =  45;
	<AC09> =  46;  <AC10> =  47;  <AC11> =  48;
	<TLDE> =  49;
	<LFSH> =  50;
	<BKSL> =  51;
	<AB01> =  52;  <AB02> =  53;  <AB03> =  54;  <AB04> =  55;
	<AB05> =  56;  <AB06> =  57;  <AB07> =  58;  <AB08> =  59;
	<AB09> =  60;  <AB10> =  61;
	<RTSH> =  62;
	<KPMU> =  63;
	<LALT> =  64;
	<SPCE> =  65;
	<CAPS> =  66;
	<FK01> =  67;  <FK02> =  68;  <FK03> =  69;  <FK04> =  70;
	<FK05> =  71;  <FK06> =  72;  <FK07> =  73;  <FK08> =  74;
	<FK09> =  75;  <FK10> =  76;
	<NMLK> =  77;
	<SCLK> =  78;
	<KP7>  =  79;  <KP8>  =  80;  <KP9>  =  81;  <KPSU> =  82;
	<KP4>  =  83;  <KP5>  =  84;  <KP6>  =  85;  <KPAD> =  86;
	<KP1>  =  87;  <KP2>  =  88;  <KP3>  =  89;  <KP0>  =  90;
	<KPDL> =  91;
	<LVL3> =  92;
	<LSGT> =  94;
	<FK11> =  95;  <FK12> =  96;
	<KPEN> = 104;
	<RCTL> = 105;
	<KPDV> = 106;
	<PRSC> = 107;
	<RALT> = 108;
	<HOME> = 110;  <UP>   = 111;  <PGUP> = 112;  <LEFT> = 113;
	<RGHT> = 114;  <END>  = 115;  <DOWN> = 116;  <PGDN> = 117;
	<INS>  = 118;  <DELE> = 119;
	<MUTE> = 121;  <VOL-> = 122;  <VOL+> = 123;
	<PAUS> = 127;
	<LWIN> = 133;  <RWIN> = 134;  <COMP> = 135;
	indicator 1 = "Caps Lock";
	indicator 2 = "Num Lock";
	indicator 3 = "Scroll Lock";
};
xkb_types "palmy_fallback" {
	virtual_modifiers NumLock,Alt,LevelThree,Super;
	type "ONE_LEVEL" {
		modifiers= none;
		map[none]= Level1;
		level_name[Level1]= "Any";
	};
	type "TWO_LEVEL" {
		modifiers= Shift;
		map[none]= Level1;
		map[Shift]= Level2;
		level_name[Level1]= "Base";
		level_name[Level2]= "Shift";
	};
	type "ALPHABETIC" {
		modifiers= Shift+Lock;
		map[none]= Level1;
		map[Shift]= Level2;
		map[Lock]= Level2;
		map[Shift+Lock]= Level1;
		level_name[Level1]= "Base";
		level_name[Level2]= "Caps";
	};
	type "PC_ALT_LEVEL2" {
		modifiers= Alt;
		map[none]= Level1;
		map[Alt]= Level2;
		level_name[Level1]= "Base";
		level_name[Level2]= "Alt";
	};
	type "PC_CONTROL_LEVEL2" {
		modifiers= Control;
		map[none]= Level1;
		map[Control]= Level2;
		level_name[Level1]= "Base";
		level_name[Level2]= "Control";
	};
	type "FOUR_LEVEL" {
		modifiers= Shift+LevelThree;
		map[none]= Level1;
		map[Shift]= Level2;
		map[LevelThree]= Level3;
		map[Shift+LevelThree]= Level4;
		level_name[Level1]= "Base";
		level_name[Level2]= "Shift";
		level_name[Level3]= "Alt Base";
		level_name[Level4]= "Shift Alt";
	};
	type "FOUR_LEVEL_SEMIALPHABETIC" {
		modifiers= Shift+Lock+LevelThree;
		map[none]= Level1;
		map[Shift]= Level2;
		map[Lock]= Level2;
		map[LevelThree]= Level3;
		map[Shift+LevelThree]= Level4;
		map[Lock+LevelThree]= Level3;
		preserve[Lock+LevelThree]= Lock;
		map[Lock+Shift+LevelThree]= Level4;
		preserve[Lock+Shift+LevelThree]= Lock;
		level_name[Level1]= "Base";
		level_name[Level2]= "Shift";
		level_name[Level3]= "AltGr Base";
		level_name[Level4]= "Shift AltGr";
	};
	type "KEYPAD" {
		modifiers= NumLock;
		map[none]= Level1;
		map[NumLock]= Level2;
		level_name[Level1]= "Base";
		level_name[Level2]= "Number";
	};
};
xkb_compatibility "palmy_fallback" {
	virtual_modifiers NumLock,Alt,LevelThree,Super;
	interpret.useModMapMods= AnyLevel;
	interpret.repeat= False;
	interpret Shift_Lock+AnyOf(Shift+Lock) {
		action= LockMods(modifiers=Shift);
	};
	interpret Any+Lock {
		action= LockMods(modifiers=Lock);
	};
	interpret Num_Lock+Any {
		virtualModifier= NumLock;
		action= LockMods(modifiers=NumLock);
	};
	interpret ISO_Level3_Shift+Any {
		virtualModifier= LevelThree;
		useModMapMods= level1;
		action= SetMods(modifiers=LevelThree,clearLocks);
	};
	interpret Any+Any {
		action= SetMods(modifiers=modMapMods,clearLocks);
	};
	indicator "Caps Lock" {
		whichModState= Locked;
		modifiers= Lock;
	};
	indicator "Num Lock" {
		whichModState= Locked;
		modifiers= NumLock;
	};
};
xkb_symbols "palmy_fallback" {
	name[Group1]="English (US)";

	key <ESC>  {[ Escape ]};
	key <TLDE> {[ grave, asciitilde ]};
	key <AE01> {[ 1, exclam ]};
	key <AE02> {[ 2, at ]};
	key <AE03> {[ 3, numbersign ]};
	key <AE04> {[ 4, dollar ]};
	key <AE05> {[ 5, percent ]};
	key <AE06> {[ 6, asciicircum ]};
	key <AE07> {[ 7, ampersand ]};
	key <AE08> {[ 8, asterisk ]};
	key <AE09> {[ 9, parenleft ]};
	key <AE10> {[ 0, parenright ]};
	key <AE11> {[ minus, underscore ]};
	key <AE12> {[ equal, plus ]};
	key <BKSP> {[ BackSpace, BackSpace ]};

	key <TAB>  {[ Tab, ISO_Left_Tab ]};
	key <AD01> { type="ALPHABETIC", [ q, Q ]};
	key <AD02> { type="ALPHABETIC", [ w, W ]};
	key <AD03> { type="ALPHABETIC", [ e, E ]};
	key <AD04> { type="ALPHABETIC", [ r, R ]};
	key <AD05> { type="ALPHABETIC", [ t, T ]};
	key <AD06> { type="ALPHABETIC", [ y, Y ]};
	key <AD07> { type="ALPHABETIC", [ u, U ]};
	key <AD08> { type="ALPHABETIC", [ i, I ]};
	key <AD09> { type="ALPHABETIC", [ o, O ]};
	key <AD10> { type="ALPHABETIC", [ p, P ]};
	key <AD11> {[ bracketleft, braceleft ]};
	key <AD12> {[ bracketright, braceright ]};
	key <BKSL> {[ backslash, bar ]};
	key <RTRN> {[ Return ]};

	key <CAPS> {[ Caps_Lock ]};
	key <AC01> { type="ALPHABETIC", [ a, A ]};
	key <AC02> { type="ALPHABETIC", [ s, S ]};
	key <AC03> { type="ALPHABETIC", [ d, D ]};
	key <AC04> { type="ALPHABETIC", [ f, F ]};
	key <AC05> { type="ALPHABETIC", [ g, G ]};
	key <AC06> { type="ALPHABETIC", [ h, H ]};
	key <AC07> { type="ALPHABETIC", [ j, J ]};
	key <AC08> { type="ALPHABETIC", [ k, K ]};
	key <AC09> { type="ALPHABETIC", [ l, L ]};
	key <AC10> {[ semicolon, colon ]};
	key <AC11> {[ apostrophe, quotedbl ]};

	key <LFSH> {[ Shift_L ]};
	key <LSGT> {[ less, greater, bar, brokenbar ]};
	key <AB01> { type="ALPHABETIC", [ z, Z ]};
	key <AB02> { type="ALPHABETIC", [ x, X ]};
	key <AB03> { type="ALPHABETIC", [ c, C ]};
	key <AB04> { type="ALPHABETIC", [ v, V ]};
	key <AB05> { type="ALPHABETIC", [ b, B ]};
	key <AB06> { type="ALPHABETIC", [ n, N ]};
	key <AB07> { type="ALPHABETIC", [ m, M ]};
	key <AB08> {[ comma, less ]};
	key <AB09> {[ period, greater ]};
	key <AB10> {[ slash, question ]};
	key <RTSH> {[ Shift_R ]};

	key <LCTL> {[ Control_L ]};
	key <LWIN> {[ Super_L ]};
	key <LALT> {[ Alt_L ]};
	key <SPCE> {[ space ]};
	key <RALT> {[ Alt_R ]};
	key <LVL3> {[ ISO_Level3_Shift ]};
	key <RWIN> {[ Super_R ]};
	key <COMP> {[ Menu ]};
	key <RCTL> {[ Control_R ]};

	key <FK01> {[ F1 ]};
	key <FK02> {[ F2 ]};
	key <FK03> {[ F3 ]};
	key <FK04> {[ F4 ]};
	key <FK05> {[ F5 ]};
	key <FK06> {[ F6 ]};
	key <FK07> {[ F7 ]};
	key <FK08> {[ F8 ]};
	key <FK09> {[ F9 ]};
	key <FK10> {[ F10 ]};
	key <FK11> {[ F11 ]};
	key <FK12> {[ F12 ]};

	key <PRSC> { type="PC_ALT_LEVEL2", [ Print, Sys_Req ]};
	key <SCLK> {[ Scroll_Lock ]};
	key <PAUS> { type="PC_CONTROL_LEVEL2", [ Pause, Break ]};
	key <INS>  {[ Insert ]};
	key <DELE> {[ Delete ]};
	key <HOME> {[ Home ]};
	key <END>  {[ End ]};
	key <PGUP> {[ Prior ]};
	key <PGDN> {[ Next ]};
	key <UP>   {[ Up ]};
	key <LEFT> {[ Left ]};
	key <DOWN> {[ Down ]};
	key <RGHT> {[ Right ]};

	key <MUTE> {[ XF86AudioMute ]};
	key <VOL-> {[ XF86AudioLowerVolume ]};
	key <VOL+> {[ XF86AudioRaiseVolume ]};

	key <NMLK> {[ Num_Lock ]};
	key <KPDV> { type="KEYPAD", [ KP_Divide, KP_Divide ]};
	key <KPMU> { type="KEYPAD", [ KP_Multiply, KP_Multiply ]};
	key <KPSU> { type="KEYPAD", [ KP_Subtract, KP_Subtract ]};
	key <KPAD> { type="KEYPAD", [ KP_Add, KP_Add ]};
	key <KPEN> { type="KEYPAD", [ KP_Enter, KP_Enter ]};
	key <KP7>  { type="KEYPAD", [ KP_Home, KP_7 ]};
	key <KP8>  { type="KEYPAD", [ KP_Up, KP_8 ]};
	key <KP9>  { type="KEYPAD", [ KP_Prior, KP_9 ]};
	key <KP4>  { type="KEYPAD", [ KP_Left, KP_4 ]};
	key <KP5>  { type="KEYPAD", [ KP_Begin, KP_5 ]};
	key <KP6>  { type="KEYPAD", [ KP_Right, KP_6 ]};
	key <KP1>  { type="KEYPAD", [ KP_End, KP_1 ]};
	key <KP2>  { type="KEYPAD", [ KP_Down, KP_2 ]};
	key <KP3>  { type="KEYPAD", [ KP_Next, KP_3 ]};
	key <KP0>  { type="KEYPAD", [ KP_Insert, KP_0 ]};
	key <KPDL> { type="KEYPAD", [ KP_Delete, KP_Decimal ]};

	modifier_map Shift   { Shift_L, Shift_R };
	modifier_map Lock    { Caps_Lock };
	modifier_map Control { Control_L, Control_R };
	modifier_map Mod1    { Alt_L, Alt_R };
	modifier_map Mod2    { Num_Lock };
	modifier_map Mod4    { Super_L, Super_R };
	modifier_map Mod5    { <LVL3> };
};
};
`

// XKB_KEYSYM_TABLE is keysymdef.h and XF86keysym.h, flattened: one name and
// its hex value per line. Resolving a name is the one thing a keymap compiler
// cannot do without a table, and depending on the X11 headers being installed
// at runtime would defeat the point of the fallback above.
XKB_KEYSYM_TABLE :: `VoidSymbol ffffff
BackSpace ff08
Tab ff09
Linefeed ff0a
Clear ff0b
Return ff0d
Pause ff13
Scroll_Lock ff14
Sys_Req ff15
Escape ff1b
Delete ffff
Multi_key ff20
Codeinput ff37
SingleCandidate ff3c
MultipleCandidate ff3d
PreviousCandidate ff3e
Kanji ff21
Muhenkan ff22
Henkan_Mode ff23
Henkan ff23
Romaji ff24
Hiragana ff25
Katakana ff26
Hiragana_Katakana ff27
Zenkaku ff28
Hankaku ff29
Zenkaku_Hankaku ff2a
Touroku ff2b
Massyo ff2c
Kana_Lock ff2d
Kana_Shift ff2e
Eisu_Shift ff2f
Eisu_toggle ff30
Kanji_Bangou ff37
Zen_Koho ff3d
Mae_Koho ff3e
Home ff50
Left ff51
Up ff52
Right ff53
Down ff54
Prior ff55
Page_Up ff55
Next ff56
Page_Down ff56
End ff57
Begin ff58
Select ff60
Print ff61
Execute ff62
Insert ff63
Undo ff65
Redo ff66
Menu ff67
Find ff68
Cancel ff69
Help ff6a
Break ff6b
Mode_switch ff7e
script_switch ff7e
Num_Lock ff7f
KP_Space ff80
KP_Tab ff89
KP_Enter ff8d
KP_F1 ff91
KP_F2 ff92
KP_F3 ff93
KP_F4 ff94
KP_Home ff95
KP_Left ff96
KP_Up ff97
KP_Right ff98
KP_Down ff99
KP_Prior ff9a
KP_Page_Up ff9a
KP_Next ff9b
KP_Page_Down ff9b
KP_End ff9c
KP_Begin ff9d
KP_Insert ff9e
KP_Delete ff9f
KP_Equal ffbd
KP_Multiply ffaa
KP_Add ffab
KP_Separator ffac
KP_Subtract ffad
KP_Decimal ffae
KP_Divide ffaf
KP_0 ffb0
KP_1 ffb1
KP_2 ffb2
KP_3 ffb3
KP_4 ffb4
KP_5 ffb5
KP_6 ffb6
KP_7 ffb7
KP_8 ffb8
KP_9 ffb9
F1 ffbe
F2 ffbf
F3 ffc0
F4 ffc1
F5 ffc2
F6 ffc3
F7 ffc4
F8 ffc5
F9 ffc6
F10 ffc7
F11 ffc8
L1 ffc8
F12 ffc9
L2 ffc9
F13 ffca
L3 ffca
F14 ffcb
L4 ffcb
F15 ffcc
L5 ffcc
F16 ffcd
L6 ffcd
F17 ffce
L7 ffce
F18 ffcf
L8 ffcf
F19 ffd0
L9 ffd0
F20 ffd1
L10 ffd1
F21 ffd2
R1 ffd2
F22 ffd3
R2 ffd3
F23 ffd4
R3 ffd4
F24 ffd5
R4 ffd5
F25 ffd6
R5 ffd6
F26 ffd7
R6 ffd7
F27 ffd8
R7 ffd8
F28 ffd9
R8 ffd9
F29 ffda
R9 ffda
F30 ffdb
R10 ffdb
F31 ffdc
R11 ffdc
F32 ffdd
R12 ffdd
F33 ffde
R13 ffde
F34 ffdf
R14 ffdf
F35 ffe0
R15 ffe0
Shift_L ffe1
Shift_R ffe2
Control_L ffe3
Control_R ffe4
Caps_Lock ffe5
Shift_Lock ffe6
Meta_L ffe7
Meta_R ffe8
Alt_L ffe9
Alt_R ffea
Super_L ffeb
Super_R ffec
Hyper_L ffed
Hyper_R ffee
ISO_Lock fe01
ISO_Level2_Latch fe02
ISO_Level3_Shift fe03
ISO_Level3_Latch fe04
ISO_Level3_Lock fe05
ISO_Level5_Shift fe11
ISO_Level5_Latch fe12
ISO_Level5_Lock fe13
ISO_Group_Shift ff7e
ISO_Group_Latch fe06
ISO_Group_Lock fe07
ISO_Next_Group fe08
ISO_Next_Group_Lock fe09
ISO_Prev_Group fe0a
ISO_Prev_Group_Lock fe0b
ISO_First_Group fe0c
ISO_First_Group_Lock fe0d
ISO_Last_Group fe0e
ISO_Last_Group_Lock fe0f
ISO_Left_Tab fe20
ISO_Move_Line_Up fe21
ISO_Move_Line_Down fe22
ISO_Partial_Line_Up fe23
ISO_Partial_Line_Down fe24
ISO_Partial_Space_Left fe25
ISO_Partial_Space_Right fe26
ISO_Set_Margin_Left fe27
ISO_Set_Margin_Right fe28
ISO_Release_Margin_Left fe29
ISO_Release_Margin_Right fe2a
ISO_Release_Both_Margins fe2b
ISO_Fast_Cursor_Left fe2c
ISO_Fast_Cursor_Right fe2d
ISO_Fast_Cursor_Up fe2e
ISO_Fast_Cursor_Down fe2f
ISO_Continuous_Underline fe30
ISO_Discontinuous_Underline fe31
ISO_Emphasize fe32
ISO_Center_Object fe33
ISO_Enter fe34
dead_grave fe50
dead_acute fe51
dead_circumflex fe52
dead_tilde fe53
dead_perispomeni fe53
dead_macron fe54
dead_breve fe55
dead_abovedot fe56
dead_diaeresis fe57
dead_abovering fe58
dead_doubleacute fe59
dead_caron fe5a
dead_cedilla fe5b
dead_ogonek fe5c
dead_iota fe5d
dead_voiced_sound fe5e
dead_semivoiced_sound fe5f
dead_belowdot fe60
dead_hook fe61
dead_horn fe62
dead_stroke fe63
dead_abovecomma fe64
dead_psili fe64
dead_abovereversedcomma fe65
dead_dasia fe65
dead_doublegrave fe66
dead_belowring fe67
dead_belowmacron fe68
dead_belowcircumflex fe69
dead_belowtilde fe6a
dead_belowbreve fe6b
dead_belowdiaeresis fe6c
dead_invertedbreve fe6d
dead_belowcomma fe6e
dead_currency fe6f
dead_lowline fe90
dead_aboveverticalline fe91
dead_belowverticalline fe92
dead_longsolidusoverlay fe93
dead_a fe80
dead_A fe81
dead_e fe82
dead_E fe83
dead_i fe84
dead_I fe85
dead_o fe86
dead_O fe87
dead_u fe88
dead_U fe89
dead_small_schwa fe8a
dead_schwa fe8a
dead_capital_schwa fe8b
dead_SCHWA fe8b
dead_greek fe8c
dead_hamza fe8d
First_Virtual_Screen fed0
Prev_Virtual_Screen fed1
Next_Virtual_Screen fed2
Last_Virtual_Screen fed4
Terminate_Server fed5
AccessX_Enable fe70
AccessX_Feedback_Enable fe71
RepeatKeys_Enable fe72
SlowKeys_Enable fe73
BounceKeys_Enable fe74
StickyKeys_Enable fe75
MouseKeys_Enable fe76
MouseKeys_Accel_Enable fe77
Overlay1_Enable fe78
Overlay2_Enable fe79
AudibleBell_Enable fe7a
Pointer_Left fee0
Pointer_Right fee1
Pointer_Up fee2
Pointer_Down fee3
Pointer_UpLeft fee4
Pointer_UpRight fee5
Pointer_DownLeft fee6
Pointer_DownRight fee7
Pointer_Button_Dflt fee8
Pointer_Button1 fee9
Pointer_Button2 feea
Pointer_Button3 feeb
Pointer_Button4 feec
Pointer_Button5 feed
Pointer_DblClick_Dflt feee
Pointer_DblClick1 feef
Pointer_DblClick2 fef0
Pointer_DblClick3 fef1
Pointer_DblClick4 fef2
Pointer_DblClick5 fef3
Pointer_Drag_Dflt fef4
Pointer_Drag1 fef5
Pointer_Drag2 fef6
Pointer_Drag3 fef7
Pointer_Drag4 fef8
Pointer_Drag5 fefd
Pointer_EnableKeys fef9
Pointer_Accelerate fefa
Pointer_DfltBtnNext fefb
Pointer_DfltBtnPrev fefc
ch fea0
Ch fea1
CH fea2
c_h fea3
C_h fea4
C_H fea5
3270_Duplicate fd01
3270_FieldMark fd02
3270_Right2 fd03
3270_Left2 fd04
3270_BackTab fd05
3270_EraseEOF fd06
3270_EraseInput fd07
3270_Reset fd08
3270_Quit fd09
3270_PA1 fd0a
3270_PA2 fd0b
3270_PA3 fd0c
3270_Test fd0d
3270_Attn fd0e
3270_CursorBlink fd0f
3270_AltCursor fd10
3270_KeyClick fd11
3270_Jump fd12
3270_Ident fd13
3270_Rule fd14
3270_Copy fd15
3270_Play fd16
3270_Setup fd17
3270_Record fd18
3270_ChangeScreen fd19
3270_DeleteWord fd1a
3270_ExSelect fd1b
3270_CursorSelect fd1c
3270_PrintScreen fd1d
3270_Enter fd1e
space 20
exclam 21
quotedbl 22
numbersign 23
dollar 24
percent 25
ampersand 26
apostrophe 27
quoteright 27
parenleft 28
parenright 29
asterisk 2a
plus 2b
comma 2c
minus 2d
period 2e
slash 2f
0 30
1 31
2 32
3 33
4 34
5 35
6 36
7 37
8 38
9 39
colon 3a
semicolon 3b
less 3c
equal 3d
greater 3e
question 3f
at 40
A 41
B 42
C 43
D 44
E 45
F 46
G 47
H 48
I 49
J 4a
K 4b
L 4c
M 4d
N 4e
O 4f
P 50
Q 51
R 52
S 53
T 54
U 55
V 56
W 57
X 58
Y 59
Z 5a
bracketleft 5b
backslash 5c
bracketright 5d
asciicircum 5e
underscore 5f
grave 60
quoteleft 60
a 61
b 62
c 63
d 64
e 65
f 66
g 67
h 68
i 69
j 6a
k 6b
l 6c
m 6d
n 6e
o 6f
p 70
q 71
r 72
s 73
t 74
u 75
v 76
w 77
x 78
y 79
z 7a
braceleft 7b
bar 7c
braceright 7d
asciitilde 7e
nobreakspace a0
exclamdown a1
cent a2
sterling a3
currency a4
yen a5
brokenbar a6
section a7
diaeresis a8
copyright a9
ordfeminine aa
guillemotleft ab
guillemetleft ab
notsign ac
hyphen ad
registered ae
macron af
degree b0
plusminus b1
twosuperior b2
threesuperior b3
acute b4
mu b5
paragraph b6
periodcentered b7
cedilla b8
onesuperior b9
masculine ba
ordmasculine ba
guillemotright bb
guillemetright bb
onequarter bc
onehalf bd
threequarters be
questiondown bf
Agrave c0
Aacute c1
Acircumflex c2
Atilde c3
Adiaeresis c4
Aring c5
AE c6
Ccedilla c7
Egrave c8
Eacute c9
Ecircumflex ca
Ediaeresis cb
Igrave cc
Iacute cd
Icircumflex ce
Idiaeresis cf
ETH d0
Eth d0
Ntilde d1
Ograve d2
Oacute d3
Ocircumflex d4
Otilde d5
Odiaeresis d6
multiply d7
Oslash d8
Ooblique d8
Ugrave d9
Uacute da
Ucircumflex db
Udiaeresis dc
Yacute dd
THORN de
Thorn de
ssharp df
agrave e0
aacute e1
acircumflex e2
atilde e3
adiaeresis e4
aring e5
ae e6
ccedilla e7
egrave e8
eacute e9
ecircumflex ea
ediaeresis eb
igrave ec
iacute ed
icircumflex ee
idiaeresis ef
eth f0
ntilde f1
ograve f2
oacute f3
ocircumflex f4
otilde f5
odiaeresis f6
division f7
oslash f8
ooblique f8
ugrave f9
uacute fa
ucircumflex fb
udiaeresis fc
yacute fd
thorn fe
ydiaeresis ff
Aogonek 1a1
breve 1a2
Lstroke 1a3
Lcaron 1a5
Sacute 1a6
Scaron 1a9
Scedilla 1aa
Tcaron 1ab
Zacute 1ac
Zcaron 1ae
Zabovedot 1af
aogonek 1b1
ogonek 1b2
lstroke 1b3
lcaron 1b5
sacute 1b6
caron 1b7
scaron 1b9
scedilla 1ba
tcaron 1bb
zacute 1bc
doubleacute 1bd
zcaron 1be
zabovedot 1bf
Racute 1c0
Abreve 1c3
Lacute 1c5
Cacute 1c6
Ccaron 1c8
Eogonek 1ca
Ecaron 1cc
Dcaron 1cf
Dstroke 1d0
Nacute 1d1
Ncaron 1d2
Odoubleacute 1d5
Rcaron 1d8
Uring 1d9
Udoubleacute 1db
Tcedilla 1de
racute 1e0
abreve 1e3
lacute 1e5
cacute 1e6
ccaron 1e8
eogonek 1ea
ecaron 1ec
dcaron 1ef
dstroke 1f0
nacute 1f1
ncaron 1f2
odoubleacute 1f5
rcaron 1f8
uring 1f9
udoubleacute 1fb
tcedilla 1fe
abovedot 1ff
Hstroke 2a1
Hcircumflex 2a6
Iabovedot 2a9
Gbreve 2ab
Jcircumflex 2ac
hstroke 2b1
hcircumflex 2b6
idotless 2b9
gbreve 2bb
jcircumflex 2bc
Cabovedot 2c5
Ccircumflex 2c6
Gabovedot 2d5
Gcircumflex 2d8
Ubreve 2dd
Scircumflex 2de
cabovedot 2e5
ccircumflex 2e6
gabovedot 2f5
gcircumflex 2f8
ubreve 2fd
scircumflex 2fe
kra 3a2
kappa 3a2
Rcedilla 3a3
Itilde 3a5
Lcedilla 3a6
Emacron 3aa
Gcedilla 3ab
Tslash 3ac
rcedilla 3b3
itilde 3b5
lcedilla 3b6
emacron 3ba
gcedilla 3bb
tslash 3bc
ENG 3bd
eng 3bf
Amacron 3c0
Iogonek 3c7
Eabovedot 3cc
Imacron 3cf
Ncedilla 3d1
Omacron 3d2
Kcedilla 3d3
Uogonek 3d9
Utilde 3dd
Umacron 3de
amacron 3e0
iogonek 3e7
eabovedot 3ec
imacron 3ef
ncedilla 3f1
omacron 3f2
kcedilla 3f3
uogonek 3f9
utilde 3fd
umacron 3fe
Wcircumflex 1000174
wcircumflex 1000175
Ycircumflex 1000176
ycircumflex 1000177
Babovedot 1001e02
babovedot 1001e03
Dabovedot 1001e0a
dabovedot 1001e0b
Fabovedot 1001e1e
fabovedot 1001e1f
Mabovedot 1001e40
mabovedot 1001e41
Pabovedot 1001e56
pabovedot 1001e57
Sabovedot 1001e60
sabovedot 1001e61
Tabovedot 1001e6a
tabovedot 1001e6b
Wgrave 1001e80
wgrave 1001e81
Wacute 1001e82
wacute 1001e83
Wdiaeresis 1001e84
wdiaeresis 1001e85
Ygrave 1001ef2
ygrave 1001ef3
OE 13bc
oe 13bd
Ydiaeresis 13be
overline 47e
kana_fullstop 4a1
kana_openingbracket 4a2
kana_closingbracket 4a3
kana_comma 4a4
kana_conjunctive 4a5
kana_middledot 4a5
kana_WO 4a6
kana_a 4a7
kana_i 4a8
kana_u 4a9
kana_e 4aa
kana_o 4ab
kana_ya 4ac
kana_yu 4ad
kana_yo 4ae
kana_tsu 4af
kana_tu 4af
prolongedsound 4b0
kana_A 4b1
kana_I 4b2
kana_U 4b3
kana_E 4b4
kana_O 4b5
kana_KA 4b6
kana_KI 4b7
kana_KU 4b8
kana_KE 4b9
kana_KO 4ba
kana_SA 4bb
kana_SHI 4bc
kana_SU 4bd
kana_SE 4be
kana_SO 4bf
kana_TA 4c0
kana_CHI 4c1
kana_TI 4c1
kana_TSU 4c2
kana_TU 4c2
kana_TE 4c3
kana_TO 4c4
kana_NA 4c5
kana_NI 4c6
kana_NU 4c7
kana_NE 4c8
kana_NO 4c9
kana_HA 4ca
kana_HI 4cb
kana_FU 4cc
kana_HU 4cc
kana_HE 4cd
kana_HO 4ce
kana_MA 4cf
kana_MI 4d0
kana_MU 4d1
kana_ME 4d2
kana_MO 4d3
kana_YA 4d4
kana_YU 4d5
kana_YO 4d6
kana_RA 4d7
kana_RI 4d8
kana_RU 4d9
kana_RE 4da
kana_RO 4db
kana_WA 4dc
kana_N 4dd
voicedsound 4de
semivoicedsound 4df
kana_switch ff7e
Farsi_0 10006f0
Farsi_1 10006f1
Farsi_2 10006f2
Farsi_3 10006f3
Farsi_4 10006f4
Farsi_5 10006f5
Farsi_6 10006f6
Farsi_7 10006f7
Farsi_8 10006f8
Farsi_9 10006f9
Arabic_percent 100066a
Arabic_superscript_alef 1000670
Arabic_tteh 1000679
Arabic_peh 100067e
Arabic_tcheh 1000686
Arabic_ddal 1000688
Arabic_rreh 1000691
Arabic_comma 5ac
Arabic_fullstop 10006d4
Arabic_0 1000660
Arabic_1 1000661
Arabic_2 1000662
Arabic_3 1000663
Arabic_4 1000664
Arabic_5 1000665
Arabic_6 1000666
Arabic_7 1000667
Arabic_8 1000668
Arabic_9 1000669
Arabic_semicolon 5bb
Arabic_question_mark 5bf
Arabic_hamza 5c1
Arabic_maddaonalef 5c2
Arabic_hamzaonalef 5c3
Arabic_hamzaonwaw 5c4
Arabic_hamzaunderalef 5c5
Arabic_hamzaonyeh 5c6
Arabic_alef 5c7
Arabic_beh 5c8
Arabic_tehmarbuta 5c9
Arabic_teh 5ca
Arabic_theh 5cb
Arabic_jeem 5cc
Arabic_hah 5cd
Arabic_khah 5ce
Arabic_dal 5cf
Arabic_thal 5d0
Arabic_ra 5d1
Arabic_zain 5d2
Arabic_seen 5d3
Arabic_sheen 5d4
Arabic_sad 5d5
Arabic_dad 5d6
Arabic_tah 5d7
Arabic_zah 5d8
Arabic_ain 5d9
Arabic_ghain 5da
Arabic_tatweel 5e0
Arabic_feh 5e1
Arabic_qaf 5e2
Arabic_kaf 5e3
Arabic_lam 5e4
Arabic_meem 5e5
Arabic_noon 5e6
Arabic_ha 5e7
Arabic_heh 5e7
Arabic_waw 5e8
Arabic_alefmaksura 5e9
Arabic_yeh 5ea
Arabic_fathatan 5eb
Arabic_dammatan 5ec
Arabic_kasratan 5ed
Arabic_fatha 5ee
Arabic_damma 5ef
Arabic_kasra 5f0
Arabic_shadda 5f1
Arabic_sukun 5f2
Arabic_madda_above 1000653
Arabic_hamza_above 1000654
Arabic_hamza_below 1000655
Arabic_jeh 1000698
Arabic_veh 10006a4
Arabic_keheh 10006a9
Arabic_gaf 10006af
Arabic_noon_ghunna 10006ba
Arabic_heh_doachashmee 10006be
Farsi_yeh 10006cc
Arabic_farsi_yeh 10006cc
Arabic_yeh_baree 10006d2
Arabic_heh_goal 10006c1
Arabic_switch ff7e
Cyrillic_GHE_bar 1000492
Cyrillic_ghe_bar 1000493
Cyrillic_ZHE_descender 1000496
Cyrillic_zhe_descender 1000497
Cyrillic_KA_descender 100049a
Cyrillic_ka_descender 100049b
Cyrillic_KA_vertstroke 100049c
Cyrillic_ka_vertstroke 100049d
Cyrillic_EN_descender 10004a2
Cyrillic_en_descender 10004a3
Cyrillic_U_straight 10004ae
Cyrillic_u_straight 10004af
Cyrillic_U_straight_bar 10004b0
Cyrillic_u_straight_bar 10004b1
Cyrillic_HA_descender 10004b2
Cyrillic_ha_descender 10004b3
Cyrillic_CHE_descender 10004b6
Cyrillic_che_descender 10004b7
Cyrillic_CHE_vertstroke 10004b8
Cyrillic_che_vertstroke 10004b9
Cyrillic_SHHA 10004ba
Cyrillic_shha 10004bb
Cyrillic_SCHWA 10004d8
Cyrillic_schwa 10004d9
Cyrillic_I_macron 10004e2
Cyrillic_i_macron 10004e3
Cyrillic_O_bar 10004e8
Cyrillic_o_bar 10004e9
Cyrillic_U_macron 10004ee
Cyrillic_u_macron 10004ef
Serbian_dje 6a1
Macedonia_gje 6a2
Cyrillic_io 6a3
Ukrainian_ie 6a4
Ukranian_je 6a4
Macedonia_dse 6a5
Ukrainian_i 6a6
Ukranian_i 6a6
Ukrainian_yi 6a7
Ukranian_yi 6a7
Cyrillic_je 6a8
Serbian_je 6a8
Cyrillic_lje 6a9
Serbian_lje 6a9
Cyrillic_nje 6aa
Serbian_nje 6aa
Serbian_tshe 6ab
Macedonia_kje 6ac
Ukrainian_ghe_with_upturn 6ad
Byelorussian_shortu 6ae
Cyrillic_dzhe 6af
Serbian_dze 6af
numerosign 6b0
Serbian_DJE 6b1
Macedonia_GJE 6b2
Cyrillic_IO 6b3
Ukrainian_IE 6b4
Ukranian_JE 6b4
Macedonia_DSE 6b5
Ukrainian_I 6b6
Ukranian_I 6b6
Ukrainian_YI 6b7
Ukranian_YI 6b7
Cyrillic_JE 6b8
Serbian_JE 6b8
Cyrillic_LJE 6b9
Serbian_LJE 6b9
Cyrillic_NJE 6ba
Serbian_NJE 6ba
Serbian_TSHE 6bb
Macedonia_KJE 6bc
Ukrainian_GHE_WITH_UPTURN 6bd
Byelorussian_SHORTU 6be
Cyrillic_DZHE 6bf
Serbian_DZE 6bf
Cyrillic_yu 6c0
Cyrillic_a 6c1
Cyrillic_be 6c2
Cyrillic_tse 6c3
Cyrillic_de 6c4
Cyrillic_ie 6c5
Cyrillic_ef 6c6
Cyrillic_ghe 6c7
Cyrillic_ha 6c8
Cyrillic_i 6c9
Cyrillic_shorti 6ca
Cyrillic_ka 6cb
Cyrillic_el 6cc
Cyrillic_em 6cd
Cyrillic_en 6ce
Cyrillic_o 6cf
Cyrillic_pe 6d0
Cyrillic_ya 6d1
Cyrillic_er 6d2
Cyrillic_es 6d3
Cyrillic_te 6d4
Cyrillic_u 6d5
Cyrillic_zhe 6d6
Cyrillic_ve 6d7
Cyrillic_softsign 6d8
Cyrillic_yeru 6d9
Cyrillic_ze 6da
Cyrillic_sha 6db
Cyrillic_e 6dc
Cyrillic_shcha 6dd
Cyrillic_che 6de
Cyrillic_hardsign 6df
Cyrillic_YU 6e0
Cyrillic_A 6e1
Cyrillic_BE 6e2
Cyrillic_TSE 6e3
Cyrillic_DE 6e4
Cyrillic_IE 6e5
Cyrillic_EF 6e6
Cyrillic_GHE 6e7
Cyrillic_HA 6e8
Cyrillic_I 6e9
Cyrillic_SHORTI 6ea
Cyrillic_KA 6eb
Cyrillic_EL 6ec
Cyrillic_EM 6ed
Cyrillic_EN 6ee
Cyrillic_O 6ef
Cyrillic_PE 6f0
Cyrillic_YA 6f1
Cyrillic_ER 6f2
Cyrillic_ES 6f3
Cyrillic_TE 6f4
Cyrillic_U 6f5
Cyrillic_ZHE 6f6
Cyrillic_VE 6f7
Cyrillic_SOFTSIGN 6f8
Cyrillic_YERU 6f9
Cyrillic_ZE 6fa
Cyrillic_SHA 6fb
Cyrillic_E 6fc
Cyrillic_SHCHA 6fd
Cyrillic_CHE 6fe
Cyrillic_HARDSIGN 6ff
Greek_ALPHAaccent 7a1
Greek_EPSILONaccent 7a2
Greek_ETAaccent 7a3
Greek_IOTAaccent 7a4
Greek_IOTAdieresis 7a5
Greek_IOTAdiaeresis 7a5
Greek_OMICRONaccent 7a7
Greek_UPSILONaccent 7a8
Greek_UPSILONdieresis 7a9
Greek_OMEGAaccent 7ab
Greek_accentdieresis 7ae
Greek_horizbar 7af
Greek_alphaaccent 7b1
Greek_epsilonaccent 7b2
Greek_etaaccent 7b3
Greek_iotaaccent 7b4
Greek_iotadieresis 7b5
Greek_iotaaccentdieresis 7b6
Greek_omicronaccent 7b7
Greek_upsilonaccent 7b8
Greek_upsilondieresis 7b9
Greek_upsilonaccentdieresis 7ba
Greek_omegaaccent 7bb
Greek_ALPHA 7c1
Greek_BETA 7c2
Greek_GAMMA 7c3
Greek_DELTA 7c4
Greek_EPSILON 7c5
Greek_ZETA 7c6
Greek_ETA 7c7
Greek_THETA 7c8
Greek_IOTA 7c9
Greek_KAPPA 7ca
Greek_LAMDA 7cb
Greek_LAMBDA 7cb
Greek_MU 7cc
Greek_NU 7cd
Greek_XI 7ce
Greek_OMICRON 7cf
Greek_PI 7d0
Greek_RHO 7d1
Greek_SIGMA 7d2
Greek_TAU 7d4
Greek_UPSILON 7d5
Greek_PHI 7d6
Greek_CHI 7d7
Greek_PSI 7d8
Greek_OMEGA 7d9
Greek_alpha 7e1
Greek_beta 7e2
Greek_gamma 7e3
Greek_delta 7e4
Greek_epsilon 7e5
Greek_zeta 7e6
Greek_eta 7e7
Greek_theta 7e8
Greek_iota 7e9
Greek_kappa 7ea
Greek_lamda 7eb
Greek_lambda 7eb
Greek_mu 7ec
Greek_nu 7ed
Greek_xi 7ee
Greek_omicron 7ef
Greek_pi 7f0
Greek_rho 7f1
Greek_sigma 7f2
Greek_finalsmallsigma 7f3
Greek_tau 7f4
Greek_upsilon 7f5
Greek_phi 7f6
Greek_chi 7f7
Greek_psi 7f8
Greek_omega 7f9
Greek_switch ff7e
leftradical 8a1
topleftradical 8a2
horizconnector 8a3
topintegral 8a4
botintegral 8a5
vertconnector 8a6
topleftsqbracket 8a7
botleftsqbracket 8a8
toprightsqbracket 8a9
botrightsqbracket 8aa
topleftparens 8ab
botleftparens 8ac
toprightparens 8ad
botrightparens 8ae
leftmiddlecurlybrace 8af
rightmiddlecurlybrace 8b0
topleftsummation 8b1
botleftsummation 8b2
topvertsummationconnector 8b3
botvertsummationconnector 8b4
toprightsummation 8b5
botrightsummation 8b6
rightmiddlesummation 8b7
lessthanequal 8bc
notequal 8bd
greaterthanequal 8be
integral 8bf
therefore 8c0
variation 8c1
infinity 8c2
nabla 8c5
approximate 8c8
similarequal 8c9
ifonlyif 8cd
implies 8ce
identical 8cf
radical 8d6
includedin 8da
includes 8db
intersection 8dc
union 8dd
logicaland 8de
logicalor 8df
partialderivative 8ef
function 8f6
leftarrow 8fb
uparrow 8fc
rightarrow 8fd
downarrow 8fe
blank 9df
soliddiamond 9e0
checkerboard 9e1
ht 9e2
ff 9e3
cr 9e4
lf 9e5
nl 9e8
vt 9e9
lowrightcorner 9ea
uprightcorner 9eb
upleftcorner 9ec
lowleftcorner 9ed
crossinglines 9ee
horizlinescan1 9ef
horizlinescan3 9f0
horizlinescan5 9f1
horizlinescan7 9f2
horizlinescan9 9f3
leftt 9f4
rightt 9f5
bott 9f6
topt 9f7
vertbar 9f8
emspace aa1
enspace aa2
em3space aa3
em4space aa4
digitspace aa5
punctspace aa6
thinspace aa7
hairspace aa8
emdash aa9
endash aaa
signifblank aac
ellipsis aae
doubbaselinedot aaf
onethird ab0
twothirds ab1
onefifth ab2
twofifths ab3
threefifths ab4
fourfifths ab5
onesixth ab6
fivesixths ab7
careof ab8
figdash abb
leftanglebracket abc
decimalpoint abd
rightanglebracket abe
marker abf
oneeighth ac3
threeeighths ac4
fiveeighths ac5
seveneighths ac6
trademark ac9
signaturemark aca
trademarkincircle acb
leftopentriangle acc
rightopentriangle acd
emopencircle ace
emopenrectangle acf
leftsinglequotemark ad0
rightsinglequotemark ad1
leftdoublequotemark ad2
rightdoublequotemark ad3
prescription ad4
permille ad5
minutes ad6
seconds ad7
latincross ad9
hexagram ada
filledrectbullet adb
filledlefttribullet adc
filledrighttribullet add
emfilledcircle ade
emfilledrect adf
enopencircbullet ae0
enopensquarebullet ae1
openrectbullet ae2
opentribulletup ae3
opentribulletdown ae4
openstar ae5
enfilledcircbullet ae6
enfilledsqbullet ae7
filledtribulletup ae8
filledtribulletdown ae9
leftpointer aea
rightpointer aeb
club aec
diamond aed
heart aee
maltesecross af0
dagger af1
doubledagger af2
checkmark af3
ballotcross af4
musicalsharp af5
musicalflat af6
malesymbol af7
femalesymbol af8
telephone af9
telephonerecorder afa
phonographcopyright afb
caret afc
singlelowquotemark afd
doublelowquotemark afe
cursor aff
leftcaret ba3
rightcaret ba6
downcaret ba8
upcaret ba9
overbar bc0
downtack bc2
upshoe bc3
downstile bc4
underbar bc6
jot bca
quad bcc
uptack bce
circle bcf
upstile bd3
downshoe bd6
rightshoe bd8
leftshoe bda
lefttack bdc
righttack bfc
hebrew_doublelowline cdf
hebrew_aleph ce0
hebrew_bet ce1
hebrew_beth ce1
hebrew_gimel ce2
hebrew_gimmel ce2
hebrew_dalet ce3
hebrew_daleth ce3
hebrew_he ce4
hebrew_waw ce5
hebrew_zain ce6
hebrew_zayin ce6
hebrew_chet ce7
hebrew_het ce7
hebrew_tet ce8
hebrew_teth ce8
hebrew_yod ce9
hebrew_finalkaph cea
hebrew_kaph ceb
hebrew_lamed cec
hebrew_finalmem ced
hebrew_mem cee
hebrew_finalnun cef
hebrew_nun cf0
hebrew_samech cf1
hebrew_samekh cf1
hebrew_ayin cf2
hebrew_finalpe cf3
hebrew_pe cf4
hebrew_finalzade cf5
hebrew_finalzadi cf5
hebrew_zade cf6
hebrew_zadi cf6
hebrew_qoph cf7
hebrew_kuf cf7
hebrew_resh cf8
hebrew_shin cf9
hebrew_taw cfa
hebrew_taf cfa
Hebrew_switch ff7e
Thai_kokai da1
Thai_khokhai da2
Thai_khokhuat da3
Thai_khokhwai da4
Thai_khokhon da5
Thai_khorakhang da6
Thai_ngongu da7
Thai_chochan da8
Thai_choching da9
Thai_chochang daa
Thai_soso dab
Thai_chochoe dac
Thai_yoying dad
Thai_dochada dae
Thai_topatak daf
Thai_thothan db0
Thai_thonangmontho db1
Thai_thophuthao db2
Thai_nonen db3
Thai_dodek db4
Thai_totao db5
Thai_thothung db6
Thai_thothahan db7
Thai_thothong db8
Thai_nonu db9
Thai_bobaimai dba
Thai_popla dbb
Thai_phophung dbc
Thai_fofa dbd
Thai_phophan dbe
Thai_fofan dbf
Thai_phosamphao dc0
Thai_moma dc1
Thai_yoyak dc2
Thai_rorua dc3
Thai_ru dc4
Thai_loling dc5
Thai_lu dc6
Thai_wowaen dc7
Thai_sosala dc8
Thai_sorusi dc9
Thai_sosua dca
Thai_hohip dcb
Thai_lochula dcc
Thai_oang dcd
Thai_honokhuk dce
Thai_paiyannoi dcf
Thai_saraa dd0
Thai_maihanakat dd1
Thai_saraaa dd2
Thai_saraam dd3
Thai_sarai dd4
Thai_saraii dd5
Thai_saraue dd6
Thai_sarauee dd7
Thai_sarau dd8
Thai_sarauu dd9
Thai_phinthu dda
Thai_maihanakat_maitho dde
Thai_baht ddf
Thai_sarae de0
Thai_saraae de1
Thai_sarao de2
Thai_saraaimaimuan de3
Thai_saraaimaimalai de4
Thai_lakkhangyao de5
Thai_maiyamok de6
Thai_maitaikhu de7
Thai_maiek de8
Thai_maitho de9
Thai_maitri dea
Thai_maichattawa deb
Thai_thanthakhat dec
Thai_nikhahit ded
Thai_leksun df0
Thai_leknung df1
Thai_leksong df2
Thai_leksam df3
Thai_leksi df4
Thai_lekha df5
Thai_lekhok df6
Thai_lekchet df7
Thai_lekpaet df8
Thai_lekkao df9
Hangul ff31
Hangul_Start ff32
Hangul_End ff33
Hangul_Hanja ff34
Hangul_Jamo ff35
Hangul_Romaja ff36
Hangul_Codeinput ff37
Hangul_Jeonja ff38
Hangul_Banja ff39
Hangul_PreHanja ff3a
Hangul_PostHanja ff3b
Hangul_SingleCandidate ff3c
Hangul_MultipleCandidate ff3d
Hangul_PreviousCandidate ff3e
Hangul_Special ff3f
Hangul_switch ff7e
Hangul_Kiyeog ea1
Hangul_SsangKiyeog ea2
Hangul_KiyeogSios ea3
Hangul_Nieun ea4
Hangul_NieunJieuj ea5
Hangul_NieunHieuh ea6
Hangul_Dikeud ea7
Hangul_SsangDikeud ea8
Hangul_Rieul ea9
Hangul_RieulKiyeog eaa
Hangul_RieulMieum eab
Hangul_RieulPieub eac
Hangul_RieulSios ead
Hangul_RieulTieut eae
Hangul_RieulPhieuf eaf
Hangul_RieulHieuh eb0
Hangul_Mieum eb1
Hangul_Pieub eb2
Hangul_SsangPieub eb3
Hangul_PieubSios eb4
Hangul_Sios eb5
Hangul_SsangSios eb6
Hangul_Ieung eb7
Hangul_Jieuj eb8
Hangul_SsangJieuj eb9
Hangul_Cieuc eba
Hangul_Khieuq ebb
Hangul_Tieut ebc
Hangul_Phieuf ebd
Hangul_Hieuh ebe
Hangul_A ebf
Hangul_AE ec0
Hangul_YA ec1
Hangul_YAE ec2
Hangul_EO ec3
Hangul_E ec4
Hangul_YEO ec5
Hangul_YE ec6
Hangul_O ec7
Hangul_WA ec8
Hangul_WAE ec9
Hangul_OE eca
Hangul_YO ecb
Hangul_U ecc
Hangul_WEO ecd
Hangul_WE ece
Hangul_WI ecf
Hangul_YU ed0
Hangul_EU ed1
Hangul_YI ed2
Hangul_I ed3
Hangul_J_Kiyeog ed4
Hangul_J_SsangKiyeog ed5
Hangul_J_KiyeogSios ed6
Hangul_J_Nieun ed7
Hangul_J_NieunJieuj ed8
Hangul_J_NieunHieuh ed9
Hangul_J_Dikeud eda
Hangul_J_Rieul edb
Hangul_J_RieulKiyeog edc
Hangul_J_RieulMieum edd
Hangul_J_RieulPieub ede
Hangul_J_RieulSios edf
Hangul_J_RieulTieut ee0
Hangul_J_RieulPhieuf ee1
Hangul_J_RieulHieuh ee2
Hangul_J_Mieum ee3
Hangul_J_Pieub ee4
Hangul_J_PieubSios ee5
Hangul_J_Sios ee6
Hangul_J_SsangSios ee7
Hangul_J_Ieung ee8
Hangul_J_Jieuj ee9
Hangul_J_Cieuc eea
Hangul_J_Khieuq eeb
Hangul_J_Tieut eec
Hangul_J_Phieuf eed
Hangul_J_Hieuh eee
Hangul_RieulYeorinHieuh eef
Hangul_SunkyeongeumMieum ef0
Hangul_SunkyeongeumPieub ef1
Hangul_PanSios ef2
Hangul_KkogjiDalrinIeung ef3
Hangul_SunkyeongeumPhieuf ef4
Hangul_YeorinHieuh ef5
Hangul_AraeA ef6
Hangul_AraeAE ef7
Hangul_J_PanSios ef8
Hangul_J_KkogjiDalrinIeung ef9
Hangul_J_YeorinHieuh efa
Korean_Won eff
Armenian_ligature_ew 1000587
Armenian_full_stop 1000589
Armenian_verjaket 1000589
Armenian_separation_mark 100055d
Armenian_but 100055d
Armenian_hyphen 100058a
Armenian_yentamna 100058a
Armenian_exclam 100055c
Armenian_amanak 100055c
Armenian_accent 100055b
Armenian_shesht 100055b
Armenian_question 100055e
Armenian_paruyk 100055e
Armenian_AYB 1000531
Armenian_ayb 1000561
Armenian_BEN 1000532
Armenian_ben 1000562
Armenian_GIM 1000533
Armenian_gim 1000563
Armenian_DA 1000534
Armenian_da 1000564
Armenian_YECH 1000535
Armenian_yech 1000565
Armenian_ZA 1000536
Armenian_za 1000566
Armenian_E 1000537
Armenian_e 1000567
Armenian_AT 1000538
Armenian_at 1000568
Armenian_TO 1000539
Armenian_to 1000569
Armenian_ZHE 100053a
Armenian_zhe 100056a
Armenian_INI 100053b
Armenian_ini 100056b
Armenian_LYUN 100053c
Armenian_lyun 100056c
Armenian_KHE 100053d
Armenian_khe 100056d
Armenian_TSA 100053e
Armenian_tsa 100056e
Armenian_KEN 100053f
Armenian_ken 100056f
Armenian_HO 1000540
Armenian_ho 1000570
Armenian_DZA 1000541
Armenian_dza 1000571
Armenian_GHAT 1000542
Armenian_ghat 1000572
Armenian_TCHE 1000543
Armenian_tche 1000573
Armenian_MEN 1000544
Armenian_men 1000574
Armenian_HI 1000545
Armenian_hi 1000575
Armenian_NU 1000546
Armenian_nu 1000576
Armenian_SHA 1000547
Armenian_sha 1000577
Armenian_VO 1000548
Armenian_vo 1000578
Armenian_CHA 1000549
Armenian_cha 1000579
Armenian_PE 100054a
Armenian_pe 100057a
Armenian_JE 100054b
Armenian_je 100057b
Armenian_RA 100054c
Armenian_ra 100057c
Armenian_SE 100054d
Armenian_se 100057d
Armenian_VEV 100054e
Armenian_vev 100057e
Armenian_TYUN 100054f
Armenian_tyun 100057f
Armenian_RE 1000550
Armenian_re 1000580
Armenian_TSO 1000551
Armenian_tso 1000581
Armenian_VYUN 1000552
Armenian_vyun 1000582
Armenian_PYUR 1000553
Armenian_pyur 1000583
Armenian_KE 1000554
Armenian_ke 1000584
Armenian_O 1000555
Armenian_o 1000585
Armenian_FE 1000556
Armenian_fe 1000586
Armenian_apostrophe 100055a
Georgian_an 10010d0
Georgian_ban 10010d1
Georgian_gan 10010d2
Georgian_don 10010d3
Georgian_en 10010d4
Georgian_vin 10010d5
Georgian_zen 10010d6
Georgian_tan 10010d7
Georgian_in 10010d8
Georgian_kan 10010d9
Georgian_las 10010da
Georgian_man 10010db
Georgian_nar 10010dc
Georgian_on 10010dd
Georgian_par 10010de
Georgian_zhar 10010df
Georgian_rae 10010e0
Georgian_san 10010e1
Georgian_tar 10010e2
Georgian_un 10010e3
Georgian_phar 10010e4
Georgian_khar 10010e5
Georgian_ghan 10010e6
Georgian_qar 10010e7
Georgian_shin 10010e8
Georgian_chin 10010e9
Georgian_can 10010ea
Georgian_jil 10010eb
Georgian_cil 10010ec
Georgian_char 10010ed
Georgian_xan 10010ee
Georgian_jhan 10010ef
Georgian_hae 10010f0
Georgian_he 10010f1
Georgian_hie 10010f2
Georgian_we 10010f3
Georgian_har 10010f4
Georgian_hoe 10010f5
Georgian_fi 10010f6
Xabovedot 1001e8a
Ibreve 100012c
Zstroke 10001b5
Gcaron 10001e6
Ocaron 10001d1
Obarred 100019f
xabovedot 1001e8b
ibreve 100012d
zstroke 10001b6
gcaron 10001e7
ocaron 10001d2
obarred 1000275
SCHWA 100018f
schwa 1000259
EZH 10001b7
ezh 1000292
Lbelowdot 1001e36
lbelowdot 1001e37
Abelowdot 1001ea0
abelowdot 1001ea1
Ahook 1001ea2
ahook 1001ea3
Acircumflexacute 1001ea4
acircumflexacute 1001ea5
Acircumflexgrave 1001ea6
acircumflexgrave 1001ea7
Acircumflexhook 1001ea8
acircumflexhook 1001ea9
Acircumflextilde 1001eaa
acircumflextilde 1001eab
Acircumflexbelowdot 1001eac
acircumflexbelowdot 1001ead
Abreveacute 1001eae
abreveacute 1001eaf
Abrevegrave 1001eb0
abrevegrave 1001eb1
Abrevehook 1001eb2
abrevehook 1001eb3
Abrevetilde 1001eb4
abrevetilde 1001eb5
Abrevebelowdot 1001eb6
abrevebelowdot 1001eb7
Ebelowdot 1001eb8
ebelowdot 1001eb9
Ehook 1001eba
ehook 1001ebb
Etilde 1001ebc
etilde 1001ebd
Ecircumflexacute 1001ebe
ecircumflexacute 1001ebf
Ecircumflexgrave 1001ec0
ecircumflexgrave 1001ec1
Ecircumflexhook 1001ec2
ecircumflexhook 1001ec3
Ecircumflextilde 1001ec4
ecircumflextilde 1001ec5
Ecircumflexbelowdot 1001ec6
ecircumflexbelowdot 1001ec7
Ihook 1001ec8
ihook 1001ec9
Ibelowdot 1001eca
ibelowdot 1001ecb
Obelowdot 1001ecc
obelowdot 1001ecd
Ohook 1001ece
ohook 1001ecf
Ocircumflexacute 1001ed0
ocircumflexacute 1001ed1
Ocircumflexgrave 1001ed2
ocircumflexgrave 1001ed3
Ocircumflexhook 1001ed4
ocircumflexhook 1001ed5
Ocircumflextilde 1001ed6
ocircumflextilde 1001ed7
Ocircumflexbelowdot 1001ed8
ocircumflexbelowdot 1001ed9
Ohornacute 1001eda
ohornacute 1001edb
Ohorngrave 1001edc
ohorngrave 1001edd
Ohornhook 1001ede
ohornhook 1001edf
Ohorntilde 1001ee0
ohorntilde 1001ee1
Ohornbelowdot 1001ee2
ohornbelowdot 1001ee3
Ubelowdot 1001ee4
ubelowdot 1001ee5
Uhook 1001ee6
uhook 1001ee7
Uhornacute 1001ee8
uhornacute 1001ee9
Uhorngrave 1001eea
uhorngrave 1001eeb
Uhornhook 1001eec
uhornhook 1001eed
Uhorntilde 1001eee
uhorntilde 1001eef
Uhornbelowdot 1001ef0
uhornbelowdot 1001ef1
Ybelowdot 1001ef4
ybelowdot 1001ef5
Yhook 1001ef6
yhook 1001ef7
Ytilde 1001ef8
ytilde 1001ef9
Ohorn 10001a0
ohorn 10001a1
Uhorn 10001af
uhorn 10001b0
combining_tilde 1000303
combining_grave 1000300
combining_acute 1000301
combining_hook 1000309
combining_belowdot 1000323
EcuSign 10020a0
ColonSign 10020a1
CruzeiroSign 10020a2
FFrancSign 10020a3
LiraSign 10020a4
MillSign 10020a5
NairaSign 10020a6
PesetaSign 10020a7
RupeeSign 10020a8
WonSign 10020a9
NewSheqelSign 10020aa
DongSign 10020ab
EuroSign 20ac
zerosuperior 1002070
foursuperior 1002074
fivesuperior 1002075
sixsuperior 1002076
sevensuperior 1002077
eightsuperior 1002078
ninesuperior 1002079
zerosubscript 1002080
onesubscript 1002081
twosubscript 1002082
threesubscript 1002083
foursubscript 1002084
fivesubscript 1002085
sixsubscript 1002086
sevensubscript 1002087
eightsubscript 1002088
ninesubscript 1002089
partdifferential 1002202
emptyset 1002205
elementof 1002208
notelementof 1002209
containsas 100220b
squareroot 100221a
cuberoot 100221b
fourthroot 100221c
dintegral 100222c
tintegral 100222d
because 1002235
approxeq 1002248
notapproxeq 1002247
notidentical 1002262
stricteq 1002263
braille_dot_1 fff1
braille_dot_2 fff2
braille_dot_3 fff3
braille_dot_4 fff4
braille_dot_5 fff5
braille_dot_6 fff6
braille_dot_7 fff7
braille_dot_8 fff8
braille_dot_9 fff9
braille_dot_10 fffa
braille_blank 1002800
braille_dots_1 1002801
braille_dots_2 1002802
braille_dots_12 1002803
braille_dots_3 1002804
braille_dots_13 1002805
braille_dots_23 1002806
braille_dots_123 1002807
braille_dots_4 1002808
braille_dots_14 1002809
braille_dots_24 100280a
braille_dots_124 100280b
braille_dots_34 100280c
braille_dots_134 100280d
braille_dots_234 100280e
braille_dots_1234 100280f
braille_dots_5 1002810
braille_dots_15 1002811
braille_dots_25 1002812
braille_dots_125 1002813
braille_dots_35 1002814
braille_dots_135 1002815
braille_dots_235 1002816
braille_dots_1235 1002817
braille_dots_45 1002818
braille_dots_145 1002819
braille_dots_245 100281a
braille_dots_1245 100281b
braille_dots_345 100281c
braille_dots_1345 100281d
braille_dots_2345 100281e
braille_dots_12345 100281f
braille_dots_6 1002820
braille_dots_16 1002821
braille_dots_26 1002822
braille_dots_126 1002823
braille_dots_36 1002824
braille_dots_136 1002825
braille_dots_236 1002826
braille_dots_1236 1002827
braille_dots_46 1002828
braille_dots_146 1002829
braille_dots_246 100282a
braille_dots_1246 100282b
braille_dots_346 100282c
braille_dots_1346 100282d
braille_dots_2346 100282e
braille_dots_12346 100282f
braille_dots_56 1002830
braille_dots_156 1002831
braille_dots_256 1002832
braille_dots_1256 1002833
braille_dots_356 1002834
braille_dots_1356 1002835
braille_dots_2356 1002836
braille_dots_12356 1002837
braille_dots_456 1002838
braille_dots_1456 1002839
braille_dots_2456 100283a
braille_dots_12456 100283b
braille_dots_3456 100283c
braille_dots_13456 100283d
braille_dots_23456 100283e
braille_dots_123456 100283f
braille_dots_7 1002840
braille_dots_17 1002841
braille_dots_27 1002842
braille_dots_127 1002843
braille_dots_37 1002844
braille_dots_137 1002845
braille_dots_237 1002846
braille_dots_1237 1002847
braille_dots_47 1002848
braille_dots_147 1002849
braille_dots_247 100284a
braille_dots_1247 100284b
braille_dots_347 100284c
braille_dots_1347 100284d
braille_dots_2347 100284e
braille_dots_12347 100284f
braille_dots_57 1002850
braille_dots_157 1002851
braille_dots_257 1002852
braille_dots_1257 1002853
braille_dots_357 1002854
braille_dots_1357 1002855
braille_dots_2357 1002856
braille_dots_12357 1002857
braille_dots_457 1002858
braille_dots_1457 1002859
braille_dots_2457 100285a
braille_dots_12457 100285b
braille_dots_3457 100285c
braille_dots_13457 100285d
braille_dots_23457 100285e
braille_dots_123457 100285f
braille_dots_67 1002860
braille_dots_167 1002861
braille_dots_267 1002862
braille_dots_1267 1002863
braille_dots_367 1002864
braille_dots_1367 1002865
braille_dots_2367 1002866
braille_dots_12367 1002867
braille_dots_467 1002868
braille_dots_1467 1002869
braille_dots_2467 100286a
braille_dots_12467 100286b
braille_dots_3467 100286c
braille_dots_13467 100286d
braille_dots_23467 100286e
braille_dots_123467 100286f
braille_dots_567 1002870
braille_dots_1567 1002871
braille_dots_2567 1002872
braille_dots_12567 1002873
braille_dots_3567 1002874
braille_dots_13567 1002875
braille_dots_23567 1002876
braille_dots_123567 1002877
braille_dots_4567 1002878
braille_dots_14567 1002879
braille_dots_24567 100287a
braille_dots_124567 100287b
braille_dots_34567 100287c
braille_dots_134567 100287d
braille_dots_234567 100287e
braille_dots_1234567 100287f
braille_dots_8 1002880
braille_dots_18 1002881
braille_dots_28 1002882
braille_dots_128 1002883
braille_dots_38 1002884
braille_dots_138 1002885
braille_dots_238 1002886
braille_dots_1238 1002887
braille_dots_48 1002888
braille_dots_148 1002889
braille_dots_248 100288a
braille_dots_1248 100288b
braille_dots_348 100288c
braille_dots_1348 100288d
braille_dots_2348 100288e
braille_dots_12348 100288f
braille_dots_58 1002890
braille_dots_158 1002891
braille_dots_258 1002892
braille_dots_1258 1002893
braille_dots_358 1002894
braille_dots_1358 1002895
braille_dots_2358 1002896
braille_dots_12358 1002897
braille_dots_458 1002898
braille_dots_1458 1002899
braille_dots_2458 100289a
braille_dots_12458 100289b
braille_dots_3458 100289c
braille_dots_13458 100289d
braille_dots_23458 100289e
braille_dots_123458 100289f
braille_dots_68 10028a0
braille_dots_168 10028a1
braille_dots_268 10028a2
braille_dots_1268 10028a3
braille_dots_368 10028a4
braille_dots_1368 10028a5
braille_dots_2368 10028a6
braille_dots_12368 10028a7
braille_dots_468 10028a8
braille_dots_1468 10028a9
braille_dots_2468 10028aa
braille_dots_12468 10028ab
braille_dots_3468 10028ac
braille_dots_13468 10028ad
braille_dots_23468 10028ae
braille_dots_123468 10028af
braille_dots_568 10028b0
braille_dots_1568 10028b1
braille_dots_2568 10028b2
braille_dots_12568 10028b3
braille_dots_3568 10028b4
braille_dots_13568 10028b5
braille_dots_23568 10028b6
braille_dots_123568 10028b7
braille_dots_4568 10028b8
braille_dots_14568 10028b9
braille_dots_24568 10028ba
braille_dots_124568 10028bb
braille_dots_34568 10028bc
braille_dots_134568 10028bd
braille_dots_234568 10028be
braille_dots_1234568 10028bf
braille_dots_78 10028c0
braille_dots_178 10028c1
braille_dots_278 10028c2
braille_dots_1278 10028c3
braille_dots_378 10028c4
braille_dots_1378 10028c5
braille_dots_2378 10028c6
braille_dots_12378 10028c7
braille_dots_478 10028c8
braille_dots_1478 10028c9
braille_dots_2478 10028ca
braille_dots_12478 10028cb
braille_dots_3478 10028cc
braille_dots_13478 10028cd
braille_dots_23478 10028ce
braille_dots_123478 10028cf
braille_dots_578 10028d0
braille_dots_1578 10028d1
braille_dots_2578 10028d2
braille_dots_12578 10028d3
braille_dots_3578 10028d4
braille_dots_13578 10028d5
braille_dots_23578 10028d6
braille_dots_123578 10028d7
braille_dots_4578 10028d8
braille_dots_14578 10028d9
braille_dots_24578 10028da
braille_dots_124578 10028db
braille_dots_34578 10028dc
braille_dots_134578 10028dd
braille_dots_234578 10028de
braille_dots_1234578 10028df
braille_dots_678 10028e0
braille_dots_1678 10028e1
braille_dots_2678 10028e2
braille_dots_12678 10028e3
braille_dots_3678 10028e4
braille_dots_13678 10028e5
braille_dots_23678 10028e6
braille_dots_123678 10028e7
braille_dots_4678 10028e8
braille_dots_14678 10028e9
braille_dots_24678 10028ea
braille_dots_124678 10028eb
braille_dots_34678 10028ec
braille_dots_134678 10028ed
braille_dots_234678 10028ee
braille_dots_1234678 10028ef
braille_dots_5678 10028f0
braille_dots_15678 10028f1
braille_dots_25678 10028f2
braille_dots_125678 10028f3
braille_dots_35678 10028f4
braille_dots_135678 10028f5
braille_dots_235678 10028f6
braille_dots_1235678 10028f7
braille_dots_45678 10028f8
braille_dots_145678 10028f9
braille_dots_245678 10028fa
braille_dots_1245678 10028fb
braille_dots_345678 10028fc
braille_dots_1345678 10028fd
braille_dots_2345678 10028fe
braille_dots_12345678 10028ff
Sinh_ng 1000d82
Sinh_h2 1000d83
Sinh_a 1000d85
Sinh_aa 1000d86
Sinh_ae 1000d87
Sinh_aee 1000d88
Sinh_i 1000d89
Sinh_ii 1000d8a
Sinh_u 1000d8b
Sinh_uu 1000d8c
Sinh_ri 1000d8d
Sinh_rii 1000d8e
Sinh_lu 1000d8f
Sinh_luu 1000d90
Sinh_e 1000d91
Sinh_ee 1000d92
Sinh_ai 1000d93
Sinh_o 1000d94
Sinh_oo 1000d95
Sinh_au 1000d96
Sinh_ka 1000d9a
Sinh_kha 1000d9b
Sinh_ga 1000d9c
Sinh_gha 1000d9d
Sinh_ng2 1000d9e
Sinh_nga 1000d9f
Sinh_ca 1000da0
Sinh_cha 1000da1
Sinh_ja 1000da2
Sinh_jha 1000da3
Sinh_nya 1000da4
Sinh_jnya 1000da5
Sinh_nja 1000da6
Sinh_tta 1000da7
Sinh_ttha 1000da8
Sinh_dda 1000da9
Sinh_ddha 1000daa
Sinh_nna 1000dab
Sinh_ndda 1000dac
Sinh_tha 1000dad
Sinh_thha 1000dae
Sinh_dha 1000daf
Sinh_dhha 1000db0
Sinh_na 1000db1
Sinh_ndha 1000db3
Sinh_pa 1000db4
Sinh_pha 1000db5
Sinh_ba 1000db6
Sinh_bha 1000db7
Sinh_ma 1000db8
Sinh_mba 1000db9
Sinh_ya 1000dba
Sinh_ra 1000dbb
Sinh_la 1000dbd
Sinh_va 1000dc0
Sinh_sha 1000dc1
Sinh_ssha 1000dc2
Sinh_sa 1000dc3
Sinh_ha 1000dc4
Sinh_lla 1000dc5
Sinh_fa 1000dc6
Sinh_al 1000dca
Sinh_aa2 1000dcf
Sinh_ae2 1000dd0
Sinh_aee2 1000dd1
Sinh_i2 1000dd2
Sinh_ii2 1000dd3
Sinh_u2 1000dd4
Sinh_uu2 1000dd6
Sinh_ru2 1000dd8
Sinh_e2 1000dd9
Sinh_ee2 1000dda
Sinh_ai2 1000ddb
Sinh_o2 1000ddc
Sinh_oo2 1000ddd
Sinh_au2 1000dde
Sinh_lu2 1000ddf
Sinh_ruu2 1000df2
Sinh_luu2 1000df3
Sinh_kunddaliya 1000df4
XF86ModeLock 1008ff01
XF86MonBrightnessUp 1008ff02
XF86MonBrightnessDown 1008ff03
XF86KbdLightOnOff 1008ff04
XF86KbdBrightnessUp 1008ff05
XF86KbdBrightnessDown 1008ff06
XF86MonBrightnessCycle 1008ff07
XF86Standby 1008ff10
XF86AudioLowerVolume 1008ff11
XF86AudioMute 1008ff12
XF86AudioRaiseVolume 1008ff13
XF86AudioPlay 1008ff14
XF86AudioStop 1008ff15
XF86AudioPrev 1008ff16
XF86AudioNext 1008ff17
XF86HomePage 1008ff18
XF86Mail 1008ff19
XF86Start 1008ff1a
XF86Search 1008ff1b
XF86AudioRecord 1008ff1c
XF86Calculator 1008ff1d
XF86Memo 1008ff1e
XF86ToDoList 1008ff1f
XF86Calendar 1008ff20
XF86PowerDown 1008ff21
XF86ContrastAdjust 1008ff22
XF86RockerUp 1008ff23
XF86RockerDown 1008ff24
XF86RockerEnter 1008ff25
XF86Back 1008ff26
XF86Forward 1008ff27
XF86Stop 1008ff28
XF86Refresh 1008ff29
XF86PowerOff 1008ff2a
XF86WakeUp 1008ff2b
XF86Eject 1008ff2c
XF86ScreenSaver 1008ff2d
XF86WWW 1008ff2e
XF86Sleep 1008ff2f
XF86Favorites 1008ff30
XF86AudioPause 1008ff31
XF86AudioMedia 1008ff32
XF86MyComputer 1008ff33
XF86VendorHome 1008ff34
XF86LightBulb 1008ff35
XF86Shop 1008ff36
XF86History 1008ff37
XF86OpenURL 1008ff38
XF86AddFavorite 1008ff39
XF86HotLinks 1008ff3a
XF86BrightnessAdjust 1008ff3b
XF86Finance 1008ff3c
XF86Community 1008ff3d
XF86AudioRewind 1008ff3e
XF86BackForward 1008ff3f
XF86Launch0 1008ff40
XF86Launch1 1008ff41
XF86Launch2 1008ff42
XF86Launch3 1008ff43
XF86Launch4 1008ff44
XF86Launch5 1008ff45
XF86Launch6 1008ff46
XF86Launch7 1008ff47
XF86Launch8 1008ff48
XF86Launch9 1008ff49
XF86LaunchA 1008ff4a
XF86LaunchB 1008ff4b
XF86LaunchC 1008ff4c
XF86LaunchD 1008ff4d
XF86LaunchE 1008ff4e
XF86LaunchF 1008ff4f
XF86ApplicationLeft 1008ff50
XF86ApplicationRight 1008ff51
XF86Book 1008ff52
XF86CD 1008ff53
XF86MediaSelectCD 1008ff53
XF86Calculater 1008ff54
XF86Clear 1008ff55
XF86Close 1008ff56
XF86Copy 1008ff57
XF86Cut 1008ff58
XF86Display 1008ff59
XF86DOS 1008ff5a
XF86Documents 1008ff5b
XF86Excel 1008ff5c
XF86Explorer 1008ff5d
XF86Game 1008ff5e
XF86Go 1008ff5f
XF86iTouch 1008ff60
XF86LogOff 1008ff61
XF86Market 1008ff62
XF86Meeting 1008ff63
XF86MenuKB 1008ff65
XF86MenuPB 1008ff66
XF86MySites 1008ff67
XF86New 1008ff68
XF86News 1008ff69
XF86OfficeHome 1008ff6a
XF86Open 1008ff6b
XF86Option 1008ff6c
XF86Paste 1008ff6d
XF86Phone 1008ff6e
XF86Q 1008ff70
XF86Reply 1008ff72
XF86Reload 1008ff73
XF86RotateWindows 1008ff74
XF86RotationPB 1008ff75
XF86RotationKB 1008ff76
XF86Save 1008ff77
XF86ScrollUp 1008ff78
XF86ScrollDown 1008ff79
XF86ScrollClick 1008ff7a
XF86Send 1008ff7b
XF86Spell 1008ff7c
XF86SplitScreen 1008ff7d
XF86Support 1008ff7e
XF86TaskPane 1008ff7f
XF86Terminal 1008ff80
XF86Tools 1008ff81
XF86Travel 1008ff82
XF86UserPB 1008ff84
XF86User1KB 1008ff85
XF86User2KB 1008ff86
XF86Video 1008ff87
XF86WheelButton 1008ff88
XF86Word 1008ff89
XF86Xfer 1008ff8a
XF86ZoomIn 1008ff8b
XF86ZoomOut 1008ff8c
XF86Away 1008ff8d
XF86Messenger 1008ff8e
XF86WebCam 1008ff8f
XF86MailForward 1008ff90
XF86Pictures 1008ff91
XF86Music 1008ff92
XF86Battery 1008ff93
XF86Bluetooth 1008ff94
XF86WLAN 1008ff95
XF86UWB 1008ff96
XF86AudioForward 1008ff97
XF86AudioRepeat 1008ff98
XF86AudioRandomPlay 1008ff99
XF86Subtitle 1008ff9a
XF86AudioCycleTrack 1008ff9b
XF86CycleAngle 1008ff9c
XF86FrameBack 1008ff9d
XF86FrameForward 1008ff9e
XF86Time 1008ff9f
XF86Select 1008ffa0
XF86View 1008ffa1
XF86TopMenu 1008ffa2
XF86Red 1008ffa3
XF86Green 1008ffa4
XF86Yellow 1008ffa5
XF86Blue 1008ffa6
XF86Suspend 1008ffa7
XF86Hibernate 1008ffa8
XF86TouchpadToggle 1008ffa9
XF86TouchpadOn 1008ffb0
XF86TouchpadOff 1008ffb1
XF86AudioMicMute 1008ffb2
XF86Keyboard 1008ffb3
XF86WWAN 1008ffb4
XF86RFKill 1008ffb5
XF86AudioPreset 1008ffb6
XF86RotationLockToggle 1008ffb7
XF86FullScreen 1008ffb8
XF86Switch_VT_1 1008fe01
XF86Switch_VT_2 1008fe02
XF86Switch_VT_3 1008fe03
XF86Switch_VT_4 1008fe04
XF86Switch_VT_5 1008fe05
XF86Switch_VT_6 1008fe06
XF86Switch_VT_7 1008fe07
XF86Switch_VT_8 1008fe08
XF86Switch_VT_9 1008fe09
XF86Switch_VT_10 1008fe0a
XF86Switch_VT_11 1008fe0b
XF86Switch_VT_12 1008fe0c
XF86Ungrab 1008fe20
XF86ClearGrab 1008fe21
XF86Next_VMode 1008fe22
XF86Prev_VMode 1008fe23
XF86LogWindowTree 1008fe24
XF86LogGrabInfo 1008fe25
XF86MediaPlayPause 100810a4
XF86Exit 100810ae
XF86AudioBassBoost 100810d1
XF86Sport 100810dc
XF86BrightnessAuto 100810f4
XF86MonBrightnessAuto 100810f4
XF86DisplayOff 100810f5
XF86OK 10081160
XF86GoTo 10081162
XF86Info 10081166
XF86VendorLogo 10081168
XF86MediaSelectProgramGuide 1008116a
XF86MediaSelectHome 1008116e
XF86MediaLanguageMenu 10081170
XF86MediaTitleMenu 10081171
XF86AudioChannelMode 10081175
XF86AspectRatio 10081177
XF86MediaSelectPC 10081178
XF86MediaSelectTV 10081179
XF86MediaSelectCable 1008117a
XF86MediaSelectVCR 1008117b
XF86MediaSelectVCRPlus 1008117c
XF86MediaSelectSatellite 1008117d
XF86MediaSelectTape 10081180
XF86MediaSelectRadio 10081181
XF86MediaSelectTuner 10081182
XF86MediaPlayer 10081183
XF86MediaSelectTeletext 10081184
XF86DVD 10081185
XF86MediaSelectDVD 10081185
XF86MediaSelectAuxiliary 10081186
XF86Audio 10081188
XF86ChannelUp 10081192
XF86ChannelDown 10081193
XF86MediaPlaySlow 10081199
XF86Break 1008119b
XF86NumberEntryMode 1008119d
XF86VideoPhone 100811a0
XF86ZoomReset 100811a4
XF86Editor 100811a6
XF86GraphicsEditor 100811a8
XF86Presentation 100811a9
XF86Database 100811aa
XF86Voicemail 100811ac
XF86Addressbook 100811ad
XF86DisplayToggle 100811af
XF86SpellCheck 100811b0
XF86ContextMenu 100811b6
XF86MediaRepeat 100811b7
XF8610ChannelsUp 100811b8
XF8610ChannelsDown 100811b9
XF86Images 100811ba
XF86NotificationCenter 100811bc
XF86PickupPhone 100811bd
XF86HangupPhone 100811be
XF86LinkPhone 100811bf
XF86Fn 100811d0
XF86Fn_Esc 100811d1
XF86Fn_F1 100811d2
XF86Fn_F2 100811d3
XF86Fn_F3 100811d4
XF86Fn_F4 100811d5
XF86Fn_F5 100811d6
XF86Fn_F6 100811d7
XF86Fn_F7 100811d8
XF86Fn_F8 100811d9
XF86Fn_F9 100811da
XF86Fn_F10 100811db
XF86Fn_F11 100811dc
XF86Fn_F12 100811dd
XF86Fn_1 100811de
XF86Fn_2 100811df
XF86Fn_D 100811e0
XF86Fn_E 100811e1
XF86Fn_F 100811e2
XF86Fn_S 100811e3
XF86Fn_B 100811e4
XF86FnRightShift 100811e5
XF86Numeric0 10081200
XF86Numeric1 10081201
XF86Numeric2 10081202
XF86Numeric3 10081203
XF86Numeric4 10081204
XF86Numeric5 10081205
XF86Numeric6 10081206
XF86Numeric7 10081207
XF86Numeric8 10081208
XF86Numeric9 10081209
XF86NumericStar 1008120a
XF86NumericPound 1008120b
XF86NumericA 1008120c
XF86NumericB 1008120d
XF86NumericC 1008120e
XF86NumericD 1008120f
XF86CameraFocus 10081210
XF86WPSButton 10081211
XF86CameraZoomIn 10081215
XF86CameraZoomOut 10081216
XF86CameraUp 10081217
XF86CameraDown 10081218
XF86CameraLeft 10081219
XF86CameraRight 1008121a
XF86AttendantOn 1008121b
XF86AttendantOff 1008121c
XF86AttendantToggle 1008121d
XF86LightsToggle 1008121e
XF86ALSToggle 10081230
XF86RefreshRateToggle 10081232
XF86Buttonconfig 10081240
XF86Taskmanager 10081241
XF86Journal 10081242
XF86ControlPanel 10081243
XF86AppSelect 10081244
XF86Screensaver 10081245
XF86VoiceCommand 10081246
XF86Assistant 10081247
XF86EmojiPicker 10081249
XF86Dictate 1008124a
XF86CameraAccessEnable 1008124b
XF86CameraAccessDisable 1008124c
XF86CameraAccessToggle 1008124d
XF86Accessibility 1008124e
XF86DoNotDisturb 1008124f
XF86BrightnessMin 10081250
XF86BrightnessMax 10081251
XF86KbdInputAssistPrev 10081260
XF86KbdInputAssistNext 10081261
XF86KbdInputAssistPrevgroup 10081262
XF86KbdInputAssistNextgroup 10081263
XF86KbdInputAssistAccept 10081264
XF86KbdInputAssistCancel 10081265
XF86RightUp 10081266
XF86RightDown 10081267
XF86LeftUp 10081268
XF86LeftDown 10081269
XF86RootMenu 1008126a
XF86MediaTopMenu 1008126b
XF86Numeric11 1008126c
XF86Numeric12 1008126d
XF86AudioDesc 1008126e
XF863DMode 1008126f
XF86NextFavorite 10081270
XF86StopRecord 10081271
XF86PauseRecord 10081272
XF86VOD 10081273
XF86Unmute 10081274
XF86FastReverse 10081275
XF86SlowReverse 10081276
XF86Data 10081277
XF86OnScreenKeyboard 10081278
XF86PrivacyScreenToggle 10081279
XF86SelectiveScreenshot 1008127a
XF86NextElement 1008127b
XF86PreviousElement 1008127c
XF86AutopilotEngageToggle 1008127d
XF86MarkWaypoint 1008127e
XF86Sos 1008127f
XF86NavChart 10081280
XF86FishingChart 10081281
XF86SingleRangeRadar 10081282
XF86DualRangeRadar 10081283
XF86RadarOverlay 10081284
XF86TraditionalSonar 10081285
XF86ClearvuSonar 10081286
XF86SidevuSonar 10081287
XF86NavInfo 10081288
XF86Macro1 10081290
XF86Macro2 10081291
XF86Macro3 10081292
XF86Macro4 10081293
XF86Macro5 10081294
XF86Macro6 10081295
XF86Macro7 10081296
XF86Macro8 10081297
XF86Macro9 10081298
XF86Macro10 10081299
XF86Macro11 1008129a
XF86Macro12 1008129b
XF86Macro13 1008129c
XF86Macro14 1008129d
XF86Macro15 1008129e
XF86Macro16 1008129f
XF86Macro17 100812a0
XF86Macro18 100812a1
XF86Macro19 100812a2
XF86Macro20 100812a3
XF86Macro21 100812a4
XF86Macro22 100812a5
XF86Macro23 100812a6
XF86Macro24 100812a7
XF86Macro25 100812a8
XF86Macro26 100812a9
XF86Macro27 100812aa
XF86Macro28 100812ab
XF86Macro29 100812ac
XF86Macro30 100812ad
XF86MacroRecordStart 100812b0
XF86MacroRecordStop 100812b1
XF86MacroPresetCycle 100812b2
XF86MacroPreset1 100812b3
XF86MacroPreset2 100812b4
XF86MacroPreset3 100812b5
XF86KbdLcdMenu1 100812b8
XF86KbdLcdMenu2 100812b9
XF86KbdLcdMenu3 100812ba
XF86KbdLcdMenu4 100812bb
XF86KbdLcdMenu5 100812bc
XF86PerformanceMode 100812bd
SunFA_Grave 1005ff00
SunFA_Circum 1005ff01
SunFA_Tilde 1005ff02
SunFA_Acute 1005ff03
SunFA_Diaeresis 1005ff04
SunFA_Cedilla 1005ff05
SunF36 1005ff10
SunF37 1005ff11
SunSys_Req 1005ff60
SunPrint_Screen ff61
SunCompose ff20
SunAltGraph ff7e
SunPageUp ff55
SunPageDown ff56
SunUndo ff65
SunAgain ff66
SunFind ff68
SunStop ff69
SunProps 1005ff70
SunFront 1005ff71
SunCopy 1005ff72
SunOpen 1005ff73
SunPaste 1005ff74
SunCut 1005ff75
SunPowerSwitch 1005ff76
SunAudioLowerVolume 1005ff77
SunAudioMute 1005ff78
SunAudioRaiseVolume 1005ff79
SunVideoDegauss 1005ff7a
SunVideoLowerBrightness 1005ff7b
SunVideoRaiseBrightness 1005ff7c
SunPowerSwitchShift 1005ff7d
Dring_accent 1000feb0
Dcircumflex_accent 1000fe5e
Dcedilla_accent 1000fe2c
Dacute_accent 1000fe27
Dgrave_accent 1000fe60
Dtilde 1000fe7e
Ddiaeresis 1000fe22
DRemove 1000ff00
hpClearLine 1000ff6f
hpInsertLine 1000ff70
hpDeleteLine 1000ff71
hpInsertChar 1000ff72
hpDeleteChar 1000ff73
hpBackTab 1000ff74
hpKP_BackTab 1000ff75
hpModelock1 1000ff48
hpModelock2 1000ff49
hpReset 1000ff6c
hpSystem 1000ff6d
hpUser 1000ff6e
hpmute_acute 100000a8
hpmute_grave 100000a9
hpmute_asciicircum 100000aa
hpmute_diaeresis 100000ab
hpmute_asciitilde 100000ac
hplira 100000af
hpguilder 100000be
hpYdiaeresis 100000ee
hpIO 100000ee
hplongminus 100000f6
hpblock 100000fc
Reset 1000ff6c
System 1000ff6d
User 1000ff6e
ClearLine 1000ff6f
InsertLine 1000ff70
DeleteLine 1000ff71
InsertChar 1000ff72
DeleteChar 1000ff73
BackTab 1000ff74
KP_BackTab 1000ff75
Ext16bit_L 1000ff76
Ext16bit_R 1000ff77
mute_acute 100000a8
mute_grave 100000a9
mute_asciicircum 100000aa
mute_diaeresis 100000ab
mute_asciitilde 100000ac
lira 100000af
guilder 100000be
IO 100000ee
longminus 100000f6
block 100000fc
apLineDel 1000ff00
apCharDel 1000ff01
apCopy 1000ff02
apCut 1000ff03
apPaste 1000ff04
apMove 1000ff05
apGrow 1000ff06
apCmd 1000ff07
apShell 1000ff08
apLeftBar 1000ff09
apRightBar 1000ff0a
apLeftBox 1000ff0b
apRightBox 1000ff0c
apUpBox 1000ff0d
apDownBox 1000ff0e
apPop 1000ff0f
apRead 1000ff10
apEdit 1000ff11
apSave 1000ff12
apExit 1000ff13
apRepeat 1000ff14
apKP_parenleft 1000ffa8
apKP_parenright 1000ffa9`
