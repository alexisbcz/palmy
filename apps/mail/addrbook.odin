// Address autocomplete: the names you have already written to.
//
// WHERE THE NAMES COME FROM. Every address in the mailbox on disk — From, To,
// Cc and Reply-To of every message that was scanned — and nothing else. There
// is no system address book here, no contacts file, no LDAP and no network
// lookup; a mail client that guesses addresses out of somewhere the user did
// not put them is a mail client that leaks who they know. The book is rebuilt
// whenever the mailbox is rescanned, which costs one pass over messages that
// are already in memory.
//
// HOW IT RANKS. By how often an address appears, then by how recently. That
// is a count of messages, not of sends, which is the honest signal a Maildir
// can give: the people whose names come up are the people in your mail.
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

Contact :: struct {
	name:  string,
	email: string,
	key:   string, // "name email", lowercased, for matching
	count: int,
	last:  time.Time,
}

AC_MAX :: 6 // suggestions shown at once

// ---------------------------------------------------------------------------
// Building the book
// ---------------------------------------------------------------------------

free_book :: proc(st: ^State) {
	for c in st.book {
		delete(c.name)
		delete(c.email)
		delete(c.key)
	}
	clear(&st.book)
}

build_address_book :: proc(st: ^State) {
	free_book(st)
	at := make(map[string]int, 256, context.temp_allocator)

	add :: proc(st: ^State, at: ^map[string]int, a: Address, when_: time.Time) {
		if a.email == "" || strings.index_byte(a.email, '@') <= 0 {
			return
		}
		k := strings.to_lower(a.email, context.temp_allocator)
		if i, found := at[k]; found {
			st.book[i].count += 1
			if when_._nsec > st.book[i].last._nsec {
				st.book[i].last = when_
			}
			// A later message with a real display name beats an earlier one
			// that had only the bare address.
			if st.book[i].name == "" && a.name != "" {
				delete(st.book[i].name)
				delete(st.book[i].key)
				st.book[i].name = strings.clone(a.name)
				st.book[i].key = strings.to_lower(tfmt("%s %s", a.name, a.email))
			}
			return
		}
		at[strings.clone(k, context.temp_allocator)] = len(st.book)
		append(
			&st.book,
			Contact {
				name = strings.clone(a.name),
				email = strings.clone(a.email),
				key = strings.to_lower(tfmt("%s %s", a.name, a.email)),
				count = 1,
				last = when_,
			},
		)
	}

	for m in st.messages {
		add(st, &at, m.from, m.date)
		add(st, &at, m.reply_to, m.date)
		for a in m.to {
			add(st, &at, a, m.date)
		}
		for a in m.cc {
			add(st, &at, a, m.date)
		}
	}
	// The accounts themselves, so writing to your own other address works
	// before anything has ever been sent from it.
	for a in st.accounts {
		add(st, &at, Address{name = a.name, email = a.address}, time.Time{})
	}

	slice.sort_by(st.book[:], proc(a, b: Contact) -> bool {
		if a.count != b.count {
			return a.count > b.count
		}
		if a.last._nsec != b.last._nsec {
			return a.last._nsec > b.last._nsec
		}
		return a.email < b.email
	})
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

// ac_fragment is the piece of an address field being completed: everything
// after the last comma, which is how every address field in every mail client
// behaves. The comparison is on the text up to the caret, so completing in the
// middle of a list completes the address the caret is in.
ac_fragment :: proc(text: string, caret: int) -> string {
	cut := clamp(caret, 0, len(text))
	head := text[:cut]
	if i := strings.last_index_byte(head, ','); i >= 0 {
		head = head[i + 1:]
	}
	return strings.trim_space(head)
}

// ac_committed is the field with the fragment under the caret taken out: the
// addresses that are already there, which are the ones not worth suggesting.
ac_committed :: proc(text: string, caret: int, allocator := context.temp_allocator) -> string {
	cut := clamp(caret, 0, len(text))
	start := 0
	if i := strings.last_index_byte(text[:cut], ','); i >= 0 {
		start = i + 1
	}
	return fmt.aprintf("%s %s", text[:start], text[cut:], allocator = allocator)
}

// ac_match ranks the book against a fragment. A prefix of the address, of the
// local part, or of any word of the display name counts as a strong match and
// comes first; a substring anywhere counts as a weak one and comes after.
// Addresses already in the field are left out — suggesting somebody who is
// already a recipient is noise.
ac_match :: proc(st: ^State, frag: string, already: string, allocator := context.temp_allocator) -> []int {
	out := make([dynamic]int, 0, AC_MAX, allocator)
	if len(frag) < 1 {
		return out[:]
	}
	q := strings.to_lower(frag, context.temp_allocator)
	have := strings.to_lower(already, context.temp_allocator)

	strong := make([dynamic]int, 0, AC_MAX, context.temp_allocator)
	weak := make([dynamic]int, 0, AC_MAX, context.temp_allocator)
	for c, i in st.book {
		mail := strings.to_lower(c.email, context.temp_allocator)
		// `already` is the committed part of the field — everything except the
		// fragment being typed, which the caller takes out before calling, so
		// that typing the first letters of an address does not count as having
		// already entered it.
		if mail != "" && strings.contains(have, mail) {
			continue
		}
		if ac_is_prefix_match(c, q) {
			append(&strong, i)
			continue
		}
		if strings.contains(c.key, q) {
			append(&weak, i)
		}
	}
	for i in strong {
		if len(out) >= AC_MAX {
			return out[:]
		}
		append(&out, i)
	}
	for i in weak {
		if len(out) >= AC_MAX {
			return out[:]
		}
		append(&out, i)
	}
	return out[:]
}

ac_is_prefix_match :: proc(c: Contact, q: string) -> bool {
	mail := strings.to_lower(c.email, context.temp_allocator)
	if strings.has_prefix(mail, q) {
		return true
	}
	if at := strings.index_byte(mail, '@'); at > 0 && strings.has_prefix(mail[at + 1:], q) {
		return true
	}
	name := strings.to_lower(c.name, context.temp_allocator)
	if strings.has_prefix(name, q) {
		return true
	}
	// Any word of the display name: "grace" should find "Grace Hopper", and
	// so should "hopper".
	rest := name
	for {
		sp := strings.index_byte(rest, ' ')
		if sp < 0 {
			break
		}
		rest = rest[sp + 1:]
		if strings.has_prefix(rest, q) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Driving it from the composer
// ---------------------------------------------------------------------------

ac_close :: proc(c: ^Composer) {
	c.ac_open = false
	c.ac_sel = 0
	delete(c.ac_prefix)
	c.ac_prefix = ""
	clear(&c.ac_hits)
}

ac_field :: proc(c: ^Composer) -> ^Line_Edit {
	#partial switch c.field {
	case .To:
		return &c.to
	case .Cc:
		return &c.cc
	}
	return nil
}

// ac_update recomputes the suggestion list after a keystroke. It runs on every
// edit of an address field and nowhere else.
ac_update :: proc(st: ^State) {
	c := &st.comp
	e := ac_field(c)
	if e == nil {
		ac_close(c)
		return
	}
	text := le_text(e)
	frag := ac_fragment(text, e.cur)
	if frag == "" {
		ac_close(c)
		return
	}
	hits := ac_match(st, frag, ac_committed(text, e.cur), context.temp_allocator)
	if len(hits) == 0 {
		ac_close(c)
		return
	}
	clear(&c.ac_hits)
	for h in hits {
		append(&c.ac_hits, h)
	}
	delete(c.ac_prefix)
	c.ac_prefix = strings.clone(frag)
	c.ac_sel = clamp(c.ac_sel, 0, len(c.ac_hits) - 1)
	if !c.ac_open {
		c.ac_sel = 0
	}
	c.ac_open = true
}

// ac_accept writes the chosen address over the fragment and leaves the caret
// after a ", ", ready for the next one.
ac_accept :: proc(st: ^State) -> bool {
	c := &st.comp
	e := ac_field(c)
	if e == nil || !c.ac_open || len(c.ac_hits) == 0 {
		ac_close(c)
		return false
	}
	idx := c.ac_hits[clamp(c.ac_sel, 0, len(c.ac_hits) - 1)]
	if idx < 0 || idx >= len(st.book) {
		ac_close(c)
		return false
	}
	chosen := format_address(
		Address{name = st.book[idx].name, email = st.book[idx].email},
		context.temp_allocator,
	)

	text := le_text(e)
	cut := clamp(e.cur, 0, len(text))
	start := 0
	if i := strings.last_index_byte(text[:cut], ','); i >= 0 {
		start = i + 1
	}
	before := strings.trim_right_space(text[:start]) // the addresses already there
	// Anything past the caret, without the comma this completion is about to
	// write for itself — otherwise completing in the middle of a list leaves
	// ", ," behind.
	after := strings.trim_left(strings.trim_left_space(text[cut:]), ", ")

	b := strings.builder_make(context.temp_allocator)
	if before != "" {
		strings.write_string(&b, before)
		strings.write_byte(&b, ' ')
	}
	strings.write_string(&b, chosen)
	strings.write_string(&b, ", ")
	caret := len(strings.to_string(b))
	strings.write_string(&b, after)

	out := strings.to_string(b)
	le_set(e, out)
	e.cur = min(caret, len(out))
	ac_close(c)
	return true
}
