package main

// What the machine actually has, read from pacman and from nothing else.
//
// Every query here is read-only -- `-Q`, `-Qq`, `-Qqe`, `-Qi`, `-Si`, `-Ss`.
// None of them takes a lock, none of them needs root, and none of them can
// change a package. The parsers are separated from the subprocess calls so the
// self-test can feed them canned pacman output, including truncated output.

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

World :: struct {
	installed:    map[string]bool,
	explicit:     map[string]bool,
	// name -> the installed packages that require it, from `pacman -Qi`.
	required_by:  map[string][]string,
	// name -> whether a sync repository has it, from `pacman -Si`.
	in_repo:      map[string]bool,
	repo_checked: map[string]bool,
	loaded:       bool,
}

world_make :: proc(allocator := context.allocator) -> World {
	return World {
		installed = make(map[string]bool, allocator),
		explicit = make(map[string]bool, allocator),
		required_by = make(map[string][]string, allocator),
		in_repo = make(map[string]bool, allocator),
		repo_checked = make(map[string]bool, allocator),
	}
}

// ---------------------------------------------------------------------------
// Parsers -- pure, so they can be driven from canned text
// ---------------------------------------------------------------------------

// parse_name_list reads `pacman -Qq` / `pacman -Qqe`: one name per line.
// Anything that is not a usable package name is dropped rather than trusted,
// so a corrupt or truncated read cannot put junk into an argv later.
parse_name_list :: proc(text: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		s := strings.trim_space(raw)
		if s == "" {
			continue
		}
		// `pacman -Q` (without q) is "name version"; take the first field.
		if i := strings.index_byte(s, ' '); i > 0 {
			s = s[:i]
		}
		if pkg_name_ok(s) {
			append(&out, strings.clone(s, allocator))
		}
	}
	return out[:]
}

Pkg_Info :: struct {
	name:         string,
	version:      string,
	description:  string,
	required_by:  []string,
	optional_for: []string,
	reason:       string,
}

@(private = "file")
qi_field :: proc(line: string) -> (key, value: string, ok: bool) {
	i := strings.index_byte(line, ':')
	if i < 0 {
		return "", "", false
	}
	return strings.trim_space(line[:i]), strings.trim_space(line[i + 1:]), true
}

// parse_qi reads `pacman -Qi`, which prints one block per package separated by
// a blank line. "Required By" is the field that decides whether a removal is
// allowed; it is `None` when nothing depends on the package.
parse_qi :: proc(text: string, allocator := context.allocator) -> []Pkg_Info {
	out := make([dynamic]Pkg_Info, allocator)
	cur := Pkg_Info{}
	have := false

	flush :: proc(out: ^[dynamic]Pkg_Info, cur: ^Pkg_Info, have: ^bool) {
		if have^ && cur.name != "" {
			append(out, cur^)
		}
		cur^ = Pkg_Info{}
		have^ = false
	}

	split :: proc(v: string, allocator: runtime.Allocator) -> []string {
		if v == "" || v == "None" {
			return nil
		}
		parts := strings.fields(v, context.temp_allocator)
		keep := make([dynamic]string, allocator)
		for p in parts {
			if pkg_name_ok(p) {
				append(&keep, strings.clone(p, allocator))
			}
		}
		return keep[:]
	}

	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		line := raw
		if strings.trim_space(line) == "" {
			flush(&out, &cur, &have)
			continue
		}
		// Continuation lines in `pacman -Qi` are indented and hold no colon
		// before the first space; they only occur for long descriptions here.
		key, value, ok := qi_field(line)
		if !ok {
			continue
		}
		switch key {
		case "Name":
			flush(&out, &cur, &have)
			if pkg_name_ok(value) {
				cur.name = strings.clone(value, allocator)
				have = true
			}
		case "Version":
			cur.version = strings.clone(value, allocator)
		case "Description":
			cur.description = strings.clone(value, allocator)
		case "Required By":
			cur.required_by = split(value, allocator)
		case "Optional For":
			cur.optional_for = split(value, allocator)
		case "Install Reason":
			cur.reason = strings.clone(value, allocator)
		}
	}
	flush(&out, &cur, &have)
	return out[:]
}

