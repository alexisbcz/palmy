package main

// `installer --selftest`: everything that can be checked without a screen.
//
//   - the step flow: what Next, Back and the rail allow, the erase
//     confirmation, and the plan that comes out the end;
//   - the account rules and the password hint;
//   - the language defaults, the search and the progress arithmetic;
//   - the demo install, run for real on its worker thread (sped up);
//   - right to left: an Arabic catalogue flips the layout, measured offscreen;
//   - the catalogues: every msgid in this package's source exists, translated,
//     in every distro/locale/*/installer.msg, with the same format verbs and
//     placeholders.
//
// Run it from the repository root (it looks for apps/installer and
// distro/locale there, or above the current directory). It only uses the
// demo backend.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import kit "kit:."
import p "palmy:."

@(private = "file")
failures: int
@(private = "file")
checks: int

@(private = "file")
check :: proc(name: string, ok: bool, detail := "") {
	checks += 1
	if !ok {
		failures += 1
	}
	fmt.printfln("%s  %-60s  %s", ok ? "pass" : "FAIL", name, detail)
}

selftest :: proc() -> int {
	set_language("en_US")
	test_flow()
	test_account()
	test_defaults_and_search()
	test_progress()
	test_demo_install()
	test_rtl()
	test_catalogues()
	test_data_catalogues()
	fmt.println(strings.repeat("-", 72, context.temp_allocator))
	fmt.printfln("%d checks, %d failed", checks, failures)
	return failures == 0 ? 0 : 1
}

@(private = "file")
demo_state :: proc() -> ^St {
	st := new(St)
	state_init(st, Backend{demo = true})
	return st
}

@(private = "file")
fill_account :: proc(st: ^St) {
	clear(&st.full_name)
	append(&st.full_name, "Ada Lovelace")
	full_name_changed(st)
	clear(&st.password)
	clear(&st.confirm)
	append(&st.password, "analytical engine")
	append(&st.confirm, "analytical engine")
}

