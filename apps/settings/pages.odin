package main

import "core:fmt"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "core:time/timezone"
import ai "kit:appindex"
import p "palmy:."
import sc "shadcn:."

// ---------------------------------------------------------------------------
// Mouse & touchpad
// ---------------------------------------------------------------------------

page_mouse :: proc(ui: ^p.Ctx, m: ^Model) {
	section(ui)
	card_open(ui, "Scrolling and clicking")
	if switch_row(ui, "Natural scrolling", "The page follows your fingers, as on a phone: swipe up to go down.", m.natural, first = true) && apply(m, "mouse.natural_scroll", m.natural ? "off" : "on") {
		m.natural = !m.natural
		toast(m, m.natural ? "Natural scrolling on" : "Natural scrolling off")
	}
	if switch_row(ui, "Tap to click", "A light tap on the touchpad clicks; two fingers right-click.", m.tap) && apply(m, "mouse.tap_to_click", m.tap ? "off" : "on") {
		m.tap = !m.tap
	}
	if switch_row(ui, "Left-handed", "Swap the primary and secondary buttons.", m.left) && apply(m, "mouse.left_handed", m.left ? "off" : "on") {
		m.left = !m.left
	}
	card_close(ui)
	p.end(ui)

	section(ui)
	card_open(ui, "Pointer")
	label := m.speed == 0 ? "Default" : (m.speed < 0 ? "Slower" : "Faster")
	if slider_row(ui, "Speed", "How far the pointer travels for the same movement.", &m.speed, -1, 1, label, first = true) {
		m.speed = f32(int(m.speed * 20 + (m.speed < 0 ? -0.5 : 0.5))) / 20
		m.dirty += {.Speed}
	}
	if !p.mouse_down(ui) && .Speed in m.dirty {
		apply(m, "mouse.speed", fmt.tprintf("%.2f", m.speed))
		m.dirty -= {.Speed}
	}
	card_close(ui)
	p.end(ui)
	if m.wm.ok && !m.wm.bare {
		note(ui, "This session is nested in another desktop, whose own mouse settings apply; these take effect when Palmy runs on the machine itself.")
	} else {
		note(ui, "These apply to every mouse and touchpad, the moment they change.")
	}
}

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

page_sound :: proc(ui: ^p.Ctx, m: ^Model) {
	s := &m.sound
	if !s.available {
		empty_state(ui, ai.ICON_VOLUME_2, "No sound server", "Sound on Palmy is PipeWire with WirePlumber (packages pipewire, wireplumber), which are part of palmy-runtime. Install them with Software to control volume and outputs here.")
		return
	}
	if !s.running {
		empty_state(ui, ai.ICON_VOLUME_2, "The sound server is not running", "wpctl is installed but PipeWire did not answer. It starts with your session; logging out and back in usually brings it up.")
		return
	}
	section(ui)
	card_open(ui, "Output")
	vol := s.volume
	if slider_row(ui, "Volume", s.muted ? "Muted" : "", &vol, 0, 1, fmt.tprintf("%d%%", int(vol * 100 + 0.5)), first = true) {
		s.volume = vol
		m.dirty += {.Volume}
	}
	if !p.mouse_down(ui) && .Volume in m.dirty {
		apply(m, "sound.volume", fmt.tprintf("%d", int(s.volume * 100 + 0.5)))
		m.dirty -= {.Volume}
	}
	if switch_row(ui, "Mute", "Silence the output without losing the volume.", s.muted) && apply(m, "sound.mute", s.muted ? "off" : "on") {
		s.muted = !s.muted
	}
	card_close(ui)
	p.end(ui)

	device_list :: proc(ui: ^p.Ctx, m: ^Model, title: string, list: []Sink) {
		section(ui)
		card_open(ui, title)
		if len(list) == 0 {
			p.text(ui, "None found.", "px-5 py-4 text-sm text-muted-foreground")
		}
		for d, i in list {
			idx := p.row(ui, "w-full items-center gap-3 px-5 h-12 cursor-pointer hover:bg-accent/40")
			if i > 0 {
				p.apply(ui, "border-t border-border")
			}
			p.focusable(ui, idx)
			if p.activated(ui, idx) && !d.def && !m.fixture {
				if _, ok := run_text({"wpctl", "set-default", fmt.tprintf("%d", d.id)}); ok {
					refresh(m)
				}
			}
			sc.radio(ui, d.def)
			p.text(ui, d.name, "flex-1 min-w-0 text-sm truncate")
			if d.volume >= 0 {
				p.text(ui, fmt.tprintf("%d%%", int(d.volume * 100 + 0.5)), "text-xs text-muted-foreground tabular-nums")
			}
			p.end(ui)
		}
		card_close(ui)
		p.end(ui)
	}
	device_list(ui, m, "Speakers and headphones", s.sinks)
	device_list(ui, m, "Microphones", s.sources)
	if m.have["mixer"] {
		p.row(ui, "w-full")
		if button(ui, "Open the volume mixer", .Outline, ai.ICON_EXTERNAL_LINK) {
			launch(m, {"mixer"})
		}
		p.end(ui)
	}
}

