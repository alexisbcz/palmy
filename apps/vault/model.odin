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

// PVB2 is PVB1 with each entry's type, id, extra URLs, custom fields and
// passkey appended. A PVB1 body still opens; the next save writes PVB2.
BODY_MAGIC :: "PVB2"
BODY_MAGIC_V1 :: "PVB1"
PAD_TO :: 4096

MAX_ENTRIES :: 100_000
MAX_STR :: 1 << 20
MAX_HISTORY :: 64
MAX_FIELDS :: 256

Hist :: struct {
	when_:    i64,
	password: string,
}

// What an item is. The kind decides which fields the editor offers and which
// icon the list shows; every kind has the same record underneath, so a sync,
// a share or an export never needs to know about a new one.
Item_Kind :: enum u8 {
	Login    = 0,
	Passkey  = 1,
	Card     = 2,
	Note     = 3,
	Document = 4, // an identity document: passport, ID card, driving licence
	Totp     = 5, // an authenticator entry with no password
}

KIND_LABEL := [Item_Kind]string {
	.Login    = "Login",
	.Passkey  = "Passkey",
	.Card     = "Card",
	.Note     = "Secure note",
	.Document = "Identity document",
	.Totp     = "Authenticator",
}

// A labelled value: the card number, a passport's expiry, a security
// question. `secret` decides whether it is masked and wiped like a password.
Kv :: struct {
	label:  string,
	value:  string,
	secret: bool,
}

// A WebAuthn credential as a password manager stores it -- the fields
// Bitwarden's Fido2Credential carries, so its exports round-trip. Nothing here
// performs a WebAuthn ceremony yet: Linux has no platform authenticator API,
// and the browser half is the browser's (cloud/docs/vault.md, "Passkeys").
Passkey :: struct {
	credential_id: string, // base64url, as the relying party sees it
	rp_id:         string,
	rp_name:       string,
	user_handle:   string, // base64url
	user_name:     string,
	key:           string, // the private key, PKCS#8 base64 (ES256) -- a secret
	counter:       u32,
	created:       i64,
	discoverable:  bool,
}

// Flags on an entry.
ENTRY_EXPOSED :: u32(1 << 0) // someone whose access was revoked could read it: rotate the password

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

	// PVB2
	id:          string, // a v4 UUID; the record's id on the server
	kind:        Item_Kind,
	favorite:    bool,
	flags:       u32,
	urls:        [dynamic]string, // more sites the same login works on
	fields:      [dynamic]Kv,
	passkey:     Passkey,

	// Runtime only, never encoded: which source the entry came from (0 is the
	// local file; cloud.odin numbers the rest).
	src:         int,
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
		id          = new_uuid(),
		urls        = make([dynamic]string),
		fields      = make([dynamic]Kv),
	}
}

passkey_free :: proc(pk: ^Passkey) {
	delete(pk.credential_id)
	delete(pk.rp_id)
	delete(pk.rp_name)
	delete(pk.user_handle)
	delete(pk.user_name)
	wipe_string(pk.key)
	pk^ = {}
}

passkey_clone :: proc(pk: Passkey) -> Passkey {
	return Passkey {
		credential_id = strings.clone(pk.credential_id),
		rp_id = strings.clone(pk.rp_id),
		rp_name = strings.clone(pk.rp_name),
		user_handle = strings.clone(pk.user_handle),
		user_name = strings.clone(pk.user_name),
		key = strings.clone(pk.key),
		counter = pk.counter,
		created = pk.created,
		discoverable = pk.discoverable,
	}
}

// entry_clone is a deep copy: every string is new, so the two can be freed
// (and wiped) independently. Sync keeps one as the merge base.
entry_clone :: proc(e: ^Entry) -> Entry {
	out := e^
	out.title = strings.clone(e.title)
	out.username = strings.clone(e.username)
	out.password = strings.clone(e.password)
	out.url = strings.clone(e.url)
	out.notes = strings.clone(e.notes)
	out.totp = strings.clone(e.totp)
	out.id = strings.clone(e.id)
	out.tags = make([dynamic]string, 0, len(e.tags))
	for t in e.tags {
		append(&out.tags, strings.clone(t))
	}
	out.history = make([dynamic]Hist, 0, len(e.history))
	for h in e.history {
		append(&out.history, Hist{h.when_, strings.clone(h.password)})
	}
	out.urls = make([dynamic]string, 0, len(e.urls))
	for u in e.urls {
		append(&out.urls, strings.clone(u))
	}
	out.fields = make([dynamic]Kv, 0, len(e.fields))
	for f in e.fields {
		append(&out.fields, Kv{strings.clone(f.label), strings.clone(f.value), f.secret})
	}
	out.passkey = passkey_clone(e.passkey)
	return out
}

