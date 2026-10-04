package prose

// The style packs, compiled into the binary.
//
// `#load_directory` embeds each pack's `.yml` files at build time, which buys
// three things worth having. The feature works on a machine with no `vale`
// installed and no style packages synced — and `vale sync` wants the network,
// which these applications do not use. There is no path for the application
// to resolve at runtime, so it cannot be started from the wrong directory and
// silently find no rules. And the files are still real files in the
// repository: readable, diffable, and copyable into anybody's own
// `StylesPath`, where the real `vale` reads them unchanged.
//
// A user's own pack is loaded from disk instead, by `engine_load_dir`, which
// takes a Vale `StylesPath` and reads one directory per style.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"

@(private = "file")
PLAIN := #load_directory("styles/Plain")
@(private = "file")
BUSINESS := #load_directory("styles/Business")
@(private = "file")
ACADEMIC := #load_directory("styles/Academic")
@(private = "file")
JOURNALISTIC := #load_directory("styles/Journalistic")
@(private = "file")
INCLUSIVE := #load_directory("styles/Inclusive")
@(private = "file")
CONCISE := #load_directory("styles/Concise")

@(private = "file")
Builtin :: struct {
	name:  string,
	files: []Load_File,
}

Load_File :: runtime.Load_Directory_File

// The order here is the order the picker shows, which goes from the pack most
// documents want to the two that are deliberately opinionated.
@(private = "file")
builtins :: proc(allocator := context.temp_allocator) -> []Builtin {
	out := make([dynamic]Builtin, 0, 6, allocator)
	add :: proc(out: ^[dynamic]Builtin, name: string, dir: []Load_File, allocator: Allocator) {
		append(out, Builtin{name, dir})
	}
	add(&out, "Plain", PLAIN, allocator)
	add(&out, "Business", BUSINESS, allocator)
	add(&out, "Academic", ACADEMIC, allocator)
	add(&out, "Journalistic", JOURNALISTIC, allocator)
	add(&out, "Inclusive", INCLUSIVE, allocator)
	add(&out, "Concise", CONCISE, allocator)
	return out[:]
}

@(private = "file")
stem :: proc(name: string) -> string {
	base := name
	if i := strings.last_index_byte(base, '/'); i >= 0 {
		base = base[i + 1:]
	}
	if i := strings.last_index_byte(base, '.'); i > 0 {
		base = base[:i]
	}
	return base
}

@(private = "file")
is_rule_file :: proc(name: string) -> bool {
	return strings.has_suffix(name, ".yml") || strings.has_suffix(name, ".yaml")
}

// engine_builtin compiles every embedded pack. A rule file that will not
// compile is recorded in `Engine.errors` and skipped, so one bad pattern
// cannot take the feature down.
engine_builtin :: proc() -> Engine {
	e := Engine {
		packs  = make([dynamic]Pack, 0, 8),
		errors = make([dynamic]string, 0, 4),
	}
	for b in builtins() {
		p := Pack {
			name   = strings.clone(b.name),
			source = strings.clone("built-in"),
			rules  = make([dynamic]Rule, 0, 16),
		}
		for f in b.files {
			if f.name == "about.txt" {
				line := string(f.data)
				if nl := strings.index_byte(line, '\n'); nl >= 0 {
					line = line[:nl]
				}
				p.about = strings.clone(strings.trim_space(line))
				continue
			}
			if !is_rule_file(f.name) {
				continue
			}
			r, err := rule_compile(b.name, stem(f.name), string(f.data))
			if err != "" {
				append(&e.errors, err)
				continue
			}
			if r.kind == .Spelling {
				e.skipped_spelling += 1
			}
			append(&p.rules, r)
		}
		if p.about == "" {
			p.about = strings.clone("")
		}
		append(&e.packs, p)
	}
	return e
}

// engine_load_dir reads a Vale `StylesPath`: one directory per style, each
// holding `.yml` rule files. Nothing outside the given path is opened, and no
// directory is walked recursively past the one level Vale itself uses.
engine_load_dir :: proc(e: ^Engine, path: string) -> (added: int, err: string) {
	h, oerr := os.open(path)
	if oerr != nil {
		return 0, fmt.aprintf("cannot open %s", path)
	}
	defer os.close(h)
	infos, rerr := os.read_dir(h, -1, context.temp_allocator)
	if rerr != nil {
		return 0, fmt.aprintf("cannot read %s", path)
	}
	for info in infos {
		if info.type != .Directory {
			continue
		}
		if strings.has_prefix(info.name, ".") || info.name == "config" || info.name == "Vocab" {
			continue
		}
		dir := fmt.tprintf("%s/%s", path, info.name)
		dh, derr := os.open(dir)
		if derr != nil {
			continue
		}
		files, ferr := os.read_dir(dh, -1, context.temp_allocator)
		os.close(dh)
		if ferr != nil {
			continue
		}
		p := Pack {
			name   = strings.clone(info.name),
			source = strings.clone(dir),
			rules  = make([dynamic]Rule, 0, 16),
		}
		for f in files {
			if f.type == .Directory {
				continue
			}
			if f.name == "about.txt" {
				if data, ok := os.read_entire_file_from_path(
					fmt.tprintf("%s/%s", dir, f.name),
					context.temp_allocator,
				); ok == nil {
					line := string(data)
					if nl := strings.index_byte(line, '\n'); nl >= 0 {
						line = line[:nl]
					}
					p.about = strings.clone(strings.trim_space(line))
				}
				continue
			}
			if !is_rule_file(f.name) {
				continue
			}
			data, derr2 := os.read_entire_file_from_path(
				fmt.tprintf("%s/%s", dir, f.name),
				context.temp_allocator,
			)
			if derr2 != nil {
				continue
			}
			r, cerr := rule_compile(info.name, stem(f.name), string(data))
			if cerr != "" {
				append(&e.errors, cerr)
				continue
			}
			if r.kind == .Spelling {
				e.skipped_spelling += 1
			}
			append(&p.rules, r)
		}
		if p.about == "" {
			p.about = strings.clone(fmt.tprintf("Loaded from %s.", dir))
		}
		if len(p.rules) == 0 {
			delete(p.name)
			delete(p.about)
			delete(p.source)
			delete(p.rules)
			continue
		}
		append(&e.packs, p)
		added += 1
	}
	return added, ""
}