// ---------------------------------------------------------------------------
// Network
// ---------------------------------------------------------------------------

page_network :: proc(ui: ^p.Ctx, m: ^Model) {
	if len(m.ifaces) == 0 {
		empty_state(ui, ai.ICON_WIFI, "No network interfaces", "The kernel lists none besides the loopback. A wired adapter or a Wi-Fi card needs its driver and, for some, firmware (packages linux-firmware-*).")
	}
	for i in m.ifaces {
		section(ui)
		card_open(ui)
		p.row(ui, "w-full items-center gap-4 px-5 py-4")
		p.div(ui, "size-10 rounded-xl bg-muted flex-row items-center justify-center shrink-0")
		p.icon(ui, i.kind == "Wi-Fi" ? ai.ICON_WIFI : ai.ICON_ETHERNET_PORT, "size-5 text-muted-foreground")
		p.end(ui)
		p.col(ui, "flex-1 min-w-0 gap-0.5")
		title := i.kind == "Wi-Fi" && i.ssid != "" ? fmt.tprintf("Wi-Fi · %s", i.ssid) : i.kind
		p.text(ui, title, "text-sm font-semibold")
		p.text(ui, i.name, "text-xs text-muted-foreground font-mono")
		p.end(ui)
		up := i.state == "up"
		sc.badge(ui, up ? "Connected" : (i.state == "" ? "Unknown" : strings.to_upper_camel_case(i.state, context.temp_allocator)), up ? .Default : .Secondary)
		p.end(ui)
		kv(ui, "Addresses", strings.join(i.addrs, "   ", context.temp_allocator), mono = true)
		kv(ui, "Hardware address", i.mac, mono = true)
		card_close(ui)
		p.end(ui)
	}
	if m.have["network"] {
		p.row(ui, "w-full")
		if button(ui, "Open Network to join a Wi-Fi network", .Outline, ai.ICON_EXTERNAL_LINK) {
			launch(m, {"network"})
		}
		p.end(ui)
	} else {
		note(ui, "This page only reports. Wi-Fi is iwd: `iwctl station wlan0 connect <network>` in a terminal joins one.")
	}
}

// ---------------------------------------------------------------------------
// Date & time
// ---------------------------------------------------------------------------

// zone_now is the time in a zone and its abbreviation and UTC offset.
zone_now :: proc(zone: string) -> (hhmm, date, abbr: string, offset_min: int) {
	now := time.now()
	dt, _ := time.time_to_datetime(now)
	local := dt
	abbr = "UTC"
	if zone != "" && zone != "UTC" {
		if data, ok := read_text(fmt.tprintf("%s/%s", ZONEINFO, zone)); ok {
			if reg, rok := timezone.region_load_from_buffer(transmute([]u8)data, zone, context.temp_allocator); rok {
				if l, lok := timezone.datetime_to_tz(dt, reg); lok {
					local = l
					abbr = timezone.shortname_unsafe(l)
				}
			}
		}
	}
	if lt, ok := time.datetime_to_time(local); ok {
		offset_min = int((time.to_unix_seconds(lt) - time.to_unix_seconds(now)) / 60)
	}
	hhmm = fmt.tprintf("%02d:%02d", local.hour, local.minute)
	MONTHS := [?]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}
	mi := clamp(int(local.month) - 1, 0, 11)
	date = fmt.tprintf("%d %s %d", local.day, MONTHS[mi], local.year)
	return
}

