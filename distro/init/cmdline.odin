package main

// The kernel command line, as far as palm-init cares about it.
//
//	palm.single              a root shell on the console instead of services
//	palm.autologin=<user>    handed to every service as PALM_AUTOLOGIN, which
//	                         palm-login reads to skip the greeter
//
// The kernel's own rule for splitting /proc/cmdline is spaces, except inside
// double quotes, with the quotes kept off the value: `a="b c"` is the single
// parameter a=b c. parse_cmdline follows that so a quoted value survives.

import "core:strings"

Cmdline :: struct {
	single:    bool,
	autologin: string,
}

cmdline_split :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	b := strings.builder_make(allocator)
	in_quote := false
	have := false
	for i in 0 ..< len(text) {
		c := text[i]
		switch {
		case c == '"':
			in_quote = !in_quote
			have = true
		case (c == ' ' || c == '\t' || c == '\n') && !in_quote:
			if have {
				append(&out, strings.clone(strings.to_string(b), allocator))
				strings.builder_reset(&b)
				have = false
			}
		case:
			strings.write_byte(&b, c)
			have = true
		}
	}
	if have {append(&out, strings.clone(strings.to_string(b), allocator))}
	return out[:]
}

parse_cmdline :: proc(text: string, allocator := context.allocator) -> (c: Cmdline) {
	for param in cmdline_split(text, allocator) {
		switch {
		case param == "palm.single" || param == "palm.single=1":
			c.single = true
		case strings.has_prefix(param, "palm.autologin="):
			c.autologin = param[len("palm.autologin="):]
		}
	}
	return
}