@(private = "file")
test_flow :: proc() {
	st := demo_state()
	check("flow: starts on the language page", st.page == .Language)
	check("flow: Back is not offered on the first page", !can_go_back(st))

	go_next(st)
	check("flow: Next goes to the keyboard", st.page == .Keyboard)
	go_back(st)
	check("flow: Back returns to the language", st.page == .Language)
	go_to(st, .Disk)
	check("flow: the rail cannot jump ahead to a page not yet visited", st.page == .Language)
	go_to(st, .Keyboard)
	check("flow: the rail can return to a visited page", st.page == .Keyboard)

	go_next(st) // timezone
	go_next(st) // disk
	check("flow: reached the disk page", st.page == .Disk)
	go_next(st)
	_, why := can_leave(st)
	check("flow: no disk chosen, Next does nothing", st.page == .Disk && !st.confirm_open, why)

	// The fabricated disks: 0 nvme (partitions), 1 vda, 2 the live USB, 3 a 2 GB card.
	pick_disk(st, 2)
	check("flow: the live medium cannot be chosen", st.disk_i == -1)
	pick_disk(st, 3)
	check("flow: a disk under 4 GiB cannot be chosen", st.disk_i == -1)
	pick_disk(st, 1)
	check("flow: an empty virtio disk can be chosen", st.disk_i == 1)

	go_next(st)
	check("flow: Next on the disk page asks for confirmation first", st.confirm_open && st.page == .Disk)
	go_next(st)
	check("flow: Enter does not confirm the dialog", st.confirm_open && st.confirmed == "")
	go_back(st)
	check("flow: Esc closes the dialog without erasing anything", !st.confirm_open && st.confirmed == "" && st.page == .Disk)
	go_next(st)
	confirm_erase(st)
	check("flow: confirming names the device and moves on", st.confirmed == "/dev/vda" && st.page == .Account)

	go_next(st)
	f, _ := st.focus_field.?
	check("flow: an empty account stops Next and shows its problems", st.page == .Account && st.tried, fmt.tprintf("focus %v", f))
	check("flow: the keyboard goes to the first problem (user name)", f == .User)

	fill_account(st)
	check("flow: the user name follows the full name", string(st.user[:]) == "ada", string(st.user[:]))
	go_next(st)
	check("flow: a complete account goes to the summary", st.page == .Summary)

	plan := plan_of(st)
	check("plan: disk", plan.disk == "/dev/vda", plan.disk)
	check("plan: user", plan.user == "ada" && plan.full_name == "Ada Lovelace")
	check("plan: hostname default", plan.hostname == "palmy", plan.hostname)
	check("plan: root password empty means same as the user's", plan.root_password == "")
	check("plan: language and keyboard", plan.language == "en_US" && plan.keyboard.layout == "us", fmt.tprintf("%s %s", plan.language, plan.keyboard.layout))
	check("plan: time zone", plan.timezone == "America/New_York", plan.timezone)
	check("plan: EFI boot entry exactly when booted by UEFI", plan.efi_boot_entry == os.is_dir("/sys/firmware/efi"))
	check("plan: the default package set (left to the core)", len(plan.packages) == 0)

	st.same_root = false
	append(&st.root_password, "toor-toor")
	append(&st.root_confirm, "toor-toor")
	check("plan: a separate root password is carried", plan_of(st).root_password == "toor-toor")
	st.same_root = true

	go_to(st, .Disk)
	pick_disk(st, 0)
	check("flow: choosing another disk withdraws the confirmation", st.confirmed == "")
	go_next(st)
	check("flow: ...so the other disk is confirmed afresh", st.confirm_open)
	cancel_erase(st)
	pick_disk(st, 1)

	// One usable disk is preselected; two are not.
	qemu := []Disk{{path = "/dev/sr0", name = "sr0", size_bytes = 100 << 20, is_live_medium = true}, {path = "/dev/vda", name = "vda", size_bytes = 8 << 30}}
	check("disk: the only usable disk is preselected", preselect_disk(qemu) == 1)
	check("disk: with several usable disks none is", preselect_disk(demo_disks()) == -1 && demo_state().disk_i == -1)
	check("disk: with none usable, none is", preselect_disk(qemu[:1]) == -1)

	// A language whose script has no font.
	st2 := demo_state()
	for &l, i in st2.languages {
		if strings.has_prefix(l.code, "ja") {
			l.available = false
			pick_language(st2, i)
		}
	}
	go_next(st2)
	check("flow: an unavailable language cannot be continued with", st2.page == .Language)
	for &l, i in st2.languages {
		if strings.has_prefix(l.code, "ja") {
			l.available = true
			pick_language(st2, i)
		}
	}
	ja := plan_of(st2)
	check("plan: Japanese brings the CJK font along", len(ja.packages) == 2 && ja.packages[1] == "fonts-cjk", fmt.tprintf("%v", ja.packages))
	pick_language(st2, 0)

	// Install, then no way back.
	st3 := demo_state()
	st3.page = .Install
	check("flow: no Back during the install", !can_go_back(st3))
	st3.visited = {.Language, .Keyboard}
	check("flow: no rail jumps during the install", !can_go_to(st3, .Language))
}

@(private = "file")
test_account :: proc() {
	ok_user := [?]string{"ada", "_svc", "a1-b_c", "palm"}
	bad_user := [?]string{"", "Ada", "1ada", "ada lovelace", "ada:x", "root", "greeter", "élodie", "abcdefghijabcdefghijabcdefghijabc"}
	for u in ok_user {
		check(fmt.tprintf("user name %q accepted", u), user_problem(u) == "", user_problem(u))
	}
	for u in bad_user {
		check(fmt.tprintf("user name %q refused", u), user_problem(u) != "", user_problem(u))
	}

	ok_host := [?]string{"palmy", "atelier-2", "A1"}
	bad_host := [?]string{"", "-atelier", "atelier-", "my host", "host.local", "ordinateur_de_marie"}
	for h in ok_host {
		check(fmt.tprintf("host name %q accepted", h), hostname_problem(h) == "", hostname_problem(h))
	}
	for h in bad_host {
		check(fmt.tprintf("host name %q refused", h), hostname_problem(h) != "", hostname_problem(h))
	}

	a := Account{user = "ada", hostname = "palmy", password = "x", confirm = "y", same_root = true}
	pr := validate_account(a)
	check("account: mismatched passwords are reported on the confirmation", pr[.Confirm] != "" && pr[.Password] == "")
	a.confirm = "x"
	check("account: matching passwords pass", account_ok(validate_account(a)))
	a.full_name = "Lovelace, Ada"
	check("account: a comma in the full name is refused (GECOS)", validate_account(a)[.Full_Name] != "")
	a.full_name = ""
	check("account: the full name is optional", account_ok(validate_account(a)))
	a.same_root = false
	pr = validate_account(a)
	check("account: a separate root password must be given", pr[.Root_Password] != "")
	a.root_password = "r"
	a.root_confirm = "s"
	check("account: ...and confirmed", validate_account(a)[.Root_Confirm] != "")

	check("strength: empty", password_strength("") == .None)
	check("strength: 'palm' is weak", password_strength("palm") == .Weak)
	check("strength: 'Tr0ub4dor' is fair", password_strength("Tr0ub4dor") == .Fair, fmt.tprintf("%v", password_strength("Tr0ub4dor")))
	check("strength: a long passphrase is strong", password_strength("correct horse battery staple") == .Strong, fmt.tprintf("%v", password_strength("correct horse battery staple")))

	check("suggest: Élodie Martin -> elodie", suggest_user("Élodie Martin", context.temp_allocator) == "elodie")
	check("suggest: José -> jose", suggest_user("José", context.temp_allocator) == "jose")
	check("suggest: an Arabic name gives nothing", suggest_user("محمد", context.temp_allocator) == "")
	check("suggest: leading digits dropped", suggest_user("2Pac", context.temp_allocator) == "pac")
}

