package palm

// A TLS 1.3 client (RFC 8446), only as much of it as fetching from a package
// mirror needs, written on core:crypto.
//
// WHY palm HAS ITS OWN. The index signature already decides whether palm
// believes a download, so TLS is not what makes a package trustworthy. What it
// adds is privacy (an observer no longer reads which packages a machine
// fetches) and a second, independent check that the bytes came from the host
// named in /etc/palm/repositories, which matters for freshness: a signed but
// old index replayed by someone on the path is stopped by the rollback check
// in repo.odin, and on https only the mirror itself could try it. The other
// ways to get TLS were a dlopen of the system's OpenSSL (Palmframe ships
// none, and palm must keep working in an empty --root on any build host) or
// shipping BearSSL as a package, which puts a C library under the package
// manager that installs it. Odin's core:crypto already has every primitive and
// a strict X.509 path validator, so what is left is the protocol: about 700
// lines with no new dependency.
//
// What it does:
//
//   - TLS 1.3 only. A server that answers with TLS 1.2 is refused with a
//     message saying so; every CDN a repository would sit on speaks 1.3.
//   - Key exchange X25519 or P-256: both key shares go in the first
//     ClientHello, so a HelloRetryRequest is never needed and is refused.
//   - Ciphers TLS_AES_128_GCM_SHA256, TLS_CHACHA20_POLY1305_SHA256 and
//     TLS_AES_256_GCM_SHA384.
//   - The server's chain is validated by core:crypto/x509 against the CA
//     bundle (tls_roots below), for the host name, for serverAuth, at the
//     current time. CertificateVerify is checked for ECDSA P-256/P-384,
//     RSA-PSS and Ed25519; Finished is checked with HMAC.
//   - After the handshake: application data, NewSessionTicket (ignored, there
//     is no resumption), KeyUpdate in both directions, close_notify.
//
// What it does not: client certificates, resumption, 0-RTT, revocation (as
// x509's documentation says, no CRL or OCSP; the index signature is the
// backstop), and anything before TLS 1.3.

import "core:crypto"
import "core:crypto/aead"
import "core:crypto/ecdh"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:crypto/hkdf"
import "core:crypto/hmac"
import "core:crypto/rsa"
import "core:crypto/x509"
import "core:encoding/pem"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

@(private = "file")
TLS_MAX_PLAIN :: 16384

@(private = "file")
TLS_MAX_CIPHER :: 16384 + 256

// The ServerHello.random that marks a HelloRetryRequest (RFC 8446 4.1.3).
@(private = "file")
HRR_RANDOM := [32]byte {
	0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
	0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
}

@(private = "file")
Tls_Keys :: struct {
	on:     bool,
	secret: [48]byte,
	iv:     [12]byte,
	seq:    u64,
	ctx:    aead.Context,
}

Tls :: struct {
	sock:       net.TCP_Socket,
	host:       string,
	hash_alg:   hash.Algorithm,
	hash_len:   int,
	aead_alg:   aead.Algorithm,
	key_len:    int,
	read:       Tls_Keys,
	write:      Tls_Keys,
	raw:        [dynamic]byte, // bytes from the socket not yet cut into records
	raw_off:    int,
	rec:        [dynamic]byte, // the current record's plaintext
	hs:         [dynamic]byte, // handshake bytes not yet consumed
	app:        [dynamic]byte, // application data not yet returned
	app_off:    int,
	closed:     bool,
	transcript: hash.Context,
}

// ---------------------------------------------------------------------------
// Trust anchors
// ---------------------------------------------------------------------------

// CA bundles, first match wins. PALM_CA_FILE is for the selftest and for a
// person who wants palm to trust exactly one CA; the system bundle is used if
// something installed one; palm's package ships its own copy of the Mozilla
// roots so a Palmframe system needs nothing else.
CA_FILES := [?]string{"/etc/ssl/certs/ca-certificates.crt", "/etc/ssl/cert.pem", "/usr/share/palm/ca-certificates.crt"}

@(private = "file")
g_roots_mutex: sync.Mutex
@(private = "file")
g_roots_loaded: bool
@(private = "file")
g_roots: [dynamic]^x509.Certificate
@(private = "file")
g_roots_from: string

