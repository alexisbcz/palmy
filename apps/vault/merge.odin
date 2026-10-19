package main

// Conflicts, one item at a time.
//
// Two devices edit the same item while one is offline. The server takes the
// first write; the second comes back as a conflict (vault_put_item's
// compare-and-swap) carrying the server's revision. The losing device holds
// three versions: the one both started from (the base, its last synced copy),
// its own, and the server's. merge3 combines them field by field:
//
//   - a field only one side changed takes that side's value;
//   - a field both changed to the same value takes it;
//   - a field both changed differently takes the side with the later
//     `modified` time -- and if that field is the password, the other side's
//     password goes into the history, so no password anyone saved is lost.
//     That is the rule a password manager cannot break: a site may already
//     have accepted the losing password.
//   - tags, URLs and custom fields merge as sets: additions from either side
//     are kept, a removal on one side wins over "unchanged" on the other.
//   - histories are unioned.
//
// The result is a new revision on top of the server's, so the next push
// cannot conflict with what was merged.

import "core:slice"
import "core:strings"

merge3 :: proc(base, ours, theirs: ^Entry) -> (out: Entry, conflicted: bool) {
	// Start from theirs: it is what the server has, and what every other
	// device will converge on.
	out = entry_clone(theirs)
	ours_newer := ours.modified > theirs.modified

	pick :: proc(dst: ^string, b, o, t: string, ours_newer: bool, secret: bool) -> bool {
		if o == t || o == b {
			return false // theirs already in place
		}
		if t == b {
			replace_value(dst, o, secret)
			return false
		}
		// Both changed, differently.
		if ours_newer {
			replace_value(dst, o, secret)
		}
		return true
	}

	c := false
	c |= pick(&out.title, base.title, ours.title, theirs.title, ours_newer, false)
	c |= pick(&out.username, base.username, ours.username, theirs.username, ours_newer, false)
	c |= pick(&out.url, base.url, ours.url, theirs.url, ours_newer, false)
	c |= pick(&out.notes, base.notes, ours.notes, theirs.notes, ours_newer, true)
	c |= pick(&out.totp, base.totp, ours.totp, theirs.totp, ours_newer, true)

	// The password, with nothing lost.
	pw_c := pick(&out.password, base.password, ours.password, theirs.password, ours_newer, true)
	c |= pw_c
	if pw_c {
		loser := ours_newer ? theirs.password : ours.password
		append(&out.history, Hist{when_ = min(ours.modified, theirs.modified), password = strings.clone(loser)})
	}
	// Histories: everything either side remembers.
	for h in ours.history {
		if !has_hist(out.history[:], h) {
			append(&out.history, Hist{h.when_, strings.clone(h.password)})
		}
	}
	slice.sort_by(out.history[:], proc(x, y: Hist) -> bool {return x.when_ < y.when_})
	for len(out.history) > MAX_HISTORY {
		wipe_string(out.history[0].password)
		ordered_remove(&out.history, 0)
	}

	if ours.kind != base.kind && theirs.kind == base.kind {
		out.kind = ours.kind
	}
	if ours.favorite != base.favorite && theirs.favorite == base.favorite {
		out.favorite = ours.favorite
	}
	out.flags = theirs.flags | ours.flags
	if ours.totp_digits != base.totp_digits && theirs.totp_digits == base.totp_digits {
		out.totp_digits = ours.totp_digits
	}
	if ours.totp_period != base.totp_period && theirs.totp_period == base.totp_period {
		out.totp_period = ours.totp_period
	}
	if ours.totp_algo != base.totp_algo && theirs.totp_algo == base.totp_algo {
		out.totp_algo = ours.totp_algo
	}

	merge_set(&out.tags, base.tags[:], ours.tags[:])
	merge_set(&out.urls, base.urls[:], ours.urls[:])

	// Custom fields by label.
	for f in ours.fields {
		bv, in_base := kv_find(base.fields[:], f.label)
		tv, in_theirs := kv_find(theirs.fields[:], f.label)
		switch {
		case !in_theirs && !in_base:
			append(&out.fields, Kv{strings.clone(f.label), strings.clone(f.value), f.secret})
		case in_theirs && f.value != tv && (tv == bv || (in_base && f.value != bv && ours_newer)):
			field_set(&out, f.label, f.value, f.secret)
			c |= in_base && tv != bv
		}
	}
	for f in base.fields {
		_, in_ours := kv_find(ours.fields[:], f.label)
		tv, in_theirs := kv_find(theirs.fields[:], f.label)
		if !in_ours && in_theirs && tv == f.value {
			kv_remove(&out.fields, f.label)
		}
	}

	if ours.passkey.credential_id != base.passkey.credential_id && theirs.passkey.credential_id == base.passkey.credential_id {
		passkey_free(&out.passkey)
		out.passkey = passkey_clone(ours.passkey)
	}
	out.passkey.counter = max(ours.passkey.counter, theirs.passkey.counter)

	out.modified = max(ours.modified, theirs.modified)
	out.created = min(ours.created, theirs.created)
	return out, c
}

replace_value :: proc(dst: ^string, s: string, secret: bool) {
	if secret {
		wipe_string(dst^)
	} else {
		delete(dst^)
	}
	dst^ = strings.clone(s)
}

has_hist :: proc(hs: []Hist, h: Hist) -> bool {
	for x in hs {
		if x.when_ == h.when_ && secret_eq(x.password, h.password) {
			return true
		}
	}
	return false
}

// merge_set applies our additions and removals (relative to base) to `dst`,
// which starts as theirs.
merge_set :: proc(dst: ^[dynamic]string, base, ours: []string) {
	contains :: proc(xs: []string, s: string) -> bool {
		for x in xs {
			if x == s {
				return true
			}
		}
		return false
	}
	for o in ours {
		if !contains(base, o) && !contains(dst[:], o) {
			append(dst, strings.clone(o))
		}
	}
	for b in base {
		if !contains(ours, b) {
			for i := 0; i < len(dst); i += 1 {
				if dst[i] == b {
					delete(dst[i])
					ordered_remove(dst, i)
					break
				}
			}
		}
	}
}

kv_find :: proc(xs: []Kv, label: string) -> (string, bool) {
	for x in xs {
		if x.label == label {
			return x.value, true
		}
	}
	return "", false
}

kv_remove :: proc(xs: ^[dynamic]Kv, label: string) {
	for i := 0; i < len(xs); i += 1 {
		if xs[i].label == label {
			delete(xs[i].label)
			wipe_string(xs[i].value)
			ordered_remove(xs, i)
			return
		}
	}
}
