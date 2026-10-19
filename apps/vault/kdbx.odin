package main

// KeePass KDBX 4 databases (KeePass 2.35+, KeePassXC 2.7+), read only.
//
// The format, as KeePassXC writes and reads it (src/format/Kdbx4Reader.cpp):
//
//   sig1 0x9AA2D903 ‖ sig2 0xB54BFB67 ‖ version (major 4)
//   header fields: id u8 ‖ length u32 ‖ data, until id 0
//     2 cipher UUID · 3 compression · 4 master seed · 7 IV · 11 KDF parameters
//   SHA-256(header) ‖ HMAC-SHA256(header)
//   HMAC block stream: per block, HMAC ‖ length ‖ data; a zero length ends it
//   → decrypt (AES-256-CBC or ChaCha20) → gunzip → inner header → XML
//
//   composite key  = SHA-256(SHA-256(password))
//   transformed    = KDF(composite)        AES-KDF, Argon2d or Argon2id
//   cipher key     = SHA-256(seed ‖ transformed)
//   HMAC key       = SHA-512(seed ‖ transformed ‖ 0x01)
//   block key (i)  = SHA-512(LE64(i) ‖ HMAC key); the header uses i = 2^64 - 1
//
// The header HMAC is checked before anything is decrypted, which is how a
// wrong password is told apart from a corrupt file: KeePass made the same
// choice the local vault did, every byte authenticated before it is trusted.
//
// Values marked Protected="True" are XORed with a ChaCha20 keystream from the
// inner header, in document order, history included.
//
// Not supported: KDBX 3.1 (KeePass before 2.35; open and re-save it in
// KeePassXC first), key files and hardware keys, Twofish. Each is refused
// with a sentence saying so.

import "core:bytes"
import "core:compress/gzip"
import "core:crypto/aes"
import "core:crypto/chacha20"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/base64"
import "core:encoding/xml"
import "core:strings"
import a2 "argon2"

KDBX_SIG1 :: u32(0x9AA2D903)
KDBX_SIG2 :: u32(0xB54BFB67)

CIPHER_AES256 :: "31c1f2e6bf714350be5805216afc5aff"
CIPHER_CHACHA20 :: "d6038a2b8b6f4cb5a524339a31dbb59a"
KDBX_KDF_AES :: "c9d9f39a628a4460bf740d08c18a4fea"
KDBX_KDF_ARGON2D :: "ef636ddf8c29444b91f7a9a403e30a0c"
KDBX_KDF_ARGON2ID :: "9e298b1956db4773b23dfc3ec6f0a1e6"

Kdbx_Kdf :: struct {
	uuid:   string, // hex
	salt:   []byte, // S (Argon2) / seed (AES)
	rounds: u64, // R (AES)
	memory: u64, // M, bytes
	iters:  u64, // I
	par:    u32, // P
	ver:    u32, // V
}

@(private = "file")
get_u64le_at :: proc(b: []byte) -> u64 {
	return get_u64le(b)
}

// variant_dict reads KeePass's VariantDictionary (KDF parameters).
@(private = "file")
variant_dict :: proc(b: []byte) -> (k: Kdbx_Kdf, ok: bool) {
	if len(b) < 2 || get_u16le(b) & 0xff00 != 0x0100 {
		return {}, false
	}
	at := 2
	for at < len(b) {
		t := b[at]
		at += 1
		if t == 0 {
			return k, true
		}
		if at + 4 > len(b) {
			return {}, false
		}
		nl := int(get_u32le(b[at:]))
		at += 4
		if nl < 0 || at + nl + 4 > len(b) {
			return {}, false
		}
		name := string(b[at:at + nl])
		at += nl
		vl := int(get_u32le(b[at:]))
		at += 4
		if vl < 0 || at + vl > len(b) {
			return {}, false
		}
		v := b[at:at + vl]
		at += vl
		switch name {
		case "$UUID":
			k.uuid = hex_lower(v, context.temp_allocator)
		case "S":
			k.salt = v
		case "R":
			if len(v) == 8 {
				k.rounds = get_u64le_at(v)
			}
		case "M":
			if len(v) == 8 {
				k.memory = get_u64le_at(v)
			}
		case "I":
			if len(v) == 8 {
				k.iters = get_u64le_at(v)
			}
		case "P":
			if len(v) == 4 {
				k.par = get_u32le(v)
			}
		case "V":
			if len(v) == 4 {
				k.ver = get_u32le(v)
			}
		case "K", "A":
			if vl > 0 {
				return {}, false // a secret key or associated data: not produced by KeePass(XC) itself
			}
		}
	}
	return {}, false
}

