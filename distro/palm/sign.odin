package palm

// Keys and signatures: the one thing that makes a plain-http repository safe.
//
// The chain of trust is two links long, as in apk:
//
//	/etc/palm/keys/*.pub  ──verifies──▶  PALMINDEX.sig  ──covers──▶  PALMINDEX
//	PALMINDEX  ──sha256 of each .palm──▶  the package files
//
// Keys are ed25519 (core:crypto). Every key file is one line of hex, so it can
// be pasted, diffed and checked into a recipe tree:
//
//	<name>.pub   the 32-byte public key            (trusted by putting it in
//	                                                 /etc/palm/keys/)
//	<name>.sec   the 32-byte private seed, 0600    (never leaves the builder)
//
// PALMINDEX.sig is one line too: the 64-byte signature over the exact bytes
// of PALMINDEX, in hex. A repository is accepted if any trusted key verifies
// it, which is how a key is rotated: ship the new .pub, then re-sign.

import "core:crypto"
import "core:crypto/ed25519"
import "core:fmt"
import "core:os"
import "core:strings"

Trusted_Key :: struct {
	name: string,
	key:  ed25519.Public_Key,
}

keygen :: proc(name: string) -> Err {
	if !crypto.HAS_RAND_BYTES {
		return fail(EXIT_FAILED, "no system entropy source")
	}
	seed: [ed25519.PRIVATE_KEY_SIZE]byte
	crypto.rand_bytes(seed[:])
	defer crypto.zero_explicit(&seed, size_of(seed))
	priv: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&priv, seed[:]) {
		return fail(EXIT_FAILED, "could not derive a key")
	}
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&priv, pub[:])

	sec_path := fmt.tprintf("%s.sec", name)
	pub_path := fmt.tprintf("%s.pub", name)
	if os.exists(sec_path) {
		return fail(EXIT_REFUSED, "%s already exists; not overwriting a secret key", sec_path)
	}
	if os.write_entire_file(sec_path, fmt.tprintf("%s\n", hex_encode(seed[:], context.temp_allocator)), os.perm_number(0o600)) != nil {
		return fail(EXIT_FAILED, "cannot write %s", sec_path)
	}
	if os.write_entire_file(pub_path, fmt.tprintf("%s\n", hex_encode(pub[:], context.temp_allocator)), os.perm_number(0o644)) != nil {
		return fail(EXIT_FAILED, "cannot write %s", pub_path)
	}
	say("wrote %s and %s", sec_path, pub_path)
	return Err{}
}

load_secret :: proc(path: string) -> (priv: ed25519.Private_Key, e: Err) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		return priv, fail(EXIT_NOT_FOUND, "cannot read the key %s", path)
	}
	seed, okh := hex_decode(string(data), context.temp_allocator)
	if !okh || len(seed) != ed25519.PRIVATE_KEY_SIZE || !ed25519.private_key_set_bytes(&priv, seed) {
		return priv, fail(EXIT_FAILED, "%s is not a palm secret key (64 hex digits)", path)
	}
	return priv, Err{}
}

sign_bytes :: proc(priv: ^ed25519.Private_Key, msg: []byte, allocator := context.allocator) -> string {
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(priv, msg, sig[:])
	return hex_encode(sig[:], allocator)
}

parse_public :: proc(text: string) -> (key: ed25519.Public_Key, okk: bool) {
	b, okh := hex_decode(text, context.temp_allocator)
	if !okh || len(b) != ed25519.PUBLIC_KEY_SIZE {
		return key, false
	}
	return key, ed25519.public_key_set_bytes(&key, b)
}

// load_trusted reads every *.pub in a directory. A missing directory is an
// empty trust set, not an error: the refusal comes later, when a repository
// turns out to be signed by nobody palm trusts.
load_trusted :: proc(dir: string, allocator := context.allocator) -> []Trusted_Key {
	out := make([dynamic]Trusted_Key, allocator)
	infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return out[:]
	}
	for fi in infos {
		if !strings.has_suffix(fi.name, ".pub") {
			continue
		}
		data, rerr := os.read_entire_file_from_path(fi.fullpath, context.temp_allocator)
		if rerr != nil {
			continue
		}
		key, okk := parse_public(string(data))
		if !okk {
			warn("%s is not an ed25519 public key; ignored", fi.fullpath)
			continue
		}
		append(&out, Trusted_Key{strings.clone(fi.name, allocator), key})
	}
	return out[:]
}

// verify_any returns the name of the key that verified, or "".
verify_any :: proc(keys: []Trusted_Key, msg: []byte, sig_hex: string) -> string {
	sig, okh := hex_decode(sig_hex, context.temp_allocator)
	if !okh || len(sig) != ed25519.SIGNATURE_SIZE {
		return ""
	}
	for &k in keys {
		if ed25519.verify(&k.key, msg, sig) {
			return k.name
		}
	}
	return ""
}
