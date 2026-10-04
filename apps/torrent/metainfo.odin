package main

// The metainfo file (BEP 3), and the map from pieces onto files.
//
// THE INFO-HASH
//
// `info_hash` is SHA-1 over the bencoded `info` dictionary **exactly as those
// bytes appeared in the .torrent file** — `src[info.start:info.end]`, taken
// from the byte range the decoder recorded. It is NOT SHA-1 over this
// program's re-encoding of the parsed dictionary.
//
// The two are the same only when the file's `info` dictionary already had its
// keys in bencoding order and its integers spelled canonically. When it did
// not, re-encoding gives a different 20 bytes, which means a different
// info-hash, which means the tracker files you under a swarm nobody else is in
// and every peer you reach rejects your handshake. There is no error message
// for this; it simply never works. `selftest.odin` proves the distinction with
// a torrent whose `info` keys are deliberately out of order.
//
// PATHS
//
// A .torrent arrives from a stranger and its `path` lists are attacker
// controlled. `sanitise_path` rejects an absolute path, any `..` component, a
// `.` component, an empty component and a component containing a NUL or a
// slash. A client that joins those strings onto the download directory without
// checking writes wherever the torrent tells it to.

import "core:strings"

Torrent_File :: struct {
	path:   string, // relative, '/'-joined, already sanitised
	length: i64,
	offset: i64, // start of this file within the concatenated piece stream
}

Metainfo :: struct {
	info_hash:     Hash20,
	name:          string, // the single file's name, or the directory's
	piece_length:  i64,
	pieces:        []Hash20,
	total_length:  i64,
	files:         []Torrent_File,
	single_file:   bool,
	announce:      string,
	announce_list: []string, // flattened, announce first, de-duplicated
	private:       bool,
	comment:       string,
	created_by:    string,
	creation_date: i64,

	// The raw file, kept because `pieces` and the info-hash alias it, and
	// because re-saving the torrent should preserve it byte for byte.
	raw:           []u8,
	info_span:     [2]int, // the byte range the info-hash was taken over
}

MAX_PIECE_LENGTH :: 64 << 20
MIN_PIECE_LENGTH :: 1 << 10

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

metainfo_load :: proc(path: string, allocator := context.allocator) -> (m: Metainfo, err: string) {
	data, ok := read_file(path, allocator)
	if !ok {
		return {}, tsprint("cannot read %s", path)
	}
	return metainfo_parse(data, allocator)
}