page_datetime :: proc(ui: ^p.Ctx, m: ^Model) {
	eff := m.tz != "" ? m.tz : m.sys_tz
	hhmm, date, abbr, off := zone_now(eff)
	section(ui)
	card_open(ui)
	p.row(ui, "w-full items-center gap-5 px-6 py-6")
	p.text(ui, hhmm, "text-5xl font-semibold tracking-tight tabular-nums")
	p.col(ui, "flex-1 min-w-0 gap-1")
	p.text(ui, date, "text-base font-medium")
	sign := off < 0 ? "-" : "+"
	p.text(ui, fmt.tprintf("%s · %s · UTC%s%02d:%02d", eff, abbr, sign, abs(off) / 60, abs(off) % 60), "text-sm text-muted-foreground")
	p.end(ui)
	p.end(ui)
	card_close(ui)
	p.end(ui)

	section(ui)
	card_open(ui, "Time zone", "Yours applies to the clock in the bar and to every app you open from now on.")
	p.row(ui, "w-full items-center gap-4 px-5 py-4")
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, m.tz != "" ? m.tz : fmt.tprintf("%s (the system's)", m.sys_tz), "text-sm font-medium")
	p.text(ui, m.tz != "" ? "Chosen here, for your sessions." : "Set when Palmy was installed, in /etc/localtime.", "text-xs text-muted-foreground")
	p.end(ui)
	if m.tz != "" {
		if button(ui, fmt.tprintf("Use the system's (%s)", m.sys_tz), .Outline) && apply(m, "datetime.timezone", "") {
			delete(m.tz)
			m.tz = ""
			toast(m, "Back to the system time zone")
		}
	}
	p.end(ui)
	list_filter(ui, &m.zfilter, "Find a city or region — Paris, Tokyo, America…")
	p.col(ui, "w-full h-[300] overflow-scroll py-1")
	q := strings.to_lower(string(m.zfilter[:]), context.temp_allocator)
	shown := 0
	for z in m.zones {
		if q != "" && !strings.contains(strings.to_lower(z, context.temp_allocator), q) {
			continue
		}
		shown += 1
		if shown > 150 {
			break
		}
		sel := z == eff
		p.key(ui, z)
		idx := p.row(ui, "w-full h-9 shrink-0 items-center gap-3 px-5 cursor-pointer hover:bg-accent/50")
		if sel {
			p.apply(ui, "bg-accent/60")
		}
		p.focusable(ui, idx)
		if p.activated(ui, idx) && !sel && apply(m, "datetime.timezone", z) {
			delete(m.tz)
			m.tz = strings.clone(z)
			toast(m, fmt.tprintf("Time zone: %s", z))
		}
		city := z
		if sl := strings.last_index_byte(z, '/'); sl >= 0 {
			city = z[sl + 1:]
		}
		city, _ = strings.replace_all(city, "_", " ", context.temp_allocator)
		p.text(ui, city, "w-[180] shrink-0 text-sm truncate")
		p.text(ui, z, "flex-1 min-w-0 text-xs text-muted-foreground truncate")
		if sel {
			p.icon(ui, ai.ICON_CHECK, "size-4 shrink-0")
		}
		p.end(ui)
	}
	if shown == 0 {
		p.text(ui, len(m.zones) == 0 ? "No time zone data (package tzdata)." : "No time zone matches.", "px-5 py-3 text-sm text-muted-foreground")
	}
	p.end(ui)
	card_close(ui)
	p.end(ui)
	note(ui, "The system's time zone, used before anyone signs in, is changed by an administrator: doas ln -sf /usr/share/zoneinfo/<Region/City> /etc/localtime.")
	_ = datetime.Date{}
}

