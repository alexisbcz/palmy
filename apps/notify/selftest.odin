// `notify --selftest`: the policy grammar, the decision, "delivered once",
// digests, and the small pieces the doors depend on, against a fixed clock.
// Nothing here touches a socket, the bus or the screen; apps/notify/e2e.sh
// covers those with a real daemon.
package main

import "core:fmt"
import "core:strings"

@(private = "file")
st_fail: int
@(private = "file")
st_pass: int

@(private = "file")
check :: proc(ok: bool, what: string, loc := #caller_location) {
	if ok {
		st_pass += 1
	} else {
		st_fail += 1
		fmt.eprintfln("FAIL %s (%s:%d)", what, loc.file_path[strings.last_index_byte(loc.file_path, '/') + 1:], loc.line)
	}
}

// A Monday at 12:00 local, UTC+2.
@(private = "file")
TZ :: i64(7200)
@(private = "file")
NOON :: i64(1792404000000) // 2026-10-19 10:00 UTC = 12:00 local

@(private = "file")
at :: proc(hh, mm: int) -> i64 {
	return NOON + i64((hh - 12) * 60 + mm) * 60_000
}

@(private = "file")
parse :: proc(s: string, now := NOON) -> (Policy, bool) {
	p, _, ok := policy_parse(s, policy_default("work"), now, TZ)
	return p, ok
}

@(private = "file")
note :: proc(ident: string, class: Class, urgency := Urgency.Normal, app := "mail", category := "", key := "") -> Note {
	return Note{identity = ident, class = class, urgency = urgency, app = app, category = category, title = "t", key = key}
}

