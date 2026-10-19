package main

// The account vault: identity vaults kept on the Palmframe cloud, end to end
// encrypted, usable offline.
//
// Three layers, each knowing only the one below:
//
//   the window and the CLI  ─  Vault.entries, the same Entry the local file uses
//   this file               ─  the local cache, the keys, decrypting rows into
//                              entries and encrypting edits into pending rows
//   sync.odin               ─  moving rows to and from the server (cloudkit)
//
// The cache on disk (account/cache.json) holds exactly what the server holds
// -- ciphertext, ids, revisions -- plus this device's not-yet-pushed edits,
// which are ciphertext too. Nothing in it opens without the master password
// and the Secret Key, so an edit made offline is as safe on this disk as it
// will be on the server. The Secret Key itself is in account/device.json,
// 0600, next to the cache: it protects the server copy from the server, not
// this disk from a thief (SECURITY.md, "The Secret Key").

import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"

// ---------------------------------------------------------------------------
// Rows, as the server has them
// ---------------------------------------------------------------------------

K_Row :: struct {
	identity_id:      string,
	enc_pub:          string,
	kem_pub:          string,
	sign_pub:         string,
	kdf_salt:         string,
	kdf:              Kdf,
	account_key_wrap: string,
	private_wrap:     string,
	key_epoch:        int,
}

V_Row :: struct {
	id:          string,
	identity_id: string,
	key_wrap:    string,
	key_version: int,
	meta:        string,
	revision:    i64,
}

I_Row :: struct {
	id:          string,
	identity_id: string,
	vault_id:    string,
	revision:    i64,
	key_version: int,
	key_wrap:    string,
	blob:        string,
	deleted:     bool,
}

S_Row :: struct {
	id:          string,
	identity_id: string, // the source
	vault_id:    string,
	item_id:     string, // "" for a whole-vault share
	grantee:     string,
	role:        string,
	key_version: int,
	wrapped_key: string,
	signature:   string,
	revoked:     bool,
}

D_Row :: struct {
	id:            string,
	identity_id:   string,
	name:          string,
	pub:           string,
	sealed_secret: string,
	approved:      bool,
	revoked:       bool,
}

Ident :: struct {
	id:     string,
	handle: string,
	name:   string,
	kind:   string,
	color:  string,
}

// A foreign identity's public keys as first seen (trust on first use). A
// share from it whose signature does not verify against the pinned key, or a
// lookup that returns a different key later, is refused and reported.
Pin :: struct {
	identity_id: string,
	handle:      string,
	name:        string,
	enc_pub:     string,
	kem_pub:     string,
	sign_pub:    string,
}

// An edit not yet on the server: the row as it will be written, and the
// revision it was made against.
Pending :: struct {
	row:  I_Row,
	base: i64,
}

Cache :: struct {
	user_id:   string,
	email:     string,
	scope:     string, // the identity handle this device's session is scoped to, "" for the person
	idents:    [dynamic]Ident,
	keysets:   [dynamic]K_Row,
	vaults:    [dynamic]V_Row,
	items:     [dynamic]I_Row,
	shares:    [dynamic]S_Row,
	devices:   [dynamic]D_Row,
	pins:      [dynamic]Pin,
	pending:   [dynamic]Pending,
	synced_at: i64,
}

// ---------------------------------------------------------------------------
// What the person sees: sources
// ---------------------------------------------------------------------------

Src_Kind :: enum u8 {
	Own, // a vault the viewing identity owns
	Shared_Vault, // a whole vault shared with the viewing identity
	Shared_Items, // single items shared with the viewing identity
}

Source :: struct {
	kind:         Src_Kind,
	viewer:       string, // identity id this source is seen as
	owner:        string, // identity id that owns the vault
	vault_id:     string, // "" for Shared_Items
	name:         string,
	color:        string,
	role:         string, // owner | write | read
	owner_handle: string,
	owner_name:   string,
}

// Keys this device has opened, by what they open.
Vkey :: struct {
	vault_id: string,
	version:  int,
	kid:      [KEYID_LEN]byte,
	key:      [KEY_LEN]byte,
	via:      string, // "" when owned; the share id otherwise
	viewer:   string, // the identity that holds it
	role:     string, // owner | write | read
}

Ikey :: struct {
	item_id:  string,
	kid:      [KEYID_LEN]byte,
	key:      [KEY_LEN]byte,
	share_id: string, // "" when unwrapped from the vault
	viewer:   string,
}

Idkeys :: struct {
	identity_id: string,
	keys:        Identity_Keys,
}

// Where an entry in Vault.entries came from, so an edit goes back to the same
// row under the same key.
Origin :: struct {
	item_id:  string,
	vault_id: string,
	owner:    string,
	src:      int,
	revision: i64,
}

Acct :: struct {
	dir:          string, // $DATA/palmy-vault/account
	arena:        virtual.Arena, // every string in `cache`; rebuilt from JSON after each sync
	varena:       virtual.Arena, // strings in vkeys and ikeys; reset when they are reopened
	sarena:       virtual.Arena, // strings in sources and origins; reset when entries are rebuilt
	cache:        Cache,
	have_cache:   bool,

	// device.json
	secret:       [SECRET_LEN]byte,
	has_secret:   bool,
	device_priv:  [32]byte, // X25519, for being approved by another device
	has_device:   bool,
	device_ids:   map[string]string, // identity id -> vault_devices.id

	// Unlocked
	unlocked:     bool,
	account_key:  [KEY_LEN]byte,
	idkeys:       [dynamic]Idkeys,
	vkeys:        [dynamic]Vkey,
	ikeys:        [dynamic]Ikey,
	sources:      [dynamic]Source,
	origins:      [dynamic]Origin, // parallel to the entries handed out
	problems:     [dynamic]string, // shares refused, keys that did not open

	client:       ^ck.Client, // nil when offline or signed out
}

// ---------------------------------------------------------------------------
// Paths
// ---------------------------------------------------------------------------

