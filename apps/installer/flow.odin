package main

// The installer's state and the rules for moving through it.
//
// The pages run in INSTALLER.md's order. Forward is gated (`can_leave`):
// every page knows what it needs before Next does anything, and says so in a
// sentence beside the button rather than greying it out silently. Backward is
// free until the install starts; after that there is no way back, because the
// disk is no longer what the earlier pages described.
//
// None of this draws. ui.odin and pages.odin read the state and call
// `go_next`, `go_back` and `go_to`; selftest.odin drives the same procedures
// with no window at all.

import "core:os"
import "core:strings"
import "core:time"
import "core:time/datetime"

Page :: enum {
	Language,
	Keyboard,
	Timezone,
	Disk,
	Account,
	Summary,
	Install,
	Done,
}

St :: struct {
	backend:        Backend,
	page:           Page,
	visited:        bit_set[Page],

	// Language
	languages:      []Language,
	lang_i:         int,

	// Keyboard: `keyboards` is base.lst flattened, layouts and variants
	// alike; `layouts` indexes the rows with no variant.
	keyboards:      []Keyboard,
	layouts:        [dynamic]int,
	layout_i:       int, // into layouts
	variant:        string, // "" = the layout's default
	kb_search:      [dynamic]u8,
	kb_test:        [dynamic]u8,
	kb_dirty_at:    f32, // when the selection last changed; applied once it settles
	kb_dirty:       bool,
	kb_said:        string, // what apply_keyboard last reported

	// Time zone
	zones:          []Zone,
	zone_i:         int,
	zone_search:    [dynamic]u8,
	tz_region:      ^datetime.TZ_Region,
	tz_loaded:      string,

	// Choices the user made by hand stop following the language.
	picked:         bit_set[Page],

	// Disk
	disks:          []Disk,
	disk_i:         int, // -1: none chosen
	confirm_open:   bool, // the erase dialog
	confirmed:      string, // the path the user agreed to erase
	dialog_focus:   bool, // the dialog just opened: focus Cancel
	swap:           bool, // make a swap file on the new system
	swap_bytes:     u64, // its size, from this machine's memory

	// Account
	full_name:      [dynamic]u8,
	user:           [dynamic]u8,
	hostname:       [dynamic]u8,
	password:       [dynamic]u8,
	confirm:        [dynamic]u8,
	root_password:  [dynamic]u8,
	root_confirm:   [dynamic]u8,
	same_root:      bool,
	user_edited:    bool, // the user name was typed, so it stops following the full name
	touched:        bit_set[Field],
	tried:          bool, // Next was pressed on the account page: show every problem
	show_password:  bool,

	// Summary: the core's verdict, when it had objections.
	core_problems:  []Text,

	// Install
	worker:         ^Worker,
	log_open:       bool,

	// Done
	note:           string,

	// Focus requests: the next frame puts the keyboard on this page's first
	// control (or on a named field).
	want_focus:     bool,
	scroll_pending: bool, // a list's selection still has to be scrolled into view
	focus_field:    Maybe(Field),
}

state_init :: proc(st: ^St, b: Backend) {
	st.backend = b
	st.languages = load_languages(&st.backend)
	st.keyboards = load_layouts(&st.backend)
	st.zones = load_zones(&st.backend)
	st.disks = load_disks(&st.backend)
	st.disk_i = -1
	st.same_root = true
	st.swap = true
	st.swap_bytes = swap_size_for(memory_bytes(&st.backend))
	st.visited = {.Language}
	st.want_focus = true

	for k, i in st.keyboards {
		if k.variant == "" {
			append(&st.layouts, i)
		}
	}
	append(&st.hostname, "palmframe")

	st.disk_i = preselect_disk(st.disks)

	// Start from whatever language the environment names, or English.
	st.lang_i = 0
	pick_language(st, st.lang_i)
}

// swap_size_for is the swap file offered by default: half the memory, in
// whole GiB, at least 1 GiB and at most 4 GiB. It is room to page out what
// sits idle, not hibernation, which Palmframe does not do.
swap_size_for :: proc(mem: u64) -> u64 {
	gib := (mem / 2 + (1 << 30) - 1) >> 30
	return clamp(gib, 1, 4) << 30
}