// metainfo_parse takes ownership of `raw`: the result aliases it.
metainfo_parse :: proc(raw: []u8, allocator := context.allocator) -> (m: Metainfo, err: string) {
	root, derr := ben_decode(raw, allocator)
	if derr != "" {
		return {}, tsprint("not a torrent file: %s", derr)
	}
	if root.kind != .Dict {
		return {}, "not a torrent file: the top level is not a dictionary"
	}
	info, has_info := ben_get(root, "info")
	if !has_info || info.kind != .Dict {
		return {}, "not a torrent file: no `info` dictionary"
	}

	m.raw = raw
	m.info_span = {info.start, info.end}
	// THE one place the info-hash is computed, over the original bytes.
	m.info_hash = sha1_of(raw[info.start:info.end])

	name, has_name := ben_str_of(info, "name")
	if !has_name || name == "" {
		return {}, "the info dictionary has no `name`"
	}
	// The name becomes a directory or file name on disk, so it gets the same
	// treatment as any path component.
	if nerr := check_component(name); nerr != "" {
		return {}, tsprint("the torrent's name is not usable as a path: %s", nerr)
	}
	m.name = strings.clone(name, allocator)

	plen, has_plen := ben_int_of(info, "piece length")
	if !has_plen {
		return {}, "the info dictionary has no `piece length`"
	}
	if plen < MIN_PIECE_LENGTH || plen > MAX_PIECE_LENGTH {
		return {}, tsprint("implausible piece length %d", plen)
	}
	m.piece_length = plen

	pieces, has_pieces := ben_bytes_of(info, "pieces")
	if !has_pieces {
		return {}, "the info dictionary has no `pieces`"
	}
	if len(pieces) == 0 || len(pieces) % 20 != 0 {
		return {}, tsprint("`pieces` is %d bytes, which is not a whole number of SHA-1 digests", len(pieces))
	}
	hashes := make([]Hash20, len(pieces) / 20, allocator)
	for i in 0 ..< len(hashes) {
		copy(hashes[i][:], pieces[i * 20:(i + 1) * 20])
	}
	m.pieces = hashes

	// Single-file or multi-file, never both.
	flist, has_files := ben_list_of(info, "files")
	single_len, has_length := ben_int_of(info, "length")
	if has_files && has_length {
		return {}, "the info dictionary has both `length` and `files`"
	}
	if !has_files && !has_length {
		return {}, "the info dictionary has neither `length` nor `files`"
	}

	if has_length {
		if single_len < 0 {
			return {}, tsprint("negative file length %d", single_len)
		}
		m.single_file = true
		files := make([]Torrent_File, 1, allocator)
		files[0] = Torrent_File {
			path   = strings.clone(name, allocator),
			length = single_len,
			offset = 0,
		}
		m.files = files
		m.total_length = single_len
	} else {
		if len(flist) == 0 {
			return {}, "`files` is empty"
		}
		files := make([dynamic]Torrent_File, 0, len(flist), allocator)
		off: i64 = 0
		seen := make(map[string]bool, len(flist), context.temp_allocator)
		for fv, i in flist {
			if fv.kind != .Dict {
				return {}, tsprint("files[%d] is not a dictionary", i)
			}
			flen, lok := ben_int_of(fv, "length")
			if !lok || flen < 0 {
				return {}, tsprint("files[%d] has no usable `length`", i)
			}
			pl, pok := ben_list_of(fv, "path")
			if !pok || len(pl) == 0 {
				return {}, tsprint("files[%d] has no `path`", i)
			}
			comps := make([dynamic]string, 0, len(pl), context.temp_allocator)
			for cv, j in pl {
				if cv.kind != .Str {
					return {}, tsprint("files[%d].path[%d] is not a string", i, j)
				}
				c := string(cv.str)
				if cerr := check_component(c); cerr != "" {
					return {}, tsprint("files[%d].path[%d]: %s", i, j, cerr)
				}
				append(&comps, c)
			}
			joined := strings.join(comps[:], "/", allocator)
			if joined in seen {
				return {}, tsprint("two files in this torrent are both %q", joined)
			}
			seen[joined] = true
			append(&files, Torrent_File{path = joined, length = flen, offset = off})
			off += flen
		}
		m.files = files[:]
		m.total_length = off
	}

	// The piece count has to match the total length, or the piece-to-file map
	// is nonsense and a request for the last piece runs off the end.
	want := (m.total_length + m.piece_length - 1) / m.piece_length
	if m.total_length == 0 {
		want = 0
	}
	if i64(len(m.pieces)) != want {
		return {}, tsprint(
			"%d piece hashes for %d bytes at %d bytes a piece; expected %d",
			len(m.pieces),
			m.total_length,
			m.piece_length,
			want,
		)
	}

	if ann, aok := ben_str_of(root, "announce"); aok {
		m.announce = strings.clone(ann, allocator)
	}
	m.announce_list = collect_trackers(root, m.announce, allocator)
	if pv, pok := ben_int_of(info, "private"); pok {
		m.private = pv != 0
	}
	if c, cok := ben_str_of(root, "comment"); cok {
		m.comment = strings.clone(c, allocator)
	}
	if c, cok := ben_str_of(root, "created by"); cok {
		m.created_by = strings.clone(c, allocator)
	}
	if d, dok := ben_int_of(root, "creation date"); dok {
		m.creation_date = d
	}
	return m, ""
}

@(private = "file")
collect_trackers :: proc(root: Ben, announce: string, allocator: runtime_allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	add :: proc(out: ^[dynamic]string, s: string, allocator: runtime_allocator) {
		t := strings.trim_space(s)
		if t == "" {
			return
		}
		for existing in out {
			if existing == t {
				return
			}
		}
		append(out, strings.clone(t, allocator))
	}
	add(&out, announce, allocator)
	// `announce-list` is a list of tiers, each a list of URLs.
	if tiers, ok := ben_list_of(root, "announce-list"); ok {
		for tier in tiers {
			if tier.kind == .Str {
				add(&out, string(tier.str), allocator)
				continue
			}
			if tier.kind != .List {
				continue
			}
			for u in tier.list {
				if u.kind == .Str {
					add(&out, string(u.str), allocator)
				}
			}
		}
	}
	return out[:]
}