account_dir :: proc(allocator := context.temp_allocator) -> string {
	if d := os.get_env("PALM_VAULT_ACCOUNT_DIR", context.temp_allocator); d != "" {
		return strings.clone(d, allocator)
	}
	return fmt.aprintf("%s/account", data_dir(context.temp_allocator), allocator = allocator)
}

acct_open :: proc(dir := "") -> ^Acct {
	a := new(Acct)
	a.dir = strings.clone(dir != "" ? dir : account_dir(context.temp_allocator))
	_ = virtual.arena_init_growing(&a.arena)
	_ = virtual.arena_init_growing(&a.varena)
	_ = virtual.arena_init_growing(&a.sarena)
	a.device_ids = make(map[string]string)
	acct_load(a)
	return a
}

acct_close :: proc(a: ^Acct) {
	if a == nil {
		return
	}
	acct_lock(a)
	crypto.zero_explicit(&a.secret, size_of(a.secret))
	crypto.zero_explicit(&a.device_priv, size_of(a.device_priv))
	for k, v in a.device_ids {
		delete(k)
		delete(v)
	}
	delete(a.device_ids)
	virtual.arena_destroy(&a.arena)
	virtual.arena_destroy(&a.varena)
	virtual.arena_destroy(&a.sarena)
	delete(a.idkeys)
	delete(a.vkeys)
	delete(a.ikeys)
	delete(a.sources)
	delete(a.origins)
	for p in a.problems {
		delete(p)
	}
	delete(a.problems)
	if a.client != nil {
		ck.close(a.client)
	}
	delete(a.dir)
	free(a)
}

// A string that lives as long as the cache does.
cs :: proc(a: ^Acct, s: string) -> string {
	return strings.clone(s, virtual.arena_allocator(&a.arena))
}

// ... as long as the opened keys do.
vs :: proc(a: ^Acct, s: string) -> string {
	return strings.clone(s, virtual.arena_allocator(&a.varena))
}

// ... as long as the current list of entries does.
ss :: proc(a: ^Acct, s: string) -> string {
	return strings.clone(s, virtual.arena_allocator(&a.sarena))
}

// ---------------------------------------------------------------------------
// device.json
// ---------------------------------------------------------------------------

acct_set_up :: proc(a: ^Acct) -> bool {
	return a.has_secret && a.have_cache && len(a.cache.keysets) > 0
}

device_path :: proc(a: ^Acct) -> string {
	return fmt.tprintf("%s/device.json", a.dir)
}

cache_path :: proc(a: ^Acct) -> string {
	return fmt.tprintf("%s/cache.json", a.dir)
}

