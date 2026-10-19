package main

// Moving rows between this device and the server, through cloudkit.
//
// A sync is: pull everything this session may see (cheap listings first,
// then only the item rows whose revision changed), push the queue of local
// edits one compare-and-swap at a time, and merge any item someone else
// changed in the meantime (merge.odin). It is safe to run at any moment and
// to interrupt: the queue is on disk and every push is idempotent against its
// base revision.
//
// What a sync never sends: a plaintext, a key, the Secret Key, the master
// password. Every argument below that is not an id or a counter is either a
// public key or base64 of something sealed in keys.odin.

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import ck "../cloudkit"

Sync_Report :: struct {
	pulled:     int, // item rows fetched because they changed
	pushed:     int, // local edits the server accepted
	merged:     int, // conflicts resolved by merge3
	conflicted: int, // of those, fields both sides changed differently
	dropped:    int, // local edits for items this session can no longer write
	removed:    int, // items no longer visible (revoked, purged)
	created:    int, // keysets or vaults created on the way
}

// acct_connect opens cloudkit with the scope in force (PALM_IDENTITY) and
// says whether there is a session to sync with.
acct_connect :: proc(a: ^Acct) -> string {
	if a.client != nil {
		return ""
	}
	c, e := ck.open(app = "vault")
	if !ck.ok(e) {
		if c != nil {
			ck.close(c)
		}
		return e.message
	}
	if !ck.signed_in(c) {
		ck.close(c)
		return "not signed in to the Palmy cloud (accounts sign-in)"
	}
	a.client = c
	return ""
}

ck_err :: proc(what: string, e: ck.Error) -> string {
	return fmt.tprintf("%s: %s (%s)", what, e.message, ck.error_kind_name(e.kind))
}