// check_component is the path gate. "" means the component is safe.
check_component :: proc(c: string) -> string {
	if c == "" {
		return "an empty path component"
	}
	if c == "." || c == ".." {
		return tsprint("the path component %q escapes the download directory", c)
	}
	if c[0] == '/' {
		return "an absolute path"
	}
	for ch in transmute([]u8)c {
		if ch == '/' {
			return "a path component containing a slash"
		}
		if ch == 0 {
			return "a path component containing a NUL"
		}
	}
	return ""
}

// sanitise_path checks a '/'-joined relative path the same way, for the paths
// that come out of a magnet link or a resume file rather than a torrent.
sanitise_path :: proc(path: string) -> (clean: string, err: string) {
	if path == "" {
		return "", "an empty path"
	}
	parts := strings.split(path, "/", context.temp_allocator)
	for p in parts {
		if e := check_component(p); e != "" {
			return "", e
		}
	}
	return path, ""
}

metainfo_destroy :: proc(m: ^Metainfo) {
	delete(m.raw)
	delete(m.pieces)
	for f in m.files {
		delete(f.path)
	}
	delete(m.files)
	delete(m.name)
	delete(m.announce)
	for a in m.announce_list {
		delete(a)
	}
	delete(m.announce_list)
	delete(m.comment)
	delete(m.created_by)
	m^ = {}
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------

piece_count :: proc(m: ^Metainfo) -> int {
	return len(m.pieces)
}

// piece_size is the length of piece `i`. Only the last one differs, and
// forgetting that is how a client ends up with a last piece that never
// verifies.
piece_size :: proc(m: ^Metainfo, i: int) -> i64 {
	if i < 0 || i >= len(m.pieces) {
		return 0
	}
	if i == len(m.pieces) - 1 {
		rem := m.total_length - i64(i) * m.piece_length
		return rem
	}
	return m.piece_length
}

piece_offset :: proc(m: ^Metainfo, i: int) -> i64 {
	return i64(i) * m.piece_length
}

// Piece_Span is one contiguous run of a piece inside one file.
Piece_Span :: struct {
	file:     int,
	file_off: i64,
	length:   i64,
}

// piece_spans maps piece `index` onto the files it covers. A piece straddling a
// boundary produces several spans; a zero-length file contributes none, which
// is why the loop skips rather than stops on one.
piece_spans :: proc(
	m: ^Metainfo,
	index: int,
	allocator := context.temp_allocator,
) -> []Piece_Span {
	out := make([dynamic]Piece_Span, 0, 4, allocator)
	start := piece_offset(m, index)
	remaining := piece_size(m, index)
	if remaining <= 0 {
		return out[:]
	}
	for f, fi in m.files {
		if f.length == 0 {
			continue
		}
		fend := f.offset + f.length
		if fend <= start {
			continue
		}
		if f.offset >= start + remaining {
			break
		}
		within := start - f.offset
		if within < 0 {
			within = 0
		}
		take := min(f.length - within, start + remaining - max(start, f.offset))
		if take <= 0 {
			continue
		}
		append(&out, Piece_Span{file = fi, file_off = within, length = take})
		start = max(start, f.offset) + take
		remaining = (piece_offset(m, index) + piece_size(m, index)) - start
		if remaining <= 0 {
			break
		}
	}
	return out[:]
}

// file_pieces is the inverse: the half-open range of pieces that file `fi`
// touches, which is what a per-file priority and a per-file progress bar need.
file_pieces :: proc(m: ^Metainfo, fi: int) -> (first: int, last: int) {
	if fi < 0 || fi >= len(m.files) || m.piece_length == 0 {
		return 0, 0
	}
	f := m.files[fi]
	if f.length == 0 {
		return 0, 0
	}
	first = int(f.offset / m.piece_length)
	last = int((f.offset + f.length - 1) / m.piece_length) + 1
	return first, last
}

BLOCK_SIZE :: 16 * 1024

// blocks_in_piece is the number of 16 KiB requests a piece is cut into. The
// last block of the last piece is short.
blocks_in_piece :: proc(m: ^Metainfo, index: int) -> int {
	sz := piece_size(m, index)
	return int((sz + BLOCK_SIZE - 1) / BLOCK_SIZE)
}

block_size_at :: proc(m: ^Metainfo, index, block: int) -> int {
	sz := piece_size(m, index)
	off := i64(block) * BLOCK_SIZE
	if off >= sz {
		return 0
	}
	return int(min(i64(BLOCK_SIZE), sz - off))
}

// ---------------------------------------------------------------------------
// Making a torrent
// ---------------------------------------------------------------------------

Make_Opts :: struct {
	piece_length: i64,
	announce:     string,
	comment:      string,
	created_by:   string,
	private:      bool,
	name:         string, // defaults to the base name of the path
}

// metainfo_create builds a .torrent for a file or a directory tree on disk,
// hashing every piece. The result is a bencoded buffer whose dictionary keys
// are in order, because `ben_encode` puts them there.
metainfo_create :: proc(
	root_path: string,
	opts: Make_Opts,
	allocator := context.allocator,
) -> (
	data: []u8,
	err: string,
) {
	plen := opts.piece_length
	if plen <= 0 {
		plen = 256 * 1024
	}
	if plen < MIN_PIECE_LENGTH || plen > MAX_PIECE_LENGTH || (plen & (plen - 1)) != 0 {
		return nil, tsprint("piece length %d must be a power of two between %d and %d", plen, MIN_PIECE_LENGTH, MAX_PIECE_LENGTH)
	}

	is_dir := path_is_dir(root_path)
	name := opts.name
	if name == "" {
		name = path_base(root_path)
	}

	// Collect the files in the order the pieces are laid out in: sorted by
	// relative path, which is what every other maker does and what makes the
	// result reproducible.
	entries := make([dynamic]Walk_Entry, 0, 16, context.temp_allocator)
	if is_dir {
		found := walk_tree(root_path, context.temp_allocator)
		if len(found) == 0 {
			return nil, tsprint("%s contains no files", root_path)
		}
		append(&entries, ..found)
	} else {
		sz, ok := path_size(root_path)
		if !ok {
			return nil, tsprint("cannot stat %s", root_path)
		}
		append(&entries, Walk_Entry{rel = path_base(root_path), abs = root_path, size = sz})
	}

	total: i64 = 0
	for e in entries {
		total += e.size
	}
	if total == 0 {
		return nil, tsprint("%s is empty", root_path)
	}

	npieces := int((total + plen - 1) / plen)
	hashes := make([]u8, npieces * 20, context.temp_allocator)

	// Hash the concatenation of the files, in order, in piece-sized windows.
	buf := make([]u8, int(plen), context.temp_allocator)
	fill := 0
	pi := 0
	flush :: proc(hashes: []u8, pi: ^int, buf: []u8, fill: ^int) {
		if fill^ == 0 {
			return
		}
		h := sha1_of(buf[:fill^])
		copy(hashes[pi^ * 20:], h[:])
		pi^ += 1
		fill^ = 0
	}
	for e in entries {
		if e.size == 0 {
			continue
		}
		f, oerr := file_open_read(e.abs)
		if oerr != "" {
			return nil, oerr
		}
		off: i64 = 0
		for off < e.size {
			want := min(len(buf) - fill, int(e.size - off))
			n, rerr := file_read_at(f, buf[fill:fill + want], off)
			if rerr != "" || n <= 0 {
				file_close(f)
				return nil, tsprint("reading %s at %d: %s", e.abs, off, rerr)
			}
			fill += n
			off += i64(n)
			if fill == len(buf) {
				flush(hashes, &pi, buf, &fill)
			}
		}
		file_close(f)
	}
	flush(hashes, &pi, buf, &fill)
	if pi != npieces {
		return nil, tsprint("hashed %d pieces, expected %d", pi, npieces)
	}

	info_pairs := make([dynamic]Ben_Pair, 0, 8, context.temp_allocator)
	append(&info_pairs, bp("name", bstr(name)))
	append(&info_pairs, bp("piece length", bnum(plen)))
	append(&info_pairs, bp("pieces", bbytes(hashes)))
	if opts.private {
		append(&info_pairs, bp("private", bnum(1)))
	}
	if is_dir {
		fl := make([dynamic]Ben, 0, len(entries), context.temp_allocator)
		for e in entries {
			comps := strings.split(e.rel, "/", context.temp_allocator)
			cl := make([dynamic]Ben, 0, len(comps), context.temp_allocator)
			for c in comps {
				append(&cl, bstr(c))
			}
			append(
				&fl,
				bdict(
					{bp("length", bnum(e.size)), bp("path", blist(cl[:], context.temp_allocator))},
					context.temp_allocator,
				),
			)
		}
		append(&info_pairs, bp("files", blist(fl[:], context.temp_allocator)))
	} else {
		append(&info_pairs, bp("length", bnum(total)))
	}

	root_pairs := make([dynamic]Ben_Pair, 0, 8, context.temp_allocator)
	append(&root_pairs, bp("info", bdict(info_pairs[:], context.temp_allocator)))
	if opts.announce != "" {
		append(&root_pairs, bp("announce", bstr(opts.announce)))
		append(
			&root_pairs,
			bp(
				"announce-list",
				blist(
					{blist({bstr(opts.announce)}, context.temp_allocator)},
					context.temp_allocator,
				),
			),
		)
	}
	if opts.comment != "" {
		append(&root_pairs, bp("comment", bstr(opts.comment)))
	}
	cb := opts.created_by == "" ? "palmy-torrent/1.0" : opts.created_by
	append(&root_pairs, bp("created by", bstr(cb)))
	append(&root_pairs, bp("creation date", bnum(unix_now())))

	return ben_encode(bdict(root_pairs[:], context.temp_allocator), allocator), ""
}

// ---------------------------------------------------------------------------
// Magnet links
// ---------------------------------------------------------------------------

Magnet :: struct {
	info_hash: Hash20,
	name:      string,
	trackers:  []string,
	have_hash: bool,
}

// magnet_parse reads a `magnet:?xt=urn:btih:...` URI.
//
// This client can add a magnet only when the matching .torrent is already in
// its state directory, because fetching metadata from a stranger (BEP 9 over a
// DHT) is exactly the thing the safety gate forbids. The parse is still real,
// and is what the UI's "add magnet" validates against.
magnet_parse :: proc(uri: string, allocator := context.allocator) -> (mg: Magnet, err: string) {
	s := strings.trim_space(uri)
	if !strings.has_prefix(s, "magnet:?") {
		return {}, "not a magnet URI (it must start with `magnet:?`)"
	}
	q := s[len("magnet:?"):]
	trackers := make([dynamic]string, 0, 2, allocator)
	for field in strings.split_iterator(&q, "&") {
		eq := strings.index_byte(field, '=')
		if eq < 0 {
			continue
		}
		k := field[:eq]
		v := url_decode(field[eq + 1:], context.temp_allocator)
		switch k {
		case "xt":
			if !strings.has_prefix(v, "urn:btih:") {
				continue
			}
			hx := v[len("urn:btih:"):]
			if len(hx) == 40 {
				h, ok := hash20_from_hex(hx)
				if !ok {
					return {}, tsprint("xt=urn:btih:%s is not 40 hex digits", hx)
				}
				mg.info_hash = h
				mg.have_hash = true
			} else if len(hx) == 32 {
				b, ok := base32_decode(hx, context.temp_allocator)
				if !ok || len(b) != 20 {
					return {}, tsprint("xt=urn:btih:%s is not a base32 info-hash", hx)
				}
				copy(mg.info_hash[:], b)
				mg.have_hash = true
			} else {
				return {}, tsprint("xt=urn:btih:%s is neither 40 hex nor 32 base32 characters", hx)
			}
		case "dn":
			mg.name = strings.clone(v, allocator)
		case "tr":
			append(&trackers, strings.clone(v, allocator))
		}
	}
	if !mg.have_hash {
		return {}, "the magnet URI has no `xt=urn:btih:` info-hash"
	}
	mg.trackers = trackers[:]
	return mg, ""
}

magnet_of :: proc(m: ^Metainfo, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "magnet:?xt=urn:btih:")
	strings.write_string(&b, hash20_hex(m.info_hash, context.temp_allocator))
	strings.write_string(&b, "&dn=")
	strings.write_string(&b, url_encode(m.name, context.temp_allocator))
	for tr in m.announce_list {
		strings.write_string(&b, "&tr=")
		strings.write_string(&b, url_encode(tr, context.temp_allocator))
	}
	return strings.to_string(b)
}

// base32_decode is RFC 4648 without padding, which is the older magnet
// spelling of an info-hash.
base32_decode :: proc(s: string, allocator := context.allocator) -> (out: []u8, ok: bool) {
	acc: u32
	bits: uint
	buf := make([dynamic]u8, 0, len(s) * 5 / 8 + 1, allocator)
	for c in transmute([]u8)s {
		v: u32
		switch c {
		case 'A' ..= 'Z':
			v = u32(c - 'A')
		case 'a' ..= 'z':
			v = u32(c - 'a')
		case '2' ..= '7':
			v = u32(c - '2') + 26
		case '=':
			continue
		case:
			delete(buf)
			return nil, false
		}
		acc = acc << 5 | v
		bits += 5
		if bits >= 8 {
			bits -= 8
			append(&buf, u8(acc >> bits))
		}
	}
	return buf[:], true
}