@(private = "file")
test_defaults_and_search :: proc() {
	st := demo_state()
	idx := proc(st: ^St, prefix: string) -> int {
		for l, i in st.languages {
			if strings.has_prefix(l.code, prefix) {
				return i
			}
		}
		return -1
	}
	pick_language(st, idx(st, "fr"))
	check("defaults: French picks the French layout", cur_keyboard(st).layout == "fr", cur_keyboard(st).layout)
	check("defaults: ...and Europe/Paris", cur_zone(st).name == "Europe/Paris", cur_zone(st).name)
	check("defaults: French translates the interface", tr("Next") != "Next", tr("Next"))
	check("defaults: ...and the following layout is sent to the compositor", st.kb_dirty)
	settle_keyboard(st, 1)

	for z, i in st.zones {
		if z.name == "Asia/Tokyo" {
			pick_zone(st, i)
		}
	}
	pick_language(st, idx(st, "de"))
	check("defaults: a zone chosen by hand stays when the language changes", cur_zone(st).name == "Asia/Tokyo", cur_zone(st).name)
	check("defaults: the layout still follows", cur_keyboard(st).layout == "de", cur_keyboard(st).layout)
	pick_language(st, idx(st, "en"))

	check("search: case and underscores do not matter", matches("buenos aires", "America/Argentina/Buenos_Aires"))
	check("search: every word must appear", !matches("paris tokyo", "Europe/Paris", "Paris", "FR"))
	check("search: a country name finds its zones", matches("japan", "Asia/Tokyo", "Tokyo", "Japan"))
	clear(&st.zone_search)
	append(&st.zone_search, "europe")
	v := filtered_zones(st)
	all_europe := len(v) > 0
	for i in v {
		all_europe &&= strings.has_prefix(st.zones[i].name, "Europe/")
	}
	check("search: 'europe' lists only Europe/", all_europe, fmt.tprintf("%d rows", len(v)))
	check("search: arrows walk the visible rows", step_in({3, 7, 9}, 7, 1) == 9 && step_in({3, 7, 9}, 9, 1) == 9 && step_in({3, 7, 9}, 5, 1) == 3)

	clear(&st.kb_search)
	append(&st.kb_search, "dvorak")
	check("search: no layout without a variant is called dvorak", len(filtered_layouts(st)) == 0)
	clear(&st.kb_search)
	for li, i in st.layouts {
		if st.keyboards[li].layout == "fr" {
			pick_layout(st, i, 0)
		}
	}
	vs := variants_of(st)
	check("keyboard: French has its variants", len(vs) == 3, fmt.tprintf("%d", len(vs)))
	pick_variant(st, "bepo", 0)
	check("keyboard: the chosen variant is the current keyboard", cur_keyboard(st).variant == "bepo" && cur_keyboard(st).description == "French (BEPO)")
	settle_keyboard(st, 0.1)
	check("keyboard: not applied before it settles", st.kb_dirty)
	settle_keyboard(st, 1)
	check("keyboard: applied (demo: only described) once settled", !st.kb_dirty && strings.has_prefix(st.kb_said, "demo:"), st.kb_said)

	now := time.unix(1_791_900_300, 0) // 2026-10-13 14:05 UTC
	for z, i in st.zones {
		if z.name == "Europe/Paris" {
			st.zone_i = i
		}
	}
	off, abbrev, known := zone_offset(st, now)
	if known {
		check("clock: Paris is UTC+2 in October (CEST)", off == 7200 && abbrev == "CEST", fmt.tprintf("%d %s", off, abbrev))
	} else {
		check("clock: no zoneinfo on this machine (skipped)", true)
	}
	check("clock: offset labels", offset_label(19800) == "UTC+05:30" && offset_label(-10800) == "UTC−03:00" && offset_label(0) == "UTC")
}

