package main

// The declaration: a plain file, one per identity, saying what the machine
// should have.
//
// `pacman -Qqe` lists what was installed explicitly, which is the residue of a
// history of commands, not a statement of intent. This file is the intent, and
// it is the only thing `sync` converges toward.
//
//	# ~/.config/palm/packages/<identity>.pkgs
//	identity work            # optional, and only before the first profile
//
//	[base]                   # a profile; packages below belong to it
//	git
//	ripgrep
//	repo fd                  # "repo" is the default and may be written out
//
//	[work]
//	aur visual-studio-code-bin   # "aur" means yay reaches for it, not pacman
//
// Packages written before any `[profile]` belong to the profile `base`.
// `#` starts a comment anywhere on a line; `#` is not legal in a package name,
// so stripping at the first one is safe.
//
// NAME VALIDATION IS A SAFETY RULE, NOT TIDINESS. Every name from this file
// ends up in an argv handed to pacman. A line reading `-Sy` or `--noconfirm`
// would be a flag, not a package, and a declaration file is exactly the kind
// of thing that gets synced between machines. So a name must start with an
// alphanumeric and may then hold only `a-z A-Z 0-9 @ . _ + -`, which is what
// Arch allows. Everything else is a parse problem and never reaches an argv.
// The planner then also puts `--` in front of every operand list, so even a
// name that slipped through could not be read as a flag.

import "core:fmt"
import "core:slice"
import "core:strings"

Source :: enum u8 {
	Repo,
	Aur,
}

source_name :: proc(s: Source) -> string {
	return s == .Aur ? "aur" : "repo"
}

Decl_Entry :: struct {
	name:    string,
	profile: string,
	source:  Source,
	line:    int,
}

Decl_Problem :: struct {
	line: int,
	text: string,
}

Decl :: struct {
	identity: string,
	entries:  [dynamic]Decl_Entry,
	profiles: [dynamic]string,
	problems: [dynamic]Decl_Problem,
}

DEFAULT_PROFILE :: "base"

// pkg_name_ok is the gate described in the file comment above.
pkg_name_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 255 {
		return false
	}
	c0 := s[0]
	is_alnum := (c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z') || (c0 >= '0' && c0 <= '9')
	if !is_alnum {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '@' || c == '.' || c == '_' || c == '+' || c == '-':
		case:
			return false
		}
	}
	return true
}

profile_name_ok :: proc(s: string) -> bool {
	if len(s) == 0 || len(s) > 64 {
		return false
	}
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case c == '_' || c == '-':
		case:
			return false
		}
	}
	return true
}

@(private = "file")
strip_comment :: proc(line: string) -> string {
	if i := strings.index_byte(line, '#'); i >= 0 {
		return strings.trim_space(line[:i])
	}
	return strings.trim_space(line)
}

decl_parse :: proc(text: string, allocator := context.allocator) -> Decl {
	d := Decl {
		entries  = make([dynamic]Decl_Entry, allocator),
		profiles = make([dynamic]string, allocator),
		problems = make([dynamic]Decl_Problem, allocator),
	}
	problem :: proc(d: ^Decl, line: int, format: string, args: ..any) {
		append(&d.problems, Decl_Problem{line = line, text = fmt.aprintf(format, ..args)})
	}

	profile := DEFAULT_PROFILE
	seen_profile := false
	seen_entry := false

	lines := strings.split_lines(text, context.temp_allocator)
	for raw, idx in lines {
		n := idx + 1
		s := strip_comment(raw)
		if s == "" {
			continue
		}

		if s[0] == '[' {
			if s[len(s) - 1] != ']' {
				problem(&d, n, "a profile header must end with ']'")
				continue
			}
			name := strings.trim_space(s[1:len(s) - 1])
			if !profile_name_ok(name) {
				problem(&d, n, "not a usable profile name: %q", name)
				continue
			}
			profile = strings.clone(name, allocator)
			seen_profile = true
			if !slice.contains(d.profiles[:], profile) {
				append(&d.profiles, profile)
			}
			continue
		}

		fields := strings.fields(s, context.temp_allocator)
		name: string
		src := Source.Repo

		switch len(fields) {
		case 1:
			name = fields[0]
		case 2:
			switch fields[0] {
			case "repo":
				name = fields[1]
			case "aur":
				name = fields[1]
				src = .Aur
			case "identity":
				if seen_profile || seen_entry {
					problem(&d, n, "`identity` must come before the first package or profile")
					continue
				}
				if !profile_name_ok(fields[1]) {
					problem(&d, n, "not a usable identity name: %q", fields[1])
					continue
				}
				d.identity = strings.clone(fields[1], allocator)
				continue
			case:
				problem(&d, n, "unknown directive %q", fields[0])
				continue
			}
		case:
			problem(&d, n, "expected `<name>`, `repo <name>`, `aur <name>` or `[profile]`")
			continue
		}

		if !pkg_name_ok(name) {
			problem(&d, n, "not a usable package name: %q", name)
			continue
		}

		dup := false
		for e in d.entries {
			if e.name == name && e.profile == profile {
				problem(&d, n, "%q is declared twice in profile %q (first at line %d)", name, profile, e.line)
				dup = true
				break
			}
		}
		if dup {
			continue
		}

		if !slice.contains(d.profiles[:], profile) {
			append(&d.profiles, strings.clone(profile, allocator))
		}
		append(
			&d.entries,
			Decl_Entry {
				name = strings.clone(name, allocator),
				profile = strings.clone(profile, allocator),
				source = src,
				line = n,
			},
		)
		seen_entry = true
	}
	return d
}

