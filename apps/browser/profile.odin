// Profiles: one per Palmframe identity.
//
// The README's identity model says each sub-identity has its own browsing
// state, and the way to hold that line is to make it a directory boundary
// rather than a setting: everything a profile owns -- the engine's cookies,
// cache and local storage, the bookmarks, the history, the settings, the
// session -- lives under one directory named for the identity, and the engine
// host is started with that directory and nothing else. Work cookies cannot
// reach a personal tab because the process rendering the personal tab was
// never told where the work profile is.
//
//   $XDG_DATA_HOME/palmframe/browser/<identity>/
//     settings.json      engine choice, search, theme, ...
//     bookmarks.json     sync-ready: UUIDs, per-field clocks, tombstones
//     history.jsonl      append-only visits
//     downloads.json     what was downloaded, and where it went
//     session.json       the open tabs, for the next start
//     cef/               Chromium's profile (cookies, cache, storage)
//     gecko/             Firefox's profile
//
// $PALM_BROWSER_HOME replaces the parent directory, which is how the tests
// and the screenshots keep away from a person's real profile.
package browser

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

DEFAULT_IDENTITY :: "personal"

Engine_Kind :: enum u8 {
	Chromium,
	Firefox,
}

engine_name :: proc(k: Engine_Kind) -> string {
	return k == .Chromium ? "chromium" : "firefox"
}

engine_label :: proc(k: Engine_Kind) -> string {
	return k == .Chromium ? "Chromium" : "Firefox"
}

engine_parse :: proc(s: string) -> (k: Engine_Kind, ok: bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "chromium", "chrome", "blink", "cef":
		return .Chromium, true
	case "firefox", "gecko":
		return .Firefox, true
	}
	return .Chromium, false
}

Theme :: enum u8 {
	System,
	Light,
	Dark,
}

Search_Engine :: struct {
	id:    string,
	name:  string,
	query: string, // %s is replaced by the escaped terms
	home:  string,
}

SEARCH_ENGINES := [?]Search_Engine {
	{"duckduckgo", "DuckDuckGo", "https://duckduckgo.com/?q=%s", "https://duckduckgo.com"},
	{"startpage", "Startpage", "https://www.startpage.com/do/search?q=%s", "https://www.startpage.com"},
	{"brave", "Brave Search", "https://search.brave.com/search?q=%s", "https://search.brave.com"},
	{"google", "Google", "https://www.google.com/search?q=%s", "https://www.google.com"},
	{"wikipedia", "Wikipedia", "https://en.wikipedia.org/w/index.php?search=%s", "https://en.wikipedia.org"},
}

search_engine :: proc(id: string) -> Search_Engine {
	for s in SEARCH_ENGINES {
		if s.id == id {
			return s
		}
	}
	return SEARCH_ENGINES[0]
}

// Settings are per profile. `engine` is the one that matters most: it is read
// once, when the window starts its engine host, so changing it takes a
// restart -- the window says so and offers one.
Settings :: struct {
	engine:             string `json:"engine"`,
	search:             string `json:"search"`,
	theme:              string `json:"theme"`,
	homepage:           string `json:"homepage"`,
	show_bookmarks_bar: bool `json:"show_bookmarks_bar"`,
	restore_session:    bool `json:"restore_session"`,
	zoom:               f32 `json:"zoom"`,
	downloads_dir:      string `json:"downloads_dir"`,
	sync_bookmarks:     bool `json:"sync_bookmarks"`,
	device:             string `json:"device"`, // this profile's device id, for clocks
}

settings_default :: proc() -> Settings {
	return Settings {
		engine = "chromium",
		search = "duckduckgo",
		theme = "system",
		homepage = "palm://newtab",
		show_bookmarks_bar = true,
		restore_session = true,
		zoom = 1,
		sync_bookmarks = false,
	}
}

Profile :: struct {
	identity: string,
	dir:      string,
	color:    u32, // 0xRRGGBB, the identity's colour
	settings: Settings,
}

// browser_home is the directory holding one subdirectory per identity.
browser_home :: proc(allocator := context.allocator) -> string {
	if h := os.get_env("PALM_BROWSER_HOME", context.temp_allocator); h != "" {
		return strings.clone(h, allocator)
	}
	data := os.get_env("XDG_DATA_HOME", context.temp_allocator)
	if data == "" {
		data = fmt.tprintf("%s/.local/share", os.get_env("HOME", context.temp_allocator))
	}
	return fmt.aprintf("%s/palmframe/browser", data, allocator = allocator)
}

// identity_valid keeps an identity name usable as a directory name and
// nothing else: no separators, no dot-dot, nothing that could walk out of
// the browser's own directory.
identity_valid :: proc(name: string) -> bool {
	if name == "" || len(name) > 64 || name == "." || name == ".." {
		return false
	}
	for c in name {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
		if !ok {
			return false
		}
	}
	return true
}

// Identity colours. The accounts work owns the real registry; until it ships
// a local file, the four identities the contract names get fixed colours and
// any other name hashes into the same palette, so a colour never changes
// between runs.
IDENTITY_PALETTE := [?]u32{0x2563eb, 0xd97706, 0x7c3aed, 0x059669, 0xdb2777, 0x0891b2, 0xdc2626, 0x4f46e5}

identity_color :: proc(name: string) -> u32 {
	if c, ok := registry_color(name); ok {
		return c
	}
	switch name {
	case "personal":
		return 0x2563eb
	case "work":
		return 0xd97706
	case "public":
		return 0x7c3aed
	case "project":
		return 0x059669
	}
	h: u32 = 2166136261
	for b in transmute([]u8)name {
		h = (h ~ u32(b)) * 16777619
	}
	return IDENTITY_PALETTE[h % len(IDENTITY_PALETTE)]
}

