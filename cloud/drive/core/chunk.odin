// Content addressing: a file is cut into fixed 4 MiB chunks, each named by
// its SHA-256, and the file's identity is the SHA-256 of the whole.
//
// Why fixed 4 MiB:
//   - It is what Dropbox settled on, and for the same reasons: large enough
//     that a 1 GB file is 256 requests rather than thousands, small enough
//     that a dropped connection re-sends at most 4 MiB, and under Storage's
//     default per-object limit with room to spare.
//   - Fixed boundaries dedupe whole-file copies, appends, and edits that do
//     not shift bytes (most binary formats rewritten in place). They do not
//     dedupe an insertion near the start of a large file -- every boundary
//     after it moves. Content-defined chunking (FastCDC, ~1 MiB average) would;
//     it is the obvious next step and changes nothing in the schema, because a
//     version already stores its chunk list and chunk_size is advisory.
//   - Small files are one chunk. A 3 KB note costs one object.
package drivecore

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"

CHUNK_SIZE :: 4 * 1024 * 1024

File_Hash :: struct {
	size:   i64,
	hash:   string, // sha256 of the whole content, hex
	chunks: []string, // sha256 of each chunk, in order
}

sha256_hex :: proc(data: []u8, allocator := context.allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, data)
	sum: [32]u8
	sha2.final(&ctx, sum[:])
	return string(hex.encode(sum[:], allocator))
}

// hash_file reads a file once, hashing the chunks and the whole together.
hash_file :: proc(path: string, allocator := context.allocator) -> (h: File_Hash, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return {}, false
	}
	defer os.close(f)
	whole: sha2.Context_256
	sha2.init_256(&whole)
	buf := make([]u8, CHUNK_SIZE, context.temp_allocator)
	chunks := make([dynamic]string, allocator)
	for {
		n := read_full(f, buf)
		if n < 0 {
			return {}, false
		}
		if n == 0 {
			break
		}
		sha2.update(&whole, buf[:n])
		append(&chunks, sha256_hex(buf[:n], allocator))
		h.size += i64(n)
		if n < CHUNK_SIZE {
			break
		}
	}
	sum: [32]u8
	sha2.final(&whole, sum[:])
	h.hash = string(hex.encode(sum[:], allocator))
	// An empty file is one empty chunk, so every version has a chunk list and
	// the empty file is shared like any other.
	if len(chunks) == 0 {
		append(&chunks, sha256_hex(nil, allocator))
	}
	h.chunks = chunks[:]
	return h, true
}

@(private)
read_full :: proc(f: ^os.File, buf: []u8) -> int {
	got := 0
	for got < len(buf) {
		n, err := os.read(f, buf[got:])
		if n <= 0 || err != nil {
			if err != nil && err != .EOF && got == 0 {
				return -1
			}
			break
		}
		got += n
	}
	return got
}

// Fault injection for the resumption test: with PALM_DRIVE_FAULT_AFTER_CHUNKS=N
// the connection "drops" after N chunks have been sent, exactly as a pulled
// cable would look to the uploader. Off unless the variable is set.
@(private)
g_fault_left: int = -2

@(private)
fault_now :: proc() -> bool {
	if g_fault_left == -2 {
		g_fault_left = -1
		if v := os.get_env("PALM_DRIVE_FAULT_AFTER_CHUNKS", context.temp_allocator); v != "" {
			n := 0
			for ch in v {
				if ch >= '0' && ch <= '9' {
					n = n * 10 + int(ch - '0')
				}
			}
			g_fault_left = n
		}
	}
	if g_fault_left < 0 {
		return false
	}
	if g_fault_left == 0 {
		return true
	}
	g_fault_left -= 1
	return false
}

Progress :: struct {
	sent_chunks, skipped_chunks: int,
	sent_bytes:                  i64,
}

// upload_chunks sends whichever of the file's chunks the identity does not
// have yet. This is where dedupe and resumption both happen: an upload cut
// off halfway has its finished chunks in Storage already, and the next
// attempt asks again and sends only the rest.
//
// Each chunk is re-hashed as it is read for sending. If the file changed
// since it was hashed, the bytes no longer match the name and the upload
// stops rather than store a chunk under a hash it does not have.
upload_chunks :: proc(c: ^Client, path: string, h: File_Hash, prog: ^Progress = nil) -> Error {
	missing, e := missing_chunks(c, h.chunks)
	if failed(e) {
		return e
	}
	want := make(map[string]bool, context.temp_allocator)
	for m in missing {
		want[m] = true
	}
	if prog != nil {
		prog.skipped_chunks += len(h.chunks) - len(want)
	}
	if len(want) == 0 {
		return {}
	}
	f, err := os.open(path)
	if err != nil {
		return Error{-1, "", fmt.aprintf("cannot open %s", path)}
	}
	defer os.close(f)
	buf := make([]u8, CHUNK_SIZE, context.temp_allocator)
	for ch, i in h.chunks {
		if !want[ch] {
			continue
		}
		delete_key(&want, ch) // the same chunk twice in one file goes once
		os.seek(f, i64(i) * CHUNK_SIZE, .Start)
		n := read_full(f, buf)
		if n < 0 {
			return Error{-1, "", fmt.aprintf("cannot read %s", path)}
		}
		if sha256_hex(buf[:n], context.temp_allocator) != ch {
			return Error{-1, "changed", fmt.aprintf("%s changed while uploading", path)}
		}
		if fault_now() {
			return Error{0, "", "fault injected: connection dropped (PALM_DRIVE_FAULT_AFTER_CHUNKS)"}
		}
		if pe := put_chunk(c, ch, buf[:n]); failed(pe) {
			return pe
		}
		if prog != nil {
			prog.sent_chunks += 1
			prog.sent_bytes += i64(n)
		}
	}
	return {}
}

