package main

// The module index: what depmod wrote into /usr/lib/modules/<release>, read
// as text, plus the modprobe.d files.
//
//	modules.dep       kernel/net/foo.ko.zst: kernel/lib/bar.ko.zst ...
//	                  every module and the full list of what it needs, in an
//	                  order where loading from the last to the first works
//	modules.alias     alias pci:v00008086d0000A7A0sv*sd*bc03sc*i* i915
//	                  a glob over a device's modalias, and the module for it
//	modules.softdep   softdep snd_hda_intel pre: ... post: ...
//	modules.builtin   kernel/fs/ext4/ext4.ko  (built in: nothing to load)
//
// /etc/modprobe.d/*.conf and /usr/lib/modprobe.d/*.conf may say
//
//	blacklist nouveau            never load nouveau for a device
//	options   snd_hda_intel power_save=1
//
// and the kernel command line `modprobe.blacklist=a,b` adds to the list. A
// blacklisted module is still loaded when asked for by name, as kmod does.

import "core:strings"

Alias :: struct {
	pattern: string,
	module:  string,
}

Index :: struct {
	dir:       string,
	paths:     map[string]string, // module name -> path relative to dir
	deps:      map[string][]string, // module name -> what it needs (names)
	builtin:   map[string]bool,
	aliases:   map[string][dynamic]Alias, // by the pattern's prefix (alias_key)
	pre:       map[string][]string, // softdep pre:
	post:      map[string][]string, // softdep post:
	options:   map[string]string,
	blacklist: map[string]bool,
}

// module_name turns a path or a name into the kernel's spelling of it:
// directory and .ko[.zst|.xz|.gz] dropped, and '-' read as '_'.
module_name :: proc(s: string, allocator := context.allocator) -> string {
	name := s
	if i := strings.last_index_byte(name, '/'); i >= 0 {name = name[i + 1:]}
	if i := strings.index(name, ".ko"); i >= 0 {name = name[:i]}
	out, _ := strings.replace_all(name, "-", "_", allocator)
	return out
}

// alias_key is the part of an alias before its first ':' ("pci", "usb",
// "acpi", "hid"), used to look at only the patterns that could match. A
// pattern whose key itself has a wildcard goes under "", which is always
// searched.
alias_key :: proc(s: string, is_pattern: bool) -> string {
	key := s
	if i := strings.index_byte(s, ':'); i >= 0 {key = s[:i]}
	if is_pattern && strings.index_any(key, "*?[") >= 0 {return ""}
	return key
}

index_load :: proc(dir: string) -> (ix: Index, ok: bool) {
	ix.dir = dir
	dep_text, dep_ok := read_file(join(dir, "modules.dep"))
	if !dep_ok {return ix, false}
	for line in strings.split_lines_iterator(&dep_text) {
		colon := strings.index_byte(line, ':')
		if colon < 0 {continue}
		path := line[:colon]
		name := module_name(path)
		ix.paths[name] = path
		fields := strings.fields(line[colon + 1:])
		names := make([]string, len(fields))
		for f, i in fields {names[i] = module_name(f)}
		ix.deps[name] = names
	}

	if text, found := read_file(join(dir, "modules.builtin")); found {
		for line in strings.split_lines_iterator(&text) {
			if line != "" {ix.builtin[module_name(line)] = true}
		}
	}

	if text, found := read_file(join(dir, "modules.alias")); found {
		for line in strings.split_lines_iterator(&text) {
			f := strings.fields(line, context.temp_allocator)
			if len(f) != 3 || f[0] != "alias" {continue}
			add_alias(&ix, f[1], f[2])
		}
	}

	if text, found := read_file(join(dir, "modules.softdep")); found {
		for line in strings.split_lines_iterator(&text) {
			parse_softdep(&ix, line)
		}
	}

	for conf_dir in ([]string{"/usr/lib/modprobe.d", "/etc/modprobe.d"}) {
		names, _ := list_dir(conf_dir)
		for name in names {
			if !strings.has_suffix(name, ".conf") {continue}
			text, found := read_file(join(conf_dir, name))
			if !found {continue}
			for line in strings.split_lines_iterator(&text) {
				parse_conf_line(&ix, line)
			}
		}
	}

	if text, found := read_file("/proc/cmdline"); found {
		for word in strings.fields(text, context.temp_allocator) {
			if !strings.has_prefix(word, "modprobe.blacklist=") {continue}
			list := word[len("modprobe.blacklist="):]
			for m in strings.split_iterator(&list, ",") {
				if m != "" {ix.blacklist[module_name(m)] = true}
			}
		}
	}
	return ix, true
}

