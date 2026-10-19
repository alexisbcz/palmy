// Settings — the system's settings, the ones that do something on this
// machine.
//
//	settings                  the window, on Appearance
//	settings keyboard         the window, on that page
//	settings get|set|reset|list|show ...   the command line (cli.odin)
//	settings --shots <dir>    every page, light and dark, offscreen (shot.odin)
//	settings --selftest
//
// Every page is backed by something real. Appearance, the mouse and the key
// repeat are lines of the window manager's configuration (~/.config/palmy/
// wm.conf), which it re-reads within a second, so a change is on screen as
// soon as it is made; the keyboard layout is ~/.config/palmy/keyboard, which
// the wm prefers over the system's /etc/palm/keyboard; the time zone is the
// session's (wm.conf `timezone`, inherited by every program as TZ). Displays
// come from what the wm publishes in $XDG_RUNTIME_DIR/palmy-wm.json, sound
// from PipeWire through wpctl, network from /sys and `ip`, users from
// /etc/passwd, updates from palm, About from /proc. What is not settable
// here says where it is set, rather than offering a control that does
// nothing.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import ai "kit:appindex"
import kit "kit:."
import p "palmy:."
import sc "shadcn:."

Page :: enum u8 {
	Appearance,
	Displays,
	Keyboard,
	Mouse,
	Sound,
	Network,
	Datetime,
	Users,
	Updates,
	About,
}

PAGE_ID := [Page]string {
	.Appearance = "appearance",
	.Displays   = "displays",
	.Keyboard   = "keyboard",
	.Mouse      = "mouse",
	.Sound      = "sound",
	.Network    = "network",
	.Datetime   = "datetime",
	.Users      = "users",
	.Updates    = "updates",
	.About      = "about",
}

PAGE_TITLE := [Page]string {
	.Appearance = "Appearance",
	.Displays   = "Displays",
	.Keyboard   = "Keyboard",
	.Mouse      = "Mouse & touchpad",
	.Sound      = "Sound",
	.Network    = "Network",
	.Datetime   = "Date & time",
	.Users      = "Users & passwords",
	.Updates    = "Software updates",
	.About      = "About",
}

PAGE_BLURB := [Page]string {
	.Appearance = "The look of the bar, title bars and menus, the accent colour and the desktop.",
	.Displays   = "The screens the window manager is driving.",
	.Keyboard   = "Your layout and how held keys repeat.",
	.Mouse      = "Scrolling, clicking and pointer speed for mice and touchpads.",
	.Sound      = "Where sound goes, and how loud.",
	.Network    = "How this computer is connected.",
	.Datetime   = "The time zone your clock and apps use.",
	.Users      = "Who can sign in, and your password.",
	.Updates    = "The installed system and what has a newer version.",
	.About      = "This computer and the system on it.",
}

PAGE_ICON := [Page]p.Icon {
	.Appearance = ai.ICON_PALETTE,
	.Displays   = ai.ICON_MONITOR,
	.Keyboard   = ai.ICON_KEYBOARD,
	.Mouse      = ai.ICON_MOUSE_POINTER_2,
	.Sound      = ai.ICON_VOLUME_2,
	.Network    = ai.ICON_WIFI,
	.Datetime   = ai.ICON_CLOCK,
	.Users      = ai.ICON_USERS,
	.Updates    = ai.ICON_REFRESH_CW,
	.About      = ai.ICON_INFO,
}

page_from :: proc(s: string) -> (Page, bool) {
	for id, pg in PAGE_ID {
		if id == s {
			return pg, true
		}
	}
	switch s {
	case "date", "time", "timezone":
		return .Datetime, true
	case "touchpad", "pointer":
		return .Mouse, true
	case "display", "screen":
		return .Displays, true
	case "wifi", "net":
		return .Network, true
	case "user", "password", "passwd":
		return .Users, true
	case "update", "software":
		return .Updates, true
	case "wallpaper", "theme":
		return .Appearance, true
	}
	return .Appearance, false
}

Dirty :: enum u8 {
	Delay,
	Rate,
	Speed,
	Volume,
}

