// Bookmark sync through the Palmy account (apps/cloudkit).
//
// One round is push, then pull:
//
//   push  every local record changed since the last push goes to
//         browser_merge_bookmarks(target, items), which folds it in on the
//         server with the same per-field-group rule the client uses
//         (cloud/supabase/migrations/20261019400000_browser_bookmarks.sql);
//   pull  every row whose server `seq` is past the last one seen comes back
//         and is merged locally.
//
// Both halves are idempotent, so a round interrupted anywhere is simply run
// again. The session is the one cloudkit holds for this profile's identity
// (PALM_IDENTITY=<handle>): it is scoped, so a work window's sync can neither
// read nor write a personal bookmark -- the database refuses, which the pgTAP
// test cloud/supabase/tests/browser_bookmarks.sql asserts.
package browser

import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"
import ck "../cloudkit"

Sync_Result :: struct {
	ok:      bool,
	message: string,
	pushed:  int,
	pulled:  int,
	merged:  int,
}

PUSH_BATCH :: 200

sync_bookmarks :: proc(b: ^Bookmarks, identity: string) -> (r: Sync_Result) {
	c, err := ck.open(scope = identity, app = "browser")
	defer ck.close(c)
	if !ck.ok(err) {
		r.message = fmt.aprintf("cannot open the account: %s", err.message)
		return
	}
	if !ck.signed_in(c) {
		r.message = fmt.aprintf("not signed in for %s: sign in with the accounts app first", identity)
		return
	}
	if e := ck.ensure_fresh(c); !ck.ok(e) {
		r.message = fmt.aprintf("the session could not be refreshed: %s", e.message)
		return
	}
	ids, ierr := ck.identities(c, context.temp_allocator)
	if !ck.ok(ierr) {
		r.message = fmt.aprintf("cannot list identities: %s", ierr.message)
		return
	}
	ident, found := ck.find_identity(ids, identity)
	if !found {
		r.message = fmt.aprintf("the account has no identity %q visible to this session", identity)
		return
	}

	// push
	pend := pending(b, context.temp_allocator)
	high := b.file.pushed_through
	for start := 0; start < len(pend); start += PUSH_BATCH {
		batch := pend[start:min(start + PUSH_BATCH, len(pend))]
		items, merr := json.marshal(batch, {}, context.temp_allocator)
		if merr != nil {
			r.message = "could not encode bookmarks"
			return
		}
		args := strings.concatenate({`{"target":`, ck.quote(ident.id), `,"items":`, string(items), "}"}, context.temp_allocator)
		_, e := ck.rpc(c, "browser_merge_bookmarks", args, context.temp_allocator)
		if !ck.ok(e) {
			r.message = fmt.aprintf("push failed: %s", e.message)
			return
		}
		for &x in batch {
			high = clock_max(high, record_clock(&x))
		}
		r.pushed += len(batch)
	}
	mark_pushed(b, high)

	// pull
	for {
		q := fmt.tprintf("select=*&identity_id=eq.%s&seq=gt.%d&order=seq.asc&limit=500", ident.id, b.file.pulled_seq)
		v, e := ck.select(c, "browser_bookmarks", q, context.temp_allocator)
		if !ck.ok(e) {
			r.message = fmt.aprintf("pull failed: %s", e.message)
			return
		}
		rows := ck.array(v)
		if len(rows) == 0 {
			break
		}
		incoming := make([dynamic]Bookmark, context.temp_allocator)
		for row in rows {
			append(
				&incoming,
				Bookmark {
					id = ck.get_str(row, "id"),
					kind = ck.get_str(row, "kind"),
					parent = ck.get_str(row, "parent_id"),
					position = ck.get_str(row, "position"),
					title = ck.get_str(row, "title"),
					url = ck.get_str(row, "url"),
					deleted = ck.get_bool(row, "deleted"),
					content_clock = ck.get_str(row, "content_clock"),
					place_clock = ck.get_str(row, "place_clock"),
					life_clock = ck.get_str(row, "life_clock"),
				},
			)
			seq := ck.get_int(row, "seq")
			if seq > b.file.pulled_seq {
				b.file.pulled_seq = seq
			}
		}
		r.merged += merge(b, incoming[:])
		r.pulled += len(rows)
		b.dirty = true
		if len(rows) < 500 {
			break
		}
	}
	// what was just pulled is, by definition, on the server already
	for &x in b.file.items {
		if !strings.has_suffix(x.life_clock, "-root") {
			high = clock_max(high, record_clock(&x))
		}
	}
	if len(pending(b, context.temp_allocator)) == 0 || r.pulled > 0 {
		mark_pushed(b, high)
	}
	r.ok = true
	r.message = fmt.aprintf("sent %d, received %d (%d merged)", r.pushed, r.pulled, r.merged)
	return
}

sync_now :: proc(s: ^State) {
	s.sync_busy = true
	r := sync_bookmarks(&s.bookmarks, s.prof.identity)
	s.sync_busy = false
	if s.bookmarks.dirty {
		bookmarks_save(&s.bookmarks)
	}
	delete(s.sync_status)
	s.sync_status = r.message
	toast(s, r.ok ? "Bookmarks synced" : "Sync failed")
}

@(private = "file")
_unused :: strconv.Int_Flag
