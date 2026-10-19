package main

// The self-test for everything the synced vault added: the new primitives
// against their published vectors, the key hierarchy, records, sharing and
// rotation, merging, the importers against fixtures made by other programs,
// password health, origin matching and the autofill protocol.
//
// None of it touches the network. The account is exercised offline -- two
// Acct values over one cache directory are two devices -- and the live
// server is apps/vault/e2e.sh's job. The breach check gets a fixture fetcher
// that records what it was asked for, so the test can assert that only
// five-hex-digit prefixes would have left the machine.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ed25519"
import "core:crypto/hkdf"
import "core:crypto/x25519"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/linux"
import a2 "argon2"

@(private = "file")
FAST :: Kdf {
	m   = 64,
	t   = 1,
	par = 1,
}

@(private = "file")
unhex :: proc(s: string, allocator := context.temp_allocator) -> []byte {
	out := make([]byte, len(s) / 2, allocator)
	nib :: proc(c: u8) -> u8 {
		switch c {
		case '0' ..= '9':
			return c - '0'
		case 'a' ..= 'f':
			return c - 'a' + 10
		case 'A' ..= 'F':
			return c - 'A' + 10
		}
		return 0
	}
	for i in 0 ..< len(out) {
		out[i] = nib(s[2 * i]) << 4 | nib(s[2 * i + 1])
	}
	return out
}

@(private = "file")
perm_bits :: proc(path: string) -> u32 {
	st: linux.Stat
	if linux.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .NONE {
		return 0o777
	}
	return transmute(u32)st.mode & 0o777
}

@(private = "file")
hx :: proc(b: []byte) -> string {
	return hex_lower(b, context.temp_allocator)
}

t_sync_all :: proc() {
	t_new_vectors()
	t_wraps()
	t_seals()
	t_secret_key()
	t_records()
	t_account_offline()
	t_share_offline()
	t_merge()
	t_imports()
	t_health()
	t_origins()
	t_autofill()
	t_data_dir()
}

// ---------------------------------------------------------------------------
// Published vectors for the primitives the synced vault added
// ---------------------------------------------------------------------------

