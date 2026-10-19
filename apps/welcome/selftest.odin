package main

// `welcome --selftest`: everything that can be checked without a server.
//
//   - every msgid in the source is in all five catalogues, with the same
//     %-conversions (the msgids are found by scanning the source, as the
//     installer's selftest does, so a string cannot be added untranslated);
//   - handles, monograms, sync.conf and the marker;
//   - the flow: which steps exist on each path, what Next refuses and why,
//     what Skip does;
//   - every page drawn in every language, light and dark, with balanced
//     open/end calls, and laid out right to left in Arabic.
//
// The live end to end (a fresh user, a real server, typed keys) is
// `welcome drive`, run by apps/welcome/e2e.sh.

import "core:fmt"
import "core:os"
import "core:strings"
import ck "../cloudkit"
import kit "kit:."
import p "palmy:."

@(private = "file")
SOURCES := [?]string {
	#load("pages.odin", string),
	#load("ui.odin", string),
	#load("flow.odin", string),
	#load("core.odin", string),
	#load("worker.odin", string),
	#load("kitpage.odin", string),
	#load("model.odin", string),
	#load("shot.odin", string),
	#load("drive.odin", string),
	#load("cli.odin", string),
}

@(private = "file")
T :: struct {
	passed, failed: int,
}

@(private = "file")
check :: proc(t: ^T, ok: bool, what: string, args: ..any) {
	if ok {
		t.passed += 1
	} else {
		t.failed += 1
		fmt.eprintfln("FAIL %s", fmt.tprintf(what, ..args))
	}
}

// msgids scans the source for tr("…"), trf("…") and N("…").
msgids :: proc(allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for src in SOURCES {
		i := 0
		for i < len(src) {
			j := -1
			plen := 0
			for pat in ([?]string{"tr(\"", "trf(\"", "N(\""}) {
				k := strings.index(src[i:], pat)
				if k >= 0 && (j < 0 || i + k < j) {
					j = i + k
					plen = len(pat)
				}
			}
			if j < 0 {
				break
			}
			// Not a longer identifier ending in tr( or N(.
			if j > 0 {
				c := src[j - 1]
				if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.' {
					i = j + plen
					continue
				}
			}
			b := strings.builder_make(allocator)
			k := j + plen
			for k < len(src) && src[k] != '"' {
				if src[k] == '\\' && k + 1 < len(src) {
					k += 1
					switch src[k] {
					case 'n':
						strings.write_byte(&b, '\n')
					case 't':
						strings.write_byte(&b, '\t')
					case:
						strings.write_byte(&b, src[k])
					}
				} else {
					strings.write_byte(&b, src[k])
				}
				k += 1
			}
			id := strings.to_string(b)
			// The scanner's own patterns are not msgids.
			if id != "" && !strings.contains(id, "\"") && !seen[id] && id != "\\" {
				seen[id] = true
				append(&out, id)
			}
			i = k + 1
		}
	}
	return out[:]
}

conversions :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s) - 1; i += 1 {
		if s[i] == '%' {
			strings.write_byte(&b, s[i + 1])
			i += 1
		}
	}
	return strings.to_string(b)
}

CATALOGUE_LANGS := [?]string{"fr", "de", "es", "ar", "ja"}

