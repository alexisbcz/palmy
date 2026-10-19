package main

// The state machine: which steps exist for this run, what Next does on each,
// and what Skip means. Every step but the first and the last can be skipped,
// and skipping never does anything: it only moves on.

import "core:strings"
import ck "../cloudkit"

// step_used: in local-only mode the account steps are not part of the run.
step_used :: proc(st: ^St, s: Step) -> bool {
	if st.mode == .Local && s in CLOUD_STEPS {
		return false
	}
	// Passwords is a step only when an identity chose them, which is known
	// from the Sync page on; until then it is counted, so the step numbers
	// do not shift under the person's feet more than once.
	if s == .Passwords && st.mode == .Account && st.step > .Sync && !any_service(st, .Passwords) && !st.vault_done {
		return false
	}
	return true
}

next_step :: proc(st: ^St, s: Step) -> Step {
	n := s
	for n < .Done {
		n = Step(int(n) + 1)
		if step_used(st, n) {
			return n
		}
	}
	return .Done
}

prev_step :: proc(st: ^St, s: Step) -> Step {
	n := s
	for n > .Welcome {
		n = Step(int(n) - 1)
		if step_used(st, n) {
			return n
		}
	}
	return .Welcome
}

move_to :: proc(st: ^St, s: Step) {
	if st.step == .Welcome && s != .Welcome {
		leave_welcome(st)
	}
	st.step = s
	st.tried = false
	st.vault_tried = false
	clear_msg(st)
	st.want_focus = true
	if s == .Identities && len(st.plans) == 0 {
		suggest_first_identity(st)
	}
}

// leave_welcome saves the language and the appearance, but only what was
// changed: a person who just looked at the page leaves no file behind.
leave_welcome :: proc(st: ^St) {
	if st.opts.fixture {
		return
	}
	if st.lang_i != st.lang_start {
		save_language(LANGUAGES[st.lang_i].code)
		st.lang_start = st.lang_i
	}
	if st.dark != st.dark_start {
		save_appearance(st.dark)
		st.dark_start = st.dark
	}
}

can_go_back :: proc(st: ^St) -> bool {
	return st.step != .Welcome && st.step != .Done && !busy(st)
}

can_skip :: proc(st: ^St) -> bool {
	switch st.step {
	case .Welcome, .Done:
		return false
	case .Passwords:
		// Once the vault exists there is nothing left to skip.
		return !busy(st) && !st.vault_done
	case .Setup:
		return !busy(st) && !st.setup_ran
	case .Account, .Sign_In, .Identities, .Sync, .Import, .Tour:
		return !busy(st)
	}
	return false
}

go_back :: proc(st: ^St) {
	if !can_go_back(st) {
		return
	}
	move_to(st, prev_step(st, st.step))
}

// skip: Account and Sign in fall back to using this computer alone, which is
// a first-class way to use Palmy and not a lesser one. The rest move on
// without doing anything.
skip :: proc(st: ^St) {
	if !can_skip(st) {
		return
	}
	switch st.step {
	case .Account, .Sign_In:
		st.mode = .Local
		move_to(st, .Import)
	case .Identities:
		if usable_count(st) == 0 {
			// No identity to sync anything for.
			move_to(st, .Import)
		} else {
			move_to(st, .Sync)
		}
	case .Sync:
		move_to(st, .Import)
	case .Passwords:
		for &pl in st.plans {
			pl.services -= {.Passwords}
		}
		move_to(st, .Setup)
	case .Setup, .Import, .Tour:
		move_to(st, next_step(st, st.step))
	case .Welcome, .Done:
	}
}

// ---------------------------------------------------------------------------
// Next
// ---------------------------------------------------------------------------

// can_leave says whether Next is possible, and if not, why (a msgid).
can_leave :: proc(st: ^St) -> (ok: bool, why: string) {
	if busy(st) {
		return false, ""
	}
	switch st.step {
	case .Welcome, .Import, .Tour, .Done:
		return true, ""
	case .Account:
		if st.choice == .Undecided {
			return false, N("Choose one to continue.")
		}
	case .Sign_In:
		if st.signed_in {
			return true, ""
		}
		if p := auth_problem(st); p != "" {
			return false, p
		}
	case .Identities:
		if p := identities_problem(st); p != "" {
			return false, p
		}
	case .Sync:
		return true, ""
	case .Passwords:
		if st.vault_done {
			if st.secret != "" && !st.kit_ack {
				return false, N("Confirm that your Emergency Kit is safe.")
			}
			return true, ""
		}
		if st.vault_enroll {
			if len(strings.trim_space(string(st.secret_buf[:]))) < 20 {
				return false, N("Enter the Secret Key from your Emergency Kit.")
			}
			return true, ""
		}
		if p := vault_problem(st); p != "" {
			return false, p
		}
	case .Setup:
		return true, ""
	}
	return true, ""
}

