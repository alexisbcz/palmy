package main

// Opening and saving.
//
// Scope is deliberate. The app lists exactly one directory at a time — the one
// the user is looking at — and never walks anywhere on its own. It starts in
// the working directory, or in the folder of a path given on the command line.
// Writing happens only to a path the user typed or chose, and `save_to`
// refuses a path that is not a `.png`, because the only encoder here is PNG and
// silently writing PNG bytes into a file called `.jpg` is a lie.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import p "palmy:."

// free_str releases a string only if it owns heap memory. `""` is a literal
// here, not an allocation, and handing a literal to the allocator is how a
// tidy-up turns into a crash.
free_str :: proc(s: string) {
	if len(s) > 0 {
		delete(s)
	}
}

// set_doc_path replaces the document's path, which is the one string in the
// document that is reassigned often enough to leak if it is not owned.
set_doc_path :: proc(d: ^Doc, path: string) {
	free_str(d.path)
	d.path = strings.clone(path)
}

Entry :: struct {
	name:   string,
	path:   string,
	is_dir: bool,
	w, h:   int,
	size:   i64,
}

cwd :: proc() -> string {
	d, err := os.get_working_directory(context.temp_allocator)
	if err != nil || d == "" {
		return "/"
	}
	return d
}

base_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i >= 0 && i + 1 < len(path) {
		return path[i + 1:]
	}
	return path
}

dir_of :: proc(path: string) -> string {
	if i := strings.last_index_byte(path, '/'); i > 0 {
		return path[:i]
	}
	if strings.has_prefix(path, "/") {
		return "/"
	}
	return "."
}

parent_of :: proc(path: string) -> string {
	if path == "" || path == "/" {
		return "/"
	}
	trimmed := strings.trim_suffix(path, "/")
	return dir_of(trimmed)
}

join_path :: proc(dir, name: string) -> string {
	if strings.has_suffix(dir, "/") {
		return fmt.tprintf("%s%s", dir, name)
	}
	return fmt.tprintf("%s/%s", dir, name)
}

absolute :: proc(path: string) -> string {
	if strings.has_prefix(path, "/") {
		return path
	}
	return join_path(cwd(), path)
}

// refresh_files lists one directory: its subdirectories and the images in it.
// Nothing recursive, nothing outside it.
refresh_files :: proc(st: ^St, dir_in: string) {
	dir := dir_in == "" ? cwd() : dir_in
	for e in st.files {
		delete(e.name)
		delete(e.path)
	}
	delete(st.files)
	free_str(st.files_dir)
	st.files_dir = strings.clone(dir)
	st.ov_sel = 0

	out := make([dynamic]Entry, 0, 32)
	infos, err := os.read_directory_by_path(dir, -1, context.temp_allocator)
	if err == nil {
		for fi in infos {
			if strings.has_prefix(fi.name, ".") {
				continue
			}
			if fi.type == .Directory {
				append(
					&out,
					Entry {
						name = strings.clone(fmt.tprintf("%s/", fi.name)),
						path = strings.clone(fi.fullpath),
						is_dir = true,
					},
				)
				continue
			}
			if !p.is_image_path(fi.name) {
				continue
			}
			w, h, _, ok := p.image_size(fi.fullpath)
			append(
				&out,
				Entry {
					name = strings.clone(fi.name),
					path = strings.clone(fi.fullpath),
					w = ok ? w : 0,
					h = ok ? h : 0,
					size = fi.size,
				},
			)
		}
	}
	// Folders first, then images, each alphabetically — a file list people can
	// scan rather than one that mirrors the inode order.
	slice.sort_by(out[:], proc(a, b: Entry) -> bool {
		if a.is_dir != b.is_dir {
			return a.is_dir
		}
		return strings.to_lower(a.name, context.temp_allocator) <
			strings.to_lower(b.name, context.temp_allocator)
	})
	st.files = out[:]
}

// open_file decodes an image into a fresh document whose single layer is that
// image. The document takes the file's dimensions, as opening a photo should.
open_file :: proc(st: ^St, path_in: string) -> bool {
	path := absolute(path_in)
	img, ok := p.load_image(path, context.temp_allocator)
	if !ok || img.w <= 0 || img.h <= 0 {
		return false
	}
	new_document(st, img.w, img.h, 1)
	l := active_layer(&st.doc)
	if l == nil {
		return false
	}
	copy(l.px, img.px)
	layer_set_name(l, base_of(path))
	l.thumb_old = true
	set_doc_path(&st.doc, path)
	st.doc.saved = true
	doc_dirty_all(&st.doc)
	refresh_files(st, dir_of(path))
	return true
}

// save_to writes the flattened composite as a PNG. The only path it touches is
// the one it is handed.
save_to :: proc(st: ^St, path_in: string) -> bool {
	path := strings.trim_space(path_in)
	if path == "" {
		toast(st, "no path given")
		return false
	}
	path = absolute(path)
	low := strings.to_lower(path, context.temp_allocator)
	if !strings.has_suffix(low, ".png") {
		toast(st, "the only encoder here is PNG — give the file a .png name")
		return false
	}
	rgba := doc_rgba(&st.doc, context.temp_allocator)
	if !p.write_png_rgba(path, rgba, st.doc.w, st.doc.h) {
		toast(st, fmt.tprintf("could not write %s", base_of(path)))
		return false
	}
	set_doc_path(&st.doc, path)
	st.doc.saved = true
	toast(st, fmt.tprintf("saved %s (%d x %d)", base_of(path), st.doc.w, st.doc.h))
	return true
}