device_save :: proc(a: ^Acct) -> string {
	if err := os.make_directory_all(a.dir, os.perm(0o700)); err != nil && !os.exists(a.dir) {
		return fmt.tprintf("could not create %s", a.dir)
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{\n")
	if a.has_secret {
		s := secret_format(a.secret[:], context.temp_allocator)
		fmt.sbprintf(&sb, "  \"secret_key\": %s,\n", ck.quote(s))
	}
	if a.has_device {
		fmt.sbprintf(&sb, "  \"device_key\": %s,\n", ck.quote(b64(a.device_priv[:], context.temp_allocator)))
	}
	strings.write_string(&sb, "  \"devices\": {")
	n := 0
	for k, v in a.device_ids {
		fmt.sbprintf(&sb, "%s%s: %s", n > 0 ? ", " : "", ck.quote(k), ck.quote(v))
		n += 1
	}
	strings.write_string(&sb, "}\n}\n")
	text := strings.to_string(sb)
	err := write_atomic(device_path(a), transmute([]byte)text)
	crypto.zero_explicit(raw_data(text), len(text))
	return err
}

device_load :: proc(a: ^Acct) {
	raw, rerr := os.read_entire_file(device_path(a), context.temp_allocator)
	if rerr != nil {
		return
	}
	defer crypto.zero_explicit(raw_data(raw), len(raw))
	v, ok := ck.parse(string(raw), context.temp_allocator)
	if !ok {
		return
	}
	if s := ck.get_str(v, "secret_key"); s != "" {
		if sec, good := secret_parse(s); good {
			a.secret = sec
			a.has_secret = true
		}
	}
	if s := ck.get_str(v, "device_key"); s != "" {
		if d, good := unb64(s, context.temp_allocator); good && len(d) == 32 {
			copy(a.device_priv[:], d)
			a.has_device = true
		}
	}
	#partial switch m in ck.get(v, "devices") {
	case json.Object:
		for k, val in m {
			if s, is := val.(json.String); is {
				a.device_ids[strings.clone(k)] = strings.clone(string(s))
			}
		}
	}
}

// ---------------------------------------------------------------------------
// cache.json
// ---------------------------------------------------------------------------

acct_load :: proc(a: ^Acct) {
	device_load(a)
	raw, rerr := os.read_entire_file(cache_path(a), context.temp_allocator)
	if rerr != nil {
		return
	}
	cache_from_json(a, string(raw))
}

cache_reset :: proc(a: ^Acct) {
	virtual.arena_destroy(&a.arena)
	_ = virtual.arena_init_growing(&a.arena)
	al := virtual.arena_allocator(&a.arena)
	a.cache = Cache {
		idents  = make([dynamic]Ident, al),
		keysets = make([dynamic]K_Row, al),
		vaults  = make([dynamic]V_Row, al),
		items   = make([dynamic]I_Row, al),
		shares  = make([dynamic]S_Row, al),
		devices = make([dynamic]D_Row, al),
		pins    = make([dynamic]Pin, al),
		pending = make([dynamic]Pending, al),
	}
}

@(private = "file")
js :: proc(v: ck.Value, k: string) -> string {
	return ck.get_str(v, k)
}

k_from :: proc(a: ^Acct, v: ck.Value) -> K_Row {
	return K_Row {
		identity_id = cs(a, js(v, "identity_id")),
		enc_pub = cs(a, js(v, "enc_pub")),
		kem_pub = cs(a, js(v, "kem_pub")),
		sign_pub = cs(a, js(v, "sign_pub")),
		kdf_salt = cs(a, js(v, "kdf_salt")),
		kdf = Kdf{m = u32(ck.get_int(v, "kdf_m")), t = u32(ck.get_int(v, "kdf_t")), par = u32(ck.get_int(v, "kdf_p"))},
		account_key_wrap = cs(a, js(v, "account_key_wrap")),
		private_wrap = cs(a, js(v, "private_wrap")),
		key_epoch = int(ck.get_int(v, "key_epoch")),
	}
}

v_from :: proc(a: ^Acct, v: ck.Value) -> V_Row {
	return V_Row {
		id = cs(a, js(v, "id")),
		identity_id = cs(a, js(v, "identity_id")),
		key_wrap = cs(a, js(v, "key_wrap")),
		key_version = int(ck.get_int(v, "key_version")),
		meta = cs(a, js(v, "meta")),
		revision = ck.get_int(v, "revision"),
	}
}

i_from :: proc(a: ^Acct, v: ck.Value) -> I_Row {
	return I_Row {
		id = cs(a, js(v, "id")),
		identity_id = cs(a, js(v, "identity_id")),
		vault_id = cs(a, js(v, "vault_id")),
		revision = ck.get_int(v, "revision"),
		key_version = int(ck.get_int(v, "key_version")),
		key_wrap = cs(a, js(v, "key_wrap")),
		blob = cs(a, js(v, "blob")),
		deleted = ck.get_bool(v, "deleted"),
	}
}

s_from :: proc(a: ^Acct, v: ck.Value) -> S_Row {
	return S_Row {
		id = cs(a, js(v, "id")),
		identity_id = cs(a, js(v, "identity_id")),
		vault_id = cs(a, js(v, "vault_id")),
		item_id = cs(a, js(v, "item_id")),
		grantee = cs(a, js(v, "grantee_identity")),
		role = cs(a, js(v, "role")),
		key_version = int(ck.get_int(v, "key_version")),
		wrapped_key = cs(a, js(v, "wrapped_key")),
		signature = cs(a, js(v, "signature")),
		revoked = !ck.is_null(v, "revoked_at") || ck.get_bool(v, "revoked"),
	}
}

d_from :: proc(a: ^Acct, v: ck.Value) -> D_Row {
	return D_Row {
		id = cs(a, js(v, "id")),
		identity_id = cs(a, js(v, "identity_id")),
		name = cs(a, js(v, "name")),
		pub = cs(a, js(v, "pub")),
		sealed_secret = cs(a, js(v, "sealed_secret")),
		approved = !ck.is_null(v, "approved_at") || ck.get_bool(v, "approved"),
		revoked = !ck.is_null(v, "revoked_at") || ck.get_bool(v, "revoked"),
	}
}

cache_from_json :: proc(a: ^Acct, text: string) {
	v, ok := ck.parse(text, context.temp_allocator)
	if !ok {
		return
	}
	cache_reset(a)
	c := &a.cache
	c.user_id = cs(a, js(v, "user_id"))
	c.email = cs(a, js(v, "email"))
	c.scope = cs(a, js(v, "scope"))
	c.synced_at = ck.get_int(v, "synced_at")
	for r in ck.array(ck.get(v, "identities")) {
		append(&c.idents, Ident{cs(a, js(r, "id")), cs(a, js(r, "handle")), cs(a, js(r, "name")), cs(a, js(r, "kind")), cs(a, js(r, "color"))})
	}
	for r in ck.array(ck.get(v, "keysets")) {
		append(&c.keysets, k_from(a, r))
	}
	for r in ck.array(ck.get(v, "vaults")) {
		append(&c.vaults, v_from(a, r))
	}
	for r in ck.array(ck.get(v, "items")) {
		append(&c.items, i_from(a, r))
	}
	for r in ck.array(ck.get(v, "shares")) {
		append(&c.shares, s_from(a, r))
	}
	for r in ck.array(ck.get(v, "devices")) {
		append(&c.devices, d_from(a, r))
	}
	for r in ck.array(ck.get(v, "pins")) {
		append(&c.pins, Pin{cs(a, js(r, "identity_id")), cs(a, js(r, "handle")), cs(a, js(r, "name")),
			cs(a, js(r, "enc_pub")), cs(a, js(r, "kem_pub")), cs(a, js(r, "sign_pub"))})
	}
	for r in ck.array(ck.get(v, "pending")) {
		append(&c.pending, Pending{row = i_from(a, ck.get(r, "row")), base = ck.get_int(r, "base")})
	}
	a.have_cache = true
}

@(private = "file")
q :: proc(s: string) -> string {
	return ck.quote(s, context.temp_allocator)
}

i_json :: proc(sb: ^strings.Builder, r: I_Row) {
	fmt.sbprintf(sb, "{{\"id\":%s,\"identity_id\":%s,\"vault_id\":%s,\"revision\":%d,\"key_version\":%d,\"key_wrap\":%s,\"blob\":%s,\"deleted\":%v}}",
		q(r.id), q(r.identity_id), q(r.vault_id), r.revision, r.key_version, q(r.key_wrap), q(r.blob), r.deleted)
}

cache_save :: proc(a: ^Acct) -> string {
	if err := os.make_directory_all(a.dir, os.perm(0o700)); err != nil && !os.exists(a.dir) {
		return fmt.tprintf("could not create %s", a.dir)
	}
	c := &a.cache
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "{{\"format\":1,\"user_id\":%s,\"email\":%s,\"scope\":%s,\"synced_at\":%d,\n", q(c.user_id), q(c.email), q(c.scope), c.synced_at)
	strings.write_string(&sb, "\"identities\":[")
	for r, i in c.idents {
		fmt.sbprintf(&sb, "%s{{\"id\":%s,\"handle\":%s,\"name\":%s,\"kind\":%s,\"color\":%s}}", i > 0 ? "," : "", q(r.id), q(r.handle), q(r.name), q(r.kind), q(r.color))
	}
	strings.write_string(&sb, "],\n\"keysets\":[")
	for r, i in c.keysets {
		fmt.sbprintf(&sb, "%s{{\"identity_id\":%s,\"enc_pub\":%s,\"kem_pub\":%s,\"sign_pub\":%s,\"kdf_salt\":%s,\"kdf_m\":%d,\"kdf_t\":%d,\"kdf_p\":%d,\"account_key_wrap\":%s,\"private_wrap\":%s,\"key_epoch\":%d}}",
			i > 0 ? ",\n" : "", q(r.identity_id), q(r.enc_pub), q(r.kem_pub), q(r.sign_pub), q(r.kdf_salt), r.kdf.m, r.kdf.t, r.kdf.par,
			q(r.account_key_wrap), q(r.private_wrap), r.key_epoch)
	}
	strings.write_string(&sb, "],\n\"vaults\":[")
	for r, i in c.vaults {
		fmt.sbprintf(&sb, "%s{{\"id\":%s,\"identity_id\":%s,\"key_wrap\":%s,\"key_version\":%d,\"meta\":%s,\"revision\":%d}}",
			i > 0 ? ",\n" : "", q(r.id), q(r.identity_id), q(r.key_wrap), r.key_version, q(r.meta), r.revision)
	}
	strings.write_string(&sb, "],\n\"items\":[")
	for r, i in c.items {
		if i > 0 {
			strings.write_string(&sb, ",\n")
		}
		i_json(&sb, r)
	}
	strings.write_string(&sb, "],\n\"shares\":[")
	for r, i in c.shares {
		fmt.sbprintf(&sb, "%s{{\"id\":%s,\"identity_id\":%s,\"vault_id\":%s,\"item_id\":%s,\"grantee_identity\":%s,\"role\":%s,\"key_version\":%d,\"wrapped_key\":%s,\"signature\":%s,\"revoked\":%v}}",
			i > 0 ? ",\n" : "", q(r.id), q(r.identity_id), q(r.vault_id), q(r.item_id), q(r.grantee), q(r.role), r.key_version, q(r.wrapped_key), q(r.signature), r.revoked)
	}
	strings.write_string(&sb, "],\n\"devices\":[")
	for r, i in c.devices {
		fmt.sbprintf(&sb, "%s{{\"id\":%s,\"identity_id\":%s,\"name\":%s,\"pub\":%s,\"sealed_secret\":%s,\"approved\":%v,\"revoked\":%v}}",
			i > 0 ? ",\n" : "", q(r.id), q(r.identity_id), q(r.name), q(r.pub), q(r.sealed_secret), r.approved, r.revoked)
	}
	strings.write_string(&sb, "],\n\"pins\":[")
	for r, i in c.pins {
		fmt.sbprintf(&sb, "%s{{\"identity_id\":%s,\"handle\":%s,\"name\":%s,\"enc_pub\":%s,\"kem_pub\":%s,\"sign_pub\":%s}}",
			i > 0 ? ",\n" : "", q(r.identity_id), q(r.handle), q(r.name), q(r.enc_pub), q(r.kem_pub), q(r.sign_pub))
	}
	strings.write_string(&sb, "],\n\"pending\":[")
	for r, i in c.pending {
		fmt.sbprintf(&sb, "%s{{\"base\":%d,\"row\":", i > 0 ? ",\n" : "", r.base)
		i_json(&sb, r.row)
		strings.write_string(&sb, "}")
	}
	strings.write_string(&sb, "]}\n")
	return write_atomic(cache_path(a), transmute([]byte)strings.to_string(sb))
}