@(private = "file")
t_new_vectors :: proc() {
	begin_section("X25519, HKDF, Ed25519, XChaCha20-Poly1305 and Argon2d against their published vectors")

	// RFC 7748 section 6.1.
	a_priv := unhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
	b_priv := unhex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
	a_pub, b_pub, s1, s2: [32]byte
	x25519.scalarmult_basepoint(a_pub[:], a_priv)
	x25519.scalarmult_basepoint(b_pub[:], b_priv)
	check(hx(a_pub[:]) == "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a", "RFC 7748: Alice's public key is %s", hx(a_pub[:]))
	check(hx(b_pub[:]) == "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f", "RFC 7748: Bob's public key is %s", hx(b_pub[:]))
	x25519.scalarmult(s1[:], a_priv, b_pub[:])
	x25519.scalarmult(s2[:], b_priv, a_pub[:])
	check(hx(s1[:]) == "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742", "RFC 7748: the shared secret is %s", hx(s1[:]))
	check(s1 == s2, "RFC 7748: the two sides disagree")

	// RFC 5869 appendix A.1.
	ikm: [22]byte
	for &b in ikm {
		b = 0x0b
	}
	okm: [42]byte
	hkdf.extract_and_expand(.SHA256, unhex("000102030405060708090a0b0c"), ikm[:], unhex("f0f1f2f3f4f5f6f7f8f9"), okm[:])
	check(hx(okm[:]) == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865", "RFC 5869 A.1: OKM is %s", hx(okm[:]))

	// RFC 8032 section 7.1, TEST 1 (the empty message).
	sk: ed25519.Private_Key
	check(ed25519.private_key_set_bytes(&sk, unhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")), "RFC 8032: the seed was refused")
	pk: [32]byte
	ed25519.private_key_public_bytes(&sk, pk[:])
	check(hx(pk[:]) == "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "RFC 8032: the public key is %s", hx(pk[:]))
	sig: [64]byte
	ed25519.sign(&sk, nil, sig[:])
	check(hx(sig[:]) == "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b", "RFC 8032: the signature is %s", hx(sig[:]))
	check(verify_bytes(pk[:], nil, sig[:]), "RFC 8032: the published signature does not verify")
	sig[0] ~= 1
	check(!verify_bytes(pk[:], nil, sig[:]), "a flipped signature verified")

	// draft-irtf-cfrg-xchacha-03 appendix A.3.1.
	key := unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	iv := unhex("404142434445464748494a4b4c4d4e4f5051525354555657")
	aad := unhex("50515253c0c1c2c3c4c5c6c7")
	pt := transmute([]byte)string(RFC8439_PLAIN)
	ct := make([]byte, len(pt), context.temp_allocator)
	tag: [16]byte
	aead.seal(.XCHACHA20POLY1305, ct, tag[:], key, iv, aad, pt)
	check(hx(ct) == "bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e", "XChaCha20-Poly1305 A.3.1: the ciphertext differs: %s", hx(ct))
	check(hx(tag[:]) == "c0875924c1c7987947deafd8780acf49", "XChaCha20-Poly1305 A.3.1: the tag is %s", hx(tag[:]))

	// RFC 9106 section 5.1 (Argon2d): the same inputs as 5.3's Argon2id.
	pw: [32]byte
	salt: [16]byte
	secret: [8]byte
	ad: [12]byte
	for &b in pw {
		b = 1
	}
	for &b in salt {
		b = 2
	}
	for &b in secret {
		b = 3
	}
	for &b in ad {
		b = 4
	}
	out: [32]byte
	ps := a2.Parameters{memory_size = 32, passes = 3, parallelism = 4, argon2d = true}
	_ = a2.derive(&ps, pw[:], salt[:], out[:], secret[:], ad[:])
	check(hx(out[:]) == "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb", "RFC 9106 5.1 (Argon2d): the tag is %s", hx(out[:]))
	ps.argon2d = false
	_ = a2.derive(&ps, pw[:], salt[:], out[:], secret[:], ad[:])
	check(out == RFC9106_TAG, "the vendored Argon2 no longer matches RFC 9106 5.3 with argon2d off")
}

// ---------------------------------------------------------------------------
// Symmetric wraps
// ---------------------------------------------------------------------------

@(private = "file")
t_wraps :: proc() {
	begin_section("symmetric wraps: XChaCha20-Poly1305, key ids, bound contexts")
	key, other: [KEY_LEN]byte
	crypto.rand_bytes(key[:])
	crypto.rand_bytes(other[:])
	msg := transmute([]byte)string("an item key, or an item")
	w := wrap(key[:], msg, "ctx/a", context.temp_allocator)
	check(len(w) == 1 + KEYID_LEN + XNONCE_LEN + len(msg) + TAG_LEN, "a wrap is %d bytes", len(w))
	p, good := unwrap(key[:], w, "ctx/a", context.temp_allocator)
	check(good && string(p) == string(msg), "a wrap did not round-trip")
	_, g2 := unwrap(key[:], w, "ctx/b", context.temp_allocator)
	check(!g2, "a wrap opened under another context: a key copied between rows would decrypt")
	_, g3 := unwrap(other[:], w, "ctx/a", context.temp_allocator)
	check(!g3, "a wrap opened under another key")
	kid, kok := wrap_key_id(w)
	want := key_id(key[:])
	check(kok && kid == want, "the key id on the wrap is not the key's")
	flips := 0
	for i in 0 ..< len(w) {
		t := make([]byte, len(w), context.temp_allocator)
		copy(t, w)
		t[i] ~= 0x01
		if _, opened := unwrap(key[:], t, "ctx/a", context.temp_allocator); opened {
			flips += 1
		}
	}
	check(flips == 0, "%d single-byte flips of a wrap were accepted", flips)
	w2 := wrap(key[:], msg, "ctx/a", context.temp_allocator)
	check(string(w[1 + KEYID_LEN:][:XNONCE_LEN]) != string(w2[1 + KEYID_LEN:][:XNONCE_LEN]), "two wraps reused a nonce")
}

// ---------------------------------------------------------------------------
// Sealing to an identity (X25519 + ML-KEM-768), and to a device
// ---------------------------------------------------------------------------

@(private = "file")
t_seals :: proc() {
	begin_section("hybrid sealed boxes (X25519 + ML-KEM-768) and signed shares")
	alice := identity_keys_generate()
	bob := identity_keys_generate()
	defer identity_keys_clear(&alice)
	defer identity_keys_clear(&bob)

	reload: Identity_Keys
	check(identity_keys_load(&reload, alice.priv[:]), "an identity's private half did not load back")
	check(reload.pub == alice.pub, "reloading the private half produced different public keys")
	identity_keys_clear(&reload)

	vkey: [32]byte
	crypto.rand_bytes(vkey[:])
	s, sok := seal_to(&bob.pub, vkey[:], "vault-key|v|1|bob", context.temp_allocator)
	check(sok && len(s) == SEAL_OVERHEAD + 32, "seal_to failed or is %d bytes", len(s))
	got, gok := open_sealed(&bob, s, "vault-key|v|1|bob", context.temp_allocator)
	check(gok && string(got) == string(vkey[:]), "bob could not open a key sealed to him")
	_, wrong := open_sealed(&alice, s, "vault-key|v|1|bob", context.temp_allocator)
	check(!wrong, "alice opened a key sealed to bob")
	_, ctx := open_sealed(&bob, s, "vault-key|v|1|alice", context.temp_allocator)
	check(!ctx, "a sealed key opened under another grantee's context")
	accepted := 0
	for i := 0; i < len(s); i += 7 {
		t := make([]byte, len(s), context.temp_allocator)
		copy(t, s)
		t[i] ~= 0x80
		if _, opened := open_sealed(&bob, t, "vault-key|v|1|bob", context.temp_allocator); opened {
			accepted += 1
		}
	}
	check(accepted == 0, "%d tampered sealed boxes opened", accepted)

	// The ML-KEM half matters: with the X25519 half alone an attacker who
	// recorded the box cannot rebuild the key. Check the KEM ciphertext is
	// really bound: a box whose KEM ciphertext comes from another seal fails.
	s2, _ := seal_to(&bob.pub, vkey[:], "vault-key|v|1|bob", context.temp_allocator)
	franken := make([]byte, len(s), context.temp_allocator)
	copy(franken, s)
	copy(franken[33:33 + KEM_CT_LEN], s2[33:33 + KEM_CT_LEN])
	_, fk := open_sealed(&bob, franken, "vault-key|v|1|bob", context.temp_allocator)
	check(!fk, "a box with another box's ML-KEM ciphertext opened: the KEM half is not bound")

	// Device sealing (X25519 only).
	dpriv: [32]byte
	crypto.rand_bytes(dpriv[:])
	dpub: [32]byte
	x25519_base(dpub[:], dpriv[:])
	sx, xok := seal_x_to(dpub[:], vkey[:16], "dev|1", context.temp_allocator)
	px, pok := open_x_sealed(dpriv[:], sx, "dev|1", context.temp_allocator)
	check(xok && pok && string(px) == string(vkey[:16]), "a device seal did not round-trip")
	_, xbad := open_x_sealed(dpriv[:], sx, "dev|2", context.temp_allocator)
	check(!xbad, "a device seal opened for another device id")
	check(device_code(dpub[:]) != "" && len(device_code(dpub[:])) == 7, "a device code is not ### ###")

	// Signed shares: every field of the row is covered.
	t := share_transcript("s1", "alice", "v1", "i1", "bob", "read", 1, s)
	sg := sign_bytes(&alice, t)
	check(verify_bytes(alice.pub.sign[:], t, sg[:]), "a share signature does not verify")
	for alt in ([?][2]string{{"role", "write"}, {"grantee", "eve"}, {"item", "i2"}}) {
		t2: []byte
		switch alt[0] {
		case "role":
			t2 = share_transcript("s1", "alice", "v1", "i1", "bob", alt[1], 1, s)
		case "grantee":
			t2 = share_transcript("s1", "alice", "v1", "i1", alt[1], "read", 1, s)
		case "item":
			t2 = share_transcript("s1", "alice", "v1", alt[1], "bob", "read", 1, s)
		}
		check(!verify_bytes(alice.pub.sign[:], t2, sg[:]), "a share signature still verified with its %s changed", alt[0])
	}
	t3 := share_transcript("s1", "alice", "v1", "i1", "bob", "read", 1, s2)
	check(!verify_bytes(alice.pub.sign[:], t3, sg[:]), "a share signature verified over a substituted wrapped key")
	check(!verify_bytes(bob.pub.sign[:], t, sg[:]), "a share signature verified under the wrong identity")
	check(fingerprint(&alice.pub) != fingerprint(&bob.pub) && len(fingerprint(&alice.pub)) == 23, "fingerprints are not 4 groups of 5 digits, or collide")
}

@(private = "file")
t_secret_key :: proc() {
	begin_section("the Secret Key and the account unlock key")
	sec: [SECRET_LEN]byte
	crypto.rand_bytes(sec[:])
	text := secret_format(sec[:], context.temp_allocator)
	check(strings.has_prefix(text, "PV1-") && len(text) == 34, "the Secret Key text is %q", text)
	back, ok1 := secret_parse(text)
	check(ok1 && back == sec, "the Secret Key did not parse back")
	lower, _ := strings.replace_all(strings.to_lower(text, context.temp_allocator), "-", " ", context.temp_allocator)
	back2, ok2 := secret_parse(lower)
	check(ok2 && back2 == sec, "a Secret Key typed in lower case with spaces was refused")
	_, bad := secret_parse("PV1-AAAAAA-AAAAAA")
	check(!bad, "a short Secret Key was accepted")
	_, bad2 := secret_parse("PV1-111111-AAAAAA-AAAAAA-AAAAAA-AA")
	check(!bad2, "a Secret Key with characters outside base32 was accepted")

	salt: [SALT_LEN]byte
	crypto.rand_bytes(salt[:])
	k1, k2, k3, k4: [KEY_LEN]byte
	derive_auk("pw-one", sec[:], salt[:], FAST, "acct", k1[:])
	derive_auk("pw-one", sec[:], salt[:], FAST, "acct", k2[:])
	check(k1 == k2, "the AUK is not deterministic")
	derive_auk("pw-two", sec[:], salt[:], FAST, "acct", k3[:])
	check(k1 != k3, "the AUK does not depend on the password")
	other := sec
	other[0] ~= 1
	derive_auk("pw-one", other[:], salt[:], FAST, "acct", k4[:])
	check(k1 != k4, "the AUK does not depend on the Secret Key")
	derive_auk("pw-one", sec[:], salt[:], FAST, "another-account", k4[:])
	check(k1 != k4, "the AUK does not depend on the account it belongs to")
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

@(private = "file")
rich_entry :: proc() -> Entry {
	e := entry_new("Example Card")
	e.kind = .Card
	e.favorite = true
	e.flags = ENTRY_EXPOSED
	replace_string(&e.username, "card-holder")
	replace_string(&e.url, "https://bank.example.org")
	append(&e.urls, strings.clone("https://cards.example.org"))
	field_set(&e, "Number", "4111111111111111", true)
	field_set(&e, "Expiry", "12/2030", false)
	e.passkey = Passkey {
		credential_id = strings.clone("cred-id"),
		rp_id = strings.clone("bank.example.org"),
		user_name = strings.clone("holder"),
		key = strings.clone("PKCS8-not-real"),
		counter = 3,
		discoverable = true,
	}
	entry_set_password(&e, "record-pass-1")
	entry_set_password(&e, "record-pass-2")
	return e
}

@(private = "file")
t_records :: proc() {
	begin_section("an item as a record: every field, padded")
	e := rich_entry()
	defer entry_free(&e)
	plain := record_encode(&e, context.temp_allocator)
	check(len(plain) % RECORD_PAD == 0, "a record is %d bytes, not a multiple of %d", len(plain), RECORD_PAD)
	back, good := record_decode(plain)
	check(good, "a record did not decode")
	defer entry_free(&back)
	check(back.id == e.id && back.kind == .Card && back.favorite && back.flags == ENTRY_EXPOSED, "the PVB2 header fields did not survive")
	check(len(back.urls) == 1 && back.urls[0] == "https://cards.example.org", "the extra URLs did not survive")
	check(field_get(&back, "Number") == "4111111111111111" && back.fields[0].secret, "a secret field did not survive")
	check(back.passkey.rp_id == "bank.example.org" && back.passkey.counter == 3 && back.passkey.discoverable && back.passkey.key == "PKCS8-not-real", "the passkey did not survive")
	check(len(back.history) == 1 && back.history[0].password == "record-pass-1", "the history did not survive")

	small := entry_new("a")
	defer entry_free(&small)
	big := entry_new("a much longer title that still fits")
	defer entry_free(&big)
	check(len(record_encode(&small, context.temp_allocator)) == len(record_encode(&big, context.temp_allocator)), "two short items have different record sizes: the length leaks the title")

	bad := make([]byte, len(plain), context.temp_allocator)
	copy(bad, plain)
	bad[4] = 'X'
	_, bgood := record_decode(bad)
	check(!bgood, "a record with the wrong magic decoded")
	cut := make([]byte, len(plain), context.temp_allocator)
	copy(cut, plain)
	put_u32le(cut[0:4], get_u32le(plain[0:4]) - 3)
	_, cgood := record_decode(cut)
	check(!cgood, "a record shorter than it says decoded")

	// A PVB1 body (the format before items had types) still opens.
	w := Wr{b = make([dynamic]u8, context.temp_allocator)}
	append(&w.b, ..transmute([]u8)string(BODY_MAGIC_V1))
	w_u32(&w, 1)
	w_str(&w, "Old Entry")
	w_str(&w, "olduser")
	w_str(&w, "old-pass")
	w_str(&w, "https://old.example")
	w_str(&w, "")
	w_u32(&w, 0)
	w_str(&w, "")
	w_u8(&w, 6)
	w_u32(&w, 30)
	w_u8(&w, 0)
	w_i64(&w, 1)
	w_i64(&w, 2)
	w_u32(&w, 0)
	body := make([]byte, round_up(4 + len(w.b), PAD_TO), context.temp_allocator)
	put_u32le(body[0:4], u32(len(w.b)))
	copy(body[4:], w.b[:])
	v1, err := body_decode(body)
	check(err == "" && len(v1.entries) == 1 && v1.entries[0].password == "old-pass" && v1.entries[0].kind == .Login && len(v1.entries[0].id) == 36,
		"a PVB1 body did not open as a v2 entry with a fresh id: %s", err)
	vault_free(&v1)
}

// ---------------------------------------------------------------------------
// The account, offline: two devices over one cache
// ---------------------------------------------------------------------------

@(private = "file")
offline_account :: proc(dir: string, password: string, who := "1") -> ^Acct {
	_ = os.remove_all(dir)
	a := acct_open(dir)
	cache_reset(a)
	a.have_cache = true
	a.cache.user_id = cs(a, "00000000-0000-4000-8000-0000000000aa")
	a.cache.email = cs(a, "fixture@example.test")
	append(&a.cache.idents, Ident{cs(a, fmt.tprintf("%s1111111-0000-4000-8000-000000000001", who)), cs(a, "fx"), cs(a, "Fixture"), cs(a, "personal"), cs(a, "indigo")})
	append(&a.cache.idents, Ident{cs(a, fmt.tprintf("%s1111111-0000-4000-8000-000000000002", who)), cs(a, "fx-work"), cs(a, "Fixture at work"), cs(a, "work"), cs(a, "emerald")})
	crypto.rand_bytes(a.secret[:])
	a.has_secret = true
	crypto.rand_bytes(a.account_key[:])
	salt: [SALT_LEN]byte
	crypto.rand_bytes(salt[:])
	auk: [KEY_LEN]byte
	derive_auk(password, a.secret[:], salt[:], FAST, a.cache.user_id, auk[:])
	a.unlocked = true
	for &id in a.cache.idents {
		row, _ := new_keyset_row(a, id.id, auk[:], salt[:], FAST)
		append(&a.cache.keysets, row)
		vrow, _ := new_vault_row(a, id.id, default_vault_name(&id), id.color)
		append(&a.cache.vaults, vrow)
	}
	device_save(a)
	cache_save(a)
	return a
}

// promote_pending is what a successful push does to the cache: the pending
// row becomes the server's row.
@(private = "file")
promote_pending :: proc(a: ^Acct) {
	for p in a.cache.pending {
		upsert_item(a, p.row)
	}
	clear(&a.cache.pending)
	cache_save(a)
}

@(private = "file")
t_account_offline :: proc() {
	begin_section("the account vault offline: keys, records, a second device")
	dir := fmt.tprintf("%s/acct-a", SCRATCH)
	a := offline_account(dir, "fixture master")
	defer acct_close(a)

	b := Book{mode = .Account, acct = a}
	b.v = Vault{entries = make([dynamic]Entry)}
	acct_entries(a, &b.v)
	check(len(a.sources) == 2, "two identities should give two vaults, got %d sources", len(a.sources))
	e := rich_entry()
	_, err := book_add(&b, e, 0)
	check(err == "", "adding to the personal vault failed: %s", err)
	e2 := entry_new("Work Login")
	replace_secret(&e2.password, "work-pass-1")
	_, err = book_add(&b, e2, 1)
	check(err == "" && len(a.cache.pending) == 2, "adding to the work vault failed or did not queue: %s", err)
	promote_pending(a)
	vault_free(&b.v)

	// The cache file: ciphertext, ids and counters, nothing else.
	raw, _ := os.read_entire_file_from_path(fmt.tprintf("%s/cache.json", dir), context.temp_allocator)
	leaks := 0
	for s in ([?]string{"Example Card", "4111111111111111", "record-pass-2", "bank.example.org", "card-holder", "Work Login", "work-pass-1", "Personal", "PKCS8"}) {
		if strings.contains(string(raw), s) {
			leaks += 1
			fmt.printfln("      the cache holds %q in the clear", s)
		}
	}
	check(leaks == 0, "%d plaintext strings in the cache file", leaks)
	dev, _ := os.read_entire_file_from_path(fmt.tprintf("%s/device.json", dir), context.temp_allocator)
	check(strings.contains(string(dev), "PV1-"), "device.json does not hold the Secret Key")
	dperm := perm_bits(fmt.tprintf("%s/device.json", dir))
	check(dperm & 0o077 == 0, "device.json is readable by others: %o", dperm)

	// A second device: the same directory read fresh, unlocked by password.
	a2x := acct_open(dir)
	defer acct_close(a2x)
	check(acct_unlock(a2x, "wrong master") != "", "a wrong master password unlocked the account")
	saved := a2x.secret
	a2x.secret[3] ~= 0x10
	check(acct_unlock(a2x, "fixture master") != "", "a wrong Secret Key unlocked the account")
	a2x.secret = saved
	uerr := acct_unlock(a2x, "fixture master")
	check(uerr == "", "the second device could not unlock: %s", uerr)
	v := Vault{entries = make([dynamic]Entry)}
	acct_entries(a2x, &v)
	check(len(v.entries) == 2, "the second device sees %d items, want 2", len(v.entries))
	for &x in v.entries {
		if x.title == "Example Card" {
			check(x.password == "record-pass-2" && field_get(&x, "Number") == "4111111111111111", "an item did not decrypt intact on the second device")
			check(a2x.sources[x.src].kind == .Own && handle_of(a2x, a2x.sources[x.src].viewer) == "fx", "the card is not in fx's own vault")
		}
	}
	vault_free(&v)

	// Tampering with what the server holds: a blob moved to another row, a
	// revision rewritten, a byte flipped. Each item silently fails to open
	// rather than opening as something else.
	r0 := a2x.cache.items[0]
	r1 := a2x.cache.items[1]
	a2x.cache.items[0].blob, a2x.cache.items[1].blob = r1.blob, r0.blob
	v = Vault{entries = make([dynamic]Entry)}
	acct_entries(a2x, &v)
	check(len(v.entries) == 0, "swapping two items' ciphertext still opened %d of them", len(v.entries))
	vault_free(&v)
	a2x.cache.items[0] = r0
	a2x.cache.items[1] = r1
	a2x.cache.items[0].revision += 1
	v = Vault{entries = make([dynamic]Entry)}
	acct_entries(a2x, &v)
	check(len(v.entries) == 1, "a rewritten revision number still opened the item")
	vault_free(&v)
	a2x.cache.items[0] = r0

	// Changing the private keys' public half on the server is noticed.
	a3 := acct_open(dir)
	defer acct_close(a3)
	other := identity_keys_generate()
	a3.cache.keysets[0].enc_pub = cs(a3, b64(other.pub.enc[:], context.temp_allocator))
	identity_keys_clear(&other)
	acct_unlock(a3, "fixture master")
	check(len(a3.problems) > 0, "a keyset whose published key was swapped raised no problem")
}

@(private = "file")
t_share_offline :: proc() {
	begin_section("sharing and rotating, offline")
	alice := offline_account(fmt.tprintf("%s/acct-alice", SCRATCH), "alice master")
	defer acct_close(alice)
	bob := offline_account(fmt.tprintf("%s/acct-bob", SCRATCH), "bob master", "b")
	defer acct_close(bob)

	ab := Book{mode = .Account, acct = alice}
	ab.v = Vault{entries = make([dynamic]Entry)}
	acct_entries(alice, &ab.v)
	e := entry_new("Shared Login")
	replace_string(&e.url, "https://shared.example")
	replace_secret(&e.password, "shared-pass-1")
	idx, _ := book_add(&ab, e, 0)
	id := strings.clone(ab.v.entries[idx].id, context.temp_allocator)
	promote_pending(alice)
	vault_free(&ab.v)

	// Alice seals the item key to bob's personal identity and signs the row,
	// which then "arrives" in bob's cache with alice's keys pinned.
	r := item_row(alice, id)
	key: [KEY_LEN]byte
	_, _, kok := item_key_of(alice, r, &key)
	check(kok, "alice cannot open her own item key")
	bob_id := bob.cache.idents[0].id
	bob_pub, _ := public_keys_of(bob, bob_id)
	sealed, _ := seal_to(&bob_pub, key[:], aad_item_share(id, bob_id), context.temp_allocator)
	sid := "5a000000-0000-4000-8000-000000000001"
	src_id := r.identity_id
	sig := sign_bytes(my_keys(alice, src_id), share_transcript(sid, src_id, r.vault_id, id, bob_id, "read", 1, sealed))
	append(&bob.cache.items, I_Row{cs(bob, r.id), cs(bob, r.identity_id), cs(bob, r.vault_id), r.revision, r.key_version, cs(bob, r.key_wrap), cs(bob, r.blob), false})
	ks := keyset_of(alice, src_id)
	append(&bob.cache.pins, Pin{cs(bob, src_id), cs(bob, "fx"), cs(bob, "Alice"), cs(bob, ks.enc_pub), cs(bob, ks.kem_pub), cs(bob, ks.sign_pub)})
	share := S_Row{cs(bob, sid), cs(bob, src_id), cs(bob, r.vault_id), cs(bob, id), cs(bob, bob_id), cs(bob, "read"), 1, cs(bob, b64(sealed, context.temp_allocator)), cs(bob, b64(sig[:], context.temp_allocator)), false}
	append(&bob.cache.shares, share)
	open_vault_keys(bob)
	v := Vault{entries = make([dynamic]Entry)}
	acct_entries(bob, &v)
	got := ""
	for &x in v.entries {
		if x.id == id {
			got = strings.clone(x.password, context.temp_allocator)
			check(bob.sources[x.src].kind == .Shared_Items, "the shared login is not under 'Shared with me'")
		}
	}
	check(got == "shared-pass-1", "bob did not decrypt the shared login (got %q)", got)
	vault_free(&v)

	// A server that swaps the wrapped key for one it chose is caught by the
	// signature, even though bob can open what it sealed.
	fake: [KEY_LEN]byte
	crypto.rand_bytes(fake[:])
	forged, _ := seal_to(&bob_pub, fake[:], aad_item_share(id, bob_id), context.temp_allocator)
	bob.cache.shares[0].wrapped_key = cs(bob, b64(forged, context.temp_allocator))
	clear(&bob.problems)
	open_vault_keys(bob)
	check(len(bob.ikeys) == 0 && len(bob.problems) == 1, "a share with a substituted key was accepted (%d keys, %d problems)", len(bob.ikeys), len(bob.problems))
	bob.cache.shares[0] = share
	open_vault_keys(bob)
	check(len(bob.ikeys) == 1, "the genuine share no longer opens")

	// Rotation: alice re-encrypts the item under a fresh key (what
	// rotate_item does after a revoke). Bob's old key no longer opens what
	// the server now holds.
	ab.v = Vault{entries = make([dynamic]Entry)}
	acct_entries(alice, &ab.v)
	for &x in ab.v.entries {
		if x.id == id {
			x.flags |= ENTRY_EXPOSED
			acct_put(alice, &x, x.src >= 0 ? alice.sources[x.src].vault_id : "", new_item_key = true)
		}
	}
	vault_free(&ab.v)
	promote_pending(alice)
	nr := item_row(alice, id)
	bob.cache.items[0].blob = cs(bob, nr.blob)
	bob.cache.items[0].key_wrap = cs(bob, nr.key_wrap)
	bob.cache.items[0].revision = nr.revision
	v = Vault{entries = make([dynamic]Entry)}
	acct_entries(bob, &v)
	check(len(v.entries) == 0, "after rotation bob's old item key still opens the new ciphertext")
	vault_free(&v)
	nk: [KEY_LEN]byte
	_, _, nok := item_key_of(alice, nr, &nk)
	check(nok && nk != key, "rotation did not change the item key")
	crypto.zero_explicit(&key, size_of(key))
}

// ---------------------------------------------------------------------------
// Merging
// ---------------------------------------------------------------------------

@(private = "file")
t_merge :: proc() {
	begin_section("per-item conflict merging")
	base := entry_new("Bank")
	defer entry_free(&base)
	replace_string(&base.username, "u0")
	replace_secret(&base.password, "p0")
	entry_set_tags(&base, "money, old")
	base.modified = 100
	ours := entry_clone(&base)
	defer entry_free(&ours)
	theirs := entry_clone(&base)
	defer entry_free(&theirs)

	replace_string(&ours.username, "u-ours")
	entry_set_tags(&ours, "money, mine")
	ours.modified = 200
	replace_secret(&theirs.notes, "their note")
	entry_set_tags(&theirs, "money, old, theirs")
	theirs.modified = 150

	m, c := merge3(&base, &ours, &theirs)
	check(!c, "edits to different fields were reported as a conflict")
	check(m.username == "u-ours" && m.notes == "their note", "edits to different fields did not both survive: %q %q", m.username, m.notes)
	tags := entry_tag_text(&m)
	check(strings.contains(tags, "mine") && strings.contains(tags, "theirs") && !strings.contains(tags, "old"), "tags did not merge as sets: %s", tags)
	entry_free(&m)

	// Both changed the password: the later one wins, the other goes to history.
	entry_set_password(&ours, "p-ours")
	ours.modified = 300
	entry_set_password(&theirs, "p-theirs")
	theirs.modified = 250
	m, c = merge3(&base, &ours, &theirs)
	check(c, "two different passwords were not reported as a conflict")
	check(m.password == "p-ours", "the later password did not win: %q", m.password)
	kept := false
	for h in m.history {
		if h.password == "p-theirs" {
			kept = true
		}
	}
	check(kept, "the losing password was dropped instead of kept in the history")
	entry_free(&m)
	theirs.modified = 400
	m, _ = merge3(&base, &ours, &theirs)
	check(m.password == "p-theirs", "when theirs is later it should win")
	entry_free(&m)
}

// ---------------------------------------------------------------------------
// Importers, against fixtures written by other programs
// ---------------------------------------------------------------------------

@(private = "file")
FIX_KDBX_D :: #load("testdata/keepass-argon2d-chacha20.kdbx")
@(private = "file")
FIX_KDBX_ID :: #load("testdata/keepass-argon2id-aes256.kdbx")
@(private = "file")
FIX_KDBX_AES :: #load("testdata/keepass-aeskdf-aes256.kdbx")
@(private = "file")
FIX_BW_JSON :: #load("testdata/bitwarden.json")
@(private = "file")
FIX_BW_CSV :: #load("testdata/bitwarden.csv")
@(private = "file")
FIX_CHROME :: #load("testdata/chrome.csv")
@(private = "file")
FIX_FIREFOX :: #load("testdata/firefox.csv")
@(private = "file")
FIX_1PUX :: #load("testdata/sample.1pux")

@(private = "file")
fixture :: proc(name: string, data: []byte, format := "auto", pw := "") -> Import_Result {
	path := fmt.tprintf("%s/%s", SCRATCH, name)
	_ = os.write_entire_file(path, data)
	return import_path(path, format, pw)
}

@(private = "file")
find :: proc(r: ^Import_Result, title: string) -> ^Entry {
	for &e in r.entries {
		if e.title == title {
			return &e
		}
	}
	return nil
}

@(private = "file")
t_imports :: proc() {
	begin_section("importers: KeePass (pykeepass), Bitwarden, 1Password, Chrome, Firefox, palmy")

	for f in ([?]struct {
			name: string,
			data: []byte,
		}{{"kp-d.kdbx", FIX_KDBX_D}, {"kp-id.kdbx", FIX_KDBX_ID}, {"kp-aes.kdbx", FIX_KDBX_AES}}) {
		r := fixture(f.name, f.data, "auto", "keepass-fixture-password")
		check(r.err == "" && r.format == "kdbx", "%s: %s", f.name, r.err)
		check(len(r.entries) == 3 && r.skipped == 1, "%s: %d entries, %d skipped (want 3 and the recycle bin's 1)", f.name, len(r.entries), r.skipped)
		if m := find(&r, "Example Mail"); m != nil {
			check(m.password == "kp-mail-pass-Zx81!" && m.username == "sample.user@example.com", "%s: the mail login is wrong", f.name)
			check(m.notes == "Line one\nLine <two> & three", "%s: the notes lost their markup characters: %q", f.name, m.notes)
			check(m.totp == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ" && m.totp_period == 30, "%s: the otp setting was not read: %q", f.name, m.totp)
			check(field_get(m, "Recovery code") == "RC-1234-5678" && m.fields[0].secret, "%s: a protected custom field was not decrypted", f.name)
			tags := entry_tag_text(m)
			check(strings.contains(tags, "mail") && strings.contains(tags, "sample"), "%s: the tags are %q", f.name, tags)
		} else {
			check(false, "%s: Example Mail is missing", f.name)
		}
		if g := find(&r, "Example Forge"); g != nil {
			check(g.password == "kp-forge-pass-NEW-99%", "%s: the forge password is %q", f.name, g.password)
			check(len(g.history) == 1 && g.history[0].password == "kp-forge-pass-Qw77#", "%s: the history did not come across", f.name)
			check(entry_tag_text(g) == "Work", "%s: the group did not become a tag: %q", f.name, entry_tag_text(g))
		}
		if rt := find(&r, "Example Router"); rt != nil {
			check(entry_tag_text(rt) == "Work/Servers", "%s: the nested group is %q", f.name, entry_tag_text(rt))
		}
		import_result_free(&r)
		bad := fixture(f.name, f.data, "auto", "wrong password")
		check(bad.err != "" && strings.contains(bad.err, "password"), "%s: a wrong password said %q", f.name, bad.err)
		import_result_free(&bad)
	}
	// Tampering with a KeePass file is caught by its own HMACs.
	t := make([]byte, len(FIX_KDBX_D), context.temp_allocator)
	copy(t, FIX_KDBX_D)
	t[len(t) - 40] ~= 1
	tr := fixture("kp-t.kdbx", t, "kdbx", "keepass-fixture-password")
	check(tr.err != "", "a tampered KeePass block was accepted")
	import_result_free(&tr)

	r := fixture("bw.json", FIX_BW_JSON)
	check(r.err == "" && r.format == "bitwarden-json" && len(r.entries) == 5 && r.skipped == 1, "bitwarden json: %s, %d entries", r.err, len(r.entries))
	if f := find(&r, "Example Forge"); f != nil {
		check(f.password == "bw-fixture-pass-Ab12!" && f.username == "fixture-dev" && f.favorite, "bitwarden: login fields")
		check(f.url == "https://forge.example.net/login" && len(f.urls) == 1, "bitwarden: the URIs")
		check(f.totp_digits == 8 && f.totp_algo == .SHA256 && f.totp == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "bitwarden: the otpauth URI was not read")
		check(field_get(f, "PIN") == "bw-fixture-pin-4711" && entry_tag_text(f) == "Work", "bitwarden: hidden field or folder")
		check(len(f.history) == 1 && f.history[0].password == "bw-fixture-old-pass-1", "bitwarden: password history")
	}
	if p := find(&r, "Example Passkey Site"); p != nil {
		check(p.kind == .Passkey && p.passkey.rp_id == "passkeys.example.com" && p.passkey.counter == 7 && p.passkey.discoverable, "bitwarden: the passkey")
	}
	if c := find(&r, "Example Card"); c != nil {
		check(c.kind == .Card && field_get(c, "Number") == "4111111111111111", "bitwarden: the card")
		for kv in c.fields {
			if kv.label == "Number" || kv.label == "Security code" {
				check(kv.secret, "bitwarden: the card's %s is not marked secret", kv.label)
			}
		}
	}
	if d := find(&r, "Example Passport"); d != nil {
		check(d.kind == .Document && field_get(d, "passportNumber") == "X0000000", "bitwarden: the identity document")
	}
	// Export to Bitwarden's format and import it again: nothing lost.
	v := Vault{entries = make([dynamic]Entry)}
	for &e in r.entries {
		append(&v.entries, entry_clone(&e))
	}
	text := export_bitwarden_json(&v)
	rr := fixture("bw-round.json", transmute([]byte)text)
	check(rr.err == "" && len(rr.entries) == len(v.entries), "a Bitwarden export did not import back: %s", rr.err)
	if f := find(&rr, "Example Forge"); f != nil {
		check(f.password == "bw-fixture-pass-Ab12!" && field_get(f, "PIN") == "bw-fixture-pin-4711" && len(f.history) == 1, "the round trip lost fields")
	}
	if p := find(&rr, "Example Passkey Site"); p != nil {
		check(p.passkey.credential_id == "q8Z7cFkNfixtureCredId", "the round trip lost the passkey")
	}
	import_result_free(&rr)
	delete(text)
	// And as an encrypted .pvz, through import_pvz.
	pvz := fmt.tprintf("%s/export.pvz", SCRATCH)
	check(export_pvz(&v, pvz, "export password 123") == "", "export_pvz failed")
	pr := import_path(pvz, "auto", "export password 123")
	check(pr.err == "" && pr.format == "pvz" && len(pr.entries) == len(v.entries), "a .pvz export did not import back: %s", pr.err)
	ids_new := true
	for &e in pr.entries {
		for &o in v.entries {
			if e.id == o.id {
				ids_new = false
			}
		}
	}
	check(ids_new, "an import kept the source's item ids instead of making new items")
	import_result_free(&pr)
	vault_free(&v)
	import_result_free(&r)

	enc := fixture("bw-enc.json", transmute([]byte)string(`{"encrypted": true, "items": []}`))
	check(enc.err != "" && strings.contains(enc.err, "encrypted"), "an encrypted Bitwarden export was not refused with a reason")
	import_result_free(&enc)

	r = fixture("bw.csv", FIX_BW_CSV)
	check(r.err == "" && r.format == "bitwarden-csv" && len(r.entries) == 2, "bitwarden csv: %s %d", r.err, len(r.entries))
	if w := find(&r, "Example Wiki"); w != nil {
		check(w.password == "bwcsv-fixture-pass-1" && w.notes == "A note, with a comma" && field_get(w, "Floor") == "3" && w.totp == "JBSWY3DPEHPK3PXP", "bitwarden csv: fields")
	}
	import_result_free(&r)
	r = fixture("chrome.csv", FIX_CHROME)
	check(r.err == "" && r.format == "chrome" && len(r.entries) == 2, "chrome: %s %d", r.err, len(r.entries))
	if q := find(&r, "Example \"Quoted\" Site"); q != nil {
		check(q.password == "chrome,fixture,pass,2" && q.notes == "multi\nline note", "chrome: quoting")
	}
	import_result_free(&r)
	r = fixture("firefox.csv", FIX_FIREFOX)
	check(r.err == "" && r.format == "firefox" && len(r.entries) == 1 && r.skipped == 1, "firefox: %s %d", r.err, len(r.entries))
	if len(r.entries) == 1 {
		check(r.entries[0].title == "news.example.com" && r.entries[0].created == 1700000000, "firefox: title from host, time from milliseconds")
	}
	import_result_free(&r)
	r = fixture("sample.1pux", FIX_1PUX)
	check(r.err == "" && r.format == "1pux" && len(r.entries) == 2 && r.skipped == 1, "1pux: %s %d", r.err, len(r.entries))
	if c := find(&r, "Example Cloud"); c != nil {
		check(c.username == "fixture-op-user" && c.password == "op-fixture-pass-1" && c.totp == "JBSWY3DPEHPK3PXP", "1pux: login fields")
		check(field_get(c, "Security answer") == "op-fixture-answer" && len(c.urls) == 1 && len(c.history) == 1, "1pux: sections, urls, history")
	}
	if d := find(&r, "Example Debit Card"); d != nil {
		check(d.kind == .Card && field_get(d, "number") == "4111111111111111" && field_get(d, "expiry date") == "12/2030", "1pux: the card")
	}
	import_result_free(&r)
	garbage := fixture("garbage.bin", transmute([]byte)string("not a password export at all"))
	check(garbage.err != "", "an unrecognised file was not refused")
	import_result_free(&garbage)
}

// ---------------------------------------------------------------------------
// Health and the breach check
// ---------------------------------------------------------------------------

@(private = "file")
g_hibp_asked: [dynamic]string

@(private = "file")
fake_hibp :: proc(prefix: string) -> (string, string) {
	append(&g_hibp_asked, strings.clone(prefix))
	// SHA-1("password") = 5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8, seen
	// 3.8 million times in the real corpus; here, an invented count. The
	// padding lines (count 0) are what Add-Padding returns.
	if prefix == "5BAA6" {
		return "003D68EB55068C33ACE09247EE4C639306B:0\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:3861493\r\n011053FD0102E94D6AE2F8B83D76FAF94F6:0\r\n", ""
	}
	return "0000000000000000000000000000000000A:0\r\n", ""
}

@(private = "file")
t_health :: proc() {
	begin_section("password health, and the breach check's k-anonymity")
	v := Vault{entries = make([dynamic]Entry)}
	defer vault_free(&v)
	add :: proc(v: ^Vault, title, pw: string) {
		e := entry_new(title)
		replace_secret(&e.password, pw)
		append(&v.entries, e)
	}
	add(&v, "Common", "password")
	add(&v, "Composed", "Summer2024!")
	add(&v, "Short", "aB3$xY")
	add(&v, "Strong A", "g7#Kq!2mVx9@Lr4Tz8&Wn")
	add(&v, "Strong B", "g7#Kq!2mVx9@Lr4Tz8&Wn")
	add(&v, "Unique", "Hk2$pQ9!zR7@tM4#wX8&")
	v.entries[5].flags |= ENTRY_EXPOSED
	h := health_check(&v)
	defer health_free(&h)
	weak := map[string]bool{}
	defer delete(weak)
	for f in h.findings {
		if f.issue == .Weak {
			weak[v.entries[f.entry].title] = true
		}
	}
	check(weak["Common"] && weak["Composed"] && weak["Short"] && !weak["Strong A"] && !weak["Unique"], "weak passwords: %v", weak)
	check(h.reused == 2, "a password used twice should give two reused findings, got %d", h.reused)
	check(h.exposed == 1, "the exposed flag gave %d findings", h.exposed)

	check(hibp_sha1("password") == "5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8", "SHA-1(\"password\") is %s", hibp_sha1("password"))
	err := health_breach(&h, &v, fake_hibp)
	check(err == "" && h.breached == 1, "the breach check found %d (want 1): %s", h.breached, err)
	all_prefixes := true
	for p in g_hibp_asked {
		if len(p) != 5 {
			all_prefixes = false
		}
	}
	check(all_prefixes, "the breach check would have sent something other than a 5-character prefix")
	check(len(g_hibp_asked) == 5, "5 distinct passwords should cost 5 range requests, not %d (the reused one is asked once)", len(g_hibp_asked))
	for p in g_hibp_asked {
		delete(p)
	}
	delete(g_hibp_asked)
}

// ---------------------------------------------------------------------------
// Origins
// ---------------------------------------------------------------------------

@(private = "file")
t_origins :: proc() {
	begin_section("autofill origin matching")
	cases := [?]struct {
		origin, stored, want: string,
	} {
		{"https://github.com", "https://github.com/login", "exact"},
		{"https://github.com", "github.com", "exact"},
		{"https://gist.github.com", "https://github.com", "subdomain"},
		{"https://GitHub.com", "https://github.com", "exact"},
		{"https://github.com", "https://gist.github.com", ""},
		{"http://github.com", "https://github.com", ""},
		{"https://github.com", "http://github.com", ""},
		{"http://192.0.2.1", "http://192.0.2.1", "exact"},
		{"https://github.com.evil.example", "https://github.com", ""},
		{"https://evilgithub.com", "https://github.com", ""},
		{"https://github.com:8443", "https://github.com", ""},
		{"https://github.com:443", "https://github.com", "exact"},
		{"https://user:pw@github.com", "https://github.com", ""},
		{"https://shop.co.uk", "https://co.uk", ""},
		{"https://alice.github.io", "https://bob.github.io", ""},
		{"https://alice.github.io", "https://github.io", ""},
		{"file:///etc/passwd", "file:///etc/passwd", ""},
		{"javascript:alert(1)", "https://github.com", ""},
	}
	bad := 0
	for c in cases {
		k, _ := origin_match(c.origin, c.stored)
		if k != c.want {
			bad += 1
			fmt.printfln("      origin %s vs stored %s: %q, want %q", c.origin, c.stored, k, c.want)
		}
		check(k == c.want, "origin_match(%s, %s)", c.origin, c.stored)
	}
	_ = bad
}

// ---------------------------------------------------------------------------
// The autofill protocol, in-process: server and reference client
// ---------------------------------------------------------------------------

@(private = "file")
Af_Test :: struct {
	s:      ^Af_Server,
	b:      ^Book,
	policy: Af_Decision,
}

@(private = "file")
af_test_pump :: proc(data: rawptr) {
	t := (^Af_Test)(data)
	af_pump(t.s, t.b, t.policy, 0)
}

@(private = "file")
t_autofill :: proc() {
	begin_section("the autofill socket: pairing, auth, origin binding, confirmation")
	path := fmt.tprintf("%s/vault-af.pvz", SCRATCH)
	sess, err := store_create(path, "autofill fixture", FAST)
	check(err == "", "could not create the fixture vault: %s", err)
	b := Book{mode = .Local, path = path, sess = sess, v = Vault{entries = make([dynamic]Entry)}}
	defer book_lock(&b)
	e := entry_new("Forge")
	replace_string(&e.username, "fx")
	replace_string(&e.url, "https://forge.example.net")
	replace_secret(&e.password, "af-fixture-pass")
	replace_secret(&e.totp, base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator))
	book_add(&b, e)
	n := entry_new("A note")
	n.kind = .Note
	replace_string(&n.url, "https://forge.example.net")
	book_add(&b, n)
	forge_id := strings.clone(b.v.entries[0].id, context.temp_allocator)

	s: Af_Server
	s.pairs_path = strings.clone(fmt.tprintf("%s/af-pairs.json", SCRATCH))
	_ = os.remove(s.pairs_path)
	sock := fmt.tprintf("%s/af/autofill.sock", SCRATCH)
	serr := af_start(&s, sock)
	check(serr == "", "the autofill socket did not start: %s", serr)
	defer af_stop(&s)
	sperm := perm_bits(fmt.tprintf("%s/af", SCRATCH))
	check(sperm & 0o077 == 0, "the socket's directory is open to others: %o", sperm)
	t := Af_Test{&s, &b, .Once}

	cl, derr := af_dial(sock)
	check(derr == "", "could not connect: %s", derr)
	defer af_close(&cl)
	call :: proc(cl: ^Af_Client, t: ^Af_Test, req: string) -> string {
		_, raw, _ := af_call(cl, req, af_test_pump, t)
		return raw
	}
	hello := call(&cl, &t, af_req("op", "hello"))
	check(strings.contains(hello, "\"state\": \"unlocked\"") && strings.contains(hello, "challenge"), "hello: %s", hello)
	check(len(s.conns) == 1 && s.conns[0].uid == u32(linux.getuid()), "SO_PEERCRED did not identify the peer as this user")
	unpaired := call(&cl, &t, af_req("op", "query", "origin", "https://forge.example.net"))
	check(strings.contains(unpaired, "unpaired") && !strings.contains(unpaired, "Forge"), "an unpaired client got an answer: %s", unpaired)

	// Pair: denied first, then allowed.
	key: [32]byte
	crypto.rand_bytes(key[:])
	t.policy = .Deny
	denied := call(&cl, &t, af_req("op", "pair", "name", "test browser", "key", b64(key[:], context.temp_allocator)))
	check(strings.contains(denied, "denied"), "a denied pairing answered: %s", denied)
	t.policy = .Once
	paired := call(&cl, &t, af_req("op", "pair", "name", "test browser", "key", b64(key[:], context.temp_allocator)))
	check(strings.contains(paired, "pair_id"), "pairing failed: %s", paired)
	pid_start := strings.index(paired, "pair_id\": \"") + 11
	pair_id := paired[pid_start:pid_start + 36]
	challenge := hello[strings.index(hello, "challenge\": \"") + 13:]
	challenge = challenge[:strings.index_byte(challenge, '"')]
	other: [32]byte
	crypto.rand_bytes(other[:])
	forged := call(&cl, &t, af_req("op", "auth", "pair_id", pair_id, "proof", af_proof(other[:], challenge)))
	check(strings.contains(forged, "unpaired"), "a proof under the wrong key authenticated: %s", forged)
	authed := call(&cl, &t, af_req("op", "auth", "pair_id", pair_id, "proof", af_proof(key[:], challenge)))
	check(strings.contains(authed, "\"ok\": true"), "the right proof failed: %s", authed)

	q := call(&cl, &t, af_req("op", "query", "origin", "https://forge.example.net", "identity", ""))
	check(strings.contains(q, forge_id) && !strings.contains(q, "A note") && !strings.contains(q, "af-fixture-pass"), "query: %s", q)
	q2 := call(&cl, &t, af_req("op", "query", "origin", "https://forge.example.net.evil.example", "identity", ""))
	check(strings.contains(q2, "\"candidates\": []"), "a lookalike origin got candidates: %s", q2)
	t.policy = .Deny
	d := call(&cl, &t, af_req("op", "fill", "id", forge_id, "origin", "https://forge.example.net", "identity", ""))
	check(strings.contains(d, "denied") && !strings.contains(d, "af-fixture-pass"), "a denied fill: %s", d)
	t.policy = .Always
	f := call(&cl, &t, af_req("op", "fill", "id", forge_id, "origin", "https://forge.example.net", "identity", ""))
	check(strings.contains(f, "af-fixture-pass") && strings.contains(f, "\"totp\""), "an allowed fill did not carry the password and code: %s", f)
	t.policy = .Deny
	f2 := call(&cl, &t, af_req("op", "fill", "id", forge_id, "origin", "https://forge.example.net", "identity", ""))
	check(strings.contains(f2, "af-fixture-pass"), "\"always for this site\" was not remembered")
	wrong := call(&cl, &t, af_req("op", "fill", "id", forge_id, "origin", "https://elsewhere.example", "identity", ""))
	check(strings.contains(wrong, "not for this origin"), "a fill for another origin: %s", wrong)

	// A second connection must authenticate again: the old proof is spent.
	cl2, _ := af_dial(sock)
	defer af_close(&cl2)
	call(&cl2, &t, af_req("op", "hello"))
	replay := call(&cl2, &t, af_req("op", "auth", "pair_id", pair_id, "proof", af_proof(key[:], challenge)))
	check(strings.contains(replay, "unpaired"), "a proof replayed on a new connection authenticated: %s", replay)

	// Saving a login from a form.
	t.policy = .Once
	sv := call(&cl, &t, af_req("op", "save", "origin", "https://new.example", "identity", "", "username", "newuser", "password", "saved-from-form-1"))
	check(strings.contains(sv, "saved"), "save: %s", sv)
	found := false
	for &x in b.v.entries {
		if x.url == "https://new.example" && x.password == "saved-from-form-1" {
			found = true
		}
	}
	check(found, "the saved login is not in the vault")

	// Updating a login the browser saw a new password for: the same origin
	// and identity bindings as a fill, the person decides, the old password
	// goes to the history.
	t.policy = .Deny
	ud := call(&cl, &t, af_req("op", "save", "id", forge_id, "origin", "https://forge.example.net", "identity", "", "username", "fx", "password", "changed-on-the-site-2"))
	check(strings.contains(ud, "denied"), "a declined update answered: %s", ud)
	uw := call(&cl, &t, af_req("op", "save", "id", forge_id, "origin", "https://elsewhere.example", "identity", "", "username", "fx", "password", "changed-on-the-site-2"))
	check(strings.contains(uw, "not for this origin"), "an update from another origin: %s", uw)
	un := call(&cl, &t, af_req("op", "save", "id", forge_id, "origin", "https://forge.example.net", "identity", "", "username", "fx", "password", ""))
	check(strings.contains(un, "no password"), "an update without a password: %s", un)
	t.policy = .Once
	uo := call(&cl, &t, af_req("op", "save", "id", forge_id, "origin", "https://forge.example.net", "identity", "", "username", "fx", "password", "changed-on-the-site-2"))
	check(strings.contains(uo, "\"updated\": true"), "update: %s", uo)
	updated := false
	for &x in b.v.entries {
		if x.id == forge_id {
			updated = x.password == "changed-on-the-site-2" && x.username == "fx" && len(x.history) > 0 && x.history[len(x.history) - 1].password == "af-fixture-pass"
		}
	}
	check(updated, "the updated password (or the old one in the history) is not in the vault")
	ux := call(&cl, &t, af_req("op", "save", "id", "no-such-id", "origin", "https://forge.example.net", "identity", "", "password", "x"))
	check(strings.contains(ux, "no such login"), "an update of an unknown id: %s", ux)

	// Locked: candidates are empty and fills are refused, without a word
	// about what is inside.
	vault_free(&b.v)
	session_zero(&b.sess)
	lq := call(&cl, &t, af_req("op", "query", "origin", "https://forge.example.net", "identity", ""))
	check(strings.contains(lq, "\"state\": \"locked\"") && strings.contains(lq, "\"candidates\": []"), "a locked vault answered: %s", lq)
	crypto.zero_explicit(&key, size_of(key))
}

// ---------------------------------------------------------------------------
// The data directory, and the QEMU HOME=/root failure
// ---------------------------------------------------------------------------

@(private = "file")
t_data_dir :: proc() {
	begin_section("where the vault lives when HOME is not ours")
	saved_x := strings.clone(os.get_env("XDG_DATA_HOME", context.temp_allocator), context.temp_allocator)
	saved_h := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	defer {
		os.set_env("XDG_DATA_HOME", saved_x)
		os.set_env("HOME", saved_h)
	}
	os.unset_env("XDG_DATA_HOME")
	// "/" is root's. Running as anyone else, a HOME of "/" must not be used.
	os.set_env("HOME", "/")
	dir, why := data_dir_explained()
	if linux.getuid() != 0 {
		check(!strings.has_prefix(dir, "/.local"), "a HOME owned by root was used: %s", dir)
		check(strings.contains(why, "/etc/passwd"), "the reason does not say where the directory came from: %s", why)
	}
	os.set_env("HOME", SCRATCH)
	dir, why = data_dir_explained()
	check(strings.has_prefix(dir, SCRATCH) && why == "$HOME", "a HOME this user owns was not used: %s (%s)", dir, why)
}
