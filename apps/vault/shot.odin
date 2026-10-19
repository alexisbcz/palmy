package main

// `vault --shot <dir>`: render the screens offscreen as PNGs, light and dark.
//
// No compositor, no window, no server: the same `frame` the window runs,
// through palmy's offscreen renderer, over an account vault built offline in
// a scratch directory under <dir>. Everything in it is invented: example.*
// domains, generated passwords, the RFC 6238 seed for the one-time codes. The
// share from Bob is real cryptography -- his own keys, sealed and signed --
// so the "shared by" line in the picture is the code path a real share takes.

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import kit "kit:."
import p "palmy:."

SHOT_PASSWORD :: "shot-fixture-password"

@(private = "file")
SHOT_KDF :: Kdf {
	m   = 64,
	t   = 1,
	par = 1,
}

@(private = "file")
shot_ident :: proc(a: ^Acct, id, handle, name, kind, color: string) {
	append(&a.cache.idents, Ident{cs(a, id), cs(a, handle), cs(a, name), cs(a, kind), cs(a, color)})
}

// shot_acct builds an enrolled, synced-looking account on disk, offline.
@(private = "file")
shot_acct :: proc(dir: string, user: string, idents: [][5]string) -> ^Acct {
	_ = os.remove_all(dir)
	a := acct_open(dir)
	cache_reset(a)
	a.have_cache = true
	a.cache.user_id = cs(a, user)
	a.cache.email = cs(a, "alice@example.test")
	for i in idents {
		shot_ident(a, i[0], i[1], i[2], i[3], i[4])
	}
	crypto.rand_bytes(a.secret[:])
	a.has_secret = true
	crypto.rand_bytes(a.account_key[:])
	salt: [SALT_LEN]byte
	crypto.rand_bytes(salt[:])
	auk: [KEY_LEN]byte
	derive_auk(SHOT_PASSWORD, a.secret[:], salt[:], SHOT_KDF, a.cache.user_id, auk[:])
	a.unlocked = true
	for &id in a.cache.idents {
		row, _ := new_keyset_row(a, id.id, auk[:], salt[:], SHOT_KDF)
		append(&a.cache.keysets, row)
		vrow, _ := new_vault_row(a, id.id, default_vault_name(&id), id.color)
		append(&a.cache.vaults, vrow)
	}
	device_save(a)
	cache_save(a)
	return a
}

@(private = "file")
shot_item :: proc(a: ^Acct, src: int, title, user, url: string, kind := Item_Kind.Login) -> ^Entry {
	e := new(Entry)
	e^ = entry_new(title)
	e.kind = kind
	replace_string(&e.username, user)
	replace_string(&e.url, url)
	if kind == .Login {
		pw, _ := gen_password(GEN_DEFAULT, context.temp_allocator)
		entry_set_password(e, pw)
	}
	return e
}

@(private = "file")
put :: proc(a: ^Acct, src: int, e: ^Entry) {
	acct_put(a, e, a.sources[src].vault_id)
	entry_free(e)
	free(e)
}

shots :: proc(dir: string) -> int {
	if err := os.make_directory_all(dir, os.perm(0o700)); err != nil && !os.exists(dir) {
		fmt.eprintfln("vault: could not create %s", dir)
		return 1
	}
	n := 0
	for dark in ([2]bool{false, true}) {
		n += shot_set(dir, dark)
	}
	fmt.printfln("vault --shot: %d PNGs in %s", n, dir)
	return 0
}