// field_get finds a labelled value; "" when the entry has none.
field_get :: proc(e: ^Entry, label: string) -> string {
	for f in e.fields {
		if f.label == label {
			return f.value
		}
	}
	return ""
}

field_set :: proc(e: ^Entry, label, value: string, secret: bool) {
	for &f in e.fields {
		if f.label == label {
			if f.secret || secret {
				wipe_string(f.value)
			} else {
				delete(f.value)
			}
			f.value = strings.clone(value)
			f.secret = f.secret || secret
			return
		}
	}
	append(&e.fields, Kv{strings.clone(label), strings.clone(value), secret})
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
	delete(e.id)
	for u in e.urls {
		delete(u)
	}
	delete(e.urls)
	for f in e.fields {
		delete(f.label)
		// Wiped whether or not it is marked secret: a card's expiry is not a
		// password, but it is still nobody else's business.
		wipe_string(f.value)
	}
	delete(e.fields)
	passkey_free(&e.passkey)
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
		entry_write(&w, &e)
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
	magic := string(r_take(&r, 4))
	v2 := magic == BODY_MAGIC
	if !v2 && magic != BODY_MAGIC_V1 {
		return {}, "the vault body is not in a format this build knows"
	}
	count := r_u32(&r)
	if r.bad || count > MAX_ENTRIES {
		return {}, "the vault body declares an impossible number of entries"
	}

	v.entries = make([dynamic]Entry, 0, int(count))
	for _ in 0 ..< int(count) {
		e, good := entry_read(&r, v2)
		if !good {
			vault_free(&v)
			return {}, "the vault body is corrupt"
		}
		append(&v.entries, e)
	}
	return v, ""
}

// entry_write appends one entry's fields: the PVB1 layout first, unchanged,
// then the PVB2 additions.
entry_write :: proc(w: ^Wr, e: ^Entry) {
	w_str(w, e.title)
	w_str(w, e.username)
	w_str(w, e.password)
	w_str(w, e.url)
	w_str(w, e.notes)
	w_u32(w, u32(len(e.tags)))
	for t in e.tags {
		w_str(w, t)
	}
	w_str(w, e.totp)
	w_u8(w, e.totp_digits)
	w_u32(w, e.totp_period)
	w_u8(w, u8(e.totp_algo))
	w_i64(w, e.created)
	w_i64(w, e.modified)
	w_u32(w, u32(len(e.history)))
	for h in e.history {
		w_i64(w, h.when_)
		w_str(w, h.password)
	}

	w_str(w, e.id)
	w_u8(w, u8(e.kind))
	w_u8(w, e.favorite ? 1 : 0)
	w_u32(w, e.flags)
	w_u32(w, u32(len(e.urls)))
	for u in e.urls {
		w_str(w, u)
	}
	w_u32(w, u32(len(e.fields)))
	for f in e.fields {
		w_str(w, f.label)
		w_str(w, f.value)
		w_u8(w, f.secret ? 1 : 0)
	}
	pk := &e.passkey
	w_str(w, pk.credential_id)
	w_str(w, pk.rp_id)
	w_str(w, pk.rp_name)
	w_str(w, pk.user_handle)
	w_str(w, pk.user_name)
	w_str(w, pk.key)
	w_u32(w, pk.counter)
	w_i64(w, pk.created)
	w_u8(w, pk.discoverable ? 1 : 0)
}

