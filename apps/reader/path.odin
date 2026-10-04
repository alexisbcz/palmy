// Path arithmetic inside an archive, and percent decoding.
//
// An EPUB names every file relative to whichever file is doing the naming: the
// container points at the OPF, the OPF's manifest hrefs are relative to the
// OPF's own directory, and a chapter's `<img src>` is relative to the chapter.
// Getting this wrong is the single most common reason a book renders without
// its pictures, so it lives in one place with its own assertions.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// path_dir is the directory part of an archive path, with no trailing slash.
path_dir :: proc(p: string) -> string {
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[:i]
	}
	return ""
}

path_base :: proc(p: string) -> string {
	if i := strings.last_index_byte(p, '/'); i >= 0 {
		return p[i + 1:]
	}
	return p
}

path_ext_lower :: proc(p: string, allocator := context.temp_allocator) -> string {
	b := path_base(p)
	if i := strings.last_index_byte(b, '.'); i >= 0 {
		return strings.to_lower(b[i + 1:], allocator)
	}
	return ""
}

// path_resolve joins a relative href to a base directory and normalises away
// "." and "..". An absolute href (one starting with "/") is taken as being
// relative to the archive root, which is what readers do in practice even
// though the spec forbids it.
path_resolve :: proc(base_dir, href: string, allocator := context.temp_allocator) -> string {
	h := percent_decode(href, context.temp_allocator)
	if strings.has_prefix(h, "/") {
		h = strings.trim_left(h, "/")
		return path_normalize(h, allocator)
	}
	if base_dir == "" {
		return path_normalize(h, allocator)
	}
	joined := strings.concatenate({base_dir, "/", h}, context.temp_allocator)
	return path_normalize(joined, allocator)
}

path_normalize :: proc(p: string, allocator := context.temp_allocator) -> string {
	segs := make([dynamic]string, 0, 8, context.temp_allocator)
	for part in strings.split(p, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(segs) > 0 {
				pop(&segs)
			}
		case:
			append(&segs, part)
		}
	}
	return strings.clone(strings.join(segs[:], "/", context.temp_allocator), allocator)
}

@(private = "file")
hexv :: proc(c: u8) -> int {
	switch c {
	case '0' ..= '9':
		return int(c - '0')
	case 'a' ..= 'f':
		return int(c - 'a') + 10
	case 'A' ..= 'F':
		return int(c - 'A') + 10
	}
	return -1
}

// percent_decode undoes URL escaping. Manifest hrefs are URLs, so a chapter
// named "Chapter 1.xhtml" arrives as "Chapter%201.xhtml" and will not be found
// in the archive under that name.
percent_decode :: proc(s: string, allocator := context.temp_allocator) -> string {
	if !strings.contains(s, "%") {
		return strings.clone(s, allocator)
	}
	out := make([dynamic]u8, 0, len(s), context.temp_allocator)
	i := 0
	for i < len(s) {
		if s[i] == '%' && i + 2 < len(s) {
			hi, lo := hexv(s[i + 1]), hexv(s[i + 2])
			if hi >= 0 && lo >= 0 {
				append(&out, u8(hi * 16 + lo))
				i += 3
				continue
			}
		}
		append(&out, s[i])
		i += 1
	}
	return strings.clone(string(out[:]), allocator)
}

// tfmt is `fmt.tprintf` under a shorter name, because this app formats a lot
// of short-lived strings and the noise adds up.
tfmt :: proc(format: string, args: ..any) -> string {
	return fmt.tprintf(format, ..args)
}

// read_file is `os.read_entire_file_from_path` with a message instead of an
// error value, since every caller here wants to tell the reader what went
// wrong rather than branch on it.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []u8, err: string) {
	d, e := os.read_entire_file_from_path(path, allocator)
	if e != nil {
		return nil, tfmt("cannot read %s", path_base(path))
	}
	if len(d) == 0 {
		delete(d, allocator)
		return nil, tfmt("%s is empty", path_base(path))
	}
	return d, ""
}

// read_head reads the first `n` bytes, which is how a file's real format is
// decided when its name lies about it.
read_head :: proc(path: string, n: int) -> (data: []u8, err: string) {
	fh, oerr := os.open(path)
	if oerr != nil {
		return nil, "cannot open"
	}
	defer os.close(fh)
	buf := make([]u8, n, context.temp_allocator)
	got, rerr := os.read(fh, buf)
	if rerr != nil || got <= 0 {
		return nil, "cannot read"
	}
	return buf[:got], ""
}