// ---------------------------------------------------------------------------
// Users & passwords
// ---------------------------------------------------------------------------

page_users :: proc(ui: ^p.Ctx, m: ^Model) {
	me: ^User
	for &u in m.users {
		if u.name == m.me {
			me = &u
		}
	}
	section(ui)
	card_open(ui, "You")
	p.row(ui, "w-full items-center gap-4 px-5 py-5")
	who := m.me
	full := ""
	admin := false
	if me != nil {
		full = me.gecos
		for g in me.groups {
			admin = admin || g == "wheel"
		}
	}
	p.div(ui, "size-12 rounded-full bg-primary flex-row items-center justify-center shrink-0")
	initial := len(full) > 0 ? full[:1] : (len(who) > 0 ? who[:1] : "?")
	p.text(ui, strings.to_upper(initial, context.temp_allocator), "text-lg font-semibold text-primary-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, full != "" ? full : who, "text-base font-semibold")
	p.text(ui, me != nil ? fmt.tprintf("%s · uid %d · %s", who, me.uid, me.home) : who, "text-xs text-muted-foreground")
	p.end(ui)
	if admin {
		sc.badge(ui, "Administrator", .Secondary)
	}
	p.end(ui)
	row_open(ui, "Password", "Asks for the current one, then the new one twice, in a terminal: passwords are never typed into a window that could keep them.")
	can := m.have["term"] && m.have["passwd"]
	if button(ui, "Change password…", .Outline, disabled = !can) {
		launch(m, {"term", "-e", "passwd"})
	}
	row_close(ui)
	if me != nil {
		row_open(ui, "Groups", admin ? "As a member of wheel you can install software and run commands as root with doas." : "Not an administrator: installing software and changing the system need someone in wheel.")
		p.text(ui, strings.join(me.groups, ", ", context.temp_allocator), "max-w-[260] text-xs font-mono text-muted-foreground text-right")
		row_close(ui)
	}
	card_close(ui)
	p.end(ui)

	others := 0
	for u in m.users {
		if u.name != m.me {
			others += 1
		}
	}
	section(ui)
	card_open(ui, "Other accounts")
	if others == 0 {
		p.text(ui, "You are the only account on this computer.", "px-5 py-4 text-sm text-muted-foreground")
	}
	first := true
	for u in m.users {
		if u.name == m.me {
			continue
		}
		kv(ui, u.name, fmt.tprintf("%s%s", u.gecos != "" ? fmt.tprintf("%s · ", u.gecos) : "", strings.join(u.groups, ", ", context.temp_allocator)), first)
		first = false
	}
	card_close(ui)
	p.end(ui)
	note(ui, "Adding an account is an administrator's job for now: doas adduser <name> in a terminal.")
}

// ---------------------------------------------------------------------------
// Software updates
// ---------------------------------------------------------------------------

page_updates :: proc(ui: ^p.Ctx, m: ^Model) {
	u := &m.updates
	if !u.available {
		empty_state(ui, ai.ICON_PACKAGE, "No package manager", "palm is not on this system's PATH, so there is nothing to read updates from.")
		return
	}
	section(ui)
	card_open(ui)
	p.row(ui, "w-full items-center gap-4 px-5 py-5")
	p.div(ui, "size-12 rounded-xl bg-muted flex-row items-center justify-center shrink-0")
	p.icon(ui, len(u.upgradable) > 0 ? ai.ICON_DOWNLOAD : ai.ICON_SHIELD_CHECK, "size-6 text-muted-foreground")
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, len(u.upgradable) == 0 ? "Palmy is up to date" : fmt.tprintf("%d update%s available", len(u.upgradable), len(u.upgradable) == 1 ? "" : "s"), "text-base font-semibold")
	checked := "The package lists have not been fetched yet."
	if u.checked > 0 {
		t := time.unix(u.checked, 0)
		y, mo, d := time.date(t)
		checked = fmt.tprintf("Package lists from %d %v %d.", d, mo, y)
	}
	p.text(ui, checked, "text-xs text-muted-foreground")
	p.end(ui)
	if m.have["store"] {
		if button(ui, len(u.upgradable) > 0 ? "Update in Software" : "Open Software", len(u.upgradable) > 0 ? .Default : .Outline) {
			launch(m, {"store"})
		}
	}
	p.end(ui)
	kv(ui, "System", u.system_ver != "" ? fmt.tprintf("Palmy %s", u.system_ver) : "")
	kv(ui, "Installed packages", fmt.tprintf("%d", u.installed))
	kv(ui, "Package manager", u.palm_ver)
	card_close(ui)
	p.end(ui)
	if len(u.upgradable) > 0 {
		section(ui)
		card_open(ui, "Newer versions")
		for x, i in u.upgradable {
			p.row(ui, "w-full items-center gap-3 px-5 h-10")
			if i > 0 {
				p.apply(ui, "border-t border-border")
			}
			p.icon(ui, ai.ICON_PACKAGE, "size-4 shrink-0 text-muted-foreground")
			p.text(ui, x, "flex-1 min-w-0 text-sm font-mono truncate")
			p.end(ui)
		}
		card_close(ui)
		p.end(ui)
	}
	note(ui, "Software (and palm update / palm upgrade in a terminal) fetches the lists and installs updates through palmd, which shows the plan before anything changes.")
}

