package main

// The account page's rules, kept apart from the drawing so selftest.odin can
// check them without a window.
//
// They are install_core.validate's rules (user name, host name) stated again
// on the GUI side, because the GUI has to say what is wrong under the field
// as it is typed, in the user's language, and the core's answer arrives as
// English sentences for a whole plan. The core still checks the plan before
// it writes anything; if the two ever disagree, the core wins and its words
// are shown on the summary page.

import "core:strings"

Field :: enum {
	Full_Name,
	User,
	Hostname,
	Password,
	Confirm,
	Root_Password,
	Root_Confirm,
}

Account :: struct {
	full_name:     string,
	user:          string,
	hostname:      string,
	password:      string,
	confirm:       string,
	same_root:     bool, // the administrator (root) password is the user's
	root_password: string,
	root_confirm:  string,
}

// RESERVED are names that already exist on a Palmy system (CONTRACT.md,
// "Users") or are system groups the new user is put in. `palm` is absent on
// purpose: the install removes the demo user, so the name is free.
RESERVED := [?]string {
	"root", "greeter", "bin", "daemon", "nobody", "sys", "adm", "wheel", "video",
	"input", "audio", "tty", "users", "disk", "kmem", "utmp", "mail", "lp",
}

// Problems holds one msgid per field; "" means the field is fine.
Problems :: [Field]string

validate_account :: proc(a: Account) -> (p: Problems) {
	// Full name: optional, but it goes into the GECOS field of /etc/passwd,
	// where a colon ends the field and a comma starts a sub-field.
	if strings.contains_any(a.full_name, ":,\n") {
		p[.Full_Name] = N("A name cannot contain a colon or a comma")
	}

	p[.User] = user_problem(a.user)
	p[.Hostname] = hostname_problem(a.hostname)

	if a.password == "" {
		p[.Password] = N("Choose a password")
	}
	if a.confirm != a.password {
		p[.Confirm] = N("The passwords do not match")
	}
	if !a.same_root {
		if a.root_password == "" {
			p[.Root_Password] = N("Choose a password for the administrator")
		}
		if a.root_confirm != a.root_password {
			p[.Root_Confirm] = N("The passwords do not match")
		}
	}
	return
}

account_ok :: proc(p: Problems) -> bool {
	for f in Field {
		if p[f] != "" {
			return false
		}
	}
	return true
}

// user_problem: a POSIX-portable login name, the shape useradd accepts by
// default — a lowercase letter or underscore, then lowercase letters, digits,
// underscores and hyphens, at most 32 bytes.
user_problem :: proc(u: string) -> string {
	if u == "" {
		return N("Choose a user name")
	}
	if len(u) > 32 {
		return N("A user name has at most 32 characters")
	}
	c0 := u[0]
	if !(c0 >= 'a' && c0 <= 'z') && c0 != '_' {
		return N("A user name starts with a lowercase letter")
	}
	for i in 0 ..< len(u) {
		c := u[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			return N("Use only lowercase letters, digits, hyphens and underscores")
		}
	}
	for r in RESERVED {
		if u == r {
			return N("This name is already used by the system")
		}
	}
	return ""
}

// hostname_problem: one DNS label (RFC 1123) — letters, digits and hyphens,
// not starting or ending with a hyphen, at most 63 bytes.
hostname_problem :: proc(h: string) -> string {
	if h == "" {
		return N("Choose a name for this computer")
	}
	if len(h) > 63 {
		return N("A computer name has at most 63 characters")
	}
	for i in 0 ..< len(h) {
		c := h[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-'
		if !ok || (c == '-' && (i == 0 || i == len(h) - 1)) {
			return N("Use letters, digits and hyphens, without a hyphen at either end")
		}
	}
	return ""
}

Strength :: enum {
	None,
	Weak,
	Fair,
	Strong,
}

// password_strength is a hint, not a gate: length counts most, and each kind
// of character beyond the first adds a little. A weak password is allowed —
// it is the owner's machine — but it is called weak.
password_strength :: proc(pw: string) -> Strength {
	if pw == "" {
		return .None
	}
	lower, upper, digit, other: bool
	n := 0
	for r in pw {
		n += 1
		switch {
		case r >= 'a' && r <= 'z':
			lower = true
		case r >= 'A' && r <= 'Z':
			upper = true
		case r >= '0' && r <= '9':
			digit = true
		case:
			other = true
		}
	}
	kinds := int(lower) + int(upper) + int(digit) + int(other)
	score := kinds - 1
	switch {
	case n >= 16:
		score += 3
	case n >= 12:
		score += 2
	case n >= 8:
		score += 1
	case n < 6:
		score -= 2
	}
	switch {
	case score >= 4:
		return .Strong
	case score >= 2:
		return .Fair
	}
	return .Weak
}

strength_label :: proc(s: Strength) -> string {
	switch s {
	case .None:
		return ""
	case .Weak:
		return tr("Weak password")
	case .Fair:
		return tr("Fair password")
	case .Strong:
		return tr("Strong password")
	}
	return ""
}

// suggest_user derives a login name from a full name: the first word,
// lowercased, with common Latin accents folded and anything else dropped.
// "Élodie Martin" gives "elodie". A name with no Latin letters gives "", and
// the field stays empty for the user to fill in.
suggest_user :: proc(full_name: string, allocator := context.allocator) -> string {
	sb := strings.builder_make(allocator)
	for r in strings.trim_space(full_name) {
		if r == ' ' || r == '\t' {
			break
		}
		c := fold_latin(r)
		switch {
		case c >= 'A' && c <= 'Z':
			strings.write_byte(&sb, u8(c - 'A' + 'a'))
		case (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9' && strings.builder_len(sb) > 0):
			strings.write_byte(&sb, u8(c))
		}
		if strings.builder_len(sb) >= 32 {
			break
		}
	}
	return strings.to_string(sb)
}

@(private = "file")
fold_latin :: proc(r: rune) -> rune {
	switch r {
	case 'à', 'á', 'â', 'ã', 'ä', 'å':
		return 'a'
	case 'À', 'Á', 'Â', 'Ã', 'Ä', 'Å':
		return 'A'
	case 'ç':
		return 'c'
	case 'Ç':
		return 'C'
	case 'è', 'é', 'ê', 'ë':
		return 'e'
	case 'È', 'É', 'Ê', 'Ë':
		return 'E'
	case 'ì', 'í', 'î', 'ï':
		return 'i'
	case 'Ì', 'Í', 'Î', 'Ï':
		return 'I'
	case 'ñ':
		return 'n'
	case 'Ñ':
		return 'N'
	case 'ò', 'ó', 'ô', 'õ', 'ö', 'ø':
		return 'o'
	case 'Ò', 'Ó', 'Ô', 'Õ', 'Ö', 'Ø':
		return 'O'
	case 'ù', 'ú', 'û', 'ü':
		return 'u'
	case 'Ù', 'Ú', 'Û', 'Ü':
		return 'U'
	case 'ý', 'ÿ':
		return 'y'
	case 'ß':
		return 's'
	}
	return r
}