// reload_cache compacts the cache: save it, read it back into a fresh arena.
// Every string handed out of the old arena is invalid afterwards, so the keys
// are reopened here and callers rebuild their entries.
reload_cache :: proc(a: ^Acct) -> string {
	if err := cache_save(a); err != "" {
		return err
	}
	raw, rerr := os.read_entire_file(cache_path(a), context.temp_allocator)
	if rerr != nil {
		return "could not read the cache back"
	}
	cache_from_json(a, string(raw))
	if a.unlocked {
		open_vault_keys(a)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Pull
// ---------------------------------------------------------------------------

acct_pull :: proc(a: ^Acct, rep: ^Sync_Report) -> string {
	c := a.client
	if !a.have_cache {
		cache_reset(a)
		a.have_cache = true
	}
	a.cache.user_id = cs(a, c.session.user_id)
	a.cache.email = cs(a, c.session.email)
	a.cache.scope = cs(a, c.scope)

	ids, e := ck.identities(c, context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("listing identities", e)
	}
	clear(&a.cache.idents)
	for i in ids {
		if i.archived {
			continue
		}
		append(&a.cache.idents, Ident{cs(a, i.id), cs(a, i.handle), cs(a, i.display_name), cs(a, i.kind), cs(a, i.color)})
	}

	v: ck.Value
	v, e = ck.select(c, "vault_keysets", "select=*", context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("reading keysets", e)
	}
	clear(&a.cache.keysets)
	for r in ck.array(v) {
		append(&a.cache.keysets, k_from(a, r))
	}

	v, e = ck.select(c, "vault_vaults", "select=*&deleted_at=is.null&order=created_at.asc", context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("reading vaults", e)
	}
	clear(&a.cache.vaults)
	for r in ck.array(v) {
		append(&a.cache.vaults, v_from(a, r))
	}

	v, e = ck.select(c, "vault_shares", "select=*&order=created_at.asc", context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("reading shares", e)
	}
	clear(&a.cache.shares)
	for r in ck.array(v) {
		append(&a.cache.shares, s_from(a, r))
	}

	v, e = ck.select(c, "vault_devices", "select=*&order=created_at.asc", context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("reading devices", e)
	}
	clear(&a.cache.devices)
	for r in ck.array(v) {
		append(&a.cache.devices, d_from(a, r))
	}

	// Items: the listing is ids and counters only; a row's ciphertext is
	// fetched again only when its revision moved.
	v, e = ck.select(c, "vault_items", "select=id,revision,key_version,deleted&order=id", context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("listing items", e)
	}
	listing := ck.array(v)
	want := make([dynamic]string, context.temp_allocator)
	alive := make(map[string]bool, context.temp_allocator)
	for r in listing {
		id := ck.get_str(r, "id")
		alive[id] = true
		have := item_row(a, id)
		if have == nil || have.revision != ck.get_int(r, "revision") || have.key_version != int(ck.get_int(r, "key_version")) {
			append(&want, id)
		}
	}
	for i := 0; i < len(a.cache.items); {
		if !(a.cache.items[i].id in alive) {
			ordered_remove(&a.cache.items, i)
			rep.removed += 1
			continue
		}
		i += 1
	}
	for at := 0; at < len(want); at += 40 {
		batch := want[at:min(at + 40, len(want))]
		ids_q := strings.join(batch, ",", context.temp_allocator)
		rows: ck.Value
		rows, e = ck.select(c, "vault_items", fmt.tprintf("select=*&id=in.(%s)", ids_q), context.temp_allocator)
		if !ck.ok(e) {
			return ck_err("reading items", e)
		}
		for r in ck.array(rows) {
			row := i_from(a, r)
			if have := item_row(a, row.id); have != nil {
				// Rollback: a server handing back an older revision of an
				// item this device has already seen (yesterday's ciphertext,
				// still validly encrypted) is refused, and said so.
				if row.revision < have.revision {
					note_problem(a, fmt.tprintf("the server offered an older revision of an item (%d after %d): kept this device's copy", row.revision, have.revision))
					continue
				}
				have^ = row
			} else {
				append(&a.cache.items, row)
			}
			rep.pulled += 1
		}
	}

	// Pin the public keys of every identity outside this account that has
	// shared something with it, the first time it is seen.
	for &s in a.cache.shares {
		for who in ([2]string{s.identity_id, s.grantee}) {
			if is_mine(a, who) || pin_of(a, who) != nil {
				continue
			}
			o := ck.obj()
			ck.put(&o, "p_identity", who)
			pv, pe := ck.rpc(c, "vault_public_keys_by_id", ck.obj_done(&o), context.temp_allocator)
			if !ck.ok(pe) {
				continue
			}
			for r in ck.array(pv) {
				append(&a.cache.pins, Pin{cs(a, who), cs(a, ck.get_str(r, "handle")), cs(a, ck.get_str(r, "display_name")),
					cs(a, ck.get_str(r, "enc_pub")), cs(a, ck.get_str(r, "kem_pub")), cs(a, ck.get_str(r, "sign_pub"))})
			}
		}
	}
	a.cache.synced_at = now_unix()
	return ""
}

// ---------------------------------------------------------------------------
// Push
// ---------------------------------------------------------------------------

put_rpc :: proc(a: ^Acct, row: I_Row, base: i64) -> (out: ck.Value, e: ck.Error) {
	o := ck.obj()
	ck.put(&o, "p_id", row.id)
	ck.put(&o, "p_identity", row.identity_id)
	ck.put(&o, "p_vault", row.vault_id)
	ck.put(&o, "p_base", base)
	ck.put(&o, "p_key_version", i64(row.key_version))
	if row.deleted {
		ck.put_null(&o, "p_key_wrap")
		ck.put_null(&o, "p_blob")
	} else {
		ck.put(&o, "p_key_wrap", row.key_wrap)
		ck.put(&o, "p_blob", row.blob)
	}
	ck.put(&o, "p_deleted", row.deleted)
	return ck.rpc(a.client, "vault_put_item", ck.obj_done(&o), context.temp_allocator)
}

is_conflict :: proc(e: ck.Error) -> bool {
	return e.code == "40001" && strings.contains(e.message, "conflict")
}

is_stale_key :: proc(e: ck.Error) -> bool {
	return e.code == "40001" && strings.contains(e.message, "rotated")
}

acct_push :: proc(a: ^Acct, rep: ^Sync_Report) -> string {
	for len(a.cache.pending) > 0 {
		p := a.cache.pending[0]
		attempt := 0
		for {
			attempt += 1
			out, e := put_rpc(a, p.row, p.base)
			if ck.ok(e) {
				row := i_from(a, out)
				if have := item_row(a, row.id); have != nil {
					have^ = row
				} else {
					append(&a.cache.items, row)
				}
				rep.pushed += 1
				break
			}
			if attempt > 4 {
				return ck_err("pushing an item kept conflicting", e)
			}
			switch {
			case is_conflict(e):
				// Someone wrote first. Fetch theirs, merge with ours over
				// the base we both started from, and try again on top.
				merged, c, merr := resolve_conflict(a, &p)
				if merr != "" {
					return merr
				}
				rep.merged += 1
				if c {
					rep.conflicted += 1
				}
				_ = merged
			case is_stale_key(e):
				// The vault key was rotated while this edit waited. Open the
				// edit under the old key while it is still at hand, re-pull
				// the vault, and re-encrypt under the current key.
				ent, _, _, dok := decrypt_row(a, &p.row)
				if !dok {
					return "an edit made under a rotated key could not be re-wrapped"
				}
				rerr := refresh_vault(a, p.row.vault_id)
				if rerr == "" {
					rerr = put_pending(a, &p, &ent, p.base)
				}
				entry_free(&ent)
				if rerr != "" {
					return rerr
				}
			case e.kind == .Not_Found || e.kind == .Out_Of_Scope:
				// Access to this item is gone (a share revoked, a vault
				// deleted). There is nowhere to put the edit.
				rep.dropped += 1
				attempt = 99
			case:
				return ck_err("pushing an item", e)
			}
			if attempt == 99 {
				break
			}
		}
		ordered_remove(&a.cache.pending, 0)
		if err := cache_save(a); err != "" {
			return err
		}
	}
	return ""
}

// resolve_conflict rebuilds `p` as a merge of the server's current row, our
// edit, and our last synced copy.
resolve_conflict :: proc(a: ^Acct, p: ^Pending) -> (merged: bool, conflicted: bool, err: string) {
	rows, e := ck.select(a.client, "vault_items", fmt.tprintf("select=*&id=eq.%s", p.row.id), context.temp_allocator)
	if !ck.ok(e) || len(ck.array(rows)) == 0 {
		return false, false, ck_err("fetching the item that conflicted", e)
	}
	server := i_from(a, ck.array(rows)[0])
	base_row: ^I_Row = nil
	if p.base_row.id != "" {
		base_row = &p.base_row
	}

	ours, _, _, ook := decrypt_row(a, &p.row)
	if !ook {
		return false, false, "the local edit could not be opened to merge it"
	}
	defer entry_free(&ours)

	if server.deleted {
		// Deleted elsewhere, edited here: the edit wins and resurrects the
		// item on top of the tombstone. Losing an edit is worse than undoing
		// a delete.
		p.base = server.revision
		upsert_item(a, server)
		e2 := ours
		return true, true, put_pending(a, p, &e2, server.revision)
	}

	theirs, _, _, tok := decrypt_row(a, &server)
	if !tok {
		return false, false, "the server's version could not be opened to merge it"
	}
	defer entry_free(&theirs)

	base: Entry
	have_base := false
	if base_row != nil && !base_row.deleted {
		base, _, _, have_base = decrypt_row(a, base_row)
	}
	if !have_base {
		base = entry_clone(&theirs) // no common ancestor: treat theirs as the base
	}
	defer entry_free(&base)

	out, c := merge3(&base, &ours, &theirs)
	defer entry_free(&out)
	upsert_item(a, server)
	// The merged edit is now relative to the server's row: that is its new base.
	if q := pending_of(a, p.row.id); q != nil {
		q.base_row = server
	}
	p.base_row = server
	return true, c, put_pending(a, p, &out, server.revision)
}

// put_pending re-encrypts `e` as the revision after `base`.
put_pending :: proc(a: ^Acct, p: ^Pending, e: ^Entry, base: i64) -> string {
	p.base = base
	if q := pending_of(a, p.row.id); q != nil {
		q.base = base
	}
	if err := acct_put(a, e, p.row.vault_id); err != "" {
		return err
	}
	if q := pending_of(a, p.row.id); q != nil {
		p^ = q^
	}
	return ""
}

upsert_item :: proc(a: ^Acct, row: I_Row) {
	if have := item_row(a, row.id); have != nil {
		have^ = row
	} else {
		append(&a.cache.items, row)
	}
}

refresh_vault :: proc(a: ^Acct, vault_id: string) -> string {
	rows, e := ck.select(a.client, "vault_vaults", fmt.tprintf("select=*&id=eq.%s", vault_id), context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("refreshing a vault", e)
	}
	for r in ck.array(rows) {
		row := v_from(a, r)
		if have := vault_row(a, row.id); have != nil {
			have^ = row
		} else {
			append(&a.cache.vaults, row)
		}
	}
	sh, se := ck.select(a.client, "vault_shares", "select=*&order=created_at.asc", context.temp_allocator)
	if ck.ok(se) {
		clear(&a.cache.shares)
		for r in ck.array(sh) {
			append(&a.cache.shares, s_from(a, r))
		}
	}
	open_vault_keys(a)
	return ""
}


// ---------------------------------------------------------------------------
// The whole sync
// ---------------------------------------------------------------------------

acct_sync :: proc(a: ^Acct) -> (rep: Sync_Report, err: string) {
	if err = acct_connect(a); err != "" {
		return
	}
	if err = acct_pull(a, &rep); err != "" {
		return
	}
	if a.unlocked {
		open_vault_keys(a)
		rep.created += ensure_keysets(a)
		if err = acct_push(a, &rep); err != "" {
			return
		}
	}
	err = reload_cache(a)
	if err == "" {
		touch_devices(a)
	}
	return
}

// touch_devices records that this device synced, where it is enrolled.
touch_devices :: proc(a: ^Acct) {
	for ident, dev in a.device_ids {
		if !is_mine(a, ident) || a.client == nil {
			continue
		}
		o := ck.obj()
		ck.put(&o, "last_sync_at", time_iso(now_unix()))
		ck.update(a.client, "vault_devices", fmt.tprintf("id=eq.%s", dev), ck.obj_done(&o), context.temp_allocator)
	}
}

time_iso :: proc(t: i64) -> string {
	tt := time.unix(t, 0)
	y, m, d := time.date(tt)
	h, mi, s := time.clock_from_time(tt)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(m), d, h, mi, s)
}

// ensure_keysets gives an identity that has none (one created after the
// account was set up) its keys and a first vault. Needs the account key,
// which an unlocked device has, and a copy of the account key's wrap, which
// any existing keyset row carries.
ensure_keysets :: proc(a: ^Acct) -> int {
	if !a.unlocked || len(a.cache.keysets) == 0 || a.client == nil {
		return 0
	}
	model := a.cache.keysets[0]
	n := 0
	for &id in a.cache.idents {
		if is_mine(a, id.id) {
			continue
		}
		ik := Idkeys{identity_id = strings.clone(id.id), keys = identity_keys_generate()}
		pw := wrap(a.account_key[:], ik.keys.priv[:], aad_identity_keys(id.id), context.temp_allocator)
		row := K_Row {
			identity_id      = id.id,
			enc_pub          = b64(ik.keys.pub.enc[:], context.temp_allocator),
			kem_pub          = b64(ik.keys.pub.kem[:], context.temp_allocator),
			sign_pub         = b64(ik.keys.pub.sign[:], context.temp_allocator),
			kdf_salt         = model.kdf_salt,
			kdf              = model.kdf,
			account_key_wrap = model.account_key_wrap,
			private_wrap     = b64(pw, context.temp_allocator),
			key_epoch        = model.key_epoch,
		}
		if insert_keyset(a, row) != "" {
			identity_keys_clear(&ik.keys)
			delete(ik.identity_id)
			continue
		}
		append(&a.cache.keysets, row)
		append(&a.idkeys, ik)
		if vrow, verr := new_vault_row(a, id.id, default_vault_name(&id), id.color); verr == "" {
			if insert_vault(a, vrow) == "" {
				append(&a.cache.vaults, vrow)
			}
		}
		n += 1
	}
	return n
}

default_vault_name :: proc(id: ^Ident) -> string {
	switch id.kind {
	case "work":
		return "Work"
	case "public":
		return "Public"
	case "project":
		return "Project"
	}
	return "Personal"
}

insert_keyset :: proc(a: ^Acct, r: K_Row) -> string {
	o := ck.obj()
	ck.put(&o, "identity_id", r.identity_id)
	ck.put(&o, "enc_pub", r.enc_pub)
	ck.put(&o, "kem_pub", r.kem_pub)
	ck.put(&o, "sign_pub", r.sign_pub)
	ck.put(&o, "kdf_salt", r.kdf_salt)
	ck.put(&o, "kdf_m", i64(r.kdf.m))
	ck.put(&o, "kdf_t", i64(r.kdf.t))
	ck.put(&o, "kdf_p", i64(r.kdf.par))
	ck.put(&o, "account_key_wrap", r.account_key_wrap)
	ck.put(&o, "private_wrap", r.private_wrap)
	ck.put(&o, "key_epoch", i64(r.key_epoch))
	_, e := ck.insert(a.client, "vault_keysets", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("publishing a keyset", e)
	}
	return ""
}

insert_vault :: proc(a: ^Acct, r: V_Row) -> string {
	o := ck.obj()
	ck.put(&o, "id", r.id)
	ck.put(&o, "identity_id", r.identity_id)
	ck.put(&o, "key_wrap", r.key_wrap)
	ck.put(&o, "key_version", i64(r.key_version))
	ck.put(&o, "meta", r.meta)
	_, e := ck.insert(a.client, "vault_vaults", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("creating a vault", e)
	}
	return ""
}

// ---------------------------------------------------------------------------
// Setting the account up, on its first device
// ---------------------------------------------------------------------------

// acct_setup creates the Secret Key, the account key and a keyset and vault
// for every identity this session can see. It refuses if any identity
// already has a keyset: the account exists, and this device should enroll
// instead of minting a second account key nobody else can open.
acct_setup :: proc(a: ^Acct, password: string, kdf := KDF_DEFAULT) -> (secret_text: string, err: string) {
	if err = acct_connect(a); err != "" {
		return
	}
	rep: Sync_Report
	if err = acct_pull(a, &rep); err != "" {
		return
	}
	if len(a.cache.keysets) > 0 {
		return "", "the account vault already exists: enroll this device instead (vault enroll)"
	}
	if len(a.cache.idents) == 0 {
		return "", "this session sees no identities to set up"
	}
	if len(password) < 8 {
		return "", "a master password shorter than 8 characters is not worth encrypting anything with"
	}
	crypto.rand_bytes(a.secret[:])
	a.has_secret = true
	crypto.rand_bytes(a.account_key[:])
	salt: [SALT_LEN]byte
	crypto.rand_bytes(salt[:])
	auk: [KEY_LEN]byte
	defer crypto.zero_explicit(&auk, size_of(auk))
	if !derive_auk(password, a.secret[:], salt[:], kdf, a.cache.user_id, auk[:]) {
		return "", "the key could not be derived"
	}
	a.unlocked = true
	for &id in a.cache.idents {
		row, rerr := new_keyset_row(a, id.id, auk[:], salt[:], kdf)
		if rerr != "" {
			return "", rerr
		}
		if err = insert_keyset(a, row); err != "" {
			return
		}
		append(&a.cache.keysets, row)
		vrow, verr := new_vault_row(a, id.id, default_vault_name(&id), id.color)
		if verr != "" {
			return "", verr
		}
		if err = insert_vault(a, vrow); err != "" {
			return
		}
		append(&a.cache.vaults, vrow)
	}
	if err = device_save(a); err != "" {
		return
	}
	if err = reload_cache(a); err != "" {
		return
	}
	return secret_format(a.secret[:]), ""
}

// acct_enroll_with_secret is the manual path for a new device: the person
// types the Secret Key from their emergency kit.
acct_enroll_with_secret :: proc(a: ^Acct, secret_text: string) -> string {
	sec, ok := secret_parse(secret_text)
	if !ok {
		return "that is not a Secret Key (PV1-XXXXXX-XXXXXX-XXXXXX-XXXXXX-XX)"
	}
	a.secret = sec
	a.has_secret = true
	if err := device_save(a); err != "" {
		return err
	}
	rep: Sync_Report
	if err := acct_connect(a); err != "" {
		return err
	}
	if err := acct_pull(a, &rep); err != "" {
		return err
	}
	return reload_cache(a)
}

// ---------------------------------------------------------------------------
// New devices, approved by an old one
//
// The new device publishes an X25519 key; both screens show a six-digit code
// derived from it; the person checks they match and approves on the old
// device, which seals the Secret Key to that key. The server carries the
// sealed box and cannot open it. A server that substituted its own key would
// show a different code, which is the whole reason the code exists.
// ---------------------------------------------------------------------------

device_code :: proc(pub: []byte) -> string {
	h := sha256_tagged("palm-vault/device-code/v1", pub)
	v := (u32(h[0]) << 24 | u32(h[1]) << 16 | u32(h[2]) << 8 | u32(h[3])) % 1_000_000
	return fmt.tprintf("%03d %03d", v / 1000, v % 1000)
}

acct_device_request :: proc(a: ^Acct, identity_handle: string, name: string) -> (device_id: string, code: string, err: string) {
	if err = acct_connect(a); err != "" {
		return
	}
	rep: Sync_Report
	if err = acct_pull(a, &rep); err != "" {
		return
	}
	id := ident_by_handle(a, identity_handle)
	if id == nil {
		return "", "", fmt.tprintf("this session cannot see an identity called %q", identity_handle)
	}
	if !a.has_device {
		crypto.rand_bytes(a.device_priv[:])
		a.has_device = true
	}
	pub: [32]byte
	x25519_base(pub[:], a.device_priv[:])
	did := new_uuid(context.temp_allocator)
	o := ck.obj()
	ck.put(&o, "id", did)
	ck.put(&o, "identity_id", id.id)
	ck.put(&o, "name", name)
	ck.put(&o, "pub", b64(pub[:], context.temp_allocator))
	_, e := ck.insert(a.client, "vault_devices", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return "", "", ck_err("enrolling the device", e)
	}
	a.device_ids[strings.clone(id.id)] = strings.clone(did)
	if err = device_save(a); err != "" {
		return
	}
	return did, device_code(pub[:]), ""
}

acct_device_approve :: proc(a: ^Acct, device_id: string, code: string) -> string {
	if !a.has_secret {
		return "this device has no Secret Key to give"
	}
	if err := acct_connect(a); err != "" {
		return err
	}
	rows, e := ck.select(a.client, "vault_devices", fmt.tprintf("select=*&id=eq.%s", device_id), context.temp_allocator)
	if !ck.ok(e) || len(ck.array(rows)) == 0 {
		return "no such device for this session"
	}
	r := ck.array(rows)[0]
	if !ck.is_null(r, "revoked_at") {
		return "that device has been revoked"
	}
	pub, ok := unb64(ck.get_str(r, "pub"), context.temp_allocator)
	if !ok || len(pub) != 32 {
		return "that device's key is malformed"
	}
	want := device_code(pub)
	clean :: proc(s: string) -> string {
		out, _ := strings.replace_all(s, " ", "", context.temp_allocator)
		return out
	}
	if !secret_eq(clean(want), clean(code)) {
		return "the code does not match the one on the new device's screen: not approved"
	}
	sealed, sok := seal_x_to(pub, a.secret[:], aad_device_secret(device_id), context.temp_allocator)
	if !sok {
		return "could not seal the Secret Key to that device"
	}
	o := ck.obj()
	ck.put(&o, "sealed_secret", b64(sealed, context.temp_allocator))
	ck.put(&o, "approved_at", time_iso(now_unix()))
	upd, ue := ck.update(a.client, "vault_devices", fmt.tprintf("id=eq.%s", device_id), ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(ue) || len(ck.array(upd)) == 0 {
		return ck_err("approving the device", ue)
	}
	return ""
}

// acct_device_poll checks whether this device has been approved, and if so
// opens the Secret Key it was sent.
acct_device_poll :: proc(a: ^Acct) -> (approved: bool, err: string) {
	if a.has_secret {
		return true, ""
	}
	if !a.has_device || len(a.device_ids) == 0 {
		return false, "this device has not asked to be enrolled (vault enroll --request)"
	}
	if err = acct_connect(a); err != "" {
		return
	}
	for _, did in a.device_ids {
		rows, e := ck.select(a.client, "vault_devices", fmt.tprintf("select=*&id=eq.%s", did), context.temp_allocator)
		if !ck.ok(e) {
			return false, ck_err("checking the enrollment", e)
		}
		for r in ck.array(rows) {
			s := ck.get_str(r, "sealed_secret")
			if s == "" {
				continue
			}
			blob, ok := unb64(s, context.temp_allocator)
			if !ok {
				continue
			}
			plain, good := open_x_sealed(a.device_priv[:], blob, aad_device_secret(did), context.temp_allocator)
			if !good || len(plain) != SECRET_LEN {
				return false, "the approval did not open: it was not sealed to this device"
			}
			copy(a.secret[:], plain)
			crypto.zero_explicit(raw_data(plain), len(plain))
			a.has_secret = true
			if err = device_save(a); err != "" {
				return
			}
			rep: Sync_Report
			if err = acct_pull(a, &rep); err != "" {
				return
			}
			return true, reload_cache(a)
		}
	}
	return false, ""
}

// ---------------------------------------------------------------------------
// Sharing
// ---------------------------------------------------------------------------

// lookup_identity finds the identity to share with: one of this account's, or
// anyone's by handle through vault_public_keys, pinned on first sight.
lookup_identity :: proc(a: ^Acct, handle: string) -> (id: string, pk: Public_Keys, err: string) {
	if i := ident_by_handle(a, handle); i != nil {
		k, ok := public_keys_of(a, i.id)
		if !ok {
			return "", {}, fmt.tprintf("%s has no vault keys yet", handle)
		}
		return i.id, k, ""
	}
	if a.client == nil {
		return "", {}, "sharing with another account needs the network"
	}
	o := ck.obj()
	ck.put(&o, "p_handle", handle)
	v, e := ck.rpc(a.client, "vault_public_keys", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return "", {}, ck_err("looking up the identity", e)
	}
	rows := ck.array(v)
	if len(rows) == 0 {
		return "", {}, fmt.tprintf("no identity called %q has a vault", handle)
	}
	r := rows[0]
	who := ck.get_str(r, "identity_id")
	if p := pin_of(a, who); p != nil {
		if p.sign_pub != ck.get_str(r, "sign_pub") || p.enc_pub != ck.get_str(r, "enc_pub") || p.kem_pub != ck.get_str(r, "kem_pub") {
			return "", {}, fmt.tprintf("the server returned different keys for %s than the ones pinned before: refusing to share", handle)
		}
	} else {
		append(&a.cache.pins, Pin{cs(a, who), cs(a, ck.get_str(r, "handle")), cs(a, ck.get_str(r, "display_name")),
			cs(a, ck.get_str(r, "enc_pub")), cs(a, ck.get_str(r, "kem_pub")), cs(a, ck.get_str(r, "sign_pub"))})
	}
	k, ok := public_keys_of(a, who)
	if !ok {
		return "", {}, "the identity's public keys are malformed"
	}
	return strings.clone(who, context.temp_allocator), k, ""
}

insert_share :: proc(a: ^Acct, src_identity, vault_id, item_id, grantee, role: string, key_version: int, key: []byte, rcpt: ^Public_Keys) -> string {
	me := my_keys(a, src_identity)
	if me == nil {
		return "this device does not hold the sharing identity's keys"
	}
	aad := item_id == "" ? aad_vault_key(vault_id, key_version, grantee) : aad_item_share(item_id, grantee)
	sealed, ok := seal_to(rcpt, key, aad, context.temp_allocator)
	if !ok {
		return "the key could not be sealed to that identity"
	}
	sid := new_uuid(context.temp_allocator)
	t := share_transcript(sid, src_identity, vault_id, item_id, grantee, role, key_version, sealed)
	sig := sign_bytes(me, t)
	o := ck.obj()
	ck.put(&o, "id", sid)
	ck.put(&o, "identity_id", src_identity)
	ck.put(&o, "vault_id", vault_id)
	if item_id != "" {
		ck.put(&o, "item_id", item_id)
	}
	ck.put(&o, "grantee_identity", grantee)
	ck.put(&o, "role", role)
	ck.put(&o, "key_version", i64(key_version))
	ck.put(&o, "wrapped_key", b64(sealed, context.temp_allocator))
	ck.put(&o, "signature", b64(sig[:], context.temp_allocator))
	_, e := ck.insert(a.client, "vault_shares", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return ck_err("sharing", e)
	}
	return ""
}

// acct_share_item shares one item, read-only, with an identity by handle.
// The item must be on the server already (a pending new item is pushed first).
acct_share_item :: proc(a: ^Acct, item_id: string, grantee_handle: string) -> string {
	if err := acct_connect(a); err != "" {
		return err
	}
	rep: Sync_Report
	if err := acct_push(a, &rep); err != "" {
		return err
	}
	r := item_row(a, item_id)
	if r == nil || r.deleted {
		return "no such item on the server"
	}
	if my_keys(a, r.identity_id) == nil {
		return "only the identity that owns an item can share it"
	}
	who, pk, err := lookup_identity(a, grantee_handle)
	if err != "" {
		return err
	}
	if who == r.identity_id {
		return "an identity cannot share with itself"
	}
	key: [KEY_LEN]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if _, via, ok := item_key_of(a, r, &key); !ok || via {
		return "the item's key could not be opened"
	}
	if err = insert_share(a, r.identity_id, r.vault_id, r.id, who, "read", r.key_version, key[:], &pk); err != "" {
		return err
	}
	return refresh_after(a)
}

acct_share_vault :: proc(a: ^Acct, vault_id: string, grantee_handle: string, role: string) -> string {
	if err := acct_connect(a); err != "" {
		return err
	}
	v := vault_row(a, vault_id)
	if v == nil || my_keys(a, v.identity_id) == nil {
		return "only the identity that owns a vault can share it"
	}
	who, pk, err := lookup_identity(a, grantee_handle)
	if err != "" {
		return err
	}
	if who == v.identity_id {
		return "an identity cannot share with itself"
	}
	vk := vkey_current(a, vault_id)
	if vk == nil {
		return "the vault key is not open"
	}
	if err = insert_share(a, v.identity_id, v.id, "", who, role == "write" ? "write" : "read", v.key_version, vk.key[:], &pk); err != "" {
		return err
	}
	return refresh_after(a)
}

refresh_after :: proc(a: ^Acct) -> string {
	rep: Sync_Report
	if err := acct_pull(a, &rep); err != "" {
		return err
	}
	return reload_cache(a)
}

// ---------------------------------------------------------------------------
// Revoking, and rotating so the revoked key stops being useful
//
// Setting revoked_at stops the rows reaching the grantee at once (pgTAP:
// vault_shares.sql). It cannot make the grantee forget what it already
// decrypted, and the grantee may have kept the key. So the owner rotates:
//
//   item share   a new item key; the item is re-encrypted under it; every
//                other live share of the item is re-issued with the new key.
//   vault share  a new vault key (key_version + 1); every item in the vault
//                gets a new item key and is re-encrypted; every other live
//                share of the vault is re-issued at the new version.
//
// Every item the revoked identity could read is flagged ENTRY_EXPOSED, which
// password health turns into "change this password at the site": rotation
// protects what is written next, never what was already read.
// ---------------------------------------------------------------------------

acct_revoke :: proc(a: ^Acct, share_id: string) -> (rotated: int, err: string) {
	if err = acct_connect(a); err != "" {
		return
	}
	rep: Sync_Report
	if err = acct_pull(a, &rep); err != "" {
		return
	}
	open_vault_keys(a)
	var_s: ^S_Row
	for &s in a.cache.shares {
		if s.id == share_id {
			var_s = &s
		}
	}
	if var_s == nil {
		return 0, "no such share"
	}
	s := var_s^
	if my_keys(a, s.identity_id) == nil {
		return 0, "only the identity that made a share can revoke it"
	}
	o := ck.obj()
	ck.put(&o, "revoked_at", time_iso(now_unix()))
	upd, e := ck.update(a.client, "vault_shares", fmt.tprintf("id=eq.%s&revoked_at=is.null", s.id), ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return 0, ck_err("revoking", e)
	}
	if len(ck.array(upd)) == 0 {
		return 0, "the share was already revoked"
	}
	var_s.revoked = true

	if s.item_id != "" {
		rotated, err = rotate_item(a, s.item_id)
	} else {
		rotated, err = rotate_vault(a, s.vault_id)
	}
	if err != "" {
		return
	}
	if err = acct_push(a, &rep); err != "" {
		return
	}
	err = refresh_after(a)
	return
}

// The live shares of an item (or of a vault, item_id ""), other than revoked.
live_shares :: proc(a: ^Acct, vault_id, item_id: string) -> []S_Row {
	out := make([dynamic]S_Row, context.temp_allocator)
	for s in a.cache.shares {
		if !s.revoked && s.vault_id == vault_id && s.item_id == item_id {
			append(&out, s)
		}
	}
	return out[:]
}

// reissue revokes `s` and makes the same share again, with `key` at `version`.
reissue :: proc(a: ^Acct, s: S_Row, key: []byte, version: int) -> string {
	pk, ok := public_keys_of(a, s.grantee)
	if !ok {
		return fmt.tprintf("cannot re-share with %s: its keys are unknown", handle_of(a, s.grantee))
	}
	o := ck.obj()
	ck.put(&o, "revoked_at", time_iso(now_unix()))
	if _, e := ck.update(a.client, "vault_shares", fmt.tprintf("id=eq.%s", s.id), ck.obj_done(&o), context.temp_allocator); !ck.ok(e) {
		return ck_err("retiring a share for rotation", e)
	}
	return insert_share(a, s.identity_id, s.vault_id, s.item_id, s.grantee, s.role, version, key, &pk)
}

// decrypt_for_rewrite opens an item this device owns, for re-encryption.
decrypt_for_rewrite :: proc(a: ^Acct, item_id: string) -> (e: Entry, ok: bool) {
	r := item_row(a, item_id)
	if p := pending_of(a, item_id); p != nil {
		r = &p.row
	}
	if r == nil || r.deleted {
		return {}, false
	}
	e, _, _, ok = decrypt_row(a, r)
	return
}

rotate_item :: proc(a: ^Acct, item_id: string) -> (int, string) {
	e, ok := decrypt_for_rewrite(a, item_id)
	if !ok {
		return 0, "the item to rotate could not be opened"
	}
	defer entry_free(&e)
	r := item_row(a, item_id)
	e.flags |= ENTRY_EXPOSED
	if err := acct_put(a, &e, r.vault_id, new_item_key = true); err != "" {
		return 0, err
	}
	rep: Sync_Report
	if err := acct_push(a, &rep); err != "" {
		return 0, err
	}
	r = item_row(a, item_id)
	key: [KEY_LEN]byte
	defer crypto.zero_explicit(&key, size_of(key))
	if _, _, kok := item_key_of(a, r, &key); !kok {
		return 0, "the rotated item key did not open"
	}
	for s in live_shares(a, r.vault_id, item_id) {
		if err := reissue(a, s, key[:], r.key_version); err != "" {
			return 1, err
		}
	}
	return 1, ""
}

rotate_vault :: proc(a: ^Acct, vault_id: string) -> (int, string) {
	v := vault_row(a, vault_id)
	if v == nil {
		return 0, "no such vault"
	}
	me := my_keys(a, v.identity_id)
	if me == nil {
		return 0, "this device does not hold the vault owner's keys"
	}
	// Open every live item under the old keys before anything changes.
	entries := make([dynamic]Entry, context.temp_allocator)
	for &r in a.cache.items {
		if r.vault_id != vault_id || r.deleted {
			continue
		}
		if e, ok := decrypt_for_rewrite(a, r.id); ok {
			e.flags |= ENTRY_EXPOSED
			append(&entries, e)
		}
	}
	defer for &e in entries {
		entry_free(&e)
	}

	newkey: [KEY_LEN]byte
	defer crypto.zero_explicit(&newkey, size_of(newkey))
	crypto.rand_bytes(newkey[:])
	version := v.key_version + 1
	sealed, ok := seal_to(&me.pub, newkey[:], aad_vault_key(vault_id, version, v.identity_id), context.temp_allocator)
	if !ok {
		return 0, "the new vault key could not be sealed"
	}
	name, color := vault_label(a, vault_id)
	meta := meta_encode(Vault_Meta{name, color, "lock"}, context.temp_allocator)
	mw := wrap(newkey[:], meta, aad_vault_meta(vault_id), context.temp_allocator)
	o := ck.obj()
	ck.put(&o, "key_wrap", b64(sealed, context.temp_allocator))
	ck.put(&o, "key_version", i64(version))
	ck.put(&o, "meta", b64(mw, context.temp_allocator))
	ck.put(&o, "revision", v.revision + 1)
	upd, e := ck.update(a.client, "vault_vaults", fmt.tprintf("id=eq.%s&key_version=eq.%d", vault_id, v.key_version), ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) || len(ck.array(upd)) == 0 {
		return 0, ck_err("rotating the vault key", e)
	}
	v^ = v_from(a, ck.array(upd)[0])
	vk := Vkey{vault_id = vs(a, vault_id), version = version, viewer = vs(a, v.identity_id), role = "owner"}
	vk.key = newkey
	vk.kid = key_id(vk.key[:])
	append(&a.vkeys, vk)

	for &e in entries {
		if err := acct_put(a, &e, vault_id, new_item_key = true); err != "" {
			return 0, err
		}
	}
	rep: Sync_Report
	if err := acct_push(a, &rep); err != "" {
		return 0, err
	}
	for s in live_shares(a, vault_id, "") {
		if err := reissue(a, s, newkey[:], version); err != "" {
			return len(entries), err
		}
	}
	// Item shares inside the vault: their items have new keys now.
	for &e in entries {
		r := item_row(a, e.id)
		if r == nil {
			continue
		}
		key: [KEY_LEN]byte
		if _, _, kok := item_key_of(a, r, &key); kok {
			for s in live_shares(a, vault_id, e.id) {
				reissue(a, s, key[:], r.key_version)
			}
		}
		crypto.zero_explicit(&key, size_of(key))
	}
	return len(entries), ""
}

// ---------------------------------------------------------------------------
// Changing the master password
//
// The account key does not change; only its wrap does, on every identity's
// keyset row, under a new salt. Needs the person's unscoped session, because
// a device scoped to one identity cannot rewrite the others' rows, and a
// change that reached only some of them would leave the account with two
// master passwords.
// ---------------------------------------------------------------------------

acct_change_password :: proc(a: ^Acct, new_password: string) -> string {
	if !a.unlocked {
		return "the vault is locked"
	}
	if len(new_password) < 8 {
		return "a master password shorter than 8 characters is not worth encrypting anything with"
	}
	if err := acct_connect(a); err != "" {
		return err
	}
	if ck.scoped(a.client) {
		return "changing the master password needs the person's own session, not one scoped to an identity"
	}
	salt: [SALT_LEN]byte
	crypto.rand_bytes(salt[:])
	auk: [KEY_LEN]byte
	defer crypto.zero_explicit(&auk, size_of(auk))
	if !derive_auk(new_password, a.secret[:], salt[:], KDF_DEFAULT, a.cache.user_id, auk[:]) {
		return "the key could not be derived"
	}
	akw := b64(wrap(auk[:], a.account_key[:], aad_account_key(), context.temp_allocator), context.temp_allocator)
	for &k in a.cache.keysets {
		o := ck.obj()
		ck.put(&o, "kdf_salt", b64(salt[:], context.temp_allocator))
		ck.put(&o, "kdf_m", i64(KDF_DEFAULT.m))
		ck.put(&o, "kdf_t", i64(KDF_DEFAULT.t))
		ck.put(&o, "kdf_p", i64(KDF_DEFAULT.par))
		ck.put(&o, "account_key_wrap", akw)
		ck.put(&o, "key_epoch", i64(k.key_epoch + 1))
		if _, e := ck.update(a.client, "vault_keysets", fmt.tprintf("identity_id=eq.%s", k.identity_id), ck.obj_done(&o), context.temp_allocator); !ck.ok(e) {
			return ck_err("re-wrapping the account key", e)
		}
	}
	return refresh_after(a)
}
