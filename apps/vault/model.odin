package main

// The vault's contents, and the exact bytes they become inside the AEAD.
//
// The body format is deliberately dull: little-endian fixed widths and
// length-prefixed strings, no text parsing, no escaping, nothing that can be
// confused by a value containing a delimiter. Every read is bounds-checked
// against the buffer and sets a `bad` flag rather than trusting a length that
// came out of a file.
//
// The plaintext is padded to a multiple of PAD_TO before sealing. The
// ciphertext length is visible to anyone holding the file, and without padding
// it would leak the vault's size to within a few bytes -- and so, roughly, how
// many accounts you have.

import "core:crypto"
import "core:slice"
import "core:strings"
import "core:time"

BODY_MAGIC :: "PVB1"
PAD_TO :: 4096

MAX_ENTRIES :: 100_000
MAX_STR :: 1 << 20
MAX_HISTORY :: 64

Hist :: struct {
	when_:    i64,
	password: string,
}

Entry :: struct {
	title:       string,
	username:    string,
	password:    string,
	url:         string,
	notes:       string,
	tags:        [dynamic]string,
	totp:        string, // base32 secret; "" when the entry has none
	totp_digits: u8,
	totp_period: u32,
	totp_algo:   Totp_Algo,
	created:     i64,
	modified:    i64,
	history:     [dynamic]Hist,
}

Vault :: struct {
	entries: [dynamic]Entry,
}

now_unix :: proc() -> i64 {
	return time.time_to_unix(time.now())
}

entry_new :: proc(title := "") -> Entry {
	t := now_unix()
	return Entry {
		title       = strings.clone(title),
		username    = strings.clone(""),
		password    = strings.clone(""),
		url         = strings.clone(""),
		notes       = strings.clone(""),
		tags        = make([dynamic]string),
		totp        = strings.clone(""),
		totp_digits = 6,
		totp_period = 30,
		totp_algo   = .SHA1,
		created     = t,
		modified    = t,
		history     = make([dynamic]Hist),
	}
}

// wipe_string zeroes a heap string's bytes before freeing it. A password that
// is merely `delete`d stays legible in the freed block until something else
// claims it.
wipe_string :: proc(s: string) {
	if len(s) > 0 {
		crypto.zero_explicit(raw_data(transmute([]byte)s), len(s))
	}
	delete(s)
}

entry_free :: proc(e: ^Entry) {
	delete(e.title)
	delete(e.username)
	wipe_string(e.password)
	delete(e.url)
	wipe_string(e.notes)
	for t in e.tags {
		delete(t)
	}
	delete(e.tags)
	wipe_string(e.totp)
	for h in e.history {
		wipe_string(h.password)
	}
	delete(e.history)
	e^ = {}
}

vault_free :: proc(v: ^Vault) {
	for &e in v.entries {
		entry_free(&e)
	}
	delete(v.entries)
	v^ = {}
}

// entry_set_password records the old one in the history before replacing it,
// which is the whole reason a password manager keeps a history: a site that
// rejects a rotation leaves you locked out otherwise.
entry_set_password :: proc(e: ^Entry, pw: string) {
	if e.password == pw {
		return
	}
	if len(e.password) > 0 {
		append(&e.history, Hist{when_ = e.modified, password = e.password})
		for len(e.history) > MAX_HISTORY {
			wipe_string(e.history[0].password)
			ordered_remove(&e.history, 0)
		}
	} else {
		delete(e.password)
	}
	e.password = strings.clone(pw)
	e.modified = now_unix()
}

entry_tag_text :: proc(e: ^Entry, allocator := context.temp_allocator) -> string {
	return strings.join(e.tags[:], ", ", allocator)
}

entry_set_tags :: proc(e: ^Entry, text: string) {
	for t in e.tags {
		delete(t)
	}
	clear(&e.tags)
	for part in strings.split(text, ",", context.temp_allocator) {
		t := strings.trim_space(part)
		if t == "" {
			continue
		}
		dup := false
		for have in e.tags {
			if have == t {
				dup = true
				break
			}
		}
		if !dup {
			append(&e.tags, strings.clone(t))
		}
	}
}

