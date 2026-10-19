// The notification itself, and the store that holds them.
//
// Everything here is pure: no sockets, no clock of its own, no files. The
// daemon (daemon.odin) owns one Store and feeds it what arrives; the
// self-test drives the same procedures with a fixed clock. Times are unix
// milliseconds, passed in.
package main

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

// Class is *who* is behind a notification (cloud/docs/product.md §8). It
// decides the default far more than urgency does.
Class :: enum u8 {
	Person, // a message addressed to you, a mention, a call
	Time, // an event starting, a task due, an alarm
	Machine, // newsletters, receipts, CI, sync, updates, downloads
}

Urgency :: enum u8 {
	Low,
	Normal,
	Critical,
}

// Delivery is what the policy decided when the notification arrived.
Delivery :: enum u8 {
	Toast, // interrupts: a toast, and a sound when allowed
	Center, // silently into the center (and Today)
	Digest, // held for the identity's digest
}

Source :: enum u8 {
	Native, // apps/kit/notify.odin over the socket
	Fdo, // org.freedesktop.Notifications on the session bus
	Cli, // `notify send`
	System, // the daemon's own: digests
}

Action :: struct {
	key:   string, // "default" is the click on the body itself
	label: string,
	run:   string, // a deep link, run as the notification's identity: "mail open <id>"
}

Note :: struct {
	id:          u32, // this daemon's number; also the fdo id
	key:         string, // stable across apps: the same object, the same key
	app:         string, // "mail", "Chromium"
	identity:    string, // a handle; "" when nobody could say
	class:       Class,
	urgency:     Urgency,
	category:    string, // fdo-style: "call.incoming", "email.arrived", "im.received"
	title:       string,
	body:        string,
	link:        string, // what a click on the body runs
	actions:     [dynamic]Action,
	source:      Source,
	created:     i64,
	updated:     i64,
	timeout_ms:  int, // 0: by class
	delivery:    Delivery,
	why:         string, // the sentence that decided it, said to a person
	sound:       bool,
	showing:     bool, // on screen as a toast right now
	held:        bool, // waiting in a digest
	daily:       bool, // held for the daily digest, not for quiet or do-not-disturb
	digest:      string, // the digest's key, once it went out in one
	read:        bool,
	fdo_sender:  string, // the bus name that sent it, for ActionInvoked
	is_digest:   bool,
	count:       int, // a digest: how many it carries
}

// The key space is shared by every app, which is what makes "delivered once"
// work across them: mail and Home announcing the same message both say
// `mail:<Message-ID>`, and the second is an update, not a second toast. A
// key that was dismissed is remembered (a tombstone) for TOMBSTONE_MS, so a
// sender that repeats itself is not heard twice.
TOMBSTONE_MS :: i64(7 * 24 * 3600 * 1000)
HISTORY_MAX :: 400
HISTORY_MS :: i64(14 * 24 * 3600 * 1000)

Store :: struct {
	notes:      [dynamic]^Note,
	next_id:    u32,
	tombstones: map[string]i64, // key -> forgotten after
	rev:        u64, // bumped on every change; watchers re-read on it
	dnd:        bool, // the whole person, every identity
	dnd_until:  i64, // 0: until turned off
	policies:   [dynamic]Policy,
}

class_name :: proc(c: Class) -> string {
	switch c {
	case .Person:
		return "person"
	case .Time:
		return "time"
	case .Machine:
		return "machine"
	}
	return "person"
}

class_parse :: proc(s: string) -> (Class, bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "person", "people", "p":
		return .Person, true
	case "time", "t", "reminder":
		return .Time, true
	case "machine", "m":
		return .Machine, true
	}
	return .Person, false
}

urgency_name :: proc(u: Urgency) -> string {
	switch u {
	case .Low:
		return "low"
	case .Normal:
		return "normal"
	case .Critical:
		return "critical"
	}
	return "normal"
}

urgency_parse :: proc(s: string) -> (Urgency, bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "low", "0":
		return .Low, true
	case "normal", "1", "":
		return .Normal, true
	case "critical", "2", "high":
		return .Critical, true
	}
	return .Normal, false
}

delivery_name :: proc(d: Delivery) -> string {
	switch d {
	case .Toast:
		return "toast"
	case .Center:
		return "center"
	case .Digest:
		return "digest"
	}
	return "center"
}