// ---------------------------------------------------------------------------
// Lookups
// ---------------------------------------------------------------------------

ident_by_id :: proc(a: ^Acct, id: string) -> ^Ident {
	for &i in a.cache.idents {
		if i.id == id {
			return &i
		}
	}
	return nil
}

ident_by_handle :: proc(a: ^Acct, h: string) -> ^Ident {
	for &i in a.cache.idents {
		if i.handle == h {
			return &i
		}
	}
	return nil
}

keyset_of :: proc(a: ^Acct, identity_id: string) -> ^K_Row {
	for &k in a.cache.keysets {
		if k.identity_id == identity_id {
			return &k
		}
	}
	return nil
}

vault_row :: proc(a: ^Acct, id: string) -> ^V_Row {
	for &v in a.cache.vaults {
		if v.id == id {
			return &v
		}
	}
	return nil
}

item_row :: proc(a: ^Acct, id: string) -> ^I_Row {
	for &r in a.cache.items {
		if r.id == id {
			return &r
		}
	}
	return nil
}

pending_of :: proc(a: ^Acct, id: string) -> ^Pending {
	for &p in a.cache.pending {
		if p.row.id == id {
			return &p
		}
	}
	return nil
}

pin_of :: proc(a: ^Acct, identity_id: string) -> ^Pin {
	for &p in a.cache.pins {
		if p.identity_id == identity_id {
			return &p
		}
	}
	return nil
}

my_keys :: proc(a: ^Acct, identity_id: string) -> ^Identity_Keys {
	for &k in a.idkeys {
		if k.identity_id == identity_id && k.keys.ready {
			return &k.keys
		}
	}
	return nil
}

is_mine :: proc(a: ^Acct, identity_id: string) -> bool {
	return keyset_of(a, identity_id) != nil
}

