// keyboard.odin — which keyboard layout the compositor types with, and
// changing it while clients are running.
//
// On bare metal the layout is a system setting, not a session one: the
// installer writes `/etc/palm/keyboard` (`layout = fr`, `variant =`,
// `options =`, see distro/INSTALLER.md) and every wm --drm on the machine —
// the greeter's, the user's, the live installer's — types with it. This file
// reads that file, compiles it with xkbcomp.odin from /usr/share/X11/xkb, and
// hands the result to the same tables evdev.odin and forward_key already use.
//
// Precedence, highest first:
//   XKB_DEFAULT_LAYOUT (+ XKB_DEFAULT_VARIANT), XKB_DEFAULT_OPTIONS,
//   XKB_DEFAULT_RULES, XKB_DEFAULT_MODEL       — a person testing something
//   /etc/palm/keyboard                          — what the installer chose
//   /etc/vconsole.conf, xorg.conf.d             — what another distro left
//   us
// XKB_DEFAULT_VARIANT on its own applies to the file's layout; next to
// XKB_DEFAULT_LAYOUT it belongs to that layout and the file's variant, which
// was written for a different one, is dropped.
//
// A layout that does not exist, a variant its file does not define, or a
// keymap that compiles to something that cannot type letters is logged and
// replaced by `us`. A machine whose keyboard file is wrong must still be able
// to type the command that fixes it.
//
// Changing it live. The installer's keyboard step rewrites the file as the
// user picks a layout, and expects the test field — a client that is already
// running — to type with the new one at once. wm notices in three ways:
// SIGHUP (always recompiles), inotify on the file's directory (immediate),
// and the once-a-second check the config reload already does (in case the
// directory did not exist when wm started). The new keymap goes to every
// wl_keyboard of every client as a fresh memfd, followed by the modifier
// state, which is what the protocol asks a compositor to do when the layout
// changes: the client drops its old xkb state and resolves keycodes against
// the new map from the next key on.
//
// Several layouts (`layout = us,ru` with `options = grp:alt_shift_toggle`)
// compile into several XKB groups. The group the user switched to travels in
// wl_keyboard.modifiers, and the reverse table forward_key uses is rebuilt
// for that group so a keysym that only exists in the second layout still
// finds its key.
package wm

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"

KBD_CONF_DEFAULT :: "/etc/palm/keyboard"

// kbd_conf_path is the file, or PALMY_WM_KEYBOARD_CONF so the self test and
// a nested run can point it elsewhere without touching /etc.
kbd_conf_path :: proc() -> string {
	if v := os.get_env("PALMY_WM_KEYBOARD_CONF", context.temp_allocator); v != "" {
		return v
	}
	return KBD_CONF_DEFAULT
}

// ---------------------------------------------------------------------------
// The file
// ---------------------------------------------------------------------------

Kbd_Conf :: struct {
	layout:  string,
	variant: string,
	options: string,
	model:   string,
}

// kbd_conf_parse reads `key = value` lines. `#` starts a comment, values may
// be quoted, keys are case-insensitive, and an empty value means "none".
// Anything it does not understand is reported rather than silently dropped,
// so a typo shows up in the session log.
kbd_conf_parse :: proc(text: string, allocator := context.temp_allocator) -> (c: Kbd_Conf, problems: [dynamic]string) {
	problems = make([dynamic]string, allocator)
	rest := text
	n := 0
	for line in strings.split_lines_iterator(&rest) {
		n += 1
		l := line
		if h := strings.index_byte(l, '#'); h >= 0 {
			l = l[:h]
		}
		l = strings.trim_space(l)
		if l == "" {
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq <= 0 {
			append(&problems, fmt.aprintf("line %d: expected key = value, got %q", n, l, allocator = allocator))
			continue
		}
		key := strings.to_lower(strings.trim_space(l[:eq]), allocator)
		val := strings.trim_space(l[eq + 1:])
		if len(val) >= 2 && (val[0] == '"' || val[0] == '\'') && val[len(val) - 1] == val[0] {
			val = strings.trim_space(val[1:len(val) - 1])
		}
		val = strings.clone(val, allocator)
		switch key {
		case "layout":
			c.layout = val
		case "variant":
			c.variant = val
		case "options", "option":
			c.options = val
		case "model":
			c.model = val
		case:
			append(&problems, fmt.aprintf("line %d: unknown key %q", n, key, allocator = allocator))
		}
	}
	return
}

// Kbd_Choice is what was decided and why, for the log and for "has anything
// changed?" when the file is touched.
Kbd_Choice :: struct {
	rmlvo:  Xkb_Rmlvo,
	origin: string,
}

kbd_split_options :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for o in strings.split(s, ",", context.temp_allocator) {
		if t := strings.trim_space(o); t != "" {
			append(&out, t)
		}
	}
	return out[:]
}