@(private = "file")
sha256 :: proc(parts: ..[]byte) -> (out: [32]byte) {
	ctx: hash.Context
	hash.init(&ctx, .SHA256)
	for p in parts {
		hash.update(&ctx, p)
	}
	hash.final(&ctx, out[:])
	return
}

@(private = "file")
sha512 :: proc(parts: ..[]byte) -> (out: [64]byte) {
	ctx: hash.Context
	hash.init(&ctx, .SHA512)
	for p in parts {
		hash.update(&ctx, p)
	}
	hash.final(&ctx, out[:])
	return
}

@(private = "file")
le64 :: proc(v: u64) -> (b: [8]byte) {
	put_u64le(b[:], v)
	return
}

kdbx_transform :: proc(k: Kdbx_Kdf, composite: []byte) -> (out: [32]byte, err: string) {
	switch k.uuid {
	case KDBX_KDF_AES:
		if len(k.salt) != 32 || k.rounds == 0 || k.rounds > 1 << 32 {
			return {}, "the database's AES-KDF parameters are out of range"
		}
		ctx: aes.Context_ECB
		aes.init_ecb(&ctx, k.salt)
		buf: [32]byte
		copy(buf[:], composite)
		for _ in 0 ..< k.rounds {
			aes.encrypt_ecb(&ctx, buf[0:16], buf[0:16])
			aes.encrypt_ecb(&ctx, buf[16:32], buf[16:32])
		}
		aes.reset_ecb(&ctx)
		out = sha256(buf[:])
		zero_bytes(buf[:])
		return
	case KDBX_KDF_ARGON2D, KDBX_KDF_ARGON2ID:
		mem_kib := k.memory / 1024
		if len(k.salt) < 8 || k.iters < 1 || k.iters > 64 || k.par < 1 || k.par > 64 ||
		   mem_kib < u64(8 * k.par) || mem_kib > u64(KDF_MAX_M) || (k.ver != 0x13 && k.ver != 0x10) {
			return {}, "the database's Argon2 parameters are out of range"
		}
		if k.ver != 0x13 {
			return {}, "the database uses Argon2 version 1.0, which this build does not implement"
		}
		ps := a2.Parameters {
			memory_size = u32(mem_kib),
			passes      = u32(k.iters),
			parallelism = k.par,
			argon2d     = k.uuid == KDBX_KDF_ARGON2D,
		}
		if e := a2.derive(&ps, composite, k.salt, out[:]); e != nil {
			return {}, "not enough memory for the database's key derivation"
		}
		return
	}
	return {}, "the database uses a key derivation this build does not know"
}