// shot_fixture lays down Alice's account: her personal and work identities,
// items of every kind, a few that password health should complain about, and
// one login Bob (another account) shares with her.
@(private = "file")
shot_fixture :: proc(store: string) -> ^Acct {
	alice := shot_acct(fmt.tprintf("%s/alice", store), "a11ce000-0000-4000-8000-000000000001", {
		{"a1111111-0000-4000-8000-000000000001", "alice", "Alice Martin", "personal", "indigo"},
		{"a2222222-0000-4000-8000-000000000002", "alice-work", "Alice (Northwind)", "work", "emerald"},
	})
	bob := shot_acct(fmt.tprintf("%s/bob", store), "b0b00000-0000-4000-8000-000000000001", {
		{"b1111111-0000-4000-8000-000000000001", "bob", "Bob Lee", "personal", "amber"},
	})
	v := Vault{entries = make([dynamic]Entry)}
	acct_entries(alice, &v)
	vault_free(&v)
	acct_entries(bob, &v)
	vault_free(&v)

	seed := base32_encode(transmute([]u8)string(RFC6238_SEED_SHA1), context.temp_allocator)
	// Personal (source 0)
	e := shot_item(alice, 0, "GitHub", "alice-martin", "https://github.com")
	replace_secret(&e.totp, seed)
	e.favorite = true
	entry_set_tags(e, "dev")
	append(&e.urls, strings.clone("https://gist.github.com"))
	put(alice, 0, e)
	e = shot_item(alice, 0, "Example Bank", "alice-0042", "https://bank.example.org")
	e.favorite = true
	entry_set_tags(e, "money")
	replace_secret(&e.notes, "Branch: Rue de la Paix. The card is under Cards.")
	put(alice, 0, e)
	e = shot_item(alice, 0, "Visa Debit", "", "", .Card)
	field_set(e, "Cardholder", "Alice Martin", false)
	field_set(e, "Number", "4111111111111111", true)
	field_set(e, "Expiry", "12/2030", false)
	field_set(e, "Security code", "123", true)
	entry_set_tags(e, "money")
	put(alice, 0, e)
	e = shot_item(alice, 0, "Passport", "", "", .Document)
	field_set(e, "Document", "Passport", false)
	field_set(e, "Number", "X0000000", true)
	field_set(e, "Full name", "Alice Martin", false)
	field_set(e, "Issued by", "Example Republic", false)
	field_set(e, "Expires", "2031-04-30", false)
	put(alice, 0, e)
	e = shot_item(alice, 0, "Home Wi-Fi", "", "", .Note)
	replace_secret(&e.notes, "Network: example-home\nPassphrase is on the sticker under the router.")
	put(alice, 0, e)
	e = shot_item(alice, 0, "Example Passkeys", "alice", "https://passkeys.example.com", .Passkey)
	e.passkey = Passkey {
		credential_id = strings.clone("q8Z7cFkN3xLmP0aR"),
		rp_id = strings.clone("passkeys.example.com"),
		rp_name = strings.clone("Example Passkeys"),
		user_name = strings.clone("alice"),
		key = strings.clone("fixture-not-a-key"),
		counter = 12,
		discoverable = true,
		created = now_unix() - 86400 * 40,
	}
	put(alice, 0, e)
	e = shot_item(alice, 0, "Old Forum", "alice_m", "https://forum.example.net")
	entry_set_password(e, "Summer2024!")
	e.modified = now_unix() - 86400 * 900
	put(alice, 0, e)
	e = shot_item(alice, 0, "Recipe Site", "alice_m", "https://recipes.example.org")
	entry_set_password(e, "Summer2024!")
	e.flags |= ENTRY_EXPOSED
	put(alice, 0, e)
	// Work (source 1)
	e = shot_item(alice, 1, "Northwind VPN", "alice.martin", "https://vpn.northwind.example")
	replace_secret(&e.totp, seed)
	entry_set_tags(e, "infra")
	put(alice, 1, e)
	e = shot_item(alice, 1, "Northwind Tracker", "alice.martin@northwind.example", "https://tracker.northwind.example")
	put(alice, 1, e)
	e = shot_item(alice, 1, "Cloud Console", "alice.martin", "https://console.cloud.example")
	field_set(e, "Account ID", "4402-1177-9031", false)
	put(alice, 1, e)
	for &p in alice.cache.pending {
		upsert_item(alice, p.row)
	}
	clear(&alice.cache.pending)

	// Bob's login, shared with Alice's personal identity: his keys, his seal,
	// his signature.
	be := shot_item(bob, 0, "Streaming (family)", "bob.lee@example.test", "https://stream.example.tv")
	be.kind = .Login
	bid := strings.clone(be.id, context.temp_allocator)
	put(bob, 0, be)
	r := &bob.cache.pending[0].row
	key: [KEY_LEN]byte
	item_key_of(bob, r, &key)
	alice_id := alice.cache.idents[0].id
	apub, _ := public_keys_of(alice, alice_id)
	sealed, _ := seal_to(&apub, key[:], aad_item_share(bid, alice_id), context.temp_allocator)
	sid := "5a5a5a5a-0000-4000-8000-000000000001"
	src_id := r.identity_id
	sig := sign_bytes(my_keys(bob, src_id), share_transcript(sid, src_id, r.vault_id, bid, alice_id, "read", 1, sealed))
	append(&alice.cache.items, I_Row{cs(alice, r.id), cs(alice, r.identity_id), cs(alice, r.vault_id), 1, 1, cs(alice, r.key_wrap), cs(alice, r.blob), false})
	ks := keyset_of(bob, src_id)
	append(&alice.cache.pins, Pin{cs(alice, src_id), cs(alice, "bob"), cs(alice, "Bob Lee"), cs(alice, ks.enc_pub), cs(alice, ks.kem_pub), cs(alice, ks.sign_pub)})
	append(&alice.cache.shares, S_Row{cs(alice, sid), cs(alice, src_id), cs(alice, r.vault_id), cs(alice, bid), cs(alice, alice_id), cs(alice, "read"), 1, cs(alice, b64(sealed, context.temp_allocator)), cs(alice, b64(sig[:], context.temp_allocator)), false})
	// And Alice shares GitHub with her work identity: a share row of her own.
	crypto.zero_explicit(&key, size_of(key))
	alice.cache.synced_at = now_unix()
	cache_save(alice)
	acct_close(bob)
	acct_lock(alice)
	return alice
}

