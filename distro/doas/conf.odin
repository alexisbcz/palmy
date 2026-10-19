package doas

// /etc/doas.conf: OpenBSD's doas.conf(5), the whole of it except the
// login-class bits OpenBSD has and Linux does not.
//
//	permit|deny [options] identity [as target] [cmd command [args [argument ...]]]
//
//	options    nopass     no password
//	           nolog      do not log a successful run
//	           persist    after a password, none for 5 minutes on that terminal
//	           keepenv    keep the caller's environment (minus the dangerous parts)
//	           setenv { VAR=value  VAR=$OTHER  -VAR  VAR }
//	                      set, copy from the caller, remove, keep
//	identity   a user name, or :group
//	as         the target user; without it, any target
//	cmd        the command; without it, any command. A name without '/' is
//	           looked up in the safe PATH, exactly as running it would be
//	args       the exact arguments; `args` alone means none at all
//
// The last rule that matches decides. Nothing matching means no. Words may
// be "quoted", a backslash escapes the next character (a backslash at the
// end of a line continues it), and # starts a comment.
//
// The file is read through one descriptor that is first checked to be a
// regular file owned by root and writable by no one else; any syntax error
// anywhere refuses everything, rather than guessing what a damaged policy
// meant.

import "core:fmt"
import "core:strings"
import "core:sys/linux"

CONF_PATH :: "/etc/doas.conf"

Action :: enum u8 {
	Permit,
	Deny,
}

Rule :: struct {
	action:   Action,
	nopass:   bool,
	nolog:    bool,
	persist:  bool,
	keepenv:  bool,
	setenv:   [dynamic]string,
	ident:    string, // "palm" or ":wheel"
	target:   string, // "" means any
	cmd:      string, // "" means any
	args:     [dynamic]string,
	has_args: bool,
	line:     int,
}

Token :: struct {
	text:   string,
	quoted: bool, // came (partly) from quotes or escapes: never a keyword
	line:   int,
	eol:    bool, // the end of a rule
}

// tokenize splits the file into words and ends of lines.
tokenize :: proc(text: string, allocator := context.temp_allocator) -> (toks: [dynamic]Token, err: string) {
	toks = make([dynamic]Token, allocator)
	line := 1
	i := 0
	n := len(text)
	word := strings.builder_make(allocator)
	in_word := false
	quoted := false
	word_line := 1

	flush :: proc(toks: ^[dynamic]Token, word: ^strings.Builder, in_word: ^bool, quoted: ^bool, line: int, allocator := context.temp_allocator) {
		if in_word^ {
			append(toks, Token{text = strings.clone(strings.to_string(word^), allocator), quoted = quoted^, line = line})
			strings.builder_reset(word)
			in_word^ = false
			quoted^ = false
		}
	}

	for i < n {
		c := text[i]
		switch {
		case c == '\n':
			flush(&toks, &word, &in_word, &quoted, word_line)
			append(&toks, Token{eol = true, line = line})
			line += 1
			i += 1
		case c == ' ' || c == '\t' || c == '\r':
			flush(&toks, &word, &in_word, &quoted, word_line)
			i += 1
		case c == '#':
			flush(&toks, &word, &in_word, &quoted, word_line)
			for i < n && text[i] != '\n' {
				i += 1
			}
		case c == '\\':
			if i + 1 >= n {
				return toks, fmt.tprintf("line %d: a backslash at the end of the file", line)
			}
			if text[i + 1] == '\n' {
				// A continued line: a word boundary, not the end of a rule.
				flush(&toks, &word, &in_word, &quoted, word_line)
				line += 1
				i += 2
				continue
			}
			if !in_word {
				word_line = line
			}
			strings.write_byte(&word, text[i + 1])
			in_word = true
			quoted = true
			i += 2
		case c == '"':
			if !in_word {
				word_line = line
			}
			in_word = true
			quoted = true
			i += 1
			for {
				if i >= n || text[i] == '\n' {
					return toks, fmt.tprintf("line %d: unterminated quotes", line)
				}
				if text[i] == '"' {
					i += 1
					break
				}
				if text[i] == '\\' && i + 1 < n && text[i + 1] != '\n' {
					i += 1
				}
				strings.write_byte(&word, text[i])
				i += 1
			}
		case c == '{' || c == '}':
			flush(&toks, &word, &in_word, &quoted, word_line)
			append(&toks, Token{text = c == '{' ? "{" : "}", line = line})
			i += 1
		case c < 0x20 || c == 0x7f:
			return toks, fmt.tprintf("line %d: a control character", line)
		case:
			if !in_word {
				word_line = line
			}
			strings.write_byte(&word, c)
			in_word = true
			i += 1
		}
	}
	flush(&toks, &word, &in_word, &quoted, word_line)
	append(&toks, Token{eol = true, line = line})
	return toks, ""
}