import_kdbx :: proc(r: ^Import_Result, data: []byte, password: string) {
	if len(data) < 12 || get_u32le(data) != KDBX_SIG1 || get_u32le(data[4:]) != KDBX_SIG2 {
		r.err = "this is not a KeePass database"
		return
	}
	major := get_u16le(data[10:])
	if major != 4 {
		r.err = "this is a KDBX 3 database: open it in KeePassXC and save it once to upgrade it to KDBX 4, then import that"
		return
	}
	at := 12
	cipher, iv, seed: []byte
	compressed := false
	kdf: Kdbx_Kdf
	have_kdf := false
	for {
		if at + 5 > len(data) {
			r.err = "the database header is truncated"
			return
		}
		id := data[at]
		n := int(get_u32le(data[at + 1:]))
		at += 5
		if n < 0 || at + n > len(data) {
			r.err = "the database header is corrupt"
			return
		}
		v := data[at:at + n]
		at += n
		if id == 0 {
			break
		}
		switch id {
		case 2:
			cipher = v
		case 3:
			compressed = len(v) == 4 && get_u32le(v) == 1
		case 4:
			seed = v
		case 7:
			iv = v
		case 11:
			kdf, have_kdf = variant_dict(v)
		}
	}
	header := data[:at]
	if at + 64 > len(data) || len(seed) != 32 || !have_kdf {
		r.err = "the database header is incomplete"
		return
	}
	want_sha := sha256(header)
	if string(want_sha[:]) != string(data[at:at + 32]) {
		r.err = "the database header is corrupt (its checksum does not match)"
		return
	}
	stored_hmac := data[at + 32:at + 64]
	at += 64

	pw_hash := sha256(transmute([]byte)password)
	composite := sha256(pw_hash[:])
	transformed, terr := kdbx_transform(kdf, composite[:])
	if terr != "" {
		r.err = terr
		return
	}
	defer zero_bytes(transformed[:])
	cipher_key := sha256(seed, transformed[:])
	defer zero_bytes(cipher_key[:])
	one := [1]byte{1}
	hmac_key := sha512(seed, transformed[:], one[:])
	defer zero_bytes(hmac_key[:])

	block_key :: proc(hmac_key: []byte, i: u64) -> [64]byte {
		b := le64(i)
		return sha512(b[:], hmac_key)
	}
	hk := block_key(hmac_key[:], max(u64))
	got: [32]byte
	hmac.sum(.SHA256, got[:], header, hk[:])
	if string(got[:]) != string(stored_hmac) {
		r.err = "the KeePass database did not open: the password is wrong (key files are not supported)"
		return
	}

	// The HMAC block stream.
	payload := make([dynamic]byte, context.temp_allocator)
	idx: u64 = 0
	for {
		if at + 36 > len(data) {
			r.err = "the database is truncated"
			return
		}
		mac := data[at:at + 32]
		size := int(get_u32le(data[at + 32:]))
		if size < 0 || at + 36 + size > len(data) {
			r.err = "the database is corrupt"
			return
		}
		blk := data[at + 36:at + 36 + size]
		bk := block_key(hmac_key[:], idx)
		ix := le64(idx)
		ctx: hmac.Context
		hmac.init(&ctx, .SHA256, bk[:])
		hmac.update(&ctx, ix[:])
		hmac.update(&ctx, data[at + 32:at + 36])
		hmac.update(&ctx, blk)
		hmac.final(&ctx, got[:])
		if string(got[:]) != string(mac) {
			r.err = "the database is corrupt: a block failed its authentication"
			return
		}
		at += 36 + size
		if size == 0 {
			break
		}
		append(&payload, ..blk)
		idx += 1
	}

	// Decrypt.
	plain := make([]byte, len(payload), context.temp_allocator)
	defer zero_bytes(plain)
	switch hex_lower(cipher, context.temp_allocator) {
	case CIPHER_AES256:
		if len(iv) != 16 || len(payload) % 16 != 0 || len(payload) == 0 {
			r.err = "the database's AES payload is malformed"
			return
		}
		ctx: aes.Context_ECB
		aes.init_ecb(&ctx, cipher_key[:])
		prev := iv
		for i := 0; i < len(payload); i += 16 {
			aes.decrypt_ecb(&ctx, plain[i:i + 16], payload[i:i + 16])
			for j in 0 ..< 16 {
				plain[i + j] ~= prev[j]
			}
			prev = payload[i:i + 16]
		}
		aes.reset_ecb(&ctx)
		pad := int(plain[len(plain) - 1])
		if pad < 1 || pad > 16 {
			r.err = "the database's padding is wrong"
			return
		}
		plain = plain[:len(plain) - pad]
	case CIPHER_CHACHA20:
		if len(iv) != 12 {
			r.err = "the database's ChaCha20 nonce is malformed"
			return
		}
		ctx: chacha20.Context
		chacha20.init(&ctx, cipher_key[:], iv)
		chacha20.xor_bytes(&ctx, plain, payload[:])
		chacha20.reset(&ctx)
	case:
		r.err = "the database uses a cipher this build does not have (Twofish?)"
		return
	}

	inner := plain
	if compressed {
		buf: bytes.Buffer
		if e := gzip.load_from_bytes(plain, &buf); e != nil {
			bytes.buffer_destroy(&buf)
			r.err = "the database's compressed payload is corrupt"
			return
		}
		inner = make([]byte, len(buf.buf), context.temp_allocator)
		copy(inner, buf.buf[:])
		zero_bytes(buf.buf[:])
		bytes.buffer_destroy(&buf)
	}
	defer if compressed {
		zero_bytes(inner)
	}

	// Inner header.
	p := 0
	stream_id: u32 = 0
	stream_key: []byte
	for {
		if p + 5 > len(inner) {
			r.err = "the database's inner header is truncated"
			return
		}
		id := inner[p]
		n := int(get_u32le(inner[p + 1:]))
		p += 5
		if n < 0 || p + n > len(inner) {
			r.err = "the database's inner header is corrupt"
			return
		}
		v := inner[p:p + n]
		p += n
		if id == 0 {
			break
		}
		switch id {
		case 1:
			if len(v) == 4 {
				stream_id = get_u32le(v)
			}
		case 2:
			stream_key = v
		}
	}
	if stream_id != 3 {
		r.err = "the database protects its values with a stream cipher this build does not have (only ChaCha20, KDBX 4's default)"
		return
	}
	sk := sha512(stream_key)
	defer zero_bytes(sk[:])
	stream: chacha20.Context
	chacha20.init(&stream, sk[0:32], sk[32:44])
	defer chacha20.reset(&stream)

	kdbx_xml(r, string(inner[p:]), &stream)
}