// ---------------------------------------------------------------------------
// Byte writer / reader
// ---------------------------------------------------------------------------

Wr :: struct {
	b: [dynamic]u8,
}

w_u8 :: proc(w: ^Wr, v: u8) {
	append(&w.b, v)
}

w_u32 :: proc(w: ^Wr, v: u32) {
	t: [4]u8
	put_u32le(t[:], v)
	append(&w.b, ..t[:])
}

w_u64 :: proc(w: ^Wr, v: u64) {
	t: [8]u8
	put_u64le(t[:], v)
	append(&w.b, ..t[:])
}

w_i64 :: proc(w: ^Wr, v: i64) {
	w_u64(w, transmute(u64)v)
}

w_str :: proc(w: ^Wr, s: string) {
	w_u32(w, u32(len(s)))
	append(&w.b, ..transmute([]u8)s)
}

Rd :: struct {
	b:   []u8,
	at:  int,
	bad: bool,
}

r_take :: proc(r: ^Rd, n: int) -> []u8 {
	if r.bad || n < 0 || r.at + n > len(r.b) {
		r.bad = true
		return nil
	}
	out := r.b[r.at:r.at + n]
	r.at += n
	return out
}

r_u8 :: proc(r: ^Rd) -> u8 {
	s := r_take(r, 1)
	if r.bad {
		return 0
	}
	return s[0]
}

r_u32 :: proc(r: ^Rd) -> u32 {
	s := r_take(r, 4)
	if r.bad {
		return 0
	}
	return get_u32le(s)
}

r_u64 :: proc(r: ^Rd) -> u64 {
	s := r_take(r, 8)
	if r.bad {
		return 0
	}
	return get_u64le(s)
}

r_i64 :: proc(r: ^Rd) -> i64 {
	return transmute(i64)r_u64(r)
}

r_str :: proc(r: ^Rd, allocator := context.allocator) -> string {
	n := r_u32(r)
	if r.bad || n > MAX_STR {
		r.bad = true
		return strings.clone("", allocator)
	}
	s := r_take(r, int(n))
	if r.bad {
		return strings.clone("", allocator)
	}
	return strings.clone(string(s), allocator)
}

// ---------------------------------------------------------------------------
// Body encode / decode
// ---------------------------------------------------------------------------

round_up :: proc(n, to: int) -> int {
	if to <= 1 {
		return n
	}
	r := n % to
	return r == 0 ? n : n + (to - r)
}

// body_encode produces the plaintext that goes inside the AEAD: a 4-byte
// payload length, the payload, then zero padding to a PAD_TO boundary.
body_encode :: proc(v: ^Vault, allocator := context.allocator) -> []byte {
	w := Wr {
		b = make([dynamic]u8, context.temp_allocator),
	}
	append(&w.b, ..transmute([]u8)string(BODY_MAGIC))
	w_u32(&w, u32(len(v.entries)))
	for &e in v.entries {
		w_str(&w, e.title)
		w_str(&w, e.username)
		w_str(&w, e.password)
		w_str(&w, e.url)
		w_str(&w, e.notes)
		w_u32(&w, u32(len(e.tags)))
		for t in e.tags {
			w_str(&w, t)
		}
		w_str(&w, e.totp)
		w_u8(&w, e.totp_digits)
		w_u32(&w, e.totp_period)
		w_u8(&w, u8(e.totp_algo))
		w_i64(&w, e.created)
		w_i64(&w, e.modified)
		w_u32(&w, u32(len(e.history)))
		for h in e.history {
			w_i64(&w, h.when_)
			w_str(&w, h.password)
		}
	}

	payload := w.b[:]
	total := round_up(4 + len(payload), PAD_TO)
	out := make([]byte, total, allocator)
	put_u32le(out[0:4], u32(len(payload)))
	copy(out[4:], payload)
	return out
}