// Model is everything the window shows. `fixture` is true for --shots: the
// setters then change only the model, and nothing on the machine is read or
// written.
Model :: struct {
	page:        Page,
	fixture:     bool,

	// Appearance and the shell.
	light:       bool,
	accent:      string, // "#rrggbb"
	wallpaper:   string,
	wp_mode:     string,
	wp_color:    string,
	super_tap:   string, // menu | overview | off
	bar_pins:    bool,
	hot_corner:  bool,
	animations:  string,

	// Mouse and touchpad.
	natural:     bool,
	tap:         bool,
	left:        bool,
	speed:       f32,

	// Keyboard.
	layout:      string, // the person's, "" for the system's
	variant:     string,
	sys_layout:  string,
	sys_variant: string,
	layouts:     []Layout,
	kfilter:     [dynamic]u8,
	ktest:       [dynamic]u8,
	delay:       int,
	rate:        int,

	// Date and time.
	tz:          string, // the session's, "" for the system's
	sys_tz:      string,
	zones:       []string,
	zfilter:     [dynamic]u8,

	// The read-only pages, read when first shown and on Refresh.
	wm:          Wm_State,
	sysfs:       []Display,
	sound:       Sound,
	ifaces:      []Iface,
	users:       []User,
	me:          string,
	updates:     Updates,
	about:       About,
	loaded:      bit_set[Page],
	have:        map[string]bool, // programs on PATH: term, passwd, mixer, network, store

	dirty:       bit_set[Dirty], // sliders moved but not yet written
	pick:        kit.Pick,
	toast:       string,
	toast_until: time.Time,
}

main :: proc() {
	for a, i in os.args[1:] {
		if a == "--shots" {
			rest := os.args[1:]
			dir := i + 1 < len(rest) ? rest[i + 1] : "apps/settings/shots"
			os.exit(shots(dir))
		}
	}
	if code, handled := kit.cli(surface()); handled {
		os.exit(code)
	}

	m := new(Model)
	if len(os.args) > 1 {
		if pg, ok := page_from(os.args[1]); ok {
			m.page = pg
		}
	}
	model_load(m)

	app, err := kit.start(
		{
			title = "Settings",
			app_id = "palmy-settings",
			width = 1080,
			height = 720,
			min_width = 820,
			min_height = 540,
			root_class = "w-full h-full bg-background text-foreground",
		},
		dark = !m.light,
	)
	if err != "" {
		fmt.eprintfln("settings: %s", err)
		os.exit(1)
	}
	defer p.destroy(app)

	for ui in p.frames(app) {
		// At the top, not the bottom: the previous frame was painted when
		// p.frames came back, and its p.pixels callbacks read user data
		// that lives in this allocator.
		free_all(context.temp_allocator)
		page_ensure(m, m.page)
		keys(ui, m)
		build(ui, m)
		if m.toast != "" {
			if time.since(m.toast_until) >= 0 {
				m.toast = ""
			} else {
				p.wake_at(ui, m.toast_until)
			}
		}
		// The clock on Date & time ticks.
		if m.page == .Datetime {
			p.wake_at(ui, time.time_add(time.now(), time.Second))
		}
	}
}

