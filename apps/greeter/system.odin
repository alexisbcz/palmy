package main

// Everything the greeter reads off the real machine: the accounts that can log
// in, the sessions that can be started, the hostname, and the power actions.
//
// The power actions are inert everywhere except one place: the installed
// login screen of Palmy, under palm-login. See `power_request`.

import "core:encoding/json"
import "core:fmt"
import kit "kit:."
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import p "palmy:."

// ---------------------------------------------------------------------------
// Accounts
// ---------------------------------------------------------------------------

User :: struct {
	name:     string, // the login name, what create_session gets
	real:     string, // the GECOS full name, or the login name again
	uid:      int,
	home:     string,
	shell:    string,
	initials: string,
	synthetic: bool, // added by --demo-users, never a real account
}

UID_MIN :: 1000
UID_MAX :: 60000

// A login shell that cannot start a session. Accounts using one of these are
// service accounts even if their uid falls in the human range.
NON_LOGIN_SHELLS := [?]string {
	"/usr/bin/nologin",
	"/sbin/nologin",
	"/usr/sbin/nologin",
	"/bin/false",
	"/usr/bin/false",
	"/bin/sync",
	"/sbin/shutdown",
	"/sbin/halt",
	"",
}

// read_users parses /etc/passwd the way a login manager has to: uid in
// 1000..60000 and a shell that can actually run a session.
read_users :: proc() -> []User {
	out := make([dynamic]User)

	data, rerr := os.read_entire_file_from_path("/etc/passwd", context.allocator)
	if rerr != nil {
		return out[:]
	}
	defer delete(data)

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") {
			continue
		}
		f := strings.split(l, ":")
		defer delete(f)
		if len(f) < 7 {
			continue
		}
		uid, uid_ok := strconv.parse_int(f[2])
		if !uid_ok || uid < UID_MIN || uid > UID_MAX {
			continue
		}
		shell := f[6]
		if slice.contains(NON_LOGIN_SHELLS[:], shell) {
			continue
		}
		if strings.has_suffix(shell, "/nologin") || strings.has_suffix(shell, "/false") {
			continue
		}

		name := strings.clone(f[0])
		// GECOS is comma separated; the first field is the full name.
		gecos := f[4]
		if c := strings.index_byte(gecos, ','); c >= 0 {
			gecos = gecos[:c]
		}
		gecos = strings.trim_space(gecos)

		u := User {
			name  = name,
			real  = gecos == "" ? name : strings.clone(gecos),
			uid   = uid,
			home  = strings.clone(f[5]),
			shell = strings.clone(shell),
		}
		u.initials = initials_of(u.real)
		append(&out, u)
	}

	slice.sort_by(out[:], proc(a, b: User) -> bool {return a.uid < b.uid})
	return out[:]
}

initials_of :: proc(name: string) -> string {
	parts := strings.fields(name)
	defer delete(parts)
	sb := strings.builder_make()
	for part, i in parts {
		if i >= 2 {
			break
		}
		if len(part) > 0 {
			strings.write_byte(&sb, u8_upper(part[0]))
		}
	}
	if strings.builder_len(sb) == 0 && len(name) > 0 {
		strings.write_byte(&sb, u8_upper(name[0]))
	}
	return strings.to_string(sb)
}

u8_upper :: proc(c: u8) -> u8 {
	return c >= 'a' && c <= 'z' ? c - 32 : c
}

// ---------------------------------------------------------------------------
// Sessions
// ---------------------------------------------------------------------------

Session_Kind :: enum u8 {
	Wayland,
	X11,
	Shell,
}

Session :: struct {
	name:    string, // Name=
	comment: string, // Comment=
	exec:    string, // Exec=
	desktop: string, // DesktopNames=, for XDG_CURRENT_DESKTOP
	kind:    Session_Kind,
	path:    string, // the .desktop file it came from, or "" for the fallback
}

