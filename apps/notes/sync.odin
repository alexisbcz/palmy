// Sync: the files on this device, the CRDT copy beside them, and the cloud.
//
// Each note in a bound identity folder has three representations:
//
//	the file          ~/Notes/<handle>/Travel/lisbon.md — what people and other
//	                  tools read and write; the truth for *local* edits
//	the local copy    .palm/sync/<identity>/<note>.state — the note's CRDT, the
//	                  last server sequence it saw, and the edits not yet
//	                  acknowledged (cloud/collab/client: the offline outbox)
//	the cloud         the collab document's update log, ordered by palm-collab
//
// One pass for one identity:
//
//	1. ask the database for the identity's notes and the head of each log
//	   (notes_sync_state: owned and shared, one round trip);
//	2. carries made offline are recorded first (notes_carry), so their copies
//	   are created by the carry, not as unrelated new notes;
//	3. every file that changed since the last pass is diffed into its CRDT
//	   (diff.odin), which queues operations in the outbox — this works with
//	   the network gone, and is the whole of "offline";
//	4. every note whose file changed, whose outbox is not empty, or whose
//	   cloud head is past what this device saw, gets a short session with the
//	   sync server: it catches up, the outbox goes out, the CRDT merges;
//	5. the merged CRDT is written back to the file — renamed if the title
//	   changed, moved if another device filed it elsewhere or trashed it;
//	6. notes deleted for good elsewhere, and shares that were revoked, are
//	   removed from this device.
//
// Two devices that edited the same note offline therefore never produce a
// "conflicted copy": each one's characters are elements in the same sequence,
// and the merge is the CRDT's, the same one the office suite is fuzzed on.
//
// A window holding a note open has its own live session for it, so it asks
// the pass to skip that note (`--skip`); everything else is done here, by the
// same code for the window and for `notes sync`.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:crypto/sha2"
import ck "../cloudkit"
import client "../../cloud/collab/client"
import crdt "../../cloud/collab/crdt"

// ---------------------------------------------------------------------------
// The account
// ---------------------------------------------------------------------------

Acct :: struct {
	c:     ^ck.Client,
	ok:    bool, // signed in and the server answered
	err:   string,
	kind:  ck.Error_Kind,
	ids:   []ck.Identity,
}

acct_open :: proc() -> (a: Acct) {
	c, e := ck.open(app = "notes")
	a.c = c
	if !ck.ok(e) {
		a.err = e.message
		a.kind = e.kind
		return
	}
	if !ck.signed_in(c) {
		a.err = "not signed in"
		a.kind = .Not_Signed_In
		return
	}
	if fe := ck.ensure_fresh(c); !ck.ok(fe) {
		a.err = fe.message
		a.kind = fe.kind
		return
	}
	ids, ie := ck.identities(c)
	if !ck.ok(ie) {
		a.err = ie.message
		a.kind = ie.kind
		return
	}
	a.ids = ids
	a.ok = true
	return
}

acct_close :: proc(a: ^Acct) {
	if a.ids != nil {
		ck.identities_free(a.ids)
	}
	if a.c != nil {
		ck.close(a.c)
	}
	a^ = {}
}

// enroll makes sure every identity the session can act for has a bound
// folder on this device. A scoped session enrols its one identity.
enroll :: proc(a: ^Acct) -> (added: int) {
	if !a.ok {
		return 0
	}
	if os.get_env("PALMY_NOTES_DIR", context.temp_allocator) != "" {
		return 0
	}
	home := notes_home(context.temp_allocator)
	for id in a.ids {
		if id.archived {
			continue
		}
		root := fmt.tprintf("%s/%s", home, id.handle)
		cur := ident_read(root, id.handle)
		defer ident_free(&cur)
		if cur.id == id.id && cur.name == id.display_name && cur.color == id.color {
			continue
		}
		if cur.id == "" {
			added += 1
		}
		os.make_directory_all(root)
		ident_bind(root, id.id, id.handle, id.display_name, id.color, id.kind)
	}
	return
}

// ---------------------------------------------------------------------------
// The index: what the last pass saw of each note
// ---------------------------------------------------------------------------