// model_load reads every setting the controls show. It is cheap: a few
// small files. The slow readers (wpctl, palm, ip) wait for their page.
model_load :: proc(m: ^Model) {
	get :: proc(name: string) -> string {
		k, _ := find_key(name)
		return strings.clone(setting_get(k).value)
	}
	m.light = get("appearance.theme") == "light"
	m.accent = get("appearance.accent")
	m.wallpaper = get("appearance.wallpaper")
	m.wp_mode = get("appearance.wallpaper_mode")
	m.wp_color = get("appearance.wallpaper_color")
	m.super_tap = get("shell.super_tap")
	m.bar_pins = get("shell.bar_pins") == "on"
	m.hot_corner = get("shell.hot_corner") == "on"
	m.animations = get("shell.animations")
	m.natural = get("mouse.natural_scroll") == "on"
	m.tap = get("mouse.tap_to_click") == "on"
	m.left = get("mouse.left_handed") == "on"
	m.speed = f32(strconv.parse_f64(get("mouse.speed")) or_else 0)
	m.delay = strconv.parse_int(get("keyboard.repeat_delay")) or_else 400
	m.rate = strconv.parse_int(get("keyboard.repeat_rate")) or_else 25
	u := kbd_read(kbd_user_path())
	if u.exists {
		m.layout, m.variant = strings.clone(u.layout), strings.clone(u.variant)
	}
	sys := kbd_read(KBD_SYSTEM_PATH)
	m.sys_layout = strings.clone(sys.layout != "" ? sys.layout : "us")
	m.sys_variant = strings.clone(sys.variant)
	m.tz = get("datetime.timezone")
	m.sys_tz = strings.clone(system_zone())
	for prog in ([?]string{"term", "passwd", "mixer", "network", "store", "files"}) {
		m.have[prog] = which(prog)
	}
	m.me = strings.clone(os.get_env("USER", context.temp_allocator))
}

// page_ensure reads what a read-only page shows, the first time it is shown.
page_ensure :: proc(m: ^Model, pg: Page) {
	if pg in m.loaded || m.fixture {
		return
	}
	m.loaded += {pg}
	switch pg {
	case .Displays:
		m.wm = read_wm_state()
		m.sysfs = sysfs_displays()
	case .Keyboard:
		m.wm = read_wm_state()
		m.layouts = read_layouts()
	case .Sound:
		m.sound = read_sound()
	case .Network:
		m.ifaces = read_ifaces()
	case .Datetime:
		m.zones = read_zones()
	case .Users:
		m.users = read_users()
	case .Updates:
		m.updates = read_updates()
	case .About:
		m.about = read_about()
		m.wm = read_wm_state()
	case .Appearance, .Mouse:
	}
}

refresh :: proc(m: ^Model) {
	m.loaded -= {m.page}
	page_ensure(m, m.page)
	toast(m, "Refreshed")
}

toast :: proc(m: ^Model, msg: string) {
	delete(m.toast)
	m.toast = strings.clone(msg)
	m.toast_until = time.time_add(time.now(), 2200 * time.Millisecond)
}

// apply writes one setting through the same path `settings set` uses, and
// says what happened. In the screenshots it only changes the model.
apply :: proc(m: ^Model, key, value: string) -> bool {
	if m.fixture {
		return true
	}
	k, ok := find_key(key)
	if !ok {
		return false
	}
	_, why, _ := setting_set(k, value)
	if why != "" {
		toast(m, why)
		return false
	}
	return true
}

// set_theme also re-dresses this window, so the change is visible here as
// well as in the bar.
set_theme :: proc(m: ^Model, light: bool) {
	if apply(m, "appearance.theme", light ? "light" : "dark") {
		m.light = light
		sc.register_shadcn_theme(!light)
	}
}

launch :: proc(m: ^Model, argv: []string) {
	if m.fixture {
		return
	}
	if !kit.launch(argv) {
		toast(m, fmt.tprintf("Could not start %s", argv[0]))
	}
}

keys :: proc(ui: ^p.Ctx, m: ^Model) {
	if kit.pick_active(&m.pick) {
		return
	}
	// Ctrl+PageUp/PageDown, or Alt+Up/Down, walk the pages.
	if p.shortcut(ui, p.KEY_PAGE_DOWN, {.Ctrl}, true) || p.shortcut(ui, p.KEY_DOWN, {.Alt}, true) {
		if m.page < max(Page) {
			m.page = Page(int(m.page) + 1)
		}
	}
	if p.shortcut(ui, p.KEY_PAGE_UP, {.Ctrl}, true) || p.shortcut(ui, p.KEY_UP, {.Alt}, true) {
		if m.page > min(Page) {
			m.page = Page(int(m.page) - 1)
		}
	}
	if p.shortcut(ui, 'q', {.Ctrl}) || p.shortcut(ui, 'w', {.Ctrl}) {
		p.quit_app(ui.app)
	}
}
