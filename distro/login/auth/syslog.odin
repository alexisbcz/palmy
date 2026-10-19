package auth

// Logging to syslog, facility authpriv: what busybox's syslogd (the `syslog`
// service) writes to /var/log/messages. Every grant, refusal and failure
// of palm-login, doas and passwd goes here, so there is one place to read
// who became whom.
//
// Anything that came from a user — a name typed at the greeter, a command
// line — is passed through `clean` first, so a newline in it cannot forge a
// second log line.

import "core:fmt"
import "core:strings"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	openlog :: proc(ident: cstring, option: i32, facility: i32) ---
	syslog :: proc(priority: i32, format: cstring, #c_vararg args: ..any) ---
}

LOG_PID :: 0x01
LOG_NDELAY :: 0x08
LOG_AUTHPRIV :: 10 << 3

Level :: enum i32 {
	Err     = 3,
	Warning = 4,
	Notice  = 5,
	Info    = 6,
}

@(private = "file")
log_ident: cstring
@(private = "file")
log_echo: bool
@(private = "file")
log_syslog: bool

// log_open names the program in every line. `to_syslog` is false in test
// modes, so a selftest never writes into the host's journal; `echo` also
// writes each line to stderr (palm-login, whose stderr is its service log).
log_open :: proc(ident: cstring, to_syslog := true, echo := false) {
	log_ident = ident
	log_echo = echo
	log_syslog = to_syslog
	if to_syslog {
		openlog(ident, LOG_PID | LOG_NDELAY, LOG_AUTHPRIV)
	}
}

logf :: proc(level: Level, format: string, args: ..any) {
	msg := fmt.tprintf(format, ..args)
	cmsg := strings.clone_to_cstring(msg, context.temp_allocator)
	if log_syslog {
		syslog(LOG_AUTHPRIV | i32(level), "%s", cmsg)
	}
	if log_echo {
		fmt.eprintfln("%s: %s", log_ident, msg)
	}
}

// clean makes a user-supplied string safe to log: control characters become
// '?', and it is cut at 200 bytes.
clean :: proc(s: string) -> string {
	b := make([]u8, min(len(s), 200), context.temp_allocator)
	for i in 0 ..< len(b) {
		c := s[i]
		b[i] = c < 0x20 || c == 0x7f ? '?' : c
	}
	return string(b)
}

// clean_argv joins a command line for the log.
clean_argv :: proc(argv: []string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for a, i in argv {
		if i > 0 {
			strings.write_byte(&sb, ' ')
		}
		strings.write_string(&sb, a)
	}
	s := strings.to_string(sb)
	if len(s) > 400 {
		s = s[:400]
	}
	b := transmute([]u8)strings.clone(s, context.temp_allocator)
	for &c in b {
		if c < 0x20 || c == 0x7f {
			c = '?'
		}
	}
	return string(b)
}
