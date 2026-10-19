// Identities on this device, and where each one's notes live.
//
//	~/Notes/                      ($PALM_NOTES_ROOT)
//	  camille/                    one folder per identity, named by its handle
//	    .palm/identity.json       which cloud identity this folder belongs to
//	    .palm/index.json          what sync last saw of each note
//	    .palm/sync/<id>/*.state   the CRDT copy of each note (offline first)
//	    Inbox.md …                notes at the top level are the inbox
//	    Travel/Lisbon.md          a folder is a notebook
//	    Shared/alice.martin/…     notes other identities shared with this one
//	    .trash/…                  the trash, still Markdown
//	    attachments/              files notes embed
//	  northwind/
//	    …
//
// Every identity's notes are plain files in their own folder, so the
// separation is visible in `ls`, an identity can be removed from a device by
// deleting one folder, and no file is ever in two identities at once.
//
// $PALMY_NOTES_DIR still points the whole application at one folder, which
// is how the self-test runs and how a notebook with no account works.
package main

import "core:encoding/json"
import "core:fmt"
import ck "../cloudkit"
import "core:os"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

LEGACY_DIR :: ".local/share/palmy-notes"
LOCAL_HANDLE :: "local"

Ident :: struct {
	handle: string,
	name:   string, // display name
	id:     string, // public.identities.id once the folder is bound to the cloud
	color:  string, // a palette name: teal, blue, amber, violet, rose, emerald, indigo, slate
	kind:   string, // personal, work, public, project, or "" for a local notebook
	root:   string,
}

ident_free :: proc(i: ^Ident) {
	delete(i.handle)
	delete(i.name)
	delete(i.id)
	delete(i.color)
	delete(i.kind)
	delete(i.root)
	i^ = {}
}

idents_free :: proc(xs: ^[dynamic]Ident) {
	for &x in xs {ident_free(&x)}
	delete(xs^)
	xs^ = nil
}

ident_bound :: proc(i: Ident) -> bool {
	return i.id != ""
}