WAYLAND_SESSION_DIRS := [?]string{"/usr/share/wayland-sessions", "/usr/local/share/wayland-sessions"}
X11_SESSION_DIRS := [?]string{"/usr/share/xsessions", "/usr/local/share/xsessions"}

// PALMY_SESSION is the session Palmy's login screen offers first: the
// palmy window manager on the bare-metal backend. It is built in rather than
// read from a .desktop file so the login screen can never come up with
// nothing to start, whatever the image did or did not install.
PALMY_SESSION :: Session {
	name    = "Palmy",
	comment = "The palmy window manager",
	exec    = "wm --drm",
	desktop = "palmy",
	kind    = .Wayland,
}

// read_sessions reads the real session desktop entries.
//
// Under palm-login the built-in Palmy session comes first (unless an
// installed entry already starts `wm`), and there is no shell fallback: a
// palm-login session has no terminal to put a shell on, so offering one would
// only bounce straight back to this screen. Everywhere else a shell fallback
// is appended so there is something to start on a machine with none.
read_sessions :: proc() -> []Session {
	out := make([dynamic]Session)
	for dir in WAYLAND_SESSION_DIRS {
		scan_session_dir(&out, dir, .Wayland)
	}
	for dir in X11_SESSION_DIRS {
		scan_session_dir(&out, dir, .X11)
	}
	slice.sort_by(out[:], proc(a, b: Session) -> bool {
		if a.kind != b.kind {
			return a.kind < b.kind
		}
		return a.name < b.name
	})
	if under_palm_login() {
		if default_session(out[:]) < 0 {
			inject_at(&out, 0, PALMY_SESSION)
		}
		return out[:]
	}
	append(
		&out,
		Session {
			name = "Shell",
			comment = "A login shell on this surface's tty",
			exec = "bash -l",
			kind = .Shell,
		},
	)
	return out[:]
}

// default_session is the entry selected when the screen opens: the first one
// that starts the palmy window manager, or -1 when there is none.
default_session :: proc(sessions: []Session) -> int {
	for s, i in sessions {
		words := strings.fields(s.exec, context.temp_allocator)
		if len(words) == 0 {
			continue
		}
		exe := words[0]
		if slash := strings.last_index_byte(exe, '/'); slash >= 0 {
			exe = exe[slash + 1:]
		}
		if exe == "wm" {
			return i
		}
	}
	return -1
}

@(private = "file")
scan_session_dir :: proc(out: ^[dynamic]Session, dir: string, kind: Session_Kind) {
	fd, err := os.open(dir)
	if err != nil {
		return
	}
	defer os.close(fd)

	entries, derr := os.read_dir(fd, -1, context.allocator)
	if derr != nil {
		return
	}
	defer delete(entries)

	for e in entries {
		if !strings.has_suffix(e.name, ".desktop") {
			continue
		}
		if s, ok := parse_desktop(e.fullpath, kind); ok {
			append(out, s)
		}
	}
}

// parse_desktop reads the [Desktop Entry] group of a freedesktop entry. Only
// the keys a session needs, and the unlocalised ones: `Name[de]` is ignored.
@(private = "file")
parse_desktop :: proc(path: string, kind: Session_Kind) -> (s: Session, ok: bool) {
	data, rerr := os.read_entire_file_from_path(path, context.allocator)
	if rerr != nil {
		return {}, false
	}
	defer delete(data)

	in_entry := false
	hidden := false
	name, comment, exec, desktop, try_exec: string

	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") {
			continue
		}
		if strings.has_prefix(l, "[") {
			in_entry = l == "[Desktop Entry]"
			continue
		}
		if !in_entry {
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(l[:eq])
		val := strings.trim_space(l[eq + 1:])
		switch key {
		case "Name":
			name = val
		case "Comment":
			comment = val
		case "Exec":
			exec = val
		case "TryExec":
			try_exec = val
		case "DesktopNames":
			desktop = val
		case "Hidden", "NoDisplay":
			if val == "true" {
				hidden = true
			}
		}
	}

	if hidden || name == "" || exec == "" {
		return {}, false
	}
	if try_exec != "" && strings.contains(try_exec, "/") {
		if !os.exists(try_exec) {
			return {}, false
		}
	}

	return Session {
			name = strings.clone(name),
			comment = strings.clone(comment),
			exec = strings.clone(exec),
			desktop = strings.clone(desktop),
			kind = kind,
			path = strings.clone(path),
		},
		true
}