// parse_search reads `pacman -Ss`, whose entries are two lines: a header
// `repo/name version [flags]` and an indented description.
Search_Hit :: struct {
	repo:        string,
	name:        string,
	version:     string,
	description: string,
	installed:   bool,
}

parse_search :: proc(text: string, allocator := context.allocator) -> []Search_Hit {
	out := make([dynamic]Search_Hit, allocator)
	rest := text
	for raw in strings.split_lines_iterator(&rest) {
		if raw == "" {
			continue
		}
		if raw[0] == ' ' || raw[0] == '\t' {
			if len(out) > 0 {
				out[len(out) - 1].description = strings.clone(strings.trim_space(raw), allocator)
			}
			continue
		}
		slash := strings.index_byte(raw, '/')
		if slash <= 0 {
			continue
		}
		rest := raw[slash + 1:]
		fields := strings.fields(rest, context.temp_allocator)
		if len(fields) == 0 || !pkg_name_ok(fields[0]) {
			continue
		}
		hit := Search_Hit {
			repo      = strings.clone(raw[:slash], allocator),
			name      = strings.clone(fields[0], allocator),
			installed = strings.contains(rest, "[installed"),
		}
		if len(fields) > 1 {
			hit.version = strings.clone(fields[1], allocator)
		}
		append(&out, hit)
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// The subprocess side
// ---------------------------------------------------------------------------

// world_load fills the installed and explicit sets. Returns false when pacman
// is not reachable, which the caller turns into exit 6 (unavailable) rather
// than pretending the machine has nothing installed -- an empty world would
// make `sync` propose installing all 189 declared packages.
world_load :: proc(w: ^World) -> bool {
	all, ok1 := run_query({"pacman", "-Qq"})
	if !ok1 {
		return false
	}
	exp, ok2 := run_query({"pacman", "-Qqe"})
	if !ok2 {
		return false
	}
	for n in parse_name_list(all) {
		w.installed[n] = true
	}
	for n in parse_name_list(exp) {
		w.explicit[n] = true
	}
	w.loaded = true
	return true
}

// world_load_dependants asks only about the names a removal is about to touch,
// rather than parsing all 1,115 blocks of `pacman -Qi`.
world_load_dependants :: proc(w: ^World, names: []string) -> bool {
	if len(names) == 0 {
		return true
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "pacman", "-Qi", "--")
	for n in names {
		if pkg_name_ok(n) {
			append(&argv, n)
		}
	}
	out, _ := run_query(argv[:])
	for info in parse_qi(out) {
		w.required_by[info.name] = info.required_by
	}
	for n in names {
		if _, had := w.required_by[n]; !had {
			w.required_by[n] = nil
		}
	}
	return true
}

// world_load_repo decides, for each name, whether a sync repository has it.
// `pacman -Si` exits non-zero when any name is missing but still prints the
// ones it found, so the found set comes from the output and not the status.
world_load_repo :: proc(w: ^World, names: []string) -> bool {
	pending := make([dynamic]string, context.temp_allocator)
	for n in names {
		if !w.repo_checked[n] && pkg_name_ok(n) {
			append(&pending, n)
		}
	}
	if len(pending) == 0 {
		return true
	}
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "pacman", "-Si", "--")
	append(&argv, ..pending[:])
	out, _ := run_query(argv[:])
	found := make(map[string]bool, context.temp_allocator)
	for info in parse_qi(out) {
		found[info.name] = true
	}
	for n in pending {
		w.repo_checked[n] = true
		w.in_repo[n] = found[n]
	}
	return true
}

// world_explicit_sorted is the installed-explicitly set, which is the closest
// thing pacman has to a statement of what the machine is.
world_explicit_sorted :: proc(w: ^World, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for n in w.explicit {
		append(&out, n)
	}
	slice.sort(out[:])
	return out[:]
}

dependants_of :: proc(w: ^World, name: string) -> []string {
	return w.required_by[name]
}

describe_dependants :: proc(w: ^World, names: []string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, allocator)
	for n in names {
		deps := dependants_of(w, n)
		if len(deps) == 0 {
			continue
		}
		append(
			&out,
			fmt.aprintf("%s is required by %s", n, strings.join(deps, " ", context.temp_allocator)),
		)
	}
	return out[:]
}