// upload_file is the whole of putting a local file into the drive: hash,
// send the missing chunks, commit the version.
upload_file :: proc(
	c: ^Client,
	path, parent, name, item: string,
	base_seq: i64,
	prog: ^Progress = nil,
) -> (
	it: Item,
	h: File_Hash,
	e: Error,
) {
	ok: bool
	h, ok = hash_file(path)
	if !ok {
		return {}, {}, Error{-1, "", fmt.aprintf("cannot read %s", path)}
	}
	if e = upload_chunks(c, path, h, prog); failed(e) {
		return
	}
	it, e = commit(c, parent, name, item, base_seq, h, mime_of(name), mtime_iso(path))
	return
}

// download_to fetches a version's chunks, checks every one against its name
// and the whole against the version's hash, and only then moves the file into
// place. A half-downloaded file is never visible under the real name.
download_to :: proc(c: ^Client, identity: string, v: Version, dest: string) -> Error {
	dir := dest[:max(0, strings.last_index_byte(dest, '/'))]
	tmp := fmt.tprintf("%s/.palm-drive-%s.part", dir, v.content_hash[:min(16, len(v.content_hash))])
	f, err := os.open(tmp, {.Write, .Create, .Trunc}, os.perm(0o644))
	if err != nil {
		return Error{-1, "", fmt.aprintf("cannot write %s", tmp)}
	}
	whole: sha2.Context_256
	sha2.init_256(&whole)
	for ch in v.chunks {
		data, e := get_chunk(c, identity, ch, context.temp_allocator)
		if failed(e) {
			os.close(f)
			os.remove(tmp)
			return e
		}
		if sha256_hex(data, context.temp_allocator) != ch {
			os.close(f)
			os.remove(tmp)
			return Error{-1, "corrupt", fmt.aprintf("chunk %s did not match its hash", ch[:12])}
		}
		sha2.update(&whole, data)
		os.write(f, data)
	}
	os.close(f)
	sum: [32]u8
	sha2.final(&whole, sum[:])
	if string(hex.encode(sum[:], context.temp_allocator)) != v.content_hash {
		os.remove(tmp)
		return Error{-1, "corrupt", "the file did not match its version's hash"}
	}
	if os.rename(tmp, dest) != nil {
		os.remove(tmp)
		return Error{-1, "", fmt.aprintf("cannot move into %s", dest)}
	}
	return {}
}

download_bytes :: proc(c: ^Client, identity: string, v: Version, allocator := context.allocator) -> (data: []u8, e: Error) {
	out := make([dynamic]u8, 0, int(v.size), allocator)
	for ch in v.chunks {
		part, ge := get_chunk(c, identity, ch, context.temp_allocator)
		if failed(ge) {
			return nil, ge
		}
		if sha256_hex(part, context.temp_allocator) != ch {
			return nil, Error{-1, "corrupt", "chunk did not match its hash"}
		}
		append(&out, ..part)
	}
	return out[:], {}
}

mtime_iso :: proc(path: string) -> string {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return ""
	}
	return iso_time(fi.modification_time)
}

mime_of :: proc(name: string) -> string {
	dot := strings.last_index_byte(name, '.')
	if dot < 0 {
		return "application/octet-stream"
	}
	ext := strings.to_lower(name[dot + 1:], context.temp_allocator)
	switch ext {
	case "txt", "log":
		return "text/plain"
	case "md":
		return "text/markdown"
	case "csv":
		return "text/csv"
	case "html", "htm":
		return "text/html"
	case "json":
		return "application/json"
	case "pdf":
		return "application/pdf"
	case "png":
		return "image/png"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "gif":
		return "image/gif"
	case "webp":
		return "image/webp"
	case "svg":
		return "image/svg+xml"
	case "mp4":
		return "video/mp4"
	case "webm":
		return "video/webm"
	case "mkv":
		return "video/x-matroska"
	case "mp3":
		return "audio/mpeg"
	case "flac":
		return "audio/flac"
	case "wav":
		return "audio/wav"
	case "zip":
		return "application/zip"
	case "docx":
		return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
	case "xlsx":
		return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
	case "pptx":
		return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
	case "odt":
		return "application/vnd.oasis.opendocument.text"
	case "ods":
		return "application/vnd.oasis.opendocument.spreadsheet"
	case "odp":
		return "application/vnd.oasis.opendocument.presentation"
	case "rtf":
		return "application/rtf"
	}
	return "application/octet-stream"
}