// preselect_disk: one usable disk is the common case (a laptop, a QEMU
// guest), so it is chosen already; with several, the user chooses. Erasing
// it still takes the confirmation that names it.
preselect_disk :: proc(disks: []Disk) -> int {
	usable := -1
	for d, i in disks {
		if ok, _ := disk_usable(d); ok {
			if usable >= 0 {
				return -1
			}
			usable = i
		}
	}
	return usable
}

cur_language :: proc(st: ^St) -> Language {
	if len(st.languages) == 0 {
		return LANGUAGES[0]
	}
	return st.languages[clamp(st.lang_i, 0, len(st.languages) - 1)]
}

cur_keyboard :: proc(st: ^St) -> Keyboard {
	if len(st.layouts) == 0 {
		return {layout = "us", description = "English (US)"}
	}
	base := st.keyboards[st.layouts[clamp(st.layout_i, 0, len(st.layouts) - 1)]]
	if st.variant == "" {
		return base
	}
	for k in st.keyboards {
		if k.layout == base.layout && k.variant == st.variant {
			return k
		}
	}
	return base
}

cur_zone :: proc(st: ^St) -> Zone {
	if len(st.zones) == 0 {
		return {name = "UTC", city = "UTC"}
	}
	return st.zones[clamp(st.zone_i, 0, len(st.zones) - 1)]
}

cur_disk :: proc(st: ^St) -> (Disk, bool) {
	if st.disk_i < 0 || st.disk_i >= len(st.disks) {
		return {}, false
	}
	return st.disks[st.disk_i], true
}