@(private = "file")
test_progress :: proc() {
	last: f32 = -1
	monotonic := true
	for s in Install_Step {
		for f in ([?]f32{0, 0.5, 1}) {
			v := overall_fraction(s, f)
			if v < last {
				monotonic = false
			}
			last = v
		}
	}
	check("progress: never goes backwards through the steps", monotonic)
	check("progress: starts at 0 and ends at 1", overall_fraction(.Partition, 0) == 0 && overall_fraction(.Done, 0) == 1)
	check("progress: packages are most of the bar", overall_fraction(.Configure, 0) - overall_fraction(.Packages, 0) > 0.5)
}

@(private = "file")
test_demo_install :: proc() {
	st := demo_state()
	demo_time_scale = 0.02
	defer demo_time_scale = 1
	pick_disk(st, 1)
	st.confirmed = "/dev/vda"
	fill_account(st)
	st.page = .Summary
	go_next(st)
	check("install: Install starts the worker and shows its page", st.worker != nil && st.page == .Install)
	deadline := time.tick_now()
	saw_packages := false
	for time.tick_since(deadline) < 20 * time.Second {
		snap := worker_snapshot(st.worker, 5)
		if snap.progress.step == .Packages {
			saw_packages = true
		}
		poll_install(st)
		if snap.finished {
			break
		}
		time.sleep(5 * time.Millisecond)
	}
	snap := worker_snapshot(st.worker, 1000)
	check("install: the demo install finished, and well", snap.finished && snap.ok, snap.err)
	check("install: progress was polled mid-way", saw_packages)
	check("install: success moves to the done page", st.page == .Done)
	check("install: every log line says it is a demo", all_demo(snap.log), fmt.tprintf("%d lines", len(snap.log)))

	st2 := demo_state()
	st2.backend.demo_fail = true
	pick_disk(st2, 1)
	st2.confirmed = "/dev/vda"
	fill_account(st2)
	st2.page = .Summary
	go_next(st2)
	for !worker_snapshot(st2.worker, 1).finished {
		time.sleep(5 * time.Millisecond)
	}
	poll_install(st2)
	s2 := worker_snapshot(st2.worker, 1000)
	check("install: a failure stays on the install page with its error", st2.page == .Install && !s2.ok && s2.err != "", s2.err)
}

@(private = "file")
all_demo :: proc(lines: []string) -> bool {
	for l in lines {
		if !strings.has_prefix(l, "demo:") {
			return false
		}
	}
	return len(lines) > 0
}

@(private = "file")
test_rtl :: proc() {
	set_language("ar")
	check("rtl: Arabic is right to left", is_rtl())
	check("rtl: the Arabic catalogue is loaded", tr("Next") != "Next", tr("Next"))

	off := p.offscreen_create(400, 100, 1, "w-full h-full")
	defer p.offscreen_destroy(off)
	a, b: int
	for _ in 0 ..< 2 {
		ui := p.offscreen_begin(off)
		r := p.row(ui, "w-full gap-2 dir-rtl")
		a = p.div(ui, "w-10 h-10")
		p.end(ui)
		b = p.div(ui, "w-20 h-10")
		p.end(ui)
		p.end(ui)
		_ = r
		p.offscreen_end(off)
	}
	ra := p.node_rect(&off.ctx, a)
	rb := p.node_rect(&off.ctx, b)
	check("rtl: a row's first child is on the right", ra.x > rb.x, fmt.tprintf("first x=%v second x=%v", ra.x, rb.x))
	check("rtl: ...and the row hugs the right edge", ra.x + ra.w >= 399, fmt.tprintf("right edge %v", ra.x + ra.w))

	set_language("fr_FR")
	check("rtl: French is left to right", !is_rtl())
	set_language("en_US")
}