auth_problem :: proc(st: ^St) -> string {
	email := strings.trim_space(string(st.email_buf[:]))
	if st.auth_tab == .Create && strings.trim_space(string(st.name_buf[:])) == "" {
		return N("Enter your name.")
	}
	if !email_ok(email) {
		return N("Enter a valid email address.")
	}
	if len(st.pw_buf) < 8 {
		return N("The password needs at least 8 characters.")
	}
	if st.auth_tab == .Create && string(st.pw_buf[:]) != string(st.pw2_buf[:]) {
		return N("The passwords do not match.")
	}
	return ""
}

identities_problem :: proc(st: ^St) -> string {
	if len(st.plans) == 0 {
		return N("Add at least one identity.")
	}
	for &pl, i in st.plans {
		if pl.existing {
			continue
		}
		if plan_name(&pl) == "" {
			return N("Every identity needs a name.")
		}
		if p := handle_problem(plan_handle(&pl)); p != "" {
			return p
		}
		for &q, j in st.plans {
			if j != i && plan_handle(&q) == plan_handle(&pl) {
				return N("Two identities cannot have the same handle.")
			}
		}
	}
	return ""
}

vault_problem :: proc(st: ^St) -> string {
	pw := string(st.vault_pw[:])
	if len(pw) < 10 {
		return N("The master password needs at least 10 characters.")
	}
	if pw == string(st.pw_buf[:]) && pw != "" {
		return N("Use a different password from your account password.")
	}
	if pw != string(st.vault_pw2[:]) {
		return N("The passwords do not match.")
	}
	return ""
}

go_next :: proc(st: ^St) {
	ok, _ := can_leave(st)
	if !ok {
		st.tried = true
		st.vault_tried = true
		return
	}
	switch st.step {
	case .Welcome, .Import, .Tour:
		move_to(st, next_step(st, st.step))
	case .Account:
		st.mode = st.choice
		if st.mode == .Account && !st.opts.fixture {
			if st.c == nil {
				if e := open_cloud(st); !ck.ok(e) {
					say(st, err_text(e), true)
					return
				}
			}
			if st.signed_in {
				refresh_account(st)
			}
		}
		move_to(st, next_step(st, st.step))
	case .Sign_In:
		if st.signed_in {
			move_to(st, .Identities)
			return
		}
		start_job(st, st.auth_tab == .Create ? .Sign_Up : .Sign_In)
	case .Identities:
		need := false
		for &pl in st.plans {
			if !pl.existing {
				need = true
			}
		}
		if need {
			start_job(st, .Identities)
		} else {
			move_to(st, .Sync)
		}
	case .Sync:
		move_to(st, any_service(st, .Passwords) || st.vault_done ? .Passwords : .Setup)
	case .Passwords:
		switch {
		case st.vault_done:
			move_to(st, .Setup)
		case st.vault_enroll:
			start_job(st, .Vault_Enroll)
		case:
			start_job(st, .Vault)
		}
	case .Setup:
		if !st.setup_ran {
			plan_tasks(st)
			st.setup_ran = true
			start_job(st, .Services)
		} else {
			move_to(st, .Import)
		}
	case .Done:
		finish(st)
		st.finished = true
	}
}

// job_done hands a finished job's result to its page.
job_done :: proc(st: ^St, kind: Job_Kind, err: string) {
	if err != "" {
		say(st, err, true)
	}
	switch kind {
	case .None, .Kit:
		if kind == .Kit && err == "" {
			say(st, tr("Saved. Print it, or copy it somewhere only you can reach, then delete the files."))
			st.want_focus = true // the acknowledgement is next
		}
	case .Sign_In, .Sign_Up:
		if err == "" {
			if kind == .Sign_Up {
				suggest_first_identity(st)
			}
			move_to(st, .Identities)
		}
	case .Identities:
		if err == "" {
			move_to(st, .Sync)
		}
	case .Vault, .Vault_Enroll:
		if err == "" && kind == .Vault_Enroll {
			move_to(st, .Setup)
		}
		st.want_focus = true
	case .Services:
		st.want_focus = true
	}
}

// suggest_first_identity proposes a personal identity named after the
// person, with a handle made from the name: one row, ready to change.
suggest_first_identity :: proc(st: ^St) {
	for &pl in st.plans {
		if !pl.existing {
			return
		}
	}
	if usable_count(st) > 0 {
		return
	}
	name := strings.trim_space(string(st.name_buf[:]))
	if name == "" && st.email != "" {
		at := strings.index_byte(st.email, '@')
		name = at > 0 ? st.email[:at] : st.email
	}
	add_plan(st, 0, name)
}

add_plan :: proc(st: ^St, kind: int, name := "") -> ^Plan {
	taken := make([dynamic]int, context.temp_allocator)
	for &q in st.plans {
		append(&taken, q.color)
	}
	pl := Plan{kind = kind}
	pl.color = kind_default_color(KINDS[kind], taken[:])
	pl.services = kind_default_services(KINDS[kind])
	if name != "" {
		append(&pl.name, ..transmute([]u8)name)
		h := handle_from(name)
		append(&pl.handle, ..transmute([]u8)h)
	}
	append(&st.plans, pl)
	return &st.plans[len(st.plans) - 1]
}

remove_plan :: proc(st: ^St, i: int) {
	if i < 0 || i >= len(st.plans) || st.plans[i].existing {
		return
	}
	ordered_remove(&st.plans, i)
}