source_name :: proc(s: Source) -> string {
	switch s {
	case .Native:
		return "native"
	case .Fdo:
		return "fdo"
	case .Cli:
		return "cli"
	case .System:
		return "system"
	}
	return "native"
}

// is_call and is_alarm are the two kinds that may break through a quiet
// identity or do-not-disturb, and only when its policy says so.
is_call :: proc(n: ^Note) -> bool {
	return strings.has_prefix(n.category, "call.incoming") || (n.class == .Person && n.urgency == .Critical && n.category == "")
}

is_alarm :: proc(n: ^Note) -> bool {
	return n.category == "alarm" || strings.has_prefix(n.category, "alarm.") || (n.class == .Time && n.urgency == .Critical)
}

// class_for_category is how a notification from an application that knows
// nothing about classes (anything speaking org.freedesktop.Notifications)
// gets one. The categories are the freedesktop list.
class_for_category :: proc(cat: string, urgency: Urgency) -> Class {
	switch {
	case strings.has_prefix(cat, "call."), strings.has_prefix(cat, "im."), cat == "email.arrived", cat == "x-palm.mention":
		return .Person
	case strings.has_prefix(cat, "alarm"), strings.has_prefix(cat, "x-palm.reminder"), strings.has_prefix(cat, "x-gnome.alarm"):
		return .Time
	case strings.has_prefix(cat, "device."),
	     strings.has_prefix(cat, "network."),
	     strings.has_prefix(cat, "transfer."),
	     strings.has_prefix(cat, "presence."),
	     strings.has_prefix(cat, "email.bounced"),
	     cat == "x-palm.update",
	     cat == "x-palm.sync":
		return .Machine
	}
	// Someone asked for attention and said nothing more. The default is
	// person, because a third-party app that cannot say who is behind a
	// notification is far more often a chat or a web app than a cron job,
	// and a policy can demote one app in a sentence ("Chromium in the
	// digest"). Low urgency is taken as a machine speaking.
	return urgency == .Low ? .Machine : .Person
}

note_free :: proc(n: ^Note) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	if n == nil {
		return
	}
	delete(n.key)
	delete(n.app)
	delete(n.identity)
	delete(n.category)
	delete(n.title)
	delete(n.body)
	delete(n.link)
	delete(n.why)
	delete(n.fdo_sender)
	delete(n.digest)
	for a in n.actions {
		delete(a.key)
		delete(a.label)
		delete(a.run)
	}
	delete(n.actions)
	free(n)
}

// note_clone deep-copies `src` into fresh heap storage owned by the store.
note_clone :: proc(src: ^Note) -> ^Note {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	n := new(Note)
	n^ = src^
	n.key = strings.clone(src.key)
	n.app = strings.clone(src.app)
	n.identity = strings.clone(src.identity)
	n.category = strings.clone(src.category)
	n.title = strings.clone(src.title)
	n.body = strings.clone(src.body)
	n.link = strings.clone(src.link)
	n.why = strings.clone(src.why)
	n.fdo_sender = strings.clone(src.fdo_sender)
	n.digest = strings.clone(src.digest)
	n.actions = make([dynamic]Action)
	for a in src.actions {
		append(&n.actions, Action{strings.clone(a.key), strings.clone(a.label), strings.clone(a.run)})
	}
	return n
}

set_str :: proc(dst: ^string, v: string) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	delete(dst^)
	dst^ = strings.clone(v)
}

store_init :: proc(s: ^Store) {
	s.next_id = 1
	s.notes = make([dynamic]^Note)
	s.tombstones = make(map[string]i64)
	s.policies = make([dynamic]Policy)
}

store_find_id :: proc(s: ^Store, id: u32) -> (^Note, int) {
	for n, i in s.notes {
		if n.id == id {
			return n, i
		}
	}
	return nil, -1
}

store_find_key :: proc(s: ^Store, key: string) -> (^Note, int) {
	if key == "" {
		return nil, -1
	}
	for n, i in s.notes {
		if n.key == key {
			return n, i
		}
	}
	return nil, -1
}

touch :: proc(s: ^Store) {
	s.rev += 1
}

// Arrival is what `store_add` tells its caller, which is also what the
// sender is told back.
Arrival :: struct {
	note:     ^Note,
	replaced: bool, // an update to a key already here
	dropped:  bool, // a tombstoned key: already seen and put away
	toast:    bool, // put on screen now
	sound:    bool,
}