// kbd_choose applies the precedence above. Everything it returns lives in the
// temp allocator.
kbd_choose :: proc() -> Kbd_Choice {
	env :: proc(n: string) -> string {return strings.trim_space(os.get_env(n, context.temp_allocator))}
	path := kbd_conf_path()
	text, have_file := ev_read_file(path, context.temp_allocator)
	if !have_file {
		// No system file: the older places xkb_host_rmlvo knows, which also
		// reads the XKB_DEFAULT_* variables first.
		m := xkb_host_rmlvo("")
		origin := "the default (us)"
		switch {
		case env("XKB_DEFAULT_LAYOUT") != "":
			origin = "XKB_DEFAULT_LAYOUT"
		case m.layout != "":
			origin = "/etc/vconsole.conf or xorg.conf.d"
		}
		return {rmlvo = m, origin = origin}
	}

	c, problems := kbd_conf_parse(text)
	for p in problems {
		fmt.eprintfln("wm: keyboard: %s: %s", path, p)
	}
	m := Xkb_Rmlvo {
		layout  = c.layout,
		variant = c.variant,
		model   = c.model,
		options = kbd_split_options(c.options),
	}
	origin := path
	overrides := make([dynamic]string, context.temp_allocator)
	if v := env("XKB_DEFAULT_LAYOUT"); v != "" {
		m.layout = v
		m.variant = env("XKB_DEFAULT_VARIANT")
		append(&overrides, "XKB_DEFAULT_LAYOUT")
	} else if v := env("XKB_DEFAULT_VARIANT"); v != "" {
		m.variant = v
		append(&overrides, "XKB_DEFAULT_VARIANT")
	}
	if v := env("XKB_DEFAULT_OPTIONS"); v != "" {
		m.options = kbd_split_options(v)
		append(&overrides, "XKB_DEFAULT_OPTIONS")
	}
	if v := env("XKB_DEFAULT_MODEL"); v != "" {
		m.model = v
		append(&overrides, "XKB_DEFAULT_MODEL")
	}
	if v := env("XKB_DEFAULT_RULES"); v != "" {
		m.rules = v
		append(&overrides, "XKB_DEFAULT_RULES")
	}
	if len(overrides) > 0 {
		origin = fmt.tprintf("%s, overridden by %s", path, strings.join(overrides[:], ", ", context.temp_allocator))
	}
	return {rmlvo = m, origin = origin}
}

kbd_rmlvo_equal :: proc(a, b: Xkb_Rmlvo) -> bool {
	if a.rules != b.rules || a.model != b.model || a.layout != b.layout || a.variant != b.variant {
		return false
	}
	if len(a.options) != len(b.options) {
		return false
	}
	for o, i in a.options {
		if o != b.options[i] {
			return false
		}
	}
	return true
}

kbd_rmlvo_clone :: proc(m: Xkb_Rmlvo) -> Xkb_Rmlvo {
	out := Xkb_Rmlvo {
		rules   = strings.clone(m.rules),
		model   = strings.clone(m.model),
		layout  = strings.clone(m.layout),
		variant = strings.clone(m.variant),
	}
	if len(m.options) > 0 {
		out.options = make([]string, len(m.options))
		for o, i in m.options {
			out.options[i] = strings.clone(o)
		}
	}
	return out
}

kbd_rmlvo_free :: proc(m: ^Xkb_Rmlvo) {
	delete(m.rules)
	delete(m.model)
	delete(m.layout)
	delete(m.variant)
	for o in m.options {
		delete(o)
	}
	delete(m.options)
	m^ = {}
}