// ---------------------------------------------------------------------------
// Catalogues
// ---------------------------------------------------------------------------

@(private = "file")
find_root :: proc() -> string {
	dir, _ := os.get_working_directory(context.temp_allocator)
	for _ in 0 ..< 6 {
		if os.exists(fmt.tprintf("%s/apps/installer/main.odin", dir)) {
			return dir
		}
		dir = filepath.dir(dir)
	}
	return ""
}

// source_msgids collects the literal argument of every tr(, trf( and N( call
// in the package's .odin files, skipping comment lines.
source_msgids :: proc(src_dir: string) -> []string {
	set := make(map[string]bool, context.temp_allocator)
	f, err := os.open(src_dir)
	if err != nil {
		return nil
	}
	defer os.close(f)
	infos, _ := os.read_dir(f, -1, context.temp_allocator)
	for fi in infos {
		if !strings.has_suffix(fi.name, ".odin") {
			continue
		}
		data, rerr := os.read_entire_file(fi.fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		text := string(data)
		for line in strings.split_lines_iterator(&text) {
			if strings.has_prefix(strings.trim_space(line), "//") {
				continue
			}
			for marker in ([?]string{"tr(\"", "trf(\"", "N(\""}) {
				rest := line
				for {
					i := strings.index(rest, marker)
					if i < 0 {
						break
					}
					// `str(` and friends end in "tr(" too: require a boundary.
					if i > 0 {
						c := rest[i - 1]
						if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
							rest = rest[i + len(marker):]
							continue
						}
					}
					rest = rest[i + len(marker) - 1:]
					lit, n := read_literal(rest)
					if n > 0 {
						set[lit] = true
					}
					rest = rest[max(n, 1):]
				}
			}
		}
	}
	out := make([dynamic]string)
	for k in set {
		append(&out, strings.clone(k))
	}
	slice.sort(out[:])
	return out[:]
}

// read_literal reads an Odin "..." literal at the start of s, unescaped.
@(private = "file")
read_literal :: proc(s: string) -> (lit: string, n: int) {
	if len(s) == 0 || s[0] != '"' {
		return "", 0
	}
	i := 1
	for i < len(s) {
		if s[i] == '\\' {
			i += 2
			continue
		}
		if s[i] == '"' {
			return unescape(s[1:i]), i + 1
		}
		i += 1
	}
	return "", 0
}

// unescape resolves the escapes an Odin literal may hold in a msgid.
@(private = "file")
unescape :: proc(s: string) -> string {
	if strings.index_byte(s, '\\') < 0 {
		return s
	}
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\\' && i + 1 < len(s) {
			i += 1
			switch s[i] {
			case 'n':
				strings.write_byte(&b, '\n')
			case 't':
				strings.write_byte(&b, '\t')
			case:
				strings.write_byte(&b, s[i])
			}
			continue
		}
		strings.write_byte(&b, s[i])
	}
	return strings.to_string(b)
}