selftest :: proc() -> int {
	t: T
	find_checkout_catalogues()

	// --- catalogues --------------------------------------------------------
	ids := msgids()
	if os.get_env("WELCOME_DUMP_MSGIDS", context.temp_allocator) != "" {
		for id in ids {
			fmt.println(ck.quote(id))
		}
		return 0
	}
	check(&t, len(ids) > 150, "found %d msgids in the source, expected more than 150", len(ids))
	root := kit.i18n_root()
	for lang in CATALOGUE_LANGS {
		path := fmt.tprintf("%s/%s/%s.msg", root, lang, DOMAIN)
		cat, ok := kit.i18n_load_file(path, lang)
		check(&t, ok, "%s loads", path)
		if !ok {
			continue
		}
		missing := 0
		for id in ids {
			tr_, found := kit.i18n_lookup(&cat, id)
			if !found || tr_ == "" {
				if missing < 5 {
					fmt.eprintfln("  %s: missing %q", lang, id)
				}
				missing += 1
				continue
			}
			check(&t, conversions(tr_) == conversions(id), "%s: %q keeps the conversions of %q", lang, tr_, id)
		}
		check(&t, missing == 0, "%s: %d of %d msgids untranslated", lang, missing, len(ids))
		kit.i18n_catalog_destroy(&cat)
	}

	// --- handles and letters -----------------------------------------------
	check(&t, handle_from("Camille at Northwind") == "camille.northwind", "handle_from drops 'at': %q", handle_from("Camille at Northwind"))
	check(&t, handle_from("Zoë Ünal") == "zoe.unal", "handle_from folds accents: %q", handle_from("Zoë Ünal"))
	check(&t, handle_from("  Ada  Lovelace ") == "ada.lovelace", "handle_from trims: %q", handle_from("  Ada  Lovelace "))
	check(&t, handle_problem("camille.roux") == "", "a good handle passes")
	check(&t, handle_problem("a") != "", "a one-letter handle is refused")
	check(&t, handle_problem("admin") == N("That handle is reserved."), "a reserved handle is refused")
	check(&t, handle_problem("Camille") != "", "upper case is refused")
	check(&t, handle_problem(".dot") != "", "a leading dot is refused")
	{
		st := new(St)
		st_init(st, {fixture = true})
		a := add_plan(st, 0, "Camille Roux")
		b := add_plan(st, 1, "Camille at Northwind")
		check(&t, plan_mono(st, a) == "C" && plan_mono(st, b) == "N", "monograms C and N, got %s and %s", plan_mono(st, a), plan_mono(st, b))
		check(&t, a.color != b.color, "two identities do not share a hue")
		check(&t, .Mail in a.services && .Chat in b.services && .Chat not_in a.services, "defaults by kind")
		check(&t, email_ok("a@example.org") && !email_ok("a@b") && !email_ok("no at") && !email_ok("a@@b.c"), "email_ok")
	}

	// --- files ---------------------------------------------------------------
	scratch := fmt.aprintf("%s/welcome-selftest-%d", os.get_env("XDG_RUNTIME_DIR", context.temp_allocator) != "" ? os.get_env("XDG_RUNTIME_DIR", context.temp_allocator) : "/tmp", os.get_pid())
	os.make_directory_all(scratch, os.perm(0o700))
	defer os.remove_all(scratch)
	old_state := strings.clone(os.get_env("XDG_STATE_HOME", context.temp_allocator))
	old_config := strings.clone(os.get_env("XDG_CONFIG_HOME", context.temp_allocator))
	os.set_env("XDG_STATE_HOME", fmt.tprintf("%s/state", scratch))
	os.set_env("XDG_CONFIG_HOME", fmt.tprintf("%s/config", scratch))
	{
		check(&t, !read_marker().done, "no marker in a fresh home")
		check(&t, write_marker("local"), "the marker is written")
		m := read_marker()
		check(&t, m.done && m.mode == "local" && len(m.completed_at) == 20, "the marker reads back: %v", m)
		check(&t, remove_marker() && !read_marker().done, "reset removes it")
		check(&t, !remove_marker(), "a second reset has nothing to remove")

		st := new(St)
		st_init(st, {fixture = true})
		a := add_plan(st, 0, "Camille Roux")
		a.existing = true
		a.id = "x"
		a.services = {.Mail, .Drive, .Passwords}
		b := add_plan(st, 1, "Camille at Northwind")
		b.existing = true
		b.id = "y"
		b.services = {.Drive}
		c := add_plan(st, 2, "Not created")
		c.services = {.Mail}
		check(&t, write_text(sync_conf_path(), sync_conf_text("account", "http://127.0.0.1:54321", st.plans[:])), "sync.conf is written")
		sc, ok := read_sync_conf()
		check(&t, ok && sc.mode == "account" && len(sc.entries) == 2, "sync.conf reads back two identities (the uncreated one is left out): %v", sc)
		if ok && len(sc.entries) == 2 {
			check(&t, sc.entries[0].handle == "camille.roux" && sc.entries[0].services == {.Mail, .Drive, .Passwords}, "first entry: %v", sc.entries[0])
			check(&t, sc.entries[1].handle == "camille.northwind" && sc.entries[1].services == {.Drive}, "second entry: %v", sc.entries[1])
		}
		check(&t, save_appearance(false) && !theme_from_environment_file(), "appearance light round trip")
		check(&t, save_appearance(true) && theme_from_environment_file(), "appearance dark round trip")
		check(&t, save_language("fr_FR"), "locale.conf is written")
		text, _ := read_text(locale_conf_path())
		check(&t, strings.contains(text, "LANG=fr_FR.UTF-8"), "locale.conf says LANG=fr_FR.UTF-8")
	}
	os.set_env("XDG_STATE_HOME", old_state)
	os.set_env("XDG_CONFIG_HOME", old_config)

	// --- the flow --------------------------------------------------------------
	{
		st := new(St)
		st_init(st, {fixture = true})
		check(&t, !can_skip(st), "the first page cannot be skipped")
		go_next(st)
		check(&t, st.step == .Account, "Welcome → Account")
		ok, why := can_leave(st)
		check(&t, !ok && why != "", "Account needs a choice")
		skip(st)
		check(&t, st.mode == .Local && st.step == .Import, "skipping the account means this computer only, and goes to Import")
		for s in CLOUD_STEPS {
			check(&t, !step_used(st, s), "local: %v is not a step", s)
		}
		_, total := step_number(st)
		check(&t, total == 5, "local: five steps, got %d", total)
		go_next(st)
		go_next(st)
		check(&t, st.step == .Done, "Import → Tour → Done")
		go_back(st)
		check(&t, st.step == .Done, "there is no Back from Done")
		go_next(st)
		check(&t, st.finished, "Done's Enter finishes")

		a := new(St)
		st_init(a, {fixture = true})
		a.step = .Account
		a.choice = .Account
		go_next(a)
		check(&t, a.step == .Sign_In && a.mode == .Account, "Account → Sign in")
		set_buf(&a.name_buf, "Camille Roux")
		set_buf(&a.email_buf, "camille@example")
		check(&t, auth_problem(a) == N("Enter a valid email address."), "a bad email is refused")
		set_buf(&a.email_buf, "camille@example.org")
		set_buf(&a.pw_buf, "short")
		check(&t, auth_problem(a) == N("The password needs at least 8 characters."), "a short password is refused")
		set_buf(&a.pw_buf, "long enough")
		set_buf(&a.pw2_buf, "long enougj")
		check(&t, auth_problem(a) == N("The passwords do not match."), "a mismatch is refused")
		set_buf(&a.pw2_buf, "long enough")
		check(&t, auth_problem(a) == "", "a good form passes")
		a.auth_tab = .Sign_In
		clear(&a.name_buf)
		check(&t, auth_problem(a) == "", "signing in needs no name")

		a.step = .Identities
		clear(&a.plans)
		check(&t, identities_problem(a) != "", "no identity is refused")
		x := add_plan(a, 0, "Camille Roux")
		y := add_plan(a, 1, "")
		check(&t, identities_problem(a) == N("Every identity needs a name."), "a nameless identity is refused")
		set_buf(&y.name, "Other")
		set_buf(&y.handle, plan_handle(x))
		check(&t, identities_problem(a) == N("Two identities cannot have the same handle."), "a duplicate handle is refused")
		set_buf(&y.handle, "camille.other")
		check(&t, identities_problem(a) == "", "two good rows pass")

		for &pl in a.plans {
			pl.existing = true
			pl.services -= {.Passwords}
		}
		a.step = .Sync
		check(&t, step_used(a, .Passwords), "Passwords is counted until the Sync page is left")
		go_next(a)
		check(&t, a.step == .Setup, "no passwords chosen: Sync → Setup")
		check(&t, !step_used(a, .Passwords), "and Passwords drops out of the rail")
		a.step = .Sync
		a.plans[0].services += {.Passwords}
		go_next(a)
		check(&t, a.step == .Passwords, "passwords chosen: Sync → Passwords")
		set_buf(&a.vault_pw, "short")
		check(&t, vault_problem(a) != "", "a short master password is refused")
		set_buf(&a.vault_pw, "long enough")
		set_buf(&a.pw_buf, "long enough")
		check(&t, vault_problem(a) == N("The master password needs at least 10 characters.") || vault_problem(a) == N("Use a different password from your account password."), "the account password is refused as a master password")
		set_buf(&a.vault_pw, "a different sentence")
		set_buf(&a.vault_pw2, "a different sentence")
		check(&t, vault_problem(a) == "", "a good master password passes")
		a.vault_done = true
		a.secret = "PV1-X"
		ok2, _ := can_leave(a)
		check(&t, !ok2, "the kit must be acknowledged before leaving")
		check(&t, !can_skip(a), "the vault page cannot be skipped once the vault exists")
		a.kit_ack = true
		ok3, _ := can_leave(a)
		check(&t, ok3, "acknowledged, it can be left")

		plan_tasks(a)
		check(&t, len(a.tasks) > 4 && a.tasks[0].what == .Sync_Conf, "setup plans its tasks, choices first")
		mail_client_seen := false
		for tk in a.tasks {
			if tk.what == .Mail_Client {
				mail_client_seen = true
			}
			check(&t, tk.state == .Waiting, "nothing runs before Set up is pressed")
		}
		check(&t, mail_client_seen, "mail on this computer is one task for the account")
	}

	// --- outcomes ---------------------------------------------------------------
	{
		s, _ := outcome({found = false})
		check(&t, s == .Not_Installed, "a missing program is Not installed")
		s, _ = outcome({found = true, code = 0})
		check(&t, s == .Done, "exit 0 is Done")
		s, _ = outcome({found = true, code = 6, out = `{"error":"unavailable","detail":"no server"}`})
		check(&t, s == .Pending_Server, "exit 6 waits for the server")
		s, _ = outcome({found = true, code = 2, err = "notes: unknown command \"sync\""})
		check(&t, s == .Coming, "an unknown verb is Coming")
		s2, why := outcome({found = true, code = 7, out = `{"error":"failed","detail":"disk full"}`})
		check(&t, s2 == .Failed && why == "disk full", "a failure keeps its reason: %q", why)
		os.set_env("WELCOME_BIN_DIR", "/nonexistent-welcome")
		_, found := find_tool("sh")
		check(&t, found, "find_tool searches PATH after WELCOME_BIN_DIR")
		_, nf := find_tool("no-such-program-welcome")
		check(&t, !nf, "find_tool says when a program is missing")
		os.unset_env("WELCOME_BIN_DIR")
	}

	// --- every page, every language ------------------------------------------------
	{
		off := p.offscreen_create(SHOT_W, SHOT_H, 1, "w-full h-full bg-background text-foreground")
		defer p.offscreen_destroy(off)
		kit_fonts(&off.fonts)
		before := shot_unbalanced
		for lang in ([?]string{"en_US", "fr_FR", "de_DE", "es_ES", "ar", "ja_JP"}) {
			set_language(lang)
			for dark in ([?]bool{false, true}) {
				register_theme(dark)
				for step in Step {
					st := fixture_state(lang, dark)
					st.mode = step in CLOUD_STEPS || step == .Done ? .Account : .Undecided
					st.signed_in = step > .Sign_In
					st.email = "camille@example.org"
					if step >= .Identities {
						fixture_identities(st, step > .Identities)
					}
					if step == .Setup {
						fixture_setup(st, true)
					}
					st.step = step
					for _ in 0 ..< 2 {
						shot_frame(off, st)
					}
					if lang == "ar" && step == .Welcome && !dark {
						check(&t, is_rtl(), "Arabic is right to left")
						check(&t, brand_x(&off.ctx) > SHOT_W / 2, "Arabic: the rail is on the right (brand at x=%v)", brand_x(&off.ctx))
					}
					if lang == "en_US" && step == .Welcome && !dark {
						check(&t, brand_x(&off.ctx) < SHOT_W / 2, "English: the rail is on the left")
					}
				}
			}
		}
		check(&t, shot_unbalanced == before, "every page closes what it opens (%d unbalanced)", shot_unbalanced - before)

		// A password is never on screen in clear, not even while a job runs
		// and the fields are disabled.
		set_language("en_US")
		for step in ([?]Step{.Sign_In, .Passwords}) {
			st := fixture_state("en_US", true)
			st.mode = .Account
			st.step = step
			set_buf(&st.pw_buf, "hunter2 secret words")
			set_buf(&st.pw2_buf, "hunter2 secret words")
			set_buf(&st.vault_pw, "hunter2 secret words")
			set_buf(&st.vault_pw2, "hunter2 secret words")
			fixture_identities(st, true)
			for busy_ in ([?]bool{false, true}) {
				st.job.running = busy_
				shot_frame(off, st)
				leaked := false
				for n in off.ctx.nodes {
					if strings.contains(n.text, "hunter2") {
						leaked = true
					}
				}
				check(&t, !leaked, "%v page, busy=%v: the password is masked", step, busy_)
			}
			st.job.running = false
		}
		set_language("")
	}

	fmt.printfln("welcome --selftest: %d passed, %d failed", t.passed, t.failed)
	return t.failed == 0 ? 0 : 1
}

// brand_x is where the rail's "Palmframe" sits: left of centre in a
// left-to-right interface, right of it in a right-to-left one.
brand_x :: proc(ctx: ^p.Ctx) -> f32 {
	for n in ctx.nodes {
		if n.text == "Palmframe" {
			return n.rect.x
		}
	}
	return -1
}

// theme_from_environment_file is theme_from_environment without PALM_THEME,
// so the test reads the file it just wrote.
theme_from_environment_file :: proc() -> bool {
	old := strings.clone(os.get_env("PALM_THEME", context.temp_allocator))
	os.unset_env("PALM_THEME")
	defer if old != "" {os.set_env("PALM_THEME", old)}
	return theme_from_environment()
}