// registry_color reads $XDG_CONFIG_HOME/palmframe/identities.json when it
// exists: [{"handle": "work", "color": "#d97706", ...}]. This is the seam for
// apps/accounts; nothing else in the browser reads that file.
registry_color :: proc(name: string) -> (c: u32, ok: bool) {
	cfg := os.get_env("XDG_CONFIG_HOME", context.temp_allocator)
	if cfg == "" {
		cfg = fmt.tprintf("%s/.config", os.get_env("HOME", context.temp_allocator))
	}
	data, err := os.read_entire_file(fmt.tprintf("%s/palmframe/identities.json", cfg), context.temp_allocator)
	if err != nil {
		return 0, false
	}
	Entry :: struct {
		handle: string,
		name:   string,
		color:  string,
	}
	entries: []Entry
	if json.unmarshal(data, &entries, allocator = context.temp_allocator) != nil {
		return 0, false
	}
	for e in entries {
		if (e.handle == name || e.name == name) && len(e.color) == 7 && e.color[0] == '#' {
			v: u32
			for ch in e.color[1:] {
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
	}
	return 0, false
}

// identity_of is the identity in force: --identity, then $PALM_IDENTITY, then
// the default.
identity_of :: proc(scoped: string) -> string {
	if scoped != "" {
		return scoped
	}
	if e := os.get_env("PALM_IDENTITY", context.temp_allocator); e != "" {
		return e
	}
	return DEFAULT_IDENTITY
}

profile_open :: proc(identity: string, allocator := context.allocator) -> (p: Profile, ok: bool) {
	if !identity_valid(identity) {
		return {}, false
	}
	p.identity = strings.clone(identity, allocator)
	p.dir = fmt.aprintf("%s/%s", browser_home(context.temp_allocator), identity, allocator = allocator)
	p.color = identity_color(identity)
	p.settings = settings_load(p.dir)
	return p, true
}

profile_ensure :: proc(p: ^Profile) -> bool {
	if os.exists(p.dir) {
		return true
	}
	return os.make_directory_all(p.dir, os.perm(0o700)) == nil
}

profile_path :: proc(p: ^Profile, name: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s/%s", p.dir, name, allocator = allocator)
}

profile_list :: proc(allocator := context.allocator) -> []string {
	home := browser_home(context.temp_allocator)
	out := make([dynamic]string, allocator)
	entries, err := os.read_all_directory_by_path(home, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for e in entries {
		if e.type == .Directory && identity_valid(e.name) {
			append(&out, strings.clone(e.name, allocator))
		}
	}
	return out[:]
}

settings_load :: proc(dir: string) -> Settings {
	s := settings_default()
	data, err := os.read_entire_file(fmt.tprintf("%s/settings.json", dir), context.temp_allocator)
	if err == nil {
		loaded := s
		if json.unmarshal(data, &loaded) == nil {
			s = loaded
		}
	}
	if _, ok := engine_parse(s.engine); !ok {
		s.engine = "chromium"
	}
	if s.zoom <= 0.2 || s.zoom > 5 {
		s.zoom = 1
	}
	if s.device == "" {
		s.device = new_device_id()
	}
	return s
}

settings_save :: proc(p: ^Profile) -> bool {
	profile_ensure(p) or_return
	data, err := json.marshal(p.settings, {pretty = true, use_spaces = true, spaces = 2}, context.temp_allocator)
	if err != nil {
		return false
	}
	return write_atomic(profile_path(p, "settings.json"), data)
}

profile_engine :: proc(p: ^Profile) -> Engine_Kind {
	k, _ := engine_parse(p.settings.engine)
	return k
}

profile_theme :: proc(p: ^Profile) -> Theme {
	switch p.settings.theme {
	case "light":
		return .Light
	case "dark":
		return .Dark
	}
	return .System
}

downloads_dir :: proc(p: ^Profile, allocator := context.allocator) -> string {
	if p.settings.downloads_dir != "" {
		return strings.clone(p.settings.downloads_dir, allocator)
	}
	if xdg := os.get_env("XDG_DOWNLOAD_DIR", context.temp_allocator); xdg != "" {
		return strings.clone(xdg, allocator)
	}
	return fmt.aprintf("%s/Downloads", os.get_env("HOME", context.temp_allocator), allocator = allocator)
}

// write_atomic replaces a file in one step: write beside it, then rename, so a
// crash leaves either the old file or the new one and never half of each.
write_atomic :: proc(path: string, data: []u8) -> bool {
	dir := filepath.dir(path)
	if !os.exists(dir) {
		os.make_directory_all(dir, os.perm(0o700))
	}
	tmp := fmt.tprintf("%s.tmp-%d", path, os.get_pid())
	if os.write_entire_file(tmp, data) != nil {
		return false
	}
	if os.rename(tmp, path) != nil {
		os.remove(tmp)
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// Ids and clocks
// ---------------------------------------------------------------------------

// new_uuid is a random (version 4) UUID, the stable identity of a bookmark
// across every device it ever reaches.
new_uuid :: proc(allocator := context.allocator) -> string {
	b: [16]u8
	crypto.rand_bytes(b[:])
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.aprintf(
		"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
		b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
		allocator = allocator,
	)
}

new_device_id :: proc(allocator := context.allocator) -> string {
	b: [6]u8
	crypto.rand_bytes(b[:])
	return fmt.aprintf("%02x%02x%02x%02x%02x%02x", b[0], b[1], b[2], b[3], b[4], b[5], allocator = allocator)
}

now_ms :: proc() -> i64 {
	return time.time_to_unix_nano(time.now()) / 1_000_000
}