add_alias :: proc(ix: ^Index, pattern, module: string) {
	key := alias_key(pattern, true)
	if key not_in ix.aliases {ix.aliases[key] = make([dynamic]Alias)}
	append(&ix.aliases[key], Alias{pattern, module_name(module)})
}

parse_softdep :: proc(ix: ^Index, line: string) {
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 3 || f[0] != "softdep" {return}
	mod := module_name(f[1])
	pre, post: [dynamic]string
	into := &pre
	for w in f[2:] {
		switch w {
		case "pre:":
			into = &pre
		case "post:":
			into = &post
		case:
			append(into, module_name(w))
		}
	}
	if len(pre) > 0 {ix.pre[mod] = pre[:]}
	if len(post) > 0 {ix.post[mod] = post[:]}
}

parse_conf_line :: proc(ix: ^Index, raw: string) {
	line := strings.trim_space(raw)
	if line == "" || line[0] == '#' {return}
	f := strings.fields(line, context.temp_allocator)
	if len(f) < 2 {return}
	switch f[0] {
	case "blacklist":
		ix.blacklist[module_name(f[1])] = true
	case "options":
		name := module_name(f[1])
		rest := strings.join(f[2:], " ", context.temp_allocator)
		if old, has := ix.options[name]; has {
			ix.options[name] = strings.concatenate({old, " ", rest})
		} else {
			ix.options[name] = strings.clone(rest)
		}
	case "softdep":
		parse_softdep(ix, line)
	case "alias":
		if len(f) >= 3 {add_alias(ix, f[1], f[2])}
	}
}

// lookup answers which modules a name or a modalias stands for: the module
// of that name, else every module with a matching alias. builtin is true if
// the name is a module compiled into the kernel (nothing to load).
lookup :: proc(ix: ^Index, what: string, allocator := context.temp_allocator) -> (mods: [dynamic]string, builtin: bool) {
	mods = make([dynamic]string, allocator)
	name := module_name(what, context.temp_allocator)
	// A modalias has a ':' and is never a module name; a name never has one.
	if strings.index_byte(what, ':') < 0 {
		if name in ix.paths {
			append(&mods, name)
			return
		}
		if name in ix.builtin {return mods, true}
	}
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for key in ([]string{alias_key(what, false), ""}) {
		list, has := ix.aliases[key]
		if !has {continue}
		for a in list {
			if a.module in seen {continue}
			if glob(a.pattern, what) {
				seen[a.module] = true
				append(&mods, a.module)
			}
		}
		if key == "" {break}
	}
	return
}

// glob is fnmatch(3) without flags: '*' any run, '?' any byte, '[...]' a set
// with ranges and '!' or '^' to negate. That is all file2alias writes.
glob :: proc(pattern, s: string) -> bool {
	p, i := 0, 0
	star_p, star_i := -1, 0
	for i < len(s) {
		if p < len(pattern) {
			switch pattern[p] {
			case '*':
				star_p, star_i = p, i
				p += 1
				continue
			case '?':
				p += 1
				i += 1
				continue
			case '[':
				if matched, width, valid := match_class(pattern[p:], s[i]); valid {
					if matched {
						p += width
						i += 1
						continue
					}
				} else if s[i] == '[' {
					p += 1
					i += 1
					continue
				}
			case:
				if pattern[p] == s[i] {
					p += 1
					i += 1
					continue
				}
			}
		}
		if star_p < 0 {return false}
		star_i += 1
		p, i = star_p + 1, star_i
	}
	for p < len(pattern) && pattern[p] == '*' {p += 1}
	return p == len(pattern)
}

// match_class matches one byte against the set at the start of pat ("[...]").
// width is the set's length in pat; valid is false for an unclosed '['.
match_class :: proc(pat: string, c: u8) -> (matched: bool, width: int, valid: bool) {
	j := 1
	negate := false
	if j < len(pat) && (pat[j] == '!' || pat[j] == '^') {
		negate = true
		j += 1
	}
	first := true
	for j < len(pat) {
		if pat[j] == ']' && !first {
			return matched != negate, j + 1, true
		}
		first = false
		lo := pat[j]
		if j + 2 < len(pat) && pat[j + 1] == '-' && pat[j + 2] != ']' {
			if lo <= c && c <= pat[j + 2] {matched = true}
			j += 3
		} else {
			if lo == c {matched = true}
			j += 1
		}
	}
	return false, 0, false
}