@(private = "file")
Kdbx_Walk :: struct {
	doc:    ^xml.Document,
	values: map[xml.Element_ID]string, // protected values, decrypted
	bin:    string, // the recycle bin group's UUID (base64)
}

@(private = "file")
text_of :: proc(w: ^Kdbx_Walk, id: xml.Element_ID) -> string {
	if v, ok := w.values[id]; ok {
		return v
	}
	el := &w.doc.elements[id]
	for v in el.value {
		if s, is := v.(string); is {
			return s
		}
	}
	return ""
}

@(private = "file")
child :: proc(w: ^Kdbx_Walk, id: xml.Element_ID, name: string) -> (xml.Element_ID, bool) {
	for v in w.doc.elements[id].value {
		if c, is := v.(xml.Element_ID); is && w.doc.elements[c].ident == name {
			return c, true
		}
	}
	return 0, false
}

@(private = "file")
children :: proc(w: ^Kdbx_Walk, id: xml.Element_ID, name: string) -> []xml.Element_ID {
	out := make([dynamic]xml.Element_ID, context.temp_allocator)
	for v in w.doc.elements[id].value {
		if c, is := v.(xml.Element_ID); is && w.doc.elements[c].ident == name {
			append(&out, c)
		}
	}
	return out[:]
}

kdbx_xml :: proc(r: ^Import_Result, text: string, stream: ^chacha20.Context) {
	opts := xml.Options {
		flags = {.Ignore_Unsupported, .Unbox_CDATA, .Decode_SGML_Entities},
	}
	doc, err := xml.parse_string(text, opts, allocator = context.temp_allocator)
	if err != .None {
		r.err = "the database's XML is malformed"
		return
	}
	w := Kdbx_Walk {
		doc    = doc,
		values = make(map[xml.Element_ID]string, context.temp_allocator),
	}
	// Protected values, in document order: the keystream is one long run
	// across the whole file, so every one must be consumed in turn, kept or not.
	for i in 0 ..< int(doc.element_count) {
		el := &doc.elements[i]
		if el.ident != "Value" {
			continue
		}
		protected := false
		for at in el.attribs {
			if at.key == "Protected" && strings.equal_fold(at.val, "true") {
				protected = true
			}
		}
		if !protected {
			continue
		}
		raw := ""
		for v in el.value {
			if s, is := v.(string); is {
				raw = s
			}
		}
		dec, derr := base64.decode(strings.trim_space(raw), allocator = context.temp_allocator)
		if derr != nil {
			r.err = "a protected value in the database is not base64"
			return
		}
		chacha20.xor_bytes(stream, dec, dec)
		w.values[xml.Element_ID(i)] = string(dec)
	}

	root, rok := child(&w, 0, "Root")
	if !rok {
		// Element 0 may be the document's top element itself.
		r.err = "the database has no Root"
		return
	}
	if meta, ok := child(&w, 0, "Meta"); ok {
		if rb, ok2 := child(&w, meta, "RecycleBinUUID"); ok2 {
			w.bin = text_of(&w, rb)
		}
	}
	for g in children(&w, root, "Group") {
		kdbx_group(r, &w, g, "", true)
	}
}

@(private = "file")
kdbx_group :: proc(r: ^Import_Result, w: ^Kdbx_Walk, g: xml.Element_ID, path: string, top: bool) {
	name := ""
	if n, ok := child(w, g, "Name"); ok {
		name = text_of(w, n)
	}
	if u, ok := child(w, g, "UUID"); ok && w.bin != "" && text_of(w, u) == w.bin {
		for _ in children(w, g, "Entry") {
			r.skipped += 1
		}
		return // the recycle bin
	}
	// The top group is the database itself; its name is not a tag.
	here := top ? "" : (path == "" ? name : strings.concatenate({path, "/", name}, context.temp_allocator))
	for e in children(w, g, "Entry") {
		kdbx_entry(r, w, e, here)
	}
	for sub in children(w, g, "Group") {
		kdbx_group(r, w, sub, here, false)
	}
}