// body_decode is handed a buffer whose tag has already verified, so this is
// not a hostile parser -- but it is still a parser, and a truncated or
// corrupted plaintext must produce an error rather than a half-built vault.
body_decode :: proc(plain: []byte) -> (v: Vault, err: string) {
	if len(plain) < 8 {
		return {}, "the vault body is truncated"
	}
	n := get_u32le(plain[0:4])
	if int(n) + 4 > len(plain) {
		return {}, "the vault body records a length past the end of the plaintext"
	}
	r := Rd {
		b = plain[4:4 + int(n)],
	}
	if string(r_take(&r, 4)) != BODY_MAGIC {
		return {}, "the vault body is not in a format this build knows"
	}
	count := r_u32(&r)
	if r.bad || count > MAX_ENTRIES {
		return {}, "the vault body declares an impossible number of entries"
	}

	v.entries = make([dynamic]Entry, 0, int(count))
	for _ in 0 ..< int(count) {
		e := Entry{}
		e.title = r_str(&r)
		e.username = r_str(&r)
		e.password = r_str(&r)
		e.url = r_str(&r)
		e.notes = r_str(&r)
		nt := r_u32(&r)
		if r.bad || nt > 256 {
			r.bad = true
		}
		e.tags = make([dynamic]string)
		if !r.bad {
			for _ in 0 ..< int(nt) {
				append(&e.tags, r_str(&r))
			}
		}
		e.totp = r_str(&r)
		e.totp_digits = r_u8(&r)
		e.totp_period = r_u32(&r)
		alg := r_u8(&r)
		e.totp_algo = alg <= u8(Totp_Algo.SHA512) ? Totp_Algo(alg) : .SHA1
		e.created = r_i64(&r)
		e.modified = r_i64(&r)
		nh := r_u32(&r)
		if r.bad || nh > MAX_HISTORY {
			r.bad = true
		}
		e.history = make([dynamic]Hist)
		if !r.bad {
			for _ in 0 ..< int(nh) {
				h := Hist{}
				h.when_ = r_i64(&r)
				h.password = r_str(&r)
				append(&e.history, h)
			}
		}
		if r.bad {
			entry_free(&e)
			vault_free(&v)
			return {}, "the vault body is corrupt"
		}
		if e.totp_digits != 6 && e.totp_digits != 8 {
			e.totp_digits = 6
		}
		if e.totp_period == 0 || e.totp_period > 3600 {
			e.totp_period = 30
		}
		append(&v.entries, e)
	}
	return v, ""
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

// entry_matches searches the fields a user would expect to search and
// deliberately does not search the password, the notes' secrets or the TOTP
// seed -- typing a fragment of one secret should not confirm another.
entry_matches :: proc(e: ^Entry, needle_lower: string) -> bool {
	if needle_lower == "" {
		return true
	}
	hay := [?]string{e.title, e.username, e.url}
	for h in hay {
		if strings.contains(strings.to_lower(h, context.temp_allocator), needle_lower) {
			return true
		}
	}
	for t in e.tags {
		if strings.contains(strings.to_lower(t, context.temp_allocator), needle_lower) {
			return true
		}
	}
	return false
}

vault_sort :: proc(v: ^Vault) {
	slice.stable_sort_by(v.entries[:], proc(a, b: Entry) -> bool {
		la := strings.to_lower(a.title, context.temp_allocator)
		lb := strings.to_lower(b.title, context.temp_allocator)
		if la != lb {
			return la < lb
		}
		return a.created < b.created
	})
}

vault_all_tags :: proc(v: ^Vault, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for &e in v.entries {
		for t in e.tags {
			seen := false
			for h in out {
				if h == t {
					seen = true
					break
				}
			}
			if !seen {
				append(&out, t)
			}
		}
	}
	slice.sort(out[:])
	return out[:]
}