// public_keys_of answers "what do I encrypt to" for an identity: from the
// keyset rows for this account's own identities, from the pins otherwise.
public_keys_of :: proc(a: ^Acct, identity_id: string) -> (pk: Public_Keys, ok: bool) {
	enc, kem, sign: string
	if k := keyset_of(a, identity_id); k != nil {
		enc, kem, sign = k.enc_pub, k.kem_pub, k.sign_pub
	} else if p := pin_of(a, identity_id); p != nil {
		enc, kem, sign = p.enc_pub, p.kem_pub, p.sign_pub
	} else {
		return {}, false
	}
	e, eok := unb64(enc, context.temp_allocator)
	m, mok := unb64(kem, context.temp_allocator)
	s, sok := unb64(sign, context.temp_allocator)
	if !eok || !mok || !sok || len(e) != 32 || len(m) != KEM_PUB_LEN || len(s) != 32 {
		return {}, false
	}
	copy(pk.enc[:], e)
	copy(pk.kem[:], m)
	copy(pk.sign[:], s)
	return pk, true
}

handle_of :: proc(a: ^Acct, identity_id: string) -> string {
	if i := ident_by_id(a, identity_id); i != nil {
		return i.handle
	}
	if p := pin_of(a, identity_id); p != nil {
		return p.handle
	}
	return identity_id[:min(8, len(identity_id))]
}

name_of :: proc(a: ^Acct, identity_id: string) -> string {
	if i := ident_by_id(a, identity_id); i != nil {
		return i.name
	}
	if p := pin_of(a, identity_id); p != nil {
		return p.name != "" ? p.name : p.handle
	}
	return handle_of(a, identity_id)
}

note_problem :: proc(a: ^Acct, msg: string) {
	append(&a.problems, strings.clone(msg))
}

// ---------------------------------------------------------------------------
// Unlock and lock
// ---------------------------------------------------------------------------

acct_lock :: proc(a: ^Acct) {
	crypto.zero_explicit(&a.account_key, size_of(a.account_key))
	for &k in a.idkeys {
		identity_keys_clear(&k.keys)
		delete(k.identity_id)
	}
	clear(&a.idkeys)
	for &k in a.vkeys {
		crypto.zero_explicit(&k.key, size_of(k.key))
	}
	clear(&a.vkeys)
	for &k in a.ikeys {
		crypto.zero_explicit(&k.key, size_of(k.key))
	}
	clear(&a.ikeys)
	clear(&a.sources)
	clear(&a.origins)
	a.unlocked = false
}

// acct_kdf is the account's KDF salt and parameters, read from any keyset:
// they are the same on all of them.
acct_kdf :: proc(a: ^Acct) -> (salt: [SALT_LEN]byte, kdf: Kdf, ok: bool) {
	if len(a.cache.keysets) == 0 {
		return {}, {}, false
	}
	k := &a.cache.keysets[0]
	s, good := unb64(k.kdf_salt, context.temp_allocator)
	if !good || len(s) != SALT_LEN || !kdf_valid(k.kdf) {
		return {}, {}, false
	}
	copy(salt[:], s)
	return salt, k.kdf, true
}

// acct_unlock derives the AUK and opens everything below it. The cost is one
// Argon2id, whatever the number of identities.
acct_unlock :: proc(a: ^Acct, password: string) -> string {
	if !a.has_secret {
		return "this device has no Secret Key for the account: enroll it first (vault enroll)"
	}
	if !a.have_cache || len(a.cache.keysets) == 0 {
		return "the account vault has not been synced to this device yet"
	}
	salt, kdf, ok := acct_kdf(a)
	if !ok {
		return "the account's key derivation parameters are not usable"
	}
	auk: [KEY_LEN]byte
	defer crypto.zero_explicit(&auk, size_of(auk))
	if !derive_auk(password, a.secret[:], salt[:], kdf, a.cache.user_id, auk[:]) {
		return "the key could not be derived from that password"
	}
	acct_lock(a)
	opened := false
	for &k in a.cache.keysets {
		wrapped, wok := unb64(k.account_key_wrap, context.temp_allocator)
		if !wok {
			continue
		}
		plain, good := unwrap(auk[:], wrapped, aad_account_key(), context.temp_allocator)
		if !good || len(plain) != KEY_LEN {
			continue
		}
		copy(a.account_key[:], plain)
		crypto.zero_explicit(raw_data(plain), len(plain))
		opened = true
		break
	}
	if !opened {
		return "the vault did not authenticate: the master password or the Secret Key is wrong"
	}
	for &k in a.cache.keysets {
		wrapped, wok := unb64(k.private_wrap, context.temp_allocator)
		if !wok {
			continue
		}
		plain, good := unwrap(a.account_key[:], wrapped, aad_identity_keys(k.identity_id), context.temp_allocator)
		if !good {
			note_problem(a, fmt.tprintf("the keys of %s did not open", handle_of(a, k.identity_id)))
			continue
		}
		ik := Idkeys{identity_id = strings.clone(k.identity_id)}
		if !identity_keys_load(&ik.keys, plain) {
			delete(ik.identity_id)
		} else {
			// The keyset row's public half must be the one these private
			// keys produce; a server that swapped it would otherwise have
			// other people encrypt to a key it chose.
			pk, pok := public_keys_of(a, k.identity_id)
			if !pok || !secret_eq(string(pk.enc[:]), string(ik.keys.pub.enc[:])) ||
			   !secret_eq(string(pk.sign[:]), string(ik.keys.pub.sign[:])) ||
			   !secret_eq(string(pk.kem[:]), string(ik.keys.pub.kem[:])) {
				note_problem(a, fmt.tprintf("the published public keys of %s do not match its private keys", handle_of(a, k.identity_id)))
			}
			append(&a.idkeys, ik)
		}
		crypto.zero_explicit(raw_data(plain), len(plain))
	}
	a.unlocked = true
	open_vault_keys(a)
	return ""
}