Index_Entry :: struct {
	rel:    string, // where the file was
	hash:   u64, // of the whole file as last written or read by sync
	remote: bool, // the cloud has it (so its absence later means it was deleted)
	access: string, // owner, read or edit
	owner:  string, // the owning identity's handle, for shared notes
}

Index :: map[string]Index_Entry

index_path :: proc(root: string) -> string {
	return fmt.tprintf("%s/.palm/index.tsv", root)
}

index_load :: proc(root: string, allocator := context.allocator) -> Index {
	idx := make(Index, 16, allocator)
	data, err := os.read_entire_file_from_path(index_path(root), context.temp_allocator)
	if err != nil {
		return idx
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 6 || !is_uuid(f[0]) {
			continue
		}
		h, _ := strconv.parse_u64(f[2], 16)
		idx[strings.clone(f[0], allocator)] = Index_Entry {
			rel    = strings.clone(f[1], allocator),
			hash   = h,
			remote = f[3] == "1",
			access = strings.clone(f[4], allocator),
			owner  = strings.clone(f[5], allocator),
		}
	}
	return idx
}

index_save :: proc(root: string, idx: Index) {
	os.make_directory_all(fmt.tprintf("%s/.palm", root))
	b := strings.builder_make(context.temp_allocator)
	for id, e in idx {
		fmt.sbprintf(&b, "%s\t%s\t%x\t%s\t%s\t%s\n", id, e.rel, e.hash, e.remote ? "1" : "0", e.access, e.owner)
	}
	tmp := fmt.tprintf("%s.tmp", index_path(root))
	if os.write_entire_file(tmp, transmute([]u8)strings.to_string(b)) == nil {
		os.rename(tmp, index_path(root))
	}
}

// ---------------------------------------------------------------------------
// Local CRDT copies
// ---------------------------------------------------------------------------

sync_dir :: proc(root: string) -> string {
	return fmt.tprintf("%s/.palm/sync", root)
}

state_file :: proc(root, identity_id, note_id: string) -> string {
	return fmt.tprintf("%s/%s/%s.state", sync_dir(root), identity_id, note_id)
}

// state_peek reads the header of a local copy: the last server sequence it
// applied and how many edits wait in its outbox, without loading the CRDT.
state_peek :: proc(path: string) -> (last_seq: u64, outbox: int, exists: bool) {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil || len(data) < 5 || string(data[:4]) != "PCS1" {
		return 0, 0, false
	}
	i := 4
	uv :: proc(b: []u8, i: ^int) -> u64 {
		v: u64
		shift: u64
		for i^ < len(b) {
			c := b[i^]
			i^ += 1
			v |= u64(c & 0x7f) << shift
			if c & 0x80 == 0 {
				break
			}
			shift += 7
		}
		return v
	}
	last_seq = uv(data, &i)
	_ = uv(data, &i)
	outbox = int(uv(data, &i))
	return last_seq, outbox, true
}

// ---------------------------------------------------------------------------
// One pass
// ---------------------------------------------------------------------------

Sync_Opts :: struct {
	offline: bool, // queue only: do not talk to the network
	skip:    string, // a note id a window holds open with its own session
	wait:    time.Duration, // how long one note may take to settle
	device:  string,
}

Sync_Result :: struct {
	handle:   string,
	online:   bool,
	pushed:   int, // notes whose local edits went out (or were queued, offline)
	pulled:   int, // notes that changed here because of another device or person
	created:  int, // notes this device created in the cloud
	arrived:  int, // notes that appeared here from elsewhere
	removed:  int, // deleted elsewhere, or a share that was revoked
	queued:   int, // edits waiting in an outbox for the network
	readonly: int, // edits to a read-only shared note that were not kept
	events:   [dynamic]string,
	error:    string,
}

Remote :: struct {
	id, title, notebook, access, owner_id, owner_handle, owner_name, owner_color: string,
	tags:    [dynamic]string,
	pinned:  bool,
	trashed: string,
	head:    u64,
}

event :: proc(r: ^Sync_Result, format: string, args: ..any) {
	append(&r.events, fmt.aprintf(format, ..args))
}