// store_add takes a notification in, deduplicated by key, and applies the
// policy in force for its identity at `now`. `in_` is copied; the caller
// keeps ownership of what it passed. `renotify` lets a sender that is
// genuinely saying something new about the same object interrupt again.
store_add :: proc(s: ^Store, in_: ^Note, now: i64, tz_offset: i64, renotify := false) -> Arrival {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	expire_tombstones(s, now)
	if in_.key != "" {
		if until, gone := s.tombstones[in_.key]; gone && until > now && !renotify {
			return Arrival{dropped = true}
		}
	}

	pol := policy_for(s, in_.identity)
	dec := decide(pol, s.dnd && (s.dnd_until == 0 || s.dnd_until > now), in_, now, tz_offset)

	if old, _ := store_find_key(s, in_.key); old != nil {
		// Delivered once: an update changes the words in place. It comes back
		// on screen only if it is still there, or the sender asked.
		set_str(&old.title, in_.title)
		set_str(&old.body, in_.body)
		set_str(&old.link, in_.link)
		set_str(&old.category, in_.category)
		for a in old.actions {
			delete(a.key)
			delete(a.label)
			delete(a.run)
		}
		clear(&old.actions)
		for a in in_.actions {
			append(&old.actions, Action{strings.clone(a.key), strings.clone(a.label), strings.clone(a.run)})
		}
		old.urgency = in_.urgency
		old.updated = now
		old.timeout_ms = in_.timeout_ms
		a := Arrival{note = old, replaced = true}
		if renotify && dec.delivery == .Toast {
			old.showing = true
			old.read = false
			old.delivery = .Toast
			set_str(&old.why, dec.why)
			a.toast = true
			a.sound = dec.sound
		} else {
			a.toast = old.showing
		}
		touch(s)
		return a
	}

	n := note_clone(in_)
	n.id = s.next_id
	s.next_id += 1
	if s.next_id == 0 {
		s.next_id = 1
	}
	if n.key == "" {
		n.key = strings.clone(fmt.tprintf("%s:%d", n.app != "" ? n.app : "anon", n.id))
	}
	n.created = now
	n.updated = now
	n.delivery = dec.delivery
	set_str(&n.why, dec.why)
	n.sound = dec.sound
	n.showing = dec.delivery == .Toast
	n.held = dec.delivery == .Digest
	n.daily = dec.daily
	append(&s.notes, n)
	trim_history(s, now)
	touch(s)
	return Arrival{note = n, toast = n.showing, sound = n.sound}
}

expire_tombstones :: proc(s: ^Store, now: i64) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	gone := make([dynamic]string, context.temp_allocator)
	for k, until in s.tombstones {
		if until <= now {
			append(&gone, k)
		}
	}
	for k in gone {
		key, _ := delete_key(&s.tombstones, k)
		delete(key)
	}
}

tombstone :: proc(s: ^Store, key: string, now: i64) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	if key == "" {
		return
	}
	if _, has := s.tombstones[key]; has {
		s.tombstones[key] = now + TOMBSTONE_MS
		return
	}
	s.tombstones[strings.clone(key)] = now + TOMBSTONE_MS
}

// trim_history keeps the store bounded: read notifications older than two
// weeks go, and past HISTORY_MAX the oldest read ones go first.
trim_history :: proc(s: ^Store, now: i64) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	i := 0
	for i < len(s.notes) {
		n := s.notes[i]
		if n.read && !n.held && now - n.updated > HISTORY_MS {
			note_free(n)
			ordered_remove(&s.notes, i)
			continue
		}
		i += 1
	}
	for len(s.notes) > HISTORY_MAX {
		victim := 0
		for n, k in s.notes {
			if n.read && !n.held {
				victim = k
				break
			}
		}
		note_free(s.notes[victim])
		ordered_remove(&s.notes, victim)
	}
}

// store_remove withdraws a notification: the sender says it no longer
// matters (the call was answered elsewhere, the mail was read in Mail). It is
// tombstoned, so the same key cannot come back as new.
store_remove :: proc(s: ^Store, idx: int, now: i64) {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	n := s.notes[idx]
	tombstone(s, n.key, now)
	note_free(n)
	ordered_remove(&s.notes, idx)
	touch(s)
}

store_mark_read :: proc(s: ^Store, n: ^Note) {
	if !n.read || n.showing {
		n.read = true
		n.showing = false
		touch(s)
	}
}

// Filter narrows a listing. An empty identity means every identity the
// caller may see; the daemon has already narrowed it to the caller's scope.
Filter :: struct {
	identity:   string,
	any_ident:  bool, // identity "" means "no identity" unless this is set
	app:        string,
	unread:     bool,
	showing:    bool,
	held:       bool,
}