// open_vault_keys walks the vault rows and the shares and opens every key
// this device is entitled to, verifying each share's signature first.
open_vault_keys :: proc(a: ^Acct) {
	for &k in a.vkeys {
		crypto.zero_explicit(&k.key, size_of(k.key))
	}
	clear(&a.vkeys)
	for &k in a.ikeys {
		crypto.zero_explicit(&k.key, size_of(k.key))
	}
	clear(&a.ikeys)
	virtual.arena_free_all(&a.varena)

	for &v in a.cache.vaults {
		me := my_keys(a, v.identity_id)
		if me == nil {
			continue
		}
		wrapped, ok := unb64(v.key_wrap, context.temp_allocator)
		if !ok {
			continue
		}
		plain, good := open_sealed(me, wrapped, aad_vault_key(v.id, v.key_version, v.identity_id), context.temp_allocator)
		if !good || len(plain) != KEY_LEN {
			note_problem(a, fmt.tprintf("a vault key of %s did not open", handle_of(a, v.identity_id)))
			continue
		}
		vk := Vkey{vault_id = vs(a, v.id), version = v.key_version, viewer = vs(a, v.identity_id), role = "owner"}
		copy(vk.key[:], plain)
		vk.kid = key_id(vk.key[:])
		crypto.zero_explicit(raw_data(plain), len(plain))
		append(&a.vkeys, vk)
	}

	for &s in a.cache.shares {
		if s.revoked {
			continue
		}
		me := my_keys(a, s.grantee)
		if me == nil {
			continue // a share this account made, not one it received
		}
		if !share_verify(a, &s) {
			note_problem(a, fmt.tprintf("a share from %s was refused: its signature does not verify", handle_of(a, s.identity_id)))
			continue
		}
		wrapped, ok := unb64(s.wrapped_key, context.temp_allocator)
		if !ok {
			continue
		}
		aad := s.item_id == "" ? aad_vault_key(s.vault_id, s.key_version, s.grantee) : aad_item_share(s.item_id, s.grantee)
		plain, good := open_sealed(me, wrapped, aad, context.temp_allocator)
		if !good || len(plain) != KEY_LEN {
			note_problem(a, fmt.tprintf("a share from %s did not open", handle_of(a, s.identity_id)))
			continue
		}
		if s.item_id == "" {
			vk := Vkey{vault_id = vs(a, s.vault_id), version = s.key_version, via = vs(a, s.id), viewer = vs(a, s.grantee), role = vs(a, s.role)}
			copy(vk.key[:], plain)
			vk.kid = key_id(vk.key[:])
			append(&a.vkeys, vk)
		} else {
			ik := Ikey{item_id = vs(a, s.item_id), share_id = vs(a, s.id), viewer = vs(a, s.grantee)}
			copy(ik.key[:], plain)
			ik.kid = key_id(ik.key[:])
			append(&a.ikeys, ik)
		}
		crypto.zero_explicit(raw_data(plain), len(plain))
	}
}

share_verify :: proc(a: ^Acct, s: ^S_Row) -> bool {
	src, ok := public_keys_of(a, s.identity_id)
	if !ok {
		return false
	}
	wrapped, wok := unb64(s.wrapped_key, context.temp_allocator)
	sig, sok := unb64(s.signature, context.temp_allocator)
	if !wok || !sok {
		return false
	}
	t := share_transcript(s.id, s.identity_id, s.vault_id, s.item_id, s.grantee, s.role, s.key_version, wrapped)
	return verify_bytes(src.sign[:], t, sig)
}

// ---------------------------------------------------------------------------
// Rows to entries
// ---------------------------------------------------------------------------

vkey_for :: proc(a: ^Acct, vault_id: string, kid: []byte) -> ^Vkey {
	for &k in a.vkeys {
		if k.vault_id == vault_id && crypto.compare_constant_time(k.kid[:], kid) == 1 {
			return &k
		}
	}
	return nil
}

vkey_current :: proc(a: ^Acct, vault_id: string) -> ^Vkey {
	v := vault_row(a, vault_id)
	best: ^Vkey
	for &k in a.vkeys {
		if k.vault_id != vault_id {
			continue
		}
		if v != nil && k.version == v.key_version {
			if best == nil || (best.role != "owner" && k.role == "owner") {
				best = &k
			}
		}
		if v == nil && (best == nil || k.version > best.version) {
			best = &k
		}
	}
	return best
}

// item_key_of opens an item row's key: through the vault key when this device
// holds it, through an item share otherwise.
item_key_of :: proc(a: ^Acct, r: ^I_Row, out: ^[KEY_LEN]byte) -> (viewer: string, via_share: bool, ok: bool) {
	if r.key_wrap != "" {
		if wrapped, good := unb64(r.key_wrap, context.temp_allocator); good {
			if kid, kok := wrap_key_id(wrapped); kok {
				if vk := vkey_for(a, r.vault_id, kid[:]); vk != nil {
					if plain, opened := unwrap(vk.key[:], wrapped, aad_item_key(r.vault_id, r.id, r.key_version), context.temp_allocator); opened && len(plain) == KEY_LEN {
						copy(out[:], plain)
						crypto.zero_explicit(raw_data(plain), len(plain))
						return vk.viewer, false, true
					}
				}
			}
		}
	}
	blob, good := unb64(r.blob, context.temp_allocator)
	if !good {
		return "", false, false
	}
	kid, kok := wrap_key_id(blob)
	if !kok {
		return "", false, false
	}
	for &k in a.ikeys {
		if k.item_id == r.id && crypto.compare_constant_time(k.kid[:], kid[:]) == 1 {
			out^ = k.key
			return k.viewer, true, true
		}
	}
	return "", false, false
}

decrypt_row :: proc(a: ^Acct, r: ^I_Row) -> (e: Entry, viewer: string, via_share: bool, ok: bool) {
	if r.deleted || r.blob == "" {
		return {}, "", false, false
	}
	key: [KEY_LEN]byte
	defer crypto.zero_explicit(&key, size_of(key))
	viewer, via_share, ok = item_key_of(a, r, &key)
	if !ok {
		return {}, "", false, false
	}
	blob, good := unb64(r.blob, context.temp_allocator)
	if !good {
		return {}, "", false, false
	}
	plain, opened := unwrap(key[:], blob, aad_item(r.vault_id, r.id, r.revision), context.temp_allocator)
	if !opened {
		return {}, "", false, false
	}
	defer crypto.zero_explicit(raw_data(plain), len(plain))
	e, ok = record_decode(plain)
	if ok && e.id != r.id {
		// The record names the row it belongs to; a blob moved between rows
		// would already have failed the AEAD, this is the belt to its braces.
		entry_free(&e)
		return {}, "", false, false
	}
	return
}