@(private = "file")
shot_set :: proc(dir: string, dark: bool) -> int {
	store := strings.clone(fmt.tprintf("%s/.store-%s", dir, dark ? "dark" : "light"))
	_ = os.make_directory_all(store, os.perm(0o700))
	acct := shot_fixture(store)

	off := p.offscreen_create(WIN_W, WIN_H, 1, "w-full h-full flex-col bg-background text-foreground overflow-hidden")
	defer p.offscreen_destroy(off)
	shot_fonts(off, dark)

	st := st_new(strings.clone(fmt.tprintf("%s/unused.pvz", store)))
	st.mode = .Account
	st.acct = acct
	st.screen = .Unlock
	st.have_clip = true
	st.dark = dark
	st.idle_limit = 300
	st.clip_limit = 20
	defer shutdown(&st)

	suffix := dark ? "-dark" : ""
	count := 0
	step :: proc(off: ^p.Offscreen, st: ^St) {
		ui := p.offscreen_begin(off)
		frame(ui, nil, st)
		p.offscreen_end(off)
	}
	// Enough frames for every `transition` to finish: a picture taken mid-fade
	// shows two rows selected.
	settle :: proc(off: ^p.Offscreen, st: ^St) {
		for _ in 0 ..< 24 {
			step(off, st)
		}
	}
	// The pointer rests on the footer, so no row is caught mid-hover.
	p.move_pointer(off, 6, WIN_H - 6)
	shot :: proc(off: ^p.Offscreen, dir, name, suffix: string, n: ^int) {
		out := fmt.tprintf("%s/%s%s.png", dir, name, suffix)
		if p.offscreen_write_png(off, out) {
			n^ += 1
			fmt.printfln("  %s", out)
		}
	}
	select :: proc(st: ^St, title: string) {
		for r, i in st.rows {
			if st.v.entries[r].title == title {
				st.sel = i
			}
		}
	}

	settle(off, &st)
	p.type_text(off, SHOT_PASSWORD)
	settle(off, &st)
	shot(off, dir, "vault-locked", suffix, &count)

	p.press_key(off, p.KEY_RETURN)
	step(off, &st)
	step(off, &st)
	st.busy = .None // no server here: skip the sync that follows an unlock
	if st.sync_msg != "" {
		delete(st.sync_msg)
	}
	st.sync_msg = strings.clone("synced 09:41")
	settle(off, &st)
	select(&st, "GitHub")
	settle(off, &st)
	shot(off, dir, "vault-login", suffix, &count)

	select(&st, "Visa Debit")
	settle(off, &st)
	shot(off, dir, "vault-card", suffix, &count)

	select(&st, "Example Passkeys")
	settle(off, &st)
	shot(off, dir, "vault-passkey", suffix, &count)

	// Bob's share, under Alice's "Shared with me".
	for s, i in st.acct.sources {
		if s.kind == .Shared_Items {
			st.nav = {kind = .Source, src = i}
		}
	}
	settle(off, &st)
	select(&st, "Streaming (family)")
	settle(off, &st)
	shot(off, dir, "vault-shared", suffix, &count)

	// The work identity's vault.
	st.nav = {kind = .Source, src = 1}
	settle(off, &st)
	select(&st, "Northwind VPN")
	settle(off, &st)
	shot(off, dir, "vault-work", suffix, &count)

	st.nav = {kind = .Health}
	st.health_ok = false
	settle(off, &st)
	shot(off, dir, "vault-health", suffix, &count)

	st.nav = {}
	settle(off, &st)
	select(&st, "GitHub")
	settle(off, &st)
	st.share_open = true
	set_buf(&st.share_with, "bob")
	settle(off, &st)
	shot(off, dir, "vault-share", suffix, &count)
	st.share_open = false

	st.af.prompt = Af_Prompt {
		kind     = .Fill,
		conn     = -1,
		client   = strings.clone("Palmy Browser"),
		exe      = strings.clone("/usr/bin/browser"),
		pid      = 4242,
		origin   = strings.clone("https://github.com"),
		identity = strings.clone("alice"),
		item_id  = strings.clone(current(&st).id),
		title    = strings.clone("GitHub"),
		username = strings.clone("alice-martin"),
	}
	settle(off, &st)
	shot(off, dir, "vault-autofill", suffix, &count)
	af_prompt_clear(&st.af.prompt)
	st.af.prompt = Af_Prompt {
		kind   = .Pair,
		conn   = -1,
		client = strings.clone("Palmy Browser"),
		exe    = strings.clone("/usr/bin/browser"),
		pid    = 4242,
		code   = strings.clone("318 907"),
	}
	settle(off, &st)
	shot(off, dir, "vault-pair", suffix, &count)
	af_prompt_clear(&st.af.prompt)

	bw := fmt.tprintf("%s/bitwarden-export.json", store)
	_ = os.write_entire_file(bw, #load("testdata/bitwarden.json"))
	begin_import(&st, bw)
	settle(off, &st)
	shot(off, dir, "vault-import", suffix, &count)
	import_result_free(&st.imp)
	st.imp_open = false

	begin_edit(&st, true, .Card)
	set_buf(&st.ed[.Title], "Travel card")
	if len(st.ed_kv) >= 3 {
		set_buf(&st.ed_kv[0].buf, "Alice Martin")
		set_buf(&st.ed_kv[1].buf, "5555444433331111")
		set_buf(&st.ed_kv[2].buf, "09/2029")
	}
	settle(off, &st)
	shot(off, dir, "vault-new-card", suffix, &count)
	cancel_edit(&st)

	p.press_key(off, 'g', {.Ctrl})
	settle(off, &st)
	shot(off, dir, "vault-generator", suffix, &count)
	p.press_key(off, p.KEY_ESCAPE)
	settle(off, &st)

	clear_clipboard(&st, "")
	lock(&st, "Locked")
	settle(off, &st)
	_ = kit.FONT_DIR
	return count
}

// shot_fonts loads exactly what `kit.start` gives a window, into the
// offscreen font table: a screenshot in a different face proves nothing.
shot_fonts :: proc(off: ^p.Offscreen, dark: bool) {
	for pair in ([?]struct {
		file: string,
		wt:   p.Font_Weight,
	}{
		{"Geist-400.ttf", .Regular},
		{"Geist-500.ttf", .Medium},
		{"Geist-600.ttf", .Semibold},
		{"Geist-700.ttf", .Bold},
	}) {
		p.load_font(&off.fonts, fmt.tprintf("%s/%s", kit.FONT_DIR, pair.file), .Sans, pair.wt)
	}
	for wt in p.Font_Weight {
		p.use_synthetic_italic(&off.fonts, .Sans, wt)
	}
	for path in ([?]string {
		"/usr/share/fonts/TTF/JetBrainsMonoNerdFont-Regular.ttf",
		"/usr/share/fonts/TTF/DejaVuSansMono.ttf",
		"/usr/share/fonts/liberation/LiberationMono-Regular.ttf",
	}) {
		if p.load_font(&off.fonts, path, .Mono, .Regular) {
			p.load_font(&off.fonts, path, .Mono, .Medium)
			p.load_font(&off.fonts, path, .Mono, .Semibold)
			p.load_font(&off.fonts, path, .Mono, .Bold)
			break
		}
	}
	register_theme(dark)
}