// sync_ident runs one pass for one bound identity folder.
sync_ident :: proc(a: ^Acct, id: Ident, opts: Sync_Opts) -> (r: Sync_Result) {
	r.handle = id.handle
	r.events = make([dynamic]string)
	if !ident_bound(id) {
		r.error = "this folder is not bound to a cloud identity"
		return
	}
	root := id.root
	wait := opts.wait != 0 ? opts.wait : 8 * time.Second
	online := !opts.offline && a.ok

	// 1. What the cloud has.
	remotes := make(map[string]Remote, 16, context.temp_allocator)
	if online {
		args := fmt.tprintf(`{{"p_identity":"%s"}}`, id.id)
		v, e := ck.rpc(a.c, "notes_sync_state", args, context.temp_allocator)
		if !ck.ok(e) {
			online = false
			if e.kind != .Unavailable {
				r.error = fmt.aprintf("%s", e.message)
			}
		} else {
			for row in ck.array(v) {
				rm := Remote {
					id           = ck.get_str(row, "id"),
					title        = ck.get_str(row, "title"),
					notebook     = ck.get_str(row, "notebook"),
					access       = ck.get_str(row, "access"),
					owner_id     = ck.get_str(row, "owner_identity"),
					owner_handle = ck.get_str(row, "owner_handle"),
					owner_name   = ck.get_str(row, "owner_name"),
					owner_color  = ck.get_str(row, "owner_color"),
					pinned       = ck.get_bool(row, "pinned"),
					trashed      = ck.is_null(row, "trashed_at") ? "" : ck.get_str(row, "trashed_at"),
					head         = u64(ck.get_int(row, "head_seq")),
				}
				rm.tags = make([dynamic]string, context.temp_allocator)
				if arr, ok := ck.get(row, "tags").(json.Array); ok {
					for t in arr {
						if s, ok2 := t.(json.String); ok2 {
							append(&rm.tags, s)
						}
					}
				}
				remotes[rm.id] = rm
			}
		}
	}
	r.online = online

	idx := index_load(root, context.temp_allocator)
	cfg_host, cfg_port := client.server_address()

	// 2. Carries recorded offline.
	pending := carries_pending_load(root)
	still := make([dynamic]Pending_Carry, context.temp_allocator)
	for pc in pending {
		if !online {
			append(&still, pc)
			continue
		}
		res, err := carry_record(a, pc, opts.device)
		if err != "" {
			append(&still, pc)
			event(&r, "carry of %q from %s is still waiting: %s", pc.title, pc.from_handle, err)
			continue
		}
		_ = res
		e := idx[pc.new_id]
		e.remote = true
		e.access = "owner"
		idx[pc.new_id] = e
		event(&r, "recorded the carry of %q from %s", pc.title, pc.from_handle)
	}
	carries_pending_save(root, still[:])
	waiting := make(map[string]bool, 4, context.temp_allocator)
	for pc in still {
		waiting[pc.new_id] = true
	}

	// 3. The files as they are now.
	notes := store_load(root)
	defer notes_free(&notes)
	seen := make(map[string]bool, len(notes), context.temp_allocator)
	for &n in notes {
		if n.meta.id == "" || !is_uuid(n.meta.id) || seen[n.meta.id] {
			// A file someone dropped into the folder, or a copy of another
			// note's file: it becomes a note of its own.
			if n.shared {
				continue
			}
			delete(n.meta.id)
			n.meta.id = new_id()
			store_write_meta(n.path, n.meta)
			event(&r, "gave %q an id", n.title)
		}
		seen[n.meta.id] = true
	}

	session_cfg :: proc(root, host: string, port: int, id: Ident, note, token: string, online: bool) -> client.Config {
		return client.Config {
			host = host,
			port = port,
			doc_id = note,
			as_id = id.id,
			token = token,
			app = "notes",
			dir = sync_dir(root),
			offline = !online,
		}
	}
	token := a.ok ? a.c.session.access_token : ""

	// 4 and 5, for every note that is here.
	for &n in notes {
		nid := n.meta.id
		if nid == opts.skip {
			continue
		}
		entry, known := idx[nid]
		rm, in_cloud := remotes[nid]
		data, _ := os.read_entire_file_from_path(n.path, context.temp_allocator)
		text := string(data)
		// A move (another notebook, the trash) changes where the file is and
		// not what is in it, so the path counts as much as the bytes.
		changed := !known || entry.hash != fnv(text) || entry.rel != n.rel
		access := in_cloud ? rm.access : (known ? entry.access : "owner")
		if n.shared && access == "owner" {
			access = n.meta.access != "" ? n.meta.access : "read"
		}
		regranted := known && entry.access != "" && entry.access != access

		if online && !in_cloud && known && entry.remote {
			// Gone from the cloud: deleted for good on another device, or a
			// share that was revoked. Either way it leaves this device.
			os.remove(n.path)
			os.remove(state_file(root, id.id, nid))
			delete_key(&idx, nid)
			r.removed += 1
			if access == "owner" {
				event(&r, "%q was deleted on another device", n.title)
			} else {
				event(&r, "%s stopped sharing %q", entry.owner, n.title)
			}
			continue
		}
		if waiting[nid] {
			continue // its carry is not recorded yet; it is created by that
		}

		last, outbox, _ := state_peek(state_file(root, id.id, nid))
		behind := in_cloud && rm.head > last
		if !changed && outbox == 0 && !behind && !regranted {
			continue
		}
		if regranted {
			event(&r, "%q is now shared with you to %s", n.title, access)
		}

		if online && !in_cloud && access == "owner" {
			o := ck.obj()
			ck.put(&o, "p_id", nid)
			ck.put(&o, "p_identity", id.id)
			ck.put(&o, "p_title", n.title)
			ck.put(&o, "p_notebook", n.trashed ? "" : n.notebook)
			_, ce := ck.rpc(a.c, "notes_create", ck.obj_done(&o), context.temp_allocator)
			if !ck.ok(ce) {
				event(&r, "could not create %q in the cloud: %s", n.title, ce.message)
				continue
			}
			r.created += 1
		}

		s := client.session_open(session_cfg(root, cfg_host, cfg_port, id, nid, token, online))
		before := doc_body(s.doc, context.allocator)
		before_meta := doc_meta(s.doc)
		ingested := false
		if changed {
			if access == "read" {
				if known {
					r.readonly += 1
					event(&r, "%q is shared with you to read; your edit to it was not kept", n.title)
				}
			} else {
				crdt.begin(s.doc)
				ingested = doc_set_body(s.doc, n.body)
				if access == "owner" {
					m := Doc_Meta {
						notebook = n.notebook,
						tags     = tags_join(n.meta.tags[:]),
						pinned   = n.meta.pinned,
						trashed  = n.trashed ? (before_meta.trashed != "" ? before_meta.trashed : iso_now()) : "",
					}
					ingested = doc_set_meta(s.doc, m) || ingested
				}
				crdt.commit(s.doc)
				if client.flush(s) {
					r.pushed += 1
				}
			}
		}
		settled := !online || settle(s, wait)
		if online && !settled {
			event(&r, "%q did not finish syncing: %s", n.title, s.error != "" ? s.error : "the sync server did not answer in time")
		}
		if client.pending_count(s) > 0 {
			r.queued += 1
		}
		after := doc_body(s.doc)
		if after != before && after != n.body {
			r.pulled += 1
		}
		delete(before)
		owner_handle := in_cloud ? rm.owner_handle : entry.owner
		new_rel, written := materialise(root, s.doc, &n, nid, access, owner_handle)
		client.session_close(s)

		e := Index_Entry {
			rel    = strings.clone(new_rel, context.temp_allocator),
			hash   = fnv(written),
			remote = in_cloud || (online && settled),
			access = access,
			owner  = owner_handle,
		}
		idx[nid] = e
		if online && access == "owner" && settled {
			mirror(a, nid, root, new_rel, in_cloud ? &rm : nil)
		}
	}

	// Notes the cloud has and this device does not: from another device, or
	// shared with this identity.
	if online {
		for nid, rm in remotes {
			if seen[nid] || nid == opts.skip {
				continue
			}
			if rm.access == "owner" && rm.head == 0 {
				continue // created but never written: nothing to show yet
			}
			s := client.session_open(session_cfg(root, cfg_host, cfg_port, id, nid, token, true))
			ok := settle(s, wait)
			if !ok {
				event(&r, "could not fetch %q: %s", rm.title, s.error)
				client.session_close(s)
				continue
			}
			n := Note{}
			new_rel, written := materialise(root, s.doc, &n, nid, rm.access, rm.owner_handle)
			got_title := title_of(doc_body(s.doc), context.temp_allocator)
			client.session_close(s)
			idx[strings.clone(nid, context.temp_allocator)] = Index_Entry {
				rel    = strings.clone(new_rel, context.temp_allocator),
				hash   = fnv(written),
				remote = true,
				access = rm.access,
				owner  = rm.owner_handle,
			}
			r.arrived += 1
			if rm.access == "owner" {
				event(&r, "%q arrived from another device", got_title)
			} else {
				event(&r, "%s shared %q with you (%s)", rm.owner_name, rm.title, rm.access)
			}
		}
		// Index entries for notes whose files are gone here and in the cloud.
		for nid, e in idx {
			if !seen[nid] && !(nid in remotes) && e.remote {
				delete_key(&idx, nid)
			}
		}
		attachments_sync(a, id, root, &r)
	}
	index_save(root, idx)
	return
}