source_for :: proc(a: ^Acct, kind: Src_Kind, viewer, owner, vault_id: string) -> int {
	for s, i in a.sources {
		if s.kind != kind || s.viewer != viewer {
			continue
		}
		if kind == .Shared_Items || s.vault_id == vault_id {
			return i
		}
	}
	src := Source {
		kind         = kind,
		viewer       = ss(a, viewer),
		owner        = ss(a, owner),
		vault_id     = ss(a, vault_id),
		owner_handle = ss(a, handle_of(a, owner)),
		owner_name   = ss(a, name_of(a, owner)),
	}
	switch kind {
	case .Own:
		src.role = "owner"
	case .Shared_Vault:
		src.role = "read"
		for &k in a.vkeys {
			if k.vault_id == vault_id && k.viewer == viewer && k.role == "write" {
				src.role = "write"
			}
		}
	case .Shared_Items:
		src.role = "read"
		src.name = "Shared with me"
	}
	if vault_id != "" {
		n, c := vault_label(a, vault_id)
		src.name, src.color = ss(a, n), ss(a, c)
	}
	if src.color == "" {
		if i := ident_by_id(a, viewer); i != nil {
			src.color = ss(a, i.color)
		}
	}
	append(&a.sources, src)
	return len(a.sources) - 1
}

// vault_label opens a vault's sealed name and colour (into temp memory).
vault_label :: proc(a: ^Acct, vault_id: string) -> (name, color: string) {
	v := vault_row(a, vault_id)
	vk := vkey_current(a, vault_id)
	if v == nil || vk == nil {
		return "Vault", ""
	}
	blob, ok := unb64(v.meta, context.temp_allocator)
	if !ok {
		return "Vault", ""
	}
	kid, kok := wrap_key_id(blob)
	if kok {
		if k := vkey_for(a, vault_id, kid[:]); k != nil {
			vk = k
		}
	}
	plain, good := unwrap(vk.key[:], blob, aad_vault_meta(vault_id), context.temp_allocator)
	if !good {
		return "Vault", ""
	}
	m, mok := meta_decode(plain)
	if !mok {
		return "Vault", ""
	}
	name = strings.clone(m.name, context.temp_allocator)
	color = strings.clone(m.color, context.temp_allocator)
	delete(m.name)
	delete(m.color)
	delete(m.icon)
	return
}

// acct_entries decrypts every live item this device can open into `out`,
// with pending edits laid over the server's rows. The person's own vaults
// come first, then shares; an item visible both as one's own and through a
// share between one's identities appears once, as one's own.
acct_entries :: proc(a: ^Acct, out: ^Vault) {
	clear(&a.sources)
	clear(&a.origins)
	virtual.arena_free_all(&a.sarena)
	if !a.unlocked {
		return
	}
	// Every vault this device holds a key for gets a source, even when empty,
	// so a new vault shows up before anything is in it.
	for &v in a.cache.vaults {
		if my_keys(a, v.identity_id) != nil {
			source_for(a, .Own, v.identity_id, v.identity_id, v.id)
		}
	}
	for &k in a.vkeys {
		if k.role != "owner" && my_keys(a, vault_owner(a, k.vault_id)) == nil {
			source_for(a, .Shared_Vault, k.viewer, vault_owner(a, k.vault_id), k.vault_id)
		}
	}

	seen := make(map[string]bool, context.temp_allocator)
	emit :: proc(a: ^Acct, out: ^Vault, r: ^I_Row, seen: ^map[string]bool) {
		if r.id in seen {
			return
		}
		e, viewer, via_share, ok := decrypt_row(a, r)
		if !ok {
			return
		}
		seen[r.id] = true
		src: int
		switch {
		case my_keys(a, r.identity_id) != nil && !via_share && viewer == r.identity_id:
			src = source_for(a, .Own, r.identity_id, r.identity_id, r.vault_id)
		case !via_share:
			src = source_for(a, .Shared_Vault, viewer, r.identity_id, r.vault_id)
		case:
			src = source_for(a, .Shared_Items, viewer, r.identity_id, "")
		}
		e.src = src
		append(&out.entries, e)
		append(&a.origins, Origin{item_id = ss(a, r.id), vault_id = ss(a, r.vault_id), owner = ss(a, r.identity_id), src = src, revision = r.revision})
	}
	for &p in a.cache.pending {
		if p.row.deleted {
			seen[p.row.id] = true
			continue
		}
		emit(a, out, &p.row, &seen)
	}
	for &r in a.cache.items {
		emit(a, out, &r, &seen)
	}
}

vault_owner :: proc(a: ^Acct, vault_id: string) -> string {
	if v := vault_row(a, vault_id); v != nil {
		return v.identity_id
	}
	for &s in a.cache.shares {
		if s.vault_id == vault_id {
			return s.identity_id
		}
	}
	return ""
}