kbd_describe :: proc(m: Xkb_Rmlvo) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, m.layout == "" ? "us" : m.layout)
	if m.variant != "" {
		fmt.sbprintf(&b, "(%s)", m.variant)
	}
	if len(m.options) > 0 {
		fmt.sbprintf(&b, " options %s", strings.join(m.options, ",", context.temp_allocator))
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Compiling, with the fallback
// ---------------------------------------------------------------------------

kbd_name_ok :: proc(s: string) -> bool {
	if s == "" || len(s) > 64 {
		return false
	}
	for c in transmute([]u8)s {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// kbd_validate checks what xkb_compile would otherwise skip quietly: a symbols
// file that is not there, or a variant the file does not define, compiles to
// `pc` alone — modifiers and no letters. Returns "" when the description is
// usable, or when there is no XKB data to check against at all (the compiler
// then falls back to its built-in US keymap and says so itself).
kbd_validate :: proc(m: Xkb_Rmlvo) -> string {
	layouts := strings.split(m.layout == "" ? "us" : m.layout, ",", context.temp_allocator)
	variants := strings.split(m.variant, ",", context.temp_allocator)
	if len(layouts) > XKB_MAX_GROUPS {
		return fmt.tprintf("%d layouts, at most %d are possible", len(layouts), XKB_MAX_GROUPS)
	}
	if len(variants) > len(layouts) {
		return fmt.tprintf("%d variants for %d layouts", len(variants), len(layouts))
	}
	have_data := os.exists(fmt.tprintf("%s/symbols", xkb_root()))
	for raw, i in layouts {
		l := strings.trim_space(raw)
		if !kbd_name_ok(l) {
			return fmt.tprintf("%q is not a layout name", l)
		}
		v := i < len(variants) ? strings.trim_space(variants[i]) : ""
		if v != "" && !kbd_name_ok(v) {
			return fmt.tprintf("%q is not a variant name", v)
		}
		if !have_data {
			continue
		}
		src, ok := xkb_src_load("symbols", l)
		if !ok {
			return fmt.tprintf("no layout %q in %s/symbols", l, xkb_root())
		}
		if v != "" {
			if _, _, found := xkb_section(src, "xkb_symbols", v); !found {
				return fmt.tprintf("layout %q has no variant %q", l, v)
			}
		}
	}
	return ""
}

// kbd_typeable is the last line of defence: the letter rows have to produce
// something. A keymap where they do not is a dead keyboard however it was
// arrived at.
kbd_typeable :: proc(km: ^Xkb_Keymap) -> bool {
	n := 0
	for code in u32(24) ..= u32(61) { 	// AD01 .. AB10 in evdev keycodes
		sym, _, _ := xkb_lookup(km, code, 0, 0)
		if sym != XKB_SYM_NO && sym != XKB_SYM_VOID {
			n += 1
		}
	}
	return n >= 20
}

// kbd_compile turns a description into a finished keymap, text included. It
// always returns one that types; `fallback_why` says when that is not the one
// asked for.
kbd_compile :: proc(m: Xkb_Rmlvo) -> (km: Xkb_Keymap, fallback_why: string) {
	want := m
	if why := kbd_validate(want); why != "" {
		fallback_why = why
	} else {
		if xkb_compile(&km, want) && kbd_typeable(&km) {
			if km.rules == "builtin" && (want.layout != "" && want.layout != "us") {
				fallback_why = fmt.tprintf("%s has no XKB data; using the built-in US keymap", xkb_root())
			}
		} else {
			fallback_why = fmt.tprintf("the keymap for %s cannot type", kbd_describe(want))
		}
	}
	if fallback_why != "" && !(km.ok && km.rules == "builtin") {
		us := Xkb_Rmlvo {
			rules = want.rules,
			model = want.model,
			layout = "us",
		}
		if !xkb_compile(&km, us) || !kbd_typeable(&km) {
			xkb_compile_fallback(&km, "the built-in US keymap")
		}
	}
	km.text = xkb_keymap_text(&km)
	return
}

// kbd_install makes `km` the compositor's keymap. The xkb state keeps what
// survives a layout change — Caps Lock and Num Lock stay locked, held keys
// stay held — and goes back to the first layout, as a new keymap means.
kbd_install :: proc(km: Xkb_Keymap) {
	old := xkb_km
	xkb_km = km
	xkb_sort_km = &xkb_km
	if old.ok || len(old.keys) > 0 {
		delete(old.keys)
		delete(old.types)
		delete(old.indicators)
		delete(old.compat)
		delete(old.modmap_sym)
		delete(old.vmods)
		delete(old.text)
		delete(old.source)
		xkb_keymap_free(&old)
	}

	xkb_st.group = 0
	xkb_st.latched_group = 0
	xkb_st.locked_group = 0
	xkb_st.latched = 0
	xkb_st.depressed = 0
	for c in 0 ..< u32(XKB_KEYCODE_SPAN) {
		if !xkb_st.down[c] {
			continue
		}
		if k := xkb_key_by_code(&xkb_km, c); k != nil {
			xkb_st.depressed |= xkb_km.modmap[k.name]
		}
	}
}

// ---------------------------------------------------------------------------
// The compositor side
// ---------------------------------------------------------------------------

Kbd :: struct {
	current:    Xkb_Rmlvo, // what was asked for last, before any fallback
	origin:     string,
	label:      string, // for the bar: "fr", "us", "de"
	fell_back:  bool,

	hup:        bool, // SIGHUP arrived
	ino:        linux.Fd,
	watched:    bool,
	sig:        Kbd_Sig,
	checked_at: f64,
	reloads:    int,
}

kbd: Kbd

// Set from the signal handler; the loop reads it.
kbd_hup_flag: i32

kbd_on_hup :: proc "c" (sig: linux.Signal) {
	kbd_hup_flag = 1
}

// Kbd_Sig is enough of a stat to tell that the file was replaced or rewritten.
Kbd_Sig :: struct {
	exists: bool,
	ino:    u64,
	size:   i64,
	mtime:  i64,
}

kbd_sig :: proc(path: string) -> Kbd_Sig {
	st: linux.Stat
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	if linux.stat(cpath, &st) != .NONE {
		return {}
	}
	return {
		exists = true,
		ino = u64(st.ino),
		size = i64(st.size),
		mtime = i64(st.mtime.time_sec) * 1_000_000_000 + i64(st.mtime.time_nsec),
	}
}

// kbd_label is the short name the bar shows: the active group's layout.
kbd_label :: proc(km: ^Xkb_Keymap, group: int) -> string {
	ls := strings.split(km.layout == "" ? "us" : km.layout, ",", context.temp_allocator)
	g := clamp(group, 0, len(ls) - 1)
	return strings.trim_space(ls[g])
}

// kbd_load decides, compiles and installs, and rebuilds everything derived
// from the keymap. Clients are told by kbd_broadcast, separately, because at
// start-up there are none yet.
kbd_load :: proc(s: ^Server, choice: Kbd_Choice) {
	km, why := kbd_compile(choice.rmlvo)
	kbd_install(km)

	kbd_rmlvo_free(&kbd.current)
	kbd.current = kbd_rmlvo_clone(choice.rmlvo)
	delete(kbd.origin)
	kbd.origin = strings.clone(choice.origin)
	kbd.fell_back = why != ""
	delete(kbd.label)
	kbd.label = strings.clone(kbd_label(&xkb_km, 0))

	if why != "" {
		fmt.eprintfln("wm: keyboard: %s (from %s): %s; falling back to %s", kbd_describe(choice.rmlvo), choice.origin, why, xkb_km.source)
	}
	fmt.printfln(
		"wm: keyboard: %s from %s — keymap %s, %d group(s), symbols %s",
		kbd_describe(choice.rmlvo),
		choice.origin,
		xkb_km.source,
		max(xkb_km.ngroups, 1),
		xkb_km.comp_symbols,
	)

	delete(s.kt.rev)
	delete(s.kt.text)
	s.kt = {}
	if !keytable_from_compiled(&s.kt, &xkb_km) {
		fmt.eprintfln("wm: keyboard: no usable keymap; clients will have no keyboard")
	}
	old_fd := s.keymap_fd
	if make_keymap_fd(s, s.kt.text) {
		if old_fd > 0 && old_fd != s.keymap_fd {
			linux.close(old_fd)
		}
	} else {
		fmt.eprintfln("wm: keyboard: could not publish the keymap; clients keep the previous one")
	}
}

// kbd_broadcast sends the current keymap to every keyboard of every client,
// then the modifier state to whoever has focus. Not flushed here: the loop's
// flush_all does it with everything else from this iteration.
kbd_broadcast :: proc(s: ^Server) -> (sent: int) {
	if s.keymap_fd <= 0 {
		return 0
	}
	for c in s.clients {
		if c.dead {
			continue
		}
		for k in c.keyboards {
			dup, err := linux.dup(s.keymap_fd)
			if err != .NONE {
				continue
			}
			// wl_keyboard.keymap(format = xkb_v1, fd, size)
			event(c, k, 0, u32(1), Fd(dup), u32(s.keymap_size))
			sent += 1
		}
	}
	if surf := s.kbd_surf; surf != nil && surf.client != nil && !surf.client.dead {
		for k in surf.client.keyboards {
			event(surf.client, k, 4, next_serial(s), s.mod_mask, u32(0), u32(0), s.kt.group)
		}
		s.mod_group = s.kt.group
	}
	return
}

// kbd_start is bare_main's keyboard set-up, in place of xkb_init_default.
kbd_start :: proc(s: ^Server) {
	kbd_load(s, kbd_choose())
	kbd.sig = kbd_sig(kbd_conf_path())
	kbd.checked_at = wall_now()
	kbd_watch_start()

	sa := linux.Sig_Action {
		handler = kbd_on_hup,
	}
	linux.rt_sigaction(.SIGHUP, &sa, nil)
}

// kbd_watch_start puts an inotify watch on the file's directory rather than
// on the file, because the usual way to replace a configuration file is to
// write a new one and rename it over the old, and a watch on the old inode
// would never hear about that.
kbd_watch_start :: proc() {
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	if err != .NONE {
		fmt.eprintfln("wm: keyboard: inotify unavailable (%v); changes are noticed within a second", err)
		kbd.ino = -1
		return
	}
	kbd.ino = fd
	dir := kbd_dir(kbd_conf_path())
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	if _, werr := linux.inotify_add_watch(fd, cdir, {.CLOSE_WRITE, .MOVED_TO, .DELETE, .MOVED_FROM}); werr != .NONE {
		// /etc/palm may not exist yet on a system that never had a keyboard
		// file. The once-a-second check covers that case.
		kbd.watched = false
		return
	}
	kbd.watched = true
}

kbd_dir :: proc(path: string) -> string {
	i := strings.last_index_byte(path, '/')
	switch {
	case i > 0:
		return path[:i]
	case i == 0:
		return "/"
	}
	return "."
}

kbd_base :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 {
		return path[i + 1:]
	}
	return path
}

// kbd_poll_fd is the inotify descriptor for the loop's poll set, or -1.
kbd_poll_fd :: proc() -> linux.Fd {
	return kbd.watched ? kbd.ino : -1
}

// kbd_drain_inotify reads every pending event and says whether one of them
// was about the keyboard file.
kbd_drain_inotify :: proc() -> bool {
	if !kbd.watched {
		return false
	}
	base := kbd_base(kbd_conf_path())
	hit := false
	buf: [4096]u8
	for {
		n, err := linux.read(kbd.ino, buf[:])
		if err != .NONE || n <= 0 {
			break
		}
		off := 0
		for off + size_of(linux.Inotify_Event) <= n {
			ev := (^linux.Inotify_Event)(&buf[off])
			name_len := int(ev.len)
			name := ""
			if name_len > 0 {
				raw := buf[off + size_of(linux.Inotify_Event):][:name_len]
				// The kernel pads the name with NULs to an aligned length.
				name = strings.truncate_to_byte(string(raw), 0)
			}
			if name == base || .Q_OVERFLOW in ev.mask {
				hit = true
			}
			off += size_of(linux.Inotify_Event) + name_len
		}
	}
	return hit
}

// kbd_reload re-reads the description and, when it changed or `force` says so
// (SIGHUP), installs it and tells every client.
kbd_reload :: proc(s: ^Server, why: string, force: bool) {
	choice := kbd_choose()
	kbd.sig = kbd_sig(kbd_conf_path())
	if !force && kbd_rmlvo_equal(choice.rmlvo, kbd.current) && choice.origin == kbd.origin {
		return
	}
	fmt.printfln("wm: keyboard: reloading (%s)", why)
	kbd_load(s, choice)
	n := kbd_broadcast(s)
	kbd.reloads += 1
	fmt.printfln("wm: keyboard: now %s, keymap sent to %d keyboard(s) of %d client(s)", kbd.label, n, len(s.clients))
	note(s, fmt.tprintf("keyboard: %s%s", kbd_describe(choice.rmlvo), kbd.fell_back ? " (unavailable, using us)" : ""))
	s.dirty = true
}

// kbd_pump is called once per loop iteration, after the input devices have
// been read and before the keys are handled.
kbd_pump :: proc(s: ^Server) {
	if kbd_hup_flag != 0 {
		kbd_hup_flag = 0
		kbd_drain_inotify()
		kbd_reload(s, "SIGHUP", true)
	} else if kbd_drain_inotify() {
		kbd_reload(s, fmt.tprintf("%s changed", kbd_conf_path()), false)
	} else if now := wall_now(); now - kbd.checked_at >= 1.0 {
		kbd.checked_at = now
		if !kbd.watched && kbd.ino > 0 && os.exists(kbd_dir(kbd_conf_path())) {
			// The directory has appeared since start-up: watch it from now on.
			cdir := strings.clone_to_cstring(kbd_dir(kbd_conf_path()), context.temp_allocator)
			if _, werr := linux.inotify_add_watch(kbd.ino, cdir, {.CLOSE_WRITE, .MOVED_TO, .DELETE, .MOVED_FROM}); werr == .NONE {
				kbd.watched = true
			}
		}
		if kbd_sig(kbd_conf_path()) != kbd.sig {
			kbd_reload(s, fmt.tprintf("%s changed", kbd_conf_path()), false)
		}
	}
	kbd_track_group(s)
}

// kbd_track_group follows a layout switch (grp:alt_shift_toggle and friends):
// the reverse table is rebuilt for the new group, and the next modifiers
// event carries it so the client resolves keycodes in the same group.
kbd_track_group :: proc(s: ^Server) {
	if !xkb_km.ok {
		return
	}
	g := u32(xkb_effective_group(&xkb_km, &xkb_st))
	if g == s.kt.group {
		return
	}
	text := s.kt.text
	s.kt.text = ""
	delete(s.kt.rev)
	source := s.kt.source
	s.kt = {}
	keytable_from_compiled(&s.kt, &xkb_km, int(g))
	delete(s.kt.text)
	s.kt.text = text
	s.kt.source = source
	delete(kbd.label)
	kbd.label = strings.clone(kbd_label(&xkb_km, int(g)))
	fmt.printfln("wm: keyboard: group %d (%s)", g + 1, kbd.label)
	note(s, fmt.tprintf("keyboard: %s", kbd.label))
	s.dirty = true
}

// ---------------------------------------------------------------------------
// Self test
//
// Runs on the host against the host's /usr/share/X11/xkb (or whatever
// XKB_CONFIG_ROOT says), with PALMY_WM_KEYBOARD_CONF pointed at a scratch
// file. No socket, no device, no signal is sent to anything.
// ---------------------------------------------------------------------------

kbd_test_pass, kbd_test_fail: int

kbd_check :: proc(ok: bool, format: string, args: ..any) {
	if ok {
		kbd_test_pass += 1
		fmt.printf("  ok    ")
	} else {
		kbd_test_fail += 1
		fmt.printf("  FAIL  ")
	}
	fmt.printf(format, ..args)
	fmt.println()
}

// kbd_sym_of is what the physical key `evdev_code` types in `km`, unshifted,
// in group `group`.
kbd_sym_of :: proc(km: ^Xkb_Keymap, evdev_code: u32, mods: u32 = 0, group := 0) -> u32 {
	sym, _, _ := xkb_lookup(km, evdev_code + EV_XKB_OFFSET, mods, group)
	return sym
}

kbd_selftest :: proc() -> int {
	fmt.println("keyboard self test")
	fmt.println()
	xkb_syms_init()

	fmt.println("parsing /etc/palm/keyboard")
	{
		c, probs := kbd_conf_parse("# chosen by the installer\nlayout = fr\nvariant =\noptions = grp:alt_shift_toggle, compose:ralt\n")
		kbd_check(c.layout == "fr", "layout = fr, got %q", c.layout)
		kbd_check(c.variant == "", "an empty variant is none, got %q", c.variant)
		kbd_check(c.options == "grp:alt_shift_toggle, compose:ralt", "options kept verbatim, got %q", c.options)
		kbd_check(len(probs) == 0, "no problems, got %v", probs)
		c2, p2 := kbd_conf_parse("Layout=\"de\"  # quoted\nVARIANT = 'nodeadkeys'\nbogus = 1\nno equals sign\n")
		kbd_check(c2.layout == "de" && c2.variant == "nodeadkeys", "quotes and case: got %q %q", c2.layout, c2.variant)
		kbd_check(len(p2) == 2, "an unknown key and a malformed line are both reported, got %d", len(p2))
		opts := kbd_split_options(" grp:alt_shift_toggle , ,compose:ralt")
		kbd_check(len(opts) == 2 && opts[0] == "grp:alt_shift_toggle" && opts[1] == "compose:ralt", "options split and trimmed, got %v", opts)
	}

	have_xkb := os.exists(fmt.tprintf("%s/symbols/fr", xkb_root()))
	scratch := fmt.tprintf("/tmp/palmy-wm-kbd-selftest-%d", linux.getpid())
	conf := fmt.tprintf("%s/keyboard", scratch)
	linux.mkdir(strings.clone_to_cstring(scratch, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	defer {
		linux.unlink(strings.clone_to_cstring(conf, context.temp_allocator))
		linux.rmdir(strings.clone_to_cstring(scratch, context.temp_allocator))
	}
	saved_env: [5]string
	env_names := [5]string{"XKB_DEFAULT_LAYOUT", "XKB_DEFAULT_VARIANT", "XKB_DEFAULT_OPTIONS", "XKB_DEFAULT_MODEL", "XKB_DEFAULT_RULES"}
	for n, i in env_names {
		saved_env[i] = strings.clone(os.get_env(n, context.temp_allocator))
		os.unset_env(n)
	}
	saved_conf := strings.clone(os.get_env("PALMY_WM_KEYBOARD_CONF", context.temp_allocator))
	os.set_env("PALMY_WM_KEYBOARD_CONF", conf)
	defer {
		for n, i in env_names {
			if saved_env[i] != "" {os.set_env(n, saved_env[i])} else {os.unset_env(n)}
		}
		if saved_conf != "" {os.set_env("PALMY_WM_KEYBOARD_CONF", saved_conf)} else {os.unset_env("PALMY_WM_KEYBOARD_CONF")}
	}
	write :: proc(path, text: string) {
		_ = os.write_entire_file(path, transmute([]u8)text)
	}

	fmt.println("precedence")
	{
		write(conf, "layout = fr\nvariant = bepo\noptions = grp:alt_shift_toggle\n")
		ch := kbd_choose()
		kbd_check(ch.rmlvo.layout == "fr" && ch.rmlvo.variant == "bepo", "the file decides: %s", kbd_describe(ch.rmlvo))
		kbd_check(len(ch.rmlvo.options) == 1, "with its options")
		kbd_check(ch.origin == conf, "and says so: %q", ch.origin)

		os.set_env("XKB_DEFAULT_LAYOUT", "de")
		ch = kbd_choose()
		kbd_check(ch.rmlvo.layout == "de" && ch.rmlvo.variant == "", "XKB_DEFAULT_LAYOUT wins and drops the file's variant: %s", kbd_describe(ch.rmlvo))
		kbd_check(len(ch.rmlvo.options) == 1, "the file's options still apply")
		kbd_check(strings.contains(ch.origin, "XKB_DEFAULT_LAYOUT"), "origin names the override: %q", ch.origin)
		os.set_env("XKB_DEFAULT_VARIANT", "nodeadkeys")
		ch = kbd_choose()
		kbd_check(ch.rmlvo.layout == "de" && ch.rmlvo.variant == "nodeadkeys", "XKB_DEFAULT_VARIANT goes with it: %s", kbd_describe(ch.rmlvo))
		os.unset_env("XKB_DEFAULT_LAYOUT")
		ch = kbd_choose()
		kbd_check(ch.rmlvo.layout == "fr" && ch.rmlvo.variant == "nodeadkeys", "alone it applies to the file's layout: %s", kbd_describe(ch.rmlvo))
		os.unset_env("XKB_DEFAULT_VARIANT")
		os.set_env("XKB_DEFAULT_OPTIONS", "caps:escape")
		ch = kbd_choose()
		kbd_check(len(ch.rmlvo.options) == 1 && ch.rmlvo.options[0] == "caps:escape", "XKB_DEFAULT_OPTIONS replaces the options: %v", ch.rmlvo.options)
		os.unset_env("XKB_DEFAULT_OPTIONS")
	}

	fmt.println("validation")
	{
		kbd_check(kbd_validate({layout = "../../etc/passwd"}) != "", "a path is not a layout name")
		kbd_check(kbd_validate({layout = "us,fr,de,ru,gb"}) != "", "five layouts are more than XKB has groups")
		if have_xkb {
			kbd_check(kbd_validate({layout = "fr"}) == "", "fr exists")
			kbd_check(kbd_validate({layout = "fr", variant = "bepo"}) == "", "fr(bepo) exists")
			kbd_check(kbd_validate({layout = "xx"}) != "", "xx does not: %q", kbd_validate({layout = "xx"}))
			kbd_check(kbd_validate({layout = "fr", variant = "nosuch"}) != "", "nor does fr(nosuch): %q", kbd_validate({layout = "fr", variant = "nosuch"}))
			kbd_check(kbd_validate({layout = "us,ru", variant = ",phonetic"}) == "", "us,ru(phonetic) is two valid groups")
		}
	}

	if !have_xkb {
		fmt.printfln("  (skipping the compile checks: no %s/symbols/fr)", xkb_root())
	} else {
		fmt.println("compiling, and the fallback")
		{
			km, why := kbd_compile({layout = "fr"})
			kbd_check(why == "", "fr compiles without falling back, got %q", why)
			kbd_check(kbd_sym_of(&km, 16) == 'a' && kbd_sym_of(&km, 17) == 'z', "AZERTY: physical q types a, w types z")
			kbd_check(kbd_sym_of(&km, 30) == 'q' && kbd_sym_of(&km, 44) == 'w', "and a types q, z types w")
			kbd_check(strings.contains(km.text, "xkb_symbols"), "the text for clients is there")

			km2, why2 := kbd_compile({layout = "xx"})
			kbd_check(why2 != "", "xx falls back, saying why: %q", why2)
			kbd_check(km2.ok && kbd_sym_of(&km2, 16) == 'q', "to a US keymap that types q")

			km3, why3 := kbd_compile({layout = "fr", variant = "nosuch"})
			kbd_check(why3 != "" && kbd_sym_of(&km3, 16) == 'q', "a missing variant falls back too: %q", why3)

			km4, _ := kbd_compile({layout = "de"})
			kbd_check(kbd_sym_of(&km4, 21) == 'z' && kbd_sym_of(&km4, 44) == 'y', "de: y and z swap")
		}

		fmt.println("the reverse table: AltGr, Caps Lock and groups")
		{
			km, _ := kbd_compile({layout = "de"})
			kt: Key_Table
			keytable_from_compiled(&kt, &km)
			at, ok := keycode_for(&kt, '@')
			kbd_check(ok && at.code == 16 && at.level3 && !at.shift, "de: @ is AltGr+Q (code 16, level 3), got %v %v", ok, at)
			kbd_check(kt.m_level3 != XKB_MOD_INVALID && kt.m_level3 < 8, "LevelThree is a real modifier bit, got %d", kt.m_level3)
			big, bok := keycode_for(&kt, 'Z')
			kbd_check(bok && big.code == 21 && big.shift && big.lock_ok, "Z is Shift+Y-key, and Caps Lock alone also gives it: %v", big)
			excl, eok := keycode_for(&kt, '!')
			kbd_check(eok && excl.shift && !excl.lock_ok, "! needs Shift even with Caps Lock: %v", excl)
			delete(kt.rev)
			delete(kt.text)

			km2, why := kbd_compile({layout = "us,ru", options = {"grp:alt_shift_toggle"}})
			kbd_check(why == "" && km2.ngroups == 2, "us,ru is two groups, got %d (%q)", km2.ngroups, why)
			kt2: Key_Table
			keytable_from_compiled(&kt2, &km2, 1)
			kbd_check(kt2.group == 1, "a table for group two")
			cyr, cok := keycode_for(&kt2, 0x6ca) // Cyrillic_shorti, on Q in ru
			kbd_check(cok && cyr.code == 16, "finds й on Q, got %v %v", cok, cyr)
			delete(kt2.rev)
			delete(kt2.text)

			// The toggle itself, through the state machine: Shift held, then Alt.
			saved := xkb_km
			saved_st := xkb_st
			xkb_km = km2
			xkb_sort_km = &xkb_km
			xkb_state_reset()
			xkb_update_key(42, true) // LEFTSHIFT
			xkb_update_key(56, true) // LEFTALT
			xkb_update_key(56, false)
			xkb_update_key(42, false)
			kbd_check(xkb_effective_group(&xkb_km, &xkb_st) == 1, "Shift+Alt switches to group two, got %d", xkb_effective_group(&xkb_km, &xkb_st))
			xkb_update_key(56, true)
			xkb_update_key(42, true)
			xkb_update_key(42, false)
			xkb_update_key(56, false)
			kbd_check(xkb_effective_group(&xkb_km, &xkb_st) == 0, "Alt+Shift switches back, got %d", xkb_effective_group(&xkb_km, &xkb_st))
			xkb_update_key(42, true)
			xkb_update_key(42, false)
			kbd_check(xkb_effective_group(&xkb_km, &xkb_st) == 0, "Shift alone does nothing")
			xkb_km = saved
			xkb_st = saved_st
			xkb_sort_km = &xkb_km
		}

		fmt.println("live reload, end to end over a fake client")
		{
			s := new(Server)
			defer free(s)
			write(conf, "layout = fr\n")
			kbd_load(s, kbd_choose())
			kbd_check(kbd.label == "fr" && !kbd.fell_back, "loaded fr from the file, label %q", kbd.label)
			fd1 := s.keymap_fd
			kbd_check(fd1 > 0 && s.keymap_size > 1000, "published as a memfd of %d bytes", s.keymap_size)
			a_rev, _ := keycode_for(&s.kt, 'a')
			kbd_check(a_rev.code == 16, "the compositor's table: a is on physical Q, got %d", a_rev.code)

			// A client on the other end of a real socket, so the descriptors
			// travel the way they do to a palmy client.
			pair: [2]linux.Fd
			kbd_check(linux.socketpair(.UNIX, .STREAM, linux.Protocol(0), &pair) == .NONE, "a socketpair for the fake client")
			c := new(Client)
			c.fd = pair[0]
			c.objs = make(map[u32]Object)
			append(&c.keyboards, 7, 9)
			append(&s.clients, c)
			surf := new(Surface)
			surf.client = c
			s.kbd_surf = surf

			// What the client received since the last call: message ops and
			// target ids in order, and how many descriptors came with them.
			Rx :: struct {
				ops, ids: [dynamic]u32,
				fds:      int,
			}
			receive :: proc(c: ^Client, fd: linux.Fd) -> (rx: Rx) {
				client_flush(c)
				rx.ops = make([dynamic]u32, context.temp_allocator)
				rx.ids = make([dynamic]u32, context.temp_allocator)
				bytes := make([dynamic]u8, context.temp_allocator)
				for {
					buf: [8192]u8
					ctrl: [256]u8
					iov := [1]linux.IO_Vec{{base = &buf[0], len = len(buf)}}
					hdr := linux.Msg_Hdr {
						iov     = iov[:],
						control = ctrl[:],
					}
					n, err := linux.recvmsg(fd, &hdr, {.DONTWAIT})
					if err != .NONE || n <= 0 {
						break
					}
					append(&bytes, ..buf[:n])
					// One SCM_RIGHTS block per sendmsg; count and close.
					if clen := len(hdr.control); clen >= size_of(Cmsg_Hdr) {
						ch := (^Cmsg_Hdr)(&ctrl[0])
						k := (int(ch.len) - size_of(Cmsg_Hdr)) / 4
						for i in 0 ..< k {
							got := (^i32)(&ctrl[size_of(Cmsg_Hdr) + i * 4])^
							linux.close(linux.Fd(got))
						}
						rx.fds += k
					}
				}
				// Wire format: object id, (size << 16 | opcode), then the args.
				for off := 0; off + 8 <= len(bytes); {
					append(&rx.ids, (^u32)(&bytes[off])^)
					hdr := (^u32)(&bytes[off + 4])^
					append(&rx.ops, hdr & 0xffff)
					off += max(int(hdr >> 16), 8)
				}
				return
			}

			// SIGHUP is a flag the handler sets; exercise it the same way.
			write(conf, "layout = de\n")
			kbd_hup_flag = 1
			kbd.watched = false
			kbd_pump(s)
			kbd_check(kbd.label == "de", "SIGHUP reloads: now %q", kbd.label)
			kbd_check(s.keymap_fd > 0 && s.keymap_fd != fd1, "a new keymap fd (%d, was %d)", s.keymap_fd, fd1)
			y_rev, _ := keycode_for(&s.kt, 'y')
			kbd_check(y_rev.code == 44, "the table follows: y is on physical Z, got %d", y_rev.code)
			rx := receive(c, pair[1])
			kbd_check(!c.dead, "the client is still alive")
			kbd_check(rx.fds == 2, "one keymap fd per wl_keyboard, got %d", rx.fds)
			kbd_check(len(rx.ops) == 4 && rx.ops[0] == 0 && rx.ops[1] == 0 && rx.ops[2] == 4 && rx.ops[3] == 4, "keymap, keymap, then modifiers to the focused client: ops %v", rx.ops[:])
			kbd_check(len(rx.ids) == 4 && rx.ids[0] == 7 && rx.ids[1] == 9, "to both keyboards: ids %v", rx.ids[:])

			// Unchanged content is not news; a changed file is, without a signal.
			kbd.checked_at = -10
			kbd_pump(s)
			rx = receive(c, pair[1])
			kbd_check(len(rx.ops) == 0, "nothing re-sent while the file is unchanged, got %v", rx.ops[:])
			write(conf, "layout = fr\n# touched\n")
			kbd.sig = {}
			kbd.checked_at = -10
			kbd_pump(s)
			rx = receive(c, pair[1])
			kbd_check(kbd.label == "fr" && rx.fds == 2, "the once-a-second check notices a rewrite: %q, %d fds", kbd.label, rx.fds)

			// inotify, for real, on the scratch directory.
			kbd.ino = -1
			kbd.watched = false
			kbd_watch_start()
			kbd_check(kbd.watched, "inotify watches %s", scratch)
			tmp := fmt.tprintf("%s/.keyboard.new", scratch)
			write(tmp, "layout = de\n")
			linux.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(conf, context.temp_allocator))
			kbd.checked_at = wall_now() + 100 // the timer must not be what notices
			kbd_pump(s)
			rx = receive(c, pair[1])
			kbd_check(kbd.label == "de" && rx.fds == 2, "a rename over the file is noticed at once: %q, %d fds", kbd.label, rx.fds)

			write(conf, "layout = nonexistent\n")
			kbd_pump(s)
			rx = receive(c, pair[1])
			kbd_check(kbd.fell_back && kbd.label == "us" && rx.fds == 2, "a bad layout falls back to us and is still sent, label %q", kbd.label)
			us_q, _ := keycode_for(&s.kt, 'q')
			kbd_check(us_q.code == 16, "and q is where it is on a US keyboard")

			// A layout switch inside a two-layout keymap reaches the client
			// as the group in wl_keyboard.modifiers.
			write(conf, "layout = us,ru\noptions = grp:alt_shift_toggle\n")
			kbd_pump(s)
			receive(c, pair[1])
			kbd_check(kbd.label == "us" && xkb_km.ngroups == 2, "us,ru loaded: %q, %d groups", kbd.label, xkb_km.ngroups)
			xkb_st.locked_group = 1
			kbd_pump(s)
			kbd_check(kbd.label == "ru" && s.kt.group == 1, "a group switch is followed: %q, group %d", kbd.label, s.kt.group)
			send_mods(s, s.mod_mask)
			rx = receive(c, pair[1])
			kbd_check(len(rx.ops) == 2 && rx.ops[0] == 4, "and announced in a modifiers event per keyboard: %v", rx.ops[:])
			xkb_state_reset()

			linux.close(pair[0])
			linux.close(pair[1])
			linux.close(kbd.ino)
			kbd.ino = -1
			kbd.watched = false
			pop(&s.clients)
			linux.close(s.keymap_fd)
		}
	}

	fmt.println()
	fmt.printf("keyboard: %d passed, %d failed\n", kbd_test_pass, kbd_test_fail)
	return kbd_test_fail
}

// `wm --kbd-selftest` runs this file's checks and clock.odin's, and exits
// before main: no socket, no device. Hooked in through @(init) the way
// evdev.odin hooks --input-selftest.
@(init)
kbd_init_flags :: proc "contextless" () {
	context = runtime.default_context()
	for a in os.args {
		if a == "--kbd-selftest" {
			fail := kbd_selftest()
			fmt.println()
			fail += clock_selftest()
			os.exit(fail == 0 ? 0 : 1)
		}
	}
}