// settle runs a session until it is caught up and everything it sent is
// acknowledged, or until `wait` runs out.
settle :: proc(s: ^client.Session, wait: time.Duration) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < wait {
		client.poll(s)
		if s.status == .Refused {
			return false
		}
		if s.status == .Live && client.pending_count(s) == 0 {
			// One more poll: anything that raced the ack is applied too.
			time.sleep(15 * time.Millisecond)
			client.poll(s)
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// materialise writes the CRDT's state back to the note's file and returns
// where the file now is and exactly what was written.
materialise :: proc(root: string, d: ^crdt.Doc, n: ^Note, nid, access, owner: string) -> (rel: string, written: string) {
	body := doc_body(d)
	dm := doc_meta(d)
	meta := Meta{}
	if n.path != "" {
		meta = meta_clone(n.meta, context.temp_allocator)
	}
	meta.id = nid
	folder: string
	if access == "owner" {
		clear(&meta.tags)
		for t in tags_split(dm.tags) {append(&meta.tags, t)}
		meta.pinned = dm.pinned
		meta.shared_from = ""
		meta.access = ""
		folder = dm.notebook
		if dm.trashed != "" {
			folder = dm.notebook == "" ? TRASH_DIR : fmt.tprintf("%s/%s", TRASH_DIR, dm.notebook)
		}
	} else {
		meta.shared_from = owner
		meta.access = access
		folder = fmt.tprintf("%s/%s", SHARED_DIR, owner)
	}
	written = compose(meta, body)
	dir := folder == "" ? root : fmt.tprintf("%s/%s", root, folder)
	os.make_directory_all(dir)
	title := title_of(body, context.temp_allocator)
	want := unique_path(dir, slug(title), n.path)

	if n.path != "" && want == n.path {
		if old, err := os.read_entire_file_from_path(n.path, context.temp_allocator); err == nil && string(old) == written {
			return strings.trim_prefix(strings.trim_prefix(want, root), "/"), written
		}
	}
	if n.path != "" {
		os.chmod(n.path, os.perm_number(0o644))
	}
	if os.write_entire_file(want, transmute([]u8)written) == nil {
		if n.path != "" && n.path != want {
			os.remove(n.path)
		}
		if access == "read" {
			os.chmod(want, os.perm_number(0o444))
		}
	}
	return strings.trim_prefix(strings.trim_prefix(want, root), "/"), written
}

iso_now :: proc() -> string {
	now := time.now()
	y, mo, d := time.date(now)
	h, mi, s := time.clock(now)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// mirror updates the server-visible metadata row after the owner synced, so
// a new device can list titles before it fetches anything and a grantee's
// list says what the note is called.
mirror :: proc(a: ^Acct, nid, root, rel: string, rm: ^Remote) {
	data, err := os.read_entire_file_from_path(fmt.tprintf("%s/%s", root, rel), context.temp_allocator)
	if err != nil {
		return
	}
	n := note_from_text("", rel, string(data), {})
	defer note_free(n)
	if rm != nil && rm.title == n.title && rm.notebook == n.notebook && rm.pinned == n.meta.pinned &&
	   (rm.trashed != "") == n.trashed && tags_join(rm.tags[:]) == tags_join(n.meta.tags[:]) {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"title":`)
	json_q(&b, n.title)
	strings.write_string(&b, `,"notebook":`)
	json_q(&b, n.notebook)
	strings.write_string(&b, `,"pinned":`)
	strings.write_string(&b, n.meta.pinned ? "true" : "false")
	strings.write_string(&b, `,"tags":[`)
	for t, i in n.meta.tags {
		if i > 0 {strings.write_byte(&b, ',')}
		json_q(&b, t)
	}
	strings.write_string(&b, `],"trashed_at":`)
	if n.trashed {
		json_q(&b, rm != nil && rm.trashed != "" ? rm.trashed : iso_now())
	} else {
		strings.write_string(&b, "null")
	}
	strings.write_byte(&b, '}')
	ck.update(a.c, "notes", fmt.tprintf("id=eq.%s", nid), strings.to_string(b), context.temp_allocator)
}

// ---------------------------------------------------------------------------
// Carry
// ---------------------------------------------------------------------------

Pending_Carry :: struct {
	new_id, from_id, from_handle, to_handle, hash, title: string,
	bytes: int,
}

carries_path :: proc(root: string) -> string {
	return fmt.tprintf("%s/.palm/carries.tsv", root)
}

carries_pending_load :: proc(root: string) -> []Pending_Carry {
	out := make([dynamic]Pending_Carry, context.temp_allocator)
	data, err := os.read_entire_file_from_path(carries_path(root), context.temp_allocator)
	if err != nil {
		return out[:]
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 7 {
			continue
		}
		n, _ := strconv.parse_int(f[6])
		append(&out, Pending_Carry{f[0], f[1], f[2], f[3], f[4], f[5], n})
	}
	return out[:]
}

carries_pending_save :: proc(root: string, xs: []Pending_Carry) {
	if len(xs) == 0 {
		os.remove(carries_path(root))
		return
	}
	os.make_directory_all(fmt.tprintf("%s/.palm", root))
	b := strings.builder_make(context.temp_allocator)
	for pc in xs {
		fmt.sbprintf(&b, "%s\t%s\t%s\t%s\t%s\t%s\t%d\n", pc.new_id, pc.from_id, pc.from_handle, pc.to_handle, pc.hash, pc.title, pc.bytes)
	}
	_ = os.write_entire_file(carries_path(root), transmute([]u8)strings.to_string(b))
}

// carry_record writes the carry into the account: the copy's note row in
// the target identity and the log row on each side, in one transaction.
carry_record :: proc(a: ^Acct, pc: Pending_Carry, device: string) -> (res: ck.Value, err: string) {
	o := ck.obj()
	ck.put(&o, "p_note", pc.from_id)
	ck.put(&o, "p_to", pc.to_handle)
	ck.put(&o, "p_new", pc.new_id)
	ck.put(&o, "p_hash", pc.hash)
	ck.put(&o, "p_title", pc.title)
	ck.put(&o, "p_bytes", i64(pc.bytes))
	ck.put(&o, "p_device", device != "" ? device : ck.machine_name())
	v, e := ck.rpc(a.c, "notes_carry", ck.obj_done(&o), context.temp_allocator)
	if !ck.ok(e) {
		return nil, fmt.tprintf("%s", e.message)
	}
	return v, ""
}

sha256_hex :: proc(s: string, allocator := context.temp_allocator) -> string {
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]u8)s)
	sum: [32]u8
	sha2.final(&ctx, sum[:])
	b := strings.builder_make(allocator)
	for x in sum {
		fmt.sbprintf(&b, "%02x", x)
	}
	return strings.to_string(b)
}

// ---------------------------------------------------------------------------
// Attachments: files under attachments/, content-addressed in Storage
// ---------------------------------------------------------------------------

Pending_Attach :: struct {
	note, sha, name, file: string,
	size: i64,
}

attach_queue_path :: proc(root: string) -> string {
	return fmt.tprintf("%s/.palm/attachments.tsv", root)
}

attach_queue_load :: proc(root: string) -> [dynamic]Pending_Attach {
	out := make([dynamic]Pending_Attach, context.temp_allocator)
	data, err := os.read_entire_file_from_path(attach_queue_path(root), context.temp_allocator)
	if err != nil {
		return out
	}
	rest := string(data)
	for line in strings.split_lines_iterator(&rest) {
		f := strings.split(line, "\t", context.temp_allocator)
		if len(f) < 5 {
			continue
		}
		n, _ := strconv.parse_i64(f[4])
		append(&out, Pending_Attach{f[0], f[1], f[2], f[3], n})
	}
	return out
}

attach_queue_save :: proc(root: string, xs: []Pending_Attach) {
	if len(xs) == 0 {
		os.remove(attach_queue_path(root))
		return
	}
	os.make_directory_all(fmt.tprintf("%s/.palm", root))
	b := strings.builder_make(context.temp_allocator)
	for x in xs {
		fmt.sbprintf(&b, "%s\t%s\t%s\t%s\t%d\n", x.note, x.sha, x.name, x.file, x.size)
	}
	_ = os.write_entire_file(attach_queue_path(root), transmute([]u8)strings.to_string(b))
}

attach_file_name :: proc(sha, name: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf("%s-%s", sha[:12], name, allocator = allocator)
}

// attachments_sync uploads what was attached here and fetches what notes
// here link to but this device does not have.
attachments_sync :: proc(a: ^Acct, id: Ident, root: string, r: ^Sync_Result) {
	queue := attach_queue_load(root)
	still := make([dynamic]Pending_Attach, context.temp_allocator)
	for x in queue {
		path := fmt.tprintf("%s/%s/%s", root, ATTACH_DIR, x.file)
		ue := ck.upload_file(a.c, "notes", fmt.tprintf("%s/%s", id.id, x.sha), path)
		if !ck.ok(ue) && ue.kind != .Conflict && ue.status != 409 && ue.status != 400 {
			append(&still, x)
			continue
		}
		o := ck.obj()
		ck.put(&o, "note_id", x.note)
		ck.put(&o, "identity_id", id.id)
		ck.put(&o, "sha256", x.sha)
		ck.put(&o, "name", x.name)
		ck.put(&o, "size", x.size)
		ck.put(&o, "mime", ck.guess_content_type(x.name))
		_, ie := ck.insert(a.c, "note_attachments", ck.obj_done(&o), context.temp_allocator)
		if !ck.ok(ie) && ie.kind != .Conflict {
			append(&still, x)
			continue
		}
		event(r, "uploaded the attachment %s", x.name)
	}
	attach_queue_save(root, still[:])

	// Rows this identity can read (its own notes' and shared notes'), fetched
	// when the file is missing here.
	v, e := ck.select(a.c, "note_attachments", "select=note_id,identity_id,sha256,name", context.temp_allocator)
	if !ck.ok(e) {
		return
	}
	for row in ck.array(v) {
		sha := ck.get_str(row, "sha256")
		name := ck.get_str(row, "name")
		owner := ck.get_str(row, "identity_id")
		if owner != id.id && !shared_here(root, ck.get_str(row, "note_id")) {
			continue
		}
		dest := fmt.tprintf("%s/%s/%s", root, ATTACH_DIR, attach_file_name(sha, name))
		if os.exists(dest) {
			continue
		}
		os.make_directory_all(fmt.tprintf("%s/%s", root, ATTACH_DIR))
		if de := ck.download_file(a.c, "notes", fmt.tprintf("%s/%s", owner, sha), dest); ck.ok(de) {
			event(r, "fetched the attachment %s", name)
		}
	}
}

@(private = "file")
shared_here :: proc(root, note: string) -> bool {
	idx := index_load(root, context.temp_allocator)
	e, ok := idx[note]
	return ok && e.access != "owner"
}