// parse_conf turns the text of a doas.conf into rules, or the first error.
parse_conf :: proc(text: string, allocator := context.temp_allocator) -> (rules: [dynamic]Rule, err: string) {
	context.allocator = allocator
	toks, terr := tokenize(text, allocator)
	if terr != "" {
		return nil, terr
	}
	rules = make([dynamic]Rule, allocator)
	i := 0
	kw :: proc(t: Token, word: string) -> bool {
		return !t.eol && !t.quoted && t.text == word
	}
	for i < len(toks) {
		if toks[i].eol {
			i += 1
			continue
		}
		r: Rule
		r.line = toks[i].line
		bad :: proc(r: Rule, what: string) -> string {
			return fmt.tprintf("line %d: %s", r.line, what)
		}

		switch {
		case kw(toks[i], "permit"):
			r.action = .Permit
		case kw(toks[i], "deny"):
			r.action = .Deny
		case:
			return nil, bad(r, fmt.tprintf("expected permit or deny, not %q", toks[i].text))
		}
		i += 1

		// Options (permit only).
		for i < len(toks) && !toks[i].eol {
			t := toks[i]
			if kw(t, "nopass") {
				r.nopass = true
			} else if kw(t, "nolog") {
				r.nolog = true
			} else if kw(t, "persist") {
				r.persist = true
			} else if kw(t, "keepenv") {
				r.keepenv = true
			} else if kw(t, "setenv") {
				i += 1
				if i >= len(toks) || !kw(toks[i], "{") {
					return nil, bad(r, "setenv needs { ... }")
				}
				i += 1
				for {
					if i >= len(toks) {
						return nil, bad(r, "setenv { is not closed")
					}
					if toks[i].eol {
						// A newline inside the braces needs a backslash, as in
						// OpenBSD.
						return nil, bad(r, "setenv { is not closed on its line")
					}
					if kw(toks[i], "}") {
						break
					}
					if why := check_setenv(toks[i].text); why != "" {
						return nil, bad(r, why)
					}
					append(&r.setenv, toks[i].text)
					i += 1
				}
			} else {
				break
			}
			if r.action == .Deny {
				return nil, bad(r, "deny takes no options")
			}
			i += 1
		}
		if r.persist && r.nopass {
			return nil, bad(r, "persist and nopass do not go together")
		}

		if i >= len(toks) || toks[i].eol || kw(toks[i], "{") || kw(toks[i], "}") {
			return nil, bad(r, "no identity (a user, or :group)")
		}
		r.ident = toks[i].text
		if r.ident == "" || r.ident == ":" {
			return nil, bad(r, "an empty identity")
		}
		i += 1

		if i < len(toks) && kw(toks[i], "as") {
			i += 1
			if i >= len(toks) || toks[i].eol || toks[i].text == "" {
				return nil, bad(r, "as needs a user")
			}
			r.target = toks[i].text
			i += 1
		}
		if i < len(toks) && kw(toks[i], "cmd") {
			i += 1
			if i >= len(toks) || toks[i].eol || toks[i].text == "" {
				return nil, bad(r, "cmd needs a command")
			}
			r.cmd = toks[i].text
			i += 1
			if i < len(toks) && kw(toks[i], "args") {
				r.has_args = true
				i += 1
				for i < len(toks) && !toks[i].eol {
					append(&r.args, toks[i].text)
					i += 1
				}
			}
		}
		if i < len(toks) && !toks[i].eol {
			return nil, bad(r, fmt.tprintf("unexpected %q", toks[i].text))
		}
		append(&rules, r)
	}
	return rules, ""
}

@(private = "file")
check_setenv :: proc(e: string) -> string {
	name := e
	if strings.has_prefix(name, "-") {
		name = name[1:]
	}
	if eq := strings.index_byte(name, '='); eq >= 0 {
		if e[0] == '-' {
			return fmt.tprintf("setenv: %q removes and sets at once", e)
		}
		name = name[:eq]
	}
	if !valid_env_name(name) {
		return fmt.tprintf("setenv: %q is not a variable name", e)
	}
	return ""
}

valid_env_name :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	for c, i in transmute([]u8)name {
		switch c {
		case 'A' ..= 'Z', 'a' ..= 'z', '_':
		case '0' ..= '9':
			if i == 0 {
				return false
			}
		case:
			return false
		}
	}
	return true
}

// read_conf opens the configuration and checks, on the open descriptor,
// that it is root's and nobody else may change it: what is checked is what
// is read.
read_conf :: proc(path: string, need_root_owned := true) -> (text: string, err: string) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	fd, e := linux.open(cpath, {.NOFOLLOW, .CLOEXEC, .NONBLOCK})
	if e != .NONE {
		return "", fmt.tprintf("%s: %v", path, e)
	}
	defer linux.close(fd)
	st: linux.Stat
	if linux.fstat(fd, &st) != .NONE || !linux.S_ISREG(st.mode) {
		return "", fmt.tprintf("%s is not a regular file", path)
	}
	if need_root_owned {
		if st.uid != 0 {
			return "", fmt.tprintf("%s is not owned by root", path)
		}
		if transmute(u32)st.mode & 0o022 != 0 {
			return "", fmt.tprintf("%s is writable by group or others", path)
		}
	}
	if st.size > 1 << 20 {
		return "", fmt.tprintf("%s is too large", path)
	}
	buf := make([]u8, int(st.size), context.temp_allocator)
	off := 0
	for off < len(buf) {
		n, re := linux.read(fd, buf[off:])
		if re == .EINTR {
			continue
		}
		if re != .NONE {
			return "", fmt.tprintf("%s: %v", path, re)
		}
		if n == 0 {
			break
		}
		off += n
	}
	return string(buf[:off]), ""
}