session_kind_label :: proc(k: Session_Kind) -> string {
	switch k {
	case .Wayland:
		return "wayland"
	case .X11:
		return "x11"
	case .Shell:
		return "tty"
	}
	return "?"
}

// session_cmd is the argv handed to start_session. An X11 entry is wrapped in
// `startx`, which is how greetd's own documentation starts an X session.
session_cmd :: proc(s: Session, allocator := context.allocator) -> []string {
	argv := make([dynamic]string, allocator)
	if s.kind == .X11 {
		append(&argv, strings.clone("startx", allocator))
		append(&argv, strings.clone("/usr/bin/X", allocator))
	}
	// Exec in a session entry is a plain command line; the %f/%U field codes
	// that application entries use do not apply, so splitting on whitespace is
	// the whole of it.
	for word in strings.fields(s.exec) {
		append(&argv, strings.clone(word, allocator))
	}
	return argv[:]
}

// session_env is the environment added on top of the one PAM built.
session_env :: proc(s: Session, u: User, allocator := context.allocator) -> []string {
	env := make([dynamic]string, allocator)
	append(&env, fmt.aprintf("XDG_SESSION_TYPE=%s", session_kind_label(s.kind), allocator = allocator))
	if s.desktop != "" {
		append(&env, fmt.aprintf("XDG_CURRENT_DESKTOP=%s", s.desktop, allocator = allocator))
		append(&env, fmt.aprintf("XDG_SESSION_DESKTOP=%s", s.desktop, allocator = allocator))
	}
	if s.path != "" {
		append(&env, fmt.aprintf("GREETER_SESSION_FILE=%s", s.path, allocator = allocator))
	}
	append(&env, fmt.aprintf("SHELL=%s", u.shell, allocator = allocator))
	return env[:]
}

// ---------------------------------------------------------------------------
// The machine
// ---------------------------------------------------------------------------

read_hostname :: proc() -> string {
	if data, rerr := os.read_entire_file_from_path("/etc/hostname", context.allocator); rerr == nil {
		defer delete(data)
		h := strings.trim_space(string(data))
		if h != "" {
			return strings.clone(h)
		}
	}
	if h := os.get_env("HOSTNAME", context.allocator); h != "" {
		return h
	}
	return "localhost"
}

// local_zone loads the machine's time zone the way glibc finds it: TZ when it
// is set (palm-login exports it only when /etc/localtime is missing and
// /etc/timezone names a zone), otherwise /etc/localtime itself — a TZif file,
// on Palmy a symlink into /usr/share/zoneinfo that the installer points
// at the zone picked. It used to ask `date +%z` once at start, which missed a
// daylight-saving change while the screen stayed up and depended on a
// `date` that reads the zone the same way. nil means UTC, which is also the
// answer when nothing can be read.
local_zone :: proc() -> ^datetime.TZ_Region {
	if tz := os.get_env("TZ", context.temp_allocator); tz != "" {
		name := strings.trim_prefix(tz, ":")
		if strings.has_prefix(name, "/") {
			if reg, ok := timezone.region_load_from_file(name, name); ok {
				return reg
			}
		} else if reg, ok := timezone.region_load(name); ok {
			return reg // nil for "UTC", which is right
		}
	}
	if reg, ok := timezone.region_load_from_file("/etc/localtime", "localtime"); ok {
		return reg
	}
	return nil
}

