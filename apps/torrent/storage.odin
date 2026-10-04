package main

// Disk: pieces onto a multi-file layout, and back.
//
// A piece is a window over the concatenation of the torrent's files in order.
// It does not respect file boundaries, so a 256 KiB piece over a tree of small
// files can cover a dozen of them, and the last piece of the torrent is short.
// `piece_spans` in metainfo.odin does that arithmetic; everything here is about
// turning those spans into reads and writes.
//
// NOTHING IS WRITTEN UNTIL IT HASHES
//
// `storage_write_piece` refuses a piece whose SHA-1 does not match the digest
// in the metainfo, and returns an error instead. That is not belt and braces:
// a peer can send you a block of anything it likes, and a client that writes
// blocks as they arrive and verifies afterwards has already corrupted the
// user's file by the time it finds out. Verify, then write, and the file on
// disk is only ever made of pieces that were correct.

import "core:strings"

File_Prio :: enum u8 {
	Skip, // "do not download" — the file's pieces are never requested
	Low,
	Normal,
	High,
}

file_prio_name :: proc(p: File_Prio) -> string {
	switch p {
	case .Skip:
		return "Don't download"
	case .Low:
		return "Low"
	case .Normal:
		return "Normal"
	case .High:
		return "High"
	}
	return "?"
}

Storage :: struct {
	m:        ^Metainfo,
	root:     string, // the download directory the user chose
	base:     string, // root, or root/name for a multi-file torrent
	paths:    []string, // absolute path per file in the torrent
	handles:  []File, // opened lazily; nil until touched
	writable: []bool, // whether the handle was opened for writing
	prio:     []File_Prio,
	err:      string,
}

storage_open :: proc(s: ^Storage, m: ^Metainfo, download_dir: string) -> (err: string) {
	s.m = m
	s.root = strings.clone(download_dir)
	s.base = m.single_file ? strings.clone(download_dir) : path_join(download_dir, m.name)
	n := len(m.files)
	s.paths = make([]string, n)
	s.handles = make([]File, n)
	s.writable = make([]bool, n)
	s.prio = make([]File_Prio, n)
	for i in 0 ..< n {
		// `path` was sanitised at parse time: relative, no `..`, no absolute
		// component. Checked again here, because this is the line that decides
		// where bytes land on the user's disk.
		if _, perr := sanitise_path(m.files[i].path); perr != "" {
			return tsprint("file %d of this torrent has an unusable path: %s", i, perr)
		}
		s.paths[i] = m.single_file \
		? path_join(download_dir, m.files[i].path) \
		: path_join(s.base, m.files[i].path)
		s.prio[i] = .Normal
	}
	return ""
}

storage_close :: proc(s: ^Storage) {
	for h, i in s.handles {
		if h != nil {
			file_close(h)
			s.handles[i] = nil
		}
	}
}

storage_destroy :: proc(s: ^Storage) {
	storage_close(s)
	for p in s.paths {
		delete(p)
	}
	delete(s.paths)
	delete(s.handles)
	delete(s.writable)
	delete(s.prio)
	delete(s.root)
	delete(s.base)
	s^ = {}
}

@(private = "file")
handle_for :: proc(s: ^Storage, i: int, for_write: bool) -> (f: File, err: string) {
	if i < 0 || i >= len(s.paths) {
		return nil, tsprint("file index %d out of range", i)
	}
	if s.handles[i] != nil && (!for_write || s.writable[i]) {
		return s.handles[i], ""
	}
	if s.handles[i] != nil {
		file_close(s.handles[i])
		s.handles[i] = nil
	}
	if for_write {
		h, e := file_open_rw(s.paths[i])
		if e != "" {
			return nil, e
		}
		s.handles[i] = h
		s.writable[i] = true
	} else {
		h, e := file_open_read(s.paths[i])
		if e != "" {
			return nil, e
		}
		s.handles[i] = h
		s.writable[i] = false
	}
	return s.handles[i], ""
}