origin_of :: proc(a: ^Acct, id: string) -> ^Origin {
	for &o in a.origins {
		if o.item_id == id {
			return &o
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Entries to rows: an edit, encrypted on the spot
// ---------------------------------------------------------------------------

// acct_put encrypts `e` as the next revision of its row (or the first, for a
// new item in `vault_id`) and queues it. Nothing touches the network: sync
// pushes the queue. Returns "" or why the edit could not be made.
acct_put :: proc(a: ^Acct, e: ^Entry, vault_id: string, deleted := false, new_item_key := false) -> string {
	if !a.unlocked {
		return "the vault is locked"
	}
	base: i64 = 0
	cur := item_row(a, e.id)
	if p := pending_of(a, e.id); p != nil {
		base = p.base
	} else if cur != nil {
		base = cur.revision
	}
	vid := vault_id
	owner := ""
	if cur != nil {
		vid = cur.vault_id
		owner = cur.identity_id
	} else if p := pending_of(a, e.id); p != nil {
		vid = p.row.vault_id
		owner = p.row.identity_id
	}
	if vid == "" {
		return "no vault to put the item in"
	}
	if owner == "" {
		owner = vault_owner(a, vid)
	}
	vk := vkey_current(a, vid)
	if vk == nil {
		return "this device does not hold the key to that vault"
	}
	if vk.role == "read" {
		return "that vault is shared read-only"
	}
	v := vault_row(a, vid)
	version := v != nil ? v.key_version : vk.version

	row := I_Row {
		id          = cs(a, e.id),
		identity_id = cs(a, owner),
		vault_id    = cs(a, vid),
		revision    = base + 1,
		key_version = version,
		deleted     = deleted,
	}
	if !deleted {
		ikey: [KEY_LEN]byte
		defer crypto.zero_explicit(&ikey, size_of(ikey))
		// Reuse the item's key: the server's row first (after a merge it
		// may carry a key rotated since this edit was made), the pending
		// row otherwise. A key that does not open is replaced, which is
		// always safe: the item is re-encrypted whole.
		have := false
		if !new_item_key {
			if cur != nil && !cur.deleted {
				_, _, have = item_key_of(a, cur, &ikey)
			}
			if !have {
				if p := pending_of(a, e.id); p != nil && !p.row.deleted {
					_, _, have = item_key_of(a, &p.row, &ikey)
				}
			}
		}
		if !have {
			crypto.rand_bytes(ikey[:])
		}
		plain := record_encode(e, context.temp_allocator)
		blob := wrap(ikey[:], plain, aad_item(vid, e.id, row.revision), context.temp_allocator)
		crypto.zero_explicit(raw_data(plain), len(plain))
		kw := wrap(vk.key[:], ikey[:], aad_item_key(vid, e.id, version), context.temp_allocator)
		row.blob = cs(a, b64(blob, context.temp_allocator))
		row.key_wrap = cs(a, b64(kw, context.temp_allocator))
	}
	if p := pending_of(a, e.id); p != nil {
		p.row = row
	} else {
		append(&a.cache.pending, Pending{row = row, base = base})
	}
	return cache_save(a)
}

// ---------------------------------------------------------------------------
// Creating vaults and keysets
// ---------------------------------------------------------------------------

// new_vault_row makes a vault for an identity this device holds keys for:
// a fresh key sealed to the identity, and the name sealed under the key.
new_vault_row :: proc(a: ^Acct, identity_id: string, name, color: string) -> (row: V_Row, err: string) {
	me := my_keys(a, identity_id)
	if me == nil {
		return {}, "this device does not hold that identity's keys"
	}
	vkey: [KEY_LEN]byte
	defer crypto.zero_explicit(&vkey, size_of(vkey))
	crypto.rand_bytes(vkey[:])
	id := new_uuid(context.temp_allocator)
	sealed, ok := seal_to(&me.pub, vkey[:], aad_vault_key(id, 1, identity_id), context.temp_allocator)
	if !ok {
		return {}, "the vault key could not be sealed"
	}
	meta := meta_encode(Vault_Meta{name, color, "lock"}, context.temp_allocator)
	mw := wrap(vkey[:], meta, aad_vault_meta(id), context.temp_allocator)
	row = V_Row {
		id          = cs(a, id),
		identity_id = cs(a, identity_id),
		key_wrap    = cs(a, b64(sealed, context.temp_allocator)),
		key_version = 1,
		meta        = cs(a, b64(mw, context.temp_allocator)),
		revision    = 1,
	}
	vk := Vkey{vault_id = vs(a, row.id), version = 1, viewer = vs(a, row.identity_id), role = "owner"}
	vk.key = vkey
	vk.kid = key_id(vk.key[:])
	append(&a.vkeys, vk)
	return row, ""
}

// new_keyset_row makes an identity's keys and wraps them for the account.
// The AUK only wraps the account key, so a keyset for an identity added later
// needs only the account key, not the password.
new_keyset_row :: proc(a: ^Acct, identity_id: string, auk: []byte, salt: []byte, kdf: Kdf) -> (row: K_Row, err: string) {
	ik := Idkeys{identity_id = strings.clone(identity_id), keys = identity_keys_generate()}
	pw := wrap(a.account_key[:], ik.keys.priv[:], aad_identity_keys(identity_id), context.temp_allocator)
	akw := wrap(auk, a.account_key[:], aad_account_key(), context.temp_allocator)
	row = K_Row {
		identity_id      = cs(a, identity_id),
		enc_pub          = cs(a, b64(ik.keys.pub.enc[:], context.temp_allocator)),
		kem_pub          = cs(a, b64(ik.keys.pub.kem[:], context.temp_allocator)),
		sign_pub         = cs(a, b64(ik.keys.pub.sign[:], context.temp_allocator)),
		kdf_salt         = cs(a, b64(salt, context.temp_allocator)),
		kdf              = kdf,
		account_key_wrap = cs(a, b64(akw, context.temp_allocator)),
		private_wrap     = cs(a, b64(pw, context.temp_allocator)),
		key_epoch        = 1,
	}
	append(&a.idkeys, ik)
	return row, ""
}

// ---------------------------------------------------------------------------
// Small helpers for sync.odin and the CLI
// ---------------------------------------------------------------------------

parse_int :: proc(s: string) -> int {
	n, _ := strconv.parse_int(s)
	return n
}

ident_sorted :: proc(a: ^Acct) -> []Ident {
	out := slice.clone(a.cache.idents[:], context.temp_allocator)
	return out
}