@(private = "file")
kdbx_strings :: proc(w: ^Kdbx_Walk, e: xml.Element_ID) -> (keys, vals: [dynamic]string, prot: [dynamic]bool) {
	keys = make([dynamic]string, context.temp_allocator)
	vals = make([dynamic]string, context.temp_allocator)
	prot = make([dynamic]bool, context.temp_allocator)
	for s in children(w, e, "String") {
		k, kok := child(w, s, "Key")
		v, vok := child(w, s, "Value")
		if !kok || !vok {
			continue
		}
		append(&keys, text_of(w, k))
		append(&vals, text_of(w, v))
		_, is_prot := w.values[v]
		append(&prot, is_prot)
	}
	return
}

@(private = "file")
kdbx_entry :: proc(r: ^Import_Result, w: ^Kdbx_Walk, el: xml.Element_ID, tag: string) {
	keys, vals, prot := kdbx_strings(w, el)
	title := ""
	for k, i in keys {
		if k == "Title" {
			title = vals[i]
		}
	}
	if title == "" {
		title = "Untitled"
	}
	e := entry_new(title)
	for k, i in keys {
		v := vals[i]
		switch k {
		case "Title":
		case "UserName":
			replace_string(&e.username, v)
		case "Password":
			replace_secret(&e.password, v)
		case "URL":
			replace_string(&e.url, v)
		case "Notes":
			replace_secret(&e.notes, v)
		case "otp", "TOTP Seed":
			if !set_totp_from(&e, v) {
				warn(r, "%s: the one-time password setting was not understood", title)
			}
		case "TOTP Settings":
			// KeePass 2's "30;6" form, only meaningful with "TOTP Seed".
			parts := strings.split(v, ";", context.temp_allocator)
			if len(parts) >= 2 {
				if n := parse_int(parts[0]); n > 0 && n <= 3600 {
					e.totp_period = u32(n)
				}
				if n := parse_int(parts[1]); n == 6 || n == 8 {
					e.totp_digits = u8(n)
				}
			}
		case:
			if strings.has_prefix(k, "KPH: ") || strings.has_prefix(k, "KPEX_") {
				continue // browser-integration bookkeeping, not data
			}
			if v != "" {
				field_set(&e, k, v, prot[i])
			}
		}
	}
	tags := tag
	if t, ok := child(w, el, "Tags"); ok {
		extra, _ := strings.replace_all(text_of(w, t), ";", ",", context.temp_allocator)
		if extra != "" {
			tags = tags == "" ? extra : strings.concatenate({tags, ",", extra}, context.temp_allocator)
		}
	}
	entry_set_tags(&e, tags)
	if times, ok := child(w, el, "Times"); ok {
		if c, ok2 := child(w, times, "CreationTime"); ok2 {
			if t := kdbx_time(text_of(w, c)); t > 0 {
				e.created = t
			}
		}
		if m, ok2 := child(w, times, "LastModificationTime"); ok2 {
			if t := kdbx_time(text_of(w, m)); t > 0 {
				e.modified = t
			}
		}
	}
	if hist, ok := child(w, el, "History"); ok {
		for old in children(w, hist, "Entry") {
			hk, hv, _ := kdbx_strings(w, old)
			when_: i64 = 0
			if times, tok := child(w, old, "Times"); tok {
				if m, mok := child(w, times, "LastModificationTime"); mok {
					when_ = kdbx_time(text_of(w, m))
				}
			}
			for k, i in hk {
				if k == "Password" && hv[i] != "" && hv[i] != e.password && len(e.history) < MAX_HISTORY && !has_hist(e.history[:], Hist{when_, hv[i]}) {
					append(&e.history, Hist{when_, strings.clone(hv[i])})
				}
			}
		}
	}
	if e.password == "" && e.username == "" && e.url == "" {
		e.kind = e.totp != "" ? .Totp : .Note
	}
	append(&r.entries, e)
}

// kdbx_time reads KDBX 4's times: base64 of a little-endian i64 of seconds
// since 0001-01-01 (or an ISO string, which KDBX 3 used).
kdbx_time :: proc(s: string) -> i64 {
	if strings.contains(s, "-") {
		return iso_unix(s)
	}
	b, err := base64.decode(s, allocator = context.temp_allocator)
	if err != nil || len(b) != 8 {
		return 0
	}
	secs := i64(get_u64le(b))
	EPOCH_FROM_0001 :: i64(62135596800)
	return secs - EPOCH_FROM_0001
}