// storage_create_files makes every file in the layout at its final length, so
// the user sees the shape of the download immediately and a later write never
// has to extend a file. Zero-length files are created too, because the torrent
// says they exist.
storage_create_files :: proc(s: ^Storage) -> (err: string) {
	for i in 0 ..< len(s.paths) {
		f, e := handle_for(s, i, true)
		if e != "" {
			return e
		}
		want := s.m.files[i].length
		have, _ := path_size(s.paths[i])
		if have != want {
			file_truncate(f, want)
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

// storage_read_piece fills `buf` with piece `index`. A span whose file is
// missing or short reads as zeros, which then fails the hash check — which is
// what should happen.
storage_read_piece :: proc(s: ^Storage, index: int, buf: []u8) -> (n: int, err: string) {
	size := int(piece_size(s.m, index))
	if size == 0 {
		return 0, tsprint("piece %d does not exist", index)
	}
	if len(buf) < size {
		return 0, tsprint("buffer of %d bytes for a %d byte piece", len(buf), size)
	}
	for i in 0 ..< size {
		buf[i] = 0
	}
	off := 0
	for sp in piece_spans(s.m, index) {
		f, e := handle_for(s, sp.file, false)
		if e != "" {
			// A file that is not there yet is not an error during a recheck.
			off += int(sp.length)
			continue
		}
		got, rerr := file_read_at(f, buf[off:off + int(sp.length)], sp.file_off)
		_ = rerr
		_ = got
		off += int(sp.length)
	}
	return size, ""
}

// storage_read_block serves a `request` from a peer. It refuses a request that
// runs off the end of the piece rather than reading whatever is next in the
// file, because a peer that asks for one is either broken or probing.
storage_read_block :: proc(
	s: ^Storage,
	index, begin, length: int,
	buf: []u8,
) -> (
	out: []u8,
	err: string,
) {
	psize := int(piece_size(s.m, index))
	if index < 0 || index >= piece_count(s.m) {
		return nil, tsprint("request for piece %d, which does not exist", index)
	}
	if begin < 0 || length <= 0 || begin + length > psize {
		return nil, tsprint(
			"request for %d bytes at %d in piece %d, which is %d bytes long",
			length,
			begin,
			index,
			psize,
		)
	}
	if length > MAX_MESSAGE - 9 {
		return nil, tsprint("request for %d bytes is beyond this client's block cap", length)
	}
	if len(buf) < length {
		return nil, "the block buffer is too small"
	}

	abs := piece_offset(s.m, index) + i64(begin)
	want := i64(length)
	wrote := 0
	for f, fi in s.m.files {
		if f.length == 0 {
			continue
		}
		if f.offset + f.length <= abs {
			continue
		}
		if f.offset >= abs + want {
			break
		}
		within := abs - f.offset
		if within < 0 {
			within = 0
		}
		take := int(min(f.length - within, abs + want - max(abs, f.offset)))
		if take <= 0 {
			continue
		}
		h, e := handle_for(s, fi, false)
		if e != "" {
			return nil, e
		}
		got, rerr := file_read_at(h, buf[wrote:wrote + take], within)
		if rerr != "" || got != take {
			return nil, tsprint("short read of %s: %s", s.paths[fi], rerr)
		}
		wrote += take
		abs = max(abs, f.offset) + i64(take)
		want = (piece_offset(s.m, index) + i64(begin) + i64(length)) - abs
		if want <= 0 {
			break
		}
	}
	if wrote != length {
		return nil, tsprint("only %d of %d bytes were readable", wrote, length)
	}
	return buf[:length], ""
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

// storage_write_piece verifies `data` against the metainfo's digest and only
// then writes it across the files the piece covers.
storage_write_piece :: proc(s: ^Storage, index: int, data: []u8) -> (err: string) {
	size := int(piece_size(s.m, index))
	if len(data) != size {
		return tsprint("piece %d is %d bytes, not %d", index, size, len(data))
	}
	got := sha1_of(data)
	if !hash20_eq(got, s.m.pieces[index]) {
		return tsprint(
			"piece %d failed verification: SHA-1 is %s, the torrent says %s",
			index,
			hash20_hex(got, context.temp_allocator),
			hash20_hex(s.m.pieces[index], context.temp_allocator),
		)
	}
	off := 0
	for sp in piece_spans(s.m, index) {
		f, e := handle_for(s, sp.file, true)
		if e != "" {
			return e
		}
		if werr := file_write_at(f, data[off:off + int(sp.length)], sp.file_off); werr != "" {
			return tsprint("writing %s at %d: %s", s.paths[sp.file], sp.file_off, werr)
		}
		off += int(sp.length)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

storage_verify_piece :: proc(s: ^Storage, index: int, buf: []u8) -> bool {
	n, err := storage_read_piece(s, index, buf)
	if err != "" || n == 0 {
		return false
	}
	return hash20_eq(sha1_of(buf[:n]), s.m.pieces[index])
}

// storage_check_all is the resume path: re-hash everything on disk and report
// which pieces are actually there.
//
// Re-hashing on load is the only honest way to resume. A client that trusts a
// saved bitfield resumes a download that was interrupted mid-write, or whose
// files were edited or truncated underneath it, and then seeds corruption to
// the swarm. This is also exactly what the UI's "force recheck" runs.
storage_check_all :: proc(
	s: ^Storage,
	have: ^Bitfield,
	on_progress: proc(done, total: int, user: rawptr) = nil,
	user: rawptr = nil,
) -> (
	verified: int,
) {
	n := piece_count(s.m)
	buf := make([]u8, int(s.m.piece_length))
	defer delete(buf)
	for i in 0 ..< n {
		ok := storage_verify_piece(s, i, buf)
		bf_set(have, i, ok)
		if ok {
			verified += 1
		}
		if on_progress != nil && (i % 16 == 0 || i == n - 1) {
			on_progress(i + 1, n, user)
		}
	}
	return verified
}

// ---------------------------------------------------------------------------
// Removal
// ---------------------------------------------------------------------------

// storage_delete_targets lists exactly what "remove with data" would delete, so
// the confirmation dialog can name it rather than saying "are you sure".
storage_delete_targets :: proc(s: ^Storage, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, len(s.paths) + 1, allocator)
	if !s.m.single_file {
		append(&out, strings.clone(s.base, allocator))
		return out[:]
	}
	for p in s.paths {
		append(&out, strings.clone(p, allocator))
	}
	return out[:]
}

// storage_delete_data is the irreversible one. It is only ever called from a
// code path the user confirmed, and it refuses to touch anything that is not
// under the download directory it was given.
storage_delete_data :: proc(s: ^Storage) -> (err: string) {
	storage_close(s)
	root := strings.trim_right(s.root, "/")
	if root == "" || root == "/" {
		return "refusing to delete data with no download directory set"
	}
	for target in storage_delete_targets(s, context.temp_allocator) {
		t := strings.trim_right(target, "/")
		if !strings.has_prefix(t, root) || len(t) <= len(root) {
			return tsprint("refusing to delete %s: it is not under %s", t, root)
		}
		rm_rf(t)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Per-file progress, for the files tab
// ---------------------------------------------------------------------------

file_progress :: proc(m: ^Metainfo, have: Bitfield, fi: int) -> f32 {
	first, last := file_pieces(m, fi)
	if last <= first {
		return 1
	}
	got := 0
	for i in first ..< last {
		if bf_get(have, i) {
			got += 1
		}
	}
	return f32(got) / f32(last - first)
}

// piece_wanted answers whether any file this piece touches is set to be
// downloaded. A piece straddling a skipped file and a wanted one is still
// wanted, because the wanted file cannot be completed without it.
piece_wanted :: proc(s: ^Storage, index: int) -> bool {
	for sp in piece_spans(s.m, index) {
		if s.prio[sp.file] != .Skip {
			return true
		}
	}
	return false
}