// tls_roots loads the CA bundle once per process. The root directory is the
// running system's, not --root's: --root names the system being changed, and
// the trust used to fetch for it is the one palm runs under.
tls_roots :: proc() -> ([]^x509.Certificate, string) {
	sync.mutex_lock(&g_roots_mutex)
	defer sync.mutex_unlock(&g_roots_mutex)
	if g_roots_loaded {
		return g_roots[:], g_roots_from
	}
	g_roots_loaded = true
	candidates := make([dynamic]string, context.temp_allocator)
	if v, found := os.lookup_env("PALM_CA_FILE", context.temp_allocator); found && v != "" {
		append(&candidates, v)
	} else {
		append(&candidates, ..CA_FILES[:])
	}
	for path in candidates {
		data, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			continue
		}
		rest := data
		for len(rest) > 0 {
			blk, remaining, perr := pem.decode(rest, context.allocator)
			if perr != nil || blk == nil {
				break
			}
			rest = remaining
			if blk.label != pem.LABEL_CERTIFICATE {
				continue
			}
			c := new(x509.Certificate)
			cerr: x509.Error
			c^, cerr = x509.parse(blk.data[:], context.allocator)
			if cerr == .None {
				append(&g_roots, c)
			}
		}
		if len(g_roots) > 0 {
			g_roots_from = strings.clone(path)
			break
		}
	}
	return g_roots[:], g_roots_from
}

// tls_reset_roots forgets the loaded bundle; the selftest switches
// PALM_CA_FILE between a test CA and none.
tls_reset_roots :: proc() {
	sync.mutex_lock(&g_roots_mutex)
	defer sync.mutex_unlock(&g_roots_mutex)
	g_roots_loaded = false
	clear(&g_roots)
	g_roots_from = ""
}

// ---------------------------------------------------------------------------
// Byte building and reading
// ---------------------------------------------------------------------------

@(private = "file")
b_u8 :: proc(b: ^[dynamic]byte, v: int) {append(b, byte(v))}
@(private = "file")
b_u16 :: proc(b: ^[dynamic]byte, v: int) {append(b, byte(v >> 8), byte(v))}
@(private = "file")
b_u24 :: proc(b: ^[dynamic]byte, v: int) {append(b, byte(v >> 16), byte(v >> 8), byte(v))}
@(private = "file")
b_open :: proc(b: ^[dynamic]byte, width: int) -> int {
	for _ in 0 ..< width {append(b, 0)}
	return len(b)
}
@(private = "file")
b_close :: proc(b: ^[dynamic]byte, at: int, width: int) {
	n := len(b) - at
	for i in 0 ..< width {
		b[at - width + i] = byte(n >> uint(8 * (width - 1 - i)))
	}
}

@(private = "file")
Rd :: struct {
	b:   []byte,
	bad: bool,
}
@(private = "file")
r_u8 :: proc(r: ^Rd) -> int {
	if len(r.b) < 1 {r.bad = true; return 0}
	v := int(r.b[0]); r.b = r.b[1:]
	return v
}
@(private = "file")
r_u16 :: proc(r: ^Rd) -> int {
	if len(r.b) < 2 {r.bad = true; return 0}
	v := int(r.b[0]) << 8 | int(r.b[1]); r.b = r.b[2:]
	return v
}
@(private = "file")
r_u24 :: proc(r: ^Rd) -> int {
	if len(r.b) < 3 {r.bad = true; return 0}
	v := int(r.b[0]) << 16 | int(r.b[1]) << 8 | int(r.b[2]); r.b = r.b[3:]
	return v
}
@(private = "file")
r_bytes :: proc(r: ^Rd, n: int) -> []byte {
	if n < 0 || len(r.b) < n {r.bad = true; return nil}
	v := r.b[:n]; r.b = r.b[n:]
	return v
}
@(private = "file")
r_vec :: proc(r: ^Rd, width: int) -> []byte {
	n := width == 1 ? r_u8(r) : (width == 2 ? r_u16(r) : r_u24(r))
	return r_bytes(r, n)
}

// ---------------------------------------------------------------------------
// Key schedule
// ---------------------------------------------------------------------------

@(private = "file")
expand_label :: proc(alg: hash.Algorithm, secret: []byte, label: string, ctx: []byte, out: []byte) {
	info := make([dynamic]byte, 0, 2 + 1 + 6 + len(label) + 1 + len(ctx), context.temp_allocator)
	b_u16(&info, len(out))
	b_u8(&info, 6 + len(label))
	append(&info, ..transmute([]byte)string("tls13 "))
	append(&info, ..transmute([]byte)label)
	b_u8(&info, len(ctx))
	append(&info, ..ctx)
	hkdf.expand(alg, secret, info[:], out)
}

@(private = "file")
transcript_hash :: proc(t: ^Tls) -> []byte {
	out := make([]byte, t.hash_len, context.temp_allocator)
	hash.final(&t.transcript, out, true)
	return out
}