// verbs lists a format string's % verbs and {placeholders}, in order for the
// verbs (fmt is positional) and sorted for the placeholders (they are named).
@(private = "file")
verbs :: proc(s: string) -> (v: string, ph: string) {
	vb := strings.builder_make(context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(s); i += 1 {
		if s[i] == '%' && i + 1 < len(s) {
			if s[i + 1] == '%' {
				i += 1
				continue
			}
			j := i + 1
			for j < len(s) && strings.index_byte("0123456789.-+# ", s[j]) >= 0 {
				j += 1
			}
			if j < len(s) {
				strings.write_string(&vb, s[i:j + 1])
				strings.write_byte(&vb, ' ')
			}
			i = j
		} else if s[i] == '{' {
			if k := strings.index_byte(s[i:], '}'); k > 0 {
				append(&names, s[i:i + k + 1])
				i += k
			}
		}
	}
	slice.sort(names[:])
	return strings.to_string(vb), strings.join(names[:], " ", context.temp_allocator)
}

@(private = "file")
test_catalogues :: proc() {
	root := find_root()
	if root == "" {
		check("catalogues: run from the repository (apps/installer not found)", false)
		return
	}
	src_ids := source_msgids(fmt.tprintf("%s/apps/installer", root))
	check("catalogues: msgids found in the source", len(src_ids) > 100, fmt.tprintf("%d msgids", len(src_ids)))
	// The core's messages (validate problems, progress details) are
	// translated through the same catalogue, by text_tr.
	all_ids := make([dynamic]string, context.temp_allocator)
	append(&all_ids, ..src_ids)
	core_ids := core_message_msgids()
	check("catalogues: the core's messages are listed", len(core_ids) > 40, fmt.tprintf("%d messages", len(core_ids)))
	for id in core_ids {
		if !slice.contains(all_ids[:], id) {
			append(&all_ids, id)
		}
	}
	ids := all_ids[:]

	for lang in ([?]string{"fr", "de", "es", "ar", "ja"}) {
		path := fmt.tprintf("%s/distro/locale/%s/installer.msg", root, lang)
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			check(fmt.tprintf("catalogue %s: exists", lang), false, path)
			continue
		}
		c, perr := kit.i18n_parse(string(data))
		check(fmt.tprintf("catalogue %s: parses cleanly", lang), perr == "", perr)
		m := make(map[string]string, context.temp_allocator)
		for k, v in c.msgs {
			m[k] = len(v) > 0 ? v[0] : ""
		}
		check(fmt.tprintf("catalogue %s: says which language it is", lang), c.header["language"] == lang, c.header["language"])
		if lang == "ar" {
			check("catalogue ar: declares right to left", c.header["direction"] == "rtl")
		}
		missing := make([dynamic]string, context.temp_allocator)
		mismatched := make([dynamic]string, context.temp_allocator)
		for id in ids {
			tr_, ok := m[id]
			if !ok || tr_ == "" {
				append(&missing, id)
				continue
			}
			v1, p1 := verbs(id)
			v2, p2 := verbs(tr_)
			if v1 != v2 || p1 != p2 {
				append(&mismatched, id)
			}
		}
		check(
			fmt.tprintf("catalogue %s: every msgid is translated", lang),
			len(missing) == 0,
			len(missing) == 0 ? fmt.tprintf("%d entries", len(m)) : fmt.tprintf("%d missing, first %q", len(missing), missing[0]),
		)
		check(
			fmt.tprintf("catalogue %s: format verbs and placeholders match", lang),
			len(mismatched) == 0,
			len(mismatched) == 0 ? "" : fmt.tprintf("%d differ, first %q", len(mismatched), mismatched[0]),
		)
		stale := 0
		for k in m {
			if !slice.contains(ids, k) {
				stale += 1
			}
		}
		check(fmt.tprintf("catalogue %s: no stale entries", lang), stale == 0, fmt.tprintf("%d stale", stale))
	}
}

// The data catalogues (countries.msg, keyboards.msg): country names and
// layout descriptions follow the interface's language, and English stays
// English.
@(private = "file")
test_data_catalogues :: proc() {
	set_language("fr_FR")
	check("data: a country in French", country_name("DE", "Germany") == "Allemagne", country_name("DE", "Germany"))
	check("data: a layout in French", keyboard_name("German") == "Allemand", keyboard_name("German"))
	check("data: no translation keeps tzdata's name", country_name("", "Britain (UK)") == "Britain (UK)")
	st := demo_state()
	for l, i in st.languages {
		if l.code == "fr_FR" {pick_language(st, i)}
	}
	sorted := true
	for li in 1 ..< len(st.layouts) {
		a := strings.to_lower(keyboard_name(st.keyboards[st.layouts[li - 1]].description))
		b := strings.to_lower(keyboard_name(st.keyboards[st.layouts[li]].description))
		if a > b {sorted = false}
	}
	first := keyboard_name(st.keyboards[st.layouts[0]].description)
	check("data: the layout list is sorted in French", sorted && first != "Arabic", first)
	check("data: the French layout stays chosen", cur_keyboard(st).layout == "fr", cur_keyboard(st).layout)
	set_language("ja_JP")
	check("data: a country in Japanese", country_name("JP", "Japan") == "日本", country_name("JP", "Japan"))
	set_language("en_US")
	check("data: English is tzdata's", country_name("GB", "Britain (UK)") == "Britain (UK)")
	check("data: and base.lst's", keyboard_name("German") == "German")
}