// notes_home is the folder that holds one folder per identity.
notes_home :: proc(allocator := context.allocator) -> string {
	if r := os.get_env("PALM_NOTES_ROOT", context.temp_allocator); r != "" {
		return strings.clone(r, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	return fmt.aprintf("%s/Notes", home, allocator = allocator)
}

// idents_load lists the identities whose notes are on this device. A scoped
// process ($PALM_IDENTITY) sees its own identity and nothing else, the same
// rule the database applies to its token.
idents_load :: proc(allocator := context.allocator) -> [dynamic]Ident {
	context.allocator = allocator
	out := make([dynamic]Ident)
	if one := os.get_env("PALMY_NOTES_DIR", context.temp_allocator); one != "" {
		if !os.is_dir(one) {
			ck.make_dirs(one)
		}
		// A process scoped to an identity and pointed at that identity's own
		// folder (~/Notes/<handle>, as the assistant runs this) reads it as
		// that identity's even before sync has bound it; any other folder
		// stays the local notebook, which a scope then hides.
		handle := LOCAL_HANDLE
		scope := os.get_env("PALM_IDENTITY", context.temp_allocator)
		trimmed := strings.trim_right(one, "/")
		if scope != "" && scope != LOCAL_HANDLE && trimmed[strings.last_index_byte(trimmed, '/') + 1:] == scope {
			handle = scope
		}
		append(&out, ident_read(one, handle))
	} else {
		home := notes_home(context.temp_allocator)
		if h, err := os.open(home); err == nil {
			infos, _ := os.read_dir(h, -1, context.temp_allocator)
			os.close(h)
			for info in infos {
				if info.type != .Directory || strings.has_prefix(info.name, ".") {
					continue
				}
				append(&out, ident_read(fmt.tprintf("%s/%s", home, info.name), info.name))
			}
		}
		if len(out) == 0 {
			// The notebook this application kept before identities existed is
			// the device's local notebook until the person signs in. Nothing is
			// moved: it is read where it is.
			legacy := fmt.tprintf("%s/%s", os.get_env("HOME", context.temp_allocator), LEGACY_DIR)
			if os.is_dir(legacy) {
				append(&out, ident_read(legacy, LOCAL_HANDLE))
			} else {
				root := fmt.tprintf("%s/%s", home, LOCAL_HANDLE)
				ck.make_dirs(root)
				append(&out, ident_read(root, LOCAL_HANDLE))
			}
		}
	}

	scope := os.get_env("PALM_IDENTITY", context.temp_allocator)
	if scope != "" {
		#reverse for &x, i in out {
			if x.handle != scope {
				ident_free(&x)
				ordered_remove(&out, i)
			}
		}
	}
	slice.sort_by(out[:], proc(a, b: Ident) -> bool {
		if (a.id == "") != (b.id == "") {
			return a.id != ""
		}
		ka, kb := kind_rank(a.kind), kind_rank(b.kind)
		if ka != kb {
			return ka < kb
		}
		return a.name < b.name
	})
	return out
}

@(private = "file")
kind_rank :: proc(k: string) -> int {
	switch k {
	case "personal":
		return 0
	case "work":
		return 1
	case "project":
		return 2
	case "public":
		return 3
	}
	return 4
}

// ident_read builds an Ident from a folder: its identity.json when the folder
// is bound to a cloud identity, otherwise a local notebook named after it.
ident_read :: proc(root, fallback_handle: string) -> Ident {
	i := Ident {
		root   = strings.clone(root),
		handle = strings.clone(fallback_handle),
		color  = strings.clone("slate"),
	}
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/.palm/identity.json", root), context.temp_allocator)
	if err == nil {
		v, perr := json.parse(data, allocator = context.temp_allocator)
		if perr == .None {
			if o, ok := v.(json.Object); ok {
				get :: proc(o: json.Object, k: string) -> string {
					s, _ := o[k].(json.String)
					return s
				}
				if h := get(o, "handle"); h != "" {
					delete(i.handle)
					i.handle = strings.clone(h)
				}
				i.id = strings.clone(get(o, "id"))
				i.name = strings.clone(get(o, "display_name"))
				if c := get(o, "color"); c != "" {
					delete(i.color)
					i.color = strings.clone(c)
				}
				i.kind = strings.clone(get(o, "kind"))
			}
		}
	}
	if i.name == "" {
		delete(i.name)
		i.name = strings.clone(i.handle == LOCAL_HANDLE ? "On this device" : i.handle)
	}
	return i
}

// ident_bind records which cloud identity a folder belongs to. From then on
// `notes sync` syncs it, and the folder's name stays the handle.
ident_bind :: proc(root, id, handle, name, color, kind: string) -> bool {
	ck.make_dirs(fmt.tprintf("%s/.palm", root))
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{\n  \"id\": ")
	json_q(&b, id)
	strings.write_string(&b, ",\n  \"handle\": ")
	json_q(&b, handle)
	strings.write_string(&b, ",\n  \"display_name\": ")
	json_q(&b, name)
	strings.write_string(&b, ",\n  \"color\": ")
	json_q(&b, color)
	strings.write_string(&b, ",\n  \"kind\": ")
	json_q(&b, kind)
	strings.write_string(&b, "\n}\n")
	return os.write_entire_file(fmt.tprintf("%s/.palm/identity.json", root), transmute([]u8)strings.to_string(b)) == nil
}

json_q :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			strings.write_string(b, "\\\"")
		case '\\':
			strings.write_string(b, "\\\\")
		case '\n':
			strings.write_string(b, "\\n")
		case '\r':
			strings.write_string(b, "\\r")
		case '\t':
			strings.write_string(b, "\\t")
		case:
			if c < 0x20 {
				fmt.sbprintf(b, "\\u%04x", int(c))
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}

ident_find :: proc(xs: []Ident, key: string) -> int {
	for x, i in xs {
		if x.handle == key || x.id == key {
			return i
		}
	}
	low := strings.to_lower(key, context.temp_allocator)
	for x, i in xs {
		if strings.to_lower(x.name, context.temp_allocator) == low || x.kind == low {
			return i
		}
	}
	return -1
}

// ---------------------------------------------------------------------------
// The identity colour, the same eight hues the shell uses (cloud/docs/shell.md)
// ---------------------------------------------------------------------------

identity_hex :: proc(color: string, dark: bool) -> u32 {
	switch color {
	case "teal":
		return dark ? 0x2dd4bf : 0x0f9488
	case "blue", "sky", "cyan":
		return dark ? 0x60a5fa : 0x2563eb
	case "amber", "orange", "yellow":
		return dark ? 0xfbbf24 : 0xc2620a
	case "violet", "purple", "fuchsia":
		return dark ? 0xa78bfa : 0x7c3aed
	case "rose", "pink", "red":
		return dark ? 0xfb7185 : 0xe11d48
	case "emerald", "green", "lime":
		return dark ? 0x34d399 : 0x059669
	case "indigo":
		return dark ? 0x818cf8 : 0x4f46e5
	}
	return dark ? 0x94a3b8 : 0x475569
}

monogram_of :: proc(name: string) -> string {
	for r, i in name {
		if r != ' ' {
			return strings.to_upper(name[i:i + utf8.rune_size(r)], context.temp_allocator)
		}
	}
	return "?"
}