// ---------------------------------------------------------------------------
// About
// ---------------------------------------------------------------------------

page_about :: proc(ui: ^p.Ctx, m: ^Model) {
	a := &m.about
	section(ui)
	card_open(ui)
	p.row(ui, "w-full items-center gap-5 px-6 py-6")
	p.div(ui, fmt.tprintf("size-14 rounded-2xl bg-[%s] flex-row items-center justify-center shrink-0", m.accent))
	p.div(ui, "size-6 rounded-md bg-white/80")
	p.end(ui)
	p.end(ui)
	p.col(ui, "flex-1 min-w-0 gap-0.5")
	p.text(ui, a.os_name, "text-xl font-semibold tracking-tight")
	ver := a.os_version != "" ? a.os_version : (m.updates.system_ver != "" ? m.updates.system_ver : "")
	p.text(ui, ver != "" ? fmt.tprintf("Version %s", ver) : "A small Linux built around its own toolkit and window manager.", "text-sm text-muted-foreground")
	p.end(ui)
	p.end(ui)
	card_close(ui)
	p.end(ui)

	section(ui)
	card_open(ui, "This computer")
	kv(ui, "Name", a.hostname, first = true)
	kv(ui, "Processor", a.cores > 0 ? fmt.tprintf("%s · %d thread%s", a.cpu, a.cores, a.cores == 1 ? "" : "s") : a.cpu)
	kv(ui, "Memory", a.mem_total_kb > 0 ? human_bytes(u64(a.mem_total_kb) * 1024) : "")
	kv(ui, "Disk", a.disk_total > 0 ? fmt.tprintf("%s, %s free", human_bytes(a.disk_total), human_bytes(a.disk_free)) : "")
	kv(ui, "Graphics", a.gpu)
	card_close(ui)
	p.end(ui)

	section(ui)
	card_open(ui, "System")
	kv(ui, "Kernel", fmt.tprintf("Linux %s", a.kernel), first = true)
	kv(ui, "Session", m.wm.ok ? (m.wm.bare ? "palmy wm, on the hardware (DRM)" : "palmy wm, nested") : "")
	up := a.uptime_s
	kv(ui, "Up for", up > 0 ? (up >= 86400 ? fmt.tprintf("%d days, %d h", up / 86400, (up % 86400) / 3600) : fmt.tprintf("%d h %d min", up / 3600, (up % 3600) / 60)) : "")
	card_close(ui)
	p.end(ui)
}