// entry_read reads what entry_write wrote. `v2` says whether the PVB2 fields
// follow; a PVB1 entry gets a fresh id and is a Login. On any bounds failure
// the half-read entry is freed (and its secrets wiped) and `ok` is false.
entry_read :: proc(r: ^Rd, v2: bool) -> (e: Entry, ok: bool) {
	e.title = r_str(r)
	e.username = r_str(r)
	e.password = r_str(r)
	e.url = r_str(r)
	e.notes = r_str(r)
	nt := r_u32(r)
	if r.bad || nt > 256 {
		r.bad = true
	}
	e.tags = make([dynamic]string)
	if !r.bad {
		for _ in 0 ..< int(nt) {
			append(&e.tags, r_str(r))
		}
	}
	e.totp = r_str(r)
	e.totp_digits = r_u8(r)
	e.totp_period = r_u32(r)
	alg := r_u8(r)
	e.totp_algo = alg <= u8(Totp_Algo.SHA512) ? Totp_Algo(alg) : .SHA1
	e.created = r_i64(r)
	e.modified = r_i64(r)
	nh := r_u32(r)
	if r.bad || nh > MAX_HISTORY {
		r.bad = true
	}
	e.history = make([dynamic]Hist)
	if !r.bad {
		for _ in 0 ..< int(nh) {
			h := Hist{}
			h.when_ = r_i64(r)
			h.password = r_str(r)
			append(&e.history, h)
		}
	}

	e.urls = make([dynamic]string)
	e.fields = make([dynamic]Kv)
	if v2 && !r.bad {
		e.id = r_str(r)
		k := r_u8(r)
		e.kind = k <= u8(Item_Kind.Totp) ? Item_Kind(k) : .Login
		e.favorite = r_u8(r) != 0
		e.flags = r_u32(r)
		nu := r_u32(r)
		if r.bad || nu > MAX_FIELDS {
			r.bad = true
		}
		if !r.bad {
			for _ in 0 ..< int(nu) {
				append(&e.urls, r_str(r))
			}
		}
		nf := r_u32(r)
		if r.bad || nf > MAX_FIELDS {
			r.bad = true
		}
		if !r.bad {
			for _ in 0 ..< int(nf) {
				f := Kv{}
				f.label = r_str(r)
				f.value = r_str(r)
				f.secret = r_u8(r) != 0
				append(&e.fields, f)
			}
		}
		pk := &e.passkey
		pk.credential_id = r_str(r)
		pk.rp_id = r_str(r)
		pk.rp_name = r_str(r)
		pk.user_handle = r_str(r)
		pk.user_name = r_str(r)
		pk.key = r_str(r)
		pk.counter = r_u32(r)
		pk.created = r_i64(r)
		pk.discoverable = r_u8(r) != 0
	} else {
		e.id = new_uuid()
	}
	if e.id == "" {
		delete(e.id)
		e.id = new_uuid()
	}

	if r.bad {
		entry_free(&e)
		return {}, false
	}
	if e.totp_digits != 6 && e.totp_digits != 8 {
		e.totp_digits = 6
	}
	if e.totp_period == 0 || e.totp_period > 3600 {
		e.totp_period = 30
	}
	return e, true
}

// ---------------------------------------------------------------------------
// One item as a record: what goes inside an item blob on the server
//
// The same entry encoding, behind its own magic, padded to RECORD_PAD so the
// ciphertext length says little more than "a login" versus "a login with a
// long note": the server sees sizes in 512-byte steps, never the length of a
// password or a URL.
// ---------------------------------------------------------------------------

RECORD_MAGIC :: "PVI1"
RECORD_PAD :: 512

record_encode :: proc(e: ^Entry, allocator := context.allocator) -> []byte {
	w := Wr {
		b = make([dynamic]u8, context.temp_allocator),
	}
	append(&w.b, ..transmute([]u8)string(RECORD_MAGIC))
	entry_write(&w, e)
	payload := w.b[:]
	total := round_up(4 + len(payload), RECORD_PAD)
	out := make([]byte, total, allocator)
	put_u32le(out[0:4], u32(len(payload)))
	copy(out[4:], payload)
	crypto.zero_explicit(raw_data(payload), len(payload))
	return out
}

record_decode :: proc(plain: []byte) -> (e: Entry, ok: bool) {
	if len(plain) < 8 {
		return {}, false
	}
	n := get_u32le(plain[0:4])
	if int(n) + 4 > len(plain) {
		return {}, false
	}
	r := Rd {
		b = plain[4:4 + int(n)],
	}
	if string(r_take(&r, 4)) != RECORD_MAGIC {
		return {}, false
	}
	e, ok = entry_read(&r, true)
	if ok && r.at != len(r.b) {
		entry_free(&e)
		return {}, false
	}
	return
}

// ---------------------------------------------------------------------------
// A vault's own metadata: its name, colour and icon, sealed under its key.
// ---------------------------------------------------------------------------

Vault_Meta :: struct {
	name:  string,
	color: string,
	icon:  string,
}

meta_encode :: proc(m: Vault_Meta, allocator := context.allocator) -> []byte {
	w := Wr {
		b = make([dynamic]u8, context.temp_allocator),
	}
	append(&w.b, ..transmute([]u8)string("PVM1"))
	w_str(&w, m.name)
	w_str(&w, m.color)
	w_str(&w, m.icon)
	total := round_up(len(w.b), 64)
	out := make([]byte, total, allocator)
	copy(out, w.b[:])
	return out
}

meta_decode :: proc(plain: []byte) -> (m: Vault_Meta, ok: bool) {
	r := Rd {
		b = plain,
	}
	if string(r_take(&r, 4)) != "PVM1" {
		return {}, false
	}
	m.name = r_str(&r)
	m.color = r_str(&r)
	m.icon = r_str(&r)
	if r.bad {
		delete(m.name)
		delete(m.color)
		delete(m.icon)
		return {}, false
	}
	return m, true
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