filter_match :: proc(f: Filter, n: ^Note) -> bool {
	if !f.any_ident && n.identity != f.identity {
		return false
	}
	if f.app != "" && !strings.equal_fold(f.app, n.app) {
		return false
	}
	if f.unread && n.read {
		return false
	}
	if f.showing && !n.showing {
		return false
	}
	if f.held && !n.held {
		return false
	}
	return true
}

// store_select returns the matching notes, newest first.
store_select :: proc(s: ^Store, f: Filter, allocator := context.temp_allocator) -> []^Note {
	out := make([dynamic]^Note, allocator)
	#reverse for n in s.notes {
		if filter_match(f, n) {
			append(&out, n)
		}
	}
	return out[:]
}

// ---------------------------------------------------------------------------
// Digests
// ---------------------------------------------------------------------------

// digest_build gathers what an identity is holding into one notification,
// and marks each held one as having gone out in it. It returns nil when
// nothing is held. The digest's words say what is in it per application,
// most first, and the first person in it by name: a digest is a summary a
// person can act on without opening it.
digest_build :: proc(s: ^Store, identity: string, reason: string, now: i64, only_hold := false, before := max(i64)) -> ^Note {
	context.allocator = runtime.default_allocator() // the store\'s memory, whoever calls
	held := make([dynamic]^Note, context.temp_allocator)
	for n in s.notes {
		if n.held && n.identity == identity && !n.is_digest && !(only_hold && n.daily) && !(n.daily && n.created > before) {
			append(&held, n)
		}
	}
	if len(held) == 0 {
		return nil
	}

	App_Count :: struct {
		app: string,
		n:   int,
	}
	apps := make([dynamic]App_Count, context.temp_allocator)
	first_person: ^Note
	for n in held {
		found := false
		for &a in apps {
			if a.app == n.app {
				a.n += 1
				found = true
			}
		}
		if !found {
			append(&apps, App_Count{n.app, 1})
		}
		if first_person == nil && n.class == .Person {
			first_person = n
		}
	}
	slice.sort_by(apps[:], proc(a, b: App_Count) -> bool {return a.n > b.n})

	sb := strings.builder_make(context.temp_allocator)
	for a, i in apps {
		if i > 0 {
			strings.write_string(&sb, " · ")
		}
		fmt.sbprintf(&sb, "%s %d", app_label(a.app), a.n)
	}
	if first_person != nil {
		fmt.sbprintf(&sb, "\n%s", first_person.title)
		if first_person.body != "" {
			fmt.sbprintf(&sb, ": %s", first_line(first_person.body))
		}
	}

	key := fmt.tprintf("digest:%s:%d", identity != "" ? identity : "none", now / 1000)
	d := new(Note)
	d.id = s.next_id
	s.next_id += 1
	d.key = strings.clone(key)
	d.app = strings.clone("notify")
	d.identity = strings.clone(identity)
	d.class = .Machine
	d.urgency = .Normal
	d.category = strings.clone("x-palm.digest")
	d.title = strings.clone(fmt.tprintf("%d notification%s %s", len(held), len(held) == 1 ? "" : "s", reason))
	d.body = strings.clone(strings.to_string(sb))
	d.link = strings.clone(fmt.tprintf("notify center --identity %s", identity != "" ? identity : "none"))
	d.actions = make([dynamic]Action)
	append(&d.actions, Action{strings.clone("default"), strings.clone("Open"), strings.clone(d.link)})
	d.source = .System
	d.created = now
	d.updated = now
	d.is_digest = true
	d.count = len(held)
	d.why = strings.clone("")
	d.fdo_sender = strings.clone("")
	d.digest = strings.clone("")
	for n in held {
		n.held = false
		set_str(&n.digest, d.key)
	}
	append(&s.notes, d)
	touch(s)
	return d
}

first_line :: proc(s: string) -> string {
	if i := strings.index_byte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// app_label is an application's name as a person reads it.
app_label :: proc(app: string) -> string {
	switch app {
	case "":
		return "Unknown"
	case "palm":
		return "Updates"
	case "notify":
		return "Notifications"
	case "store":
		return "Software"
	}
	if app[0] >= 'a' && app[0] <= 'z' {
		return fmt.tprintf("%c%s", rune(app[0] - 32), app[1:])
	}
	return app
}