// zone_offset is how far `zone`'s wall clock is ahead of UTC at instant t.
zone_offset :: proc(zone: ^datetime.TZ_Region, t: time.Time) -> time.Duration {
	if zone == nil {
		return 0
	}
	utc, ok := time.time_to_datetime(t)
	if !ok {
		return 0
	}
	local, lok := timezone.datetime_to_tz(utc, zone)
	if !lok {
		return 0
	}
	local.tz = nil
	wall, wok := time.datetime_to_time(local)
	if !wok {
		return 0
	}
	return time.diff(t, wall)
}

// ---------------------------------------------------------------------------
// Power actions
// ---------------------------------------------------------------------------

Power :: enum u8 {
	Suspend,
	Reboot,
	Shutdown,
}

// under_palm_login reports whether this greeter is Palmy's installed login
// screen. palm-login sets both variables for the greeter session it starts;
// a greeter run by hand on a development machine — even one pointed at a real
// greetd, which sets only GREETD_SOCK — keeps its power buttons inert.
under_palm_login :: proc() -> bool {
	return os.get_env("GREETD_SOCK", context.temp_allocator) != "" &&
		os.get_env("PALM_LOGIN", context.temp_allocator) == "1"
}

power_label :: proc(pw: Power) -> string {
	switch pw {
	case .Suspend:
		return kit.tr("Suspend")
	case .Reboot:
		return kit.tr("Restart")
	case .Shutdown:
		return kit.tr("Shut Down")
	}
	return "?"
}

power_icon :: proc(pw: Power) -> p.Icon {
	switch pw {
	case .Suspend:
		return GI_MOON
	case .Reboot:
		return GI_ROTATE_CCW
	case .Shutdown:
		return GI_POWER
	}
	return GI_POWER
}

// power_available is false for an action this machine cannot carry out, so
// its button is not offered at all. That is only ever Suspend under
// palm-login: Palmy has no suspend path yet. A stub greeter keeps all
// three, since none of them do anything there.
power_available :: proc(pw: Power) -> bool {
	return !(pw == .Suspend && under_palm_login())
}

// power_command is what the action means on this machine: busybox's
// /sbin/poweroff and /sbin/reboot under palm-login, the systemd verbs a
// greeter elsewhere would use.
power_command :: proc(pw: Power) -> string {
	if under_palm_login() {
		switch pw {
		case .Suspend:
			return "" // Palmy has no suspend path yet
		case .Reboot:
			return "/sbin/reboot"
		case .Shutdown:
			return "/sbin/poweroff"
		}
		return ""
	}
	switch pw {
	case .Suspend:
		return "systemctl suspend"
	case .Reboot:
		return "systemctl reboot"
	case .Shutdown:
		return "systemctl poweroff"
	}
	return ""
}

// power_request carries out a power action and returns the line to show.
//
// Anywhere but under palm-login it is a stub: it logs the intent and nothing
// is spawned, no dbus call is made, and the machine is not touched.
//
// Under palm-login the action is real, but the greeter does not run
// /sbin/poweroff itself: busybox's poweroff is a kill(2) of PID 1, which the
// unprivileged `greeter` account is not allowed to send. palm-login, which is
// root, runs it on the greeter's behalf when asked with a `power` request — an
// extension to the greetd protocol that only palm-login understands, sent on a
// connection of its own so it never disturbs a login in progress.
power_request :: proc(pw: Power, sock: string) -> string {
	cmd := power_command(pw)
	if !under_palm_login() {
		msg := fmt.aprintf(kit.tr("power: would run `%s` (stub — nothing executed)"), cmd)
		fmt.eprintfln("greeter: %s", msg)
		return msg
	}
	if cmd == "" {
		return fmt.aprintf(kit.tr("%s is not available on this machine"), power_label(pw))
	}

	c: Client
	if e := client_connect(&c, sock); e != "" {
		return fmt.aprintf(kit.tr("power: %s"), e)
	}
	defer client_close(&c)
	if e := send(&c, req_power(pw == .Shutdown ? "poweroff" : "reboot", context.temp_allocator)); e != "" {
		return fmt.aprintf(kit.tr("power: %s"), e)
	}
	if !readable(&c, 3000) {
		return kit.tr("power: palm-login did not answer")
	}
	r, e := recv(&c)
	if e != "" {
		return fmt.aprintf(kit.tr("power: %s"), e)
	}
	if r.kind != .Success {
		return fmt.aprintf(kit.tr("power: %s"), r.description == "" ? kit.tr("refused") : kit.tr(r.description))
	}
	return pw == .Shutdown ? kit.tr("Shutting down…") : kit.tr("Restarting…")
}