selftest :: proc() -> int {
	identities_set({{"work", "Northwind", "blue"}, {"me", "Personal", "teal"}})

	// --- time of day -------------------------------------------------------
	check(local_minute(NOON, TZ) == 12 * 60, "the fixed clock reads 12:00 local")
	check(local_minute(at(18, 30), TZ) == 18 * 60 + 30, "18:30")
	check(next_at(NOON, TZ, 8 * 60) == at(32, 0), "next 08:00 is tomorrow's")
	check(next_at(NOON, TZ, 13 * 60) == at(13, 0), "next 13:00 is today's")
	Case :: struct {
		s:    string,
		want: int,
	}
	for c in ([?]Case{{"18:00", 1080}, {"6pm", 1080}, {"6:30 pm", 1110}, {"18h", 1080}, {"noon", 720}, {"midnight", 0}, {"7", 420}, {"12am", 0}, {"12pm", 720}}) {
		m, ok := parse_time(c.s)
		check(ok && m == c.want, fmt.tprintf("parse_time %q", c.s))
	}
	for s in ([?]string{"25:00", "18:5", "pm", "", "13pm", "x"}) {
		_, ok := parse_time(s)
		check(!ok, fmt.tprintf("parse_time refuses %q", s))
	}
	check(in_window(23 * 60, 22 * 60, 7 * 60) && in_window(60, 22 * 60, 7 * 60) && !in_window(12 * 60, 22 * 60, 7 * 60), "a window across midnight")

	// --- the sentence ----------------------------------------------------------
	{
		p, ok := parse("after 18:00")
		check(ok && p.quiet_from == 1080 && p.quiet_to == MORNING, "`after 18:00` is quiet hours to the morning")
		check(policy_sentence(p, NOON, TZ) == "Quiet after 18:00", "and reads back as “Quiet after 18:00”")
	}
	{
		p, ok := parse("Quiet after 18:00. Daily digest at 17:00; calls break through, Forge in the digest, mute Chromium")
		check(ok, "a five-clause sentence parses")
		check(p.digest_at == 1020 && .Calls in p.breaks && .Reminders in p.breaks, "digest and calls, reminders kept")
		check(app_mode(p, "forge") == .Digest && app_mode(p, "Chromium") == .Muted, "per-app rules, any case")
		s := policy_sentence(p, NOON, TZ)
		check(s == "Quiet after 18:00. Daily digest at 17:00. Calls break through. Forge in the digest. Mute Chromium", fmt.tprintf("rendered: %s", s))
		q, ok2 := parse(s)
		check(ok2 && policy_sentence(q, NOON, TZ) == s, "the rendered sentence parses back to itself")
	}
	{
		p, ok := parse("quiet 22:00-07:00")
		check(ok && p.quiet_from == 1320 && p.quiet_to == 420, "a range with a hyphen")
		check(policy_sentence(p, NOON, TZ) == "Quiet 22:00–07:00", "rendered with an en dash")
		q, ok2 := parse("Quiet between 22:00 and 07:00")
		check(ok2 && q.quiet_from == 1320 && q.quiet_to == 420, "between … and …")
		r, ok3 := parse(policy_sentence(p, NOON, TZ))
		check(ok3 && r.quiet_from == 1320, "the en dash parses back")
	}
	{
		p, ok := parse("People only. Nothing breaks through")
		check(ok && p.people_only && p.breaks == {}, "people only, nothing breaks through")
		p2, ok2 := parse("calls and alarms break through. reminders wait")
		check(ok2 && p2.breaks == {.Calls, .Alarms}, "calls and alarms, reminders wait")
		check(policy_sentence(p2, NOON, TZ) == "Calls and alarms break through. Reminders wait", "and back")
	}
	{
		p, ok := parse("quiet for 2 hours")
		check(ok && p.quiet_until == NOON + 2 * 3_600_000, "a one-off quiet for two hours")
		check(policy_sentence(p, NOON, TZ) == "Quiet until 14:00", "said as until 14:00")
		check(policy_sentence(p, at(15, 0), TZ) == "People and reminders", "and gone after")
		q, ok2 := parse("focus until 15:30")
		check(ok2 && q.dnd_until == at(15, 30), "focus until 15:30")
		check(hold_of(q, false, at(15, 0), TZ) == .Dnd && hold_of(q, false, at(15, 31), TZ) == .None, "focus holds, then lifts")
	}
	{
		_, perr, ok := policy_parse("quiet after lunch", policy_default("work"), NOON, TZ)
		check(!ok && perr.clause == "quiet after lunch", "an unreadable clause is refused, and quoted")
		_, _, ok2 := policy_parse("make it nice", policy_default("work"), NOON, TZ)
		check(!ok2, "nonsense is refused, not guessed")
		d, _, ok3 := policy_parse("", policy_default("work"), NOON, TZ)
		check(ok3 && policy_sentence(d, NOON, TZ) == "People and reminders", "an empty sentence is the default, said positively")
	}
	{
		base, _ := parse("after 18:00")
		p, _, ok := policy_parse("daily digest at 17:00", base, NOON, TZ)
		check(ok && p.quiet_from == 1080 && p.digest_at == 1020, "`add` keeps what was there")
		r, _, ok2 := policy_parse("resume", base, at(19, 0), TZ)
		check(ok2 && r.awake_until == at(32, 0) && hold_of(r, false, at(19, 0), TZ) == .None, "resume during quiet hours sets them aside until they end")
		check(hold_of(r, false, at(42, 0), TZ) == .Quiet, "and they come back the next evening")
		check(strings.contains(policy_sentence(r, at(19, 0), TZ), "Not quiet until 08:00"), "said as “Not quiet until 08:00”")
		x, _, ok3 := policy_parse("everything", p, NOON, TZ)
		check(ok3 && x.quiet_from < 0 && x.digest_at < 0, "`everything` resets")
	}

	// --- the decision -----------------------------------------------------------
	{
		def := policy_default("work")
		n := note("work", .Person)
		check(decide(def, false, &n, NOON, TZ).delivery == .Toast, "a person interrupts by default")
		m := note("work", .Machine, app = "forge")
		check(decide(def, false, &m, NOON, TZ).delivery == .Center, "a machine never interrupts")
		t := note("work", .Time, app = "calendar")
		check(decide(def, false, &t, NOON, TZ).delivery == .Toast, "a reminder interrupts at its time")
		l := note("work", .Person, .Low)
		check(decide(def, false, &l, NOON, TZ).delivery == .Center, "low urgency does not")

		q, _ := parse("after 18:00. daily digest at 17:00")
		d1 := decide(q, false, &n, at(18, 30), TZ)
		check(d1.delivery == .Digest && !d1.daily && !d1.sound, "quiet: a person is held for the digest, silently")
		check(d1.why == "Northwind is quiet", fmt.tprintf("…and says why: %q", d1.why))
		check(decide(q, false, &t, at(18, 30), TZ).delivery == .Toast, "quiet: a reminder still breaks through by default")
		d2 := decide(q, false, &m, NOON, TZ)
		check(d2.delivery == .Digest && d2.daily, "machines go in the daily digest")

		call := note("work", .Person, .Critical, app = "call", category = "call.incoming")
		check(decide(q, false, &call, at(18, 30), TZ).delivery == .Digest, "quiet: a call does NOT break through unless allowed")
		qc, _ := parse("after 18:00. calls break through")
		dc := decide(qc, false, &call, at(18, 30), TZ)
		check(dc.delivery == .Toast && dc.sound, "quiet + calls break through: the call rings")
		check(decide(qc, true, &call, NOON, TZ).delivery == .Toast, "do not disturb + calls break through: rings")
		check(decide(def, true, &call, NOON, TZ).delivery == .Digest, "do not disturb, default: the call is held")
		check(decide(qc, true, &t, NOON, TZ).delivery == .Digest, "do not disturb holds reminders too")
		alarm := note("work", .Time, .Critical, app = "calendar", category = "alarm")
		check(decide(def, true, &alarm, NOON, TZ).delivery == .Digest, "an alarm does not break DND by default")
		pa, _ := parse("alarms break through")
		check(decide(pa, true, &alarm, NOON, TZ).delivery == .Toast, "…unless the policy says so")

		po, _ := parse("people only")
		check(decide(po, false, &t, NOON, TZ).delivery == .Center && decide(po, false, &n, NOON, TZ).delivery == .Toast, "people only: reminders wait, people interrupt")

		mu, _ := parse("mute mail")
		check(decide(mu, false, &n, NOON, TZ).delivery == .Center, "a muted app never interrupts")
		al, _ := parse("forge always")
		check(decide(al, false, &m, NOON, TZ).delivery == .Toast, "an `always` app interrupts even as a machine")
	}

	// --- delivered once ---------------------------------------------------------
	{
		s: Store
		store_init(&s)
		a := note("work", .Person, key = "mail:<abc@x>")
		r1 := store_add(&s, &a, NOON, TZ)
		check(r1.toast && !r1.replaced, "first arrival toasts")
		b := note("work", .Person, app = "home", key = "mail:<abc@x>")
		b.title = "updated"
		r2 := store_add(&s, &b, NOON + 1000, TZ)
		check(r2.replaced && r2.note == r1.note && len(s.notes) == 1, "the same key from another app is the same notification")
		check(r2.note.title == "updated" && !r2.sound, "…updated in place, and it does not ring again")
		store_mark_read(&s, r2.note)
		r3 := store_add(&s, &a, NOON + 2000, TZ)
		check(r3.replaced && !r3.toast && r3.note.read, "a read notification repeated stays read and off screen")
		r4 := store_add(&s, &a, NOON + 3000, TZ, renotify = true)
		check(r4.toast, "renotify: the sender says it is news")
		_, idx := store_find_key(&s, "mail:<abc@x>")
		store_remove(&s, idx, NOON + 4000)
		r5 := store_add(&s, &a, NOON + 5000, TZ)
		check(r5.dropped && len(s.notes) == 0, "a withdrawn key is not delivered again")
		r6 := store_add(&s, &a, NOON + TOMBSTONE_MS + 6000, TZ)
		check(!r6.dropped, "…until the tombstone expires")
		c1 := note("work", .Person, app = "chat")
		c2 := note("work", .Person, app = "chat")
		x1 := store_add(&s, &c1, NOON, TZ)
		x2 := store_add(&s, &c2, NOON, TZ)
		check(x1.note != x2.note && x1.note.key != x2.note.key, "no key: two notifications, two keys")
	}

	// --- digests ------------------------------------------------------------------
	{
		s: Store
		store_init(&s)
		q, _ := parse("after 18:00. daily digest at 17:00")
		policy_put(&s, q)
		for i in 0 ..< 3 {
			n := note("work", .Person, app = i == 2 ? "forge" : "mail")
			n.title = fmt.tprintf("Person %d", i)
			n.body = "hello"
			r := store_add(&s, &n, at(18, 10 + i), TZ)
			check(r.note.held && !r.toast, "held while quiet")
		}
		mach := note("work", .Machine, app = "forge")
		rm := store_add(&s, &mach, at(16, 0), TZ)
		check(rm.note.held && rm.note.daily, "a machine waits for the daily digest")
		dg := digest_build(&s, "work", "while quiet", at(32, 0), true)
		check(dg != nil && dg.count == 3, "the quiet digest carries the three held people, not the machine")
		check(dg.title == "3 notifications while quiet", fmt.tprintf("digest title %q", dg.title))
		check(strings.has_prefix(dg.body, "Mail 2 · Forge 1\nPerson 0: hello"), fmt.tprintf("digest body %q", dg.body))
		check(rm.note.held, "the machine is still waiting")
		dd := digest_build(&s, "work", "in the 17:00 digest", at(41, 0), false, at(41, 0))
		check(dd != nil && dd.count == 1 && !rm.note.held, "the daily digest takes it")
		check(digest_build(&s, "work", "x", at(42, 0)) == nil, "nothing held, no digest")
	}

	// --- the doors' small pieces ----------------------------------------------------
	check(strip_markup("<b>Priya</b> &amp; <i>Ines</i> &lt;3") == "Priya & Ines <3", "markup is stripped, entities decoded")
	check(class_for_category("call.incoming", .Critical) == .Person && class_for_category("im.received", .Normal) == .Person, "fdo categories: person")
	check(class_for_category("transfer.complete", .Normal) == .Machine && class_for_category("device.added", .Normal) == .Machine, "fdo categories: machine")
	check(class_for_category("", .Normal) == .Person && class_for_category("", .Low) == .Machine, "no category: person, unless low")
	{
		argv := split_command(`mail open "<abc 1@x>" 'two words'`)
		check(len(argv) == 4 && argv[2] == "<abc 1@x>" && argv[3] == "two words", "deep links split without a shell")
	}
	{
		n := note("work", .Person, .Critical, app = "call", category = "call.incoming")
		n.title = "Ines Roux"
		n.body = "Design review"
		n.actions = make([dynamic]Action, context.temp_allocator)
		append(&n.actions, Action{"answer", "Answer", ""}, Action{"decline", "Decline", ""})
		sp := spoken(&n)
		check(sp == "Incoming call from Call, Northwind identity, urgent. Ines Roux. Design review. Actions: Answer, Decline.", fmt.tprintf("spoken: %q", sp))
	}
	check(in_scope("", "work") && in_scope("work", "work") && !in_scope("work", "me") && !in_scope("work", ""), "scope: narrowed, never widened")
	check(app_label("palm") == "Updates" && app_label("mail") == "Mail" && app_label("Chromium") == "Chromium", "app labels")

	fmt.printfln("notify --selftest: %d passed, %d failed", st_pass, st_fail)
	return st_fail == 0 ? 0 : 1
}