@(private = "file")
empty_hash :: proc(t: ^Tls) -> []byte {
	out := make([]byte, t.hash_len, context.temp_allocator)
	hash.hash_bytes_to_buffer(t.hash_alg, nil, out)
	return out
}

@(private = "file")
set_keys :: proc(t: ^Tls, k: ^Tls_Keys, secret: []byte) {
	copy(k.secret[:], secret)
	key: [32]byte
	expand_label(t.hash_alg, secret, "key", nil, key[:t.key_len])
	expand_label(t.hash_alg, secret, "iv", nil, k.iv[:])
	aead.init(&k.ctx, t.aead_alg, key[:t.key_len])
	crypto.zero_explicit(&key, size_of(key))
	k.seq = 0
	k.on = true
}

@(private = "file")
next_secret :: proc(t: ^Tls, k: ^Tls_Keys) {
	n: [48]byte
	expand_label(t.hash_alg, k.secret[:t.hash_len], "traffic upd", nil, n[:t.hash_len])
	set_keys(t, k, n[:t.hash_len])
}

@(private = "file")
nonce :: proc(k: ^Tls_Keys) -> [12]byte {
	n := k.iv
	for i in 0 ..< 8 {
		n[4 + i] ~= byte(k.seq >> uint(56 - 8 * i))
	}
	return n
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

@(private = "file")
sock_send :: proc(t: ^Tls, data: []byte) -> Err {
	sent := 0
	for sent < len(data) {
		n, err := net.send_tcp(t.sock, data[sent:])
		if err != nil || n <= 0 {
			return fail(EXIT_UNAVAILABLE, "%s: send failed (%v)", t.host, err)
		}
		sent += n
	}
	return Err{}
}

@(private = "file")
write_record :: proc(t: ^Tls, ctype: u8, data: []byte) -> Err {
	rest := data
	for {
		chunk := rest[:min(len(rest), TLS_MAX_PLAIN)]
		rest = rest[len(chunk):]
		out := make([dynamic]byte, 0, 5 + len(chunk) + 1 + 16, context.temp_allocator)
		if !t.write.on {
			append(&out, ctype, 0x03, 0x03)
			b_u16(&out, len(chunk))
			append(&out, ..chunk)
		} else {
			inner := make([]byte, len(chunk) + 1, context.temp_allocator)
			copy(inner, chunk)
			inner[len(chunk)] = ctype
			append(&out, 23, 0x03, 0x03)
			b_u16(&out, len(inner) + 16)
			header := out[:5]
			ct := make([]byte, len(inner), context.temp_allocator)
			tag: [16]byte
			n := nonce(&t.write)
			aead.seal_ctx(&t.write.ctx, ct, tag[:], n[:], header, inner)
			t.write.seq += 1
			append(&out, ..ct)
			append(&out, ..tag[:])
		}
		if e := sock_send(t, out[:]); !ok(e) {
			return e
		}
		if len(rest) == 0 {
			return Err{}
		}
	}
}

// read_record returns the next record's type and plaintext (in t.rec, valid
// until the next call). eof is true when the peer closed the socket.
@(private = "file")
read_record :: proc(t: ^Tls) -> (ctype: u8, body: []byte, eof: bool, e: Err) {
	for {
		avail := t.raw[t.raw_off:]
		if len(avail) >= 5 {
			n := int(avail[3]) << 8 | int(avail[4])
			if n > TLS_MAX_CIPHER {
				return 0, nil, false, fail(EXIT_UNAVAILABLE, "%s: TLS record too large (%d)", t.host, n)
			}
			if len(avail) >= 5 + n {
				header := avail[:5]
				frag := avail[5:5 + n]
				t.raw_off += 5 + n
				ctype = header[0]
				clear(&t.rec)
				if ctype == 20 && !t.read.on || ctype == 20 && n == 1 {
					// change_cipher_spec, sent for middlebox compatibility
					continue
				}
				if !t.read.on {
					append(&t.rec, ..frag)
					return ctype, t.rec[:], false, Err{}
				}
				if ctype != 23 || n < 17 {
					return 0, nil, false, fail(EXIT_UNAVAILABLE, "%s: unexpected TLS record type %d", t.host, ctype)
				}
				resize(&t.rec, n - 16)
				nn := nonce(&t.read)
				if !aead.open_ctx(&t.read.ctx, t.rec[:], nn[:], header, frag[:n - 16], frag[n - 16:]) {
					return 0, nil, false, fail(EXIT_UNAVAILABLE, "%s: a TLS record failed authentication", t.host)
				}
				t.read.seq += 1
				end := len(t.rec)
				for end > 0 && t.rec[end - 1] == 0 {
					end -= 1
				}
				if end == 0 {
					return 0, nil, false, fail(EXIT_UNAVAILABLE, "%s: a TLS record has no content type", t.host)
				}
				return t.rec[end - 1], t.rec[:end - 1], false, Err{}
			}
		}
		// Need more bytes: compact, then read.
		if t.raw_off > 0 {
			rem := len(t.raw) - t.raw_off
			copy(t.raw[:rem], t.raw[t.raw_off:])
			resize(&t.raw, rem)
			t.raw_off = 0
		}
		buf: [32 * 1024]byte
		got, rerr := net.recv_tcp(t.sock, buf[:])
		if rerr != nil {
			return 0, nil, false, fail(EXIT_UNAVAILABLE, "%s: receive failed (%v)", t.host, rerr)
		}
		if got == 0 {
			return 0, nil, true, Err{}
		}
		append(&t.raw, ..buf[:got])
	}
}

@(private = "file")
alert_err :: proc(t: ^Tls, body: []byte) -> Err {
	desc := len(body) >= 2 ? int(body[1]) : -1
	why := ""
	switch desc {
	case 40:
		why = " (handshake_failure: the server speaks no TLS 1.3, or shares no cipher, group or signature algorithm with palm)"
	case 42, 43, 44, 45, 46:
		why = " (the server did not accept the certificate exchange)"
	case 70:
		why = " (protocol_version: the server does not speak TLS 1.3)"
	case 112:
		why = " (unrecognized_name: the server does not serve this host)"
	}
	return fail(EXIT_UNAVAILABLE, "%s: the server sent TLS alert %d%s", t.host, desc, why)
}

// next_handshake returns one whole handshake message (header included) and
// adds it to the transcript.
@(private = "file")
next_handshake :: proc(t: ^Tls, add_to_transcript := true) -> (typ: int, msg: []byte, e: Err) {
	for {
		if len(t.hs) >= 4 {
			n := int(t.hs[1]) << 16 | int(t.hs[2]) << 8 | int(t.hs[3])
			if n > 1 << 18 {
				return 0, nil, fail(EXIT_UNAVAILABLE, "%s: TLS handshake message too large", t.host)
			}
			if len(t.hs) >= 4 + n {
				msg = make([]byte, 4 + n, context.temp_allocator)
				copy(msg, t.hs[:4 + n])
				remove_range(&t.hs, 0, 4 + n)
				if add_to_transcript {
					hash.update(&t.transcript, msg)
				}
				return int(msg[0]), msg, Err{}
			}
		}
		ctype, body, eof, re := read_record(t)
		if !ok(re) {
			return 0, nil, re
		}
		if eof {
			return 0, nil, fail(EXIT_UNAVAILABLE, "%s: the connection closed during the TLS handshake", t.host)
		}
		switch ctype {
		case 22:
			append(&t.hs, ..body)
		case 21:
			return 0, nil, alert_err(t, body)
		case:
			return 0, nil, fail(EXIT_UNAVAILABLE, "%s: unexpected TLS record %d during the handshake", t.host, ctype)
		}
	}
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

@(private = "file")
is_ip_literal :: proc(host: string) -> bool {
	if strings.contains_rune(host, ':') {
		return true
	}
	for c in transmute([]byte)host {
		if !(c >= '0' && c <= '9' || c == '.') {
			return false
		}
	}
	return true
}

tls_connect :: proc(sock: net.TCP_Socket, host: string) -> (^Tls, Err) {
	t := new(Tls)
	t.sock = sock
	t.host = strings.clone(host)
	roots, _ := tls_roots()
	if len(roots) == 0 {
		return t, fail(EXIT_UNAVAILABLE, "%s: no CA certificates to check the server against (looked in %s)", host, strings.join(CA_FILES[:], ", ", context.temp_allocator))
	}
	if !crypto.HAS_RAND_BYTES {
		return t, fail(EXIT_FAILED, "no system entropy source")
	}

	// Two key shares, so no HelloRetryRequest is ever needed.
	x_priv, p_priv: ecdh.Private_Key
	if !ecdh.private_key_generate(&x_priv, .X25519) || !ecdh.private_key_generate(&p_priv, .SECP256R1) {
		return t, fail(EXIT_FAILED, "cannot generate a TLS key share")
	}
	defer ecdh.private_key_clear(&x_priv)
	defer ecdh.private_key_clear(&p_priv)
	x_pub: [32]byte
	p_pub: [65]byte
	ecdh.private_key_public_bytes(&x_priv, x_pub[:])
	ecdh.private_key_public_bytes(&p_priv, p_pub[:])

	ch := make([dynamic]byte, context.temp_allocator)
	b_u8(&ch, 1) // client_hello
	body := b_open(&ch, 3)
	b_u16(&ch, 0x0303)
	random: [32]byte
	crypto.rand_bytes(random[:])
	append(&ch, ..random[:])
	session: [32]byte
	crypto.rand_bytes(session[:])
	b_u8(&ch, 32)
	append(&ch, ..session[:])
	b_u16(&ch, 6)
	b_u16(&ch, 0x1301)
	b_u16(&ch, 0x1303)
	b_u16(&ch, 0x1302)
	b_u8(&ch, 1)
	b_u8(&ch, 0) // no compression
	exts := b_open(&ch, 2)
	if !is_ip_literal(host) {
		b_u16(&ch, 0x0000) // server_name
		e := b_open(&ch, 2)
		l := b_open(&ch, 2)
		b_u8(&ch, 0)
		b_u16(&ch, len(host))
		append(&ch, ..transmute([]byte)host)
		b_close(&ch, l, 2)
		b_close(&ch, e, 2)
	}
	{
		b_u16(&ch, 0x000a) // supported_groups
		e := b_open(&ch, 2)
		l := b_open(&ch, 2)
		b_u16(&ch, 0x001d) // x25519
		b_u16(&ch, 0x0017) // secp256r1
		b_close(&ch, l, 2)
		b_close(&ch, e, 2)
	}
	{
		b_u16(&ch, 0x000d) // signature_algorithms; the pkcs1 ones are for certificates only
		e := b_open(&ch, 2)
		l := b_open(&ch, 2)
		for alg in ([?]int{0x0403, 0x0503, 0x0804, 0x0805, 0x0806, 0x0807, 0x0401, 0x0501, 0x0601}) {
			b_u16(&ch, alg)
		}
		b_close(&ch, l, 2)
		b_close(&ch, e, 2)
	}
	{
		b_u16(&ch, 0x0010) // application_layer_protocol_negotiation
		e := b_open(&ch, 2)
		l := b_open(&ch, 2)
		b_u8(&ch, 8)
		append(&ch, ..transmute([]byte)string("http/1.1"))
		b_close(&ch, l, 2)
		b_close(&ch, e, 2)
	}
	{
		b_u16(&ch, 0x002b) // supported_versions
		e := b_open(&ch, 2)
		b_u8(&ch, 2)
		b_u16(&ch, 0x0304)
		b_close(&ch, e, 2)
	}
	{
		b_u16(&ch, 0x0033) // key_share
		e := b_open(&ch, 2)
		l := b_open(&ch, 2)
		b_u16(&ch, 0x001d)
		b_u16(&ch, len(x_pub))
		append(&ch, ..x_pub[:])
		b_u16(&ch, 0x0017)
		b_u16(&ch, len(p_pub))
		append(&ch, ..p_pub[:])
		b_close(&ch, l, 2)
		b_close(&ch, e, 2)
	}
	b_close(&ch, exts, 2)
	b_close(&ch, body, 3)

	{
		rec := make([dynamic]byte, context.temp_allocator)
		append(&rec, 22, 0x03, 0x01)
		b_u16(&rec, len(ch))
		append(&rec, ..ch[:])
		if e := sock_send(t, rec[:]); !ok(e) {
			return t, e
		}
	}

	// ServerHello
	typ, sh, e := next_handshake(t, false)
	if !ok(e) {
		return t, e
	}
	if typ != 2 {
		return t, fail(EXIT_UNAVAILABLE, "%s: expected ServerHello, got handshake message %d", host, typ)
	}
	r := Rd{b = sh[4:]}
	_ = r_u16(&r)
	srandom := r_bytes(&r, 32)
	_ = r_vec(&r, 1)
	suite := r_u16(&r)
	_ = r_u8(&r)
	sexts := Rd{b = r_vec(&r, 2)}
	if r.bad {
		return t, fail(EXIT_UNAVAILABLE, "%s: malformed ServerHello", host)
	}
	if string(srandom) == string(HRR_RANDOM[:]) {
		return t, fail(EXIT_UNAVAILABLE, "%s: the server asked for a key exchange palm does not offer (HelloRetryRequest)", host)
	}
	version := 0
	group := 0
	server_key: []byte
	for len(sexts.b) > 0 && !sexts.bad {
		et := r_u16(&sexts)
		ed := Rd{b = r_vec(&sexts, 2)}
		switch et {
		case 0x002b:
			version = r_u16(&ed)
		case 0x0033:
			group = r_u16(&ed)
			server_key = r_vec(&ed, 2)
		}
	}
	if version != 0x0304 {
		return t, fail(EXIT_UNAVAILABLE, "%s: the server does not speak TLS 1.3, which is all palm speaks", host)
	}
	switch suite {
	case 0x1301:
		t.hash_alg, t.hash_len, t.aead_alg, t.key_len = .SHA256, 32, .AES_GCM_128, 16
	case 0x1302:
		t.hash_alg, t.hash_len, t.aead_alg, t.key_len = .SHA384, 48, .AES_GCM_256, 32
	case 0x1303:
		t.hash_alg, t.hash_len, t.aead_alg, t.key_len = .SHA256, 32, .CHACHA20POLY1305, 32
	case:
		return t, fail(EXIT_UNAVAILABLE, "%s: the server chose cipher suite %04x, which palm did not offer", host, suite)
	}
	hash.init(&t.transcript, t.hash_alg)
	hash.update(&t.transcript, ch[:])
	hash.update(&t.transcript, sh)

	shared: [32]byte
	{
		peer: ecdh.Public_Key
		okk := false
		switch group {
		case 0x001d:
			okk = ecdh.public_key_set_bytes(&peer, .X25519, server_key) && ecdh.ecdh(&x_priv, &peer, shared[:])
		case 0x0017:
			okk = ecdh.public_key_set_bytes(&peer, .SECP256R1, server_key) && ecdh.ecdh(&p_priv, &peer, shared[:])
		case:
			return t, fail(EXIT_UNAVAILABLE, "%s: the server chose key exchange group %04x, which palm did not offer", host, group)
		}
		if !okk {
			return t, fail(EXIT_UNAVAILABLE, "%s: the server's key share is invalid", host)
		}
	}
	defer crypto.zero_explicit(&shared, size_of(shared))

	// Key schedule, RFC 8446 7.1.
	hl := t.hash_len
	zeros: [48]byte
	early: [48]byte
	hkdf.extract(t.hash_alg, zeros[:hl], zeros[:hl], early[:hl])
	derived: [48]byte
	expand_label(t.hash_alg, early[:hl], "derived", empty_hash(t), derived[:hl])
	hs_secret: [48]byte
	hkdf.extract(t.hash_alg, derived[:hl], shared[:], hs_secret[:hl])
	th := transcript_hash(t)
	c_hs, s_hs: [48]byte
	expand_label(t.hash_alg, hs_secret[:hl], "c hs traffic", th, c_hs[:hl])
	expand_label(t.hash_alg, hs_secret[:hl], "s hs traffic", th, s_hs[:hl])
	set_keys(t, &t.read, s_hs[:hl])

	// EncryptedExtensions, Certificate, CertificateVerify, Finished.
	typ, _, e = next_handshake(t)
	if !ok(e) {return t, e}
	if typ != 8 {
		return t, fail(EXIT_UNAVAILABLE, "%s: expected EncryptedExtensions, got %d", host, typ)
	}
	msg: []byte
	typ, msg, e = next_handshake(t)
	if !ok(e) {return t, e}
	if typ == 13 {
		return t, fail(EXIT_UNAVAILABLE, "%s: the server wants a client certificate", host)
	}
	if typ != 11 {
		return t, fail(EXIT_UNAVAILABLE, "%s: expected Certificate, got %d", host, typ)
	}
	certs := make([dynamic]^x509.Certificate, context.temp_allocator)
	{
		cr := Rd{b = msg[4:]}
		_ = r_vec(&cr, 1)
		list := Rd{b = r_vec(&cr, 3)}
		for len(list.b) > 0 && !list.bad {
			der := r_vec(&list, 3)
			_ = r_vec(&list, 2)
			if list.bad {break}
			c := new(x509.Certificate, context.temp_allocator)
			perr: x509.Error
			// The DER lives in msg, which is temp-allocated like c.
			c^, perr = x509.parse(der, context.temp_allocator)
			if perr != .None {
				return t, fail(EXIT_UNAVAILABLE, "%s: the server's certificate does not parse (%v)", host, perr)
			}
			append(&certs, c)
		}
		if cr.bad || list.bad || len(certs) == 0 {
			return t, fail(EXIT_UNAVAILABLE, "%s: malformed Certificate message", host)
		}
	}
	leaf := certs[0]
	{
		opts := x509.Verify_Options {
			roots         = roots,
			intermediates = certs[1:],
			current_time  = time.now(),
			required_eku  = x509.EKU_Bit.Server_Auth,
		}
		if !is_ip_literal(host) {
			opts.dns_name = host
		}
		_, verr := x509.verify_chain(leaf, opts, context.temp_allocator)
		if verr != .None {
			return t, fail(EXIT_UNAVAILABLE, "%s: the server's certificate is not trusted (%v)", host, verr)
		}
		if is_ip_literal(host) && !ip_matches(leaf, host) {
			return t, fail(EXIT_UNAVAILABLE, "%s: the server's certificate is not for this address", host)
		}
	}
	th = transcript_hash(t)
	typ, msg, e = next_handshake(t)
	if !ok(e) {return t, e}
	if typ != 15 {
		return t, fail(EXIT_UNAVAILABLE, "%s: expected CertificateVerify, got %d", host, typ)
	}
	{
		vr := Rd{b = msg[4:]}
		alg := r_u16(&vr)
		sig := r_vec(&vr, 2)
		if vr.bad {
			return t, fail(EXIT_UNAVAILABLE, "%s: malformed CertificateVerify", host)
		}
		signed := make([dynamic]byte, context.temp_allocator)
		for _ in 0 ..< 64 {append(&signed, 0x20)}
		append(&signed, ..transmute([]byte)string("TLS 1.3, server CertificateVerify"))
		append(&signed, 0)
		append(&signed, ..th)
		if !verify_cert_signature(leaf, alg, signed[:], sig) {
			return t, fail(EXIT_UNAVAILABLE, "%s: the server's CertificateVerify signature (scheme %04x) does not verify", host, alg)
		}
	}
	th = transcript_hash(t)
	typ, msg, e = next_handshake(t)
	if !ok(e) {return t, e}
	if typ != 20 {
		return t, fail(EXIT_UNAVAILABLE, "%s: expected Finished, got %d", host, typ)
	}
	{
		fk: [48]byte
		expand_label(t.hash_alg, s_hs[:hl], "finished", nil, fk[:hl])
		want: [48]byte
		hmac.sum(t.hash_alg, want[:hl], th, fk[:hl])
		if len(msg) - 4 != hl || crypto.compare_constant_time(want[:hl], msg[4:]) != 1 {
			return t, fail(EXIT_UNAVAILABLE, "%s: the server's Finished does not verify", host)
		}
	}
	th = transcript_hash(t) // through the server's Finished

	// Application secrets.
	expand_label(t.hash_alg, hs_secret[:hl], "derived", empty_hash(t), derived[:hl])
	master: [48]byte
	hkdf.extract(t.hash_alg, derived[:hl], zeros[:hl], master[:hl])
	c_ap, s_ap: [48]byte
	expand_label(t.hash_alg, master[:hl], "c ap traffic", th, c_ap[:hl])
	expand_label(t.hash_alg, master[:hl], "s ap traffic", th, s_ap[:hl])

	// Our Finished, under the client handshake keys (after a compatibility
	// change_cipher_spec, which middleboxes expect when a session id is sent).
	if e = sock_send(t, {20, 0x03, 0x03, 0x00, 0x01, 0x01}); !ok(e) {
		return t, e
	}
	set_keys(t, &t.write, c_hs[:hl])
	{
		fk: [48]byte
		expand_label(t.hash_alg, c_hs[:hl], "finished", nil, fk[:hl])
		vd: [48]byte
		hmac.sum(t.hash_alg, vd[:hl], th, fk[:hl])
		fin := make([dynamic]byte, context.temp_allocator)
		b_u8(&fin, 20)
		b_u24(&fin, hl)
		append(&fin, ..vd[:hl])
		if e = write_record(t, 22, fin[:]); !ok(e) {
			return t, e
		}
	}
	set_keys(t, &t.write, c_ap[:hl])
	set_keys(t, &t.read, s_ap[:hl])
	for s in ([?]^[48]byte{&early, &hs_secret, &c_hs, &s_hs, &master, &c_ap, &s_ap}) {
		crypto.zero_explicit(s, size_of(s^))
	}
	return t, Err{}
}

@(private = "file")
ip_matches :: proc(c: ^x509.Certificate, host: string) -> bool {
	addr := net.parse_address(host)
	if addr == nil {
		return false
	}
	want: []byte
	switch a in addr {
	case net.IP4_Address:
		v := a
		want = make([]byte, 4, context.temp_allocator)
		copy(want, v[:])
	case net.IP6_Address:
		v := transmute([16]byte)a
		want = make([]byte, 16, context.temp_allocator)
		copy(want, v[:])
	}
	for ip in c.ip_addresses {
		if string(ip) == string(want) {
			return true
		}
	}
	return false
}

@(private = "file")
verify_cert_signature :: proc(leaf: ^x509.Certificate, alg: int, msg, sig: []byte) -> bool {
	switch alg {
	case 0x0403, 0x0503:
		curve: ecdsa.Curve = alg == 0x0403 ? .SECP256R1 : .SECP384R1
		h: hash.Algorithm = alg == 0x0403 ? .SHA256 : .SHA384
		want: x509.Public_Key_Algorithm = alg == 0x0403 ? .ECDSA_P256 : .ECDSA_P384
		if leaf.public_key_algorithm != want {
			return false
		}
		pub: ecdsa.Public_Key
		if !ecdsa.public_key_set_bytes(&pub, curve, leaf.ec_point) {
			return false
		}
		return ecdsa.verify_asn1(&pub, h, msg, sig)
	case 0x0804, 0x0805, 0x0806:
		if leaf.public_key_algorithm != .RSA {
			return false
		}
		h: hash.Algorithm = alg == 0x0804 ? .SHA256 : (alg == 0x0805 ? .SHA384 : .SHA512)
		salt := alg == 0x0804 ? 32 : (alg == 0x0805 ? 48 : 64)
		pub: rsa.Public_Key
		if !rsa.public_key_set_bytes(&pub, leaf.rsa_n, leaf.rsa_e) {
			return false
		}
		return rsa.verify_pss(&pub, h, salt, msg, sig)
	case 0x0807:
		if leaf.public_key_algorithm != .Ed25519 {
			return false
		}
		pub: ed25519.Public_Key
		if !ed25519.public_key_set_bytes(&pub, leaf.ec_point) {
			return false
		}
		return ed25519.verify(&pub, msg, sig)
	}
	return false
}

// ---------------------------------------------------------------------------
// After the handshake
// ---------------------------------------------------------------------------

// tls_read returns application data; 0 means the peer closed.
tls_read :: proc(t: ^Tls, buf: []byte) -> (int, Err) {
	for {
		if t.app_off < len(t.app) {
			n := copy(buf, t.app[t.app_off:])
			t.app_off += n
			if t.app_off == len(t.app) {
				clear(&t.app)
				t.app_off = 0
			}
			return n, Err{}
		}
		if t.closed {
			return 0, Err{}
		}
		ctype, body, eof, e := read_record(t)
		if !ok(e) {
			return 0, e
		}
		if eof {
			t.closed = true
			return 0, Err{}
		}
		switch ctype {
		case 23:
			append(&t.app, ..body)
		case 21:
			if len(body) >= 2 && body[1] == 0 {
				t.closed = true // close_notify
				return 0, Err{}
			}
			return 0, alert_err(t, body)
		case 22:
			append(&t.hs, ..body)
			for len(t.hs) >= 4 {
				n := int(t.hs[1]) << 16 | int(t.hs[2]) << 8 | int(t.hs[3])
				if len(t.hs) < 4 + n {break}
				typ := t.hs[0]
				req := n >= 1 ? t.hs[4] : 0
				remove_range(&t.hs, 0, 4 + n)
				switch typ {
				case 4: // NewSessionTicket: no resumption, nothing to keep
				case 24: // KeyUpdate
					next_secret(t, &t.read)
					if req == 1 {
						if we := write_record(t, 22, {24, 0, 0, 1, 0}); !ok(we) {
							return 0, we
						}
						next_secret(t, &t.write)
					}
				case:
					return 0, fail(EXIT_UNAVAILABLE, "%s: unexpected post-handshake message %d", t.host, typ)
				}
			}
		case:
			return 0, fail(EXIT_UNAVAILABLE, "%s: unexpected TLS record type %d", t.host, ctype)
		}
	}
}

tls_write :: proc(t: ^Tls, data: []byte) -> Err {
	return write_record(t, 23, data)
}

// tls_close sends close_notify and forgets the keys; the caller closes the
// socket.
tls_close :: proc(t: ^Tls) {
	if t.write.on {
		_ = write_record(t, 21, {1, 0})
	}
	aead.reset(&t.read.ctx)
	aead.reset(&t.write.ctx)
	crypto.zero_explicit(&t.read.secret, size_of(t.read.secret))
	crypto.zero_explicit(&t.write.secret, size_of(t.write.secret))
	delete(t.raw)
	delete(t.rec)
	delete(t.hs)
	delete(t.app)
	hash.reset(&t.transcript)
	free(t)
}

_ :: fmt
_ :: strconv