// ---------------------------------------------------------------------------
// The output to cover
// ---------------------------------------------------------------------------

// detect_output_size measures the output this greeter will cover.
//
// A wlr-layer-shell surface anchored to all four edges fills the output when
// it requests a size of 0x0, but palmy clamps a zero size up to 960x640 before
// asking, so the size has to be requested explicitly. The compositor is asked
// through whatever control tool it ships; the fallback is 1080p.
detect_output_size :: proc() -> (w: int, h: int) {
	if under_palm_login() {
		// Palmy's wm sizes a zero-sized layer surface anchored to all
		// four edges to the output it is on — whatever that output is in a
		// QEMU window or on real hardware — and palmy now passes 0 through.
		// There is no swaymsg or hyprctl to ask there anyway.
		return 0, 0
	}
	if out, ok := kit.run({"swaymsg", "-t", "get_outputs", "-r"}, context.temp_allocator); ok {
		if ww, hh, found := first_rect(out, "rect"); found {
			return ww, hh
		}
	}
	if out, ok := kit.run({"hyprctl", "monitors", "-j"}, context.temp_allocator); ok {
		if ww, hh, found := hypr_first_monitor(out); found {
			return ww, hh
		}
	}
	return 1920, 1080
}

@(private = "file")
first_rect :: proc(doc: string, key: string) -> (w, h: int, ok: bool) {
	v, err := json.parse(transmute([]u8)doc, .JSON, true, context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr || len(arr) == 0 {
		return 0, 0, false
	}
	for e in arr {
		obj, is_obj := e.(json.Object)
		if !is_obj {
			continue
		}
		if act, has := obj["active"]; has {
			if b, is_b := act.(json.Boolean); is_b && !bool(b) {
				continue
			}
		}
		rect, has_rect := obj[key]
		if !has_rect {
			continue
		}
		ro, is_ro := rect.(json.Object)
		if !is_ro {
			continue
		}
		ww := jnum(ro, "width")
		hh := jnum(ro, "height")
		if ww > 0 && hh > 0 {
			return int(ww), int(hh), true
		}
	}
	return 0, 0, false
}

@(private = "file")
hypr_first_monitor :: proc(doc: string) -> (w, h: int, ok: bool) {
	v, err := json.parse(transmute([]u8)doc, .JSON, true, context.temp_allocator)
	if err != nil {
		return 0, 0, false
	}
	arr, is_arr := v.(json.Array)
	if !is_arr {
		return 0, 0, false
	}
	for e in arr {
		obj, is_obj := e.(json.Object)
		if !is_obj {
			continue
		}
		if dis, has := obj["disabled"]; has {
			if b, is_b := dis.(json.Boolean); is_b && bool(b) {
				continue
			}
		}
		ww := jnum(obj, "width")
		hh := jnum(obj, "height")
		scale := jnum(obj, "scale")
		if scale <= 0 {
			scale = 1
		}
		// palmy works in logical pixels and follows the output scale itself.
		if ww > 0 && hh > 0 {
			return int(ww / scale), int(hh / scale), true
		}
	}
	return 0, 0, false
}

@(private = "file")
jnum :: proc(obj: json.Object, key: string) -> f64 {
	if v, ok := obj[key]; ok {
		switch n in v {
		case json.Integer:
			return f64(n)
		case json.Float:
			return f64(n)
		case json.Null, json.Boolean, json.String, json.Array, json.Object:
			return 0
		}
	}
	return 0
}