// variants_of lists the variants of the current layout, by index into
// `keyboards`.
variants_of :: proc(st: ^St, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	if len(st.layouts) == 0 {
		return out[:]
	}
	base := st.keyboards[st.layouts[clamp(st.layout_i, 0, len(st.layouts) - 1)]]
	for k, i in st.keyboards {
		if k.layout == base.layout && k.variant != "" {
			append(&out, i)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Choosing
// ---------------------------------------------------------------------------

// LANGUAGE_DEFAULTS: picking a language also preselects the keyboard and the
// time zone most people choosing it will want, until the user picks those
// pages' values by hand.
LANGUAGE_DEFAULTS := [?]struct {
	prefix, layout, zone: string,
}{
	{"en", "us", "America/New_York"},
	{"fr", "fr", "Europe/Paris"},
	{"de", "de", "Europe/Berlin"},
	{"es", "es", "Europe/Madrid"},
	{"ar", "ara", "Africa/Cairo"},
	{"ja", "jp", "Asia/Tokyo"},
}

pick_language :: proc(st: ^St, i: int) {
	if len(st.languages) == 0 {
		return
	}
	st.lang_i = clamp(i, 0, len(st.languages) - 1)
	l := cur_language(st)
	if l.available {
		set_language(l.code)
	}
	for d in LANGUAGE_DEFAULTS {
		if !strings.has_prefix(l.code, d.prefix) {
			continue
		}
		if .Keyboard not_in st.picked {
			for idx, li in st.layouts {
				if st.keyboards[idx].layout == d.layout {
					if li != st.layout_i || st.variant != "" {
						// The compositor follows too, so the account page
						// types in the layout the keyboard page will show.
						st.kb_dirty = true
						st.kb_dirty_at = 0
					}
					st.layout_i = li
					st.variant = ""
					break
				}
			}
		}
		if .Timezone not_in st.picked {
			for z, zi in st.zones {
				if z.name == d.zone {
					st.zone_i = zi
					break
				}
			}
		}
		break
	}
}

pick_layout :: proc(st: ^St, li: int, now: f32) {
	if len(st.layouts) == 0 {
		return
	}
	n := clamp(li, 0, len(st.layouts) - 1)
	if n != st.layout_i {
		st.variant = ""
	}
	st.layout_i = n
	st.picked += {.Keyboard}
	st.kb_dirty = true
	st.kb_dirty_at = now
}

pick_variant :: proc(st: ^St, variant: string, now: f32) {
	st.variant = variant
	st.picked += {.Keyboard}
	st.kb_dirty = true
	st.kb_dirty_at = now
}

// KB_SETTLE is how long a keyboard selection must stay put before the
// compositor is told: holding the down arrow through forty layouts should
// not recompile forty keymaps.
KB_SETTLE :: f32(0.25)

// settle_keyboard sends the layout to the compositor once it has settled.
settle_keyboard :: proc(st: ^St, now: f32) {
	if st.kb_dirty && now - st.kb_dirty_at >= KB_SETTLE {
		st.kb_dirty = false
		st.kb_said = apply_keyboard(&st.backend, cur_keyboard(st))
	}
}

pick_zone :: proc(st: ^St, i: int) {
	if len(st.zones) == 0 {
		return
	}
	st.zone_i = clamp(i, 0, len(st.zones) - 1)
	st.picked += {.Timezone}
}

pick_disk :: proc(st: ^St, i: int) {
	if i < 0 || i >= len(st.disks) {
		return
	}
	if ok, _ := disk_usable(st.disks[i]); !ok {
		return
	}
	st.disk_i = i
	if st.confirmed != st.disks[i].path {
		// Agreeing to erase one disk is not agreeing to erase another.
		st.confirmed = ""
	}
}

account_of :: proc(st: ^St) -> Account {
	return Account {
		full_name = string(st.full_name[:]),
		user = string(st.user[:]),
		hostname = string(st.hostname[:]),
		password = string(st.password[:]),
		confirm = string(st.confirm[:]),
		same_root = st.same_root,
		root_password = string(st.root_password[:]),
		root_confirm = string(st.root_confirm[:]),
	}
}

// full_name_changed keeps the user name following the full name until the
// user name has been typed into.
full_name_changed :: proc(st: ^St) {
	if st.user_edited {
		return
	}
	s := suggest_user(string(st.full_name[:]), context.temp_allocator)
	clear(&st.user)
	append(&st.user, s)
}

// ---------------------------------------------------------------------------
// Moving
// ---------------------------------------------------------------------------

// can_leave says whether Next may leave the page, and if not, why (a msgid).
can_leave :: proc(st: ^St) -> (ok: bool, why: string) {
	switch st.page {
	case .Language:
		if !cur_language(st).available {
			return false, N("This language cannot be shown: no font for its script is installed")
		}
	case .Keyboard:
		if len(st.layouts) == 0 {
			return false, N("No keyboard layouts were found")
		}
	case .Timezone:
		if len(st.zones) == 0 {
			return false, N("No time zones were found")
		}
	case .Disk:
		d, have := cur_disk(st)
		if !have {
			if len(st.disks) == 0 {
				return false, N("No disks were found")
			}
			return false, N("Choose a disk")
		}
		if ok2, why2 := disk_usable(d); !ok2 {
			return false, why2
		}
	case .Account:
		if !account_ok(validate_account(account_of(st))) {
			return false, N("Some fields need attention")
		}
	case .Summary:
		if st.confirmed == "" {
			return false, N("The disk has not been confirmed")
		}
	case .Install:
		return false, ""
	case .Done:
		return false, ""
	}
	return true, ""
}

// go_next is Next (and Enter). It may open the erase dialog instead of
// moving, and on the summary page it starts the install.
go_next :: proc(st: ^St) {
	if st.confirm_open {
		return
	}
	ok, _ := can_leave(st)
	if st.page == .Account && !ok {
		st.tried = true
		// Put the keyboard where the first problem is.
		p := validate_account(account_of(st))
		for f in Field {
			if p[f] != "" {
				st.focus_field = f
				break
			}
		}
		return
	}
	if !ok {
		return
	}
	#partial switch st.page {
	case .Disk:
		d, _ := cur_disk(st)
		if st.confirmed != d.path {
			st.confirm_open = true
			st.dialog_focus = true
			return
		}
	case .Summary:
		start_install(st)
		return
	}
	move_to(st, Page(int(st.page) + 1))
}

// confirm_erase is the dialog's destructive button.
confirm_erase :: proc(st: ^St) {
	d, have := cur_disk(st)
	st.confirm_open = false
	if !have {
		return
	}
	st.confirmed = d.path
	move_to(st, .Account)
}

cancel_erase :: proc(st: ^St) {
	st.confirm_open = false
	st.want_focus = true
}

can_go_back :: proc(st: ^St) -> bool {
	return st.page > .Language && st.page < .Install && !st.confirm_open
}

go_back :: proc(st: ^St) {
	if st.confirm_open {
		cancel_erase(st)
		return
	}
	if can_go_back(st) {
		move_to(st, Page(int(st.page) - 1))
	}
}

// go_to is a click on the rail: any page already visited, before the install.
can_go_to :: proc(st: ^St, p: Page) -> bool {
	return p in st.visited && p < .Install && st.page < .Install && !st.confirm_open
}

go_to :: proc(st: ^St, p: Page) {
	if can_go_to(st, p) {
		move_to(st, p)
	}
}

move_to :: proc(st: ^St, p: Page) {
	st.page = p
	st.visited += {p}
	st.want_focus = true
	st.scroll_pending = true
}

// plan_of is the Plan the summary describes and the install carries out.
plan_of :: proc(st: ^St) -> Plan {
	d, _ := cur_disk(st)
	a := account_of(st)
	root := ""
	if !a.same_root {
		root = a.root_password
	}
	// The default package set has no CJK font (19 MB in every palmy process
	// is a lot for a machine that never shows a kanji), so a system that is
	// to speak Japanese gets it added; it is in the medium's repository.
	packages: []string
	if strings.has_prefix(cur_language(st).code, "ja") {
		packages = CJK_PACKAGES[:]
	}
	return Plan {
		disk = d.path,
		language = cur_language(st).code,
		keyboard = cur_keyboard(st),
		timezone = cur_zone(st).name,
		hostname = a.hostname,
		full_name = a.full_name,
		user = a.user,
		password = a.password,
		root_password = root,
		packages = packages,
		efi_boot_entry = os.is_dir("/sys/firmware/efi"),
		swap_bytes = st.swap ? st.swap_bytes : 0,
	}
}

// A package-level array, so the slice plan_of hands out outlives the call.
CJK_PACKAGES := [?]string{"palmframe", "fonts-cjk"}

start_install :: proc(st: ^St) {
	if st.worker != nil {
		return
	}
	plan := plan_of(st)
	if ok, problems := check_plan(&st.backend, plan); !ok {
		st.core_problems = problems
		return
	}
	st.core_problems = nil
	st.worker = worker_start(st.backend, plan)
	move_to(st, .Install)
}

// poll_install moves to Done when the worker has finished well. A failure
// stays on the install page, which shows it.
poll_install :: proc(st: ^St) {
	if st.page != .Install || st.worker == nil {
		return
	}
	snap := worker_snapshot(st.worker, 1)
	if snap.finished && snap.ok {
		move_to(st, .Done)
	}
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

// matches is the search box's test: every word of the query appears,
// case-insensitively, somewhere in the haystacks.
matches :: proc(query: string, hay: ..string) -> bool {
	q := strings.trim_space(query)
	if q == "" {
		return true
	}
	joined := strings.to_lower(strings.join(hay, " ", context.temp_allocator), context.temp_allocator)
	joined, _ = strings.replace_all(joined, "_", " ", context.temp_allocator)
	for word in strings.fields(strings.to_lower(q, context.temp_allocator), context.temp_allocator) {
		if !strings.contains(joined, word) {
			return false
		}
	}
	return true
}

// filtered_layouts / filtered_zones are the visible rows, as indexes into
// `layouts` and `zones`.
filtered_layouts :: proc(st: ^St, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	q := string(st.kb_search[:])
	for idx, li in st.layouts {
		k := st.keyboards[idx]
		if matches(q, k.description, k.layout) {
			append(&out, li)
		}
	}
	return out[:]
}

filtered_zones :: proc(st: ^St, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, allocator)
	q := string(st.zone_search[:])
	for z, i in st.zones {
		if matches(q, z.name, z.city, z.country) {
			append(&out, i)
		}
	}
	return out[:]
}

// step_in moves a selection by `d` rows through a filtered list, so the
// arrows walk what is on screen and not what the search has hidden.
step_in :: proc(visible: []int, current: int, d: int) -> int {
	if len(visible) == 0 {
		return current
	}
	at := -1
	for v, i in visible {
		if v == current {
			at = i
			break
		}
	}
	if at < 0 {
		return visible[d < 0 ? len(visible) - 1 : 0]
	}
	return visible[clamp(at + d, 0, len(visible) - 1)]
}

// ---------------------------------------------------------------------------
// Local time in the chosen zone
// ---------------------------------------------------------------------------

// zone_offset is the chosen zone's UTC offset right now, from its TZif file,
// with the region cached until the selection changes.
zone_offset :: proc(st: ^St, now: time.Time) -> (offset: i64, abbrev: string, ok: bool) {
	z := cur_zone(st)
	if st.tz_loaded != z.name {
		st.tz_loaded = strings.clone(z.name)
		st.tz_region = load_region(z.name)
	}
	if st.tz_region == nil {
		return 0, "", false
	}
	rec, found := region_record(st.tz_region, now)
	if !found {
		return 0, "", false
	}
	return rec.utc_offset, rec.shortname, true
}