// decl_wanted is the declared set, narrowed to the given profiles (all of them
// when `profiles` is empty), sorted and de-duplicated. A package declared in
// two active profiles is wanted once; if either declaration says `aur`, the
// AUR wins, because a name pacman does not have has to come from somewhere.
decl_wanted :: proc(
	d: ^Decl,
	profiles: []string,
	allocator := context.allocator,
) -> (
	names: []string,
	sources: map[string]Source,
) {
	sources = make(map[string]Source, allocator)
	out := make([dynamic]string, allocator)
	for e in d.entries {
		if len(profiles) > 0 && !slice.contains(profiles, e.profile) {
			continue
		}
		if prev, had := sources[e.name]; had {
			if e.source == .Aur {
				sources[e.name] = .Aur
			} else {
				sources[e.name] = prev
			}
			continue
		}
		sources[e.name] = e.source
		append(&out, e.name)
	}
	slice.sort(out[:])
	return out[:], sources
}

decl_has_profile :: proc(d: ^Decl, name: string) -> bool {
	return slice.contains(d.profiles[:], name)
}

// decl_add returns the declaration text with `names` added to `profile`. It is
// a pure text transform so that `declare` is testable without a filesystem,
// and so that the file a person edits keeps its comments and its order.
decl_add :: proc(
	text: string,
	names: []string,
	profile: string,
	source: Source,
	allocator := context.allocator,
) -> (
	out: string,
	added: []string,
) {
	d := decl_parse(text, context.temp_allocator)

	want := make([dynamic]string, context.temp_allocator)
	for n in names {
		already := false
		for e in d.entries {
			if e.name == n && e.profile == profile {
				already = true
				break
			}
		}
		if !already && !slice.contains(want[:], n) {
			append(&want, n)
		}
	}
	if len(want) == 0 {
		return strings.clone(text, allocator), nil
	}

	line_text :: proc(name: string, source: Source) -> string {
		if source == .Aur {
			return fmt.tprintf("aur %s", name)
		}
		return name
	}

	lines := strings.split_lines(text, context.temp_allocator)
	// A trailing newline produces an empty last element; drop it so the
	// rebuilt file does not grow a blank line on every call.
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}

	sb := strings.builder_make(allocator)
	wrote := false

	if decl_has_profile(&d, profile) {
		// Insert at the end of that profile's block: after its last non-blank
		// line, before the next header.
		in_block := false
		last := -1
		for raw, i in lines {
			s := strip_comment(raw)
			if len(s) > 1 && s[0] == '[' && s[len(s) - 1] == ']' {
				hdr := strings.trim_space(s[1:len(s) - 1])
				in_block = hdr == profile
				if in_block {
					last = i
				}
				continue
			}
			if in_block && s != "" {
				last = i
			}
		}
		for raw, i in lines {
			strings.write_string(&sb, raw)
			strings.write_byte(&sb, '\n')
			if i == last {
				for n in want {
					strings.write_string(&sb, line_text(n, source))
					strings.write_byte(&sb, '\n')
				}
				wrote = true
			}
		}
	} else {
		for raw in lines {
			strings.write_string(&sb, raw)
			strings.write_byte(&sb, '\n')
		}
	}

	if !wrote {
		if len(lines) > 0 {
			strings.write_byte(&sb, '\n')
		}
		strings.write_string(&sb, fmt.tprintf("[%s]\n", profile))
		for n in want {
			strings.write_string(&sb, line_text(n, source))
			strings.write_byte(&sb, '\n')
		}
	}

	kept := make([dynamic]string, allocator)
	for n in want {
		append(&kept, strings.clone(n, allocator))
	}
	return strings.to_string(sb), kept[:]
}

// decl_remove drops every line declaring one of `names`, in any profile.
decl_remove :: proc(
	text: string,
	names: []string,
	allocator := context.allocator,
) -> (
	out: string,
	removed: []string,
) {
	lines := strings.split_lines(text, context.temp_allocator)
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		lines = lines[:len(lines) - 1]
	}
	sb := strings.builder_make(allocator)
	gone := make([dynamic]string, allocator)
	for raw in lines {
		s := strip_comment(raw)
		drop := false
		if s != "" && s[0] != '[' {
			fields := strings.fields(s, context.temp_allocator)
			nm := ""
			switch len(fields) {
			case 1:
				nm = fields[0]
			case 2:
				if fields[0] == "repo" || fields[0] == "aur" {
					nm = fields[1]
				}
			}
			if nm != "" && slice.contains(names, nm) {
				drop = true
				append(&gone, strings.clone(nm, allocator))
			}
		}
		if !drop {
			strings.write_string(&sb, raw)
			strings.write_byte(&sb, '\n')
		}
	}
	return strings.to_string(sb), gone[:]
}
