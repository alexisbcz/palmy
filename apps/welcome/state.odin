package main

import "core:strings"
import "core:sync"
import "core:thread"
import ck "../cloudkit"
import kit "kit:."

Options :: struct {
	fixture:    bool, // drawing for screenshots: no client, nothing written
	spawn:      bool, // start long-running services (palm-drive watch) after setup
	first_login: bool,
}

Job_Kind :: enum u8 {
	None,
	Sign_In,
	Sign_Up,
	Identities,
	Vault,
	Vault_Enroll,
	Kit,
	Services,
}

// Job is the one piece of work running off the UI thread. While it runs the
// page's inputs are disabled, so the worker may use the fields it was given;
// the task list is the one thing both sides read at once, under `mu`.
Job :: struct {
	kind:     Job_Kind,
	running:  bool,
	finished: bool, // set by the worker; the UI joins and clears it
	err:      string,
	th:       ^thread.Thread,
	mu:       sync.Mutex,
}

St :: struct {
	opts:        Options,
	step:        Step,
	mode:        Mode,

	// Welcome
	lang_i:      int,
	lang_start:  int,
	dark:        bool,
	dark_start:  bool,

	// Account
	choice:      Mode, // highlighted card on the Account page

	// Sign in
	c:           ^ck.Client,
	url_buf:     [dynamic]u8,
	url_open:    bool,
	auth_tab:    Auth_Tab,
	name_buf:    [dynamic]u8,
	email_buf:   [dynamic]u8,
	pw_buf:      [dynamic]u8,
	pw2_buf:     [dynamic]u8,
	tried:       bool,
	signed_in:   bool,
	email:       string,
	domain:      string, // the mail domain addresses are on

	// Identities and Sync
	plans:       [dynamic]Plan,
	focus_plan:  int, // the row whose name field takes the keyboard

	// Passwords
	vault_pw:    [dynamic]u8,
	vault_pw2:   [dynamic]u8,
	vault_tried: bool,
	vault_enroll: bool, // the account already has a vault: this device joins it
	secret_buf:  [dynamic]u8, // enrolment: the Secret Key typed from the kit
	secret:      string, // shown once, after setup
	vault_done:  bool,
	kit_paths:   [2]string, // the PNG and the text file, once saved
	kit_ack:     bool,

	// Setup
	tasks:       [dynamic]Task,
	setup_ran:   bool,
	mail_pw_buf: [dynamic]u8, // when mail needs the password and none was typed here

	job:         Job,
	msg:         string, // the page's one line: an error, or what happened
	msg_bad:     bool,

	// Focus bookkeeping
	want_focus:  bool,
	consumed_enter: bool,
	now:         f64,
	finished:    bool, // the Done page's button was pressed: close the window
}

st_init :: proc(st: ^St, opts: Options) {
	st.opts = opts
	st.dark = theme_from_environment()
	st.dark_start = st.dark
	st.lang_i = language_index(kit.i18n_language())
	st.lang_start = st.lang_i
	st.domain = strings.clone("palm.test")
	st.want_focus = true
}

language_index :: proc(code: string) -> int {
	for l, i in LANGUAGES {
		if l.code == code || (len(code) >= 2 && len(l.code) >= 2 && l.code[:2] == code[:2]) {
			return i
		}
	}
	return 0
}

say :: proc(st: ^St, text: string, bad := false) {
	delete(st.msg)
	st.msg = strings.clone(text)
	st.msg_bad = bad
}

clear_msg :: proc(st: ^St) {
	delete(st.msg)
	st.msg = ""
	st.msg_bad = false
}

busy :: proc(st: ^St) -> bool {
	return st.job.running
}

any_service :: proc(st: ^St, s: Service) -> bool {
	for &pl in st.plans {
		if (pl.existing || pl.id != "") && s in pl.services {
			return true
		}
	}
	return false
}

// usable_plans are the identities that exist on the account (created now or
// before): the only ones the Sync page and Setup can act on.
usable_count :: proc(st: ^St) -> int {
	n := 0
	for &pl in st.plans {
		if pl.existing || pl.id != "" {
			n += 1
		}
	}
	return n
}
